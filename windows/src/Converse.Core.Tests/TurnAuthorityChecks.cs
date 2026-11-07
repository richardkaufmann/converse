using Converse.Core;
using System.Text.Json;

// A reply acts with the authority captured when its own prompt started.
// The session goes idle before a reply's image import finishes, so another
// turn can start in that gap; the held reply must not borrow its
// provenance, hop or app-control depth.
static class TurnAuthorityChecks
{
    const string Result = "[Converse app operation result]";

    static async Task<bool> Eventually(Func<bool> done, int seconds = 30)
    {
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
        return done();
    }
    static string Fence(object command) => "\n\n```converse\n" + JsonSerializer.Serialize(command) + "\n```";
    static string CreateAgent(string title) => Fence(new { command = "app-control", action = "create-agent", title, objective = "Fixture" });
    static readonly string Inspect = Fence(new { command = "app-control", action = "inspect" });

    sealed class Runner : IAgentRunner
    {
        public Func<string, string> Reply = _ => "Done.";
        public readonly List<string> Prompts = new();
        public Task<int> RunAsync(ChatSession session, IReadOnlyList<string> arguments, string prompt, Action<string> line, CancellationToken token)
        {
            lock (Prompts) Prompts.Add(prompt);
            // A multi-step turn: prose streams first, and the final result is
            // the whole-reply command, so the visible reply has text to import.
            var reply = Reply(prompt); var at = reply.IndexOf("\n\n```converse", StringComparison.Ordinal);
            if (at >= 0)
            {
                line(JsonSerializer.Serialize(new { type = "assistant", message = new { content = new[] { new { type = "text", text = reply[..at] } } } }));
                reply = reply[(at + 2)..];
            }
            line(JsonSerializer.Serialize(new { type = "result", result = reply, is_error = false, session_id = session.Id.ToString() }));
            return Task.FromResult(0);
        }
        public int Count(string text) { lock (Prompts) return Prompts.Count(p => p.Contains(text)); }
    }

    // A taught App Support-style session whose handler mirrors the Windows
    // app's: execute with the reply's authority, then continue or notice.
    sealed class Fixture : IDisposable
    {
        public readonly Runner Runner = new();
        public readonly SessionStore Store;
        public readonly DeviceSyncService Devices;
        public readonly ChatSession Session;
        public readonly List<(TurnAuthority Authority, string Result)> Requests = new();
        public readonly TaskCompletionSource HeldAt = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource Release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public string? HoldMarker;
        public Fixture(string root, string name)
        {
            Store = new SessionStore(Path.Combine(root, name), Runner);
            Devices = new DeviceSyncService(Store.Folder, Store);
            Session = Store.Create(Store.Entries.First(e => e.Engine == "claude"));
            // A fixed title keeps prompt markers out of inspect results.
            Session.Title = "Authority fixture";
            Session.SupportTeachingVersion = AppSupportTeaching.Version; Session.MessagingEnabled = true; Store.Save();
            Store.ImportResponseImages = async (_, _, message) =>
            {
                if (HoldMarker is { } marker && message.Text.Contains(marker)) { HoldMarker = null; HeldAt.TrySetResult(); await Release.Task; }
                return false;
            };
            Store.AppSupportRequest = (source, command, authority) =>
            {
                string result;
                try { result = AppSupportActions.Execute(Store, source, authority, command, null); }
                catch (ArgumentException e) { result = "App operation blocked: " + e.Message; }
                lock (Requests) Requests.Add((authority, result));
                AppSupportActions.Continue(Store, source, authority, result);
                return Task.CompletedTask;
            };
        }
        public (TurnAuthority Authority, string Result)[] Seen() { lock (Requests) return Requests.ToArray(); }
        public bool Replied(string text) => !Session.Busy && Session.Messages.Any(m => m.Role == "assistant" && m.Text.Contains(text));
        public bool Noticed(string text) => Session.Messages.Any(m => m.Role == "notice" && m.Text.Contains(text));
        // Hold the reply carrying marker at image import, then submit a human
        // turn into the idle session and let it finish before releasing.
        public async Task<bool> HumanTurnDuringImport()
        {
            if (await Task.WhenAny(HeldAt.Task, Task.Delay(TimeSpan.FromSeconds(30))) != HeldAt.Task || Session.Busy) return false;
            Session.Draft = "HUMAN-NEXT"; Store.Submit(Session);
            var ok = await Eventually(() => Replied("Human reply."));
            Release.TrySetResult();
            return ok;
        }
        public void Dispose() => Devices.Dispose();
    }

