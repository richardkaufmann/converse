import AppKit

enum ParkingLotTag: String, Codable, CaseIterable {
    case red, orange, yellow, green, blue, purple

    var lightHex: String {
        switch self {
        case .red: return "#B42332"
        case .orange: return "#A34600"
        case .yellow: return "#806000"
        case .green: return "#16733D"
        case .blue: return "#1762B8"
        case .purple: return "#8045B5"
        }
    }
    var darkHex: String {
        switch self {
        case .red: return "#FF8890"
        case .orange: return "#FFB56B"
        case .yellow: return "#E9CB65"
        case .green: return "#79D99C"
        case .blue: return "#83BBFF"
        case .purple: return "#C7A0F5"
        }
    }
    var color: NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkHex : lightHex
            let value = UInt32(hex.dropFirst(), radix: 16)!
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    static func parseEdit(_ value: String?) throws -> ParkingLotTag? {
        guard let value, value != "none" else { return nil }
        guard let tag = Self(rawValue: value) else { throw AgentFailure.message("Unknown Parking Lot tag. Use red, orange, yellow, green, blue, purple or none.") }
        return tag
    }
}

/// A compact, accessible swatch row at the top of the native item menu.
final class ParkingTagMenuView: NSView {
    private let choose: (ParkingLotTag?) -> Void
    init(selected: ParkingLotTag?, enabled: Bool, choose: @escaping (ParkingLotTag?) -> Void) {
        self.choose = choose
        super.init(frame: NSRect(x: 0, y: 0, width: 218, height: 34))
        let choices: [ParkingLotTag?] = [nil] + ParkingLotTag.allCases.map { Optional($0) }
        for (index, tag) in choices.enumerated() {
            let button = NSButton(frame: NSRect(x: 8 + index * 29, y: 3, width: 28, height: 28))
            button.tag = index; button.isBordered = false; button.imagePosition = .imageOnly
            button.target = self; button.action = #selector(pick(_:)); button.isEnabled = enabled
            let label = tag.map { $0.rawValue.capitalized + " tag" } ?? "Clear tag"
            button.toolTip = label; button.setAccessibilityLabel(label)
            button.setAccessibilityValue(tag == selected ? "Selected" : "")
            button.image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
                let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5))
                if let tag { tag.color.setFill(); circle.fill() }
                else {
                    NSColor.secondaryLabelColor.setStroke(); circle.lineWidth = 1.5; circle.stroke()
                    let slash = NSBezierPath(); slash.move(to: NSPoint(x: 7, y: 7)); slash.line(to: NSPoint(x: 17, y: 17)); slash.stroke()
                }
                if tag == selected {
                    NSColor.labelColor.setStroke()
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)); ring.lineWidth = 1.5; ring.stroke()
                }
                return true
            }
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pick(_ sender: NSButton) {
        enclosingMenuItem?.menu?.cancelTracking()
        choose(sender.tag == 0 ? nil : ParkingLotTag.allCases[sender.tag - 1])
    }
}

