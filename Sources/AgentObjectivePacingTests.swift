import Foundation

// Pacing read from the objective. Fixtures only: no network, no credentials.
@MainActor func agentObjectivePacingSelfTests(_ check: (Bool, String) -> Void) {
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func completed(_ text: String) -> Data {
        let object: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": text]]]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }
    func settle(_ runtime: AgentRuntime, _ session: Session) {
        let end = Date().addingTimeInterval(5)
        while runtime.readingPacing(session) && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-objective-pacing-" + UUID().uuidString)
    let store = Store(folder: root)
    let runtime = AgentRuntime()
    runtime.readsObjectivePacing = true
    runtime.keyReader = { _ in "isolated-test-key" }
    var requests: [URLRequest] = []
    var reply = "{\"runEveryMinutes\": 5, \"artMaxAgeHours\": 12, \"artChangePercent\": 0.5}"
    var replyError: Error?
    runtime.api.request = { request in
        requests.append(request)
        if let replyError { throw replyError }
        return (completed(reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    // Defaults for new agents; older archives keep theirs.
    let fresh = AgentConfig()
    check(fresh.autoPaceOn && fresh.paceMinMinutes == 5 && fresh.paceMaxMinutes == 4320 && fresh.pacingSummary() == "Auto pacing between 5 min and 72 h",
          "New agents default to Auto pacing between 5 minutes and 72 hours")
    if var legacy = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentConfig())) as? [String: Any] {
        for field in ["autoPace", "pacingDefaults"] { legacy.removeValue(forKey: field) }
        let old = try? JSONDecoder().decode(AgentConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(old?.autoPaceOn == false && old?.paceMaxMinutes == 240, "Existing agents keep Auto off and their 4 hour maximum")
        var on = old; try? on?.setAutoPace(true, minMinutes: 5, maxMinutes: 240, now: Date())
        check(on?.autoPaceOn == true && on?.paceMaxMinutes == 240 && on?.autoPaceMaxMinutes == nil, "Turning Auto on for an existing agent keeps its saved maximum")
    } else { check(false, "Existing agents keep Auto off and their 4 hour maximum") }

    // Richard's Meta Stock Agent example, end to end with a fixture response.
    let stock = store.createAgent(title: "Meta Stock Agent")
    stock.agent?.objective = "Track META and the Magnificent Seven. Run the agent every five minutes, and generate new scoreboard art at least every twelve hours or when any stock changes value by more than 0.5%."
    stock.agent?.enabled = true; stock.agent?.turnLimit = 3; stock.agent?.nextRunAt = Date().addingTimeInterval(900)
    let saved = Date()
    runtime.objectiveSaved(stock, store: store, notice: nil)
    check(runtime.readingPacing(stock) && stock.agent?.pacingSummary(extracting: true) == "Reading timing from the objective…", "Saving the objective starts one extraction and says so")
    settle(runtime, stock)
    let body = requests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(requests.count == 1 && requests.first?.url?.path == "/v1/responses" && body?["instructions"] as? String == AgentPacingSpec.instructions
          && (body?["reasoning"] as? [String: Any])?["effort"] as? String == "low" && body?["model"] as? String == stock.agent?.model
          && body?["tools"] == nil && (body?["input"] as? String)?.contains("every five minutes") == true,
          "Extraction asks the agent's own model once at low effort with the strict schema and the objective")
    let spec = stock.agent?.pacingSpec
    check(spec?.runEveryMinutes == 5 && spec?.artMaxAgeHours == 12 && spec?.artChangePercent == 0.5 && spec?.failed == nil
          && stock.agent?.pacingObjectiveHash == AgentPacingSpec.hash(stock.agent?.objective ?? ""), "The extracted spec is stored with the objective's hash")
    check(stock.agent?.effectiveIntervalSeconds == 300 && (try? stock.agent?.scheduleRule())?.kind == .interval && (try? stock.agent?.scheduleRule())?.seconds == 300
          && abs((stock.agent?.nextRunAt ?? .distantFuture).timeIntervalSince(saved) - 300) < 5, "Runs every 5 minutes, rescheduled from the 15 minute default")
    check(stock.agent?.pacingSummary() == "Runs every 5 min", "Summary reads as one plain line; art timing no longer applies because portraits are on demand")
    check(stock.agent?.loopStatus(at: Date(), busy: false, queuePaused: false, pendingCount: 0).hasPrefix("Loop on · every 5 min") == true, "Footer status shows the objective's cadence")
    // Explicit cadence beats the agent's suggestion even with Auto on.
    if var config = stock.agent {
        let now = date("2026-11-04T15:00:00Z"); config.nextRunAt = now.addingTimeInterval(300); config.autoPaceReason = "stale"
        config.applyPace(suggestedMinutes: 60, reason: "quiet", at: now)
        check(config.autoPaceOn && config.autoPaceInstruction == nil && config.nextRunAt == now.addingTimeInterval(300) && config.autoPaceReason == nil,
              "An owner-stated cadence wins over the agent's next-run suggestion")
    }

    // Re-extraction only when the objective text changes.
    runtime.objectiveSaved(stock, store: store, notice: nil); settle(runtime, stock)
    check(requests.count == 1, "Saving an unchanged objective does not ask the model again")
    stock.agent?.objective += " Weekdays only."
    reply = "{\"runEveryMinutes\": 10, \"activeWindow\": {\"days\": \"weekdays\", \"start\": \"09:00\", \"end\": \"17:00\", \"timeZone\": \"America/New_York\"}}"
    runtime.objectiveSaved(stock, store: store, notice: nil); settle(runtime, stock)
    let window = try? stock.agent?.scheduleRule()
    check(requests.count == 2 && window?.kind == .window && window?.weekdays == Set(2...6) && window?.startMinute == 540 && window?.endMinute == 1020 && window?.zoneID == "America/New_York"
          && window?.next(after: date("2026-11-06T22:30:00Z")) == date("2026-11-09T14:00:00Z"), "An edited objective is read again; its window becomes the next allowed time")
    check(stock.agent?.pacingSummary() == "Runs every 10 min on weekdays 09:00–17:00 (America/New_York)", "Summary names the window")
    // A result for an objective edited during extraction is discarded.
    runtime.api.request = { request in
        requests.append(request); await MainActor.run { stock.agent?.objective += " Edited meanwhile." }
        return (completed("{\"runEveryMinutes\": 1}"), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    stock.agent?.objective += " Also NVDA."
    runtime.objectiveSaved(stock, store: store, notice: nil); settle(runtime, stock)
    check(stock.agent?.explicitCadenceMinutes == 10 && stock.agent?.needsPacingExtraction(retryFailed: false) == true, "A stale extraction result never replaces the current objective's timing")
    runtime.api.request = { request in
        requests.append(request)
        if let replyError { throw replyError }
        return (completed(reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    // Fallback when extraction fails or the objective names no timing.
    let quiet = store.createAgent(title: "Quiet agent")
    quiet.agent?.objective = "Summarize release notes."
    replyError = URLError(.timedOut); let before = requests.count
    runtime.objectiveSaved(quiet, store: store, notice: nil); settle(runtime, quiet)
    check(requests.count == before + 1 && quiet.agent?.pacingSpec?.failed == true && quiet.agent?.objectivePacing == nil && quiet.agent?.effectiveIntervalSeconds == quiet.agent?.intervalSeconds
          && quiet.agent?.pacingSummary() == "Auto pacing between 5 min and 72 h · couldn’t read timing from the objective; save it again to retry", "A failed extraction falls back to Auto defaults and says so")
    runtime.objectiveSaved(quiet, store: store, notice: nil); settle(runtime, quiet)
    check(requests.count == before + 1, "A failed extraction is not retried in the background")
    replyError = nil; reply = "{}"
    runtime.objectiveSaved(quiet, store: store, notice: nil, retryFailed: true); settle(runtime, quiet)
    check(requests.count == before + 2 && quiet.agent?.pacingSpec == AgentPacingSpec() && quiet.agent?.pacingSummary() == "Auto pacing between 5 min and 72 h", "Saving again retries; an objective without timing uses Auto defaults")
    reply = "Sorry, I can't help with that."; quiet.agent?.objective += " Weekly."
    runtime.objectiveSaved(quiet, store: store, notice: nil); settle(runtime, quiet)
    check(quiet.agent?.pacingSpec?.failed == true, "Unparseable extraction output is a failure, not a schedule")
    let keyless = AgentRuntime(); keyless.readsObjectivePacing = true; keyless.keyReader = { _ in nil }; var keylessCalls = 0
    keyless.api.request = { _ in keylessCalls += 1; throw URLError(.badURL) }
    quiet.agent?.objective += " Monthly."
    keyless.objectiveSaved(quiet, store: store, notice: nil); settle(keyless, quiet)
    check(keylessCalls == 0 && quiet.agent?.pacingSpec?.failed == true, "Without a Meta key nothing is sent and defaults apply")
    let disabled = AgentRuntime(); var disabledCalls = 0
    disabled.api.request = { _ in disabledCalls += 1; throw URLError(.badURL) }
    quiet.agent?.objective += " Daily."
    disabled.objectiveSaved(quiet, store: store, notice: nil)
    check(disabledCalls == 0 && !disabled.readingPacing(quiet), "Self-test runtimes never call a model for pacing unless a fixture opts in")

    // Untrusted output is clamped or dropped.
    let clamped = AgentPacingSpec.parse("```json\n{\"runEveryMinutes\": 0.2, \"artMaxAgeHours\": 9999, \"artChangePercent\": true, \"artMinIntervalMinutes\": \"1\", \"activeWindow\": {\"days\": \"sometimes\", \"start\": \"25:00\"}}\n```")
    check(clamped?.runEveryMinutes == 1 && clamped?.artMaxAgeHours == 168 && clamped?.artChangePercent == nil && clamped?.artMinIntervalMinutes == 5 && clamped?.activeWindow == nil,
          "Extraction output is clamped to the 1 minute floor and host limits; malformed fields are dropped")
    check(AgentPacingSpec.parse("{\"runEveryMinutes\": 100000}")?.runEveryMinutes == 4320 && AgentPacingSpec.parse("{\"runEveryMinutes\": -5}")?.runEveryMinutes == nil && AgentPacingSpec.parse("not json") == nil,
          "Cadence is capped at 72 hours; negative values and non-JSON are rejected")
    let market = AgentPacingSpec.parse("{\"runEveryMinutes\": 20, \"activeWindow\": {\"days\": \"usMarket\"}}")
    var marketAgent = AgentConfig(); marketAgent.pacingSpec = market
    check((try? marketAgent.scheduleRule())?.kind == .market && marketAgent.pacingSummary() == "Runs every 20 min while the US market is open", "A US market window uses the NYSE calendar")
    var dailyAgent = AgentConfig(); dailyAgent.autoPace = false; dailyAgent.scheduleTimeZone = "UTC"
    dailyAgent.pacingSpec = AgentPacingSpec.parse("{\"activeWindow\": {\"days\": \"weekdays\", \"start\": \"09:00\"}}")
    check((try? dailyAgent.scheduleRule())?.kind == .daily && dailyAgent.pacingSummary() == "Runs weekdays at 09:00 (UTC)", "A start time without an end runs once a day")
    var fixed = AgentConfig(); fixed.autoPace = false
    check(fixed.pacingSummary() == "Runs every 15 min", "With Auto off and no stated cadence the saved interval applies")

    // Numbers on scoreboards.
    let numbers: [(String, Double?)] = [("$1,234.56", 1234.56), ("12.3%", 12.3), ("-0.5", -0.5), ("\u{2212}$12.50", -12.5), ("$-3", -3), ("+2.1%", 2.1), (".5", 0.5),
        ("$612.40 (+1.2%)", 612.4), ("Open", nil), ("Q3 2026", nil), ("—", nil), ("", nil)]
    check(numbers.allSatisfy { AgentMetricNumber.parse($0.0) == $0.1 }, "Scoreboard numbers parse robustly; non-numeric values are skipped")
    check(AgentMetricNumber.moved(from: ["A": 0], to: ["A": 1], percent: 0.5) && !AgentMetricNumber.moved(from: [:], to: ["A": 1], percent: 0.5) && AgentMetricNumber.moved(from: ["A": -10], to: ["A": -10.1], percent: 0.5),
          "Percent moves handle zero, new metrics and negative values")

    // Text schedules move into the objective: archive and wire.
    let legacyStore = Store(folder: FileManager.default.temporaryDirectory.appendingPathComponent("converse-schedule-migration-" + UUID().uuidString))
    let legacy = legacyStore.createAgent(title: "Legacy market agent")
    legacy.agent?.objective = "Track META."; legacy.agent?.scheduleText = "every 20 minutes while the US stock market is open"; legacy.agent?.scheduleTimeZone = "America/New_York"
    legacy.agent?.enabled = true
    try? legacyStore.saveChecked()
    let reloadStore = Store(folder: legacyStore.folder)
    let reloaded = reloadStore.sessions.first { $0.id == legacy.id }
    check(reloaded?.agent?.objective == "Track META.\nSchedule: every 20 minutes while the US stock market is open" && reloaded?.agent?.scheduleText == nil && reloaded?.agent?.pacingPending == true
          && reloaded?.messages.last?.role == "notice" && reloaded?.messages.last?.text.contains("moved into this agent’s objective") == true, "An archived text schedule moves into the objective once, with a transcript notice")
    check((try? reloaded?.agent?.scheduleRule())?.kind == .market && reloaded?.agent?.pacingSummary() == "Runs every 20 minutes while the US stock market is open",
          "A migrated schedule keeps running on its market calendar before the model reads it")
    try? reloadStore.saveChecked()
    let again = Store(folder: legacyStore.folder).sessions.first { $0.id == legacy.id }
    check(again?.messages.filter { $0.text.contains("moved into this agent’s objective") }.count == 1 && again?.agent?.objective.components(separatedBy: "Schedule:").count == 2, "Migration happens only once")
    var remote = AgentConfig(); remote.objective = "Watch CI."
    var wire = remote.wire(home: "local"); wire.scheduleText = "every 2 hours on weekdays between 9am and 5pm"
    let notice = try? remote.apply(wire)
    check(notice != nil && remote.objective == "Watch CI.\nSchedule: every 2 hours on weekdays between 9am and 5pm" && remote.scheduleText == nil && remote.wire(home: "local").scheduleText == "",
          "A remote editor's text schedule is migrated the same way")
    wire = remote.wire(home: "local"); wire.scheduleText = "daily at 09:00"
    _ = try? remote.apply(wire)
    check(remote.objective == "Watch CI.\nSchedule: daily at 09:00", "A later remote schedule replaces the migrated line instead of stacking")
    wire = remote.wire(home: "local")
    check((try? remote.apply(wire)) == .some(nil), "Current editors send no text schedule and see no notice")
    let loopStore = Store(folder: FileManager.default.temporaryDirectory.appendingPathComponent("converse-loop-migration-" + UUID().uuidString))
    let loopAgent = loopStore.createAgent(title: "Loop controls agent")
    do {
        try loopStore.configureAgentLoop(loopAgent, enabled: true, interval: 900, turns: 2, scoreboardEvery: 1, scheduleText: "every 30 minutes", scheduleTimeZone: "UTC")
        check(loopAgent.agent?.scheduleText == nil && loopAgent.agent?.objective.hasSuffix("\nSchedule: every 30 minutes") == true && (try? loopAgent.agent?.scheduleRule())?.seconds == 1800
              && loopAgent.messages.last?.text.contains("moved into this agent’s objective") == true, "Older loop-control callers' schedules migrate too")
    } catch { check(false, "Older loop-control callers' schedules migrate too: " + error.localizedDescription) }
}
