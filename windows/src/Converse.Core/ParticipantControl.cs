using System.Text.Json;
namespace Converse.Core;

public sealed class ParticipantIntent
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Home { get; set; } = "";
    public DeviceParticipantRequest Request { get; set; } = new();
    public string Outcome { get; set; } = "pending";
    public DeviceParticipantResponse? Response { get; set; }
}
public sealed class ParticipantReceipt
{
    public Guid Id { get; set; }
    public string Origin { get; set; } = "";
    public string Hash { get; set; } = "";
    public DeviceParticipantResponse Response { get; set; } = new();
}

public sealed partial class DeviceSyncService
{
    public const int SwitchboardMaxHops = 100;
    private List<ParticipantIntent> _participantIntents = new();
    private readonly Dictionary<Guid, TaskCompletionSource<DeviceParticipantResponse>> _participantWaiting = new();
    private void LoadParticipants()
    {
        var file = Path.Combine(_folder, "participant-intents.json");
        if (File.Exists(file)) _participantIntents = JsonSerializer.Deserialize<List<ParticipantIntent>>(File.ReadAllBytes(file)) ?? new();
        foreach (var intent in _participantIntents.Where(i => i.Outcome == "pending")) intent.Outcome = "uncertain";
    }
    private void SaveParticipants() => AtomicJson.Write(Path.Combine(_folder, "participant-intents.json"), _participantIntents);
    public bool CanHostAgent(string home) => home == DeviceId || PeerForHome(home)?.Hello?.Capabilities.Contains("agent-host-v1") == true;
    public async Task<DeviceParticipantResponse> RequestParticipantAsync(string home, string action, string? target = null, string? title = null, DeviceAgentSettings? settings = null)
    {
        var group = CurrentGroup?.Id ?? "";
        DeviceParticipantResponse Reject(string detail) => new() { GroupID = group, Detail = detail };
        if (group.Length == 0 || !IsGroupMember(home) || PeerForHome(home) is not { } peer || peer.Hello?.Capabilities.Contains("participant-control-v1") != true)
            return Reject("Home is offline, outside this group, or needs an update.");
        if (!string.IsNullOrEmpty(settings?.ScheduleText) && !peer.Hello.Capabilities.Contains("agent-schedule-v1"))
            return Reject("Update the home before editing text schedules.");
        var request = new DeviceParticipantRequest { GroupID = group, Action = action, Target = target, Title = title, Settings = settings };
        var bytes = DeviceJson.Encode(request);
        var intent = _participantIntents.FirstOrDefault(i => i.Home == home && i.Outcome is "pending" or "uncertain" && DeviceJson.Encode(i.Request).SequenceEqual(bytes));
        if (intent is null)
        {
            if (_participantIntents.Count >= 10000) return Reject("Operation journal is full.");
            intent = new ParticipantIntent { Home = home, Request = request };
            _participantIntents.Add(intent);
            try { SaveParticipants(); } catch { _participantIntents.Remove(intent); return Reject("Could not save the operation. Nothing was sent."); }
        }
        if (_participantWaiting.ContainsKey(intent.Id)) return Reject("This operation is already waiting for home.");
        var wait = new TaskCompletionSource<DeviceParticipantResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        _participantWaiting[intent.Id] = wait;
        try
        {
            await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = "participant.request", CommandID = intent.Id, Payload = bytes });
            return await wait.Task.WaitAsync(TimeSpan.FromSeconds(20));
        }
        catch
        {
            intent.Outcome = "uncertain"; try { SaveParticipants(); } catch { }
            return new() { GroupID = group, Outcome = "uncertain", Detail = "Home acceptance unconfirmed. Retry reuses the saved operation ID; nothing replays automatically." };
        }
        finally { _participantWaiting.Remove(intent.Id); }
    }
    private async Task<bool> HandleParticipantAsync(Peer peer, DeviceEnvelope envelope)
    {
        if (!envelope.Kind.StartsWith("participant.", StringComparison.Ordinal)) return false;
        if (peer.Hello is not { } hello || peer.ControlOnly || !IsGroupMember(hello.DeviceID) || CurrentGroup is not { } group || !hello.Capabilities.Contains("participant-control-v1") || envelope.CommandID is not { } id || envelope.Payload is not { } bytes || bytes.Length > 64000) return true;
        if (envelope.Kind == "participant.response")
        {
            var intent = _participantIntents.FirstOrDefault(i => i.Id == id && i.Home == hello.DeviceID && i.Request.GroupID == group.Id);
            if (intent is null) return true;
            var response = DeviceJson.Decode<DeviceParticipantResponse>(bytes);
            if (response.GroupID != group.Id) return true;
            intent.Response = response; intent.Outcome = response.Outcome; SaveParticipants();
            if (_participantWaiting.TryGetValue(id, out var waiter)) waiter.TrySetResult(response);
            return true;
        }
        if (envelope.Kind == "participant.request")
        {
            var request = DeviceJson.Decode<DeviceParticipantRequest>(bytes);
            if (request.GroupID != group.Id) return true;
            var response = await HandleAgentRequestAsync(hello.DeviceID, id, request);
            await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = "participant.response", CommandID = id, Payload = DeviceJson.Encode(response) });
            return true;
        }
        if (envelope.Kind == "participant.tell")
        {
            var request = DeviceJson.Decode<DeviceTellPayload>(bytes);
            var from = DeviceGlobalID.Parse(request.Source); var target = DeviceGlobalID.Parse(request.Target);
            var response = new DeviceAckPayload { Outcome = "rejected", Detail = "Invalid, disabled, or out-of-group target." };
            if (request.GroupID == group.Id && from?.Home == hello.DeviceID && target?.Home == DeviceId && request.Hop is > 0 and <= SwitchboardMaxHops && System.Text.Encoding.UTF8.GetByteCount(request.Text) is > 0 and <= 32768 && request.SourceTitle.Length <= 1000)
            {
                var session = _store.Sessions.FirstOrDefault(s => s.Id == target.Value.Session && s.MessagingEnabled);
                var hash = DeviceBlob.Sha256Hex(bytes);
                var prior = _store.ParticipantReceipts.FirstOrDefault(r => r.Id == id);
                if (prior is not null) response = new() { Outcome = prior.Origin == hello.DeviceID && prior.Hash == hash ? "queued" : "rejected", Detail = "Previously recorded delivery; nothing queued twice." };
                else if (session is not null && _store.ParticipantReceipts.Count < 100000)
                {
                    var prompt = new PendingPrompt { Text = $"[Converse message from {request.SourceTitle} · session {request.Source} · delivery {id} · hop {request.Hop}/{SwitchboardMaxHops}]\n{request.Text}", Autonomous = true, OriginGroupID = group.Id, OriginHomeID = hello.DeviceID, Hop = request.Hop };
                    session.Pending.Add(prompt);
                    var receipt = new ParticipantReceipt { Id = id, Origin = hello.DeviceID, Hash = hash };
                    _store.ParticipantReceipts.Add(receipt);
                    try { _store.Save(); response = new() { Outcome = "queued", Detail = "Persisted on home. Queued does not mean read or answered." }; _store.RunNext(session); }
                    catch { session.Pending.Remove(prompt); _store.ParticipantReceipts.Remove(receipt); }
                }
            }
            await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = "participant.tell.ack", CommandID = id, Payload = DeviceJson.Encode(response) });
            return true;
        }
        return true;
    }
}

