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
