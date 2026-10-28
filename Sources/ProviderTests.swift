import AppKit
import Foundation

func providerSelfTests(_ check: (Bool, String) -> Void) {
    responseImageSelfTests(check)
    helpSelfTests(check)
    workspaceSelfTests(check)
    switchboardSelfTests(check)
    transcriptExportSelfTests(check)
    setupSelfTests(check)
    accountLoginSelfTests(check)
    sessionSetupSelfTests(check)
    deviceSyncSelfTests(check)
    converseGroupSelfTests(check)
    fabricRevocationReconnectTests(check)
    fabricTrustSelfTests(check)
    deviceFabricSelfTests(check)
    MainActor.assumeIsolated { agentSelfTests(check) }
    let store = Store.shared
    let fixture = FileManager.default.currentDirectoryPath + "/Tests/provider_fixture.py"
    func pump(_ done: () -> Bool, seconds: Double = 8) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    for engine in ["codex", "claude"] {
        let accountDir = store.folder.appendingPathComponent("fixture-" + engine + "-account").standardizedFileURL.path
        try! FileManager.default.createDirectory(atPath: accountDir, withIntermediateDirectories: true)
        let entry = Entry(name: "Fixture", command: "python3 " + ProviderCommand.quote(fixture) + " " + engine, directory: NSTemporaryDirectory(), engine: engine, accountID: "fixture", accountName: "Fixture", accountDirectory: accountDir)
        do {
            let probe = try ProviderStatus.query(entry: entry, remoteID: engine == "codex" ? "fixture-thread" : nil)
            check(probe.models.count == 2 && !probe.models[0].efforts.isEmpty && probe.account == accountDir, engine + " prompt-free catalog and account isolation")
            check(probe.status.model == (engine == "codex" ? "fixture-sol" : "fixture-opus") && !probe.access.isEmpty, engine + " resolved model and permission discovery")
            if engine == "codex" { check(probe.status.effort == "high", "Codex retained effort wins over config default") }
        } catch { check(false, engine + " catalog failed: " + error.localizedDescription) }
        let session = store.create(entry)
        session.choices = SessionChoices(model: engine == "codex" ? "fixture-sol" : "sonnet", effort: "high", access: engine == "codex" ? "read-only" : "manual")
        session.draft = "slow"; store.submit(session)
        pump { session.messages.contains { $0.text == "partial" } }
        check(session.busy && session.remoteID == "fixture-thread", engine + " running turn retains exact remote identity")
        session.draft = "queued"; store.submit(session)
        check(session.pending.count == 1 && session.draft.isEmpty && session.busy, engine + " Return queues without interrupting")
        session.draft = "urgent"; store.submit(session, interrupt: true)
        session.draft = "keep draft"
        pump { !session.busy && session.pending.isEmpty }
        let answers = session.messages.filter { $0.role == "assistant" }.map(\.text)
        check(answers == ["partial", "answer: urgent", "answer: queued"] && session.draft == "keep draft", engine + " interruption waits for exit, resumes exact session, drains in order and preserves edited draft")
        session.draft = "slow"; store.submit(session)
        pump { session.messages.last?.text == "partial" }
        session.pending = [PendingPrompt(text: "first", images: []), PendingPrompt(text: "second", images: [])]
        session.draft = "untouched"
        store.injectPending(session, id: session.pending[1].id)
        pump { !session.busy && session.pending.isEmpty }
        check(session.messages.filter { $0.role == "assistant" }.suffix(2).map(\.text) == ["answer: second", "answer: first"] && session.draft == "untouched", engine + " Inject now promotes selected row, interrupts, and preserves draft")
        session.pending = [PendingPrompt(text: "one", images: []), PendingPrompt(text: "two", images: [])]
        session.queuePaused = true
        store.injectPending(session)
        pump { !session.busy && session.pending.isEmpty }
        check(session.messages.last?.text == "answer: one\n\ntwo" && session.draft == "untouched", engine + " Inject all resumes paused queue as one ordered turn without changing draft")
        session.switchboardEnabled = true
        session.draft = "switchboard-output:```converse\n{\"command\":\"list-sessions\"}\n```"
        store.submit(session)
        pump { !session.busy && session.pending.isEmpty }
        check(session.messages.contains { $0.role == "user" && $0.text.hasPrefix("[Converse switchboard directory") && $0.text.contains(session.id.uuidString) }, engine + " completed directory command automatically returns live IDs through the provider")
        if engine == "codex" {
            let command = "```converse\n{\"command\":\"list-sessions\"}\n```"
            session.queuePaused = true
            session.draft = "switchboard-progress:" + command; store.submit(session)
            pump { !session.busy }
            check(session.pending.count == 1 && session.pending.first?.text.hasPrefix("[Converse switchboard directory") == true && session.messages.contains { $0.finalReply == command && $0.text.contains("I will inspect") }, "Codex progress remains visible while its separate final reply dispatches exactly once")
            let captured = Session(try! JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(session.saved)))
            check(captured.messages.contains { $0.finalReply == command }, "Codex authoritative final reply survives archive persistence")
            session.pending = []
            session.draft = "switchboard-file-only:" + command; store.submit(session)
            pump { !session.busy }
            check(session.pending.count == 1 && session.messages.contains { $0.finalReply == command && $0.text == command }, "Codex final-answer file without a JSONL text event remains visible and dispatches")
            session.pending = []
            session.draft = "switchboard-commentary-only:" + command; store.submit(session)
            pump { !session.busy }
            check(session.pending.isEmpty, "Codex command in commentary cannot execute when final answer is ordinary prose")
            session.draft = "switchboard-output:Example:\n" + command; store.submit(session)
            pump { !session.busy }
            check(session.pending.isEmpty, "Codex quoted final-answer command remains non-executable")
            session.draft = "switchboard-missing-final:" + command; store.submit(session)
            pump { !session.busy }
            check(session.pending.isEmpty && session.messages.contains { $0.role == "notice" && $0.text.contains("final-answer capture was unavailable") }, "Missing Codex final-answer capture fails closed with a visible delivery notice")
            session.queuePaused = false
        }
        let peer = store.create(entry); peer.choices = session.choices
        peer.draft = "slow"; store.submit(peer)
        pump { peer.messages.last?.text == "partial" }
        peer.draft = "preserve peer draft"
        let request = ["command": "tell-urgently", "to": peer.id.uuidString, "text": "review now"]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        session.draft = "switchboard-output:```converse\n" + json + "\n```"; store.submit(session)
        pump { !session.busy && !peer.busy && peer.pending.isEmpty }
        check(peer.messages.contains { $0.role == "assistant" && $0.text.hasSuffix("review now") } && peer.remoteID == "fixture-thread" && peer.draft == "preserve peer draft", engine + " switchboard urgent delivery interrupts running peer and resumes exact conversation without touching draft")
        session.switchboardEnabled = false
        session.draft = "slow"; store.submit(session)
        pump { session.messages.last?.text == "partial" }
        session.draft = "held"; store.submit(session); store.stop(session)
        pump { !session.busy }
        check(session.queuePaused && session.pending.first?.text == "held", engine + " Stop holds queued input")
        let encoded = try! JSONEncoder().encode(session.saved)
        let loaded = Session(try! JSONDecoder().decode(SavedSession.self, from: encoded))
        check(loaded.pending.count == 1 && loaded.queuePaused && loaded.entry.accountDirectory == accountDir && loaded.choices.effort == "high", engine + " account, settings and paused queue survive relaunch")
        store.restorePending(session, id: session.pending[0].id)
        check(session.draft == "held" && session.pending.isEmpty, engine + " queued input can be recovered for editing")
        session.draft = "fail"; store.submit(session)
        session.draft = "must not run"; store.submit(session)
        pump { !session.busy }
        check(session.queuePaused && session.pending.count == 1 && !session.messages.contains { $0.text == "answer: must not run" }, engine + " failure pauses queue without losing input")
        let signedOut = store.create(entry); signedOut.choices = session.choices
        signedOut.draft = "login-required"; store.submit(signedOut)
        pump { !signedOut.busy }
        check(signedOut.needsSignIn && signedOut.status.hasPrefix("Failed"), engine + " authentication failure exposes sign-in recovery instead of requiring headless slash login")
        store.changeSetting(session, .model(MuseModelChoice(id: "fixture-small", label: "Small", provider: engine, profile: nil, efforts: ["low"])))
        check(session.choices.effort == "low" && session.availableEfforts.isEmpty, engine + " changing models replaces an unsupported saved effort")
        let before = session.entry
        session.busy = true
        store.chooseAccount(session, profile: AccountProfile(id: "other", name: "Other", engine: engine, directory: "/other"))
        check(session.entry == before, engine + " active conversation cannot change account")
        session.busy = false
        session.draft = "transfer this draft"
        let remote = session.remoteID
        let countBeforeBinding = store.sessions.count
        let alternateDirectory = store.folder.appendingPathComponent("Other/fixture-" + engine + "-account").path
        store.chooseAccount(session, profile: AccountProfile(id: "other", name: "Other", engine: engine, directory: alternateDirectory))
        check(session.entry.accountID == "other" && session.remoteID == remote && session.draft == "transfer this draft" && store.sessions.count == countBeforeBinding, engine + " login is rebound on the same session without losing context or creating another conversation")
        let bound = session.entry
        let changedFolder = store.folder.appendingPathComponent(engine + " changed working folder")
        try! FileManager.default.createDirectory(at: changedFolder, withIntermediateDirectories: true)
        session.draft = "preserved draft"; session.attachments = ["preserved.png"]
        let messageCount = session.messages.count
        try! store.configure(session, title: "Renamed now", command: session.entry.command, directory: changedFolder.path)
        check(session.title == "Renamed now" && session.entry.directory == changedFolder.path && session.remoteID == remote && session.entry.accountID == bound.accountID && session.messages.count == messageCount && session.draft == "preserved draft" && session.attachments == ["preserved.png"], engine + " session settings save immediately without changing history, login, context or unsent input")
        session.pending = []; session.attachments = []
        session.choices = SessionChoices(model: engine == "codex" ? "fixture-sol" : "sonnet", effort: "high", access: engine == "codex" ? "read-only" : "manual")
        session.draft = "working-directory"; store.submit(session)
        pump { !session.busy }
        let actualFolder = session.messages.last(where: { $0.role == "assistant" })?.text ?? ""
        let actualIdentity = try? FileManager.default.attributesOfItem(atPath: actualFolder)
        let expectedIdentity = try! FileManager.default.attributesOfItem(atPath: changedFolder.path)
        check(actualIdentity?[.systemFileNumber] as? NSNumber == expectedIdentity[.systemFileNumber] as? NSNumber && actualIdentity?[.systemNumber] as? NSNumber == expectedIdentity[.systemNumber] as? NSNumber && session.remoteID == remote, engine + " next resumed turn runs in the changed working folder")
        let saved = Session(try! JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(session.saved)))
        check(saved.title == "Renamed now" && saved.entry.directory == changedFolder.path && saved.remoteID == remote, engine + " renamed title and working folder survive relaunch")
        do { try store.configure(session, title: "Invalid", command: session.entry.command, directory: changedFolder.appendingPathComponent("missing").path); check(false, engine + " rejects missing working folders") }
        catch { check(session.title == "Renamed now" && session.entry.directory == changedFolder.path, engine + " rejects missing working folders without partially changing title or directory") }

    }
    let museEntry = Entry(name: "Muse fixture", command: "python3 " + ProviderCommand.quote(fixture) + " muse", directory: NSTemporaryDirectory(), engine: "muse")
    let resumed = MuseConnection(sessionID: UUID().uuidString)
    var resumedResult: Result<[String: Any], Error>?
    resumed.start(entry: museEntry) { result in
        if case .failure = result { resumedResult = result; return }
        resumed.load(entry: museEntry, choices: SessionChoices(model: "retired-model")) { resumedResult = $0 }
    }
    pump { resumedResult != nil }
    if case .success? = resumedResult { check(resumed.settingWarning?.contains("Continuing with the session's current model") == true, "Rejected saved Muse model does not turn successful resume into session-open failure") }
    else { check(false, "Rejected saved Muse model does not turn successful resume into session-open failure") }
    resumed.close()
    let muse = store.create(museEntry)
    var reply = UUID(); muse.busy = true; muse.messages = [Message(id: reply, role: "assistant", text: "")]
    store.sendMuse(muse, prompt: "slow", display: "slow", images: [], responseID: reply)
    pump { muse.messages.last?.text == "partial" }
    let museRemote = muse.remoteID
    store.stop(muse); pump { !muse.busy }
    check(!muse.busy && muse.status == "Cancelled" && museRemote != nil, "Muse uses native turn/interrupt and authoritative completion")
    reply = UUID(); muse.busy = true; muse.messages.append(Message(id: reply, role: "assistant", text: ""))
    store.sendMuse(muse, prompt: "after interrupt", display: "after interrupt", images: [], responseID: reply)
    pump { !muse.busy }
    check(muse.remoteID == museRemote && muse.messages.last?.text == "answer: after interrupt", "Muse resumes its retained session after interruption")
    let previousMuseTransport = store.usesInteractiveMuse
    store.usesInteractiveMuse = true
    for mode in ["muse-stuck", "muse-no-ack", "muse-rejected-interrupt"] {
        var entry = museEntry
        entry.command = "python3 " + ProviderCommand.quote(fixture) + " " + mode
        let stuck = store.create(entry)
        stuck.draft = "slow"; store.submit(stuck)
        pump { stuck.messages.last?.text == "partial" }
        guard let old = stuck.muse, stuck.messages.last?.text == "partial" else {
            check(false, mode + " starts the interactive fixture: " + stuck.status)
            continue
        }
        let remote = stuck.remoteID
        old.interruptionGrace = 0.15; old.terminationGrace = 0.15
        stuck.pending = [PendingPrompt(text: "replacement", images: [])]
        stuck.draft = "keep newer typing"
        store.stop(stuck)
        store.injectPending(stuck, id: stuck.pending[0].id)
        pump { !stuck.busy && stuck.pending.isEmpty }
        check(!old.process.isRunning && !stuck.busy && stuck.pending.isEmpty && stuck.remoteID == remote && stuck.messages.last(where: { $0.role == "assistant" })?.text == "answer: replacement" && stuck.draft == "keep newer typing", mode + " Stop then Inject recovers after host exit with exact session and draft")
        let count = stuck.messages.filter { $0.role == "user" && $0.text == "replacement" }.count
        check(count == 1 && stuck.messages.contains { $0.role == "notice" && $0.text.contains("local host") }, mode + " recovery submits once and explains forced host stop")
    }
    store.usesInteractiveMuse = previousMuseTransport
    muse.switchboardEnabled = true; muse.queuePaused = true
    muse.switchboardTurnStart = muse.messages.count
    reply = UUID(); muse.busy = true; muse.messages.append(Message(id: reply, role: "assistant", text: ""))
    store.sendMuse(muse, prompt: "switchboard-output:```converse\n{\"command\":\"list-sessions\"}\n```", display: "directory", images: [], responseID: reply)
    pump { !muse.busy }
    check(muse.pending.first?.text.hasPrefix("[Converse switchboard directory") == true && muse.pending.first?.text.contains(muse.id.uuidString) == true, "Muse native successful completion dispatches switchboard commands")
    muse.pending = []; muse.switchboardEnabled = false
    let keys = ConversationTextView(frame: .zero)
    var submitted = false
    keys.submit = { submitted = true }
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    keys.keyDown(with: escape)
    check(!submitted, "Escape never submits queued or draft input")
    let legacy = #"{"entries":[],"sessions":[]}"#.data(using: .utf8)!
    let archive = try! JSONDecoder().decode(Archive.self, from: legacy)
    check(archive.accounts == nil, "Archives predating account support remain readable")
    let q = ProviderCommand.script(entry: Entry(name: "Test", command: "codex", directory: "~", engine: "codex", accountDirectory: "/tmp/path ' $(literal)"), arguments: ["--", "$(literal)"])
    check(q.contains("export CODEX_HOME='/tmp/path '\\'' $(literal)'") && q.contains("'$(literal)'"), "Account paths and prompts are shell quoted without expansion")
}
