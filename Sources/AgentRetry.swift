import Foundation

// A loop must survive hiccups. Only problems the human must fix pause it at
// once: rejected or missing credentials, a spent turn limit or run budget, an
// invalid schedule or settings, and the human's own Stop. A malformed model
// reply is re-asked once within the run. Everything else, including unknown
// errors, is transient: the loop stays on and backs off (1, 2, 4, 8 minutes…
// capped at its interval); from the third failure in a row a banner says it
// is having trouble, and the next success clears it.
// Mirrored in windows/src/Converse.Core/AgentRuntime.cs (AgentRunFailure).
enum AgentRunFailure {
    enum Kind: Equatable { case transient, model, permanent, cancelled }
    static let troubleAfter = 3
    static let retryPrefix = "Retrying: "
    static let troublePrefix = "Having trouble since "
    static let formatCorrection = "Your previous reply was not one valid JSON object. Return the same answer as exactly one JSON object."
    static let lengthCorrection = "Your previous reply was cut off before it finished. Return a shorter answer as exactly one JSON object."
    static let transientURLCodes: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .callIsActive, .dataNotAllowed, .resourceUnavailable, .badServerResponse]
    static let permanentURLCodes: Set<URLError.Code> = [.userAuthenticationRequired, .userCancelledAuthentication, .clientCertificateRequired, .clientCertificateRejected]
    static func classify(_ error: Error) -> Kind {
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError { return url.code == .cancelled ? .cancelled : permanentURLCodes.contains(url.code) ? .permanent : .transient }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return classify(URLError(URLError.Code(rawValue: ns.code))) }
        return classify(message: error.localizedDescription)
    }
    // Host messages are fixed strings (bodies are never surfaced), so plain
    // text is a safe signal. The permanent list is deliberately narrow.
    static let permanentMarkers = ["http 401", "http 403", "api key", "rejected the", "denied", "bot token", "token missing", "add a ",
        "turn limit", "run budget", "schedule/calendar", "saved schedule", "no future run", "invalid agent settings", "invalid provider selection",
        "choose a model", "no longer enabled", "paused by stop"]
    static let modelMarkers = ["invalid action format", "stopped before completion", "response limit", "max_output_tokens",
        "did not return a completed final response", "returned no answer", "response did not complete", "reply is missing"]
    static func classify(message: String) -> Kind {
        let text = message.lowercased()
        if permanentMarkers.contains(where: text.contains) { return .permanent }
        if modelMarkers.contains(where: text.contains) { return .model }
        return .transient
    }
    // The one corrective re-ask for a model-output failure.
    static func correction(for message: String) -> String {
        let text = message.lowercased()
        return text.contains("response limit") || text.contains("max_output_tokens") || text.contains("stopped before completion") ? lengthCorrection : formatCorrection
    }
    // Seconds before retry n (1-based): 1, 2, 4, 8… minutes, capped at the loop interval.
    static func backoff(failures: Int, interval: TimeInterval) -> TimeInterval {
        let cap = interval.isFinite ? max(60, interval) : 900
        return min(cap, 60 * pow(2, Double(min(30, max(0, failures - 1)))))
    }
    static func stamp(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
    static func trouble(since: Date, reason: String, tries: Int) -> String {
        String((troublePrefix + stamp(since) + ": " + reason + " — still retrying (\(tries) tries)").prefix(1000))
    }
}

