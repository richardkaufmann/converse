import AppKit
import SwiftUI
import Vision

/// An offscreen pane like ScrollingConversation builds, for resize timing and anchor tests.
final class PaneTextFixture {
    let window: NSWindow
    let scroll: ConversationScrollView
    let text: ConversationTextView
    let coordinator: ScrollingConversation.Coordinator
    init(_ session: Session, size: NSSize = NSSize(width: 760, height: 620), fontSize: Double = PaneTextSize.standard) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll = ConversationScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.contentView = InputClipView(); scroll.hasVerticalScroller = true
        text = ConversationTextView(frame: scroll.contentView.bounds)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: size.height); text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.isEditable = true; text.isSelectable = true; text.isRichText = true
        scroll.documentView = text; window.contentView = scroll; scroll.tile()
        coordinator = ScrollingConversation.Coordinator(session); text.delegate = coordinator
        text.fontSize = CGFloat(fontSize)
        coordinator.render(text); scroll.tile()
    }
    var clip: NSClipView { scroll.contentView }
    /// Where a character's line sits in the viewport.
    func viewportY(_ character: Int) -> CGFloat {
        let layout = text.layoutManager!
        let glyph = layout.glyphIndexForCharacter(at: min(character, max(0, (text.string as NSString).length - 1)))
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + text.textContainerOrigin.y - clip.bounds.minY
    }
    func lineHeight(_ character: Int) -> CGFloat {
        let layout = text.layoutManager!
        return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: nil).height
    }
    func scroll(toY y: CGFloat) {
        clip.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(clip); scroll.recordScroll()
    }
    /// Sets the pane size the way updateNSView does, timed.
    @discardableResult func resize(to size: Double) -> Double {
        let began = ProcessInfo.processInfo.systemUptime
        text.fontSize = CGFloat(size)
        coordinator.render(text)
        return (ProcessInfo.processInfo.systemUptime - began) * 1000
    }
    func close() { window.contentView = nil }
}

func largeTranscript(_ count: Int) -> [Message] {
    (0..<count / 2).flatMap { i in
        [Message(role: "user", text: "Question \(i): how should the pane keep its place while the text grows and shrinks?"),
         Message(role: "assistant", text: "## Answer \(i)\nA reply with **bold**, `code` and a [link](https://example.com/\(i)) that wraps across the pane width so reflow changes line breaks.\n\n- first point \(i)\n- second point with more words to wrap\n\n```\nlet value = \(i)\n```")]
    }
}

/// Times resizing a large transcript. Printed by --pane-text-benchmark and the self-test.
func paneTextResizeTimings(messages count: Int = 4000) -> (first: Double, steps: [Double]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-textbench-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root)
    let session = store.create(Entry(name: "Echo", command: "unused", directory: NSTemporaryDirectory(), engine: "muse"))
    session.messages = largeTranscript(count)
    let began = ProcessInfo.processInfo.systemUptime
    let pane = PaneTextFixture(session)
    let first = (ProcessInfo.processInfo.systemUptime - began) * 1000
    pane.scroll(toY: pane.text.frame.height * 0.4)
    let interval = PaneTextSize.repeatInterval; PaneTextSize.repeatInterval = 0
    defer { PaneTextSize.repeatInterval = interval }
    var steps: [Double] = []
    for size in [18.0, 20, 18, 16, 14, 16] { steps.append(pane.resize(to: size)) }
    pane.close()
    return (first, steps)
}

