import AppKit
import CryptoKit
import Foundation
import Observation
import Security

enum ChatGPTPlanError: LocalizedError {
    case message(String)
    case invalidGrant
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .invalidGrant: "ChatGPT 授权已失效，请重新登录；不会自动改用付费 API。"
        }
    }
    static func service(_ code: String) -> Self {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return .message("ChatGPT 订阅额度已用尽。请在 ChatGPT 设置 → Usage 查看额度或调整 Tars 的使用上限。")
        case "subscription_sharing_usage_unavailable": return .message("当前账号暂不可共享 ChatGPT 订阅额度，请在 ChatGPT 中检查授权和订阅状态。")
        case "invalid_grant": return .invalidGrant
        case "access_denied": return .message("你取消了 ChatGPT 授权。")
        default: return .message("ChatGPT 请求失败，请检查连接或重新授权（\(code.prefix(80))）。")
        }
    }
}

struct ChatGPTPlanModel: Identifiable, Codable, Sendable {
    var id: String { slug }
    let slug: String
    let display_name: String
    let visibility: String?
}

struct ChatGPTPlanAccount: Identifiable, Sendable {
    let id: String
    let label: String
    let connected: Bool
    let remoteRevocationPending: Bool
}

struct ChatGPTPlanRegistration: Codable, Sendable {
    var clientID: String
    var subject: String = ""
    var email: String = ""
    var accessToken: String = ""
    var refreshToken: String = ""
    var idToken: String = ""
    var scopes: String = ""
    var expiresAt: Date = .distantPast
    var earliestRefreshAt: Date?
    var remoteRevocationPending = false
    var canInvoke: Bool { !accessToken.isEmpty && scopes.split(separator: " ").contains("chatgpt.tokens.use.direct") }
}

enum ChatGPTPlanOAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ text: String) throws -> Data {
        var text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text) else { throw ChatGPTPlanError.message("授权令牌格式不正确。") }
        return data
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTPlanError.message("无法生成安全的登录请求。")
        }
        return base64URL(Data(bytes))
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
    static func issuedClient(callback: URLComponents, expectedState: String, returningClient: String?) throws -> String {
        let items = callback.queryItems ?? []
        func single(_ name: String) -> String? {
            let values = items.filter { $0.name == name }
            return values.count == 1 ? values[0].value : nil
        }
        guard single("state") == expectedState else { throw ChatGPTPlanError.message("登录回调校验失败，请重新登录。") }
        if let error = single("error") { throw ChatGPTPlanError.service(error) }
        guard let code = single("code"), !code.isEmpty else { throw ChatGPTPlanError.message("登录回调缺少授权码。") }
        if let returningClient {
            if items.contains(where: { $0.name == "client_id" }), single("client_id") != returningClient {
                throw ChatGPTPlanError.message("登录回调的应用注册不匹配。")
            }
            return returningClient
        }
        guard let client = single("client_id"), client.hasPrefix("oaiapp_"), client != "dynamic_agent_client" else {
            throw ChatGPTPlanError.message("OpenAI 尚未完成 Tars 的注册，请重新授权。")
        }
        return client
    }
    // Validate the signed identity before using its subject/email as an account key.
    static func verifyIDToken(_ token: String, jwks: Data, clientID: String, nonce: String?, now: Date = Date()) throws -> [String: Any] {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: Any],
              let kid = header["kid"] as? String,
              let keys = (try JSONSerialization.jsonObject(with: jwks) as? [String: Any])?["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid }) else {
            throw ChatGPTPlanError.message("无法验证 OpenAI 身份签名。")
        }
        let message = Data("\(parts[0]).\(parts[1])".utf8), signature = try decode(parts[2])
        let alg = header["alg"] as? String
        guard key["use"] == nil || key["use"] as? String == "sig",
              key["alg"] == nil || key["alg"] as? String == alg else { throw ChatGPTPlanError.message("身份签名密钥用途不匹配。") }
        if alg == "RS256", key["kty"] as? String == "RSA",
           let n = key["n"] as? String, let e = key["e"] as? String {
            func der(_ tag: UInt8, _ body: Data) -> Data {
                var size = body.count, bytes = [UInt8]()
                repeat { bytes.insert(UInt8(size & 255), at: 0); size >>= 8 } while size > 0
                let length = body.count < 128 ? Data([UInt8(body.count)]) : Data([0x80 | UInt8(bytes.count)] + bytes)
                return Data([tag]) + length + body
            }
            func integer(_ bytes: Data) -> Data { der(0x02, bytes.first.map { $0 & 0x80 != 0 } == true ? Data([0]) + bytes : bytes) }
            let modulus = try decode(n), exponent = try decode(e)
            let rsa = der(0x30, integer(modulus) + integer(exponent))
            let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits as String: modulus.count * 8]
            guard let publicKey = SecKeyCreateWithData(rsa as CFData, attributes as CFDictionary, nil),
                  SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil) else {
                throw ChatGPTPlanError.message("OpenAI 身份签名验证失败。")
            }
        } else if alg == "ES256", key["kty"] as? String == "EC", key["crv"] as? String == "P-256",
                  let x = key["x"] as? String, let y = key["y"] as? String {
            let publicKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + decode(x) + decode(y))
            guard publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: message) else {
                throw ChatGPTPlanError.message("OpenAI 身份签名验证失败。")
            }
        } else { throw ChatGPTPlanError.message("不支持的 OpenAI 身份签名算法。") }
        guard let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any],
              claims["iss"] as? String == issuer,
              (claims["aud"] as? String == clientID || (claims["aud"] as? [String])?.contains(clientID) == true),
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970,
              let issued = claims["iat"] as? Double, issued <= now.timeIntervalSince1970 + 60,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              nonce == nil || claims["nonce"] as? String == nonce else {
            throw ChatGPTPlanError.message("OpenAI 身份令牌已过期或不属于这次登录。")
        }
        if let audiences = claims["aud"] as? [String], audiences.count > 1,
           claims["azp"] as? String != clientID { throw ChatGPTPlanError.message("身份令牌的授权应用不匹配。") }
        if let azp = claims["azp"] as? String, azp != clientID { throw ChatGPTPlanError.message("身份令牌的授权应用不匹配。") }
        if let nbf = claims["nbf"] as? Double, nbf > now.timeIntervalSince1970 + 60 { throw ChatGPTPlanError.message("身份令牌尚未生效。") }
        return claims
    }
}

