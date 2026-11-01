import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class ParkingLotLibrary: ObservableObject {
    struct Record: Codable, Equatable, Identifiable { var id: UUID; var name: String }
    static let shared = ParkingLotLibrary(folder: Store.shared.folder)
    @Published private(set) var records: [Record] = []
    @Published var error = ""
    private var cache: [UUID: ParkingLotStore] = [:]
    let folder: URL
    private var catalog: URL { folder.appendingPathComponent("parking-lots.json") }
    init(folder: URL) {
        self.folder = folder
        if FileManager.default.fileExists(atPath: catalog.path) {
            do {
                let saved = try JSONDecoder().decode([Record].self, from: Data(contentsOf: catalog))
                guard Set(saved.map(\.id)).count == saved.count else { throw AgentFailure.message("Duplicate Parking Lot identities.") }
                records = saved
            } catch { self.error = "Could not read the Parking Lots list. Saved files have been left intact." }
        } else { records = [Record(id: ParkingLotStore.id, name: "Parking Lot")] }
    }
    var lots: [ParkingLotStore] { records.compactMap { lot($0.id) } }
    func lot(_ id: UUID) -> ParkingLotStore? {
        guard let record = records.first(where: { $0.id == id }) else { return nil }
        if let value = cache[id] { return value }
        let value = ParkingLotStore(folder: folder, id: id, name: record.name); cache[id] = value; return value
    }
    private func save(_ records: [Record]) throws {
        guard error.isEmpty else { throw AgentFailure.message(error) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: catalog, options: .atomic)
        self.records = records
    }
    @discardableResult func create(name: String) throws -> ParkingLotStore {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 100, records.count < 100 else { throw AgentFailure.message("Choose a name of 1–100 characters; up to 100 Parking Lots are supported.") }
        let record = Record(id: UUID(), name: title)
        let lot = ParkingLotStore(folder: folder, id: record.id, name: title)
        lot.open(); guard lot.error.isEmpty else { throw AgentFailure.message(lot.error) }
        try save(records + [record]); cache[record.id] = lot; return lot
    }
    func rename(_ id: UUID, to name: String) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 100, let index = records.firstIndex(where: { $0.id == id }) else { throw AgentFailure.message("Choose a name of 1–100 characters.") }
        var next = records; next[index].name = title; try save(next); cache[id]?.name = title
    }
    func delete(_ id: UUID) throws {
        guard let lot = lot(id), let record = records.first(where: { $0.id == id }) else { return }
        // Keep a recoverable copy, including the name, before removing the catalog entry.
        let trash = folder.appendingPathComponent("Deleted Parking Lots/" + id.uuidString + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: trash.appendingPathComponent("name.json"), options: .atomic)
        try JSONEncoder().encode(lot.document).write(to: trash.appendingPathComponent("document.json"), options: .atomic)
        try save(records.filter { $0.id != id }); cache.removeValue(forKey: id)
    }
    func promptNew() {
        promptName(title: "New Parking Lot", initial: "") { name in
            let lot = try self.create(name: name)
            if let (_, state) = AppDelegate.shared.windows.first(where: { $0.0.isKeyWindow }) ?? AppDelegate.shared.windows.last {
                Workspace.shared.assign(lot.id, to: state.id, pane: Workspace.shared.firstAvailablePane(in: state.id))
            }
        }
    }
    func promptRename(_ lot: ParkingLotStore) { promptName(title: "Rename Parking Lot", initial: lot.name) { try self.rename(lot.id, to: $0) } }
    private func promptName(title: String, initial: String, action: (String) throws -> Void) {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try action(field.stringValue) } catch { showError(error.localizedDescription) }
    }
    func promptDelete(_ lot: ParkingLotStore) {
        let alert = NSAlert(); alert.messageText = "Delete “" + lot.name + "”?"
        alert.informativeText = "This removes the lot from this device and its Group viewers. A recovery copy stays in Converse’s Deleted Parking Lots folder."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try delete(lot.id); Workspace.shared.park(lot.id) } catch { showError(error.localizedDescription) }
    }
    private func showError(_ message: String) { let alert = NSAlert(); alert.messageText = message; alert.runModal() }
}

