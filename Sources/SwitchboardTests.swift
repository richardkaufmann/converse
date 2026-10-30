import Foundation
import AppKit
import Network

func switchboardSelfTests(_ check: (Bool, String) -> Void) {
    let store = Store.shared
    let entry = Entry(name: "Switchboard fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")
    let source = store.create(entry), target = store.create(entry)
    source.title = "Writer"; target.title = "Reviewer"; source.queuePaused = true; target.queuePaused = true
    source.draft = "source draft"; target.draft = "recipient draft"
    func block(_ command: String, to: String? = nil, text: String? = nil) -> String {
        var value = ["command": command]
        value["to"] = to; value["text"] = text
        return "```converse\n" + String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n```"
    }
    func reply(_ text: String, hop: Int = 0) {
        source.switchboardTurnStart = source.messages.count
        source.switchboardHop = hop
        source.messages.append(Message(role: "assistant", text: text, finalReply: text))
        store.processSwitchboard(source)
    }
    reply(block("tell", to: target.id.uuidString, text: "disabled"))
    check(target.pending.isEmpty, "Untaught sessions cannot emit switchboard messages")
    check(source.messages.last?.role == "notice" && source.messages.last?.text.contains("messaging is disabled") == true, "Untaught switchboard commands explain that nothing was sent")
    let noticeCount = source.messages.count
    store.processSwitchboard(source)
    check(source.messages.count == noticeCount, "Ignored untaught commands report once and cannot replay after teaching")
    reply("{\"command\":\"list-sessions\"}")
    check(source.messages.last?.text.contains("messaging is disabled") == true && source.pending.isEmpty, "Bare JSON commands from untaught sessions receive a notice without executing")
    store.teachSwitchboard(source)
    check(source.switchboardEnabled && source.pending.last?.text.contains("list-sessions") == true && source.pending.last?.text.contains("tell <name>") == true && source.draft == "source draft", "Teach enables messaging and queues dynamic lookup instructions without overwriting draft")
    source.pending = []
    reply("{\"command\":\"list-sessions\"}")
    check(source.pending.isEmpty && source.messages.last?.text.contains("fenced JSON block") == true, "Taught sessions get a formatting notice for bare command JSON")
    let textView = ConversationTextView(frame: .zero); textView.teachSession = { store.teachSwitchboard(source) }
    let menu = NSMenu(); textView.addTeachingItem(to: menu)
    check(menu.items.contains { $0.title == "Teach Session To Talk To Other Sessions" }, "Transcript right-click offers teaching even with no text or pane placement")
    reply("Example:\n" + block("tell", to: target.id.uuidString, text: "quoted"))
    check(target.pending.isEmpty, "JSON embedded in explanatory prose never sends")
    reply(block("list-sessions"))
    let directory = source.pending.last?.text ?? ""
    check(directory.contains(target.id.uuidString) && directory.contains("Reviewer") && source.queuePaused && !source.busy, "Directory lookup returns live IDs and names and respects paused input")
    target.title = "Renamed reviewer"
    check(store.switchboardDirectory(for: source).contains("Renamed reviewer"), "Directory lookup sees current session names")
    reply(block("tell", to: target.id.uuidString, text: "Quoted \"text\"\nSecond line"))
    check(target.pending.count == 1 && target.pending[0].text.hasSuffix("Quoted \"text\"\nSecond line") && target.pending[0].switchboardHop == 1 && target.draft == "recipient draft" && target.queuePaused, "Tell routes exact escaped text with sender provenance and preserves paused queue and draft")
    store.processSwitchboard(source)
    check(target.pending.count == 1, "Reprocessing a completed reply cannot deliver twice")
    let restored = Session(try! JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(source.saved)))
    check(restored.switchboardEnabled && restored.switchboardHandled == source.switchboardHandled, "Messaging opt-in and handled reply IDs survive persistence")
    let recipient = Session(try! JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(target.saved)))
    check(recipient.pending.first?.switchboardHop == 1 && recipient.queuePaused, "Received message and hop budget survive restart paused")
    reply(block("tell", to: target.id.uuidString, text: "past old limit"), hop: 8)
    check(target.pending.last?.switchboardHop == 9, "Switchboard continues beyond the old eight-hop limit")
    reply(block("tell", to: target.id.uuidString, text: "last permitted delivery"), hop: 99)
    check(target.pending.last?.switchboardHop == 100 && target.pending.last?.text.contains("hop 100/100]") == true, "Switchboard delivers and labels the hundredth hop")
    let count = target.pending.count
    reply(block("tell", to: target.id.uuidString, text: "loop"), hop: 100)
    let directoryCount = source.pending.count
    reply(block("list-sessions"), hop: 100)
    check(source.pending.count == directoryCount, "Directory responses also stop at one hundred hops")
    reply(block("tell", to: source.id.uuidString, text: "self"))
    reply(block("tell", to: UUID().uuidString, text: "closed"))
    reply(block("tell", to: target.id.uuidString, text: ""))
    check(target.pending.count == count, "Hop exhaustion, self-addressing, missing targets and empty messages never deliver")
    reply(block("tell", to: target.id.uuidString, text: String(repeating: "x", count: 32769)))
    check(target.pending.count == count, "Oversized messages are rejected")
    source.switchboardTurnStart = source.messages.count
    source.messages.append(Message(role: "assistant", text: block("tell", to: target.id.uuidString, text: "failed turn")))
    store.finishQueue(source, success: false)
    check(target.pending.count == count, "Failed turns never dispatch switchboard commands")
    source.switchboardEnabled = false
    reply(block("tell", to: target.id.uuidString, text: "disabled again"))
    check(target.pending.count == count, "Disabling messaging takes effect immediately")
    store.sessions.removeAll { $0.id == source.id || $0.id == target.id }; store.save()
}

// Real Noise/TCP group tell: neither home grants a display lease.
func groupSwitchboardSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-group-tell-" + UUID().uuidString)
    let a = DeviceSyncService(), b = DeviceSyncService()
    defer { a.suspendViewer(); b.suspendViewer(); a.storeOverride = nil; b.storeOverride = nil; try? FileManager.default.removeItem(at: root) }
    func pump(_ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return done()
    }
    do {
        try a.configureForTesting(folder: root.appendingPathComponent("A")); try a.enableGroupsForTesting()
        try b.configureForTesting(folder: root.appendingPathComponent("B")); try b.enableGroupsForTesting()
        let sa = Store(folder: root.appendingPathComponent("A")), sb = Store(folder: root.appendingPathComponent("B"))
        sa.switchboardService = a; sb.switchboardService = b; a.storeOverride = sa; b.storeOverride = sb
        let entry = Entry(name: "Fixture", command: "false", directory: NSTemporaryDirectory(), engine: "codex")
        let source = sa.create(entry), target = sb.create(entry)
        source.title = "Group sender"; target.title = "Group receiver"; target.draft = "Unsent human draft"
        source.switchboardEnabled = true; target.switchboardEnabled = true; source.queuePaused = true; target.queuePaused = true
        try a.startNetworkForTesting(); try b.startNetworkForTesting()
        check(pump { a.testingPort != nil && b.testingPort != nil }, "Group tell listeners start in isolated stores")
        a.createGroup(name: "Tell QA")
        b.joinGroupByAddress(host: "127.0.0.1", port: Int(a.testingPort!))
        guard pump({ a.groupRequests.first != nil && b.pairingPrompt != nil }) else { check(false, "Group tell join reaches review"); return }
        a.reviewGroupRequest(a.groupRequests[0]); a.approveGroupReview(); b.confirmPairing()
        let aid = a.identity!.deviceID, bid = b.identity!.deviceID
        guard pump({ a.homes[bid]?.rows.contains(where: { $0.sessionID == target.id }) == true && b.homes[aid]?.online == true }) else { check(false, "Group tell homes exchange directory metadata"); return }
        let gid = DeviceGlobalID(home: bid, session: target.id).string
        let directory = sa.switchboardDirectory(for: source)
        check(directory.contains(gid) && directory.contains("Group receiver") && directory.contains("homeDeviceName"), "list-sessions includes same-group remote participants and their homes")
        let delivery = UUID()
        check(sa.deliverSwitchboard(from: source, to: gid, text: "Cross-device hello", id: delivery, hop: 1) == nil && pump { target.pending.count == 1 && source.messages.contains(where: { $0.text.contains("Persisted on") }) }, "Group tell queues on its authenticated home and acknowledges persisted acceptance")
        check(a.remoteLeases.isEmpty && b.remoteLeases.isEmpty && target.draft == "Unsent human draft" && target.queuePaused, "Cross-device tells need no display lease and preserve human drafts and paused queues")
        _ = sa.deliverSwitchboard(from: source, to: gid, text: "Cross-device hello", id: delivery, hop: 1)
        _ = pump { source.messages.filter { $0.text.contains("Previously recorded") }.count == 1 }
        check(target.pending.count == 1 && source.messages.contains { $0.text.hasPrefix("Switchboard: queued → Group receiver") && $0.text.contains(delivery.uuidString) && $0.text.contains("Previously recorded") }, "Repeated remote delivery IDs cannot queue the same message twice")
        let reload = Store(folder: root.appendingPathComponent("B"))
        check(reload.groupTellReceipts.contains { $0.id == delivery } && reload.sessions.first(where: { $0.id == target.id })?.pending.count == 1, "Remote receipt and recipient queue survive one atomic archive reload")
        let tracked = UUID()
        check(sa.deliverSwitchboard(from: source, to: gid, text: "Tracked remote question", id: tracked, hop: 1, replyExpected: true) == nil && pump { target.switchboardObligations.contains { $0.id == tracked } }, "Remote supervised request is recorded on its authenticated receiving home")
        let replyID = UUID(), sourceGlobal = DeviceGlobalID(home: aid, session: source.id).string
        check(sb.deliverSwitchboard(from: target, to: sourceGlobal, text: "Remote answer", id: replyID, hop: 2, inReplyTo: tracked) == nil && pump { target.switchboardObligations.first(where: { $0.id == tracked })?.state == "resolved" && source.switchboardExpectations.first(where: { $0.id == tracked })?.answered == true }, "Remote correlated reply closes only after a persisted home receipt")
        target.pending.removeAll { $0.text.contains("Tracked remote question") }
        source.pending.removeAll { $0.text.contains("Remote answer") }
        func request(_ action: String, target: String? = nil, title: String? = nil, settings: DeviceAgentSettings? = nil, id: UUID? = nil) -> DeviceParticipantResponse? {
            var response: DeviceParticipantResponse?
            Task { @MainActor in response = await a.requestParticipant(home: bid, action: action, target: target, title: title, settings: settings, id: id) }
            _ = pump { response != nil }
            return response
        }
        let creationID = UUID(), initialCount = sb.sessions.count
        let created = request("agent.create", title: "Remote steward", id: creationID)
        let repeated = request("agent.create", title: "Remote steward", id: creationID)
        check(created?.outcome == "completed" && repeated?.target == created?.target && sb.sessions.count == initialCount + 1, "Remote agent creation and retries produce exactly one paused agent on the chosen home")
        guard let agentID = created?.target, let agentUUID = DeviceGlobalID(agentID)?.session, let agent = sb.sessions.first(where: { $0.id == agentUUID }) else { check(false, "Remote-created agent has a stable home identity"); return }
        check(agent.agent?.enabled == false && agent.agent?.watchedSessions.isEmpty == true, "Remote creation grants no transcript scope and starts no paid work")
        let reloadedIntents = DeviceSyncService(); try reloadedIntents.configureForTesting(folder: root.appendingPathComponent("A"))
        check(reloadedIntents.participantIntents.contains { $0.id == creationID && $0.response?.target == agentID }, "Outgoing creation identity and result survive a client restart without automatic replay")
        var settings = agent.agent!.wire(home: bid)
        settings.watched = [DeviceGlobalID(home: aid, session: source.id).string, gid]
        settings.turnLimit = 3; settings.enabled = false
        let configured = request("agent.configure", target: agentID, settings: settings)
        check(configured?.outcome == "completed" && Set(agent.agent?.watchedParticipants ?? []) == Set(settings.watched), "Group devices configure an agent's allowed participants and budget on its home (" + (configured?.detail ?? "no response") + ")")
        let pendingInspection = request("inspect", target: gid)
        check(pendingInspection?.evidence?.messages.contains { $0.text.contains("Cross-device hello") } == false, "Queued incoming traffic is not duplicated in submitted history or agent evidence")
        // Advance this paused fixture through the submission boundary without
        // invoking a real provider; inspection should then expose the prompt.
        let submitted = target.pending.removeFirst()
        target.messages.append(Message(role: "user", text: submitted.text))
        let inspection = request("inspect", target: gid)
        check(inspection?.evidence?.globalID == gid && inspection?.evidence?.messages.contains { $0.text.contains("Cross-device hello") } == true && inspection?.evidence?.messages.contains { $0.text.contains("Unsent human draft") } == false && a.remoteLeases.isEmpty, "Agent evidence snapshots include allowed submitted history without drafts or a display lease")
        target.pending.append(submitted) // Restore the reciprocal-queue fixture for the later recovery check.
        settings.watched = [DeviceGlobalID(home: String(repeating: "f", count: 64), session: source.id).string]
        check(request("agent.configure", target: agentID, settings: settings)?.outcome == "rejected" && agent.agent?.turnLimit == 3, "Remote agent configuration refuses targets outside the current group")
        agent.queuePaused = true
        let runID = UUID()
        _ = request("agent.run", target: agentID, id: runID); _ = request("agent.run", target: agentID, id: runID)
        check(agent.pending.count == 1 && agent.agent?.turnLimit == 3 && agent.pending.first?.agentRunReserved == true, "Remote Run once persists an activation reservation and deduplicates repeated requests")
        let before = target.pending.count
        target.switchboardEnabled = false
        _ = sa.deliverSwitchboard(from: source, to: gid, text: "Disabled after discovery", id: UUID(), hop: 1)
        check(pump { source.messages.contains { $0.text.contains("Target is closed or session messaging is disabled") } } && target.pending.count == before, "Target home rechecks messaging permission after a stale directory lookup")
        target.switchboardEnabled = true
        let fake = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), isInitiator: false, displayName: "Spoof")
        fake.trustedReady = true; fake.hello = DeviceHello(deviceID: aid, deviceName: "A", converseVersion: "test"); fake.hello?.capabilities.append("participant-control-v1")
        let spoof = DeviceTellPayload(groupID: b.currentGroup!.id, source: DeviceGlobalID(home: String(repeating: "f", count: 64), session: source.id).string, sourceTitle: "Spoof", target: gid, text: "No", hop: 1)
        b.handleEnvelope(fake, DeviceEnvelope(kind: "participant.tell", commandID: UUID(), payload: try JSONEncoder().encode(spoof)))
        check(target.pending.count == before, "Authenticated peer cannot forge another home's switchboard sender identity")
        // Ordinary tells, no replyExpected, over the real authenticated transport.
        _ = sb.deliverSwitchboard(from: target, to: sourceGlobal, text: "Mutual remote queue", id: UUID(), hop: 1)
        check(pump { source.pending.contains { $0.text.contains("Mutual remote queue") } }, "Mutual-queue fixture receives an ordinary remote tell")
        let recoveryNow = Date()
        for (store, session) in [(sa, source), (sb, target)] {
            session.busy = true; session.queuePaused = false
            session.switchboardProgress = (session.messagesRevision, recoveryNow.addingTimeInterval(-130))
            for index in session.switchboardObligations.indices { session.switchboardObligations[index].createdAt = recoveryNow.addingTimeInterval(-130) }
            store.recoverMutualSwitchboardQueues(now: recoveryNow)
        }
        check(pump { a.switchboardQueueReports[bid] != nil && b.switchboardQueueReports[aid] != nil }, "Authenticated homes exchange bounded queue identities without prompt content")
        sa.recoverMutualSwitchboardQueues(now: Date()); sb.recoverMutualSwitchboardQueues(now: Date())
        check(source.interrupted != target.interrupted, "Cross-home reciprocal queues elect exactly one home to inject")
        source.interrupted = false; target.interrupted = false
        sa.recoverMutualSwitchboardQueues(now: Date()); sb.recoverMutualSwitchboardQueues(now: Date())
        check(!source.interrupted && !target.interrupted, "Cross-home mutual recovery does not interrupt the other side on another scan")
        source.busy = false; target.busy = false; source.queuePaused = true; target.queuePaused = true
        source.pending.removeAll { $0.text.contains("Mutual remote queue") }
        target.pending.append(PendingPrompt(text: "Additional local queue item", images: []))
        target.busy = true
        _ = sb.injectPending(target)
        check(target.pending.first?.groupOrigins.contains(where: { $0.home == aid }) == true, "Inject all retains the origin of every contributing group message")
        target.busy = false; target.queuePaused = true
        let disposable = sb.create(target.entry)
        disposable.title = "Close fixture"; disposable.draft = "Recover my draft"; sb.save()
        let closeGID = DeviceGlobalID(home: bid, session: disposable.id).string
        check(pump { a.homes[bid]?.rows.contains { $0.globalID == closeGID } == true }, "Remote close fixture appears in the group directory")
        let closeID = UUID()
        let closed = request("session.close", target: closeGID, id: closeID)
        let replay = request("session.close", target: closeGID, id: closeID)
        let closeReload = Store(folder: root.appendingPathComponent("B"))
        let backup = root.appendingPathComponent("B/Deleted Sessions/" + disposable.id.uuidString + ".json")
        check(closed?.outcome == "completed" && replay?.outcome == closed?.outcome && replay?.target == closed?.target && !sb.sessions.contains { $0.id == disposable.id } && closeReload.participantReceipts.filter { $0.id == closeID }.count == 1 && (try? String(contentsOf: backup, encoding: .utf8))?.contains("Recover my draft") == true,
              "Remote close without a lease saves recovery data and persists one replayable deletion receipt")
        check(pump { a.homes[bid]?.rows.contains { $0.globalID == closeGID } == false }, "Remote close promptly removes the group directory row")
        b.leaveGroup(); sb.runNext(target)
        check(target.pending.count == 1 && target.pending[0].text == "Additional local queue item" && target.draft == "Unsent human draft" && target.messages.contains { $0.text.contains("discarded because") }, "Leaving a group removes stale queued tells while preserving combined local input and the human draft")
        check(!sb.switchboardDirectory(for: target).contains("Group sender"), "Ungrouped directory hides remote sessions")
        check(sa.deliverSwitchboard(from: source, to: DeviceGlobalID(home: String(repeating: "e", count: 64), session: target.id).string, text: "Outside", id: UUID(), hop: 1) != nil, "Tells to an unknown or other-group home fail visibly without queuing")
    } catch { check(false, "Group switchboard integration: " + error.localizedDescription) }
}

func switchboardSupervisionSelfTests(_ check: (Bool, String) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("supervision-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = Store(folder: folder)
    let entry = Entry(name: "Fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")
    let sender = store.create(entry), receiver = store.create(entry), watcher = store.create(entry)
    sender.switchboardEnabled = true; receiver.switchboardEnabled = true
    sender.queuePaused = true; receiver.queuePaused = true; watcher.queuePaused = true
    receiver.agent = AgentConfig(watchedSessions: [sender.id]); watcher.agent = AgentConfig(watchedSessions: [receiver.id])
    var starts = 0; store.startAgentRun = { _, _ in starts += 1 }
    let id = UUID(), now = Date()
    check(store.deliverSwitchboard(from: sender, to: receiver.id.uuidString, text: "Review this change", id: id, hop: 1, replyExpected: true) == nil,
          "Tracked tell registers an explicit reply obligation")
    // Exercise the actual final-reply command path on separate paused sessions.
    let asker = store.create(entry), answerer = store.create(entry)
    asker.switchboardEnabled = true; answerer.switchboardEnabled = true
    asker.queuePaused = true; answerer.queuePaused = true
    func command(_ action: String) {
        let body: [String: Any] = ["command": action, "to": answerer.id.uuidString, "text": "Question", "replyExpected": false]
        let text = "```converse\n" + String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self) + "\n```"
        asker.switchboardTurnStart = asker.messages.count
        asker.messages.append(Message(role: "assistant", text: text, finalReply: text)); store.processSwitchboard(asker)
    }
    command("tell")
    check(asker.switchboardExpectations.isEmpty && answerer.pending.count == 1, "Plain tell delivers without requesting a receipt turn")
    command("ask")
    check(asker.switchboardExpectations.count == 1 && answerer.pending.count == 2 && answerer.pending.last!.text.contains("Reply expected"), "Ask command always requests a correlated reply, even with conflicting false flag")
    check(!asker.switchboardExpectations[0].answered, "Delivery acceptance does not answer an ask")
    check(store.localContext(asker, directory: NSTemporaryDirectory()).contains("one-way tell"), "Existing enabled sessions receive ask/tell policy on their next turn")
    let original = receiver.pending[0]
    check(receiver.switchboardObligations.first?.id == id && original.text.contains("inReplyTo") && sender.switchboardExpectations.first?.id == id,
          "Request ID and reply instructions persist with the original queue item")
    store.superviseSwitchboard(now: now.addingTimeInterval(1000))
    check(starts == 0 && receiver.pending.count == 1 && receiver.switchboardObligations[0].intervenedAt == nil, "Supervision never resumes a human-paused queue")
    receiver.pending = []; store.switchboardStarted(receiver, prompt: original); store.switchboardTurnFinished(receiver, now: now)
    receiver.queuePaused = false
    store.superviseSwitchboard(now: now.addingTimeInterval(29))
    check(starts == 0, "Missing reply gets a grace period after turn completion")
    store.superviseSwitchboard(now: now.addingTimeInterval(31))
    check(starts == 1 && receiver.switchboardObligations[0].intervenedAt != nil && receiver.draft.isEmpty,
          "Missing reply receives exactly one corrective turn without changing the draft")
    receiver.busy = false; store.switchboardTurnFinished(receiver, now: now.addingTimeInterval(32))
    store.superviseSwitchboard(now: now.addingTimeInterval(160))
    store.superviseSwitchboard(now: now.addingTimeInterval(1000))
    check(starts == 1 && watcher.pending.count == 1 && watcher.queuePaused && receiver.switchboardObligations[0].state == "escalated",
          "Failed correction escalates once to watching agents and preserves their pauses")
    let reload = Store(folder: folder)
    check(reload.sessions.first(where: { $0.id == receiver.id })?.switchboardObligations.first?.intervenedAt != nil,
          "Restart preserves the consumed recovery allowance")
    check(store.deliverSwitchboard(from: receiver, to: sender.id.uuidString, text: "Reviewed; here is the blocker", id: UUID(), hop: 2, inReplyTo: id) == nil && sender.switchboardExpectations[0].answered,
          "A correctly attributed correlated reply closes the request even after escalation")
    check(store.deliverSwitchboard(from: receiver, to: sender.id.uuidString, text: "Wrong request", id: UUID(), hop: 2, inReplyTo: UUID()) != nil,
          "Unrelated reply IDs cannot satisfy an obligation")
    let a = store.create(entry), b = store.create(entry)
    a.switchboardEnabled = true; b.switchboardEnabled = true
    a.queuePaused = true; b.queuePaused = true
    a.draft = "keep A"; b.draft = "keep B"
    _ = store.deliverSwitchboard(from: a, to: b.id.uuidString, text: "Waiting for your review", id: UUID(), hop: 1)
    _ = store.deliverSwitchboard(from: b, to: a.id.uuidString, text: "Waiting for your answer", id: UUID(), hop: 1)
    let mutualNow = Date()
    a.switchboardProgress = (a.messagesRevision, mutualNow); b.switchboardProgress = (b.messagesRevision, mutualNow)
    a.busy = true; b.busy = true
    store.recoverMutualSwitchboardQueues(now: mutualNow.addingTimeInterval(121))
    check(!a.interrupted && !b.interrupted, "Mutual queued tells never override human pauses")
    a.queuePaused = false; b.queuePaused = false
    store.recoverMutualSwitchboardQueues(now: mutualNow.addingTimeInterval(119))
    check(!a.interrupted && !b.interrupted, "Mutual queue recovery waits for a quiet period")
    store.recoverMutualSwitchboardQueues(now: mutualNow.addingTimeInterval(121))
    check(a.interrupted != b.interrupted && a.pending.count == 1 && b.pending.count == 1 && a.draft == "keep A" && b.draft == "keep B",
          "Reciprocal ordinary tells inject exactly one existing prompt and preserve both drafts")
    a.interrupted = false; b.interrupted = false
    store.recoverMutualSwitchboardQueues(now: mutualNow.addingTimeInterval(1000))
    check(!a.interrupted && !b.interrupted, "Mutual queue intervention is not repeated on later scans")
    let mutualReload = Store(folder: folder)
    check(mutualReload.sessions.filter { $0.id == a.id || $0.id == b.id }.allSatisfy { $0.switchboardObligations.first?.intervenedAt != nil },
          "Both sides of mutual recovery are durably marked before interruption")
    a.busy = false; b.busy = false; a.queuePaused = true; b.queuePaused = true
    let hoverText = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    let hoverScroll = NSScrollView(frame: hoverText.frame)
    let ruler = MessageNumberRuler(scroll: hoverScroll, text: hoverText)
    check(ruler.responds(to: NSSelectorFromString("view:stringForToolTip:point:userData:")),
          "Message timestamp ruler exposes the native AppKit tooltip callback")
    let commandText = "```converse\n{\"command\":\"ask\",\"to\":\"" + sender.id.uuidString + "\",\"text\":\"Review\"}\n```"
    check(TranscriptStyle.trafficSummary(commandText, resolveName: { _ in "MuseConverse" }) == "Ask to MuseConverse · Review", "Outgoing command resolves destination name without claiming delivery")
    check(TranscriptStyle.trafficSummary(commandText) == "Ask to Unavailable session · Review", "Unresolved session IDs never leak into compact labels")
    check(TranscriptStyle.trafficSummary("Switchboard: queued → Muse [id] · delivery [ask]\nReview") == "Queued ask to Muse · Review", "Accepted ask summary names destination and direction")
    check(TranscriptStyle.trafficSummary("Switchboard: rejected → Muse [id] · delivery [tell]\nReview") == "Rejected tell to Muse · Review", "Rejected messages never render as sent")
    check(TranscriptStyle.trafficSummary("[Converse message from Muse · session id]\nReview\n[Reply expected]", queued: true)?.hasPrefix("Queued ask from Muse") == true, "Receiver queue identifies source and ask kind")
    let summary = TranscriptStyle.trafficSummary("[Converse message from MuseConverse · session abc · delivery xyz · hop 1/100]\nPlease review\nsecond line")
    check(summary == "Received tell from MuseConverse · Please review second line" && summary?.contains("\n") == false,
          "Traffic summary retains direction and session name on one line")
    check(TranscriptStyle.trafficSummary("{\"ordinary\":\"JSON\"}") == nil && TranscriptStyle.trafficSummary("Example:\n```converse\n{\"command\":\"tell\"}\n```") == nil,
          "Ordinary JSON and quoted switchboard examples remain expanded")
    check(TranscriptStyle.trafficSummary("```converse\n{\"command\":\"tell\",\"to\":\"Muse\",\"text\":\"Review\"}\n```") == "Tell to Muse · Review", "Unexecuted command summaries never claim delivery")
}
