import Foundation

// Transient failures back off and never pause; a malformed reply is re-asked
// once; only problems the human must fix pause, with a reason that later
// manual runs cannot hide. Fixtures only: no network.
@MainActor func agentRetrySelfTests(_ check: (Bool, String) -> Void) {
    let now = ISO8601DateFormatter().date(from: "2026-11-04T15:00:00Z")!
    // Classification.
    let transient: [Error] = [URLError(.timedOut), URLError(.networkConnectionLost), URLError(.notConnectedToInternet), URLError(.cannotConnectToHost), URLError(.badURL),
        NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), AgentFailure.message("api.meta.ai returned HTTP 503."), AgentFailure.message("api.meta.ai returned HTTP 429."),
        AgentFailure.message("api.meta.ai returned HTTP 500."), AgentFailure.message("The request timed out."), AgentFailure.message("Provider timed out; no actions applied."),
        AgentFailure.message("The model is overloaded. Please retry."), AgentFailure.message("api.meta.ai returned HTTP 400."), AgentFailure.message("Something nobody anticipated."),
        AgentFailure.message("Provider request failed. Check the selected login in Setup; no actions applied."), AgentFailure.message("Discord scope changed during the run. Run again with the new settings."),
        AgentFailure.message("Agent service returned an invalid response. No actions applied."), AgentFailure.message("Model selection changed during this activation. Retry with the new selection.")]
    for error in transient { check(AgentRunFailure.classify(error) == .transient, "Transient, never a pause: " + error.localizedDescription) }
    let permanent: [Error] = [AgentFailure.message("Meta rejected the API key (HTTP 401). Check or replace it in Agent Setup."),
        AgentFailure.message(AgentModels.missingMetaKey), AgentFailure.message("This activation reached its turn limit. The next scheduled loop gets a fresh limit."),
        AgentFailure.message("No future run is available. Review the schedule/calendar."), AgentFailure.message("Invalid agent settings. Check scope, interval and run budget."),
        AgentFailure.message("GitHub denied access or reached its rate limit (HTTP 403). Check token permissions or try again later."),
        AgentFailure.message("Discord rejected the bot token. Replace it in Agent Setup."), AgentFailure.message("Add a Converse bot token in Agent Setup to read Discord."),
        AgentFailure.message("Invalid provider selection. Choose a model again."), AgentFailure.message("This agent's provider/login is no longer enabled. Choose a model and login in Agent Setup."),
        URLError(.userAuthenticationRequired)]
    for error in permanent { check(AgentRunFailure.classify(error) == .permanent, "Permanent, pause with a fix: " + error.localizedDescription) }
    let model: [Error] = [AgentFailure.message("Agent returned an invalid action format twice. No actions applied; the next check tries again."),
        AgentFailure.message("Agent response stopped before completion (incomplete). No actions applied."),
        AgentFailure.message("Agent hit its response limit (8192 tokens including reasoning). No actions applied."), AgentFailure.message("Agent returned no answer.")]
    for error in model { check(AgentRunFailure.classify(error) == .model, "Model output problem, re-asked once: " + error.localizedDescription) }
    check(AgentRunFailure.classify(CancellationError()) == .cancelled && AgentRunFailure.classify(URLError(.cancelled)) == .cancelled, "Cancellation is neither transient nor a permanent failure")
    check(AgentRunFailure.correction(for: "Agent hit its response limit") == AgentRunFailure.lengthCorrection
          && AgentRunFailure.correction(for: "Agent returned an invalid action format") == AgentRunFailure.formatCorrection, "Cut-off replies ask for a shorter answer; malformed ones for one JSON object")

    // Back-off: 1, 2, 4, 8 minutes, capped at the loop interval.
    check([1, 2, 3, 4, 5, 6, 40].map { AgentRunFailure.backoff(failures: $0, interval: 900) } == [60, 120, 240, 480, 900, 900, 900], "Retries back off 1, 2, 4, 8 minutes up to the interval")
    check(AgentRunFailure.backoff(failures: 1, interval: 30) == 60 && AgentRunFailure.backoff(failures: 3, interval: 86400) == 240, "Back-off never retries sooner than a minute and grows to long intervals")

    // Many transient failures never pause; banner from the third; success clears it.
    var loop = AgentConfig(); loop.enabled = true; loop.turnLimit = 3; loop.intervalSeconds = 900; loop.autoPace = false
    loop.nextRunAt = now.addingTimeInterval(900)
    loop.recordFailure("The request timed out.", kind: .transient, countsForLoop: true, at: now)
    check(loop.enabled && loop.transientFailures == 1 && loop.attention.isEmpty && loop.lastOutcome.hasPrefix("Retrying: The request timed out.") && loop.pauseReason == nil
          && loop.nextRunAt == now.addingTimeInterval(60) && loop.troubleSince == now, "A first transient failure stays quiet, keeps the loop on and retries in one minute")
    // Each scheduled tick reserves the next regular check before running.
    func fail(_ message: String, kind: AgentRunFailure.Kind = .transient, at time: Date) {
        loop.nextRunAt = time.addingTimeInterval(900)
        loop.recordFailure(message, kind: kind, countsForLoop: true, at: time)
    }
    fail("The request timed out.", kind: .model, at: now.addingTimeInterval(60))
    check(loop.enabled && loop.transientFailures == 2 && loop.attention.isEmpty && loop.nextRunAt == now.addingTimeInterval(180), "A repeated model-output failure is treated as transient: retry two minutes later")
    var reset = loop
    reset.recordSuccess("Completed", attention: nil)
    check(reset.enabled && reset.transientFailures == nil && reset.troubleSince == nil && reset.attention.isEmpty && reset.lastOutcome == "Completed", "A success resets the counter")
    fail("The request timed out.", at: now.addingTimeInterval(180))
    let banner = AgentRunFailure.trouble(since: now, reason: "The request timed out.", tries: 3)
    check(loop.enabled && loop.pauseReason == nil && loop.attention == banner && banner.hasPrefix("Having trouble since " + AgentRunFailure.stamp(now) + ": The request timed out. — still retrying (3 tries)")
          && loop.nextRunAt == now.addingTimeInterval(180 + 240), "The third failure in a row shows a trouble banner with its start time, and the loop keeps running")
    for attempt in 4...25 { fail("api.meta.ai returned HTTP 503.", at: now.addingTimeInterval(Double(attempt) * 900)) }
    check(loop.enabled && loop.pauseReason == nil && loop.transientFailures == 25 && loop.attention.contains("still retrying (25 tries)") && loop.attention.contains("HTTP 503")
          && loop.nextRunAt == now.addingTimeInterval(25 * 900 + 900), "Twenty-five transient failures never pause; retries settle at the loop interval")
    loop.recordSuccess("Completed", attention: nil)
    check(loop.enabled && loop.attention.isEmpty && loop.transientFailures == nil && loop.troubleSince == nil, "A success clears the trouble banner")
    var reported = loop
    for offset in 0..<3 { reported.recordFailure("The request timed out.", kind: .transient, countsForLoop: true, at: now.addingTimeInterval(Double(offset))) }
    reported.recordSuccess("Completed", attention: "Release blocked on review")
    check(reported.attention == "Release blocked on review", "A reported attention replaces the trouble banner")
    var hard = AgentConfig(); hard.enabled = true
    hard.recordFailure("Meta rejected the API key (HTTP 401).", kind: .permanent, countsForLoop: true, at: now)
    check(!hard.enabled && hard.pauseReason?.hasPrefix("Paused: Meta rejected the API key") == true, "Permanent failures still pause immediately")
    var publicTurn = AgentConfig(); publicTurn.enabled = true
    publicTurn.recordFailure("Meta rejected the API key (HTTP 401).", kind: .permanent, countsForLoop: false, at: now)
    check(publicTurn.enabled && publicTurn.pauseReason == nil && publicTurn.lastOutcome.hasPrefix("Stopped:"), "Public Discord turns never pause the loop")

    // A later manual, Jolly or Discord run keeps the pause reason visible.
    var paused = hard
    paused.recordSuccess("Completed", attention: "")
    check(!paused.enabled && paused.lastOutcome == hard.pauseReason && paused.attention == hard.pauseReason, "A later completed run cannot erase why the loop is paused")
    paused.recordSuccess("Discord reply completed", attention: "Price feed lagging")
    check(paused.lastOutcome == hard.pauseReason && paused.attention == hard.pauseReason! + " · Price feed lagging", "New attention is added after the pause reason")
    paused.recordFailure("Discord response was incomplete.", kind: .permanent, countsForLoop: true, at: now)
    check(paused.pauseReason == hard.pauseReason && paused.attention.hasPrefix(hard.pauseReason!) && paused.attention.contains("Discord response was incomplete"), "A later failed run keeps the original pause reason first")

    // Store paths: clear banner, Setup saves and re-enable.
    let store = Store(folder: FileManager.default.temporaryDirectory.appendingPathComponent("converse-retry-" + UUID().uuidString))
    let agent = store.createAgent(title: "Retry fixture agent")
    agent.agent?.enabled = true
    agent.agent?.pause("Meta rejected the API key (HTTP 401).", at: now)
    do { try store.configureAgentLoop(agent, enabled: false, interval: 900, turns: 3) } catch { check(false, "Retry fixture setup save") }
    check(agent.agent?.pauseReason != nil && agent.pausedLoopReason == agent.agent?.pauseReason, "Saving other settings with the loop still off keeps the pause reason")
    store.clearAgentAttention(agent)
    check(agent.agent?.pauseReason == nil && agent.agent?.attention == "", "Clear attention banner ends the recorded pause")
    agent.agent?.recordSuccess("Completed", attention: nil)
    check(agent.agent?.lastOutcome == "Completed", "After clearing, later runs report normally")
    agent.agent?.enabled = true; agent.agent?.pause("Meta rejected the API key (HTTP 401).", at: now)
    do { try store.configureAgentLoop(agent, enabled: true, interval: 900, turns: 3) } catch { check(false, "Retry fixture re-enable") }
    check(agent.agent?.enabled == true && agent.agent?.pauseReason == nil && agent.agent?.transientFailures == nil, "Re-enabling the loop clears the pause reason and counter")
    agent.agent?.enabled = false; agent.agent?.pause("Meta rejected the API key (HTTP 401).", at: now)
    if var wire = agent.agent?.wire(home: "local") {
        wire.enabled = true
        do { try agent.agent?.apply(wire) } catch { check(false, "Remote re-enable: " + error.localizedDescription) }
        check(agent.agent?.enabled == true && agent.agent?.pauseReason == nil, "A remote editor re-enabling the loop clears the pause reason")
    }
    if let config = agent.agent, let restored = try? JSONDecoder().decode(AgentConfig.self, from: JSONEncoder().encode({ var c = config; c.transientFailures = 2; c.troubleSince = now; c.pauseReason = "Paused: x"; return c }())) {
        check(restored.transientFailures == 2 && restored.troubleSince == now && restored.pauseReason == "Paused: x", "Retry count, trouble start and pause reason survive archive reload")
    } else { check(false, "Retry count, trouble start and pause reason survive archive reload") }

    // Pause loop / Resume loop from the … menu or footer status.
    let controls = store.createAgent(title: "Controls fixture agent")
    controls.agent?.autoPace = false
    do { try store.configureAgentLoop(controls, enabled: true, interval: 900, turns: 3, now: now) } catch { check(false, "Controls fixture enable") }
    store.pauseAgentLoop(controls)
    check(controls.agent?.enabled == false && controls.agent?.nextRunAt == nil && controls.agent?.pauseReason == nil && controls.agent?.attention == ""
          && controls.agent?.lastOutcome.hasPrefix("Loop paused") == true, "Pause loop turns automatic checks off without an alarm")
    controls.agent?.pause("Meta rejected the API key (HTTP 401).", at: now)
    store.resumeAgentLoop(controls, now: now)
    check(controls.agent?.enabled == true && controls.agent?.pauseReason == nil && controls.agent?.attention == "" && controls.agent?.lastOutcome == "Loop resumed."
          && controls.agent?.nextRunAt == now.addingTimeInterval(900) && controls.status == "Ready", "Resume loop clears the pause reason and banner and schedules the next check")
    controls.agent?.attention = "Release blocked on review"
    store.pauseAgentLoop(controls); store.resumeAgentLoop(controls, now: now)
    check(controls.agent?.enabled == true, "Pause and Resume round-trip")

    // End to end: repeated timed-out loop runs keep the loop on.
    let runtime = AgentRuntime()
    runtime.keyReader = { _ in "isolated-test-key" }
    runtime.api.request = { _ in throw URLError(.timedOut) }
    let looping = store.createAgent(title: "Timeout fixture agent")
    looping.agent?.enabled = true; looping.agent?.turnLimit = 3; looping.agent?.generateArt = false
    func pump(_ session: Session, seconds: Double = 8) {
        let deadline = Date().addingTimeInterval(seconds)
        while session.busy && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    func start(_ session: Session, runtime: AgentRuntime, loopTick: Bool = true) {
        session.busy = true
        let id = UUID(); session.messages.append(Message(id: id, role: "assistant", text: ""))
        runtime.run(session, store: store, responseID: id, loopTick: loopTick)
    }
    for attempt in 1...5 {
        start(looping, runtime: runtime); pump(looping)
        check(looping.agent?.enabled == true && looping.agent?.transientFailures == attempt && looping.agent?.pauseReason == nil && !looping.agentLoopPaused
              && looping.messages.last?.role == "notice" && (attempt < 3 ? looping.agent?.attention.isEmpty == true : looping.agent?.attention.hasPrefix("Having trouble since ") == true),
              "Timed-out loop run \(attempt) keeps the loop on" + (attempt < 3 ? " quietly" : " with a trouble banner"))
    }

    // Same-run corrective re-ask: bad JSON, then a good reply.
    func replyResponse(_ text: String, status: String = "completed", reason: String? = nil) -> Data {
        var object: [String: Any] = ["status": status, "output": [["type": "message", "content": [["type": "output_text", "text": text]]]]]
        if let reason { object["incomplete_details"] = ["reason": reason] }
        return try! JSONSerialization.data(withJSONObject: object)
    }
    var scripted: [Data] = []
    var instructions: [String] = []
    let fixer = AgentRuntime()
    fixer.keyReader = { name in name == "discordBot" ? nil : "isolated-test-key" }
    fixer.api.request = { request in
        if request.url?.path == "/v1/responses" {
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            instructions.append(body?["instructions"] as? String ?? "")
        }
        let data = scripted.isEmpty ? replyResponse("{\"reply\":\"unexpected\"}") : scripted.removeFirst()
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let healed = store.createAgent(title: "Re-ask fixture agent")
    healed.agent?.enabled = true; healed.agent?.turnLimit = 1; healed.agent?.generateArt = false
    let notices = { healed.messages.filter { $0.role == "notice" }.count }
    let noticesBefore = notices()
    scripted = [replyResponse("Sure! Here is my update: things look fine."), replyResponse("{\"reply\":\"Recovered report\",\"attention\":\"\"}")]
    start(healed, runtime: fixer); pump(healed)
    check(instructions.count == 2 && !instructions[0].contains(AgentRunFailure.formatCorrection) && instructions[1].hasSuffix(AgentRunFailure.formatCorrection)
          && healed.agent?.lastOutcome == "Completed" && healed.agent?.enabled == true && healed.messages.contains { $0.role == "assistant" && $0.text == "Recovered report" }
          && notices() == noticesBefore, "A malformed reply is re-asked once in the same run, even with a one-turn limit, and the run completes")
    instructions = []
    scripted = [replyResponse("{\"reply\":\"Partial", status: "incomplete", reason: "max_output_tokens"), replyResponse("{\"reply\":\"Shorter report\"}")]
    start(healed, runtime: fixer); pump(healed)
    check(instructions.count == 2 && instructions[1].hasSuffix(AgentRunFailure.lengthCorrection) && healed.agent?.lastOutcome == "Completed", "A cut-off reply is re-asked once for a shorter answer")
    instructions = []
    scripted = [replyResponse("not json"), replyResponse("still not json")]
    start(healed, runtime: fixer); pump(healed)
    check(instructions.count == 2 && healed.agent?.enabled == true && healed.agent?.pauseReason == nil && healed.agent?.transientFailures == 1
          && healed.agent?.lastOutcome.contains("invalid action format twice") == true, "A second malformed reply fails the run as transient: the loop stays on")
    healed.agent?.recordSuccess("Completed", attention: nil)

    // Side effects never fail a run: a Discord alert without a token, and a
    // Parking Lot edit naming no allowed lot, are reported; the run succeeds.
    healed.agent?.discord = true; healed.agent?.discordChannelID = "42"
    scripted = [replyResponse("{\"reply\":\"Report with alert\",\"notifyDiscord\":\"Heads up\",\"parkingLotEdits\":{\"revision\":1,\"operations\":[{\"action\":\"add\",\"text\":\"Idea\"}]}}")]
    start(healed, runtime: fixer); pump(healed)
    check(healed.agent?.lastOutcome == "Completed" && healed.agent?.enabled == true && healed.agent?.transientFailures == nil
          && healed.messages.contains { $0.role == "notice" && $0.text.hasPrefix("Discord alert was not sent:") }
          && healed.messages.contains { $0.role == "assistant" && $0.text.hasPrefix("Report with alert") && $0.text.contains("Parking Lot edits were not applied") },
          "Failed Discord alerts and unscoped Parking Lot edits are reported while the run still records success")
    healed.agent?.discord = false

    // Stop current run cancels only the run; the loop stays on.
    let slow = AgentRuntime()
    slow.keyReader = { _ in "isolated-test-key" }
    slow.api.request = { request in
        try await Task.sleep(nanoseconds: 20_000_000_000)
        return (replyResponse("{\"reply\":\"late\"}"), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let stoppable = store.createAgent(title: "Stop run fixture agent")
    stoppable.agent?.enabled = true; stoppable.agent?.turnLimit = 3; stoppable.agent?.generateArt = false
    start(stoppable, runtime: slow)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    slow.stopRun(stoppable)
    pump(stoppable, seconds: 4)
    check(!stoppable.busy && stoppable.agent?.enabled == true && stoppable.agent?.pauseReason == nil && stoppable.agent?.attention == ""
          && stoppable.agent?.lastOutcome == "Run stopped; loop remains on." && !stoppable.interrupted, "Stop current run cancels the in-flight run and leaves the loop on without an alarm")
    start(stoppable, runtime: slow)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    store.pauseAgentLoop(stoppable)
    slow.stopRun(stoppable)
    pump(stoppable, seconds: 4)
    check(!stoppable.busy && stoppable.agent?.enabled == false && stoppable.agent?.lastOutcome == "Run stopped.", "Stop current run on a paused loop leaves it paused")
}
