namespace Converse.Core;

public enum MdRunKind { Bold, Code, Heading, Table }

public sealed record MdRun(int Start, int Length, MdRunKind Kind, int Level = 0);

/// <summary>
/// Small chat-markdown renderer for the transcript: strips ## / ** / `
/// / link markers and reports formatting runs in stripped coordinates, so
/// the editor can tint ranges without skewing the gutter or draft math.
/// Same-line inline spans only; ``` fences drop whole lines; unmatched
/// markers stay literal. Headings are line-anchored ("## " prefix). Pipe
/// tables render as one monospace run with the divider row dropped (RichEdit
/// has no real tables); cell text stays literal so columns keep aligning.
/// </summary>
public static class MarkdownRuns
{
    public static (string Plain, List<MdRun> Runs) Render(string body)
    {
        var runs = new List<MdRun>();
        var outText = new System.Text.StringBuilder();
        var inFence = false;
        void AppendLine(string text)
        {
            if (outText.Length > 0) outText.Append('\n');
            outText.Append(text);
        }
        var raws = (body ?? "").Split('\n');
        var index = 0;
        while (index < raws.Length)
        {
            var line = raws[index].EndsWith('\r') ? raws[index][..^1] : raws[index];
            if (!inFence && line.Contains('|') && index + 1 < raws.Length && IsDivider(raws[index + 1]))
            {
                var blockStart = outText.Length == 0 ? 0 : outText.Length + 1;
                AppendLine(line);
                index += 2;
                while (index < raws.Length)
                {
                    var row = raws[index].EndsWith('\r') ? raws[index][..^1] : raws[index];
                    if (row.Trim().Length == 0 || !row.Contains('|')) break;
                    AppendLine(row);
                    index++;
                }
                runs.Add(new MdRun(blockStart, outText.Length - blockStart, MdRunKind.Table));
                continue;
            }
            var trimmed = line.TrimStart();
            if (trimmed.StartsWith("```", StringComparison.Ordinal))
            {
                inFence = !inFence;
                index++;
                continue;
            }
            var baseOffset = outText.Length == 0 ? 0 : outText.Length + 1;
            if (inFence)
            {
                AppendLine(line);
                index++;
                continue;
            }
            var level = 0;
            var text = line;
            if (trimmed.StartsWith('#'))
            {
                var hashes = 0;
                while (hashes < trimmed.Length && trimmed[hashes] == '#') hashes++;
                if (hashes is >= 1 and <= 6 && hashes < trimmed.Length && trimmed[hashes] == ' ')
                {
                    level = hashes;
                    text = trimmed[(hashes + 1)..];
                }
            }
            var (plain, inline) = Inline(text);
            if (level > 0 && plain.Length > 0)
                runs.Add(new MdRun(baseOffset, plain.Length, MdRunKind.Heading, level));
            else
                foreach (var run in inline)
                    runs.Add(run with { Start = run.Start + baseOffset });
            AppendLine(plain);
            index++;
        }
        return (outText.ToString(), runs);
    }

    private static bool IsDivider(string raw)
    {
        var line = (raw.EndsWith('\r') ? raw[..^1] : raw).Trim();
        if (line.StartsWith('|')) line = line[1..];
        if (line.EndsWith('|')) line = line[..^1];
        var cells = line.Split('|');
        if (cells.Length == 0) return false;
        foreach (var cell in cells)
        {
            var trimmed = cell.Trim();
            if (trimmed.Length < 1) return false;
            var inner = trimmed.Trim(':');
            if (inner.Length == 0 || inner.Any(c => c != '-')) return false;
        }
        return true;
    }

    private static (string Plain, List<MdRun> Runs) Inline(string text)
    {
        var plain = new System.Text.StringBuilder();
        var runs = new List<MdRun>();
        var i = 0;
        while (i < text.Length)
        {
            if (TrySpan(text, i, "**", MdRunKind.Bold) is { } bold)
            {
                runs.Add(new MdRun(bold.Start + plain.Length, bold.Text.Length, bold.Kind));
                plain.Append(bold.Text); i = bold.Next; continue;
            }
            if (TrySpan(text, i, "`", MdRunKind.Code) is { } code)
            {
                runs.Add(new MdRun(code.Start + plain.Length, code.Text.Length, code.Kind));
                plain.Append(code.Text); i = code.Next; continue;
            }
            if (text[i] == '[')
            {
                var close = text.IndexOf(']', i + 1);
                if (close > i + 1 && close + 1 < text.Length && text[close + 1] == '(')
                {
                    var end = text.IndexOf(')', close + 2);
                    if (end > close + 2) { plain.Append(text[(i + 1)..close]); i = end + 1; continue; }
                }
            }
            plain.Append(text[i]);
            i++;
        }
        return (plain.ToString(), runs);
    }

    private sealed record Span(int Start, MdRunKind Kind, string Text, int Next);

    private static Span? TrySpan(string text, int at, string marker, MdRunKind kind)
    {
        if (!text.AsSpan(at).StartsWith(marker, StringComparison.Ordinal)) return null;
        var close = text.IndexOf(marker, at + marker.Length, StringComparison.Ordinal);
        if (close < 0) return null;
        var inner = text[(at + marker.Length)..close];
        if (inner.Length == 0 || inner.Contains('\n')) return null;
        return new Span(0, kind, inner, close + marker.Length);
    }
}
