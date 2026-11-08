import AppKit
import CryptoKit
import Network
import WebKit

private let groupMapSentinel = "GROUP-MAP-SENTINEL-MESSAGE-BODY"

private func groupMapFixtureInput(now: Date) -> (GroupMapInput, ids: [String: UUID]) {
    let writer = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, reviewer = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    let agent = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!, muted = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!
    let home = "macA", remoteHome = "macB"
    // Private text the input legitimately holds and the page must never receive.
    var config = AgentConfig(); config.watchedSessions = [reviewer]; config.objective = groupMapSentinel
    func address(_ id: UUID) -> String { DeviceGlobalID(home: home, session: id).string }
    let remoteAlpha = DeviceGlobalID(home: remoteHome, session: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!).string
    let remoteAgent = DeviceGlobalID(home: remoteHome, session: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!).string
    let ask = UUID(), tell = UUID(), remoteAsk = UUID(), rejected = UUID(), pendingAsk = UUID(), plainTell = UUID()
    var delivered = SwitchboardObligation(id: tell, source: address(writer), sourceName: "Writer", promptID: UUID(), kind: "delivery", state: "completed", createdAt: now.addingTimeInterval(-90))
    delivered.finishedAt = now; delivered.groupID = groupMapSentinel; delivered.originHomeID = groupMapSentinel
    var answered = SwitchboardObligation(id: ask, source: address(writer), sourceName: "Writer", promptID: UUID(), kind: "request", state: "resolved", createdAt: now.addingTimeInterval(-120))
    answered.replyDeliveryID = UUID()
    let session = { (id: UUID, title: String, enabled: Bool, agent: AgentConfig?, obligations: [SwitchboardObligation], expectations: [SwitchboardExpectation]) in
        GroupMapInput.LocalSession(id: id, title: title, assistant: "Codex", busy: false, queued: 0, queuePaused: false, switchboardEnabled: enabled, taught: enabled, agent: agent, obligations: obligations, expectations: expectations, queuedPromptIDs: [])
    }
    let input = GroupMapInput(localDeviceID: home, localDeviceName: "Studio", groupName: "QA",
        sessions: [
            session(writer, "Writer", true, nil, [], [
                SwitchboardExpectation(id: remoteAsk, target: remoteAlpha, createdAt: now.addingTimeInterval(-30), homeAccepted: true),
                SwitchboardExpectation(id: rejected, target: remoteAlpha, answered: true, createdAt: now.addingTimeInterval(-40), homeAccepted: false),
                SwitchboardExpectation(id: pendingAsk, target: remoteAlpha, createdAt: now.addingTimeInterval(-3))
            ]),
            session(reviewer, "Reviewer", true, nil, [delivered, answered], []),
            session(agent, "Watcher", true, config, [], []),
            session(muted, "Quiet", false, nil, [], [])
        ],
        homes: [GroupMapInput.RemoteHome(deviceID: remoteHome, name: "Laptop", online: true, reachable: true, rows: [
            GroupMapInput.RemoteRow(globalID: remoteAlpha, title: "Remote alpha", assistant: "Claude", isAgent: false, busy: false, queued: 0, queuePaused: false, messagingEnabled: true),
            GroupMapInput.RemoteRow(globalID: remoteAgent, title: "Remote agent", assistant: "Agent", isAgent: true, busy: false, queued: 0, queuePaused: false, messagingEnabled: true)
        ]), GroupMapInput.RemoteHome(deviceID: "macC", name: "Old Mac", online: false, reachable: false, rows: [])],
        pendingTellIDs: [pendingAsk], remoteQueuedIDs: [],
        tells: [GroupMapTellRecord(id: plainTell, phase: .accepted, source: address(writer), target: remoteAlpha, kind: .tell, at: now.addingTimeInterval(-10))],
        now: now)
    return (input, ["writer": writer, "reviewer": reviewer, "agent": agent, "muted": muted, "ask": ask, "tell": tell, "remoteAsk": remoteAsk, "rejected": rejected, "pendingAsk": pendingAsk, "plainTell": plainTell])
}

func groupMapSelfTests(_ check: (Bool, String) -> Void) {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    groupMapStateSelfTests(check)
    groupMapGraphSelfTests(check, now: now)
    groupMapFeedSelfTests(check, now: now)
    groupMapEvidenceSelfTests(check)
    groupMapResourceSelfTests(check)
    groupMapPageSelfTests(check, now: now)
    groupMapReloadSelfTests(check)
    groupMapWindowSelfTests(check)
}

private func pump(_ seconds: TimeInterval = 15, until done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    return done()
}

