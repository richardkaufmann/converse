using System.Text.Json;

namespace Converse.Core;

// Durable sync state mirroring Sources/DeviceSync.swift semantics.
public sealed class DeviceLeaseManager
{
    private readonly Func<DateTimeOffset> _now;
    private readonly TimeSpan _ttl;
    private readonly Func<Dictionary<Guid, ulong>, bool>? _persistEpochs;
    private readonly Dictionary<Guid, (string Device, ulong Epoch, DateTimeOffset ExpiresAt)> _leases = new();
    private Dictionary<Guid, ulong> _epochs;

    public DeviceLeaseManager(Func<DateTimeOffset>? now = null, double ttlSeconds = 15,
        Dictionary<Guid, ulong>? initialEpochs = null, Func<Dictionary<Guid, ulong>, bool>? persistEpochs = null)
    {
        _now = now ?? (() => DateTimeOffset.UtcNow);
        _ttl = TimeSpan.FromSeconds(ttlSeconds);
        _epochs = initialEpochs ?? new Dictionary<Guid, ulong>();
        _persistEpochs = persistEpochs;
    }

    public (bool Granted, ulong Epoch, string? Displaced) Acquire(Guid session, string device)
    {
        string? displaced = _leases.TryGetValue(session, out var old) && old.Device != device ? old.Device : null;
        var epoch = (_epochs.TryGetValue(session, out var current) ? current : 0) + 1;
        var candidate = new Dictionary<Guid, ulong>(_epochs) { [session] = epoch };
        // Fail closed: never grant an epoch that cannot be persisted.
        if (_persistEpochs is not null && !_persistEpochs(candidate))
            return (false, _epochs.GetValueOrDefault(session), null);
        _epochs = candidate;
        _leases[session] = (device, epoch, _now() + _ttl);
        return (true, epoch, displaced);
    }

    public bool Validate(Guid session, string device, ulong epoch)
    {
        if (!_leases.TryGetValue(session, out var lease)) return false;
        if (lease.ExpiresAt <= _now()) { _leases.Remove(session); return false; }
        return lease.Device == device && lease.Epoch == epoch;
    }

    public bool Heartbeat(Guid session, string device, ulong epoch)
    {
        if (!Validate(session, device, epoch)) return false;
        _leases[session] = (device, epoch, _now() + _ttl);
        return true;
    }

    public void Release(Guid session, string device, ulong epoch)
    {
        if (_leases.TryGetValue(session, out var lease) && lease.Device == device && lease.Epoch == epoch)
            _leases.Remove(session);
    }

    public void ForceRelease(Guid session, string device)
    {
        if (_leases.TryGetValue(session, out var lease) && lease.Device == device) _leases.Remove(session);
    }

    public (string Device, ulong Epoch)? Holder(Guid session)
    {
        if (!_leases.TryGetValue(session, out var lease) || lease.ExpiresAt <= _now()) return null;
        return (lease.Device, lease.Epoch);
    }

    public List<(Guid Session, string Device)> SweepExpired()
    {
        var expired = _leases.Where(pair => pair.Value.ExpiresAt <= _now())
            .Select(pair => (pair.Key, pair.Value.Device)).ToList();
        foreach (var entry in expired) _leases.Remove(entry.Key);
        return expired;
    }
}

public sealed class DeviceCommandRecord
{
    public Guid Id { get; set; }
    public string Origin { get; set; } = "";
    public string Outcome { get; set; } = "accepted";
    public DateTime UpdatedAt { get; set; }
    public string SessionID { get; set; } = "";
    public string PayloadHash { get; set; } = "";
}

public sealed class DeviceCommandStore
{
    private readonly string _file;
    public Dictionary<Guid, DeviceCommandRecord> Records { get; } = new();

    public DeviceCommandStore(string folder)
    {
        Directory.CreateDirectory(folder);
        _file = Path.Combine(folder, "device-commands.json");
        if (!File.Exists(_file)) return;
        var decoded = JsonSerializer.Deserialize<List<DeviceCommandRecord>>(File.ReadAllBytes(_file)) ?? new();
        foreach (var record in decoded)
        {
            if (record.Outcome is "running" or "accepted") record.Outcome = "uncertain";
            Records[record.Id] = record;
        }
        Save();
    }

