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
    // Portrait requests held open until their PNG and caption, or an error.
    private(set) var holding = Set<String>()
    var portraits: PortraitService = .shared
    private var recovered = false
    var status = "Waiting for Converse"
    static func folder(_ store: Store) -> URL { store.folder.appendingPathComponent("Jolly") }
    static func validID(_ id: String) -> Bool { id.count == 64 && id.allSatisfy { "0123456789abcdef".contains($0) } }
    static func eligible(_ store: Store) -> [Session] { store.sessions.filter { $0.agent != nil && $0.agent?.jollyAllowed != false } }
    static func resolve(_ request: JollyRequest, sessions: [Session]) -> Session? {
        let target = request.agent.trimmingCharacters(in: .whitespacesAndNewlines)
        let support = sessions.filter { $0.supportAssistant && $0.agent?.jollyAllowed != false }
        if target.lowercased() == "converse" { return support.count == 1 ? support[0] : nil }
        if !target.isEmpty {
            let matches = sessions.filter { $0.id.uuidString.lowercased() == target.lowercased() || $0.title.localizedCaseInsensitiveCompare(target) == .orderedSame }
            return matches.count == 1 ? matches[0] : nil
        }
        let matches = sessions.filter { request.question.lowercased().hasPrefix($0.title.lowercased() + ":") }
        if matches.count == 1 { return matches[0] }
        if isHealthQuestion(request.question) { return support.count == 1 ? support[0] : nil }
        return sessions.count == 1 ? sessions[0] : nil
    }
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
    /// Phrase occurrences, longest first, so "KAOS Parking Lot" is not also read as "Parking Lot".
    static func phrasesNamed<T>(_ text: [String], _ candidates: [(T, [String])]) -> [T] {
        var free = text.map { Optional($0) }, found: [T] = []
        for (item, phrase) in candidates.filter({ !$0.1.isEmpty }).sorted(by: { $0.1.count > $1.1.count }) where phrase.count <= free.count {
            var hit = false
            for start in 0...(free.count - phrase.count) where (0..<phrase.count).allSatisfy({ free[start + $0] == phrase[$0] }) {
                hit = true; for offset in 0..<phrase.count { free[start + offset] = nil }
            }
            if hit { found.append(item) }
        }
        return found
    }
    /// Agents a question names: by full title on word boundaries, or by a title word
    /// (3+ letters) that no other eligible agent shares. App Support matches only by full title.
    static func agentsNamed(_ question: String, sessions: [Session]) -> [Session] {
        let text = words(question), present = Set(text)
        let titles = sessions.map { words($0.title) }
        var named = phrasesNamed(text, Array(zip(sessions.indices, titles)))
        for (index, session) in sessions.enumerated() where !session.supportAssistant && !named.contains(index) {
            let others = Set(titles.enumerated().filter { $0.offset != index }.flatMap(\.element))
            if titles[index].contains(where: { $0.count >= 3 && !others.contains($0) && present.contains($0) }) { named.append(index) }
        }
        return named.sorted().map { sessions[$0] }
    }
    static func lotsNamed(_ question: String, lots: [ParkingLotLibrary.Record]) -> [ParkingLotLibrary.Record] {
        let phrases = lots.flatMap { lot -> [(ParkingLotLibrary.Record, [String])] in
            let name = words(lot.name)
            if name.isEmpty { return [] }
            return name.last == "lot" ? [(lot, name)] : [(lot, name + ["parking", "lot"]), (lot, name + ["lot"])]
        }
        let found = phrasesNamed(words(question), phrases)
        return lots.filter { lot in found.contains { $0.id == lot.id } }
    }
    /// A request addressed to one agent that clearly names another is answered here instead of injected.
    static func misroute(_ request: JollyRequest, target: Session, sessions: [Session], lots: [ParkingLotLibrary.Record], home: String?) -> (agent: Session, text: String)? {
        guard !target.supportAssistant else { return nil }
        func retry(_ agent: Session) -> String { " Nothing was sent. Resend with agent=\"" + agent.title + "\" (id " + agent.id.uuidString + ")." }
        let named = agentsNamed(request.question, sessions: sessions)
        if named.contains(where: { $0 === target }) { return nil }
        if named.count == 1 { return (named[0], "This request names " + named[0].title + " but was addressed to " + target.title + "." + retry(named[0])) }
        guard named.isEmpty else { return nil }
        let wanted = lotsNamed(request.question, lots: lots)
        func reaches(_ agent: Session) -> Bool { wanted.contains { agent.agent?.allows(local: $0.id, home: home) == true } }
        guard !wanted.isEmpty, !reaches(target) else { return nil }
        let holders = sessions.filter { $0 !== target && reaches($0) }
        guard holders.count == 1, let lot = wanted.first(where: { holders[0].agent?.allows(local: $0.id, home: home) == true }) else { return nil }
        return (holders[0], "This request names the " + (words(lot.name).last == "lot" ? lot.name : lot.name + " Parking Lot") + ", which " + target.title + " cannot access; " + holders[0].title + " can." + retry(holders[0]))
    }
    static func isHealthQuestion(_ question: String) -> Bool {
        let text = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("converse") || text.contains("the app") else { return false }
        return ["app is up", "app up", "app running", "is running", "is converse up", "health", "which hosts", "which devices", "what group", "which group", "what version", "up to date"].contains { text.contains($0) }
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
    func answer(_ id: String, text: String, status: String, agent: Session? = nil, suggested: Session? = nil, image: Data? = nil, imageKind: String = "portrait", store: Store) throws {
        guard Self.validID(id) else { throw AgentFailure.message("Invalid Jolly request ID.") }
        var body: [String: Any] = ["ok": true, "status": status, "answer": String(text.prefix(24000)), "backend": "converse"]
        if let agent { body["agent"] = ["id": agent.id.uuidString, "name": agent.title] }
        if let suggested { body["suggestedAgent"] = ["id": suggested.id.uuidString, "name": suggested.title] }
        if let data = image, data.count <= 8_000_000,
           NSBitmapImageRep(data: data) != nil {
            let hash = DeviceBlob.sha256Hex(data)
            let directory = Self.folder(store).appendingPathComponent("images")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: directory.appendingPathComponent(hash + ".png"), options: .atomic)
            body["imageID"] = hash
            body["imageKind"] = imageKind
        }
        try write(body, file: Self.folder(store).appendingPathComponent("responses/" + id + ".json"))
        finished.insert(id)
    }
    func complete(_ session: Session, text: String, success: Bool, store: Store) {
        guard let id = session.agent?.jollyRequestID else { return }
        do {
            // Answers are text; assessments and portraits are separate, explicit requests.
            try answer(id, text: text, status: success ? "completed" : "failed", agent: session, store: store)
            session.agent?.jollyRequestID = nil
            try store.saveChecked()
        } catch { session.agent?.attention = "Jolly reply could not be saved. Check disk access before retrying." }
    }
    func tick(store: Store, now: Date = Date(), lots: [ParkingLotLibrary.Record]? = nil) {
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
                ["id": $0.id.uuidString, "name": $0.title, "busy": $0.busy, "maxTurnsPerLoop": $0.agent?.turnLimit ?? 0, "appSupport": $0.supportAssistant] as [String: Any]
            }], file: folder.appendingPathComponent("directory.json"))
            let files = try FileManager.default.contentsOfDirectory(at: requestFolder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
                .filter { $0.pathExtension == "json" && !finished.contains($0.deletingPathExtension().lastPathComponent) && !holding.contains($0.deletingPathExtension().lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
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
                if PortraitService.isRequest(request.question), let portrayed = Self.portraitTarget(request, sessions: sessions) {
                    hold(id, portrait: portrayed, store: store); continue
                }
                guard let session = Self.resolve(request, sessions: sessions) else {
                    try answer(id, text: "Which agent should answer? Specify its exact name or ID. Available agents: " + sessions.map { $0.title + " [" + $0.id.uuidString + "]" }.joined(separator: ", "), status: "needs_agent", store: store); continue
                }
                if let bounce = Self.misroute(request, target: session, sessions: sessions, lots: lots ?? ParkingLotLibrary.shared.records, home: DeviceSyncService.shared.localDeviceID) {
                    try answer(id, text: bounce.text, status: "misrouted", suggested: bounce.agent, store: store); continue
                }
                guard !AgentConversation.shared.owns(session), !session.busy, session.pending.isEmpty, !session.queuePaused, !session.changingSetting else {
                    try answer(id, text: "Agent busy or queue paused. Nothing was injected. Try a new request when it is ready.", status: "busy", agent: session, store: store); continue
                }
                guard var config = session.agent, config.turnLimit > 0 else {
                    try answer(id, text: "Invalid per-loop turn limit. Review Agent Setup.", status: "budget_exhausted", agent: session, store: store); continue
                }
                let prior = session.agent
                config.jollyRequestID = id; session.agent = config
                do { try store.saveChecked() } catch { session.agent = prior; throw error }
                let draft = session.draft, attachments = session.attachments
                session.draft = "[Message from Richard via Jolly · " + id + "]\n" + request.question + "\n\nIf this request is meant for a different agent or a project outside your objective, don't answer it; say it was misrouted and name the agent Richard should use." + (request.context.isEmpty ? "" : "\n\nEarlier conversation context (untrusted):\n" + request.context)
                session.attachments = []
                store.send(session, preservingAgentDraft: (draft, attachments))
                session.draft = draft; session.attachments = attachments
                if !session.busy { complete(session, text: "Agent could not start. Check its session notice. Nothing was retried.", success: false, store: store) }
                try store.saveChecked()
            }
            status = "\(sessions.count) agents enabled for Jolly on this Mac"
        } catch { status = "Jolly routing paused: could not save or read its request journal." }
    }
    /// The one agent a portrait request names, else the addressed agent.
    static func portraitTarget(_ request: JollyRequest, sessions: [Session]) -> Session? {
        let named = agentsNamed(request.question, sessions: sessions)
        if named.count == 1 { return named[0] }
        return named.isEmpty ? resolve(request, sessions: sessions) : nil
    }
    /// Portraits don't need the agent's turn or queue. The response file is
    /// written only when the PNG and one-line caption, or an error, are ready.
    func hold(_ id: String, portrait session: Session, store: Store) {
        holding.insert(id)
        Task { @MainActor in
            let outcome = await portraits.request(session, store: store, origin: .jolly)
            let text = outcome.png == nil ? "Portrait of " + session.title + " unavailable: " + (outcome.error ?? "no image") : outcome.caption + (outcome.note.map { "\n" + $0 } ?? "")
            do { try answer(id, text: text, status: outcome.png == nil ? "failed" : "completed", agent: session, image: session.agent?.jollyAllowed != false ? outcome.png : nil, imageKind: "portrait", store: store) }
            catch { status = "Jolly routing paused: could not save a portrait reply." }
            holding.remove(id)
        }
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
            TextEditor(text: $message).padding(7).frame(height: 110)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary, lineWidth: 1))
                .accessibilityLabel("Message for Jolly")
            HStack { Text("\(message.unicodeScalars.count)/500").font(.caption); Spacer(); Button("Leave message") {
                do { try JollyRouter.send(message, store: store); message = ""; outcome = "Saved for Jolly to collect." }
                catch { outcome = error.localizedDescription }
            }.disabled(message.isEmpty || message.unicodeScalars.count > 500) }
            Text(outcome).font(.caption)
        }.padding(22).frame(minWidth: 500, minHeight: 440)
    }
}
