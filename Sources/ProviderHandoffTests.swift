import AppKit
import SwiftUI
import Foundation

func providerHandoffSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-handoff-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = Store(folder: root.appendingPathComponent("data"))
    func wait(_ done: () -> Bool, seconds: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }
    func reply(_ s: Session) -> String { s.messages.last { $0.role == "assistant" }?.text ?? "" }
    func occurrences(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    // Refusals: busy, agents, App Support and remote sessions.
    let plain = store.create(Entry(name: "Codex", command: "codex", directory: NSTemporaryDirectory(), engine: "codex"))
    plain.busy = true
    var busyNote: Result<String, Error>?
    store.requestHandoffNote(plain) { busyNote = $0 }
    let codexLogin = store.makeLogin(engine: "codex", name: "Test Codex")
    check(store.providerChangeRefusal(plain)?.contains("Finish or stop") == true && (try? store.switchProvider(plain, entry: store.defaultEntry(engine: "claude"), profile: store.makeLogin(engine: "claude", name: "Busy"), note: false)) == nil && plain.entry.engine == "codex",
          "A busy session refuses to change its assistant")
    if case .failure = busyNote { check(true, "A busy session cannot start a handoff turn") } else { check(false, "A busy session cannot start a handoff turn") }
    plain.busy = false
    let agent = store.create(Entry(name: "Agent", command: "", directory: NSTemporaryDirectory(), engine: "agent")); agent.agent = AgentConfig()
    let support = store.create(Entry(name: "Support", command: "", directory: NSTemporaryDirectory(), engine: "support")); support.supportAssistant = true
    check(store.providerChangeRefusal(agent)?.contains("Agent Setup") == true && store.providerChangeRefusal(support)?.contains("App Support") == true && !store.handoffAvailable(agent),
          "Agents and App Support explain where their assistant is chosen")
    check(ProviderHandoff.remoteRefusal.contains("on that device"), "Remote Group sessions say to change the assistant on their home device")

    // Same assistant, another login: the same conversation continues (no handoff).
    let personal = store.makeLogin(engine: "claude", name: "Personal"), work = store.makeLogin(engine: "claude", name: "Work")
    let claudeEntry = Entry(name: "Claude", command: "claude", directory: NSTemporaryDirectory(), engine: "claude")
    let resumed = store.createBoundSession(entry: claudeEntry, profile: personal, title: "Two accounts")!
    let context = URL(fileURLWithPath: personal.directory).appendingPathComponent("projects/test/retained-handoff.jsonl")
    try? FileManager.default.createDirectory(at: context.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data("retained".utf8).write(to: context)
    resumed.remoteID = "retained-handoff"; resumed.started = true; resumed.messages = [Message(role: "assistant", text: "keep context")]
    check(store.conversationChange(resumed, engine: "claude", accountID: personal.id) == .none && store.conversationChange(resumed, engine: "claude", accountID: work.id) == .login
          && store.conversationChange(resumed, engine: "codex", accountID: codexLogin.id) == .provider, "The Configure sheet tells a login change from an assistant change")
    store.chooseAccount(resumed, profile: work)
    check(resumed.entry.accountID == work.id && resumed.remoteID == "retained-handoff" && resumed.started && resumed.handoffPending == nil && resumed.messages.count == 1
          && !FileManager.default.fileExists(atPath: store.handoffFolder(resumed).path)
          && FileManager.default.fileExists(atPath: URL(fileURLWithPath: work.directory).appendingPathComponent("projects/test/retained-handoff.jsonl").path),
          "Same assistant with another login resumes the same conversation and writes no handoff")

    guard let command = ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"], let museLogin = store.preferredLogin(engine: "muse") else {
        check(false, "Provider handoff tests need the echo provider"); return
    }
    // A stand-in Codex that answers with its prompt, so the takeover line is visible.
    let fakeCodex = root.appendingPathComponent("fake-codex")
    try? """
    #!/usr/bin/python3 -I
    import json, sys
    args = sys.argv[1:]
    prompt = args[args.index("--") + 1] if "--" in args else ""
    if "--output-last-message" in args:
        open(args[args.index("--output-last-message") + 1], "w").write("CODEX: " + prompt)
    print(json.dumps({"type": "thread.started", "thread_id": "fake-thread"}))
    print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "CODEX: " + prompt}}))
    """.write(to: fakeCodex, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodex.path)
    setenv("CONVERSE_SKIP_STATUS_PROBE", "1", 1)
    defer { unsetenv("CONVERSE_SKIP_STATUS_PROBE") }
    let echo = Entry(name: "Muse", command: command, directory: NSTemporaryDirectory(), engine: "muse")
    var codex = store.defaultEntry(engine: "codex"); codex.command = fakeCodex.path; codex.directory = NSTemporaryDirectory()
    let session = store.createBoundSession(entry: echo, profile: museLogin, title: "Launch plan")!
    session.draft = "Plan the launch"; store.send(session); wait { !session.busy }
    check(reply(session).contains("Plan the launch") && session.started, "Handoff fixture: the echo provider answered the first turn")

    // The Configure sheet: Assistant and Login at the top, then name, command and folder.
    func render(_ s: Session, name: String) -> CGFloat {
        let view = NSHostingView(rootView: ConfigureConversationView(session: s, focusPickers: true))
        view.frame = NSRect(origin: .zero, size: view.fittingSize); view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("converse-configure-" + name + ".png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            print("Configure sheet fixture: " + url.path)
        }
        return view.fittingSize.height
    }
    check(render(session, name: "session") > 250 && render(agent, name: "agent") > 100, "Configure conversation renders for sessions and, with pickers locked, for agents")

    // Different assistant: the outgoing one writes handoff.md in a visible turn.
    session.draft = "unsent draft"; session.attachments = ["/tmp/unsent.png"]
    var outcome: ProviderChangeOutcome?
    check(store.conversationChange(session, engine: "codex", accountID: codexLogin.id) == .provider && store.handoffAvailable(session), "A different assistant takes the handoff path, offered by default")
    store.changeProvider(session, handoff: true, target: { (codex, codexLogin) }) { outcome = $0 }
    wait { outcome != nil }
    let note = (try? String(contentsOf: store.handoffNoteURL(session), encoding: .utf8)) ?? ""
    let transcript = (try? String(contentsOf: store.handoffTranscriptURL(session), encoding: .utf8)) ?? ""
    check(outcome == .switched(note: true) && note.contains("handoff note for your successor") && !note.contains("[Converse: "),
          "The outgoing provider's reply is saved as Handoffs/<id>/handoff.md")
    check(session.messages.contains { $0.role == "user" && $0.text == ProviderHandoff.prompt } && transcript.contains("Plan the launch") && transcript.contains("## Response"),
          "The handoff turn is ordinary history, and transcript.md holds the conversation")
    check(session.entry.engine == "codex" && session.entry.accountID == codexLogin.id && session.remoteID == nil && !session.started && session.freshConversationID != nil
          && session.handoffPending == HandoffPending(from: "Muse", note: true), "Switching binds the new assistant and login and starts a fresh provider conversation")
    check(session.draft == "unsent draft" && session.attachments == ["/tmp/unsent.png"] && !session.queuePaused, "The handoff turn keeps the draft and attachments")
    let reloaded = Store(folder: store.folder).sessions.first { $0.id == session.id }
    check(reloaded?.handoffPending == session.handoffPending && reloaded?.freshConversationID == session.freshConversationID && reloaded?.entry.engine == "codex", "The pending handoff survives relaunch")
    let legacy = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(session.saved)) as? [String: Any]
    if var legacy { legacy["handoffPending"] = nil; legacy["importedTranscriptPending"] = true
        let old = (try? JSONSerialization.data(withJSONObject: legacy)).flatMap { try? JSONDecoder().decode(SavedSession.self, from: $0) }.map(Session.init)
        check(old?.handoffPending == HandoffPending(from: nil, note: false) && old?.importedTranscriptPending == true, "Archives from build 130 keep their pending import preface")
    } else { check(false, "Legacy archive fixture") }

    // First send to the new provider carries the takeover line once.
    session.draft = "Carry on"; store.send(session); wait { !session.busy }
    let takeover = ProviderHandoff.takeoverPreface(from: "Muse", handoff: store.handoffNoteURL(session).path, transcript: store.handoffTranscriptURL(session).path)
    check(occurrences(takeover, in: reply(session)) == 1 && reply(session).contains("Carry on") && session.messages.contains { $0.role == "user" && $0.text == "Carry on" },
          "The first prompt to the new provider carries one takeover line; the visible prompt is unchanged")
    check(session.handoffPending == nil, "The takeover line is cleared after a successful turn")
    session.draft = "Next"; store.send(session); wait { !session.busy }
    check(!reply(session).contains("taking over"), "Later prompts carry no takeover line")

    // A failed handoff turn switches nothing and offers to go on without a note.
    var failing = codex; failing.command = "/usr/bin/false"; session.entry = failing
    outcome = nil
    store.changeProvider(session, handoff: true, target: { (echo, museLogin) }) { outcome = $0 }
    wait { outcome != nil }
    if case .noteFailed = outcome { check(session.entry.engine == "codex", "A failed handoff turn leaves the session on its assistant") } else { check(false, "A failed handoff turn leaves the session on its assistant") }
    session.entry.command = fakeCodex.path
    outcome = nil
    store.changeProvider(session, handoff: false, target: { (echo, museLogin) }) { outcome = $0 }
    check(outcome == .switched(note: false) && session.entry.engine == "muse" && session.handoffPending == HandoffPending(from: "Codex", note: false)
          && !FileManager.default.fileExists(atPath: store.handoffNoteURL(session).path), "Switching without a note removes the old note")
    // The flag clears only after success.
    session.entry.command = "/usr/bin/false"
    session.draft = "Will fail"; store.send(session); wait { !session.busy }
    check(session.handoffPending != nil, "A failed first turn keeps the takeover line for the retry")
    session.entry.command = command; session.queuePaused = false
    session.draft = "Retry"; store.send(session); wait { !session.busy }
    let bare = ProviderHandoff.takeoverPreface(from: "Codex", handoff: nil, transcript: store.handoffTranscriptURL(session).path)
    check(occurrences(bare, in: reply(session)) == 1 && !bare.contains("handoff.md") && session.handoffPending == nil, "Without a note the takeover line omits the handoff clause")

    // Export with handoff notes: each selected session writes its note first.
    var notes: (notes: [UUID: String], failures: [String])??
    Task { @MainActor in notes = await TranscriptExportController.collectHandoffs([ExportSession(session), ExportSession(agent)], store: store) }
    wait({ notes != nil }, seconds: 40)
    let collected = ((notes ?? nil)?.notes) ?? [:]
    check(collected.count == 1 && collected[session.id]?.contains("handoff note for your successor") == true, "Include handoff notes asks each local, bound, idle session (not agents) for a note")
    // A stalled handoff turn times out instead of hanging the export, and
    // Cancel returns at once even while a turn is still running.
    let stall = root.appendingPathComponent("stall-provider")
    try? "#!/bin/zsh\nsleep 30\n".write(to: stall, atomically: true, encoding: .utf8)
    _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stall.path)
    let savedCommand = session.entry.command, savedTimeout = ProviderHandoff.exportNoteTimeout
    session.entry.command = stall.path; ProviderHandoff.exportNoteTimeout = 2
    var timed: (notes: [UUID: String], failures: [String])??
    let started = Date()
    Task { @MainActor in timed = await TranscriptExportController.collectHandoffs([ExportSession(session)], store: store) }
    wait({ timed != nil }, seconds: 20)
    check(Date().timeIntervalSince(started) < 15 && (timed ?? nil)?.failures.first?.contains("No handoff note after") == true,
          "A stalled handoff turn times out and is reported instead of hanging the export")
    wait({ !session.busy }, seconds: 10)
    ProviderHandoff.exportNoteTimeout = 60
    let progress = HandoffExportProgress()
    var cancelledToNil = false, finished = false
    Task { @MainActor in cancelledToNil = await TranscriptExportController.collectHandoffs([ExportSession(session)], store: store, progress: progress) == nil; finished = true }
    wait({ session.busy }, seconds: 10)
    progress.cancel()
    wait({ finished }, seconds: 10)
    check(finished && cancelledToNil, "Cancel ends the handoff export at once, even while a turn is running")
    wait({ !session.busy }, seconds: 10)
    session.entry.command = savedCommand; ProviderHandoff.exportNoteTimeout = savedTimeout; session.queuePaused = false

    // One serial queue per provider, the queues side by side. Slow stand-ins
    // log when each turn starts and ends, and tag their note.
    let turnLog = root.appendingPathComponent("handoff-turns.log")
    func slowCodex(_ tag: String, seconds: Double) -> String {
        let url = root.appendingPathComponent("slow-codex-" + tag)
        try? """
        #!/usr/bin/python3 -I
        import json, sys, time
        args = sys.argv[1:]
        log = open(\(String(reflecting: turnLog.path)), "a")
        log.write("start \(tag) %f\\n" % time.time()); log.flush()
        time.sleep(\(seconds))
        text = "\(tag): " + (args[args.index("--") + 1] if "--" in args else "")
        if "--output-last-message" in args:
            open(args[args.index("--output-last-message") + 1], "w").write(text)
        print(json.dumps({"type": "thread.started", "thread_id": "slow-\(tag)"}))
        print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": text}}))
        log.write("end \(tag) %f\\n" % time.time())
        """.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }
    let slowMuse = root.appendingPathComponent("slow-muse")
    try? "#!/bin/zsh\nsleep 2\nexec \(command) \"$@\"\n".write(to: slowMuse, atomically: true, encoding: .utf8)
    _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowMuse.path)
    func codexSession(_ title: String, command: String) -> Session? {
        var entry = codex; entry.command = command
        return store.createBoundSession(entry: entry, profile: codexLogin, title: title)
    }
    var slowEcho = echo; slowEcho.command = slowMuse.path
    guard let codexA = codexSession("Queue A", command: slowCodex("A", seconds: 2)), let codexB = codexSession("Queue B", command: slowCodex("B", seconds: 2)),
          let museC = store.createBoundSession(entry: slowEcho, profile: museLogin, title: "Queue C") else { check(false, "Handoff queue fixtures"); return }
    let queueProgress = HandoffExportProgress()
    var queued: (notes: [UUID: String], failures: [String])??
    var sawLines: [String] = []
    let queueStarted = Date()
    Task { @MainActor in queued = await TranscriptExportController.collectHandoffs([codexA, museC, codexB].map(ExportSession.init), store: store, progress: queueProgress) }
    wait({ queueProgress.active.count == 2 }, seconds: 10)
    sawLines = queueProgress.lines.map(\.text)
    check(codexA.busy && museC.busy && !codexB.busy, "Each provider's queue runs at once; the same provider waits its turn")
    wait({ queued != nil }, seconds: 40)
    let queueWall = Date().timeIntervalSince(queueStarted)
    let queuedNotes = (queued ?? nil)?.notes ?? [:]
    check(sawLines == ["Codex: 1 of 2 — Queue A", "Muse: 1 of 1 — Queue C"] && queueProgress.lines.map(\.text) == ["Codex: done", "Muse: done"],
          "The progress panel shows one line per provider")
    check(queuedNotes[codexA.id]?.hasPrefix("A: ") == true && queuedNotes[codexB.id]?.hasPrefix("B: ") == true
          && queuedNotes[museC.id]?.contains("handoff note for your successor") == true && queuedNotes[museC.id]?.contains("CODEX") == false
          && (queued ?? nil)?.failures.isEmpty == true, "Each handoff note maps to its own session")
    let turns = ((try? String(contentsOf: turnLog, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.split(separator: " ") }
    let span: (String) -> (Double, Double)? = { tag in
        guard let start = turns.first(where: { $0.count == 3 && $0[0] == "start" && $0[1] == tag }).flatMap({ Double($0[2]) }),
              let end = turns.first(where: { $0.count == 3 && $0[0] == "end" && $0[1] == tag }).flatMap({ Double($0[2]) }) else { return nil }
        return (start, end)
    }
    if let a = span("A"), let b = span("B") { check(b.0 >= a.1 || a.0 >= b.1, "One provider never runs two handoff turns at once") }
    else { check(false, "One provider never runs two handoff turns at once") }
    let noteSum = queueProgress.noteSeconds.values.reduce(0, +)
    check(queueProgress.noteSeconds.count == 3 && queueWall < noteSum - 1 && queueProgress.wallSeconds < noteSum - 1,
          "Different providers write their notes concurrently (wall \(HandoffExportProgress.duration(queueWall)) < notes \(HandoffExportProgress.duration(noteSum)))")
    check(queueProgress.summary.hasPrefix("Codex 2 notes in ") && queueProgress.summary.contains("; Muse 1 note in ") && queueProgress.summary.contains("total "),
          "Handoff export timing: " + queueProgress.summary)

    // Cancel stops every provider's active turn and returns at once; a stall
    // times out per session, the queues side by side.
    for s in [codexA, museC] { s.entry.command = stall.path; s.queuePaused = false }
    let cancelAll = HandoffExportProgress()
    var allCancelled = false, cancelDone = false
    Task { @MainActor in allCancelled = await TranscriptExportController.collectHandoffs([codexA, museC].map(ExportSession.init), store: store, progress: cancelAll) == nil; cancelDone = true }
    wait({ codexA.busy && museC.busy }, seconds: 10)
    let cancelAt = Date()
    cancelAll.cancel()
    wait({ cancelDone }, seconds: 10)
    check(cancelDone && allCancelled && Date().timeIntervalSince(cancelAt) < 2, "Cancel returns nil at once with two providers mid-turn")
    wait({ !codexA.busy && !museC.busy }, seconds: 10)
    check(!codexA.busy && !museC.busy, "Cancel stops every export-owned handoff turn")
    for s in [codexA, museC] { s.queuePaused = false }
    ProviderHandoff.exportNoteTimeout = 2
    var stalled: (notes: [UUID: String], failures: [String])??
    let stallStarted = Date()
    Task { @MainActor in stalled = await TranscriptExportController.collectHandoffs([codexA, museC].map(ExportSession.init), store: store) }
    wait({ stalled != nil }, seconds: 20)
    let stallFailures = (stalled ?? nil)?.failures ?? []
    check(Date().timeIntervalSince(stallStarted) < 3.5 && stallFailures.count == 2 && stallFailures[0].hasPrefix("“Queue A” (Codex, ") && stallFailures[1].hasPrefix("“Queue C” (Muse, ")
          && stallFailures.allSatisfy { $0.contains("No handoff note after") }, "Each stalled session reports its own time limit, with its duration")
    wait({ !codexA.busy && !museC.busy }, seconds: 10)
    ProviderHandoff.exportNoteTimeout = savedTimeout
    for s in [codexA, museC, codexB] { try? store.closeSessionChecked(s) }
    var exported = ExportSession(session); exported.handoff = "Reach me at handoff@example.invalid. key sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
    var scrubber: ExportScrubber? = ExportScrubber(context: .init())
    var plainScrub: ExportScrubber? = nil
    let scrubbed = try? ConverseExchange.decode(ConverseExchange.export([exported], content: .both, scrubber: &scrubber, includeImages: false, imageData: { _ in nil }))
    let kept = try? ConverseExchange.decode(ConverseExchange.export([exported, ExportSession(resumed)], content: .both, scrubber: &plainScrub, includeImages: false, imageData: { _ in nil }))
    let scrubbedNote = scrubbed?.document.sessions.first?.handoff ?? ""
    check(scrubbedNote.contains("[email 1]") && !scrubbedNote.contains("example.invalid") && !scrubbedNote.contains("sk-ant-"), "Handoff notes are scrubbed with the rest of the export")
    check(kept?.document.sessions.first?.handoff == exported.handoff && kept?.document.sessions.last?.handoff == nil, "Handoff notes travel in the session record; sessions without one omit it")

    // Import: a record with a note starts from the handoff.
    guard var package = kept else { check(false, "Handoff export fixture"); return }
    package.document.sessions[0].provider = "Claude"
    let target = Store(folder: root.appendingPathComponent("target"))
    let library = ParkingLotLibrary(folder: target.folder)
    do {
        let imported = try target.importConverse(package, sessions: Set(package.document.sessions.map(\.exportID)), lots: [], library: library).sessions
        let withNote = imported[0], without = imported[1]
        check(withNote.handoffPending == HandoffPending(from: "Claude", note: true) && (try? String(contentsOf: target.handoffNoteURL(withNote), encoding: .utf8)) == exported.handoff
              && without.handoffPending == HandoffPending(from: nil, note: false), "Importing a record with a handoff note writes handoff.md and plans a takeover; others keep the import preface")
        let targetMuse = target.preferredLogin(engine: "muse")!
        check(target.bindImportedSession(withNote, entry: echo, profile: targetMuse), "Late binding an import with a note")
        withNote.draft += "Pick it up"; target.send(withNote); wait { !withNote.busy }
        let line = ProviderHandoff.takeoverPreface(from: "Claude", handoff: target.handoffNoteURL(withNote).path, transcript: target.handoffTranscriptURL(withNote).path)
        check(occurrences("Read the handoff note first: " + target.handoffNoteURL(withNote).path, in: reply(withNote)) == 1 && occurrences(line, in: reply(withNote)) == 0 && !reply(withNote).contains("this conversation was imported"),
              "An imported handoff note is named in the visible catch-up draft instead of a hidden line")
    } catch { check(false, "Handoff import failed: " + error.localizedDescription) }
    // Older files without `handoff` import exactly as before; oversized notes are refused.
    if let data = try? JSONEncoder().encode(package.document), var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], var records = object["sessions"] as? [[String: Any]] {
        for index in records.indices { records[index]["handoff"] = nil }
        object["sessions"] = records
        let old = (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? ConverseExchange.decode($0) }
        let oldImport = old.flatMap { try? target.importConverse($0, sessions: Set($0.document.sessions.map(\.exportID)), lots: [], library: library).sessions }
        check(old?.document.sessions.allSatisfy { $0.handoff == nil } == true && oldImport?.allSatisfy { $0.handoffPending == HandoffPending(from: nil, note: false) && !FileManager.default.fileExists(atPath: target.handoffNoteURL($0).path) } == true,
              "Version 1 files without handoff notes import as before")
        records[0]["handoff"] = String(repeating: "x", count: ProviderHandoff.maxNoteCharacters + 1); object["sessions"] = records
        do { _ = try ConverseExchange.decode(JSONSerialization.data(withJSONObject: object)); check(false, "Oversized handoff note rejected") }
        catch { check(error.localizedDescription.contains("handoff note longer"), "An oversized handoff note is refused before import") }
    } else { check(false, "Old-format fixture") }
}
