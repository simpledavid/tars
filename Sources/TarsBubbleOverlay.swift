import AppKit
import SwiftUI

/// TARS 头顶与灵动岛旁边的状态气泡。
///
/// 触发时机：
///   - 任务超过 30s：「等等，快好了…」
///   - 任务超过 90s：「emm，再花点时间」
///   - 任务出错（success=false）：「糟糕 😵」
///
/// 实现：单独 NSWindow，level .statusBar，浮在灵动岛胶囊**右下方**，
/// 1.8s 自动淡出。跟 VoiceTranscriptOverlay 同款轻量模式
@MainActor
final class TarsBubbleOverlayController {
    static let shared = TarsBubbleOverlayController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<TarsBubbleView>?
    private let viewState = BubbleState()
    private var hideTask: Task<Void, Never>?

    private init() {
        registerNotifications()
    }

    // MARK: - 公开入口（其他控件直接 post 通知触发）

    /// 触发气泡显示。text 是要展示的文字，duration 默认 1.8s
    static func show(_ text: String, duration: TimeInterval = 1.8) {
        NotificationCenter.default.post(
            name: .init("HermesPetTarsBubble"),
            object: nil,
            userInfo: ["text": text, "duration": duration]
        )
    }

    // MARK: - Notifications

    private func registerNotifications() {
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetTarsBubble"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let text = (note.userInfo?["text"] as? String) ?? ""
            let dur = (note.userInfo?["duration"] as? TimeInterval) ?? 1.8
            Task { @MainActor in
                self?.showBubble(text: text, duration: dur)
            }
        }
    }

    // MARK: - Show / Hide

    private func showBubble(text: String, duration: TimeInterval) {
        guard !text.isEmpty else { return }
        if window == nil { createWindow() }
        viewState.text = text
        viewState.isVisible = true
        positionWindow()
        window?.orderFront(nil)

        // 取消上一个隐藏 task，重新计时
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if Task.isCancelled { return }
            viewState.isVisible = false
            try? await Task.sleep(nanoseconds: 350_000_000)   // 等淡出动画
            if Task.isCancelled { return }
            window?.orderOut(nil)
            viewState.text = ""
        }
    }

    // MARK: - Window

    private func createWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 50),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        w.level = HermesWindowLevel.auxiliary   // 低于灵动岛，见 WindowLevels.swift
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: TarsBubbleView(state: viewState))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 50)
        host.autoresizingMask = [.width, .height]
        w.contentView = host

        self.window = w
        self.hostingView = host
    }

    /// 浮在灵动岛下方，与左耳的 TARS 斜向对应。
    private func positionWindow() {
        guard let window = window else { return }
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
        guard let screen = screen else { return }
        let frame = screen.frame
        let safeArea = screen.safeAreaInsets
        let notchHeight: CGFloat = safeArea.top > 0 ? safeArea.top : 28

        // 估算文字宽度（每字 14pt + padding 32）
        let charCount = viewState.text.count
        let estimatedWidth: CGFloat = min(360, max(100, CGFloat(charCount) * 14 + 36))
        let windowHeight: CGFloat = 38

        // x：刘海中心 - 灵动岛宽度一半 - 一段距离。
        let bubbleX = frame.midX - 200 - estimatedWidth / 2
        // y：灵动岛胶囊本体下方 24pt
        let bubbleY = frame.maxY - notchHeight - 8 - windowHeight - 18

        window.setFrame(
            NSRect(x: bubbleX, y: bubbleY, width: estimatedWidth, height: windowHeight),
            display: true
        )
    }
}

// MARK: - State

@Observable
@MainActor
final class BubbleState {
    var text: String = ""
    var isVisible: Bool = false
}

// MARK: - SwiftUI Bubble

/// TARS 状态气泡。
struct TarsBubbleView: View {
    @Bindable var state: BubbleState

    private static let tarsBlue = Color(red: 0.35, green: 0.82, blue: 1.0)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if state.isVisible {
                Text(state.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.black.opacity(0.82))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Self.tarsBlue.opacity(0.35), lineWidth: 0.6)
                    )
                    .shadow(color: .black.opacity(0.30), radius: 10, y: 4)
                    .transition(.scale(scale: 0.7, anchor: .topTrailing)
                        .combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: state.isVisible)
    }
}
