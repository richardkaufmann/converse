import XCTest
import SwiftUI
import Network
import UniformTypeIdentifiers
@testable import Converse

@MainActor
final class ConverseTests: XCTestCase {
    func service() throws -> DeviceSyncService {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("converse-ipad-tests-" + UUID().uuidString)
        let service = DeviceSyncService(); try service.configureForTesting(folder: folder)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return service
    }
    func testClosedHomeSessionDisappearsFromIPadAndRejectsLateSnapshots() throws {
        let service = try service(), model = PadModel(service: service)
        let home = String(repeating: "a", count: 64), sid = UUID()
        let id = DeviceGlobalID(home: home, session: sid).string
        let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Home")
        peer.hello = DeviceHello(deviceID: home, deviceName: "Home", converseVersion: "test"); peer.trustedReady = true
        let row = DeviceSidebarRow(globalID: id, sessionID: sid, title: "Closing", assistant: "Muse", engine: "muse", model: "m", effort: "", access: "", status: "Ready", busy: false, queued: 0, queuePaused: false)
        func sidebar(_ sequence: UInt64, _ rows: [DeviceSidebarRow]) throws {
            let payload = DeviceSidebarPayload(homeDeviceID: home, homeDeviceName: "Home", homeSeq: sequence, rows: rows)
            service.handleEnvelope(peer, DeviceEnvelope(kind: "sidebar.snapshot", homeSeq: sequence, payload: try JSONEncoder().encode(payload)))
        }
        try sidebar(10, [row])
        model.state.placements[0] = id; model.state.drafts[id] = PadDraft(text: "Keep unsent words", dirty: true)
        service.remoteLeases[id] = 4
        let snapshot = DeviceTranscriptPayload(globalID: id, homeSeq: 11, epoch: 4, messages: [], offset: 0, total: 0, draft: "", draftVersion: 0, busy: false, status: "Ready")
        service.handleEnvelope(peer, DeviceEnvelope(kind: "transcript.snapshot", sessionID: id, epoch: 4, payload: try JSONEncoder().encode(snapshot)))
        try sidebar(12, [])
        XCTAssertNil(model.state.placements[0]); XCTAssertNil(service.remoteLeases[id]); XCTAssertNil(service.remoteTranscripts[id])
        XCTAssertEqual(model.draft(id).text, "Keep unsent words", "Closing a remote pane retains recoverable local typing")
        XCTAssertNil(service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "send", text: "Too late")))
        try sidebar(10, [row])
        service.handleEnvelope(peer, DeviceEnvelope(kind: "transcript.snapshot", sessionID: id, epoch: 4, payload: try JSONEncoder().encode(snapshot)))
        XCTAssertTrue(service.homes[home]?.rows.isEmpty == true); XCTAssertNil(service.remoteTranscripts[id])
        XCTAssertNil(PadModel(service: service).state.placements[0], "Closed placement stays gone after scene restoration")
    }
    func testConverseGroupsAdmissionAgainstMacHome() async throws {
        guard let port = ProcessInfo.processInfo.environment["CONVERSE_GROUP_PORT"].flatMap(Int.init), port > 0 else { throw XCTSkip("Run iPad/test.sh --interop with the group-aware Mac fixture") }
        let service = try service(); try service.enableGroupsForTesting()
        service.isPlaced = { _ in true }
        try service.startNetworkForTesting()
        defer { service.suspendViewer() }
        service.joinGroupByAddress(host: "127.0.0.1", port: port)
        try await eventually("Joiner immediately receives its connection code") { service.pairingPrompt != nil }
        let code = try XCTUnwrap(service.pairingPrompt?.code)
        XCTAssertNil(service.currentGroup)
        service.confirmPairing()
        try await eventually("Mac review and both Pair confirmations admit iPad") { service.currentGroup?.name == "Simulator Group" && !service.homes.isEmpty }
        XCTAssertTrue(service.remoteLeases.isEmpty, "Admission does not take a session")
        try await eventually("Group directory reaches iPad") { service.homes.values.contains { !$0.rows.isEmpty } }
        let row = try XCTUnwrap(service.homes.values.flatMap(\.rows).first)
        service.acquireRemote(globalID: row.globalID)
        try await eventually("Group member takes the home session") { service.remoteTranscripts[row.globalID] != nil }
        let transcript = try XCTUnwrap(service.remoteTranscripts[row.globalID])
        XCTAssertTrue(transcript.messages.contains { $0.text.contains("verified code " + code) }, "Mac Review saw the exact number the iPad displayed first")
        XCTAssertEqual(transcript.draft, "home draft")
        let home = try XCTUnwrap(DeviceGlobalID(row.globalID)?.home)
        let oldLeases = service.remoteLeases
        let created = await service.requestParticipant(home: home, action: "agent.create", title: "iPad-created paused agent")
        XCTAssertEqual(created.outcome, "completed", created.detail)
        let target = try XCTUnwrap(created.target)
        let loaded = await service.requestParticipant(home: home, action: "agent.settings", target: target)
        var settings = try XCTUnwrap(loaded.settings)
        XCTAssertFalse(settings.enabled)
        XCTAssertTrue(settings.watched.isEmpty)
        settings.scheduleText = "every 20 minutes while the US stock market is open"
        settings.scheduleTimeZone = "America/New_York"
        settings.discordShareSessionInformation = true
        settings.discordShareScoreboard = true
        settings.objective = "Persist the edited objective from the iPad"
        settings.remainingRuns = 0; settings.turnLimit = 3; settings.enabled = true
        let saved = await service.requestParticipant(home: home, action: "agent.configure", target: target, settings: settings)
        XCTAssertEqual(saved.outcome, "completed", saved.detail)
        XCTAssertEqual(saved.settings?.turnLimit, 3, "Save acknowledges the per-activation limit even with an exhausted legacy counter")
        XCTAssertEqual(saved.settings?.enabled, true, "The iPad can restart a loop using a text schedule")
        let refreshed = await service.requestParticipant(home: home, action: "agent.settings", target: target)
        XCTAssertEqual(refreshed.settings?.scheduleText, settings.scheduleText)
        XCTAssertEqual(refreshed.settings?.objective, settings.objective)
        XCTAssertEqual(refreshed.settings?.discordShareScoreboard, true)
        XCTAssertEqual(refreshed.settings?.discordShareSessionInformation, true)
        var duringRun = try XCTUnwrap(refreshed.settings)
        let queued = await service.requestParticipant(home: home, action: "agent.run", target: target)
        XCTAssertEqual(queued.outcome, "completed", queued.detail)
        duringRun.discordShareScoreboard = false
        let changedDuringRun = await service.requestParticipant(home: home, action: "agent.configure", target: target, settings: duringRun)
        XCTAssertEqual(changedDuringRun.outcome, "completed", changedDuringRun.detail)
        let readBack = await service.requestParticipant(home: home, action: "agent.settings", target: target)
        XCTAssertEqual(readBack.settings?.discordShareScoreboard, false)
        XCTAssertEqual(service.remoteLeases, oldLeases, "Agent control never steals or changes a display lease")
        let stale = await service.requestParticipant(home: home, action: "agent.configure", target: target, settings: settings)
        XCTAssertEqual(stale.outcome, "rejected", "Stale settings cannot overwrite the new schedule")
        XCTAssertTrue(stale.detail.contains("Reload"), "The home returns an actionable conflict message")
        service.leaveGroup()
        XCTAssertNil(service.currentGroup)
        XCTAssertTrue(service.homes.isEmpty)
        XCTAssertTrue(service.remoteLeases.isEmpty)
        XCTAssertTrue(service.remoteTranscripts.isEmpty)
    }
    func testBlockSpacingDoesNotInsertBlankTranscriptLines() {
        for tail in ["", "\n", "\n\n", "\r\n"] {
            let messages = [DeviceWireMessage(id: UUID(), role: "user", text: "Prompt" + tail), DeviceWireMessage(id: UUID(), role: "assistant", text: "Reply" + tail)]
            let parent = PadTranscript(messages: messages, draft: "Draft\nsecond line\n", images: [:], editable: true, lineNumbers: true, edit: { _ in }, send: {}, attach: { _ in })
            let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 700, height: 400)
            parent.update(view, coordinator: PadTranscript.Coordinator(parent))
            XCTAssertEqual(view.textStorage.string, "Prompt\nReply\nDraft\nsecond line\n", tail.debugDescription)
            XCTAssertEqual((view.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing, TranscriptStyle.blockSpacing)
            XCTAssertEqual(messages[0].text, "Prompt" + tail)
        }
    }
    func testDraftImageRemoveButtonPreservesHistoryAndText() throws {
        let service = try service(), model = PadModel(service: service)
        let id = DeviceGlobalID(home: "test-home", session: UUID()).string
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 100)).image { context in UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 100)) }
        let file = service.storageFolder.appendingPathComponent("draft-preview.png")
        try XCTUnwrap(image.pngData()).write(to: file)
        service.remoteLeases[id] = 1
        model.state.drafts[id] = PadDraft(text: "Keep this text", hashes: ["one", "two"], dirty: true)
        let historical = DeviceWireMessage(id: UUID(), role: "assistant", text: "Historical image", imageHashes: ["one"])
        var parent = PadTranscript(messages: [historical], draft: model.draft(id).text, images: ["one": file, "two": file], draftImageHashes: model.draft(id).hashes, editable: true, lineNumbers: true, edit: { model.edit(id, text: $0) }, send: {}, attach: { _ in }, removeImage: { model.removeImage(id, hash: $0) })
        let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let coordinator = PadTranscript.Coordinator(parent); view.delegate = coordinator
        parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.draftImageButtons.count, 2, "The historical image has no X")
        XCTAssertEqual(view.textStorage.string.filter { $0 == "\u{fffc}" }.count, 3)
        view.selectedRange = NSRange(location: view.historyLength + 3, length: 0)
        let button = try XCTUnwrap(view.draftImageButtons.first)
        XCTAssertFalse(button.isHidden); XCTAssertGreaterThan(button.frame.minX, 100)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(model.draft(id).hashes, ["two"]); XCTAssertEqual(model.draft(id).text, "Keep this text")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(PadModel(service: service).draft(id).hashes, ["two"], "Deletion is persisted before network sync")
        parent.draftImageHashes = model.draft(id).hashes
        parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.draftImageButtons.count, 1)
        XCTAssertEqual(view.selectedRange.location, view.historyLength + 3)
        XCTAssertEqual(view.textStorage.string.filter { $0 == "\u{fffc}" }.count, 2)
        parent.editable = false; parent.update(view, coordinator: coordinator)
        XCTAssertTrue(view.draftImageButtons.allSatisfy(\.isHidden))
    }
    func testUnloadedImageCaptionRemainsClickable() {
        let url = URL(string: "https://upload.wikimedia.org/example.jpg")!
        let rendered = PadTranscript.render("![Grasshopper](" + url.absoluteString + ")")
        XCTAssertEqual(rendered.string, "Grasshopper")
        XCTAssertEqual(rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL, url)
        XCTAssertEqual(TranscriptStyle.imageLinks("`![example](https://example.com/a.png)`"), "`![example](https://example.com/a.png)`")
    }
    func testUnalignedCoalescedFrames() throws {
        var first = DeviceEnvelope(kind: "odd")
        while try DeviceFrame.encode(first).count % 4 == 0 { first.kind += "x" }
        let second = DeviceEnvelope(kind: "next")
        let bytes = try DeviceFrame.encode(first) + DeviceFrame.encode(second)
        var decoder = DeviceFrameDecoder()
        XCTAssertEqual(try decoder.append(bytes), [first, second])
    }
    func testOfflineDraftSurvivesModelRecreationWithoutSending() throws {
        let service = try service()
        let model = PadModel(service: service)
        let id = DeviceGlobalID(home: "test-home", session: UUID()).string
        model.edit(id, text: "unacknowledged draft 😀")
        let restored = PadModel(service: service)
        XCTAssertEqual(restored.draft(id).text, "unacknowledged draft 😀")
        XCTAssertTrue(restored.draft(id).dirty)
        XCTAssertFalse(restored.canSend(id))
        XCTAssertTrue(service.outbox.isEmpty)
    }
    func testBlockMarkdownForAgentReports() {
        let rendered = PadTranscript.render("### Status\n| Session | Status |\n|---|---|\n| Steward | **Ready** |\n- Done\n```\n### literal\n```")
        XCTAssertFalse(rendered.string.contains("### Status"))
        XCTAssertFalse(rendered.string.contains("|---|"))
        XCTAssertTrue(rendered.string.contains("Session: Steward"))
        XCTAssertTrue(rendered.string.contains("Status: Ready"))
        XCTAssertTrue(rendered.string.contains("• Done"))
        XCTAssertTrue(rendered.string.contains("### literal"))
        XCTAssertTrue((rendered.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }
    func testBackgroundDropsLeasesAndForegroundDoesNotAcquire() throws {
        let service = try service(); let model = PadModel(service: service)
        let id = DeviceGlobalID(home: "test-home", session: UUID()).string
        model.state.placements[0] = id; service.remoteLeases[id] = 42
        model.edit(id, text: "keep this")
        model.background()
        XCTAssertTrue(service.remoteLeases.isEmpty)
        XCTAssertEqual(model.state.placements[0], id)
        model.foreground()
        XCTAssertTrue(service.remoteLeases.isEmpty)
        XCTAssertEqual(model.draft(id).text, "keep this")
        XCTAssertFalse(model.canControl(id))
    }
    func testPinIsLayoutOnlyAndRestoresSavedWidth() throws {
        let service = try service(); let model = PadModel(service: service)
        let id = DeviceGlobalID(home: "test-home", session: UUID()).string
        model.state.placements[1] = id; service.remoteLeases[id] = 7
        model.state.sidebarWidth = 287; model.state.sidebarHidden = true; model.persist()
        XCTAssertEqual(service.remoteLeases[id], 7)
        let restored = PadModel(service: service)
        XCTAssertEqual(restored.state.sidebarWidth, 287)
        XCTAssertTrue(restored.state.sidebarHidden)
        XCTAssertEqual(restored.state.placements[1], id)
        XCTAssertEqual(PadLayout.sidebarWidth(preferred: 287, available: 320), 160)
        XCTAssertEqual(PadLayout.sidebarWidth(preferred: 287, available: 1024), 287)
        XCTAssertEqual(restored.state.sidebarWidth, 287, "Rotation clamp never overwrites the chosen width")
    }
    func testPNGNormalizationBoundsDimensionsAndStripsOriginalBytes() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let data = try PadImage.normalize(jpeg)
        XCTAssertEqual(Array(data.prefix(8)), [137,80,78,71,13,10,26,10])
        XCTAssertLessThanOrEqual(data.count, PadImage.byteLimit)
        let normalized = try XCTUnwrap(UIImage(data: data))
        XCTAssertLessThanOrEqual(max(normalized.size.width, normalized.size.height), 2048)
        XCTAssertThrowsError(try PadImage.normalize(Data("invalid".utf8)))
    }
    func testProtectedHistoryAndReturnSemantics() {
        var edits = ""; var sends = 0
        let parent = PadTranscript(messages: [], draft: "draft", images: [:], editable: true, lineNumbers: false, edit: { edits = $0 }, send: { sends += 1 }, attach: { _ in })
        let coordinator = PadTranscript.Coordinator(parent)
        let view = TailTextView(); view.text = "history\ndraft"; coordinator.historyLength = 8
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 0, length: 1), replacementText: "x"))
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 13, length: 0), replacementText: "\n"))
        XCTAssertEqual(sends, 1)
        view.insertingNewline = true
        XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 13, length: 0), replacementText: "\n"))
        coordinator.textViewDidChange(view); XCTAssertEqual(edits, "draft")
        coordinator.parent.editable = false
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 13, length: 0), replacementText: "x"))
    }
    func testSnapshotEchoPreservesDraftSelectionAndOrangeStyle() {
        let first = DeviceWireMessage(id: UUID(), role: "assistant", text: "First reply")
        var parent = PadTranscript(messages: [first], draft: "tell Muse hello", images: [:], editable: true, lineNumbers: true, edit: { _ in }, send: {}, attach: { _ in })
        let coordinator = PadTranscript.Coordinator(parent)
        let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        view.delegate = coordinator
        parent.update(view, coordinator: coordinator)
        view.selectedRange = NSRange(location: coordinator.historyLength + 5, length: 4)
        parent.messages.append(DeviceWireMessage(id: UUID(), role: "assistant", text: "Another reply"))
        parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.selectedRange, NSRange(location: coordinator.historyLength + 5, length: 4))
        XCTAssertEqual((view.text as NSString).substring(from: coordinator.historyLength), "tell Muse hello")
        XCTAssertEqual(view.textStorage.attribute(.foregroundColor, at: coordinator.historyLength, effectiveRange: nil) as? UIColor, PadPalette.traffic)
        XCTAssertTrue(view.gutter.isHidden == false)
    }
    func testNativeReturnSendsWithoutInsertingLineBreaks() {
        for key in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"] {
            var sends = 0
            let parent = PadTranscript(messages: [], draft: "draft", images: [:], editable: true, lineNumbers: true, edit: { _ in }, send: { sends += 1 }, attach: { _ in })
            let coordinator = PadTranscript.Coordinator(parent)
            let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 700, height: 300); view.delegate = coordinator
            parent.update(view, coordinator: coordinator)
            view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
            view.insertText(key)
            XCTAssertEqual(sends, 1, key.debugDescription)
            XCTAssertEqual(view.text, "draft", "Return must never insert a blank paragraph")
            view.insertingNewline = true; view.insertText("\n"); view.insertingNewline = false
            XCTAssertEqual(view.text, "draft\n", "Command-Return inserts exactly one newline")
            XCTAssertEqual(sends, 1)
            view.hardwareReturn(modifiers: [])
            XCTAssertEqual(sends, 2, "Hardware Return has a direct Send command")
            view.isEditable = false; view.insertText(key); view.hardwareReturn(modifiers: [])
            XCTAssertEqual(sends, 2, "An offline or read-only pane cannot send")
            XCTAssertEqual(view.text, "draft\n")
        }
    }
    func testInitialHistoryWaitsForLayoutAndFollowsTailWithoutAnimation() {
        var parent = PadTranscript(messages: [DeviceWireMessage(id: UUID(), role: "assistant", text: String(repeating: "A long transcript line.\n", count: 120))], draft: "draft", images: [:], editable: true, lineNumbers: true, edit: { _ in }, send: {}, attach: { _ in })
        let coordinator = PadTranscript.Coordinator(parent)
        let view = TailTextView.native(); view.delegate = coordinator
        parent.update(view, coordinator: coordinator)
        view.frame = CGRect(x: 0, y: 0, width: 700, height: 300); view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertEqual(view.contentOffset.y, view.contentSize.height - view.bounds.height, accuracy: 1, "Initial transcript opens at its tail after the view has a real size")
        parent.messages.append(DeviceWireMessage(id: UUID(), role: "assistant", text: String(repeating: "Streaming update\n", count: 10)))
        parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.contentOffset.y, view.contentSize.height - view.bounds.height, accuracy: 1, "Tail following completes synchronously rather than queuing a scroll animation")
        view.frame.size.height = 180; view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertEqual(view.contentOffset.y, view.contentSize.height - view.bounds.height, accuracy: 1, "Keyboard resizing retains the tail when already following it")
    }
    func testTranscriptRelayoutWithoutTypingAfterSheetSizedBounds() {
        let parent = PadTranscript(messages: [DeviceWireMessage(id: UUID(), role: "assistant", text: String(repeating: "History stays visible after setup.\n", count: 80))], draft: "unchanged draft", images: [:], editable: true, lineNumbers: true, edit: { _ in }, send: {}, attach: { _ in })
        let coordinator = PadTranscript.Coordinator(parent)
        let view = TailTextView.native(); view.delegate = coordinator
        view.frame = CGRect(x: 0, y: 0, width: 700, height: 450)
        parent.update(view, coordinator: coordinator)
        let original = view.textStorage.string
        for size in [CGSize(width: 320, height: 180), .zero, CGSize(width: 700, height: 450)] {
            view.frame.size = size; view.setNeedsLayout(); view.layoutIfNeeded()
            parent.update(view, coordinator: coordinator)
        }
        XCTAssertFalse(view.layoutManager.allowsNonContiguousLayout)
        XCTAssertEqual(view.textStorage.string, original)
        XCTAssertGreaterThan(view.layoutManager.numberOfGlyphs, 100)
        let visible = view.layoutManager.glyphRange(forBoundingRect: CGRect(x: 0, y: view.contentOffset.y, width: view.bounds.width, height: view.bounds.height), in: view.textContainer)
        XCTAssertGreaterThan(visible.length, 0, "A restored pane lays out visible history without a draft edit")
    }
    func testClipboardPasteUsesClipboardAndLeavesHistoryAlone() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 9, height: 7)).image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 9, height: 7)) }
        UIPasteboard.general.image = image
        defer { UIPasteboard.general.items = [] }
        var attached: Data?
        let parent = PadTranscript(messages: [], draft: "Keep draft", images: [:], editable: true, lineNumbers: false, edit: { _ in }, send: {}, attach: { attached = $0 })
        let coordinator = PadTranscript.Coordinator(parent)
        let view = TailTextView.native(); view.delegate = coordinator
        parent.update(view, coordinator: coordinator)
        let before = view.textStorage.string
        XCTAssertFalse(UIPasteboard.general.hasStrings)
        XCTAssertTrue(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil), "Image-only clipboard enables context-menu and Command-V Paste")
        XCTAssertTrue(UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.paste(_:)), to: view, from: nil, for: nil))
        let pasted = try XCTUnwrap(attached.flatMap(UIImage.init(data:)))
        XCTAssertEqual(pasted.cgImage?.width, image.cgImage?.width)
        XCTAssertEqual(pasted.cgImage?.height, image.cgImage?.height)
        XCTAssertEqual(view.textStorage.string, before)
        view.isEditable = false
        XCTAssertFalse(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil), "A displaced viewer cannot paste")
    }
    func testSystemPasteProviderPreservesImageAndDraft() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 19, height: 13)).image { c in UIColor.green.setFill(); c.fill(CGRect(x: 0, y: 0, width: 19, height: 13)) }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(image.pngData(), nil); return nil
        }
        var attached: Data?
        let parent = PadTranscript(messages: [], draft: "Keep this", images: [:], editable: true, lineNumbers: false, edit: { _ in }, send: {}, attach: { attached = $0 })
        let coordinator = PadTranscript.Coordinator(parent)
        let view = TailTextView.native(); view.delegate = coordinator
        parent.update(view, coordinator: coordinator)
        XCTAssertTrue(view.canPaste([provider]))
        XCTAssertTrue(view.pasteConfiguration?.acceptableTypeIdentifiers.contains(UTType.image.identifier) == true)
        view.paste(itemProviders: [provider])
        try await eventually("System paste provider attaches asynchronously") { attached != nil }
        let result = try XCTUnwrap(attached.flatMap(UIImage.init(data:)))
        XCTAssertEqual(result.cgImage?.width, image.cgImage?.width); XCTAssertEqual(result.cgImage?.height, image.cgImage?.height)
        XCTAssertEqual(view.textStorage.string, "Keep this")
    }
    func testFollowResumesAfterFiveIdleSecondsAndHonorsSelectionAndTake() {
        var clock: TimeInterval = 100
        var parent = PadTranscript(messages: [DeviceWireMessage(id: UUID(), role: "assistant", text: String(repeating: "Long history\n", count: 150))], draft: "draft", images: [:], editable: true, lineNumbers: true, displayEpoch: 1, edit: { _ in }, send: {}, attach: { _ in })
        let coordinator = PadTranscript.Coordinator(parent); coordinator.now = { clock }
        let view = TailTextView.native(); view.delegate = coordinator
        view.frame = CGRect(x: 0, y: 0, width: 700, height: 300)
        parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.selectedRange.location, view.textStorage.length, "Startup places the implicit cursor at the tail")
        view.setContentOffset(CGPoint(x: 0, y: 100), animated: false); coordinator.recordScroll(view)
        clock += 4; coordinator.resumeIfIdle()
        XCTAssertEqual(view.contentOffset.y, 100, accuracy: 1)
        clock += 1; coordinator.resumeIfIdle()
        XCTAssertEqual(view.contentOffset.y, view.contentSize.height - view.bounds.height, accuracy: 1)
        view.selectedRange = NSRange(location: 10, length: 5)
        coordinator.textViewDidChangeSelection(view)
        view.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
        clock += 10; coordinator.resumeIfIdle()
        XCTAssertEqual(view.contentOffset.y, 100, accuracy: 1, "An explicit selection holds reading position indefinitely")
        parent.displayEpoch = 2; parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.contentOffset.y, 100, accuracy: 1, "Take does not discard deliberate selection")
        view.selectedRange = NSRange(location: view.textStorage.length, length: 0); coordinator.textViewDidChangeSelection(view)
        parent.displayEpoch = 3; parent.update(view, coordinator: coordinator); view.layoutIfNeeded()
        XCTAssertEqual(view.contentOffset.y, view.contentSize.height - view.bounds.height, accuracy: 1, "Take scrolls an existing pane even without new transcript text")
    }
    func testReadingPositionSurvivesAppendAndEarlierHistory() {
        let messages = (0..<70).map { DeviceWireMessage(id: UUID(), role: "assistant", text: "Reply \($0): " + String(repeating: "readable text ", count: 14)) }
        var parent = PadTranscript(messages: messages, draft: "", images: [:], editable: true, lineNumbers: true, edit: { _ in }, send: {}, attach: { _ in })
        let coordinator = PadTranscript.Coordinator(parent)
        let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 700, height: 300); view.delegate = coordinator
        parent.update(view, coordinator: coordinator)
        view.selectedRange = NSRange(location: 0, length: 0)
        view.setContentOffset(CGPoint(x: 0, y: 520), animated: false)
        let oldOffset = view.contentOffset.y
        parent.messages.append(DeviceWireMessage(id: UUID(), role: "assistant", text: "A streamed update"))
        parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.contentOffset.y, oldOffset, accuracy: 1, "An update below the reader must not move the viewport")
        let before = view.layoutManager.characterIndexForGlyph(at: view.layoutManager.glyphIndex(for: CGPoint(x: 0, y: view.contentOffset.y - view.textContainerInset.top), in: view.textContainer))
        let visibleText = (view.text as NSString).substring(with: NSRange(location: before, length: min(30, view.textStorage.length - before)))
        parent.messages.insert(DeviceWireMessage(id: UUID(), role: "user", text: String(repeating: "Earlier history ", count: 90)), at: 0)
        parent.update(view, coordinator: coordinator)
        let after = view.layoutManager.characterIndexForGlyph(at: view.layoutManager.glyphIndex(for: CGPoint(x: 0, y: view.contentOffset.y - view.textContainerInset.top), in: view.textContainer))
        XCTAssertEqual((view.text as NSString).substring(with: NSRange(location: after, length: min(30, view.textStorage.length - after))), visibleText, "Loading earlier history keeps the same text at the top")
    }
    func testNativeReplacementAndCommandReturn() {
        var sends = 0; var edited = ""
        let parent = PadTranscript(messages: [], draft: "draft", images: [:], editable: true, lineNumbers: true, edit: { edited = $0 }, send: { sends += 1 }, attach: { _ in })
        let coordinator = PadTranscript.Coordinator(parent)
        let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 700, height: 300); view.delegate = coordinator
        parent.update(view, coordinator: coordinator)
        view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
        let commandReturn = view.keyCommands!.first { $0.input == "\r" && $0.modifierFlags == .command }!
        view.perform(commandReturn.action, with: commandReturn)
        XCTAssertEqual(view.text, "draft\n", "Dispatch the actual Command-Return selector")
        XCTAssertEqual(edited, "draft\n", "Command-Return must update the synced draft, not only the native view")
        XCTAssertEqual(sends, 0)
        let caret = view.textRange(from: view.endOfDocument, to: view.endOfDocument)!
        view.replace(caret, withText: "\n\n")
        XCTAssertEqual(sends, 1, "UIKit replacement of a paragraph break sends once")
        XCTAssertEqual(view.text, "draft\n", "UIKit replacement must not append blank lines")
        view.hardwareReturn(modifiers: .shift)
        XCTAssertEqual(edited, "draft\n\n", "Shift-Return uses the same explicit newline semantics")
        XCTAssertEqual(sends, 1)
    }
    func testToolActivityNeverAppearsInTheConversationDocument() {
        let parent = PadTranscript(messages: [DeviceWireMessage(id: UUID(), role: "user", text: "Show a grasshopper"), DeviceWireMessage(id: UUID(), role: "activity", text: "Using Bash"), DeviceWireMessage(id: UUID(), role: "assistant", text: "Here is the photo"), DeviceWireMessage(id: UUID(), role: "activity", text: "/bin/zsh -lc private-command")], draft: "", images: [:], editable: true, lineNumbers: true, edit: { _ in }, send: {}, attach: { _ in })
        let coordinator = PadTranscript.Coordinator(parent)
        let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 700, height: 300)
        parent.update(view, coordinator: coordinator)
        XCTAssertFalse(view.text.contains("Using Bash")); XCTAssertFalse(view.text.contains("private-command"))
        XCTAssertTrue(view.text.contains("Here is the photo"))
    }
    func testFreshLeasePreservesConflictingRecoveredDraftUntilChoice() throws {
        let service = try service(); let model = PadModel(service: service)
        let id = DeviceGlobalID(home: "test-home", session: UUID()).string
        model.edit(id, text: "my offline edit")
        service.remoteLeases[id] = 3
        service.remoteTranscripts[id] = DeviceTranscriptPayload(globalID: id, homeSeq: 1, epoch: 3, messages: [], draft: "home edit", draftVersion: 6, busy: false, status: "Ready")
        model.reconcile()
        XCTAssertEqual(model.draft(id).text, "my offline edit")
        XCTAssertTrue(model.conflicts.contains(id))
        XCTAssertFalse(model.canSend(id))
        model.resolveDraft(id, keepLocal: false)
        XCTAssertEqual(model.draft(id).text, "home edit")
        XCTAssertFalse(model.conflicts.contains(id))
    }
    func testLateCompletionPreservesNewTyping() throws {
        let service = try service(); let model = PadModel(service: service)
        let id = DeviceGlobalID(home: "test-home", session: UUID()).string
        service.remoteLeases[id] = 3
        service.remoteTranscripts[id] = DeviceTranscriptPayload(globalID: id, homeSeq: 1, epoch: 3, messages: [], draft: "", draftVersion: 1, busy: true, status: "Working")
        model.reconcile()
        let command = UUID()
        model.state.drafts[id] = PadDraft(text: "new typing", sentID: command, sentText: "old send")
        service.completedCommands.insert(command); model.reconcile()
        XCTAssertEqual(model.draft(id).text, "new typing")
        XCTAssertNil(model.draft(id).sentID)
    }
    func testFailedSendRestoreKeepsNewerTextAndImages() throws {
        for outcome in ["failed", "rejected"] {
            let service = try service(); let model = PadModel(service: service)
            let id = DeviceGlobalID(home: "test-home", session: UUID()).string
            let record = DeviceOutboxRecord(commandID: UUID(), sessionID: id, payload: DeviceCommandPayload(action: "submit", text: "old send", blobHashes: ["old-image"]), payloadHash: "fixture", outcome: outcome)
            model.state.drafts[id] = PadDraft(text: "new typing", hashes: ["new-image"], sentID: record.commandID, sentText: "old send", sentHashes: ["old-image"])
            model.discard(record, restore: true)
            XCTAssertEqual(model.draft(id).text, "new typing", outcome)
            XCTAssertEqual(model.draft(id).hashes, ["new-image"], outcome)
            XCTAssertNil(model.draft(id).sentID)
            XCTAssertEqual(PadModel(service: service).draft(id).text, "new typing", "Preserved edits survive relaunch")
        }
    }
    func testFailedSendRestoreFillsEmptyOrUnchangedComposerOnly() throws {
        let service = try service(); let model = PadModel(service: service)
        let id = DeviceGlobalID(home: "test-home", session: UUID()).string
        let record = DeviceOutboxRecord(commandID: UUID(), sessionID: id, payload: DeviceCommandPayload(action: "submit", text: "old send", blobHashes: ["old-image"]), payloadHash: "fixture", outcome: "failed")
        model.discard(record, restore: true)
        XCTAssertEqual(model.draft(id).text, "old send")
        XCTAssertEqual(model.draft(id).hashes, ["old-image"])
        model.state.drafts[id]?.sentID = record.commandID
        model.discard(record, restore: true)
        XCTAssertEqual(model.draft(id).text, "old send")
        XCTAssertEqual(model.draft(id).hashes, ["old-image"])
        XCTAssertNil(model.draft(id).sentID, "Restoring unchanged submitted content clears its pending marker")
        model.state.drafts[id] = PadDraft(text: "old send", hashes: ["new-image"], sentID: record.commandID, sentText: "old send", sentHashes: ["old-image"])
        model.discard(record, restore: true)
        XCTAssertEqual(model.draft(id).hashes, ["new-image"], "An attachment-only edit counts as newer typing")
        model.state.drafts[id] = PadDraft(text: "", hashes: ["new-image"])
        model.discard(record, restore: true)
        XCTAssertEqual(model.draft(id).text, "", "An image-only draft must not be replaced")
        XCTAssertEqual(model.draft(id).hashes, ["new-image"])
    }
    func testHelpLoadsSharedSchemaAndSearch() throws {
        let book = try HelpBook.load()
        XCTAssertEqual(book.schemaVersion, 1)
        XCTAssertFalse(book.search("pair").isEmpty)
        XCTAssertEqual(book.sourceSHA256.count, 64)
    }
    func eventually(_ description: String, timeout: TimeInterval = 10, _ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), description)
        if !predicate() { throw CocoaError(.coderValueNotFound) }
    }
    func testInterruptedImageUploadRecoversAfterBackgroundAndCacheReload() async throws {
        guard let port = ProcessInfo.processInfo.environment["CONVERSE_INTEROP_PORT"].flatMap(Int.init), port > 0 else { throw XCTSkip("Run iPad/test.sh --interop with an isolated Mac home") }
        let service = try service(); defer { service.suspendViewer() }
        try service.startNetworkForTesting(); service.connectManual(host: "127.0.0.1", port: port)
        try await eventually("Pair isolated home") { service.pairingPrompt != nil }
        service.confirmPairing()
        try await eventually("Load home directory") { service.homes.values.contains { !$0.rows.isEmpty } }
        let row = try XCTUnwrap(service.homes.values.flatMap(\.rows).first)
        var model: PadModel? = PadModel(service: service)
        model!.state.placements[0] = row.globalID
        service.acquireRemote(globalID: row.globalID)
        try await eventually("Take initial lease") { service.remoteTranscripts[row.globalID] != nil }
        model!.reconcile()
        let firstEpoch = try XCTUnwrap(service.remoteLeases[row.globalID])
        let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { context in UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 48, height: 48)) }
        let png = try PadImage.normalize(try XCTUnwrap(image.pngData()))
        let hash = DeviceBlob.sha256Hex(png)
        let folder = service.storageFolder.appendingPathComponent("RemoteCache")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cached = folder.appendingPathComponent(hash + ".png"); try png.write(to: cached, options: .atomic)
        service.blobCache[hash] = cached
        var draft = model!.draft(row.globalID); draft.hashes = [hash]; draft.dirty = true
        model!.state.drafts[row.globalID] = draft; model!.persist()
        service.saveDraftAttachments(globalID: row.globalID, hashes: [hash])
        XCTAssertTrue(service.sendPartialBlobForTesting(globalID: row.globalID, data: png))
        XCTAssertFalse(model!.canSend(row.globalID))
        // Ensure the TCP stream delivered the prefix before canceling it.
        // A subsequent rename ack is ordered after that blob chunk at home.
        let barrier = try XCTUnwrap(service.sendRemoteCommand(globalID: row.globalID, command: DeviceCommandPayload(action: "rename", text: row.title)))
        try await eventually("Home has consumed the partial upload") { service.completedCommands.contains(barrier) }
        model!.background(); model = nil
        service.blobCache = [:] // Simulate losing the in-memory cache index on relaunch.
        let restored = PadModel(service: service)
        XCTAssertEqual(restored.draft(row.globalID).hashes, [hash])
        try service.startNetworkForTesting(); service.connectManual(host: "127.0.0.1", port: port)
        try await eventually("Trusted home reconnects") { service.homes[DeviceGlobalID(row.globalID)!.home]?.online == true }
        try await eventually("Saved iPad pane restores automatically after background without Take") { (service.remoteLeases[row.globalID] ?? 0) > firstEpoch && service.remoteTranscripts[row.globalID] != nil }
        restored.reconcile()
        try await eventually("Cached PNG is resent and verified on home") { service.blobReady[hash] == true }
        XCTAssertEqual(service.blobCache[hash], cached, "Recovery rediscovers the verified file without an in-memory cache index")
        if restored.conflicts.contains(row.globalID) { restored.resolveDraft(row.globalID, keepLocal: true) }
        try await eventually("Recovered draft can be sent") { restored.canSend(row.globalID) }
        XCTAssertEqual(restored.draft(row.globalID).hashes, [hash], "Recovery never appends a duplicate attachment")
        restored.clearImages(row.globalID)
        restored.edit(row.globalID, text: "home draft"); restored.flush(row.globalID)
        try await eventually("Fixture restored for other interop checks") { service.remoteTranscripts[row.globalID]?.draft == "home draft" && service.remoteTranscripts[row.globalID]?.draftImageHashes == [] }
    }
    func testMacHomeInteroperability() async throws {
        guard let port = ProcessInfo.processInfo.environment["CONVERSE_INTEROP_PORT"].flatMap(Int.init), port > 0 else { throw XCTSkip("Run iPad/test.sh --interop with an isolated Mac home") }
        let service = try service(); defer { service.suspendViewer() }
        try service.startNetworkForTesting()
        service.connectManual(host: "127.0.0.1", port: port)
        try await eventually("Mac offers authenticated pairing") { service.pairingPrompt != nil }
        let code = try XCTUnwrap(service.pairingPrompt?.code)
        XCTAssertEqual(code.split(separator: " ").count, 8)
        service.confirmPairing()
        try await eventually("Mac sidebar is published after mutual confirmation") { service.homes.values.contains { !$0.rows.isEmpty } }
        let row = try XCTUnwrap(service.homes.values.flatMap(\.rows).first)
        service.isPlaced = { $0 == row.globalID }
        service.acquireRemote(globalID: row.globalID)
        try await eventually("iPad receives fresh draft and transcript") { service.remoteTranscripts[row.globalID] != nil }
        XCTAssertEqual(service.remoteTranscripts[row.globalID]?.draft, "home draft")
        XCTAssertTrue(service.remoteTranscripts[row.globalID]?.messages.first?.text.contains(code) == true, "Both platform handshakes show the same verification code")
        let replyHash = try XCTUnwrap(service.remoteTranscripts[row.globalID]?.messages.first?.imageHashes.first)
        service.fetchBlob(globalID: row.globalID, hash: replyHash)
        try await eventually("Returned Mac image downloads to iPad") { service.blobCache[replyHash] != nil }
        let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 700, height: 400)
        let parent = PadTranscript(messages: try XCTUnwrap(service.remoteTranscripts[row.globalID]?.messages), draft: "", images: service.blobCache, editable: false, lineNumbers: true, edit: { _ in }, send: {}, attach: { _ in })
        parent.update(view, coordinator: PadTranscript.Coordinator(parent))
        XCTAssertTrue(view.textStorage.string.contains("\u{fffc}"), "Mac reply image is a native inline attachment on iPad")
        let model = PadModel(service: service); model.state.placements[0] = row.globalID; model.reconcile()
        model.edit(row.globalID, text: "from iPad")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40)) }
        model.attach(row.globalID, data: try XCTUnwrap(image.pngData()))
        let hash = try XCTUnwrap(model.draft(row.globalID).hashes.first)
        // Edit again while the image is in flight; blob completion must flush
        // the current text even if the normal debounce already ran.
        model.edit(row.globalID, text: "from iPad with image")
        model.flush(row.globalID)
        try await eventually("Converted PNG is verified and stored on Mac") { service.blobReady[hash] == true }
        try await eventually("Latest draft and attachment sync after upload") {
            service.remoteTranscripts[row.globalID]?.draft == "from iPad with image" && service.remoteTranscripts[row.globalID]?.draftImageHashes == [hash]
        }
        model.removeImage(row.globalID, hash: hash)
        try await eventually("Removing one image synchronizes to the Mac draft without changing text") {
            service.remoteTranscripts[row.globalID]?.draft == "from iPad with image" && service.remoteTranscripts[row.globalID]?.draftImageHashes == []
        }
        XCTAssertNotNil(service.blobCache[hash], "Removing a draft reference does not delete an image used in history")
        model.attach(row.globalID, data: try XCTUnwrap(image.pngData()))
        try await eventually("The same image can be attached again without a stale removal") {
            service.remoteTranscripts[row.globalID]?.draftImageHashes == [hash]
        }
        model.send(row.globalID)
        let command = try XCTUnwrap(model.draft(row.globalID).sentID)
        try await eventually("Mac acknowledges the queued send") { service.completedCommands.contains(command) }
        try await eventually("Mac publishes exactly one queued message") { service.remoteTranscripts[row.globalID]?.pending.count == 1 }
        XCTAssertEqual(service.remoteTranscripts[row.globalID]?.pending.first?.text, "from iPad with image")
        service.sendRemoteCommand(globalID: row.globalID, command: DeviceCommandPayload(action: "rename", text: "Renamed from iPad"))
        try await eventually("Rename reaches home and sidebar") { service.remoteTranscripts[row.globalID]?.title == "Renamed from iPad" }
        service.releaseRemote(globalID: row.globalID)
        XCTAssertNil(service.remoteLeases[row.globalID])
        service.acquireRemote(globalID: row.globalID)
        try await eventually("Parked iPad can reacquire without replaying") { service.remoteTranscripts[row.globalID]?.pending.count == 1 && service.remoteLeases[row.globalID] != nil }
        service.releaseRemote(globalID: row.globalID)
        let teaching = try XCTUnwrap(service.sendRemoteCommand(globalID: row.globalID, command: DeviceCommandPayload(action: "teachSwitchboard")))
        try await eventually("Parked session teaching reaches Mac") { service.completedCommands.contains(teaching) }
        XCTAssertNil(service.remoteLeases[row.globalID], "Teaching must not take the session away from another device")
        service.acquireRemote(globalID: row.globalID)
        try await eventually("Teaching instructions are visible on home") { service.remoteTranscripts[row.globalID]?.pending.contains { $0.text.hasPrefix("[Converse switchboard instructions]") } == true }
    }

}
