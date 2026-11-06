import AppKit
import SwiftUI

// Teaching banners (never / older / current / dismissed) and pane text size.
func sessionTeachingSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-teaching-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root)
    func wait(_ done: () -> Bool, seconds: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }
    let command = ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] ?? "muse"
    let echo = Entry(name: "Echo", command: command, directory: NSTemporaryDirectory(), engine: "muse")
    let plain = store.create(echo)
    check(store.teachingBanner(plain) == .untaught && plain.switchboardTeachingVersion == nil, "A session never taught shows the red teaching banner")
    store.teachSwitchboard(plain)
    check(plain.switchboardEnabled && plain.switchboardTeachingVersion == SwitchboardTeaching.version && store.teachingBanner(plain) == nil,
          "Teaching records the current lesson version and clears the banner")
    wait { !plain.busy && plain.pending.isEmpty }
    check(plain.messages.contains { $0.role == "user" && $0.text.contains("[Converse switchboard instructions]") }, "Teach it runs the existing teaching turn")
    plain.switchboardTeachingVersion = SwitchboardTeaching.version - 1
    check(store.teachingBanner(plain) == .outdated, "A session taught an older lesson shows the yellow Re-teach banner")
    plain.switchboardEnabled = false
    check(store.teachingBanner(plain) == nil, "Session messaging turned off shows no banner")
    plain.switchboardEnabled = true
    store.dismissTeachingBanner(plain)
    check(store.teachingBanner(plain) == nil && plain.teachingBannerDismissed == SwitchboardTeaching.version, "Don’t show again hides the banner for this lesson version")
    plain.teachingBannerDismissed = SwitchboardTeaching.version - 1
    check(store.teachingBanner(plain) == .outdated, "A dismissal for an earlier lesson version does not hide a newer banner")
    let fresh = store.create(echo)
    store.dismissTeachingBanner(fresh)
    check(store.teachingBanner(fresh) == nil, "The red banner can be dismissed for this version too")

    // Agents, App Support, unbound imports and remote viewers never show it.
    let agent = store.create(Entry(name: "Agent", command: "", directory: NSTemporaryDirectory(), engine: "agent")); agent.agent = AgentConfig()
    let support = store.create(Entry(name: "Support", command: "", directory: NSTemporaryDirectory(), engine: "support")); support.supportAssistant = true
    let imported = store.create(Entry(name: "Imported", command: "", directory: NSTemporaryDirectory(), engine: ConverseExchange.unboundEngine))
    let viewer = Session(entry: echo)
    check([agent, support, imported, viewer].allSatisfy { store.teachingBanner($0) == nil }, "Agents, App Support, unbound imports and remote viewers show no teaching banner")

    // Archives: the version and dismissal survive relaunch; older taught
    // sessions decode as version 1, untaught ones as never taught.
    plain.switchboardTeachingVersion = SwitchboardTeaching.version
    store.save()
    let reloaded = Store(folder: root)
    let again = reloaded.sessions.first { $0.id == plain.id }, freshAgain = reloaded.sessions.first { $0.id == fresh.id }
    check(again?.switchboardTeachingVersion == SwitchboardTeaching.version && freshAgain?.teachingBannerDismissed == SwitchboardTeaching.version,
          "Teaching version and banner dismissal survive relaunch")
    func legacy(_ enabled: Bool?) -> Session? {
        guard var object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(plain.saved)) as? [String: Any] else { return nil }
        for key in ["switchboardTeachingVersion", "teachingBannerDismissed", "textSize"] { object[key] = nil }
        object["switchboardEnabled"] = enabled
        return (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(SavedSession.self, from: $0) }.map(Session.init)
    }
    let taughtBefore = legacy(true), neverTaught = legacy(nil)
    check(taughtBefore?.switchboardTeachingVersion == 1 && taughtBefore?.textSize == nil && neverTaught?.switchboardTeachingVersion == nil,
          "Older archives decode taught sessions as lesson version 1 and others as never taught")
    if let taughtBefore {
        reloaded.sessions.append(taughtBefore)
        check(reloaded.teachingBanner(taughtBefore) == .outdated, "Sessions taught before lesson versions show yellow once")
    }
    check(SwitchboardTeaching.version > 1, "The current lesson is newer than the unversioned one")

    // The banner and its explanation render.
    for banner in [TeachingBanner.untaught, .outdated] {
        let view = NSHostingView(rootView: TeachingBannerView(banner: banner, teach: {}, dismiss: {}).frame(width: 640))
        check(view.fittingSize.height > 10, "The \(banner == .untaught ? "red" : "yellow") teaching banner renders")
    }
    let explanation = NSHostingView(rootView: TeachingExplanation().frame(width: 360))
    check(explanation.fittingSize.height > 60 && SwitchboardTeaching.controlHelp.contains("operate Converse") && SwitchboardTeaching.talkHelp.contains("Parking Lots"),
          "What’s this? explains both lessons plainly")
}

func paneTextSizeSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-textsize-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root)
    let entry = Entry(name: "Echo", command: "unused", directory: NSTemporaryDirectory(), engine: "muse")
    let a = store.create(entry), b = store.create(entry)
    check(store.paneTextSize == PaneTextSize.standard && store.textSize(for: a) == 16, "Panes start at the standard 16 pt")
    store.changeTextSize(.bigger, focused: a)
    check(store.textSize(for: a) == 18 && b.textSize == nil && store.paneTextSize == 16, "With a focused pane, Bigger changes only that pane")
    store.changeTextSize(.bigger, focused: nil)
    check(store.paneTextSize == 18 && store.textSize(for: b) == 18 && store.textSize(for: a) == 20, "Without a focused pane, Bigger changes every pane")
    store.changeTextSize(.smaller, focused: a)
    check(a.textSize == nil && store.textSize(for: a) == 18, "A pane back at the default follows later global changes")
    for _ in 0..<30 { store.changeTextSize(.bigger, focused: b) }
    check(store.textSize(for: b) == PaneTextSize.range.upperBound, "Bigger stops at 28 pt")
    for _ in 0..<30 { store.changeTextSize(.smaller, focused: nil) }
    check(store.paneTextSize == PaneTextSize.range.lowerBound && store.textSize(for: b) == PaneTextSize.range.lowerBound, "Smaller stops at 9 pt")
    check(PaneTextSize.clamp(40) == 28 && PaneTextSize.clamp(2) == 9 && PaneTextSize.bigger(16.5) == 18 && PaneTextSize.smaller(9) == 9, "Sizes clamp to 9–28 pt")
    store.changeTextSize(.actual, focused: nil)
    store.changeTextSize(.bigger, focused: nil); store.changeTextSize(.bigger, focused: b)
    store.changeTextSize(.actual, focused: b)
    check(b.textSize == nil && store.textSize(for: b) == 18, "Actual Size on a focused pane returns it to the default")
    store.changeTextSize(.bigger, focused: a)
    let reloaded = Store(folder: root)
    check(reloaded.paneTextSize == 18 && reloaded.sessions.first { $0.id == a.id }?.textSize == 20 && reloaded.sessions.first { $0.id == b.id }?.textSize == nil,
          "The default and per-pane sizes survive relaunch")
    store.changeTextSize(.actual, focused: nil)
    check(store.paneTextSize == 16 && a.textSize == nil && b.textSize == nil, "Actual Size with no focused pane resets every pane")

    // Focus: the session whose conversation text view holds the cursor.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = ConversationScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
    scroll.contentView = InputClipView(); scroll.hasVerticalScroller = true
    let text = ConversationTextView(frame: scroll.contentView.bounds)
    text.isVerticallyResizable = true; text.isHorizontallyResizable = false
    text.minSize = NSSize(width: 0, height: 400); text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
    text.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
    text.textContainerInset = NSSize(width: 12, height: 12)
    scroll.documentView = text; window.contentView = scroll; scroll.tile()
    let coordinator = ScrollingConversation.Coordinator(a); text.delegate = coordinator
    window.makeFirstResponder(text)
    check(AppDelegate.focusedTextSession(in: window) === a, "The pane with the text cursor is the focused pane")
    window.makeFirstResponder(nil)
    check(AppDelegate.focusedTextSession(in: window) == nil, "No landed cursor means every pane")

    // Rendering at a new size keeps the draft, the selection and the reading position.
    a.messages = (0..<40).flatMap { [Message(role: "user", text: "Question \($0)"), Message(role: "assistant", text: "# Heading \($0)\nA reply line with **bold** and `code` that wraps across the pane width.")] }
    a.draft = "My unsent draft"
    coordinator.render(text); scroll.tile()
    func font(at location: Int) -> NSFont? { text.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont }
    let heading = (text.string as NSString).range(of: "Heading 20").location
    check(font(at: 0)?.pointSize == 16 && font(at: heading)?.pointSize == 21, "Fixture renders at the standard size")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: text.frame.height / 2)); scroll.reflectScrolledClipView(scroll.contentView); scroll.recordScroll()
    let draftSelection = NSRange(location: text.inputStart + 3, length: 6)
    text.setSelectedRange(draftSelection)
    let top = text.topVisibleCharacter() ?? -1
    let topLine = (text.string as NSString).lineRange(for: NSRange(location: max(0, top), length: 0))
    let before = text.string
    store.changeTextSize(.bigger, focused: a); store.changeTextSize(.bigger, focused: a)
    text.fontSize = CGFloat(store.textSize(for: a))
    coordinator.render(text)
    check(text.fontSize == 20 && font(at: 0)?.pointSize == 20 && abs((font(at: heading)?.pointSize ?? 0) - 21 * 20 / 16) < 0.01 && font(at: text.inputStart)?.pointSize == 20,
          "Bigger rescales the transcript, Markdown headings and the draft")
    check(text.string == before && a.draft == "My unsent draft" && text.selectedRange() == draftSelection, "Changing size keeps the draft and selection")
    let newTop = text.topVisibleCharacter() ?? -1
    check(NSLocationInRange(newTop, topLine) || abs(newTop - top) < 80, "Changing size keeps the same text at the top of the pane (\(top) → \(newTop))")
    check(text.typingAttributes[.font].flatMap { $0 as? NSFont }?.pointSize == 20, "New typing uses the pane size")
    window.contentView = nil
}
