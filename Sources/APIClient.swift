import Foundation

/// 跨 Task 边界共享的 idle clock —— stream watchdog 用它检测服务端"装死"。
/// actor 保证并发安全，每次收到 SSE 数据就 touch()，watchdog 每 5s 查 idleSeconds()。
actor APIIdleClock {
    private var lastTouchedAt = Date()
    private(set) var timedOut = false
    func touch() { lastTouchedAt = Date() }
    func idleSeconds() -> TimeInterval { Date().timeIntervalSince(lastTouchedAt) }
    func markTimedOut() { timedOut = true }
}

/// OpenAI-compatible provider client for small text requests and provider checks.
final class APIClient: @unchecked Sendable {
    enum ConfigSource {
        case direct
        var baseURLKey: String { "directAPIBaseURL" }
        var apiKeyKey: String { "directAPIKey" }
        var modelNameKey: String { "directAPIModel" }
        var defaultBaseURL: String { "" }
        var defaultModel: String { "" }
    }

    /// SSE 流空闲超时（秒）。超过此值无数据 → 主动断流报错，避免卡到 timeoutIntervalForRequest 才返回
    private static let streamIdleTimeoutSeconds: TimeInterval = 90

    /// 注入给 Hermes / AI 助手的 system 提示 —— 让 AI 识别任务规划意图时输出 ```tasks fence。
    /// Claude/Codex 的提示靠 prompt 末尾拼接（它们没 system 概念），Hermes/直连 走 OpenAI 兼容 API
    /// 直接前置一条 role=system 即可
    private func systemPrompt(onlineAgent: OnlineAIAgent = .opencode) -> String {
        let identityBlock: String
            let provider = ProviderPreset.detect(baseURL: baseURL)
            let providerName = provider.id == "custom" ? "自定义 OpenAI 兼容服务" : provider.displayName
            let preferenceRaw = UserDefaults.standard.string(forKey: "directAPIResponsePreference") ?? ""
            let preference = DirectResponsePreference(rawValue: preferenceRaw) ?? .balanced
            identityBlock = """
            当前模式：AI 助手
            \(onlineAgent.directSystemInstructions)
            当前服务商：\(providerName)
            当前模型：\(modelName)
            当前回复偏好：\(preference.label)
            你运行在 Tars 的「AI 助手」模式。你可以说明自己是 Tars AI 助手，当前由 \(providerName) / \(modelName) 提供能力。
            除非当前模式明确是 Claude Code 或 Codex，否则不要自称 Claude、Claude Code、Codex，也不要说自己处在 Codex 模式。
            """

        return """
    你运行在 Tars 桌面客户端。客户端约定：

    【身份与配置】
    \(identityBlock)

    1) 如果你想让用户做选择，用 Markdown 编号列表（1. xxx 2. yyy ...）。客户端会渲染成可点击卡片。

    2) 如果识别到用户输入是任务规划意图（"今天要做哪些事 / 待办 / 帮我分解任务"），用 fence block 输出：
    ```tasks
    - title: 任务标题
      desc: 一行描述
      mode: directAPI     # directAPI / claudeCode / codex 三选一
      eta: 30m            # 可选预估时长
    ```
    客户端会渲染成可点击任务卡片，每张有 📌 Pin / 🤖 让 AI 做 / ✗ 跳过 按钮。**只在确实是任务规划场景用此格式**。
    """
    }

    let source: ConfigSource

    init(source: ConfigSource = .direct) {
        self.source = source
    }

