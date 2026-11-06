import Foundation
import CryptoKit

/// Version covers every persisted row field, including tags and note/image metadata.
/// Unsupported versions are refused before a holder can rewrite a document.
enum LotEditing {
    static let capability = "lot-edit-v1"
    static let readOnlyCapability = "lot-read-v1"
    static let version = 1
    static let maximumPending = 100
    static let maximumFrameBytes = 4 * 1024 * 1024 - 1024
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try encoded(value)).map { String(format: "%02x", $0) }.joined()
    }
    static func hashIsValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validate(_ document: ParkingLotDocument, wireImages: Bool = true) throws {
        guard document.schemaVersion == ParkingLotDocument.currentSchemaVersion,
              document.revision >= 0, document.revision < Int.max,
              document.rows.count <= 500 else { throw ParkingLotError.message("Unsupported or oversized Parking Lot document.") }
        _ = try ParkingLotTree.nodes(document.rows)
        var characters = 0
        var noteIDs = Set<UUID>()
        for row in document.rows {
            guard row.text.count <= 20_000, (row.notes ?? []).count <= 500,
                  (row.images ?? []).count <= 500 else { throw ParkingLotError.message("Parking Lot entry exceeds its size limit.") }
            characters += row.text.count
            for note in row.notes ?? [] {
                guard note.text.count <= 20_000, note.author.count <= 1000, noteIDs.insert(note.id).inserted else {
                    throw ParkingLotError.message("Invalid Parking Lot comment.")
                }
                characters += note.text.count
            }
            if wireImages && !(row.images ?? []).allSatisfy(hashIsValid) { throw ParkingLotError.message("Invalid Parking Lot image reference.") }
        }
        guard characters <= 250_000 else { throw ParkingLotError.message("Parking Lot exceeds its text limit.") }
    }
}

struct LotSnapshot: Codable, Equatable {
    var globalID: String
    var homeBoot: UInt64
    var leaseEpoch: UInt64
    var editVersion = LotEditing.version
    var name: String
    var document: ParkingLotDocument
    var digest: String
    var readOnlyReason: String? = nil
    init(globalID: String, homeBoot: UInt64, leaseEpoch: UInt64, name: String, document: ParkingLotDocument) throws {
        self.globalID = globalID; self.homeBoot = homeBoot; self.leaseEpoch = leaseEpoch; self.name = name
        self.document = document; self.digest = try LotEditing.digest(document)
        try validate()
    }
    func validate() throws {
        guard editVersion == LotEditing.version, leaseEpoch > 0, homeBoot > 0,
              name.count <= 1000, digest == (try LotEditing.digest(document)) else {
            throw ParkingLotError.message("Parking Lot snapshot is incompatible or damaged. Take it again after updating Converse.")
        }
        try LotEditing.validate(document)
    }
    func envelope() throws -> DeviceEnvelope {
        let envelope = DeviceEnvelope(kind: "lot.snapshot", boot: homeBoot, sessionID: globalID, epoch: leaseEpoch, payload: try LotEditing.encoded(self))
        guard try LotEditing.encoded(envelope).count <= LotEditing.maximumFrameBytes else {
            throw ParkingLotError.message("This Parking Lot is too large to edit on another device. Open or export it on its home.")
        }
        return envelope
    }
}

struct LotOperation: Codable, Equatable {
    enum Kind: String, Codable { case setText, setDone, setTag, insert, insertSubtree, move, deleteSubtree, deleteSelection, indent, outdent, appendComment, removeComment, addImage, removeImage, replaceRows }
    var kind: Kind
    var rowID: UUID? = nil
    var text: String? = nil
    var done: Bool? = nil
    var tag: ParkingLotTag? = nil
    var row: ParkingLotRow? = nil
    var before: UUID? = nil
    var parentID: UUID? = nil
    var commentID: UUID? = nil
    var imageHash: String? = nil
    var rows: [ParkingLotRow]? = nil
    var rowIDs: [UUID]? = nil

