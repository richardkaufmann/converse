import XCTest
import SwiftUI
import Network
import CryptoKit
import UniformTypeIdentifiers
@testable import Converse

@MainActor
final class ConverseTests: XCTestCase {
    func testPerformanceCaptureMatchesReceiptsAndKeepsTimingsPrivate() {
        performanceCaptureSelfTests { passed, description in XCTAssertTrue(passed, description) }
    }
    func testCopySelectionPreservesLinkDestinations() {
        let view = TailTextView()
        let text = NSMutableAttributedString(string: "References: Café 🐈 and https://example.com")
        text.addAttribute(.link, value: URL(string: "https://example.com/docs")!, range: NSRange(location: 12, length: 7))
        let last = (text.string as NSString).range(of: "https://example.com")
        text.addAttribute(.link, value: URL(string: "https://example.com")!, range: last)
        view.attributedText = text; view.selectedRange = NSRange(location: 0, length: text.length)
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "References: Café 🐈 (https://example.com/docs) and https://example.com")
        view.selectedRange = NSRange(location: 12, length: 4); view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "Café (https://example.com/docs)")
    }
    func testParkingLotLinksMatchMacAndKeepFileLinksPlain() {
        let styled = LotStyle.linked("See [the repo](https://github.com/x/y), https://x.com/a. and /Users/me/a.txt")
        XCTAssertEqual(String(styled.characters), "See the repo, https://x.com/a. and /Users/me/a.txt")
        XCTAssertEqual(styled.runs.compactMap(\.link), [URL(string: "https://github.com/x/y")!, URL(string: "https://x.com/a")!])
        XCTAssertTrue(LotStyle.linked("[x](javascript:alert(1))").runs.allSatisfy { $0.link == nil })
    }
    func testPhonePaneCollapseKeepsEditorAndKeyboardFocus() async throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let service = try service(), model = PadModel(service: service)
        let home = String(repeating: "a", count: 64)
        let ids = (0..<2).map { _ in DeviceGlobalID(home: home, session: UUID()).string }
        for (index, id) in ids.enumerated() {
            model.state.placements[index] = id
            model.state.drafts[id] = PadDraft(text: "Stable draft \(index)", dirty: true)
            service.remoteLeases[id] = UInt64(index + 1)
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIHostingController(rootView: PadRoot(model: model)); window.rootViewController = host
        window.makeKeyAndVisible()
        defer { model.phoneKeyboard.hide(); window.isHidden = true }
        func editors(_ root: UIView) -> [TailTextView] {
            (root as? TailTextView).map { [$0] } ?? root.subviews.flatMap { editors($0) }
        }
        try await Task.sleep(for: .milliseconds(200)); host.view.layoutIfNeeded()
        let original = editors(host.view)
        let first = try XCTUnwrap(original.first { $0.text.contains("Stable draft 0") })
        let second = try XCTUnwrap(original.first { $0.text.contains("Stable draft 1") })
        model.phoneKeyboard.show(ids[0])
        try await Task.sleep(for: .milliseconds(200)); host.view.layoutIfNeeded()
        XCTAssertTrue(first.isFirstResponder)
        XCTAssertTrue(editors(host.view).contains { $0 === second }, "Collapsed editor must remain mounted")
        second.prepareKeyboardTouch(at: .zero)
        try await Task.sleep(for: .milliseconds(200)); host.view.layoutIfNeeded()
        XCTAssertTrue(second.isFirstResponder, "Focus must survive SwiftUI collapse and expansion")
        XCTAssertTrue(editors(host.view).contains { $0 === first })
        XCTAssertEqual(model.phoneKeyboard.target, ids[1])
        XCTAssertEqual(second.keyboardDismissMode, .none)
        model.phoneKeyboard.hide()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(second.isFirstResponder)
        XCTAssertEqual(model.draft(ids[0]).text, "Stable draft 0")
        XCTAssertEqual(model.draft(ids[1]).text, "Stable draft 1")
    }
    func testPhoneRotationWithKeyboardPreservesFullWidthAndDraft() async throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("Phone rotation acceptance fixture") }
        let service = try service(), model = PadModel(service: service)
        let home = String(repeating: "b", count: 64)
        let ids = (0..<2).map { _ in DeviceGlobalID(home: home, session: UUID()).string }
        for (index, id) in ids.enumerated() {
            model.state.placements[index] = id
            model.state.drafts[id] = PadDraft(text: "Rotation draft \(index)", dirty: true)
            service.remoteLeases[id] = UInt64(index + 1)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: PadRoot(model: model))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { model.phoneKeyboard.hide(); window.isHidden = true; scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in XCTFail("Initial portrait request failed: \(error)") }
        try await eventually("Rotation fixture starts in portrait") {
            window.bounds.height > window.bounds.width && scene.interfaceOrientation.isPortrait
        }
        try await eventually("Rotation fixture mounts its draft editor") {
            Self.views(host.view).compactMap { $0 as? TailTextView }.contains { $0.text.contains("Rotation draft 0") }
        }
        let editor = try XCTUnwrap(Self.views(host.view).compactMap { $0 as? TailTextView }.first { $0.text.contains("Rotation draft 0") })
        model.phoneKeyboard.show(ids[0])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(editor.isFirstResponder)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft)) { error in XCTFail("Rotation request failed: \(error)") }
        try await eventually("Rotation fixture reaches landscape") {
            window.bounds.width > window.bounds.height && scene.interfaceOrientation.isLandscape
        }
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(window.bounds.width, window.bounds.height, "The fixture must actually rotate")
        XCTAssertEqual(host.view.bounds.width, window.bounds.width, accuracy: 1)
        XCTAssertGreaterThan(editor.bounds.width, window.bounds.width * 0.75, "A phone pane must fill landscape width instead of retaining its portrait width")
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertEqual(model.draft(ids[0]).text, "Rotation draft 0")
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try await eventually("Rotation fixture returns to portrait") {
            window.bounds.height > window.bounds.width && scene.interfaceOrientation.isPortrait
        }
        XCTAssertLessThan(window.bounds.width, window.bounds.height)
        XCTAssertTrue(editor.isFirstResponder)
    }
    func testPhoneKeyboardExplicitShowHideAndPaneTransfer() async throws {
        let keyboard = PhoneKeyboardController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
        defer { keyboard.hide(); window.isHidden = true }
        let first = TailTextView.native(), second = TailTextView.native()
        var parents: [PadTranscript] = []
        var coordinators: [PadTranscript.Coordinator] = []
        for (index, view) in [first, second].enumerated() {
            let session = String(index)
            let parent = PadTranscript(messages: [], draft: "Draft " + session, images: [:], editable: true, lineNumbers: false,
                                       edit: { _ in XCTFail("Keyboard controls must not edit or send drafts") }, send: { XCTFail("Unexpected send") }, attach: { _ in },
                                       phoneKeyboard: keyboard, keyboardSession: session)
            let coordinator = PadTranscript.Coordinator(parent); parents.append(parent); coordinators.append(coordinator)
            view.frame = CGRect(x: 0, y: CGFloat(index * 220), width: 390, height: 210)
            view.explicitPhoneKeyboard = true; view.delegate = coordinator; host.view.addSubview(view)
            parent.update(view, coordinator: coordinator)
        }
        XCTAssertFalse(keyboard.isRequested)
        keyboard.select("1")
        XCTAssertFalse(keyboard.isRequested, "Switching while reading must not summon the keyboard")
        keyboard.show("0")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(first.isFirstResponder); XCTAssertEqual(keyboard.target, "0")
        keyboard.select("1")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(second.isFirstResponder); XCTAssertFalse(first.isFirstResponder)
        XCTAssertEqual(keyboard.target, "1", "Old editor's end-editing must not cancel new focus")
        keyboard.hide()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(first.isFirstResponder); XCTAssertFalse(second.isFirstResponder); XCTAssertFalse(keyboard.isRequested)
        XCTAssertEqual(first.text, "Draft 0"); XCTAssertEqual(second.text, "Draft 1")
        second.isEditable = false
        keyboard.show("1")
        XCTAssertFalse(keyboard.isRequested, "Cannot summon input for a read-only remote session")
        XCTAssertEqual(parents.count, coordinators.count) // Keep delegates alive throughout UIKit focus transfer.
    }
    func testPhoneHistoryTouchDoesNotStartEditingButDraftTouchDoes() {
        let view = TailTextView.native()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        view.font = .systemFont(ofSize: 16)
        view.text = "Historical message\n\nEditable draft"
        view.historyLength = ("Historical message\n\n" as NSString).length
        view.explicitPhoneKeyboard = true
        let parent = PadTranscript(messages: [], draft: "Editable draft", images: [:], editable: true, lineNumbers: false,
                                   edit: { _ in }, send: {}, attach: { _ in })
        let coordinator = PadTranscript.Coordinator(parent); view.delegate = coordinator
        view.layoutIfNeeded()
        for (offset, allowed) in [(2, false), (view.historyLength + 2, true)] {
            let position = view.position(from: view.beginningOfDocument, offset: offset)!
            let rect = view.caretRect(for: position)
            view.prepareKeyboardTouch(at: CGPoint(x: rect.midX, y: rect.midY))
            XCTAssertEqual(coordinator.textViewShouldBeginEditing(view), allowed)
        }
        view.explicitPhoneKeyboard = false; view.allowKeyboardActivation = false
        XCTAssertTrue(coordinator.textViewShouldBeginEditing(view), "iPad keeps its existing editing behavior")
    }
    func testFourMobileDevicesJoinOneGroupWithDistinctPersistentIdentities() async throws {
        guard let port = ProcessInfo.processInfo.environment["CONVERSE_GROUP_PORT"].flatMap(Int.init), port > 0 else { throw XCTSkip("Run iPad/test.sh --interop with the isolated Mac group sponsor") }
        var mobiles: [DeviceSyncService] = []
        defer { mobiles.forEach { $0.suspendViewer() } }
        for index in 0..<4 {
            let mobile = try service(); try mobile.enableGroupsForTesting(); mobiles.append(mobile)
            let identity = try XCTUnwrap(mobile.identity)
            mobile.deviceNameOverride = PadModel.mobileDeviceName(phone: index < 2, identifier: identity.deviceID)
            try mobile.startNetworkForTesting()
            mobile.joinGroupByAddress(host: "127.0.0.1", port: port)
            try await eventually("Mobile requests admission") { mobile.pairingPrompt != nil }
            XCTAssertNil(mobile.currentGroup)
            mobile.confirmPairing()
            try await eventually("Mac reviewed code and admitted mobile") { mobile.currentGroup?.name == "Simulator Group" }
            XCTAssertTrue(mobile.remoteLeases.isEmpty, "Joining must not take any existing display lease")
        }
        try await eventually("Four mobile identities coexist") { mobiles.allSatisfy { $0.trusted.count >= 4 } }
        XCTAssertEqual(Set(mobiles.compactMap { $0.identity?.deviceID }).count, 4)
        XCTAssertEqual(Set(mobiles.compactMap(\.deviceNameOverride)).count, 4)
        let renamedID = try XCTUnwrap(mobiles[1].identity?.deviceID)
        let reportedName = mobiles[1].deviceNameOverride
        try mobiles[0].renameDeviceDisplayName(renamedID, name: "Pocket phone")
        try await eventually("Group display label reaches all four mobile viewers") {
            mobiles.allSatisfy { $0.displayName(for: renamedID) == "Pocket phone" }
        }
        XCTAssertEqual(mobiles[1].deviceNameOverride, reportedName)
        XCTAssertEqual(mobiles[1].identity?.deviceID, renamedID)
        let group = try XCTUnwrap(mobiles.first?.currentGroup)
        for mobile in mobiles {
            let reloadedIdentity = try DeviceIdentity.loadOrCreate(folder: mobile.storageFolder, useKeychain: false)
            XCTAssertEqual(reloadedIdentity.deviceID, mobile.identity?.deviceID)
            let groups = try ConverseGroupStore(folder: mobile.storageFolder)
            XCTAssertEqual(groups.current, group)
            let trust = try DeviceTrustStore(folder: mobile.storageFolder)
            XCTAssertGreaterThanOrEqual(trust.devices.count, 4)
        }
        let model = PadModel(service: mobiles[0])
        XCTAssertEqual(PadModel(service: mobiles[0]).state.defaultDeviceName, model.state.defaultDeviceName)
    }
    func testPhoneRestoringThreeTabletPlacementsParksOnlyExtraAndKeepsDraft() throws {
        let service = try service(), model = PadModel(service: service)
        model.state.placements = ["one", "two", "three"]
        model.state.drafts["three"] = PadDraft(text: "Recovered third draft", dirty: true)
        model.constrainPhonePlacements()
        XCTAssertEqual(model.state.placements, ["one", "two", nil])
        XCTAssertEqual(model.draft("three").text, "Recovered third draft")
        XCTAssertEqual(PadModel(service: service).state.placements, model.state.placements)
    }
    func testPhoneSelectionCapsAtTwoAndPreservesParkedDraft() throws {
        let service = try service(), model = PadModel(service: service)
        let home = String(repeating: "a", count: 64)
        let ids = (0..<3).map { _ in DeviceGlobalID(home: home, session: UUID()).string }
        model.state.drafts[ids[0]] = PadDraft(text: "Unsent phone draft", dirty: true)
        model.togglePhoneSession(ids[0]); model.togglePhoneSession(ids[1])
        XCTAssertEqual(model.state.placements.compactMap { $0 }, Array(ids.prefix(2)))
        model.togglePhoneSession(ids[2])
        XCTAssertFalse(model.state.placements.contains(ids[2]), "Choosing a third must not silently replace another session")
        model.togglePhoneSession(ids[0])
        XCTAssertEqual(model.draft(ids[0]).text, "Unsent phone draft")
        model.togglePhoneSession(ids[2])
        XCTAssertEqual(Set(model.state.placements.compactMap { $0 }), Set(ids.suffix(2)))
        let restored = PadModel(service: service)
        XCTAssertEqual(restored.state.placements, model.state.placements)
        XCTAssertEqual(restored.draft(ids[0]).text, "Unsent phone draft")
    }
    func testPhonePickerToggleOffStaysOffAcrossHomeTraffic() throws {
        let service = try service(), model = PadModel(service: service)
        let home = String(repeating: "b", count: 64), sid = UUID()
        let id = DeviceGlobalID(home: home, session: sid).string
        let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Home")
        peer.hello = DeviceHello(deviceID: home, deviceName: "Home", converseVersion: "test"); peer.trustedReady = true
        let row = DeviceSidebarRow(globalID: id, sessionID: sid, title: "Work", assistant: "Muse", engine: "muse", model: "", effort: "", access: "read only", status: "Ready", busy: false, queued: 0, queuePaused: false)
        func sidebar(_ sequence: UInt64) throws {
            let payload = DeviceSidebarPayload(homeDeviceID: home, homeDeviceName: "Home", homeSeq: sequence, rows: [row])
            service.handleEnvelope(peer, DeviceEnvelope(kind: "sidebar.snapshot", homeSeq: sequence, payload: try JSONEncoder().encode(payload)))
        }
        try sidebar(10)
        model.togglePhoneSession(id)
        XCTAssertTrue(model.state.placements.contains(id), "Selecting checks the session")
        model.togglePhoneSession(id)
        XCTAssertFalse(model.state.placements.contains(id), "Unchecking closes the session")
        try sidebar(11)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(model.state.placements.contains(id), "Later home traffic must not recheck an unchecked session")
    }
    func testRemoteSidebarMarkersPausedUnseenAndPersisted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("converse-ipad-markers-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let home = String(repeating: "c", count: 64), sid = UUID(), aid = UUID()
        let id = DeviceGlobalID(home: home, session: sid).string, agentID = DeviceGlobalID(home: home, session: aid).string
        var sequence: UInt64 = 10
        func launch() throws -> (DeviceSyncService, PadModel, DevicePeer) {
            let service = DeviceSyncService(); try service.configureForTesting(folder: folder)
            let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Home")
            peer.hello = DeviceHello(deviceID: home, deviceName: "Home", converseVersion: "test"); peer.trustedReady = true
            service.adoptPeerForTesting(peer)
            return (service, PadModel(service: service), peer)
        }
        func sidebar(_ service: DeviceSyncService, _ peer: DevicePeer, response: TimeInterval, paused: Bool) throws {
            sequence += 1
            var chat = DeviceSidebarRow(globalID: id, sessionID: sid, title: "Work", assistant: "Claude", engine: "claude", model: "", effort: "", access: "", status: "Ready", busy: false, queued: 0, queuePaused: false)
            chat.lastResponseAt = Date(timeIntervalSinceReferenceDate: response)
            var agent = DeviceSidebarRow(globalID: agentID, sessionID: aid, title: "Converse Steward", assistant: "Agent", engine: "agent", model: "", effort: "", access: "", status: "Ready", busy: false, queued: 0, queuePaused: false, participantKind: "agent")
            agent.loopPaused = paused; agent.pausedReason = paused ? "Over budget." : nil; agent.lastResponseAt = chat.lastResponseAt
            let payload = DeviceSidebarPayload(homeDeviceID: home, homeDeviceName: "Home", homeSeq: sequence, rows: [chat, agent])
            service.handleEnvelope(peer, DeviceEnvelope(kind: "sidebar.snapshot", homeSeq: sequence, payload: try JSONEncoder().encode(payload)))
        }
        func markers(_ service: DeviceSyncService, _ id: String) throws -> RemoteRowMarkers { service.remoteMarkers(try XCTUnwrap(service.remoteRow(globalID: id))) }
        var (service, model, peer) = try launch()
        try sidebar(service, peer, response: 100, paused: true)
        XCTAssertEqual(try markers(service, agentID), RemoteRowMarkers(paused: true, pausedReason: "Over budget.", unseen: false), "A paused remote agent renders red with its reason, never the eye")
        XCTAssertFalse(try markers(service, id).unseen, "First sight after install is seen")
        try sidebar(service, peer, response: 200, paused: false)
        XCTAssertTrue(try markers(service, id).unseen, "A new response while not displayed here shows the eye")
        let resumedAgent = try markers(service, agentID)
        XCTAssertFalse(resumedAgent.unseen || resumedAgent.paused, "Agents never get the eye; unpausing clears the red marker")
        (service, model, peer) = try launch()
        try sidebar(service, peer, response: 200, paused: false)
        XCTAssertTrue(try markers(service, id).unseen, "The eye survives relaunch")
        service.homes[home]?.lastSeen = Date()
        model.assign(id, pane: 0)
        XCTAssertFalse(try markers(service, id).unseen, "Taking the session with 1, 2 or 3 clears the eye")
        try sidebar(service, peer, response: 300, paused: false)
        XCTAssertFalse(try markers(service, id).unseen, "A response while displayed here is seen")
        model.park(id)
        try sidebar(service, peer, response: 400, paused: false)
        XCTAssertTrue(try markers(service, id).unseen, "After parking, the next response shows the eye again")
        (service, model, peer) = try launch()
        XCTAssertEqual(model.state.placements, [nil, nil, nil])
        try sidebar(service, peer, response: 400, paused: false)
        XCTAssertTrue(try markers(service, id).unseen, "Relaunch keeps an uncleared eye without marking anything new")
    }
    func testTranscriptFocusSelectsPaneWithoutEditingDraft() {
        var focusCount = 0
        let parent = PadTranscript(messages: [], draft: "Untouched", images: [:], editable: true, lineNumbers: true,
                                   edit: { _ in XCTFail("Focus must not edit the draft") }, send: {}, attach: { _ in }, didFocus: { focusCount += 1 })
        let coordinator = PadTranscript.Coordinator(parent)
        coordinator.textViewDidBeginEditing(TailTextView.native())
        XCTAssertEqual(focusCount, 1)
    }
    func testUniversalAppDeviceFamilies() throws {
        let families = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIDeviceFamily") as? [Int])
        XCTAssertTrue(families.contains(1), "The built app must install on iPhone")
        XCTAssertTrue(families.contains(2), "iPad support must remain")
    }
    func testPhoneTwoPanesPortraitAndLandscape() async throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let service = try service(), model = PadModel(service: service)
        let home = String(repeating: "a", count: 64)
        for index in 0..<2 {
            let id = DeviceGlobalID(home: home, session: UUID()).string
            model.state.placements[index] = id
            model.state.drafts[id] = PadDraft(text: "Session \(index + 1) draft stays intact", dirty: true)
            service.remoteLeases[id] = UInt64(index + 1)
            service.remoteTranscripts[id] = DeviceTranscriptPayload(globalID: id, homeSeq: 1, epoch: UInt64(index + 1), messages: [], draft: model.draft(id).text, draftVersion: 1, busy: index == 0, status: index == 0 ? "Working" : "Ready", title: index == 0 ? "Converse Development" : "Claude VM", engine: index == 0 ? "codex" : "claude")
        }
        let expected = model.state.drafts.mapValues(\.text)
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
            let window = UIWindow(frame: CGRect(origin: .zero, size: size)); window.overrideUserInterfaceStyle = .dark
            let host = UIHostingController(rootView: PadRoot(model: model)); window.rootViewController = host; window.isHidden = false
            try await Task.sleep(for: .milliseconds(250)); host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: image); attachment.name = "iPhone two sessions \(Int(size.width))x\(Int(size.height))"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(model.state.drafts.mapValues(\.text), expected)
            if size.width < size.height {
                NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
                window.frame.size.height = 510
                try await Task.sleep(for: .milliseconds(250)); host.view.layoutIfNeeded()
                let keyboardImage = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
                let keyboardAttachment = XCTAttachment(image: keyboardImage); keyboardAttachment.name = "iPhone keyboard-sized focused pane"; keyboardAttachment.lifetime = .keepAlways; add(keyboardAttachment)
                NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            }
            window.isHidden = true
        }
    }
    func testPhoneSessionPickerAtPhoneWidth() async throws {
        let service = try service(), model = PadModel(service: service)
        let home = String(repeating: "a", count: 64)
        var state = RemoteHomeState(deviceID: home, deviceName: "Richard-Air"); state.online = true
        for (index, title) in ["Converse Development", "Converse Steward", "Weekend demo"].enumerated() {
            let sid = UUID(), id = DeviceGlobalID(home: home, session: UUID()).string
            state.rows.append(DeviceSidebarRow(globalID: id, sessionID: sid, title: title, assistant: "Muse", engine: "muse", model: "muse-spark-1.3", effort: "", access: "", status: index == 0 ? "Working" : "Ready", busy: index == 0, queued: 0, queuePaused: false))
            if index < 2 { model.state.placements[index] = id }
        }
        service.homes[home] = state
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)); window.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView: PhoneSessionPicker(model: model, open: { _ in })); window.rootViewController = host; window.isHidden = false
        try await Task.sleep(for: .milliseconds(250)); host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image); attachment.name = "iPhone session picker"; attachment.lifetime = .keepAlways; add(attachment)
        window.isHidden = true
    }
    func testImageToolsMenuForHistoryAndDraftOnly() {
        let parent = PadTranscript(messages: [], draft: "", images: [:], editable: true, lineNumbers: true, edit: { _ in }, send: {}, attach: { _ in }, imageTools: { _, _ in })
        let coordinator = PadTranscript.Coordinator(parent)
        let view = TailTextView.native()
        let attachment = NSTextAttachment()
        attachment.image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 12, height: 12)) }
        view.textStorage.append(NSAttributedString(attachment: attachment))
        view.textStorage.append(NSAttributedString(string: "text"))
        view.textStorage.append(NSAttributedString(attachment: attachment))
        XCTAssertNotNil(coordinator.imageToolsAction(view, range: NSRange(location: 0, length: 1)))
        XCTAssertNotNil(coordinator.imageToolsAction(view, range: NSRange(location: 5, length: 1)))
        XCTAssertNil(coordinator.imageToolsAction(view, range: NSRange(location: 1, length: 1)))
        coordinator.parent.editable = false
        XCTAssertNil(coordinator.imageToolsAction(view, range: NSRange(location: 0, length: 1)))
    }
    func testBuiltAppDeclaresPhotoSavePermission() throws {
        // Check the packaged host, not a source-file string: UIKit supplies
        // Save Image for transcript attachments and TCC aborts without this.
        let reason = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String)
        XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // The system Photos picker does not require broad library access.
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription"))
    }
    func testImageNotesPreserveTypingAndRejectStaleResults() throws {
        let service = try service(), model = PadModel(service: service)
        let id = DeviceGlobalID(home: String(repeating: "a", count: 64), session: UUID()).string
        service.remoteLeases[id] = 7
        model.state.drafts[id] = PadDraft(text: "Typed while processing", hashes: ["image"], dirty: true)
        XCTAssertTrue(model.addImageNotes(id, hash: "image", epoch: 7, notes: "A blue square"))
        XCTAssertTrue(model.draft(id).text.hasPrefix("Typed while processing"))
        XCTAssertEqual(model.draft(id).hashes, ["image"])
        let saved = model.draft(id).text
        service.remoteLeases[id] = 8
        XCTAssertFalse(model.addImageNotes(id, hash: "image", epoch: 7, notes: "Late result"))
        service.remoteLeases[id] = 7; model.state.drafts[id]?.sentID = UUID()
        XCTAssertFalse(model.addImageNotes(id, hash: "image", epoch: 7, notes: "After send"))
        model.state.drafts[id]?.sentID = nil; model.state.drafts[id]?.hashes = []
        XCTAssertFalse(model.addImageNotes(id, hash: "image", epoch: 7, notes: "Removed image"))
        XCTAssertEqual(model.draft(id).text, saved)
    }
    func testSegmentOutlinesStayVisibleOnReducedPreview() async throws {
        let width = 600, height = 1200
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let index = y * width + x
            rgba[index * 4] = UInt8((x / 25 + y / 25).isMultiple(of: 2) ? 35 : 125)
            rgba[index * 4 + 1] = UInt8((x / 25).isMultiple(of: 2) ? 130 : 190)
            rgba[index * 4 + 2] = 30
            let dx = Double(x - 300) / 190, dy = Double(y - 600) / 120
            if dx * dx + dy * dy < 1 { mask[index] = 1 }
        } }
        let image = try ImageSegment.rgbaImage(rgba, width: width, height: height)
        let item = try ImageSegment(DeviceImageSegment(region: DeviceImageRegion(x: 0, y: 0, width: width, height: height, imageWidth: width, imageHeight: height), label: "test object", mask: SAMMask.encode(mask, width: width, height: height)))
        XCTAssertNotNil(item.boundary)
        for selected: Set<Int> in [[], [0]] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600)); window.overrideUserInterfaceStyle = .light
            let host = UIHostingController(rootView: SegmentPicker(image: image, segments: [item], selected: .constant(selected)).padding())
            window.rootViewController = host; window.isHidden = false
            try await Task.sleep(for: .milliseconds(200)); host.view.layoutIfNeeded()
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: screenshot); attachment.name = "Segment contrast " + (selected.isEmpty ? "candidate" : "selected"); attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
        // The thicker preview boundary must not bleed into exported pixels.
        let exported = try ImageSegment.export(image, segments: [item], crop: false)
        let bytes = Array(exported.dataProvider!.data! as Data)
        XCTAssertEqual(bytes[(600 * width + 300) * 4 + 1], rgba[(600 * width + 300) * 4 + 1])
        XCTAssertEqual(bytes[3], 0)
    }
    func testImageToolsPanelAtNarrowWidth() async throws {
        let service = try service(), model = PadModel(service: service)
        let id = DeviceGlobalID(home: String(repeating: "a", count: 64), session: UUID()).string
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 200)).image { c in
            UIColor.systemBackground.setFill(); c.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
            UIColor.red.setFill(); c.cgContext.fillEllipse(in: CGRect(x: 20, y: 35, width: 120, height: 120))
            UIColor.blue.setFill(); c.fill(CGRect(x: 200, y: 60, width: 80, height: 80))
        }
        let file = service.storageFolder.appendingPathComponent("sample.png"); try image.pngData()!.write(to: file)
        service.blobCache["image"] = file; service.blobReady["image"] = true; service.remoteLeases[id] = 1
        model.state.drafts[id] = PadDraft(text: "", hashes: ["image"])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 480, height: 820)); window.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView: PadImageTools(id: id, model: model)); window.rootViewController = host; window.isHidden = false
        try await Task.sleep(for: .milliseconds(250)); host.view.layoutIfNeeded()
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: screenshot); attachment.name = "Image tools at narrow width"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(model.draft(id).hashes, ["image"], "Opening tools never sends or modifies attachments")
        window.isHidden = true
    }
    func testSAMRegionsAndMalformedResponses() throws {
        let parsed = try ImageAssist.regions("<0f>1<|box;x1=26;y1=41;x2=144;y2=159;w=320;h=240|><|mask;x=0;y=0;data=119,119,~payload|>", width: 320, height: 240)
        XCTAssertEqual(parsed.first?.width, 119)
        XCTAssertEqual(parsed.first?.height, 119)
        XCTAssertThrowsError(try ImageAssist.regions("<|box;x1=0;y1=0;x2=321;y2=20;w=320;h=240|>", width: 320, height: 240))
        XCTAssertThrowsError(try ImageAssist.regions("<|box;x1=20;y1=0;x2=10;y2=20;w=320;h=240|>", width: 320, height: 240))
        XCTAssertThrowsError(try ImageAssist.outputText(["status": "incomplete", "output": []]))
        XCTAssertEqual(try ImageAssist.regions("", width: 320, height: 240), [])
    }
    func testDraftWrapsAfterTrafficDuringTypingPasteAndResize() throws {
        let message = DeviceWireMessage(id: UUID(), role: "user", text: "[Converse message from Reviewer · session abc · delivery def · hop 1/100]\nPlease review this change")
        var edited = ""
        var parent = PadTranscript(messages: [message], draft: "", images: [:], editable: true, lineNumbers: true, edit: { edited = $0 }, send: {}, attach: { _ in })
        let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 280, height: 500)
        let coordinator = PadTranscript.Coordinator(parent); view.delegate = coordinator
        parent.update(view, coordinator: coordinator)
        let text = String(repeating: "Draft must wrap and remain editable. ", count: 12)
        view.insertText(text)
        coordinator.textViewDidChange(view)
        XCTAssertEqual(edited, text)
        func checkWrap() throws {
            view.layoutManager.ensureLayout(for: view.textContainer)
            let range = NSRange(location: view.historyLength, length: (text as NSString).length)
            let style = try XCTUnwrap(view.textStorage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(style.lineBreakMode, .byWordWrapping)
            XCTAssertNil(view.textStorage.attribute(.link, at: range.location, effectiveRange: nil), "Draft must not inherit the traffic link")
            XCTAssertGreaterThan(view.lineTop(at: NSMaxRange(range) - 1), view.lineTop(at: range.location) + 40, "Native layout must use several lines")
            let glyphs = view.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            view.layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, glyphRange, _ in
                XCTAssertEqual(view.layoutManager.truncatedGlyphRange(inLineFragmentForGlyphAt: glyphRange.location).location, NSNotFound)
            }
        }
        try checkWrap()
        // A rich paste can supply a truncating paragraph and a link of its own.
        let clipped = NSMutableParagraphStyle(); clipped.lineBreakMode = .byTruncatingTail
        view.textStorage.addAttributes([.paragraphStyle: clipped, .link: URL(string: "https://example.com")!], range: NSRange(location: view.historyLength, length: (text as NSString).length))
        coordinator.textViewDidChange(view)
        try checkWrap()
        parent.draft = text
        parent.messages.append(DeviceWireMessage(id: UUID(), role: "assistant", text: "New home output"))
        view.frame.size.width = 180
        parent.update(view, coordinator: coordinator)
        try checkWrap()
        XCTAssertEqual((view.text as NSString).substring(from: view.historyLength), text)
    }
    func testTrafficLinksKeepTheirColorInLightAndDarkMode() async throws {
        let message = DeviceWireMessage(id: UUID(), role: "user", text: "[Converse message from Reviewer · session abc · delivery def · hop 1/100]\nPlease review this change")
        let parent = PadTranscript(messages: [message], draft: "My typing", images: [:], editable: true, lineNumbers: true, edit: { _ in }, send: {}, attach: { _ in })
        let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 280, height: 500)
        let coordinator = PadTranscript.Coordinator(parent)
        parent.update(view, coordinator: coordinator)
        XCTAssertNotNil(view.textStorage.attribute(.link, at: 0, effectiveRange: nil), "Tap must still open full message details")
        let traffic = try XCTUnwrap(view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        let draft = try XCTUnwrap(view.textStorage.attribute(.foregroundColor, at: view.historyLength, effectiveRange: nil) as? UIColor)
        XCTAssertNil(view.linkTextAttributes[.foregroundColor], "UIKit must not override traffic with its default blue link color")
        for mode in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: mode)
            XCTAssertEqual(traffic.resolvedColor(with: traits), PadPalette.traffic.resolvedColor(with: traits))
            XCTAssertNotEqual(traffic.resolvedColor(with: traits), draft.resolvedColor(with: traits))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 280, height: 200))
            window.overrideUserInterfaceStyle = mode
            let controller = UIViewController(); window.rootViewController = controller
            let sample = TailTextView.native(); sample.backgroundColor = .systemBackground
            sample.frame = window.bounds; controller.view.addSubview(sample)
            window.isHidden = false
            parent.update(sample, coordinator: PadTranscript.Coordinator(parent))
            try await Task.sleep(for: .milliseconds(100))
            sample.layoutIfNeeded()
            let screenshot = UIGraphicsImageRenderer(bounds: sample.bounds).image { sample.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "Switchboard summary and draft — " + (mode == .dark ? "dark" : "light")
            attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
    }
    // Inject all merged a reply with typed input (941BAB1E): the typed part
    // stays visible whether the home sent components or not.
    func testMergedTrafficKeepsTypedPromptVisible() throws {
        let reply = "[Converse message from ClaudeConverse · session abc · delivery " + UUID().uuidString + " · hop 2/100]\nRead-only diagnosis\n[Reply to request " + UUID().uuidString + "]"
        let typed = "OK, propose: make 148 on Mac have a Debug pane."
        let text = reply + "\n\n" + typed
        let wireJSON = #"{"id":"941BAB1E-4268-4C06-AFF5-0457C32E123D","role":"user","text":"#
            + String(data: try JSONEncoder().encode(text), encoding: .utf8)!
            + #","imageHashes":[],"components":[{"offset":0,"length":"# + String((reply as NSString).length) + #","kind":"traffic"},{"offset":"#
            + String((reply as NSString).length + 2) + #","length":"# + String((typed as NSString).length) + #","kind":"human"}]}"#
        let recorded = try JSONDecoder().decode(DeviceWireMessage.self, from: Data(wireJSON.utf8))
        XCTAssertEqual(recorded.components?.map(\.kind), ["traffic", "human"], "The snapshot DTO decodes components from the home")
        let legacy = DeviceWireMessage(id: UUID(), role: "user", text: text)
        for message in [recorded, legacy] {
            let parent = PadTranscript(messages: [message], draft: "", images: [:], editable: true, lineNumbers: true, edit: { _ in }, send: {}, attach: { _ in })
            let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
            let coordinator = PadTranscript.Coordinator(parent)
            parent.update(view, coordinator: coordinator)
            let shown = view.text as NSString
            let typedRange = shown.range(of: typed)
            XCTAssertNotEqual(typedRange.location, NSNotFound, "The typed prompt is visible")
            XCTAssertEqual(shown.range(of: "Received reply from ClaudeConverse · Read-only diagnosis").location, 0, "The reply collapses to its own summary")
            XCTAssertFalse(view.text.contains("[Reply to request"))
            let typedColor = try XCTUnwrap(view.textStorage.attribute(.foregroundColor, at: typedRange.location, effectiveRange: nil) as? UIColor)
            XCTAssertNotEqual(typedColor, PadPalette.traffic, "Typed text is not traffic-colored")
            XCTAssertEqual(view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, PadPalette.traffic)
            XCTAssertNotNil(view.textStorage.attribute(.link, at: 0, effectiveRange: nil), "Tapping the summary still opens its full message")
            XCTAssertEqual(coordinator.trafficDetails.values.sorted(), [reply], "Details hold only the switchboard part")
            XCTAssertFalse(view.trafficBlocks.contains { NSIntersectionRange($0, typedRange).length > 0 }, "Typed text keeps prompt shading")
            XCTAssertEqual(view.promptBlocks.count, 1)
        }
    }
    // A plain tell has no delivery block: invalid recorded parts from the
    // home must show the whole merged message expanded, never collapse it.
    func testInvalidMergedPartsShowWholeMessageExpanded() throws {
        let tell = "[Converse message from Fixture · session abc · delivery test · hop 1/100]\nStatus message"
        let typed = "MY TYPED PROMPT MUST STAY VISIBLE"
        let text = tell + "\n\n" + typed
        let tellLength = (tell as NSString).length, textLength = (text as NSString).length
        let invalid = DeviceWireMessage(id: UUID(), role: "user", text: text, components: [MessageComponent(offset: 0, length: tellLength, kind: "traffic"), MessageComponent(offset: textLength + 1, length: 1, kind: "human")])
        let overlapping = DeviceWireMessage(id: UUID(), role: "user", text: text, components: [MessageComponent(offset: 0, length: tellLength, kind: "traffic"), MessageComponent(offset: tellLength - 3, length: textLength - tellLength + 3, kind: "human")])
        for message in [invalid, overlapping] {
            let parent = PadTranscript(messages: [message], draft: "", images: [:], editable: true, lineNumbers: true, edit: { _ in }, send: {}, attach: { _ in })
            let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
            let coordinator = PadTranscript.Coordinator(parent)
            parent.update(view, coordinator: coordinator)
            let shown = view.text as NSString
            let typedRange = shown.range(of: typed)
            XCTAssertNotEqual(typedRange.location, NSNotFound, "The typed prompt is visible")
            XCTAssertEqual(shown.range(of: "[Converse message from Fixture").location, 0, "The whole message is shown expanded, not summarized")
            XCTAssertFalse(view.text.contains("Received tell"))
            XCTAssertNotEqual(view.textStorage.attribute(.foregroundColor, at: typedRange.location, effectiveRange: nil) as? UIColor, PadPalette.traffic, "Typed text is not traffic-colored")
            XCTAssertNotEqual(view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, PadPalette.traffic, "Nothing in the expanded message is orange")
            XCTAssertTrue(coordinator.trafficDetails.isEmpty, "No collapsed summary to tap")
            XCTAssertTrue(view.trafficBlocks.isEmpty, "The message keeps prompt shading")
            XCTAssertEqual(view.promptBlocks.count, 1)
        }
        XCTAssertNil(TranscriptStyle.queueSummary(text, components: invalid.components), "Queue rows never summarize over invalid parts")
        XCTAssertNotNil(TranscriptStyle.queueSummary(text), "Without parts the ambiguous old merge still summarizes as before")
    }
    // The same message text with different recorded parts renders
    // differently: the transcript's content signature must change with them.
    func testComponentsOnlyChangeRerendersTranscript() throws {
        let tell = "[Converse message from Fixture · session abc · delivery test · hop 1/100]\nStatus message"
        let typed = "MY TYPED PROMPT MUST STAY VISIBLE"
        let text = tell + "\n\n" + typed
        let valid = try XCTUnwrap(TranscriptStyle.components(joining: [(tell, "traffic"), (typed, "human")], into: text))
        let asHuman = [MessageComponent(offset: valid[0].offset, length: valid[0].length, kind: "human"), valid[1]]
        let id = UUID(), later = DeviceWireMessage(id: UUID(), role: "assistant", text: "Later reply")
        let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        var coordinator: PadTranscript.Coordinator?
        func render(_ parts: [MessageComponent]?) -> [String] {
            let parent = PadTranscript(messages: [DeviceWireMessage(id: id, role: "user", text: text, components: parts), later], draft: "", images: [:], editable: true, lineNumbers: true, edit: { _ in }, send: {}, attach: { _ in })
            if coordinator == nil { coordinator = PadTranscript.Coordinator(parent) }
            parent.update(view, coordinator: coordinator!)
            return view.text.components(separatedBy: "\n")
        }
        func typedInFull(_ lines: [String]) -> Bool { lines.contains(typed) }
        func summarized(_ lines: [String]) -> Bool { lines.contains { $0.hasPrefix("Received tell from Fixture") } }
        func wholeTell(_ lines: [String]) -> Bool { lines.contains { $0.hasPrefix("[Converse message from Fixture") } }
        var lines = render(nil)
        XCTAssertTrue(!typedInFull(lines) && summarized(lines) && lines.contains("Later reply"), "Without parts the merge collapses as before")
        lines = render(valid)
        XCTAssertTrue(typedInFull(lines) && summarized(lines) && !wholeTell(lines), "absent→valid re-renders: typed visible, tell summarized")
        lines = render([valid[0]])
        XCTAssertTrue(typedInFull(lines) && !summarized(lines) && wholeTell(lines), "valid→invalid re-renders the whole message expanded")
        lines = render(valid)
        XCTAssertTrue(typedInFull(lines) && summarized(lines), "invalid→valid re-renders")
        lines = render(asHuman)
        XCTAssertTrue(typedInFull(lines) && !summarized(lines) && wholeTell(lines), "traffic→human re-renders the tell in full")
        lines = render(nil)
        XCTAssertTrue(!typedInFull(lines) && summarized(lines) && lines.contains("Later reply"), "→absent re-renders the legacy collapse")
    }
    // A snapshot whose parts include a null entry still decodes: the message
    // keeps its text and shows whole instead of failing the whole page.
    func testNullComponentEntriesDecodeAndRenderWhole() throws {
        let tell = "[Converse message from Fixture · session abc · delivery test · hop 1/100]\nStatus message"
        let typed = "MY TYPED PROMPT MUST STAY VISIBLE"
        let text = tell + "\n\n" + typed
        func wire(_ components: String) throws -> DeviceWireMessage {
            let object: [String: Any] = ["id": UUID().uuidString, "role": "user", "text": text, "imageHashes": [String]()]
            var json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            json.removeLast(); json += ",\"components\":" + components + "}"
            return try JSONDecoder().decode(DeviceWireMessage.self, from: Data(json.utf8))
        }
        let tellLength = (tell as NSString).length
        let damaged = try ["[null]", "[{\"offset\":0,\"length\":\(tellLength),\"kind\":\"traffic\"},null]", "{\"offset\":0}", "5",
                           "[{\"offset\":0,\"length\":\(tellLength),\"kind\":5}]", "[{\"offset\":\"bad\",\"length\":\(tellLength),\"kind\":\"human\"}]"].map(wire)
        let nullKind = try wire("[{\"offset\":0,\"length\":\(tellLength),\"kind\":\"traffic\"},{\"offset\":\(tellLength + 2),\"length\":\((typed as NSString).length),\"kind\":null}]")
        XCTAssertTrue(damaged.allSatisfy { $0.text == text && $0.components == MessageComponent.undecodable }, "Null entries, a mistyped list and mistyped kind or offset decode as invalid parts with the text intact")
        XCTAssertEqual(nullKind.components?.map(\.kind), ["traffic", "text"], "A null kind is an ordinary visible part")
        let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        let parent = PadTranscript(messages: damaged + [nullKind], draft: "", images: [:], editable: true, lineNumbers: true, edit: { _ in }, send: {}, attach: { _ in })
        let coordinator = PadTranscript.Coordinator(parent)
        parent.update(view, coordinator: coordinator)
        let lines = view.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0 == typed }.count, damaged.count + 1, "Typed text stays visible in every message")
        XCTAssertEqual(lines.filter { $0.hasPrefix("[Converse message from Fixture") }.count, damaged.count, "Invalid parts show the whole message expanded")
        XCTAssertEqual(lines.filter { $0.hasPrefix("Received tell from Fixture") }.count, 1, "Valid parts with a null kind still summarize the tell")
    }
    func service() throws -> DeviceSyncService {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("converse-ipad-tests-" + UUID().uuidString)
        let service = DeviceSyncService(); try service.configureForTesting(folder: folder)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return service
    }
    func testSavedPaneStartsReconnectingWithoutInvitingTake() throws {
        let service = try service(), model = PadModel(service: service)
        let id = DeviceGlobalID(home: String(repeating: "b", count: 64), session: UUID()).string
        model.state.placements[0] = id
        XCTAssertTrue(service.remoteDisplayReconnecting(id))
        XCTAssertFalse(model.canControl(id))
        service.remoteOffline.insert(id)
        XCTAssertTrue(service.remoteDisplayReconnecting(id))
        XCTAssertEqual(model.state.placements[0], id, "Reconnect presentation preserves the saved pane")
    }
    func testParkingLotSnapshotsAreReadOnlyAndTrackRenameAndDeletion() throws {
        let service = try service(), model = PadModel(service: service)
        let home = String(repeating: "b", count: 64), sid = UUID()
        let id = DeviceGlobalID(home: home, session: sid).string
        let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Home")
        peer.hello = DeviceHello(deviceID: home, deviceName: "Home", converseVersion: "test"); peer.trustedReady = true
        var row = DeviceSidebarRow(globalID: id, sessionID: sid, title: "Ideas", assistant: "Parking Lot", engine: "parking", model: "", effort: "", access: "read only", status: "Parking Lot · read only", busy: false, queued: 0, queuePaused: false)
        func sidebar(_ sequence: UInt64, _ rows: [DeviceSidebarRow]) throws {
            let payload = DeviceSidebarPayload(homeDeviceID: home, homeDeviceName: "Home", homeSeq: sequence, rows: rows)
            service.handleEnvelope(peer, DeviceEnvelope(kind: "sidebar.snapshot", homeSeq: sequence, payload: try JSONEncoder().encode(payload)))
        }
        try sidebar(10, [row])
        XCTAssertTrue(model.isParkingLot(id), "Sidebar type prevents editing even before a transcript arrives")
        model.state.placements[0] = id; service.remoteLeases[id] = 0
        let message = DeviceWireMessage(id: UUID(), role: "assistant", text: "# Ideas\n1. [Done] Tested item")
        let snapshot = DeviceTranscriptPayload(globalID: id, homeSeq: 11, epoch: 0, messages: [message], total: 1, draft: "", draftVersion: 4, busy: false, status: "Parking Lot · read only", title: "Ideas", engine: "parking")
        service.handleEnvelope(peer, DeviceEnvelope(kind: "transcript.snapshot", sessionID: id, epoch: 0, payload: try JSONEncoder().encode(snapshot)))
        XCTAssertFalse(model.canControl(id)); XCTAssertFalse(model.canSend(id))
        XCTAssertNil(service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "submit", text: "Must not send")))
        let view = TailTextView.native()
        let parent = PadTranscript(messages: try XCTUnwrap(service.remoteTranscripts[id]?.messages), draft: "", images: [:], editable: false, lineNumbers: true, edit: { _ in XCTFail("Read-only lot edited") }, send: { XCTFail("Read-only lot sent") }, attach: { _ in XCTFail("Read-only lot attached") })
        parent.update(view, coordinator: PadTranscript.Coordinator(parent))
        XCTAssertFalse(view.isEditable); XCTAssertTrue(view.text.contains("Tested item")); XCTAssertTrue(view.text.contains("[Done]"))
        row.title = "Renamed ideas"; try sidebar(12, [row])
        XCTAssertEqual(service.remoteRow(globalID: id)?.title, "Renamed ideas")
        try sidebar(13, [])
        XCTAssertNil(model.state.placements[0]); XCTAssertNil(service.remoteTranscripts[id]); XCTAssertNil(service.remoteLeases[id])
    }
    func testParkingLotMacGroupDiscoveryImagesLiveUpdatesAndReopen() async throws {
        guard let port = ProcessInfo.processInfo.environment["CONVERSE_GROUP_PORT"].flatMap(Int.init), port > 0 else { throw XCTSkip("Run iPad/test.sh --interop with the Parking Lot Mac fixture") }
        let service = try service(); try service.enableGroupsForTesting(); try service.startNetworkForTesting()
        defer { service.suspendViewer() }
        service.joinGroupByAddress(host: "127.0.0.1", port: port)
        try await eventually("Parking Lot viewer receives pairing code") { service.pairingPrompt != nil }
        service.confirmPairing()
        try await eventually("Group advertises Mac Parking Lot") { service.homes.values.flatMap(\.rows).contains { $0.engine == "parking" && $0.title == "Mobile Parking Lot fixture" } }
        let row = try XCTUnwrap(service.homes.values.flatMap(\.rows).first { $0.engine == "parking" && $0.title == "Mobile Parking Lot fixture" })
        service.isPlaced = { $0 == row.globalID }; service.acquireRemote(globalID: row.globalID)
        try await eventually("Parking Lot snapshot opens") { service.remoteTranscripts[row.globalID]?.engine == "parking" }
        let snapshot = try XCTUnwrap(service.remoteTranscripts[row.globalID])
        XCTAssertTrue(snapshot.messages.contains { $0.text.contains("Mobile ideas") })
        let imageMessage = try XCTUnwrap(snapshot.messages.first { $0.text.contains("Image belongs to this item") })
        let hash = try XCTUnwrap(imageMessage.imageHashes.first)
        service.fetchBlob(globalID: row.globalID, hash: hash)
        try await eventually("Parking Lot item image reaches mobile") { service.blobCache[hash] != nil }
        XCTAssertNotNil(UIImage(contentsOfFile: try XCTUnwrap(service.blobCache[hash]).path))
        let model = PadModel(service: service)
        model.state.placements[0] = row.globalID // Preserve the subscription when PadModel installs isPlaced.
        XCTAssertTrue(model.isParkingLot(row.globalID)); XCTAssertFalse(model.canControl(row.globalID))
        XCTAssertNil(service.sendRemoteCommand(globalID: row.globalID, command: DeviceCommandPayload(action: "submit", text: "Must not send")))
        let oldRevision = snapshot.draftVersion
        try await eventually("Home Parking Lot edits arrive without reopening") { (service.remoteTranscripts[row.globalID]?.draftVersion ?? 0) > oldRevision }
        service.releaseRemote(globalID: row.globalID); service.acquireRemote(globalID: row.globalID)
        try await eventually("Parking Lot reopens with attached image") { service.remoteTranscripts[row.globalID]?.messages.contains { $0.imageHashes.contains(hash) } == true }
        // Viewer: open shows the latest; Mac edits (the fixture rewrites "Live
        // update N" every second) offer Refresh instead of replacing the view.
        func liveNumber(_ messages: [DeviceWireMessage]?) -> Int? {
            messages?.lazy.compactMap { LotViewerParser.parse($0) }.first { $0.text.hasPrefix("Live update ") }.flatMap { Int($0.text.dropFirst("Live update ".count)) }
        }
        model.reconcileLots()
        try await eventually("Lot viewer shows the opened lot") { model.lotViews[row.globalID]?.displayed != nil }
        let viewer = try XCTUnwrap(model.lotViews[row.globalID])
        let entries = viewer.entries.compactMap { if case .row(let row) = $0 { return row }; return nil }
        XCTAssertEqual(entries.count, viewer.entries.count, "Every Mac lot row parses")
        XCTAssertEqual(entries.first?.heading, true); XCTAssertEqual(entries.first?.text, "Mobile ideas")
        XCTAssertEqual(entries.dropFirst().first?.number, 1); XCTAssertEqual(entries.dropFirst().first?.images, [hash])
        XCTAssertEqual(entries.dropFirst(2).first?.number, 2)
        let shown = try XCTUnwrap(liveNumber(viewer.displayed))
        try await eventually("Mac edit offers Refresh", timeout: 15) { model.lotViews[row.globalID]?.refreshAvailable == true }
        XCTAssertEqual(liveNumber(model.lotViews[row.globalID]?.displayed), shown, "The open view is not replaced")
        model.applyLotRefresh(row.globalID)
        let refreshed = try XCTUnwrap(liveNumber(model.lotViews[row.globalID]?.displayed))
        XCTAssertGreaterThan(refreshed, shown, "Refresh shows the newer Mac content")
        // A dropped subscription (reconnect/foreground) renews automatically and
        // keeps the shown copy; it never needs Take.
        service.releaseRemote(globalID: row.globalID, preservingDisplay: true)
        XCTAssertNil(service.remoteLeases[row.globalID])
        model.ensureLotSubscription(row.globalID)
        XCTAssertTrue(service.lotSubscriptionPending(row.globalID), "Viewer renews its own lot subscription")
        try await eventually("Lot subscription renews without Take", timeout: 15) { service.remoteLeases[row.globalID] == 0 }
        XCTAssertEqual(liveNumber(model.lotViews[row.globalID]?.displayed), refreshed)
        try await eventually("Renewed subscription keeps offering Refresh", timeout: 15) { model.lotViews[row.globalID]?.refreshAvailable == true }
    }
    // Mirrors ParkingLotStore.markdown/exportMessages (Mac-only AppKit source).
    func lotText(heading: Bool = false, number: Int = 1, done: Bool = false, _ text: String, notes: [(String, String)] = []) -> String {
        (heading ? "# " : "\(number). ") + (done ? "[Done] " : "") + text.replacingOccurrences(of: "\n", with: "\n   ")
            + notes.map { "\n   > " + $0.0 + ": " + $0.1.replacingOccurrences(of: "\n", with: "\n   > ") }.joined()
    }
    func lotMessage(_ text: String, id: UUID = UUID(), images: [String] = [], role: String = "assistant") -> DeviceWireMessage {
        DeviceWireMessage(id: id, role: role, text: text, imageHashes: images)
    }
    func testLotParserReadsMacRowsAndFallsBackToPlain() throws {
        let messages = [
            lotMessage(lotText(heading: true, "Bugs")),
            lotMessage(lotText(number: 1, "Fix scrolling\nOnly on iPad\n\nAfter rotation")),
            lotMessage(lotText(number: 2, done: true, "Ship it"), images: ["hash-a", "hash-b"]),
            lotMessage(lotText(heading: true, done: true, "Old ideas", notes: [("Richard", "Archive?")])),
            lotMessage(lotText(number: 1, "", notes: [("Agent:Planner", "Steps: one\ntwo\n\nthree"), ("Claude", "Agreed")])),
            lotMessage(lotText(number: 2, "Quote\n> not a comment")),
            lotMessage("Not a lot row"),
            lotMessage(lotText(number: 3, "user"), role: "user"),
            lotMessage("1. Broken\nunindented"),
            lotMessage("1. a\n   > A: comment\n   trailing text"),
            lotMessage("0. zero"), lotMessage("x1. x"), lotMessage("#Heading")
        ]
        let entries = LotViewerParser.entries(messages)
        XCTAssertEqual(entries.map(\.id), messages.map(\.id), "Every message keeps its row and order")
        func row(_ index: Int) throws -> LotViewerRow {
            guard case .row(let row) = entries[index] else { XCTFail("Row \(index) did not parse"); throw CocoaError(.coderInvalidValue) }
            return row
        }
        XCTAssertEqual(try row(0), LotViewerRow(id: messages[0].id, heading: true, number: nil, done: false, text: "Bugs", comments: [], images: []))
        XCTAssertEqual(try row(1).number, 1); XCTAssertEqual(try row(1).text, "Fix scrolling\nOnly on iPad\n\nAfter rotation")
        XCTAssertEqual(try row(2).number, 2); XCTAssertTrue(try row(2).done); XCTAssertEqual(try row(2).text, "Ship it", "Done is a style, not text")
        XCTAssertEqual(try row(2).images, ["hash-a", "hash-b"])
        XCTAssertTrue(try row(3).heading); XCTAssertTrue(try row(3).done); XCTAssertEqual(try row(3).comments, [LotViewerComment(author: "Richard", text: "Archive?")])
        XCTAssertEqual(try row(4).number, 1, "Numbering restarts after each heading")
        XCTAssertEqual(try row(4).text, "")
        XCTAssertEqual(try row(4).comments, [LotViewerComment(author: "Agent:Planner", text: "Steps: one\ntwo\n\nthree"), LotViewerComment(author: "Claude", text: "Agreed")])
        XCTAssertEqual(try row(5).text, "Quote\n> not a comment"); XCTAssertTrue(try row(5).comments.isEmpty)
        for index in 6..<messages.count {
            XCTAssertEqual(entries[index], .plain(messages[index]), "Malformed message \(index) renders as it arrived")
        }
        let nested = [lotMessage("# Plans"), lotMessage("1. Parent"),
                      lotMessage("  a. Child\n     > Agent: Keep this"), lotMessage("    i. Grandchild"),
                      lotMessage("2. Sibling")]
        let nestedEntries = LotViewerParser.entries(nested)
        guard case .row(let child) = nestedEntries[2] else { return XCTFail("Nested row did not parse") }
        XCTAssertEqual(child.depth, 2); XCTAssertEqual(child.comments, [LotViewerComment(author: "Agent", text: "Keep this")])
        // The Mac labels nested levels a, b, c and i, ii, iii (0.6.8+); those must parse as rows, not plain text.
        XCTAssertEqual(child.marker, "a.")
        guard case .row(let grandchild) = nestedEntries[3] else { return XCTFail("Roman-numeral row did not parse") }
        XCTAssertEqual(grandchild.marker, "i."); XCTAssertEqual(grandchild.depth, 3)
        guard case .row(let deep) = LotViewerParser.entries([lotMessage("    xiv. Deep")])[0] else { return XCTFail("Multi-letter label did not parse") }
        XCTAssertEqual(deep.marker, "xiv.")
        let collapsed = LotViewerParser.visible(nestedEntries, collapsed: [nested[1].id])
        XCTAssertEqual(collapsed.map(\.entry.id), [nested[0].id, nested[1].id, nested[4].id])
        XCTAssertEqual(collapsed[1].hidden, 2, "Collapsing an item hides its whole nested subtree")
    }
    func testLotRefreshOnlyForChangedContentAndApplyClearsIt() {
        let ids = (0..<3).map { _ in UUID() }
        let base = [lotMessage(lotText(heading: true, "Ideas"), id: ids[0]), lotMessage(lotText(number: 1, "One"), id: ids[1]), lotMessage(lotText(number: 2, "Two", notes: [("A", "x")]), id: ids[2], images: ["h1"])]
        var state = LotViewerState()
        XCTAssertFalse(state.refreshAvailable)
        XCTAssertTrue(state.receive(base)); XCTAssertEqual(state.displayed, base, "First snapshot shows immediately")
        XCTAssertFalse(state.refreshAvailable)
        var resent = base; resent[1].messageNumber = 9; resent[1].createdAtUnixSeconds = 1
        XCTAssertFalse(state.receive(resent), "A sync tick resend with the same content is no change"); XCTAssertFalse(state.refreshAvailable)
        var variants: [(String, [DeviceWireMessage])] = []
        var text = base; text[1].text = lotText(number: 1, "One, revised"); variants.append(("text", text))
        var done = base; done[1].text = lotText(number: 1, done: true, "One"); variants.append(("done", done))
        var comment = base; comment[2].text = lotText(number: 2, "Two", notes: [("A", "x"), ("B", "y")]); variants.append(("comment", comment))
        variants.append(("order", [base[0], base[2], base[1]]))
        var image = base; image[2].imageHashes = ["h2"]; variants.append(("image", image))
        variants.append(("deleted row", Array(base.dropFirst())))
        var added = base; added.insert(lotMessage(lotText(number: 1, "New")), at: 1); variants.append(("added row", added))
        for (name, next) in variants {
            var copy = state
            XCTAssertTrue(copy.receive(next), name); XCTAssertTrue(copy.refreshAvailable, name + " offers Refresh")
            XCTAssertEqual(copy.displayed, base, name + " does not replace the view")
            copy.applyRefresh()
            XCTAssertEqual(copy.displayed, next, name); XCTAssertFalse(copy.refreshAvailable, name + " Refresh hides after applying")
            XCTAssertEqual(copy.entries, LotViewerParser.entries(next))
        }
        var reverted = state
        reverted.receive(text); XCTAssertTrue(reverted.refreshAvailable)
        reverted.receive(base); XCTAssertFalse(reverted.refreshAvailable, "Changing back to what is shown hides Refresh")
        let entries = LotViewerParser.entries(base + [lotMessage(lotText(heading: true, "Later")), lotMessage(lotText(number: 1, "Kept"))])
        let folded = LotViewerParser.visible(entries, collapsed: [ids[0]])
        XCTAssertEqual(folded.map(\.entry.id), [ids[0], entries[3].id, entries[4].id]); XCTAssertEqual(folded[0].hidden, 2)
    }
    func testLotSubscriptionRenewalDecisions() throws {
        XCTAssertTrue(LotSubscription.shouldSubscribe(placed: true, isLot: true, suspended: false, homeReachable: true, subscribed: false, pending: false))
        for (placed, isLot, suspended, reachable, subscribed, pending) in [(false, true, false, true, false, false), (true, false, false, true, false, false),
                                                                           (true, true, true, true, false, false), (true, true, false, false, false, false),
                                                                           (true, true, false, true, true, false), (true, true, false, true, false, true)] {
            XCTAssertFalse(LotSubscription.shouldSubscribe(placed: placed, isLot: isLot, suspended: suspended, homeReachable: reachable, subscribed: subscribed, pending: pending))
        }
        // Unreachable homes are not asked (no "Home is offline." churn) and
        // ordinary sessions are never taken automatically.
        let service = try service(), model = PadModel(service: service)
        let home = String(repeating: "c", count: 64), lot = UUID(), session = UUID()
        let lotID = DeviceGlobalID(home: home, session: lot).string, sessionID = DeviceGlobalID(home: home, session: session).string
        let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Home")
        peer.hello = DeviceHello(deviceID: home, deviceName: "Home", converseVersion: "test"); peer.trustedReady = true
        let rows = [DeviceSidebarRow(globalID: lotID, sessionID: lot, title: "Lot", assistant: "Parking Lot", engine: "parking", model: "", effort: "", access: "read only", status: "Parking Lot · read only", busy: false, queued: 0, queuePaused: false),
                    DeviceSidebarRow(globalID: sessionID, sessionID: session, title: "Work", assistant: "Codex", engine: "codex", model: "", effort: "", access: "", status: "Ready", busy: false, queued: 0, queuePaused: false)]
        service.handleEnvelope(peer, DeviceEnvelope(kind: "sidebar.snapshot", homeSeq: 1, payload: try JSONEncoder().encode(DeviceSidebarPayload(homeDeviceID: home, homeDeviceName: "Home", homeSeq: 1, rows: rows))))
        model.state.placements = [lotID, sessionID, nil]
        XCTAssertTrue(model.isLotRow(lotID)); XCTAssertFalse(model.isLotRow(sessionID))
        service.lastOutcome = ""
        model.ensureLotSubscription(lotID); model.ensureLotSubscription(sessionID); model.reconcileLots()
        XCTAssertTrue(service.remoteLeases.isEmpty); XCTAssertFalse(service.lotSubscriptionPending(lotID)); XCTAssertFalse(service.lotSubscriptionPending(sessionID))
        XCTAssertEqual(service.lastOutcome, "")
    }
    func testLotViewerKeepsShownCopyUntilRefreshAndRendersPhoneAndPad() async throws {
        let service = try service(), model = PadModel(service: service)
        let home = String(repeating: "d", count: 64), sid = UUID()
        let id = DeviceGlobalID(home: home, session: sid).string
        let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Home")
        peer.hello = DeviceHello(deviceID: home, deviceName: "Home", converseVersion: "test"); peer.trustedReady = true
        let row = DeviceSidebarRow(globalID: id, sessionID: sid, title: "Roadmap", assistant: "Parking Lot", engine: "parking", model: "", effort: "", access: "read only", status: "Parking Lot · read only", busy: false, queued: 0, queuePaused: false)
        service.handleEnvelope(peer, DeviceEnvelope(kind: "sidebar.snapshot", homeSeq: 1, payload: try JSONEncoder().encode(DeviceSidebarPayload(homeDeviceID: home, homeDeviceName: "Home", homeSeq: 1, rows: [row]))))
        model.state.placements[0] = id; service.remoteLeases[id] = 0
        func send(_ seq: UInt64, _ messages: [DeviceWireMessage]) throws {
            let payload = DeviceTranscriptPayload(globalID: id, homeSeq: seq, epoch: 0, messages: messages, total: messages.count, draft: "", draftVersion: seq, busy: false, status: "Parking Lot · read only", title: "Roadmap", engine: "parking")
            service.handleEnvelope(peer, DeviceEnvelope(kind: "transcript.snapshot", sessionID: id, epoch: 0, payload: try JSONEncoder().encode(payload)))
            model.reconcileLots()
        }
        let heading = lotMessage(lotText(heading: true, "Now")), first = lotMessage(lotText(number: 1, "First https://example.com", notes: [("Richard", "Why?")]))
        let second = lotMessage(lotText(number: 2, done: true, "Second"), images: ["missing-hash"])
        let later = lotMessage(lotText(heading: true, "Later")), third = lotMessage(lotText(number: 1, "Third"))
        try send(2, [heading, first, second, later, third])
        XCTAssertEqual(model.lotViews[id]?.displayed?.count, 5); XCTAssertEqual(model.lotViews[id]?.refreshAvailable, false)
        try send(3, [heading, first, second, later, third])
        XCTAssertEqual(model.lotViews[id]?.refreshAvailable, false, "Resent unchanged lot shows no Refresh")
        // Deleting the first section: the session transcript merge would keep
        // the deleted rows; the lot viewer uses the whole new document.
        try send(4, [later, third])
        XCTAssertEqual(model.lotViews[id]?.refreshAvailable, true)
        XCTAssertEqual(model.lotViews[id]?.displayed?.map(\.id), [heading, first, second, later, third].map(\.id), "Shown copy waits for Refresh")
        model.applyLotRefresh(id)
        XCTAssertEqual(model.lotViews[id]?.displayed?.map(\.id), [later, third].map(\.id)); XCTAssertEqual(model.lotViews[id]?.refreshAvailable, false)
        try send(5, [lotMessage(lotText(number: 1, "Top")), later, third])
        XCTAssertEqual(model.lotViews[id]?.refreshAvailable, true)
        model.toggleLotHeading(id, heading: later.id); XCTAssertEqual(model.lotCollapsed[id], [later.id])
        for size in [CGSize(width: 390, height: 844), CGSize(width: 1024, height: 1366), CGSize(width: 320, height: 568)] {
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            let host = UIHostingController(rootView: PadPane(id: id, pane: 0, model: model)); window.rootViewController = host
            window.makeKeyAndVisible(); defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(150)); host.view.layoutIfNeeded()
            XCTAssertFalse(Self.views(host.view).contains { $0 is TailTextView }, "Lots use the read-only viewer, not the session editor")
        }
        model.park(id)
        XCTAssertNil(model.lotViews[id]); XCTAssertNil(service.remoteLeases[id])
        model.state.placements[0] = id; service.remoteLeases[id] = 0
        service.handleEnvelope(peer, DeviceEnvelope(kind: "sidebar.snapshot", homeSeq: 6, payload: try JSONEncoder().encode(DeviceSidebarPayload(homeDeviceID: home, homeDeviceName: "Home", homeSeq: 6, rows: []))))
        XCTAssertNil(service.remoteLotSnapshots[id], "Deleted lots drop their copy")
    }
    static func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap { views($0) } }
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
        XCTAssertNotNil(row.lastResponseAt, "The Mac home reports its latest response time")
        XCTAssertFalse(service.remoteMarkers(row).unseen, "First sight of a home session after install is not unseen")
        service.acquireRemote(globalID: row.globalID)
        try await eventually("Group member takes the home session") { service.remoteTranscripts[row.globalID] != nil }
        let transcript = try XCTUnwrap(service.remoteTranscripts[row.globalID])
        XCTAssertTrue(transcript.messages.contains { $0.text.contains("verified code " + code) }, "Mac Review saw the exact number the iPad displayed first")
        XCTAssertEqual(transcript.draft, "home draft")
        let home = try XCTUnwrap(DeviceGlobalID(row.globalID)?.home)
        let imageModel = PadModel(service: service); imageModel.state.placements[0] = row.globalID; imageModel.reconcile()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 40, height: 40)) }
        let hash = try XCTUnwrap(imageModel.attach(row.globalID, data: try XCTUnwrap(image.pngData())))
        try await eventually("Image tool input reaches authenticated home draft") { service.blobReady[hash] == true && service.remoteTranscripts[row.globalID]?.draftImageHashes == [hash] }
        let epoch = try XCTUnwrap(service.remoteLeases[row.globalID])
        let operation = DeviceImageAssistRequest(hash: hash, operation: "describe", epoch: epoch)
        let staleImage = await service.requestParticipant(home: home, action: "image.assist", target: row.globalID, imageAssist: DeviceImageAssistRequest(hash: hash, operation: "describe", epoch: epoch + 1))
        XCTAssertEqual(staleImage.outcome, "rejected", "Stale viewers cannot start paid image processing")
        let missing = await service.requestParticipant(home: home, action: "image.assist", target: row.globalID, imageAssist: DeviceImageAssistRequest(hash: String(repeating: "0", count: 64), operation: "describe", epoch: epoch))
        XCTAssertEqual(missing.outcome, "rejected", "Unattached blobs cannot be processed")
        let operationID = UUID()
        let described = await service.requestParticipant(home: home, action: "image.assist", target: row.globalID, imageAssist: operation, id: operationID)
        XCTAssertEqual(described.outcome, "completed", described.detail)
        XCTAssertEqual(described.imageAssist?.notes, "Synthetic image result #1")
        service.participantIntents.removeAll { $0.id == operationID } // Force a round trip to the home receipt, not the viewer cache.
        let replay = await service.requestParticipant(home: home, action: "image.assist", target: row.globalID, imageAssist: operation, id: operationID)
        XCTAssertEqual(replay.imageAssist?.notes, described.imageAssist?.notes, "Retry returns the same result without another paid request")
        service.participantIntents.removeAll { $0.id == operationID }
        let altered = await service.requestParticipant(home: home, action: "image.assist", target: row.globalID, imageAssist: DeviceImageAssistRequest(hash: hash, operation: "focus", epoch: epoch, x: 1, y: 1), id: operationID)
        XCTAssertEqual(altered.outcome, "rejected", "Home binds an operation ID to its original image request")
        XCTAssertEqual(imageModel.draft(row.globalID).text, "home draft", "Receiving image notes never replaces or submits the draft")
        imageModel.removeImage(row.globalID, hash: hash)
        let removed = await service.requestParticipant(home: home, action: "image.assist", target: row.globalID, imageAssist: operation)
        XCTAssertEqual(removed.outcome, "rejected", "Removed attachments cannot start new processing")
        let oldLeases = service.remoteLeases
        let created = await service.requestParticipant(home: home, action: "agent.create", title: "iPad-created paused agent")
        XCTAssertEqual(created.outcome, "completed", created.detail)
        let target = try XCTUnwrap(created.target)
        try await eventually("The paused Mac agent shows the red paused marker with its reason on iPad") {
            service.remoteRow(globalID: target).map { service.remoteMarkers($0).paused && service.remoteMarkers($0).pausedReason?.isEmpty == false && !service.remoteMarkers($0).unseen } == true
        }
        let loaded = await service.requestParticipant(home: home, action: "agent.settings", target: target)
        var settings = try XCTUnwrap(loaded.settings)
        XCTAssertFalse(settings.enabled)
        XCTAssertTrue(settings.watched.isEmpty)
        settings.scheduleText = "every 20 minutes while the US stock market is open"
        settings.scheduleTimeZone = "America/New_York"
        settings.discordShareSessionInformation = true
        settings.discordShareScoreboard = true
        settings.artDirection = "Playful watercolor robots celebrating verified progress"
        settings.objective = "Persist the edited objective from the iPad"
        settings.remainingRuns = 0; settings.turnLimit = 3; settings.enabled = true
        let saved = await service.requestParticipant(home: home, action: "agent.configure", target: target, settings: settings)
        XCTAssertEqual(saved.outcome, "completed", saved.detail)
        XCTAssertEqual(saved.settings?.turnLimit, 3, "Save acknowledges the per-activation limit even with an exhausted legacy counter")
        XCTAssertEqual(saved.settings?.enabled, true, "The iPad can restart a loop using a text schedule")
        try await eventually("Restarting the loop republishes the iPad row unpaused") { service.remoteRow(globalID: target).map { !service.remoteMarkers($0).paused } == true }
        let refreshed = await service.requestParticipant(home: home, action: "agent.settings", target: target)
        // Since 0.6.0 the Mac home moves a remote editor's text schedule into the objective.
        let schedule = settings.scheduleText ?? ""
        XCTAssertEqual(refreshed.settings?.scheduleText ?? "", "", "The home no longer keeps a separate text schedule")
        XCTAssertEqual(refreshed.settings?.objective, schedule.isEmpty ? settings.objective : settings.objective + "\nSchedule: " + schedule, "A remote text schedule is preserved as the objective's last line")
        XCTAssertEqual(refreshed.settings?.artDirection, settings.artDirection, "Art direction survives a remote save and reload independently of the objective")
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
    func testMessageNumbersIgnoreDraftNewlinesAndPreserveHomeOrdinals() async throws {
        var first = DeviceWireMessage(id: UUID(), role: "user", text: "First paragraph\n\nSecond paragraph", messageNumber: 41)
        var second = DeviceWireMessage(id: UUID(), role: "assistant", text: "Reply\nwith another line", messageNumber: 42)
        let hidden = DeviceWireMessage(id: UUID(), role: "activity", text: "Working")
        let empty = DeviceWireMessage(id: UUID(), role: "assistant", text: "")
        var parent = PadTranscript(messages: [first, hidden, empty, second], draft: "Draft\n\nmore draft", images: [:], editable: true, lineNumbers: true, edit: { _ in }, send: { XCTFail("Newline must not send") }, attach: { _ in })
        let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        let coordinator = PadTranscript.Coordinator(parent); view.delegate = coordinator
        parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.messageLabels.map(\.number), [41, 42])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        let controller = UIViewController(); controller.view = view; window.rootViewController = controller
        window.makeKeyAndVisible(); defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250)); view.layoutIfNeeded()
        let screenshot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        screenshot.name = "Message numbers leave multiline drafts unnumbered"; screenshot.lifetime = .keepAlways; add(screenshot)
        let locations = view.messageLabels.map(\.location)
        view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
        view.hardwareReturn(modifiers: .shift); view.hardwareReturn(modifiers: .command)
        XCTAssertEqual(view.messageLabels.map(\.number), [41, 42], "Draft newlines do not create new message numbers")
        XCTAssertEqual(view.messageLabels.map(\.location), locations)
        XCTAssertTrue(view.textStorage.string.hasSuffix("\n\n"))
        let older = DeviceWireMessage(id: UUID(), role: "assistant", text: "Older message", messageNumber: 40)
        parent.messages = [older, first, second]; parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.messageLabels.map(\.number), [40, 41, 42], "Loading earlier history preserves existing numbers")
        first.messageNumber = 51; second.messageNumber = 52
        parent.messages = [first, second]; parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.messageLabels.map(\.number), [51, 52], "Number-only home updates invalidate the display cache")
        first.messageNumber = nil; second.messageNumber = nil
        parent.messages = [first, hidden, empty, second]; parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.messageLabels.map(\.number), [1, 2], "Older homes still number visible messages, not lines")
        let notice = DeviceWireMessage(id: UUID(), role: "notice", text: "Switchboard: queued")
        let receipt = DeviceWireMessage(id: UUID(), role: "notice", text: "Switchboard: message queued from test")
        parent.messages = [first, notice, receipt, second]; parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.messageLabels.map(\.number), [1, 2, 3], "Like the Mac, visible notices consume one number; hidden queue receipts consume none")
        first.messageNumber = Int.max
        parent.messages = [first, second]; parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.messageLabels.map(\.number), [Int.max, Int.max], "An extreme home ordinal cannot overflow")
        parent.messages = []; parent.update(view, coordinator: coordinator)
        XCTAssertTrue(view.messageLabels.isEmpty, "An unsent draft has no message number")
    }

    func testDraftImageKeyboardDeletionAndMenusProtectHistory() throws {
        let service = try service(), model = PadModel(service: service)
        let id = DeviceGlobalID(home: "test-home", session: UUID()).string
        service.remoteLeases[id] = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 100)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        }
        let file = service.storageFolder.appendingPathComponent("keyboard-draft-preview.png")
        try XCTUnwrap(image.pngData()).write(to: file)
        let historical = DeviceWireMessage(id: UUID(), role: "assistant", text: "Keep history", imageHashes: ["one"])
        for scenario in ["tail", "delegate", "attachment", "selected", "mixed", "text", "history", "read-only"] {
            model.state.drafts[id] = PadDraft(text: "Keep text", hashes: ["one", "two"], dirty: true)
            var parent = PadTranscript(messages: [historical], draft: model.draft(id).text, images: ["one": file, "two": file], draftImageHashes: model.draft(id).hashes, editable: true, lineNumbers: true, edit: { model.edit(id, text: $0) }, send: { XCTFail("Deleting never sends") }, attach: { _ in }, removeImage: { model.removeImage(id, hash: $0) })
            let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
            let coordinator = PadTranscript.Coordinator(parent); view.delegate = coordinator
            parent.update(view, coordinator: coordinator)
            let first = try XCTUnwrap(view.draftImages.first), last = try XCTUnwrap(view.draftImages.last)
            let history = view.textStorage.attributedSubstring(from: NSRange(location: 0, length: first.location)).string
            XCTAssertEqual(coordinator.imageMenuActions(view, range: NSRange(location: last.location, length: 1)).map(\.title), ["Remove image from draft"])
            XCTAssertTrue(coordinator.imageMenuActions(view, range: NSRange(location: first.location - 2, length: 1)).isEmpty)
            switch scenario {
            case "text": view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
            case "tail", "delegate": view.selectedRange = NSRange(location: view.historyLength, length: 0)
            case "attachment": view.selectedRange = NSRange(location: last.location + 1, length: 0)
            case "selected": view.selectedRange = NSRange(location: last.location, length: 1)
            case "mixed": view.selectedRange = NSRange(location: last.location, length: view.historyLength + 4 - last.location)
            case "history": view.selectedRange = NSRange(location: first.location - 1, length: view.historyLength - first.location + 1)
            default:
                parent.editable = false; parent.update(view, coordinator: coordinator)
                XCTAssertTrue(coordinator.imageMenuActions(view, range: NSRange(location: last.location, length: 1)).isEmpty)
                view.selectedRange = NSRange(location: view.historyLength, length: 0)
            }
            if scenario == "delegate" {
                XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: view.historyLength - 1, length: 1), replacementText: ""))
            } else { view.deleteBackward() }
            let expected = ["text", "history", "read-only"].contains(scenario) ? ["one", "two"] : ["one"]
            XCTAssertEqual(model.draft(id).hashes, expected, scenario)
            XCTAssertEqual(model.draft(id).text, scenario == "mixed" ? " text" : scenario == "text" ? "Keep tex" : "Keep text", scenario)
            parent.draft = model.draft(id).text; parent.draftImageHashes = model.draft(id).hashes
            parent.update(view, coordinator: coordinator)
            XCTAssertEqual(view.textStorage.attributedSubstring(from: NSRange(location: 0, length: first.location)).string, history, scenario)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Never delete the image file used by history")
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
        // Web images never load unasked; the viewer shows the caption and full URL.
        XCTAssertEqual(rendered.string, "Grasshopper: " + url.absoluteString)
        XCTAssertEqual(rendered.attribute(.link, at: ("Grasshopper: " as NSString).length, effectiveRange: nil) as? URL, url)
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
        coordinator.textViewDidChange(view); XCTAssertEqual(edits, "draftx", "Typing in history redirects the character into the draft")
        coordinator.parent.editable = false
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 13, length: 0), replacementText: "x"))
    }
    func testTypingFromHistoryRevealsDraftWithoutChangingHistory() {
        let history = String(repeating: "History remains protected.\n", count: 80)
        var edited = ""
        let parent = PadTranscript(messages: [DeviceWireMessage(id: UUID(), role: "assistant", text: history)], draft: "draft", images: [:], editable: true, lineNumbers: true, edit: { edited = $0 }, send: {}, attach: { _ in })
        let coordinator = PadTranscript.Coordinator(parent)
        let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 320, height: 200); view.delegate = coordinator
        parent.update(view, coordinator: coordinator)
        let protectedText = (view.text as NSString).substring(to: view.historyLength)
        view.setContentOffset(.zero, animated: false); view.selectedRange = NSRange(location: 1, length: 5)
        coordinator.explicitSelection = true; coordinator.follow.pause(now: 0)
        view.insertText("x")
        XCTAssertEqual(edited, "draftx")
        XCTAssertEqual((view.text as NSString).substring(to: view.historyLength), protectedText)
        XCTAssertEqual(view.contentOffset.y, view.contentSize.height - view.bounds.height, accuracy: 1)
        XCTAssertTrue(coordinator.follow.following)
        view.setContentOffset(.zero, animated: false); view.selectedRange = NSRange(location: 1, length: 5)
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: view.selectedRange, replacementText: " pasted words"))
        XCTAssertEqual(edited, "draftx pasted words", "UIKit replacement redirects without losing the first character")
        XCTAssertEqual((view.text as NSString).substring(to: view.historyLength), protectedText)
        XCTAssertEqual(view.contentOffset.y, view.contentSize.height - view.bounds.height, accuracy: 1)
        view.isEditable = false; view.setContentOffset(.zero, animated: false); view.selectedRange = NSRange(location: 1, length: 0)
        view.insertText("blocked")
        XCTAssertEqual(edited, "draftx pasted words"); XCTAssertEqual(view.contentOffset.y, 0)
    }
    func testAttachmentCaretAndResizeHandle() throws {
        let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 400, height: 500)
        let attachment = NSTextAttachment(); attachment.bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        let content = NSMutableAttributedString(attachment: attachment)
        content.append(NSAttributedString(string: "\nDraft", attributes: PadTranscript.draftAttributes("Draft")))
        view.textStorage.setAttributedString(content); view.layoutManager.ensureLayout(for: view.textContainer)
        for offset in [0, 1] {
            let position = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: offset))
            let caret = view.caretRect(for: position)
            XCTAssertGreaterThan(caret.height, 0)
            XCTAssertLessThanOrEqual(caret.height, UIFont.systemFont(ofSize: 16).lineHeight + 1, "Clicking an image must not create an image-height caret")
        }
        let handle = PadResizeHandle(frame: CGRect(x: 0, y: 0, width: PadSidebarDivider.width, height: 500))
        let pointer = try XCTUnwrap(handle.interactions.compactMap { $0 as? UIPointerInteraction }.first)
        XCTAssertNotNil(handle.pointerInteraction(pointer, styleFor: UIPointerRegion(rect: handle.bounds, identifier: nil)))
        XCTAssertGreaterThanOrEqual(handle.bounds.width, 20)
        var width: CGFloat = 200; var saves = 0
        handle.drag = { width += $0 }; handle.end = { saves += 1 }
        handle.accessibilityIncrement(); XCTAssertEqual(width, 220)
        handle.accessibilityDecrement(); XCTAssertEqual(width, 200); XCTAssertEqual(saves, 2)
    }
    func testSnapshotEchoPreservesDraftSelectionAndBlueStyle() {
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
        XCTAssertEqual(view.textStorage.attribute(.foregroundColor, at: coordinator.historyLength, effectiveRange: nil) as? UIColor, UIColor.systemBlue)
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
    func testReadingNeverTimesOutAndHonorsSelectionAndTake() {
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
        clock += 3600; coordinator.resumeIfIdle()
        parent.update(view, coordinator: coordinator); view.layoutIfNeeded()
        XCTAssertEqual(view.contentOffset.y, 100, accuracy: 1, "Idle refresh never scrolls even with the cursor at the tail")
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
    func testHelpVideoLinksOpenThePlayerAndOtherLinksDoNot() async throws {
        let book = try HelpBook.load()
        let video = try XCTUnwrap(book.videos?.first { $0.id == "first-run" })
        let media = try XCTUnwrap(URL(string: video.mediaURL))
        XCTAssertTrue(book.topics.first { $0.id == "videos" }?.markdown.contains(video.mediaURL) == true)
        XCTAssertEqual(HelpVideo.route(media, in: book.videos ?? []), video)
        XCTAssertNil(HelpVideo.route(URL(string: video.mediaURL + "?X-Amz-Signature=abc")!, in: book.videos ?? []))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = folder.appendingPathComponent("fixture-v1.mp4")
        try HelpVideoFixture.writeMP4(to: fixture)
        // The same presenter backs PadHelp's openURL handler and its sheet.
        let presenter = HelpVideoPresenter(videos: book.videos ?? []) { _ in fixture }
        XCTAssertFalse(presenter.open(ConverseAbout.readme), "README links go to the system")
        XCTAssertNil(presenter.playback, "No sheet for ordinary links")
        XCTAssertTrue(presenter.open(media))
        let playback = try XCTUnwrap(presenter.playback, "A manifest link presents the video sheet")
        XCTAssertEqual(playback.video, video)
        try await eventually("Local fixture plays") { playback.state == .ready && (playback.player?.rate ?? 0) > 0 }
        let player = playback.player
        presenter.close()
        XCTAssertNil(presenter.playback, "Dismissing clears the sheet")
        XCTAssertNil(playback.player, "Dismissing releases the player")
        XCTAssertEqual(player?.rate, 0, "Dismissing stops playback")
        XCTAssertNil(player?.currentItem)
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
        XCTAssertTrue(service.remoteDisplayReconnecting(row.globalID), "Backgrounded pane says Reconnecting, not Take")
        try service.startNetworkForTesting(); service.connectManual(host: "127.0.0.1", port: port)
        try await eventually("Trusted home reconnects") { service.homes[DeviceGlobalID(row.globalID)!.home]?.online == true }
        try await eventually("Saved iPad pane restores automatically after background without Take") { (service.remoteLeases[row.globalID] ?? 0) > firstEpoch && service.remoteTranscripts[row.globalID] != nil }
        XCTAssertFalse(service.remoteDisplayReconnecting(row.globalID), "Reconnecting clears once the lease and transcript arrive")
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
    func testPhonePickerToggleOffSurvivesRealHomeRoundTrip() async throws {
        guard let port = ProcessInfo.processInfo.environment["CONVERSE_INTEROP_PORT"].flatMap(Int.init), port > 0 else { throw XCTSkip("Run iPad/test.sh --interop with an isolated Mac home") }
        let service = try service(); defer { service.suspendViewer() }
        try service.startNetworkForTesting()
        service.connectManual(host: "127.0.0.1", port: port)
        try await eventually("Pair isolated home") { service.pairingPrompt != nil }
        service.confirmPairing()
        try await eventually("Load home directory") { service.homes.values.contains { !$0.rows.isEmpty } }
        let row = try XCTUnwrap(service.homes.values.flatMap(\.rows).first)
        let model = PadModel(service: service)
        model.togglePhoneSession(row.globalID)
        try await eventually("Take initial lease") { service.remoteLeases[row.globalID] != nil }
        XCTAssertTrue(model.state.placements.contains(row.globalID))
        model.togglePhoneSession(row.globalID)
        XCTAssertFalse(model.state.placements.contains(row.globalID), "Unchecking closes the session")
        try await Task.sleep(for: .seconds(3))
        model.reconcile()
        XCTAssertFalse(model.state.placements.contains(row.globalID), "Unchecking a live session must close it, not recheck")
        XCTAssertNil(service.remoteLeases[row.globalID], "A parked session holds no lease")
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

final class LotEditingTests: XCTestCase {
    func testSharedLotEditingContract() {
        lotEditingSelfTests { value, label in XCTAssertTrue(value, label) }
    }
}

extension ConverseTests {
    func testEditableLotTakeSaveAndPhonePadLayouts() async throws {
        XCTAssertEqual(EditableLotPane.links(in: "https://example.com https://example.com file:///Users/someone/private.txt me@example.org").map(\.scheme), ["https", "mailto"], "Only explicit web and email links open on the viewing device; home file paths stay text")
        let service = try service(); service.editableLotsEnabled = true
        let model = PadModel(service: service)
        service.deviceNameOverride = "iPhone"
        let home = String(repeating: "e", count: 64), lot = UUID(), id = DeviceGlobalID(home: String(repeating: "e", count: 64), session: lot).string
        let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Home")
        peer.hello = DeviceHello(deviceID: home, deviceName: "Home", converseVersion: "test"); peer.hello!.capabilities.append(LotEditing.capability); peer.trustedReady = true
        service.adoptPeerForTesting(peer)
        let sidebar = DeviceSidebarRow(globalID: id, sessionID: lot, title: "Mobile Roadmap", assistant: "Parking Lot", engine: "parking", model: "", effort: "", access: "edit", status: "Parking Lot", busy: false, queued: 0, queuePaused: false)
        service.handleEnvelope(peer, DeviceEnvelope(kind: "sidebar.snapshot", homeSeq: 1, payload: try JSONEncoder().encode(DeviceSidebarPayload(homeDeviceID: home, homeDeviceName: "Home", homeSeq: 1, rows: [sidebar]))))
        model.assign(id, pane: 0)
        service.handleEnvelope(peer, DeviceEnvelope(kind: "lease.granted", boot: 9, sessionID: id, epoch: 4))
        let heading = ParkingLotRow(heading: true, text: "Things to build")
        let item = ParkingLotRow(heading: false, text: "Edit this item on your phone", notes: [ParkingLotNote(author: "Richard", text: "Keep my note")], parentID: heading.id, tag: .green)
        let child = ParkingLotRow(heading: false, text: "Keep nested items with their parent", done: true, parentID: item.id)
        let snapshot = try LotSnapshot(globalID: id, homeBoot: 9, leaseEpoch: 4, name: "Mobile Roadmap", document: ParkingLotDocument(revision: 12, rows: [heading, item, child]))
        service.handleEnvelope(peer, try snapshot.envelope())
        XCTAssertTrue(service.lotCanEdit(id)); XCTAssertEqual(service.lotEditors[id]?.projected.rows.count, 3)
        service.handleEnvelope(peer, DeviceEnvelope(kind: "lease.expired", boot: 9, sessionID: id, epoch: 4))
        XCTAssertFalse(service.lotCanEdit(id))
        XCTAssertTrue(service.lotEditors[id]?.frozenReason?.contains("No unsaved changes") == true)
        XCTAssertNil(service.lotRecovery[id])
        service.restoreAvailableDisplays()
        service.handleEnvelope(peer, DeviceEnvelope(kind: "lease.granted", boot: 9, sessionID: id, epoch: 4))
        service.handleEnvelope(peer, try snapshot.envelope())
        XCTAssertTrue(service.lotCanEdit(id), "An authenticated fresh snapshot resumes the clean editor")
        XCTAssertEqual(service.lotEditors[id]?.unconfirmedCount, 0)
        for width: CGFloat in [430, 1024] {
            for style: UIUserInterfaceStyle in [.light, .dark] {
                let host = UIHostingController(rootView: EditableLotPane(id: id, pane: 0, model: model).frame(width: width))
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: width, height: 900); window.overrideUserInterfaceStyle = style; window.rootViewController = host; window.makeKeyAndVisible()
                host.view.frame = window.bounds; host.view.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 100_000_000)
                let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
                attachment.name = "Editable lot \(Int(width)) \(style == .dark ? "dark" : "light")"; attachment.lifetime = .keepAlways; add(attachment)
                XCTAssertTrue(Self.views(host.view).contains { ($0 as? UITextView)?.text == item.text || ($0 as? UITextField)?.text == item.text }, "Native editable text renders at phone and tablet sizes")
                let pointerHost = try XCTUnwrap(Self.views(host.view).compactMap { $0 as? LotPointerSelectionHost }.first)
                let gestureHost = try XCTUnwrap(pointerHost.gesture.view)
                XCTAssertTrue(Self.views(gestureHost).contains { ($0 as? UITextView)?.text == item.text }, "Pointer recognizer observes the editor, not only a decorative background sibling")
                XCTAssertTrue(pointerHost.gesture.frames.keys.contains(child.id), "Pointer hit testing receives visible row geometry")
                window.isHidden = true
            }
        }
        model.state.paneTextSizes = [24, 16, 16]
        let selectionHost = UIHostingController(rootView: EditableLotPane(id: id, pane: 0, model: model, initialSelection: [item.id, child.id]).frame(width: 430))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let selectionWindow = UIWindow(windowScene: scene); selectionWindow.frame = CGRect(x: 0, y: 0, width: 430, height: 900)
        selectionWindow.overrideUserInterfaceStyle = .light; selectionWindow.rootViewController = selectionHost; selectionWindow.makeKeyAndVisible()
        selectionHost.view.frame = selectionWindow.bounds; selectionHost.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let selectionImage = XCTAttachment(image: UIGraphicsImageRenderer(bounds: selectionWindow.bounds).image { _ in selectionWindow.drawHierarchy(in: selectionWindow.bounds, afterScreenUpdates: true) })
        selectionImage.name = "Selected lot entries at 24pt"; selectionImage.lifetime = .keepAlways; add(selectionImage)
        selectionWindow.isHidden = true
        let timingFolder = FileManager.default.temporaryDirectory.appendingPathComponent("lot-timing-" + UUID().uuidString)
        let capture = PerformanceCapture.shared
        capture.configure(folder: timingFolder, enabled: true, sampleMainQueue: false)
        defer {
            capture.configure(folder: timingFolder, enabled: false, sampleMainQueue: false)
            capture.flushForTesting(); try? FileManager.default.removeItem(at: timingFolder)
        }
        func timings() throws -> PerformanceCapture.Snapshot {
            capture.flushForTesting()
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PerformanceCapture.Snapshot.self, from: Data(contentsOf: XCTUnwrap(capture.file)))
        }
        try service.editLot(id, operation: LotOperation(kind: .setText, rowID: item.id, text: "Typed on phone"))
        let flight = try XCTUnwrap(service.lotEditors[id]?.inFlight)
        XCTAssertEqual(try timings().pendingRoundTrips, 1, "Actual edit dispatch starts the round-trip clock")
        XCTAssertEqual(service.lotEditors[id]?.saved.document.revision, 12, "Optimistic typing does not claim a saved revision")
        let result = try flight.operation.applying(to: snapshot.document, author: "iPhone")
        let saved = try LotSnapshot(globalID: id, homeBoot: 9, leaseEpoch: 4, name: snapshot.name, document: result)
        let ack = LotEditAck(mutationID: flight.mutationID, sequence: flight.sequence, snapshot: saved)
        let unrelatedAck = LotEditAck(mutationID: UUID(), sequence: flight.sequence, snapshot: saved)
        service.handleEnvelope(peer, DeviceEnvelope(kind: "lot.edit.ack", boot: 9, sessionID: id, epoch: 4, payload: try LotEditing.encoded(unrelatedAck)))
        XCTAssertEqual(try timings().pendingRoundTrips, 1, "An unrelated acknowledgment cannot finish the measurement")
        service.handleEnvelope(peer, DeviceEnvelope(kind: "lot.edit.ack", boot: 9, sessionID: id, epoch: 4, payload: try LotEditing.encoded(ack)))
        service.handleEnvelope(peer, DeviceEnvelope(kind: "lot.edit.ack", boot: 9, sessionID: id, epoch: 4, payload: try LotEditing.encoded(ack)))
        XCTAssertEqual(try timings().summaries["lotRoundTrip"]?.count, 1, "Actual acknowledgment handling measures a mutation once")
        XCTAssertEqual(try timings().pendingRoundTrips, 0)
        XCTAssertEqual(service.lotEditors[id]?.unconfirmedCount, 0); XCTAssertEqual(service.lotEditors[id]?.saved.document.rows[1].text, "Typed on phone")
        try service.editLot(id, operation: LotOperation(kind: .setText, rowID: item.id, text: "Unconfirmed words to recover"))
        service.handleEnvelope(peer, DeviceEnvelope(kind: "lease.stolen", boot: 9, sessionID: id, epoch: 5))
        XCTAssertEqual(try timings().pendingRoundTrips, 0, "Displacement removes the abandoned in-flight timer")
        XCTAssertEqual(try timings().droppedRoundTrips, 1, "Displacement is reported as abandoned, not a fast acknowledgment")
        XCTAssertFalse(service.lotCanEdit(id)); XCTAssertFalse(model.state.placements.contains(id))
        XCTAssertEqual(service.lotRecovery[id]?.rows[1].text, "Unconfirmed words to recover", "Displacement retains an explicit manual recovery copy")
        model.assign(id, pane: 0)
        service.handleEnvelope(peer, DeviceEnvelope(kind: "lease.granted", boot: 10, sessionID: id, epoch: 6))
        let retaken = try LotSnapshot(globalID: id, homeBoot: 10, leaseEpoch: 6, name: saved.name, document: saved.document)
        service.handleEnvelope(peer, try retaken.envelope())
        XCTAssertTrue(service.lotCanEdit(id)); XCTAssertEqual(service.lotEditors[id]?.unconfirmedCount, 0)
        XCTAssertEqual(service.lotEditors[id]?.projected.rows[1].text, "Typed on phone", "A new take never replays unconfirmed edits")
        XCTAssertEqual(service.lotRecovery[id]?.rows[1].text, "Unconfirmed words to recover", "Recovery survives retake for manual copy")
        try service.editLot(id, operation: LotOperation(kind: .setText, rowID: item.id, text: "Pending at background"))
        service.handleEnvelope(peer, DeviceEnvelope(kind: "lease.expired", boot: 10, sessionID: id, epoch: 6))
        service.restoreAvailableDisplays()
        service.handleEnvelope(peer, DeviceEnvelope(kind: "lease.granted", boot: 10, sessionID: id, epoch: 7))
        XCTAssertNil(service.remoteLeases[id], "No automatic resume request exists: an unsolicited grant cannot replay unconfirmed edits")
        XCTAssertTrue(service.lotEditors[id]?.frozenReason?.contains("unconfirmed") == true)
        service.suspendViewer()
        XCTAssertFalse(service.lotCanEdit(id), "Backgrounding immediately ends editing authority")
        XCTAssertNotNil(service.lotEditors[id]?.frozenReason)
        XCTAssertEqual(service.lotRecovery[id]?.rows[1].text, "Pending at background", "Pending text remains available for explicit Copy while the process lives")
        XCTAssertThrowsError(try service.editLot(id, operation: LotOperation(kind: .setText, rowID: item.id, text: "Must not edit offline")))
    }
}

extension ConverseTests {
    func testEditableLotAcrossMacAndTwoMobileHolders() async throws {
        guard ProcessInfo.processInfo.environment["CONVERSE_LOT_EDIT_INTEROP"] == "1",
              let port = ProcessInfo.processInfo.environment["CONVERSE_GROUP_PORT"].flatMap(Int.init), port > 0 else {
            throw XCTSkip("Requires the isolated editable-lot Mac fixture")
        }
        let phone = try service(), tablet = try service()
        defer { phone.suspendViewer(); tablet.suspendViewer() }
        for (viewer, name) in [(phone, "Editor phone"), (tablet, "Editor tablet")] {
            viewer.editableLotsEnabled = true; viewer.deviceNameOverride = name
            try viewer.enableGroupsForTesting(); try viewer.startNetworkForTesting()
            viewer.joinGroupByAddress(host: "127.0.0.1", port: port)
            try await eventually("Editor joins Mac group") { viewer.pairingPrompt != nil }
            viewer.confirmPairing()
            try await eventually("Editor discovers lot") { viewer.homes.values.flatMap(\.rows).contains { $0.engine == "parking" } }
        }
        let row = try XCTUnwrap(phone.homes.values.flatMap(\.rows).first { $0.engine == "parking" })
        let id = row.globalID
        phone.isPlaced = { $0 == id }; tablet.isPlaced = { $0 == id }
        phone.acquireRemote(globalID: id)
        try await eventually("Phone takes structured lot") { phone.lotCanEdit(id) }
        let initial = try XCTUnwrap(phone.lotEditors[id]?.saved)
        let item = try XCTUnwrap(initial.document.rows.first { !$0.heading })
        let imageHash = try XCTUnwrap(item.images?.first)
        try await eventually("Existing lot image downloads") { phone.blobCache[imageHash] != nil }
        try phone.editLot(id, operation: LotOperation(kind: .setText, rowID: item.id, text: "Saved from the actual mobile binary"))
        try phone.editLot(id, operation: LotOperation(kind: .setTag, rowID: item.id, tag: .purple))
        try phone.editLot(id, operation: LotOperation(kind: .appendComment, rowID: item.id, text: "Mobile comment", commentID: UUID()))
        try await eventually("Phone receives all home save acknowledgements") { phone.lotEditors[id]?.unconfirmedCount == 0 }
        XCTAssertNil(phone.lotEditors[id]?.frozenReason)
        let saved = try XCTUnwrap(phone.lotEditors[id]?.saved)
        XCTAssertEqual(saved.document.revision, initial.document.revision + 3)
        XCTAssertEqual(saved.document.rows.first { $0.id == item.id }?.notes?.last?.author, "Editor phone")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.systemPurple.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        let uploadedHash = try XCTUnwrap(phone.sendRemoteBlob(globalID: id, data: try XCTUnwrap(image.pngData())))
        try await eventually("Home stores newly attached image") { phone.lotBlobReady[id]?.contains(uploadedHash) == true }
        try phone.editLot(id, operation: LotOperation(kind: .addImage, rowID: item.id, imageHash: uploadedHash))
        try await eventually("Image reference is saved after its bytes") { phone.lotEditors[id]?.unconfirmedCount == 0 }
        // Take during an outstanding edit: the old holder must drain before the new grant.
        try phone.editLot(id, operation: LotOperation(kind: .setDone, rowID: item.id, done: true))
        tablet.acquireRemote(globalID: id)
        try await eventually("Tablet takes after phone drain") { tablet.lotCanEdit(id) && phone.remoteLeases[id] == nil }
        let moved = try XCTUnwrap(tablet.lotEditors[id]?.saved)
        XCTAssertGreaterThan(moved.leaseEpoch, saved.leaseEpoch)
        let movedRow = try XCTUnwrap(moved.document.rows.first { $0.id == item.id })
        XCTAssertTrue(movedRow.isDone); XCTAssertEqual(movedRow.tag, .purple)
        XCTAssertEqual(movedRow.text, "Saved from the actual mobile binary")
        XCTAssertEqual(movedRow.images, (item.images ?? []) + [uploadedHash])
        try await eventually("New holder downloads the newly attached image") { tablet.blobCache[uploadedHash] != nil }
        XCTAssertFalse(phone.lotCanEdit(id))
        tablet.releaseRemote(globalID: id)
        phone.acquireRemote(globalID: id)
        try await eventually("Park and retake preserve saved contents") { phone.lotCanEdit(id) && (phone.lotEditors[id]?.saved.leaseEpoch ?? 0) > moved.leaseEpoch }
        XCTAssertEqual(phone.lotEditors[id]?.saved.document, moved.document)
        let returned = try LotEntryEditing.splitting(item.id, at: NSRange(location: (movedRow.text as NSString).length, length: 0), in: moved.document.rows)
        try phone.editLot(id, operation: returned.operation)
        do { try await eventually("Return-created item is saved by the actual Mac home") { phone.lotEditors[id]?.unconfirmedCount == 0 } }
        catch {
            XCTFail("Return save state: " + String(describing: phone.lotEditors[id]?.frozenReason) + " / " + String(describing: phone.lotNotices[id]) + " / " + phone.lastOutcome)
            throw error
        }
        XCTAssertTrue(phone.lotEditors[id]?.saved.document.rows.contains { $0.id == returned.focus && $0.text.isEmpty } == true)
        try phone.editLot(id, operation: LotOperation(kind: .indent, rowIDs: [returned.focus]))
        try await eventually("Indent receives a home acknowledgement") { phone.lotEditors[id]?.unconfirmedCount == 0 }
        XCTAssertEqual(phone.lotEditors[id]?.saved.document.rows.first { $0.id == returned.focus }?.parentID, item.id)
        try phone.editLot(id, operation: LotOperation(kind: .outdent, rowIDs: [returned.focus]))
        try await eventually("Outdent receives a home acknowledgement") { phone.lotEditors[id]?.unconfirmedCount == 0 }
        XCTAssertEqual(phone.lotEditors[id]?.saved.document.rows.first { $0.id == returned.focus }?.parentID, movedRow.parentID)
        XCTAssertEqual(phone.lotEditors[id]?.saved.document.rows.first { $0.id == item.id }, movedRow, "Return and indent/outdent preserve the parent's metadata and images")
    }
}

extension ConverseTests {
    func testLotImageReceiptsAreScopedToLotAndAuthority() throws {
        let viewer = try service(); viewer.editableLotsEnabled = true
        let home = String(repeating: "f", count: 64)
        let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Home")
        peer.hello = DeviceHello(deviceID: home, deviceName: "Home", converseVersion: "test")
        peer.hello!.capabilities.append(LotEditing.capability); peer.trustedReady = true; viewer.adoptPeerForTesting(peer)
        let ids = [UUID(), UUID()]
        let sidebar = ids.map { lot in DeviceSidebarRow(globalID: DeviceGlobalID(home: home, session: lot).string, sessionID: lot, title: "Lot", assistant: "Parking Lot", engine: "parking", model: "", effort: "", access: "edit", status: "Parking Lot", busy: false, queued: 0, queuePaused: false) }
        viewer.handleEnvelope(peer, DeviceEnvelope(kind: "sidebar.snapshot", homeSeq: 1, payload: try JSONEncoder().encode(DeviceSidebarPayload(homeDeviceID: home, homeDeviceName: "Home", homeSeq: 1, rows: sidebar))))
        for (index, row) in sidebar.enumerated() {
            viewer.acquireRemote(globalID: row.globalID)
            viewer.handleEnvelope(peer, DeviceEnvelope(kind: "lease.granted", boot: 7, sessionID: row.globalID, epoch: UInt64(index + 1)))
            let snapshot = try LotSnapshot(globalID: row.globalID, homeBoot: 7, leaseEpoch: UInt64(index + 1), name: "Lot", document: ParkingLotDocument(rows: [ParkingLotRow(heading: true, text: "Now")]))
            viewer.handleEnvelope(peer, try snapshot.envelope())
        }
        let data = Data("identical image bytes in different lots".utf8)
        let hash = try XCTUnwrap(viewer.sendRemoteBlob(globalID: sidebar[0].globalID, data: data))
        XCTAssertEqual(viewer.sendRemoteBlob(globalID: sidebar[1].globalID, data: data), hash)
        let ack = try JSONEncoder().encode(DeviceAckPayload(outcome: "stored", detail: hash + "|Stored"))
        viewer.handleEnvelope(peer, DeviceEnvelope(kind: "blob.ack", boot: 7, sessionID: sidebar[0].globalID, epoch: 1, payload: ack))
        XCTAssertEqual(viewer.lotBlobReady[sidebar[0].globalID], [hash])
        XCTAssertFalse(viewer.lotBlobReady[sidebar[1].globalID]?.contains(hash) == true, "One lot's receipt cannot complete another lot's image upload")
        viewer.handleEnvelope(peer, DeviceEnvelope(kind: "blob.ack", boot: 6, sessionID: sidebar[1].globalID, epoch: 2, payload: ack))
        XCTAssertFalse(viewer.lotBlobReady[sidebar[1].globalID]?.contains(hash) == true, "Previous-boot image receipt is ignored")
        viewer.handleEnvelope(peer, DeviceEnvelope(kind: "blob.ack", boot: 7, sessionID: sidebar[1].globalID, epoch: 2, payload: ack))
        XCTAssertEqual(viewer.lotBlobReady[sidebar[1].globalID], [hash])
    }
}

extension ConverseTests {
    func testTextPinchUsesCursorOrAllPanesAndPersistsWithoutChangingDrafts() throws {
        let service = try service(), model = PadModel(service: service)
        model.state.drafts["unchanged"] = PadDraft(text: "Keep my draft")
        model.state.paneTextSizes = [16, 18, 20]
        model.cursorPane = 1
        model.pinchText(1.5)
        XCTAssertEqual(model.state.paneTextSizes, [16, 27, 20])
        model.pinchText(2)
        XCTAssertEqual(model.state.paneTextSizes, [16, 32, 20], "Every update uses the gesture's initial sizes, not the previous update")
        model.endTextPinch()
        let restored = PadModel(service: service)
        XCTAssertEqual(restored.state.paneTextSizes, [16, 32, 20])
        XCTAssertEqual(restored.state.drafts["unchanged"]?.text, "Keep my draft")
        model.cursorPane = nil; model.pinchText(0.5); model.endTextPinch()
        XCTAssertEqual(model.state.paneTextSizes, [12, 16, 12])
        let old = Data(#"{"placements":[null,null,null],"sidebarWidth":300,"sidebarHidden":false,"drafts":{}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(PadState.self, from: old).paneTextSizes, "An existing scene loads without a migration or setup reset")
    }

    func testTextResizeKeepsCaretDraftAndFontTraits() throws {
        let message = DeviceWireMessage(id: UUID(), role: "assistant", text: "A **bold** and *italic* message")
        var parent = PadTranscript(messages: [message], draft: "Keep this draft", images: [:], editable: true, lineNumbers: true, edit: { _ in XCTFail("Zoom must not edit the draft") }, send: {}, attach: { _ in })
        let view = TailTextView.native(); view.frame = CGRect(x: 0, y: 0, width: 430, height: 600)
        let coordinator = parent.makeCoordinator(); view.delegate = coordinator
        parent.update(view, coordinator: coordinator)
        view.selectedRange = NSRange(location: view.historyLength + 4, length: 3)
        let original = view.textStorage.string, selection = view.selectedRange
        parent.textSize = 24; parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.textStorage.string, original); XCTAssertEqual(view.selectedRange, selection)
        XCTAssertEqual((view.typingAttributes[.font] as? UIFont)?.pointSize, 24)
        let bold = (original as NSString).range(of: "bold").location
        let font = try XCTUnwrap(view.textStorage.attribute(.font, at: bold, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.pointSize, 24); XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        parent.textSize = 16; parent.update(view, coordinator: coordinator)
        XCTAssertEqual(view.textStorage.string, original); XCTAssertEqual(view.selectedRange, selection)
        XCTAssertEqual((view.textStorage.attribute(.font, at: bold, effectiveRange: nil) as? UIFont)?.pointSize, 16, "Restyling cannot compound the previous zoom")
    }

    func testTranscriptFontResizeBatchesLiveStorageLayout() throws {
        final class EditCounter: NSObject, NSTextStorageDelegate {
            var edits = 0
            func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
                edits += 1
            }
        }
        let view = TailTextView.native()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let text = NSMutableAttributedString()
        for index in 0..<300 {
            let font = index.isMultiple(of: 2) ? UIFont.systemFont(ofSize: 16) : UIFont.boldSystemFont(ofSize: 16)
            text.append(NSAttributedString(string: "Paragraph \(index): text with different font runs.\n", attributes: [.font: font]))
        }
        view.textStorage.setAttributedString(text)
        view.selectedRange = NSRange(location: text.length, length: 0)
        view.layoutIfNeeded()
        let counter = EditCounter(); view.textStorage.delegate = counter
        let selection = view.selectedRange
        let start = CACurrentMediaTime()
        PadTranscript.scaleFonts(view.textStorage, factor: 1.5)
        print("Transcript live font resize: \(CACurrentMediaTime() - start)s; \(counter.edits) storage notifications")
        XCTAssertEqual(counter.edits, 1, "Font resizing must invalidate live layout once, not once per font run")
        XCTAssertEqual(view.textStorage.string, text.string)
        XCTAssertEqual(view.selectedRange, selection)
        view.textStorage.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let font = value as! UIFont
            let old = text.attribute(.font, at: range.location, effectiveRange: nil) as! UIFont
            XCTAssertEqual(font.pointSize, 24)
            XCTAssertEqual(font.fontDescriptor.symbolicTraits, old.fontDescriptor.symbolicTraits)
        }
    }

    func testLotSelectionRangesAndBatchActionsPreserveUnselectedRows() throws {
        let heading = ParkingLotRow(heading: true, text: "Now")
        let parent = ParkingLotRow(heading: false, text: "Parent", parentID: heading.id)
        let child = ParkingLotRow(heading: false, text: "Child", parentID: parent.id)
        let sibling = ParkingLotRow(heading: false, text: "Sibling", parentID: heading.id)
        let doc = ParkingLotDocument(revision: 4, rows: [heading, parent, child, sibling])
        XCTAssertEqual(LotMenuSelection.range(from: sibling.id, to: parent.id, visible: doc.rows.map(\.id)), [parent.id, child.id, sibling.id])
        XCTAssertEqual(LotMenuSelection(ids: [parent.id, child.id, sibling.id]).roots(in: doc.rows).map(\.id), [parent.id, sibling.id], "Moving selected parents never moves a selected descendant twice")
        let ops = [LotOperation(kind: .setDone, rowID: parent.id, done: true), LotOperation(kind: .setDone, rowID: sibling.id, done: true), LotOperation(kind: .setTag, rowID: parent.id, tag: .red)]
        let changed = try LotMenuSelection.applying(ops, to: doc, author: "Tester")
        XCTAssertTrue(changed.rows[1].isDone); XCTAssertTrue(changed.rows[3].isDone); XCTAssertEqual(changed.rows[1].tag, .red)
        XCTAssertEqual(changed.rows[0], heading); XCTAssertEqual(changed.rows[2], child, "Done and color affect selected entries only, not their unselected children")
        let atomic = try LotOperation(kind: .replaceRows, rows: changed.rows).applying(to: doc, author: "Tester")
        XCTAssertEqual(atomic.revision, 5, "One batch is one home revision and one Undo action")
        XCTAssertThrowsError(try LotMenuSelection.applying(ops + [LotOperation(kind: .setDone, rowID: UUID(), done: true)], to: doc, author: "Tester"))
        XCTAssertFalse(doc.rows[1].isDone, "A failed batch leaves the source intact")
    }
}


