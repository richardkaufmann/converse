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
    var useDefaultAccountStore: Bool? = nil
}
struct DelayMark: Codable, Equatable { var offset: Int; var seconds: Double }
struct Message: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String
    var text: String
    var images: [String] = []
    var delays: [DelayMark]? = nil
    // Codex JSONL combines progress and answer events. Only its authoritative
    // --output-last-message result is eligible for switchboard execution.
    var finalReply: String? = nil
    // Older archives have no message times. Leave those unknown on decode.
    var createdAt: Date? = Date()
}
struct ToolStatus: Codable {
    var model = "not reported"
    var effort = "CLI default"
    var access = "CLI default"
    var approval: String? = nil
    var usage = "not reported"
    var totalUsage: String? = nil
    var quota: String? = nil
    var accountUsage: AccountUsage? = nil
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
    var switchboardObligations: [SwitchboardObligation]? = nil
    var switchboardExpectations: [SwitchboardExpectation]? = nil
    var switchboardLastRecoveryAt: Date? = nil
    var createdAt: Date? = nil
    var titleUpdatedAt: Date? = nil
    var agent: AgentConfig? = nil
    var compactionInProgress: Bool? = nil
    var lastCompactedAt: Date? = nil
    var supportTeachingVersion: Int? = nil
    var supportAssistant: Bool? = nil
    var clearedThroughMessageID: UUID? = nil
}
final class Session: ObservableObject, Identifiable {
    let id: UUID
    var supportTeachingVersion: Int? = nil
    var supportAssistant = false
    var supportProbeCompletion: ((Bool) -> Void)?
    var supportPendingCommand: AppSupportCommand?
    var supportActionCount = 0
    var supportContinuation = false
    var supportAutonomous = false
    @Published var entry: Entry
    @Published var agent: AgentConfig? = nil { didSet { if oldValue != agent { agentChanged?(oldValue, agent) } } }
    var agentChanged: ((AgentConfig?, AgentConfig?) -> Void)?
    var isAgentSession: Bool { entry.engine == "agent" || agent != nil }
    var needsAgentSetup: Bool { entry.engine == "agent" && agent == nil }
    static let missingAgentSettings = "Agent settings are missing. Open Agent Setup to review and save its configuration. No CLI sign-in is needed."
    @Published var title: String { didSet {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = "New conversation" }
        if title != oldValue { titleUpdatedAt = Date(); identityChanged?() }
    } }
    var createdAt: Date
    var titleUpdatedAt: Date
    var identityChanged: (() -> Void)?
    var identityPath: String?
    var identityError = ""
    var messagesRevision: UInt64 = 0
    @Published var messages: [Message] { didSet { messagesRevision &+= 1 } }
    @Published var clearedThroughMessageID: UUID? = nil { didSet { messagesRevision &+= 1 } }
    var displayedMessages: [Message] {
        guard let id = clearedThroughMessageID, let index = messages.firstIndex(where: { $0.id == id }) else { return messages }
        return Array(messages.dropFirst(index + 1))
    }
    // Presentation metadata supplied by a remote home; never persisted as a
    // second transcript. Local sessions derive their sequence from messages.
    var messageNumbers: [UUID: Int] = [:] { didSet { if messageNumbers != oldValue { messagesRevision &+= 1 } } }
    var messageNumberOffset = 0 { didSet { if messageNumberOffset != oldValue { messagesRevision &+= 1 } } }
    private var numberedMessagesRevision: UInt64?
    private var cachedMessageNumbers: [UUID: Int] = [:]
    func transcriptMessageNumbers() -> [UUID: Int] {
        if numberedMessagesRevision != messagesRevision {
            cachedMessageNumbers = Store.transcriptMessageNumbers(messages)
            numberedMessagesRevision = messagesRevision
        }
        return cachedMessageNumbers
    }
    @Published var draft: String
    let substitutionFeedback = SubstitutionFeedback()
    @Published var attachments: [String]
    @Published var pending: [PendingPrompt] = []
    @Published var queuePaused = false
    @Published var switchboardEnabled = false
    var switchboardHandled: [UUID] = []
    @Published var switchboardObligations: [SwitchboardObligation] = []
    var switchboardExpectations: [SwitchboardExpectation] = []
    var switchboardLastRecoveryAt: Date?
    var switchboardProgress: (revision: UInt64, at: Date)?
    var switchboardTurnStart: Int?
    var switchboardHop = 0
    var interrupted = false
    var resumeAfterInterrupt = false
    // An assistant response landed while this session sat in no local pane.
    // Transient presentation state: never archived, cleared on take (1/2/3).
    @Published var unseenResponse = false
    // An agent loop Richard did not leave running: red in the sidebar.
    var agentLoopPaused: Bool { agent != nil && agent?.enabled == false }
    // The row answers why it is paused: live attention first, then the last
    // recorded outcome, with a plain pointer for loops that never ran.
    var pausedLoopReason: String? {
        guard agentLoopPaused, let agent else { return nil }
        if !agent.attention.isEmpty { return agent.attention }
        if agent.lastOutcome.isEmpty || agent.lastOutcome == "Not run yet" { return "Never run — enable the loop in Agent Setup." }
        return agent.lastOutcome
    }
    // Remote viewers' unseen marker: the newest assistant response this home
    // holds. A running turn's partial reply never counts until it finishes.
    var lastResponseAt: Date? { Session.lastResponseAt(messages, busy: busy) }
    static func lastResponseAt(_ messages: [Message], busy: Bool) -> Date? {
        var candidates = messages[...]
        if busy, let turn = messages.lastIndex(where: { $0.role == "user" }) { candidates = messages[..<turn] }
        return candidates.last { $0.role == "assistant" && (!$0.text.isEmpty || !$0.images.isEmpty) }?.createdAt
    }
    // A Parking Lot Talk helper with nothing going on stays out of the
    // sidebar; the lot's Talk button reopens it. Busy or queued helpers stay
    // listed so their work can always be reached.
    var isIdleTalkSession: Bool { agent?.parkingLotTalkID != nil && !busy && pending.isEmpty }
    @Published var injectionNotice = ""
    // Momentary share confirmation shown as a row, never a modal alert.
    @Published var shareNotice = ""
    var injectionTargetID: UUID?
    var injectionAll = false
    var turnFailed = false
    @Published var accountStatus = ""
    @Published var probeError = ""
    @Published var needsSignIn = false
    @Published var compactionRequested = false
    @Published var compacting = false
    var lastCompactedAt: Date?
    var claudeLastContext: (model: String, tokens: Int)?
    @Published var busy = false
    @Published var status = "Ready"
    var retryDetail: String?
    @Published var toolStatus = ToolStatus()
    var remoteID: String? { didSet { if remoteID != oldValue { identityChanged?() } } }
    var started: Bool
    var choices = SessionChoices()
    @Published var modelChoices: [MuseModelChoice] = []
    @Published var accessChoices: [MuseAccessChoice] = []
    @Published var changingSetting = false
    @Published var settingNotice = ""
    var settingRevision = 0
    var sidebarProbeAttemptAt: Date?
    var quotaRefreshedAt: Date?
    var probingStatus = false
    var statusCallbacks: [() -> Void] = []
    var needsApproval: Bool {
        agent?.attention.isEmpty == false || requests.contains { $0.kind == "approval" } ||
        (status.hasPrefix("Waiting") && (status.localizedCaseInsensitiveContains("approval") || status.localizedCaseInsensitiveContains("permission")))
    }
    var statusDetails = ""
    var lastOutputAt: TimeInterval?
    var streamedText = false
    var claudeTextBlockPending = false
    var claudeStreamSeparators: [NSRange] = []
    var claudeBackgroundTasks: [String: String] = [:]
    var process: Process?
    var muse: MuseConnection?
    var museClosing = false
    @Published var requests: [MuseRequest] = []
    var requestAnswers = MuseRequestAnswers()
    @Published var requestError = ""
    @Published var answeringRequest = false
    var answerRequestToken = UUID()
    var museItems: [String: UUID] = [:]
    var web: WKWebView?
    var textScrollOrigin: NSPoint?
    var textSelection: NSRange?
    weak var inputTextView: ConversationTextView?
    init(_ saved: SavedSession) {
        createdAt = saved.createdAt ?? Date(); titleUpdatedAt = saved.titleUpdatedAt ?? saved.createdAt ?? Date()
        id = saved.id; entry = saved.entry; title = saved.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New conversation" : saved.title; messages = saved.messages; agent = saved.agent
        supportTeachingVersion = saved.supportTeachingVersion; supportAssistant = saved.supportAssistant ?? false
        clearedThroughMessageID = saved.clearedThroughMessageID
        toolStatus = saved.toolStatus ?? ToolStatus()
        accountStatus = saved.toolStatus?.account ?? ""
        lastCompactedAt = saved.lastCompactedAt
        choices = saved.choices ?? SessionChoices()
        switchboardEnabled = saved.switchboardEnabled ?? false; switchboardHandled = saved.switchboardHandled ?? []
        switchboardLastRecoveryAt = saved.switchboardLastRecoveryAt
        switchboardObligations = saved.switchboardObligations ?? []; switchboardExpectations = saved.switchboardExpectations ?? []
        // An interrupted supervised turn is uncertain after restart, never auto-replayed.
        pending = saved.pending ?? []; queuePaused = !(saved.pending ?? []).isEmpty
        draft = saved.draft; attachments = saved.attachments; remoteID = saved.remoteID; started = saved.started
        // A submitted reply already reached this transcript; only its turn was cut short.
        // Before "interrupted" existed, that was the sole path to a failed reply.
        for index in switchboardObligations.indices where switchboardObligations[index].kind == "reply" &&
            (switchboardObligations[index].state == "failed" || (switchboardObligations[index].state == "submitted" && switchboardObligations[index].finishedAt == nil)) {
            switchboardObligations[index].state = "interrupted"
        }
        for index in switchboardObligations.indices where switchboardObligations[index].state == "submitted" && switchboardObligations[index].finishedAt == nil { switchboardObligations[index].state = "cancelled" }
        if saved.compactionInProgress == true {
            queuePaused = true
            messages.append(Message(role: "notice", text: "Compaction was interrupted when Converse closed. Its completion is unknown; it will not be retried automatically. Your transcript and draft are retained."))
        }
    }
    convenience init(entry: Entry) {
        self.init(SavedSession(id: UUID(uuidString: MuseStatusProbe.commandID())!, entry: entry, title: "New conversation", messages: [], draft: "", attachments: [], remoteID: nil, started: false))
    }
    var saved: SavedSession { SavedSession(id: id, entry: entry, title: title, messages: messages, draft: draft, attachments: attachments, remoteID: remoteID, started: started, toolStatus: toolStatus, choices: choices, pending: pending, switchboardEnabled: switchboardEnabled, switchboardHandled: switchboardHandled, switchboardObligations: switchboardObligations, switchboardExpectations: switchboardExpectations, switchboardLastRecoveryAt: switchboardLastRecoveryAt, createdAt: createdAt, titleUpdatedAt: titleUpdatedAt, agent: agent, compactionInProgress: compacting, lastCompactedAt: lastCompactedAt, supportTeachingVersion: supportTeachingVersion, supportAssistant: supportAssistant, clearedThroughMessageID: clearedThroughMessageID) }
}
struct Archive: Codable { var entries: [Entry]; var sessions: [SavedSession]; var accounts: [AccountProfile]? = nil; var setupCompleted: Bool? = nil; var groupTellReceipts: [GroupTellReceipt]? = nil; var participantReceipts: [ParticipantMutationReceipt]? = nil }
final class Store: ObservableObject {
    static func transcriptMessageNumbers(_ messages: [Message]) -> [UUID: Int] {
        var result: [UUID: Int] = [:], number = 0
        for message in messages where message.role != "activity" {
            guard TranscriptStyle.blockContentLength(visibleText(message.text)) > 0 || !message.images.isEmpty else { continue }
            number += 1; result[message.id] = number
        }
        return result
    }
    static let shared = Store()
    @Published var lineNumbers = UserDefaults.standard.object(forKey: "lineNumbers") as? Bool ?? true { didSet { UserDefaults.standard.set(lineNumbers, forKey: "lineNumbers") } }
    @Published var setupCompleted = false
    @Published var accounts: [AccountProfile] = []
    @Published var entries: [Entry] = []
    @Published var sessions: [Session] = []
    let folder: URL
    let configurationAudit: ConfigurationAudit
    var includesLocalContext = ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] == nil
    var startAgentRun: ((Session, UUID) -> Void)?
    let responseImageLoader = ResponseImageLoader()
    private(set) var applicationQuitting = false
    var usesInteractiveMuse = ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] == nil
    let identityFolder: URL
    var loginFileOpener: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var participantReceipts: [ParticipantMutationReceipt] = []
    var groupTellReceipts: [GroupTellReceipt] = []
    var switchboardService: DeviceSyncService?
    var participantService: DeviceSyncService { switchboardService ?? .shared }
    var pendingSave: DispatchWorkItem?
    init(folder: URL? = nil) {
        self.folder = folder ?? ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Converse")
        identityFolder = (folder != nil || ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"] != nil) ? self.folder.appendingPathComponent("SessionIdentity") : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".converse/sessions")
        configurationAudit = ConfigurationAudit(folder: self.folder)
        accounts = AccountProfile.defaults(dataFolder: self.folder)
        do {
            try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            let archiveData = try Data(contentsOf: self.folder.appendingPathComponent("sessions.json"))
            let archive = try JSONDecoder().decode(Archive.self, from: archiveData)
            participantReceipts = archive.participantReceipts ?? []
            groupTellReceipts = archive.groupTellReceipts ?? []
            setupCompleted = archive.setupCompleted ?? true
            entries = archive.entries; sessions = archive.sessions.map(Session.init)
            configurationAudit.loaded(sessions, data: archiveData)
            accounts = archive.accounts ?? accounts
            for session in sessions where session.entry.accountID == nil {
                if let profile = accounts.first(where: { $0.id == session.entry.engine + "-default" }) {
                    session.entry.accountID = profile.id; session.entry.accountName = profile.name; session.entry.accountDirectory = profile.directory; session.entry.useDefaultAccountStore = profile.useDefaultStore
                }
            }
            // Import an explicit CLI-default authentication selection used by
            // older versions, replacing its command override with a binding.
            for session in sessions where session.entry.engine == "claude" && session.entry.command == "env -u CLAUDE_CONFIG_DIR claude" {
                let profile = accounts.first { $0.engine == "claude" && $0.useDefaultStore == true } ?? AccountProfile(id: "claude-cli-auth-default", name: "CLI default login", engine: "claude", directory: NSHomeDirectory() + "/.claude", useDefaultStore: true)
                if !accounts.contains(where: { $0.id == profile.id }) { accounts.append(profile) }
                session.entry.command = "claude"
                session.entry.accountID = profile.id; session.entry.accountName = profile.name
                session.entry.accountDirectory = profile.directory; session.entry.useDefaultAccountStore = true
            }
        } catch {
            configurationAudit.failure("archive_load_failed", error: error)
            if FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("sessions.json").path) {
                DispatchQueue.main.async { let alert = NSAlert(); alert.messageText = "Could not load saved conversations"; alert.informativeText = "Your saved file has been left in Application Support/Converse. \(error.localizedDescription)"; alert.runModal() }
            }
            setupCompleted = FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("sessions.json").path)
            entries = SetupCatalog.entries
        }
        for session in sessions { attachIdentity(session); importResponseImages(session, allowRemote: false) }
        // Replace a sender's stale "failed"/"processing" receipt for replies reclassified on load.
        for session in sessions where session.switchboardObligations.contains(where: { $0.state == "interrupted" }) { refreshSwitchboardReceipts(session) }
        if !sessions.isEmpty { save() }
    }
    deinit { configurationAudit.record("store_closed") }
    func attachIdentity(_ session: Session) {
        session.agentChanged = { [weak self, weak session] old, new in
            guard let self, let session else { return }
            self.configurationAudit.agentChanged(id: session.id, old: old, new: new)
        }
        session.identityChanged = { [weak self, weak session] in
            guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
            self.syncIdentity(session); self.save()
        }
        syncIdentity(session)
    }
    func saveSoon(file: String = #fileID, line: Int = #line, function: String = #function) {
        pendingSave?.cancel()
        let task = DispatchWorkItem { self.save(file: file, line: line, function: function) }; pendingSave = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }
    func saveChecked(file: String = #fileID, line: Int = #line, function: String = #function) throws {
        let source = "\(file):\(line) \(function)"
        let began = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            if elapsed > 0.15 { NSLog("Converse slow archive save: %.0f ms at %@", elapsed * 1000, source) }
        }
        do {
            let data = try JSONEncoder().encode(Archive(entries: entries, sessions: sessions.map(\.saved), accounts: accounts, setupCompleted: setupCompleted, groupTellReceipts: groupTellReceipts, participantReceipts: participantReceipts))
            configurationAudit.willSave(sessions, data: data, source: source)
            try data.write(to: folder.appendingPathComponent("sessions.json"), options: .atomic)
            configurationAudit.didSave(sessions)
        } catch {
            configurationAudit.failure("archive_save_failed", error: error, source: source)
            throw error
        }
    }
    func save(file: String = #fileID, line: Int = #line, function: String = #function) {
        do { try saveChecked(file: file, line: line, function: function) }
        catch { NSLog("Save failed: %@", error.localizedDescription) }
    }
    func create(_ entry: Entry, persist: Bool = true) -> Session {
        var entry = entry
        if entry.accountDirectory == nil, let profile = (entry.accountID.flatMap { id in accounts.first { $0.id == id && $0.engine == entry.engine } } ?? (entry.accountID == nil ? preferredLogin(engine: entry.engine) : nil)) {
            entry.accountID = profile.id; entry.accountName = profile.name; entry.accountDirectory = profile.directory; entry.useDefaultAccountStore = profile.useDefaultStore
        }
        let s = Session(entry: entry); sessions.append(s); attachIdentity(s); if persist { save() }; return s
    }
    func stop(_ s: Session) {
        MainActor.assumeIsolated { if AgentConversation.shared.owns(s) { AgentConversation.shared.stop(resumeQueued: false) } }
        s.compactionRequested = false
        s.queuePaused = true; s.resumeAfterInterrupt = false
        if s.injectionTargetID != nil { s.injectionNotice = "Injection paused. Your prompt remains queued." }
        interruptProcess(s)
    }
    func interruptProcess(_ s: Session) {
        guard s.busy, !s.interrupted else { return }
        s.interrupted = true
        if s.agent != nil { MainActor.assumeIsolated { AgentRuntime.shared.cancel(s) }; s.status = "Stopping…"; return }
        if let muse = s.muse {
            s.status = "Stopping…"
            muse.interrupt { [weak self, weak s] in
                guard let self, let s, s.muse === muse else { return }
                self.finishMuse(s, status: "Interrupted", notice: "Muse did not finish interrupting; its local host was stopped. The saved conversation, queued input and draft were retained.")
            }
            return
        }
        guard let p = s.process, p.isRunning else { return }
        s.status = "Stopping…"; p.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if p.isRunning { s.status = "Still stopping… · queued input is held" } }
    }
    // A share confirmation lives as a momentary row for ten seconds, never a
    // modal alert. A newer notice replaces an older one and gets its own
    // ten seconds: the timer only clears the text it set.
    func flashShareNotice(_ s: Session, _ text: String) {
        s.shareNotice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak s] in
            if s?.shareNotice == text { s?.shareNotice = "" }
        }
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
    func removeDraftImage(_ s: Session, path: String) {
        guard let index = s.attachments.firstIndex(of: path) else { return }
        s.attachments.remove(at: index); saveSoon()
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
    @discardableResult
    func injectPending(_ s: Session, id: UUID? = nil) -> String? {
        func refused(_ detail: String) -> String {
            if s.messages.last?.role != "notice" || s.messages.last?.text != detail {
                s.messages.append(Message(role: "notice", text: detail))
            }
            saveSoon(); return detail
        }
        sanitizeGroupQueue(s)
        if s.changingSetting { return refused("Inject not applied: a session setting is still changing. Wait for its result, then try again.") }
        if s.pending.isEmpty { return refused("Inject not applied: the queue is already empty. Nothing was sent.") }
        if s.interrupted && s.resumeAfterInterrupt && s.injectionTargetID != nil {
            guard (id == nil && s.injectionAll) || id == s.injectionTargetID else {
                return refused("Inject not applied: another queued prompt is already being injected. Wait for it to start before choosing a different item.")
            }
            s.injectionNotice = "Interrupting — your queued prompt is next"; return nil
        }
        if let id {
            guard let index = s.pending.firstIndex(where: { $0.id == id }) else {
                return refused("Inject not applied: that queued item is no longer available. The queue has been refreshed; nothing else was sent.")
            }
            let prompt = s.pending.remove(at: index)
            s.pending.insert(prompt, at: 0)
        } else {
            let prompts = s.pending
            s.pending = [PendingPrompt(switchboardHop: prompts.compactMap(\.switchboardHop).max(), components: prompts.flatMap { $0.components ?? [$0] }, originParticipants: prompts.flatMap { $0.groupOrigins }, agentRunReserved: prompts.contains { $0.agentRunReserved == true }, autonomous: prompts.contains { $0.autonomous == true || $0.agentRunReserved == true }, text: prompts.map(\.text).joined(separator: "\n\n"), images: prompts.flatMap(\.images))]
        }
        s.queuePaused = false
        s.injectionTargetID = s.pending.first?.id
        s.injectionAll = id == nil
        s.injectionNotice = s.busy ? "Interrupting — your queued prompt is next" : "Starting your queued prompt…"
        if s.busy { s.resumeAfterInterrupt = true; interruptProcess(s) }
        else { runNext(s) }
        save()
        return nil
    }
    func sanitizeGroupQueue(_ session: Session) {
        var discarded = false
        func allowed(_ prompt: PendingPrompt) -> Bool { !prompt.groupOrigins.contains { !participantService.acceptsParticipant(home: $0.home, groupID: $0.group) } }
        session.pending = session.pending.compactMap { prompt in
            guard !allowed(prompt) else { return prompt }
            discarded = true
            // Inject all keeps the constituent inputs so revoking one origin
            // never discards unrelated human input combined with it.
            guard let components = prompt.components else { return nil }
            let valid = components.filter(allowed)
            guard !valid.isEmpty else { return nil }
            var repaired = prompt
            repaired.components = valid; repaired.originGroupID = nil; repaired.originHomeID = nil
            repaired.originParticipants = valid.flatMap { $0.groupOrigins }
            repaired.switchboardHop = valid.compactMap(\.switchboardHop).max()
            repaired.agentRunReserved = valid.contains { $0.agentRunReserved == true }
            repaired.autonomous = valid.contains { $0.autonomous == true }
            repaired.text = valid.map(\.text).joined(separator: "\n\n"); repaired.images = valid.flatMap(\.images)
            return repaired
        }
        if discarded {
            session.messages.append(Message(role: "notice", text: "Switchboard: queued group message discarded because its sender is no longer in this group. Unrelated local input is preserved.")); save()
        }
    }
    func runNext(_ s: Session) {
        guard !applicationQuitting else { return }
        if s.agent != nil && MainActor.assumeIsolated({ AgentConversation.shared.owns(s) }) { return }
        sanitizeGroupQueue(s)
        if !s.busy && s.pending.isEmpty && s.injectionTargetID != nil {
            s.injectionNotice = "Queued injection cancelled: that prompt is no longer in the queue."
            s.injectionTargetID = nil
        }
        if !s.busy, !s.changingSetting, s.compactionRequested { startCompaction(s); return }
        guard !s.busy, !s.changingSetting, !s.queuePaused, !s.pending.isEmpty else { return }
        // A tick queued just before a window closes must not run after that
        // window (or after a changed restriction). Its persisted reservation is
        // retained conservatively; later human input is still allowed through.
        while s.pending.first?.agentLoopTick == true,
              (try? s.agent?.scheduleRule().permits(Date())) != true {
            s.pending.removeFirst()
            s.messages.append(Message(role: "notice", text: "Skipped a queued loop check outside its schedule. Its reserved turn remains counted; no catch-up run was started."))
            save()
        }
        guard !s.pending.isEmpty else { return }
        if let config = s.agent, let next = s.pending.first,
           ((next.switchboardHop ?? 0) > 0 || next.autonomous == true), next.agentRunReserved != true {
            guard config.turnLimit > 0 else {
                s.queuePaused = true; s.agent?.attention = "Invalid per-loop turn limit. Review Agent Setup, then resume the queue."; save(); return
            }
            let previous = s.agent
            s.agent = config; s.pending[0].agentRunReserved = true
            do { try saveChecked() }
            catch { s.agent = previous; s.pending[0].agentRunReserved = false; s.queuePaused = true; s.agent?.attention = "Could not save run budget. Agent paused."; return }
        }
        // A separately edited draft stays editable while queued messages run.
        let draft = s.draft, attachments = s.attachments
        let next = s.pending.removeFirst(); s.draft = next.text; s.attachments = next.images
        send(s, switchboardHop: next.switchboardHop ?? 0, agentLoopTick: next.agentLoopTick == true, supportContinuation: next.supportContinuation == true, supportAutonomous: next.autonomous == true || next.agentLoopTick == true, clearDisplayBeforeReply: next.clearDisplayBeforeReply == true)
        if !s.busy { s.pending.insert(next, at: 0); s.queuePaused = true }
        else { switchboardStarted(s, prompt: next) }
        if s.injectionTargetID == next.id {
            if !s.busy { s.injectionNotice = "Injected prompt is held in the queue. Check the session notice before retrying." }
            else if s.entry.engine == "muse" && usesInteractiveMuse && s.agent == nil { s.injectionNotice = "Opening your injected prompt…" }
            else { confirmInjectionStarted(s) }
        }
        s.draft = draft; s.attachments = attachments; save()
    }
    func confirmInjectionStarted(_ s: Session) {
        guard !s.interrupted, let target = s.injectionTargetID, !s.pending.contains(where: { $0.id == target }) else { return }
        s.injectionNotice = "Injected prompt started."; s.injectionTargetID = nil
    }
    func assistantResponded(_ s: Session) {
        if s.injectionNotice == "Injected prompt started." { s.injectionNotice = "" }
    }
    func finishQueue(_ s: Session, success: Bool) {
        if Workspace.shared.flagsUnseenResponse(s, success: success, interrupted: s.interrupted) { s.unseenResponse = true }
        importResponseImages(s)
        finishSupportProbe(s, success: success)
        if success && !s.interrupted { processAppSupport(s); processSwitchboard(s) }
        switchboardTurnFinished(s, success: success && !s.interrupted)
        s.switchboardTurnStart = nil
        var shouldRun = s.interrupted ? s.resumeAfterInterrupt : success
        if s.interrupted && s.resumeAfterInterrupt && s.remoteID == nil && !s.started {
            shouldRun = false
            s.messages.append(Message(role: "notice", text: "Interrupted before the CLI returned a conversation ID. Your queued message is held; use Resume queue to retry."))
        }
        s.interrupted = false; s.resumeAfterInterrupt = false
        if !shouldRun { s.queuePaused = !s.pending.isEmpty; s.compactionRequested = false }
        if !shouldRun && s.injectionTargetID != nil { s.injectionNotice = "Injection did not start. Check the queued input and session notice before retrying." }
        save()
        if shouldRun { DispatchQueue.main.async { self.runNext(s) } }
    }
    func send(_ s: Session, switchboardHop: Int = 0, agentLoopTick: Bool = false, preservingAgentDraft: (text: String, images: [String])? = nil, supportContinuation: Bool = false, supportAutonomous: Bool = false, clearDisplayBeforeReply: Bool = false) {
        guard s.entry.engine != "support" else { return }
        if s.supportAssistant && !setupCompleted && s.supportProbeCompletion == nil { return }
        guard !s.needsAgentSetup else {
            s.probeError = Session.missingAgentSettings; s.status = "Agent setup required"; s.queuePaused = true
            return // Retain draft and attachments; never launch a CLI for an unconfigured agent.
        }
        if s.agent != nil && preservingAgentDraft == nil {
            MainActor.assumeIsolated { if AgentConversation.shared.owns(s) { AgentConversation.shared.stop("Voice paused for your typed question · microphone off") } }
        }
        if handleLocalCommand(s) { return }
        guard !s.busy && !s.changingSetting, !s.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !s.attachments.isEmpty else { return }
        let directory = NSString(string: s.entry.directory).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            s.messages.append(Message(role: "notice", text: "Working directory does not exist: \(directory). Change it with Configure and retry this conversation.")); return
        }
        s.interrupted = false; s.resumeAfterInterrupt = false; s.turnFailed = false; s.retryDetail = nil; s.settingNotice = ""
        let text = s.draft.isEmpty ? "Please examine the attached image." : s.draft
        let images = s.attachments
        s.supportContinuation = supportContinuation; s.supportAutonomous = supportAutonomous || agentLoopTick || preservingAgentDraft != nil
        if !supportContinuation { s.supportActionCount = 0 }
        s.supportPendingCommand = nil
        s.switchboardTurnStart = s.messages.count; s.switchboardHop = switchboardHop
        s.messages.append(Message(role: "user", text: text, images: images))
        if clearDisplayBeforeReply { clearSessionDisplay(s) }
        if s.title == "New conversation", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { s.title = String(text.prefix(45)) }
        s.draft = ""; s.attachments = []; s.busy = true; s.lastOutputAt = ProcessInfo.processInfo.systemUptime; s.streamedText = false; s.claudeTextBlockPending = false; s.claudeStreamSeparators = []; s.claudeBackgroundTasks = [:]; s.status = "Working…"
        s.claudeLastContext = nil
        let responseID = UUID(); s.messages.append(Message(id: responseID, role: "assistant", text: ""))
        if s.agent != nil {
            // Restore before any runtime/save callback: an external request must
            // never persist the transient empty composer over the human draft.
            if let draft = preservingAgentDraft { s.draft = draft.text; s.attachments = draft.images }
            if let startAgentRun { startAgentRun(s, responseID) } else { MainActor.assumeIsolated { AgentRuntime.shared.run(s, store: self, responseID: responseID, loopTick: agentLoopTick) } }
            save(); return
        }
        var args: [String] = []
        updateExplicitStatus(s)
        var prompt = text
        if s.supportTeachingVersion != nil { prompt += "\n\n" + AppSupport.instructions(agent: false) }
        if includesLocalContext {
            prompt += "\n\n" + localContext(s, directory: directory)
            let imageFolder = responseImageFolder(s)
            try? FileManager.default.createDirectory(at: imageFolder, withIntermediateDirectories: true)
            prompt += "\n[Converse image output: save images you create or download in " + imageFolder.path + "; include each as ![caption](file:///absolute/path.png) in your reply. Converse displays these in the conversation, including on remote devices. Do not open Preview or another desktop viewer.]"
        }
        if !images.isEmpty { prompt += "\n\nAttached image files (read these images):\n" + images.joined(separator: "\n") }
        if s.entry.engine == "muse" && usesInteractiveMuse {
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
        var finalOutputDirectory: URL?
        if s.entry.engine == "codex" {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("converse-final-" + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                finalOutputDirectory = directory
                args += ["--output-last-message", directory.appendingPathComponent("answer.txt").path]
            } catch {
                s.busy = false; s.status = "Failed to start"; s.queuePaused = true
                s.messages.append(Message(role: "notice", text: "Could not prepare Codex final-answer capture: " + error.localizedDescription)); save(); return
            }
        }
        let finalDirectory = finalOutputDirectory
        args += ["--", prompt]
        let p = ProviderCommand.process(entry: s.entry, arguments: args, effort: s.choices.effort)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        s.process = p; save()
        do { try p.run() } catch {
            if let finalDirectory { try? FileManager.default.removeItem(at: finalDirectory) }
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
            let finalReply = finalDirectory.flatMap { try? String(contentsOf: $0.appendingPathComponent("answer.txt"), encoding: .utf8) }
            if let finalDirectory { try? FileManager.default.removeItem(at: finalDirectory) }
            DispatchQueue.main.async {
                let retryFailure = s.retryDetail
                s.retryDetail = nil
                s.busy = false; s.process = nil
                if !s.claudeBackgroundTasks.isEmpty {
                    if !s.interrupted { s.messages.append(Message(role: "notice", text: "Claude ended this turn while still reporting work in progress: " + s.claudeBackgroundTasks.values.sorted().joined(separator: "; ") + ". No completion was reported; ask the session for its status before assuming that work finished.")) }
                    s.claudeBackgroundTasks = [:]
                }
                s.status = s.interrupted ? "Interrupted" : (p.terminationStatus == 0 && !s.turnFailed ? "Ready" : "Failed · exit \(p.terminationStatus)")
                if p.terminationStatus == 0 { s.started = true }
                if s.entry.engine == "codex", p.terminationStatus == 0, !s.turnFailed, !s.interrupted,
                   let i = s.messages.firstIndex(where: { $0.id == responseID }) {
                    s.messages[i].finalReply = finalReply
                    if s.messages[i].text.isEmpty, let finalReply {
                        s.messages[i].text = Store.visibleText(finalReply)
                    }
                    if finalReply == nil && s.switchboardEnabled {
                        s.messages.append(Message(role: "notice", text: "Switchboard: Codex final-answer capture was unavailable; no command was dispatched."))
                    }
                }
                if let i = s.messages.firstIndex(where: { $0.id == responseID }), s.messages[i].text.isEmpty { s.messages.remove(at: i) }
                if (p.terminationStatus != 0 || s.turnFailed) && !s.interrupted {
                    let output = s.messages.dropFirst(s.switchboardTurnStart ?? s.messages.count).filter { $0.role != "user" }.map(\.text).joined(separator: "\n")
                    if AccountLogin.requiresSignIn(output) { s.needsSignIn = true }
                }
                if p.terminationStatus != 0 && !s.interrupted, let retryFailure {
                    s.messages.append(Message(role: "notice", text: "Could not reconnect. Your prompt and partial reply are kept. Try again when the connection recovers.\n" + retryFailure))
                }
                if p.terminationStatus != 0 && !s.interrupted && retryFailure == nil && !s.turnFailed { s.messages.append(Message(role: "notice", text: "The command exited with status \(p.terminationStatus). See the activity messages above. For authentication, use Sign in… or /login to choose a login or authenticate in Terminal. Interactive terminal approval prompts are not supported in this version.")) }
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
            guard let self, let s, s.muse === connection else { return }
            if case .failure(let error) = result { self.finishMuse(s, status: "Connection failed", notice: error.localizedDescription); return }
            s.process = connection.process
            connection.load(entry: s.entry, choices: s.choices) { result in
                guard s.muse === connection else { return }
                if case .failure(let error) = result {
                    if MuseConnection.sessionIsInUse(error) {
                        // No turn/start was sent, so holding this exact input is
                        // safe. Never resubmit an ambiguously acknowledged turn.
                        if let index = s.messages.firstIndex(where: { $0.id == responseID }), index > 0,
                           s.messages[index - 1].role == "user", s.messages[index - 1].text == display,
                           s.messages[index - 1].images == images {
                            s.messages.removeSubrange((index - 1)...index)
                        }
                        s.pending.insert(PendingPrompt(switchboardHop: s.switchboardHop, text: display, images: images), at: 0)
                        s.interrupted = false; s.resumeAfterInterrupt = false; s.queuePaused = true
                        self.finishMuse(s, status: "Session in use · input held", notice: "Muse has this session open in another host. This prompt was not submitted and is held in the paused queue. Close the other host, then choose Resume queue or Inject now. Your conversation identity and draft are unchanged.")
                    } else { self.finishMuse(s, status: "Could not open session", notice: error.localizedDescription) }
                    return
                }
                if let warning = connection.settingWarning { s.messages.append(Message(role: "notice", text: warning)); s.settingNotice = warning }
                s.started = true; s.remoteID = connection.sessionID; self.save(); s.status = "Working…"
                connection.submit(prompt: prompt, display: display, images: images, effort: s.choices.effort) { result in
                    guard s.muse === connection else { return }
                    if case .failure(let error) = result { self.finishMuse(s, status: "Turn not acknowledged", notice: error.localizedDescription) }
                    else {
                        self.confirmInjectionStarted(s)
                        if s.interrupted { connection.interrupt() }
                    }
                }
            }
        }
    }
    func finishMuse(_ s: Session, status: String, notice: String? = nil) {
        guard !s.museClosing else { return }
        s.museClosing = true
        let connection = s.muse; connection?.event = nil; connection?.disconnected = nil
        s.status = "Releasing Muse session…"
        let finish = {
            s.muse = nil; s.museClosing = false
            s.busy = false; s.process = nil; s.requests = []; s.answeringRequest = false; s.status = status
            s.messages.removeAll { $0.role == "assistant" && $0.text.isEmpty && $0.images.isEmpty }
            if let notice, !notice.isEmpty { s.messages.append(Message(role: "notice", text: notice)) }
            self.save(); self.objectWillChange.send()
            if ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] == nil { self.refreshStatus(s) }
            self.finishQueue(s, success: status == "Ready")
        }
        // turn/completed is not process exit. Keep this seat busy until its
        // owned host has exited and released the CLI session lock.
        if let connection { connection.close(completion: finish) } else { finish() }
    }
    func consumeMuse(_ method: String, _ params: [String: Any], session s: Session, responseID: UUID) {
        switch method {
        case "turn/started": s.busy = true; s.muse?.turnID = params["turnId"] as? String; s.status = "Working…"; confirmInjectionStarted(s)
        case "turn/foregroundCompleted":
            let agents = params["blockingAgents"] as? [String] ?? []
            s.status = "Answer finished · checking " + agents.joined(separator: ", ")
        case "turn/retryScheduled", "turn/modelRetryScheduled":
            let delay = (params["retryDelayMs"] as? Double ?? 0) / 1000
            s.status = "Retrying in \(Int(delay)) sec · attempt \(params["nextAttempt"] as? Int ?? 0)/\(params["maxAttempts"] as? Int ?? 0)"
        case "turn/completed":
            let terminal = params["terminal"] as? String ?? "unknown"
            let error = params["error"] as? [String: Any]
            let reason = error?["message"] as? String ?? params["reason"] as? String
            let notice = terminal == "completed" ? reason : "Muse turn \(terminal)." + (reason.map { " " + $0 } ?? "")
            finishMuse(s, status: terminal == "completed" ? "Ready" : terminal.capitalized, notice: notice)
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
        case "session/contextUsage":
            if s.toolStatus.accountUsage == nil { s.toolStatus.accountUsage = AccountUsage() }
            s.toolStatus.accountUsage?.context = AccountUsage.context(tokens: params["usedTokens"], capacity: params["windowTokens"], at: Date())
        case "session/tokenUsage":
            if let usage = params["usage"] as? [String: Any] { s.toolStatus.usage = "\((usage["inputTokens"] as? Int ?? 0).formatted()) in / \((usage["outputTokens"] as? Int ?? 0).formatted()) out" }
        case "item/started", "item/updated", "item/completed":
            guard let item = params["item"] as? [String: Any], let itemID = item["itemId"] as? String else { break }
            if item["kind"] as? String == "compaction", method == "item/completed", item["outcome"] as? String == "compacted" {
                s.lastCompactedAt = Date(); s.toolStatus.accountUsage?.context = nil
            }
            if item["kind"] as? String == "agentMessage" {
                if s.museItems[itemID] == nil {
                    if s.museItems.isEmpty { s.museItems[itemID] = responseID }
                    else { let id = UUID(); s.museItems[itemID] = id; s.messages.append(Message(id: id, role: "assistant", text: "")) }
                }
                if let value = item["text"] as? String { updateMuseText(value, append: false, itemID: itemID, session: s) }
            } else if item["kind"] as? String == "toolCall", method == "item/completed", item["status"] as? String == "failed" {
                // A failed tool attempt can be recovered by the model. Only
                // turn/completed decides whether the conversation turn failed.
                activity("Muse tool \(item["tool"] as? String ?? "call") failed: \(item["failureReason"] as? String ?? "No reason reported")", session: s)
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
        let answerToken = UUID(); s.answerRequestToken = answerToken
        s.answeringRequest = true; s.requestError = ""
        connection.rpc(method, params) { result in
            guard s.muse === connection, s.answerRequestToken == answerToken else { return }
            s.answeringRequest = false
            if case .success = result {
                // The RPC is itself an acknowledgement. Do not wait forever for
                // a separate resolved event, and retain a newer approval stage.
                s.requests.removeAll { current in
                    current.id == request.id && current.kind == request.kind &&
                    NSDictionary(dictionary: current.params).isEqual(to: request.params)
                }
            }
            if case .failure(let error) = result {
                s.requestError = error.localizedDescription
                // Refresh the race-guarded request after another client or a stage change wins.
                connection.rpc("approval/listPending", ["sessionId": connection.sessionID]) { result in
                    guard s.muse === connection, s.answerRequestToken == answerToken else { return }
                    if case .success(let value) = result {
                        s.requests = (value["approvals"] as? [[String: Any]] ?? []).compactMap { p in (p["approvalId"] as? String).map { MuseRequest(id: $0, kind: "approval", params: p) } }
                        s.requests += (value["userInputs"] as? [[String: Any]] ?? []).compactMap { p in (p["userInputId"] as? String).map { MuseRequest(id: $0, kind: "question", params: p) } }
                    }
                }
            }
        }
    }
    func refreshStatus(_ s: Session, quota: Bool = false, completion: (() -> Void)? = nil) {
        guard s.entry.engine != "support" else { completion?(); return }
        guard !applicationQuitting else { completion?(); return }
        if s.isAgentSession {
            s.probeError = s.needsAgentSetup ? Session.missingAgentSettings : ""
            s.needsSignIn = false
            if let agent = s.agent { s.toolStatus.model = AgentModels.label(agent.model); s.toolStatus.access = "Monitor selected sessions" }
            completion?(); return
        }
        guard ProcessInfo.processInfo.environment["CONVERSE_SKIP_STATUS_PROBE"] == nil else { completion?(); return }
        if s.entry.engine != "muse" { refreshProviderStatus(s, completion: completion); return }
        if let completion { s.statusCallbacks.append(completion) }
        guard !s.probingStatus else { return }
        s.probingStatus = true
        let entry = s.entry; let id = s.remoteID ?? s.id.uuidString; let revision = s.settingRevision
        let fetchQuota = quota || s.quotaRefreshedAt == nil || Date().timeIntervalSince(s.quotaRefreshedAt!) > 300
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try MuseStatusProbe.query(entry: entry, sessionID: id) }
            let quotaResult: Result<MuseQuotaReading, Error>? = fetchQuota && ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] == nil ? Result { try MuseQuota.query(entry: entry) } : nil
            DispatchQueue.main.async {
                s.probingStatus = false
                // A pre-change metadata read must not revert the picker after
                // a newer acknowledged setting transaction.
                if s.changingSetting { return }
                if revision != s.settingRevision { self.refreshStatus(s); return }
                switch result {
                case .success(let snapshot):
                    s.modelChoices = snapshot.models; s.accessChoices = snapshot.access
                    let previousQuota = s.toolStatus.quota
                    let previousUsage = s.toolStatus.accountUsage
                    let identity = snapshot.status.account ?? "Muse CLI has no reported account email"
                    s.toolStatus = snapshot.status; s.statusDetails = snapshot.detail; s.probeError = ""
                    if let context = previousUsage?.context {
                        if s.toolStatus.accountUsage == nil { s.toolStatus.accountUsage = AccountUsage() }
                        s.toolStatus.accountUsage?.context = context
                    }
                    // Keep the last measured limits (and their age) between quota reads.
                    if let previousUsage, !previousUsage.limits.isEmpty, s.toolStatus.accountUsage?.limits.isEmpty != false {
                        if s.toolStatus.accountUsage == nil { s.toolStatus.accountUsage = AccountUsage() }
                        s.toolStatus.accountUsage?.limits = previousUsage.limits; s.toolStatus.accountUsage?.observedAt = previousUsage.observedAt
                    }
                    s.accountStatus = identity; s.toolStatus.account = identity; s.toolStatus.accountObservedAt = Date()
                    if snapshot.status.quota == "Muse has no observed account quota", let previousQuota, (previousQuota.contains("observed ") || previousQuota.contains("% used")) { s.toolStatus.quota = previousQuota; s.toolStatus.accountUsage = previousUsage }
                    if !s.started { self.updateExplicitStatus(s) }; self.saveSoon()
                case .failure(let error):
                    s.probeError = error.localizedDescription
                    s.statusDetails = "Muse status refresh failed: " + error.localizedDescription
                    s.toolStatus.access = "Status refresh failed"
                    s.toolStatus.usage = "Refresh failed"
                }
                if let quotaResult {
                    s.quotaRefreshedAt = Date()
                    switch quotaResult {
                    case .success(let reading):
                        var usage = reading.usage ?? AccountUsage()
                        usage.context = s.toolStatus.accountUsage?.context
                        s.toolStatus.quota = reading.text; s.toolStatus.accountUsage = usage
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
        guard s.entry.engine != "muse" || !s.started else { return }
        if let model = s.choices.model {
            s.toolStatus.model = s.entry.engine == "claude" ? (s.modelChoices.first { $0.id == model }?.label ?? model) : model
        }
        if let effort = s.choices.effort { s.toolStatus.effort = effort }
        if let approval = s.choices.approval { s.toolStatus.approval = approval }
        if let access = s.choices.access { s.toolStatus.access = s.accessChoices.first { $0.id == access }?.label ?? access }
    }
    func changeSetting(_ s: Session, _ change: MuseSettingChange) {
        guard !s.changingSetting else { return }
        s.settingRevision += 1
        func remember() {
            switch change {
            case .model(let model):
                s.toolStatus.accountUsage?.context = nil; s.claudeLastContext = nil
                s.choices.model = model.id; s.choices.modelProvider = model.provider; s.choices.modelProfile = model.profile
                if let effort = s.choices.effort, !model.efforts.contains(effort) {
                    s.choices.effort = s.entry.engine == "muse" ? nil : model.efforts.first
                    s.toolStatus.effort = s.choices.effort ?? "CLI default"
                }
            case .effort(let effort): s.choices.effort = effort
            case .access(let access): s.choices.access = access
            }
            if s.entry.engine == "muse", s.started {
                switch change {
                case .model(let model): s.toolStatus.model = model.label
                case .effort(let effort): s.toolStatus.effort = effort
                case .access(let access): s.toolStatus.access = s.accessChoices.first { $0.id == access }?.label ?? access
                }
            } else { self.applySessionChoices(s) }
            self.save()
        }
        if s.entry.engine != "muse" || !s.started {
            remember(); s.settingNotice = s.busy ? "Change saved · applies next turn" : "Change saved · applies when the next turn starts"; return
        }
        if s.busy {
            guard !s.museClosing, let connection = s.muse, connection.turnID != nil else {
                remember(); s.settingNotice = "Change saved · applies next turn"; return
            }
            s.changingSetting = true; s.settingNotice = "Waiting for Muse to confirm change… · you can keep typing"
            connection.changeSetting(change) { result in
                s.changingSetting = false
                switch result {
                case .success:
                    remember()
                    switch change {
                    case .access: s.settingNotice = "Permission profile applied · pending approvals still need a decision"
                    case .model: s.settingNotice = "Model selected · applies at the next model call"
                    case .effort: s.settingNotice = "Effort saved · applies next turn"
                    }
                case .failure(let error):
                    s.settingNotice = "Change not confirmed: " + error.localizedDescription
                    s.messages.append(Message(role: "notice", text: s.settingNotice)); s.queuePaused = !s.pending.isEmpty; self.saveSoon()
                }
                if ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] == nil { self.refreshStatus(s) }
                self.runNext(s)
            }
            return
        }
        s.changingSetting = true; s.settingNotice = "Waiting for Muse to confirm change… · you can keep typing"
        let entry = s.entry, id = s.remoteID ?? s.id.uuidString
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try MuseStatusProbe.query(entry: entry, sessionID: id, change: change) }
            DispatchQueue.main.async {
                s.changingSetting = false
                switch result {
                case .success(let snapshot):
                    let quota = s.toolStatus.quota
                    s.toolStatus = snapshot.status; s.toolStatus.quota = quota ?? snapshot.status.quota; s.modelChoices = snapshot.models; s.accessChoices = snapshot.access; s.statusDetails = snapshot.detail
                    remember(); s.settingNotice = "Session setting applied"
                case .failure(let error):
                    s.settingNotice = "Change not confirmed: " + error.localizedDescription
                    s.messages.append(Message(role: "notice", text: s.settingNotice)); self.saveSoon()
                }
                if !s.statusCallbacks.isEmpty && !s.probingStatus { self.refreshStatus(s) }
                self.runNext(s)
            }
        }
    }
    func clearSessionDisplay(_ s: Session) {
        s.clearedThroughMessageID = s.messages.last?.id
        save()
    }
    func handleLocalCommand(_ s: Session) -> Bool {
        let command = s.draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["/help", "/model", "/models", "/usage", "/status", "/stop", "/login", "/clear", "/unclear"].contains(command) else { return false }
        if command == "/clear" || command == "/unclear" {
            s.draft = ""
            if command == "/clear" { clearSessionDisplay(s) }
            else { s.clearedThroughMessageID = nil; save() }
            return true
        }
        if command == "/login" {
            s.draft = ""
            if s.agent != nil { MainActor.assumeIsolated { AgentWindows.shared.setup(s) } }
            else if let app = AppDelegate.shared { app.chooseLogin(s) } else { signInSession(s) }
            saveSoon(); return true
        }
        s.messages.append(Message(role: "user", text: s.draft)); s.draft = ""
        if command == "/stop" { stop(s); saveSoon(); return true }
        if command == "/help" {
            s.messages.append(Message(role: "notice", text: "/model or /models — query model, effort and access\n/usage — query last-turn tokens, session totals and available quota\n/status — refresh all session status\n/stop — interrupt the current turn\n/login — choose an existing login, add a new one, or sign in again\n/clear — clear the display; keep model context and history\n/unclear — show the hidden history again\n/help — show these local commands\nThese commands never submit a prompt. Use the bottom dropdowns for session settings. Return queues while busy. Use Inject now or Inject all to interrupt with queued input. Command Return inserts a newline.")); saveSoon(); return true
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
        do { try closeSessionChecked(s) }
        catch {
            let alert = NSAlert(); alert.messageText = "Could not close conversation"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    func closeSessionChecked(_ s: Session, receipt: ParticipantMutationReceipt? = nil) throws {
        guard let index = sessions.firstIndex(where: { $0 === s }) else { return }
        let deleted = folder.appendingPathComponent("Deleted Sessions")
        try FileManager.default.createDirectory(at: deleted, withIntermediateDirectories: true)
        try JSONEncoder().encode(s.saved).write(to: deleted.appendingPathComponent(s.id.uuidString + ".json"), options: .atomic)
        try closeIdentity(s)
        sessions.remove(at: index)
        if let receipt { participantReceipts.append(receipt) }
        do { try saveChecked() }
        catch {
            sessions.insert(s, at: index)
            if let receipt { participantReceipts.removeAll { $0.id == receipt.id } }
            syncIdentity(s)
            throw error
        }
        s.identityChanged = nil
        s.queuePaused = true; s.pending = []; stop(s)
        DeviceSyncService.shared.homeSessionClosed(s.id)
        AppDelegate.shared?.sessionWasDeleted(s)
    }
    func restoreDeleted() -> Session? {
        let dir = folder.appendingPathComponent("Deleted Sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        for file in files.sorted(by: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }) {
            guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(SavedSession.self, from: data), !sessions.contains(where: { $0.id == saved.id }) else { continue }
            let s = Session(saved); sessions.append(s); attachIdentity(s)
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
        if s.entry.engine == "claude" { updateClaudeContext(obj, session: s) }
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
        assistantResponded(s)
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
    static func claudeWorkingStatus(_ s: Session) -> String {
        let tasks = s.claudeBackgroundTasks.values.sorted()
        guard let first = tasks.first else { return "Working…" }
        return "Working… · " + (tasks.count == 1 ? "task: " : "\(tasks.count) tasks: ") + String(first.prefix(60)) + (tasks.count > 1 ? " +\(tasks.count - 1)" : "")
    }
    static func claudeUnseparated(_ text: String, session: Session) -> String {
        let unseparated = NSMutableString(string: text)
        for range in session.claudeStreamSeparators.reversed() where NSMaxRange(range) <= unseparated.length {
            unseparated.deleteCharacters(in: range)
        }
        return unseparated as String
    }
    func consume(_ line: String, session s: Session, responseID: UUID) {
        guard !line.isEmpty else { return }
        if let retry = ProviderRetry.detail(line) {
            s.retryDetail = retry
            s.status = ProviderRetry.status(s.entry.engine)
            saveSoon(); objectWillChange.send(); return
        }
        if s.retryDetail != nil { s.retryDetail = nil; s.status = s.entry.engine == "claude" ? Store.claudeWorkingStatus(s) : "Working…" }
        guard let data = line.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            activity(line, session: s); saveSoon(); return
        }
        updateReportedStatus(obj, session: s)
        var text: String?; var replace = false; var delta = false; var startsTextBlock = false
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
                activity("Muse tool exited with status \(code): " + Store.visibleText(raw), session: s)
            }
            else if kind.contains("failed") || kind.contains("approval") {
                let description = payload["reason"] as? String ?? payload["text"] as? String ?? payload["tool_name"] as? String
                if let description { s.messages.append(Message(role: "notice", text: description)) }
            }
        } else if s.entry.engine == "claude" {
            if let sid = obj["session_id"] as? String { s.remoteID = sid }
            // Subagents and background shells can keep the CLI working after
            // its first result. Name them so the turn does not look finished.
            if type == "system", let task = obj["task_id"] as? String, let subtype = obj["subtype"] as? String, ["task_started", "task_notification"].contains(subtype) {
                if subtype == "task_started" { s.claudeBackgroundTasks[task] = (obj["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unnamed task" }
                else { s.claudeBackgroundTasks[task] = nil }
                if s.busy && s.status.hasPrefix("Working") { s.status = Store.claudeWorkingStatus(s) }
            }
            if type == "stream_event", let event = obj["event"] as? [String: Any] {
                if event["type"] as? String == "content_block_start", let block = event["content_block"] as? [String: Any], block["type"] as? String == "text" {
                    s.claudeTextBlockPending = true
                    if let initial = block["text"] as? String, !initial.isEmpty {
                        text = initial; delta = true; startsTextBlock = true
                        s.claudeTextBlockPending = false; s.streamedText = true
                    }
                }
                if let chunk = event["delta"] as? [String: Any], chunk["type"] as? String == "text_delta", let value = chunk["text"] as? String, !value.isEmpty {
                    text = value; delta = true; startsTextBlock = s.claudeTextBlockPending
                    s.claudeTextBlockPending = false; s.streamedText = true
                }
            }
            if type == "assistant", let message = obj["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
                let accumulated = s.messages.first { $0.id == responseID }?.text ?? ""
                for block in content {
                    // Later text blocks can arrive only in assistant events,
                    // even after earlier blocks streamed. Deduplicate their
                    // content, rather than dropping everything after a delta.
                    if let value = block["text"] as? String, !value.isEmpty,
                       !(Store.claudeUnseparated(accumulated, session: s) + (text ?? "")).contains(value) {
                        text = (text ?? "") + value
                    }
                    if block["type"] as? String == "tool_use" { activity("Using \(block["name"] as? String ?? "tool")", session: s) }
                }
            } else if type == "result" {
                if obj["is_error"] as? Bool == true { s.turnFailed = true }
                if let result = obj["result"] as? String {
                    let accumulated = s.messages.first { $0.id == responseID }?.text ?? ""
                    let unseparated = Store.claudeUnseparated(accumulated, session: s)
                    // A successful final snapshot can contain only the last
                    // block. Preserve earlier output and display separators;
                    // genuine corrections and errors still replace it.
                    let sameWithoutSeparators = !s.claudeStreamSeparators.isEmpty && unseparated == result
                    let subset = !result.isEmpty && accumulated.contains(result)
                    text = !s.turnFailed && (sameWithoutSeparators || subset) ? accumulated : result
                    replace = true
                }
                if let errors = obj["errors"] as? [String] { s.messages.append(Message(role: "notice", text: errors.joined(separator: "\n"))) }
            }
        } else {
            if type == "thread.started" { s.remoteID = obj["thread_id"] as? String }
            if type == "item.completed", let item = obj["item"] as? [String: Any] {
                if item["type"] as? String == "agent_message" { text = item["text"] as? String }
                else if let command = item["command"] as? String { activity(command, session: s) }
            }
            if type == "error" || type == "turn.failed" {
                if !s.turnFailed { s.messages.append(Message(role: "notice", text: obj["message"] as? String ?? String(describing: obj["error"] ?? "Command failed"))) }; s.turnFailed = true
            }
        }
        if let raw = text, let i = s.messages.firstIndex(where: { $0.id == responseID }) {
            let visible = Store.visibleText(raw)
            let old = s.messages[i].text
            if !visible.isEmpty {
                let separator = old.isEmpty ? "" : startsTextBlock && !old.hasSuffix("\n") ? "\n\n" : delta ? "" : "\n"
                let next = replace ? visible : old + separator + visible
                if s.entry.engine == "claude", startsTextBlock, !replace, !separator.isEmpty {
                    s.claudeStreamSeparators.append(NSRange(location: (old as NSString).length, length: (separator as NSString).length))
                }
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
        context.coordinator.messages = session.displayedMessages; context.coordinator.update(web)
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
enum TranscriptPalette {
    static let promptBackground = NSColor(red: 212.0 / 255, green: 231.0 / 255, blue: 1, alpha: 1)
    static let trafficBackground = NSColor(red: 1, green: 0.89, blue: 0.76, alpha: 1)
    static let traffic = NSColor(name: "ConverseTraffic") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 1, green: 0.70, blue: 0.36, alpha: 1) : NSColor(red: 0.65, green: 0.27, blue: 0, alpha: 1)
    }
    static func draft(_ source: String) -> NSColor { .systemBlue }
}
struct TranscriptMessageLabel: Equatable {
    var location: Int
    var number: Int
    var prompt: Bool
    var timestamp: Date? = nil
    var color: NSColor { prompt ? .systemBlue : .systemGray }
}
final class MessageNumberRuler: NSRulerView {
    override var isFlipped: Bool { true }
    weak var text: ConversationTextView?
    private var timestampTips: [Int: String] = [:]
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String { timestampTips[tag] ?? "" }
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
        removeAllToolTips(); timestampTips.removeAll()
        guard let text, let layout = text.layoutManager, let container = text.textContainer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor.black : NSColor.white).setFill(); bounds.fill()
        layout.ensureLayout(for: container)
        let string = text.string as NSString
        let origin = (scrollView?.contentView.frame.minY ?? 0) - (scrollView?.contentView.bounds.minY ?? 0) + text.textContainerOrigin.y
        // Shade the entire visual block, including wrapped lines and images,
        // rather than only the first numbered line of a submitted prompt.
        if !dark { TranscriptPalette.promptBackground.setFill() }
        for block in (dark ? [] : text.userBlocks) where block.length > 0 && block.location < string.length {
            let end = min(NSMaxRange(block), string.length)
            let first = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: block.location), effectiveRange: nil)
            let last = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: end - 1), effectiveRange: nil)
            NSRect(x: bounds.minX, y: origin + first.minY, width: bounds.width, height: last.maxY - first.minY).intersection(bounds).fill()
        }
        // The editable draft is a prompt too, including its empty final line.
        let start = min(text.inputStart, string.length)
        let first = start < string.length ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil) : layout.extraLineFragmentRect
        let last = string.length > start && !text.string.hasSuffix("\n") ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: string.length - 1), effectiveRange: nil) : layout.extraLineFragmentRect
        if !dark {
            TranscriptPalette.promptBackground.setFill()
            NSRect(x: bounds.minX, y: origin + first.minY, width: bounds.width, height: max(18, last.maxY - first.minY)).intersection(bounds).fill()
            TranscriptPalette.trafficBackground.setFill()
            for block in text.trafficBlocks where block.length > 0 && block.location < string.length {
                let end = min(NSMaxRange(block), string.length)
                let a = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: block.location), effectiveRange: nil)
                let b = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: end - 1), effectiveRange: nil)
                NSRect(x: bounds.minX, y: origin + a.minY, width: bounds.width, height: b.maxY - a.minY).intersection(bounds).fill()
            }
        }
        NSColor.gray.withAlphaComponent(0.25).setStroke()
        let edge = NSBezierPath(); edge.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY)); edge.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY)); edge.lineWidth = 0.5; edge.stroke()
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]
        // One label at the start of each rendered message. Paragraph breaks,
        // wrapping, images and the editable draft never consume numbers.
        for message in text.messageLabels where message.location < string.length {
            let glyph = layout.glyphIndexForCharacter(at: message.location)
            let lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let label = NSAttributedString(string: String(message.number), attributes: baseAttrs.merging([.foregroundColor: message.color]) { _, new in new })
            let y = origin + lineRect.minY + max(0, (lineRect.height - label.size().height) / 2)
            if y + label.size().height >= bounds.minY && y <= bounds.maxY {
                label.draw(at: NSPoint(x: ruleThickness - label.size().width - 9, y: y))
                if let date = message.timestamp {
                    let tag = addToolTip(NSRect(x: 0, y: y, width: ruleThickness, height: max(18, label.size().height)), owner: self, userData: nil)
                    timestampTips[tag] = "Recorded " + date.formatted(date: .abbreviated, time: .standard)
                }
            }
        }
    }
}

