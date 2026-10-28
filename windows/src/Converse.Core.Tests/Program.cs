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
