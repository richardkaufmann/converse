import Foundation

func workspaceSelfTests(_ check: (Bool, String) -> Void) {
    let wide = PaneSizing.widths(available: 1200, weights: [2, 1, 1])
    let tight = PaneSizing.widths(available: 750, weights: [2, 1, 1])
    check(wide == [600, 300, 300] && tight == [310, 220, 220], "Window sizing preserves session proportions until readable minimums require clamping")
    let smallSidebar = PaneSizing.sidebar(preferred: 410, reference: 1400, window: 834, limit: 480, paneCount: 3)
    let restoredSidebar = PaneSizing.sidebar(preferred: 410, reference: 1400, window: 1400, limit: 480, paneCount: 3)
    check(smallSidebar == 162 && restoredSidebar == 410, "Sidebar compresses in small windows and restores the preferred width as space returns")
    check(PaneSizing.sidebar(preferred: 200, reference: 1100, window: 1100, limit: 359, paneCount: 2) == 200, "Adding panes retains an intentionally narrow sidebar instead of expanding it")
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
}
