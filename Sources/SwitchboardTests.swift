import Foundation

func switchboardSelfTests(_ check: (Bool, String) -> Void) {
    let store = Store.shared
    let entry = Entry(name: "Switchboard fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")
    let source = store.create(entry), target = store.create(entry)
    source.title = "Writer"; target.title = "Reviewer"; source.queuePaused = true; target.queuePaused = true
    source.draft = "source draft"; target.draft = "recipient draft"
    func block(_ command: String, to: String? = nil, text: String? = nil) -> String {
        var value = ["command": command]
        value["to"] = to; value["text"] = text
        return "```converse\n" + String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n```"
    }
    func reply(_ text: String, hop: Int = 0) {
        source.switchboardTurnStart = source.messages.count
        source.switchboardHop = hop
        source.messages.append(Message(role: "assistant", text: text, finalReply: text))
        store.processSwitchboard(source)
    }
    reply(block("tell", to: target.id.uuidString, text: "disabled"))
    check(target.pending.isEmpty, "Untaught sessions cannot emit switchboard messages")
    store.teachSwitchboard(source)
    check(source.switchboardEnabled && source.pending.last?.text.contains("list-sessions") == true && source.pending.last?.text.contains("tell <name>") == true && source.draft == "source draft", "Teach enables messaging and queues dynamic lookup instructions without overwriting draft")
    source.pending = []
    reply("Example:\n" + block("tell", to: target.id.uuidString, text: "quoted"))
    check(target.pending.isEmpty, "JSON embedded in explanatory prose never sends")
    reply(block("list-sessions"))
    let directory = source.pending.last?.text ?? ""
    check(directory.contains(target.id.uuidString) && directory.contains("Reviewer") && source.queuePaused && !source.busy, "Directory lookup returns live IDs and names and respects paused input")
    target.title = "Renamed reviewer"
    check(store.switchboardDirectory(for: source).contains("Renamed reviewer"), "Directory lookup sees current session names")
    reply(block("tell", to: target.id.uuidString, text: "Quoted \"text\"\nSecond line"))
    check(target.pending.count == 1 && target.pending[0].text.hasSuffix("Quoted \"text\"\nSecond line") && target.pending[0].switchboardHop == 1 && target.draft == "recipient draft" && target.queuePaused, "Tell routes exact escaped text with sender provenance and preserves paused queue and draft")
    store.processSwitchboard(source)
    check(target.pending.count == 1, "Reprocessing a completed reply cannot deliver twice")
    let restored = Session(try! JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(source.saved)))
    check(restored.switchboardEnabled && restored.switchboardHandled == source.switchboardHandled, "Messaging opt-in and handled reply IDs survive persistence")
    let recipient = Session(try! JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(target.saved)))
    check(recipient.pending.first?.switchboardHop == 1 && recipient.queuePaused, "Received message and hop budget survive restart paused")
    let count = target.pending.count
    reply(block("tell", to: target.id.uuidString, text: "loop"), hop: 8)
    reply(block("tell", to: source.id.uuidString, text: "self"))
    reply(block("tell", to: UUID().uuidString, text: "closed"))
    reply(block("tell", to: target.id.uuidString, text: ""))
    check(target.pending.count == count, "Hop exhaustion, self-addressing, missing targets and empty messages never deliver")
    reply(block("tell", to: target.id.uuidString, text: String(repeating: "x", count: 32769)))
    check(target.pending.count == count, "Oversized messages are rejected")
    source.switchboardTurnStart = source.messages.count
    source.messages.append(Message(role: "assistant", text: block("tell", to: target.id.uuidString, text: "failed turn")))
    store.finishQueue(source, success: false)
    check(target.pending.count == count, "Failed turns never dispatch switchboard commands")
    source.switchboardEnabled = false
    reply(block("tell", to: target.id.uuidString, text: "disabled again"))
    check(target.pending.count == count, "Disabling messaging takes effect immediately")
    store.sessions.removeAll { $0.id == source.id || $0.id == target.id }; store.save()
}
