using System.Security.Cryptography;
using Converse.Core;

// Console check runner mirroring Sources/DeviceSyncTests.swift (PASS:/FAIL:).
var failures = 0;
void Check(bool ok, string label)
{
    Console.WriteLine((ok ? "PASS: " : "FAIL: ") + label);
    if (!ok) failures++;
}
byte[] FixedKey(byte value)
{
    var key = new byte[32];
    Array.Fill(key, value);
    return key;
}
byte[] Utf8(string value) => System.Text.Encoding.UTF8.GetBytes(value);

Console.WriteLine("ChaCha20Poly1305 supported: " + ChaCha20Poly1305.IsSupported);
Check(ChaCha20Poly1305.IsSupported, "Platform provides ChaCha20-Poly1305 (run on Windows/Linux)");

// Framing round-trip.
{
    var id = Guid.NewGuid();
    var envelope = new DeviceEnvelope { Kind = DeviceKind.Command, SessionID = "home/session", CommandID = id, Epoch = 3, Payload = Utf8("hello") };
    var decoder = new DeviceFrameDecoder();
    var framed = DeviceFrame.Encode(envelope).Concat(DeviceFrame.Encode(envelope)).ToArray();
    var decoded = decoder.Append(framed);
    Check(decoded.Count == 2 && decoded[0].CommandID == id && decoded[0].Epoch == 3, "Device frames round-trip two envelopes");
}

// External cacophony vector Noise_XX_25519_ChaChaPoly_SHA256 (prologue "John Galt").
{
    var prologue = Hex.Decode("4a6f686e2047616c74");
    var initiator = new DeviceHandshake(true, Hex.Decode("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1"), Hex.Decode("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a"), prologue);
    var responder = new DeviceHandshake(false, Hex.Decode("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893"), Hex.Decode("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b"), prologue);
    var m1 = initiator.WriteMessage(Hex.Decode("4c756477696720766f6e204d69736573"));
    Check(Hex.Encode(m1) == "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79444c756477696720766f6e204d69736573", "External Noise vector message one matches");
    responder.ReadMessage(m1);
    var m2 = responder.WriteMessage(Hex.Decode("4d757272617920526f746862617264"));
    Check(Hex.Encode(m2) == "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f14480884381cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b9bd5269c2f1e4f488ed8831161f19b7815528f8982ffe09be9b5c412f8a0db50f8814c7194e83f23dbd8d162c9326ad", "External Noise vector message two matches");
    initiator.ReadMessage(m2);
    var m3 = initiator.WriteMessage(Hex.Decode("462e20412e20486179656b"));
    Check(Hex.Encode(m3) == "c7195ffacac1307ff99046f219750fc47693e23c3cb08b89c2af808b444850a80ae475b9df0f169ae80a89be0865b57f58c9fea0d4ec82a286427402f113e4b6ae769a1d95941d49b25030", "External Noise vector message three matches");
    responder.ReadMessage(m3);
    var a = initiator.Finish();
    var b = responder.Finish();
    Check(Hex.Encode(a.HandshakeHash) == "c8e5f64e846193be2a834104c2a009868d6c9f3bd3c186299888b488b2f1f58e", "External Noise vector handshake hash matches");
    Check(Hex.Encode(b.Sender.Encrypt(Hex.Decode("4361726c204d656e676572"))) == "96763ed773f8e47bb3712f0e29b3060ffc956ffc146cee53d5e1df", "External Noise vector transport matches");
    Check(DeviceSas.Code(a.HandshakeHash) == DeviceSas.Code(b.HandshakeHash) && DeviceSas.Code(a.HandshakeHash).Replace(" ", "").Length == 32, "Both devices derive same 128-bit code");
}

// MITM legs must show different codes.
{
    string Leg(byte attackerByte, byte victimByte, bool victimInitiator)
    {
        var victim = new DeviceHandshake(victimInitiator, FixedKey(victimByte), FixedKey(0x51));
        var attacker = new DeviceHandshake(!victimInitiator, FixedKey(attackerByte), FixedKey(0x52));
        if (victimInitiator)
        {
            attacker.ReadMessage(victim.WriteMessage(Utf8("hello-victim")));
            victim.ReadMessage(attacker.WriteMessage(Utf8("hello-attacker")));
            attacker.ReadMessage(victim.WriteMessage(Utf8("hello-victim")));
        }
        else
        {
            victim.ReadMessage(attacker.WriteMessage(Utf8("hello-attacker")));
            attacker.ReadMessage(victim.WriteMessage(Utf8("hello-victim")));
            victim.ReadMessage(attacker.WriteMessage(Utf8("hello-attacker")));
        }
        return DeviceSas.Code(victim.Finish().HandshakeHash);
    }
    Check(Leg(0x61, 0x11, true) != Leg(0x62, 0x22, false), "MITM legs with different keys show different 128-bit codes");
}

