import AppKit
import Combine
import SwiftUI

/// A synthetic lot shaped like Richard's main Parking Lot (November 2026: 130
/// rows, 9 headings, nesting to three levels, 16 tags, 53 comments, 3 images,
/// 11 done, 4 links, rows of about 280 characters). No real lot content.
func parkingLotTypingFixture(rows count: Int, imagePath: String) -> [ParkingLotRow] {
    let sentence = "Typing in a long Parking Lot row should feel immediate, even with nested items, tags, comments and screenshots nearby. "
    let headings = max(1, count * 9 / 130)
    var rows: [ParkingLotRow] = [], images = 0
    let perSection = max(1, (count - headings) / headings)
    for section in 0..<headings {
        let heading = ParkingLotRow(heading: true, text: "Section \(section + 1)")
        rows.append(heading)
        var parents: [UUID] = [heading.id]
        for i in 0..<perSection where rows.count < count {
            let n = rows.count
            // Mostly top-level items, with occasional children and grandchildren.
            let depth = i == 0 ? 1 : [1, 1, 2, 2, 3][n % 5]
            while parents.count > depth { parents.removeLast() }
            var text = "Item \(n): " + String(repeating: sentence, count: 2)
            if n % 33 == 7 { text += " See https://example.com/notes/\(n) and [the spec](https://example.com/spec)." }
            var row = ParkingLotRow(heading: false, text: text, parentID: parents.last)
            if n % 8 == 3 { row.tag = ParkingLotTag.allCases[n % ParkingLotTag.allCases.count] }
            if n % 12 == 5 { row.done = true }
            if n % 5 == 1 { row.notes = (0..<(n % 3 == 0 ? 2 : 1)).map { .init(author: "Reviewer", text: "Comment \(n).\($0)") } }
            if n % 43 == 20, images < max(3, count / 43) { row.images = [imagePath]; images += 1 }
            rows.append(row)
            if parents.count == depth { parents.append(row.id) }
        }
    }
    return rows
}

struct ParkingLotTypingMeasurement {
    var keystrokes: [Double] = []
    var stages: [String: [Double]] = [:]
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}

