import Foundation

/// 每日早报服务 —— 在每天首次启动时自动生成一份"今日早报"。
///
/// 流程：
///   1. 检查 lastBriefingDate < today（同一天不重复生成）
///   2. 拉昨天的 activity_sessions / app_usage_stats / user_questions
///   3. 喂给用户在设置里选定的 `morningBriefingBackend` AI（默认 Hermes）
///   4. AI 返回 markdown briefing → ChatViewModel 自动开一个"📰 今日早报"对话
///
/// 为什么 backend 用户必须显式选：早报包含活动汇总 + 你跟 AI 的问题主题，
/// 数据敏感，让用户有意识地决定哪家服务商能看到这些。
@MainActor
final class MorningBriefingService {
    static let shared = MorningBriefingService()

    private let lastBriefingDateKey = "morningBriefingLastDate"
    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    /// 是否在跑（避免重入 / 用户连点）
    private var isGenerating = false

    private init() {}

    // MARK: - 触发入口

    /// AppDelegate 启动时调用 —— 同一天只跑一次
    func generateIfNeeded(viewModel: ChatViewModel) {
        let today = Self.dateFormatter.string(from: Date())
        let last = UserDefaults.standard.string(forKey: lastBriefingDateKey) ?? ""
        if last == today {
            return  // 今天已经生成过
        }
        // 启动后等 3s 再触发，让 ActivityRecorder 把当天 stats 先聚合一下，
        // 也让用户看到 app 启动时不会有突兀弹窗
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self.generateInternal(viewModel: viewModel, isManual: false)
        }
    }

    /// 用户在菜单栏 / 灵动岛点击"立即生成今日早报"调用 —— 不管 lastBriefingDate
    func generateNow(viewModel: ChatViewModel) {
        Task { @MainActor in
            await self.generateInternal(viewModel: viewModel, isManual: true)
        }
    }

    // MARK: - 主流程

    private func generateInternal(viewModel: ChatViewModel, isManual: Bool) async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }

        // 1. 收数据 —— 优先昨天（每天早晨打开看的是回顾）；
        // 如果昨天为空（比如刚装、或周末没用），回退到今天 to-date 的数据
        var data = collectData(forYesterday: true)
        if data.isEmpty {
            data = collectData(forYesterday: false)
        }
        if data.isEmpty {
            if isManual {
                viewModel.errorMessage = "还没有任何活动数据。让 ActivityRecorder 跑一会儿（用一会儿电脑）再来生成早报。"
            }
            return
        }

        // 2. 构造 prompt
        let prompt = buildPrompt(data: data)

        // 3. 调用 AI（用用户选定的 morningBriefingBackend，不写入 user_questions）
        let backend = viewModel.morningBriefingBackend
        var briefing = ""
        do {
            for try await chunk in viewModel.streamOneShotAsk(
                prompt: prompt,
                modeOverride: backend,
                recordToActivity: false
            ) {
                briefing += chunk
            }
        } catch {
            print("[MorningBriefing] 生成失败: \(error.localizedDescription)")
            if isManual {
                viewModel.errorMessage = "早报生成失败：\(error.localizedDescription)"
            }
            return
        }

        let trimmed = briefing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if isManual {
                viewModel.errorMessage = "早报 AI 没返回内容，请检查 \(backend.label) 后端是否正常"
            }
            return
        }

        // 4. 创建早报对话
        viewModel.createBriefingConversation(content: trimmed)

        // 5. 标记今天已生成
        UserDefaults.standard.set(Self.dateFormatter.string(from: Date()), forKey: lastBriefingDateKey)
    }

    // MARK: - 数据收集

    /// - forYesterday: true=拉昨天（早晨自动模式），false=拉今天到目前为止（manual fallback）
    private func collectData(forYesterday: Bool) -> BriefingData {
        let store = ActivityRecorder.shared.queryStore
        let targetDate = forYesterday
            ? (Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
            : Date()
        let dayStart = Calendar.current.startOfDay(for: targetDate)
        let dayEnd = dayStart.addingTimeInterval(86400)

        // 先聚合一遍当天 stats（确保最新）
        store.aggregateDailyStats(for: targetDate)
        let stats = store.dailyStats(for: targetDate)

        // 拿当天的用户问题
        let allRecent = store.recentUserQuestions(withinMinutes: 48 * 60, limit: 200)
        let dayQuestions = allRecent.filter {
            $0.timestamp >= dayStart && $0.timestamp < dayEnd
        }

        // 最近 7 天最常用 app
        let topApps = store.topApps(days: 7, limit: 5)

        return BriefingData(
            yesterdayDate: targetDate,
            yesterdayStats: stats,
            yesterdayQuestions: dayQuestions,
            topAppsLast7Days: topApps
        )
    }

    // MARK: - Prompt 构造

    private func buildPrompt(data: BriefingData) -> String {
        var lines: [String] = []
        lines.append("# 任务")
        lines.append("你是用户的「今日早报」助手。基于他昨天的电脑活动数据，生成一份温暖、有洞察力的早报。")
        lines.append("")
        lines.append("## 风格要求")
        lines.append("- 用第二人称「你」，亲切而非冷冰冰报数字")
        lines.append("- markdown 格式，包含小标题")
        lines.append("- 长度：300-500 字")
        lines.append("- 结构：")
        lines.append("  1. 一句友好的早安问候")
        lines.append("  2. **昨日概览**：在屏幕前多久、主要在用什么、敲了多少次键")
        lines.append("  3. **关键观察**：你在哪个项目/主题上花了时间，跟 AI 聊了关于什么的问题（不要照搬原话，提炼主题）")
        lines.append("  4. **今天的建议**：基于昨天进展，温柔提议 2-3 件可以做的事")
        lines.append("  5. 一句祝你愉快的尾语")
        lines.append("- 不要长篇大论，不要复读数据，要有「懂你」的感觉")
        lines.append("")
        lines.append("## 用户昨日数据 (\(Self.dateFormatter.string(from: data.yesterdayDate)))")
        lines.append("")

        // App 使用情况
        if !data.yesterdayStats.isEmpty {
            lines.append("### App 使用 Top \(min(5, data.yesterdayStats.count))")
            for s in data.yesterdayStats.prefix(5) {
                let h = s.totalSeconds / 3600
                let m = (s.totalSeconds % 3600) / 60
                let timeStr = h > 0 ? "\(h)h\(m)m" : "\(m)m"
                lines.append("- **\(s.appName)**：\(timeStr)，\(s.sessionCount) 次会话，\(s.keyboardEvents) 次按键")
            }
            lines.append("")
        }

        // 用户跟 AI 的对话
        let qCount = data.yesterdayQuestions.count
        lines.append("### 跟 AI 的对话")
        lines.append("昨天总共问了 **\(qCount)** 个问题。")
        if !data.yesterdayQuestions.isEmpty {
            lines.append("")
            lines.append("最近 \(min(15, qCount)) 个问题（用来推断你在关注什么）：")
            for q in data.yesterdayQuestions.prefix(15) {
                let preview = q.content.prefix(120).replacingOccurrences(of: "\n", with: " ")
                lines.append("- [\(q.mode)] \(preview)")
            }
            lines.append("")
        }

        // 最近 7 天常用 app
        if !data.topAppsLast7Days.isEmpty {
            lines.append("### 最近 7 天最常用 (作为对比)")
            for s in data.topAppsLast7Days {
                let h = s.totalSeconds / 3600
                lines.append("- \(s.appName)：累计 \(h)h")
            }
            lines.append("")
        }

        lines.append("---")
        lines.append("现在直接生成早报，不要解释任务、不要重复数据，直接输出 markdown 早报正文。")
        return lines.joined(separator: "\n")
    }
}

/// 早报需要的全部数据快照
struct BriefingData {
    let yesterdayDate: Date
    let yesterdayStats: [AppDailyStat]
    let yesterdayQuestions: [UserQuestion]
    let topAppsLast7Days: [AppDailyStat]

    var isEmpty: Bool {
        yesterdayStats.isEmpty && yesterdayQuestions.isEmpty
    }
}
