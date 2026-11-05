import AppKit
import Foundation

@MainActor func agentSelfTests(_ check: (Bool, String) -> Void) {
    do {
        var art = AgentConfig(); art.artDirection = "Ink illustration of determined explorers"; art.lastArtDirection = art.artDirection
        let restored = try JSONDecoder().decode(AgentConfig.self, from: JSONEncoder().encode(art))
        check(restored.artDirection == art.artDirection && restored.lastArtDirection == art.lastArtDirection, "Art direction and rendered direction survive archive reload")
        var wire = art.wire(home: String(repeating: "a", count: 64)); wire.artDirection = "Playful moonbase, purple palette"
        try art.apply(wire)
        check(art.artDirection == wire.artDirection && art.lastArtDirection != art.artDirection, "Remote art direction edit leaves a pending refresh even when mood stays unchanged")
        var old = art.wire(home: String(repeating: "a", count: 64)); old.artDirection = nil; try art.apply(old)
        check(art.artDirection == wire.artDirection, "Older editors preserve an existing art direction")
        check(AgentArt.prompt(direction: art.artDirection!, scene: String(repeating: "x", count: 5000), mood: "peaceful").contains(art.artDirection!), "Owner art direction reaches image prompt even with a long generated scene")
        var oversized = art.wire(home: String(repeating: "a", count: 64)); oversized.artDirection = String(repeating: "x", count: 4001)
        do { try art.apply(oversized); check(false, "Art direction size limit") } catch { check(true, "Art direction size limit rejects before settings mutation") }
    } catch { check(false, "Art direction regression: " + error.localizedDescription) }
    imageAssistSelfTests(check)
    photoShareSelfTests(check)
    agentScheduleSelfTests(check)
    agentPaceSelfTests(check)
    agentRetrySelfTests(check)
    agentObjectivePacingSelfTests(check)
    configurationAuditSelfTests(check)
    agentDiscordSelfTests(check)
    agentDiscordRouterSelfTests(check)
    agentHomeAssistantSelfTests(check)
    let voice = AgentDictation()
    voice.keyReader = { "synthetic-key" }
    voice.permission = { false }
    voice.record()
    let permissionDeadline = Date().addingTimeInterval(2)
    while voice.phase == .permission && Date() < permissionDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(voice.phase == .failed && voice.status.contains("Microphone"), "Denied microphone permission leaves a visible recoverable state without a modal session")
    var permissionReply: CheckedContinuation<Bool, Never>?
    voice.permission = { await withCheckedContinuation { permissionReply = $0 } }
    voice.record()
    let cancelDeadline = Date().addingTimeInterval(2)
    while permissionReply == nil && Date() < cancelDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    voice.cancel(); permissionReply?.resume(returning: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    check(voice.phase == .idle && !voice.active && voice.status.contains("Ready"), "Cancelling Dictate fences a late permission approval instead of starting the microphone")
    check(AgentDictation.inserting("new words", into: "typed meanwhile") == "typed meanwhile new words", "Dictation inserts into the current draft without erasing newer typing")
    var wav = Data("RIFF".utf8); wav.append(Data(repeating: 0, count: 4)); wav.append(Data("WAVE".utf8)); wav.append(Data(repeating: 0, count: 40))
    var voiceRequest: URLRequest?, voiceText: String?, voiceError: String?, voiceDone = false
    voice.api.request = { request in
        voiceRequest = request
        return (Data("{\"transcript\":\" synthetic voice test \"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    Task { @MainActor in
        do { voiceText = try await voice.api.transcribe(wav, key: "synthetic-key") } catch { voiceError = error.localizedDescription }; voiceDone = true
    }
    let voiceDeadline = Date().addingTimeInterval(2)
    while !voiceDone && Date() < voiceDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    let multipart = voiceRequest?.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    check(voiceText == "synthetic voice test" && voiceError == nil && voiceRequest?.url?.path == "/v1/asr/transcribe" && multipart.contains("PUSH_TO_TALK") && multipart.contains("name=\"audio\"") && multipart.contains("WAVE"), "Dictation uses the documented multipart Meta Voice API and extracts the review text")
    voiceDone = false
    voice.api.request = { request in
        (Data("private-error-canary".utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
    }
    Task { @MainActor in
        do { _ = try await voice.api.transcribe(wav, key: "synthetic-key") } catch { voiceError = error.localizedDescription }; voiceDone = true
    }
    let failureDeadline = Date().addingTimeInterval(2)
    while !voiceDone && Date() < failureDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(voiceError?.contains("401") == true && voiceError?.contains("private-error-canary") == false, "Voice API failures expose an actionable status without raw response bodies")
    do {
        var first = AgentActivationBudget(limit: 2)
        try first.consume(); try first.consume()
        do { try first.consume(); check(false, "Activation cap enforced") }
        catch { check(first.used == 2, "One activation cannot exceed its model-turn cap") }
        var next = AgentActivationBudget(limit: 2); try next.consume()
        check(next.used == 1, "Next activation receives a fresh turn budget")
        var legacy = AgentConfig(); legacy.remainingRuns = 0
        check(legacy.turnLimit == 1 && !legacy.enabled, "Exhausted legacy archives migrate to a usable cap without silently enabling the loop")
    } catch { check(false, "Activation budget fixture: " + error.localizedDescription) }
    let now = Date(timeIntervalSince1970: 1_000)
    var config = AgentConfig(); config.enabled = true; config.turnLimit = 1; config.nextRunAt = now
    check(config.reserveRun(at: now) && config.turnLimit == 1 && config.enabled && !config.reserveRun(at: now), "Agent reserves a due loop once without exhausting future scheduled loops")
    do {
        var daily = AgentConfig(); daily.enabled = true; daily.intervalSeconds = 86400
        daily.nextRunAt = now
        check(daily.reserveRun(at: now), "Daily loop records its first check")
        var restored = try JSONDecoder().decode(AgentConfig.self, from: JSONEncoder().encode(daily))
        try restored.restoreSchedule(at: now.addingTimeInterval(3600))
        check(restored.nextRunAt == now.addingTimeInterval(86400) && !restored.due(at: now.addingTimeInterval(3600)), "Restart an hour after a check preserves the remaining 23 hours")
        let overdue = now.addingTimeInterval(3 * 86400)
        try restored.restoreSchedule(at: overdue)
        check(restored.reserveRun(at: overdue) && !restored.reserveRun(at: overdue) && restored.nextRunAt == overdue.addingTimeInterval(86400), "Several offline days produce one catch-up check and the next check a day later")
        restored.nextRunAt = nil
        try restored.restoreSchedule(at: overdue.addingTimeInterval(3600))
        check(restored.nextRunAt == overdue.addingTimeInterval(86400), "Missing deadline reconstructs from persisted last loop instead of restart time")
        var edit = restored.wire(home: "local"); edit.objective = "Updated objective"
        try restored.apply(edit)
        check(restored.nextRunAt == overdue.addingTimeInterval(86400), "Unrelated agent settings save preserves the deadline")
        restored.enabled = false; restored.nextRunAt = nil
        try restored.restoreSchedule(at: overdue)
        check(!restored.due(at: overdue) && restored.nextRunAt == nil, "Restart never re-enables a paused loop")
        var fresh = AgentConfig(); fresh.enabled = true; fresh.intervalSeconds = 86400
        try fresh.restoreSchedule(at: now)
        check(fresh.nextRunAt == now.addingTimeInterval(86400), "Never-run loop without saved history waits its first interval")
    } catch { check(false, "Restart cadence fixture: " + error.localizedDescription) }
    do {
        let instant = ISO8601DateFormatter().date(from: "2026-11-27T17:50:00Z")!
        var scheduled = AgentConfig(); scheduled.enabled = true; scheduled.turnLimit = 3
        scheduled.scheduleText = "every 20 minutes while the us stock market is open"; scheduled.scheduleTimeZone = "America/New_York"; scheduled.nextRunAt = instant
        check(scheduled.reserveRun(at: instant) && !scheduled.reserveRun(at: instant) && scheduled.turnLimit == 3, "Text schedule reserves a due run exactly once")
        check(!scheduled.reserveRun(at: instant.addingTimeInterval(1200)) && scheduled.turnLimit == 3, "Closed market does not spend a loop turn")
        let encoded = try JSONEncoder().encode(scheduled)
        let restored = try JSONDecoder().decode(AgentConfig.self, from: encoded)
        check(restored.scheduleText == scheduled.scheduleText && restored.nextRunAt == scheduled.nextRunAt, "Text schedule and next deadline survive persistence")
        var oldEditor = scheduled.wire(home: "local"); oldEditor.scheduleText = nil
        do { try scheduled.apply(oldEditor); check(false, "Old editor cannot erase a text schedule") }
        catch { check(scheduled.scheduleText == restored.scheduleText, "Old editor cannot erase a text schedule") }
    } catch { check(false, "Schedule integration fixture: " + error.localizedDescription) }
    let stopStore = Store(folder: FileManager.default.temporaryDirectory.appendingPathComponent("converse-stop-" + UUID().uuidString))
    let stopAgent = stopStore.createAgent(title: "Stop fixture agent")
    stopAgent.agent?.enabled = true
    stopAgent.resumeAfterInterrupt = false
    AgentRuntime().cancel(stopAgent)
    check(stopAgent.agent?.enabled == false && stopAgent.agent?.attention.contains("Agent Setup") == true && stopAgent.agent?.lastOutcome == "Paused by Stop.", "Stop explains a paused loop instead of silently disabling it")
    let strayStore = Store(folder: FileManager.default.temporaryDirectory.appendingPathComponent("converse-cancel-" + UUID().uuidString))
    let strayAgent = strayStore.createAgent(title: "Cancel fixture agent")
    strayAgent.agent?.enabled = true
    AgentRuntime().finishCancelledTurn(strayAgent, store: strayStore)
    check(strayAgent.agent?.enabled == true && strayAgent.agent?.attention == "Turn cancelled; loop remains on." && strayAgent.agent?.lastOutcome == "Turn cancelled; loop remains on.", "A cancelled turn that was not this session's Stop leaves the loop on")
    let ownStop = strayStore.createAgent(title: "Own Stop fixture agent")
    ownStop.agent?.enabled = true
    ownStop.queuePaused = true
    AgentRuntime().cancel(ownStop)
    AgentRuntime().finishCancelledTurn(ownStop, store: strayStore)
    check(ownStop.agent?.enabled == false && ownStop.agent?.attention.contains("Agent Setup") == true && ownStop.agent?.lastOutcome == "Paused by Stop.", "A Stop on the agent's own session keeps its paused explanation after the turn settles")
    let boardStore = Store(folder: FileManager.default.temporaryDirectory.appendingPathComponent("converse-board-" + UUID().uuidString))
    let boardAgent = boardStore.createAgent(title: "Scoreboard fixture agent")
    boardAgent.agent?.turnLimit = 1
    check(boardStore.requestScoreboardRefresh(boardAgent) && boardAgent.pending.last?.text.contains("scoreboard") == true, "Scoreboard refresh queues a scoreboard-only prompt")
    boardAgent.agent?.turnLimit = 0
    check(!boardStore.requestScoreboardRefresh(boardAgent) && boardAgent.agent?.attention.contains("turn limit") == true, "Scoreboard refresh without a turn limit asks for setup instead")
    let setupSwitch = strayStore.createAgent(title: "Setup switch fixture agent")
    setupSwitch.agent?.enabled = true
    setupSwitch.agent?.attention = "Stale alarm."
    do {
        try strayStore.configureAgentLoop(setupSwitch, enabled: false, interval: 900, turns: 20, scoreboardEvery: 1)
    } catch { check(false, "Setup switch fixture: " + error.localizedDescription) }
    check(setupSwitch.agent?.enabled == false && setupSwitch.agent?.attention == "" && setupSwitch.agent?.lastOutcome == "Loop turned off in Agent Setup.", "Switching a loop off in Setup clears the alarm and records the choice")
    check(AgentRepoSnapshot.validRepository("owner/repo-name") && !AgentRepoSnapshot.validRepository("../repo") && !AgentRepoSnapshot.validRepository("owner/repo?token=x"), "Agent repository paths cannot inject queries or escape their namespace")
    let old = AgentRepoSnapshot(repository: "owner/repo", openBugs: 2)
    check(AgentRepoSnapshot(repository: "owner/repo", openBugs: 3).mood(previous: old) == "urgent" && AgentRepoSnapshot(repository: "owner/repo", openBugs: 0).mood(previous: old) == "peaceful", "Widget mood follows measured bug changes")
    let researchResponse: [String: Any] = ["output": [
        ["type": "web_search_call", "status": "completed", "results": [["url": "https://example.com/quote", "title": "Quote"], ["url": "file:///private/secret", "title": "Unsafe"]]],
        ["type": "message", "content": [["type": "output_text", "annotations": [["type": "url_citation", "url": "https://example.com/news", "title": "News"]]]]]]]
    let research = AgentResearch.parse(researchResponse)
    check(research.searched && research.sources.count == 2 && !research.markdown.contains("file:"), "Web research preserves actual result/citation URLs and rejects non-web links")
    check(!research.markdown.contains("Source 1") && research.markdown.contains("[Quote](<https://example.com/quote>)"), "Research citations read as short labels instead of numbered sources")
    check(AgentWebSource.shortLabel(title: "Apple Reports Record Quarter Results Today", url: "https://example.com/x") == "Apple Reports" && AgentWebSource.shortLabel(title: "", url: "https://www.example.com/x") == "example.com" && AgentWebSource.shortLabel(title: "[Bracketed] (mess)", url: "https://example.com/x") == "Bracketed mess" && AgentWebSource.shortLabel(title: String(repeating: "Supercalifragilistic", count: 4), url: "https://example.com/x") == "example.com" && AgentWebSource.domainLabel("https://www.example.com/x") == "example.com", "Short source labels trim to two words with a domain fallback")
    check((MarkdownText.inline("[x](https://example.com/y)").attribute(.toolTip, at: 0, effectiveRange: nil) as? String) == "https://example.com/y", "Rendered links carry their URL as the hover tooltip")
    let board = AgentScoreboard(title: "Stock", summary: "Today’s verified snapshot", metrics: [
        .init(label: "Price", value: "$123", sourceURL: "https://example.com/quote", asOf: "2026-10-29 16:00 ET · close"),
        .init(label: "Invented", value: "999", sourceURL: "https://unseen.example/quote", asOf: "now")], sentiment: "up").validated(research: research, at: now)
    check(board.metrics[0].value == "$123" && board.metrics[1].value == "Unavailable" && board.metrics[1].sourceURL == nil && board.observedAt == now, "Scoreboard keeps source time distinct from retrieval and refuses metrics whose source was not retrieved")
    check(AgentScoreboardCards.html(board).contains("https://example.com/quote") && !AgentScoreboardCards.html(board).contains("999"), "Exported flexible scoreboard has clickable sources and omits unsupported values")
    check(AgentScoreboardCards.html(board).contains(">example.com</a>"), "Exported scoreboard links read as domains")
    do {
        var many = AgentResearch(); many.searched = true
        many.sources = (1...30).map { AgentWebSource(title: "Story \($0)", url: "https://news.example/\($0)") }
        check(many.appendix(for: "Weather is sunny. Sources: [Forecast](https://wx.example/94028) · [AI](https://ai.example/a)") == "", "Host adds no search-source list when the agent's reply already cites its own links")
        let capped = many.appendix(for: "Weather is sunny.")
        check(capped.hasPrefix("\n\nSources: ") && capped.components(separatedBy: "https://news.example/").count - 1 == 3, "Host-added search sources are capped at three when the reply has no links")
        check(AgentResearch().appendix(for: "No search ran.") == "", "No search sources means no Sources line")
        let fixed = Date(timeIntervalSince1970: 1793805780) // Wed Nov 4 2026 15:23 UTC
        check(AgentPromptContext.localNow(fixed, zone: TimeZone(identifier: "America/Los_Angeles")!) == "Wednesday, November 4, 2026 at 7:23 AM PST (America/Los_Angeles)", "Agents receive the current local date and time with zone")
        check(AgentInstructions.staticRules.contains("never report the absence of watched sessions") && AgentInstructions.staticRules.contains("use it for any date or time-of-day wording") && AgentInstructions.staticRules.contains("If you have nothing new or relevant to say, say nothing") && AgentInstructions.staticRules.contains("answer in one short line"), "Agents use the supplied local time, skip unconfigured sources, and stay silent when there is nothing to say")
        check(AgentReply.decode("{\"reply\":\"\",\"attention\":\"\"}")?.reply == "", "A silent agent reply is a valid reply, not an error that could pause the loop")
    }
    check(!AgentResearch.parse(["output": []]).searched && board.validated(research: AgentResearch()).metrics.allSatisfy { $0.value == "Unavailable" }, "Enabling search is not treated as evidence that a search ran")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-agents-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root)
    for title in ["Converse Development", "MuseConverse"] {
        let suggestion = store.create(Entry(name: "Fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")); suggestion.title = title
    }
    let agent = store.createAgent(); agent.queuePaused = true
    check(agent.agent?.watchedSessions.isEmpty == true, "New agents have no transcript scope until the user explicitly selects sessions")
    check(agent.agent?.repository == "", "New agents do not assume a GitHub repository")
    let missing = store.create(Entry(name: "Agent", command: "/usr/bin/false", directory: NSTemporaryDirectory(), engine: "agent"))
    missing.draft = "Retain this unsent question"; missing.attachments = ["fixture-image"]
    missing.probeError = "old CLI failure"; missing.needsSignIn = true
    var completedMissingRefresh = false
    store.refreshStatus(missing) { completedMissingRefresh = true }
    check(completedMissingRefresh && !missing.probingStatus && missing.needsAgentSetup && !missing.needsSignIn && missing.probeError == Session.missingAgentSettings,
          "Missing agent configuration reports setup recovery synchronously without launching a CLI")
    store.send(missing)
    check(!missing.busy && missing.process == nil && missing.draft == "Retain this unsent question" && missing.attachments == ["fixture-image"] && missing.messages.isEmpty && missing.queuePaused,
          "Unconfigured agent cannot become a CLI conversation or consume a draft")
    var missingSaved = missing.saved
    do {
        missingSaved = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(missingSaved))
        let reopened = Session(missingSaved)
        check(reopened.isAgentSession && reopened.needsAgentSetup && reopened.agent == nil,
              "Missing configuration retains agent identity across reload without inventing permissions")
    } catch { check(false, "Missing agent reload fixture: \(error)") }
    store.sessions.removeAll { $0.id == missing.id }
    var optionalConfig = AgentConfig(repository: "owner/repo")
    optionalConfig.snapshot = AgentRepoSnapshot(repository: "owner/repo", stars: 42)
    var optionalWire = optionalConfig.wire(home: "local"); optionalWire.repository = " \n "
    do {
        try optionalConfig.apply(optionalWire)
        let restored = try JSONDecoder().decode(AgentConfig.self, from: JSONEncoder().encode(optionalConfig))
        check(restored.repository.isEmpty && restored.snapshot == nil, "Blank repository saves and reloads, clearing prior repository measurements")
        optionalWire = optionalConfig.wire(home: "local"); optionalWire.repository = "../repo"
        do { try optionalConfig.apply(optionalWire); check(false, "Malformed nonblank repository must reject") }
        catch { check(optionalConfig.repository.isEmpty, "Malformed nonblank repository is rejected without changing saved settings") }
    } catch { check(false, "Optional repository settings: " + error.localizedDescription) }
    let recipient = store.create(Entry(name: "Fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")); recipient.queuePaused = true
    let blocked = store.create(recipient.entry); blocked.queuePaused = true
    agent.agent?.watchedSessions = [recipient.id]
    var secretWrites = 0, secretDeletes = 0
    do {
        try AgentSecrets.update("fixture", value: "", remove: false, write: { _, _ in secretWrites += 1 }, delete: { _ in secretDeletes += 1 })
        try AgentSecrets.update("fixture", value: "new test value", remove: false, write: { _, _ in secretWrites += 1 }, delete: { _ in secretDeletes += 1 })
        try AgentSecrets.update("fixture", value: "", remove: true, write: { _, _ in secretWrites += 1 }, delete: { _ in secretDeletes += 1 })
        check(secretWrites == 1 && secretDeletes == 1, "Agent credentials support explicit removal while blank fields preserve saved values")
        do { try AgentSecrets.update("fixture", value: "replacement", remove: true, write: { _, _ in secretWrites += 1 }, delete: { _ in secretDeletes += 1 }); check(false, "Conflicting secret edit rejected") }
        catch { check(secretWrites == 1 && secretDeletes == 1, "Conflicting credential replacement/removal changes nothing") }
    } catch { check(false, "Credential edit policy: " + error.localizedDescription) }
    var credentialReads = 0
    do {
        let entered = try AgentCredentialProbe.resolve("  replacement  ", name: "fixture", read: { _ in credentialReads += 1; return "saved" })
        let saved = try AgentCredentialProbe.resolve(" ", name: "fixture", read: { _ in credentialReads += 1; return " saved " })
        let missing = try AgentCredentialProbe.resolve("", name: "fixture", read: { _ in credentialReads += 1; return nil })
        check(entered == "replacement" && saved == "saved" && missing == nil && credentialReads == 2, "Connection tests prefer the entered credential, otherwise read the saved credential without modifying it")
    } catch { check(false, "Connection test credential selection") }
    let probeAPI = AgentAPI()
    func probe(_ operation: @escaping @MainActor () async throws -> String) -> String {
        var result = "Probe timed out", finished = false
        Task { @MainActor in
            do { result = try await operation() } catch { result = error.localizedDescription }
            finished = true
        }
        let end = Date().addingTimeInterval(3)
        while !finished && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return result
    }
    var probeRequests: [URLRequest] = []
    var deniedTraffic = false, responseStatus = 200
    probeAPI.request = { request in
        probeRequests.append(request)
        var status = responseStatus
        var object: [String: Any] = ["id": 42]
        if request.url?.path.hasSuffix("/traffic/views") == true {
            if deniedTraffic { status = 403 } else { object = ["uniques": 0] }
        }
        if request.url?.host == "discord.com" { object = ["id": "12345"] }
        if status != 200 { object = ["message": "private-service-error-canary"] }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    let searchAPI = AgentAPI()
    searchAPI.request = { request in
        let final = "{\"reply\":\"Sourced answer\",\"scoreboard\":{\"summary\":\"News summary\",\"metrics\":[]}}"
        let response: [String: Any] = ["status": "completed", "output": [
            ["type": "message", "phase": "commentary", "content": [["type": "output_text", "text": "Searching now"]]],
            ["type": "web_search_call", "status": "completed"],
            ["type": "message", "phase": "final_answer", "content": [["type": "output_text", "text": final]]]]]
        return (try JSONSerialization.data(withJSONObject: response), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let searchedReply = probe { try await searchAPI.respond(model: "fixture", instructions: "fixture", input: "fixture", key: "fixture", webSearch: true) }
    check(AgentReply.decode(searchedReply)?.reply == "Sourced answer" && !searchedReply.contains("Searching now"), "Hosted search commentary is excluded from the actionable final JSON")
    let githubOK = probe { try await probeAPI.testGitHub(repository: "owner/repo", token: "test-token") }
    check(githubOK.contains("token accepted") && githubOK.contains("visitor metrics are readable") && probeRequests.count == 3 && probeRequests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil && $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" }, "GitHub test checks token, repository metadata and traffic read-only; measured zero visitors succeeds")
    deniedTraffic = true; probeRequests = []
    let limitedGitHub = probe { try await probeAPI.testGitHub(repository: "owner/repo", token: "test-token") }
    check(limitedGitHub.contains("token accepted") && limitedGitHub.contains("Visitor metrics unavailable"), "GitHub test distinguishes a valid token from missing optional traffic permission")
    probeRequests = []
    let publicGitHub = probe { try await probeAPI.testGitHub(repository: "owner/repo", token: nil) }
    check(publicGitHub.contains("No token") && probeRequests.count == 1 && probeRequests[0].value(forHTTPHeaderField: "Authorization") == nil, "GitHub test without a token reports public access honestly and does not claim authenticated success")
    probeRequests = []
    let optionalGitHub = probe { try await probeAPI.testGitHub(repository: " ", token: nil) }
    check(optionalGitHub.contains("optional") && probeRequests.isEmpty, "Blank GitHub probe without a token makes no requests")
    let tokenOnly = probe { try await probeAPI.testGitHub(repository: "", token: "test-token") }
    check(tokenOnly.contains("token accepted") && probeRequests.map { $0.url?.path } == ["/user"], "Blank GitHub probe verifies only the token when supplied")
    probeRequests = []
    _ = probe {
        let snapshot = await probeAPI.metrics(repository: " \n ", token: "unused")
        return snapshot.notes.isEmpty && snapshot.repository.isEmpty ? "blank" : "unexpected"
    }
    check(probeRequests.isEmpty, "Blank repository metrics never call GitHub")
    responseStatus = 401; probeRequests = []
    let invalidGitHub = probe { try await probeAPI.testGitHub(repository: "owner/repo", token: "test-token") }
    check(invalidGitHub.contains("rejected the token") && !invalidGitHub.contains("private-service-error-canary") && probeRequests.count == 1, "Rejected GitHub credentials stop the probe and never expose response bodies")
    probeRequests = []
    let invalidRepository = probe { try await probeAPI.testGitHub(repository: "../repo", token: "test-token") }
    check(invalidRepository.contains("owner/name") && probeRequests.isEmpty, "GitHub probe rejects an invalid repository before making any request")
    responseStatus = 200; probeRequests = []
    let quitStore = Store(folder: root.appendingPathComponent("quit-fixture"))
    let quitCLI = quitStore.create(Entry(name: "Quit fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex"))
    check(ConverseQuitWarning(sessions: quitStore.sessions) == nil, "Idle ordinary sessions do not introduce an unnecessary quit confirmation")
    let supportOnly = Store(folder: root.appendingPathComponent("support-quit-fixture"))
    let support = supportOnly.supportSession(); support.agent = AgentConfig(); support.agent?.enabled = true
    support.title = "Renamed support"; support.busy = true
    check(ConverseQuitWarning(sessions: supportOnly.sessions) == nil, "Busy App Support with an enabled loop never introduces a quit warning, even when renamed")
    var supportShutdowns = 0; var supportConfirmations = 0
    check(supportOnly.requestApplicationQuit(confirm: { _ in supportConfirmations += 1; return false }, stopAgents: { supportShutdowns += 1 }) && supportConfirmations == 0 && supportShutdowns == 1, "Support-only Quit proceeds without a dialog and still runs normal agent shutdown")
    check(Store(folder: supportOnly.folder).sessions.first?.agent?.enabled == true, "Support-only Quit preserves the daily loop for restart")
    quitCLI.busy = true
    check(ConverseQuitWarning(sessions: [support, quitCLI])?.title == "Quit with 1 running session?", "Busy support is excluded while ordinary active work still warns")
    quitCLI.busy = false
    let quitAgent = quitStore.createAgent(title: "Quit fixture agent")
    quitAgent.queuePaused = true; quitAgent.draft = "Preserve this draft"
    quitAgent.pending = [PendingPrompt(text: "Keep this queued", images: [])]
    let pausedWarning = ConverseQuitWarning(sessions: quitStore.sessions)
    check(pausedWarning == nil, "Paused agents do not introduce an unnecessary quit warning")
    quitAgent.title = AppSupport.title
    quitAgent.agent?.enabled = true
    check(ConverseQuitWarning(sessions: [support, quitAgent])?.detail.contains("1 agent with enabled loops") == true, "An ordinary agent named Converse App Support still warns; the built-in role controls the exception")
    let loopWarning = ConverseQuitWarning(sessions: quitStore.sessions)
    check(loopWarning?.detail.contains("1 agent with enabled loops will not run until the app is restarted.") == true, "Quit warning counts enabled loops rather than every hosted agent")
    quitCLI.busy = true
    let combinedWarning = ConverseQuitWarning(sessions: quitStore.sessions)
    check(combinedWarning?.title == "Quit with 1 running session?" && combinedWarning?.detail.contains("stops active commands") == true && combinedWarning?.detail.contains("enabled loops will not run") == true, "Busy sessions and home agents share one combined quit confirmation")
    var quitShutdowns = 0
    let cancelledQuit = quitStore.requestApplicationQuit(confirm: { _ in false }, stopAgents: { quitShutdowns += 1 })
    check(!cancelledQuit && quitShutdowns == 0 && quitCLI.busy && !quitCLI.interrupted && quitAgent.draft == "Preserve this draft" && quitAgent.pending.count == 1, "Keep Running cancels quit without interrupting work, changing drafts or touching agent queues")
    quitAgent.agent?.enabled = true; quitAgent.agent?.generateArt = false
    let quitRuntime = AgentRuntime(); quitRuntime.keyReader = { _ in "isolated-quit-test-key" }
    var suspendedReply: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    var replyRequest: URLRequest?
    quitRuntime.api.request = { request in
        if request.url?.path == "/v1/responses" {
            replyRequest = request
            return await withCheckedContinuation { suspendedReply = $0 }
        }
        let path = request.url!.path
        let object: Any = path.contains("search/issues") ? ["total_count": 0] : (path.hasSuffix("/comments") || path.hasSuffix("/releases")) ? [] : ["stargazers_count": 0, "uniques": 0]
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let quitResponseID = UUID(); quitAgent.messages.append(Message(id: quitResponseID, role: "assistant", text: "")); quitAgent.busy = true
    quitRuntime.run(quitAgent, store: quitStore, responseID: quitResponseID)
    let quitRequestDeadline = Date().addingTimeInterval(3)
    while suspendedReply == nil && Date() < quitRequestDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(suspendedReply != nil, "Quit recovery fixture reaches an actual in-flight agent response")
    let acceptedQuit = quitStore.requestApplicationQuit(confirm: { _ in true }, stopAgents: { quitShutdowns += 1; quitRuntime.prepareForQuit() })
    check(acceptedQuit && quitShutdowns == 1 && quitCLI.interrupted && quitAgent.agent?.enabled == true && quitAgent.queuePaused && quitAgent.pending.count == 1, "Confirmed quit interrupts local CLI work but preserves enabled agent loops and paused queues for relaunch")
    if let continuation = suspendedReply, let request = replyRequest {
        let object: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "{\"reply\":\"Late shutdown result must not apply\",\"attention\":\"\"}"]]]]]
        continuation.resume(returning: (try! JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        let diagnostic = quitStore.folder.appendingPathComponent("Agents/" + quitAgent.id.uuidString + "/last-response.json")
        let callbackDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: diagnostic.path) && Date() < callbackDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(FileManager.default.fileExists(atPath: diagnostic.path) && quitAgent.agent?.enabled == true && !quitAgent.messages.contains { $0.text.contains("Late shutdown result") || $0.text.contains("Agent stopped.") } && quitAgent.pending.count == 1, "Late shutdown cancellation cannot apply a response, permanently pause the loop or drain queued input")
    }
    let budgetAfterQuit = quitAgent.agent?.turnLimit
    quitAgent.queuePaused = false; quitAgent.pending = []
    quitRuntime.tick(store: quitStore, now: Date().addingTimeInterval(86400))
    check(quitAgent.agent?.turnLimit == budgetAfterQuit && quitAgent.pending.isEmpty, "Agent scheduler cannot reserve or start another loop after quit is confirmed")
    let notStartedRuntime = AgentRuntime()
    var startedAfterQuit = 0
    notStartedRuntime.keyReader = { _ in startedAfterQuit += 1; return "isolated-quit-test-key" }
    notStartedRuntime.run(quitAgent, store: quitStore, responseID: quitResponseID)
    notStartedRuntime.prepareForQuit()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    check(startedAfterQuit == 0, "An agent task queued just before quit cannot read credentials or start an API request afterward")
    let quitRestored = Store(folder: quitStore.folder).sessions.first { $0.id == quitAgent.id }
    check(quitRestored?.agent?.enabled == true && quitRestored?.draft == "Preserve this draft" && quitRestored?.pending.count == 1, "Relaunch restores the enabled loop, draft and pending messages saved on confirmed quit")

    let loopStore = Store(folder: root.appendingPathComponent("loop-fixture"))
    let looping = loopStore.createAgent(title: "Loop presentation fixture")
    looping.queuePaused = true; looping.draft = "Unfinished human thought"
    func changeLoop(_ enabled: Bool) {
        let config = looping.agent!
        try! loopStore.configureAgentLoop(looping, enabled: enabled, interval: config.intervalSeconds, turns: config.turnLimit, scoreboardEvery: config.scoreboardCadence, now: now)
    }
    check(looping.agent?.loopStatus(at: now, busy: false, queuePaused: true, pendingCount: 0) == "Loop paused · automatic checks off", "Paused agent loop status explicitly says automatic checks are off")
    changeLoop(true)
    check(looping.agent?.nextRunAt == now.addingTimeInterval(900) && looping.agent?.turnLimit == 20 && !looping.queuePaused, "Resume loop schedules the first check one interval later, unblocks an empty stopped queue and does not spend a run")
    var loopStarts = 0
    loopStore.startAgentRun = { session, _ in loopStarts += 1; session.busy = true }
    let loopRuntime = AgentRuntime()
    loopRuntime.tick(store: loopStore, now: now.addingTimeInterval(899))
    check(loopStarts == 0 && looping.agent?.turnLimit == 20, "Enabled loop remains idle before its advertised next check")
    loopRuntime.tick(store: loopStore, now: now.addingTimeInterval(900))
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    check(loopStarts == 1 && looping.agent?.turnLimit == 20 && looping.draft == "Unfinished human thought", "Due loop performs one automatic check, preserves its per-loop limit and preserves the human draft")
    changeLoop(false)
    check(looping.busy && looping.agent?.enabled == false && !looping.interrupted, "Pause loop stops future checks without interrupting current thinking")
    looping.busy = false; looping.queuePaused = true; looping.pending = [PendingPrompt(text: "Held by human", images: [])]
    changeLoop(true)
    check(looping.queuePaused && looping.pending.count == 1 && looping.agent?.loopStatus(at: now, busy: false, queuePaused: true, pendingCount: 1).contains("queue paused") == true, "Resume loop leaves held messages paused and explains that state")
    looping.agent?.attention = "Review this blocker first"
    let loopWorkspace = Workspace(), loopWindow = WindowState(workspace: loopWorkspace)
    loopWorkspace.assign(looping.id, to: loopWindow.id, pane: 1)
    let hoverText = looping.sidebarSummary(workspace: loopWorkspace, windowID: loopWindow.id)
    let hoverAttributed = SidebarHoverView.attributedDetails(hoverText)
    check(hoverText.hasPrefix("ATTENTION REQUIRED\nReview this blocker first\n\n") && hoverAttributed.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemYellow, "Agent hover puts its warning first and highlights it yellow even when the agent is displayed in a pane")

    var loopRevision = looping.agent?.settingsRevision ?? 0
    do {
        try loopStore.configureAgentLoop(looping, enabled: true, interval: 120, turns: 4, scoreboardEvery: 3, expectedRevision: loopRevision, now: now)
        check(looping.agent?.intervalSeconds == 120 && looping.agent?.turnLimit == 4 && looping.agent?.scoreboardCadence == 3, "Loop popover saves interval, finite turn budget and scoreboard cadence together")
        loopRevision = looping.agent?.settingsRevision ?? 0
        looping.agent?.settingsChanged(); looping.agent?.turnLimit = 3
        do { try loopStore.configureAgentLoop(looping, enabled: true, interval: 120, turns: 4, scoreboardEvery: 3, expectedRevision: loopRevision); check(false, "Stale loop editor rejected") }
        catch { check(looping.agent?.turnLimit == 3, "A stale loop popover cannot restore a turn spent while it was open") }
    } catch { check(false, "Loop options: " + error.localizedDescription) }
    let cadenceStore = Store(folder: root.appendingPathComponent("cadence-fixture"))
    let cadenceAgent = cadenceStore.createAgent(title: "Cadence fixture")
    cadenceAgent.queuePaused = true; cadenceAgent.agent?.generateArt = false
    cadenceAgent.agent?.repository = "owner/repo"
    cadenceAgent.agent?.scoreboardEveryLoops = 2
    cadenceAgent.agent?.snapshot = AgentRepoSnapshot(repository: "owner/repo", observedAt: now, stars: 7)
    cadenceAgent.agent?.widgetSummary = "Existing scoreboard"
    let cadenceRuntime = AgentRuntime(); cadenceRuntime.keyReader = { _ in "isolated-cadence-key" }
    var measuredRequests = 0, cadenceResponses = 0
    cadenceRuntime.api.request = { request in
        let path = request.url!.path
        let object: Any
        if path == "/v1/responses" {
            cadenceResponses += 1
            object = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "{\"reply\":\"Cadence report \(cadenceResponses)\",\"attention\":\"\"}"]]]]]
        } else {
            measuredRequests += 1
            object = path.contains("search/issues") ? ["total_count": 0] : (path.hasSuffix("/comments") || path.hasSuffix("/releases")) ? [] : ["stargazers_count": 12, "uniques": 0]
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func cadenceRun(loop: Bool) {
        let id = UUID(); cadenceAgent.messages.append(Message(id: id, role: "assistant", text: "")); cadenceAgent.busy = true
        cadenceRuntime.run(cadenceAgent, store: cadenceStore, responseID: id, loopTick: loop)
        let end = Date().addingTimeInterval(3)
        while cadenceAgent.busy && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    cadenceRun(loop: true)
    check(!cadenceAgent.busy && cadenceResponses == 1 && measuredRequests == 0 && cadenceAgent.agent?.snapshot?.observedAt == now && cadenceAgent.agent?.widgetSummary == "Existing scoreboard" && cadenceAgent.agent?.loopsSinceScoreboard == 1, "An intervening scheduled loop still reports in the conversation without re-fetching or replacing the scoreboard")
    cadenceRun(loop: true)
    check(cadenceResponses == 2 && measuredRequests > 0 && cadenceAgent.agent?.widgetSummary == "Cadence report 2" && cadenceAgent.agent?.loopsSinceScoreboard == 0, "Scoreboard refresh happens on the configured loop cadence and resets its persisted counter")
    cadenceRun(loop: true)
    let measuredBeforeManual = measuredRequests
    cadenceRun(loop: false)
    check(cadenceResponses == 4 && measuredRequests > measuredBeforeManual && cadenceAgent.agent?.widgetSummary == "Cadence report 4" && cadenceAgent.agent?.loopsSinceScoreboard == 0, "A manual check forces a fresh scoreboard and resets the loop cadence without enabling the loop")
    cadenceAgent.agent?.repository = "owner/other"
    let measuredBeforeRepositoryChange = measuredRequests
    cadenceRun(loop: true)
    check(measuredRequests > measuredBeforeRepositoryChange && cadenceAgent.agent?.snapshot?.repository == "owner/other", "Changing repository forces fresh metrics instead of reusing another project's cached scoreboard")
    let legacyCadence = try! JSONDecoder().decode(AgentConfig.self, from: JSONEncoder().encode(AgentConfig()))
    check(legacyCadence.scoreboardCadence == 1 && cadenceAgent.agent?.wire(home: String(repeating: "a", count: 64)).scoreboardEveryLoops == 2, "Existing agents default to refreshing every loop and custom cadence travels in secret-free settings")
    let taggedLoop = PendingPrompt(agentLoopTick: true, text: "host tick", images: [])
    check((try? JSONDecoder().decode(PendingPrompt.self, from: JSONEncoder().encode(taggedLoop)))?.agentLoopTick == true, "Scheduled loop provenance survives queue persistence without inferring it from prompt text")

    let runtime = AgentRuntime()
    runtime.deliver(AgentReply(reply: "report", tell: [.init(to: recipient.id.uuidString, text: "Please review"), .init(to: blocked.id.uuidString, text: "Forbidden")]), from: agent, store: store)
    check(recipient.pending.count == 1 && blocked.pending.isEmpty && recipient.pending[0].text.contains(agent.id.uuidString), "Agent messages are visibly attributed and restricted to selected sessions")
    agent.switchboardTurnStart = agent.messages.count
    agent.messages.append(Message(role: "assistant", text: "```converse\n{\"command\":\"tell\",\"to\":\"" + blocked.id.uuidString + "\",\"text\":\"Forbidden through alternate protocol\"}\n```"))
    store.processSwitchboard(agent)
    check(blocked.pending.isEmpty && !store.switchboardDirectory(for: agent).contains(blocked.id.uuidString), "Agent scope also fences normal switchboard commands and directory lookup")
    agent.agent?.widgetSummary = "<script>alert('x')</script>"
    check(AgentWidgetExport.html(agent).contains("&lt;script&gt;") && !AgentWidgetExport.html(agent).contains("<script>"), "Exported agent widget escapes model text and disables scripts")
    agent.agent?.repository = "owner/repo"
    agent.agent?.snapshot = AgentRepoSnapshot(repository: "owner/repo")
    check(AgentWidgetExport.html(agent).contains("Repository data unavailable") && !AgentWidgetExport.html(agent).contains("<div class=metric>"), "Scoreboard without GitHub data gives one setup explanation instead of empty metric tiles")
    agent.agent?.snapshot?.stars = 0
    check(agent.agent?.snapshot?.hasMeasurements == true && AgentWidgetExport.html(agent).contains("<strong>0</strong>"), "Scoreboard distinguishes measured zero from missing GitHub data")
    agent.agent?.enabled = true; agent.agent?.turnLimit = 2; agent.agent?.nextRunAt = now
    agent.draft = "User's unfinished thought"
    runtime.tick(store: store, now: now)
    check(agent.pending.isEmpty && agent.agent?.turnLimit == 2, "Paused agent queues prevent scheduled wakeups")
    agent.queuePaused = false; agent.busy = true; runtime.tick(store: store, now: now)
    check(agent.agent?.turnLimit == 2, "Agent scheduler never overlaps a running turn")
    agent.busy = false; agent.queuePaused = true; store.save()
    let reloaded = Store(folder: root).sessions.first { $0.id == agent.id }
    check(reloaded?.agent?.watchedSessions == [recipient.id] && reloaded?.draft == "User's unfinished thought", "Agent settings and editable draft survive archive reload")

    let stimulated = store.createAgent(title: "External stimulus fixture")
    stimulated.agent?.fileTriggers = true; stimulated.agent?.turnLimit = 1
    stimulated.draft = "A separate human draft"
    var starts = 0
    store.startAgentRun = { session, _ in starts += 1; session.busy = true }
    let inbox = root.appendingPathComponent("Agents/" + stimulated.id.uuidString + "/Inbox")
    try! FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let event = AgentRuntime.FileEvent(id: UUID(), text: "A test result arrived; ask for evidence.")
    let eventFile = inbox.appendingPathComponent("event.json")
    try! JSONEncoder().encode(event).write(to: eventFile)
    runtime.ingestFileEvents(store: store)
    check(stimulated.pending.count == 1 && stimulated.agent?.processedEvents == [event.id] && !FileManager.default.fileExists(atPath: eventFile.path), "Opt-in file events persist provenance and deduplication before consuming the input file")
    store.runNext(stimulated)
    check(starts == 1 && stimulated.agent?.turnLimit == 1 && stimulated.draft == "A separate human draft", "External stimuli persist their reservation without spending future activations before starting and preserve the human draft")
    stimulated.busy = false
    try! JSONEncoder().encode(event).write(to: eventFile)
    runtime.ingestFileEvents(store: store)
    check(stimulated.pending.isEmpty && starts == 1, "Repeated external event IDs do not enqueue or start duplicate runs")
    store.enqueueSwitchboard(stimulated, text: "Another agent asks for work", hop: 1)
    store.runNext(stimulated)
    check(!stimulated.queuePaused && stimulated.pending.isEmpty && starts == 2 && stimulated.agent?.turnLimit == 1, "A separate incoming request receives a fresh activation without consuming future loop checks")
    stimulated.agent?.fileTriggers = false; stimulated.pending = []
    let expired = store.createAgent(title: "Expired tick fixture")
    expired.agent?.scheduleText = "unsupported restriction"
    expired.pending = [PendingPrompt(agentRunReserved: true, agentLoopTick: true, text: "Expired tick", images: [])]
    store.runNext(expired)
    check(expired.pending.isEmpty && !expired.busy && starts == 2, "Queued loop ticks revalidate restrictions before starting and do not block later human input")
    store.startAgentRun = nil
    let migrated = AgentConfig(watchedSessions: [recipient.id])
    let localHome = String(repeating: "a", count: 64), otherHome = String(repeating: "b", count: 64)
    check(migrated.allows(global: DeviceGlobalID(home: localHome, session: recipient.id).string, home: localHome)
        && !migrated.allows(global: DeviceGlobalID(home: otherHome, session: recipient.id).string, home: localHome), "Legacy agent scope migrates only within its original home, never a same-UUID remote session")

    var runningSettings = AgentConfig()
    runningSettings.enabled = true; runningSettings.nextRunAt = .distantPast
    let openForm = runningSettings.wire(home: localHome)
    check(runningSettings.reserveRun(at: Date()), "Settings fixture starts a scheduled activation")
    do { try runningSettings.apply(openForm); check(true, "Starting an activation does not invalidate an open settings form") }
    catch { check(false, "Unedited settings must remain saveable during an activation: \(error)") }

    var revisionFixture = AgentConfig()
    let staleSettings = revisionFixture.wire(home: localHome)
    revisionFixture.settingsChanged(); revisionFixture.turnLimit -= 1
    do { try revisionFixture.apply(staleSettings); check(false, "Stale settings must reject") }
    catch { check(revisionFixture.turnLimit == 19, "Saving a stale setup form cannot overwrite a changed per-loop limit") }

    // Real engine path, fake HTTP. No credentials, external requests or billable calls.
    runtime.keyReader = { _ in "isolated-test-key" }
    var requests: [URLRequest] = []
    recipient.messages.append(Message(role: "assistant", text: "private scope canary"))
    let currentWork = store.create(recipient.entry)
    currentWork.title = "Currently working fixture"; currentWork.busy = true; currentWork.status = "Working…"
    currentWork.messages = [Message(role: "user", text: "are you working?"), Message(role: "assistant", text: "")]
    agent.supportTeachingVersion = 1 // Existing teaching must receive the current research policy.
    agent.agent?.watchedSessions = [recipient.id, currentWork.id]
    runtime.api.request = { request in
        requests.append(request)
        let path = request.url!.path
        if path != "/v1/responses" { agent.agent?.watchedSessions.removeAll { $0 == recipient.id } } // Revoke scope while repository requests are in flight.
        var object: Any = [:]
        if path == "/v1/responses" {
            object = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "{\"reply\":\"Measured progress\",\"attention\":\"Need a success criterion\",\"tell\":[],\"memory\":\"Keep release acceptance criteria\"}"]]]]]
        } else if path.contains("search/issues") { object = ["total_count": 0, "incomplete_results": false] }
        else if path.hasSuffix("/releases") || path.hasSuffix("/comments") { object = [] }
        else if path.hasSuffix("/views") { object = ["uniques": 7] }
        else { object = ["stargazers_count": 12] }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    agent.agent?.generateArt = false; agent.agent?.enabled = false; agent.pending = []; agent.queuePaused = true
    let visualFile = store.folder.appendingPathComponent("agent-input.png")
    let visualFixture = NSImage(size: NSSize(width: 80, height: 40), flipped: false) { rect in NSColor.blue.setFill(); rect.fill(); return true }
    try! MacImageSource.normalized(visualFixture).write(to: visualFile)
    let userImage = Message(role: "user", text: "How is the project doing?", images: [visualFile.path])
    agent.messages.append(userImage)
    let responseID = UUID(); agent.messages.append(Message(id: responseID, role: "assistant", text: "")); agent.busy = true
    agent.lastOutputAt = ProcessInfo.processInfo.systemUptime - 12
    runtime.run(agent, store: store, responseID: responseID)
    let deadline = Date().addingTimeInterval(8)
    while agent.busy && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!agent.busy && agent.messages.contains { $0.text == "Measured progress" } && agent.agent?.snapshot?.stars == 12 && agent.agent?.snapshot?.visitors14d == 7 && agent.needsApproval, "Direct API agent completes a measured report and raises yellow attention")
    let response = agent.messages.first { $0.id == responseID }!
    check(response.delays?.first?.offset == 0 && (response.delays?.first?.seconds ?? 0) >= 12, "Real agent response path records the same first-output delay as sessions")
    let responseView = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    let responseCoordinator = ScrollingConversation.Coordinator(agent); responseCoordinator.render(responseView)
    check(responseView.messageLabels.count == agent.messages.filter { !$0.text.isEmpty || !$0.images.isEmpty }.count && responseView.messageLabels.last?.timestamp == response.createdAt,
          "Agent transcript numbers all visible messages and retains their timestamp labels")
    let answerRange = (responseView.string as NSString).range(of: "Measured progress")
    check(answerRange.location != NSNotFound && responseView.textStorage?.attribute(.toolTip, at: answerRange.location, effectiveRange: nil) as? String != nil && responseView.string.contains(Store.delayLabel(response.delays?.first?.seconds ?? 0)),
          "Agent response body provides a timestamp hover and rendered delay hint")
    check(FileManager.default.fileExists(atPath: root.appendingPathComponent("Agents/" + agent.id.uuidString + "/widget.html").path) && requests.contains { $0.url?.path == "/v1/responses" }, "Agent exports its scoreboard after the model response")
    let archive = (try? String(contentsOf: root.appendingPathComponent("sessions.json"), encoding: .utf8)) ?? ""
    check(Store(folder: root).sessions.first(where: { $0.id == agent.id })?.agent?.workingMemory == "Keep release acceptance criteria", "Agent's learned human criteria survive archive reload beyond the recent conversation window")
    check(!archive.contains("isolated-test-key") && !AgentWidgetExport.html(agent).contains("isolated-test-key"), "Agent credentials never enter persisted sessions or widget exports")
    let modelInput = requests.first { $0.url?.path == "/v1/responses" }?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check(!modelInput.contains("private scope canary"), "Scope revoked during repository collection is excluded from the next model request")
    let requestBody = requests.first { $0.url?.path == "/v1/responses" }?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let visualMessages = requestBody?["input"] as? [[String: Any]]
    let visualContent = visualMessages?.first?["content"] as? [[String: Any]] ?? []
    check(visualContent.contains { $0["type"] as? String == "input_image" && ($0["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true } && visualContent.contains { ($0["text"] as? String)?.contains(userImage.id.uuidString) == true }, "Real agent runtime sends attached pixels and associates them with the originating user message")
    let inputs = try! AgentPromptContext.images([userImage, Message(role: "assistant", text: "Generated art", images: ["missing-art.png"])], excluding: UUID())
    check(inputs.count == 1, "Agent vision excludes assistant artwork")
    let historyImages = (0..<10).map { Message(role: "user", text: "Image \($0)", images: [visualFile.path]) }
    let recentImages = try! AgentPromptContext.images(historyImages, excluding: UUID())
    check(recentImages.count == 8 && recentImages.first?.label.contains(historyImages[2].id.uuidString) == true, "Agent image history is bounded to the newest eight with stable message labels")
    check((try? AgentPromptContext.images([Message(role: "user", text: "Missing", images: [store.folder.appendingPathComponent("missing.png").path])], excluding: UUID())) == nil, "Unreadable attached images fail explicitly instead of silently sending text only")
    let oldMissing = Message(role: "user", text: "Old image", images: [store.folder.appendingPathComponent("missing-old.png").path])
    let recovered = try! AgentPromptContext.imageContext([oldMissing, userImage], excluding: UUID())
    check(recovered.images.count == 1 && recovered.omitted.first?.contains(oldMissing.id.uuidString) == true, "Unavailable historical image is explicitly omitted and does not block a new image request")
    let claudeVisual = try! JSONSerialization.jsonObject(with: AgentCLI.claudeInput("Question", images: inputs)) as! [String: Any]
    let claudeContent = (claudeVisual["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    check(claudeContent.contains { $0["type"] as? String == "image" && ($0["source"] as? [String: String])?["media_type"] == "image/png" }, "Claude agent stream input contains native image blocks")
    let claudeStream = Data("{\"type\":\"assistant\",\"message\":{}}\n{\"type\":\"result\",\"is_error\":false,\"result\":\"Image read\"}\n".utf8)
    check((try? AgentCLI.finalReply(engine: "claude", data: claudeStream, final: nil)) == "Image read", "Claude image turns consume the terminal streamed result, not intermediate messages")
    let supportPolicy = requestBody?["instructions"] as? String ?? ""
    check(supportPolicy.contains("Never search the web for bare") && supportPolicy.contains("site:github.com/richardkaufmann/converse") && supportPolicy.contains("no relevant result is found"), "Previously taught agents receive current scoped research policy in the actual model request")
    agent.supportTeachingVersion = nil
    func evidenceText(_ body: [String: Any]?) -> String? {
        if let text = body?["input"] as? String { return text }
        return (((body?["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first?["text"] as? String)
    }
    let evidenceInput = evidenceText(requestBody).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let activeEvidence = (evidenceInput?["watchedSessions"] as? [[String: Any]])?.first { $0["title"] as? String == "Currently working fixture" }
    check(activeEvidence?["busy"] as? Bool == true && activeEvidence?["activity"] as? String == "running now" && activeEvidence?["activityObservedAt"] as? String != nil && (requestBody?["instructions"] as? String)?.contains("do not recommend re-prompting or resuming") == true, "Agent receives timestamped current host activity and must not infer a stalled session from an unfinished reply")
    check((requestBody?["instructions"] as? String)?.contains(AgentPolicy.scoreboardScope) == true, "Agent scoreboard instructions limit metrics to that agent's own objective and scope")
    check((requestBody?["tools"] as? [[String: String]])?.first?["type"] == "web_search" && requestBody?["max_tool_calls"] as? Int == 4, "Agent enables bounded built-in web research without changing credential test calls")
    check(requestBody?["max_output_tokens"] as? Int == 8192 && (requestBody?["reasoning"] as? [String: Any])?["effort"] as? String == "low", "Agent requests reserve room for reasoning and visible output with explicit low effort")
    check(requestBody?["prompt_cache_key"] as? String == AgentInstructions.cacheKey(agent.id) && requestBody?["prompt_cache_retention"] as? String == "24h" && (requestBody?["instructions"] as? String)?.hasPrefix(AgentInstructions.staticRules) == true,
          "Real agent runtime sends its static instructions first with a per-agent prompt cache key")

    // Clearing GitHub must not make an unrelated saved credential a runtime dependency.
    var noRepoSettings = agent.agent!.wire(home: localHome); noRepoSettings.repository = ""
    noRepoSettings.objective = "Report weather news only. Never mention GitHub or Discord."
    do { try agent.agent?.apply(noRepoSettings) } catch { check(false, "Clear runtime repository") }
    agent.agent?.generateArt = false; requests = []
    runtime.keyReader = { name in
        guard name != "github" else { throw AgentFailure.message("GitHub must not be read") }
        return "isolated-test-key"
    }
    agent.busy = true
    let noRepoID = UUID(); agent.messages.append(Message(id: noRepoID, role: "assistant", text: ""))
    runtime.run(agent, store: store, responseID: noRepoID)
    let noRepoDeadline = Date().addingTimeInterval(8)
    while agent.busy && Date() < noRepoDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!agent.busy && agent.agent?.lastOutcome == "Completed" && requests.count == 1 && requests.first?.url?.host == "api.meta.ai", "Agent without a repository completes using only Meta, with GitHub credentials inaccessible")
    let noRepoBody = requests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let noRepoEvidence = evidenceText(noRepoBody)?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(noRepoEvidence?["repository"] is NSNull, "General agent evidence explicitly omits repository data")
    let noRepoInstructions = noRepoBody?["instructions"] as? String ?? ""
    check(noRepoInstructions.contains("Objective: Report weather news only. Never mention GitHub or Discord.") && !noRepoInstructions.contains("Objective: " + AgentConfig().objective) && noRepoInstructions.contains(AgentPolicy.objectiveGoverns), "An objective edited in Agent Setup reaches the next run and governs supplied evidence and older notes")
    let noRepoHTML = AgentWidgetExport.html(agent)
    check(noRepoHTML.contains("AGENT SCOREBOARD") && !noRepoHTML.contains("Repository data unavailable") && !noRepoHTML.contains("<div class=grid>"), "General scoreboard retains its report without GitHub warnings or metric tiles")
    check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Agents/" + agent.id.uuidString + "/metrics.json").path), "Clearing GitHub removes stale exported repository measurements")
    check(Store(folder: root).sessions.first(where: { $0.id == agent.id })?.agent?.repository == "", "No-repository agent survives a full session archive reload")
    runtime.keyReader = { _ in "isolated-test-key" }
    agent.agent?.discordRead = true; agent.agent?.discordChannelID = "42"
    agent.agent?.discord = false
    let priorRequest = runtime.api.request
    runtime.api.request = { request in
        if request.url?.host == "discord.com" {
            let messages: [[String: Any]] = [["id": "100", "channel_id": "42", "content": "The window is clipped", "author": ["username": "Tester", "bot": false]]]
            return (try JSONSerialization.data(withJSONObject: messages), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return try await priorRequest(request)
    }
    requests = []; agent.busy = true
    let discordID = UUID(); agent.messages.append(Message(id: discordID, role: "assistant", text: ""))
    runtime.run(agent, store: store, responseID: discordID)
    let discordDeadline = Date().addingTimeInterval(8)
    while agent.busy && Date() < discordDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    let discordBody = requests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(agent.agent?.lastOutcome == "Completed" && agent.agent?.discordLastMessageID == "100" && evidenceText(discordBody)?.contains("The window is clipped") == true, "Agent run supplies Discord evidence to the model and commits its read cursor on a valid response")
    check(Store(folder: root).sessions.first(where: { $0.id == agent.id })?.agent?.discordLastMessageID == "100", "Successful Discord read cursor survives session archive reload")
    agent.agent?.discordLastMessageID = "99"
    runtime.api.request = { request in
        if request.url?.host == "discord.com" {
            return (Data("[{\"id\":\"101\",\"channel_id\":\"42\",\"content\":\"Still clipped\",\"author\":{\"username\":\"Tester\"}}]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    agent.busy = true
    let discordFailID = UUID(); agent.messages.append(Message(id: discordFailID, role: "assistant", text: ""))
    runtime.run(agent, store: store, responseID: discordFailID)
    let discordFailDeadline = Date().addingTimeInterval(8)
    while agent.busy && Date() < discordFailDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(agent.agent?.discordLastMessageID == "99" && agent.agent?.lastOutcome.hasPrefix("Stopped:") == true, "Failed model response leaves Discord messages unread for a later retry")
    agent.agent?.discordRead = false; agent.agent?.discordChannelID = nil

    let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
    runtime.api.request = { request in
        let image = request.url?.path == "/v1/images/generations"
        let object: [String: Any] = image ? ["data": [["b64_json": png.base64EncodedString()]]] : ["stargazers_count": 1]
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    var art: Data?; var artDone = false
    Task { @MainActor in art = try? await runtime.api.art(prompt: "Test background", key: "isolated-test-key"); artDone = true }
    let artDeadline = Date().addingTimeInterval(3)
    while !artDone && Date() < artDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(art != nil && NSBitmapImageRep(data: art!) != nil, "Muse Image response bytes become a validated portable PNG")
    runtime.api.request = { request in
        let object: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "Not a structured agent action"]]]]]
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    agent.busy = true; let malformedID = UUID(); agent.messages.append(Message(id: malformedID, role: "assistant", text: "")); runtime.run(agent, store: store, responseID: malformedID)
    let malformedDeadline = Date().addingTimeInterval(8)
    while agent.busy && Date() < malformedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!agent.busy && agent.agent?.attention.contains("invalid action format twice") == true, "Malformed completed agent output is re-asked once, then fails without applying actions")
    runtime.api.request = { request in
        let object: [String: Any] = ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"], "usage": ["output_tokens": 8192, "output_tokens_details": ["reasoning_tokens": 8192]], "output": [["type": "message", "content": [["type": "output_text", "text": "{\"reply\":\"Partial result\",\"tell\":[]}"]]]], "error": ["message": "private-api-canary"]]
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    agent.busy = true; let failedID = UUID(); agent.messages.append(Message(id: failedID, role: "assistant", text: "")); runtime.run(agent, store: store, responseID: failedID)
    let failedDeadline = Date().addingTimeInterval(8)
    while agent.busy && Date() < failedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!agent.busy && agent.agent?.attention.contains("No actions applied") == true, "Incomplete model responses cannot apply actions")
    check(agent.agent?.attention.contains("response limit") == true, "Token exhaustion produces an actionable reason instead of a generic incomplete error")
    let diagnosticPath = root.appendingPathComponent("Agents/" + agent.id.uuidString + "/last-response.json")
    let diagnosticBytes = try! Data(contentsOf: diagnosticPath)
    let diagnosticDecoder = JSONDecoder(); diagnosticDecoder.dateDecodingStrategy = .iso8601
    let diagnostic = try! diagnosticDecoder.decode(AgentResponseDiagnostic.self, from: diagnosticBytes)
    check(diagnostic.incompleteReason == "max_output_tokens" && diagnostic.reasoningTokens == 8192 && !String(decoding: diagnosticBytes, as: UTF8.self).contains("private-api-canary"), "Response diagnostics preserve safe termination and usage metadata without raw API bodies")

    // Judges with only Claude Code or Codex: new agents use an installed CLI, not the Meta API.
    let judge = Store(folder: root.appendingPathComponent("judge-defaults"))
    judge.entries = ["claude", "codex", "muse"].map { Entry(name: $0.capitalized, command: $0, directory: NSTemporaryDirectory(), engine: $0) }
    let fakePath = root.appendingPathComponent("judge-path")
    try? FileManager.default.createDirectory(at: fakePath, withIntermediateDirectories: true)
    func install(_ name: String, _ present: Bool) {
        let file = fakePath.appendingPathComponent(name)
        if present { FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]) } else { try? FileManager.default.removeItem(at: file) }
    }
    judge.agentCommandAvailable = { ProviderCommand.resolve($0.command, directories: [fakePath.path]) != nil }
    judge.agentSecret = { _ in nil }
    install("claude", true); install("codex", true)
    let claudeJudge = judge.createAgent(title: "CLI judge", persist: false)
    check(AgentModels.parse(claudeJudge.agent?.model ?? "")?.engine == "claude" && claudeJudge.agent?.generateArt == false, "Without a Meta key a new agent defaults to the installed Claude CLI with mood art off")
    install("claude", false)
    check(AgentModels.parse(judge.createAgent(title: "Codex judge", persist: false).agent?.model ?? "")?.engine == "codex", "Codex is the default when it is the only installed CLI")
    install("codex", false)
    check(judge.createAgent(title: "No CLI", persist: false).agent?.model == "muse-spark-1.3", "With no installed CLI the Meta API model remains")
    install("claude", true); judge.agentSecret = { $0 == "meta" ? "isolated-test-key" : nil }
    let metaJudge = judge.createAgent(title: "Meta judge", persist: false).agent
    check(metaJudge?.model == "muse-spark-1.3" && metaJudge?.generateArt == true, "A saved Meta key keeps the Meta API model and mood art defaults")
    check(claudeJudge.agent?.generateArt == false, "Saving a Meta key later does not silently turn on art for existing agents")
    judge.agentSecret = nil
    check(judge.createAgent(title: "Fixture judge", persist: false).agent?.model == "muse-spark-1.3", "Fixtures without a credential reader keep the legacy defaults")
    check(AgentModels.options(store: judge).compactMap { AgentModels.parse($0.id)?.engine } == ["claude"], "Agent model options omit providers whose CLI is not on the searched path")
    check(ProviderCommand.resolve("claude", directories: [fakePath.path]) == fakePath.appendingPathComponent("claude").path && ProviderCommand.resolve("muse", directories: [fakePath.path]) == nil, "Command resolution finds only executables in the searched directories")
    let keyless = AgentRuntime(); keyless.keyReader = { _ in nil }
    let metaAgent = judge.createAgent(title: "Keyless Meta agent", persist: false)
    let keylessID = UUID(); metaAgent.messages.append(Message(id: keylessID, role: "assistant", text: "")); metaAgent.busy = true
    keyless.run(metaAgent, store: judge, responseID: keylessID)
    let keylessDeadline = Date().addingTimeInterval(8)
    while metaAgent.busy && Date() < keylessDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(metaAgent.agent?.attention.contains(AgentModels.missingMetaKey) == true, "Run once without a Meta key says how to fix it")
}


func configurationAuditSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("configuration-audit-" + UUID().uuidString)
    let store = Store(folder: root)
    let agent = store.createAgent(title: "private-title-canary")
    agent.agent?.objective = "private-objective-canary"
    agent.draft = "private-draft-canary"
    store.save()
    let expected = agent.agent
    agent.agent = nil
    store.save()
    let directory = root.appendingPathComponent("Configuration Diagnostics")
    func events() -> String {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
    }
    let recovery = directory.appendingPathComponent("Agent Recovery/" + agent.id.uuidString + "/latest.json")
    do {
        let recovered = try JSONDecoder().decode(AgentConfig.self, from: Data(contentsOf: recovery))
        check(recovered == expected, "Diagnostic recovery retains the last valid agent configuration after it is removed from memory and saved")
        let rows = events()
        check(rows.contains("agent_configuration_removed_in_memory") && rows.contains("stack") && rows.contains("agent_configuration_save_committed") && rows.contains("AgentTests.swift"),
              "Agent removal diagnostics identify in-memory transition, call stack and archive save origin")
        check(!rows.contains("private-objective-canary") && !rows.contains("private-draft-canary") && !rows.contains("private-title-canary"),
              "Configuration diagnostic events contain no objectives, titles or draft text")
        let archive = root.appendingPathComponent("sessions.json")
        var bytes = try Data(contentsOf: archive); bytes.append(10); try bytes.write(to: archive, options: .atomic)
        store.save()
        check(events().contains("archive_changed_outside_this_store"), "Configuration diagnostics detect an archive replaced by another writer")
        let reopened = Store(folder: root)
        check(reopened.sessions.first?.needsAgentSetup == true && events().contains("missingAgentConfigurations") && FileManager.default.fileExists(atPath: recovery.path),
              "Restart records missing configurations and preserves recovery evidence without silently granting old permissions")
        let mode = (try FileManager.default.attributesOfItem(atPath: recovery.path)[.posixPermissions] as? NSNumber)?.intValue
        check(mode == 0o600, "Agent recovery copies are readable only by the owning user")
        store.configurationAudit.failure("fixture_failure", error: NSError(domain: "fixture", code: 7, userInfo: [NSLocalizedDescriptionKey: "private-error-canary"]))
        check(!events().contains("private-error-canary"), "Diagnostic failures record error categories without raw provider or filesystem error bodies")
        let rotation = ConfigurationAudit(folder: root.appendingPathComponent("rotation"), limit: 512)
        for index in 0..<40 { rotation.record("rotation_fixture", ["index": index]) }
        let logs = try FileManager.default.contentsOfDirectory(at: rotation.directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        check(logs.count == 2 && logs.allSatisfy { ((try? Data(contentsOf: $0).count) ?? 10000) <= 512 }, "Diagnostic rotation bounds active logs while retaining the previous segment")

        let historyStore = Store(folder: root.appendingPathComponent("snapshot-history"))
        let historyAgent = historyStore.createAgent(title: "Recovery history fixture")
        historyAgent.agent?.objective = "first-private-objective"
        try historyStore.saveChecked()
        let firstConfig = historyAgent.agent
        historyAgent.agent?.objective = "second-private-objective"
        try historyStore.saveChecked()
        let secondConfig = historyAgent.agent
        let historyFolder = historyStore.configurationAudit.directory.appendingPathComponent("Agent Recovery/" + historyAgent.id.uuidString)
        func historyConfig(_ name: String) throws -> AgentConfig {
            try JSONDecoder().decode(AgentConfig.self, from: Data(contentsOf: historyFolder.appendingPathComponent(name + ".json")))
        }
        check(try historyConfig("latest") == secondConfig && historyConfig("previous") == firstConfig,
              "Changed agent configuration preserves both the current and preceding recovery versions")
        try historyStore.saveChecked()
        let historyReopened = Store(folder: historyStore.folder)
        check(try historyReopened.sessions.first?.agent == secondConfig && historyConfig("previous") == firstConfig,
              "Unchanged saves and restart do not replace the preceding recovery version")
        let previousMode = (try FileManager.default.attributesOfItem(atPath: historyFolder.appendingPathComponent("previous.json").path)[.posixPermissions] as? NSNumber)?.intValue
        check(previousMode == 0o600, "Previous configuration snapshots remain owner-readable only")

        // An ordinary file blocks creation of the diagnostics directory on every
        // platform, even when the test process has elevated filesystem access.
        let blockedRoot = root.appendingPathComponent("blocked-diagnostics")
        try FileManager.default.createDirectory(at: blockedRoot, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: blockedRoot.appendingPathComponent("Configuration Diagnostics"))
        let blockedStore = Store(folder: blockedRoot)
        let blockedAgent = blockedStore.createAgent(title: "Diagnostic failure fixture")
        blockedAgent.agent?.objective = "preserve despite logging failure"
        blockedAgent.draft = "preserve editable draft"
        try blockedStore.saveChecked()
        let blockedReopened = Store(folder: blockedRoot)
        check(blockedReopened.sessions.first?.agent == blockedAgent.agent && blockedReopened.sessions.first?.draft == blockedAgent.draft,
              "Unavailable diagnostics never prevent saving and reopening the agent configuration and draft")
    } catch { check(false, "Configuration diagnostics fixture: \(error)") }
}

// Explicit opt-in live probe. Uses a fresh temporary profile and no actions,
// watched sessions, Discord, repository, artwork, or scheduled work.
@MainActor func agentImageLiveTest() -> Bool {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("converse-live-vision-" + UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let code = "VISION-" + String(UUID().uuidString.prefix(8))
        let fixture = NSImage(size: NSSize(width: 900, height: 320), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            NSColor.blue.setFill(); NSRect(x: 30, y: 35, width: 180, height: 130).fill()
            (code as NSString).draw(at: NSPoint(x: 30, y: 220), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 48, weight: .bold), .foregroundColor: NSColor.black])
            return true
        }
        let file = folder.appendingPathComponent("visual-fixture.png")
        try MacImageSource.normalized(fixture).write(to: file)
        let store = Store(folder: folder)
        let session = store.create(Entry(name: "Vision test", command: "/usr/bin/false", directory: folder.path, engine: "agent"))
        var config = AgentConfig(); config.generateArt = false; config.webSearch = false
        if let engine = ProcessInfo.processInfo.environment["CONVERSE_VISION_TEST_ENGINE"], ["muse", "claude", "codex"].contains(engine) {
            let archiveFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Converse/sessions.json")
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: archiveFile))
            store.entries = archive.entries; store.accounts = archive.accounts ?? []
            guard let account = store.accounts.first(where: { $0.engine == engine }) else { throw AgentFailure.message("No existing login for this test provider.") }
            config.model = AgentModels.reference(engine: engine, account: account.id)
        }
        config.objective = "Answer the user's image question. Do not request or perform actions."
        session.agent = config
        session.messages = [Message(role: "user", text: "Read the exact code printed in this image and name the color of the rectangle.", images: [file.path])]
        let reply = UUID(); session.messages.append(Message(id: reply, role: "assistant", text: "")); session.busy = true
        let runtime = AgentRuntime(); runtime.run(session, store: store, responseID: reply)
        let deadline = Date().addingTimeInterval(120)
        while session.busy && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let result = session.messages.first { $0.id == reply }?.text ?? ""
        let passed = !session.busy && result.contains(code) && result.localizedCaseInsensitiveContains("blue")
        print("Live agent image test: \(passed ? "PASS" : "FAIL")\n\(result)\nAttention: \(session.agent?.attention ?? "")\nArtifacts: \(folder.path)")
        runtime.prepareForQuit()
        return passed
    } catch { print("Live agent image test failed: " + error.localizedDescription); return false }
}
