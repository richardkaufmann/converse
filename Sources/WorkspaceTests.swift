import AppKit
import SwiftUI

func workspaceSelfTests(_ check: (Bool, String) -> Void) {
    let wide = PaneSizing.widths(available: 1200, weights: [2, 1, 1])
    let tight = PaneSizing.widths(available: 750, weights: [2, 1, 1])
    check(wide == [600, 300, 300] && tight == [310, 220, 220], "Window sizing preserves session proportions until readable minimums require clamping")
    let smallSidebar = PaneSizing.sidebar(preferred: 410, reference: 1400, window: 834, limit: 480, paneCount: 3)
    let restoredSidebar = PaneSizing.sidebar(preferred: 410, reference: 1400, window: 1400, limit: 480, paneCount: 3)
    check(smallSidebar == 162 && restoredSidebar == 410, "Sidebar compresses in small windows and restores the preferred width as space returns")
    check(PaneSizing.sidebar(preferred: 200, reference: 1100, window: 1100, limit: 359, paneCount: 2) == 200, "Adding panes retains an intentionally narrow sidebar instead of expanding it")
    do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-restore-" + UUID().uuidString)
        let original = Workspace(); _ = original.restore(folder: folder)
        let window = WindowState(workspace: original), session = UUID()
        original.rename(window.id, to: "Saved window"); original.assign(session, to: window.id, pane: 2)
        let restored = Workspace(); let windows = restored.restore(folder: folder)
        check(windows == [window.id] && restored.names[window.id] == "Saved window" && restored.session(in: window.id, pane: 2) == session, "Mac relaunch restores named windows and saved pane placements without taking sessions")
        restored.park(session)
        let parked = Workspace(); _ = parked.restore(folder: folder)
        check(parked.placements.isEmpty, "Explicit Park stays parked after Mac relaunch")
    }
    let workspace = Workspace()
    let first = WindowState(workspace: workspace), second = WindowState(workspace: workspace)
    check(first.title == "Converse" && second.title == "Converse 2", "New windows have distinct names and independent empty panes")
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    workspace.assign(a, to: first.id, pane: 1)
    workspace.assign(b, to: first.id, pane: 2)
    workspace.assign(c, to: first.id, pane: 3)
    check((1...3).compactMap { workspace.session(in: first.id, pane: $0) } == [a, b, c], "Three independent panes retain three different conversations")
    check(workspace.minimumWidth(in: first.id) >= PaneSizing.minimumSidebar + 3 * PaneSizing.minimumPane, "Three panes request enough native window width to stay visible")
    workspace.assign(d, to: first.id, pane: 1)
    check(workspace.placements[a] == nil && workspace.session(in: first.id, pane: 1) == d && workspace.placements[b]?.pane == 2, "Replacing a pane parks only its previous occupant")
    workspace.assign(b, to: second.id, pane: 3)
    check(workspace.pane(for: b, in: first.id) == nil && workspace.pane(for: b, in: second.id) == 3 && workspace.session(in: first.id, pane: 2) == nil, "Moving across windows updates both sidebars and vacates the old pane")
    workspace.assign(c, to: second.id, pane: 3)
    check(workspace.placements[b] == nil && workspace.session(in: first.id, pane: 3) == nil && workspace.placements[c]?.windowID == second.id, "Cross-window replacement parks the displaced session globally")
    workspace.assign(c, to: second.id, pane: 1)
    check(workspace.session(in: second.id, pane: 3) == nil && workspace.pane(for: c, in: second.id) == 1, "Moving between panes never duplicates a session")
    workspace.park(c)
    check(workspace.placements[c] == nil && workspace.session(in: second.id, pane: 1) == nil, "P removes a session from every right pane")
    workspace.assign(a, to: first.id, pane: 0); workspace.assign(a, to: first.id, pane: 4)
    check(workspace.placements[a] == nil, "Assignments outside panes one through three are rejected")
    workspace.rename(second.id, to: "Research")
    workspace.assign(c, to: second.id, pane: 2)
    check(workspace.placementDescription(c) == "Research · pane 2", "Named windows appear in shared placement details")
    workspace.rename(first.id, to: "Research")
    check(first.title == "Research 2" && second.title == "Research", "Window names stay distinguishable in the Window menu")
    let entry = Entry(name: "Test", command: "codex", directory: "~", engine: "codex", accountName: "Work")
    let session = Session(entry: entry); session.draft = "keep this draft"; session.busy = true
    session.accountStatus = "person@example.invalid"; session.toolStatus.model = "test-model"
    session.toolStatus.effort = "high"; session.toolStatus.access = "read-only"; session.status = "Working…"
    session.pending = [PendingPrompt(text: "held", images: [])]
    session.requests = [MuseRequest(id: "approval", kind: "approval", params: [:])]
    check(workspace.showsParkedApproval(session), "Parked approval requests flag the sidebar row")
    workspace.assign(session.id, to: second.id, pane: 3)
    check(!workspace.showsParkedApproval(session), "Approval requests already displayed in another window stay out of the sidebar alert")
    do {
        let store = Workspace()
        let window = WindowState(workspace: store)
        let chat = Session(entry: Entry(name: "Chat", command: "claude", directory: "~", engine: "claude", accountName: "Work"))
        check(!chat.agentLoopPaused && !chat.unseenResponse, "Ordinary sessions start with no paused loop and no unread marker")
        chat.messages.append(Message(role: "user", text: "hi"))
        check(!store.flagsUnseenResponse(chat, success: true, interrupted: false), "A turn ending on the user's own message earns no unread marker")
        chat.messages.append(Message(role: "assistant", text: "hello"))
        check(store.flagsUnseenResponse(chat, success: true, interrupted: false), "A parked session with a fresh answer earns an unread marker")
        check(!store.flagsUnseenResponse(chat, success: false, interrupted: false) && !store.flagsUnseenResponse(chat, success: true, interrupted: true), "Failed or interrupted turns earn no unread marker")
        store.assign(chat.id, to: window.id, pane: 1)
        check(!store.flagsUnseenResponse(chat, success: true, interrupted: false), "A session on screen earns no unread marker")
        chat.unseenResponse = true
        check(Session(chat.saved).unseenResponse, "An unseen response survives relaunch")
        let trailing = Session(entry: Entry(name: "Trailing", command: "claude", directory: NSTemporaryDirectory(), engine: "claude"))
        trailing.messages = [Message(role: "user", text: "q"), Message(role: "assistant", text: "answer"), Message(role: "activity", text: "Using Bash"), Message(role: "notice", text: "diagnostic")]
        check(Workspace.shared.flagsUnseenResponse(trailing, success: true, interrupted: false), "A reply followed by activity rows still earns the unseen marker")
        trailing.messages.append(Message(role: "user", text: "next"))
        check(!Workspace.shared.flagsUnseenResponse(trailing, success: true, interrupted: false), "A turn with no reply since the last human message earns no marker")
        check(chat.sidebarSummary(workspace: store, windowID: window.id).contains("UNSEEN RESPONSE"), "Row hover surfaces an unseen response with its take hint")
        let agentSession = Session(entry: Entry(name: "Helper", command: "", directory: "~", engine: "agent", accountName: "Work"))
        agentSession.agent = AgentConfig()
        agentSession.messages.append(Message(role: "assistant", text: "done"))
        check(agentSession.agentLoopPaused, "A disabled agent loop reads as paused")
        check(!store.flagsUnseenResponse(agentSession, success: true, interrupted: false), "Agent answers report through attention, never the unread marker")
        agentSession.agent?.enabled = true
        check(!agentSession.agentLoopPaused, "An enabled agent loop reads as running")
        check(agentSession.pausedLoopReason == nil && chat.pausedLoopReason == nil, "Running loops and ordinary sessions carry no paused reason")
        agentSession.agent?.enabled = false
        agentSession.agent?.attention = "Over budget."
        check(agentSession.pausedLoopReason == "Over budget.", "A paused row leads with live attention")
        agentSession.agent?.attention = ""
        agentSession.agent?.lastOutcome = "Paused by Stop."
        check(agentSession.pausedLoopReason == "Paused by Stop.", "A paused row falls back to the last recorded outcome")
        agentSession.agent?.lastOutcome = "Not run yet"
        check(agentSession.pausedLoopReason == "Never run — enable the loop in Agent Setup.", "A never-run loop points at Agent Setup")
    }
    session.requests = []
    let detail = session.sidebarSummary(workspace: workspace, windowID: first.id)
    check(detail.contains("person@example.invalid") && detail.contains("test-model") && detail.contains("Research · pane 3") && detail.contains("Parked in this window") && detail.contains("queued: 1"), "Row hover includes account email, model, activity, queue and exact window location")
    workspace.park(session.id)
    check(session.busy && session.draft == "keep this draft" && session.pending.count == 1, "Parking preserves active work, drafts and queued input")
    workspace.assign(session.id, to: second.id, pane: 3)
    workspace.close(second.id)
    check(workspace.placements[c] == nil && workspace.placements[session.id] == nil && workspace.placements[d]?.windowID == first.id, "Closing a window parks all its panes and leaves other windows intact")
    check(session.busy && session.draft == "keep this draft" && workspace.names[second.id] == nil, "Window close preserves conversation state and removes its window entry")
    workspace.assign(a, to: second.id, pane: 1)
    check(workspace.placements[a] == nil, "A closed window cannot acquire new assignments")
    session.toolStatus.account = session.accountStatus; session.toolStatus.accountObservedAt = Date()
    let encoded = try! JSONEncoder().encode(session.saved)
    let restored = Session(try! JSONDecoder().decode(SavedSession.self, from: encoded))
    check(restored.accountStatus == session.accountStatus && restored.toolStatus.accountObservedAt != nil && restored.draft == session.draft, "Observed account identity and draft survive relaunch")
    let auth: [String: Any] = ["providers": ["meta": ["user_email": "muse@example.invalid", "user_full_name": "Fixture"]]]
    check(MuseStatusProbe.accountEmail(auth: auth, provider: "meta") == "muse@example.invalid" && MuseStatusProbe.accountEmail(auth: auth, provider: "local") == nil, "Muse account email uses the selected provider's identity metadata")
    // Stress all destinations: each session and each slot must have one owner.
    let states = (0..<4).map { _ in WindowState(workspace: workspace) }
    let ids = (0..<12).map { _ in UUID() }
    for index in 0..<240 {
        workspace.assign(ids[index % ids.count], to: states[(index * 7) % states.count].id, pane: (index % 3) + 1)
        if index % 11 == 0 { workspace.park(ids[(index + 3) % ids.count]) }
        let values = Array(workspace.placements.values)
        let unique = Set(values.map { $0.windowID.uuidString + ":" + String($0.pane) })
        if values.count != unique.count { check(false, "All shared pane assignments remain exclusive"); return }
    }
    check(true, "All shared pane assignments remain exclusive across repeated moves")
    do {
        let panes = Workspace(), here = WindowState(workspace: panes), there = WindowState(workspace: panes)
        let mine = UUID(), other = UUID()
        panes.assign(mine, to: here.id, pane: 1); panes.assign(other, to: here.id, pane: 2)
        check(panes.paneIsAvailable(1, for: mine, in: here.id) && !panes.paneIsAvailable(2, for: mine, in: here.id) && panes.paneIsAvailable(3, for: mine, in: here.id), "Sidebar pane is available when empty here or already showing this session, not when another session would be evicted")
        check(panes.paneIsAvailable(1, for: mine, in: there.id) && !panes.paneIsAvailable(1, for: other, in: here.id) && !panes.paneIsAvailable(4, for: mine, in: here.id), "Pane availability is judged per window and only for panes 1-3")
        let hover = SidebarHoverState()
        hover.setHovered(true); let row = hover.wantsDetails
        hover.setButtonsHovered(true); let buttons = hover.wantsDetails
        hover.setButtonsHovered(false); let back = hover.wantsDetails
        hover.setHovered(false)
        check(row && !buttons && back && !hover.wantsDetails, "Sidebar row summary card is suppressed while the pointer is over the row's buttons")
        let tested = Workspace(), window = WindowState(workspace: tested)
        tested.assign(other, to: window.id, pane: 1)
        check(!tested.paneIsAvailable(1, for: mine, in: window.id) && tested.paneIsAvailable(2, for: mine, in: window.id) && tested.paneIsAvailable(3, for: mine, in: window.id), "With one pane up, panes 2 and 3 are free for another session")
        // Red P/X: decided from where else the session is displayed; 1/2/3 orange is unchanged.
        let names = panes.names
        let nobody = ShownElsewhere(window: ShownElsewhere.window(nil, here: here.id, names: names), device: ShownElsewhere.device(nil, me: "me") { _ in "iPad" })
        check(!nobody.isShown && nobody.label == nil && nobody.help("Park") == "Park" && !PaneButton.showsElsewhere(shownElsewhere: nobody.isShown, rowHovered: true), "A session displayed nowhere else keeps normal P and X")
        check(ShownElsewhere.window(PaneLocation(windowID: here.id, pane: 1), here: here.id, names: names) == nil && ShownElsewhere.device("me", me: "me") { _ in "This Mac" } == nil, "This window and this device never count as elsewhere")
        let inWindow = ShownElsewhere(window: ShownElsewhere.window(PaneLocation(windowID: there.id, pane: 2), here: here.id, names: names))
        check(inWindow.isShown && inWindow.label == "Shown in " + (names[there.id] ?? "?") && inWindow.help("Park") == inWindow.label! + "\nPark", "A session in another window here warns with that window's name")
        check(PaneButton.showsElsewhere(shownElsewhere: inWindow.isShown, rowHovered: true) && !PaneButton.showsElsewhere(shownElsewhere: inWindow.isShown, rowHovered: false), "P and X turn red only while the row is hovered")
        let device = ShownElsewhere(device: ShownElsewhere.device("win", me: "me") { $0 == "win" ? "Windows 11 (Parallels)" : nil })
        check(device.label == "Shown on Windows 11 (Parallels)", "A session on another device warns with the device name")
        check(ShownElsewhere(window: "Work", device: "Richard-Air").label == "Shown in Work · on Richard-Air", "A session in another window and on another device names both")
        let unknown = ShownElsewhere(window: ShownElsewhere.window(PaneLocation(windowID: UUID(), pane: 1), here: here.id, names: names), device: ShownElsewhere.device("ghost", me: nil) { _ in "  " })
        check(unknown.label == "Shown in another window · on another device", "Unknown window and device names fall back to another window and another device")
        var remoteRow = DeviceSidebarRow(globalID: "home/x", sessionID: UUID(), title: "R", assistant: "Claude", engine: "claude", model: "m", effort: "e", access: "a", status: "Ready", busy: false, queued: 0, queuePaused: false)
        let lookup: (String) -> String? = { ["home": "Richard-Air", "ipad": "iPad"][$0] }
        check(ShownElsewhere.remoteDevice(remoteRow, home: "home", homeName: "Richard-Air", me: "me", name: lookup) == nil, "A remote session parked everywhere keeps normal P and X")
        remoteRow.leaseHolder = "me"
        check(ShownElsewhere.remoteDevice(remoteRow, home: "home", homeName: "Richard-Air", me: "me", name: lookup) == nil, "A remote session this device holds is not elsewhere")
        remoteRow.leaseHolder = "home"
        check(ShownElsewhere.remoteDevice(remoteRow, home: "home", homeName: "Richard-Air", me: "me", name: lookup) == nil, "The home's expiring local fence alone does not mark a remote session")
        remoteRow.shownOnHome = true
        check(ShownElsewhere.remoteDevice(remoteRow, home: "home", homeName: "Richard-Air", me: "me", name: lookup) == "Richard-Air", "A remote session shown on its home names the home")
        remoteRow.shownOnHome = nil; remoteRow.leaseHolder = "ipad"
        check(ShownElsewhere.remoteDevice(remoteRow, home: "home", homeName: "Richard-Air", me: "me", name: lookup) == "iPad", "A remote session another viewer holds names that viewer")
        let decoded = try? JSONDecoder().decode(DeviceSidebarRow.self, from: Data(#"{"globalID":"h/x","sessionID":"\#(UUID().uuidString)","title":"T","assistant":"A","engine":"claude","model":"m","effort":"e","access":"a","status":"Ready","busy":false,"queued":0,"queuePaused":false}"#.utf8))
        check(decoded != nil && decoded?.shownOnHome == nil, "Rows from older homes decode without the home display flag")
        check(PaneButton.showsOpen(available: true, selected: false, stripHovered: true) && !PaneButton.showsOpen(available: true, selected: true, stripHovered: true) && !PaneButton.showsOpen(available: false, selected: false, stripHovered: true) && !PaneButton.showsOpen(available: true, selected: false, stripHovered: false), "Pane 1/2/3 orange logic is unchanged")
    }
    sidebarHoverSelfTests(check)
}

// Hosts real sidebar rows offscreen and drives their AppKit trackers with
// window-local events, as AppKit would for a pointer sweep. No global events.
func sidebarHoverSelfTests(_ check: (Bool, String) -> Void) {
    _ = NSApplication.shared
    func settle(_ seconds: TimeInterval = 0.1) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    final class Harness {
        let window: NSWindow, host: NSView
        var row: SidebarHoverView?, strip: SidebarTrackingView?
        var inside: Set<ObjectIdentifier> = []
        var tracked: [NSRect] { trackers.map { view in view.trackingAreas.map { view.convert($0.rect, to: nil) }.first ?? .zero } }
        var cards: [String] = []
        init<V: View>(_ view: V) {
            window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 320, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: view.frame(width: 320, height: 30))
            window.contentView = host; window.orderBack(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            func walk(_ view: NSView) {
                if let found = view as? SidebarHoverView { row = found } else if let found = view as? SidebarTrackingView { strip = found }
                view.subviews.forEach(walk)
            }
            walk(host)
            row?.presentDetails = { [unowned self] in self.cards.append($0) }
        }
        var trackers: [SidebarTrackingView] { [row, strip].compactMap { $0 } }
        func rect(_ view: SidebarTrackingView) -> NSRect { view.convert(view.trackedRect, to: nil) }
        // Pane button centers in window coordinates: P, 1, 2, 3, X across the 98-point strip.
        func button(_ index: Int) -> NSPoint { let frame = rect(strip!); return NSPoint(x: frame.minX + 9 + CGFloat(index) * 20, y: frame.midY) }
        var name: NSPoint { NSPoint(x: 40, y: rect(strip!).midY) }
        var outside: NSPoint { NSPoint(x: 500, y: rect(strip!).midY) }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            type == .mouseMoved
                ? NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                : NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        }
        // AppKit semantics: entered/exited on crossing a tracking area, moved while inside it.
        func move(to point: NSPoint, dropping dropped: SidebarTrackingView? = nil) {
            for view in trackers {
                let id = ObjectIdentifier(view), now = rect(view).contains(point), was = inside.contains(id)
                if now { inside.insert(id) } else { inside.remove(id) }
                if view === dropped { continue }
                if now && !was { view.mouseEntered(with: event(.mouseEntered, point)) }
                else if now { view.mouseMoved(with: event(.mouseMoved, point)) }
                else if was { view.mouseExited(with: event(.mouseExited, point)) }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        func color(_ point: NSPoint) -> NSColor? {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let local = host.convert(point, from: nil), scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let y = host.isFlipped ? local.y : host.bounds.height - local.y
            return bitmap.colorAt(x: Int(local.x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
        }
        // Sample the fill left of the label glyph. Orange and green read lighter here than their nominal fills; white is (1, 1, 1).
        func fill(_ index: Int) -> NSColor? { color(NSPoint(x: button(index).x - 6, y: button(index).y)) }
        func orange(_ index: Int) -> Bool { fill(index).map { $0.redComponent > 0.8 && $0.greenComponent > 0.45 && $0.greenComponent < 0.8 && $0.blueComponent < 0.5 } ?? false }
        func green(_ index: Int) -> Bool { fill(index).map { $0.greenComponent - $0.redComponent > 0.1 && $0.greenComponent - $0.blueComponent > 0.1 } ?? false }
        func orangePanes() -> Set<Int> { Set((1...3).filter { orange($0) }) }
        // Red P/X carry a white label, so sample the fill's corner, clear of the glyph. Offscreen, red reads
        // about (0.86, 0.47, 0.37) and orange (0.90, 0.67, 0.36): green separates them.
        func red(_ index: Int) -> Bool { color(NSPoint(x: button(index).x - 7, y: button(index).y - 7)).map { $0.redComponent > 0.75 && $0.greenComponent < 0.56 && $0.blueComponent < 0.5 } ?? false }
        func close() { row?.closeDetails(); window.orderOut(nil); window.close() }
    }
    let workspace = Workspace(), state = WindowState(workspace: workspace), other = UUID()
    let session = Session(entry: Entry(name: "Hover", command: "claude", directory: "~", engine: "claude"))
    session.accountStatus = "test"
    // Only one pane is up, and another session holds it.
    workspace.assign(other, to: state.id, pane: 1)
    let local = Harness(SidebarSession(session: session, workspace: workspace, state: state, showsModel: false))
    guard let hover = local.row?.hoverState, local.strip != nil else { check(false, "Sidebar row hosts its card anchor and pane strip tracker"); local.close(); return }
    check(local.tracked == [local.rect(local.row!), local.rect(local.strip!)] && local.rect(local.strip!).width == 98, "The pane strip tracks only its own 98 points, not the whole row")
    check(local.orangePanes().isEmpty, "No pane is orange before the strip is hovered")
    local.move(to: local.name); settle(0.6)
    check(hover.wantsDetails && local.cards.count == 1 && local.cards.last?.contains("Hover") == true, "Hovering a session's name opens its summary card")
    local.row?.closeDetails(); local.cards = []
    local.move(to: local.button(0))
    check(hover.overButtons && !hover.wantsDetails, "Hovering P suppresses the summary card")
    check(local.orangePanes() == [2, 3], "Hovering P with only pane 1 occupied shows panes 2 and 3 orange")
    local.move(to: local.button(4)); settle(0.6)
    check(local.orangePanes() == [2, 3] && local.cards.isEmpty, "Hovering X still shows the free panes and never stacks the card on the buttons")
    local.move(to: local.name)
    check(!hover.overButtons && local.orangePanes().isEmpty, "Leaving the strip clears the orange panes")
    settle(0.6)
    check(hover.wantsDetails && local.cards.count == 1, "Moving from the buttons back to the name brings the summary card back")
    local.row?.closeDetails(); local.cards = []
    local.move(to: local.button(2)); local.move(to: local.outside, dropping: local.strip)
    check(!hover.inside && !hover.overButtons, "A dropped strip exit cannot strand the buttons-hovered state")
    local.move(to: local.name); settle(0.6)
    check(hover.wantsDetails && local.cards.count == 1, "After a dropped strip exit the name hover still opens the card")
    local.row?.closeDetails(); local.cards = []
    workspace.assign(session.id, to: state.id, pane: 2); settle()
    local.move(to: local.button(1))
    check(local.green(2) && local.orangePanes() == [3], "The session's own pane stays green while the other free pane turns orange")
    workspace.assign(UUID(), to: state.id, pane: 3); workspace.assign(UUID(), to: state.id, pane: 2); settle()
    local.move(to: local.button(2))
    check(local.orangePanes().isEmpty, "Nothing turns orange when every pane holds another session")
    local.move(to: local.outside)
    check(!hover.inside && !hover.overButtons, "Leaving the row clears all hover state")
    local.close()

    // A session showing in another window: P and X red on row hover, 1/2/3 orange as before.
    let elsewhereSpace = Workspace(), elsewhereState = WindowState(workspace: elsewhereSpace), otherWindow = WindowState(workspace: elsewhereSpace)
    let shown = Session(entry: Entry(name: "Elsewhere", command: "claude", directory: "~", engine: "claude"))
    shown.accountStatus = "test"
    elsewhereSpace.assign(shown.id, to: otherWindow.id, pane: 1); elsewhereSpace.assign(other, to: elsewhereState.id, pane: 1)
    let away = Harness(SidebarSession(session: shown, workspace: elsewhereSpace, state: elsewhereState, showsModel: false))
    if let awayHover = away.row?.hoverState, away.strip != nil {
        check(!away.red(0) && !away.red(4), "P and X are not red before the row is hovered")
        away.move(to: away.name)
        check(awayHover.inside && away.red(0) && away.red(4) && away.orangePanes().isEmpty, "Hovering a row shown in another window turns P and X red, not 1/2/3")
        away.move(to: away.button(2))
        check(away.red(0) && away.red(4) && away.orangePanes() == [2, 3], "Over the strip, free panes still turn orange beside the red P and X")
        away.move(to: away.outside)
        check(!away.red(0) && !away.red(4) && away.orangePanes().isEmpty, "Leaving the row restores P and X")
        away.move(to: away.name)
        check(away.tracked.count == 2 && away.rect(away.strip!).width == 98, "Red P and X never change the strip's layout")
    } else { check(false, "Shown-elsewhere row hosts its trackers") }
    away.close()
    let soloSpace = Workspace(), homeOnly = Harness(SidebarSession(session: session, workspace: soloSpace, state: WindowState(workspace: soloSpace), showsModel: false))
    homeOnly.move(to: homeOnly.name)
    check(homeOnly.row?.hoverState?.inside == true && !homeOnly.red(0) && !homeOnly.red(4), "A row shown nowhere else keeps normal P and X on hover")
    homeOnly.close()

    let remoteRow = DeviceSidebarRow(globalID: "home/" + UUID().uuidString, sessionID: UUID(), title: "Remote Hover", assistant: "Claude", engine: "claude", model: "m", effort: "e", access: "a", status: "Ready", busy: false, queued: 0, queuePaused: false)
    let remote = Harness(RemoteSidebarRow(row: remoteRow, homeName: "Studio", online: true, showsModel: false, localPane: nil, freePanes: [2, 3], elsewhere: ShownElsewhere(device: "Studio"), park: {}, assign: { _ in }))
    guard let remoteHover = remote.row?.hoverState, remote.strip != nil else { check(false, "Remote sidebar row hosts its card anchor and pane strip tracker"); remote.close(); return }
    remote.move(to: remote.name); settle(0.6)
    check(remoteHover.wantsDetails && remote.cards.last?.contains("Remote Hover") == true, "Hovering a remote session's name opens its summary card")
    remote.row?.closeDetails(); remote.cards = []
    remote.move(to: remote.button(3)); settle(0.6)
    check(remote.orangePanes() == [2, 3] && remote.cards.isEmpty, "Hovering a remote row's strip shows its free panes orange without the card")
    remote.move(to: remote.name); settle(0.6)
    check(remote.orangePanes().isEmpty && remote.cards.count == 1, "Leaving a remote row's strip restores its name card")
    check(remote.red(0) && remote.red(4), "A hovered remote row shown on its home turns P and X red")
    remote.move(to: remote.outside)
    check(!remote.red(0) && !remote.red(4), "Leaving a remote row restores P and X")
    remote.close()
}
