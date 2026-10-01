import Foundation
import Observation

enum AgentTaskPhase: String {
    case idle, queued, connecting, thinking, responding, completed, cancelled, failed

    var label: String {
        switch self {
        case .idle: "待命"
        case .queued: "排队中"
        case .connecting: "正在连接"
        case .thinking: "正在思考"
        case .responding: "正在回复"
        case .completed: "已完成"
        case .cancelled: "已停止"
        case .failed: "需要处理"
        }
    }
    var isRunning: Bool { [.queued, .connecting, .thinking, .responding].contains(self) }
}

struct AgentToolActivity: Identifiable {
    let id: String
    let kind: ToolKind
    let argument: String
    var finished = false
    var failed = false
}

struct AgentTaskActivity {
    var phase: AgentTaskPhase = .idle
    var tools: [AgentToolActivity] = []
    var interactions: [String: Bool] = [:] // true: permission; false: question
    var model: String?
    var startedAt: Date?
    var currentTool: AgentToolActivity? { tools.last { !$0.finished } }
    var isWaiting: Bool { !interactions.isEmpty }
    var label: String {
        if interactions.values.contains(true) { return "等待批准" }
        if isWaiting { return "等待回答" }
        if phase.isRunning, let tool = currentTool { return tool.kind.verb }
        return phase.label
    }
    var completedTools: Int { tools.filter { $0.finished && !$0.failed }.count }
}

/// Each event is scoped to its originating conversation; background work never takes over the active strip.
@MainActor @Observable
final class AgentActivityStore {
    private(set) var tasks: [String: AgentTaskActivity] = [:]
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        for name in ["TarsModelSelected", "TarsAgentPhase", "HermesPetToolStarted", "HermesPetToolEnded",
                     "HermesPetPermissionAsked", "HermesPetQuestionAsked", "HermesPetPermissionReplied",
                     "HermesPetPermissionDecisionMade", "HermesPetQuestionAnswered", "HermesPetQuestionRejected"] {
            observers.append(NotificationCenter.default.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in
                let event = Event(note)
                // The main-queue observer receives an immutable, Sendable snapshot.
                MainActor.assumeIsolated { self?.receive(event) }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func activity(for id: String) -> AgentTaskActivity { tasks[id] ?? AgentTaskActivity() }
    func start(_ id: String, phase: AgentTaskPhase = .connecting) {
        tasks[id] = AgentTaskActivity(phase: phase, startedAt: Date())
    }
    func setPhase(_ phase: AgentTaskPhase, for id: String) {
        guard tasks[id]?.phase.isRunning == true else { return }
        tasks[id]?.phase = phase
    }
    func finish(_ id: String, phase: AgentTaskPhase) {
        tasks[id]?.phase = phase
        tasks[id]?.interactions.removeAll()
        // Incomplete tools are interrupted, never presented as successful.
        if let tools = tasks[id]?.tools {
            tasks[id]?.tools = tools.map { var tool = $0; if !tool.finished { tool.finished = true; tool.failed = true }; return tool }
        }
    }
    func remove(_ id: String) { tasks.removeValue(forKey: id) }

    private struct Event: Sendable {
        let name: String
        let conversationID: String?
        let toolID: String?
        let toolName: String?
        let argument: String
        let failed: Bool
        let phase: String?
        let resolvedID: String?
        let interactionID: String?
        let permission: Bool
        let model: String?
        init(_ note: Notification) {
            let info = note.userInfo ?? [:]
            name = note.name.rawValue
            conversationID = info["conversationID"] as? String
            toolID = info["id"] as? String
            toolName = info["name"] as? String
            argument = info["arg"] as? String ?? info["file_path"] as? String ?? ""
            failed = info["failed"] as? Bool ?? false
            phase = info["phase"] as? String
            resolvedID = info["requestID"] as? String
            model = info["model"] as? String
            if let request = info["request"] as? PermissionRequest {
                interactionID = request.id; permission = true
            } else if let request = info["request"] as? QuestionRequest {
                interactionID = request.id; permission = false
            } else { interactionID = nil; permission = false }
        }
    }
    func receive(_ note: Notification) { receive(Event(note)) }
    private func receive(_ event: Event) {
        if let requestID = event.resolvedID {
            for id in Array(tasks.keys) { tasks[id]?.interactions.removeValue(forKey: requestID) }
        }
        guard let id = event.conversationID, tasks[id]?.phase.isRunning == true else { return }
        switch event.name {
        case "TarsModelSelected": tasks[id]?.model = event.model
        case "TarsAgentPhase":
            if let raw = event.phase, let phase = AgentTaskPhase(rawValue: raw) { setPhase(phase, for: id) }
        case "HermesPetToolStarted":
            guard let key = event.toolID, let name = event.toolName,
                  tasks[id]?.tools.contains(where: { $0.id == key }) == false else { return }
            tasks[id]?.tools.append(AgentToolActivity(id: key, kind: ToolKind.from(toolName: name), argument: event.argument))
        case "HermesPetToolEnded":
            guard let key = event.toolID, let index = tasks[id]?.tools.firstIndex(where: { $0.id == key }) else { return }
            tasks[id]?.tools[index].finished = true
            tasks[id]?.tools[index].failed = event.failed
            setPhase(.thinking, for: id)
        case "HermesPetPermissionAsked", "HermesPetQuestionAsked":
            if let key = event.interactionID { tasks[id]?.interactions[key] = event.permission }
        default: break
        }
    }

    static func postPhase(_ phase: AgentTaskPhase, conversationID: String) {
        NotificationCenter.default.post(name: .init("TarsAgentPhase"), object: nil,
                                        userInfo: ["conversationID": conversationID, "phase": phase.rawValue])
    }
}
