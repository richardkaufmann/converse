import AppKit
import Combine
import SwiftUI

// Find and replace over the rows themselves, not the display: collapsed
// sections are searched too, and replacing is an ordinary user edit of the rows.
enum ParkingLotFind {
    struct Match: Equatable { var row: UUID; var range: NSRange }
    /// Matches in visible text only; hidden link syntax and emphasis markers never match.
    static func matches(_ query: String, in rows: [ParkingLotRow], caseSensitive: Bool = false) -> [Match] {
        guard !query.isEmpty else { return [] }
        var results: [Match] = []
        let options: NSString.CompareOptions = caseSensitive ? [] : .caseInsensitive
        for row in rows {
            let source = row.text as NSString
            let hidden = hiddenSyntax(in: row.text)
            var searched = NSRange(location: 0, length: source.length)
            while searched.length > 0 {
                let found = source.range(of: query, options: options, range: searched)
                guard found.location != NSNotFound, found.length > 0 else { break }
                if !hidden.contains(where: { NSIntersectionRange($0, found).length > 0 }) { results.append(Match(row: row.id, range: found)) }
                let next = NSMaxRange(found)
                searched = NSRange(location: next, length: source.length - next)
            }
        }
        return results
    }
    /// The parts of a Markdown link that are never shown: brackets and address.
    static func hiddenSyntax(in text: String) -> [NSRange] {
        LotLinks.find(in: text).filter(\.isMarkdown).flatMap { link -> [NSRange] in
            [NSRange(location: link.range.location, length: link.label.location - link.range.location),
             NSRange(location: NSMaxRange(link.label), length: NSMaxRange(link.range) - NSMaxRange(link.label))]
        } + (TextSubstitutions.shared.enabled ? LotInline.delimiters(in: text) : [])
    }
    static func replacing(_ targets: [Match], with replacement: String, in rows: [ParkingLotRow]) -> [ParkingLotRow] {
        let byRow = Dictionary(grouping: targets, by: \.row)
        return rows.map { row in
            guard let matches = byRow[row.id] else { return row }
            var row = row
            let source = NSMutableString(string: row.text)
            for match in matches.sorted(by: { $0.range.location > $1.range.location }) where NSMaxRange(match.range) <= source.length {
                source.replaceCharacters(in: match.range, with: replacement)
            }
            row.text = source as String; row.editedBy = nil
            return row
        }
    }
}

