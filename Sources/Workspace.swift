import AppKit
import SwiftUI

struct PaneLocation: Equatable, Codable {
    let windowID: UUID
    let pane: Int
}
// One authority for all windows. Assigning replaces the destination and removes
// the source in one publication, so a conversation never has two owners.
final class Workspace: ObservableObject {
    static let shared = Workspace()
    @Published private(set) var placements: [UUID: PaneLocation] = [:] { didSet { persist() } }
    @Published private(set) var names: [UUID: String] = [:] { didSet { persist() } }
    private var file: URL?
    private struct Saved: Codable { var names: [UUID: String]; var placements: [UUID: PaneLocation] }
    func restore(folder: URL) -> [UUID] {
        let url = folder.appendingPathComponent("window-placements.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            names = Dictionary(uniqueKeysWithValues: saved.names.sorted { $0.key.uuidString < $1.key.uuidString }.prefix(16).map { ($0.key, $0.value) })
            var seen: Set<String> = []
            placements = saved.placements.filter { id, location in
                guard names[location.windowID] != nil, (1...3).contains(location.pane) else { return false }
                return seen.insert(location.windowID.uuidString + ":" + String(location.pane)).inserted
            }
        }
        file = url
        return names.keys.sorted { $0.uuidString < $1.uuidString }
    }
    private func persist() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Saved(names: names, placements: placements)).write(to: file, options: .atomic)
        } catch { NSLog("Converse could not save window placements.") }
    }
    func register(_ windowID: UUID, name: String = "Converse") {
        guard names[windowID] == nil else { return }
        names[windowID] = uniqueName(name, excluding: windowID)
    }
    func uniqueName(_ proposed: String, excluding windowID: UUID) -> String {
        let base = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = base.isEmpty ? "Converse" : base
        let others = Set(names.filter { $0.key != windowID }.map(\.value))
        var name = title, number = 2
        while others.contains(name) { name = title + " \(number)"; number += 1 }
        return name
    }
    func rename(_ windowID: UUID, to name: String) {
        guard names[windowID] != nil else { return }
        names[windowID] = uniqueName(name, excluding: windowID)
    }
    func session(in windowID: UUID, pane: Int) -> UUID? {
        placements.first { $0.value == PaneLocation(windowID: windowID, pane: pane) }?.key
    }
    func pane(for sessionID: UUID, in windowID: UUID) -> Int? {
        guard let location = placements[sessionID], location.windowID == windowID else { return nil }
        return location.pane
    }
    func assign(_ sessionID: UUID, to windowID: UUID, pane: Int) {
        guard names[windowID] != nil, (1...3).contains(pane) else { return }
        let destination = PaneLocation(windowID: windowID, pane: pane)
        var next = placements.filter { $0.key != sessionID && $0.value != destination }
        next[sessionID] = destination; placements = next
    }
    func showsParkedApproval(_ session: Session) -> Bool { session.needsApproval && placements[session.id] == nil }
    func park(_ sessionID: UUID) { placements.removeValue(forKey: sessionID) }
    func close(_ windowID: UUID) {
        placements = placements.filter { $0.value.windowID != windowID }
        names.removeValue(forKey: windowID)
    }
    func firstAvailablePane(in windowID: UUID) -> Int { (1...3).first { session(in: windowID, pane: $0) == nil } ?? 1 }
    func minimumWidth(in windowID: UUID) -> CGFloat {
        let count = placements.values.filter { $0.windowID == windowID }.count
        return Self.minimumWidth(paneCount: count)
    }
    static func minimumWidth(paneCount: Int, sidebarCollapsed: Bool = false) -> CGFloat { max(760, (sidebarCollapsed ? PaneSizing.collapsedSidebar : PaneSizing.minimumSidebar) + max(310, CGFloat(paneCount) * PaneSizing.minimumPane) + 12) }
    func placementDescription(_ sessionID: UUID) -> String {
        guard let location = placements[sessionID] else { return "Parked · not displayed in any window" }
        return "\(names[location.windowID] ?? "Converse") · pane \(location.pane)"
    }
}
final class WindowState: ObservableObject {
    let id: UUID
    let workspace: Workspace
    @Published var settings = false
    @Published var deviceConnect = false
    @Published var setup = false
    @Published var sidebarCollapsed = false
    @Published var sessionSetup: SessionSetupRequest? = nil
    @Published var closingSessionID: UUID? = nil
    init(workspace: Workspace = .shared, id: UUID = UUID()) { self.id = id; self.workspace = workspace; workspace.register(id) }
    var title: String { workspace.names[id] ?? "Converse" }
}

