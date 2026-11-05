import AppKit
import SwiftUI

struct ParkingLotNote: Codable, Equatable, Identifiable {
    var id = UUID()
    var author: String
    var text: String
}
struct ParkingLotRow: Codable, Equatable, Identifiable {
    var id = UUID()
    var heading: Bool
    var text: String
    var editedBy: String? = nil
    var notes: [ParkingLotNote]? = nil
    var images: [String]? = nil
    var done: Bool? = nil
    // Nil in an old document means the nearest preceding heading. Rows stay
    // in preorder; this ID gives nested items a stable parent across edits.
    var parentID: UUID? = nil
    var isDone: Bool { done == true }
}
struct ParkingLotDocument: Codable, Equatable {
    static let currentSchemaVersion = 2
    var schemaVersion: Int = currentSchemaVersion
    var revision: Int = 0
    var rows: [ParkingLotRow] = []
    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, rows }
    init(revision: Int = 0, rows: [ParkingLotRow] = []) {
        self.revision = revision; self.rows = rows
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                debugDescription: "This Parking Lot was saved by a newer version of Converse.")
        }
        revision = try container.decode(Int.self, forKey: .revision)
        rows = try container.decode([ParkingLotRow].self, forKey: .rows)
    }
}
// All rows remain one ordered array, so old lots and existing export packages
// can be read without a structural migration. Children follow their parent.
enum ParkingLotTree {
    struct Node { let parentID: UUID?; let depth: Int }
    static let maximumDepth = 8
    /// Outline labels by level: 1, 2, 3 → a, b, c → i, ii, iii, then repeat.
    static func label(_ number: Int, depth: Int) -> String {
        let n = max(1, number)
        switch (max(1, depth) - 1) % 3 {
        case 1: return letters(n)
        case 2: return roman(n)
        default: return String(n)
        }
    }
    /// a…z, then aa, ab… (like spreadsheet columns).
    static func letters(_ number: Int) -> String {
        var n = number, result = ""
        while n > 0 { n -= 1; result = String(UnicodeScalar(UInt8(97 + n % 26))) + result; n /= 26 }
        return result
    }
    static func roman(_ number: Int) -> String {
        guard number < 4000 else { return String(number) }
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var n = number, result = ""
        for (value, symbol) in table { while n >= value { result += symbol; n -= value } }
        return result
    }
    static func nodes(_ rows: [ParkingLotRow]) throws -> [UUID: Node] {
        var result: [UUID: Node] = [:]
        var path: [UUID] = []
        var section: UUID?
        for row in rows {
            guard result[row.id] == nil else { throw AgentFailure.message("Parking Lot has duplicate row IDs.") }
            if row.heading {
                guard row.parentID == nil else { throw AgentFailure.message("A Parking Lot heading must be at the top level.") }
                result[row.id] = Node(parentID: nil, depth: 0)
                path = [row.id]; section = row.id
                continue
            }
            let parentID = row.parentID ?? section
            if let parentID {
                guard let position = path.firstIndex(of: parentID) else {
                    throw AgentFailure.message("A Parking Lot item must follow its parent and stay inside its section.")
                }
                path = Array(path.prefix(position + 1))
                guard path.count <= maximumDepth else { throw AgentFailure.message("Parking Lot nesting is limited to eight levels.") }
                result[row.id] = Node(parentID: parentID, depth: path.count)
                path.append(row.id)
            } else {
                result[row.id] = Node(parentID: nil, depth: 0)
                path = [row.id]
            }
        }
        return result
    }
    static func normalized(_ rows: [ParkingLotRow]) throws -> [ParkingLotRow] {
        let hierarchy = try nodes(rows)
        return rows.map { row in
            var copy = row
            if !copy.heading { copy.parentID = hierarchy[row.id]?.parentID }
            return copy
        }
    }
    static func range(_ id: UUID, in rows: [ParkingLotRow]) -> Range<Int>? {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let hierarchy = try? nodes(rows), let depth = hierarchy[id]?.depth else { return nil }
        var end = index + 1
        while end < rows.count, (hierarchy[rows[end].id]?.depth ?? 0) > depth { end += 1 }
        return index..<end
    }
    static func parentForInsertion(at index: Int, in rows: [ParkingLotRow], heading: Bool) -> UUID? {
        guard !heading else { return nil }
        if index < rows.count, !rows[index].heading {
            return (try? nodes(rows))?[rows[index].id]?.parentID
        }
        return rows.prefix(index).last(where: \.heading)?.id
    }
    static func depth(of id: UUID, in rows: [ParkingLotRow]) -> Int {
        (try? nodes(rows))?[id]?.depth ?? 0
    }
    static func canIndent(_ id: UUID, in rows: [ParkingLotRow]) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }), !rows[index].heading,
              let hierarchy = try? nodes(rows), let node = hierarchy[id], node.depth < maximumDepth else { return false }
        return rows[..<index].last(where: { !$0.heading && hierarchy[$0.id]?.parentID == node.parentID }) != nil
    }
    static func canOutdent(_ id: UUID, in rows: [ParkingLotRow]) -> Bool {
        guard let hierarchy = try? nodes(rows), let parent = hierarchy[id]?.parentID,
              let row = rows.first(where: { $0.id == parent }) else { return false }
        return !row.heading
    }
    static func changingIndent(_ id: UUID, in rows: [ParkingLotRow], deeper: Bool) -> [ParkingLotRow]? {
        guard let index = rows.firstIndex(where: { $0.id == id }), !rows[index].heading,
              let hierarchy = try? nodes(rows), let node = hierarchy[id] else { return nil }
        var result = rows
        if deeper {
            guard canIndent(id, in: rows),
                  let previous = rows[..<index].last(where: { !$0.heading && hierarchy[$0.id]?.parentID == node.parentID }) else { return nil }
            result[index].parentID = previous.id
        } else {
            guard canOutdent(id, in: rows), let parent = node.parentID,
                  let range = range(id, in: rows) else { return nil }
            var moving = Array(result[range]); moving[0].parentID = hierarchy[parent]?.parentID
            result.removeSubrange(range)
            guard let parentRange = self.range(parent, in: result) else { return nil }
            result.insert(contentsOf: moving, at: parentRange.upperBound)
        }
        return (try? nodes(result)) == nil ? nil : result
    }
}
struct ParkingLotEdits: Decodable {
    struct Operation: Decodable {
        var action: String
        var id: UUID?
        var text: String?
        var heading: Bool?
        var before: UUID?
        var done: Bool? = nil
        var parentID: UUID? = nil
    }
    var revision: Int
    var operations: [Operation]
    var lotID: UUID? = nil
}
// Local notes, not a provider session. The stable ID uses the ordinary agent
// watched-session scope and workspace placement, without starting a CLI.
final class ParkingLotStore: ObservableObject, Identifiable {
    static let id = UUID(uuidString: "B4AA70E2-147E-40A1-9342-0751C0A40101")!
    static let placementGuidance = """
    Choose a section by meaning when adding an item, unless the human specified a destination. Read the existing headings and their items first; use the most relevant existing section without asking when the fit is clear. A report of broken behavior belongs under Bugs, praise under Compliments, and a deferred idea under Future work. Respect project boundaries and planning-only headings. Do not append to the last section just because it is convenient. Rows belong to the nearest preceding heading: to append inside a section, set before to the NEXT heading's UUID; omit before only if the chosen section is the last one. To place an item first in a section, use its first item's UUID (or the next heading for an empty section). If no section fits, propose a clearly named heading with the item; ask only when the intended classification is genuinely ambiguous. Preserve existing wording, IDs, comments, images and Done state when moving an item. Do not reorganize unrelated items. Briefly name the chosen section in your reply.
    For a nested item, set parentID to the item it belongs under and place it after that parent or its descendants. Rows are stored in preorder. A move or delete of a parent includes its descendants. Headings stay at the top level.
    """
    // Named lots are owned by ParkingLotLibrary; there is no second singleton copy.
    let id: UUID
    let substitutionFeedback = SubstitutionFeedback()
    let undoManager: UndoManager = { let manager = UndoManager(); manager.groupsByEvent = false; manager.levelsOfUndo = 100; return manager }()
    @Published var name: String
    @Published private(set) var document = ParkingLotDocument()
    @Published private(set) var active = false
    @Published var error = ""
    @Published private(set) var readOnlyReason: String?
    var isReadOnly: Bool { readOnlyReason != nil }
    private let file: URL
    let attachmentFolder: URL
    init(folder: URL, id: UUID = ParkingLotStore.id, name: String = "Parking Lot") {
        self.id = id; self.name = name
        attachmentFolder = folder.appendingPathComponent("Attachments/" + id.uuidString)
        file = id == Self.id ? folder.appendingPathComponent("parking-lot.json") : folder.appendingPathComponent("ParkingLots/" + id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let saved = try JSONDecoder().decode(ParkingLotDocument.self, from: Data(contentsOf: file))
                // Structural corruption must never be mistaken for a size limit.
                _ = try ParkingLotTree.nodes(saved.rows)
                document = saved; active = true
                do { try Self.validateSize(saved.rows) }
                catch { readOnlyReason = "This Parking Lot exceeds the editing size limits. It is open read-only. Export a recovery copy before reducing or splitting it; the saved file is unchanged." }
            }
            catch {
                self.error = "Could not read Parking Lot. The saved file has been left intact."
                readOnlyReason = self.error
            }
        }
    }
    private func requireWritable() throws {
        if let readOnlyReason { throw AgentFailure.message(readOnlyReason) }
    }
    /// Preserve the source bytes, including fields unknown to this build.
    /// Attachments remain in the original lot's attachment folder.
    func exportRecovery(to destination: URL) throws {
        guard destination.resolvingSymlinksInPath().standardizedFileURL != file.resolvingSymlinksInPath().standardizedFileURL else {
            throw AgentFailure.message("Choose a different file for the recovery copy.")
        }
        try Data(contentsOf: file).write(to: destination, options: .atomic)
    }
    func showSavedFile() { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    func saveImage(_ image: NSImage) throws -> String {
        try requireWritable()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]), png.count <= 25_000_000 else {
            throw AgentFailure.message("Choose an image smaller than 25 MB.")
        }
        try FileManager.default.createDirectory(at: attachmentFolder, withIntermediateDirectories: true)
        let url = attachmentFolder.appendingPathComponent(UUID().uuidString + ".png")
        try png.write(to: url, options: .atomic)
        return url.path
    }
    var exportMessages: [Message] {
        let hierarchy = (try? ParkingLotTree.nodes(document.rows)) ?? [:]
        var counts: [UUID?: Int] = [:]
        return document.rows.map { row in
            let parent = hierarchy[row.id]?.parentID
            if !row.heading { counts[parent, default: 0] += 1 }
            var copy = row
            // The ordinary Markdown helper numbers a standalone item as one.
            // Preserve the section's actual numbering in the exported message.
            copy.images = nil
            var text = Self.markdown([copy])
            if !row.heading {
                if text.hasPrefix("1. ") { text = ParkingLotTree.label(counts[parent] ?? 1, depth: hierarchy[row.id]?.depth ?? 1) + ". " + text.dropFirst(3) }
                let indent = String(repeating: "  ", count: max(0, (hierarchy[row.id]?.depth ?? 1) - 1))
                text = indent + text.replacingOccurrences(of: "\n   ", with: "\n" + indent + "   ")
            }
            return Message(id: row.id, role: "assistant", text: text, images: row.images ?? [], createdAt: nil)
        }
    }
    func open() {
        guard !active, error.isEmpty else { return }
        commit([ParkingLotRow(heading: true, text: "New features"), ParkingLotRow(heading: false, text: ""),
                ParkingLotRow(heading: true, text: "Bugs"), ParkingLotRow(heading: false, text: "")])
    }
    /// First-run starter content for a lot that has never been saved.
    func openStarter(_ rows: [ParkingLotRow]) {
        guard !active, error.isEmpty else { return }
        commit(rows)
    }
    private func persist(_ next: ParkingLotDocument) throws {
        try requireWritable()
        var next = next
        next.rows = try ParkingLotTree.normalized(next.rows)
        next.schemaVersion = ParkingLotDocument.currentSchemaVersion
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        let before = document.rows
        if active && before != next.rows {
            let group = !undoManager.isUndoing && !undoManager.isRedoing
            if group { undoManager.beginUndoGrouping() }
            undoManager.registerUndo(withTarget: self) { lot in lot.restoreUndo(before, replacing: next.rows) }
            if group { undoManager.setActionName("Edit Parking Lot"); undoManager.endUndoGrouping() }
        }
        document = next; active = true; error = ""
    }
    private func restoreUndo(_ rows: [ParkingLotRow], replacing expected: [ParkingLotRow]) {
        guard document.rows == expected else { error = "Parking Lot changed since that edit. Undo was skipped to preserve newer changes."; return }
        commit(rows)
    }
    private func commit(_ rows: [ParkingLotRow]) {
        do { try Self.validate(rows); try persist(ParkingLotDocument(revision: document.revision + 1, rows: rows)) }
        catch { self.error = "Parking Lot was not saved: " + error.localizedDescription }
    }
    static func validate(_ rows: [ParkingLotRow]) throws {
        _ = try ParkingLotTree.nodes(rows)
        try validateSize(rows)
    }
    private static func validateSize(_ rows: [ParkingLotRow]) throws {
        guard rows.count <= 500,
              rows.allSatisfy({ $0.text.count <= 20_000 && ($0.notes ?? []).allSatisfy { $0.text.count <= 20_000 } }), rows.reduce(0, { $0 + $1.text.count + ($1.notes ?? []).reduce(0) { $0 + $1.text.count } }) <= 250_000 else {
            throw AgentFailure.message("Parking Lot exceeds its size limit (500 entries, 20,000 characters per entry).")
        }
    }
    func replaceUserRows(_ rows: [ParkingLotRow], revision: Int) throws {
        try requireWritable()
        guard revision == document.revision else { throw AgentFailure.message("Parking Lot changed. Please try your edit again.") }
        try Self.validate(rows)
        if rows != document.rows { try persist(ParkingLotDocument(revision: revision + 1, rows: rows)) }
    }
    func setDone(_ id: UUID, _ done: Bool) {
        var rows = document.rows
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].isDone != done else { return }
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        rows[index].done = done; rows[index].editedBy = nil; commit(rows)
        let actionName: String = done ? "Mark Done" : "Mark Not Done"
        undoManager.setActionName(actionName)
    }
    @discardableResult func changeIndent(_ id: UUID, deeper: Bool) -> Bool {
        guard !isReadOnly, let rows = ParkingLotTree.changingIndent(id, in: document.rows, deeper: deeper) else { return false }
        commit(rows); return true
    }
    func update(_ id: UUID, text: String) {
        var rows = document.rows
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].text != text else { return }
        rows[index].text = text; rows[index].editedBy = nil; commit(rows)
    }
    @discardableResult func insert(heading: Bool = false, text: String = "", after id: UUID? = nil) -> UUID {
        var rows = document.rows
        let anchor = heading ? id.flatMap { id in
            rows.first(where: { $0.id == id })?.heading == true ? id : rows.prefix { $0.id != id }.last(where: \.heading)?.id
        } : id
        let index = anchor.flatMap { ParkingLotTree.range($0, in: rows).map(\.upperBound) } ?? rows.count
        let parent = heading ? nil : id.flatMap { id in rows.first(where: { $0.id == id }) }.flatMap { row in
            row.heading ? row.id : (try? ParkingLotTree.nodes(rows))?[row.id]?.parentID
        } ?? ParkingLotTree.parentForInsertion(at: index, in: rows, heading: false)
        let row = ParkingLotRow(heading: heading, text: text, parentID: parent)
        rows.insert(row, at: index); commit(rows); return row.id
    }
    func delete(_ id: UUID) {
        guard let range = Self.entryRange(id, in: document.rows) else { return }
        var rows = document.rows; rows.removeSubrange(range); commit(rows)
    }
    /// Where an agent's add/move lands. With a parentID, `before` is honored only
    /// when it names one of that parent's direct children; otherwise the row goes
    /// to the end of the parent's subtree. Agents often send both, and a
    /// conflicting pair must not fail the whole batch.
    static func placement(_ destination: Int?, parent: UUID?, in rows: [ParkingLotRow]) throws -> Int {
        guard let parent else { return destination ?? rows.count }
        guard let parentRange = ParkingLotTree.range(parent, in: rows) else { throw AgentFailure.message("Parking Lot parent no longer exists.") }
        if let destination, destination < rows.count, !rows[destination].heading,
           (try? ParkingLotTree.nodes(rows))?[rows[destination].id]?.parentID == parent { return destination }
        return parentRange.upperBound
    }
    static func entryRange(_ id: UUID, in rows: [ParkingLotRow]) -> Range<Int>? {
        ParkingLotTree.range(id, in: rows)
    }
    static func markdown(_ rows: [ParkingLotRow]) -> String {
        let hierarchy = (try? ParkingLotTree.nodes(rows)) ?? [:]
        var counts: [UUID?: Int] = [:]
        return rows.map { row in
            let parent = hierarchy[row.id]?.parentID
            if !row.heading { counts[parent, default: 0] += 1 }
            let indent = String(repeating: "  ", count: max(0, (hierarchy[row.id]?.depth ?? 1) - 1))
            let continuation = "\n" + indent + "   "
            let line = (row.heading ? "# " : indent + ParkingLotTree.label(counts[parent] ?? 1, depth: hierarchy[row.id]?.depth ?? 1) + ". ") + (row.isDone ? "[Done] " : "") + row.text.replacingOccurrences(of: "\n", with: continuation)
            return line + (row.images ?? []).map { continuation + "[Image: " + URL(fileURLWithPath: $0).lastPathComponent + "]" }.joined() + (row.notes ?? []).map { continuation + "> " + $0.author + ": " + $0.text.replacingOccurrences(of: "\n", with: continuation + "> ") }.joined()
        }.joined(separator: "\n")
    }
    /// The heading an item sits under (headings are top-level; rows are preorder).
    static func section(of id: UUID, in rows: [ParkingLotRow]) -> UUID? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        return rows[...index].last(where: \.heading)?.id
    }
    /// Headings an item can be moved to: every heading except its current section.
    static func moveTargets(for id: UUID, in rows: [ParkingLotRow]) -> [ParkingLotRow] {
        guard let row = rows.first(where: { $0.id == id }), !row.heading else { return [] }
        let current = section(of: id, in: rows)
        return rows.filter { $0.heading && $0.id != current }
    }
    /// Moves an item (with any nested children) to the end of a heading's section.
    @discardableResult func moveToSection(_ id: UUID, heading: UUID) -> Bool {
        let rows = document.rows
        guard Self.moveTargets(for: id, in: rows).contains(where: { $0.id == heading }),
              let start = rows.firstIndex(where: { $0.id == heading }) else { return false }
        let next = rows[(start + 1)...].first(where: \.heading)?.id
        move(id, before: next)
        return Self.section(of: id, in: document.rows) == heading
    }
    func move(_ id: UUID, before destination: UUID?) {
        var rows = document.rows
        guard id != destination, let range = Self.entryRange(id, in: rows) else { return }
        var moving = Array(rows[range])
        guard !moving.contains(where: { $0.id == destination }) else { return }
        rows.removeSubrange(range)
        let index = destination.flatMap { id in rows.firstIndex(where: { $0.id == id }) } ?? rows.count
        if moving[0].heading, index < rows.count, !rows[index].heading { return }
        moving[0].parentID = ParkingLotTree.parentForInsertion(at: index, in: rows, heading: moving[0].heading)
        rows.insert(contentsOf: moving, at: index)
        commit(rows)
    }
    func evidence() throws -> Any {
        guard error.isEmpty else { throw AgentFailure.message(error) }
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(document))
    }
    // Build and validate a whole transaction before saving. A user edit or a
    // second agent run invalidates the old revision instead of losing work.
    func apply(_ edits: ParkingLotEdits, author: String) throws {
        let rows = try preview(edits, author: author)
        if rows != document.rows { try persist(ParkingLotDocument(revision: document.revision + 1, rows: rows)) }
    }
    func preview(_ edits: ParkingLotEdits, author: String) throws -> [ParkingLotRow] {
        try requireWritable()
        guard error.isEmpty else { throw AgentFailure.message(error) }
        guard edits.lotID == nil || edits.lotID == id else { throw AgentFailure.message("Those edits name a different Parking Lot. Nothing changed.") }
        guard edits.revision == document.revision else { throw AgentFailure.message("Parking Lot changed during this run. Read it again before editing; no edits applied.") }
        guard edits.operations.count <= 50 else { throw AgentFailure.message("Too many Parking Lot edits; no edits applied.") }
        var rows = document.rows
        for operation in edits.operations {
            let index = operation.id.flatMap { id in rows.firstIndex(where: { $0.id == id }) }
            switch operation.action {
            case "add":
                guard let text = operation.text else { throw AgentFailure.message("A Parking Lot addition needs text.") }
                let destination = operation.before.flatMap { id in rows.firstIndex(where: { $0.id == id }) }
                guard operation.before == nil || destination != nil else { throw AgentFailure.message("Parking Lot destination no longer exists.") }
                let id = operation.id ?? UUID()
                guard !rows.contains(where: { $0.id == id }) else { throw AgentFailure.message("Parking Lot row ID already exists.") }
                let heading = operation.heading ?? false
                let position = try Self.placement(destination, parent: heading ? nil : operation.parentID, in: rows)
                let parentID = (heading ? nil : operation.parentID) ?? ParkingLotTree.parentForInsertion(at: position, in: rows, heading: heading)
                rows.insert(ParkingLotRow(id: id, heading: heading, text: text, editedBy: author, done: operation.done,
                                          parentID: heading ? nil : parentID), at: position)
            case "update":
                guard let index, operation.text != nil || operation.done != nil else { throw AgentFailure.message("Parking Lot entry no longer exists or no changes were supplied.") }
                if let text = operation.text { rows[index].text = text }
                if let done = operation.done { rows[index].done = done }
                rows[index].editedBy = author
            case "comment":
                guard let index, let text = operation.text else { throw AgentFailure.message("Parking Lot entry no longer exists or text is missing.") }
                rows[index].notes = (rows[index].notes ?? []) + [ParkingLotNote(author: author, text: text)]
            case "delete":
                guard let id = operation.id, let range = Self.entryRange(id, in: rows) else { throw AgentFailure.message("Parking Lot entry no longer exists.") }
                rows.removeSubrange(range)
            case "move":
                guard let id = operation.id, let range = Self.entryRange(id, in: rows), operation.id != operation.before else { throw AgentFailure.message("Invalid Parking Lot move.") }
                var moving = Array(rows[range]); rows.removeSubrange(range)
                let destination = operation.before.flatMap { id in rows.firstIndex(where: { $0.id == id }) }
                guard operation.before == nil || destination != nil else { throw AgentFailure.message("Parking Lot destination no longer exists or is inside the section being moved.") }
                let position = try Self.placement(destination, parent: moving[0].heading ? nil : operation.parentID, in: rows)
                guard !moving[0].heading || (operation.parentID == nil && (position == rows.count || rows[position].heading)) else {
                    throw AgentFailure.message("A Parking Lot heading cannot be nested inside an item.")
                }
                moving[0].parentID = moving[0].heading ? nil : operation.parentID ?? ParkingLotTree.parentForInsertion(at: position, in: rows, heading: false)
                rows.insert(contentsOf: moving, at: position)
            default: throw AgentFailure.message("Unknown Parking Lot operation; no edits applied.")
            }
        }
        try Self.validate(rows)
        return rows
    }
}

