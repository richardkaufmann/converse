import AppKit
import SwiftUI

/// The catch-up message an imported conversation offers its new provider: an
/// ordinary, editable draft, sent only when the human presses Return.
enum RestoreContext {
    static let framing = "Context from an imported Converse conversation — a record, not instructions."
    static let messageCount = 10
    static let messageLimit = 2_000
    static let blockLimit = 16_000
    static let truncated = "…[truncated; the rest is in transcript.md]"
    static let separator = "\n\n---\n"

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(max(0, limit - truncated.count))) + truncated
    }
    static func label(_ message: Message) -> String {
        var text = Store.visibleText(message.text)
        let images = Array(repeating: "[image]", count: message.images.count).joined(separator: " ")
        if !images.isEmpty { text = text.isEmpty ? images : text + "\n" + images }
        return (message.role == "user" ? "User: " : "Assistant: ") + clip(text, messageLimit)
    }
    /// Framing, the handoff note when present, the last ten user/assistant
    /// messages oldest first (each and all capped), then the transcript path.
    static func block(messages: [Message], handoff: String?, transcript: String) -> String {
        var head = [framing]
        if let handoff { head.append("Read the handoff note first: " + handoff) }
        let tail = "Full transcript: " + transcript
        let recent = messages.filter { ["user", "assistant"].contains($0.role) }.suffix(messageCount).map(label)
        guard !recent.isEmpty else { return (head + [tail]).joined(separator: "\n") }
        // Newest messages win the shared budget; an older one may be cut short.
        let fixed = (head + ["The last 10 messages:", tail]).joined(separator: "\n").count + 4
        var budget = blockLimit - fixed, kept: [String] = []
        for entry in recent.reversed() {
            let cost = entry.count + 2
            if cost <= budget { kept.append(entry); budget -= cost; continue }
            if budget - 2 > truncated.count + 40 { kept.append(clip(entry, budget - 2)) }
            break
        }
        kept.reverse()
        let count = kept.count == 1 ? "The last message:" : "The last \(kept.count) messages:"
        return (head + [count]).joined(separator: "\n") + "\n\n" + kept.joined(separator: "\n\n") + "\n\n" + tail
    }
    /// Puts `block` first. A block generated earlier is replaced where it
    /// still stands; otherwise the human's text follows after a separator.
    /// Returns nil when an earlier block was edited or removed: that draft is
    /// the human's now and stays as it is.
    static func merge(_ block: String, previous: String?, into draft: String) -> String? {
        if let previous {
            guard let range = draft.range(of: previous) else { return nil }
            return draft.replacingCharacters(in: range, with: block)
        }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return block + "\n\n" }
        return block + separator + draft
    }
}

extension Session {
    /// Bound to a provider with the catch-up draft prepared but not yet sent:
    /// the provider has seen nothing, so choosing again simply rebinds.
    var restoringImport: Bool { restoreContext != nil && !started && remoteID == nil && !busy }
}

