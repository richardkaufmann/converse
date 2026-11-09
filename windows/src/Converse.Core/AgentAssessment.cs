using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
namespace Converse.Core;

// Mirrors Sources/AgentAssessment.swift: every agent turn returns an
// assessment; the host owns measured values; a malformed or missing one keeps
// the last record, marked stale, and never fails the turn. Windows UI later.
public sealed class AgentFactRecord
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";
    public string Value { get; set; } = AgentAssessments.Unavailable;
    public string Kind { get; set; } = "judgment"; // measured | evidence | judgment
    public string Source { get; set; } = "";
    public DateTime? ObservedAtUtc { get; set; }
    public JsonNode? Detail { get; set; }
}

public sealed class AgentAssessmentRecord
{
    public string Summary { get; set; } = "";
    public string Status { get; set; } = "on-track"; // on-track | at-risk | blocked | done
    public List<AgentFactRecord> Facts { get; set; } = new();
    public JsonNode? Detail { get; set; }
    public List<string>? Mood { get; set; }
    public int Revision { get; set; } = 1;
    public string ContentHash { get; set; } = "";
    public DateTime UpdatedAtUtc { get; set; }
    public DateTime CheckedAtUtc { get; set; }
    public int Heartbeats { get; set; }
}

public enum AgentAssessmentOutcome { Revision, Heartbeat, Rejected }

public static class AgentAssessments
{
    public const string Unavailable = "Unavailable";
    public static readonly string[] Statuses = ["on-track", "at-risk", "blocked", "done"];
    public const string Teaching = "Return assessment EVERY turn, even when reply is empty: {summary: at most two sentences on progress against the objective, status: \"on-track\"|\"at-risk\"|\"blocked\"|\"done\", mood: optional 3-5 single words for portrait art, facts: 5-7 glanceable rows [{id, label, value, kind, source, observedAt, detail}], detail: optional nested JSON with deeper levels than the rows show}. kind is \"measured\", \"evidence\" or \"judgment\". measuredFacts in the input are host measurements: to show one, include {id: its exact id, kind: \"measured\"}; Converse fills in its value. Never type a measured value yourself; a measured fact Converse does not have shows Unavailable. evidence facts must be traceable to supplied sessions or this run's research (source names the session id or exact URL); judgment facts are your explicitly labelled opinion. Do not reword an unchanged assessment just to look fresh. Never put credentials in an assessment.";

    public static List<AgentFactRecord> Measured(JsonObject? repositoryEvidence, string repository, DateTime now)
    {
        var facts = new List<AgentFactRecord>();
        if (repository.Length == 0) return facts;
        var observed = repositoryEvidence?["observedAt"] is JsonValue stamp && stamp.TryGetValue<string>(out var text) && DateTime.TryParse(text, null, System.Globalization.DateTimeStyles.RoundtripKind, out var at) ? at.ToUniversalTime() : now;
        string? Count(string key) => repositoryEvidence?[key] is JsonValue value && value.GetValueKind() == System.Text.Json.JsonValueKind.Number ? value.ToJsonString() : null;
        facts.Add(new AgentFactRecord { Id = "github.openIssues", Label = "Open issues", Value = Count("openIssues") ?? Unavailable, Kind = "measured", Source = "github.com/" + repository, ObservedAtUtc = observed });
        return facts;
    }