struct ParkingLotSidebar: View {
    @State private var showingLinks = false
    @ObservedObject private var library = ParkingLotLibrary.shared
    @ObservedObject var lot: ParkingLotStore
    @ObservedObject var workspace: Workspace
    @ObservedObject var state: WindowState
    @StateObject private var paneHover = SidebarHoverState()
    private func show(_ pane: Int? = nil) {
        lot.open()
        workspace.assign(lot.id, to: state.id, pane: pane ?? workspace.firstAvailablePane(in: state.id))
    }
    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 12, height: 12).accessibilityHidden(true)
            Button { show() } label: {
                SessionName(title: lot.name, isAgent: false, isParkingLot: true).foregroundStyle(lot.active ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).layoutPriority(-1).help("Keep ideas and bugs under headings. Agents can help when you select Parking Lot in their session access list.")
            ProviderLogo(engine: "parking").frame(width: 24)
            PaneButtonGroup(hover: paneHover) {
                PaneButton(label: "P", selected: workspace.placements[lot.id] == nil) { workspace.park(lot.id) }
                    .accessibilityLabel("Park " + lot.name).help("Park this Parking Lot without deleting it")
                ForEach(1...3, id: \.self) { pane in
                    PaneButton(label: String(pane), selected: workspace.pane(for: lot.id, in: state.id) == pane, available: workspace.paneIsAvailable(pane, for: lot.id, in: state.id), stripHovered: paneHover.overButtons) { show(pane) }
                }
                PaneButton(label: "X", selected: false) { ParkingLotLibrary.shared.promptDelete(lot) }
                    .accessibilityLabel("Delete " + lot.name).help("Delete this Parking Lot…")
            }
        }.padding(.leading, 16).padding(.trailing, 4).frame(height: 30)
            .contextMenu {
                Button("Linked Sessions…") { showingLinks = true }
                Toggle("Confirmation Required for Session Updates", isOn: Binding(get: { library.confirmsSessionEdits(lot.id) }, set: { value in
                    do { try library.setConfirmsSessionEdits(lot.id, value) } catch { library.error = error.localizedDescription }
                }))
                Button("Rename Parking Lot…") { ParkingLotLibrary.shared.promptRename(lot) }
                Button("Delete Parking Lot…") { ParkingLotLibrary.shared.promptDelete(lot) }
            }
            .sheet(isPresented: $showingLinks) { ParkingLotLinksView(lot: lot) }
    }
}
struct ParkingLotView: View {
    @ObservedObject var lot: ParkingLotStore
    @ObservedObject var workspace: Workspace
    let pane: Int
    @State private var reordering = false
    @StateObject private var undoFocus = ParkingLotUndoFocus()
    @State private var talking = false
    @State private var dragging: UUID?
    @State private var dropBefore: UUID?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var collapsed: Set<UUID> = []
    @FocusState private var focused: UUID?
    private var visibleRows: [ParkingLotRow] {
        let hierarchy = (try? ParkingLotTree.nodes(lot.document.rows)) ?? [:]
        var hiddenByID: [UUID: Bool] = [:]
        return lot.document.rows.filter { row in
            let hidden = hierarchy[row.id]?.parentID.flatMap { hiddenByID[$0] } ?? false
            hiddenByID[row.id] = hidden || collapsed.contains(row.id)
            return !hidden
        }
    }
    func number(_ row: ParkingLotRow) -> Int {
        let hierarchy = (try? ParkingLotTree.nodes(lot.document.rows)) ?? [:]
        let parent = hierarchy[row.id]?.parentID
        var number = 0
        for entry in lot.document.rows {
            if !entry.heading && hierarchy[entry.id]?.parentID == parent { number += 1 }
            if entry.id == row.id { return number }
        }
        return number
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func rowField(_ row: ParkingLotRow) -> some View {
                TextField(row.heading ? "Heading" : "Write an idea, prompt or bug…", text: Binding(get: { lot.document.rows.first(where: { $0.id == row.id })?.text ?? "" }, set: { lot.update(row.id, text: $0) }), axis: .vertical)
                    .font(row.heading ? .headline : .body).textFieldStyle(.plain)
                    .foregroundColor(Color(nsColor: ParkingOutlineText.color(for: row)))
                    .strikethrough(row.isDone)
                    .disabled(reordering).focused($focused, equals: row.id)
                    .onKeyPress(keys: [.return]) { press in
                        if press.modifiers.contains(.shift) { return KeyPress.Result.ignored }
                        collapsed.remove(row.id)
                        focused = lot.insert(after: row.id)
                        return KeyPress.Result.handled
                    }
    }
    private func destination(for location: CGPoint, source: ParkingLotRow) -> UUID? {
        visibleRows.first { row in
            (!source.heading || row.heading) && (rowFrames[row.id]?.midY ?? -.infinity) > location.y
        }?.id
    }
    private func reorderGesture(_ row: ParkingLotRow) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("parkingOutline"))
            .onChanged { value in dragging = row.id; dropBefore = destination(for: value.location, source: row) }
            .onEnded { value in
                let area = rowFrames.values.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -14, dy: -50)
                if area.contains(value.location) { lot.move(row.id, before: destination(for: value.location, source: row)); undoFocus.activate() }
                dragging = nil; dropBefore = nil
            }
    }
    private func rowView(_ row: ParkingLotRow) -> some View {
        let hasChildren = (ParkingLotTree.range(row.id, in: lot.document.rows)?.count ?? 1) > 1
        let depth = ParkingLotTree.depth(of: row.id, in: lot.document.rows)
        return HStack(alignment: .top, spacing: 8) {
            if reordering {
                Image(systemName: "line.3.horizontal").frame(width: 24, height: 24).contentShape(Rectangle())
                    .gesture(reorderGesture(row)).help("Drag to reorder")
            }
            if hasChildren {
                Button { if !collapsed.insert(row.id).inserted { collapsed.remove(row.id) } } label: {
                    Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down").frame(width: 16)
                }.buttonStyle(.plain).accessibilityLabel(collapsed.contains(row.id) ? "Expand section" : "Collapse section")
            }
            if !row.heading { Text(String(number(row)) + ".").foregroundStyle(.secondary).frame(minWidth: 20, alignment: .trailing) }
            VStack(alignment: .leading, spacing: 3) {
                rowField(row)
                if let notes = row.notes, !notes.isEmpty {
                    DisclosureGroup("Comments (\(notes.count))") {
                        ForEach(notes) { note in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(note.author).font(.caption.bold())
                                Text(note.text).font(.callout).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if let author = row.editedBy { Text("Edited by " + author).font(.caption2).foregroundStyle(.secondary) }
            }
        }.padding(.leading, CGFloat(max(0, depth - 1)) * 20).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .background(GeometryReader { geometry in
            Color.clear.preference(key: ParkingLotFrames.self, value: [row.id: geometry.frame(in: .named("parkingOutline"))])
        })
        .overlay(alignment: .top) { if dragging != nil && dropBefore == row.id { Color.accentColor.frame(height: 2) } }
    }
    private func exportRecovery() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = lot.name + " Recovery.json"
        panel.message = "Save an exact copy of the lot data. Image references still point to the original attachment folder."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try lot.exportRecovery(to: url) }
            catch { lot.error = "Could not export recovery copy: " + error.localizedDescription }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ParkingLotTalkBar(lot: lot)
            HStack(spacing: 8) {
                Text("\(pane)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.white).frame(width: 19, height: 19).background(Color.paneNumberBadge).clipShape(RoundedRectangle(cornerRadius: 3))
                ProviderLogo(engine: "parking")
                SessionName(title: lot.name, isAgent: false, isParkingLot: true).font(.system(size: 15, weight: .medium))
                Spacer(minLength: 0)
                Button(reordering ? "Done" : "Reorder") {
                    let previous = undoFocus.view?.window?.firstResponder
                    reordering.toggle()
                    DispatchQueue.main.async { undoFocus.activate(ifUnchangedFrom: previous) }
                }.controlSize(.small).disabled(lot.isReadOnly)
                PaneButton(label: "P", selected: false) { workspace.park(lot.id) }.accessibilityLabel("Park " + lot.name).help("Park this Parking Lot")
            }.padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            if reordering { Text("Drag the handles to reorder headings and items.").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            if !lot.error.isEmpty { Text(lot.error).foregroundStyle(.red).padding(.horizontal).textSelection(.enabled) }
            if let reason = lot.readOnlyReason {
                Text(reason).font(.callout).padding(.horizontal).textSelection(.enabled)
                HStack {
                    Button("Export recovery copy…", action: exportRecovery)
                    Button("Show saved file") { lot.showSavedFile() }
                }.padding(.horizontal)
                ScrollView {
                    Text(ParkingLotStore.markdown(lot.document.rows))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding()
                }
            } else if !reordering {
                ParkingLotEditor(lot: lot, collapsed: $collapsed, reorder: { reordering = true })
                    .overlay(alignment: .bottomTrailing) { SubstitutionButton(feedback: lot.substitutionFeedback).padding(12) }
            } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleRows) { row in
                        rowView(row)
                    }
                    Text(reordering ? "Drop here to move to the end" : "").frame(maxWidth: .infinity, minHeight: 40)
                        .overlay(alignment: .top) { if dragging != nil && dropBefore == nil { Color.accentColor.frame(height: 2) } }
                }.padding(.horizontal, 14)
            }.coordinateSpace(name: "parkingOutline")
                .onPreferenceChange(ParkingLotFrames.self) { rowFrames = $0 }
            }
            HStack {
                Text(lot.name).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Talk…") { talking = true }.disabled(lot.isReadOnly)
            }.padding(8)
        }.frame(minWidth: PaneSizing.minimumPane, maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
            .background(ParkingLotUndoAnchor(lot: lot, focus: undoFocus).frame(width: 0, height: 0))
            .sheet(isPresented: $talking) { ParkingLotTalkView(lot: lot) }
    }
}
private struct ParkingLotFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

