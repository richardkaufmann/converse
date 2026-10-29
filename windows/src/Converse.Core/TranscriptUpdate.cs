namespace Converse.Core;

// Decides how the transcript document absorbs a new history string without
// whole-document SetText (round-16 crash fix: the dumps pin SetText with a
// ~21K string as the faulting call). The UI tracks the last rendered history;
// streaming turns are pure appends, everything else falls back to a full
// rebuild. Pure so the Core suite can pin the transitions.
public static class TranscriptHistory
{
    // True when the document cannot absorb the new history incrementally:
    // first render, session switch, prepended earlier messages, or any edit
    // above the tail.
    public static bool NeedsFull(string? rendered, string history) =>
        rendered is null || !history.StartsWith(rendered, System.StringComparison.Ordinal);

    // True when the new history only adds to the rendered tail. Call only
    // when NeedsFull is false.
    public static bool IsAppend(string rendered, string history) =>
        history.Length > rendered.Length;
}