    static string Clip(string? text, int limit)
    {
        var value = System.Text.RegularExpressions.Regex.Replace(text ?? "", @"\s+", " ").Trim();
        return value[..Math.Min(value.Length, limit)];
    }
    static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    /// sourceRetrieved says whether a cited web URL was really seen this run;
    /// a fact citing any other URL keeps its row but reads Unavailable.
    public static (AgentAssessmentOutcome Kind, AgentAssessmentRecord? Record, string? Reason) Evaluate(JsonNode? raw, IReadOnlyList<AgentFactRecord> measured, AgentAssessmentRecord? previous, DateTime now, Func<string, bool>? sourceRetrieved = null)
    {
        if (raw is null) return (AgentAssessmentOutcome.Rejected, null, "No assessment returned this turn.");
        if (raw is not JsonObject root) return (AgentAssessmentOutcome.Rejected, null, "Assessment was not a JSON object.");
        var summary = Clip(Text(root["summary"]), 400);
        if (summary.Length == 0) return (AgentAssessmentOutcome.Rejected, null, "Assessment summary was missing.");
        var status = Clip(Text(root["status"]), 20).ToLowerInvariant().Replace('_', '-').Replace(' ', '-');
        if (!Statuses.Contains(status)) return (AgentAssessmentOutcome.Rejected, null, "Assessment status was missing or not on-track, at-risk, blocked or done.");
        var facts = new List<AgentFactRecord>();
        if (root["facts"] is { } list && list is not JsonArray) return (AgentAssessmentOutcome.Rejected, null, "Assessment facts were not an array.");
        foreach (var item in (root["facts"] as JsonArray ?? new()).OfType<JsonObject>().Take(12))
        {
            var id = Clip(Text(item["id"]), 120); var label = Clip(Text(item["label"]), 80);
            var host = id.Length > 0 ? measured.FirstOrDefault(m => m.Id == id) : null;
            var kind = Clip(Text(item["kind"]), 20).ToLowerInvariant();
            if (kind is not ("measured" or "evidence" or "judgment")) kind = host is not null ? "measured" : Text(item["source"])?.Length > 0 ? "evidence" : "judgment";
            AgentFactRecord fact;
            if (host is not null || kind == "measured")
            {
                host ??= label.Length > 0 ? measured.FirstOrDefault(m => string.Equals(m.Label, label, StringComparison.OrdinalIgnoreCase)) : null;
                fact = host is not null
                    ? new AgentFactRecord { Id = host.Id, Label = host.Label, Value = host.Value, Kind = "measured", Source = host.Source, ObservedAtUtc = host.ObservedAtUtc, Detail = host.Detail?.DeepClone() }
                    : new AgentFactRecord { Id = id.Length > 0 ? id : label, Label = label.Length > 0 ? label : id, Value = Unavailable, Kind = "measured", Source = "Not measured by Converse" };
            }
            else
            {
                var value = Clip(Text(item["value"]) ?? item["value"]?.ToJsonString(), 200);
                var stated = Text(item["observedAt"]) is { } stamp && DateTime.TryParse(stamp, null, System.Globalization.DateTimeStyles.RoundtripKind, out var at) && at.ToUniversalTime() <= now.AddMinutes(5) ? at.ToUniversalTime() : (DateTime?)null;
                var key = id.Length > 0 ? id : label;
                var earlier = previous?.Facts.FirstOrDefault(f => f.Id == key && f.Value == value)?.ObservedAtUtc;
                var cited = Clip(Text(item["source"]), 300);
                var isWeb = kind == "evidence" && Uri.TryCreate(cited, UriKind.Absolute, out var web) && web.Scheme is "http" or "https";
                if (isWeb && sourceRetrieved is not null && !sourceRetrieved(cited) && previous?.Facts.Any(f => f.Id == key && f.Value == value && f.Source == cited) != true)
                {
                    if (facts.All(f => f.Id != key) && key.Length > 0) facts.Add(new AgentFactRecord { Id = key, Label = label.Length > 0 ? label : id, Value = Unavailable, Kind = kind, Source = "Source not retrieved this run" });
                    continue;
                }
                fact = new AgentFactRecord { Id = key, Label = label.Length > 0 ? label : id, Value = value.Length > 0 ? value : Unavailable, Kind = kind,
                    Source = Clip(Text(item["source"]), 300) is { Length: > 0 } source ? source : kind == "judgment" ? "judgment" : "Unspecified",
                    ObservedAtUtc = stated ?? earlier ?? now, Detail = item["detail"]?.DeepClone() };
            }
            if (fact.Id.Length > 0 && facts.All(f => f.Id != fact.Id)) facts.Add(fact);
        }
        var mood = (root["mood"] as JsonArray)?.Select(m => Clip(Text(m), 24)).Where(m => m.Length > 0).Take(5).ToList();
        var next = new AgentAssessmentRecord { Summary = summary, Status = status, Facts = facts, Detail = root["detail"]?.DeepClone(), Mood = mood is { Count: > 0 } ? mood : null, UpdatedAtUtc = now, CheckedAtUtc = now };
        next.ContentHash = ContentHash(next);
        if (previous is not null && previous.ContentHash == next.ContentHash)
        {
            previous.CheckedAtUtc = now; previous.Heartbeats++; previous.Mood = next.Mood ?? previous.Mood;
            foreach (var fact in previous.Facts) if (fact.Kind == "measured" && next.Facts.FirstOrDefault(f => f.Id == fact.Id) is { } fresh) fact.ObservedAtUtc = fresh.ObservedAtUtc;
            return (AgentAssessmentOutcome.Heartbeat, previous, null);
        }
        next.Revision = (previous?.Revision ?? 0) + 1;
        return (AgentAssessmentOutcome.Revision, next, null);
    }

