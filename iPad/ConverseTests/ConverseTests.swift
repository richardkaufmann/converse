import XCTest
import SwiftUI
import Network
@testable import Converse

@MainActor
final class ConverseTests: XCTestCase {
    func service() throws -> DeviceSyncService {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("converse-ipad-tests-" + UUID().uuidString)
        let service = DeviceSyncService(); try service.configureForTesting(folder: folder)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return service
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
    }

}
