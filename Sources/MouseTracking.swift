import AppKit

/// 全局鼠标位置追踪 —— 让 Clawd 的眼睛跟着鼠标看。
///
/// 用 NSEvent.addGlobalMonitorForEvents 监听全屏鼠标移动（不需要任何 entitlement）。
/// 每次移动计算鼠标在带刘海屏的 X 比例，分成 left/center/right 三档：
///   - x < 40%  → .left
///   - x > 60%  → .right
///   - 其余     → .center
///
/// 仅在 area **变化**时 post `HermesPetMouseAreaChanged` 通知，所以接收方
/// （ClaudeKnotSprite）不需要节流，自动只在状态切换时刷新一次 pose。
@MainActor
final class MouseTrackingController {
    static let shared = MouseTrackingController()

    enum MouseArea: String { case left, center, right }

    private var monitor: Any?
    private var lastArea: MouseArea = .center

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            // global monitor closure 在主线程触发（macOS 14+），但保险起见显式 hop
            Task { @MainActor in
                self?.handleMouseMove()
            }
        }
    }

    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    private func handleMouseMove() {
        // 优先用带刘海的屏（外接显示器场景下 NSScreen.main 不一定是 MacBook 自带屏）
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
        guard let screen = screen else { return }

        let mouseLoc = NSEvent.mouseLocation       // 屏幕全局坐标
        let frame = screen.frame
        // 鼠标可能在其他屏 —— 仅当鼠标在这块屏内才计算（其他屏视为 center）
        let area: MouseArea
        if mouseLoc.x < frame.minX || mouseLoc.x > frame.maxX {
            area = .center
        } else {
            let relativeX = (mouseLoc.x - frame.minX) / frame.width
            if relativeX < 0.40      { area = .left }
            else if relativeX > 0.60 { area = .right }
            else                     { area = .center }
        }

        guard area != lastArea else { return }
        lastArea = area
        NotificationCenter.default.post(
            name: .init("HermesPetMouseAreaChanged"),
            object: nil,
            userInfo: ["area": area.rawValue]
        )
    }
}
