import Foundation

struct AgentScheduleError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

// Text is compiled into a small deterministic rule. It never becomes a prompt,
// script, cron shell, or a model decision on a scheduler tick.
struct AgentSchedule: Equatable {
    enum Kind { case interval, window, daily, market }
    var kind: Kind = .interval
    var seconds: Double
    var zoneID: String
    var weekdays: Set<Int> = Set(1...7)
    var startMinute = 0
    var endMinute = 1440
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zoneID)!
        return calendar
    }
    static func compile(interval: Double, text: String?, zone: String?) throws -> AgentSchedule {
        let zoneID = zone ?? TimeZone.current.identifier
        guard TimeZone(identifier: zoneID) != nil else { throw AgentScheduleError(message: "Choose a valid time zone, such as America/New_York.") }
        var rule = AgentSchedule(seconds: interval, zoneID: zoneID)
        var input = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.utf8.count <= 500 else { throw AgentScheduleError(message: "Keep the schedule under 500 bytes.") }
        if input.isEmpty {
            guard text == nil || text == "" else { throw AgentScheduleError(message: "Enter a text schedule, or choose Fixed interval.") }
            try validateInterval(interval); return rule
        }
        input = input.lowercased().replacingOccurrences(of: "u.s.", with: "us").replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if input.hasSuffix(".") { input.removeLast() }
        if let match = captures("^(.*) (?:in|timezone) ([a-z_]+/[a-z_/]+|utc|et|pt)$", input) {
            input = match[0]
            let aliases = ["et": "America/New_York", "pt": "America/Los_Angeles", "utc": "UTC"]
            guard let found = aliases[match[1]] ?? TimeZone.knownTimeZoneIdentifiers.first(where: { $0.lowercased() == match[1] }) else {
                throw AgentScheduleError(message: "Unknown time zone. Use an IANA name such as America/New_York.")
            }
            rule.zoneID = found
        }
        if let daily = captures("^(daily|every day|weekdays|every weekday|weekends|every weekend) at (.+)$", input) {
            rule.kind = .daily; rule.seconds = 86400; rule.startMinute = try clock(daily[1])
            rule.weekdays = daily[0].contains("weekday") ? Set(2...6) : daily[0].contains("weekend") ? Set([1, 7]) : Set(1...7)
            return rule
        }
        guard let parts = captures("^every ([a-z-]+|[0-9]+(?:\\.[0-9]+)?) (seconds?|secs?|minutes?|mins?|hours?|hrs?|days?)(.*)$", input),
              let number = number(parts[0]) else { throw unsupported() }
        let unit = parts[1]
        rule.seconds = number * (unit.hasPrefix("s") ? 1 : unit.hasPrefix("m") ? 60 : unit.hasPrefix("h") ? 3600 : 86400)
        try validateInterval(rule.seconds)
        var condition = parts[2].trimmingCharacters(in: .whitespaces)
        if condition.isEmpty { return rule }
        if ["while the us stock market is open", "while us stock market is open", "while the market is open", "during us market hours", "during market hours"].contains(condition) {
            rule.kind = .market; rule.zoneID = "America/New_York"; rule.weekdays = Set(2...6)
            rule.startMinute = 570; rule.endMinute = 960
            guard rule.seconds <= 23400 else { throw AgentScheduleError(message: "Market intervals must fit within a regular 6½-hour session.") }
            return rule
        }
        for (prefix, days) in [("on weekdays", Set(2...6)), ("weekdays", Set(2...6)), ("on weekends", Set([1, 7])), ("weekends", Set([1, 7]))] {
            if condition == prefix || condition.hasPrefix(prefix + " ") {
                rule.weekdays = days; condition = String(condition.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces); break
            }
        }
        rule.kind = .window
        if !condition.isEmpty {
            guard let hours = captures("^(?:between|from) (.+?) (?:and|to) (.+)$", condition) else { throw unsupported() }
            rule.startMinute = try clock(hours[0]); rule.endMinute = try clock(hours[1], allowMidnightEnd: true)
            guard rule.endMinute > rule.startMinute else { throw AgentScheduleError(message: "Use a same-day window with its end after its start. Split overnight schedules into separate agents for now.") }
        }
        guard rule.seconds <= Double(rule.endMinute - rule.startMinute) * 60 else { throw AgentScheduleError(message: "The interval must fit inside the selected daily window.") }
        return rule
    }
    static func validateInterval(_ seconds: Double) throws {
        guard seconds.isFinite, (60...31536000).contains(seconds) else { throw AgentScheduleError(message: "Use an interval between one minute and 365 days.") }
    }
    static func number(_ text: String) -> Double? {
        if let number = Double(text) { return number }
        let words: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "forty-five": 45, "sixty": 60]
        return words[text]
    }
    static func captures(_ pattern: String, _ value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : (value as NSString).substring(with: match.range(at: $0)) }
    }
    static func clock(_ input: String, allowMidnightEnd: Bool = false) throws -> Int {
        if input == "noon" { return 720 }; if input == "midnight" { return allowMidnightEnd ? 1440 : 0 }
        guard let fields = captures("^([0-9]{1,2})(?::([0-9]{2}))?\\s*(am|pm)?$", input) else { throw unsupported() }
        var hour = Int(fields[0])!; let minute = Int(fields[1]) ?? 0; let suffix = fields[2]
        guard minute < 60 else { throw unsupported() }
        if !suffix.isEmpty {
            guard (1...12).contains(hour) else { throw unsupported() }
            hour = hour % 12 + (suffix == "pm" ? 12 : 0)
        }
        guard hour < 24 || (allowMidnightEnd && hour == 24 && minute == 0) else { throw unsupported() }
        return hour * 60 + minute
    }
    static func unsupported() -> AgentScheduleError {
        AgentScheduleError(message: "Try ‘every 20 minutes while the US stock market is open’, ‘every 2 hours on weekdays between 9am and 5pm’, or ‘daily at 09:00’. Unsupported conditions are never ignored.")
    }
    var description: String {
        let period = seconds.truncatingRemainder(dividingBy: 3600) == 0 ? "\(Int(seconds / 3600)) hours" : seconds.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(seconds / 60)) minutes" : "\(seconds) seconds"
        if kind == .interval { return "Every \(period) after the previous start; no calendar restrictions." }
        if kind == .market { return "Every \(period) from 09:30, before 16:00 New York time; NYSE regular sessions, holidays and 13:00 early closes (2026–2028)." }
        let days = weekdays == Set(2...6) ? "weekdays" : weekdays == Set([1, 7]) ? "weekends" : "every day"
        func clockText(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
        return kind == .daily ? "At \(clockText(startMinute)) on \(days), \(zoneID)." : "Every \(period) from \(clockText(startMinute)) to before \(clockText(endMinute)), \(days), \(zoneID)."
    }
    // Status lines show local time. A calendar schedule kept in another zone
    // also names its own wall clock, e.g. "Nov 3 at 6:30 AM PST (9:30 AM EST)".
    func nextRunLabel(_ date: Date, local: TimeZone = .current, locale: Locale = .current) -> String {
        func label(_ zone: TimeZone, withDate: Bool) -> String {
            let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = zone
            formatter.setLocalizedDateFormatFromTemplate(withDate ? "MMMdjmmz" : "jmmz")
            return formatter.string(from: date)
        }
        guard kind != .interval, let zone = TimeZone(identifier: zoneID), zone.secondsFromGMT(for: date) != local.secondsFromGMT(for: date) else { return label(local, withDate: true) }
        var localCalendar = Calendar(identifier: .gregorian); localCalendar.timeZone = local
        var zoneCalendar = localCalendar; zoneCalendar.timeZone = zone
        let sameDay = localCalendar.dateComponents([.year, .month, .day], from: date) == zoneCalendar.dateComponents([.year, .month, .day], from: date)
        return label(local, withDate: true) + " (" + label(zone, withDate: !sameDay) + ")"
    }
    // Calendar wall-clock matching avoids hard-coded UTC offsets and repeated
    // local times. Missing DST times are skipped; a repeated daily time runs once.
    func boundary(_ minute: Int, on day: Date) -> Date? {
        let calendar = calendar
        if minute == 1440 { return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) }
        guard let date = calendar.nextDate(after: calendar.startOfDay(for: day).addingTimeInterval(-1), matching: DateComponents(hour: minute / 60, minute: minute % 60, second: 0), matchingPolicy: .strict, repeatedTimePolicy: .first), calendar.isDate(date, inSameDayAs: day) else { return nil }
        return date
    }
    func bounds(on day: Date) -> (Date, Date)? {
        let calendar = calendar
        guard weekdays.contains(calendar.component(.weekday, from: day)) else { return nil }
        var end = endMinute
        if kind == .market {
            guard let marketEnd = USMarketCalendar.closeMinute(on: day, calendar: calendar) else { return nil }
            end = marketEnd
        }
        guard let start = boundary(startMinute, on: day), let finish = boundary(end, on: day) else { return nil }
        return (start, finish)
    }
    func permits(_ now: Date) -> Bool {
        if kind == .interval { return true }
        guard let (start, end) = bounds(on: now) else { return false }
        return now >= start && now < end
    }
    func next(after now: Date) -> Date? {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return nil }
        if kind == .interval { return now.addingTimeInterval(seconds) }
        let calendar = calendar; let today = calendar.startOfDay(for: now)
        for offset in 0...370 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today), let (start, end) = bounds(on: day) else { continue }
            if start > now { return start }
            if kind == .daily { continue }
            let steps = floor(now.timeIntervalSince(start) / seconds) + 1
            let candidate = start.addingTimeInterval(max(0, steps) * seconds)
            if candidate > now && candidate < end { return candidate }
        }
        return nil
    }
    func preview(after now: Date, count: Int = 3) -> [Date] {
        var dates: [Date] = [], cursor = now
        for _ in 0..<max(0, min(10, count)) { guard let date = next(after: cursor) else { break }; dates.append(date); cursor = date }
        return dates
    }
}