extension ConverseTests {
    func testMobileSidebarIconAppearance() async throws {
        for style: UIUserInterfaceStyle in [.light, .dark] {
            let host = UIHostingController(rootView: VStack(alignment: .leading, spacing: 12) {
                HStack { PadSessionName(title: "Parking Lot", isAgent: false, isParkingLot: true); Spacer(); PadProviderLogo(engine: "parking") }
                HStack { PadSessionName(title: "Converse Steward", isAgent: true); Spacer(); PadProviderLogo(engine: "muse") }
                HStack { Text("Claude"); Spacer(); PadProviderLogo(engine: "claude") }
                HStack { Text("Codex"); Spacer(); PadProviderLogo(engine: "codex") }
                HStack { Text("Choose a provider"); Spacer(); PadProviderLogo(engine: "unassigned") }
                HStack { Text("Imported conversation"); Spacer(); PadProviderLogo(engine: "imported") }
            }.font(.system(size: 13)).padding().frame(width: 360))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 360, height: 270)
            window.overrideUserInterfaceStyle = style; window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let image = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
            image.name = "Mac-matching mobile icons \(style == .dark ? "dark" : "light")"; image.lifetime = .keepAlways; add(image)
            window.isHidden = true
        }
    }
}


extension ConverseTests {
    func testMobileEntryCreationReturnAndOutdentBoundaries() throws {
        let heading = ParkingLotRow(heading: true, text: "Hook")
        let parent = ParkingLotRow(heading: false, text: "First 📽 item", notes: [ParkingLotNote(author: "Owner", text: "Keep")], parentID: heading.id, tag: .green)
        let child = ParkingLotRow(heading: false, text: "Nested", parentID: parent.id)
        let sibling = ParkingLotRow(heading: false, text: "Second", parentID: heading.id)
        let nextHeading = ParkingLotRow(heading: true, text: "Later")
        let rows = [heading, parent, child, sibling, nextHeading]
        XCTAssertNil(ParkingLotTree.changingIndent([parent.id], in: rows, deeper: false), "The Video lot's first item is already at the outermost item level")
        let outdented = try LotOperation(kind: .outdent, rowIDs: [child.id]).applying(to: ParkingLotDocument(rows: rows), author: "iPhone")
        XCTAssertEqual(outdented.rows[2].parentID, heading.id)
        XCTAssertEqual(outdented.rows.map(\.id), rows.map(\.id))
        let newItem = try LotEntryEditing.inserting(in: rows, heading: false, after: parent.id)
        XCTAssertEqual(newItem.rows.map(\.id), [heading.id, parent.id, child.id, newItem.focus, sibling.id, nextHeading.id])
        XCTAssertEqual(newItem.rows[3].parentID, heading.id)
        let newHeading = try LotEntryEditing.inserting(in: rows, heading: true, after: child.id)
        XCTAssertEqual(newHeading.rows.map(\.id), [heading.id, parent.id, child.id, sibling.id, newHeading.focus, nextHeading.id])
        XCTAssertTrue(newHeading.rows[4].heading)
        let sectionItem = try LotEntryEditing.inserting(in: rows, heading: false, after: nil, section: heading.id)
        XCTAssertEqual(sectionItem.rows[4].id, sectionItem.focus)
        XCTAssertEqual(sectionItem.rows[4].parentID, heading.id)
        let enter = try LotEntryEditing.splitting(parent.id, at: NSRange(location: (parent.text as NSString).length, length: 0), in: rows)
        XCTAssertEqual(enter.rows.map(\.id), [heading.id, parent.id, child.id, enter.focus, sibling.id, nextHeading.id])
        XCTAssertEqual(enter.rows[1], parent); XCTAssertEqual(enter.rows[2], child)
        XCTAssertEqual(enter.rows[3].text, "")
        let headerReturn = try LotEntryEditing.splitting(heading.id, at: NSRange(location: 4, length: 0), in: rows)
        XCTAssertEqual(headerReturn.rows[1].id, headerReturn.focus)
        XCTAssertEqual(headerReturn.rows[1].parentID, heading.id)
        let middle = try LotEntryEditing.splitting(parent.id, at: NSRange(location: 5, length: 0), in: rows)
        XCTAssertEqual(middle.rows[1].text, "First")
        XCTAssertEqual(middle.rows[3].text, " 📽 item")
        XCTAssertEqual(middle.rows[1].notes, parent.notes); XCTAssertEqual(middle.rows[1].tag, parent.tag)
        let beginning = try LotEntryEditing.splitting(parent.id, at: NSRange(location: 0, length: 0), in: rows)
        XCTAssertEqual(beginning.rows[2], parent); XCTAssertEqual(beginning.rows[3], child)
        XCTAssertEqual(beginning.focus, parent.id)
        for edit in [newItem, newHeading, sectionItem, enter, headerReturn, middle, beginning] {
            let saved = try edit.operation.applying(to: ParkingLotDocument(rows: rows), author: "iPhone")
            func withoutEditor(_ rows: [ParkingLotRow]) -> [ParkingLotRow] {
                rows.map { row in var row = row; row.editedBy = nil; return row }
            }
            XCTAssertEqual(withoutEditor(saved.rows), withoutEditor(edit.rows), "The operation sent home must create exactly the previewed outline, including split placement and metadata")
        }
        XCTAssertThrowsError(try LotEntryEditing.splitting(parent.id, at: NSRange(location: 100, length: 0), in: rows))
    }
    func testNativeMobileEntryReturnAndSoftLineBreak() throws {
        var returned: NSRange?, typed: String?, deletedEmpty = false
        let entry = LotEntryText(text: "First", font: .systemFont(ofSize: 17), color: .label, done: false,
            editable: true, focused: false, caret: nil, identifier: "entry-test", changed: { typed = $0 },
            focusChanged: { _ in }, returned: { returned = $0 }, emptyBackspace: { deletedEmpty = true })
        let coordinator = entry.makeCoordinator(), view = LotEntryTextView()
        view.text = entry.text; view.delegate = coordinator
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 5, length: 0), replacementText: "\n"))
        XCTAssertEqual(returned, NSRange(location: 5, length: 0)); XCTAssertNil(typed)
        view.softReturn = true; returned = nil
        XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 5, length: 0), replacementText: "\n"))
        XCTAssertNil(returned, "Command-Return stays inside the item")
        view.softReturn = false
        XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 5, length: 0), replacementText: "pasted\ntext"), "Pasting multiline text is not interpreted as pressing Return")
        view.onEmptyBackspace = entry.emptyBackspace; view.text = ""; view.deleteBackward()
        XCTAssertTrue(deletedEmpty)
    }
}