private func groupMapStateSelfTests(_ check: (Bool, String) -> Void) {
    func obligation(_ state: String, kind: String = "request", finished: Bool = false, reply: Bool = false) -> SwitchboardObligation {
        var item = SwitchboardObligation(id: UUID(), source: "a", sourceName: "A", promptID: UUID(), kind: kind, state: state)
        if finished { item.finishedAt = Date() }
        if reply { item.replyDeliveryID = UUID() }
        return item
    }
    func state(_ item: SwitchboardObligation) -> GroupMapDeliveryState { GroupMapModel.state(of: item, queuedLocally: true).state }
    check(state(obligation("queued")) == .queued, "Group map: a queued obligation shows queued")
    check(state(obligation("submitted", kind: "delivery")) == .delivered && state(obligation("completed", kind: "delivery")) == .delivered, "Group map: a tell the recipient took up shows delivered")
    check(state(obligation("submitted")) == .awaitingAnswer && state(obligation("submitted", finished: true)) == .awaitingAnswer, "Group map: a request being worked on awaits its answer")
    check(state(obligation("resolved", reply: true)) == .answered, "Group map: a request answered via inReplyTo shows answered")
    check(state(obligation("resolved")) == .unknown, "Group map: resolved with no matching reply is unknown, not answered")
    check(state(obligation("awaitingReceipt", reply: true)) == .awaitingAnswer, "Group map: a reply awaiting its transport receipt is not yet an answer")
    check(["failed", "deliveryFailed", "escalated", "cancelled"].allSatisfy { state(obligation($0)) == .failed }, "Group map: failed, rejected, escalated and cancelled show failed")
    check(state(obligation("somethingNew")) == .unknown, "Group map: an unrecognized state is unknown")

    func expectation(answered: Bool = false, accepted: Bool? = nil, reply: Bool = false) -> SwitchboardExpectation {
        SwitchboardExpectation(id: UUID(), target: "t", answered: answered, createdAt: Date(), homeAccepted: accepted, replyDeliveryID: reply ? UUID() : nil)
    }
    func expected(_ item: SwitchboardExpectation, pending: Bool = false, remoteQueued: Bool = false) -> GroupMapDeliveryState {
        GroupMapModel.state(of: item, pendingTell: pending, remoteQueued: remoteQueued).state
    }
    check(expected(expectation(), pending: true) == .sent, "Group map: a tell awaiting home acceptance shows sent")
    check(expected(expectation(accepted: true)) == .awaitingAnswer, "Group map: a transport receipt alone is NOT an answer")
    check(expected(expectation(answered: true, accepted: true, reply: true)) == .answered, "Group map: only a reply matched by inReplyTo answers an ask")
    check(expected(expectation(answered: true, accepted: false)) == .failed, "Group map: a rejected ask shows failed even though it was closed")
    check(expected(expectation(answered: true)) == .unknown, "Group map: a closed legacy record without evidence is unknown")
    check(expected(expectation()) == .unknown, "Group map: a remote ask with no acceptance on record is unknown")
    check(expected(expectation(accepted: true), remoteQueued: true) == .queued, "Group map: an authenticated remote queue report shows queued")
    func tell(_ phase: GroupMapTellPhase, pending: Bool = false) -> GroupMapDeliveryState { GroupMapModel.state(of: GroupMapTellRecord(id: UUID(), phase: phase, source: "a", target: "b", kind: .tell, at: Date()), pendingTell: pending).state }
    check(tell(.sent, pending: true) == .sent && tell(.accepted) == .queued && tell(.rejected) == .failed && tell(.unconfirmed) == .unknown, "Group map: plain remote tells follow only their transport evidence")
    check(tell(.sent) == .unknown && !tell(.sent).pending, "Group map: a sent tell with no pending ID is unknown, not still in flight")
    check(tell(.accepted).pending && tell(.accepted) != .delivered, "Group map: a queued remote ack stays pending and never reads as delivered")

    // The real Switchboard path records evidence the model can read.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-group-map-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root)
    let entry = Entry(name: "Fixture", command: "false", directory: NSTemporaryDirectory(), engine: "codex")
    let asker = store.create(entry), responder = store.create(entry)
    asker.queuePaused = true; responder.queuePaused = true
    let request = UUID(), target = store.switchboardAddress(responder.id.uuidString), origin = store.switchboardAddress(asker.id.uuidString)
    store.switchboardSent(asker, to: target, id: request, replyExpected: true, inReplyTo: nil, remote: true)
    store.switchboardReceipt(asker, delivery: request, accepted: true)
    let afterReceipt = asker.switchboardExpectations.first { $0.id == request }!
    check(!afterReceipt.answered && afterReceipt.homeAccepted == true && afterReceipt.createdAt != nil && GroupMapModel.state(of: afterReceipt, pendingTell: false, remoteQueued: false).state == .awaitingAnswer, "Group map: the real transport receipt path leaves an ask awaiting its answer")
    let reply = UUID()
    store.switchboardReceived(asker, source: target, name: "Responder", id: reply, prompt: PendingPrompt(text: "reply", images: []), replyExpected: false, inReplyTo: request)
    let afterReply = asker.switchboardExpectations.first { $0.id == request }!
    check(afterReply.replyDeliveryID == reply && GroupMapModel.state(of: afterReply, pendingTell: false, remoteQueued: false).state == .answered, "Group map: the real inReplyTo path links the reply delivery")
    store.switchboardSent(asker, to: target, id: UUID(), replyExpected: true, inReplyTo: nil, remote: true)
    let refused = asker.switchboardExpectations.last!
    store.switchboardReceipt(asker, delivery: refused.id, accepted: false)
    let afterReject = asker.switchboardExpectations.first { $0.id == refused.id }!
    check(afterReject.answered && afterReject.homeAccepted == false && GroupMapModel.state(of: afterReject, pendingTell: false, remoteQueued: false).state == .failed, "Group map: a real rejection shows failed and keeps its existing answered behaviour")
    _ = origin
    let encoded = try? JSONEncoder().encode(afterReply)
    let legacy = Data(#"{"id":"\#(UUID().uuidString)","target":"t","answered":true}"#.utf8)
    let decodedLegacy = try? JSONDecoder().decode(SwitchboardExpectation.self, from: legacy)
    check(encoded != nil && decodedLegacy?.homeAccepted == nil && decodedLegacy?.createdAt == nil && decodedLegacy?.replyDeliveryID == nil, "Group map: older archives decode without the new evidence fields")
    for session in [asker, responder] { try? store.closeSessionChecked(session) }
}

private func groupMapGraphSelfTests(_ check: (Bool, String) -> Void, now: Date) {
    let (input, ids) = groupMapFixtureInput(now: now)
    var layout = GroupMapLayout()
    let graph = GroupMapModel.build(input, layout: &layout)
    func address(_ name: String) -> String { DeviceGlobalID(home: "macA", session: ids[name]!).string }
    func reach(_ from: String, _ to: String) -> GroupMapReach? {
        let id = GroupMapModel.edgeID(from, to)
        guard let edge = graph.edges.first(where: { $0.id == id }) else { return nil }
        return from == edge.a ? edge.ab : edge.ba
    }
    let alpha = DeviceGlobalID(home: "macB", session: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!).string
    let remoteAgent = DeviceGlobalID(home: "macB", session: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!).string
    check(graph.devices.count == 3 && graph.devices.first { $0.id == "macC" }?.online == false, "Group map: devices include an offline Group member")
    check(graph.nodes.count == 6 && graph.nodes.filter { $0.device == "macA" }.count == 4, "Group map: sessions and agents cluster by device")
    check(graph.nodes.first { $0.id == address("agent") }?.kind == "agent", "Group map: agents are marked")
    check(reach(address("writer"), address("reviewer")) == .can, "Group map: a taught local session can reach another local session")
    check(reach(address("muted"), address("writer")) == nil, "Group map: an untaught session has no outgoing permission")
    check(reach(address("writer"), address("muted")) == .can, "Group map: local delivery does not require the recipient to be taught, as the Switchboard allows")
    check(reach(address("agent"), address("reviewer")) == .can && reach(address("agent"), address("writer")) == nil, "Group map: an agent reaches only its selected sessions")
    check(reach(address("writer"), alpha) == .can && reach(alpha, address("writer")) == .can, "Group map: remote participants with messaging on can talk across the Group")
    check(reach(remoteAgent, address("writer")) == .unknown, "Group map: a remote agent's scope is unknown here")
    check(reach(alpha, address("muted")) == nil, "Group map: a remote sender cannot reach a local session with messaging off")
    check(reach(alpha, remoteAgent) == .unknown, "Group map: traffic between two other devices is unknown")
    var offlineInput = input; offlineInput.homes[0].reachable = false; offlineInput.homes[0].online = false
    var offlineLayout = GroupMapLayout()
    let offlineGraph = GroupMapModel.build(offlineInput, layout: &offlineLayout)
    let offlineEdge = offlineGraph.edges.first { $0.id == GroupMapModel.edgeID(address("writer"), alpha) }
    check((address("writer") == offlineEdge?.a ? offlineEdge?.ab : offlineEdge?.ba) == .offline, "Group map: an offline device's permission is shown as offline, not available")

    func delivery(_ name: String) -> GroupMapDelivery? { graph.deliveries.first { $0.id == ids[name]!.uuidString } }
    check(delivery("ask")?.state == .answered && delivery("tell")?.state == .delivered, "Group map: local deliveries use the recipient's record")
    check(delivery("remoteAsk")?.state == .awaitingAnswer && delivery("remoteAsk")?.recipient == "unknown", "Group map: a remote recipient's progress is reported as unknown")
    check(delivery("rejected")?.state == .failed && delivery("pendingAsk")?.state == .sent && delivery("plainTell")?.state == .queued, "Group map: remote outcomes come from their receipts")
    check(delivery("remoteAsk")?.createdAt == GroupMapModel.milliseconds(now) - 30_000, "Group map: pending age is measured from the recorded send time")
    let edge = graph.edges.first { $0.id == GroupMapModel.edgeID(address("writer"), alpha) }!
    check(edge.pending == 3 && edge.total == 4 && edge.oldestPendingAt == GroupMapModel.milliseconds(now) - 30_000 && edge.counts["failed"] == 1, "Group map: edge counts and oldest pending age aggregate correctly")

    // Stable identity and positions.
    var moving = input
    var stableLayout = GroupMapLayout()
    let first = GroupMapModel.build(moving, layout: &stableLayout)
    moving.sessions[1].obligations.append(SwitchboardObligation(id: UUID(), source: address("writer"), sourceName: "Writer", promptID: UUID()))
    moving.sessions[1].queued = 3; moving.sessions[0].busy = true
    moving.sessions.append(GroupMapInput.LocalSession(id: UUID(), title: "Newcomer", assistant: "Codex", busy: false, queued: 0, queuePaused: false, switchboardEnabled: true, taught: true, agent: nil, obligations: [], expectations: [], queuedPromptIDs: []))
    let later = GroupMapModel.build(moving, layout: &stableLayout)
    let earlier = Dictionary(uniqueKeysWithValues: first.nodes.map { ($0.id, $0) })
    check(later.nodes.filter { earlier[$0.id] != nil }.allSatisfy { earlier[$0.id]!.x == $0.x && earlier[$0.id]!.y == $0.y }, "Group map: nodes keep their positions across message traffic and new arrivals")
    check(first.devices.allSatisfy { d in later.devices.first { $0.id == d.id }.map { $0.x == d.x && $0.y == d.y } == true }, "Group map: device clusters do not move")

    // Diffs.
    var builder = GroupMapBuilder()
    let initial = builder.build(input)
    check(initial?.full == true && initial?.nodes.count == 6 && initial?.pulses.isEmpty == true, "Group map: the first payload is complete and animates no history")
    check(builder.build(input) == nil, "Group map: an unchanged snapshot sends nothing")
    var changed = input
    changed.sessions[1].obligations[0].state = "failed"
    let diff = builder.build(changed)
    check(diff?.full == false && diff?.nodes.isEmpty == true && diff?.deliveries.count == 1 && diff?.deliveries.first?.state == .failed && diff?.pulses.count == 1, "Group map: one message's change sends a one-message diff with one pulse")
    builder = GroupMapBuilder()
    _ = builder.build(input)
    var replied = input
    var open = SwitchboardObligation(id: UUID(), source: address("writer"), sourceName: "Writer", promptID: UUID(), kind: "request", state: "submitted")
    replied.sessions[1].obligations.append(open)
    let start = builder.build(replied)
    open.state = "resolved"; open.replyDeliveryID = UUID()
    replied.sessions[1].obligations[replied.sessions[1].obligations.count - 1] = open
    let answerDiff = builder.build(replied)
    check(start?.pulses.first?.to == address("reviewer") && answerDiff?.pulses.first?.from == address("reviewer") && answerDiff?.pulses.first?.to == address("writer"), "Group map: an answer animates back toward the asker")
    var restarted = input
    restarted.sessions.removeLast()
    let removal = builder.build(restarted)
    check(removal?.removedNodes == [address("muted")], "Group map: a closed session is removed by diff")

    // Bounds and privacy.
    var flood = input
    let sentinelPromptID = UUID()
    flood.sessions[0].queued = 1
    flood.sessions[1].obligations = (0..<(GroupMapModel.maximumDeliveries + 200)).map { offset in
        SwitchboardObligation(id: UUID(), source: address("writer"), sourceName: "Writer", promptID: sentinelPromptID, kind: "delivery", state: "completed", createdAt: now.addingTimeInterval(TimeInterval(-offset)))
    }
    let oldestPending = UUID()
    flood.sessions[1].obligations.append(SwitchboardObligation(id: oldestPending, source: address("writer"), sourceName: "Writer", promptID: UUID(), kind: "request", state: "queued", createdAt: now.addingTimeInterval(-86_400)))
    var floodLayout = GroupMapLayout()
    let flooded = GroupMapModel.build(flood, layout: &floodLayout)
    let floodPending = flooded.nodes.first { $0.id == address("reviewer") }
    check(flooded.deliveries.count == GroupMapModel.maximumDeliveries, "Group map: deliveries stay bounded")
    check(flooded.deliveries.first { $0.id == oldestPending.uuidString }?.state == .queued && (floodPending?.pendingIn ?? 0) >= 1 && floodPending?.oldestPendingAt == GroupMapModel.milliseconds(now) - 86_400_000, "Group map: the oldest pending item survives a flood of newer finished ones")

    check(input.sessions[2].agent?.objective == groupMapSentinel && input.sessions[1].obligations[0].groupID == groupMapSentinel, "Group map: the fixture really holds the sentinel")
    guard let data = initial.flatMap(GroupMapModel.encode) else { check(false, "Group map: payload encodes"); return }
    let json = String(decoding: data, as: UTF8.self)
    check(!json.contains(groupMapSentinel), "Group map: private fixture text never reaches the JSON payload")
}

private func groupMapFeedSelfTests(_ check: (Bool, String) -> Void, now: Date) {
    // Coalescing bound with a fake clock.
    var clock = now
    var scheduled: [(at: Date, work: () -> Void)] = []
    var runs = 0
    var coalescer: GroupMapCoalescer!
    coalescer = GroupMapCoalescer(minimumInterval: 0.25, now: { clock }, schedule: { delay, work in scheduled.append((clock.addingTimeInterval(delay), work)) }) { runs += 1; coalescer.finished() }
    func advance(to target: Date) {
        while let next = scheduled.enumerated().filter({ $0.element.at <= target }).min(by: { $0.element.at < $1.element.at }) {
            clock = max(clock, next.element.at); scheduled.remove(at: next.offset); next.element.work()
        }
        clock = target
    }
    for tick in 0..<1000 { coalescer.mark(); advance(to: now.addingTimeInterval(Double(tick) * 0.001)) }
    advance(to: now.addingTimeInterval(1))
    check(runs >= 3 && runs <= 5, "Group map: 1000 marks in one second coalesce to at most a few updates (\(runs))")
    let settled = runs
    advance(to: now.addingTimeInterval(5))
    check(runs == settled, "Group map: no build runs without a change")
    var blockedDone: (() -> Void)?
    var blockedRuns = 0
    let flow = GroupMapCoalescer(minimumInterval: 0, now: { clock }, schedule: { _, work in work() }) { blockedRuns += 1; blockedDone = {} }
    flow.mark(); flow.mark(); flow.mark()
    check(blockedRuns == 1 && blockedDone != nil, "Group map: no second build starts until the page finishes the last")
    flow.finished()
    check(blockedRuns == 2, "Group map: the held change builds once the page is ready")

    // Real observers, synchronous worker, and teardown.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-group-map-feed-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root), service = DeviceSyncService()
    store.switchboardService = service
    try? service.configureForTesting(folder: root.appendingPathComponent("device"))
    defer { service.suspendViewer() }
    let entry = Entry(name: "Fixture", command: "false", directory: NSTemporaryDirectory(), engine: "codex")
    let source = store.create(entry)
    source.title = "Feed session"; source.queuePaused = true
    var payloads: [Data] = []
    var pending: [() -> Void] = []
    var applyResult = true
    let measured = PerformanceCapture()
    measured.configure(folder: root.appendingPathComponent("perf"), enabled: true, sampleMainQueue: false)
    let feed = GroupMapFeed(store: store, service: service, minimumInterval: 0, heartbeatSeconds: nil, schedule: { _, work in pending.append(work) }, worker: { $0() }, main: { $0() }, performance: measured) { data, done in payloads.append(data); done(applyResult) }
    func drain() { while !pending.isEmpty { pending.removeFirst()() } }
    check(feed.observerCount == 0 && service.groupMapTellObserver == nil, "Group map: nothing is observed before the window opens")
    feed.start(); drain()
    check(feed.isRunning && feed.observerCount >= 12 && service.groupMapTellObserver != nil, "Group map: opening attaches observers")
    check(payloads.count == 1 && String(decoding: payloads[0], as: UTF8.self).contains("\"full\":true"), "Group map: opening sends one complete snapshot")
    let afterFirst = payloads.count
    source.messages.append(Message(role: "assistant", text: groupMapSentinel))
    drain()
    check(payloads.count == afterFirst, "Group map: transcript text changes do not rebuild the map")
    source.pending.append(PendingPrompt(text: groupMapSentinel, images: []))
    source.switchboardObligations.append(SwitchboardObligation(id: UUID(), source: "source-elsewhere", sourceName: "Elsewhere", promptID: source.pending[0].id))
    drain()
    check(payloads.count == afterFirst + 1, "Group map: a queue change produces one coalesced diff")
    check(payloads.allSatisfy { !String(decoding: $0, as: UTF8.self).contains(groupMapSentinel) }, "Group map: no message body enters the page payload, even with a sentinel in pending and transcript")
    let measuredOperations = Set(measured.eventsForTesting().map(\.operation))
    check(measuredOperations.isSuperset(of: [.groupMapCapture, .groupMapBuild]), "Group map: the running feed reports its capture and build to PerformanceCapture")

    service.groupMapTellObserver?(SwitchboardTellEvent(id: UUID(), phase: .sent, source: "a", target: "b", kind: .tell))
    let scheduledBeforeStop = pending
    let countBeforeStop = payloads.count
    feed.stop()
    scheduledBeforeStop.forEach { $0() }; pending.removeAll()
    source.pending.append(PendingPrompt(text: "after stop", images: []))
    source.title = "Renamed after stop"
    drain()
    check(!feed.isRunning && feed.observerCount == 0 && service.groupMapTellObserver == nil && pending.isEmpty && payloads.count == countBeforeStop, "Group map: teardown removes observers and stops all work")
    feed.start(); drain()
    check(payloads.count == countBeforeStop + 1 && String(decoding: payloads.last!, as: UTF8.self).contains("\"full\":true"), "Group map: reopening resends a complete snapshot")
    func lastPayloadIsFull() -> Bool { String(decoding: payloads.last ?? Data(), as: UTF8.self).contains("\"full\":true") }
    feed.resync(); drain()
    check(payloads.count == countBeforeStop + 2 && lastPayloadIsFull(), "Group map: a reloaded page gets a complete snapshot even when nothing changed")
    applyResult = false
    source.title = "Fails to apply"; drain()
    let afterFailure = payloads.count
    check(!lastPayloadIsFull(), "Group map: the failing update was an ordinary diff")
    applyResult = true
    source.title = "After the failure"; drain()
    check(payloads.count == afterFailure + 1 && lastPayloadIsFull(), "Group map: a failed apply is followed by a complete snapshot, not a diff against what never landed")
    source.title = "Back to normal"; drain()
    check(payloads.count == afterFailure + 2 && !lastPayloadIsFull(), "Group map: diffs resume once the page has caught up")
    feed.stop()
    try? store.closeSessionChecked(source)
}

/// The transport paths for real: sends and acks go through DeviceSyncService
/// against a fake trusted peer, and every state is read back through capture().
private func groupMapEvidenceSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-group-map-evidence-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root), service = DeviceSyncService()
    store.switchboardService = service; service.storeOverride = store
    defer { service.suspendViewer(); service.storeOverride = nil }
    guard (try? service.configureForTesting(folder: root.appendingPathComponent("device"))) != nil, let localHome = service.localDeviceID else { check(false, "Group map: evidence fixture starts"); return }
    let group = ConverseGroup(id: UUID().uuidString, name: "QA", creator: String(repeating: "a", count: 64))
    let peerHome = String(repeating: "b", count: 64), stranger = String(repeating: "c", count: 64), otherMember = String(repeating: "d", count: 64)
    service.currentGroup = group
    service.trusted = [peerHome, otherMember].map { TrustedDevice(deviceID: $0, name: "Peer", publicKey: Data(), pairedAt: Date(), groupID: group.id) }
    let remoteOn = UUID(), remoteOff = UUID(), remoteOnAddress = DeviceGlobalID(home: peerHome, session: remoteOn).string, remoteOffAddress = DeviceGlobalID(home: peerHome, session: remoteOff).string
    func row(_ id: UUID, messaging: Bool) -> DeviceSidebarRow {
        var value = DeviceSidebarRow(globalID: DeviceGlobalID(home: peerHome, session: id).string, sessionID: id, title: "Remote", assistant: "Claude", engine: "claude", model: "", effort: "", access: "", status: "Ready", busy: false, queued: 0, queuePaused: false)
        value.messagingEnabled = messaging
        return value
    }
    service.homes[peerHome] = RemoteHomeState(deviceID: peerHome, deviceName: "Peer", online: true, rows: [row(remoteOn, messaging: true), row(remoteOff, messaging: false)])
    let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), isInitiator: false, displayName: "Peer")
    peer.trustedReady = true; peer.hello = DeviceHello(deviceID: peerHome, deviceName: "Peer", converseVersion: "test")
    peer.hello?.capabilities += ["participant-control-v1", "switchboard-supervision-v1"]
    service.adoptPeerForTesting(peer)

    let entry = Entry(name: "Fixture", command: "false", directory: NSTemporaryDirectory(), engine: "codex")
    func session(_ title: String, messaging: Bool = true) -> Session {
        let value = store.create(entry)
        value.title = title; value.switchboardEnabled = messaging; value.queuePaused = true
        return value
    }
    let sender = session("Sender")
    var pending: [() -> Void] = []
    let feed = GroupMapFeed(store: store, service: service, minimumInterval: 0, heartbeatSeconds: nil, schedule: { _, work in pending.append(work) }, worker: { $0() }, main: { $0() }) { _, done in done(true) }
    func drain() { while !pending.isEmpty { pending.removeFirst()() } }
    func graph() -> GroupMapGraph { var layout = GroupMapLayout(); return GroupMapModel.build(feed.capture(), layout: &layout) }
    func shown(_ id: UUID) -> GroupMapDelivery? { graph().deliveries.first { $0.id == id.uuidString } }
    func send(_ id: UUID, from source: Session? = nil, replyExpected: Bool = false) -> String? {
        store.deliverSwitchboard(from: source ?? sender, to: remoteOnAddress, text: "Evidence", id: id, hop: 1, replyExpected: replyExpected)
    }
    func ack(_ id: UUID, _ outcome: String) {
        service.handleEnvelope(peer, DeviceEnvelope(kind: "participant.tell.ack", commandID: id, payload: try? JSONEncoder().encode(DeviceAckPayload(outcome: outcome, detail: "Test"))))
    }
    func address(_ value: Session) -> String { DeviceGlobalID(home: localHome, session: value.id).string }
    feed.start(); drain()

    // Finding 4: a remote "queued" ack is Queued and still pending.
    let tell = UUID()
    check(send(tell) == nil && shown(tell)?.state == .sent, "Group map: a real remote tell shows Sent while its ack is outstanding")
    ack(tell, "queued")
    check(shown(tell)?.state == .queued && (graph().nodes.first { $0.id == address(sender) }?.pendingOut ?? 0) >= 1, "Group map: a real queued ack shows Queued and stays in the pending count")
    let refused = UUID(), odd = UUID()
    _ = send(refused); _ = send(odd)
    ack(refused, "rejected"); ack(odd, "somethingNew")
    check(shown(refused)?.state == .failed && shown(odd)?.state == .unknown, "Group map: a rejected ack fails and an unrecognized outcome stays unknown")

    // Finding 1: evidence missed while the window was hidden.
    let missed = UUID()
    _ = send(missed)
    feed.stop()
    ack(missed, "queued")
    feed.start(); drain()
    let afterMissed = shown(missed)
    check(afterMissed?.state == .unknown && afterMissed?.detail.contains("did not see") == true, "Group map: an ack that arrived while stopped shows unknown, not Sent")
    // Finding 1: the confirmation timer outlives a closed source session.
    service.participantTellConfirmationSeconds = 0.05
    let closing = session("Closing"), orphan = UUID()
    _ = send(orphan, from: closing)
    service.participantTellConfirmationSeconds = 20
    check(shown(orphan)?.state == .sent, "Group map: the closing session's tell starts out Sent")
    try? store.closeSessionChecked(closing)
    _ = pump(5) { feed.capture().tells.contains { $0.id == orphan && $0.phase == .unconfirmed } }
    check(shown(orphan)?.state == .unknown && shown(orphan)?.detail.contains("did not confirm") == true, "Group map: a tell from a closed session still reaches unknown when its confirmation lapses")

    // Finding 3 and expectation retirement.
    let ask = UUID()
    _ = send(ask, replyExpected: true)
    ack(ask, "queued")
    check(!feed.capture().tells.contains { $0.id == ask } && shown(ask)?.state == .awaitingAnswer, "Group map: an ask stays out of the tell records and awaits its answer")
    let followUp = UUID()
    _ = service.sendParticipantTell(source: sender, target: remoteOnAddress, text: "Evidence", id: followUp, hop: 1, urgent: false, replyExpected: true, inReplyTo: UUID())
    check(!feed.capture().tells.contains { $0.id == followUp }, "Group map: a reply that also expects a reply has an expectation, so it stays out too")
    store.switchboardReceived(sender, source: remoteOnAddress, name: "Remote", id: UUID(), prompt: PendingPrompt(text: "Answer", images: []), replyExpected: false, inReplyTo: ask)
    check(shown(ask)?.state == .answered && shown(ask)?.kind == .ask, "Group map: the real inReplyTo path answers the remote ask")
    let retirement = GroupMapBuilder()
    _ = retirement.build(feed.capture())
    _ = send(UUID(), replyExpected: true)
    let retired = retirement.build(feed.capture())
    check(shown(ask) == nil && retired?.removedDeliveries.contains(ask.uuidString) == true && retired?.pulses.contains { $0.delivery == ask.uuidString } == false, "Group map: a retired Answered ask leaves the map instead of regressing to Delivered")

    // Finding 5: queue-report evidence must name the right home, recipient and sender.
    let reported = UUID()
    _ = send(reported, replyExpected: true)
    ack(reported, "queued")
    func report(from home: String = peerHome, group reportGroup: String? = nil, target: String? = nil, source: String? = nil, age: TimeInterval = 0) -> Bool {
        service.switchboardQueueReports = [home: (DeviceQueueWatchReport(groupID: reportGroup ?? group.id, entries: [DeviceQueueWatch(target: target ?? remoteOnAddress, source: source ?? address(sender), delivery: reported)]), Date().addingTimeInterval(-age))]
        return feed.capture().remoteQueuedIDs.contains(reported)
    }
    check(report() && shown(reported)?.state == .queued, "Group map: a fresh report from the expected member shows Queued")
    check(!report(from: otherMember), "Group map: another Group member cannot mark a delivery aimed at a different home")
    check(!report(from: stranger), "Group map: a home outside the Group is not evidence")
    check(!report(group: UUID().uuidString), "Group map: a report for another Group is not evidence")
    check(!report(target: remoteOffAddress), "Group map: a report naming a different recipient is not evidence")
    check(!report(source: remoteOffAddress), "Group map: a report naming a different sender is not evidence")
    check(!report(age: 30), "Group map: a stale queue report is not evidence")
    service.switchboardQueueReports = [:]

    // Permission edges against what delivery actually does.
    let other = session("Other"), quiet = session("Quiet", messaging: false), watcher = session("Watcher")
    var scope = AgentConfig(); scope.watchedSessions = [other.id]
    watcher.agent = scope
    drain()
    func reach(_ from: String, _ to: String) -> GroupMapReach? {
        guard let edge = graph().edges.first(where: { $0.id == GroupMapModel.edgeID(from, to) }) else { return nil }
        return from == edge.a ? edge.ab : edge.ba
    }
    func delivers(_ from: Session, _ to: String) -> Bool { store.deliverSwitchboard(from: from, to: to, text: "Reach check", id: UUID(), hop: 1) == nil }
    let outgoing: [(Session, String, GroupMapReach?, String)] = [
        (sender, address(other), .can, "a messaging session to a local one"),
        (sender, address(quiet), .can, "a local recipient with messaging off, which needs no opt-in"),
        (quiet, address(other), nil, "a session with messaging off"),
        (watcher, address(other), .can, "an agent to a selected session"),
        (watcher, address(sender), nil, "an agent outside its selection"),
        (sender, remoteOnAddress, .can, "a remote recipient with messaging on"),
        (sender, remoteOffAddress, nil, "a remote recipient with messaging off")
    ]
    for (source, target, expected, name) in outgoing {
        let predicted = reach(address(source), target)
        check(predicted == expected && (predicted == .can) == delivers(source, target), "Group map: reach matches real delivery for " + name)
    }
    service.homes[peerHome]?.online = false
    check(reach(address(sender), remoteOnAddress) == .offline && !delivers(sender, remoteOnAddress), "Group map: an offline edge really cannot deliver")
    service.homes[peerHome]?.online = true
    func incoming(to target: Session) -> Bool {
        let before = target.pending.count
        let payload = DeviceTellPayload(groupID: group.id, source: remoteOnAddress, sourceTitle: "Remote", target: address(target), text: "Incoming", hop: 1)
        service.handleEnvelope(peer, DeviceEnvelope(kind: "participant.tell", commandID: UUID(), payload: try? JSONEncoder().encode(payload)))
        return target.pending.count == before + 1
    }
    check(reach(remoteOnAddress, address(sender)) == .can && incoming(to: sender), "Group map: reach matches real delivery from a remote session")
    check(reach(remoteOnAddress, address(quiet)) == nil && !incoming(to: quiet), "Group map: reach matches real refusal when the local recipient has messaging off")
    feed.stop()
    for value in store.sessions { try? store.closeSessionChecked(value) }
}