/// Types into an offscreen window configured like the live pane and records
/// each keystroke's main-thread time: key handling, then the layout and draw
/// AppKit performs before the next frame. Stage timings come from PerformanceCapture.
func measureParkingLotTyping(rows count: Int, keys: Int, folder: URL, check: (Bool, String) -> Void) -> ParkingLotTypingMeasurement {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let imagePath = folder.appendingPathComponent("screenshot.png").path
    let picture = NSImage(size: NSSize(width: 900, height: 300), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
    if let tiff = picture.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: imagePath))
    }
    let lot = ParkingLotStore(folder: folder.appendingPathComponent("lot"), id: UUID(), name: "Typing profile")
    lot.openStarter(parkingLotTypingFixture(rows: count, imagePath: imagePath))
    // The real pane, so makeNSView's configuration and SwiftUI's update pass count too.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let hosting = NSHostingView(rootView: ParkingLotView(lot: lot, workspace: Workspace(), pane: 1))
    hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 900); window.contentView = hosting
    func settle() { hosting.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date()); hosting.layoutSubtreeIfNeeded() }
    func find(_ view: NSView) -> ParkingOutlineText? { (view as? ParkingOutlineText) ?? view.subviews.lazy.compactMap(find).first }
    settle()
    for _ in 0..<50 where find(hosting) == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.02)); settle() }
    guard let text = find(hosting), let coordinator = text.owner else {
        check(false, "Typing profile hosts the real Parking Lot pane"); window.close(); return ParkingLotTypingMeasurement()
    }
    window.makeFirstResponder(text)
    text.mouseLocation = { .zero }  // A real pointer may move while this runs.
    settle()
    // Type at the end of a row in the middle of the lot, scrolled into view.
    let target = lot.document.rows[lot.document.rows.count / 2].id
    let entry = coordinator.projection.entries.first { $0.row.id == target }!
    text.setSelectedRange(NSRange(location: NSMaxRange(entry.range), length: 0)); text.scrollRangeToVisible(text.selectedRange())
    settle()

    let keys = Int(ProcessInfo.processInfo.environment["CONVERSE_LOT_PROFILE_KEYS"] ?? "") ?? keys
    let capture = PerformanceCapture.shared, wasEnabled = capture.enabled
    capture.configure(folder: folder.appendingPathComponent("capture"), enabled: true, sampleMainQueue: false, historySeconds: 600)
    defer { capture.configure(folder: folder.appendingPathComponent("capture"), enabled: wasEnabled, sampleMainQueue: wasEnabled) }
    var result = ParkingLotTypingMeasurement()
    let phrase = Array(" quick note about typing")
    // Lets a sampler attach to a run of keystrokes.
    if let pause = ProcessInfo.processInfo.environment["CONVERSE_LOT_PROFILE_PAUSE"], let seconds = Double(pause) { print("READY \(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout); Thread.sleep(forTimeInterval: seconds) }
    for i in 0..<keys {
        let character = String(phrase[i % phrase.count])
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false,
                                     keyCode: character == " " ? 49 : 0)!
        let start = ProcessInfo.processInfo.systemUptime
        text.keyDown(with: event)
        let handled = ProcessInfo.processInfo.systemUptime
        hosting.layoutSubtreeIfNeeded()
        let settled = ProcessInfo.processInfo.systemUptime
        // Core Animation's commit at the end of the run loop turn draws the layers.
        RunLoop.current.run(until: Date()); hosting.layoutSubtreeIfNeeded()
        let end = ProcessInfo.processInfo.systemUptime
        result.keystrokes.append((end - start) * 1000)
        result.stages["profileKey", default: []].append((handled - start) * 1000)
        result.stages["profileSwiftUI", default: []].append((settled - handled) * 1000)
        result.stages["profilePaint", default: []].append((end - settled) * 1000)
    }
    for event in capture.eventsForTesting() { result.stages[event.operation.rawValue, default: []].append(event.milliseconds) }
    let typed = String((0..<keys).map { phrase[$0 % phrase.count] })
    let saved = lot.document.rows.first { $0.id == target }?.text ?? ""
    check(saved == entry.row.text + typed, "Typing profile (\(count) rows) saved every keystroke into the edited row")
    check(text.cursorHides == 1, "Keys after the first skip the WindowServer cursor hide while the pointer stays put (\(text.cursorHides) hides)")
    // The pane must still follow other writers without going through SwiftUI.
    let other = lot.document.rows[1].id
    do { try lot.apply(.init(revision: lot.document.revision, operations: [.init(action: "update", id: other, text: "Saved by a session")]), author: "Session") }
    catch { check(false, "Typing profile session edit: " + error.localizedDescription) }
    for _ in 0..<500 where coordinator.displayed != lot.document { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(coordinator.displayed == lot.document && text.string.contains("Saved by a session"), "An open pane shows another writer's save without an edit of its own")
    // The display must be exactly what a full render of the saved lot produces.
    let incremental = ParkingLotRenderSignature(text, coordinator)
    coordinator.discardDisplayedState(); coordinator.render(); settle()
    let full = ParkingLotRenderSignature(text, coordinator)
    check(incremental == full, "After \(keys) typed keys in a \(count)-row lot, the incremental display matches a full render (text, attributes, gutter, comment buttons)")
    text.undo(nil)
    check(lot.document.rows.first { $0.id == target }?.text == entry.row.text + typed.dropLast() && ParkingLotRenderSignature(text, coordinator).text == coordinator.projection.string,
          "Undo after profiled typing removes the last keystroke and redisplays the lot")
    window.close()
    return result
}

/// Everything a render decides: text, attribute runs, gutter entries and comment buttons.
struct ParkingLotRenderSignature: Equatable {
    var text = ""
    var runs: [String] = []
    var entries: [String] = []
    var buttons: [String] = []
    init(_ view: ParkingOutlineText, _ coordinator: ParkingLotEditor.Coordinator) {
        guard let storage = view.textStorage else { return }
        text = storage.string
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            let font = attributes[.font] as? NSFont, style = attributes[.paragraphStyle] as? NSParagraphStyle
            // Tag colors are new dynamic objects per render; compare what they resolve to.
            let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB).map { "\($0.redComponent) \($0.greenComponent) \($0.blueComponent) \($0.alphaComponent)" } ?? "-"
            runs.append("\(range.location),\(range.length) \(font?.fontName ?? "-") \(font?.pointSize ?? 0) \(color) \(style.map { "\($0.firstLineHeadIndent)/\($0.headIndent)/\($0.tailIndent)/\($0.paragraphSpacing)/\($0.paragraphSpacingBefore)" } ?? "-") "
                + "\(attributes[.strikethroughStyle] as? Int ?? 0) \((attributes[.link] as? URL)?.absoluteString ?? "-") \(attributes[.toolTip] as? String ?? "-")")
        }
        entries = coordinator.projection.entries.map {
            "\($0.row.id) \($0.range.location),\($0.range.length) \($0.number) \($0.depth) \($0.hasChildren) \($0.placeholder) \($0.before?.uuidString ?? "-")"
        }
        buttons = view.subviews.compactMap { $0 as? NSButton }.map { "\($0.identifier?.rawValue ?? "") \($0.title) \($0.frame)" }.sorted()
    }
}

