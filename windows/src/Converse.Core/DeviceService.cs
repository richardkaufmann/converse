using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text;
using System.Text.Json.Serialization;
using System.Collections.Concurrent;

namespace Converse.Core;

// Pairwise device sync mirroring DeviceTransport/DeviceIdentity/DeviceSync.
// Home-authoritative sessions, one fenced display lease per session,
// durable command dedup with honest uncertain recovery.
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
    [property: JsonPropertyName("metadataBy")] string? MetadataBy = null);

// Same versioned membership records as Swift. Authentication of the sender
// grants fabric-administration authority; records are never accepted pre-trust.
public sealed class DeviceTrustStore
{
    private readonly string _file;
    private readonly object _gate = new();
    private List<TrustedDevice> _records = new();
    public List<TrustedDevice> Records { get { lock (_gate) return _records.ToList(); } }
    public List<TrustedDevice> Devices { get { lock (_gate) return _records.Where(d => d.Removed != true).ToList(); } }
    public DeviceTrustStore(string folder)
    {
        Directory.CreateDirectory(folder); _file = Path.Combine(folder, "devices.json");
        if (File.Exists(_file)) _records = JsonSerializer.Deserialize<List<TrustedDevice>>(File.ReadAllBytes(_file), new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new InvalidDataException("Invalid trust store");
        _records = _records.Select(d => d with { Name = BoundedName(d.Name) }).ToList();
    }
    public string Check(string id, byte[] key)
    {
        var device = Devices.FirstOrDefault(d => d.DeviceID == id);
        return device is null ? "unknown" : device.PublicKey.AsSpan().SequenceEqual(key) ? "trusted" : "keyChanged";
    }
    private ulong NextGeneration()
    {
        var highest = _records.Select(d => d.Generation ?? 0).DefaultIfEmpty().Max();
        if (highest >= ulong.MaxValue - 2) throw new InvalidDataException("Membership counter exhausted");
        return highest + 1;
    }
    public static string BoundedName(string name)
    {
        var result = new System.Text.StringBuilder(); var bytes = 0;
        foreach (var rune in name.EnumerateRunes()) { if (bytes + rune.Utf8SequenceLength > 200) break; result.Append(rune.ToString()); bytes += rune.Utf8SequenceLength; }
        return result.ToString();
    }
    public void Pin(TrustedDevice device, string? issuer = null, bool allowAdmission = true)
    {
        lock (_gate)
        {
            device = device with { Name = BoundedName(device.Name) };
            var old = _records.FirstOrDefault(d => d.DeviceID == device.DeviceID);
            var active = old is not null && old.Removed != true && old.PublicKey.AsSpan().SequenceEqual(device.PublicKey);
            if (!active && !allowAdmission) throw new InvalidDataException("Fresh human admission required");
            if (active && old!.Name == device.Name && (device.LastHost is null || old.LastHost == device.LastHost) && (device.LastPort is null || old.LastPort == device.LastPort)) return;
            if ((old?.MetadataGeneration ?? 0) >= ulong.MaxValue - 2) throw new InvalidDataException("Metadata counter exhausted");
            var pairedAt = active && old!.PairedAt > 0 ? old.PairedAt : (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 - 978307200);
            var member = device with {
                Generation = active ? old!.Generation : NextGeneration(),
                ChangedBy = active ? old!.ChangedBy : issuer ?? device.DeviceID,
                Removed = false, PairedAt = pairedAt,
                LastHost = device.LastHost ?? old?.LastHost, LastPort = device.LastPort ?? old?.LastPort,
                MetadataGeneration = checked((old?.MetadataGeneration ?? 0) + 1), MetadataBy = issuer ?? device.DeviceID
            };
            var next = _records.Where(d => d.DeviceID != device.DeviceID).Append(member).ToList();
            if (next.Count > 512) throw new InvalidDataException("Fabric roster limit");
            AtomicJson.Write(_file, next); _records = next;
        }
    }
    public void Forget(string id, string? issuer = null)
    {
        lock (_gate)
        {
            var old = _records.FirstOrDefault(d => d.DeviceID == id); if (old is null) return;
            var next = _records.Where(d => d.DeviceID != id).Append(old with { Generation = NextGeneration(), ChangedBy = issuer ?? id, Removed = true }).ToList();
            AtomicJson.Write(_file, next); _records = next;
        }
    }
    public bool Merge(IReadOnlyList<TrustedDevice> incoming)
    {
        lock (_gate)
        {
            if (incoming.Count > 512 || incoming.Any(d => d.PublicKey.Length != 32 || DeviceBlob.DeviceIdForPublicKey(d.PublicKey) != d.DeviceID || System.Text.Encoding.UTF8.GetByteCount(d.Name) > 200 || (d.MetadataBy?.Length ?? 0) > 64 || (d.MetadataGeneration ?? 0) >= ulong.MaxValue - 1 || (d.ChangedBy?.Length ?? 0) > 64 || (d.LastHost?.Length ?? 0) > 253 || d.LastPort is < 1 or > 65535 || (d.Generation ?? 0) >= ulong.MaxValue - 1)) throw new InvalidDataException("Invalid membership");
            var next = _records.ToList(); var changed = false;
            foreach (var member in incoming)
            {
                var index = next.FindIndex(d => d.DeviceID == member.DeviceID);
                if (index < 0) { next.Add(member); changed = true; continue; }
                var old = next[index];
                var newer = (member.Generation ?? 0) > (old.Generation ?? 0)
                    || ((member.Generation ?? 0) == (old.Generation ?? 0) && ((member.Removed == true && old.Removed != true)
                    || ((member.Removed == true) == (old.Removed == true) && string.CompareOrdinal(member.ChangedBy ?? "", old.ChangedBy ?? "") > 0)));
                if (newer) { next[index] = member; changed = true; }
                else if ((member.Generation ?? 0) == (old.Generation ?? 0) && (member.Removed == true) == (old.Removed == true) && (member.ChangedBy ?? "") == (old.ChangedBy ?? "") && old.PublicKey.AsSpan().SequenceEqual(member.PublicKey)
                    && ((member.MetadataGeneration ?? 0) > (old.MetadataGeneration ?? 0) || ((member.MetadataGeneration ?? 0) == (old.MetadataGeneration ?? 0) && string.CompareOrdinal(member.MetadataBy ?? "", old.MetadataBy ?? "") > 0)))
                {
                    next[index] = old with { Name = member.Name, LastHost = member.LastHost, LastPort = member.LastPort, MetadataGeneration = member.MetadataGeneration, MetadataBy = member.MetadataBy };
                    changed = true;
                }
            }
            if (next.Count > 512) throw new InvalidDataException("Fabric roster limit");
            if (!changed) return false;
            AtomicJson.Write(_file, next); _records = next; return true;
        }
    }
}

public sealed record PairingPrompt(string PeerName, string Fingerprint, string Code, bool KeyChanged, bool IsInitiator = false);

public sealed class RemoteHomeState
{
    public string DeviceID { get; set; } = "";
    public string DeviceName { get; set; } = "";
    public bool Online { get; set; }
    public List<DeviceSidebarRow> Rows { get; set; } = new();
}

internal sealed class Peer
{
    public required TcpClient Client { get; init; }
    public required bool IsInitiator { get; init; }
    public DeviceHandshake? Handshake { get; set; }
    public DeviceTransportKeys? Keys { get; set; }
    public DeviceHello? Hello { get; set; }
    public DeviceFrameDecoder Decoder { get; } = new();
    public List<byte> Buffer { get; } = new();
    public volatile bool Alive = true;
    public bool TrustedReady { get; set; }
    public bool HumanConfirmed { get; set; }
    public bool LocalConfirmed { get; set; }
    public bool RemoteConfirmed { get; set; }
    public HashSet<Guid> LeasedSessions { get; } = new();
    public string? ManualHost { get; init; }
    public int? ManualPort { get; init; }
    public readonly SemaphoreSlim SendLock = new(1, 1);
}

public sealed class DeviceSyncService : IDisposable
{
    public const int DefaultPort = 48721;
    public string DeviceId { get; }
    public string DeviceName { get; }
    public DeviceTrustStore Trust { get; }
    public ConcurrentDictionary<string, RemoteHomeState> Homes { get; } = new();
    public Dictionary<string, ulong> RemoteLeases { get; } = new();
    public Dictionary<string, DeviceTranscriptPayload> RemoteTranscripts { get; } = new();
    public HashSet<string> RemoteOffline { get; } = new();
    public string LastOutcome { get; private set; } = "";
    public int ListeningPort { get; private set; }
    public event Action? Changed;
    public Func<PairingPrompt, Task<bool>>? PairingConfirmation { get; set; }

