import Foundation
import Network

/// An ephemeral, IPv4 loopback-only HTTP callback. Invalid states never consume the login.
final class ChatGPTLoginCallback: @unchecked Sendable {
    private let state: String
    private let queue = DispatchQueue(label: "tars.chatgpt.oauth.callback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var startup: CheckedContinuation<String, Error>?
    private var cancelled = false
    private let stream: AsyncThrowingStream<URLComponents, Error>
    private let output: AsyncThrowingStream<URLComponents, Error>.Continuation
    init(state: String) {
        self.state = state
        let pair = AsyncThrowingStream<URLComponents, Error>.makeStream()
        stream = pair.stream; output = pair.continuation
    }
    func start() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                startup = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self, weak listener] status in
                        guard let self else { return }
                        switch status {
                        case .ready:
                            guard let port = listener?.port else { self.fail(ChatGPTPlanError.message("无法获取登录回调端口。")); return }
                            self.lock.lock(); let pending = self.startup; self.startup = nil; self.lock.unlock()
                            pending?.resume(returning: "http://127.0.0.1:\(port.rawValue)/auth/callback")
                        case .failed: self.fail(ChatGPTPlanError.message("无法启动本机登录回调，请检查防火墙设置。"))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { connection.cancel(); return }
                        self.lock.lock()
                        guard !self.cancelled, self.connections.count < 16 else { self.lock.unlock(); connection.cancel(); return }
                        self.connections.append(connection); self.lock.unlock()
                        connection.start(queue: self.queue)
                        self.receive(connection, accumulated: Data())
                        self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in connection.cancel(); self?.remove(connection) }
                    }
                    listener.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 300) { [weak self] in self?.fail(ChatGPTPlanError.message("ChatGPT 登录等待超时，请重新登录。")) }
                } catch { startup = nil; continuation.resume(throwing: error) }
            }
        } onCancel: { self.cancel() }
    }
    func waitForCallback() async throws -> URLComponents {
        try await withTaskCancellationHandler {
            for try await value in stream { return value }
            throw CancellationError()
        } onCancel: { self.cancel() }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            let buffer = accumulated + (data ?? Data())
            guard buffer.count <= 16_384 else { connection.cancel(); self.remove(connection); return }
            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                let line = text.components(separatedBy: "\r\n")[0].split(separator: " ")
                let target = line.count == 3 && line[0] == "GET" ? String(line[1]) : ""
                let components = URLComponents(string: "http://127.0.0.1" + target)
                let states = components?.queryItems?.filter { $0.name == "state" } ?? []
                let valid = target.hasPrefix("/auth/callback?") && components?.path == "/auth/callback" && states.count == 1 && states[0].value == self.state
                let body = valid ? "Tars 已收到登录结果。请返回 Tars 查看授权状态。" : "无效的登录回调。"
                let bytes = Data(body.utf8)
                let header = "HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
                if valid, let components { self.output.yield(components); self.output.finish() }
                self.remove(connection)
            } else if complete || error != nil { connection.cancel(); self.remove(connection) }
            else { self.receive(connection, accumulated: buffer) }
        }
    }
    private func remove(_ connection: NWConnection) { lock.lock(); connections.removeAll { $0 === connection }; lock.unlock() }
    private func fail(_ error: Error) {
        lock.lock(); let pending = startup; startup = nil; lock.unlock()
        pending?.resume(throwing: error); output.finish(throwing: error); cancel()
    }
    func cancel() {
        lock.lock(); cancelled = true; let pending = startup; startup = nil
        let listener = listener; self.listener = nil; let connections = connections; self.connections = []; lock.unlock()
        pending?.resume(throwing: CancellationError()); output.finish(throwing: CancellationError())
        listener?.cancel(); connections.forEach { $0.cancel() }
    }
}
