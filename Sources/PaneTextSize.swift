import AppKit

/// View ▸ Bigger (⌘+), Smaller (⌘−) and Actual Size (⌘0) for session panes:
/// the pane holding the text cursor, else every session pane. Parking Lot
/// panes keep their own size.
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
    static func scale(_ text: NSMutableAttributedString, by factor: CGFloat) {
        guard abs(factor - 1) > 0.001 else { return }
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            text.addAttribute(.font, value: NSFont(descriptor: font.fontDescriptor, size: font.pointSize * factor) ?? font, range: range)
        }
    }
}

enum PaneTextSizeChange { case bigger, smaller, actual }

extension Store {
    func textSize(for s: Session) -> Double { s.textSize ?? paneTextSize }
    /// With a focused pane, only that session changes (Actual Size returns it
    /// to the default). Otherwise the default and every pane change together.
    func changeTextSize(_ change: PaneTextSizeChange, focused: Session?) {
        func step(_ size: Double) -> Double {
            switch change {
            case .bigger: return PaneTextSize.bigger(size)
            case .smaller: return PaneTextSize.smaller(size)
            case .actual: return PaneTextSize.standard
            }
        }
        if let focused {
            let size = change == .actual ? paneTextSize : step(textSize(for: focused))
            focused.textSize = size == paneTextSize ? nil : size
        } else {
            paneTextSize = step(paneTextSize)
            for session in sessions + remoteTextSessions() {
                guard let size = session.textSize else { continue }
                let next = change == .actual ? paneTextSize : step(size)
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
    @objc func biggerText(_ sender: Any?) { Store.shared.changeTextSize(.bigger, focused: Self.focusedTextSession()) }
    @objc func smallerText(_ sender: Any?) { Store.shared.changeTextSize(.smaller, focused: Self.focusedTextSession()) }
    @objc func actualSizeText(_ sender: Any?) { Store.shared.changeTextSize(.actual, focused: Self.focusedTextSession()) }
}
