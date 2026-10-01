import XCTest
@testable import HermesPet

@MainActor
final class AgentPresentationTests: XCTestCase {
    private func event(_ name: String, _ info: [String: Any]) -> Notification { Notification(name: .init(name), userInfo: info) }

    func testConcurrentToolsRemainScopedAndDeduplicated() {
        let store = AgentActivityStore()
        store.start("a"); store.start("b", phase: .queued)
        store.receive(event("HermesPetToolStarted", ["conversationID": "a", "id": "read", "name": "Read", "arg": "/tmp/file"]))
        store.receive(event("HermesPetToolStarted", ["conversationID": "a", "id": "read", "name": "Read"]))
        store.receive(event("HermesPetToolEnded", ["conversationID": "b", "id": "read"]))
        XCTAssertEqual(store.activity(for: "a").label, "正在读")
        XCTAssertEqual(store.activity(for: "a").tools.count, 1)
        XCTAssertEqual(store.activity(for: "b").label, "排队中")
        store.receive(event("HermesPetToolEnded", ["conversationID": "a", "id": "read"]))
        XCTAssertEqual(store.activity(for: "a").label, "正在思考")
        store.setPhase(.responding, for: "a")
        store.finish("a", phase: .completed)
        store.receive(event("HermesPetToolStarted", ["conversationID": "a", "id": "late", "name": "Bash"]))
        XCTAssertEqual(store.activity(for: "a").label, "已完成")
        XCTAssertEqual(store.activity(for: "a").completedTools, 1)
        XCTAssertEqual(store.activity(for: "a").tools.count, 1)
    }
    func testWaitingApprovalSurvivesTextAndOnlyItsOwnReplyClearsIt() {
        let store = AgentActivityStore(); store.start("a"); store.start("b")
        let permission = PermissionRequest(id: "approval", sessionID: "thread", permission: "bash", patterns: [], metadata: [:], always: [], tool: nil)
        store.receive(event("HermesPetPermissionAsked", ["conversationID": "a", "request": permission]))
        store.setPhase(.responding, for: "a")
        XCTAssertEqual(store.activity(for: "a").label, "等待批准")
        XCTAssertFalse(store.activity(for: "b").isWaiting)
        store.receive(event("HermesPetPermissionDecisionMade", ["requestID": "other"]))
        XCTAssertTrue(store.activity(for: "a").isWaiting)
        store.receive(event("HermesPetPermissionDecisionMade", ["requestID": "approval"]))
        XCTAssertEqual(store.activity(for: "a").label, "正在回复")
    }
    func testInterruptedToolsAreNeverMarkedSuccessful() {
        let store = AgentActivityStore(); store.start("a")
        store.receive(event("HermesPetToolStarted", ["conversationID": "a", "id": "command", "name": "commandExecution"]))
        store.finish("a", phase: .cancelled)
        XCTAssertTrue(store.activity(for: "a").tools[0].failed)
        XCTAssertEqual(store.activity(for: "a").completedTools, 0)
    }
    func testPersistentRecoveryAndModelSurviveConversationReload() throws {
        var conversation = Conversation(title: "保留记录", messages: [ChatMessage(role: .user, content: "原始问题")], assistantEngine: .chatGPT)
        conversation.runtimeModel = "gpt-6-astra"
        conversation.issue = ChatIssue.classify("ChatGPT 授权已失效，请重新登录")
        let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        XCTAssertEqual(restored.messages.first?.content, "原始问题")
        XCTAssertEqual(restored.runtimeModel, "gpt-6-astra")
        XCTAssertEqual(restored.issue?.recovery, .signIn)
        XCTAssertTrue(restored.issue?.isPersistent == true)
        XCTAssertEqual(ChatIssue.classify("ChatGPT 订阅额度已用尽").recovery, .usage)
        XCTAssertEqual(ChatIssue.classify("连接断开", unconfirmedTask: true).recovery, .inspectTask)
        XCTAssertFalse(ChatIssue.classify("对话已达 8 条上限，关掉一条再试").isPersistent)
    }
}
