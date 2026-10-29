import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@main
struct ConversePadApp: App {
    @StateObject private var model = PadModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            PadRoot(model: model).onAppear { model.foreground() }
                .onChange(of: phase) { _, value in
                    if value == .background { model.background() }
                    else if value == .active { model.foreground() }
                }
        }
    }
}

struct PadAgentTarget: Identifiable { var id = UUID(); var home: String; var target: String? }

struct PadRoot: View {
    @ObservedObject var model: PadModel
    @ObservedObject private var service = DeviceSyncService.shared
    @State private var agentTarget: PadAgentTarget?
    @State private var dragWidth: Double?
    var body: some View {
        GeometryReader { geometry in
            let width = PadLayout.sidebarWidth(preferred: model.state.sidebarWidth, available: geometry.size.width)
            HStack(spacing: 0) {
                if !model.state.sidebarHidden {
                    sidebar.frame(width: width)
                    Rectangle().fill(.separator).frame(width: 5).contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            if dragWidth == nil { dragWidth = width }
                            model.state.sidebarWidth = min(geometry.size.width * 0.5, max(120, (dragWidth ?? width) + value.translation.width))
                        }.onEnded { _ in dragWidth = nil; model.persist() })
                        .accessibilityLabel("Resize conversation sidebar")
                }
                VStack(spacing: 0) {
                    HStack {
                        if model.state.sidebarHidden { pin }
                        Text("Converse").font(.headline)
                        Spacer()
                        Menu {
                            Button("Converse Groups…") { model.connectShown = true }
                            Button("Converse Help…") { model.helpShown = true }
                            Divider()
                            Text("Converse " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + ")")
                            Text("Richard Kaufmann")
                            Link("richard@kaoslabs.app", destination: URL(string: "mailto:richard@kaoslabs.app")!)
                            Link("www.kaoslabs.app", destination: URL(string: "https://www.kaoslabs.app")!)
                            Toggle("Line numbers", isOn: $model.lineNumbers)
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Converse menu")
                    }.padding(10)
                    Divider()
                    let assigned = model.state.placements.indices.filter { model.state.placements[$0] != nil }
                    if assigned.isEmpty {
                        ContentUnavailableView {
                            Label("Your conversations, here", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("Join a Converse group, then tap 1, 2 or 3 beside a session. Models and logins stay on its home computer.")
                        } actions: { Button("Converse Groups") { model.connectShown = true }.buttonStyle(.borderedProminent) }
                    } else if geometry.size.width - (model.state.sidebarHidden ? 0 : width) >= CGFloat(assigned.count) * 360 {
                        HStack(spacing: 0) {
                            ForEach(assigned, id: \.self) { pane in
                                if pane != assigned.first { Divider() }
                                PadPane(id: model.state.placements[pane]!, pane: pane, model: model)
                            }
                        }
                    } else {
                        if assigned.count > 1 {
                            Picker("Visible pane", selection: $model.focusedPane) {
                                ForEach(assigned, id: \.self) { pane in Text("\(pane + 1) · " + (service.remoteRow(globalID: model.state.placements[pane]!)?.title ?? "Session")).tag(pane) }
                            }.pickerStyle(.segmented).padding(6)
                        }
                        let visible = assigned.contains(model.focusedPane) ? model.focusedPane : assigned[0]
                        PadPane(id: model.state.placements[visible]!, pane: visible, model: model).id(model.state.placements[visible])
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(Color(uiColor: .systemBackground))
        }
        .onChange(of: service.groupRequests) { old, requests in
            let previous = Set(old.map(\.id))
            if requests.contains(where: { !$0.approved && !previous.contains($0.id) }) { model.connectShown = true }
        }
        .sheet(isPresented: $model.connectShown) { PadConnect(model: model) }
        .sheet(isPresented: $model.helpShown) { PadHelp() }
        .sheet(item: $agentTarget) { PadAgentPanel(home: $0.home, target: $0.target) }
        .alert("Converse", isPresented: Binding(get: { !model.error.isEmpty }, set: { if !$0 { model.error = "" } })) { Button("OK") { model.error = "" } } message: { Text(model.error) }
    }
    var pin: some View {
        Button {
            model.state.sidebarHidden.toggle(); model.persist()
        } label: { Image(systemName: model.state.sidebarHidden ? "pin" : "pin.fill").frame(width: 30, height: 30) }
            .accessibilityLabel(model.state.sidebarHidden ? "Show conversation sidebar" : "Hide conversation sidebar")
    }
    var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) { pin; Text("Conversation").font(.caption).foregroundStyle(.secondary); Spacer(); Button { model.connectShown = true } label: { Image(systemName: "network") }.accessibilityLabel("Converse Groups") }.padding(6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if let group = service.currentGroup { Text("Group").bold().padding(.top, 6); Text(group.name).font(.caption).foregroundStyle(.secondary) }
                    ForEach((service.currentGroup == nil ? [] : Array(service.homes.values)).sorted { $0.deviceName < $1.deviceName }, id: \.deviceID) { home in
                        if home.online {
                        HStack { Circle().fill(.green).frame(width: 8, height: 8); Text(home.deviceName).bold().lineLimit(1); Text("remote").font(.caption).foregroundStyle(.secondary)
                            if service.canHostAgent(home.deviceID) { Button { agentTarget = PadAgentTarget(home: home.deviceID, target: nil) } label: { Image(systemName: "plus") }.accessibilityLabel("Create agent on " + home.deviceName) }
                        }.padding(.top, 10)
                        if home.rows.isEmpty { Text("No sessions available.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8) }
                        ForEach(home.rows) { row in
                            let pane = model.state.placements.firstIndex(of: row.globalID)
                            let attention = !(row.attention ?? "").isEmpty || (row.status.hasPrefix("Waiting") && pane == nil)
                            HStack(spacing: 3) {
                                if row.busy && home.online { ProgressView().controlSize(.mini).frame(width: 14) }
                                else { Text(attention ? "!" : "").bold().frame(width: 14) }
                                Text(row.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 3) {
                                    placementButton("P", selected: pane == nil) { model.park(row.globalID) }
                                    ForEach(0..<3) { index in placementButton(String(index + 1), selected: pane == index) { model.assign(row.globalID, pane: index) } }
                                    placementButton("X", selected: false) {}.disabled(true).opacity(0.3).accessibilityLabel("Close on home device")
                                }.frame(width: 132).fixedSize(horizontal: true, vertical: false).disabled(!home.online)
                            }.font(.system(size: 13)).padding(.vertical, 4).padding(.horizontal, 3)
                                .background(attention ? Color.yellow.opacity(0.65) : (pane == nil ? .clear : Color.accentColor.opacity(0.07)))
                                .contextMenu {
                                    Text(row.title); Text("Remote device: " + home.deviceName); Text("Account: " + (row.accountName ?? "Not reported")); Text("Model: " + row.model); Text(row.status)
                                    Button("Teach Session To Talk To Other Sessions") { service.sendRemoteCommand(globalID: row.globalID, command: DeviceCommandPayload(action: "teachSwitchboard")) }.disabled(!service.canTeachRemote(row.globalID))
                                    if row.participantKind == "agent" { Button("Agent Setup / Loop") { agentTarget = PadAgentTarget(home: home.deviceID, target: row.globalID) } }
                                    if let warning = row.attention, !warning.isEmpty { Text(warning) }
                                    Button("Park") { model.park(row.globalID) }
                                }
                                .accessibilityElement(children: .contain)
                        }
                        } else { Text(home.deviceName).fontWeight(.regular).foregroundStyle(Color.primary.opacity(0.3)).padding(.top, 10) }
                    }
                    if service.homes.isEmpty { Text("Join a Converse group to see its devices and sessions.").font(.callout).foregroundStyle(.secondary).padding(10) }
                }.padding(.horizontal, 5)
            }
            Button("Converse Groups") { model.connectShown = true }.padding(8)
            Text(service.serviceStatus).font(.caption2).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    func placementButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(selected ? .white : .primary).frame(width: 24, height: 28).background(selected ? Color.green.opacity(0.9) : Color(uiColor: .systemBackground)).clipShape(RoundedRectangle(cornerRadius: 3)).overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.3), lineWidth: 0.5)) }.buttonStyle(.plain)
    }
}

