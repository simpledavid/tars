import Foundation

/// GUI App 直接从 Dock/Finder 启动时拿到的 PATH 很短，通常没有 Homebrew、
/// ~/.local/bin、nvm/asdf/mise 等目录。Claude/Codex CLI 如果是 npm 脚本，
/// shebang 会走 `/usr/bin/env node`，此时就会报 `env: node: No such file or directory`。
///
/// 统一在 spawn CLI 前补齐 PATH：优先复用 CLIAvailability 从 login shell 探测到的 PATH，
/// 再追加可执行文件所在目录和常见开发工具目录。
enum CLIProcessEnvironment {
    static func make(executablePath: String, removing keysToRemove: [String] = []) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in keysToRemove {
            env.removeValue(forKey: key)
        }
        env["PATH"] = mergedPATH(existing: env["PATH"], executablePath: executablePath)
        return env
    }

    private static func mergedPATH(existing: String?, executablePath: String) -> String {
        var entries: [String] = []
        var seen = Set<String>()

        func appendPathList(_ value: String?) {
            guard let value, !value.isEmpty else { return }
            for raw in value.split(separator: ":") {
                appendDir(String(raw))
            }
        }

        func appendDir(_ raw: String) {
            let expanded = (raw as NSString).expandingTildeInPath
            guard !expanded.isEmpty, !seen.contains(expanded) else { return }

            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                seen.insert(expanded)
                entries.append(expanded)
            }
        }

        appendPathList(existing)
        appendPathList(UserDefaults.standard.string(forKey: "cliLoginShellPATH"))

        if !executablePath.isEmpty {
            appendDir((executablePath as NSString).deletingLastPathComponent)
        }

        let home = NSHomeDirectory()
        [
            "\(home)/.local/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
            "\(home)/.asdf/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].forEach(appendDir)

        return entries.joined(separator: ":")
    }
}