private final class LotTestPointerTouch: UITouch {
    var point = CGPoint.zero
    var inputType: UITouch.TouchType = .indirectPointer
    override var type: UITouch.TouchType { inputType }
    override func location(in view: UIView?) -> CGPoint { point }
}
private final class LotTestPointerEvent: UIEvent {
    override var buttonMask: UIEvent.ButtonMask { .primary }
}
extension ConverseTests {
    func testTrackpadDragCrossesRowsWithoutTakingWithinItemTextSelection() {
        let ids = [UUID(), UUID(), UUID()]
        let gesture = LotPointerRangeGesture()
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 500)); host.addGestureRecognizer(gesture)
        gesture.visible = ids
        gesture.frames = [ids[0]: CGRect(x: 20, y: 20, width: 360, height: 80), ids[1]: CGRect(x: 20, y: 110, width: 360, height: 80), ids[2]: CGRect(x: 20, y: 200, width: 360, height: 80)]
        gesture.viewport = { host.bounds }
        var selected: Set<UUID> = []
        gesture.select = { selected = $0 }
        let touch = LotTestPointerTouch(), event = LotTestPointerEvent()
        touch.point = CGPoint(x: 80, y: 40)
        XCTAssertTrue(gesture.gestureRecognizer(gesture, shouldReceive: touch))
        gesture.touchesBegan([touch], with: event)
        touch.point.y = 70; gesture.touchesMoved([touch], with: event)
        XCTAssertTrue(selected.isEmpty, "A pointer drag within one entry belongs to native text selection")
        touch.point.y = 220; gesture.touchesMoved([touch], with: event)
        XCTAssertEqual(selected, Set(ids), "Crossing entries selects every row between the pointer-down row and current row")
        touch.point.y = 150; gesture.touchesMoved([touch], with: event)
        XCTAssertEqual(selected, Set(ids.prefix(2)), "Reversing the same drag shrinks the range")
        gesture.touchesEnded([touch], with: event)
        touch.inputType = .direct
        XCTAssertFalse(gesture.gestureRecognizer(gesture, shouldReceive: touch), "An ordinary finger drag remains scrolling or text selection")
        touch.inputType = .indirectPointer; touch.point.x = 450
        XCTAssertFalse(gesture.gestureRecognizer(gesture, shouldReceive: touch), "A pointer in a neighboring pane cannot start this lot's selection")
    }
}

