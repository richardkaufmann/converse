import AppKit
import SwiftUI

// Paragraphs are outline entries; soft line breaks stay within an entry. The
// projection is ephemeral: displaying an empty input never writes to the file.
struct ParkingOutline {
    struct Entry {
        var row: ParkingLotRow
        var range: NSRange
        var before: UUID?
        var placeholder: Bool
        var number: Int
    }
    var entries: [Entry] = []
    var string = ""
    init(rows: [ParkingLotRow], collapsed: Set<UUID>, placeholders: inout [String: UUID]) {
        var projected: [(ParkingLotRow, UUID?, Bool, Int)] = []
        var section = "root", hidden = false, count = 0, lastEmpty = false
        func empty(_ heading: Bool, before: UUID?) {
            let key = heading ? "heading" : section
            let cached = placeholders[key]
            let id = cached.flatMap { id in rows.contains(where: { $0.id == id }) ? nil : id } ?? UUID()
            placeholders[key] = id
            projected.append((ParkingLotRow(id: id, heading: heading, text: ""), before, true, count + 1))
        }
        for row in rows {
            if row.heading {
                if !hidden && !lastEmpty && !projected.isEmpty { empty(false, before: row.id) }
                section = row.id.uuidString; hidden = collapsed.contains(row.id); count = 0; lastEmpty = false
                projected.append((row, nil, false, 0))
            } else if !hidden {
                count += 1; projected.append((row, nil, false, count)); lastEmpty = row.text.isEmpty
            }
        }
        if !hidden && !lastEmpty && !projected.isEmpty { empty(false, before: nil) }
        for (row, before, placeholder, number) in projected {
            if !entries.isEmpty { string += "\n" }
            let text = row.text.replacingOccurrences(of: "\n", with: "\u{2028}")
            let range = NSRange(location: (string as NSString).length, length: (text as NSString).length)
            entries.append(Entry(row: row, range: range, before: before, placeholder: placeholder, number: number))
            string += text
        }
    }
    func index(at offset: Int) -> Int? { entries.lastIndex { $0.range.location <= offset } }
    struct Edit {
        var rows: [ParkingLotRow]
        var caretID: UUID
        var caretOffset: Int
    }
    func replacing(_ range: NSRange, with replacement: String, rows: [ParkingLotRow]) -> Edit? {
        guard range.location != NSNotFound, NSMaxRange(range) <= (string as NSString).length,
              let start = index(at: range.location), let end = index(at: NSMaxRange(range)) else { return nil }
        let first = entries[start], last = entries[end]
        let firstText = first.row.text as NSString, lastText = last.row.text as NSString
        let firstOffset = min(range.location - first.range.location, firstText.length)
        let lastOffset = min(NSMaxRange(range) - last.range.location, lastText.length)
        let prefix = firstText.substring(to: firstOffset).replacingOccurrences(of: "\n", with: "\u{2028}")
        let suffix = lastText.substring(from: lastOffset).replacingOccurrences(of: "\n", with: "\u{2028}")
        let insertion = replacement.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let pieces = (prefix + insertion + suffix).components(separatedBy: "\n")
        let removed = Set(entries[start...end].filter { !$0.placeholder }.map { $0.row.id })
        let initialIndex = rows.firstIndex { $0.id == first.row.id } ?? first.before.flatMap { id in rows.firstIndex { $0.id == id } } ?? rows.count
        var result = rows.filter { !removed.contains($0.id) }
        let destination = rows.prefix(initialIndex).filter { !removed.contains($0.id) }.count
        // Cutting entire paragraphs up to the next row preserves that next row's identity/type.
        let base = prefix.isEmpty && insertion.isEmpty && start != end && lastOffset == 0 ? last.row : first.row
        var newRows: [ParkingLotRow] = []
        let preserveSuffix = range.length == 0 && prefix.isEmpty && insertion.hasSuffix("\n") && !suffix.isEmpty
        for (i, piece) in pieces.enumerated() {
            var row = preserveSuffix ? (i == pieces.count - 1 ? first.row : ParkingLotRow(heading: false, text: "")) : (i == 0 ? base : ParkingLotRow(heading: false, text: ""))
            row.text = piece.replacingOccurrences(of: "\u{2028}", with: "\n"); row.editedBy = nil
            // Plain text round trips through Markdown, keeping pasted headings and lists.
            if insertion.contains("\n") && (i > 0 || prefix.isEmpty) {
                if row.text.hasPrefix("# ") { row.heading = true; row.text = String(row.text.dropFirst(2)) }
                else if let match = row.text.range(of: "^(?:[0-9]+[.] |[-*] )", options: .regularExpression) {
                    row.heading = false; row.text.removeSubrange(match)
                }
            }
            newRows.append(row)
        }
        let caretLine = (prefix + insertion).components(separatedBy: "\n").count - 1
        let rawCaret = (prefix + insertion).components(separatedBy: "\n").last! as NSString
        let caret = min(rawCaret.length, (newRows[caretLine].text as NSString).length)
        result.insert(contentsOf: newRows, at: min(destination, result.count))
        return Edit(rows: result, caretID: newRows[caretLine].id, caretOffset: caret)
    }
    func markdown(_ selection: NSRange) -> String {
        guard let start = index(at: selection.location), let end = index(at: NSMaxRange(selection)) else { return "" }
        if start == end { return (string as NSString).substring(with: selection).replacingOccurrences(of: "\u{2028}", with: "\n") }
        return entries[start...end].compactMap { entry -> String? in
            let overlap = NSIntersectionRange(selection, entry.range)
            guard overlap.length > 0 else { return nil }
            let text = (string as NSString).substring(with: overlap).replacingOccurrences(of: "\u{2028}", with: "\n")
            return (overlap.location == entry.range.location ? (entry.row.heading ? "# " : "\(entry.number). ") : "") + text
        }.joined(separator: "\n")
    }
}