// RFC 7748 section 6.1 vectors + low-order rejection.
{
    var alicePriv = Hex.Decode("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    var alicePub = Hex.Decode("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
    var bobPriv = Hex.Decode("5dab087ebb8a74e5a7d8f44d526b2d87247d7469f3f34e13fd5a1d57a4277b7a");
    var bobPub = Hex.Decode("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
    Check(Hex.Encode(X25519.PublicKeyFromPrivate(alicePriv)) == Hex.Encode(alicePub), "RFC7748 Alice public key matches");
    Check(Hex.Encode(X25519.SharedSecret(alicePriv, bobPub)) == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742", "RFC7748 shared secret matches");
    var rejected = false;
    try { X25519.SharedSecret(alicePriv, new byte[32]); } catch { rejected = true; }
    Check(rejected, "All-zero (low-order) public key is rejected");
}

// Lease fencing + expiry.
{
    var now = DateTimeOffset.FromUnixTimeSeconds(1000);
    var leases = new DeviceLeaseManager(() => now, ttlSeconds: 15);
    var session = Guid.NewGuid();
    var first = leases.Acquire(session, "device-a");
    var second = leases.Acquire(session, "device-b");
    Check(first.Granted && second.Epoch == first.Epoch + 1 && !leases.Validate(session, "device-a", first.Epoch) && leases.Validate(session, "device-b", second.Epoch), "Takeover fences stale holder");
    now = now.AddSeconds(16);
    Check(leases.SweepExpired().Any(e => e.Device == "device-b") && !leases.Validate(session, "device-b", second.Epoch), "Expired leases sweep");
    var denied = new DeviceLeaseManager(persistEpochs: _ => false);
    Check(!denied.Acquire(session, "device-c").Granted, "Epoch persistence failure denies grant (fail closed)");
}

// Command store dedup + uncertain recovery; outbox retention; draft adoption.
{
    var root = Directory.CreateTempSubdirectory("converse-core-").FullName;
    try
    {
        var commands = new DeviceCommandStore(root);
        var id = Guid.NewGuid();
        Check(commands.Begin(id, "device-a", "s1", "h1") && !commands.Begin(id, "device-a", "s1", "h1") && !commands.BindingMatches(id, "device-a", "s2", "h1"), "Dedup binds origin session hash");
        commands.MarkRunning(id);
        Check(new DeviceCommandStore(root).Outcome(id) == "uncertain", "Running command recovers as uncertain");
        var outbox = new DeviceOutboxStore(root);
        var record = new DeviceOutboxRecord { CommandID = Guid.NewGuid(), SessionID = "home/s", Payload = new DeviceCommandPayload { Action = "submit", Text = "keep me" }, PayloadHash = "h", Epoch = 4 };
        outbox.Add(record);
        outbox.Resolve(record.CommandID, "failed", "nope");
        Check(outbox.Records.Count == 1 && outbox.Records[0].Payload.Text == "keep me", "Failed outbox record retains content");
        outbox.Resolve(record.CommandID, "completed", null);
        Check(outbox.Records.Count == 0, "Only completed removes outbox record");
        var homeDraft = new DeviceDraftTracker();
        var viewerDraft = new DeviceDraftTracker();
        homeDraft.Apply("s", 5, "preserved");
        viewerDraft.Adopt("s", 5, "preserved");
        Check(viewerDraft.Bump("s", "edit") == 6 && homeDraft.Apply("s", 6, "edit"), "New holder adopts home draft version");
    }
    finally { Directory.Delete(root, recursive: true); }
}

// Session engine with fake runner: codex JSONL consume + queue + final reply.
{
    var root = Directory.CreateTempSubdirectory("converse-engine-").FullName;
    try
    {
        var store = new SessionStore(root, new FakeRunner());
        var session = store.Create(store.Entries.First(e => e.Engine == "codex"));
        session.Draft = "hello engine";
        store.Submit(session);
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (session.Busy && DateTime.UtcNow < deadline) await Task.Delay(20);
        Check(session.Messages.Any(m => m.Role == "assistant" && m.Text.Contains("fake reply")), "Engine consumes Codex JSONL into assistant text");
        Check(session.RemoteID == "thread-1" && session.Status == "Ready", "Engine records Codex thread and ready status");
        Check(session.Messages.Any(m => m.FinalReply == "fake reply\n"), "Engine captures Codex final-answer file");
    }
    finally { Directory.Delete(root, recursive: true); }
}

// Loopback device service: pair, take, rename, bound ack over real TCP.
{
    var homeRoot = Directory.CreateTempSubdirectory("converse-home-").FullName;
    var viewerRoot = Directory.CreateTempSubdirectory("converse-viewer-").FullName;
    try
    {
        var homeStore = new SessionStore(homeRoot, new FakeRunner());
        var homeSession = homeStore.Create(homeStore.Entries.First(e => e.Engine == "codex"));
        homeSession.Title = "Loopback home";
        homeSession.Draft = "home words";
        using var home = new DeviceSyncService(homeRoot, homeStore, "HomePC");
        using var viewer = new DeviceSyncService(viewerRoot, new SessionStore(viewerRoot, new FakeRunner()), "ViewerPC");
        home.PairingConfirmation = _ => Task.FromResult(true);
        viewer.PairingConfirmation = _ => Task.FromResult(true);
        await home.StartAsync(0);
        await viewer.StartAsync(0);
        await viewer.ConnectManualAsync("127.0.0.1", home.ListeningPort);
        async Task<bool> Until(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        var gid = new DeviceGlobalID(home.DeviceId, homeSession.Id).ToString();
        Check(await Until(() => viewer.Homes.GetValueOrDefault(home.DeviceId)?.Rows.Any(r => r.GlobalID == gid) == true), "Loopback pairing publishes home sidebar");
        await viewer.AcquireRemoteAsync(gid);
        Check(await Until(() => viewer.RemoteTranscripts.GetValueOrDefault(gid)?.Draft == "home words"), "Loopback take streams home draft snapshot");
        var commandId = await viewer.SendRemoteCommandAsync(gid, new DeviceCommandPayload { Action = "rename", Text = "Renamed from viewer" });
        Check(commandId is not null && await Until(() => homeSession.Title == "Renamed from viewer" && viewer.Unresolved(gid).Count == 0), "Loopback rename applies once on home and clears outbox");
    }
    finally
    {
        Directory.Delete(homeRoot, recursive: true);
        Directory.Delete(viewerRoot, recursive: true);
    }
}

// Muse MSP over loopback TCP: approval request surfaces and decides.
{
    var root = Directory.CreateTempSubdirectory("converse-msp-").FullName;
    var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
    listener.Start();
    var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
    string? decidedChoice = null;
    string sid = "";
    var serverTask = Task.Run(async () =>
    {
        using var server = await listener.AcceptTcpClientAsync();
        var stream = server.GetStream();
        using var reader = new StreamReader(stream, leaveOpen: true);
        async Task Send(string json) => await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes(json + "\n"));
        while (await reader.ReadLineAsync() is { } line)
        {
            var obj = System.Text.Json.Nodes.JsonNode.Parse(line)!.AsObject();
            var method = obj["method"]?.GetValue<string>();
            var id = obj["id"]?.DeepClone();
            if (method == "initialize") await Send($"{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":{{}}}}".Replace("{id}", id!.ToJsonString()));
            else if (method == "session/read") { sid = obj["params"]?["sessionId"]?.GetValue<string>() ?? ""; await Send($"{{\"jsonrpc\":\"2.0\",\"id\":{id!.ToJsonString()},\"error\":{{\"code\":-32000,\"message\":\"missing\",\"data\":{{\"kind\":\"sessionNotFound\"}}}}}}"); }
            else if (method == "session/start") { sid = obj["params"]?["sessionId"]?.GetValue<string>() ?? sid; await Send($"{{\"jsonrpc\":\"2.0\",\"id\":{id!.ToJsonString()},\"result\":{{}}}}"); }
            else if (method == "turn/start")
            {
                await Send($"{{\"jsonrpc\":\"2.0\",\"id\":{id!.ToJsonString()},\"result\":{{\"turnId\":\"t1\"}}}}");
                await Send("{\"jsonrpc\":\"2.0\",\"id\":900,\"method\":\"approval/request\",\"params\":{\"sessionId\":\"" + sid + "\",\"approvalId\":\"a1\",\"currentRequirementId\":\"r1\",\"toolName\":\"Bash\",\"rawArgs\":\"ls\",\"availableChoices\":[{\"choiceId\":\"allow-once\",\"label\":\"Allow once\"},{\"choiceId\":\"deny\",\"label\":\"Deny\"}]}}");
            }
            else if (method == "approval/decide")
            {
                decidedChoice = obj["params"]?["choiceId"]?.GetValue<string>();
                await Send($"{{\"jsonrpc\":\"2.0\",\"id\":{id!.ToJsonString()},\"result\":{{}}}}");
                await Send("{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"sessionId\":\"" + sid + "\",\"terminal\":\"completed\"}}");
            }
        }
    });
    try
    {
        var store = new SessionStore(root, new FakeRunner());
        var session = store.Create(store.Entries.First(e => e.Engine == "muse"));
        store.MuseFactory = (entry, s) =>
        {
            var tcp = new System.Net.Sockets.TcpClient();
            tcp.Connect(System.Net.IPAddress.Loopback, port);
            return MuseMspClient.OverStream(s.Id.ToString("D"), tcp.GetStream());
        };
        // Fake server expects its sessionId echo; align by using any id (client filters mismatches).
        session.Draft = "do it";
        store.Submit(session);
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (session.Requests.Count == 0 && DateTime.UtcNow < deadline) await Task.Delay(25);
        Check(session.Requests.Count == 1 && session.Requests[0].Kind == "approval", "MSP approval request surfaces on session");
        if (session.Requests.Count == 1)
            Check(await store.AnswerMuseAsync(session, session.Requests[0], choice: "deny"), "MSP approval decision accepted by client");
        while (session.Busy && DateTime.UtcNow < deadline) await Task.Delay(25);
        Check(decidedChoice == "deny" && session.Status == "Ready", "MSP decide reaches host and turn completes");
    }
    finally
    {
        listener.Stop();
        Directory.Delete(root, recursive: true);
    }
}

// mDNS name decoding with compression pointer.
{
    var packet = new List<byte>();
    packet.AddRange(new byte[12]);
    void Label(string value) { packet.Add((byte)value.Length); packet.AddRange(System.Text.Encoding.UTF8.GetBytes(value)); }
    Label("_converse"); Label("_tcp"); Label("local"); packet.Add(0);
    var pointerTarget = 12;
    packet.AddRange(new byte[] { 3, (byte)'M', (byte)'a', (byte)'c', (byte)(0xC0 | (pointerTarget >> 8)), (byte)pointerTarget });
    var bytes = packet.ToArray();
    var offset = 12;
    var first = Converse.Core.MdnsDiscovery.ReadName(bytes, ref offset);
    var second = Converse.Core.MdnsDiscovery.ReadName(bytes, ref offset);
    Check(first == "_converse._tcp.local" && second == "Mac._converse._tcp.local", "mDNS names decode with compression pointers");
}

// Help artifact: generated schema loads, search matches titles + body, bad schema fails closed.
{
    var json = "{\"schemaVersion\":1,\"title\":\"Converse\",\"appVersion\":\"0.4.5\",\"appBuild\":\"18\","
        + "\"sourceCommit\":\"0123456789abcdef0123456789abcdef01234567-dirty\","
        + "\"sourceURL\":\"https://github.com/richardkaufmann/converse/blob/main/README.md\","
        + "\"sourceSHA256\":\"deadbeef\",\"futureMetadata\":{\"anything\":true},\"topics\":["
        + "{\"id\":\"overview\",\"title\":\"Converse\",\"markdown\":\"Intro\",\"plainText\":\"Manage conversations about pairing\"},"
        + "{\"id\":\"pairing\",\"title\":\"Pairing devices\",\"markdown\":\"Steps\",\"plainText\":\"Compare all 8 groups\"},"
        + "{\"id\":\"connect-two-macs\",\"title\":\"Connect two Macs\",\"markdown\":\"Pairing steps\",\"plainText\":\"Compare all 8 groups\"}]}";
    var help = HelpDocument.Load(json);
    Check(help.Topics.Count == 3 && help.AppVersion == "0.4.5" && help.AppBuild == "18" && help.Title == "Converse"
        && help.SourceSHA256 == "deadbeef" && help.Topic("connect-two-macs")?.Title == "Connect two Macs",
        "Help artifact loads locked metadata and ignores unknown fields");
    Check(help.Search("8 GROUPS").Count == 2 && help.Search("macs").Count == 1 && help.Search("").Count == 3 && help.Search("nonexistent-term").Count == 0,
        "Help search is case-insensitive over titles and plain text");
    var ranked = help.Search("pairing");
    Check(ranked.Count == 2 && ranked[0].Id == "pairing" && ranked[1].Id == "overview",
        "Help search ranks title hits before body-only hits");
    var rejected = false;
    try { HelpDocument.Load("{\"schemaVersion\":99,\"topics\":[]}"); } catch (InvalidDataException) { rejected = true; }
    Check(rejected, "Help loader rejects unsupported schema versions");
    // Generated artifact, when present next to the test runner or in the app Assets, must load.
    var candidates = new[]
    {
        Path.Combine(AppContext.BaseDirectory, "help.json"),
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "Converse.Windows", "Assets", "help.json")),
    };
    var generated = candidates.Select(HelpDocument.TryLoadFile).FirstOrDefault(d => d is not null);
    if (generated is not null)
        Check(generated.Topics.Count >= 10 && generated.Topic("overview") is not null,
            "Generated README Help artifact loads with overview topic");
}

