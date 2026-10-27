import AppKit
import Foundation

func providerSelfTests(_ check: (Bool, String) -> Void) {
    workspaceSelfTests(check)
    switchboardSelfTests(check)
    setupSelfTests(check)
    accountLoginSelfTests(check)
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
        store.chooseAccount(session, profile: AccountProfile(id: "other", name: "Other", engine: engine, directory: "/other"))
        check(session.entry == before && session.remoteID == remote && store.sessions.last?.remoteID == nil && store.sessions.last?.draft == "transfer this draft", engine + " switching accounts preserves old context and opens an independent conversation")
    }
    let museEntry = Entry(name: "Muse fixture", command: "python3 " + ProviderCommand.quote(fixture) + " muse", directory: NSTemporaryDirectory(), engine: "muse")
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
