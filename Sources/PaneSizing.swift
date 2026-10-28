import AppKit

enum PaneSizing {
    static let modelColumnThreshold: CGFloat = 360
    static let compactSidebar: CGFloat = modelColumnThreshold - 1
    static let minimumSidebar: CGFloat = 160
    static let collapsedSidebar: CGFloat = 0
    static let minimumPane: CGFloat = 220
    static func split(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView, split.isVertical { return split }
        return view.subviews.lazy.compactMap { split(in: $0) }.first
    }
    static func sidebarWidth(in window: NSWindow) -> CGFloat? {
        split(in: window.contentView)?.arrangedSubviews.first?.frame.width
    }
    static func sidebar(preferred: CGFloat, reference: CGFloat, window: CGFloat, limit: CGFloat, paneCount: Int) -> CGFloat {
        let scaled = preferred * min(1, window / max(1, reference))
        let available = window - max(310, CGFloat(paneCount) * minimumPane) - 12
        return max(minimumSidebar, min(scaled, limit, available))
    }
    // Preserve proportions until a pane hits its readable minimum. Keep the
    // original weights so enlarging the window restores the user's proportions.
    static func widths(available: CGFloat, weights: [CGFloat]) -> [CGFloat] {
        guard !weights.isEmpty else { return [] }
        let weights = weights.map { $0.isFinite && $0 > 0 ? $0 : 1 }
        if available <= minimumPane * CGFloat(weights.count) { return weights.map { _ in max(0, available) / CGFloat(weights.count) } }
        var result = Array(repeating: CGFloat(0), count: weights.count)
        var remaining = Set(weights.indices), space = available
        while !remaining.isEmpty {
            let sum = remaining.reduce(CGFloat(0)) { $0 + weights[$1] }
            let constrained = remaining.filter { space * weights[$0] / sum < minimumPane }
            if constrained.isEmpty {
                for index in remaining { result[index] = space * weights[index] / sum }
                break
            }
            for index in constrained { result[index] = minimumPane; space -= minimumPane; remaining.remove(index) }
        }
        return result
    }
    @discardableResult
    static func apply(to window: NSWindow, sidebar: CGFloat, paneCount: Int, weights: [CGFloat] = []) -> Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let outer = split(in: window.contentView), outer.arrangedSubviews.count == 2 else { return false }
        outer.setPosition(sidebar, ofDividerAt: 0)
        outer.layoutSubtreeIfNeeded()
        guard paneCount > 0 else { return true }
        guard let inner = split(in: outer.arrangedSubviews[1]), inner.arrangedSubviews.count == paneCount else { return false }
        inner.layoutSubtreeIfNeeded()
        let sizes = widths(available: inner.bounds.width - CGFloat(paneCount - 1) * inner.dividerThickness, weights: weights.count == paneCount ? weights : Array(repeating: 1, count: paneCount))
        var position: CGFloat = 0
        for index in 0..<(paneCount - 1) {
            position += sizes[index]
            inner.setPosition(position, ofDividerAt: index)
            position += inner.dividerThickness
        }
        return true
    }
}

// Own sizing rather than accepting SwiftUI/AppKit's intermediate equalization
// during a resize. A count change resets session proportions; a window resize
// preserves them. Divider changes establish new user preferences.
final class WindowPaneLayout {
    weak var window: NSWindow?
    private(set) var paneCount = -1
    private(set) var preferredSidebar: CGFloat = 340
    private(set) var weights: [CGFloat] = []
    private(set) var sidebarCollapsed = false
    private var referenceWidth: CGFloat
    private var sidebarLimit: CGFloat = 480
    private var lastWidth: CGFloat
    private var lastSidebar: CGFloat = 340
    private var applying = false
    private var pending = false
    private var revision = 0
    private var lastExpandedSidebar: CGFloat = 340
    private var restoreSidebarCap: CGFloat?
    private var observers: [NSObjectProtocol] = []
    init(window: NSWindow) {
        self.window = window
        referenceWidth = window.contentRect(forFrameRect: window.frame).width; lastWidth = referenceWidth
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in self?.windowResized() })
        observers.append(NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let split = note.object as? NSSplitView, split.window === self.window else { return }
            self.dividerChanged()
        })
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    func setSidebarCollapsed(_ collapsed: Bool) {
        guard collapsed != sidebarCollapsed else { return }
        if collapsed, let window { lastExpandedSidebar = PaneSizing.sidebarWidth(in: window) ?? preferredSidebar }
        sidebarCollapsed = collapsed
        updateMinimumWidth()
        if !collapsed, let window {
            let width = window.contentRect(forFrameRect: window.frame).width
            preferredSidebar = lastExpandedSidebar; referenceWidth = width; sidebarLimit = 480
            restoreSidebarCap = width / 2
        }
        schedule()
    }
    private func updateMinimumWidth() {
        guard let window else { return }
        window.contentMinSize = NSSize(width: Workspace.minimumWidth(paneCount: max(0, paneCount), sidebarCollapsed: sidebarCollapsed), height: 540)
        let size = window.contentRect(forFrameRect: window.frame).size
        if size.width < window.contentMinSize.width { window.setContentSize(NSSize(width: window.contentMinSize.width, height: max(540, size.height))) }
    }
    func setPaneCount(_ count: Int) {
        guard count != paneCount, window != nil else { return }
        if count > paneCount && paneCount >= 0 && !sidebarCollapsed { sidebarLimit = min(sidebarLimit, PaneSizing.compactSidebar) }
        paneCount = count; weights = Array(repeating: 1, count: count)
        updateMinimumWidth()
        schedule()
    }
    private func windowResized() {
        guard !applying else { return }
        schedule()
    }
    private func dividerChanged() {
        guard !applying, !pending, let window, let outer = PaneSizing.split(in: window.contentView) else { return }
        let width = window.contentRect(forFrameRect: window.frame).width
        guard abs(width - lastWidth) < 0.5 else { schedule(); return }
        guard outer.arrangedSubviews.count == 2 else { return }
        let sidebar = outer.arrangedSubviews[0].frame.width
        if !sidebarCollapsed && abs(sidebar - lastSidebar) > 0.5 {
            preferredSidebar = sidebar; referenceWidth = width; sidebarLimit = 480
            schedule(); return
        }
        if let inner = PaneSizing.split(in: outer.arrangedSubviews[1]), inner.arrangedSubviews.count == paneCount {
            weights = inner.arrangedSubviews.map { max(1, $0.frame.width) }
        }
    }
    private func schedule() {
        revision += 1; let token = revision; pending = true
        DispatchQueue.main.async { [weak self] in self?.arrange(token, attempts: 8) }
    }
    private func arrange(_ token: Int, attempts: Int) {
        guard token == revision, let window else { return }
        let width = window.contentRect(forFrameRect: window.frame).width
        let sidebar = sidebarCollapsed ? PaneSizing.collapsedSidebar : PaneSizing.sidebar(preferred: preferredSidebar, reference: referenceWidth, window: width, limit: min(sidebarLimit, restoreSidebarCap ?? sidebarLimit), paneCount: max(0, paneCount))
        applying = true
        let success = PaneSizing.apply(to: window, sidebar: sidebar, paneCount: max(0, paneCount), weights: weights)
        applying = false
        if !success && attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.arrange(token, attempts: attempts - 1) }; return
        }
        lastWidth = width; lastSidebar = PaneSizing.sidebarWidth(in: window) ?? sidebar
        restoreSidebarCap = nil
        pending = false
    }
}