// Sidebar pin layout: toggle collapses to zero, restore returns user width clamped to half window.
{
    var layout = new SidebarLayoutState();
    layout.RecordUserWidth(420, 1200);
    Check(layout.EffectiveWidth(1200) == 420, "Sidebar remembers user width");
    Check(layout.Toggle() && layout.EffectiveWidth(1200) == 0, "Sidebar pin collapses to zero width");
    Check(!layout.Toggle() && layout.EffectiveWidth(1200) == 420, "Sidebar pin restores previous user width");
    Check(layout.EffectiveWidth(600) == 300, "Sidebar restore clamps to half a narrow window");
    layout.RecordUserWidth(80, 1200);
    Check(layout.ExpandedWidth == SidebarLayoutState.MinWidth, "Sidebar width has a usable minimum");
    var dir = Directory.CreateTempSubdirectory("converse-layout-").FullName;
    layout.Collapsed = true;
    layout.Save(dir);
    var reloaded = SidebarLayoutState.Load(dir);
    Check(reloaded.Collapsed && reloaded.ExpandedWidth == SidebarLayoutState.MinWidth,
        "Sidebar layout persists collapsed state and width");
}

// Transitive admission: C joins through B; A and C connect without another approval.
{
    var root = Directory.CreateTempSubdirectory("converse-fabric-").FullName;
    var services = new List<DeviceSyncService>(); var admissions = 0;
    try
    {
        for (var i = 0; i < 4; i++)
        {
            var folder = Path.Combine(root, i.ToString());
            var store = new SessionStore(folder, new FakeRunner());
            var session = store.Create(store.Entries.First(e => e.Engine == "codex")); session.Title = "Fabric " + i;
            var service = new DeviceSyncService(folder, store, "PC " + i);
            service.PairingConfirmation = _ => { Interlocked.Increment(ref admissions); return Task.FromResult(true); };
            await service.StartAsync(0); services.Add(service);
        }
        async Task<bool> WaitFor(Func<bool> predicate)
        {
            var end = DateTime.UtcNow.AddSeconds(15);
            while (!predicate() && DateTime.UtcNow < end) await Task.Delay(20);
            return predicate();
        }
        for (var i = 1; i < services.Count; i++)
        {
            await services[i].ConnectManualAsync("127.0.0.1", services[i - 1].ListeningPort);
            Check(await WaitFor(() => services[i].Trust.Devices.Count >= i + 1), "Windows entrant learns existing fabric from one sponsor");
        }
        Check(await WaitFor(() => services.All(s => s.Homes.Count(h => h.Value.Online) == 3)) && admissions == 6,
            "Four Windows cores form a mesh with only three mutual admissions");
        Check(await WaitFor(() => services.All(s => s.Homes.Values.All(h => h.Rows.Count == 1))), "Fabric members see every other home session");
        var stale = services[0].Trust.Records;
        services[0].ForgetDevice(services[0].Trust.Devices.First(d => d.DeviceID == services[3].DeviceId));
        Check(await WaitFor(() => services.Take(3).All(s => s.Trust.Check(services[3].DeviceId, X25519.PublicKeyFromPrivate(File.ReadAllBytes(Path.Combine(root, "3", "device-key.bin")))) == "unknown")), "Fabric removal propagates to other members");
        var merged = services[1].Trust.Merge(stale);
        Check(!services[1].Trust.Devices.Any(d => d.DeviceID == services[3].DeviceId), "Stale roster cannot resurrect a removed Windows member");
        var wire = System.Text.Encoding.UTF8.GetString(DeviceJson.Encode(services[0].Trust.Records));
        Check(wire.Contains("\"deviceID\"") && wire.Contains("\"generation\"") && wire.Contains("\"removed\""), "Fabric record JSON uses the exact Swift wire keys");
    }
    finally { foreach (var service in services) service.Dispose(); }
}

