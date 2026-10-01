import Foundation

struct ChatIssue: Codable, Equatable {
    enum Recovery: String, Codable {
        case settings, signIn, usage, inspectTask, reconnect
        var label: String {
            switch self {
            case .settings: "打开设置"
            case .signIn: "重新登录"
            case .usage: "查看额度"
            case .inspectTask: "检查任务状态"
            case .reconnect: "检查连接"
            }
        }
    }
    var message: String
    var recovery: Recovery?
    var relatedMessageID: String?
    var isPersistent: Bool

    static func classify(_ message: String, unconfirmedTask: Bool = false) -> Self {
        let recovery: Recovery?
        if unconfirmedTask || message.contains("结果尚未确认") || message.contains("不会自动重放") || message.contains("本次输入尚未发送") {
            recovery = .inspectTask
        } else if message.contains("额度已用尽") || message.contains("使用上限") || message.contains("429") {
            recovery = .usage
        } else if message.contains("授权已失效") || message.contains("重新登录") || message.contains("先登录 ChatGPT") || message.contains("401") {
            recovery = .signIn
        } else if message.contains("设置") || message.contains("配置") || message.contains("安装") || message.contains("权限") {
            recovery = .settings
        } else if message.contains("连接") || message.contains("断开") || message.contains("超时") || message.contains("网络") {
            recovery = .reconnect
        } else { recovery = nil }
        let persistent = recovery != nil || message.contains("失败") || message.contains("错误")
        return Self(message: message, recovery: recovery, isPersistent: persistent)
    }
}