public sealed partial class DeviceSyncService
{
    public bool IsParticipantAllowed(string home, string? group) => !LocallyRemoved && group is not null && CurrentGroup?.Id == group && (home == DeviceId || IsGroupMember(home));
    internal static DeviceParticipantEvidence Evidence(string home, ChatSession session) => new() { GlobalID = new DeviceGlobalID(home, session.Id).ToString(), Title = session.Title, Busy = session.Busy, Status = session.Status, Messages = session.Messages.Where(m => m.Role is "user" or "assistant" or "notice").TakeLast(20).Select(m => new DeviceWireMessage { Id = m.Id, Role = m.Role, Text = m.Text[..Math.Min(4000, m.Text.Length)] }).ToList() };
    public DeviceAgentWidget? AgentWidgetFor(ChatSession session)
    {
        if (session.Agent is not { } agent) return null;
        var widget = agent.Widget is null ? new DeviceAgentWidget { Summary = "Tell me what success looks like." } : DeviceJson.Decode<DeviceAgentWidget>(DeviceJson.Encode(agent.Widget));
        widget.Attention = agent.Attention; widget.LoopStatus = agent.LoopStatus;
        if (agent.ArtPath is { } art && File.Exists(art)) widget.ArtHash = ImageHash(art);
        return widget;
    }
    public event Action<ChatSession>? AgentWidgetRequested;
    private Task<DeviceParticipantResponse> HandleAgentRequestAsync(string origin, Guid id, DeviceParticipantRequest request)
    {
        var group = CurrentGroup?.Id ?? "";
        DeviceParticipantResponse Result(string outcome, string detail, ChatSession? session = null) => new() { GroupID = group, Outcome = outcome, Detail = detail, Target = session is null ? request.Target : new DeviceGlobalID(DeviceId, session.Id).ToString() };
        var target = request.Target is null ? null : DeviceGlobalID.Parse(request.Target);
        var session = target?.Home == DeviceId ? _store.Sessions.FirstOrDefault(s => s.Id == target.Value.Session) : null;
        if (request.Action == "inspect") return Task.FromResult(session is null ? Result("rejected", "Target is not on this home.") : new DeviceParticipantResponse { GroupID = group, Outcome = "completed", Detail = "Home evidence snapshot.", Target = request.Target, Evidence = Evidence(DeviceId, session) });
        if (request.Action == "agent.settings") return Task.FromResult(session?.Agent is not { } c ? Result("rejected", "Target is not an agent.") : new DeviceParticipantResponse { GroupID = group, Outcome = "completed", Detail = "Credentials stay on home.", Target = request.Target, Settings = DeviceJson.Decode<DeviceAgentSettings>(DeviceJson.Encode(c.Settings)) });
        var hash = DeviceBlob.Sha256Hex(DeviceJson.Encode(request));
        var previous = _store.ParticipantReceipts.FirstOrDefault(r => r.Id == id);
        if (previous is not null) return Task.FromResult(previous.Origin == origin && previous.Hash == hash ? previous.Response : Result("rejected", "Operation ID belongs to another request."));
        if (_store.ParticipantReceipts.Count >= 100000) return Task.FromResult(Result("rejected", "Home operation journal is full."));
        var old = session?.Agent is null ? null : JsonSerializer.SerializeToUtf8Bytes(session.Agent);
        var oldQueuePaused = session?.QueuePaused;
        var pending = session?.Pending.ToList(); ChatSession? created = null; bool run = false, widget = false;
        try
        {
            string detail;
            switch (request.Action)
            {
                case "agent.create": created = _store.CreateAgent(request.Title ?? "New Agent", false); session = created; detail = "Agent created paused. Add a Meta key on its home computer."; break;
                case "agent.configure":
                    if (session?.Agent is null || request.Settings is null || request.Settings.Watched.Any(w => DeviceGlobalID.Parse(w) is not { } r || !IsParticipantAllowed(r.Home, group))) throw new ArgumentException("Agent missing or scope outside this group.");
                    session.Agent.Apply(request.Settings); if (request.Settings.Enabled && session.Pending.Count == 0) session.QueuePaused = false; detail = "Settings saved on home."; break;
                case "agent.run":
                    if (session?.Agent is not { } agent || agent.Settings.TurnLimit <= 0 || session.Pending.Count >= 100) throw new ArgumentException("Agent missing, budget exhausted, or queue full.");
                    agent.Settings.Revision = checked((agent.Settings.Revision ?? 0) + 1);
                    session.Pending.Add(new PendingPrompt { Text = "[Human-requested agent run] Check progress and refresh the scoreboard.", Autonomous = true, AgentRunReserved = true, OriginGroupID = group, OriginHomeID = origin }); run = true; detail = "Run saved on home."; break;
                case "agent.widget": if (session?.Agent is null) throw new ArgumentException("Target is not an agent."); widget = true; detail = "Scoreboard requested on home."; break;
                default: return Task.FromResult(Result("rejected", "Unsupported operation."));
            }
            var response = Result("completed", detail, session);
            if (session?.Agent is { } saved) response.Settings = DeviceJson.Decode<DeviceAgentSettings>(DeviceJson.Encode(saved.Settings));
            _store.ParticipantReceipts.Add(new ParticipantReceipt { Id = id, Origin = origin, Hash = hash, Response = response });
            _store.Save();
            if (run) _store.RunNext(session!);
            if (widget) AgentWidgetRequested?.Invoke(session!);
            return Task.FromResult(response);
        }
        catch (Exception e)
        {
            if (created is not null) _store.Sessions.Remove(created);
            if (session is not null && old is not null) { session.Agent = JsonSerializer.Deserialize<AgentConfig>(old); session.Pending = pending ?? new(); if (oldQueuePaused is { } paused) session.QueuePaused = paused; }
            _store.ParticipantReceipts.RemoveAll(r => r.Id == id);
            return Task.FromResult(Result("rejected", e is ArgumentException ? e.Message : "Home could not save the operation. Nothing applied."));
        }
    }
    public async Task SendAgentTellAsync(ChatSession source, string target, string text)
    {
        if (!source.MessagingEnabled || source.Agent is { } config && !config.Settings.Watched.Contains(target) || source.ActiveHop >= SwitchboardMaxHops || DeviceGlobalID.Parse(target) is not { } to || to.Session == source.Id && to.Home == DeviceId) return;
        var id = Guid.NewGuid(); var hop = source.ActiveHop + 1;
        if (to.Home == DeviceId)
        {
            var session = _store.Sessions.FirstOrDefault(s => s.Id == to.Session && s.MessagingEnabled);
            if (session is null) return;
            session.Pending.Add(new PendingPrompt { Text = $"[Converse message from {source.Title} · session {new DeviceGlobalID(DeviceId, source.Id)} · delivery {id} · hop {hop}/{SwitchboardMaxHops}]\n{text}", Autonomous = true, Hop = hop });
            _store.Save(); _store.RunNext(session); return;
        }
        if (!IsParticipantAllowed(to.Home, CurrentGroup?.Id) || PeerForHome(to.Home) is not { } peer || peer.Hello?.Capabilities.Contains("participant-control-v1") != true || Homes.GetValueOrDefault(to.Home)?.Rows.Any(r => r.GlobalID == target && r.MessagingEnabled == true) != true) return;
        var request = new DeviceTellPayload { GroupID = CurrentGroup!.Id, Source = new DeviceGlobalID(DeviceId, source.Id).ToString(), SourceTitle = source.Title, Target = target, Text = text, Hop = hop };
        source.Messages.Add(new ChatMessage { Role = "notice", Text = $"Switchboard: sent to home for acceptance · {id}. No automatic replay." }); _store.Save();
        await SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = "participant.tell", CommandID = id, Payload = DeviceJson.Encode(request) });
    }
}

