import Foundation

// Transient failures retry; repeated or permanent ones pause with a reason
// that later manual runs cannot hide. Fixtures only: no network.
@MainActor func agentRetrySelfTests(_ check: (Bool, String) -> Void) {
    let now = ISO8601DateFormatter().date(from: "2026-11-04T15:00:00Z")!
    // Classification.
    let transient: [Error] = [URLError(.timedOut), URLError(.networkConnectionLost), URLError(.notConnectedToInternet), URLError(.cannotConnectToHost),
        NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), AgentFailure.message("api.meta.ai returned HTTP 503."), AgentFailure.message("api.meta.ai returned HTTP 429."),
        AgentFailure.message("api.meta.ai returned HTTP 500."), AgentFailure.message("The request timed out."), AgentFailure.message("Provider timed out; no actions applied."),
        AgentFailure.message("The model is overloaded. Please retry.")]
    check(transient.allSatisfy { AgentRunFailure.classify($0) == .transient }, "Timeouts, lost networks, HTTP 429/5xx and overloaded providers are transient")
    let permanent: [Error] = [AgentFailure.message("Meta rejected the API key (HTTP 401). Check or replace it in Agent Setup."),
        AgentFailure.message("Add a Meta API key or choose a logged-in provider in Agent Setup."), AgentFailure.message("This activation reached its turn limit. The next scheduled loop gets a fresh limit."),
        AgentFailure.message("No future run is available. Review the schedule/calendar."), AgentFailure.message("Invalid agent settings. Check scope, interval and run budget."),
        AgentFailure.message("GitHub denied access or reached its rate limit (HTTP 403). Check token permissions or try again later."),
        AgentFailure.message("Agent returned an invalid action format. No actions applied; loop paused."), AgentFailure.message("api.meta.ai returned HTTP 400."),
        AgentFailure.message("Provider request failed. Check the selected login in Setup; no actions applied."), URLError(.userAuthenticationRequired)]
    check(permanent.allSatisfy { AgentRunFailure.classify($0) == .permanent }, "Missing or rejected keys, invalid settings, budgets, schedules and HTTP 4xx are permanent")
    check(AgentRunFailure.classify(CancellationError()) == .cancelled && AgentRunFailure.classify(URLError(.cancelled)) == .cancelled, "Cancellation is neither transient nor a permanent failure")

    // Counter, retry banner and pause after three in a row.
    var loop = AgentConfig(); loop.enabled = true; loop.turnLimit = 3
    loop.recordFailure("The request timed out.", kind: .transient, countsForLoop: true, at: now)
    check(loop.enabled && loop.transientFailures == 1 && loop.attention == "Retrying: The request timed out. (1 of 3)" && loop.lastOutcome == loop.attention && loop.pauseReason == nil,
          "A first transient failure keeps the loop on and shows a retry count")
    loop.recordFailure("The request timed out.", kind: .transient, countsForLoop: true, at: now)
    check(loop.enabled && loop.transientFailures == 2 && loop.attention.hasSuffix("(2 of 3)"), "A second transient failure still retries at the next tick")
    var reset = loop
    reset.recordSuccess("Completed", attention: nil)
    check(reset.enabled && reset.transientFailures == nil && reset.attention.isEmpty && reset.lastOutcome == "Completed", "A success resets the counter and clears the retry banner")
    reset.recordFailure("The request timed out.", kind: .transient, countsForLoop: true, at: now)
    check(reset.enabled && reset.transientFailures == 1, "After a success the count starts again at one")
    loop.recordFailure("The request timed out.", kind: .transient, countsForLoop: true, at: now)
    let stamp = AgentRunFailure.stamp(now)
    check(!loop.enabled && loop.transientFailures == nil && loop.pauseReason == "Paused: The request timed out. — failed 3 times in a row (" + stamp + ")"
          && loop.attention == loop.pauseReason && loop.lastOutcome == loop.pauseReason, "The third consecutive transient failure pauses the loop with a clear reason and time")
    var hard = AgentConfig(); hard.enabled = true
    hard.recordFailure("Meta rejected the API key (HTTP 401).", kind: .permanent, countsForLoop: true, at: now)
    check(!hard.enabled && hard.pauseReason?.hasPrefix("Paused: Meta rejected the API key") == true, "Permanent failures pause immediately")
    var publicTurn = AgentConfig(); publicTurn.enabled = true
    publicTurn.recordFailure("Meta rejected the API key (HTTP 401).", kind: .permanent, countsForLoop: false, at: now)
    check(publicTurn.enabled && publicTurn.pauseReason == nil && publicTurn.lastOutcome.hasPrefix("Stopped:"), "Public Discord turns never pause the loop")

    // A later manual, Jolly or Discord run keeps the pause reason visible.
    var paused = loop
    paused.recordSuccess("Completed", attention: "")
    check(!paused.enabled && paused.lastOutcome == loop.pauseReason && paused.attention == loop.pauseReason, "A later completed run cannot erase why the loop is paused")
    paused.recordSuccess("Discord reply completed", attention: "Price feed lagging")
    check(paused.lastOutcome == loop.pauseReason && paused.attention == loop.pauseReason! + " · Price feed lagging", "New attention is added after the pause reason")
    paused.recordFailure("Discord response was incomplete.", kind: .permanent, countsForLoop: true, at: now)
    check(paused.pauseReason == loop.pauseReason && paused.attention.hasPrefix(loop.pauseReason!) && paused.attention.contains("Discord response was incomplete"), "A later failed run keeps the original pause reason first")

    // Store paths: clear banner, Setup saves and re-enable.
    let store = Store(folder: FileManager.default.temporaryDirectory.appendingPathComponent("converse-retry-" + UUID().uuidString))
    let agent = store.createAgent(title: "Retry fixture agent")
    agent.agent?.enabled = true
    agent.agent?.pause("The request timed out. — failed 3 times in a row", at: now)
    do { try store.configureAgentLoop(agent, enabled: false, interval: 900, turns: 3, scoreboardEvery: 1) } catch { check(false, "Retry fixture setup save") }
    check(agent.agent?.pauseReason != nil && agent.pausedLoopReason == agent.agent?.pauseReason, "Saving other settings with the loop still off keeps the pause reason")
    store.clearAgentAttention(agent)
    check(agent.agent?.pauseReason == nil && agent.agent?.attention == "", "Clear attention banner ends the recorded pause")
    agent.agent?.recordSuccess("Completed", attention: nil)
    check(agent.agent?.lastOutcome == "Completed", "After clearing, later runs report normally")
    agent.agent?.enabled = true; agent.agent?.pause("Meta rejected the API key (HTTP 401).", at: now)
    do { try store.configureAgentLoop(agent, enabled: true, interval: 900, turns: 3, scoreboardEvery: 1) } catch { check(false, "Retry fixture re-enable") }
    check(agent.agent?.enabled == true && agent.agent?.pauseReason == nil && agent.agent?.transientFailures == nil, "Re-enabling the loop clears the pause reason and counter")
    agent.agent?.enabled = false; agent.agent?.pause("The request timed out.", at: now)
    if var wire = agent.agent?.wire(home: "local") {
        wire.enabled = true
        do { try agent.agent?.apply(wire) } catch { check(false, "Remote re-enable: " + error.localizedDescription) }
        check(agent.agent?.enabled == true && agent.agent?.pauseReason == nil, "A remote editor re-enabling the loop clears the pause reason")
    }
    if let config = agent.agent, let restored = try? JSONDecoder().decode(AgentConfig.self, from: JSONEncoder().encode({ var c = config; c.transientFailures = 2; c.pauseReason = "Paused: x"; return c }())) {
        check(restored.transientFailures == 2 && restored.pauseReason == "Paused: x", "Retry count and pause reason survive archive reload")
    } else { check(false, "Retry count and pause reason survive archive reload") }

    // End to end: a timed-out loop run keeps the loop on.
    let runtime = AgentRuntime()
    runtime.keyReader = { _ in "isolated-test-key" }
    runtime.api.request = { _ in throw URLError(.timedOut) }
    let looping = store.createAgent(title: "Timeout fixture agent")
    looping.agent?.enabled = true; looping.agent?.turnLimit = 3; looping.agent?.generateArt = false
    for attempt in 1...3 {
        looping.busy = true
        let id = UUID(); looping.messages.append(Message(id: id, role: "assistant", text: ""))
        runtime.run(looping, store: store, responseID: id, loopTick: true)
        let deadline = Date().addingTimeInterval(8)
        while looping.busy && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if attempt < 3 {
            check(looping.agent?.enabled == true && looping.agent?.transientFailures == attempt && looping.agent?.attention.hasPrefix("Retrying: ") == true
                  && looping.messages.last?.role == "notice", "Timed-out loop run \(attempt) keeps the loop on and leaves a transcript notice")
        } else {
            check(looping.agent?.enabled == false && looping.agent?.pauseReason?.contains("failed 3 times in a row") == true && looping.pausedLoopReason == looping.agent?.pauseReason,
                  "The third timed-out loop run pauses with the reason shown on the paused row")
        }
    }
}
