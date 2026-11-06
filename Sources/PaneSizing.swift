import AppKit
import os
import SwiftUI

private let gutterLog = Logger(subsystem: "local.richard.Converse", category: "gutter")

// Transparent handles overlap the pane edges, so easier grabbing costs no
// transcript space. Keep SwiftUI's split-view delegates and constraints intact.
final class PaneDividerHandle: NSView {
    static let hitWidth: CGFloat = 14
    weak var split: NSSplitView?
    let dividerIndex: Int
    private var tracking: NSTrackingArea?
    private var dragStart: (pointer: CGFloat, divider: CGFloat)?
    private var lastDragEvent = Date.distantPast
    private var pendingPosition: CGFloat?
    private var dragFrame: DispatchWorkItem?
    private var idleCheck: DispatchWorkItem?
    private var releaseMonitor: Any?
    private var lastLocationInWindow: NSPoint = .zero
    /// Tests override this to drive the held and released paths deterministically;
    /// production reads the real hardware button.
    var buttonDownOverride: (() -> Bool)?
    private let wrapping = WrapFreeze()
    private var thawedOnPause = false
    /// Pointer motion stops count as the end of dragging for wrapping: reflow
    /// follows quickly even with the button still held.
    private static let idleThawInterval: TimeInterval = 0.4
    /// A missed release (button let go off the gutter or outside the app) can
    /// never freeze wrapping longer than this.
    static let staleDragInterval: TimeInterval = 2
    var dragBegan: (() -> Void)?
    var dragEnded: (() -> Void)?
    deinit { dragFrame?.cancel(); idleCheck?.cancel(); stopReleaseMonitor(); wrapping.thaw() }
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
        dragFrame?.cancel(); dragFrame = nil; pendingPosition = nil
        dragStart = (split.convert(event.locationInWindow, from: nil).x, split.arrangedSubviews[dividerIndex].frame.maxX)
        lastLocationInWindow = event.locationInWindow
        lastDragEvent = Date()
        gutterLog.info("gutter drag began")
        thawedOnPause = false
        wrapping.freeze(in: window?.contentView)
        let frozen = wrapping.count
        gutterLog.debug("froze \(frozen, privacy: .public) containers")
        dragBegan?()
        startReleaseMonitor()
        scheduleIdleCheck()
        NSCursor.resizeLeftRight.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let split, let dragStart, split.arrangedSubviews.indices.contains(dividerIndex + 1) else { return }
        lastDragEvent = Date()
        lastLocationInWindow = event.locationInWindow
        // A pause thawed wrapping while the button stayed down; suspend it
        // again as soon as the pointer moves.
        if thawedOnPause {
            thawedOnPause = false
            wrapping.freeze(in: window?.contentView)
            let refrozen = wrapping.count
            gutterLog.debug("refroze \(refrozen, privacy: .public) containers on pointer motion")
        }
        pendingPosition = dragStart.divider + split.convert(event.locationInWindow, from: nil).x - dragStart.pointer
        // Consume only the newest pointer position each display interval.
        // Reflowing every queued mouse event makes long transcripts lag behind.
        if dragFrame == nil {
            let frame = DispatchWorkItem { [weak self] in self?.applyDragFrame() }
            dragFrame = frame
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: frame)
        }
        NSCursor.resizeLeftRight.set()
    }
    private func applyDragFrame() {
        dragFrame = nil
        guard let split, let position = pendingPosition, split.arrangedSubviews.indices.contains(dividerIndex + 1) else { return }
        pendingPosition = nil
        let constrained = max(split.minPossiblePositionOfDivider(at: dividerIndex), min(position, split.maxPossiblePositionOfDivider(at: dividerIndex)))
        if abs(split.arrangedSubviews[dividerIndex].frame.maxX - constrained) > 0.25 { split.setPosition(constrained, ofDividerAt: dividerIndex) }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        gutterLog.info("drag ended via handle mouseUp")
        endDrag(at: event.locationInWindow)
    }
    // AppKit delivers mouseUp to the view under the cursor, not necessarily
    // this handle, so releasing outside the gutter never calls mouseUp here.
    // A local event monitor catches those in-app releases; the idle sweep
    // below is the backstop for releases outside the app. Shared with the
    // monitor so both paths apply the identical release exactly once.
    func endDrag(at locationInWindow: NSPoint) {
        guard let split, let start = dragStart else { return }
        stopReleaseMonitor(); idleCheck?.cancel(); idleCheck = nil
        dragFrame?.cancel(); dragFrame = nil
        pendingPosition = start.divider + split.convert(locationInWindow, from: nil).x - start.pointer
        applyDragFrame()
        let thawing = wrapping.count
        gutterLog.debug("thawing \(thawing, privacy: .public) containers")
        dragStart = nil; wrapping.thaw(); dragEnded?()
        window?.invalidateCursorRects(for: self)
    }
    private func startReleaseMonitor() {
        stopReleaseMonitor()
        releaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            // A release in another window has foreign coordinates; leave it
            // to the stale sweep instead of jumping the divider to garbage.
            if self?.dragStart != nil, event.window === self?.window {
                gutterLog.info("drag ended via release monitor")
                self?.endDrag(at: event.locationInWindow)
            } else if self?.dragStart != nil {
                gutterLog.info("release monitor ignored mouseUp: window mismatch")
            }
            return event
        }
    }
    private func stopReleaseMonitor() {
        if let monitor = releaseMonitor { NSEvent.removeMonitor(monitor); releaseMonitor = nil }
    }
    private func scheduleIdleCheck() {
        idleCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in self?.idleCheckFired() }
        idleCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleThawInterval, execute: check)
    }
    // Visible to the same-file self-tests, which drive a button-up idle check directly.
    private func isButtonDown() -> Bool {
        buttonDownOverride?() ?? (NSEvent.pressedMouseButtons & 1 != 0)
    }
    private func idleCheckFired() {
        idleCheck = nil
        guard dragStart != nil else { return }
        gutterLog.debug("idle check: buttons=\(NSEvent.pressedMouseButtons, privacy: .public)")
        // The button is already up but no release reached this handle or the
        // monitor. End the drag only once events have gone quiet: ending on
        // button-up alone would kill an active tap-to-drag mid-gesture.
        if !isButtonDown() {
            let quiet = Date().timeIntervalSince(lastDragEvent) > Self.idleThawInterval
            gutterLog.info("idle check: button up, quiet=\(quiet, privacy: .public)")
            if quiet {
                gutterLog.info("drag ended via idle check")
                endDrag(at: lastLocationInWindow)
                return
            }
            scheduleIdleCheck()
            return
        }
        // Pointer motion stopped with the button still down: reflow short
        // transcripts now instead of waiting for a release that may never
        // reach this handle. A long history costs seconds to reflow, so
        // each pause would stall the drag; it waits for the release.
        if !thawedOnPause, Date().timeIntervalSince(lastDragEvent) > Self.idleThawInterval {
            gutterLog.debug("idle check: button held, thawing short transcripts")
            wrapping.thaw(upTo: WrapFreeze.pauseReflowLimit); thawedOnPause = true
        }
        scheduleIdleCheck()
    }
    // Without this sweep a missed release freezes transcript wrapping and the
    // layout loop forever. Returns true when it ended a stale drag.
    func cancelStaleDrag(now: Date = Date()) -> Bool {
        guard dragStart != nil, now.timeIntervalSince(lastDragEvent) > Self.staleDragInterval else { return false }
        // A held button is a pause, not a missed release: the idle check
        // reflows wrapping while the sweep leaves the live drag alone.
        guard !isButtonDown() else { return false }
        gutterLog.info("stale sweep ended a missed release")
        stopReleaseMonitor(); idleCheck?.cancel(); idleCheck = nil
        dragFrame?.cancel(); dragFrame = nil; pendingPosition = nil
        let staleThawing = wrapping.count
        gutterLog.debug("thawing \(staleThawing, privacy: .public) containers")
        dragStart = nil; wrapping.thaw(); dragEnded?()
        window?.invalidateCursorRects(for: self)
        return true
    }
}