    func applying(to document: ParkingLotDocument, author: String) throws -> ParkingLotDocument {
        var result = document
        var rows = try ParkingLotTree.normalized(document.rows)
        let index = rowID.flatMap { id in rows.firstIndex { $0.id == id } }
        func position(_ before: UUID?, parent: UUID?, heading: Bool, rows: [ParkingLotRow]) throws -> Int {
            if let before {
                guard let at = rows.firstIndex(where: { $0.id == before }),
                      heading ? rows[at].heading : (try ParkingLotTree.nodes(rows))[before]?.parentID == parent else {
                    throw ParkingLotError.message("The destination is no longer in the requested section.")
                }
                return at
            }
            if let parent {
                guard !heading, let range = ParkingLotTree.range(parent, in: rows) else { throw ParkingLotError.message("The parent no longer exists.") }
                return range.upperBound
            }
            return rows.count
        }
        switch kind {
        case .setText, .setDone, .setTag:
            guard let index else { throw ParkingLotError.message("That Parking Lot entry no longer exists.") }
            if kind == .setText { guard let text else { throw ParkingLotError.message("Missing text.") }; rows[index].text = text }
            if kind == .setDone { guard let done else { throw ParkingLotError.message("Missing Done state.") }; rows[index].done = done }
            if kind == .setTag { rows[index].tag = tag }
            rows[index].editedBy = author
        case .insert:
            guard var row, !rows.contains(where: { $0.id == row.id }), row.notes == nil, row.images == nil else { throw ParkingLotError.message("Invalid new Parking Lot entry.") }
            row.parentID = row.heading ? nil : parentID; row.editedBy = author
            rows.insert(row, at: try position(before, parent: row.parentID, heading: row.heading, rows: rows))
        case .insertSubtree:
            guard let incoming = self.rows, !incoming.isEmpty, incoming.allSatisfy({ entry in !rows.contains(where: { $0.id == entry.id }) }) else { throw ParkingLotError.message("Invalid pasted entries.") }
            let additions = incoming.map { entry -> ParkingLotRow in
                var entry = entry; entry.editedBy = author
                entry.notes = entry.notes?.map { ParkingLotNote(id: $0.id, author: author, text: $0.text) }
                return entry
            }
            rows.insert(contentsOf: additions, at: try position(before, parent: additions[0].heading ? nil : parentID, heading: additions[0].heading, rows: rows))
        case .move:
            guard let rowID, let range = ParkingLotTree.range(rowID, in: rows) else { throw ParkingLotError.message("The moved entry no longer exists.") }
            var moving = Array(rows[range]); rows.removeSubrange(range)
            moving[0].parentID = moving[0].heading ? nil : parentID
            rows.insert(contentsOf: moving, at: try position(before, parent: moving[0].parentID, heading: moving[0].heading, rows: rows))
        case .deleteSubtree:
            guard let rowID, let range = ParkingLotTree.range(rowID, in: rows) else { throw ParkingLotError.message("The deleted entry no longer exists.") }
            rows.removeSubrange(range)
        case .deleteSelection:
            guard let rowIDs, !rowIDs.isEmpty else { throw ParkingLotError.message("Choose entries to delete.") }
            var removed = Set<Int>()
            for id in rowIDs { guard let range = ParkingLotTree.range(id, in: rows) else { throw ParkingLotError.message("A selected entry no longer exists.") }; removed.formUnion(range) }
            rows = rows.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        case .indent, .outdent:
            let ids = Set(rowIDs ?? rowID.map { [$0] } ?? [])
            guard let next = ParkingLotTree.changingIndent(ids, in: rows, deeper: kind == .indent) else { throw ParkingLotError.message("This entry cannot move to that indentation level.") }
            rows = next
        case .appendComment:
            guard let index, let text, let commentID else { throw ParkingLotError.message("Invalid comment.") }
            rows[index].notes = (rows[index].notes ?? []) + [ParkingLotNote(id: commentID, author: author, text: text)]
        case .removeComment:
            guard let index, let commentID, rows[index].notes?.contains(where: { $0.id == commentID }) == true else { throw ParkingLotError.message("The comment no longer exists.") }
            rows[index].notes?.removeAll { $0.id == commentID }
        case .addImage, .removeImage:
            guard let index, let imageHash, LotEditing.hashIsValid(imageHash) else { throw ParkingLotError.message("Invalid image.") }
            if kind == .addImage {
                guard !(rows[index].images ?? []).contains(imageHash) else { throw ParkingLotError.message("Image already attached.") }
                rows[index].images = (rows[index].images ?? []) + [imageHash]
            } else {
                guard rows[index].images?.contains(imageHash) == true else { throw ParkingLotError.message("Image no longer attached.") }
                rows[index].images?.removeAll { $0 == imageHash }
            }
        case .replaceRows:
            guard let replacement = self.rows else { throw ParkingLotError.message("Missing replacement rows.") }
            rows = replacement
        }
        result.rows = try ParkingLotTree.normalized(rows)
        guard result.revision < Int.max - 1 else { throw ParkingLotError.message("Parking Lot revision exhausted.") }
        result.revision += 1
        try LotEditing.validate(result)
        return result
    }
}

