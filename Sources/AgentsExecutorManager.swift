import Foundation

@MainActor
protocol AgentsExecuting {
    func start(sessionID: String, environmentID: String, remoteURL: String,
               directory: String, key: String, executablePath: String) throws
    func stop(sessionID: String)
    func isRunning(sessionID: String) -> Bool
}

/// Each durable cloud session gets its own local executor. Keys never enter arguments or logs.
@MainActor
final class AgentsExecutorManager: AgentsExecuting {
    private var processes: [String: Process] = [:]

    static func checkAvailability() async throws -> String {
        guard await CLIAvailability.codexAvailable(),
              let path = UserDefaults.standard.string(forKey: "codexExecutablePath") else {
            throw AgentsAPIError.message("未找到执行器。请安装支持 exec-server 的 Codex CLI，再重新检测")
        }
        let supported = await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["exec-server", "--help"]
            process.environment = environment(executablePath: path, environmentKey: nil)
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { process.terminate(); return false }
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return process.terminationStatus == 0 && text.contains("--environment-id") && text.contains("--remote")
        }.value
        guard supported else {
            throw AgentsAPIError.message("当前 Codex CLI 不支持 exec-server，请更新执行器后重新检测")
        }
        return path
    }

    nonisolated static func environment(executablePath: String, environmentKey: String?) -> [String: String] {
        let original = CLIProcessEnvironment.make(executablePath: executablePath)
        // An allowlist keeps provider and application credentials out of the execution environment.
        let allowed = ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME", "SHELL"]
        var result = original.filter { allowed.contains($0.key) }
        if let environmentKey { result["CODEX_API_KEY"] = environmentKey }
        return result
    }

    func start(sessionID: String, environmentID: String, remoteURL: String,
               directory: String, key: String, executablePath: String) throws {
        if processes[sessionID]?.isRunning == true { return }
        guard let url = URL(string: remoteURL), url.scheme == "https", url.host == "api.openai.com",
              url.user == nil, url.password == nil else {
            throw AgentsAPIError.message("Agents API 返回了无法识别的执行器连接地址")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["exec-server", "--remote", remoteURL, "--environment-id", environmentID]
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.environment = Self.environment(executablePath: executablePath, environmentKey: key)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in SubprocessRegistry.shared.unregister(process) }
        try process.run()
        SubprocessRegistry.shared.register(process)
        processes[sessionID] = process
    }

    func stop(sessionID: String) {
        guard let process = processes.removeValue(forKey: sessionID) else { return }
        if process.isRunning { process.terminate() }
        SubprocessRegistry.shared.unregister(process)
    }

    func isRunning(sessionID: String) -> Bool { processes[sessionID]?.isRunning == true }
}