func parkingLotTagSelfTests(_ check: (Bool, String) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-lot-tags-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lot = ParkingLotStore(folder: folder)
    let heading = ParkingLotRow(heading: true, text: "Bugs", tag: .red)
    let item = ParkingLotRow(heading: false, text: "Fix this", parentID: heading.id)
    let child = ParkingLotRow(heading: false, text: "Nested", done: true, parentID: item.id, tag: .red)
    lot.openStarter([heading, item, child])
    lot.setTag(item.id, .blue)
    check(lot.document.rows[1].tag == .blue && lot.document.rows[2].tag == .red, "Tagging an item leaves descendants and their tags alone")
    lot.undoManager.undo()
    check(lot.document.rows[1].tag == nil, "Color tag has one-step Undo")
    lot.undoManager.redo()
    check(lot.document.rows[1].tag == .blue, "Color tag Redo restores the tag")
    check(ParkingLotStore(folder: folder).document == lot.document && lot.document.schemaVersion == 3, "Tagged lot persists and reloads with the field-preserving schema")
    let counts = ParkingLotStore.unresolvedTagCounts(lot.document.rows)
    check(counts["blue"] == 1 && counts["red"] == 0 && counts["yellow"] == 0, "Steward counts exclude headings and completed items, with explicit zero counts")
    do {
        let evidence = try lot.evidence() as? [String: Any]
        check((evidence?["unresolvedTagCounts"] as? [String: Int]) == counts, "Assistant evidence exposes unresolved named tag counts")
        let store = Store(folder: folder.appendingPathComponent("review"))
        let session = store.create(Entry(name: "Review", command: "unused", directory: folder.path, engine: "claude"))
        let summary = try store.parkingLotReviewSummary(.init(revision: lot.document.revision, operations: [.init(action: "update", id: item.id, tag: "yellow")]), session: session, lot: lot)
        check(summary?.contains("Color tag: “Fix this” → yellow") == true, "Review names the exact proposed color change")
        try lot.apply(.init(revision: lot.document.revision, operations: [.init(action: "update", id: item.id, tag: "yellow")]), author: "Steward")
        check(lot.document.rows[1].tag == .yellow, "Assistant can apply a named tag without changing text")
        try lot.apply(.init(revision: lot.document.revision, operations: [.init(action: "update", id: item.id, text: "Still tagged")]), author: "Steward")
        check(lot.document.rows[1].tag == .yellow, "Text-only assistant edits preserve the color tag")
        let before = lot.document
        do {
            try lot.apply(.init(revision: before.revision, operations: [.init(action: "update", id: item.id, text: "Must not save", tag: "scarlet")]), author: "Steward")
            check(false, "Invalid tag must refuse the transaction")
        } catch { check(lot.document == before, "Invalid color atomically refuses the entire edit") }
        let html = try TranscriptExport.lotHTML(lot.document, includeImages: false, imageData: { _ in nil })
        check(html.contains("[yellow]") && ParkingLotStore.markdown(lot.document.rows).contains("[Tag: yellow]"), "HTML and text lot exports retain named color tags")
        try lot.apply(.init(revision: lot.document.revision, operations: [.init(action: "update", id: item.id, tag: "none")]), author: "Steward")
        check(lot.document.rows[1].tag == nil, "Assistant can explicitly clear a tag")
        let legacy = try JSONDecoder().decode(ParkingLotDocument.self, from: Data("{\"schemaVersion\":2,\"revision\":1,\"rows\":[]}".utf8))
        check(legacy.rows.isEmpty, "Pre-tag lot schemas remain readable")
    } catch { check(false, "Color tag test: " + error.localizedDescription) }
    var picked: ParkingLotTag?
    let swatches = ParkingTagMenuView(selected: .blue, enabled: true) { picked = $0 }
    let buttons = swatches.subviews.compactMap { $0 as? NSButton }
    buttons.first(where: { $0.toolTip == "Red tag" })?.performClick(nil)
    check(buttons.count == 7 && picked == .red && buttons.allSatisfy { $0.accessibilityLabel() != nil }, "Compact menu has six accessible color choices and Clear, and clicking applies the color")
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = NSAppearance(named: name)!
        appearance.performAsCurrentDrawingAppearance {
            check(ParkingLotTag.allCases.allSatisfy { $0.color.usingColorSpace(.sRGB) != nil }, "Tag palette resolves in " + name.rawValue)
            if let directory = ProcessInfo.processInfo.environment["CONVERSE_TAG_PREVIEW_DIR"] {
                let preview = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 230))
                preview.appearance = appearance
                preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
                let menu = ParkingTagMenuView(selected: .blue, enabled: true) { _ in }
                menu.frame.origin = NSPoint(x: 10, y: 185); preview.addSubview(menu)
                for (index, tag) in ParkingLotTag.allCases.enumerated() {
                    let label = NSTextField(labelWithString: "\(index + 1).  \(tag.rawValue.capitalized) tagged item")
                    label.font = .systemFont(ofSize: 16); label.textColor = tag.color
                    label.frame = NSRect(x: 20, y: 158 - index * 27, width: 300, height: 24); preview.addSubview(label)
                }
                let window = NSWindow(contentRect: preview.bounds, styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = appearance; window.contentView = preview
                if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
                    preview.cacheDisplay(in: preview.bounds, to: bitmap)
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("lot-tags-" + name.rawValue + ".png")
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }
}
