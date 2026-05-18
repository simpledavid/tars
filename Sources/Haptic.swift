import AppKit

/// 触觉反馈（trackpad 微震）统一入口。
/// 调用 `Haptic.tap(.alignment)` 等同于 NSHapticFeedbackManager + 检查用户开关。
///
/// 设置里"触觉反馈"开关存在 UserDefaults["hapticEnabled"]（默认开），
/// 关闭后所有 tap() 调用静默 no-op，调用方不需要自己判断
enum Haptic {
    /// trackpad 触觉反馈类型：
    /// - .alignment：极轻的对齐感（适合 mode 切换 / 按下热键）
    /// - .levelChange：明显的层级跳变（适合截屏成功 / 任务完成）
    /// - .generic：通用提示
    static func tap(_ kind: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        // UserDefaults 没设过时默认开启 —— object(forKey:) 返回 nil 走 ?? true
        let enabled = (UserDefaults.standard.object(forKey: "hapticEnabled") as? Bool) ?? true
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(kind, performanceTime: .now)
    }
}
