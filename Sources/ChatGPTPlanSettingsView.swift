import AppKit
import SwiftUI

struct ChatGPTPlanSettingsView: View {
    @Bindable var viewModel: ChatViewModel
    @Bindable private var auth = ChatGPTPlanAuth.shared
    @State private var codexAvailable = false
    @State private var checking = false
    @State private var verificationTask: Task<Void, Never>?
    @State private var verification: String?
    @State private var localError: String?
    @State private var showAccountManagement = false
    @State private var showDiagnostics = false

    private var locked: Bool { auth.busy || checking || viewModel.hasAgentWork }
    private var hasSafari: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") != nil }
    private var errorText: String? { localError ?? auth.errorMessage }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            connectionControls
            Divider()
            accountManagement
            diagnostics
            if let message = errorText {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .task {
            codexAvailable = await CLIAvailability.codexAvailable()
            revealRequestedDetail()
            if auth.isConnected { refresh() }
            if !codexAvailable { showDiagnostics = true }
        }
        .onChange(of: viewModel.settingsDetail) { _, _ in revealRequestedDetail() }
        .onChange(of: errorText) { _, error in if error != nil { showDiagnostics = true } }
        .onChange(of: auth.activeAccountID) { _, _ in verification = nil; if auth.isConnected { refresh() } }
        .onChange(of: auth.selectedModel) { _, _ in verification = nil }
        .onChange(of: auth.busy) { _, busy in if !busy { viewModel.checkConnection() } }
        .onDisappear { verificationTask?.cancel() }
    }
    private var modelFallbackLabel: String { auth.selectedModel.isEmpty ? "等待模型列表" : auth.selectedModel }
    @ViewBuilder private var connectionControls: some View {
            HStack {
                Label(auth.isConnected ? "订阅已授权" : "连接 ChatGPT 订阅",
                      systemImage: auth.isConnected ? "checkmark.circle.fill" : "person.crop.circle")
                    .font(.callout).foregroundStyle(auth.isConnected ? .green : .primary)
                Spacer()
                if auth.busy { ProgressView().controlSize(.small) }
            }
            if !auth.accounts.isEmpty {
                Picker("账号", selection: $auth.activeAccountID) {
                    Text("选择账号").tag("")
                    ForEach(auth.accounts) { account in Text(account.label).tag(account.id) }
                }.disabled(locked)
            }
            if !auth.isConnected {
                HStack {
                    Button(auth.busy ? "正在登录…" : "使用 ChatGPT 登录") { signIn() }
                        .buttonStyle(.borderedProminent).disabled(locked)
                    if auth.busy { Button("取消") { auth.cancelLogin() } }
                }
                Text("使用 Plus / Pro 订阅额度，无需 API Key。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("模型", selection: $auth.selectedModel) {
                    if auth.models.isEmpty { Text(modelFallbackLabel).tag(auth.selectedModel) }
                    ForEach(auth.models) { model in Text(model.display_name).tag(model.slug) }
                }.disabled(locked)
                Text("账号和模型用于新对话；已有对话保持首次发送时的绑定。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("查看订阅额度", destination: URL(string: "https://chatgpt.com/#settings")!).font(.caption)
            }

    }
    private var accountManagement: some View {
            DisclosureGroup("账号管理", isExpanded: $showAccountManagement) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button(auth.isConnected ? "重新授权" : "登录") { signIn() }.disabled(locked)
                        if hasSafari { Button("用 Safari 登录") { signIn(browser: "com.apple.Safari") }.disabled(locked) }
                    }
                    HStack {
                        Button("添加账号") { verification = nil; localError = nil; auth.signIn() }.disabled(locked)
                        if auth.isConnected {
                            Button("退出登录", role: .destructive) {
                                verification = nil; localError = nil
                                Task { await auth.disconnect(); viewModel.checkConnection() }
                            }.disabled(locked)
                        }
                        if auth.busy { Button("取消登录") { auth.cancelLogin() } }
                    }
                    Text("额度与 Codex、ChatGPT Work 共享。Tars 无法读取 ChatGPT 历史或记忆。")
                        .font(.caption).foregroundStyle(.secondary)
                    if auth.accounts.contains(where: { $0.id == auth.activeAccountID && $0.remoteRevocationPending }) {
                        Text("远端撤销尚未确认，请在 ChatGPT 设置中断开 Tars。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.padding(.top, 8)
            }
    }
    private var diagnostics: some View {
            DisclosureGroup("连接诊断", isExpanded: $showDiagnostics) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(codexAvailable ? "本机执行器已就绪" : "本机执行器未就绪", systemImage: codexAvailable ? "checkmark.circle" : "terminal")
                        .font(.caption).foregroundStyle(codexAvailable ? Color.secondary : Color.orange)
                    HStack {
                        Button("重新检测") { Task { codexAvailable = await CLIAvailability.codexAvailable(); viewModel.checkConnection() } }.disabled(locked)
                        if auth.isConnected { Button("刷新模型") { refresh() }.disabled(locked) }
                    }
                    if !codexAvailable {
                        Link("安装 Codex 执行器", destination: URL(string: "https://developers.openai.com/codex/cli")!).font(.caption)
                    }
                    if auth.isConnected {
                        HStack {
                            Button(checking ? "正在验证…" : "验证订阅连接") { verify() }
                                .disabled(locked || !codexAvailable || auth.selectedModel.isEmpty)
                            if checking { Button("取消") { verificationTask?.cancel() } }
                        }
                        if let verification { Label(verification, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                        Text("验证发送一条简短请求，消耗少量额度。模型列表不能证明请求可用。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("登录页出错时可用 Safari 重试；浏览器安全验证需在浏览器中完成。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("在 ChatGPT 设置 → Usage 管理 Tars 的额度与授权。本机访问权限按任务询问。")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
    }
    private func revealRequestedDetail() {
        if viewModel.settingsDetail == "account" { showAccountManagement = true }
        if viewModel.settingsDetail == "diagnostics" { showDiagnostics = true }
    }
    private func signIn(browser: String? = nil) {
        verification = nil; localError = nil
        auth.signIn(accountID: auth.activeAccountID.isEmpty ? nil : auth.activeAccountID, browserBundleID: browser)
    }
    private func refresh() {
        Task {
            do { try await auth.loadModels(); localError = nil; viewModel.checkConnection() }
            catch { localError = error.localizedDescription }
        }
    }
    private func verify() {
        checking = true; verification = nil; localError = nil
        verificationTask = Task { @MainActor in
            defer { checking = false; verificationTask = nil }
            let harness = AgentHarness(), id = "chatgpt-verification-\(UUID().uuidString)"
            defer { harness.reset(conversationID: id) }
            do {
                let request = try harness.prepare(messages: [.init(role: .user, content: "只回复：Tars 订阅连接成功。无需使用任何工具。")], conversationID: id, mode: .directAPI, engine: .chatGPT, configuration: viewModel.agentConfiguration, ephemeral: true)
                for try await _ in harness.stream(request) { try Task.checkCancellation() }
                try Task.checkCancellation(); verification = "真实请求验证通过"; viewModel.checkConnection()
            } catch is CancellationError { }
            catch { localError = error.localizedDescription }
        }
    }
}