// Published NYSE cash-equity calendar, verified 2026-10-29:
// https://www.nyse.com/trade/hours-calendars
// No prediction beyond these years, no claim to detect emergency closures or
// security-specific trading halts. Update the calendar before 2029.
enum USMarketCalendar {
    static let holidays: Set<String> = Set((
        "2026-01-01 2026-01-19 2026-02-16 2026-04-03 2026-05-25 2026-06-19 2026-07-03 2026-09-07 2026-11-26 2026-12-25 " +
        "2027-01-01 2027-01-18 2027-02-15 2027-03-26 2027-05-31 2027-06-18 2027-07-05 2027-09-06 2027-11-25 2027-12-24 " +
        "2028-01-17 2028-02-21 2028-04-14 2028-05-29 2028-06-19 2028-07-04 2028-09-04 2028-11-23 2028-12-25"
    ).split(separator: " ").map(String.init))
    static let earlyCloses: Set<String> = ["2026-11-27", "2026-12-24", "2027-11-26", "2028-07-03", "2028-11-24"]
    static func closeMinute(on date: Date, calendar: Calendar) -> Int? {
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let year = c.year, (2026...2028).contains(year), let weekday = c.weekday, (2...6).contains(weekday) else { return nil }
        let key = String(format: "%04d-%02d-%02d", year, c.month!, c.day!)
        return holidays.contains(key) ? nil : earlyCloses.contains(key) ? 780 : 960
    }
}