    public static async Task Run(Action<bool, string> check)
    {
        var root = Directory.CreateTempSubdirectory("converse-turn-authority-").FullName;
        try
        {
            foreach (var (label, held) in new[] {
                ("background", new PendingPrompt { Text = "PEER-REQUEST", Autonomous = true }),
                ("forwarded", new PendingPrompt { Text = "PEER-REQUEST", Autonomous = true, Hop = 2 }) })
            {
                using var f = new Fixture(root, label);
                f.HoldMarker = "HELD-PEER";
                f.Runner.Reply = p => p.Contains("PEER-REQUEST") ? "HELD-PEER" + CreateAgent("Peer agent") : "Human reply.";
                f.Session.Pending.Add(held); f.Store.RunNext(f.Session);
                check(await f.HumanTurnDuringImport(), "A human turn starts while a " + label + " reply is held at image import");
                await Eventually(() => f.Seen().Length == 1 && !f.Session.Busy);
                var seen = f.Seen();
                check(seen.Length == 1 && seen[0].Result.Contains("Background or forwarded turns cannot configure the app") && seen[0].Authority.PromptID == held.Id
                    && !f.Store.Sessions.Any(s => s.Title == "Peer agent"), "A held " + label + " reply's app control is rejected after a human turn starts");
                check(f.Session.Pending.Count == 0 && f.Runner.Count(Result) == 0 && f.Noticed("App operation blocked"), "A held " + label + " reply queues no authorized continuation");
            }
            {
                // Opposite ordering: a human reply held while a peer turn runs
                // keeps its foreground authority, and its continuation is depth 1.
                using var f = new Fixture(root, "foreground-held");
                f.HoldMarker = "HELD-HUMAN";
                f.Runner.Reply = p => p.Contains(Result + "\nCreated paused") ? "Checking." + Inspect
                    : p.Contains(Result) ? "Created it."
                    : p.Contains("HUMAN-ASK") ? "HELD-HUMAN" + CreateAgent("Human agent") : "Peer handled.";
                f.Session.Draft = "HUMAN-ASK"; f.Store.Submit(f.Session);
                var heldAt = await Task.WhenAny(f.HeldAt.Task, Task.Delay(TimeSpan.FromSeconds(30))) == f.HeldAt.Task && !f.Session.Busy;
                f.Session.Pending.Add(new PendingPrompt { Text = "PEER-NEXT", Autonomous = true, Hop = 3 }); f.Store.RunNext(f.Session);
                var peerRan = await Eventually(() => f.Replied("Peer handled."));
                f.Release.TrySetResult();
                await Eventually(() => f.Replied("Created it."));
                var seen = f.Seen();
                check(heldAt && peerRan && seen.Length == 2 && seen[0].Result.Contains("Created paused") && f.Store.Sessions.Any(s => s.Title == "Human agent"),
                    "A held human reply's app control is accepted after a peer turn starts");
                check(seen.Length == 2 && seen[1].Authority is { Background: false, Hop: 0, AppControlDepth: 1 } && !seen[1].Result.StartsWith("App operation blocked"),
                    "The held human reply's continuation is one level deeper than that reply");
            }
            {
                using var f = new Fixture(root, "depth-cap");
                f.Runner.Reply = p => p.Contains("HUMAN-LOOP") || p.Contains(Result) ? "Again." + Inspect : "Human reply.";
                f.Session.Draft = "HUMAN-LOOP"; f.Store.Submit(f.Session);
                await Eventually(() => f.Noticed("Setup action limit reached") && !f.Session.Busy);
                var seen = f.Seen();
                check(seen.Length == AppSupportActions.MaxDepth + 1
                    && seen.Select(r => r.Authority.AppControlDepth).SequenceEqual(Enumerable.Range(0, AppSupportActions.MaxDepth + 1))
                    && seen.Take(AppSupportActions.MaxDepth).All(r => !r.Result.StartsWith("App operation blocked")) && seen[^1].Result.Contains("Setup action limit reached"),
                    "Foreground app control is accepted until the continuation depth cap");
                check(f.Session.Pending.Count == 0 && f.Runner.Count(Result) == AppSupportActions.MaxDepth, "The depth cap stops further continuations");
            }
            {
                // A continuation held at depth 7 keeps that depth when a human
                // turn starts; its own continuation is depth 8, not 1.
                using var f = new Fixture(root, "depth-held");
                f.HoldMarker = "HELD-SEVEN";
                f.Runner.Reply = p => p.Contains("DEPTH-SEVEN") ? "HELD-SEVEN" + Inspect : p.Contains(Result) ? "Again." + Inspect : "Human reply.";
                f.Session.Pending.Add(new PendingPrompt { Text = Result + "\nDEPTH-SEVEN", AppControlDepth = AppSupportActions.MaxDepth - 1 }); f.Store.RunNext(f.Session);
                check(await f.HumanTurnDuringImport(), "A human turn starts while a deep continuation's reply is held");
                await Eventually(() => f.Noticed("Setup action limit reached") && !f.Session.Busy);
                var seen = f.Seen();
                check(seen.Length == 2 && seen[0].Authority.AppControlDepth == AppSupportActions.MaxDepth - 1 && !seen[0].Result.StartsWith("App operation blocked")
                    && seen[1].Authority.AppControlDepth == AppSupportActions.MaxDepth && seen[1].Result.Contains("Setup action limit reached") && f.Session.Pending.Count == 0,
                    "A human turn does not reset a held reply's app-control depth");
            }
            {
                using var f = new Fixture(root, "hop-held");
                f.HoldMarker = "HELD-HOP";
                f.Runner.Reply = p => p.Contains("HOP-LIMIT") ? "HELD-HOP" + Fence(new { command = "list-sessions" }) : "Human reply.";
                f.Session.Pending.Add(new PendingPrompt { Text = "HOP-LIMIT", Autonomous = true, Hop = DeviceSyncService.SwitchboardMaxHops }); f.Store.RunNext(f.Session);
                check(await f.HumanTurnDuringImport(), "A human turn starts while a last-hop reply is held");
                await Eventually(() => f.Noticed("Switchboard chain limit reached") && !f.Session.Busy);
                check(f.Noticed("Switchboard chain limit reached") && f.Session.Pending.Count == 0 && f.Runner.Count("switchboard directory") == 0,
                    "A human turn does not reset a held reply's switchboard hop");
            }
        }
        finally { try { Directory.Delete(root, recursive: true); } catch { } }
    }
}
