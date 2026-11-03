import Foundation

func agentScheduleSelfTests(_ check: (Bool, String) -> Void) {
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func rule(_ text: String, zone: String = "America/New_York") throws -> AgentSchedule { try AgentSchedule.compile(interval: 900, text: text, zone: zone) }
    do {
        let market = try rule("every 20 minutes while the us stock market is open.")
        let before = date("2026-10-29T13:29:00Z")
        check(market.preview(after: before) == [date("2026-10-29T13:30:00Z"), date("2026-10-29T13:50:00Z"), date("2026-10-29T14:10:00Z")], "Text schedule anchors twenty-minute checks at New York market open")
        check(!market.permits(date("2026-10-29T20:00:00Z")) && market.next(after: date("2026-10-29T19:50:00Z")) == date("2026-10-30T13:30:00Z"), "Market close is exclusive and next run advances to next trading day")
        check(market.next(after: date("2026-10-30T20:00:00Z")) == date("2026-11-02T14:30:00Z"), "Market schedule skips weekend and follows New York DST, independent of device zone")
        check(!market.permits(date("2026-11-26T16:00:00Z")) && market.next(after: date("2026-11-25T21:00:00Z")) == date("2026-11-27T14:30:00Z"), "Market schedule skips Thanksgiving")
        check(!market.permits(date("2026-11-27T18:00:00Z")) && market.next(after: date("2026-11-27T17:50:00Z")) == date("2026-11-30T14:30:00Z"), "Market schedule respects 13:00 early close")
        check(!market.permits(date("2026-07-03T15:00:00Z")) && !market.permits(date("2027-03-26T15:00:00Z")), "Market schedule includes observed Independence Day and Good Friday")
        check(market.permits(date("2027-12-31T15:00:00Z")) && market.next(after: date("2028-12-31T00:00:00Z")) == nil, "Published New Year exception is honored and unknown calendar years fail closed")
        let fixed = try AgentSchedule.compile(interval: 1200, text: nil, zone: "America/Los_Angeles")
        check(fixed.next(after: before) == before.addingTimeInterval(1200) && fixed.permits(date("2026-11-26T00:00:00Z")), "Numeric intervals remain deterministic and unrestricted by market hours")
        let window = try rule("every 2 hours on weekdays between 9am and 5pm in America/Los_Angeles")
        check(window.zoneID == "America/Los_Angeles" && window.next(after: date("2026-10-29T15:59:00Z")) == date("2026-10-29T16:00:00Z") && !window.permits(date("2026-10-31T19:00:00Z")), "Weekday time windows honor explicit time zone and exclude weekends")
        let daily = try rule("daily at 1:30am")
        check(daily.next(after: date("2026-11-01T05:30:00Z")) == date("2026-11-02T06:30:00Z"), "Daily schedule does not double-run repeated daylight-saving hour")
        let missing = try rule("daily at 02:30")
        check(missing.next(after: date("2027-03-14T00:00:00Z")) == date("2027-03-15T06:30:00Z"), "Daily schedule skips nonexistent spring daylight-saving time")
        let words = try rule("every twenty minutes during market hours")
        check(words == market, "Supported word-number schedule compiles to the same deterministic rule")
        let weekend = try rule("weekends at noon in UTC")
        check(weekend.next(after: date("2026-10-30T13:00:00Z")) == date("2026-10-31T12:00:00Z"), "Weekend daily schedule and UTC alias are supported")
        for text in ["every 20 minutes while news is important", "every 20 minutes while the market is open and also at midnight", "every 20 seconds", "daily at 25:00", "every 2 hours between 5pm and 9am", " ", "every 20 minutes in Mars/Olympus", "every 9999999999999999999999 days"] {
            do { _ = try rule(text); check(false, "Unsupported/unsafe schedule rejected: " + text) }
            catch { check(true, "Unsupported/unsafe schedule rejected: " + text) }
        }
        check(market.preview(after: before, count: 100).count == 10, "Schedule preview has bounded work")
        // Bug D2A179D2: the saved Meta Stock Agent loop, replayed across the
        // 2026-11-01 fall-back weekend. Fixed instants; no device-zone dependence.
        var saved = AgentConfig()
        saved.intervalSeconds = 900; saved.scheduleText = "every 20 minutes while the US stock market is open"; saved.scheduleTimeZone = "America/New_York"
        saved.remainingRuns = 0; saved.maxTurnsPerLoop = 1; saved.enabled = true; saved.lastLoopAt = date("2026-10-30T19:50:00Z")
        try saved.restoreSchedule(at: date("2026-11-02T12:00:00Z"))
        check(saved.canSchedule && saved.nextRunAt == date("2026-11-02T14:30:00Z"), "Saved market loop with remainingRuns 0 still schedules; Friday 15:50 EDT resumes Monday 09:30 EST")
        check(!saved.due(at: date("2026-11-02T13:30:00Z")) && !saved.due(at: date("2026-11-02T14:29:59Z")), "No Monday run at the stale EDT 09:30 (08:30 EST) or before the open")
        var mondayRuns: [Date] = [], cursor = date("2026-11-02T14:30:00Z")
        while cursor < date("2026-11-03T00:00:00Z"), saved.reserveRun(at: cursor.addingTimeInterval(2)) { mondayRuns.append(cursor); cursor = saved.nextRunAt ?? .distantFuture }
        check(mondayRuns.count == 20 && mondayRuns.last == date("2026-11-02T20:50:00Z") && saved.nextRunAt == date("2026-11-03T14:30:00Z"),
              "Saved market loop runs every 20 minutes from 09:30 to 15:50 EST on the first post-DST Monday, then Tuesday 09:30")
        for zone in ["America/Los_Angeles", "Asia/Tokyo", "UTC"] {
            check(try rule("every 20 minutes while the US stock market is open", zone: zone) == market, "Market schedule ignores the saved/device zone " + zone)
        }
        check(market.next(after: date("2026-03-06T20:50:00Z")) == date("2026-03-09T13:30:00Z") && !market.permits(date("2026-03-09T13:29:00Z")) && market.permits(date("2026-03-09T13:30:00Z")),
              "Spring-forward weekend: Friday 15:50 EST resumes Monday 09:30 EDT")
        func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ") }
        let us = Locale(identifier: "en_US"), pacific = TimeZone(identifier: "America/Los_Angeles")!, eastern = TimeZone(identifier: "America/New_York")!
        check(plain(market.nextRunLabel(date("2026-11-03T14:30:00Z"), local: pacific, locale: us)) == "Nov 3 at 6:30 AM PST (9:30 AM EST)",
              "Loop status names the market's New York time beside local time")
        check(plain(market.nextRunLabel(date("2026-10-30T13:30:00Z"), local: pacific, locale: us)) == "Oct 30 at 6:30 AM PDT (9:30 AM EDT)",
              "Next-run label tracks daylight time before the fall-back boundary")
        check(plain(market.nextRunLabel(date("2026-11-03T14:30:00Z"), local: eastern, locale: us)) == "Nov 3 at 9:30 AM EST", "Next-run label stays single when local time is the schedule's zone")
        check(plain(market.nextRunLabel(date("2026-11-03T14:30:00Z"), local: TimeZone(identifier: "Australia/Sydney")!, locale: us)).hasSuffix(" (Nov 3 at 9:30 AM EST)"),
              "Next-run label dates the schedule's wall clock when it falls on another local day")
        check(!fixed.nextRunLabel(date("2026-11-03T14:30:00Z"), local: eastern, locale: us).contains("("), "Fixed intervals show only local time")
    } catch { check(false, "Schedule fixture failed: " + error.localizedDescription) }
}