extension ConverseTests {
    func testLargeLotPhoneResponsiveness() async throws {
        try await exerciseLargeLotPhone(streaming: false)
    }
    func testLargeLotPhoneWhileConversationStreams() async throws {
        try await exerciseLargeLotPhone(streaming: true)
    }
    private func exerciseLargeLotPhone(streaming: Bool) async throws {
        XCTAssertEqual(EditableLotPane.links(in: "https://example.com https://example.com file:///Users/someone/private.txt me@example.org").map(\.scheme), ["https", "mailto"], "Only explicit web and email links open on the viewing device; home file paths stay text")
        let service = try service(); service.editableLotsEnabled = true
        let model = PadModel(service: service)
        service.deviceNameOverride = "iPhone"
        let home = String(repeating: "e", count: 64), lot = UUID(), id = DeviceGlobalID(home: String(repeating: "e", count: 64), session: lot).string
        let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Home")
        peer.hello = DeviceHello(deviceID: home, deviceName: "Home", converseVersion: "test"); peer.hello!.capabilities.append(LotEditing.capability); peer.trustedReady = true
        service.adoptPeerForTesting(peer)
        let sidebar = DeviceSidebarRow(globalID: id, sessionID: lot, title: "Mobile Roadmap", assistant: "Parking Lot", engine: "parking", model: "", effort: "", access: "edit", status: "Parking Lot", busy: false, queued: 0, queuePaused: false)
        service.handleEnvelope(peer, DeviceEnvelope(kind: "sidebar.snapshot", homeSeq: 1, payload: try JSONEncoder().encode(DeviceSidebarPayload(homeDeviceID: home, homeDeviceName: "Home", homeSeq: 1, rows: [sidebar]))))
        model.assign(id, pane: 0)
        service.handleEnvelope(peer, DeviceEnvelope(kind: "lease.granted", boot: 9, sessionID: id, epoch: 4))
        let heading = ParkingLotRow(heading: true, text: "Things to build")
        let item = ParkingLotRow(heading: false, text: "Edit this item on your phone", notes: [ParkingLotNote(author: "Richard", text: "Keep my note")], parentID: heading.id, tag: .green)
        let child = ParkingLotRow(heading: false, text: "Keep nested items with their parent", done: true, parentID: item.id)
        let snapshot = try LotSnapshot(globalID: id, homeBoot: 9, leaseEpoch: 4, name: "Mobile Roadmap", document: ParkingLotDocument(revision: 12, rows: [heading, item, child] + (0..<120).map { index in ParkingLotRow(heading: false, text: "Entry \(index): " + String(repeating: "Long wrapped video notes with links https://example.com/video and multiple sentences. ", count: 8), parentID: heading.id) }))
        service.handleEnvelope(peer, try snapshot.envelope())
        let conversation = DeviceGlobalID(home: home, session: UUID()).string
        if streaming {
            model.state.placements[1] = conversation
            service.remoteLeases[conversation] = 5
            let messages = (0..<100).map { index in DeviceWireMessage(id: UUID(), role: index.isMultiple(of: 2) ? "user" : "assistant", text: "Message \(index)\n" + String(repeating: "Long conversation text with **formatting** and [links](https://example.com).\n", count: 10)) }
            service.remoteTranscripts[conversation] = DeviceTranscriptPayload(globalID: conversation, homeSeq: 1, epoch: 5, messages: messages, draft: "Preserve this draft", draftVersion: 1, busy: true, status: "Working", title: "Streaming conversation", engine: "codex")
        }
        let host = UIHostingController(rootView: PadRoot(model: model))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; service.suspendViewer() }
        host.view.frame = window.bounds
        let start = Date()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        print("LARGE_LOT initial layout seconds", Date().timeIntervalSince(start))
        let text = try XCTUnwrap(Self.views(host.view).compactMap { $0 as? LotEntryTextView }.first { $0.text == item.text })
        XCTAssertTrue(text.becomeFirstResponder())
        try await Task.sleep(for: .seconds(2)) // Separate cold keyboard startup from steady editing.
        for index in 0..<60 {
            service.handleEnvelope(peer, DeviceEnvelope(kind: "lot.lease.renewed", boot: 9, sessionID: id, epoch: 4))
            XCTAssertTrue(service.lotCanEdit(id), service.lotEditors[id]?.frozenReason ?? "Editor unavailable")
            let began = Date()
            if streaming { service.remoteTranscripts[conversation]?.messages[99].text += " Streamed token \(index)." }
            text.insertText("x")
            let queue = try XCTUnwrap(service.lotEditors[id])
            let flight = try XCTUnwrap(queue.inFlight)
            let savedDocument = try flight.operation.applying(to: queue.saved.document, author: queue.author)
            let saved = try LotSnapshot(globalID: id, homeBoot: 9, leaseEpoch: 4, name: snapshot.name, document: savedDocument)
            let ack = LotEditAck(mutationID: flight.mutationID, sequence: flight.sequence, snapshot: saved)
            service.handleEnvelope(peer, DeviceEnvelope(kind: "lot.edit.ack", boot: 9, sessionID: id, epoch: 4, payload: try LotEditing.encoded(ack)))
            try await Task.sleep(for: .milliseconds(50))
            host.view.layoutIfNeeded()
            XCTAssertEqual(service.lotEditors[id]?.unconfirmedCount, 0)
            print("LARGE_LOT edit", index, "seconds", Date().timeIntervalSince(began))
            XCTAssertLessThan(Date().timeIntervalSince(began), 2, "Main-thread editing must remain responsive with a long outline")
        }
        text.resignFirstResponder()
        let scroll = try XCTUnwrap(Self.views(host.view).compactMap { $0 as? UIScrollView }.first { !($0 is UITextView) })
        for page in 1...5 {
            scroll.setContentOffset(CGPoint(x: 0, y: page * 550), animated: false)
            try await Task.sleep(for: .milliseconds(100)); host.view.layoutIfNeeded()
        }
        XCTAssertEqual(service.lotEditors[id]?.projected.rows.first { $0.id == item.id }?.text.filter { $0 == "x" }.count, 60)
    }
}

