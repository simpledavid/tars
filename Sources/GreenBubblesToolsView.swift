import AppKit
import SwiftUI

private struct GreenBubblesToolGroup: Identifiable {
    let id: String
    let title: String
    let detail: String
    var tool = "greenbubbles"
    var documentation: String?
}

struct GreenBubblesToolsView: View {
    let onPrepareAI: () -> String?
    @State private var error: String?
    private let groups = [
        GreenBubblesToolGroup(id: "messages", title: "聊天检索", detail: "按会话、关键词、时间和游标读取消息"),
        GreenBubblesToolGroup(id: "attachment", title: "附件", detail: "检查、解码和独立保存图片、文件、视频、语音"),
        GreenBubblesToolGroup(id: "snapshot", title: "加密备份", detail: "创建、验证、恢复词、密钥轮换与备份保留"),
        GreenBubblesToolGroup(id: "memory", title: "个人知识库", detail: "整理聊天证据、增量更新和读取覆盖率"),
        GreenBubblesToolGroup(id: "ai-query", title: "AI 数据访问", detail: "限制会话、时间和字段，导出带引用的 AI 上下文"),
        GreenBubblesToolGroup(id: "profile", title: "账号与查询配置", detail: "配置第二个微信账号、快照和默认查询来源"),
        GreenBubblesToolGroup(id: "send", title: "发送适配器", detail: "遵循公开版限制，仅开放检查和模拟执行"),
        GreenBubblesToolGroup(id: "restore", title: "导出、恢复与审计", detail: "导出副本、恢复数据、验证完整性及操作审计", documentation: "docs/RESTORATION_SPEC.md"),
        GreenBubblesToolGroup(id: "replica-status", title: "同步副本", detail: "副本状态、搜索、同步与变更处理", documentation: "docs/REPLICA_OPERATIONS.md"),
        GreenBubblesToolGroup(id: "acquire", title: "微信密钥配置", detail: "原项目密钥获取与已支持客户端检测", tool: "greenbubbles-acquire"),
        GreenBubblesToolGroup(id: "discover", title: "本机数据发现", detail: "查找账号目录，检查存储与采集能力", tool: "greenbubbles-discover"),
        GreenBubblesToolGroup(id: "article", title: "公众号文章", detail: "读取公开文章内容与资源", documentation: "docs/PUBLIC_ARTICLE_FETCH.md"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("GreenBubbles 完整工具箱").font(.title.weight(.semibold))
                    Text("聊天和备份可在上方界面操作。其他原项目功能通过内置工具与技能使用。")
                        .foregroundStyle(.secondary)
                }
                GroupBox("AI 笔记") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("让 Tars 按原项目技能整理聊天，生成带引用、可持续更新的 Markdown 笔记。")
                        Text("点击后只准备聊天输入。发送给 AI 后，读取的内容会进入你选择的模型。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("在 Tars 中整理文件传输助手") { error = onPrepareAI() }
                            Button("查看内置技能") { openResource("skills") }
                            Button("查看完整文档") { openResource("docs") }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(groups) { group in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group.title).font(.headline)
                                Text(group.detail).font(.callout).foregroundStyle(.secondary)
                                Button("打开操作说明") {
                                    if let documentation = group.documentation { openResource(documentation) }
                                    else { launchTerminal(topic: group.id, tool: group.tool) }
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading).padding(10)
                        }
                    }
                }
                HStack {
                    Button("打开完整工具终端") { launchTerminal(topic: nil) }
                        .buttonStyle(.borderedProminent)
                    Button("首次配置说明") { openResource("docs/PASSPHRASE_ACQUISITION.md") }
                    Button("恢复、导出与审计指南") { openResource("docs/CLI_REFERENCE.md") }
                }
                Text("内置完整 CLI、密钥获取工具、发现工具、技能、脚本和文档；普通读取保持只读。高级导出、恢复、同步副本和审计等命令均保留。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .padding(36).frame(maxWidth: 1000)
        }
        .frame(maxWidth: .infinity)
    }

    private func openResource(_ path: String) {
        guard let resources = Bundle.main.resourceURL else { return }
        let url = resources.appending(path: "GreenBubbles/\(path)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            error = "内置文档未找到，请通过 build.sh 构建完整 Tars 应用。"; return
        }
        NSWorkspace.shared.open(url)
    }

    private func launchTerminal(topic: String?, tool: String = "greenbubbles") {
        guard let binary = Bundle.main.executableURL?.deletingLastPathComponent() else { return }
        guard FileManager.default.isExecutableFile(atPath: binary.appending(path: "greenbubbles").path) else {
            error = "未找到内置 GreenBubbles 工具，请通过 build.sh 构建完整应用。"; return
        }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let resources = Bundle.main.resourceURL!.appending(path: "GreenBubbles")
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TarsKnowledge/terminal")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let script = directory.appending(path: "greenbubbles-\(UUID().uuidString).command")
            let help = tool == "greenbubbles"
                ? (topic.map { "greenbubbles help " + quote($0) } ?? "greenbubbles help --all")
                : quote(tool) + " --help"
            let body = """
            #!/bin/zsh
            umask 077
            export PATH=\(quote(binary.path)):"$PATH"
            cd \(quote(resources.path))
            print 'Tars · GreenBubbles 工具终端'
            print '已配置内置工具路径。普通读取命令会使用现有微信密钥配置。'
            \(help)
            exec /bin/zsh -i
            """
            try Data(body.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch { self.error = "工具终端打开失败：\(error.localizedDescription)" }
    }
}
