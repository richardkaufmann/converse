import AppKit
import SwiftUI

final class DeviceConnectForm: ObservableObject {
    @Published var host = ""
    @Published var port = "48721"
}
final class RemoteComposer: ObservableObject {
    @Published var draft = ""
    @Published var blobHashes: [String] = []
    @Published var sentCommandID: UUID?
    @Published var sentText = ""
    var hydratedSession: UUID?
    var suppressEcho = false
    @Published var answers: [String: String] = [:]
}

struct DeviceConnectView: View {
    @ObservedObject var service = DeviceSyncService.shared
    @Environment(\.dismiss) var dismiss
    @StateObject private var form = DeviceConnectForm()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to Other Converses").font(.title2.bold())
            Text(service.serviceStatus + " · " + service.localCodeNote).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Pairing lets each Mac view history and send prompts on the other Mac. Prompts run tools on the home Mac under its logins. Pair only with your own devices.").font(.callout)
            GroupBox("Nearby devices") {
                if service.discovered.isEmpty { Text("No nearby Converse found yet. Keep both apps open on the same network.").font(.caption).foregroundStyle(.secondary) }
                ForEach(service.discovered) { device in
                    HStack { Text(device.name); Spacer(); Button("Connect") { service.connect(discovered: device) } }
                }
            }
            GroupBox("Connect by address") {
                HStack {
                    TextField("Host or IP", text: $form.host).textFieldStyle(.roundedBorder)
                    TextField("Port", text: $form.port).frame(width: 80).textFieldStyle(.roundedBorder)
                    Button("Connect") { service.connectManual(host: form.host.trimmingCharacters(in: .whitespaces), port: Int(form.port) ?? -1) }.disabled(form.host.isEmpty)
                }
                Text("Use this across VPNs where discovery does not reach. Pairing and encryption are identical.").font(.caption).foregroundStyle(.secondary)
            }
            GroupBox("Paired devices") {
                if service.trusted.isEmpty { Text("None paired.").font(.caption).foregroundStyle(.secondary) }
                ForEach(service.trusted) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text((service.homes[device.deviceID]?.online == true ? "Online" : "Offline") + " · " + String(device.deviceID.prefix(16)).uppercased()).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget Device", role: .destructive) { service.forgetDevice(device) }
                    }
                }
            }
            if !service.lastOutcome.isEmpty { Text(service.lastOutcome).font(.caption).textSelection(.enabled) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 560)
            .alert(item: $service.pairingPrompt) { prompt in
                Alert(title: Text("Pair with " + prompt.peerName + "?"),
                      message: Text("Confirm this code matches on both Macs:\n\n" + prompt.code + "\n\nFingerprint " + prompt.fingerprint + (prompt.keyChanged ? "\n\nWarning: stored key mismatch. Pair again only if you expect this." : "") + (prompt.nameCollision ? "\n\nNote: a different paired device already uses this name. Check the fingerprint." : "") + "\n\nPairing allows remote prompts and tool execution on the home Mac."),
                      primaryButton: .default(Text("Pair")) { service.confirmPairing() },
                      secondaryButton: .cancel(Text("Reject")) { service.rejectPairing() })
            }
    }
}

