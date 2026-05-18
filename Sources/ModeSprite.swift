import SwiftUI

/// 灵动岛左耳的 mode 精灵 —— 显示当前 AgentMode 的标志元素，
/// 并在"工作中"（流式生成时）播放各自专属的动画。
///
/// Claude → 橘色 asterisk 自转（Claude 品牌色）
/// Hermes → 绿色羽毛轻摆（信使羽毛）
/// Codex  → 青色 `</>` 旁边加一个闪烁光标
struct ModeSpriteView: View {
    let mode: AgentMode
    /// 是否正在"工作中" —— 播放各自的动画
    let isWorking: Bool
    let size: CGFloat

    /// 全局调色板存储 —— @Observable，用户改色后此 View 自动 invalidate 重渲染
    @State private var paletteStore = PetPaletteStore.shared

    var body: some View {
        let palette = paletteStore.palette(for: mode)
        ClaudeKnotSprite(isWorking: isWorking, size: size, palette: palette)
    }
}

// MARK: - Claude：Clawd 🦞 (8-bit 像素小家伙，自家版本)

/// Clawd 的 pose 状态。形象**完全照搬 Anthropic 官方 SVG**（参考
/// marciogranzotto/clawd-tank/clawd-static-base.svg）：viewBox 15×10 上的
/// 几个矩形组件构成 —— torso 大矩形 + 左右手臂 + 4 条腿（2+2 不等距）+
/// 两个 1×2 竖长眼睛 + 半透明地面阴影。
///
/// pose 主要影响眼神方向和 armsUp（伸懒腰）。
/// 走路 / 呼吸 / 眨眼等动画由 ClawdView 内部 TimelineView 自动驱动
enum ClawdPose {
    case rest, lookLeft, lookRight, armsUp
}

/// Clawd sprite 的一个像素矩形组件。坐标在 viewBox 15×10 内
/// （已减去官方 SVG 原 y=6 偏移，让 sprite 从 y=0 开始）
struct ClawdRect {
    let x: CGFloat
    let y: CGFloat
    let w: CGFloat
    let h: CGFloat
}

/// 官方 Clawd 像素渲染器
///
/// 像素图（viewBox 15×10）：
/// ```
///         0  1  2  3  4  5  6  7  8  9 10 11 12 13 14
/// row 0:           ████████████████████████████          ← torso 顶
/// row 1:           ████████████████████████████
/// row 2:           ██████ ▣  ██████████ ▣  ██████        ← 眼睛 col 4, col 10
/// row 3:        █████████████████████████████████        ← 手臂左右伸 col 0-1, col 13-14
/// row 4:        █████████████████████████████████
/// row 5:           ████████████████████████████
/// row 6:           ████████████████████████████          ← torso 底
/// row 7:                  ██    ██       ██    ██        ← 4 腿（col 3, 5, 9, 11）
/// row 8:                  ██    ██       ██    ██
/// row 9:                 ░░░░░░░░░░░░░░░░░░░░░           ← 半透明地面阴影
/// ```
///
/// 动画（TimelineView 自动驱动）：
/// 1. **呼吸** 3.2s loop，scale ±2% 横纵反向
/// 2. **眨眼** 5s 间隔，最后 200ms 闭眼
/// 3. **走路** (isWalking=true 时) 1s loop：身体 bob + 4 腿对角交替 + 手臂上下摆
/// 4. **眼神** lookLeft/lookRight → 眼睛 translate ±2 unit
/// 5. **伸懒腰** armsUp → 身体 scale(0.95, 1.10) + 手臂上抬
struct ClawdView: View {
    let pose: ClawdPose
    /// 精灵高度。最终 frame 宽 = height × 1.5（viewBox 15:10）
    let height: CGFloat
    /// 是否正在走路 —— 控制 4 条腿对角交替抬放
    var isWalking: Bool = false
    /// 眼睛是否要平滑跟随鼠标（pose 为 .rest 时才生效；
    /// .lookLeft/.lookRight/.armsUp 时仍用离散偏移以保留这些 pose 表达力）
    var followMouse: Bool = false
    /// 调色板 —— 主色 + 派生高光/阴影。默认 Anthropic 官方橙；用户调色后从 PaletteStore 传入
    var palette: PetPalette = .clawdDefault

