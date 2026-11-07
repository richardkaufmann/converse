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
        var asks = text.Contains("[Reply expected") || text.Split('\n')[0].Contains("[ask]");
        // An incoming message carrying inReplyTo answers the recipient's own
        // request; it must read as a reply, not as a fresh tell or ask.
        var replies = text.Contains("\n[Reply to request ");
        var kind = replies ? (asks ? "reply + ask" : "reply") : asks ? "ask" : "tell";
        // The delivery instructions trail the body; keep them out of the detail.
        var cut = new[] { text.IndexOf("\n[Reply to request ", StringComparison.Ordinal), text.IndexOf("\n[Reply expected", StringComparison.Ordinal) }.Where(i => i >= 0).DefaultIfEmpty(text.Length).Min();
        var lines = text.Split('\n');
        var detail = Clip(string.Join(" ", text[..cut].Split('\n').Skip(1)));
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

    /// Inject all joins queued prompts with this separator.
    public const string InjectSeparator = "\n\n";
    public static string ComponentKind(string text, bool typed) =>
        typed ? MessageComponent.Human : Summary(text) is not null ? MessageComponent.Traffic : MessageComponent.Plain;
    /// Component ranges for parts joined by Inject all, or null unless the
    /// parts reproduce the merged text exactly.
    public static List<MessageComponent>? Components(IReadOnlyList<(string Text, string Kind)> parts, string text)
    {
        if (parts.Count < 2 || string.Join(InjectSeparator, parts.Select(p => p.Text)) != text) return null;
        var offset = 0;
        var result = new List<MessageComponent>();
        foreach (var (part, kind) in parts)
        {
            result.Add(new MessageComponent { Offset = offset, Length = part.Length, Kind = kind });
            offset += part.Length + InjectSeparator.Length;
        }
        return result;
    }
    /// One-line queue label: a summary only when the whole item is traffic.
    public static string? QueueSummary(string text, IReadOnlyList<MessageComponent>? components = null) =>
        Segments(text, components) is null ? Summary(text, queued: true) : null;
    /// Parts of a merged message to render separately (Swift parity): traffic
    /// parts with their own summary, everything else in full. Null renders the
    /// message whole, exactly as before.
    public static List<TranscriptSegment>? Segments(string source, IReadOnlyList<MessageComponent>? components, Func<string, string?>? resolveName = null)
    {
        if (components is { Count: > 1 })
        {
            var cursor = 0;
            var result = new List<TranscriptSegment>();
            int? plainStart = null;
            bool Blank(int start, int length) => string.IsNullOrWhiteSpace(source.Substring(start, length));
            foreach (var component in components)
            {
                // Untrusted ranges never hide text: anything outside them
                // must be blank, or the message falls back below.
                if (component.Offset < cursor || component.Offset > source.Length || component.Length < 0
                    || component.Length > source.Length - component.Offset || !Blank(cursor, component.Offset - cursor)) { result.Clear(); break; }
                var part = source.Substring(component.Offset, component.Length);
                var summary = component.Kind == MessageComponent.Traffic ? Summary(part, resolveName: resolveName) : null;
                cursor = component.Offset + component.Length;
                if (string.IsNullOrWhiteSpace(part)) continue;
                // Adjacent visible parts stay one block with their separator.
                if (summary is null && plainStart is { } start) { result[^1] = result[^1] with { Text = source[start..cursor] }; continue; }
                plainStart = summary is null ? component.Offset : null;
                result.Add(new TranscriptSegment(part, summary));
            }
            if (result.Count > 0 && Blank(cursor, source.Length - cursor))
                // Plain parts alone render as before, unless the whole would
                // otherwise collapse over a visible part.
                return result.Any(segment => segment.Summary is not null) || Summary(source) is not null ? result : null;
        }
        return LegacySegments(source, resolveName);
    }
    /// Messages merged before component metadata. Splits only after a
    /// complete delivery block followed by the Inject all separator, and never
    /// says who wrote the remainder. A delivery block followed by anything
    /// else shows the whole message expanded.
    public static List<TranscriptSegment>? LegacySegments(string source, Func<string, string?>? resolveName = null)
    {
        const string envelope = "[Converse message from ";
        // Every render asks about ordinary prompts too; check before copying.
        if (!source.AsSpan().TrimStart().StartsWith(envelope, StringComparison.Ordinal)) return null;
        var text = source.Trim();
        var result = new List<TranscriptSegment>();
        var rest = text;
        var trailing = false;
        while (rest.StartsWith(envelope, StringComparison.Ordinal) && DeliveryEnd(rest, ref trailing) is { } found)
        {
            var part = rest[..found.End];
            result.Add(new TranscriptSegment(part, Summary(part, resolveName: resolveName)));
            rest = rest[found.Next..];
        }
        if (result.Count == 0) return trailing ? new List<TranscriptSegment> { new(source, null) } : null;
        var remainder = rest.Trim('\r', '\n');
        if (remainder.Length > 0) result.Add(new TranscriptSegment(remainder, null));
        return result.Count > 1 ? result : null;
    }
    // End of the first delivery block that closes an envelope, and where the
    // next part starts (the end of the text when nothing follows).
    private static (int End, int Next)? DeliveryEnd(string text, ref bool trailing)
    {
        const string reply = "[Reply to request ", expected = "[Reply expected · request ID:\n";
        bool At(int index, string value) => index <= text.Length && text.AsSpan(index).StartsWith(value, StringComparison.Ordinal);
        int? Uuid(int from) => from + 36 <= text.Length && Guid.TryParseExact(text.Substring(from, 36), "D", out _) ? from + 36 : null;
        int? ExpectedEnd(int from)
        {
            if (!At(from, expected) || Uuid(from + expected.Length) is not { } id || !At(id, "\n")) return null;
            var close = text.IndexOf(']', id);
            return close < 0 ? null : close + 1;
        }
        int? BlockEnd(int from)
        {
            if (!At(from, reply)) return ExpectedEnd(from);
            if (Uuid(from + reply.Length) is not { } id || !At(id, "]")) return null;
            return At(id + 1, "\n" + expected) ? ExpectedEnd(id + 2) : id + 1;
        }
        var search = 0;
        while (text.IndexOf('\n', search) is var marker && marker >= 0)
        {
            search = marker + 1;
            if (!(At(search, reply) || At(search, expected)) || BlockEnd(search) is not { } end) continue;
            if (string.IsNullOrWhiteSpace(text[end..])) return (end, text.Length);
            if (At(end, InjectSeparator)) return (end, end + InjectSeparator.Length);
            trailing = true;
        }
        return null;
    }
}

/// One rendered part of a message. A null Summary shows Text in full.
public sealed record TranscriptSegment(string Text, string? Summary);