struct LotEdit: Codable, Equatable {
    var mutationID = UUID()
    var globalID: String
    var homeBoot: UInt64
    var leaseEpoch: UInt64
    var editVersion = LotEditing.version
    var sequence: UInt64
    var baseRevision: Int
    var baseDigest: String
    var operation: LotOperation
    var payloadHash: String
    init(snapshot: LotSnapshot, sequence: UInt64, operation: LotOperation) throws {
        globalID = snapshot.globalID; homeBoot = snapshot.homeBoot; leaseEpoch = snapshot.leaseEpoch
        self.sequence = sequence; baseRevision = snapshot.document.revision; baseDigest = snapshot.digest
        self.operation = operation; payloadHash = try LotEditing.digest(operation)
    }
    func validate(against snapshot: LotSnapshot, sequence expected: UInt64) throws {
        guard editVersion == LotEditing.version, globalID == snapshot.globalID, homeBoot == snapshot.homeBoot,
              leaseEpoch == snapshot.leaseEpoch, sequence == expected,
              baseRevision == snapshot.document.revision, baseDigest == snapshot.digest,
              payloadHash == (try LotEditing.digest(operation)) else {
            throw ParkingLotError.message("Parking Lot authority or revision changed. No edits applied.")
        }
    }
}

struct LotEditAck: Codable, Equatable {
    var mutationID: UUID
    var sequence: UInt64
    var snapshot: LotSnapshot
}

struct LotProposalPreview: Codable, Equatable, Identifiable {
    var id: UUID
    var author: String
    var before: LotSnapshot?
    var after: ParkingLotDocument?
    var previewDigest: String?
}
struct LotProposalDecision: Codable {
    var id: UUID
    var approved: Bool
    var previewDigest: String?
}

/// A holder never persists or replays this queue across launches/epochs.
/// The transport sends only `inFlight`; unsent consecutive typing can coalesce.
struct LotEditQueue {
    private(set) var saved: LotSnapshot
    private(set) var projected: ParkingLotDocument
    private(set) var pending: [LotOperation] = []
    private(set) var inFlight: LotEdit?
    private(set) var nextSequence: UInt64 = 1
    var frozenReason: String?
    var draining = false
    var author: String
    var unconfirmedCount: Int { pending.count + (inFlight == nil ? 0 : 1) }
    init(snapshot: LotSnapshot, author: String) throws {
        try snapshot.validate(); saved = snapshot; projected = snapshot.document; self.author = author
    }
    mutating func enqueue(_ operation: LotOperation) throws {
        guard frozenReason == nil, !draining, unconfirmedCount < LotEditing.maximumPending else {
            throw ParkingLotError.message(frozenReason ?? "Waiting for this Parking Lot to finish saving.")
        }
        let result = try operation.applying(to: projected, author: author)
        // Preflight full envelope, including base64 overhead, before accepting input.
        _ = try LotSnapshot(globalID: saved.globalID, homeBoot: saved.homeBoot, leaseEpoch: saved.leaseEpoch, name: saved.name, document: result).envelope()
        if operation.kind == .setText, let previous = pending.last, previous.kind == .setText, previous.rowID == operation.rowID {
            pending[pending.count - 1] = operation
        } else { pending.append(operation) }
        try reproject()
    }
    mutating func beginNext() throws -> LotEdit? {
        guard frozenReason == nil, inFlight == nil, !pending.isEmpty else { return nil }
        let edit = try LotEdit(snapshot: saved, sequence: nextSequence, operation: pending.removeFirst())
        inFlight = edit
        return edit
    }
    mutating func acknowledge(_ ack: LotEditAck) throws {
        guard let sent = inFlight, ack.mutationID == sent.mutationID, ack.sequence == sent.sequence,
              ack.snapshot.globalID == saved.globalID, ack.snapshot.homeBoot == saved.homeBoot,
              ack.snapshot.leaseEpoch == saved.leaseEpoch, ack.snapshot.document.revision == saved.document.revision + 1 else {
            throw ParkingLotError.message("Unexpected Parking Lot save acknowledgement.")
        }
        try ack.snapshot.validate()
        let expected = try sent.operation.applying(to: saved.document, author: author)
        guard ack.snapshot.document == expected else { throw ParkingLotError.message("Home saved different Parking Lot content. Refresh is required.") }
        saved = ack.snapshot; inFlight = nil; nextSequence += 1
        try reproject()
    }
    mutating func installExternal(_ snapshot: LotSnapshot) throws {
        try snapshot.validate()
        guard unconfirmedCount == 0, snapshot.globalID == saved.globalID,
              snapshot.homeBoot == saved.homeBoot, snapshot.leaseEpoch == saved.leaseEpoch,
              snapshot.document.revision >= saved.document.revision else {
            throw ParkingLotError.message("Unsaved changes need reconciliation before refreshing this lot.")
        }
        saved = snapshot; projected = snapshot.document
    }
    private mutating func reproject() throws {
        var document = saved.document
        if let inFlight { document = try inFlight.operation.applying(to: document, author: author) }
        for operation in pending { document = try operation.applying(to: document, author: author) }
        projected = document
    }
}