// Metadata updates have no admission authority; UTF-8 name bounds match Swift.
{
    var folder = Directory.CreateTempSubdirectory("converse-metadata-").FullName;
    var trust = new DeviceTrustStore(folder);
    var key = X25519.GenerateKeyPair().Item2;
    var id = DeviceBlob.DeviceIdForPublicKey(key);
    trust.Pin(new TrustedDevice(id, "First", key, null, null), "admin-a");
    var first = trust.Records.Single();
    trust.Pin(new TrustedDevice(id, "Renamed", key, "192.0.2.5", 49000), "admin-b", allowAdmission: false);
    var refreshed = trust.Records.Single();
    Check(refreshed.Generation == first.Generation && refreshed.ChangedBy == first.ChangedBy && refreshed.MetadataGeneration > first.MetadataGeneration, "C# endpoint updates do not mint membership generations");
    Check(refreshed.PairedAt > 0, "C# admissions record a real Apple-reference pairing date");
    var mirror = new DeviceTrustStore(Path.Combine(folder, "mirror")); mirror.Merge(new[] { first }); mirror.Merge(new[] { refreshed });
    Check(mirror.Devices.Single().LastHost == "192.0.2.5" && mirror.Devices.Single().Generation == first.Generation, "C# equal-rank hint updates converge without granting admission");
    var name = string.Concat(Enumerable.Repeat("🙂", 60));
    Check(DeviceTrustStore.BoundedName(name) == string.Concat(Enumerable.Repeat("🙂", 50)), "C# fabric names share Swift's 200 UTF-8 byte limit");
}

