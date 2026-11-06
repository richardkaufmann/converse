import Foundation

func lotEditingSelfTests(_ check: (Bool, String) -> Void) {
    func refuses(_ label: String, _ body: () throws -> Void) {
        do { try body(); check(false, label) } catch { check(true, label) }
    }
    do {
        let heading = ParkingLotRow(heading: true, text: "Ideas")
        let first = ParkingLotRow(heading: false, text: "First", notes: [ParkingLotNote(author: "Owner", text: "Keep comment")], images: [String(repeating: "a", count: 64)], parentID: heading.id, tag: .purple)
        let second = ParkingLotRow(heading: false, text: "Second", parentID: heading.id)
        let document = ParkingLotDocument(revision: 7, rows: [heading, first, second])
        let id = "home/" + UUID().uuidString.lowercased()
        let snapshot = try LotSnapshot(globalID: id, homeBoot: 2, leaseEpoch: 3, name: "Ideas", document: document)
        let decoded = try JSONDecoder().decode(LotSnapshot.self, from: LotEditing.encoded(snapshot))
        check(decoded == snapshot && decoded.document.rows[1].tag == .purple, "Structured lot snapshots preserve hierarchy, tags, comment IDs and image order")
        var broken = snapshot; broken.document.rows[1].text = "changed"
        refuses("Lot snapshot digest detects changed content") { try broken.validate() }
        broken = snapshot; broken.editVersion += 1
        refuses("Unknown lot edit field versions are refused") { try broken.validate() }
        var badDocument = document; badDocument.rows[1].images = ["/private/home/file.png"]
        refuses("A lot wire document never accepts home file paths") { try LotEditing.validate(badDocument) }
        badDocument = document; badDocument.revision = Int.max
        refuses("Exhausted lot revision is refused without arithmetic overflow") { try LotEditing.validate(badDocument) }
        let edited = try LotOperation(kind: .setText, rowID: first.id, text: "Changed").applying(to: document, author: "iPhone")
        check(edited.rows[1].notes == first.notes && edited.rows[1].images == first.images && edited.rows[1].tag == .purple && edited.rows[1].editedBy == "iPhone", "Typing changes only text/provenance and preserves other row fields")
        let nested = try LotOperation(kind: .indent, rowID: second.id).applying(to: document, author: "iPhone")
        check(nested.rows[2].parentID == first.id, "Mobile indent nests under the preceding sibling")
        let removed = try LotOperation(kind: .deleteSubtree, rowID: first.id).applying(to: nested, author: "iPhone")
        check(removed.rows.map(\.id) == [heading.id], "Deleting a parent removes exactly its subtree")
        let outdented = try LotOperation(kind: .outdent, rowID: second.id).applying(to: nested, author: "iPhone")
        check(outdented.rows.map(\.id) == document.rows.map(\.id) && outdented.rows[2].parentID == heading.id, "Outdent preserves sibling order and stable row IDs")
        refuses("A nested move cannot move its parent into its child") { _ = try LotOperation(kind: .move, rowID: first.id, parentID: second.id).applying(to: nested, author: "iPhone") }
        let batch = LotOperation(kind: .batch, operations: [
            LotOperation(kind: .setDone, rowID: first.id, done: true),
            LotOperation(kind: .setTag, rowID: second.id, tag: .green),
            LotOperation(kind: .appendComment, rowID: second.id, text: "Batch note", commentID: UUID())
        ])
        let batched = try batch.applying(to: document, author: "iPhone")
        check(batched.revision == document.revision + 1 && batched.rows[1].isDone && batched.rows[2].tag == .green && batched.rows[2].notes?.last?.author == "iPhone", "Mobile batch validates each edit with home author and commits one revision")
        refuses("A batch cannot smuggle an unrestricted row replacement past Undo validation") {
            _ = try LotOperation(kind: .batch, operations: [LotOperation(kind: .replaceRows, rows: [])]).applying(to: document, author: "iPhone")
        }
        refuses("Nested batches are refused before recursive application") {
            _ = try LotOperation(kind: .batch, operations: [batch]).applying(to: document, author: "iPhone")
        }
        refuses("A failed final batch operation rejects the entire edit") {
            _ = try LotOperation(kind: .batch, operations: batch.operations! + [LotOperation(kind: .setDone, rowID: UUID(), done: true)]).applying(to: document, author: "iPhone")
        }
        check(!document.rows[1].isDone && document.revision == 7, "Failed batch leaves source rows and revision untouched")
        let comment = UUID()
        let commented = try LotOperation(kind: .appendComment, rowID: first.id, text: "New note", commentID: comment).applying(to: document, author: "iPad")
        check(commented.rows[1].notes?.last?.author == "iPad" && commented.rows[1].notes?.last?.id == comment, "New comments use home-selected author and supplied stable ID")
        refuses("Duplicate note IDs cannot enter the lot") { _ = try LotOperation(kind: .appendComment, rowID: second.id, text: "Dup", commentID: comment).applying(to: commented, author: "iPad") }
        var queue = try LotEditQueue(snapshot: snapshot, author: "iPhone")
        try queue.enqueue(LotOperation(kind: .setText, rowID: first.id, text: "A"))
        let flight = try queue.beginNext()!
        try queue.enqueue(LotOperation(kind: .setText, rowID: first.id, text: "AB"))
        try queue.enqueue(LotOperation(kind: .setText, rowID: first.id, text: "ABC"))
        check(queue.pending.count == 1 && queue.inFlight == flight && queue.saved == snapshot && queue.projected.rows[1].text == "ABC", "Unsent typing coalesces without changing the in-flight mutation or claiming saved state")
        let homeResult = try flight.operation.applying(to: document, author: "iPhone")
        let ackSnapshot = try LotSnapshot(globalID: id, homeBoot: 2, leaseEpoch: 3, name: "Ideas", document: homeResult)
        try queue.acknowledge(LotEditAck(mutationID: flight.mutationID, sequence: flight.sequence, snapshot: ackSnapshot))
        let next = try queue.beginNext()!
        check(next.baseRevision == 8 && next.baseDigest == ackSnapshot.digest && next.sequence == 2 && queue.projected.rows[1].text == "ABC", "The next lot edit derives its base only from the previous home acknowledgement")
        var badEdit = next; badEdit.homeBoot = 1
        refuses("Edits from a previous home boot cannot apply") { try badEdit.validate(against: ackSnapshot, sequence: 2) }
        badEdit = next; badEdit.leaseEpoch = 2
        refuses("Edits from a previous holder epoch cannot apply") { try badEdit.validate(against: ackSnapshot, sequence: 2) }
        badEdit = next; badEdit.sequence = 4
        refuses("Skipped holder sequence cannot apply") { try badEdit.validate(against: ackSnapshot, sequence: 2) }
        badEdit = next; badEdit.operation.text = "different bytes"
        refuses("Changed operation bytes fail the mutation hash") { try badEdit.validate(against: ackSnapshot, sequence: 2) }
        queue.frozenReason = "Disconnected"
        refuses("Disconnected holders cannot add offline edits") { try queue.enqueue(LotOperation(kind: .setText, rowID: first.id, text: "offline")) }
        check(queue.unconfirmedCount == 1 && queue.projected.rows[1].text == "ABC", "Freeze retains unconfirmed text for manual copy")
        refuses("External snapshot cannot silently discard pending holder edits") { try queue.installExternal(snapshot) }
        var huge = document; huge.rows = (0..<8).map { _ in
            ParkingLotRow(heading: true, text: "Metadata", notes: (0..<500).map { _ in ParkingLotNote(author: String(repeating: "x", count: 1000), text: "") })
        }
        let hugeSnapshot = try LotSnapshot(globalID: id, homeBoot: 2, leaseEpoch: 3, name: "Huge", document: huge)
        refuses("Encoded envelope limit includes note metadata and base64 overhead") { _ = try hugeSnapshot.envelope() }
        check(try LotEditing.encoded(snapshot.envelope()).count < LotEditing.maximumFrameBytes, "Ordinary complete lot envelopes fit the transport cap")
    } catch { check(false, "Lot editing fixture: " + error.localizedDescription) }
}
