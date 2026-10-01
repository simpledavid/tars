import SwiftUI

/// Tars 唯一的灵动岛宠物。AgentMode 只影响业务路由，不更换宠物形象。
struct ModeSpriteView: View {
    let mode: AgentMode
    /// 是否正在工作中
    let isWorking: Bool
    let size: CGFloat

    /// 全局调色板存储 —— @Observable，用户改色后此 View 自动 invalidate 重渲染
    @State private var paletteStore = PetPaletteStore.shared

    var body: some View {
        let palette = paletteStore.palette(for: mode)
        TarsSprite(isWorking: isWorking, size: size, palette: palette)
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
        case "WebFetch", "WebSearch", "webSearch", "web_search": return .web
        case "TodoWrite":         return .todo
        case "Task", "collabAgentToolCall", "collab_agent_tool_call":              return .task
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

/// 工作中 TARS 旁边显示的工具状态。
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

/// Tars 全模式共用的机器人精灵。
///
/// 三套互斥动画 + 优先级 working > celebrate > look：
/// - **idle look**：静态 rest，每 25~50s 随机触发一次左右扫视
///   (rest → lookLeft → rest → lookRight → rest)，模拟"小家伙在打量你"
/// - **working jump**：流式生成时，rest ↔ armsUp 交替跳跃（250/350ms），
///   表达"在干活"
/// - **celebrate**：收到 `HermesPetTaskFinished`(success=true) 通知时，
///   连续 3 次 armsUp 庆祝（200/150ms），跟普通 working 区分开
///
/// 这套 pose 切换本身就是 TARS 的生命感，因此外部
/// **不再挂** `LifeSignsModifier`（scaleEffect 会让像素艺术插值变糊）
struct TarsSprite: View {
    let isWorking: Bool
    /// 灵动岛传进来的目标高度。
    let size: CGFloat
    /// 调色板主色用于 TARS 信息屏和状态灯。
    var palette: PetPalette = .tarsDefault

    @State private var pose: TarsPose = .rest
    @State private var workingTask: Task<Void, Never>?
    @State private var celebrateTask: Task<Void, Never>?
    @State private var lookTask: Task<Void, Never>?
    /// 工作时水平方向"跑来跑去"的位移，±4pt 间循环
    @State private var runOffset: CGFloat = 0
    /// 当前工具类型（Read/Write/Bash/...），由 HermesPetToolStarted 通知驱动。
    /// 工作中没有特定工具时显示默认扳手（.other）
    @State private var currentTool: ToolKind = .other
    /// 鼠标在屏幕的相对区域，由 MouseTrackingController 通知驱动。
    /// idle 时 TARS 会朝鼠标所在区域轻微倾斜。
    @State private var mouseArea: MouseTrackingController.MouseArea = .center

    private var tarsHeight: CGFloat { size * 1.5 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // followMouse 只在 idle（非工作、非庆祝）时打开：
            // 工作时 pose 在循环切换工具姿势，庆祝时 armsUp，都不希望被鼠标跟踪覆盖
            TarsView(pose: pose, height: tarsHeight,
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
    /// TarsView 内部会朝鼠标方向轻微倾斜；这里保留随机观察和展开动作。
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
    private func workingFrames(for tool: ToolKind) -> [(TarsPose, UInt64)] {
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

    /// idle 时周期触发左右观察或展开机体。
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
                    let firstSide: TarsPose  = leftFirst ? .lookLeft  : .lookRight
                    let secondSide: TarsPose = leftFirst ? .lookRight : .lookLeft

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
