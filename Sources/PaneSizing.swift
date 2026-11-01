import AppKit
import SwiftUI

// Transparent handles overlap the pane edges, so easier grabbing costs no
// transcript space. Keep SwiftUI's split-view delegates and constraints intact.
final class PaneDividerHandle: NSView {
    static let hitWidth: CGFloat = 14
    weak var split: NSSplitView?
    let dividerIndex: Int
    private var tracking: NSTrackingArea?
    private var dragStart: (pointer: CGFloat, divider: CGFloat)?
    init(split: NSSplitView, index: Int) {
        self.split = split; dividerIndex = index
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseExited(with event: NSEvent) { if dragStart == nil { NSCursor.arrow.set() } }
    override func mouseDown(with event: NSEvent) {
        guard let split, split.arrangedSubviews.indices.contains(dividerIndex + 1) else { return }
        dragStart = (split.convert(event.locationInWindow, from: nil).x, split.arrangedSubviews[dividerIndex].frame.maxX)
        NSCursor.resizeLeftRight.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let split, let dragStart, split.arrangedSubviews.indices.contains(dividerIndex + 1) else { return }
        let position = dragStart.divider + split.convert(event.locationInWindow, from: nil).x - dragStart.pointer
        split.setPosition(max(split.minPossiblePositionOfDivider(at: dividerIndex), min(position, split.maxPossiblePositionOfDivider(at: dividerIndex))), ofDividerAt: dividerIndex)
        NSCursor.resizeLeftRight.set()
    }
    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        window?.invalidateCursorRects(for: self)
    }
}

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
        var position: CGFloat = 0, positions: [CGFloat] = []
        for index in 0..<(paneCount - 1) {
            position += sizes[index]; positions.append(position)
            position += inner.dividerThickness
        }
        // Moving a divider can be constrained by its neighbour's old position.
        // Clear space from both directions before considering the layout done.
        for index in positions.indices.reversed() { inner.setPosition(positions[index], ofDividerAt: index) }
        for index in positions.indices { inner.setPosition(positions[index], ofDividerAt: index) }
        return true
    }
}

