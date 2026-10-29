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
/// The caret breaks one ambiguity strings alone cannot: deleting history's
/// last content char while the draft starts with the same char produces
/// byte-identical text to deleting the separators plus the draft's head
/// (backspacing "text\r\r" + "typing" vs selecting "\r\rt" away). The former
/// leaves the caret inside history's core, the latter at or past it, so a
/// text change settling with the caret inside the core is always a revert.
/// </summary>
public static class EditorBoundary
{
    public static (bool HistoryOk, string Draft) Split(string full, string history, int caret)
    {
        var core = history.TrimEnd('\r');
        // The non-break core must match exactly in position. A trimmed
        // prefix slide let coinciding draft text mask a deleted tail.
        if (full.Length < core.Length
            || !full.Substring(0, core.Length).Equals(core, StringComparison.Ordinal))
            return (false, "");
        if (caret < core.Length)
            return (false, "");
        var trimmedFull = full.TrimEnd('\r');
        if (trimmedFull.Length < core.Length)
            return (false, "");
        var rest = trimmedFull.Substring(core.Length);
        // Separator remnant: history's trailing breaks may survive partially
        // in the document. Consume at most that many so genuine leading blank
        // lines in the draft survive.
        var budget = history.Length - core.Length;
        var consumed = 0;
        while (consumed < budget && consumed < rest.Length && rest[consumed] == '\r') consumed++;
        return (true, rest.Substring(consumed));
    }
}