struct ParkingLotEditor: NSViewRepresentable {
    @ObservedObject var lot: ParkingLotStore
    @Binding var collapsed: Set<UUID>
    var reorder: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = true
        let text = ParkingOutlineText(frame: .zero)
        text.isRichText = false; text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainerInset = NSSize(width: 36, height: 8)
        text.textContainer?.widthTracksTextView = true; text.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        text.minSize = NSSize(width: 0, height: 0); text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.delegate = context.coordinator; text.owner = context.coordinator
        text.setAccessibilityLabel("Parking Lot outline")
        scroll.documentView = text; context.coordinator.text = text; context.coordinator.render()
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ParkingLotEditor
        weak var text: ParkingOutlineText?
        var placeholders: [String: UUID] = [:]
        var projection = ParkingOutline(rows: [], collapsed: [], placeholders: &emptyPlaceholders)
        var displayed: ParkingLotDocument?
        var displayedCollapsed: Set<UUID> = []
        var rendering = false
        init(_ parent: ParkingLotEditor) { self.parent = parent }
        func render(caret: (UUID, Int)? = nil) {
            guard let text, caret != nil || displayed != parent.lot.document || displayedCollapsed != parent.collapsed else { return }
            let oldSelection = text.selectedRange()
            let oldAnchor = projection.index(at: oldSelection.location).map { (projection.entries[$0].row.id, oldSelection.location - projection.entries[$0].range.location) }
            rendering = true; defer { rendering = false }
            displayed = parent.lot.document; displayedCollapsed = parent.collapsed
            projection = ParkingOutline(rows: parent.lot.document.rows, collapsed: parent.collapsed, placeholders: &placeholders)
            let body = NSMutableAttributedString(string: projection.string)
            let standard = NSMutableParagraphStyle(); standard.paragraphSpacing = 5
            body.addAttributes([.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor, .paragraphStyle: standard], range: NSRange(location: 0, length: body.length))
            for entry in projection.entries where entry.row.heading {
                let style = standard.mutableCopy() as! NSMutableParagraphStyle; style.paragraphSpacingBefore = 7
                if entry.range.length > 0 { body.addAttributes([.font: NSFont.boldSystemFont(ofSize: 13), .paragraphStyle: style], range: entry.range) }
            }
            text.textStorage?.setAttributedString(body)
            text.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor, .paragraphStyle: standard]
            let anchor = caret ?? oldAnchor
            if let anchor, let entry = projection.entries.first(where: { $0.row.id == anchor.0 }) {
                text.setSelectedRange(NSRange(location: entry.range.location + min(anchor.1, entry.range.length), length: caret == nil ? min(oldSelection.length, max(0, body.length - entry.range.location - min(anchor.1, entry.range.length))) : 0))
            } else { text.setSelectedRange(NSRange(location: min(oldSelection.location, body.length), length: 0)) }
            text.needsDisplay = true
            if caret != nil { text.scrollRangeToVisible(text.selectedRange()) }
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard !rendering, let replacementString, let displayed,
                  let edit = projection.replacing(affectedCharRange, with: replacementString, rows: displayed.rows) else { return false }
            if replacementString.contains("\n"), let index = projection.index(at: affectedCharRange.location) {
                parent.collapsed.remove(projection.entries[index].row.id)
            }
            save(edit.rows, expected: displayed, caret: (edit.caretID, edit.caretOffset)); return false
        }
        func save(_ rows: [ParkingLotRow], expected: ParkingLotDocument, caret: (UUID, Int)? = nil) {
            do {
                try parent.lot.replaceUserRows(rows, revision: expected.revision)
                if rows != expected.rows {
                    text?.undoManager?.registerUndo(withTarget: self) { owner in owner.restore(expected.rows, replacing: rows) }
                    text?.undoManager?.setActionName("Edit Parking Lot")
                }
                render(caret: caret)
            } catch { parent.lot.error = error.localizedDescription; render() }
        }
        func restore(_ rows: [ParkingLotRow], replacing expected: [ParkingLotRow]) {
            guard parent.lot.document.rows == expected else { parent.lot.error = "Parking Lot changed since that edit. Undo was skipped to preserve newer changes."; return }
            save(rows, expected: parent.lot.document)
        }
        func select(_ id: UUID) {
            guard let text, let entry = projection.entries.first(where: { $0.row.id == id }) else { return }
            text.window?.makeFirstResponder(text); text.setSelectedRange(entry.range); text.scrollRangeToVisible(entry.range)
        }
        func add(heading: Bool, after entry: ParkingOutline.Entry? = nil) {
            let document = parent.lot.document
            let index: Int
            if let entry {
                if entry.placeholder { index = entry.before.flatMap { id in document.rows.firstIndex { $0.id == id } } ?? document.rows.count }
                else { index = document.rows.firstIndex { $0.id == entry.row.id }.map { $0 + 1 } ?? document.rows.count }
                parent.collapsed.remove(entry.row.id)
            } else { index = document.rows.count }
            let row = ParkingLotRow(heading: heading, text: "")
            var rows = document.rows; rows.insert(row, at: index)
            save(rows, expected: document, caret: (row.id, 0)); text?.window?.makeFirstResponder(text)
        }
        func toggle(_ id: UUID) {
            if !parent.collapsed.insert(id).inserted { parent.collapsed.remove(id) }
            render()
        }
    }
}
private var emptyPlaceholders: [String: UUID] = [:]