enum ChatGPTPlanKeychain {
    static func hostID() throws -> String {
        var query = base; query[kSecAttrAccount as String] = "host-id"
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8), value.hasPrefix("urn:uuid:") { return value }
        guard status == errSecItemNotFound else { throw ChatGPTPlanError.message("无法读取本机授权标识（\(status)）。") }
        let value = "urn:uuid:\(UUID().uuidString.lowercased())"
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let saved = SecItemAdd(query as CFDictionary, nil)
        guard saved == errSecSuccess else { throw ChatGPTPlanError.message("无法保存本机授权标识（\(saved)）。") }
        return value
    }
    static func read() throws -> [ChatGPTPlanRegistration] {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = item as? Data else { throw ChatGPTPlanError.message("无法读取 ChatGPT 钥匙串（\(status)）。") }
        return try JSONDecoder().decode([ChatGPTPlanRegistration].self, from: data)
    }
    private static var base: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.nousresearch.hermespet.chatgpt-plan", kSecAttrAccount as String: "registrations"] }
    static func save(_ registrations: [ChatGPTPlanRegistration]) throws {
        let attributes = [kSecValueData as String: try JSONEncoder().encode(registrations)]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = base.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ChatGPTPlanError.message("无法保存 ChatGPT 钥匙串（\(status)）。") }
    }
}