// Own sizing rather than accepting SwiftUI/AppKit's intermediate equalization
// during a resize. Count changes and window resizes equalize session panes.
// Divider changes last until the next window resize.
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
    private var countChangeSidebar: CGFloat?
    private var observers: [NSObjectProtocol] = []
    private var dividerHandles: [PaneDividerHandle] = []
    init(window: NSWindow) {
        self.window = window
        referenceWidth = window.contentRect(forFrameRect: window.frame).width; lastWidth = referenceWidth
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in self?.windowResized() })
        observers.append(NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let split = note.object as? NSSplitView, split.window === self.window else { return }
            self.dividerChanged()
            self.refreshDividerHandles()
        })
    }
    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for handle in dividerHandles { handle.removeFromSuperview() }
    }
    private func refreshDividerHandles() {
        guard let root = window?.contentView, let outer = PaneSizing.split(in: root) else { return }
        var splits: [NSSplitView] = sidebarCollapsed ? [] : [outer]
        if outer.arrangedSubviews.count == 2, let inner = PaneSizing.split(in: outer.arrangedSubviews[1]) { splits.append(inner) }
        var active: [PaneDividerHandle] = []
        for split in splits where split.arrangedSubviews.count > 1 {
            for index in 0..<(split.arrangedSubviews.count - 1) {
                let handle = dividerHandles.first { $0.split === split && $0.dividerIndex == index } ?? PaneDividerHandle(split: split, index: index)
                let edge = split.arrangedSubviews[index].frame.maxX + split.dividerThickness / 2
                let rect = NSRect(x: edge - PaneDividerHandle.hitWidth / 2, y: split.bounds.minY, width: PaneDividerHandle.hitWidth, height: split.bounds.height)
                handle.frame = root.convert(rect, from: split).intersection(root.bounds)
                if handle.superview !== root { root.addSubview(handle, positioned: .above, relativeTo: nil) }
                window?.invalidateCursorRects(for: handle)
                active.append(handle)
            }
        }
        for handle in dividerHandles where !active.contains(where: { $0 === handle }) { handle.removeFromSuperview() }
        dividerHandles = active
    }
    func setSidebarCollapsed(_ collapsed: Bool) {
        guard collapsed != sidebarCollapsed else { return }
        if collapsed, let window { lastExpandedSidebar = PaneSizing.sidebarWidth(in: window) ?? preferredSidebar }
        sidebarCollapsed = collapsed; countChangeSidebar = nil
        updateMinimumWidth()
        if !collapsed, let window {
            let width = window.contentRect(forFrameRect: window.frame).width
            preferredSidebar = lastExpandedSidebar; referenceWidth = width; sidebarLimit = 480
            restoreSidebarCap = width / 2
        }
        schedule()
    }
    private func updateMinimumWidth(preservingSidebar: CGFloat? = nil) {
        guard let window else { return }
        let base = Workspace.minimumWidth(paneCount: max(0, paneCount), sidebarCollapsed: sidebarCollapsed)
        let preserved = (preservingSidebar ?? 0) + max(310, CGFloat(max(0, paneCount)) * PaneSizing.minimumPane) + 12
        window.contentMinSize = NSSize(width: max(base, preserved), height: 540)
        let size = window.contentRect(forFrameRect: window.frame).size
        if size.width < window.contentMinSize.width { window.setContentSize(NSSize(width: window.contentMinSize.width, height: max(540, size.height))) }
    }
    func setPaneCount(_ count: Int) {
        guard count != paneCount, let window else { return }
        // Capture the displayed sidebar before SwiftUI replaces its pane tree.
        // Rapid count changes retain this same width through intermediate layouts.
        if paneCount >= 0 { countChangeSidebar = countChangeSidebar ?? (sidebarCollapsed ? PaneSizing.collapsedSidebar : PaneSizing.sidebarWidth(in: window) ?? lastSidebar) }
        pending = true
        paneCount = count; weights = Array(repeating: 1, count: count)
        updateMinimumWidth(preservingSidebar: countChangeSidebar)
        if let width = countChangeSidebar, !sidebarCollapsed {
            preferredSidebar = width; referenceWidth = window.contentRect(forFrameRect: window.frame).width
            sidebarLimit = 480; restoreSidebarCap = nil
        }
        schedule()
    }
    private func windowResized() {
        guard !applying else { return }
        weights = Array(repeating: 1, count: max(0, paneCount))
        schedule()
        if let root = window?.contentView { followTail(in: root) }
    }
    private func followTail(in view: NSView) {
        if let scroll = view as? ConversationScrollView { scroll.revealInitialTail() }
        for child in view.subviews { followTail(in: child) }
    }
    private func dividerChanged() {
        guard !applying, let window, let outer = PaneSizing.split(in: window.contentView) else { return }
        if pending { schedule(); return }
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
        let sidebar = sidebarCollapsed ? PaneSizing.collapsedSidebar : countChangeSidebar ?? PaneSizing.sidebar(preferred: preferredSidebar, reference: referenceWidth, window: width, limit: min(sidebarLimit, restoreSidebarCap ?? sidebarLimit), paneCount: max(0, paneCount))
        applying = true
        let success = PaneSizing.apply(to: window, sidebar: sidebar, paneCount: max(0, paneCount), weights: weights)
        applying = false
        if !success {
            if attempts > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.arrange(token, attempts: attempts - 1) } }
            // A remote pane can mount after these short retries. Its native
            // layout notification will retry; do not adopt intermediate widths.
            return
        }
        lastWidth = width; lastSidebar = PaneSizing.sidebarWidth(in: window) ?? sidebar
        restoreSidebarCap = nil; countChangeSidebar = nil
        // The temporary growth floor protects the sidebar during the count
        // transition; later manual window resizing keeps its usual minimum.
        window.contentMinSize = NSSize(width: Workspace.minimumWidth(paneCount: max(0, paneCount), sidebarCollapsed: sidebarCollapsed), height: 540)
        pending = false
        refreshDividerHandles()
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
    let content = NSView(frame: outer.frame)
    outer.autoresizingMask = [.width, .height]; content.addSubview(outer)
    window.contentView = content
    let layout = WindowPaneLayout(window: window)
    func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.12)) }
    func sizes() -> [CGFloat] { inner.arrangedSubviews.map { $0.frame.width } }
    layout.setPaneCount(3); settle()
    let handles = content.subviews.compactMap { $0 as? PaneDividerHandle }
    check(handles.count == 3 && handles.allSatisfy { abs($0.frame.width - 14) < 0.1 } && outer.dividerThickness <= 1,
          "All gutters have wider invisible handles without widening drawn dividers")
    if let handle = handles.first(where: { $0.split === inner && $0.dividerIndex == 0 }) {
        let before = inner.arrangedSubviews[0].frame.width
        let start = NSPoint(x: handle.frame.midX + 5, y: handle.frame.midY)
        check(content.hitTest(start) === handle && content.hitTest(NSPoint(x: handle.frame.maxX + 2, y: start.y)) !== handle,
              "A gutter catches clicks five points off its line but leaves nearby content interactive")
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: content.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        handle.mouseDown(with: event(.leftMouseDown, start))
        check(abs(inner.arrangedSubviews[0].frame.width - before) < 0.1, "An off-center gutter grab does not jump the divider")
        handle.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: start.x + 45, y: start.y)))
        handle.mouseUp(with: event(.leftMouseUp, NSPoint(x: start.x + 45, y: start.y)))
        settle()
        check(abs(inner.arrangedSubviews[0].frame.width - before - 45) < 2, "Dragging the wider gutter moves its native divider by the pointer delta")
        handle.cursorUpdate(with: event(.mouseMoved, start))
        check(NSCursor.current == NSCursor.resizeLeftRight, "Gutter hover selects the horizontal resize cursor")
        NSCursor.arrow.set()
    } else { check(false, "Session gutter handle is installed") }
    inner.setPosition(500, ofDividerAt: 0); settle()
    _ = sizes()
    window.setContentSize(NSSize(width: 1800, height: 700)); settle()
    let larger = sizes()
    check(larger.max()! - larger.min()! < 2, "Window resize equalizes manually dragged session panes")
    window.setContentSize(NSSize(width: 834, height: 700)); settle()
    check((PaneSizing.sidebarWidth(in: window) ?? 999) < 200 && sizes().allSatisfy { $0 >= 219 }, "A small native window compresses the sidebar while preserving readable session panes (sidebar: \(PaneSizing.sidebarWidth(in: window) ?? -1), panes: \(sizes()))")
    window.setContentSize(NSSize(width: 1800, height: 700)); settle()
    check(sizes().max()! - sizes().min()! < 2, "Growing after minimum-width clamping keeps panes equal")
    outer.setPosition(420, ofDividerAt: 0); settle()
    window.setContentSize(NSSize(width: 1000, height: 700)); settle()
    window.setContentSize(NSSize(width: 1800, height: 700)); settle()
    check(abs((PaneSizing.sidebarWidth(in: window) ?? 0) - 420) < 2, "A manually chosen sidebar width returns after shrinking and enlarging")
    let removed = inner.arrangedSubviews.last!; inner.removeArrangedSubview(removed); removed.removeFromSuperview()
    layout.setPaneCount(2); settle()
    check(abs(sizes()[0] - sizes()[1]) < 2 && abs((PaneSizing.sidebarWidth(in: window) ?? 0) - 420) < 2, "Removing a pane balances survivors without changing the sidebar")
    let left = PaneSizing.sidebarWidth(in: window) ?? 0
    inner.addArrangedSubview(NSView()); layout.setPaneCount(3); settle()
    check((sizes().max()! - sizes().min()!) < 2 && abs((PaneSizing.sidebarWidth(in: window) ?? 0) - left) < 2, "Adding a pane balances all panes without changing the sidebar")
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
    swiftUIPaneCountSelfTests(check)
}

