import XCTest
@testable import HermesPet

final class AgentMigrationTests: XCTestCase {
    func testRetiredCloudConversationKeepsItsHistoryAndAttachments() throws {
        let message = ChatMessage(role: .user, content: "保留这段历史", imagePaths: ["/tmp/image.png"], documentPaths: ["/tmp/reference.pdf"])
        let old = Conversation(title: "旧对话", messages: [message], assistantEngine: .chatGPT)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json["assistantEngine"] = "openai_agents"
        let restored = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.assistantEngine, .chatGPT)
        XCTAssertEqual(restored.id, old.id)
        XCTAssertEqual(restored.title, old.title)
        XCTAssertEqual(restored.messages[0].content, message.content)
        XCTAssertEqual(restored.messages[0].imagePaths, message.imagePaths)
        XCTAssertEqual(restored.messages[0].documentPaths, message.documentPaths)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as! [String: Any]
        XCTAssertEqual(saved["assistantEngine"] as? String, "chatgpt_plan")
    }
    func testProviderConversationMigrationDoesNotChangeItsEngine() throws {
        for raw in ["hermes", "openclaw", "none", "unknown", "opencode"] { XCTAssertEqual(OnlineAIAgent.restored(raw), .opencode) }
        let old = Conversation(title: "old", messages: [ChatMessage(role: .user, content: "history")])
        let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(restored.assistantEngine, .opencode)
        XCTAssertEqual(restored.messages[0].content, "history")
    }
}
