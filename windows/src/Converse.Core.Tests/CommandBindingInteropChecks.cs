using System.Collections.Concurrent;
using Converse.Core;

// Explicit cross-platform probes of command payload binding, never a
// production Group: a Core viewer against the Mac --ipad-home-fixture, and an
// isolated Core home for the Mac --core-command-interop viewer.
// scripts/command-binding-interop.sh runs both directions.
internal static class CommandBindingInteropChecks
{
    public const string HomeTitle = "Core command fixture";
    static byte[] Utf8(string value) => System.Text.Encoding.UTF8.GetBytes(value);

    public static async Task<int> RunViewer(string host, int port)
    {
        var folder = Directory.CreateTempSubdirectory("converse-command-binding-viewer-").FullName;
        var viewer = new DeviceSyncService(folder, new SessionStore(folder), "Isolated Windows command viewer");
        viewer.PairingConfirmation = _ => Task.FromResult(true);
        var acks = new ConcurrentQueue<(Guid Id, DeviceAckPayload Ack)>();
        viewer.AckReceivedForTest += (id, ack) => acks.Enqueue((id, ack));
        var sent = new ConcurrentDictionary<Guid, byte[]>();
        viewer.EnvelopeSentForTest += e => { if (e.Kind == DeviceKind.Command && e.CommandID is { } id && e.Payload is { } bytes) sent.TryAdd(id, bytes); };
        async Task Until(Func<bool> predicate, string label)
        {
            var deadline = DateTime.UtcNow.AddSeconds(30);
            while (!predicate() && DateTime.UtcNow < deadline) await Task.Delay(50);
            if (!predicate()) throw new InvalidOperationException(label);
            Console.WriteLine("PASS: " + label);
        }
        try
        {
            await viewer.StartAsync(0, false);
            await viewer.JoinGroupByAddressAsync(host, port, "");
            await Until(() => viewer.Homes.Values.Any(h => h.Rows.Any(r => r.Title == "iPad interop fixture" && r.Engine != "parking")), "Windows discovers the isolated Mac home session");
            var gid = viewer.Homes.Values.SelectMany(h => h.Rows).First(r => r.Title == "iPad interop fixture" && r.Engine != "parking").GlobalID;
            await viewer.AcquireRemoteAsync(gid);
            await Until(() => viewer.RemoteLeases.ContainsKey(gid) && viewer.RemoteTranscripts.ContainsKey(gid), "Windows takes the Mac session");
            string Title() => viewer.RemoteTranscripts.GetValueOrDefault(gid)?.Title ?? "";
            DeviceAckPayload? Last(Guid id) => acks.LastOrDefault(a => a.Id == id).Ack;
            async Task<DeviceAckPayload?> Raw(Guid id, byte[] payload)
            {
                var before = acks.Count(a => a.Id == id);
                if (!await viewer.SendRawCommandForTestAsync(gid, id, payload)) throw new InvalidOperationException("Raw resend had no lease or home");
                var deadline = DateTime.UtcNow.AddSeconds(15);
                while (acks.Count(a => a.Id == id) == before && DateTime.UtcNow < deadline) await Task.Delay(25);
                return acks.Count(a => a.Id == id) > before ? Last(id) : null;
            }
            var first = await viewer.SendRemoteCommandAsync(gid, new DeviceCommandPayload { Action = "rename", Text = "Binding A" });
            await Until(() => first is { } id && Last(id) is { Outcome: "completed" }, "Mac home applies a Windows command");
            var second = await viewer.SendRemoteCommandAsync(gid, new DeviceCommandPayload { Action = "rename", Text = "Binding B" });
            await Until(() => second is { } id && Last(id) is { Outcome: "completed" } && Title() == "Binding B", "Mac home applies a second Windows command");
            var exact = await Raw(first!.Value, sent[first.Value]);
            var permuted = await Raw(first.Value, Utf8("{\"text\":\"Binding A\",\"blobHashes\":[],\"action\":\"rename\"}"));
            await Task.Delay(500);
            Check(exact is { Outcome: "completed", Detail: "Already recorded on home." } && permuted is { Outcome: "completed", Detail: "Already recorded on home." } && Title() == "Binding B",
                "Mac home dedupes exact and key-permuted Windows re-sends of one command ID, applying it once");
            var changed = await Raw(first.Value, Utf8("{\"action\":\"rename\",\"blobHashes\":[],\"text\":\"Binding C\"}"));
            Check(changed is { Outcome: "rejected", Detail: "Command ID reused with different content." } && Title() == "Binding B", "Mac home rejects a Windows command ID reused with different text");
            var extra = Guid.NewGuid();
            var extraFirst = await Raw(extra, Utf8("{\"action\":\"rename\",\"blobHashes\":[],\"text\":\"Binding D\",\"zExtra\":{\"b\":1,\"a\":2}}"));
            var extraPermuted = await Raw(extra, Utf8("{\"zExtra\":{\"a\":2,\"b\":1},\"text\":\"Binding D\",\"action\":\"rename\",\"blobHashes\":[]}"));
            var extraChanged = await Raw(extra, Utf8("{\"action\":\"rename\",\"blobHashes\":[],\"text\":\"Binding D\",\"zExtra\":{\"b\":1,\"a\":3}}"));
            await Task.Delay(500);
            Check(extraFirst is { Outcome: "completed" } && extraPermuted is { Outcome: "completed", Detail: "Already recorded on home." }
                && extraChanged is { Outcome: "rejected", Detail: "Command ID reused with different content." } && Title() == "Binding D",
                "Mac home binds unknown fields from Windows: permuted re-send dedupes, a changed value is rejected");
            await viewer.ReleaseRemoteAsync(gid);
            Console.WriteLine(Failures == 0 ? "PASS: Windows viewer to Mac home command binding complete" : "FAIL: Windows viewer to Mac home command binding");
            return Failures == 0 ? 0 : 1;
        }
        catch (Exception ex) { Console.WriteLine("FAIL: " + ex.Message + "; status=" + viewer.ServiceStatus + "; outcome=" + viewer.LastOutcome + "; profile=" + folder); return 1; }
        finally { viewer.Dispose(); }
    }

