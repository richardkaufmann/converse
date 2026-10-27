import Foundation

struct AccountLogin {
    static func directoryKey(_ directory: String) -> String { URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path }
    static func requiresSignIn(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["not logged in", "not signed in", "please run /login", "authentication required", "authentication token has expired", "oauth token has expired"].contains { text.contains($0) }
    }
}
extension Store {
    func loginAccount(for session: Session) -> AccountProfile? {
        guard ["claude", "codex"].contains(session.entry.engine) else { return nil }
        let entry = session.entry
        let profile = accounts.first { $0.id == (entry.accountID ?? entry.engine + "-default") && $0.engine == entry.engine }
        guard let directory = entry.accountDirectory ?? profile?.directory, !directory.isEmpty else { return nil }
        return AccountProfile(id: entry.accountID ?? profile?.id ?? entry.engine, name: entry.accountName ?? profile?.name ?? entry.name, engine: entry.engine, directory: directory)
    }
    func signInSession(_ session: Session) {
        guard let profile = loginAccount(for: session) else {
            session.messages.append(Message(role: "notice", text: session.entry.engine == "muse" ? "Sign in using the Muse CLI in Terminal, then return and refresh this session. No login prompt was sent to the model." : "Choose an account with a configuration folder in Settings before signing in.")); save(); return
        }
        guard !session.busy, !session.changingSetting, !accountIsBusy(profile) else {
            session.messages.append(Message(role: "notice", text: "Sign-in is held because this account has active work. Stop or finish its turns, then use Sign in… or /login again.")); save(); return
        }
        if signIn(profile, command: session.entry.command) {
            session.messages.append(Message(role: "notice", text: "Sign-in opened in Terminal for \(profile.name). Complete the CLI/browser flow, then return here. This conversation keeps its account, history and draft; queued input is paused until you resume it. The account is chosen with the account menu, independently of the conversation title."))
            save()
        }
    }
}
