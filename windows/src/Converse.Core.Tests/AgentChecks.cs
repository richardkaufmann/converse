using Converse.Core;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

static class AgentChecks
{
    public static async Task Run(Action<bool,string> check, Func<DeviceSyncService,DeviceSyncService,Func<bool>,Task<bool>> join)
    {
        DateTime D(string text) => DateTime.Parse(text, null, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal);
        check(DeviceSyncService.ParseSwitchboardReply("```converse\n{\"command\":\"list-sessions\"}\n```")?["command"]?.GetValue<string>() == "list-sessions", "Whole final reply can execute a switchboard command");
        check(DeviceSyncService.ParseSwitchboardReply("Some prose\n```converse\n{\"command\":\"tell\"}\n```") is null, "Prose around switchboard fence never executes");
        var settings = new DeviceAgentSettings { ScheduleText = "every 20 minutes while the us stock market is open", ScheduleTimeZone = "America/New_York" };
        var rule = AgentSchedule.Compile(settings);
        check(rule.Next(D("2026-10-29T13:29:00Z")) == D("2026-10-29T13:30:00Z"), "Agent market schedule anchors at New York open");
        check(rule.Next(D("2026-10-30T20:00:00Z")) == D("2026-11-02T14:30:00Z"), "Agent market schedule skips weekends and follows DST");
        check(!rule.Permits(D("2026-11-26T16:00:00Z")) && rule.Next(D("2026-11-27T17:50:00Z")) == D("2026-11-30T14:30:00Z"), "Agent market holidays and early closes match Swift");
        check(rule.Permits(D("2027-12-31T15:00:00Z")) && rule.Next(D("2028-12-31T00:00:00Z")) is null, "Agent market calendar expiry fails closed and New Year exception matches Swift");
        settings.ScheduleText = "daily at 01:30";
        check(AgentSchedule.Compile(settings).Next(D("2026-11-01T05:30:00Z")) == D("2026-11-02T06:30:00Z"), "Agent daily schedule never repeats the DST hour");
        settings.ScheduleText = "daily at 02:30";
        check(AgentSchedule.Compile(settings).Next(D("2027-03-14T00:00:00Z")) == D("2027-03-15T06:30:00Z"), "Agent daily schedule skips nonexistent wall time");
        foreach (var bad in new[] { "every 20 minutes while news is important", "every 20 seconds", "daily at 25:00", "every 2 hours between 5pm and 9am" })
        { settings.ScheduleText = bad; try { AgentSchedule.Compile(settings); check(false, "Agent rejects " + bad); } catch { check(true, "Agent rejects " + bad); } }
        var roots = Enumerable.Range(0, 2).Select(_ => Directory.CreateTempSubdirectory("converse-agent-").FullName).ToArray();
        try
        {
            var store = new SessionStore(roots[0], new FakeRunner());
            using var home = new DeviceSyncService(roots[0], store, "AgentHome");
            var viewerStore = new SessionStore(roots[1], new FakeRunner());
            using var viewer = new DeviceSyncService(roots[1], viewerStore, "AgentViewer");
            var sender = store.Create(new AgentEntry { Name = "Hop sender", Engine = "codex" });
            var receiver = store.Create(new AgentEntry { Name = "Hop receiver", Engine = "codex" });
            sender.MessagingEnabled = receiver.MessagingEnabled = true;
            receiver.QueuePaused = true;
            var receiverID = new DeviceGlobalID(home.DeviceId, receiver.Id).ToString();
            sender.ActiveHop = 8;
            await home.SendAgentTellAsync(sender, receiverID, "Past old limit");
            check(receiver.Pending.LastOrDefault()?.Hop == 9, "Switchboard continues beyond eight hops");
            sender.ActiveHop = 99;
            await home.SendAgentTellAsync(sender, receiverID, "Last permitted delivery");
            check(receiver.Pending.LastOrDefault()?.Hop == 100 && receiver.Pending.Last().Text.Contains("hop 100/100]"), "Switchboard delivers and labels hop one hundred");
            var queued = receiver.Pending.Count;
            sender.ActiveHop = 100;
            await home.SendAgentTellAsync(sender, receiverID, "Over limit");
            check(receiver.Pending.Count == queued, "Switchboard rejects hop one hundred and one");
            store.Sessions.Remove(sender); store.Sessions.Remove(receiver);
            var agent = store.CreateAgent("Agent fixture");
            agent.MessagingEnabled = true;
            agent.QueuePaused = true; agent.Draft = "Keep my agent draft";
            home.TeachSwitchboard(agent);
            check(agent.Pending.Count == 1 && agent.Pending[0].Text.Contains("tell array") && agent.Pending[0].Text.Contains("inReplyTo") && !agent.Pending[0].Text.Contains("```converse"), "Agent teaching preserves structured response format and correlated replies");
            check(agent.QueuePaused && agent.Draft == "Keep my agent draft" && agent.Agent!.Settings.Watched.Count == 0 && !agent.Agent.CanSchedule, "Teaching does not change agent scope, draft or paused loop");
            agent.Pending.Clear(); agent.Draft = ""; agent.QueuePaused = false;
            check(agent.Agent!.Settings.Watched.Count == 0 && !agent.Agent.CanSchedule, "New Windows agent starts paused with empty explicit scope");
            var calls = 0; string input = "";
            home.Agents.ReadSecret = _ => "test-only-not-a-real-key";
            home.Agents.Request = async (request, token) =>
            {
                calls++; input = request.Content is null ? "" : await request.Content.ReadAsStringAsync(token);
                return Encoding.UTF8.GetBytes("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"{\\\"reply\\\":\\\"Synthetic verified reply\\\",\\\"attention\\\":\\\"\\\",\\\"scoreboard\\\":{\\\"summary\\\":\\\"No live market data in this test\\\",\\\"metrics\\\":[{\\\"label\\\":\\\"Price\\\",\\\"value\\\":\\\"999\\\",\\\"sourceURL\\\":\\\"https://invented.invalid\\\"}]}}\"}]}]}");
            };
            foreach (var service in new[] { home, viewer }) { service.PairingConfirmation = _ => Task.FromResult(true); await service.StartAsync(0, enableDiscovery: false, loopbackOnly: true); }
            check(await join(home, viewer, () => viewer.Homes.GetValueOrDefault(home.DeviceId)?.Online == true), "Agent control peers join one group");
            var target = new DeviceGlobalID(home.DeviceId, agent.Id).ToString();
            var loaded = await viewer.RequestParticipantAsync(home.DeviceId, "agent.settings", target);
            check(loaded.Settings is not null && viewer.RemoteLeases.Count == 0, "Agent settings work without taking or moving the display lease");
            var edit = loaded.Settings!; edit.ScheduleText = "every 20 minutes while the US stock market is open"; edit.ScheduleTimeZone = "America/New_York"; edit.GenerateArt = false;
            var saved = await viewer.RequestParticipantAsync(home.DeviceId, "agent.configure", target, settings: edit);
            check(saved.Outcome == "completed" && agent.Agent.Settings.ScheduleText == edit.ScheduleText, "Remote agent settings preserve text schedule on home");
            var stale = await viewer.RequestParticipantAsync(home.DeviceId, "agent.configure", target, settings: edit);
            check(stale.Outcome == "rejected", "Stale remote settings cannot overwrite newer revision");
            agent.Draft = "A human asks for progress"; store.Submit(agent);
            var deadline = DateTime.UtcNow.AddSeconds(3); while (agent.Busy && DateTime.UtcNow < deadline) await Task.Delay(10);
            check(calls == 1 && agent.Messages.Any(m => m.Text == "Synthetic verified reply"), "Agent human turn runs through injected API and writes a reply");
            check(agent.Agent.Widget?.Metrics.Single().Value == "Unavailable", "Agent scoreboard rejects metrics without an exact real search source");
            var before = agent.Agent.Settings.RemainingRuns;
            agent.Agent.Settings.ScheduleText = ""; agent.Agent.Settings.IntervalSeconds = 60; agent.Agent.Settings.Enabled = true; agent.Agent.NextRunUtc = DateTime.UtcNow.AddSeconds(-1);
            home.Agents.Tick(DateTime.UtcNow); home.Agents.Tick(DateTime.UtcNow);
            deadline = DateTime.UtcNow.AddSeconds(3); while (agent.Busy && DateTime.UtcNow < deadline) await Task.Delay(10);
            check(calls == 2 && agent.Agent.Settings.RemainingRuns == before, "Agent scheduler persists one activation without depleting the schedule and coalesces ticks");
            check(new SessionStore(roots[0], new FakeRunner()).Sessions.Single(s => s.Id == agent.Id).Agent!.Settings.RemainingRuns == before, "Agent budget and scoreboard survive archive reload");
            var created = await viewer.RequestParticipantAsync(home.DeviceId, "agent.create", title: "Created remotely");
            check(created.Outcome == "completed" && store.Sessions.Any(s => s.Title == "Created remotely" && s.Agent is not null), "Viewer creates a paused agent on the selected home");
            home.SetAcceptingWork(false);
            var closedCreated = await viewer.RequestParticipantAsync(home.DeviceId, "agent.create", title: "Must not create during drain");
            check(closedCreated.Outcome != "completed" && !store.Sessions.Any(s => s.Title == "Must not create during drain"),
                "Closed admission rejects remote agent creation");
            agent.QueuePaused = true;
            var queuedBefore = agent.Pending.Count;
            var closedRun = await viewer.RequestParticipantAsync(home.DeviceId, "agent.run", target);
            check(closedRun.Outcome != "completed" && agent.Pending.Count == queuedBefore,
                "Closed admission rejects remote agent runs before queueing");
            agent.Pending.Clear(); agent.QueuePaused = false;
            home.SetAcceptingWork(true);
            var remoteSender = viewerStore.Create(new AgentEntry { Name = "Drain tell probe", Engine = "codex" });
            remoteSender.MessagingEnabled = true;
            agent.QueuePaused = true;
            home.SetAcceptingWork(false);
            var tellCountBefore = agent.Pending.Count;
            await viewer.SendAgentTellAsync(remoteSender, target, "DRAIN_PROBE_NEW_EXTERNAL_TELL");
            var tellDeadline = DateTime.UtcNow.AddSeconds(2);
            while (agent.Pending.Count == tellCountBefore && DateTime.UtcNow < tellDeadline) await Task.Delay(20);
            check(agent.Pending.Count == tellCountBefore,
                "Closed admission rejects a new incoming switchboard tell");
            agent.Pending.Clear(); agent.QueuePaused = false; home.SetAcceptingWork(true);
            await viewer.LeaveGroupAsync();
            var refused = await viewer.RequestParticipantAsync(home.DeviceId, "agent.run", target);
            check(refused.Outcome == "rejected" && calls == 2, "Leaving group immediately fences remote agent control");
            home.Agents.Shutdown(); agent.Agent.Settings.Enabled = true; agent.Agent.NextRunUtc = DateTime.UtcNow.AddSeconds(-1); home.Agents.Tick(DateTime.UtcNow);
            check(calls == 2, "Shutdown prevents agent loop restart");
        }
        finally { foreach (var root in roots) { try { Directory.Delete(root, true); } catch { } } }
    }
}
