import Foundation
import Network

func converseGroupSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-groups-" + UUID().uuidString)
    var services: [DeviceSyncService] = []
    defer { services.forEach { $0.suspendViewer() }; try? FileManager.default.removeItem(at: root) }
    func pump(_ done: () -> Bool, seconds: Double = 6) {
        let until = Date().addingTimeInterval(seconds)
        while !done() && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    do {
        let persistence = root.appendingPathComponent("persistence")
        let store = try ConverseGroupStore(folder: persistence)
        let group = ConverseGroup(id: UUID().uuidString.lowercased(), name: "Workshop", creator: String(repeating: "a", count: 64))
        try store.adopt(group); try store.leave()
        check(store.current == nil && store.state.groups == [group], "Leaving preserves the group directory without keeping membership")
        try store.adopt(group); try store.dissolve(group)
        let reload = try ConverseGroupStore(folder: persistence)
        check(reload.current == nil && reload.state.groups.first?.dissolved == true, "Group dissolution persists a tombstone across restart")
        var resurrected = false
        do { try reload.adopt(group); resurrected = true } catch {}
        check(!resurrected, "A stale active descriptor cannot resurrect a dissolved group")
        var bad = group; bad.id = "not-an-id"
        check(!bad.valid, "Group identities are validated independently of display names")
        let keyA = Data(repeating: 1, count: 32), keyB = Data(repeating: 2, count: 32)
        let records = [TrustedDevice(deviceID: DeviceBlob.sha256Hex(keyA), name: "A", publicKey: keyA, pairedAt: Date()), TrustedDevice(deviceID: DeviceBlob.sha256Hex(keyB), name: "B", publicKey: keyB, pairedAt: Date())]
        check(ConverseGroupStore.migration(records) == ConverseGroupStore.migration(Array(records.reversed())), "Existing fabric migration assigns the same group irrespective of roster order")
        func make(_ name: String) throws -> DeviceSyncService {
            let service = DeviceSyncService(); service.deviceNameOverride = name
            try service.configureForTesting(folder: root.appendingPathComponent(name)); try service.enableGroupsForTesting()
            try service.startNetworkForTesting(); services.append(service); return service
        }
        let a = try make("Groups A"), b = try make("Groups B"), c = try make("Groups C"), d = try make("Groups D")
        check(a.currentGroup == nil && a.homes.isEmpty && a.trusted.isEmpty, "A device outside a group exposes no remote homes or sessions")
        a.createGroup(name: "Workshop")
        guard let groupA = a.currentGroup else { check(false, "Create group saves local membership"); return }
        a.createGroup(name: " workshop ")
        check(a.currentGroup == groupA && a.lastOutcome.contains("unique"), "Create Group refuses a conflicting name without leaving the current group")
        d.createGroup(name: "Other workshop")
        pump { a.testingPort != nil && d.testingPort != nil }
        guard let aPort = a.testingPort, let dPort = d.testingPort else { check(false, "Group listeners start on isolated ports"); return }
        d.connectManual(host: "127.0.0.1", port: Int(aPort))
        pump({ false }, seconds: 0.15)
        check(d.currentGroup?.name == "Other workshop" && a.pairingPrompt == nil && d.pairingPrompt == nil && a.groupRequests.isEmpty, "Ordinary connections across groups cannot bypass explicit Join and Review")
        b.joinGroupByAddress(host: "127.0.0.1", port: Int(aPort))
        pump { b.pairingPrompt != nil && a.groupRequests.count == 1 }
        guard let promptB = b.pairingPrompt, let requestB = a.groupRequests.first else { check(false, "Joiner gets immediate code and sponsor gets a pending request"); return }
        check(a.pairingPrompt == nil && a.groupReview == nil && b.currentGroup == nil, "Review hides the sponsor's security code and no membership is granted early")
        a.reviewGroupRequest(requestB)
        check(a.groupReview?.code == promptB.code, "Review reveals exactly the code already displayed to the joiner")
        a.approveGroupReview()
        pump({ b.currentGroup != nil }, seconds: 0.15)
        check(b.currentGroup == nil, "An existing member's Pair alone does not admit the joiner")
        b.confirmPairing()
        pump { b.currentGroup == groupA && a.trusted.count == 1 && b.trusted.count == 1 }
        check(b.currentGroup == groupA && a.trusted.count == 1 && b.trusted.count == 1, "Both Pair confirmations admit one device into the selected group")
        c.joinGroupByAddress(host: "127.0.0.1", port: Int(aPort))
        pump { c.pairingPrompt != nil && b.groupRequests.contains { $0.requesterName == "Groups C" } }
        guard let promptC = c.pairingPrompt, let requestC = b.groupRequests.first(where: { $0.requesterName == "Groups C" }) else { check(false, "Every existing member sees the new join request"); return }
        check(a.groupReview == nil && b.groupReview == nil, "Broadcast join requests carry no visible security number before Review")
        b.reviewGroupRequest(requestC)
        pump { b.groupReview != nil }
        guard let reviewC = b.groupReview else { check(false, "Another group member can review through the authenticated sponsor"); return }
        check(reviewC.code == promptC.code && c.pairingPrompt?.code == promptC.code, "A different member reviews without changing the joiner's connection-bound number")
        var wrong = reviewC; wrong.code = String(repeating: "0", count: 39)
        b.groupReview = wrong; b.approveGroupReview(); c.confirmPairing()
        pump({ a.groupRequests.first(where: { $0.id == requestC.id })?.approved == true }, seconds: 0.15)
        check(c.currentGroup == nil && a.groupRequests.first(where: { $0.id == requestC.id })?.approved == false, "Approval with a mismatched code cannot authorize the pending connection")
        b.groupReview = reviewC; b.approveGroupReview()
        pump { c.currentGroup == groupA && a.trusted.count == 2 && b.trusted.count == 2 && c.trusted.count == 2 }
        check(c.currentGroup == groupA && a.trusted.count == 2 && b.trusted.count == 2 && c.trusted.count == 2, "One reviewing member plus the joiner admits and connects the three-device group")
        let localSession = Store.shared.create(Entry(name: "Group fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "claude"))
        defer { Store.shared.deleteSession(localSession) }
        localSession.draft = "Unsent home draft"
        let globalID = DeviceGlobalID(home: a.identity!.deviceID, session: localSession.id).string
        c.isPlaced = { _ in true }
        c.acquireRemote(globalID: globalID)
        pump { c.remoteTranscripts[globalID]?.draft == "Unsent home draft" }
        check(c.remoteLeases[globalID] != nil && c.remoteTranscripts[globalID]?.draft == "Unsent home draft", "Admitted group members retain normal lease and transcript semantics")
        d.acquireRemote(globalID: globalID)
        check(d.remoteLeases[globalID] == nil && d.remoteTranscripts[globalID] == nil, "A device in another group cannot take or receive the session")
        // An unsuccessful switch keeps the old group and its trust separate.
        c.joinGroupByAddress(host: "127.0.0.1", port: Int(dPort))
        pump { c.pairingPrompt != nil && !d.groupRequests.isEmpty }
        check(c.currentGroup == groupA && d.trusted.isEmpty, "A pending join never merges groups or leaves the previous group")
        c.rejectPairing()
        pump { d.groupRequests.isEmpty }
        check(c.currentGroup == groupA && d.groupRequests.isEmpty, "Canceling a join withdraws the group-wide request and keeps current membership")
        // An offline member must learn the permanent tombstone on reconnect.
        let window = UUID(), missingPlacement = UUID(), remotePlacement = c.placementID(forGlobal: globalID)
        Workspace.shared.register(window, name: "Isolated group placement check")
        defer { Workspace.shared.close(window) }
        Workspace.shared.assign(localSession.id, to: window, pane: 1)
        Workspace.shared.assign(remotePlacement, to: window, pane: 2)
        Workspace.shared.assign(missingPlacement, to: window, pane: 3)
        c.suspendViewer()
        a.dissolveGroup()
        check(Workspace.shared.placements[remotePlacement] == nil && Workspace.shared.placements[missingPlacement] == nil && Workspace.shared.placements[localSession.id] != nil, "Group exit parks remote and unknown panes while preserving local session placement")
        pump { b.currentGroup == nil }
        check(a.currentGroup == nil && b.currentGroup == nil && a.homes.isEmpty && b.homes.isEmpty, "Any member can dissolve the group and remove remote sidebar data")
        c.connectManual(host: "127.0.0.1", port: Int(aPort))
        pump { c.currentGroup == nil }
        check(c.currentGroup == nil && c.knownGroups.contains(where: { $0.id == groupA.id && $0.dissolved }), "An offline member receives dissolution without granting session authority")
        a.createGroup(name: "Fresh group")
        check(a.currentGroup?.id != groupA.id && a.currentGroup?.name == "Fresh group", "Creating after dissolution uses a fresh group identity")
        a.leaveGroup()
        check(a.currentGroup == nil && a.homes.isEmpty && a.lastOutcome.isEmpty, "Leave parks remote views and returns the device to local-only mode")
    } catch { check(false, "Converse Groups tests: " + error.localizedDescription) }
}
