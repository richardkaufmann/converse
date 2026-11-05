import AppKit
import SwiftUI

struct SessionSetupRequest: Identifiable {
    let id = UUID()
    var engine: String
    var sessionID: UUID? = nil
    var focusPickers = false
}
/// New sessions use the setup sheet; an existing session opens Configure
/// conversation, where its assistant and login are chosen.
struct SessionSetupSheet: View {
    let request: SessionSetupRequest
    @ObservedObject var state: WindowState
    var body: some View {
        if let id = request.sessionID, let session = Store.shared.sessions.first(where: { $0.id == id }) {
            ConfigureConversationView(session: session, focusPickers: request.focusPickers)
        } else { SessionSetupView(request: request, state: state) }
    }
}
enum AssistantFamily {
    static func name(_ engine: String) -> String {
        ["claude": "Claude", "codex": "Codex", "muse": "Muse", "agent": "Agent"][engine] ?? engine.capitalized
    }
}
extension Store {
    var assistantFamilies: [String] {
        Array(Set(entries.map(\.engine) + sessions.map { $0.entry.engine })).filter { $0 != "agent" && $0 != ConverseExchange.unboundEngine }.sorted()
    }
    // Reuse the provider verified by onboarding, including after it becomes an agent.
    // Keep credentials in the same edition's profile; never copy them between apps.
    func preferredLogin(engine: String) -> AccountProfile? {
        if setupCompleted, let support = sessions.first(where: { $0.supportAssistant }),
           let route = support.agent.flatMap({ AgentModels.parse($0.model) }), route.engine == engine,
           let profile = accounts.first(where: { $0.id == route.account && $0.engine == engine }) { return profile }
        return accounts.first { $0.engine == engine }
    }
    func defaultEntry(engine: String) -> Entry {
        entries.first { $0.engine == engine } ?? SetupCatalog.entries.first { $0.engine == engine }!
    }
    func loginLabel(_ profile: AccountProfile) -> String {
        let matching = sessions.filter {
            $0.entry.engine == profile.engine && ($0.entry.useDefaultAccountStore == true) == (profile.useDefaultStore == true) &&
            AccountLogin.directoryKey($0.entry.accountDirectory ?? "") == AccountLogin.directoryKey(profile.directory)
        }
        let identity = matching.map(\.accountStatus).first { $0.contains("@") }
        return identity.map { $0 == profile.name ? $0 : "\($0) · \(profile.name)" } ?? profile.name
    }
    func sessionLoginLabel(_ session: Session) -> String {
        if session.isAgentSession, let account = AgentModels.apiKeyAccount(session.agent?.model) { return account.label }
        if session.accountStatus.contains("@") { return session.accountStatus }
        return loginAccount(for: session).map(loginLabel) ?? session.entry.accountName ?? "CLI login"
    }
    @discardableResult
    func makeLogin(engine: String, name: String) -> AccountProfile {
        let id = UUID().uuidString
        let profile = AccountProfile(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AssistantFamily.name(engine) + " login" : name, engine: engine, directory: folder.appendingPathComponent("Accounts/" + id).path)
        accounts.append(profile); save(); return profile
    }
    func createBoundSession(entry: Entry, profile: AccountProfile, title: String) -> Session? {
        guard entry.engine == profile.engine else { return nil }
        var bound = entry
        bound.accountID = profile.id; bound.accountName = profile.name; bound.accountDirectory = profile.directory; bound.useDefaultAccountStore = profile.useDefaultStore
        let session = create(bound)
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { session.title = title }
        save(); return session
    }
}
final class SessionSetupProgress: ObservableObject {
    @Published var engine: String
    @Published var accountID: String
    @Published var title = ""
    @Published var directory: String
    @Published var loginName = ""
    @Published var signIn = false
    init(request: SessionSetupRequest) {
        let entry = Store.shared.defaultEntry(engine: request.engine)
        engine = request.engine
        accountID = Store.shared.preferredLogin(engine: request.engine)?.id ?? "new"
        directory = entry.directory
    }
}
struct SessionSetupView: View {
    @ObservedObject var store = Store.shared
    let request: SessionSetupRequest
    @ObservedObject var state: WindowState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var progress: SessionSetupProgress
    init(request: SessionSetupRequest, state: WindowState) {
        self.request = request; self.state = state
        _progress = StateObject(wrappedValue: SessionSetupProgress(request: request))
    }
    private var engine: String { progress.engine }
    private var accountID: String { progress.accountID }
    private var title: String { progress.title }
    private var directory: String { progress.directory }
    private var loginName: String { progress.loginName }
    private var signIn: Bool { progress.signIn }
    private var profiles: [AccountProfile] { store.accounts.filter { $0.engine == engine } }
    private var isNew: Bool { accountID == "new" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New session").font(.title2.bold())
            Picker("Model / assistant", selection: $progress.engine) {
                ForEach(store.assistantFamilies.filter { $0 != "support" }, id: \.self) { Text(AssistantFamily.name($0)).tag($0) }
            }.onChange(of: engine) { _, value in
                progress.accountID = store.preferredLogin(engine: value)?.id ?? "new"
                progress.directory = store.defaultEntry(engine: value).directory
            }
            TextField("Session name (optional)", text: $progress.title)
            HStack {
                TextField("Working folder", text: $progress.directory)
                Button("Choose…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { progress.directory = url.path }
                }
            }
            Picker("Login", selection: $progress.accountID) {
                ForEach(profiles) { profile in
                    Text(store.loginLabel(profile)).tag(profile.id)
                }
                if engine != "muse" { Text("New login…").tag("new") }
            }
            if engine == "claude" && !profiles.contains(where: { $0.useDefaultStore == true }) {
                Button("Use installed Claude CLI login") {
                    let profile = store.installedClaudeLogin()
                    progress.accountID = profile.id
                }.help("Reuse the CLI’s normal login without signing in again.")
            }
            if isNew {
                TextField("Name this login (e.g. Personal or Work)", text: $progress.loginName)
                Text("Creates a separate login and opens the CLI’s authentication flow in Terminal. Finish signing in, then return here.").font(.callout).foregroundStyle(.secondary)
            } else if engine != "muse" {
                Toggle("Sign in to another account for this session", isOn: $progress.signIn)
                Text("Reusing a saved login does not change it. Signing into another account creates an isolated login for this session and preserves its conversation.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Muse uses the selected saved login and permission profiles. Your setup login can be reused by other sessions in this app.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Create & sign in…" : "Create session") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!SetupCatalog.validDirectory(directory))
            }
        }.padding(24).frame(width: 480).textFieldStyle(.roundedBorder)
    }
    private func finish() {
        guard let profile = isNew ? store.makeLogin(engine: engine, name: loginName) : profiles.first(where: { $0.id == accountID }) else { return }
        var entry = store.defaultEntry(engine: engine); entry.directory = directory
        guard let target = store.createBoundSession(entry: entry, profile: profile, title: title) else { return }
        if isNew { guard store.signInSession(target, freshProfile: profile) else { return } }
        else if signIn { guard store.signInSession(target, name: profile.name) else { return } }
        dismiss()
    }
}

