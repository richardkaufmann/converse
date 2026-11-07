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
    /// One visible part over all of text: what a merged message renders as
    /// when its recorded ranges cannot be carried through a rewrite.
    public static List<MessageComponent> ExpandedComponents(string text) =>
        new() { new MessageComponent { Offset = 0, Length = text.Length, Kind = MessageComponent.Plain } };
    /// Whether recorded ranges are in order, inside the text, and leave
    /// nothing but whitespace uncovered.
    public static bool ComponentsTile(string source, IReadOnlyList<MessageComponent> components)
    {
        var cursor = 0;
        foreach (var component in components)
        {
            if (component.Offset < cursor || component.Offset > source.Length || component.Length < 0
                || component.Length > source.Length - component.Offset || !string.IsNullOrWhiteSpace(source[cursor..component.Offset])) return false;
            cursor = component.Offset + component.Length;
        }
        return string.IsNullOrWhiteSpace(source[cursor..]);
    }
    /// Components for text, a display rewrite of source (Swift parity).
    /// Parts survive when rewriting each piece reproduces text exactly;
    /// anything else that had parts becomes one visible part, so lost or
    /// invalid ranges never fall back to a whole-message summary.
    public static List<MessageComponent>? Components(IReadOnlyList<MessageComponent>? components, string source, string text, Func<string, string> rewrite)
    {
        if (components is null) return null;
        if (!ComponentsTile(source, components)) return ExpandedComponents(text);
        if (text == source) return components.ToList();
        var rebuilt = new System.Text.StringBuilder();
        var cursor = 0;
        var result = new List<MessageComponent>();
        foreach (var component in components)
        {
            rebuilt.Append(rewrite(source[cursor..component.Offset]));
            var part = rewrite(source.Substring(component.Offset, component.Length));
            result.Add(new MessageComponent { Offset = rebuilt.Length, Length = part.Length, Kind = component.Kind });
            rebuilt.Append(part);
            cursor = component.Offset + component.Length;
        }
        rebuilt.Append(rewrite(source[cursor..]));
        return rebuilt.ToString() == text ? result : ExpandedComponents(text);
    }
    /// One-line queue label: a summary only when the whole item is traffic.
    public static string? QueueSummary(string text, IReadOnlyList<MessageComponent>? components = null) =>
        Segments(text, components) is null ? Summary(text, queued: true) : null;
    /// Parts of a merged message to render separately (Swift parity): traffic
    /// parts with their own summary, everything else in full. Null renders the
    /// message whole, exactly as before. Recorded components that do not tile
    /// the text show it all expanded; only messages without them use the
    /// conservative legacy split.
    public static List<TranscriptSegment>? Segments(string source, IReadOnlyList<MessageComponent>? components, Func<string, string?>? resolveName = null)
    {
        if (components is null) return LegacySegments(source, resolveName);
        // Untrusted ranges never hide text, and never fall back to a
        // whole-message summary that could cover a typed part.
        if (!ComponentsTile(source, components)) return new List<TranscriptSegment> { new(source, null) };
        var result = new List<TranscriptSegment>();
        int? plainStart = null;
        foreach (var component in components)
        {
            var part = source.Substring(component.Offset, component.Length);
            var summary = component.Kind == MessageComponent.Traffic ? Summary(part, resolveName: resolveName) : null;
            var end = component.Offset + component.Length;
            if (string.IsNullOrWhiteSpace(part)) continue;
            // Adjacent visible parts stay one block with their separator.
            if (summary is null && plainStart is { } start) { result[^1] = result[^1] with { Text = source[start..end] }; continue; }
            plainStart = summary is null ? component.Offset : null;
            result.Add(new TranscriptSegment(part, summary));
        }
        // Plain parts alone render as before, unless the whole would
        // otherwise collapse over a visible part.
        return result.Count > 0 && (result.Any(segment => segment.Summary is not null) || Summary(source) is not null) ? result : null;
    }
    /// Messages merged before component metadata. Splits only after a
    /// complete delivery block followed by the Inject all separator, and never
    /// says who wrote the remainder. A delivery block followed by anything
    /// else shows the whole message expanded. A plain tell has no delivery
    /// block, so an old merge of one with typed text cannot be told apart from
    /// a multi-paragraph tell: it still collapses, as before.
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