private final class PaneCountFixture: ObservableObject {
    @Published var count = 1
}
private struct PaneCountFixtureView: View {
    @ObservedObject var fixture: PaneCountFixture
    var body: some View {
        HSplitView {
            Text("Sidebar").frame(minWidth: 160, idealWidth: 420, maxWidth: 480, maxHeight: .infinity)
            HSplitView {
                ForEach(0..<fixture.count, id: \.self) { i in
                    Text("Session \(i)").frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minWidth: 310, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

func swiftUIPaneCountSelfTests(_ check: (Bool, String) -> Void) {
    let fixture = PaneCountFixture()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: PaneCountFixtureView(fixture: fixture))
    let layout = WindowPaneLayout(window: window)
    func settle() { window.contentView?.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
    func inner() -> NSSplitView? { PaneSizing.split(in: window.contentView).flatMap { $0.arrangedSubviews.count == 2 ? PaneSizing.split(in: $0.arrangedSubviews[1]) : nil } }
    func widths() -> [CGFloat] { inner()?.arrangedSubviews.map { $0.frame.width } ?? [] }
    layout.setPaneCount(1); settle()
    PaneSizing.split(in: window.contentView)?.setPosition(420, ofDividerAt: 0); settle()
    let sidebar = PaneSizing.sidebarWidth(in: window) ?? 0
    for count in [2, 3, 2, 1, 0, 2, 3] {
        // Like @Published's willSet delivery: scheduling sees the old SwiftUI tree.
        layout.setPaneCount(count); fixture.count = count; settle()
        let sizes = widths()
        check(sizes.count == count && (sizes.max() ?? 0) - (sizes.min() ?? 0) < 2 && abs((PaneSizing.sidebarWidth(in: window) ?? 0) - sidebar) < 2,
              "SwiftUI count change to \(count) equalizes panes and preserves sidebar (panes: \(sizes), sidebar: \(PaneSizing.sidebarWidth(in: window) ?? -1))")
        if count > 1 { inner()?.setPosition(280, ofDividerAt: 0); settle() }
    }
    layout.setPaneCount(1); fixture.count = 1; settle()
    layout.setPaneCount(3)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    fixture.count = 3; settle()
    check(widths().count == 3 && (widths().max() ?? 0) - (widths().min() ?? 0) < 2 && abs((PaneSizing.sidebarWidth(in: window) ?? 0) - sidebar) < 2,
          "A delayed SwiftUI pane mount still equalizes after the initial sizing retries")
    inner()?.setPosition(280, ofDividerAt: 0); settle()
    let before = widths(); layout.setPaneCount(3); settle()
    check(zip(widths(), before).allSatisfy { abs($0 - $1) < 2 }, "Same-count updates preserve manually dragged pane widths")
    layout.setPaneCount(2); fixture.count = 2; settle()
    window.setContentSize(NSSize(width: 1000, height: 700)); settle()
    PaneSizing.split(in: window.contentView)?.setPosition(420, ofDividerAt: 0); settle()
    let narrowSidebar = PaneSizing.sidebarWidth(in: window) ?? 0
    layout.setPaneCount(3); fixture.count = 3; settle()
    check(abs((PaneSizing.sidebarWidth(in: window) ?? 0) - narrowSidebar) < 2 && widths().allSatisfy { $0 >= 219 } && (widths().max() ?? 0) - (widths().min() ?? 0) < 2,
          "Adding a pane to a narrow window grows the window instead of stealing sidebar width")
    window.setContentSize(NSSize(width: 834, height: 700)); settle()
    check(window.contentRect(forFrameRect: window.frame).width < 900 && widths().allSatisfy { $0 >= 219 }, "Count-change sidebar protection does not prevent later manual window shrinking")
    window.close()
}
