import AppKit
import CryptoKit
import Network

func lotTransportSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lot-transport-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let home = DeviceSyncService(); try home.configureForTesting(folder: root.appendingPathComponent("home")); home.editableLotsEnabled = true
        let lot = try home.parkingLibrary.create(name: "Editing fixture")
        let heading = ParkingLotRow(heading: true, text: "Now")
        let row = ParkingLotRow(heading: false, text: "Original", parentID: heading.id, tag: .red)
        try lot.replaceUserRows([heading, row], revision: lot.document.revision)
        let id = DeviceGlobalID(home: home.identity!.deviceID, session: lot.id).string
        func peer(_ name: String, capable: Bool = true) throws -> (DevicePeer, () throws -> [DeviceEnvelope]) {
            let key = Curve25519.KeyAgreement.PrivateKey()
            var viewerHS = DeviceHandshake(isInitiator: true, staticKey: key)
            var homeHS = DeviceHandshake(isInitiator: false, staticKey: home.identity!.privateKey)
            _ = try homeHS.readMessage(viewerHS.writeMessage(payload: Data()))
            _ = try viewerHS.readMessage(homeHS.writeMessage(payload: Data()))
            _ = try homeHS.readMessage(viewerHS.writeMessage(payload: Data()))
            var viewerKeys = try viewerHS.finish()
            let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: false, displayName: name)
            peer.hello = DeviceHello(deviceID: DeviceBlob.sha256Hex(key.publicKey.rawRepresentation), deviceName: name, converseVersion: "test")
            if capable { peer.hello!.capabilities.append(LotEditing.capability) }
            peer.keys = try homeHS.finish(); peer.trustedReady = true
            var captured: [Data] = []
            peer.testSink = { captured.append($0) }; home.adoptPeerForTesting(peer)
            return (peer, {
                var decoder = DeviceFrameDecoder(); var result: [DeviceEnvelope] = []
                for data in captured { result.append(contentsOf: try decoder.append(viewerKeys.receiver.decrypt(data))) }
                captured = []; return result
            })
        }
        let (old, oldFrames) = try peer("Old viewer", capable: false)
        home.handleEnvelope(old, DeviceEnvelope(kind: "lease.acquire", sessionID: id))
        check(try oldFrames().contains { $0.kind == "lease.denied" } && !old.leasedSessions.contains(lot.id), "Activated lot editing refuses old epoch-zero subscribers")
        let (phone, frames) = try peer("iPhone")
        home.handleEnvelope(phone, DeviceEnvelope(kind: "lease.acquire", sessionID: id))
        let grantFrames = try frames()
        let snapshot = try JSONDecoder().decode(LotSnapshot.self, from: grantFrames.first { $0.kind == "lot.snapshot" }!.payload!)
        check(snapshot.leaseEpoch > 0 && phone.leasedSessions.contains(lot.id), "Mobile lot take grants a persisted nonzero epoch and structured document")
        let before = lot.document
        do { try lot.replaceUserRows([heading], revision: before.revision); check(false, "Home writes must wait for the holder") }
        catch { check(lot.document == before, "Home writes cannot bypass the remote holder") }
        let edit = try LotEdit(snapshot: snapshot, sequence: 1, operation: LotOperation(kind: .setText, rowID: row.id, text: "From phone"))
        let envelope = DeviceEnvelope(kind: "lot.edit", boot: snapshot.homeBoot, sessionID: id, epoch: snapshot.leaseEpoch, payload: try LotEditing.encoded(edit))
        home.handleEnvelope(phone, envelope)
        let saved = lot.document
        let ack = try JSONDecoder().decode(LotEditAck.self, from: frames().first { $0.kind == "lot.edit.ack" }!.payload!)
        check(saved.rows[1].text == "From phone" && saved.rows[1].tag == .red && ack.snapshot.document.revision == before.revision + 1, "Remote typing commits atomically on home before the save ack")
        home.handleEnvelope(phone, envelope)
        check(try frames().contains { $0.kind == "lot.edit.ack" } && lot.document == saved, "Lost-ack retry returns the original receipt without applying twice")
        var tampered = edit; tampered.operation.text = "Altered"; tampered.payloadHash = try LotEditing.digest(tampered.operation)
        var bad = envelope; bad.payload = try LotEditing.encoded(tampered)
        home.handleEnvelope(phone, bad)
        check(try frames().contains { $0.kind == "lot.rejected" } && lot.document == saved, "Same mutation ID with different bytes is rejected")
        var obsolete = try LotEdit(snapshot: ack.snapshot, sequence: 2, operation: LotOperation(kind: .setDone, rowID: row.id, done: true)); obsolete.homeBoot += 1
        bad.payload = try LotEditing.encoded(obsolete)
        home.handleEnvelope(phone, bad)
        check(try frames().contains { $0.kind == "lot.rejected" } && lot.document == saved, "Old-boot edit cannot mutate a currently held lot")
        let (tablet, tabletFrames) = try peer("iPad")
        home.handleEnvelope(tablet, DeviceEnvelope(kind: "lease.acquire", sessionID: id))
        check(try frames().contains { $0.kind == "lot.handoff.prepare" } && tabletFrames().isEmpty, "Second take waits for the first holder to drain and hide")
        let late = try LotEdit(snapshot: ack.snapshot, sequence: 2, operation: LotOperation(kind: .setText, rowID: row.id, text: "Last pending text"))
        home.handleEnvelope(phone, DeviceEnvelope(kind: "lot.edit", boot: snapshot.homeBoot, sessionID: id, epoch: snapshot.leaseEpoch, payload: try LotEditing.encoded(late)))
        let lateAck = try JSONDecoder().decode(LotEditAck.self, from: frames().first { $0.kind == "lot.edit.ack" }!.payload!)
        home.handleEnvelope(phone, DeviceEnvelope(kind: "lot.handoff.ready", boot: snapshot.homeBoot, sessionID: id, epoch: snapshot.leaseEpoch, payload: try LotEditing.encoded(lateAck.snapshot.digest)))
        let moved = try JSONDecoder().decode(LotSnapshot.self, from: tabletFrames().first { $0.kind == "lot.snapshot" }!.payload!)
        check(moved.leaseEpoch > snapshot.leaseEpoch && moved.document.rows[1].text == "Last pending text" && !phone.leasedSessions.contains(lot.id), "Handoff includes the old holder’s last acknowledged edit and fences its authority")
        home.handleEnvelope(phone, envelope)
        check(try frames().contains { $0.kind == "lot.rejected" } && lot.document.rows[1].text == "Last pending text", "Old holder cannot replay a cached edit after handoff")
        home.handleEnvelope(tablet, DeviceEnvelope(kind: "lease.heartbeat", sessionID: id, epoch: moved.leaseEpoch))
        check(try tabletFrames().contains { $0.kind == "lot.lease.renewed" && $0.epoch == moved.leaseEpoch }, "Lot heartbeat acknowledges the exact holder epoch")
        func pump(_ done: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            return done()
        }
        let proposed = ParkingLotEdits(revision: lot.document.revision, operations: [
            .init(action: "update", id: row.id, text: "Approved agent edit", heading: nil, before: nil),
            .init(action: "comment", id: row.id, text: "Agent comment"),
            .init(action: "add", text: "Agent addition", parentID: heading.id)
        ])
        var reviewResult: Result<String, Error>?
        let reviewTask = Task { @MainActor in
            do { reviewResult = .success(try await home.reviewOnLotHolder(proposed, lot: lot, author: "Fixture agent", allowed: { true })) }
            catch { reviewResult = .failure(error) }
        }
        var announcement: LotProposalPreview?
        _ = pump {
            for frame in (try? tabletFrames()) ?? [] where frame.kind == "lot.proposal" {
                announcement = frame.payload.flatMap { try? JSONDecoder().decode(LotProposalPreview.self, from: $0) }
            }
            return announcement != nil
        }
        guard let announcement else { reviewTask.cancel(); throw ParkingLotError.message("Holder did not receive review request.") }
        check(announcement.before == nil && reviewResult == nil, "Agent proposal waits for holder drain before preview or mutation")
        let human = try LotEdit(snapshot: moved, sequence: 1, operation: LotOperation(kind: .appendComment, rowID: row.id, text: "Last human comment", commentID: UUID()))
        home.handleEnvelope(tablet, DeviceEnvelope(kind: "lot.edit", boot: moved.homeBoot, sessionID: id, epoch: moved.leaseEpoch, payload: try LotEditing.encoded(human)))
        _ = try tabletFrames()
        home.handleEnvelope(tablet, DeviceEnvelope(kind: "lot.barrier", boot: moved.homeBoot, sessionID: id, commandID: announcement.id, epoch: moved.leaseEpoch))
        guard let previewData = try tabletFrames().first(where: { $0.kind == "lot.proposal" })?.payload else { throw ParkingLotError.message("Missing drained review preview.") }
        let preview = try JSONDecoder().decode(LotProposalPreview.self, from: previewData)
        check(preview.before?.document.rows[1].notes?.last?.text == "Last human comment" && preview.after?.rows[1].text == "Approved agent edit", "Exact review includes the last human edit and the proposed agent change")
        let decision = LotProposalDecision(id: preview.id, approved: true, previewDigest: preview.previewDigest)
        home.handleEnvelope(tablet, DeviceEnvelope(kind: "lot.proposal.resolve", boot: moved.homeBoot, sessionID: id, epoch: moved.leaseEpoch, payload: try LotEditing.encoded(decision)))
        _ = pump { reviewResult != nil }
        check(lot.document.rows[1].text == "Approved agent edit" && lot.document.rows[1].notes?.first?.text == "Last human comment", "Holder approval commits once and preserves drained human edits")
        check(lot.document == preview.after, "Approval persists exactly the reviewed row and comment IDs, without regenerating them")
        _ = try tabletFrames()
        let approved = lot.document
        home.handleEnvelope(tablet, DeviceEnvelope(kind: "lot.proposal.resolve", boot: moved.homeBoot, sessionID: id, epoch: moved.leaseEpoch, payload: try LotEditing.encoded(decision)))
        check(lot.document == approved, "Duplicate approval cannot apply a proposal twice")
        _ = try tabletFrames()
        reviewResult = nil
        let cancelled = Task { @MainActor in
            do { reviewResult = .success(try await home.reviewOnLotHolder(proposed, lot: lot, author: "Cancelled agent", allowed: { true })) }
            catch { reviewResult = .failure(error) }
        }
        var cancelID: UUID?
        _ = pump {
            for frame in (try? tabletFrames()) ?? [] where frame.kind == "lot.proposal" {
                cancelID = frame.payload.flatMap { try? JSONDecoder().decode(LotProposalPreview.self, from: $0).id }
            }
            return cancelID != nil
        }
        cancelled.cancel()
        let completed = pump { reviewResult != nil }
        let closed = try tabletFrames().contains { $0.kind == "lot.proposal.closed" }
        check(completed && closed && lot.document == approved, "Cancelling the requesting task closes holder review without applying changes")
    } catch { check(false, "Lot transport fixture: " + error.localizedDescription) }
}