    private readonly byte[] _staticPrivate;
    private readonly SessionStore _store;
    private readonly string _folder;
    private readonly DeviceCommandStore _commands;
    private readonly DeviceOutboxStore _outbox;
    private readonly DeviceLeaseManager _leases;
    private readonly DeviceDraftTracker _drafts = new();
    private readonly ConcurrentDictionary<Guid, Peer> _peers = new();
    private readonly Dictionary<string, string> _blobPaths = new();
    private readonly Dictionary<string, List<byte>> _staged = new();
    private readonly Dictionary<string, DateTime> _pendingTakes = new();
    private readonly SemaphoreSlim _pairingQueue = new(1, 1);
    private readonly ConcurrentDictionary<string, byte> _connecting = new();
    private readonly object _fabricGate = new();
    private ulong _homeSeq;
    private ulong _boot = 1;
    public List<MdnsService> DiscoveredDevices { get; } = new();
    private MdnsDiscovery? _mdns;
    private TcpListener? _listener;
    private CancellationTokenSource? _shutdown;

    public DeviceSyncService(string folder, SessionStore store, string? deviceName = null)
    {
        _folder = folder;
        _store = store;
        Directory.CreateDirectory(folder);
        var keyFile = Path.Combine(folder, "device-key.bin");
        // Core keeps plain test storage; the app must DPAPI-protect this file.
        _staticPrivate = File.Exists(keyFile) ? File.ReadAllBytes(keyFile) : CreateKeyFile(keyFile);
        DeviceId = DeviceBlob.DeviceIdForPublicKey(X25519.PublicKeyFromPrivate(_staticPrivate));
        DeviceName = deviceName ?? Environment.MachineName;
        Trust = new DeviceTrustStore(folder);
        _commands = new DeviceCommandStore(folder);
        _outbox = new DeviceOutboxStore(folder);
        _leases = new DeviceLeaseManager();
        foreach (var device in Trust.Devices.Where(d => d.DeviceID != DeviceId))
            Homes[device.DeviceID] = new RemoteHomeState { DeviceID = device.DeviceID, DeviceName = device.Name };
        _store.Changed += PublishSidebars;
    }

