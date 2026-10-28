namespace Converse.Core;

/// <summary>
/// Tolerant split of RichEditBox document text into protected history and the
/// editable draft tail. RichEdit paragraph breaks do not round-trip exactly:
/// SetText("a\r\r") may read back with collapsed trailing breaks plus exactly
/// one document terminator, so a naive StartsWith(history) check eats every
/// keystroke in sessions with history (the PC "cannot type anything" bug).
/// Both sides are compared with trailing breaks trimmed, up to history's own
/// trailing-break count is consumed as separator remnant, and the single
/// GetText terminator is stripped. A draft the user edits inside history
/// still fails the check and must be reverted by the caller.
/// </summary>
public static class EditorBoundary
{
    public static (bool HistoryOk, string Draft) Split(string full, string history)
    {
        var trimmedHistory = history.TrimEnd('\r');
        var trimmedFull = full.TrimEnd('\r');
        if (!trimmedFull.StartsWith(trimmedHistory, StringComparison.Ordinal))
            return (false, "");
        var rest = trimmedFull.Substring(trimmedHistory.Length);
        // Separator remnant: history's trailing breaks may survive partially
        // in the document. Consume at most that many so genuine leading blank
        // lines in the draft survive.
        var budget = history.Length - trimmedHistory.Length;
        var consumed = 0;
        while (consumed < budget && consumed < rest.Length && rest[consumed] == '\r') consumed++;
        return (true, rest.Substring(consumed));
    }
}
