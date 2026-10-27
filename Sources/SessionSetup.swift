import AppKit
import SwiftUI

struct SessionSetupRequest: Identifiable {
    let id = UUID()
    var engine: String
    var sessionID: UUID? = nil
}
enum AssistantFamily {
    static func name(_ engine: String) -> String {
        ["claude": "Claude", "codex": "Codex", "muse": "Muse"][engine] ?? engine.capitalized
    }
}
extension Store {
    var assistantFamilies: [String] {
        Array(Set(entries.map(\.engine) + sessions.map { $0.entry.engine })).sorted()
    }
    func defaultEntry(engine: String) -> Entry {
        entries.first { $0.engine == engine } ?? SetupCatalog.entries.first { $0.engine == engine }!
    }
    func loginLabel(_ profile: AccountProfile) -> String {
        let matching = sessions.filter {
            $0.entry.engine == profile.engine &&
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
        bound.accountID = profile.id; bound.accountName = profile.name; bound.accountDirectory = profile.directory
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
            if isNew {
                TextField("Name this login (e.g. Personal or Work)", text: $progress.loginName)
                Text("Creates a separate login and opens the CLI’s authentication flow in Terminal. Finish signing in, then return here.").font(.callout).foregroundStyle(.secondary)
            } else if engine != "muse" {
                Toggle("Sign in again using this login", isOn: $progress.signIn)
                Text("An existing login is reused. Sign in again only if it has expired or you want to authenticate it.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Muse uses its installed CLI login and permission profiles.").font(.callout).foregroundStyle(.secondary)
            }
            if let session, session.started || session.remoteID != nil || !session.messages.isEmpty || !session.pending.isEmpty {
                Text("Choosing a different login starts a new conversation. This session keeps its history and login.").font(.callout).foregroundStyle(.secondary)
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
        guard let profile = isNew ? store.makeLogin(engine: engine, name: loginName) : profiles.first(where: { $0.id == accountID && $0.engine == engine }) else { return }
        let target: Session
        if let session {
            target = store.chooseAccount(session, profile: profile)
        } else {
            var entry = store.defaultEntry(engine: engine); entry.directory = directory
            guard let created = store.createBoundSession(entry: entry, profile: profile, title: title) else { return }
            target = created
        }
        AppDelegate.shared.select(target, state: state)
        if isNew || signIn { store.signInSession(target) }
        dismiss()
    }
}

extension Store {
    func setApproval(_ session: Session, value: String?) {
        guard session.entry.engine == "codex", !session.busy, !session.changingSetting else { return }
        session.choices.approval = value; session.toolStatus.approval = value
        save(); refreshStatus(session)
    }
    func clearOverride(_ session: Session, field: String) {
        guard session.entry.engine != "muse", !session.busy, !session.changingSetting else { return }
        switch field {
        case "model": session.choices.model = nil; session.toolStatus.model = "CLI default"
        case "effort": session.choices.effort = nil; session.toolStatus.effort = "CLI default"
        case "access": session.choices.access = nil; session.toolStatus.access = "CLI default"
        default: return
        }
        save(); refreshStatus(session)
    }
}
