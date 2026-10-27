import AppKit
import SwiftUI
import WebKit
import Combine

struct Entry: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    var directory: String
    var engine: String
    var accountID: String? = nil
    var accountName: String? = nil
    var accountDirectory: String? = nil
}
struct DelayMark: Codable { var offset: Int; var seconds: Double }
struct Message: Codable, Identifiable {
    var id = UUID()
    var role: String
    var text: String
    var images: [String] = []
    var delays: [DelayMark]? = nil
}
struct ToolStatus: Codable {
    var model = "not reported"
    var effort = "CLI default"
    var access = "CLI default"
    var usage = "not reported"
    var totalUsage: String? = nil
    var quota: String? = nil
    var account: String? = nil
    var accountObservedAt: Date? = nil
}
struct SavedSession: Codable {
    var id: UUID
    var entry: Entry
    var title: String
    var messages: [Message]
    var draft: String
    var attachments: [String]
    var remoteID: String?
    var started: Bool
    var toolStatus: ToolStatus? = nil
    var choices: SessionChoices? = nil
    var pending: [PendingPrompt]? = nil
    var switchboardEnabled: Bool? = nil
    var switchboardHandled: [UUID]? = nil
}
final class Session: ObservableObject, Identifiable {
    let id: UUID
    @Published var entry: Entry
    @Published var title: String
    @Published var messages: [Message]
    @Published var draft: String
    @Published var attachments: [String]
    @Published var pending: [PendingPrompt] = []
    @Published var queuePaused = false
    @Published var switchboardEnabled = false
    var switchboardHandled: [UUID] = []
    var switchboardTurnStart: Int?
    var switchboardHop = 0
    var interrupted = false
    var resumeAfterInterrupt = false
    var turnFailed = false
    @Published var accountStatus = ""
    @Published var probeError = ""
    @Published var busy = false
    @Published var status = "Ready"
    @Published var toolStatus = ToolStatus()
    var remoteID: String?
    var started: Bool
    var choices = SessionChoices()
    @Published var modelChoices: [MuseModelChoice] = []
    @Published var accessChoices: [MuseAccessChoice] = []
    @Published var changingSetting = false
    var sidebarProbeAttemptAt: Date?
    var quotaRefreshedAt: Date?
    var probingStatus = false
    var statusCallbacks: [() -> Void] = []
    var statusDetails = ""
    var lastOutputAt: TimeInterval?
    var streamedText = false
    var process: Process?
    var muse: MuseConnection?
    @Published var requests: [MuseRequest] = []
    var requestAnswers = MuseRequestAnswers()
    @Published var requestError = ""
    @Published var answeringRequest = false
    var museItems: [String: UUID] = [:]
    var web: WKWebView?
    var textScrollOrigin: NSPoint?
    var textSelection: NSRange?
    init(_ saved: SavedSession) {
        id = saved.id; entry = saved.entry; title = saved.title; messages = saved.messages
        toolStatus = saved.toolStatus ?? ToolStatus()
        accountStatus = saved.toolStatus?.account ?? ""
        choices = saved.choices ?? SessionChoices()
        switchboardEnabled = saved.switchboardEnabled ?? false; switchboardHandled = saved.switchboardHandled ?? []
        pending = saved.pending ?? []; queuePaused = !(saved.pending ?? []).isEmpty
        draft = saved.draft; attachments = saved.attachments; remoteID = saved.remoteID; started = saved.started
    }
    convenience init(entry: Entry) {
        self.init(SavedSession(id: UUID(uuidString: MuseStatusProbe.commandID())!, entry: entry, title: "New conversation", messages: [], draft: "", attachments: [], remoteID: nil, started: false))
    }
    var saved: SavedSession { SavedSession(id: id, entry: entry, title: title, messages: messages, draft: draft, attachments: attachments, remoteID: remoteID, started: started, toolStatus: toolStatus, choices: choices, pending: pending, switchboardEnabled: switchboardEnabled, switchboardHandled: switchboardHandled) }
}
struct Archive: Codable { var entries: [Entry]; var sessions: [SavedSession]; var accounts: [AccountProfile]? = nil; var setupCompleted: Bool? = nil }
final class Store: ObservableObject {
    static let shared = Store()
    @Published var lineNumbers = UserDefaults.standard.object(forKey: "lineNumbers") as? Bool ?? true { didSet { UserDefaults.standard.set(lineNumbers, forKey: "lineNumbers") } }
    @Published var setupCompleted = false
    @Published var accounts: [AccountProfile] = []
    @Published var entries: [Entry] = []
    @Published var sessions: [Session] = []
    let folder: URL
    var pendingSave: DispatchWorkItem?
    init(folder: URL? = nil) {
        self.folder = folder ?? ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Converse")
        accounts = AccountProfile.defaults(dataFolder: self.folder)
        do {
            try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: self.folder.appendingPathComponent("sessions.json")))
            setupCompleted = archive.setupCompleted ?? true
            entries = archive.entries; sessions = archive.sessions.map(Session.init)
            accounts = archive.accounts ?? accounts
            for session in sessions where session.entry.accountID == nil {
                if let profile = accounts.first(where: { $0.id == session.entry.engine + "-default" }) {
                    session.entry.accountID = profile.id; session.entry.accountName = profile.name; session.entry.accountDirectory = profile.directory
                }
            }
        } catch {
            if FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("sessions.json").path) {
                DispatchQueue.main.async { let alert = NSAlert(); alert.messageText = "Could not load saved conversations"; alert.informativeText = "Your saved file has been left in Application Support/Converse. \(error.localizedDescription)"; alert.runModal() }
            }
            setupCompleted = FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("sessions.json").path)
            entries = SetupCatalog.entries
        }
    }
    func saveSoon() {
        pendingSave?.cancel()
        let task = DispatchWorkItem { self.save() }; pendingSave = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }
    func save() {
        do { let data = try JSONEncoder().encode(Archive(entries: entries, sessions: sessions.map(\.saved), accounts: accounts, setupCompleted: setupCompleted)); try data.write(to: folder.appendingPathComponent("sessions.json"), options: .atomic) }
        catch { NSLog("Save failed: %@", error.localizedDescription) }
    }
    func create(_ entry: Entry) -> Session {
        var entry = entry
        if entry.accountDirectory == nil, let profile = accounts.first(where: { $0.id == (entry.accountID ?? entry.engine + "-default") }) {
            entry.accountID = profile.id; entry.accountName = profile.name; entry.accountDirectory = profile.directory
        }
        let s = Session(entry: entry); sessions.append(s); save(); return s
    }
    func stop(_ s: Session) {
        s.queuePaused = true; s.resumeAfterInterrupt = false
        interruptProcess(s)
    }
    func interruptProcess(_ s: Session) {
        guard s.busy else { return }
        s.interrupted = true
        if let muse = s.muse { s.status = "Stopping…"; muse.interrupt(); return }
        guard let p = s.process, p.isRunning else { return }
        s.status = "Stopping…"; p.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if p.isRunning { s.status = "Still stopping… · queued input is held" } }
    }
    func attach(_ s: Session, image: NSImage) {
        do {
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return }
            let dir = folder.appendingPathComponent("Attachments/\(s.id.uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("Screenshot-\(UUID().uuidString).png")
            try png.write(to: url, options: .atomic); s.attachments.append(url.path); saveSoon()
        } catch { s.messages.append(Message(role: "notice", text: "Could not attach image: \(error.localizedDescription)")) }
    }
    func submit(_ s: Session, interrupt: Bool = false) {
        if handleLocalCommand(s) { return }
        let hasInput = !s.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !s.attachments.isEmpty
        guard hasInput else { if interrupt { stop(s) }; return }
        if s.busy || !s.pending.isEmpty {
            let prompt = PendingPrompt(text: s.draft, images: s.attachments)
            if interrupt { s.pending.insert(prompt, at: 0) } else { s.pending.append(prompt) }
            s.draft = ""; s.attachments = []; s.queuePaused = false
            if interrupt && s.busy { s.resumeAfterInterrupt = true; interruptProcess(s) }
            else if !s.busy { runNext(s) }
            save(); return
        }
        send(s)
    }
    func injectPending(_ s: Session, id: UUID? = nil) {
        guard !s.pending.isEmpty, !s.changingSetting else { return }
        if let id {
            guard let index = s.pending.firstIndex(where: { $0.id == id }) else { return }
            let prompt = s.pending.remove(at: index)
            s.pending.insert(prompt, at: 0)
        } else {
            let prompts = s.pending
            s.pending = [PendingPrompt(switchboardHop: prompts.compactMap(\.switchboardHop).max(), text: prompts.map(\.text).joined(separator: "\n\n"), images: prompts.flatMap(\.images))]
        }
        s.queuePaused = false
        if s.busy { s.resumeAfterInterrupt = true; interruptProcess(s) }
        else { runNext(s) }
        save()
    }
    func runNext(_ s: Session) {
        guard !s.busy, !s.changingSetting, !s.queuePaused, !s.pending.isEmpty else { return }
        // A separately edited draft stays editable while queued messages run.
        let draft = s.draft, attachments = s.attachments
        let next = s.pending.removeFirst(); s.draft = next.text; s.attachments = next.images
        send(s, switchboardHop: next.switchboardHop ?? 0)
        if !s.busy { s.pending.insert(next, at: 0); s.queuePaused = true }
        s.draft = draft; s.attachments = attachments; save()
    }
    func finishQueue(_ s: Session, success: Bool) {
        if success && !s.interrupted { processSwitchboard(s) }
        s.switchboardTurnStart = nil
        var shouldRun = s.interrupted ? s.resumeAfterInterrupt : success
        if s.interrupted && s.resumeAfterInterrupt && s.remoteID == nil && !s.started {
            shouldRun = false
            s.messages.append(Message(role: "notice", text: "Interrupted before the CLI returned a conversation ID. Your queued message is held; use Resume queue to retry."))
        }
        s.interrupted = false; s.resumeAfterInterrupt = false
        if !shouldRun { s.queuePaused = !s.pending.isEmpty }
        save()
        if shouldRun { DispatchQueue.main.async { self.runNext(s) } }
    }
    func send(_ s: Session, switchboardHop: Int = 0) {
        if handleLocalCommand(s) { return }
        guard !s.busy && !s.changingSetting, !s.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !s.attachments.isEmpty else { return }
        let directory = NSString(string: s.entry.directory).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            s.messages.append(Message(role: "notice", text: "Working directory does not exist: \(directory). Change it in Settings and start a new session.")); return
        }
        s.interrupted = false; s.resumeAfterInterrupt = false; s.turnFailed = false
        let text = s.draft.isEmpty ? "Please examine the attached image." : s.draft
        let images = s.attachments
        s.switchboardTurnStart = s.messages.count; s.switchboardHop = switchboardHop
        s.messages.append(Message(role: "user", text: text, images: images))
        if s.title == "New conversation" { s.title = String(text.prefix(45)) }
        s.draft = ""; s.attachments = []; s.busy = true; s.lastOutputAt = ProcessInfo.processInfo.systemUptime; s.streamedText = false; s.status = "Working…"
        let responseID = UUID(); s.messages.append(Message(id: responseID, role: "assistant", text: ""))
        var args: [String] = []
        updateExplicitStatus(s)
        var prompt = text
        if ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] == nil {
            let zone = TimeZone.current
            let formatter = ISO8601DateFormatter(); formatter.timeZone = zone
            prompt += "\n\n[Local context from Converse: time zone \(zone.identifier) (\(zone.abbreviation() ?? "local")); local time at send \(formatter.string(from: Date())). Use this time zone for dates and times unless I request another.]"
        }
        if !images.isEmpty { prompt += "\n\nAttached image files (read these images):\n" + images.joined(separator: "\n") }
        if s.entry.engine == "muse" && ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] == nil {
            sendMuse(s, prompt: prompt, display: text, images: images, responseID: responseID); return
        }
        switch s.entry.engine {
        case "muse":
            args = ["exec", "--json", "--session-id", s.id.uuidString]
            if let model = s.choices.model { args += ["--model", model] }
            if let effort = s.choices.effort { args += ["--reasoning-effort", effort] }
            if let access = s.choices.access { args += ["--permission-profile", access] }
            for image in images { args += ["--image", image] }
        default:
            args = ProviderCommand.turnArguments(entry: s.entry, choices: s.choices, id: s.id, remoteID: s.remoteID, started: s.started, images: images)
        }
        args += ["--", prompt]
        let p = ProviderCommand.process(entry: s.entry, arguments: args, effort: s.choices.effort)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        s.process = p; save()
        do { try p.run() } catch {
            s.busy = false; s.process = nil; s.status = "Failed to start"
            s.messages.append(Message(role: "notice", text: error.localizedDescription)); s.queuePaused = true; save(); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    DispatchQueue.main.async { self.consume(line, session: s, responseID: responseID) }
                }
            }
            if !buffer.isEmpty {
                let line = String(decoding: buffer, as: UTF8.self)
                DispatchQueue.main.async { self.consume(line, session: s, responseID: responseID) }
            }
            p.waitUntilExit()
            DispatchQueue.main.async {
                s.busy = false; s.process = nil
                s.status = s.interrupted ? "Interrupted" : (p.terminationStatus == 0 && !s.turnFailed ? "Ready" : "Failed · exit \(p.terminationStatus)")
                if p.terminationStatus == 0 { s.started = true }
                if let i = s.messages.firstIndex(where: { $0.id == responseID }), s.messages[i].text.isEmpty { s.messages.remove(at: i) }
                if p.terminationStatus != 0 && !s.interrupted { s.messages.append(Message(role: "notice", text: "The command exited with status \(p.terminationStatus). See the activity messages above. Authentication and permission settings use your installed CLI configuration; interactive terminal approval prompts are not supported in this version.")) }
                self.save(); if ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] == nil { self.refreshStatus(s) }; self.objectWillChange.send()
                self.finishQueue(s, success: p.terminationStatus == 0 && !s.turnFailed)
            }
        }
    }
    func sendMuse(_ s: Session, prompt: String, display: String, images: [String], responseID: UUID, serverArguments: [String] = []) {
        let connection = MuseConnection(sessionID: s.remoteID ?? s.id.uuidString)
        s.muse = connection; s.museItems = [:]; s.requests = []; s.requestError = ""; s.status = "Connecting…"
        connection.event = { [weak self, weak s] method, params in
            guard let self, let s, s.muse === connection else { return }
            self.consumeMuse(method, params, session: s, responseID: responseID)
        }
        connection.disconnected = { [weak self, weak s] error in
            guard let self, let s, s.muse === connection else { return }
            self.finishMuse(s, status: "Disconnected", notice: error)
        }
        connection.start(entry: s.entry, arguments: serverArguments) { [weak self, weak s] result in
            guard let self, let s else { return }
            if case .failure(let error) = result { self.finishMuse(s, status: "Connection failed", notice: error.localizedDescription); return }
            s.process = connection.process
            connection.load(entry: s.entry, choices: s.choices) { result in
                if case .failure(let error) = result { self.finishMuse(s, status: "Could not open session", notice: error.localizedDescription); return }
                s.started = true; s.remoteID = connection.sessionID; self.save(); s.status = "Working…"
                connection.submit(prompt: prompt, display: display, images: images, effort: s.choices.effort) { result in
                    if case .failure(let error) = result { self.finishMuse(s, status: "Turn not acknowledged", notice: error.localizedDescription) }
                    else if s.interrupted { connection.interrupt() }
                }
            }
        }
    }
    func finishMuse(_ s: Session, status: String, notice: String? = nil) {
        let connection = s.muse; s.muse = nil; connection?.event = nil; connection?.disconnected = nil; connection?.close()
        s.busy = false; s.process = nil; s.requests = []; s.answeringRequest = false; s.status = status
        s.messages.removeAll { $0.role == "assistant" && $0.text.isEmpty && $0.images.isEmpty }
        if let notice, !notice.isEmpty { s.messages.append(Message(role: "notice", text: notice)) }
        save(); objectWillChange.send()
        if ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] == nil { refreshStatus(s) }
        finishQueue(s, success: status == "Ready")
    }
    func consumeMuse(_ method: String, _ params: [String: Any], session s: Session, responseID: UUID) {
        switch method {
        case "turn/started": s.busy = true; s.muse?.turnID = params["turnId"] as? String; s.status = "Working…"
        case "turn/foregroundCompleted":
            let agents = params["blockingAgents"] as? [String] ?? []
            s.status = "Answer finished · checking " + agents.joined(separator: ", ")
        case "turn/retryScheduled", "turn/modelRetryScheduled":
            let delay = (params["retryDelayMs"] as? Double ?? 0) / 1000
            s.status = "Retrying in \(Int(delay)) sec · attempt \(params["nextAttempt"] as? Int ?? 0)/\(params["maxAttempts"] as? Int ?? 0)"
        case "turn/completed":
            let terminal = params["terminal"] as? String ?? "unknown"
            let error = params["error"] as? [String: Any]
            finishMuse(s, status: terminal == "completed" ? "Ready" : terminal.capitalized, notice: error?["message"] as? String ?? params["reason"] as? String)
        case "session/statusChanged":
            let attention = params["attention"] as? [String] ?? []
            if attention.contains("inputPending") { s.status = "Waiting for your answer" }
            else if attention.contains("approvalPending") { s.status = "Waiting for approval" }
            // Completion is authoritative on turn/completed, never host process lifetime.
        case "approval/reviewing": s.status = "Reviewing approval…"
        case "approval/requested": s.status = "Checking approval…"
        case "approval/request", "userInput/request":
            let kind = method == "approval/request" ? "approval" : "question"
            let id = params[kind == "approval" ? "approvalId" : "userInputId"] as? String ?? ""
            guard !id.isEmpty else { return }
            s.requests.removeAll { $0.id == id }; s.requests.append(MuseRequest(id: id, kind: kind, params: params)); s.requestAnswers.selections = [:]; s.requestAnswers.text = [:]
            s.status = kind == "approval" ? "Waiting for your approval" : "Waiting for your answer"
            s.requestError = ""; s.answeringRequest = false
            NSSound.beep()
        case "approval/updated":
            if let id = params["approvalId"] as? String, let index = s.requests.firstIndex(where: { $0.id == id }) {
                s.requests[index].params.merge(params) { _, new in new }
            }
            s.answeringRequest = false; s.status = s.requests.isEmpty ? "Checking approval…" : "Waiting for your approval"
        case "approval/resolved", "userInput/settled":
            let id = params["approvalId"] as? String ?? params["userInputId"] as? String
            s.requests.removeAll { $0.id == id }; s.answeringRequest = false
            if method == "approval/resolved", let decision = params["decision"] as? String, ["denied", "deniedPolicyAmendment", "timedOut", "abort"].contains(decision) {
                let evidence = params["stageEvidence"] as? [[String: Any]] ?? []
                let diagnostics = evidence.compactMap { ($0["resolution"] as? [String: Any])?["diagnostic"] as? String }
                s.messages.append(Message(role: "notice", text: "Approval " + decision + (diagnostics.isEmpty ? "" : ": " + diagnostics.joined(separator: "\n"))))
            }
            s.status = s.requests.isEmpty ? "Working…" : "Waiting for your answer"
        case "session/tokenUsage":
            if let usage = params["usage"] as? [String: Any] { s.toolStatus.usage = "\((usage["inputTokens"] as? Int ?? 0).formatted()) in / \((usage["outputTokens"] as? Int ?? 0).formatted()) out" }
        case "item/started", "item/updated", "item/completed":
            guard let item = params["item"] as? [String: Any], let itemID = item["itemId"] as? String else { break }
            if item["kind"] as? String == "agentMessage" {
                if s.museItems[itemID] == nil {
                    if s.museItems.isEmpty { s.museItems[itemID] = responseID }
                    else { let id = UUID(); s.museItems[itemID] = id; s.messages.append(Message(id: id, role: "assistant", text: "")) }
                }
                if let value = item["text"] as? String { updateMuseText(value, append: false, itemID: itemID, session: s) }
            } else if item["kind"] as? String == "toolCall", method == "item/completed", item["status"] as? String == "failed" {
                s.messages.append(Message(role: "notice", text: item["failureReason"] as? String ?? "Tool failed"))
            }
        case "item/delta":
            if (params["field"] as? String ?? "text") == "text", let itemID = params["itemId"] as? String, let delta = params["delta"] as? String { updateMuseText(delta, append: true, itemID: itemID, session: s) }
        default: break
        }
        saveSoon()
    }
    func updateMuseText(_ value: String, append: Bool, itemID: String, session s: Session) {
        guard let id = s.museItems[itemID], let i = s.messages.firstIndex(where: { $0.id == id }) else { return }
        let old = s.messages[i].text; let next = append ? old + value : value
        guard next != old else { return }
        s.messages[i].text = next
        markOutput(s, index: i, offset: append || next.hasPrefix(old) ? (old as NSString).length : 0)
    }
    func answerMuse(_ s: Session, request: MuseRequest, choice: String? = nil, answers: [[String: Any]]? = nil, cancel: Bool = false) {
        guard let connection = s.muse, !s.answeringRequest else { return }
        var params: [String: Any] = ["commandId": MuseStatusProbe.commandID(), "sessionId": connection.sessionID]
        let method: String
        if request.kind == "approval" {
            guard let choice, let requirement = request.params["currentRequirementId"],
                  (request.params["availableChoices"] as? [[String: Any]] ?? []).contains(where: { $0["choiceId"] as? String == choice }) else { return }
            method = "approval/decide"; params["approvalId"] = request.id; params["choiceId"] = choice; params["requirementId"] = requirement
        } else {
            method = cancel ? "userInput/cancel" : "userInput/answer"; params["userInputId"] = request.id
            if !cancel { params["answers"] = answers ?? [] }
        }
        s.answeringRequest = true; s.requestError = ""
        connection.rpc(method, params) { result in
            if case .failure(let error) = result {
                s.answeringRequest = false; s.requestError = error.localizedDescription
                // Refresh the race-guarded request after another client or a stage change wins.
                connection.rpc("approval/listPending", ["sessionId": connection.sessionID]) { result in
                    if case .success(let value) = result {
                        s.requests = (value["approvals"] as? [[String: Any]] ?? []).compactMap { p in (p["approvalId"] as? String).map { MuseRequest(id: $0, kind: "approval", params: p) } }
                        s.requests += (value["userInputs"] as? [[String: Any]] ?? []).compactMap { p in (p["userInputId"] as? String).map { MuseRequest(id: $0, kind: "question", params: p) } }
                    }
                }
            }
        }
    }
    func refreshStatus(_ s: Session, quota: Bool = false, completion: (() -> Void)? = nil) {
        guard ProcessInfo.processInfo.environment["CONVERSE_SKIP_STATUS_PROBE"] == nil else { completion?(); return }
        if s.entry.engine != "muse" { refreshProviderStatus(s, completion: completion); return }
        if let completion { s.statusCallbacks.append(completion) }
        guard !s.probingStatus else { return }
        s.probingStatus = true
        let entry = s.entry; let id = s.remoteID ?? s.id.uuidString
        let fetchQuota = quota || s.quotaRefreshedAt == nil || Date().timeIntervalSince(s.quotaRefreshedAt!) > 300
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try MuseStatusProbe.query(entry: entry, sessionID: id) }
            let quotaResult: Result<String, Error>? = fetchQuota && ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] == nil ? Result { try MuseQuota.query(entry: entry) } : nil
            DispatchQueue.main.async {
                s.probingStatus = false
                switch result {
                case .success(let snapshot):
                    s.modelChoices = snapshot.models; s.accessChoices = snapshot.access
                    let previousQuota = s.toolStatus.quota
                    let identity = snapshot.status.account ?? "Muse CLI has no reported account email"
                    s.toolStatus = snapshot.status; s.statusDetails = snapshot.detail
                    s.accountStatus = identity; s.toolStatus.account = identity; s.toolStatus.accountObservedAt = Date()
                    if snapshot.status.quota == "Muse has no observed account quota", let previousQuota, (previousQuota.contains("observed ") || previousQuota.contains("% used")) { s.toolStatus.quota = previousQuota }
                    if !s.started { self.updateExplicitStatus(s) }; self.saveSoon()
                case .failure(let error):
                    s.statusDetails = "Muse status refresh failed: " + error.localizedDescription
                    s.toolStatus.access = "Status refresh failed"
                    s.toolStatus.usage = "Refresh failed"
                }
                if let quotaResult {
                    s.quotaRefreshedAt = Date()
                    switch quotaResult {
                    case .success(let value): s.toolStatus.quota = value
                    case .failure(let error): s.toolStatus.quota = error.localizedDescription
                    }
                }
                self.applySessionChoices(s)
                if let quota = s.toolStatus.quota, let range = s.statusDetails.range(of: "Account quota:") { s.statusDetails.replaceSubrange(range.lowerBound..., with: "Account quota: " + quota) }
                self.saveSoon()
                let callbacks = s.statusCallbacks; s.statusCallbacks = []
                for callback in callbacks { callback() }
            }
        }
    }
    func applySessionChoices(_ s: Session) {
        if let model = s.choices.model {
            s.toolStatus.model = s.entry.engine == "claude" ? (s.modelChoices.first { $0.id == model }?.label ?? model) : model
        }
        if let effort = s.choices.effort { s.toolStatus.effort = effort }
        if let access = s.choices.access { s.toolStatus.access = s.accessChoices.first { $0.id == access }?.label ?? access }
    }
    func changeSetting(_ s: Session, _ change: MuseSettingChange) {
        guard !s.busy && !s.changingSetting else { return }
        func remember() {
            switch change {
            case .model(let model):
                s.choices.model = model.id
                if let effort = s.choices.effort, !model.efforts.contains(effort) {
                    s.choices.effort = s.entry.engine == "muse" ? nil : model.efforts.first
                    s.toolStatus.effort = s.choices.effort ?? "CLI default"
                }
            case .effort(let effort): s.choices.effort = effort
            case .access(let access): s.choices.access = access
            }
            self.applySessionChoices(s); self.save()
        }
        if !s.started || s.entry.engine != "muse" { remember(); return }
        s.changingSetting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try MuseStatusProbe.query(entry: s.entry, sessionID: s.remoteID ?? s.id.uuidString, change: change) }
            DispatchQueue.main.async {
                s.changingSetting = false
                switch result {
                case .success(let snapshot):
                    let quota = s.toolStatus.quota
                    s.toolStatus = snapshot.status; s.toolStatus.quota = quota ?? snapshot.status.quota; s.modelChoices = snapshot.models; s.accessChoices = snapshot.access; s.statusDetails = snapshot.detail
                    remember()
                case .failure(let error):
                    s.messages.append(Message(role: "notice", text: "Could not change session setting: " + error.localizedDescription)); self.saveSoon()
                }
            }
        }
    }
    func handleLocalCommand(_ s: Session) -> Bool {
        let command = s.draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["/help", "/model", "/models", "/usage", "/status", "/stop"].contains(command) else { return false }
        s.messages.append(Message(role: "user", text: s.draft)); s.draft = ""
        if command == "/stop" { stop(s); saveSoon(); return true }
        if command == "/help" {
            s.messages.append(Message(role: "notice", text: "/model or /models — query model, effort and access\n/usage — query last-turn tokens, session totals and available quota\n/status — refresh all session status\n/stop — interrupt the current turn\n/help — show these local commands\nThese commands never submit a prompt. Use the bottom dropdowns for session settings. Return queues while busy. Use Inject now or Inject all to interrupt with queued input. Command Return inserts a newline.")); saveSoon(); return true
        }
        let response = UUID()
        s.messages.append(Message(id: response, role: "notice", text: "Reading " + s.entry.name + " status…"))
        refreshStatus(s, quota: command == "/usage") {
            if let i = s.messages.firstIndex(where: { $0.id == response }) {
                if s.entry.engine != "muse" {
                    s.messages[i].text = "Model: \(s.toolStatus.model)\nEffort: \(s.toolStatus.effort)\nAccess: \(s.toolStatus.access)\nLast turn: \(s.toolStatus.usage)\n\(s.probeError.isEmpty ? s.statusDetails : s.probeError)"
                } else if s.statusDetails.hasPrefix("Muse status refresh failed:") {
                    s.messages[i].text = s.statusDetails
                } else if command == "/usage" {
                    s.messages[i].text = "Last turn: \(s.toolStatus.usage)\nSession total: \(s.toolStatus.totalUsage ?? "Unavailable")\nAccount quota: \(s.toolStatus.quota ?? "Muse has no observed account quota")"
                } else { s.messages[i].text = s.statusDetails }
                self.saveSoon()
            }
        }
        return true
    }
    func deleteSession(_ s: Session) {
        let deleted = folder.appendingPathComponent("Deleted Sessions")
        do {
            try FileManager.default.createDirectory(at: deleted, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(s.saved)
            try data.write(to: deleted.appendingPathComponent(s.id.uuidString + ".json"), options: .atomic)
        } catch {
            let alert = NSAlert(); alert.messageText = "Could not close conversation"; alert.informativeText = error.localizedDescription; alert.runModal(); return
        }
        s.pending = []; stop(s)
        sessions.removeAll { $0.id == s.id }
        AppDelegate.shared?.sessionWasDeleted(s)
        save()
    }
    func restoreDeleted() -> Session? {
        let dir = folder.appendingPathComponent("Deleted Sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        for file in files.sorted(by: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }) {
            guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(SavedSession.self, from: data), !sessions.contains(where: { $0.id == saved.id }) else { continue }
            let s = Session(saved); sessions.append(s)
            if !entries.contains(where: { $0.id == s.entry.id }) { entries.append(s.entry) }
            save(); return s
        }
        return nil
    }
    func updateExplicitStatus(_ s: Session) {
        func option(_ names: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s)(?:" + names + ")(?:=|\\s+)([^\\s]+)") else { return nil }
            let command = s.entry.command as NSString
            guard let match = regex.firstMatch(in: s.entry.command, range: NSRange(location: 0, length: command.length)) else { return nil }
            return command.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        if let model = option("--model|-m") { s.toolStatus.model = model + " (requested)" }
        if let effort = option("--reasoning-effort|--effort") { s.toolStatus.effort = effort + " (requested)" }
        if let access = option("--permission-profile|--approval-mode|--permission-mode|--sandbox|-s") { s.toolStatus.access = access + " (requested)" }
        applySessionChoices(s)
    }
    func updateReportedStatus(_ obj: [String: Any], session s: Session) {
        let payload = obj["payload"] as? [String: Any] ?? obj
        if let quota = payload["allowance"] as? [String: Any], quota["window"] != nil { s.toolStatus.quota = MuseStatusProbe.quotaSummary(quota) }
        if let model = payload["model"] as? String { s.toolStatus.model = model }
        if let message = obj["message"] as? [String: Any], let model = message["model"] as? String { s.toolStatus.model = model }
        for key in ["reasoning_effort", "reasoningEffort", "effort"] {
            if let effort = payload[key] as? String { s.toolStatus.effort = effort }
        }
        for key in ["permissionMode", "permission_mode", "permission_profile", "approval_mode", "sandbox"] {
            if let access = payload[key] as? String { s.toolStatus.access = access }
        }
        let models = payload["models"] as? [[String: Any]] ?? []
        if let model = models.compactMap({ $0["model"] as? String }).first { s.toolStatus.model = model }
        let usage = payload["usage"] as? [String: Any] ?? payload
        var input = usage["input_tokens"] as? Int
        var output = usage["output_tokens"] as? Int
        if !models.isEmpty {
            input = models.reduce(0) { $0 + ($1["input_tokens"] as? Int ?? 0) }
            output = models.reduce(0) { $0 + ($1["output_tokens"] as? Int ?? 0) }
        }
        if let input, let output { s.toolStatus.usage = "\(input.formatted()) in / \(output.formatted()) out" }
    }
    static func visibleText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("muse: workspace root:") || trimmed.hasPrefix("muse: workspace trust:") { return "" }
        var candidate = trimmed
        if candidate.hasPrefix("```json"), candidate.hasSuffix("```") { candidate = String(candidate.dropFirst(7).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let data = candidate.data(using: .utf8), let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           value["chunk_id"] != nil || value["terminal_status"] != nil || (value["command"] != nil && value["output"] != nil) {
            if let output = value["output"] as? String { return output.trimmingCharacters(in: .newlines) }
            if let error = value["error"] as? String { return error }
            return ""
        }
        return raw
    }
    static func delayLabel(_ seconds: Double) -> String {
        if seconds < 60 { return "[\(Int(seconds.rounded())) sec]" }
        if seconds < 3600 { return String(format: "[%.1f minutes]", seconds / 60) }
        return String(format: "[%.1f hours]", seconds / 3600)
    }
    func markOutput(_ s: Session, index: Int, offset: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let previous = s.lastOutputAt, now - previous >= 10 {
            var marks = s.messages[index].delays ?? []
            marks.append(DelayMark(offset: offset, seconds: now - previous))
            s.messages[index].delays = marks
        }
        s.lastOutputAt = now
    }
    func activity(_ raw: String, session s: Session) {
        let text = Store.visibleText(raw)
        guard !text.isEmpty else { return }
        s.messages.append(Message(role: "activity", text: text))
        // Tool activity is retained for diagnostics, but does not reset visible-answer timing.
    }
    func consume(_ line: String, session s: Session, responseID: UUID) {
        guard !line.isEmpty else { return }
        guard let data = line.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            activity(line, session: s); saveSoon(); return
        }
        updateReportedStatus(obj, session: s)
        var text: String?; var replace = false; var delta = false
        let type = obj["type"] as? String ?? ""
        if s.entry.engine == "muse" {
            let payload = obj["payload"] as? [String: Any] ?? [:]
            let kind = obj["payload_type"] as? String ?? ""
            if kind.hasPrefix("run.terminal") { text = payload["text"] as? String; replace = true
                if let reason = payload["reason"] as? String { s.messages.append(Message(role: "notice", text: reason)) }
            } else if kind == "run.output.delta" || kind.contains("text.delta") || kind.contains("text_delta") { text = payload["delta"] as? String ?? payload["text"] as? String; delta = true }
            else if kind.contains("tool"), let raw = payload["text"] as? String,
                    let data = raw.data(using: .utf8), let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                    let code = result["exit_code"] as? Int, code != 0 {
                s.messages.append(Message(role: "notice", text: Store.visibleText(raw)))
            }
            else if kind.contains("failed") || kind.contains("approval") {
                let description = payload["reason"] as? String ?? payload["text"] as? String ?? payload["tool_name"] as? String
                if let description { s.messages.append(Message(role: "notice", text: description)) }
            }
        } else if s.entry.engine == "claude" {
            if let sid = obj["session_id"] as? String { s.remoteID = sid }
            if type == "stream_event", let event = obj["event"] as? [String: Any], let chunk = event["delta"] as? [String: Any], chunk["type"] as? String == "text_delta" {
                text = chunk["text"] as? String; delta = true; s.streamedText = true
            }
            if type == "assistant", let message = obj["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if let value = block["text"] as? String, !s.streamedText { text = (text ?? "") + value }
                    if block["type"] as? String == "tool_use" { activity("Using \(block["name"] as? String ?? "tool")", session: s) }
                }
            } else if type == "result" {
                if obj["is_error"] as? Bool == true { s.turnFailed = true }
                if let result = obj["result"] as? String { text = result; replace = true }
                if let errors = obj["errors"] as? [String] { s.messages.append(Message(role: "notice", text: errors.joined(separator: "\n"))) }
            }
        } else {
            if type == "thread.started" { s.remoteID = obj["thread_id"] as? String }
            if type == "item.completed", let item = obj["item"] as? [String: Any] {
                if item["type"] as? String == "agent_message" { text = item["text"] as? String }
                else if let command = item["command"] as? String { activity(command, session: s) }
            }
            if type == "error" || type == "turn.failed" { s.turnFailed = true; s.messages.append(Message(role: "notice", text: obj["message"] as? String ?? String(describing: obj["error"] ?? "Command failed"))) }
        }
        if let raw = text, let i = s.messages.firstIndex(where: { $0.id == responseID }) {
            let visible = Store.visibleText(raw)
            let old = s.messages[i].text
            if !visible.isEmpty {
                let separator = old.isEmpty || delta ? "" : "\n"
                let next = replace ? visible : old + separator + visible
                if next != old {
                    var offset = replace ? 0 : ((old + separator) as NSString).length
                    if replace && next.hasPrefix(old) { offset = (old as NSString).length }
                    if replace && !next.hasPrefix(old) { s.messages[i].delays = (s.messages[i].delays ?? []).filter { $0.offset == 0 } }
                    s.messages[i].text = next
                    // A final snapshot of already streamed text is not new output.
                    if !(replace && !old.isEmpty && next == old) { markOutput(s, index: i, offset: offset) }
                }
            }
        }
        saveSoon()
    }
}

