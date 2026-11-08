import CryptoKit
import Foundation

// The objective is the only place the owner describes timing. When it is
// saved, the agent's own model reads it once into this small spec; the host
// enforces it deterministically. Host limits always win: 1 minute floor,
// 72 hour ceiling, turn budgets, Stop and pause.
struct AgentPacingSpec: Codable, Equatable {
    struct Window: Codable, Equatable {
        // "everyday", "weekdays", "weekends" or "usMarket" (NYSE regular hours).
        var days: String?
        var start: String?
        var end: String?
        var timeZone: String?
    }
    var runEveryMinutes: Double? = nil
    var activeWindow: Window? = nil
    // Art timing (artMinIntervalMinutes, artMaxAgeHours, artChangePercent,
    // artOnSentimentChange) is no longer read: portraits are on demand only.
    // Specs saved by older builds still decode; those keys are ignored.
    // Extraction failed; defaults apply until the objective is saved again.
    var failed: Bool? = nil
    static let failure = AgentPacingSpec(failed: true)
    static let maxRunMinutes = 4320.0
    var usable: AgentPacingSpec? { failed == true ? nil : self }

    static func hash(_ objective: String) -> String {
        SHA256.hash(data: Data(objective.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static let instructions = """
    You read an AI agent's objective and extract only the timing the owner stated. Return exactly one JSON object and nothing else, matching this schema. Omit every field the objective does not state explicitly; never guess.
    {"runEveryMinutes": number (how often the agent should run, in minutes),
     "activeWindow": {"days": "everyday" | "weekdays" | "weekends" | "usMarket", "start": "HH:MM" (24-hour), "end": "HH:MM" (24-hour), "timeZone": IANA name such as "America/New_York"}}
    Use "usMarket" when the agent should run only while the US stock market is open. For a once-a-day time give start without end. Omit timeZone unless the objective names one; defaultTimeZone in the input is the owner's zone. If the objective says nothing about timing, return {}.
    """
    static func input(objective: String, timeZone: String?) -> String {
        let object: [String: String] = ["objective": String(objective.prefix(16000)), "defaultTimeZone": timeZone ?? TimeZone.current.identifier]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
    // Model output is untrusted: out-of-range or malformed fields are dropped
    // or clamped, never allowed to fail open into a faster schedule.
    static func parse(_ text: String) -> AgentPacingSpec? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```"), let open = body.firstIndex(of: "\n"), body.hasSuffix("```") { body = String(body[body.index(after: open)..<body.index(body.endIndex, offsetBy: -3)]) }
        guard let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(body[start...end].utf8)) as? [String: Any] else { return nil }
        func number(_ key: String, _ range: ClosedRange<Double>, from source: [String: Any] = object) -> Double? {
            let raw = source[key]
            guard let value = (raw as? NSNumber).flatMap({ CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue }) ?? (raw as? String).flatMap(Double.init),
                  value.isFinite, value > 0 else { return nil }
            return min(range.upperBound, max(range.lowerBound, value))
        }
        var spec = AgentPacingSpec()
        spec.runEveryMinutes = number("runEveryMinutes", 1...maxRunMinutes)
        if let window = object["activeWindow"] as? [String: Any] {
            func clock(_ key: String) -> String? {
                guard let text = window[key] as? String, let parts = AgentSchedule.captures("^([0-9]{1,2}):([0-9]{2})$", text.trimmingCharacters(in: .whitespaces)),
                      let hour = Int(parts[0]), let minute = Int(parts[1]), (0...24).contains(hour), (0..<60).contains(minute), hour < 24 || minute == 0 else { return nil }
                return String(format: "%02d:%02d", hour, minute)
            }
            let days = (window["days"] as? String).flatMap { ["everyday", "weekdays", "weekends", "usMarket"].contains($0) ? $0 : nil }
            let zone = (window["timeZone"] as? String).flatMap { TimeZone(identifier: $0) != nil ? $0 : nil }
            let parsed = Window(days: days, start: clock("start"), end: clock("end"), timeZone: zone)
            if days == "usMarket" || parsed.start != nil { spec.activeWindow = parsed }
        }
        return spec
    }
    // The schedule compiler turns the window into the next allowed time.
    func rule(interval: Double, zone: String?) -> AgentSchedule? {
        guard let window = activeWindow else { return nil }
        let minutes = AgentPacing.minutesText(interval / 60)
        let text: String
        if window.days == "usMarket" { text = "every \(minutes) minutes while the us stock market is open" }
        else if let start = window.start, let end = window.end {
            let days = window.days == "weekdays" ? " on weekdays" : window.days == "weekends" ? " on weekends" : ""
            text = "every \(minutes) minutes\(days) between \(start) and \(end)"
        } else if let start = window.start {
            text = (window.days == "weekdays" ? "weekdays" : window.days == "weekends" ? "weekends" : "daily") + " at " + start
        } else { return nil }
        return try? AgentSchedule.compile(interval: interval, text: text, zone: window.timeZone ?? zone)
    }
}

extension AgentPacing {
    static let legacyMaxMinutes = 240.0
    // "5 min", "12 h", "1 h 30 min".
    static func durationText(minutes: Double) -> String {
        let rounded = Int(minutes.rounded())
        if rounded < 60 { return minutesText(minutes) + " min" }
        return rounded % 60 == 0 ? "\(rounded / 60) h" : "\(rounded / 60) h \(rounded % 60) min"
    }
}

extension AgentConfig {
    var objectivePacing: AgentPacingSpec? { pacingSpec?.usable }
    // An owner-stated cadence wins over the agent's own suggestions.
    var explicitCadenceMinutes: Double? { objectivePacing?.runEveryMinutes }
    var pacesAutomatically: Bool { autoPaceOn && explicitCadenceMinutes == nil }
    var effectiveIntervalSeconds: Double { explicitCadenceMinutes.map { $0 * 60 } ?? intervalSeconds }
    // A migrated "Schedule: …" line still compiles deterministically when the
    // model has not (or could not) read the objective.
    var legacyScheduleLine: String? {
        guard let line = objective.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init), line.hasPrefix(Self.schedulePrefix) else { return nil }
        let text = String(line.dropFirst(Self.schedulePrefix.count)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
    static let schedulePrefix = "Schedule: "
    func objectiveRule() throws -> AgentSchedule {
        if let spec = objectivePacing {
            if let rule = spec.rule(interval: effectiveIntervalSeconds, zone: scheduleTimeZone) { return rule }
            return try AgentSchedule.compile(interval: effectiveIntervalSeconds, text: nil, zone: scheduleTimeZone)
        }
        if let line = legacyScheduleLine, let rule = try? AgentSchedule.compile(interval: intervalSeconds, text: line, zone: scheduleTimeZone) { return rule }
        return try AgentSchedule.compile(interval: intervalSeconds, text: nil, zone: scheduleTimeZone)
    }
    // Text schedules now live in the objective. Moves a non-empty one into a
    // last "Schedule:" line (replacing an earlier migrated line), clears the
    // field and returns the transcript notice, or nil when nothing moved.
    mutating func migrateScheduleText() -> String? {
        let text = (scheduleText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { if scheduleText != nil && scheduleText != "" { scheduleText = nil }; return nil }
        var lines = objective.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if lines.last?.hasPrefix(Self.schedulePrefix) == true { lines.removeLast() }
        lines.append(Self.schedulePrefix + text)
        objective = lines.joined(separator: "\n"); scheduleText = nil; pacingPending = true
        return "Your text schedule moved into this agent’s objective as its last line: “" + Self.schedulePrefix + text + "”. Converse now reads timing from the objective, so edit it there to change how often this agent runs or refreshes its art."
    }
    // Adopts a freshly extracted spec; a changed rule reschedules the loop.
    mutating func adoptPacing(_ spec: AgentPacingSpec, hash: String, now: Date) {
        let before = try? scheduleRule()
        pacingSpec = spec; pacingObjectiveHash = hash; pacingPending = nil
        if !pacesAutomatically { autoPaceReason = nil }
        if canSchedule, let rule = try? scheduleRule(), rule != before { nextRunAt = rule.next(after: now) }
    }
    func needsPacingExtraction(retryFailed: Bool) -> Bool {
        pacingObjectiveHash != AgentPacingSpec.hash(objective) || (retryFailed && pacingSpec?.failed == true)
    }
    // One plain line under the objective and in the footer hover, e.g.
    // "Runs every 5 min · art: at least every 12 h, or when any metric moves > 0.5%".
    func pacingSummary(extracting: Bool = false) -> String {
        if extracting { return "Reading timing from the objective…" }
        let spec = objectivePacing
        var cadence: String
        if let minutes = explicitCadenceMinutes { cadence = "Runs every " + AgentPacing.durationText(minutes: minutes) }
        else if autoPaceOn { cadence = "Auto pacing between " + AgentPacing.durationText(minutes: paceMinMinutes) + " and " + AgentPacing.durationText(minutes: paceMaxMinutes) }
        else { cadence = "Runs every " + AgentPacing.durationText(minutes: intervalSeconds / 60) }
        if let window = spec?.activeWindow, spec?.rule(interval: effectiveIntervalSeconds, zone: scheduleTimeZone) != nil {
            let zone = window.timeZone ?? scheduleTimeZone ?? TimeZone.current.identifier
            if window.days == "usMarket" { cadence += " while the US market is open" }
            else if let start = window.start, let end = window.end {
                cadence += (window.days == "weekdays" ? " on weekdays " : window.days == "weekends" ? " on weekends " : " ") + start + "–" + end + " (" + zone + ")"
            } else if let start = window.start {
                cadence = (window.days == "weekdays" ? "Runs weekdays at " : window.days == "weekends" ? "Runs weekends at " : "Runs daily at ") + start + " (" + zone + ")"
            }
        } else if spec == nil, let line = legacyScheduleLine, (try? AgentSchedule.compile(interval: intervalSeconds, text: line, zone: scheduleTimeZone)) != nil {
            cadence = "Runs " + line
        }
        var parts = [cadence]
        if pacingSpec?.failed == true { parts.append("couldn’t read timing from the objective; save it again to retry") }
        return parts.joined(separator: " · ")
    }
}
