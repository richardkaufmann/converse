import AppKit
import Foundation

func providerSelfTests(_ check: (Bool, String) -> Void) {
    accountUsageSelfTests(check)
    responseImageSelfTests(check)
    helpSelfTests(check)
    workspaceSelfTests(check)
    switchboardSelfTests(check)
    groupSwitchboardSelfTests(check)
    transcriptExportSelfTests(check)
    setupSelfTests(check)
    accountLoginSelfTests(check)
    sessionSetupSelfTests(check)
    deviceSyncSelfTests(check)
    converseGroupSelfTests(check)
    fabricRevocationReconnectTests(check)
    fabricTrustSelfTests(check)
    deviceFabricSelfTests(check)
    MainActor.assumeIsolated { agentSelfTests(check); agentConversationSelfTests(check); jollySelfTests(check) }
    // A real MSP process stops reading stdin after initialize. This pins the
    // actual connection/setting path against UI stalls, not just the writer helper.
    let pressureHost = FileManager.default.temporaryDirectory.appendingPathComponent("converse-slow-msp-" + UUID().uuidString + ".py")
    let pressureSource = """
    import json,sys,time
    for line in sys.stdin:
        message=json.loads(line)
        if 'id' not in message or message.get('method') == 'fixture/never-ack': continue
        print(json.dumps({'jsonrpc':'2.0','id':message['id'],'result':{}}),flush=True)
        if message.get('method') == 'initialize': time.sleep(0.6)
        if message.get('method') == 'fixture/block-next':
            sys.stdin.read(4096)
            print(json.dumps({'jsonrpc':'2.0','method':'fixture/blocked','params':{}}),flush=True)
            time.sleep(30)
    """
    try! pressureSource.write(to: pressureHost, atomically: true, encoding: .utf8)
    let pressureConnection = MuseConnection(sessionID: UUID().uuidString)
    var pressureReady = false, pressureFailed = false, uiHeartbeat = false, pressureReplies: [Int] = []
    pressureConnection.start(entry: Entry(name: "Backpressure fixture", command: "/usr/bin/python3 " + ProviderCommand.quote(pressureHost.path), directory: NSTemporaryDirectory(), engine: "muse")) { result in
        if case .failure = result { pressureFailed = true }
        pressureReady = true
    }
    let readyDeadline = Date().addingTimeInterval(3)
    while !pressureReady && Date() < readyDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { uiHeartbeat = true }
    let pressureStarted = ProcessInfo.processInfo.systemUptime
    pressureConnection.rpc("fixture/large", ["payload": String(repeating: "x", count: 2_000_000)]) { result in
        if case .failure = result { pressureFailed = true }; pressureReplies.append(1)
    }
    pressureConnection.changeSetting(.model(MuseModelChoice(id: "fixture-model", label: "Fixture", provider: "echo", profile: nil, efforts: []))) { result in
        if case .failure = result { pressureFailed = true }; pressureReplies.append(2)
    }
    let sendLatency = ProcessInfo.processInfo.systemUptime - pressureStarted
    let heartbeatDeadline = Date().addingTimeInterval(0.2)
    while !uiHeartbeat && Date() < heartbeatDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    check(pressureReady && sendLatency < 0.2 && uiHeartbeat && pressureReplies.isEmpty, "Muse setting requests cannot block UI callbacks while its real host is not reading stdin")
    let pressureDeadline = Date().addingTimeInterval(3)
    while pressureReplies.count < 2 && Date() < pressureDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    let questionRoot = FileManager.default.temporaryDirectory.appendingPathComponent("converse-question-" + UUID().uuidString)
    let questionStore = Store(folder: questionRoot)
    let questionSession = questionStore.create(Entry(name: "Question fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "muse"))
    questionSession.muse = pressureConnection
    let question = MuseRequest(id: "question-fixture", kind: "question", params: ["questions": [["id": "q", "question": "Ready?"]]])
    questionSession.requests = [question]
    questionStore.answerMuse(questionSession, request: question, answers: [["questionId": "q", "freeText": "Yes"]])
    let answerDeadline = Date().addingTimeInterval(2)
    while questionSession.answeringRequest && Date() < answerDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!questionSession.answeringRequest && questionSession.requests.isEmpty, "Muse RPC acknowledgement unlocks answered question controls even without a resolved event")
    questionSession.requests = [question]
    questionStore.answerMuse(questionSession, request: question, cancel: true)
    questionSession.requests = [MuseRequest(id: question.id, kind: "question", params: ["questions": [["id": "new", "question": "New question stage"]]])]
    let stageDeadline = Date().addingTimeInterval(2)
    while questionSession.answeringRequest && Date() < stageDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!questionSession.answeringRequest && questionSession.requests.count == 1, "A late question acknowledgement preserves a newer request stage")
    questionSession.muse = nil; try? FileManager.default.removeItem(at: questionRoot)
    var abandonedSettingCallbacks = 0, abandonedSettingFailed = false
    pressureConnection.rpc("fixture/never-ack", [:]) { result in
        abandonedSettingCallbacks += 1
        if case .failure = result { abandonedSettingFailed = Thread.isMainThread }
    }
    var pressureClosed = false
    pressureConnection.close { pressureClosed = true }
    let closeDeadline = Date().addingTimeInterval(2)
    while !pressureClosed && Date() < closeDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(pressureClosed && !pressureFailed && pressureReplies == [1, 2], "Background Muse writes retain complete frames, ordered setting replies and clean shutdown")
    check(abandonedSettingCallbacks == 1 && abandonedSettingFailed, "Closing a Muse connection settles unacknowledged settings once on main instead of leaving the picker stuck")
    var closedRequestFailed = false
    pressureConnection.rpc("session/setReasoningEffort", [:]) { result in if case .failure = result { closedRequestFailed = true } }
    check(closedRequestFailed, "A settings request on an already-closed Muse connection fails immediately")
    let blockedConnection = MuseConnection(sessionID: UUID().uuidString)
    var blockedReady = false, blockArmed = false, pipeBlocked = false, blockedClosed = false
    blockedConnection.event = { method, _ in if method == "fixture/blocked" { pipeBlocked = true } }
    blockedConnection.start(entry: Entry(name: "Blocked shutdown fixture", command: "/usr/bin/python3 " + ProviderCommand.quote(pressureHost.path), directory: NSTemporaryDirectory(), engine: "muse")) { _ in blockedReady = true }
    let blockedDeadline = Date().addingTimeInterval(3)
    while !blockedReady && Date() < blockedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    blockedConnection.rpc("fixture/block-next", [:]) { _ in blockArmed = true }
    while !blockArmed && Date() < blockedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    blockedConnection.rpc("fixture/large", ["payload": String(repeating: "x", count: 2_000_000)])
    while !pipeBlocked && Date() < blockedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    blockedConnection.close { blockedClosed = true }
    let blockedCloseDeadline = Date().addingTimeInterval(2)
    while !blockedClosed && Date() < blockedCloseDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    // Drain the writer's failure callback after the child exits.
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    try? FileManager.default.removeItem(at: pressureHost)
    check(pipeBlocked && blockedClosed, "Closing a real host during a proven blocked write survives EPIPE and completes without freezing or crashing")
    let hangingEntry = Entry(name: "Ignoring timeout fixture", command: "/usr/bin/python3 -c 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)'", directory: NSTemporaryDirectory(), engine: "muse")
    var timeoutCompleted = false, timeoutFailed = false, timeoutHeartbeat = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { timeoutHeartbeat = true }
    DispatchQueue.global().async {
        do { _ = try MuseStatusProbe.query(entry: hangingEntry, sessionID: UUID().uuidString, timeoutInterval: 0.5, terminationGrace: 0.2) }
        catch { DispatchQueue.main.async { timeoutFailed = true } }
        DispatchQueue.main.async { timeoutCompleted = true }
    }
    let timeoutDeadline = Date().addingTimeInterval(3)
    while !timeoutCompleted && Date() < timeoutDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(timeoutCompleted && timeoutFailed && timeoutHeartbeat, "A Muse settings host that ignores termination is bounded without stalling the UI")
    let vanishedEntry = Entry(name: "Closed pipe fixture", command: "/usr/bin/python3 -c 'import json,os,sys,time; m=json.loads(sys.stdin.readline()); os.close(0); print(json.dumps(dict(jsonrpc=\"2.0\",id=m[\"id\"],result={})),flush=True); time.sleep(30)'", directory: NSTemporaryDirectory(), engine: "muse")
    var vanishedCompleted = false, vanishedFailed = false
    DispatchQueue.global().async {
        do { _ = try MuseStatusProbe.query(entry: vanishedEntry, sessionID: UUID().uuidString, timeoutInterval: 0.5, terminationGrace: 0.2) }
        catch { DispatchQueue.main.async { vanishedFailed = true } }
        DispatchQueue.main.async { vanishedCompleted = true }
    }
    let vanishedDeadline = Date().addingTimeInterval(3)
    while !vanishedCompleted && Date() < vanishedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(vanishedCompleted && vanishedFailed, "A temporary Muse settings host closing stdin fails safely without a process-wide broken-pipe crash")
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
        let promotedID = session.pending.first?.id
        check(session.injectionNotice == "Interrupting — your queued prompt is next" && session.interrupted, engine + " injection gives immediate feedback before the old process exits")
        store.injectPending(session, id: promotedID)
        check(session.pending.first?.id == promotedID && session.pending.count == 2 && session.resumeAfterInterrupt, engine + " repeated injection while stopping keeps the original intent and queue order")
        pump { !session.busy && session.pending.isEmpty }
        check(session.messages.filter { $0.role == "assistant" }.suffix(2).map(\.text) == ["answer: second", "answer: first"] && session.draft == "untouched", engine + " Inject now promotes selected row, interrupts, and preserves draft")
        check(session.injectionNotice == "Injected prompt started." && session.injectionTargetID == nil, engine + " injection confirms the promoted prompt actually started")
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
    let lifecycleFolder = store.folder.appendingPathComponent("msp-lifecycle")
    let lifecycleScript = FileManager.default.currentDirectoryPath + "/Tests/msp_lifecycle_fixture.py"
    let lifecycleEntry = Entry(name: "Muse lifecycle", command: "python3 " + ProviderCommand.quote(lifecycleScript) + " " + ProviderCommand.quote(lifecycleFolder.path), directory: NSTemporaryDirectory(), engine: "muse")
    let lifecycle = store.create(lifecycleEntry)
    lifecycle.draft = "first"; store.submit(lifecycle)
    lifecycle.draft = "second"; store.submit(lifecycle)
    lifecycle.draft = "newer draft"
    pump { !lifecycle.busy && lifecycle.pending.isEmpty }
    let submittedFile = lifecycleFolder.appendingPathComponent("submitted.jsonl")
    let submissions = (try? String(contentsOf: submittedFile, encoding: .utf8)) ?? ""
    check(lifecycle.status == "Ready" && lifecycle.messages.filter { $0.role == "assistant" }.map(\.text) == ["answer: first", "answer: second"] && submissions.split(separator: "\n").count == 2 && lifecycle.draft == "newer draft", "Muse queue waits for delayed host exit and releases its real session lock before the next turn")
    let lock = lifecycleFolder.appendingPathComponent("session.lock")
    try! FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
    let retainedID = lifecycle.remoteID
    lifecycle.draft = "blocked input"; store.submit(lifecycle)
    lifecycle.draft = "keep typing"; lifecycle.attachments = ["new-attachment.png"]
    pump { !lifecycle.busy }
    check(lifecycle.queuePaused && lifecycle.pending.map(\.text) == ["blocked input"] && lifecycle.status == "Session in use · input held" && lifecycle.remoteID == retainedID && lifecycle.draft == "keep typing" && lifecycle.attachments == ["new-attachment.png"], "Muse lock conflict holds unsubmitted input in a paused queue without replacing identity or newer typing")
    check(!lifecycle.messages.contains { $0.role == "user" && $0.text == "blocked input" } && ((try? String(contentsOf: submittedFile, encoding: .utf8)) ?? "") == submissions, "Rejected Muse session-open never submits a turn or leaves a duplicate user message")
    try! FileManager.default.removeItem(at: lock)
    store.injectPending(lifecycle, id: lifecycle.pending.first?.id)
    pump { !lifecycle.busy && lifecycle.pending.isEmpty }
    check(lifecycle.messages.filter { $0.role == "user" && $0.text == "blocked input" }.count == 1 && lifecycle.messages.filter { $0.text == "answer: blocked input" }.count == 1 && lifecycle.draft == "keep typing" && lifecycle.attachments == ["new-attachment.png"], "Inject after a Muse lock clears delivers held input exactly once and preserves the draft")
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
