namespace Converse.Core;

public sealed class SwitchboardObligation
{
    public Guid Id { get; set; }
    public string Source { get; set; } = "";
    public string SourceName { get; set; } = "";
    public Guid PromptID { get; set; }
    public string Kind { get; set; } = "request";
    public string State { get; set; } = "queued";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime? FinishedAt { get; set; }
    public DateTime? IntervenedAt { get; set; }
    public Guid? ReplyDeliveryID { get; set; }
    public string? GroupID { get; set; }
    public string? OriginHomeID { get; set; }
    public bool Terminal => State is "resolved" or "escalated" or "cancelled";
}
public sealed class SwitchboardExpectation
{
    public Guid Id { get; set; }
    public string Target { get; set; } = "";
    public bool Answered { get; set; }
}

public sealed partial class DeviceSyncService
{
    // Host updates/shutdown may close automatic work without erasing obligations.
    public Func<bool> CanSuperviseSwitchboard { get; set; } = () => true;
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, (DeviceQueueWatchReport Report, DateTime At)> _queueWatchReports = new();
    private readonly Dictionary<Guid, (long Revision, DateTime At)> _supervisionProgress = new();
    internal static string ReplyInstruction(Guid id, bool expected, Guid? inReplyTo) =>
        (inReplyTo is { } reply ? $"\n[Reply to request {reply}]" : "") +
        (expected ? $"\n[Reply expected · request {id}. Reply using tell to the sender with inReplyTo: \"{id}\". Answer, report a blocker, or explicitly decline.]" : "");

