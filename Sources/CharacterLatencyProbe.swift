import AppKit

/// Explicit, isolated TEST-only experiment. All mutable records belong to main.
/// A draw callback proves AppKit drew a visible glyph, not monitor presentation.
final class CharacterLatencyProbe {
    static let shared = CharacterLatencyProbe()
    struct Character: Codable {
        let lane: String
        let sequence: Int
        let scheduled: Double
        var emitted: Double?
        var received: Double?
        var inserted: Double?
        var drawn: Double?
        var characterOffset: Int?
    }
    struct Report: Codable {
        let schemaVersion: Int
        let endpoint: String
        let countPerLane: Int
        let intervalSeconds: Double
        let historyLines: Int
        let webImage: Bool
        let mouseStress: MouseStress
        let windows: [WindowSample]
        let finished: Double
        let characters: [Character]
    }
    struct MouseStress: Codable {
        var hertz = 0
        var scheduled = 0
        var delivered = 0
        var skippedNoTracking = 0
        var skippedNoView = 0
        var maximumDispatchDelayMilliseconds = 0.0
        var trackingInitialized = false
        let endpoint = "synthetic mouseMoved handler calls, only while the response-image hover area exists; not natural pointer or autoscroll delivery"
    }
    struct WindowSample: Codable {
        let uptime: Double
        let frame: [Double]
        let visible: Bool
        let key: Bool
        let pointer: [Double]
    }
    private var inputID: UUID?, outputID: UUID?
    private weak var inputView: ConversationTextView?
    private weak var outputView: ConversationTextView?
    private var mouseStress = MouseStress()
    private var windows: [WindowSample] = []
    private var input: [Character] = [], output: [Character] = []
    private var started = false, finished = false
    private let scheduler = DispatchQueue(label: "Converse.character-probe.cadence", qos: .userInitiated)
    private var historyLines = 0
    private var webImage = false
    private var count = 200
    private var interval = 0.05
    private var destination: URL?

