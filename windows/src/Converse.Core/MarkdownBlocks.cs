namespace Converse.Core;

// Block-level markdown for the transcript pane. Non-table text keeps the
// run-based rendering (MarkdownRuns); pipe tables become real cell grids
// (Mac NSTextTable parity). The walk mirrors MarkdownRuns.Render's table
// and fence rules so the two never disagree about what is a table.
public abstract record MdBlock;
public sealed record MdText(string Plain, List<MdRun> Runs) : MdBlock;
public sealed record MdTable(List<List<string>> Rows, List<string> Alignments) : MdBlock;

public static class MarkdownBlocks
{
    public static List<MdBlock> Parse(string body)
    {
        var blocks = new List<MdBlock>();
        var lines = (body ?? "").Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        var textLines = new List<string>();
        var inFence = false;

        void FlushText()
        {
            if (textLines.Count == 0) return;
            var (plain, runs) = MarkdownRuns.Render(string.Join("\n", textLines));
            if (plain.Length > 0 || blocks.Count == 0)
                blocks.Add(new MdText(plain, runs));
            textLines.Clear();
        }

        var i = 0;
        while (i < lines.Length)
        {
            var line = lines[i];
            var trimmed = line.TrimStart();
            if (trimmed.StartsWith("```", StringComparison.Ordinal))
                inFence = !inFence;
            if (!inFence && line.Contains('|') && i + 1 < lines.Length && IsDivider(lines[i + 1]))
            {
                FlushText();
                var rows = new List<List<string>> { Cells(line) };
                var alignments = Cells(lines[i + 1]);
                i += 2;
                while (i < lines.Length && lines[i].Trim().Length > 0 && lines[i].Contains('|'))
                {
                    rows.Add(Cells(lines[i]));
                    i++;
                }
                blocks.Add(new MdTable(rows, alignments));
                continue;
            }
            textLines.Add(line);
            i++;
        }
        FlushText();
        if (blocks.Count == 0)
            blocks.Add(new MdText(body ?? "", new List<MdRun>()));
        return blocks;
    }

    // Mac cells() parity: trim, strip one outer pipe pair, split, trim each.
    private static List<string> Cells(string line)
    {
        var trimmed = line.Trim();
        if (trimmed.StartsWith('|')) trimmed = trimmed[1..];
        if (trimmed.EndsWith('|')) trimmed = trimmed[..^1];
        return trimmed.Split('|').Select(c => c.Trim()).ToList();
    }

    private static bool IsDivider(string raw)
    {
        var line = raw.Trim();
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
}
