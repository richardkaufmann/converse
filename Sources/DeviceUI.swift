import AppKit
import SwiftUI

final class DeviceConnectForm: ObservableObject {
    @Published var host = ""
    @Published var port = "48721"
}
final class RemoteComposer: ObservableObject {
    // Presentation only: never registered with Store or attached to a CLI.
    let editor = Session(entry: Entry(name: "Remote", command: "", directory: "", engine: "remote"))
    @Published var draft = ""
    @Published var blobHashes: [String] = []
    @Published var sentCommandID: UUID?
    @Published var sentText = ""
    @Published var sentHashes: [String] = []
    var hydratedKey = ""
    private var lastHomeText = ""
    private var lastHomeHashes: [String] = []
    private var offeredHomeText = ""
    private var offeredHomeHashes: [String] = []
    @Published var hydrationConflict = false
    @Published var draftOrigin = ""
    @Published var answers: [String: String] = [:]
    @Published var selections: [String: Set<String>] = [:]
    @discardableResult func hydrate(text: String, hashes: [String], key: String, origin: String) -> Bool {
        hydratedKey = key
        offeredHomeText = text; offeredHomeHashes = hashes
        let unchanged = draft == lastHomeText && blobHashes == lastHomeHashes
        let empty = draft.isEmpty && blobHashes.isEmpty
        let sent = sentCommandID != nil && draft == sentText && blobHashes == sentHashes
        guard unchanged || empty || sent || (draft == text && blobHashes == hashes) else {
            hydrationConflict = true; draftOrigin = "Home supplied a different draft from " + origin + ". Your unsent edits are preserved."
            return false
        }
        useHomeDraft(); draftOrigin = text.isEmpty && hashes.isEmpty ? "" : "Restored unsent draft from " + origin
        return true
    }
    func useHomeDraft() {
        draft = offeredHomeText; blobHashes = offeredHomeHashes
        lastHomeText = draft; lastHomeHashes = blobHashes; hydrationConflict = false
    }
    func keepLocalDraft() {
        lastHomeText = draft; lastHomeHashes = blobHashes; hydrationConflict = false; draftOrigin = ""
    }
    @discardableResult func removeImage(path: String, cache: [String: URL]) -> Bool {
        guard let index = blobHashes.firstIndex(where: { cache[$0]?.path == path }) else { return false }
        blobHashes.remove(at: index); return true
    }
    func restoreFailedSend(_ record: DeviceOutboxRecord) {
        if DeviceDraftRecovery.canRestore(text: draft, hashes: blobHashes, record: record) {
            draft = record.payload.text ?? ""; blobHashes = record.payload.blobHashes
        }
        if sentCommandID == record.commandID {
            sentCommandID = nil; sentText = ""; sentHashes = []
        }
    }
    func updateEditor(transcript: DeviceTranscriptPayload?, cache: [String: URL]) {
        editor.messages = (transcript?.messages ?? []).map { message in
            Message(id: message.id, role: message.role, text: message.text, images: message.imageHashes.compactMap { cache[$0]?.path }, createdAt: nil)
        }
        editor.draft = draft
        editor.attachments = blobHashes.compactMap { cache[$0]?.path }
        editor.busy = transcript?.busy ?? false
    }
}

struct DeviceConnectView: View {
    var body: some View { ConverseGroupsView().frame(width: 600, height: 650) }
}

struct DeviceSidebarSection: View {
    @ObservedObject var service = DeviceSyncService.shared
    @ObservedObject var workspace: Workspace
    @ObservedObject var state: WindowState
    var showsModel = true
    var body: some View {
        let homes = service.homes.values.sorted { $0.deviceName < $1.deviceName }
        if service.currentGroup != nil && !homes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(homes, id: \.deviceID) { home in
                    HStack(spacing: 6) {
                        Circle().fill(home.online ? Color.green : Color.gray).frame(width: 8, height: 8)
                        Text(home.deviceName).fontWeight(.bold).lineLimit(1)
                        Text(home.online ? "home" : "offline").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 4)
                    ForEach(home.rows) { row in
                        RemoteSidebarRow(row: row, homeName: home.deviceName, online: home.online, showsModel: showsModel,
                                         localPane: workspace.pane(for: service.placementID(forGlobal: row.globalID), in: state.id),
                                         park: { service.releaseRemote(globalID: row.globalID); workspace.park(service.placementID(forGlobal: row.globalID)) },
                                         assign: { pane in service.releaseDisplaced(in: state.id, pane: pane, incomingPlacement: service.placementID(forGlobal: row.globalID)); service.acquireRemote(globalID: row.globalID); workspace.assign(service.placementID(forGlobal: row.globalID), to: state.id, pane: pane) })
                    }
                    if home.rows.isEmpty { Text(home.online ? "No sessions available." : "Offline. Last known sessions kept.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4) }
                }
            }
        }
    }
}

