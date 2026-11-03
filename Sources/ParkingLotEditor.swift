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
        var section = "root", hidden = false, count = 0
        func empty(_ heading: Bool, before: UUID?) {
            let key = heading ? "heading" : section
            let cached = placeholders[key]
            let id = cached.flatMap { id in rows.contains(where: { $0.id == id }) ? nil : id } ?? UUID()
            placeholders[key] = id
            projected.append((ParkingLotRow(id: id, heading: heading, text: ""), before, true, count + 1))
        }
        for row in rows {
            if row.heading {
                if !hidden && !projected.isEmpty { empty(false, before: row.id) }
                section = row.id.uuidString; hidden = collapsed.contains(row.id); count = 0
                projected.append((row, nil, false, 0))
            } else if !hidden {
                count += 1; projected.append((row, nil, false, count))
            }
        }
        if !hidden && !projected.isEmpty { empty(false, before: nil) }
        empty(true, before: nil)
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
        // Backspace/Delete across the paragraph separator merges entries.
        // Keep attachments from both sides instead of losing the second row's
        // images when its identity is removed.
        if start != end && insertion.isEmpty && range.length == 1 && firstOffset == firstText.length && lastOffset == 0 {
            let images = (first.row.images ?? []) + (last.row.images ?? [])
            if !images.isEmpty { newRows[0].images = images }
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
        text.isRichText = false; text.allowsUndo = true; text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainerInset = NSSize(width: 36, height: 8)
        text.textContainer?.widthTracksTextView = true; text.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        text.minSize = NSSize(width: 0, height: 0); text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.delegate = context.coordinator; text.owner = context.coordinator
        text.setAccessibilityLabel("Parking Lot outline")
        text.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
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
        var displayedWidth: CGFloat = 0
        func render(caret: (UUID, Int)? = nil) {
            guard let text else { return }
            // Image rows reserve space for their drawn height at the current
            // width, so a resize that changes the width must re-render too.
            let width = min(ParkingOutlineText.lotImageWidth, (text.textContainer?.containerSize.width ?? 400) - 10)
            guard caret != nil || displayed != parent.lot.document || displayedCollapsed != parent.collapsed || displayedWidth != width else { return }
            let oldSelection = text.selectedRange()
            let oldAnchor = projection.index(at: oldSelection.location).map { (projection.entries[$0].row.id, oldSelection.location - projection.entries[$0].range.location) }
            rendering = true; defer { rendering = false }
            displayed = parent.lot.document; displayedCollapsed = parent.collapsed; displayedWidth = width
            projection = ParkingOutline(rows: parent.lot.document.rows, collapsed: parent.collapsed, placeholders: &placeholders)
            let body = NSMutableAttributedString(string: projection.string)
            let standard = NSMutableParagraphStyle(); standard.paragraphSpacing = 5
            body.addAttributes([.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor, .paragraphStyle: standard], range: NSRange(location: 0, length: body.length))
            for entry in projection.entries where entry.row.heading {
                let style = standard.mutableCopy() as! NSMutableParagraphStyle; style.paragraphSpacingBefore = 7
                if entry.range.length > 0 { body.addAttributes([.font: NSFont.boldSystemFont(ofSize: 13), .paragraphStyle: style], range: entry.range) }
            }
            for entry in projection.entries where !(entry.row.images ?? []).isEmpty {
                let style = standard.mutableCopy() as! NSMutableParagraphStyle
                let sizes = text.lotImageSizes(entry.row.images!, width: width).compactMap { $0 }
                style.paragraphSpacing = ParkingOutlineText.lotImageSpacing(sizes)
                let length = min(body.length - entry.range.location, max(1, entry.range.length))
                if length > 0 { body.addAttribute(.paragraphStyle, value: style, range: NSRange(location: entry.range.location, length: length)) }
            }
            let anchor = caret ?? oldAnchor
            linkEditing = text.editingFocus ? anchor.flatMap { anchor in projection.entries.first { $0.row.id == anchor.0 }.map { (anchor.0, min(anchor.1, $0.range.length)) } } : nil
            for entry in projection.entries where entry.range.length > 0 {
                body.addAttribute(.foregroundColor, value: ParkingOutlineText.color(for: entry.row), range: entry.range)
                if entry.row.isDone { body.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: entry.range) }
                styleLinks(body, entry)
            }
            text.textStorage?.setAttributedString(body)
            text.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor, .paragraphStyle: standard]
            if let anchor, let entry = projection.entries.first(where: { $0.row.id == anchor.0 }) {
                text.setSelectedRange(NSRange(location: entry.range.location + min(anchor.1, entry.range.length), length: caret == nil ? min(oldSelection.length, max(0, body.length - entry.range.location - min(anchor.1, entry.range.length))) : 0))
            } else { text.setSelectedRange(NSRange(location: min(oldSelection.location, body.length), length: 0)) }
            text.updateCommentButtons()
            text.needsDisplay = true
            if caret != nil { text.scrollRangeToVisible(text.selectedRange()) }
        }
        // The row holding the caret shows raw Markdown, and a link being typed
        // stays plain until a space or other boundary follows it.
        var linkEditing: (UUID, Int)?
        static let hiddenFont = NSFont.systemFont(ofSize: 0.01)
        func styleLinks(_ storage: NSMutableAttributedString, _ entry: ParkingOutline.Entry) {
            let links = LotLinks.find(in: entry.row.text)
            guard !links.isEmpty else { return }
            storage.addAttributes([.font: entry.row.heading ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13),
                                   .foregroundColor: ParkingOutlineText.color(for: entry.row)], range: entry.range)
            storage.removeAttribute(.link, range: entry.range); storage.removeAttribute(.toolTip, range: entry.range)
            let caret = linkEditing.flatMap { $0.0 == entry.row.id ? $0.1 : nil }
            for link in links {
                if let caret, caret >= link.range.location, caret <= LotLinks.tokenEnd(link, in: entry.row.text) { continue }
                let label = NSRange(location: entry.range.location + link.label.location, length: link.label.length)
                storage.addAttributes([.link: link.url, .toolTip: link.isFile ? link.url.path : link.url.absoluteString], range: label)
                guard link.isMarkdown else { continue }
                let opening = NSRange(location: entry.range.location + link.range.location, length: 1)
                let closing = NSRange(location: NSMaxRange(label), length: NSMaxRange(link.range) - link.label.location - link.label.length)
                for syntax in [opening, closing] {
                    storage.addAttributes(caret == nil ? [.font: Self.hiddenFont, .foregroundColor: NSColor.clear] : [.foregroundColor: NSColor.secondaryLabelColor], range: syntax)
                }
            }
        }
        /// Restyle only the rows whose caret state changed; text and selection are untouched.
        func refreshLinks() {
            guard !rendering, let text, let storage = text.textStorage, storage.length == (projection.string as NSString).length else { return }
            let selection = text.selectedRange()
            let anchor = text.editingFocus ? projection.index(at: selection.location).map { (projection.entries[$0].row.id, selection.location - projection.entries[$0].range.location) } : nil
            guard anchor?.0 != linkEditing?.0 || anchor?.1 != linkEditing?.1 else { return }
            let changed = Set([anchor?.0, linkEditing?.0].compactMap { $0 })
            linkEditing = anchor
            storage.beginEditing()
            for entry in projection.entries where changed.contains(entry.row.id) && entry.range.length > 0 { styleLinks(storage, entry) }
            storage.endEditing()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            // A click restyles after mouse tracking ends, so text never shifts under a drag.
            if let type = NSApp.currentEvent?.type, [.leftMouseDown, .leftMouseDragged].contains(type), text?.window != nil { return }
            refreshLinks()
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { ParkingOutlineText.follow(url) }
            return true
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
                else if heading && entry.row.heading { index = ParkingLotStore.entryRange(entry.row.id, in: document.rows)?.upperBound ?? document.rows.count }
                else { index = document.rows.firstIndex { $0.id == entry.row.id }.map { $0 + 1 } ?? document.rows.count }
                parent.collapsed.remove(entry.row.id)
            } else { index = document.rows.count }
            let row = ParkingLotRow(heading: heading, text: "")
            var rows = document.rows; rows.insert(row, at: index)
            save(rows, expected: document, caret: (row.id, 0)); text?.window?.makeFirstResponder(text)
        }
        func copyEntry(_ id: UUID, cut: Bool, board: NSPasteboard = .general) {
            let document = parent.lot.document
            guard let range = ParkingLotStore.entryRange(id, in: document.rows) else { return }
            let rows = Array(document.rows[range])
            board.clearContents()
            board.setString(ParkingLotStore.markdown(rows), forType: .string)
            if let data = try? JSONEncoder().encode(rows) { board.setData(data, forType: ParkingOutlineText.rowsType) }
            if cut { var next = document.rows; next.removeSubrange(range); save(next, expected: document) }
        }
        func toggle(_ id: UUID) {
            if !parent.collapsed.insert(id).inserted { parent.collapsed.remove(id) }
            render()
        }
    }
}
private var emptyPlaceholders: [String: UUID] = [:]

