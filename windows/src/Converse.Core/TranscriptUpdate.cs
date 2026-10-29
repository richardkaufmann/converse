namespace Converse.Core;

// Decides how the transcript document absorbs a new history string without
// whole-document SetText (round-16 crash fix: the dumps pin SetText as the
// faulting call). The UI tracks the last rendered history plus the start of
// its last message. Streaming text lands BEFORE the trailing separator, so
// the rendered string is never a prefix of the new history (round-16 miss);
// the common prefix is the real absorb point. Pure so the Core suite can
// pin the transitions with BuildHistory-shaped literals.
public enum HistoryOp { Full, Replace, Same }

public static class TranscriptHistory
{
    public static (HistoryOp Op, int Start) Plan(string? rendered, string history, int lastMessageStart)
    {
        if (rendered is null)
            return (HistoryOp.Full, 0);
        var limit = System.Math.Min(rendered.Length, history.Length);
        var p = 0;
        while (p < limit && rendered[p] == history[p]) p++;
        if (p == rendered.Length && p == history.Length)
            return (HistoryOp.Same, p);
        // Edits above the last message (prepend, mid-history rewrite) keep
        // the full rebuild, which preserves the reading position.
        if (p < lastMessageStart)
            return (HistoryOp.Full, 0);
        return (HistoryOp.Replace, p);
    }
}