    static int Failures;
    static void Check(bool ok, string label)
    {
        Console.WriteLine((ok ? "PASS: " : "FAIL: ") + label);
        if (!ok) Failures++;
    }

    // Isolated Core home: one session, a fresh Group, automatic approval of
    // join requests, until the folder's stop file appears or three minutes pass.
    public static async Task<int> RunHome(string folder)
    {
        if (!Path.GetFileName(Path.GetDirectoryName(Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar))!).StartsWith("converse-command-binding.")) return 2;
        var store = new SessionStore(folder);
        var session = store.Create(store.Entries.First(e => e.Engine == "codex"));
        session.Title = HomeTitle;
        store.Save();
        using var home = new DeviceSyncService(folder, store, "Isolated Core home");
        home.PairingConfirmation = _ => Task.FromResult(true);
        await home.StartAsync(0, enableDiscovery: false, loopbackOnly: true);
        await home.CreateGroupAsync("Command binding fixture");
        await File.WriteAllTextAsync(Path.Combine(folder, "port"), home.ListeningPort.ToString());
        var deadline = DateTime.UtcNow.AddMinutes(3);
        var titles = new List<string> { session.Title };
        while (DateTime.UtcNow < deadline && !File.Exists(Path.Combine(folder, "stop")))
        {
            if (home.GroupRequests.Count > 0)
            {
                await home.ReviewGroupRequestAsync(home.GroupRequests[0]);
                await home.ApproveGroupReviewAsync();
            }
            if (titles[^1] != session.Title) { titles.Add(session.Title); Console.WriteLine("Core home title: " + session.Title); }
            await Task.Delay(25);
        }
        await File.WriteAllLinesAsync(Path.Combine(folder, "titles"), titles);
        return 0;
    }
}
