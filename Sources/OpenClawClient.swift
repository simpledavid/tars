import Foundation

private final class OpenClawStreamState: @unchecked Sendable {
    let lock = NSLock()
    var emittedText = false
}

private final class OpenClawLockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Local OpenClaw agent integration.
///
/// OpenClaw is treated as a local CLI runtime, parallel to opencode in the
/// online AI agent picker. The client accepts either plain text stdout or
/// JSON/JSONL events with common text fields (`text`, `content`, `delta`).
final class OpenClawClient: @unchecked Sendable {
    private var executablePath: String {
        UserDefaults.standard.string(forKey: "openClawExecutablePath") ?? ""
    }

    func checkAvailable() async -> Bool {
        await CLIAvailability.openClawAvailable()
    }

    func streamCompletion(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        let prompt = buildPrompt(messages: messages)
        return streamRaw(prompt: prompt)
    }

    private func buildPrompt(messages: [ChatMessage]) -> String {
        let convo = messages.filter { $0.role == .user || $0.role == .assistant }
        guard let latest = convo.last, latest.role == .user else {
            return convo.map { "\($0.role == .user ? "用户" : "助手"): \($0.content)" }.joined(separator: "\n\n")
        }

        var lines: [String] = []
        let history = convo.dropLast()
        if !history.isEmpty {
            lines.append("以下是之前的对话历史，请基于上下文回答最后一个新问题。")
            lines.append("--- 历史开始 ---")
            for msg in history {
                let who = msg.role == .user ? "用户" : "助手"
                lines.append("【\(who)】\(msg.content)")
            }
            lines.append("--- 历史结束 ---")
            lines.append("")
            lines.append("现在用户问：")
        }
        lines.append(latest.content)

        if !latest.documentPaths.isEmpty {
            lines.append("")
            lines.append("用户附带了这些本地文件路径，请在需要时读取：")
            lines.append(contentsOf: latest.documentPaths)
        }
        if !latest.imagePaths.isEmpty {
            lines.append("")
            lines.append("用户附带了这些图片路径，请在需要时查看：")
            lines.append(contentsOf: latest.imagePaths)
        }
        return lines.joined(separator: "\n")
    }

    private func streamRaw(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let path = executablePath
            guard !path.isEmpty else {
                continuation.finish(throwing: APIError.httpError(
                    statusCode: 0,
                    body: "找不到 openclaw 命令，请先安装 OpenClaw 或在 PATH 中暴露 openclaw"
                ))
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["run", "--format", "json", "--", prompt]
            process.environment = CLIProcessEnvironment.make(executablePath: path)

            let outPipe = Pipe()
            let errPipe = Pipe()
            let stderr = OpenClawLockedData()
            let state = OpenClawStreamState()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stderr.append(data) }
            }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let chunk = String(data: data, encoding: .utf8) ?? ""
                for rawLine in chunk.components(separatedBy: .newlines) {
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    if let text = Self.extractText(fromLine: line), !text.isEmpty {
                        state.lock.lock()
                        state.emittedText = true
                        state.lock.unlock()
                        continuation.yield(text)
                    } else if !line.hasPrefix("{") {
                        state.lock.lock()
                        state.emittedText = true
                        state.lock.unlock()
                        continuation.yield(line + "\n")
                    }
                }
            }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                SubprocessRegistry.shared.unregister(proc)

                if proc.terminationStatus != 0 {
                    let errText = String(data: stderr.data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? "OpenClaw 进程异常退出"
                    continuation.finish(throwing: APIError.httpError(
                        statusCode: 0,
                        body: "OpenClaw: \(errText)"
                    ))
                } else {
                    continuation.finish()
                }
            }

            do {
                try process.run()
                SubprocessRegistry.shared.register(process)
            } catch {
                continuation.finish(throwing: error)
            }

            continuation.onTermination = { @Sendable _ in
                if process.isRunning { process.terminate() }
            }
        }
    }

    private static func extractText(fromLine line: String) -> String? {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return extractText(from: json)
    }

    private static func extractText(from value: Any) -> String? {
        if let text = value as? String { return text }
        if let dict = value as? [String: Any] {
            for key in ["delta", "text", "content", "message", "output"] {
                if let found = dict[key], let text = extractText(from: found), !text.isEmpty {
                    return text
                }
            }
            if let choices = dict["choices"] as? [Any],
               let first = choices.first,
               let text = extractText(from: first) {
                return text
            }
        }
        if let array = value as? [Any] {
            return array.compactMap { extractText(from: $0) }.joined()
        }
        return nil
    }
}
