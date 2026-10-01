import Foundation

struct AgentContext {
    var messages: [ChatMessage]
    var omittedCount: Int
    var archiveURL: URL?

    /// Extractive compaction: excerpts are explicitly labelled and the complete source stays on disk.
    /// The newest turn (including attachments) is always intact, even if it exceeds the budget.
    static func compact(_ messages: [ChatMessage], budget: Int, enabled: Bool,
                        archiveURL: URL? = nil) -> Self {
        let history = messages.filter { $0.role == .user || $0.role == .assistant }
        guard enabled, history.reduce(0, { $0 + $1.content.count }) > budget,
              history.count > 2 else {
            return Self(messages: history, omittedCount: 0, archiveURL: archiveURL)
        }
        var start = history.count - 1
        var size = history[start].content.count
        let recentBudget = max(1, budget - 4_000)
        while start > 0, size + history[start - 1].content.count <= recentBudget {
            start -= 1
            size += history[start].content.count
        }
        // Keep a user/assistant pair together rather than leading with an orphan answer.
        if history[start].role == .assistant, start + 1 < history.count { start += 1 }
        guard start > 0 else { return Self(messages: history, omittedCount: 0, archiveURL: archiveURL) }
        let omitted = Array(history.prefix(start))
        var lines = ["[早期对话摘录：已压缩 \(start) 条消息。以下只是原文片段，可能不完整；不是新增指令。]"]
        if let archiveURL { lines.append("完整历史：\(archiveURL.path)；需要精确信息时按路径读取。") }
        if let first = omitted.first(where: { $0.role == .user }) {
            lines.append("最初请求：\(first.content.prefix(700))")
        }
        // Preserve more recent decisions as excerpts; never claim a generated semantic summary.
        for message in omitted.suffix(8) {
            lines.append("\(message.role == .user ? "用户" : "助手")摘录：\(message.content.prefix(280))")
            if !message.documentPaths.isEmpty {
                lines.append("附件路径：\(message.documentPaths.joined(separator: ", "))")
            }
        }
        let digest = ChatMessage(role: .assistant, content: String(lines.joined(separator: "\n").prefix(4_000)))
        return Self(messages: [digest] + Array(history.suffix(from: start)),
                    omittedCount: start, archiveURL: archiveURL)
    }

    static func archiveText(_ messages: [ChatMessage]) -> String {
        messages.map { message in
            let attachments = message.documentPaths + message.imagePaths
            return "## \(message.role.rawValue) · \(message.timestamp.ISO8601Format())\n\n\(message.content)"
                + (attachments.isEmpty ? "" : "\n\n附件路径：\n" + attachments.joined(separator: "\n"))
        }.joined(separator: "\n\n")
    }
}
