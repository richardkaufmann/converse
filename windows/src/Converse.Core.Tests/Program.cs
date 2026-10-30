using System.Security.Cryptography;
using Converse.Core;

// Console check runner mirroring Sources/DeviceSyncTests.swift (PASS:/FAIL:).
// Emit mode: the UTF-8 test spawns this same binary so the wire bytes are
// exact (E2 80 93 + newline) on every platform, no shell involved.
if (args.FirstOrDefault() == "--emit-utf8")
{
    Console.OpenStandardOutput().Write([0xE2, 0x80, 0x93, 0x0A]);
    return 0;
}
if (args.FirstOrDefault() == "--echo-stdin")
{
    Console.Write(await Console.In.ReadToEndAsync());
    return 0;
}
var failures = 0;
var failedLabels = new List<string>();
void Check(bool ok, string label)
{
    Console.WriteLine((ok ? "PASS: " : "FAIL: ") + label);
    if (!ok) { failures++; failedLabels.Add(label); }
}
byte[] FixedKey(byte value)
{
    var key = new byte[32];
    Array.Fill(key, value);
    return key;
}
byte[] Utf8(string value) => System.Text.Encoding.UTF8.GetBytes(value);

// Loopback peers can still flush a store write while a test tears down;
// retry cleanup instead of crashing the whole run on a busy directory.
void Cleanup(params string[] dirs)
{
    foreach (var dir in dirs)
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
                break;
            }
            catch when (attempt < 8) { Thread.Sleep(100); }
        }
}

// Groups admission helper: home owns a group, the joiner connects with
// intent, the sponsor approves its own pending request, and the joiner's
// PairingConfirmation callback presses Pair. Returns when both sides agree.
async Task<bool> JoinPair(DeviceSyncService home, DeviceSyncService joiner, Func<bool> done)
{
    if (home.CurrentGroup is null) await home.CreateGroupAsync("Test Group");
    // A first-run firewall prompt can stall the opening sockets; retry the
    // dial while the sponsor still sees no request instead of failing setup.
    var dialDeadline = DateTime.UtcNow.AddSeconds(45);
    while (home.GroupRequests.Count == 0 && DateTime.UtcNow < dialDeadline)
    {
        // Redial only while the joiner also shows no prompt: a slow first
        // attempt must not become a duplicate request.
        if (joiner.GroupPairingPrompts.Count == 0)
            await joiner.ConnectManualAsync("127.0.0.1", home.ListeningPort, home.CurrentGroup!.Id);
        var slice = DateTime.UtcNow.AddSeconds(15);
        while (home.GroupRequests.Count == 0 && DateTime.UtcNow < slice) await Task.Delay(25);
    }
    if (home.GroupRequests.Count == 0) return false;
    await home.ReviewGroupRequestAsync(home.GroupRequests[0]);
    await home.ApproveGroupReviewAsync();
    var doneDeadline = DateTime.UtcNow.AddSeconds(15);
    while (!done() && DateTime.UtcNow < doneDeadline) await Task.Delay(25);
    return done();
}

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

// Restart/crash safety: durable sequence reservations and lease generations.
{
    var root = Directory.CreateTempSubdirectory("converse-counters-").FullName;
    try
    {
        var first = new DeviceSyncCounters(root);
        var last = 0UL;
        for (var n = 0; n < 5000; n++) last = first.NextSequence();
        var session = Guid.NewGuid();
        Check(first.SaveEpochs(new() { [session] = 7 }), "Sync counters persist lease epochs");
        var restarted = new DeviceSyncCounters(root);
        Check(restarted.NextSequence() > last && restarted.Boot > first.Boot && restarted.Epochs[session] == 7,
            "Sync counters reserve beyond issued range and retain epochs after restart");
        Check(!restarted.SaveEpochs(new() { [session] = 6 }), "Sync counters refuse lease epoch rollback");
        var file = Path.Combine(root, "device-sync-counters.json");
        File.Move(file, file + ".backup"); Directory.CreateDirectory(file);
        Check(!restarted.SaveEpochs(new() { [session] = 8 }) && restarted.Epochs[session] == 7,
            "Sync counter write failure does not grant or adopt a lease epoch");
        var refused = false;
        try { for (var n = 0; n < 4096; n++) restarted.NextSequence(); } catch (IOException) { refused = true; }
        catch (UnauthorizedAccessException) { refused = true; }
        Check(refused, "Sync sequence cannot escape its reserved range after persistence failure");
        Directory.Delete(file); File.WriteAllText(file, "{\"Boot\":4}");
        refused = false;
        try { _ = new DeviceSyncCounters(root); } catch (System.Text.Json.JsonException) { refused = true; }
        Check(refused, "Incomplete sync counter state fails closed instead of resetting generations");
    }
    finally { Cleanup(root); }
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
    finally { Cleanup(root); }
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
    finally { Cleanup(root); }
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
        await home.StartAsync(0); // Default service startup must remain loopback-only.
        await viewer.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        var listeners = System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners();
        Check(listeners.Any(e => e.Port == home.ListeningPort && e.Address.Equals(System.Net.IPAddress.Loopback)) &&
              !listeners.Any(e => e.Port == home.ListeningPort && !System.Net.IPAddress.IsLoopback(e.Address)),
              "Default device startup listens on loopback only, never LAN interfaces");
        async Task<bool> Until(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        var gid = new DeviceGlobalID(home.DeviceId, homeSession.Id).ToString();
        Check(await JoinPair(home, viewer, () => viewer.Homes.GetValueOrDefault(home.DeviceId)?.Rows.Any(r => r.GlobalID == gid) == true), "Loopback pairing publishes home sidebar");
        await viewer.AcquireRemoteAsync(gid);
        Check(await Until(() => viewer.RemoteTranscripts.GetValueOrDefault(gid)?.Draft == "home words"), "Loopback take streams home draft snapshot");
        var commandId = await viewer.SendRemoteCommandAsync(gid, new DeviceCommandPayload { Action = "rename", Text = "Renamed from viewer" });
        Check(commandId is not null && await Until(() => homeSession.Title == "Renamed from viewer" && viewer.Unresolved(gid).Count == 0), "Loopback rename applies once on home and clears outbox");
        homeSession.Title = "Renamed on home while viewed remotely";
        homeSession.Draft = "keep this draft";
        homeStore.Save();
        Check(await Until(() => viewer.RemoteTranscripts.GetValueOrDefault(gid)?.Title == homeSession.Title
            && viewer.Homes[home.DeviceId].Rows.Any(r => r.GlobalID == gid && r.Title == homeSession.Title)),
            "Home rename updates both remote pane snapshot and sidebar without a new turn");
        // Make the previous process's counter larger than a fresh process's
        // startup traffic, exactly the condition rejected by a Mac viewer.
        for (var n = 0; n < 40; n++) homeStore.Save();
        await viewer.ReleaseRemoteAsync(gid);
        await viewer.AcquireRemoteAsync(gid);
        Check(await Until(() => viewer.RemoteTranscripts.GetValueOrDefault(gid)?.Epoch > 1), "Restart setup refreshes the held snapshot");
        var oldSnapshot = viewer.RemoteTranscripts[gid];
        home.Dispose();
        await Until(() => !viewer.Homes[home.DeviceId].Online);
        var restartedStore = new SessionStore(homeRoot, new FakeRunner());
        var restartedSession = restartedStore.Sessions.Single(s => s.Id == homeSession.Id);
        restartedSession.Title = "Renamed after restart";
        restartedStore.Save();
        using var restarted = new DeviceSyncService(homeRoot, restartedStore, "HomePC");
        await restarted.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await viewer.ConnectManualAsync("127.0.0.1", restarted.ListeningPort);
        Check(await Until(() => viewer.Homes.GetValueOrDefault(home.DeviceId)?.Rows.Any(r => r.Title == restartedSession.Title) == true),
            "Restart reconnect publishes current title without pairing again");
        await viewer.AcquireRemoteAsync(gid);
        Check(await Until(() => viewer.RemoteTranscripts.GetValueOrDefault(gid)?.Title == restartedSession.Title), "Restart allows a fresh take");
        var fresh = viewer.RemoteTranscripts.GetValueOrDefault(gid);
        Check(fresh is not null && fresh.HomeSeq > oldSnapshot.HomeSeq,
            "Restart snapshot advances HomeSeq beyond previous process for Mac viewer acceptance");
        Check(fresh is not null && fresh.Boot > oldSnapshot.Boot && fresh.Epoch > oldSnapshot.Epoch,
            "Restart changes boot and advances lease epoch so old snapshots cannot match");
        Check(fresh?.Draft == "keep this draft", "Rename and restart preserve the remote draft");

    }
    finally
    {
        Cleanup(homeRoot);
        Cleanup(viewerRoot);
    }
}

// A live takeover must notify the displaced viewer immediately, not at TTL.
{
    var roots = Enumerable.Range(0, 3).Select(_ => Directory.CreateTempSubdirectory("converse-takeover-").FullName).ToArray();
    try
    {
        var store = new SessionStore(roots[0], new FakeRunner());
        var session = store.Create(store.Entries.First(e => e.Engine == "codex"));
        session.Draft = "takeover draft";
        using var home = new DeviceSyncService(roots[0], store, "TakeoverHome");
        using var a = new DeviceSyncService(roots[1], new SessionStore(roots[1], new FakeRunner()), "ViewerA");
        using var b = new DeviceSyncService(roots[2], new SessionStore(roots[2], new FakeRunner()), "ViewerB");
        foreach (var service in new[] { home, a, b })
        {
            service.PairingConfirmation = _ => Task.FromResult(true);
            await service.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        }
        async Task<bool> UntilTakeover(Func<bool> done)
        {
            // Strictly below the 15-second lease expiry: expiry cannot pass this test.
            var deadline = DateTime.UtcNow.AddSeconds(3);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(10);
            return done();
        }
        string? holderSeenByUI = "not refreshed";
        home.Changed += () => holderSeenByUI = home.DisplayHolder(session.Id)?.Device;
        var gid = new DeviceGlobalID(home.DeviceId, session.Id).ToString();
        Check(await JoinPair(home, a, () => a.Homes.GetValueOrDefault(home.DeviceId)?.Rows.Any(r => r.GlobalID == gid) == true)
            && await JoinPair(home, b, () => b.Homes.GetValueOrDefault(home.DeviceId)?.Rows.Any(r => r.GlobalID == gid) == true),
            "Takeover regression pairs a home and two viewers");
        await a.AcquireRemoteAsync(gid);
        Check(await UntilTakeover(() => a.RemoteTranscripts.ContainsKey(gid))
            && home.DisplayHolder(session.Id) is { } firstHolder && firstHolder.Device == a.DeviceId
            && firstHolder.Epoch == a.RemoteLeases.GetValueOrDefault(gid),
            "Display holder reports the actual viewer and granted epoch");
        Check(await UntilTakeover(() => holderSeenByUI == a.DeviceId),
            "Lease grant refreshes the home UI so it can park the local pane immediately");
        var firstEpoch = a.RemoteLeases.GetValueOrDefault(gid);
        // A redundant dial loses arbitration; its close callback must not
        // invalidate the existing trusted connection or its display lease.
        await a.ConnectManualAsync("127.0.0.1", home.ListeningPort);
        await Task.Delay(250);
        Check(a.Homes.GetValueOrDefault(home.DeviceId)?.Online == true && a.RemoteLeases.GetValueOrDefault(gid) == firstEpoch && a.RemoteTranscripts.ContainsKey(gid),
            "Discarded duplicate connection preserves the live viewer lease and online state");
        await a.AcquireRemoteAsync(gid);
        Check(a.RemoteLeases.GetValueOrDefault(gid) == firstEpoch && a.RemoteTranscripts.ContainsKey(gid),
            "Repeated Take on the current viewer keeps its live transcript and lease");
        await b.AcquireRemoteAsync(gid);
        Check(await UntilTakeover(() => b.RemoteTranscripts.ContainsKey(gid)
            && !a.RemoteLeases.ContainsKey(gid) && !a.RemoteTranscripts.ContainsKey(gid)),
            "Live takeover sends stolen notice and clears the displaced viewer before lease expiry");
        Check(home.DisplayHolder(session.Id) is { } secondHolder && secondHolder.Device == b.DeviceId
            && secondHolder.Epoch > firstEpoch && secondHolder.Epoch == b.RemoteLeases.GetValueOrDefault(gid),
            "Takeover holder advances to the new viewer at its granted epoch");
        Check(await UntilTakeover(() => holderSeenByUI == b.DeviceId),
            "Takeover refreshes the home UI with the new display holder");
        string? displacedView = null;
        b.RemoteViewDisplaced += value => displacedView = value;
        var remoteEpoch = b.RemoteLeases[gid];
        Check(await home.AcquireLocalAsync(session.Id) && await UntilTakeover(() =>
            !b.RemoteLeases.ContainsKey(gid) && !b.RemoteTranscripts.ContainsKey(gid) && displacedView == gid)
            && home.DisplayHolder(session.Id) is { } localHolder && localHolder.Device == home.DeviceId && localHolder.Epoch > remoteEpoch,
            "Home take immediately fences and parks the remote viewer without requiring remote Park");
        Check(session.Draft == "takeover draft" && holderSeenByUI == home.DeviceId,
            "Home take preserves the shared draft and refreshes home placement authority");
        var localEpoch = home.DisplayHolder(session.Id)!.Value.Epoch;
        Check(await home.AcquireLocalAsync(session.Id) && home.DisplayHolder(session.Id)?.Epoch == localEpoch,
            "Repeated home pane clicks keep the same local display fence");
        await b.ReleaseRemoteAsync(gid);
        Check(home.DisplayHolder(session.Id)?.Device == home.DeviceId,
            "Parked viewer release cannot release the home's new display fence");
        await b.AcquireRemoteAsync(gid);
        Check(await UntilTakeover(() => b.RemoteTranscripts.ContainsKey(gid) && home.DisplayHolder(session.Id)?.Device == b.DeviceId),
            "Remote viewer can take the session back again after a home take");
        await b.ReleaseRemoteAsync(gid);
        Check(await UntilTakeover(() => home.DisplayHolder(session.Id) is null && holderSeenByUI is null),
            "Display holder clears and refreshes the home UI on release");
    }
    finally { Cleanup(roots); }
}