    private var baseURL: String {
        UserDefaults.standard.string(forKey: source.baseURLKey) ?? source.defaultBaseURL
    }
    private var apiKey: String {
        ModelDriverConfig.currentFromDefaults().apiKey
    }
    private var modelName: String {
        UserDefaults.standard.string(forKey: source.modelNameKey) ?? source.defaultModel
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    // MARK: - Streaming

    /// Returns an AsyncThrowingStream that yields text deltas as they arrive via SSE.
    func streamCompletion(messages: [ChatMessage],
                          onlineAgent: OnlineAIAgent = .opencode) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { [weak self] continuation in
            guard let self = self else {
                continuation.finish(throwing: APIError.cancelled)
                return
            }

            let clock = APIIdleClock()  // 跟踪"最近一次收到数据"的时间戳

            let task = Task { [self] in
                do {
                    let url = try self.makeURL(path: "chat/completions")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    self.authorize(&request)

                    // 前置一条 system message 注入客户端约定（选项列表 / 任务规划 fence）
                    var apiMessages: [APIMessage] = [APIMessage(role: "system", text: self.systemPrompt(onlineAgent: onlineAgent))]
                    apiMessages.append(contentsOf: messages.map {
                        APIMessage(role: $0.role.rawValue, text: $0.content, images: $0.images)
                    })
                    let body = ChatCompletionRequest(model: self.modelName, messages: apiMessages, stream: true)
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await self.session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw APIError.invalidResponse
                    }
                    guard httpResponse.statusCode == 200 else {
                        throw APIError.httpError(statusCode: httpResponse.statusCode, body: "stream failed")
                    }

                    for try await line in bytes.lines {
                        await clock.touch()
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

                        if trimmed.hasPrefix("data: ") {
                            let payload = String(trimmed.dropFirst(6))

                            if payload == "[DONE]" {
                                continue
                            }

                            if let data = payload.data(using: .utf8),
                               let chunk = try? JSONDecoder().decode(StreamingChunk.self, from: data),
                               let content = chunk.choices?.first?.delta.content {
                                continuation.yield(content)
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    // 区分用户取消 vs 服务端装死，给用户更清晰的错误
                    if await clock.timedOut {
                        let msg = "服务器 \(Int(Self.streamIdleTimeoutSeconds))s 未响应，已自动断流"
                        continuation.finish(throwing: NSError(
                            domain: "HermesAPI", code: NSURLErrorTimedOut,
                            userInfo: [NSLocalizedDescriptionKey: msg]
                        ))
                    } else if Task.isCancelled {
                        continuation.finish(throwing: APIError.cancelled)
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            // Watchdog：每 5s 检查 idle 时间，超过阈值 → 标记 timedOut + cancel 主 task
            let watchdog = Task { [task] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    let idle = await clock.idleSeconds()
                    if idle > Self.streamIdleTimeoutSeconds {
                        await clock.markTimedOut()
                        task.cancel()
                        return
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
                watchdog.cancel()
            }
        }
    }

    // MARK: - Non-streaming

    func sendMessage(messages: [ChatMessage],
                     onlineAgent: OnlineAIAgent = .opencode) async throws -> String {
        let url = try makeURL(path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.timeoutInterval = 120

        var apiMessages: [APIMessage] = [APIMessage(role: "system", text: systemPrompt(onlineAgent: onlineAgent))]
        apiMessages.append(contentsOf: messages.map {
            APIMessage(role: $0.role.rawValue, text: $0.content, images: $0.images)
        })
        let body = ChatCompletionRequest(model: modelName, messages: apiMessages, stream: false)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode: httpResponse.statusCode, body: bodyStr)
        }

        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        // content 现在是 enum，取出文本
        if case .text(let s) = completion.choices.first?.message.content {
            return s
        }
        // multimodal 返回（少见）—— 把所有 text part 拼起来
        if case .parts(let arr) = completion.choices.first?.message.content {
            return arr.compactMap { $0.text }.joined()
        }
        return ""
    }

    // MARK: - Health Check

    func checkHealth() async throws -> Bool {
        var request = URLRequest(url: try makeURL(path: "models"))
        authorize(&request)
        request.timeoutInterval = 5
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - Private

    private func makeURL(path: String) throws -> URL {
        let base = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        guard let url = URL(string: "\(base)\(path)") else {
            throw APIError.invalidResponse
        }
        return url
    }

    private func authorize(_ request: inout URLRequest) {
        guard !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
}
