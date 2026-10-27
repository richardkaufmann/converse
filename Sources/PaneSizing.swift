import AppKit

enum PaneSizing {
    static let modelColumnThreshold: CGFloat = 360
    static let compactSidebar: CGFloat = modelColumnThreshold - 1
    static let minimumPane: CGFloat = 220
    static func split(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView, split.isVertical { return split }
        return view.subviews.lazy.compactMap { split(in: $0) }.first
    }
    static func sidebarWidth(in window: NSWindow) -> CGFloat? {
        split(in: window.contentView)?.arrangedSubviews.first?.frame.width
    }
    @discardableResult
    static func apply(to window: NSWindow, sidebar: CGFloat, paneCount: Int) -> Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let outer = split(in: window.contentView), outer.arrangedSubviews.count == 2 else { return false }
        outer.setPosition(sidebar, ofDividerAt: 0)
        outer.layoutSubtreeIfNeeded()
        guard paneCount > 0 else { return true }
        guard let inner = split(in: outer.arrangedSubviews[1]), inner.arrangedSubviews.count == paneCount else { return false }
        inner.layoutSubtreeIfNeeded()
        let width = (inner.bounds.width - CGFloat(paneCount - 1) * inner.dividerThickness) / CGFloat(paneCount)
        for index in 0..<(paneCount - 1) {
            inner.setPosition(CGFloat(index + 1) * width + CGFloat(index) * inner.dividerThickness, ofDividerAt: index)
        }
        return true
    }
}
