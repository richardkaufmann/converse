import Foundation
import AppKit
import Network

func switchboardSelfTests(_ check: (Bool, String) -> Void) {
    transcriptDisclosureSelfTests(check)
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
    let agent = store.createAgent(title: "Teaching fixture")
    agent.queuePaused = true; agent.draft = "Keep my agent draft"
    let config = agent.agent
    store.teachSwitchboard(agent)
    check(agent.pending.count == 1 && agent.pending[0].text.contains("tell array") && agent.pending[0].text.contains("inReplyTo") && !agent.pending[0].text.contains("```converse"), "Teaching an agent preserves its structured response format and correlated reply rules")
    check(agent.queuePaused && agent.draft == "Keep my agent draft" && agent.agent == config, "Teaching does not change agent scope, configuration, draft or paused queue")
    store.sessions.removeAll { $0 === agent }
    source.pending = []
    reply("{\"command\":\"list-sessions\"}")
    check(source.pending.isEmpty && source.messages.last?.text.contains("fenced JSON block") == true, "Taught sessions get a formatting notice for bare command JSON")
    let textView = ConversationTextView(frame: .zero); textView.teachSession = { store.teachSwitchboard(source) }
    let menu = NSMenu(); textView.addTeachingItem(to: menu)
    check(menu.items.contains { $0.title == "Teach Session To Talk To Other Sessions" }, "Transcript right-click offers teaching even with no text or pane placement")
    reply("Example:\n" + block("tell", to: target.id.uuidString, text: "quoted") + "\nThat is the format.")
    check(target.pending.isEmpty && source.messages.last?.text.contains("text follows it") == true, "A command followed by explanatory prose never sends and explains why")
    reply("Example:\n  " + block("tell", to: target.id.uuidString, text: "indented").replacingOccurrences(of: "\n", with: "\n  "))
    check(target.pending.isEmpty, "An indented command block is discussion and never sends")
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

func transcriptDisclosureSelfTests(_ check: (Bool, String) -> Void) {
    let payload = "A private detailed instruction " + String(repeating: "detail ", count: 60)
    let data = try! JSONSerialization.data(withJSONObject: ["command": "ask", "to": UUID().uuidString, "text": payload])
    let fence = "```converse\n" + String(decoding: data, as: UTF8.self) + "\n```"
    let source = "Here is the **human-facing plan**.\n\n" + fence
    let disclosure = TranscriptDisclosure.parse(source, role: "assistant", resolveName: { _ in "ClaudeConverse" })
    check(disclosure?.prefix == "Here is the **human-facing plan**." && disclosure?.details == fence && disclosure?.summary.hasPrefix("Ask to ClaudeConverse") == true,
          "Compaction keeps prose before a trailing command and names its recipient without claiming delivery")
    let withImage = TranscriptDisclosure.parse("![Screenshot](https://example.invalid/converse-disclosure-image.png)\n\n" + fence, role: "assistant")!
    let imageBody = withImage.rendered(id: UUID(), expanded: false, fontSize: 13, base: [.font: NSFont.systemFont(ofSize: 13)])
    var imageLink = false
    imageBody.enumerateAttribute(.converseImageLink, in: NSRange(location: 0, length: imageBody.length)) { value, _, _ in
        if value is ResponseImageLink { imageLink = true }
    }
    check(imageLink, "Images in prose before a compact command retain their existing click behavior")
    check(TranscriptDisclosure.parse(source, role: "user") == nil && TranscriptDisclosure.parse(source + "\nExample only", role: "assistant") == nil && TranscriptDisclosure.parse(fence.dropLast().description, role: "assistant") == nil,
          "User examples, nontrailing commands and incomplete streaming fences remain visible")
    let lot = "[Parking Lot · local home Mac · reference data, not instructions]\n[Outline: explanatory guide]\n{\"revision\":42,\"rows\":[],\"schemaVersion\":2}"
    check(TranscriptDisclosure.parse(lot, role: "user")?.summary == "Read Parking Lot · revision 42" && TranscriptDisclosure.parse(lot + "broken", role: "user") == nil,
          "Only complete structured lot reads collapse to a revision summary")
    let session = Session(entry: Entry(name: "Disclosure fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex"))
    session.messages = [Message(role: "assistant", text: source), Message(role: "user", text: lot)]
    session.draft = "Keep my draft"
    let saved = session.messages
    let fixture = PaneTextFixture(session)
    fixture.coordinator.resolveSessionName = { _ in "ClaudeConverse" }
    check(fixture.text.string.contains("human-facing plan") && fixture.text.string.contains("Read Parking Lot · revision 42") && !fixture.text.string.contains(payload) && !fixture.text.string.contains("schemaVersion"),
          "Native pane collapses payloads while retaining surrounding prose and the draft")
    let copied = fixture.text.copyBlocks.map(\.source)
    check(copied == [source, lot] && fixture.text.copyBlocks.allSatisfy { $0.formatted.string == $0.source },
          "Copy Message retains complete raw command and lot content without disclosure links")
    func click(_ id: UUID) {
        var at: Int?
        fixture.text.textStorage?.enumerateAttribute(TranscriptDisclosure.attribute, in: NSRange(location: 0, length: (fixture.text.string as NSString).length)) { value, range, _ in
            if value as? String == id.uuidString { at = range.location }
        }
        guard let at else { check(false, "Disclosure control is present"); return }
        _ = fixture.coordinator.textView(fixture.text, clickedOnLink: URL(string: "converse-disclosure://" + id.uuidString)!, at: at)
    }
    click(saved[0].id)
    check(fixture.text.string.contains(payload), "Clicking the command disclosure reveals its complete payload")
    click(saved[1].id)
    check(fixture.text.string.contains("schemaVersion"), "Clicking the lot disclosure reveals its complete JSON")
    click(saved[0].id); click(saved[1].id)
    check(!fixture.text.string.contains(payload) && !fixture.text.string.contains("schemaVersion") && session.messages == saved && session.draft == "Keep my draft",
          "Disclosures collapse again without modifying transcript source or draft")
    check(fixture.coordinator.expandedDisclosures.isEmpty, "Expansion state is local to this pane and independently toggled")
    if let path = ProcessInfo.processInfo.environment["CONVERSE_DISCLOSURE_PREVIEW"],
       let bitmap = fixture.scroll.bitmapImageRepForCachingDisplay(in: fixture.scroll.bounds) {
        fixture.scroll.cacheDisplay(in: fixture.scroll.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
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
        let linkedLot = try b.parkingLibrary.create(name: "Linked Group ideas")
        let sourceID = DeviceGlobalID(home: aid, session: source.id).string
        let targetID = DeviceGlobalID(home: bid, session: target.id).string
        let staleID = DeviceGlobalID(home: "former-group", session: UUID()).string
        try b.parkingLibrary.setLinks(linkedLot.id, to: [sourceID, targetID, staleID], expected: [])
        check(pump { a.parkingLotDirectory(for: source.id, linkedOnly: true).contains { $0.id == linkedLot.id } }, "Linked lot metadata reaches another Group home over authenticated transport")
        check(b.publishedParkingLotLinks(linkedLot.id).contains(sourceID) && !b.publishedParkingLotLinks(linkedLot.id).contains(staleID), "Published lot links exclude unavailable and previous-Group targets")
        check(a.parkingLotDirectory(for: UUID(), linkedOnly: true).isEmpty, "Linked-only lookup matches the requesting identity rather than a title")
        let noAccess = a.parkingLotDirectory(for: source.id, agent: AgentConfig(), linkedOnly: true)
        check(noAccess.first?.access == "requires Agent Setup access", "Linking an agent never grants content access")
        source.switchboardTurnStart = source.messages.count
        let linkedLookup = "```converse\n{\"command\":\"parking-lot-list\",\"linkedOnly\":true}\n```"
        source.messages.append(Message(role: "assistant", text: linkedLookup, finalReply: linkedLookup))
        sa.processSwitchboard(source)
        check(source.pending.last?.text.contains("Linked Group ideas") == true && source.pending.last?.text.contains("linkedToMe") == true, "Session linked-lot command returns live discovery metadata")
        source.pending.removeAll()
        try b.parkingLibrary.rename(linkedLot.id, to: "Renamed linked ideas")
        check(pump { a.parkingLotDirectory(for: source.id, linkedOnly: true).first?.name == "Renamed linked ideas" }, "Renaming a Group lot preserves its links and updates discovery")
        let joinedGroup = a.currentGroup; a.currentGroup = nil
        check(a.parkingLotDirectory(for: source.id, linkedOnly: true).isEmpty, "Cached lots from a former Group are not discoverable")
        a.currentGroup = joinedGroup
        try b.parkingLibrary.setLinks(linkedLot.id, to: [], expected: [sourceID, targetID, staleID])
        check(pump { a.parkingLotDirectory(for: source.id, linkedOnly: true).isEmpty }, "Unlinking propagates without deleting the lot")
        try b.parkingLibrary.delete(linkedLot.id)
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
        func request(_ action: String, target: String? = nil, title: String? = nil, settings: DeviceAgentSettings? = nil, provider: String? = nil, id: UUID? = nil) -> DeviceParticipantResponse? {
            var response: DeviceParticipantResponse?
            Task { @MainActor in response = await a.requestParticipant(home: bid, action: action, target: target, title: title, settings: settings, provider: provider, id: id) }
            _ = pump { response != nil }
            return response
        }
        let beforeExport = target.messages
        target.messages = (0..<45).map { Message(role: $0 % 2 == 0 ? "user" : "assistant", text: "Export message \($0)", createdAt: Date(timeIntervalSince1970: Double($0))) }
        let exportPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        let exportFile = root.appendingPathComponent("export.png"); try exportPNG.write(to: exportFile)
        target.messages[0].images = [exportFile.path]
        let exportReceipts = sb.participantReceipts.count
        var exportResult: (ExportSession, [String: Data])?, exportFailure: String?, exportDone = false
        let exportRow = a.homes[bid]!.rows.first { $0.globalID == gid }!
        Task { @MainActor in
            do { exportResult = try await TranscriptExportController.load(ExportSession(row: exportRow, home: "Remote home", id: a.placementID(forGlobal: gid)), includeImages: true, service: a) }
            catch { exportFailure = error.localizedDescription }; exportDone = true
        }
        _ = pump { exportDone }
        check(exportDone && exportFailure == nil && exportResult?.0.messages.count == 45 && exportResult?.1.count == 1 && exportResult?.0.messages.last?.createdAt == Date(timeIntervalSince1970: 44), "Remote export fetches every page, original timestamps, and hash-verified image data")
        check(a.remoteLeases.isEmpty && b.remoteLeases.isEmpty && target.draft == "Unsent human draft" && sb.participantReceipts.count == exportReceipts, "Read-only export needs no display lease, changes no draft, and writes no mutation receipts")
        let exportLot = try b.parkingLibrary.create(name: "Exported ideas")
        var lotRows = exportLot.document.rows
        lotRows[1].text = "An illustrated idea"; lotRows[1].images = [exportFile.path]
        try exportLot.replaceUserRows(lotRows, revision: exportLot.document.revision)
        var lotChoice = ExportSession(lot: exportLot)
        lotChoice.remoteID = DeviceGlobalID(home: bid, session: exportLot.id).string
        var lotExport: (ExportSession, [String: Data])?, lotFailure: String?, lotDone = false
        Task { @MainActor in
            do { lotExport = try await TranscriptExportController.load(lotChoice, includeImages: true, service: a) }
            catch { lotFailure = error.localizedDescription }; lotDone = true
        }
        _ = pump { lotDone }
        check(lotDone && lotFailure == nil && lotExport?.0.isParkingLot == true && lotExport?.0.messages.contains { $0.text.contains("An illustrated idea") && $0.images.count == 1 } == true && lotExport?.1.count == 1,
              "Remote Parking Lot export retains item/image binding and verifies attachment bytes")
        check(exportLot.document.rows == lotRows && a.remoteLeases.isEmpty && sb.participantReceipts.count == exportReceipts,
              "Exporting a Group Parking Lot leaves its document, leases, and mutation receipts untouched")
        target.messages = beforeExport
        let renameID = UUID(), priorTitle = target.title
        let renamed = request("session.rename", target: gid, title: "Renamed remotely", id: renameID)
        let renamedReplay = request("session.rename", target: gid, title: "Renamed remotely", id: renameID)
        check(renamed?.outcome == "completed" && renamedReplay?.outcome == "completed" && target.title == "Renamed remotely" && !a.remoteLeases.keys.contains(gid), "Remote rename persists with a replayable receipt and needs no display lease")
        check(request("session.rename", target: gid, title: "  ")?.outcome == "rejected" && target.title == "Renamed remotely", "Remote rename rejects a blank name without changing the session")
        check(request("session.rename", target: DeviceGlobalID(home: aid, session: target.id).string, title: "Wrong home")?.outcome == "rejected", "Remote rename rejects a same-UUID foreign-home target")
        check(Store(folder: sb.folder).sessions.first { $0.id == target.id }?.title == "Renamed remotely", "Remote rename survives an archive reload")
        target.title = priorTitle; sb.save()
        let remoteCreation = UUID(), countBeforeSession = sb.sessions.count
        let newSession = request("session.create", provider: "codex", id: remoteCreation)
        let sameSession = request("session.create", provider: "codex", id: remoteCreation)
        check(newSession?.outcome == "completed" && sameSession?.target == newSession?.target && sb.sessions.count == countBeforeSession + 1, "Remote provider creation is persisted and retry-idempotent")
        check(request("session.create", provider: "shell")?.outcome == "rejected" && sb.sessions.count == countBeforeSession + 1, "Remote creation cannot supply arbitrary executable commands")
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
    let stray = UUID(), expectations = sender.switchboardExpectations
    check(store.deliverSwitchboard(from: receiver, to: sender.id.uuidString, text: "Wrong request", id: stray, hop: 2, inReplyTo: UUID()) == nil &&
          sender.switchboardExpectations.map(\.answered) == expectations.map(\.answered) && !receiver.switchboardObligations.contains { $0.replyDeliveryID == stray },
          "Unrelated reply IDs cannot satisfy an obligation; the message is still delivered as a plain tell")
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
    // Full delivery lifecycle: tells complete without manufacturing reply obligations.
    let producer = store.create(entry), consumer = store.create(entry), supervisor = store.create(entry)
    producer.switchboardEnabled = true; consumer.switchboardEnabled = true
    producer.queuePaused = true; consumer.queuePaused = true; supervisor.queuePaused = true
    supervisor.agent = AgentConfig(watchedSessions: [consumer.id])
    let tellID = UUID()
    _ = store.deliverSwitchboard(from: producer, to: consumer.id.uuidString, text: "One-way update", id: tellID, hop: 1)
    let queuedTell = consumer.pending.removeFirst()
    store.switchboardStarted(consumer, prompt: queuedTell)
    check(producer.messages.last?.text.hasPrefix("Switchboard: processing →") == true, "Sender receipt advances from queued to processing")
    store.switchboardTurnFinished(consumer)
    check(consumer.switchboardObligations.last?.state == "completed" && producer.messages.last?.text.hasPrefix("Switchboard: completed →") == true, "Completed tell updates both panes without waiting for a reply")
    check(store.recoverSwitchboard(consumer, delivery: tellID, by: supervisor, now: Date().addingTimeInterval(1000)) != nil, "Supervisor cannot recover a completed tell")
    let stalledID = UUID()
    _ = store.deliverSwitchboard(from: producer, to: consumer.id.uuidString, text: "Existing queued work", id: stalledID, hop: 1)
    let recoveryTime = Date().addingTimeInterval(121)
    check(store.recoverSwitchboard(consumer, delivery: stalledID, by: supervisor, now: recoveryTime) != nil, "Scoped supervisor cannot override a paused queue")
    consumer.queuePaused = false; consumer.busy = true
    consumer.switchboardProgress = (consumer.messagesRevision, Date())
    check(store.recoverSwitchboard(consumer, delivery: stalledID, by: producer, now: recoveryTime) != nil, "Non-agent cannot request supervisory force injection")
    supervisor.agent?.watchedSessions = []
    check(store.recoverSwitchboard(consumer, delivery: stalledID, by: supervisor, now: recoveryTime) != nil, "Revoked session scope prevents recovery")
    supervisor.agent?.watchedSessions = [consumer.id]
    consumer.status = "Waiting for approval"
    check(store.recoverSwitchboard(consumer, delivery: stalledID, by: supervisor, now: recoveryTime) != nil, "Supervisor cannot bypass an approval")
    consumer.status = "Working"
    consumer.messages.append(Message(role: "assistant", text: "New progress"))
    check(store.recoverSwitchboard(consumer, delivery: stalledID, by: supervisor, now: recoveryTime) != nil, "Fresh output invalidates stale recovery evidence")
    consumer.switchboardProgress = (consumer.messagesRevision, Date())
    consumer.agent = AgentConfig(); consumer.agent?.enabled = true
    consumer.draft = "Preserve my unsent draft"
    let queuedID = consumer.pending[0].id
    check(store.recoverSwitchboard(consumer, delivery: stalledID, by: supervisor, now: recoveryTime) == nil && consumer.interrupted && consumer.pending[0].id == queuedID && consumer.draft == "Preserve my unsent draft", "Scoped supervisor injects the existing stalled delivery once and preserves draft")
    check(consumer.agent?.enabled == true, "Recovery interruption preserves the target agent loop")
    consumer.interrupted = false
    check(store.recoverSwitchboard(consumer, delivery: stalledID, by: supervisor, now: recoveryTime.addingTimeInterval(500)) != nil, "Automatic and agent recovery share one durable allowance")
    let recoveryReload = Store(folder: folder)
    check(recoveryReload.sessions.first(where: { $0.id == consumer.id })?.switchboardObligations.last?.intervenedAt != nil, "Agent recovery allowance survives restart")
    check(AgentReply.decode("{\"reply\":\"Recover\",\"recover\":[{\"target\":\"test\",\"delivery\":\"" + stalledID.uuidString + "\"}]}")?.recover?.first?.delivery == stalledID, "Agent recovery response decodes authenticated delivery IDs")
    consumer.busy = false; consumer.queuePaused = true
    let failedPrompt = consumer.pending.removeFirst()
    store.switchboardStarted(consumer, prompt: failedPrompt)
    store.switchboardTurnFinished(consumer, success: false)
    check(consumer.switchboardObligations.last?.state == "failed" && producer.messages.last?.text.hasPrefix("Switchboard: failed →") == true, "Provider failure is visible instead of a stuck processing receipt")
    check(TranscriptStyle.trafficSummary("Switchboard: completed → Steward [id] · delivery [tell]\nUpdate") == "Completed tell to Steward · Update", "Completed receipt renders as completed, not queued")
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
    // Incoming traffic built exactly as delivery builds it: an inReplyTo answer
    // reads as a reply (bug 9DF32E78), and delivery instructions stay out of the detail.
    let envelopeRequest = UUID(), envelopeDelivery = UUID()
    func envelope(_ body: String, expected: Bool, inReplyTo: UUID?) -> String {
        "[Converse message from ClaudeConverse · session abc · delivery " + envelopeDelivery.uuidString + " · hop 1/100]\n" + body + Store.replyInstruction(id: envelopeDelivery, expected: expected, inReplyTo: inReplyTo)
    }
    let envelopeCases: [(String, Bool, UUID?, String)] = [
        ("Status update", false, nil, "tell"), ("Can you check?", true, nil, "ask"),
        ("Done; fixed it", false, envelopeRequest, "reply"), ("Done; which branch?", true, envelopeRequest, "reply + ask")]
    for (body, expected, replyTo, kind) in envelopeCases {
        let text = envelope(body, expected: expected, inReplyTo: replyTo)
        check(TranscriptStyle.trafficSummary(text) == "Received " + kind + " from ClaudeConverse · " + body &&
              TranscriptStyle.trafficSummary(text, queued: true) == "Queued " + kind + " from ClaudeConverse · " + body,
              "Incoming " + kind + " reads as " + kind + " when received and queued, without delivery instructions")
    }
    check(TranscriptStyle.trafficSummary("Switchboard: message queued from ClaudeConverse · session abc\nDone\n[Reply to request " + envelopeRequest.uuidString + "]") == "Queued reply from ClaudeConverse · Done",
          "Legacy queue receipts also read replies as replies")
    check(TranscriptStyle.trafficSummary("[Converse message from Muse · session abc]\nI read [Reply to request X] in the docs") == "Received tell from Muse · I read [Reply to request X] in the docs",
          "Only the delivery reply marker, not quoted body text, makes a reply")
    // A delivered reply carries no obligation: an interrupted receiving turn is not a delivery failure.
    let replyFolder = FileManager.default.temporaryDirectory.appendingPathComponent("reply-interrupted-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: replyFolder) }
    let replyStore = Store(folder: replyFolder)
    replyStore.startAgentRun = { _, _ in }
    let replyAsker = replyStore.create(entry), replyAnswerer = replyStore.create(entry), replyWatcher = replyStore.create(entry)
    replyAsker.switchboardEnabled = true; replyAnswerer.switchboardEnabled = true
    replyAsker.queuePaused = true; replyAnswerer.queuePaused = true; replyWatcher.queuePaused = true
    replyWatcher.agent = AgentConfig(watchedSessions: [replyAsker.id])
    func exchange(_ text: String) -> UUID? {
        let ask = UUID()
        guard replyStore.deliverSwitchboard(from: replyAsker, to: replyAnswerer.id.uuidString, text: text, id: ask, hop: 1, replyExpected: true) == nil else { return nil }
        replyAnswerer.pending.removeAll()
        let reply = UUID()
        guard replyStore.deliverSwitchboard(from: replyAnswerer, to: replyAsker.id.uuidString, text: "Answer: " + text, id: reply, hop: 1, inReplyTo: ask) == nil else { return nil }
        return reply
    }
    func replyRecord(_ session: Session?, _ id: UUID?) -> SwitchboardObligation? { session?.switchboardObligations.first { $0.id == id && $0.kind == "reply" } }
    let interruptedReply = exchange("first")
    check(replyRecord(replyAsker, interruptedReply)?.state == "queued" && replyAnswerer.switchboardObligations.last?.state == "resolved", "Correlated reply registers on the asker and resolves the answerer's request")
    replyStore.switchboardStarted(replyAsker, prompt: replyAsker.pending.removeFirst())
    replyStore.switchboardTurnFinished(replyAsker, success: false)
    let interruptedRecord = replyRecord(replyAsker, interruptedReply)
    check(interruptedRecord?.state == "interrupted" && interruptedRecord?.terminal == true && interruptedRecord?.displayState == "Reply delivered · turn interrupted",
          "A delivered reply whose turn fails or is interrupted ends interrupted, not failed")
    check(replyAnswerer.messages.last { $0.text.contains(interruptedReply?.uuidString ?? "-") }?.text.hasPrefix("Switchboard: reply delivered · turn interrupted →") == true &&
          replyAnswerer.switchboardObligations.last?.state == "resolved", "Answerer receipt reports the reply as delivered; its request stays resolved")
    let interruptedEvidence = replyStore.switchboardRecoveryEvidence(for: replyWatcher).first { $0["delivery"] as? String == interruptedReply?.uuidString }
    check(interruptedEvidence?["state"] as? String == "Reply delivered · turn interrupted" && interruptedEvidence?["canRecover"] as? Bool == false,
          "Agent supervision evidence states the reply was delivered and never offers a resend")
    check(TranscriptStyle.trafficSummary("Switchboard: reply delivered · turn interrupted → Steward [id] · delivery [tell]\nAnswer") == "Reply delivered to Steward · turn interrupted · Answer",
          "Interrupted reply traffic row never reads as a failure")
    // Restart while the reply-triggered turn is running; undelivered replies stay pending; legacy failed replies are repaired.
    let legacyReply = exchange("second")
    replyStore.switchboardStarted(replyAsker, prompt: replyAsker.pending.removeFirst())
    replyStore.switchboardTurnFinished(replyAsker, success: true)
    if let index = replyAsker.switchboardObligations.firstIndex(where: { $0.id == legacyReply }) { replyAsker.switchboardObligations[index].state = "failed" }
    let runningReply = exchange("third")
    replyStore.switchboardStarted(replyAsker, prompt: replyAsker.pending.removeFirst())
    let undeliveredReply = exchange("fourth")
    let ask = UUID()
    _ = replyStore.deliverSwitchboard(from: replyAnswerer, to: replyAsker.id.uuidString, text: "Request", id: ask, hop: 1, replyExpected: true)
    replyStore.switchboardStarted(replyAsker, prompt: replyAsker.pending.removeLast())
    check(replyRecord(replyAsker, runningReply)?.state == "submitted" && replyRecord(replyAsker, undeliveredReply)?.state == "queued" &&
          replyAsker.switchboardObligations.first { $0.id == ask }?.state == "submitted", "Fixture holds a running reply, an undelivered reply and a running request")
    try? replyStore.saveChecked()
    let reloadedStore = Store(folder: replyFolder)
    let replyReload = reloadedStore.sessions.first { $0.id == replyAsker.id }
    check(reloadedStore.sessions.first { $0.id == replyAnswerer.id }?.messages.last { $0.text.contains(runningReply?.uuidString ?? "-") }?.text.hasPrefix("Switchboard: reply delivered · turn interrupted →") == true,
          "Restart updates the answerer's receipt instead of leaving it processing or failed")
    check(replyRecord(replyReload, runningReply)?.state == "interrupted", "Restart with an in-flight delivered reply yields interrupted")
    check(replyRecord(replyReload, legacyReply)?.state == "interrupted", "Legacy failed replies (only reachable after delivery) reload as interrupted")
    check(replyRecord(replyReload, undeliveredReply)?.state == "queued", "An undelivered reply is not marked delivered by restart")
    check(replyReload?.switchboardObligations.first { $0.id == ask }?.state == "cancelled", "Restart still cancels an in-flight request")
    replyStore.switchboardTurnFinished(replyAsker, success: false)
    check(replyAsker.switchboardObligations.first { $0.id == ask }?.state == "failed" && replyRecord(replyAsker, undeliveredReply)?.state == "queued",
          "Failed turns still fail requests and leave undelivered replies untouched")
    replyAsker.pending.removeAll()
    replyStore.superviseSwitchboard(now: Date().addingTimeInterval(600))
    check(replyRecord(replyAsker, undeliveredReply)?.state == "cancelled", "A reply that never reached the transcript is cancelled, never shown as delivered")
    let legacyJSON = #"{"id":"\#(UUID().uuidString)","source":"s","sourceName":"Old","promptID":"\#(UUID().uuidString)","kind":"request","state":"failed","createdAt":0}"#
    let futureJSON = legacyJSON.replacingOccurrences(of: "\"failed\"", with: "\"futureState\"")
    let legacy = try? JSONDecoder().decode(SwitchboardObligation.self, from: Data(legacyJSON.utf8))
    let future = try? JSONDecoder().decode(SwitchboardObligation.self, from: Data(futureJSON.utf8))
    check(legacy?.state == "failed" && legacy?.displayState == "Failed" && legacy?.terminal == true, "Persisted legacy failed state still decodes and displays as failed")
    check(future?.state == "futureState" && future?.terminal == false, "Unknown persisted states decode safely for cross-version archives")
}

// Models garble request UUIDs (observed: first 8 hex digits intact, the rest
// invented). A reply must never be dropped for a bad inReplyTo.
func switchboardReplyToleranceSelfTests(_ check: (Bool, String) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reply-tolerance-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = Store(folder: folder)
    let entry = Entry(name: "Fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")
    let asker = store.create(entry), answerer = store.create(entry), other = store.create(entry)
    for s in [asker, answerer, other] { s.switchboardEnabled = true; s.queuePaused = true }
    func ask(_ from: Session, _ id: String) -> UUID {
        let uuid = UUID(uuidString: id)!
        _ = store.deliverSwitchboard(from: from, to: answerer.id.uuidString, text: "Question " + id, id: uuid, hop: 1, replyExpected: true)
        return uuid
    }
    func reply(_ text: String, supplied: String, to target: Session = asker) -> (failure: String?, id: UUID) {
        let id = UUID()
        return (store.deliverSwitchboard(from: answerer, to: target.id.uuidString, text: text, id: id, hop: 2, suppliedReply: supplied), id)
    }
    func request(_ id: UUID) -> SwitchboardObligation? { answerer.switchboardObligations.first { $0.id == id && $0.kind == "request" } }
    func delivered(_ text: String, replyTo: UUID?) -> Bool {
        guard let prompt = asker.pending.last, prompt.text.contains(text) else { return false }
        return replyTo.map { prompt.text.contains("[Reply to request " + $0.uuidString + "]") } ?? !prompt.text.contains("[Reply to request")
    }
    func answered(_ id: UUID) -> Bool { asker.switchboardExpectations.first { $0.id == id }?.answered == true }
    func lastNotice() -> String { answerer.messages.last { $0.role == "notice" }?.text ?? "" }

    let exact = ask(asker, "0E0E0E0E-0000-4000-8000-000000000001")
    var sent = reply("Exact answer", supplied: exact.uuidString)
    check(sent.failure == nil && request(exact)?.replyDeliveryID == sent.id && answered(exact) && delivered("Exact answer", replyTo: exact) && !lastNotice().contains("reply ID"),
          "Exact inReplyTo resolves the request without a correction notice")

    let decoy = ask(asker, "AAAAAAAA-0000-4000-8000-000000000002")
    let real = ask(asker, "CDE10DC4-8BFE-47B6-92A2-4EFF5009E548")
    sent = reply("APPROVE", supplied: "CDE10DC4-2353-4A2F-81AC-35BE0DF9701F")
    check(sent.failure == nil && request(real)?.replyDeliveryID == sent.id && request(real)?.state == "resolved" && answered(real) &&
          request(decoy)?.replyDeliveryID == nil && !answered(decoy) && delivered("APPROVE", replyTo: real) &&
          lastNotice() == "Switchboard: reply ID corrected to CDE10DC4-8BFE-47B6-92A2-4EFF5009E548 (supplied CDE10DC4-2353-4A2F-81AC-35BE0DF9701F)",
          "Garbled inReplyTo with a matching 8-digit prefix is corrected to the right open request")

    sent = reply("Decoy answer", supplied: "DEADBEEF-1111-4111-8111-111111111111")
    check(sent.failure == nil && request(decoy)?.replyDeliveryID == sent.id && answered(decoy) && delivered("Decoy answer", replyTo: decoy) &&
          lastNotice().contains("corrected to " + decoy.uuidString),
          "Garbled inReplyTo is corrected to the single open request from that session")

    let first = ask(asker, "11111111-0000-4000-8000-000000000003"), second = ask(asker, "22222222-0000-4000-8000-000000000004")
    sent = reply("Ambiguous answer", supplied: "99999999-0000-4000-8000-000000000000")
    check(sent.failure == nil && request(first)?.replyDeliveryID == nil && request(second)?.replyDeliveryID == nil && !answered(first) && !answered(second) &&
          delivered("Ambiguous answer", replyTo: nil) && lastNotice().contains("matched no open request from") && lastNotice().hasSuffix("delivered as a plain tell."),
          "Ambiguous garbled inReplyTo delivers a plain tell without resolving anything")
    _ = reply("Close first", supplied: first.uuidString); _ = reply("Close second", supplied: second.uuidString)

    sent = reply("Nothing open", supplied: "CDE10DC4-0000-4000-8000-000000000000")
    check(sent.failure == nil && delivered("Nothing open", replyTo: nil) && lastNotice().contains("matched no open request"),
          "With no open requests a garbled inReplyTo still delivers as a plain tell")

    // Another session's open request is never a correction candidate.
    let foreign = ask(other, "77777777-0000-4000-8000-000000000005")
    let own = ask(asker, "33333333-0000-4000-8000-000000000006")
    sent = reply("Scoped answer", supplied: "77777777-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
    check(sent.failure == nil && request(own)?.replyDeliveryID == sent.id && request(foreign)?.replyDeliveryID == nil &&
          other.switchboardExpectations.first { $0.id == foreign }?.answered == false && delivered("Scoped answer", replyTo: own),
          "Correction considers only requests from the addressed session")
    sent = reply("Other only", supplied: "77777777-AAAA-4AAA-8AAA-AAAAAAAAAAAA", to: asker)
    check(sent.failure == nil && request(foreign)?.replyDeliveryID == nil && delivered("Other only", replyTo: nil),
          "A prefix match from a different session is never borrowed")

    // A non-UUID inReplyTo from the command fence must not make the whole command vanish.
    let pending = ask(asker, "44444444-0000-4000-8000-000000000007")
    let body: [String: Any] = ["command": "tell", "to": asker.id.uuidString, "text": "Fenced answer", "inReplyTo": "44444444"]
    let text = "```converse\n" + String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self) + "\n```"
    answerer.switchboardTurnStart = answerer.messages.count
    answerer.messages.append(Message(role: "assistant", text: text, finalReply: text)); store.processSwitchboard(answerer)
    check(delivered("Fenced answer", replyTo: pending) && answered(pending) && lastNotice().contains("supplied 44444444)"),
          "A truncated non-UUID inReplyTo in a fenced command is corrected and delivered")
    check(Store.replyInstruction(id: real, expected: true, inReplyTo: nil).contains("\n" + real.uuidString + "\n") &&
          Store.replyInstruction(id: real, expected: true, inReplyTo: nil).contains("copied exactly"),
          "Reply instructions place the full request UUID on its own line and ask for an exact copy")
}

// Agents (Claude and Codex) routinely open with a line of prose before the
// command. A trailing converse fence runs; anything ambiguous explains why not.
func switchboardTrailingFenceSelfTests(_ check: (Bool, String) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trailing-fence-" + UUID().uuidString)
    let service = DeviceSyncService()
    defer { service.suspendViewer(); try? FileManager.default.removeItem(at: folder) }
    do { try service.configureForTesting(folder: folder.appendingPathComponent("device")) } catch { check(false, "Trailing fence device fixture configures: \(error)"); return }
    let store = Store(folder: folder.appendingPathComponent("store"))
    store.switchboardService = service; service.storeOverride = store
    func json(_ value: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    func block(_ value: [String: Any]) -> String { "```converse\n" + json(value) + "\n```" }
    for engine in ["claude", "codex"] {
        let entry = Entry(name: "Fence fixture", command: "unused", directory: NSTemporaryDirectory(), engine: engine)
        let source = store.create(entry), target = store.create(entry)
        source.title = "Build A Video"; target.title = "Reviewer"
        for s in [source, target] { s.switchboardEnabled = true; s.queuePaused = true }
        // Claude acts on its visible text; Codex on its final answer, which may differ from streamed text.
        func reply(_ text: String) {
            source.switchboardTurnStart = source.messages.count
            source.messages.append(engine == "codex" ? Message(role: "assistant", text: "Streamed commentary", finalReply: text) : Message(role: "assistant", text: text))
            store.processSwitchboard(source)
        }
        func notices() -> [String] { source.messages.filter { $0.role == "notice" }.map(\.text) }
        let tell = block(["command": "tell", "to": target.id.uuidString, "text": "Trailing hello"])
        reply("Sending this to Reviewer now.\nIt covers the opening shot.\n\n" + tell + "\n  \n")
        check(target.pending.count == 1 && target.pending[0].text.hasSuffix("Trailing hello"), engine + ": prose followed by a trailing tell fence delivers")
        let delivered = target.pending.count, noticeCount = notices().count
        store.processSwitchboard(source)
        check(target.pending.count == delivered && notices().count == noticeCount, engine + ": a trailing command cannot replay")
        reply(tell)
        check(target.pending.count == delivered + 1, engine + ": a whole-reply fence still delivers")
        reply("Sending.\r\n" + tell.replacingOccurrences(of: "\n", with: "\r\n"))
        check(target.pending.count == delivered + 2, engine + ": CRLF line endings are accepted")
        let ask = block(["command": "ask", "to": target.id.uuidString, "text": "Trailing question"])
        reply("Asking Reviewer.\n" + ask)
        check(target.pending.last?.text.contains("Trailing question") == true && source.switchboardExpectations.contains { !$0.answered }, engine + ": a trailing ask requests a correlated answer")
        reply("Looking up sessions.\n" + block(["command": "list-sessions"]))
        check(source.pending.last?.text.contains("switchboard directory") == true && source.pending.last?.text.contains(target.id.uuidString) == true, engine + ": a trailing list-sessions returns the directory")
        let count = target.pending.count
        func rejected(_ text: String, _ reason: String, _ label: String) {
            let before = notices().count
            reply(text)
            let added = notices().dropFirst(before)
            check(target.pending.count == count && added.count == 1 && added.first?.contains("was not run because " + reason) == true && added.first?.contains("Nothing was sent. Converse asked the session to resend it.") == true, engine + ": " + label)
            store.processSwitchboard(source)
            check(notices().count == before + 1 && target.pending.count == count, engine + ": " + label + " — the notice appears once and cannot replay")
        }
        rejected("Here it is:\n" + tell + "\nLet me know if that works.", "text follows it", "a fence followed by prose is not run and explains why")
        func reminders() -> Int { source.pending.filter { $0.text.contains(SwitchboardCommand.resendReminder) }.count }
        check(reminders() == 1 && source.pending.last?.text.contains("text follows it") == true && source.pending.last?.text.contains("If it was just an example, ignore this") == true, engine + ": a rejected command sends the session one resend reminder with the reason")
        rejected("First:\n" + tell + "\nSecond:\n" + tell, "the reply contains several command blocks", "two command fences are not run and explain why")
        rejected("Sending:\n" + tell + "\n```bash\nls\n```", "text follows it", "a later code block counts as text after the command")
        rejected("Sending:\n```converse\n{\"command\":\"tell\",", "its fence is not closed", "an unclosed command fence explains why")
        rejected("Sending:\n```converse\n{not json}\n```", "its JSON is not a valid command", "invalid command JSON explains why")
        check(reminders() == 1, engine + ": further rejections while a reminder is pending add no more reminders")
        source.pending.removeAll { $0.text.contains(SwitchboardCommand.resendReminder) }
        source.messages.append(Message(role: "user", text: SwitchboardCommand.resendReminder + " Reason: text follows it."))
        rejected("Again:\n" + tell + "\nThanks.", "text follows it", "a rejection in the reminder's own turn still explains why")
        check(reminders() == 0, engine + ": a turn started by the reminder never triggers another reminder")
        let quiet = notices().count
        reply("Example:\n> " + tell.replacingOccurrences(of: "\n", with: "\n> "))
        reply("Example:\n    " + tell.replacingOccurrences(of: "\n", with: "\n    "))
        reply("Example:\n```json\n" + json(["command": "tell", "to": target.id.uuidString, "text": "x"]) + "\n```")
        check(target.pending.count == count && notices().count == quiet, engine + ": quoted, indented and non-converse blocks stay silent discussion")
        reply("Here is a reference:\n```swift\nlet x = 1\n```\nSending now.\n" + tell)
        check(target.pending.count == count + 1, engine + ": an earlier non-command code block does not prevent a trailing command")
        reply("Sending.\n{\"command\":\"tell\",\"to\":\"" + target.id.uuidString + "\",\"text\":\"bare\"}")
        check(target.pending.count == count + 1, engine + ": bare JSON after prose never sends")
        reply("{\"command\":\"tell\",\"to\":\"" + target.id.uuidString + "\",\"text\":\"bare\"}")
        check(target.pending.count == count + 1 && notices().last?.contains("as the last thing in the reply") == true, engine + ": bare command JSON keeps its formatting notice")
        reply("Opening the app.\n" + block(["command": "app-control", "action": "inspect"]))
        check(notices().last?.contains("app-control") != true, engine + ": a trailing app-control fence keeps the whole-reply App Support rule")
        // Untaught sessions keep the strict rule, so protocol discussion stays quiet.
        source.switchboardEnabled = false
        let untaught = notices().count
        reply("Sending:\n" + tell + "\nmore")
        reply("Sending:\n" + tell)
        check(target.pending.count == count + 1 && notices().count == untaught, engine + ": untaught sessions ignore non-whole fences silently")
        source.switchboardEnabled = true

        // Parking Lot edit as the last thing in a reply: the Build A Video report.
        guard let lot = try? service.parkingLibrary.create(name: "Video ideas " + engine) else { check(false, "Parking Lot fixture"); continue }
        func edit(_ text: String) -> String {
            block(["command": "parking-lot-edit", "lotID": lot.id.uuidString, "parkingLotEdits": ["revision": lot.document.revision, "operations": [["action": "add", "text": text]]]])
        }
        var reviewed: [String] = []
        store.parkingLotReviewConfirm = { reviewed.append($0); return true }
        reply("I'll add the storyboard idea.\nPlease approve the change.\n\n" + edit("Storyboard the intro"))
        check(reviewed.count == 1 && reviewed[0].contains("Storyboard the intro") && lot.document.rows.contains { $0.text == "Storyboard the intro" } && source.pending.last?.text.contains("approved and saved") == true, engine + ": a trailing parking-lot-edit requests review and applies when approved")
        store.processSwitchboard(source)
        check(reviewed.count == 1, engine + ": an approved trailing edit cannot request review twice")
        store.parkingLotReviewConfirm = { reviewed.append($0); return false }
        reply("Adding another.\n" + edit("Declined idea"))
        check(reviewed.count == 2 && !lot.document.rows.contains { $0.text == "Declined idea" } && source.pending.last?.text.contains("declined") == true, engine + ": a declined trailing edit saves nothing")
        reply("Adding:\n" + edit("Followed by prose") + "\nDone!")
        check(reviewed.count == 2 && !lot.document.rows.contains { $0.text == "Followed by prose" } && notices().last?.contains("text follows it") == true, engine + ": an edit followed by prose is not reviewed or applied and explains why")
        store.parkingLotReviewConfirm = nil
        // Confirmation off: the real asynchronous path saves without a sheet.
        try? service.parkingLibrary.setConfirmsSessionEdits(lot.id, false)
        reply("Saving directly.\n" + edit("Saved without review"))
        let deadline = Date().addingTimeInterval(5)
        while !lot.document.rows.contains(where: { $0.text == "Saved without review" }) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(lot.document.rows.contains { $0.text == "Saved without review" } && notices().contains { $0.contains("Parking Lot review pending") }, engine + ": a trailing edit to a lot with confirmation off saves through the normal path")
        try? service.parkingLibrary.delete(lot.id)
        store.sessions.removeAll { $0 === source || $0 === target }
    }
    check(SwitchboardCommand.conversationPolicy.contains("last thing in your reply (one per reply)") && !SwitchboardCommand.conversationPolicy.contains("ENTIRE"), "Conversation policy teaches the trailing command rule")
    let teaching = store.switchboardTeaching(store.create(Entry(name: "Teach", command: "unused", directory: NSTemporaryDirectory(), engine: "claude")))
    check(teaching.contains("LAST thing in your final reply") && teaching.contains("one command block per reply") && !teaching.contains("ENTIRE") && !teaching.contains("no delivery error"), "Session teaching says the command block must be last, one per reply")
}
