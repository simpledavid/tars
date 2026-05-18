import SwiftUI

/// 全局动画常量，参照 Apple HIG（响应感 + 物理感）。
/// 各处用同一套 token 保证整个 App 的"动画语言"统一。
enum AnimTok {
    /// 微交互（按钮、tap 反馈、状态切换）—— 短促但稳重
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.86)

    /// 标准过渡（hover 展开、布局切换）—— 平滑无晃动
    static let smooth = Animation.spring(response: 0.35, dampingFraction: 0.85)

    /// 入场动画（窗口展开、消息出现）—— 略带弹性，有生命力
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.78)

    /// 退场动画（窗口收回、删除）—— 稍快、收得干净
    static let exit = Animation.spring(response: 0.28, dampingFraction: 0.92)

    /// 装饰性循环（呼吸、闪烁）
    static let breathe = Animation.easeInOut(duration: 1.4).repeatForever(autoreverses: true)
    static let blink   = Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true)
}
