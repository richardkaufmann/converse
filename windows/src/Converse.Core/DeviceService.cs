using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Converse.Core;

// Pairwise device sync mirroring DeviceTransport/DeviceIdentity/DeviceSync.
// Home-authoritative sessions, one fenced display lease per session,
// durable command dedup with honest uncertain recovery.
//
// Versioned membership records, same shape and rules as Swift: the JSON
// keys must match Mac TrustedDevice Codable exactly because both sides
// decode fabric.members (pairedAt is REQUIRED on the Mac side). The
// sender's authentication grants fabric-administration authority;
// records are never accepted pre-trust.
public sealed record TrustedDevice(
    [property: JsonPropertyName("deviceID")] string DeviceID,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("publicKey")] byte[] PublicKey,
    [property: JsonPropertyName("lastHost")] string? LastHost,
    [property: JsonPropertyName("lastPort")] int? LastPort,
    [property: JsonPropertyName("pairedAt")] double PairedAt = 0,
    [property: JsonPropertyName("generation")] ulong? Generation = null,
    [property: JsonPropertyName("changedBy")] string? ChangedBy = null,
    [property: JsonPropertyName("removed")] bool? Removed = null,
    [property: JsonPropertyName("metadataGeneration")] ulong? MetadataGeneration = null,
    [property: JsonPropertyName("metadataBy")] string? MetadataBy = null,
    [property: JsonPropertyName("groupID")] string? GroupID = null,
    [property: JsonPropertyName("displayName")] string? DisplayName = null,
    [property: JsonPropertyName("displayNameGeneration")] ulong? DisplayNameGeneration = null,
    [property: JsonPropertyName("displayNameBy")] string? DisplayNameBy = null);

public sealed class DeviceTrustStore
{
    private readonly string _file;
    private readonly object _gate = new();
    private List<TrustedDevice> _records = new();
    public List<TrustedDevice> Records { get { lock (_gate) return _records.ToList(); } }
    public List<TrustedDevice> Devices { get { lock (_gate) return _records.Where(d => d.Removed != true).ToList(); } }
    private static readonly JsonSerializerOptions ReadOptions = new() { PropertyNameCaseInsensitive = true };
    private readonly ulong _generationFloor;
    public DeviceTrustStore(string folder, ulong nextGenerationFloor = 0)
    {
        _generationFloor = nextGenerationFloor > 0 ? nextGenerationFloor - 1 : 0;
        Directory.CreateDirectory(folder);
        _file = Path.Combine(folder, "devices.json");
        if (File.Exists(_file))
            _records = (JsonSerializer.Deserialize<List<TrustedDevice>>(File.ReadAllBytes(_file), ReadOptions) ?? new())
                .Where(d => !string.IsNullOrEmpty(d.DeviceID) && d.PublicKey is { Length: 32 })
                .Select(d => d with { Name = BoundedName(string.IsNullOrEmpty(d.Name) ? d.DeviceID : d.Name) }).ToList();
    }
    public string Check(string deviceId, byte[] publicKey)
    {
        var device = Devices.FirstOrDefault(d => d.DeviceID == deviceId);
        if (device is null) return "unknown";
        return device.PublicKey.AsSpan().SequenceEqual(publicKey) ? "trusted" : "keyChanged";
    }
    // Membership generations advance by one per local mutation, so an honest
    // peer is never far ahead. Records beyond this allowance are ignored
    // rather than ranked: a compromised member cannot ratchet counters toward
    // exhaustion, and a tombstone cannot be outranked from afar (Mac parity).
    private static readonly ulong GenerationSkewAllowance = 1_000_000;
    private static bool WithinAllowance(ulong? remote, ulong? local)
    {
        var l = local ?? 0; var r = remote ?? 0;
        if (r <= l) return true;
        if (l >= ulong.MaxValue - GenerationSkewAllowance) return true;
        return r - l <= GenerationSkewAllowance;
    }
    private ulong NextGeneration()
    {
        var highest = Math.Max(_generationFloor,
            _records.Select(d => d.Generation ?? 0).DefaultIfEmpty().Max());
        if (highest < ulong.MaxValue - 2) return highest + 1;
        // Exhausted counters compact instead of bricking Forget, Pin and
        // admissions. Order is preserved, so every rank relationship holds.
        RenormalizeGenerations();
        var compacted = Math.Max(_generationFloor,
            _records.Select(d => d.Generation ?? 0).DefaultIfEmpty().Max());
        if (compacted >= ulong.MaxValue - 2) throw new InvalidDataException("Membership counter exhausted");
        return compacted + 1;
    }
    private void RenormalizeGenerations()
    {
        var order = _records.Select((d, i) => i)
            .OrderBy(i => _records[i].Generation ?? 0).ThenBy(i => _records[i].DeviceID, StringComparer.Ordinal).ToList();
        var next = _records.ToList();
        for (var rank = 0; rank < order.Count; rank++)
            next[order[rank]] = next[order[rank]] with { Generation = (ulong)(rank + 1) };
        Save(next);
        _records = next;
    }

    public ulong NextGenerationFloor =>
        Math.Max(_generationFloor,
            Records.Select(d => d.Generation ?? 0).DefaultIfEmpty().Max()) + 1;
    public static double AppleNow() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 - 978307200;
    public static string BoundedName(string name)
    {
        var result = new System.Text.StringBuilder();
        var bytes = 0;
        foreach (var rune in name.EnumerateRunes())
        {
            if (bytes + rune.Utf8SequenceLength > 200) break;
            result.Append(rune.ToString());
            bytes += rune.Utf8SequenceLength;
        }
        return result.ToString();
    }
    // Pin scopes to a group: same device/key in another group is a fresh
    // admission, never an update. Only fresh human admission (reviewed
    // join) may supersede a tombstone.
    public void Pin(TrustedDevice device, string? issuer = null, bool allowAdmission = true, string? groupID = null)
    {
        lock (_gate)
        {
            device = device with { Name = BoundedName(device.Name) };
            var old = _records.FirstOrDefault(d => d.DeviceID == device.DeviceID);
            var active = old is not null && old.Removed != true
                && old.PublicKey.AsSpan().SequenceEqual(device.PublicKey) && old.GroupID == groupID;
            if (!active && !allowAdmission) throw new InvalidDataException("Fresh human admission required");
            if (active && old!.Name == device.Name && (device.LastHost is null || old.LastHost == device.LastHost)
                && (device.LastPort is null || old.LastPort == device.LastPort)) return;
            if ((old?.MetadataGeneration ?? 0) >= ulong.MaxValue - 2) throw new InvalidDataException("Metadata counter exhausted");
            var member = device with
            {
                Generation = active ? old!.Generation : NextGeneration(),
                ChangedBy = active ? old!.ChangedBy : issuer ?? device.DeviceID,
                Removed = false,
                PairedAt = active && old!.PairedAt > 0 ? old.PairedAt : AppleNow(),
                LastHost = device.LastHost ?? old?.LastHost,
                LastPort = device.LastPort ?? old?.LastPort,
                MetadataGeneration = checked((old?.MetadataGeneration ?? 0) + 1),
                MetadataBy = issuer ?? device.DeviceID,
                GroupID = groupID,
                DisplayName = active ? old?.DisplayName : null,
                DisplayNameGeneration = active ? old?.DisplayNameGeneration : null,
                DisplayNameBy = active ? old?.DisplayNameBy : null,
            };
            var next = _records.Where(d => d.DeviceID != device.DeviceID).Append(member).ToList();
            if (next.Count > 512) throw new InvalidDataException("Fabric roster limit");
            Save(next);
            _records = next;
        }
    }
    // Forget writes a versioned removal tombstone (Mac parity) so the
    // removal propagates; it never just deletes the row.
    public void Forget(string deviceId, string? issuer = null)
    {
        lock (_gate)
        {
            var old = _records.FirstOrDefault(d => d.DeviceID == deviceId);
            if (old is null) return;
            var next = _records.Where(d => d.DeviceID != deviceId)
                .Append(old with { Generation = NextGeneration(), ChangedBy = issuer ?? deviceId, Removed = true }).ToList();
            Save(next);
            _records = next;
        }
    }
    public void MigrateLegacyGroup(string id)
    {
        lock (_gate)
        {
            var next = _records.Select(d => d.GroupID is null ? d with { GroupID = id } : d).ToList();
            Save(next);
            _records = next;
        }
    }
    public static bool ValidDisplayName(string name) => name.Length > 0 && name == name.Trim()
        && System.Text.Encoding.UTF8.GetByteCount(name) <= 200 && !name.Any(char.IsControl);

    public void RenameDisplay(string deviceId, string groupId, string name, string issuer)
    {
        lock (_gate)
        {
            name = name.Trim();
            var old = _records.FirstOrDefault(d => d.DeviceID == deviceId && d.GroupID == groupId && d.Removed != true);
            if (!ValidDisplayName(name) || old is null || (old.DisplayNameGeneration ?? 0) >= ulong.MaxValue - 2)
                throw new InvalidDataException("Use a nonempty device name up to 200 UTF-8 bytes for a current group member.");
            if (old.DisplayName == name) return;
            var next = _records.Select(d => d.DeviceID == deviceId ? old with {
                DisplayName = name, DisplayNameGeneration = (old.DisplayNameGeneration ?? 0) + 1, DisplayNameBy = issuer
            } : d).ToList();
            Save(next); _records = next;
        }
    }

    public bool Merge(IReadOnlyList<TrustedDevice> incoming)
    {
        lock (_gate)
        {
            if (incoming.Count > 512 || incoming.Any(d => d.PublicKey.Length != 32
                || DeviceBlob.DeviceIdForPublicKey(d.PublicKey) != d.DeviceID
                || (d.GroupID is not null && !Guid.TryParse(d.GroupID, out _))
                || System.Text.Encoding.UTF8.GetByteCount(d.Name) > 200
                || (d.DisplayName is not null && !ValidDisplayName(d.DisplayName))
                || (d.DisplayNameGeneration ?? 0) >= ulong.MaxValue - 1 || (d.DisplayNameBy?.Length ?? 0) > 64
                || (d.MetadataBy?.Length ?? 0) > 64 || (d.MetadataGeneration ?? 0) >= ulong.MaxValue - 1
                || (d.ChangedBy?.Length ?? 0) > 64 || (d.LastHost?.Length ?? 0) > 253 || d.LastPort is < 1 or > 65535
                || (d.Generation ?? 0) >= ulong.MaxValue - 1)) throw new InvalidDataException("Invalid membership");
            var next = _records.ToList();
            var preMergeMax = next.Select(d => d.Generation ?? 0).DefaultIfEmpty().Max();
            var changed = false;
            foreach (var member in incoming)
            {
                var index = next.FindIndex(d => d.DeviceID == member.DeviceID);
                if (index < 0)
                {
                    // A far-future introduction is ignored, never appended.
                    if (!WithinAllowance(member.Generation, preMergeMax)) continue;
                    next.Add(member); changed = true; continue;
                }
                var old = next[index];
                // A record far past local state is ignored, never ranked: a
                // tombstone keeps authority over any non-removal far past it.
                if (!WithinAllowance(member.Generation, old.Generation)) continue;
                var newer = (member.Generation ?? 0) > (old.Generation ?? 0)
                    || ((member.Generation ?? 0) == (old.Generation ?? 0) && ((member.Removed == true && old.Removed != true)
                    || ((member.Removed == true) == (old.Removed == true) && string.CompareOrdinal(member.ChangedBy ?? "", old.ChangedBy ?? "") > 0)));
                if (newer) { next[index] = member; changed = true; }
                else if ((member.Generation ?? 0) == (old.Generation ?? 0) && (member.Removed == true) == (old.Removed == true)
                    && (member.ChangedBy ?? "") == (old.ChangedBy ?? "") && old.GroupID == member.GroupID && old.PublicKey.AsSpan().SequenceEqual(member.PublicKey))
                {
                    if (WithinAllowance(member.MetadataGeneration, old.MetadataGeneration)
                        && ((member.MetadataGeneration ?? 0) > (old.MetadataGeneration ?? 0)
                    || ((member.MetadataGeneration ?? 0) == (old.MetadataGeneration ?? 0)
                    && string.CompareOrdinal(member.MetadataBy ?? "", old.MetadataBy ?? "") > 0))) {
                    next[index] = old with
                    {
                        Name = member.Name, LastHost = member.LastHost, LastPort = member.LastPort,
                        MetadataGeneration = member.MetadataGeneration, MetadataBy = member.MetadataBy,
                    };
                    changed = true;
                    }
                    if (WithinAllowance(member.DisplayNameGeneration, old.DisplayNameGeneration)
                        && ((member.DisplayNameGeneration ?? 0) > (old.DisplayNameGeneration ?? 0)
                        || ((member.DisplayNameGeneration ?? 0) == (old.DisplayNameGeneration ?? 0)
                        && string.CompareOrdinal(member.DisplayNameBy ?? "", old.DisplayNameBy ?? "") > 0)))
                    {
                        next[index] = next[index] with { DisplayName = member.DisplayName,
                            DisplayNameGeneration = member.DisplayNameGeneration, DisplayNameBy = member.DisplayNameBy };
                        changed = true;
                    }
                }
            }
            if (next.Count > 512) throw new InvalidDataException("Fabric roster limit");
            if (!changed) return false;
            Save(next);
            _records = next;
            return true;
        }
    }
    // Merge-preserve write: unknown future keys ride along untouched while
    // every known membership key is stored canonically. Tombstones are
    // ordinary records here (Forget tombstones, never deletes), so no
    // separate removed set is needed.
    private static readonly string[] KnownKeys =
        { "deviceID", "DeviceID", "name", "Name", "publicKey", "PublicKey", "pairedAt", "PairedAt",
          "lastHost", "LastHost", "lastPort", "LastPort", "generation", "Generation", "changedBy", "ChangedBy",
          "removed", "Removed", "metadataGeneration", "MetadataGeneration", "metadataBy", "MetadataBy",
          "groupID", "GroupID", "displayName", "DisplayName", "displayNameGeneration", "DisplayNameGeneration", "displayNameBy", "DisplayNameBy" };
    private void Save(List<TrustedDevice> devices)
    {
        System.Text.Json.Nodes.JsonArray existing = new();
        try
        {
            if (File.Exists(_file))
                existing = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllBytes(_file))
                    as System.Text.Json.Nodes.JsonArray ?? new();
        }
        catch { /* corrupted file: rebuild from memory */ }
        var byId = new Dictionary<string, System.Text.Json.Nodes.JsonObject>();
        foreach (var node in existing.OfType<System.Text.Json.Nodes.JsonObject>())
        {
            var id = node["deviceID"]?.GetValue<string>() ?? node["DeviceID"]?.GetValue<string>();
            if (!string.IsNullOrEmpty(id)) byId[id!] = node;
        }
        var next = new System.Text.Json.Nodes.JsonArray();
        var seen = new HashSet<string>();
        foreach (var device in devices)
        {
            seen.Add(device.DeviceID);
            var entry = byId.TryGetValue(device.DeviceID, out var prior)
                ? (System.Text.Json.Nodes.JsonObject)prior.DeepClone()
                : new System.Text.Json.Nodes.JsonObject();
            foreach (var key in KnownKeys) entry.Remove(key);
            entry["deviceID"] = device.DeviceID;
            entry["name"] = device.Name;
            entry["publicKey"] = Convert.ToBase64String(device.PublicKey);
            entry["pairedAt"] = device.PairedAt;
            if (device.LastHost is not null) entry["lastHost"] = device.LastHost;
            if (device.LastPort is not null) entry["lastPort"] = device.LastPort;
            if (device.Generation is not null) entry["generation"] = device.Generation.Value;
            if (device.ChangedBy is not null) entry["changedBy"] = device.ChangedBy;
            if (device.Removed is not null) entry["removed"] = device.Removed.Value;
            if (device.MetadataGeneration is not null) entry["metadataGeneration"] = device.MetadataGeneration.Value;
            if (device.MetadataBy is not null) entry["metadataBy"] = device.MetadataBy;
            if (device.GroupID is not null) entry["groupID"] = device.GroupID;
            if (device.DisplayName is not null) entry["displayName"] = device.DisplayName;
            if (device.DisplayNameGeneration is not null) entry["displayNameGeneration"] = device.DisplayNameGeneration.Value;
            if (device.DisplayNameBy is not null) entry["displayNameBy"] = device.DisplayNameBy;
            next.Add(entry);
        }
        foreach (var (id, entry) in byId)
            if (!seen.Contains(id)) next.Add((System.Text.Json.Nodes.JsonNode)entry.DeepClone());
        AtomicJson.Write(_file, next);
    }
}