    func start(app: AppDelegate) {
        let env = ProcessInfo.processInfo.environment
        guard env["CONVERSE_CHARACTER_PROBE"] == "1",
              Bundle.main.object(forInfoDictionaryKey: "ConverseTestProvider") != nil,
              let folder = env["CONVERSE_DATA_DIR"],
              let fixture = env["CONVERSE_CHARACTER_PROVIDER"],
              FileManager.default.isExecutableFile(atPath: fixture),
              let state = app.windows.first?.1 else { return }
        // A caller must explicitly prepare a disposable profile. Never run in
        // a reused TEST/production archive merely because an env flag leaked.
        guard FileManager.default.fileExists(atPath: folder + "/character-probe-profile") else { return }
        count = min(1000, max(1, Int(env["CONVERSE_CHARACTER_COUNT"] ?? "") ?? 200))
        interval = min(1, max(0.01, Double(env["CONVERSE_CHARACTER_INTERVAL"] ?? "") ?? 0.05))
        historyLines = min(10000, max(0, Int(env["CONVERSE_CHARACTER_HISTORY_LINES"] ?? "") ?? 0))
        mouseStress.hertz = min(120, max(0, Int(env["CONVERSE_CHARACTER_MOUSE_HZ"] ?? "") ?? 0))
        webImage = env["CONVERSE_CHARACTER_WEB_IMAGE"] == "1"
        destination = URL(fileURLWithPath: folder).appendingPathComponent("Performance Diagnostics/characters.json")
        let entry = Entry(name: "Character probe fixture", command: fixture, directory: folder, engine: "claude")
        let typing = Store.shared.create(entry)
        typing.title = "Character probe — typing"; inputID = typing.id
        let streaming = Store.shared.create(entry)
        streaming.title = "Character probe — streaming"; outputID = streaming.id
        if historyLines > 0 {
            let history = (0..<historyLines).map { "Fixture history line \($0): reproducible plain text for layout and autoscroll." }.joined(separator: "\n")
            for session in [typing, streaming] {
                session.messages = [Message(role: "assistant", text: history)]
            }
        }
        if webImage {
            // A placeholder link exercises hover tracking without fetching it.
            streaming.messages.append(Message(role: "assistant", text: "![Hover fixture](https://example.invalid/character-probe.png)"))
        }
        app.assign(typing, to: state, pane: 1)
        app.assign(streaming, to: state, pane: 2)
        streaming.draft = "Character latency fixture"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Store.shared.send(streaming) }
    }

    func bind(_ view: ConversationTextView, session: Session) {
        if session.id == outputID {
            outputView = view
            // Our synthetic dispatch bypasses AppKit's event-loop tracking
            // refresh. Initialize it identically in control and candidate;
            // otherwise only a candidate's property observer may create it.
            if mouseStress.hertz > 0, !mouseStress.trackingInitialized, view.window != nil {
                view.updateTrackingAreas()
                mouseStress.trackingInitialized = true
            }
        }
        guard session.id == inputID, !started, view.window != nil else { return }
        started = true; inputView = view
        let base = ProcessInfo.processInfo.systemUptime + 3
        input = (0..<count).map { Character(lane: "input", sequence: $0, scheduled: base + Double($0) * interval) }
        let origin = DispatchTime.now()
        // Deadlines are fixed before the first key. A slow UI must not move
        // future deadlines and conceal coordinated omission.
        for index in 0..<count {
            scheduler.asyncAfter(deadline: origin + 3 + Double(index) * interval) { [weak self] in
                let emitted = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async { self?.type(index, emitted: emitted) }
            }
        }
        if mouseStress.hertz > 0 {
            mouseStress.scheduled = Int(ceil(Double(count) * interval * Double(mouseStress.hertz)))
            for index in 0..<mouseStress.scheduled {
                let offset = Double(index) / Double(mouseStress.hertz)
                scheduler.asyncAfter(deadline: origin + 3 + offset) { [weak self] in
                    DispatchQueue.main.async { self?.moveMouse(scheduled: base + offset) }
                }
            }
        }
        scheduler.asyncAfter(deadline: origin + 3 + Double(count) * interval + 10) { [weak self] in
            DispatchQueue.main.async { self?.finish() }
        }
    }

    private func moveMouse(scheduled: Double) {
        guard !finished else { return }
        mouseStress.maximumDispatchDelayMilliseconds = max(mouseStress.maximumDispatchDelayMilliseconds,
            (ProcessInfo.processInfo.systemUptime - scheduled) * 1000)
        guard let view = outputView, let window = view.window, window.isVisible,
              window.occlusionState.contains(.visible) else { mouseStress.skippedNoView += 1; return }
        // Model deliveries from our tracking area, not unconditional method
        // calls: a build that removes that area must receive no such events.
        guard view.tracksResponseImageHover else {
            mouseStress.skippedNoTracking += 1; return
        }
        let visible = view.visibleRect
        let point = view.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
            timestamp: scheduled, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 0, pressure: 0) else { mouseStress.skippedNoView += 1; return }
        mouseStress.delivered += 1
        view.mouseMoved(with: event)
    }

    private func type(_ index: Int, emitted: Double) {
        guard !finished, input.indices.contains(index) else { return }
        input[index].emitted = emitted
        input[index].received = ProcessInfo.processInfo.systemUptime
        guard let view = inputView, let window = view.window else { return }
        if index % 100 == 0 {
            let frame = window.frame, pointer = NSEvent.mouseLocation
            windows.append(WindowSample(uptime: ProcessInfo.processInfo.systemUptime,
                frame: [frame.origin.x, frame.origin.y, frame.width, frame.height],
                visible: window.occlusionState.contains(.visible), key: window.isKeyWindow,
                pointer: [pointer.x, pointer.y]))
        }
        if window.firstResponder !== view { window.makeFirstResponder(view) }
        let end = NSRange(location: (view.string as NSString).length, length: 0)
        if view.selectedRange() != end { view.setSelectedRange(end) }
        let before = (view.string as NSString).length
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: input[index].scheduled, windowNumber: window.windowNumber,
                                          context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                          isARepeat: false, keyCode: 0) else { return }
        // Exercise the ordinary keyDown/insertText/delegate path. This begins
        // at synthetic dispatch, not hardware keyboard or WindowServer input.
        view.keyDown(with: event)
        if (view.string as NSString).length == before + 1 {
            input[index].inserted = ProcessInfo.processInfo.systemUptime
            input[index].characterOffset = before - view.inputStart
        }
    }

    func received(_ object: [String: Any], session: Session) {
        guard session.id == outputID, !finished,
              let probe = object["character_probe"] as? [String: Any],
              let sequence = probe["sequence"] as? Int, sequence == output.count, sequence < count,
              let scheduled = probe["scheduled"] as? Double,
              let emitted = probe["emitted"] as? Double,
              scheduled.isFinite, emitted.isFinite else { return }
        output.append(Character(lane: "provider", sequence: sequence, scheduled: scheduled,
                                emitted: emitted, received: ProcessInfo.processInfo.systemUptime))
    }

    func didDraw(_ view: ConversationTextView, dirty: NSRect) {
        guard !finished, let session = (view.delegate as? ScrollingConversation.Coordinator)?.session,
              session.id == inputID || session.id == outputID,
              let window = view.window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible),
              let layout = view.layoutManager, let container = view.textContainer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let typing = session.id == inputID
        let start: Int
        if typing { start = view.inputStart }
        else {
            guard let block = view.copyBlocks.last(where: { $0.role == "assistant" }),
                  block.source.allSatisfy({ $0 == "a" }) else { return }
            start = block.range.location
        }
        for index in 0..<(typing ? input.count : output.count) {
            if typing ? input[index].drawn != nil : output[index].drawn != nil { continue }
            if typing && input[index].inserted == nil { continue }
            let character = start + (typing ? (input[index].characterOffset ?? index) : index)
            guard character < (view.string as NSString).length,
                  (view.string as NSString).character(at: character) == 97 else { continue }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: character, length: 1), actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            guard !rect.isEmpty, rect.intersects(dirty), rect.intersects(view.visibleRect) else { continue }
            if typing { input[index].drawn = now } else { output[index].drawn = now }
        }
    }

    private func finish() {
        guard !finished, let destination else { return }
        finished = true
        let report = Report(schemaVersion: 1, endpoint: "visible-glyph AppKit draw callback; not physical presentation",
                            countPerLane: count, intervalSeconds: interval, historyLines: historyLines, webImage: webImage,
                            mouseStress: mouseStress, windows: windows,
                            finished: ProcessInfo.processInfo.systemUptime, characters: input + output)
        scheduler.async {
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(report).write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            } catch { NSLog("Character probe could not save results: %@", error.localizedDescription) }
        }
    }
}