extension ConverseTests {
    func testQueueRemoveNeedsHomeCapabilityAndSendsExactID() throws {
        let service = try service()
        let home = String(repeating: "c", count: 64)
        let sid = UUID(), id = DeviceGlobalID(home: home, session: sid).string
        let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Home")
        peer.hello = DeviceHello(deviceID: home, deviceName: "Home", converseVersion: "test"); peer.trustedReady = true
        service.adoptPeerForTesting(peer)
        service.homes[home] = RemoteHomeState(deviceID: home, deviceName: "Home", online: true, rows: [
            DeviceSidebarRow(globalID: id, sessionID: sid, title: "Queued", assistant: "Muse", engine: "muse", model: "m", effort: "", access: "", status: "Working", busy: true, queued: 3, queuePaused: false)
        ], lastSeen: Date())
        service.remoteLeases[id] = 3
        XCTAssertNotNil(service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "rename", text: "Reachable")), "The fixture home is reachable for ordinary commands")
        let items = ["first", "second", "third"].map { DevicePendingDTO(id: UUID(), text: $0) }
        var sent: [DeviceCommandPayload] = []
        func queue() -> PadQueue { PadQueue(pending: items, paused: false, canRemove: service.canRemoveQueuedRemote(id)) { sent.append($0); service.sendRemoteCommand(globalID: id, command: $0) } }
        let older = queue()
        XCTAssertEqual(older.bulkActions.map(\.label), ["Pause", "Inject all", PadQueue.clearAll])
        XCTAssertEqual(PadQueue.clearAll, "Clear all")
        XCTAssertEqual(older.itemActions(items[1]).map(\.label), ["Inject now"], "An older home keeps only Clear all")
        XCTAssertNil(service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "removeQueued", pendingID: items[1].id)), "An older home is never sent a single removal")
        XCTAssertFalse(service.outbox.contains { $0.payload.action == "removeQueued" })
        peer.hello!.capabilities.append(DeviceSyncService.queueRemoveCapability)
        let current = queue()
        XCTAssertEqual(current.itemActions(items[1]).map(\.label), ["Inject now", "Remove"])
        let remove = try XCTUnwrap(current.itemActions(items[1]).first { $0.label == "Remove" })
        current.send(remove.command)
        XCTAssertEqual(sent, [DeviceCommandPayload(action: "removeQueued", pendingID: items[1].id)])
        let record = try XCTUnwrap(service.outbox.first { $0.payload.action == "removeQueued" })
        XCTAssertEqual(record.payload.pendingID, items[1].id, "Remove names the exact queued message")
        XCTAssertEqual(record.epoch, 3, "Remove travels with the display lease through the durable outbox")
        current.send(remove.command)
        XCTAssertEqual(service.outbox.filter { $0.payload.action == "removeQueued" }.map(\.commandID), [record.commandID], "A second tap reuses the outstanding command ID")
    }
}