final class SidebarOrder: ObservableObject {
    static let shared = SidebarOrder(folder: Store.shared.folder)
    struct Saved: Codable { var sections: [String: [String]] = [:] }
    @Published var reordering = false
    @Published private(set) var saved = Saved()
    @Published var dragging: (scope: String, id: String)?
    @Published var dropTarget: String?
    var frames: [String: CGRect] = [:]
    func destination(scope: String, location: CGPoint, available: [String]) -> String? {
        available.sorted { (frames[scope + "|" + $0]?.minY ?? 0) < (frames[scope + "|" + $1]?.minY ?? 0) }
            .first { (frames[scope + "|" + $0]?.midY ?? -.infinity) > location.y }
    }
    func containsDrop(scope: String, location: CGPoint) -> Bool {
        frames.filter { $0.key.hasPrefix(scope + "|") }.values.reduce(CGRect.null) { $0.union($1) }.contains(location)
    }
    private let file: URL
    init(folder: URL) {
        file = folder.appendingPathComponent("sidebar-order.json")
        if let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Saved.self, from: data) { saved = value }
    }
    func ordered(_ ids: [String], scope: String) -> [String] {
        let known = (saved.sections[scope] ?? []).filter { ids.contains($0) }
        return known + ids.filter { !known.contains($0) }
    }
    func move(_ id: String, before target: String?, scope: String, available: [String]) {
        guard available.contains(id), target != id, target == nil || available.contains(target!) else { return }
        var next = ordered(available, scope: scope).filter { $0 != id }
        next.insert(id, at: target.flatMap { next.firstIndex(of: $0) } ?? next.count)
        var state = saved; state.sections[scope] = next
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: .atomic); saved = state
        } catch { NSLog("Could not save sidebar order") }
    }
}
private struct SidebarWindowKey: EnvironmentKey { static let defaultValue = "" }
private extension EnvironmentValues {
    var sidebarWindowID: String {
        get { self[SidebarWindowKey.self] }
        set { self[SidebarWindowKey.self] = newValue }
    }
}
private struct SidebarFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
struct SidebarReorderRow<Content: View>: View {
    @Environment(\.sidebarWindowID) private var windowID
    private var frameScope: String { windowID + "|" + scope }
    @ObservedObject var order = SidebarOrder.shared
    let scope: String
    let id: String?
    let available: [String]
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 0) {
            if order.reordering, let id {
                Image(systemName: "line.3.horizontal").frame(width: 20, height: 28).contentShape(Rectangle()).help("Drag to reorder")
                    .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("sidebarOutline"))
                        .onChanged { value in
                            order.dragging = (frameScope, id)
                            order.dropTarget = order.containsDrop(scope: frameScope, location: value.location) ? frameScope + "|" + (order.destination(scope: frameScope, location: value.location, available: available) ?? "end") : nil
                        }
                        .onEnded { value in
                            if order.containsDrop(scope: frameScope, location: value.location) {
                                order.move(id, before: order.destination(scope: frameScope, location: value.location, available: available), scope: scope, available: available)
                            }
                            order.dragging = nil; order.dropTarget = nil
                        })
            }
            content()
        }.background(GeometryReader { geometry in
            Color.clear.preference(key: SidebarFrames.self, value: [frameScope + "|" + (id ?? "end"): geometry.frame(in: .named("sidebarOutline"))])
        }).overlay(alignment: .top) { if order.dropTarget == frameScope + "|" + (id ?? "end") { Color.accentColor.frame(height: 2) } }
    }
}
struct OrderedDeviceSidebar: View {
    @ObservedObject var order = SidebarOrder.shared
    @ObservedObject var library = ParkingLotLibrary.shared
    @ObservedObject var store = Store.shared
    @ObservedObject var devices = DeviceSyncService.shared
    @ObservedObject var workspace: Workspace
    @ObservedObject var state: WindowState
    var deviceIDs: [String] { ["local"] + (devices.currentGroup == nil ? [] : devices.homes.keys.sorted()) }
    var localIDs: [String] {
        let rows = store.sessions.map { ($0.id.uuidString, $0.title) } + library.records.map { ($0.id.uuidString, $0.name) }
        return rows.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }.map(\.0)
    }
    var body: some View {
        VStack(spacing: 0) {
        ForEach(order.ordered(deviceIDs, scope: "devices"), id: \.self) { device in
            VStack(spacing: 0) {
                if device == "local" {
                    SidebarReorderRow(scope: "devices", id: device, available: deviceIDs) {
                        HStack {
                            Text((devices.identity.map { devices.displayName(for: $0.deviceID) } ?? "This Mac") + " • this device").fontWeight(.bold).foregroundStyle(Color.green)
                                .contextMenu { if let id = devices.identity?.deviceID { Button("Rename device…") { renameDeviceDisplay(devices, id: id) }.disabled(!devices.canRenameDevice(id)) } }
                            Spacer()
                            Menu {
                                ForEach(store.assistantFamilies, id: \.self) { engine in Button("New " + AssistantFamily.name(engine) + " session…") { state.sessionSetup = SessionSetupRequest(engine: engine) } }
                                Button("New agent…") { AgentWindows.shared.create() }
                                Button("New Parking Lot…") { library.promptNew() }
                            } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize()
                        }.padding(.horizontal, 4).frame(height: 28)
                    }
                    ForEach(order.ordered(localIDs, scope: "local"), id: \.self) { id in
                        SidebarReorderRow(scope: "local", id: id, available: localIDs) {
                            if let uuid = UUID(uuidString: id), let lot = library.lot(uuid) { ParkingLotSidebar(lot: lot, workspace: workspace, state: state) }
                            else if let session = store.sessions.first(where: { $0.id.uuidString == id }) { SidebarSession(session: session, workspace: workspace, state: state) }
                        }
                    }
                    if order.reordering { SidebarReorderRow(scope: "local", id: nil, available: localIDs) { Text("Move to end of this device").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(5) } }
                } else {
                    DeviceSidebarSection(onlyHome: device, deviceOrder: deviceIDs, workspace: workspace, state: state)
                }
            }.padding(.bottom, 8)
        }
        if order.reordering { SidebarReorderRow(scope: "devices", id: nil, available: deviceIDs) { Text("Move device to end").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(5) } }
        }.coordinateSpace(name: "sidebarOutline").environment(\.sidebarWindowID, state.id.uuidString)
            .onPreferenceChange(SidebarFrames.self) { frames in
                order.frames = order.frames.filter { !$0.key.hasPrefix(state.id.uuidString + "|") }.merging(frames, uniquingKeysWith: { _, new in new })
            }
    }
}