extension Store {
    func setApproval(_ session: Session, value: String?) {
        guard session.entry.engine == "codex", !session.changingSetting else { return }
        session.choices.approval = value; session.toolStatus.approval = value
        session.settingNotice = "Change saved · applies next turn"
        save(); if !session.busy { refreshStatus(session) }
    }
    func clearOverride(_ session: Session, field: String) {
        guard session.entry.engine != "muse", !session.changingSetting else { return }
        switch field {
        case "model": session.choices.model = nil; session.choices.modelProvider = nil; session.choices.modelProfile = nil; session.toolStatus.model = "CLI default"
        case "effort": session.choices.effort = nil; session.toolStatus.effort = "CLI default"
        case "access": session.choices.access = nil; session.toolStatus.access = "CLI default"
        default: return
        }
        session.settingNotice = "Change saved · applies next turn"
        save(); if !session.busy { refreshStatus(session) }
    }
}

struct SessionSettingsRow: View {
    @ObservedObject var session: Session
    @ObservedObject var store: Store
    @ObservedObject var flow: SettingsFlow
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(session.title).lineLimit(1)
                Text(store.sessionLoginLabel(session)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rename…") { AppDelegate.shared.renameSession(session) }
            Button("Configure…") { flow.request = SessionSetupRequest(engine: session.entry.engine, sessionID: session.id) }.disabled(session.busy || session.changingSetting)
            Button("Assistant & Login…") { flow.request = SessionSetupRequest(engine: session.entry.engine, sessionID: session.id, focusPickers: true) }.disabled(session.busy || session.changingSetting)
        }
    }
}
extension Store {
    func configure(_ session: Session, title: String, command: String, directory: String) throws {
        guard !session.busy, !session.changingSetting else {
            throw NSError(domain: "Converse", code: 1, userInfo: [NSLocalizedDescriptionKey: "Finish or stop the current turn before changing its settings."])
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !command.isEmpty, SetupCatalog.validDirectory(directory) else {
            throw NSError(domain: "Converse", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use a nonempty title and command, and an existing working folder."])
        }
        let changed = session.entry.command != command || session.entry.directory != directory
        session.title = title
        var entry = session.entry; entry.command = command; entry.directory = directory
        session.entry = entry
        if changed {
            session.toolStatus.accountUsage = nil; session.toolStatus.quota = nil; session.quotaRefreshedAt = nil
        }
        save()
        if changed { refreshStatus(session) }
    }
}

extension Store {
    func installedClaudeLogin() -> AccountProfile {
        if let profile = accounts.first(where: { $0.engine == "claude" && $0.useDefaultStore == true }) { return profile }
        let profile = AccountProfile(id: UUID().uuidString, name: "Installed CLI login", engine: "claude", directory: NSHomeDirectory() + "/.claude", useDefaultStore: true)
        accounts.append(profile); save(); return profile
    }
}