final class InputClipView: NSClipView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if let text = documentView as? ConversationTextView { text.focusInput() }
        else { super.mouseDown(with: event) }
    }
}
final class LatestOutputButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        // A standard macOS bezel can show transcript text through its fill.
        // Paint an opaque backing before AppKit draws the button and title.
        NSColor.windowBackgroundColor.withAlphaComponent(1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        super.draw(dirtyRect)
    }
}
final class ConversationScrollView: NSScrollView {
    private var tiling = false
    private var initialTailPending = false
    func revealInitialTail() { initialTailPending = true; needsLayout = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if initialTailPending { needsLayout = true } }
    override func layout() {
        super.layout()
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        if initialTailPending {
            initialTailPending = false; tile(); jumpToLatest()
        } else if followState.following && !selecting && !isFindBarVisible { followLatest() }
    }
    private(set) var followState = TranscriptFollowState()
    private var idleResume: DispatchWorkItem?
    private var interactionMonitor: Any?
    private var liveScrolling = false
    private var lastScrollAt: TimeInterval = 0
    private var settlingTail = false
    private let latest = LatestOutputButton(title: "Jump to latest", target: nil, action: nil)
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); configureFollowing() }
    required init?(coder: NSCoder) { super.init(coder: coder); configureFollowing() }
    deinit {
        idleResume?.cancel(); NotificationCenter.default.removeObserver(self)
        if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) }
    }
    private func configureFollowing() {
        latest.target = self; latest.action = #selector(jumpToLatest)
        latest.bezelStyle = .rounded; latest.font = .systemFont(ofSize: 12, weight: .medium); latest.isHidden = true
        latest.setAccessibilityLabel("Jump to latest output")
        addSubview(latest)
        interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            if let self, let window = self.window, event.window === window {
                if event.type == .leftMouseDown { self.focusBlankInput(at: event.locationInWindow) }
                let inside = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                let focused = (window.firstResponder as? NSView)?.isDescendant(of: self) == true
                if event.type == .keyDown ? focused : inside { self.interaction() }
            }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(startedScrolling), name: NSScrollView.willStartLiveScrollNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSScrollView.didLiveScrollNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(endedScrolling), name: NSScrollView.didEndLiveScrollNotification, object: self)
    }
    // Claim a blank-input click before the responder chain routes it. In
    // particular, a Parking Lot's text/Undo responder must not keep that click.
    @discardableResult func focusBlankInput(at windowPoint: NSPoint) -> Bool {
        guard let window, let text = documentView as? ConversationTextView, text.isEditable,
              contentView.bounds.contains(contentView.convert(windowPoint, from: nil)),
              text.isInputWhitespace(text.convert(windowPoint, from: nil)) else { return false }
        if let root = window.contentView,
           root.hitTest(root.convert(windowPoint, from: nil)) is PaneDividerHandle { return false }
        text.focusInput()
        return window.firstResponder === text
    }
    var nearBottom: Bool { contentView.bounds.maxY >= (documentView?.bounds.height ?? 0) - 2 }
    var selecting: Bool {
        guard let text = documentView as? ConversationTextView else { return false }
        return text.explicitCursor || (text.selectedRange().length > 0 && !text.findOwnsSelection)
    }
    func prepareForRender(first: Bool) -> Bool {
        if first { followState.resume() }
        else if followState.following && (selecting || isFindBarVisible) {
            followState.pause(now: ProcessInfo.processInfo.systemUptime); scheduleResume()
        }
        refreshLatest(); return followState.following
    }
    func outputArrived() { followState.outputArrived(); refreshLatest() }
    func interaction() {
        initialTailPending = false
        followState.interaction(now: ProcessInfo.processInfo.systemUptime)
        if (selecting || isFindBarVisible) && followState.following { followState.pause(now: ProcessInfo.processInfo.systemUptime) }
        scheduleResume()
    }
    private func scheduleResume() {
        idleResume?.cancel()
        guard !followState.following else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.followState.resumeIfIdle(now: ProcessInfo.processInfo.systemUptime,
                selecting: self.selecting || self.isFindBarVisible, scrolling: self.liveScrolling && ProcessInfo.processInfo.systemUptime - self.lastScrollAt < 1) {
                self.resumeFollowing()
            } else { self.scheduleResume() }
        }
        idleResume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TranscriptFollowState.idleDelay, execute: work)
    }
    @objc private func startedScrolling() { liveScrolling = true; recordScroll() }
    @objc private func scrolled() { recordScroll() }
    @objc private func endedScrolling() { liveScrolling = false; recordScroll() }
    func recordScroll() {
        lastScrollAt = ProcessInfo.processInfo.systemUptime
        initialTailPending = false
        followState.scroll(nearBottom: nearBottom && !selecting, now: ProcessInfo.processInfo.systemUptime)
        scheduleResume(); refreshLatest()
    }
    override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event); recordScroll() }
    func followLatest() {
        guard !settlingTail, let text = documentView as? ConversationTextView else { return }
        settlingTail = true; defer { settlingTail = false }
        text.fitDocumentHeight()
        let bottom = max(0, text.bounds.maxY - contentView.bounds.height)
        if abs(contentView.bounds.minY - bottom) > 0.5 {
            contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: bottom))
            reflectScrolledClipView(contentView)
        }
    }
    @objc func jumpToLatest() {
        (documentView as? ConversationTextView)?.explicitCursor = false
        if let text = documentView as? NSTextView {
            let tail = NSRange(location: (text.string as NSString).length, length: 0)
            text.setSelectedRange(tail); text.scrollRangeToVisible(tail)
        }
        resumeFollowing()
    }
    // Automatic following changes the viewport, never the user's insertion point.
    // Only the explicit Jump to latest command moves the caret to the tail.
    func resumeFollowing() {
        idleResume?.cancel(); followState.resume()
        followLatest(); refreshLatest()
    }
    var showsLatest: Bool { !latest.isHidden }
    func refreshLatest() {
        let bottomVisible = contentView.bounds.maxY >= (documentView?.bounds.maxY ?? 0) - 2
        latest.isHidden = followState.following || bottomVisible
        latest.title = followState.unreadUpdates == 0 ? "Jump to latest" : "Jump to latest (" + String(followState.unreadUpdates) + " new updates)"
        latest.sizeToFit()
        latest.frame.origin = NSPoint(x: max(contentView.frame.minX + 8, contentView.frame.maxX - latest.frame.width - 12), y: isFlipped ? bounds.maxY - latest.frame.height - 10 : bounds.minY + 10)
    }
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        refreshLatest()
    }
    override func tile() {
        guard !tiling else { return }
        tiling = true; defer { tiling = false }
        super.tile()
        (documentView as? ConversationTextView)?.fitDocumentHeight()
        refreshLatest()
    }
}
final class DraftImageRemoveButton: NSButton {
    var remove: (() -> Void)?
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        isBordered = false; imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove draft image")
        contentTintColor = .white; wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor; layer?.cornerRadius = 11
        toolTip = "Remove image from draft"; setAccessibilityLabel("Remove image from draft")
        target = self; action = #selector(removeImage)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func removeImage() { remove?() }
}
// NSTextView must remain editable for the draft, but the finder gets a
// read-only client. It cannot mutate either history or the unsent draft.
final class TranscriptFindClient: NSObject, NSTextFinderClient {
    weak var text: ConversationTextView?
    init(_ text: ConversationTextView) { self.text = text }
    var isEditable: Bool { false }
    var isSelectable: Bool { true }
    var allowsMultipleSelection: Bool { false }
    var string: String { text?.string ?? "" }
    var firstSelectedRange: NSRange { text?.selectedRange() ?? NSRange(location: 0, length: 0) }
    var selectedRanges: [NSValue] {
        get { text?.selectedRanges ?? [] }
        set { text?.findOwnsSelection = true; text?.selectedRanges = newValue }
    }
    func scrollRangeToVisible(_ range: NSRange) { text?.scrollRangeToVisible(range) }
    func shouldReplaceCharacters(inRanges ranges: [NSValue], with strings: [String]) -> Bool { false }
    func replaceCharacters(in range: NSRange, with string: String) { /* Search is read-only. */ }
    // Forward only geometry/drawing supplied by NSTextView's public finder
    // client protocol. No editing selectors can escape through this proxy.
    private func isGeometry(_ selector: Selector) -> Bool {
        ["contentViewAtIndex:effectiveCharacterRange:", "rectsForCharacterRange:",
         "visibleCharacterRanges", "drawCharactersInRange:forContentView:"].contains(NSStringFromSelector(selector))
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (isGeometry(selector) && text?.responds(to: selector) == true)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        isGeometry(selector) ? text : super.forwardingTarget(for: selector)
    }
}
final class ConversationTextView: NSTextView {
    var explicitCursor = false
    var handlingSelectionGesture = false
    var findOwnsSelection = false
    lazy var findClient = TranscriptFindClient(self)
    lazy var readOnlyFinder: NSTextFinder = {
        let finder = NSTextFinder(); finder.client = findClient
        finder.isIncrementalSearchingEnabled = true
        return finder
    }()
    static func allowsFindAction(_ tag: Int) -> Bool {
        [NSTextFinder.Action.showFindInterface, .nextMatch, .previousMatch, .setSearchString, .hideFindInterface].contains { $0.rawValue == tag }
    }
    override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? 0
        guard Self.allowsFindAction(tag), let action = NSTextFinder.Action(rawValue: tag) else { return }
        readOnlyFinder.findBarContainer = enclosingScrollView
        if action == .showFindInterface { findOwnsSelection = true }
        readOnlyFinder.performAction(action)
        (enclosingScrollView as? ConversationScrollView)?.interaction()
    }

    var draftImages: [(location: Int, path: String)] = []
    private(set) var draftImageButtons: [DraftImageRemoveButton] = []
    var imageRemove: ((String) -> Void)?
    func configureDraftImageButtons() {
        draftImageButtons.forEach { $0.removeFromSuperview() }; draftImageButtons = []
        for image in draftImages {
            let button = DraftImageRemoveButton()
            button.remove = { [weak self] in self?.imageRemove?(image.path) }
            addSubview(button); draftImageButtons.append(button)
        }
        layoutDraftImageButtons()
    }
    private var positioningImageButtons = false
    func layoutDraftImageButtons() {
        guard !positioningImageButtons, !draftImageButtons.isEmpty, let layout = layoutManager, let container = textContainer else { return }
        positioningImageButtons = true; defer { positioningImageButtons = false }
        layout.ensureLayout(for: container)
        for (image, button) in zip(draftImages, draftImageButtons) {
            button.isHidden = imageRemove == nil || !isEditable || image.location >= (string as NSString).length
            guard !button.isHidden else { continue }
            let glyph = layout.glyphRange(forCharacterRange: NSRange(location: image.location, length: 1), actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyph, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            button.setFrameOrigin(NSPoint(x: max(rect.minX, rect.maxX - 24), y: rect.minY + 2))
        }
    }
    override func layout() { super.layout(); layoutDraftImageButtons() }
    static let inputParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle(); style.lineSpacing = 2; return style
    }()
    private var fittingDocument = false
    func fitDocumentHeight() {
        guard !fittingDocument, let scroll = enclosingScrollView, let layout = layoutManager, let container = textContainer else { return }
        fittingDocument = true; defer { fittingDocument = false }
        let minimum = scroll.contentView.bounds.height
        if minSize.height != minimum { minSize.height = minimum }
        layout.ensureLayout(for: container)
        let bottom = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let height = max(minimum, ceil(bottom + textContainerInset.height * 2))
        if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: frame.width, height: height)) }
        let origin = scroll.contentView.constrainBoundsRect(scroll.contentView.bounds).origin
        if origin != scroll.contentView.bounds.origin { scroll.contentView.scroll(to: origin) }
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func focusInput() {
        explicitCursor = false
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        let color = TranscriptPalette.draft((string as NSString).substring(from: min(inputStart, (string as NSString).length)))
        typingAttributes = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: color, .paragraphStyle: Self.inputParagraphStyle]
        insertionPointColor = color
        scrollRangeToVisible(selectedRange())
        updateInsertionPointStateAndRestartTimer(true)
        needsDisplay = true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func isInputWhitespace(_ point: NSPoint) -> Bool {
        guard let layout = layoutManager, let container = textContainer else { return true }
        layout.ensureLayout(for: container)
        if string.isEmpty { return true }
        let extra = layout.extraLineFragmentRect
        let bottom = extra.height > 0 ? extra.minY : layout.usedRect(for: container).maxY
        return point.y >= bottom + textContainerOrigin.y
    }
    override func mouseDown(with event: NSEvent) {
        findOwnsSelection = false
        (enclosingScrollView as? ConversationScrollView)?.interaction()
        if isInputWhitespace(convert(event.locationInWindow, from: nil)) { focusInput(); return }
        handlingSelectionGesture = true
        defer { handlingSelectionGesture = false; recordUserSelection() }
        super.mouseDown(with: event)
    }
    func recordUserSelection() {
        guard !findOwnsSelection else { return }
        explicitCursor = selectedRange().length > 0 || selectedRange().location < inputStart
        (enclosingScrollView as? ConversationScrollView)?.interaction()
    }
    private func prepareTypingUndoGroup() {
        guard let manager = undoManager, manager.groupsByEvent, manager.groupingLevel == 0,
              manager.isUndoRegistrationEnabled, !manager.isUndoing, !manager.isRedoing else { return }
        manager.beginUndoGrouping()
        // The first explicit group can also create AppKit's event group.
        // Keep only that outer group so native typing coalesces normally.
        if manager.groupingLevel > 1 { manager.endUndoGrouping() }
    }
    override func insertText(_ value: Any, replacementRange: NSRange) {
        prepareTypingUndoGroup()
        immediateSubstitution = nil
        let typedSpace = !suppressSubstitutions && !hasMarkedText() && (value as? String) == " " && selectedRange().length == 0
        if selectedRange().location < inputStart || (replacementRange.location != NSNotFound && replacementRange.location < inputStart) {
            focusInput(); super.insertText(value, replacementRange: selectedRange()); return
        }
        super.insertText(value, replacementRange: replacementRange)
        guard typedSpace, let manager = undoManager, manager.groupingLevel <= 1,
              !manager.isUndoing, !manager.isRedoing, selectedRange().location >= inputStart,
              let match = TextSubstitutions.match(in: (string as NSString).substring(from: inputStart), caret: selectedRange().location - inputStart) else { return }
        substitutionFeedback.converted()
        guard TextSubstitutions.shared.enabled else { return }
        let caret = selectedRange().location
        let before = (string as NSString).substring(from: inputStart)
        let after = (before as NSString).replacingCharacters(in: match.range, with: match.replacement)
        breakUndoCoalescing()
        // Finish the typing event before registering a distinct substitution.
        // Undo must restore the literal token, including the triggering space.
        if manager.groupingLevel == 1 { manager.endUndoGrouping() }
        manager.beginUndoGrouping()
        manager.disableUndoRegistration()
        super.insertText(match.replacement, replacementRange: NSRange(location: inputStart + match.range.location, length: match.range.length))
        manager.enableUndoRegistration()
        setSelectedRange(NSRange(location: caret + (match.replacement as NSString).length - match.range.length, length: 0))
        let beforeCaret = caret - inputStart, afterCaret = selectedRange().location - inputStart
        manager.registerUndo(withTarget: self) { view in view.restoreSubstitution(expected: after, replacement: before, caret: beforeCaret, inverseCaret: afterCaret) }
        breakUndoCoalescing(); manager.setActionName(TextSubstitutions.undoName); manager.endUndoGrouping()
        substitutionFeedback.converted()
        substitutionUndo = (after, before, beforeCaret, afterCaret)
        immediateSubstitution = ImmediateSubstitution(text: after, caret: NSRange(location: afterCaret, length: 0))
    }
    private func restoreSubstitution(expected: String, replacement: String, caret: Int, inverseCaret: Int) {
        guard isEditable, let manager = undoManager, (string as NSString).substring(from: inputStart) == expected else { return }
        manager.registerUndo(withTarget: self) { view in view.restoreSubstitution(expected: replacement, replacement: expected, caret: inverseCaret, inverseCaret: caret) }
        manager.setActionName(TextSubstitutions.undoName)
        manager.disableUndoRegistration()
        super.insertText(replacement, replacementRange: NSRange(location: inputStart, length: (string as NSString).length - inputStart))
        manager.enableUndoRegistration()
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: inputStart + min(caret, (replacement as NSString).length), length: 0))
        if manager.isUndoing { substitutionFeedback.rejected() }
    }
    private var substitutionUndo: (expected: String, replacement: String, caret: Int, inverseCaret: Int)?
    func retainedSubstitutionUndo(for draft: String) -> (() -> Void)? {
        guard let value = substitutionUndo, value.expected == draft, undoManager?.undoActionName == TextSubstitutions.undoName else { return nil }
        return { [weak self] in
            guard let self, let manager = self.undoManager else { return }
            manager.beginUndoGrouping()
            manager.registerUndo(withTarget: self) { view in
                view.restoreSubstitution(expected: value.expected, replacement: value.replacement, caret: value.caret, inverseCaret: value.inverseCaret)
            }
            manager.setActionName(TextSubstitutions.undoName); manager.endUndoGrouping()
        }
    }
    var substitutionFeedback = SubstitutionFeedback()
    private var suppressSubstitutions = false
    private var immediateSubstitution: ImmediateSubstitution?
    @objc func undo(_ sender: Any?) {
        let substituted = undoManager?.undoActionName == TextSubstitutions.undoName
        immediateSubstitution = nil; breakUndoCoalescing(); undoManager?.undo(); breakUndoCoalescing()
        if substituted { substitutionFeedback.rejected() }
    }
    @objc func redo(_ sender: Any?) { immediateSubstitution = nil; breakUndoCoalescing(); undoManager?.redo(); breakUndoCoalescing() }
    override func deleteBackward(_ sender: Any?) {
        if immediateSubstitution?.matches(self, start: inputStart) == true, undoManager?.undoActionName == TextSubstitutions.undoName { undo(sender); return }
        immediateSubstitution = nil; prepareTypingUndoGroup(); super.deleteBackward(sender)
    }
    struct CopyBlock {
        let range: NSRange
        let role: String
        let source: String
        let formatted: NSAttributedString
    }
    var copyBlocks: [CopyBlock] = []
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard let textStorage, range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= textStorage.length else { return }
        let plain = TranscriptClipboard.plainText(textStorage.attributedSubstring(from: range))
        super.copy(sender)
        NSPasteboard.general.setString(plain, forType: .string)
    }
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
    func copyAction(at character: Int) -> (title: String, index: Int)? {
        guard let index = copyBlocks.firstIndex(where: { NSLocationInRange(character, $0.range) }), ["user", "assistant"].contains(copyBlocks[index].role) else { return nil }
        return (copyBlocks[index].role == "user" ? "Copy this prompt" : "Copy this response", index)
    }
    @objc private func copyConversationBlock(_ sender: NSMenuItem) { copyBlock(sender.tag, to: .general) }
    var teachApp: (() -> Void)?
    @objc func teachAppConversation(_ sender: Any?) { teachApp?() }
    var teachSession: (() -> Void)?
    @objc func teachConversation(_ sender: Any?) { teachSession?() }
    func addTeachingItem(to menu: NSMenu) {
        guard teachSession != nil else { return }
        let item = NSMenuItem(title: "Teach Session To Talk To Other Sessions", action: #selector(teachConversation(_:)), keyEquivalent: "")
        item.target = self; menu.addItem(.separator()); menu.addItem(item)
        if teachApp != nil {
            let support = NSMenuItem(title: "Teach Converse Setup & Control", action: #selector(teachAppConversation(_:)), keyEquivalent: "")
            support.target = self; menu.addItem(support)
        }
    }
    func imageToolsItem(at character: Int, hasMetaKey: Bool? = nil) -> NSMenuItem? {
        guard let storage = textStorage, character >= 0, character < storage.length,
              let attachment = storage.attribute(.attachment, at: character, effectiveRange: nil) as? NSTextAttachment,
              let image = attachment.fileWrapper?.regularFileContents.flatMap({ NSImage(data: $0) }) ?? attachment.image else { return nil }
        let hasMetaKey = hasMetaKey ?? !((try? AgentSecrets.read("meta")) ?? "").isEmpty
        // A nil action also keeps AppKit's automatic menu validation from
        // re-enabling this item when the required credential is absent.
        let item = NSMenuItem(title: "Image tools · Describe / SAM…", action: hasMetaKey ? #selector(openImageTools(_:)) : nil, keyEquivalent: "")
        item.isEnabled = hasMetaKey
        item.toolTip = hasMetaKey ? nil : "Meta API key required"
        item.target = self; item.representedObject = image.copy() as? NSImage
        return item
    }
    @objc private func openImageTools(_ sender: NSMenuItem) {
        guard let image = sender.representedObject as? NSImage else { return }
        let sessionID = (delegate as? ScrollingConversation.Coordinator)?.session.id
        let canApply: () -> Bool = { [weak self] in
            guard let self, self.window != nil, self.isEditable, let sessionID else { return false }
            return (self.delegate as? ScrollingConversation.Coordinator)?.session.id == sessionID
        }
        MacImageToolsWindow.show(image: image, canApply: canApply, addNotes: { [weak self] notes in
            guard let self, self.isEditable else { return }
            self.focusInput()
            self.insertText((self.string.hasSuffix("\n") ? "" : "\n\n") + "Image notes:\n" + notes, replacementRange: self.selectedRange())
        }, addImage: { [weak self] image in
            guard let self, self.isEditable else { return }; self.imagePaste?(image)
        })
    }
    private func shareNotice() -> (String) -> Void {
        weak let session = (delegate as? ScrollingConversation.Coordinator)?.session
        return { text in
            guard let session else { return }
            Store.shared.flashShareNotice(session, text)
        }
    }
    @objc private func saveImageToPhotos(_ sender: NSMenuItem) {
        guard let image = sender.representedObject as? NSImage else { return }
        PhotoImageShare.save(image, notice: shareNotice())
    }
    override func orderFrontSharingServicePicker(_ sender: Any?) {
        // NSTextView otherwise shares an attributed-text/HTML wrapper, which
        // Photos silently ignores even when the selection is just an image.
        if selectedRange().length == 1, let image = imageToolsItem(at: selectedRange().location, hasMetaKey: true)?.representedObject as? NSImage {
            PhotoImageShare.showPicker(image, from: self, notice: shareNotice())
        } else { super.orderFrontSharingServicePicker(sender) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        addTeachingItem(to: menu)
        guard let layout = layoutManager, let container = textContainer else { return menu }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x; point.y -= textContainerOrigin.y
        let glyph = layout.glyphIndex(for: point, in: container)
        let character = glyph < layout.numberOfGlyphs ? layout.characterIndexForGlyph(at: glyph) : (string as NSString).length
        guard glyph < layout.numberOfGlyphs else { return menu }
        if layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point), let tools = imageToolsItem(at: character) {
            menu.insertItem(.separator(), at: 0); menu.insertItem(tools, at: 0)
            let save = NSMenuItem(title: "Save Image to Photos", action: #selector(saveImageToPhotos(_:)), keyEquivalent: "")
            save.target = self; save.representedObject = tools.representedObject; menu.insertItem(save, at: 1)
        }
        let line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        guard point.y >= line.minY && point.y < line.maxY, let action = copyAction(at: character) else { return menu }
        let item = NSMenuItem(title: action.title, action: #selector(copyConversationBlock(_:)), keyEquivalent: "")
        item.target = self; item.tag = action.index
        menu.insertItem(.separator(), at: 0); menu.insertItem(item, at: 0)
        return menu
    }
    var messageLabels: [TranscriptMessageLabel] = []
    var userBlocks: [NSRange] = []
    var trafficBlocks: [NSRange] = []
    func refreshDecorations() { (enclosingScrollView as? ConversationScrollView)?.refreshLatest(); layoutDraftImageButtons(); needsDisplay = true; enclosingScrollView?.verticalRulerView?.needsDisplay = true }
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
    var droppedFileSourceDevice: String?
    override func keyDown(with event: NSEvent) {
        handlingSelectionGesture = true
        defer { handlingSelectionGesture = false }
        (enclosingScrollView as? ConversationScrollView)?.interaction()
        if event.keyCode == 53 { super.keyDown(with: event); return }
        if event.keyCode == 36 || event.keyCode == 76 {
            guard isEditable else { return }
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewline(nil); return
            }
            if isEditable { submit?() }; return
        }
        // Typing while reading history always goes to the current input.
        if selectedRange().location < inputStart && !event.modifierFlags.contains(.command),
           let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
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
        if item.action == #selector(undo(_:)) { return undoManager?.canUndo == true }
        if item.action == #selector(redo(_:)) { return undoManager?.canRedo == true }
        if item.action == #selector(performTextFinderAction(_:)) {
            guard Self.allowsFindAction(item.tag), let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
            return readOnlyFinder.validateAction(action)
        }
        if item.action == #selector(paste(_:)), Self.clipboardImage(.general) != nil { return imagePaste != nil }
        return super.validateUserInterfaceItem(item)
    }
    // Drops insert references; image paste continues to attach the image itself.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        let types = super.readablePasteboardTypes
        return types.contains(.fileURL) ? types : types + [.fileURL]
    }
    static func quoteDroppedPath(_ path: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.")
        if path.unicodeScalars.allSatisfy({ plain.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    @discardableResult func insertDroppedFiles(from board: NSPasteboard) -> Bool {
        guard isEditable else { return false }
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let paths = urls.filter(\.isFileURL).map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return false }
        window?.makeFirstResponder(self)
        if selectedRange().location < inputStart {
            setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        }
        let text: String
        if let device = droppedFileSourceDevice {
            text = paths.map { "file from " + device + ": " + Self.quoteDroppedPath($0) }.joined(separator: "\n")
        } else { text = paths.map(Self.quoteDroppedPath).joined(separator: " ") }
        insertText(text + " ", replacementRange: selectedRange())
        scrollRangeToVisible(selectedRange())
        return true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.types?.contains(.fileURL) == true {
            return isEditable && sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
        }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.types?.contains(.fileURL) == true {
            return isEditable && sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
        }
        return super.draggingUpdated(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if sender.draggingPasteboard.types?.contains(.fileURL) == true {
            return insertDroppedFiles(from: sender.draggingPasteboard)
        }
        return super.performDragOperation(sender)
    }
    override func paste(_ sender: Any?) {
        suppressSubstitutions = true; defer { suppressSubstitutions = false }
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
    var inputEnabled: Bool = true
    var droppedFileSourceDevice: String? = nil
    var onTeachSwitchboard: (() -> Void)? = nil
    var onSubmit: (() -> Void)? = nil
    var onDraftChanged: ((String) -> Void)? = nil
    var onImagePaste: ((NSImage) -> Void)? = nil
    var onImageRemove: ((String) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ConversationScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        scroll.contentView = InputClipView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.backgroundColor = NSColor.textBackgroundColor
        let text = ConversationTextView(frame: scroll.contentView.bounds)
        text.droppedFileSourceDevice = droppedFileSourceDevice
        session.inputTextView = text
        text.substitutionFeedback = session.substitutionFeedback
        text.minSize = NSSize(width: 0, height: 600)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.isEditable = true; text.isSelectable = true; text.isRichText = true
        text.usesFindBar = true; text.isIncrementalSearchingEnabled = true
        text.importsGraphics = false; text.allowsUndo = true
        text.registerForDraggedTypes([.fileURL])
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.font = .systemFont(ofSize: 16); text.backgroundColor = NSColor.textBackgroundColor
        text.delegate = context.coordinator
        text.setAccessibilityLabel("Conversation and message input. Return sends or queues. Command Return inserts a new line.")
        text.submit = inputEnabled ? context.coordinator.submissionHandler(text, action: onSubmit ?? { Store.shared.submit(session) }) : nil
        text.imagePaste = inputEnabled ? (onImagePaste ?? { Store.shared.attach(session, image: $0) }) : nil
        text.imageRemove = inputEnabled ? (onImageRemove ?? { Store.shared.removeDraftImage(session, path: $0) }) : nil
        text.isEditable = inputEnabled
        text.teachApp = Store.shared.sessions.contains(where: { $0.id == session.id }) ? { Store.shared.teachAppSupport(session) } : nil
        text.teachSession = onTeachSwitchboard ?? (Store.shared.sessions.contains(where: { $0.id == session.id }) ? { Store.shared.teachSwitchboard(session) } : nil)
        context.coordinator.draftChanged = onDraftChanged
        scroll.documentView = text
        scroll.verticalRulerView = MessageNumberRuler(scroll: scroll, text: text)
        scroll.hasVerticalRuler = true; scroll.rulersVisible = lineNumbers
        context.coordinator.render(text)
        if let selection = session.textSelection, NSMaxRange(selection) <= (text.string as NSString).length { text.setSelectedRange(selection) }
        if let origin = session.textScrollOrigin { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
        else { scroll.revealInitialTail() } // Startup: wait for the actual pane width and height.
        DispatchQueue.main.async {
            // A newly mounted pane must not steal focus from a question answer,
            // settings field, or another pane's draft.
            guard let window = text.window, window.isKeyWindow,
                  window.firstResponder == nil || window.firstResponder === window else { return }
            window.makeFirstResponder(text)
        }
        return scroll
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // The native scroll view starts wide, but must accept narrower split panes.
        CGSize(width: proposal.width ?? 700, height: proposal.height ?? 600)
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        scroll.rulersVisible = lineNumbers
        context.coordinator.draftChanged = onDraftChanged
        if let text = scroll.documentView as? ConversationTextView {
            text.droppedFileSourceDevice = droppedFileSourceDevice
            text.isEditable = inputEnabled
            text.teachApp = Store.shared.sessions.contains(where: { $0.id == session.id }) ? { Store.shared.teachAppSupport(session) } : nil
        text.teachSession = onTeachSwitchboard ?? (Store.shared.sessions.contains(where: { $0.id == session.id }) ? { Store.shared.teachSwitchboard(session) } : nil)
            text.submit = inputEnabled ? context.coordinator.submissionHandler(text, action: onSubmit ?? { Store.shared.submit(session) }) : nil
            text.imagePaste = inputEnabled ? (onImagePaste ?? { Store.shared.attach(session, image: $0) }) : nil
            text.imageRemove = inputEnabled ? (onImageRemove ?? { Store.shared.removeDraftImage(session, path: $0) }) : nil
            context.coordinator.render(text); text.refreshDecorations()
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.session.textScrollOrigin = scroll.contentView.bounds.origin
        coordinator.session.textSelection = (scroll.documentView as? NSTextView)?.selectedRange()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: Session
        var renderedMessages: [Message]?
        var seenMessagesRevision: UInt64?
        var renderedMessageNumbers: [UUID: Int] = [:]
        var renderedMessageNumberOffset = 0
        var renderedAttachments: [String] = []
        var messageStarts: [UUID: Int] = [:]
        var historyEnd = 0
        private(set) var historyBuildCount = 0
        private(set) var lastReplacementStart = 0
        var markdownCache: [UUID: (String, NSAttributedString)] = [:]
        private let imageCache = NSCache<NSString, NSTextAttachment>()
        private(set) var imagePreparationCount = 0
        func preparedImage(_ path: String) -> NSTextAttachment? {
            guard let info = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
            let key = "\(path)|\(info[.size] ?? 0)|\((info[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)" as NSString
            if let cached = imageCache.object(forKey: key) { return cached }
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)), let img = NSImage(data: bytes) else { return nil }
            let png: Data?
            if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { png = bytes }
            else { png = img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } }
            guard let png else { return nil }
            let attachment = NSTextAttachment(); attachment.image = img
            attachment.fileWrapper = FileWrapper(regularFileWithContents: png)
            attachment.fileWrapper?.preferredFilename = "Converse-image.png"
            let scale = min(1, 480 / max(img.size.width, 1), 260 / max(img.size.height, 1))
            attachment.bounds = NSRect(x: 0, y: 0, width: img.size.width * scale, height: img.size.height * scale)
            let preview = img.copy() as! NSImage; preview.size = attachment.bounds.size
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: preview)
            imageCache.countLimit = 256; imageCache.totalCostLimit = 128 * 1024 * 1024
            imageCache.setObject(attachment, forKey: key, cost: png.count)
            imagePreparationCount += 1
            return attachment
        }
        let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var rendering = false
        var draftChanged: ((String) -> Void)?
        var resolveSessionName: (String) -> String? = { DeviceSyncService.shared.switchboardDisplayName($0) }
        init(_ session: Session) { self.session = session }
        func submissionHandler(_ text: ConversationTextView, action: @escaping () -> Void) -> () -> Void {
            { [weak self, weak text] in
                action()
                // Return is handled before SwiftUI's next update. Consume the
                // native tail now so later edits/notifications cannot restore
                // the submitted draft. Failed or awaiting-ack sends keep it.
                if let self, let text { self.render(text) }
            }
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let text = textView as? ConversationTextView else { return false }
            let allowed = rendering || affectedCharRange.location >= text.inputStart
            if allowed { text.readOnlyFinder.noteClientStringWillChange() }
            return allowed
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            if !rendering, let text = notification.object as? ConversationTextView, text.handlingSelectionGesture {
                text.recordUserSelection()
            }
            guard let text = notification.object as? ConversationTextView, text.selectedRange().location >= text.inputStart else { return }
            text.typingAttributes = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: TranscriptPalette.draft(session.draft), .paragraphStyle: ConversationTextView.inputParagraphStyle]
        }
        func textDidChange(_ notification: Notification) {
            guard !rendering, let text = notification.object as? ConversationTextView else { return }
            session.draft = (text.string as NSString).substring(from: min(text.inputStart, (text.string as NSString).length))
            let length = (text.string as NSString).length
            if length > text.inputStart { text.textStorage?.addAttributes([.foregroundColor: TranscriptPalette.draft(session.draft), .paragraphStyle: ConversationTextView.inputParagraphStyle], range: NSRange(location: text.inputStart, length: length - text.inputStart)) }
            text.refreshDecorations()
            text.typingAttributes[.foregroundColor] = TranscriptPalette.draft(session.draft)
            text.fitDocumentHeight()
            text.explicitCursor = text.selectedRange().length > 0 || text.selectedRange().location < text.inputStart
            text.scrollRangeToVisible(text.selectedRange())
            if !text.explicitCursor { (text.enclosingScrollView as? ConversationScrollView)?.resumeFollowing() }
            else { (text.enclosingScrollView as? ConversationScrollView)?.interaction() }
            if let draftChanged { draftChanged(session.draft) }
            else { Store.shared.saveSoon() }
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url, AppSupport.handleLink(url) { return true }
            if let url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            return true
        }
        func render(_ text: ConversationTextView) {
            let restoreSubstitutionUndo = text.retainedSubstitutionUndo(for: session.draft)
            let began = ProcessInfo.processInfo.systemUptime
            defer {
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                if elapsed > 0.15 { NSLog("Converse slow transcript render: %.0f ms, %d messages, %d prepared images", elapsed * 1000, session.messages.count, imagePreparationCount) }
            }
            let previous = renderedMessages
            let firstRender = previous == nil
            var historyChanged = firstRender
            if seenMessagesRevision != session.messagesRevision {
                let messages = session.displayedMessages.filter { $0.role != "activity" && !($0.role == "notice" && TranscriptStyle.isQueueReceipt($0.text)) }
                historyChanged = previous != messages
                renderedMessages = messages; seenMessagesRevision = session.messagesRevision
            }
            let numberingChanged = renderedMessageNumbers != session.messageNumbers || renderedMessageNumberOffset != session.messageNumberOffset
            historyChanged = historyChanged || numberingChanged
            renderedMessageNumbers = session.messageNumbers; renderedMessageNumberOffset = session.messageNumberOffset
            let addedAttachment = session.attachments.contains { !renderedAttachments.contains($0) }
            let attachmentsChanged = renderedAttachments != session.attachments
            let current = text.textStorage?.mutableString ?? NSMutableString(string: text.string)
            if !historyChanged && !attachmentsChanged {
                guard current.length >= text.inputStart, current.substring(from: text.inputStart) != session.draft else { return }
                // External draft hydration/clear changes only the editable
                // tail. Native typing already changed it and returns above.
                let selection = text.selectedRange(), offset = max(0, selection.location - text.inputStart)
                rendering = true
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: TranscriptPalette.draft(session.draft), .paragraphStyle: ConversationTextView.inputParagraphStyle]
                text.textStorage?.replaceCharacters(in: NSRange(location: text.inputStart, length: current.length - text.inputStart), with: NSAttributedString(string: session.draft, attributes: attrs))
                text.typingAttributes = attrs; text.undoManager?.removeAllActions()
                if selection.location >= text.inputStart {
                    let length = (session.draft as NSString).length, at = min(offset, length)
                    text.setSelectedRange(NSRange(location: text.inputStart + at, length: min(selection.length, length - at)))
                }
                text.fitDocumentHeight(); text.refreshDecorations(); rendering = false
                return
            }
            let messages = renderedMessages ?? []
            var common = 0
            if let previous {
                while common < min(previous.count, messages.count) && previous[common] == messages[common] { common += 1 }
            }
            let unchangedPrefix = firstRender ? 0 : common == previous?.count ? historyEnd : previous.flatMap { common < $0.count ? messageStarts[$0[common].id] : nil } ?? 0
            renderedAttachments = session.attachments
            historyBuildCount += 1
            let selection = text.selectedRange()
            let editing = selection.location >= text.inputStart
            let offset = max(0, selection.location - text.inputStart)
            let scroll = text.enclosingScrollView
            let origin = scroll?.contentView.bounds.origin ?? .zero
            let nativeScroll = scroll as? ConversationScrollView
            let follow = (firstRender || historyChanged) && (nativeScroll?.prepareForRender(first: firstRender) ?? true)
            if !firstRender && historyChanged { nativeScroll?.outputArrived() }
            rendering = true
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2; paragraph.paragraphSpacing = 0
            let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
            let document = NSMutableAttributedString(string: "")
            func append(_ string: String, _ attrs: [NSAttributedString.Key: Any] = [:]) {
                document.append(NSAttributedString(string: string, attributes: base.merging(attrs) { _, new in new }))
            }
            @discardableResult func image(_ path: String) -> Bool {
                guard let attachment = preparedImage(path) else { return false }
                if document.length > 0 && !document.string.hasSuffix("\n") { append("\n") }
                document.append(NSAttributedString(attachment: attachment)); return true
            }
            text.messageLabels = []
            var messageNumber = max(0, session.messageNumberOffset)
            text.userBlocks = []
            text.trafficBlocks = []
            text.copyBlocks = []
            messageStarts = [:]
            for message in messages {
                messageStarts[message.id] = document.length
                let visible = Store.visibleText(message.text)
                if visible.isEmpty && message.images.isEmpty { continue }
                let body: NSMutableAttributedString
                let trafficSummary = TranscriptStyle.trafficSummary(visible, resolveName: resolveSessionName)
                if let summary = trafficSummary {
                    let oneLine = NSMutableParagraphStyle(); oneLine.lineBreakMode = .byTruncatingTail
                    body = NSMutableAttributedString(string: summary, attributes: base.merging([.toolTip: visible, .paragraphStyle: oneLine]) { _, value in value })
                    markdownCache[message.id] = (visible, NSAttributedString(string: visible, attributes: base))
                } else if message.role == "assistant" {
                    if let cached = markdownCache[message.id], cached.0 == visible { body = NSMutableAttributedString(attributedString: cached.1) }
                    else { body = MarkdownText.render(visible); markdownCache[message.id] = (visible, NSAttributedString(attributedString: body)) }
                } else { body = NSMutableAttributedString(string: visible, attributes: base) }
                for mark in (trafficSummary == nil ? message.delays ?? [] : []).sorted(by: { $0.offset > $1.offset }) {
                    let sourceOffset = min(max(0, mark.offset), (visible as NSString).length)
                    let renderedOffset = message.role == "assistant" ? MarkdownText.renderedOffset(in: visible, utf16Offset: sourceOffset) : sourceOffset
                    let at = min(renderedOffset, body.length)
                    body.insert(NSAttributedString(string: Store.delayLabel(mark.seconds) + " ", attributes: base.merging([.foregroundColor: NSColor.gray]) { _, new in new }), at: at)
                }
                if let detector = linkDetector {
                    let value = body.string as NSString
                    for match in detector.matches(in: body.string, range: NSRange(location: 0, length: value.length)) {
                        if let url = match.url, ["http", "https"].contains(url.scheme ?? "") { body.addAttribute(.link, value: url, range: match.range) }
                    }
                }
                if let timestamp = message.createdAt {
                    let hint = "Recorded " + timestamp.formatted(date: .abbreviated, time: .standard)
                    var ranges: [NSRange] = []
                    body.enumerateAttribute(.toolTip, in: NSRange(location: 0, length: body.length)) { value, range, _ in
                        if value == nil { ranges.append(range) }
                    }
                    for range in ranges { body.addAttribute(.toolTip, value: hint, range: range) }
                }
                let contentLength = TranscriptStyle.blockContentLength(body.string)
                body.deleteCharacters(in: NSRange(location: contentLength, length: body.length - contentLength))
                if body.length == 0 && message.images.isEmpty { continue }
                let start = document.length
                let traffic = TranscriptStyle.isTraffic(message.text) || message.finalReply.map(TranscriptStyle.isTraffic) == true
                if traffic { body.addAttribute(.foregroundColor, value: TranscriptPalette.traffic, range: NSRange(location: 0, length: body.length)) }
                if message.role == "user" {
                    body.addAttribute(.font, value: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 16), toHaveTrait: .italicFontMask), range: NSRange(location: 0, length: body.length))
                }
                document.append(body)
                if message.role == "user" || message.role == "assistant" {
                    let formatted = message.role == "assistant" ? markdownCache[message.id]!.1 : NSAttributedString(string: visible, attributes: body.length > 0 ? body.attributes(at: 0, effectiveRange: nil) : base)
                    text.copyBlocks.append(.init(range: NSRange(location: start, length: body.length), role: message.role, source: visible, formatted: formatted))
                }
                for path in message.images { image(path) }
                guard document.length > start else { continue }
                messageNumber = session.messageNumbers[message.id].flatMap { $0 > 0 ? $0 : nil } ?? (messageNumber + 1)
                text.messageLabels.append(TranscriptMessageLabel(location: start, number: messageNumber, prompt: message.role == "user", timestamp: message.createdAt))
                let last = document.length - 1
                let paragraphRange = (document.string as NSString).paragraphRange(for: NSRange(location: last, length: 0))
                let style = ((document.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle) ?? paragraph).mutableCopy() as! NSMutableParagraphStyle
                style.paragraphSpacing = TranscriptStyle.blockSpacing
                append("\n", [.paragraphStyle: style])
                document.addAttribute(.paragraphStyle, value: style, range: NSRange(location: paragraphRange.location, length: document.length - paragraphRange.location))
                if traffic { text.trafficBlocks.append(NSRange(location: start, length: max(0, document.length - start - 1))) }
                if message.role == "user" { text.userBlocks.append(NSRange(location: start, length: max(0, document.length - start - 1))) }
            }
            historyEnd = document.length
            text.draftImages = []
            for path in session.attachments {
                if image(path) { text.draftImages.append((document.length - 1, path)); append("\n") }
            }
            text.inputStart = document.length
            let draftStyle: [NSAttributedString.Key: Any] = [.foregroundColor: TranscriptPalette.draft(session.draft)]
            append(session.draft, draftStyle)
            // Layout preceding unchanged messages remains valid while an
            // assistant streams. Replacing the entire storage invalidates
            // every paragraph, even when only the final block changed.
            var prefix = min(unchangedPrefix, document.length, current.length)
            // A directory refresh can change an earlier traffic label without
            // changing its stored message. Never reuse offsets unless the
            // actual rendered prefix still matches the new document.
            if prefix > 0 && current.substring(to: prefix) != (document.string as NSString).substring(to: prefix) {
                prefix = 0
            }
            lastReplacementStart = prefix
            text.readOnlyFinder.noteClientStringWillChange()
            if prefix > 0 {
                text.textStorage?.replaceCharacters(in: NSRange(location: prefix, length: current.length - prefix), with: document.attributedSubstring(from: NSRange(location: prefix, length: document.length - prefix)))
            } else { text.textStorage?.setAttributedString(document) }
            text.configureDraftImageButtons()
            text.typingAttributes = base.merging(draftStyle) { _, value in value }
            text.insertionPointColor = .systemBlue
            text.undoManager?.removeAllActions()
            restoreSubstitutionUndo?()
            if session.draft.isEmpty && selection.length == 0 && !text.explicitCursor { text.setSelectedRange(NSRange(location: document.length, length: 0)) }
            else if editing || firstRender { text.setSelectedRange(NSRange(location: min(document.length, text.inputStart + offset), length: min(selection.length, max(0, document.length - text.inputStart - offset)))) }
            else {
                let start = min(selection.location, document.length)
                text.setSelectedRange(NSRange(location: start, length: min(selection.length, document.length - start)))
            }
            text.typingAttributes = base.merging(draftStyle) { _, value in value }
            text.layoutManager?.ensureLayout(for: text.textContainer!)
            text.fitDocumentHeight()
            if addedAttachment {
                nativeScroll?.jumpToLatest()
                text.scrollRangeToVisible(NSRange(location: text.inputStart, length: 0))
            } else if follow {
                if let nativeScroll { nativeScroll.followLatest() }
                else { text.scrollRangeToVisible(NSRange(location: document.length, length: 0)) }
            }
            else if let scroll {
                let bounds = NSRect(origin: origin, size: scroll.contentView.bounds.size)
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
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
                Toggle("message numbers", isOn: $store.lineNumbers).toggleStyle(.checkbox).font(.caption).fixedSize()
                Button { let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true; if panel.runModal() == .OK { for url in panel.urls { if let image = NSImage(contentsOf: url) { Store.shared.attach(session, image: image) } } } } label: { Image(systemName: "paperclip") }.help("Attach image or paste a screenshot")
                if !session.attachments.isEmpty { Button("Clear images") { session.attachments = []; Store.shared.saveSoon() } }
                if session.busy { if session.requests.isEmpty && !session.status.hasPrefix("Waiting") { ProgressView().controlSize(.small) }; Button("Stop") { Store.shared.stop(session) } }
            }.padding(.horizontal, 10).padding(.vertical, 5)
            if !session.shareNotice.isEmpty {
                HStack {
                    Text(session.shareNotice).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }.padding(.horizontal, 10).padding(.vertical, 3)
                Divider()
            }
            Divider()
            if session.needsSignIn && session.entry.engine != "muse" {
                HStack {
                    Text("Sign in to this conversation’s account, or choose another account below.").font(.caption)
                    Spacer()
                    Button("Sign in to \(session.entry.accountName ?? session.entry.name)…") { store.signInSession(session) }
                        .disabled(session.busy || session.changingSetting)
                }.padding(8).background(Color.orange.opacity(0.1))
            }
            if session.needsApproval && !session.requests.contains(where: { $0.kind == "approval" }) {
                ApprovalHeading(detail: session.agent?.attention ?? session.status, title: session.agent == nil ? "PERMISSION REQUIRED" : "ATTENTION REQUIRED")
            }
            if let request = session.requests.first { MuseRequestView(session: session, request: request).id(request.id) }
            if !session.injectionNotice.isEmpty {
                HStack {
                    Text(session.injectionNotice).fontWeight(.semibold); Spacer()
                    if !session.interrupted { Button("Dismiss") { session.injectionNotice = "" } }
                }.font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.22))
            }
            SwitchboardStatusView(session: session)
            if !session.pending.isEmpty { PendingMessagesView(session: session) }
            ScrollingConversation(session: session, lineNumbers: store.lineNumbers)
                .overlay(alignment: .bottomTrailing) { SubstitutionButton(feedback: session.substitutionFeedback).padding(.trailing, 12).padding(.bottom, 80) }
                .overlay(alignment: .bottomTrailing) {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        if let state = session.compactionState { CompactionControl(state: state) { if session.compactionRequested { session.compactionRequested = false } else { _ = store.requestCompaction(session) } }.disabled(session.changingSetting || session.interrupted).padding(.trailing, 12).padding(.bottom, 46) }
                    }
                }
            Divider()
            if session.needsAgentSetup {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Agent settings are missing · automatic work is paused").foregroundStyle(.orange)
                    Button("Open Agent Setup…") { AgentWindows.shared.setup(session) }.buttonStyle(.link)
                        .help(Session.missingAgentSettings)
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            } else if session.agent != nil { AgentControls(session: session) } else {
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text(session.status).help(session.status)
                            Text(AssistantFamily.name(session.entry.engine)).foregroundStyle(.primary)
                            loginButton
                            Text("Last turn: " + session.toolStatus.usage).help("Last turn: " + session.toolStatus.usage)
                            refreshButton
                        }
                        HStack(spacing: 12) { settingControls }.disabled(session.changingSetting)
                        AccountStatusView(status: session.toolStatus, refreshing: session.probingStatus) { store.refreshStatus(session, quota: true) }
                    }.fixedSize(horizontal: true, vertical: false)
                    HStack(spacing: 8) {
                        Text(session.status).lineLimit(1).truncationMode(.tail).help(session.status)
                        Text(AssistantFamily.name(session.entry.engine)).foregroundStyle(.primary).fixedSize()
                        Spacer(minLength: 0)
                        AccountStatusView(status: session.toolStatus, refreshing: session.probingStatus, compact: true) { store.refreshStatus(session, quota: true) }
                        Menu {
                            Text("Account: " + store.sessionLoginLabel(session))
                            loginButton
                            Text("Last turn: " + session.toolStatus.usage)
                            Button("Refresh status") { store.refreshStatus(session, quota: true) }.disabled(session.probingStatus)
                            Divider()
                            Group { settingControls }.disabled(session.changingSetting)
                        } label: { Image(systemName: "ellipsis.circle") }
                            .fixedSize().accessibilityLabel("Session settings")
                            .help("Account: " + store.sessionLoginLabel(session) + "\nLast turn: " + session.toolStatus.usage + "\nModel, effort, permissions and account settings")
                    }
                }
                if !session.settingNotice.isEmpty { Text(session.settingNotice).foregroundStyle(.primary).help(session.settingNotice) }
                if !session.probeError.isEmpty { ProviderStatusRepairView(session: session) }
            }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
        }.background(Color(nsColor: .textBackgroundColor)).onAppear { Store.shared.refreshStatus(session) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if !session.busy { store.refreshStatus(session) } }
    }
    private var loginButton: some View {
        Button { AppDelegate.shared.chooseLogin(session) } label: {
            Text(store.sessionLoginLabel(session)).lineLimit(1).truncationMode(.middle)
        }.buttonStyle(.borderless).disabled(session.busy || session.changingSetting)
            .help("Account: " + store.sessionLoginLabel(session) + "\nChoose an existing login, add a new login, or sign in again. /login opens the same picker.")
    }
    private var refreshButton: some View {
        Button { store.refreshStatus(session, quota: true) } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.plain).disabled(session.probingStatus).help("Refresh this account's models and session status")
    }
    @ViewBuilder private var settingControls: some View {
                        Menu("Model: " + session.toolStatus.model) {
                            if session.entry.engine != "muse" { Button("CLI default") { store.clearOverride(session, field: "model") }; Divider() }
                            ForEach(session.modelChoices) { model in Button(model.label) { store.changeSetting(session, .model(model)) } }
                            Divider()
                            Button("Other model…") { store.chooseCustomModel(session) }
                        }.menuStyle(.borderlessButton).fixedSize()
                        Menu("Effort: " + session.toolStatus.effort) {
                            if session.entry.engine != "muse" { Button("CLI default") { store.clearOverride(session, field: "effort") }; Divider() }
                            if session.availableEfforts.isEmpty { Text(session.probingStatus ? "Loading supported effort levels…" : "This model has no reported effort options") }
                            ForEach(session.availableEfforts, id: \.self) { effort in Button(effort) { store.changeSetting(session, .effort(effort)) } }
                            Divider()
                            Button("Other effort…") { store.chooseCustomEffort(session) }
                        }.menuStyle(.borderlessButton).fixedSize()
                        Menu("Permissions: " + session.toolStatus.access) {
                            if session.entry.engine != "muse" { Button("CLI default") { store.clearOverride(session, field: "access") }; Divider() }
                            ForEach(session.accessChoices) { access in Button(access.label) { store.changeSetting(session, .access(access.id)) }.disabled(!access.available) }
                        }.menuStyle(.borderlessButton).fixedSize()
                        if session.compactionState != nil {
                            Button("Compact") { _ = store.requestCompaction(session) }
                                .disabled(session.compacting || session.compactionRequested || session.changingSetting)
                                .help(session.busy ? "Compact after this turn" : "Compact context")
                        }
    }

}