/// The text actually drawn in a rendered view, read back with on-device OCR.
func visibleText(_ bitmap: NSBitmapImageRep) -> [String] {
    guard let image = bitmap.cgImage else { return [] }
    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

func paneTextResizeSelfTests(_ check: (Bool, String) -> Void) {
    MainActor.assumeIsolated {
        let interval = PaneTextSize.repeatInterval, hidden = PaneTextSize.isHidden
        PaneTextSize.repeatInterval = 0
        defer { PaneTextSize.repeatInterval = interval; PaneTextSize.isHidden = hidden }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-resize-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(folder: root)
        let entry = Entry(name: "Echo", command: "unused", directory: NSTemporaryDirectory(), engine: "muse")

        // Speed: resizing scales the text in place. The old path rebuilt every
        // block, costing as much as a first render.
        let timings = paneTextResizeTimings()
        let median = timings.steps.sorted()[timings.steps.count / 2]
        print(String(format: "Resize timing (4,000 messages): first render %.0f ms, resize steps %@ ms", timings.first, timings.steps.map { String(format: "%.0f", $0) }.joined(separator: ", ")))
        check(median < timings.first * 0.5, String(format: "Resizing 4,000 messages takes under half a full render (%.0f ms vs %.0f ms)", median, timings.first))

        let session = store.create(entry)
        session.messages = largeTranscript(400)
        session.draft = "My unsent draft"
        let pane = PaneTextFixture(session)
        defer { pane.close() }
        let text = pane.text
        func font(at location: Int) -> NSFont? { text.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont }
        func step(_ change: PaneTextChange) { store.changeTextSize(change, focused: session); pane.resize(to: store.textSize(for: session)) }
        func keeps(_ anchor: ConversationTextView.ResizeAnchor?) -> Bool {
            guard let anchor else { return false }
            return abs(pane.viewportY(anchor.character) - anchor.viewportY) <= pane.lineHeight(min(anchor.character, (text.string as NSString).length - 1))
        }

        // Reading position: the first fully visible line stays put.
        pane.scroll(toY: text.frame.height * 0.45)
        check(!pane.scroll.followState.following, "Scrolling up stops following the latest output")
        let draftSelection = NSRange(location: text.inputStart + 3, length: 6)
        text.setSelectedRange(draftSelection)
        let before = text.string, builds = pane.coordinator.historyBuildCount
        var held = true
        for change in [PaneTextChange.bigger, .bigger, .smaller, .reset, .smaller] {
            let anchor = text.resizeAnchor(), origin = pane.clip.bounds.minY
            step(change)
            held = held && keeps(anchor) && pane.clip.bounds.minY != origin
        }
        check(held, "Bigger, Smaller and Actual Size keep the first fully visible line at the same viewport height")
        check(pane.coordinator.historyBuildCount == builds && text.string == before, "Resizing scales the existing text without rebuilding the transcript")
        check(text.selectedRange() == draftSelection && session.draft == "My unsent draft" && text.string.hasSuffix("My unsent draft"), "Resizing keeps the draft and its selection")
        let size = CGFloat(store.textSize(for: session))
        check(size == 15 && font(at: text.inputStart)?.pointSize == size && text.typingAttributes[.font].flatMap { $0 as? NSFont }?.pointSize == size, "The draft and new typing use the pane size")

        // The caret, when on screen, is the anchor.
        let mid = pane.clip.bounds.midY
        let glyph = text.layoutManager!.glyphIndex(for: NSPoint(x: 40, y: mid - text.textContainerOrigin.y), in: text.textContainer!)
        let caret = text.layoutManager!.characterIndexForGlyph(at: glyph)
        text.setSelectedRange(NSRange(location: caret, length: 0)); text.explicitCursor = true
        let caretY = pane.viewportY(caret)
        var caretHeld = true
        for change in [PaneTextChange.bigger, .bigger, .reset, .smaller] {
            step(change)
            caretHeld = caretHeld && abs(pane.viewportY(caret) - caretY) <= pane.lineHeight(caret) && text.selectedRange() == NSRange(location: caret, length: 0)
        }
        check(caretHeld && text.resizeAnchor()?.character == caret, "A visible caret keeps its viewport height through every size change, never recentered")
        let selected = NSRange(location: caret, length: 12)
        text.setSelectedRange(selected); step(.bigger)
        check(text.selectedRange() == selected && abs(pane.viewportY(caret) - caretY) <= pane.lineHeight(caret), "A transcript selection survives resizing and stays in place")

        // Same result as a full render at that size.
        let fresh = PaneTextFixture(session, fontSize: store.textSize(for: session))
        let samples = stride(from: 0, to: text.inputStart, by: max(1, text.inputStart / 200)).map { $0 }
        check(fresh.text.string == text.string && samples.allSatisfy { font(at: $0) == (fresh.text.textStorage?.attribute(.font, at: $0, effectiveRange: nil) as? NSFont) },
              "In-place resizing matches a fresh render at the same size")
        fresh.close()

        // Following the latest output keeps following.
        let follower = store.create(entry)
        follower.messages = largeTranscript(200)
        let tail = PaneTextFixture(follower)
        defer { tail.close() }
        tail.scroll.followLatest()
        var following = true
        for change in [PaneTextChange.bigger, .bigger, .smaller, .reset] {
            store.changeTextSize(change, focused: follower); tail.resize(to: store.textSize(for: follower))
            following = following && tail.scroll.followState.following && abs(tail.clip.bounds.maxY - tail.text.bounds.maxY) < 1
        }
        check(following, "A pane following the latest output keeps following it at every size")

        // New output and a size change together rebuild once, still anchored.
        pane.scroll(toY: text.frame.height * 0.3)
        text.setSelectedRange(NSRange(location: text.inputStart, length: 0)); text.explicitCursor = false
        let anchor = text.resizeAnchor()
        session.messages.append(Message(role: "assistant", text: "A new reply"))
        step(.smaller)
        check(keeps(anchor) && text.string.contains("A new reply") && font(at: text.inputStart)?.pointSize == CGFloat(store.textSize(for: session)), "A size change arriving with new output keeps the anchor")

        // Through SwiftUI, as View ▸ Bigger reaches a mounted pane.
        final class SizeModel: ObservableObject { @Published var size: Double = 16 }
        struct Hosted: View {
            @ObservedObject var model: SizeModel
            let session: Session
            var body: some View { ScrollingConversation(session: session, lineNumbers: true, textSize: model.size) }
        }
        PaneTextSize.isHidden = { _ in false } // Offscreen windows count as covered.
        let hostedSession = store.create(entry)
        hostedSession.messages = largeTranscript(300)
        let model = SizeModel()
        let hostWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 760, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = NSHostingView(rootView: Hosted(model: model, session: hostedSession).frame(width: 760, height: 620))
        hostWindow.orderBack(nil)
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        settle()
        func find(_ view: NSView) -> ConversationScrollView? { view as? ConversationScrollView ?? view.subviews.lazy.compactMap(find).first }
        if let hostedScroll = find(hostWindow.contentView!), let hostedText = hostedScroll.documentView as? ConversationTextView {
            hostedScroll.contentView.scroll(to: NSPoint(x: 0, y: hostedText.frame.height * 0.5)); hostedScroll.reflectScrolledClipView(hostedScroll.contentView); hostedScroll.recordScroll()
            var kept = true
            for size in [18.0, 22, 14, 16] {
                guard let anchor = hostedText.resizeAnchor() else { kept = false; break }
                model.size = size; settle()
                let y = (hostedText.lineTop(forCharacter: anchor.character) ?? .infinity) - hostedScroll.contentView.bounds.minY
                let font = hostedText.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                kept = kept && abs(y - anchor.viewportY) <= CGFloat(size) * 1.5 && font?.pointSize == CGFloat(size)
            }
            check(kept, "In a mounted SwiftUI pane, every size change keeps the anchor line at its viewport height")
            hostedScroll.jumpToLatest(); settle()
            model.size = 20; settle()
            check(hostedScroll.followState.following && abs(hostedScroll.contentView.bounds.maxY - hostedText.bounds.maxY) < 1, "In a mounted SwiftUI pane, following the latest output survives a size change")
        } else { check(false, "The SwiftUI pane hosts its conversation scroll view") }
        hostWindow.orderOut(nil); hostWindow.contentView = nil

        // Held keys apply once at the latest size; covered windows wait.
        PaneTextSize.repeatInterval = 0.12
        let count = pane.coordinator.restyleCount
        store.changeTextSize(.bigger, focused: session); pane.resize(to: store.textSize(for: session))
        store.changeTextSize(.bigger, focused: session); pane.resize(to: store.textSize(for: session))
        store.changeTextSize(.bigger, focused: session); pane.resize(to: store.textSize(for: session))
        let immediate = pane.coordinator.restyleCount
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check(immediate == count + 1 && pane.coordinator.restyleCount == count + 2 && font(at: text.inputStart)?.pointSize == CGFloat(store.textSize(for: session)),
              "Repeated presses apply the first at once and the rest once, at the latest size")
        PaneTextSize.repeatInterval = 0
        PaneTextSize.isHidden = { _ in true }
        let shown = font(at: text.inputStart)?.pointSize
        step(.reset)
        let waited = font(at: text.inputStart)?.pointSize == shown
        PaneTextSize.isHidden = { _ in false }
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: pane.window)
        check(waited && font(at: text.inputStart)?.pointSize == CGFloat(store.textSize(for: session)), "A covered window's pane resizes when it is seen again")
    }
}

