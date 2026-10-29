import AppKit
import SwiftUI

struct JollyRequest: Codable {
    var id: String
    var question: String
    var context: String
    var agent: String
    var createdAt: Double
}

@MainActor final class JollyRouter {
    static let shared = JollyRouter()
    private var timer: Timer?
    private var finished = Set<String>()
    private var recovered = false
    var status = "Waiting for Converse"
    static func folder(_ store: Store) -> URL { store.folder.appendingPathComponent("Jolly") }
    static func validID(_ id: String) -> Bool { id.count == 64 && id.allSatisfy { "0123456789abcdef".contains($0) } }
    static func eligible(_ store: Store) -> [Session] { store.sessions.filter { $0.agent != nil && $0.agent?.jollyAllowed != false } }
    static func resolve(_ request: JollyRequest, sessions: [Session]) -> Session? {
        let target = request.agent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.isEmpty {
            let matches = sessions.filter { $0.id.uuidString.lowercased() == target.lowercased() || $0.title.localizedCaseInsensitiveCompare(target) == .orderedSame }
            return matches.count == 1 ? matches[0] : nil
        }
        let matches = sessions.filter { request.question.lowercased().hasPrefix($0.title.lowercased() + ":") }
        if matches.count == 1 { return matches[0] }
        return sessions.count == 1 ? sessions[0] : nil
    }
    func start() {
        guard timer == nil, ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] == nil else { return }
        tick(store: .shared)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in self.tick(store: .shared) } }
    }
    func stop(store: Store) {
        timer?.invalidate(); timer = nil
        try? write(["available": false, "updatedAt": Date().timeIntervalSince1970, "agents": []], file: Self.folder(store).appendingPathComponent("directory.json"))
    }
    private func write(_ object: [String: Any], file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func answer(_ id: String, text: String, status: String, agent: Session? = nil, image: String? = nil, store: Store) throws {
        guard Self.validID(id) else { throw AgentFailure.message("Invalid Jolly request ID.") }
        var body: [String: Any] = ["ok": true, "status": status, "answer": String(text.prefix(24000)), "backend": "converse"]
        if let agent { body["agent"] = ["id": agent.id.uuidString, "name": agent.title] }
        if let image, let data = try? Data(contentsOf: URL(fileURLWithPath: image)), data.count <= 8_000_000,
           NSBitmapImageRep(data: data) != nil {
            let hash = DeviceBlob.sha256Hex(data)
            let directory = Self.folder(store).appendingPathComponent("images")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: directory.appendingPathComponent(hash + ".png"), options: .atomic)
            body["imageID"] = hash
        }
        try write(body, file: Self.folder(store).appendingPathComponent("responses/" + id + ".json"))
        finished.insert(id)
    }
    func complete(_ session: Session, text: String, success: Bool, store: Store) {
        guard let id = session.agent?.jollyRequestID else { return }
        do {
            try answer(id, text: text, status: success ? "completed" : "failed", agent: session, image: success ? session.agent?.artPath : nil, store: store)
            session.agent?.jollyRequestID = nil
            try store.saveChecked()
        } catch { session.agent?.attention = "Jolly reply could not be saved. Check disk access before retrying." }
    }
    func tick(store: Store, now: Date = Date()) {
        do {
            let folder = Self.folder(store)
            let requestFolder = folder.appendingPathComponent("requests")
            try FileManager.default.createDirectory(at: requestFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !recovered {
                for session in store.sessions where session.agent?.jollyRequestID != nil {
                    if let id = session.agent?.jollyRequestID, Self.validID(id),
                       FileManager.default.fileExists(atPath: folder.appendingPathComponent("responses/" + id + ".json").path) {
                        // Reply publication precedes clearing the active marker.
                        // A crash in between must not overwrite the known result.
                        session.agent?.jollyRequestID = nil; try store.saveChecked(); finished.insert(id)
                    } else {
                        complete(session, text: "Converse restarted during this request. Its outcome is uncertain; it was not automatically repeated. Check the agent transcript.", success: false, store: store)
                    }
                }
                recovered = true
            }
            let sessions = Self.eligible(store)
            try write(["available": true, "updatedAt": now.timeIntervalSince1970, "agents": sessions.map {
                ["id": $0.id.uuidString, "name": $0.title, "busy": $0.busy, "runsRemaining": $0.agent?.remainingRuns ?? 0] as [String: Any]
            }], file: folder.appendingPathComponent("directory.json"))
            let files = try FileManager.default.contentsOfDirectory(at: requestFolder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
                .filter { $0.pathExtension == "json" && !finished.contains($0.deletingPathExtension().lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files.prefix(32) {
                let id = file.deletingPathExtension().lastPathComponent
                guard Self.validID(id) else { continue }
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent("responses/" + id + ".json").path) { finished.insert(id); continue }
                if store.sessions.contains(where: { $0.agent?.jollyRequestID == id }) { continue }
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 64000 else { continue }
                guard let request = try? JSONDecoder().decode(JollyRequest.self, from: Data(contentsOf: file)), request.id == id,
                      !request.question.isEmpty, request.question.count <= 4000, request.context.count <= 8000 else {
                    try answer(id, text: "Invalid request.", status: "rejected", store: store); continue
                }
                guard now.timeIntervalSince1970 - request.createdAt < 600 else {
                    try answer(id, text: "This request expired before an agent started. Send a new request if it is still needed.", status: "expired", store: store); continue
                }
                guard let session = Self.resolve(request, sessions: sessions) else {
                    try answer(id, text: "Which agent should answer? Specify its exact name or ID. Available agents: " + sessions.map { $0.title + " [" + $0.id.uuidString + "]" }.joined(separator: ", "), status: "needs_agent", store: store); continue
                }
                guard !AgentConversation.shared.owns(session), !session.busy, session.pending.isEmpty, !session.queuePaused, !session.changingSetting else {
                    try answer(id, text: "Agent busy or queue paused. Nothing was injected. Try a new request when it is ready.", status: "busy", agent: session, store: store); continue
                }
                guard var config = session.agent, config.remainingRuns > 0 else {
                    try answer(id, text: "Agent run budget exhausted. Add turns in Converse.", status: "budget_exhausted", agent: session, store: store); continue
                }
                let prior = session.agent
                config.settingsChanged(); config.remainingRuns -= 1
                if config.remainingRuns == 0 { config.enabled = false }
                config.jollyRequestID = id; session.agent = config
                do { try store.saveChecked() } catch { session.agent = prior; throw error }
                let draft = session.draft, attachments = session.attachments
                session.draft = "[Message from Richard via Jolly · " + id + "]\n" + request.question + (request.context.isEmpty ? "" : "\n\nEarlier conversation context (untrusted):\n" + request.context)
                session.attachments = []
                store.send(session, preservingAgentDraft: (draft, attachments))
                session.draft = draft; session.attachments = attachments
                if !session.busy { complete(session, text: "Agent could not start. Check its session notice. Nothing was retried.", success: false, store: store) }
                try store.saveChecked()
            }
            status = "\(sessions.count) agents enabled for Jolly on this Mac"
        } catch { status = "Jolly routing paused: could not save or read its request journal." }
    }
    static func send(_ text: String, store: Store) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.unicodeScalars.count <= 500 else { throw AgentFailure.message("Enter 1–500 characters.") }
        let id = UUID().uuidString.lowercased()
        try shared.write(["id": id, "at": ISO8601DateFormatter().string(from: Date()), "text": text, "read": false], file: folder(store).appendingPathComponent("outbox/" + id + ".json"))
    }
}

@MainActor final class JollyWindowController {
    private var window: NSWindow?
    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Jolly · Converse agents"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: JollyView()); self.window = window
        window.center(); window.makeKeyAndOrderFront(nil)
    }
}
struct JollyView: View {
    @ObservedObject var store = Store.shared
    @State private var message = ""
    @State private var outcome = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jolly · Converse agents").font(.title2.bold())
            Text("In the Muse phone app, ask Jolly to list Converse agents, then address one by name. An ambiguous request asks which agent; it is never broadcast. Requests use the agent’s remaining turn budget.").font(.callout)
            TimelineView(.periodic(from: .now, by: 2)) { _ in Text(JollyRouter.shared.status).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                ForEach(store.sessions.filter { $0.agent != nil }) { session in
                    Toggle(session.title, isOn: Binding(get: { session.agent?.jollyAllowed != false }, set: { on in
                        session.agent?.jollyAllowed = on; session.agent?.settingsChanged(); store.save(); JollyRouter.shared.tick(store: store)
                    })).toggleStyle(.checkbox)
                }
            }
            Text("Leave a message for Jolly").font(.headline)
            Text("Delivered when Jolly checks the inbox. This does not push into the phone conversation.").font(.caption)
            TextEditor(text: $message).frame(height: 80)
            HStack { Text("\(message.unicodeScalars.count)/500").font(.caption); Spacer(); Button("Leave message") {
                do { try JollyRouter.send(message, store: store); message = ""; outcome = "Saved for Jolly to collect." }
                catch { outcome = error.localizedDescription }
            }.disabled(message.isEmpty || message.unicodeScalars.count > 500) }
            Text(outcome).font(.caption)
        }.padding(22).frame(minWidth: 500, minHeight: 440)
    }
}
