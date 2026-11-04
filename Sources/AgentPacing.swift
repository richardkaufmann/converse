import Foundation

// Auto pacing is opt-in. The agent may suggest when its next automatic check
// runs; the host clamps the suggestion to the owner's bounds and the configured
// schedule window. Budgets, Stop and pause behave exactly as without it.
enum AgentPacing {
    static let defaultMinMinutes = 5.0
    static let defaultMaxMinutes = 240.0
    static let reasonLimit = 60
    static func reason(_ text: String?) -> String? {
        let value = (text ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : String(value.prefix(reasonLimit))
    }
    static func minutesText(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
    // "20 min", "1 hr 5 min", "3 hr". Rounded up so a countdown never reads 0.
    static func relative(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
    }
}

extension AgentConfig {
    var autoPaceOn: Bool { autoPace == true }
    var paceMinMinutes: Double { autoPaceMinMinutes ?? AgentPacing.defaultMinMinutes }
    var paceMaxMinutes: Double { max(paceMinMinutes, autoPaceMaxMinutes ?? AgentPacing.defaultMaxMinutes) }
    var autoPaceInstruction: String? {
        guard autoPaceOn else { return nil }
        return "Auto pacing is on: you choose when the next automatic check runs. Add nextRunInMinutes (a number) and paceReason (a short reason, at most 60 characters) to your JSON object. Suggest sooner when things are actively changing or a human is waiting; suggest later when it is quiet. The host keeps your choice between \(AgentPacing.minutesText(paceMinMinutes)) and \(AgentPacing.minutesText(paceMaxMinutes)) minutes and inside the configured schedule; if you omit it, the configured interval applies."
    }
    // Validated setter used by Agent Setup. Turning pacing on or off never
    // pushes an existing deadline later than the configured schedule would.
    mutating func setAutoPace(_ on: Bool, minMinutes: Double, maxMinutes: Double, now: Date) throws {
        guard minMinutes.isFinite, maxMinutes.isFinite, (1...1440).contains(minMinutes), (minMinutes...10080).contains(maxMinutes) else {
            throw AgentFailure.message("Auto pacing needs a minimum of 1–1440 minutes and a maximum between the minimum and 7 days.")
        }
        let changed = on != autoPaceOn
        autoPace = on ? true : nil
        autoPaceMinMinutes = minMinutes == AgentPacing.defaultMinMinutes ? nil : minMinutes
        autoPaceMaxMinutes = maxMinutes == AgentPacing.defaultMaxMinutes ? nil : maxMinutes
        if !on { autoPaceReason = nil }
        if changed, canSchedule, let scheduled = nextScheduledRun(after: now) { nextRunAt = min(nextRunAt ?? scheduled, scheduled) }
    }
    // Called after a completed run. Missing or invalid suggestions keep the
    // configured schedule's deadline (already reserved for loop ticks).
    mutating func applyPace(suggestedMinutes: Double?, reason: String?, at now: Date) {
        guard autoPaceOn, canSchedule, let rule = try? scheduleRule() else { return }
        guard let minutes = suggestedMinutes, minutes.isFinite, minutes > 0, rule.kind != .daily else {
            autoPaceReason = nil
            if nextRunAt == nil { nextRunAt = rule.next(after: now) }
            return
        }
        let candidate = now.addingTimeInterval(min(paceMaxMinutes, max(paceMinMinutes, minutes)) * 60)
        // Inside a schedule window, use the suggestion; otherwise wait for the
        // window's next permitted run. Never run outside the calendar.
        guard let next = rule.permits(candidate) ? candidate : rule.next(after: candidate) else { return }
        nextRunAt = next
        autoPaceReason = AgentPacing.reason(reason)
    }
    func autoPaceStatus(next: Date, now: Date, rule: AgentSchedule) -> String {
        let when = next.timeIntervalSince(now) < 86400 ? "next in " + AgentPacing.relative(next.timeIntervalSince(now)) : "next " + rule.nextRunLabel(next)
        return "Auto · " + when + (autoPaceReason.map { " (" + $0 + ")" } ?? "")
    }
}

// Mood art costs an image generation. Regenerate only for a meaningful change,
// never more often than the minimum interval unless the owner edited the art
// direction, and refresh unchanged art at most once per maximum staleness.
enum AgentArtPolicy {
    static let defaultMinMinutes = 30.0
    static let defaultMaxStaleHours = 6.0
    // Labels, values and sentiment matter; title, summary, asOf and source URLs do not.
    static func signature(_ board: AgentScoreboard?) -> AgentScoreboard? {
        board.map { AgentScoreboard(title: nil, summary: "", metrics: $0.metrics.map { .init(label: $0.label, value: $0.value) }, sentiment: $0.sentiment) }
    }
    static func scoreboardChanged(from old: AgentScoreboard?, to new: AgentScoreboard?) -> Bool {
        let before = old?.metrics ?? [], after = new?.metrics ?? []
        if old?.sentiment != new?.sentiment { return true }
        func values(_ metrics: [AgentScoreboard.Metric]) -> [String: [String]] { Dictionary(grouping: metrics, by: \.label).mapValues { $0.map(\.value) } }
        return values(before) != values(after)
    }
    static func shouldRegenerate(now: Date, lastArtAt: Date?, directionChanged: Bool, moodChanged: Bool, scoreboardChanged: Bool,
                                 minInterval: TimeInterval, maxStale: TimeInterval) -> Bool {
        guard let lastArtAt else { return true }
        if directionChanged { return true }
        let age = now.timeIntervalSince(lastArtAt)
        guard age >= minInterval else { return false }
        return moodChanged || scoreboardChanged || age >= maxStale
    }
}

extension AgentConfig {
    var artMinMinutes: Double { artMinIntervalMinutes ?? AgentArtPolicy.defaultMinMinutes }
    var artStaleHours: Double { max(artMinMinutes / 60, artMaxStaleHours ?? AgentArtPolicy.defaultMaxStaleHours) }
    mutating func setArtThrottle(minMinutes: Double, maxStaleHours: Double) throws {
        guard minMinutes.isFinite, maxStaleHours.isFinite, (5...1440).contains(minMinutes), (1...168).contains(maxStaleHours), maxStaleHours * 60 >= minMinutes else {
            throw AgentFailure.message("Art refresh needs a minimum of 5–1440 minutes and a maximum of 1–168 hours, no shorter than the minimum.")
        }
        artMinIntervalMinutes = minMinutes == AgentArtPolicy.defaultMinMinutes ? nil : minMinutes
        artMaxStaleHours = maxStaleHours == AgentArtPolicy.defaultMaxStaleHours ? nil : maxStaleHours
    }
    func shouldRegenerateArt(mood: String, board: AgentScoreboard?, now: Date) -> Bool {
        AgentArtPolicy.shouldRegenerate(now: now, lastArtAt: lastArtAt, directionChanged: (lastArtDirection ?? "") != (artDirection ?? ""),
            moodChanged: lastArtMood != mood, scoreboardChanged: AgentArtPolicy.scoreboardChanged(from: lastArtScoreboard, to: AgentArtPolicy.signature(board)),
            minInterval: artMinMinutes * 60, maxStale: artStaleHours * 3600)
    }
}

// Model replies are untrusted. A malformed optional pacing field must never
// make the whole action object undecodable, so these decode leniently.
struct AgentLenientNumber: Decodable, Equatable {
    var value: Double?
    init(_ value: Double?) { self.value = value }
    init(from decoder: Decoder) {
        let container = try? decoder.singleValueContainer()
        if let number = try? container?.decode(Double.self) { value = number }
        else if let text = try? container?.decode(String.self) { value = Double(text.trimmingCharacters(in: .whitespaces)) }
        else { value = nil }
    }
}
struct AgentLenientText: Decodable, Equatable {
    var value: String?
    init(from decoder: Decoder) { value = try? decoder.singleValueContainer().decode(String.self) }
}

extension AgentModels {
    // API-key agents have no provider account to report. The footer column
    // is narrow, so show a short label and explain it on hover.
    static func apiKeyAccount(_ model: String?) -> (label: String, help: String)? {
        guard let model, parse(model) == nil else { return nil }
        return ("API Key", "API key — no account info available")
    }
}