struct ParkingLotTalkView: View {
    @ObservedObject var lot: ParkingLotStore
    @ObservedObject var store = Store.shared
    @Environment(\.dismiss) private var dismiss
    @State private var model = ""
    @State private var options: [DeviceChoiceDTO] = []
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Talk about “" + lot.name + "”").font(.title2.bold())
            Text("Choose the provider and model for this conversation. The assistant can read this Parking Lot and propose changes; you review changes before they are saved.")
            Picker("Model", selection: $model) {
                Text("Choose a model").tag("")
                ForEach(options) { Text($0.label).tag($0.id) }
            }
            Text("Voice transcription uses your saved Meta key. Other sessions stay outside this assistant’s scope unless you select them in Agent Setup. The microphone starts only when you press Start talking.").font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Start talking") { start() }.disabled(model.isEmpty)
            }
        }.padding(20).frame(width: 470)
        .task {
            options = AgentModels.options(store: store)
            let previous = store.sessions.first { $0.agent?.parkingLotTalkID == lot.id }?.agent?.model
            model = previous ?? options.first?.id ?? ""
            options = await AgentModels.catalog(store: store)
            if let previous, !options.contains(where: { $0.id == previous }) { options.insert(DeviceChoiceDTO(id: previous, label: AgentModels.label(previous)), at: 0) }
        }
    }
    private func start() {
        do {
            guard (try? AgentSecrets.read("meta")) != nil else { throw AgentFailure.message("Add a Meta API key in Agent Setup to enable voice transcription. You can still discuss the lot by typing to any taught session.") }
            lot.open()
            let session = try store.parkingLotTalkSession(lot: lot, model: model)
            if let (_, state) = AppDelegate.shared.windows.first(where: { $0.0.isKeyWindow }) ?? AppDelegate.shared.windows.last {
                let free = (1...3).first { Workspace.shared.session(in: state.id, pane: $0) == nil }
                let pane = free ?? (1...3).first { Workspace.shared.session(in: state.id, pane: $0) != lot.id } ?? 1
                Workspace.shared.assign(session.id, to: state.id, pane: pane)
            }
            dismiss(); AgentConversation.shared.start(session, store: store)
        } catch { self.error = error.localizedDescription }
    }
}
extension Store {
    func parkingLotTalkSession(lot: ParkingLotStore, model: String) throws -> Session {
        guard !model.isEmpty else { throw AgentFailure.message("Choose a provider and model.") }
        let existing = sessions.first { $0.agent?.parkingLotTalkID == lot.id }
        if let existing, existing.busy || !existing.pending.isEmpty || existing.queuePaused { throw AgentFailure.message("This lot’s assistant has work waiting. Open its session to finish or resume it first.") }
        let session = existing ?? createAgent(title: lot.name + " · Talk", persist: false)
        if existing == nil {
            session.agent?.objective = "Help the user think through and organize the selected Parking Lot. Discuss practicality, add useful comments, and preserve the user's wording. Use only supplied context. When sorting into projects such as Converse and KAOS, leave unclear and universal items in place. Propose concrete changes for host review before saving. Do not run an automatic loop or contact other sessions without the user's request."
            session.agent?.watchedSessions = [lot.id]; session.agent?.parkingLotTalkID = lot.id
            session.agent?.enabled = false; session.agent?.generateArt = false; session.agent?.webSearch = false
            session.messages = [Message(role: "notice", text: "Talk or type about “" + lot.name + "”. Proposed note changes require your approval. Use Agent Setup to choose any other sessions this assistant may read.")]
        }
        if session.agent?.watchedSessions.contains(lot.id) == false { session.agent?.watchedSessions.append(lot.id) }
        session.agent?.parkingLotRequiresReview = true; session.agent?.model = model
        session.toolStatus.model = AgentModels.label(model); save(); return session
    }
}

