using System.Text.Json;

namespace Converse.Core;

/// <summary>
/// Pane assignments for the window, Mac parity: every session row has
/// P/1/2/3/X. Assigning a session to a pane removes its previous placement
/// and parks (unplaces) whatever occupied that pane. Parking is layout and
/// lease-view state only: it never closes a session, stops a CLI, or touches
/// group membership. Keys are sidebar keys ("local:{id}"/"remote:{global}").
/// Persisted beside the sidebar layout; unknown keys prune on load.
/// </summary>
public sealed class PanePlacements
{
    public const int MinPane = 1;
    public const int MaxPane = 3;

    public Dictionary<int, string> Slots { get; set; } = new();

    public static bool ValidPane(int pane) => pane is >= MinPane and <= MaxPane;

    /// <summary>Place key in pane, evicting any occupant. Returns the evicted key, if any.</summary>
    public string? Assign(string key, int pane)
    {
        if (!ValidPane(pane) || string.IsNullOrEmpty(key)) return null;
        string? evicted = null;
        foreach (var (slot, occupant) in Slots.ToList())
        {
            if (occupant == key) Slots.Remove(slot);
            else if (slot == pane) { evicted = occupant; Slots.Remove(slot); }
        }
        Slots[pane] = key;
        return evicted == key ? null : evicted;
    }

    public void Park(string key)
    {
        if (string.IsNullOrEmpty(key)) return;
        foreach (var (slot, occupant) in Slots.ToList())
            if (occupant == key) Slots.Remove(slot);
    }

    public int? PaneOf(string key)
    {
        if (string.IsNullOrEmpty(key)) return null;
        foreach (var (slot, occupant) in Slots)
            if (occupant == key) return slot;
        return null;
    }

    public string? KeyIn(int pane) => Slots.TryGetValue(pane, out var key) ? key : null;

    public void Clear() => Slots.Clear();

    private static string FilePath(string folder) => Path.Combine(folder, "pane-layout.json");

    public void Save(string folder)
    {
        try
        {
            Directory.CreateDirectory(folder);
            File.WriteAllText(FilePath(folder), JsonSerializer.Serialize(this));
        }
        catch { /* Placement persistence must never crash the shell. */ }
    }

    public static PanePlacements Load(string folder)
    {
        try
        {
            var path = FilePath(folder);
            if (!File.Exists(path)) return new PanePlacements();
            var loaded = JsonSerializer.Deserialize<PanePlacements>(File.ReadAllText(path));
            var clean = new PanePlacements();
            if (loaded?.Slots is null) return clean;
            foreach (var (slot, key) in loaded.Slots)
                if (ValidPane(slot) && !string.IsNullOrEmpty(key) && clean.PaneOf(key) is null)
                    clean.Slots[slot] = key;
            return clean;
        }
        catch { return new PanePlacements(); }
    }
}