struct SidebarActionButton: View {
    let emoji: String
    let title: String
    let showTitle: Bool
    let help: String
    var badge: Int = 0
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(emoji).font(.system(size: 15))
                if showTitle { Text(title).font(.system(size: 11)).lineLimit(1).fixedSize() }
                if badge > 0 { Text(String(badge)).font(.system(size: 10, weight: .bold)).foregroundStyle(.orange) }
            }.frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .background(hovered ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(hovered ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.12), lineWidth: 1))
            .onHover { hovered = $0 }.help(help).accessibilityLabel(title)
    }
}

struct RootView: View {
    @ObservedObject var sidebarOrder = SidebarOrder.shared
    @ObservedObject var store = Store.shared
    @ObservedObject var workspace = Workspace.shared
    @ObservedObject var devices = DeviceSyncService.shared
    @ObservedObject var state: WindowState
    var body: some View {
        HSplitView {
            GeometryReader { sidebar in
            if state.sidebarCollapsed {
                Color.clear
            } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    sidebarPin
                    Text("Conversation").lineLimit(1).truncationMode(.tail).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 24, height: 12).accessibilityHidden(true)
                    Button(sidebarOrder.reordering ? "Done" : "Reorder") { sidebarOrder.reordering.toggle() }.frame(width: 98, alignment: .leading)
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let group = devices.currentGroup {
                            Text(group.name + " group").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 4).help("Converse group: " + group.name + ". Choose a pane number to bring a session here.")
                        }
                        OrderedDeviceSidebar(workspace: workspace, state: state)
                    }.padding(.top, 6)
                }
                HStack(spacing: 6) {
                    SidebarActionButton(emoji: "🚗", title: "Parking Lots", showTitle: sidebar.size.width >= 320,
                        help: "Create a Parking Lot") { ParkingLotLibrary.shared.promptNew() }
                    SidebarActionButton(emoji: "😎", title: "Agents", showTitle: sidebar.size.width >= 320,
                        help: "Create an agent") { AgentWindows.shared.create() }
                    SidebarActionButton(emoji: "👥", title: "Groups", showTitle: sidebar.size.width >= 320,
                        help: "Manage Groups" + (devices.groupRequests.isEmpty ? "" : " · \(devices.groupRequests.count) pairing requests"),
                        badge: devices.groupRequests.count) { state.deviceConnect = true }
                }.padding(.vertical, 4)
                HStack {
                    Button("New window", systemImage: "macwindow.badge.plus") { AppDelegate.shared.newWindow() }
                    Spacer()
                    Text("\(workspace.names.count) window\(workspace.names.count == 1 ? "" : "s")").font(.caption)
                    Button { state.settings = true } label: { Image(systemName: "slider.horizontal.3") }.help("Settings")
                }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.bottom, 6)
            }.padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }.frame(minWidth: state.sidebarCollapsed ? PaneSizing.collapsedSidebar : PaneSizing.minimumSidebar, idealWidth: state.sidebarCollapsed ? PaneSizing.collapsedSidebar : 340, maxWidth: state.sidebarCollapsed ? PaneSizing.collapsedSidebar : 480)
            WorkspacePanes(workspace: workspace, state: state).overlay(alignment: .topLeading) {
                if state.sidebarCollapsed { sidebarPin.padding(.leading, 6).padding(.top, 3) }
            }
        }.sheet(isPresented: $state.settings) { SettingsView(state: state) }.sheet(isPresented: $state.deviceConnect) { DeviceConnectView() }.sheet(isPresented: $state.setup) { SetupView(state: state) }.sheet(item: $state.sessionSetup) { SessionSetupView(request: $0, state: state) }.frame(minWidth: 760, minHeight: 540)
    }
    private var sidebarPin: some View {
        Button {
            state.sidebarCollapsed.toggle()
            AppDelegate.shared?.paneLayouts[state.id]?.setSidebarCollapsed(state.sidebarCollapsed)
        } label: {
            Image(systemName: state.sidebarCollapsed ? "pin" : "pin.fill").font(.system(size: 11)).frame(width: 16, height: 20)
        }.buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel(state.sidebarCollapsed ? "Show conversation sidebar" : "Hide conversation sidebar")
            .help(state.sidebarCollapsed ? "Show conversations at the previous sidebar width" : "Minimize the conversation sidebar")
    }
}
struct SettingsView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var substitutions = TextSubstitutions.shared
    @ObservedObject var state: WindowState
    @StateObject private var flow = SettingsFlow()
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Models & sessions").font(.title2.bold())
            Toggle("Text substitutions while typing", isOn: Binding(get: { substitutions.enabled }, set: { substitutions.changeFromUI($0) }))
                .help("Turn :-) into 🙂 and --> into → after a space. Undo restores the literal text. Pasted text and Markdown code stay unchanged.")
            Text("Choose a model, create a session, then bind its login. Existing conversations keep their history and login.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(store.assistantFamilies, id: \.self) { engine in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(AssistantFamily.name(engine)).font(.headline)
                                Spacer()
                                Button("New session…") { flow.request = SessionSetupRequest(engine: engine) }
                            }
                            ForEach(store.sessions.filter { $0.entry.engine == engine }) { session in
                                SessionSettingsRow(session: session, store: store, flow: flow)
                            }
                            DisclosureGroup("Saved logins") {
                                ForEach($store.accounts) { $profile in
                                    if profile.engine == engine {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                TextField("Login name", text: $profile.name)
                                                if engine != "muse" { Button("Sign in…") { store.signIn(profile) }.disabled(store.accountIsBusy(profile) || !store.sessionsUsingLogin(profile).isEmpty).help("For a saved login in use, choose Login… on its session to authenticate independently.") }
                                            }
                                            if engine != "muse" { TextField("CLI configuration folder", text: $profile.directory) }
                                        }.padding(.vertical, 4)
                                    }
                                }
                                Text("Add a new login when creating a session or through its Login… button.").font(.caption).foregroundStyle(.secondary)
                            }
                            DisclosureGroup("Advanced launch configurations") {
                                ForEach($store.entries) { $entry in
                                    if entry.engine == engine {
                                        VStack(alignment: .leading, spacing: 6) {
                                            TextField("Configuration name", text: $entry.name)
                                            TextField("CLI command", text: $entry.command)
                                            TextField("Default working folder", text: $entry.directory)
                                        }.padding(.vertical, 4)
                                    }
                                }
                            }
                        }.padding(12).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.textFieldStyle(.roundedBorder)
            HStack {
                Menu("Add model") {
                    ForEach(SetupCatalog.entries.filter { candidate in !store.entries.contains { $0.engine == candidate.engine } }) { entry in
                        Button(entry.name) { store.entries.append(entry); store.save() }
                    }
                }
                Spacer()
                Button("Done") { store.save(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 600, height: 580).onDisappear { store.save() }
            .sheet(item: $flow.request) { SessionSetupView(request: $0, state: state) }
    }
}
final class SettingsFlow: ObservableObject { @Published var request: SessionSetupRequest? = nil }
struct ConverseQuitWarning {
    let title: String
    let detail: String
    let quitButton: String
    init?(sessions: [Session]) {
        // Built-in support must never hold up Quit, even during a reply or check.
        // Use its persisted role, not its editable display name.
        let work = sessions.filter { !$0.supportAssistant }
        let running = work.filter(\.busy).count
        // Store contains home sessions only; remote viewers must not warn about
        // agents whose execution continues on a different device.
        let agents = work.filter { $0.agent?.canSchedule == true }.count
        guard running > 0 || agents > 0 else { return nil }
        title = running > 0 ? "Quit with \(running) running session\(running == 1 ? "" : "s")?" : "Quit Converse?"
        quitButton = running > 0 ? "Stop and Quit" : "Quit Converse"
        var paragraphs: [String] = []
        if running > 0 { paragraphs.append("Quitting stops active commands.") }
        if agents > 0 {
            paragraphs.append("\(agents) agent\(agents == 1 ? "" : "s") with enabled loops will not run until the app is restarted.")
        }
        paragraphs.append("Your conversations, drafts, and settings are saved.")
        detail = paragraphs.joined(separator: "\n\n")
    }
}

