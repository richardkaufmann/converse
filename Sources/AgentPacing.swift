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