private func groupMapResourceSelfTests(_ check: (Bool, String) -> Void) {
    guard let folder = GroupMapResources.folder else { check(false, "Group map: resources present"); return }
    let d3 = folder.appendingPathComponent(GroupMapResources.d3File)
    let digest = (try? Data(contentsOf: d3)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    check(digest == GroupMapResources.d3SHA256, "Group map: bundled D3 " + GroupMapResources.d3Version + " matches its recorded SHA-256")
    check((try? String(contentsOf: folder.appendingPathComponent("D3-LICENSE.txt"), encoding: .utf8))?.contains("Mike Bostock") == true, "Group map: D3's ISC license ships beside it")
    check(GroupMapResources.pages.keys.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent(String($0.dropFirst())).path) }, "Group map: every served page exists in the app bundle")
    let html = (try? String(contentsOf: folder.appendingPathComponent("group-map.html"), encoding: .utf8)) ?? ""
    check(html.contains("default-src 'none'") && html.contains("connect-src 'none'") && !html.contains("http://") && !html.contains("https://"), "Group map: the page declares a restrictive CSP and names no remote resource")
}

private func groupMapPageSelfTests(_ check: (Bool, String) -> Void, now: Date) {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1040, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let page = GroupMapPage(frame: NSRect(x: 0, y: 0, width: 1040, height: 720))
    window.contentView = page.webView
    window.orderBack(nil)
    defer { page.teardown(); window.orderOut(nil); window.close() }
    page.load()
    guard pump(until: { page.isReady || !page.errors.isEmpty }) else { check(false, "Group map: the bundled page reports ready"); return }
    check(page.isReady && page.errors.isEmpty, "Group map: the bundled page loads without JavaScript or CSP errors " + page.errors.joined(separator: "; "))
    let (input, _) = groupMapFixtureInput(now: Date())
    let builder = GroupMapBuilder()
    guard let first = builder.build(input), let firstData = GroupMapModel.encode(first) else { check(false, "Group map: fixture builds"); return }
    var applied = false
    page.apply(firstData) { _ in applied = true }
    check(pump(until: { applied }) && page.errors.isEmpty, "Group map: the page applies a full snapshot without errors " + page.errors.joined(separator: "; "))
    var changed = input
    changed.sessions[1].obligations[0].state = "failed"
    var appliedDiff = false
    if let diff = builder.build(changed), let data = GroupMapModel.encode(diff) { page.apply(data) { _ in appliedDiff = true } }
    check(pump(until: { appliedDiff }) && page.errors.isEmpty, "Group map: the page applies a diff without errors")
    func evaluate(_ script: String) -> Any? {
        var result: Any?, finished = false
        page.webView.evaluateJavaScript(script) { value, _ in result = value; finished = true }
        _ = pump(until: { finished })
        return result
    }
    let stats = evaluate("JSON.stringify(GroupMap.stats())") as? String ?? "{}"
    let parsed = (try? JSONSerialization.jsonObject(with: Data(stats.utf8))) as? [String: Any] ?? [:]
    check(parsed["nodes"] as? Int == 6 && parsed["devices"] as? Int == 3 && (parsed["deliveries"] as? Int ?? 0) > 0, "Group map: nodes, devices and deliveries render in the page")
    let resources = parsed["resources"] as? [String] ?? []
    check(Set(page.schemes.served) == Set(GroupMapResources.pages.keys) && page.schemes.refused.isEmpty && resources.allSatisfy { $0.hasPrefix(GroupMapResources.scheme + "://app/") }, "Group map: the page loads exactly its bundled files and requests nothing else; served " + page.schemes.served.joined(separator: ",") + " refused " + page.schemes.refused.joined(separator: ","))
    check((parsed["page"] as? String)?.hasPrefix(GroupMapResources.scheme + "://") == true, "Group map: the page stays on the bundled origin")
    _ = evaluate("location.href='https://example.com/'; 1")
    _ = pump(1) { !page.refusedNavigations.isEmpty }
    check(page.refusedNavigations.contains { $0.contains("example.com") } && page.webView.url?.scheme == GroupMapResources.scheme, "Group map: navigation away from the bundled page is refused")
    let errorsBeforeFetch = page.errors.count
    _ = evaluate("fetch('https://example.com/group-map-probe').catch(function () {}); 1")
    check(pump(5) { page.errors.dropFirst(errorsBeforeFetch).contains { $0.contains("CSP") } } && page.schemes.refused.isEmpty, "Group map: CSP blocks a network request the page tries to make")
    // Hostile names must stay inert everywhere they are drawn, including the detail panel.
    let hostile = "<img src=x onerror=\"window.__groupMapInjected=1\"><b>bold</b>"
    var marked = input
    marked.sessions[0].title = hostile; marked.localDeviceName = hostile
    var appliedMarked = false
    if let payload = GroupMapBuilder().build(marked), let data = GroupMapModel.encode(payload) { page.apply(data) { _ in appliedMarked = true } }
    let errorsBeforeMarkup = page.errors.count
    check(pump(until: { appliedMarked }), "Group map: a snapshot with markup in a title applies")
    _ = evaluate("[...document.querySelectorAll('g.node')].find((n) => n.getAttribute('aria-label').includes('<img')).dispatchEvent(new MouseEvent('click', { bubbles: true })); 1")
    let markupJSON = evaluate("JSON.stringify({ elements: document.querySelectorAll('#stage img, #stage b').length, injected: window.__groupMapInjected === 1, detail: document.getElementById('detail').textContent, device: document.querySelector('#devices text').textContent })") as? String ?? "{}"
    let markup = (try? JSONSerialization.jsonObject(with: Data(markupJSON.utf8))) as? [String: Any] ?? [:]
    check(markup["elements"] as? Int == 0 && markup["injected"] as? Bool == false, "Group map: markup in a title creates no elements and runs no script " + markupJSON)
    check((markup["detail"] as? String)?.contains(hostile) == true && (markup["device"] as? String)?.contains("<img") == true, "Group map: markup in a title is shown as literal text " + markupJSON)
    check(page.errors.count == errorsBeforeMarkup, "Group map: markup in a title raises no page errors " + page.errors.joined(separator: "; "))
    page.setPaused(true)
    _ = pump(1) { false }
    let paused = evaluate("document.body.classList.contains('paused') && GroupMap.stats().pulses === 0") as? Bool ?? false
    check(paused, "Group map: pausing stops the animation")
    page.setPaused(false)
    if let path = ProcessInfo.processInfo.environment["CONVERSE_GROUP_MAP_SNAPSHOT"] {
        var done = false
        _ = pump(1) { false }
        page.webView.takeSnapshot(with: nil) { image, _ in
            if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
            done = true
        }
        _ = pump { done }
    }
}