final class ParkingLotFinder: ObservableObject {
    @Published private(set) var visible = false
    @Published var showsReplace = false
    @Published var query = "" { didSet { if query != oldValue { refresh(fromCaret: true) } } }
    @Published var replacement = ""
    @Published var caseSensitive = false { didSet { if caseSensitive != oldValue { refresh(fromCaret: true) } } }
    @Published private(set) var matches: [ParkingLotFind.Match] = []
    @Published private(set) var current: Int?
    @Published private(set) var focusRequest = 0
    weak var editor: ParkingLotEditor.Coordinator?
    // Counted by the idle self-test: an open bar must not do this work unprompted.
    private(set) var refreshes = 0, scans = 0
    /// Everything the matches are computed from; while it holds, they are still right.
    private struct Scan: Equatable { var query: String; var caseSensitive: Bool; var substitutions: Bool; var rows: [ParkingLotRow] }
    private var scanned: Scan?
    private var substitutionsObserver: AnyCancellable?
    init() {
        // Turning substitutions on or off changes which markers can match, and
        // nothing else re-renders. $enabled fires before the value changes.
        substitutionsObserver = TextSubstitutions.shared.$enabled.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.editorRendered() }
    }
    var canReplace: Bool { editor?.canEditText == true }
    var status: String {
        if query.isEmpty { return "" }
        guard let current else { return matches.isEmpty ? "Not found" : "\(matches.count) found" }
        return "\(current + 1) of \(matches.count)"
    }
    /// Opens the bar, seeded with a single-line selection like the standard Find panel.
    func open() {
        visible = true; focusRequest += 1
        if let selected = editor?.selectedFindText, !selected.isEmpty { query = selected } else { refresh(fromCaret: true) }
        editor?.applyFindHighlights()
    }
    func close() {
        visible = false; select(nil)
        editor?.clearFindHighlights()
    }
    private func rows() -> [ParkingLotRow] { editor?.parent.lot.document.rows ?? [] }
    /// Recomputes the matches; a save elsewhere can move or remove the current one.
    /// Publishes only real changes, since each publication updates the pane and comes back here.
    func refresh(fromCaret: Bool = false) {
        refreshes += 1
        let previous = current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        let scan = Scan(query: query, caseSensitive: caseSensitive, substitutions: TextSubstitutions.shared.enabled, rows: rows())
        if scan != scanned {
            scans += 1; scanned = scan
            let found = ParkingLotFind.matches(query, in: scan.rows, caseSensitive: caseSensitive)
            if found != matches { matches = found }
        }
        if fromCaret, let caret = editor?.findCaret { select(index(atOrAfter: caret)) }
        else if let previous, let same = matches.firstIndex(of: previous) { select(same) }
        else { select(matches.isEmpty ? nil : min(current ?? 0, matches.count - 1)) }
        editor?.applyFindHighlights()
    }
    private func select(_ index: Int?) { if index != current { current = index } }
    /// The first match at or after a position in the rows, wrapping to the first.
    private func index(atOrAfter position: (UUID, Int)) -> Int? {
        guard !matches.isEmpty else { return nil }
        let order = Dictionary(rows().enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let target = order[position.0] ?? 0
        return matches.firstIndex { (order[$0.row] ?? 0, $0.range.location) >= (target, position.1) } ?? 0
    }
    /// Called after each render while the bar is open.
    func editorRendered() {
        guard visible else { return }
        refresh()
    }
    func next() { advance(by: 1) }
    func previous() { advance(by: -1) }
    private func advance(by step: Int) {
        guard visible, !matches.isEmpty else { NSSound.beep(); return }
        select(current.map { ($0 + step + matches.count) % matches.count } ?? (step > 0 ? 0 : matches.count - 1))
        showCurrent()
    }
    private func showCurrent() {
        guard let current, matches.indices.contains(current) else { return }
        editor?.showFindMatch(matches[current])
    }
    /// Replaces the current match, then moves on to the next one after it.
    @discardableResult func replaceCurrent() -> Bool {
        guard canReplace, let editor, let index = current, matches.indices.contains(index) else { NSSound.beep(); return false }
        let match = matches[index]
        let rows = ParkingLotFind.replacing([match], with: replacement, in: editor.parent.lot.document.rows)
        let after = match.range.location + (replacement as NSString).length
        guard editor.saveFindResult(rows, undoName: "Replace", caret: (match.row, after)) else { return false }
        refresh()
        select(self.index(atOrAfter: (match.row, after)))
        showCurrent()
        return true
    }
    /// One edit of every match, so one Undo reverses all of them.
    @discardableResult func replaceAll() -> Int {
        guard canReplace, let editor, !matches.isEmpty else { NSSound.beep(); return 0 }
        let count = matches.count
        let rows = ParkingLotFind.replacing(matches, with: replacement, in: editor.parent.lot.document.rows)
        guard editor.saveFindResult(rows, undoName: "Replace All", caret: nil) else { return 0 }
        refresh()
        return count
    }
}