    private static byte[] CreateKeyFile(string keyFile)
    {
        var (priv, _) = X25519.GenerateKeyPair();
        File.WriteAllBytes(keyFile, priv);
        return priv;
    }

    public IReadOnlyList<DeviceOutboxRecord> Outbox => _outbox.Records;

    public async Task StartAsync(int port = DefaultPort)
    {
        _shutdown = new CancellationTokenSource();
        _listener = new TcpListener(IPAddress.Any, port);
        _listener.Start();
        ListeningPort = ((IPEndPoint)_listener.LocalEndpoint).Port;
        try
        {
            _mdns = new MdnsDiscovery(DeviceName + " [" + DeviceId[..8] + "]", ListeningPort);
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
        _ = ReconnectFabricAsync();
        await Task.CompletedTask;
    }

    public void Dispose()
    {
        _shutdown?.Cancel();
        _mdns?.Dispose();
        _listener?.Stop();
        foreach (var peer in _peers.Values.ToList()) peer.Client.Dispose();
    }

    public async Task ConnectManualAsync(string host, int port)
    {
        if (port is < 1 or > 65535) { LastOutcome = "Port must be between 1 and 65535."; return; }
        var client = new TcpClient();
        await client.ConnectAsync(host, port);
        var peer = new Peer { Client = client, IsInitiator = true, ManualHost = host, ManualPort = port };
        peer.Handshake = new DeviceHandshake(true, _staticPrivate);
        _peers[Guid.NewGuid()] = peer;
        await SendRawAsync(peer, peer.Handshake.WriteMessage(DeviceJson.Encode(Hello())));
        _ = ReceiveLoopAsync(peer);
    }

    public void ForgetDevice(TrustedDevice device)
    {
        Trust.Forget(device.DeviceID, DeviceId);
        Homes.TryRemove(device.DeviceID, out _);
        _ = BroadcastFabricAsync();
        foreach (var peer in _peers.Values.Where(p => p.Hello?.DeviceID == device.DeviceID)) Disconnect(peer);
        Changed?.Invoke();
    }

    private bool LocallyRemoved => Trust.Records.Any(d => d.DeviceID == DeviceId && d.Removed == true);
    private DeviceHello Hello() => new() { DeviceID = DeviceId, DeviceName = DeviceName, ConverseVersion = "0.5.0-windows-dev", ListenPort = ListeningPort };

    private async Task AcceptLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested && _listener is not null)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(token); }
            catch { break; }
            var peer = new Peer { Client = client, IsInitiator = false };
            peer.Handshake = new DeviceHandshake(false, _staticPrivate);
            _peers[Guid.NewGuid()] = peer;
            _ = ReceiveLoopAsync(peer);
        }
    }

    private async Task HeartbeatLoopAsync(CancellationToken token)
    {
        var reconnectTicks = 0;
        while (!token.IsCancellationRequested)
        {
            await Task.Delay(TimeSpan.FromSeconds(5), token).ContinueWith(_ => { });
            if (token.IsCancellationRequested) break;
            if (++reconnectTicks % 6 == 0) _ = ReconnectFabricAsync();
            foreach (var expired in _leases.SweepExpired())
            {
                foreach (var peer in _peers.Values.Where(p => p.Hello?.DeviceID == expired.Device))
                {
                    peer.LeasedSessions.Remove(expired.Session);
                    await SendEnvelopeAsync(peer, new DeviceEnvelope
                    {
                        Kind = DeviceKind.LeaseStolen, Boot = _boot,
                        SessionID = new DeviceGlobalID(DeviceId, expired.Session).ToString(),
                    });
                }
            }
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
        if (message.Length > 65535) { peer.Client.Dispose(); return; }
        var framed = new byte[2 + message.Length];
        framed[0] = (byte)(message.Length >> 8); framed[1] = (byte)message.Length;
        message.CopyTo(framed, 2);
        await peer.SendLock.WaitAsync();
        try { await peer.Client.GetStream().WriteAsync(framed); }
        finally { peer.SendLock.Release(); }
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
                }
                var finished = TryFinish(handshake);
                if (finished is null)
                {
                    await SendRawAsync(peer, handshake.WriteMessage(DeviceJson.Encode(Hello())));
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

    private async Task BeginTrustAsync(Peer peer)
    {
        if (peer.Keys is null || peer.Hello is null) { peer.Client.Dispose(); return; }
        if (peer.Hello.DeviceID == DeviceId || peer.Hello.DeviceID != DeviceBlob.DeviceIdForPublicKey(peer.Keys.RemoteStatic)) { peer.Client.Dispose(); return; }
        lock (_fabricGate)
        {
            var preferInitiator = string.CompareOrdinal(DeviceId, peer.Hello.DeviceID) < 0;
            foreach (var other in _peers.Values.Where(p => p != peer && p.Alive && p.Keys is not null && p.Hello?.DeviceID == peer.Hello.DeviceID).ToList())
            {
                if (other.TrustedReady || (other.IsInitiator == preferInitiator && peer.IsInitiator != preferInitiator)) { Disconnect(peer); return; }
                Disconnect(other);
            }
        }
        var check = Trust.Records.Any(d => d.DeviceID == DeviceId && d.Removed == true) ? "unknown" : Trust.Check(peer.Hello.DeviceID, peer.Keys.RemoteStatic);
        if (check == "trusted")
        {
            peer.LocalConfirmed = true;
            await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.PairConfirm });
            FinishTrust(peer);
            return;
        }
        var prompt = new PairingPrompt(peer.Hello.DeviceName,
            peer.Hello.DeviceID[..Math.Min(16, peer.Hello.DeviceID.Length)].ToUpperInvariant(),
            DeviceSas.Code(peer.Keys.HandshakeHash), check == "keyChanged", peer.IsInitiator);
        bool accepted;
        await _pairingQueue.WaitAsync();
        try { accepted = PairingConfirmation is not null && await PairingConfirmation(prompt); }
        finally { _pairingQueue.Release(); }
        if (!accepted) { peer.Client.Dispose(); return; }
        peer.HumanConfirmed = true; peer.LocalConfirmed = true;
        await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.PairConfirm });
        FinishTrust(peer);
    }

    private void FinishTrust(Peer peer)
    {
        if (!peer.LocalConfirmed || !peer.RemoteConfirmed || peer.TrustedReady || peer.Hello is null || peer.Keys is null) return;
        try
        {
            if (!peer.HumanConfirmed && Trust.Check(peer.Hello.DeviceID, peer.Keys.RemoteStatic) != "trusted") { peer.Client.Dispose(); return; }
            var host = peer.ManualHost ?? (peer.Client.Client.RemoteEndPoint as IPEndPoint)?.Address.ToString();
            Trust.Pin(new TrustedDevice(peer.Hello.DeviceID, peer.Hello.DeviceName, peer.Keys.RemoteStatic, host, peer.Hello.ListenPort ?? peer.ManualPort), DeviceId, allowAdmission: peer.HumanConfirmed);
            // Only a sponsor's fresh human admission may supersede our tombstone.
            if (!Trust.Records.Any(d => d.DeviceID == DeviceId && d.Removed == true))
                Trust.Pin(new TrustedDevice(DeviceId, DeviceName, X25519.PublicKeyFromPrivate(_staticPrivate), null, null), DeviceId);
        }
        catch { LastOutcome = "Could not save paired device. Control not granted."; peer.Client.Dispose(); return; }
        peer.TrustedReady = true;
        Homes[peer.Hello.DeviceID] = new RemoteHomeState
        {
            DeviceID = peer.Hello.DeviceID, DeviceName = peer.Hello.DeviceName, Online = true,
            Rows = Homes.GetValueOrDefault(peer.Hello.DeviceID)?.Rows ?? new(),
        };
        if (!LocallyRemoved) _ = SendSidebarAsync(peer);
        _ = BroadcastFabricAsync();
        Changed?.Invoke();
    }

    private async Task BroadcastFabricAsync()
    {
        var payload = DeviceJson.Encode(Trust.Records);
        foreach (var peer in _peers.Values.Where(p => p.TrustedReady && p.Hello?.Capabilities.Contains("fabric-membership-v1") == true))
            try { await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = "fabric.members", Payload = payload }); } catch { Disconnect(peer); }
    }
    private async Task ReconnectFabricAsync()
    {
        if (_shutdown?.IsCancellationRequested != false || Trust.Records.Any(d => d.DeviceID == DeviceId && d.Removed == true)) return;
        foreach (var device in Trust.Devices.Where(d => d.DeviceID != DeviceId))
        {
            if (_peers.Values.Any(p => p.Hello?.DeviceID == device.DeviceID) || !_connecting.TryAdd(device.DeviceID, 0)) continue;
            try
            {
                MdnsService? found; lock (DiscoveredDevices) found = DiscoveredDevices.FirstOrDefault(d => d.Name.EndsWith("[" + device.DeviceID[..8] + "]") || d.Name == device.Name);
                var host = found?.Host ?? device.LastHost; var port = found?.Port ?? device.LastPort;
                if (host is not null && port is not null) await ConnectManualAsync(host, port.Value);
            }
            catch { /* retry on discovery or subsequent membership exchange */ }
            finally { _connecting.TryRemove(device.DeviceID, out _); }
        }
    }

    private void Disconnect(Peer peer)
    {
        if (!peer.Alive) return;
        peer.Alive = false;
        peer.Client.Dispose();
        var key = _peers.FirstOrDefault(p => p.Value == peer).Key;
        if (key != Guid.Empty) _peers.TryRemove(key, out _);
        if (peer.Hello is { } hello && !_peers.Values.Any(p => p.Alive && p.TrustedReady && p.Hello?.DeviceID == hello.DeviceID))
        {
            if (Homes.TryGetValue(hello.DeviceID, out var home))
            {
                home.Online = false;
                foreach (var row in home.Rows)
                {
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

    internal async Task SendEnvelopeAsync(Peer peer, DeviceEnvelope envelope)
    {
        if (peer.Keys is null) return;
        var framed = DeviceFrame.Encode(envelope);
        for (var offset = 0; offset < framed.Length; offset += 60_000)
        {
            var chunk = framed.AsMemory(offset, Math.Min(60_000, framed.Length - offset)).ToArray();
            await SendRawAsync(peer, peer.Keys.Sender.Encrypt(chunk));
        }
    }

    // ---- Home side ----
    private DeviceSidebarPayload SidebarPayload() => new()
    {
        HomeDeviceID = DeviceId,
        HomeDeviceName = DeviceName,
        HomeSeq = _homeSeq,
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
        }).ToList(),
    };

    private async Task SendSidebarAsync(Peer peer) =>
        await SendEnvelopeAsync(peer, new DeviceEnvelope
        { Kind = DeviceKind.SidebarSnapshot, HomeSeq = ++_homeSeq, Payload = DeviceJson.Encode(SidebarPayload()) });

    private void PublishSidebars()
    {
        foreach (var peer in _peers.Values.Where(p => p.TrustedReady)) _ = SendSidebarAsync(peer);
    }

    private string ImageHash(string path)
    {
        var hash = DeviceBlob.Sha256Hex(File.ReadAllBytes(path));
        _blobPaths[hash] = path;
        return hash;
    }

    private async Task SendTranscriptAsync(Peer peer, ChatSession session, int? beforeOffset = null)
    {
        if (peer.Hello is null) return;
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
            HomeSeq = ++_homeSeq, Epoch = holder.Value.Epoch, Boot = _boot,
            Messages = session.Messages.Skip(start).Take(end - start).Select(m => new DeviceWireMessage
            {
                Id = m.Id, Role = m.Role, Text = m.Text,
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
            QueuePaused = session.QueuePaused,
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
        if (!await RequireLeaseAsync(peer, envelope, session)) return;
        var payloadHash = DeviceBlob.Sha256Hex(envelope.Payload);
        if (!_commands.Begin(commandId, peer.Hello.DeviceID, envelope.SessionID ?? "", payloadHash))
        {
            await SendAckAsync(peer, commandId, envelope.SessionID,
                _commands.BindingMatches(commandId, peer.Hello.DeviceID, envelope.SessionID ?? "", payloadHash) ? _commands.Outcome(commandId) ?? "rejected" : "rejected",
                "Already recorded on home.", envelope.Epoch);
            return;
        }
        string[] known = { "submit", "inject", "injectAll", "stop", "resumeQueue", "pauseQueue", "clearQueue", "rename", "model", "effort", "access", "answer" };
        if (!known.Contains(command.Action))
        {
            _commands.MarkFailed(commandId);
            await SendAckAsync(peer, commandId, envelope.SessionID, "failed", "Unknown action.", envelope.Epoch);
            return;
        }
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
        switch (command.Action)
        {
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
            case "inject": _store.InjectPending(session, command.PendingID); break;
            case "injectAll": _store.InjectPending(session); break;
            case "stop": _store.Stop(session); break;
            case "resumeQueue": session.QueuePaused = false; _store.Save(); _store.RunNext(session); break;
            case "pauseQueue": session.QueuePaused = true; _store.Save(); break;
            case "clearQueue": session.Pending.Clear(); _store.Save(); break;
            case "rename": if (!string.IsNullOrEmpty(command.Text)) { session.Title = command.Text; _store.Save(); } break;
            case "model": session.Choices.Model = command.Model; session.Choices.ModelProvider = command.ModelProvider; session.Choices.ModelProfile = command.ModelProfile; _store.Save(); break;
            case "effort": session.Choices.Effort = command.Effort; _store.Save(); break;
            case "access": session.Choices.Access = command.Access; _store.Save(); break;
        }
        _commands.MarkCompleted(commandId);
        await SendAckAsync(peer, commandId, envelope.SessionID, "completed", "Applied once on home.", envelope.Epoch);
        await SendTranscriptAsync(peer, session);
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
        if (LocallyRemoved && envelope.Kind is not ("fabric.members" or DeviceKind.Ping or DeviceKind.Pong)) return;
        switch (envelope.Kind)
        {
            case "fabric.members":
                if (!peer.Hello.Capabilities.Contains("fabric-membership-v1") || envelope.Payload is null) break;
                try
                {
                    var wasRemoved = LocallyRemoved;
                    if (!Trust.Merge(DeviceJson.Decode<List<TrustedDevice>>(envelope.Payload))) break;
                    var active = Trust.Devices.Select(d => d.DeviceID).ToHashSet();
                    foreach (var connection in _peers.Values.Where(p => p.TrustedReady && !active.Contains(p.Hello?.DeviceID ?? "")).ToList()) Disconnect(connection);
                    foreach (var member in Trust.Devices.Where(d => d.DeviceID != DeviceId)) Homes.TryAdd(member.DeviceID, new RemoteHomeState { DeviceID = member.DeviceID, DeviceName = member.Name });
                    foreach (var removed in Trust.Records.Where(d => d.Removed == true)) Homes.TryRemove(removed.DeviceID, out _);
                    if (LocallyRemoved && !wasRemoved) { foreach (var connection in _peers.Values.ToList()) Disconnect(connection); break; }
                    if (wasRemoved && !LocallyRemoved) await SendSidebarAsync(peer);
                    await BroadcastFabricAsync(); _ = ReconnectFabricAsync(); Changed?.Invoke();
                }
                catch { LastOutcome = "Could not save fabric membership. No new trust granted."; }
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
                if (HomeSession(envelope) is { } leased)
                {
                    var result = _leases.Acquire(leased.Id, peerHome);
                    if (!result.Granted) { await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.LeaseDenied, Boot = _boot, SessionID = envelope.SessionID }); break; }
                    peer.LeasedSessions.Add(leased.Id);
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
                    _leases.Release(released.Id, peerHome, relEpoch);
                    peer.LeasedSessions.Remove(released.Id);
                }
                break;
            case DeviceKind.LeaseGranted:
                if (envelope.SessionID is { } grantedId && DeviceGlobalID.Parse(grantedId)?.Home == peerHome && envelope.Epoch is { } grantEpoch)
                {
                    if (_pendingTakes.Remove(grantedId)) { RemoteLeases[grantedId] = grantEpoch; RemoteOffline.Remove(grantedId); }
                    else if (RemoteLeases.TryGetValue(grantedId, out var current) && grantEpoch > current) RemoteLeases[grantedId] = grantEpoch;
                    else await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.LeaseRelease, SessionID = grantedId, Epoch = grantEpoch });
                    Changed?.Invoke();
                }
                break;
            case DeviceKind.LeaseStolen:
            case DeviceKind.LeaseDenied:
                if (envelope.SessionID is { } stolenId && DeviceGlobalID.Parse(stolenId)?.Home == peerHome)
                {
                    _pendingTakes.Remove(stolenId);
                    RemoteLeases.Remove(stolenId);
                    RemoteTranscripts.Remove(stolenId);
                    Changed?.Invoke();
                }
                break;
            case DeviceKind.TranscriptSnapshot:
                if (envelope.Payload is null) break;
                var transcript = DeviceJson.Decode<DeviceTranscriptPayload>(envelope.Payload);
                if (DeviceGlobalID.Parse(transcript.GlobalID)?.Home != peerHome) break;
                if (transcript.Epoch is null || RemoteLeases.GetValueOrDefault(transcript.GlobalID) != transcript.Epoch) break;
                if (RemoteTranscripts.TryGetValue(transcript.GlobalID, out var existing) && transcript.HomeSeq <= existing.HomeSeq) break;
                RemoteTranscripts[transcript.GlobalID] = transcript;
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
                        if (!_staged.TryGetValue(blob.Sha256Hex, out var staged)) { staged = new List<byte>(); _staged[blob.Sha256Hex] = staged; }
                        staged.AddRange(blob.Chunk);
                        if (staged.Count > DeviceBlob.MaxBlob) { _staged.Remove(blob.Sha256Hex); await SendBlobAckAsync(peer, envelope, blob.Sha256Hex, false); break; }
                    }
                    if (blob.Done)
                    {
                        var bytes = _staged.GetValueOrDefault(blob.Sha256Hex)?.ToArray() ?? Array.Empty<byte>();
                        _staged.Remove(blob.Sha256Hex);
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
                Changed?.Invoke();
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

    // ---- Viewer side ----
    private Peer? PeerForHome(string home) =>
        LocallyRemoved ? null : _peers.Values.FirstOrDefault(p => p.TrustedReady && p.Hello?.DeviceID == home && Homes.GetValueOrDefault(home)?.Online == true);

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
        _pendingTakes.Remove(globalId);
        if (DeviceGlobalID.Parse(globalId) is { } parsed && RemoteLeases.TryGetValue(globalId, out var epoch) &&
            PeerForHome(parsed.Home) is { } peer)
            await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = DeviceKind.LeaseRelease, SessionID = globalId, Epoch = epoch });
        RemoteLeases.Remove(globalId);
    }

    public async Task<Guid?> SendRemoteCommandAsync(string globalId, DeviceCommandPayload command)
    {
        var parsed = DeviceGlobalID.Parse(globalId);
        if (parsed is null || !RemoteLeases.TryGetValue(globalId, out var epoch) || PeerForHome(parsed.Value.Home) is not { } peer)
        { LastOutcome = "Take the session again before sending."; return null; }
        var payloadData = DeviceJson.Encode(command);
        var record = new DeviceOutboxRecord
        { CommandID = Guid.NewGuid(), SessionID = globalId, Payload = command, PayloadHash = DeviceBlob.Sha256Hex(payloadData), Epoch = epoch };
        _outbox.Add(record);
        Changed?.Invoke();
        await SendEnvelopeAsync(peer, new DeviceEnvelope
        { Kind = DeviceKind.Command, SessionID = globalId, CommandID = record.CommandID, Epoch = epoch, Payload = payloadData });
        return record.CommandID;
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
}

