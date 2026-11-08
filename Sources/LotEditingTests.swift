import Foundation

/// Flexible nesting and outdent-to-heading, in the shared tree and wire model.
func lotFlexibleNestingSelfTests(_ check: (Bool, String) -> Void) {
    func depth(_ id: UUID, _ rows: [ParkingLotRow]) -> Int { ParkingLotTree.depth(of: id, in: rows) }
    do {
        let h = ParkingLotRow(heading: true, text: "Section"), first = ParkingLotRow(heading: false, text: "First", parentID: h.id)
        let second = ParkingLotRow(heading: false, text: "Second", parentID: h.id), child = ParkingLotRow(heading: false, text: "Child", parentID: second.id)
        let third = ParkingLotRow(heading: false, text: "Third", parentID: h.id), later = ParkingLotRow(heading: true, text: "Later")
        let rows = [h, first, second, child, third, later]
        // A first item can go deeper than its heading, one level per Tab.
        let once = ParkingLotTree.changingIndent(first.id, in: rows, deeper: true)!
        let twice = ParkingLotTree.changingIndent(first.id, in: once, deeper: true)!
        check(depth(first.id, once) == 2 && depth(first.id, twice) == 3 && once[1].parentID == h.id && once[1].indent == 1 && twice[1].indent == 2,
              "A first item can sit deeper than its heading, recording the gap above it")
        check(ParkingLotTree.canIndent(first.id, in: rows) && ParkingLotTree.canOutdent(first.id, in: once), "Indent and Outdent are offered for a first item")
        check(ParkingLotTree.changingIndent(first.id, in: twice, deeper: false) == once && ParkingLotTree.changingIndent(first.id, in: once, deeper: false) == rows,
              "Outdent removes the recorded gap one level at a time")
        // An item can go several levels deeper than the row before it.
        let nested = ParkingLotTree.changingIndent(second.id, in: rows, deeper: true)!
        let deeper = ParkingLotTree.changingIndent(second.id, in: nested, deeper: true)!
        check(nested[2].parentID == first.id && nested[2].indent == nil && deeper[2].parentID == first.id && deeper[2].indent == 1 && depth(second.id, deeper) == 3 && depth(child.id, deeper) == 4,
              "An item can nest more than one level deeper than the row before it, carrying its children")
        // A later row that is merely indented deeper is not swallowed as a descendant.
        var gapped = rows; gapped[2].indent = 2
        check(ParkingLotTree.range(first.id, in: gapped) == 1..<2 && ParkingLotTree.range(second.id, in: gapped) == 2..<4, "A row indented deeper than the one before it is not treated as its child")
        check((try? LotOperation(kind: .deleteSubtree, rowID: first.id).applying(to: ParkingLotDocument(revision: 1, rows: gapped), author: "iPhone"))?.rows.contains { $0.id == second.id } == true,
              "Deleting the row above keeps an unrelated, deeper row")
        // Numbering stays per level: a shallower sibling ends a deeper run.
        var mixed = rows; mixed[1].indent = 2
        let numbers = ParkingLotTree.numbers(mixed)
        check(numbers[first.id] == 1 && numbers[second.id] == 1 && numbers[third.id] == 2 && ParkingLotTree.label(numbers[first.id]!, depth: depth(first.id, mixed)) == "i",
              "A deeper first item numbers on its own level, and normal siblings keep their numbers")
        // The depth cap still holds.
        var chain = [h, first]
        for n in 2...ParkingLotTree.maximumDepth { chain.append(ParkingLotRow(heading: false, text: "d\(n)", parentID: chain.last!.id)) }
        check(ParkingLotTree.changingIndent(chain.last!.id, in: chain, deeper: true) == nil, "Tab at the depth cap is refused")
        var overDeep = rows; overDeep[1].indent = ParkingLotTree.maximumDepth
        check((try? ParkingLotTree.nodes(overDeep)) == nil, "An indent beyond the depth cap is rejected as an invalid document")
        var badIndent = rows; badIndent[0].indent = 1
        check((try? ParkingLotTree.nodes(badIndent)) == nil, "A heading can never carry an indent")
        // Outdent of a top-level item makes it a heading; siblings after it follow into its section.
        let converted = ParkingLotTree.changingIndent(second.id, in: rows, deeper: false)!
        let hierarchy = try ParkingLotTree.nodes(converted)
        check(converted.map(\.id) == rows.map(\.id) && converted[2].heading && converted[2].parentID == nil && hierarchy[child.id]?.parentID == second.id && hierarchy[child.id]?.depth == 1
              && hierarchy[third.id]?.parentID == second.id && hierarchy[first.id]?.parentID == h.id,
              "Outdenting a top-level item turns it into a heading, adopting later siblings and shifting its children")
        check(ParkingLotTree.changingIndent([first.id, second.id], in: rows, deeper: false)?.filter(\.heading).count == 4, "Outdenting several selected top-level items makes each a heading")
        let root = ParkingLotRow(heading: false, text: "Root"), rootTwo = ParkingLotRow(heading: false, text: "Next root")
        let rootConverted = ParkingLotTree.changingIndent(root.id, in: [root, rootTwo], deeper: false)!
        check(rootConverted[0].heading && rootConverted[1].parentID == root.id, "An item before any heading also outdents into a heading")
        check(ParkingLotTree.changingIndent(h.id, in: rows, deeper: false) == nil, "A heading itself cannot outdent")
        // Reordering works around recorded gaps.
        var spaced = rows; spaced[2].indent = 2
        let dropped = ParkingLotTree.moving(third.id, before: child.id, depth: 3, in: spaced)!
        check((try? ParkingLotTree.nodes(dropped)) != nil && dropped[3].id == third.id, "Dropping into a row that has an indent gap keeps a valid outline")
        // Normalized accepts the new shapes through every read path.
        let wire = ParkingLotDocument(revision: 4, rows: twice)
        let encoded = try LotEditing.encoded(wire)
        check(try JSONDecoder().decode(ParkingLotDocument.self, from: encoded).rows == twice && (try ParkingLotTree.normalized(twice)) == twice, "Flexible indents survive encoding and normalization")
        check((try ParkingLotTree.normalized(rows.map { var row = $0; row.indent = 0; return row })) == rows, "A stored zero indent normalizes away")
        var plainDoc = ParkingLotDocument(revision: 3, rows: rows); plainDoc.schemaVersion = 3
        let indentOp = try LotOperation(kind: .indent, rowID: first.id).applying(to: plainDoc, author: "iPad")
        check(indentOp.rows[1].indent == 1 && indentOp.schemaVersion == 4, "A device indent uses schema 4 only once a row needs it")
        let outdentOp = try LotOperation(kind: .outdent, rowID: second.id).applying(to: plainDoc, author: "iPad")
        check(outdentOp.rows[2].heading && outdentOp.schemaVersion == 3, "A device outdent to a heading stays compatible with schema 3")
        check(try LotOperation(kind: .move, rowID: first.id, parentID: h.id).applying(to: indentOp, author: "iPad").rows[1].indent == nil, "A move clears any recorded gap")
        let snapshot = try LotSnapshot(globalID: "home/" + UUID().uuidString.lowercased(), homeBoot: 1, leaseEpoch: 1, name: "L", document: indentOp)
        check(try JSONDecoder().decode(LotSnapshot.self, from: LotEditing.encoded(snapshot)) == snapshot, "A snapshot with flexible indents round-trips")
        // An older peer does not know `indent`. Dropping it on decode leaves the digest wrong, so it refuses the snapshot.
        var olderPeer = snapshot
        olderPeer.document.rows = olderPeer.document.rows.map { var row = $0; row.indent = nil; return row }
        do { try olderPeer.validate(); check(false, "An older peer that drops indent must fail the digest check") } catch { check(true, "An older peer that drops indent fails the digest check instead of keeping an altered lot") }
        var plainSnapshot = plainDoc
        plainSnapshot.rows = rows
        let plain = try LotSnapshot(globalID: "home/" + UUID().uuidString.lowercased(), homeBoot: 1, leaseEpoch: 1, name: "L", document: plainSnapshot)
        check(!String(decoding: try LotEditing.encoded(plain), as: UTF8.self).contains("indent") && plain.document.schemaVersion == 3,
              "Lots without flexible nesting have no new field and stay schema 3 for older peers")
        // A document saved by an older build keeps loading here.
        let oldJSON = #"{"schemaVersion":3,"revision":1,"rows":[{"id":"\#(h.id)","heading":true,"text":"Section"},{"id":"\#(first.id)","heading":false,"text":"First","parentID":"\#(h.id)"}]}"#
        check((try? JSONDecoder().decode(ParkingLotDocument.self, from: Data(oldJSON.utf8)))?.rows[1].indent == nil, "Older lot files decode with no indents")
        var futureDoc = ParkingLotDocument(revision: 1, rows: rows); futureDoc.schemaVersion = ParkingLotDocument.currentSchemaVersion + 1
        let futureJSON = String(decoding: try JSONEncoder().encode(futureDoc), as: UTF8.self)
        check((try? JSONDecoder().decode(ParkingLotDocument.self, from: Data(futureJSON.utf8))) == nil, "A lot from a future schema is still refused")
    } catch { check(false, "Flexible nesting model: " + error.localizedDescription) }
}

func lotEditingSelfTests(_ check: (Bool, String) -> Void) {
    lotFlexibleNestingSelfTests(check)
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