struct ParkingLotFindBar: View {
    @ObservedObject var finder: ParkingLotFinder
    @FocusState private var findFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if finder.canReplace {
                    Button { finder.showsReplace.toggle() } label: { Image(systemName: finder.showsReplace ? "chevron.down" : "chevron.right").frame(width: 12) }
                        .buttonStyle(.borderless).help(finder.showsReplace ? "Hide Replace" : "Show Replace")
                        .accessibilityLabel(finder.showsReplace ? "Hide Replace" : "Show Replace")
                }
                TextField("Find", text: $finder.query).textFieldStyle(.roundedBorder).focused($findFocused).onSubmit { finder.next() }
                Text(finder.status).font(.caption).foregroundStyle(.secondary).fixedSize()
                Button { finder.previous() } label: { Image(systemName: "chevron.up") }.keyboardShortcut("g", modifiers: [.command, .shift]).help("Find Previous").accessibilityLabel("Find Previous")
                Button { finder.next() } label: { Image(systemName: "chevron.down") }.keyboardShortcut("g", modifiers: .command).help("Find Next").accessibilityLabel("Find Next")
                Menu {
                    Toggle("Match Case", isOn: $finder.caseSensitive)
                    if finder.canReplace { Toggle("Show Replace", isOn: $finder.showsReplace) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Find options")
                Button("Done") { finder.close() }.keyboardShortcut(.cancelAction)
                // ⌘F while the bar is open returns to the search field.
                Button("") { findFocused = true }.keyboardShortcut("f", modifiers: .command).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
            if finder.showsReplace && finder.canReplace {
                HStack(spacing: 6) {
                    TextField("Replace", text: $finder.replacement).textFieldStyle(.roundedBorder).onSubmit { finder.replaceCurrent() }
                    Button("Replace") { finder.replaceCurrent() }.disabled(finder.current == nil)
                    Button("Replace All") { finder.replaceAll() }.disabled(finder.matches.isEmpty)
                }
            }
        }.controlSize(.small).padding(.horizontal, 8).padding(.vertical, 4)
        .onChange(of: finder.focusRequest) { _, _ in findFocused = true }
        .onAppear { findFocused = true }
    }
}

