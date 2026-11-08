using Converse.Core;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

static class AgentChecks
{
    public static async Task Run(Action<bool,string> check, Func<DeviceSyncService,DeviceSyncService,Func<bool>,Task<bool>> join)
    {
        DateTime D(string text) => DateTime.Parse(text, null, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal);
        var fired = D("2026-10-28T12:00:00Z");
        var dailyLoop = new AgentConfig { Settings = new DeviceAgentSettings { Enabled = true, IntervalSeconds = 86400 }, LastLoopUtc = fired, NextRunUtc = fired.AddDays(1) };
        var restoredLoop = DeviceJson.Decode<AgentConfig>(DeviceJson.Encode(dailyLoop));
        restoredLoop.RestoreSchedule(fired.AddHours(1));
        check(restoredLoop.NextRunUtc == fired.AddDays(1), "Restart one hour after a daily check preserves the remaining 23 hours");
        var haScope = HomeAssistantAgent.Validate("http://homeassistant.local:8123", "sensor.office_temperature, light.desk sensor.office_temperature", true);
        check(haScope.Entities.SequenceEqual(new[] { "light.desk", "sensor.office_temperature" }), "Home Assistant accepts only unique selected entity IDs");
        try { HomeAssistantAgent.Validate("https://user:secret@example.com", "sensor.office_temperature", true); check(false, "Home Assistant rejects embedded URL credentials"); }
        catch (ArgumentException) { check(true, "Home Assistant rejects embedded URL credentials"); }
        try { HomeAssistantAgent.Validate("https://example.com", "https://evil.example", true); check(false, "Home Assistant rejects entity URLs"); }
        catch (ArgumentException) { check(true, "Home Assistant rejects entity URLs"); }
        var haSettings = new DeviceAgentSettings { HomeAssistantURL = "http://homeassistant.local:8123", HomeAssistantEntities = "sensor.office_temperature", HomeAssistantRead = true };
        var haAgent = new AgentConfig { Settings = haSettings };
        var oldEditor = DeviceJson.Decode<DeviceAgentSettings>(DeviceJson.Encode(haSettings));
        oldEditor.HomeAssistantURL = null; oldEditor.HomeAssistantEntities = null; oldEditor.HomeAssistantRead = null;
        haAgent.Apply(oldEditor);
        check(haAgent.Settings.HomeAssistantRead == true && haAgent.Settings.HomeAssistantEntities == "sensor.office_temperature", "Older Windows editors preserve Home Assistant scope");
        var artNow = D("2026-11-04T15:00:00Z");
        // Assessments: host-owned measured values, revision vs heartbeat, malformed never fatal.
        var measured = AgentAssessments.Measured(new JsonObject { ["observedAt"] = "2026-11-04T14:00:00Z", ["openIssues"] = 4 }, "kaos/converse", artNow);
        var raw = JsonNode.Parse("{\"summary\":\"Two bugs remain.\",\"status\":\"at-risk\",\"facts\":[{\"id\":\"github.openIssues\",\"kind\":\"measured\",\"value\":\"999\"},{\"id\":\"users\",\"label\":\"Users\",\"kind\":\"measured\",\"value\":\"5000\"},{\"label\":\"Ship tonight\",\"value\":\"Likely\",\"kind\":\"judgment\",\"detail\":{\"why\":[\"tests\",{\"docs\":true}]}}],\"detail\":{\"risks\":{\"top\":\"renderer\"}}}");
        var first = AgentAssessments.Evaluate(raw, measured, null, artNow);
        check(first.Kind == AgentAssessmentOutcome.Revision && first.Record!.Revision == 1 && first.Record.Facts[0].Value == "4" && first.Record.Facts[1].Value == AgentAssessments.Unavailable && first.Record.Facts[2].Detail?["why"] is JsonArray,
            "Windows assessment: measured values come from the host, unknown measurements read Unavailable, nested detail is kept");
        var again = AgentAssessments.Evaluate(JsonNode.Parse(raw!.ToJsonString().Replace("Two bugs remain.", "  two bugs   remain. ")), measured, first.Record, artNow.AddMinutes(5));
        check(again.Kind == AgentAssessmentOutcome.Heartbeat && again.Record!.Revision == 1 && again.Record.Heartbeats == 1, "Windows assessment: unchanged content is a heartbeat");
        var moved = AgentAssessments.Measured(new JsonObject { ["openIssues"] = 5 }, "kaos/converse", artNow);
        check(AgentAssessments.Evaluate(raw, moved, again.Record, artNow.AddMinutes(10)) is { Kind: AgentAssessmentOutcome.Revision, Record.Revision: 2 }, "Windows assessment: a changed measurement is a new revision");
        foreach (var bad in new JsonNode?[] { null, JsonValue.Create("fine"), JsonNode.Parse("{\"status\":\"done\"}"), JsonNode.Parse("{\"summary\":\"x\",\"status\":\"great\"}") })
            check(AgentAssessments.Evaluate(bad, measured, first.Record, artNow).Kind == AgentAssessmentOutcome.Rejected, "Windows assessment: malformed input is rejected, not fatal");
        var persisted = DeviceJson.Decode<AgentConfig>(DeviceJson.Encode(new AgentConfig { Assessment = first.Record }));
        check(persisted.Assessment?.ContentHash == first.Record.ContentHash && persisted.Assessment.Facts.Count == 3, "Windows assessment persists with the agent");
        var transientErrors = new Exception[] { new AgentHttpStatusException(503, false), new AgentHttpStatusException(429, false), new AgentHttpStatusException(400, false), new HttpRequestException("lost"),
            new TaskCanceledException("timeout", new TimeoutException()), new IOException("reset"), new InvalidOperationException("Something nobody anticipated."), new FormatException("odd"),
            new InvalidOperationException("Home Assistant scope changed during the run. Retry with the new settings.") };
        foreach (var error in transientErrors) check(AgentRunFailure.Classify(error) == AgentFailureKind.Transient, "Windows retry: transient, never a pause: " + error.Message);
        var permanentErrors = new Exception[] { new AgentHttpStatusException(401, false), new AgentHttpStatusException(403, false), new InvalidOperationException(AgentPolicy.MissingMetaKey),
            new InvalidOperationException("Supported calendar exhausted. Review the schedule/calendar."), new ArgumentException("Invalid agent settings."), new InvalidOperationException("Invalid provider selection. Choose a model again."),
            new InvalidOperationException("This activation reached its turn limit.") };
        foreach (var error in permanentErrors) check(AgentRunFailure.Classify(error) == AgentFailureKind.Permanent, "Windows retry: permanent, pause with a fix: " + error.Message);
        var modelErrors = new Exception[] { new InvalidOperationException("Agent returned an invalid action format. No actions applied."), new InvalidOperationException("Agent response did not complete. No actions applied."),
            new InvalidOperationException("Agent hit its response limit. No actions applied.") };
        foreach (var error in modelErrors) check(AgentRunFailure.Classify(error) == AgentFailureKind.Model, "Windows retry: model output, re-asked once: " + error.Message);
        check(AgentRunFailure.Classify(new TaskCanceledException("stopped")) == AgentFailureKind.Cancelled && AgentRunFailure.Correction("Agent hit its response limit") == AgentRunFailure.LengthCorrection
            && AgentRunFailure.Correction("invalid action format") == AgentRunFailure.FormatCorrection, "Windows retry: Stop is cancellation; cut-off replies ask for a shorter answer");
        check(new[] { 1, 2, 3, 4, 5, 40 }.Select(n => AgentRunFailure.Backoff(n, 900).TotalSeconds).SequenceEqual(new double[] { 60, 120, 240, 480, 900, 900 }), "Windows retry: back-off 1, 2, 4, 8 minutes, capped at the interval");
        var retry = new AgentConfig { Settings = new DeviceAgentSettings { Enabled = true, IntervalSeconds = 900, TurnLimit = 3 } };
        void Fail(string text, AgentFailureKind kind, DateTime at) { retry.NextRunUtc = at.AddSeconds(900); retry.RecordFailure(text, kind, at); }
        Fail("The request timed out.", AgentFailureKind.Transient, artNow); Fail("The request timed out.", AgentFailureKind.Model, artNow.AddMinutes(1));
        check(retry.Settings.Enabled && retry.TransientFailures == 2 && retry.Attention == "" && retry.TroubleSinceUtc == artNow && retry.NextRunUtc == artNow.AddMinutes(3), "Windows retry: early failures stay quiet, keep the loop on and back off");
        var reset = DeviceJson.Decode<AgentConfig>(DeviceJson.Encode(retry)); reset.RecordSuccess();
        check(reset.TransientFailures is null && reset.TroubleSinceUtc is null && reset.Settings.Enabled, "Windows retry: a success resets the counter");
        Fail("The request timed out.", AgentFailureKind.Transient, artNow.AddMinutes(3));
        check(retry.Settings.Enabled && retry.PauseReason is null && retry.Attention.StartsWith("Having trouble since ") && retry.Attention.EndsWith(": The request timed out. — still retrying (3 tries)"), "Windows retry: the third failure shows a trouble banner and keeps running");
        for (var attempt = 4; attempt <= 25; attempt++) Fail("Agent service returned HTTP 503.", AgentFailureKind.Transient, artNow.AddMinutes(15 * attempt));
        check(retry.Settings.Enabled && retry.PauseReason is null && retry.TransientFailures == 25 && retry.Attention.Contains("(25 tries)") && retry.NextRunUtc == artNow.AddMinutes(15 * 25 + 15), "Windows retry: many transient failures never pause");
        retry.RecordSuccess();
        check(retry.Attention == "" && retry.TransientFailures is null, "Windows retry: a success clears the trouble banner");
        var permanent = new AgentConfig { Settings = new DeviceAgentSettings { Enabled = true, IntervalSeconds = 900, TurnLimit = 3 } };
        permanent.RecordFailure("Add a Meta API key.", AgentFailureKind.Permanent, artNow);
        check(!permanent.Settings.Enabled && permanent.PauseReason?.StartsWith("Paused: Add a Meta API key.") == true, "Windows retry: permanent failures pause at once");
        permanent.Attention = ""; permanent.RecordSuccess();
        check(permanent.Attention == permanent.PauseReason, "Windows retry: a later manual run keeps the pause reason visible");
        var reenable = DeviceJson.Decode<DeviceAgentSettings>(DeviceJson.Encode(permanent.Settings)); reenable.Enabled = true; permanent.Apply(reenable);
        check(permanent.PauseReason is null && permanent.Settings.Enabled, "Windows retry: re-enabling clears the pause reason");
        permanent.PauseLoop();
        check(!permanent.Settings.Enabled && permanent.NextRunUtc is null && permanent.PauseReason is null, "Windows controls: Pause loop turns checks off without an alarm");
        permanent.Pause("Add a Meta API key.", artNow); permanent.ResumeLoop(artNow);
        check(permanent.Settings.Enabled && permanent.PauseReason is null && permanent.Attention == "" && permanent.NextRunUtc == artNow.AddSeconds(900), "Windows controls: Resume loop clears the pause and schedules the next check");
        restoredLoop.RestoreSchedule(fired.AddDays(3));
        check(restoredLoop.NextRunUtc == fired.AddDays(1), "Overdue deadline survives restart for catch-up on normal tick");
        restoredLoop.NextRunUtc = null; restoredLoop.RestoreSchedule(fired.AddHours(2));
        check(restoredLoop.NextRunUtc == fired.AddDays(1), "Missing deadline reconstructs from persisted last loop");
        var objectiveEdit = DeviceJson.Decode<DeviceAgentSettings>(DeviceJson.Encode(restoredLoop.Settings)); objectiveEdit.Objective = "Updated objective"; restoredLoop.Apply(objectiveEdit);
        check(restoredLoop.NextRunUtc == fired.AddDays(1), "Unrelated settings edit preserves the loop deadline");
        restoredLoop.Settings.Enabled = false; restoredLoop.NextRunUtc = null; restoredLoop.RestoreSchedule(fired.AddDays(3));
        check(!restoredLoop.CanSchedule && restoredLoop.NextRunUtc is null, "Restart leaves paused loops paused");
        var freshLoop = new AgentConfig { Settings = new DeviceAgentSettings { Enabled = true, IntervalSeconds = 86400 } }; freshLoop.RestoreSchedule(fired);
        check(freshLoop.NextRunUtc == fired.AddDays(1), "Never-run loop without history waits its first interval");
        check(DeviceSyncService.ParseSwitchboardReply("```converse\n{\"command\":\"list-sessions\"}\n```")?["command"]?.GetValue<string>() == "list-sessions", "Whole final reply can execute a switchboard command");
        check(DeviceSyncService.ParseSwitchboardReply("Some prose\n```converse\n{\"command\":\"tell\"}\n```") is null, "Prose around switchboard fence never executes");
        var artConfig = new AgentConfig();
        var artSettings = DeviceJson.Decode<DeviceAgentSettings>(DeviceJson.Encode(artConfig.Settings)); artSettings.ArtDirection = "Watercolor moonbase"; artConfig.Apply(artSettings);
        var oldArtEditor = DeviceJson.Decode<DeviceAgentSettings>(DeviceJson.Encode(artConfig.Settings)); oldArtEditor.ArtDirection = null; artConfig.Apply(oldArtEditor);
        check(artConfig.Settings.ArtDirection == "Watercolor moonbase", "Old editors preserve scoreboard art direction");
        var oversizedArt = DeviceJson.Decode<DeviceAgentSettings>(DeviceJson.Encode(artConfig.Settings)); oversizedArt.ArtDirection = new string('x', 4001);
        try { artConfig.Apply(oversizedArt); check(false, "Art prompt bound"); } catch (ArgumentException) { check(artConfig.Settings.ArtDirection == "Watercolor moonbase", "Oversized art prompt cannot mutate settings"); }
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
            var restartAgent = store.CreateAgent("Restart cadence fixture");
            restartAgent.Agent = dailyLoop; restartAgent.QueuePaused = true; store.Save();
            store = new SessionStore(roots[0], new FakeRunner());
            using var home = new DeviceSyncService(roots[0], store, "AgentHome");
            restartAgent = store.Sessions.Single(s => s.Title == "Restart cadence fixture");
            check(restartAgent.Agent!.NextRunUtc == fired.AddDays(1), "Actual runtime startup keeps an archived overdue deadline");
            home.Agents.Tick(fired.AddDays(3));
            check(restartAgent.Pending.Count == 0 && restartAgent.Agent.NextRunUtc == fired.AddDays(1), "Overdue startup respects a human-paused queue");
            store.AgentRun = (_, _, _, _) => Task.CompletedTask;
            restartAgent.QueuePaused = false;
            home.Agents.Tick(fired.AddDays(3)); home.Agents.Tick(fired.AddDays(3));
            check(restartAgent.Agent.LastLoopUtc == fired.AddDays(3) && restartAgent.Agent.NextRunUtc == fired.AddDays(4), "Missed days coalesce into one check with the next interval from that check");
            store.Sessions.Remove(restartAgent); store.AgentRun = home.Agents.RunAsync;
            var viewerStore = new SessionStore(roots[1], new FakeRunner());
            using var viewer = new DeviceSyncService(roots[1], viewerStore, "AgentViewer");
            var sender = store.Create(new AgentEntry { Name = "Hop sender", Engine = "codex" });
            var receiver = store.Create(new AgentEntry { Name = "Hop receiver", Engine = "codex" });
            sender.MessagingEnabled = receiver.MessagingEnabled = true;
            receiver.QueuePaused = true;
            var receiverID = new DeviceGlobalID(home.DeviceId, receiver.Id).ToString();
            await home.SendAgentTellAsync(sender, TurnAuthority.Foreground() with { Background = true, Hop = 8 }, receiverID, "Past old limit");
            check(receiver.Pending.LastOrDefault()?.Hop == 9, "Switchboard continues beyond eight hops");
            await home.SendAgentTellAsync(sender, TurnAuthority.Foreground() with { Background = true, Hop = 99 }, receiverID, "Last permitted delivery");
            check(receiver.Pending.LastOrDefault()?.Hop == 100 && receiver.Pending.Last().Text.Contains("hop 100/100]"), "Switchboard delivers and labels hop one hundred");
            var queued = receiver.Pending.Count;
            await home.SendAgentTellAsync(sender, TurnAuthority.Foreground() with { Background = true, Hop = 100 }, receiverID, "Over limit");
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
                return Encoding.UTF8.GetBytes("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"{\\\"reply\\\":\\\"Synthetic verified reply\\\",\\\"attention\\\":\\\"\\\",\\\"scoreboard\\\":{\\\"summary\\\":\\\"Old field\\\",\\\"metrics\\\":[]},\\\"assessment\\\":{\\\"summary\\\":\\\"Synthetic progress.\\\",\\\"status\\\":\\\"at-risk\\\",\\\"facts\\\":[{\\\"id\\\":\\\"github.openIssues\\\",\\\"kind\\\":\\\"measured\\\"}]}}\"}]}]}");
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
            var sentBody = JsonNode.Parse(input) as JsonObject;
            check(sentBody?["prompt_cache_key"]?.GetValue<string>() == AgentRuntime.PromptCacheKey(agent.Id) && sentBody?["prompt_cache_retention"]?.GetValue<string>() == "24h", "Windows agent sends a per-agent prompt cache key and 24h retention");
            var invented = AgentAssessments.Evaluate(JsonNode.Parse("{\"summary\":\"Quotes\",\"status\":\"on-track\",\"facts\":[{\"id\":\"price\",\"label\":\"Price\",\"value\":\"999\",\"kind\":\"evidence\",\"source\":\"https://invented.invalid/q\"},{\"id\":\"real\",\"label\":\"Real\",\"value\":\"$1\",\"kind\":\"evidence\",\"source\":\"https://example.com/q\"}]}"), [], null, DateTime.UtcNow, url => url == "https://example.com/q");
            check(invented.Record!.Facts.Single(f => f.Id == "price").Value == AgentAssessments.Unavailable && invented.Record.Facts.Single(f => f.Id == "real").Value == "$1", "Assessment facts citing a web URL this run did not retrieve read Unavailable");
            var widget = home.AgentWidgetFor(agent);
            check(agent.Agent.Widget is null && widget?.Summary == "Synthetic progress." && widget.Status == "At risk" && widget.Freshness == "Fresh" && widget.Revision == 1 && widget.Metrics.Single().Value == AgentAssessments.Unavailable,
                "The remote widget derives from the assessment (summary, status, freshness, facts); a scoreboard field from the model is ignored");
            var before = agent.Agent.Settings.RemainingRuns;
            agent.Agent.Settings.ScheduleText = ""; agent.Agent.Settings.IntervalSeconds = 60; agent.Agent.Settings.Enabled = true; agent.Agent.NextRunUtc = DateTime.UtcNow.AddSeconds(-1);
            home.Agents.Tick(DateTime.UtcNow); home.Agents.Tick(DateTime.UtcNow);
            deadline = DateTime.UtcNow.AddSeconds(3); while (agent.Busy && DateTime.UtcNow < deadline) await Task.Delay(10);
            check(calls == 2 && agent.Agent.Settings.RemainingRuns == before, "Agent scheduler persists one activation without depleting the schedule and coalesces ticks");
            check(new SessionStore(roots[0], new FakeRunner()).Sessions.Single(s => s.Id == agent.Id).Agent!.Settings.RemainingRuns == before, "Agent budget and assessment survive archive reload");
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
            await viewer.SendAgentTellAsync(remoteSender, TurnAuthority.Foreground(), target, "DRAIN_PROBE_NEW_EXTERNAL_TELL");
            var tellDeadline = DateTime.UtcNow.AddSeconds(2);
            while (agent.Pending.Count == tellCountBefore && DateTime.UtcNow < tellDeadline) await Task.Delay(20);
            check(agent.Pending.Count == tellCountBefore,
                "Closed admission rejects a new incoming switchboard tell");
            agent.Pending.Clear(); agent.QueuePaused = false; home.SetAcceptingWork(true);
            await viewer.LeaveGroupAsync();
            var refused = await viewer.RequestParticipantAsync(home.DeviceId, "agent.run", target);
            check(refused.Outcome == "rejected" && calls == 2, "Leaving group immediately fences remote agent control");
            var originalRequest = home.Agents.Request; var cacheBodies = new List<string>();
            home.Agents.Request = async (request, token) =>
            {
                var sent = request.Content is null ? "" : await request.Content.ReadAsStringAsync(token); cacheBodies.Add(sent);
                if (sent.Contains("prompt_cache_key")) throw new AgentHttpStatusException(400, true);
                return Encoding.UTF8.GetBytes("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"{\\\"reply\\\":\\\"Cache fallback reply\\\"}\"}]}]}");
            };
            agent.Draft = "Fallback probe"; store.Submit(agent);
            deadline = DateTime.UtcNow.AddSeconds(3); while (agent.Busy && DateTime.UtcNow < deadline) await Task.Delay(10);
            check(cacheBodies.Count == 2 && cacheBodies[0].Contains("prompt_cache_retention") && !cacheBodies[1].Contains("prompt_cache") && agent.Messages.Any(m => m.Text == "Cache fallback reply"), "Windows agent retries once without prompt cache fields after a 400 naming them");
            // Same-run corrective re-ask, then transient failures that never pause.
            var scripted = new Queue<string>(); var asked = new List<string>();
            static string Completed(string text) => "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":" + JsonSerializer.Serialize(text) + "}]}]}";
            home.Agents.Request = async (request, token) =>
            {
                asked.Add(JsonNode.Parse(request.Content is null ? "{}" : await request.Content.ReadAsStringAsync(token))?["instructions"]?.GetValue<string>() ?? "");
                if (scripted.Count == 0) throw new HttpRequestException("lost");
                return Encoding.UTF8.GetBytes(scripted.Dequeue());
            };
            agent.Agent.Settings.Enabled = true; agent.Agent.Settings.TurnLimit = 1; agent.Agent.NextRunUtc = DateTime.UtcNow.AddHours(1);
            scripted.Enqueue(Completed("Here is my update, not JSON.")); scripted.Enqueue(Completed("{\"reply\":\"Recovered Windows report\"}"));
            agent.Draft = "Re-ask probe"; store.Submit(agent);
            deadline = DateTime.UtcNow.AddSeconds(3); while (agent.Busy && DateTime.UtcNow < deadline) await Task.Delay(10);
            check(asked.Count == 2 && !asked[0].Contains(AgentRunFailure.FormatCorrection) && asked[1].EndsWith(AgentRunFailure.FormatCorrection) && agent.Messages.Any(m => m.Text == "Recovered Windows report")
                && agent.Agent.Settings.Enabled && agent.Agent.TransientFailures is null, "Windows agent re-asks a malformed reply once in the same run and completes");
            asked.Clear(); scripted.Enqueue(Completed("nope")); scripted.Enqueue(Completed("still nope"));
            agent.Draft = "Double malformed probe"; store.Submit(agent);
            deadline = DateTime.UtcNow.AddSeconds(3); while (agent.Busy && DateTime.UtcNow < deadline) await Task.Delay(10);
            check(asked.Count == 2 && agent.Agent.Settings.Enabled && agent.Agent.PauseReason is null && agent.Agent.TransientFailures == 1, "Windows agent treats a second malformed reply as transient: the loop stays on");
            for (var attempt = 2; attempt <= 4; attempt++)
            {
                agent.Draft = "Network probe " + attempt; store.Submit(agent);
                deadline = DateTime.UtcNow.AddSeconds(3); while (agent.Busy && DateTime.UtcNow < deadline) await Task.Delay(10);
            }
            check(agent.Agent.Settings.Enabled && agent.Agent.PauseReason is null && agent.Agent.TransientFailures == 4 && agent.Agent.Attention.StartsWith(AgentRunFailure.TroublePrefix)
                && agent.Agent.NextRunUtc <= DateTime.UtcNow.AddMinutes(9), "Windows agent keeps retrying through network failures with a trouble banner and an earlier next check");
            agent.Agent.Settings.Enabled = false; agent.Agent.TransientFailures = null; agent.Agent.TroubleSinceUtc = null; agent.Agent.Attention = "";
            home.Agents.Request = originalRequest;
            home.Agents.Shutdown(); agent.Agent.Settings.Enabled = true; agent.Agent.NextRunUtc = DateTime.UtcNow.AddSeconds(-1); home.Agents.Tick(DateTime.UtcNow);
            check(calls == 2, "Shutdown prevents agent loop restart");
        }
        finally { foreach (var root in roots) { try { Directory.Delete(root, true); } catch { } } }
    }
}
