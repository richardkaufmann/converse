import AppKit

@MainActor func agentConversationSelfTests(_ check: (Bool, String) -> Void) {
    var silence = VoiceEndpointDetector()
    var decision = VoiceEndpointDetector.Decision.keepListening
    for n in 1...200 { decision = silence.sample(power: -80, at: Double(n) / 10) }
    check(decision == .noSpeech, "Hands-free initial silence times out without becoming an uploaded question")
    var click = VoiceEndpointDetector()
    _ = click.sample(power: -10, at: 0.1)
    check(click.sample(power: -80, at: 20) == .noSpeech, "A brief microphone spike cannot trigger a hands-free query")
    var clicks = VoiceEndpointDetector()
    for n in 1...199 { _ = clicks.sample(power: n % 4 == 0 ? -10 : -80, at: Double(n) / 10) }
    check(clicks.sample(power: -80, at: 20) == .noSpeech, "Separated keyboard clicks never accumulate into sustained speech")
    var shortWord = VoiceEndpointDetector()
    _ = shortWord.sample(power: -25, at: 0.1); _ = shortWord.sample(power: -25, at: 0.2)
    check(shortWord.sample(power: -80, at: 1.8) == .send, "A short spoken answer can finish without requiring a long sentence")
    var speaking = VoiceEndpointDetector()
    for n in 1...5 { _ = speaking.sample(power: -25, at: Double(n) / 10) }
    check(speaking.sample(power: -80, at: 1.7) == .keepListening && speaking.sample(power: -80, at: 2.1) == .send, "Sustained speech ends after 1.5 seconds of quiet, not a shorter thinking pause")
    var continuous = VoiceEndpointDetector()
    for n in 1...594 { _ = continuous.sample(power: -25, at: Double(n) / 10) }
    check(continuous.sample(power: -25, at: 59.6) == .send, "Hands-free recording has a hard one-minute boundary even with continuous sound")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-talk-" + UUID().uuidString)
    let store = Store(folder: root)
    let session = store.createAgent(); session.draft = "keep typed draft"; session.attachments = ["keep-image"]
    let talk = AgentConversation.shared
    var listens = 0, starts = 0, speeches: [String] = [], completion: ((Bool) -> Void)?
    var draftAtStart = false
    talk.startRecording = { listens += 1 }
    talk.speakReply = { text, _, done in speeches.append(text); completion = done }
    talk.stopPlayback = {}; talk.resumeDelay = 0
    store.startAgentRun = { s, _ in
        starts += 1; try! store.saveChecked()
        let saved = Store(folder: root).sessions.first { $0.id == s.id }
        draftAtStart = saved?.draft == "keep typed draft" && saved?.attachments == ["keep-image"]
    }
    defer {
        talk.stop(); talk.startRecording = nil; talk.speakReply = nil; talk.stopPlayback = nil; talk.resumeDelay = 500_000_000
        try? FileManager.default.removeItem(at: root)
    }
    func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
    talk.start(session, store: store)
    check(talk.phase == .listening && listens == 1, "Start talking opens exactly one listening turn without submitting anything")
    session.agent?.enabled = true; session.agent?.nextRunAt = .distantPast
    let allowance = session.agent?.turnLimit
    AgentRuntime().tick(store: store)
    check(starts == 0 && session.agent?.turnLimit == allowance, "Automatic agent loops hold their budget while a voice conversation owns the session")
    talk.transcribed("How is the project?")
    let responseID = session.messages.last!.id
    check(talk.phase == .thinking && starts == 1 && listens == 1 && draftAtStart && session.draft == "keep typed draft", "Recognized voice sends one human turn with the microphone off and preserves persisted typing and images")
    talk.transcribed("duplicate")
    talk.completed(session, responseID: UUID(), text: "wrong turn", intent: "calm", success: true)
    check(starts == 1 && speeches.isEmpty, "Duplicate transcription and unrelated agent replies cannot advance a voice conversation")
    session.busy = false
    talk.completed(session, responseID: responseID, text: "**All good.**\nSources: https://example.test", intent: "calm", success: true)
    check(talk.phase == .speaking && speeches == ["All good."] && listens == 1, "The agent speaks only its correlated reply and never records its own playback")
    completion?(true); drain()
    check(talk.phase == .listening && listens == 2, "Successful speech completion automatically opens the next listening turn")

    talk.transcribed("Next question")
    let secondID = session.messages.last!.id; session.busy = false
    talk.completed(session, responseID: secondID, text: "Second reply", intent: "calm", success: true)
    let lateSpeech = completion
    talk.stop(); lateSpeech?(true); drain()
    check(!talk.active && listens == 2, "Stop fences late speech callbacks so the microphone cannot reopen")
    talk.start(session, store: store); talk.transcribed("Another question")
    let stoppedID = session.messages.last!.id
    talk.stop(); session.busy = false
    talk.completed(session, responseID: stoppedID, text: "Late model reply", intent: "calm", success: true)
    check(speeches.count == 2 && !talk.active, "Stopping while thinking leaves the sent turn intact but prevents later speech or listening")

    talk.start(session, store: store); session.busy = true
    talk.transcribed("Preserve these words")
    check(!talk.active && session.draft == "keep typed draft Preserve these words" && starts == 3, "If another turn wins, voice words stay in the draft rather than interrupting or disappearing")
    session.busy = false; session.draft = "keep typed draft"
    talk.start(session, store: store)
    session.pending = [PendingPrompt(text: "queued fixture", images: [])]
    store.runNext(session)
    check(starts == 3 && session.pending.count == 1, "Queued switchboard work waits instead of stealing a listening agent")
    talk.stop(resumeQueued: false); drain()
    check(session.pending.count == 1 && starts == 3, "Quitting voice mode during app shutdown preserves queued work without starting a new turn")
    session.pending = []
    talk.start(session, store: store)
    talk.audio.onFailure?("Synthetic transcription failure")
    check(!talk.active && talk.detail == "Synthetic transcription failure", "Transcription failure visibly ends hands-free mode with no retry loop")

    let runtime = AgentRuntime()
    runtime.keyReader = { _ in "synthetic-test-key" }
    var spokenInstructions = false
    runtime.api.request = { request in
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        spokenInstructions = (body["instructions"] as? String)?.contains("This is a spoken conversation.") == true
        let reply = "{\"reply\":\"Hello from the fixture.\",\"attention\":\"\",\"tell\":[]}"
        let data = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": reply]]]]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    session.agent?.generateArt = false; session.agent?.webSearch = false; session.agent?.enabled = false
    store.startAgentRun = { s, id in runtime.run(s, store: store, responseID: id) }
    // Old saved speech preferences must not authorize autonomous or typed playback.
    session.agent?.speak = true
    talk.stop(resumeQueued: false)
    let priorSpeechCount = speeches.count
    // Earlier lifecycle tests intentionally use a nonexistent draft attachment;
    // this model-backed turn must not submit that synthetic path as an image.
    session.attachments = []
    session.draft = "An ordinary typed question"
    store.send(session)
    let silentDeadline = Date().addingTimeInterval(4)
    while session.busy && Date() < silentDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!session.busy && speeches.count == priorSpeechCount && !talk.active,
          "A legacy speak setting cannot make an ordinary agent response start talking")
    talk.start(session, store: store); talk.transcribed("Say hello")
    let deadline = Date().addingTimeInterval(4)
    while talk.phase == .thinking && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(spokenInstructions && talk.phase == .speaking && speeches.last == "Hello from the fixture." && !session.busy,
          "Real agent runtime carries a voice question through model parsing and completion into correlated speech")
    let workspace = Workspace(); let window = UUID(); workspace.register(window)
    workspace.assign(session.id, to: window, pane: 1)
    workspace.park(session.id)
    check(!talk.active, "Parking immediately stops explicit voice playback")
    talk.start(session, store: store)
    store.stop(session)
    check(!talk.active, "Stop ends explicit voice input even while the agent is idle")
}