@MainActor @Observable
final class ChatGPTPlanAuth {
    static let shared = ChatGPTPlanAuth()
    var accounts: [ChatGPTPlanAccount] = []
    var models: [ChatGPTPlanModel] = []
    var busy = false
    var errorMessage: String?
    var activeAccountID: String {
        didSet {
            UserDefaults.standard.set(activeAccountID, forKey: "chatGPTPlan.activeAccount")
            models = []
            NotificationCenter.default.post(name: .init("TarsChatGPTAccountChanged"), object: nil)
        }
    }
    var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "chatGPTPlan.model") }
    }
    @ObservationIgnored private var registrations: [ChatGPTPlanRegistration] = []
    @ObservationIgnored private var refreshTasks: [String: Task<String, Error>] = [:]
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var callback: ChatGPTLoginCallback?
    @ObservationIgnored private var disconnectingAccountID: String?
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral, delegate: ChatGPTPlanHTTPDelegate(), delegateQueue: nil)
    private init() {
        activeAccountID = UserDefaults.standard.string(forKey: "chatGPTPlan.activeAccount") ?? ""
        selectedModel = UserDefaults.standard.string(forKey: "chatGPTPlan.model") ?? ""
        do { registrations = try ChatGPTPlanKeychain.read(); publish() }
        catch { errorMessage = error.localizedDescription }
    }
    var isConnected: Bool { accounts.first(where: { $0.id == activeAccountID })?.connected == true }
    var activeLabel: String { accounts.first(where: { $0.id == activeAccountID })?.label ?? "未登录" }
    func requireSelection() throws -> (accountID: String, model: String) {
        guard isConnected else { throw ChatGPTPlanError.message("请在设置中使用 ChatGPT 登录并授权订阅额度。") }
        guard !selectedModel.isEmpty else { throw ChatGPTPlanError.message("请在 ChatGPT 订阅设置中刷新并选择模型。") }
        return (activeAccountID, selectedModel)
    }
    private func publish() {
        accounts = registrations.map { .init(id: $0.clientID, label: ($0.email.isEmpty ? "待完成授权" : $0.email) + " · \($0.clientID.suffix(6))",
            connected: $0.canInvoke && (!$0.refreshToken.isEmpty || $0.expiresAt > Date()), remoteRevocationPending: $0.remoteRevocationPending) }
    }
    private func persist(_ new: [ChatGPTPlanRegistration]) throws {
        try ChatGPTPlanKeychain.save(new); registrations = new; publish()
    }
    func cancelLogin() { loginTask?.cancel(); callback?.cancel() }
    func signIn(accountID: String? = nil, browserBundleID: String? = nil) {
        guard !busy else { return }
        busy = true; errorMessage = nil
        loginTask = Task {
            defer { callback?.cancel(); callback = nil; busy = false; loginTask = nil }
            do {
                if let accountID, let refresh = refreshTasks[accountID] { _ = try? await refresh.value }
                try Task.checkCancellation()
                let discovery = try await discovery()
                let returning = registrations.first(where: { $0.clientID == accountID })
                let state = try ChatGPTPlanOAuth.random(), nonce = try ChatGPTPlanOAuth.random(), verifier = try ChatGPTPlanOAuth.random()
                let server = ChatGPTLoginCallback(state: state); callback = server
                let redirect = try await server.start()
                let hostID = try ChatGPTPlanKeychain.hostID()
                var values = ["client_id": returning?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                    "response_type": "code", "redirect_uri": redirect, "scope": ChatGPTPlanOAuth.scopes,
                    "resource": ChatGPTPlanOAuth.resource, "state": state, "nonce": nonce,
                    "code_challenge": ChatGPTPlanOAuth.challenge(verifier), "code_challenge_method": "S256"]
                if returning == nil { values["agent_name_hint"] = "tars" }
                else if let returning {
                    if !returning.idToken.isEmpty { values["id_token_hint"] = returning.idToken }
                    if !returning.email.isEmpty { values["login_hint"] = returning.email }
                }
                var authorize = URLComponents(url: try endpoint(discovery, "authorization_endpoint"), resolvingAgainstBaseURL: false)!
                authorize.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
                guard let url = authorize.url else { throw ChatGPTPlanError.message("无法生成登录地址。") }
                if let browserBundleID {
                    guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserBundleID) else { throw ChatGPTPlanError.message("未找到所选浏览器，请使用默认浏览器登录。") }
                    _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
                } else if !NSWorkspace.shared.open(url) { throw ChatGPTPlanError.message("无法打开浏览器，请检查默认浏览器设置。") }
                let response = try await server.waitForCallback()
                try Task.checkCancellation()
                let client = try ChatGPTPlanOAuth.issuedClient(callback: response, expectedState: state, returningClient: returning?.clientID)
                if !registrations.contains(where: { $0.clientID == client }) {
                    try persist(registrations + [ChatGPTPlanRegistration(clientID: client)])
                }
                let code = response.queryItems!.first(where: { $0.name == "code" })!.value!
                let token = try await tokenRequest(discovery, fields: ["grant_type": "authorization_code", "client_id": client,
                    "code": code, "code_verifier": verifier, "redirect_uri": redirect, "resource": ChatGPTPlanOAuth.resource])
                try await saveToken(token, clientID: client, nonce: nonce, discovery: discovery)
                activeAccountID = client
                try await loadModels()
                if !isConnected { errorMessage = "已登录，但未授予订阅额度权限。请重新授权并勾选订阅使用权限。" }
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
    private func discovery() async throws -> [String: Any] {
        let data = try await get(URL(string: "\(ChatGPTPlanOAuth.issuer)/.well-known/openid-configuration")!)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["issuer"] as? String == ChatGPTPlanOAuth.issuer else {
            throw ChatGPTPlanError.message("OpenAI 登录服务身份不匹配。")
        }
        return value
    }
    private func endpoint(_ discovery: [String: Any], _ key: String) throws -> URL {
        guard let raw = discovery[key] as? String, let url = URL(string: raw), url.scheme == "https", url.host == "auth.openai.com", url.user == nil, url.password == nil else {
            throw ChatGPTPlanError.message("OpenAI 登录服务地址无效。")
        }
        return url
    }
    private func get(_ url: URL, token: String? = nil) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 30
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await send(request)
    }
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTPlanError.message("OpenAI 返回了无效响应。") }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = json?["error"] as? String ?? (json?["error"] as? [String: Any])?["code"] as? String
            throw ChatGPTPlanError.service(code ?? "HTTP \(http.statusCode)")
        }
        return data
    }
    private func tokenRequest(_ discovery: [String: Any], fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: try endpoint(discovery, "token_endpoint")); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = ChatGPTPlanOAuth.form(fields)
        let data = try await send(request)
        guard let token = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatGPTPlanError.message("OpenAI 返回了无效令牌。") }
        return token
    }
    private func saveToken(_ token: [String: Any], clientID: String, nonce: String?, discovery: [String: Any]) async throws {
        guard let access = token["access_token"] as? String, !access.isEmpty,
              (token["token_type"] as? String)?.lowercased() == "bearer", let expires = token["expires_in"] as? Double, expires > 0 else {
            throw ChatGPTPlanError.message("OpenAI 返回的访问令牌不完整。")
        }
        var account = registrations.first(where: { $0.clientID == clientID }) ?? .init(clientID: clientID)
        if let idToken = token["id_token"] as? String {
            let jwks = try await get(endpoint(discovery, "jwks_uri"))
            let claims = try ChatGPTPlanOAuth.verifyIDToken(idToken, jwks: jwks, clientID: clientID, nonce: nonce)
            let subject = claims["sub"] as! String
            guard account.subject.isEmpty || account.subject == subject else { throw ChatGPTPlanError.message("重新授权的账号与原对话账号不匹配，请添加新账号。") }
            account.subject = subject; account.email = claims["email"] as? String ?? account.email; account.idToken = idToken
        } else if nonce != nil { throw ChatGPTPlanError.message("登录响应缺少可验证的身份令牌。") }
        account.accessToken = access; account.expiresAt = Date().addingTimeInterval(expires)
        if let timestamp = token["earliest_refresh_at"] as? Double {
            account.earliestRefreshAt = Date(timeIntervalSince1970: timestamp > 1e12 ? timestamp / 1000 : timestamp)
        } else if let text = token["earliest_refresh_at"] as? String { account.earliestRefreshAt = ISO8601DateFormatter().date(from: text) }
        else { account.earliestRefreshAt = nil }
        account.scopes = token["scope"] as? String ?? (nonce == nil ? account.scopes : "")
        account.refreshToken = token["refresh_token"] as? String ?? account.refreshToken
        account.remoteRevocationPending = false
        // Persist the complete rotation atomically, before publishing the new token.
        var next = registrations.filter { $0.clientID != clientID }; next.append(account); try persist(next)
    }
    func accessToken(accountID: String) async throws -> String {
        guard disconnectingAccountID != accountID else { throw ChatGPTPlanError.message("此账号正在退出登录。") }
        if let task = refreshTasks[accountID] { return try await task.value }
        guard let account = registrations.first(where: { $0.clientID == accountID }), account.canInvoke else { throw ChatGPTPlanError.message("此对话的 ChatGPT 账号未授权，请在设置中重新登录该账号。") }
        if account.expiresAt.timeIntervalSinceNow > 120 { return account.accessToken }
        if let earliest = account.earliestRefreshAt, earliest > Date() {
            guard account.expiresAt > Date() else { throw ChatGPTPlanError.message("暂未到授权刷新时间，请稍后重新连接。") }
            return account.accessToken
        }
        guard loginTask == nil else { throw ChatGPTPlanError.message("正在重新授权，请等待登录完成。") }
        guard !account.refreshToken.isEmpty else { throw ChatGPTPlanError.message("ChatGPT 授权已过期，请重新登录。") }
        let task = Task { @MainActor in
            do {
                let discovery = try await self.discovery()
                let token = try await self.tokenRequest(discovery, fields: ["grant_type": "refresh_token", "client_id": accountID,
                    "refresh_token": account.refreshToken, "resource": ChatGPTPlanOAuth.resource])
                try await self.saveToken(token, clientID: accountID, nonce: nil, discovery: discovery)
                guard let refreshed = self.registrations.first(where: { $0.clientID == accountID }), refreshed.canInvoke else { throw ChatGPTPlanError.message("订阅使用授权已被撤销，请重新授权。") }
                return refreshed.accessToken
            } catch ChatGPTPlanError.invalidGrant {
                var cleared = account; cleared.accessToken = ""; cleared.refreshToken = ""; cleared.scopes = ""; cleared.expiresAt = .distantPast
                try self.persist(self.registrations.map { $0.clientID == accountID ? cleared : $0 })
                throw ChatGPTPlanError.invalidGrant
            }
        }
        refreshTasks[accountID] = task
        defer { refreshTasks.removeValue(forKey: accountID) }
        return try await task.value
    }
    func loadModels() async throws {
        let account = activeAccountID
        let token = try await accessToken(accountID: account)
        let data = try await get(URL(string: "\(ChatGPTPlanOAuth.resource)/models")!, token: token)
        struct Catalog: Decodable { let models: [ChatGPTPlanModel] }
        let choices = try JSONDecoder().decode(Catalog.self, from: data).models.filter { $0.visibility == "list" }
        guard account == activeAccountID else { return }
        models = choices
        if !choices.contains(where: { $0.slug == selectedModel }) { selectedModel = choices.first?.slug ?? "" }
        guard !choices.isEmpty else { throw ChatGPTPlanError.message("此账号暂未返回可用模型，请检查订阅共享权限。") }
    }
    func disconnect() async {
        guard !busy, let original = registrations.first(where: { $0.clientID == activeAccountID }) else { return }
        busy = true; errorMessage = nil
        disconnectingAccountID = original.clientID
        defer { busy = false; disconnectingAccountID = nil }
        refreshTasks[original.clientID]?.cancel()
        _ = try? await refreshTasks[original.clientID]?.value
        let account = registrations.first(where: { $0.clientID == original.clientID }) ?? original
        NotificationCenter.default.post(name: .init("TarsChatGPTDisconnect"), object: nil, userInfo: ["accountID": account.clientID])
        var confirmed = account.refreshToken.isEmpty
        if !account.refreshToken.isEmpty {
            for attempt in 0..<3 {
                do {
                    let discovery = try await discovery()
                    var request = URLRequest(url: try endpoint(discovery, "revocation_endpoint")); request.httpMethod = "POST"; request.timeoutInterval = 15
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    request.httpBody = ChatGPTPlanOAuth.form(["token": account.refreshToken, "token_type_hint": "refresh_token", "client_id": account.clientID])
                    _ = try await send(request); confirmed = true; break
                } catch { if attempt < 2 { try? await Task.sleep(for: .seconds(attempt + 1)) } }
            }
        }
        var cleared = account; cleared.accessToken = ""; cleared.refreshToken = ""; cleared.idToken = ""; cleared.scopes = ""; cleared.expiresAt = .distantPast; cleared.remoteRevocationPending = !confirmed
        do { try persist(registrations.map { $0.clientID == account.clientID ? cleared : $0 }); models = [] }
        catch { errorMessage = error.localizedDescription; return }
        if !confirmed { errorMessage = "已清除本机凭据，远端撤销尚未确认。请在 ChatGPT 设置中断开 Tars。" }
    }
}

private final class ChatGPTPlanHTTPDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