extension AgentConfig {
    // Records a failed run. countsForLoop is false for public Discord turns
    // and interrupted turns that will resume: they never pause the loop.
    mutating func recordFailure(_ message: String, kind: AgentRunFailure.Kind, countsForLoop: Bool, at now: Date) {
        guard countsForLoop, enabled, kind != .cancelled else {
            if countsForLoop && kind == .cancelled { enabled = false }
            attention = message; lastOutcome = "Stopped: " + message
            preservePause(); return
        }
        guard kind == .permanent else { retryLater(message, at: now); return }
        pause(message, at: now)
    }
    // A transient failure keeps the loop on and brings its next check forward
    // to the back-off deadline; it never pauses.
    mutating func retryLater(_ message: String, at now: Date) {
        let count = min(1_000_000, max(0, transientFailures ?? 0) + 1)
        transientFailures = count
        let since = troubleSince ?? now
        troubleSince = since
        let retry = now.addingTimeInterval(AgentRunFailure.backoff(failures: count, interval: effectiveIntervalSeconds))
        if canSchedule { nextRunAt = min(nextRunAt ?? retry, retry) }
        if count >= AgentRunFailure.troubleAfter { attention = AgentRunFailure.trouble(since: since, reason: message, tries: count) }
        lastOutcome = String((AgentRunFailure.retryPrefix + message + " (next try " + AgentRunFailure.stamp(retry) + ")").prefix(1000))
    }
    var hasTroubleBanner: Bool { attention.hasPrefix(AgentRunFailure.troublePrefix) || attention.hasPrefix(AgentRunFailure.retryPrefix) }
    // A completed run resets the failure count. A reported attention replaces
    // the banner; otherwise only a stale trouble banner is cleared.
    mutating func recordSuccess(_ outcome: String, attention reported: String?) {
        transientFailures = nil; troubleSince = nil
        if let reported { attention = String(reported.prefix(1000)) }
        else if hasTroubleBanner { attention = "" }
        lastOutcome = outcome
        preservePause()
    }
    mutating func pause(_ reason: String, at now: Date) {
        enabled = false; transientFailures = nil; troubleSince = nil
        let label = "Paused: " + reason + " (" + AgentRunFailure.stamp(now) + ")"
        pauseReason = String(label.prefix(1000)); attention = pauseReason!; lastOutcome = pauseReason!
    }
    // While the loop stays paused, later manual, Jolly or Discord runs add to
    // the reason instead of hiding it.
    mutating func preservePause() {
        guard !enabled, let pauseReason else { return }
        lastOutcome = pauseReason
        if !attention.hasPrefix(pauseReason) { attention = String((attention.isEmpty ? pauseReason : pauseReason + " · " + attention).prefix(1000)) }
    }
    // Re-enabling the loop or clearing the banner ends the recorded pause.
    mutating func clearPause() { pauseReason = nil; transientFailures = nil; troubleSince = nil }
}

extension Store {
    func clearAgentAttention(_ session: Session) {
        session.agent?.attention = ""; session.agent?.clearPause()
        session.status = session.busy ? "Working…" : "Ready"; save()
    }
    // Pause, Resume and Stop from the agent's … menu or its footer status.
    // Pausing leaves a current run alone; Stop current run leaves the loop on.
    func pauseAgentLoop(_ session: Session) {
        guard let config = session.agent, config.enabled else { return }
        do {
            try configureAgentLoop(session, enabled: false, interval: config.intervalSeconds, turns: config.turnLimit, scoreboardEvery: config.scoreboardCadence)
            session.agent?.lastOutcome = "Loop paused. Choose Resume loop to continue."
            save()
        } catch { session.agent?.attention = error.localizedDescription; save() }
    }
    func resumeAgentLoop(_ session: Session, now: Date = Date()) {
        guard let config = session.agent, !config.enabled else { return }
        let reason = config.pauseReason
        do {
            try configureAgentLoop(session, enabled: true, interval: config.intervalSeconds, turns: config.turnLimit, scoreboardEvery: config.scoreboardCadence, now: now)
            if let attention = session.agent?.attention, (reason.map { attention.hasPrefix($0) } == true || attention.hasPrefix("Loop paused") || attention.hasPrefix("Turn cancelled")) {
                session.agent?.attention = ""
            }
            session.agent?.lastOutcome = "Loop resumed."
            if !session.busy { session.status = "Ready" }
            save()
        } catch { session.agent?.attention = error.localizedDescription; save() }
        objectWillChange.send()
    }
    func stopAgentRun(_ session: Session) { MainActor.assumeIsolated { AgentRuntime.shared.stopRun(session) } }
    func toggleQueue(_ session: Session) {
        session.queuePaused.toggle(); save()
        if !session.queuePaused { runNext(session) }
    }
}