func parkingLotTypingReport(_ measurement: ParkingLotTypingMeasurement, label: String) -> String {
    var lines = [String(format: "%@: %d keys, per keystroke median %.2f ms, mean %.2f ms, max %.2f ms", label, measurement.keystrokes.count,
                        ParkingLotTypingMeasurement.median(measurement.keystrokes),
                        measurement.keystrokes.reduce(0, +) / Double(max(1, measurement.keystrokes.count)), measurement.keystrokes.max() ?? 0)]
    for (name, values) in measurement.stages.sorted(by: { $0.value.reduce(0, +) > $1.value.reduce(0, +) }) {
        lines.append(String(format: "  %-20@ n=%4d  median %7.3f  mean %7.3f  max %7.3f  per key %7.3f ms", name as NSString, values.count,
                            ParkingLotTypingMeasurement.median(values), values.reduce(0, +) / Double(values.count), values.max() ?? 0,
                            values.reduce(0, +) / Double(max(1, measurement.keystrokes.count))))
    }
    return lines.joined(separator: "\n")
}

/// Every kind of edit, each compared with a from-scratch render of the same state.
private func parkingLotIncrementalRenderSelfTests(_ check: (Bool, String) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lot-incremental-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let imagePath = folder.appendingPathComponent("shot.png").path
    let picture = NSImage(size: NSSize(width: 600, height: 200), flipped: false) { rect in NSColor.systemPink.setFill(); rect.fill(); return true }
    if let tiff = picture.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: imagePath))
    }
    let lot = ParkingLotStore(folder: folder.appendingPathComponent("lot"), id: UUID(), name: "Incremental")
    lot.openStarter(parkingLotTypingFixture(rows: 60, imagePath: imagePath))
    var collapsed: Set<UUID> = []
    let coordinator = ParkingLotEditor.Coordinator(ParkingLotEditor(lot: lot, collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }), reorder: {}))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let text = ParkingOutlineText(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
    text.isRichText = false; text.allowsUndo = true; text.owner = coordinator; text.delegate = coordinator; coordinator.text = text
    text.isVerticallyResizable = true; text.textContainerInset = NSSize(width: 36, height: 8)
    text.textContainer?.widthTracksTextView = true
    window.contentView = text; text.configureTextScaling(); coordinator.render(); window.makeFirstResponder(text)
    func matches(_ step: String) {
        let incremental = ParkingLotRenderSignature(text, coordinator)
        coordinator.discardDisplayedState(); coordinator.render()
        let full = ParkingLotRenderSignature(text, coordinator)
        check(incremental == full && coordinator.displayed == lot.document, "Incremental display equals a full render after: " + step)
    }
    func entry(_ id: UUID) -> ParkingOutline.Entry { coordinator.projection.entries.first { $0.row.id == id }! }
    func caret(_ id: UUID, _ offset: Int? = nil) {
        let found = entry(id)
        text.setSelectedRange(NSRange(location: found.range.location + (offset ?? found.range.length), length: 0))
    }
    func type(_ value: String) { for key in value { text.insertText(String(key), replacementRange: text.selectedRange()) } }
    let rows = lot.document.rows
    let item = rows.first { !$0.heading && $0.images == nil && $0.notes == nil }!.id
    let heading = rows.first(where: \.heading)!.id
    let imageRow = rows.first { $0.images != nil }!.id
    let commented = rows.first { $0.notes != nil }!.id
    let linked = rows.first { $0.text.contains("[the spec]") }!.id
    caret(item); type(" typed"); matches("typing at the end of a row")
    caret(item, 0); type("Start "); matches("typing at the start of a row")
    caret(heading); type(" title"); matches("typing in a heading")
    caret(imageRow); type(" caption"); matches("typing in a row with an image")
    caret(commented); type(" more"); matches("typing above comment buttons")
    let wrapping = String(repeating: "wide words wrap to another line ", count: 8)
    caret(item); text.insertText(wrapping, replacementRange: text.selectedRange()); matches("a paste that adds wrapped lines")
    caret(item); type(" 🦊é"); matches("emoji and composed characters")
    let ready = coordinator.projection.entries.first { $0.placeholder && !$0.row.heading }!
    text.setSelectedRange(NSRange(location: ready.range.location, length: 0)); type("New row"); matches("typing into a ready input")
    caret(item); text.insertText("\n", replacementRange: text.selectedRange()); matches("Return creating a row")
    text.deleteBackward(nil); matches("Backspace removing a blank row")
    caret(item); text.insertText("\u{2028}", replacementRange: text.selectedRange()); type("second line"); matches("a soft line break")
    caret(item, 0); text.deleteBackward(nil); matches("Backspace joining two rows")
    text.undo(nil); matches("Undo of a join")
    text.redo(nil); matches("Redo of a join")
    text.undo(nil); matches("Undo again")
    caret(item); type(" https://example.com/a"); matches("a URL still being typed")
    type(" "); matches("a URL finished by a space")
    caret(linked); matches("the caret entering a linked row")
    type(" after"); matches("typing after a Markdown link")
    caret(heading); matches("the caret leaving a linked row")
    type(" :-) "); matches("a text substitution")
    let done = rows.first { !$0.heading && $0.id != item && $0.id != commented && $0.id != imageRow && $0.id != linked }!.id
    lot.setDone(done, true); coordinator.render(); matches("Mark Done")
    lot.setTag(done, .green); coordinator.render(); matches("a color tag")
    do {
        try lot.apply(.init(revision: lot.document.revision, operations: [.init(action: "update", id: commented, text: "Rewritten by a session")]), author: "Session")
        coordinator.render(); matches("another writer's text edit")
        try lot.apply(.init(revision: lot.document.revision, operations: [.init(action: "comment", id: done, text: "A new comment")]), author: "Session")
        coordinator.render(); matches("another writer's comment")
        try lot.apply(.init(revision: lot.document.revision, operations: [.init(action: "add", text: "Added above", before: item, parentID: heading)]), author: "Session")
        coordinator.render(); matches("another writer inserting a row above the caret")
        try lot.apply(.init(revision: lot.document.revision, operations: [.init(action: "delete", id: done)]), author: "Session")
        coordinator.render(); matches("another writer deleting a row")
        try lot.commitRemote(ParkingLotDocument(revision: lot.document.revision + 1, rows: lot.document.rows.map { row in
            var row = row; if row.id == heading { row.text = "Remote heading" }; return row
        }))
        coordinator.render(); matches("a remote device's commit")
    } catch { check(false, "Incremental render session fixture: " + error.localizedDescription) }
    lot.changeIndent(item, deeper: true); coordinator.render(); matches("indenting renumbers later rows")
    lot.changeIndent(item, deeper: true); coordinator.render(); matches("a flexible indent beyond the row above")
    lot.changeIndent(item, deeper: false); coordinator.render(); matches("removing a flexible indent")
    let topLevel = lot.document.rows.first { !$0.heading && $0.id != item && (try? ParkingLotTree.nodes(lot.document.rows))?[$0.id]?.depth == 1 }!.id
    lot.changeIndent(topLevel, deeper: false); coordinator.render(); matches("outdenting a top-level item into a heading")
    text.undo(nil); matches("Undo of an outdent to a heading")
    lot.delete(linked); coordinator.render(); matches("deleting a row renumbers its section")
    collapsed = [heading]; coordinator.render(); matches("collapsing a section")
    collapsed = []; coordinator.render(); matches("expanding a section")
    text.applyPaneText(.bigger); caret(item); type(" zoomed"); matches("typing after a text size change")
    window.setContentSize(NSSize(width: 520, height: 800)); text.setFrameSize(NSSize(width: 520, height: 800)); text.layout()
    caret(item); type(" narrow"); matches("typing after a width change")
    window.close()
}