final class ParkingOutlineText: NSTextView {
    weak var owner: ParkingLotEditor.Coordinator?
    private let outlineUndo = UndoManager()
    override var undoManager: UndoManager? { outlineUndo }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            insertText(event.modifierFlags.contains(.command) ? "\u{2028}" : "\n", replacementRange: selectedRange()); return
        }
        super.keyDown(with: event)
    }
    override func copy(_ sender: Any?) {
        guard let owner, selectedRange().length > 0 else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(owner.projection.markdown(selectedRange()), forType: .string)
    }
    override func cut(_ sender: Any?) { guard selectedRange().length > 0 else { return }; copy(sender); insertText("", replacementRange: selectedRange()) }
    override func paste(_ sender: Any?) { if let value = NSPasteboard.general.string(forType: .string) { insertText(value, replacementRange: selectedRange()) } }
    func rowRect(_ entry: ParkingOutline.Entry) -> NSRect {
        guard let manager = layoutManager, let container = textContainer else { return .zero }
        manager.ensureLayout(for: container)
        if entry.range.location >= (string as NSString).length {
            let rect = manager.extraLineFragmentRect
            return NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y + rect.minY, width: rect.width, height: max(16, rect.height))
        }
        let glyph = manager.glyphIndexForCharacter(at: entry.range.location)
        return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }
    override func draw(_ dirtyRect: NSRect) {
        // NSTextView narrows the graphics clip while drawing its text container.
        // Restore it before drawing the outline gutter outside that container.
        NSGraphicsContext.saveGraphicsState()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        guard let owner else { return }
        if owner.projection.entries.isEmpty {
            ("Right-click to create a heading" as NSString).draw(at: NSPoint(x: 36, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor])
        }
        for entry in owner.projection.entries {
            let rect = rowRect(entry)
            guard rect.intersects(dirtyRect) else { continue }
            let marker = entry.row.heading ? (owner.parent.collapsed.contains(entry.row.id) ? "›" : "⌄") : "\(entry.number)."
            (marker as NSString).draw(at: NSPoint(x: 12, y: rect.minY), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
            if entry.row.text.isEmpty {
                ((entry.row.heading ? "Heading" : "New item…") as NSString).draw(at: NSPoint(x: rect.minX + 5, y: rect.minY), withAttributes: [.font: entry.row.heading ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor])
            }
            if let notes = entry.row.notes, !notes.isEmpty {
                ("💬\(notes.count)" as NSString).draw(at: NSPoint(x: max(rect.minX, bounds.width - 34), y: rect.minY), withAttributes: [.font: NSFont.systemFont(ofSize: 10)])
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x < 32, let entry = owner?.projection.entries.first(where: { $0.row.heading && rowRect($0).minY <= point.y && rowRect($0).maxY >= point.y }), !entry.placeholder {
            owner?.toggle(entry.row.id); return
        }
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let menu = NSMenu()
        func item(_ title: String, _ action: @escaping () -> Void) {
            let target = ParkingMenuAction(action); let item = NSMenuItem(title: title, action: #selector(ParkingMenuAction.run), keyEquivalent: "")
            item.target = target; item.representedObject = target; menu.addItem(item)
        }
        guard let i = owner.projection.index(at: index) else {
            item("New heading") { owner.add(heading: true) }
            return menu
        }
        let entry = owner.projection.entries[i]
        if selectedRange().length == 0 || !NSLocationInRange(index, selectedRange()) { setSelectedRange(NSRange(location: index, length: 0)) }
        if entry.row.heading { item("Rename heading") { owner.select(entry.row.id) } }
        item("New heading below") { owner.add(heading: true, after: entry) }
        item("New item below") { owner.add(heading: false, after: entry) }
        menu.addItem(.separator())
        item("Copy") { if self.selectedRange().length == 0 { owner.select(entry.row.id) }; self.copy(nil) }
        item("Cut") { if self.selectedRange().length == 0 { owner.select(entry.row.id) }; self.cut(nil) }
        item("Paste") { self.paste(nil) }
        item("Reorder") { owner.parent.reorder() }
        if let notes = entry.row.notes, !notes.isEmpty {
            item("Comments (\(notes.count))…") {
                let alert = NSAlert(); alert.messageText = "Comments"
                alert.informativeText = notes.map { $0.author + ": " + $0.text }.joined(separator: "\n\n")
                alert.runModal()
            }
        }
        if !entry.placeholder { item(entry.row.heading ? "Delete heading (keep items)" : "Delete") {
            let document = owner.parent.lot.document
            owner.save(document.rows.filter { $0.id != entry.row.id }, expected: document)
        } }
        return menu
    }
}
private final class ParkingMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

func parkingOutlineSelfTests(_ check: (Bool, String) -> Void) {
    let heading = ParkingLotRow(heading: true, text: "Converse")
    let first = ParkingLotRow(heading: false, text: "Fix scrolling", notes: [.init(author: "Reviewer", text: "Keep this comment")])
    let second = ParkingLotRow(heading: false, text: "Improve pairing")
    let other = ParkingLotRow(heading: true, text: "KAOS")
    let hidden = ParkingLotRow(heading: false, text: "Do not lose this")
    let rows = [heading, first, second, other, hidden]
    var placeholders: [String: UUID] = [:]
    let outline = ParkingOutline(rows: rows, collapsed: [], placeholders: &placeholders)
    check(outline.entries.filter(\.placeholder).count == 2 && outline.entries.filter(\.placeholder).allSatisfy { !$0.row.heading }, "Outline provides one ready item per section; new headings require right-click")
    let again = ParkingOutline(rows: rows, collapsed: [], placeholders: &placeholders)
    check(outline.entries.map { $0.row.id } == again.entries.map { $0.row.id }, "Empty outline inputs retain stable identity without being saved")
    let afterHeading = outline.replacing(NSRange(location: heading.text.utf16.count, length: 0), with: "\n", rows: rows)!
    check(afterHeading.rows[0] == heading && !afterHeading.rows[1].heading && afterHeading.rows[1].text.isEmpty && afterHeading.rows[2] == first, "Return at the end of a heading inserts an item immediately below")
    let firstRange = outline.entries.first { $0.row.id == first.id }!.range
    let afterItem = outline.replacing(NSRange(location: NSMaxRange(firstRange), length: 0), with: "\n", rows: rows)!
    check(afterItem.rows[1] == first && !afterItem.rows[2].heading && afterItem.caretID == afterItem.rows[2].id, "Return after an item creates a new item and places its caret there")
    let soft = outline.replacing(NSRange(location: NSMaxRange(firstRange), length: 0), with: "\u{2028}Details", rows: rows)!
    check(soft.rows.count == rows.count && soft.rows[1].text == "Fix scrolling\nDetails" && soft.rows[1].notes == first.notes, "Command-Return inserts a line within the entry and preserves comments")
    let placeholder = outline.entries.first { $0.placeholder }!
    let typed = outline.replacing(placeholder.range, with: "Another feature", rows: rows)!
    let projected = ParkingOutline(rows: typed.rows, collapsed: [], placeholders: &placeholders)
    check(typed.rows[3].text == "Another feature" && projected.entries.filter(\.placeholder).count == 2 && Set(projected.entries.map { $0.row.id }).count == projected.entries.count, "Typing in the ready item saves it in its section and provides another empty item")
    let headingRange = outline.entries.first { $0.row.id == other.id }!.range
    let cutRange = NSRange(location: firstRange.location, length: headingRange.location - firstRange.location)
    let cut = outline.replacing(cutRange, with: "", rows: rows)!
    check(cut.rows.map(\.id) == [heading.id, other.id, hidden.id] && cut.rows[1].heading, "Cut across multiple entries preserves the next heading and its identity")
    let copied = outline.markdown(NSRange(location: 0, length: headingRange.location))
    check(copied == "# Converse\n1. Fix scrolling\n2. Improve pairing", "Cross-row copy exports useful heading and numbered-list text without empty placeholders")
    let pasted = outline.replacing(NSRange(location: headingRange.location, length: 0), with: "# New section\n1. New idea\n", rows: rows)!
    check(pasted.rows[3].heading && pasted.rows[3].text == "New section" && !pasted.rows[4].heading && pasted.rows[4].text == "New idea", "Multiline paste recognizes headings and numbered items")
    check(pasted.rows[5] == other, "Pasting complete rows before a heading preserves its type and identity")
    let folded = ParkingOutline(rows: rows, collapsed: [other.id], placeholders: &placeholders)
    let editFolded = folded.replacing(NSRange(location: 0, length: heading.text.utf16.count), with: "App", rows: rows)!
    check(editFolded.rows.contains(hidden) && !folded.entries.contains { $0.row.id == hidden.id }, "Editing visible outline text preserves collapsed entries")
    let emoji = ParkingLotRow(heading: false, text: "🦊 hello")
    let unicode = ParkingOutline(rows: [emoji], collapsed: [], placeholders: &placeholders)
    let emojiEdit = unicode.replacing(NSRange(location: 3, length: 5), with: "world", rows: [emoji])!
    check(emojiEdit.rows[0].text == "🦊 world", "Outline editing uses native UTF-16 selection offsets")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("outline-editor-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lot = ParkingLotStore(folder: folder); lot.open()
    let view = ParkingLotEditor(lot: lot, collapsed: .constant([]), reorder: {})
    let coordinator = ParkingLotEditor.Coordinator(view)
    let text = ParkingOutlineText(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    text.isRichText = false; text.owner = coordinator; text.delegate = coordinator; coordinator.text = text; coordinator.render()
    let original = lot.document
    text.setSelectedRange(NSRange(location: 0, length: 3))
    text.insertText("Fresh", replacementRange: text.selectedRange())
    check(lot.document.rows[0].text == "Fresh features", "Native text edits update the persisted outline")
    text.undoManager?.undo()
    check(lot.document.rows == original.rows, "Native Undo restores a multi-row-capable outline transaction")
    text.undoManager?.redo()
    check(lot.document.rows[0].text == "Fresh features", "Native Redo restores the edited outline")
    lot.update(lot.document.rows[0].id, text: "Another writer")
    text.undoManager?.undo()
    check(lot.document.rows[0].text == "Another writer", "Undo cannot overwrite changes made by another writer")
    lot.error = ""
    lot.update(lot.document.rows[1].id, text: "Existing item"); coordinator.render()
    let ready = coordinator.projection.entries.first { $0.placeholder }!
    let nextHeading = ready.before!
    coordinator.add(heading: true, after: ready)
    let position = lot.document.rows.firstIndex { $0.id == nextHeading }!
    check(lot.document.rows[position - 1].heading && lot.document.rows[position - 1].text.isEmpty, "Right-click creation at a ready input inserts at that section, not at the end of the document")
    let entry = Entry(name: "Parking reader", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")
    let session = Session(entry: entry); session.switchboardEnabled = true
    let read = SwitchboardCommand(command: "parking-lot-read")
    let store = Store.shared
    check(store.parkingLotCommand(read, session: session, lot: lot).contains("Another writer"), "An ordinary taught session can read Parking Lot without an agent scope setting")
    session.supportAutonomous = true
    check(store.parkingLotCommand(read, session: session, lot: lot).contains("Nothing was read"), "An autonomous session message cannot bypass agent Parking Lot scope")
    session.supportAutonomous = false
    var command = SwitchboardCommand(command: "parking-lot-edit")
    let id = lot.document.rows[0].id
    command.parkingLotEdits = ParkingLotEdits(revision: lot.document.revision, operations: [.init(action: "update", id: id, text: "Approved heading")])
    var reviewed = ""
    let denied = store.parkingLotCommand(command, session: session, lot: lot, confirm: { reviewed = $0; return false })
    check(denied.contains("declined") && reviewed.contains("Another writer") && reviewed.contains("Approved heading") && lot.document.rows[0].text == "Another writer", "Session edits present the exact old and new text and cancellation saves nothing")
    let approved = store.parkingLotCommand(command, session: session, lot: lot, confirm: { _ in true })
    check(approved.contains("approved and saved") && lot.document.rows[0].text == "Approved heading", "Confirmed session edits save the reviewed transaction")
    command.parkingLotEdits = ParkingLotEdits(revision: lot.document.revision, operations: [.init(action: "update", id: id, text: "Old proposal")])
    let stale = store.parkingLotCommand(command, session: session, lot: lot, confirm: { _ in lot.update(id, text: "While reviewing"); return true })
    check(stale.contains("No changes applied") && lot.document.rows[0].text == "While reviewing", "Review cannot apply a stale proposal over edits made while the confirmation is open")
    let newID = UUID(), target = lot.document.rows.last!.id
    do {
        try lot.apply(.init(revision: lot.document.revision, operations: [.init(action: "add", id: newID, text: "Project", heading: true), .init(action: "move", id: target, before: newID)]), author: "Session")
        check(lot.document.rows.suffix(2).map(\.id) == [target, newID], "A session can add an identified heading and refer to it later in the same transaction")
    } catch { check(false, "Outline batch reorganization: " + error.localizedDescription) }
    check(store.switchboardTeaching(session).contains("Converse or KAOS") && store.switchboardTeaching(session).contains("Confirm the proposed reorganization"), "General session teaching includes contextual organization and user confirmation")
}