func parkingLibrarySelfTests(_ check: (Bool, String) -> Void) {
    // Undo belongs to the document, so it survives replacing the editor with Reorder.
    do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parking-undo-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lot = ParkingLotStore(folder: folder); lot.open()
        let before = lot.document.rows
        let editor = ParkingLotEditor(lot: lot, collapsed: .constant([]), reorder: {})
        var coordinator: ParkingLotEditor.Coordinator? = ParkingLotEditor.Coordinator(editor)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        coordinator?.copyEntry(before[0].id, cut: true, board: clipboard)
        check(lot.document.rows == Array(before.dropFirst(2)), "Context Cut Heading removes the entire section")
        coordinator = nil
        lot.undoManager.undo()
        check(lot.document.rows == before, "Cut Heading Undo survives destruction of the text editor and restores item identities")
        lot.undoManager.redo()
        check(lot.document.rows == Array(before.dropFirst(2)), "Redo cuts the same complete heading section")
        lot.undoManager.undo()
        lot.move(before[0].id, before: nil)
        let moved = lot.document.rows
        let responder = ParkingLotUndoResponder(); responder.lot = lot
        responder.undo(nil)
        check(lot.document.rows == before, "Reorder responder Undo restores heading and item order")
        responder.redo(nil)
        check(lot.document.rows == moved, "Reorder responder Redo restores the reordered section")
        let revision = lot.document.revision
        try lot.apply(.init(revision: revision, operations: [.init(action: "comment", id: before[1].id, text: "Assistant thought")]), author: "Assistant")
        let commented = lot.document.rows
        lot.undoManager.undo()
        check(lot.document.rows == moved && lot.document.revision > revision, "Undo reverses assistant edits and advances the revision to invalidate stale proposals")
        lot.undoManager.redo()
        check(lot.document.rows == commented, "Redo restores assistant comments with their author and identity")
        let firstLot = ParkingLotStore(folder: folder.appendingPathComponent("second")); firstLot.open()
        firstLot.update(firstLot.document.rows[1].id, text: "Separate lot")
        lot.undoManager.undo()
        check(firstLot.document.rows[1].text == "Separate lot", "Undo in one lot never edits another lot")
    } catch { check(false, "Parking Lot Undo checks: " + error.localizedDescription) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parking-library-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        let legacy = ParkingLotStore(folder: folder); legacy.open()
        legacy.update(legacy.document.rows[1].id, text: "Original idea")
        let bytes = try Data(contentsOf: folder.appendingPathComponent("parking-lot.json"))
        let library = ParkingLotLibrary(folder: folder)
        check(library.records.count == 1 && library.lot(ParkingLotStore.id)?.document == legacy.document, "Named lots preserve legacy identity, content and agent scope")
        let other = try library.create(name: "KAOS")
        check(other.id != ParkingLotStore.id && other.document.rows.count == 4, "New lots have independent identities and content")
        try library.rename(ParkingLotStore.id, to: "Converse")
        let reloaded = ParkingLotLibrary(folder: folder)
        check(reloaded.records.map(\.name) == ["Converse", "KAOS"] && reloaded.lot(other.id)?.document == other.document, "Named lot catalog and documents survive restart")
        check(try Data(contentsOf: folder.appendingPathComponent("parking-lot.json")) == bytes, "Catalog migration never rewrites existing notes")
        var config = AgentConfig(); config.watchedSessions = [other.id]
        check(config.allows(local: other.id, home: "home") && !config.allows(local: legacy.id, home: "home"), "Each named lot has separate agent access")
        try library.delete(other.id); try library.delete(legacy.id)
        check(ParkingLotLibrary(folder: folder).records.isEmpty, "Deleting every lot does not resurrect the legacy placeholder")
        let backups = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("Deleted Parking Lots"), includingPropertiesForKeys: nil)
        check(backups.count == 2 && backups.allSatisfy { FileManager.default.fileExists(atPath: $0.appendingPathComponent("document.json").path) }, "Deleting lots preserves recovery documents")
        let badFolder = folder.appendingPathComponent("bad"); try FileManager.default.createDirectory(at: badFolder, withIntermediateDirectories: true)
        let badFile = badFolder.appendingPathComponent("parking-lots.json"); try Data("broken".utf8).write(to: badFile)
        let bad = ParkingLotLibrary(folder: badFolder)
        do { _ = try bad.create(name: "Overwrite"); check(false, "Corrupt catalog blocks replacement") }
        catch { check(try String(contentsOf: badFile) == "broken", "Corrupt catalog is reported without overwriting it") }
        let heading = ParkingLotRow(heading: true, text: "Features")
        let child = ParkingLotRow(heading: false, text: "Idea", notes: [.init(author: "Reviewer", text: "Useful")])
        let following = ParkingLotRow(heading: true, text: "Bugs")
        let rows = [heading, child, following]
        check(ParkingLotStore.entryRange(heading.id, in: rows) == 0..<2, "Cut Heading includes nested items but not the next heading")
        check(ParkingLotStore.entryRange(child.id, in: rows) == 1..<2, "Cut Item includes exactly the right-clicked item")
        let orphan = ParkingLotRow(heading: false, text: "")
        var withOrphan = [orphan] + rows
        withOrphan.removeSubrange(ParkingLotStore.entryRange(orphan.id, in: withOrphan)!)
        check(withOrphan == rows, "An empty orphan item can be cut without changing the following section")
        check(ParkingLotStore.markdown(Array(rows.prefix(2))).contains("Reviewer: Useful"), "Structural copying preserves comments in readable text")
        let order = SidebarOrder(folder: folder)
        order.move("remote", before: "local", scope: "devices", available: ["local", "remote"])
        order.move("lot", before: "session", scope: "local", available: ["session", "agent", "lot"])
        order.move("foreign-session", before: "session", scope: "local", available: ["session", "agent", "lot"])
        order.frames = ["local|session": CGRect(x: 0, y: 30, width: 300, height: 30), "local|lot": CGRect(x: 0, y: 60, width: 300, height: 30), "remote|remote-session": CGRect(x: 0, y: 130, width: 300, height: 30)]
        check(order.containsDrop(scope: "local", location: CGPoint(x: 80, y: 40)) && !order.containsDrop(scope: "local", location: CGPoint(x: 80, y: 140)), "Dragging a local row cannot drop it into another device section")
        check(order.destination(scope: "local", location: CGPoint(x: 80, y: 31), available: ["session", "lot"]) == "session", "Sidebar drag target follows visible row positions")
        let savedOrder = SidebarOrder(folder: folder)
        check(savedOrder.ordered(["local", "remote"], scope: "devices") == ["remote", "local"], "Device reorder survives restart, including moving the local device")
        check(savedOrder.ordered(["session", "agent", "lot"], scope: "local") == ["lot", "session", "agent"], "Mixed session/agent/lot order survives restart and rejects foreign rows")
        check(savedOrder.ordered(["remote-session", "remote-lot"], scope: "remote") == ["remote-session", "remote-lot"], "Reordering one device leaves other device rows untouched")
        check(savedOrder.ordered(["session", "agent", "lot", "new"], scope: "local") == ["lot", "session", "agent", "new"], "New sidebar rows append after the saved order")
    } catch { check(false, "Named Parking Lots: " + error.localizedDescription) }
}

// A stable responder keeps Cmd-Z available while the text editor is replaced by the reorder view.
final class ParkingLotUndoFocus: ObservableObject {
    weak var view: ParkingLotUndoResponder?
    func activate() { if let view { view.window?.makeFirstResponder(view) } }
}
struct ParkingLotUndoAnchor: NSViewRepresentable {
    var lot: ParkingLotStore
    var focus: ParkingLotUndoFocus
    func makeNSView(context: Context) -> ParkingLotUndoResponder {
        let view = ParkingLotUndoResponder(); view.lot = lot; focus.view = view; return view
    }
    func updateNSView(_ view: ParkingLotUndoResponder, context: Context) { view.lot = lot; focus.view = view }
}
final class ParkingLotUndoResponder: NSView, NSUserInterfaceValidations {
    var lot: ParkingLotStore?
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { lot?.undoManager }
    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return undoManager?.canUndo == true }
        if item.action == #selector(redo(_:)) { return undoManager?.canRedo == true }
        return false
    }
}
