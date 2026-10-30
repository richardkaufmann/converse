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
}

public sealed class DeviceAgentSettings
{
    [JsonPropertyName("objective")] public string Objective { get; set; } = "Monitor progress and report blockers.";
    [JsonPropertyName("repository")] public string Repository { get; set; } = "";
    [JsonPropertyName("model")] public string Model { get; set; } = "muse-spark-1.3";
    [JsonPropertyName("watched")] public List<string> Watched { get; set; } = new();
    [JsonPropertyName("intervalSeconds")] public double IntervalSeconds { get; set; } = 900;
    [JsonPropertyName("remainingRuns")] public int RemainingRuns { get; set; } = 20;
    [JsonPropertyName("maxTurnsPerLoop")] public int? MaxTurnsPerLoop { get; set; }
    [JsonIgnore] public int TurnLimit { get => MaxTurnsPerLoop ?? Math.Max(1, RemainingRuns); set => MaxTurnsPerLoop = value; }
    [JsonPropertyName("enabled")] public bool Enabled { get; set; } = false;
    [JsonPropertyName("generateArt")] public bool GenerateArt { get; set; } = true;
    [JsonPropertyName("speak")] public bool Speak { get; set; } = false;
    [JsonPropertyName("discord")] public bool Discord { get; set; } = false;
    [JsonPropertyName("fileTriggers")] public bool FileTriggers { get; set; } = false;
    [JsonPropertyName("revision")] public ulong? Revision { get; set; } = 0;
    [JsonPropertyName("scoreboardEveryLoops")] public int? ScoreboardEveryLoops { get; set; } = 1;
    [JsonPropertyName("scheduleText")] public string? ScheduleText { get; set; } = "";
    [JsonPropertyName("discordShareSessionInformation")] public bool? DiscordShareSessionInformation { get; set; }
    [JsonPropertyName("discordShareScoreboard")] public bool? DiscordShareScoreboard { get; set; }
    [JsonPropertyName("scheduleTimeZone")] public string? ScheduleTimeZone { get; set; } = "UTC";
}

public sealed class DeviceParticipantRequest
{
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
