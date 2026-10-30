using System.Text.Json;
using System.Text.RegularExpressions;

namespace Converse.Core;

public static class ProviderInput
{
    // Claude's directory grant does not attach images. Send rich user content
    // over stdin; large base64 payloads must never go through Windows argv.
    public static async Task<string> CreateAsync(string engine, string prompt, IReadOnlyList<string> images)
    {
        if (engine != "claude" || images.Count == 0) return prompt;
        var content = new List<object> { new { type = "text", text = prompt } };
        foreach (var path in images)
        {
            var bytes = await File.ReadAllBytesAsync(path);
            var mime = ImageMime(bytes) ?? throw new InvalidOperationException(
                "Unsupported attachment. Use PNG, JPEG, GIF or WebP: " + Path.GetFileName(path));
            content.Add(new { type = "image", source = new { type = "base64", media_type = mime, data = Convert.ToBase64String(bytes) } });
        }
        return JsonSerializer.Serialize(new { type = "user", message = new { role = "user", content }, parent_tool_use_id = (string?)null });
    }

    // Remote blob names have no image extension. Identify their actual bytes.
    public static string? ImageMime(ReadOnlySpan<byte> data)
    {
        if (data.StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })) return "image/png";
        if (data.StartsWith(new byte[] { 255, 216, 255 })) return "image/jpeg";
        if (data.StartsWith("GIF87a"u8) || data.StartsWith("GIF89a"u8)) return "image/gif";
        if (data.Length >= 12 && data[..4].SequenceEqual("RIFF"u8) && data.Slice(8, 4).SequenceEqual("WEBP"u8)) return "image/webp";
        return null;
    }
}

public static class ProviderRetry
{
    public static string Status(string engine) => "Waiting for " + (engine == "codex" ? "OpenAI" : engine == "claude" ? "Claude" : "Muse") + "… reconnecting";

    public static string? Detail(string line)
    {
        var message = line.Trim();
        try
        {
            using var doc = JsonDocument.Parse(line);
            var obj = doc.RootElement;
            if (obj.ValueKind != JsonValueKind.Object) return null;
            var type = obj.TryGetProperty("type", out var t) ? t.GetString() : null;
            // Never hide assistant text or terminal failures that mention retries.
            if (type != "error" && type != "system") return null;
            if (obj.TryGetProperty("subtype", out var sub) && sub.GetString() == "api_retry") return "Provider is retrying the request.";
            if (obj.TryGetProperty("willRetry", out var will) && will.ValueKind == JsonValueKind.False) return null;
            message = obj.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.String ? m.GetString()! : "";
            if (obj.TryGetProperty("willRetry", out will) && will.ValueKind == JsonValueKind.True) return message;
        }
        catch (JsonException) { }
        return Regex.IsMatch(message, @"^Reconnecting(?:\.\.\.|…)\s*\d+/\d+(?:\s|$)", RegexOptions.IgnoreCase) ? message : null;
    }
}