extension ConverseTests {
    func testLotBacklogCountsUnacknowledgedCharacters() {
        let row = ParkingLotRow(heading: false, text: "prefix suffix")
        var edited = row
        edited.text = "prefix 12345678901suffix"
        XCTAssertEqual(LotTextBacklog.count(saved: [row], projected: [edited]), 11)
        XCTAssertEqual(LotTextBacklog.count(saved: [edited], projected: [edited]), 0, "Acknowledgement drains the text backlog")
        XCTAssertEqual(LotTextBacklog.difference("12345678901", ""), 11, "Deletions also await acknowledgement")
        XCTAssertEqual(LotTextBacklog.difference("abc", "xyz"), 3, "Equal-length replacements must not disappear")
        XCTAssertEqual(LotTextBacklog.difference("a👨‍👩‍👧‍👦b", "ab"), 1, "Count graphemes, not UTF-16 units")
        XCTAssertEqual(LotTextBacklog.count(saved: [], projected: [row]), row.text.count)
        XCTAssertEqual(LotTextBacklog.count(saved: [row], projected: []), row.text.count)
    }
    func testLotSaveGaugeWaitsForPauseAndDoesNotMoveLayout() async throws {
        let row = ParkingLotRow(heading: false, text: "")
        var edited = row; edited.text = "12345678901"
        let host = UIHostingController(rootView: LotSaveGauge(saved: [row], projected: [edited], activity: 0, pending: true))
        // This fixture renders only the six-point rail, not a whole screen.
        // An iPhone's status/home safe areas can consume its 50-point window.
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 200, height: 50)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func pixels() -> Data? {
            host.view.layoutIfNeeded()
            return UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }.pngData()
        }
        try await Task.sleep(for: .milliseconds(100))
        let hidden = pixels(), size = host.view.intrinsicContentSize
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNotEqual(pixels(), hidden, "Eleven unacknowledged characters appear after the pause")
        host.rootView = LotSaveGauge(saved: [row], projected: [edited], activity: 1, pending: true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(pixels(), hidden, "Resuming input immediately hides the gauge")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNotEqual(pixels(), hidden)
        host.rootView = LotSaveGauge(saved: [edited], projected: [edited], activity: 1, pending: false)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(pixels(), hidden, "An acknowledgement hides it without any Saved text")
        edited.text = "1234567890"
        host.rootView = LotSaveGauge(saved: [row], projected: [edited], activity: 2, pending: true)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(pixels(), hidden, "Ten characters never show a gauge")
        XCTAssertEqual(host.view.intrinsicContentSize, size, "The status rail never changes layout size")
    }
    func testLotReturnFocusAndCaretLayout() async throws {
        let service = try service(); service.editableLotsEnabled = true
        let model = PadModel(service: service)
        let home = String(repeating: "e", count: 64), lot = UUID()
        let id = DeviceGlobalID(home: home, session: lot).string
        let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Home")
        peer.hello = DeviceHello(deviceID: home, deviceName: "Home", converseVersion: "test")
        peer.hello!.capabilities.append(LotEditing.capability); peer.trustedReady = true
        service.adoptPeerForTesting(peer)
        let sidebar = DeviceSidebarRow(globalID: id, sessionID: lot, title: "Return check", assistant: "Parking Lot", engine: "parking", model: "", effort: "", access: "edit", status: "Parking Lot", busy: false, queued: 0, queuePaused: false)
        service.handleEnvelope(peer, DeviceEnvelope(kind: "sidebar.snapshot", homeSeq: 1, payload: try JSONEncoder().encode(DeviceSidebarPayload(homeDeviceID: home, homeDeviceName: "Home", homeSeq: 1, rows: [sidebar]))))
        model.assign(id, pane: 0)
        service.handleEnvelope(peer, DeviceEnvelope(kind: "lease.granted", boot: 9, sessionID: id, epoch: 4))
        let heading = ParkingLotRow(heading: true, text: "Return and save feedback")
        let item = ParkingLotRow(heading: false, text: "Press Return here", parentID: heading.id)
        let snapshot = try LotSnapshot(globalID: id, homeBoot: 9, leaseEpoch: 4, name: "Return check", document: ParkingLotDocument(revision: 1, rows: [heading, item]))
        service.handleEnvelope(peer, try snapshot.envelope())
        let host = UIHostingController(rootView: EditableLotPane(id: id, pane: 0, model: model))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 600, height: 700)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; service.suspendViewer() }
        try await Task.sleep(for: .milliseconds(250)); host.view.layoutIfNeeded()
        let entry = try XCTUnwrap(Self.views(host.view).compactMap { $0 as? LotEntryTextView }.first { $0.text == item.text })
        XCTAssertTrue(entry.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(150))
        entry.selectedRange = NSRange(location: (entry.text as NSString).length, length: 0)
        // Programmatic insertText bypasses shouldChangeTextIn. Deliver the
        // keyboard delegate callback, which rejects the newline and splits.
        XCTAssertEqual(entry.delegate?.textView?(entry, shouldChangeTextIn: entry.selectedRange, replacementText: "\n"), false)
        try await Task.sleep(for: .milliseconds(500)); host.view.layoutIfNeeded()
        let preAttachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        preAttachment.name = "Return layout before assertions"; preAttachment.lifetime = .keepAlways; add(preAttachment)
        let blank = try XCTUnwrap(Self.views(host.view).compactMap { $0 as? LotEntryTextView }.first { $0.text.isEmpty && $0.isFirstResponder })
        XCTAssertEqual(blank.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(service.lotEditors[id]?.projected.rows.count, 3)
        let caret = blank.caretRect(for: blank.beginningOfDocument)
        XCTAssertLessThan(caret.minY, blank.font!.lineHeight / 2, "Caret belongs to the first line of the empty editor")
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) })
        attachment.name = "Return creates an aligned empty item"; attachment.lifetime = .keepAlways; add(attachment)
        blank.insertText("Next item")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(service.lotEditors[id]?.projected.rows.last?.text, "Next item")
        XCTAssertTrue(blank.isFirstResponder)
    }
}