public sealed record PairingPrompt(string PeerName, string Fingerprint, string Code, bool KeyChanged, bool IsInitiator = false, Guid PeerId = default);

public sealed class RemoteHomeState
{
    public string DeviceID { get; set; } = "";
    public string DeviceName { get; set; } = "";
    public bool Online { get; set; }
    public List<DeviceSidebarRow> Rows { get; set; } = new();
}

internal sealed class Peer
{
    public required Guid Id { get; init; }
    public required TcpClient Client { get; init; }
    public required bool IsInitiator { get; init; }
    public DeviceHandshake? Handshake { get; set; }
    public DeviceTransportKeys? Keys { get; set; }
    public DeviceHello? Hello { get; set; }
    public DeviceFrameDecoder Decoder { get; } = new();
    public List<byte> Buffer { get; } = new();
    public bool TrustedReady { get; set; }
    public bool HumanConfirmed { get; set; }
    public bool LocalConfirmed { get; set; }
    public bool RemoteConfirmed { get; set; }
    public string? JoiningGroupID { get; set; }
    public bool WantsJoin { get; set; }
    public ConverseGroup? AdmissionGroup { get; set; }
    public bool ControlOnly { get; set; }
    public HashSet<Guid> LeasedSessions { get; } = new();
    public string? ManualHost { get; init; }
    public int? ManualPort { get; init; }
    public readonly SemaphoreSlim SendLock = new(1, 1);
}

public sealed partial class DeviceSyncService : IDisposable
{
    public const int DefaultPort = 48721;
    public string DeviceId { get; }
    public string DeviceName { get; }
    public DeviceTrustStore Trust { get; }
    public Dictionary<string, RemoteHomeState> Homes { get; } = new();
    public Dictionary<string, ulong> RemoteLeases { get; } = new();
    public Dictionary<string, DeviceTranscriptPayload> RemoteTranscripts { get; } = new();
    public HashSet<string> RemoteOffline { get; } = new();
    public string LastOutcome { get; private set; } = "";
    public string ConnectionNotice { get; private set; } = "";
    private string? _failedConnectionEndpoint;
    public int ListeningPort { get; private set; }
    public event Action? Changed;
    public event Action<string>? RemoteViewDisplaced;
    public event Action<Guid, string, ulong>? DisplayLeaseGranted;
    public event Action<Guid, string, ulong>? DisplayLeaseReleased;
    public bool AcceptingWork { get; private set; } = true;
    public Func<string, bool>? IsViewerPlaced { get; set; }
    public Func<PairingPrompt, Task<bool>>? PairingConfirmation { get; set; }

    // Shared admission boundary. Every producer of NEW external work takes
    // TryBeginExternalWork under the same lock that flips AcceptingWork, so
    // once admission closes no new work can start and the in-flight count
    // can only shrink. The final idle-to-activation decision observes
    // IsWorkQuiescent, which reads that same count plus the work snapshot.
    // Already-accepted work (queued prompts, running turns, acknowledgments,
    // stop/answers/queue management) never takes this guard.
    private readonly object _admissionLock = new();
    private int _admissionInflight;
    private readonly HashSet<string> _guardedBlobs = new();

    public void SetAcceptingWork(bool accepting)
    {
        lock (_admissionLock)
        {
            if (AcceptingWork == accepting) return;
            AcceptingWork = accepting;
        }
        Changed?.Invoke();
    }

    public bool TryBeginExternalWork()
    {
        lock (_admissionLock)
        {
            if (!AcceptingWork) return false;
            _admissionInflight++;
            return true;
        }
    }

    public void EndExternalWork()
    {
        lock (_admissionLock) { _admissionInflight--; }
    }

    public bool IsWorkQuiescent()
    {
        lock (_admissionLock) { if (_admissionInflight != 0) return false; }
        return WorkSnapshot().Idle;
    }

    private void ReleaseBlobGuard(string hash)
    {
        lock (_admissionLock) { if (_guardedBlobs.Remove(hash)) _admissionInflight--; }
    }

    public DeviceSyncCounterSnapshot SyncCounterSnapshot()
    {
        var snapshot = _syncCounters.Snapshot();
        return snapshot with
        {
            NextLeaseEpoch = Math.Max(snapshot.NextLeaseEpoch, (1UL << 48) + 1),
        };
    }

    public IReadOnlyList<DeviceCommandRecord> CommandReceipts =>
        _commands.Records.Values.OrderBy(record => record.UpdatedAt).ToList();

    // Converse Groups state, mirroring Swift DeviceTransport.
    public ConverseGroupStore GroupStore { get; }
    public ConverseGroup? CurrentGroup => GroupStore.Current;
    public List<ConverseGroup> KnownGroups { get; private set; } = new();
    public List<GroupJoinRequest> GroupRequests { get; } = new();
    public GroupJoinReview? GroupReview { get; set; }
    public List<PairingPrompt> GroupPairingPrompts { get; } = new();
    public string ServiceStatus { get; private set; } = "";
    private readonly Dictionary<Guid, GroupJoinRequest> _sponsoredRequests = new();

    private readonly byte[] _staticPrivate;
    private readonly SessionStore _store;
    public AgentRuntime Agents { get; private set; } = null!;
    private readonly string _folder;
    private readonly DeviceCommandStore _commands;
    private readonly DeviceOutboxStore _outbox;
    private readonly DeviceLeaseManager _leases;
    private readonly DeviceDraftTracker _drafts = new();
    private readonly Dictionary<Guid, Peer> _peers = new();
    private readonly Dictionary<string, string> _blobPaths = new();
    private readonly Dictionary<string, List<byte>> _staged = new();
    private readonly Dictionary<string, TaskCompletionSource<bool>> _blobAcks = new();
    private readonly Dictionary<string, TaskCompletionSource<string?>> _blobDownloads = new();
    private readonly Dictionary<string, DateTime> _pendingTakes = new();
    private Dictionary<string, ulong> _resumeEpochs = new();
    private readonly SemaphoreSlim _pairingQueue = new(1, 1);
    private readonly ConcurrentDictionary<string, byte> _connecting = new();
    private readonly DeviceSyncCounters _syncCounters;
    private ulong _boot => _syncCounters.Boot;
    public List<MdnsService> DiscoveredDevices { get; } = new();
    private MdnsDiscovery? _mdns;
    private TcpListener? _listener;
    private CancellationTokenSource? _shutdown;

    public DeviceSyncService(string folder, SessionStore store, string? deviceName = null,
        DeviceRecoveryFloors? recoveryFloors = null)
    {
        _folder = folder;
        _store = store;
        Directory.CreateDirectory(folder);
        try { _resumeEpochs = JsonSerializer.Deserialize<Dictionary<string, ulong>>(File.ReadAllText(Path.Combine(folder, "display-resume.json"))) ?? new(); }
        catch { _resumeEpochs = new(); }
        var keyFile = Path.Combine(folder, "device-key.bin");
        // Core keeps plain test storage; the app must DPAPI-protect this file.
        _staticPrivate = File.Exists(keyFile) ? File.ReadAllBytes(keyFile) : CreateKeyFile(keyFile);
        DeviceId = DeviceBlob.DeviceIdForPublicKey(X25519.PublicKeyFromPrivate(_staticPrivate));
        DeviceName = deviceName ?? Environment.MachineName;
        Trust = new DeviceTrustStore(folder, recoveryFloors?.NextMembershipGeneration ?? 0);
        _commands = new DeviceCommandStore(folder);
        if (recoveryFloors is not null) _commands.SeedIfMissing(recoveryFloors.CommandReceipts);
        _outbox = new DeviceOutboxStore(folder);
        _syncCounters = new DeviceSyncCounters(folder, recoveryFloors);
        _leases = new DeviceLeaseManager(initialEpochs: _syncCounters.Epochs,
            persistEpochs: _syncCounters.SaveEpochs,
            initialEpoch: Math.Max(1UL << 48, _syncCounters.LeaseEpochFloor));
        GroupStore = new ConverseGroupStore(folder);
        KnownGroups = GroupStore.Groups.ToList();
        InitializeGroups();
        RefreshGroupMembers();
        _store.Changed += PublishSidebars;
        _store.TranscriptAdvanced += PushTranscriptToHolder;
        _store.SessionClosed += HomeSessionClosed;
        LoadParticipants();
        _store.FinalParticipantReply = (session, reply, authority) => { _ = ProcessParticipantReplyAsync(session, reply, authority); };
        _store.AcceptGroupPrompt = p => IsParticipantAllowed(p.OriginHomeID ?? "", p.OriginGroupID);
        Agents = new AgentRuntime(_store, this);
    }

    // Turn progress/completion fan-out: the holder's viewer gets a fresh
    // snapshot with a higher HomeSeq, which its sequence gate accepts.
    // Non-holders and lapsed leases drop inside SendTranscriptAsync.
    private readonly ConcurrentDictionary<Guid, byte> _transcriptPushPending = new();
    private void PushTranscriptToHolder(ChatSession session)
    {
        // Coalesce token bursts into a latest snapshot, independently of the
        // two-second archive checkpoint. A trailing flush also delivers the
        // last fragment when a provider pauses without completing its turn.
        if (_leases.Holder(session.Id) is null || !_transcriptPushPending.TryAdd(session.Id, 0)) return;
        _ = FlushTranscriptAsync(session);
    }
    private async Task FlushTranscriptAsync(ChatSession session)
    {
        await Task.Delay(75);
        _transcriptPushPending.TryRemove(session.Id, out _);
        if (_shutdown?.IsCancellationRequested != false || !_store.Sessions.Contains(session)) return;
        var holder = _leases.Holder(session.Id);
        if (holder is null) return;
        var peer = _peers.Values.FirstOrDefault(p => p.Hello?.DeviceID == holder.Value.Device);
        if (peer is not null) await SendTranscriptAsync(peer, session);
    }

    // First launch with pre-group trust: deterministic legacy migration
    // adopts the shared default group and stamps every unstamped record.
    private void InitializeGroups()
    {
        if (GroupStore.Existed || LocallyRemoved) return;
        var legacy = ConverseGroupStore.Migrate(Trust.Records, DeviceId);
        if (legacy is null || CurrentGroup is not null) return;
        Trust.MigrateLegacyGroup(legacy.Id);
        Trust.Pin(new TrustedDevice(DeviceId, DeviceName, X25519.PublicKeyFromPrivate(_staticPrivate),
            null, ListeningPort > 0 ? ListeningPort : null), DeviceId, true, legacy.Id);
        GroupStore.Adopt(legacy);
        KnownGroups = GroupStore.Groups.ToList();
    }

    public bool LocallyRemoved =>
        Trust.Records.FirstOrDefault(d => d.DeviceID == DeviceId)?.Removed == true;

    public string DisplayName(string id, string? fallback = null)
    {
        var record = Trust.Devices.FirstOrDefault(d => d.DeviceID == id && d.GroupID == CurrentGroup?.Id);
        return record?.DisplayName ?? fallback ?? (id == DeviceId ? DeviceName : Homes.GetValueOrDefault(id)?.DeviceName ?? record?.Name ?? id[..Math.Min(id.Length, 8)]);
    }
    public bool CanRenameDevice(string id) => CurrentGroup is not null && !LocallyRemoved
        && Trust.Devices.Any(d => d.DeviceID == id && d.GroupID == CurrentGroup.Id);
    public async Task RenameDeviceDisplayNameAsync(string id, string name)
    {
        if (!CanRenameDevice(id)) throw new InvalidOperationException("Device is not a current group member.");
        Trust.RenameDisplay(id, CurrentGroup!.Id, name, DeviceId);
        RefreshGroupMembers(); await BroadcastFabricAsync();
    }
    public string DeviceDetails(string id)
    {
        var record = Trust.Devices.FirstOrDefault(d => d.DeviceID == id && d.GroupID == CurrentGroup?.Id);
        var local = id == DeviceId;
        var reported = local ? DeviceName : Homes.GetValueOrDefault(id)?.DeviceName ?? record?.Name ?? "Unknown";
        var status = local ? "This device" : Homes.GetValueOrDefault(id)?.Online == true ? "Online" : "Offline";
        var endpoint = record?.LastHost is { } host ? "\nLast address: " + host + (record.LastPort is { } port ? ":" + port : "") : "";
        return DisplayName(id, reported) + "\nReported name: " + reported + "\n" + status + "\nGroup: " + (CurrentGroup?.Name ?? "None") + "\nDevice ID: " + id + endpoint;
    }

    // Remote homes exist only for current-group members; leaving all
    // groups hides every remote session without touching local work.
    public void RefreshGroupMembers()
    {
        KnownGroups = GroupStore.Groups.ToList();
        var trusted = CurrentGroup is null
            ? new List<TrustedDevice>()
            : Trust.Devices.Where(d => d.DeviceID != DeviceId && d.GroupID == CurrentGroup.Id).ToList();
        foreach (var device in trusted)
            if (!Homes.TryGetValue(device.DeviceID, out var home))
                Homes[device.DeviceID] = new RemoteHomeState { DeviceID = device.DeviceID, DeviceName = device.Name };
            else home.DeviceName = device.Name;
        foreach (var stale in Homes.Keys.Where(id => trusted.All(d => d.DeviceID != id)).ToList())
            DropHome(stale);
        Changed?.Invoke();
    }

    private void DropHome(string deviceId)
    {
        if (!Homes.Remove(deviceId, out var home)) return;
        foreach (var row in home.Rows)
        {
            RemoteLeases.Remove(row.GlobalID);
            RemoteTranscripts.Remove(row.GlobalID);
            RemoteOffline.Remove(row.GlobalID);
        }
    }

    // Current-group membership by live roster, like Swift.
    private bool IsGroupMember(string deviceID) =>
        CurrentGroup is not null
        && Trust.Devices.Any(d => d.DeviceID == deviceID && d.GroupID == CurrentGroup.Id);

    // Home-state envelopes must never cross a group boundary, in either
    // direction: dispatch and every publisher check membership first.
    private static readonly HashSet<string> SessionKinds = new(StringComparer.Ordinal)
    {
        DeviceKind.SidebarSnapshot, DeviceKind.LeaseAcquire, DeviceKind.LeaseResume, DeviceKind.LeaseExpired, DeviceKind.LeaseGranted,
        DeviceKind.LeaseDenied, DeviceKind.LeaseStolen, DeviceKind.LeaseHeartbeat,
        DeviceKind.LeaseRelease, DeviceKind.TranscriptSnapshot, DeviceKind.TranscriptRequest,
        DeviceKind.DraftPatch, DeviceKind.Command, DeviceKind.CommandQuery, DeviceKind.CommandAck,
        DeviceKind.BlobOffer, DeviceKind.BlobChunk, DeviceKind.BlobAck,
        DeviceKind.BlobRequest, DeviceKind.BlobData,
    };

    // Creating a new group fences home leases held by the old group: only
    // members of the new group keep their holds, everyone else loses them
    // immediately so a fresh member can take the session.
    private void FenceHomeLeases()
    {
        foreach (var session in _store.Sessions)
            if (_leases.Holder(session.Id) is { } holder && !IsGroupMember(holder.Device))
                _leases.ForceRelease(session.Id, holder.Device);
    }

    private static byte[] CreateKeyFile(string keyFile)
    {
        var (priv, _) = X25519.GenerateKeyPair();
        File.WriteAllBytes(keyFile, priv);
        return priv;
    }

    public IReadOnlyList<DeviceOutboxRecord> Outbox => _outbox.Records;

    public sealed record DeviceWorkSnapshot(
        int ActiveTurns, int QueuedPrompts, int PendingOutbox, int BlobTransfers)
    {
        public int Total => ActiveTurns + QueuedPrompts + PendingOutbox + BlobTransfers;
        public bool Idle => Total == 0;
    }

