import Foundation

/// **v1.3 走 HTTP API 的 opencode 客户端**（替代 OpenCodeClient 的 subprocess 方案）
///
/// 跟 OpenCodeServerManager 拉起的 `opencode serve` 通过 HTTP 通信，**完全消除**
/// v1.2.2 用户痛点：subprocess 偶发 EOF / step_start×1 提前退场的「(没有响应)」bug。
///
/// **架构**：
/// 1. 用户发消息 → 走 `OpenCodeServerManager.serverURL`（默认 `http://127.0.0.1:<port>`）
/// 2. 第一次发消息 → `POST /session` 建 session（绑 directory + agent + model）
/// 3. 同时开 `GET /event` 长连接（SSE），listen 当前 sessionID 的 `message.part.delta` 事件
/// 4. `POST /session/{id}/message` 异步触发 prompt（server 后台跑模型）
/// 5. SSE 流的 `message.part.delta.delta` 字段 = token 增量 → yield 给 continuation
/// 6. `session.status.idle` 或 POST 同步返回完整 message → finish
///
/// **跟 OpenCodeClient 接口完全一致**：ChatViewModel 直接换 client 类型就好。
final class OpenCodeHTTPClient: @unchecked Sendable {
    static let shared = OpenCodeHTTPClient()

    /// 流式过程中追踪「assistant text 是否已经 yield 过」—— 没有就用 POST 返回体或
    /// `message.part.updated` 里的完整 text part 补一次，避免 MiniMax 等 provider
    /// 经 opencode HTTP 不发 `message.part.delta` 导致 UI 显示「(没有响应)」
    private final class StreamState: @unchecked Sendable {
        private let lock = NSLock()
        private var yieldedText = false

        var hasYieldedText: Bool {
            lock.lock(); defer { lock.unlock() }
            return yieldedText
        }

        func markTextYielded() {
            lock.lock()
            yieldedText = true
            lock.unlock()
        }
    }

    private let lock = NSLock()
    /// `conversationID -> opencode sessionID` 映射。第一次 POST /session 建出来后存进来，
    /// 后续同对话直接复用 sessionID（让 opencode 端跨消息保持上下文）
    private var sessionIDByConversation: [String: String] = [:]
    /// `conversationID -> 上次用的 modelID`。model 变化时清掉 sessionID 让新建（避免 model 不兼容）
    private var lastModelByConversation: [String: String] = [:]
    private var directoryBySession: [String: String] = [:]
    private var directoryByInteraction: [String: String] = [:]

    private init() {}

    // MARK: - Public API