/// A real page and feed joined the way the window joins them.
private func groupMapReloadSelfTests(_ check: (Bool, String) -> Void) {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1040, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let page = GroupMapPage(frame: NSRect(x: 0, y: 0, width: 1040, height: 720))
    window.contentView = page.webView
    window.orderBack(nil)
    defer { page.teardown(); window.orderOut(nil); window.close() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-group-map-reload-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root), service = DeviceSyncService()
    store.switchboardService = service
    try? service.configureForTesting(folder: root.appendingPathComponent("device"))
    defer { service.suspendViewer() }
    let session = store.create(Entry(name: "Fixture", command: "false", directory: NSTemporaryDirectory(), engine: "codex"))
    session.queuePaused = true
    var lastFull = false
    let feed = GroupMapFeed(store: store, service: service, minimumInterval: 0, heartbeatSeconds: nil) { [weak page] data, done in
        lastFull = String(decoding: data, as: UTF8.self).contains("\"full\":true")
        guard let page else { done(false); return }
        page.apply(data, completion: done)
    }
    var visible = true
    let link = GroupMapLink(page: page, feed: feed) { visible }
    func evaluate(_ script: String) -> Any? {
        var result: Any?, finished = false
        page.webView.evaluateJavaScript(script) { value, _ in result = value; finished = true }
        _ = pump(5, until: { finished })
        return result
    }
    func nodes() -> Int { (evaluate("GroupMap.stats().nodes") as? Int) ?? -1 }
    page.load()
    check(pump { page.isReady && feed.isRunning && nodes() == 1 }, "Group map: a linked page gets its first snapshot once ready")
    _ = evaluate("window.__beforeReload = true; 1")
    lastFull = false
    page.webView.reload()
    check(pump { page.isReady && evaluate("window.__beforeReload === undefined") as? Bool == true && nodes() == 1 } && lastFull && feed.isRunning, "Group map: reloading the page restores it with a complete snapshot")
    check(page.errors.isEmpty, "Group map: reloading raises no page errors " + page.errors.joined(separator: "; "))
    page.webViewWebContentProcessDidTerminate(page.webView)
    check(!page.isReady && !feed.isRunning, "Group map: a terminated page stops the feed until it is back")
    lastFull = false
    check(pump { page.isReady && feed.isRunning && nodes() == 1 } && lastFull, "Group map: the page recovers from a WebContent crash with a complete snapshot")
    visible = false; link.sync()
    check(!feed.isRunning && evaluate("document.body.classList.contains('paused')") as? Bool == true, "Group map: hiding the window stops the feed and pauses the page")
    visible = true; lastFull = false; link.sync()
    check(pump { feed.isRunning && lastFull && nodes() == 1 }, "Group map: showing it again resumes with a complete snapshot")
    for _ in 0..<3 { page.webViewWebContentProcessDidTerminate(page.webView) }
    check(!feed.isRunning && page.errors.contains { $0.contains("keeps crashing") }, "Group map: a page that keeps crashing stops being reloaded")
    feed.stop()
    try? store.closeSessionChecked(session)
}

private func groupMapWindowSelfTests(_ check: (Bool, String) -> Void) {
    let name = "ConverseGroupMapTest-" + UUID().uuidString
    defer { NSWindow.removeFrame(usingName: name) }
    let unsaved = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: true)
    unsaved.isReleasedWhenClosed = false
    let centered = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: true)
    centered.isReleasedWhenClosed = false; centered.center()
    GroupMapWindows.place(unsaved, autosaveName: name)
    check(unsaved.frame.origin == centered.frame.origin, "Group map: a window with no remembered frame opens centered")
    unsaved.setFrameAutosaveName("")
    NSWindow.removeFrame(usingName: name)
    let saver = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: true)
    saver.isReleasedWhenClosed = false
    saver.setFrameOrigin(NSPoint(x: centered.frame.minX + 37, y: centered.frame.minY - 23))
    saver.saveFrame(usingName: name)
    let restored = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: true)
    restored.isReleasedWhenClosed = false
    GroupMapWindows.place(restored, autosaveName: name)
    check(restored.frame.origin == saver.frame.origin, "Group map: a remembered window position survives reopening")
    restored.setFrameAutosaveName("")
}
