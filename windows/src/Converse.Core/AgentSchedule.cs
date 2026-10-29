using System.Globalization;
using System.Text.RegularExpressions;
namespace Converse.Core;

// Same accepted grammar and calendar as Sources/AgentSchedule.swift. No model,
// network request or arbitrary code is involved in deciding when a tick is due.
public sealed class AgentSchedule
{
    public double Seconds { get; private set; }
    public string Kind { get; private set; } = "interval";
    public TimeZoneInfo Zone { get; private set; } = TimeZoneInfo.Utc;
    private HashSet<DayOfWeek> _days = Enum.GetValues<DayOfWeek>().ToHashSet();
    private int _start, _end = 1440;
    public static AgentSchedule Compile(DeviceAgentSettings settings)
    {
        var rule = new AgentSchedule { Seconds = settings.IntervalSeconds, Zone = TimeZoneInfo.FindSystemTimeZoneById(settings.ScheduleTimeZone ?? TimeZoneInfo.Local.Id) };
        var raw = settings.ScheduleText ?? "";
        var input = Regex.Replace(raw.Trim().ToLowerInvariant().Replace("u.s.", "us").Replace('–', '-').TrimEnd('.'), @"\s+", " ");
        if (input.Length == 0) { if (raw.Length > 0) throw new ArgumentException("Enter a text schedule or choose a numeric interval."); Validate(rule.Seconds); return rule; }
        if (System.Text.Encoding.UTF8.GetByteCount(raw) > 500) throw new ArgumentException("Schedule is too long.");
        var zone = Regex.Match(input, @"^(.*) (?:in|timezone) ([a-z_]+/[a-z_/]+|utc|et|pt)$");
        if (zone.Success)
        {
            input = zone.Groups[1].Value;
            var id = zone.Groups[2].Value;
            id = id switch { "utc" => "UTC", "et" => "America/New_York", "pt" => "America/Los_Angeles", "america/new_york" => "America/New_York", "america/los_angeles" => "America/Los_Angeles", _ => TimeZoneInfo.GetSystemTimeZones().FirstOrDefault(z => z.Id.Equals(id, StringComparison.OrdinalIgnoreCase))?.Id ?? id };
            rule.Zone = TimeZoneInfo.FindSystemTimeZoneById(id);
        }
        var daily = Regex.Match(input, @"^(daily|every day|weekdays|every weekday|weekends|every weekend) at (.+)$");
        if (daily.Success)
        {
            rule.Kind = "daily"; rule._start = Clock(daily.Groups[2].Value);
            if (daily.Groups[1].Value.Contains("weekday")) rule._days = Weekdays();
            if (daily.Groups[1].Value.Contains("weekend")) rule._days = new() { DayOfWeek.Saturday, DayOfWeek.Sunday };
            return rule;
        }
        var match = Regex.Match(input, @"^every ([a-z-]+|[0-9]+(?:\.[0-9]+)?) (seconds?|secs?|minutes?|mins?|hours?|hrs?|days?)(.*)$");
        if (!match.Success) throw Unsupported();
        var words = new Dictionary<string, double> { ["a"] = 1, ["an"] = 1, ["one"] = 1, ["two"] = 2, ["three"] = 3, ["four"] = 4, ["five"] = 5, ["six"] = 6, ["seven"] = 7, ["eight"] = 8, ["nine"] = 9, ["ten"] = 10, ["fifteen"] = 15, ["twenty"] = 20, ["thirty"] = 30, ["forty"] = 40, ["forty-five"] = 45, ["sixty"] = 60 };
        if (!double.TryParse(match.Groups[1].Value, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var number) && !words.TryGetValue(match.Groups[1].Value, out number)) throw Unsupported();
        rule.Seconds = number * (match.Groups[2].Value[0] switch { 's' => 1, 'm' => 60, 'h' => 3600, _ => 86400 }); Validate(rule.Seconds);
        var condition = match.Groups[3].Value.Trim();
        if (condition.Length == 0) return rule;
        if (new[] { "while the us stock market is open", "while us stock market is open", "while the market is open", "during us market hours", "during market hours" }.Contains(condition))
        {
            rule.Kind = "market"; rule.Zone = TimeZoneInfo.FindSystemTimeZoneById("America/New_York"); rule._days = Weekdays(); rule._start = 570; rule._end = 960;
        }
        else
        {
            rule.Kind = "window";
            foreach (var prefix in new[] { "on weekdays", "weekdays", "on weekends", "weekends" })
                if (condition == prefix || condition.StartsWith(prefix + " ")) { rule._days = prefix.Contains("weekday") ? Weekdays() : new() { DayOfWeek.Saturday, DayOfWeek.Sunday }; condition = condition[prefix.Length..].Trim(); break; }
            if (condition.Length > 0)
            {
                var window = Regex.Match(condition, @"^(?:between|from) (.+?) (?:and|to) (.+)$");
                if (!window.Success) throw Unsupported();
                rule._start = Clock(window.Groups[1].Value); rule._end = Clock(window.Groups[2].Value, true);
            }
        }
        if (rule._end <= rule._start || rule.Seconds > (rule._end - rule._start) * 60) throw new ArgumentException("Use a same-day window large enough for the interval.");
        return rule;
    }
    private static HashSet<DayOfWeek> Weekdays() => new() { DayOfWeek.Monday, DayOfWeek.Tuesday, DayOfWeek.Wednesday, DayOfWeek.Thursday, DayOfWeek.Friday };
    private static ArgumentException Unsupported() => new("Unsupported schedule. Try ‘every 20 minutes while the US stock market is open’ or ‘daily at 09:00’.");
    private static void Validate(double seconds) { if (!double.IsFinite(seconds) || seconds < 60 || seconds > 31536000) throw new ArgumentException("Interval must be one minute to 365 days."); }
    private static int Clock(string value, bool end = false)
    {
        if (value == "noon") return 720; if (value == "midnight") return end ? 1440 : 0;
        var match = Regex.Match(value, @"^([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)?$");
        if (!match.Success) throw Unsupported();
        var h = int.Parse(match.Groups[1].Value); var m = match.Groups[2].Success ? int.Parse(match.Groups[2].Value) : 0;
        if (match.Groups[3].Success) { if (h < 1 || h > 12) throw Unsupported(); h = h % 12 + (match.Groups[3].Value == "pm" ? 12 : 0); }
        if (m >= 60 || h >= 24 && !(end && h == 24 && m == 0)) throw Unsupported();
        return h * 60 + m;
    }
    private DateTime? Wall(DateTime day, int minute)
    {
        var wall = DateTime.SpecifyKind(day.Date.AddMinutes(minute), DateTimeKind.Unspecified);
        if (Zone.IsInvalidTime(wall)) return null;
        if (Zone.IsAmbiguousTime(wall)) return new DateTimeOffset(wall, Zone.GetAmbiguousTimeOffsets(wall).Max()).UtcDateTime;
        return TimeZoneInfo.ConvertTimeToUtc(wall, Zone);
    }
    private (DateTime Start, DateTime End)? Bounds(DateTime day)
    {
        if (!_days.Contains(day.DayOfWeek)) return null;
        var end = _end;
        if (Kind == "market")
        {
            if (day.Year < 2026 || day.Year > 2028 || Holidays.Contains(day.ToString("yyyy-MM-dd"))) return null;
            if (EarlyCloses.Contains(day.ToString("yyyy-MM-dd"))) end = 780;
        }
        return Wall(day, _start) is { } start && Wall(day, end) is { } finish ? (start, finish) : null;
    }
    public bool Permits(DateTime utc) => Kind == "interval" || Bounds(TimeZoneInfo.ConvertTimeFromUtc(utc.ToUniversalTime(), Zone)) is { } bounds && utc >= bounds.Start && utc < bounds.End;
    public DateTime? Next(DateTime utc)
    {
        utc = utc.ToUniversalTime(); if (Kind == "interval") return utc.AddSeconds(Seconds);
        var today = TimeZoneInfo.ConvertTimeFromUtc(utc, Zone).Date;
        for (var offset = 0; offset <= 370; offset++)
        {
            if (Bounds(today.AddDays(offset)) is not { } b) continue;
            if (b.Start > utc) return b.Start;
            if (Kind == "daily") continue;
            var next = b.Start.AddSeconds(Math.Max(0, Math.Floor((utc - b.Start).TotalSeconds / Seconds) + 1) * Seconds);
            if (next > utc && next < b.End) return next;
        }
        return null;
    }
    // NYSE published calendar, verified 2026-10-29; fail closed after 2028.
    // https://www.nyse.com/trade/hours-calendars
    private static readonly HashSet<string> Holidays = ("2026-01-01 2026-01-19 2026-02-16 2026-04-03 2026-05-25 2026-06-19 2026-07-03 2026-09-07 2026-11-26 2026-12-25 " +
        "2027-01-01 2027-01-18 2027-02-15 2027-03-26 2027-05-31 2027-06-18 2027-07-05 2027-09-06 2027-11-25 2027-12-24 " +
        "2028-01-17 2028-02-21 2028-04-14 2028-05-29 2028-06-19 2028-07-04 2028-09-04 2028-11-23 2028-12-25").Split(' ').ToHashSet();
    private static readonly HashSet<string> EarlyCloses = new() { "2026-11-27", "2026-12-24", "2027-11-26", "2028-07-03", "2028-11-24" };
}