struct SessionActivity: View {
    @ObservedObject var session: Session
    var showApproval = false
    var body: some View {
        if let agent = session.agent {
            HStack(spacing: 3) {
                if !agent.attention.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black).padding(3).background(.yellow, in: RoundedRectangle(cornerRadius: 3))
                        .accessibilityLabel("Agent attention required").help(agent.attention)
                }
                if session.busy {
                    ConversationActivity(busy: true, status: "Agent thinking", waiting: false)
                } else {
                    Image(systemName: agent.canSchedule && !session.queuePaused ? "arrow.triangle.2.circlepath" : "pause.circle")
                        .font(.system(size: 11)).foregroundStyle(agent.canSchedule && !session.queuePaused ? Color.green : Color.secondary)
                        .frame(width: 12, height: 12)
                        .help(agent.loopStatus(at: Date(), busy: false, queuePaused: session.queuePaused, pendingCount: session.pending.count))
                }
            }.fixedSize()
        } else {
            ConversationActivity(busy: session.busy, status: session.status,
                                 waiting: !session.requests.isEmpty || session.status.hasPrefix("Waiting"), showApproval: showApproval)
        }
    }
}
// Both home and remote rows render the same animation and waiting state.
struct ConversationActivity: View {
    var busy: Bool
    var status: String
    var waiting = false
    var showApproval = false
    var body: some View {
        Group {
            if showApproval {
                Circle().fill(.yellow).overlay(Text("!").font(.system(size: 10, weight: .heavy)).foregroundStyle(.black))
            } else if busy && !waiting {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                    Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                        .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) * 240))
                }
            } else { Color.clear }
        }.frame(width: 12, height: 12).accessibilityLabel(showApproval ? "Permission required" : (busy ? status : "Idle"))
    }
}
struct PaneButton: View {
    let label: String
    let selected: Bool
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(selected ? Color.white : Color.black)
                .frame(width: 18, height: 19)
                .background(selected ? (destructive ? Color(red: 0.55, green: 0.06, blue: 0.08) : Color(red: 0.12, green: 0.52, blue: 0.28)) : .white)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(selected ? 0 : 0.18), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }.buttonStyle(.plain)
    }
}
extension Session {
    func sidebarSummary(workspace: Workspace, windowID: UUID) -> String {
        let identity = accountStatus.isEmpty ? "Not reported by CLI" : accountStatus
        var lines = [title, "Assistant: \(entry.name) (\(entry.engine))", "Account: \(identity)",
                     "Account profile: \(entry.accountName ?? "CLI default")", "Model: \(toolStatus.model)",
                     "Effort: \(toolStatus.effort)", "Access: \(toolStatus.access)", "State: \(status)",
                     "Location: \(workspace.placementDescription(id))"]
        if let location = workspace.placements[id], location.windowID != windowID { lines.append("Parked in this window · use 1, 2 or 3 to move here") }
        lines += ["Last turn: \(toolStatus.usage)", "Session total: \(toolStatus.totalUsage ?? "Not reported")",
                  "Quota: \(toolStatus.quota ?? "Not reported")", "Directory: \(entry.directory)",
                  "Session messaging: \(switchboardEnabled ? "enabled" : "disabled")",
                  "Messages: \(messages.count) · queued: \(pending.count)\(queuePaused ? " (paused)" : "")",
                  "Draft: \(draft.count) characters · attached images: \(attachments.count)",
                  "Conversation ID: \(id.uuidString)", "CLI session ID: \(remoteID ?? "Not started")"]
        if let approval = toolStatus.approval { lines.append("Approvals: " + approval) }
        if let directory = entry.accountDirectory, !directory.isEmpty { lines.append("Account directory: \(directory)") }
        if let observed = toolStatus.accountObservedAt { lines.append("Account observed: " + DateFormatter.localizedString(from: observed, dateStyle: .short, timeStyle: .medium)) }
        if !probeError.isEmpty { lines.append("Status refresh: \(probeError)") }
        if let agent {
            let loop = agent.loopStatus(at: Date(), busy: busy, queuePaused: queuePaused, pendingCount: pending.count)
            lines.insert(loop, at: 1)
            if let at = agent.lastRunAt { lines.insert("Last agent check: " + at.formatted(date: .abbreviated, time: .shortened), at: 2) }
            if !agent.attention.isEmpty { lines.insert("ATTENTION REQUIRED\n" + agent.attention + "\n", at: 0) }
        }
        return lines.joined(separator: "\n")
    }
}
struct SidebarSession: View {
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace
    @ObservedObject var state: WindowState
    var showsModel = true
    @StateObject private var hover = SidebarHoverState()
    var confirmingClose: Bool { state.closingSessionID == session.id }
    var closeBinding: Binding<Bool> {
        Binding(get: { confirmingClose }, set: { if $0 { state.closingSessionID = session.id } else if confirmingClose { state.closingSessionID = nil } })
    }
    var localPane: Int? { workspace.pane(for: session.id, in: state.id) }
    var body: some View {
        HStack(spacing: 6) {
            SessionActivity(session: session, showApproval: workspace.showsParkedApproval(session))
            Button { AppDelegate.shared.select(session, state: state) } label: {
                Text(session.title).lineLimit(1).truncationMode(.tail).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).layoutPriority(-1)
            if showsModel {
                Text(session.toolStatus.model).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(width: 105, alignment: .leading)
            }
            HStack(spacing: 2) {
                PaneButton(label: "P", selected: localPane == nil) { workspace.park(session.id) }.accessibilityLabel("Park \(session.title)").help("Park this session: hide its pane while its work continues.")
                ForEach(1...3, id: \.self) { pane in
                    PaneButton(label: String(pane), selected: localPane == pane) { AppDelegate.shared.assign(session, to: state, pane: pane) }
                        .accessibilityLabel("Move \(session.title) to pane \(pane) in \(state.title)").help("Move this session to pane \(pane) here, taking it back from any other display.")
                }
                PaneButton(label: "X", selected: confirmingClose, destructive: true) { state.closingSessionID = session.id }.accessibilityLabel("Close \(session.title)").help("Close this session and stop its work. Asks for confirmation; closed sessions can be restored.")
            }.frame(width: 98).fixedSize(horizontal: true, vertical: false)
        }.padding(.horizontal, 4).padding(.vertical, 3)
            .background(workspace.showsParkedApproval(session) ? Color.yellow : (localPane == nil ? Color.clear : Color.accentColor.opacity(0.05)))
            .foregroundStyle(workspace.showsParkedApproval(session) ? Color.black : Color.primary)
            .contentShape(Rectangle())
            .background(SidebarHoverDetails(text: session.sidebarSummary(workspace: workspace, windowID: state.id), state: hover).frame(maxWidth: .infinity, maxHeight: .infinity))
            .onAppear { if session.accountStatus.isEmpty { Store.shared.refreshSidebarStatus(session) } }
            .onHover { inside in hover.setHovered(inside); if inside { Store.shared.refreshSidebarStatus(session) } }
            .contextMenu {
                Button("Rename…") { AppDelegate.shared.renameSession(session) }
                if session.agent != nil {
                    Button("Agent Setup…") { AgentWindows.shared.setup(session) }
                    Button("Show scoreboard") { AgentWindows.shared.widget(session) }
                    Button("Run once") { Store.shared.queueAgentRun(session) }
                    Button("Clear attention") { session.agent?.attention = ""; session.status = session.busy ? "Working…" : "Ready"; Store.shared.save() }
                } else { Button("Configure…") { AppDelegate.shared.configureSession(session) }.disabled(session.busy) }
                ForEach(1...3, id: \.self) { pane in Button("Move to pane \(pane) here") { AppDelegate.shared.assign(session, to: state, pane: pane) } }
                if let location = workspace.placements[session.id], location.windowID != state.id {
                    Button("Show in " + (workspace.names[location.windowID] ?? "other window")) { AppDelegate.shared.frontWindow(location.windowID) }
                }
                Button("Teach Session To Talk To Other Sessions") { Store.shared.teachSwitchboard(session) }
                if session.switchboardEnabled { Button("Disable session messaging") { session.switchboardEnabled = false; Store.shared.save() } }
                Button("Park conversation") { workspace.park(session.id) }
                Divider()
                Button("Close conversation…", role: .destructive) { state.closingSessionID = session.id }
            }
            .alert("Close ‘\(session.title)’?", isPresented: closeBinding) {
                Button("Cancel", role: .cancel) {}
                Button("Close conversation", role: .destructive) { Store.shared.deleteSession(session) }
            } message: {
                Text("This removes the conversation from every window and stops any active work. A recovery snapshot keeps its transcript and draft. Use File → Restore Closed Conversation to recover it.")
            }
    }
}
struct WindowTitle: View {
    @ObservedObject var workspace: Workspace
    let state: WindowState
    var body: some View {
        Text(state.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .help(state.title + "\nRight-click to rename this window")
            .contextMenu { Button("Rename window…") { AppDelegate.shared.renameWindow(state.id) } }
    }
}
struct WorkspacePanes: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var store = Store.shared
    @ObservedObject var devices = DeviceSyncService.shared
    @ObservedObject var state: WindowState
    var occupied: [Int] { (1...3).filter { workspace.session(in: state.id, pane: $0) != nil } }
    var body: some View {
        Group {
            if occupied.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.split.3x1").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("Choose 1, 2 or 3 beside a conversation").foregroundStyle(.secondary)
                    Text("A conversation moves here from any other window. P parks it.").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
            } else {
                HSplitView {
                    ForEach(occupied, id: \.self) { pane in
                        if let id = workspace.session(in: state.id, pane: pane), let session = store.sessions.first(where: { $0.id == id }) {
                            SessionPane(session: session, workspace: workspace, pane: pane, leadingInset: state.sidebarCollapsed && pane == occupied.first ? 28 : 0)
                        } else if let id = workspace.session(in: state.id, pane: pane), let globalID = devices.globalID(forPlacement: id) {
                            RemotePane(globalID: globalID, pane: pane, workspace: workspace, leadingInset: state.sidebarCollapsed && pane == occupied.first ? 28 : 0)
                        }
                    }
                }
            }
        }.frame(minWidth: 310, maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Store {
    func refreshSidebarStatus(_ session: Session) {
        guard !session.busy, !session.probingStatus else { return }
        let now = Date()
        if let observed = session.toolStatus.accountObservedAt, now.timeIntervalSince(observed) < 60 { return }
        if let attempted = session.sidebarProbeAttemptAt, now.timeIntervalSince(attempted) < 60 { return }
        session.sidebarProbeAttemptAt = now
        refreshStatus(session)
    }
}

struct SessionPane: View {
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace
    let pane: Int
    var leadingInset: CGFloat = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(pane)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.white).frame(width: 19, height: 19).background(Color(red: 0.12, green: 0.52, blue: 0.28)).clipShape(RoundedRectangle(cornerRadius: 3))
                ProviderLogo(engine: session.entry.engine)
                Text(session.title).font(.system(size: 15, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                PaneButton(label: "P", selected: false) { workspace.park(session.id) }.accessibilityLabel("Park " + session.title).help("Park this conversation")
            }.padding(.leading, leadingInset).padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            Conversation(session: session).id(session.id)
        }.frame(minWidth: PaneSizing.minimumPane, maxWidth: .infinity, maxHeight: .infinity)
    }
}
