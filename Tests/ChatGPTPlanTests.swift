import CryptoKit
import Foundation
import Security
import XCTest
@testable import HermesPet

final class ChatGPTPlanOAuthTests: XCTestCase {
    func testPKCEAndFormEncoding() throws {
        XCTAssertEqual(ChatGPTPlanOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(String(data: ChatGPTPlanOAuth.form(["code": "a+b&=/ 中文"]), encoding: .utf8), "code=a%2Bb%26%3D%2F%20%E4%B8%AD%E6%96%87")
        let state = try ChatGPTPlanOAuth.random()
        XCTAssertEqual(state.count, 64); XCTAssertNotEqual(state, try ChatGPTPlanOAuth.random())
    }
    func testCallbackRejectsMismatchedAndDuplicateStateAndClient() throws {
        func callback(_ query: String) -> URLComponents { URLComponents(string: "http://127.0.0.1:1234/auth/callback?" + query)! }
        XCTAssertEqual(try ChatGPTPlanOAuth.issuedClient(callback: callback("state=good&code=x&client_id=oaiapp_test"), expectedState: "good", returningClient: nil), "oaiapp_test")
        XCTAssertEqual(try ChatGPTPlanOAuth.issuedClient(callback: callback("state=good&code=x"), expectedState: "good", returningClient: "oaiapp_saved"), "oaiapp_saved")
        for query in ["state=bad&code=x&client_id=oaiapp_test", "state=good&state=good&code=x&client_id=oaiapp_test", "state=good&code=x&client_id=dynamic_agent_client", "state=good&code=x", "state=good&error=access_denied"] {
            XCTAssertThrowsError(try ChatGPTPlanOAuth.issuedClient(callback: callback(query), expectedState: "good", returningClient: nil))
        }
        XCTAssertThrowsError(try ChatGPTPlanOAuth.issuedClient(callback: callback("state=good&code=x&client_id=oaiapp_other"), expectedState: "good", returningClient: "oaiapp_saved"))
    }
    func testSignedIdentityRejectsWrongNonceAudienceExpiryAndTampering() throws {
        let key = P256.Signing.PrivateKey(), point = key.publicKey.x963Representation
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "test", "kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "x": ChatGPTPlanOAuth.base64URL(point.subdata(in: 1..<33)), "y": ChatGPTPlanOAuth.base64URL(point.subdata(in: 33..<65))]]])
        let now = Date()
        var claims: [String: Any] = ["iss": ChatGPTPlanOAuth.issuer, "sub": "account", "email": "test@example.com", "aud": "oaiapp_test", "nonce": "nonce", "exp": now.timeIntervalSince1970 + 3600, "iat": now.timeIntervalSince1970]
        func signed(_ value: [String: Any]) throws -> String {
            let header = ChatGPTPlanOAuth.base64URL(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "test"]))
            let body = ChatGPTPlanOAuth.base64URL(try JSONSerialization.data(withJSONObject: value))
            let text = header + "." + body
            return text + "." + ChatGPTPlanOAuth.base64URL(try key.signature(for: Data(text.utf8)).rawRepresentation)
        }
        let good = try signed(claims)
        XCTAssertEqual(try ChatGPTPlanOAuth.verifyIDToken(good, jwks: jwks, clientID: "oaiapp_test", nonce: "nonce", now: now)["sub"] as? String, "account")
        XCTAssertThrowsError(try ChatGPTPlanOAuth.verifyIDToken(good, jwks: jwks, clientID: "oaiapp_other", nonce: "nonce", now: now))
        XCTAssertThrowsError(try ChatGPTPlanOAuth.verifyIDToken(good, jwks: jwks, clientID: "oaiapp_test", nonce: "wrong", now: now))
        claims["exp"] = now.timeIntervalSince1970 - 1
        XCTAssertThrowsError(try ChatGPTPlanOAuth.verifyIDToken(signed(claims), jwks: jwks, clientID: "oaiapp_test", nonce: "nonce", now: now))
        var parts = good.split(separator: ".").map(String.init)
        claims["sub"] = "intruder"; parts[1] = ChatGPTPlanOAuth.base64URL(try JSONSerialization.data(withJSONObject: claims))
        XCTAssertThrowsError(try ChatGPTPlanOAuth.verifyIDToken(parts.joined(separator: "."), jwks: jwks, clientID: "oaiapp_test", nonce: "nonce", now: now))
    }
    func testLoopbackListenerIgnoresInvalidStateAndAcceptsOneValidCallback() async throws {
        let listener = ChatGPTLoginCallback(state: "correct")
        defer { listener.cancel() }
        let uri = try await listener.start()
        XCTAssertTrue(uri.hasPrefix("http://127.0.0.1:")); XCTAssertTrue(uri.hasSuffix("/auth/callback"))
        let (_, invalid) = try await URLSession.shared.data(from: URL(string: uri + "?state=wrong&code=x")!)
        XCTAssertEqual((invalid as? HTTPURLResponse)?.statusCode, 400)
        let (_, valid) = try await URLSession.shared.data(from: URL(string: uri + "?state=correct&code=x&client_id=oaiapp_test")!)
        XCTAssertEqual((valid as? HTTPURLResponse)?.statusCode, 200)
        let value = try await listener.waitForCallback()
        XCTAssertEqual(try ChatGPTPlanOAuth.issuedClient(callback: value, expectedState: "correct", returningClient: nil), "oaiapp_test")
    }
    func testRS256IdentityUsesTheOfficialJWKPublicKey() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var cursor = 0
        func readTLV() throws -> Data {
            _ = der[cursor]; cursor += 1
            var length = Int(der[cursor]); cursor += 1
            if length & 128 != 0 {
                let count = length & 127; length = 0
                for _ in 0..<count { length = length * 256 + Int(der[cursor]); cursor += 1 }
            }
            let value = der.subdata(in: cursor..<(cursor + length)); cursor += length; return value
        }
        _ = try readTLV(); cursor = der.count - (try readTLVAtStart(der)).count
        var n = try readTLV(); let e = try readTLV()
        if n.first == 0 { n.removeFirst() }
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "rsa-test", "kty": "RSA", "n": ChatGPTPlanOAuth.base64URL(n), "e": ChatGPTPlanOAuth.base64URL(e)]]])
        let header = ChatGPTPlanOAuth.base64URL(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "rsa-test"]))
        let claims: [String: Any] = ["iss": ChatGPTPlanOAuth.issuer, "aud": "oaiapp_rsa", "sub": "account", "nonce": "nonce", "iat": Date().timeIntervalSince1970, "exp": Date().timeIntervalSince1970 + 3600]
        let body = ChatGPTPlanOAuth.base64URL(try JSONSerialization.data(withJSONObject: claims)), text = header + "." + body
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(text.utf8) as CFData, nil)) as Data
        let token = text + "." + ChatGPTPlanOAuth.base64URL(signature)
        XCTAssertEqual(try ChatGPTPlanOAuth.verifyIDToken(token, jwks: jwks, clientID: "oaiapp_rsa", nonce: "nonce")["sub"] as? String, "account")
    }
    private func readTLVAtStart(_ data: Data) throws -> Data {
        var cursor = 1, length = Int(data[1]); cursor += 1
        if length & 128 != 0 {
            let count = length & 127; length = 0
            for _ in 0..<count { length = length * 256 + Int(data[cursor]); cursor += 1 }
        }
        return data.subdata(in: cursor..<(cursor + length))
    }
}

