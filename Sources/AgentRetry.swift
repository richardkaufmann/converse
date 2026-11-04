import Foundation

// A loop must survive a passing network or service hiccup. Transient errors
// keep the loop on and retry at the next scheduled check; only repeated ones
// pause it. Credentials, settings, budgets, schedules and Stop pause at once.
// Mirrored in windows/src/Converse.Core/AgentRuntime.cs (AgentRunFailure).
enum AgentRunFailure {
    enum Kind: Equatable { case transient, permanent, cancelled }
    static let retryLimit = 3
    static let retryPrefix = "Retrying: "
    static let transientURLCodes: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .callIsActive, .dataNotAllowed, .resourceUnavailable, .badServerResponse]
    static func classify(_ error: Error) -> Kind {
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError { return url.code == .cancelled ? .cancelled : transientURLCodes.contains(url.code) ? .transient : .permanent }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return classify(URLError(URLError.Code(rawValue: ns.code))) }
        return classify(message: error.localizedDescription)
    }
    // Host messages are fixed strings (bodies are never surfaced), so plain
    // text is a safe signal. Permanent markers win over transient ones.
    static func classify(message: String) -> Kind {
        let text = message.lowercased()
        let permanent = ["api key", "token", "rejected", "denied", "http 400", "http 401", "http 403", "http 404", "turn limit", "budget",
                         "schedule", "calendar", "invalid", "choose", "add a ", "stopped", "stop."]
        if permanent.contains(where: text.contains) { return .permanent }
        if text.range(of: #"http (429|5\d\d)\b"#, options: .regularExpression) != nil { return .transient }
        let transient = ["timed out", "network connection was lost", "not connected to the internet", "could not connect to the server",
                         "cannot connect", "network is unreachable", "overloaded", "temporarily unavailable", "service unavailable", "no http response"]
        return transient.contains(where: text.contains) ? .transient : .permanent
    }
    static func stamp(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
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
        guard kind == .transient else { pause(message, at: now); return }
        let count = min(AgentRunFailure.retryLimit, max(0, transientFailures ?? 0) + 1)
        guard count < AgentRunFailure.retryLimit else {
            pause(message + " — failed \(count) times in a row", at: now); return
        }
        transientFailures = count
        attention = AgentRunFailure.retryPrefix + message + " (\(count) of \(AgentRunFailure.retryLimit))"
        lastOutcome = attention
    }
    // A completed run resets the transient counter. A reported attention
    // replaces the banner; otherwise only a stale retry banner is cleared.
    mutating func recordSuccess(_ outcome: String, attention reported: String?) {
        transientFailures = nil
        if let reported { attention = String(reported.prefix(1000)) }
        else if attention.hasPrefix(AgentRunFailure.retryPrefix) { attention = "" }
        lastOutcome = outcome
        preservePause()
    }
    mutating func pause(_ reason: String, at now: Date) {
        enabled = false; transientFailures = nil
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
    mutating func clearPause() { pauseReason = nil; transientFailures = nil }
}

extension Store {
    func clearAgentAttention(_ session: Session) {
        session.agent?.attention = ""; session.agent?.clearPause()
        session.status = session.busy ? "Working…" : "Ready"; save()
    }
}