    private static let viewBoxW: CGFloat = 15
    private static let viewBoxH: CGFloat = 10
    /// scale 锚点：sprite 中心
    private static let centerX: CGFloat = 7.5
    private static let centerY: CGFloat = 5.0

    // 官方静态 sprite 矩形（viewBox 15×10，已减去 y=6 偏移）
    private static let torso     = ClawdRect(x: 2,  y: 0, w: 11, h: 7)
    private static let leftArm   = ClawdRect(x: 0,  y: 3, w: 2,  h: 2)
    private static let rightArm  = ClawdRect(x: 13, y: 3, w: 2,  h: 2)
    /// 4 条腿。索引 0-3 = outer-left / inner-left / inner-right / outer-right
    /// 走路时 (0, 2) 一组（leg-a），(1, 3) 一组（leg-b）—— 对角交替
    private static let legs: [ClawdRect] = [
        ClawdRect(x: 3,  y: 7, w: 1, h: 2),
        ClawdRect(x: 5,  y: 7, w: 1, h: 2),
        ClawdRect(x: 9,  y: 7, w: 1, h: 2),
        ClawdRect(x: 11, y: 7, w: 1, h: 2),
    ]
    private static let leftEye  = ClawdRect(x: 4,  y: 2, w: 1, h: 2)
    private static let rightEye = ClawdRect(x: 10, y: 2, w: 1, h: 2)
    private static let shadow   = ClawdRect(x: 3,  y: 9, w: 9, h: 1)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/60.0)) { timeline in
            Canvas(rendersAsynchronously: false) { ctx, size in
                draw(ctx: ctx, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: height * Self.viewBoxW / Self.viewBoxH, height: height)
    }

    // MARK: - 绘制

    private func draw(ctx: GraphicsContext, size: CGSize, now: TimeInterval) {
        let unit = min(size.width / Self.viewBoxW, size.height / Self.viewBoxH)
        let bodyFill = GraphicsContext.Shading.color(palette.primary)
        // body 顶部高光（自动从主色 +12% brightness 派生）：模拟左上光源，让 sprite 立体
        let bodyTopShading = GraphicsContext.Shading.color(palette.derivedTop)
        // body 底部阴影（自动从主色 -15% brightness 派生）：增加体积感
        let bodyBottomShading = GraphicsContext.Shading.color(palette.derivedBottom)
        let eyeFill  = GraphicsContext.Shading.color(.black)
        let highlightFill = GraphicsContext.Shading.color(.white)
        let shadowFill = GraphicsContext.Shading.color(.black.opacity(0.5))

        // —— 动画参数 ——

        // 呼吸 3.2s loop，scale ±2% 横纵反向
        let breatheT = sin(now * 2 * .pi / 3.2)
        let breatheSX: CGFloat = 1 + CGFloat(breatheT) * 0.02
        let breatheSY: CGFloat = 1 - CGFloat(breatheT) * 0.02

        // 走路 phase 0~1
        let walkPhase = isWalking ? now.truncatingRemainder(dividingBy: 1.0) : 0

        // 眨眼：每 4.5s 一次，最后 0.18s 闭眼（比之前略快眨频更俏皮）
        let blinkCycle = 4.5
        let blinkPhase = now.truncatingRemainder(dividingBy: blinkCycle) / blinkCycle
        let isBlinking = blinkPhase > 0.96

        // 眼神偏移（看左/看右）
        // pose 为 .rest 且 followMouse 时：眼睛连续跟随鼠标 x/y 坐标
        // 其他 pose（lookLeft/lookRight/armsUp）保留离散偏移，让这些 pose 仍能表达"刻意瞥一眼"
        let (eyeLookX, eyeLookY): (CGFloat, CGFloat) = {
            switch pose {
            case .lookLeft:  return (-2, 0)
            case .lookRight: return ( 2, 0)
            case .armsUp:    return ( 0, 0)
            case .rest:
                guard followMouse else { return (0, 0) }
                return Self.continuousMouseEyeOffset()
            }
        }()

        // 伸懒腰（armsUp pose）
        let stretching = (pose == .armsUp)
        let stretchSX: CGFloat = stretching ? 0.95 : 1.0
        let stretchSY: CGFloat = stretching ? 1.10 : 1.0
        let stretchDY: CGFloat = stretching ? -1.0 : 0.0
        let armRaise:  CGFloat = stretching ? -3.0 : 0.0

        // 走路身体 bob：0%/50% 下沉 +1，25%/75% 抬 0
        let bodyBobY: CGFloat = isWalking
            ? ((walkPhase < 0.25 || (walkPhase >= 0.5 && walkPhase < 0.75)) ? 1 : 0)
            : 0

        // 走路时身体左右微微 sway（±0.4 单位）—— 像企鹅一摇一摆，比原版纯上下 bob 更生动
        let walkSwayX: CGFloat = isWalking
            ? CGFloat(sin(walkPhase * 2 * .pi)) * 0.4
            : 0

        // 走路手臂 ±1.5 摆动（左右反向）—— 比原 ±1 略大，步态更有力
        let armSwingAmount: CGFloat = 1.5
        let armWaveL: CGFloat = isWalking
            ? ((walkPhase < 0.25 || (walkPhase >= 0.5 && walkPhase < 0.75)) ? -armSwingAmount : armSwingAmount)
            : 0
        let armWaveR: CGFloat = -armWaveL

        // 总变换
        let totalSX = breatheSX * stretchSX
        let totalSY = breatheSY * stretchSY
        let totalDY = bodyBobY + stretchDY
        let totalDX = walkSwayX

        // —— 渲染 ——

        // 阴影（不参与 body scale / sway，固定贴地）
        drawRect(Self.shadow, in: ctx, unit: unit,
                 offsetX: 0, offsetY: 0,
                 scaleX: 1, scaleY: 1, fill: shadowFill)

        // 4 条腿（对角交替；不跟 sway —— 保持地面接触感）
        for (idx, leg) in Self.legs.enumerated() {
            let (lx, ly) = legOffset(group: (idx == 0 || idx == 2) ? 0 : 1, phase: walkPhase)
            drawRect(leg, in: ctx, unit: unit,
                     offsetX: lx, offsetY: ly,
                     scaleX: totalSX, scaleY: totalSY, fill: bodyFill)
        }

        // torso（主体）
        drawRect(Self.torso, in: ctx, unit: unit,
                 offsetX: totalDX, offsetY: totalDY,
                 scaleX: totalSX, scaleY: totalSY, fill: bodyFill)
        // torso 顶部 1 行加亮（亮橘高光带，左上光源效果）
        drawRect(ClawdRect(x: Self.torso.x, y: Self.torso.y, w: Self.torso.w, h: 1),
                 in: ctx, unit: unit, offsetX: totalDX, offsetY: totalDY,
                 scaleX: totalSX, scaleY: totalSY, fill: bodyTopShading)
        // torso 底部 1 行压暗（暗橘阴影带，下沉量感）
        drawRect(ClawdRect(x: Self.torso.x, y: Self.torso.y + Self.torso.h - 1, w: Self.torso.w, h: 1),
                 in: ctx, unit: unit, offsetX: totalDX, offsetY: totalDY,
                 scaleX: totalSX, scaleY: totalSY, fill: bodyBottomShading)

        // 手臂（走路摆动 + 伸懒腰上抬 + sway）
        drawRect(Self.leftArm, in: ctx, unit: unit,
                 offsetX: totalDX, offsetY: totalDY + armWaveL + armRaise,
                 scaleX: totalSX, scaleY: totalSY, fill: bodyFill)
        drawRect(Self.rightArm, in: ctx, unit: unit,
                 offsetX: totalDX, offsetY: totalDY + armWaveR + armRaise,
                 scaleX: totalSX, scaleY: totalSY, fill: bodyFill)

        // 眼睛 + 高光（让眼神"活"起来的关键）
        let totalEyeDX = totalDX + eyeLookX
        let totalEyeDY = totalDY + eyeLookY
        if isBlinking {
            // 闭眼：压扁成 0.3 单位横线，无高光
            let centerEyeY = Self.leftEye.y + Self.leftEye.h / 2
            let blinkH: CGFloat = 0.3
            let blinkY = centerEyeY - blinkH / 2
            drawRect(ClawdRect(x: Self.leftEye.x,  y: blinkY, w: 1, h: blinkH),
                     in: ctx, unit: unit, offsetX: totalEyeDX, offsetY: totalEyeDY,
                     scaleX: totalSX, scaleY: totalSY, fill: eyeFill)
            drawRect(ClawdRect(x: Self.rightEye.x, y: blinkY, w: 1, h: blinkH),
                     in: ctx, unit: unit, offsetX: totalEyeDX, offsetY: totalEyeDY,
                     scaleX: totalSX, scaleY: totalSY, fill: eyeFill)
        } else {
            // 黑眼睛 1×2
            drawRect(Self.leftEye, in: ctx, unit: unit,
                     offsetX: totalEyeDX, offsetY: totalEyeDY,
                     scaleX: totalSX, scaleY: totalSY, fill: eyeFill)
            drawRect(Self.rightEye, in: ctx, unit: unit,
                     offsetX: totalEyeDX, offsetY: totalEyeDY,
                     scaleX: totalSX, scaleY: totalSY, fill: eyeFill)
            // 白色高光点 0.4×0.4 在眼睛左上角 —— 单一光源效果，眼神立刻有神
            let hlW: CGFloat = 0.4
            let hlH: CGFloat = 0.4
            let hlDX: CGFloat = 0.05
            let hlDY: CGFloat = 0.1
            drawRect(ClawdRect(x: Self.leftEye.x + hlDX, y: Self.leftEye.y + hlDY, w: hlW, h: hlH),
                     in: ctx, unit: unit, offsetX: totalEyeDX, offsetY: totalEyeDY,
                     scaleX: totalSX, scaleY: totalSY, fill: highlightFill)
            drawRect(ClawdRect(x: Self.rightEye.x + hlDX, y: Self.rightEye.y + hlDY, w: hlW, h: hlH),
                     in: ctx, unit: unit, offsetX: totalEyeDX, offsetY: totalEyeDY,
                     scaleX: totalSX, scaleY: totalSY, fill: highlightFill)
        }
    }

    /// 读取当前鼠标在带刘海屏上的归一化偏移，转换为眼睛偏移单位
    /// - 返回 X: [-2, 2]（同 lookLeft/lookRight 离散值范围）
    /// - 返回 Y: [-0.5, 0.5]（眼高 2 单位 → 上下各 1/4 偏移，subtle but visible）
    /// NSEvent.mouseLocation 是无锁 class method，从主线程 Canvas draw 调用安全
    nonisolated private static func continuousMouseEyeOffset() -> (CGFloat, CGFloat) {
        let loc = NSEvent.mouseLocation
        // 优先用带刘海屏（Clawd 主要活动区域）
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
        guard let screen, screen.frame.contains(loc) else { return (0, 0) }
        let halfW = screen.frame.width / 2
        let halfH = screen.frame.height / 2
        let nx = max(-1, min(1, (loc.x - screen.frame.midX) / halfW))
        // macOS 坐标 y 是底部为 0，向上为正；眼睛 y 是顶部为 0，向下为正 → 取反
        let ny = max(-1, min(1, (loc.y - screen.frame.midY) / halfH))
        return (CGFloat(nx) * 2.0, CGFloat(-ny) * 0.5)
    }

    /// 还原自官方 walking SVG 的腿位移 keyframe（leg-a / leg-b 对角交替）
    private func legOffset(group: Int, phase: Double) -> (CGFloat, CGFloat) {
        guard isWalking else { return (0, 0) }
        let p = phase
        if group == 0 {  // leg-a (outer-left + inner-right)
            if p < 0.125 { return (-2, 0) }
            if p < 0.375 { return ( 0, 0) }
            if p < 0.625 { return ( 2, 0) }
            if p < 0.875 { return ( 0, -2) }
            return (-2, 0)
        } else {         // leg-b (inner-left + outer-right)
            if p < 0.125 { return ( 2, 0) }
            if p < 0.375 { return ( 0, -2) }
            if p < 0.625 { return (-2, 0) }
            if p < 0.875 { return ( 0, 0) }
            return ( 2, 0)
        }
    }

    /// 以 sprite 中心 (7.5, 5) 为锚点做 scale
    private func drawRect(_ r: ClawdRect, in ctx: GraphicsContext, unit: CGFloat,
                          offsetX: CGFloat, offsetY: CGFloat,
                          scaleX: CGFloat, scaleY: CGFloat,
                          fill: GraphicsContext.Shading) {
        let rx = r.x + offsetX
        let ry = r.y + offsetY
        let screenX = (rx - Self.centerX) * scaleX * unit + Self.centerX * unit
        let screenY = (ry - Self.centerY) * scaleY * unit + Self.centerY * unit
        let screenW = r.w * scaleX * unit
        let screenH = r.h * scaleY * unit
        ctx.fill(Path(CGRect(x: screenX, y: screenY, width: screenW, height: screenH)), with: fill)
    }
}