struct RemoteSidebarRow: View {
    let row: DeviceSidebarRow
    let homeName: String
    let online: Bool
    var showsModel = true
    let localPane: Int?
    let park: () -> Void
    let assign: (Int) -> Void
    var helpText: String {
        var text = row.title + "\nHome: " + homeName + "\nModel: " + row.model + "\nState: " + row.status
        if let account = row.accountName { text += "\nAccount: " + account }
        return text + "\nExecution stays on " + homeName + "."
    }
    var body: some View {
        HStack(spacing: 6) {
            ConversationActivity(busy: online && row.busy, status: row.status, waiting: row.status.hasPrefix("Waiting"))
                .help(online ? (row.busy ? row.status : "Idle") : "Home offline")
            Text(row.title).lineLimit(1).truncationMode(.tail).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if showsModel { Text(row.model).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).frame(width: 105, alignment: .leading) }
            if (row.status == "Waiting for approval" || !(row.attention ?? "").isEmpty) && localPane == nil { Text("!").fontWeight(.bold).foregroundStyle(.orange).help("Needs approval") }
            HStack(spacing: 2) {
                PaneButton(label: "P", selected: localPane == nil) { park() }.accessibilityLabel("Park " + row.title)
                ForEach(1...3, id: \.self) { pane in
                    PaneButton(label: String(pane), selected: localPane == pane) { assign(pane) }
                        .accessibilityLabel("Move " + row.title + " to pane " + String(pane) + " here")
                }
            }.fixedSize(horizontal: true, vertical: false).disabled(!online)
        }.padding(.horizontal, 4).padding(.vertical, 3)
            .background((row.status == "Waiting for approval" || !(row.attention ?? "").isEmpty) && localPane == nil ? Color(red: 1, green: 0.84, blue: 0.35) : (localPane == nil ? Color.clear : Color.accentColor.opacity(0.05)))
            .help(helpText)
            .contextMenu {
                Button("Teach Session To Talk To Other Sessions") { DeviceSyncService.shared.sendRemoteCommand(globalID: row.globalID, command: DeviceCommandPayload(action: "teachSwitchboard")) }
                    .disabled(!DeviceSyncService.shared.canTeachRemote(row.globalID))
                Button("Park conversation") { park() }
            }
    }
}

