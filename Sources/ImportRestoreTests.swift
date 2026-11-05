import AppKit
import SwiftUI
import Foundation

func importRestoreSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-restore-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func wait(_ done: () -> Bool, seconds: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }
    func reply(_ s: Session) -> String { s.messages.last { $0.role == "assistant" }?.text ?? "" }
    func occurrences(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    // The block: framing, optional note, the last ten messages oldest first, capped.
    var history = (1...14).map { Message(role: $0 % 2 == 1 ? "user" : "assistant", text: "message \($0) body") }
    history.insert(Message(role: "notice", text: "a notice, not a message"), at: 6)
    history[13].text = String(repeating: "x", count: 3_000)
    history[14].images = ["/tmp/picture.png"]
    let block = RestoreContext.block(messages: history, handoff: nil, transcript: "/data/transcript.md")
    let positions = (5...14).compactMap { block.range(of: "message \($0) body")?.lowerBound }
    check(block.hasPrefix(RestoreContext.framing) && block.contains("The last 10 messages:") && block.hasSuffix("Full transcript: /data/transcript.md") && !block.contains("handoff note"),
          "The catch-up block frames the context as a record and ends with the transcript path")
    check(positions.count == 9 && positions == positions.sorted() && !block.contains("message 4 body") && !block.contains("a notice") && block.contains("User: message 5 body"),
          "The block holds exactly the last ten user/assistant messages, oldest first and role-labeled")
    let long = block.components(separatedBy: "\n\n").first { $0.hasPrefix("User: xxx") } ?? ""
    check(long.hasSuffix(RestoreContext.truncated) && long.count == "User: ".count + RestoreContext.messageLimit && block.contains("message 14 body\n[image]"),
          "Each message is capped at 2,000 characters, and images appear as [image]")
    let huge = (1...12).map { Message(role: $0 % 2 == 1 ? "user" : "assistant", text: "m\($0) " + String(repeating: "y", count: 5_000)) }
    let capped = RestoreContext.block(messages: huge, handoff: "/data/handoff.md", transcript: "/data/transcript.md")
    check(capped.count <= RestoreContext.blockLimit && capped.contains("m12 ") && capped.contains("Read the handoff note first: /data/handoff.md\n") && capped.hasSuffix("Full transcript: /data/transcript.md"),
          "The whole block stays within 16,000 characters and keeps the newest messages")
    check(RestoreContext.merge("NEW", previous: nil, into: "  ") == "NEW\n\n" && RestoreContext.merge("NEW", previous: nil, into: "mine") == "NEW\n\n---\nmine"
          && RestoreContext.merge("NEW", previous: "OLD", into: "OLD\n\n---\nmine") == "NEW\n\n---\nmine" && RestoreContext.merge("NEW", previous: "OLD", into: "OLX, edited\n\nmine") == nil,
          "Merging puts the block first, keeps the human's draft after a separator, and replaces only an unedited earlier block")

    // Lead provider: App Support's agent route, or the first installed assistant.
    let store = Store(folder: root.appendingPathComponent("lead"))
    var cli: Set<String> = ["claude", "codex", "muse"]
    store.agentCommandAvailable = { cli.contains($0.engine) }
    let support = store.create(Entry(name: "Support", command: "", directory: NSTemporaryDirectory(), engine: "support")); support.supportAssistant = true
    let work = store.makeLogin(engine: "codex", name: "Work")
    support.agent = AgentConfig(); support.agent?.model = AgentModels.reference(engine: "codex", account: work.id)
    store.setupCompleted = true
    let defaults = store.importPickerDefaults()
    check(defaults.engine == "codex" && defaults.accountID == work.id, "The picker preselects App Support's provider and its login")
    cli.remove("codex")
    check(store.importPickerDefaults().engine == "claude" && store.importFamilies.contains("codex") && !store.providerInstalled("codex"),
          "When the lead provider's CLI is missing, the first installed assistant is preselected and the missing one is still listed")
    cli = []
    let unbound = Session(entry: Entry(name: "Imported", command: "", directory: "~", engine: ConverseExchange.unboundEngine))
    check(store.useImportProvider(unbound, engine: "claude", accountID: "claude-default")?.contains("isn’t installed") == true && unbound.isUnboundImport,
          "A provider whose CLI is missing cannot be used")
    let gone = AccountProfile(id: "gone", name: "Gone", engine: "claude", directory: root.appendingPathComponent("no-such-login").path)
    check(store.loginStoreProblem(gone)?.contains("missing") == true && store.loginStoreProblem(AccountProfile(id: "m", name: "Muse", engine: "muse", directory: "")) == nil,
          "A saved login whose folder is gone says so")

    // Import, then Use: binds, prepares the draft, sends nothing.
    guard let command = ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] else { check(false, "Import restore tests need the echo provider"); return }
    setenv("CONVERSE_SKIP_STATUS_PROBE", "1", 1)
    defer { unsetenv("CONVERSE_SKIP_STATUS_PROBE") }
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
    let source = Store(folder: root.appendingPathComponent("source"))
    let original = source.create(Entry(name: "Muse", command: command, directory: NSTemporaryDirectory(), engine: "muse"))
    original.title = "Garden plan"
    original.messages = (1...12).map { Message(role: $0 % 2 == 1 ? "user" : "assistant", text: "garden step \($0)") }
    var noted = ExportSession(original); noted.handoff = "Goals: a raised bed by spring."
    var scrubber: ExportScrubber? = nil
    guard let package = try? ConverseExchange.decode(ConverseExchange.export([noted, ExportSession(original)], content: .both, scrubber: &scrubber, includeImages: false, imageData: { _ in nil })) else {
        check(false, "Import restore export fixture"); return
    }
    let target = Store(folder: root.appendingPathComponent("target"))
    for index in target.entries.indices {
        target.entries[index].directory = NSTemporaryDirectory()
        if target.entries[index].engine == "muse" { target.entries[index].command = command }
        if target.entries[index].engine == "codex" { target.entries[index].command = fakeCodex.path }
    }
    let codexLogin = target.makeLogin(engine: "codex", name: "Garden Codex")
    try? FileManager.default.createDirectory(atPath: codexLogin.directory, withIntermediateDirectories: true)
    guard let imported = try? target.importConverse(package, sessions: Set(package.document.sessions.map(\.exportID)), lots: [], library: ParkingLotLibrary(folder: target.folder)).sessions,
          imported.count == 2, let museLogin = target.preferredLogin(engine: "muse") else { check(false, "Import restore import fixture"); return }
    let withNote = imported[0], plain = imported[1]
    withNote.draft = "My own words"; withNote.attachments = ["/tmp/kept.png"]
    let before = withNote.messages
    check(target.useImportProvider(withNote, engine: "muse", accountID: museLogin.id) == nil && withNote.entry.engine == "muse" && withNote.entry.accountID == museLogin.id,
          "Use binds the imported session to the chosen assistant and login")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    check(!withNote.busy && withNote.process == nil && withNote.messages == before && !withNote.started && withNote.pending.isEmpty, "Binding sends nothing: no turn, not busy, history unchanged")
    let note = target.handoffNoteURL(withNote).path, transcript = target.handoffTranscriptURL(withNote).path
    let generated = withNote.restoreContext ?? ""
    check(withNote.draft == generated + RestoreContext.separator + "My own words" && withNote.attachments == ["/tmp/kept.png"],
          "The catch-up block comes first; the human's draft follows the separator and attachments stay")
    check(generated.contains("Read the handoff note first: " + note) && generated.contains("Full transcript: " + transcript) && FileManager.default.fileExists(atPath: transcript)
          && generated.contains("User: garden step 3") && !generated.contains("garden step 2\n") && generated.contains("Assistant: garden step 12"),
          "With a handoff note the draft points at it, the last ten messages and the transcript")
    check(withNote.handoffPending == nil && withNote.restoringImport && !target.handoffAvailable(withNote), "The hidden first-send preface is cleared once the draft is ready")
    check(Store(folder: target.folder).sessions.first { $0.id == withNote.id }?.restoreContext == generated, "The prepared block survives relaunch")

    // Choosing again before sending replaces only the generated block.
    withNote.draft = "STALE BLOCK" + RestoreContext.separator + "My own words, edited"; withNote.restoreContext = "STALE BLOCK"
    check(target.useImportProvider(withNote, engine: "codex", accountID: codexLogin.id) == nil && withNote.entry.engine == "codex" && !withNote.busy
          && withNote.draft == generated + RestoreContext.separator + "My own words, edited" && !withNote.messages.contains { $0.text.hasPrefix("Switched from") },
          "Re-binding before sending replaces only the generated block and adds no switch notice")
    withNote.draft = "Rewritten by hand"
    _ = target.useImportProvider(withNote, engine: "codex", accountID: codexLogin.id)
    check(withNote.draft == "Rewritten by hand", "A catch-up block the human edited or deleted is left alone")

    // Return sends the draft as typed; no hidden preface rides along.
    withNote.draft = generated + RestoreContext.separator + "What next?"; withNote.attachments = []
    let typed = withNote.draft
    target.submit(withNote); wait { !withNote.busy }
    let answer = reply(withNote)
    check(withNote.messages.contains { $0.role == "user" && $0.text == typed } && answer.hasPrefix("CODEX: ") && answer.contains("Assistant: garden step 12") && answer.contains("What next?")
          && occurrences(RestoreContext.framing, in: answer) == 1 && !answer.contains("taking over this conversation") && !answer.contains("this conversation was imported"),
          "Return supplies the catch-up message to the new provider, with no hidden preface")
    check(withNote.restoreContext == nil && !withNote.restoringImport, "After the first send the conversation is an ordinary one")

    // Without a handoff note: the messages alone.
    check(target.useImportProvider(plain, engine: "muse", accountID: museLogin.id) == nil && plain.draft == (plain.restoreContext ?? "-") + "\n\n", "An empty draft gets the block and a fresh line")
    check(!plain.draft.contains("handoff note") && plain.draft.contains("The last 10 messages:") && plain.draft.contains("garden step 12"), "Without a handoff note the draft has the messages alone")
    plain.draft += "Carry on"
    target.submit(plain); wait { !plain.busy }
    check(occurrences(RestoreContext.framing, in: reply(plain)) == 1 && reply(plain).contains("Carry on") && !reply(plain).contains("this conversation was imported"), "The echo provider receives the plain catch-up message once")

    // The picker renders for an unbound import.
    let third = try? target.importConverse(package, sessions: [package.document.sessions[1].exportID], lots: [], library: ParkingLotLibrary(folder: target.folder)).sessions.first
    if let third {
        let view = NSHostingView(rootView: ImportProviderPicker(session: third).frame(width: 760))
        view.frame = NSRect(origin: .zero, size: view.fittingSize); view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("converse-import-picker.png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            print("Import picker fixture: " + url.path)
        }
        check(view.fittingSize.height > 15 && third.isUnboundImport && third.draft.isEmpty, "The inline picker renders and changes nothing on its own")
    } else { check(false, "Import picker fixture") }
}