let transcriptHTML = #"""
<!doctype html><html><head><meta name="viewport" content="width=device-width"><style>
:root {color-scheme:light dark;font:15px -apple-system,BlinkMacSystemFont,sans-serif}body{margin:0;background:transparent;color:light-dark(#252b33,#e8e9ec)}#messages{max-width:820px;margin:auto;padding:36px 38px 100px}.message{margin:0 0 30px;line-height:1.65;overflow-wrap:anywhere}.label{font-size:11px;font-weight:700;letter-spacing:1.2px;text-transform:uppercase;opacity:.5;margin-bottom:8px}.body{white-space:pre-wrap}pre{white-space:pre;overflow:auto;background:light-dark(#f1f3f6,#22252c);padding:16px;border-radius:10px;font:13px ui-monospace,monospace}code{font-family:ui-monospace,monospace}strong{font-weight:650}.user{background:light-dark(#eef0f4,#282b33);padding:18px 22px;border-radius:16px}.activity,.notice{font-size:12px;opacity:.7;border-left:2px solid #8893a4;padding-left:12px;margin-bottom:14px}.notice{color:light-dark(#925119,#efbc82)}a{color:light-dark(#4465ca,#9ab5ff)}img{display:block;max-width:100%;max-height:300px;border-radius:10px;margin-top:12px}#jump{position:fixed;bottom:18px;left:50%;transform:translateX(-50%);border:1px solid #8885;border-radius:20px;padding:9px 16px;background:light-dark(#fff,#30333b);color:inherit;box-shadow:0 3px 15px #0002;display:none;cursor:pointer}#empty{text-align:center;padding-top:18vh;color:#89909e}h1{font-size:28px;font-weight:600;letter-spacing:-1px}
</style></head><body><div id="messages"></div><button id="jump" onclick="window.scrollTo(0,document.body.scrollHeight)">Jump to latest ↓</button><script>
let last='';function nearBottom(){return document.documentElement.scrollHeight-innerHeight-scrollY<110}onscroll=()=>document.getElementById('jump').style.display=nearBottom()?'none':'block';
function bodyText(el,text){const re=/https?:\/\/[^\s<>"\x60]+/g;let start=0;for(const match of text.matchAll(re)){el.append(document.createTextNode(text.slice(start,match.index)));let url=match[0].replace(/[.,;!?)\]]+$/,'');let a=document.createElement('a');a.textContent=url;a.href=url;el.append(a);el.append(document.createTextNode(match[0].slice(url.length)));start=match.index+match[0].length;}el.append(document.createTextNode(text.slice(start)));}
function richText(el,text){let chunks=text.split(/(```[^\n]*\n[\s\S]*?```)/g);for(let part of chunks){if(part.startsWith('```')){let pre=document.createElement('pre');let code=document.createElement('code');code.textContent=part.replace(/^```[^\n]*\n/,'').replace(/```$/,'');pre.append(code);el.append(pre);}else{for(let token of part.split(/(\*\*[^*]+\*\*|`[^`\n]+`)/g)){if(token.startsWith('**')&&token.endsWith('**')){let strong=document.createElement('strong');bodyText(strong,token.slice(2,-2));el.append(strong);}else if(token.startsWith('`')&&token.endsWith('`')){let code=document.createElement('code');code.textContent=token.slice(1,-1);el.append(code);}else bodyText(el,token);}}}}
function render(messages){let key=JSON.stringify(messages);if(key===last)return;last=key;let follow=nearBottom(),y=scrollY;let root=document.getElementById('messages');root.replaceChildren();if(!messages.length){root.innerHTML='<div id="empty"><h1>A little room to think.</h1><p>Start a conversation below.<br>Paste a screenshot. Follow a link. Keep your place.</p></div>';}for(let m of messages){if(!m.text&&!m.images.length)continue;let el=document.createElement('div');el.className='message '+m.role;let label=document.createElement('div');label.className='label';label.textContent=m.role==='user'?'You':m.role==='assistant'?'Assistant':m.role;el.append(label);let b=document.createElement('div');b.className='body';richText(b,m.text);el.append(b);for(let path of m.images){let img=document.createElement('img');img.src='attachment://local/'+encodeURIComponent(path);img.onload=()=>{if(follow)window.scrollTo(0,document.body.scrollHeight)};el.append(img);}root.append(el);}if(follow)window.scrollTo(0,document.body.scrollHeight);else window.scrollTo(0,y);onscroll();}
</script></body></html>
"""#
final class AttachmentHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let path = String(url.absoluteString.dropFirst("attachment://local/".count)).removingPercentEncoding,
              path.hasPrefix(Store.shared.folder.appendingPathComponent("Attachments").path + "/"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        task.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil)); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
struct Transcript: NSViewRepresentable {
    @ObservedObject var session: Session
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        if let web = session.web { web.navigationDelegate = context.coordinator; return web }
        let config = WKWebViewConfiguration(); config.setURLSchemeHandler(AttachmentHandler(), forURLScheme: "attachment")
        let web = WKWebView(frame: .zero, configuration: config); web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator; web.loadHTMLString(transcriptHTML, baseURL: nil); session.web = web; return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.messages = session.messages; context.coordinator.update(web)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var messages: [Message] = []
        func update(_ web: WKWebView) {
            guard let data = try? JSONEncoder().encode(messages), let json = String(data: data, encoding: .utf8) else { return }
            web.evaluateJavaScript("if(typeof render==='function')render(\(json))", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { update(webView) }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                if ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }; decisionHandler(.cancel)
            } else if action.request.url?.scheme == "about" { decisionHandler(.allow) } else { decisionHandler(.cancel) }
        }
    }
}
final class LineNumberRuler: NSRulerView {
    override var isFlipped: Bool { true }
    weak var text: ConversationTextView?
    init(scroll: NSScrollView, text: ConversationTextView) {
        self.text = text
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = text; ruleThickness = 42
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc func refresh() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let text, let layout = text.layoutManager, let container = text.textContainer else { return }
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        NSColor.gray.withAlphaComponent(0.25).setStroke()
        let edge = NSBezierPath(); edge.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY)); edge.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY)); edge.lineWidth = 0.5; edge.stroke()
        layout.ensureLayout(for: container)
        let string = text.string as NSString
        let origin = (scrollView?.contentView.frame.minY ?? 0) - (scrollView?.contentView.bounds.minY ?? 0) + text.textContainerOrigin.y
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.gray]
        var offset = 0; var number = 1; var previousY: CGFloat?
        repeat {
            let lineRect: NSRect
            if offset < string.length {
                let glyph = layout.glyphIndexForCharacter(at: offset)
                lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else { lineRect = layout.extraLineFragmentRect }
            let label = NSAttributedString(string: String(number), attributes: attrs)
            let y = origin + lineRect.minY + max(0, (lineRect.height - label.size().height) / 2)
            let newRow = previousY == nil || abs(lineRect.minY - previousY!) > 0.5
            if newRow && y + lineRect.height >= bounds.minY && y <= bounds.maxY {
                label.draw(at: NSPoint(x: ruleThickness - label.size().width - 9, y: y))
            }
            if offset >= string.length { break }
            let range = string.lineRange(for: NSRange(location: offset, length: 0))
            offset = NSMaxRange(range)
            if newRow { number += 1; previousY = lineRect.minY }
            if offset == string.length && !text.string.hasSuffix("\n") { break }
        } while offset <= string.length
    }
}

final class InputClipView: NSClipView {
    override func mouseDown(with event: NSEvent) {
        if let text = documentView as? ConversationTextView { text.focusInput() }
        else { super.mouseDown(with: event) }
    }
}
final class ConversationScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let text = documentView as? ConversationTextView else { return }
        let height = contentView.bounds.height
        if text.minSize.height != height { text.minSize.height = height }
        if text.frame.height < height { text.setFrameSize(NSSize(width: text.frame.width, height: height)) }
    }
}
final class ConversationTextView: NSTextView {
    func focusInput() {
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        typingAttributes = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.systemBlue]
        insertionPointColor = .systemBlue
        scrollRangeToVisible(selectedRange())
    }
    func isInputWhitespace(_ point: NSPoint) -> Bool {
        guard let layout = layoutManager, let container = textContainer else { return true }
        layout.ensureLayout(for: container)
        if string.isEmpty { return true }
        let extra = layout.extraLineFragmentRect
        let bottom = extra.height > 0 ? extra.minY : layout.usedRect(for: container).maxY
        return point.y >= bottom + textContainerOrigin.y
    }
    override func mouseDown(with event: NSEvent) {
        if isInputWhitespace(convert(event.locationInWindow, from: nil)) { focusInput(); return }
        super.mouseDown(with: event)
    }
    override func insertText(_ value: Any, replacementRange: NSRange) {
        if selectedRange().location < inputStart || (replacementRange.location != NSNotFound && replacementRange.location < inputStart) {
            focusInput(); super.insertText(value, replacementRange: selectedRange()); return
        }
        super.insertText(value, replacementRange: replacementRange)
    }
    struct CopyBlock {
        let range: NSRange
        let role: String
        let source: String
        let formatted: NSAttributedString
    }
    var copyBlocks: [CopyBlock] = []
    func copyBlock(_ index: Int, to pasteboard: NSPasteboard) {
        guard copyBlocks.indices.contains(index) else { return }
        let block = copyBlocks[index]
        pasteboard.clearContents()
        pasteboard.setString(block.source, forType: .string)
        if let rtf = try? block.formatted.data(from: NSRange(location: 0, length: block.formatted.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        if let html = try? block.formatted.data(from: NSRange(location: 0, length: block.formatted.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) {
            pasteboard.setData(html, forType: .html)
        }
    }
    @objc private func copyConversationBlock(_ sender: NSMenuItem) { copyBlock(sender.tag, to: .general) }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let layout = layoutManager, let container = textContainer, !copyBlocks.isEmpty else { return menu }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x; point.y -= textContainerOrigin.y
        let glyph = layout.glyphIndex(for: point, in: container)
        let character = glyph < layout.numberOfGlyphs ? layout.characterIndexForGlyph(at: glyph) : (string as NSString).length
        let clicked = copyBlocks.lastIndex { $0.range.location <= character } ?? 0
        var prompt = clicked
        while prompt > 0 && copyBlocks[prompt].role != "user" { prompt -= 1 }
        var response = copyBlocks[clicked].role == "assistant" ? clicked : prompt + 1
        while response < copyBlocks.count && copyBlocks[response].role != "assistant" { response += 1 }
        var items: [NSMenuItem] = []
        for (title, index) in [("Copy this prompt", prompt), ("Copy this response", response)] {
            guard copyBlocks.indices.contains(index), copyBlocks[index].role == (title == "Copy this prompt" ? "user" : "assistant") else { continue }
            let item = NSMenuItem(title: title, action: #selector(copyConversationBlock(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; items.append(item)
        }
        if !items.isEmpty { menu.insertItem(.separator(), at: 0) }
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }
    var userBlocks: [NSRange] = []
    func refreshDecorations() { needsDisplay = true; enclosingScrollView?.verticalRulerView?.needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        NSColor.gray.withAlphaComponent(0.3).setStroke()
        let length = (string as NSString).length
        let blocks = userBlocks + [NSRange(location: min(inputStart, length), length: max(0, length - inputStart))]
        for block in blocks where block.length > 0 {
            let start = min(block.location, length)
            let end = min(NSMaxRange(block), length)
            guard start < length, end > start else { continue }
            let first = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
            let last = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: end - 1), effectiveRange: nil)
            for y in [first.minY + textContainerOrigin.y - 1, last.maxY + textContainerOrigin.y] {
                let rule = NSBezierPath(); rule.move(to: NSPoint(x: textContainerOrigin.x, y: y)); rule.line(to: NSPoint(x: bounds.maxX - textContainerInset.width, y: y)); rule.lineWidth = 0.5; rule.stroke()
            }
        }
    }

    var inputStart = 0
    var submit: (() -> Void)?
    var imagePaste: ((NSImage) -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { super.keyDown(with: event); return }
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewline(nil); return
            }
            submit?(); return
        }
        // Typing while reading history always goes to the current input.
        if selectedRange().location < inputStart && !event.modifierFlags.contains(.command),
           let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        }
        super.keyDown(with: event)
    }
    static func clipboardImage(_ board: NSPasteboard) -> NSImage? {
        for type in [NSPasteboard.PasteboardType.png, .tiff, .init("public.jpeg"), .init("public.heic")] {
            if let data = board.data(forType: type), let image = NSImage(data: data) { return image }
        }
        if let image = NSImage(pasteboard: board) { return image }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls { if let image = NSImage(contentsOf: url) { return image } }
        }
        return nil
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), Self.clipboardImage(.general) != nil { return imagePaste != nil }
        return super.validateUserInterfaceItem(item)
    }
    override func paste(_ sender: Any?) {
        if let image = Self.clipboardImage(.general) { imagePaste?(image); return }
        if selectedRange().location < inputStart { setSelectedRange(NSRange(location: (string as NSString).length, length: 0)) }
        pasteAsPlainText(sender)
    }
    override func selectAll(_ sender: Any?) {
        if selectedRange().location >= inputStart { setSelectedRange(NSRange(location: inputStart, length: (string as NSString).length - inputStart)) }
        else { super.selectAll(sender) }
    }
}
struct ScrollingConversation: NSViewRepresentable {
    @ObservedObject var session: Session
    var lineNumbers: Bool = true
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ConversationScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        scroll.contentView = InputClipView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.backgroundColor = NSColor.textBackgroundColor
        let text = ConversationTextView(frame: scroll.contentView.bounds)
        text.minSize = NSSize(width: 0, height: 600)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.isEditable = true; text.isSelectable = true; text.isRichText = true
        text.importsGraphics = false; text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.font = .systemFont(ofSize: 16); text.backgroundColor = NSColor.textBackgroundColor
        text.delegate = context.coordinator
        text.setAccessibilityLabel("Conversation and message input. Return sends or queues. Command Return inserts a new line.")
        text.submit = { Store.shared.submit(session) }
        text.imagePaste = { Store.shared.attach(session, image: $0) }
        scroll.documentView = text
        scroll.verticalRulerView = LineNumberRuler(scroll: scroll, text: text)
        scroll.hasVerticalRuler = true; scroll.rulersVisible = lineNumbers
        context.coordinator.render(text)
        if let selection = session.textSelection, NSMaxRange(selection) <= (text.string as NSString).length { text.setSelectedRange(selection) }
        if let origin = session.textScrollOrigin { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
        DispatchQueue.main.async { text.window?.makeFirstResponder(text) }
        return scroll
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // The native scroll view starts wide, but must accept narrower split panes.
        CGSize(width: proposal.width ?? 700, height: proposal.height ?? 600)
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        scroll.rulersVisible = lineNumbers
        if let text = scroll.documentView as? ConversationTextView { context.coordinator.render(text); text.refreshDecorations() }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.session.textScrollOrigin = scroll.contentView.bounds.origin
        coordinator.session.textSelection = (scroll.documentView as? NSTextView)?.selectedRange()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: Session
        var signature = ""
        var markdownCache: [UUID: (String, NSAttributedString)] = [:]
        var rendering = false
        init(_ session: Session) { self.session = session }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let text = textView as? ConversationTextView else { return false }
            return rendering || affectedCharRange.location >= text.inputStart
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let text = notification.object as? ConversationTextView, text.selectedRange().location >= text.inputStart else { return }
            text.typingAttributes = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.systemBlue]
        }
        func textDidChange(_ notification: Notification) {
            guard !rendering, let text = notification.object as? ConversationTextView else { return }
            session.draft = (text.string as NSString).substring(from: min(text.inputStart, (text.string as NSString).length))
            let length = (text.string as NSString).length
            if length > text.inputStart { text.textStorage?.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: NSRange(location: text.inputStart, length: length - text.inputStart)) }
            text.refreshDecorations()
            text.typingAttributes[.foregroundColor] = NSColor.systemBlue
            text.scrollRangeToVisible(NSRange(location: length, length: 0))
            Store.shared.saveSoon()
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            return true
        }
        func render(_ text: ConversationTextView) {
            let data = (try? JSONEncoder().encode(session.messages)) ?? Data()
            let key = String(decoding: data, as: UTF8.self) + session.attachments.joined() + String(session.busy)
            let current = text.string as NSString
            if key == signature && current.length >= text.inputStart && current.substring(from: text.inputStart) == session.draft { return }
            let firstRender = signature.isEmpty
            signature = key
            let selection = text.selectedRange()
            let editing = selection.location >= text.inputStart
            let offset = max(0, selection.location - text.inputStart)
            let scroll = text.enclosingScrollView
            let origin = scroll?.contentView.bounds.origin ?? .zero
            let follow = firstRender || (scroll.map { $0.contentView.bounds.maxY >= text.bounds.height - 70 } ?? true)
            rendering = true
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2; paragraph.paragraphSpacing = 0
            let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
            let document = NSMutableAttributedString(string: "")
            func append(_ string: String, _ attrs: [NSAttributedString.Key: Any] = [:]) {
                document.append(NSAttributedString(string: string, attributes: base.merging(attrs) { _, new in new }))
            }
            func image(_ path: String) {
                guard let img = NSImage(contentsOfFile: path) else { return }
                let attachment = NSTextAttachment(); attachment.image = img
                let scale = min(1, 480 / max(img.size.width, 1), 260 / max(img.size.height, 1))
                attachment.bounds = NSRect(x: 0, y: 0, width: img.size.width * scale, height: img.size.height * scale)
                document.append(NSAttributedString(attachment: attachment)); append("\n")
            }
            text.userBlocks = []
            text.copyBlocks = []
            for message in session.messages where message.role != "activity" && (!message.text.isEmpty || !message.images.isEmpty) {
                let visible = Store.visibleText(message.text)
                if visible.isEmpty && message.images.isEmpty { continue }
                let body: NSMutableAttributedString
                if message.role == "assistant" {
                    if let cached = markdownCache[message.id], cached.0 == visible { body = NSMutableAttributedString(attributedString: cached.1) }
                    else { body = MarkdownText.render(visible); markdownCache[message.id] = (visible, NSAttributedString(attributedString: body)) }
                } else { body = NSMutableAttributedString(string: visible + "\n", attributes: base) }
                for mark in (message.delays ?? []).sorted(by: { $0.offset > $1.offset }) {
                    let sourceOffset = min(max(0, mark.offset), (visible as NSString).length)
                    let renderedOffset = message.role == "assistant" && sourceOffset > 0 ? MarkdownText.render((visible as NSString).substring(to: sourceOffset)).length : sourceOffset
                    let at = min(renderedOffset, body.length)
                    body.insert(NSAttributedString(string: Store.delayLabel(mark.seconds) + " ", attributes: base.merging([.foregroundColor: NSColor.gray]) { _, new in new }), at: at)
                }
                if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                    let value = body.string as NSString
                    for match in detector.matches(in: body.string, range: NSRange(location: 0, length: value.length)) {
                        if let url = match.url, ["http", "https"].contains(url.scheme ?? "") { body.addAttribute(.link, value: url, range: match.range) }
                    }
                }
                let start = document.length
                if message.role == "user" {
                    body.addAttribute(.font, value: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 16), toHaveTrait: .italicFontMask), range: NSRange(location: 0, length: body.length))
                }
                document.append(body)
                if message.role == "user" || message.role == "assistant" {
                    let formatted = message.role == "assistant" ? MarkdownText.render(visible) : NSAttributedString(string: visible, attributes: body.attributes(at: 0, effectiveRange: nil))
                    text.copyBlocks.append(.init(range: NSRange(location: start, length: body.length), role: message.role, source: visible, formatted: formatted))
                }
                for path in message.images { image(path) }
                if message.role == "user" { text.userBlocks.append(NSRange(location: start, length: max(0, document.length - start - 1))) }
            }
            for path in session.attachments { image(path) }
            text.inputStart = document.length
            let draftStyle: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemBlue]
            append(session.draft, draftStyle)
            text.textStorage?.setAttributedString(document)
            text.typingAttributes = base.merging(draftStyle) { _, value in value }
            text.insertionPointColor = .systemBlue
            text.undoManager?.removeAllActions()
            if session.draft.isEmpty && selection.length == 0 { text.setSelectedRange(NSRange(location: document.length, length: 0)) }
            else if editing || firstRender { text.setSelectedRange(NSRange(location: min(document.length, text.inputStart + offset), length: min(selection.length, max(0, document.length - text.inputStart - offset)))) }
            else { text.setSelectedRange(NSRange(location: min(selection.location, document.length), length: 0)) }
            text.typingAttributes = base.merging(draftStyle) { _, value in value }
            text.layoutManager?.ensureLayout(for: text.textContainer!)
            if follow { text.scrollRangeToVisible(NSRange(location: document.length, length: 0)) }
            else { scroll?.contentView.scroll(to: origin); scroll?.reflectScrolledClipView(scroll!.contentView) }
            text.refreshDecorations()
            rendering = false
        }
    }
}
struct Conversation: View {
    @ObservedObject var session: Session
    @ObservedObject var store = Store.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("↵ send / queue · ⌘↵ newline").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                Spacer()
                Toggle("line numbers", isOn: $store.lineNumbers).toggleStyle(.checkbox).font(.caption).fixedSize()
                Button { let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true; if panel.runModal() == .OK { for url in panel.urls { if let image = NSImage(contentsOf: url) { Store.shared.attach(session, image: image) } } } } label: { Image(systemName: "paperclip") }.help("Attach image or paste a screenshot")
                if !session.attachments.isEmpty { Button("Clear images") { session.attachments = []; Store.shared.saveSoon() } }
                if session.busy { if session.requests.isEmpty && !session.status.hasPrefix("Waiting") { ProgressView().controlSize(.small) }; Button("Stop") { Store.shared.stop(session) } }
            }.padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            if let request = session.requests.first { MuseRequestView(session: session, request: request).id(request.id) }
            if !session.pending.isEmpty { PendingMessagesView(session: session) }
            ScrollingConversation(session: session, lineNumbers: store.lineNumbers)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(session.status)
                    Menu(session.entry.accountName ?? session.entry.name) {
                        ForEach(store.accounts.filter { $0.engine == session.entry.engine }) { profile in
                            Button(profile.name + (session.entry.accountID == profile.id ? " ✓" : (session.started ? " · new conversation" : ""))) { store.chooseAccount(session, profile: profile) }
                        }
                        Divider()
                        Button("Manage accounts…") { AppDelegate.shared.showSettings() }
                    }.menuStyle(.borderlessButton).fixedSize().disabled(session.busy || session.changingSetting)
                    if !session.accountStatus.isEmpty { Text(session.accountStatus).help(session.accountStatus).truncationMode(.middle) }
                    Spacer(minLength: 0)
                    Text("Last turn: " + session.toolStatus.usage)
                    Button { store.refreshStatus(session, quota: true) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).disabled(session.probingStatus).help("Refresh this account's models and session status")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        Menu(session.toolStatus.model) {
                            ForEach(session.modelChoices) { model in Button(model.label) { store.changeSetting(session, .model(model)) } }
                            Divider()
                            Button("Other model…") { store.chooseCustomModel(session) }
                        }.menuStyle(.borderlessButton).fixedSize()
                        Menu(session.toolStatus.effort) {
                            if session.availableEfforts.isEmpty { Text(session.probingStatus ? "Loading supported effort levels…" : "This model has no reported effort options") }
                            ForEach(session.availableEfforts, id: \.self) { effort in Button(effort) { store.changeSetting(session, .effort(effort)) } }
                            Divider()
                            Button("Other effort…") { store.chooseCustomEffort(session) }
                        }.menuStyle(.borderlessButton).fixedSize()
                        Menu(session.toolStatus.access) {
                            ForEach(session.accessChoices) { access in Button(access.label) { store.changeSetting(session, .access(access.id)) }.disabled(!access.available) }
                        }.menuStyle(.borderlessButton).fixedSize()
                    }.disabled(session.busy || session.changingSetting || session.probingStatus)
                }
                if !session.probeError.isEmpty { Text(session.probeError).foregroundStyle(.orange).help(session.probeError) }
            }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .help("Settings apply to subsequent turns in this conversation. Switching accounts opens a new conversation and keeps this account's history. Token usage is not account quota.")
        }.background(Color(nsColor: .textBackgroundColor)).onAppear { Store.shared.refreshStatus(session) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if !session.busy { store.refreshStatus(session) } }
    }
}

struct RootView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var workspace = Workspace.shared
    @ObservedObject var state: WindowState
    var body: some View {
        HSplitView {
            GeometryReader { sidebar in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Color.clear.frame(width: 12, height: 1)
                    Text("Conversation").lineLimit(1).truncationMode(.tail).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    if sidebar.size.width >= 360 { Text("Model").frame(width: 105, alignment: .leading) }
                    Text("Placement").frame(width: 98, alignment: .leading)
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.entries) { entry in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(entry.name).fontWeight(store.sessions.contains { $0.entry.id == entry.id } ? .bold : .regular)
                                    Text(entry.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(entry.directory)
                                    Spacer()
                                    Button { AppDelegate.shared.newSession(entry, state: state) } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("New session")
                                }.padding(.horizontal, 4).contextMenu {
                                    Button("Configure…") { AppDelegate.shared.configureEntry(entry) }
                                    Button("New Session") { AppDelegate.shared.newSession(entry, state: state) }
                                    Button("Delete Entry", role: .destructive) { store.entries.removeAll { $0.id == entry.id }; store.save() }.disabled(store.sessions.contains { $0.entry.id == entry.id })
                                }
                                ForEach(store.sessions.filter { $0.entry.id == entry.id }) { session in
                                    SidebarSession(session: session, workspace: workspace, state: state, showsModel: sidebar.size.width >= 360)
                                }
                            }
                        }
                    }.padding(.top, 6)
                }
                HStack {
                    Button("New window", systemImage: "macwindow.badge.plus") { AppDelegate.shared.newWindow() }
                    Spacer()
                    Text("\(workspace.names.count) window\(workspace.names.count == 1 ? "" : "s")").font(.caption)
                    Button { state.settings = true } label: { Image(systemName: "slider.horizontal.3") }.help("Settings")
                }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.bottom, 6)
            }.padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(minWidth: 200, idealWidth: 340, maxWidth: 480)
            WorkspacePanes(workspace: workspace, state: state)
        }.sheet(isPresented: $state.settings) { SettingsView() }.sheet(isPresented: $state.setup) { SetupView(state: state) }.frame(minWidth: 760, minHeight: 540)
    }
}
struct SettingsView: View {
    @ObservedObject var store = Store.shared
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Assistants").font(.title2.bold())
            Text("Commands run through your login shell. Choose the matching conversation adapter. Changes apply to new sessions.").font(.callout).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 18) {
                Text("Accounts").font(.headline)
                Text("Default accounts reuse your existing CLI sign-ins. Add named accounts for separate sign-ins; each gets its own configuration folder. Claude desktop sign-ins are separate from Claude Code. Account changes apply to new conversations.").font(.caption).foregroundStyle(.secondary)
                ForEach($store.accounts) { $profile in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Account name", text: $profile.name)
                            Text(profile.engine.capitalized).foregroundStyle(.secondary).frame(width: 60)
                            if profile.engine != "muse" { Button("Sign in…") { store.signIn(profile) }.disabled(store.accountIsBusy(profile)).help("Sign in to this CLI account when its active turns have finished") }
                        }
                        if profile.engine != "muse" { TextField("CLI configuration directory", text: $profile.directory) }
                    }.padding(8).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                HStack { Button("Add Codex account") { store.addAccount(engine: "codex") }; Button("Add Claude account") { store.addAccount(engine: "claude") } }
                Divider()
                Text("Assistants").font(.headline)
                ForEach($store.entries) { $entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { TextField("Name", text: $entry.name); Picker("Adapter", selection: $entry.engine) { Text("Muse").tag("muse"); Text("Claude").tag("claude"); Text("Codex").tag("codex") }.frame(width: 200) }
                        TextField("Command line, e.g. muse --model …", text: $entry.command)
                        TextField("Working directory", text: $entry.directory)
                        Picker("Default account", selection: Binding(get: { entry.accountID ?? entry.engine + "-default" }, set: { entry.accountID = $0; entry.accountName = nil; entry.accountDirectory = nil })) {
                            ForEach(store.accounts.filter { $0.engine == entry.engine }) { profile in Text(profile.name).tag(profile.id) }
                        }
                        HStack { Button("Choose directory…") { let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; if p.runModal() == .OK, let url = p.url { entry.directory = url.path } }; Spacer(); Button("Remove") { store.entries.removeAll { $0.id == entry.id } }.disabled(store.sessions.contains { $0.entry.id == entry.id }) }
                    }.padding(12).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } }.textFieldStyle(.roundedBorder)
            HStack { Button("Add assistant") { store.entries.append(Entry(name: "Muse", command: "muse", directory: "~", engine: "muse")) }; Spacer(); Button("Done") { store.save(); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 600, height: 540).onDisappear { store.save() }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate!
    var windows: [(NSWindow, WindowState)] = []
    var paneObserver: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.appearance = nil
        paneObserver = Workspace.shared.$placements.sink { [weak self] placements in self?.updatePaneWidths(placements) }
        buildMenu(); newWindow(); NSApp.activate(ignoringOtherApps: true)
    }
    func buildMenu() {
        let menu = NSMenu(); let app = NSMenuItem(); menu.addItem(app); let sub = NSMenu(); app.submenu = sub
        sub.addItem(withTitle: "About Converse", action: #selector(about), keyEquivalent: "")
        sub.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ","); sub.addItem(.separator()); sub.addItem(withTitle: "Quit Converse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem(); file.title = "File"; menu.addItem(file); let f = NSMenu(title: "File"); file.submenu = f
        f.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        f.addItem(withTitle: "Restore Closed Conversation", action: #selector(restoreDeletedConversation), keyEquivalent: "")
        f.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenuItem(); edit.title = "Edit"; menu.addItem(edit); let e = NSMenu(title: "Edit"); edit.submenu = e
        for (name, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { e.addItem(withTitle: name, action: Selector(action), keyEquivalent: key) }
        let window = NSMenuItem(); window.title = "Window"; menu.addItem(window); let w = NSMenu(title: "Window"); window.submenu = w
        w.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"); w.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""); NSApp.windowsMenu = w
        let help = NSMenuItem(); help.title = "Help"; menu.addItem(help); let h = NSMenu(title: "Help"); help.submenu = h
        h.addItem(withTitle: "Setup Guide…", action: #selector(showSetup), keyEquivalent: "")
        NSApp.mainMenu = menu
    }
    @objc func showSettings() {
        if windows.isEmpty { newWindow() }
        (windows.first { $0.0.isKeyWindow } ?? windows.last)?.1.settings = true
    }
    @objc func showSetup() {
        if windows.isEmpty { newWindow() }
        guard let state = (windows.first { $0.0.isKeyWindow } ?? windows.last)?.1 else { return }
        state.settings = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { state.setup = true }
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Converse", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Preview", .credits: NSAttributedString(string: "A calmer home for your command-line assistants.")]) }
    @objc func newWindow() {
        let state = WindowState()
        state.setup = windows.isEmpty && !Store.shared.setupCompleted
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 760, height: 540)
        window.title = state.title; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false; window.delegate = self
        let title = NSTitlebarAccessoryViewController(); title.layoutAttribute = .left
        title.view = NSHostingView(rootView: WindowTitle(workspace: .shared, state: state)); title.view.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        window.addTitlebarAccessoryViewController(title)
        window.contentView = NSHostingView(rootView: RootView(state: state)); window.center(); window.setFrameAutosaveName("ConverseWindow")
        if let (previous, _) = windows.last { window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24)) }
        windows.append((window, state)); window.makeKeyAndOrderFront(nil)
        NSApp.addWindowsItem(window, title: state.title, filename: false)
    }
    func updatePaneWidths(_ placements: [UUID: PaneLocation]) {
        for (window, state) in windows where window.isVisible {
            let count = placements.values.filter { $0.windowID == state.id }.count
            let minimum = Workspace.minimumWidth(paneCount: count)
            window.contentMinSize = NSSize(width: minimum, height: 540)
            let size = window.contentRect(forFrameRect: window.frame).size
            if size.width < minimum { window.setContentSize(NSSize(width: minimum, height: max(540, size.height))) }
        }
    }
    func sessionWasDeleted(_ session: Session) { Workspace.shared.park(session.id) }
    func closeSessionWindow(_ session: Session) {
        guard let location = Workspace.shared.placements[session.id], let (window, _) = windows.first(where: { $0.1.id == location.windowID }) else { return }
        window.performClose(nil)
    }
    func frontWindow(_ id: UUID) {
        guard let (window, _) = windows.first(where: { $0.1.id == id }) else { return }
        window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
    }
    func renameWindow(_ id: UUID) {
        guard let (window, state) = windows.first(where: { $0.1.id == id }) else { return }
        configurationForm(title: "Rename window", values: [("Window name", state.title)]) { values in
            guard !values[0].isEmpty else { return }
            Workspace.shared.rename(id, to: values[0]); window.title = state.title
            NSApp.changeWindowsItem(window, title: state.title, filename: false)
        }
    }
    func assign(_ session: Session, to state: WindowState, pane: Int) {
        guard Store.shared.sessions.contains(where: { $0.id == session.id }) else { return }
        Workspace.shared.assign(session.id, to: state.id, pane: pane)
        if let (window, _) = windows.first(where: { $0.1.id == state.id }) { window.makeKeyAndOrderFront(nil) }
    }
    @objc func restoreDeletedConversation() {
        guard let session = Store.shared.restoreDeleted() else { return }
        if windows.isEmpty { newWindow() }
        if let (_, state) = windows.first(where: { $0.0.isKeyWindow }) ?? windows.last { select(session, state: state) }
    }
    func configurationForm(title: String, values: [(String, String)], save: ([String]) -> Void) {
        let alert = NSAlert(); alert.messageText = title
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: CGFloat(values.count * 44)))
        var fields = [NSTextField]()
        for (index, item) in values.enumerated() {
            let y = CGFloat((values.count - index - 1) * 44)
            let label = NSTextField(labelWithString: item.0); label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; label.frame = NSRect(x: 0, y: y + 25, width: 350, height: 16)
            let field = NSTextField(string: item.1); field.frame = NSRect(x: 0, y: y, width: 350, height: 24)
            view.addSubview(label); view.addSubview(field); fields.append(field)
        }
        alert.accessoryView = view; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = fields.first
        if alert.runModal() == .alertFirstButtonReturn { save(fields.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }) }
    }
    func configureEntry(_ entry: Entry) {
        configurationForm(title: "Configure " + entry.name, values: [("Name", entry.name), ("Command", entry.command), ("Working directory", entry.directory)]) { values in
            guard values.allSatisfy({ !$0.isEmpty }), let index = Store.shared.entries.firstIndex(where: { $0.id == entry.id }) else { return }
            Store.shared.entries[index].name = values[0]; Store.shared.entries[index].command = values[1]; Store.shared.entries[index].directory = values[2]; Store.shared.save()
        }
    }
    func configureSession(_ session: Session) {
        guard !session.busy else { return }
        configurationForm(title: "Configure conversation", values: [("Conversation name", session.title), ("Command", session.entry.command), ("Working directory", session.entry.directory)]) { values in
            guard values.allSatisfy({ !$0.isEmpty }) else { return }
            session.title = values[0]; session.entry.command = values[1]; session.entry.directory = values[2]; Store.shared.save()
        }
    }
    func showSession(_ session: Session) {
        if windows.isEmpty { newWindow() }
        let target = windows.first { $0.0.isKeyWindow } ?? windows.last
        if let (window, state) = target { select(session, state: state); window.makeKeyAndOrderFront(nil) }
    }
    func newSession(_ entry: Entry, state: WindowState) { select(Store.shared.create(entry), state: state) }
    func select(_ session: Session, state: WindowState) {
        let pane = Workspace.shared.pane(for: session.id, in: state.id) ?? Workspace.shared.firstAvailablePane(in: state.id)
        assign(session, to: state, pane: pane)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let (_, state) = windows.first(where: { $0.0 === window }) else { return }
        Workspace.shared.close(state.id); NSApp.removeWindowsItem(window)
        windows.removeAll { $0.0 === window }; Store.shared.save()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { newWindow() }; return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = Store.shared.sessions.filter(\.busy)
        if !running.isEmpty {
            let alert = NSAlert(); alert.messageText = "Quit with \(running.count) running session(s)?"; alert.informativeText = "Quitting stops active commands. Your conversations and drafts are saved."; alert.addButton(withTitle: "Keep Running"); alert.addButton(withTitle: "Stop and Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
            for s in running { Store.shared.stop(s) }
        }
        Store.shared.save(); return .terminateNow
    }
}

func selfTest() {
    guard ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil, ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"] != nil else { fputs("Use test.sh to run isolated tests.\n", stderr); exit(2) }
    let store = Store.shared
    func check(_ value: Bool, _ label: String) { if !value { fputs("FAIL: \(label)\n", stderr); exit(1) }; print("PASS: \(label)") }
    providerSelfTests(check)
    let entry = Entry(name: "Echo", command: ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] ?? "muse", directory: NSTemporaryDirectory(), engine: "muse")
    let s = store.create(entry)
    let r = UUID(); s.messages.append(Message(id: r, role: "assistant", text: ""))
    store.consume(#"{"payload_type":"run.terminal.completed","payload":{"text":"Visit https://example.com"}}"#, session: s, responseID: r)
    check(s.messages.last?.text == "Visit https://example.com", "Muse structured response")
    let native = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    let coordinator = ScrollingConversation.Coordinator(s)
    native.delegate = coordinator; coordinator.render(native)
    native.setSelectedRange(NSRange(location: native.inputStart, length: 0))
    native.insertText("a long editable message", replacementRange: native.selectedRange())
    check(s.draft == "a long editable message", "Native text view accepts typing and saves draft")
    check(native.isInputWhitespace(NSPoint(x: 20, y: 450)), "Blank space below transcript is recognized as input")
    native.setSelectedRange(NSRange(location: 0, length: 0))
    let blankClick = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 450), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    native.mouseDown(with: blankClick)
    check(native.selectedRange().location == (native.string as NSString).length, "Clicking blank pane space places the caret at current input")
    native.insertText(" after click", replacementRange: native.selectedRange())
    check(s.draft.hasSuffix(" after click"), "Typing after a blank-space click edits the draft")
    native.setSelectedRange(NSRange(location: 0, length: 0))
    native.insertText(" via input method", replacementRange: NSRange(location: 0, length: 0))
    check(s.draft.hasSuffix(" via input method") && native.string.hasPrefix("Visit https://example.com"), "Input-method text redirects to the draft without editing history")
    let tall = ConversationScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 950))
    tall.documentView = native; tall.tile()
    check(native.minSize.height == tall.contentView.bounds.height && native.frame.height >= tall.contentView.bounds.height, "Editable document fills a viewport taller than 600 points")
    check(native.typingAttributes[.foregroundColor] as? NSColor == NSColor.systemBlue, "Draft typing is blue")
    check(native.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.textColor, "Submitted transcript follows system text color")
    check(!native.string.contains("YOU") && !native.string.contains("MUSE"), "Transcript has no speaker labels")
    let nativeLinkRange = (native.string as NSString).range(of: "https://example.com")
    check(nativeLinkRange.location != NSNotFound && native.textStorage?.attribute(.link, at: nativeLinkRange.location, effectiveRange: nil) != nil, "Native transcript renders clickable URLs")
    check(!coordinator.textView(native, shouldChangeTextIn: NSRange(location: 0, length: 1), replacementString: "x"), "History is protected while input remains editable")
    var sent = false; native.submit = { sent = true }
    let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    native.keyDown(with: enter)
    check(sent, "Return invokes Send from native text view")
    sent = false
    let commandEnter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    native.keyDown(with: commandEnter)
    check(!sent && s.draft.hasSuffix("\n"), "Command Return inserts a newline without sending")
    let styledSession = Session(entry: entry)
    styledSession.messages = [Message(role: "user", text: "line one\nline two"), Message(role: "assistant", text: "response")]
    let styled = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    let styledCoordinator = ScrollingConversation.Coordinator(styledSession)
    styledCoordinator.render(styled)
    let submittedFont = styled.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    check(submittedFont.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true, "Submitted input renders in italics")
    check(styled.userBlocks.count == 1 && styled.userBlocks[0].length == 17, "Multiline input is enclosed as one separator block")
    let timed = Session(entry: entry)
    timed.messages = [Message(id: r, role: "assistant", text: "")]
    store.consume("muse: workspace root: /somewhere", session: timed, responseID: r)
    store.consume("muse: workspace trust: trusted source=user-config", session: timed, responseID: r)
    check(timed.messages.count == 1, "Muse startup diagnostics are suppressed")
    check(Store.visibleText(#"{"chunk_id":"exec-1","command":"date","output":"Monday\n","terminal_status":"completed"}"#) == "Monday", "Tool JSON unwraps to command output")
    timed.lastOutputAt = ProcessInfo.processInfo.systemUptime - 20
    store.consume(#"{"payload_type":"run.terminal.completed","payload":{"text":"First line"}}"#, session: timed, responseID: r)
    check(timed.messages[0].delays?.count == 1 && timed.messages[0].delays?[0].offset == 0 && Store.delayLabel(timed.messages[0].delays![0].seconds) == "[20 sec]", "First response shows delay since Return")
    timed.lastOutputAt = ProcessInfo.processInfo.systemUptime - 630
    store.consume(#"{"payload_type":"text.delta","payload":{"delta":" Next line"}}"#, session: timed, responseID: r)
    check(timed.messages[0].delays?.count == 2 && timed.messages[0].delays?[1].offset == 10 && Store.delayLabel(630) == "[10.5 minutes]", "Later output gaps get inline minute markers")
    store.consume(#"{"payload_type":"text.delta","payload":{"delta":" quickly"}}"#, session: timed, responseID: r)
    check(timed.messages[0].delays?.count == 2, "Short gaps produce no marker")
    let exact = Session(entry: entry); exact.messages = [Message(role: "assistant", text: "Answer")]; exact.lastOutputAt = 100
    store.activity("hidden tool output", session: exact)
    check(exact.lastOutputAt == 100, "Hidden tool output does not reset response delay")
    store.markOutput(exact, index: 0, offset: 0, now: 110)
    check(exact.messages[0].delays?.first?.seconds == 10 && Store.delayLabel(10) == "[10 sec]", "Delay threshold includes exactly ten seconds")
    let timedView = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    let timedCoordinator = ScrollingConversation.Coordinator(exact); timedCoordinator.render(timedView)
    check(timedView.string == "[10 sec] Answer\n" && timedView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.gray, "Delay prefix is grey and tool output is hidden")
    store.updateReportedStatus(["payload": ["models": [["model": "test-model", "input_tokens": 120, "output_tokens": 30]], "reasoning_effort": "high", "approval_mode": "on-request"]], session: exact)
    check(exact.toolStatus.model == "test-model" && exact.toolStatus.effort == "high" && exact.toolStatus.access == "on-request" && exact.toolStatus.usage == "120 in / 30 out", "Status reflects reported model, effort, access and usage")
    let probeConfig: [String: Any] = ["model": "saved-model", "model_reasoning_efforts": ["retained-model": "max"]]
    let probeSession: [String: Any] = ["modelId": "retained-model", "approvalMode": ["mode": "onRequest"]]
    let probeRecords: [[String: Any]] = [
        ["payload_type": "runtime.session.permission_profile_committed", "payload": ["source": ["display_name": "Auto-review"]]],
        ["payload": ["outcome": ["kind": "top_level_turn_started"]]],
        ["payload": ["event": ["kind": "model_completed", "usage": ["input_tokens": 100, "output_tokens": 10]]]],
        ["payload": ["outcome": ["kind": "top_level_turn_started"]]],
        ["payload": ["event": ["kind": "model_completed", "usage": ["input_tokens": 200, "output_tokens": 20]]]],
        ["payload": ["event": ["kind": "model_completed", "usage": ["input_tokens": 300, "output_tokens": 30]]]],
        ["payload": ["event": ["kind": "model_request_configured", "reminder_roster": ["agents": [["reasoning_effort": "low", "model": "child-model"]]]]]]
    ]
    let probe = MuseStatusProbe.resolve(config: probeConfig, session: probeSession, records: probeRecords, quota: nil)
    check(probe.status.model == "retained-model" && probe.status.effort == "max (config)", "Retained model wins over saved config without confusing child effort")
    check(probe.status.access == "Auto-review / onRequest" && probe.status.usage == "500 in / 50 out" && probe.status.totalUsage == "600 in / 60 out", "Read-only probe resolves access and sums all model calls per turn and session")
    let quotaText = MuseStatusProbe.quotaSummary(["tier": "test", "window": ["usedPercent": 25, "windowDurationMins": 300], "weekly": ["usedPercent": 12], "observedAtMs": 0])
    check(quotaText.contains("25%") && !quotaText.contains("{"), "Quota is readable text, not JSON")
    let ttyQuota = MuseQuota.parse("\u{001B}[17;1H│ Weekly 2% used · Resets Nov 1 at 4:00 PM │\n│ Current 7% used · Resets at 10:42 PM │")
    check(ttyQuota?.contains("Weekly 2% used · resets Nov 1 at 4:00 PM") == true && ttyQuota?.contains("Current 7%") == true && ttyQuota?.contains("\u{001B}") == false, "CLI quota parsing preserves weekly percent and reset time without terminal escapes")
    check(MuseQuota.parse("Weekly: unavailable") == nil, "Unavailable quota is never presented as zero")
    let fresh = Session(entry: entry)
    store.changeSetting(fresh, .effort("max"))
    check(fresh.choices.effort == "max" && fresh.toolStatus.effort == "max" && fresh.process == nil, "New-session setting is scoped and saved without starting a turn")
    let commandID = MuseStatusProbe.commandID()
    check(UUID(uuidString: commandID) != nil && commandID.split(separator: "-")[2].first == "7", "Session mutation IDs are UUIDv7")
    let local = Session(entry: entry); local.draft = "/help"; store.send(local)
    check(!local.busy && local.process == nil && local.messages.last?.text.contains("/usage") == true, "Local slash commands do not submit model prompts")
    let localView = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    let localCoordinator = ScrollingConversation.Coordinator(local)
    localCoordinator.render(localView)
    local.messages[local.messages.count - 1].text = "A different length status reply"
    localCoordinator.render(localView)
    check(localView.selectedRange().location == (localView.string as NSString).length, "Asynchronous local replies leave the cursor at current input")
    let markdown = MarkdownText.render("## Key decisions\n\n**Bold** and `code` with [a link](https://example.com).\n\n| Decision | Recommendation |\n| --- | --- |\n| Repo | **public** |\n| Language | Python |\n\n- First item\n\n```swift\nlet literal = \"**not bold**\"\n```\n")
    check(!markdown.string.contains("| ---") && !markdown.string.contains("##") && markdown.string.contains("• First item"), "Markdown headings, lists and table syntax render without delimiters")
    let boldRange = (markdown.string as NSString).range(of: "Bold")
    let boldFont = markdown.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
    check(boldFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "Markdown emphasis produces a bold font")
    let tableRange = (markdown.string as NSString).range(of: "Recommendation")
    let tableStyle = markdown.attribute(.paragraphStyle, at: tableRange.location, effectiveRange: nil) as? NSParagraphStyle
    check(tableStyle?.textBlocks.first is NSTextTableBlock, "Markdown pipe tables become native Mac table cells")
    let linkRange = (markdown.string as NSString).range(of: "a link")
    check(markdown.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"), "Markdown link labels keep clickable URL attributes")
    check(markdown.string.contains("**not bold**") && !markdown.string.contains("```"), "Fenced code is literal and loses fence markers")
    let tableSession = Session(entry: entry)
    tableSession.messages = [Message(role: "assistant", text: "| A | B |\n| --- | --- |\n| one | two |")]
    let tableView = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    let tableCoordinator = ScrollingConversation.Coordinator(tableSession)
    tableView.delegate = tableCoordinator; tableCoordinator.render(tableView); tableView.focusInput()
    tableView.insertText("next input", replacementRange: tableView.selectedRange())
    let inputStyle = tableView.textStorage?.attribute(.paragraphStyle, at: tableView.inputStart, effectiveRange: nil) as? NSParagraphStyle
    check(tableSession.draft == "next input" && inputStyle?.textBlocks.isEmpty != false, "Input after a rendered table stays outside table cells")
    let copyBoard = NSPasteboard.withUniqueName()
    tableView.copyBlock(0, to: copyBoard)
    let copiedRTF = copyBoard.data(forType: .rtf).flatMap { try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
    check(copyBoard.string(forType: .string)?.contains("| --- |") == true && copiedRTF?.string.contains("one") == true && copyBoard.data(forType: .html) != nil, "Whole-response copy exports original Markdown and rich RTF/HTML")
    copyBoard.releaseGlobally()
    let c = Session(entry: Entry(name: "Claude", command: "claude", directory: "~", engine: "claude"))
    c.messages.append(Message(id: r, role: "assistant", text: ""))
    store.consume(#"{"type":"assistant","session_id":"test-session","message":{"content":[{"type":"text","text":"Hello"}]}}"#, session: c, responseID: r)
    store.consume(#"{"type":"result","result":"Hello world"}"#, session: c, responseID: r)
    check(c.messages.last?.text == "Hello world" && c.remoteID == "test-session", "Claude response deduplication and session identity")
    let x = Session(entry: Entry(name: "Codex", command: "codex", directory: "~", engine: "codex"))
    x.messages.append(Message(id: r, role: "assistant", text: ""))
    store.consume(#"{"type":"thread.started","thread_id":"thread-123"}"#, session: x, responseID: r)
    store.consume(#"{"type":"item.completed","item":{"type":"agent_message","text":"Done"}}"#, session: x, responseID: r)
    check(x.remoteID == "thread-123" && x.messages.last?.text == "Done", "Codex structured response and resume identity")
    let image = NSImage(size: NSSize(width: 16, height: 16)); image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 16, height: 16).fill(); image.unlockFocus()
    store.attach(s, image: image)
    check(s.attachments.count == 1 && FileManager.default.fileExists(atPath: s.attachments[0]), "Pasted image saved as PNG")
    let imageBoard = NSPasteboard.withUniqueName()
    let pngImage = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    imageBoard.setData(pngImage, forType: .png)
    check(ConversationTextView.clipboardImage(imageBoard) != nil, "PNG-only clipboard is recognized without a text representation")
    let originalClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item -> NSPasteboardItem in
        let copy = NSPasteboardItem(); for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }; return copy
    }
    NSPasteboard.general.clearContents(); NSPasteboard.general.setData(pngImage, forType: .png)
    let pasteView = ConversationTextView(frame: .zero); var pastedImage = false
    pasteView.imagePaste = { _ in pastedImage = true }
    let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    check(pasteView.validateUserInterfaceItem(pasteItem), "Paste command stays enabled for image-only clipboard")
    pasteView.paste(nil)
    check(pastedImage, "Image-only Cmd-V routes to attachment handler")
    NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(originalClipboard); imageBoard.releaseGlobally()
    let interactive = Session(entry: Entry(name: "Muse echo", command: "muse", directory: NSTemporaryDirectory(), engine: "muse"))
    interactive.busy = true; let interactiveID = UUID(); interactive.messages = [Message(id: interactiveID, role: "assistant", text: "")]
    store.sendMuse(interactive, prompt: "offline msp", display: "offline msp", images: [], responseID: interactiveID, serverArguments: ["--provider", "echo"])
    let interactiveDeadline = Date().addingTimeInterval(20)
    while interactive.busy && Date() < interactiveDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(!interactive.busy && interactive.status == "Ready" && interactive.messages.contains { $0.text == "echo: offline msp" }, "Real interactive Muse streams text and finishes on turn/completed")
    let fixturePath = FileManager.default.currentDirectoryPath + "/Tests/msp_fixture.py"
    let fixture = Session(entry: Entry(name: "Fixture", command: "/usr/bin/python3 '" + fixturePath + "'", directory: NSTemporaryDirectory(), engine: "muse"))
    fixture.busy = true; let fixtureID = UUID(); fixture.messages = [Message(id: fixtureID, role: "assistant", text: "")]
    store.sendMuse(fixture, prompt: "fixture", display: "fixture", images: [], responseID: fixtureID)
    let approvalDeadline = Date().addingTimeInterval(10)
    while fixture.requests.isEmpty && fixture.busy && Date() < approvalDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(fixture.status == "Waiting for your approval" && fixture.requests.first?.kind == "approval", "Approval request reaches conversation instead of hiding behind Working")
    if let request = fixture.requests.first { store.answerMuse(fixture, request: request, choice: "allow-once") }
    let questionDeadline = Date().addingTimeInterval(10)
    while fixture.requests.first?.kind != "question" && fixture.busy && Date() < questionDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(fixture.status == "Waiting for your answer" && fixture.requests.first?.kind == "question", "Question request remains visible and blocks until the user answers")
    if let request = fixture.requests.first { store.answerMuse(fixture, request: request, answers: [["questionId": "single", "selectedLabel": "B"], ["questionId": "multiple", "selectedLabels": ["X", "Y"]], ["questionId": "free", "freeText": "hello"]]) }
    let fixtureDeadline = Date().addingTimeInterval(10)
    while fixture.busy && Date() < fixtureDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(!fixture.busy && fixture.status == "Ready" && fixture.requests.isEmpty && fixture.messages.contains { $0.text == "Waiting for permission." }, "Approval choice, exact stage guard, presentation receipts and all question answer modes round-trip")
    let config = WKWebViewConfiguration(); config.setURLSchemeHandler(AttachmentHandler(), forURLScheme: "attachment")
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: config)
    web.loadHTMLString(transcriptHTML, baseURL: nil)
    let loadDeadline = Date().addingTimeInterval(10)
    while web.isLoading && Date() < loadDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    let sample = [Message(role: "assistant", text: "See https://example.com/path.\n**Bold** and `code`\n```swift\nlet x = 1\n```\n<script>unsafe</script>", images: s.attachments)]
    let sampleJSON = String(data: try! JSONEncoder().encode(sample), encoding: .utf8)!
    var dom: [String: Any]?
    web.evaluateJavaScript("render(\(sampleJSON)); ({url:document.querySelector('a').href,code:document.querySelector('pre code').textContent,bold:document.querySelector('strong').textContent,scripts:document.querySelectorAll('script').length})") { result, error in
        dom = result as? [String: Any]
        if let error { print(error) }
    }
    let domDeadline = Date().addingTimeInterval(10)
    while dom == nil && Date() < domDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    check(dom?["url"] as? String == "https://example.com/path", "Rendered URLs are real links with punctuation excluded")
    check((dom?["code"] as? String)?.contains("let x = 1") == true && dom?["bold"] as? String == "Bold", "Code blocks and bold render")
    check(dom?["scripts"] as? Int == 1, "Assistant HTML remains inert text")
    s.attachments = []; s.messages = []; s.draft = "hello 'quoted' $(literal) https://example.com"
    store.send(s)
    let deadline = Date().addingTimeInterval(20)
    while s.busy && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    check(!s.busy && s.started && s.messages.contains { $0.role == "assistant" && $0.text.contains("echo: hello 'quoted' $(literal)") }, "Real Muse headless turn and safe prompt quoting")
    s.draft = "second turn"; store.send(s)
    let second = Date().addingTimeInterval(20)
    while s.busy && Date() < second { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    check(!s.busy && s.messages.contains { $0.text == "echo: second turn" }, "Real Muse session resume")
    s.draft = "saved draft"; store.save()
    let loaded = Store()
    check(loaded.sessions.contains { $0.id == s.id && $0.draft == "saved draft" && $0.messages.count == s.messages.count }, "Transcript and draft survive reload")
    let localProbe = Session(SavedSession(id: s.id, entry: Entry(name: "Muse", command: "muse", directory: NSTemporaryDirectory(), engine: "muse"), title: "Probe", messages: [], draft: "/usage", attachments: [], remoteID: nil, started: true))
    store.send(localProbe)
    let probeDeadline = Date().addingTimeInterval(12)
    while localProbe.probingStatus && Date() < probeDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    check(!localProbe.busy && !localProbe.probingStatus && localProbe.process == nil && localProbe.messages.last?.text.contains("Session total: 0 in / 0 out") == true, "Real read-only Muse session query and local /usage work without a turn")
    do {
        let changed = try MuseStatusProbe.query(entry: Entry(name: "Muse", command: "muse", directory: NSTemporaryDirectory(), engine: "muse"), sessionID: s.id.uuidString, change: .effort("max"), serverArguments: ["--provider", "echo"])
        check(changed.status.effort == "max", "Real Muse setter persists session effort without a model turn")
        let access = try MuseStatusProbe.query(entry: Entry(name: "Muse", command: "muse", directory: NSTemporaryDirectory(), engine: "muse"), sessionID: s.id.uuidString, change: .access(":read-only"), serverArguments: ["--provider", "echo"])
        check(access.status.access.lowercased().contains("read"), "Real Muse permission-profile setter persists access without a model turn")
    } catch { check(false, "Muse session effort setter: " + error.localizedDescription) }
    _ = NSApplication.shared
    let deleteDelegate = AppDelegate(); AppDelegate.shared = deleteDelegate
    let deleteWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let deleteState = WindowState()
    deleteDelegate.windows = [(deleteWindow, deleteState)]
    let disposable = store.create(entry); disposable.title = "Recovery check"; disposable.draft = "keep this draft"
    Workspace.shared.assign(disposable.id, to: deleteState.id, pane: 1)
    store.deleteSession(disposable)
    check(!store.sessions.contains { $0.id == disposable.id }, "Deleting a conversation removes it from the active sidebar")
    check(deleteDelegate.windows.count == 1 && Workspace.shared.placements[disposable.id] == nil, "Close Conversation keeps the window open and clears its pane")
    let restored = store.restoreDeleted()
    check(restored?.id == disposable.id && restored?.draft == "keep this draft", "Deleted conversations can be restored with their drafts")
    print("All checks passed")
}
signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--probe-muse-quota") {
    do { print(try MuseQuota.query(entry: Entry(name: "Muse", command: "muse", directory: "~", engine: "muse"))); exit(0) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if let at = CommandLine.arguments.firstIndex(of: "--probe-muse-status"), CommandLine.arguments.count > at + 1 {
    do { print(try MuseStatusProbe.query(entry: Entry(name: "Muse", command: "muse", directory: "~", engine: "muse"), sessionID: CommandLine.arguments[at + 1]).detail); exit(0) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if let at = CommandLine.arguments.firstIndex(of: "--probe-provider-status"), CommandLine.arguments.count > at + 2 {
    let engine = CommandLine.arguments[at + 1], directory = CommandLine.arguments[at + 2]
    guard ["codex", "claude"].contains(engine) else { exit(2) }
    do {
        let snapshot = try ProviderStatus.query(entry: Entry(name: engine, command: engine, directory: "~", engine: engine, accountDirectory: directory), remoteID: nil)
        print(snapshot.detail)
        print("Catalog: " + snapshot.models.map { $0.id + " [" + $0.efforts.joined(separator: ", ") + "]" }.joined(separator: "; "))
        exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--provider-self-test") {
    guard ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil, ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"] != nil else { fputs("Use test.sh --providers-only for isolated tests.\n", stderr); exit(2) }
    providerSelfTests { value, label in if !value { fputs("FAIL: " + label + "\n", stderr); exit(1) }; print("PASS: " + label) }
    print("All provider checks passed"); exit(0)
}
if CommandLine.arguments.contains("--self-test") { selfTest(); exit(0) }
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
