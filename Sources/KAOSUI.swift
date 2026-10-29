import AppKit
import SwiftUI

@MainActor final class KAOSModel: ObservableObject {
    let client: KAOSClient
    let conversation = Session(entry: Entry(name: "KAOS", command: "", directory: "", engine: "kaos"))
    @Published var connection = "Not connected · local Muse bridge"
    @Published var connected = false
    @Published var connecting = false
    @Published var context = ""
    @Published var asking = false
    @Published var scenario = false
    @Published var input = ""
    @Published var actionBusy = false
    @Published var prepared: KAOSPrepared?
    @Published var outcome = ""
    @Published var jobID = ""
    @Published var jobState = ""
    @Published var jobDetails = ""
    @Published var watching = false
    @Published var jollyMessage = ""
    @Published var jollyBusy = false
    @Published var jollyOutcome = ""
    private var askTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var watchGeneration = UUID()
    var outbox: (String) async throws -> String = { text in try await Task.detached { try JollyOutbox.send(text) }.value }
    init(client: KAOSClient? = nil) { self.client = client ?? KAOSClient(); conversation.title = "Ask KAOS" }
    func connect() async {
        guard !connecting, !asking, !actionBusy else { return }
        connecting = true; connected = false; defer { connecting = false }
        do { connection = try await client.connect(); connected = true; if input.isEmpty { resetInput() } }
        catch { connection = error.localizedDescription }
    }
    func resetInput() {
        guard prepared == nil, !actionBusy, let schema = client.schema else { return }
        do {
            let example = schema.example(try schema.body(scenario ? "/v1/scenario/propose" : "/v1/jobs/prepare"))
            input = String(decoding: try JSONSerialization.data(withJSONObject: example, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        } catch { outcome = error.localizedDescription }
    }
    var schemaDescription: String {
        guard let schema = client.schema, let body = try? schema.body(scenario ? "/v1/scenario/propose" : "/v1/jobs/prepare") else { return "Connect to load the bridge’s live request schema." }
        return KAOSClient.displayJSON(body)
    }
    func ask() {
        guard connected, !asking, !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let question = conversation.draft, context = self.context
        conversation.messages.append(Message(role: "user", text: question)); conversation.draft = ""
        let response = Message(role: "assistant", text: "")
        conversation.messages.append(response); conversation.busy = true; asking = true
        askTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { asking = false; conversation.busy = false; askTask = nil }
            do {
                let json = try await client.ask(question, context: context)
                try Task.checkCancellation()
                let answer = json["answer"] as? String ?? ""
                if let index = conversation.messages.firstIndex(where: { $0.id == response.id }) {
                    conversation.messages[index].text = answer + "\n\n[" + KAOSClient.lane(json) + " · read-only · " + (json["innerModel"] as? String ?? "KAOS") + "]"
                }
                for image in (json["images"] as? [[String: Any]] ?? []).prefix(8) {
                    try Task.checkCancellation()
                    guard let link = image["url"] as? String, let url = URL(string: link) else { continue }
                    do {
                        let bytes = try await client.image(url)
                        try Task.checkCancellation()
                        let folder = Store.shared.responseImageFolder(conversation)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        let file = folder.appendingPathComponent("KAOS-" + DeviceBlob.sha256Hex(bytes) + ".png")
                        try bytes.write(to: file, options: .atomic)
                        if let index = conversation.messages.firstIndex(where: { $0.id == response.id }) { conversation.messages[index].images.append(file.path) }
                    } catch is CancellationError { throw CancellationError() }
                    catch { conversation.messages.append(Message(role: "notice", text: "Image unavailable or expired. " + url.absoluteString)) }
                }
            } catch {
                if let index = conversation.messages.firstIndex(where: { $0.id == response.id }), conversation.messages[index].text.isEmpty {
                    conversation.messages[index].text = Task.isCancelled ? "Stopped waiting. The read-only ask may still be running on KAOS; a new ask may report Lane busy." : error.localizedDescription
                }
            }
        }
    }
    func stopWaiting() { askTask?.cancel() }
    func prepare() async {
        guard connected, !actionBusy, prepared == nil else { return }
        actionBusy = true; defer { actionBusy = false }
        do {
            guard let data = input.data(using: .utf8), let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw KAOSFailure(message: "Enter a JSON object matching the live schema.") }
            prepared = try await client.prepare(scenario: scenario, body: body)
            outcome = "Prepared only. Review the exact summary before approving."
        } catch { outcome = (error is KAOSFailure) ? error.localizedDescription : "Invalid JSON. Check the live schema." }
    }
    // Only the explicit Approve button invokes this. Consume the in-memory
    // proposal before awaiting, so duplicate clicks cannot confirm it twice.
    func approve(id: String) async {
        guard !actionBusy, let proposal = prepared, proposal.id == id else { return }
        prepared = nil; actionBusy = true; defer { actionBusy = false }
        if proposal.kind == .job { jobID = proposal.id; jobState = "Confirmation pending" }
        do {
            let json = try await client.confirm(proposal)
            outcome = proposal.kind == .job ? "Run accepted by KAOS." : "Scenario changes applied."
            if proposal.kind == .job { watchJob() } else { outcome += "\n" + KAOSClient.displayJSON(json) }
        } catch {
            outcome = error.localizedDescription + "\nApproval was not repeated."
            if proposal.kind == .job { jobState = "Confirmation unconfirmed — check status" }
            else { outcome += " Check the scenario in KAOS before preparing these edits again." }
        }
    }
    func discard() async {
        guard !actionBusy, let proposal = prepared else { return }
        prepared = nil
        if proposal.kind == .job {
            actionBusy = true; defer { actionBusy = false }
            do { _ = try await client.job(proposal.id, cancel: true); outcome = "Prepared job cancelled." }
            catch { outcome = error.localizedDescription + " No run was approved." }
        } else { outcome = "Proposal dismissed without applying it." }
    }
    func watchJob() {
        guard KAOSClient.validID(jobID) else { return }
        watchTask?.cancel(); let id = jobID; let generation = UUID(); watchGeneration = generation; watching = true
        watchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if watchGeneration == generation { watching = false } }
            do {
                while !Task.isCancelled && jobID == id {
                    let json = try await client.job(id)
                    try Task.checkCancellation()
                    let job = json["job"] as? [String: Any] ?? [:]
                    jobState = job["state"] as? String ?? "Unknown"
                    jobDetails = KAOSClient.displayJSON(json)
                    guard ["running", "prepared"].contains(jobState) else { break }
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            } catch { if !Task.isCancelled { jobState = "Status unavailable. Check status to resume watching." } }
        }
    }
    func stopWatching() { watchGeneration = UUID(); watchTask?.cancel(); watching = false } // Never cancels the server's job.
    func cancelJob() async {
        guard !actionBusy, KAOSClient.validID(jobID) else { return }
        let id = jobID; stopWatching(); actionBusy = true; defer { actionBusy = false }
        do { let json = try await client.job(id, cancel: true); jobState = json["state"] as? String ?? "Cancel requested"; jobDetails = KAOSClient.displayJSON(json) }
        catch { outcome = error.localizedDescription + " Cancellation was not confirmed. Check status." }
    }
    func leaveForJolly() async {
        guard !jollyBusy else { return }
        let text = jollyMessage
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.unicodeScalars.count <= 500 else { jollyOutcome = "Enter a message of at most 500 characters."; return }
        jollyBusy = true; defer { jollyBusy = false }
        do { jollyOutcome = try await outbox(text); if jollyMessage == text { jollyMessage = "" } }
        catch { jollyOutcome = error.localizedDescription }
    }
}