// Remote inject honesty (Mac failed-ack parity) + double-press guard.
{
    var homeRoot = Directory.CreateTempSubdirectory("converse-injhome-").FullName;
    var viewerRoot = Directory.CreateTempSubdirectory("converse-injviewer-").FullName;
    try
    {
        var homeStore = new SessionStore(homeRoot, new FakeRunner());
        var homeSession = homeStore.Create(homeStore.Entries.First(e => e.Engine == "codex"));
        using var home = new DeviceSyncService(homeRoot, homeStore, "HomePC");
        using var viewer = new DeviceSyncService(viewerRoot, new SessionStore(viewerRoot, new FakeRunner()), "ViewerPC");
        home.PairingConfirmation = _ => Task.FromResult(true);
        viewer.PairingConfirmation = _ => Task.FromResult(true);
        await home.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await viewer.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        async Task<bool> Until(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        var gid = new DeviceGlobalID(home.DeviceId, homeSession.Id).ToString();
        Check(await JoinPair(home, viewer, () => viewer.Homes.GetValueOrDefault(home.DeviceId)?.Rows.Any(r => r.GlobalID == gid) == true), "Inject loopback pairing publishes home sidebar");
        await viewer.AcquireRemoteAsync(gid);
        Check(await Until(() => viewer.RemoteLeases.ContainsKey(gid)), "Inject loopback take holds a lease");
        var failed = await viewer.SendRemoteCommandAsync(gid, new DeviceCommandPayload { Action = "injectAll" });
        Check(failed is not null && await Until(() => viewer.Unresolved(gid)
            .Any(r => r.CommandID == failed && r.Outcome == "failed" && (r.Detail ?? "").Contains("already empty"))),
            "Remote inject on an empty queue fails honestly");
        viewer.DiscardOutbox(failed!.Value);
        // Both sends start before either ack returns: the second must reuse
        // the outstanding command instead of sending a duplicate interrupt.
        var first = viewer.SendRemoteCommandAsync(gid, new DeviceCommandPayload { Action = "injectAll" });
        var second = viewer.SendRemoteCommandAsync(gid, new DeviceCommandPayload { Action = "injectAll" });
        var ids = await Task.WhenAll(first, second);
        Check(ids[0] is not null && ids[0] == ids[1]
            && viewer.Outbox.Count(r => r.SessionID == gid && r.Payload.Action == "injectAll") == 1,
            "Double inject reuses the outstanding command");
    }
    finally
    {
        Cleanup(homeRoot);
        Cleanup(viewerRoot);
    }
}

// A completed remote turn pushes its final transcript to the lease holder:
// without the push the viewer keeps the turn-start snapshot ("working")
// forever, because the viewer never polls latest text.
{
    var homeRoot = Directory.CreateTempSubdirectory("converse-push-").FullName;
    var viewerRoot = Directory.CreateTempSubdirectory("converse-pushviewer-").FullName;
    try
    {
        var homeRunner = new FakeRunner { Gate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously) };
        var homeStore = new SessionStore(homeRoot, homeRunner);
        var homeSession = homeStore.Create(homeStore.Entries.First(e => e.Engine == "codex"));
        using var home = new DeviceSyncService(homeRoot, homeStore, "HomePC");
        using var viewer = new DeviceSyncService(viewerRoot, new SessionStore(viewerRoot, new FakeRunner()), "ViewerPC");
        home.PairingConfirmation = _ => Task.FromResult(true);
        viewer.PairingConfirmation = _ => Task.FromResult(true);
        await home.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await viewer.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        async Task<bool> UntilPush(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        var gid = new DeviceGlobalID(home.DeviceId, homeSession.Id).ToString();
        Check(await JoinPair(home, viewer, () => viewer.Homes.GetValueOrDefault(home.DeviceId)?.Rows.Any(r => r.GlobalID == gid) == true), "Push setup pairs home and viewer");
        await viewer.AcquireRemoteAsync(gid);
        Check(await UntilPush(() => viewer.RemoteLeases.ContainsKey(gid)), "Push setup viewer holds the lease");
        var submit = await viewer.SendRemoteCommandAsync(gid, new DeviceCommandPayload { Action = "submit", Text = "say hello" });
        Check(submit is not null && await UntilPush(() => homeSession.Busy), "Push setup remote submit starts the home turn");
        Check(await UntilPush(() => viewer.Homes.GetValueOrDefault(home.DeviceId)?.Rows.Any(r => r.GlobalID == gid && r.Busy) == true), "Gated turn shows busy on the viewer sidebar");
        Check(viewer.RemoteTranscripts.GetValueOrDefault(gid)?.Messages.Any(m => m.Text.Contains("fake reply")) != true, "Gated turn has not leaked its reply yet");
        homeRunner.Gate!.TrySetResult(true);
        Check(await UntilPush(() => !homeSession.Busy), "Push setup home turn completes");
        Check(await UntilPush(() => viewer.RemoteTranscripts.GetValueOrDefault(gid) is { } pushed && !pushed.Busy
            && pushed.Messages.Any(m => m.Text.Contains("fake reply"))), "Completed turn pushes its final transcript to the holder");
        Check(await UntilPush(() => viewer.Homes.GetValueOrDefault(home.DeviceId)?.Rows.Any(r => r.GlobalID == gid && !r.Busy && r.Status == "Ready") == true), "Completed turn clears the viewer sidebar busy");
    }
    finally
    {
        Cleanup(homeRoot);
        Cleanup(viewerRoot);
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
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (session.Requests.Count == 0 && DateTime.UtcNow < deadline) await Task.Delay(25);
        Check(session.Requests.Count == 1 && session.Requests[0].Kind == "approval", "MSP approval request surfaces on session");
        if (session.Requests.Count == 1)
            Check(await store.AnswerMuseAsync(session, session.Requests[0], choice: "deny"), "MSP approval decision accepted by client");
        // Fresh budget per phase: sharing one deadline across the request
        // wait and the turn wait starves the second phase on slow machines.
        deadline = DateTime.UtcNow.AddSeconds(30);
        while (session.Busy && DateTime.UtcNow < deadline) await Task.Delay(25);
        Check(decidedChoice == "deny" && session.Status == "Ready", "MSP decide reaches host and turn completes");
    }
    finally
    {
        listener.Stop();
        Cleanup(root);
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

// Entry naming: claude engine is "Claude" (Mac parity), with migration for old stores.
{
    var entries = Converse.Core.SessionStore.DefaultEntries();
    Check(entries.Count == 3 && entries[0].Name == "Claude" && entries[1].Name == "Codex" && entries[2].Name == "Muse",
        "Default entries are named Claude, Codex, Muse");
    var dir = Directory.CreateTempSubdirectory("converse-entries-").FullName;
    var entryJson = "{\"Name\":\"Muse\",\"Command\":\"claude\",\"Directory\":\"C:\\\\u\",\"Engine\":\"claude\"}";
    File.WriteAllText(Path.Combine(dir, "sessions.json"),
        "{\"Entries\":[" + entryJson + "],\"Sessions\":["
        + "{\"Id\":\"" + Guid.NewGuid() + "\",\"Entry\":" + entryJson + ",\"Title\":\"Muse\",\"Messages\":[]},"
        + "{\"Id\":\"" + Guid.NewGuid() + "\",\"Entry\":" + entryJson + ",\"Title\":\"My chat\",\"Messages\":[]}]}");
    var store = new Converse.Core.SessionStore(dir, new FakeRunner());
    var untouched = store.Sessions.Single(s => s.Title == "My chat");
    Check(store.Entries.Count == 1 && store.Entries[0].Name == "Claude" && store.Entries[0].Command == "claude"
        && store.Sessions.Single(s => s.Entry.Name == "Claude" && s.Title == "Claude") is not null
        && untouched.Entry.Name == "Claude",
        "Stored claude entry misnamed Muse migrates to Claude, including session copies and default titles");
}

// Command resolution: .exe preferred, npm .cmd shims wrapped in cmd.exe with safe quoting.
{
    var bin = Directory.CreateTempSubdirectory("converse-bin-").FullName;
    var npm = Directory.CreateTempSubdirectory("converse-npm-").FullName;
    File.WriteAllText(Path.Combine(npm, "codex.cmd"),
        "@ECHO off\r\nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & \"%_prog%\"  \"%dp0%\\node_modules\\@openai\\codex\\bin\\codex.js\" %*\r\n");
    Directory.CreateDirectory(Path.Combine(npm, "node_modules", "@openai", "codex", "bin"));
    File.WriteAllText(Path.Combine(npm, "node_modules", "@openai", "codex", "bin", "codex.js"), "");
    File.WriteAllText(Path.Combine(npm, "node.exe"), "");
    var shim = Converse.Core.CommandResolution.Resolve("codex", true, new[] { bin, npm });
    Check(shim is not null && shim.FileName == Path.Combine(npm, "node.exe")
          && shim.PrefixArguments.Count == 1 && shim.PrefixArguments[0].EndsWith("codex.js") && !shim.UsesCmd,
        "Standard npm .cmd shim unwraps to node + script, never cmd.exe");
    File.WriteAllText(Path.Combine(npm, "claude.cmd"), "@ECHO off\r\n\"%dp0%\\node_modules\\x\\cli.js\" %*\r\n");
    File.WriteAllText(Path.Combine(bin, "claude.exe"), "");
    var native = Converse.Core.CommandResolution.Resolve("claude", true, new[] { npm, bin });
    Check(native is not null && native.FileName == Path.Combine(bin, "claude.exe") && native.PrefixArguments.Count == 0,
        "Native .exe wins over a shim in an earlier directory");
    Check(Converse.Core.CommandResolution.Resolve("muse", true, new[] { bin, npm }) is null,
        "Missing CLI resolves to null so Setup reports it not found");
    var absolute = Path.Combine(bin, "claude.exe");
    Check(Converse.Core.CommandResolution.Resolve(absolute, true, Array.Empty<string>())?.FileName == absolute,
        "Absolute command path is used as-is");
    File.WriteAllText(Path.Combine(bin, "weird.cmd"), "@ECHO off\r\ncustom-launcher %*\r\n");
    var fallback = Converse.Core.CommandResolution.Resolve("weird", true, new[] { bin });
    Check(fallback is not null && fallback.UsesCmd && fallback.CmdPrefix == "\"" + Path.Combine(bin, "weird.cmd") + "\"",
        "Unparseable .cmd shim falls back to a quoted cmd.exe wrapper");
    var quoted = Converse.Core.CommandResolution.QuoteCmdArg("say \"hi\" & 100% | done ^<>");
    Check(quoted == "\"say \"\"hi\"\" & 100%% | done ^<>\"",
        "cmd quoting doubles quotes and percents, leaving metachars literal inside quotes");
    var psi = new System.Diagnostics.ProcessStartInfo();
    Converse.Core.CommandResolution.Apply(psi, fallback!, new[] { "--print", "a&b" });
    Check(psi.FileName.EndsWith("cmd.exe", StringComparison.OrdinalIgnoreCase)
        && psi.Arguments.StartsWith("/d /s /c \"") && psi.Arguments.Contains("\"a&b\""),
        "cmd wrapper builds a /d /s /c line with quoted prompt text");
    var psi2 = new System.Diagnostics.ProcessStartInfo();
    Converse.Core.CommandResolution.Apply(psi2, shim!, new[] { "--print", "hi" });
    Check(psi2.FileName.EndsWith("node.exe") && psi2.ArgumentList.Count == 3 && psi2.ArgumentList[1] == "--print",
        "node unwrap prepends the script ahead of CLI arguments");
    var fabric = Directory.CreateTempSubdirectory("converse-fabric-").FullName;
    var key = Convert.ToBase64String(new byte[32]);
    File.WriteAllText(Path.Combine(fabric, "devices.json"),
        "[{\"deviceID\":\"aa\",\"name\":\"Mac\",\"publicKey\":\"" + key + "\",\"lastHost\":\"10.0.0.2\",\"lastPort\":48721,\"generation\":1,\"removed\":false},"
        + "{\"deviceID\":\"bb\",\"name\":\"Gone\",\"publicKey\":\"" + key + "\",\"generation\":3,\"removed\":true},"
        + "{\"name\":\"NoId\",\"publicKey\":\"" + key + "\"}]");
    var trust = new Converse.Core.DeviceTrustStore(fabric);
    Check(trust.Devices.Count == 1 && trust.Devices[0].DeviceID == "aa" && trust.Devices[0].LastPort == 48721,
        "Fabric-format devices.json (camelCase, tombstones) loads without null IDs");
}

// Choices catalog: per-engine access/effort options for the settings row.
{
    var claude = Converse.Core.ChoicesCatalog.AccessFor("claude");
    Check(claude.Count == 6 && claude.Any(o => o.Id == "manual") && claude.Any(o => o.Id == "bypassPermissions"),
        "Claude access matches CLI permission-mode vocabulary");
    var codex = Converse.Core.ChoicesCatalog.AccessFor("codex");
    Check(codex.Count == 3 && codex[0].Id == "read-only",
        "Codex access offers sandbox modes");
    var museEfforts = Converse.Core.ChoicesCatalog.EffortsFor("muse");
    Check(museEfforts.Contains("ultra") && museEfforts.Contains("none"),
        "Muse efforts match CLI reasoning-effort vocabulary");
    var clean = Converse.Core.ChoicesCatalog.EffortsFor("claude")
        .Concat(Converse.Core.ChoicesCatalog.EffortsFor("codex"))
        .Concat(museEfforts)
        .All(e => e.Length > 0 && !e.Any(char.IsWhiteSpace));
    Check(clean && Converse.Core.ChoicesCatalog.AccessFor("unknown").Count == 0,
        "Effort ids are CLI-safe tokens; unknown engines offer nothing");
    var session = new Converse.Core.ChatSession
    {
        Entry = new Converse.Core.AgentEntry { Engine = "claude" },
        Choices = new Converse.Core.SessionChoices { Access = "default" },
    };
    var turnArgs = Converse.Core.TurnArguments.For(session, Array.Empty<string>());
    var mode = turnArgs.SkipWhile(a => a != "--permission-mode").Skip(1).FirstOrDefault();
    Check(mode == "manual", "Mac legacy access id 'default' normalizes to CLI 'manual'");
}

// Editor boundary: RichEdit GetText normalization must not eat keystrokes.
{
    var history = "You: hi\r\r";
    var exact = Converse.Core.EditorBoundary.Split("You: hi\r\rhello\r", history, 15);
    Check(exact.HistoryOk && exact.Draft == "hello", "Exact history match splits the draft tail");
    var collapsed = Converse.Core.EditorBoundary.Split("You: hi\rhello\r", history, 14);
    Check(collapsed.HistoryOk && collapsed.Draft == "hello", "Collapsed trailing break still matches history");
    var terminator = Converse.Core.EditorBoundary.Split("You: hi\r\r\r", history, 11);
    Check(terminator.HistoryOk && terminator.Draft == "", "Lone GetText terminator leaves an empty draft");
    var hacked = Converse.Core.EditorBoundary.Split("You: HACKED\r\rhello\r", history, 20);
    Check(!hacked.HistoryOk, "Edited history fails the protected-region check");
    var fresh = Converse.Core.EditorBoundary.Split("hello\r", "", 6);
    Check(fresh.HistoryOk && fresh.Draft == "hello", "Empty history accepts first keystrokes");
    var leading = Converse.Core.EditorBoundary.Split("H\r\r\rhello\r", "H\r\r", 11);
    Check(leading.HistoryOk && leading.Draft == "\rhello", "Genuine leading draft blank lines survive the separator budget");
}

// Model options: verified claude aliases ride the home snapshot.
{
    var claude = Converse.Core.ChoicesCatalog.ModelsFor("claude");
    Check(claude.Select(o => o.Id).SequenceEqual(new[] { "fable", "opus", "sonnet" }),
        "Claude model aliases match verified CLI vocabulary");
    Check(Converse.Core.ChoicesCatalog.ModelsFor("muse").Count == 0
        && Converse.Core.ChoicesCatalog.ModelsFor("codex").Count == 0
        && Converse.Core.ChoicesCatalog.ModelsFor("unknown").Count == 0,
        "Other engines offer no static models (live or free text, Mac parity)");
}

// Prepend merge: earlier pages merge ahead with ID dedup.
{
    DeviceWireMessage Wire(string text) => new() { Id = Guid.NewGuid(), Role = "user", Text = text };
    var old = new DeviceTranscriptPayload { HomeSeq = 7, Offset = 50, Total = 250,
        Messages = new List<DeviceWireMessage> { Wire("new-1"), Wire("new-2") } };
    var paged = new DeviceTranscriptPayload { HomeSeq = 9, Offset = 0, Total = 250, Prepend = true,
        Messages = new List<DeviceWireMessage> { old.Messages[1], Wire("old-0") } };
    var merged = Converse.Core.DeviceSyncService.MergePrepend(old, paged);
    Check(merged.Offset == 0 && merged.Total == 250
        && merged.Messages.Select(m => m.Text).SequenceEqual(new[] { "new-2", "old-0", "new-1" }),
        "Earlier page merges ahead exactly once by message ID");
}

// Request views: local Muse requests project like remote DTOs; answers use Mac keys.
{
    var local = new Converse.Core.MuseRequest { Id = "a1", Kind = "approval",
        Params = (System.Text.Json.Nodes.JsonNode.Parse(
            "{\"toolName\":\"Bash\",\"rawArgs\":\"ls\",\"availableChoices\":[{\"choiceId\":\"allow-once\",\"label\":\"Allow once\",\"scope\":\"session\"}]}")!
            .AsObject()) };
    var approval = Converse.Core.RequestViews.FromLocal(local);
    Check(approval.Kind == "approval" && approval.ToolName == "Bash" && approval.RawArgs == "ls"
        && approval.Choices.Count == 1 && approval.Choices[0].Detail == "session",
        "Local approval projects tool, args and choice detail");
    var remote = new DeviceRequestDto { Id = "q1", Kind = "question",
        QuestionsJson = Utf8("[{\"id\":\"q1\",\"question\":\"Pick one\",\"options\":[{\"label\":\"A\"},{\"label\":\"B\",\"description\":\"desc\"}]},"
            + "{\"id\":\"q2\",\"question\":\"Pick many\",\"selection\":{\"mode\":\"multiple\"},\"options\":[{\"label\":\"X\"},{\"label\":\"Y\"}]}]") };
    var view = Converse.Core.RequestViews.FromRemote(remote);
    Check(view.Questions.Count == 2 && !view.Questions[0].Multiple && view.Questions[1].Multiple
        && view.Questions[0].Options[1].Description == "desc",
        "Remote questions parse options and single/multi selection");
    var answers = System.Text.Encoding.UTF8.GetString(Converse.Core.RequestViews.BuildAnswersJson(view,
        new Dictionary<string, HashSet<string>> { ["q1"] = new() { "B", "bogus" }, ["q2"] = new() { "X", "Y" } },
        new Dictionary<string, string> { ["q1"] = "  ", ["q2"] = " extra " }));
    Check(answers == "[{\"questionId\":\"q1\",\"selectedLabel\":\"B\"},{\"questionId\":\"q2\",\"selectedLabels\":[\"X\",\"Y\"],\"freeText\":\"extra\"}]",
        "Question answers use Mac keys and drop unknown labels and blank text");
    Check(Converse.Core.RequestViews.ParseQuestions("not json").Count == 0
        && Converse.Core.RequestViews.ParseQuestions(null).Count == 0,
        "Malformed questions JSON parses to no questions");
}

// Line-number gutter preference persists with the window layout, default on.
{
    var layout = new Converse.Core.SidebarLayoutState();
    Check(layout.ShowLineNumbers, "Line numbers default on (Mac parity)");
    var dir = Directory.CreateTempSubdirectory("converse-gutter-").FullName;
    File.WriteAllText(Path.Combine(dir, "window-layout.json"), "{\"Collapsed\":false,\"ExpandedWidth\":340}");
    Check(Converse.Core.SidebarLayoutState.Load(dir).ShowLineNumbers,
        "Layout files predating the gutter still default it on");
    layout.ShowLineNumbers = false;
    layout.Save(dir);
    Check(!Converse.Core.SidebarLayoutState.Load(dir).ShowLineNumbers,
        "Gutter preference round-trips through save and load");
}

// Loopback round two: model options, earlier paging, blob upload with an
// attached submit, and outbox query/retry/discard over real TCP.
{
    var homeRoot = Directory.CreateTempSubdirectory("converse-home2-").FullName;
    var viewerRoot = Directory.CreateTempSubdirectory("converse-viewer2-").FullName;
    try
    {
        var homeStore = new SessionStore(homeRoot, new FakeRunner());
        var homeSession = homeStore.Create(homeStore.Entries.First(e => e.Engine == "claude"));
        homeSession.Messages.Clear();
        for (var i = 0; i < 250; i++)
            homeSession.Messages.Add(new ChatMessage { Role = i % 2 == 0 ? "user" : "assistant", Text = "m" + i });
        using var home = new DeviceSyncService(homeRoot, homeStore, "HomePC");
        using var viewer = new DeviceSyncService(viewerRoot, new SessionStore(viewerRoot, new FakeRunner()), "ViewerPC");
        home.PairingConfirmation = _ => Task.FromResult(true);
        viewer.PairingConfirmation = _ => Task.FromResult(true);
        await home.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await viewer.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        async Task<bool> Until(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        var gid = new DeviceGlobalID(home.DeviceId, homeSession.Id).ToString();
        Check(await JoinPair(home, viewer, () => viewer.Homes.GetValueOrDefault(home.DeviceId)?.Rows.Any(r => r.GlobalID == gid) == true),
            "Round-two pairing publishes the claude home sidebar");
        await viewer.AcquireRemoteAsync(gid);
        Check(await Until(() => viewer.RemoteTranscripts.GetValueOrDefault(gid) is { } t
            && t.ModelOptions.Select(o => o.Id).SequenceEqual(new[] { "fable", "opus", "sonnet" })
            && t.Offset == 50 && t.Messages.Count == 200),
            "Take streams model options with a 200-message tail at offset 50");
        await viewer.RequestEarlierAsync(gid);
        Check(await Until(() => viewer.RemoteTranscripts.GetValueOrDefault(gid) is { } t
            && t.Offset == 0 && t.Messages.Count == 250 && t.Messages.First().Text == "m0"),
            "Earlier page merges ahead to the full 250 messages");
        var png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV9sAAAAASUVORK5CYII=");
        var hash = await viewer.UploadBlobAsync(gid, png);
        Check(hash == DeviceBlob.Sha256Hex(png), "Blob upload returns the content hash");
        Check(viewer.BlobPath(hash!) is { } previewPath && File.ReadAllBytes(previewPath).SequenceEqual(png), "Remote draft upload retains exact local preview bytes");
        var attached = await viewer.SendRemoteCommandAsync(gid,
            new DeviceCommandPayload { Action = "submit", Text = "with image", BlobHashes = new[] { hash! } });
        Check(attached is not null && await Until(() =>
            homeSession.Messages.Any(m => m.Role == "user" && m.Text == "with image" && m.Images.Count == 1 && File.Exists(m.Images[0]))
            && viewer.Unresolved(gid).Count == 0), "Submit with an uploaded hash stores home-side bytes once");
        var failed = await viewer.SendRemoteCommandAsync(gid, new DeviceCommandPayload { Action = "submit", Text = "  " });
        Check(failed is not null && await Until(() =>
            viewer.Unresolved(gid).FirstOrDefault(r => r.CommandID == failed)?.Outcome == "failed"),
            "Empty submit records a failed outbox entry with content retained");
        var record = viewer.Unresolved(gid).First(r => r.CommandID == failed);
        await viewer.QueryOutboxAsync(record);
        Check(await Until(() =>
            viewer.Unresolved(gid).FirstOrDefault(r => r.CommandID == failed)?.Detail == "Home record lookup."),
            "Outbox query returns the authoritative home outcome");
        Check(await viewer.RetryOutboxAsync(record)
            && await Until(() => viewer.Unresolved(gid).Any(r => r.CommandID == failed && r.Outcome == "failed")),
            "Retry resends under the original ID and home dedups the replay");
        viewer.DiscardOutbox(failed.Value);
        Check(viewer.Unresolved(gid).Count == 0, "Discard drops the outbox record");
    }
    finally
    {
        Cleanup(homeRoot);
        Cleanup(viewerRoot);
    }
}

// AtomicJson: concurrent saves of one store cannot collide on Windows.
{
    var root = Directory.CreateTempSubdirectory("converse-atomic-").FullName;
    try
    {
        var file = Path.Combine(root, "store.json");
        var tasks = Enumerable.Range(0, 8).Select(worker => Task.Run(() =>
        {
            for (var i = 0; i < 25; i++) Converse.Core.AtomicJson.Write(file, new { worker, i });
        })).ToArray();
        Task.WaitAll(tasks);
        var back = System.Text.Json.JsonDocument.Parse(File.ReadAllBytes(file));
        Check(back.RootElement.TryGetProperty("worker", out _), "Concurrent atomic saves never throw and leave valid JSON");
    }
    finally { Cleanup(root); }
}

// devices.json merge-preserve: fabric extras and tombstones survive our saves.
{
    var dir = Directory.CreateTempSubdirectory("converse-merge-").FullName;
    var key = Convert.ToBase64String(new byte[32]);
    File.WriteAllText(Path.Combine(dir, "devices.json"),
        "[{\"deviceID\":\"aa\",\"name\":\"Mac\",\"publicKey\":\"" + key + "\",\"generation\":4,\"changedBy\":\"aa\",\"custom\":true},"
        + "{\"deviceID\":\"bb\",\"name\":\"Gone\",\"publicKey\":\"" + key + "\",\"generation\":9,\"removed\":true},"
        + "{\"DeviceID\":\"cc\",\"Name\":\"Old\",\"PublicKey\":\"" + key + "\"}]");
    var trust = new Converse.Core.DeviceTrustStore(dir);
    Check(trust.Devices.Count == 2, "Merge setup loads live entries and skips tombstones");
    trust.Pin(new Converse.Core.TrustedDevice("dd", "New", new byte[32], "h", 1));
    var saved = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(Path.Combine(dir, "devices.json")))!.AsArray();
    var aa = saved.OfType<System.Text.Json.Nodes.JsonObject>().First(o => o["deviceID"]?.GetValue<string>() == "aa");
    var bb = saved.OfType<System.Text.Json.Nodes.JsonObject>().First(o => o["deviceID"]?.GetValue<string>() == "bb");
    var cc = saved.OfType<System.Text.Json.Nodes.JsonObject>().First(o => o["deviceID"]?.GetValue<string>() == "cc");
    var dd = saved.OfType<System.Text.Json.Nodes.JsonObject>().First(o => o["deviceID"]?.GetValue<string>() == "dd");
    Check(aa["generation"]?.GetValue<int>() == 4 && aa["changedBy"]?.GetValue<string>() == "aa" && aa["custom"]?.GetValue<bool>() == true,
        "Pin preserves fabric membership fields on untouched entries");
    Check(bb["removed"]?.GetValue<bool>() == true && bb["generation"]?.GetValue<int>() == 9,
        "Pin carries tombstones it never loaded");
    Check(cc["DeviceID"] is null && cc["deviceID"]?.GetValue<string>() == "cc",
        "PascalCase entries migrate to canonical fabric casing");
    Check(dd["name"]?.GetValue<string>() == "New" && dd["lastHost"]?.GetValue<string>() == "h" && dd["lastPort"]?.GetValue<int>() == 1,
        "New pins store canonical keys with endpoint metadata");
    trust.Forget("aa");
    var after = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(Path.Combine(dir, "devices.json")))!.AsArray();
    var tombed = after.OfType<System.Text.Json.Nodes.JsonObject>().First(o => o["deviceID"]?.GetValue<string>() == "aa");
    Check(tombed["removed"]?.GetValue<bool>() == true && (tombed["generation"]?.GetValue<int>() ?? 0) > 0
        && after.OfType<System.Text.Json.Nodes.JsonObject>().Any(o => o["deviceID"]?.GetValue<string>() == "bb"
            && o["removed"]?.GetValue<bool>() == true)
        && new Converse.Core.DeviceTrustStore(dir).Devices.All(d => d.DeviceID != "aa"),
        "Forget tombstones with a bumped generation while reloads skip it");
    Cleanup(dir);
}

// Queue semantics with a gated runner: enqueue-only, unpause, clean clear,
// inject ordering, merged inject-all, title from first prompt.
{
    var root = Directory.CreateTempSubdirectory("converse-queue-").FullName;
    try
    {
        var gated = new GatedRunner();
        var store = new SessionStore(root, gated);
        var session = store.Create(store.Entries.First(e => e.Engine == "codex"));
        async Task<bool> Until(Func<bool> done)
        {
            // The engine appends transcript messages off-thread while these
            // predicates observe; a torn read retries instead of crashing.
            bool Try()
            {
                try { return done(); }
                catch (InvalidOperationException) { return false; }
            }
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!Try() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return Try();
        }
        int UserCount() => session.Messages.Count(m => m.Role == "user");
        session.Draft = "first prompt here";
        store.Submit(session);
        Check(session.Busy && UserCount() == 1, "Idle submit starts a turn with its user message");
        session.Draft = "second";
        store.Submit(session);
        Check(session.Pending.Count == 1 && UserCount() == 1, "Busy submit enqueues without a transcript message");
        session.QueuePaused = true;
        session.Draft = "third";
        store.Submit(session);
        Check(!session.QueuePaused && session.Pending.Count == 2, "Submit unpauses the queue (Mac parity)");
        session.Pending.Clear();
        store.Save();
        Check(session.Pending.Count == 0 && UserCount() == 1, "Clear leaves no unsent transcript trace");
        Check(session.Title == "first prompt here", "Session title comes from the first prompt");
        gated.Gate.SetResult(true);
        Check(await Until(() => !session.Busy && session.Status == "Ready"), "Gated turn completes after release");

        var injected = store.Create(store.Entries.First(e => e.Engine == "codex"));
        injected.Draft = "one";
        store.Submit(injected);
        injected.Draft = "two";
        store.Submit(injected);
        var target = injected.Pending[0].Id;
        store.InjectPending(injected, target);
        Check(injected.Pending.Count == 1 && injected.Busy, "Inject while busy holds the prompt for the wind-down");
        Check(await Until(() => injected.Messages.Any(m => m.Role == "user" && m.Text == "two") && injected.Pending.Count == 0),
            "Injected prompt runs after the interrupted turn, never alongside");
        gated.Gate.SetResult(true);
        Check(await Until(() => !injected.Busy) && gated.Prompts.TakeLast(2).SequenceEqual(new[] { "one", "two" }),
            "Interrupted turn yields to the injected prompt in order");

        var mergeStore = new SessionStore(root, new FakeRunner());
        var merged = mergeStore.Create(mergeStore.Entries.First(e => e.Engine == "codex"));
        merged.Pending.Add(new Converse.Core.PendingPrompt { Text = "alpha" });
        merged.Pending.Add(new Converse.Core.PendingPrompt { Text = "beta" });
        mergeStore.InjectPending(merged);
        Check(merged.Pending.Count == 0 && merged.Messages.Count(m => m.Role == "user") == 1
            && merged.Messages.First(m => m.Role == "user").Text == "alpha\n\nbeta",
            "Inject-all merges the queue into one prompt (Mac parity)");
        var honest = mergeStore.Create(mergeStore.Entries.First(e => e.Engine == "codex"));
        Check(mergeStore.InjectPending(honest) is string emptyFail && emptyFail.Length > 0 && honest.Pending.Count == 0,
            "Inject on an empty queue reports honestly instead of going silent");
        honest.Pending.Add(new Converse.Core.PendingPrompt { Text = "kept" });
        Check(mergeStore.InjectPending(honest, Guid.NewGuid()) is string missingFail && missingFail.Length > 0
            && honest.Pending.Count == 1 && honest.Pending[0].Text == "kept",
            "Inject of a missing queued item reports honestly and keeps the queue");
    }
    finally { Cleanup(root); }
}

// Claude text-block separators mirror the Mac: blocks stay separated in
// interrupted streams, and glued final snapshots keep our separators only.
{
    var store = new SessionStore(Directory.CreateTempSubdirectory("converse-sep-").FullName, new FakeRunner());
    var session = store.Create(store.Entries.First(e => e.Engine == "claude"));
    var response = new ChatMessage { Role = "assistant", Text = "" };
    void Line(string json) => store.Consume(json, session, response);
    Line("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\"}}}");
    Line("{\"type\":\"stream_event\",\"event\":{\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}}");
    Check(response.Text == "Hello", "First streamed block needs no separator");
    Line("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\"}}}");
    Line("{\"type\":\"stream_event\",\"event\":{\"delta\":{\"type\":\"text_delta\",\"text\":\"World\"}}}");
    Check(response.Text == "Hello\n\nWorld", "Later text blocks separate with a blank line");
    Line("{\"type\":\"result\",\"result\":\"HelloWorld\"}");
    Check(response.Text == "Hello\n\nWorld", "Glued final snapshot keeps display separators");
    Line("{\"type\":\"result\",\"result\":\"Something new\"}");
    Check(response.Text == "Something new", "Genuinely new final text still replaces");
    var streamed = store.Create(store.Entries.First(e => e.Engine == "claude"));
    var streamedResponse = new ChatMessage { Role = "assistant", Text = "" };
    void Chunk(string text) => store.Consume(
        "{\"type\":\"stream_event\",\"event\":{\"delta\":{\"type\":\"text_delta\",\"text\":" + System.Text.Json.JsonSerializer.Serialize(text) + "}}}",
        streamed, streamedResponse);
    Chunk("12\n");
    Chunk("13\n");
    Check(streamedResponse.Text == "12\n13\n", "Streamed chunk boundaries keep their newlines");
    var failed = store.Create(store.Entries.First(e => e.Engine == "claude"));
    var failedResponse = new ChatMessage { Role = "assistant", Text = "" };
    store.Consume("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\"}}}", failed, failedResponse);
    store.Consume("{\"type\":\"stream_event\",\"event\":{\"delta\":{\"type\":\"text_delta\",\"text\":\"part\"}}}", failed, failedResponse);
    store.Consume("{\"type\":\"result\",\"is_error\":true,\"result\":\"part\"}", failed, failedResponse);
    Check(failedResponse.Text == "part" && failed.TurnFailed, "Error results replace without separator games");
}

// Round-12 item 3c: a final snapshot that omits the first streamed block
// (text -> tool -> text) joins on overlap instead of deleting it.
{
    var dir = Directory.CreateTempSubdirectory("converse-firstblock-").FullName;
    try
    {
        var joinStore = new SessionStore(dir, new FakeRunner());
        var joined = joinStore.Create(joinStore.Entries.First(e => e.Engine == "claude"));
        var joinedResponse = new ChatMessage { Role = "assistant", Text = "" };
        void Join(string json) => joinStore.Consume(json, joined, joinedResponse);
        Join("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\"}}}");
        Join("{\"type\":\"stream_event\",\"event\":{\"delta\":{\"type\":\"text_delta\",\"text\":\"First block. \"}}}");
        Join("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"First block. \"},{\"type\":\"tool_use\",\"name\":\"Read\"}]}}");
        Join("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\"}}}");
        Join("{\"type\":\"stream_event\",\"event\":{\"delta\":{\"type\":\"text_delta\",\"text\":\"Second block.\"}}}");
        Join("{\"type\":\"result\",\"result\":\"Second block. Final words.\"}");
        Check(joinedResponse.Text.Contains("First block.", StringComparison.Ordinal)
            && joinedResponse.Text.Contains("Final words.", StringComparison.Ordinal)
            && joinedResponse.Text.Split("Second block.").Length == 2,
            "Partial final snapshot joins instead of deleting the first streamed block");
    }
    finally { Cleanup(dir); }
}

// Crash hardening: streamed text reaches disk before the turn ends, so a
// mid-stream death loses seconds, not the whole reply (round-12 leftovers).
{
    var dir = Directory.CreateTempSubdirectory("converse-streamsave-").FullName;
    try
    {
        var saveStore = new SessionStore(dir, new FakeRunner());
        var saving = saveStore.Create(saveStore.Entries.First(e => e.Engine == "claude"));
        var savingResponse = new ChatMessage { Role = "assistant", Text = "" };
        saving.Messages.Add(savingResponse);
        saveStore.Consume("{\"type\":\"stream_event\",\"event\":{\"delta\":{\"type\":\"text_delta\",\"text\":\"Partial reply\"}}}", saving, savingResponse);
        Check(File.ReadAllText(Path.Combine(dir, "sessions.json")).Contains("Partial reply", StringComparison.Ordinal),
            "Streamed text persists before turn end");
    }
    finally { Cleanup(dir); }
}

// Entry naming repairs "Claude Code" as well as "Muse".
{
    var dir = Directory.CreateTempSubdirectory("converse-code-").FullName;
    var entryJson = "{\"Name\":\"Claude Code\",\"Command\":\"claude\",\"Directory\":\"C:\\\\u\",\"Engine\":\"claude\"}";
    File.WriteAllText(Path.Combine(dir, "sessions.json"),
        "{\"Entries\":[" + entryJson + "],\"Sessions\":["
        + "{\"Id\":\"" + Guid.NewGuid() + "\",\"Entry\":" + entryJson + ",\"Title\":\"Claude Code\",\"Messages\":[]},"
        + "{\"Id\":\"" + Guid.NewGuid() + "\",\"Entry\":" + entryJson + ",\"Title\":\"Custom\",\"Messages\":[]}]}");
    var migrated = new Converse.Core.SessionStore(dir, new FakeRunner());
    Check(migrated.Entries[0].Name == "Claude"
        && migrated.Sessions.Single(s => s.Title == "Claude").Entry.Name == "Claude"
        && migrated.Sessions.Single(s => s.Title == "Custom").Entry.Name == "Claude",
        "Stored claude entry misnamed Claude Code migrates, keeping custom titles");
    Cleanup(dir);
}

// Group store: adopt/leave/dissolve, tombstone permanence, immutability, caps.
{
    var dir = Directory.CreateTempSubdirectory("converse-groups-").FullName;
    var store = new Converse.Core.ConverseGroupStore(dir);
    Check(store.Current is null && !store.Existed, "Fresh group store starts groupless");
    var group = new Converse.Core.ConverseGroup { Id = Guid.NewGuid().ToString("d"), Name = "Team", Creator = new string('c', 64) };
    store.Adopt(group);
    Check(store.Current?.Id == group.Id, "Adopt sets the current group");
    var renamed = new Converse.Core.ConverseGroup { Id = group.Id, Name = "Renamed", Creator = group.Creator };
    var threw = false;
    try { store.Adopt(renamed); } catch { threw = true; }
    Check(threw, "Group identity is immutable");
    store.Leave();
    Check(store.Current is null && store.Groups.Count == 1, "Leave keeps the group known but currentless");
    store.Dissolve(group);
    Check(store.Current is null && store.Groups.Single().Dissolved, "Dissolve writes a permanent tombstone");
    threw = false;
    try { store.Adopt(group); } catch { threw = true; }
    Check(threw, "Adopting a dissolved group refuses");
    var bad = new Converse.Core.ConverseGroup { Id = "not-a-uuid", Name = "Bad", Creator = new string('c', 64) };
    threw = false;
    try { store.Adopt(bad); } catch { threw = true; }
    Check(threw, "Invalid group IDs refuse adoption");
    var reloaded = new Converse.Core.ConverseGroupStore(dir);
    Check(reloaded.Existed && reloaded.Groups.Single().Dissolved, "Tombstones persist across restarts");
    var stored = System.Text.Encoding.UTF8.GetString(Converse.Core.DeviceJson.Encode(group));
    Check(!stored.Contains("valid", StringComparison.OrdinalIgnoreCase), "Computed group validity never serializes");
    Cleanup(dir);
}

// Legacy migration: the shared Mac/Windows vector from GroupTests.swift —
// byte keys 01/02/03 (x32), own is the 03 device and the smallest
// identity, so it is the creator. Older stores may omit their own pin,
// so this identity joins the distinct active roster exactly once.
{
    var ownID = Converse.Core.DeviceBlob.DeviceIdForPublicKey(FixedKey(0x03));
    Check(ownID == "648aa5c579fb30f38af744d97d6ec840c7a91277a499a0d780f3e7314eca090b",
        "Shared vector device ID matches 32 repetitions of byte 03");
    Converse.Core.TrustedDevice Row(byte fill, bool? removed = null)
    {
        var key = FixedKey(fill);
        return new Converse.Core.TrustedDevice(Converse.Core.DeviceBlob.DeviceIdForPublicKey(key), "N", key, null, null)
            with { Removed = removed };
    }
    var members = new[] { Row(0x01), Row(0x02) };
    var ownRow = Row(0x03);
    var group = Converse.Core.ConverseGroupStore.Migrate(members, ownID);
    Check(group is not null && group.Id == "27be22ea-df62-15e3-f5ca-dc1771d8f526"
        && group.Name == "Converse Group" && group.Creator == ownID,
        "Shared migration vector derives the documented group UUID");
    Check(Converse.Core.ConverseGroupStore.Migrate(members.Reverse().Append(ownRow).Append(ownRow).ToArray(), ownID)?.Id == group!.Id,
        "Migration deduplicates self and is roster-order independent");
    Check(Converse.Core.ConverseGroupStore.Migrate(Array.Empty<Converse.Core.TrustedDevice>(), ownID) is null
        && Converse.Core.ConverseGroupStore.Migrate(new[] { ownRow }, ownID) is null,
        "A standalone device does not automatically create a group");
    Check(Converse.Core.ConverseGroupStore.Migrate(members.Append(Row(0x03, true)).ToArray(), ownID) is null,
        "Migration cannot readmit a locally revoked device");
    Check(Converse.Core.ConverseGroupStore.Migrate(new[] { Row(0x01, true) }, ownID) is null,
        "Removed peers do not turn a standalone device into a migrated group");
}

// Request binding: exact-double equality plus liveness.
{
    var live = new Converse.Core.GroupJoinRequest
    {
        Id = Guid.NewGuid(), GroupID = "g", RequesterID = new string('r', 64),
        RequesterName = "R", SponsorID = "s", ExpiresAt = Converse.Core.DeviceTrustStore.AppleNow() + 60, Approved = false,
    };
    var copy = new Converse.Core.GroupJoinRequest
    {
        Id = live.Id, GroupID = live.GroupID, RequesterID = live.RequesterID, RequesterName = live.RequesterName,
        SponsorID = live.SponsorID, ExpiresAt = live.ExpiresAt, Approved = live.Approved,
    };
    Check(Converse.Core.GroupJoinRequests.Same(live, copy) && Converse.Core.GroupJoinRequests.Live(live),
        "Identical requests bind and report live");
    copy.ExpiresAt = BitConverter.Int64BitsToDouble(BitConverter.DoubleToInt64Bits(copy.ExpiresAt) + 1);
    Check(!Converse.Core.GroupJoinRequests.Same(live, copy), "One-ulp expiry drift breaks binding (exact doubles)");
    live.Approved = true;
    Check(!Converse.Core.GroupJoinRequests.Live(live), "Approved requests are no longer live");
}

// group.review carries the BARE request on the wire (Swift shape); the
// request/code wrapper exists only for review.detail and approve.
{
    var json = "{\"id\":\"11111111-2222-3333-4444-555555555555\",\"groupID\":\"27be22ea-df62-15e3-f5ca-dc1771d8f526\","
        + "\"requesterID\":\"" + new string('c', 64) + "\",\"requesterName\":\"C\",\"sponsorID\":\"" + new string('a', 64)
        + "\",\"expiresAt\":789123.5,\"approved\":false}";
    var bare = Converse.Core.DeviceJson.Decode<Converse.Core.GroupJoinRequest>(Utf8(json));
    Check(bare.Id == Guid.Parse("11111111-2222-3333-4444-555555555555") && bare.ExpiresAt == 789123.5 && !bare.Approved
        && bare is { GroupID: "27be22ea-df62-15e3-f5ca-dc1771d8f526", RequesterName: "C" },
        "Literal Swift-shaped review payload decodes with exact expiry");
    var encoded = System.Text.Encoding.UTF8.GetString(Converse.Core.DeviceJson.Encode(bare));
    Check(!encoded.Contains("\"request\":") && !encoded.Contains("\"code\"") && encoded.Contains("\"requesterID\":"),
        "Encoded review request has no wrapper keys");
    var wrapped = System.Text.Encoding.UTF8.GetString(Converse.Core.DeviceJson.Encode(
        new Converse.Core.GroupJoinReview { Request = bare, Code = "0000 0000 0000 0000 0000 0000 0000 0000" }));
    Check(wrapped.Contains("\"request\":{") && wrapped.Contains("\"code\":"), "Detail/approve keep the wrapper shape");
}

// Discovery phantoms expire past the 120s TTL, and this device lists
// itself only under its current group (Mac parity).
{
    var dir = Directory.CreateTempSubdirectory("converse-phantom-").FullName;
    try
    {
        using var a = new DeviceSyncService(dir, new SessionStore(dir, new FakeRunner()), "A");
        await a.CreateGroupAsync("Home");
        var home = a.CurrentGroup!;
        var stale = new Converse.Core.ConverseGroup
        { Id = Guid.NewGuid().ToString("d"), Name = "Alpha", Creator = new string('c', 64) };
        var fresh = new Converse.Core.ConverseGroup
        { Id = Guid.NewGuid().ToString("d"), Name = "Beta", Creator = new string('d', 64) };
        lock (a.DiscoveredDevices)
        {
            a.DiscoveredDevices.Add(new Converse.Core.MdnsService("Ghost [deadbeef]", "127.0.0.1", 1,
                stale, new string('e', 64), DateTime.UtcNow.AddSeconds(-121)));
            a.DiscoveredDevices.Add(new Converse.Core.MdnsService("Live [cafef00d]", "127.0.0.1", 2,
                fresh, new string('f', 64), DateTime.UtcNow));
        }
        var visible = a.AvailableGroups();
        Check(visible.All(g => g.Name != "Alpha") && visible.Any(g => g.Name == "Beta"),
            "Expired discoveries vanish while live hints stay");
        Check(a.GroupDevices(home).Any(d => d.DeviceID == a.DeviceId), "This device lists under its current group");
        var other = new Converse.Core.ConverseGroup
        { Id = Guid.NewGuid().ToString("d"), Name = "Elsewhere", Creator = new string('a', 64) };
        a.GroupStore.Adopt(other);
        Check(a.GroupDevices(home).All(d => d.DeviceID != a.DeviceId)
            && a.GroupDevices(other).Any(d => d.DeviceID == a.DeviceId),
            "This device never lists under groups it left");
    }
    finally { Cleanup(dir); }
}

// Pins scope to groups: same device/key in another group is a fresh admission.
{
    var dir = Directory.CreateTempSubdirectory("converse-pinscope-").FullName;
    var trust = new Converse.Core.DeviceTrustStore(dir);
    var key = new byte[32];
    var ga = Guid.NewGuid().ToString("d");
    var gb = Guid.NewGuid().ToString("d");
    trust.Pin(new Converse.Core.TrustedDevice("dd", "D", key, null, null), "dd", true, ga);
    var firstGen = trust.Devices.Single().Generation;
    trust.Pin(new Converse.Core.TrustedDevice("dd", "D", key, null, null), "dd", true, gb);
    var moved = trust.Devices.Single();
    Check(moved.GroupID == gb && moved.Generation != firstGen, "Re-pin to another group mints fresh membership");
    trust.Pin(new Converse.Core.TrustedDevice("dd", "D2", key, "h", 1), "dd", true, gb);
    Check(trust.Devices.Single().Generation == moved.Generation && trust.Devices.Single().LastHost == "h",
        "Same-group re-pin updates metadata without new membership");
    Cleanup(dir);
}

// Join codes match: the joiner's prompt equals the sponsor's live review code.
{
    var homeRoot = Directory.CreateTempSubdirectory("converse-codeeq-").FullName;
    var viewerRoot = Directory.CreateTempSubdirectory("converse-codeeqv-").FullName;
    try
    {
        using var home = new DeviceSyncService(homeRoot, new SessionStore(homeRoot, new FakeRunner()), "HomePC");
        using var viewer = new DeviceSyncService(viewerRoot, new SessionStore(viewerRoot, new FakeRunner()), "ViewerPC");
        viewer.PairingConfirmation = _ => Task.FromResult(true);
        await home.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await viewer.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await home.CreateGroupAsync("Codes");
        await viewer.ConnectManualAsync("127.0.0.1", home.ListeningPort, home.CurrentGroup!.Id);
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (home.GroupRequests.Count == 0 && DateTime.UtcNow < deadline) await Task.Delay(25);
        await home.ReviewGroupRequestAsync(home.GroupRequests[0]);
        Check(viewer.GroupPairingPrompts.Count == 1 && home.GroupReview is not null
            && home.GroupReview.Code == viewer.GroupPairingPrompts[0].Code
            && home.GroupReview.Code.Length == 39,
            "Sponsor review reproduces the joiner's 8-group code");
    }
    finally { Cleanup(homeRoot); Cleanup(viewerRoot); }
}

// Three-device admission: a NON-sponsor member reviews with a stable code.
{
    var aRoot = Directory.CreateTempSubdirectory("converse-3a-").FullName;
    var bRoot = Directory.CreateTempSubdirectory("converse-3b-").FullName;
    var cRoot = Directory.CreateTempSubdirectory("converse-3c-").FullName;
    try
    {
        using var a = new DeviceSyncService(aRoot, new SessionStore(aRoot, new FakeRunner()), "A");
        using var b = new DeviceSyncService(bRoot, new SessionStore(bRoot, new FakeRunner()), "B");
        using var c = new DeviceSyncService(cRoot, new SessionStore(cRoot, new FakeRunner()), "C");
        a.PairingConfirmation = _ => Task.FromResult(true);
        b.PairingConfirmation = _ => Task.FromResult(true);
        c.PairingConfirmation = _ => Task.FromResult(true);
        await a.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await b.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await c.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        async Task<bool> Until(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        Check(await JoinPair(a, b, () => b.CurrentGroup?.Id == a.CurrentGroup?.Id), "Member B joins through sponsor A");
        await c.ConnectManualAsync("127.0.0.1", a.ListeningPort, a.CurrentGroup!.Id);
        Check(await Until(() => b.GroupRequests.Count == 1), "Sponsor publishes the join request to members");
        await b.ReviewGroupRequestAsync(b.GroupRequests[0]);
        string? joinerCode = null;
        Check(await Until(() => b.GroupReview is not null
            && (joinerCode = c.GroupPairingPrompts.FirstOrDefault()?.Code) is not null
            && b.GroupReview.Code == joinerCode), "Review by another member reproduces the joiner's code");
        await b.ApproveGroupReviewAsync();
        Check(await Until(() => c.CurrentGroup?.Id == a.CurrentGroup?.Id
            && a.Trust.Devices.Any(d => d.DeviceID == c.DeviceId)), "Relayed approval admits the joiner");
    }
    finally
    {
        Cleanup(aRoot);
        Cleanup(bRoot);
        Cleanup(cRoot);
    }
}

// Wrong codes and missing gates refuse admission silently.
{
    var aRoot = Directory.CreateTempSubdirectory("converse-ng1-").FullName;
    var bRoot = Directory.CreateTempSubdirectory("converse-ng2-").FullName;
    try
    {
        using var a = new DeviceSyncService(aRoot, new SessionStore(aRoot, new FakeRunner()), "A");
        using var b = new DeviceSyncService(bRoot, new SessionStore(bRoot, new FakeRunner()), "B");
        b.PairingConfirmation = _ => Task.FromResult(true);
        await a.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await b.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await a.CreateGroupAsync("Gates");
        async Task<bool> Until(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        await b.ConnectManualAsync("127.0.0.1", a.ListeningPort, a.CurrentGroup!.Id);
        Check(await Until(() => a.GroupRequests.Count == 1), "Negative setup sponsors the join");
        await a.ReviewGroupRequestAsync(a.GroupRequests[0]);
        var live = a.GroupReview!;
        a.GroupReview = new Converse.Core.GroupJoinReview { Request = live.Request, Code = "0000 0000 0000 0000 0000 0000 0000 0000" };
        await a.ApproveGroupReviewAsync();
        await Task.Delay(500);
        Check(!a.Trust.Devices.Any(d => d.DeviceID == b.DeviceId) && b.CurrentGroup is null,
            "Tampered approval code refuses admission");
        b.RejectPairing(b.GroupPairingPrompts[0].PeerId);
        Check(await Until(() => a.GroupRequests.Count == 0) && b.CurrentGroup is null,
            "Canceled join withdraws the request and keeps no group");
    }
    finally { Cleanup(aRoot); Cleanup(bRoot); }
}

// The joiner pressing Pair alone, or the sponsor approving alone, admits nobody.
{
    var aRoot = Directory.CreateTempSubdirectory("converse-1g1-").FullName;
    var bRoot = Directory.CreateTempSubdirectory("converse-1g2-").FullName;
    try
    {
        using var a = new DeviceSyncService(aRoot, new SessionStore(aRoot, new FakeRunner()), "A");
        using var b = new DeviceSyncService(bRoot, new SessionStore(bRoot, new FakeRunner()), "B");
        b.PairingConfirmation = _ => Task.FromResult(true);
        await a.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await b.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await a.CreateGroupAsync("Gates");
        async Task<bool> Until(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        await b.ConnectManualAsync("127.0.0.1", a.ListeningPort, a.CurrentGroup!.Id);
        Check(await Until(() => b.GroupPairingPrompts.Count == 1 && a.GroupRequests.Count == 1), "One-gate setup reaches both prompts");
        await Task.Delay(500);
        Check(!a.Trust.Devices.Any(d => d.DeviceID == b.DeviceId) && b.CurrentGroup is null,
            "Joiner Pair without sponsor approval admits nobody");
    }
    finally { Cleanup(aRoot); Cleanup(bRoot); }
}

// A refused manual connect reports instead of throwing (its UI callers are async void).
{
    var rRoot = Directory.CreateTempSubdirectory("converse-refused-").FullName;
    try
    {
        using var a = new DeviceSyncService(rRoot, new SessionStore(rRoot, new FakeRunner()), "A");
        var probe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        probe.Start();
        var closedPort = ((System.Net.IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        var threw = false;
        try { await a.ConnectManualAsync("127.0.0.1", closedPort); } catch { threw = true; }
        Check(!threw && a.LastOutcome.StartsWith("Could not reach"), "Refused manual connect reports instead of throwing");
    }
    finally { Cleanup(rRoot); }
}

// Cross-group and legacy peers are refused without pairing.
{
    var aRoot = Directory.CreateTempSubdirectory("converse-iso1-").FullName;
    var dRoot = Directory.CreateTempSubdirectory("converse-iso2-").FullName;
    try
    {
        using var a = new DeviceSyncService(aRoot, new SessionStore(aRoot, new FakeRunner()), "A");
        using var d = new DeviceSyncService(dRoot, new SessionStore(dRoot, new FakeRunner()), "D");
        await a.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await d.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await a.CreateGroupAsync("Alpha");
        await d.CreateGroupAsync("Beta");
        await d.ConnectManualAsync("127.0.0.1", a.ListeningPort);
        await Task.Delay(500);
        Check(!a.Trust.Devices.Any(x => x.DeviceID == d.DeviceId) && a.LastOutcome.Contains("Groups"),
            "Cross-group reconnect refuses without generic pairing");
        Check(Converse.Core.DeviceSyncService.RefusesLegacy(new DeviceHello { Capabilities = new[] { "sidebar" } })
            && !Converse.Core.DeviceSyncService.RefusesLegacy(new DeviceHello()),
            "Legacy capability sets refuse while current ones pass");
    }
    finally { Cleanup(aRoot); Cleanup(dRoot); }
}

// Offline dissolution converges over a control-only reconnect, sessions hidden.
{
    var aRoot = Directory.CreateTempSubdirectory("converse-dis1-").FullName;
    var bRoot = Directory.CreateTempSubdirectory("converse-dis2-").FullName;
    try
    {
        var bStore = new SessionStore(bRoot, new FakeRunner());
        using var a = new DeviceSyncService(aRoot, new SessionStore(aRoot, new FakeRunner()), "A");
        a.PairingConfirmation = _ => Task.FromResult(true);
        await a.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await a.CreateGroupAsync("Doomed");
        string groupId;
        string bId;
        {
            using var b = new DeviceSyncService(bRoot, bStore, "B");
            b.PairingConfirmation = _ => Task.FromResult(true);
            await b.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
            async Task<bool> Until(Func<bool> done)
            {
                var deadline = DateTime.UtcNow.AddSeconds(15);
                while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
                return done();
            }
            groupId = a.CurrentGroup!.Id;
            bId = b.DeviceId;
            Check(await JoinPair(a, b, () => b.CurrentGroup?.Id == groupId), "Dissolve setup joins B");
            Check(await Until(() => a.Homes.GetValueOrDefault(bId)?.Online == true), "Dissolve setup trusts both directions");
        }
        async Task<bool> UntilOff(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        // b's disposal must be fully observed before the dissolve: asserting
        // "offline belief" while any socket is still draining is a race.
        Check(await UntilOff(() => a.Homes.GetValueOrDefault(bId)?.Online != true),
            "Dissolve setup waits for b's disconnect");
        await a.DissolveGroupAsync(a.KnownGroups.First(g => g.Id == groupId));
        Check(a.CurrentGroup is null && a.KnownGroups.Any(g => g.Id == groupId && g.Dissolved),
            "Dissolve clears current and stores the tombstone");
        using var b2 = new DeviceSyncService(bRoot, new SessionStore(bRoot, new FakeRunner()), "B");
        // Belief is a file-state claim: assert it before any socket exists,
        // so no reconnect can ever slip in ahead of the check.
        var groupsFile = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(Path.Combine(bRoot, "converse-groups.json")))!;
        Check(b2.CurrentGroup?.Id == groupId && groupsFile["currentID"]?.GetValue<string>() == groupId,
            "Offline member still believes in the group");
        await b2.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await b2.ConnectManualAsync("127.0.0.1", a.ListeningPort);
        async Task<bool> Until2(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        Check(await Until2(() => b2.CurrentGroup is null && b2.KnownGroups.Any(g => g.Id == groupId && g.Dissolved)),
            "Reconnecting member learns the tombstone over control-only");
        Check(!b2.Homes.Values.Any(h => h.Rows.Count > 0), "Dissolved member sees no remote sessions");
    }
    finally { Cleanup(aRoot); Cleanup(bRoot); }
}

// Leave parks remote views immediately; local work survives.
{
    var aRoot = Directory.CreateTempSubdirectory("converse-leave1-").FullName;
    var bRoot = Directory.CreateTempSubdirectory("converse-leave2-").FullName;
    try
    {
        using var a = new DeviceSyncService(aRoot, new SessionStore(aRoot, new FakeRunner()), "A");
        var bStore = new SessionStore(bRoot, new FakeRunner());
        using var b = new DeviceSyncService(bRoot, bStore, "B");
        a.PairingConfirmation = _ => Task.FromResult(true);
        b.PairingConfirmation = _ => Task.FromResult(true);
        await a.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await b.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        async Task<bool> Until(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        var local = bStore.Create(bStore.Entries.First(e => e.Engine == "codex"));
        local.Draft = "keep me";
        Check(await JoinPair(a, b, () => b.Homes.ContainsKey(a.DeviceId)), "Leave setup joins B");
        await b.LeaveGroupAsync();
        Check(b.CurrentGroup is null && b.Homes.Count == 0 && bStore.Sessions.Single(s => s.Id == local.Id).Draft == "keep me",
            "Leave hides remotes while local drafts survive");
    }
    finally { Cleanup(aRoot); Cleanup(bRoot); }
}

// mDNS TXT hints: group/device parse, invalid UUIDs ignored.
{
    static byte[] Txt(params string[] entries)
    {
        using var stream = new MemoryStream();
        foreach (var entry in entries)
        {
            var bytes = System.Text.Encoding.UTF8.GetBytes(entry);
            stream.WriteByte((byte)bytes.Length);
            stream.Write(bytes);
        }
        return stream.ToArray();
    }
    var id = Guid.NewGuid().ToString("d");
    var parsed = Converse.Core.MdnsDiscovery.ParseTxt(Txt("device=" + new string('d', 64), "group=" + id, "name=G", "creator=" + new string('c', 64)));
    var hint = Converse.Core.MdnsDiscovery.GroupHint(parsed.ToDictionary(e => e.Key, e => e.Value));
    Check(hint is not null && hint.Id == id && hint.Name == "G" && !hint.Dissolved, "TXT hints parse group identity");
    var bad = Converse.Core.MdnsDiscovery.GroupHint(new Dictionary<string, string> { ["group"] = "nope" });
    Check(bad is null, "Invalid group UUID hints are ignored");
    var dead = Converse.Core.MdnsDiscovery.GroupHint(new Dictionary<string, string> { ["group"] = id, ["dissolved"] = "1" });
    Check(dead is not null && dead.Dissolved, "Dissolved flag survives the hint round-trip");
}

// devices.json carries groupID; Mac-shaped records decode fully.
{
    var dir = Directory.CreateTempSubdirectory("converse-gid-").FullName;
    var key = Convert.ToBase64String(new byte[32]);
    var gid = Guid.NewGuid().ToString("d");
    File.WriteAllText(Path.Combine(dir, "devices.json"),
        "[{\"deviceID\":\"aa\",\"name\":\"Mac\",\"publicKey\":\"" + key + "\",\"pairedAt\":789123456.5,\"generation\":2,\"changedBy\":\"aa\","
        + "\"metadataGeneration\":3,\"metadataBy\":\"aa\",\"groupID\":\"" + gid + "\"}]");
    var trust = new Converse.Core.DeviceTrustStore(dir);
    var loaded = trust.Devices.Single();
    Check(loaded.GroupID == gid && loaded.PairedAt == 789123456.5 && loaded.Generation == 2 && loaded.MetadataBy == "aa",
        "Mac-shaped membership records decode with group and counters");
    trust.Pin(new Converse.Core.TrustedDevice("bb", "B", new byte[32], null, null), "bb", true, gid);
    var saved = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(Path.Combine(dir, "devices.json")))!.AsArray();
    Check(saved.OfType<System.Text.Json.Nodes.JsonObject>().Any(o => o["deviceID"]?.GetValue<string>() == "bb"
        && o["groupID"]?.GetValue<string>() == gid && o["pairedAt"]?.GetValue<double>() > 0),
        "Pins persist groupID with a stamped pairedAt");
    Cleanup(dir);
}

// Creating a group while grouped fences the old group in both directions:
// stale submits never land or ack, stale acquires never grant, publishes
// skip the stale peer, and a fresh member of the new group can take the
// session the old member held.
{
    var aRoot = Directory.CreateTempSubdirectory("converse-fencea-").FullName;
    var bRoot = Directory.CreateTempSubdirectory("converse-fenceb-").FullName;
    var cRoot = Directory.CreateTempSubdirectory("converse-fencec-").FullName;
    try
    {
        var aStore = new SessionStore(aRoot, new FakeRunner());
        var held = aStore.Create(aStore.Entries.First(e => e.Engine == "codex"));
        held.Title = "Held session";
        var other = aStore.Create(aStore.Entries.First(e => e.Engine == "codex"));
        other.Title = "Other session";
        using var a = new DeviceSyncService(aRoot, aStore, "A");
        using var b = new DeviceSyncService(bRoot, new SessionStore(bRoot, new FakeRunner()), "B");
        using var c = new DeviceSyncService(cRoot, new SessionStore(cRoot, new FakeRunner()), "C");
        a.PairingConfirmation = _ => Task.FromResult(true);
        b.PairingConfirmation = _ => Task.FromResult(true);
        c.PairingConfirmation = _ => Task.FromResult(true);
        await a.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await b.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await c.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        // 30 s budget: three DeviceSyncServices plus Noise handshakes can
        // exceed 15 s on a loaded virtualized box; Until exits early when
        // green, so this only costs time on genuine failure.
        async Task<bool> Until(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(30);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        var gidHeld = new DeviceGlobalID(a.DeviceId, held.Id).ToString();
        var gidOther = new DeviceGlobalID(a.DeviceId, other.Id).ToString();
        Check(await JoinPair(a, b, () => b.Homes.GetValueOrDefault(a.DeviceId)?.Rows.Count == 2), "Fence setup groups A with B");
        await b.AcquireRemoteAsync(gidHeld);
        Check(await Until(() => b.RemoteLeases.ContainsKey(gidHeld)), "Fence setup holds B's lease on A's session");
        await a.CreateGroupAsync("Second");
        Check(!a.Homes.ContainsKey(b.DeviceId), "Create drops the old-group home immediately");
        var stale = await b.SendRemoteCommandAsync(gidHeld, new DeviceCommandPayload { Action = "rename", Text = "Stale" });
        await Task.Delay(500);
        Check(stale is not null && held.Title == "Held session"
            && b.Outbox.Any(r => r.CommandID == stale && r.Outcome == "pending"),
            "Stale submit never lands and never acks");
        await b.AcquireRemoteAsync(gidOther);
        await Task.Delay(500);
        Check(!b.RemoteLeases.ContainsKey(gidOther), "Stale acquire never grants");
        other.Title = "Changed after create";
        aStore.Save();
        await Task.Delay(500);
        Check(b.Homes.GetValueOrDefault(a.DeviceId)?.Rows.Any(r => r.GlobalID == gidOther && r.Title == "Changed after create") != true,
            "Sidebar publish skips the stale peer while still connected");
        Check(await JoinPair(a, c, () => c.Homes.GetValueOrDefault(a.DeviceId)?.Rows.Count == 2), "Fresh member joins the new group");
        await c.AcquireRemoteAsync(gidHeld);
        Check(await Until(() => c.RemoteLeases.ContainsKey(gidHeld)), "Fenced hold releases so the new member can take it");
    }
    finally { Cleanup(aRoot); Cleanup(bRoot); Cleanup(cRoot); }
}

// A pre-group store with a self tombstone never migrates, never self-pins
// above the removal, and refuses reconnects; a reviewed join readmits.
{
    var aRoot = Directory.CreateTempSubdirectory("converse-revoka-").FullName;
    var bRoot = Directory.CreateTempSubdirectory("converse-revokb-").FullName;
    try
    {
        using var a = new DeviceSyncService(aRoot, new SessionStore(aRoot, new FakeRunner()), "A");
        a.PairingConfirmation = _ => Task.FromResult(true);
        await a.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await a.CreateGroupAsync("Members");
        var aPub = a.Trust.Records.First(d => d.DeviceID == a.DeviceId).PublicKey;
        string bId;
        ulong tombGen;
        var fakeKey = new byte[32];
        Array.Fill(fakeKey, (byte)0x77);
        var fakeId = Converse.Core.DeviceBlob.DeviceIdForPublicKey(fakeKey);
        // Craft the pre-group store: two actives, one self tombstone, no
        // groups file. The key file fixes the identity across restarts.
        {
            using var craft = new DeviceSyncService(bRoot, new SessionStore(bRoot, new FakeRunner()), "B");
            bId = craft.DeviceId;
            var trust = new Converse.Core.DeviceTrustStore(bRoot);
            trust.Pin(new Converse.Core.TrustedDevice(a.DeviceId, "A", aPub, null, null), a.DeviceId);
            trust.Pin(new Converse.Core.TrustedDevice(fakeId, "Phantom", fakeKey, null, null), fakeId);
            var bPub = Converse.Core.X25519.PublicKeyFromPrivate(File.ReadAllBytes(Path.Combine(bRoot, "device-key.bin")));
            trust.Pin(new Converse.Core.TrustedDevice(bId, "B", bPub, null, null), bId);
            trust.Forget(bId, bId);
            tombGen = trust.Records.First(d => d.DeviceID == bId).Generation ?? 0;
        }
        using var b = new DeviceSyncService(bRoot, new SessionStore(bRoot, new FakeRunner()), "B");
        b.PairingConfirmation = _ => Task.FromResult(true);
        await b.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        async Task<bool> Until(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        Check(b.CurrentGroup is null && b.LocallyRemoved
            && b.Trust.Records.Count(d => d.DeviceID == bId) == 1
            && (b.Trust.Records.First(d => d.DeviceID == bId).Generation ?? 0) == tombGen,
            "Removed restart keeps the tombstone newest with no group");
        // The crafted live pin of A must sit untouched: no trust means no
        // metadata refresh, and the tombstone stays the newest self record.
        var aPinGen = b.Trust.Records.First(d => d.DeviceID == a.DeviceId).Generation ?? 0;
        await b.ConnectManualAsync("127.0.0.1", a.ListeningPort);
        await Task.Delay(500);
        Check(!a.Trust.Devices.Any(d => d.DeviceID == bId)
            && (b.Trust.Records.First(d => d.DeviceID == a.DeviceId).Generation ?? 0) == aPinGen
            && b.GroupPairingPrompts.Count == 0 && b.Homes.Count == 0
            && (b.Trust.Records.First(d => d.DeviceID == bId).Generation ?? 0) == tombGen,
            "Removed reconnect refuses with no prompt, pin, or resurrection");
        // Readmission: a reviewed join supersedes the tombstone cleanly.
        await b.ConnectManualAsync("127.0.0.1", a.ListeningPort, a.CurrentGroup!.Id);
        Check(await Until(() => a.GroupRequests.Count == 1), "Readmission setup sponsors the removed device");
        await a.ReviewGroupRequestAsync(a.GroupRequests[0]);
        await a.ApproveGroupReviewAsync();
        Check(await Until(() => b.CurrentGroup?.Id == a.CurrentGroup?.Id
            && b.Trust.Devices.Any(d => d.DeviceID == bId)
            && ((b.Trust.Records.First(d => d.DeviceID == bId).Generation ?? 0) > tombGen)
            && a.Trust.Devices.Any(d => d.DeviceID == bId)),
            "Reviewed join readmits above the removal generation");
    }
    finally { Cleanup(aRoot); Cleanup(bRoot); }
}

// Leave broadcasts its tombstone under the previous group before any
// disconnect, so members converge without a reconnect.
{
    var aRoot = Directory.CreateTempSubdirectory("converse-leavea-").FullName;
    var bRoot = Directory.CreateTempSubdirectory("converse-leaveb-").FullName;
    try
    {
        using var a = new DeviceSyncService(aRoot, new SessionStore(aRoot, new FakeRunner()), "A");
        using var b = new DeviceSyncService(bRoot, new SessionStore(bRoot, new FakeRunner()), "B");
        a.PairingConfirmation = _ => Task.FromResult(true);
        b.PairingConfirmation = _ => Task.FromResult(true);
        await a.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await b.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        // 30 s budget, same rule as the fence test below: Until exits
        // early when green, so this only costs time on genuine failure.
        async Task<bool> Until(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(30);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        Check(await JoinPair(a, b, () => b.Homes.GetValueOrDefault(a.DeviceId)?.Online == true), "Leave setup groups A with B");
        await b.LeaveGroupAsync();
        Check(await Until(() => a.Trust.Records.Any(d => d.DeviceID == b.DeviceId && d.Removed == true)),
            "Leave tombstone reaches the member over the open socket");
        Check(await Until(() => !a.Homes.ContainsKey(b.DeviceId)), "Member drops the leaver's home on merge");
    }
    finally { Cleanup(aRoot); Cleanup(bRoot); }
}

// Expiry closes the join, clears prompts and reviews, and stale approvals
// admit nobody.
{
    var aRoot = Directory.CreateTempSubdirectory("converse-expa-").FullName;
    var cRoot = Directory.CreateTempSubdirectory("converse-expc-").FullName;
    try
    {
        using var a = new DeviceSyncService(aRoot, new SessionStore(aRoot, new FakeRunner()), "A");
        using var c = new DeviceSyncService(cRoot, new SessionStore(cRoot, new FakeRunner()), "C");
        c.PairingConfirmation = _ => Task.FromResult(true);
        await a.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await c.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        async Task<bool> Until(Func<bool> done)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
            return done();
        }
        await a.CreateGroupAsync("Expiring");
        var dialDeadline = DateTime.UtcNow.AddSeconds(45);
        while (a.GroupRequests.Count == 0 && DateTime.UtcNow < dialDeadline)
        {
            if (c.GroupPairingPrompts.Count == 0)
                await c.ConnectManualAsync("127.0.0.1", a.ListeningPort, a.CurrentGroup!.Id);
            var slice = DateTime.UtcNow.AddSeconds(15);
            while (a.GroupRequests.Count == 0 && DateTime.UtcNow < slice) await Task.Delay(25);
        }
        Check(a.GroupRequests.Count == 1 && c.GroupPairingPrompts.Count == 1,
            "Expiry setup sponsors a waiting joiner");
        var stale = a.GroupRequests[0];
        await a.ReviewGroupRequestAsync(stale);
        Check(a.GroupReview is not null, "Expiry setup stages a live review");
        a.ExpireJoinForTest(stale.Id);
        Check(a.SweepExpiredSponsors() && a.GroupRequests.Count == 0 && a.GroupReview is null,
            "Sweep drops the expired request and clears its review");
        Check(await Until(() => c.GroupPairingPrompts.Count == 0), "Expired join closes the joiner's socket");
        a.GroupReview = new Converse.Core.GroupJoinReview { Request = stale, Code = "0000 0000 0000 0000 0000 0000 0000 0000" };
        await a.ApproveGroupReviewAsync();
        await Task.Delay(300);
        Check(!a.Trust.Devices.Any(d => d.DeviceID == c.DeviceId) && c.CurrentGroup is null,
            "Stale review approves nobody");
    }
    finally { Cleanup(aRoot); Cleanup(cRoot); }
}

// Pane placements: assign parks occupants, park clears, layout persists.
{
    var p = new PanePlacements();
    Check(p.PaneOf("local:a") is null, "Unplaced session has no pane");
    Check(p.Assign("local:a", 1) is null, "First assignment evicts nobody");
    Check(p.Assign("local:a", 1) is null && p.KeyIn(1) == "local:a", "Repeat assignment is stable");
    Check(p.Assign("remote:b", 1) == "local:a", "Assigning a pane evicts its occupant");
    Check(p.PaneOf("local:a") is null && p.PaneOf("remote:b") == 1, "Evicted session is parked");
    Check(p.Assign("remote:b", 2) == null && p.KeyIn(1) is null && p.KeyIn(2) == "remote:b",
        "Moving a session parks its old pane");
    p.Assign("zzz", 9);
    Check(p.KeyIn(9) is null && p.Slots.Count == 1, "Out-of-range pane refused");
    p.Park("remote:b");
    Check(p.KeyIn(2) is null, "Park clears the pane");
    var layoutDir = Directory.CreateTempSubdirectory("converse-panes-").FullName;
    try
    {
        p.Assign("local:a", 3);
        p.Save(layoutDir);
        var reloaded = PanePlacements.Load(layoutDir);
        Check(reloaded.KeyIn(3) == "local:a", "Placements persist across restarts");
        File.WriteAllText(Path.Combine(layoutDir, "pane-layout.json"), "{broken");
        Check(PanePlacements.Load(layoutDir).Slots.Count == 0, "Corrupt layout loads empty, never crashes");
    }
    finally { Cleanup(layoutDir); }
}

// Chat markdown: markers strip, runs land in stripped coordinates.
{
    var (plain, runs) = MarkdownRuns.Render("## Title\nHello **bold** and `code`.\n[Docs](https://example.com/x)");
    Check(plain == "Title\nHello bold and code.\nDocs", "Markdown markers strip to plain text");
    Check(runs.Any(r => r.Kind == MdRunKind.Heading && r.Start == 0 && r.Length == 5 && r.Level == 2),
        "Heading run covers the stripped title");
    var boldAt = plain.IndexOf("bold", StringComparison.Ordinal);
    Check(runs.Any(r => r.Kind == MdRunKind.Bold && r.Start == boldAt && r.Length == 4),
        "Bold run matches the stripped span");
    var codeAt = plain.IndexOf("code", StringComparison.Ordinal);
    Check(runs.Any(r => r.Kind == MdRunKind.Code && r.Start == codeAt && r.Length == 4),
        "Code run matches the stripped span");
    var (fenced, fenceRuns) = MarkdownRuns.Render("```\n**not bold**\n```\na ** b `c");
    Check(fenced == "**not bold**\na ** b `c"
        && fenceRuns.Count(r => r.Kind == MdRunKind.Code) == 1
        && fenceRuns.Any(r => r.Kind == MdRunKind.Code && r.Start == 0 && r.Length == "**not bold**".Length),
        "Fenced code washes as one Code run; unmatched markers stay literal");
    var (table, tableRuns) = MarkdownRuns.Render("Intro\n| °C | °F |\n|---|---|\n| 20 | 68.0 |\n| 21 | 69.8 |\nAfter");
    Check(table == "Intro\n| °C | °F |\n| 20 | 68.0 |\n| 21 | 69.8 |\nAfter",
        "Table divider drops, header and rows kept verbatim");
    var tableAt = table.IndexOf("| °C", StringComparison.Ordinal);
    Check(tableRuns.Any(r => r.Kind == MdRunKind.Table && r.Start == tableAt
        && r.Length == "| °C | °F |\n| 20 | 68.0 |\n| 21 | 69.8 |".Length),
        "Table run covers the whole block for monospace alignment");
    var (pipes, pipeRuns) = MarkdownRuns.Render("a | b\nnot a divider");
    Check(pipes == "a | b\nnot a divider" && pipeRuns.Count == 0,
        "Pipes without a divider row stay plain text");
}

// Render-boundary hardening: lone surrogates scrub to U+FFFD 1:1 (offsets
// preserved) while valid pairs pass through untouched.
{
    var lone = "a\ud800b\udc00c\ud800";
    var clean = MarkdownRuns.SanitizeLoneSurrogates(lone);
    Check(clean == "a�b�c�", "Lone surrogates scrub to replacement chars");
    var pair = "a\U0001F600b";
    Check(MarkdownRuns.SanitizeLoneSurrogates(pair) == pair && pair.Length == 4,
        "Valid surrogate pairs pass through untouched");
}

// Round-16 crash fix, round-18 correction: streaming text lands BEFORE the
// trailing separator, so prefix checks always miss. The common prefix is the
// absorb point. Literals below are BuildHistory-shaped: every message ends
// with the "\r\r" separator, including the streaming tail.
{
    var (fullOp, _) = TranscriptHistory.Plan(null, "abc", 0);
    Check(fullOp == HistoryOp.Full, "First render takes the full rebuild");
    var rendered = "First question\r\rFirst answer line one\r\r";
    var grown = "First question\r\rFirst answer line one plus more\r\r";
    var (repOp, repStart) = TranscriptHistory.Plan(rendered, grown, 16);
    Check(repOp == HistoryOp.Replace && repStart == 37,
        "Streaming growth before the separator absorbs from the common prefix");
    var (gateOp, _) = TranscriptHistory.Plan(rendered, grown, 38);
    Check(gateOp == HistoryOp.Full, "Divergence above the last message keeps the full rebuild");
    var (pureOp, pureStart) = TranscriptHistory.Plan("abc", "abcdef", 0);
    Check(pureOp == HistoryOp.Replace && pureStart == 3, "Pure tail append absorbs at the end");
    var (sameOp, _) = TranscriptHistory.Plan("abc", "abc", 0);
    Check(sameOp == HistoryOp.Same, "Identical history needs no history work");
    var (preOp, _) = TranscriptHistory.Plan("A\r\rB", "Z\r\rA\r\rB", 8);
    Check(preOp == HistoryOp.Full, "Prepended earlier messages take the full rebuild");
}

// Protected-history seam: deleting history's last content char while the
// draft starts with the same char is byte-identical to a legal separator
// trim, so strings alone cannot judge it. The post-change caret is the
// witness: inside the core means revert, at/past it means adopt.
{
    var history = "You: hi\r\rResponse text\r\r";
    var masked = "You: hi\r\rResponse tex" + "typing words";
    Check(!EditorBoundary.Split(masked, history, 21).HistoryOk,
        "Seam deletion masked by coinciding draft text still reverts");
    var (ok, draft) = EditorBoundary.Split(masked, history, 22);
    Check(ok && draft == "yping words",
        "Legal separator-plus-draft-head deletion adopts the true draft");
    var typed = EditorBoundary.Split(history + "q", history, history.Length + 1);
    Check(typed.HistoryOk && typed.Draft == "q", "Draft typing keeps history intact");
    var breaks = EditorBoundary.Split(history[..^1], history, history.Length - 1);
    Check(breaks.HistoryOk && breaks.Draft == "", "Separator backspace is a legal no-op");
    Check(!EditorBoundary.Split(history.Insert(10, "Q"), history, 11).HistoryOk,
        "Typing inside history reverts");
    var fresh = EditorBoundary.Split("abc", "", 3);
    Check(fresh.HistoryOk && fresh.Draft == "abc", "Empty history takes all text as draft");
}

// Block renderer: pipe tables become grids, surrounding text keeps runs.
{
    var intro = MarkdownBlocks.Parse("Intro **bold** text.\n\n| A | B |\n| --- | ---: |\n| 1 | 2 |\n| 3 | 4 |\n\nAfter.");
    Check(intro.Count == 3 && intro[0] is MdText && intro[1] is MdTable && intro[2] is MdText,
        "Table splits its message into text-table-text blocks");
    var table = (MdTable)intro[1];
    Check(table.Rows.Count == 3 && table.Rows[0].SequenceEqual(new[] { "A", "B" })
        && table.Rows[2].SequenceEqual(new[] { "3", "4" }),
        "Table cells parse with header first and divider dropped");
    Check(table.Alignments.Count == 2 && table.Alignments[1].EndsWith(':'), "Divider carries column alignments");
    var noDivider = MarkdownBlocks.Parse("a | b\nnot a divider");
    Check(noDivider.Count == 1 && noDivider[0] is MdText, "Pipes without a divider row stay one text block");
    var fenced = MarkdownBlocks.Parse("```\n| a |\n| - |\n```");
    Check(fenced.Count == 1 && fenced[0] is MdText, "Table shapes inside a fence stay text");
    var empty = MarkdownBlocks.Parse("");
    Check(empty.Count == 1 && ((MdText)empty[0]).Plain == "", "Empty body yields one empty text block");
}

// Response images: refs parse outside fences, roots gate reads, PNG
// bounds parse from IHDR, and import strips markdown to captions.
{
    var refs = ResponseImages.ParseFileRefs("Look ![a cat](/tmp/cat.png) here.");
    Check(refs.Count == 1 && refs[0].Caption == "a cat" && refs[0].Path == "/tmp/cat.png",
        "File image ref parses with caption and path");
    var angled = ResponseImages.ParseFileRefs("See ![x](<C:/pics/my cat.png>).");
    Check(angled.Count == 1 && angled[0].Path == "C:/pics/my cat.png", "Angle-bracket path with spaces parses");
    var fenced = ResponseImages.ParseFileRefs("```\n![no](/tmp/no.png)\n```\n> ![q](/tmp/q.png)\n`![c](/tmp/c.png)`\n\\![e](/tmp/e.png)");
    Check(fenced.Count == 0, "Fenced, quoted, inline-code, and escaped refs stay text");
    var web = ResponseImages.ParseFileRefs("![w](https://example.com/a.png)");
    Check(web.Count == 0 && ResponseImages.ParseWebRefs("![w](https://example.com/a.png)").Count == 1,
        "HTTPS refs route to the web parser, not the file parser");
    var many = ResponseImages.ParseFileRefs(string.Join("\n",
        Enumerable.Range(0, 10).Select(i => $"![{i}](/tmp/{i}.png)")));
    Check(many.Count == 8, "Capture caps at eight images per message");

    var root = Directory.CreateTempSubdirectory("converse-imgroot-").FullName;
    try
    {
        var inside = Path.Combine(root, "sub", "a.png");
        Check(ResponseImages.IsUnderRoot(inside, new[] { root }), "Nested path sits inside its root");
        Check(!ResponseImages.IsUnderRoot(Path.Combine(root, "..", "evil.png"), new[] { root }),
            "Traversal out of the root is refused");
        Check(!ResponseImages.IsUnderRoot(Path.Combine(root, "a.png"), new[] { Path.Combine(root, "other") }),
            "Sibling directory is outside the root");
    }
    finally { Cleanup(root); }

    byte[] Png(int w, int h)
    {
        var bytes = new byte[] { 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, (byte)'I', (byte)'H', (byte)'D', (byte)'R',
            (byte)(w >> 24), (byte)(w >> 16), (byte)(w >> 8), (byte)w,
            (byte)(h >> 24), (byte)(h >> 16), (byte)(h >> 8), (byte)h,
            8, 2, 0, 0, 0, 0, 0, 0, 0 };
        return bytes;
    }
    Check(ResponseImages.TryPngDimensions(Png(640, 480), out var w, out var h) && w == 640 && h == 480,
        "PNG dimensions parse from IHDR");
    Check(!ResponseImages.TryPngDimensions(Png(0, 480), out _, out _), "Zero-width PNG is rejected");
    Check(!ResponseImages.TryPngDimensions(new byte[] { 1, 2, 3 }, out _, out _), "Truncated bytes are rejected");
    Check(ResponseImages.IsSupportedImage(new byte[] { 0xFF, 0xD8, 0xFF, 0xE0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }),
        "JPEG magic is accepted");
    Check(!ResponseImages.IsSupportedImage(System.Text.Encoding.UTF8.GetBytes("not an image at all........")),
        "Text bytes are not an image");

    var dataDir = Directory.CreateTempSubdirectory("converse-imgdata-").FullName;
    var workDir = Directory.CreateTempSubdirectory("converse-imgwork-").FullName;
    try
    {
        var source = Path.Combine(workDir, "pic.png");
        await File.WriteAllBytesAsync(source, Png(100, 100));
        var session = new ChatSession { Entry = new AgentEntry { Directory = workDir } };
        var message = new ChatMessage { Role = "assistant", Text = $"Here ![a sunset]({source}) done." };
        Check(await ResponseImages.ImportAsync(dataDir, session, message)
            && message.Images.Count == 1 && File.Exists(message.Images[0])
            && message.Text == "Here a sunset done.",
            "Import stores the file, strips markdown to caption");
        var outside = new ChatMessage { Role = "assistant", Text = "![x](/etc/hosts)" };
        Check(!await ResponseImages.ImportAsync(dataDir, session, outside) && outside.Images.Count == 0
            && outside.Text.Contains("!["), "Refs outside the roots stay untouched");
    }
    finally { Cleanup(dataDir); Cleanup(workDir); }
}

// Picture requests earn agent delivery guidance (raw CLIs otherwise save
// SVGs and shell open a browser); ordinary prompts pass through untouched.
{
    Check(ImageGuidance.WantsPicture("show me a picture of a red truck"), "Picture request is detected");
    Check(ImageGuidance.WantsPicture("Generate an image of a spinning top"), "Image request is detected case-insensitively");
    Check(ImageGuidance.WantsPicture("draw me a cat"), "Draw request is detected");
    Check(!ImageGuidance.WantsPicture("show me the code for Dispose"), "Non-picture request is ignored");
    Check(!ImageGuidance.WantsPicture("picture this: a green build"), "Bare 'picture' without 'of' is ignored");
    Check(!ImageGuidance.WantsPicture("see ![x](y.png) now"), "Prompt already carrying markdown needs no steering");
    Check(ImageGuidance.WithGuidance("show me the diff") == "show me the diff", "Ordinary prompt is byte-identical");
    var guided = ImageGuidance.WithGuidance("draw me a cat");
    Check(guided.StartsWith("draw me a cat", StringComparison.Ordinal) && guided.Contains("![caption](absolute path)")
        && guided.Contains("Do not open a browser"), "Guidance appends PNG-plus-markdown delivery, keeps the prompt");
}

// Guidance reaches the runner while history keeps the original prompt.
{
    var root = Directory.CreateTempSubdirectory("converse-guidance-").FullName;
    try
    {
        var runner = new FakeRunner();
        var store = new SessionStore(root, runner);
        var session = store.Create(store.Entries.First(e => e.Engine == "codex"));
        session.Draft = "show me a picture of a red truck";
        store.Submit(session);
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (session.Busy && DateTime.UtcNow < deadline) await Task.Delay(20);
        Check(runner.Prompts.Count == 1 && runner.Prompts[0].StartsWith("show me a picture of a red truck", StringComparison.Ordinal)
            && runner.Prompts[0].Contains("Do not open a browser"), "Runner-bound picture prompt carries delivery guidance");
        Check(session.Messages.Any(m => m.Role == "user" && m.Text == "show me a picture of a red truck"),
            "Stored user message keeps the original prompt without guidance");
    }
    finally { Cleanup(root); }
}

// Command resolution: native exe wins, npm shims unwrap to node, unknown
// batches fall back to a quoted cmd.exe wrapper, misses resolve null.
{
    var bin = Directory.CreateTempSubdirectory("converse-cmd-").FullName;
    try
    {
        File.WriteAllText(Path.Combine(bin, "claude.exe"), "native");
        var shimDir = Path.Combine(bin, "shim");
        Directory.CreateDirectory(shimDir);
        File.WriteAllText(Path.Combine(shimDir, "codex.cmd"),
            "@IF EXIST \"%dp0%\\node.exe\" (\r\n  \"%dp0%\\node.exe\" \"%dp0%\\..\\lib\\codex.js\" %*\r\n)");
        Directory.CreateDirectory(Path.Combine(shimDir, "..", "lib"));
        File.WriteAllText(Path.GetFullPath(Path.Combine(shimDir, "..", "lib", "codex.js")), "cli");
        File.WriteAllText(Path.Combine(shimDir, "node.exe"), "node");
        File.WriteAllText(Path.Combine(bin, "tool.bat"), "batch");
        var dirs = new[] { bin, shimDir };
        var exe = CommandResolution.Resolve("claude", true, dirs);
        Check(exe is not null && exe.FileName.EndsWith("claude.exe") && !exe.UsesCmd && exe.PrefixArguments.Count == 0,
            "Native exe wins with no wrapper");
        var unwrapped = CommandResolution.Resolve("codex", true, dirs);
        Check(unwrapped is not null && unwrapped.FileName.EndsWith("node.exe") && !unwrapped.UsesCmd
            && unwrapped.PrefixArguments.Count == 1 && unwrapped.PrefixArguments[0].EndsWith("codex.js"),
            "npm shim unwraps to node plus script, never cmd.exe");
        var batch = CommandResolution.Resolve("tool", true, dirs);
        Check(batch is not null && batch.UsesCmd && batch.CmdPrefix is not null && batch.CmdPrefix.Contains("tool.bat"),
            "Unknown batch falls back to a quoted cmd.exe wrapper");
        Check(CommandResolution.Resolve("nope", true, dirs) is null, "Missing command resolves null");
        Check(CommandResolution.Resolve("  ", true, dirs) is null, "Blank command resolves null");
    }
    finally { Cleanup(bin); }
}

// Session Configure: retitle plus provider move, validated and persisted.
{
    var dir = Directory.CreateTempSubdirectory("converse-config-").FullName;
    try
    {
        var store = new SessionStore(dir, new FakeRunner());
        var session = store.Create(store.Entries.First(e => e.Engine == "claude"));
        var messages = session.Messages.Count;
        var codex = store.Entries.First(e => e.Engine == "codex");
        store.Configure(session, "  Research  ", codex, "C:\\work");
        Check(session.Title == "Research" && session.Entry.Command == "codex" && session.Entry.Engine == "codex"
            && session.Entry.Directory == "C:\\work" && session.Messages.Count == messages,
            "Configure retitles, moves provider and directory, keeps history");
        var reloaded = new SessionStore(dir, new FakeRunner());
        var same = reloaded.Sessions.First(s => s.Id == session.Id);
        Check(same.Title == "Research" && same.Entry.Command == "codex",
            "Configured session persists across restarts");
        var threw = false;
        try { store.Configure(session, "   ", codex, ""); } catch (ArgumentException) { threw = true; }
        Check(threw && session.Title == "Research", "Blank title is refused without touching the session");
        threw = false;
        try { store.Configure(session, "X", new AgentEntry { Name = "Bad", Command = " " }, ""); }
        catch (ArgumentException) { threw = true; }
        Check(threw && session.Entry.Command == "codex", "Blank provider command is refused");
    }
    finally { Cleanup(dir); }
}

// Configure isolation (review blocker): sessions own their entries, and the
// saved login binding survives a provider move.
{
    var dir = Directory.CreateTempSubdirectory("converse-configiso-").FullName;
    try
    {
        var store = new SessionStore(dir, new FakeRunner());
        var codex = store.Entries.First(e => e.Engine == "codex");
        var claudeTemplate = store.Entries.First(e => e.Engine == "claude");
        var aye = store.Create(claudeTemplate);
        var bee = store.Create(claudeTemplate);
        store.Configure(aye, "Aye", codex, "");
        Check(aye.Entry.Engine == "codex" && bee.Entry.Engine == "claude"
            && claudeTemplate.Engine == "claude"
            && !ReferenceEquals(aye.Entry, bee.Entry) && !ReferenceEquals(aye.Entry, codex),
            "Configure moves one session only; sibling and template keep their provider");
        aye.Entry.AccountName = "me@example.com";
        aye.Entry.AccountDirectory = "C:\\acct";
        aye.Entry.UseDefaultAccountStore = true;
        store.Configure(aye, "Aye", codex, "");
        Check(aye.Entry.AccountName == "me@example.com" && aye.Entry.AccountDirectory == "C:\\acct"
            && aye.Entry.UseDefaultAccountStore == true,
            "Configure preserves the session's saved login binding");
    }
    finally { Cleanup(dir); }
}

// A turn shaped text -> tool -> text keeps every block: later blocks that
// arrive only in assistant events are rescued (not dropped once anything
// streamed), and a subset final snapshot keeps the accumulation (PONG).
{
    var dir = Directory.CreateTempSubdirectory("converse-pong-").FullName;
    try
    {
        var store = new SessionStore(dir, new FakeRunner());
        var session = store.Create(store.Entries.First(e => e.Engine == "claude"));
        var response = new ChatMessage { Role = "assistant", Text = "" };
        void Line(string json) => store.Consume(json, session, response);
        Line("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\"}}}");
        Line("{\"type\":\"stream_event\",\"event\":{\"delta\":{\"type\":\"text_delta\",\"text\":\"PONG\"}}}");
        Line("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"PONG\"},{\"type\":\"tool_use\",\"name\":\"Glob\"}]}}");
        Line("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Both files read now\"}]}}");
        Line("{\"type\":\"result\",\"result\":\"Both files read now\"}");
        Check(response.Text.Contains("PONG", StringComparison.Ordinal)
            && response.Text.Contains("Both files read now", StringComparison.Ordinal),
            "Unstreamed later blocks survive; subset snapshot keeps PONG");
        Check(response.Text.IndexOf("PONG", StringComparison.Ordinal)
            == response.Text.LastIndexOf("PONG", StringComparison.Ordinal),
            "Already-streamed blocks are not duplicated by their assistant event");

        var streamed = store.Create(store.Entries.First(e => e.Engine == "claude"));
        var streamedResponse = new ChatMessage { Role = "assistant", Text = "" };
        void SLine(string json) => store.Consume(json, streamed, streamedResponse);
        SLine("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\"}}}");
        SLine("{\"type\":\"stream_event\",\"event\":{\"delta\":{\"type\":\"text_delta\",\"text\":\"A\"}}}");
        SLine("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\"}}}");
        SLine("{\"type\":\"stream_event\",\"event\":{\"delta\":{\"type\":\"text_delta\",\"text\":\"B\"}}}");
        SLine("{\"type\":\"result\",\"result\":\"B\"}");
        Check(streamedResponse.Text == "A\n\nB", "Last-block-only snapshot keeps earlier streamed blocks");
    }
    finally { Cleanup(dir); }
}

// CLI pipes are UTF-8 on every platform: .NET on Windows would otherwise
// decode the redirected output as the ANSI code page (mojibake). The child
// is this same binary in emit mode, so the wire bytes are exact on every
// platform (a powershell child follows console encoding and proved nothing).
{
    var dir = Directory.CreateTempSubdirectory("converse-utf8-").FullName;
    try
    {
        var store = new SessionStore(dir, new FakeRunner());
        var session = store.Create(store.Entries.First(e => e.Engine == "codex"));
        session.Entry.Command = Environment.ProcessPath!;
        // A user-local SDK (no global install) needs DOTNET_ROOT to reach
        // grandchildren: the apphost resolves the runtime from it.
        var runtimeDir = System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory();
        Environment.SetEnvironmentVariable("DOTNET_ROOT",
            Path.GetFullPath(Path.Combine(runtimeDir, "..", "..", "..")));
        var lines = new List<string>();
        var exit = await new ProcessAgentRunner().RunAsync(session,
            new[] { "--emit-utf8" }, "ignored", lines.Add, CancellationToken.None);
        Check(exit == 0 && lines.Count == 1 && lines[0] == "–",
            "Runner decodes multibyte UTF-8 CLI output exactly");
    }
    finally { Cleanup(dir); }
}

// Pin the actual process boundary: rich image bytes on stdin, no image argv.
{
    var dir = Directory.CreateTempSubdirectory("converse-images-").FullName;
    try
    {
        var path = Path.Combine(dir, "extensionless-remote-blob");
        var png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV9sAAAAASUVORK5CYII=");
        await File.WriteAllBytesAsync(path, png);
        var capture = new FakeRunner();
        var store = new SessionStore(dir, capture);
        var session = store.Create(store.Entries.First(e => e.Engine == "claude"));
        session.Busy = true; session.Draft = "Queued image"; session.Attachments.Add(path);
        store.Submit(session);
        session.Busy = false; store.RunNext(session);
        var sentDeadline = DateTime.UtcNow.AddSeconds(3);
        while (capture.Prompts.Count == 0 && DateTime.UtcNow < sentDeadline) await Task.Delay(10);
        Check(capture.Prompts.Count == 1 && capture.Prompts[0].Contains("image/png") && session.Messages.Any(m => m.Role == "user" && m.Images.Count == 1),
            "Queued Claude image reaches the runner as rich content while remaining in transcript history");
        var input = await ProviderInput.CreateAsync("claude", "What is this? – \nsecond line", new[] { path, path });
        using var json = System.Text.Json.JsonDocument.Parse(input);
        var blocks = json.RootElement.GetProperty("message").GetProperty("content");
        Check(blocks.GetArrayLength() == 3 && blocks[0].GetProperty("text").GetString()!.Contains("second line")
            && blocks[1].GetProperty("source").GetProperty("media_type").GetString() == "image/png"
            && Convert.FromBase64String(blocks[1].GetProperty("source").GetProperty("data").GetString()!).SequenceEqual(png),
            "Claude prompt contains real image bytes and text, including extensionless remote blobs");
        var turnArgs = TurnArguments.For(session, new[] { path });
        Check(turnArgs.Contains("--input-format") && turnArgs.Contains("stream-json"), "Claude image turns enable structured stdin");
        session.Started = true; session.RemoteID = "existing-session";
        Check(TurnArguments.For(session, new[] { path }).Contains("existing-session"), "Image turns preserve Claude resume identity");
        Check(!TurnArguments.For(session, Array.Empty<string>()).Contains("--input-format")
            && await ProviderInput.CreateAsync("codex", "plain", new[] { path }) == "plain", "Text turns and Codex image arguments stay compatible");
        session.Entry.Command = Environment.ProcessPath!;
        var lines = new List<string>();
        var exit = await new ProcessAgentRunner().RunAsync(session, new[] { "--echo-stdin", "--input-format", "stream-json" }, input, lines.Add, CancellationToken.None);
        Check(exit == 0 && lines.Count == 1 && lines[0] == input, "Real process receives complete UTF-8 multimodal JSON through stdin");
        await File.WriteAllTextAsync(path, "not an image");
        var refused = false;
        try { await ProviderInput.CreateAsync("claude", "prompt", new[] { path }); } catch (InvalidOperationException) { refused = true; }
        Check(refused, "Invalid image fails explicitly instead of silently sending text only");
    }
    finally { Cleanup(dir); }
}
{
    var dir = Directory.CreateTempSubdirectory("converse-retry-").FullName;
    try
    {
        var store = new SessionStore(dir, new FakeRunner());
        var session = store.Create(store.Entries.First(e => e.Engine == "codex"));
        var response = new ChatMessage { Role = "assistant", Text = "Partial reply" };
        session.Messages.Add(response);
        var before = session.Messages.Count;
        for (var attempt = 1; attempt <= 5; attempt++) store.Consume(System.Text.Json.JsonSerializer.Serialize(new { type = "error", message = $"Reconnecting... {attempt}/5 (stream disconnected)" }), session, response);
        Check(session.Messages.Count == before && !session.TurnFailed && session.Status.StartsWith("Waiting for OpenAI"), "Five reconnects produce one temporary status and do not fail the turn");
        store.Consume("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Recovered\"}}", session, response);
        Check(session.RetryDetail is null && session.Status == "Working…" && response.Text.Contains("Recovered"), "Next provider output clears waiting status and preserves partial response");
        store.Consume("Reconnecting... 1/5 (stream disconnected)", session, response);
        Check(session.Messages.Count == before, "Raw stderr reconnect lines are transient too");
        store.Consume("{\"type\":\"error\",\"willRetry\":false,\"message\":\"Connection lost permanently\"}", session, response);
        Check(session.RetryDetail is null && session.TurnFailed && session.Messages.Last().Text.Contains("permanently"), "Terminal connection errors remain visible and fail the turn");
        Check(ProviderRetry.Detail("{\"type\":\"assistant\",\"message\":\"Reconnecting... 1/5\"}") is null
            && ProviderRetry.Detail("A tool printed Reconnecting... 1/5") is null, "Retry classification does not hide assistant content or unrelated diagnostics");
        Check(ProviderRetry.Detail("{\"type\":\"system\",\"subtype\":\"api_retry\"}") is not null
            && ProviderRetry.Status("claude").Contains("Claude"), "Claude retry telemetry uses provider-specific waiting status");
    }
    finally { Cleanup(dir); }
}

await AgentChecks.Run(Check, JoinPair);

Console.WriteLine(failures == 0 ? "All core checks passed" : $"{failures} checks FAILED");
foreach (var label in failedLabels) Console.WriteLine("FAILED: " + label);
return failures == 0 ? 0 : 1;

sealed class GatedRunner : Converse.Core.IAgentRunner
{
    public TaskCompletionSource<bool> Gate { get; set; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public List<string> Prompts { get; } = new();
    public async Task<int> RunAsync(Converse.Core.ChatSession session, IReadOnlyList<string> arguments, string prompt,
        Action<string> onLine, CancellationToken cancellationToken)
    {
        Prompts.Add(prompt);
        var done = await Task.WhenAny(Gate.Task, Task.Delay(-1, cancellationToken));
        if (done != Gate.Task) return 1;
        Gate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        onLine("{\"type\":\"thread.started\",\"thread_id\":\"t\"}");
        onLine("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"gated reply\"}}");
        onLine("{\"type\":\"turn.completed\"}");
        return 0;
    }
}

sealed class FakeRunner : Converse.Core.IAgentRunner
{
    public readonly List<string> Prompts = new();
    public TaskCompletionSource<bool>? Gate;
    public async Task<int> RunAsync(Converse.Core.ChatSession session, IReadOnlyList<string> arguments, string prompt,
        Action<string> onLine, CancellationToken cancellationToken)
    {
        Prompts.Add(prompt);
        if (Gate is not null) await Gate.Task;
        onLine("{\"type\":\"thread.started\",\"thread_id\":\"thread-1\"}");
        onLine("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"fake reply\"}}");
        var finalIndex = arguments.ToList().IndexOf("--output-last-message");
        if (finalIndex >= 0) File.WriteAllText(arguments[finalIndex + 1], "fake reply\n");
        onLine("{\"type\":\"turn.completed\"}");
        return 0;
    }
}
