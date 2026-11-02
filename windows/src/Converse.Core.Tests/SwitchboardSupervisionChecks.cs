using Converse.Core;

static class SwitchboardSupervisionChecks
{
    public static async Task Run(Action<bool, string> check, Func<DeviceSyncService, DeviceSyncService, Func<bool>, Task<bool>> join)
    {
        var root = Directory.CreateTempSubdirectory("converse-supervision-").FullName;
        try
        {
            var store = new SessionStore(root, new FakeRunner());
            using var home = new DeviceSyncService(root, store, "Supervision");
            var asker = store.Create(new AgentEntry { Name = "Asker", Engine = "codex" });
            var answerer = store.Create(new AgentEntry { Name = "Answerer", Engine = "codex" });
            asker.MessagingEnabled = answerer.MessagingEnabled = true;
            asker.QueuePaused = answerer.QueuePaused = true;
            async Task Command(string action, int count)
            {
                var body = System.Text.Json.JsonSerializer.Serialize(new { command = action, to = answerer.Id.ToString(), text = "Question", replyExpected = false });
                store.FinalParticipantReply!(asker, "```converse\n" + body + "\n```");
                for (var i = 0; i < 100 && answerer.Pending.Count < count; i++) await Task.Delay(10);
            }
            await Command("tell", 1);
            check(asker.SwitchboardExpectations.Count == 0 && answerer.Pending.Count == 1, "Plain tell delivers without requesting a receipt turn");
            await Command("ask", 2);
            check(asker.SwitchboardExpectations.Count == 1 && answerer.Pending.Count == 2 && answerer.Pending.Last().Text.Contains("Reply expected"), "Ask command always requests correlated reply, even with conflicting false flag");
            check(!asker.SwitchboardExpectations.Single().Answered, "Delivery acceptance does not answer an ask");
            check(SwitchboardInstructions.WithPolicy(asker, "Hello").Contains("one-way tell") && SwitchboardInstructions.WithPolicy(new ChatSession(), "Hello") == "Hello", "Policy refresh reaches enabled existing sessions only");
            var a = store.Create(new AgentEntry { Name = "A", Engine = "codex" });
            var b = store.Create(new AgentEntry { Name = "B", Engine = "codex" });
            a.MessagingEnabled = b.MessagingEnabled = true;
            a.QueuePaused = b.QueuePaused = true;
            a.Draft = "A draft"; b.Draft = "B draft";
            string ID(ChatSession s) => new DeviceGlobalID(home.DeviceId, s.Id).ToString();
            await home.SendAgentTellAsync(a, ID(b), "Question", replyExpected: true);
            var request = b.SwitchboardObligations.Single();
            check(request.Kind == "request" && b.Pending.Single().Text.Contains("inReplyTo") && a.SwitchboardExpectations.Single().Id == request.Id,
                "Tracked tell records correlated obligation and reply instructions");
            try { await home.SendAgentTellAsync(b, ID(a), "Wrong", inReplyTo: Guid.NewGuid()); check(false, "Forged reply rejected"); }
            catch (ArgumentException) { check(true, "Forged reply rejected"); }
            await home.SendAgentTellAsync(b, ID(a), "Answer", inReplyTo: request.Id);
            check(a.SwitchboardExpectations.Single().Answered && request.State == "resolved", "Authenticated correlated reply closes request");
            a.Pending.Clear(); b.Pending.Clear(); a.SwitchboardObligations.Clear(); b.SwitchboardObligations.Clear();
            await home.SendAgentTellAsync(a, ID(b), "Awaiting you");
            await home.SendAgentTellAsync(b, ID(a), "Awaiting you too");
            var now = DateTime.UtcNow;
            a.Busy = b.Busy = true;
            home.SuperviseSwitchboard(now);
            home.SuperviseSwitchboard(now.AddSeconds(121));
            check(!a.Interrupted && !b.Interrupted, "Mutual queues never resume human pauses");
            a.QueuePaused = b.QueuePaused = false;
            home.SuperviseSwitchboard(now.AddSeconds(119));
            check(!a.Interrupted && !b.Interrupted, "Mutual queue recovery waits for quiet period");
            home.SuperviseSwitchboard(now.AddSeconds(121));
            check(a.Interrupted != b.Interrupted && a.Pending.Count == 1 && b.Pending.Count == 1 && a.Draft == "A draft" && b.Draft == "B draft",
                "Mutual ordinary tells inject exactly one existing prompt without changing drafts");
            a.Interrupted = b.Interrupted = false;
            home.SuperviseSwitchboard(now.AddSeconds(1000));
            check(!a.Interrupted && !b.Interrupted, "Mutual recovery never interrupts both sides on repeated scans");
            var reload = new SessionStore(root, new FakeRunner());
            check(reload.Sessions.Where(s => s.Id == a.Id || s.Id == b.Id).All(s => s.SwitchboardObligations.Single().IntervenedAt is not null),
                "Restart preserves both sides of consumed mutual recovery");
            var combined = new ChatSession { MessagingEnabled = true, Busy = true };
            var part1 = new PendingPrompt { Text = "first" }; var part2 = new PendingPrompt { Text = "second" };
            combined.Pending.AddRange(new[] { part1, part2 });
            store.InjectPending(combined);
            check(combined.Pending.Single().ComponentIDs?.Contains(part1.Id) == true && combined.Pending.Single().ComponentIDs?.Contains(part2.Id) == true,
                "Inject all retains delivery identities for reply supervision");
            var peerRoot = Path.Combine(root, "peer");
            var peerStore = new SessionStore(peerRoot, new FakeRunner());
            using var peerHome = new DeviceSyncService(peerRoot, peerStore, "Remote supervision");
            var remote = peerStore.Create(new AgentEntry { Name = "Remote", Engine = "codex" });
            remote.MessagingEnabled = true; remote.QueuePaused = true;
            a.Busy = b.Busy = false; a.QueuePaused = b.QueuePaused = true;
            a.Pending.Clear(); a.SwitchboardObligations.Clear(); a.SwitchboardLastRecoveryAt = null;
            home.PairingConfirmation = _ => Task.FromResult(true); peerHome.PairingConfirmation = _ => Task.FromResult(true);
            await home.StartAsync(0, false); await peerHome.StartAsync(0, false);
            check(await join(home, peerHome, () => home.IsParticipantAllowed(peerHome.DeviceId, home.CurrentGroup?.Id) && peerHome.IsParticipantAllowed(home.DeviceId, peerHome.CurrentGroup?.Id)), "Supervision test homes join over authenticated loopback");
            var lotID = Guid.NewGuid();
            var lotGlobal = new DeviceGlobalID(peerHome.DeviceId, lotID).ToString();
            var linkedRow = DeviceJson.Decode<DeviceSidebarRow>(DeviceJson.Encode(new DeviceSidebarRow { GlobalID = lotGlobal, SessionID = lotID, Title = "Linked Mac lot", Engine = "parking", ParticipantKind = "parkingLot", LinkedSessionIDs = new[] { ID(asker) } }));
            var remoteRows = home.Homes[peerHome.DeviceId].Rows;
            remoteRows.Add(linkedRow);
            var linked = System.Text.Json.JsonSerializer.Serialize(home.ParkingLotDirectory(asker, true));
            check(linked.Contains("Linked Mac lot") && linked.Contains("linkedToMe\":true") && home.ParkingLotDirectory(answerer, true).Length == 0, "Windows discovers Group lots linked to the exact session identity");
            var beforeDirectory = asker.Pending.Count;
            store.FinalParticipantReply!(asker, "```converse\n{\"command\":\"parking-lot-list\",\"linkedOnly\":true}\n```");
            check(asker.Pending.Count == beforeDirectory + 1 && asker.Pending.Last().Text.Contains("Linked Mac lot"), "Windows session command returns linked lot discovery");
            asker.Agent = new AgentConfig();
            check(System.Text.Json.JsonSerializer.Serialize(home.ParkingLotDirectory(asker, true)).Contains("requires Agent Setup access"), "Windows linked agent gets no content permission implicitly");
            asker.Agent.Settings.Watched.Add(lotGlobal);
            check(System.Text.Json.JsonSerializer.Serialize(home.ParkingLotDirectory(asker, true)).Contains("scoped Group read-only evidence"), "Windows scoped agent sees the actual read-only capability");
            asker.Agent = null;
            var outsiderID = new string('c', 64);
            home.Homes[outsiderID] = new RemoteHomeState { DeviceID = outsiderID, DeviceName = "Old Group", Online = true, Rows = new() { linkedRow } };
            check(home.ParkingLotDirectory(asker, true).Length == 1, "Windows excludes cached lots outside the current Group");
            home.Homes.Remove(outsiderID); remoteRows.Remove(linkedRow);
            check(DeviceJson.Decode<DeviceSidebarRow>(System.Text.Encoding.UTF8.GetBytes("{}" )).LinkedSessionIDs is null, "Older sidebar rows remain compatible without links");

            async Task<bool> Until(Func<bool> done) { for (var i = 0; i < 200 && !done(); i++) await Task.Delay(25); return done(); }
            var remoteID = new DeviceGlobalID(peerHome.DeviceId, remote.Id).ToString();
            await Until(() => home.Homes.GetValueOrDefault(peerHome.DeviceId)?.Rows.Any(r => r.GlobalID == remoteID) == true && peerHome.Homes.GetValueOrDefault(home.DeviceId)?.Rows.Any(r => r.GlobalID == ID(a)) == true);
            await home.SendAgentTellAsync(a, remoteID, "Across homes");
            await peerHome.SendAgentTellAsync(remote, ID(a), "Back across homes");
            check(await Until(() => a.Pending.Count == 1 && remote.Pending.Count == 1 &&
                a.Messages.Any(m => m.Text.StartsWith("Switchboard: queued →") && m.Text.EndsWith("Across homes")) &&
                remote.Messages.Any(m => m.Text.StartsWith("Switchboard: queued →") && m.Text.EndsWith("Back across homes"))), "Mutual ordinary tells arrive and are acknowledged on both homes");
            a.Busy = remote.Busy = true; a.QueuePaused = remote.QueuePaused = false;
            // Start a new progress baseline, then age only the synthetic fixture.
            a.Messages.Add(new() { Role = "notice", Text = "fixture progress" });
            var remoteNow = DateTime.UtcNow;
            home.SuperviseSwitchboard(remoteNow.AddSeconds(-130)); peerHome.SuperviseSwitchboard(remoteNow.AddSeconds(-130));
            foreach (var item in a.SwitchboardObligations.Concat(remote.SwitchboardObligations)) item.CreatedAt = remoteNow.AddSeconds(-130);
            a.Interrupted = remote.Interrupted = false;
            home.SuperviseSwitchboard(DateTime.UtcNow); peerHome.SuperviseSwitchboard(DateTime.UtcNow);
            var recovered = await Until(() => {
                home.SuperviseSwitchboard(DateTime.UtcNow); peerHome.SuperviseSwitchboard(DateTime.UtcNow);
                return a.Interrupted || remote.Interrupted;
            });
            check(recovered && a.Interrupted != remote.Interrupted, "Two authenticated homes elect exactly one mutual-queue interruption");
            a.Interrupted = remote.Interrupted = false;
            home.SuperviseSwitchboard(DateTime.UtcNow); peerHome.SuperviseSwitchboard(DateTime.UtcNow);
            check(!a.Interrupted && !remote.Interrupted, "Remote mutual recovery never repeats on the other home");
            check(SwitchboardPresentation.Summary("[Converse message from Muse · session abc · delivery xyz]\nReview\nplease") == "Received tell from Muse · Review please", "Compact traffic shows peer and direction");
            var commandText = "```converse\n" + System.Text.Json.JsonSerializer.Serialize(new { command = "ask", to = a.Id.ToString(), text = "Review" }) + "\n```";
            check(SwitchboardPresentation.Summary(commandText, resolveName: _ => "MuseConverse") == "Ask to MuseConverse · Review", "Outgoing command resolves destination without claiming delivery");
            check(SwitchboardPresentation.Summary(commandText) == "Ask to Unavailable session · Review", "Unresolved IDs never appear in compact labels");
            check(SwitchboardPresentation.Summary("Switchboard: queued → Muse [id] · delivery [ask]\nReview") == "Queued ask to Muse · Review", "Accepted ask summary names destination and direction");
            check(SwitchboardPresentation.Summary("Switchboard: rejected → Muse [id] · delivery [tell]\nReview") == "Rejected tell to Muse · Review", "Rejected messages never render as sent");
            check(SwitchboardPresentation.Summary("[Converse message from Muse · session id]\nReview\n[Reply expected]", queued: true)!.StartsWith("Queued ask from Muse"), "Receiver queue identifies source and ask kind");
            check(SwitchboardPresentation.Summary("Some prose\n```converse\n{}\n```") is null, "Quoted JSON examples remain expanded");
        }
        finally { try { Directory.Delete(root, true); } catch (IOException) { /* Disposed transport callbacks may finish their last isolated write. */ } }
    }
}