    public const int DisplayedFacts = 7;
    public static string StatusLabel(string status) => status switch { "on-track" => "On track", "at-risk" => "At risk", "blocked" => "Blocked", "done" => "Done", _ => status };
    /// Fresh under an hour, Aging under a day, then Old; Stale with a reason
    /// when the latest turn's assessment was rejected or none exists yet.
    public static string Freshness(AgentConfig agent, DateTime now)
    {
        if (agent.Assessment is not { } record) return agent.Widget is null ? "No assessment" : "Stale: seeded from the last scoreboard; the next turn replaces it.";
        if (agent.AssessmentProblem is { } problem) return "Stale: " + problem;
        var age = now - record.CheckedAtUtc;
        return age < TimeSpan.FromHours(1) ? "Fresh" : age < TimeSpan.FromDays(1) ? "Aging" : "Old";
    }
    /// What every widget shows (remote viewers and this app's agent panel):
    /// one source of truth, the latest assessment. A pre-assessment scoreboard
    /// widget is shown as a stale seed until the first assessment arrives.
    public static DeviceAgentWidget WidgetFor(AgentConfig agent, DateTime now)
    {
        if (agent.Assessment is not { } record)
        {
            var legacy = agent.Widget is null ? new DeviceAgentWidget { Summary = "No assessment yet. The agent's next turn adds one." } : DeviceJson.Decode<DeviceAgentWidget>(DeviceJson.Encode(agent.Widget));
            legacy.Freshness = Freshness(agent, now); legacy.Attention = agent.Attention;
            return legacy;
        }
        return new DeviceAgentWidget
        {
            Summary = record.Summary, Attention = agent.Attention,
            Metrics = record.Facts.Take(DisplayedFacts).Select(f => new DeviceWidgetMetric { Label = f.Label, Value = f.Value }).ToList(),
            ObservedAt = (record.CheckedAtUtc - new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds,
            Status = StatusLabel(record.Status), Freshness = Freshness(agent, now), Revision = record.Revision,
        };
    }

    /// Status, normalized summary, facts without observation times, and detail.
    public static string ContentHash(AgentAssessmentRecord record)
    {
        static JsonNode? Canonical(JsonNode? node) => node switch
        {
            JsonObject o => new JsonObject(o.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => KeyValuePair.Create(p.Key, Canonical(p.Value)))),
            JsonArray a => new JsonArray(a.Select(Canonical).ToArray()),
            null => null,
            _ => node.DeepClone(),
        };
        var facts = new JsonArray(record.Facts.OrderBy(f => f.Id, StringComparer.Ordinal).Select(f => (JsonNode)new JsonArray(f.Id, f.Label, f.Value, f.Kind, f.Source, f.Kind == "measured" ? null : Canonical(f.Detail))).ToArray());
        var body = new JsonArray(record.Status, Clip(record.Summary, 400).ToLowerInvariant(), facts, Canonical(record.Detail));
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(body.ToJsonString()))).ToLowerInvariant();
    }
}
