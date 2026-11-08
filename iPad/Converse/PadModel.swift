import Combine
import SwiftUI
import UIKit

struct PadDraft: Codable {
    var text = ""
    var hashes: [String] = []
    var dirty = false
    var baseVersion: UInt64 = 0
    var sentID: UUID?
    var sentText = ""
    var sentHashes: [String] = []
}
struct PadState: Codable {
    var placements: [String?] = [nil, nil, nil]
    var sidebarWidth: Double = 300
    var sidebarHidden = false
    var drafts: [String: PadDraft] = [:]
    var defaultDeviceName: String? = nil
    var paneTextSizes: [Double]? = nil
}

final class PadModel: ObservableObject {
    let service: DeviceSyncService
    let phoneKeyboard = PhoneKeyboardController()
    @Published var state = PadState()
    @Published var conflicts: Set<String> = []
    @Published var error = ""
    @Published var connectShown = false
    @Published var helpShown = false
    @Published var aboutShown = false
    @Published var newAgentHome: String?
    @Published var lineNumbers = true
    @Published var focusedPane = 0
    @Published var cursorPane: Int?
    private var pinchSizes: [Double]?
    private var pinchPane: Int?
    func textSize(_ pane: Int) -> CGFloat {
        let sizes = state.paneTextSizes ?? [16, 16, 16]
        return CGFloat(sizes.indices.contains(pane) ? min(32, max(12, sizes[pane])) : 16)
    }
    func pinchText(_ magnification: CGFloat) {
        guard magnification.isFinite, magnification > 0 else { return }
        if pinchSizes == nil {
            pinchSizes = (0..<3).map { Double(textSize($0)) }
            pinchPane = cursorPane
        }
        guard let baseline = pinchSizes else { return }
        var sizes = (0..<3).map { Double(textSize($0)) }
        for pane in sizes.indices where pinchPane == nil || pinchPane == pane {
            sizes[pane] = min(32, max(12, (baseline[pane] * Double(magnification)).rounded()))
        }
        if sizes != state.paneTextSizes { state.paneTextSizes = sizes }
    }
    func endTextPinch() {
        guard pinchSizes != nil else { return }
        pinchSizes = nil; pinchPane = nil; persist()
    }
    func endedEditing(pane: Int) { if cursorPane == pane { cursorPane = nil } }
    // Parking Lot viewer state is local and in memory: what is shown, the
    // newest copy from home, and collapsed headings.
    @Published var lotViews: [String: LotViewerState] = [:]
    @Published var lotCollapsed: [String: Set<UUID>] = [:]
    var lotSubscriptionsSuspended = false
    private var edits: [String: DispatchWorkItem] = [:]
    private var hydratedEpochs: [String: UInt64] = [:]
    private var observer: AnyCancellable?
    private var uploadObserver: AnyCancellable?
    var file: URL { service.storageFolder.appendingPathComponent("ipad-scene.json") }
    init(service: DeviceSyncService = .shared) {
        self.service = service
        if !service.isTestEnvironment {
            PerformanceCapture.shared.configure(folder: service.storageFolder,
                enabled: UserDefaults.standard.bool(forKey: "performanceCapture") || ProcessInfo.processInfo.environment["CONVERSE_PERFORMANCE_DIAGNOSTICS"] == "1")
        }
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(PadState.self, from: data), saved.placements.count == 3 { state = saved }
        if state.defaultDeviceName == nil {
            state.defaultDeviceName = Self.mobileDeviceName(phone: UIDevice.current.userInterfaceIdiom == .phone, identifier: service.identity?.deviceID ?? UUID().uuidString)
            persist()
        }
        service.deviceNameOverride = UserDefaults.standard.string(forKey: "deviceName") ?? (Bundle.main.object(forInfoDictionaryKey: "ConverseDemo") as? Bool == true ? "Converse Demo · " + (state.defaultDeviceName ?? "Mobile") : state.defaultDeviceName)
        service.isPlaced = { [weak self] id in self?.state.placements.contains(id) == true }
        service.onRemotePark = { [weak self] id in self?.removePlacement(id) }
        observer = service.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.reconcile(); self?.objectWillChange.send() }
        }
        uploadObserver = service.$blobReady.dropFirst().sink { [weak self] ready in
            DispatchQueue.main.async {
                guard let self else { return }
                // A debounce may have fired before upload finished. Send the
                // latest local text once all images have durable home storage.
                for (id, draft) in self.state.drafts where draft.dirty && !draft.hashes.isEmpty && draft.hashes.allSatisfy({ ready[$0] == true }) { self.flush(id) }
            }
        }

    }
    static func mobileDeviceName(phone: Bool, identifier: String) -> String {
        "Converse " + (phone ? "iPhone" : "iPad") + " · " + identifier.prefix(6).uppercased()
    }
    func persist() {
        do {
            try FileManager.default.createDirectory(at: service.storageFolder, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
        } catch { self.error = "Could not preserve your draft: " + error.localizedDescription }
    }
    func assign(_ id: String, pane: Int) {
        guard (0..<3).contains(pane) else { return }
        if let old = state.placements[pane], old != id { flush(old); service.releaseRemote(globalID: old) }
        removePlacement(id)
        state.placements[pane] = id; focusedPane = pane; persist()
        service.acquireRemote(globalID: id)
    }
    func constrainPhonePlacements() {
        let extra = state.placements.compactMap { $0 }.dropFirst(2)
        for id in extra { park(id) }
    }
    func togglePhoneSession(_ id: String) {
        if state.placements.contains(id) { park(id); return }
        guard state.placements.compactMap({ $0 }).count < 2,
              let pane = state.placements.firstIndex(where: { $0 == nil }) else { return }
        assign(id, pane: pane)
    }
    func removePlacement(_ id: String) {
        for index in state.placements.indices where state.placements[index] == id {
            state.placements[index] = nil; endedEditing(pane: index)
        }
        persist()
    }
    func park(_ id: String) { flush(id); service.releaseRemote(globalID: id); removePlacement(id); lotViews.removeValue(forKey: id) }
    func draft(_ id: String) -> PadDraft { state.drafts[id] ?? PadDraft() }
    func edit(_ id: String, text: String) {
        service.noteHumanInput()
        var draft = draft(id); draft.text = text; draft.dirty = true; state.drafts[id] = draft
        persist() // Always durable locally, including unacknowledged/offline text.
        edits[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush(id) }
        edits[id] = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    func flush(_ id: String) {
        edits.removeValue(forKey: id)?.cancel()
        guard let draft = state.drafts[id], draft.dirty, !conflicts.contains(id), service.remoteLeases[id] != nil,
              draft.hashes.allSatisfy({ service.blobReady[$0] == true }) else { return }
        service.sendRemoteDraft(globalID: id, text: draft.text, imageHashes: draft.hashes)
    }
    func reconcile() {
        var changed = false
        for (id, snapshot) in service.remoteTranscripts where service.remoteLeases[id] != nil {
            var draft = draft(id)
            let epoch = service.remoteLeases[id]!
            if hydratedEpochs[id] != epoch {
                hydratedEpochs[id] = epoch
                if draft.dirty && (draft.text != snapshot.draft || draft.hashes != (snapshot.draftImageHashes ?? [])) {
                    conflicts.insert(id)
                } else {
                    draft.text = snapshot.draft; draft.hashes = snapshot.draftImageHashes ?? []; draft.dirty = false
                }
                draft.baseVersion = snapshot.draftVersion
                for hash in draft.hashes { service.queryBlob(globalID: id, hash: hash) }
                changed = true
            } else if snapshot.draftVersion >= draft.baseVersion {
                if !draft.dirty && draft.sentID == nil {
                    if draft.text != snapshot.draft || draft.hashes != (snapshot.draftImageHashes ?? []) {
                        draft.text = snapshot.draft; draft.hashes = snapshot.draftImageHashes ?? []; changed = true
                    }
                } else if draft.text == snapshot.draft && draft.hashes == (snapshot.draftImageHashes ?? []) { draft.dirty = false; changed = true }
                draft.baseVersion = snapshot.draftVersion
            }
            if draft.sentID == nil, let record = pending(id) {
                draft.sentID = record.commandID; draft.sentText = record.payload.text ?? ""; draft.sentHashes = record.payload.blobHashes; changed = true
            }
            if let sent = draft.sentID, service.completedCommands.contains(sent) {
                if draft.text == draft.sentText { draft.text = "" }
                if draft.hashes == draft.sentHashes { draft.hashes = [] }
                draft.sentID = nil; draft.dirty = true
                state.drafts[id] = draft; changed = true
                flush(id)
            }
            state.drafts[id] = draft
            for hash in snapshot.messages.flatMap(\.imageHashes) + draft.hashes + [snapshot.agentWidget?.artHash].compactMap({ $0 }) where service.blobCache[hash] == nil { service.fetchBlob(globalID: id, hash: hash) }
        }
        if service.pairingPrompt != nil { connectShown = true }
        if changed { persist() }
        reconcileLots()
    }
    func resolveDraft(_ id: String, keepLocal: Bool) {
        if !keepLocal, let snapshot = service.remoteTranscripts[id] {
            var draft = draft(id); draft.text = snapshot.draft; draft.hashes = snapshot.draftImageHashes ?? []; draft.dirty = false; state.drafts[id] = draft
        }
        conflicts.remove(id); persist(); if keepLocal { flush(id) }
    }
    func pending(_ id: String) -> DeviceOutboxRecord? { service.unresolved(globalID: id).first { $0.payload.action == "submit" } }
    func isParkingLot(_ id: String) -> Bool { (service.remoteTranscripts[id]?.engine ?? service.remoteRow(globalID: id)?.engine) == "parking" }
    func canControl(_ id: String) -> Bool { !isParkingLot(id) && service.remoteLeases[id] != nil && !service.remoteOffline.contains(id) }
    func canSend(_ id: String) -> Bool {
        let draft = draft(id)
        return canControl(id) && !conflicts.contains(id) && pending(id) == nil && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.hashes.isEmpty) && draft.hashes.allSatisfy { service.blobReady[$0] == true }
    }
    func send(_ id: String) {
        guard canSend(id) else { return }
        flush(id)
        var draft = draft(id)
        if let command = service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "submit", text: draft.text, blobHashes: draft.hashes)) {
            draft.sentID = command; draft.sentText = draft.text; draft.sentHashes = draft.hashes; state.drafts[id] = draft; persist()
        }
    }
    func discard(_ record: DeviceOutboxRecord, restore: Bool) {
        var draft = draft(record.sessionID)
        if restore && DeviceDraftRecovery.canRestore(text: draft.text, hashes: draft.hashes, record: record) {
            draft.text = record.payload.text ?? ""; draft.hashes = record.payload.blobHashes; draft.dirty = true
        }
        if draft.sentID == record.commandID {
            draft.sentID = nil; draft.sentText = ""; draft.sentHashes = []
        }
        state.drafts[record.sessionID] = draft
        service.discardOutbox(record); persist()
        if restore { flush(record.sessionID) }
    }
    @discardableResult func attach(_ id: String, data: Data) -> String? {
        guard canControl(id) else { error = "This session is no longer connected or controlled here. Take it into a pane, then paste the image again."; return nil }
        do {
            let png = try PadImage.normalize(data)
            guard let hash = service.sendRemoteBlob(globalID: id, data: png) else { throw CocoaError(.fileWriteUnknown) }
            let folder = service.storageFolder.appendingPathComponent("RemoteCache")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(hash + ".png"); try png.write(to: file, options: .atomic)
            service.blobCache[hash] = file
            var draft = draft(id); if !draft.hashes.contains(hash) { draft.hashes.append(hash) }; draft.dirty = true; state.drafts[id] = draft; persist()
            service.saveDraftAttachments(globalID: id, hashes: draft.hashes)
            return hash
        } catch { self.error = "Could not attach image: " + error.localizedDescription; return nil }
    }
    func canApplyImageResult(_ id: String, hash: String, epoch: UInt64?) -> Bool {
        canControl(id) && epoch != nil && service.remoteLeases[id] == epoch && draft(id).hashes.contains(hash) && draft(id).sentID == nil && !conflicts.contains(id)
    }
    @discardableResult func addImageNotes(_ id: String, hash: String, epoch: UInt64?, notes: String) -> Bool {
        guard canApplyImageResult(id, hash: hash, epoch: epoch), !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let text = draft(id).text
        edit(id, text: text + (text.isEmpty ? "" : "\n\n") + "[Image notes generated by Muse Spark; review against the attached image]\n" + notes)
        return true
    }
    func clearImages(_ id: String) {
        guard canControl(id) else { return }
        var draft = draft(id); draft.hashes = []; draft.dirty = true; state.drafts[id] = draft; persist(); flush(id)
    }
    func removeImage(_ id: String, hash: String) {
        guard canControl(id) else { return }
        var draft = draft(id)
        guard let index = draft.hashes.firstIndex(of: hash) else { return }
        draft.hashes.remove(at: index); draft.dirty = true
        state.drafts[id] = draft; persist()
        service.saveDraftAttachments(globalID: id, hashes: draft.hashes); flush(id)
    }
    func background() {
        let task = UIApplication.shared.beginBackgroundTask(withName: "Preserve Converse drafts")
        lotSubscriptionsSuspended = true
        for id in state.drafts.keys { flush(id) }; persist(); service.suspendViewer(); hydratedEpochs = [:]
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }
    func foreground() {
        if UIDevice.current.userInterfaceIdiom == .phone { constrainPhonePlacements() }
        service.resumeViewer()
        lotSubscriptionsSuspended = false; reconcileLots()
    } // Saved displays resume conditionally after the home reconnects.
}

enum PadImage {
    static let byteLimit = 8_000_000
    static func normalize(_ data: Data) throws -> Data {
        guard data.count <= 50_000_000, let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        var dimension: CGFloat = min(2048, max(image.size.width, image.size.height))
        while dimension > 0 {
            let ratio = dimension / max(image.size.width, image.size.height)
            let size = CGSize(width: max(1, floor(image.size.width * ratio)), height: max(1, floor(image.size.height * ratio)))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
            let result = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            if let png = result.pngData(), png.count <= byteLimit { return png }
            if dimension <= 128 { break }
            dimension = max(128, dimension * 0.7)
        }
        throw CocoaError(.fileReadTooLarge)
    }
}
