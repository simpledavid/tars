import SwiftUI

struct AgentTaskDetailsView: View {
    let activity: AgentTaskActivity
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("任务过程").font(.headline)
                Spacer()
                Text(activity.label).font(.caption).foregroundStyle(activity.isWaiting ? .orange : .secondary)
            }
            if activity.tools.isEmpty {
                Text(activity.phase == .idle ? "发送消息后，这里会显示当前对话的工具操作。" : "尚无工具操作。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(activity.tools) { tool in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: tool.failed ? "exclamationmark.circle" : tool.finished ? "checkmark.circle" : tool.kind.iconName)
                                    .foregroundStyle(tool.failed ? .orange : .secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tool.kind.verb).font(.caption.weight(.medium))
                                    if !tool.argument.isEmpty {
                                        Text(tool.argument).font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(4).textSelection(.enabled)
                                    }
                                    if tool.failed { Text("失败或未确认完成").font(.caption2).foregroundStyle(.orange) }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
            }
            if activity.isWaiting { Text("请在权限卡片或问题窗口中处理，任务随后继续。") .font(.caption).foregroundStyle(.secondary) }
        }
        .padding(16).frame(width: 320)
    }
}

struct ConversationModelDetailsView: View {
    @Bindable var viewModel: ChatViewModel
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.currentModelLabel).font(.headline).textSelection(.enabled)
            Text(viewModel.agentMode == .directAPI ? viewModel.currentAssistantEngine.label : viewModel.agentMode.label)
                .font(.caption).foregroundStyle(.secondary)
            if viewModel.agentMode == .directAPI && viewModel.currentAssistantEngine == .chatGPT {
                Text(viewModel.chatGPTConversationInfo).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("首次发送后，账号和模型绑定此对话。设置中的更改用于新对话。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if viewModel.agentMode == .directAPI {
                Text("显示当前或最近请求使用的模型；图片请求可能使用服务商的视觉模型。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("由本机 CLI 配置选择模型。Tars 尚未取得本次请求的模型标识。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Button("助手设置") { onClose(); DispatchQueue.main.async { viewModel.openAssistantSettings() } }
            Button("新建 AI 助手对话") { onClose(); DispatchQueue.main.async { viewModel.newConversation(mode: .directAPI) } }
            if viewModel.advancedCLIEnabled {
                Menu("其他通道") {
                    Button("新建 Claude Code 对话") { onClose(); DispatchQueue.main.async { viewModel.newConversation(mode: .claudeCode) } }
                    Button("新建 Codex 对话") { onClose(); DispatchQueue.main.async { viewModel.newConversation(mode: .codex) } }
                }
            }
        }.padding(16).frame(width: 300)
    }
}

struct ChatIssueCard: View {
    let issue: ChatIssue
    let busy: Bool
    let recoveryDisabled: Bool
    let onRecover: () -> Void
    var onOpenDirectory: (() -> Void)? = nil
    let onDismiss: () -> Void
    @State private var showDetails = false
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(issue.message).font(.system(size: 12)).lineLimit(5)
                    .textSelection(.enabled).accessibilityLabel(issue.message)
                HStack(spacing: 10) {
                    if let recovery = issue.recovery {
                        Button(busy ? "正在检查…" : recovery.label, action: onRecover)
                            .disabled(busy || recoveryDisabled)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    if let onOpenDirectory { Button("打开工作目录", action: onOpenDirectory).disabled(busy) }
                    Button { showDetails.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain).help("查看完整错误")
                        .popover(isPresented: $showDetails) {
                            ScrollView { Text(issue.message).font(.callout).textSelection(.enabled).padding(16) }
                                .frame(width: 340).frame(maxHeight: 300)
                        }
                }.font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).padding(3) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭提示")
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.25), lineWidth: 0.5))
    }
}