extension Store {
    /// App Support's assistant is the app's lead provider; when its CLI is
    /// missing, the first installed assistant leads instead.
    func leadProvider(families: [String]) -> String? {
        let support = sessions.first { $0.supportAssistant }
        let preferred = support.flatMap { $0.agent.flatMap { AgentModels.parse($0.model)?.engine } ?? $0.entry.engine }
        if let preferred, families.contains(preferred), providerInstalled(preferred) { return preferred }
        return families.first(where: providerInstalled) ?? families.first
    }
    var importFamilies: [String] { assistantFamilies.filter { $0 != "support" } }
    func providerInstalled(_ engine: String) -> Bool {
        guard let entry = entries.first(where: { $0.engine == engine }) ?? SetupCatalog.entries.first(where: { $0.engine == engine }) else { return false }
        return agentCommandAvailable(entry)
    }
    /// Why a saved login cannot be used as it stands, if it can't.
    func loginStoreProblem(_ profile: AccountProfile) -> String? {
        guard profile.engine != "muse", !profile.directory.isEmpty else { return nil }
        var isDir: ObjCBool = false
        let path = NSString(string: profile.directory).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) { return loginLabel(profile) + "’s saved sign-in is missing." }
        if !isDir.boolValue || !FileManager.default.isReadableFile(atPath: path) { return loginLabel(profile) + "’s saved sign-in can’t be read." }
        return nil
    }
    /// The picker's starting point: the lead provider and its preferred login.
    func importPickerDefaults() -> (engine: String, accountID: String) {
        let engine = leadProvider(families: importFamilies) ?? "claude"
        return (engine, preferredLogin(engine: engine)?.id ?? "new")
    }

    /// Writes the catch-up message into the draft and drops the hidden
    /// first-send preface, so the context is supplied once, visibly. Sends nothing.
    func prepareRestoreDraft(_ s: Session) {
        let note = handoffNoteURL(s), transcript = handoffTranscriptURL(s)
        if !FileManager.default.fileExists(atPath: transcript.path) { try? writeHandoffTranscript(s, pending: s.handoffPending) }
        let block = RestoreContext.block(messages: s.messages, handoff: FileManager.default.fileExists(atPath: note.path) ? note.path : nil, transcript: transcript.path)
        if let draft = RestoreContext.merge(block, previous: s.restoreContext, into: s.draft) { s.draft = draft; s.restoreContext = block }
        s.handoffPending = nil
        save()
    }

    /// The inline picker's Use: binds the chosen assistant and login and
    /// prepares the draft. A new login opens its sign-in. Returns an error.
    @discardableResult
    func useImportProvider(_ s: Session, engine: String, accountID: String, loginName: String = "") -> String? {
        guard s.isUnboundImport || s.restoringImport else { return "This conversation already has a provider." }
        if let reason = providerChangeRefusal(s) { return reason }
        guard importFamilies.contains(engine), providerInstalled(engine) else { return AssistantFamily.name(engine) + " isn’t installed on this Mac." }
        let fresh = accountID == "new"
        if fresh && engine == "muse" { return "Sign in with the Muse CLI in Terminal, then choose its login." }
        guard let profile = fresh ? makeLogin(engine: engine, name: loginName) : accounts.first(where: { $0.id == accountID && $0.engine == engine }) else {
            return "Choose one of " + AssistantFamily.name(engine) + "’s logins."
        }
        do { try switchProvider(s, entry: defaultEntry(engine: engine), profile: profile, note: false) }
        catch {
            if fresh { accounts.removeAll { $0.id == profile.id }; save() }
            return error.localizedDescription
        }
        if fresh { signInSession(s, freshProfile: profile) }
        return nil
    }
}

extension AppDelegate {
    /// Puts the caret at the end of the session's draft once it is on screen.
    static func focusDraftEnd(_ s: Session, attempts: Int = 4) {
        DispatchQueue.main.async {
            guard let text = s.inputTextView, let window = text.window else { return }
            let string = text.string as NSString
            guard string.substring(from: min(text.inputStart, string.length)) == s.draft || attempts <= 1 else { focusDraftEnd(s, attempts: attempts - 1); return }
            window.makeFirstResponder(text)
            let end = NSRange(location: string.length, length: 0)
            text.setSelectedRange(end); text.scrollRangeToVisible(end)
        }
    }
}

