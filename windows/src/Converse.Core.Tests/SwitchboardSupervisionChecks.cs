using Converse.Core;

static class SwitchboardSupervisionChecks
{
    // Wait on conditions with generous deadlines, never fixed poll counts:
    // the Windows 11 ARM64 VM runs these far slower than a Mac.
    static async Task<bool> Eventually(Func<bool> done, int seconds = 30)
    {
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
        return done();
    }
    // A finished reply from a human-started turn.
    static void Reply(SessionStore store, ChatSession source, string reply) => store.FinalParticipantReply!(source, reply, TurnAuthority.Foreground());

    // Models garble request UUIDs (observed: first 8 hex digits intact, the rest
    // invented). A reply must never be dropped for a bad inReplyTo.
    static async Task ReplyTolerance(Action<bool, string> check)
    {
        var root = Directory.CreateTempSubdirectory("converse-reply-tolerance-").FullName;
        try
        {
            var store = new SessionStore(root, new FakeRunner());
            using var home = new DeviceSyncService(root, store, "Reply tolerance");
            var asker = store.Create(new AgentEntry { Name = "Asker", Engine = "codex" });
            var answerer = store.Create(new AgentEntry { Name = "Answerer", Engine = "codex" });
            var other = store.Create(new AgentEntry { Name = "Other", Engine = "codex" });
            foreach (var s in new[] { asker, answerer, other }) { s.MessagingEnabled = true; s.QueuePaused = true; }
            string ID(ChatSession s) => new DeviceGlobalID(home.DeviceId, s.Id).ToString();
            async Task<Guid> Ask(ChatSession from)
            {
                await home.SendAgentTellAsync(from, TurnAuthority.Foreground(), ID(answerer), "Question", replyExpected: true);
                return answerer.SwitchboardObligations.Last(o => o.Kind == "request").Id;
            }
            // Request IDs are random; pin their prefixes so the fixtures are deterministic.
            Guid Pin(Guid id, string prefix)
            {
                var pinned = Guid.Parse(prefix + id.ToString()[8..]);
                answerer.SwitchboardObligations.Single(o => o.Id == id).Id = pinned;
                foreach (var s in new[] { asker, other }) foreach (var e in s.SwitchboardExpectations.Where(e => e.Id == id)) e.Id = pinned;
                return pinned;
            }
            SwitchboardObligation Request(Guid id) => answerer.SwitchboardObligations.Single(o => o.Id == id && o.Kind == "request");
            bool Answered(Guid id) => asker.SwitchboardExpectations.Single(e => e.Id == id).Answered;
            bool Delivered(string text, Guid? replyTo) => asker.Pending.LastOrDefault() is { } p && p.Text.Contains(text) &&
                (replyTo is { } r ? p.Text.Contains($"[Reply to request {r}]") : !p.Text.Contains("[Reply to request"));
            string LastNotice() => answerer.Messages.LastOrDefault(m => m.Role == "notice")?.Text ?? "";

            var exact = await Ask(asker);
            await home.SendAgentTellAsync(answerer, TurnAuthority.Foreground(), ID(asker), "Exact answer", inReplyTo: exact);
            check(Request(exact).State == "resolved" && Answered(exact) && Delivered("Exact answer", exact) && !LastNotice().Contains("reply ID"),
                "Exact inReplyTo resolves the request without a correction notice");

            var decoy = Pin(await Ask(asker), "aaaaaaaa");
            var real = Pin(await Ask(asker), "cde10dc4");
            await home.SendAgentTellAsync(answerer, TurnAuthority.Foreground(), ID(asker), "APPROVE", suppliedReply: "CDE10DC4-2353-4A2F-81AC-35BE0DF9701F");
            check(Request(real).State == "resolved" && Request(real).ReplyDeliveryID is not null && Answered(real) && Request(decoy).ReplyDeliveryID is null && !Answered(decoy) &&
                Delivered("APPROVE", real) && LastNotice() == $"Switchboard: reply ID corrected to {real} (supplied CDE10DC4-2353-4A2F-81AC-35BE0DF9701F)",
                "Garbled inReplyTo with a matching 8-digit prefix is corrected to the right open request");

            await home.SendAgentTellAsync(answerer, TurnAuthority.Foreground(), ID(asker), "Decoy answer", suppliedReply: "DEADBEEF-1111-4111-8111-111111111111");
            check(Request(decoy).ReplyDeliveryID is not null && Answered(decoy) && Delivered("Decoy answer", decoy) && LastNotice().Contains($"corrected to {decoy}"),
                "Garbled inReplyTo is corrected to the single open request from that session");

            var first = Pin(await Ask(asker), "11111111"); var second = Pin(await Ask(asker), "22222222");
            await home.SendAgentTellAsync(answerer, TurnAuthority.Foreground(), ID(asker), "Ambiguous answer", suppliedReply: "99999999-0000-4000-8000-000000000000");
            check(Request(first).ReplyDeliveryID is null && Request(second).ReplyDeliveryID is null && !Answered(first) && !Answered(second) &&
                Delivered("Ambiguous answer", null) && LastNotice().Contains("matched no open request from Asker") && LastNotice().EndsWith("delivered as a plain tell."),
                "Ambiguous garbled inReplyTo delivers a plain tell without resolving anything");
            await home.SendAgentTellAsync(answerer, TurnAuthority.Foreground(), ID(asker), "Close first", inReplyTo: first);
            await home.SendAgentTellAsync(answerer, TurnAuthority.Foreground(), ID(asker), "Close second", inReplyTo: second);

            await home.SendAgentTellAsync(answerer, TurnAuthority.Foreground(), ID(asker), "Nothing open", suppliedReply: "cde10dc4-0000-4000-8000-000000000000");
            check(Delivered("Nothing open", null) && LastNotice().Contains("matched no open request"),
                "With no open requests a garbled inReplyTo still delivers as a plain tell");

            var foreign = Pin(await Ask(other), "77777777");
            var own = Pin(await Ask(asker), "33333333");
            await home.SendAgentTellAsync(answerer, TurnAuthority.Foreground(), ID(asker), "Scoped answer", suppliedReply: "77777777-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
            check(Request(own).ReplyDeliveryID is not null && Request(foreign).ReplyDeliveryID is null && !other.SwitchboardExpectations.Single(e => e.Id == foreign).Answered && Delivered("Scoped answer", own),
                "Correction considers only requests from the addressed session");
            await home.SendAgentTellAsync(answerer, TurnAuthority.Foreground(), ID(asker), "Other only", suppliedReply: "77777777-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
            check(Request(foreign).ReplyDeliveryID is null && Delivered("Other only", null), "A prefix match from a different session is never borrowed");

            var pending = Pin(await Ask(asker), "44444444");
            Reply(store, answerer, "```converse\n" + System.Text.Json.JsonSerializer.Serialize(new { command = "tell", to = asker.Id.ToString(), text = "Fenced answer", inReplyTo = "44444444" }) + "\n```");
            await Eventually(() => Delivered("Fenced answer", pending));
            check(Delivered("Fenced answer", pending) && Answered(pending) && LastNotice().Contains("supplied 44444444)"),
                "A truncated non-UUID inReplyTo in a fenced command is corrected and delivered");
            var instruction = DeviceSyncService.ReplyInstruction(real, true, null);
            check(instruction.Contains($"\n{real}\n") && instruction.Contains("copied exactly"), "Reply instructions place the full request UUID on its own line and ask for an exact copy");
        }
        finally { try { Directory.Delete(root, true); } catch (IOException) { } }
    }
    // Mac parity: prose then a trailing converse fence runs; a fence that
    // cannot run (text after it, several fences) explains why exactly once.
    static async Task TrailingFence(Action<bool, string> check)
    {
        var root = Directory.CreateTempSubdirectory("converse-trailing-fence-").FullName;
        try
        {
            var store = new SessionStore(root, new FakeRunner());
            using var home = new DeviceSyncService(root, store, "Trailing fence");
            var source = store.Create(new AgentEntry { Name = "Build A Video", Engine = "claude" });
            var target = store.Create(new AgentEntry { Name = "Reviewer", Engine = "codex" });
            foreach (var s in new[] { source, target }) { s.MessagingEnabled = true; s.QueuePaused = true; }
            string Tell(string text) => "```converse\n" + System.Text.Json.JsonSerializer.Serialize(new { command = "tell", to = target.Id.ToString(), text }) + "\n```";
            int Notices() => source.Messages.Count(m => m.Role == "notice");
            string LastNotice() => source.Messages.LastOrDefault(m => m.Role == "notice")?.Text ?? "";
            bool Delivered(string text) => target.Pending.Any(p => p.Text.Contains(text));

            var parsed = DeviceSyncService.ParseTrailingSwitchboardReply("Sending now.\nIt covers the intro.\n\n" + Tell("x") + "\n  \n");
            check(parsed.Command?["command"]?.GetValue<string>() == "tell" && parsed.Rejection is null, "Prose followed by a trailing converse fence parses as a command");
            check(DeviceSyncService.ParseTrailingSwitchboardReply(Tell("x")).Command is not null, "A whole-reply fence still parses");
            check(DeviceSyncService.ParseTrailingSwitchboardReply("Sending.\r\n" + Tell("x").Replace("\n", "\r\n")).Command is not null, "CRLF trailing fences parse");
            check(DeviceSyncService.ParseTrailingSwitchboardReply("Here:\n" + Tell("x") + "\nThanks").Rejection == "text follows it", "Text after a fence rejects it");
            check(DeviceSyncService.ParseTrailingSwitchboardReply("A:\n" + Tell("x") + "\nB:\n" + Tell("y")).Rejection == "the reply contains several command blocks", "Several fences reject the reply");
            check(DeviceSyncService.ParseTrailingSwitchboardReply("Sending:\n" + Tell("x") + "\n```bash\nls\n```").Rejection == "text follows it", "A later code block counts as text after the command");
            check(DeviceSyncService.ParseTrailingSwitchboardReply("Sending:\n```converse\n{\"command\":").Rejection == "its fence is not closed", "An unclosed fence rejects");
            check(DeviceSyncService.ParseTrailingSwitchboardReply("Sending:\n```converse\n{not json}\n```").Rejection == "its JSON is not a valid command", "Invalid command JSON rejects");
            var quiet = new[] { "Example:\n> " + Tell("x").Replace("\n", "\n> "), "Example:\n    " + Tell("x").Replace("\n", "\n    "), "Example:\n```json\n{\"command\":\"tell\"}\n```", "Plain prose" };
            check(quiet.All(q => DeviceSyncService.ParseTrailingSwitchboardReply(q) is { Command: null, Rejection: null }), "Quoted, indented and non-converse blocks are silent discussion");
            check(DeviceSyncService.ParseTrailingSwitchboardReply("See:\n```swift\nlet x = 1\n```\nSending.\n" + Tell("x")).Command is not null, "An earlier non-command code block does not block a trailing command");
            check(DeviceSyncService.ParseTrailingSwitchboardReply("Opening.\n```converse\n{\"command\":\"app-control\",\"action\":\"inspect\"}\n```") is { Command: null, Rejection: null }, "Trailing app-control keeps the whole-reply App Support rule");

            Reply(store, source, "Sending this to Reviewer now.\n\n" + Tell("Trailing hello"));
            check(await Eventually(() => Delivered("Trailing hello")), "Windows/Linux session delivers a tell that follows a line of prose");
            Reply(store, source, Tell("Whole hello"));
            check(await Eventually(() => Delivered("Whole hello")), "Windows/Linux whole-reply fences still deliver");
            var pending = target.Pending.Count; var before = Notices();
            Reply(store, source, "Here it is:\n" + Tell("Followed") + "\nLet me know.");
            check(await Eventually(() => Notices() == before + 1) && target.Pending.Count == pending &&
                LastNotice() == "Switchboard: a converse command in this reply was not run because text follows it. Nothing was sent. Ask the session to resend the command as the last thing in its reply.",
                "Windows/Linux fence followed by prose is not run and adds one notice");
            Reply(store, source, "A:\n" + Tell("One") + "\nB:\n" + Tell("Two"));
            check(await Eventually(() => Notices() == before + 2) && target.Pending.Count == pending && LastNotice().Contains("several command blocks"),
                "Windows/Linux reply with several fences is not run and adds one notice");
            source.MessagingEnabled = false;
            Reply(store, source, "Sending:\n" + Tell("Untaught") + "\nmore");
            Reply(store, source, "Sending:\n" + Tell("Untaught"));
            await Task.Delay(200);
            check(target.Pending.Count == pending && Notices() == before + 2, "Windows/Linux untaught sessions ignore non-whole fences silently");
            check(SwitchboardInstructions.ConversationPolicy.Contains("last thing in your reply (one per reply)") && !SwitchboardInstructions.ConversationPolicy.Contains("ENTIRE"), "Windows/Linux conversation policy teaches the trailing command rule");
            source.MessagingEnabled = true; source.Pending.Clear();
            home.TeachSwitchboard(source);
            check(source.Pending.LastOrDefault()?.Text.Contains("LAST thing in your reply") == true && source.Pending.Last().Text.Contains("one command block per reply"), "Windows/Linux teaching says the command block must be last, one per reply");
        }
        finally { try { Directory.Delete(root, true); } catch (IOException) { } }
    }
    // Inject all must not launder peer or agent prompts into a foreground
    // hop-0 human turn, and must still apply Group admission per part.
    static void InjectAllFlags(Action<bool, string> check)
    {
        var root = Directory.CreateTempSubdirectory("converse-inject-flags-").FullName;
        try
        {
            var group = Guid.NewGuid().ToString(); var peer = new string('a', 64); var removed = new string('b', 64); var other = new string('c', 64);
            var store = new SessionStore(root, new FakeRunner()) { AcceptGroupPrompt = p => p.OriginHomeID != removed };
            ChatSession Busy(params PendingPrompt[] prompts) { var s = new ChatSession { MessagingEnabled = true, Busy = true }; s.Pending.AddRange(prompts); return s; }

            var human = new PendingPrompt { Text = "human" };
            var tell = new PendingPrompt { Text = "peer", Autonomous = true, Hop = 3, AppControlDepth = 2, OriginGroupID = group, OriginHomeID = peer };
            var local = new PendingPrompt { Text = "agent", Autonomous = true, Hop = 1, AppControlDepth = 1 };
            var mixed = Busy(human, tell, local);
            var result = store.InjectPending(mixed);
            var m = mixed.Pending.SingleOrDefault();
            check(result is null && m is { Autonomous: true, Hop: 3, AppControlDepth: 2, AgentRunReserved: false } && m.OriginGroupID == group && m.OriginHomeID == peer
                && m.Text == "human\n\npeer\n\nagent" && new[] { human.Id, tell.Id, local.Id }.All(m.ComponentIDs!.Contains),
                "Inject all keeps the strictest flags: autonomous, max hop/app-control depth, and the Group origin");

            var reserved = Busy(new PendingPrompt { Text = "typed" }, new PendingPrompt { Text = "run", Autonomous = true, AgentRunReserved = true });
            store.InjectPending(reserved);
            check(reserved.Pending.SingleOrDefault() is { Autonomous: true, AgentRunReserved: true }, "Inject all keeps an agent run reservation");

            var revoked = new PendingPrompt { Text = "from removed member", Autonomous = true, Hop = 4, OriginGroupID = group, OriginHomeID = removed };
            var stale = Busy(new PendingPrompt { Text = "mine" }, revoked, new PendingPrompt { Text = "also mine" });
            store.InjectPending(stale);
            check(stale.Pending.SingleOrDefault() is { Autonomous: false, Hop: 0, OriginGroupID: null, Text: "mine\n\nalso mine" } p && !p.ComponentIDs!.Contains(revoked.Id),
                "Inject all drops a part whose Group origin is no longer allowed and keeps unrelated human input");
            var onlyRevoked = Busy(revoked, new PendingPrompt { Text = "x", OriginGroupID = group, OriginHomeID = removed });
            check(store.InjectPending(onlyRevoked) is string refused && refused.Length > 0 && onlyRevoked.Pending.Count == 0,
                "Inject all reports honestly when every part came from a removed Group member");

            var fromOther = new PendingPrompt { Text = "other peer", Autonomous = true, Hop = 2, OriginGroupID = group, OriginHomeID = other };
            var two = Busy(new PendingPrompt { Text = "mine" }, tell, fromOther, new PendingPrompt { Text = "later" });
            store.InjectPending(two);
            check(two.Pending.Count == 2 && two.Pending[0] is { OriginHomeID: var first, Text: "mine\n\npeer\n\nlater" } && first == peer
                && two.Pending[1] == fromOther,
                "Inject all never merges prompts from different Group senders under one origin");

            // Inject all merging traffic with typed input (Mac 941BAB1E parity).
            var typing = Busy(); typing.Draft = "typed while busy"; store.Submit(typing);
            check(typing.Pending.SingleOrDefault() is { Typed: true, Text: "typed while busy" }, "Composer input is marked typed in the queue");
            var request = Guid.NewGuid();
            string Envelope(string body, bool expected, Guid? replyTo) =>
                $"[Converse message from ClaudeConverse · session abc · delivery {Guid.NewGuid()} · hop 2/100]\n{body}" + DeviceSyncService.ReplyInstruction(Guid.NewGuid(), expected, replyTo);
            var reply = Envelope("Read-only diagnosis", false, request); var ask = Envelope("Which build?", true, null);
            const string typed = "OK, propose: make 148\n\nSecond paragraph.";
            const string replySummary = "Received reply from ClaudeConverse · Read-only diagnosis", askSummary = "Received ask from ClaudeConverse · Which build?";
            var replyPrompt = new PendingPrompt { Text = reply, Autonomous = true, Hop = 2 };
            var typedPrompt = new PendingPrompt { Text = typed, Typed = true };
            var agentHuman = Busy(replyPrompt, typedPrompt);
            store.InjectPending(agentHuman);
            var merged = agentHuman.Pending.Single();
            check(merged.Text == reply + "\n\n" + typed && merged.ComponentIDs!.Contains(replyPrompt.Id) && merged.ComponentIDs.Contains(typedPrompt.Id)
                && merged.Components is [{ Offset: 0, Kind: "traffic" } a, { Kind: "human" } b] && a.Length == reply.Length && b.Offset == reply.Length + 2 && b.Length == typed.Length,
                "Inject all records the traffic and typed parts without changing the merged text or durability IDs");
            check(SwitchboardPresentation.Segments(merged.Text, merged.Components) is [{ Summary: replySummary } r, { Summary: null } h] && r.Text == reply && h.Text == typed,
                "Agent then human: the reply collapses to its own summary and the typed prompt stays visible in full");
            agentHuman.Pending.Add(new PendingPrompt { Text = ask, Autonomous = true, Hop = 1 });
            store.InjectPending(agentHuman);
            var remerged = agentHuman.Pending.Single();
            check(remerged.Components?.Select(c => c.Kind).SequenceEqual(new[] { "traffic", "human", "traffic" }) == true
                && SwitchboardPresentation.Segments(remerged.Text, remerged.Components)?.Select(s => s.Summary).SequenceEqual(new[] { replySummary, null, askSummary }) == true,
                "Merging an already merged prompt keeps each recorded part: two summaries plus the visible typed text");
            var humanAgent = Busy(new PendingPrompt { Text = typed, Typed = true }, new PendingPrompt { Text = reply, Hop = 2, Autonomous = true });
            store.InjectPending(humanAgent);
            check(SwitchboardPresentation.Segments(humanAgent.Pending[0].Text, humanAgent.Pending[0].Components) is [{ Summary: null } typedFirst, { Summary: replySummary }] && typedFirst.Text == typed,
                "Human then agent: typed text first, then the reply's own summary");
            var trafficOnly = Busy(new PendingPrompt { Text = reply, Hop = 2, Autonomous = true }, new PendingPrompt { Text = ask, Hop = 1, Autonomous = true });
            store.InjectPending(trafficOnly);
            check(SwitchboardPresentation.Segments(trafficOnly.Pending[0].Text, trafficOnly.Pending[0].Components)?.Select(s => s.Summary).SequenceEqual(new[] { replySummary, askSummary }) == true,
                "Traffic-only merges still collapse, one summary per message");
            var lookalike = Busy(new PendingPrompt { Text = "Switchboard: why did it fail?", Typed = true }, new PendingPrompt { Text = "and this", Typed = true });
            store.InjectPending(lookalike);
            check(SwitchboardPresentation.Segments(lookalike.Pending[0].Text, lookalike.Pending[0].Components) is [{ Summary: null, Text: "Switchboard: why did it fail?\n\nand this" }],
                "Typed text that looks like a switchboard line never collapses once merged");
            check(SwitchboardPresentation.Segments("plain one\n\nplain two", new List<MessageComponent> { new() { Offset = 0, Length = 9, Kind = "human" }, new() { Offset = 11, Length = 9, Kind = "text" } }) is null
                && SwitchboardPresentation.Segments(reply, null) is null && SwitchboardPresentation.Segments(typed, null) is null,
                "Unmerged traffic and plain messages, and merges with no traffic, render whole exactly as before");
            var forged = new List<MessageComponent> { new() { Offset = 0, Length = reply.Length, Kind = "traffic" }, new() { Offset = merged.Text.Length + 5, Length = 3, Kind = "human" } };
            var hiding = new List<MessageComponent> { new() { Offset = 0, Length = reply.Length, Kind = "traffic" }, new() { Offset = reply.Length + 2, Length = 4, Kind = "traffic" } };
            check(SwitchboardPresentation.Segments(merged.Text, forged) is [{ Summary: null } forgedWhole] && forgedWhole.Text == merged.Text
                && SwitchboardPresentation.Segments(merged.Text, hiding) is [{ Summary: null } hidingWhole] && hidingWhole.Text == merged.Text,
                "Out-of-range ranges, or ranges leaving text uncovered, show the whole message expanded instead of hiding text");
            // A plain tell has no delivery block, so only recorded parts can
            // separate it from typed text. Invalid parts must never collapse it.
            var plainTell = "[Converse message from Fixture · session test · delivery test · hop 1/100]\nStatus message";
            const string humanText = "MY TYPED PROMPT MUST STAY VISIBLE";
            var markerless = plainTell + "\n\n" + humanText;
            var valid = SwitchboardPresentation.Components(new[] { (plainTell, "traffic"), (humanText, "human") }, markerless)!;
            bool Expanded(IReadOnlyList<MessageComponent>? parts) => SwitchboardPresentation.Segments(markerless, parts) is [{ Summary: null } only] && only.Text == markerless;
            check(SwitchboardPresentation.Segments(markerless, valid) is [{ Summary: "Received tell from Fixture · Status message" }, { Summary: null, Text: humanText }],
                "Markerless tell then typed text: valid parts keep the typed prompt visible");
            check(Expanded(new List<MessageComponent> { valid[0], new() { Offset = markerless.Length + 1, Length = 1, Kind = "human" } }),
                "Markerless tell then typed text: an out-of-bounds part shows the whole message expanded");
            check(Expanded(new List<MessageComponent> { valid[0], new() { Offset = valid[0].Length - 3, Length = markerless.Length - valid[0].Length + 3, Kind = "human" } }),
                "Markerless tell then typed text: overlapping parts show the whole message expanded");
            check(Expanded(new List<MessageComponent> { valid[0] }) && Expanded(new List<MessageComponent>()) && Expanded(new List<MessageComponent> { new() { Offset = 0, Length = 5, Kind = "traffic" } }),
                "Markerless tell then typed text: parts leaving non-blank text uncovered, including a single or empty list, show it expanded");
            check(SwitchboardPresentation.Segments(markerless, null) is null && SwitchboardPresentation.Summary(markerless) is not null,
                "Without components a markerless merge is ambiguous with a multi-paragraph tell and still collapses whole, as before");
            check(SwitchboardPresentation.QueueSummary(markerless, valid) is null && SwitchboardPresentation.QueueSummary(markerless, new List<MessageComponent> { valid[0] }) is null,
                "Queue rows with recorded parts, valid or not, never summarize over the typed text");
            // Metadata-only changes: the same text with different parts renders
            // differently, so every render cache key (Windows SameLine, queue
            // banner signature) must change with them.
            var trafficToHuman = new List<MessageComponent> { new() { Offset = valid[0].Offset, Length = valid[0].Length, Kind = "human" }, valid[1] };
            var partStates = new List<(string Name, List<MessageComponent>? Parts)> {
                ("absent", null), ("valid", valid), ("invalid", new() { valid[0] }), ("empty", new()), ("traffic→human", trafficToHuman), ("reordered", new() { valid[1], valid[0] }) };
            bool TypedVisible(IReadOnlyList<MessageComponent>? parts) => SwitchboardPresentation.Segments(markerless, parts)?.Any(s => s.Summary is null && s.Text.Contains(humanText)) == true;
            string Rendered(IReadOnlyList<MessageComponent>? parts) => string.Join("|", (SwitchboardPresentation.Segments(markerless, parts)
                ?? new List<TranscriptSegment> { new(markerless, SwitchboardPresentation.Summary(markerless)) }).Select(s => s.Summary ?? s.Text));
            check(partStates.Select(s => TypedVisible(s.Parts)).SequenceEqual(new[] { false, true, true, true, true, true })
                && Rendered(null) != Rendered(valid) && Rendered(valid) != Rendered(partStates[2].Parts) && Rendered(valid) != Rendered(trafficToHuman)
                && SwitchboardPresentation.Segments(markerless, trafficToHuman) is [{ Summary: null } asHuman] && asHuman.Text == markerless,
                "Same text, different parts: absent collapses; valid, invalid, empty, traffic→human and reordered parts render the typed prompt in full");
            var queueId = Guid.NewGuid();
            var distinct = true;
            for (var i = 0; i < partStates.Count; i++)
                for (var j = 0; j < partStates.Count; j++)
                    if (i != j && (SwitchboardPresentation.SameComponents(partStates[i].Parts, partStates[j].Parts)
                        || SwitchboardPresentation.ComponentsKey(partStates[i].Parts) == SwitchboardPresentation.ComponentsKey(partStates[j].Parts)
                        || SwitchboardPresentation.QueueSignature(queueId, markerless, partStates[i].Parts) == SwitchboardPresentation.QueueSignature(queueId, markerless, partStates[j].Parts)))
                        distinct = false;
            check(distinct, "Metadata-only changes (absent→valid, valid→invalid, traffic→human, reordered, empty) change the line comparison and the queue banner signature");
            var copy = SwitchboardPresentation.Snapshot(valid)!;
            check(SwitchboardPresentation.SameComponents(valid, copy) && SwitchboardPresentation.QueueSignature(queueId, markerless, valid) == SwitchboardPresentation.QueueSignature(queueId, markerless, copy)
                && SwitchboardPresentation.SameComponents(null, null) && !ReferenceEquals(copy, valid) && !ReferenceEquals(copy[0], valid[0]),
                "Equal parts keep the cached line and banner; a cached snapshot is a detached copy");
            var nullKind = DeviceJson.Decode<DeviceWireMessage>(System.Text.Encoding.UTF8.GetBytes("{\"id\":\"941BAB1E-4268-4C06-AFF5-0457C32E123D\",\"role\":\"user\",\"text\":\"x\",\"imageHashes\":[],\"components\":[{\"offset\":0,\"length\":1,\"kind\":null}]}"));
            check(SwitchboardPresentation.ComponentsKey(nullKind.Components) == "[0,1,~]" && SwitchboardPresentation.Snapshot(nullKind.Components) is [{ Kind: null }],
                "A part with a null kind from the wire keys and snapshots without throwing");
            // Archive/wire JSON with a null kind: every walker tolerates it, the
            // part stays visible, and null→"" is a change.
            var parsedNullKind = System.Text.Json.JsonSerializer.Deserialize<List<MessageComponent>>("[{\"offset\":0,\"length\":5,\"kind\":null}]")!;
            var emptyKind = new List<MessageComponent> { new() { Offset = 0, Length = 5, Kind = "" } };
            check(parsedNullKind is [{ Kind: null }] && SwitchboardPresentation.Segments("hello", parsedNullKind) is null
                && SwitchboardPresentation.Segments(plainTell, new List<MessageComponent> { new() { Offset = 0, Length = plainTell.Length, Kind = null! } }) is [{ Summary: null } nullKindTell] && nullKindTell.Text == plainTell
                && SwitchboardPresentation.ComponentsKey(parsedNullKind) != SwitchboardPresentation.ComponentsKey(emptyKind) && !SwitchboardPresentation.SameComponents(parsedNullKind, emptyKind)
                && SwitchboardPresentation.SameComponents(parsedNullKind, SwitchboardPresentation.Snapshot(parsedNullKind))
                && SwitchboardPresentation.QueueSignature(queueId, "hello", parsedNullKind) != SwitchboardPresentation.QueueSignature(queueId, "hello", emptyKind)
                && SwitchboardPresentation.QueueSummary("hello", parsedNullKind) is null && SwitchboardPresentation.Components(parsedNullKind, "hello", "hello", text => text) is [{ Kind: null }],
                "A deserialized null kind renders plain, never collapses traffic, and keys apart from an empty kind");
            // Null list entries are invalid metadata: the whole message shows
            // expanded, and nothing that walks the parts throws. The real wire,
            // queue and archive types read them as MessageComponent.Undecodable().
            var nullEntryLists = new[] { "[null]", "[{\"offset\":0,\"length\":" + plainTell.Length + ",\"kind\":\"traffic\"},null]", "[null,{\"offset\":" + (plainTell.Length + 2) + ",\"length\":" + humanText.Length + ",\"kind\":\"human\"}]" }
                .Select(json => System.Text.Json.JsonSerializer.Deserialize<List<MessageComponent>>(json)!).ToList();
            var nullEntriesSafe = nullEntryLists.All(parts =>
                parts.Any(part => part is null) && Expanded(parts) && SwitchboardPresentation.QueueSummary(markerless, parts) is null
                && SwitchboardPresentation.Components(parts, markerless, markerless, text => text) is [{ Kind: "text" } whole] && whole.Length == markerless.Length
                && SwitchboardPresentation.Snapshot(parts) is { } snap && snap.Count == parts.Count && SwitchboardPresentation.SameComponents(parts, snap)
                && SwitchboardPresentation.ComponentsKey(parts).Contains('!') && SwitchboardPresentation.QueueSignature(queueId, markerless, parts).Length > 0);
            check(nullEntriesSafe && SwitchboardPresentation.ComponentsKey(nullEntryLists[0]) != SwitchboardPresentation.ComponentsKey(new List<MessageComponent>())
                && SwitchboardPresentation.ComponentsKey(nullEntryLists[1]) != SwitchboardPresentation.ComponentsKey(new List<MessageComponent> { valid[0] }),
                "Null component entries show the whole message expanded, key apart from their neighbours, and never throw");
            var nullEntryWire = DeviceJson.Decode<DeviceWireMessage>(System.Text.Encoding.UTF8.GetBytes("{\"id\":\"941BAB1E-4268-4C06-AFF5-0457C32E123D\",\"role\":\"user\",\"text\":\"" + markerless.Replace("\n", "\\n") + "\",\"imageHashes\":[],\"components\":[null]}"));
            var nullEntryHeld = Busy(new PendingPrompt { Text = markerless, Components = nullEntryLists[1] }, new PendingPrompt { Text = "and more", Typed = true });
            store.InjectPending(nullEntryHeld);
            check(nullEntryWire.Text == markerless && nullEntryWire.Components is [{ Offset: -1, Length: 0, Kind: MessageComponent.Plain }] && Expanded(nullEntryWire.Components)
                && SwitchboardPresentation.Segments(nullEntryHeld.Pending[0].Text, nullEntryHeld.Pending[0].Components) is [{ Summary: null } nullHeldWhole] && nullHeldWhole.Text == markerless + "\n\nand more",
                "A wire message with a null part keeps its text as the undecodable marker, and Inject all over a null part keeps it visible");
            var archivedNullEntry = System.Text.Json.JsonSerializer.Deserialize<ChatMessage>("{\"Role\":\"user\",\"Text\":\"kept text\",\"Components\":[null,{\"offset\":0,\"length\":9,\"kind\":null}]}")!;
            check(archivedNullEntry.Text == "kept text" && archivedNullEntry.Components is [{ Offset: -1, Length: 0 }] && SwitchboardPresentation.Segments(archivedNullEntry.Text, archivedNullEntry.Components) is [{ Summary: null, Text: "kept text" }],
                "An archived message with null parts loads with its text as the undecodable marker and renders it whole");
            copy[0].Kind = "human";
            check(!SwitchboardPresentation.SameComponents(valid, copy) && valid[0].Kind == "traffic", "Mutating a part in place is seen against the cached snapshot");
            check(SwitchboardPresentation.QueueSummary(markerless, null) is not null && partStates.Skip(1).All(s => SwitchboardPresentation.QueueSummary(markerless, s.Parts) is null),
                "Queue rows: same text summarizes without parts and shows typed text in full once any parts arrive");
            // Display rewrites carry the parts, or keep the whole visible.
            var crlf = plainTell.Replace("\n", "\r\n") + "\n\n" + humanText;
            var crlfParts = SwitchboardPresentation.Components(new[] { (plainTell.Replace("\n", "\r\n"), "traffic"), (humanText, "human") }, crlf);
            var normalizedParts = SwitchboardPresentation.Components(crlfParts, crlf, markerless, text => text.Replace("\r\n", "\n"));
            check(SwitchboardPresentation.Segments(markerless, normalizedParts) is [{ Summary: not null }, { Summary: null, Text: humanText }],
                "Newline normalization moves the recorded parts with the text");
            check(SwitchboardPresentation.Components(valid, markerless, "rewritten whole", text => text) is [{ Offset: 0, Kind: "text" } marker] && marker.Length == "rewritten whole".Length
                && SwitchboardPresentation.Components(null, markerless, "x", text => text) is null
                && SwitchboardPresentation.Components(new List<MessageComponent> { valid[0] }, markerless, markerless, text => text) is [{ Kind: "text" } invalidMarker] && invalidMarker.Length == markerless.Length,
                "A rewrite the parts cannot follow, or invalid parts, become one visible part; no parts stay no parts");
            var invalidHeld = Busy(new PendingPrompt { Text = markerless, Components = new List<MessageComponent> { valid[0], new() { Offset = 999, Length = 1, Kind = "human" } } },
                new PendingPrompt { Text = "and more", Typed = true });
            store.InjectPending(invalidHeld);
            check(SwitchboardPresentation.Segments(invalidHeld.Pending[0].Text, invalidHeld.Pending[0].Components) is [{ Summary: null } heldWhole] && heldWhole.Text == markerless + "\n\nand more",
                "Inject all over a part with invalid ranges keeps that part visible instead of reclassifying it as traffic");
            var pendingWire = DeviceJson.Decode<DevicePendingDto>(DeviceJson.Encode(new DevicePendingDto { Id = Guid.NewGuid(), Text = markerless, Components = valid }));
            var olderPending = DeviceJson.Decode<DevicePendingDto>(System.Text.Encoding.UTF8.GetBytes("{\"id\":\"941BAB1E-4268-4C06-AFF5-0457C32E123D\",\"text\":\"x\"}"));
            check(SwitchboardPresentation.QueueSummary(pendingWire.Text, pendingWire.Components) is null && pendingWire.Components?.Count == 2 && olderPending.Components is null
                && !System.Text.Encoding.UTF8.GetString(DeviceJson.Encode(new DevicePendingDto { Text = "x" })).Contains("components"),
                "Queue snapshots carry merged parts when present and omit them otherwise");
            // Archived shape without metadata: reply envelope, separator, typed text.
            check(SwitchboardPresentation.Segments(reply + "\n\n" + typed, null) is [{ Summary: replySummary }, { Summary: null } legacyTyped] && legacyTyped.Text == typed,
                "Old merged messages split after the reply's delivery block and show the remainder unattributed and in full");
            check(SwitchboardPresentation.Segments(ask + "\n\n" + typed, null) is [{ Summary: askSummary }, { Summary: null }]
                && SwitchboardPresentation.Segments(reply + "\n\n" + ask + "\n\n" + typed, null)?.Select(s => s.Summary).SequenceEqual(new[] { replySummary, askSummary, null }) == true
                && SwitchboardPresentation.Segments(Envelope("Both", true, request) + "\n\n" + typed, null)?.LastOrDefault() is { Summary: null, Text: typed },
                "Old merges split after Reply expected blocks and after each of several envelopes");
            check(SwitchboardPresentation.Segments(Envelope("Status\n\nsecond paragraph", false, null), null) is null,
                "A single envelope, including multi-paragraph tells without a delivery block, still collapses as before");
            var unsafeText = reply + "\ntrailing text without the separator";
            check(SwitchboardPresentation.Segments(unsafeText, null) is [{ Summary: null } whole] && whole.Text == unsafeText, "Content after a delivery block that cannot be split safely shows the whole message expanded");
            check(SwitchboardPresentation.QueueSummary(reply) == "Queued reply from ClaudeConverse · Read-only diagnosis" && SwitchboardPresentation.QueueSummary(reply + "\n\n" + typed) is null,
                "Queue rows summarize whole traffic only and never hide merged typed input");
            var wire = DeviceJson.Decode<DeviceWireMessage>(DeviceJson.Encode(new DeviceWireMessage { Id = Guid.NewGuid(), Role = "user", Text = merged.Text, Components = merged.Components }));
            var olderPeer = DeviceJson.Decode<DeviceWireMessage>(System.Text.Encoding.UTF8.GetBytes("{\"id\":\"941BAB1E-4268-4C06-AFF5-0457C32E123D\",\"role\":\"user\",\"text\":\"x\",\"imageHashes\":[]}"));
            var swiftShape = DeviceJson.Decode<DeviceWireMessage>(System.Text.Encoding.UTF8.GetBytes("{\"id\":\"941BAB1E-4268-4C06-AFF5-0457C32E123D\",\"role\":\"user\",\"text\":\"x\",\"imageHashes\":[],\"components\":[{\"offset\":0,\"length\":1,\"kind\":\"traffic\"}]}"));
            check(wire.Components?.Select(c => (c.Offset, c.Length, c.Kind)).SequenceEqual(merged.Components!.Select(c => (c.Offset, c.Length, c.Kind))) == true && olderPeer.Components is null
                && swiftShape.Components is [{ Offset: 0, Length: 1, Kind: "traffic" }] && !System.Text.Encoding.UTF8.GetString(DeviceJson.Encode(new DeviceWireMessage { Text = "x" })).Contains("components"),
                "The transcript DTO carries components in the Swift shape when present and omits them otherwise");
        }
        finally { try { Directory.Delete(root, true); } catch { } }
    }

    // Shared parity vectors (also run by the Swift suite): every malformed
    // components shape loads through the real wire, queue and archive types,
    // keeps its text, renders whole, and re-saves as the same marker.
    static void ComponentVectors(Action<bool, string> check)
    {
        string? vectorFile = null;
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null && vectorFile is null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "Tests", "inject-components-vectors.json"))) vectorFile = Path.Combine(dir.FullName, "Tests", "inject-components-vectors.json");
        check(vectorFile is not null, "Shared components vectors are readable");
        if (vectorFile is null) return;
        var file = System.Text.Json.JsonDocument.Parse(File.ReadAllBytes(vectorFile)).RootElement;
        var text = file.GetProperty("text").GetString()!;
        var typed = file.GetProperty("typed").GetString()!;
        var vectors = file.GetProperty("vectors").EnumerateArray()
            .Select(v => (Name: v.GetProperty("name").GetString()!, Raw: v.GetProperty("components").GetString()!, Expect: v.GetProperty("expect").GetString()!)).ToList();
        // Serializes `value` without its components, then splices in the raw JSON.
        string Spliced<T>(T value, string raw, System.Text.Json.JsonSerializerOptions? options = null)
        {
            var node = System.Text.Json.JsonSerializer.SerializeToNode(value, options)!.AsObject();
            node.Remove("components"); node.Remove("Components");
            var json = node.ToJsonString();
            return json[..^1] + (typeof(T) == typeof(ChatMessage) || typeof(T) == typeof(PendingPrompt) ? ",\"Components\":" : ",\"components\":") + raw + "}";
        }
        var id = Guid.NewGuid();
        bool Loaded(IReadOnlyList<MessageComponent>? parts, string expect)
        {
            var segments = SwitchboardPresentation.Segments(text, parts);
            var whole = segments is [{ Summary: null } only] && only.Text == text;
            var stable = SwitchboardPresentation.ComponentsKey(parts) == SwitchboardPresentation.ComponentsKey(SwitchboardPresentation.Snapshot(parts))
                && SwitchboardPresentation.QueueSignature(id, text, parts) == SwitchboardPresentation.QueueSignature(id, text, SwitchboardPresentation.Snapshot(parts));
            return stable && expect switch
            {
                "absent" => parts is null,
                "empty" => parts is { Count: 0 } && whole,
                "valid" => segments is [{ Summary: not null }, { Summary: null } typedPart] && typedPart.Text == typed,
                "undecodable" => parts is [{ Offset: -1, Length: 0, Kind: MessageComponent.Plain }] && whole && SwitchboardPresentation.QueueSummary(text, parts) is null
                    && SwitchboardPresentation.Components(parts, text, text, t => t) is [{ Kind: MessageComponent.Plain } visible] && visible.Length == text.Length,
                _ => false,
            };
        }
        var failed = new List<string>();
        foreach (var (name, raw, expect) in vectors)
        {
            try
            {
                var wire = DeviceJson.Decode<DeviceWireMessage>(System.Text.Encoding.UTF8.GetBytes(Spliced(new DeviceWireMessage { Id = Guid.NewGuid(), Role = "user", Text = text }, raw, DeviceJson.Options)));
                var pending = DeviceJson.Decode<DevicePendingDto>(System.Text.Encoding.UTF8.GetBytes(Spliced(new DevicePendingDto { Id = Guid.NewGuid(), Text = text }, raw, DeviceJson.Options)));
                var archived = System.Text.Json.JsonSerializer.Deserialize<ChatMessage>(Spliced(new ChatMessage { Role = "user", Text = text }, raw))!;
                var queued = System.Text.Json.JsonSerializer.Deserialize<PendingPrompt>(Spliced(new PendingPrompt { Text = text }, raw))!;
                var wireBytes = DeviceJson.Encode(wire);
                var rewired = DeviceJson.Decode<DeviceWireMessage>(wireBytes);
                var rearchived = System.Text.Json.JsonSerializer.Deserialize<ChatMessage>(System.Text.Json.JsonSerializer.Serialize(archived))!;
                var exact = name != "valid" || System.Text.Encoding.UTF8.GetString(wireBytes).Contains("\"components\":" + raw);
                if (!(new[] { wire.Text, pending.Text, archived.Text, queued.Text, rewired.Text, rearchived.Text }.All(t => t == text) && exact
                    && new[] { wire.Components, pending.Components, archived.Components, queued.Components, rewired.Components, rearchived.Components }.All(parts => Loaded(parts, expect))))
                    failed.Add(name);
            }
            catch (Exception e) { failed.Add(name + " (" + e.GetType().Name + ")"); }
        }
        check(vectors.Count >= 20 && failed.Count == 0, "Every shared components vector loads through DeviceWireMessage, DevicePendingDto, ChatMessage and PendingPrompt, and re-saves without throwing" + (failed.Count == 0 ? "" : ": " + string.Join(", ", failed)));
        // One damaged message among valid ones: the whole device snapshot and
        // the whole archive still load with every message.
        try
        {
            var snapshot = System.Text.Json.JsonSerializer.SerializeToNode(new DeviceTranscriptPayload { GlobalID = "g", HomeSeq = 1, Status = "Ready" }, DeviceJson.Options)!.AsObject();
            snapshot["messages"] = System.Text.Json.Nodes.JsonNode.Parse("[" + string.Join(",", vectors.Select(v => Spliced(new DeviceWireMessage { Id = Guid.NewGuid(), Role = "user", Text = text }, v.Raw, DeviceJson.Options))) + "]");
            snapshot["pending"] = System.Text.Json.Nodes.JsonNode.Parse("[" + string.Join(",", vectors.Select(v => Spliced(new DevicePendingDto { Id = Guid.NewGuid(), Text = text }, v.Raw, DeviceJson.Options))) + "]");
            var page = DeviceJson.Decode<DeviceTranscriptPayload>(System.Text.Encoding.UTF8.GetBytes(snapshot.ToJsonString()));
            check(page.Messages.Count == vectors.Count && page.Pending.Count == vectors.Count
                && page.Messages.Zip(vectors).All(p => p.First.Text == text && Loaded(p.First.Components, p.Second.Expect)) && page.Pending.Zip(vectors).All(p => p.First.Text == text && Loaded(p.First.Components, p.Second.Expect)),
                "A device snapshot mixing every malformed shape with valid parts loads every message and queue row");
        }
        catch (Exception e) { check(false, "A device snapshot with malformed parts loads: " + e.GetType().Name + " " + e.Message); }
        var root = Directory.CreateTempSubdirectory("converse-component-vectors-").FullName;
        try
        {
            var seed = new SessionStore(root, new FakeRunner());
            seed.Create(new AgentEntry { Name = "Vectors", Engine = "codex" });
            var file2 = Path.Combine(root, "sessions.json");
            var archive = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(file2))!;
            var session = archive["Sessions"]![0]!;
            session["Messages"] = System.Text.Json.Nodes.JsonNode.Parse("[" + string.Join(",", vectors.Select(v => Spliced(new ChatMessage { Role = "user", Text = text }, v.Raw))) + "]");
            session["Pending"] = System.Text.Json.Nodes.JsonNode.Parse("[" + string.Join(",", vectors.Select(v => Spliced(new PendingPrompt { Text = text }, v.Raw))) + "]");
            File.WriteAllText(file2, archive.ToJsonString());
            bool Archived(SessionStore store) => store.Sessions is [{ } only] && only.Messages.Count == vectors.Count && only.Pending.Count == vectors.Count
                && only.Messages.Zip(vectors).All(p => p.First.Text == text && Loaded(p.First.Components, p.Second.Expect))
                && only.Pending.Zip(vectors).All(p => p.First.Text == text && Loaded(p.First.Components, p.Second.Expect));
            var loaded = new SessionStore(root, new FakeRunner());
            var first = Archived(loaded);
            loaded.Save();
            check(first && Archived(new SessionStore(root, new FakeRunner())),
                "An archive mixing every malformed shape with valid parts loads every message and queued prompt, and re-saves the marker");
        }
        catch (Exception e) { check(false, "An archive with malformed parts loads: " + e.GetType().Name + " " + e.Message); }
        finally { Directory.Delete(root, true); }
    }

    public static async Task Run(Action<bool, string> check, Func<DeviceSyncService, DeviceSyncService, Func<bool>, Task<bool>> join)
    {
        InjectAllFlags(check);
        ComponentVectors(check);
        await ReplyTolerance(check);
        await TrailingFence(check);
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
                Reply(store, asker, "```converse\n" + body + "\n```");
                await Eventually(() => answerer.Pending.Count >= count);
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
            await home.SendAgentTellAsync(a, TurnAuthority.Foreground(), ID(b), "Question", replyExpected: true);
            var request = b.SwitchboardObligations.Single();
            check(request.Kind == "request" && b.Pending.Single().Text.Contains("inReplyTo") && a.SwitchboardExpectations.Single().Id == request.Id,
                "Tracked tell records correlated obligation and reply instructions");
            await home.SendAgentTellAsync(b, TurnAuthority.Foreground(), ID(answerer), "Wrong", inReplyTo: Guid.NewGuid());
            check(request.ReplyDeliveryID is null && !a.SwitchboardExpectations.Single().Answered && answerer.Pending.Last().Text.Contains("Wrong") && !answerer.Pending.Last().Text.Contains("[Reply to request"),
                "Unrelated reply ID cannot satisfy another session's request; message still delivered as a plain tell");
            await home.SendAgentTellAsync(b, TurnAuthority.Foreground(), ID(a), "Answer", inReplyTo: request.Id);
            check(a.SwitchboardExpectations.Single().Answered && request.State == "resolved", "Authenticated correlated reply closes request");
            a.Pending.Clear(); b.Pending.Clear(); a.SwitchboardObligations.Clear(); b.SwitchboardObligations.Clear();
            await home.SendAgentTellAsync(a, TurnAuthority.Foreground(), ID(b), "Awaiting you");
            await home.SendAgentTellAsync(b, TurnAuthority.Foreground(), ID(a), "Awaiting you too");
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
            // The live peer republishes its sidebar (now also on response/pause
            // marker changes), which swaps in a new replica state without this
            // fixture row, even between re-injecting it and querying. Re-inject
            // before each attempt and accept a result only when no republish
            // replaced the state during the query; otherwise retry. A stable
            // attempt returns its real answer, so negative checks stay honest.
            async Task<bool> withLinkedLot(Func<bool> query)
            {
                var deadline = DateTime.UtcNow.AddSeconds(30);
                while (true)
                {
                    var state = home.Homes[peerHome.DeviceId];
                    if (!state.Rows.Any(r => r.GlobalID == lotGlobal)) state.Rows.Add(linkedRow);
                    var result = query();
                    if (ReferenceEquals(home.Homes[peerHome.DeviceId], state) || DateTime.UtcNow >= deadline) return result;
                    await Task.Delay(25);
                }
            }
            check(await withLinkedLot(() =>
            {
                var linked = System.Text.Json.JsonSerializer.Serialize(home.ParkingLotDirectory(asker, true));
                return linked.Contains("Linked Mac lot") && linked.Contains("linkedToMe\":true") && home.ParkingLotDirectory(answerer, true).Length == 0;
            }), "Windows discovers Group lots linked to the exact session identity");
            var beforeDirectory = asker.Pending.Count;
            check(await withLinkedLot(() =>
            {
                // An interrupted attempt may have queued a directory without the lot.
                while (asker.Pending.Count > beforeDirectory) asker.Pending.RemoveAt(asker.Pending.Count - 1);
                Reply(store, asker, "```converse\n{\"command\":\"parking-lot-list\",\"linkedOnly\":true}\n```");
                return asker.Pending.Count == beforeDirectory + 1 && asker.Pending.Last().Text.Contains("Linked Mac lot");
            }), "Windows session command returns linked lot discovery");
            asker.Agent = new AgentConfig();
            check(await withLinkedLot(() => System.Text.Json.JsonSerializer.Serialize(home.ParkingLotDirectory(asker, true)).Contains("requires Agent Setup access")), "Windows linked agent gets no content permission implicitly");
            asker.Agent.Settings.Watched.Add(lotGlobal);
            check(await withLinkedLot(() => System.Text.Json.JsonSerializer.Serialize(home.ParkingLotDirectory(asker, true)).Contains("scoped Group read-only evidence")), "Windows scoped agent sees the actual read-only capability");
            asker.Agent = null;
            var outsiderID = new string('c', 64);
            home.Homes[outsiderID] = new RemoteHomeState { DeviceID = outsiderID, DeviceName = "Old Group", Online = true, Rows = new() { linkedRow } };
            check(await withLinkedLot(() => home.ParkingLotDirectory(asker, true).Length == 1), "Windows excludes cached lots outside the current Group");
            home.Homes.Remove(outsiderID); home.Homes[peerHome.DeviceId].Rows.RemoveAll(r => r.GlobalID == lotGlobal);
            check(DeviceJson.Decode<DeviceSidebarRow>(System.Text.Encoding.UTF8.GetBytes("{}" )).LinkedSessionIDs is null, "Older sidebar rows remain compatible without links");

            Task<bool> Until(Func<bool> done) => Eventually(done);
            var remoteID = new DeviceGlobalID(peerHome.DeviceId, remote.Id).ToString();
            // Cross-home tells silently skip targets whose row is not yet
            // messaging-enabled, so wait for exactly that precondition.
            await Until(() => home.Homes.GetValueOrDefault(peerHome.DeviceId)?.Rows.Any(r => r.GlobalID == remoteID && r.MessagingEnabled == true) == true && peerHome.Homes.GetValueOrDefault(home.DeviceId)?.Rows.Any(r => r.GlobalID == ID(a) && r.MessagingEnabled == true) == true);
            await home.SendAgentTellAsync(a, TurnAuthority.Foreground(), remoteID, "Across homes");
            await peerHome.SendAgentTellAsync(remote, TurnAuthority.Foreground(), ID(a), "Back across homes");
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
            var remoteAsk = Guid.Empty;
            await peerHome.SendAgentTellAsync(remote, TurnAuthority.Foreground(), ID(a), "Remote question", replyExpected: true);
            await Until(() => (remoteAsk = a.SwitchboardObligations.ToArray().LastOrDefault(o => o.Kind == "request" && o.Source == remoteID)?.Id ?? Guid.Empty) != Guid.Empty);
            var remoteGarbled = remoteAsk.ToString()[..8] + "-2353-4a2f-81ac-35be0df9701f";
            await home.SendAgentTellAsync(a, TurnAuthority.Foreground(), remoteID, "Remote APPROVE", suppliedReply: remoteGarbled);
            check(remoteAsk != Guid.Empty && await Until(() => remote.Pending.ToArray().Any(p => p.Text.Contains("Remote APPROVE") && p.Text.Contains($"[Reply to request {remoteAsk}]")) &&
                remote.SwitchboardExpectations.ToArray().Any(e => e.Id == remoteAsk && e.Answered)) && a.Messages.ToArray().Any(m => m.Text == $"Switchboard: reply ID corrected to {remoteAsk} (supplied {remoteGarbled})"),
                "Garbled reply to a remote home's request is corrected before crossing devices");
            check(SwitchboardPresentation.Summary("[Converse message from Muse · session abc · delivery xyz]\nReview\nplease") == "Received tell from Muse · Review please", "Compact traffic shows peer and direction");
            var commandText = "```converse\n" + System.Text.Json.JsonSerializer.Serialize(new { command = "ask", to = a.Id.ToString(), text = "Review" }) + "\n```";
            check(SwitchboardPresentation.Summary(commandText, resolveName: _ => "MuseConverse") == "Ask to MuseConverse · Review", "Outgoing command resolves destination without claiming delivery");
            check(SwitchboardPresentation.Summary(commandText) == "Ask to Unavailable session · Review", "Unresolved IDs never appear in compact labels");
            check(SwitchboardPresentation.Summary("Switchboard: queued → Muse [id] · delivery [ask]\nReview") == "Queued ask to Muse · Review", "Accepted ask summary names destination and direction");
            check(SwitchboardPresentation.Summary("Switchboard: rejected → Muse [id] · delivery [tell]\nReview") == "Rejected tell to Muse · Review", "Rejected messages never render as sent");
            check(SwitchboardPresentation.Summary("[Converse message from Muse · session id]\nReview\n[Reply expected]", queued: true)!.StartsWith("Queued ask from Muse"), "Receiver queue identifies source and ask kind");
            check(SwitchboardPresentation.Summary("Some prose\n```converse\n{}\n```") is null, "Quoted JSON examples remain expanded");
            // Incoming traffic built as delivery builds it: an inReplyTo answer reads as a reply (bug 9DF32E78).
            var envelopeRequest = Guid.NewGuid(); var envelopeDelivery = Guid.NewGuid();
            foreach (var (body, expected, replyTo, kind) in new (string, bool, Guid?, string)[] { ("Status update", false, null, "tell"), ("Can you check?", true, null, "ask"), ("Done; fixed it", false, envelopeRequest, "reply"), ("Done; which branch?", true, envelopeRequest, "reply + ask") })
            {
                var envelope = $"[Converse message from ClaudeConverse · session abc · delivery {envelopeDelivery} · hop 1/100]\n{body}" + DeviceSyncService.ReplyInstruction(envelopeDelivery, expected, replyTo);
                check(SwitchboardPresentation.Summary(envelope) == $"Received {kind} from ClaudeConverse · {body}" && SwitchboardPresentation.Summary(envelope, queued: true) == $"Queued {kind} from ClaudeConverse · {body}",
                    $"Incoming {kind} reads as {kind} when received and queued, without delivery instructions");
            }
            check(SwitchboardPresentation.Summary($"Switchboard: message queued from ClaudeConverse · session abc\nDone\n[Reply to request {envelopeRequest}]") == "Queued reply from ClaudeConverse · Done", "Legacy queue receipts also read replies as replies");
            check(SwitchboardPresentation.Summary("[Converse message from Muse · session abc]\nI read [Reply to request X] in the docs") == "Received tell from Muse · I read [Reply to request X] in the docs", "Only the delivery reply marker, not quoted body text, makes a reply");
        }
        finally { try { Directory.Delete(root, true); } catch (IOException) { /* Disposed transport callbacks may finish their last isolated write. */ } }
    }
}