/// View ▸ Bigger/Smaller/Actual Size routing: a focused PaneTextScalable, else
/// the focused session, else every session pane and every lot.
func paneTextRoutingSelfTests(_ check: (Bool, String) -> Void) {
    MainActor.assumeIsolated {
        final class FakeLot: NSView, PaneTextScalable {
            var changes: [PaneTextChange] = []
            func applyPaneText(_ change: PaneTextChange) { changes.append(change) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-route-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(folder: root)
        let entry = Entry(name: "Echo", command: "unused", directory: NSTemporaryDirectory(), engine: "muse")
        let a = store.create(entry), b = store.create(entry)
        let saved = PaneTextScaling.allLots
        defer { PaneTextScaling.allLots = saved }
        var lots: [PaneTextChange] = []
        PaneTextScaling.allLots = { lots.append($0) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentLayoutRect)
        let lot = FakeLot(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        let lotScroll = NSScrollView(frame: lot.bounds)
        let lotText = NSTextView(frame: lot.bounds); lotScroll.documentView = lotText; lot.addSubview(lotScroll)
        let pane = PaneTextFixture(a, size: NSSize(width: 600, height: 500))
        pane.window.contentView = nil
        pane.scroll.frame.origin.x = 300
        content.addSubview(lot); content.addSubview(pane.scroll); window.contentView = content

        window.makeFirstResponder(lotText)
        AppDelegate.changePaneText(.bigger, in: window, store: store)
        check(lot.changes == [.bigger] && lots.isEmpty && store.paneTextSize == 16 && a.textSize == nil && b.textSize == nil,
              "A focused Parking Lot editor (or anything inside a PaneTextScalable) resizes only itself")
        window.makeFirstResponder(pane.text)
        AppDelegate.changePaneText(.bigger, in: window, store: store)
        check(lot.changes == [.bigger] && lots.isEmpty && a.textSize == 18 && b.textSize == nil && store.paneTextSize == 16, "A focused session pane resizes only that session")
        window.makeFirstResponder(nil)
        AppDelegate.changePaneText(.smaller, in: window, store: store)
        check(lots == [.smaller] && lot.changes == [.bigger] && store.paneTextSize == 15 && a.textSize == 16 && b.textSize == nil,
              "No focused pane: every session pane and every Parking Lot get the change")
        AppDelegate.changePaneText(.reset, in: window, store: store)
        check(lots == [.smaller, .reset] && store.paneTextSize == 16 && a.textSize == nil, "Actual Size with no focused pane resets sessions and lots together")
        PaneTextScaling.allLots = nil
        AppDelegate.changePaneText(.bigger, in: nil, store: store)
        check(store.paneTextSize == 18, "Without a lot hook, sessions still resize as before")
        window.contentView = nil
    }
}

/// Red (never taught) and yellow (outdated) banners from isolated fixture
/// sessions, rendered offscreen as the pane shows them.
func teachingBannerRenderSelfTests(_ check: (Bool, String) -> Void) {
    MainActor.assumeIsolated {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-banner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(folder: root)
        let echo = Entry(name: "Echo", command: "unused", directory: NSTemporaryDirectory(), engine: "muse")
        let untaught = store.create(echo), outdated = store.create(echo)
        outdated.switchboardEnabled = true; outdated.switchboardTeachingVersion = SwitchboardTeaching.version - 1
        func render(_ session: Session, png: String? = nil) -> (height: CGFloat, strings: [String], fill: NSColor?) {
            let width: CGFloat = 640
            let host = NSHostingView(rootView: SessionTeachingBanner(store: store, session: session).frame(width: width))
            host.appearance = NSAppearance(named: .aqua)
            let height = host.fittingSize.height
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: max(height, 1)), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
            let backing = NSView(frame: NSRect(x: 0, y: 0, width: width, height: max(height, 1)))
            backing.wantsLayer = true; backing.layer?.backgroundColor = NSColor.white.cgColor
            host.frame = backing.bounds; backing.addSubview(host); window.contentView = backing
            window.orderBack(nil); RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            var fill: NSColor?, strings: [String] = []
            if height > 1, let bitmap = backing.bitmapImageRepForCachingDisplay(in: backing.bounds) {
                backing.cacheDisplay(in: backing.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / width
                fill = bitmap.colorAt(x: Int(4 * scale), y: Int(height / 2 * scale))?.usingColorSpace(.sRGB)
                if let png, let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: png)) }
                strings = visibleText(bitmap)
            }
            window.orderOut(nil); window.close()
            return (height, strings, fill)
        }
        // OCR may read curly apostrophes as straight ones; compare letters, digits and spaces.
        func plain(_ text: String) -> String { String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }) }
        func has(_ strings: [String], _ text: String) -> Bool { strings.contains { plain($0).contains(plain(text)) } }
        check(store.teachingBanner(untaught) == .untaught && store.teachingBanner(outdated) == .outdated, "Fixture sessions: one never taught, one taught an older lesson")
        let red = render(untaught, png: "/tmp/claude-banner-red.png")
        check(red.height > 20 && has(red.strings, "This session can’t message other sessions yet.") && has(red.strings, "Teach it")
              && has(red.strings, "What’s this?") && has(red.strings, "Don’t show again") && !has(red.strings, "Re-teach"),
              "The red banner says the session can’t message others yet, with Teach it, What’s this? and Don’t show again (\(red.strings))")
        check(red.fill.map { $0.redComponent > 0.9 && $0.redComponent - $0.greenComponent > 0.04 && abs($0.greenComponent - $0.blueComponent) < 0.08 } ?? false,
              "The never-taught banner is red (\(red.fill.map { String(format: "%.2f %.2f %.2f", $0.redComponent, $0.greenComponent, $0.blueComponent) } ?? "none"))")
        let yellow = render(outdated, png: "/tmp/claude-banner-yellow.png")
        check(yellow.height > 20 && has(yellow.strings, "Converse’s session lessons changed. Please re-teach this session.") && has(yellow.strings, "Re-teach")
              && has(yellow.strings, "What’s this?") && has(yellow.strings, "Don’t show again") && !has(yellow.strings, "Teach it"),
              "The yellow banner asks to re-teach, with Re-teach, What’s this? and Don’t show again (\(yellow.strings))")
        check(yellow.fill.map { $0.redComponent > 0.9 && abs($0.redComponent - $0.greenComponent) < 0.05 && $0.greenComponent - $0.blueComponent > 0.08 } ?? false,
              "The outdated-lesson banner is yellow (\(yellow.fill.map { String(format: "%.2f %.2f %.2f", $0.redComponent, $0.greenComponent, $0.blueComponent) } ?? "none"))")
        check(FileManager.default.fileExists(atPath: "/tmp/claude-banner-red.png") && FileManager.default.fileExists(atPath: "/tmp/claude-banner-yellow.png"), "Banner snapshots saved for review")
        let agent = store.create(Entry(name: "Agent", command: "", directory: NSTemporaryDirectory(), engine: "agent")); agent.agent = AgentConfig()
        let support = store.create(Entry(name: "Support", command: "", directory: NSTemporaryDirectory(), engine: "support")); support.supportAssistant = true
        let imported = store.create(Entry(name: "Imported", command: "", directory: NSTemporaryDirectory(), engine: ConverseExchange.unboundEngine))
        let viewer = Session(entry: echo)
        check([agent, support, imported, viewer].allSatisfy { render($0).height < 1 }, "Agents, App Support, imports and remote viewers render no banner")
        store.dismissTeachingBanner(untaught)
        check(render(untaught).height < 1, "Don’t show again removes the rendered banner")
    }
}
