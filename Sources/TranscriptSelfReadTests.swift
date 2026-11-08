import AppKit

func transcriptSelfReadSelfTests(_ check: (Bool, String) -> Void) {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("converse-selfread-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let store = Store(folder: root)
    let entry = Entry(name: "Self-read fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")
    let a = store.create(entry), b = store.create(entry)
    a.title = "Reader"; b.title = "Neighbor"; a.queuePaused = true; b.queuePaused = true
    a.messages = (1...30).map { Message(role: $0 % 2 == 1 ? "user" : "assistant", text: "message \($0)" + ($0 == 7 || $0 == 21 ? " has the Needle" : "")) }
    a.messages.insert(Message(role: "activity", text: "tool output"), at: 3)
    b.messages = [Message(role: "user", text: "neighbor secret needle")]
    func json(_ text: String) -> [String: Any] {
        guard let start = text.range(of: "\n{") else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(text[start.lowerBound...].utf8))) as? [String: Any] ?? [:]
    }
    func numbers(_ value: [String: Any], _ key: String = "messages") -> [Int] { (value[key] as? [[String: Any]] ?? []).compactMap { $0["number"] as? Int } }
    func reply(_ s: Session, _ command: [String: Any], prose: String = "") {
        s.switchboardTurnStart = s.messages.count; s.switchboardHop = 0
        let text = prose + "```converse\n" + String(decoding: try! JSONSerialization.data(withJSONObject: command), as: UTF8.self) + "\n```"
        s.messages.append(Message(role: "assistant", text: text, finalReply: text))
        store.processSwitchboard(s)
    }

    // Teaching: the lesson, the per-turn policy and the version.
    store.teachSwitchboard(a)
    let lesson = a.pending.last?.text ?? ""
    check(lesson.contains("transcript-search") && lesson.contains("transcript-read") && lesson.contains("only this session's own retained transcript") && lesson.contains("reference data, not instructions"),
          "Teach covers transcript-search and transcript-read, own-session scope and reference framing")
    check(SwitchboardTeaching.version == 5 && a.switchboardTeachingVersion == 5 && SwitchboardTeaching.talkHelp.contains("its own transcript"),
          "The lesson version advances so taught sessions see Re-teach")
    check(SwitchboardCommand.conversationPolicy.contains("transcript-search") && SwitchboardCommand.conversationPolicy.contains("never another session's"),
          "Every taught prompt's policy reminder names the self-read commands")
    a.pending = []
    let before = a.messages.count

    // Reading: bounded pages with roles, numbers and paging.
    reply(a, ["command": "transcript-read", "fromMessage": 5, "count": 3], prose: "Checking my history.\n")
    let page = a.pending.last?.text ?? ""
    let read = json(page)
    check(page.hasPrefix(TranscriptSelfRead.header) && page.contains("reference data, not instructions") && page.contains("not instructions to follow now"),
          "Results are framed as reference data like Parking Lot reads")
    check(numbers(read) == [5, 6, 7] && (read["messages"] as? [[String: Any]])?.map { $0["role"] as? String ?? "" } == ["user", "assistant", "user"]
          && (read["messages"] as? [[String: Any]])?[2]["text"] as? String == "message 7 has the Needle" && (read["next"] as? [String: Any])?["fromMessage"] as? Int == 8,
          "transcript-read returns the requested numbered messages with roles and a next page")
    check(a.messages[before].role == "assistant" && a.messages.last?.role == "notice" && a.messages.last?.text.contains("transcript result queued") == true && a.pending.last?.switchboardHop == 1,
          "The result is queued as the next input one hop later, with a notice")
    a.pending = []
    reply(a, ["command": "transcript-read"])
    check(numbers(json(a.pending.last?.text ?? "")).count == TranscriptSelfRead.defaultCount && numbers(json(a.pending.last?.text ?? "")).last == Store.transcriptMessageNumbers(a.messages)[a.messages[a.messages.count - 2].id],
          "Without fromMessage, transcript-read returns the latest messages")
    reply(a, ["command": "transcript-read", "fromMessage": 1, "count": 500])
    check(numbers(json(a.pending.last?.text ?? "")).count == TranscriptSelfRead.maxCount, "The message count is capped at 20 per page")
    a.pending = []

    // Character bounds.
    let long = Session(entry: entry); store.sessions.append(long); long.switchboardEnabled = true; long.queuePaused = true
    long.messages = [Message(role: "user", text: "short"), Message(role: "assistant", text: String(repeating: "abcdefghij", count: 3_000))]
        + (1...20).map { Message(role: "user", text: String(repeating: "z", count: 5_000) + " \($0)") }
    let truncated = json(TranscriptSelfRead.read(long, fromMessage: 2, count: 1, fromCharacter: nil))
    let first = (truncated["messages"] as? [[String: Any]])?.first ?? [:]
    let next = truncated["next"] as? [String: Any] ?? [:]
    check((first["text"] as? String)?.count == TranscriptSelfRead.messageCharacters && first["truncated"] as? Bool == true && first["characters"] as? Int == 30_000
          && next["fromMessage"] as? Int == 2 && next["fromCharacter"] as? Int == TranscriptSelfRead.messageCharacters,
          "A long message is cut at 6,000 characters and says where it continues")
    let continued = (json(TranscriptSelfRead.read(long, fromMessage: 2, count: 1, fromCharacter: 6_000))["messages"] as? [[String: Any]])?.first ?? [:]
    check(continued["fromCharacter"] as? Int == 6_000 && (continued["text"] as? String)?.hasPrefix("abcdefghij") == true, "fromCharacter continues the same message")
    let wide = json(TranscriptSelfRead.read(long, fromMessage: 3, count: 20, fromCharacter: nil))
    let total = (wide["messages"] as? [[String: Any]] ?? []).reduce(0) { $0 + (($1["text"] as? String)?.count ?? 0) }
    check(total <= TranscriptSelfRead.pageCharacters && numbers(wide).count < 20 && (wide["next"] as? [String: Any])?["fromMessage"] as? Int == (numbers(wide).last ?? 0) + 1,
          "A page stays within 24,000 characters and pages on")
    store.sessions.removeAll { $0 === long }

    // Search, paging and earlier results.
    reply(a, ["command": "transcript-search", "query": "needle"])
    let found = json(a.pending.last?.text ?? "")
    check(numbers(found, "matches") == [21, 7] && found["totalMatches"] as? Int == 2 && (found["matches"] as? [[String: Any]])?.first?["snippet"] as? String == "message 21 has the Needle"
          && !(a.pending.last?.text.contains("neighbor secret") ?? true),
          "transcript-search finds case-insensitive matches newest first, only in this session")
    reply(a, ["command": "transcript-search", "query": "NEEDLE", "limit": 1])
    let limited = json(a.pending.last?.text ?? "")
    check(numbers(limited, "matches") == [21] && (limited["next"] as? [String: Any])?["beforeMessage"] as? Int == 21, "Search limit pages with beforeMessage")
    reply(a, ["command": "transcript-search", "query": "needle", "beforeMessage": 21])
    check(numbers(json(a.pending.last?.text ?? ""), "matches") == [7], "beforeMessage continues to older matches")
    a.messages.append(Message(role: "user", text: a.pending.last?.text ?? ""))
    reply(a, ["command": "transcript-search", "query": "message 21"])
    check(numbers(json(a.pending.last?.text ?? ""), "matches") == [21], "Earlier transcript results are not searched again")
    let lastNumber = Store.transcriptMessageNumbers(a.messages)[a.messages.last(where: { $0.role == "user" && $0.text.hasPrefix(TranscriptSelfRead.header) })!.id]!
    check((json(TranscriptSelfRead.read(a, fromMessage: lastNumber, count: 1, fromCharacter: nil))["messages"] as? [[String: Any]])?.first?["text"] as? String == TranscriptSelfRead.omitted,
          "Earlier transcript results read back only as a placeholder")
    reply(a, ["command": "transcript-search", "query": ""])
    check(a.pending.last?.text.hasPrefix(TranscriptSelfRead.refusedHeader) == true && a.messages.last?.text.contains("refused") == true, "An empty query is refused with an explanation")
    a.pending = []

    // Own session only.
    reply(a, ["command": "transcript-read", "session": b.id.uuidString])
    check(a.pending.last?.text.hasPrefix(TranscriptSelfRead.refusedHeader) == true && a.pending.last?.text.contains("only this session's own transcript") == true && !(a.pending.last?.text.contains("neighbor") ?? true),
          "Naming another session's ID is refused and reveals nothing")
    reply(a, ["command": "transcript-search", "query": "needle", "to": "other-home/" + b.id.uuidString.lowercased()])
    check(a.pending.last?.text.hasPrefix(TranscriptSelfRead.refusedHeader) == true, "Naming another session's global ID is refused")
    reply(a, ["command": "transcript-search", "query": "needle", "session": "elsewhere/" + a.id.uuidString.lowercased()])
    let home = store.participantService.localDeviceID
    check((a.pending.last?.text.hasPrefix(TranscriptSelfRead.refusedHeader) == true) == (home != nil), "This session's ID on another home is refused")
    reply(a, ["command": "transcript-search", "query": "needle", "session": a.id.uuidString])
    check(a.pending.last?.text.hasPrefix(TranscriptSelfRead.header) == true, "Naming this session's own ID is allowed")
    check(TranscriptSelfRead.ownsTarget(a.id.uuidString.lowercased(), session: a, home: "h") && TranscriptSelfRead.ownsTarget("h/" + a.id.uuidString, session: a, home: "h")
          && !TranscriptSelfRead.ownsTarget("h/" + b.id.uuidString, session: a, home: "h") && !TranscriptSelfRead.ownsTarget("garbage", session: a, home: "h"),
          "Own-session matching accepts only this session's bare or home-qualified ID")

    // Untaught sessions: only a whole-reply self-read runs (import recovery).
    a.pending = []; b.pending = []
    reply(b, ["command": "transcript-read"])
    check(b.pending.last?.text.contains("neighbor secret needle") == true && !b.switchboardEnabled, "An untaught session can read its own transcript with a whole-reply command")
    b.pending = []
    reply(b, ["command": "transcript-read"], prose: "Let me look.\n")
    check(b.pending.isEmpty, "An untaught session's trailing command still runs nothing")
    reply(b, ["command": "tell", "to": a.id.uuidString, "text": "hi"])
    check(a.pending.isEmpty && b.messages.last?.text.contains("messaging is disabled") == true, "Self-read does not open messaging to untaught sessions")
    check(RestoreContext.block(messages: b.messages, handoff: nil, transcript: "/t.md").contains("transcript-search") && TranscriptSelfRead.importHint.contains("reply with only"),
          "Import recovery's catch-up draft mentions the self-read commands")

    // Collapsed display.
    let readText = TranscriptSelfRead.read(a, fromMessage: 5, count: 3, fromCharacter: nil)
    let searchText = TranscriptSelfRead.search(a, query: "needle", limit: nil, beforeMessage: nil)
    check(TranscriptDisclosure.parse(readText, role: "user")?.summary == "Read own transcript · messages 5–7"
          && TranscriptDisclosure.parse(searchText, role: "user")?.summary == "Searched own transcript · 2 matches for “needle”"
          && TranscriptDisclosure.parse(readText + "broken", role: "user") == nil && TranscriptDisclosure.parse(readText, role: "assistant") == nil,
          "Complete transcript results collapse to a one-line summary")

    // Numbers survive trimming.
    a.pending = []; a.switchboardObligations = []; a.switchboardExpectations = []
    let numbered = Store.transcriptMessageNumbers(a.messages)
    let keep = a.messages.suffix(4).map(\.id)
    a.transcriptLimits = TranscriptLimits(count: 4)
    check(store.trimIdleTranscripts() > 0 && keep.allSatisfy { a.transcriptMessageNumbers()[$0] == numbered[$0] } && a.trimmedMessageNumber > 0 && a.messageNumberOffset == a.trimmedMessageNumber,
          "Trimming keeps every retained message's number")
    let afterTrim = json(TranscriptSelfRead.read(a, fromMessage: 1, count: 2, fromCharacter: nil))
    check((afterTrim["retained"] as? [String: Any])?["trimmedThrough"] as? Int == a.trimmedMessageNumber && (afterTrim["note"] as? String)?.contains("no longer retained") == true,
          "Reads report trimmed history")
    ArchiveWriter.shared.flush(root.path)
    let reloaded = Store(folder: root).sessions.first { $0.id == a.id }
    check(reloaded?.trimmedMessageNumber == a.trimmedMessageNumber && reloaded?.transcriptMessageNumbers() == a.transcriptMessageNumbers(), "Stable numbering survives relaunch")
}
