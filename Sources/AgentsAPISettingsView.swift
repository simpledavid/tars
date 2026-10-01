import SwiftUI

struct AgentsAPISettingsView: View {
    @Bindable var viewModel: ChatViewModel
    @State private var model = AgentsAPISettings.load().model
    @State private var applicationKey = ""
    @State private var environmentKey = ""
    @State private var result: String?
    @State private var failed = false
    @State private var testing = false
    @State private var saved = false
    @State private var validationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OpenAI Agents API · Beta").font(.system(size: 13, weight: .semibold))
            TextField("模型", text: $model).textFieldStyle(.roundedBorder).disabled(testing || viewModel.hasAgentWork)
            SecureField("应用密钥", text: $applicationKey).textFieldStyle(.roundedBorder).disabled(testing || viewModel.hasAgentWork)
            SecureField("执行环境密钥", text: $environmentKey).textFieldStyle(.roundedBorder).disabled(testing || viewModel.hasAgentWork)
            Text("两种密钥保存在系统钥匙串。应用密钥需要 agents.read、agents.write、responses.write；执行环境密钥只开放连接环境权限。两者须属于同一项目与账号。")
                .font(.caption2).foregroundStyle(.secondary)
            Text("本机需要支持 exec-server 的 Codex CLI。它是文件与命令执行器；登录 Codex CLI 的账号不能替代这两种 API 密钥。")
                .font(.caption2).foregroundStyle(.secondary)
            Link("密钥与执行器配置说明", destination: URL(string: "https://developers.openai.com/api/docs/guides/agents-api/environments/self-hosted")!)
                .font(.caption)
            HStack {
                Button("保存") {
                    do {
                        try AgentsAPISettings.save(model: model, credentials: AgentsCredentials(
                            applicationKey: applicationKey.trimmingCharacters(in: .whitespacesAndNewlines),
                            environmentKey: environmentKey.trimmingCharacters(in: .whitespacesAndNewlines)))
                        saved = true
                        failed = false
                        result = "已保存。先检测权限与执行器，再验证一次真实对话。"
                        viewModel.checkConnection()
                    } catch { report(error) }
                }.disabled(testing || viewModel.hasAgentWork)
                Button(testing ? "检测中…" : "检测连接") { checkConnection() }
                    .disabled(!saved || testing || viewModel.hasAgentWork)
                Spacer()
            }
            Button("验证一次对话") { validateTurn() }
                .disabled(!saved || testing || viewModel.hasAgentWork)
            if testing {
                Button("取消验证") { validationTask?.cancel() }
            }
            Text("检测连接只读取接口。验证对话会创建临时会话并调用一次模型，按 API 用量计费；成功后会清理临时会话。")
                .font(.caption2).foregroundStyle(.secondary)
            if let result {
                Text(result).font(.caption).foregroundStyle(failed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .onDisappear { validationTask?.cancel() }
        .onChange(of: model) { _, _ in saved = false }
        .onChange(of: applicationKey) { _, _ in saved = false }
        .onChange(of: environmentKey) { _, _ in saved = false }
        .onAppear {
            do {
                applicationKey = try AgentsKeychain.read(account: "application") ?? ""
                environmentKey = try AgentsKeychain.read(account: "environment") ?? ""
                // State edits may fire onChange after onAppear. Detect availability explicitly on save.
                saved = false
                if !applicationKey.isEmpty && !environmentKey.isEmpty { result = "钥匙串中已有密钥；保存后可检测。" }
            } catch { report(error) }
        }
    }

    private func checkConnection() {
        testing = true
        validationTask = Task {
            defer { testing = false }
            do {
                try await AgentsAPIClient().checkConnection()
                failed = false
                result = "应用接口可读，执行器版本可用。执行环境密钥与模型仍需真实对话验证。"
            } catch { report(error) }
        }
    }

    private func validateTurn() {
        testing = true
        validationTask = Task {
            defer { testing = false }
            do {
                var text = ""
                for try await chunk in viewModel.streamOneShotAsk(
                    prompt: "只回复：Tars Agents API 连接成功。不要调用任何文件或命令工具。",
                    modeOverride: .directAPI, recordToActivity: false) { text += chunk }
                guard !text.isEmpty else { throw AgentsAPIError.message("模型没有返回文本") }
                failed = false
                result = "真实对话成功：\(text.prefix(160))"
            } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        failed = true
        result = error.localizedDescription
    }
}