extension Store {
    // Only close hosts owned by this app. Keep the main run loop alive so pipe
    // closure, process-exit callbacks and the bounded forced-stop fallback run.
    func closeMuseHostsForQuit(completion: @escaping () -> Void) {
        let hosts = sessions.compactMap { $0.muse }
        let group = DispatchGroup()
        for host in hosts {
            group.enter()
            host.close { group.leave() }
        }
        group.notify(queue: .main) { self.save(); self.configurationAudit.record("quit_save_completed"); completion() }
    }
    func requestApplicationQuit(confirm: (ConverseQuitWarning) -> Bool, stopAgents: () -> Void) -> Bool {
        if let warning = ConverseQuitWarning(sessions: sessions), !confirm(warning) { return false }
        configurationAudit.record("quit_accepted", ["busySessions": sessions.filter(\.busy).count, "configuredAgents": sessions.filter { $0.agent != nil }.count])
        applicationQuitting = true
        // Stop the scheduler before stopping CLI sessions or saving. Agent shutdown
        // preserves enabled loops and held queues; ordinary Stop deliberately pauses.
        stopAgents()
        for session in sessions where session.busy && session.agent == nil { stop(session) }
        save()
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate!
    var windows: [(NSWindow, WindowState)] = []
    var paneObserver: AnyCancellable?
    var paneLayouts: [UUID: WindowPaneLayout] = [:]
    private var quitting = false
    private var quitReady = false
    private var resettingDemo = false
    var transcriptExporter: TranscriptExportController?
    lazy var helpController = ConverseHelpController()
    lazy var jollyController = MainActor.assumeIsolated { JollyWindowController() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.appearance = nil
        paneObserver = Workspace.shared.$placements.sink { [weak self] placements in self?.updatePaneWidths(placements) }
        if ProcessInfo.processInfo.environment["CONVERSE_QA_APPROVAL"] == "1",
           ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil,
           ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"] != nil,
           let preview = Store.shared.sessions.first(where: { $0.entry.engine == "muse" }) {
            preview.requests = [MuseRequest(id: "isolated-approval-preview", kind: "approval", params: ["toolName": "Offline permission preview", "rawArgs": "Read a test file in the isolated QA folder", "availableChoices": [["choiceId": "allow-once", "label": "Allow once"], ["choiceId": "deny", "label": "Deny"]]])]
            preview.status = "Waiting for your approval"
        }
        buildMenu()
        let savedWindows = Workspace.shared.restore(folder: Store.shared.folder)
        if savedWindows.isEmpty { newWindow() }
        else { for id in savedWindows { makeWindow(WindowState(id: id)) } }
        NSApp.activate(ignoringOtherApps: true)
        DeviceSyncService.shared.startIfNeeded()
        AgentRuntime.shared.start()
        JollyRouter.shared.start()
        if ProcessInfo.processInfo.environment["CONVERSE_QA_GROUPS"] == "1", ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil, ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"] != nil, let state = windows.first?.1 {
            do {
                let devices = DeviceSyncService.shared
                try devices.configureForTesting(folder: Store.shared.folder); try devices.enableGroupsForTesting()
                devices.createGroup(name: "Design review")
                state.deviceConnect = true
            } catch { fputs("Group preview unavailable\n", stderr) }
        }
        if ProcessInfo.processInfo.environment["CONVERSE_QA_AGENT"] == "1", ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil, ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"] != nil, let state = windows.first?.1 {
            let agent = Store.shared.createAgent(title: "Isolated steward preview")
            agent.agent?.snapshot = AgentRepoSnapshot(repository: "fixture/project", stars: 12, openPRs: 2, openIssues: 4, openBugs: 1, conversationComments: 18, releaseDownloads: 23, visitors14d: 7)
            agent.agent?.attention = "Define the release acceptance criteria."
            agent.agent?.widgetSummary = "Preview data only. Ready to compare evidence across the development sessions."
            agent.messages.append(Message(role: "assistant", text: "What are we building, and what must be true for the demo to count as a success?"))
            select(agent, state: state); AgentWindows.shared.widget(agent)
        }
        if ProcessInfo.processInfo.environment["CONVERSE_QA_REMOTE"] == "1",
           ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil,
           ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"] != nil,
           let state = windows.first?.1 {
            let devices = DeviceSyncService.shared
            let busyPreview = ProcessInfo.processInfo.environment["CONVERSE_QA_BUSY"] == "1"
            let id = UUID(); let globalID = DeviceGlobalID(home: "isolated-preview", session: id).string
            let messages = Store.shared.sessions.first(where: { $0.title == "Gutter style check" })?.messages ?? []
            devices.homes["isolated-preview"] = RemoteHomeState(deviceID: "isolated-preview", deviceName: "Offline QA Mac", online: true, rows: [DeviceSidebarRow(globalID: globalID, sessionID: id, title: "Remote editor QA", assistant: "Claude", engine: "claude", model: "fixture", effort: "high", access: "Manual", status: busyPreview ? "Working…" : "Ready", busy: busyPreview, queued: 0, queuePaused: false)])
            devices.remoteLeases[globalID] = 1
            devices.remoteTranscripts[globalID] = DeviceTranscriptPayload(globalID: globalID, homeSeq: 1, epoch: 1, messages: messages.map { DeviceWireMessage(id: $0.id, role: $0.role, text: $0.text) }, draft: "A blue remote draft", draftVersion: 1, busy: false, status: "Ready", title: "Remote editor QA", engine: "claude")
            Workspace.shared.assign(devices.placementID(forGlobal: globalID), to: state.id, pane: 1)
            if ProcessInfo.processInfo.environment["CONVERSE_QA_PAIRING"] == "1" {
                devices.pairingPrompt = PairingPrompt(connectionID: UUID(), peerName: "Offline QA Mac", fingerprint: "OFFLINE PREVIEW", code: "1111 2222 3333 4444 5555 6666 7777 8888", keyChanged: false, isInitiator: false)
                state.deviceConnect = true
            }
        }
    }
    func buildMenu() {
        let menu = NSMenu(); let app = NSMenuItem(); menu.addItem(app); let sub = NSMenu(); app.submenu = sub
        sub.addItem(withTitle: "About Converse", action: #selector(about), keyEquivalent: "")
        sub.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        sub.addItem(withTitle: "Setup…", action: #selector(showSetup), keyEquivalent: "")
        if DemoReset.enabled { sub.addItem(withTitle: "Reset Demo…", action: #selector(resetDemo), keyEquivalent: "") }
        sub.addItem(withTitle: "Jolly…", action: #selector(showJolly), keyEquivalent: "")
        sub.addItem(withTitle: "New Agent…", action: #selector(newAgent), keyEquivalent: ""); sub.addItem(withTitle: "Converse Groups…", action: #selector(showDeviceConnect), keyEquivalent: ""); sub.addItem(.separator()); sub.addItem(withTitle: "Quit Converse", action: #selector(quitConverse(_:)), keyEquivalent: "q")
        let file = NSMenuItem(); file.title = "File"; menu.addItem(file); let f = NSMenu(title: "File"); file.submenu = f
        let new = NSMenuItem(title: "New", action: nil, keyEquivalent: ""); let choices = NSMenu(title: "New"); new.submenu = choices; f.addItem(new)
        choices.addItem(withTitle: "Parking Lot…", action: #selector(newParkingLot), keyEquivalent: "")
        choices.addItem(withTitle: "Agent…", action: #selector(newAgent), keyEquivalent: "")
        choices.addItem(withTitle: "Group…", action: #selector(showDeviceConnect), keyEquivalent: "")
        f.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        f.addItem(withTitle: "Export…", action: #selector(exportTranscripts), keyEquivalent: "")
        f.addItem(withTitle: "Restore Closed Conversation", action: #selector(restoreDeletedConversation), keyEquivalent: "")
        f.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenuItem(); edit.title = "Edit"; menu.addItem(edit); let e = NSMenu(title: "Edit"); edit.submenu = e
        for (name, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { e.addItem(withTitle: name, action: Selector(action), keyEquivalent: key) }
        e.addItem(.separator())
        for (title, key, tag) in [("Find…", "f", NSTextFinder.Action.showFindInterface.rawValue), ("Find Next", "g", NSTextFinder.Action.nextMatch.rawValue), ("Find Previous", "G", NSTextFinder.Action.previousMatch.rawValue)] {
            let item = e.addItem(withTitle: title, action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: key)
            item.tag = Int(tag)
        }
        let window = NSMenuItem(); window.title = "Window"; menu.addItem(window); let w = NSMenu(title: "Window"); window.submenu = w
        w.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"); w.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""); NSApp.windowsMenu = w
        let help = NSMenuItem(); help.title = "Help"; menu.addItem(help); let h = NSMenu(title: "Help"); help.submenu = h
        h.addItem(withTitle: "Converse Help…", action: #selector(showConverseHelp), keyEquivalent: "?")
        h.addItem(withTitle: "Report a Bug on GitHub…", action: #selector(reportConverseBug), keyEquivalent: "")
        h.addItem(withTitle: "Security & Privacy…", action: #selector(showSecurityHelp), keyEquivalent: "")
        NSApp.mainMenu = menu
        NSApp.helpMenu = h
        NSApp.registerUserInterfaceItemSearchHandler(helpController)
    }
    @objc func quitConverse(_ sender: Any?) {
        // SwiftUI's non-dismissable onboarding sheet must close before AppKit
        // can complete termination. The unfinished setup stays persisted.
        let setupWindows = windows.filter { $0.1.setup }.map { $0.0 }
        for (_, state) in windows { state.setup = false }
        finishQuitAfterSheets(sender, setupWindows: setupWindows)
    }
    private func finishQuitAfterSheets(_ sender: Any?, setupWindows: [NSWindow]) {
        guard !setupWindows.contains(where: { $0.attachedSheet != nil }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.finishQuitAfterSheets(sender, setupWindows: setupWindows) }
            return
        }
        NSApp.terminate(sender)
    }
    @objc func showDeviceConnect() {
        guard Store.shared.setupCompleted else { showSetup(); return }
        if windows.isEmpty { newWindow() }
        guard let (window, state) = windows.first(where: { $0.0.isKeyWindow }) ?? windows.last else { return }
        state.deviceConnect = true
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showSettings() {
        guard Store.shared.setupCompleted else { showSetup(); return }
        if windows.isEmpty { newWindow() }
        (windows.first { $0.0.isKeyWindow } ?? windows.last)?.1.settings = true
    }
    @objc func showSetup() {
        if windows.isEmpty { newWindow() }
        guard let state = (windows.first { $0.0.isKeyWindow } ?? windows.last)?.1 else { return }
        state.settings = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { state.setup = true }
    }
    @objc func showJolly() { guard Store.shared.setupCompleted else { helpController.show(topic: "jolly-mac", query: ""); return }; MainActor.assumeIsolated { jollyController.show() } }
    @objc func reportConverseBug() { MainActor.assumeIsolated { BugReportWindow.show(report: GitHubBugReport(title: "", body: "What happened:\n\nSteps to reproduce:\n\nWhat I expected:\n\nConverse " + ConverseAbout.versionBuild)) } }
    @objc func showSecurityHelp() { helpController.show(topic: "security-and-privacy", query: "") }
    @objc func showConverseHelp() { helpController.show() }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Converse", .applicationVersion: ConverseAbout.versionBuild, .version: "", .credits: NSAttributedString(string: ConverseAbout.copyright + "\n" + ConverseAbout.license + "\nhttps://github.com/richardkaufmann/converse\nrichard@kaoslabs.app")]) }
    @objc func newWindow() { makeWindow(WindowState()) }
    private func makeWindow(_ state: WindowState) {
        state.setup = !Store.shared.setupCompleted
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 760, height: 540)
        window.title = (Bundle.main.object(forInfoDictionaryKey: "ConverseNUXPreview") as? Bool == true ? (Bundle.main.object(forInfoDictionaryKey: "ConverseDemo") as? Bool == true ? "Converse Demo" : "Converse Setup Preview") : state.title) + " · " + ConverseAbout.versionBuild; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false; window.delegate = self
        let title = NSTitlebarAccessoryViewController(); title.layoutAttribute = .left
        title.view = NSHostingView(rootView: WindowTitle(workspace: .shared, state: state)); title.view.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        window.addTitlebarAccessoryViewController(title)
        window.contentView = NSHostingView(rootView: RootView(state: state)); window.center(); window.setFrameAutosaveName("ConverseWindow")
        if let (previous, _) = windows.last { window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24)) }
        windows.append((window, state)); paneLayouts[state.id] = WindowPaneLayout(window: window); window.makeKeyAndOrderFront(nil)
        paneLayouts[state.id]?.setPaneCount(Workspace.shared.placements.values.filter { $0.windowID == state.id }.count)
        NSApp.addWindowsItem(window, title: state.title, filename: false)
    }
    func updatePaneWidths(_ placements: [UUID: PaneLocation]) {
        for (_, state) in windows {
            paneLayouts[state.id]?.setPaneCount(placements.values.filter { $0.windowID == state.id }.count)
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
            Workspace.shared.rename(id, to: values[0]); window.title = state.title + " · " + ConverseAbout.versionBuild
            NSApp.changeWindowsItem(window, title: state.title, filename: false)
        }
    }
    func assign(_ session: Session, to state: WindowState, pane: Int) {
        guard Store.shared.sessions.contains(where: { $0.id == session.id }) else { return }
        // Taking a session shows its transcript: any unseen response is seen.
        session.unseenResponse = false
        DeviceSyncService.shared.releaseDisplaced(in: state.id, pane: pane, incomingPlacement: session.id)
        DeviceSyncService.shared.localTake(sessionID: session.id)
        Workspace.shared.assign(session.id, to: state.id, pane: pane)
        if let (window, _) = windows.first(where: { $0.1.id == state.id }) { window.makeKeyAndOrderFront(nil) }
    }
    @objc func newParkingLot() { ParkingLotLibrary.shared.promptNew() }
    @objc func newAgent() { guard Store.shared.setupCompleted else { showSetup(); return }; MainActor.assumeIsolated { AgentWindows.shared.create() } }
    @objc func restoreDeletedConversation() {
        guard let session = Store.shared.restoreDeleted() else { return }
        if windows.isEmpty { newWindow() }
        if let (_, state) = windows.first(where: { $0.0.isKeyWindow }) ?? windows.last { select(session, state: state) }
    }
    func configurationForm(title: String, values: [(String, String)], explanation: String = "", save: ([String]) -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = explanation
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
    func renameSession(_ session: Session) {
        configurationForm(title: "Rename conversation", values: [("Conversation name", session.title)]) { values in
            guard !values[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            session.title = values[0]; Store.shared.save()
        }
    }
    func configureSession(_ session: Session) {
        guard !session.busy else { return }
        configurationForm(title: "Configure conversation", values: [("Conversation name", session.title), ("Command", session.entry.command), ("Working directory", session.entry.directory)], explanation: "The title updates immediately. The working folder and command apply to the next turn; this conversation keeps its history and login.") { values in
            do { try Store.shared.configure(session, title: values[0], command: values[1], directory: values[2]) }
            catch { let alert = NSAlert(); alert.messageText = "Could not save conversation settings"; alert.informativeText = error.localizedDescription; alert.runModal() }
        }
    }
    func showSession(_ session: Session) {
        if windows.isEmpty { newWindow() }
        let target = windows.first { $0.0.isKeyWindow } ?? windows.last
        if let (window, state) = target { select(session, state: state); window.makeKeyAndOrderFront(nil) }
    }
    func newSession(_ entry: Entry, state: WindowState) { state.sessionSetup = SessionSetupRequest(engine: entry.engine) }
    func chooseLogin(_ session: Session) {
        if windows.isEmpty { newWindow() }
        guard let (_, state) = windows.first(where: { $0.0.isKeyWindow }) ?? windows.last else { return }
        state.sessionSetup = SessionSetupRequest(engine: session.entry.engine, sessionID: session.id)
    }
    func select(_ session: Session, state: WindowState) {
        let pane = Workspace.shared.pane(for: session.id, in: state.id) ?? Workspace.shared.firstAvailablePane(in: state.id)
        assign(session, to: state, pane: pane)
    }
    func windowWillClose(_ notification: Notification) {
        guard !quitting else { return }
        guard let window = notification.object as? NSWindow, let (_, state) = windows.first(where: { $0.0 === window }) else { return }
        paneLayouts.removeValue(forKey: state.id)
        DeviceSyncService.shared.releaseWindow(placements: Workspace.shared.placements, windowID: state.id)
        Workspace.shared.close(state.id); NSApp.removeWindowsItem(window)
        windows.removeAll { $0.0 === window }; Store.shared.save()
    }
    @objc func resetDemo() {
        guard DemoReset.enabled, !quitting else { return }
        let alert = NSAlert()
        alert.messageText = "Reset Converse Demo?"
        alert.informativeText = "This stops Demo’s work and quits. Reopen Converse Demo to start the welcome walkthrough again, with fresh sessions, provider logins and Group pairing. Saved Demo API tokens will be removed. The old Demo files are kept in a local backup. Your normal Converse app and project files are untouched."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Reset and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try DemoReset.request(folder: Store.shared.folder, enabled: DemoReset.enabled)
            resettingDemo = true
            quitConverse(nil)
        } catch { NSAlert(error: error).runModal() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { newWindow() }; return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitReady { return .terminateNow }
        if quitting { return .terminateCancel }
        let confirmed = Store.shared.requestApplicationQuit(confirm: { warning in
            if self.resettingDemo { return true }
            let alert = NSAlert()
            alert.messageText = warning.title; alert.informativeText = warning.detail
            alert.addButton(withTitle: "Keep Running"); alert.addButton(withTitle: warning.quitButton)
            return alert.runModal() == .alertSecondButtonReturn
        }, stopAgents: { MainActor.assumeIsolated { JollyRouter.shared.stop(store: .shared); AgentRuntime.shared.prepareForQuit() } })
        quitting = confirmed
        guard confirmed else {
            if !Store.shared.setupCompleted { for (_, state) in windows { state.setup = true } }
            return .terminateCancel
        }
        guard Store.shared.sessions.contains(where: { $0.muse != nil }) else {
            Store.shared.configurationAudit.record("quit_save_completed")
            return .terminateNow
        }
        // Drain owned hosts on the ordinary run loop. NSTerminateLater enters
        // an AppKit modal loop that can starve our main-queue shutdown callbacks.
        Store.shared.closeMuseHostsForQuit { [weak self] in
            self?.quitReady = true
            sender.terminate(nil)
        }
        return .terminateCancel
    }
}

func conversationLayoutSelfTests(_ check: (Bool, String) -> Void) {
    let performanceSession = Session(entry: Entry(name: "Typing QA", command: "false", directory: "/tmp", engine: "claude"))
    performanceSession.messages = (0..<600).map { Message(role: $0 % 2 == 0 ? "user" : "assistant", text: "Message \($0): " + String(repeating: "Retained history with **formatting**. ", count: 8)) }
    let performanceText = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
    let performanceCoordinator = ScrollingConversation.Coordinator(performanceSession)
    performanceText.delegate = performanceCoordinator; performanceCoordinator.render(performanceText)
    let historyInputStart = performanceText.inputStart
    let startTyping = ProcessInfo.processInfo.systemUptime
    for _ in 0..<100 {
        performanceText.insertText("x", replacementRange: NSRange(location: performanceText.textStorage!.length, length: 0))
        performanceCoordinator.render(performanceText)
    }
    let typingMilliseconds = (ProcessInfo.processInfo.systemUptime - startTyping) * 1000
    check(performanceSession.draft == String(repeating: "x", count: 100) && performanceCoordinator.historyBuildCount == 1 && performanceText.inputStart == historyInputStart, "Long-history typing does not serialize, rebuild or replace submitted history (100 edits: " + String(format: "%.1f", typingMilliseconds) + " ms)")
    performanceSession.draft = "External draft hydration"
    performanceCoordinator.render(performanceText)
    check(performanceCoordinator.historyBuildCount == 1 && (performanceText.string as NSString).substring(from: performanceText.inputStart) == performanceSession.draft, "Programmatic draft hydration replaces only the editable tail")
    let previousPrefix = performanceCoordinator.messageStarts[performanceSession.messages.last!.id]!
    performanceSession.messages[performanceSession.messages.count - 1].text += " Streamed suffix."
    performanceCoordinator.render(performanceText)
    check(performanceCoordinator.historyBuildCount == 2 && performanceCoordinator.lastReplacementStart == previousPrefix && performanceText.string.contains("Streamed suffix."), "Streaming replaces the changed message suffix while retaining preceding native layout")
    performanceSession.messages.append(Message(role: "activity", text: "hidden tool status"))
    performanceCoordinator.render(performanceText)
    check(performanceCoordinator.historyBuildCount == 2, "Hidden tool activity does not invalidate the rendered transcript")
    let renamedSession = Session(entry: performanceSession.entry)
    renamedSession.messages = [Message(role: "assistant", text: "```converse\n{\"command\":\"tell\",\"to\":\"" + UUID().uuidString + "\",\"text\":\"Review\"}\n```"), Message(role: "assistant", text: "Previous response")]
    let renamedText = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
    let renamedCoordinator = ScrollingConversation.Coordinator(renamedSession)
    renamedCoordinator.resolveSessionName = { _ in "A formerly long session name" }
    renamedCoordinator.render(renamedText)
    renamedCoordinator.resolveSessionName = { _ in "Muse" }
    renamedSession.messages.append(Message(role: "user", text: "Let's get Linux up and into the group"))
    renamedCoordinator.render(renamedText)
    let cleanText = ConversationTextView(frame: renamedText.frame)
    let cleanCoordinator = ScrollingConversation.Coordinator(renamedSession)
    cleanCoordinator.resolveSessionName = { _ in "Muse" }; cleanCoordinator.render(cleanText)
    check(renamedText.string == cleanText.string && renamedText.string.contains("Let's get Linux up and into the group"), "An earlier resolved name change cannot leak history into or truncate the next prompt")
    let findTest = ConversationTextView(frame: .zero)
    findTest.string = "Saved transcript and unsent draft"
    let originalFindText = findTest.string
    for action in [NSTextFinder.Action.replace, .replaceAll, .replaceAndFind, .replaceAllInSelection, .showReplaceInterface] {
        let item = NSMenuItem(title: "Forbidden replace", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "")
        item.tag = action.rawValue
        check(!findTest.validateUserInterfaceItem(item), "Find rejects replacement action \(action.rawValue)")
        findTest.performTextFinderAction(item)
    }
    findTest.findClient.replaceCharacters(in: NSRange(location: 0, length: 5), with: "Changed")
    check(!findTest.findClient.isEditable && findTest.string == originalFindText, "The finder client cannot replace transcript or draft text")
    var following = TranscriptFollowState()
    following.scroll(nearBottom: false, now: 10); following.outputArrived()
    check(!following.following && following.unreadUpdates == 1 && !following.resumeIfIdle(now: 14.9, selecting: false, scrolling: false), "Manual scroll pauses following and counts unread output without a deadline")
    following.interaction(now: 14)
    check(!following.resumeIfIdle(now: 18.9, selecting: false, scrolling: false), "Non-typing interaction does not resume following")
    check(!following.resumeIfIdle(now: 19, selecting: true, scrolling: false) && !following.resumeIfIdle(now: 19, selecting: false, scrolling: true), "Idle following never resumes while selecting text or actively scrolling")
    check(!following.resumeIfIdle(now: 43.9, selecting: false, scrolling: false) && following.resumeIfIdle(now: 44, selecting: false, scrolling: false) && following.following && following.unreadUpdates == 0, "Scrolling alone resumes at the tail after thirty idle seconds")
    following.scroll(nearBottom: false, now: 20); following.outputArrived(); following.scroll(nearBottom: true, now: 21)
    check(following.following && following.unreadUpdates == 0, "Scrolling back near the bottom resumes following immediately")
    let entry = Entry(name: "Layout fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "claude")
    let submitted = Session(entry: entry)
    submitted.draft = "Send this once"
    let editor = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
    let submission = ScrollingConversation.Coordinator(submitted)
    editor.delegate = submission; submission.render(editor)
    editor.submit = submission.submissionHandler(editor) {
        submitted.messages.append(Message(role: "user", text: submitted.draft)); submitted.draft = ""
    }
    let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    editor.keyDown(with: enter)
    // A delayed native notification must see the consumed tail immediately,
    // without relying on a later SwiftUI updateNSView call.
    submission.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
    check(submitted.draft.isEmpty && editor.inputStart == (editor.string as NSString).length, "Return consumes the native draft synchronously before delayed editor notifications")
    editor.insertText("New typing", replacementRange: editor.selectedRange())
    check(submitted.draft == "New typing" && submitted.messages.count == 1 && submitted.messages[0].text == "Send this once", "Typing immediately after Return starts a fresh draft without restoring or resending the prompt")
    editor.submit = submission.submissionHandler(editor) { /* Failed or awaiting home acknowledgment. */ }
    editor.keyDown(with: enter)
    check(submitted.draft == "New typing" && (editor.string as NSString).substring(from: editor.inputStart) == "New typing", "A send that has not consumed its draft keeps the native text intact")
    for tail in ["", "\n", "\n\n", "\r\n"] {
        let session = Session(entry: entry)
        session.messages = [Message(role: "user", text: "Prompt" + tail), Message(role: "assistant", text: "Reply" + tail)]
        session.draft = "Draft\nsecond line\n"
        let view = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        ScrollingConversation.Coordinator(session).render(view)
        check(view.string == "Prompt\nReply\nDraft\nsecond line\n", "Message boundaries have one newline for both roles, preserving the editable draft (" + tail.debugDescription + ")")
        check(session.messages[0].text == "Prompt" + tail && session.messages[1].text == "Reply" + tail, "Spacing normalization never edits source transcripts")
    }
    let session = Session(entry: entry)
    session.messages = [Message(role: "user", text: "first\n\nsecond"), Message(role: "assistant", text: "alpha\n\nbeta")]
    let scroll = ConversationScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
    scroll.contentView = InputClipView(); scroll.hasVerticalScroller = true
    let view = ConversationTextView(frame: scroll.contentView.bounds)
    view.isVerticallyResizable = true; view.isHorizontallyResizable = false
    view.minSize = NSSize(width: 0, height: 400); view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
    view.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
    view.textContainerInset = NSSize(width: 12, height: 12)
    scroll.documentView = view; scroll.tile()
    let coordinator = ScrollingConversation.Coordinator(session); coordinator.render(view)
    check(view.string.contains("first\n\nsecond") && view.string.contains("alpha\n\nbeta"), "Intentional blank lines inside prompts and replies remain intact")
    // Reproduce the stale frame left by a previously taller viewport/document.
    view.setFrameSize(NSSize(width: view.frame.width, height: 3000)); scroll.tile()
    check(view.frame.height <= scroll.contentView.bounds.height + 1, "Mac tiling shrinks a stale document frame instead of leaving a large blank tail")
    session.messages = [Message(role: "assistant", text: String(repeating: "A long wrapping response line with words. ", count: 600))]
    coordinator.render(view); scroll.tile()
    let startupWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
    startupWindow.isReleasedWhenClosed = false
    scroll.revealInitialTail()
    startupWindow.contentView = scroll
    scroll.layoutSubtreeIfNeeded()
    check(scroll.contentView.bounds.maxY >= view.frame.maxY - 2, "Startup waits for the mounted pane layout before revealing the transcript tail")
    scroll.contentView.scroll(to: .zero)
    scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
    check(scroll.contentView.bounds.maxY >= view.frame.maxY - 2, "Later layout keeps automatic following at the actual document bottom")
    scroll.contentView.scroll(to: .zero); scroll.recordScroll()
    scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
    check(scroll.contentView.bounds.minY < 2, "Later layout preserves a deliberate user scroll")
    startupWindow.contentView = nil
    scroll.setFrameSize(NSSize(width: 700, height: 400)); scroll.tile()
    let longHeight = view.frame.height
    check(longHeight > 1000, "Native layout fixture produces a scrollable transcript")
    scroll.jumpToLatest()
    // Layout may change under us as output/images grow: that is not a user scroll.
    view.setFrameSize(NSSize(width: view.frame.width, height: view.frame.height + 500))
    check(scroll.prepareForRender(first: false), "Output growth alone never pauses automatic following")
    view.delegate = coordinator
    view.setSelectedRange(NSRange(location: 2, length: 0))
    coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
    check(!view.explicitCursor, "Programmatic caret changes cannot impersonate a user planting a transcript cursor")
    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
    scroll.recordScroll()
    session.messages.append(Message(role: "assistant", text: "A later streamed answer"))
    coordinator.render(view)
    check(abs(scroll.contentView.bounds.minY - 100) < 1, "New output preserves the viewport while reading older messages")
    view.setSelectedRange(NSRange(location: 5, length: 12))
    session.messages.append(Message(role: "assistant", text: "Output while selecting history"))
    coordinator.render(view)
    check(view.selectedRange() == NSRange(location: 5, length: 12) && !scroll.followState.following && scroll.followState.unreadUpdates > 0, "Incoming output preserves a history selection and exposes unread updates")
    let rightArrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)!
    view.keyDown(with: rightArrow)
    check(view.selectedRange().location < view.inputStart && !scroll.followState.following, "History navigation keys move within history without being mistaken for typing and jumping to the draft")
    view.explicitCursor = true; view.setSelectedRange(NSRange(location: 10, length: 0))
    session.messages.append(Message(role: "assistant", text: "Keep an explicitly positioned cursor"))
    coordinator.render(view)
    check(view.selectedRange() == NSRange(location: 10, length: 0) && scroll.selecting && !scroll.followState.following, "An explicit Mac cursor holds its position even without a selection or draft")
    check(scroll.showsLatest, "Jump to latest appears when a paused transcript has output below the viewport")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, view.bounds.maxY - scroll.contentView.bounds.height)))
    scroll.reflectScrolledClipView(scroll.contentView)
    check(!scroll.showsLatest && !scroll.followState.following && view.explicitCursor, "Jump to latest hides at the bottom without clearing an explicit cursor or resuming following")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
    scroll.reflectScrolledClipView(scroll.contentView)
    check(scroll.showsLatest, "Jump to latest returns when the paused viewport moves away from the bottom")
    let pasteFile = FileManager.default.temporaryDirectory.appendingPathComponent("converse-scroll-image-" + UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: pasteFile) }
    let pasted = NSImage(size: NSSize(width: 300, height: 700))
    pasted.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 300, height: 700).fill(); pasted.unlockFocus()
    if let tiff = pasted.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: pasteFile) }
    session.attachments = [pasteFile.path]
    coordinator.render(view)
    let imageBottom = view.layoutManager!.boundingRect(forGlyphRange: view.layoutManager!.glyphRange(forCharacterRange: NSRange(location: view.draftImages[0].location, length: 1), actualCharacterRange: nil), in: view.textContainer!).maxY + view.textContainerOrigin.y
    check(imageBottom <= scroll.contentView.bounds.maxY + 1 && imageBottom > scroll.contentView.bounds.minY, "Pasting a tall image reveals its bottom even while the transcript was scrolled up")
    session.attachments = []
    coordinator.render(view)
    scroll.jumpToLatest()
    check(scroll.followState.following && scroll.followState.unreadUpdates == 0, "Native Jump to latest explicitly resumes following and clears unread output")
    session.messages = [Message(role: "assistant", text: "Short reply")]; session.draft = "Typing here"
    coordinator.render(view); scroll.tile()
    check(view.frame.height <= scroll.contentView.bounds.height + 1 && scroll.contentView.bounds.minY < 1, "Shortened transcripts shrink and clamp the scroll position before showing the draft")
    scroll.setFrameSize(NSSize(width: 700, height: 900)); scroll.tile()
    scroll.setFrameSize(NSSize(width: 700, height: 250)); scroll.tile()
    check(view.frame.height <= scroll.contentView.bounds.height + 1, "Reducing the window height cannot retain the previous tall document frame")
    // Keep the real scroll container: the regression was in the follow-output
    // callback, so a standalone NSTextView does not exercise it.
    session.draft = "original prompt"; coordinator.render(view)
    view.setSelectedRange(NSRange(location: view.inputStart, length: 0))
    view.insertText("A", replacementRange: view.selectedRange())
    check(session.draft == "Aoriginal prompt" && view.selectedRange().location == view.inputStart + 1, "Typing at the start of a prompt preserves the caret after the inserted character")
    view.insertText("B", replacementRange: view.selectedRange())
    check(session.draft == "ABoriginal prompt", "Consecutive characters stay at the chosen prompt position instead of jumping to the end")
    view.setSelectedRange(NSRange(location: view.inputStart + 2, length: 9))
    view.insertText("edited ", replacementRange: view.selectedRange())
    check(session.draft == "ABedited prompt" && view.selectedRange().location == view.inputStart + 9, "Replacing a prompt selection preserves the replacement insertion point")
    session.messages.append(Message(role: "assistant", text: "Streaming while editing")); coordinator.render(view)
    check(view.selectedRange().location == view.inputStart + 9, "Streamed output preserves the draft-relative insertion point")
    scroll.resumeFollowing()
    check(view.selectedRange().location == view.inputStart + 9, "Automatic idle following does not move the draft caret")
    view.insertText("middle ", replacementRange: view.selectedRange())
    check(session.draft == "ABedited middle prompt", "Typing in the middle remains correct after output and automatic following")
    scroll.jumpToLatest()
    check(view.selectedRange().location == (view.string as NSString).length, "Explicit Jump to latest still moves the caret to the prompt end")
}

func selfTest() {
    guard ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil, ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"] != nil else { fputs("Use test.sh to run isolated tests.\n", stderr); exit(2) }
    let store = Store.shared
    func check(_ value: Bool, _ label: String) { if !value { fputs("FAIL: \(label)\n", stderr); exit(1) }; print("PASS: \(label)") }
    MainActor.assumeIsolated { appSupportSelfTests(check) }
    providerSelfTests(check)
    MainActor.assumeIsolated { textSubstitutionSelfTests(check) }
    conversationLayoutSelfTests(check)
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
    let blankClick = NSEvent.mouseEvent(with: .leftMouseDown, location: native.convert(NSPoint(x: 20, y: 450), to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
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
    let focusWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 950), styleMask: [.titled], backing: .buffered, defer: false)
    focusWindow.isReleasedWhenClosed = false
    let focusRoot = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 950)); focusWindow.contentView = focusRoot
    focusRoot.addSubview(tall)
    let parkingText = ParkingOutlineText(frame: NSRect(x: 720, y: 0, width: 250, height: 950)); focusRoot.addSubview(parkingText)
    let undoAnchor = ParkingLotUndoResponder(); focusRoot.addSubview(undoAnchor)
    let undoFocus = ParkingLotUndoFocus(); undoFocus.view = undoAnchor
    focusWindow.makeFirstResponder(parkingText)
    native.setSelectedRange(NSRange(location: 0, length: 0))
    let inputPoint = native.convert(NSPoint(x: 80, y: 850), to: nil)
    check(tall.focusBlankInput(at: inputPoint) && focusWindow.firstResponder === native && native.selectedRange().location == (native.string as NSString).length,
          "Blank input clicks take focus directly from the Parking Lot and place the draft caret")
    undoFocus.activate(ifUnchangedFrom: parkingText)
    check(focusWindow.firstResponder === native, "A deferred Parking Lot Undo handoff cannot steal a later conversation click")
    focusWindow.makeFirstResponder(undoAnchor)
    check(tall.focusBlankInput(at: inputPoint) && focusWindow.firstResponder === native, "Blank input clicks also leave the Parking Lot reorder Undo responder")
    check(!tall.focusBlankInput(at: parkingText.convert(NSPoint(x: 80, y: 300), to: nil)), "Clicks in another pane do not focus this conversation")
    native.isEditable = false; focusWindow.makeFirstResponder(parkingText)
    check(!tall.focusBlankInput(at: inputPoint) && focusWindow.firstResponder === parkingText, "Read-only conversation views do not claim input focus")
    native.isEditable = true; focusWindow.close()
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
    let remoteComposer = RemoteComposer()
    remoteComposer.draft = "remote draft"
    let remoteHistory = DeviceTranscriptPayload(globalID: "home/" + UUID().uuidString, homeSeq: 1, messages: [DeviceWireMessage(id: UUID(), role: "user", text: "previous prompt"), DeviceWireMessage(id: UUID(), role: "assistant", text: "**remote response**")], draft: "remote draft", draftVersion: 1, busy: true, status: "Working")
    let localCount = store.sessions.count
    remoteComposer.updateEditor(transcript: remoteHistory, cache: [:])
    let remoteText = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    let remoteCoordinator = ScrollingConversation.Coordinator(remoteComposer.editor)
    var transmittedDraft = ""; var remoteSubmits = 0
    remoteCoordinator.draftChanged = { transmittedDraft = $0 }
    remoteText.delegate = remoteCoordinator; remoteText.submit = { remoteSubmits += 1 }; remoteCoordinator.render(remoteText)
    remoteText.setSelectedRange(NSRange(location: (remoteText.string as NSString).length, length: 0))
    remoteText.insertText(" edited", replacementRange: remoteText.selectedRange())
    check(transmittedDraft == "remote draft edited" && remoteText.typingAttributes[.foregroundColor] as? NSColor == NSColor.systemBlue, "Remote native editor types blue and routes draft edits through transport callback")
    remoteText.keyDown(with: enter)
    check(remoteSubmits == 1 && remoteComposer.editor.busy, "Remote Return invokes submission while home is busy so home can queue it")
    remoteText.keyDown(with: commandEnter)
    check(remoteSubmits == 1 && transmittedDraft.hasSuffix("\n"), "Remote Command Return edits a multiline draft without sending")
    check(!remoteCoordinator.textView(remoteText, shouldChangeTextIn: NSRange(location: 0, length: 1), replacementString: "x") && !remoteText.userBlocks.isEmpty, "Remote native transcript protects history and tracks prompt gutter blocks")
    remoteText.isEditable = false; let offlineText = remoteText.string
    remoteText.keyDown(with: enter); remoteText.keyDown(with: commandEnter)
    check(remoteSubmits == 1 && remoteText.string == offlineText && store.sessions.count == localCount, "Offline remote editor cannot send or insert newline and never registers a local CLI session")
    let styledSession = Session(entry: entry)
    styledSession.messages = [Message(role: "user", text: "line one\nline two"), Message(role: "assistant", text: "response")]
    let styled = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    let styledCoordinator = ScrollingConversation.Coordinator(styledSession)
    styledCoordinator.render(styled)
    let submittedFont = styled.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    check(submittedFont.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true, "Submitted input renders in italics")
    check(styled.userBlocks.count == 1 && styled.userBlocks[0].length == 17, "Multiline input is enclosed as one separator block")
    check(styled.messageLabels.map(\.number) == [1, 2] && styled.messageLabels.map(\.location) == [0, 18], "Gutter numbers multiline prompts and responses once per message")
    check(styled.messageLabels[0].color == .systemBlue && styled.messageLabels[1].color == .systemGray, "Prompt numbers are blue and response numbers grey")
    let labelSnapshot = styled.messageLabels
    styledSession.draft = "draft\nwith\nthree lines"; styledCoordinator.render(styled)
    check(styled.messageLabels == labelSnapshot, "Editable draft paragraphs never consume message numbers")
    styledSession.messages += [Message(role: "activity", text: "hidden tool output"), Message(role: "assistant", text: ""), Message(role: "notice", text: "Switchboard: queued"), Message(role: "assistant", text: "paragraph one\n\nparagraph two\n```swift\nlet n = 1\n```" )]
    styledCoordinator.render(styled)
    check(styled.messageLabels.map(\.number) == [1, 2, 3, 4], "Hidden activity and empty placeholders consume no numbers; visible notices and code blocks each consume one")
    check(styledSession.transcriptMessageNumbers().count == 4 && styledSession.transcriptMessageNumbers()[styledSession.messages.last!.id] == 4, "Home numbering matches visible message sequence")
    styledSession.messages[3].text = "new streamed response"; styledCoordinator.render(styled)
    check(styled.messageLabels.map(\.number) == [1, 2, 3, 4, 5] && styledSession.transcriptMessageNumbers()[styledSession.messages.last!.id] == 5, "An empty response gaining text refreshes numbering and the home cache")
    let pagedComposer = RemoteComposer()
    let pagedA = DeviceWireMessage(id: UUID(), role: "user", text: "page prompt\nsecond line", messageNumber: 41)
    let pagedB = DeviceWireMessage(id: UUID(), role: "assistant", text: "page response", messageNumber: 42)
    var paged = DeviceTranscriptPayload(globalID: "home/" + UUID().uuidString, homeSeq: 1, messages: [pagedA, pagedB], offset: 90, total: 92, draft: "", draftVersion: 0, busy: false, status: "Ready")
    let pagedText = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    let pagedCoordinator = ScrollingConversation.Coordinator(pagedComposer.editor)
    pagedComposer.updateEditor(transcript: paged, cache: [:]); pagedCoordinator.render(pagedText)
    check(pagedText.messageLabels.map(\.number) == [41, 42], "Remote gutter uses home ordinals rather than raw paging offsets")
    paged.messages.insert(DeviceWireMessage(id: UUID(), role: "assistant", text: "earlier", messageNumber: 40), at: 0); paged.offset = 89
    pagedComposer.updateEditor(transcript: paged, cache: [:]); pagedCoordinator.render(pagedText)
    check(pagedText.messageLabels.map(\.number) == [40, 41, 42], "Loading earlier messages preserves the numbers already on screen")
    paged.messages.removeFirst(); paged.messages[0].messageNumber = 51; paged.messages[1].messageNumber = 52
    pagedComposer.updateEditor(transcript: paged, cache: [:]); pagedCoordinator.render(pagedText)
    check(pagedText.messageLabels.map(\.number) == [51, 52], "Home numbering-only updates refresh cached native history")
    let legacyWire = try! JSONDecoder().decode(DeviceWireMessage.self, from: Data(("{\"id\":\"" + UUID().uuidString + "\",\"role\":\"assistant\",\"text\":\"old home\",\"imageHashes\":[]}").utf8))
    check(legacyWire.messageNumber == nil && (try? JSONDecoder().decode(DeviceWireMessage.self, from: JSONEncoder().encode(pagedB)))?.messageNumber == 42, "Optional message ordinals round-trip while old wire messages still decode")
    let retrySession = Session(entry: Entry(name: "Codex", command: "codex", directory: NSTemporaryDirectory(), engine: "codex"))
    let retryResponse = Message(role: "assistant", text: "Partial")
    retrySession.messages = [retryResponse]
    for attempt in 1...5 {
        store.consume("{\"type\":\"error\",\"message\":\"Reconnecting... \(attempt)/5 (stream disconnected)\"}", session: retrySession, responseID: retryResponse.id)
    }
    check(retrySession.messages.count == 1 && !retrySession.turnFailed && retrySession.status.hasPrefix("Waiting for OpenAI"), "Reconnect attempts replace one temporary status without polluting history or failing the turn")
    store.consume(#"{"type":"item.completed","item":{"type":"agent_message","text":"Recovered"}}"#, session: retrySession, responseID: retryResponse.id)
    check(retrySession.retryDetail == nil && retrySession.status == "Working…" && retrySession.messages[0].text.contains("Recovered"), "Next output clears retry state and preserves the partial reply")
    store.consume("Reconnecting... 1/5 (stream disconnected)", session: retrySession, responseID: retryResponse.id)
    check(retrySession.messages.count == 1, "Raw stderr retries do not become transcript lines")
    store.consume(#"{"type":"error","willRetry":false,"message":"Connection lost permanently"}"#, session: retrySession, responseID: retryResponse.id)
    check(retrySession.retryDetail == nil && retrySession.turnFailed && retrySession.messages.last?.text == "Connection lost permanently", "Terminal provider failure stays visible")
    check(ProviderRetry.detail(#"{"type":"assistant","message":"Reconnecting... 1/5"}"#) == nil && ProviderRetry.detail("A tool printed Reconnecting... 1/5") == nil, "Retry matcher preserves ordinary content")
    check(ProviderRetry.detail(#"{"type":"system","subtype":"api_retry"}"#) != nil && ProviderRetry.status("claude").contains("Claude"), "Claude retry events get a provider-specific waiting status")
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
    exact.injectionNotice = "Injected prompt started."
    store.activity("hidden tool output", session: exact)
    check(exact.lastOutputAt == 100, "Hidden tool output does not reset response delay")
    check(exact.injectionNotice == "Injected prompt started.", "Injection confirmation waits for an assistant response, not tool activity")
    store.markOutput(exact, index: 0, offset: 0, now: 110)
    check(exact.injectionNotice.isEmpty, "First assistant response clears the injection confirmation")
    exact.injectionNotice = "Injection did not start. Check the queued input and session notice before retrying."
    store.assistantResponded(exact)
    check(!exact.injectionNotice.isEmpty, "Assistant response does not dismiss an injection failure notice")
    check(exact.messages[0].delays?.first?.seconds == 10 && Store.delayLabel(10) == "[10 sec]", "Delay threshold includes exactly ten seconds")
    let timedView = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    let timedCoordinator = ScrollingConversation.Coordinator(exact); timedCoordinator.render(timedView)
    check(timedView.string == "[10 sec] Answer\n" && timedView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.gray, "Delay prefix is grey and tool output is hidden")
    let glued = Session(entry: Entry(name: "Claude", command: "claude", directory: "/tmp", engine: "claude"))
    let gluedID = UUID(); glued.messages = [Message(id: gluedID, role: "assistant", text: "tracked.")]
    glued.lastOutputAt = ProcessInfo.processInfo.systemUptime - 35
    store.consume(#"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"While"}}}"#, session: glued, responseID: gluedID)
    let gluedView = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    ScrollingConversation.Coordinator(glued).render(gluedView)
    check(gluedView.string.contains("tracked.[35 sec] While") && !gluedView.string.contains("tracked.W["), "Stored mid-line delay renders before the resumed character, without a phantom prefix newline")
    store.consume(#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"Read"}}}"#, session: glued, responseID: gluedID)
    store.consume(#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#, session: glued, responseID: gluedID)
    glued.lastOutputAt = ProcessInfo.processInfo.systemUptime - 20
    store.consume(#"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Next block"}}}"#, session: glued, responseID: gluedID)
    store.consume(#"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":" continues"}}}"#, session: glued, responseID: gluedID)
    ScrollingConversation.Coordinator(glued).render(gluedView)
    check(glued.messages[0].text == "tracked.While\n\nNext block continues" && gluedView.string.contains("\n\n[20 sec] Next block continues"), "Claude text blocks get one separator in storage and delay markers stay at the start of resumed blocks")
    store.consume(#"{"type":"result","result":"tracked.WhileNext block continues"}"#, session: glued, responseID: gluedID)
    check(glued.messages[0].text == "tracked.While\n\nNext block continues" && glued.messages[0].delays?.count == 2, "Claude final snapshots cannot glue separated text blocks back together or discard their delay marks")
    let pong = Session(entry: Entry(name: "Claude", command: "claude", directory: "/tmp", engine: "claude"))
    let pongID = UUID(); pong.messages = [Message(id: pongID, role: "assistant", text: "")]
    func pongLine(_ line: String) { store.consume(line, session: pong, responseID: pongID) }
    pongLine(#"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"PONG"}}}"#)
    pongLine(#"{"type":"assistant","message":{"content":[{"type":"text","text":"PONG"},{"type":"tool_use","name":"Read"}]}}"#)
    pongLine(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Both files read now"}]}}"#)
    check(pong.messages[0].text == "PONG\nBoth files read now", "Claude retains later unstreamed blocks without duplicating earlier streamed text")
    pongLine(#"{"type":"result","result":"Both files read now"}"#)
    check(pong.messages[0].text == "PONG\nBoth files read now", "Last-block-only final snapshot preserves the complete Claude reply")
    let priorDelays = glued.messages[0].delays
    store.consume(#"{"type":"assistant","message":{"content":[{"type":"text","text":"tracked.WhileNext block continues"}]}}"#, session: glued, responseID: gluedID)
    store.consume(#"{"type":"result","result":"Next block continues"}"#, session: glued, responseID: gluedID)
    check(glued.messages[0].text == "tracked.While\n\nNext block continues" && glued.messages[0].delays?.count == priorDelays?.count, "Claude deduplicates separator-stripped assistant snapshots and retains delays for subset results")
    pongLine(#"{"type":"result","result":"A genuine correction"}"#)
    check(pong.messages[0].text == "A genuine correction", "A genuinely different Claude result still replaces accumulated output")
    pongLine(#"{"type":"result","is_error":true,"result":"correction"}"#)
    check(pong.turnFailed && pong.messages[0].text == "correction", "Claude error results replace output even when they are a subset")
    let background = Session(entry: Entry(name: "Claude", command: "claude", directory: "/tmp", engine: "claude"))
    let backgroundID = UUID(); background.messages = [Message(id: backgroundID, role: "assistant", text: "")]; background.busy = true; background.status = "Working…"
    store.consume(#"{"type":"system","subtype":"task_started","task_id":"t1","description":"Audit the gutter","is_backgrounded":true}"#, session: background, responseID: backgroundID)
    store.consume(#"{"type":"result","result":"Started a background audit."}"#, session: background, responseID: backgroundID)
    check(background.busy && background.status == "Working… · task: Audit the gutter" && background.messages[0].text == "Started a background audit.", "Claude background work stays visible as busy after the first result")
    store.consume(#"{"type":"system","subtype":"task_started","task_id":"t2","description":"Run tests"}"#, session: background, responseID: backgroundID)
    check(background.status == "Working… · 2 tasks: Audit the gutter +1", "Several outstanding Claude tasks are counted")
    store.consume(#"{"type":"system","subtype":"task_notification","task_id":"t1","status":"completed"}"#, session: background, responseID: backgroundID)
    store.consume(#"{"type":"system","subtype":"task_notification","task_id":"t2","status":"failed"}"#, session: background, responseID: backgroundID)
    check(background.status == "Working…" && background.claudeBackgroundTasks.isEmpty, "Finished Claude tasks clear the background status")
    let blocks = Session(entry: Entry(name: "Claude", command: "claude", directory: "/tmp", engine: "claude"))
    let blocksID = UUID(); blocks.messages = [Message(id: blocksID, role: "assistant", text: "")]
    store.consume(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Unique block"},{"type":"text","text":"Unique block"}]}}"#, session: blocks, responseID: blocksID)
    check(blocks.messages[0].text == "Unique block", "Claude deduplication includes text already accepted in the same assistant event")
    check(MarkdownText.renderedOffset(in: "plain\nNext", utf16Offset: 6) == 6 && MarkdownText.renderedOffset(in: "plainNext", utf16Offset: 5) == 5 && MarkdownText.renderedOffset(in: "é😀Next", utf16Offset: 3) == 3, "Rendered delay offsets preserve existing newlines and UTF-16 character positions")
    check(!TranscriptStyle.isTraffic("tell me about the rain in Spain") && !TranscriptStyle.isTraffic("tell Muse hello") && !TranscriptStyle.isTraffic(#"{"command":"tell","text":"hi"}"#) && TranscriptStyle.isTraffic("[Converse message from Muse · session test]\nhello"), "Only structured switchboard traffic is orange; ordinary tell prose and JSON stay normal")
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
    var currentPermission = probeSession
    currentPermission["permissionState"] = ["profileId": ":ask-me", "reviewerAuthority": "human", "reviewerAttached": false]
    let currentProbe = MuseStatusProbe.resolve(config: probeConfig, session: currentPermission, records: probeRecords, quota: nil)
    check(currentProbe.status.access == ":ask-me / onRequest", "Current Muse permission snapshot overrides an older Auto-review transcript record")
    for engine in ["codex", "claude"] {
        let active = Session(entry: Entry(name: engine, command: engine, directory: NSTemporaryDirectory(), engine: engine)); active.busy = true
        store.changeSetting(active, .effort("high"))
        check(active.busy && active.choices.effort == "high" && active.settingNotice.contains("next turn"), engine + " accepts settings during an active turn without restarting the process")
    }
    let quotaText = MuseStatusProbe.quotaSummary(["tier": "test", "window": ["usedPercent": 25, "windowDurationMins": 300], "weekly": ["usedPercent": 12], "observedAtMs": 0])
    check(quotaText.contains("25%") && !quotaText.contains("{"), "Quota is readable text, not JSON")
    let ttyQuota = MuseQuota.parse("\u{001B}[17;1H│ Weekly 2% used · Resets Nov 1 at 4:00 PM │\n│ Current 7% used · Resets at 10:42 PM │")
    check(ttyQuota?.contains("Weekly 2% used · resets Nov 1 at 4:00 PM") == true && ttyQuota?.contains("Current 7%") == true && ttyQuota?.contains("\u{001B}") == false, "CLI quota parsing preserves weekly percent and reset time without terminal escapes")
    check(MuseQuota.parse("Weekly: unavailable") == nil, "Unavailable quota is never presented as zero")
    // Captured from `muse usage --json` (Muse Code 1.4.14).
    let usageSample = Data(#"{"schemaVersion":1,"allowance":{"tier":"Muse Code Max Usage","window":{"usedPercent":2,"resetsAtMs":1793685586000},"weekly":{"usedPercent":8,"resetsAtMs":1794182400000},"asOfMs":1793670990782,"source":"mint"},"reason":null,"hint":null}"#.utf8)
    let usageReading = try? MuseQuota.allowance(usageSample)
    let weeklyLimit = usageReading?.usage?.limits.first { $0.name == "Weekly" }
    check(weeklyLimit?.usedPercent == 8 && weeklyLimit?.resetsAt == Date(timeIntervalSince1970: 1794182400) && usageReading?.usage?.limits.first?.name == "Window" && abs((usageReading?.usage?.observedAt?.timeIntervalSince1970 ?? 0) - 1793670990.782) < 0.01, "Muse usage report supplies weekly and window limits with reset and observation times")
    check(usageReading?.text.contains("weekly 8% used") == true && AccountUsage.museLimits(usageReading?.text ?? "").map(\.usedPercent) == [2, 8], "Muse usage report keeps a readable quota summary")
    var unavailableThrows = false
    do { _ = try MuseQuota.allowance(Data(#"{"schemaVersion":1,"allowance":null,"reason":"not signed in","hint":"Run muse login"}"#.utf8)) } catch { unavailableThrows = error.localizedDescription.contains("not signed in") }
    var fellBack = false
    do { fellBack = try MuseQuota.allowance(Data("Weekly: 8% used".utf8)) == nil } catch {}
    check(unavailableThrows && fellBack, "Missing Muse allowance reports Muse's reason; non-report output falls back to the terminal reader")
    check(MuseQuota.listsUsage("Commands:\n  serve  Serve\n  usage            Show your subscription allowance\n") && !MuseQuota.listsUsage("Commands:\n  serve  Serve\n  exec  Run one prompt\n"), "Converse runs muse usage only when the installed CLI lists it")
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
    for ending in ["\r\n", "\r"] {
        let raw = ["## Remote heading", "**Bold reply**", "| A | B |", "| --- | --- |", "| one | two |"].joined(separator: ending)
        let remote = RemoteComposer()
        remote.updateEditor(transcript: DeviceTranscriptPayload(globalID: "fixture", homeSeq: 1, messages: [DeviceWireMessage(id: UUID(), role: "assistant", text: raw)], draft: "", draftVersion: 1, busy: false, status: "Ready"), cache: [:])
        let rendered = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        ScrollingConversation.Coordinator(remote.editor).render(rendered)
        let cell = (rendered.string as NSString).range(of: "one")
        let cellStyle = cell.location == NSNotFound ? nil : rendered.textStorage?.attribute(.paragraphStyle, at: cell.location, effectiveRange: nil) as? NSParagraphStyle
        check(!rendered.string.contains("##") && !rendered.string.contains("**") && !rendered.string.contains("| ---") && cellStyle?.textBlocks.first is NSTextTableBlock && remote.editor.messages[0].text == raw, "Remote assistant Markdown with " + ending.debugDescription + " line endings renders headings/emphasis/tables without editing its source")
    }
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
    check(tableSession.draft == "next input" && inputStyle?.textBlocks.isEmpty != false && inputStyle?.paragraphSpacing == 0, "Input after a rendered table stays outside cells and does not inherit message spacing")
    let fileBoard = NSPasteboard.withUniqueName()
    fileBoard.writeObjects([URL(fileURLWithPath: "/tmp/a folder/photo.png") as NSURL,
                            URL(fileURLWithPath: "/tmp/report.txt") as NSURL])
    let originalHistory = tableSession.messages
    tableView.setSelectedRange(NSRange(location: 0, length: 1))
    check(tableView.insertDroppedFiles(from: fileBoard) &&
          tableSession.draft == "next input'/tmp/a folder/photo.png' /tmp/report.txt " &&
          tableSession.messages == originalHistory && tableSession.attachments.isEmpty,
          "File drops append absolute paths to draft, preserve history and do not attach images")
    tableView.setSelectedRange(NSRange(location: tableView.inputStart, length: 4))
    check(tableView.insertDroppedFiles(from: fileBoard) && tableSession.draft.hasPrefix("'/tmp/a folder/photo.png' /tmp/report.txt  input"),
          "File drops replace only the selected draft text")
    let beforeReadOnlyDrop = tableSession.draft
    tableView.isEditable = false
    check(!tableView.insertDroppedFiles(from: fileBoard) && tableSession.draft == beforeReadOnlyDrop,
          "Read-only remote editor rejects file drops")
    tableView.isEditable = true
    tableView.droppedFileSourceDevice = "Richard-Air"
    tableView.focusInput()
    check(tableView.insertDroppedFiles(from: fileBoard) && tableSession.draft.hasSuffix("file from Richard-Air: '/tmp/a folder/photo.png'\nfile from Richard-Air: /tmp/report.txt "),
          "Remote file drops identify the source device for every file")
    check(ConversationTextView.quoteDroppedPath("/tmp/it's $(touch nope).txt") == "'/tmp/it'\"'\"'s $(touch nope).txt'",
          "Dropped Mac paths quote apostrophes and shell metacharacters literally")
    fileBoard.releaseGlobally()
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
    // Use pixels, not lockFocus points (which become 32 pixels on Retina displays).
    let imageBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<16 { for x in 0..<16 { imageBitmap.setColor(.red, atX: x, y: y) } }
    let image = NSImage(size: NSSize(width: 16, height: 16)); image.addRepresentation(imageBitmap)
    store.attach(s, image: image)
    check(s.attachments.count == 1 && FileManager.default.fileExists(atPath: s.attachments[0]), "Pasted image saved as PNG")
    let imageDraft = store.create(entry)
    let largeImage = NSImage(size: NSSize(width: 1600, height: 1200))
    largeImage.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 1600, height: 1200).fill(); largeImage.unlockFocus()
    store.attach(imageDraft, image: image); store.attach(imageDraft, image: largeImage)
    let imagePaths = imageDraft.attachments
    imageDraft.messages = [Message(role: "assistant", text: "Historical image", images: [imagePaths[0]])]
    imageDraft.draft = "Keep this text"
    let imageEditor = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    let imageCoordinator = ScrollingConversation.Coordinator(imageDraft)
    imageEditor.imageRemove = { path in store.removeDraftImage(imageDraft, path: path); imageCoordinator.render(imageEditor) }
    imageCoordinator.render(imageEditor)
    var renderedImageLocations: [Int] = []
    imageEditor.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: imageEditor.textStorage!.length)) { value, range, _ in
        guard let attachment = value as? NSTextAttachment else { return }
        renderedImageLocations.append(range.location)
        check(attachment.fileWrapper?.preferredFilename?.hasSuffix(".png") == true && attachment.fileWrapper?.regularFileContents.flatMap { NSImage(data: $0) } != nil, "Transcript image sharing carries a decodable PNG file with a filename")
        check((attachment.attachmentCell?.cellSize().width ?? 1000) <= 480 && (attachment.attachmentCell?.cellSize().height ?? 1000) <= 260, "Named image attachments keep bounded transcript previews")
        check(imageEditor.imageToolsItem(at: range.location, hasMetaKey: false)?.representedObject is NSImage, "Image tools target the clicked historical or draft attachment")
    }
    check(renderedImageLocations.count == 3 && imageEditor.imageToolsItem(at: imageEditor.inputStart) == nil, "Image menu is present for history and both draft images, never plain draft text")
    if let location = renderedImageLocations.first {
        let menu = NSMenu()
        let unavailable = imageEditor.imageToolsItem(at: location, hasMetaKey: false)!
        menu.addItem(unavailable); menu.update()
        check(!unavailable.isEnabled && unavailable.toolTip == "Meta API key required" && unavailable.representedObject is NSImage, "Missing Meta key keeps image tools disabled after menu validation, with a tooltip and image sharing intact")
        let available = imageEditor.imageToolsItem(at: location, hasMetaKey: true)!
        menu.addItem(available); menu.update()
        check(available.isEnabled && available.action != nil && available.toolTip == nil, "Image tools are available when a Meta key is configured")
    }
    let preparedCount = imageCoordinator.imagePreparationCount
    imageDraft.messages.append(Message(role: "assistant", text: "Streaming update"))
    imageCoordinator.render(imageEditor)
    imageDraft.messages.removeLast(); imageCoordinator.render(imageEditor)
    check(imageCoordinator.imagePreparationCount == preparedCount, "Streaming text reuses historical and draft image preparations")
    check(TranscriptPalette.draft("tell me about the rain in Spain") == .systemBlue && TranscriptPalette.draft("tell Muse hello") == .systemBlue, "All unsent prompts remain blue, regardless of tell wording")
    let normalizedImage = try! MacImageSource.normalized(image)
    check(NSBitmapImageRep(data: normalizedImage)?.pixelsWide == 16, "Image tools normalize a captured image without changing its dimensions unnecessarily")
    check(imageEditor.draftImageButtons.count == 2 && imageEditor.draftImages.allSatisfy { $0.location < imageEditor.inputStart }, "Only draft image previews receive native remove buttons; historical images remain protected")
    check(imageEditor.messageLabels.map(\.number) == [1] && imageEditor.messageLabels[0].location < imageEditor.inputStart, "Historical images share their message number and draft attachment previews remain unnumbered")
    imageEditor.setSelectedRange(NSRange(location: imageEditor.inputStart + 3, length: 0))
    imageEditor.draftImageButtons[0].performClick(nil)
    check(imageDraft.attachments == [imagePaths[1]] && imageDraft.draft == "Keep this text" && imageDraft.messages[0].images == [imagePaths[0]] && FileManager.default.fileExists(atPath: imagePaths[0]) && imageEditor.selectedRange().location == imageEditor.inputStart + 3, "Clicking a draft image X removes exactly that attachment and preserves text, caret, historical images and their files")
    imageEditor.isEditable = false; imageEditor.refreshDecorations()
    check(imageEditor.draftImageButtons.allSatisfy(\.isHidden), "Image removal controls are hidden when the pane cannot edit")
    let restoredImages = Session(try! JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(imageDraft.saved)))
    check(restoredImages.attachments == [imagePaths[1]] && restoredImages.draft == "Keep this text", "Per-image draft removal survives session persistence")
    let remoteImages = RemoteComposer(); remoteImages.draft = "Remote draft"; remoteImages.blobHashes = ["one", "two"]; remoteImages.sentHashes = ["one", "two"]
    check(remoteImages.removeImage(path: imagePaths[0], cache: ["one": URL(fileURLWithPath: imagePaths[0]), "two": URL(fileURLWithPath: imagePaths[1])]) && remoteImages.blobHashes == ["two"] && remoteImages.sentHashes == ["one", "two"] && remoteImages.draft == "Remote draft", "Remote removal resolves the clicked preview to its hash without altering text or an already submitted payload")
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
    check(fixture.status == "Waiting for your approval" && fixture.requests.first?.kind == "approval" && fixture.needsApproval, "Approval request reaches conversation instead of hiding behind Working")
    func settleSetting() {
        let deadline = Date().addingTimeInterval(5)
        while fixture.changingSetting && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    store.changeSetting(fixture, .access(":ask-me")); settleSetting()
    check(fixture.busy && fixture.choices.access == ":ask-me" && fixture.requests.first?.kind == "approval" && fixture.settingNotice.contains("applied"), "Muse permission changes use the active connection without answering a pending approval or stopping the turn")
    store.changeSetting(fixture, .effort("max")); settleSetting()
    check(fixture.busy && fixture.choices.effort == "max" && fixture.settingNotice.contains("next turn"), "Muse accepts effort changes while running and reports their next-turn timing")
    store.changeSetting(fixture, .model(MuseModelChoice(id: "fixture-model", label: "Fixture", provider: "echo", profile: nil, efforts: ["max"]))); settleSetting()
    check(fixture.busy && fixture.choices.model == "fixture-model" && fixture.settingNotice.contains("next model call"), "Muse model changes while running are acknowledged for the next model-call boundary")
    store.changeSetting(fixture, .access(":unavailable")); settleSetting()
    check(fixture.choices.access == ":ask-me" && fixture.settingNotice.contains("not confirmed"), "A rejected live permission change is visible and never presented as applied")
    fixture.title = "Renamed during a running turn"
    check(fixture.busy && fixture.title == "Renamed during a running turn", "Renaming a running session never waits for the next turn")
    if let request = fixture.requests.first { store.answerMuse(fixture, request: request, choice: "allow-once") }
    let questionDeadline = Date().addingTimeInterval(10)
    while fixture.requests.first?.kind != "question" && fixture.busy && Date() < questionDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(fixture.status == "Waiting for your answer" && fixture.requests.first?.kind == "question" && !fixture.needsApproval, "Question request remains visible and blocks until the user answers")
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
    var probeEntry = s.entry; probeEntry.command = "muse"
    let localProbe = Session(SavedSession(id: s.id, entry: probeEntry, title: "Probe", messages: [], draft: "/usage", attachments: [], remoteID: nil, started: true))
    store.send(localProbe)
    let probeDeadline = Date().addingTimeInterval(12)
    while localProbe.probingStatus && Date() < probeDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    check(!localProbe.busy && !localProbe.probingStatus && localProbe.process == nil && localProbe.messages.last?.text.contains("Session total: 0 in / 0 out") == true, "Real read-only Muse session query and local /usage work without a turn")
    do {
        let changed = try MuseStatusProbe.query(entry: probeEntry, sessionID: s.id.uuidString, change: .effort("max"), serverArguments: ["--provider", "echo"])
        check(changed.status.effort == "max", "Real Muse setter persists session effort without a model turn")
        let access = try MuseStatusProbe.query(entry: probeEntry, sessionID: s.id.uuidString, change: .access(":read-only"), serverArguments: ["--provider", "echo"])
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
    parkingLotSelfTests(check)
    paneSizingSelfTests(check)
    identitySelfTests(check)
    // Native approval UI runs after image fixtures that intentionally precede AppKit initialization.
    parkingLotReviewConnectivitySelfTests(check)
    print("All checks passed")
}
signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--agent-image-live-test") { exit(MainActor.assumeIsolated { agentImageLiveTest() } ? 0 : 1) }
if CommandLine.arguments.contains("--probe-muse-quota") {
    do { print(try MuseQuota.query(entry: Entry(name: "Muse", command: "muse", directory: "~", engine: "muse")).text); exit(0) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if let at = CommandLine.arguments.firstIndex(of: "--probe-muse-status"), CommandLine.arguments.count > at + 1 {
    do { print(try MuseStatusProbe.query(entry: Entry(name: "Muse", command: "muse", directory: "~", engine: "muse"), sessionID: CommandLine.arguments[at + 1]).detail); exit(0) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if let at = CommandLine.arguments.firstIndex(of: "--probe-response-image"), CommandLine.arguments.count > at + 1 {
    guard ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil,
          let path = ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"],
          let url = URL(string: CommandLine.arguments[at + 1]) else { exit(2) }
    exit(probeResponseImage(url, folder: URL(fileURLWithPath: path)) ? 0 : 1)
}
if let at = CommandLine.arguments.firstIndex(of: "--probe-provider-status"), CommandLine.arguments.count > at + 2 {
    let engine = CommandLine.arguments[at + 1], directory = CommandLine.arguments[at + 2]
    guard ["codex", "claude", "muse"].contains(engine) else { exit(2) }
    do {
        let entry = Entry(name: engine, command: engine, directory: "~", engine: engine, accountDirectory: directory)
        let snapshot: ProviderSnapshot
        if engine == "muse" {
            let result = try MuseStatusProbe.query(entry: entry, sessionID: UUID().uuidString)
            snapshot = ProviderSnapshot(status: result.status, models: result.models, access: result.access, account: result.status.account ?? "", detail: result.detail)
        } else { snapshot = try ProviderStatus.query(entry: entry, remoteID: nil) }
        print(snapshot.detail)
        print("Access: " + snapshot.access.map { $0.id + ($0.available ? "" : " (unavailable)") }.joined(separator: ", "))
        print("Catalog: " + snapshot.models.map { $0.id + " [" + $0.efforts.joined(separator: ", ") + "]" }.joined(separator: "; "))
        exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--groups-self-test") {
    guard ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil, ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"] != nil else { exit(2) }
    var failures = 0
    converseGroupSelfTests { value, label in if value { print("PASS: " + label) } else { failures += 1; fputs("FAIL: " + label + "\n", stderr) } }
    exit(failures == 0 ? 0 : 1)
}
if CommandLine.arguments.contains("--conversation-layout-self-test") {
    guard ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil, ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"] != nil else { exit(2) }
    var failures = 0
    conversationLayoutSelfTests { value, label in if value { print("PASS: " + label) } else { failures += 1; fputs("FAIL: " + label + "\n", stderr) } }
    exit(failures == 0 ? 0 : 1)
}
if CommandLine.arguments.contains("--pane-sizing-self-test") {
    guard ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil, ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"] != nil else { exit(2) }
    paneSizingSelfTests { value, label in if !value { fputs("FAIL: " + label + "\n", stderr); exit(1) }; print("PASS: " + label) }; exit(0)
}
if CommandLine.arguments.contains("--provider-self-test") {
    guard ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil, ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"] != nil else { fputs("Use test.sh --providers-only for isolated tests.\n", stderr); exit(2) }
    providerSelfTests { value, label in if !value { fputs("FAIL: " + label + "\n", stderr); exit(1) }; print("PASS: " + label) }
    print("All provider checks passed"); exit(0)
}
if CommandLine.arguments.contains("--ipad-home-fixture") { runIPadHomeFixture(); exit(0) }
if CommandLine.arguments.contains("--self-test") { selfTest(); exit(0) }
if Bundle.main.object(forInfoDictionaryKey: "ConverseNUXPreview") as? Bool == true {
    let isolated = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent((Bundle.main.object(forInfoDictionaryKey: "ConverseDemo") as? Bool == true ? "Converse Demo" : "Converse Setup Preview"))
    setenv("CONVERSE_DATA_DIR", isolated.path, 1)
    do {
        if try DemoReset.consume(folder: isolated, enabled: DemoReset.enabled, clearCredentials: DemoReset.clearCredentials) != nil,
           let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
    } catch {
        NSAlert(error: error).runModal()
        exit(1) // Never open a half-reset profile.
    }
}
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