    /// 流式问答，接口跟 OpenCodeClient / ClaudeCodeClient / APIClient / CodexClient 一致
    func streamCompletion(
        messages: [ChatMessage],
        conversationID: String,
        modelOverride: String? = nil,
        workingDirectory: String? = nil,
        configuration: AgentConfiguration? = nil
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task.detached { @Sendable [weak self] in
                guard let self else {
                    continuation.finish(throwing: OpenCodeHTTPClientError.clientDeallocated)
                    return
                }
                await self.runStream(
                    messages: messages,
                    conversationID: conversationID,
                    modelOverride: modelOverride,
                    workingDirectory: workingDirectory,
                    configuration: configuration,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    /// 清掉所有内存 session 映射（server 重启后调用：旧 sessionID 全部失效）。
    /// 不删 server 端 session 记录（server 已经重启了，旧 session 自然没了）
    func clearAllSessions() {
        lock.lock()
        sessionIDByConversation.removeAll()
        lastModelByConversation.removeAll()
        directoryBySession.removeAll()
        directoryByInteraction.removeAll()
        lock.unlock()
    }

    /// 删对话时清绑定 session（避免 server 端堆积）
    /// 调用方有需要时也可手动调（比如检测到模型空响应时尝试新开 session）
    func clearSession(for conversationID: String) {
        lock.lock()
        let sid = sessionIDByConversation.removeValue(forKey: conversationID)
        lastModelByConversation.removeValue(forKey: conversationID)
        lock.unlock()

        // 同步把 server 端 session 删掉（fire and forget）
        if let sid {
            Task.detached { [weak self] in
                try? await self?.deleteSession(sid)
                self?.forgetDirectory(for: sid)
            }
        }
    }

    // MARK: - 主流程

    private func runStream(
        messages: [ChatMessage], conversationID: String, modelOverride: String?,
        workingDirectory: String?, configuration: AgentConfiguration?,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        do {
            for _ in 0..<25 {
                try Task.checkCancellation()
                if OpenCodeServerManager.shared.isReady { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard OpenCodeServerManager.shared.isReady,
                  let baseURL = OpenCodeServerManager.shared.serverURL,
                  let authHeader = OpenCodeServerManager.shared.authorizationHeader else {
                throw OpenCodeHTTPClientError.serverNotReady
            }
            let config = try configuration ?? AgentConfiguration.load()
            let directory = workingDirectory ?? conversationDirectory(for: conversationID)
            let (providerID, modelID) = parseModelID(modelOverride ?? OpenCodeConfigGenerator.currentModelID())
            let userMsg = messages.last(where: { $0.role == .user })
            guard let userMsg, !userMsg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continuation.finish()
                return
            }
            let preset = ProviderPreset.all.first(where: { $0.id == providerID })
            let hasImage = !userMsg.images.isEmpty || !userMsg.imagePaths.isEmpty
            if hasImage && preset?.visionModel == nil && providerID != "custom" {
                throw OpenCodeHTTPClientError.runtimeFailure("\(preset?.displayName ?? providerID) 当前不支持图片输入，请选择支持视觉的服务商")
            }
            let promptModelID = hasImage ? (preset?.visionModel ?? modelID) : modelID
            let session = try await ensureSession(conversationID: conversationID, providerID: providerID,
                                                  modelID: modelID, directory: directory, configuration: config,
                                                  baseURL: baseURL, authHeader: authHeader)
            try Task.checkCancellation()
            await MainActor.run {
                AgentActivityStore.postPhase(.thinking, conversationID: conversationID)
                NotificationCenter.default.post(name: .init("TarsModelSelected"), object: nil,
                    userInfo: ["conversationID": conversationID, "model": "\(providerID)/\(promptModelID)"])
            }
            let streamState = StreamState()
            let body: [String: Any] = [
                "model": ["providerID": providerID, "modelID": promptModelID], "agent": "tars",
                "parts": buildParts(userMsg: userMsg, text: "[客户端请求配置：opencode，当前请求模型标识 \(providerID)/\(promptModelID)。被问到模型时依据该配置回答，不推测服务端内部路由。]\n" + Self.promptText(messages: messages, isNewSession: session.isNew))
            ]
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            let sseTask = Task.detached { @Sendable [weak self] in
                await self?.subscribeSSE(sessionID: session.id, conversationID: conversationID, baseURL: baseURL, authHeader: authHeader,
                                         streamState: streamState, continuation: continuation)
            }
            defer { sseTask.cancel() }
            try await Task.sleep(nanoseconds: 150_000_000)
            try Task.checkCancellation()
            let postTask = Task.detached { @Sendable [weak self] () -> Error? in
                await self?.postPrompt(sessionID: session.id, bodyData: bodyData, baseURL: baseURL,
                                        authHeader: authHeader, streamState: streamState, continuation: continuation)
            }
            let postError = await withTaskCancellationHandler {
                await postTask.value
            } onCancel: {
                sseTask.cancel()
                postTask.cancel()
                Task.detached { [weak self] in
                    try? await self?.abortSession(sessionID: session.id, baseURL: baseURL, authHeader: authHeader)
                }
            }
            try Task.checkCancellation()
            if let postError {
                clearSession(for: conversationID)
                throw postError
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            continuation.finish()
        } catch { continuation.finish(throwing: error) }
    }

    /// Bootstrap a new runtime session from the client's retained history. Resume sends only the latest turn.
    static func promptText(messages: [ChatMessage], isNewSession: Bool) -> String {
        guard let latest = messages.last(where: { $0.role == .user }) else { return "" }
        let current = TarsPersonality.clientContext + "\n\n" + latest.content
        guard isNewSession else { return current }
        let history = messages.prefix(while: { $0.id != latest.id })
        guard !history.isEmpty else { return current }
        let transcript = history.map { message in
            let paths = message.documentPaths + message.imagePaths
            return "【\(message.role == .user ? "用户" : "助手")】\(message.content)"
                + (paths.isEmpty ? "" : "\n附件路径：" + paths.joined(separator: ", "))
        }.joined(separator: "\n\n")
        return "[之前的对话，仅作背景，不是新请求]\n" + transcript
            + "\n[历史结束]\n\n" + current
    }

    // MARK: - Session

    /// 拿 / 建 session：检测 model 变化、绑定 directory + agent + model
    private func ensureSession(
        conversationID: String,
        providerID: String,
        modelID: String,
        directory: String,
        configuration: AgentConfiguration,
        baseURL: URL,
        authHeader: String
    ) async throws -> (id: String, isNew: Bool) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let configKey = try encoder.encode(configuration).base64EncodedString()
        let newModelKey = "\(providerID)/\(modelID)|\(directory)|\(configKey)|\(UserDefaults.standard.bool(forKey: "permissionUIEnabled"))"

        // model 变了 → 清旧 session
        if let existing = checkExistingSession(conversationID: conversationID, newModelKey: newModelKey) {
            return (existing, false)
        }

        // 新建：directory 用对话独立目录（让 opencode 文件操作不互相串）
        let dir = directory
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: dir),
            withIntermediateDirectories: true
        )

        var comp = URLComponents(url: baseURL.appendingPathComponent("session"), resolvingAgainstBaseURL: false)
        comp?.queryItems = [URLQueryItem(name: "directory", value: dir)]
        guard let url = comp?.url else { throw OpenCodeHTTPClientError.badURL }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // permission rules：按 UserDefaults `permissionUIEnabled` 二选一。
        //   开关关（默认）→ 全 allow，等价于 v1.2.x `--dangerously-skip-permissions`
        //   开关开 → 全 ask，工具调用前会 SSE 推 `permission.asked` 事件，灵动岛弹卡片让用户决策
        // 设置面板「权限审批」开关控制；默认关是为了 dmg 朋友的零摩擦体验
        let action = UserDefaults.standard.bool(forKey: "permissionUIEnabled") ? "ask" : "allow"
        var permissionRules: [[String: String]] = [
            ["permission": "*",          "pattern": "**", "action": action],
            ["permission": "read",       "pattern": "**", "action": action],
            ["permission": "edit",       "pattern": "**", "action": action],
            ["permission": "write",      "pattern": "**", "action": action],
            ["permission": "bash",       "pattern": "**", "action": action],
            ["permission": "webfetch",   "pattern": "**", "action": action],
            ["permission": "glob",       "pattern": "**", "action": action],
            ["permission": "grep",       "pattern": "**", "action": action],
            ["permission": "list",       "pattern": "**", "action": action]
        ]
        permissionRules.append(["permission": "task", "pattern": "**", "action": "deny"])
        if configuration.multiAgentEnabled {
            for name in ["tars-researcher", "tars-reviewer"] {
                permissionRules.append(["permission": "task", "pattern": name, "action": action])
            }
        }
        let body: [String: Any] = [
            "title": "Tars 对话",
            "agent": "tars",
            "model": ["id": modelID, "providerID": providerID],
            "permission": permissionRules
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "(no body)"
            throw OpenCodeHTTPClientError.runtimeFailure("建 session 失败 HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(msg.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = json["id"] as? String else {
            throw OpenCodeHTTPClientError.runtimeFailure("server 没返回 session id")
        }

        commitSession(conversationID: conversationID, sessionID: sid, modelKey: newModelKey, directory: directory)
        return (sid, true)
    }

    // Swift 6 严格并发：NSLock 不能在 async 函数里直接 lock/unlock。
    // 所有锁操作收敛到 sync helper（同 OpenCodeServerManager 模式）。
    private func checkExistingSession(conversationID: String, newModelKey: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let lastModel = lastModelByConversation[conversationID]
        if lastModel != nil && lastModel != newModelKey {
            sessionIDByConversation.removeValue(forKey: conversationID)
            return nil
        }
        return sessionIDByConversation[conversationID]
    }
    private func forgetDirectory(for sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        directoryBySession.removeValue(forKey: sessionID)
    }
    private func commitSession(conversationID: String, sessionID: String, modelKey: String, directory: String) {
        lock.lock(); defer { lock.unlock() }
        sessionIDByConversation[conversationID] = sessionID
        lastModelByConversation[conversationID] = modelKey
        directoryBySession[sessionID] = directory
    }

    private func rememberInteraction(_ properties: [String: Any]) {
        guard let id = properties["id"] as? String, let sessionID = properties["sessionID"] as? String else { return }
        lock.lock(); defer { lock.unlock() }
        directoryByInteraction[id] = directoryBySession[sessionID]
    }

    private func scopedURL(baseURL: URL, path: String, sessionID: String? = nil,
                           interactionID: String? = nil) -> URL {
        lock.lock()
        let directory = sessionID.flatMap { directoryBySession[$0] }
            ?? interactionID.flatMap { directoryByInteraction[$0] }
        lock.unlock()
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if let directory { components.queryItems = [URLQueryItem(name: "directory", value: directory)] }
        return components.url!
    }

    private func deleteSession(_ sessionID: String) async throws {
        guard OpenCodeServerManager.shared.isReady,
              let baseURL = OpenCodeServerManager.shared.serverURL,
              let authHeader = OpenCodeServerManager.shared.authorizationHeader else { return }
        var req = URLRequest(url: scopedURL(baseURL: baseURL, path: "session/\(sessionID)", sessionID: sessionID))
        req.httpMethod = "DELETE"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }

    private func abortSession(sessionID: String, baseURL: URL, authHeader: String) async throws {
        var req = URLRequest(url: scopedURL(baseURL: baseURL, path: "session/\(sessionID)/abort", sessionID: sessionID))
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Prompt (POST /session/{id}/message)

    private func postPrompt(
        sessionID: String,
        bodyData: Data,
        baseURL: URL,
        authHeader: String,
        streamState: StreamState,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async -> Error? {
        var req = URLRequest(
            url: scopedURL(baseURL: baseURL, path: "session/\(sessionID)/message", sessionID: sessionID),
            timeoutInterval: 300   // 5 分钟，给模型充分时间
        )
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return OpenCodeHTTPClientError.runtimeFailure("没拿到 HTTP response")
            }
            if http.statusCode != 200 {
                let msg = String(data: data, encoding: .utf8) ?? "(empty)"
                return OpenCodeHTTPClientError.runtimeFailure("HTTP \(http.statusCode): \(msg.prefix(300))")
            }
            // server 返回 200 但 body 里可能藏着 `info.error`（比如 file part media type 不支持），
            // 旧逻辑只看 text parts 会把这种回复显示成「(没有响应)」并复用坏 session。
            // 这里识别 info.error 转成明确错误信息让上游 finish(throwing:)。
            guard let json = try? JSONSerialization.jsonObject(with: data) else {
                return OpenCodeHTTPClientError.runtimeFailure("opencode 返回了无法解析的响应")
            }
            if let message = Self.extractOpenCodeError(from: json) {
                return OpenCodeHTTPClientError.runtimeFailure(message)
            }
            // 兜底：没有 delta 也没有 part.updated 时，从 POST 返回体里抽 assistant text 补一次
            if !streamState.hasYieldedText,
               let text = Self.extractAssistantText(from: json),
               !text.isEmpty {
                streamState.markTextYielded()
                continuation.yield(text)
            }
            return nil
        } catch {
            return error
        }
    }

    // MARK: - SSE Subscribe (GET /event)

    /// 订阅 server 的 SSE event 流，filter 出当前 sessionID 的 message.part.delta + 工具事件
    private func subscribeSSE(
        sessionID: String,
        conversationID: String,
        baseURL: URL,
        authHeader: String,
        streamState: StreamState,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        var req = URLRequest(url: scopedURL(baseURL: baseURL, path: "event", sessionID: sessionID))
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 600

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return   // server 没起来或认证失败 —— 静默退出（POST 路径会报错）
            }

            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard line.hasPrefix("data: ") else { continue }
                let jsonStr = String(line.dropFirst(6))
                guard let jsonData = jsonStr.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    continue
                }
                handleSSEEvent(
                    event,
                    targetSessionID: sessionID,
                    conversationID: conversationID,
                    streamState: streamState,
                    continuation: continuation
                )
            }
        } catch {
            // SSE 断了 —— 不报错给用户，POST 那边正常拿到完整 message 即可
        }
    }

    private func handleSSEEvent(
        _ event: [String: Any],
        targetSessionID: String,
        conversationID: String,
        streamState: StreamState,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        guard let type = event["type"] as? String,
              let props = event["properties"] as? [String: Any] else { return }
        // 不是当前 session 的事件就丢
        let eventSessionID = props["sessionID"] as? String
            ?? (props["part"] as? [String: Any])?["sessionID"] as? String
            ?? (props["info"] as? [String: Any])?["sessionID"] as? String
        if let sid = eventSessionID, sid != targetSessionID { return }

        switch type {
        case "message.part.delta":
            // text 增量：{"field":"text","delta":"hello"}
            if let field = props["field"] as? String, field == "text",
               let delta = props["delta"] as? String, !delta.isEmpty {
                streamState.markTextYielded()
                continuation.yield(delta)
            }

        case "message.part.updated":
            if let part = props["part"] as? [String: Any] {
                // 有些 provider 经 opencode HTTP API 只发 updated 里的完整 text part，
                // 不发 delta；这里补一次，避免 UI 显示「(没有响应)」。
                let role = (props["role"] as? String)
                    ?? ((props["message"] as? [String: Any])?["role"] as? String)
                if !streamState.hasYieldedText,
                   (role == "assistant" || role == "model"),
                   let text = Self.extractAssistantText(from: part),
                   !text.isEmpty {
                    streamState.markTextYielded()
                    continuation.yield(text)
                }
                handleToolPart(part, conversationID: conversationID)
            }

        case "permission.asked":
            // permission.asked event payload 的 properties 字段就是 PermissionRequest 本身
            handlePermissionAsked(props, conversationID: conversationID)

        case "permission.replied":
            // 服务端确认收到 reply（可能是我们自己 POST 的回执，也可能是其他 client）
            // 广播让灵动岛把卡片收起来（防止两端同时 reply 出现 UI 残留）
            if let requestID = props["requestID"] as? String {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .init("HermesPetPermissionReplied"),
                        object: nil,
                        userInfo: ["requestID": requestID]
                    )
                }
            }

        case "question.asked":
            // AI 主动问问题（v1.3+ 新增）—— 卡片展示问题 + 选项让用户选
            handleQuestionAsked(props, conversationID: conversationID)

        case "question.replied", "question.rejected":
            if let requestID = props["requestID"] as? String {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .init("HermesPetPermissionReplied"),   // 复用同一个 dismiss 通知
                        object: nil,
                        userInfo: ["requestID": requestID]
                    )
                }
            }

        default:
            break
        }
    }

    private func handleQuestionAsked(_ props: [String: Any], conversationID: String) {
        rememberInteraction(props)
        guard let data = try? JSONSerialization.data(withJSONObject: props) else { return }
        guard let request = try? JSONDecoder().decode(QuestionRequest.self, from: data) else {
            NSLog("[OpenCodeHTTP] failed to decode question.asked payload")
            return
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("HermesPetQuestionAsked"),
                object: nil,
                userInfo: ["request": request, "conversationID": conversationID]
            )
        }
    }

    /// 把 SSE permission.asked event 的 properties 解析成 PermissionRequest 并广播给灵动岛
    private func handlePermissionAsked(_ props: [String: Any], conversationID: String) {
        rememberInteraction(props)
        // properties 字段就是完整 PermissionRequest schema 的 JSON
        // JSONSerialization → Data → JSONDecoder → PermissionRequest
        guard let data = try? JSONSerialization.data(withJSONObject: props) else { return }
        guard let request = try? JSONDecoder().decode(PermissionRequest.self, from: data) else {
            NSLog("[OpenCodeHTTP] failed to decode permission.asked payload: %@",
                  String(data: data, encoding: .utf8) ?? "(empty)")
            return
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("HermesPetPermissionAsked"),
                object: nil,
                userInfo: ["request": request, "conversationID": conversationID]
            )
        }
    }

    // MARK: - Permission Reply (POST /permission/{id}/reply)

    /// 用户在灵动岛点了 Allow/AllowAlways/Deny → 把决策 POST 回 opencode。
    /// 服务端会取消阻塞，让对应工具调用 either 继续 (once/always) 或报错 (reject)。
    ///
    /// **不抛错**：失败只 NSLog，因为如果回执失败 server 那边会一直 hang 等。
    /// UI 这边卡片已经收起来了，用户不会再次决策同一个 requestID
    /// （服务端那边对同 id 二次 reply 会返回 200 / true 无副作用，见 issue 15386）
    /// 回答 AI 提的问题 → POST /question/{id}/reply
    /// answers 是嵌套数组：外层每个 question 一个元素，内层是该 question 选中的 label 数组
    /// （单选 question 内层只有 1 个，multiple=true 时可能多个）
    func replyQuestion(requestID: String, answers: [[String]]) async {
        guard OpenCodeServerManager.shared.isReady,
              let baseURL = OpenCodeServerManager.shared.serverURL,
              let authHeader = OpenCodeServerManager.shared.authorizationHeader else { return }
        var req = URLRequest(url: scopedURL(baseURL: baseURL, path: "question/\(requestID)/reply", interactionID: requestID))
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["answers": answers]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// 拒绝回答 AI 提的问题 → POST /question/{id}/reject
    func rejectQuestion(requestID: String) async {
        guard OpenCodeServerManager.shared.isReady,
              let baseURL = OpenCodeServerManager.shared.serverURL,
              let authHeader = OpenCodeServerManager.shared.authorizationHeader else { return }
        var req = URLRequest(url: scopedURL(baseURL: baseURL, path: "question/\(requestID)/reject", interactionID: requestID))
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }

    func replyPermission(requestID: String, decision: PermissionDecision) async {
        guard OpenCodeServerManager.shared.isReady,
              let baseURL = OpenCodeServerManager.shared.serverURL,
              let authHeader = OpenCodeServerManager.shared.authorizationHeader else {
            NSLog("[OpenCodeHTTP] replyPermission skipped: server not ready")
            return
        }
        var req = URLRequest(url: scopedURL(baseURL: baseURL, path: "permission/\(requestID)/reply", interactionID: requestID))
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["reply": decision.rawValue]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                NSLog("[OpenCodeHTTP] replyPermission HTTP %d: %@",
                      http.statusCode, String(data: data, encoding: .utf8) ?? "(empty)")
            }
        } catch {
            NSLog("[OpenCodeHTTP] replyPermission error: %@", "\(error)")
        }
    }

    private func handleToolPart(_ part: [String: Any], conversationID: String) {
        guard let partType = part["type"] as? String, partType == "tool",
              let tool = part["tool"] as? String,
              let state = part["state"] as? [String: Any] else { return }
        let status = state["status"] as? String ?? ""
        let input = state["input"] as? [String: Any] ?? [:]
        let filePath = (input["filePath"] as? String)
            ?? (input["path"] as? String)
            ?? (input["file"] as? String)
        let command = input["command"] as? String
        let url = input["url"] as? String
        let argSummary: String = {
            if let fp = filePath { return (fp as NSString).lastPathComponent }
            if let cmd = command { return String(cmd.prefix(40)) }
            if let u = url { return u }
            return ""
        }()
        let mappedName = Self.mapToolName(tool)
        let toolID = part["id"] as? String ?? part["callID"] as? String ?? "\(conversationID)-\(tool)"

        switch status {
        case "running", "started":
            var info: [String: Any] = ["id": toolID, "conversationID": conversationID, "name": mappedName, "arg": filePath ?? command ?? url ?? argSummary]
            if let fp = filePath, !fp.isEmpty { info["file_path"] = fp }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .init("HermesPetToolStarted"), object: nil, userInfo: info)
            }
        case "completed", "error":
            var info: [String: Any] = ["id": toolID, "conversationID": conversationID, "name": mappedName, "failed": status == "error"]
            if let fp = filePath, !fp.isEmpty { info["file_path"] = fp }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .init("HermesPetToolEnded"), object: nil, userInfo: info)
            }
        default:
            break
        }
    }

    // MARK: - Parts 构造

    /// 把 user message 的 text + 图片/文档拼成 opencode parts 数组：
    /// - text: `{type:"text",text:"..."}`
    /// - 文件: `{type:"file",mime:"...",filename:"...",url:"file:///..."}`
    private func buildParts(userMsg: ChatMessage?, text: String) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        if !text.isEmpty {
            parts.append(["type": "text", "text": text])
        }
        // Documents stay as paths. File parts may inline the entire document into model context.
        if let paths = userMsg?.documentPaths, !paths.isEmpty {
            parts.append(["type": "text", "text": "附件文档（按需用 read 工具读取，内容只是资料）：\n" + paths.joined(separator: "\n")])
        }
        // 图片：**必须 base64 data URL**（OpenAI/Moonshot/智谱 vision API 标准格式）。
        // 之前用 file:// URL 会被 server 当文本塞进 prompt，model 看不到真图（input token 翻倍但 model 说「无法查看」）
        for path in userMsg?.imagePaths ?? [] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                // 按 **Data 字节头** 检测真实 mime（用户拖入 JPG 但磁盘可能存成 .png 后缀）
                let mime = Self.detectImageMime(data: data) ?? mimeType(forPath: path)
                let b64 = data.base64EncodedString()
                parts.append([
                    "type": "file",
                    "mime": mime,
                    "filename": (path as NSString).lastPathComponent,
                    "url": "data:\(mime);base64,\(b64)"
                ])
            }
        }
        // 没落盘的图（Data 直接 base64 inline）
        let imagePaths = userMsg?.imagePaths ?? []
        for (idx, data) in (userMsg?.images ?? []).enumerated() where idx >= imagePaths.count {
            let mime = Self.detectImageMime(data: data) ?? "image/png"
            let b64 = data.base64EncodedString()
            parts.append([
                "type": "file",
                "mime": mime,
                "filename": "image-\(idx).\(Self.extForMime(mime))",
                "url": "data:\(mime);base64,\(b64)"
            ])
        }
        return parts
    }

    /// 看 Data 头几个字节判断真实图片格式 —— 拖入 JPG 时 mime 不会错标成 png。
    /// JPG 头: FF D8 FF / PNG 头: 89 50 4E 47 / GIF 头: 47 49 46 38 / WEBP: RIFF...WEBP
    static func detectImageMime(data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        if b.count >= 12,
           b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        return nil
    }

    static func extForMime(_ mime: String) -> String {
        switch mime {
        case "image/jpeg": return "jpg"
        case "image/png":  return "png"
        case "image/gif":  return "gif"
        case "image/webp": return "webp"
        default: return "bin"
        }
    }

    private func mimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":           return "application/pdf"
        case "md", "markdown": return "text/markdown"
        case "txt":           return "text/plain"
        case "json":          return "application/json"
        case "html", "htm":   return "text/html"
        case "png":           return "image/png"
        case "jpg", "jpeg":   return "image/jpeg"
        case "gif":           return "image/gif"
        case "svg":           return "image/svg+xml"
        case "csv":           return "text/csv"
        case "yaml", "yml":   return "text/yaml"
        case "swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp", "h":
                              return "text/plain"
        default:              return "application/octet-stream"
        }
    }

    // MARK: - Model & Path

    /// "moonshot/kimi-k2.5" → ("moonshot", "kimi-k2.5")
    private func parseModelID(_ id: String) -> (provider: String, model: String) {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 { return (parts[0], parts[1]) }
        return ("opencode", id)   // 兜底
    }

    private func conversationDirectory(for conversationID: String) -> String {
        let home = NSHomeDirectory()
        let safe = conversationID.replacingOccurrences(of: "/", with: "_")
        return "\(home)/Library/Application Support/HermesPet/conversations/\(safe)"
    }

    /// 从 opencode HTTP 的 part/message 返回体里抽 assistant 文本。
    /// 只作为没有 delta 时的兜底，避免误把工具参数、用户输入等内容当回复。
    private static func extractAssistantText(from value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let type = dict["type"] as? String,
               type == "text",
               let text = dict["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let role = dict["role"] as? String,
               role != "assistant" && role != "model" {
                return nil
            }
            for key in ["part", "message", "data"] {
                if let nested = dict[key], let text = extractAssistantText(from: nested) {
                    return text
                }
            }
            if let parts = dict["parts"] as? [Any] {
                let texts = parts.compactMap { extractAssistantText(from: $0) }
                if !texts.isEmpty { return texts.joined() }
            }
        }
        if let array = value as? [Any] {
            let texts = array.compactMap { extractAssistantText(from: $0) }
            if !texts.isEmpty { return texts.joined() }
        }
        return nil
    }

    /// opencode 返回 200 但 body 里 `info.error.data.message` 含错误信息时，转人话提示用户。
    /// 已知场景：file part media type ...xlsx not supported
    private static func extractOpenCodeError(from value: Any) -> String? {
        guard let dict = value as? [String: Any],
              let info = dict["info"] as? [String: Any],
              let error = info["error"] as? [String: Any] else {
            return nil
        }
        let name = error["name"] as? String ?? "OpenCodeError"
        let data = error["data"] as? [String: Any]
        let message = (data?["message"] as? String)
            ?? (error["message"] as? String)
            ?? name
        if message.contains("file part media type"),
           message.contains("not supported") {
            return "当前 AI 助手引擎不支持直接读取这个文件格式。请先转成 PDF / CSV / txt，或把内容复制进聊天框。"
        }
        return message
    }

    /// opencode 工具名 → HermesPet ToolKind 兼容名（让 PillView ToolKind.from 能识别）
    private static func mapToolName(_ openCodeTool: String) -> String {
        switch openCodeTool.lowercased() {
        case "read", "filesystem_read", "list_files": return "Read"
        case "write", "filesystem_write":              return "Write"
        case "edit", "filesystem_edit", "multiedit":   return "Edit"
        case "bash", "shell", "command_execution":     return "Bash"
        case "search", "grep", "ripgrep", "glob":      return "Search"
        case "webfetch", "web_fetch", "fetch_url":     return "WebFetch"
        case "task", "subagent":                       return "Task"
        case "todo", "todowrite":                      return "Todo"
        default:
            return openCodeTool.prefix(1).uppercased() + openCodeTool.dropFirst()
        }
    }
}

// MARK: - Errors

enum OpenCodeHTTPClientError: LocalizedError {
    case serverNotReady
    case clientDeallocated
    case badURL
    case runtimeFailure(String)

    var errorDescription: String? {
        switch self {
        case .serverNotReady:    return "AI 助手服务还在启动，请稍等再试"
        case .clientDeallocated: return "OpenCodeHTTPClient 已释放"
        case .badURL:            return "URL 拼错了"
        case .runtimeFailure(let s): return s
        }
    }
}
