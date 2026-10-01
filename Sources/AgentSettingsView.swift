import SwiftUI
import AppKit

struct AgentSettingsView: View {
    @Bindable var viewModel: ChatViewModel
    @State private var draft = AgentConfiguration()
    @State private var memory = ""
    @State private var serverName = ""
    @State private var serverURL = ""
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Agent 能力").font(.system(size: 16, weight: .semibold))
            Text("统一管理本机工作环境、记忆和工具。聊天与快问使用同一个调度层。")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 9) {
                capability("Harness", icon: "cpu", detail: "统一请求、排队、取消与会话清理")
                capability("Environment", icon: "folder", detail: "本机目录 · 按对话隔离运行状态")
                capability("Memory & context", icon: "brain", detail: draft.memoryEnabled ? "使用你保存的偏好" : "记忆已关闭")
                capability("MCP, tools & skills", icon: "wrench.and.screwdriver", detail: "Agents API / opencode 原生工具与 MCP")
                capability("Compaction", icon: "line.3.horizontal.decrease", detail: draft.compactionEnabled ? "早期摘录 + 完整本地归档" : "保留完整请求历史")
                capability("Multi-agent", icon: "person.2", detail: draft.multiAgentEnabled ? "Agents API / opencode 子任务协作" : "子任务协作已关闭")
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 14) {
                directoryRow("工作目录", path: $draft.workspacePath)
                Text("留空时沿用 Claude / Codex 原工作目录，AI 助手使用每个对话的独立目录。选定目录后，各模式在该目录执行任务。")
                    .font(.caption2).foregroundStyle(.secondary)
                directoryRow("Skills 目录", path: $draft.skillsDirectory)
                Text("选择包含技能文件夹的目录；每个技能以 SKILL.md 为入口。只发送路径，执行时按需读取。")
                    .font(.caption2).foregroundStyle(.secondary)

                Divider()
                Toggle("使用保存的记忆", isOn: $draft.memoryEnabled)
                DisclosureGroup("编辑记忆 · \(memory.count)/6,000 字符") {
                    Text("保存常用偏好、项目约定等。开启后会随请求发送给当前后端。")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextEditor(text: $memory)
                        .font(.system(size: 12)).frame(height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                }
                Toggle("本地历史摘录与 opencode 自动压缩", isOn: $draft.compactionEnabled)
                Picker("历史字符预算", selection: $draft.contextCharacterBudget) {
                    Text("12,000").tag(12_000)
                    Text("24,000").tag(24_000)
                    Text("48,000").tag(48_000)
                }.disabled(!draft.compactionEnabled)
                Text("超过预算时保留最近对话和早期原文摘录；完整记录保存在本机，可按路径继续读取。字符预算不是模型的 token 上限。Agents API 在云端自动管理上下文压缩，此开关不关闭云端压缩。")
                    .font(.caption2).foregroundStyle(.secondary)

                Divider()
                Toggle("子任务协作", isOn: $draft.multiAgentEnabled)
                Text("Agents API 启用原生多 Agent，最多并行 4 个子任务。opencode 使用研究与审查子 Agent，限制其编辑和 shell 权限。")
                    .font(.caption2).foregroundStyle(.secondary)

                DisclosureGroup("MCP 服务器 · \(draft.mcpServers.count)") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach($draft.mcpServers) { $server in
                            HStack {
                                Toggle(server.name, isOn: $server.enabled)
                                Spacer()
                                Button {
                                    draft.mcpServers.removeAll { $0.name == server.name }
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("移除服务器")
                            }
                            Text(server.url).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        TextField("服务器名称", text: $serverName).textFieldStyle(.roundedBorder)
                        TextField("https://example.com/mcp", text: $serverURL).textFieldStyle(.roundedBorder)
                        Button("添加服务器", action: addServer)
                            .disabled(serverName.isEmpty || serverURL.isEmpty)
                        Text("MCP 和子任务配置同时用于 Agents API 与 opencode。Agents API 从本机执行环境连接 MCP；Claude / Codex CLI 使用各自已有的工具配置。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.top, 6)
                }
            }
            .font(.system(size: 12))
            .disabled(viewModel.hasAgentWork)

            if viewModel.hasAgentWork {
                Text("任务进行中，完成或取消后可修改配置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result {
                Text(result).font(.caption).foregroundStyle(failed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("保存") {
                    do {
                        try viewModel.saveAgentConfiguration(draft, memory: memory)
                        result = "已保存，下次请求使用新配置。"
                        failed = false
                    } catch {
                        result = error.localizedDescription
                        failed = true
                    }
                }.disabled(viewModel.hasAgentWork).buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            draft = viewModel.agentConfiguration
            do {
                if FileManager.default.fileExists(atPath: AgentConfiguration.memoryURL.path) {
                    memory = try String(contentsOf: AgentConfiguration.memoryURL, encoding: .utf8)
                }
            } catch {
                result = "记忆读取失败：\(error.localizedDescription)"
                failed = true
            }
        }
    }

    private func capability(_ label: String, icon: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.blue)
            Text(label).font(.system(size: 11, weight: .medium)).frame(width: 122, alignment: .leading)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func directoryRow(_ label: String, path: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 76, alignment: .leading)
            Text(path.wrappedValue.isEmpty ? "默认" : (path.wrappedValue as NSString).abbreviatingWithTildeInPath)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            if !path.wrappedValue.isEmpty {
                Button { path.wrappedValue = "" } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("恢复默认目录")
            }
            Button("选择") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.prompt = "选择"
                if panel.runModal() == .OK, let url = panel.url {
                    path.wrappedValue = url.resolvingSymlinksInPath().path
                }
            }
        }
    }

    private func addServer() {
        var candidate = draft
        candidate.mcpServers.append(AgentMCPServer(name: serverName.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    url: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)))
        do {
            try candidate.validate()
            draft = candidate
            serverName = ""
            serverURL = ""
            result = nil
        } catch {
            result = error.localizedDescription
            failed = true
        }
    }
}
