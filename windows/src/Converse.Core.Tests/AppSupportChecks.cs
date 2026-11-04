using Converse.Core;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

internal static class AppSupportChecks
{
    public static async Task Run(Action<bool, string> check)
    {
        var scrubbed = BugReportPrivacy.Scrub("Bug 123\nBearer fixture-secret\ngithub_pat_fixture\nuser@example.com\n/Users/alice/private.txt\nC:\\Users\\alice\\private.txt\n192.168.1.2\n-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----");
        check(scrubbed.Contains("Bug 123") && !scrubbed.Contains("alice") && !scrubbed.Contains("fixture") && !scrubbed.Contains("example.com") && !scrubbed.Contains("192.168"), "Local scrubber removes common credentials and identifiers while preserving symptoms");
        check(BugReportPrivacy.Summary("test", "Windows", true, 2, 1, 3, 1).Contains("Known peers: 2; online: 1"), "Diagnostics contain only allowlisted versions and counts");
        var root = Directory.CreateTempSubdirectory("converse-support-check-").FullName;
        try
        {
            var report = new GitHubBugReport("A & B / café", "Line one\n@someone &title=wrong # ?");
            var uri = report.BrowserURL();
            check(uri.Host == "github.com" && uri.AbsolutePath == "/richardkaufmann/converse/issues/new" && uri.Query.Contains(Uri.EscapeDataString(report.Body)), "GitHub draft URL preserves report text and fixes the destination");
            check(Rejected(() => new GitHubBugReport(" ", "x").Validated()) && Rejected(() => new GitHubBugReport("x", new string('界', 2000)).BrowserURL()), "Invalid and oversized browser reports fail without truncation");
            var transport = new ReportTransport(); using var client = new HttpClient(transport);
            var receipt = await report.SubmitAsync("fixture", client);
            check(receipt.AbsoluteUri == "https://github.com/richardkaufmann/converse/issues/42" && transport.Count == 1 && transport.ReportBody == System.Text.Json.JsonSerializer.Serialize(new { title = report.Title, body = report.Body }), "GitHub creation requires a real issue receipt and sends only reviewed text");
            foreach (var status in new[] { 401, 403, 404, 429, 500 })
            {
                transport.Count = 0; transport.Status = status;
                try { await report.SubmitAsync("fixture", client); check(false, "Rejected GitHub post cannot claim success"); }
                catch (InvalidOperationException ex) { check(transport.Count == 1 && !ex.Message.Contains("fixture-secret"), "GitHub error fails without automatic retries or leaking service content"); }
            }
            transport.Status = 201; transport.ForeignReceipt = true;
            try { await report.SubmitAsync("fixture", client); check(false, "Foreign issue receipt must fail"); } catch (InvalidOperationException) { check(true, "Foreign issue receipt rejected"); }
            transport.FailNetwork = true; transport.Count = 0;
            try { await report.SubmitAsync("fixture", client); check(false, "Timeout must fail"); } catch (InvalidOperationException ex) { check(transport.Count == 1 && ex.Message.Contains("Check the issue list"), "Ambiguous submission is not retried"); }
            foreach (var engine in new[] { "claude", "codex" })
            {
                var runner = new SupportRunner(); var store = new SessionStore(Path.Combine(root, engine), runner);
                store.AgentRun = (s, prompt, images) => { runner.Prompts.Add(prompt); s.Messages.Add(new ChatMessage { Role = "assistant", Text = "Welcome to Converse! " + AppSupportTeaching.Invitation }); s.Busy = false; store.Save(); return Task.CompletedTask; };
                var setup = new SupportSetup(store); var session = setup.Session();
                check(store.Sessions.Count == 1 && session.Title == AppSupportTeaching.Title && !session.MessagingEnabled, engine + " starts with one unprivileged App Support session");
                session.Draft = "Do not send before login"; store.Submit(session);
                check(runner.Prompts.Count == 0 && session.Draft.Length > 0, "Provider gate blocks ordinary prompts before successful verification");
                setup.SelectProvider(engine);
                check(session.Entry.AccountDirectory!.StartsWith(store.Folder) && session.Entry.UseDefaultAccountStore == false, engine + " support uses an isolated account profile");
                runner.Reply = "Not connected";
                check(!await setup.VerifyAsync(TimeSpan.FromSeconds(3)) && !session.SupportSetupCompleted && session.SupportTeachingVersion is null, engine + " wrong response leaves setup locked");
                runner.Reply = AppSupportTeaching.ConnectionReply; runner.Exit = 1;
                check(!await setup.VerifyAsync(TimeSpan.FromSeconds(3)) && !session.MessagingEnabled, engine + " failed process cannot unlock setup even with sentinel output");
                runner.Exit = 0; runner.Block = true;
                check(!await setup.VerifyAsync(TimeSpan.FromMilliseconds(40)), engine + " timeout does not unlock setup");
                await WaitIdle(session); runner.Block = false;
                check(!session.SupportSetupCompleted, "Cancelled connection probe remains gated");
                check(await setup.VerifyAsync(TimeSpan.FromSeconds(3)), engine + " actual successful final response unlocks setup");
                await WaitIdle(session);
                check(session.MessagingEnabled && session.SupportTeachingVersion == AppSupportTeaching.Version && runner.Prompts.Last().Contains("list-sessions") && runner.Prompts.Last().Contains("app-control"), engine + " receives both teaching capabilities automatically");
                check(session.DisplayedMessages.All(m => !m.Text.Contains("Connection check only") && !m.Text.Contains("setup and control teaching")) && session.Messages.Any(m => m.Text.Contains("setup and control teaching")), "Onboarding hides setup machinery without deleting provider context");
                check(session.Agent?.Settings.Enabled == true && session.Agent.Settings.IntervalSeconds == 86400 && !session.Agent.Settings.GenerateArt && session.Agent.Settings.Repository == "richardkaufmann/converse" && AgentModels.Parse(session.Agent.Settings.Model)?.Engine == engine, "Support daily loop preserves the verified provider and has no mood art");
                session.Title = "Renamed support"; session.Busy = true;
                check(store.QuitActivity() == (0, 0), "Busy built-in support with an enabled loop never blocks Quit, regardless of title");
                session.Busy = false;
                session.Agent!.Settings.Enabled = false; SupportSetup.ConfigureAgent(store, session);
                check(!session.Agent.Settings.Enabled, "Support migration preserves a user-paused loop");
                var reopened = new SessionStore(store.Folder, runner).Sessions.Single();
                check(reopened.SupportSetupCompleted && reopened.MessagingEnabled && reopened.SupportTeachingVersion == AppSupportTeaching.Version && reopened.ClearedThroughMessageID == session.ClearedThroughMessageID, "Support setup, teaching and display boundary survive restart");
                session.Attachments.Add("untouched.png"); session.Pending.Add(new PendingPrompt { Text = "Preserve queue" }); session.QueuePaused = true;
                var count = session.Messages.Count; session.Draft = "/clear"; store.Submit(session);
                check(!session.DisplayedMessages.Any() && session.Messages.Count == count && session.Attachments.Count == 1 && session.Pending.Count == 1, "/clear preserves context, images and queued work");
                session.Draft = "/unclear"; store.Submit(session); check(session.DisplayedMessages.Count() == count, "/unclear restores history");
                var create = JsonNode.Parse("""{"command":"app-control","action":"create-agent","title":"Test Steward","objective":"Report progress"}""")!.AsObject();
                var result = AppSupportActions.Execute(store, session, create, null);
                var agent = store.Sessions.Single(s => s.Agent is not null && !s.SupportAssistant);
                check(result.Contains("Created paused") && !agent.Agent!.Settings.Enabled && !agent.Agent.Settings.GenerateArt && !agent.Agent.Settings.Speak && agent.Agent.Settings.Watched.Count == 0, "App control creates an inert, scoped agent without paid work");
                AppSupportActions.Execute(store, session, create, null);
                check(store.Sessions.Count(s => s.Agent is not null && !s.SupportAssistant) == 1, "Repeated create does not duplicate an agent");
                check(agent.Agent!.Settings.Model == session.Agent!.Settings.Model, "New agent inherits the verified onboarding provider");
                var codingCommand = new JsonObject { ["command"] = "app-control", ["action"] = "create-session", ["provider"] = engine, ["title"] = "My project", ["directory"] = store.Folder };
                var codingResult = AppSupportActions.Execute(store, session, codingCommand, null);
                var coding = store.Sessions.Single(s => s.Title == "My project");
                check(codingResult.Contains(coding.Id.ToString()) && coding.Entry.AccountDirectory == session.Entry.AccountDirectory && !coding.Busy, "Support creates an idle coding session sharing the verified login");
                AppSupportActions.Execute(store, session, codingCommand, null);
                check(store.Sessions.Count(s => s.Title == "My project") == 1, "Repeated coding session request is idempotent");
                var normal = store.Create(store.Entries.First(e => e.Engine == engine));
                check(normal.Entry.AccountDirectory == session.Entry.AccountDirectory, "Ordinary new sessions reuse onboarding login");
                var restoredStore = new SessionStore(store.Folder, runner);
                check(restoredStore.Create(restoredStore.Entries.First(e => e.Engine == engine)).Entry.AccountDirectory == session.Entry.AccountDirectory, "Verified login preference survives restart");
                codingCommand["directory"] = Path.Combine(store.Folder, "missing");
                check(Rejected(() => AppSupportActions.Execute(store, session, codingCommand, null)), "Missing project folder rejected");
                agent.Title = AppSupportTeaching.Title; agent.Agent!.Settings.Enabled = true; agent.Agent.Settings.ScheduleText = ""; agent.Agent.Settings.TurnLimit = 2;
                normal.Busy = true;
                check(store.QuitActivity() == (1, 1), "Ordinary running sessions and scheduled agents still warn, even when named App Support");
                normal.Busy = false; agent.Agent.Settings.Enabled = false;
                var configure = new JsonObject { ["command"] = "app-control", ["action"] = "configure-agent", ["target"] = agent.Id.ToString(), ["repository"] = "not a repository" };
                var old = JsonSerializer.Serialize(agent.Agent);
                check(Rejected(() => AppSupportActions.Execute(store, session, configure, null)) && JsonSerializer.Serialize(agent.Agent) == old, "Invalid app configuration leaves the agent unchanged");
                var bug = new JsonObject { ["command"] = "app-control", ["action"] = "report-bug", ["title"] = "Fixture", ["body"] = "Only this description" };
                check(AppSupportActions.Execute(store, session, bug, null) == "UI", "Report prepares native review without Discord or credentials");
                session.ActiveBackground = true;
                check(Rejected(() => AppSupportActions.Execute(store, session, bug, null)), "Background agents cannot open bug report submission");
                session.ActiveBackground = false;
                session.ActiveBackground = true;
                check(Rejected(() => AppSupportActions.Execute(store, session, create, null)), "Background and forwarded turns cannot configure the app");
                session.ActiveBackground = false; session.ActiveAppControlDepth = 8;
                check(Rejected(() => AppSupportActions.Execute(store, session, create, null)), "App operation chains have a bounded turn limit");
                session.ActiveAppControlDepth = 0; session.SupportTeachingVersion = null;
                check(Rejected(() => AppSupportActions.Execute(store, session, create, null)), "Revoking teaching removes app-control access");
            }
            {
                var store = new SessionStore(Path.Combine(root, "native-agent"));
                using var devices = new DeviceSyncService(store.Folder, store);
                var session = store.CreateAgent("Taught native agent"); session.SupportTeachingVersion = 1;
                session.Agent!.Settings.GenerateArt = false;
                devices.Agents.ReadSecret = _ => "fixture-key";
                var explicitAction = false; var calls = 0; var instructions = "";
                devices.Agents.Request = async (request, token) =>
                {
                    var body = JsonNode.Parse(await request.Content!.ReadAsStringAsync(token))!.AsObject();
                    instructions = body["instructions"]!.GetValue<string>();
                    var reply = new JsonObject { ["reply"] = "```converse\n{\"command\":\"app-control\",\"action\":\"inspect\"}\n```", ["attention"] = "", ["memory"] = "", ["tell"] = new JsonArray() };
                    if (explicitAction) reply["appControl"] = new JsonObject { ["command"] = "app-control", ["action"] = "inspect" };
                    return System.Text.Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { status = "completed", output = new[] { new { content = new[] { new { type = "output_text", text = reply.ToJsonString() } } } } }));
                };
                store.AppSupportRequest = (_, command) => { calls++; return Task.CompletedTask; };
                session.Draft = "Inspect setup"; store.Submit(session); await WaitIdle(session);
                check(calls == 0 && instructions.Contains("optional appControl object"), "Native-agent teaching preserves JSON format and never executes prose commands");
                check(instructions.Contains("Never search the web for bare") && instructions.Contains("site:github.com/richardkaufmann/converse") && instructions.Contains("no relevant result is found"), "Previously taught agents receive current scoped research policy on their next request");
                check(instructions.Contains(AgentPolicy.ScoreboardScope), "Agent scoreboard instructions limit metrics to that agent's own objective and scope");
                check(instructions.Contains(AgentPolicy.ObjectiveGoverns), "Agent instructions make the current objective govern supplied evidence and older notes");
                explicitAction = true; session.Draft = "Inspect setup"; store.Submit(session); await WaitIdle(session);
                check(calls == 1, "Native agents dispatch only the explicit appControl operation");
            }
            {
                // Judges with only Claude Code or Codex: no Meta key must not block or pause a completed reply.
                var store = new SessionStore(Path.Combine(root, "art-optional"));
                using var devices = new DeviceSyncService(store.Folder, store);
                var bin = Path.Combine(root, "fake-path"); Directory.CreateDirectory(bin);
                foreach (var name in new[] { "claude", "codex" }) File.WriteAllText(Path.Combine(bin, name), "");
                store.AgentCommandAvailable = entry => CommandResolution.Resolve(entry.Command, false, new[] { bin }) is not null;
                store.AgentSecret = _ => null;
                var cliAgent = store.CreateAgent("CLI judge", false);
                check(AgentModels.Parse(cliAgent.Agent!.Settings.Model)?.Engine == "claude" && !cliAgent.Agent.Settings.GenerateArt, "Without a Meta key a new agent defaults to the installed Claude CLI with mood art off");
                File.Delete(Path.Combine(bin, "claude"));
                check(AgentModels.Parse(store.CreateAgent("Codex judge", false).Agent!.Settings.Model)?.Engine == "codex", "Codex is the default when it is the only installed CLI");
                File.Delete(Path.Combine(bin, "codex"));
                var none = store.CreateAgent("No CLI", false).Agent!.Settings;
                check(none.Model == "muse-spark-1.3" && !none.GenerateArt, "With no installed CLI the Meta API model remains, without mood art");
                store.AgentSecret = name => name == "meta" ? "fixture-key" : null;
                File.WriteAllText(Path.Combine(bin, "claude"), "");
                var meta = store.CreateAgent("Meta judge", false).Agent!.Settings;
                check(meta.Model == "muse-spark-1.3" && meta.GenerateArt, "A saved Meta key keeps the Meta API model and mood art defaults");

                var session = store.CreateAgent("Art fallback", false);
                session.Agent!.Settings.Model = "muse-spark-1.3"; session.Agent.Settings.GenerateArt = true; session.Agent.Settings.Enabled = true; session.Agent.Settings.ArtDirection = "Watercolor";
                var keyReads = 0;
                devices.Agents.ReadSecret = name => name == "meta" && keyReads++ == 0 ? "fixture-key" : null;
                devices.Agents.Request = async (request, token) =>
                {
                    if (request.RequestUri!.AbsolutePath.EndsWith("/images/generations")) throw new HttpRequestException("image service down");
                    await Task.Yield();
                    var reply = new JsonObject { ["reply"] = "Completed CLI-style reply", ["attention"] = "", ["memory"] = "", ["tell"] = new JsonArray(), ["artPrompt"] = "A cheerful lighthouse", ["scoreboard"] = new JsonObject { ["summary"] = "Steady progress", ["sentiment"] = "up", ["metrics"] = new JsonArray() } };
                    return System.Text.Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { status = "completed", output = new[] { new { content = new[] { new { type = "output_text", text = reply.ToJsonString() } } } } }));
                };
                bool KeptReply() => session.Messages.Any(m => m.Role == "assistant" && m.Text == "Completed CLI-style reply") && session.Messages.Last().Role == "notice" && session.Messages.Last().Text == AgentArtPolicy.Unavailable
                    && session.Status == "Ready" && session.Agent!.Settings.Enabled && session.Agent.Attention.Length == 0 && session.Agent.Widget?.Summary == "Steady progress";
                session.Draft = "Check progress"; store.Submit(session); await WaitIdle(session);
                check(KeptReply(), "A missing Meta key for mood art keeps the completed reply and the loop, with a quiet notice");
                keyReads = 0; devices.Agents.ReadSecret = name => name == "meta" ? "fixture-key" : null; session.Agent.Widget = null; session.Agent.ArtAtUtc = null; session.Agent.ArtMood = null;
                session.Draft = "Check again"; store.Submit(session); await WaitIdle(session);
                check(KeptReply(), "An image API failure keeps the completed reply and the loop, with a quiet notice");
                devices.Agents.ReadSecret = _ => null; session.Agent.Settings.Enabled = false;
                session.Draft = "Run once"; store.Submit(session); await WaitIdle(session);
                check(session.Agent.Attention.Contains(AgentPolicy.MissingMetaKey), "Run once without a Meta key says how to fix it");
            }
            foreach (var engine in new[] { "claude", "codex", "muse" })
            {
                var profile = Path.Combine(root, "profiles", engine);
                var start = new ProcessStartInfo();
                foreach (var key in new[] { "META_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR" }) start.Environment[key] = "fixture-secret";
                ProviderProfile.Apply(start, new AgentEntry { Engine = engine, AccountDirectory = profile, UseDefaultAccountStore = false });
                check(engine switch {
                    "claude" => start.Environment["CLAUDE_CONFIG_DIR"] == profile && !start.Environment.ContainsKey("ANTHROPIC_API_KEY") && !start.Environment.ContainsKey("ANTHROPIC_AUTH_TOKEN") && !start.Environment.ContainsKey("CLAUDE_CODE_OAUTH_TOKEN") && !start.Environment.ContainsKey("CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"),
                    "codex" => start.Environment["CODEX_HOME"] == profile && !start.Environment.ContainsKey("OPENAI_API_KEY") && !start.Environment.ContainsKey("CODEX_ACCESS_TOKEN"),
                    _ => start.Environment["MUSE_AUTH_PATH"] == Path.Combine(profile, "config", "muse", "auth.json") && start.Environment["XDG_CONFIG_HOME"] == Path.Combine(profile, "config") && !start.Environment.ContainsKey("META_API_KEY")
                }, engine + " login/runtime environment cannot inherit production account credentials");
            }
            {
                var store = new SessionStore(Path.Combine(root, "account-binding"));
                var entry = store.Entries.First(e => e.Engine == "claude"); entry.AccountDirectory = Path.Combine(root, "first-account");
                var reference = AgentModels.Reference("claude", AgentModels.AccountKey(entry), "same-model");
                check(AgentModels.Resolve(store, reference).AccountDirectory == entry.AccountDirectory, "Model selection resolves the chosen provider account");
                entry.AccountDirectory = Path.Combine(root, "replacement-account");
                var rejected = false; try { AgentModels.Resolve(store, reference); } catch (InvalidOperationException) { rejected = true; }
                check(rejected, "Rebinding a coding session cannot silently switch an agent's account");
                foreach (var engine in new[] { "claude", "codex", "muse" })
                {
                    var args = AgentCLI.Arguments(engine, "chosen-model", "input.txt", "output.txt");
                    check(args.Contains("--model") && !args.Contains("--resume") && !args.Contains("--yolo") && !args.Contains("--dangerously-bypass-approvals-and-sandbox"), engine + " agent requests are fresh and do not bypass permissions");
                }
            }
            check(DeviceSyncService.ParseSwitchboardReply("prose\n```converse\n{\"command\":\"app-control\",\"action\":\"inspect\"}\n```") is null, "Prose and quoted app commands remain inert");
        }
        finally { Directory.Delete(root, true); }
    }
    private static bool Rejected(Action action) { try { action(); return false; } catch (ArgumentException) { return true; } }
    private static async Task WaitIdle(ChatSession session)
    {
        for (var n = 0; n < 300 && session.Busy; n++) await Task.Delay(10);
        if (session.Busy) throw new Exception("Fixture provider did not stop.");
    }
    private sealed class SupportRunner : IAgentRunner
    {
        public List<string> Prompts = new(); public string Reply = ""; public int Exit; public bool Block;
        public async Task<int> RunAsync(ChatSession session, IReadOnlyList<string> arguments, string prompt, Action<string> line, CancellationToken token)
        {
            Prompts.Add(prompt);
            if (Block) await Task.Delay(Timeout.Infinite, token);
            var text = prompt.Contains("Connection check only:") ? Reply : "Welcome to Converse! " + AppSupportTeaching.Invitation;
            if (session.Entry.Engine == "codex")
            {
                var at = arguments.ToList().IndexOf("--output-last-message"); File.WriteAllText(arguments[at + 1], text);
                line(JsonSerializer.Serialize(new { type = "item.completed", item = new { type = "agent_message", text } }));
            }
            else line(JsonSerializer.Serialize(new { type = "result", result = text, is_error = false, session_id = session.Id.ToString() }));
            return Exit;
        }
    }
    private sealed class ReportTransport : HttpMessageHandler
    {
        public int Count, Status = 201;
        public bool ForeignReceipt, FailNetwork;
        public string? ReportBody;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Count++;
            if (request.RequestUri?.AbsoluteUri != "https://api.github.com/repos/richardkaufmann/converse/issues" || request.Headers.Authorization?.ToString() != "Bearer fixture" || request.Method != HttpMethod.Post) throw new Exception("Wrong report request");
            ReportBody = await request.Content!.ReadAsStringAsync(token);
            if (FailNetwork) throw new HttpRequestException("fixture-secret");
            return new HttpResponseMessage((System.Net.HttpStatusCode)Status) { Content = new StringContent(Status == 201 ? "{\"number\":42,\"html_url\":\"https://" + (ForeignReceipt ? "example.invalid" : "github.com/richardkaufmann/converse") + "/issues/42\"}" : "fixture-secret") };
        }
    }

}