    public bool Begin(Guid id, string origin, string sessionId = "", string payloadHash = "")
    {
        if (Records.ContainsKey(id)) return false;
        Records[id] = new DeviceCommandRecord { Id = id, Origin = origin, Outcome = "accepted", UpdatedAt = DateTime.UtcNow, SessionID = sessionId, PayloadHash = payloadHash };
        Save();
        return true;
    }

    public bool BindingMatches(Guid id, string origin, string sessionId, string payloadHash) =>
        Records.TryGetValue(id, out var record) && record.Origin == origin && record.SessionID == sessionId && record.PayloadHash == payloadHash;

    public void MarkRunning(Guid id) => Update(id, "running");
    public void MarkCompleted(Guid id) => Update(id, "completed");
    public void MarkFailed(Guid id) => Update(id, "failed");
    public string? Outcome(Guid id) => Records.TryGetValue(id, out var record) ? record.Outcome : null;

    private void Update(Guid id, string outcome)
    {
        if (!Records.TryGetValue(id, out var record)) return;
        record.Outcome = outcome; record.UpdatedAt = DateTime.UtcNow; Save();
    }
    private void Save() => AtomicJson.Write(_file, Records.Values.ToList());
}

public sealed class DeviceOutboxRecord
{
    public Guid CommandID { get; set; }
    public string SessionID { get; set; } = "";
    public DeviceCommandPayload Payload { get; set; } = new();
    public string PayloadHash { get; set; } = "";
    public ulong Epoch { get; set; }
    public string Outcome { get; set; } = "pending";
    public string? Detail { get; set; }
}

public sealed class DeviceOutboxStore
{
    private readonly string _file;
    public List<DeviceOutboxRecord> Records { get; } = new();
    public DeviceOutboxStore(string folder)
    {
        Directory.CreateDirectory(folder);
        _file = Path.Combine(folder, "device-outbox.json");
        if (File.Exists(_file))
            Records = JsonSerializer.Deserialize<List<DeviceOutboxRecord>>(File.ReadAllBytes(_file)) ?? new();
    }
    public void Add(DeviceOutboxRecord record)
    {
        Records.RemoveAll(r => r.CommandID == record.CommandID);
        Records.Add(record); Save();
    }
    // Only success removes the record; failures retain content for recovery.
    public void Resolve(Guid commandId, string outcome, string? detail)
    {
        var record = Records.FirstOrDefault(r => r.CommandID == commandId);
        if (record is null) return;
        if (outcome == "completed") Records.Remove(record);
        else { record.Outcome = outcome; record.Detail = detail; }
        Save();
    }
    public void MarkUncertain(string sessionId)
    {
        foreach (var record in Records.Where(r => r.SessionID == sessionId && r.Outcome == "pending"))
        {
            record.Outcome = "uncertain";
            record.Detail = "Home disconnected before acknowledgment. Check home before retrying.";
        }
        Save();
    }
    public void Remove(Guid commandId) { Records.RemoveAll(r => r.CommandID == commandId); Save(); }
    private void Save() => AtomicJson.Write(_file, Records);
}

// Draft versions keyed by routing key (home session UUID string at home,
// full global ID on viewers). Versions never regress on snapshot adoption.
public sealed class DeviceDraftTracker
{
    private readonly Dictionary<string, ulong> _versions = new();
    private readonly Dictionary<string, string> _texts = new();
    public bool Apply(string session, ulong version, string text)
    {
        if (version <= _versions.GetValueOrDefault(session)) return false;
        _versions[session] = version; _texts[session] = text; return true;
    }
    public string? Text(string session) => _texts.GetValueOrDefault(session);
    public ulong Version(string session) => _versions.GetValueOrDefault(session);
    public ulong Bump(string session, string text)
    {
        var next = Version(session) + 1;
        Apply(session, next, text);
        return next;
    }
    public void Adopt(string session, ulong version, string text)
    {
        _versions[session] = version; _texts[session] = text;
    }
    public bool AdoptIfNewer(string session, ulong version, string text)
    {
        if (version <= Version(session)) return false;
        Adopt(session, version, text); return true;
    }
}

internal static class AtomicJson
{
    public static void Write<T>(string file, T value)
    {
        var temp = file + ".tmp";
        File.WriteAllBytes(temp, JsonSerializer.SerializeToUtf8Bytes(value));
        File.Move(temp, file, overwrite: true);
    }
}
