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
    } catch { check(false, "Schedule fixture failed: " + error.localizedDescription) }
}
