import AppKit
import SwiftUI

// Tracks the whole row without intercepting clicks, context menus or divider drags.
// SwiftUI's inherited help text is unreliable over rows of independent buttons.
final class SidebarHoverState: ObservableObject {
    weak var anchor: SidebarHoverView?
    var inside = false
    func setHovered(_ inside: Bool) {
        self.inside = inside
        anchor?.setHovered(inside)
    }
}
struct SidebarHoverDetails: NSViewRepresentable {
    let text: String
    let state: SidebarHoverState
    func makeNSView(context: Context) -> SidebarHoverView {
        let view = SidebarHoverView(); state.anchor = view; view.hoverState = state
        return view
    }
    func updateNSView(_ view: SidebarHoverView, context: Context) { view.details = text }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarHoverView, context: Context) -> CGSize? { CGSize(width: proposal.width ?? 1, height: proposal.height ?? 1) }
    static func dismantleNSView(_ view: SidebarHoverView, coordinator: ()) { view.closeDetails() }
}
final class SidebarHoverView: NSView {
    var details = "" { didSet { if details != oldValue { updateDetails() } } }
    weak var hoverState: SidebarHoverState?
    private var opening: DispatchWorkItem?
    private var watchdog: Timer?
    private var popover: NSPopover?
    private var textView: NSTextView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func setHovered(_ inside: Bool) {
        opening?.cancel()
        guard inside else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoverState?.inside == true, self.window?.isVisible == true else { return }
            self.showDetails()
        }
        opening = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
    private var pointerInRow: Bool {
        guard let window else { return false }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return visibleRect.contains(point)
    }
    func showDetails() {
        guard popover == nil, window != nil else { return }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 500))
        text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.drawsBackground = false
        text.font = .systemFont(ofSize: 12); text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("Conversation details")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 450, height: 500))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = text
        let controller = NSViewController(); controller.view = scroll
        let panel = NSPopover(); panel.behavior = .transient; panel.animates = false
        panel.contentViewController = controller; panel.contentSize = scroll.frame.size
        popover = panel; textView = text; updateDetails()
        panel.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let inPanel = self.popover?.contentViewController?.view.window?.frame.contains(NSEvent.mouseLocation) == true
            if self.window?.isVisible != true || self.popover?.isShown != true || (self.hoverState?.inside != true && !self.pointerInRow && !inPanel) { self.closeDetails() }
        }
    }
    static func attributedDetails(_ details: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: details, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        if details.hasPrefix("ATTENTION REQUIRED\n"), let end = details.range(of: "\n\n") {
            let range = NSRange(details.startIndex..<end.lowerBound, in: details)
            text.addAttributes([.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.black, .backgroundColor: NSColor.systemYellow], range: range)
        }
        return text
    }
    private func updateDetails() {
        guard let text = textView else { return }
        text.textStorage?.setAttributedString(Self.attributedDetails(details))
        if let container = text.textContainer, let layout = text.layoutManager {
            layout.ensureLayout(for: container)
            let height = max(100, layout.usedRect(for: container).height + 20)
            text.setFrameSize(NSSize(width: 450, height: height))
            popover?.contentSize = NSSize(width: 450, height: min(520, height))
        }
    }
    func closeDetails() {
        opening?.cancel(); opening = nil
        watchdog?.invalidate(); watchdog = nil
        popover?.close(); popover = nil; textView = nil
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { closeDetails() }
        super.viewWillMove(toWindow: newWindow)
    }
    deinit { opening?.cancel(); watchdog?.invalidate() }
}