/// Claude Code 工具类型分类 —— 把所有 tool_use name 映射到一种道具形象
enum ToolKind: Equatable {
    case read, write, bash, search, web, todo, task, thinking, other

    static func from(toolName: String) -> ToolKind {
        switch toolName {
        case "Read":              return .read
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return .write
        case "Bash", "BashOutput", "KillBash", "KillShell": return .bash
        case "Grep", "Glob":      return .search
        case "WebFetch", "WebSearch": return .web
        case "TodoWrite":         return .todo
        case "Task":              return .task
        default:
            // 兜底：按工具名关键字模糊匹配，覆盖 Codex 的 command_execution / file_change 等命名
            let lower = toolName.lowercased()
            if lower.contains("read")                              { return .read }
            if lower.contains("write") || lower.contains("edit")
                || lower.contains("patch") || lower.contains("change") { return .write }
            if lower.contains("shell") || lower.contains("bash")
                || lower.contains("command") || lower.contains("exec") { return .bash }
            if lower.contains("search") || lower.contains("grep")
                || lower.contains("find") || lower.contains("glob")   { return .search }
            if lower.contains("web") || lower.contains("fetch")
                || lower.contains("http") || lower.contains("url")    { return .web }
            return .other
        }
    }

    /// 道具的 SF Symbol
    var iconName: String {
        switch self {
        case .read:     return "magnifyingglass"      // 🔎 放大镜
        case .write:    return "pencil.tip"           // ✏️ 钢笔
        case .bash:     return "wrench.fill"          // 🔧 扳手
        case .search:   return "doc.text.magnifyingglass"
        case .web:      return "globe.americas.fill"
        case .todo:     return "checklist"
        case .task:     return "person.2.fill"
        case .thinking: return "brain"
        case .other:    return "wrench.fill"
        }
    }

