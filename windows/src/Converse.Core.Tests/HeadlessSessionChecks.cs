using Converse.Core;
using System.Text.Json;
using System.Text.Json.Nodes;

static class HeadlessSessionChecks
{
    public static async Task Run(Action<bool, string> check, Func<DeviceSyncService, DeviceSyncService, Func<bool>, Task<bool>> join)
    {
        var calls = new List<string>();
        var catalog = await CodexModelCatalog.ReadAsync((method, args) =>
        {
            calls.Add(method);
            if (method == "initialize") return Task.FromResult(new JsonObject());
            check(args["includeHidden"]?.GetValue<bool>() == true, "Codex discovery includes the complete CLI catalog");
            return Task.FromResult(JsonNode.Parse(args["cursor"] is null
                ? "{\"data\":[{\"model\":\"model-a\",\"displayName\":\"Model A\",\"isDefault\":true,\"supportedReasoningEfforts\":[{\"reasoningEffort\":\"high\"}]}],\"nextCursor\":\"second\"}"
                : "{\"data\":[{\"model\":\"model-b\",\"displayName\":\"Model B\",\"supportedReasoningEfforts\":[{\"reasoningEffort\":\"ultra\"}]}]}")!.AsObject());
        });
        check(catalog.Select(m => m.Id).SequenceEqual(new[] { "model-a", "model-b" }) && catalog[1].Efforts.SequenceEqual(new[] { "ultra" }) && calls.SequenceEqual(new[] { "initialize", "model/list", "model/list" }), "Codex catalog follows pagination and model-specific efforts without opening a thread or turn");
        var duplicateCursorRejected = false;
        try { await CodexModelCatalog.ReadAsync((m, _) => Task.FromResult(JsonNode.Parse(m == "initialize" ? "{}" : "{\"data\":[],\"nextCursor\":\"same\"}")!.AsObject())); }
        catch (InvalidDataException) { duplicateCursorRejected = true; }
        check(duplicateCursorRejected, "Codex discovery bounds repeated pagination cursors");
        var cache = new CodexModelCatalog(); var probes = 0;
        var gate = new TaskCompletionSource<IReadOnlyList<CodexModel>>(TaskCreationOptions.RunContinuationsAsynchronously);
        cache.Probe = _ => { probes++; return gate.Task; };
        var entry = new AgentEntry { Engine = "codex", Command = "unused", Directory = Path.GetTempPath(), AccountDirectory = "login-a" };
        var one = cache.GetAsync(entry); var two = cache.GetAsync(entry); gate.SetResult(catalog); await Task.WhenAll(one, two);
        check(probes == 1 && ReferenceEquals(one, two) && (await cache.GetAsync(entry)).EffortsFor("model-b").SequenceEqual(new[] { "ultra" }), "Concurrent model reads share a bounded cached probe and retain selected-model effort options");
        var another = entry.Copy(); another.AccountDirectory = "login-b"; await cache.GetAsync(another);
        check(probes == 2, "Codex catalog cache never mixes different CLI login directories");
        var failedCache = new CodexModelCatalog { Probe = _ => throw new IOException("private diagnostic must not leak") };
        var failed = await failedCache.GetAsync(entry);
        check(failed.Models.Count == 0 && failed.Error?.Contains("private diagnostic") == false && failed.ExpiresAt < DateTime.UtcNow.AddMinutes(1), "Failed catalog reads return an honest bounded retry without leaking CLI diagnostics");

        var root = Path.Combine(Path.GetTempPath(), "converse-headless-" + Guid.NewGuid());
        var store = new SessionStore(Path.Combine(root, "home"), new FakeRunner());
        var catalogReady = new TaskCompletionSource<IReadOnlyList<CodexModel>>(TaskCreationOptions.RunContinuationsAsynchronously);
        store.CodexModels.Probe = _ => catalogReady.Task;
        var session = store.Create(new AgentEntry { Engine = "codex", Command = "unused", Directory = root, Name = "Disposable" });
        session.Draft = "Preserve this draft"; session.Choices.Model = "model-b"; store.Save();
        using var home = new DeviceSyncService(store.Folder, store, "Headless");
        using var viewer = new DeviceSyncService(Path.Combine(root, "viewer"), new SessionStore(Path.Combine(root, "viewer"), new FakeRunner()), "Viewer");
        using var closer = new DeviceSyncService(Path.Combine(root, "closer"), new SessionStore(Path.Combine(root, "closer"), new FakeRunner()), "Closer");
        foreach (var d in new[] { home, viewer, closer }) { d.PairingConfirmation = _ => Task.FromResult(true); await d.StartAsync(0); }
        async Task<bool> Until(Func<bool> done) { var deadline = DateTime.UtcNow.AddSeconds(10); while (!done() && DateTime.UtcNow < deadline) await Task.Delay(20); return done(); }
        var gid = new DeviceGlobalID(home.DeviceId, session.Id).ToString();
        check(await join(home, viewer, () => viewer.Homes.GetValueOrDefault(home.DeviceId)?.Rows.Any(r => r.GlobalID == gid) == true), "Headless model/close fixture joins authenticated group");
        await viewer.AcquireRemoteAsync(gid);
        check(await Until(() => viewer.RemoteTranscripts.GetValueOrDefault(gid)?.Draft == "Preserve this draft") && !catalogReady.Task.IsCompleted,
            "Slow model discovery never blocks the initial lease or transcript");
        catalogReady.SetResult(catalog);
        check(await Until(() => viewer.RemoteTranscripts.GetValueOrDefault(gid)?.ModelOptions.Count == 2) && viewer.RemoteTranscripts[gid].EffortOptions.SequenceEqual(new[] { "ultra" }), "Headless snapshot sends live Codex models and selected-model effort levels to the viewer");
        check(await join(home, closer, () => closer.Homes.GetValueOrDefault(home.DeviceId)?.Rows.Any(r => r.GlobalID == gid) == true), "A second group member can manage a headless home");
        session.LastStreamSaveUtc = DateTime.UtcNow;
        var streamed = new ChatMessage { Role = "assistant", Text = "" }; session.Messages.Add(streamed);
        var started = System.Diagnostics.Stopwatch.StartNew();
        store.Consume("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Prompt streaming without disk save\"}}", session, streamed);
        var deadline = DateTime.UtcNow.AddSeconds(1);
        while (DateTime.UtcNow < deadline && viewer.RemoteTranscripts[gid].Messages.All(m => m.Text != streamed.Text)) await Task.Delay(10);
        check(viewer.RemoteTranscripts[gid].Messages.Any(m => m.Text == streamed.Text) && started.ElapsedMilliseconds < 1000,
            "A final streamed fragment reaches a remote viewer within one second, without waiting for another fragment or disk checkpoint");
        var beforeCreate = store.Sessions.Count;
        var newRemote = await closer.RequestParticipantAsync(home.DeviceId, "session.create", provider: "codex");
        var newID = newRemote.Target is null ? null : DeviceGlobalID.Parse(newRemote.Target);
        var newSession = store.Sessions.FirstOrDefault(s => s.Id == newID?.Session);
        check(newRemote.Outcome == "completed" && newSession?.Entry.Engine == "codex" && newSession.Busy == false && store.Sessions.Count == beforeCreate + 1,
            "Group member creates a remote provider session without starting paid work or taking a lease");
        check(await Until(() => viewer.Homes[home.DeviceId].Rows.Any(r => r.GlobalID == newRemote.Target)), "Created remote session appears in other viewers' sidebars");
        var persistedCreation = new SessionStore(store.Folder, new FakeRunner());
        check(persistedCreation.Sessions.Any(s => s.Id == newSession?.Id) && persistedCreation.ParticipantReceipts.Any(r => r.Response.Target == newRemote.Target), "Remote creation and receipt survive one archive commit");
        check((await closer.RequestParticipantAsync(home.DeviceId, "session.create", provider: "shell")).Outcome == "rejected", "Remote creation rejects arbitrary providers and commands");
        home.SetAcceptingWork(false);
        check((await closer.RequestParticipantAsync(home.DeviceId, "session.create", provider: "claude")).Outcome == "rejected" && store.Sessions.Count == beforeCreate + 1, "Remote creation respects closed update admission");
        home.SetAcceptingWork(true);
        var result = await closer.RequestParticipantAsync(home.DeviceId, "session.close", gid);
        check(result.Outcome == "completed" && !store.Sessions.Contains(session) && !closer.RemoteLeases.ContainsKey(gid), "Group member closes a remote session without taking its display lease");
        check(await Until(() => !viewer.RemoteTranscripts.ContainsKey(gid) && !viewer.RemoteLeases.ContainsKey(gid) && viewer.Homes[home.DeviceId].Rows.All(r => r.GlobalID != gid)), "Remote close immediately removes another viewer's pane, lease and sidebar row");
        var recovered = JsonSerializer.Deserialize<ChatSession>(File.ReadAllBytes(Path.Combine(store.Folder, "Deleted Sessions", session.Id.ToString("D") + ".json")));
        var reopened = new SessionStore(store.Folder, new FakeRunner());
        check(recovered?.Draft == "Preserve this draft" && reopened.Sessions.All(s => s.Id != session.Id) && reopened.ParticipantReceipts.Any(r => r.Response.Target == gid && r.Response.Outcome == "completed"), "Remote close preserves recovery data and atomically persists deletion with its receipt");
        check((await closer.RequestParticipantAsync(home.DeviceId, "session.close", gid)).Outcome == "completed", "Closing an already closed session is harmless");
        var wrongHome = new DeviceGlobalID(viewer.DeviceId, session.Id).ToString();
        check((await closer.RequestParticipantAsync(home.DeviceId, "session.close", wrongHome)).Outcome == "rejected", "Remote close cannot target a same-UUID session on another home");
        var keep = store.Create(entry); keep.Draft = "Must survive a failed backup";
        var backupDir = Path.Combine(store.Folder, "Deleted Sessions");
        File.Delete(Path.Combine(backupDir, session.Id.ToString("D") + ".json")); Directory.Delete(backupDir); File.WriteAllText(backupDir, "block directory creation");
        var keepID = new DeviceGlobalID(home.DeviceId, keep.Id).ToString();
        check((await closer.RequestParticipantAsync(home.DeviceId, "session.close", keepID)).Outcome == "rejected" && store.Sessions.Contains(keep) && !keep.Interrupted, "Failed recovery backup prevents remote close before stopping or deleting anything");
    }
}