struct RemotePane: View {
    let globalID: String
    let pane: Int
    @ObservedObject var service = DeviceSyncService.shared
    @ObservedObject var workspace: Workspace
    var leadingInset: CGFloat = 0
    @ObservedObject var store = Store.shared
    @StateObject private var composer = RemoteComposer()
    var transcript: DeviceTranscriptPayload? { service.remoteTranscripts[globalID] }
    var hasLease: Bool { service.remoteLeases[globalID] != nil }
    var offline: Bool { service.remoteOffline.contains(globalID) }
    var pendingRecord: DeviceOutboxRecord? { service.unresolved(globalID: globalID).first { $0.payload.action == "submit" } }
    var queueRecord: DeviceOutboxRecord? { service.queueCommand(globalID: globalID) }
    var queueBusy: Bool { queueRecord.map { ["pending", "accepted", "uncertain"].contains($0.outcome) } ?? false }
    var placement: UUID { service.placementID(forGlobal: globalID) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(String(pane)).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.white).frame(width: 19, height: 19).background(Color(red: 0.12, green: 0.52, blue: 0.28)).clipShape(RoundedRectangle(cornerRadius: 3))
                if let engine = transcript?.engine, !engine.isEmpty { ProviderLogo(engine: engine) }
                Text(transcript?.title ?? service.remoteRow(globalID: globalID)?.title ?? "Remote session").font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text("on home Mac").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                PaneButton(label: "P", selected: false) { service.releaseRemote(globalID: globalID); workspace.park(placement) }.help("Park this conversation")
            }.padding(.leading, leadingInset).padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            HStack {
                Text("↵ send / queue · ⌘↵ newline").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Toggle("line numbers", isOn: $store.lineNumbers).toggleStyle(.checkbox).font(.caption).fixedSize()
                Button {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK { for url in panel.urls { if let image = NSImage(contentsOf: url) { attach(image) } } }
                } label: { Image(systemName: "paperclip") }.help("Attach image or paste a screenshot").disabled(offline || !hasLease)
                if !composer.blobHashes.isEmpty { Button("Clear images") { composer.blobHashes = []; service.saveDraftAttachments(globalID: globalID, hashes: []); syncEditor() }.disabled(composer.hydrationConflict) }
                if transcript?.busy == true {
                    if transcript?.requests.isEmpty != false { ProgressView().controlSize(.small) }
                    Button("Stop") { service.sendRemoteCommand(globalID: globalID, command: DeviceCommandPayload(action: "stop")) }.disabled(offline || !hasLease)
                }
            }.padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            if let widget = transcript?.agentWidget {
                DisclosureGroup("Agent scoreboard") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let hash = widget.artHash, let file = service.blobCache[hash], let image = NSImage(contentsOf: file) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 160) }
                        Text(widget.metrics.map { $0.label + ": " + $0.value }.joined(separator: " · ")).font(.caption).textSelection(.enabled)
                        Text(widget.summary).font(.caption).textSelection(.enabled)
                    }
                }.padding(8)
                if !widget.attention.isEmpty { ApprovalHeading(detail: widget.attention, title: "ATTENTION REQUIRED") }
            }
            if offline {
                Text("Home offline. Last transcript shown. Sending disabled; nothing replays silently.").font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.12))
            } else if !hasLease {
                HStack {
                    Text("Display is elsewhere or lease expired.").font(.caption); Spacer()
                    Button("Take here") { service.acquireRemote(globalID: globalID) }
                }.padding(8).background(Color.accentColor.opacity(0.06))
            }
            if let request = transcript?.requests.first { RemoteRequestView(globalID: globalID, request: request, composer: composer) }
            if let pending = transcript?.pending, !pending.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(pending.count) + " queued on home" + (transcript?.queuePaused == true ? " · paused" : "")); Spacer()
                        Button(transcript?.queuePaused == true ? "Resume queue" : "Pause queue") { service.sendRemoteCommand(globalID: globalID, command: DeviceCommandPayload(action: transcript?.queuePaused == true ? "resumeQueue" : "pauseQueue")) }
                        Button(queueBusy && queueRecord?.payload.action == "injectAll" ? "Injecting…" : "Inject all") { service.sendRemoteCommand(globalID: globalID, command: DeviceCommandPayload(action: "injectAll")) }
                        Button("Clear queue") { service.sendRemoteCommand(globalID: globalID, command: DeviceCommandPayload(action: "clearQueue")) }
                    }
                    ForEach(pending) { item in
                        HStack { Text(item.text).foregroundStyle(TranscriptStyle.isTraffic(item.text) ? Color(nsColor: TranscriptPalette.traffic) : Color.primary).lineLimit(1); Spacer(); Button(queueBusy && queueRecord?.payload.pendingID == item.id ? "Injecting…" : "Inject now") { service.sendRemoteCommand(globalID: globalID, command: DeviceCommandPayload(action: "inject", pendingID: item.id)) } }
                    }
                }.font(.caption).padding(8).background(Color.accentColor.opacity(0.06)).disabled(offline || !hasLease || queueBusy)
            }
            if let record = queueRecord {
                RemoteQueueFeedback(record: record, available: !offline && hasLease,
                                    check: { service.queryOutbox(record) }, dismiss: { service.discardOutbox(record) })
            }
            if let record = pendingRecord {
                HStack {
                    Text(outboxText(record)).font(.caption)
                    Spacer()
                    if record.outcome == "uncertain" {
                        Button("Check home") { service.queryOutbox(record) }
                        Button("Discard") { service.discardOutbox(record); composer.sentCommandID = nil }
                    } else if record.outcome == "failed" || record.outcome == "rejected" {
                        Button("Restore to composer") { composer.restoreFailedSend(record); service.discardOutbox(record) }
                        Button("Discard") { service.discardOutbox(record); composer.sentCommandID = nil }
                    } else if record.outcome == "accepted" {
                        Button("Dismiss") { service.discardOutbox(record); composer.sentCommandID = nil }
                    } else { Button("Resend same ID") { service.retryOutbox(record) } }
                }.padding(8).background(Color.orange.opacity(0.10))
            }
            if let conflict = service.draftConflicts[globalID] {
                Text(conflict).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.10))
            }
            if !composer.draftOrigin.isEmpty {
                HStack {
                    Text(composer.draftOrigin).textSelection(.enabled); Spacer()
                    if composer.hydrationConflict {
                        Button("Keep my draft") {
                            composer.keepLocalDraft()
                            service.sendRemoteDraft(globalID: globalID, text: composer.draft, imageHashes: composer.blobHashes)
                        }
                        Button("Use home draft") { composer.useHomeDraft(); composer.draftOrigin = ""; syncEditor() }
                    }
                }.font(.caption).padding(8).background(Color.orange.opacity(0.10))
            }
            if let transcript, transcript.offset > 0 {
                Button("Load earlier messages (" + String(transcript.offset) + " earlier)") { service.requestEarlier(globalID: globalID) }.font(.caption).padding(4)
            }
            ScrollingConversation(session: composer.editor, lineNumbers: store.lineNumbers, inputEnabled: hasLease && !offline,
                onTeachSwitchboard: service.canTeachRemote(globalID) ? { service.sendRemoteCommand(globalID: globalID, command: DeviceCommandPayload(action: "teachSwitchboard")) } : nil,
                                  onSubmit: send,
                                  onDraftChanged: {
                                      composer.draft = $0
                                      if !composer.hydrationConflict { composer.draftOrigin = ""; service.sendRemoteDraft(globalID: globalID, text: $0) }
                                  },
                                  onImagePaste: attach,
                                  onImageRemove: { path in
                                      guard hasLease, !offline, composer.removeImage(path: path, cache: service.blobCache) else { return }
                                      if !composer.hydrationConflict {
                                          service.saveDraftAttachments(globalID: globalID, hashes: composer.blobHashes)
                                          service.sendRemoteDraft(globalID: globalID, text: composer.draft, imageHashes: composer.blobHashes)
                                      }
                                      syncEditor()
                                  })
            Divider()
            if let transcript {
                HStack(spacing: 10) {
                    Text(transcript.status).lineLimit(1)
                    if let account = transcript.accountName { Text(account).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 0)
                    Menu(transcript.model) { ForEach(transcript.modelOptions) { option in Button(option.label) { service.sendRemoteCommand(globalID: globalID, command: DeviceCommandPayload(action: "model", model: option.id, modelProvider: option.provider, modelProfile: option.profile)) } } }.menuStyle(.borderlessButton).fixedSize()
                    Menu(transcript.effort) { ForEach(transcript.effortOptions, id: \.self) { effort in Button(effort) { service.sendRemoteCommand(globalID: globalID, command: DeviceCommandPayload(action: "effort", effort: effort)) } } }.menuStyle(.borderlessButton).fixedSize()
                    Menu(transcript.access) { ForEach(transcript.accessOptions) { option in Button(option.label) { service.sendRemoteCommand(globalID: globalID, command: DeviceCommandPayload(action: "access", access: option.id)) } } }.menuStyle(.borderlessButton).fixedSize()
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4).disabled(!hasLease)
            }
            if !composer.blobHashes.isEmpty {
                Text(composer.blobHashes.allSatisfy { service.blobReady[$0] == true } ? "Attachments stored on home. Ready to send." : "Uploading attachments to home… Send waits for home storage.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            if service.lastOutcome.hasPrefix("failed") || service.lastOutcome.hasPrefix("Attachment failed") {
                Text(service.lastOutcome).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal, 10).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(Color(nsColor: .textBackgroundColor)).frame(minWidth: PaneSizing.minimumPane, maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: service.remoteLeases[globalID]) { _, _ in hydrate(force: true); syncEditor() }
            .onChange(of: service.remoteTranscripts[globalID]?.draftVersion) { _, _ in hydrate() }
            .onChange(of: service.remoteTranscripts[globalID]?.globalID) { _, _ in hydrate() }
            .onAppear { hydrate(); syncEditor() }
            .onChange(of: service.remoteTranscripts[globalID]?.homeSeq) { _, _ in hydrate(); syncEditor() }
            .onChange(of: composer.draft) { _, _ in syncEditor() }
            .onChange(of: composer.blobHashes) { _, _ in syncEditor() }
            .onChange(of: service.blobCache) { _, _ in syncEditor() }
            .onChange(of: service.completedCommands) { _, completed in
                // Only explicit completion clears, and only exact matches.
                // Edited text is never prefix-stripped; discard never clears.
                if let id = composer.sentCommandID, completed.contains(id) {
                    if composer.draft == composer.sentText { composer.draft = "" }
                    if composer.blobHashes == composer.sentHashes { composer.blobHashes = []; service.saveDraftAttachments(globalID: globalID, hashes: []) }
                    service.sendRemoteDraft(globalID: globalID, text: composer.draft)
                    composer.sentText = ""; composer.sentHashes = []; composer.sentCommandID = nil
                }
            }
    }
    func outboxText(_ record: DeviceOutboxRecord) -> String {
        switch record.outcome {
        case "uncertain": return "Send uncertain. Home may have received it. Check home first."
        case "failed", "rejected": return "Home did not accept this send. Your text is preserved."
        case "accepted": return "Accepted on home. Still finishing there."
        default: return "Waiting for home acknowledgment…"
        }
    }
    var canSend: Bool {
        hasLease && !offline && !composer.hydrationConflict && pendingRecord == nil && (!composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composer.blobHashes.isEmpty) && composer.blobHashes.allSatisfy { service.blobReady[$0] == true }
    }
    func hydrate(force: Bool = false) {
        guard let transcript, let epoch = service.remoteLeases[globalID], transcript.epoch == epoch else { return }
        let key = globalID + "@" + String(epoch)
        guard force || composer.hydratedKey != key else { return }
        let home = DeviceGlobalID(globalID).flatMap { service.homes[$0.home]?.deviceName } ?? "home device"
        composer.hydrate(text: transcript.draft, hashes: transcript.draftImageHashes ?? [], key: key, origin: home + " (version " + String(transcript.draftVersion) + ")")
        for hash in composer.blobHashes where service.blobReady[hash] != true { service.queryBlob(globalID: globalID, hash: hash) }
        if let record = pendingRecord { composer.sentCommandID = record.commandID; composer.sentText = record.payload.text ?? ""; composer.sentHashes = record.payload.blobHashes }
    }
    func syncEditor() {
        composer.updateEditor(transcript: transcript, cache: service.blobCache)
        let hashes = (transcript?.messages ?? []).flatMap(\.imageHashes) + composer.blobHashes + [transcript?.agentWidget?.artHash].compactMap { $0 }
        for hash in Set(hashes) where service.blobCache[hash] == nil { service.fetchBlob(globalID: globalID, hash: hash) }
    }
    func attach(_ image: NSImage) {
        guard hasLease, !offline, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]), let hash = service.sendRemoteBlob(globalID: globalID, data: data) else { return }
        let folder = Store.shared.folder.appendingPathComponent("RemoteCache")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent(hash + ".png"); try data.write(to: path, options: .atomic)
            service.blobCache[hash] = path
        } catch { service.lastOutcome = "Attachment failed: " + error.localizedDescription }
        composer.blobHashes.append(hash)
        if !composer.hydrationConflict { service.saveDraftAttachments(globalID: globalID, hashes: composer.blobHashes) }
        syncEditor()
    }
    func send() {
        guard canSend else { return }
        composer.sentText = composer.draft; composer.sentHashes = composer.blobHashes
        composer.sentCommandID = service.sendRemoteCommand(globalID: globalID, command: DeviceCommandPayload(action: "submit", text: composer.draft, blobHashes: composer.blobHashes))
    }
}