struct DeviceSidebarSection: View {
    @ObservedObject var service = DeviceSyncService.shared
    @ObservedObject var workspace: Workspace
    @ObservedObject var state: WindowState
    var showsModel = true
    var body: some View {
        let homes = service.homes.values.sorted { $0.deviceName < $1.deviceName }
        if !homes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(homes, id: \.deviceID) { home in
                    HStack(spacing: 6) {
                        Circle().fill(home.online ? Color.green : Color.gray).frame(width: 8, height: 8)
                        Text(home.deviceName).fontWeight(.bold).lineLimit(1)
                        Text(home.online ? "home" : "offline").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 4)
                    ForEach(home.rows) { row in
                        RemoteSidebarRow(row: row, homeName: home.deviceName, online: home.online, showsModel: showsModel,
                                         localPane: workspace.pane(for: row.sessionID, in: state.id),
                                         park: { service.releaseRemote(sessionID: row.sessionID); workspace.park(row.sessionID) },
                                         assign: { pane in service.acquireRemote(globalID: row.globalID); workspace.assign(row.sessionID, to: state.id, pane: pane) })
                    }
                    if home.rows.isEmpty { Text(home.online ? "No sessions shared yet." : "Offline. Last known sessions kept.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4) }
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
            Circle().fill(row.busy ? Color.orange : Color.clear).frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            Text(row.title).lineLimit(1).truncationMode(.tail).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if showsModel { Text(row.model).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).frame(width: 105, alignment: .leading) }
            HStack(spacing: 2) {
                PaneButton(label: "P", selected: localPane == nil) { park() }.accessibilityLabel("Park " + row.title)
                ForEach(1...3, id: \.self) { pane in
                    PaneButton(label: String(pane), selected: localPane == pane) { assign(pane) }
                        .accessibilityLabel("Move " + row.title + " to pane " + String(pane) + " here")
                }
            }.fixedSize(horizontal: true, vertical: false).disabled(!online)
        }.padding(.horizontal, 4).padding(.vertical, 3)
            .background(localPane == nil ? Color.clear : Color.accentColor.opacity(0.05))
            .help(helpText)
    }
}

struct RemotePane: View {
    let sessionID: UUID
    let pane: Int
    @ObservedObject var service = DeviceSyncService.shared
    @ObservedObject var workspace: Workspace
    @StateObject private var composer = RemoteComposer()
    var transcript: DeviceTranscriptPayload? { service.remoteTranscripts[sessionID] }
    var hasLease: Bool { service.remoteLeases[sessionID] != nil }
    var offline: Bool { service.remoteOffline.contains(sessionID) }
    var pendingRecord: DeviceOutboxRecord? { composer.sentCommandID.flatMap { id in service.outbox.first { $0.commandID == id } } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(String(pane)).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.white).frame(width: 19, height: 19).background(Color(red: 0.12, green: 0.52, blue: 0.28)).clipShape(RoundedRectangle(cornerRadius: 3))
                if let engine = transcript?.engine, !engine.isEmpty { ProviderLogo(engine: engine) }
                Text(transcript?.title ?? service.remoteRow(sessionID: sessionID)?.title ?? "Remote session").font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text("on home Mac").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                PaneButton(label: "P", selected: false) { service.releaseRemote(sessionID: sessionID); workspace.park(sessionID) }.help("Park this conversation")
            }.padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            if offline {
                Text("Home offline. Last transcript shown. Sending disabled; nothing replays silently.").font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.12))
            } else if !hasLease {
                HStack {
                    Text("Display is elsewhere or lease expired.").font(.caption); Spacer()
                    Button("Take here") { if let row = service.remoteRow(sessionID: sessionID) { service.acquireRemote(globalID: row.globalID) } }
                }.padding(8).background(Color.accentColor.opacity(0.06))
            }
            if let request = transcript?.requests.first { RemoteRequestView(sessionID: sessionID, request: request, composer: composer) }
            if let pending = transcript?.pending, !pending.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(pending.count) + " queued on home" + (transcript?.queuePaused == true ? " · paused" : "")); Spacer()
                        Button(transcript?.queuePaused == true ? "Resume queue" : "Pause queue") { service.sendRemoteCommand(sessionID: sessionID, command: DeviceCommandPayload(action: transcript?.queuePaused == true ? "resumeQueue" : "pauseQueue")) }
                        Button("Inject all") { service.sendRemoteCommand(sessionID: sessionID, command: DeviceCommandPayload(action: "injectAll")) }
                        Button("Clear queue") { service.sendRemoteCommand(sessionID: sessionID, command: DeviceCommandPayload(action: "clearQueue")) }
                    }
                    ForEach(pending) { item in
                        HStack { Text(item.text).lineLimit(1); Spacer(); Button("Inject now") { service.sendRemoteCommand(sessionID: sessionID, command: DeviceCommandPayload(action: "inject", pendingID: item.id)) } }
                    }
                }.font(.caption).padding(8).background(Color.accentColor.opacity(0.06))
            }
            if let record = pendingRecord {
                HStack {
                    Text(record.outcome == "uncertain" ? "Send uncertain. Home may have received it. Check home first." : "Waiting for home acknowledgment…").font(.caption)
                    Spacer()
                    if record.outcome == "uncertain" {
                        Button("Check home") { service.queryOutbox(record) }
                        Button("Discard") { service.discardOutbox(record); composer.sentCommandID = nil }
                    } else { Button("Resend same ID") { service.retryOutbox(record) } }
                }.padding(8).background(Color.orange.opacity(0.10))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let transcript, transcript.offset > 0 {
                        Button("Load earlier messages (" + String(transcript.offset) + " earlier)") { service.requestEarlier(sessionID: sessionID) }
                    }
                    ForEach(transcript?.messages ?? []) { message in RemoteMessageView(sessionID: sessionID, message: message) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            if let transcript {
                HStack(spacing: 10) {
                    Text(transcript.status).lineLimit(1)
                    if let account = transcript.accountName { Text(account).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 0)
                    Menu(transcript.model) { ForEach(transcript.modelOptions) { option in Button(option.label) { service.sendRemoteCommand(sessionID: sessionID, command: DeviceCommandPayload(action: "model", model: option.id)) } } }.menuStyle(.borderlessButton).fixedSize()
                    Menu(transcript.effort) { ForEach(transcript.effortOptions, id: \.self) { effort in Button(effort) { service.sendRemoteCommand(sessionID: sessionID, command: DeviceCommandPayload(action: "effort", effort: effort)) } } }.menuStyle(.borderlessButton).fixedSize()
                    Menu(transcript.access) { ForEach(transcript.accessOptions) { option in Button(option.label) { service.sendRemoteCommand(sessionID: sessionID, command: DeviceCommandPayload(action: "access", access: option.id)) } } }.menuStyle(.borderlessButton).fixedSize()
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4).disabled(transcript.busy || !hasLease)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message home session… Return sends", text: $composer.draft, axis: .vertical).lineLimit(1...6).textFieldStyle(.roundedBorder)
                    .disabled(offline || !hasLease)
                    .onChange(of: composer.draft) { _, value in if !composer.suppressEcho { service.sendRemoteDraft(sessionID: sessionID, text: value) } }
                    .onSubmit { send() }
                Button("Attach") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url), let hash = service.sendRemoteBlob(sessionID: sessionID, data: data) { composer.blobHashes.append(hash) }
                }.disabled(offline || !hasLease)
                Button("Stop") { service.sendRemoteCommand(sessionID: sessionID, command: DeviceCommandPayload(action: "stop")) }.disabled(!hasLease)
                Button("Send", action: send).disabled(!canSend)
            }.padding(10)
            if !composer.blobHashes.isEmpty {
                Text(composer.blobHashes.allSatisfy { service.blobReady[$0] == true } ? "Attachments stored on home. Ready to send." : "Uploading attachments to home… Send waits for home storage.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !service.lastOutcome.isEmpty {
                Text(service.lastOutcome).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal, 10).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(Color(nsColor: .textBackgroundColor)).frame(minWidth: PaneSizing.minimumPane, maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: transcript?.draftVersion) { _, _ in hydrate() }
            .onAppear { hydrate() }
            .onChange(of: service.outbox) { _, _ in
                if let id = composer.sentCommandID, !service.outbox.contains(where: { $0.commandID == id }) {
                    composer.suppressEcho = true; composer.draft = ""; composer.blobHashes = []; composer.sentText = ""; composer.sentCommandID = nil; composer.suppressEcho = false
                }
            }
    }
    var canSend: Bool {
        hasLease && !offline && composer.sentCommandID == nil && (!composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composer.blobHashes.isEmpty) && composer.blobHashes.allSatisfy { service.blobReady[$0] == true }
    }
    func hydrate() {
        guard let transcript, composer.hydratedSession != sessionID else { return }
        composer.hydratedSession = sessionID; composer.suppressEcho = true; composer.draft = transcript.draft; composer.suppressEcho = false
    }
    func send() {
        guard canSend else { return }
        composer.sentText = composer.draft
        composer.sentCommandID = service.sendRemoteCommand(sessionID: sessionID, command: DeviceCommandPayload(action: "submit", text: composer.draft, blobHashes: composer.blobHashes))
    }
}

