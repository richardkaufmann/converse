using System.Text.Json.Serialization;
namespace Converse.Core;

public sealed class DeviceWidgetMetric
{
    [JsonPropertyName("label")] public string Label { get; set; } = "";
    [JsonPropertyName("value")] public string Value { get; set; } = "";
}

public sealed class DeviceAgentWidget
{
    [JsonPropertyName("summary")] public string Summary { get; set; } = "";
    [JsonPropertyName("metrics")] public List<DeviceWidgetMetric> Metrics { get; set; } = new();
    [JsonPropertyName("observedAt")] public double? ObservedAt { get; set; } = null;
    [JsonPropertyName("attention")] public string Attention { get; set; } = "";
    [JsonPropertyName("artHash")] public string? ArtHash { get; set; } = null;
    [JsonPropertyName("loopStatus")] public string? LoopStatus { get; set; } = null;
    // Derived from the latest assessment (AgentAssessments.WidgetFor). Older
    // homes omit these and send a scoreboard-shaped widget instead.
    [JsonPropertyName("status")] public string? Status { get; set; } = null;
    [JsonPropertyName("freshness")] public string? Freshness { get; set; } = null;
    [JsonPropertyName("revision")] public int? Revision { get; set; } = null;
}

public sealed class DeviceAgentSettings
{
    [JsonPropertyName("objective")] public string Objective { get; set; } = "Help me achieve the goals we agree on. Ask what success means, compare evidence with those goals, distinguish verified results from claims, and flag blockers. When research is available, identify the exact subject before searching: qualify ambiguous names with the project, owner, repository/domain, product category or other relevant context. Prefer official or primary sources, verify that each result is about the intended subject, and ignore unrelated namesakes. Use only public information in search queries, never private session text or secrets. If relevant evidence or a search tool is unavailable, say so instead of guessing.";
    [JsonPropertyName("repository")] public string Repository { get; set; } = "";
    [JsonPropertyName("modelOptions")] public List<DeviceChoiceDto>? ModelOptions { get; set; }
    [JsonPropertyName("model")] public string Model { get; set; } = "muse-spark-1.3";
    [JsonPropertyName("watched")] public List<string> Watched { get; set; } = new();
    [JsonPropertyName("intervalSeconds")] public double IntervalSeconds { get; set; } = 900;
    [JsonPropertyName("remainingRuns")] public int RemainingRuns { get; set; } = 20;
    [JsonPropertyName("maxTurnsPerLoop")] public int? MaxTurnsPerLoop { get; set; }
    [JsonIgnore] public int TurnLimit { get => MaxTurnsPerLoop ?? Math.Max(1, RemainingRuns); set => MaxTurnsPerLoop = value; }
    [JsonPropertyName("enabled")] public bool Enabled { get; set; } = false;
    [JsonPropertyName("artDirection")] public string? ArtDirection { get; set; }
    [JsonPropertyName("generateArt")] public bool GenerateArt { get; set; } = true;
    [JsonPropertyName("speak")] public bool Speak { get; set; } = false;
    [JsonPropertyName("discord")] public bool Discord { get; set; } = false;
    [JsonPropertyName("fileTriggers")] public bool FileTriggers { get; set; } = false;
    [JsonPropertyName("revision")] public ulong? Revision { get; set; } = 0;
    // Retired scoreboard cadence: older editors still send it; every turn assesses, so it is ignored.
    [JsonPropertyName("scoreboardEveryLoops")] public int? ScoreboardEveryLoops { get; set; } = null;
    [JsonPropertyName("scheduleText")] public string? ScheduleText { get; set; } = "";
    [JsonPropertyName("discordShareSessionInformation")] public bool? DiscordShareSessionInformation { get; set; }
    [JsonPropertyName("discordShareScoreboard")] public bool? DiscordShareScoreboard { get; set; }
    [JsonPropertyName("scheduleTimeZone")] public string? ScheduleTimeZone { get; set; } = "UTC";
    [JsonPropertyName("homeAssistantURL")] public string? HomeAssistantURL { get; set; }
    [JsonPropertyName("homeAssistantEntities")] public string? HomeAssistantEntities { get; set; }
    [JsonPropertyName("homeAssistantRead")] public bool? HomeAssistantRead { get; set; }
}

