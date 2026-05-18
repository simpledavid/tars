import SwiftUI

/// 桌宠"生命感"修饰符 —— 让任意 View 拥有桌宠般的"活着"感：
/// - **慢呼吸**：scale 1.0 ↔ 1.05，2s 一周期
/// - **随机眨眼**：每 8~15s 一次，180ms 短暗（alpha → 0.25 → 1.0）
/// - **完成跳跃**：收到 `HermesPetTaskFinished` (success=true) 通知时，
///   向上跳 4pt + spring 落回 + 一圈淡白光晕扩散
///
/// 全局开关：UserDefaults `petAnimationsEnabled`（默认 true），
/// 通过 `.lifeSigns(enabled:)` 视图扩展按需开启。
struct LifeSignsModifier: ViewModifier {
    @State private var breathScale: CGFloat = 1.0
    @State private var blinkOpacity: Double = 1.0
    @State private var jumpOffset: CGFloat = 0
    @State private var glowOpacity: Double = 0
    @State private var glowScale: CGFloat = 0.4
    @State private var blinkTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scaleEffect(breathScale)
            .offset(y: jumpOffset)
            .opacity(blinkOpacity)
            .background(
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.85), .white.opacity(0)],
                            center: .center,
                            startRadius: 1,
                            endRadius: 11
                        )
                    )
                    .frame(width: 22, height: 22)
                    .scaleEffect(glowScale)
                    .opacity(glowOpacity)
                    .allowsHitTesting(false)
            )
            .onAppear {
                startBreathing()
                scheduleNextBlink()
            }
            .onDisappear {
                blinkTask?.cancel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetTaskFinished"))) { note in
                let success = (note.userInfo?["success"] as? Bool) ?? false
                if success { performCompletionJump() }
            }
    }

    private func startBreathing() {
        breathScale = 1.0
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            breathScale = 1.05
        }
    }

    private func scheduleNextBlink() {
        blinkTask?.cancel()
        blinkTask = Task { @MainActor in
            let delayNs = UInt64.random(in: 8_000_000_000...15_000_000_000)
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }

            // 半闭眼 → 张眼，180ms 完成
            withAnimation(.easeInOut(duration: 0.09)) {
                blinkOpacity = 0.25
            }
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.09)) {
                blinkOpacity = 1.0
            }
            // 排下一次
            scheduleNextBlink()
        }
    }

    private func performCompletionJump() {
        // 向上弹 4pt
        withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
            jumpOffset = -4
        }
        // 同时光晕扩散
        glowScale = 0.4
        glowOpacity = 0.55
        withAnimation(.easeOut(duration: 0.55)) {
            glowScale = 1.5
            glowOpacity = 0
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                jumpOffset = 0
            }
        }
    }
}

extension View {
    /// 给视图（通常是图标）加上桌宠生命感动画。
    /// 设置里 "安静模式" 开启时 enabled=false，整个 modifier 不挂上，零开销。
    @ViewBuilder
    func lifeSigns(enabled: Bool) -> some View {
        if enabled {
            self.modifier(LifeSignsModifier())
        } else {
            self
        }
    }
}
