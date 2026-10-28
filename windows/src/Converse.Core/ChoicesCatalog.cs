namespace Converse.Core;

/// <summary>
/// Static per-engine model/effort/access options for the settings row.
/// Values verified against real CLI help (claude --help, muse exec --help)
/// and the Mac catalog; live provider probing will supersede these lists
/// when it lands on Windows. Models stay free text (editable combo) so new
/// model IDs never need an app update; "CLI default" (null choice) omits the
/// flag entirely.
/// </summary>
public sealed record ChoiceOption(string Id, string Label);

public static class ChoicesCatalog
{
    public static IReadOnlyList<ChoiceOption> AccessFor(string engine) => engine switch
    {
        "claude" => new[]
        {
            new ChoiceOption("manual", "Manual"),
            new ChoiceOption("acceptEdits", "Accept edits"),
            new ChoiceOption("auto", "Auto"),
            new ChoiceOption("plan", "Plan"),
            new ChoiceOption("dontAsk", "Don't ask (deny unapproved)"),
            new ChoiceOption("bypassPermissions", "Bypass permissions"),
        },
        "codex" or "muse" => new[]
        {
            new ChoiceOption("read-only", "read-only"),
            new ChoiceOption("workspace-write", "workspace-write"),
            new ChoiceOption("danger-full-access", "danger-full-access"),
        },
        _ => Array.Empty<ChoiceOption>(),
    };

    public static IReadOnlyList<string> EffortsFor(string engine) => engine switch
    {
        "claude" => new[] { "low", "medium", "high", "xhigh", "max" },
        "codex" => new[] { "minimal", "low", "medium", "high", "xhigh" },
        "muse" => new[] { "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra" },
        _ => Array.Empty<string>(),
    };
}