struct RemoteQueueFeedback: View {
    let record: DeviceOutboxRecord
    let available: Bool
    let check: () -> Void
    let dismiss: () -> Void
    var waiting: Bool { ["pending", "accepted", "uncertain"].contains(record.outcome) }
    var body: some View {
        HStack {
            Text(record.detail ?? (waiting ? "Queue request sent. Waiting for home acknowledgment…" : "Queue request was not applied.")).textSelection(.enabled)
            Spacer()
            if waiting { Button("Check home", action: check).disabled(!available) }
            else { Button("Dismiss", action: dismiss) }
        }.font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.12))
    }
}

struct RemoteRequestView: View {
    let globalID: String
    let request: DeviceRequestDTO
    @ObservedObject var composer: RemoteComposer
    @ObservedObject var service = DeviceSyncService.shared
    var questions: [[String: Any]] {
        request.questionsJSON.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]] } ?? []
    }
    func options(_ q: [String: Any]) -> [[String: Any]] { q["options"] as? [[String: Any]] ?? [] }
    func isMultiple(_ q: [String: Any]) -> Bool {
        if let selection = q["selection"] as? [String: Any] { return (selection["mode"] as? String) == "multiple" }
        return false
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if request.kind == "approval" {
                HStack { Text("PERMISSION REQUIRED").font(.system(size: 12, weight: .bold)); Text("Review before continuing").font(.system(size: 11)).opacity(0.75) }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color(red: 1, green: 0.78, blue: 0.12))
            } else {
                Text("Home session has a question").fontWeight(.semibold)
            }
            if request.kind == "approval" {
                if let tool = request.toolName { Text(tool).fontWeight(.medium) }
                if let args = request.rawArgs { Text(args).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                ForEach(request.choices) { choice in
                    HStack {
                        Button(choice.label) { service.sendRemoteCommand(globalID: globalID, command: DeviceCommandPayload(action: "answer", requestID: request.id, choiceID: choice.id)) }
                        if let detail = choice.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if request.choices.isEmpty { Text("No decision choices received yet.").foregroundStyle(.secondary) }
            } else {
                ForEach(questions.indices, id: \.self) { index in
                    let q = questions[index]; let qid = q["id"] as? String ?? String(index)
                    Text(q["question"] as? String ?? "Question").textSelection(.enabled)
                    ForEach(options(q).indices, id: \.self) { oi in
                        let option = options(q)[oi]; let label = option["label"] as? String ?? "Option"
                        let selected = composer.selections[qid]?.contains(label) == true
                        Button((selected ? "✓ " : "○ ") + label) {
                            if isMultiple(q) {
                                if selected { composer.selections[qid]?.remove(label) } else { composer.selections[qid, default: []].insert(label) }
                            } else { composer.selections[qid] = [label] }
                        }.buttonStyle(.plain)
                        if let desc = option["description"] as? String { Text(desc).font(.caption).foregroundStyle(.secondary) }
                    }
                    TextField(options(q).isEmpty ? "Your answer" : "Or type your own", text: Binding(get: { composer.answers[qid] ?? "" }, set: { composer.answers[qid] = $0 }), axis: .vertical).lineLimit(1...4)
                }
                Button("Send answer") {
                    let answers: [[String: Any]] = questions.map { q in
                        let qid = q["id"] as? String ?? ""
                        let chosen = composer.selections[qid] ?? []
                        var answer: [String: Any] = ["questionId": qid]
                        if isMultiple(q) { if !chosen.isEmpty { answer["selectedLabels"] = Array(chosen) } }
                        else if let one = chosen.first { answer["selectedLabel"] = one }
                        let free = (composer.answers[qid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !free.isEmpty { answer["freeText"] = free }
                        return answer
                    }
                    let json = try? JSONSerialization.data(withJSONObject: answers)
                    service.sendRemoteCommand(globalID: globalID, command: DeviceCommandPayload(action: "answer", requestID: request.id, answersJSON: json))
                }
            }
        }.padding(10).background(Color(nsColor: .controlBackgroundColor))
    }
}