// Width changes invalidate every line in TextKit 1, including offscreen
// transcript history: a few thousand messages cost seconds per width.
// Keep wrapping fixed while a gutter or the window is being dragged; clipping
// is cheap and the final width reflows once. Never replace the editor or its
// selection/Undo stack with a new view.
final class WrapFreeze {
    /// Characters a pause may reflow without stalling the gesture.
    static let pauseReflowLimit = 100_000
    private var frozen: [(container: NSTextContainer, tracks: Bool)] = []
    var count: Int { frozen.count }
    deinit { thaw() }
    func freeze(in view: NSView?) {
        guard let view else { return }
        if let text = view as? NSTextView, let container = text.textContainer, !frozen.contains(where: { $0.container === container }) {
            frozen.append((container, container.widthTracksTextView))
            container.widthTracksTextView = false
        }
        for child in view.subviews { freeze(in: child) }
    }
    /// Restores wrapping, or only for transcripts up to `limit` characters.
    func thaw(upTo limit: Int = .max) {
        let thawing = frozen.filter { ($0.container.textView?.textStorage?.length ?? 0) <= limit }
        frozen.removeAll { entry in thawing.contains { $0.container === entry.container } }
        for (container, tracks) in thawing {
            container.widthTracksTextView = tracks
            Self.matchTrackedWidth(container)
        }
    }
    // Re-enabling widthTracksTextView only follows *later* frame changes. The
    // pane already reached its new width, so without matching it here the
    // transcript stays wrapped at the old width until some unrelated resize.
    static func matchTrackedWidth(_ container: NSTextContainer) {
        guard container.widthTracksTextView, let text = container.textView else { return }
        let width = max(0, text.bounds.width - 2 * text.textContainerInset.width)
        if abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: container.containerSize.height)
        }
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
    private var draggingDivider = false
    private var pending = false
    private var revision = 0
    private var lastExpandedSidebar: CGFloat = 340
    private var restoreSidebarCap: CGFloat?
    private var countChangeSidebar: CGFloat?
    private var observers: [NSObjectProtocol] = []
    private var dividerHandles: [PaneDividerHandle] = []
    private let liveResizeWrapping = WrapFreeze()
    init(window: NSWindow) {
        self.window = window
        referenceWidth = window.contentRect(forFrameRect: window.frame).width; lastWidth = referenceWidth
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in self?.windowResized() })
        // Dragging the window edge resizes every pane each frame. Reflow once
        // at the end, as a gutter drag does.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
            self?.liveResizeWrapping.freeze(in: self?.window?.contentView)
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.liveResizeWrapping.thaw()
            if let root = self.window?.contentView { self.followTail(in: root) }
        })
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
                handle.dragBegan = { [weak self] in self?.draggingDivider = true }
                handle.dragEnded = { [weak self] in self?.finishDividerDrag() }
                let frame = root.convert(rect, from: split).intersection(root.bounds)
                if handle.frame != frame {
                    handle.frame = frame
                    window?.invalidateCursorRects(for: handle)
                }
                if handle.superview !== root { root.addSubview(handle, positioned: .above, relativeTo: nil) }
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
        // A late-mounting pane (remote transcript, heavy history) can miss the
        // short retries and stay narrow. One last attempt a second later adopts
        // it; if layout already settled this succeeds immediately as a no-op.
        let token = revision
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.revision == token else { return }
            self.schedule()
        }
    }
    private var contentSignature = ""
    // Replacing what a pane shows (session → Parking Lot, etc.) swaps the split's
    // subview at the same count. AppKit gives the newcomer a default width and the
    // divider observer would record that as the user's proportions. Re-apply the
    // saved weights instead, once now and once after late-mounting content.
    func setPaneContents(_ signature: String) {
        guard signature != contentSignature else { return }
        let first = contentSignature.isEmpty
        contentSignature = signature
        guard !first, paneCount > 0 else { return }
        schedule()
        let token = revision
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.revision == token else { return }
            self.schedule()
        }
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
    private func finishDividerDrag() {
        draggingDivider = false
        guard let window, let outer = PaneSizing.split(in: window.contentView), outer.arrangedSubviews.count == 2 else { return }
        let width = window.contentRect(forFrameRect: window.frame).width
        if !sidebarCollapsed {
            preferredSidebar = outer.arrangedSubviews[0].frame.width
            referenceWidth = width; sidebarLimit = 480
        }
        if let inner = PaneSizing.split(in: outer.arrangedSubviews[1]), inner.arrangedSubviews.count == paneCount {
            weights = inner.arrangedSubviews.map { max(1, $0.frame.width) }
        }
        schedule()
    }
    private func dividerChanged() {
        guard !applying, !draggingDivider, let window, let outer = PaneSizing.split(in: window.contentView) else { return }
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
            // A pane that mounted after the last arrangement (a long history,
            // a lot replaced by a session) arrives at an AppKit default width.
            // That is not the user's proportion; re-apply the saved weights.
            guard inner.arrangedSubviews.map(ObjectIdentifier.init) == arrangedPanes else { schedule(); return }
            weights = inner.arrangedSubviews.map { max(1, $0.frame.width) }
        }
    }
    private var arrangedPanes: [ObjectIdentifier] = []
    private func schedule() {
        revision += 1; let token = revision; pending = true
        DispatchQueue.main.async { [weak self] in self?.arrange(token, attempts: 8) }
    }
    private func cancelStaleDrags(now: Date = Date()) {
        guard let window, let contentView = window.contentView else { return }
        func sweep(_ view: NSView) {
            if let handle = view as? PaneDividerHandle { _ = handle.cancelStaleDrag(now: now) }
            for child in view.subviews { sweep(child) }
        }
        sweep(contentView)
    }
    private func arrange(_ token: Int, attempts: Int) {
        cancelStaleDrags()
        guard token == revision, !draggingDivider, let window else { return }
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
        arrangedPanes = PaneSizing.split(in: window.contentView).flatMap { $0.arrangedSubviews.count == 2 ? PaneSizing.split(in: $0.arrangedSubviews[1]) : nil }?.arrangedSubviews.map(ObjectIdentifier.init) ?? []
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
    let longText = NSTextView(frame: inner.arrangedSubviews[0].bounds)
    longText.autoresizingMask = [.width, .height]
    longText.textContainer!.widthTracksTextView = true
    longText.string = String(repeating: "Long transcript text that wraps as the pane gets narrower. More prose for realistic wrapping.\n", count: 10000)
    inner.arrangedSubviews[0].addSubview(longText)
    longText.layoutManager!.ensureLayout(for: longText.textContainer!)
    let shortText = NSTextView(frame: inner.arrangedSubviews[0].bounds)
    shortText.autoresizingMask = [.width, .height]
    shortText.string = String(repeating: "A short conversation reflows during a pause.\n", count: 40)
    inner.arrangedSubviews[0].addSubview(shortText)
    // Tracking restored is not enough: the container must actually match the
    // view's current width, or the transcript stays wrapped at the old width.
    func reflowed(_ text: NSTextView) -> Bool {
        text.textContainer!.widthTracksTextView && abs(text.textContainer!.containerSize.width - (text.bounds.width - 2 * text.textContainerInset.width)) < 0.5
    }
    for target in [outer, inner] {
        guard let handle = content.subviews.compactMap({ $0 as? PaneDividerHandle }).first(where: { $0.split === target && $0.dividerIndex == 0 }) else { check(false, "Burst-drag fixture handle exists"); continue }
        let before = target.arrangedSubviews[0].frame.maxX
        let point = NSPoint(x: handle.frame.midX, y: handle.frame.midY)
        func event(_ type: NSEvent.EventType, _ delta: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: content.convert(NSPoint(x: point.x + delta, y: point.y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: target, queue: .main) { _ in notifications += 1 }
        let wrapping = longText.textContainer!.containerSize.width
        let selection = longText.selectedRange()
        handle.mouseDown(with: event(.leftMouseDown, 0))
        check(!longText.textContainer!.widthTracksTextView, "Gutter drag suspends full-history wrapping on a 10,000-line transcript")
        for step in 1...100 { handle.mouseDragged(with: event(.leftMouseDragged, CGFloat(step) * 0.3)) }
        // Wait for the coalesced frame rather than a fixed 40 ms: a loaded test
        // machine can delay the display-interval callback. Coalescing is still
        // proven by the notification count, which more waiting cannot inflate.
        let burstDeadline = Date().addingTimeInterval(2)
        repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        while abs(target.arrangedSubviews[0].frame.maxX - before - 30) >= 2 && Date() < burstDeadline
        check(abs(target.arrangedSubviews[0].frame.maxX - before - 30) < 2 && notifications < 10,
              "\(target === outer ? "Sidebar" : "Session") gutter coalesces a 100-event burst while following the latest pointer (resize notifications: \(notifications))")
        longText.layoutManager!.ensureLayout(for: longText.textContainer!)
        check(longText.textContainer!.containerSize.width == wrapping, "TextKit wrapping width stays fixed throughout the gutter gesture")
        handle.mouseDragged(with: event(.leftMouseDragged, 37))
        handle.mouseUp(with: event(.leftMouseUp, 37))
        check(abs(target.arrangedSubviews[0].frame.maxX - before - 37) < 2, "Gutter release applies the final pointer position without waiting for a timer")
        check(longText.textContainer!.widthTracksTextView && longText.selectedRange() == selection, "Release restores native wrapping and preserves the editor selection")
        check(reflowed(longText), "Release reflows the transcript to the pane's new width (container \(longText.textContainer!.containerSize.width), view \(longText.bounds.width), frozen at \(wrapping))")
        NotificationCenter.default.removeObserver(observer)
        settle()
        check(abs(target.arrangedSubviews[0].frame.maxX - before - 37) < 2, "Final gutter layout preserves the user's released position")
        // Pause with the button held: wrapping reflows but the drag continues.
        handle.buttonDownOverride = { true }
        handle.mouseDown(with: event(.leftMouseDown, 0))
        handle.mouseDragged(with: event(.leftMouseDragged, -12))
        check(!longText.textContainer!.widthTracksTextView, "Resumed gutter motion suspends wrapping again")
        RunLoop.current.run(until: Date().addingTimeInterval(0.65))
        check(reflowed(shortText) && !longText.textContainer!.widthTracksTextView, "A paused gutter drag reflows short transcripts at once; a 10,000-line history waits for release")
        handle.mouseDragged(with: event(.leftMouseDragged, -12))
        check(!shortText.textContainer!.widthTracksTextView && !longText.textContainer!.widthTracksTextView, "Motion after a pause suspends wrapping again")
        var ended = 0
        let previousEnded = handle.dragEnded
        handle.dragEnded = { previousEnded?(); ended += 1 }
        handle.endDrag(at: content.convert(NSPoint(x: point.x - 12, y: point.y), to: nil))
        check(ended == 1 && reflowed(longText) && reflowed(shortText), "A held-button pause keeps the drag alive until release, which reflows every transcript")
        check(abs(target.arrangedSubviews[0].frame.maxX - before - 25) < 2, "A held-button release lands on the pointer position")
        handle.dragEnded = previousEnded
        // With the button up, the scheduled idle check ends a missed release
        // once events go quiet. The applied divider position proves the drag
        // ended: a thaw alone would leave the pre-drag position in place.
        handle.buttonDownOverride = { false }
        handle.mouseDown(with: event(.leftMouseDown, 0))
        handle.mouseDragged(with: event(.leftMouseDragged, 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        check(abs(target.arrangedSubviews[0].frame.maxX - before - 25) < 2 && reflowed(longText), "An idle check ends a button-up drag without waiting for the stale sweep")
        // A second release through the shared path must be a no-op.
        var repeatEnded = 0
        let previousRepeatEnded = handle.dragEnded
        handle.dragEnded = { previousRepeatEnded?(); repeatEnded += 1 }
        handle.endDrag(at: content.convert(NSPoint(x: point.x - 12, y: point.y), to: nil))
        check(repeatEnded == 0 && longText.textContainer!.widthTracksTextView, "A repeat release after the idle path ends the drag is a no-op")
        handle.dragEnded = previousRepeatEnded
        // A release through the app event stream ends the drag via the monitor.
        handle.mouseDown(with: event(.leftMouseDown, 0))
        handle.mouseDragged(with: event(.leftMouseDragged, 5))
        NSApp.sendEvent(event(.leftMouseUp, 5))
        check(abs(target.arrangedSubviews[0].frame.maxX - before - 30) < 2 && reflowed(longText), "A real mouseUp through the event stream ends the drag via the release monitor")
        handle.buttonDownOverride = nil
    }
    if let staleHandle = content.subviews.compactMap({ $0 as? PaneDividerHandle }).first(where: { $0.split === inner && $0.dividerIndex == 0 }) {
        let probe = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        content.addSubview(probe)
        func staleEvent(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: content.convert(NSPoint(x: staleHandle.frame.midX, y: staleHandle.frame.midY), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        staleHandle.buttonDownOverride = { false }
        staleHandle.mouseDown(with: staleEvent(.leftMouseDown))
        check(!probe.textContainer!.widthTracksTextView, "A gutter grab suspends transcript wrapping")
        check(!staleHandle.cancelStaleDrag(now: Date()), "An active gutter drag is not mistaken for a stale one")
        check(staleHandle.cancelStaleDrag(now: Date().addingTimeInterval(10)), "A missed gutter release is recovered as stale")
        check(reflowed(probe), "Recovering a missed release restores transcript wrapping")
        staleHandle.buttonDownOverride = nil
        probe.removeFromSuperview()
    } else { check(false, "Stale-drag fixture handle exists") }
    // Dragging the window edge freezes wrapping the same way and reflows once.
    NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
    let liveWrapping = longText.textContainer!.containerSize.width
    window.setContentSize(NSSize(width: 1300, height: 700)); settle()
    longText.layoutManager!.ensureLayout(for: longText.textContainer!)
    check(!longText.textContainer!.widthTracksTextView && longText.textContainer!.containerSize.width == liveWrapping && abs(longText.bounds.width - 2 * longText.textContainerInset.width - liveWrapping) > 1,
          "A live window resize keeps transcript wrapping fixed while the panes change width")
    NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
    check(reflowed(longText) && reflowed(shortText), "Ending a live window resize reflows transcripts to their final width")
    window.setContentSize(NSSize(width: 1400, height: 700)); settle()
    longText.removeFromSuperview(); shortText.removeFromSuperview()
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
    // A heavy pane that mounts after the layout settled (a long Steward
    // transcript replacing a lot) arrives at a default width. Neither the
    // divider observer nor the delayed retry may keep it as the proportion.
    window.setContentSize(NSSize(width: 1800, height: 700)); settle()
    layout.setPaneContents("1=a,2=b,3=lot"); layout.setPaneContents("1=a,2=b,3=steward"); settle()
    let replaced = inner.arrangedSubviews[2]; inner.removeArrangedSubview(replaced); replaced.removeFromSuperview()
    inner.addArrangedSubview(NSView()); inner.setPosition(inner.bounds.width - 40, ofDividerAt: 1); settle()
    check(sizes().min()! >= PaneSizing.minimumPane && sizes().max()! - sizes().min()! < 2, "A late-mounting pane is re-equalized instead of keeping its default width (panes: \(sizes()))")
    RunLoop.current.run(until: Date().addingTimeInterval(1.1))
    check(sizes().max()! - sizes().min()! < 2, "The delayed retry keeps the saved proportions after a late mount (panes: \(sizes()))")
    inner.setPosition(500, ofDividerAt: 0); settle()
    let dragged = sizes(); layout.setPaneCount(3); settle()
    check(zip(sizes(), dragged).allSatisfy { abs($0 - $1) < 2 }, "A divider moved within the same panes is still kept as the user's proportion")
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
    paneMountSelfTests(check)
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


private struct PaneMountFixtureView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var state: WindowState
    var body: some View {
        HSplitView {
            Color.clear.frame(minWidth: PaneSizing.minimumSidebar, idealWidth: 340, maxWidth: 480, maxHeight: .infinity)
            WorkspacePanes(workspace: workspace, state: state)
        }
    }
}

/// Real panes: an agent with a long transcript and an attention heading
/// replaces a Parking Lot in pane 3, then moves between panes.
func paneMountSelfTests(_ check: (Bool, String) -> Void) {
    MainActor.assumeIsolated {
        let workspace = Workspace(), state = WindowState(workspace: workspace), store = Store.shared
        let others = (0..<2).map { i -> Session in
            let session = store.create(Entry(name: "Pane \(i + 1)", command: "unused", directory: NSTemporaryDirectory(), engine: "claude"), persist: false)
            session.messages = largeTranscript(40); return session
        }
        let steward = store.createAgent(title: "Converse Steward", persist: false)
        steward.messages = largeTranscript(600)
        steward.agent?.attention = "Quit Converse on Mac and Windows to install build 138. Windows WAITING; the Mac update is queued until quit."
        let lot = try? ParkingLotLibrary.shared.create(name: "Pane mount fixture")
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1500, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PaneMountFixtureView(workspace: workspace, state: state))
        window.orderBack(nil)
        let layout = WindowPaneLayout(window: window)
        // As AppDelegate.updatePaneWidths, on the same willSet publication.
        let placements = workspace.$placements.sink { placements in
            let mine = placements.filter { $0.value.windowID == state.id }
            layout.setPaneCount(mine.count)
            layout.setPaneContents(mine.map { "\($0.value.pane)=\($0.key.uuidString)" }.sorted().joined(separator: ","))
        }
        defer {
            placements.cancel(); window.orderOut(nil); window.contentView = nil; window.close()
            store.sessions.removeAll { session in session === steward || others.contains { $0 === session } }
            if let lot { try? ParkingLotLibrary.shared.delete(lot.id) }
        }
        func widths() -> [CGFloat] {
            PaneSizing.split(in: window.contentView).flatMap { $0.arrangedSubviews.count == 2 ? PaneSizing.split(in: $0.arrangedSubviews[1]) : nil }?.arrangedSubviews.map { $0.frame.width } ?? []
        }
        func settle(_ seconds: TimeInterval = 1.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func sane(_ count: Int) -> Bool { widths().count == count && widths().allSatisfy { $0 >= PaneSizing.minimumPane } && widths().max()! - widths().min()! < 2 }
        workspace.assign(others[0].id, to: state.id, pane: 1); workspace.assign(others[1].id, to: state.id, pane: 2); settle(0.5)
        if let lot { workspace.assign(lot.id, to: state.id, pane: 3); settle() }
        workspace.assign(steward.id, to: state.id, pane: 3); settle()
        check(sane(3), "Pressing 3 on a long agent transcript replaces a lot at an equal pane width (panes: \(widths().map { Int($0) }))")
        workspace.assign(steward.id, to: state.id, pane: 1); settle()
        workspace.assign(steward.id, to: state.id, pane: 3); settle()
        check(sane(widths().count) && widths().count >= 2, "Moving the agent between panes keeps every pane at a readable equal width (panes: \(widths().map { Int($0) }))")
        // Panes SwiftUI has detached keep receiving updates; they must not
        // re-render the whole history alongside the visible pane.
        let detached = ScrollingConversation.Coordinator.detachedRenders
        steward.messages.append(Message(role: "assistant", text: "Both machines report build 138."))
        settle(0.3)
        check(ScrollingConversation.Coordinator.detachedRenders == detached, "New output renders only the attached transcript, not copies from earlier panes (\(ScrollingConversation.Coordinator.detachedRenders - detached) detached renders)")
    }
}
