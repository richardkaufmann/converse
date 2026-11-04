import Foundation

// Prompt caching, auto loop pacing, art throttle and API-key footer label.
// Fixtures only: no network, no credentials.
@MainActor func agentPaceSelfTests(_ check: (Bool, String) -> Void) {
    func settle<T>(_ operation: @escaping @MainActor () async throws -> T) -> Result<T, Error>? {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await operation()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(3)
        while result == nil && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return result
    }
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // 1. Prompt caching: a byte-identical static prefix across activations.
    let attachmentID = UUID().uuidString
    let first = AgentInstructions.build(objective: "Track the release", parkingLotRequiresReview: false, artDirection: nil, supportTeaching: nil,
        webSearchAvailable: true, voiceTurn: true, omittedAttachments: ["Image 1 attached to user message " + attachmentID + " (unavailable)"])
    let second = AgentInstructions.build(objective: "Track the release", parkingLotRequiresReview: true, artDirection: "Moonbase", autoPace: "Auto pacing is on",
        supportTeaching: "Support teaching", webSearchAvailable: false, voiceTurn: false, omittedAttachments: [])
    let shared = zip(first.utf8, second.utf8).prefix { $0 == $1 }.count
    let staticBytes = AgentInstructions.staticRules.utf8.count
    check(staticBytes > 8000 && shared >= staticBytes && first.hasPrefix(AgentInstructions.staticRules) && second.hasPrefix(AgentInstructions.staticRules),
          "Agent instructions keep the long static rules block byte-identical across voice, web-search, attachment and setting changes")
    let rules = AgentInstructions.staticRules
    let timeVarying = rules.range(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-|[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}:[0-9]{2}", options: .regularExpression)
    check(timeVarying == nil && !rules.contains("Objective: ") && !rules.contains("Web search is ") && !rules.contains(AgentInstructions.voiceTurn) && !rules.contains("Unavailable older attachments") && !rules.contains("Art direction from the owner"),
          "Static instruction prefix contains no IDs, dates, times, objective or per-activation lines")
    check([AgentPolicy.objectiveGoverns, AgentPolicy.scoreboardScope, ParkingLotStore.placementGuidance, "Return ONE JSON object with:", "Make the art fit sentiment"].allSatisfy(rules.contains)
          && first.contains(AgentInstructions.voiceTurn) && first.contains("Web search is available.") && first.contains(attachmentID) && !first.contains(AgentInstructions.parkingLotReview)
          && second.contains("Web search is unavailable for this activation; use only supplied evidence.") && second.contains(AgentInstructions.parkingLotReview) && second.contains("Support teaching")
          && second.contains("Art direction from the owner (apply to artwork only): Moonbase") && second.contains("Auto pacing is on") && second.contains("Unavailable older attachments: none."),
          "Reordered instructions keep every rule and variable line")
    if let objective = second.range(of: "Objective: "), let teaching = second.range(of: "Support teaching"), let voice = first.range(of: AgentInstructions.voiceTurn), let objectiveFirst = first.range(of: "Objective: ") {
        check(objective.lowerBound < teaching.lowerBound && objectiveFirst.lowerBound < voice.lowerBound, "Per-agent settings precede per-activation lines")
    } else { check(false, "Per-agent settings precede per-activation lines") }

    let api = AgentAPI()
    var bodies: [[String: Any]] = []
    var replies: [(Int, String)] = []
    api.request = { request in
        bodies.append(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:])
        let (status, text) = replies.isEmpty ? (200, "{}") : replies.removeFirst()
        return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    let completed = "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"{\\\"reply\\\":\\\"ok\\\"}\"}]}],\"usage\":{\"input_tokens\":10000,\"input_tokens_details\":{\"cached_tokens\":8000},\"output_tokens\":500}}"
    let key = AgentInstructions.cacheKey(UUID())
    replies = [(200, completed)]
    var diagnostic: AgentResponseDiagnostic?
    let cached = settle { try await api.respond(model: "muse-spark-1.3", instructions: first, input: "{}", key: "fixture-key", cacheKey: key, observe: { diagnostic = $0 }) }
    check((try? cached?.get()) == "{\"reply\":\"ok\"}" && bodies.count == 1 && bodies[0]["prompt_cache_key"] as? String == key && bodies[0]["prompt_cache_retention"] as? String == "24h" && key.hasPrefix("converse-agent-"),
          "Agent Responses body carries a stable per-agent prompt_cache_key and 24h retention")
    check(diagnostic?.cachedTokens == 8000 && diagnostic?.usage.cachedPercent == 80 && diagnostic?.usage.label.contains("cached 80% of input") == true && diagnostic?.usage.label.contains("500 out") == true,
          "Responses usage parsing records input, cached and output tokens and shows the cached percentage")
    check(AgentUsage(response: [:]).label == "not reported" && AgentUsage(input: 0, cached: 0, output: 1).cachedPercent == nil && AgentUsage(input: 100, cached: 150, output: 1).cachedPercent == 100
          && AgentUsage(input: 1000, cached: nil, output: 9).label.contains("cached") == false, "Cached percent tolerates missing, zero and inconsistent counts")
    bodies = []; replies = [(200, completed)]
    _ = settle { try await api.respond(model: "muse-spark-1.3", instructions: "i", input: "{}", key: "fixture-key") }
    check(bodies.first?["prompt_cache_key"] == nil && bodies.first?["prompt_cache_retention"] == nil, "Callers without a cache key send an unchanged Responses body")

    bodies = []; replies = [(400, "{\"error\":{\"message\":\"Unknown parameter: 'prompt_cache_retention'. private-canary\"}}"), (200, completed)]
    let retried = settle { try await api.respond(model: "muse-spark-1.3", instructions: "i", input: "{}", key: "fixture-key", cacheKey: key) }
    check((try? retried?.get()) == "{\"reply\":\"ok\"}" && bodies.count == 2 && bodies[0]["prompt_cache_key"] != nil && bodies[1]["prompt_cache_key"] == nil && bodies[1]["prompt_cache_retention"] == nil && bodies[1]["instructions"] as? String == "i" && !api.sendsPromptCache,
          "A 400 naming the prompt cache fields retries once without them")
    bodies = []; replies = [(200, completed)]
    _ = settle { try await api.respond(model: "muse-spark-1.3", instructions: "i", input: "{}", key: "fixture-key", cacheKey: key) }
    check(bodies.count == 1 && bodies[0]["prompt_cache_key"] == nil, "After a rejection the client stops sending prompt cache fields")
    let strict = AgentAPI(); var strictCount = 0
    strict.request = { request in strictCount += 1; return (Data("{\"error\":\"bad input private-canary\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!) }
    let failed = settle { try await strict.respond(model: "muse-spark-1.3", instructions: "i", input: "{}", key: "fixture-key", cacheKey: key) }
    if case .failure(let error)? = failed {
        check(strictCount == 1 && error.localizedDescription.contains("400") && !error.localizedDescription.contains("private-canary") && strict.sendsPromptCache, "Other 400 errors are not retried and never expose the response body")
    } else { check(false, "Other 400 errors are not retried and never expose the response body") }

    // 2. Auto pacing.
    let now = date("2026-11-04T15:00:00Z")
    // An agent saved before objective pacing: Auto off, 4 hour maximum.
    var paced = AgentConfig(); paced.autoPace = nil; paced.pacingDefaults = nil
    paced.enabled = true; paced.turnLimit = 2; paced.intervalSeconds = 900; paced.nextRunAt = now.addingTimeInterval(900)
    var off = paced; off.applyPace(suggestedMinutes: 30, reason: "busy", at: now)
    check(off == paced && paced.autoPaceInstruction == nil && !AgentInstructions.build(objective: "o", parkingLotRequiresReview: false, artDirection: nil, autoPace: paced.autoPaceInstruction, supportTeaching: nil, webSearchAvailable: true, voiceTurn: false, omittedAttachments: []).contains("nextRunInMinutes"),
          "Auto pacing off (older agents): suggestions are ignored and the instruction is absent")
    paced.autoPace = true
    check(paced.autoPaceInstruction?.contains("nextRunInMinutes") == true && paced.autoPaceInstruction?.contains("between 5 and 240 minutes") == true, "Auto pacing instruction appears only when on, with the owner's bounds")
    var clamp = paced; clamp.applyPace(suggestedMinutes: 20, reason: "release in progress", at: now)
    check(clamp.nextRunAt == now.addingTimeInterval(1200) && clamp.autoPaceReason == "release in progress", "Auto pacing applies an in-bounds suggestion")
    clamp.applyPace(suggestedMinutes: 1, reason: nil, at: now)
    let low = clamp.nextRunAt
    clamp.applyPace(suggestedMinutes: 10000, reason: String(repeating: "x", count: 90), at: now)
    check(low == now.addingTimeInterval(300) && clamp.nextRunAt == now.addingTimeInterval(240 * 60) && clamp.autoPaceReason?.count == 60, "Auto pacing clamps to the minimum and maximum and bounds the reason")
    var custom = paced; custom.autoPaceMinMinutes = 15; custom.autoPaceMaxMinutes = 60
    custom.applyPace(suggestedMinutes: 5, reason: "x", at: now)
    check(custom.nextRunAt == now.addingTimeInterval(900), "Auto pacing honors owner-set bounds")
    for invalid in [nil, 0, -5, Double.nan, Double.infinity] as [Double?] {
        var fallback = paced; fallback.autoPaceReason = "stale"
        fallback.applyPace(suggestedMinutes: invalid, reason: "ignored", at: now)
        check(fallback.nextRunAt == now.addingTimeInterval(900) && fallback.autoPaceReason == nil, "Missing or invalid suggestion keeps the configured interval: \(String(describing: invalid))")
    }
    var window = paced; window.scheduleText = "every 30 minutes on weekdays between 9am and 5pm"; window.scheduleTimeZone = "America/New_York"
    let lateFriday = date("2026-11-06T21:30:00Z") // 16:30 New York, Friday
    window.applyPace(suggestedMinutes: 120, reason: "quiet", at: lateFriday)
    check(window.nextRunAt == date("2026-11-09T14:00:00Z"), "Auto pacing never runs outside the schedule window; it waits for the next window open")
    window.applyPace(suggestedMinutes: 10, reason: "busy", at: date("2026-11-06T15:00:00Z"))
    check(window.nextRunAt == date("2026-11-06T15:10:00Z"), "Auto pacing chooses a time inside an open schedule window")
    var daily = paced; daily.scheduleText = "daily at 09:00"; daily.scheduleTimeZone = "UTC"; daily.nextRunAt = date("2026-11-05T09:00:00Z")
    daily.applyPace(suggestedMinutes: 10, reason: "x", at: now)
    check(daily.nextRunAt == date("2026-11-05T09:00:00Z"), "Daily schedules keep their fixed time")
    var paused = paced; paused.enabled = false; paused.applyPace(suggestedMinutes: 10, reason: "x", at: now)
    var exhausted = paced; exhausted.turnLimit = 0; exhausted.applyPace(suggestedMinutes: 10, reason: "x", at: now)
    check(paused.nextRunAt == paced.nextRunAt && exhausted.nextRunAt == paced.nextRunAt && !paused.due(at: now.addingTimeInterval(600)) && !exhausted.due(at: now.addingTimeInterval(600)),
          "Auto pacing never schedules a paused loop or one without a turn budget")
    var reserved = clamp; reserved.nextRunAt = now.addingTimeInterval(300)
    check(!reserved.reserveRun(at: now.addingTimeInterval(299)) && reserved.reserveRun(at: now.addingTimeInterval(300)) && !reserved.reserveRun(at: now.addingTimeInterval(300)),
          "An auto-paced deadline is reserved exactly once like a scheduled one")
    clamp.applyPace(suggestedMinutes: 20, reason: "release in progress", at: now)
    check(clamp.loopStatus(at: now, busy: false, queuePaused: false, pendingCount: 0) == "Auto · next in 20 min (release in progress)", "Footer shows auto pacing with the agent's reason")
    clamp.autoPaceReason = nil; clamp.nextRunAt = now.addingTimeInterval(125 * 60)
    check(clamp.loopStatus(at: now, busy: false, queuePaused: false, pendingCount: 0) == "Auto · next in 2 hr 5 min" && clamp.loopStatus(at: now, busy: false, queuePaused: true, pendingCount: 0) == "Loop on · queue paused"
          && clamp.loopStatus(at: now.addingTimeInterval(125 * 60), busy: true, queuePaused: false, pendingCount: 0) == "Auto · next check after this run", "Auto status covers fallback, queue pause and running states")
    var stopped = clamp; stopped.enabled = false
    check(stopped.loopStatus(at: now, busy: false, queuePaused: false, pendingCount: 0) == "Loop paused · automatic checks off", "Paused loop status is unchanged by auto pacing")
    let fixed = AgentConfig()
    check(fixed.loopStatus(at: now, busy: false, queuePaused: false, pendingCount: 0) == "Loop paused · automatic checks off", "Default agent status is unchanged")
    do {
        var setup = paced; setup.autoPace = nil; setup.nextRunAt = now.addingTimeInterval(900)
        try setup.setAutoPace(true, minMinutes: 10, maxMinutes: 60, now: now)
        check(setup.autoPaceOn && setup.paceMinMinutes == 10 && setup.paceMaxMinutes == 60 && setup.nextRunAt == now.addingTimeInterval(900), "Turning auto pacing on keeps the scheduled deadline")
        setup.nextRunAt = now.addingTimeInterval(240 * 60); setup.autoPaceReason = "quiet"
        try setup.setAutoPace(false, minMinutes: 5, maxMinutes: 240, now: now)
        check(!setup.autoPaceOn && setup.autoPace == false && setup.autoPaceMinMinutes == nil && setup.autoPaceReason == nil && setup.nextRunAt == now.addingTimeInterval(900), "Turning auto pacing off returns to the configured interval")
        for (low, high) in [(0.0, 60.0), (30, 10), (5, 20000), (Double.nan, 60)] {
            do { try setup.setAutoPace(true, minMinutes: low, maxMinutes: high, now: now); check(false, "Invalid auto pacing bounds rejected") } catch { check(true, "Invalid auto pacing bounds rejected: \(low)–\(high)") }
        }
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentConfig())) as! [String: Any]
        for field in ["autoPace", "pacingDefaults", "autoPaceMinMinutes", "autoPaceMaxMinutes", "autoPaceReason", "artMinIntervalMinutes", "artMaxStaleHours", "lastArtScoreboard"] { legacy.removeValue(forKey: field) }
        let decoded = try JSONDecoder().decode(AgentConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(!decoded.autoPaceOn && decoded.paceMinMinutes == 5 && decoded.paceMaxMinutes == 240 && decoded.artMinMinutes == 30 && decoded.artStaleHours == 6, "Older agent archives decode with auto pacing off and default art throttle")
        var saved = paced; saved.autoPaceReason = "watching CI"; saved.autoPaceMaxMinutes = 90; saved.artMinIntervalMinutes = 60; saved.lastArtScoreboard = AgentScoreboard(summary: "", metrics: [], sentiment: "up")
        check(try JSONDecoder().decode(AgentConfig.self, from: JSONEncoder().encode(saved)) == saved, "Auto pacing and art throttle settings survive persistence")
        var remote = saved.wire(home: "local"); remote.objective = "Edited elsewhere"
        try saved.apply(remote)
        check(saved.autoPaceOn && saved.paceMaxMinutes == 90 && saved.artMinMinutes == 60, "Older remote editors preserve auto pacing and art throttle settings")
    } catch { check(false, "Auto pacing settings: " + error.localizedDescription) }
    let lenient = AgentReply.decode("{\"reply\":\"r\",\"nextRunInMinutes\":\"soon\",\"paceReason\":7}")
    let numeric = AgentReply.decode("{\"reply\":\"r\",\"nextRunInMinutes\":\"45\",\"paceReason\":\"CI running\"}")
    check(lenient?.reply == "r" && lenient?.nextRunInMinutes?.value == nil && lenient?.paceReason?.value == nil && numeric?.nextRunInMinutes?.value == 45 && numeric?.paceReason?.value == "CI running"
          && AgentReply.decode("{\"reply\":\"r\"}")?.nextRunInMinutes == nil, "Malformed pacing fields never invalidate an agent reply")

    // 3. Art throttle.
    func board(_ metrics: [(String, String)], sentiment: String = "up", asOf: String = "10:00 ET", url: String = "https://example.invalid/a") -> AgentScoreboard {
        AgentScoreboard(title: "T", summary: "s", metrics: metrics.map { .init(label: $0.0, value: $0.1, sourceURL: url, asOf: asOf) }, sentiment: sentiment)
    }
    let base = board([("Price", "$10"), ("Bugs", "3")])
    check(!AgentArtPolicy.scoreboardChanged(from: AgentArtPolicy.signature(base), to: board([("Price", "$10"), ("Bugs", "3")], asOf: "11:00 ET", url: "https://example.invalid/b")),
          "Art ignores asOf and source URL changes")
    check(AgentArtPolicy.scoreboardChanged(from: base, to: board([("Price", "$11"), ("Bugs", "3")])) && AgentArtPolicy.scoreboardChanged(from: base, to: board([("Price", "$10")]))
          && AgentArtPolicy.scoreboardChanged(from: base, to: board([("Price", "$10"), ("Bugs", "3"), ("Stars", "4")])) && AgentArtPolicy.scoreboardChanged(from: base, to: board([("Price", "$10"), ("Bugs", "3")], sentiment: "down"))
          && AgentArtPolicy.scoreboardChanged(from: nil, to: base) && !AgentArtPolicy.scoreboardChanged(from: nil, to: nil) && !AgentArtPolicy.scoreboardChanged(from: base, to: board([("Bugs", "3"), ("Price", "$10")])),
          "Art treats changed values, added/removed metrics and sentiment as meaningful; metric order is not")
    let last = now.addingTimeInterval(-600)
    func decide(age: TimeInterval, direction: Bool = false, mood: Bool = false, board: Bool = false, lastArt: Date?? = nil) -> Bool {
        AgentArtPolicy.shouldRegenerate(now: now, lastArtAt: lastArt ?? now.addingTimeInterval(-age), directionChanged: direction, moodChanged: mood, scoreboardChanged: board, minInterval: 1800, maxStale: 21600)
    }
    check(decide(age: 0, lastArt: .some(nil)), "First art is generated immediately")
    check(decide(age: 60, direction: true), "Edited art direction regenerates immediately")
    check(!decide(age: 600, mood: true) && !decide(age: 600, board: true) && decide(age: 1800, mood: true) && decide(age: 1800, board: true), "Mood or scoreboard changes wait for the minimum interval")
    check(!decide(age: 1800) && !decide(age: 21599) && decide(age: 21600), "Unchanged art refreshes only at the maximum staleness")
    var throttled = AgentConfig(); throttled.lastArtAt = last; throttled.lastArtMood = "up"; throttled.lastArtScoreboard = AgentArtPolicy.signature(base)
    check(!throttled.shouldRegenerateArt(mood: "down", board: base, now: now) && throttled.shouldRegenerateArt(mood: "down", board: base, now: now.addingTimeInterval(1200)), "Agent art uses the default 30 minute minimum")
    throttled.artDirection = "Moonbase"
    check(throttled.shouldRegenerateArt(mood: "up", board: base, now: now), "Agent art regenerates for an art direction edit inside the minimum")
    do {
        try throttled.setArtThrottle(minMinutes: 60, maxStaleHours: 12)
        check(throttled.artMinMinutes == 60 && throttled.artStaleHours == 12, "Art throttle settings are configurable")
        for (low, high) in [(1.0, 6.0), (60, 0.5), (600, 2), (30, 500)] {
            do { try throttled.setArtThrottle(minMinutes: low, maxStaleHours: high); check(false, "Invalid art throttle rejected") } catch { check(true, "Invalid art throttle rejected: \(low) min / \(high) hr") }
        }
    } catch { check(false, "Art throttle settings: " + error.localizedDescription) }

    // 4. API-key footer label.
    check(AgentModels.apiKeyAccount("muse-spark-1.3")?.label == "API Key" && AgentModels.apiKeyAccount("muse-spark-1.3")?.help == "API key — no account info available"
          && AgentModels.apiKeyAccount(AgentModels.reference(engine: "claude", account: "a")) == nil && AgentModels.apiKeyAccount(nil) == nil,
          "API-key agents show API Key in the footer; CLI-login agents keep account status")
    let footerStore = Store(folder: FileManager.default.temporaryDirectory.appendingPathComponent("converse-footer-" + UUID().uuidString))
    let footerAgent = footerStore.createAgent(title: "Footer fixture", persist: false)
    check(footerStore.sessionLoginLabel(footerAgent) == "API Key", "Session login label names the API key for Meta API agents")
}
