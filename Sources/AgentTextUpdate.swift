/// A streaming backend can replace provisional text with an authoritative final answer.
enum AgentTextUpdate {
    private static let replacementPrefix = "\u{001E}TARS_REPLACE:"
    static func replacement(_ text: String) -> String { replacementPrefix + text }
    static func apply(_ update: String, to text: inout String) {
        if update.hasPrefix(replacementPrefix) { text = String(update.dropFirst(replacementPrefix.count)) }
        else { text += update }
    }
}
