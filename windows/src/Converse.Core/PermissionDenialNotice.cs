using System.Text.Json;

namespace Converse.Core;

// Headless Claude denies tools its permission mode does not allow and lists
// them in the final result's permission_denials. Name them once, so a refusal
// does not look like Converse failing. Summaries show a path or command,
// never file contents (Mac parity: PermissionDenialNotice in ProviderSupport).
public static class PermissionDenialNotice
{
    private static readonly string[] SummaryKeys = ["file_path", "notebook_path", "path", "command", "url", "pattern", "query"];

    public static string Summary(JsonElement input)
    {
        if (input.ValueKind != JsonValueKind.Object) return "";
        foreach (var key in SummaryKeys)
        {
            if (!input.TryGetProperty(key, out var raw) || raw.ValueKind != JsonValueKind.String) continue;
            var value = string.Join(' ', (raw.GetString() ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
            if (value.Length == 0) continue;
            if (key.EndsWith("path"))
            {
                var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                if (home.Length > 0 && (value == home || value.StartsWith(home + "/") || value.StartsWith(home + "\\"))) value = "~" + value[home.Length..];
                return value.Length > 80 ? "…" + value[^79..] : value;
            }
            return value.Length > 80 ? value[..79] + "…" : value;
        }
        return "";
    }

    // Returns null when nothing new was denied; `seen` keeps later results in
    // the same turn from repeating tools already named.
    public static string? Text(JsonElement denials, ISet<string> seen)
    {
        if (denials.ValueKind != JsonValueKind.Array) return null;
        var items = new List<string>();
        foreach (var denial in denials.EnumerateArray())
        {
            if (denial.ValueKind != JsonValueKind.Object) continue;
            var tool = denial.TryGetProperty("tool_name", out var name) && name.ValueKind == JsonValueKind.String && name.GetString() is { Length: > 0 } n ? n : "a tool";
            var detail = denial.TryGetProperty("tool_input", out var input) ? Summary(input) : "";
            var item = detail.Length == 0 ? tool : $"{tool} ({detail})";
            var key = denial.TryGetProperty("tool_use_id", out var id) && id.ValueKind == JsonValueKind.String ? id.GetString()! : item;
            if (!seen.Add(key) || items.Contains(item)) continue;
            items.Add(item);
        }
        if (items.Count == 0) return null;
        var listed = string.Join(", ", items.Take(3)) + (items.Count > 3 ? $" +{items.Count - 3} more" : "");
        return $"This session’s Access setting blocked: {listed}. To allow it, change Access in the footer (for example Auto or Bypass permissions) and send again.";
    }
}