// Revoked R must not revive itself via stale X, even when endpoints/names drift.
{
    var root = Directory.CreateTempSubdirectory("converse-revocation-").FullName;
    var live = new List<DeviceSyncService>();
    DeviceSyncService Make(string name)
    {
        var folder = Path.Combine(root, name); var service = new DeviceSyncService(folder, new SessionStore(folder, new FakeRunner()), name);
        service.PairingConfirmation = _ => Task.FromResult(true); live.Add(service); return service;
    }
    async Task<bool> WaitRevocation(Func<bool> done)
    {
        var until = DateTime.UtcNow.AddSeconds(8);
        while (!done() && DateTime.UtcNow < until) await Task.Delay(20);
        return done();
    }
    try
    {
        var a = Make("A"); var r = Make("R"); var x = Make("X");
        await a.StartAsync(0); await r.StartAsync(0); await x.StartAsync(0);
        await r.ConnectManualAsync("127.0.0.1", a.ListeningPort);
        await WaitRevocation(() => a.Trust.Devices.Count == 2 && r.Trust.Devices.Count == 2);
        await x.ConnectManualAsync("127.0.0.1", a.ListeningPort);
        Check(await WaitRevocation(() => live.All(s => s.Homes.Values.Count(h => h.Online) == 2)), "Revocation regression starts with a connected fabric");
        x.Dispose(); r.Dispose();
        a.ForgetDevice(a.Trust.Devices.First(d => d.DeviceID == r.DeviceId));
        var tombstone = a.Trust.Records.First(d => d.DeviceID == r.DeviceId);
        new DeviceTrustStore(Path.Combine(root, "R")).Merge(new[] { tombstone });
        a.Dispose();
        r = Make("R"); x = Make("X"); await r.StartAsync(0); await x.StartAsync(0);
        await r.ConnectManualAsync("127.0.0.1", x.ListeningPort);
        await WaitRevocation(() => x.Trust.Records.Any(d => d.DeviceID == r.DeviceId && d.Removed == true));
        var all = a.Trust.Records.Concat(r.Trust.Records).Concat(x.Trust.Records).Where(d => d.DeviceID == r.DeviceId);
        Check(all.All(d => d.Removed == true && d.Generation == tombstone.Generation), "Removed C# device cannot self-readmit through a stale member on reconnect");
        Check(await WaitRevocation(() => r.Homes.GetValueOrDefault(x.DeviceId)?.Online != true && x.Homes.GetValueOrDefault(r.DeviceId)?.Online != true), "Stale C# member learns removal and disconnects R");
        a = Make("A"); await a.StartAsync(0); await r.ConnectManualAsync("127.0.0.1", a.ListeningPort);
        Check(await WaitRevocation(() => r.Trust.Records.Any(d => d.DeviceID == r.DeviceId && d.Removed != true) && a.Homes.GetValueOrDefault(r.DeviceId)?.Online == true), "Explicit up-to-date C# sponsor readmission succeeds");
        var readmitted = a.Trust.Records.First(d => d.DeviceID == r.DeviceId);
        Check(readmitted.Removed != true && readmitted.Generation > tombstone.Generation && readmitted.ChangedBy == a.DeviceId, "C# readmission generation belongs to the approving sponsor");
    }
    finally { foreach (var service in live) service.Dispose(); }
}

