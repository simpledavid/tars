import Foundation

/// Product-owned configuration; never overwrites a runtime's user config or a project's AGENTS.md.
struct AgentConfiguration: Codable, Equatable, Sendable {
    var workspacePath = ""
    var skillsDirectory = ""
    var memoryEnabled = true
    var compactionEnabled = true
    var contextCharacterBudget = 24_000
    var multiAgentEnabled = false
    var mcpServers: [AgentMCPServer] = []

    static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermespet/agents", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("runtime.json") }
    static var memoryURL: URL { directory.appendingPathComponent("memory.md") }

    static func load() throws -> Self {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: fileURL))
    }

    func validate() throws {
        for path in [workspacePath, skillsDirectory] where !path.isEmpty {
            var isDirectory: ObjCBool = false
            guard path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AgentHarnessError.configuration("目录不存在：\(path)")
            }
        }
        guard (8_000...96_000).contains(contextCharacterBudget) else {
            throw AgentHarnessError.configuration("上下文预算应在 8,000–96,000 字符之间")
        }
        var names = Set<String>()
        for server in mcpServers {
            guard !server.name.isEmpty,
                  server.name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil,
                  names.insert(server.name).inserted else {
                throw AgentHarnessError.configuration("MCP 名称须唯一，只能包含英文字母、数字、下划线和连字符")
            }
            guard let url = URL(string: server.url),
                  ["http", "https"].contains(url.scheme), url.host != nil,
                  url.user == nil, url.password == nil else {
                throw AgentHarnessError.configuration("MCP 地址须为 HTTP 或 HTTPS URL：\(server.name)")
            }
        }
    }

    func save() throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.writePrivate(try encoder.encode(self), to: Self.fileURL)
    }

    static func saveMemory(_ text: String) throws {
        guard text.count <= 6_000 else {
            throw AgentHarnessError.configuration("记忆最多 6,000 字符；较长资料请作为文件附件发送")
        }
        try writePrivate(Data(text.utf8), to: memoryURL)
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Skills are loaded lazily by the runtime. Only names and absolute paths enter the prompt.
    func skillFiles() -> [URL] {
        guard !skillsDirectory.isEmpty else { return [] }
        let root = URL(fileURLWithPath: skillsDirectory, isDirectory: true)
        let fm = FileManager.default
        var files: [URL] = []
        if fm.fileExists(atPath: root.appendingPathComponent("SKILL.md").path) {
            files.append(root.appendingPathComponent("SKILL.md"))
        }
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        for child in children.sorted(by: { $0.path < $1.path }) {
            let file = child.appendingPathComponent("SKILL.md")
            if fm.fileExists(atPath: file.path) { files.append(file) }
        }
        return Array(files.prefix(32))
    }

    /// Native opencode capabilities. These are tool permissions, not prompt-only personalities.
    func openCodeOptions(modelID: String) -> [String: Any] {
        var mcp: [String: Any] = [:]
        for server in mcpServers {
            mcp[server.name] = ["type": "remote", "url": server.url, "enabled": server.enabled]
        }
        let taskPermission: [String: String] = multiAgentEnabled
            ? ["*": "deny", "tars-researcher": "allow", "tars-reviewer": "allow"] : ["*": "deny"]
        let primary: [String: Any] = [
            "mode": "primary", "model": modelID,
            "description": "Tars task coordinator",
            "prompt": multiAgentEnabled
                ? "For independent research or review, use tars-researcher or tars-reviewer via the task tool when useful. Combine their evidence and answer the user yourself. Keep file modifications in the primary agent."
                : "Complete the user's task directly.",
            "permission": ["task": taskPermission]
        ]
        var agents: [String: Any] = ["tars": primary]
        for (name, description, prompt) in [
            ("tars-researcher", "Research files and sources without editing", "Research the assigned question. Cite files or URLs and report evidence, uncertainties and findings. Do not modify files."),
            ("tars-reviewer", "Review correctness without editing", "Review the assigned work for concrete correctness issues. Report evidence and actionable findings. Do not modify files.")
        ] {
            agents[name] = [
                "mode": "subagent", "model": modelID, "description": description, "prompt": prompt,
                "disable": !multiAgentEnabled,
                "permission": ["edit": "deny", "bash": "deny", "task": "deny"]
            ]
        }
        var options: [String: Any] = [
            "mcp": mcp, "agent": agents, "default_agent": "tars",
            "compaction": ["auto": compactionEnabled, "prune": compactionEnabled]
        ]
        if !skillsDirectory.isEmpty { options["skills"] = ["paths": [skillsDirectory]] }
        return options
    }
}

struct AgentMCPServer: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var url: String
    var enabled = true
}

enum AgentHarnessError: LocalizedError {
    case configuration(String)
    var errorDescription: String? {
        switch self { case .configuration(let message): return message }
    }
}