public sealed class DeviceParticipantRequest
{
    [JsonPropertyName("exportRequest")] public DeviceExportRequest? ExportRequest { get; set; }
    [JsonPropertyName("provider"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? Provider { get; set; } = null;
    [JsonPropertyName("groupID")] public string GroupID { get; set; } = "";
    [JsonPropertyName("action")] public string Action { get; set; } = "";
    [JsonPropertyName("target")] public string? Target { get; set; } = null;
    [JsonPropertyName("title")] public string? Title { get; set; } = null;
    [JsonPropertyName("settings")] public DeviceAgentSettings? Settings { get; set; } = null;
}

public sealed class DeviceParticipantEvidence
{
    [JsonPropertyName("globalID")] public string GlobalID { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("busy")] public bool Busy { get; set; } = false;
    [JsonPropertyName("status")] public string Status { get; set; } = "";
    [JsonPropertyName("messages")] public List<DeviceWireMessage> Messages { get; set; } = new();
}

public sealed class DeviceParticipantResponse
{
    [JsonPropertyName("exportPage")] public DeviceExportPage? ExportPage { get; set; }
    [JsonPropertyName("exportImage")] public byte[]? ExportImage { get; set; }
    [JsonPropertyName("exportImageTotal")] public int? ExportImageTotal { get; set; }
    [JsonPropertyName("groupID")] public string GroupID { get; set; } = "";
    [JsonPropertyName("outcome")] public string Outcome { get; set; } = "rejected";
    [JsonPropertyName("detail")] public string Detail { get; set; } = "";
    [JsonPropertyName("target")] public string? Target { get; set; } = null;
    [JsonPropertyName("evidence")] public DeviceParticipantEvidence? Evidence { get; set; } = null;
    [JsonPropertyName("settings")] public DeviceAgentSettings? Settings { get; set; } = null;
}

public sealed class DeviceTellPayload
{
    [JsonPropertyName("replyExpected")] public bool ReplyExpected { get; set; }
    [JsonPropertyName("inReplyTo")] public Guid? InReplyTo { get; set; }
    [JsonPropertyName("groupID")] public string GroupID { get; set; } = "";
    [JsonPropertyName("source")] public string Source { get; set; } = "";
    [JsonPropertyName("sourceTitle")] public string SourceTitle { get; set; } = "";
    [JsonPropertyName("target")] public string Target { get; set; } = "";
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("hop")] public int Hop { get; set; } = 1;
    [JsonPropertyName("urgent")] public bool Urgent { get; set; } = false;
}


public sealed class DeviceQueueWatch
{
    [JsonPropertyName("target")] public string Target { get; set; } = "";
    [JsonPropertyName("source")] public string Source { get; set; } = "";
    [JsonPropertyName("delivery")] public Guid Delivery { get; set; }
}
public sealed class DeviceQueueWatchReport
{
    [JsonPropertyName("groupID")] public string GroupID { get; set; } = "";
    [JsonPropertyName("entries")] public List<DeviceQueueWatch> Entries { get; set; } = new();
}

public sealed class DeviceExportRequest
{
    [JsonPropertyName("offset")] public int Offset { get; set; }
    [JsonPropertyName("total")] public int? Total { get; set; }
    [JsonPropertyName("fingerprint")] public string? Fingerprint { get; set; }
    [JsonPropertyName("imageHash")] public string? ImageHash { get; set; }
}
public sealed class DeviceExportPage
{
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("provider")] public string Provider { get; set; } = "";
    [JsonPropertyName("offset")] public int Offset { get; set; }
    [JsonPropertyName("total")] public int Total { get; set; }
    [JsonPropertyName("fingerprint")] public string Fingerprint { get; set; } = "";
    [JsonPropertyName("messages")] public List<DeviceWireMessage> Messages { get; set; } = new();
}