    /// 中文动词，用在灵动岛展开文本里
    var verb: String {
        switch self {
        case .read:     return "正在读"
        case .write:    return "正在写"
        case .bash:     return "正在执行"
        case .search:   return "正在搜索"
        case .web:      return "正在浏览"
        case .todo:     return "更新清单"
        case .task:     return "派遣 subagent"
        case .thinking: return "正在思考"
        case .other:    return "正在调用"
        }
    }

    /// 道具的金属/品牌颜色
    var iconColor: LinearGradient {
        switch self {
        case .read, .search:
            return LinearGradient(colors: [Color(white: 0.95), Color(white: 0.65)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .write:
            return LinearGradient(colors: [Color(red: 1.00, green: 0.85, blue: 0.40),
                                           Color(red: 0.90, green: 0.55, blue: 0.15)],
                                  startPoint: .top, endPoint: .bottom)
        case .bash, .other:
            return LinearGradient(colors: [Color(white: 0.95), Color(white: 0.60)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .web:
            return LinearGradient(colors: [Color(red: 0.45, green: 0.85, blue: 0.95),
                                           Color(red: 0.20, green: 0.55, blue: 0.85)],
                                  startPoint: .top, endPoint: .bottom)
        case .todo:
            return LinearGradient(colors: [Color(red: 0.75, green: 0.55, blue: 0.95),
                                           Color(red: 0.55, green: 0.30, blue: 0.85)],
                                  startPoint: .top, endPoint: .bottom)
        case .task:
            return LinearGradient(colors: [Color(red: 1.00, green: 0.60, blue: 0.30),
                                           Color(red: 0.85, green: 0.30, blue: 0.15)],
                                  startPoint: .top, endPoint: .bottom)
        case .thinking:
            return LinearGradient(colors: [Color(red: 0.85, green: 0.70, blue: 0.95),
                                           Color(red: 0.55, green: 0.45, blue: 0.85)],
                                  startPoint: .top, endPoint: .bottom)
        }
    }
}

/// 工作中 Clawd 手里挥舞的小工具 —— 模拟"在干活"
/// 根据 ToolKind 显示对应 SF Symbol，持续摆动旋转
/// 切换 kind 时用 .id() 强制重建 view，让动画从初始角度重启
struct ToolOverlay: View {
    let kind: ToolKind
    @State private var swing: Double = 35

    var body: some View {
        Image(systemName: kind.iconName)
            .font(.system(size: 6.5, weight: .heavy))
            .foregroundStyle(kind.iconColor)
            .shadow(color: .black.opacity(0.4), radius: 0.5, y: 0.5)
            .rotationEffect(.degrees(swing))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true)) {
                    swing = -25
                }
            }
            .id(kind)   // kind 切换 → view 重建，扳手→放大镜的过渡更自然
    }
}

/// Claude 模式的左耳精灵 —— Clawd 像素小家伙。
///
/// 三套互斥动画 + 优先级 working > celebrate > look：
/// - **idle look**：静态 rest，每 25~50s 随机触发一次左右扫视
///   (rest → lookLeft → rest → lookRight → rest)，模拟"小家伙在打量你"
/// - **working jump**：流式生成时，rest ↔ armsUp 交替跳跃（250/350ms），
///   表达"在干活"
/// - **celebrate**：收到 `HermesPetTaskFinished`(success=true) 通知时，
///   连续 3 次 armsUp 庆祝（200/150ms），跟普通 working 区分开
///
/// 这套 pose 切换本身就是 Clawd 的"生命感"，所以 Claude 模式下外部
/// **不再挂** `LifeSignsModifier`（scaleEffect 会让像素艺术插值变糊）
struct ClaudeKnotSprite: View {
    let isWorking: Bool
    /// 灵动岛传进来的目标高度。Clawd 真实终端比例 1.5:1（不是 3:1），
    /// 这里取 1.15 倍让它比常规图标略大 15% 显眼一点
    let size: CGFloat
    /// 调色板 —— 默认 Anthropic 官方橙，用户自定义后由调用方传入
    var palette: PetPalette = .clawdDefault