struct RemoteMessageView: View {
    let sessionID: UUID
    let message: DeviceWireMessage
    @ObservedObject var service = DeviceSyncService.shared
    var body: some View {
        let visible = Store.visibleText(message.text)
        if message.role != "activity" && (!visible.isEmpty || !message.imageHashes.isEmpty) {
            VStack(alignment: .leading, spacing: 6) {
                if !visible.isEmpty {
                    if message.role == "assistant" { Text(AttributedString(MarkdownText.render(visible))).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    else { Text(visible).italic(message.role == "user").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
                ForEach(message.imageHashes, id: \.self) { hash in
                    if let url = service.blobCache[hash], let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                    } else {
                        Text("Image on home…").font(.caption).foregroundStyle(.secondary).onAppear { service.fetchBlob(sessionID: sessionID, hash: hash) }
                    }
                }
            }
        }
    }
}

struct RemoteRequestView: View {
    let sessionID: UUID
    let request: DeviceRequestDTO
    @ObservedObject var composer: RemoteComposer
    @ObservedObject var service = DeviceSyncService.shared
    var questions: [[String: Any]] {
        request.questionsJSON.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]] } ?? []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.kind == "approval" ? "Home session needs your approval" : "Home session has a question").fontWeight(.semibold)
            if request.kind == "approval" {
                if let tool = request.toolName { Text(tool).fontWeight(.medium) }
                if let args = request.rawArgs { Text(args).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                ForEach(request.choices) { choice in
                    HStack {
                        Button(choice.label) { service.sendRemoteCommand(sessionID: sessionID, command: DeviceCommandPayload(action: "answer", requestID: request.id, choiceID: choice.id)) }
                        if let detail = choice.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if request.choices.isEmpty { Text("No decision choices received yet.").foregroundStyle(.secondary) }
            } else {
                ForEach(questions.indices, id: \.self) { index in
                    let q = questions[index]; let qid = q["id"] as? String ?? String(index)
                    Text(q["question"] as? String ?? "Question").textSelection(.enabled)
                    TextField("Your answer", text: Binding(get: { composer.answers[qid] ?? "" }, set: { composer.answers[qid] = $0 }), axis: .vertical).lineLimit(1...4)
                }
                Button("Send answer") {
                    let answers: [[String: Any]] = questions.map { q in
                        let qid = q["id"] as? String ?? ""
                        return ["questionId": qid, "freeText": composer.answers[qid] ?? ""]
                    }
                    let json = try? JSONSerialization.data(withJSONObject: answers)
                    service.sendRemoteCommand(sessionID: sessionID, command: DeviceCommandPayload(action: "answer", requestID: request.id, answersJSON: json))
                }
            }
        }.padding(10).background(Color(nsColor: .controlBackgroundColor))
    }
}

