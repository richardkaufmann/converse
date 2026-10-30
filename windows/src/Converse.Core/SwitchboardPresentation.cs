using System.Text.Json;
using System.Text.RegularExpressions;

namespace Converse.Core;

public static class SwitchboardPresentation
{
    public static bool IsQueueReceipt(string text) => text.StartsWith("Switchboard: message queued from ");
    private static string Clip(string value, int limit = 100)
    {
        var flat = Regex.Replace(value, @"\s+", " ").Trim();
        return flat.Length > limit ? flat[..(limit - 1)] + "…" : flat;
    }
    private static string Name(string value) => Clip(value.Split(" · ")[0].Split(" [")[0], 35);
    public static string? Summary(string source, bool queued = false, Func<string, string?>? resolveName = null)
    {
        var text = source.Trim();
        string Destination(string value) => resolveName?.Invoke(value) is { } name ? Clip(name, 35)
            : Guid.TryParse(value, out _) || value.Contains('/') ? "Unavailable session" : Clip(value, 35);
        var kind = text.Contains("[Reply expected") || text.Split('\n')[0].Contains("[ask]") ? "ask" : "tell";
        var lines = text.Split('\n');
        var detail = Clip(string.Join(" ", lines.Skip(1)));
        var suffix = detail.Length == 0 ? "" : " · " + detail;
        if (text.StartsWith("[Converse message from "))
            return (queued ? "Queued " : "Received ") + kind + " from " + Name(lines[0][23..]) + suffix;
        if (text.StartsWith("[Converse switchboard recovery")) return "Reply needed" + suffix;
        if (text.StartsWith("[Converse switchboard supervision")) return "Needs attention" + suffix;
        if (text.StartsWith("[Converse switchboard ")) return "Switchboard · " + Clip(lines[0].Trim('[', ']'));
        if (text.StartsWith("Switchboard:"))
        {
            var header = lines[0][12..].Trim();
            if (header.StartsWith("message queued from ")) return "Queued " + kind + " from " + Name(header[20..]) + suffix;
            var arrow = header.IndexOf('→');
            if (arrow >= 0) return (header.Contains("awaiting home") ? "Sending" : header.StartsWith("queued") ? "Queued" : header.StartsWith("rejected") ? "Rejected" : header.StartsWith("delivery unconfirmed") ? "Unconfirmed" : "Sent") + " " + kind + " to " + Name(header[(arrow + 1)..].Trim()) + suffix;
            return "Switchboard · " + Clip(header.Split(" · ")[0]);
        }
        if (text.StartsWith("```converse\n") && text.EndsWith("\n```"))
        {
            try
            {
                using var doc = JsonDocument.Parse(text[12..^4]);
                var root = doc.RootElement;
                var action = root.GetProperty("command").GetString();
                if (action is "tell" or "ask" or "tell-urgently")
                    return (action == "ask" || root.TryGetProperty("replyExpected", out var expected) && expected.ValueKind == JsonValueKind.True ? "Ask to " : "Tell to ") + Destination(root.GetProperty("to").GetString() ?? "session") + " · " + Clip(root.GetProperty("text").GetString() ?? "");
                return "Switchboard · " + action;
            }
            catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException) { }
        }
        return null;
    }
}
