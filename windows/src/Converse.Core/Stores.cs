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
    private readonly ulong _initialEpoch;

    public DeviceLeaseManager(Func<DateTimeOffset>? now = null, double ttlSeconds = 15,
        Dictionary<Guid, ulong>? initialEpochs = null, Func<Dictionary<Guid, ulong>, bool>? persistEpochs = null, ulong initialEpoch = 0)
    {
        _now = now ?? (() => DateTimeOffset.UtcNow);
        _ttl = TimeSpan.FromSeconds(ttlSeconds);
        _epochs = initialEpochs ?? new Dictionary<Guid, ulong>();
        _persistEpochs = persistEpochs;
        _initialEpoch = initialEpoch;
    }

    public (bool Granted, ulong Epoch, string? Displaced) Acquire(Guid session, string device)
    {
        string? displaced = _leases.TryGetValue(session, out var old) && old.Device != device ? old.Device : null;
        var current = _epochs.TryGetValue(session, out var saved) ? saved : _initialEpoch;
        if (current == ulong.MaxValue) return (false, current, null);
        var epoch = current + 1;
        var candidate = new Dictionary<Guid, ulong>(_epochs) { [session] = epoch };
        // Fail closed: never grant an epoch that cannot be persisted.
        if (_persistEpochs is not null && !_persistEpochs(candidate))
            return (false, _epochs.GetValueOrDefault(session), null);
        _epochs = candidate;
        _leases[session] = (device, epoch, _now() + _ttl);
        return (true, epoch, displaced);
    }

    public (bool Granted, ulong Epoch, string? Displaced) Resume(Guid session, string device, ulong expectedEpoch)
    {
        if (!_epochs.TryGetValue(session, out var current) || current != expectedEpoch ||
            (Holder(session) is { } holder && holder.Device != device)) return (false, _epochs.GetValueOrDefault(session), null);
        return Acquire(session, device);
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

    internal void ExpireForTest(Guid session)
    {
        if (_leases.TryGetValue(session, out var lease)) _leases[session] = (lease.Device, lease.Epoch, _now().AddSeconds(-1));
    }

    public List<(Guid Session, string Device, ulong Epoch)> SweepExpired()
    {
        var expired = _leases.Where(pair => pair.Value.ExpiresAt <= _now())
            .Select(pair => (pair.Key, pair.Value.Device, pair.Value.Epoch)).ToList();
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
    // Absent on records written before canonical binding: those keep raw
    // byte hashes, so only an identical legacy retry still matches.
    public string? HashScheme { get; set; }
}

public sealed class DeviceCommandStore
{
    private readonly string _file;
    // Overlapping connections deliver commands concurrently.
    private readonly object _gate = new();
    private readonly Dictionary<Guid, DeviceCommandRecord> _records = new();
    public Dictionary<Guid, DeviceCommandRecord> Records { get { lock (_gate) return new(_records); } }

    public DeviceCommandStore(string folder)
    {
        Directory.CreateDirectory(folder);
        _file = Path.Combine(folder, "device-commands.json");
        if (!File.Exists(_file)) return;
        var decoded = JsonSerializer.Deserialize<List<DeviceCommandRecord>>(File.ReadAllBytes(_file)) ?? new();
        foreach (var record in decoded)
        {
            if (record.Outcome is "running" or "accepted") record.Outcome = "uncertain";
            _records[record.Id] = record;
        }
        Save();
    }

    public bool Begin(Guid id, string origin, string sessionId = "", string payloadHash = "", string? hashScheme = null)
    {
        lock (_gate)
        {
            if (_records.ContainsKey(id)) return false;
            _records[id] = new DeviceCommandRecord { Id = id, Origin = origin, Outcome = "accepted", UpdatedAt = DateTime.UtcNow, SessionID = sessionId, PayloadHash = payloadHash, HashScheme = hashScheme };
            Save();
            return true;
        }
    }

    // Compares under the scheme the record was written with.
    public bool BindingMatches(Guid id, string origin, string sessionId, byte[] payload) =>
        Find(id) is { } record && record.Origin == origin && record.SessionID == sessionId
        && DeviceCommandBinding.Hash(payload, record.HashScheme) is { } hash && record.PayloadHash == hash;

    // An earlier home hashed raw bytes, so a key-reordered retry of the same
    // command misses. Its original may already have run: never call it rejected.
    public bool RawBindingUnconfirmed(Guid id, string origin, string sessionId) =>
        Find(id) is { } record && record.Origin == origin && record.SessionID == sessionId
        && (record.HashScheme ?? DeviceCommandBinding.RawScheme) == DeviceCommandBinding.RawScheme;

    // Recovery-ledger receipts survive an application-data restore that lost
    // this store. Seed only missing IDs; an existing local record stays as-is.
    public void SeedIfMissing(IEnumerable<DeviceCommandRecord> receipts)
    {
        lock (_gate)
        {
            var changed = false;
            foreach (var receipt in receipts)
            {
                if (receipt.Id == Guid.Empty || _records.ContainsKey(receipt.Id)) continue;
                _records[receipt.Id] = new DeviceCommandRecord
                {
                    Id = receipt.Id,
                    Origin = receipt.Origin,
                    Outcome = receipt.Outcome is "accepted" or "running" ? "uncertain" : receipt.Outcome,
                    UpdatedAt = receipt.UpdatedAt == default ? DateTime.UtcNow : receipt.UpdatedAt,
                    SessionID = receipt.SessionID,
                    PayloadHash = receipt.PayloadHash,
                    HashScheme = receipt.HashScheme,
                };
                changed = true;
            }
            if (changed) Save();
        }
    }

    public void MarkRunning(Guid id) => Update(id, "running");
    public void MarkCompleted(Guid id) => Update(id, "completed");
    public void MarkFailed(Guid id) => Update(id, "failed");
    public string? Outcome(Guid id) => Find(id)?.Outcome;

    private void Update(Guid id, string outcome)
    {
        lock (_gate)
        {
            if (!_records.TryGetValue(id, out var record)) return;
            record.Outcome = outcome; record.UpdatedAt = DateTime.UtcNow; Save();
        }
    }
    private DeviceCommandRecord? Find(Guid id) { lock (_gate) return _records.GetValueOrDefault(id); }
    private void Save() { lock (_gate) AtomicJson.Write(_file, _records.Values.ToList()); }
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
    // Exact bytes first sent; every retry resends them. Absent on records
    // saved by earlier versions, which cannot be resent.
    public byte[]? PayloadBytes { get; set; }
    public const string LegacyDetail = "Saved by an earlier Converse version, so it cannot be resent exactly. Check home for its result.";
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
        // Re-encoding a legacy payload could differ from what home bound, and
        // a fresh command ID could apply it twice. Only Check home is safe.
        var legacy = Records.Where(r => r.PayloadBytes is null && r.Outcome == "pending").ToList();
        foreach (var record in legacy) { record.Outcome = "uncertain"; record.Detail = DeviceOutboxRecord.LegacyDetail; }
        // Never block sync start: memory keeps the migration and the next save writes it.
        if (legacy.Count > 0)
        {
            try { Save(); }
            catch (Exception e) { System.Diagnostics.Trace.WriteLine("Device outbox migration not saved yet: " + e.Message); }
        }
    }
    public void MarkLegacyUncertain(Guid commandId)
    {
        var record = Records.FirstOrDefault(r => r.CommandID == commandId);
        if (record is null) return;
        record.Outcome = "uncertain"; record.Detail = DeviceOutboxRecord.LegacyDetail; Save();
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
    // Resend under the original ID keeps the payload; only the lease epoch
    // and pending state move forward. Home dedups replays by ID.
    public void Requeue(Guid commandId, ulong epoch)
    {
        var record = Records.FirstOrDefault(r => r.CommandID == commandId);
        if (record is null) return;
        record.Epoch = epoch; record.Outcome = "pending"; record.Detail = null; Save();
    }
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

// A data folder override is a separate profile, so its saved keys live under
// their own vault resource: a test run can neither read nor replace real ones.
public static class CredentialScope
{
    public static string Resource(string resource, string? dataFolder) =>
        string.IsNullOrWhiteSpace(dataFolder) ? resource
        : resource + "." + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(Path.GetFullPath(dataFolder).ToUpperInvariant())));
}

internal static class AtomicJson
{
    // Concurrent saves of one store share a .tmp path; Windows rejects that as a sharing violation.
    static readonly object Gate = new();
    public static void Write<T>(string file, T value)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value);
        lock (Gate)
        {
            var temp = file + ".tmp";
            File.WriteAllBytes(temp, bytes);
            File.Move(temp, file, overwrite: true);
        }
    }
}
