using System.Text.Json;
using System.Text.RegularExpressions;

namespace Converse.Core;

public static class SwitchboardPresentation
{
    private static string Clip(string value, int limit = 100)
    {
        var flat = Regex.Replace(value, @"\s+", " ").Trim();
        return flat.Length > limit ? flat[..(limit - 1)] + "…" : flat;
    }
    private static string Name(string value) => Clip(value.Split(" · session ")[0].Split(" [")[0], 35);
    public static string? Summary(string source, bool queued = false)
    {
        var text = source.Trim();
        var lines = text.Split('\n');
        var detail = Clip(string.Join(" ", lines.Skip(1)));
        var suffix = detail.Length == 0 ? "" : " · " + detail;
        if (text.StartsWith("[Converse message from "))
            return (queued ? "Queued ← " : "Received ← ") + Name(lines[0][23..])
                + (text.Contains("[Reply expected") ? " · Reply expected" : "") + suffix;
        if (text.StartsWith("[Converse switchboard recovery")) return "Reply needed" + suffix;
        if (text.StartsWith("[Converse switchboard supervision")) return "Needs attention" + suffix;
        if (text.StartsWith("[Converse switchboard ")) return "Switchboard · " + Clip(lines[0].Trim('[', ']'));
        if (text.StartsWith("Switchboard:"))
        {
            var header = lines[0][12..].Trim();
            if (header.StartsWith("message queued from ")) return "Queued ← " + Name(header[20..]) + suffix;
            var arrow = header.IndexOf('→');
            if (arrow >= 0) return (header.Contains("awaiting home") ? "Sending" : header.StartsWith("queued") ? "Queued" : "Sent") + " → " + Name(header[(arrow + 1)..].Trim()) + suffix;
            return "Switchboard · " + Clip(header);
        }
        if (text.StartsWith("```converse\n") && text.EndsWith("\n```"))
        {
            try
            {
                using var doc = JsonDocument.Parse(text[12..^4]);
                var root = doc.RootElement;
                var action = root.GetProperty("command").GetString();
                if (action is "tell" or "tell-urgently")
                    return "Tell → " + Clip(root.GetProperty("to").GetString() ?? "session", 28) + " · " + Clip(root.GetProperty("text").GetString() ?? "");
                return "Switchboard · " + action;
            }
            catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException) { }
        }
        return null;
    }
}