extension ConverseTests {
    // Exact command bytes: an iPad send is stored, survives relaunch and is
    // resent byte-for-byte; an earlier version's record asks home instead.
    func testOutboxResendsExactCommandBytesAfterRelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("converse-ipad-command-bytes-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let service = DeviceSyncService(); try service.configureForTesting(folder: folder)
        let homeStatic = Curve25519.KeyAgreement.PrivateKey()
        let home = DeviceBlob.sha256Hex(homeStatic.publicKey.rawRepresentation), id = DeviceGlobalID(home: home, session: UUID()).string
        var viewerHandshake = DeviceHandshake(isInitiator: true, staticKey: Curve25519.KeyAgreement.PrivateKey(), ephemeralKey: Curve25519.KeyAgreement.PrivateKey())
        var homeHandshake = DeviceHandshake(isInitiator: false, staticKey: homeStatic, ephemeralKey: Curve25519.KeyAgreement.PrivateKey())
        _ = try homeHandshake.readMessage(try viewerHandshake.writeMessage(payload: Data("v".utf8)))
        _ = try viewerHandshake.readMessage(try homeHandshake.writeMessage(payload: Data("h".utf8)))
        _ = try homeHandshake.readMessage(try viewerHandshake.writeMessage(payload: Data("v".utf8)))
        var homeKeys = try homeHandshake.finish()
        let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Home")
        peer.hello = DeviceHello(deviceID: home, deviceName: "Home", converseVersion: "test"); peer.keys = try viewerHandshake.finish(); peer.trustedReady = true
        var wire: [Data] = []; peer.testSink = { wire.append($0) }
        service.adoptPeerForTesting(peer)
        service.homes[home] = RemoteHomeState(deviceID: home, deviceName: "Home", online: true, rows: [], lastSeen: Date())
        var decoder = DeviceFrameDecoder()
        func sent() throws -> [DeviceEnvelope] {
            var frames: [DeviceEnvelope] = []
            for frame in wire { frames += try decoder.append(homeKeys.receiver.decrypt(frame)) }
            wire = []; return frames
        }
        service.remoteLeases[id] = 3
        let command = try XCTUnwrap(service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "submit", text: "From iPad")))
        let first = try XCTUnwrap(try sent().first { $0.commandID == command && $0.kind == DeviceMessageKind.command.rawValue }?.payload)
        XCTAssertEqual(String(decoding: first, as: UTF8.self), #"{"action":"submit","blobHashes":[],"text":"From iPad"}"#, "iPad sends canonical command bytes")
        XCTAssertEqual(service.outbox.first { $0.commandID == command }?.payloadData, first, "The outbox stores the bytes it sent")
        try service.configureForTesting(folder: folder) // Relaunch: stores reload from disk.
        service.remoteLeases[id] = 3
        XCTAssertNotNil(service.homes[home], "The fixture home stays reachable across the simulated relaunch")
        let reloaded = try XCTUnwrap(service.outbox.first { $0.commandID == command })
        XCTAssertEqual(reloaded.payloadData, first)
        service.retryOutbox(reloaded)
        XCTAssertEqual(try sent().first { $0.commandID == command && $0.kind == DeviceMessageKind.command.rawValue }?.payload, first, "Resend same ID after relaunch is byte-identical")
        let legacyID = UUID()
        let legacy = #"[{"commandID":""# + legacyID.uuidString + #"","sessionID":""# + id + #"","payload":{"action":"submit","text":"Old","blobHashes":[]},"payloadHash":"h","epoch":3,"outcome":"pending"}]"#
        try Data(legacy.utf8).write(to: folder.appendingPathComponent("device-outbox.json"))
        try service.configureForTesting(folder: folder)
        service.remoteLeases[id] = 3
        var record = try XCTUnwrap(service.outbox.first { $0.commandID == legacyID })
        XCTAssertEqual(record.outcome, "uncertain", "An earlier version's pending send surfaces as Check home")
        XCTAssertEqual(record.detail, DeviceOutboxRecord.legacyDetail)
        record.outcome = "pending"; service.retryOutbox(record)
        let frames = try sent()
        XCTAssertTrue(frames.contains { $0.kind == DeviceMessageKind.commandQuery.rawValue && $0.commandID == legacyID }, "Resending a legacy record queries home under its original ID")
        XCTAssertFalse(frames.contains { $0.kind == DeviceMessageKind.command.rawValue }, "A legacy record is never re-encoded and resent")
    }
}
