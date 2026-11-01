using Converse.Core;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

internal static class AppSupportChecks
{
    public static async Task Run(Action<bool, string> check)
    {
        var root = Directory.CreateTempSubdirectory("converse-support-check-").FullName;
        try
        {
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
                check(session.MessagingEnabled && session.SupportTeachingVersion == 1 && runner.Prompts.Last().Contains("list-sessions") && runner.Prompts.Last().Contains("app-control"), engine + " receives both teaching capabilities automatically");
                check(session.DisplayedMessages.All(m => !m.Text.Contains("Connection check only") && !m.Text.Contains("setup and control teaching")) && session.Messages.Any(m => m.Text.Contains("setup and control teaching")), "Onboarding hides setup machinery without deleting provider context");
                check(session.Agent?.Settings.Enabled == true && session.Agent.Settings.IntervalSeconds == 86400 && !session.Agent.Settings.GenerateArt && session.Agent.Settings.Repository == "richardkaufmann/converse" && AgentModels.Parse(session.Agent.Settings.Model)?.Engine == engine, "Support daily loop preserves the verified provider and has no mood art");
                session.Agent!.Settings.Enabled = false; SupportSetup.ConfigureAgent(store, session);
                check(!session.Agent.Settings.Enabled, "Support migration preserves a user-paused loop");
                var reopened = new SessionStore(store.Folder, runner).Sessions.Single();
                check(reopened.SupportSetupCompleted && reopened.MessagingEnabled && reopened.SupportTeachingVersion == 1 && reopened.ClearedThroughMessageID == session.ClearedThroughMessageID, "Support setup, teaching and display boundary survive restart");
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
                var configure = new JsonObject { ["command"] = "app-control", ["action"] = "configure-agent", ["target"] = agent.Id.ToString(), ["repository"] = "not a repository" };
                var old = JsonSerializer.Serialize(agent.Agent);
                check(Rejected(() => AppSupportActions.Execute(store, session, configure, null)) && JsonSerializer.Serialize(agent.Agent) == old, "Invalid app configuration leaves the agent unchanged");
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
                explicitAction = true; session.Draft = "Inspect setup"; store.Submit(session); await WaitIdle(session);
                check(calls == 1, "Native agents dispatch only the explicit appControl operation");
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
}