/// The pane around the editor waits for a pause in typing, and the read
/// marker is not rewritten per key, without either falling behind for long.
private func parkingLotDeferredPublishSelfTests(_ check: (Bool, String) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lot-deferred-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lot = ParkingLotStore(folder: folder, id: UUID(), name: "Deferred")
    let heading = ParkingLotRow(heading: true, text: "Work"), row = ParkingLotRow(heading: false, text: "Alpha")
    lot.openStarter([heading, row])
    let viewer = UUID(); lot.beginViewing(viewer)
    var signals = 0
    let observer = lot.chrome.objectWillChange.sink { signals += 1 }
    func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    func typed(_ value: String) throws {
        var rows = lot.document.rows
        rows[1].text = value; rows[1].editedBy = nil
        try lot.replaceUserRows(rows, revision: lot.document.revision)
    }
    do {
        try typed("Alpha 1"); try typed("Alpha 12")
        check(signals == 0 && lot.document.rows[1].text == "Alpha 12", "Typing leaves the views around the editor alone while the row saves")
        for _ in 0..<200 where signals == 0 { spin(0.025) }
        check(signals == 1, "Those views refresh once typing pauses")
        lot.setTag(row.id, .red)
        check(signals > 1, "A change the views show refreshes them at once")
        lot.error = "Problem"; signals = 0
        try typed("Alpha 123")
        check(signals >= 1 && lot.error.isEmpty, "Typing that clears an error refreshes them at once")
        lot.endViewing(viewer)
        check(!ParkingLotStore(folder: folder, id: lot.id).hasUnseenChanges, "Leaving a lot saves the read marker typing had deferred")
    } catch { check(false, "Deferred publish fixture: " + error.localizedDescription) }
    withExtendedLifetime(observer) {}
}

/// Typing a character in a lot the size of Richard's must stay well inside a frame.
func parkingLotTypingSelfTests(_ check: (Bool, String) -> Void) {
    parkingLotIncrementalRenderSelfTests(check)
    parkingLotDeferredPublishSelfTests(check)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lot-typing-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let measurement = measureParkingLotTyping(rows: 130, keys: 40, folder: folder, check: check)
    let median = ParkingLotTypingMeasurement.median(measurement.keystrokes)
    print(parkingLotTypingReport(measurement, label: "Lot typing self-test"))
    check(median < 15, String(format: "Typing in a 130-row lot costs a median %.2f ms per key on main (limit 15 ms)", median))
}