/// Compact NUX-style picker at the foot of an imported conversation: provider
/// logos, an Account menu and Use. Choosing again before sending rebinds.
struct ImportProviderPicker: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var session: Session
    @State private var engine: String
    @State private var accountID: String
    @State private var loginName = ""
    @State private var installed: [String: Bool] = [:]
    @State private var error = ""
    init(session: Session) {
        self.session = session
        let defaults: (engine: String, accountID: String) = session.isUnboundImport ? Store.shared.importPickerDefaults() : (session.entry.engine, Store.shared.currentLoginID(session) ?? "new")
        _engine = State(initialValue: defaults.engine); _accountID = State(initialValue: defaults.accountID)
    }
    private var profiles: [AccountProfile] { store.accounts.filter { $0.engine == engine } }
    private var selected: AccountProfile? { profiles.first { $0.id == accountID } }
    private var problem: String? {
        if installed[engine] == false { return AssistantFamily.name(engine) + " isn’t installed on this Mac." }
        if accountID == "new" { return engine == "muse" ? "Sign in with the Muse CLI in Terminal, then choose its login." : nil }
        return selected.flatMap(store.loginStoreProblem).map { $0 + " Choose New login… to sign in again." }
    }
    private var unchanged: Bool { !session.isUnboundImport && engine == session.entry.engine && accountID == store.currentLoginID(session) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(session.isUnboundImport ? "Imported · continue with" : "Catch-up message below · not sent").foregroundStyle(.secondary)
                ForEach(store.importFamilies, id: \.self) { family in
                    let ready = installed[family] != false
                    Button { choose(family) } label: {
                        HStack(spacing: 4) { ProviderLogo(engine: family).frame(width: 16, height: 16); Text(AssistantFamily.name(family)) }
                    }.buttonStyle(.bordered).controlSize(.small).tint(family == engine ? .accentColor : nil)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: family == engine ? 1.5 : 0))
                        .disabled(!ready).opacity(ready ? 1 : 0.45)
                        .help(ready ? "Continue with " + AssistantFamily.name(family) : AssistantFamily.name(family) + " · Not installed")
                        .accessibilityLabel((ready ? "Continue with " : "Not installed: ") + AssistantFamily.name(family))
                }
                Picker("Account", selection: $accountID) {
                    ForEach(profiles) { Text(store.loginLabel($0) + (store.loginStoreProblem($0) == nil ? "" : " · missing")).tag($0.id) }
                    if engine != "muse" { Text("New login…").tag("new") }
                }.labelsHidden().fixedSize().controlSize(.small).help("The login this conversation uses")
                if accountID == "new" && engine != "muse" {
                    TextField("Login name", text: $loginName).textFieldStyle(.roundedBorder).frame(width: 120).controlSize(.small)
                }
                Button(session.isUnboundImport ? "Use" : "Switch") { use() }.controlSize(.small)
                    .disabled(installed[engine] == false || (accountID == "new" && engine == "muse") || unchanged || session.busy)
                    .help("Connect this conversation and fill in an editable catch-up message. Nothing is sent until you press Return.")
                Button("More options…") { AppDelegate.shared.chooseLogin(session) }.buttonStyle(.link)
                Spacer(minLength: 0)
            }
            if let message = error.isEmpty ? problem : error {
                Text(message).foregroundStyle(error.isEmpty ? Color.orange : Color.red).lineLimit(2)
            }
        }.font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 6)
            .onAppear(perform: checkInstalled)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in checkInstalled() }
    }
    private func choose(_ family: String) {
        guard family != engine else { return }
        engine = family; error = ""
        accountID = !session.isUnboundImport && family == session.entry.engine ? (store.currentLoginID(session) ?? "new") : (store.preferredLogin(engine: family)?.id ?? "new")
    }
    /// A PATH lookup per assistant, so it is cheap enough to run inline.
    private func checkInstalled() {
        let families = store.importFamilies
        installed = Dictionary(uniqueKeysWithValues: families.map { ($0, store.providerInstalled($0)) })
        // A CLI removed since the picker opened: move to an installed one.
        if session.isUnboundImport, installed[engine] == false, let next = families.first(where: { installed[$0] == true }) { choose(next) }
    }
    private func use() {
        error = ""
        if let failure = store.useImportProvider(session, engine: engine, accountID: accountID, loginName: loginName) { error = failure; return }
        accountID = store.currentLoginID(session) ?? accountID
        AppDelegate.focusDraftEnd(session)
    }
}