func parkingLotSelfTests(_ check: (Bool, String) -> Void) {
    check((1...3).map { ParkingLotTree.label($0, depth: 1) } == ["1", "2", "3"] && (1...3).map { ParkingLotTree.label($0, depth: 2) } == ["a", "b", "c"]
          && [1, 2, 3, 4, 9, 14].map { ParkingLotTree.label($0, depth: 3) } == ["i", "ii", "iii", "iv", "ix", "xiv"] && ParkingLotTree.label(2, depth: 4) == "2"
          && ParkingLotTree.letters(27) == "aa" && ParkingLotTree.letters(26) == "z", "Outline labels go 1, a, i by level, then repeat")
    parkingOutlineSelfTests(check)
    parkingLinkEditorSelfTests(check)
    parkingLibrarySelfTests(check)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parking-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lot = ParkingLotStore(folder: folder)
    check(!lot.active && !FileManager.default.fileExists(atPath: folder.path), "Parking Lot remains an inactive placeholder until opened")
    lot.open()
    check(lot.active && lot.document.rows.filter(\.heading).map(\.text) == ["New features", "Bugs"], "Opening Parking Lot creates editable headings")
    let item = lot.document.rows[1].id
    lot.update(item, text: "A useful idea")
    let reload = ParkingLotStore(folder: folder)
    check(reload.document == lot.document, "Parking Lot content and revision survive reopening")
    do {
        // Move ➞ <heading>: an item and its nested children go to the end of another section.
        let moveFolder = FileManager.default.temporaryDirectory.appendingPathComponent("parking-move-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: moveFolder) }
        let moves = ParkingLotStore(folder: moveFolder); moves.open()
        let now = moves.document.rows[0].id, future = moves.document.rows.first { $0.heading && $0.text == "Bugs" }!.id
        let idea = moves.insert(text: "Idea", after: future), child = moves.insert(text: "Detail", after: idea)
        _ = moves.changeIndent(child, deeper: true)
        let existing = moves.insert(text: "Already here", after: now)
        check(ParkingLotStore.moveTargets(for: idea, in: moves.document.rows).map(\.id) == [now] && ParkingLotStore.moveTargets(for: future, in: moves.document.rows).isEmpty,
              "Move targets list every other heading for items, none for headings")
        check(moves.moveToSection(idea, heading: now), "Move ➞ heading moves an item to another section")
        let rows = moves.document.rows, ideaIndex = rows.firstIndex { $0.id == idea }!
        check(ParkingLotStore.section(of: idea, in: rows) == now && rows[ideaIndex].parentID == now && rows[ideaIndex + 1].id == child && rows[ideaIndex + 1].parentID == idea
              && ideaIndex > rows.firstIndex { $0.id == existing }! && ideaIndex < rows.firstIndex { $0.id == future }!,
              "The item lands at the end of the target section with its nested children")
        check(!moves.moveToSection(idea, heading: now), "Moving to the current section is refused")
        // Agents often send both parentID and before. A conflicting pair (before
        // names a row in another section) places the row at the end of the
        // parent's subtree instead of failing the whole batch.
        let otherSection = moves.document.rows.first { !$0.heading && ParkingLotStore.section(of: $0.id, in: moves.document.rows) == future }?.id
            ?? moves.insert(text: "Bug row", after: future)
        do {
            let added = UUID()
            try moves.apply(ParkingLotEdits(revision: moves.document.revision, operations: [.init(action: "add", id: added, text: "Nested note", before: otherSection, parentID: idea)]), author: "Agent")
            let after = moves.document.rows, ideaRange = ParkingLotTree.range(idea, in: after)!
            check(after.first { $0.id == added }?.parentID == idea && ideaRange.contains(after.firstIndex { $0.id == added }!),
                  "An add whose before conflicts with its parentID lands at the end of the parent's subtree")
            try moves.apply(ParkingLotEdits(revision: moves.document.revision, operations: [.init(action: "move", id: added, before: otherSection, parentID: now)]), author: "Agent")
            check(moves.document.rows.first { $0.id == added }?.parentID == now && ParkingLotStore.section(of: added, in: moves.document.rows) == now,
                  "A move whose before conflicts with its parentID goes to the end of that parent")
            let sibling = moves.insert(text: "Sibling", after: existing)
            let placed = UUID()
            try moves.apply(ParkingLotEdits(revision: moves.document.revision, operations: [.init(action: "add", id: placed, text: "Before sibling", before: sibling, parentID: now)]), author: "Agent")
            let rows = moves.document.rows
            check(rows.firstIndex { $0.id == placed }! + 1 == rows.firstIndex { $0.id == sibling }!, "before is honored when it names a direct child of the parent")
            do { try moves.apply(ParkingLotEdits(revision: moves.document.revision, operations: [.init(action: "add", text: "Orphan", parentID: UUID())]), author: "Agent"); check(false, "Unknown parent rejected") }
            catch { check(error.localizedDescription.contains("parent no longer exists"), "An unknown parentID is refused clearly") }
        } catch { check(false, "Agent placement tests: " + error.localizedDescription) }
    }
    func edits(_ operations: [ParkingLotEdits.Operation], revision: Int? = nil) -> ParkingLotEdits {
        ParkingLotEdits(revision: revision ?? lot.document.revision, operations: operations)
    }
    do {
        let stale = lot.document.revision
        try lot.apply(edits([.init(action: "comment", id: item, text: "Practical with a small prototype.")]), author: "Reviewer")
        check(lot.document.rows[1].text == "A useful idea" && lot.document.rows[1].notes?.first?.author == "Reviewer" && lot.document.rows[1].notes?.first?.text.contains("Practical") == true, "Agent comments preserve the original idea and identify the author")
        let before = lot.document
        do { try lot.apply(edits([.init(action: "delete", id: item)], revision: stale), author: "Other"); check(false, "Stale edits rejected") }
        catch { check(lot.document == before, "Concurrent edits cannot overwrite newer Parking Lot changes") }
        do { try lot.apply(edits([.init(action: "delete", id: item), .init(action: "update", id: UUID(), text: "missing")]), author: "Reviewer"); check(false, "Invalid edit transaction rejected") }
        catch { check(lot.document == before, "An invalid agent batch applies none of its edits") }
        lot.move(item, before: nil)
        check(lot.document.rows.last?.id == item, "Reordering preserves entry identity and moves it to the end")
        let heading = lot.document.rows.first!.id
        let sectionIDs = Array(lot.document.rows.prefix(while: { $0.id == heading || !$0.heading }).map(\.id))
        lot.move(heading, before: nil)
        check(Array(lot.document.rows.suffix(sectionIDs.count).map(\.id)) == sectionIDs, "Moving a heading keeps its section together")
        let config = AgentConfig()
        check(!config.allows(local: ParkingLotStore.id, home: "test"), "Agents cannot access Parking Lot by default")
        var scoped = config; scoped.watchedSessions = [ParkingLotStore.id]
        let decoded = try JSONDecoder().decode(AgentConfig.self, from: JSONEncoder().encode(scoped))
        check(decoded.allows(local: ParkingLotStore.id, home: "test"), "Parking Lot uses the existing persisted session access list")
        let reply = AgentReply.decode("{\"reply\":\"Assessment\",\"parkingLotEdits\":{\"revision\":1,\"operations\":[{\"action\":\"add\",\"text\":\"Prototype\"}]}}")
        check(reply?.parkingLotEdits?.operations.first?.text == "Prototype", "Agent reply parses structured Parking Lot edits")
    } catch { check(false, "Parking Lot checks: " + error.localizedDescription) }
    let completed = ParkingLotStore(folder: folder.appendingPathComponent("completion")); completed.open()
    let headingID = completed.document.rows[0].id, itemID = completed.document.rows[1].id
    completed.setDone(headingID, true)
    check(completed.document.rows[0].isDone && !completed.document.rows[1].isDone, "Completing a heading preserves its children's individual states")
    completed.undoManager.undo()
    check(!completed.document.rows[0].isDone, "Undo restores a heading's completion state")
    completed.undoManager.redo()
    check(ParkingLotStore(folder: folder.appendingPathComponent("completion")).document.rows[0].isDone, "Redo completion persists across reopening")
    do {
        let editJSON = "{\"revision\":\(completed.document.revision),\"operations\":[{\"action\":\"update\",\"id\":\"\(itemID)\",\"done\":true}]}"
        let edits = try JSONDecoder().decode(ParkingLotEdits.self, from: Data(editJSON.utf8))
        try completed.apply(edits, author: "Reviewer")
        check(completed.document.rows[1].isDone && completed.document.rows[1].text.isEmpty && completed.document.rows[1].editedBy == "Reviewer", "Session and agent edits can mark Done without replacing the item's text")
        try completed.apply(ParkingLotEdits(revision: completed.document.revision, operations: [.init(action: "update", id: itemID, done: false)]), author: "Reviewer")
        check(!completed.document.rows[1].isDone, "Structured Done false reopens an item")
        let legacy = try JSONDecoder().decode(ParkingLotRow.self, from: Data("{\"id\":\"\(UUID())\",\"heading\":false,\"text\":\"Old idea\"}".utf8))
        check(!legacy.isDone, "Old Parking Lot files without done decode as unfinished")
        check(completed.exportMessages[0].text.contains("[Done]"), "Completed headings remain identified in exports and Group snapshots")
    } catch { check(false, "Completion state tests: " + error.localizedDescription) }
    do {
        let oldJSON = "{\"revision\":3,\"rows\":[{\"id\":\"\(UUID())\",\"heading\":true,\"text\":\"Legacy\"},{\"id\":\"\(UUID())\",\"heading\":false,\"text\":\"Item\"}]}"
        let old = try JSONDecoder().decode(ParkingLotDocument.self, from: Data(oldJSON.utf8))
        let oldHierarchy = try ParkingLotTree.nodes(old.rows)
        check(old.schemaVersion == 1 && oldHierarchy[old.rows[1].id]?.parentID == old.rows[0].id,
              "Legacy flat lots decode with their items under the preceding heading")
        let newer = oldJSON.replacingOccurrences(of: "{\"revision\"", with: "{\"schemaVersion\":99,\"revision\"")
        check((try? JSONDecoder().decode(ParkingLotDocument.self, from: Data(newer.utf8))) == nil,
              "An older build rejects a newer Parking Lot schema instead of dropping unknown fields")
        let tree = ParkingLotStore(folder: folder.appendingPathComponent("nested"))
        let heading = ParkingLotRow(heading: true, text: "Plans")
        let parent = ParkingLotRow(heading: false, text: "Parent")
        let child = ParkingLotRow(heading: false, text: "Child")
        let grandchild = ParkingLotRow(heading: false, text: "Grandchild")
        let nextHeading = ParkingLotRow(heading: true, text: "Later")
        tree.openStarter([heading, parent, child, grandchild, nextHeading])
        check(tree.changeIndent(child.id, deeper: true) && tree.changeIndent(grandchild.id, deeper: true)
              && tree.changeIndent(grandchild.id, deeper: true), "Tab can create multiple nested item levels")
        let nested = try ParkingLotTree.nodes(tree.document.rows)
        check(nested[child.id]?.parentID == parent.id && nested[grandchild.id]?.parentID == child.id
              && nested[grandchild.id]?.depth == 3, "Nested items persist stable parent IDs and preorder")
        check(ParkingLotStore.entryRange(parent.id, in: tree.document.rows)?.count == 3,
              "An item subtree includes all its descendants")
        check(ParkingLotStore(folder: folder.appendingPathComponent("nested")).document == tree.document,
              "The nested schema survives reopening")
        let outdented = tree.changeIndent(grandchild.id, deeper: false)
        let afterOutdent = try ParkingLotTree.nodes(tree.document.rows)
        check(outdented && afterOutdent[grandchild.id]?.parentID == parent.id,
              "Shift-Tab outdents an item without losing its parent or siblings")
        tree.move(parent.id, before: nextHeading.id)
        check(tree.document.rows.map(\.id) == [heading.id, parent.id, child.id, grandchild.id, nextHeading.id],
              "Moving an item subtree preserves its descendants and section")
        let before = tree.document
        do {
            try tree.apply(.init(revision: before.revision, operations: [.init(action: "move", id: parent.id, before: child.id)]), author: "Agent")
            check(false, "Moving a parent inside its own subtree must fail")
        } catch { check(tree.document == before, "An invalid nested agent move is atomic") }
        tree.delete(parent.id)
        check(tree.document.rows.map(\.id) == [heading.id, nextHeading.id], "Deleting a parent removes its whole subtree")
        tree.undoManager.undo()
        check(tree.document.rows.map(\.id) == before.rows.map(\.id), "Undo restores a deleted nested subtree")
    } catch { check(false, "Nested Parking Lot tests: " + error.localizedDescription) }
    do {
        let heading = ParkingLotRow(heading: true, text: "Recovery")
        let overRows = [heading] + (0..<500).map { ParkingLotRow(heading: false, text: "Item \($0)", parentID: heading.id) }
        let longText = [ParkingLotRow(heading: false, text: String(repeating: "x", count: 20_001))]
        let longNote = [ParkingLotRow(heading: false, text: "Item", notes: [.init(author: "Test", text: String(repeating: "n", count: 20_001))])]
        let totalText = (0..<13).map { _ in ParkingLotRow(heading: false, text: String(repeating: "t", count: 20_000)) }
        for (index, rows) in [overRows, longText, longNote, totalText].enumerated() {
            let home = folder.appendingPathComponent("oversize-\(index)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let source = home.appendingPathComponent("parking-lot.json")
            let original = ParkingLotDocument(revision: 7, rows: rows)
            // Extra unknown fields and whitespace must survive recovery export.
            let encoded = try JSONEncoder().encode(original)
            let bytes = Data(("{\"recoveryTest\":true," + String(decoding: encoded, as: UTF8.self).dropFirst() + "\n").utf8)
            try bytes.write(to: source)
            let recovered = ParkingLotStore(folder: home)
            check(recovered.active && recovered.isReadOnly && recovered.document == original && recovered.error.isEmpty,
                  "Size-only limit \(index) opens its complete document read-only")
            check(recovered.exportMessages.count == rows.count && (try? recovered.evidence()) != nil,
                  "Size-only limit \(index) remains available for export and reading")
            recovered.open(); recovered.openStarter([])
            recovered.update(rows[0].id, text: "Overwrite")
            recovered.delete(rows[0].id)
            do { try recovered.replaceUserRows([], revision: 7); check(false, "Recovery editor must refuse saves") } catch {}
            do { try recovered.apply(.init(revision: 7, operations: [.init(action: "delete", id: rows[0].id)]), author: "Agent"); check(false, "Recovery agent must refuse saves") } catch {}
            check(try recovered.document == original && !recovered.undoManager.canUndo && Data(contentsOf: source) == bytes,
                  "Recovery protects source and revision against user and agent writes")
            let copy = home.appendingPathComponent("recovery.json")
            try recovered.exportRecovery(to: copy)
            check(try Data(contentsOf: copy) == bytes, "Recovery export preserves exact source bytes and unknown fields")
            do { try recovered.exportRecovery(to: source); check(false, "Recovery must refuse its source as destination") } catch {}
        }
        let invalids = [
            [heading, ParkingLotRow(heading: false, text: "Orphan", parentID: UUID())],
            [heading, heading],
            overRows + [ParkingLotRow(heading: false, text: "Broken and oversized", parentID: UUID())]
        ]
        for (index, rows) in invalids.enumerated() {
            let home = folder.appendingPathComponent("invalid-tree-\(index)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let source = home.appendingPathComponent("parking-lot.json")
            let bytes = try JSONEncoder().encode(ParkingLotDocument(revision: 8, rows: rows))
            try bytes.write(to: source)
            let invalid = ParkingLotStore(folder: home)
            check(!invalid.active && invalid.document.rows.isEmpty && !invalid.error.isEmpty && invalid.isReadOnly,
                  "Invalid tree \(index) refuses to load, even when also oversized")
            invalid.open(); invalid.openStarter([]); _ = invalid.insert(text: "Overwrite")
            do { try invalid.replaceUserRows([], revision: 0); check(false, "Invalid tree must refuse replacement") } catch {}
            let copy = home.appendingPathComponent("recovery.json")
            try invalid.exportRecovery(to: copy)
            check(try Data(contentsOf: source) == bytes && Data(contentsOf: copy) == bytes,
                  "Invalid tree stays byte-identical and can be copied for recovery")
        }
    } catch { check(false, "Parking Lot recovery tests: " + error.localizedDescription) }
    let corrupt = folder.appendingPathComponent("bad")
    try? FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
    try? Data("broken".utf8).write(to: corrupt.appendingPathComponent("parking-lot.json"))
    let broken = ParkingLotStore(folder: corrupt); broken.open()
    check(!broken.error.isEmpty && (try? String(contentsOf: corrupt.appendingPathComponent("parking-lot.json"))) == "broken", "Unreadable Parking Lot data is reported and never silently replaced")
}

/// While a voice conversation about this lot is running, its controls live in the
/// lot's own pane: the talk session itself is usually not shown in any pane.
struct ParkingLotTalkBar: View {
    @ObservedObject var lot: ParkingLotStore
    @ObservedObject var conversation = AgentConversation.shared
    @ObservedObject var store = Store.shared
    static func talkSession(for lot: UUID, sessionID: UUID?, sessions: [Session]) -> Session? {
        guard let sessionID else { return nil }
        return sessions.first { $0.id == sessionID && $0.agent?.parkingLotTalkID == lot }
    }
    var body: some View {
        if conversation.active, let session = Self.talkSession(for: lot.id, sessionID: conversation.sessionID, sessions: store.sessions) {
            HStack(spacing: 8) {
                Image(systemName: conversation.phase == .listening ? "mic.fill" : "speaker.wave.2.fill").foregroundStyle(.orange)
                Text(conversation.status.isEmpty ? "Talking about \u{201C}" + lot.name + "\u{201D}" : conversation.status)
                    .font(.callout).lineLimit(2)
                    .help(conversation.lastHeard.isEmpty ? conversation.status : "Heard: " + conversation.lastHeard)
                Spacer(minLength: 0)
                Button("Stop talking") { conversation.stop() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel("Stop talking about " + lot.name)
                    .help("End the voice conversation and turn the microphone off. " + session.title + " keeps its transcript.")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.orange.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
