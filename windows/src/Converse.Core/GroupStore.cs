using System.Text.Json;
using System.Text.Json.Serialization;

namespace Converse.Core;

// Persistent group membership mirroring Swift ConverseGroupStore:
// converse-groups.json holds {currentID, groups} with immutable
// id/name/creator and permanent dissolution tombstones.
public sealed class ConverseGroupFile
{
    [JsonPropertyName("currentID")] public string? CurrentID { get; set; }
    [JsonPropertyName("groups")] public List<ConverseGroup> Groups { get; set; } = new();
}

public sealed class ConverseGroupStore
{
    private readonly string _file;
    private ConverseGroupFile _state = new();
    public ConverseGroup? Current => _state.Groups.FirstOrDefault(g => g.Id == _state.CurrentID && !g.Dissolved);
    public IReadOnlyList<ConverseGroup> Groups => _state.Groups;
    public bool Existed { get; }

    public ConverseGroupStore(string folder)
    {
        Directory.CreateDirectory(folder);
        _file = Path.Combine(folder, "converse-groups.json");
        if (!File.Exists(_file)) return;
        Existed = true;
        var state = JsonSerializer.Deserialize<ConverseGroupFile>(File.ReadAllBytes(_file))
            ?? throw new InvalidDataException("Invalid group store.");
        if (state.Groups.Count > 2048 || state.Groups.Any(g => !g.Valid)
            || state.Groups.Select(g => g.Id).ToHashSet().Count != state.Groups.Count)
            throw new InvalidDataException("Invalid group store.");
        _state = state;
    }

    private void Save(ConverseGroupFile next)
    {
        if (next.Groups.Count > 2048) throw new InvalidDataException("Group store limit.");
        AtomicJson.Write(_file, next);
        _state = next;
    }

    public void Adopt(ConverseGroup group)
    {
        if (!group.Valid || group.Dissolved
            || _state.Groups.FirstOrDefault(g => g.Id == group.Id) is { Dissolved: true })
            throw new InvalidDataException("Cannot adopt dissolved group.");
        if (_state.Groups.FirstOrDefault(g => g.Id == group.Id) is { } old
            && (old.Name != group.Name || old.Creator != group.Creator))
            throw new InvalidDataException("Group identity is immutable.");
        var next = new ConverseGroupFile { CurrentID = group.Id, Groups = _state.Groups.Where(g => g.Id != group.Id).Append(group).ToList() };
        Save(next);
    }

    public void Leave()
    {
        var next = new ConverseGroupFile { CurrentID = null, Groups = _state.Groups.ToList() };
        AtomicJson.Write(_file, next);
        _state = next;
    }

    public void Dissolve(ConverseGroup group)
    {
        if (!group.Valid) throw new InvalidDataException("Invalid group.");
        if (_state.Groups.FirstOrDefault(g => g.Id == group.Id) is { } old
            && (old.Name != group.Name || old.Creator != group.Creator))
            throw new InvalidDataException("Group identity is immutable.");
        var dead = new ConverseGroup { Id = group.Id, Name = group.Name, Creator = group.Creator, Dissolved = true };
        var next = new ConverseGroupFile
        {
            CurrentID = _state.CurrentID == group.Id ? null : _state.CurrentID,
            Groups = _state.Groups.Where(g => g.Id != group.Id).Append(dead).ToList(),
        };
        Save(next);
    }

    // Deterministic legacy migration, byte-identical to Swift: over the
    // active roster plus self, groups form only above one device; the UUID
    // is the dashed first 32 hex chars of the migration hash (no
    // version/variant bits — same as Swift's raw formatting).
    public static ConverseGroup? Migrate(IEnumerable<string> activeDeviceIDs)
    {
        var active = activeDeviceIDs.ToList();
        if (active.Count <= 1) return null;
        var first = active.OrderBy(id => id, StringComparer.Ordinal).First();
        var digest = DeviceBlob.Sha256Hex(System.Text.Encoding.UTF8.GetBytes("Converse legacy group v1/" + first));
        var raw = digest[..32];
        var id = raw[..8] + "-" + raw[8..12] + "-" + raw[12..16] + "-" + raw[16..20] + "-" + raw[20..32];
        return new ConverseGroup { Id = id, Name = "Converse Group", Creator = first };
    }
}

// Exact request equality for relayed review/approval binding: every field
// including the Apple-epoch double must match the sponsored original.
public static class GroupJoinRequests
{
    public static bool Same(GroupJoinRequest a, GroupJoinRequest b) =>
        a.Id == b.Id && a.GroupID == b.GroupID && a.RequesterID == b.RequesterID
        && a.RequesterName == b.RequesterName && a.SponsorID == b.SponsorID
        && a.ExpiresAt == b.ExpiresAt && a.Approved == b.Approved;
    public static bool Live(GroupJoinRequest request) => !request.Approved && request.ExpiresAt > DeviceTrustStore.AppleNow();
}
