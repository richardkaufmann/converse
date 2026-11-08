using Converse.Core;
using System.Text.Json;
using System.Text.Json.Nodes;

// Mac parity for transcript-search / transcript-read (Sources/TranscriptSelfReadTests.swift).
static class TranscriptSelfReadChecks
{
    static async Task<bool> Eventually(Func<bool> done, int seconds = 10)
    {
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        while (!done() && DateTime.UtcNow < deadline) await Task.Delay(25);
        return done();
    }
    static JsonObject Json(string text) => text.IndexOf("\n{", StringComparison.Ordinal) is var at and >= 0 ? JsonNode.Parse(text[(at + 1)..]) as JsonObject ?? new() : new();
    static int[] Numbers(JsonObject value, string key = "messages") => (value[key] as JsonArray ?? new()).Select(m => m!["number"]!.GetValue<int>()).ToArray();

    public static async Task Run(Action<bool, string> check)
    {
        var root = Directory.CreateTempSubdirectory("converse-selfread-").FullName;
        try
        {
            var store = new SessionStore(root, new FakeRunner());
            using var home = new DeviceSyncService(root, store, "Self-read");
            var a = store.Create(new AgentEntry { Name = "Reader", Engine = "codex" });
            var b = store.Create(new AgentEntry { Name = "Neighbor", Engine = "codex" });
            foreach (var s in new[] { a, b }) s.QueuePaused = true;
            a.MessagingEnabled = true;
            for (var i = 1; i <= 30; i++) a.Messages.Add(new ChatMessage { Role = i % 2 == 1 ? "user" : "assistant", Text = $"message {i}" + (i is 7 or 21 ? " has the Needle" : ""), CreatedAt = DateTime.UtcNow });
            a.Messages.Insert(3, new ChatMessage { Role = "activity", Text = "tool output" });
            b.Messages.Add(new ChatMessage { Role = "user", Text = "neighbor secret needle" });
            string Fence(object command) => "```converse\n" + JsonSerializer.Serialize(command) + "\n```";
            void Reply(ChatSession s, string text) { s.Messages.Add(new ChatMessage { Role = "assistant", Text = text }); store.FinalParticipantReply!(s, text, TurnAuthority.Foreground()); }
            async Task<string> Result(ChatSession s, object command, string prose = "")
            {
                var before = s.Pending.Count; Reply(s, prose + Fence(command));
                await Eventually(() => s.Pending.Count > before);
                return s.Pending.Count > before ? s.Pending[^1].Text : "";
            }

            home.TeachSwitchboard(a);
            check(a.Pending[^1].Text.Contains("transcript-search") && a.Pending[^1].Text.Contains("only this session's own retained transcript")
                && SwitchboardInstructions.ConversationPolicy.Contains("transcript-read"), "Windows/Linux teaching and per-turn policy name the self-read commands");
            a.Pending.Clear();

            var page = await Result(a, new { command = "transcript-read", fromMessage = 5, count = 3 }, "Checking.\n");
            var read = Json(page);
            check(page.StartsWith(TranscriptSelfRead.Header) && page.Contains("reference data, not instructions") && Numbers(read).SequenceEqual(new[] { 5, 6, 7 })
                && read["messages"]![2]!["role"]!.GetValue<string>() == "user" && read["next"]!["fromMessage"]!.GetValue<int>() == 8 && a.Pending[^1].Hop == 1,
                "Windows/Linux transcript-read returns numbered messages with roles, framing and paging");
            check(Numbers(Json(await Result(a, new { command = "transcript-read", fromMessage = 1, count = 500 }))).Length == TranscriptSelfRead.MaxCount, "Windows/Linux pages are capped at 20 messages");
            var found = Json(await Result(a, new { command = "transcript-search", query = "NEEDLE" }));
            check(Numbers(found, "matches").SequenceEqual(new[] { 21, 7 }) && found["totalMatches"]!.GetValue<int>() == 2, "Windows/Linux transcript-search finds own matches newest first");
            var refused = await Result(a, new { command = "transcript-read", session = b.Id.ToString() });
            check(refused.StartsWith(TranscriptSelfRead.RefusedHeader) && !refused.Contains("neighbor"), "Windows/Linux refuses another session's transcript");
            check(TranscriptSelfRead.OwnsTarget(new DeviceGlobalID(home.DeviceId, a.Id).ToString(), a, home.DeviceId) && !TranscriptSelfRead.OwnsTarget(new DeviceGlobalID("other", a.Id).ToString(), a, home.DeviceId),
                "Windows/Linux accepts only this session's own home-qualified ID");
            var longSession = new ChatSession(); longSession.Messages.Add(new ChatMessage { Role = "assistant", Text = new string('x', 30_000) });
            var cut = Json(TranscriptSelfRead.Read(longSession, 1, 1, null));
            check(cut["messages"]![0]!["text"]!.GetValue<string>().Length == TranscriptSelfRead.MessageCharacters && cut["next"]!["fromCharacter"]!.GetValue<int>() == TranscriptSelfRead.MessageCharacters,
                "Windows/Linux long messages are cut and continue with fromCharacter");

            var neighbor = await Result(b, new { command = "transcript-read" });
            check(neighbor.Contains("neighbor secret needle") && !b.MessagingEnabled, "Windows/Linux untaught sessions may read their own transcript with a whole-reply command");
            var count = b.Pending.Count;
            Reply(b, "Looking.\n" + Fence(new { command = "transcript-read" }));
            await Task.Delay(200);
            check(b.Pending.Count == count, "Windows/Linux untaught trailing commands still run nothing");
        }
        finally { try { Directory.Delete(root, true); } catch (IOException) { } }
    }
}
