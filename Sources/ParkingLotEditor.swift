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
        var depth: Int
        var hasChildren: Bool
    }
    var entries: [Entry] = []
    var string = ""
    init(rows: [ParkingLotRow], collapsed: Set<UUID>, placeholders: inout [String: UUID]) {
        var projected: [(ParkingLotRow, UUID?, Bool, Int, Int)] = []
        let hierarchy = (try? ParkingLotTree.nodes(rows)) ?? [:]
        let parents = Set(hierarchy.values.compactMap(\.parentID))
        var section: UUID?, sectionHidden = false, count = 0
        var hiddenByID: [UUID: Bool] = [:]
        var counts: [UUID?: Int] = [:]
        func empty(_ heading: Bool, before: UUID?) {
            let key = heading ? "heading" : (section?.uuidString ?? "root")
            let cached = placeholders[key]
            let id = cached.flatMap { id in rows.contains(where: { $0.id == id }) ? nil : id } ?? UUID()
            placeholders[key] = id
            projected.append((ParkingLotRow(id: id, heading: heading, text: "", parentID: heading ? nil : section),
                              before, true, count + 1, heading ? 0 : (section == nil ? 0 : 1)))
        }
        for row in rows {
            if row.heading {
                if !sectionHidden && !projected.isEmpty { empty(false, before: row.id) }
                section = row.id; sectionHidden = collapsed.contains(row.id); count = 0
                hiddenByID[row.id] = sectionHidden
                projected.append((row, nil, false, 0, 0))
            } else {
                let parent = hierarchy[row.id]?.parentID
                counts[parent, default: 0] += 1
                if parent == section { count = counts[parent] ?? count }
                let hidden = parent.flatMap { hiddenByID[$0] } ?? false
                hiddenByID[row.id] = hidden || collapsed.contains(row.id)
                if !hidden { projected.append((row, nil, false, counts[parent] ?? 1, hierarchy[row.id]?.depth ?? 1)) }
            }
        }
        if !sectionHidden && !projected.isEmpty { empty(false, before: nil) }
        empty(true, before: nil)
        for (row, before, placeholder, number, depth) in projected {
            if !entries.isEmpty { string += "\n" }
            let text = row.text.replacingOccurrences(of: "\n", with: "\u{2028}")
            let range = NSRange(location: (string as NSString).length, length: (text as NSString).length)
            entries.append(Entry(row: row, range: range, before: before, placeholder: placeholder,
                                 number: number, depth: depth, hasChildren: parents.contains(row.id)))
            string += text
        }
    }
    func index(at offset: Int) -> Int? { entries.lastIndex { $0.range.location <= offset } }
    struct Edit {
        var rows: [ParkingLotRow]
        var caretID: UUID
        var caretOffset: Int
    }
    func replacing(_ range: NSRange, with replacement: String, rows: [ParkingLotRow], mergeSeparator: Bool = true) -> Edit? {
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
        let firstParent = first.row.heading ? first.row.id : ((try? ParkingLotTree.nodes(rows))?[first.row.id]?.parentID ?? first.row.parentID)
        var insertedHeading: UUID?
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
            if row.heading { row.parentID = nil; insertedHeading = row.id }
            else if rows.contains(where: { $0.id == row.id }) == false || first.placeholder { row.parentID = insertedHeading ?? firstParent }
            newRows.append(row)
        }
        // Only a single real row separator is a merge. Full-row Cut/Delete
        // continues to remove the selected subtree, including hidden children.
        let merging = mergeSeparator && start != end && insertion.isEmpty && range.length == 1
            && firstOffset == firstText.length && lastOffset == 0
            && !first.placeholder && !last.placeholder
        if merging {
            func section(_ id: UUID) -> UUID? {
                guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
                return rows[...index].last(where: \.heading)?.id
            }
            guard section(first.row.id) == section(last.row.id) else { return nil }
            // Even an empty first row survives a separator merge.
            newRows[0] = first.row
            newRows[0].text = (prefix + suffix).replacingOccurrences(of: "\u{2028}", with: "\n")
            newRows[0].editedBy = nil
            let images = (first.row.images ?? []) + (last.row.images ?? [])
            if !images.isEmpty { newRows[0].images = images }
            let notes = (first.row.notes ?? []) + (last.row.notes ?? [])
            if !notes.isEmpty { newRows[0].notes = notes }
            // Normalize legacy implicit parents before transferring children.
            guard let normalized = try? ParkingLotTree.normalized(rows) else { return nil }
            result = normalized.filter { !removed.contains($0.id) }.map { row in
                var row = row
                if row.parentID == last.row.id { row.parentID = first.row.id }
                return row
            }
        }
        let caretLine = (prefix + insertion).components(separatedBy: "\n").count - 1
        let rawCaret = (prefix + insertion).components(separatedBy: "\n").last! as NSString
        let caret = min(rawCaret.length, (newRows[caretLine].text as NSString).length)
        // A removed parent takes its hidden descendants with it. Editing the
        // parent's text keeps its ID in newRows, so those children stay put.
        let retained = Set(newRows.map(\.id))
        let deletedRoots = removed.subtracting(retained)
        let descendants = Set(deletedRoots.flatMap { id in
            ParkingLotTree.range(id, in: rows).map { range in rows[range].map(\.id) } ?? []
        })
        if !merging { result.removeAll { descendants.contains($0.id) } }
        result.insert(contentsOf: newRows, at: min(destination, result.count))
        // Return on a parent creates its next sibling after the whole subtree.
        // Its existing children must remain directly below the original item.
        if start == end, insertion == "\n", !first.row.heading, !first.placeholder,
           newRows.count == 2, let originalRange = ParkingLotTree.range(first.row.id, in: rows),
           originalRange.count > 1 {
            let sibling = result.remove(at: destination + 1)
            result.insert(sibling, at: min(destination + originalRange.count, result.count))
        }
        // Reparenting may make a deep previous row exceed the depth cap, or
        // break preorder. Refuse the entire edit rather than losing descendants.
        if merging, (try? ParkingLotTree.nodes(result)) == nil { return nil }
        return Edit(rows: result, caretID: newRows[caretLine].id, caretOffset: caret)
    }
    func markdown(_ selection: NSRange) -> String {
        guard let start = index(at: selection.location), let end = index(at: NSMaxRange(selection)) else { return "" }
        if start == end { return (string as NSString).substring(with: selection).replacingOccurrences(of: "\u{2028}", with: "\n") }
        return entries[start...end].compactMap { entry -> String? in
            let overlap = NSIntersectionRange(selection, entry.range)
            guard overlap.length > 0 else { return nil }
            let text = (string as NSString).substring(with: overlap).replacingOccurrences(of: "\u{2028}", with: "\n")
            let indent = String(repeating: "  ", count: max(0, entry.depth - 1))
            return (overlap.location == entry.range.location ? (entry.row.heading ? "# " : indent + ParkingLotTree.label(entry.number, depth: entry.depth) + ". ") : "") + text
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
            for entry in projection.entries {
                let style = standard.mutableCopy() as! NSMutableParagraphStyle
                let offset = CGFloat(max(0, entry.depth - 1)) * 20
                style.firstLineHeadIndent = offset; style.headIndent = offset
                if entry.row.heading { style.paragraphSpacingBefore = 7 }
                if let paths = entry.row.images, !paths.isEmpty {
                    let sizes = text.lotImageSizes(paths, width: max(40, width - offset)).compactMap { $0 }
                    style.paragraphSpacing = ParkingOutlineText.lotImageSpacing(sizes)
                }
                let length = min(body.length - entry.range.location, max(1, entry.range.length))
                if length > 0 {
                    let range = NSRange(location: entry.range.location, length: length)
                    body.addAttribute(.paragraphStyle, value: style, range: range)
                    if entry.row.heading { body.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: range) }
                }
            }
            let anchor = caret ?? oldAnchor
            linkEditing = text.editingFocus ? anchor.flatMap { anchor in projection.entries.first { $0.row.id == anchor.0 }.map { (anchor.0, min(anchor.1, $0.range.length)) } } : nil
            if let settled, !(linkEditing.map { $0 == settled } ?? false) { self.settled = nil }
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
            let selection = text.selectedRange(), allowed = snapped(selection, from: selection, mouse: false)
            if allowed != selection { text.setSelectedRange(allowed) }
            text.updateCommentButtons()
            text.needsDisplay = true
            if caret != nil { text.scrollRangeToVisible(text.selectedRange()) }
        }
        // A bare link being typed stays plain until a space or other boundary
        // follows it. Markdown links always show only their label.
        var linkEditing: (UUID, Int)?
        // Pasted or dropped text arrives complete, so its row renders finished
        // links at once and keeps them until the caret moves.
        var settled: (UUID, Int)?
        static let hiddenFont = NSFont.systemFont(ofSize: 0.01)
        func styleLinks(_ storage: NSMutableAttributedString, _ entry: ParkingOutline.Entry) {
            let links = LotLinks.find(in: entry.row.text)
            guard !links.isEmpty else { return }
            storage.addAttributes([.font: entry.row.heading ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13),
                                   .foregroundColor: ParkingOutlineText.color(for: entry.row)], range: entry.range)
            storage.removeAttribute(.link, range: entry.range); storage.removeAttribute(.toolTip, range: entry.range)
            let caret = settled?.0 == entry.row.id ? nil : linkEditing.flatMap { $0.0 == entry.row.id ? $0.1 : nil }
            for link in links {
                if !link.isMarkdown, let caret, caret >= link.range.location, caret <= LotLinks.tokenEnd(link, in: entry.row.text) { continue }
                let label = NSRange(location: entry.range.location + link.label.location, length: link.label.length)
                storage.addAttributes([.link: link.url, .toolTip: link.isFile ? link.url.path : link.url.absoluteString], range: label)
                guard link.isMarkdown else { continue }
                let opening = NSRange(location: entry.range.location + link.range.location, length: 1)
                let closing = NSRange(location: NSMaxRange(label), length: NSMaxRange(link.range) - link.label.location - link.label.length)
                for syntax in [opening, closing] { storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: syntax) }
            }
        }
        /// A Markdown link in the display: `whole` spans "[label](url)", `label` the visible part.
        struct HiddenLink { var row: UUID; var link: LotLinks.Link; var whole: NSRange; var label: NSRange }
        func hiddenLinks(touching range: NSRange) -> [HiddenLink] {
            projection.entries.filter { $0.range.location <= NSMaxRange(range) && NSMaxRange($0.range) >= range.location }.flatMap { entry in
                LotLinks.find(in: entry.row.text).filter(\.isMarkdown).map { link in
                    HiddenLink(row: entry.row.id, link: link, whole: NSRange(location: entry.range.location + link.range.location, length: link.range.length),
                               label: NSRange(location: entry.range.location + link.label.location, length: link.label.length))
                }
            }
        }
        // Option-click opens one link's label for editing in place: (row, link start in row).
        var labelEditing: (UUID, Int)?
        func editedLabel() -> HiddenLink? {
            guard let labelEditing, let entry = projection.entries.first(where: { $0.row.id == labelEditing.0 }) else { return nil }
            return hiddenLinks(touching: entry.range).first { $0.row == labelEditing.0 && $0.link.range.location == labelEditing.1 }
        }
        func openLabel(at index: Int, caret: Int) -> Bool {
            guard let text, let link = hiddenLinks(touching: NSRange(location: index, length: 0)).first(where: { NSLocationInRange(index, $0.label) }) else { return false }
            labelEditing = (link.row, link.link.range.location)
            text.window?.makeFirstResponder(text)
            text.setSelectedRange(NSRange(location: min(max(caret, link.label.location), NSMaxRange(link.label)), length: 0))
            return true
        }
        /// The edge a position inside hidden syntax belongs to: the nearer end of the label.
        static func nearestEdge(_ p: Int, _ link: HiddenLink) -> Int {
            p >= NSMaxRange(link.label) || p - link.label.location >= NSMaxRange(link.label) - p ? NSMaxRange(link.whole) : link.whole.location
        }
        /// Hidden Markdown syntax is never a caret stop. A caret moving into a link
        /// crosses it; selections grow to whole links, except within an opened label.
        func snapped(_ proposed: NSRange, from old: NSRange, mouse: Bool) -> NSRange {
            if let open = editedLabel(), proposed.location >= open.label.location, NSMaxRange(proposed) <= NSMaxRange(open.label) { return proposed }
            labelEditing = nil
            var start = proposed.location, end = NSMaxRange(proposed)
            for link in hiddenLinks(touching: proposed) {
                let a = link.whole.location, b = NSMaxRange(link.whole)
                func edge(_ p: Int, was: Int, otherwise: Int) -> Int {
                    guard p > a && p < b else { return p }
                    if !mouse && p > was { return b }
                    if !mouse && p < was { return a }
                    return otherwise
                }
                if start == end { start = edge(start, was: old.location, otherwise: Self.nearestEdge(start, link)); end = start }
                else { start = edge(start, was: old.location, otherwise: a); end = edge(end, was: NSMaxRange(old), otherwise: b) }
            }
            return NSRange(location: start, length: max(0, end - start))
        }
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange proposed: NSRange) -> NSRange {
            guard !rendering, textView.string.utf16.count == (projection.string as NSString).length else { return proposed }
            let mouse = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown].contains(NSApp.currentEvent?.type)
            return snapped(proposed, from: old, mouse: mouse)
        }
        /// Edits treat a Markdown link as one piece: Backspace after it or Delete
        /// before it removes the whole link, and typing never lands in its syntax.
        func atomic(_ range: NSRange, _ replacement: String) -> NSRange? {
            if let open = editedLabel(), range.location >= open.label.location, NSMaxRange(range) <= NSMaxRange(open.label) {
                if replacement.rangeOfCharacter(from: CharacterSet(charactersIn: "[]\n\r\u{2028}")) == nil { return replacement.isEmpty && range == open.label ? open.whole : range }
                // Brackets and line breaks would split the link, so they go after it.
                guard range.length == 0 else { NSSound.beep(); return nil }
                labelEditing = nil
                return NSRange(location: NSMaxRange(open.whole), length: 0)
            }
            // Backspace at the start of an opened label, or Delete at its end, reaches past the link.
            if let open = editedLabel(), replacement.isEmpty, range.length == 1, let text {
                let source = text.string as NSString
                if range.location == open.whole.location && range.location > 0 { labelEditing = nil; return source.rangeOfComposedCharacterSequence(at: range.location - 1) }
                if range.location == NSMaxRange(open.label) && NSMaxRange(open.whole) < source.length { labelEditing = nil; return source.rangeOfComposedCharacterSequence(at: NSMaxRange(open.whole)) }
            }
            var start = range.location, end = NSMaxRange(range)
            for link in hiddenLinks(touching: range) {
                // Selections never sit inside a link, so this is autocorrect or Find replacing part of it.
                if range.length > 0 && range.location > link.whole.location && NSMaxRange(range) < NSMaxRange(link.whole) { return nil }
                if range.length == 0 {
                    if start > link.whole.location && start < NSMaxRange(link.whole) { start = Self.nearestEdge(start, link); end = start }
                } else if NSIntersectionRange(range, link.whole).length > 0 {
                    start = min(start, link.whole.location); end = max(end, NSMaxRange(link.whole))
                }
            }
            return NSRange(location: start, length: end - start)
        }
        /// Restyle only the rows whose caret state changed; text and selection are untouched.
        func refreshLinks(settle: Bool = false) {
            guard !rendering, let text, let storage = text.textStorage, storage.length == (projection.string as NSString).length else { return }
            let selection = text.selectedRange()
            let anchor = text.editingFocus ? projection.index(at: selection.location).map { (projection.entries[$0].row.id, selection.location - projection.entries[$0].range.location) } : nil
            if settle { settled = anchor } else if let settled, !(anchor.map { $0 == settled } ?? false) { self.settled = nil }
            guard settle || anchor?.0 != linkEditing?.0 || anchor?.1 != linkEditing?.1 else { return }
            let changed = Set([anchor?.0, linkEditing?.0].compactMap { $0 })
            linkEditing = anchor
            storage.beginEditing()
            for entry in projection.entries where changed.contains(entry.row.id) && entry.range.length > 0 { styleLinks(storage, entry) }
            storage.endEditing()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            // Next to hidden link syntax the caret would take its tiny font.
            if let text, let font = text.typingAttributes[.font] as? NSFont, font.pointSize < 1 {
                text.typingAttributes[.font] = NSFont.systemFont(ofSize: 13); text.typingAttributes[.foregroundColor] = NSColor.textColor
            }
            // A click restyles after mouse tracking ends, so text never shifts under a drag.
            if let type = NSApp.currentEvent?.type, [.leftMouseDown, .leftMouseDragged].contains(type), text?.window != nil { return }
            refreshLinks()
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { ParkingOutlineText.follow(url) }
            return true
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard !rendering, let replacementString, let displayed, let affectedCharRange = atomic(affectedCharRange, replacementString),
                  let edit = projection.replacing(affectedCharRange, with: replacementString, rows: displayed.rows, mergeSeparator: text?.cutting != true) else { return false }
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
        /// The link (bare or Markdown) at a display index, located by its row and start.
        func link(containing index: Int) -> (row: UUID, link: LotLinks.Link, source: String)? {
            guard let i = projection.index(at: index) else { return nil }
            let entry = projection.entries[i], offset = index - entry.range.location
            guard let link = LotLinks.find(in: entry.row.text).first(where: { NSLocationInRange(offset, $0.range) }) else { return nil }
            return (entry.row.id, link, (entry.row.text as NSString).substring(with: link.range))
        }
        /// Rewrite the link that still reads `source` at `location`; returns a problem to show, or nil once saved.
        func setLink(_ id: UUID, at location: Int, source: String, label: String, address: String) -> String? {
            let label = label.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
                .components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let target = address.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "%20")
                .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
            guard !label.isEmpty else { return "Enter a label for the link." }
            let markdown = "[" + label + "](" + target + ")"
            guard ["http://", "https://", "mailto:", "file://"].contains(where: { target.lowercased().hasPrefix($0) }), LotLinks.url(target) != nil,
                  LotLinks.find(in: markdown).map(\.range) == [NSRange(location: 0, length: (markdown as NSString).length)] else {
                return "Use a web (https://…), email (mailto:…) or file (file:///…) link."
            }
            return replaceLink(id, at: location, source: source, with: markdown)
        }
        /// Keep a Markdown link's label as plain text.
        func removeLink(_ id: UUID, at location: Int, source: String) {
            guard let link = LotLinks.find(in: source).first, link.isMarkdown else { return }
            _ = replaceLink(id, at: location, source: source, with: (source as NSString).substring(with: link.label))
        }
        private func replaceLink(_ id: UUID, at location: Int, source: String, with replacement: String) -> String? {
            let document = parent.lot.document
            var rows = document.rows
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return "That item no longer exists." }
            let current = rows[index].text as NSString, range = NSRange(location: location, length: (source as NSString).length)
            guard NSMaxRange(range) <= current.length, current.substring(with: range) == source else { return "That link changed while you were editing it." }
            rows[index].text = current.replacingCharacters(in: range, with: replacement); rows[index].editedBy = nil
            labelEditing = nil
            save(rows, expected: document, caret: (id, location + (replacement as NSString).length))
            return nil
        }
        func select(_ id: UUID) {
            guard let text, let entry = projection.entries.first(where: { $0.row.id == id }) else { return }
            text.window?.makeFirstResponder(text); text.setSelectedRange(entry.range); text.scrollRangeToVisible(entry.range)
        }
        func add(heading: Bool, after entry: ParkingOutline.Entry? = nil) {
            let document = parent.lot.document
            let index: Int
            var parentID: UUID?
            if let entry {
                if entry.placeholder {
                    index = entry.before.flatMap { id in document.rows.firstIndex { $0.id == id } } ?? document.rows.count
                    parentID = entry.row.parentID
                } else if heading {
                    let section = document.rows.prefix { $0.id != entry.row.id }.last(where: \.heading)?.id
                    let anchor = entry.row.heading ? entry.row.id : section
                    index = anchor.flatMap { ParkingLotStore.entryRange($0, in: document.rows)?.upperBound } ?? document.rows.count
                } else {
                    index = ParkingLotStore.entryRange(entry.row.id, in: document.rows)?.upperBound ?? document.rows.count
                    parentID = entry.row.heading ? entry.row.id : (try? ParkingLotTree.nodes(document.rows))?[entry.row.id]?.parentID
                }
                parent.collapsed.remove(entry.row.id)
            } else { index = document.rows.count }
            if !heading && parentID == nil { parentID = ParkingLotTree.parentForInsertion(at: index, in: document.rows, heading: false) }
            let row = ParkingLotRow(heading: heading, text: "", parentID: heading ? nil : parentID)
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
        func changeIndent(_ id: UUID, deeper: Bool) {
            let offset = projection.entries.first(where: { $0.row.id == id }).map { entry in
                max(0, min(entry.range.length, (text?.selectedRange().location ?? entry.range.location) - entry.range.location))
            } ?? 0
            if parent.lot.changeIndent(id, deeper: deeper) { render(caret: (id, offset)) }
            else { NSSound.beep() }
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
        if immediateSubstitution?.matches(self) == true, [TextSubstitutions.undoName, Self.fileLinkUndoName].contains(undoManager?.undoActionName ?? "") { undo(sender); return }
        immediateSubstitution = nil
        if let owner, selectedRange().length == 0,
           let index = owner.projection.index(at: selectedRange().location) {
            let entry = owner.projection.entries[index]
            if !entry.placeholder && !entry.row.heading && !entry.hasChildren && entry.row.text.isEmpty && (entry.row.images ?? []).isEmpty {
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
        if event.keyCode == 48, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.option),
           let owner, let index = owner.projection.index(at: selectedRange().location) {
            let entry = owner.projection.entries[index]
            if !entry.placeholder && !entry.row.heading {
                owner.changeIndent(entry.row.id, deeper: !event.modifierFlags.contains(.shift)); return
            }
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command), let owner,
               let index = owner.projection.index(at: selectedRange().location) {
                owner.add(heading: true, after: owner.projection.entries[index]); return
            }
            insertText(event.modifierFlags.contains(.command) ? "\u{2028}" : "\n", replacementRange: selectedRange()); return
        }
        super.keyDown(with: event)
    }
    override func copy(_ sender: Any?) { copySelection(to: .general) }
    /// Other apps get link labels as plain text; a Parking Lot paste gets the Markdown back.
    func copySelection(to board: NSPasteboard) {
        guard let owner, selectedRange().length > 0 else { return }
        let markdown = owner.projection.markdown(selectedRange()), plain = Self.labels(markdown)
        board.clearContents(); board.setString(plain, forType: .string)
        if plain != markdown { board.setString(markdown, forType: Self.markdownType) }
    }
    static let markdownType = NSPasteboard.PasteboardType("app.converse.parking-markdown")
    static func labels(_ text: String) -> String {
        let source = NSMutableString(string: text)
        for link in LotLinks.find(in: text).reversed() where link.isMarkdown {
            source.replaceCharacters(in: link.range, with: source.substring(with: link.label))
        }
        return source as String
    }
    var cutting = false
    override func cut(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        copy(sender)
        cutting = true; defer { cutting = false }
        insertText("", replacementRange: selectedRange())
    }
    override func paste(_ sender: Any?) { paste(from: .general) }
    func paste(from board: NSPasteboard) {
        suppressSubstitutions = true; defer { suppressSubstitutions = false }
        guard let owner, let index = owner.projection.index(at: selectedRange().location) else { return }
        let entry = owner.projection.entries[index]
        let document = owner.parent.lot.document
        if let data = board.data(forType: Self.rowsType),
           var pasted = try? JSONDecoder().decode([ParkingLotRow].self, from: data), !pasted.isEmpty,
           Set(pasted.map(\.id)).count == pasted.count {
            // Copied entries get new identities; attachment files are immutable
            // and retained for Undo and for other lots using the same image.
            let newIDs = Dictionary(uniqueKeysWithValues: pasted.map { ($0.id, UUID()) })
            for i in pasted.indices {
                let oldID = pasted[i].id
                pasted[i].id = newIDs[oldID]!
                pasted[i].parentID = pasted[i].parentID.flatMap { newIDs[$0] }
            }
            var rows = document.rows
            let destination = entry.placeholder ? entry.before.flatMap { id in rows.firstIndex { $0.id == id } } ?? rows.count : ParkingLotStore.entryRange(entry.row.id, in: rows)?.upperBound ?? rows.count
            if !pasted[0].heading {
                pasted[0].parentID = ParkingLotTree.parentForInsertion(at: destination, in: rows, heading: false)
            }
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
        if let value = board.string(forType: Self.markdownType) ?? board.string(forType: .string) {
            insertText(value, replacementRange: selectedRange())
            if !LotLinks.find(in: value).isEmpty { owner.refreshLinks(settle: true) }
        }
    }
    static let fileLinkUndoName = "File Link"
    static func droppedFiles(_ board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .map { (($0 as NSURL).filePathURL ?? $0).standardizedFileURL }
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let owner, isEditable else { return false }
        let board = sender.draggingPasteboard
        let files = (sender.draggingSource as AnyObject?) === self ? [] : Self.droppedFiles(board)
        if !files.isEmpty {
            insertFileLinks(files, at: characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)))
            return true
        }
        // NSTextView registers drop Undo after the edit; the lot groups Undo
        // explicitly, so without an open group the drop raises mid-operation.
        undoManager?.beginUndoGrouping()
        let dropped = super.performDragOperation(sender)
        undoManager?.endUndoGrouping()
        if let value = board.string(forType: .string), !LotLinks.find(in: value).isEmpty { owner.refreshLinks(settle: true) }
        return dropped
    }
    /// Files dropped from Finder become Markdown links. Like a text substitution,
    /// one Undo (or an immediate Backspace) restores the plain path first.
    func insertFileLinks(_ urls: [URL], at location: Int) {
        guard let owner, !urls.isEmpty else { return }
        immediateSubstitution = nil
        suppressSubstitutions = true; defer { suppressSubstitutions = false }
        window?.makeFirstResponder(self)
        let plain = urls.map(\.path).joined(separator: ", ")
        let linked = urls.map(LotLinks.markdown(file:)).joined(separator: ", ")
        let proposed = NSRange(location: min(location, (string as NSString).length), length: 0)
        setSelectedRange(owner.snapped(proposed, from: proposed, mouse: true))
        let start = selectedRange().location
        var revision = owner.parent.lot.document.revision
        insertText(plain, replacementRange: selectedRange())
        guard owner.parent.lot.document.revision != revision else { return }
        revision = owner.parent.lot.document.revision
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        super.insertText(linked, replacementRange: NSRange(location: start, length: (plain as NSString).length))
        guard owner.parent.lot.document.revision != revision else { return }
        setSelectedRange(NSRange(location: start + (linked as NSString).length, length: 0))
        undoManager?.setActionName(Self.fileLinkUndoName)
        immediateSubstitution = ImmediateSubstitution(text: string, caret: selectedRange())
        owner.refreshLinks(settle: true)
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
                let offset = CGFloat(max(0, entry.depth - 1)) * 20
                let width = max(40, min(Self.lotImageWidth, container.containerSize.width - 10 - offset))
                var y = textContainerOrigin.y + line.maxY + Self.lotImageGap
                for (path, size) in zip(paths, lotImageSizes(paths, width: width)) {
                    guard let size, let image = imageCache[path] else { continue }
                    let dest = NSRect(x: textContainerOrigin.x + 5 + offset, y: y, width: size.width, height: size.height)
                    if dest.intersects(dirtyRect) {
                        image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    }
                    y += size.height + Self.lotImageGap
                }
            }
            guard rect.intersects(dirtyRect) else { continue }
            let offset = CGFloat(max(0, entry.depth - 1)) * 20
            let marker = entry.row.heading ? (owner.parent.collapsed.contains(entry.row.id) ? "›" : "⌄") : ParkingLotTree.label(entry.number, depth: entry.depth) + "."
            let markerAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
            // Item labels are right-aligned against the text, so "iii." or "12." never overlaps it.
            let markerX = entry.row.heading ? 12 + offset : max(2, 32 + offset - (marker as NSString).size(withAttributes: markerAttributes).width)
            (marker as NSString).draw(at: NSPoint(x: markerX, y: rect.minY), withAttributes: markerAttributes)
            if entry.hasChildren && !entry.row.heading {
                let disclosure = owner.parent.collapsed.contains(entry.row.id) ? "▸" : "▾"
                (disclosure as NSString).draw(at: NSPoint(x: 2 + offset, y: rect.minY), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
            }
            if entry.placeholder {
                ((entry.row.heading ? "New Heading…" : "New item…") as NSString).draw(at: NSPoint(x: rect.minX + 5, y: rect.minY), withAttributes: [.font: entry.row.heading ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor])
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let entry = owner?.projection.entries.first(where: { ($0.row.heading || $0.hasChildren) && rowRect($0).minY <= point.y && rowRect($0).maxY >= point.y }),
           !entry.placeholder, point.x < (entry.row.heading ? 32 : 12 + CGFloat(max(0, entry.depth - 1)) * 20) {
            owner?.toggle(entry.row.id); return
        }
        // Clicking a link follows it instead of placing the caret for editing;
        // Option-click places the caret in a Markdown link's label instead.
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if event.clickCount == 1, modifiers.isEmpty || modifiers == .option, let (url, index) = link(at: point) {
            if modifiers.isEmpty { clicked(onLink: url, at: index); return }
            if owner?.openLabel(at: index, caret: characterIndexForInsertion(at: point)) == true { owner?.refreshLinks(); return }
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
        let clickedLink = link(at: point).flatMap { owner.link(containing: $0.1) }
        if selectedRange().length == 0 || !NSLocationInRange(index, selectedRange()) { setSelectedRange(NSRange(location: index, length: 0)) }
        if let clickedLink {
            let (row, link, source) = clickedLink
            item("Edit Link…") { self.editLink(row, at: link.range.location, source: source) }
            if link.isMarkdown { item("Remove Link") { owner.removeLink(row, at: link.range.location, source: source) } }
            item("Copy Link Address") { Self.copyLinkAddress(link.url) }
            menu.addItem(.separator())
        }
        if entry.row.heading { item("Rename heading") { owner.select(entry.row.id) } }
        item("New heading below", key: "\r", modifiers: .shift) { owner.add(heading: true, after: entry) }
        item("New item below", key: "\r") { owner.add(heading: false, after: entry) }
        menu.addItem(.separator())
        item(entry.row.heading ? "Copy Heading" : "Copy Item") { owner.copyEntry(entry.row.id, cut: false) }
        item(entry.row.heading ? "Cut Heading" : "Cut Item") { owner.copyEntry(entry.row.id, cut: true) }
        item("Paste") { self.paste(nil) }
        item("Reorder") { owner.parent.reorder() }
        if !entry.placeholder {
            let rows = owner.parent.lot.document.rows
            if ParkingLotTree.canIndent(entry.row.id, in: rows) {
                item("Indent", key: "\t") { owner.changeIndent(entry.row.id, deeper: true) }
            }
            if ParkingLotTree.canOutdent(entry.row.id, in: rows) {
                item("Outdent", key: "\t", modifiers: .shift) { owner.changeIndent(entry.row.id, deeper: false) }
            }
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
        if !entry.placeholder {
            let targets = ParkingLotStore.moveTargets(for: entry.row.id, in: owner.parent.lot.document.rows)
            if !targets.isEmpty { menu.addItem(.separator()) }
            for heading in targets {
                let name = heading.text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                let label = name.isEmpty ? "Untitled heading" : name.count > 48 ? String(name.prefix(47)) + "…" : name
                item("Move ➞ " + label) { owner.parent.lot.moveToSection(entry.row.id, heading: heading.id); owner.render() }
            }
        }
        return menu
    }
}
extension ParkingOutlineText {
    static func copyLinkAddress(_ url: URL, to board: NSPasteboard = .general) {
        board.clearContents(); board.setString(url.absoluteString, forType: .string)
    }
    /// Label and address for a link's source text; a Markdown address is shown as written.
    static func linkFields(_ source: String) -> (label: String, address: String)? {
        guard let link = LotLinks.find(in: source).first, link.range.location == 0 else { return nil }
        let text = source as NSString
        guard link.isMarkdown else { return (text.substring(with: link.label), link.url.absoluteString) }
        return (text.substring(with: link.label), text.substring(with: NSRange(location: NSMaxRange(link.label) + 2, length: link.range.length - link.label.length - 4)))
    }
    static let linkHelp = "Links show only their label. Click a link to open it (file links reveal in Finder). To edit the label text in place, Option-click it."
    func editLink(_ row: UUID, at location: Int, source: String, fields: (label: String, address: String)? = nil, problem: String? = nil) {
        guard let owner, let initial = fields ?? Self.linkFields(source) else { return }
        let alert = NSAlert(); alert.messageText = "Edit Link"
        alert.informativeText = problem ?? Self.linkHelp
        if problem != nil { alert.alertStyle = .warning }
        let label = NSTextField(string: initial.label), address = NSTextField(string: initial.address)
        for field in [label, address] { field.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Label"), label], [NSTextField(labelWithString: "Link"), address]])
        grid.rowSpacing = 8; grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = label
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if let problem = owner.setLink(row, at: location, source: source, label: label.stringValue, address: address.stringValue) {
                DispatchQueue.main.async { self.editLink(row, at: location, source: source, fields: (label.stringValue, address.stringValue), problem: problem) }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
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
    let nestedChild = ParkingLotRow(heading: false, text: "Child", parentID: first.id)
    let nestedRows = [heading, first, nestedChild, second]
    let nestedOutline = ParkingOutline(rows: nestedRows, collapsed: [], placeholders: &placeholders)
    let parentRange = nestedOutline.entries.first { $0.row.id == first.id }!.range
    let splitParent = nestedOutline.replacing(NSRange(location: NSMaxRange(parentRange), length: 0), with: "\n", rows: nestedRows)!
    check(Array(splitParent.rows.map(\.id).prefix(3)) == [heading.id, first.id, nestedChild.id]
          && splitParent.rows[3].id == splitParent.caretID
          && (try? ParkingLotTree.nodes(splitParent.rows)) != nil,
          "Return on a parent places its new sibling after the existing children")
    let foldedNested = ParkingOutline(rows: nestedRows, collapsed: [first.id], placeholders: &placeholders)
    let foldedParent = foldedNested.entries.first { $0.row.id == first.id }!.range
    let followingSibling = foldedNested.entries.first { $0.row.id == second.id }!.range
    let removedParent = foldedNested.replacing(NSRange(location: foldedParent.location,
        length: followingSibling.location - foldedParent.location), with: "", rows: nestedRows)!
    check(removedParent.rows.map(\.id) == [heading.id, second.id],
          "Deleting a collapsed parent removes its hidden children")
    let blankOutline = ParkingOutline(rows: afterItem.rows, collapsed: [], placeholders: &placeholders)
    check(blankOutline.entries.contains { $0.row.id == afterItem.caretID && !$0.placeholder } && blankOutline.entries.filter { $0.placeholder && !$0.row.heading }.count == 2,
          "A real blank Return item coexists with each section's New item input")
    let illustrated = [ParkingLotRow(heading: false, text: "First", images: ["a.png"]), ParkingLotRow(heading: false, text: "Second", images: ["b.png"])]
    let illustratedOutline = ParkingOutline(rows: illustrated, collapsed: [], placeholders: &placeholders)
    let joined = illustratedOutline.replacing(NSRange(location: 5, length: 1), with: "", rows: illustrated)!
    check(joined.rows[0].text == "FirstSecond" && joined.rows[0].images == ["a.png", "b.png"], "Joining items with Backspace preserves both sets of images")
    do {
        let h = ParkingLotRow(heading: true, text: "Heading")
        let a = ParkingLotRow(heading: false, text: "A", parentID: h.id)
        let ac = ParkingLotRow(heading: false, text: "A child", parentID: a.id)
        let b = ParkingLotRow(heading: false, text: "B", notes: [.init(author: "Test", text: "B note")], parentID: h.id)
        let bc = ParkingLotRow(heading: false, text: "B child", parentID: b.id)
        let bg = ParkingLotRow(heading: false, text: "B grandchild", parentID: bc.id)
        func merge(_ rows: [ParkingLotRow], after id: UUID, collapsed: Set<UUID> = []) -> ParkingOutline.Edit? {
            var placeholders: [String: UUID] = [:]
            let projection = ParkingOutline(rows: rows, collapsed: collapsed, placeholders: &placeholders)
            let entry = projection.entries.first { $0.row.id == id }!
            return projection.replacing(NSRange(location: NSMaxRange(entry.range), length: 1), with: "", rows: rows)
        }
        for collapsed: Set<UUID> in [[], [b.id]] {
            let joined = merge([h, a, b, bc, bg], after: a.id, collapsed: collapsed)!
            let hierarchy = try ParkingLotTree.nodes(joined.rows)
            check(joined.rows.map(\.id) == [h.id, a.id, bc.id, bg.id] && hierarchy[bc.id]?.parentID == a.id
                  && hierarchy[bg.id]?.parentID == bc.id && joined.rows[1].notes == b.notes,
                  "Separator merge keeps expanded or collapsed descendants and comments")
        }
        let bothFolded = merge([h, a, ac, b, bc, bg], after: a.id, collapsed: [a.id, b.id])!
        check(bothFolded.rows.map(\.id) == [h.id, a.id, ac.id, bc.id, bg.id]
              && bothFolded.rows[3].parentID == a.id && (try? ParkingLotTree.nodes(bothFolded.rows)) != nil,
              "Merging two collapsed parents keeps both subtrees in preorder")
        let childMerge = merge([h, b, bc, bg], after: b.id)!
        check(childMerge.rows.map(\.id) == [h.id, b.id, bg.id] && childMerge.rows[2].parentID == b.id,
              "Merging parent with first child reparents its grandchildren")
        var empty = a; empty.text = ""
        let emptyMerge = merge([h, empty, b, bc], after: empty.id)!
        check(emptyMerge.rows[1].id == a.id && emptyMerge.rows[1].text == "B" && emptyMerge.rows[2].parentID == a.id,
              "An empty first row survives a separator merge with descendants")
        let otherHeading = ParkingLotRow(heading: true, text: "Other")
        check(merge([h, a, otherHeading], after: h.id, collapsed: [h.id]) == nil,
              "Merging collapsed sections is refused")
        var chain = [h, a]
        for depth in 2...ParkingLotTree.maximumDepth {
            chain.append(ParkingLotRow(heading: false, text: "Depth \(depth)", parentID: chain.last!.id))
        }
        let deepest = chain.last!.id
        check(merge(chain + [b, bc], after: deepest) == nil,
              "A merge that would reparent descendants beyond the depth cap is refused")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-lot-merge-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ParkingLotStore(folder: home)
        store.openStarter([h, a, ac, b, bc, bg])
        let before = store.document
        try store.replaceUserRows(bothFolded.rows, revision: before.revision)
        check(ParkingLotStore(folder: home).document.rows == bothFolded.rows, "Merged descendants persist across reopening")
        store.undoManager.undo()
        check(store.document.rows == before.rows, "Undo restores both original subtrees after a separator merge")
        store.undoManager.redo()
        check(store.document.rows == bothFolded.rows, "Redo restores the complete merged subtree")
        store.delete(a.id)
        check(store.document.rows.map(\.id) == [h.id], "Explicit Delete still removes the entire merged subtree")
    } catch { check(false, "Separator subtree merge tests: " + error.localizedDescription) }
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
    let mergeLot = ParkingLotStore(folder: folder.appendingPathComponent("native-merges"))
    let mergeHeading = ParkingLotRow(heading: true, text: "Native")
    let survivor = ParkingLotRow(heading: false, text: "First", parentID: mergeHeading.id)
    let blankParent = ParkingLotRow(heading: false, text: "", parentID: mergeHeading.id)
    let keptChild = ParkingLotRow(heading: false, text: "Keep me", parentID: blankParent.id)
    mergeLot.openStarter([mergeHeading, survivor, blankParent, keptChild])
    let mergeBefore = mergeLot.document.rows
    let mergeCoordinator = ParkingLotEditor.Coordinator(ParkingLotEditor(lot: mergeLot, collapsed: .constant([blankParent.id]), reorder: {}))
    let mergeText = ParkingOutlineText(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    mergeText.isRichText = false; mergeText.owner = mergeCoordinator; mergeText.delegate = mergeCoordinator
    mergeCoordinator.text = mergeText; mergeCoordinator.render()
    let blankRange = mergeCoordinator.projection.entries.first { $0.row.id == blankParent.id }!.range
    mergeText.setSelectedRange(NSRange(location: blankRange.location, length: 0))
    mergeText.deleteBackward(nil)
    check(mergeLot.document.rows.map(\.id) == [mergeHeading.id, survivor.id, keptChild.id]
          && mergeLot.document.rows.last?.parentID == survivor.id,
          "Native Backspace on a blank collapsed parent preserves and reparents its children")
    mergeText.undo(nil)
    check(mergeLot.document.rows == mergeBefore, "Native Undo restores the blank parent and descendants")
    let cutBoard = NSPasteboard.withUniqueName()
    defer { cutBoard.releaseGlobally() }
    mergeCoordinator.copyEntry(blankParent.id, cut: true, board: cutBoard)
    check(mergeLot.document.rows.map(\.id) == [mergeHeading.id, survivor.id],
          "Native Cut Item removes the blank parent and its hidden descendants")
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
    let readText = store.parkingLotCommand(read, session: session, lot: lot)
    check(readText.contains("Another writer"), "An ordinary taught session can read Parking Lot without an agent scope setting")
    check(readText.contains(Store.parkingLotReadGuide), "Every Parking Lot read carries the nesting guide, so sessions taught before nesting edit correctly")
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
    check((attribute(.font, 24) as? NSFont)?.pointSize ?? 13 < 1 && attribute(.link, 25) != nil, "Moving the caret into a row keeps its Markdown hidden and the label clickable")
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
    parkingDropSelfTests(check)
    parkingAtomicLinkSelfTests(check)
}

// Drives the drop path NSTextView uses for Finder drags, in a real window.
private final class TestDrop: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard; let draggingLocation: NSPoint; weak var draggingDestinationWindow: NSWindow?
    init(_ board: NSPasteboard, at point: NSPoint, in window: NSWindow) { draggingPasteboard = board; draggingLocation = point; draggingDestinationWindow = window }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

func parkingDropSelfTests(_ check: (Bool, String) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parking-drop-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lot = ParkingLotStore(folder: folder); lot.open()
    let coordinator = ParkingLotEditor.Coordinator(ParkingLotEditor(lot: lot, collapsed: .constant([]), reorder: {}))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let text = ParkingOutlineText(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    text.isRichText = false; text.allowsUndo = true; text.owner = coordinator; text.delegate = coordinator; coordinator.text = text
    window.contentView = text; coordinator.render(); window.makeFirstResponder(text)
    let item = lot.document.rows[1].id
    func entry() -> ParkingOutline.Entry { coordinator.projection.entries.first { $0.row.id == item }! }
    func row() -> String { lot.document.rows.first { $0.id == item }!.text }
    func linked(_ offset: Int) -> URL? { text.textStorage?.attribute(.link, at: entry().range.location + offset, effectiveRange: nil) as? URL }
    // The display must match the saved rows, and only Markdown syntax may use the hidden font.
    func cleanDisplay() -> Bool {
        guard let storage = text.textStorage, storage.string == coordinator.projection.string else { return false }
        var syntax = IndexSet()
        for entry in coordinator.projection.entries {
            for link in LotLinks.find(in: entry.row.text) where link.isMarkdown {
                syntax.insert(integersIn: entry.range.location + link.range.location ..< entry.range.location + link.label.location)
                syntax.insert(integersIn: entry.range.location + NSMaxRange(link.label) ..< entry.range.location + NSMaxRange(link.range))
            }
        }
        var clean = true
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let font = value as? NSFont, font.pointSize < 1, !syntax.contains(integersIn: range.location ..< NSMaxRange(range)) { clean = false }
        }
        return clean
    }
    func drop(_ objects: [NSPasteboardWriting]) -> Bool {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.clearContents(); board.writeObjects(objects)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let end = text.firstRect(forCharacterRange: NSRange(location: NSMaxRange(entry().range), length: 0), actualRange: nil)
        let info = TestDrop(board, at: window.convertPoint(fromScreen: NSPoint(x: end.maxX + 1, y: end.midY)), in: window)
        guard text.draggingEntered(info).contains(.copy), text.prepareForDragOperation(info) else { return false }
        let result = text.performDragOperation(info); text.concludeDragOperation(info)
        return result
    }
    // Paste: a complete URL is a link at once, even with the caret right after it.
    lot.update(item, text: "Pasted "); coordinator.render(caret: (item, 7))
    let paste = NSPasteboard.withUniqueName(); paste.clearContents(); paste.setString("https://x.com/a", forType: .string)
    text.paste(from: paste); paste.releaseGlobally()
    check(row() == "Pasted https://x.com/a" && linked(8) == URL(string: "https://x.com/a") && cleanDisplay(), "Pasting a URL styles it as a link immediately")
    // Finder drop: files become Markdown links rendered as their filenames, spaces included.
    let spaced = URL(fileURLWithPath: "/Users/me/Downloads/KAOS Labs Logo.png"), plain = URL(fileURLWithPath: "/Users/me/Desktop/converse.jpeg")
    lot.update(item, text: "Logo is with "); coordinator.render(caret: (item, 13))
    let before = lot.document.rows
    check(drop([spaced as NSURL, plain as NSURL]), "Dropping files on a Parking Lot row is accepted")
    let expected = "Logo is with [KAOS Labs Logo.png](file:///Users/me/Downloads/KAOS%20Labs%20Logo.png), [converse.jpeg](file:///Users/me/Desktop/converse.jpeg)"
    check(row() == expected && lot.document.rows.count == before.count, "Dropped files insert one Markdown link per file in the same row, separated by commas")
    let links = LotLinks.find(in: row())
    let hidden = (text.textStorage?.attribute(.font, at: entry().range.location + NSMaxRange(links[0].label), effectiveRange: nil) as? NSFont)?.pointSize ?? 13
    check(links.count == 2 && linked(links[0].label.location)?.path == spaced.path && linked(NSMaxRange(links[0].label) - 1)?.path == spaced.path
          && linked(links[1].label.location)?.path == plain.path && linked(links[0].range.location) == nil && hidden < 1 && cleanDisplay(),
          "Dropped file links render immediately as clickable filenames with the path hidden")
    check(text.selectedRange() == NSRange(location: NSMaxRange(entry().range), length: 0), "The caret follows the dropped links")
    text.undo(nil)
    check(row() == "Logo is with /Users/me/Downloads/KAOS Labs Logo.png, /Users/me/Desktop/converse.jpeg" && cleanDisplay(), "One Undo after a drop restores the plain paths")
    text.undo(nil)
    check(lot.document.rows == before && cleanDisplay(), "A second Undo removes the drop entirely")
    check(drop([plain as NSURL]) && row() == "Logo is with [converse.jpeg](file:///Users/me/Desktop/converse.jpeg)", "Dropping one file inserts its link")
    text.deleteBackward(nil)
    check(row() == "Logo is with /Users/me/Desktop/converse.jpeg", "Backspace right after a drop restores the plain path")
    text.deleteBackward(nil)
    check(row() == "Logo is with /Users/me/Desktop/converse.jpe", "A second Backspace deletes normally")
    // The revert only applies straight after the drop; later, Backspace removes the whole link.
    lot.update(item, text: "Logo is with "); coordinator.render(caret: (item, 13))
    check(drop([plain as NSURL]), "Dropping a file again inserts its link")
    text.insertText("x", replacementRange: text.selectedRange()); text.deleteBackward(nil); text.deleteBackward(nil)
    check(row() == "Logo is with ", "After typing, Backspace after a dropped link deletes the whole link instead of reverting it")
    // Text dragged in from another app still uses NSTextView's drop, inside an Undo group.
    lot.update(item, text: "Dragged "); coordinator.render(caret: (item, 8))
    check(drop(["https://y.com/z" as NSString]) && row() == "Dragged https://y.com/z" && linked(9) == URL(string: "https://y.com/z") && cleanDisplay(), "Dropped text is inserted and its links style immediately")
    text.undo(nil)
    check(row() == "Dragged ", "Undo removes dropped text")
    window.close()
}

// Markdown links edit as one piece in a real window: never raw, never entered by accident.
func parkingAtomicLinkSelfTests(_ check: (Bool, String) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parking-atomic-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lot = ParkingLotStore(folder: folder); lot.open()
    let coordinator = ParkingLotEditor.Coordinator(ParkingLotEditor(lot: lot, collapsed: .constant([]), reorder: {}))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let text = ParkingOutlineText(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    text.isRichText = false; text.allowsUndo = true; text.owner = coordinator; text.delegate = coordinator; coordinator.text = text
    window.contentView = text; coordinator.render(); window.makeFirstResponder(text)
    let heading = lot.document.rows[0].id, item = lot.document.rows[1].id
    func entry() -> ParkingOutline.Entry { coordinator.projection.entries.first { $0.row.id == item }! }
    func row() -> String { lot.document.rows.first { $0.id == item }!.text }
    // What is drawn: the row without characters set in the hidden font.
    func visible() -> String {
        guard let storage = text.textStorage else { return "" }
        var shown = ""
        storage.enumerateAttribute(.font, in: entry().range) { value, run, _ in
            if ((value as? NSFont)?.pointSize ?? 13) >= 1 { shown += (storage.string as NSString).substring(with: run) }
        }
        return shown
    }
    func linkRuns() -> [NSRange] {
        var runs: [NSRange] = []
        text.textStorage?.enumerateAttribute(.link, in: entry().range) { value, run, _ in
            if value != nil { runs.append(NSRange(location: run.location - entry().range.location, length: run.length)) }
        }
        return runs
    }
    func caret() -> Int { text.selectedRange().location - entry().range.location }
    func place(_ offset: Int, _ length: Int = 0) { text.setSelectedRange(NSRange(location: entry().range.location + offset, length: length)) }
    func point(_ offset: Int) -> NSPoint {
        text.layoutManager!.ensureLayout(for: text.textContainer!)
        let glyphs = text.layoutManager!.glyphRange(forCharacterRange: NSRange(location: entry().range.location + offset, length: 1), actualCharacterRange: nil)
        let rect = text.layoutManager!.boundingRect(forGlyphRange: glyphs, in: text.textContainer!)
        return NSPoint(x: rect.midX + text.textContainerOrigin.x, y: rect.midY + text.textContainerOrigin.y)
    }
    let address = "file:///Users/x/KAOS%20Labs%20Logo.png"
    let source = "[KAOS Labs Logo.png](" + address + ")"
    let stored = "see " + source
    let a = 4, b = 4 + (source as NSString).length
    lot.update(item, text: stored); coordinator.render(caret: (heading, 0))
    check(visible() == "see KAOS Labs Logo.png" && linkRuns() == [NSRange(location: 5, length: 18)], "A row without the caret shows only the link label")
    // Richard's scenario: click to the right of the line's end, then type a space.
    text.layoutManager!.ensureLayout(for: text.textContainer!)
    let line = text.layoutManager!.lineFragmentUsedRect(forGlyphAt: text.layoutManager!.glyphIndexForCharacter(at: entry().range.location), effectiveRange: nil)
    place(text.characterIndexForInsertion(at: NSPoint(x: text.textContainerOrigin.x + line.maxX + 40, y: text.textContainerOrigin.y + line.midY)) - entry().range.location)
    coordinator.refreshLinks()
    check(caret() == b && visible() == "see KAOS Labs Logo.png" && linkRuns() == [NSRange(location: 5, length: 18)], "The row holding the caret shows only link labels")
    check(((text.typingAttributes[.font] as? NSFont)?.pointSize ?? 0) == 13, "The caret after a link keeps the normal text size")
    text.insertText(" ", replacementRange: text.selectedRange())
    check(row() == stored + " " && visible() == "see KAOS Labs Logo.png " && linkRuns() == [NSRange(location: 5, length: 18)] && caret() == b + 1,
          "Clicking right of a line ending in a link and typing a space neither reveals nor restyles its Markdown")
    // The caret never stops inside hidden syntax or the label without Option-click.
    var stops = Set<Int>()
    for offset in a + 1 ..< b { place(0); place(offset); stops.insert(caret()) }
    check(stops.isSubset(of: [a, b]), "A caret placed inside a link moves to the link's edge")
    place(b); text.moveLeft(nil)
    check(caret() == a, "Left arrow after a link crosses the whole link")
    text.moveRight(nil)
    check(caret() == b, "Right arrow before a link crosses the whole link")
    place(a); text.moveRightAndModifySelection(nil)
    check(text.selectedRange() == NSRange(location: entry().range.location + a, length: b - a), "Extending a selection into a link selects the whole link")
    place(0); place(2, 6)
    check(text.selectedRange() == NSRange(location: entry().range.location + 2, length: b - 2), "A selection that ends inside a link grows to cover it")
    // Backspace and Delete remove the link in one step; Undo restores it.
    place(b); text.deleteBackward(nil)
    check(row() == "see  " && caret() == a, "Backspace right after a link deletes the whole link")
    text.undo(nil)
    check(row() == stored + " " && visible() == "see KAOS Labs Logo.png ", "Undo restores a link deleted with Backspace")
    place(a); text.deleteForward(nil)
    check(row() == "see  ", "Delete right before a link deletes the whole link")
    text.undo(nil)
    place(b); text.insertText("!", replacementRange: text.selectedRange())
    check(row() == stored + "! " && linkRuns() == [NSRange(location: 5, length: 18)], "Typing straight after a link does not extend it")
    text.undo(nil)
    // Copy gives other apps the label; a Parking Lot paste keeps the link.
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    place(0, (stored as NSString).length)
    text.copySelection(to: board)
    check(board.string(forType: .string) == "see KAOS Labs Logo.png" && board.string(forType: ParkingOutlineText.markdownType) == stored, "Copying a link copies its label as plain text and keeps the Markdown for Parking Lots")
    place(0, 0); text.paste(from: board)
    check(row() == stored + stored + " ", "Pasting a copied link back into a Parking Lot keeps the link")
    text.undo(nil)
    // Option-click opens the label for editing in place.
    let optionClick = NSEvent.mouseEvent(with: .leftMouseDown, location: text.convert(point(a + 3), to: nil), modifierFlags: .option, timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    text.mouseDown(with: optionClick)
    let opened = caret()
    check(opened > a && opened <= a + 1 + 18 && coordinator.labelEditing != nil, "Option-click places the caret inside a link's label")
    text.insertText("X", replacementRange: text.selectedRange())
    let renamed = "see [" + (("KAOS Labs Logo.png" as NSString).replacingCharacters(in: NSRange(location: opened - a - 1, length: 0), with: "X")) + "](" + address + ") "
    check(row() == renamed && caret() == opened + 1 && linkRuns() == [NSRange(location: 5, length: 19)], "Typing in an opened label edits the label and keeps the link")
    text.undo(nil); place(0)
    check(coordinator.labelEditing == nil, "Moving the caret away closes the opened label")
    // Right-click offers link editing.
    func menu(at offset: Int) -> [String] {
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: text.convert(point(offset), to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        return text.menu(for: event)?.items.map(\.title) ?? []
    }
    let titles = menu(at: a + 3)
    check(titles.prefix(3) == ["Edit Link…", "Remove Link", "Copy Link Address"] && !menu(at: 1).contains("Edit Link…"), "Right-clicking a link offers Edit Link, Remove Link and Copy Link Address")
    check(ParkingOutlineText.linkFields(source).map { [$0.label, $0.address] } == ["KAOS Labs Logo.png", address] && ParkingOutlineText.linkHelp.contains("Option-click"),
          "Edit Link shows the label and address and explains Option-click")
    check(coordinator.setLink(item, at: a, source: source, label: "javascript:alert(1)", address: "javascript:alert(1)") != nil && row() == stored + " ", "Edit Link refuses other schemes")
    check(coordinator.setLink(item, at: a, source: source, label: "Logo", address: "https://example.com/a b") == nil && row() == "see [Logo](https://example.com/a%20b) "
          && visible() == "see Logo ", "Edit Link changes the label and address")
    text.undo(nil)
    check(row() == stored + " ", "Undo restores a link changed with Edit Link")
    coordinator.removeLink(item, at: a, source: source)
    check(row() == "see KAOS Labs Logo.png " && linkRuns().isEmpty, "Remove Link keeps the label as plain text")
    text.undo(nil)
    ParkingOutlineText.copyLinkAddress(LotLinks.find(in: stored)[0].url, to: board)
    check(board.string(forType: .string) == address, "Copy Link Address copies the link's URL")
    // Bare URLs are their own label and stay ordinary text.
    lot.update(item, text: "go https://x.com/a"); coordinator.render(caret: (item, 6))
    check(caret() == 6 && visible() == "go https://x.com/a" && linkRuns().isEmpty, "A caret can sit inside a bare URL being edited")
    place(0)
    check(linkRuns() == [NSRange(location: 3, length: 15)] && visible() == "go https://x.com/a", "Bare URLs style as before once the caret leaves them")
    let bareMenu = menu(at: 5)
    check(!bareMenu.contains("Remove Link") && bareMenu.contains("Edit Link…") && bareMenu.contains("Copy Link Address"), "Bare URLs offer Edit Link and Copy Link Address without Remove Link")
    window.close()
}
