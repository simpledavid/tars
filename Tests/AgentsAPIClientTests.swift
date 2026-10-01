import XCTest
import CryptoKit
@testable import HermesPet

@MainActor
private final class TestExecutor: AgentsExecuting {
    var sessions = Set<String>()
    var keys: [String] = []
    func start(sessionID: String, environmentID: String, remoteURL: String,
               directory: String, key: String, executablePath: String) throws {
        sessions.insert(sessionID)
        keys.append(key)
    }
    func stop(sessionID: String) { sessions.remove(sessionID) }
    func isRunning(sessionID: String) -> Bool { sessions.contains(sessionID) }
}

private enum StreamScenario: Sendable { case success, idleOnly, failed, recoverFromItems, stalled }

private final class TestHTTP: @unchecked Sendable {
    static let shared = TestHTTP()
    private let lock = NSLock()
    struct State {
        var requests: [URLRequest] = []
        var inputs = 0
        var creates = 0
        var scenario: StreamScenario
        var statusCode = 200
    }
    private var states: [String: State] = [:]

    func register(host: String, scenario: StreamScenario, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        states[host] = State(scenario: scenario, statusCode: status)
    }
    func changeScenario(host: String, scenario: StreamScenario) {
        lock.lock(); defer { lock.unlock() }
        states[host]?.scenario = scenario
    }
    func state(host: String) -> State {
        lock.lock(); defer { lock.unlock() }
        return states[host]!
    }
    func response(_ request: URLRequest) throws -> (Int, Data, String) {
        lock.lock(); defer { lock.unlock() }
        let host = request.url!.host!
        var state = states[host]!
        state.requests.append(request)
        defer { states[host] = state }
        if state.statusCode != 200 { return (state.statusCode, Data("{}".utf8), "application/json") }
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        var object: [String: Any] = [:]
        if path.hasSuffix("/sessions") && method == "POST" {
            state.creates += 1
            object = ["id": "session_\(state.creates)",
                      "environment": ["id": "environment_test", "remote_url": "https://api.openai.com/v1/agents/api"]]
        } else if path.hasSuffix("/events") && method == "GET" {
            let turnID = "turn_\(state.inputs + 1)"
            var events: [[String: Any]] = [
                ["type": "agent.session.turn.created", "turn": ["id": turnID, "subagent_id": NSNull()]],
                ["type": "agent.session.turn.created", "turn": ["id": "child", "subagent_id": "child_agent"]],
                ["type": "agent.session.turn.output_text.done", "turn_id": "child", "item_id": "child_item", "text": "private child text"],
                ["type": "agent.session.turn.completed", "turn": ["id": "child", "subagent_id": "child_agent"]]
            ]
            switch state.scenario {
            case .success:
                events += [["type": "agent.session.turn.output_text.done", "turn_id": turnID, "item_id": "answer", "text": "hello"],
                           ["type": "agent.session.turn.completed", "turn": ["id": turnID, "subagent_id": NSNull(), "status": "completed"]]]
            case .idleOnly, .recoverFromItems, .stalled:
                events += [["type": "agent.session.idle"]]
            case .failed:
                events += [["type": "agent.session.turn.failed", "turn": ["id": turnID, "subagent_id": NSNull(), "error": ["message": "test failure"]]]]
            }
            let data = try events.map { "data: " + String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! + "\n\n" }.joined()
            return (200, Data(data.utf8), "text/event-stream")
        } else if path.hasSuffix("/events") && method == "POST" {
            if let body = request.httpBody,
               let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any],
               let events = obj["events"] as? [[String: Any]],
               events.first?["type"] as? String == "agent.session.input.message" {
                state.inputs += 1
            }
            return (202, Data(), "application/json")
        } else if path.hasSuffix("/turns") {
            let status = (state.scenario == .idleOnly || state.scenario == .stalled) ? "in_progress" : "completed"
            object = ["data": state.inputs == 0 ? [] : [["id": "turn_\(state.inputs)", "subagent_id": NSNull(), "status": status]], "has_more": false]
        } else if path.hasSuffix("/items") {
            object = ["data": [["id": "answer", "turn_id": "turn_\(state.inputs)", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": state.scenario == .success ? "hello" : "recovered"]]]], "has_more": false]
        } else {
            object = ["status": "idle", "environment": ["status": "connected"]]
        }
        return (200, try JSONSerialization.data(withJSONObject: object), "application/json")
    }
}

private final class AgentsTestURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasPrefix("tars-test-") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var normalized = request
            if normalized.httpBody == nil, let stream = normalized.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let length = stream.read(&buffer, maxLength: buffer.count)
                    if length <= 0 { break }
                    body.append(contentsOf: buffer.prefix(length))
                }
                normalized.httpBody = body
            }
            let (status, data, type) = try TestHTTP.shared.response(normalized)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            if request.url!.path.hasSuffix("/events") && request.httpMethod == "GET" && TestHTTP.shared.state(host: request.url!.host!).scenario == .stalled { return }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class AgentsAPIClientTests: XCTestCase {
    private func makeRun(id: String = "conversation", messages: [ChatMessage]? = nil) -> AgentRunRequest {
        AgentRunRequest(conversationID: id, mode: .directAPI, engine: .agentsAPI,
                        configuration: AgentConfiguration(), workingDirectory: "/tmp",
                        messages: messages ?? [ChatMessage(role: .user, content: "hello")], omittedCount: 0, ephemeral: false,
                        agentsSettings: AgentsAPISettings(model: "test-model", revision: "test"),
                        credentials: AgentsCredentials(applicationKey: "app-test-key", environmentKey: "env-test-key"))
    }
    private func client(scenario: StreamScenario, status: Int = 200) -> (AgentsAPIClient, TestExecutor, String, URL) {
        let host = "tars-test-" + UUID().uuidString.lowercased() + ".local"
        TestHTTP.shared.register(host: host, scenario: scenario, status: status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentsTestURLProtocol.self]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bindings = directory.appendingPathComponent("bindings.json")
        let executor = TestExecutor()
        return (AgentsAPIClient(session: URLSession(configuration: configuration), baseURL: URL(string: "https://\(host)/v1")!,
                                bindingsURL: bindings, executor: executor, resolveExecutor: { "/mock/codex" }), executor, host, directory)
    }
    private func collect(_ client: AgentsAPIClient, run: AgentRunRequest) async throws -> String {
        var result = ""
        for try await chunk in client.streamCompletion(run) { AgentTextUpdate.apply(chunk, to: &result) }
        return result
    }

    func testRealRESTShapeAndSessionReuseWithSeparateExecutorKey() async throws {
        let (client, executor, host, directory) = client(scenario: .success)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await collect(client, run: makeRun())
        XCTAssertEqual(result, "hello")
        let next = try await collect(client, run: makeRun(messages: [ChatMessage(role: .user, content: "next")]))
        XCTAssertEqual(next, "hello")
        let state = TestHTTP.shared.state(host: host)
        XCTAssertEqual(state.creates, 1)
        XCTAssertEqual(state.inputs, 2)
        XCTAssertEqual(executor.keys, ["env-test-key", "env-test-key"])
        for request in state.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer app-test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "agents=v1")
            XCTAssertFalse(request.url!.absoluteString.contains("app-test-key"))
        }
        let submits = state.requests.filter { $0.url!.path.hasSuffix("/events") && $0.httpMethod == "POST" }
        XCTAssertTrue(submits.allSatisfy { $0.value(forHTTPHeaderField: "Idempotency-Key") != nil })
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("bindings.json").path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue, 0o600)
    }

    func testIdleAndEOFAreNotSuccessAndSendCancellation() async throws {
        let (client, executor, host, directory) = client(scenario: .idleOnly)
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try await collect(client, run: makeRun()); XCTFail("EOF must fail without a terminal root turn") }
        catch { XCTAssertTrue(error.localizedDescription.contains("中断")) }
        XCTAssertTrue(executor.sessions.isEmpty)
        let requests = TestHTTP.shared.state(host: host).requests
        let cancellation = try XCTUnwrap(requests.last(where: { $0.httpMethod == "POST" }))
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(cancellation.httpBody)) as! [String: Any]
        XCTAssertEqual((body["events"] as! [[String: Any]])[0]["type"] as? String, "agent.session.input.cancel")
        // An unresolved prior turn blocks a new submission, including after client recreation.
        do { _ = try await collect(client, run: makeRun()); XCTFail("Uncertain input must not be replayed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("尚未确认")) }
        XCTAssertEqual(TestHTTP.shared.state(host: host).inputs, 1)
    }

    func testRetryRecoversAnUncertainCompletedSubmissionWithoutExecutingAgain() async throws {
        let (client, _, host, directory) = client(scenario: .idleOnly)
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try await collect(client, run: makeRun()); XCTFail("Expected uncertain result") }
        catch { XCTAssertTrue(error.localizedDescription.contains("中断")) }
        TestHTTP.shared.changeScenario(host: host, scenario: .success)
        let recovered = try await collect(client, run: makeRun())
        XCTAssertEqual(recovered, "hello")
        XCTAssertEqual(TestHTTP.shared.state(host: host).inputs, 1)
    }

    func testLegacyPendingInputSurvivesPersonalityUpdateWithoutReplay() async throws {
        let (client, _, host, directory) = client(scenario: .idleOnly)
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try await collect(client, run: makeRun()); XCTFail("Expected uncertain result") }
        catch { XCTAssertTrue(error.localizedDescription.contains("中断")) }

        // Simulate the saved digest from the previous app, before the style block existed.
        let legacyBody: [String: Any] = ["events": [["type": "agent.session.input.message",
            "input": [["role": "user", "content": [["type": "input_text", "text": "hello"]]]]]]]
        let data = try JSONSerialization.data(withJSONObject: legacyBody, options: .sortedKeys)
        let legacyDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let bindingsURL = directory.appendingPathComponent("bindings.json")
        var bindings = try JSONDecoder().decode([String: AgentsSessionBinding].self, from: Data(contentsOf: bindingsURL))
        bindings["conversation"]?.inputDigest = legacyDigest
        try JSONEncoder().encode(bindings).write(to: bindingsURL)

        TestHTTP.shared.changeScenario(host: host, scenario: .success)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentsTestURLProtocol.self]
        let restarted = AgentsAPIClient(session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://\(host)/v1")!, bindingsURL: bindingsURL,
            executor: TestExecutor(), resolveExecutor: { "/mock/codex" })
        let recovered = try await collect(restarted, run: makeRun())
        XCTAssertEqual(recovered, "hello")
        XCTAssertEqual(TestHTTP.shared.state(host: host).creates, 1)
        XCTAssertEqual(TestHTTP.shared.state(host: host).inputs, 1)
    }

    func testConversationMigrationKeepsOldHistoryAndBackends() async throws {
        let old = Conversation(title: "old", messages: [ChatMessage(role: .user, content: "history")])
        let encoded = try JSONEncoder().encode(old)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["assistantEngine"] = "openclaw"
        let restored = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.assistantEngine, .opencode)
        XCTAssertEqual(restored.messages[0].content, "history")
        object.removeValue(forKey: "assistantEngine")
        XCTAssertEqual(try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object)).assistantEngine, .opencode)
        var cloud = old
        cloud.assistantEngine = .agentsAPI
        XCTAssertEqual(try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(cloud)).assistantEngine, .agentsAPI)
    }

    func testUserCancellationStopsExecutorAndCancelsOnlyThatSession() async throws {
        let (client, executor, host, directory) = client(scenario: .stalled)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task { try await self.collect(client, run: self.makeRun()) }
        for _ in 0..<100 {
            if TestHTTP.shared.state(host: host).inputs == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(TestHTTP.shared.state(host: host).inputs, 1)
        task.cancel()
        _ = await task.result
        for _ in 0..<100 {
            if executor.sessions.isEmpty && TestHTTP.shared.state(host: host).requests.filter({ $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/events") }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(executor.sessions.isEmpty)
        let events = TestHTTP.shared.state(host: host).requests.filter { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/events") }
        XCTAssertEqual(events.count, 2)
        let last = try JSONSerialization.jsonObject(with: events.last!.httpBody!) as! [String: Any]
        XCTAssertEqual((last["events"] as! [[String: Any]])[0]["type"] as? String, "agent.session.input.cancel")
    }

    func testEOFFinalTurnRecoversSavedItemsWithoutResubmission() async throws {
        let (client, _, host, directory) = client(scenario: .recoverFromItems)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = try await collect(client, run: makeRun())
        XCTAssertEqual(text, "recovered")
        XCTAssertEqual(TestHTTP.shared.state(host: host).inputs, 1)
    }

    func testFailedTurnDoesNotBecomeSuccess() async throws {
        let (client, executor, _, directory) = client(scenario: .failed)
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try await collect(client, run: makeRun()); XCTFail("Expected root failure") }
        catch { XCTAssertEqual(error.localizedDescription, "test failure") }
        XCTAssertTrue(executor.sessions.isEmpty)
    }

    func testAuthenticationFailureDoesNotSpawnExecutorOrSendInput() async throws {
        let (client, executor, host, directory) = client(scenario: .success, status: 403)
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try await collect(client, run: makeRun()); XCTFail("403 must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("403")) }
        XCTAssertTrue(executor.keys.isEmpty)
        XCTAssertEqual(TestHTTP.shared.state(host: host).inputs, 0)
    }

    func testConversationIsolation() async throws {
        let (client, executor, host, directory) = client(scenario: .success)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await collect(client, run: makeRun(id: "first"))
        _ = try await collect(client, run: makeRun(id: "second"))
        XCTAssertEqual(TestHTTP.shared.state(host: host).creates, 2)
        XCTAssertEqual(executor.sessions.count, 2)
    }

    func testMultimodalDocumentsUsePathsAndOnlyLatestInputOnResume() async throws {
        let old = ChatMessage(role: .user, content: "OLD", documentPaths: ["/old/secret.txt"])
        let latest = ChatMessage(role: .user, content: "NEW", images: [Data([0xFF, 0xD8, 0xFF])], documentPaths: ["/new/report.pdf"])
        let body = AgentsAPIClient.messageBody([old, ChatMessage(role: .assistant, content: "previous"), latest], includeHistory: false)
        let event = (body["events"] as! [[String: Any]])[0]
        let input = (event["input"] as! [[String: Any]])[0]
        let content = input["content"] as! [[String: Any]]
        let text = content[0]["text"] as! String
        XCTAssertTrue(text.hasPrefix(TarsPersonality.clientContext))
        XCTAssertFalse(text.contains("OLD"))
        XCTAssertTrue(text.contains("/new/report.pdf"))
        XCTAssertTrue((content[1]["image_url"] as! String).hasPrefix("data:image/jpeg;base64,"))
        let bootstrap = AgentsAPIClient.messageBody([old, latest], includeHistory: true)
        XCTAssertTrue(String(data: try JSONSerialization.data(withJSONObject: bootstrap), encoding: .utf8)!.contains("OLD"))
    }

    func testReducerIgnoresChildAndOldTurnsAndDeduplicatesFinalText() async throws {
        var reducer = AgentsEventReducer(excludedTurns: ["old"])
        _ = try reducer.consume(["type": "agent.session.turn.completed", "turn": ["id": "old"]])
        XCTAssertFalse(reducer.completed)
        _ = try reducer.consume(["type": "agent.session.turn.created", "turn": ["id": "child", "subagent_id": "child-agent"]])
        XCTAssertNil(reducer.rootTurnID)
        _ = try reducer.consume(["type": "agent.session.turn.created", "turn": ["id": "root"]])
        let delta: [String: Any] = ["event_id": "delta1", "type": "agent.session.turn.output_text.delta", "turn_id": "root", "item_id": "a", "delta": "hello"]
        XCTAssertEqual(try reducer.consume(delta), "hello")
        XCTAssertEqual(try reducer.consume(delta), "")
        XCTAssertEqual(try reducer.consume(["type": "agent.session.turn.output_text.done", "turn_id": "root", "item_id": "a", "text": "hello"]), "")
        _ = try reducer.consume(["type": "agent.session.turn.completed", "turn": ["id": "child", "subagent_id": "child-agent"]])
        XCTAssertFalse(reducer.completed)
    }

    func testFinalTextCanReplaceTemporaryText() async throws {
        var reducer = AgentsEventReducer()
        _ = try reducer.consume(["type": "agent.session.turn.created", "turn": ["id": "root"]])
        var text = try reducer.consume(["type": "agent.session.turn.output_text.delta", "turn_id": "root", "item_id": "a", "delta": "temporary"])
        let replacement = try reducer.consume(["type": "agent.session.turn.output_text.done", "turn_id": "root", "item_id": "a", "text": "final"])
        AgentTextUpdate.apply(replacement, to: &text)
        XCTAssertEqual(text, "final")
    }

    func testRemovedRuntimeMigrationAndNativeConfiguration() async {
        for legacy in ["hermes", "openclaw", "none", "unknown"] { XCTAssertEqual(OnlineAIAgent.restored(legacy), .opencode) }
        XCTAssertEqual(OnlineAIAgent.restored("openai_agents"), .agentsAPI)
        var configuration = AgentConfiguration()
        configuration.skillsDirectory = "/skills"
        configuration.multiAgentEnabled = true
        configuration.mcpServers = [AgentMCPServer(name: "local", url: "http://localhost:9000/mcp")]
        var request = makeRun()
        request = AgentRunRequest(conversationID: request.conversationID, mode: request.mode, engine: request.engine,
                                  configuration: configuration, workingDirectory: request.workingDirectory,
                                  messages: request.messages, omittedCount: 0, ephemeral: false,
                                  agentsSettings: request.agentsSettings, credentials: request.credentials)
        let body = AgentsAPIClient.createBody(request)
        let agent = body["agent"] as! [String: Any]
        XCTAssertEqual((agent["multi_agent"] as! [String: Any])["max_concurrent_subagents"] as? Int, 4)
        XCTAssertEqual((agent["tools"] as! [[String: Any]])[0]["connection_origin"] as? String, "environment")
        XCTAssertEqual((body["environment"] as! [String: Any])["capability_directories"] as? [String], ["/skills"])
        let environment = AgentsExecutorManager.environment(executablePath: "/usr/bin/true", environmentKey: "env-only")
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertEqual(environment["CODEX_API_KEY"], "env-only")
    }
}