@MainActor
final class ChatGPTPlanRuntimeTests: XCTestCase {
    private func fixture(_ scenario: String) throws -> (URL, ChatGPTPlanClient, AgentRunRequest) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tars-plan-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("mock-codex")
        let script = """
        #!/usr/bin/python3
        import sys,json,pathlib
        root=pathlib.Path(__file__).parent
        scenario='\(scenario)'
        status='inProgress'
        def send(v):
            print(json.dumps(v),flush=True)
        for line in sys.stdin:
            m=json.loads(line); method=m.get('method'); p=m.get('params',{})
            if 'id' not in m: continue
            with (root/'requests.jsonl').open('a') as f: f.write(json.dumps(m)+'\\n')
            if method=='initialize': send({'id':m['id'],'result':{'userAgent':'mock'}})
            elif method in ['thread/start','thread/resume']: send({'id':m['id'],'result':{'thread':{'id':'thread-test'}}})
            elif method=='thread/read': send({'id':m['id'],'result':{'thread':{'turns':[{'id':'turn-test','status':'completed' if (root/'terminal').exists() else status,'items':[{'type':'agentMessage','text':'recovered'}]}]}}})
            elif method=='turn/interrupt':
                status='interrupted'; send({'id':m['id'],'result':{}})
            elif method=='turn/start':
                send({'id':m['id'],'result':{'turn':{'id':'turn-test'}}})
                if scenario=='approval':
                    send({'id':'approval-id','method':'item/commandExecution/requestApproval','params':{'threadId':'thread-test','turnId':'turn-test','itemId':'tool','command':'echo test','reason':'test approval'}})
                    continue
                send({'method':'item/agentMessage/delta','params':{'threadId':'other-thread','turnId':'child','itemId':'secret','delta':'do not show'}})
                send({'method':'item/agentMessage/delta','params':{'threadId':'thread-test','turnId':'turn-test','itemId':'answer','delta':'hel'}})
                if scenario=='disconnect': break
                if scenario=='stalled': continue
                send({'method':'item/agentMessage/delta','params':{'threadId':'thread-test','turnId':'turn-test','itemId':'answer','delta':'lo'}})
                status='failed' if scenario=='quota' else 'interrupted' if scenario=='interrupted' else 'completed'
                send({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-test','status':status,'items':[{'type':'agentMessage','text':'hello'}],'error':{'message':'subscription_sharing_usage_limit_exceeded'} if scenario=='quota' else None}}})
            elif m['id']=='approval-id':
                send({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-test','status':'completed','items':[{'type':'agentMessage','text':'approved'}]}}})
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ChatGPTPlanClient(bindingsURL: root.appendingPathComponent("bindings.json"), tokenProvider: { id in
            guard id == "oaiapp_test" else { throw ChatGPTPlanError.message("Wrong account") }; return "test-only-token"
        }, executableProvider: { executable.path })
        let request = AgentRunRequest(conversationID: "test", mode: .directAPI, engine: .chatGPT, configuration: AgentConfiguration(), workingDirectory: root.path,
            messages: [ChatMessage(role: .user, content: "hello", documentPaths: ["/tmp/reference.pdf"])], omittedCount: 0, ephemeral: false,
            chatGPTAccountID: "oaiapp_test", chatGPTModel: "model-from-account")
        return (root, client, request)
    }
    func testCompletedTurnStreamsOnlyItsOwnOutputAndResumesBoundAccount() async throws {
        let (root, client, request) = try fixture("success"); defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<2 {
            var text = ""
            for try await delta in client.streamCompletion(request) { AgentTextUpdate.apply(delta, to: &text) }
            XCTAssertEqual(text, "hello")
        }
        let lines = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
        let requests = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(requests.filter { $0["method"] as? String == "thread/start" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "thread/resume" }.count, 1)
        let threadParams = try XCTUnwrap(requests.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
        XCTAssertTrue((threadParams["developerInstructions"] as? String ?? "").contains("model-from-account"))
        let selected = try client.selection(conversationID: "test"); XCTAssertEqual(selected.accountID, "oaiapp_test")
        let input = requests.first { $0["method"] as? String == "turn/start" }!["params"] as! [String: Any]
        XCTAssertTrue(String(describing: input["input"]!).contains("/tmp/reference.pdf"))
        XCTAssertFalse(String(describing: requests).contains("test-only-token"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("bindings.json").path)[.posixPermissions] as? Int, 0o600)
    }
    func testInspectionReadsTerminalResultWithoutStartingAnotherTurn() async throws {
        let (root, client, request) = try fixture("disconnect")
        defer { try? FileManager.default.removeItem(at: root) }
        do { for try await _ in client.streamCompletion(request) { }; XCTFail("Expected disconnect") } catch { }
        XCTAssertTrue(client.hasUnconfirmedTask(conversationID: "test"))
        let pending = try await client.inspectTask(conversationID: "test", configuration: request.configuration)
        XCTAssertEqual(pending.status, "inProgress")
        XCTAssertTrue(client.hasUnconfirmedTask(conversationID: "test"))
        try Data().write(to: root.appendingPathComponent("terminal"))
        let final = try await client.inspectTask(conversationID: "test", configuration: request.configuration)
        XCTAssertEqual(final.status, "completed")
        XCTAssertEqual(final.text, "recovered")
        XCTAssertFalse(client.hasUnconfirmedTask(conversationID: "test"))
        let lines = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
        let requests = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(requests.filter { $0["method"] as? String == "turn/start" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "thread/read" }.count, 2)
    }

    func testQuotaAndInterruptedTerminalEventsAreFailures() async throws {
        for scenario in ["quota", "interrupted"] {
            let (root, client, request) = try fixture(scenario); defer { try? FileManager.default.removeItem(at: root) }
            do { for try await _ in client.streamCompletion(request) { }; XCTFail("Non-completed turn was accepted") }
            catch { if scenario == "quota" { XCTAssertTrue(error.localizedDescription.contains("额度已用尽")) } else { XCTAssertTrue(error is CancellationError) } }
        }
    }
    func testPermissionDecisionIsRoutedBackToTheRequestingRPC() async throws {
        let (root, client, request) = try fixture("approval"); defer { try? FileManager.default.removeItem(at: root) }
        let observer = NotificationCenter.default.addObserver(forName: .init("HermesPetPermissionAsked"), object: nil, queue: .main) { note in
            guard let permission = note.userInfo?["request"] as? PermissionRequest, permission.id.hasPrefix("tars-chatgpt-") else { return }
            Task { @MainActor in
                NotificationCenter.default.post(name: .init("HermesPetPermissionDecisionMade"), object: nil,
                    userInfo: ["requestID": permission.id, "decision": PermissionDecision.once.rawValue])
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var text = ""
        for try await delta in client.streamCompletion(request) { AgentTextUpdate.apply(delta, to: &text) }
        XCTAssertEqual(text, "approved")
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        XCTAssertTrue(requests.contains("\"decision\": \"accept\""))
    }
    func testDisconnectedInputIsNeverAutomaticallyReplayed() async throws {
        let (root, client, request) = try fixture("disconnect"); defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<2 {
            do { for try await _ in client.streamCompletion(request) { }; XCTFail("Disconnected turn succeeded") } catch { }
        }
        let text = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "\"method\": \"turn/start\"").count - 1, 1)
        XCTAssertTrue(text.contains("thread/read"))
    }
    func testCancellationInterruptsTheActualTurn() async throws {
        let (root, client, request) = try fixture("stalled"); defer { try? FileManager.default.removeItem(at: root) }
        let first = expectation(description: "first delta")
        let task = Task { @MainActor in
            do { for try await _ in client.streamCompletion(request) { first.fulfill() } } catch { }
        }
        await fulfillment(of: [first], timeout: 5)
        task.cancel(); await task.value
        // Consumer cancellation triggers asynchronous producer cleanup.
        for _ in 0..<30 {
            let text = (try? String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)) ?? ""
            if text.contains("turn/interrupt") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let text = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        XCTAssertTrue(text.contains("turn/interrupt"))
    }
    func testInstalledCodexSupportsTheConfiguredHandshake() async throws {
        let path = NSHomeDirectory() + "/.local/bin/codex"
        guard FileManager.default.isExecutableFile(atPath: path) else { throw XCTSkip("Codex is not installed on this test host") }
        let rpc = ChatGPTPlanRPC(); defer { rpc.stop() }
        try rpc.start(executable: path, token: "test-only-no-inference", directory: NSTemporaryDirectory(), configuration: AgentConfiguration())
        let response = try await rpc.request("initialize", params: ["clientInfo": ["name": "tars", "title": "Tars", "version": "test"], "capabilities": ["experimentalApi": true]], timeout: 15)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: response) as? [String: Any])
        try rpc.notify("initialized", params: [:])
    }
}