    public DeviceWorkSnapshot WorkSnapshot()
    {
        int blobTransfers;
        lock (_blobAcks) { blobTransfers = _blobAcks.Count; }
        lock (_blobDownloads) { blobTransfers += _blobDownloads.Count; }
        return new DeviceWorkSnapshot(
            _store.Sessions.Count(session => session.Busy),
            _store.Sessions.Sum(session => session.Pending.Count),
            _outbox.Records.Count(record => record.Outcome == "pending"),
            blobTransfers + _staged.Count);
    }

    // Tests disable discovery AND bind loopback so they neither advertise
    // phantom groups nor open a LAN listener that asks for firewall access.
    public async Task StartAsync(int port = DefaultPort, bool enableDiscovery = false, bool loopbackOnly = true)
    {
        if (loopbackOnly && enableDiscovery) throw new ArgumentException("Loopback listeners cannot advertise on the LAN.");
        _shutdown = new CancellationTokenSource();
        _listener = new TcpListener(loopbackOnly ? IPAddress.Loopback : IPAddress.Any, port);
        _listener.Start();
        ListeningPort = ((IPEndPoint)_listener.LocalEndpoint).Port;
        if (!enableDiscovery) { _ = AcceptLoopAsync(_shutdown.Token); _ = HeartbeatLoopAsync(_shutdown.Token); await Task.CompletedTask; return; }
        try
        {
            _mdns = new MdnsDiscovery(DeviceName + " [" + DeviceId[..8] + "]", ListeningPort, CurrentGroup, DeviceId);
            _mdns.Found += found =>
            {
                lock (DiscoveredDevices)
                {
                    DiscoveredDevices.RemoveAll(d => d.Name == found.Name);
                    DiscoveredDevices.Add(found);
                }
                Changed?.Invoke();
                _ = ReconnectFabricAsync();
            };
            _mdns.Start();
        }
        catch { /* discovery is best-effort; manual connect remains */ }
        _ = AcceptLoopAsync(_shutdown.Token);
        _ = HeartbeatLoopAsync(_shutdown.Token);
        await Task.CompletedTask;
    }

    public void Dispose()
    {
        Agents.Shutdown();
        _shutdown?.Cancel();
        try { _store.TranscriptAdvanced -= PushTranscriptToHolder; _store.SessionClosed -= HomeSessionClosed; } catch { /* store outlives us */ }
        _mdns?.Dispose();
        _listener?.Stop();
        // Best-effort shutdown: connect/accept threads can mutate _peers
        // (a plain Dictionary) mid-snapshot, surfacing torn nulls — the
        // RESULTS30 test-process crash. One bad peer never stops the rest.
        List<Peer> peers;
        try { peers = _peers.Values.ToList(); }
        catch { peers = new List<Peer>(); }
        foreach (var peer in peers)
        {
            try { peer.Client?.Dispose(); }
            catch { /* already gone */ }
        }
    }

    public async Task ConnectManualAsync(string host, int port, string? joiningGroupID = null)
    {
        var id = Guid.NewGuid();
        await ConnectAsync(id, host, port, joiningGroupID, joiningGroupID is not null);
    }

    // Headless setup needs the connection's peer ID so an admin client can
    // track the exact pairing prompt it displays and confirms.
    public async Task<Guid> BeginGroupJoinAsync(string host, int port, string groupID)
    {
        var id = Guid.NewGuid();
        await ConnectAsync(id, host, port, groupID, wantsJoin: true);
        return id;
    }

    internal async Task ConnectAsync(Guid id, string host, int port, string? joiningGroupID, bool wantsJoin, bool userInitiated = true)
    {
        if (userInitiated) { ConnectionNotice = ""; _failedConnectionEndpoint = null; }
        if (port is < 1 or > 65535) { if (userInitiated) ConnectionNotice = "Port must be between 1 and 65535."; return; }
        if (!_connecting.TryAdd(host + ":" + port, 0)) return;
        try
        {
            var client = new TcpClient();
            // A refused or unreachable host must not escape to the async void UI handlers.
            try { await client.ConnectAsync(host, port); }
            catch (SocketException ex)
            {
                client.Dispose();
                // Offline group members are routine background work, not
                // errors in whichever conversation happens to be displayed.
                if (userInitiated)
                {
                    ConnectionNotice = $"Could not reach {host}:{port} ({ex.SocketErrorCode}).";
                    _failedConnectionEndpoint = host + ":" + port;
                    Changed?.Invoke();
                }
                return;
            }
            var peer = new Peer
            {
                Id = id, Client = client, IsInitiator = true, ManualHost = host, ManualPort = port,
                JoiningGroupID = joiningGroupID, WantsJoin = wantsJoin,
            };
            peer.Handshake = new DeviceHandshake(true, _staticPrivate);
            _peers[id] = peer;
            await SendRawAsync(peer, peer.Handshake.WriteMessage(DeviceJson.Encode(Hello(wantsJoin ? joiningGroupID : null))));
            _ = ReceiveLoopAsync(peer);
        }
        finally { _connecting.TryRemove(host + ":" + port, out _); }
    }

    public void ForgetDevice(TrustedDevice device)
    {
        // Forget is a versioned removal: tombstone, broadcast, disconnect,
        // and drop the home. Tombstones converge to every member.
        Trust.Forget(device.DeviceID, DeviceId);
        foreach (var peer in _peers.Values.Where(p => p.Hello?.DeviceID == device.DeviceID).ToList())
            Disconnect(peer);
        DropHome(device.DeviceID);
        RefreshGroupMembers();
        _ = BroadcastFabricAsync();
    }

    // The bundled VERSION.json is the release identity shown in the title bar.
    private static readonly (string Version, string? Build) InstalledVersion = ReadInstalledVersion();
    private static (string, string?) ReadInstalledVersion()
    {
        foreach (var path in new[] { Path.Combine(AppContext.BaseDirectory, "Assets", "VERSION.json"), Path.Combine(AppContext.BaseDirectory, "VERSION.json") })
        {
            try
            {
                using var version = JsonDocument.Parse(File.ReadAllText(path));
                return (version.RootElement.GetProperty("version").GetString() ?? "development", version.RootElement.GetProperty("build").ToString());
            }
            catch { }
        }
        return ("development", null);
    }

    private DeviceHello Hello(string? joinGroupID = null) => new()
    {
        DeviceID = DeviceId, DeviceName = DeviceName, ConverseVersion = InstalledVersion.Version, ConverseBuild = InstalledVersion.Build,
        Capabilities = new[] { "lot-read-v1", "sidebar", "lease", "lease-resume-v1", "transcript", "commands", "blobs", "fabric-membership-v1", "converse-groups-v1", "participant-control-v1", "session-close-v1", "session-rename-v1", "session-create-v1", "agent-host-v1", "transcript-export-v1", "agent-art-direction-v1", "agent-schedule-v1", "switchboard-teach-v1", "switchboard-supervision-v1", QueueRemoveCapability },
        ListenPort = ListeningPort > 0 ? ListeningPort : null,
        Group = CurrentGroup, JoinGroupID = joinGroupID,
    };

