import AppKit
import SwiftUI
import Combine

/// Signals the views around the editor. Typing changes only row text, which they
/// never show, so a text-only user edit defers this signal until typing pauses.
final class ParkingLotChrome: ObservableObject {}

// Local notes, not a provider session. The stable ID uses the ordinary agent
// watched-session scope and workspace placement, without starting a CLI.
final class ParkingLotStore: ObservableObject, Identifiable {
    static let id = UUID(uuidString: "B4AA70E2-147E-40A1-9342-0751C0A40101")!
    static let placementGuidance = """
    Choose a section by meaning when adding an item, unless the human specified a destination. Read the existing headings and their items first; use the most relevant existing section without asking when the fit is clear. A report of broken behavior belongs under Bugs, praise under Compliments, and a deferred idea under Future work. Respect project boundaries and planning-only headings. Do not append to the last section just because it is convenient. Rows belong to the nearest preceding heading: to append inside a section, set before to the NEXT heading's UUID; omit before only if the chosen section is the last one. To place an item first in a section, use its first item's UUID (or the next heading for an empty section). If no section fits, propose a clearly named heading with the item; ask only when the intended classification is genuinely ambiguous. Preserve existing wording, IDs, comments, images and Done state when moving an item. Do not reorganize unrelated items. Briefly name the chosen section in your reply.
    For a nested item, set parentID to the item it belongs under and place it after that parent or its descendants. Rows are stored in preorder. A move or delete of a parent includes its descendants. Headings stay at the top level.
    """
    static let tagGuidance = "Tags are explicit named colors: red, orange, yellow, green, blue, purple. Add/update may set tag to a color or none to clear it; omitted tag preserves it. unresolvedTagCounts counts unfinished non-heading items only, with no inheritance from parents. A goal such as no red items means resolving the work, not deleting items or clearing/recoloring tags to improve the score."
    // Named lots are owned by ParkingLotLibrary; there is no second singleton copy.
    let id: UUID
    let substitutionFeedback = SubstitutionFeedback()
    let chrome = ParkingLotChrome()
    private var chromeObserver: AnyCancellable?
    private var deferChrome = false
    private var pendingChrome: DispatchWorkItem?
    let undoManager: UndoManager = { let manager = UndoManager(); manager.groupsByEvent = false; manager.levelsOfUndo = 100; return manager }()
    @Published var name: String
    @Published private(set) var document = ParkingLotDocument()
    @Published private(set) var active = false
    @Published var error = ""
    /// Why the last Undo or Redo was refused. Unlike `error`, it never blocks other writers.
    @Published var notice = ""
    @Published private(set) var readOnlyReason: String?
    @Published private(set) var lastSeenRevision = 0
    var hasUnseenChanges: Bool { active && document.revision > lastSeenRevision }
    private var viewers: Set<UUID> = []
    private let seenFile: URL
    var isReadOnly: Bool { readOnlyReason != nil }
    private let file: URL
    let attachmentFolder: URL
    init(folder: URL, id: UUID = ParkingLotStore.id, name: String = "Parking Lot") {
        self.id = id; self.name = name
        seenFile = folder.appendingPathComponent("ParkingLot Seen/" + id.uuidString + ".json")
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
        lastSeenRevision = (try? JSONDecoder().decode(Int.self, from: Data(contentsOf: seenFile))) ?? document.revision
        if active { saveSeenRevision() }
        chromeObserver = objectWillChange.sink { [weak self] _ in
            guard let self, !self.deferChrome else { return }
            self.pendingChrome?.cancel(); self.pendingChrome = nil
            self.chrome.objectWillChange.send()
        }
    }
    private func refreshChromeSoon() {
        pendingChrome?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.pendingChrome = nil; self?.chrome.objectWillChange.send() }
        pendingChrome = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }
    private static func onlyTextDiffers(_ a: [ParkingLotRow], _ b: [ParkingLotRow]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.id == $1.id && $0.heading == $1.heading && $0.parentID == $1.parentID && $0.tag == $1.tag && $0.done == $1.done && $0.images == $1.images && $0.notes == $1.notes
        }
    }
    private var savedSeenRevision: Int?
    private var pendingSeenSave: DispatchWorkItem?
    private func saveSeenRevision() {
        pendingSeenSave?.cancel(); pendingSeenSave = nil
        do {
            try FileManager.default.createDirectory(at: seenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(lastSeenRevision).write(to: seenFile, options: .atomic)
            savedSeenRevision = lastSeenRevision
        } catch { NSLog("Could not save Parking Lot reading position: %@", error.localizedDescription) }
    }
    /// The file only drives the unseen marker, and a lost beat of it just shows
    /// the marker again, so a burst of edits to an open lot writes it once.
    private func saveSeenRevisionSoon() {
        guard lastSeenRevision != savedSeenRevision else { return }
        guard savedSeenRevision != nil, !viewers.isEmpty, Thread.isMainThread else { saveSeenRevision(); return }
        guard pendingSeenSave == nil else { return }
        let task = DispatchWorkItem { [weak self] in self?.saveSeenRevision() }
        pendingSeenSave = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: task)
    }
    func beginViewing(_ viewer: UUID) {
        viewers.insert(viewer)
        if lastSeenRevision != document.revision { lastSeenRevision = document.revision; saveSeenRevision() }
    }
    func endViewing(_ viewer: UUID) {
        viewers.remove(viewer)
        if pendingSeenSave != nil { saveSeenRevision() }
    }
    var authorityCheck: (() throws -> Void)?
    var snapshotCheck: ((ParkingLotDocument) throws -> Void)?
    private func requireWritable() throws {
        try authorityCheck?()
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
    var exportMessages: [Message] { Self.exportMessages(document) }
    static func exportMessages(_ document: ParkingLotDocument) -> [Message] {
        let hierarchy = (try? ParkingLotTree.nodes(document.rows)) ?? [:]
        let numbers = ParkingLotTree.numbers(document.rows)
        return document.rows.map { row in
            var copy = row
            // The ordinary Markdown helper numbers a standalone item as one.
            // Preserve the section's actual numbering in the exported message.
            copy.images = nil
            var text = Self.markdown([copy])
            if !row.heading {
                if text.hasPrefix("1. ") { text = ParkingLotTree.label(numbers[row.id] ?? 1, depth: hierarchy[row.id]?.depth ?? 1) + ". " + text.dropFirst(3) }
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
    /// Only `user` saves (native editor, outline commands, reorder, tags) join
    /// the Undo history; session, agent, device and Undo saves never do.
    private func persist(_ next: ParkingLotDocument, user: Bool = false, undoName: String? = nil) throws {
        try requireWritable()
        let capture = PerformanceCapture.shared
        var next = next
        next.rows = try capture.measure(.lotNormalize) { try ParkingLotTree.normalized(next.rows) }
        next.schemaVersion = ParkingLotDocument.schemaVersion(for: next.rows)
        try capture.measure(.lotSnapshotCheck) { try snapshotCheck?(next) }
        try capture.measure(.lotEncodeWrite) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
        }
        let before = document.rows, after = next.rows
        if user && active && before != after {
            capture.measure(.lotUndoRegister) {
                let name = undoName ?? ParkingLotUndo.actionName(before, after)
                undoManager.beginUndoGrouping()
                undoManager.registerUndo(withTarget: self) { lot in lot.revert(from: after, to: before) }
                undoManager.setActionName(name)
                undoManager.endUndoGrouping()
            }
        }
        capture.measure(.lotPublish) {
            let textOnly = user && active && Thread.isMainThread && error.isEmpty && notice.isEmpty && Self.onlyTextDiffers(before, after)
            deferChrome = textOnly
            document = next; active = true; error = ""
            if user { notice = "" }
            if !viewers.isEmpty { lastSeenRevision = next.revision }
            deferChrome = false
            if textOnly { refreshChromeSoon() }
        }
        capture.measure(.lotSeenWrite) { saveSeenRevisionSoon() }
    }
    /// Undo or Redo one user edit against the current rows. A conflict drops
    /// the entry and explains why; it never restores an older document.
    private func revert(from base: [ParkingLotRow], to target: [ParkingLotRow]) {
        let redo = undoManager.isRedoing
        do {
            let rows = try ParkingLotUndo.applying(from: base, to: target, onto: document.rows)
            try Self.validate(rows)
            if rows != document.rows { try persist(ParkingLotDocument(revision: document.revision + 1, rows: rows)) }
            // UndoManager carries the group's action name over to Redo.
            undoManager.registerUndo(withTarget: self) { lot in lot.revert(from: target, to: base) }
            notice = ""
        } catch let conflict as ParkingLotUndo.Conflict { notice = conflict.message(redo: redo) }
        catch { self.error = "Parking Lot was not saved: " + error.localizedDescription }
    }
    func commitRemote(_ document: ParkingLotDocument) throws {
        try Self.validate(document.rows)
        guard document.revision == self.document.revision + 1 else { throw ParkingLotError.message("Parking Lot revision changed.") }
        try persist(document)
        undoManager.removeAllActions()
    }
    private func commit(_ rows: [ParkingLotRow], undoName: String? = nil) {
        do { try Self.validate(rows); try persist(ParkingLotDocument(revision: document.revision + 1, rows: rows), user: true, undoName: undoName) }
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
    func replaceUserRows(_ rows: [ParkingLotRow], revision: Int, undoName: String? = nil) throws {
        try requireWritable()
        guard revision == document.revision else { throw AgentFailure.message("Parking Lot changed. Please try your edit again.") }
        try PerformanceCapture.shared.measure(.lotValidate) { try Self.validate(rows) }
        if rows != document.rows { try persist(ParkingLotDocument(revision: revision + 1, rows: rows), user: true, undoName: undoName) }
    }
    func setDone(_ id: UUID, _ done: Bool) {
        var rows = document.rows
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].isDone != done else { return }
        rows[index].done = done; rows[index].editedBy = nil; commit(rows, undoName: done ? "Mark Done" : "Mark Not Done")
    }
    func setTag(_ id: UUID, _ tag: ParkingLotTag?) {
        var rows = document.rows
        guard !isReadOnly, let index = rows.firstIndex(where: { $0.id == id }), rows[index].tag != tag else { return }
        rows[index].tag = tag; rows[index].editedBy = nil; commit(rows, undoName: tag == nil ? "Clear Color Tag" : "Color Tag")
    }
    static func unresolvedTagCounts(_ rows: [ParkingLotRow]) -> [String: Int] {
        var counts = Dictionary(uniqueKeysWithValues: ParkingLotTag.allCases.map { ($0.rawValue, 0) })
        for row in rows where !row.heading && !row.isDone {
            if let tag = row.tag { counts[tag.rawValue, default: 0] += 1 }
        }
        return counts
    }
    @discardableResult func changeIndent(_ id: UUID, deeper: Bool) -> Bool {
        changeIndent([id], deeper: deeper)
    }
    @discardableResult func changeIndent(_ ids: Set<UUID>, deeper: Bool) -> Bool {
        guard !isReadOnly, let rows = ParkingLotTree.changingIndent(ids, in: document.rows, deeper: deeper) else { return false }
        do {
            try replaceUserRows(rows, revision: document.revision, undoName: deeper ? "Indent Items" : "Outdent Items")
            return true
        } catch { self.error = "Parking Lot was not saved: " + error.localizedDescription; return false }
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
        var rows = document.rows; rows.removeSubrange(range); commit(rows, undoName: "Delete")
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
        let numbers = ParkingLotTree.numbers(rows)
        return rows.map { row in
            let indent = String(repeating: "  ", count: max(0, (hierarchy[row.id]?.depth ?? 1) - 1))
            let continuation = "\n" + indent + "   "
            let line = (row.heading ? "# " : indent + ParkingLotTree.label(numbers[row.id] ?? 1, depth: hierarchy[row.id]?.depth ?? 1) + ". ") + (row.isDone ? "[Done] " : "") + (row.tag.map { "[Tag: " + $0.rawValue + "] " } ?? "") + row.text.replacingOccurrences(of: "\n", with: continuation)
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
        move(id, before: next, depth: 1)
        return Self.section(of: id, in: document.rows) == heading
    }
    /// A drop or move adopts the parent at the destination; see ParkingLotTree.moving.
    @discardableResult func move(_ id: UUID, before destination: UUID?, depth: Int? = nil) -> Bool {
        guard !isReadOnly, let rows = ParkingLotTree.moving(id, before: destination, depth: depth, in: document.rows) else { return false }
        if rows != document.rows { commit(rows, undoName: "Move") }
        return true
    }
    func evidence() throws -> Any {
        guard error.isEmpty else { throw AgentFailure.message(error) }
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as! [String: Any]
        value["unresolvedTagCounts"] = Self.unresolvedTagCounts(document.rows)
        value["tagGuidance"] = Self.tagGuidance
        return value
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
            let tag = try ParkingLotTag.parseEdit(operation.tag)
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
                                          parentID: heading ? nil : parentID, tag: tag), at: position)
            case "update":
                guard let index, operation.text != nil || operation.done != nil || operation.tag != nil else { throw AgentFailure.message("Parking Lot entry no longer exists or no changes were supplied.") }
                if let text = operation.text { rows[index].text = text }
                if let done = operation.done { rows[index].done = done }
                if operation.tag != nil { rows[index].tag = tag }
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
                moving[0].indent = nil
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
    let lot: ParkingLotStore
    @ObservedObject private var chrome: ParkingLotChrome
    @ObservedObject var workspace: Workspace
    @ObservedObject var state: WindowState
    @StateObject private var paneHover = SidebarHoverState()
    init(lot: ParkingLotStore, workspace: Workspace, state: WindowState) {
        self.lot = lot; _chrome = ObservedObject(wrappedValue: lot.chrome)
        _workspace = ObservedObject(wrappedValue: workspace); _state = ObservedObject(wrappedValue: state)
    }
    private func show(_ pane: Int? = nil) {
        lot.open()
        workspace.assign(lot.id, to: state.id, pane: pane ?? workspace.firstAvailablePane(in: state.id))
    }
    var body: some View {
        HStack(spacing: 6) {
            Group {
                if lot.hasUnseenChanges {
                    Text("👀").font(.system(size: 10)).fixedSize()
                        .help("This Parking Lot changed while it was not displayed. Open it to read the changes.")
                        .accessibilityLabel("Unseen Parking Lot changes")
                } else { Color.clear.accessibilityHidden(true) }
            }.frame(width: 12, height: 12)
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
                Button("Import…") { ParkingLotTransfer.importConversations() }
                Button("Export Parking Lot…") { ParkingLotTransfer.export(lot) }
                Button("Delete Parking Lot…") { ParkingLotLibrary.shared.promptDelete(lot) }
            }
            .sheet(isPresented: $showingLinks) { ParkingLotLinksView(lot: lot) }
    }
}
/// The lot menus reuse the normal reviewed import/export flows. Export starts
/// with this lot alone, rather than silently selecting every conversation.
enum ParkingLotTransfer {
    static func importConversations() { (NSApp.delegate as? AppDelegate)?.chooseConversationsToImport() }
    static func export(_ lot: ParkingLotStore) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        if let exporter = delegate.transcriptExporter { exporter.showActivePanel(); return }
        let exporter = TranscriptExportController(sessions: [ExportSession(lot: lot)], lotOnly: true)
        delegate.transcriptExporter = exporter
        exporter.completed = { [weak delegate] in delegate?.transcriptExporter = nil }
        exporter.show(for: NSApp.keyWindow)
    }
}

struct ParkingLotView: View {
    @State private var viewerID = UUID()
    let lot: ParkingLotStore
    @ObservedObject private var chrome: ParkingLotChrome
    @ObservedObject var workspace: Workspace
    let pane: Int
    init(lot: ParkingLotStore, workspace: Workspace, pane: Int) {
        self.lot = lot; _chrome = ObservedObject(wrappedValue: lot.chrome)
        _workspace = ObservedObject(wrappedValue: workspace); self.pane = pane
    }
    @State private var reordering = false
    @StateObject private var undoFocus = ParkingLotUndoFocus()
    @StateObject private var finder = ParkingLotFinder()
    @State private var talking = false
    @State private var dragging: UUID?
    @State private var dropBefore: UUID?
    @State private var dropDepth: Int?
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
    func number(_ row: ParkingLotRow) -> Int { ParkingLotTree.numbers(lot.document.rows)[row.id] ?? 0 }
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
    /// Dragging sideways by one indent changes the drop level, as in an outliner.
    private func wantedDepth(_ row: ParkingLotRow, _ value: DragGesture.Value) -> Int {
        ParkingLotTree.depth(of: row.id, in: lot.document.rows) + Int((value.translation.width / 20).rounded())
    }
    private func reorderGesture(_ row: ParkingLotRow) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("parkingOutline"))
            .onChanged { value in
                dragging = row.id; dropBefore = destination(for: value.location, source: row)
                dropDepth = ParkingLotTree.moving(row.id, before: dropBefore, depth: wantedDepth(row, value), in: lot.document.rows)
                    .map { ParkingLotTree.depth(of: row.id, in: $0) }
            }
            .onEnded { value in
                let area = rowFrames.values.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -14, dy: -50)
                if area.contains(value.location) {
                    if lot.move(row.id, before: destination(for: value.location, source: row), depth: wantedDepth(row, value)) { undoFocus.activate() }
                    else { NSSound.beep() }
                }
                dragging = nil; dropBefore = nil; dropDepth = nil
            }
    }
    private func dropIndicator(before id: UUID?) -> some View {
        Group {
            if dragging != nil && dropBefore == id, let dropDepth {
                Color.accentColor.frame(height: 2).padding(.leading, CGFloat(max(0, dropDepth - 1)) * 20)
            }
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
        .overlay(alignment: .top) { dropIndicator(before: row.id) }
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
    private func foldButtons(_ folding: ParkingLotFolding, compact: Bool) -> some View {
        HStack(spacing: 6) {
            Button { collapsed = folding.targets } label: {
                if compact { Image(systemName: "chevron.up") } else { Text("Collapse All") }
            }.disabled(!folding.canCollapseAll)
                .accessibilityLabel("Collapse All")
                .help("Collapse All: fold every heading and nested branch without changing the lot.")
            if folding.collapsedCount > 0 {
                Button { collapsed = [] } label: {
                    if compact { Image(systemName: "chevron.down") } else { Text("Expand All") }
                }.accessibilityLabel("Expand All")
                    .help("Expand All: show every nested level.")
            }
        }.fixedSize()
    }
    var body: some View {
        let folding = ParkingLotFolding(rows: lot.document.rows, collapsed: collapsed)
        VStack(alignment: .leading, spacing: 8) {
            ParkingLotTalkBar(lot: lot)
            HStack(spacing: 8) {
                Text("\(pane)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.white).frame(width: 19, height: 19).background(Color.paneNumberBadge).clipShape(RoundedRectangle(cornerRadius: 3))
                ProviderLogo(engine: "parking")
                SessionName(title: lot.name, isAgent: false, isParkingLot: true).font(.system(size: 15, weight: .medium))
                Spacer(minLength: 0)
                PaneButton(label: "P", selected: false) { workspace.park(lot.id) }.accessibilityLabel("Park " + lot.name).help("Park this Parking Lot")
            }.padding(.horizontal, 8).padding(.vertical, 4)
            HStack(spacing: 6) {
                Button(reordering ? "Done" : "Reorder") {
                    let previous = undoFocus.view?.window?.firstResponder
                    reordering.toggle()
                    DispatchQueue.main.async { undoFocus.activate(ifUnchangedFrom: previous) }
                }.controlSize(.small).disabled(lot.isReadOnly).fixedSize()
                if !lot.isReadOnly {
                    ViewThatFits(in: .horizontal) {
                        foldButtons(folding, compact: false)
                        foldButtons(folding, compact: true)
                    }
                    if folding.hiddenCount > 0 {
                        Text("\(folding.hiddenCount) hidden").font(.caption).foregroundStyle(.secondary)
                            .fixedSize()
                            .help("Items hidden inside collapsed headings or branches.")
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    if !lot.isReadOnly {
                        Button("Collapse All") { collapsed = folding.targets }.disabled(!folding.canCollapseAll)
                        Button("Expand All") { collapsed = [] }.disabled(folding.collapsedCount == 0)
                        Divider()
                    }
                    Button("Import…") { ParkingLotTransfer.importConversations() }
                        .help("Review a Converse file and import it as new conversations and Parking Lots.")
                    Button("Export Parking Lot…") { ParkingLotTransfer.export(lot) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Parking Lot actions")
            }.controlSize(.small).padding(.horizontal, 8)
            Divider()
            if reordering { Text("Drag the handles to reorder headings and items. Drag sideways to change an item's level.").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            if !lot.error.isEmpty { Text(lot.error).foregroundStyle(.red).padding(.horizontal).textSelection(.enabled) }
            else if !lot.notice.isEmpty { Text(lot.notice).foregroundStyle(.secondary).padding(.horizontal).textSelection(.enabled) }
            if let reason = lot.readOnlyReason {
                Text(reason).font(.callout).padding(.horizontal).textSelection(.enabled)
                HStack {
                    Button("Export recovery copy…", action: exportRecovery)
                    Button("Show saved file") { lot.showSavedFile() }
                }.padding(.horizontal)
                ParkingLotReadOnlyText(text: ParkingLotStore.markdown(lot.document.rows))
            } else if !reordering {
                if finder.visible { ParkingLotFindBar(finder: finder); Divider() }
                ParkingLotEditor(lot: lot, collapsed: $collapsed, reorder: { reordering = true }, finder: finder)
                    .overlay(alignment: .bottomTrailing) { SubstitutionButton(feedback: lot.substitutionFeedback).padding(12) }
            } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleRows) { row in
                        rowView(row)
                    }
                    Text(reordering ? "Drop here to move to the end" : "").frame(maxWidth: .infinity, minHeight: 40)
                        .overlay(alignment: .top) { dropIndicator(before: nil) }
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
            .onAppear { lot.beginViewing(viewerID) }
            .onDisappear { lot.endViewing(viewerID) }
            .background(ParkingLotUndoAnchor(lot: lot, focus: undoFocus).frame(width: 0, height: 0))
            .sheet(isPresented: $talking) { ParkingLotTalkView(lot: lot) }
    }
}
/// Read-only recovery view: native selection and Find, with nothing to replace.
struct ParkingLotReadOnlyText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false; view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.textContainerInset = NSSize(width: 12, height: 8); view.font = .systemFont(ofSize: 13)
        view.setAccessibilityLabel("Parking Lot text")
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? NSTextView, view.string != text { view.string = text }
    }
}
private struct ParkingLotFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

func parkingLotSelfTests(_ check: (Bool, String) -> Void) {
    parkingLotTagSelfTests(check)
    parkingLotPolishSelfTests(check)
    check((1...3).map { ParkingLotTree.label($0, depth: 1) } == ["1", "2", "3"] && (1...3).map { ParkingLotTree.label($0, depth: 2) } == ["a", "b", "c"]
          && [1, 2, 3, 4, 9, 14].map { ParkingLotTree.label($0, depth: 3) } == ["i", "ii", "iii", "iv", "ix", "xiv"] && ParkingLotTree.label(2, depth: 4) == "2"
          && ParkingLotTree.letters(27) == "aa" && ParkingLotTree.letters(26) == "z", "Outline labels go 1, a, i by level, then repeat")
    parkingOutlineSelfTests(check)
    parkingLinkEditorSelfTests(check)
    parkingUserUndoSelfTests(check)
    parkingLotTypingSelfTests(check)
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

private func parkingLotPolishSelfTests(_ check: (Bool, String) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lot-polish-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lot = ParkingLotStore(folder: folder)
    let h = ParkingLotRow(heading: true, text: "Heading")
    let a = ParkingLotRow(heading: false, text: "Anchor", parentID: h.id)
    let b = ParkingLotRow(heading: false, text: "First 🦊", parentID: h.id)
    let child = ParkingLotRow(heading: false, text: "Hidden child", notes: [ParkingLotNote(author: "Tester", text: "Keep")], parentID: b.id)
    let c = ParkingLotRow(heading: false, text: "Second", done: true, parentID: h.id)
    lot.openStarter([h, a, b, child, c])
    let before = lot.document.rows
    check(lot.changeIndent([b.id, child.id, c.id], deeper: true)
          && lot.document.rows.first { $0.id == b.id }?.parentID == a.id
          && lot.document.rows.first { $0.id == c.id }?.parentID == a.id
          && lot.document.rows.first { $0.id == child.id } == child,
          "Batch indent keeps selected siblings together and carries selected descendants once")
    lot.undoManager.undo()
    check(lot.document.rows == before, "One Undo restores the entire multi-item indentation")
    lot.undoManager.redo()
    check(lot.changeIndent([b.id, c.id], deeper: false) && lot.document.rows == before,
          "Batch outdent preserves sibling order, comments, Done and descendant identities")
    let revision = lot.document.revision
    let deepest = (1...7).reduce(into: [a]) { rows, n in rows.append(ParkingLotRow(heading: false, text: "d\(n)", parentID: rows.last!.id)) }
    let capLot = ParkingLotStore(folder: folder.appendingPathComponent("cap")); capLot.openStarter([h] + deepest + [c])
    let capBefore = capLot.document
    check(!capLot.changeIndent([deepest[7].id, c.id], deeper: true) && capLot.document == capBefore,
          "A batch with an item already at the depth cap is refused atomically instead of indenting only some items")
    check(lot.document.revision == revision && lot.document.rows == before, "Refusing a batch elsewhere leaves this lot unchanged")
    check(!lot.changeIndent([h.id, b.id], deeper: true), "A selection containing a heading cannot accidentally nest the heading")
    // Richard's lot: 17 > a > i…vii. Shift-Tab on i keeps every row in place.
    let oh = ParkingLotRow(heading: true, text: "Lot"), o17 = ParkingLotRow(heading: false, text: "17", parentID: oh.id)
    let oa = ParkingLotRow(heading: false, text: "a", parentID: o17.id)
    let romans = (1...7).map { ParkingLotRow(heading: false, text: ParkingLotTree.roman($0), parentID: oa.id) }
    let outline = [oh, o17, oa] + romans
    func lines(_ rows: [ParkingLotRow]?) -> [String] { rows.map { ParkingLotStore.markdown($0).components(separatedBy: "\n") } ?? [] }
    func outdent(_ ids: Set<UUID>, _ rows: [ParkingLotRow]? = nil) -> [ParkingLotRow]? { ParkingLotTree.changingIndent(ids, in: rows ?? outline, deeper: false) }
    let head = ["# Lot", "1. 17"]
    let first = outdent([romans[0].id])
    check(lines(first) == head + ["  a. a", "  b. i"] + (2...7).map { "    " + ParkingLotTree.roman($0 - 1) + ". " + ParkingLotTree.roman($0) }
          && first?.map(\.id) == outline.map(\.id),
          "Outdenting the first child keeps it in place and adopts its following siblings, renumbered")
    check(lines(outdent([romans[2].id])) == head + ["  a. a", "    i. i", "    ii. ii", "  b. iii"] + (4...7).map { "    " + ParkingLotTree.roman($0 - 3) + ". " + ParkingLotTree.roman($0) },
          "Outdenting a middle child leaves earlier siblings under their parent")
    check(lines(outdent([romans[6].id])) == head + ["  a. a"] + (1...6).map { "    " + ParkingLotTree.roman($0) + ". " + ParkingLotTree.roman($0) } + ["  b. vii"],
          "Outdenting the last child adopts nothing")
    check(lines(outdent([romans[1].id, romans[2].id])) == head + ["  a. a", "    i. i", "  b. ii", "  c. iii"] + (4...7).map { "    " + ParkingLotTree.roman($0 - 3) + ". " + ParkingLotTree.roman($0) },
          "Outdenting selected siblings keeps them siblings; the last one adopts the rest")
    let own = ParkingLotRow(heading: false, text: "own", parentID: romans[0].id)
    let withOwn = [oh, o17, oa, romans[0], own] + romans.dropFirst()
    check(lines(outdent([romans[0].id], withOwn)) == head + ["  a. a", "  b. i", "    i. own"] + (2...7).map { "    " + ParkingLotTree.roman($0) + ". " + ParkingLotTree.roman($0) },
          "An outdented item's own children stay first, before its adopted siblings")
    let undoLot = ParkingLotStore(folder: folder.appendingPathComponent("outdent")); undoLot.openStarter(outline)
    let original = undoLot.document.rows
    check(undoLot.changeIndent(romans[0].id, deeper: false) && lines(undoLot.document.rows) == lines(first), "Shift-Tab in the lot applies the outliner outdent")
    undoLot.undoManager.undo()
    check(undoLot.document.rows == original, "One Undo restores the rows exactly as they were before the outdent")
    // Reorder: a drop takes the level of the row before it, or deeper/shallower
    // by dragging sideways, so an item can move into any parent's list.
    let o18 = ParkingLotRow(heading: false, text: "18", parentID: oh.id), next = ParkingLotRow(heading: true, text: "Next")
    let field = [oh, o17, oa, romans[0], romans[1], o18, next]
    func depth(_ id: UUID, _ rows: [ParkingLotRow]?) -> Int { rows.map { ParkingLotTree.depth(of: id, in: $0) } ?? -1 }
    func parent(_ id: UUID, _ rows: [ParkingLotRow]?) -> UUID? { (rows.flatMap { try? ParkingLotTree.nodes($0) })?[id]?.parentID }
    let between = ParkingLotTree.moving(o18.id, before: romans[1].id, in: field)
    check(parent(o18.id, between) == oa.id && between?.map(\.text) == ["Lot", "17", "a", "i", "18", "ii", "Next"],
          "Dropping between a's children makes the item one of a's children")
    var later = o18; later.parentID = next.id
    let atEnd = ParkingLotTree.moving(o18.id, before: next.id, in: [oh, o17, oa, romans[0], romans[1], next, later])
    check(parent(o18.id, atEnd) == oa.id && atEnd?.map(\.text) == ["Lot", "17", "a", "i", "ii", "18", "Next"],
          "Dropping after the last child appends to that child list at the row before's level")
    check(parent(o18.id, ParkingLotTree.moving(o18.id, before: next.id, depth: 2, in: field)) == o17.id
          && parent(o18.id, ParkingLotTree.moving(o18.id, before: next.id, depth: 1, in: field)) == oh.id,
          "Dragging left at the end of a nested list moves out to each enclosing level")
    check(parent(romans[1].id, ParkingLotTree.moving(romans[1].id, before: romans[1].id, depth: 4, in: field)) == romans[0].id,
          "Dragging an item right in place nests it under a childless row before it")
    check(parent(romans[1].id, ParkingLotTree.moving(romans[1].id, before: romans[1].id, depth: 9, in: field)) == romans[0].id
          && parent(romans[1].id, ParkingLotTree.moving(romans[1].id, before: o18.id, depth: 0, in: field)) == oh.id,
          "Drop levels clamp between the next row's level and one below the row before")
    check(depth(oa.id, ParkingLotTree.moving(oa.id, before: romans[0].id, in: field)) == -1
          && ParkingLotTree.moving(next.id, before: romans[1].id, in: field) == nil
          && depth(next.id, ParkingLotTree.moving(next.id, before: oh.id, depth: 5, in: field)) == 0,
          "A parent cannot drop inside itself, and headings move only between sections at the top level")
    let chain = (1...8).reduce(into: [oh]) { rows, n in rows.append(ParkingLotRow(heading: false, text: "d\(n)", parentID: n == 1 ? oh.id : rows.last!.id)) }
    let p = ParkingLotRow(heading: false, text: "p", parentID: oh.id), q = ParkingLotRow(heading: false, text: "q", parentID: p.id)
    let capped = ParkingLotTree.moving(p.id, before: nil, depth: 9, in: chain + [p, q])
    check(depth(p.id, capped) == 7 && depth(q.id, capped) == ParkingLotTree.maximumDepth, "A dropped subtree never nests deeper than eight levels")
    let moveLot = ParkingLotStore(folder: folder.appendingPathComponent("drop")); moveLot.openStarter(field)
    let unmoved = moveLot.document.rows
    check(moveLot.move(o18.id, before: romans[1].id) && parent(o18.id, moveLot.document.rows) == oa.id, "Reorder moves an item into another parent's list")
    moveLot.undoManager.undo()
    check(moveLot.document.rows == unmoved, "One Undo restores the rows before the reorder")
    let viewer = UUID(), otherViewer = UUID()
    lot.beginViewing(viewer)
    check(!lot.hasUnseenChanges, "Opening a lot clears its unseen-change marker")
    lot.update(b.id, text: "Visible change")
    check(!lot.hasUnseenChanges, "Edits received while a lot is displayed do not raise an unseen marker")
    lot.beginViewing(otherViewer); lot.endViewing(viewer)
    lot.update(b.id, text: "Still visible")
    check(!lot.hasUnseenChanges, "A view handoff retains visibility while another lot view exists")
    lot.endViewing(otherViewer); lot.update(b.id, text: "Parked change")
    check(lot.hasUnseenChanges && ParkingLotStore(folder: folder).hasUnseenChanges,
          "Parked changes raise an eyeball that survives restarting the app")
    lot.beginViewing(viewer)
    check(!ParkingLotStore(folder: folder).hasUnseenChanges, "Reading the changed lot persists the cleared marker")
}

/// Voice controls and the last stop/failure stay in the lot's own pane because
/// the idle Talk helper is hidden from the sidebar.
struct ParkingLotTalkBar: View {
    let lot: ParkingLotStore
    @ObservedObject private var chrome: ParkingLotChrome
    @ObservedObject var conversation = AgentConversation.shared
    @ObservedObject var store = Store.shared
    init(lot: ParkingLotStore) { self.lot = lot; _chrome = ObservedObject(wrappedValue: lot.chrome) }
    static func talkSession(for lot: UUID, sessionID: UUID?, sessions: [Session]) -> Session? {
        guard let sessionID else { return nil }
        return sessions.first { $0.id == sessionID && $0.agent?.parkingLotTalkID == lot }
    }
    var body: some View {
        if conversation.statusPresented, let session = Self.talkSession(for: lot.id, sessionID: conversation.sessionID, sessions: store.sessions) {
            HStack(spacing: 8) {
                Image(systemName: !conversation.active ? "mic.slash" : conversation.phase == .listening ? "mic.fill" : "speaker.wave.2.fill").foregroundStyle(.orange)
                Text(conversation.status.isEmpty ? "Talking about \u{201C}" + lot.name + "\u{201D}" : conversation.status)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .help(conversation.lastHeard.isEmpty ? conversation.status : "Heard: " + conversation.lastHeard)
                Spacer(minLength: 0)
                if conversation.active {
                    Button("Stop talking") { conversation.stop() }
                        .keyboardShortcut(.escape, modifiers: [])
                        .accessibilityLabel("Stop talking about " + lot.name)
                        .help("End the voice conversation and turn the microphone off. " + session.title + " keeps its transcript.")
                } else {
                    Button("Retry") { conversation.start(session, store: store) }.disabled(lot.isReadOnly)
                    Button("Dismiss") { conversation.dismissStatus() }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.orange.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