if (int.TryParse(Environment.GetEnvironmentVariable("CONVERSE_MAC_INTEROP_PORT"), out var macPort) && macPort > 0)
{
    var root = Directory.CreateTempSubdirectory("converse-mac-fabric-").FullName;
    var admissions = 0;
    using var a = new DeviceSyncService(Path.Combine(root, "a"), new SessionStore(Path.Combine(root, "a"), new FakeRunner()), "Windows core A");
    using var b = new DeviceSyncService(Path.Combine(root, "b"), new SessionStore(Path.Combine(root, "b"), new FakeRunner()), "Windows core B");
    a.PairingConfirmation = _ => { Interlocked.Increment(ref admissions); return Task.FromResult(true); };
    b.PairingConfirmation = _ => { Interlocked.Increment(ref admissions); return Task.FromResult(true); };
    await a.StartAsync(0); await b.StartAsync(0);
    async Task<bool> WaitMac(Func<bool> predicate)
    {
        var end = DateTime.UtcNow.AddSeconds(15);
        while (!predicate() && DateTime.UtcNow < end) await Task.Delay(25);
        return predicate();
    }
    await a.ConnectManualAsync("127.0.0.1", macPort);
    Check(await WaitMac(() => a.Homes.Values.Any(h => h.DeviceName == "Isolated Mac home" && h.Rows.Count > 0)), "C# core pairs with real Swift home");
    await b.ConnectManualAsync("127.0.0.1", a.ListeningPort);
    Check(await WaitMac(() => b.Homes.Values.Any(h => h.DeviceName == "Isolated Mac home" && h.Rows.Count > 0)) && admissions == 3,
        "C# entrant joins through C# member and automatically connects to Swift home");
    var mac = b.Homes.Values.FirstOrDefault(h => h.DeviceName == "Isolated Mac home");
    if (mac?.Rows.FirstOrDefault() is { } row)
    {
        await b.AcquireRemoteAsync(row.GlobalID);
        Check(await WaitMac(() => b.RemoteTranscripts.GetValueOrDefault(row.GlobalID)?.Draft == "home draft"), "Transitively admitted C# viewer takes Swift session and receives its draft");
    }
}

Console.WriteLine(failures == 0 ? "All core checks passed" : $"{failures} checks FAILED");
return failures == 0 ? 0 : 1;

sealed class FakeRunner : Converse.Core.IAgentRunner
{
    public Task<int> RunAsync(Converse.Core.ChatSession session, IReadOnlyList<string> arguments, string prompt,
        Action<string> onLine, CancellationToken cancellationToken)
    {
        onLine("{\"type\":\"thread.started\",\"thread_id\":\"thread-1\"}");
        onLine("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"fake reply\"}}");
        var finalIndex = arguments.ToList().IndexOf("--output-last-message");
        if (finalIndex >= 0) File.WriteAllText(arguments[finalIndex + 1], "fake reply\n");
        onLine("{\"type\":\"turn.completed\"}");
        return Task.FromResult(0);
    }
}