    private async Task AcceptLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested && _listener is not null)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(token); }
            catch { break; }
            var id = Guid.NewGuid();
            var peer = new Peer { Id = id, Client = client, IsInitiator = false };
            peer.Handshake = new DeviceHandshake(false, _staticPrivate);
            _peers[id] = peer;
            _ = ReceiveLoopAsync(peer);
        }
    }

    private async Task HeartbeatLoopAsync(CancellationToken token)
    {
        var ticks = 0;
        while (!token.IsCancellationRequested)
        {
            await Task.Delay(TimeSpan.FromSeconds(5), token).ContinueWith(_ => { });
            if (token.IsCancellationRequested) break;
            ticks++;
            if (SweepExpiredSponsors()) await PublishGroupRequestsAsync();
            if (ticks % 6 == 0) await ReconnectFabricAsync();
            foreach (var expired in _leases.SweepExpired())
            {
                foreach (var peer in _peers.Values.Where(p => p.Hello?.DeviceID == expired.Device))
                {
                    peer.LeasedSessions.Remove(expired.Session);
                    await SendEnvelopeAsync(peer, new DeviceEnvelope
                    {
                        Kind = peer.Hello?.Capabilities.Contains("lease-resume-v1") == true ? DeviceKind.LeaseExpired : DeviceKind.LeaseStolen, Boot = _boot,
                        SessionID = new DeviceGlobalID(DeviceId, expired.Session).ToString(), Epoch = expired.Epoch,
                    });
                }
            }
            await RestoreAvailableDisplaysAsync();
            foreach (var (globalId, epoch) in RemoteLeases.ToList())
            {
                var parsed = DeviceGlobalID.Parse(globalId);
                var peer = parsed is null ? null : PeerForHome(parsed.Value.Home);
                if (peer is not null)
                    await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.LeaseHeartbeat, SessionID = globalId, Epoch = epoch });
            }
        }
    }

    private async Task ReceiveLoopAsync(Peer peer)
    {
        var stream = peer.Client.GetStream();
        var buffer = new byte[65_536];
        try
        {
            while (true)
            {
                var read = await stream.ReadAsync(buffer);
                if (read == 0) break;
                peer.Buffer.AddRange(buffer.Take(read));
                if (peer.Buffer.Count > 1_048_576) break;
                while (peer.Buffer.Count >= 2)
                {
                    var length = (peer.Buffer[0] << 8) | peer.Buffer[1];
                    if (peer.Buffer.Count < 2 + length) break;
                    var message = peer.Buffer.GetRange(2, length).ToArray();
                    peer.Buffer.RemoveRange(0, 2 + length);
                    await HandleRawAsync(peer, message);
                }
            }
        }
        catch { /* disconnect below */ }
        Disconnect(peer);
    }

    private async Task SendRawAsync(Peer peer, byte[] message)
    {
        await peer.SendLock.WaitAsync();
        try { await WriteFrameAsync(peer, message); }
        finally { peer.SendLock.Release(); }
    }

    // Callers hold peer.SendLock.
    private static async Task WriteFrameAsync(Peer peer, byte[] message)
    {
        if (message.Length > 65535) { peer.Client.Dispose(); return; }
        var framed = new byte[2 + message.Length];
        framed[0] = (byte)(message.Length >> 8); framed[1] = (byte)message.Length;
        message.CopyTo(framed, 2);
        await peer.Client.GetStream().WriteAsync(framed);
    }

    private async Task HandleRawAsync(Peer peer, byte[] message)
    {
        try
        {
            if (peer.Keys is null)
            {
                var handshake = peer.Handshake ?? throw new NoiseException("Missing handshake.");
                var payload = handshake.ReadMessage(message);
                if (payload.Length > 0 && JsonDocument.Parse(payload).RootElement.ValueKind == JsonValueKind.Object)
                {
                    var hello = DeviceJson.Decode<DeviceHello>(payload);
                    if (hello.ProtocolVersion != 1) { peer.Client.Dispose(); return; }
                    peer.Hello = hello;
                    // Raw-address Group joins learn the target from message two,
                    // before the final Noise hello asks the sponsor for admission.
                    if (peer.WantsJoin && peer.JoiningGroupID is null) peer.JoiningGroupID = hello.Group?.Id;
                }
                var finished = TryFinish(handshake);
                if (finished is null)
                {
                    await SendRawAsync(peer, handshake.WriteMessage(DeviceJson.Encode(Hello(peer.WantsJoin ? peer.JoiningGroupID : null))));
                    if (peer.IsInitiator)
                    {
                        peer.Keys = handshake.Finish();
                        await BeginTrustAsync(peer);
                    }
                    return;
                }
                peer.Keys = finished;
                await BeginTrustAsync(peer);
            }
            else
            {
                var plain = peer.Keys.Receiver.Decrypt(message);
                foreach (var envelope in peer.Decoder.Append(plain))
                {
                    if (envelope.Version != 1) { peer.Client.Dispose(); return; }
                    await HandleEnvelopeAsync(peer, envelope);
                }
            }
        }
        catch { peer.Client.Dispose(); }
    }

    private static DeviceTransportKeys? TryFinish(DeviceHandshake handshake)
    {
        try { return handshake.Finish(); } catch { return null; }
    }

    internal static bool RefusesLegacy(DeviceHello hello) =>
        !hello.Capabilities.Contains("converse-groups-v1");

    private async Task BeginTrustAsync(Peer peer)
    {
        if (peer.Keys is null || peer.Hello is null) { peer.Client.Dispose(); return; }
        var hello = peer.Hello;
        if (hello.DeviceID != DeviceBlob.DeviceIdForPublicKey(peer.Keys.RemoteStatic)) { peer.Client.Dispose(); return; }
        if (hello.DeviceID == DeviceId) { peer.Client.Dispose(); return; } // never trust self
        if (RefusesLegacy(hello)) { LastOutcome = "Update the other device to use Converse Groups."; peer.Client.Dispose(); return; }
        // Duplicate-connection arbitration: keep exactly one channel per peer.
        var preferInitiator = string.CompareOrdinal(DeviceId, hello.DeviceID) < 0;
        var other = _peers.Values.FirstOrDefault(p => p != peer && p.Hello?.DeviceID == hello.DeviceID && p.Keys is not null);
        if (other is not null)
        {
            if (other.TrustedReady || (other.IsInitiator == preferInitiator && peer.IsInitiator != preferInitiator))
            { Disconnect(peer); return; }
            Disconnect(other);
        }
        var check = Trust.Check(hello.DeviceID, peer.Keys.RemoteStatic);
        if (peer.WantsJoin)
        {
            // Joiner path: an authenticated group definition is required, and
            // the join target must match it (unless joining by raw address,
            // which learns the group from the responder).
            if (peer.JoiningGroupID is null && hello.JoinGroupID is null) { /* address join learns below */ }
            if (hello.Group is not { } claimed || !claimed.Valid || claimed.Dissolved
                || (peer.JoiningGroupID is not null && claimed.Id != peer.JoiningGroupID)
                || KnownGroups.FirstOrDefault(g => g.Id == claimed.Id) is { Dissolved: true })
            { LastOutcome = "Join failed: no valid group offered."; peer.Client.Dispose(); return; }
            if (peer.JoiningGroupID is null) peer.JoiningGroupID = claimed.Id;
            peer.AdmissionGroup = claimed;
            OfferPairing(peer, claimed, check == "keyChanged");
            return;
        }
        if (hello.JoinGroupID is not null)
        {
            // Sponsor path: only members of the requested group may anchor;
            // expired requests prune before the capacity check.
            SweepExpiredSponsors();
            if (CurrentGroup is null || hello.JoinGroupID != CurrentGroup.Id || _sponsoredRequests.Count >= 16)
            { peer.Client.Dispose(); return; }
            var request = new GroupJoinRequest
            {
                Id = peer.Id, GroupID = CurrentGroup.Id, RequesterID = hello.DeviceID,
                RequesterName = DeviceTrustStore.BoundedName(hello.DeviceName), SponsorID = DeviceId,
                ExpiresAt = DeviceTrustStore.AppleNow() + 180, Approved = false,
            };
            _sponsoredRequests[peer.Id] = request;
            GroupRequests.Add(request);
            await PublishGroupRequestsAsync();
            ServiceStatus = hello.DeviceName + " asked to join " + CurrentGroup.Name + ".";
            Changed?.Invoke();
            return;
        }
        // Removed devices only exchange membership until readmitted: their
        // reconnects never reach the member or control-only paths below.
        if (LocallyRemoved) { peer.Client.Dispose(); return; }
        var pinned = Trust.Devices.FirstOrDefault(d => d.DeviceID == hello.DeviceID);
        var member = pinned is not null && pinned.GroupID == CurrentGroup?.Id && CurrentGroup is not null;
        if (member && check == "trusted")
        {
            // Automatic reconnect: no human reviewed THIS connection, so
            // HumanConfirmed stays false and FinishTrust pins metadata only.
            peer.LocalConfirmed = true;
            await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.PairConfirm });
            FinishTrust(peer);
            return;
        }
        // Reconnect from a known pin outside the current group: control-only
        // membership exchange when either side carries a dissolution, or the
        // group matches our current one. Nothing else flows here.
        var knownGroup = pinned?.GroupID is string gid ? KnownGroups.FirstOrDefault(g => g.Id == gid) : null;
        var id = pinned?.GroupID;
        if (pinned is not null && id is not null && check == "trusted"
            && ((knownGroup?.Dissolved == true && hello.Group?.Id == id)
                || (CurrentGroup?.Id == id && (hello.Group is null || hello.Group.Id == id))))
        {
            peer.ControlOnly = true;
            peer.LocalConfirmed = true;
            await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.PairConfirm });
            FinishTrust(peer);
            return;
        }
        // Group-scoped reconnect can never mint generic pairing.
        LastOutcome = member ? "Stored key mismatch." : "Use Converse Groups to join.";
        peer.Client.Dispose();
    }

    // Serialized join prompts: the joiner sees its code immediately in the
    // Groups dialog; the optional callback lets tests approve directly.
    private void OfferPairing(Peer peer, ConverseGroup group, bool keyChanged)
    {
        var prompt = new PairingPrompt(peer.Hello!.DeviceName,
            peer.Hello.DeviceID[..Math.Min(16, peer.Hello.DeviceID.Length)].ToUpperInvariant(),
            DeviceSas.Code(peer.Keys!.HandshakeHash), keyChanged, peer.IsInitiator, peer.Id);
        GroupPairingPrompts.RemoveAll(p => p.PeerId == peer.Id);
        GroupPairingPrompts.Add(prompt);
        ServiceStatus = "Verify the security number to join " + group.Name + ".";
        Changed?.Invoke();
        if (PairingConfirmation is not null)
            _ = Task.Run(async () =>
            {
                await _pairingQueue.WaitAsync();
                try
                {
                    if (await PairingConfirmation(prompt)) await ConfirmPairing(peer.Id);
                    else RejectPairing(peer.Id);
                }
                finally { _pairingQueue.Release(); }
            });
    }

    public async Task<bool> ConfirmPairing(Guid peerId)
    {
        if (!_peers.TryGetValue(peerId, out var peer) || peer.Hello is null || peer.Keys is null) return false;
        peer.HumanConfirmed = true;
        peer.LocalConfirmed = true;
        await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.PairConfirm });
        FinishTrust(peer);
        return true;
    }

    public void RejectPairing(Guid peerId)
    {
        GroupPairingPrompts.RemoveAll(p => p.PeerId == peerId);
        if (_peers.TryGetValue(peerId, out var peer)) Disconnect(peer);
        Changed?.Invoke();
    }

    private void FinishTrust(Peer peer)
    {
        if (!peer.LocalConfirmed || !peer.RemoteConfirmed || peer.TrustedReady || peer.Hello is null || peer.Keys is null) return;
        if (peer.WantsJoin)
        {
            // A join confirm without a reviewed code disconnects: the half
            // approval must never linger as a trusted socket.
            if (!peer.HumanConfirmed || peer.AdmissionGroup is null) { Disconnect(peer); return; }
            try { ActivateGroup(peer.AdmissionGroup, peer.Id); }
            catch { LastOutcome = "Could not save group."; peer.Client.Dispose(); return; }
        }
        if (!(peer.HumanConfirmed || Trust.Check(peer.Hello.DeviceID, peer.Keys.RemoteStatic) == "trusted")) { Disconnect(peer); return; }
        var port = peer.Hello.ListenPort ?? peer.ManualPort;
        try
        {
            // Only an actually reviewed connection admits: automatic
            // reconnects refresh metadata on their existing pin, and a
            // control-only peer keeps its own stamped group.
            Trust.Pin(new TrustedDevice(peer.Hello.DeviceID, peer.Hello.DeviceName, peer.Keys.RemoteStatic,
                peer.ManualHost, port), DeviceId, peer.HumanConfirmed,
                peer.ControlOnly
                    ? Trust.Records.FirstOrDefault(d => d.DeviceID == peer.Hello.DeviceID)?.GroupID
                    : CurrentGroup?.Id ?? peer.Hello.Group?.Id);
            if (!peer.ControlOnly && !LocallyRemoved)
                Trust.Pin(new TrustedDevice(DeviceId, DeviceName, X25519.PublicKeyFromPrivate(_staticPrivate),
                    null, ListeningPort > 0 ? ListeningPort : null), DeviceId, true, CurrentGroup?.Id);
        }
        catch { LastOutcome = "Could not save paired device. Control not granted."; peer.Client.Dispose(); return; }
        peer.TrustedReady = true;
        if (_failedConnectionEndpoint == peer.ManualHost + ":" + peer.ManualPort)
        {
            ConnectionNotice = "";
            _failedConnectionEndpoint = null;
        }
        if (peer.ControlOnly)
        {
            _ = SendGroupStateAsync(peer);
            Changed?.Invoke();
            return;
        }
        GroupPairingPrompts.RemoveAll(p => p.PeerId == peer.Id);
        WithdrawGroupRequest(peer.Id);
        Homes[peer.Hello.DeviceID] = new RemoteHomeState
        {
            DeviceID = peer.Hello.DeviceID, DeviceName = peer.Hello.DeviceName, Online = true,
            Rows = Homes.GetValueOrDefault(peer.Hello.DeviceID)?.Rows ?? new(),
        };
        RefreshGroupMembers();
        _ = SendSidebarAsync(peer);
        _ = SendGroupStateAsync(peer);
        _ = BroadcastFabricAsync();
        _ = ReconnectFabricAsync();
        Changed?.Invoke();
    }

    private void Disconnect(Peer peer)
    {
        if (peer.Hello is { } departed) _queueWatchReports.TryRemove(departed.DeviceID, out _);
        peer.Client.Dispose();
        if (!_peers.Remove(peer.Id)) return; // Disconnect callbacks may arrive twice.
        GroupPairingPrompts.RemoveAll(p => p.PeerId == peer.Id);
        WithdrawGroupRequest(peer.Id);
        if (peer.Hello is { } hello && !_peers.Values.Any(p => p.TrustedReady && p.Hello?.DeviceID == hello.DeviceID))
        {
            if (Homes.TryGetValue(hello.DeviceID, out var home))
            {
                home.Online = false;
                foreach (var row in home.Rows)
                {
                    _pendingTakes.Remove(row.GlobalID);
                    RemoteLeases.Remove(row.GlobalID);
                    RemoteOffline.Add(row.GlobalID);
                    _outbox.MarkUncertain(row.GlobalID);
                }
            }
            foreach (var sessionId in peer.LeasedSessions.ToList())
            {
                // Expire home leases held by the disconnected viewer promptly.
                _leases.ForceRelease(sessionId, hello.DeviceID);
            }
        }
        Changed?.Invoke();
    }

    // ---- Fabric membership ----
    // Leaving broadcasts under the PREVIOUS group: the socket is still open
    // and the peers are still stamped there, so the tombstone lands before
    // anyone disconnects.
    public async Task BroadcastFabricAsync(string? groupID = null)
    {
        var id = groupID ?? CurrentGroup?.Id;
        if (id is null) return;
        var records = Trust.Records.Where(d => d.GroupID == id).ToList();
        foreach (var peer in _peers.Values.Where(p => CanExchangeFabric(p, id)).ToList())
            await SendEnvelopeAsync(peer, new DeviceEnvelope
            { Kind = DeviceKind.FabricMembers, Payload = DeviceJson.Encode(records) });
    }

    private bool CanExchangeFabric(Peer peer, string? groupID = null) =>
        peer is { TrustedReady: true, Hello: not null }
        && peer.Hello.Capabilities.Contains("fabric-membership-v1")
        && !peer.ControlOnly
        && Trust.Devices.Any(d => d.DeviceID == peer.Hello.DeviceID && d.GroupID == (groupID ?? CurrentGroup?.Id));

    public async Task ReconnectFabricAsync()
    {
        if (CurrentGroup is null || LocallyRemoved) return;
        foreach (var device in Trust.Devices.Where(d => d.DeviceID != DeviceId && d.GroupID == CurrentGroup.Id).ToList())
        {
            if (_peers.Values.Any(p => p.Hello?.DeviceID == device.DeviceID && p.Keys is not null)) continue;
            var endpoint = (device.LastHost, device.LastPort) switch
            {
                (string host, int port) => (host, port),
                _ => DiscoveredEndpoint(device.DeviceID),
            };
            if (endpoint is not { } address) continue;
            _ = ConnectAsync(Guid.NewGuid(), address.host, address.port, null, false, userInitiated: false);
        }
        await Task.CompletedTask;
    }

    private (string host, int port)? DiscoveredEndpoint(string deviceId)
    {
        lock (DiscoveredDevices)
        {
            var found = DiscoveredDevices.FirstOrDefault(d =>
                d.DeviceID == deviceId || d.Name.EndsWith("[" + ShortDeviceId(deviceId) + "]", StringComparison.Ordinal));
            return found is null ? null : (found.Host, found.Port);
        }
    }

    // ---- Converse Groups ----
    // Discovery hints honor the 120s mDNS TTL: dead peers stop being
    // listed (and rejoinable) until they announce again.
    private void PruneDiscovery()
    {
        var now = DateTime.UtcNow;
        DiscoveredDevices.RemoveAll(d => d.SeenAt != default && (now - d.SeenAt).TotalSeconds > 120);
    }

    public List<ConverseGroup> AvailableGroups()
    {
        var groups = KnownGroups.Where(g => !g.Dissolved).ToList();
        lock (DiscoveredDevices)
        {
            PruneDiscovery();
            foreach (var found in DiscoveredDevices)
            {
                if (found.Group is { } hint && hint.Valid && !hint.Dissolved
                    && KnownGroups.All(g => g.Id != hint.Id || g.Dissolved)
                    && groups.All(g => g.Id != hint.Id))
                    groups.Add(hint);
            }
        }
        return groups.OrderBy(g => g.Name.ToLowerInvariant()).ThenBy(g => g.Id, StringComparer.Ordinal).ToList();
    }

    // Labels show an 8-character prefix; trust files and LAN hints can carry shorter IDs.
    internal static string ShortDeviceId(string id) => id.Length > 8 ? id[..8] : id;

    public List<(string DeviceID, string Label)> GroupDevices(ConverseGroup group)
    {
        var rows = new List<(string, string)>();
        var members = Trust.Devices.Where(d => d.GroupID == group.Id && d.DeviceID != DeviceId)
            .OrderBy(d => d.Name.ToLowerInvariant()).ThenBy(d => d.DeviceID, StringComparer.Ordinal).ToList();
        foreach (var device in members)
            rows.Add((device.DeviceID, (device.DisplayName ?? device.Name) + " [" + ShortDeviceId(device.DeviceID) + "]"));
        // Swift parity: this device appears only under its current group,
        // never under left groups or strangers' advertisements.
        if (group.Id == CurrentGroup?.Id)
            rows.Add((DeviceId, DisplayName(DeviceId) + " [this device]"));
        lock (DiscoveredDevices)
        {
            PruneDiscovery();
            foreach (var found in DiscoveredDevices.Where(d => d.Group?.Id == group.Id && d.Group.Valid && !d.Group.Dissolved))
            {
                var id = found.DeviceID;
                if (id is not null && (id == DeviceId || members.Any(d => d.DeviceID == id))) continue;
                var label = id is null ? found.Name + " (unverified)"
                    : members.Any(d => d.Name == found.Name)
                        ? found.Name + " [" + ShortDeviceId(id) + "]" : found.Name;
                rows.Add((id ?? found.Name, label));
            }
        }
        return rows;
    }

    public bool CanJoinGroup(string id) =>
        AvailableGroups().Any(g => g.Id == id) && CurrentGroup?.Id != id
        && !_peers.Values.Any(p => p.WantsJoin && p.JoiningGroupID == id);

    public async Task JoinGroupAsync(ConverseGroup group)
    {
        MdnsService? target;
        lock (DiscoveredDevices)
            target = DiscoveredDevices.FirstOrDefault(d => d.Group?.Id == group.Id && d.Group.Valid && !d.Group.Dissolved);
        if (target is null) { LastOutcome = "No reachable member advertises that group."; return; }
        await ConnectAsync(Guid.NewGuid(), target.Host, target.Port, group.Id, true);
    }

    public async Task JoinGroupByAddressAsync(string host, int port, string groupID)
    {
        if (port is < 1 or > 65535) { LastOutcome = "Port must be between 1 and 65535."; return; }
        ConverseGroup? group = null;
        if (!string.IsNullOrWhiteSpace(groupID))
        {
            group = KnownGroups.FirstOrDefault(g => g.Id == groupID && !g.Dissolved);
            if (group is null) { LastOutcome = "Unknown group."; return; }
        }
        await ConnectAsync(Guid.NewGuid(), host.Trim(), port, group?.Id, true);
    }

    public async Task CreateGroupAsync(string name)
    {
        var trimmed = name.Trim();
        if (trimmed.Length == 0 || System.Text.Encoding.UTF8.GetByteCount(trimmed) > 120)
        { LastOutcome = "Group name must be 1..120 bytes."; return; }
        if (AvailableGroups().Any(g => string.Equals(g.Name, trimmed, StringComparison.OrdinalIgnoreCase)))
        { LastOutcome = "A visible group already has that name."; return; }
        var group = new ConverseGroup { Id = Guid.NewGuid().ToString("d"), Name = trimmed, Creator = DeviceId };
        GroupStore.Adopt(group);
        Trust.Pin(new TrustedDevice(DeviceId, DeviceName, X25519.PublicKeyFromPrivate(_staticPrivate),
            null, ListeningPort > 0 ? ListeningPort : null), DeviceId, true, group.Id);
        // One fenced transition: park my remote views, release old-group
        // holds on my sessions, then rescope. Queued traffic in both
        // directions stops at the membership gate from here on.
        ParkGroupViews(silent: true);
        FenceHomeLeases();
        RefreshGroupMembers();
        Reannounce();
        ServiceStatus = "Created " + trimmed + ".";
        Changed?.Invoke();
        await BroadcastFabricAsync();
        await ReconnectFabricAsync();
    }

    public void ActivateGroup(ConverseGroup group, Guid keepPeerId)
    {
        if (!group.Valid || group.Dissolved) throw new InvalidDataException("Invalid group.");
        var previous = CurrentGroup;
        if (previous?.Id == group.Id)
        {
            Trust.Pin(new TrustedDevice(DeviceId, DeviceName, X25519.PublicKeyFromPrivate(_staticPrivate),
                null, ListeningPort > 0 ? ListeningPort : null), DeviceId, true, group.Id);
            RefreshGroupMembers();
            return;
        }
        GroupStore.Adopt(group);
        // A human-approved join always stamps self into the new group,
        // superseding the old self-pin or any removal tombstone: this is
        // the readmission path. Old-group members converge stale through
        // reconnect refusal, like Swift; no self-tombstone is written.
        Trust.Pin(new TrustedDevice(DeviceId, DeviceName, X25519.PublicKeyFromPrivate(_staticPrivate),
            null, ListeningPort > 0 ? ListeningPort : null), DeviceId, true, group.Id);
        RefreshGroupMembers();
        ParkGroupViews(silent: true);
        foreach (var id in _peers.Keys.Where(k => k != keepPeerId).ToList())
            if (_peers.TryGetValue(id, out var peer))
                Disconnect(peer);
        ServiceStatus = "Joined " + group.Name + ".";
        Reannounce();
        Changed?.Invoke();
    }

    public async Task LeaveGroupAsync()
    {
        var group = CurrentGroup;
        if (group is null) return;
        GroupStore.Leave();
        Trust.Forget(DeviceId, DeviceId);
        // Broadcast under the previous group while the sockets are open, so
        // members learn the tombstone without needing a disconnect.
        await BroadcastFabricAsync(group.Id);
        ParkGroupViews(silent: true);
        RefreshGroupMembers();
        Reannounce();
        ServiceStatus = "Left " + group.Name + ". Devices remember the group for rejoining.";
        Changed?.Invoke();
        var old = _peers.Values.ToList();
        foreach (var peer in old) peer.ControlOnly = true;
        await Task.Delay(300);
        foreach (var peer in old) Disconnect(peer);
    }

    public bool CanDissolveGroup(string id) => !LocallyRemoved && CurrentGroup?.Id == id;

    public async Task DissolveGroupAsync(ConverseGroup group)
    {
        if (!group.Valid) { LastOutcome = "Unknown group."; return; }
        if (!CanDissolveGroup(group.Id)) { LastOutcome = "Join this group before dissolving it."; return; }
        GroupStore.Dissolve(group);
        RefreshGroupMembers();
        Reannounce();
        foreach (var peer in _peers.Values.Where(p => p is { TrustedReady: true, ControlOnly: false }).ToList())
        {
            await SendGroupStateAsync(peer);
            peer.ControlOnly = true;
        }
        ParkGroupViews(silent: true);
        ServiceStatus = "Dissolved " + group.Name + ".";
        Changed?.Invoke();
        await Task.Delay(300);
        foreach (var peer in _peers.Values.ToList()) Disconnect(peer);
        await BroadcastFabricAsync();
    }

    // Moving groups parks remote views and marks pending sends uncertain;
    // local panes, drafts and queues are untouched.
    public void ParkGroupViews(bool silent = false)
    {
        foreach (var globalId in RemoteLeases.Keys.ToList())
            _ = ReleaseRemoteAsync(globalId);
        RemoteLeases.Clear();
        RemoteTranscripts.Clear();
        RemoteOffline.Clear();
        foreach (var record in Outbox) _outbox.Resolve(record.CommandID, "uncertain", "Group changed.");
        if (!silent) Changed?.Invoke();
    }

    // Expiry closes the join socket, drops the request everywhere, and
    // clears a matching review: a stale review must never approve. The
    // join peer's disconnect withdraws an already-removed request, so no
    // recursive republish fires. Returns true when anything expired.
    internal bool SweepExpiredSponsors()
    {
        var now = DeviceTrustStore.AppleNow();
        var expired = _sponsoredRequests.Where(kv => kv.Value.ExpiresAt <= now).Select(kv => kv.Key).ToList();
        foreach (var id in expired)
        {
            _sponsoredRequests.Remove(id);
            GroupRequests.RemoveAll(r => r.Id == id);
            lock (_reviewLock) { if (GroupReview?.Request.Id == id) GroupReview = null; }
            if (_peers.TryGetValue(id, out var peer)) Disconnect(peer);
        }
        if (expired.Count > 0) Changed?.Invoke();
        return expired.Count > 0;
    }

    // Completed acks leave the outbox; tests read their receipt detail here.
    internal event Action<Guid, DeviceAckPayload>? AckReceivedForTest;
    internal void ExpireJoinForTest(Guid requestId)
    {
        if (_sponsoredRequests.TryGetValue(requestId, out var live))
            _sponsoredRequests[requestId] = new GroupJoinRequest
            {
                Id = live.Id, GroupID = live.GroupID, RequesterID = live.RequesterID,
                RequesterName = live.RequesterName, SponsorID = live.SponsorID,
                ExpiresAt = DeviceTrustStore.AppleNow() - 1, Approved = live.Approved,
            };
    }

    private async Task PublishGroupRequestsAsync()
    {
        SweepExpiredSponsors();
        var requests = _sponsoredRequests.Values.Where(r => CurrentGroup is not null && r.GroupID == CurrentGroup.Id).ToList();
        foreach (var peer in _peers.Values.Where(p => CanExchangeFabric(p)).ToList())
            await SendEnvelopeAsync(peer, new DeviceEnvelope
            { Kind = DeviceKind.GroupRequests, Payload = DeviceJson.Encode(requests) });
    }

    private void WithdrawGroupRequest(Guid requestId)
    {
        if (_sponsoredRequests.Remove(requestId))
        {
            GroupRequests.RemoveAll(r => r.Id == requestId);
            _ = PublishGroupRequestsAsync();
        }
    }

    private async Task SendGroupStateAsync(Peer peer)
    {
        if (peer.Hello is null) return;
        await SendEnvelopeAsync(peer, new DeviceEnvelope
        { Kind = DeviceKind.GroupState, Payload = DeviceJson.Encode(KnownGroups) });
    }

    // A member reviews through the sponsor: the sponsor's own connection
    // anchors the request; direct sponsors read the live code locally.
    public async Task ReviewGroupRequestAsync(GroupJoinRequest request)
    {
        if (CurrentGroup is null || request.GroupID != CurrentGroup.Id
            || !GroupJoinRequests.Live(request)) return;
        if (_sponsoredRequests.TryGetValue(request.Id, out var live)
            && _peers.TryGetValue(request.Id, out var joinPeer)
            && joinPeer is { Keys: not null, Hello: not null } && !joinPeer.TrustedReady)
        {
            lock (_reviewLock) { GroupReview = new GroupJoinReview { Request = live, Code = DeviceSas.Code(joinPeer.Keys.HandshakeHash) }; }
            Changed?.Invoke();
            return;
        }
        var sponsor = _peers.Values.FirstOrDefault(p => p.Hello?.DeviceID == request.SponsorID && CanExchangeFabric(p));
        if (sponsor is null) { LastOutcome = "Sponsor is unreachable."; return; }
        // group.review carries the BARE request on the wire (Swift parity):
        // the wrapper only exists for review.detail and review.approve.
        await SendEnvelopeAsync(sponsor, new DeviceEnvelope
        { Kind = DeviceKind.GroupReview, Payload = DeviceJson.Encode(request) });
    }

    // Atomic approval: the expected review is captured and consumed under
    // the shared review lock, and the captured value — never the mutable
    // property — flows into the approval below. A replaced or missing
    // review refuses instead of approving the wrong request.
    private readonly object _reviewLock = new();

    public async Task<bool> TryApproveGroupReviewAsync(Guid expectedRequestID, string expectedCode)
    {
        GroupJoinReview? stored;
        lock (_reviewLock)
        {
            stored = GroupReview;
            if (stored is null || stored.Request.Id != expectedRequestID || stored.Code != expectedCode)
                return false;
            GroupReview = null;
        }
        return await ApproveReviewAsync(stored);
    }

    public async Task ApproveGroupReviewAsync()
    {
        GroupJoinReview? stored;
        lock (_reviewLock)
        {
            stored = GroupReview;
            GroupReview = null;
        }
        if (stored is null) return;
        await ApproveReviewAsync(stored);
    }

    private async Task<bool> ApproveReviewAsync(GroupJoinReview stored)
    {
        // Approval always follows a human-reviewed code, even when the
        // reviewer is the sponsor itself: the stored code is verified
        // against the live join channel either way. No direct path.
        if (_sponsoredRequests.ContainsKey(stored.Request.Id))
            return await ApproveSponsoredAsync(stored);
        var sponsor = _peers.Values.FirstOrDefault(p => p.Hello?.DeviceID == stored.Request.SponsorID && CanExchangeFabric(p));
        if (sponsor is null) { LastOutcome = "Sponsor is unreachable."; return false; }
        await SendEnvelopeAsync(sponsor, new DeviceEnvelope
        { Kind = DeviceKind.GroupApprove, Payload = DeviceJson.Encode(stored) });
        return true;
    }

    // The approve gate: the request must equal the live sponsored original
    // field-for-field, and the reviewed code must match the join channel's
    // current handshake hash — verified for direct and relayed reviews
    // alike. Either side failing refuses admission silently.
    private async Task<bool> ApproveSponsoredAsync(GroupJoinReview review)
    {
        if (CurrentGroup is null || review.Request.GroupID != CurrentGroup.Id || !GroupJoinRequests.Live(review.Request)) return false;
        if (!_sponsoredRequests.TryGetValue(review.Request.Id, out var original)
            || !GroupJoinRequests.Same(original, review.Request)) return false;
        if (!_peers.TryGetValue(review.Request.Id, out var peer)
            || peer is not { Keys: not null, Hello: not null } || peer.TrustedReady) return false;
        if (review.Code != DeviceSas.Code(peer.Keys.HandshakeHash)) return false;
        original.Approved = true;
        _sponsoredRequests[review.Request.Id] = original;
        GroupRequests.RemoveAll(r => r.Id == review.Request.Id);
        await PublishGroupRequestsAsync();
        peer.HumanConfirmed = true;
        peer.LocalConfirmed = true;
        await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.PairConfirm });
        FinishTrust(peer);
        return true;
    }

    private async Task HandleGroupEnvelopeAsync(Peer peer, DeviceEnvelope envelope)
    {
        if (peer.Hello is null) return;
        switch (envelope.Kind)
        {
            case DeviceKind.GroupState:
            {
                // Conveys the full known list; only entries dissolved by a
                // member pinned to that same group take effect. Live groups
                // are announcements and change nothing.
                if (envelope.Payload is null) break;
                List<ConverseGroup> groups;
                try { groups = DeviceJson.Decode<List<ConverseGroup>>(envelope.Payload); }
                catch { break; }
                if (groups.Count > 2048) break;
                var issuer = Trust.Records.FirstOrDefault(d => d.DeviceID == peer.Hello.DeviceID
                    && d.Removed != true && d.PublicKey.AsSpan().SequenceEqual(peer.Keys?.RemoteStatic ?? Array.Empty<byte>()));
                if (issuer is null) break;
                foreach (var group in groups.Where(g => g.Valid && g.Dissolved && g.Id == issuer.GroupID))
                {
                    try
                    {
                        var affected = CurrentGroup?.Id == group.Id;
                        GroupStore.Dissolve(group);
                        KnownGroups = GroupStore.Groups.ToList();
                        if (!affected) continue;
                        foreach (var connection in _peers.Values.Where(p => p.TrustedReady && p.Id != peer.Id).ToList())
                            await SendGroupStateAsync(connection);
                        RefreshGroupMembers();
                        ParkGroupViews(silent: true);
                        Reannounce();
                        var old = _peers.Values.ToList();
                        foreach (var connection in old) connection.ControlOnly = true;
                        _ = Task.Run(async () => { await Task.Delay(300); foreach (var connection in old) Disconnect(connection); });
                        ServiceStatus = "Group dissolved by another member. Local sessions keep running.";
                    }
                    catch { LastOutcome = "Could not persist group dissolution."; }
                }
                Changed?.Invoke();
                break;
            }
            case DeviceKind.GroupRequests:
            {
                if (envelope.Payload is null) break;
                List<GroupJoinRequest> incoming;
                try { incoming = DeviceJson.Decode<List<GroupJoinRequest>>(envelope.Payload); }
                catch { break; }
                if (incoming.Count > 16 || !incoming.All(r => r.GroupID == CurrentGroup?.Id
                    && r.SponsorID == peer.Hello.DeviceID && r.RequesterID.Length == 64
                    && System.Text.Encoding.UTF8.GetByteCount(r.RequesterName) <= 400)) break;
                GroupRequests.RemoveAll(r => r.SponsorID == peer.Hello.DeviceID);
                GroupRequests.AddRange(incoming.Where(r => r.ExpiresAt > DeviceTrustStore.AppleNow()));
                Changed?.Invoke();
                break;
            }
            case DeviceKind.GroupReview:
            {
                if (envelope.Payload is null) break;
                var review = DeviceJson.Decode<GroupJoinRequest>(envelope.Payload);
                if (!_sponsoredRequests.TryGetValue(review.Id, out var original)
                    || !GroupJoinRequests.Same(original, review) || !GroupJoinRequests.Live(original)) break;
                if (!_peers.TryGetValue(review.Id, out var joinPeer)
                    || joinPeer is not { Keys: not null, Hello: not null } || joinPeer.TrustedReady) break;
                await SendEnvelopeAsync(peer, new DeviceEnvelope
                {
                    Kind = DeviceKind.GroupReviewDetail,
                    Payload = DeviceJson.Encode(new GroupJoinReview
                    { Request = original, Code = DeviceSas.Code(joinPeer.Keys.HandshakeHash) }),
                });
                break;
            }
            case DeviceKind.GroupReviewDetail:
            {
                if (envelope.Payload is null) break;
                var review = DeviceJson.Decode<GroupJoinReview>(envelope.Payload);
                if (review.Request.GroupID != CurrentGroup?.Id || !GroupJoinRequests.Live(review.Request)
                    || review.Code.Length != 39) break;
                lock (_reviewLock) { GroupReview = review; }
                Changed?.Invoke();
                break;
            }
            case DeviceKind.GroupApprove:
            {
                if (envelope.Payload is null) break;
                _ = await ApproveSponsoredAsync(DeviceJson.Decode<GroupJoinReview>(envelope.Payload));
                break;
            }
        }
    }

    private void Reannounce() => _mdns?.UpdateGroup(CurrentGroup, DeviceId);

    internal async Task SendEnvelopeAsync(Peer peer, DeviceEnvelope envelope)
    {
        if (peer.Keys is null) return;
        var framed = DeviceFrame.Encode(envelope);
        // Encrypt under the send lock: each Encrypt advances the Noise nonce,
        // so concurrent sends that encrypted first and then raced for the
        // socket could write out of nonce order. The peer's Decrypt then
        // failed and dropped the connection (and every display lease on it).
        // Holding the lock across chunks also keeps one envelope contiguous.
        await peer.SendLock.WaitAsync();
        try
        {
            for (var offset = 0; offset < framed.Length; offset += 60_000)
            {
                var chunk = framed.AsMemory(offset, Math.Min(60_000, framed.Length - offset)).ToArray();
                await WriteFrameAsync(peer, peer.Keys.Sender.Encrypt(chunk));
            }
        }
        finally { peer.SendLock.Release(); }
    }

    // ---- Home side ----
    internal DeviceSidebarPayload SidebarPayload(ulong sequence) => new()
    {
        HomeDeviceID = DeviceId,
        HomeDeviceName = DeviceName,
        HomeSeq = sequence,
        Rows = _store.Sessions.Select(session => new DeviceSidebarRow
        {
            GlobalID = new DeviceGlobalID(DeviceId, session.Id).ToString(),
            SessionID = session.Id,
            Title = session.Title,
            Assistant = session.Entry.Name,
            Engine = session.Entry.Engine,
            Model = session.Choices.Model ?? "",
            Effort = session.Choices.Effort ?? "",
            Access = session.Choices.Access ?? "",
            Status = session.Status,
            Busy = session.Busy,
            Queued = session.Pending.Count,
            QueuePaused = session.QueuePaused,
            LeaseHolder = _leases.Holder(session.Id)?.Device,
            LeaseEpoch = _leases.Holder(session.Id)?.Epoch,
            AccountName = session.Entry.AccountName,
            MessagingEnabled = session.MessagingEnabled, ParticipantKind = session.Agent is null ? null : "agent", Attention = session.Agent?.Attention,
            LoopPaused = SidebarMarkers.LoopPaused(session), PausedReason = SidebarMarkers.PausedReason(session),
            LastResponseAt = SidebarMarkers.LastResponseAt(session.Messages, session.Busy),
        }).ToList(),
    };

    private async Task SendSidebarAsync(Peer peer)
    {
        if (peer.Hello is null || !IsGroupMember(peer.Hello.DeviceID)) return;
        var sequence = _syncCounters.NextSequence();
        await SendEnvelopeAsync(peer, new DeviceEnvelope
        { Kind = DeviceKind.SidebarSnapshot, HomeSeq = sequence, Boot = _boot, Payload = DeviceJson.Encode(SidebarPayload(sequence)) });
    }

    private readonly Dictionary<Guid, string> _publishedMetadata = new();
    private void PublishSidebars()
    {
        if (CurrentGroup is null || LocallyRemoved) return;
        foreach (var peer in _peers.Values.Where(p => p.TrustedReady && !p.ControlOnly)) _ = SendSidebarAsync(peer);
        foreach (var session in _store.Sessions)
        {
            // A home-side rename must reach the held pane, not only the
            // directory. Ordinary draft saves do not force a transcript push.
            var signature = System.Text.Json.JsonSerializer.Serialize(new { session.Title, session.Agent });
            if (_publishedMetadata.GetValueOrDefault(session.Id) == signature) continue;
            _publishedMetadata[session.Id] = signature; PushTranscriptToHolder(session);
        }
    }

    private void HomeSessionClosed(ChatSession session)
    {
        _publishedMetadata.Remove(session.Id);
        if (_leases.Holder(session.Id) is { } holder)
        {
            _leases.Release(session.Id, holder.Device, holder.Epoch);
            DisplayLeaseReleased?.Invoke(session.Id, holder.Device, holder.Epoch);
        }
        var global = new DeviceGlobalID(DeviceId, session.Id).ToString();
        foreach (var peer in _peers.Values.Where(p => p.TrustedReady && !p.ControlOnly).ToArray())
        {
            peer.LeasedSessions.Remove(session.Id);
            _ = SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.LeaseStolen, Boot = _boot, SessionID = global });
        }
        PublishSidebars(); Changed?.Invoke();
    }

    private string ImageHash(string path)
    {
        var hash = DeviceBlob.Sha256Hex(File.ReadAllBytes(path));
        _blobPaths[hash] = path;
        return hash;
    }

    private readonly ConcurrentDictionary<Guid, byte> _catalogRefreshes = new();
    private async Task RefreshCodexCatalogAsync(ChatSession session)
    {
        if (!_catalogRefreshes.TryAdd(session.Id, 0)) return;
        var entry = session.Entry.Copy();
        try
        {
            await _store.CodexModels.GetAsync(entry);
            if (_shutdown?.IsCancellationRequested == false && _store.Sessions.Contains(session) && CodexModelCatalog.Key(session.Entry) == CodexModelCatalog.Key(entry))
                PushTranscriptToHolder(session);
        }
        finally { _catalogRefreshes.TryRemove(session.Id, out _); }
    }

    private async Task SendTranscriptAsync(Peer peer, ChatSession session, int? beforeOffset = null)
    {
        if (peer.Hello is null || !IsGroupMember(peer.Hello.DeviceID)) return;
        CodexCatalogResult? catalog = null;
        if (session.Entry.Engine == "codex")
        {
            catalog = _store.CodexModels.Cached(session.Entry);
            if (catalog is null || catalog.ExpiresAt <= DateTime.UtcNow) _ = RefreshCodexCatalogAsync(session);
        }
        if (!_store.Sessions.Contains(session) || peer.Hello is null || !IsGroupMember(peer.Hello.DeviceID)) return;
        var holder = _leases.Holder(session.Id);
        if (holder is null || holder.Value.Device != peer.Hello.DeviceID) { peer.LeasedSessions.Remove(session.Id); return; }
        var total = session.Messages.Count;
        var end = Math.Clamp(beforeOffset ?? total, 0, total);
        var start = Math.Max(0, end - 200);
        var draftKey = session.Id.ToString("D");
        if (_drafts.Text(draftKey) is null) _drafts.Adopt(draftKey, Math.Max(1UL, _drafts.Version(draftKey)), session.Draft);
        else if (_drafts.Text(draftKey) != session.Draft) _drafts.Bump(draftKey, session.Draft);
        var payload = new DeviceTranscriptPayload
        {
            GlobalID = new DeviceGlobalID(DeviceId, session.Id).ToString(),
            HomeSeq = _syncCounters.NextSequence(), Epoch = holder.Value.Epoch, Boot = _boot,
            Messages = session.Messages.Skip(start).Take(end - start).Select(m => new DeviceWireMessage
            {
                Id = m.Id, Role = m.Role, Text = m.Text, CreatedAt = m.CreatedAt, Components = m.Components,
                ImageHashes = m.Images.Where(File.Exists).Select(ImageHash).ToArray(),
            }).ToList(),
            Offset = start, Total = total, Prepend = beforeOffset is not null,
            Draft = session.Draft, DraftVersion = _drafts.Version(draftKey),
            DraftImageHashes = session.Attachments.Where(File.Exists).Select(ImageHash).ToArray(),
            Pending = session.Pending.Select(p => new DevicePendingDto { Id = p.Id, Text = p.Text }).ToList(),
            Requests = session.Requests.Select(request => new DeviceRequestDto
            {
                Id = request.Id, Kind = request.Kind,
                ToolName = request.Params["toolName"]?.GetValue<string>(),
                RawArgs = request.Params["rawArgs"]?.GetValue<string>(),
                Choices = (request.Params["availableChoices"] as System.Text.Json.Nodes.JsonArray ?? new())
                    .OfType<System.Text.Json.Nodes.JsonObject>()
                    .Where(c => c["choiceId"] is not null)
                    .Select(c => new DeviceChoiceDto
                    {
                        Id = c["choiceId"]!.GetValue<string>(),
                        Label = c["label"]?.GetValue<string>() ?? c["choiceId"]!.GetValue<string>(),
                        Detail = c["rulePreview"]?.GetValue<string>() ?? c["scope"]?.GetValue<string>(),
                    }).ToList(),
                QuestionsJson = request.Params["questions"] is { } questions
                    ? System.Text.Encoding.UTF8.GetBytes(questions.ToJsonString()) : null,
            }).ToList(),
            Busy = session.Busy, Status = session.Status, Title = session.Title, Engine = session.Entry.Engine,
            AccountName = session.Entry.AccountName,
            Model = session.Choices.Model ?? "", Effort = session.Choices.Effort ?? "", Access = session.Choices.Access ?? "",
            ModelOptions = catalog is not null ? catalog.Models.Select(o => new DeviceChoiceDto { Id = o.Id, Label = o.Label, Provider = "codex" }).ToList()
                : ChoicesCatalog.ModelsFor(session.Entry.Engine).Select(o => new DeviceChoiceDto { Id = o.Id, Label = o.Label }).ToList(),
            EffortOptions = catalog?.EffortsFor(session.Choices.Model) ?? ChoicesCatalog.EffortsFor(session.Entry.Engine).ToArray(),
            AccessOptions = ChoicesCatalog.AccessFor(session.Entry.Engine)
                .Select(o => new DeviceChoiceDto { Id = o.Id, Label = o.Label }).ToList(),
            QueuePaused = session.QueuePaused,
            AgentWidget = AgentWidgetFor(session),
        };
        await SendEnvelopeAsync(peer, new DeviceEnvelope
        { Kind = DeviceKind.TranscriptSnapshot, HomeSeq = payload.HomeSeq, Boot = _boot, SessionID = payload.GlobalID, Epoch = holder.Value.Epoch, Payload = DeviceJson.Encode(payload) });
    }

    private ChatSession? HomeSession(DeviceEnvelope envelope)
    {
        if (envelope.SessionID is null) return null;
        var global = DeviceGlobalID.Parse(envelope.SessionID);
        if (global is null || global.Value.Home != DeviceId) return null;
        return _store.Sessions.FirstOrDefault(s => s.Id == global.Value.Session);
    }

    private async Task<bool> RequireLeaseAsync(Peer peer, DeviceEnvelope envelope, ChatSession session)
    {
        if (peer.Hello is not null && envelope.Epoch is { } epoch && _leases.Validate(session.Id, peer.Hello.DeviceID, epoch)) return true;
        if (envelope.CommandID is { } commandId)
            await SendAckAsync(peer, commandId, envelope.SessionID, "rejected", "Stale or missing display lease. Take the session again.", envelope.Epoch);
        return false;
    }

    private async Task SendAckAsync(Peer peer, Guid commandId, string? sessionId, string outcome, string? detail = null, ulong? epoch = null) =>
        await SendEnvelopeAsync(peer, new DeviceEnvelope
        {
            Kind = DeviceKind.CommandAck, SessionID = sessionId, CommandID = commandId, Epoch = epoch,
            Payload = DeviceJson.Encode(new DeviceAckPayload { Outcome = outcome, Detail = detail, Epoch = epoch }),
        });

    private async Task ExecuteHomeCommandAsync(Peer peer, DeviceEnvelope envelope)
    {
        var session = HomeSession(envelope);
        if (session is null || envelope.CommandID is not { } commandId || envelope.Payload is null || peer.Hello is null) return;
        var command = DeviceJson.Decode<DeviceCommandPayload>(envelope.Payload);
        // Teaching needs no display lease, as on the Mac home: a viewer that
        // advertises switchboard-teach-v1 sends it with epoch 0.
        var teaching = command.Action == "teachSwitchboard" && envelope.Epoch == 0 && peer.Hello.Capabilities.Contains("switchboard-teach-v1");
        if (!teaching && !await RequireLeaseAsync(peer, envelope, session)) return;
        var payloadHash = DeviceBlob.Sha256Hex(envelope.Payload);
        if (!_commands.Begin(commandId, peer.Hello.DeviceID, envelope.SessionID ?? "", payloadHash))
        {
            await SendAckAsync(peer, commandId, envelope.SessionID,
                _commands.BindingMatches(commandId, peer.Hello.DeviceID, envelope.SessionID ?? "", payloadHash) ? _commands.Outcome(commandId) ?? "rejected" : "rejected",
                "Already recorded on home.", envelope.Epoch);
            return;
        }
        string[] known = { "submit", "inject", "injectAll", "stop", "resumeQueue", "pauseQueue", "clearQueue", "removeQueued", "rename", "model", "effort", "access", "answer", "teachSwitchboard" };
        if (!known.Contains(command.Action))
        {
            _commands.MarkFailed(commandId);
            await SendAckAsync(peer, commandId, envelope.SessionID, "failed", "Unknown action.", envelope.Epoch);
            return;
        }
        // Drain closes only work-starting actions. Stop, answers, queue
        // management and settings remain available so active work can finish.
        // The shared admission guard spans the rest of this command so the
        // final quiescence decision cannot miss in-flight work.
        if (!AcceptingWork && command.Action is "submit" or "inject" or "injectAll" or "resumeQueue" or "teachSwitchboard")
        {
            _commands.MarkFailed(commandId);
            await SendAckAsync(peer, commandId, envelope.SessionID, "failed",
                "This home is draining for an update. Nothing was submitted.", envelope.Epoch);
            return;
        }
        var startsWork = command.Action is "submit" or "inject" or "injectAll" or "resumeQueue" or "teachSwitchboard";
        if (startsWork && !TryBeginExternalWork())
        {
            _commands.MarkFailed(commandId);
            await SendAckAsync(peer, commandId, envelope.SessionID, "failed",
                "This home is draining for an update. Nothing was submitted.", envelope.Epoch);
            return;
        }
        try
        {
        if (command.Action == "submit")
        {
            var missing = command.BlobHashes.Where(h => !_blobPaths.TryGetValue(h, out var path) || !File.Exists(path)).ToList();
            if (missing.Count > 0)
            {
                _commands.MarkFailed(commandId);
                await SendAckAsync(peer, commandId, envelope.SessionID, "failed", "Attachments not stored on home yet. Nothing was submitted.", envelope.Epoch);
                return;
            }
            if (string.IsNullOrWhiteSpace(command.Text) && command.BlobHashes.Length == 0)
            {
                _commands.MarkFailed(commandId);
                await SendAckAsync(peer, commandId, envelope.SessionID, "failed", "Empty message.", envelope.Epoch);
                return;
            }
        }
        if (command.Action == "answer")
        {
            var request = session.Requests.FirstOrDefault(r => r.Id == command.RequestID);
            System.Text.Json.Nodes.JsonArray? answers = null;
            if (command.AnswersJson is not null)
                answers = System.Text.Json.Nodes.JsonNode.Parse(command.AnswersJson) as System.Text.Json.Nodes.JsonArray;
            var answered = request is not null && await _store.AnswerMuseAsync(session, request, command.ChoiceID, answers);
            if (!answered)
            {
                _commands.MarkFailed(commandId);
                await SendAckAsync(peer, commandId, envelope.SessionID, "failed", "Request is no longer pending on home.", envelope.Epoch);
                return;
            }
            _commands.MarkRunning(commandId);
            _commands.MarkCompleted(commandId);
            await SendAckAsync(peer, commandId, envelope.SessionID, "completed", "Decision sent on home.", envelope.Epoch);
            await SendTranscriptAsync(peer, session);
            return;
        }
        _commands.MarkRunning(commandId);
        string? failure = null;
        switch (command.Action)
        {
                case "teachSwitchboard": TeachSwitchboard(session); break;

            case "submit":
                var savedDraft = session.Draft;
                var savedAttachments = new List<string>(session.Attachments);
                var consumes = (command.Text ?? "") == savedDraft;
                session.Draft = command.Text ?? "";
                session.Attachments = command.BlobHashes.Select(h => _blobPaths[h]).ToList();
                _store.Submit(session);
                session.Draft = consumes ? "" : savedDraft;
                session.Attachments = consumes ? new List<string>() : savedAttachments;
                if (consumes) _drafts.Bump(session.Id.ToString("D"), "");
                break;
            case "inject":
                if (command.PendingID is null)
                {
                    _commands.MarkFailed(commandId);
                    await SendAckAsync(peer, commandId, envelope.SessionID, "failed",
                        "Inject not applied: no queued item was specified. Nothing was sent.", envelope.Epoch);
                    await SendTranscriptAsync(peer, session);
                    return;
                }
                failure = _store.InjectPending(session, command.PendingID);
                break;
            case "injectAll": failure = _store.InjectPending(session); break;
            case "stop": _store.Stop(session); break;
            case "resumeQueue": session.QueuePaused = false; _store.Save(); _store.RunNext(session); break;
            case "pauseQueue": session.QueuePaused = true; _store.Save(); break;
            case "clearQueue": session.Pending.Clear(); _store.Save(); break;
            case "removeQueued":
                failure = command.PendingID is { } pendingId ? _store.RemovePending(session, pendingId)
                    : "Remove not applied: no queued item was specified. Nothing was removed.";
                break;
            case "rename": if (!string.IsNullOrEmpty(command.Text)) { session.Title = command.Text; _store.Save(); } break;
            case "model": session.Choices.Model = command.Model; session.Choices.ModelProvider = command.ModelProvider; session.Choices.ModelProfile = command.ModelProfile; _store.Save(); break;
            case "effort": session.Choices.Effort = command.Effort; _store.Save(); break;
            case "access": session.Choices.Access = command.Access; _store.Save(); break;
        }
        // Automatic dequeue won the race: the inject completes as a no-op.
        var completion = "Applied once on home.";
        if (SessionStore.InjectIsNoOp(failure)) { completion = failure!; failure = null; }
        if (failure is not null)
        {
            _commands.MarkFailed(commandId);
            await SendAckAsync(peer, commandId, envelope.SessionID, "failed", failure, envelope.Epoch);
            await SendTranscriptAsync(peer, session);
            return;
        }
        _commands.MarkCompleted(commandId);
        await SendAckAsync(peer, commandId, envelope.SessionID, "completed", completion, envelope.Epoch);
        await SendTranscriptAsync(peer, session);
        }
        finally { if (startsWork) EndExternalWork(); }
    }

    // ---- Dispatch ----
    internal async Task HandleEnvelopeAsync(Peer peer, DeviceEnvelope envelope)
    {
        if (envelope.Kind == DeviceKind.PairConfirm)
        {
            peer.RemoteConfirmed = true;
            FinishTrust(peer);
            return;
        }
        if (!peer.TrustedReady || peer.Hello is null) return;
        var peerHome = peer.Hello.DeviceID;
        // Removed devices exchange membership only, never sessions.
        if (LocallyRemoved && envelope.Kind != DeviceKind.FabricMembers
            && envelope.Kind != DeviceKind.Ping && envelope.Kind != DeviceKind.Pong) return;
        // Control-only peers carry dissolution state and nothing else.
        if (peer.ControlOnly)
        {
            if (envelope.Kind == DeviceKind.GroupState) await HandleGroupEnvelopeAsync(peer, envelope);
            return;
        }
        // Session traffic never crosses a group boundary: after Create or a
        // group change, queued sends from stale peers drop here silently.
        if (SessionKinds.Contains(envelope.Kind) && !IsGroupMember(peerHome)) return;
        if (await HandleParticipantAsync(peer, envelope)) return;
        switch (envelope.Kind)
        {
            case DeviceKind.FabricMembers:
            {
                // Leave can clear CurrentGroup on another thread while this frame is merging.
                // Keep the authenticated group scope stable so an in-flight roster cannot
                // disconnect every socket before Leave broadcasts its removal tombstone.
                var receivingGroup = CurrentGroup?.Id;
                if (receivingGroup is null || envelope.Payload is null
                    || !peer.Hello.Capabilities.Contains("fabric-membership-v1")
                    || !Trust.Devices.Any(d => d.DeviceID == peerHome && d.GroupID == receivingGroup)) break;
                List<TrustedDevice> incoming;
                try { incoming = DeviceJson.Decode<List<TrustedDevice>>(envelope.Payload); }
                catch { peer.Client.Dispose(); return; }
                incoming = incoming.Where(d => d.GroupID == receivingGroup).ToList();
                var wasRemoved = LocallyRemoved;
                bool merged;
                try { merged = Trust.Merge(incoming); }
                catch { peer.Client.Dispose(); return; }
                var removedByFrame = !wasRemoved && LocallyRemoved
                    && incoming.Any(d => d.DeviceID == DeviceId && d.Removed == true);
                if (removedByFrame)
                {
                    // Freshly removed: leave quietly, park remotes, go dark.
                    GroupStore.Leave();
                    ParkGroupViews(silent: true);
                    RefreshGroupMembers();
                    ServiceStatus = "Removed by a group member.";
                    Changed?.Invoke();
                }
                var active = removedByFrame ? new HashSet<string>()
                    : Trust.Devices.Where(d => d.GroupID == receivingGroup).Select(d => d.DeviceID).ToHashSet();
                foreach (var gone in _peers.Values
                    .Where(p => p is { TrustedReady: true, Hello: not null } && !active.Contains(p.Hello.DeviceID)).ToList())
                    Disconnect(gone);
                RefreshGroupMembers();
                if (merged) _ = BroadcastFabricAsync();
                _ = ReconnectFabricAsync();
                Changed?.Invoke();
                break;
            }
            case DeviceKind.GroupState:
            case DeviceKind.GroupRequests:
            case DeviceKind.GroupReview:
            case DeviceKind.GroupReviewDetail:
            case DeviceKind.GroupApprove:
                if (Trust.Devices.Any(d => d.DeviceID == peerHome && d.GroupID == CurrentGroup?.Id))
                    await HandleGroupEnvelopeAsync(peer, envelope);
                break;
            case DeviceKind.Ping:
                await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.Pong });
                break;
            case DeviceKind.SidebarSnapshot:
                if (envelope.Payload is null) break;
                var sidebar = DeviceJson.Decode<DeviceSidebarPayload>(envelope.Payload);
                if (sidebar.HomeDeviceID != peerHome || sidebar.Rows.Any(r => DeviceGlobalID.Parse(r.GlobalID)?.Home != peerHome)) { peer.Client.Dispose(); return; }
                Homes[peerHome] = new RemoteHomeState { DeviceID = peerHome, DeviceName = sidebar.HomeDeviceName, Online = true, Rows = sidebar.Rows };
                foreach (var row in sidebar.Rows) RemoteOffline.Remove(row.GlobalID);
                Changed?.Invoke();
                break;
            case DeviceKind.LeaseAcquire:
            case DeviceKind.LeaseResume:
                if (HomeSession(envelope) is { } leased)
                {
                    var result = envelope.Kind == DeviceKind.LeaseResume
                        ? _leases.Resume(leased.Id, peerHome, envelope.Epoch ?? 0)
                        : _leases.Acquire(leased.Id, peerHome);
                    if (!result.Granted) { await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.LeaseDenied, Boot = _boot, SessionID = envelope.SessionID }); break; }
                    // Mac parity: the displaced previous holder must drop its
                    // view, or two devices show one session as live. The
                    // local pane parks in the UI refresh below via
                    // DisplayHolder; remote holders get lease.stolen here.
                    if (result.Displaced is { } displaced && displaced != peerHome)
                        foreach (var old in _peers.Values.Where(p => p.Hello?.DeviceID == displaced))
                        {
                            old.LeasedSessions.Remove(leased.Id);
                            await SendEnvelopeAsync(old, new DeviceEnvelope
                            {
                                Kind = DeviceKind.LeaseStolen, Boot = _boot,
                                SessionID = new DeviceGlobalID(DeviceId, leased.Id).ToString(), Epoch = result.Epoch,
                            });
                        }
                    peer.LeasedSessions.Add(leased.Id);
                    DisplayLeaseGranted?.Invoke(leased.Id, peerHome, result.Epoch);
                    PublishSidebars();
                    Changed?.Invoke();
                    await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.LeaseGranted, Boot = _boot, SessionID = envelope.SessionID, Epoch = result.Epoch });
                    await SendTranscriptAsync(peer, leased);
                }
                break;
            case DeviceKind.LeaseHeartbeat:
                if (HomeSession(envelope) is { } heartbeat && envelope.Epoch is { } hbEpoch)
                    _leases.Heartbeat(heartbeat.Id, peerHome, hbEpoch);
                break;
            case DeviceKind.LeaseRelease:
                if (HomeSession(envelope) is { } released && envelope.Epoch is { } relEpoch)
                {
                    var wasHolder = _leases.Holder(released.Id) is { } holder
                        && holder.Device == peerHome && holder.Epoch == relEpoch;
                    _leases.Release(released.Id, peerHome, relEpoch);
                    if (wasHolder) DisplayLeaseReleased?.Invoke(released.Id, peerHome, relEpoch);
                    peer.LeasedSessions.Remove(released.Id);
                    PublishSidebars();
                    Changed?.Invoke();
                }
                break;
            case DeviceKind.LeaseGranted:
                if (envelope.SessionID is { } grantedId && DeviceGlobalID.Parse(grantedId)?.Home == peerHome && envelope.Epoch is { } grantEpoch)
                {
                    if (_pendingTakes.Remove(grantedId)) { RememberDisplay(grantedId, grantEpoch); RemoteLeases[grantedId] = grantEpoch; RemoteOffline.Remove(grantedId); }
                    else if (RemoteLeases.TryGetValue(grantedId, out var current) && grantEpoch > current) { RememberDisplay(grantedId, grantEpoch); RemoteLeases[grantedId] = grantEpoch; }
                    else await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.LeaseRelease, SessionID = grantedId, Epoch = grantEpoch });
                    Changed?.Invoke();
                }
                break;
            case DeviceKind.LeaseExpired:
                if (envelope.SessionID is { } expiredId && DeviceGlobalID.Parse(expiredId)?.Home == peerHome && envelope.Epoch is { } expiredEpoch && RemoteLeases.GetValueOrDefault(expiredId) == expiredEpoch)
                {
                    RemoteLeases.Remove(expiredId); RemoteOffline.Add(expiredId);
                    Changed?.Invoke();
                }
                break;
            case DeviceKind.LeaseStolen:
            case DeviceKind.LeaseDenied:
                if (envelope.SessionID is { } stolenId && DeviceGlobalID.Parse(stolenId)?.Home == peerHome)
                {
                    ForgetDisplay(stolenId);
                    _pendingTakes.Remove(stolenId);
                    RemoteLeases.Remove(stolenId);
                    RemoteTranscripts.Remove(stolenId);
                    RemoteViewDisplaced?.Invoke(stolenId);
                    Changed?.Invoke();
                }
                break;
            case DeviceKind.TranscriptSnapshot:
                if (envelope.Payload is null) break;
                var transcript = DeviceJson.Decode<DeviceTranscriptPayload>(envelope.Payload);
                if (DeviceGlobalID.Parse(transcript.GlobalID)?.Home != peerHome) break;
                if (transcript.Epoch is null || RemoteLeases.GetValueOrDefault(transcript.GlobalID) != transcript.Epoch) break;
                if (RemoteTranscripts.TryGetValue(transcript.GlobalID, out var existing) && transcript.HomeSeq <= existing.HomeSeq) break;
                RemoteTranscripts[transcript.GlobalID] = existing is not null && transcript.Prepend
                    ? MergePrepend(existing, transcript) : transcript;
                _drafts.AdoptIfNewer(transcript.GlobalID, transcript.DraftVersion, transcript.Draft);
                RemoteOffline.Remove(transcript.GlobalID);
                Changed?.Invoke();
                break;
            case DeviceKind.TranscriptRequest:
                if (HomeSession(envelope) is { } paged && envelope.Payload is not null && await RequireLeaseAsync(peer, envelope, paged))
                    await SendTranscriptAsync(peer, paged, DeviceJson.Decode<DeviceTranscriptRequest>(envelope.Payload).BeforeOffset);
                break;
            case DeviceKind.DraftPatch:
                if (HomeSession(envelope) is { } drafted && envelope.Payload is not null)
                {
                    if (!await RequireLeaseAsync(peer, envelope, drafted)) break;
                    var draft = DeviceJson.Decode<DeviceDraftPayload>(envelope.Payload);
                    var hashes = draft.ImageHashes ?? Array.Empty<string>();
                    if (!hashes.All(h => _blobPaths.TryGetValue(h, out var path) && File.Exists(path))) break;
                    if (_drafts.Apply(drafted.Id.ToString("D"), draft.Version, draft.Text))
                    {
                        drafted.Draft = draft.Text;
                        drafted.Attachments = hashes.Select(h => _blobPaths[h]).ToList();
                        _store.Save();
                    }
                }
                break;
            case DeviceKind.Command:
                await ExecuteHomeCommandAsync(peer, envelope);
                break;
            case DeviceKind.CommandQuery:
                if (envelope.CommandID is { } queryId)
                {
                    if (_commands.Records.TryGetValue(queryId, out var record) &&
                        (record.Origin != peerHome || record.SessionID != envelope.SessionID)) break;
                    await SendAckAsync(peer, queryId, envelope.SessionID, _commands.Outcome(queryId) ?? "rejected", "Home record lookup.", envelope.Epoch);
                }
                break;
            case DeviceKind.CommandAck:
                if (envelope.CommandID is { } ackId && envelope.SessionID is { } ackSession &&
                    DeviceGlobalID.Parse(ackSession)?.Home == peerHome && envelope.Payload is not null)
                {
                    if (AckReceivedForTest is { } observe) observe(ackId, DeviceJson.Decode<DeviceAckPayload>(envelope.Payload));
                    var record = _outbox.Records.FirstOrDefault(r => r.CommandID == ackId);
                    if (record is null || record.SessionID != ackSession) break;
                    if (envelope.Epoch is null || (envelope.Epoch != record.Epoch && RemoteLeases.GetValueOrDefault(ackSession) != envelope.Epoch)) break;
                    var ack = DeviceJson.Decode<DeviceAckPayload>(envelope.Payload);
                    _outbox.Resolve(ackId, ack.Outcome, ack.Detail);
                    Changed?.Invoke();
                }
                break;
            case DeviceKind.BlobChunk:
            case DeviceKind.BlobOffer:
                if (HomeSession(envelope) is { } blobSession && envelope.Payload is not null && await RequireLeaseAsync(peer, envelope, blobSession))
                {
                    var blob = DeviceJson.Decode<DeviceBlobPayload>(envelope.Payload);
                    if (envelope.Kind == DeviceKind.BlobOffer)
                    {
                        var stored = _blobPaths.TryGetValue(blob.Sha256Hex, out var existingPath) && File.Exists(existingPath);
                        await SendBlobAckAsync(peer, envelope, blob.Sha256Hex, stored);
                        break;
                    }
                    if (blob.Chunk is not null)
                    {
                        if (!_staged.TryGetValue(blob.Sha256Hex, out var staged))
                        {
                            if (!TryBeginExternalWork()) { await SendBlobAckAsync(peer, envelope, blob.Sha256Hex, false); break; }
                            staged = new List<byte>(); _staged[blob.Sha256Hex] = staged; _guardedBlobs.Add(blob.Sha256Hex);
                        }
                        staged.AddRange(blob.Chunk);
                        if (staged.Count > DeviceBlob.MaxBlob) { _staged.Remove(blob.Sha256Hex); ReleaseBlobGuard(blob.Sha256Hex); await SendBlobAckAsync(peer, envelope, blob.Sha256Hex, false); break; }
                    }
                    if (blob.Done)
                    {
                        var bytes = _staged.GetValueOrDefault(blob.Sha256Hex)?.ToArray() ?? Array.Empty<byte>();
                        _staged.Remove(blob.Sha256Hex); ReleaseBlobGuard(blob.Sha256Hex);
                        if (!DeviceBlob.Verify(bytes, blob.Sha256Hex)) { await SendBlobAckAsync(peer, envelope, blob.Sha256Hex, false); break; }
                        var dir = Path.Combine(_folder, "Attachments", blobSession.Id.ToString("D"));
                        Directory.CreateDirectory(dir);
                        var file = Path.Combine(dir, "Remote-" + blob.Sha256Hex[..16] + ".png");
                        await File.WriteAllBytesAsync(file, bytes);
                        _blobPaths[blob.Sha256Hex] = file;
                        await SendBlobAckAsync(peer, envelope, blob.Sha256Hex, true);
                    }
                }
                break;
            case DeviceKind.BlobAck:
                // BlobAck detail is "hash|message" (see SendBlobAckAsync);
                // correlate upload waits by hash.
                if (envelope.Payload is not null)
                {
                    var blobAck = DeviceJson.Decode<DeviceAckPayload>(envelope.Payload);
                    var pipe = (blobAck.Detail ?? "").IndexOf('|');
                    var hash = pipe < 0 ? blobAck.Detail ?? "" : blobAck.Detail![..pipe];
                    lock (_blobAcks)
                    {
                        if (_blobAcks.TryGetValue(hash, out var waiter))
                        {
                            _blobAcks.Remove(hash);
                            waiter.TrySetResult(blobAck.Outcome == "stored");
                        }
                    }
                }
                Changed?.Invoke();
                break;
            case DeviceKind.BlobData:
                if (envelope.Payload is null) break;
                var data = DeviceJson.Decode<DeviceBlobPayload>(envelope.Payload);
                if (data.Chunk is not null)
                {
                    if (!_staged.TryGetValue(data.Sha256Hex, out var pending)) { pending = new List<byte>(); _staged[data.Sha256Hex] = pending; }
                    pending.AddRange(data.Chunk);
                    if (pending.Count > DeviceBlob.MaxBlob) _staged.Remove(data.Sha256Hex);
                }
                if (data.Done)
                {
                    string? stored = null;
                    var bytes = _staged.GetValueOrDefault(data.Sha256Hex)?.ToArray() ?? Array.Empty<byte>();
                    _staged.Remove(data.Sha256Hex);
                    if (DeviceBlob.Verify(bytes, data.Sha256Hex))
                    {
                        var dir = Path.Combine(_folder, "Attachments", "Downloads");
                        try
                        {
                            Directory.CreateDirectory(dir);
                            var file = Path.Combine(dir, "Remote-" + data.Sha256Hex[..16] + ".png");
                            await File.WriteAllBytesAsync(file, bytes);
                            _blobPaths[data.Sha256Hex] = file;
                            stored = file;
                        }
                        catch { /* disk failure resolves the waiter null below */ }
                    }
                    lock (_blobDownloads)
                    {
                        if (_blobDownloads.TryGetValue(data.Sha256Hex, out var waiter))
                        {
                            _blobDownloads.Remove(data.Sha256Hex);
                            waiter.TrySetResult(stored);
                        }
                    }
                    Changed?.Invoke();
                }
                break;
            case DeviceKind.BlobRequest:
                if (HomeSession(envelope) is { } downloadSession && envelope.Payload is not null && await RequireLeaseAsync(peer, envelope, downloadSession))
                {
                    var request = DeviceJson.Decode<DeviceBlobPayload>(envelope.Payload);
                    if (_blobPaths.TryGetValue(request.Sha256Hex, out var path) && File.Exists(path))
                    {
                        var bytes = await File.ReadAllBytesAsync(path);
                        for (var offset = 0; offset < bytes.Length || (offset == 0 && bytes.Length == 0); offset += 32_768)
                        {
                            var chunk = bytes.AsSpan(offset, Math.Min(32_768, Math.Max(0, bytes.Length - offset))).ToArray();
                            await SendEnvelopeAsync(peer, new DeviceEnvelope
                            {
                                Kind = DeviceKind.BlobData, SessionID = envelope.SessionID, Epoch = envelope.Epoch,
                                Payload = DeviceJson.Encode(new DeviceBlobPayload { Sha256Hex = request.Sha256Hex, Size = bytes.Length, Chunk = chunk, Done = offset + chunk.Length >= bytes.Length }),
                            });
                            if (bytes.Length == 0) break;
                        }
                    }
                }
                break;
        }
    }

    private async Task SendBlobAckAsync(Peer peer, DeviceEnvelope envelope, string hash, bool stored) =>
        await SendEnvelopeAsync(peer, new DeviceEnvelope
        {
            Kind = DeviceKind.BlobAck, SessionID = envelope.SessionID, Epoch = envelope.Epoch,
            Payload = DeviceJson.Encode(new DeviceAckPayload { Outcome = stored ? "stored" : "failed", Detail = hash + "|" + (stored ? "Stored on home." : "Not stored on home.") }),
        });

    // Merges an earlier page ahead of the retained transcript. Message IDs
    // dedupe (a repeated page changes nothing); fresh home fields (draft,
    // status, options) come from the page, which carries the newest homeSeq.
    internal static DeviceTranscriptPayload MergePrepend(DeviceTranscriptPayload existing, DeviceTranscriptPayload paged)
    {
        var seen = new HashSet<Guid>(paged.Messages.Select(m => m.Id));
        var merged = new List<DeviceWireMessage>(paged.Messages);
        merged.AddRange(existing.Messages.Where(m => !seen.Contains(m.Id)));
        paged.Messages = merged;
        paged.Total = Math.Max(paged.Total, existing.Total);
        return paged;
    }

    // ---- Viewer side ----
    private Peer? PeerForHome(string home) =>
        _peers.Values.FirstOrDefault(p => p.TrustedReady && !p.ControlOnly && p.Hello?.DeviceID == home
            && Homes.GetValueOrDefault(home)?.Online == true && IsGroupMember(home));

    private void SaveResumeEpochs()
    {
        try
        {
            var file = Path.Combine(_folder, "display-resume.json");
            var temporary = file + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(_resumeEpochs));
            File.Move(temporary, file, true);
        }
        catch { LastOutcome = "Could not save display restore state. Take manually after restarting."; }
    }
    private void RememberDisplay(string id, ulong epoch) { _resumeEpochs[id] = epoch; SaveResumeEpochs(); }
    private void ForgetDisplay(string id) { if (_resumeEpochs.Remove(id)) SaveResumeEpochs(); }
    public async Task RestoreAvailableDisplaysAsync()
    {
        foreach (var (id, epoch) in _resumeEpochs.ToList())
        {
            if (IsViewerPlaced?.Invoke(id) != true || RemoteLeases.ContainsKey(id) || _pendingTakes.ContainsKey(id) ||
                DeviceGlobalID.Parse(id) is not { } global || PeerForHome(global.Home) is not { } peer ||
                !peer.Hello!.Capabilities.Contains("lease-resume-v1")) continue;
            RemoteTranscripts.Remove(id);
            _pendingTakes[id] = DateTime.UtcNow;
            await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.LeaseResume, SessionID = id, Epoch = epoch });
        }
    }

    public async Task AcquireRemoteAsync(string globalId)
    {
        var parsed = DeviceGlobalID.Parse(globalId);
        if (parsed is null || PeerForHome(parsed.Value.Home) is not { } peer) { LastOutcome = "Home is offline."; return; }
        if (_pendingTakes.ContainsKey(globalId) || RemoteLeases.ContainsKey(globalId)) return;
        RemoteTranscripts.Remove(globalId);
        _pendingTakes[globalId] = DateTime.UtcNow;
        await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.LeaseAcquire, SessionID = globalId });
    }

    public async Task ReleaseRemoteAsync(string globalId)
    {
        ForgetDisplay(globalId);
        _pendingTakes.Remove(globalId);
        if (DeviceGlobalID.Parse(globalId) is { } parsed && RemoteLeases.TryGetValue(globalId, out var epoch) &&
            PeerForHome(parsed.Home) is { } peer)
            await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.LeaseRelease, SessionID = globalId, Epoch = epoch });
        RemoteLeases.Remove(globalId);
    }

    private static readonly HashSet<string> QueueActions = new() { "inject", "injectAll", "pauseQueue", "resumeQueue", "clearQueue", "removeQueued" };
    public const string QueueRemoveCapability = "queue-remove-v1";
    public bool CanRemoveQueuedRemote(string globalId) =>
        DeviceGlobalID.Parse(globalId) is { } id && PeerForHome(id.Home)?.Hello?.Capabilities.Contains(QueueRemoveCapability) == true;

    // Mac parity: the outstanding queue intent feeds the Injecting label and
    // the double-press guard below. Falls back to the newest queue record so
    // failed/completed feedback stays visible until discarded.
    public DeviceOutboxRecord? QueueCommand(string globalId)
    {
        var records = _outbox.Records
            .Where(r => r.SessionID == globalId && QueueActions.Contains(r.Payload.Action)).ToList();
        return records.FirstOrDefault(r => r.Outcome is "pending" or "accepted" or "uncertain")
            ?? records.LastOrDefault();
    }

    public async Task<Guid?> SendRemoteCommandAsync(string globalId, DeviceCommandPayload command)
    {
        if (RemoteTranscripts.GetValueOrDefault(globalId)?.Engine == "parking" || Homes.Values.SelectMany(h => h.Rows).Any(r => r.GlobalID == globalId && r.Engine == "parking"))
        { LastOutcome = "Parking Lots are read only on Group viewers."; return null; }
        // Older homes only know Clear queue; never send them a single removal.
        if (command.Action == "removeQueued" && !CanRemoveQueuedRemote(globalId))
        { LastOutcome = "Update the home device to remove one queued message."; return null; }
        var parsed = DeviceGlobalID.Parse(globalId);
        if (parsed is null || !RemoteLeases.TryGetValue(globalId, out var epoch) || PeerForHome(parsed.Value.Home) is not { } peer)
        { LastOutcome = "Take the session again before sending."; return null; }
        // A double press is the same outstanding queue intent, not a second
        // interrupt. Uncertain requests need Check home before retrying.
        if (QueueActions.Contains(command.Action) && QueueCommand(globalId) is { } active
            && active.Outcome is "pending" or "accepted" or "uncertain")
        {
            LastOutcome = "Queue request already pending. Check home for its result.";
            return active.Payload.Action == command.Action && active.Payload.PendingID == command.PendingID
                ? active.CommandID : null;
        }
        var payloadData = DeviceJson.Encode(command);
        var record = new DeviceOutboxRecord
        { CommandID = Guid.NewGuid(), SessionID = globalId, Payload = command, PayloadHash = DeviceBlob.Sha256Hex(payloadData), Epoch = epoch };
        _outbox.Add(record);
        Changed?.Invoke();
        await SendEnvelopeAsync(peer, new DeviceEnvelope
        { Kind = DeviceKind.Command, SessionID = globalId, CommandID = record.CommandID, Epoch = epoch, Payload = payloadData });
        return record.CommandID;
    }

    // Composer submission includes its latest keystroke, even when the UI's
    // throttled draft patch has not fired. Independent command submissions
    // retain their existing semantics and do not consume unrelated drafts.
    public async Task<Guid?> SendRemoteComposerAsync(string globalId, string text, string[] hashes)
    {
        await SendRemoteDraftAsync(globalId, text);
        return await SendRemoteCommandAsync(globalId,
            new DeviceCommandPayload { Action = "submit", Text = text, BlobHashes = hashes });
    }

    public async Task SendRemoteDraftAsync(string globalId, string text)
    {
        var parsed = DeviceGlobalID.Parse(globalId);
        if (parsed is null || !RemoteLeases.TryGetValue(globalId, out var epoch) || PeerForHome(parsed.Value.Home) is not { } peer) return;
        var version = _drafts.Bump(globalId, text);
        await SendEnvelopeAsync(peer, new DeviceEnvelope
        {
            Kind = DeviceKind.DraftPatch, SessionID = globalId, Epoch = epoch,
            Payload = DeviceJson.Encode(new DeviceDraftPayload { Version = version, Text = text, ImageHashes = Array.Empty<string>() }),
        });
    }

    public List<DeviceOutboxRecord> Unresolved(string globalId) =>
        _outbox.Records.Where(r => r.SessionID == globalId).ToList();

    // Mac Workspace.shared.park parity: the UI parks a local session whose
    // display lease is held by another device (one active display each).
    public (string Device, ulong Epoch)? DisplayHolder(Guid sessionId) => _leases.Holder(sessionId);

    // Clicking a home pane number is a take, just like a remote lease.acquire.
    // Fence the old holder before exposing the local editor, then park its view.
    public async Task<bool> AcquireLocalAsync(Guid sessionId)
    {
        if (!_store.Sessions.Any(s => s.Id == sessionId)) return false;
        var holder = _leases.Holder(sessionId);
        // A local take must fence offline viewers too, not just live holders.
        if (holder?.Device == DeviceId) return true;
        var result = _leases.Acquire(sessionId, DeviceId);
        if (!result.Granted) { LastOutcome = "Could not record local display fence."; return false; }
        DisplayLeaseGranted?.Invoke(sessionId, DeviceId, result.Epoch);
        foreach (var old in _peers.Values.Where(p => p.Hello?.DeviceID == result.Displaced).ToArray())
        {
            old.LeasedSessions.Remove(sessionId);
            await SendEnvelopeAsync(old, new DeviceEnvelope
            {
                Kind = DeviceKind.LeaseStolen, Boot = _boot,
                SessionID = new DeviceGlobalID(DeviceId, sessionId).ToString(), Epoch = result.Epoch,
            });
        }
        PublishSidebars();
        Changed?.Invoke();
        return true;
    }

    // Mac parity: page earlier messages ahead of the retained transcript.
    public async Task RequestEarlierAsync(string globalId)
    {
        var parsed = DeviceGlobalID.Parse(globalId);
        if (parsed is null || !RemoteLeases.TryGetValue(globalId, out var epoch) || PeerForHome(parsed.Value.Home) is not { } peer)
        { LastOutcome = "Take the session again before loading earlier messages."; return; }
        var offset = RemoteTranscripts.GetValueOrDefault(globalId)?.Offset ?? 0;
        if (offset <= 0) return;
        await SendEnvelopeAsync(peer, new DeviceEnvelope
        {
            Kind = DeviceKind.TranscriptRequest, SessionID = globalId, Epoch = epoch,
            Payload = DeviceJson.Encode(new DeviceTranscriptRequest { BeforeOffset = offset }),
        });
    }

    // Mac parity outbox recovery: ask home for the authoritative outcome of
    // an uncertain command, drop a record the user discards, or resend the
    // identical command under its original ID (home dedups replays).
    public async Task QueryOutboxAsync(DeviceOutboxRecord record)
    {
        var parsed = DeviceGlobalID.Parse(record.SessionID);
        if (parsed is null || PeerForHome(parsed.Value.Home) is not { } peer)
        { LastOutcome = "Home is offline."; return; }
        await SendEnvelopeAsync(peer, new DeviceEnvelope
        { Kind = DeviceKind.CommandQuery, SessionID = record.SessionID, CommandID = record.CommandID, Epoch = record.Epoch });
    }

    public void DiscardOutbox(Guid commandId)
    {
        _outbox.Remove(commandId);
        Changed?.Invoke();
    }

    public async Task<bool> RetryOutboxAsync(DeviceOutboxRecord record)
    {
        var parsed = DeviceGlobalID.Parse(record.SessionID);
        if (parsed is null || !RemoteLeases.TryGetValue(record.SessionID, out var epoch) || PeerForHome(parsed.Value.Home) is not { } peer)
        { LastOutcome = "Take the session again before resending."; return false; }
        _outbox.Requeue(record.CommandID, epoch);
        Changed?.Invoke();
        await SendEnvelopeAsync(peer, new DeviceEnvelope
        {
            Kind = DeviceKind.Command, SessionID = record.SessionID, CommandID = record.CommandID,
            Epoch = epoch, Payload = DeviceJson.Encode(record.Payload),
        });
        return true;
    }

    // Uploads attachment bytes to home, short-circuiting when home already
    // stores the hash. Returns the content hash, or null on failure/timeout.
    public async Task<string?> UploadBlobAsync(string globalId, byte[] data)
    {
        var parsed = DeviceGlobalID.Parse(globalId);
        if (parsed is null || !RemoteLeases.TryGetValue(globalId, out var epoch) || PeerForHome(parsed.Value.Home) is not { } peer)
        { LastOutcome = "Take the session again before attaching."; return null; }
        if (data.Length > DeviceBlob.MaxBlob) { LastOutcome = "Attachment exceeds the 25 MB limit."; return null; }
        var hash = DeviceBlob.Sha256Hex(data);
        // Preserve a local preview of an outgoing remote attachment, too.
        var previewPath = Path.Combine(_folder, "device-blobs", hash);
        Directory.CreateDirectory(Path.GetDirectoryName(previewPath)!);
        await File.WriteAllBytesAsync(previewPath, data);
        _blobPaths[hash] = previewPath;
        TaskCompletionSource<bool> waiter;
        lock (_blobAcks) { waiter = new TaskCompletionSource<bool>(); _blobAcks[hash] = waiter; }
        await SendEnvelopeAsync(peer, new DeviceEnvelope
        {
            Kind = DeviceKind.BlobOffer, SessionID = globalId, Epoch = epoch,
            Payload = DeviceJson.Encode(new DeviceBlobPayload { Sha256Hex = hash, Size = data.Length }),
        });
        // The offer ack reports whether home already stores the hash: stored
        // short-circuits, "failed" means home needs the bytes (not refusal).
        var offered = await WaitBlobAckAsync(hash, waiter, required: false);
        if (offered is null) return null;
        if (offered == true) return hash;
        // Re-register: a second ack follows the chunk stream.
        lock (_blobAcks) { waiter = new TaskCompletionSource<bool>(); _blobAcks[hash] = waiter; }
        if (data.Length == 0)
        {
            await SendEnvelopeAsync(peer, new DeviceEnvelope
            {
                Kind = DeviceKind.BlobChunk, SessionID = globalId, Epoch = epoch,
                Payload = DeviceJson.Encode(new DeviceBlobPayload { Sha256Hex = hash, Done = true }),
            });
        }
        else
        {
            for (var offset = 0; offset < data.Length; offset += 32_768)
            {
                var chunk = data.AsSpan(offset, Math.Min(32_768, data.Length - offset)).ToArray();
                await SendEnvelopeAsync(peer, new DeviceEnvelope
                {
                    Kind = DeviceKind.BlobChunk, SessionID = globalId, Epoch = epoch,
                    Payload = DeviceJson.Encode(new DeviceBlobPayload
                    { Sha256Hex = hash, Size = data.Length, Chunk = chunk, Done = offset + chunk.Length >= data.Length }),
                });
            }
        }
        return await WaitBlobAckAsync(hash, waiter, required: true) == true ? hash : null;
    }

    // Fetches home bytes for a transcript image hash the viewer lacks,
    // short-circuiting the local blob cache. Concurrent requests for one
    // hash share a waiter. Returns the stored path, or null when the
    // lease is gone, home lacks it, or the bytes time out.
    public string? BlobPath(string hash) =>
        _blobPaths.TryGetValue(hash, out var path) && File.Exists(path) ? path : null;

    public async Task<string?> DownloadBlobAsync(string globalId, string hash)
    {
        if (BlobPath(hash) is { } cached) return cached;
        var parsed = DeviceGlobalID.Parse(globalId);
        if (parsed is null || !RemoteLeases.TryGetValue(globalId, out var epoch) || PeerForHome(parsed.Value.Home) is not { } peer)
            return null;
        TaskCompletionSource<string?> waiter;
        bool mine;
        lock (_blobDownloads)
        {
            mine = !_blobDownloads.TryGetValue(hash, out waiter!);
            if (mine) { waiter = new TaskCompletionSource<string?>(); _blobDownloads[hash] = waiter; }
        }
        if (mine)
            await SendEnvelopeAsync(peer, new DeviceEnvelope
            {
                Kind = DeviceKind.BlobRequest, SessionID = globalId, Epoch = epoch,
                Payload = DeviceJson.Encode(new DeviceBlobPayload { Sha256Hex = hash }),
            });
        var timeout = Task.Delay(TimeSpan.FromSeconds(60));
        if (await Task.WhenAny(waiter.Task, timeout) != waiter.Task) return null;
        var stored = await waiter.Task;
        return stored is not null && File.Exists(stored) ? stored : null;
    }

    // Returns the stored flag, or null on timeout. Only the final ack treats
    // "not stored" as a failure; the offer ack uses it to request bytes.
    private async Task<bool?> WaitBlobAckAsync(string hash, TaskCompletionSource<bool> waiter, bool required)
    {
        var timeout = Task.Delay(TimeSpan.FromSeconds(60));
        if (await Task.WhenAny(waiter.Task, timeout) != waiter.Task)
        {
            lock (_blobAcks) _blobAcks.Remove(hash);
            LastOutcome = "Attachment upload timed out.";
            return null;
        }
        var stored = await waiter.Task;
        if (!stored && required) LastOutcome = "Home refused the attachment.";
        return stored;
    }
}

