import AppKit

/// View ▸ Bigger (⌘+), Smaller (⌘−) and Actual Size (⌘0): a focused view that
/// sizes its own text (PaneTextScalable), else the session pane holding the
/// text cursor, else every session pane and every Parking Lot.
enum PaneTextSize {
    static let standard: Double = 16
    static let range: ClosedRange<Double> = 9...28
    /// Every session shown in a pane, so a global change reaches remote viewers too.
    static let viewers = NSHashTable<Session>.weakObjects()
    static let steps: [Double] = [9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 26, 28]
    static func clamp(_ size: Double) -> Double { min(max(size, range.lowerBound), range.upperBound) }
    static func bigger(_ size: Double) -> Double { steps.first { $0 > size + 0.01 } ?? range.upperBound }
    static func smaller(_ size: Double) -> Double { steps.last { $0 < size - 0.01 } ?? range.lowerBound }
    /// Markdown renders at the standard size; a pane scales every font in it.
    /// Sizes round to 1/4096 pt, so stepping up and back down returns exactly.
    static func scale(_ text: NSMutableAttributedString, by factor: CGFloat) {
        guard abs(factor - 1) > 0.001 else { return }
        var scaled: [NSFont: NSFont] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let next = scaled[font] ?? {
                let size = (font.pointSize * factor * 4096).rounded() / 4096
                // The plain system font is the pane's body font: keep it exactly as a fresh render makes it.
                let made = font == NSFont.systemFont(ofSize: font.pointSize) ? NSFont.systemFont(ofSize: size) : NSFont(descriptor: font.fontDescriptor, size: size) ?? font
                scaled[font] = made; return made
            }()
            text.addAttribute(.font, value: next, range: range)
        }
    }
    /// A pane in a minimized or covered window resizes when it is next seen.
    static var isHidden: (NSWindow) -> Bool = { $0.isMiniaturized || ($0.isVisible && !$0.occlusionState.contains(.visible)) }
    /// Repeated presses inside this interval apply once, at the latest size.
    static var repeatInterval: TimeInterval = 0.12
}

extension Store {
    func textSize(for s: Session) -> Double { s.textSize ?? paneTextSize }
    /// With a focused pane, only that session changes (Actual Size returns it
    /// to the default). Otherwise the default and every pane change together.
    func changeTextSize(_ change: PaneTextChange, focused: Session?) {
        func step(_ size: Double) -> Double {
            switch change {
            case .bigger: return PaneTextSize.bigger(size)
            case .smaller: return PaneTextSize.smaller(size)
            case .reset: return PaneTextSize.standard
            }
        }
        if let focused {
            let size = change == .reset ? paneTextSize : step(textSize(for: focused))
            focused.textSize = size == paneTextSize ? nil : size
        } else {
            paneTextSize = step(paneTextSize)
            for session in sessions + remoteTextSessions() {
                guard let size = session.textSize else { continue }
                let next = change == .reset ? paneTextSize : step(size)
                session.textSize = next == paneTextSize ? nil : next
            }
        }
        if focused == nil || sessions.contains(where: { $0 === focused }) { save() }
    }
    /// Remote viewers' editors are not archived; they keep a size for this launch.
    func remoteTextSessions() -> [Session] { PaneTextSize.viewers.allObjects.filter { session in !sessions.contains { $0 === session } } }
}

extension AppDelegate {
    /// The session whose conversation text view holds the cursor.
    static func focusedTextSession(in window: NSWindow? = NSApp.keyWindow) -> Session? {
        guard let text = window?.firstResponder as? ConversationTextView else { return nil }
        return (text.delegate as? ScrollingConversation.Coordinator)?.session
    }
    /// The first PaneTextScalable from the first responder up its superviews,
    /// else the focused session pane, else every session pane and every lot.
    static func changePaneText(_ change: PaneTextChange, in window: NSWindow? = NSApp.keyWindow, store: Store = .shared) {
        if let scalable = window?.firstResponder as? PaneTextScalable { scalable.applyPaneText(change); return }
        var view = window?.firstResponder as? NSView
        while let current = view {
            if let scalable = current as? PaneTextScalable { scalable.applyPaneText(change); return }
            view = current.superview
        }
        if let scalable = window?.contentView as? PaneTextScalable { scalable.applyPaneText(change); return }
        if let session = focusedTextSession(in: window) { store.changeTextSize(change, focused: session); return }
        store.changeTextSize(change, focused: nil)
        PaneTextScaling.allLots?(change)
    }
    @objc func biggerText(_ sender: Any?) { Self.changePaneText(.bigger) }
    @objc func smallerText(_ sender: Any?) { Self.changePaneText(.smaller) }
    @objc func actualSizeText(_ sender: Any?) { Self.changePaneText(.reset) }
}