func parkingFindSelfTests(_ check: (Bool, String) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lot-find-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let h = ParkingLotRow(heading: true, text: "Launch plan"), a = ParkingLotRow(heading: false, text: "Plan the plan", parentID: h.id)
    let nested = ParkingLotRow(heading: false, text: "A nested PLAN item", parentID: a.id)
    let linked = ParkingLotRow(heading: false, text: "See [plan](https://plan.example.com/plan) today", parentID: h.id)
    let other = ParkingLotRow(heading: true, text: "Elsewhere"), far = ParkingLotRow(heading: false, text: "Nothing here", parentID: other.id)
    let rows = [h, a, nested, linked, other, far]
    check(ParkingLotFind.matches("plan", in: rows).count == 5 && ParkingLotFind.matches("plan", in: rows, caseSensitive: true).count == 3,
          "Find is case-insensitive by default and can match case")
    check(ParkingLotFind.matches("https", in: rows).isEmpty && ParkingLotFind.matches("today", in: rows).map(\.row) == [linked.id],
          "Find matches a link's visible label, never its hidden address")
    check(ParkingLotFind.matches("", in: rows).isEmpty, "An empty search finds nothing")
    let emoji = [ParkingLotRow(heading: false, text: "🦊 fox 🦊 fox")]
    check(ParkingLotFind.matches("fox", in: emoji).map(\.range.location) == [3, 10], "Find ranges use UTF-16 offsets like the editor")
    let lot = ParkingLotStore(folder: folder.appendingPathComponent("lot"), id: UUID())
    lot.openStarter(rows)
    var collapsed: Set<UUID> = [a.id, other.id]
    let finder = ParkingLotFinder()
    let coordinator = ParkingLotEditor.Coordinator(ParkingLotEditor(lot: lot, collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }), reorder: {}, finder: finder))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let text = ParkingOutlineText(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    text.isRichText = false; text.owner = coordinator; text.delegate = coordinator; coordinator.text = text; window.contentView = text; coordinator.render()
    func entry(_ id: UUID) -> ParkingOutline.Entry { coordinator.projection.entries.first { $0.row.id == id }! }
    func menu(_ action: NSTextFinder.Action) -> NSMenuItem { let item = NSMenuItem(title: "", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: ""); item.tag = Int(action.rawValue); return item }
    let findItem = menu(.showFindInterface)
    check(text.validateUserInterfaceItem(findItem), "Edit > Find is available in a Parking Lot")
    text.setSelectedRange(NSRange(location: 0, length: 0))
    text.performTextFinderAction(findItem)
    finder.query = "plan"
    check(finder.visible && finder.matches.count == 5 && finder.status == "1 of 5", "Command-F opens the bar and reports the match count: " + finder.status)
    check(!coordinator.projection.entries.contains { $0.row.id == nested.id }, "The match in the collapsed row is counted while it stays hidden")
    finder.next(); finder.next(); finder.next()
    check(collapsed.isEmpty == false && !collapsed.contains(a.id) && coordinator.projection.entries.contains { $0.row.id == nested.id } && finder.status == "4 of 5", "Moving onto a match inside a collapsed section opens it")
    let shown = finder.matches[finder.current!]
    let selected = text.selectedRange(), expected = NSRange(location: entry(shown.row).range.location + shown.range.location, length: shown.range.length)
    check(selected == expected, "Next selects the match in the text")
    finder.next(); finder.next()
    check(finder.status == "1 of 5", "Next wraps around at the end")
    finder.previous()
    check(finder.status == "5 of 5", "Previous wraps around at the start")
    text.performTextFinderAction(menu(.nextMatch))
    check(finder.status == "1 of 5", "Find Next from the menu moves to the next match")
    finder.replacement = "PROJECT"
    let before = lot.document.rows
    check(finder.replaceCurrent(), "Replace changes the current match")
    let afterOne = lot.document
    let changed = afterOne.rows.filter { row in before.first { $0.id == row.id }?.text != row.text }
    check(changed.count == 1 && changed[0].text.contains("PROJECT") && lot.undoManager.undoActionName == "Replace" && finder.matches.count == 4 && coordinator.displayed == lot.document,
          "Replace edits one row through the saved rows and moves on to the next match")
    check(ParkingLotRenderSignature(text, coordinator).text == coordinator.projection.string, "The display follows a replacement")
    text.undo(nil)
    check(lot.document.rows == before && finder.matches.count == 5, "Undo restores a replacement and the matches")
    finder.replaceAll()
    check(lot.document.rows.allSatisfy { !$0.text.lowercased().contains("plan") || $0.id == linked.id } && lot.undoManager.undoActionName == "Replace All", "Replace All changes every visible match in one edit")
    check(lot.document.rows.first { $0.id == linked.id }?.text == "See [PROJECT](https://plan.example.com/plan) today", "Replace All leaves a hidden link address alone")
    check(ParkingLotStore(folder: folder.appendingPathComponent("lot"), id: lot.id).document == lot.document, "Replacements are saved to disk")
    let incremental = ParkingLotRenderSignature(text, coordinator)
    coordinator.discardDisplayedState(); coordinator.render()
    check(incremental == ParkingLotRenderSignature(text, coordinator), "Incremental display equals a full render after Replace All")
    text.undo(nil)
    check(lot.document.rows == before, "One Undo reverses Replace All entirely")
    text.redo(nil); text.undo(nil)
    try? lot.apply(.init(revision: lot.document.revision, operations: [.init(action: "update", id: far.id, text: "Another plan arrives")]), author: "Session")
    coordinator.render()
    check(finder.matches.count == 6, "A session's edit updates the open Find bar's matches")
    finder.close()
    check(!finder.visible, "Done closes the bar")
    text.layoutManager?.ensureLayout(for: text.textContainer!)
    let noneditable = ParkingOutlineText(frame: text.frame)
    noneditable.isEditable = false
    do {
        // A read-only lot finds but never replaces.
        let readOnlyHome = folder.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: readOnlyHome, withIntermediateDirectories: true)
        let oversized = [ParkingLotRow(heading: true, text: "Recovery plan")] + (0..<500).map { ParkingLotRow(heading: false, text: "Item \($0) plan") }
        try JSONEncoder().encode(ParkingLotDocument(revision: 2, rows: oversized)).write(to: readOnlyHome.appendingPathComponent("parking-lot.json"))
        let readOnly = ParkingLotStore(folder: readOnlyHome)
        let lockedFinder = ParkingLotFinder()
        let locked = ParkingLotEditor.Coordinator(ParkingLotEditor(lot: readOnly, collapsed: .constant([]), reorder: {}, finder: lockedFinder))
        let lockedText = ParkingOutlineText(frame: text.frame); lockedText.owner = locked; lockedText.delegate = locked; locked.text = lockedText; locked.render()
        lockedFinder.open(); lockedFinder.query = "plan"; lockedFinder.replacement = "gone"
        let saved = readOnly.document
        check(readOnly.isReadOnly && lockedFinder.matches.count == 501 && !lockedFinder.canReplace, "A read-only lot finds but offers no Replace")
        check(!lockedFinder.replaceCurrent() && lockedFinder.replaceAll() == 0 && readOnly.document == saved, "Replace and Replace All are refused in a read-only lot")
    } catch { check(false, "Read-only Find fixture: " + error.localizedDescription) }
    window.close()
    parkingFindIdleSelfTests(check)
}

