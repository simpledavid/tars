import AppKit

/// Finder 桌面上的一个项目（文件 / 文件夹）。
/// Clawd 巡视桌面时会随机挑一个走过去，嗅一下，让 AI 短评文件名
struct DesktopIcon: Equatable {
    let name: String
    /// NSScreen 坐标系（bottom-left origin, y-up）。Clawd 走到这附近做 sniff
    let position: NSPoint
    /// 文件夹给一个不同的口吻（"翻翻这个" vs "看这名字"）
    let isFolder: Bool
}

/// 用 osascript 调 Finder 读桌面图标 (name, position, kind) 列表。
///
/// **权限**：osascript 控制 Finder 第一次会弹"允许 HermesPet 控制 Finder"对话框。
/// 用户拒绝 → 永久返回空数组，Clawd 巡视会静默退化为"无图标，走一圈就回去"。
///
/// **性能**：osascript 启动 + Finder AppleScript 遍历桌面 ~200-400ms。
/// 缓存 5min（用户改桌面不算频繁），Clawd 每次巡视命中缓存即可。
/// **隐私**：本地黑名单关键词命中就直接丢弃，**不会发给 AI 也不会出现在气泡里**
@MainActor
final class DesktopIconReader {
    static let shared = DesktopIconReader()

    private var cache: [DesktopIcon] = []
    private var cacheAt: Date = .distantPast
    private var inflight: Task<[DesktopIcon], Never>? = nil

    private static let cacheTTL: TimeInterval = 300   // 5 min
    /// 含这些关键词的文件名直接跳过 —— 避免 Clawd 把敏感名字吐到气泡 / 发给 AI。
    /// 中文优先（用户多半中文文件名）；英文兜底
    private static let blacklistKeywords: [String] = [
        "薪资", "工资", "合同", "协议", "密码", "私密", "保密", "身份证", "银行卡",
        "passwd", "password", "secret", "private", ".env", "credential",
        "credit", "tax", "ssn", "social"
    ]

    private init() {}

    /// 强制下次 snapshot 重新读 Finder（用户刚开桌面巡视开关时调一次）
    func invalidate() {
        cache = []
        cacheAt = .distantPast
    }

    /// 返回桌面图标快照。命中缓存零延迟；过期 → spawn osascript 异步读
    func snapshot() async -> [DesktopIcon] {
        if Date().timeIntervalSince(cacheAt) < Self.cacheTTL, !cache.isEmpty {
            return cache
        }
        // 已经有飞行中的请求 → 共享同一次（避免巡视触发瞬间双调用）
        if let t = inflight { return await t.value }

        let task = Task<[DesktopIcon], Never> {
            await self.fetchFromFinder()
        }
        inflight = task
        let icons = await task.value
        inflight = nil
        cache = icons
        cacheAt = Date()
        return icons
    }

    /// 真正干活：osascript → 解析 → 坐标转换
    private func fetchFromFinder() async -> [DesktopIcon] {
        // NSScreen 几何要在 MainActor 上抓（self 已 MainActor，这里就是）
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
                            ?? NSScreen.main else {
            return []
        }
        let screenFrame = screen.frame
        // Finder 桌面坐标的 (0,0) = 屏幕去掉菜单栏后的左上角；
        // 转 NSScreen 系（bottom-left）：screenY = visibleFrame.maxY - finder_y
        let desktopTopScreenY = screen.visibleFrame.maxY

        let script = """
        tell application "Finder"
          set out to ""
          try
            set itemList to items of desktop
            repeat with itm in itemList
              try
                set nm to name of itm
                set pos to position of itm
                set kindStr to class of itm as text
                set out to out & nm & tab & (item 1 of pos) & tab & (item 2 of pos) & tab & kindStr & linefeed
              end try
            end repeat
          end try
          return out
        end tell
        """

        let raw = await Self.runOsascript(script)
        guard !raw.isEmpty else { return [] }

        var icons: [DesktopIcon] = []
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 4 else { continue }
            let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            guard let fx = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  let fy = Double(parts[2].trimmingCharacters(in: .whitespaces)) else { continue }
            // Finder 给 (-1,-1) 表示"无固定位置"（自动排列里没排完）—— 跳过
            guard fx >= 0, fy >= 0 else { continue }
            // 黑名单：含敏感关键词 → 跳过
            let lower = name.lowercased()
            if Self.blacklistKeywords.contains(where: { lower.contains($0.lowercased()) }) { continue }

            let kindStr = String(parts[3]).lowercased()
            // Finder 类名：file / folder / document file / application file / disk 等
            let isFolder = kindStr.contains("folder")

            let screenX = screenFrame.minX + CGFloat(fx)
            let screenY = desktopTopScreenY - CGFloat(fy)
            // 安全裁剪：图标可能位于辅助屏 / 桌面边外，裁回主屏 visibleFrame
            guard screenFrame.contains(NSPoint(x: screenX, y: screenY)) else { continue }
            icons.append(DesktopIcon(
                name: name,
                position: NSPoint(x: screenX, y: screenY),
                isFolder: isFolder
            ))
        }
        return icons
    }

    /// spawn /usr/bin/osascript 异步执行，返回 stdout。
    /// 超时 3s（Finder 卡死时不能让 Clawd 也跟着卡）。失败/超时静默返回 ""
    private static func runOsascript(_ script: String) async -> String {
        await withCheckedContinuation { cont in
            let box = ResumeBox(cont)
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", script]
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                do {
                    try proc.run()
                } catch {
                    box.resume("")
                    return
                }

                // 3s 超时兜底：Finder 偶尔卡死，不让 Clawd 跟着卡
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) {
                    if proc.isRunning {
                        proc.terminate()
                        box.resume("")
                    }
                }

                proc.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let s = String(data: data, encoding: .utf8) ?? ""
                box.resume(s)
            }
        }
    }
}

/// Continuation 恢复保护盒 —— 给 osascript 后台子进程用：
/// 主线程超时分支 + 后台 waitUntilExit 分支可能竞争 resume，用 NSLock 保证只 resume 一次。
/// Swift 6 严格并发下，跨线程 capture 局部 var 会报 SendableClosureCaptures，所以提取成引用类型
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<String, Never>
    init(_ cont: CheckedContinuation<String, Never>) { self.cont = cont }
    func resume(_ value: String) {
        lock.lock()
        let alreadyDone = done
        if !done { done = true }
        lock.unlock()
        if !alreadyDone { cont.resume(returning: value) }
    }
}