public sealed partial class DeviceSyncService
{
    public static System.Text.Json.Nodes.JsonObject? ParseSwitchboardReply(string reply)
    {
        var text = reply.Trim().Replace("\r\n", "\n");
        if (!text.StartsWith("```converse\n") || !text.EndsWith("\n```")) return null;
        try { return System.Text.Json.Nodes.JsonNode.Parse(text[12..^4]) as System.Text.Json.Nodes.JsonObject; } catch { return null; }
    }
    public void TeachSwitchboard(ChatSession session)
    {
        session.MessagingEnabled = true;
        session.Pending.Add(new PendingPrompt { Text = "[Converse switchboard instructions]\nYour entire final reply must be exactly one converse fenced JSON block, without prose before or after it. Otherwise it is discussion and sends nothing. Discover IDs using ```converse\\n{\"command\":\"list-sessions\"}\\n``` (use real newlines). Send using {\"command\":\"tell\",\"to\":\"exact directory ID\",\"text\":\"message\"} in the same whole-reply fence. Delivery is queued, not proof it was read. Only local and current-group targets are available. Do not acknowledge messages with more tells unless needed." });
        _store.Save(); _store.RunNext(session);
    }
    private async Task ProcessParticipantReplyAsync(ChatSession source, string reply)
    {
        var command = ParseSwitchboardReply(reply);
        if (command is null || source.Agent is not null) return;
        try
        {
            if (!source.MessagingEnabled) { source.Messages.Add(new ChatMessage { Role = "notice", Text = "Switchboard command ignored: teach this session the switchboard first." }); _store.Save(); return; }
            if (source.ActiveHop >= SwitchboardMaxHops) { source.Messages.Add(new ChatMessage { Role = "notice", Text = "Switchboard chain limit reached." }); _store.Save(); return; }
            var action = command["command"]?.GetValue<string>();
            if (action is "list-sessions" or "sessions")
            {
                var rows = _store.Sessions.Select(s => new { id = new DeviceGlobalID(DeviceId,s.Id).ToString(), name = s.Title, homeDeviceName = DeviceName, online = true, messagingEnabled = s.MessagingEnabled }).ToList();
                foreach (var home in Homes.Values.Where(h => IsParticipantAllowed(h.DeviceID, CurrentGroup?.Id))) rows.AddRange(home.Rows.Select(s => new { id = s.GlobalID, name = s.Title, homeDeviceName = home.DeviceName, online = home.Online, messagingEnabled = s.MessagingEnabled == true }));
                source.Pending.Add(new PendingPrompt { Text = "[Converse switchboard directory · live lookup]\n" + JsonSerializer.Serialize(new { command = "sessions", self = new DeviceGlobalID(DeviceId,source.Id).ToString(), sessions = rows }), Hop = source.ActiveHop + 1 }); _store.Save();
            }
            else if (action == "tell" && command["to"]?.GetValue<string>() is { } target && command["text"]?.GetValue<string>() is { } text && text.Length is > 0 and <= 16000)
            {
                if (Guid.TryParse(target, out var local)) target = new DeviceGlobalID(DeviceId, local).ToString();
                await SendAgentTellAsync(source, target, text);
            }
            else { source.Messages.Add(new ChatMessage { Role = "notice", Text = "Switchboard command unsupported or invalid. Use list-sessions or tell." }); _store.Save(); }
        }
        catch { source.Messages.Add(new ChatMessage { Role = "notice", Text = "Switchboard delivery unconfirmed. Check the target before retrying." }); _store.Save(); }
    }
}