    @State private var pose: ClawdPose = .rest
    @State private var workingTask: Task<Void, Never>?
    @State private var celebrateTask: Task<Void, Never>?
    @State private var lookTask: Task<Void, Never>?
    /// 工作时水平方向"跑来跑去"的位移，±4pt 间循环
    @State private var runOffset: CGFloat = 0
    /// 当前工具类型（Read/Write/Bash/...），由 HermesPetToolStarted 通知驱动。
    /// 工作中没有特定工具时显示默认扳手（.other）
    @State private var currentTool: ToolKind = .other
    /// 鼠标在屏幕的相对区域，由 MouseTrackingController 通知驱动。
    /// idle 时 Clawd 的眼睛会跟着这个区域看（左/中/右）—— 让桌宠"活"起来
    @State private var mouseArea: MouseTrackingController.MouseArea = .center

    /// v2 像素更密 + 用户希望 Clawd 显得更大 → 系数从 1.15 拉到 1.4
    /// （配合调用点 size 13→18 一起，整体放大约 50~70%）
    private var clawdHeight: CGFloat { size * 1.4 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // followMouse 只在 idle（非工作、非庆祝）时打开：
            // 工作时 pose 在循环切换工具姿势，庆祝时 armsUp，都不希望被鼠标跟踪覆盖
            ClawdView(pose: pose, height: clawdHeight,
                      followMouse: !isWorking && celebrateTask == nil,
                      palette: palette)

            // 工作时手里挥着工具在右上角；工具种类跟着 Claude tool_use 实时切换
            if isWorking {
                ToolOverlay(kind: currentTool)
                    .offset(x: 3, y: -2)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        // 整体跑来跑去 —— 拿着扳手在左耳区域水平来回小跑
        .offset(x: runOffset)
        .animation(AnimTok.smooth, value: isWorking)   // 扳手出场动画
        .onAppear {
            applyWorkingState(isWorking, animateRest: false)
            updateRunningAnimation(working: isWorking)
        }
        .onChange(of: isWorking) { _, working in
            applyWorkingState(working, animateRest: true)
            updateRunningAnimation(working: working)
            if !working {
                // 工作结束 → 工具重置为默认（下次工作前不会残留上次的工具）
                currentTool = .other
            }
        }
        .onDisappear {
            cancelAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetTaskFinished"))) { note in
            let success = (note.userInfo?["success"] as? Bool) ?? false
            if success { startCelebrate() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetToolStarted"))) { note in
            guard let name = note.userInfo?["name"] as? String else { return }
            let kind = ToolKind.from(toolName: name)
            withAnimation(AnimTok.snappy) {
                currentTool = kind
            }
            // 工具切换 → 重启 jump 用新工具的动画序列（每个工具的姿势节奏不同）
            if isWorking {
                startWorkingJump()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetMouseAreaChanged"))) { note in
            let raw = (note.userInfo?["area"] as? String) ?? "center"
            let newArea = MouseTrackingController.MouseArea(rawValue: raw) ?? .center
            mouseArea = newArea
            // 仅在 idle 状态生效（不被工作 / 庆祝抢占）
            if !isWorking, celebrateTask == nil {
                applyMousePoseIfIdle()
            }
        }
    }

    /// 鼠标驱动 idle 时的 pose
    /// 现在眼睛在 ClawdView 内部做连续跟踪了，这里不再用 mouseArea 强制 lookLeft/Right —
    /// 只保留 rest 时启动"随机偶尔扫视/伸懒腰"循环，让 Clawd 有自己的小动作
    private func applyMousePoseIfIdle() {
        withAnimation(AnimTok.snappy) { pose = .rest }
        startIdleLookCycle()
    }

    /// 工作时水平来回 ±4pt 平移 —— 配合 pose 跳跃 = 拿着扳手跑来跑去
    private func updateRunningAnimation(working: Bool) {
        if working {
            runOffset = -4
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                runOffset = 4
            }
        } else {
            withAnimation(AnimTok.smooth) {
                runOffset = 0
            }
        }
    }

    // MARK: - 状态切换

    private func applyWorkingState(_ working: Bool, animateRest: Bool) {
        if working {
            // 工作开始：取消 idle look，启动 jump
            lookTask?.cancel(); lookTask = nil
            startWorkingJump()
        } else {
            // 工作结束：取消 jump
            workingTask?.cancel(); workingTask = nil
            // celebrate 没在跑就 reset 到 rest（celebrate 会自己控制 pose）
            if celebrateTask == nil, animateRest {
                pose = .rest
            }
            // 让 idle 时优先尊重鼠标位置，鼠标在 center 才走随机扫
            if celebrateTask == nil {
                applyMousePoseIfIdle()
            }
        }
    }

    private func cancelAll() {
        workingTask?.cancel();   workingTask = nil
        celebrateTask?.cancel(); celebrateTask = nil
        lookTask?.cancel();      lookTask = nil
    }

    // MARK: - 动画 Task

    /// 工作中循环 —— 根据 currentTool 走不同的"姿势节奏"：
    /// - Read：lookLeft ↔ lookRight 慢扫（眯眼读书感）
    /// - Write/Edit：armsUp ↔ rest 快速（打字感）
    /// - Bash：armsUp ↔ rest 中速（敲命令感）
    /// - Search：lookLeft ↔ lookRight 快切（探头探脑找东西）
    /// - Web：rest → lookLeft → lookRight → rest 慢扫（环顾世界）
    /// - Task：armsUp 双弹（指挥 subagent）
    /// - Todo / Other：默认 armsUp ↔ rest
    /// currentTool 切换时（onReceive 里）会重启此 task，自动用新工具的节奏
    private func startWorkingJump() {
        workingTask?.cancel()
        let frames = workingFrames(for: currentTool)
        workingTask = Task { @MainActor in
            while !Task.isCancelled {
                for (frame, durationNs) in frames {
                    pose = frame
                    try? await Task.sleep(nanoseconds: durationNs)
                    if Task.isCancelled { return }
                }
            }
        }
    }

    /// 不同工具对应的姿势循环序列：[(姿势, 持续时间 ns)]
    private func workingFrames(for tool: ToolKind) -> [(ClawdPose, UInt64)] {
        switch tool {
        case .read:
            return [
                (.lookLeft,  600_000_000),
                (.rest,      150_000_000),
                (.lookRight, 600_000_000),
                (.rest,      150_000_000),
            ]
        case .write:
            return [
                (.armsUp, 180_000_000),
                (.rest,   200_000_000),
            ]
        case .bash:
            return [
                (.armsUp, 220_000_000),
                (.rest,   320_000_000),
            ]
        case .search:
            return [
                (.lookLeft,  240_000_000),
                (.lookRight, 240_000_000),
            ]
        case .web:
            return [
                (.rest,      350_000_000),
                (.lookLeft,  500_000_000),
                (.lookRight, 500_000_000),
            ]
        case .task:
            return [
                (.armsUp, 200_000_000),
                (.rest,   100_000_000),
                (.armsUp, 200_000_000),
                (.rest,   500_000_000),
            ]
        case .todo, .other, .thinking:
            return [
                (.armsUp, 250_000_000),
                (.rest,   350_000_000),
            ]
        }
    }

    /// 任务成功结束：连续 3 次开心举手
    private func startCelebrate() {
        // celebrate 优先级最高，抢占其他动画
        workingTask?.cancel(); workingTask = nil
        lookTask?.cancel();    lookTask = nil
        celebrateTask?.cancel()
        celebrateTask = Task { @MainActor in
            for i in 0..<3 {
                pose = .armsUp
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { celebrateTask = nil; return }
                pose = .rest
                if i < 2 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if Task.isCancelled { celebrateTask = nil; return }
                }
            }
            celebrateTask = nil
            // 庆祝完，回到 idle look 循环（如果不在工作中）
            if !isWorking {
                startIdleLookCycle()
            }
        }
    }

    /// idle 时周期触发"左右看 / 偶尔伸懒腰"，让 Clawd 像个活物在打量周围
    /// - 70% → 左右扫视（看左 + 看右）
    /// - 20% → 伸懒腰（armsUp 0.6s）
    /// - 10% → 单侧扫视（只看一边）
    private func startIdleLookCycle() {
        lookTask?.cancel()
        lookTask = Task { @MainActor in
            while !Task.isCancelled {
                // 等 22~42s 随机（比之前略短，让动作更密一点）
                let delayNs = UInt64.random(in: 22_000_000_000...42_000_000_000)
                try? await Task.sleep(nanoseconds: delayNs)
                if Task.isCancelled || isWorking { return }

                let roll = Int.random(in: 0..<10)

                if roll < 2 {
                    // 伸懒腰：举手 0.6s → 放下
                    pose = .armsUp
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if Task.isCancelled || isWorking { return }
                    pose = .rest
                } else {
                    let bothSides = roll < 9
                    let leftFirst = Bool.random()
                    let firstSide: ClawdPose  = leftFirst ? .lookLeft  : .lookRight
                    let secondSide: ClawdPose = leftFirst ? .lookRight : .lookLeft

                    pose = firstSide
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled || isWorking { return }
                    pose = .rest

                    guard bothSides else { continue }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if Task.isCancelled || isWorking { return }
                    pose = secondSide
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled || isWorking { return }
                    pose = .rest
                }
            }
        }
    }
}