/// The real pane, so SwiftUI's update pass takes part: an open bar has to go quiet.
private func parkingFindIdleSelfTests(_ check: (Bool, String) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lot-find-idle-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let shared = TextSubstitutions.shared, wasEnabled = shared.enabled
    defer { try? shared.setEnabled(wasEnabled) }
    try? shared.setEnabled(true)
    let h = ParkingLotRow(heading: true, text: "Launch plan"), a = ParkingLotRow(heading: false, text: "Plan the **plan**", parentID: h.id)
    let nested = ParkingLotRow(heading: false, text: "A nested plan", parentID: a.id), other = ParkingLotRow(heading: false, text: "Nothing here", parentID: h.id)
    let lot = ParkingLotStore(folder: folder.appendingPathComponent("lot"), id: UUID())
    lot.openStarter([h, a, nested, other])
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let hosting = NSHostingView(rootView: ParkingLotView(lot: lot, workspace: Workspace(), pane: 1))
    hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 500); window.contentView = hosting
    func run(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.01)); hosting.layoutSubtreeIfNeeded() } while Date() < end
    }
    func find(_ view: NSView) -> ParkingOutlineText? { (view as? ParkingOutlineText) ?? view.subviews.lazy.compactMap(find).first }
    run(0.1)
    for _ in 0..<50 where find(hosting) == nil { run(0.02) }
    guard let text = find(hosting), let coordinator = text.owner else { check(false, "The idle Find test hosts the real Parking Lot pane"); return }
    let finder = coordinator.parent.finder
    var publications = 0
    let counting = finder.objectWillChange.sink { _ in publications += 1 }
    defer { counting.cancel() }
    /// Lets the action's own updates finish, then counts what an idle bar still does.
    /// Draining counts run-loop passes rather than elapsed time, so a loaded machine
    /// cannot land typing's delayed chrome refresh in the counted window. A bar that
    /// keeps working never drains, and that fails here.
    func expectIdle(_ label: String) {
        func counters() -> (Int, Int, Int, Int) { (publications, finder.refreshes, finder.scans, coordinator.findHighlightPasses) }
        var last = counters(), quietPasses = 0
        let deadline = Date().addingTimeInterval(20)
        while quietPasses < 25, Date() < deadline {
            run(0.01)
            if counters() != last || lot.chromeRefreshPending { last = counters(); quietPasses = 0 } else { quietPasses += 1 }
        }
        guard quietPasses >= 25 else { check(false, "An open Find bar does no work while idle after \(label): still working after 20 s"); return }
        let start = counters()
        run(0.25)
        let cycles = (publications - start.0, finder.refreshes - start.1, finder.scans - start.2, coordinator.findHighlightPasses - start.3)
        let report = "\(cycles.0) publications, \(cycles.1) refreshes, \(cycles.2) scans, \(cycles.3) highlight passes in 250 ms"
        check(cycles == (0, 0, 0, 0), "An open Find bar does no work while idle after \(label): \(report)")
    }
    func highlighted() -> [NSRange] {
        guard let manager = text.layoutManager else { return [] }
        let length = (text.string as NSString).length
        var ranges: [NSRange] = [], location = 0
        while location < length {
            var run = NSRange()
            if manager.temporaryAttribute(.backgroundColor, atCharacterIndex: location, longestEffectiveRange: &run, in: NSRange(location: 0, length: length)) != nil { ranges.append(run) }
            location = max(NSMaxRange(run), location + 1)
        }
        return ranges
    }
    func expected() -> [NSRange] {
        finder.matches.compactMap { match in
            coordinator.projection.entries.first { $0.row.id == match.row }.map { NSRange(location: $0.range.location + match.range.location, length: match.range.length) }
        }
    }
    finder.open(); finder.query = "plan"
    expectIdle("opening")
    check(finder.visible && finder.matches.count == 4 && highlighted() == expected() && highlighted().count == 4, "An open bar highlights every shown match")

    // Rendering with nothing new publishes nothing.
    var before = (publications, finder.scans)
    let passes = coordinator.findHighlightPasses
    for _ in 0..<5 { finder.editorRendered() }
    check(publications == before.0 && finder.scans == before.1 && coordinator.findHighlightPasses == passes, "Refreshing unchanged state neither publishes, rescans nor repaints")

    window.makeFirstResponder(text)
    let end = coordinator.projection.entries.first { $0.row.id == other.id }!
    text.setSelectedRange(NSRange(location: NSMaxRange(end.range), length: 0))
    text.insertText(" plan", replacementRange: text.selectedRange())
    expectIdle("typing")
    check(finder.matches.count == 5 && highlighted() == expected(), "Typing a match updates the count and highlights")

    try? lot.apply(.init(revision: lot.document.revision, operations: [.init(action: "update", id: other.id, text: "No longer")]), author: "Session")
    expectIdle("an external edit")
    check(finder.matches.count == 4 && highlighted() == expected() && highlighted().count == 4, "A session's edit updates the count and highlights")

    coordinator.toggle(a.id)
    expectIdle("collapsing")
    check(finder.matches.count == 4 && !coordinator.projection.entries.contains { $0.row.id == nested.id } && highlighted() == expected() && highlighted().count == 3, "Collapsing keeps the hidden match counted and highlights only what is shown")
    coordinator.toggle(a.id)
    expectIdle("expanding")
    check(highlighted() == expected() && highlighted().count == 4, "Expanding highlights the match that reappears")

    window.setContentSize(NSSize(width: 480, height: 420)); hosting.frame.size = NSSize(width: 480, height: 420)
    expectIdle("resizing")
    check(finder.matches.count == 4 && highlighted() == expected() && highlighted().count == 4, "Resizing keeps the highlights")
    coordinator.discardDisplayedState(); coordinator.render()
    expectIdle("a full rebuild")
    check(highlighted() == expected() && highlighted().count == 4, "A full rebuild of the text restores the highlights over unchanged matches")

    before = (publications, finder.scans)
    let start = finder.current!
    finder.next()
    check(publications == before.0 + 1 && finder.scans == before.1 && finder.current == (start + 1) % 4, "Moving to the next match publishes once, without rescanning")
    let selected = finder.matches[finder.current!], shown = coordinator.projection.entries.first { $0.row.id == selected.row }!
    check(text.selectedRange() == NSRange(location: shown.range.location + selected.range.location, length: selected.range.length), "Navigation still selects the match")
    expectIdle("navigating")
    coordinator.toggle(a.id)
    run(0.25)
    let hiddenIndex = finder.matches.firstIndex { $0.row == nested.id }!
    while finder.current != hiddenIndex { finder.next() }
    expectIdle("navigating into a collapsed section")
    check(coordinator.projection.entries.contains { $0.row.id == nested.id } && highlighted() == expected() && highlighted().count == 4, "Navigating into a collapsed section opens it and highlights the match")

    finder.replacement = "goal"
    check(finder.replaceCurrent(), "Replace still replaces with the bar open")
    expectIdle("replacing")
    check(finder.matches.count == 3 && highlighted() == expected() && highlighted().count == 3, "Replace updates the matches and highlights")

    finder.query = "**"
    expectIdle("searching for a hidden marker")
    check(finder.matches.isEmpty && highlighted().isEmpty, "Hidden emphasis markers are not found")
    try? shared.setEnabled(false)
    expectIdle("turning substitutions off")
    check(finder.matches.count == 2, "Turning substitutions off makes literal markers findable with the bar open: \(finder.matches.count)")
    try? shared.setEnabled(true)
    expectIdle("turning substitutions on")
    check(finder.matches.isEmpty, "Turning substitutions back on hides them from Find again")

    finder.query = "plan"
    finder.close()
    expectIdle("closing")
    check(!finder.visible && finder.current == nil && highlighted().isEmpty, "Done clears the highlights")
    finder.open()
    expectIdle("reopening")
    check(finder.visible && finder.current != nil && highlighted() == expected() && !highlighted().isEmpty, "Reopening restores the current match and highlights without a new search")
}