struct PadPane: View {
    let id: String
    let pane: Int
    @ObservedObject var model: PadModel
    @ObservedObject private var service = DeviceSyncService.shared
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var agentSetup = false
    var snapshot: DeviceTranscriptPayload? { service.remoteTranscripts[id] }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(pane + 1)).font(.caption.bold()).foregroundStyle(.white).padding(5).background(.green, in: RoundedRectangle(cornerRadius: 3))
                PadProviderLogo(engine: snapshot?.engine.isEmpty == false ? snapshot!.engine : service.remoteRow(globalID: id)?.engine ?? "")
                Text(snapshot?.title ?? service.remoteRow(globalID: id)?.title ?? "Session").font(.title3).lineLimit(1)
                Spacer()
                if service.remoteRow(globalID: id)?.participantKind == "agent" {
                    Button("Agent Setup / Loop") { agentSetup = true }
                        .sheet(isPresented: $agentSetup) { if let global = DeviceGlobalID(id) { PadAgentPanel(home: global.home, target: id) } }
                }
                Button("P") { model.park(id) }.accessibilityLabel("Park this conversation")
            }.padding(8)
            Divider()
            if !model.canControl(id) {
                HStack {
                    Text(service.remoteOffline.contains(id) ? "Home offline. Your draft is preserved." : "Take this session to edit and send.")
                    Spacer(); Button("Take here") { service.acquireRemote(globalID: id) }
                }.font(.callout).padding(10).background(Color.orange.opacity(0.18))
            }
            if model.conflicts.contains(id) {
                VStack(alignment: .leading) {
                    Text("Recovered draft differs from the home draft. Both are preserved; choose which to edit.").font(.caption)
                    HStack { Button("Keep my recovered draft") { model.resolveDraft(id, keepLocal: true) }; Button("Use home draft") { model.resolveDraft(id, keepLocal: false) } }
                }.padding(8).background(Color.yellow.opacity(0.3))
            }
            if let widget = snapshot?.agentWidget {
                DisclosureGroup("Agent scoreboard") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let hash = widget.artHash, let file = service.blobCache[hash], let image = UIImage(contentsOfFile: file.path) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180) }
                        Text(widget.metrics.map { $0.label + ": " + $0.value }.joined(separator: " · ")).font(.caption).textSelection(.enabled)
                        Text(widget.summary).font(.caption).textSelection(.enabled)
                    }
                }.padding(8)
                if !widget.attention.isEmpty { Label(widget.attention, systemImage: "exclamationmark.triangle.fill").padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.yellow).foregroundStyle(.black) }
            }
            if let request = snapshot?.requests.first { PadRequest(id: id, request: request).disabled(!model.canControl(id)) }
            if let snapshot, !snapshot.pending.isEmpty {
                VStack(spacing: 4) {
                    HStack {
                        Text("\(snapshot.pending.count) queued"); Spacer()
                        Button(snapshot.queuePaused ? "Resume" : "Pause") { command(snapshot.queuePaused ? "resumeQueue" : "pauseQueue") }
                        Button("Inject all") { command("injectAll") }
                        Button("Clear") { command("clearQueue") }
                    }
                    ForEach(snapshot.pending) { item in HStack { Text(item.text).foregroundStyle(TranscriptStyle.isTraffic(item.text) ? Color(uiColor: PadPalette.traffic) : Color.primary).lineLimit(1); Spacer(); Button("Inject now") { service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "inject", pendingID: item.id)) } } }
                }.font(.caption).padding(8).background(Color.blue.opacity(0.06)).disabled(!model.canControl(id))
            }
            if let conflict = service.draftConflicts[id] {
                Text(conflict).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.15))
            }
            if let record = model.pending(id) {
                HStack {
                    Text("Send: " + record.outcome).font(.caption); Spacer()
                    if record.outcome == "uncertain" { Button("Check home") { service.queryOutbox(record) } }
                    if record.outcome == "failed" || record.outcome == "rejected" { Button("Restore") { model.discard(record, restore: true) } }
                    if ["pending", "accepted", "running"].contains(record.outcome) { Button("Check home") { service.queryOutbox(record) } }
                    else { Button("Discard") { model.discard(record, restore: false) } }
                }.padding(8).background(Color.orange.opacity(0.12))
            }
            if let snapshot, snapshot.offset > 0 { Button("Load \(snapshot.offset) earlier messages") { service.requestEarlier(globalID: id) }.font(.caption).padding(4) }
            PadTranscript(messages: snapshot?.messages ?? [], draft: model.draft(id).text, images: service.blobCache, draftImageHashes: model.draft(id).hashes, editable: model.canControl(id), lineNumbers: model.lineNumbers,
                          edit: { model.edit(id, text: $0) }, send: { model.send(id) }, attach: { model.attach(id, data: $0) }, removeImage: { model.removeImage(id, hash: $0) })
            Divider()
            if let status = snapshot?.agentWidget?.loopStatus { Text(status).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(6) }
            if let snapshot {
                ViewThatFits(in: .horizontal) {
                    HStack { settings(snapshot); Spacer(); Text(snapshot.status).font(.caption).foregroundStyle(.secondary) }
                    settings(snapshot)
                }.padding(.horizontal, 8).padding(.vertical, 4)
            }
            if !model.draft(id).hashes.isEmpty {
                Text(model.draft(id).hashes.allSatisfy { service.blobReady[$0] == true } ? "Images stored on home." : "Uploading images; Send waits for home storage.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            if service.lastOutcome.hasPrefix("failed") || service.lastOutcome.hasPrefix("Attachment failed") {
                Text(service.lastOutcome).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(8)
            }
            HStack {
                PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo") }.accessibilityLabel("Attach photo")
                Button { importing = true } label: { Image(systemName: "paperclip") }.accessibilityLabel("Attach image file")
                if !model.draft(id).hashes.isEmpty {
                    Text("\(model.draft(id).hashes.count) images").font(.caption)
                    Button("Clear images") { model.clearImages(id) }.font(.caption)
                }
                Spacer()
                if snapshot?.busy == true { Button("Stop") { command("stop") } }
                Button(snapshot?.busy == true ? "Queue" : "Send") { model.send(id) }.buttonStyle(.borderedProminent).disabled(!model.canSend(id))
            }.padding(8).disabled(!model.canControl(id))
        }.background(Color(uiColor: .systemBackground)).frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: photo) { _, value in
                Task {
                    do { if let bytes = try await value?.loadTransferable(type: Data.self) { model.attach(id, data: bytes) } }
                    catch { model.error = error.localizedDescription }
                    photo = nil
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 50_000_000 else { throw CocoaError(.fileReadTooLarge) }
                    model.attach(id, data: try Data(contentsOf: url))
                } catch { model.error = error.localizedDescription }
            }
    }
    func command(_ action: String) { service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: action)) }
    func settings(_ snapshot: DeviceTranscriptPayload) -> some View {
        HStack(spacing: 8) {
            Menu(snapshot.model.isEmpty ? "Model" : snapshot.model) {
                ForEach(snapshot.modelOptions) { choice in Button(choice.label) { service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "model", model: choice.id, modelProvider: choice.provider, modelProfile: choice.profile)) } }
            }
            Menu(snapshot.effort.isEmpty ? "Effort" : snapshot.effort) { ForEach(snapshot.effortOptions, id: \.self) { value in Button(value) { service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "effort", effort: value)) } } }
            Menu(snapshot.access.isEmpty ? "Access" : snapshot.access) { ForEach(snapshot.accessOptions) { value in Button(value.label) { service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "access", access: value.id)) } } }
        }.font(.caption).disabled(!model.canControl(id))
    }
}


enum PadLayout {
    static func sidebarWidth(preferred: Double, available: CGFloat) -> CGFloat {
        min(max(0, available) * 0.5, max(120, preferred))
    }
}

private struct PadProviderLogo: View {
    let engine: String
    var body: some View {
        let key = engine.lowercased()
        let provider = ["muse": "meta", "claude": "anthropic", "codex": "openai"][key] ?? key
        let label = ["muse": "Meta", "claude": "Anthropic", "codex": "OpenAI"][key] ?? engine.capitalized
        let color: Color = key == "muse" ? Color(red: 4/255, green: 103/255, blue: 223/255) : key == "claude" ? Color(red: 217/255, green: 119/255, blue: 87/255) : .primary
        if !engine.isEmpty {
            Group {
                if let url = Bundle.main.url(forResource: provider, withExtension: "png", subdirectory: "ProviderLogos"), let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).renderingMode(.template).resizable().scaledToFit()
                } else {
                    Text(String(label.prefix(1))).font(.system(size: 14, weight: .bold))
                }
            }.frame(width: 20, height: 20).foregroundStyle(color).accessibilityLabel(label)
        }
    }
}
