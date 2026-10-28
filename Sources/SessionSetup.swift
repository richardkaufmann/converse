import AppKit
import SwiftUI

struct SessionSetupRequest: Identifiable {
    let id = UUID()
    var engine: String
    var sessionID: UUID? = nil
}
enum AssistantFamily {
    static func name(_ engine: String) -> String {
        ["claude": "Claude", "codex": "Codex", "muse": "Muse", "agent": "Agent"][engine] ?? engine.capitalized
    }
}
extension Store {
    var assistantFamilies: [String] {
        Array(Set(entries.map(\.engine) + sessions.map { $0.entry.engine })).filter { $0 != "agent" }.sorted()
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
    @Published var title: String
    @Published var directory: String
    @Published var loginName = ""
    @Published var signIn = false
    init(request: SessionSetupRequest) {
        let session = Store.shared.sessions.first { $0.id == request.sessionID }
        let entry = session?.entry ?? Store.shared.defaultEntry(engine: request.engine)
        engine = request.engine
        accountID = session?.entry.accountID ?? Store.shared.accounts.first { $0.engine == request.engine }?.id ?? "new"
        title = session?.title ?? ""; directory = entry.directory
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
    private var session: Session? { store.sessions.first { $0.id == request.sessionID } }
    private var profiles: [AccountProfile] {
        var profiles = store.accounts.filter { $0.engine == engine }
        if let session, let saved = store.loginAccount(for: session), !profiles.contains(where: { $0.id == saved.id }) { profiles.append(saved) }
        return profiles
    }
    private var isNew: Bool { accountID == "new" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(session == nil ? "New session" : "Session login").font(.title2.bold())
            if session == nil {
                Picker("Model / assistant", selection: $progress.engine) {
                    ForEach(store.assistantFamilies, id: \.self) { Text(AssistantFamily.name($0)).tag($0) }
                }.onChange(of: engine) { _, value in
                    progress.accountID = store.accounts.first { $0.engine == value }?.id ?? "new"
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
            } else {
                Text(AssistantFamily.name(engine) + " → " + (session?.title ?? "")).font(.headline)
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
                Text("Muse uses its installed CLI login and permission profiles.").font(.callout).foregroundStyle(.secondary)
            }
            if let session, session.started || session.remoteID != nil || !session.messages.isEmpty || !session.pending.isEmpty {
                Text("Changing the login preserves this session’s history, draft and retained CLI context. Other sessions are unchanged.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Create & sign in…" : (session == nil ? "Create session" : "Use login")) { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((session == nil && !SetupCatalog.validDirectory(directory)) || session?.busy == true || session?.changingSetting == true)
            }
        }.padding(24).frame(width: 480).textFieldStyle(.roundedBorder)
    }
    private func finish() {
        let target: Session
        if let session {
            if isNew || signIn {
                guard store.signInSession(session, name: isNew ? loginName : profiles.first(where: { $0.id == accountID })?.name) else { return }
            } else {
                guard let profile = profiles.first(where: { $0.id == accountID }) else { return }
                _ = store.chooseAccount(session, profile: profile)
            }
            target = session
        } else {
            guard let profile = isNew ? store.makeLogin(engine: engine, name: loginName) : profiles.first(where: { $0.id == accountID }) else { return }
            var entry = store.defaultEntry(engine: engine); entry.directory = directory
            guard let created = store.createBoundSession(entry: entry, profile: profile, title: title) else { return }
            target = created
            if isNew { guard store.signInSession(target, freshProfile: profile) else { return } }
            else if signIn { guard store.signInSession(target, name: profile.name) else { return } }
        }
        AppDelegate.shared.select(target, state: state)
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
            Button("Configure…") { AppDelegate.shared.configureSession(session) }.disabled(session.busy || session.changingSetting)
            Button("Login…") { flow.request = SessionSetupRequest(engine: session.entry.engine, sessionID: session.id) }.disabled(session.busy || session.changingSetting)
        }
    }
}
extension Store {
    func configure(_ session: Session, title: String, command: String, directory: String) throws {
        guard !session.busy, !session.changingSetting else {
            throw NSError(domain: "Converse", code: 1, userInfo: [NSLocalizedDescriptionKey: "Finish or stop the current turn before changing its settings."])
        }
        guard !title.isEmpty, !command.isEmpty, SetupCatalog.validDirectory(directory) else {
            throw NSError(domain: "Converse", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use a nonempty title and command, and an existing working folder."])
        }
        let changed = session.entry.command != command || session.entry.directory != directory
        session.title = title
        var entry = session.entry; entry.command = command; entry.directory = directory
        session.entry = entry
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
