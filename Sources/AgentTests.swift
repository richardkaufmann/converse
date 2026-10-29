import AppKit
import Foundation

@MainActor func agentSelfTests(_ check: (Bool, String) -> Void) {
    let now = Date(timeIntervalSince1970: 1_000)
    var config = AgentConfig(); config.enabled = true; config.remainingRuns = 1; config.nextRunAt = now
    check(config.reserveRun(at: now) && config.remainingRuns == 0 && !config.enabled && !config.reserveRun(at: now), "Agent reserves its last scheduled run once and stops at the persisted cap")
    check(AgentRepoSnapshot.validRepository("owner/repo-name") && !AgentRepoSnapshot.validRepository("../repo") && !AgentRepoSnapshot.validRepository("owner/repo?token=x"), "Agent repository paths cannot inject queries or escape their namespace")
    let old = AgentRepoSnapshot(repository: "owner/repo", openBugs: 2)
    check(AgentRepoSnapshot(repository: "owner/repo", openBugs: 3).mood(previous: old) == "urgent" && AgentRepoSnapshot(repository: "owner/repo", openBugs: 0).mood(previous: old) == "peaceful", "Widget mood follows measured bug changes")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-agents-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root)
    for title in ["Converse Development", "MuseConverse"] {
        let suggestion = store.create(Entry(name: "Fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")); suggestion.title = title
    }
    let agent = store.createAgent(); agent.queuePaused = true
    check(agent.agent?.watchedSessions.isEmpty == true, "New agents have no transcript scope until the user explicitly selects sessions")
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
    let githubOK = probe { try await probeAPI.testGitHub(repository: "owner/repo", token: "test-token") }
    check(githubOK.contains("token accepted") && githubOK.contains("visitor metrics are readable") && probeRequests.count == 3 && probeRequests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil && $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" }, "GitHub test checks token, repository metadata and traffic read-only; measured zero visitors succeeds")
    deniedTraffic = true; probeRequests = []
    let limitedGitHub = probe { try await probeAPI.testGitHub(repository: "owner/repo", token: "test-token") }
    check(limitedGitHub.contains("token accepted") && limitedGitHub.contains("Visitor metrics unavailable"), "GitHub test distinguishes a valid token from missing optional traffic permission")
    probeRequests = []
    let publicGitHub = probe { try await probeAPI.testGitHub(repository: "owner/repo", token: nil) }
    check(publicGitHub.contains("No token") && probeRequests.count == 1 && probeRequests[0].value(forHTTPHeaderField: "Authorization") == nil, "GitHub test without a token reports public access honestly and does not claim authenticated success")
    responseStatus = 401; probeRequests = []
    let invalidGitHub = probe { try await probeAPI.testGitHub(repository: "owner/repo", token: "test-token") }
    check(invalidGitHub.contains("rejected the token") && !invalidGitHub.contains("private-service-error-canary") && probeRequests.count == 1, "Rejected GitHub credentials stop the probe and never expose response bodies")
    probeRequests = []
    let invalidRepository = probe { try await probeAPI.testGitHub(repository: "../repo", token: "test-token") }
    check(invalidRepository.contains("owner/name") && probeRequests.isEmpty, "GitHub probe rejects an invalid repository before making any request")
    responseStatus = 200; probeRequests = []
    let testWebhook = "https://discord.com/api/webhooks/12345/test_token?thread_id=6789&wait=false"
    let discordOK = probe { try await probeAPI.testDiscord(webhook: testWebhook) }
    let sentBody = probeRequests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let sentQuery = probeRequests.first?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    check(discordOK.contains("confirmed") && probeRequests.count == 1 && probeRequests[0].httpMethod == "POST" && sentBody?["content"] as? String == "Converse connection test — this webhook is working. No session content is included." && (sentBody?["allowed_mentions"] as? [String: Any])?["parse"] as? [String] == [] && sentQuery.contains(URLQueryItem(name: "wait", value: "true")) && sentQuery.contains(URLQueryItem(name: "thread_id", value: "6789")), "Discord test posts only the fixed labeled message, disables mentions, preserves thread routing and waits for confirmation")
    for webhook in ["https://discord.com.attacker.test/api/webhooks/12345/test_token", "http://discord.com/api/webhooks/12345/test_token", "https://discord.com/api/users/@me", "https://name:password@discord.com/api/webhooks/12345/test_token", "https://discord.com/api/webhooks/12345/test_token?redirect=elsewhere"] {
        probeRequests = []
        let rejected = probe { try await probeAPI.testDiscord(webhook: webhook) }
        check(rejected.contains("Integrations") && probeRequests.isEmpty, "Discord probe refuses non-webhook or untrusted destinations without sending")
    }
    responseStatus = 404; probeRequests = []
    let missingWebhook = probe { try await probeAPI.testDiscord(webhook: testWebhook) }
    check(missingWebhook.contains("may have been deleted") && !missingWebhook.contains("private-service-error-canary") && !missingWebhook.contains("test_token"), "Discord probe explains a deleted webhook without exposing its URL or the API response")
    probeAPI.request = { request in throw NSError(domain: "private-url-canary-test_token", code: -1, userInfo: [NSLocalizedDescriptionKey: request.url!.absoluteString]) }
    let offlineDiscord = probe { try await probeAPI.testDiscord(webhook: testWebhook) }
    check(offlineDiscord.contains("Check the channel and network") && !offlineDiscord.contains("test_token"), "Discord network errors cannot leak secret webhook URLs")
    probeAPI.request = { request in (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!) }
    let unconfirmedDiscord = probe { try await probeAPI.testDiscord(webhook: testWebhook) }
    check(unconfirmedDiscord.contains("did not confirm") && !unconfirmedDiscord.contains("confirmed the test"), "Discord test does not report delivery without a returned message receipt")
    let quitStore = Store(folder: root.appendingPathComponent("quit-fixture"))
    let quitCLI = quitStore.create(Entry(name: "Quit fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex"))
    check(ConverseQuitWarning(sessions: quitStore.sessions) == nil, "Idle ordinary sessions do not introduce an unnecessary quit confirmation")
    let quitAgent = quitStore.createAgent(title: "Quit fixture agent")
    quitAgent.queuePaused = true; quitAgent.draft = "Preserve this draft"
    quitAgent.pending = [PendingPrompt(text: "Keep this queued", images: [])]
    let pausedWarning = ConverseQuitWarning(sessions: quitStore.sessions)
    check(pausedWarning?.detail.contains("won't be able to reach them") == true && pausedWarning?.detail.contains("until you restart") == true && pausedWarning?.quitButton == "Quit Converse", "Paused home agents still warn that quitting makes them unreachable and stops their loops")
    quitCLI.busy = true
    let combinedWarning = ConverseQuitWarning(sessions: quitStore.sessions)
    check(combinedWarning?.title == "Quit with 1 running session?" && combinedWarning?.detail.contains("stops active commands") == true && combinedWarning?.detail.contains("terminates your agents") == true, "Busy sessions and home agents share one combined quit confirmation")
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
    let budgetAfterQuit = quitAgent.agent?.remainingRuns
    quitAgent.queuePaused = false; quitAgent.pending = []
    quitRuntime.tick(store: quitStore, now: Date().addingTimeInterval(86400))
    check(quitAgent.agent?.remainingRuns == budgetAfterQuit && quitAgent.pending.isEmpty, "Agent scheduler cannot reserve or start another loop after quit is confirmed")
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
        try! loopStore.configureAgentLoop(looping, enabled: enabled, interval: config.intervalSeconds, turns: config.remainingRuns, scoreboardEvery: config.scoreboardCadence, now: now)
    }
    check(looping.agent?.loopStatus(at: now, busy: false, queuePaused: true, pendingCount: 0) == "Loop paused · automatic checks off", "Paused agent loop status explicitly says automatic checks are off")
    changeLoop(true)
    check(looping.agent?.nextRunAt == now.addingTimeInterval(900) && looping.agent?.remainingRuns == 20 && !looping.queuePaused, "Resume loop schedules the first check one interval later, unblocks an empty stopped queue and does not spend a run")
    var loopStarts = 0
    loopStore.startAgentRun = { session, _ in loopStarts += 1; session.busy = true }
    let loopRuntime = AgentRuntime()
    loopRuntime.tick(store: loopStore, now: now.addingTimeInterval(899))
    check(loopStarts == 0 && looping.agent?.remainingRuns == 20, "Enabled loop remains idle before its advertised next check")
    loopRuntime.tick(store: loopStore, now: now.addingTimeInterval(900))
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    check(loopStarts == 1 && looping.agent?.remainingRuns == 19 && looping.draft == "Unfinished human thought", "Due loop performs one automatic check, spends one run and preserves the human draft")
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
        check(looping.agent?.intervalSeconds == 120 && looping.agent?.remainingRuns == 4 && looping.agent?.scoreboardCadence == 3, "Loop popover saves interval, finite turn budget and scoreboard cadence together")
        loopRevision = looping.agent?.settingsRevision ?? 0
        looping.agent?.settingsChanged(); looping.agent?.remainingRuns = 3
        do { try loopStore.configureAgentLoop(looping, enabled: true, interval: 120, turns: 4, scoreboardEvery: 3, expectedRevision: loopRevision); check(false, "Stale loop editor rejected") }
        catch { check(looping.agent?.remainingRuns == 3, "A stale loop popover cannot restore a turn spent while it was open") }
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
    agent.agent?.snapshot = AgentRepoSnapshot(repository: "owner/repo")
    check(AgentWidgetExport.html(agent).contains("Repository data unavailable") && !AgentWidgetExport.html(agent).contains("<div class=metric>"), "Scoreboard without GitHub data gives one setup explanation instead of empty metric tiles")
    agent.agent?.snapshot?.stars = 0
    check(agent.agent?.snapshot?.hasMeasurements == true && AgentWidgetExport.html(agent).contains("<strong>0</strong>"), "Scoreboard distinguishes measured zero from missing GitHub data")
    agent.agent?.enabled = true; agent.agent?.remainingRuns = 2; agent.agent?.nextRunAt = now
    agent.draft = "User's unfinished thought"
    runtime.tick(store: store, now: now)
    check(agent.pending.isEmpty && agent.agent?.remainingRuns == 2, "Paused agent queues prevent scheduled wakeups")
    agent.queuePaused = false; agent.busy = true; runtime.tick(store: store, now: now)
    check(agent.agent?.remainingRuns == 2, "Agent scheduler never overlaps a running turn")
    agent.busy = false; agent.queuePaused = true; store.save()
    let reloaded = Store(folder: root).sessions.first { $0.id == agent.id }
    check(reloaded?.agent?.watchedSessions == [recipient.id] && reloaded?.draft == "User's unfinished thought", "Agent settings and editable draft survive archive reload")

    let stimulated = store.createAgent(title: "External stimulus fixture")
    stimulated.agent?.fileTriggers = true; stimulated.agent?.remainingRuns = 1
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
    check(starts == 1 && stimulated.agent?.remainingRuns == 0 && stimulated.draft == "A separate human draft", "External stimuli reserve a persisted run budget before starting and preserve the human draft")
    stimulated.busy = false
    try! JSONEncoder().encode(event).write(to: eventFile)
    runtime.ingestFileEvents(store: store)
    check(stimulated.pending.isEmpty && starts == 1, "Repeated external event IDs do not enqueue or start duplicate runs")
    store.enqueueSwitchboard(stimulated, text: "Another agent asks for work", hop: 1)
    store.runNext(stimulated)
    check(stimulated.queuePaused && stimulated.pending.count == 1 && starts == 1 && stimulated.agent?.attention.contains("budget exhausted") == true, "Incoming agent tells cannot bypass the autonomous turn allowance")
    stimulated.agent?.fileTriggers = false; stimulated.pending = []
    store.startAgentRun = nil
    let migrated = AgentConfig(watchedSessions: [recipient.id])
    let localHome = String(repeating: "a", count: 64), otherHome = String(repeating: "b", count: 64)
    check(migrated.allows(global: DeviceGlobalID(home: localHome, session: recipient.id).string, home: localHome)
        && !migrated.allows(global: DeviceGlobalID(home: otherHome, session: recipient.id).string, home: localHome), "Legacy agent scope migrates only within its original home, never a same-UUID remote session")

    var revisionFixture = AgentConfig()
    let staleSettings = revisionFixture.wire(home: localHome)
    revisionFixture.settingsChanged(); revisionFixture.remainingRuns -= 1
    do { try revisionFixture.apply(staleSettings); check(false, "Stale settings must reject") }
    catch { check(revisionFixture.remainingRuns == 19, "Saving a stale setup form cannot restore an autonomous run already spent") }

    // Real engine path, fake HTTP. No credentials, external requests or billable calls.
    runtime.keyReader = { _ in "isolated-test-key" }
    var requests: [URLRequest] = []
    recipient.messages.append(Message(role: "assistant", text: "private scope canary"))
    let currentWork = store.create(recipient.entry)
    currentWork.title = "Currently working fixture"; currentWork.busy = true; currentWork.status = "Working…"
    currentWork.messages = [Message(role: "user", text: "are you working?"), Message(role: "assistant", text: "")]
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
    agent.messages.append(Message(role: "user", text: "How is the project doing?"))
    let responseID = UUID(); agent.messages.append(Message(id: responseID, role: "assistant", text: "")); agent.busy = true
    runtime.run(agent, store: store, responseID: responseID)
    let deadline = Date().addingTimeInterval(8)
    while agent.busy && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!agent.busy && agent.messages.contains { $0.text == "Measured progress" } && agent.agent?.snapshot?.stars == 12 && agent.agent?.snapshot?.visitors14d == 7 && agent.needsApproval, "Direct API agent completes a measured report and raises yellow attention")
    check(FileManager.default.fileExists(atPath: root.appendingPathComponent("Agents/" + agent.id.uuidString + "/widget.html").path) && requests.contains { $0.url?.path == "/v1/responses" }, "Agent exports its scoreboard after the model response")
    let archive = (try? String(contentsOf: root.appendingPathComponent("sessions.json"), encoding: .utf8)) ?? ""
    check(Store(folder: root).sessions.first(where: { $0.id == agent.id })?.agent?.workingMemory == "Keep release acceptance criteria", "Agent's learned human criteria survive archive reload beyond the recent conversation window")
    check(!archive.contains("isolated-test-key") && !AgentWidgetExport.html(agent).contains("isolated-test-key"), "Agent credentials never enter persisted sessions or widget exports")
    let modelInput = requests.first { $0.url?.path == "/v1/responses" }?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check(!modelInput.contains("private scope canary"), "Scope revoked during repository collection is excluded from the next model request")
    let requestBody = requests.first { $0.url?.path == "/v1/responses" }?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let evidenceInput = (requestBody?["input"] as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let activeEvidence = (evidenceInput?["watchedSessions"] as? [[String: Any]])?.first { $0["title"] as? String == "Currently working fixture" }
    check(activeEvidence?["busy"] as? Bool == true && activeEvidence?["activity"] as? String == "running now" && activeEvidence?["activityObservedAt"] as? String != nil && (requestBody?["instructions"] as? String)?.contains("do not recommend re-prompting or resuming") == true, "Agent receives timestamped current host activity and must not infer a stalled session from an unfinished reply")
    check(requestBody?["max_output_tokens"] as? Int == 8192 && (requestBody?["reasoning"] as? [String: Any])?["effort"] as? String == "low", "Agent requests reserve room for reasoning and visible output with explicit low effort")

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
    check(!agent.busy && agent.agent?.enabled == false && agent.agent?.attention.contains("invalid action format") == true, "Malformed completed agent output pauses the loop without applying actions")
    runtime.api.request = { request in
        let object: [String: Any] = ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"], "usage": ["output_tokens": 8192, "output_tokens_details": ["reasoning_tokens": 8192]], "output": [["type": "message", "content": [["type": "output_text", "text": "{\"reply\":\"Partial result\",\"tell\":[]}"]]]], "error": ["message": "private-api-canary"]]
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    agent.busy = true; let failedID = UUID(); agent.messages.append(Message(id: failedID, role: "assistant", text: "")); runtime.run(agent, store: store, responseID: failedID)
    let failedDeadline = Date().addingTimeInterval(8)
    while agent.busy && Date() < failedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!agent.busy && agent.agent?.enabled == false && agent.agent?.attention.contains("No actions applied") == true, "Incomplete model responses cannot apply actions and pause the agent loop")
    check(agent.agent?.attention.contains("response limit") == true, "Token exhaustion produces an actionable reason instead of a generic incomplete error")
    let diagnosticPath = root.appendingPathComponent("Agents/" + agent.id.uuidString + "/last-response.json")
    let diagnosticBytes = try! Data(contentsOf: diagnosticPath)
    let diagnosticDecoder = JSONDecoder(); diagnosticDecoder.dateDecodingStrategy = .iso8601
    let diagnostic = try! diagnosticDecoder.decode(AgentResponseDiagnostic.self, from: diagnosticBytes)
    check(diagnostic.incompleteReason == "max_output_tokens" && diagnostic.reasoningTokens == 8192 && !String(decoding: diagnosticBytes, as: UTF8.self).contains("private-api-canary"), "Response diagnostics preserve safe termination and usage metadata without raw API bodies")
}
