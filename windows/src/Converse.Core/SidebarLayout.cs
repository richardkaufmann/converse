using System.Text.Json;

namespace Converse.Core;

/// <summary>
/// Pure layout state for the sidebar pin, shared contract on every platform:
/// the pin sits immediately left of the Conversation header and toggles
/// between the user's last expanded width and fully collapsed (width zero,
/// transcript takes the space). Collapsing is layout only — it never parks a
/// session, releases a lease, or touches the device service. Width intent
/// persists across restarts and window resizes; on restore the width is
/// clamped to at most half the available window width.
/// </summary>
public sealed class SidebarLayoutState
{
    public const double DefaultWidth = 340;
    public const double MinWidth = 220;
    public const double MaxWindowFraction = 0.5;

    public bool Collapsed { get; set; }
    public double ExpandedWidth { get; set; } = DefaultWidth;
    // Line-number gutter, Mac parity (Store.lineNumbers, default on).
    // Missing in older files; the initializer keeps the default true.
    public bool ShowLineNumbers { get; set; } = true;

    /// <summary>Effective sidebar width for the current window width.</summary>
    public double EffectiveWidth(double windowWidth)
    {
        if (Collapsed) return 0;
        return ClampWidth(ExpandedWidth, windowWidth);
    }

    /// <summary>Toggle via the pin. Returns the new collapsed state.</summary>
    public bool Toggle()
    {
        Collapsed = !Collapsed;
        return Collapsed;
    }

    /// <summary>Record a user drag of the sidebar edge as the width to restore.</summary>
    public void RecordUserWidth(double width, double windowWidth)
    {
        if (width <= 0) return;
        ExpandedWidth = ClampWidth(width, windowWidth);
    }

    public static double ClampWidth(double width, double windowWidth)
    {
        var max = windowWidth > 0 ? Math.Max(MinWidth, windowWidth * MaxWindowFraction) : width;
        return Math.Min(Math.Max(width, MinWidth), max);
    }

    private static string FilePath(string folder) => Path.Combine(folder, "window-layout.json");

    public static SidebarLayoutState Load(string folder)
    {
        try
        {
            var path = FilePath(folder);
            if (!File.Exists(path)) return new SidebarLayoutState();
            return JsonSerializer.Deserialize<SidebarLayoutState>(File.ReadAllText(path))
                   ?? new SidebarLayoutState();
        }
        catch { return new SidebarLayoutState(); }
    }

    public void Save(string folder)
    {
        try
        {
            Directory.CreateDirectory(folder);
            File.WriteAllText(FilePath(folder), JsonSerializer.Serialize(this));
        }
        catch { /* Layout persistence must never crash the shell. */ }
    }
}