@MainActor final class KAOSWindowController: NSObject, NSWindowDelegate {
    let model = KAOSModel()
    private var window: NSWindow?
    func windowWillClose(_ notification: Notification) { model.stopWatching() }
    func show() {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "Jolly / KAOS"; created.isReleasedWhenClosed = false; created.delegate = self
            created.contentMinSize = NSSize(width: 650, height: 520)
            created.contentView = NSHostingView(rootView: KAOSView(model: model)); created.setFrameAutosaveName("ConverseKAOS"); created.center(); window = created
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

struct KAOSView: View {
    @ObservedObject var model: KAOSModel
    @State private var section = 0
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading) { Text(model.connection).textSelection(.enabled); Text("127.0.0.1:4691 · authenticated local bridge").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(model.connecting ? "Connecting…" : "Refresh connection") { Task { await model.connect() } }.disabled(model.connecting || model.asking || model.actionBusy)
            }.padding([.horizontal, .top], 12)
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Array(["Ask KAOS", "Runs & scenario", "Jolly outbox"].enumerated()), id: \.offset) { index, title in
                        Button { section = index } label: {
                            Text(title).font(.system(size: 13, weight: section == index ? .semibold : .regular)).padding(.horizontal, 14).padding(.vertical, 7)
                                .background(section == index ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).accessibilityAddTraits(section == index ? .isSelected : [])
                    }
                    Spacer()
                }.padding(.horizontal, 12)
                Divider()
                if section == 0 { VStack(spacing: 6) {
                    DisclosureGroup("Optional context — only this text and your question are sent") { TextEditor(text: $model.context).font(.body).frame(height: 80).border(Color.secondary.opacity(0.25)) }.padding(.horizontal, 12)
                    ScrollingConversation(session: model.conversation, inputEnabled: model.connected,
                                          onSubmit: { model.ask() }, onDraftChanged: { _ in }, onImagePaste: { _ in }, onImageRemove: { _ in })
                    HStack { Text(model.asking ? "Waiting for KAOS · answers can take several minutes" : "Read-only · Return asks · ⌘Return inserts a newline").font(.caption); Spacer(); if model.asking { ProgressView().controlSize(.small); Button("Stop waiting") { model.stopWaiting() } }; Button("Ask") { model.ask() }.disabled(!model.connected || model.asking) }.padding(10)
                } }
                if section == 1 { actions }
                if section == 2 { VStack(alignment: .leading, spacing: 12) {
                    Text("Leave a message for Jolly").font(.headline)
                    Text("Jolly reads the shared KAOS outbox when you say ‘check KAOS’ in the Muse phone app. This sends no push notification. Converse does not read or poll Jolly’s inbox.")
                    TextEditor(text: $model.jollyMessage).font(.body).frame(minHeight: 100, maxHeight: 200).border(Color.secondary.opacity(0.25))
                    HStack { Text("\(model.jollyMessage.unicodeScalars.count)/500 characters").font(.caption); Spacer(); Button(model.jollyBusy ? "Leaving message…" : "Leave for Jolly") { Task { await model.leaveForJolly() } }.disabled(model.jollyBusy || model.jollyMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.jollyMessage.unicodeScalars.count > 500) }
                    Text(model.jollyOutcome).textSelection(.enabled); Spacer()
                }.padding(16) }
            }
        }.background(Color(nsColor: .windowBackgroundColor)).task { if !model.connected { await model.connect() } }.onDisappear { model.stopWatching() }
    }
    private var actions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Operation", selection: $model.scenario) { Text("Run a World").tag(false); Text("Edit scenario").tag(true) }.pickerStyle(.segmented).disabled(model.actionBusy || model.prepared != nil).onChange(of: model.scenario) { _, _ in model.resetInput() }
                if let proposal = model.prepared {
                    Text("Review before approving · " + proposal.lane).font(.headline)
                    Text(proposal.summary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.yellow.opacity(0.2))
                    HStack { Button("Dismiss without executing") { Task { await model.discard() } }; Spacer(); Button(proposal.kind == .job ? "Approve & Run" : "Approve & Apply") { Task { await model.approve(id: proposal.id) } } }.disabled(model.actionBusy)
                } else {
                    Text("Prepare a request using the bridge’s live schema. Nothing runs or changes until you approve its exact summary.").font(.caption)
                    TextEditor(text: $model.input).font(.system(.body, design: .monospaced)).frame(height: 150).border(Color.secondary.opacity(0.25)).disabled(model.actionBusy)
                    DisclosureGroup("Live request schema") { Text(model.schemaDescription).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack { Button("Reset example") { model.resetInput() }; Spacer(); Button(model.scenario ? "Propose edits" : "Prepare run") { Task { await model.prepare() } } }.disabled(!model.connected || model.actionBusy)
                }
                if model.actionBusy { ProgressView().controlSize(.small) }
                Text(model.outcome).textSelection(.enabled)
                Divider()
                HStack { TextField("Job ID (saved from your prepared run)", text: $model.jobID).disabled(model.watching || model.actionBusy); Button("Check status") { model.watchJob() }.disabled(!model.connected || model.actionBusy || !KAOSClient.validID(model.jobID)); Button("Stop watching") { model.stopWatching() }.disabled(!model.watching); Button("Cancel job") { Task { await model.cancelJob() } }.disabled(!model.connected || model.actionBusy || !KAOSClient.validID(model.jobID)) }
                Text(model.jobState).font(.headline)
                Text(model.jobDetails).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Text("Closing this window stops watching. It does not cancel a running KAOS job.").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
    }
}
