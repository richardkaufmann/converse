import AppKit
import CryptoKit
import WebKit

private let groupMapSentinel = "GROUP-MAP-SENTINEL-MESSAGE-BODY"

private func groupMapFixtureInput(now: Date) -> (GroupMapInput, ids: [String: UUID]) {
    let writer = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, reviewer = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    let agent = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!, muted = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!
    let home = "macA", remoteHome = "macB"
    var config = AgentConfig(); config.watchedSessions = [reviewer]
    func address(_ id: UUID) -> String { DeviceGlobalID(home: home, session: id).string }
    let remoteAlpha = DeviceGlobalID(home: remoteHome, session: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!).string
    let remoteAgent = DeviceGlobalID(home: remoteHome, session: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!).string
    let ask = UUID(), tell = UUID(), remoteAsk = UUID(), rejected = UUID(), pendingAsk = UUID(), plainTell = UUID()
    var delivered = SwitchboardObligation(id: tell, source: address(writer), sourceName: "Writer", promptID: UUID(), kind: "delivery", state: "completed", createdAt: now.addingTimeInterval(-90))
    delivered.finishedAt = now
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
    groupMapResourceSelfTests(check)
    groupMapPageSelfTests(check, now: now)
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
    func tell(_ phase: GroupMapTellPhase) -> GroupMapDeliveryState { GroupMapModel.state(of: GroupMapTellRecord(id: UUID(), phase: phase, source: "a", target: "b", kind: .tell, at: Date())).state }
    check(tell(.sent) == .sent && tell(.accepted) == .delivered && tell(.rejected) == .failed && tell(.unconfirmed) == .unknown, "Group map: plain remote tells follow only their transport evidence")

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
    check(delivery("rejected")?.state == .failed && delivery("pendingAsk")?.state == .sent && delivery("plainTell")?.state == .delivered, "Group map: remote outcomes come from their receipts")
    check(delivery("remoteAsk")?.createdAt == GroupMapModel.milliseconds(now) - 30_000, "Group map: pending age is measured from the recorded send time")
    let edge = graph.edges.first { $0.id == GroupMapModel.edgeID(address("writer"), alpha) }!
    check(edge.pending == 2 && edge.total == 4 && edge.oldestPendingAt == GroupMapModel.milliseconds(now) - 30_000 && edge.counts["failed"] == 1, "Group map: edge counts and oldest pending age aggregate correctly")

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
    var floodLayout = GroupMapLayout()
    check(GroupMapModel.build(flood, layout: &floodLayout).deliveries.count == GroupMapModel.maximumDeliveries, "Group map: deliveries stay bounded")

    guard let data = initial.flatMap(GroupMapModel.encode) else { check(false, "Group map: payload encodes"); return }
    let json = String(decoding: data, as: UTF8.self)
    check(!json.contains(groupMapSentinel), "Group map: fixture JSON carries no sentinel body")
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
    let measured = PerformanceCapture()
    measured.configure(folder: root.appendingPathComponent("perf"), enabled: true, sampleMainQueue: false)
    let feed = GroupMapFeed(store: store, service: service, minimumInterval: 0, heartbeatSeconds: nil, schedule: { _, work in pending.append(work) }, worker: { $0() }, main: { $0() }, performance: measured) { data, done in payloads.append(data); done() }
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
    feed.stop()
    try? store.closeSessionChecked(source)
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
    func pump(_ seconds: TimeInterval = 15, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return done()
    }
    page.load()
    guard pump(until: { page.isReady || !page.errors.isEmpty }) else { check(false, "Group map: the bundled page reports ready"); return }
    check(page.isReady && page.errors.isEmpty, "Group map: the bundled page loads without JavaScript or CSP errors " + page.errors.joined(separator: "; "))
    let (input, _) = groupMapFixtureInput(now: Date())
    let builder = GroupMapBuilder()
    guard let first = builder.build(input), let firstData = GroupMapModel.encode(first) else { check(false, "Group map: fixture builds"); return }
    var applied = false
    page.apply(firstData) { applied = true }
    check(pump(until: { applied }) && page.errors.isEmpty, "Group map: the page applies a full snapshot without errors " + page.errors.joined(separator: "; "))
    var changed = input
    changed.sessions[1].obligations[0].state = "failed"
    var appliedDiff = false
    if let diff = builder.build(changed), let data = GroupMapModel.encode(diff) { page.apply(data) { appliedDiff = true } }
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
