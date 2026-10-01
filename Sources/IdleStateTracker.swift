import AppKit
import CoreGraphics

/// 系统空闲检测 —— 用 CGEventSource 看用户多久没动鼠标/键盘了。
/// 3 分钟无任何输入 → 切换到 sleeping 态：
///   - 灵动岛圆点 dim + 飘 z
///   - TARS 从灵动岛进入桌面巡视
/// 用户重新动 → 立即恢复活跃态。
///
/// 工作机制：每 15s tick 一次，状态变化时 post `HermesPetUserIdleChanged` 通知。
/// 监听方：`IdleModeDot`、桌面漫步 controller
@MainActor
final class IdleStateTracker {
    static let shared = IdleStateTracker()

    private(set) var isSleeping = false
    private var timer: Timer?

    /// 阈值：3 分钟无任何输入 → sleeping
    private let sleepThresholdSeconds: TimeInterval = 180

    private init() {}

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // 取鼠标移动 / 键盘按键的最近时间，min 是"用户最后一次活跃"
        let m = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let k = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let idle = min(m, k)

        let newSleeping = idle >= sleepThresholdSeconds
        guard newSleeping != isSleeping else { return }
        isSleeping = newSleeping
        NotificationCenter.default.post(
            name: .init("HermesPetUserIdleChanged"),
            object: nil,
            userInfo: ["isSleeping": newSleeping]
        )
    }
}