func paneSizingSelfTests(_ check: (Bool, String) -> Void) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let outer = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1400, height: 700)); outer.isVertical = true; outer.dividerStyle = .thin
    let inner = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700)); inner.isVertical = true; inner.dividerStyle = .thin
    outer.addArrangedSubview(NSView()); outer.addArrangedSubview(inner)
    for _ in 0..<3 { inner.addArrangedSubview(NSView()) }
    window.contentView = outer
    let layout = WindowPaneLayout(window: window)
    func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.12)) }
    func sizes() -> [CGFloat] { inner.arrangedSubviews.map { $0.frame.width } }
    layout.setPaneCount(3); settle()
    inner.setPosition(500, ofDividerAt: 0); settle()
    let preferred = sizes(), weights = layout.weights
    window.setContentSize(NSSize(width: 1800, height: 700)); settle()
    let larger = sizes()
    check(abs(larger[0] / larger[1] - preferred[0] / preferred[1]) < 0.02, "Native window resize retains manually dragged session-pane proportions")
    window.setContentSize(NSSize(width: 834, height: 700)); settle()
    check((PaneSizing.sidebarWidth(in: window) ?? 999) < 200 && sizes().allSatisfy { $0 >= 219 }, "A small native window compresses the sidebar while preserving readable session panes (sidebar: \(PaneSizing.sidebarWidth(in: window) ?? -1), panes: \(sizes()))")
    window.setContentSize(NSSize(width: 1800, height: 700)); settle()
    check(zip(layout.weights, weights).allSatisfy { abs($0 - $1) < 1 } && abs(sizes()[0] / sizes()[1] - preferred[0] / preferred[1]) < 0.02, "Growing after minimum-width clamping restores original proportions")
    outer.setPosition(420, ofDividerAt: 0); settle()
    window.setContentSize(NSSize(width: 1000, height: 700)); settle()
    window.setContentSize(NSSize(width: 1800, height: 700)); settle()
    check(abs((PaneSizing.sidebarWidth(in: window) ?? 0) - 420) < 2, "A manually chosen sidebar width returns after shrinking and enlarging")
    let removed = inner.arrangedSubviews.last!; inner.removeArrangedSubview(removed); removed.removeFromSuperview()
    layout.setPaneCount(2); settle()
    check(abs(sizes()[0] - sizes()[1]) < 2, "Removing a pane balances the surviving native panes")
    let left = PaneSizing.sidebarWidth(in: window) ?? 0
    inner.addArrangedSubview(NSView()); layout.setPaneCount(3); settle()
    check((sizes().max()! - sizes().min()!) < 2 && (PaneSizing.sidebarWidth(in: window) ?? 999) <= PaneSizing.compactSidebar + 1 && left > PaneSizing.compactSidebar, "Adding a pane balances all panes and compacts a wide sidebar")
    let expandedSidebar = PaneSizing.sidebarWidth(in: window) ?? 0
    let savedPreference = layout.preferredSidebar, savedWeights = layout.weights
    layout.setSidebarCollapsed(true); settle()
    check(abs((PaneSizing.sidebarWidth(in: window) ?? 999) - PaneSizing.collapsedSidebar) < 2 && layout.preferredSidebar == savedPreference, "The pin minimizes the native sidebar without overwriting its preferred width")
    window.setContentSize(NSSize(width: 900, height: 700)); settle()
    window.setContentSize(NSSize(width: 1800, height: 700)); settle()
    check(abs((PaneSizing.sidebarWidth(in: window) ?? 999) - PaneSizing.collapsedSidebar) < 2 && layout.weights == savedWeights, "A collapsed sidebar stays minimized during resizing and preserves session-pane proportions")
    layout.setSidebarCollapsed(false); settle()
    check(abs((PaneSizing.sidebarWidth(in: window) ?? 0) - expandedSidebar) < 2, "The pin restores the previous native sidebar width after resizing")
    window.close()
}
