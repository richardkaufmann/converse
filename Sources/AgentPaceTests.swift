import Foundation

// Prompt caching and token usage.
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
}