    internal void RecordSwitchboardIncoming(ChatSession target, string source, string name, Guid id, PendingPrompt prompt,
        bool expected, Guid? inReplyTo, string? group = null, string? home = null)
    {
        target.SwitchboardObligations.RemoveAll(item => item.Terminal && item.IntervenedAt is null);
        if (expected || inReplyTo is null) target.SwitchboardObligations.Add(new() { Kind = expected ? "request" : "delivery", Id = id, Source = source, SourceName = name, PromptID = prompt.Id, GroupID = group, OriginHomeID = home });
        var sent = target.SwitchboardExpectations.FirstOrDefault(item => item.Id == inReplyTo && !item.Answered && item.Target == source);
        if (sent is not null)
        {
            sent.Answered = true;
            target.SwitchboardObligations.Add(new() { Id = id, Source = source, SourceName = name, PromptID = prompt.Id, Kind = "reply", GroupID = group, OriginHomeID = home });
        }
    }
    private static void RecordSwitchboardSent(ChatSession source, string target, Guid id, bool expected, Guid? inReplyTo, bool remote)
    {
        if (expected)
        {
            source.SwitchboardExpectations.RemoveAll(item => item.Answered);
            source.SwitchboardExpectations.Add(new() { Id = id, Target = target });
        }
        if (source.SwitchboardObligations.FirstOrDefault(item => item.Id == inReplyTo && item.Kind == "request") is { } request)
        {
            request.State = remote ? "awaitingReceipt" : "resolved";
            request.ReplyDeliveryID = id; request.FinishedAt = DateTime.UtcNow;
        }
    }
    private void RecoverMutualSwitchboardQueues(DateTime now)
    {
        bool Eligible(ChatSession s) => s.MessagingEnabled && !s.QueuePaused && s.Requests.Count == 0 && !s.AnsweringRequest &&
            !s.Status.Contains("approval", StringComparison.OrdinalIgnoreCase) && !s.Status.Contains("sign in", StringComparison.OrdinalIgnoreCase) &&
            _supervisionProgress.TryGetValue(s.Id, out var p) && (now - p.At).TotalSeconds >= 120 &&
            (s.SwitchboardLastRecoveryAt is not { } last || (now - last).TotalSeconds >= 120);
        bool Queued(ChatSession s, SwitchboardObligation item) => item.State == "queued" && item.IntervenedAt is null &&
            (now - item.CreatedAt).TotalSeconds >= 120 && s.Pending.Any(p => p.Id == item.PromptID || p.ComponentIDs?.Contains(item.PromptID) == true);
        var advertised = _store.Sessions.Where(Eligible).SelectMany(s => s.SwitchboardObligations.Where(o => Queued(s, o))
            .Select(o => new DeviceQueueWatch { Target = new DeviceGlobalID(DeviceId, s.Id).ToString(), Source = o.Source, Delivery = o.Id })).ToList();
        foreach (var peer in _peers.Values.ToArray())
            if (peer.Hello is { } hello && !peer.ControlOnly && IsParticipantAllowed(hello.DeviceID, CurrentGroup?.Id) && hello.Capabilities.Contains("switchboard-supervision-v1"))
                _ = SendEnvelopeAsync(peer, new DeviceEnvelope { Kind = "participant.queue-watch", Payload = DeviceJson.Encode(new DeviceQueueWatchReport {
                    GroupID = CurrentGroup!.Id, Entries = advertised.Where(e => DeviceGlobalID.Parse(e.Source)?.Home == hello.DeviceID).Take(128).ToList() }) });
        foreach (var a in _store.Sessions.Where(Eligible).ToArray())
            foreach (var item in a.SwitchboardObligations.Where(o => Queued(a, o)).ToArray())
            {
                var local = new DeviceGlobalID(DeviceId, a.Id).ToString(); var remote = DeviceGlobalID.Parse(item.Source);
                if (remote is null || remote.Value.Home == DeviceId || string.CompareOrdinal(local, item.Source) >= 0 || PeerForHome(remote.Value.Home) is null ||
                    !_queueWatchReports.TryGetValue(remote.Value.Home, out var snapshot) || !IsParticipantAllowed(remote.Value.Home, snapshot.Report.GroupID) ||
                    (now - snapshot.At).TotalSeconds is < 0 or > 15 || !snapshot.Report.Entries.Any(e => e.Target == item.Source && e.Source == local)) continue;
                item.IntervenedAt = now; a.SwitchboardLastRecoveryAt = now;
                a.Messages.Add(new() { Role = "notice", Text = $"[Converse switchboard recovery] Mutual queued messages with {item.SourceName}. Injecting the existing message once." });
                _store.Save(); _store.InjectPending(a, a.Pending.First(p => p.Id == item.PromptID || p.ComponentIDs?.Contains(item.PromptID) == true).Id); break;
            }
        foreach (var a in _store.Sessions.OrderBy(s => s.Id.ToString()).ToArray().Where(Eligible))
            foreach (var item in a.SwitchboardObligations.Where(o => Queued(a, o)).ToArray())
            {
                var peer = DeviceGlobalID.Parse(item.Source);
                var b = peer?.Home == DeviceId ? _store.Sessions.FirstOrDefault(s => s.Id == peer.Value.Session) : null;
                if (b is null || string.CompareOrdinal(a.Id.ToString(), b.Id.ToString()) >= 0 || !Eligible(b)) continue;
                var other = b.SwitchboardObligations.FirstOrDefault(o => o.Source == new DeviceGlobalID(DeviceId, a.Id).ToString() && Queued(b, o));
                if (other is null) continue;
                item.IntervenedAt = now; other.IntervenedAt = now;
                a.SwitchboardLastRecoveryAt = now; b.SwitchboardLastRecoveryAt = now;
                a.Messages.Add(new() { Role = "notice", Text = $"[Converse switchboard recovery] Mutual queued messages with {b.Title}. Injecting the existing message once." });
                _store.Save(); _store.InjectPending(a, a.Pending.First(p => p.Id == item.PromptID || p.ComponentIDs?.Contains(item.PromptID) == true).Id); break;
            }
    }
    public void SuperviseSwitchboard(DateTime now)
    {
        if (!CanSuperviseSwitchboard()) return;
        foreach (var session in _store.Sessions.ToArray())
        {
            var revision = session.Messages.Sum(m => (long)m.Text.Length) + session.Messages.Count;
            if (!_supervisionProgress.TryGetValue(session.Id, out var progress) || progress.Revision != revision)
                _supervisionProgress[session.Id] = progress = (revision, now);
        }
        RecoverMutualSwitchboardQueues(now);
        foreach (var session in _store.Sessions.ToArray())
        {
            var progress = _supervisionProgress[session.Id];
            if (!session.MessagingEnabled || session.QueuePaused || session.Requests.Count > 0 || session.Status.Contains("approval", StringComparison.OrdinalIgnoreCase)) continue;
            foreach (var item in session.SwitchboardObligations.ToArray())
            {
                if (item.Terminal) continue;
                if (item.Kind == "delivery") {
                    if (!session.Pending.Any(p => p.Id == item.PromptID || p.ComponentIDs?.Contains(item.PromptID) == true)) { item.State = "cancelled"; _store.Save(); }
                    continue;
                }
                if (item.OriginHomeID is { } home)
                {
                    if (!IsParticipantAllowed(home, item.GroupID)) { item.State = "cancelled"; _store.Save(); continue; }
                    if (PeerForHome(home) is null) continue;
                }
                var queued = session.Pending.Any(p => p.Id == item.PromptID || p.ComponentIDs?.Contains(item.PromptID) == true);
                if (item.State == "queued" && !queued) { item.State = "cancelled"; _store.Save(); continue; }
                if (item.State == "submitted" && !session.Busy && item.FinishedAt is null) { item.FinishedAt = now; _store.Save(); }
                var grace = item.FinishedAt is { } finished && (now - finished).TotalSeconds >= 30;
                var quiet = !session.Busy || (now - progress.At).TotalSeconds >= 120;
                var waiting = session.SwitchboardExpectations.Any(e => !e.Answered && e.Target == item.Source);
                var remoteHome = DeviceGlobalID.Parse(item.Source)?.Home;
                var remotePairReady = remoteHome is not null && remoteHome != DeviceId && _queueWatchReports.TryGetValue(remoteHome, out var peerReport) &&
                    IsParticipantAllowed(remoteHome, peerReport.Report.GroupID) && (now - peerReport.At).TotalSeconds is >= 0 and <= 15 &&
                    peerReport.Report.Entries.Any(e => e.Target == item.Source && e.Source == new DeviceGlobalID(DeviceId, session.Id).ToString());
                var freshPeer = remoteHome is null || remoteHome == DeviceId ||
                    _queueWatchReports.TryGetValue(remoteHome, out var fresh) && (now - fresh.At).TotalSeconds is >= 0 and <= 15;
                var stuck = freshPeer && !remotePairReady && queued && (now - item.CreatedAt).TotalSeconds >= 120 && quiet && (item.Kind == "reply" || waiting);
                var cooled = session.SwitchboardLastRecoveryAt is not { } last || (now - last).TotalSeconds >= 120;
                if (item.IntervenedAt is null && cooled && (stuck || (item.State == "submitted" && grace && !session.Busy)))
                {
                    item.IntervenedAt = now; session.SwitchboardLastRecoveryAt = now;
                    if (!queued)
                    {
                        var prompt = new PendingPrompt { Autonomous = true, OriginGroupID = item.GroupID, OriginHomeID = item.OriginHomeID,
                            Text = $"[Converse switchboard recovery · request {item.Id}]\nYour turn finished without replying to {item.SourceName} ({item.Source}). Send an answer, blocker, or explicit decline using tell with inReplyTo: \"{item.Id}\". This is the only automatic reminder. Do not request a reply to this notice." };
                        item.PromptID = prompt.Id; item.State = "queued"; item.FinishedAt = null; session.Pending.Insert(0, prompt);
                    }
                    _store.Save(); _store.InjectPending(session, session.Pending.First(p => p.Id == item.PromptID || p.ComponentIDs?.Contains(item.PromptID) == true).Id);
                }
                else if ((item.IntervenedAt is { } intervention && (now - intervention).TotalSeconds >= 120 && (grace || (queued && quiet))) ||
                         (item.State is "awaitingReceipt" or "deliveryFailed" && grace))
                {
                    var state = item.State; item.State = "escalated";
                    var text = $"[Converse switchboard supervision · needs attention · {item.Id}]\n{session.Title} ↔ {item.SourceName}: reply unresolved, state {state}. One automatic recovery at most. Inspect the sessions and queues; this notice does not request a reply.";
                    session.Messages.Add(new() { Role = "notice", Text = text });
                    var alerts = new List<(ChatSession Session, Guid Prompt)>();
                    foreach (var watcher in _store.Sessions.Where(w => w.Id != session.Id && w.Agent is { } agent &&
                        (agent.Settings.Watched.Contains(new DeviceGlobalID(DeviceId, session.Id).ToString()) || agent.Settings.Watched.Contains(item.Source))).ToArray())
                    {
                        var prompt = new PendingPrompt { Text = text, Autonomous = true }; watcher.Pending.Add(prompt); alerts.Add((watcher, prompt.Id));
                    }
                    _store.Save();
                    foreach (var (watcher, prompt) in alerts.Where(a => !a.Session.QueuePaused && a.Session.Requests.Count == 0))
                    {
                        if (watcher.SwitchboardLastRecoveryAt is { } recent && (now - recent).TotalSeconds < 120) continue;
                        watcher.SwitchboardLastRecoveryAt = now; _store.Save(); _store.InjectPending(watcher, prompt);
                    }
                }
            }
        }
    }
}
