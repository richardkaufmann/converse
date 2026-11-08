import AppKit

func transcriptRetentionSelfTests(_ check: (Bool, String) -> Void) {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("converse-retention-" + UUID().uuidString).resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: root) }
    let suite = "converse-retention-" + UUID().uuidString
    let oldDefaults = TranscriptLimits.defaults
    TranscriptLimits.defaults = UserDefaults(suiteName: suite)!
    defer { TranscriptLimits.defaults.removePersistentDomain(forName: suite); TranscriptLimits.defaults = oldDefaults }
    func wait(_ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    let folder = root.appendingPathComponent("profile")
    let store = Store(folder: folder)
    let entry = Entry(name: "Retention", command: "unused", directory: root.path, engine: "codex")

    check(TranscriptLimits.newSessionDefault == TranscriptLimits() && store.create(entry).transcriptLimits == TranscriptLimits(days: nil, count: 1000), "Built-in default is no age limit and 1,000 messages")
    TranscriptLimits.newSessionDefault = TranscriptLimits(days: 30, count: nil)
    check(store.create(entry).transcriptLimits == TranscriptLimits(days: 30, count: nil) && store.sessions[0].transcriptLimits.count == 1000, "The global default seeds new sessions only")
    TranscriptLimits.newSessionDefault = TranscriptLimits()
    store.sessions.removeAll()
    check(TranscriptLimits.unitExplanation.contains("Each prompt and each response counts as one message") && TranscriptLimits.unitExplanation.contains("a prompt and its response are two")
          && TranscriptLimits.timingExplanation.contains("every minute") && TranscriptLimits.timingExplanation.contains("idle"),
          "The counting unit and timing are stated plainly")
    check(TranscriptLimits(days: 7, count: nil).summary == "Deletes messages older than 7 days" && TranscriptLimits(days: nil, count: nil).summary == "Keeps everything", "Limits summarize in plain words")

    // Files: owned, shared, protected elsewhere, outside Converse, and a link out.
    let s = store.create(entry), other = store.create(entry)
    s.queuePaused = true; other.queuePaused = true
    let mine = folder.appendingPathComponent("Attachments/" + s.id.uuidString)
    try? fm.createDirectory(at: mine.appendingPathComponent("Outputs"), withIntermediateDirectories: true)
    func file(_ name: String, in dir: URL? = nil) -> String {
        let url = (dir ?? mine).appendingPathComponent(name); try? Data(name.utf8).write(to: url); return url.path
    }
    let solo = file("solo.png"), output = file("Outputs/reply.png"), shared = file("shared.png"), drafted = file("drafted.png")
    let queued = file("queued.png"), closed = file("closed.png"), mentioned = file("mentioned.png")
    let handedOff = file("handed-off.png"), noted = file("noted.png")
    let outsideDir = root.appendingPathComponent("user-files"); try? fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
    let outside = file("outside.png", in: outsideDir)
    let link = mine.appendingPathComponent("link.png").path
    try? fm.createSymbolicLink(atPath: link, withDestinationPath: outside)
    let old = Date().addingTimeInterval(-86400 * 40)
    s.messages = [
        Message(role: "user", text: "old prompt", images: [solo, shared, drafted, queued, closed, mentioned, handedOff, noted], createdAt: old),
        Message(role: "assistant", text: "old reply", images: [output, outside, link], createdAt: old),
        Message(role: "notice", text: "old notice", createdAt: old),
        Message(role: "user", text: "new prompt", images: [shared]),
        Message(role: "assistant", text: "new reply"),
    ]
    other.draft = "keep my draft"; other.attachments = [drafted]
    other.pending = [PendingPrompt(text: "queued with image", images: [queued])]
    other.messages = [Message(role: "assistant", text: "See " + URL(fileURLWithPath: mentioned).absoluteString)]
    var snapshot = s.saved; snapshot.id = UUID(); snapshot.messages = [Message(role: "user", text: "closed", images: [closed])]
    try? fm.createDirectory(at: folder.appendingPathComponent("Deleted Sessions"), withIntermediateDirectories: true)
    try? JSONEncoder().encode(snapshot).write(to: folder.appendingPathComponent("Deleted Sessions/" + snapshot.id.uuidString + ".json"))
    // Handoff files written for sessions no longer in memory: the only references left.
    var handoff = s.saved; handoff.id = UUID(); handoff.messages = [Message(role: "user", text: "handed over", images: [handedOff])]
    let handoffTranscript = try? store.writeHandoffTranscript(Session(handoff), pending: nil)
    handoff.id = UUID()
    let handoffNote = try? store.writeHandoffNote(Session(handoff), text: "Pick up from " + noted)
    let numbersBefore = s.transcriptMessageNumbers()

    // None/None, then a declined and an accepted change.
    var asked: [String] = []
    check(store.applyTranscriptLimits(s, TranscriptLimits(days: nil, count: nil), confirm: { title, _ in asked.append(title); return true }) && asked.isEmpty && s.messages.count == 5,
          "None for both limits keeps everything without asking")
    check(!store.applyTranscriptLimits(s, TranscriptLimits(days: 30, count: nil), confirm: { title, _ in asked.append(title); return false })
          && s.transcriptLimits == TranscriptLimits(days: nil, count: nil) && s.messages.count == 5 && asked.count == 1,
          "Declining the confirmation saves nothing and deletes nothing")
    var detail = "", deletedFiles = -1
    check(store.applyTranscriptLimits(s, TranscriptLimits(days: 30, count: nil), confirm: { _, text in detail = text; return true }, deleted: { deletedFiles = $0 }),
          "Accepting saves the age limit")
    check(detail.contains("2 prompts and responses and 11 images") && detail.contains("now"), "The confirmation counts prompts, responses and images")
    wait { deletedFiles >= 0 }
    check(s.messages.map(\.text) == ["new prompt", "new reply"] && s.transcriptLimits.days == 30, "Age trimming removes the old turn and its notice")
    check(deletedFiles == 2 && !fm.fileExists(atPath: solo) && !fm.fileExists(atPath: output), "Images used only by trimmed messages are deleted, including Outputs")
    check([shared, drafted, queued, closed, mentioned].allSatisfy { fm.fileExists(atPath: $0) },
          "Images still used by a message, a draft, a queued prompt, a closed session or message text are kept")
    check(handoffTranscript.map { (try? String(contentsOf: $0, encoding: .utf8))?.contains(handedOff) == true } == true && handoffNote != nil
          && fm.fileExists(atPath: handedOff) && fm.fileExists(atPath: noted),
          "Images named only by a handoff transcript.md or handoff.md are kept")
    check(fm.fileExists(atPath: outside) && (try? fm.destinationOfSymbolicLink(atPath: link)) == outside, "Files outside Converse and links out of Attachments are never deleted")
    check(other.draft == "keep my draft" && other.attachments == [drafted] && other.pending.count == 1 && other.pending[0].images == [queued], "Other sessions' drafts and queued work are untouched")
    check(s.messages.allSatisfy { s.transcriptMessageNumbers()[$0.id] == numbersBefore[$0.id] }, "Retained messages keep their numbers")
    ArchiveWriter.shared.flush(folder.path)
    let reload = Store(folder: folder).sessions.first { $0.id == s.id }
    check(reload?.messages.map(\.text) == ["new prompt", "new reply"] && reload?.transcriptLimits.days == 30 && reload?.transcriptLimits.count == nil
          && reload?.transcriptMessageNumbers() == s.transcriptMessageNumbers(),
          "The trimmed archive, its limits and numbering load back")

    other.messages.append(Message(role: "user", text: "busy image", images: [shared]))
    // Count limit waits while busy, then applies.
    s.messages += (1...6).map { Message(role: $0 % 2 == 1 ? "user" : "assistant", text: "turn \($0)") }
    s.busy = true
    check(store.applyTranscriptLimits(s, TranscriptLimits(days: nil, count: 4), confirm: { _, text in detail = text; return true }) && s.messages.count == 8 && detail.contains("when the session is idle"),
          "A busy session saves the limit and trims later")
    s.busy = false; s.draft = "draft"
    check(store.trimIdleTranscripts() == 0 && s.draft == "draft", "An active draft postpones trimming")
    s.draft = ""; s.pending = [PendingPrompt(text: "next", images: [])]
    check(store.trimIdleTranscripts() == 0, "Queued work postpones trimming")
    s.pending = []
    check(store.trimIdleTranscripts() == 4 && s.messages.map(\.text) == ["turn 3", "turn 4", "turn 5", "turn 6"], "Count trimming keeps the latest four messages")

    // Trim all images.
    let pasted = file("pasted.png"), reply = file("Outputs/reply2.png"), draftImage = file("draft.png")
    s.messages += [Message(role: "user", text: "", images: [pasted]), Message(role: "assistant", text: "Here it is", images: [reply, outside]), Message(role: "user", text: "after")]
    s.attachments = [draftImage]
    let numbered = s.transcriptMessageNumbers()
    check(!store.confirmTrimAllImages([s], confirm: { _, _ in false }) && s.messages.contains { !$0.images.isEmpty } && fm.fileExists(atPath: pasted),
          "Cancelling Trim All Images changes nothing")
    other.busy = true
    var prompt = ""; deletedFiles = -1
    check(store.confirmTrimAllImages([s, other], confirm: { _, text in prompt = text; return true }, deleted: { deletedFiles = $0 }), "Confirmed Trim All Images runs")
    other.busy = false
    wait { deletedFiles >= 0 }
    check(prompt.contains("3 images") && prompt.contains("1 busy session is skipped"), "The confirmation counts images and skipped busy sessions")
    check(s.messages.allSatisfy { $0.images.isEmpty } && s.messages.contains { $0.text == "[image removed]" } && s.messages.last?.role == "notice", "Every transcript image is removed with a notice")
    check(s.attachments == [draftImage] && fm.fileExists(atPath: draftImage) && !fm.fileExists(atPath: pasted) && !fm.fileExists(atPath: reply) && fm.fileExists(atPath: outside) && deletedFiles == 2,
          "Draft images, outside files and the busy session's images are kept")
    check(other.messages.last?.images == [shared] && fm.fileExists(atPath: shared), "Busy sessions are not modified")
    check(numbered.allSatisfy { id, number in s.transcriptMessageNumbers()[id] == number }, "Removing images keeps message numbers")
    var told = ""
    check(!store.confirmTrimAllImages([s], confirm: { title, _ in told = title; return true }) && told.hasPrefix("No images"), "With nothing to trim, the action explains and deletes nothing")

    // Cleanup reads files off the main thread and rechecks memory before deleting.
    let hold = DispatchSemaphore(value: 0)
    let late = file("late.png"), moved = file("moved.png"), free = file("free.png")
    Store.imageCleanupQueue.async { hold.wait() }
    var raced = -1
    store.deleteUnreferencedImages([late, free]) { raced = $0 }
    check(raced == -1 && fm.fileExists(atPath: late) && fm.fileExists(atPath: free), "Cleanup returns at once and does its file work in the background")
    other.messages.append(Message(role: "user", text: "late", images: [late]))
    hold.signal()
    wait { raced >= 0 }
    check(raced == 1 && fm.fileExists(atPath: late) && !fm.fileExists(atPath: free), "An image referenced after cleanup started is kept; unreferenced ones are deleted")
    // A handoff written after the background scan sends cleanup back to rescan.
    Store.imageCleanupQueue.async { hold.wait() }
    raced = -1
    store.deleteUnreferencedImages([moved]) { raced = $0 }
    store.imageReferenceFileWrites += 1
    let lateHandoff = folder.appendingPathComponent("Handoffs/" + UUID().uuidString)
    Store.imageCleanupQueue.async {
        try? fm.createDirectory(at: lateHandoff, withIntermediateDirectories: true)
        try? Data(("[Attached image: " + moved + "]").utf8).write(to: lateHandoff.appendingPathComponent("transcript.md"))
    }
    hold.signal()
    wait { raced >= 0 }
    check(raced == 0 && fm.fileExists(atPath: moved), "A closed-session or handoff write during cleanup is rescanned before deleting")

    // The work that stays on the main thread, over a large active history.
    let large = Store(folder: root.appendingPathComponent("large"))
    let body = String(repeating: "A long retained message without any file paths in it. ", count: 30)
    for _ in 0..<40 { let session = large.create(entry); session.queuePaused = true; session.messages = (0..<1500).map { _ in Message(role: "user", text: body) } }
    let spellings = (0..<20).map { ImageReferences.Spellings(mine.appendingPathComponent("candidate-\($0).png").path) }
    let started = Date()
    _ = large.liveImageReferences()
    let current = large.liveImageReferences().prepared(for: spellings)
    let unused = spellings.allSatisfy { !current.uses($0) }
    let elapsed = Date().timeIntervalSince(started)
    check(unused && elapsed < 2, "Snapshot and recheck on the main thread stay short over 60,000 messages (\(Int(elapsed * 1000)) ms)")
}