final class ParkingOutlineText: NSTextView {
    static let headingColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.48, green: 0.75, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0.05, green: 0.25, blue: 0.55, alpha: 1)
    }
    static func color(for row: ParkingLotRow) -> NSColor {
        row.isDone ? .secondaryLabelColor : (row.heading ? headingColor : .textColor)
    }
    private var commentButtons: [UUID: NSButton] = [:]
    func updateCommentButtons() {
        guard let owner else { return }
        let entries = owner.projection.entries.filter { !($0.row.notes ?? []).isEmpty }
        let ids = Set(entries.map { $0.row.id })
        for id in Array(commentButtons.keys) where !ids.contains(id) { commentButtons.removeValue(forKey: id)?.removeFromSuperview() }
        for entry in entries {
            let button: NSButton
            if let existing = commentButtons[entry.row.id] { button = existing }
            else {
                button = NSButton(title: "", target: self, action: #selector(openComments(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(entry.row.id.uuidString)
                button.isBordered = false; button.font = .systemFont(ofSize: 10)
                button.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Comments")
                button.imagePosition = .imageLeading; button.contentTintColor = .secondaryLabelColor
                button.setButtonType(.momentaryPushIn)
                commentButtons[entry.row.id] = button; addSubview(button)
            }
            let count = entry.row.notes!.count
            button.title = "\(count)"
            button.toolTip = "Show \(count) \(count == 1 ? "comment" : "comments")"
            button.setAccessibilityLabel(button.toolTip)
            let rect = rowRect(entry)
            button.frame = NSRect(x: max(rect.minX, bounds.width - 38), y: rect.minY - 1, width: 34, height: max(18, rect.height))
        }
    }
    override func layout() {
        super.layout(); updateCommentButtons()
        // Resizes land here after the container tracks the new width, so
        // image spacing follows live resizes. render()'s width guard keeps
        // this a no-op when nothing changed.
        owner?.render()
    }
    @objc private func openComments(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let id = UUID(uuidString: value) else { return }
        showComments(id)
    }
    func showComments(_ id: UUID) {
        guard let notes = owner?.parent.lot.document.rows.first(where: { $0.id == id })?.notes, !notes.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "Comments"
        alert.informativeText = notes.map { $0.author + ": " + $0.text }.joined(separator: "\n\n")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    static let rowsType = NSPasteboard.PasteboardType("app.converse.parking-rows")
    private var imageCache: [String: NSImage] = [:]
    static let lotImageWidth: CGFloat = 320
    static let lotImageHeight: CGFloat = 106
    static let lotImageGap: CGFloat = 6
    /// Aspect-fit destination sizes parallel to paths. Unloadable paths yield nil
    /// and reserve no space, so a missing file never leaves a blank stride.
    func lotImageSizes(_ paths: [String], width: CGFloat) -> [NSSize?] {
        paths.map { path in
            if imageCache[path] == nil { imageCache[path] = NSImage(contentsOfFile: path) }
            guard let image = imageCache[path], image.size.width > 0, image.size.height > 0 else { return nil }
            let scale = min(width / image.size.width, Self.lotImageHeight / image.size.height)
            return NSSize(width: image.size.width * scale, height: image.size.height * scale)
        }
    }
    /// Reserved space below an image row: one gap above, each drawn height plus a
    /// gap, keeping the standard trailing space. Matches the drawing loop above.
    static func lotImageSpacing(_ sizes: [NSSize]) -> CGFloat {
        5 + lotImageGap + sizes.reduce(0) { $0 + $1.height + lotImageGap }
    }
    weak var owner: ParkingLotEditor.Coordinator?
    private var suppressSubstitutions = false
    private var immediateSubstitution: ImmediateSubstitution?
    override var undoManager: UndoManager? { owner?.parent.lot.undoManager }
    @objc func undo(_ sender: Any?) {
        let substituted = undoManager?.undoActionName == TextSubstitutions.undoName
        immediateSubstitution = nil; undoManager?.undo(); owner?.render()
        if substituted { owner?.parent.lot.substitutionFeedback.rejected() }
    }
    @objc func redo(_ sender: Any?) { immediateSubstitution = nil; undoManager?.redo(); owner?.render() }
    override func insertText(_ value: Any, replacementRange: NSRange) {
        immediateSubstitution = nil
        let typedSpace = !suppressSubstitutions && !hasMarkedText() && (value as? String) == " " && selectedRange().length == 0
        super.insertText(value, replacementRange: replacementRange)
        guard typedSpace, let owner, let match = TextSubstitutions.match(in: string, caret: selectedRange().location) else { return }
        owner.parent.lot.substitutionFeedback.converted()
        guard TextSubstitutions.shared.enabled else { return }
        let revision = owner.parent.lot.document.revision
        let caret = selectedRange().location
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        super.insertText(match.replacement, replacementRange: match.range)
        guard owner.parent.lot.document.revision != revision else { return }
        setSelectedRange(NSRange(location: caret + (match.replacement as NSString).length - match.range.length, length: 0))
        undoManager?.setActionName(TextSubstitutions.undoName)
        owner.parent.lot.substitutionFeedback.converted()
        immediateSubstitution = ImmediateSubstitution(text: string, caret: selectedRange())
    }
    override func deleteBackward(_ sender: Any?) {
        if immediateSubstitution?.matches(self) == true, undoManager?.undoActionName == TextSubstitutions.undoName { undo(sender); return }
        immediateSubstitution = nil
        if let owner, selectedRange().length == 0,
           let index = owner.projection.index(at: selectedRange().location) {
            let entry = owner.projection.entries[index]
            if !entry.placeholder && !entry.row.heading && entry.row.text.isEmpty && (entry.row.images ?? []).isEmpty {
                let document = owner.parent.lot.document
                let previous = owner.projection.entries.prefix(index).last { !$0.placeholder }
                owner.save(document.rows.filter { $0.id != entry.row.id }, expected: document,
                           caret: previous.map { ($0.row.id, $0.range.length) })
                return
            }
        }
        super.deleteBackward(sender)
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return undoManager?.canUndo == true }
        if item.action == #selector(redo(_:)) { return undoManager?.canRedo == true }
        // Plain NSTextView validation rejects image-only clipboards before the
        // Edit menu can dispatch Command-V to our custom paste implementation.
        if item.action == #selector(paste(_:)),
           NSPasteboard.general.data(forType: Self.rowsType) != nil || ConversationTextView.clipboardImage(.general) != nil {
            return isEditable && owner != nil
        }
        return super.validateUserInterfaceItem(item)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command), let owner,
               let index = owner.projection.index(at: selectedRange().location) {
                owner.add(heading: true, after: owner.projection.entries[index]); return
            }
            insertText(event.modifierFlags.contains(.command) ? "\u{2028}" : "\n", replacementRange: selectedRange()); return
        }
        super.keyDown(with: event)
    }
    override func copy(_ sender: Any?) {
        guard let owner, selectedRange().length > 0 else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(owner.projection.markdown(selectedRange()), forType: .string)
    }
    override func cut(_ sender: Any?) { guard selectedRange().length > 0 else { return }; copy(sender); insertText("", replacementRange: selectedRange()) }
    override func paste(_ sender: Any?) { paste(from: .general) }
    func paste(from board: NSPasteboard) {
        suppressSubstitutions = true; defer { suppressSubstitutions = false }
        guard let owner, let index = owner.projection.index(at: selectedRange().location) else { return }
        let entry = owner.projection.entries[index]
        let document = owner.parent.lot.document
        if let data = board.data(forType: Self.rowsType),
           var pasted = try? JSONDecoder().decode([ParkingLotRow].self, from: data), !pasted.isEmpty {
            // Copied entries get new identities; attachment files are immutable
            // and retained for Undo and for other lots using the same image.
            for i in pasted.indices { pasted[i].id = UUID() }
            var rows = document.rows
            let destination = entry.placeholder ? entry.before.flatMap { id in rows.firstIndex { $0.id == id } } ?? rows.count : rows.firstIndex { $0.id == entry.row.id }.map { $0 + 1 } ?? rows.count
            rows.insert(contentsOf: pasted, at: destination)
            owner.save(rows, expected: document, caret: (pasted[0].id, 0)); return
        }
        if let image = ConversationTextView.clipboardImage(board) {
            do {
                let path = try owner.parent.lot.saveImage(image)
                var rows = document.rows
                let target: Int
                if !entry.placeholder && !entry.row.heading, let existing = rows.firstIndex(where: { $0.id == entry.row.id }) { target = existing }
                else {
                    target = entry.placeholder ? entry.before.flatMap { id in rows.firstIndex { $0.id == id } } ?? rows.count : rows.firstIndex { $0.id == entry.row.id }.map { $0 + 1 } ?? rows.count
                    rows.insert(ParkingLotRow(heading: false, text: ""), at: target)
                }
                rows[target].images = (rows[target].images ?? []) + [path]
                owner.save(rows, expected: document, caret: (rows[target].id, rows[target].text.utf16.count))
            } catch { owner.parent.lot.error = error.localizedDescription }
            return
        }
        if let value = board.string(forType: .string) { insertText(value, replacementRange: selectedRange()) }
    }
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
            if let manager = layoutManager, let container = textContainer, let paths = entry.row.images, !paths.isEmpty {
                let end = max(entry.range.location, NSMaxRange(entry.range) - 1)
                let glyph = manager.glyphIndexForCharacter(at: min(end, max(0, (string as NSString).length - 1)))
                let line = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                let width = min(Self.lotImageWidth, container.containerSize.width - 10)
                var y = textContainerOrigin.y + line.maxY + Self.lotImageGap
                for (path, size) in zip(paths, lotImageSizes(paths, width: width)) {
                    guard let size, let image = imageCache[path] else { continue }
                    let dest = NSRect(x: textContainerOrigin.x + 5, y: y, width: size.width, height: size.height)
                    if dest.intersects(dirtyRect) {
                        image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    }
                    y += size.height + Self.lotImageGap
                }
            }
            guard rect.intersects(dirtyRect) else { continue }
            let marker = entry.row.heading ? (owner.parent.collapsed.contains(entry.row.id) ? "›" : "⌄") : "\(entry.number)."
            (marker as NSString).draw(at: NSPoint(x: 12, y: rect.minY), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
            if entry.placeholder {
                ((entry.row.heading ? "New Heading…" : "New item…") as NSString).draw(at: NSPoint(x: rect.minX + 5, y: rect.minY), withAttributes: [.font: entry.row.heading ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor])
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x < 32, let entry = owner?.projection.entries.first(where: { $0.row.heading && rowRect($0).minY <= point.y && rowRect($0).maxY >= point.y }), !entry.placeholder {
            owner?.toggle(entry.row.id); return
        }
        // Clicking a link follows it instead of placing the caret for editing.
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
           let (url, index) = link(at: point) {
            clicked(onLink: url, at: index); return
        }
        super.mouseDown(with: event)
        owner?.refreshLinks()
    }
    func link(at point: NSPoint) -> (URL, Int)? {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: local, in: container)
        guard manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < storage.length, let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL else { return nil }
        return (url, index)
    }
    // The window records the new first responder after these return.
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.owner?.refreshLinks() } }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.owner?.refreshLinks() } }
        return result
    }
    /// A row being edited shows raw link text; tests have no window and count as focused.
    var editingFocus: Bool { window == nil || window?.firstResponder === self }
    enum LinkAction: Equatable { case open(URL), reveal(URL), unavailable }
    /// Web and mail links open; local files are only revealed in Finder, never launched.
    static func action(for url: URL) -> LinkAction {
        if url.isFileURL { return FileManager.default.fileExists(atPath: url.path) ? .reveal(url) : .unavailable }
        return ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .open(url) : .unavailable
    }
    static func follow(_ url: URL) {
        switch action(for: url) {
        case .open(let url): NSWorkspace.shared.open(url)
        case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .unavailable: NSSound.beep()
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let menu = NSMenu()
        func item(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], _ action: @escaping () -> Void) {
            let target = ParkingMenuAction(action); let item = NSMenuItem(title: title, action: #selector(ParkingMenuAction.run), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target; item.representedObject = target; menu.addItem(item)
        }
        guard let i = owner.projection.index(at: index) else {
            item("New heading") { owner.add(heading: true) }
            return menu
        }
        let entry = owner.projection.entries[i]
        if selectedRange().length == 0 || !NSLocationInRange(index, selectedRange()) { setSelectedRange(NSRange(location: index, length: 0)) }
        if entry.row.heading { item("Rename heading") { owner.select(entry.row.id) } }
        item("New heading below", key: "\r", modifiers: .shift) { owner.add(heading: true, after: entry) }
        item("New item below", key: "\r") { owner.add(heading: false, after: entry) }
        menu.addItem(.separator())
        item(entry.row.heading ? "Copy Heading" : "Copy Item") { owner.copyEntry(entry.row.id, cut: false) }
        item(entry.row.heading ? "Cut Heading" : "Cut Item") { owner.copyEntry(entry.row.id, cut: true) }
        item("Paste") { self.paste(nil) }
        item("Reorder") { owner.parent.reorder() }
        if !entry.placeholder {
            item(entry.row.isDone ? "Mark Not Done" : "Mark Done") {
                owner.parent.lot.setDone(entry.row.id, !entry.row.isDone); owner.render()
            }
        }
        if !(entry.row.images ?? []).isEmpty {
            item("Remove Images") {
                let document = owner.parent.lot.document
                var rows = document.rows
                if let index = rows.firstIndex(where: { $0.id == entry.row.id }) {
                    rows[index].images = nil; owner.save(rows, expected: document)
                }
            }
        }
        if let notes = entry.row.notes, !notes.isEmpty {
            item("Comments (\(notes.count))…") {
                self.showComments(entry.row.id)
            }
        }
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
    check(outline.entries.filter(\.placeholder).count == 3 && outline.entries.last?.row.heading == true, "Outline provides one ready item per section and a trailing New Heading input")
    let again = ParkingOutline(rows: rows, collapsed: [], placeholders: &placeholders)
    check(outline.entries.map { $0.row.id } == again.entries.map { $0.row.id }, "Empty outline inputs retain stable identity without being saved")
    let afterHeading = outline.replacing(NSRange(location: heading.text.utf16.count, length: 0), with: "\n", rows: rows)!
    check(afterHeading.rows[0] == heading && !afterHeading.rows[1].heading && afterHeading.rows[1].text.isEmpty && afterHeading.rows[2] == first, "Return at the end of a heading inserts an item immediately below")
    let firstRange = outline.entries.first { $0.row.id == first.id }!.range
    let afterItem = outline.replacing(NSRange(location: NSMaxRange(firstRange), length: 0), with: "\n", rows: rows)!
    check(afterItem.rows[1] == first && !afterItem.rows[2].heading && afterItem.caretID == afterItem.rows[2].id, "Return after an item creates a new item and places its caret there")
    let blankOutline = ParkingOutline(rows: afterItem.rows, collapsed: [], placeholders: &placeholders)
    check(blankOutline.entries.contains { $0.row.id == afterItem.caretID && !$0.placeholder } && blankOutline.entries.filter { $0.placeholder && !$0.row.heading }.count == 2,
          "A real blank Return item coexists with each section's New item input")
    let illustrated = [ParkingLotRow(heading: false, text: "First", images: ["a.png"]), ParkingLotRow(heading: false, text: "Second", images: ["b.png"])]
    let illustratedOutline = ParkingOutline(rows: illustrated, collapsed: [], placeholders: &placeholders)
    let joined = illustratedOutline.replacing(NSRange(location: 5, length: 1), with: "", rows: illustrated)!
    check(joined.rows[0].text == "FirstSecond" && joined.rows[0].images == ["a.png", "b.png"], "Joining items with Backspace preserves both sets of images")
    let emptyOutline = ParkingOutline(rows: [], collapsed: [], placeholders: &placeholders)
    check(emptyOutline.entries.count == 1 && emptyOutline.entries[0].placeholder && emptyOutline.entries[0].row.heading,
          "An empty lot always offers New Heading")
    let soft = outline.replacing(NSRange(location: NSMaxRange(firstRange), length: 0), with: "\u{2028}Details", rows: rows)!
    check(soft.rows.count == rows.count && soft.rows[1].text == "Fix scrolling\nDetails" && soft.rows[1].notes == first.notes, "Command-Return inserts a line within the entry and preserves comments")
    let placeholder = outline.entries.first { $0.placeholder }!
    let typed = outline.replacing(placeholder.range, with: "Another feature", rows: rows)!
    let projected = ParkingOutline(rows: typed.rows, collapsed: [], placeholders: &placeholders)
    check(typed.rows[3].text == "Another feature" && projected.entries.filter(\.placeholder).count == 3 && Set(projected.entries.map { $0.row.id }).count == projected.entries.count, "Typing in the ready item saves it in its section and provides another empty item")
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
    check(text.validateUserInterfaceItem(NSMenuItem(title: "Undo", action: #selector(ParkingOutlineText.undo(_:)), keyEquivalent: "z")), "Native Edit menu enables Undo for the document history")
    text.undo(nil)
    check(lot.document.rows == original.rows, "Native Undo restores a multi-row-capable outline transaction")
    text.redo(nil)
    check(lot.document.rows[0].text == "Fresh features", "Native Redo restores the edited outline")
    lot.update(lot.document.rows[0].id, text: "Another writer")
    text.undoManager?.undo()
    check(lot.document.rows[0].text == "Fresh features", "Undo reverses the newest lot change before earlier text edits")
    text.redo(nil)
    check(lot.document.rows[0].text == "Another writer", "Redo restores the newest lot change before continuing edits")
    lot.error = ""
    lot.update(lot.document.rows[1].id, text: "Existing item"); coordinator.render()
    lot.setDone(lot.document.rows[1].id, true); coordinator.render()
    let doneRange = coordinator.projection.entries.first { $0.row.id == lot.document.rows[1].id }!.range
    let openRange = coordinator.projection.entries.first { $0.row.id == lot.document.rows[0].id }!.range
    check((text.textStorage?.attribute(.strikethroughStyle, at: doneRange.location, effectiveRange: nil) as? Int) == NSUnderlineStyle.single.rawValue, "Completed items render with strikethrough")
    check(text.textStorage?.attribute(.strikethroughStyle, at: openRange.location, effectiveRange: nil) == nil, "Open items render without strikethrough")
    let ready = coordinator.projection.entries.first { $0.placeholder }!
    let nextHeading = ready.before!
    coordinator.add(heading: true, after: ready)
    let position = lot.document.rows.firstIndex { $0.id == nextHeading }!
    check(lot.document.rows[position - 1].heading && lot.document.rows[position - 1].text.isEmpty, "Right-click creation at a ready input inserts at that section, not at the end of the document")
    let imageLot = ParkingLotStore(folder: folder.appendingPathComponent("images")); imageLot.open()
    let imageCoordinator = ParkingLotEditor.Coordinator(ParkingLotEditor(lot: imageLot, collapsed: .constant([]), reorder: {}))
    let imageText = ParkingOutlineText(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
    imageText.owner = imageCoordinator; imageText.delegate = imageCoordinator; imageText.isRichText = false
    imageCoordinator.text = imageText; imageCoordinator.render()
    let imageRow = imageLot.document.rows[1]
    imageText.setSelectedRange(imageCoordinator.projection.entries.first { $0.row.id == imageRow.id }!.range)
    let board = NSPasteboard.withUniqueName()
    let image = NSImage(size: NSSize(width: 100, height: 50), flipped: false) { rect in NSColor.blue.setFill(); rect.fill(); return true }
    board.writeObjects([image]); imageText.paste(from: board)
    let savedImages = imageLot.document.rows[1].images ?? []
    check(savedImages.count == 1 && FileManager.default.fileExists(atPath: savedImages[0]), "Pasting an image saves an immutable attachment on the selected item")
    imageText.undo(nil)
    check(imageLot.document.rows[1].images == nil, "Undo removes the image association without destroying the attachment file")
    imageText.redo(nil)
    check(imageLot.document.rows[1].images == savedImages, "Redo restores the item's pasted image")
    // A wide-short screenshot must reserve only its drawn height, not a fixed stride.
    let wideBoard = NSPasteboard.withUniqueName()
    let wide = NSImage(size: NSSize(width: 400, height: 40), flipped: false) { rect in NSColor.green.setFill(); rect.fill(); return true }
    wideBoard.writeObjects([wide])
    imageText.setSelectedRange(imageCoordinator.projection.entries.first { $0.row.id == imageRow.id }!.range)
    imageText.paste(from: wideBoard)
    wideBoard.releaseGlobally()
    let bothImages = imageLot.document.rows.first { $0.id == imageRow.id }!.images ?? []
    check(bothImages.count == 2, "A second pasted image attaches to the same item")
    let slotWidth = min(320, (imageText.textContainer?.containerSize.width ?? 400) - 10)
    // 100x50 scales to the full 106pt height; 400x40 aspect-fits to 32pt.
    let tallHeight = 50 * min(slotWidth / 100, 106 / 50)
    let wideHeight = 40 * min(slotWidth / 400, 106 / 40)
    let expectedSpacing = 5 + 6 + (tallHeight + 6) + (wideHeight + 6)
    let spacedEntry = imageCoordinator.projection.entries.first { $0.row.id == imageRow.id }!
    let spacedStyle = imageText.textStorage?.attribute(.paragraphStyle, at: spacedEntry.range.location, effectiveRange: nil) as? NSParagraphStyle
    check(spacedStyle != nil && abs(spacedStyle!.paragraphSpacing - expectedSpacing) < 0.5, "Image rows reserve their drawn height, not a fixed stride")
    check(imageText.lotImageSizes(["/nonexistent/missing.png"], width: 320).compactMap { $0 }.isEmpty, "Unloadable images reserve no space")
    // A live resize must re-reserve image height without an edit and without
    // calling render() directly: the layout pass triggers it. Both images are
    // width-limited here, so the reserved total changes with the pane.
    let beforeStyle = imageText.textStorage?.attribute(.paragraphStyle, at: spacedEntry.range.location, effectiveRange: nil) as? NSParagraphStyle
    let beforeSpacing: CGFloat = beforeStyle?.paragraphSpacing ?? -1
    imageText.textContainer?.widthTracksTextView = true
    imageText.setFrameSize(NSSize(width: 260, height: 600))
    if let layout = imageText.layoutManager, let container = imageText.textContainer {
        layout.ensureLayout(for: container)
    }
    imageText.layout()
    let liveWidth: CGFloat = min(320, (imageText.textContainer?.containerSize.width ?? 400) - 10)
    let liveScaleA: CGFloat = min(liveWidth / 100, 106 / 50)
    let liveScaleB: CGFloat = min(liveWidth / 400, 106 / 40)
    let liveExpected: CGFloat = 5 + 6 + (50 * liveScaleA + 6) + (40 * liveScaleB + 6)
    let liveEntry = imageCoordinator.projection.entries.first { $0.row.id == imageRow.id }!
    let liveStyle = imageText.textStorage?.attribute(.paragraphStyle, at: liveEntry.range.location, effectiveRange: nil) as? NSParagraphStyle
    let liveSpacing: CGFloat = liveStyle?.paragraphSpacing ?? -1
    check(abs(liveSpacing - liveExpected) < 1 && abs(liveExpected - beforeSpacing) > 1, "Resizing the pane re-reserves image height without an edit")
    imageText.undo(nil)
    check(imageLot.document.rows.first { $0.id == imageRow.id }!.images == savedImages, "Undo removes the second pasted image and restores single-image state")
    imageCoordinator.copyEntry(imageRow.id, cut: true, board: board)
    check(!imageLot.document.rows.contains { $0.id == imageRow.id }, "Cut Item removes the item and its attached image together")
    imageText.setSelectedRange(imageCoordinator.projection.entries.last!.range)
    imageText.paste(from: board)
    check(imageLot.document.rows.last?.images == savedImages && imageLot.document.rows.last?.id != imageRow.id, "Structural paste retains images and creates a distinct item identity")
    let reloaded = ParkingLotStore(folder: folder.appendingPathComponent("images"))
    check(reloaded.document.rows == imageLot.document.rows, "Item image associations survive persistence and reopening")
    let exported = ExportSession(lot: imageLot)
    let exportedHTML = try? TranscriptExport.html(sessions: [exported], order: .sequential, content: .prompts, lineNumbers: false, imageData: { try? Data(contentsOf: URL(fileURLWithPath: $0)) })
    let exportedText = try? TranscriptExport.text(sessions: [exported], order: .sequential, content: .prompts)
    check(exportedHTML?.contains("data:image/png;base64,") == true && exportedText?.contains("[Attached image:") == true, "Parking Lot exports include items and embedded HTML images regardless of conversation role filters")
    check(exportedHTML?.contains("Time unavailable</time>") == false, "Parking Lot exports do not invent conversation timestamps")
    // Exercise native menu validation, not only direct paste(from:) calls.
    let previousClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item -> NSPasteboardItem in
        let copy = NSPasteboardItem()
        for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
        return copy
    }
    defer { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(previousClipboard) }
    let png = try! Data(contentsOf: URL(fileURLWithPath: savedImages[0]))
    NSPasteboard.general.clearContents(); NSPasteboard.general.setData(png, forType: .png)
    let pasteCommand = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    let plainText = NSTextView(); plainText.isRichText = false
    check(!plainText.validateUserInterfaceItem(pasteCommand), "Native plain-text validation reproduces the disabled image-only Paste command")
    check(imageText.validateUserInterfaceItem(pasteCommand), "Parking Lot enables Edit Paste and Command-V for image-only clipboard")
    let beforeKeyboardPaste = imageLot.document.rows
    imageText.paste(pasteCommand)
    check(imageLot.document.rows.reduce(0) { $0 + ($1.images?.count ?? 0) } == beforeKeyboardPaste.reduce(0) { $0 + ($1.images?.count ?? 0) } + 1,
          "Menu Paste attaches the clipboard PNG to the Parking Lot")
    imageText.undo(nil)
    check(imageLot.document.rows == beforeKeyboardPaste, "Undo restores the lot after image-only menu paste")
    imageText.isEditable = false
    check(!imageText.validateUserInterfaceItem(pasteCommand), "Image Paste remains disabled in a noneditable Parking Lot")
    imageText.isEditable = true
    board.clearContents(); board.writeObjects([URL(fileURLWithPath: savedImages[0]) as NSURL])
    imageText.paste(from: board)
    check(imageLot.document.rows.reduce(0) { $0 + ($1.images?.count ?? 0) } == beforeKeyboardPaste.reduce(0) { $0 + ($1.images?.count ?? 0) } + 1,
          "Pasting a copied image file attaches its pixels to the Parking Lot")
    imageText.undo(nil)
    board.releaseGlobally()
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
    // Confirmation off removes only the review sheet: same validation, stale check, scope and Undo.
    command.parkingLotEdits = ParkingLotEdits(revision: lot.document.revision, operations: [.init(action: "update", id: id, text: "Saved without review")])
    var asked = false
    let beforeDirect = lot.document.rows
    let direct = store.parkingLotCommand(command, session: session, lot: lot, confirm: { _ in asked = true; return false }, requiresConfirmation: false)
    check(!asked && direct.contains("confirmation off") && !direct.contains("approved") && lot.document.rows[0].text == "Saved without review", "With confirmation off, session edits save without the review sheet")
    lot.undoManager.undo()
    check(lot.document.rows == beforeDirect, "Lot Undo reverses an edit saved without confirmation")
    command.parkingLotEdits = ParkingLotEdits(revision: lot.document.revision - 1, operations: [.init(action: "update", id: id, text: "Stale direct")])
    let staleDirect = store.parkingLotCommand(command, session: session, lot: lot, requiresConfirmation: false)
    check(staleDirect.contains("No changes applied") && lot.document.rows == beforeDirect, "With confirmation off, a stale revision still applies nothing")
    session.supportAutonomous = true
    command.parkingLotEdits = ParkingLotEdits(revision: lot.document.revision, operations: [.init(action: "update", id: id, text: "Autonomous")])
    check(store.parkingLotCommand(command, session: session, lot: lot, requiresConfirmation: false).contains("Nothing was read or changed") && lot.document.rows == beforeDirect, "Confirmation off never lets autonomous messages bypass scope")
    session.supportAutonomous = false
    check(store.switchboardTeaching(session).contains("If a lot's confirmation is off"), "Session teaching explains lots with confirmation off")
    let newID = UUID(), target = lot.document.rows.last!.id
    do {
        try lot.apply(.init(revision: lot.document.revision, operations: [.init(action: "add", id: newID, text: "Project", heading: true), .init(action: "move", id: target, before: newID)]), author: "Session")
        check(lot.document.rows.suffix(2).map(\.id) == [target, newID], "A session can add an identified heading and refer to it later in the same transaction")
    } catch { check(false, "Outline batch reorganization: " + error.localizedDescription) }
    check(store.switchboardTeaching(session).contains("Converse or KAOS") && store.switchboardTeaching(session).contains("Confirm the proposed reorganization"), "General session teaching includes contextual organization and user confirmation")
}

func parkingLinkEditorSelfTests(_ check: (Bool, String) -> Void) {
    lotLinkSelfTests(check)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parking-links-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lot = ParkingLotStore(folder: folder); lot.open()
    let coordinator = ParkingLotEditor.Coordinator(ParkingLotEditor(lot: lot, collapsed: .constant([]), reorder: {}))
    let text = ParkingOutlineText(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    text.isRichText = false; text.owner = coordinator; text.delegate = coordinator; coordinator.text = text; coordinator.render()
    let heading = lot.document.rows[0].id, item = lot.document.rows[1].id
    let stored = "See https://x.com/a and [Docs](https://d.com/b)."
    lot.update(item, text: stored)
    coordinator.render(caret: (heading, 0))
    func entry() -> ParkingOutline.Entry { coordinator.projection.entries.first { $0.row.id == item }! }
    func attribute(_ key: NSAttributedString.Key, _ offset: Int) -> Any? { text.textStorage?.attribute(key, at: entry().range.location + offset, effectiveRange: nil) }
    check(attribute(.link, 4) as? URL == URL(string: "https://x.com/a") && attribute(.link, 0) == nil && attribute(.link, 19) == nil, "Parking Lot items render bare URLs as links without the trailing words")
    check(attribute(.link, 25) as? URL == URL(string: "https://d.com/b") && (attribute(.font, 24) as? NSFont)?.pointSize ?? 13 < 1 && (attribute(.font, 31) as? NSFont)?.pointSize ?? 13 < 1, "A Markdown link outside the edited row shows only its clickable label")
    check(lot.document.rows[1].text == stored, "Link styling leaves the stored item text plain")
    text.setSelectedRange(NSRange(location: entry().range.location + 1, length: 0))
    check((attribute(.font, 24) as? NSFont)?.pointSize == 13 && attribute(.link, 25) != nil, "Moving the caret into a row reveals its Markdown for editing")
    text.setSelectedRange(NSRange(location: 0, length: 0))
    check((attribute(.font, 24) as? NSFont)?.pointSize ?? 13 < 1, "Leaving the row hides Markdown syntax again")
    text.layoutManager?.ensureLayout(for: text.textContainer!)
    if let manager = text.layoutManager, let container = text.textContainer {
        func point(_ offset: Int) -> NSPoint {
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: entry().range.location + offset, length: 1), actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            return NSPoint(x: rect.midX + text.textContainerOrigin.x, y: rect.midY + text.textContainerOrigin.y)
        }
        check(text.link(at: point(26))?.0 == URL(string: "https://d.com/b") && text.link(at: point(1)) == nil, "Clicking a link label follows it; clicking other text edits")
    }
    // Live styling: the URL stays plain while typed and becomes a link at the space.
    let typedRow = coordinator.projection.entries.first { $0.placeholder && !$0.row.heading }!
    text.setSelectedRange(NSRange(location: typedRow.range.location, length: 0))
    text.insertText("Visit https://y.com/z", replacementRange: text.selectedRange())
    let typedID = coordinator.projection.entries.first { $0.row.text == "Visit https://y.com/z" }!.row.id
    func typedLink() -> Any? { let typed = coordinator.projection.entries.first { $0.row.id == typedID }!; return text.textStorage?.attribute(.link, at: typed.range.location + 8, effectiveRange: nil) }
    check(typedLink() == nil, "A URL being typed stays plain until a boundary follows it")
    text.insertText(" ", replacementRange: text.selectedRange())
    check(typedLink() as? URL == URL(string: "https://y.com/z") && lot.document.rows.contains { $0.text == "Visit https://y.com/z " }, "Typing a space after a URL styles it as a link, as with text substitutions")
    text.undo(nil)
    check(lot.document.rows.contains { $0.text == "Visit https://y.com/z" } && typedLink() == nil, "Undo removes the space and the live link styling together")
    lot.setDone(item, true); coordinator.render(caret: (heading, 0))
    check(attribute(.link, 4) != nil && attribute(.strikethroughStyle, 4) != nil, "Done items keep clickable links")
    check(ParkingOutlineText.action(for: URL(string: "https://x.com")!) == .open(URL(string: "https://x.com")!) && ParkingOutlineText.action(for: URL(string: "javascript:alert(1)")!) == .unavailable, "Web links open in the browser; other schemes do nothing")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let teaching = Store.shared.switchboardTeaching(Session(entry: Entry(name: "Link writer", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")))
    check(teaching.contains("[label](https://url) and appear clickable") && teaching.contains("reveals in Finder"), "Session teaching explains how to write clickable lot links")
    check(ParkingOutlineText.action(for: folder) == .reveal(folder) && ParkingOutlineText.action(for: folder.appendingPathComponent("missing.txt")) == .unavailable, "File links reveal existing items in Finder and never launch them")
}
