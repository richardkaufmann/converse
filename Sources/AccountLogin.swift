import AppKit
import Foundation

struct AccountLogin {
    static func directoryKey(_ directory: String) -> String { URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path }
    static func requiresSignIn(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["not logged in", "not signed in", "please run /login", "authentication required", "authentication token has expired", "oauth token has expired"].contains { text.contains($0) }
    }
}
extension Store {
    func sessionsUsingLogin(_ profile: AccountProfile) -> [Session] {
        sessions.filter { session in
            session.entry.engine == profile.engine && (session.entry.useDefaultAccountStore == true) == (profile.useDefaultStore == true) &&
            loginAccount(for: session).map { AccountLogin.directoryKey($0.directory) == AccountLogin.directoryKey(profile.directory) } == true
        }
    }
    func loginAccount(for session: Session) -> AccountProfile? {
        guard ["claude", "codex"].contains(session.entry.engine) else { return nil }
        let entry = session.entry
        let profile = accounts.first { $0.id == (entry.accountID ?? entry.engine + "-default") && $0.engine == entry.engine }
        guard let directory = entry.accountDirectory ?? profile?.directory, !directory.isEmpty else { return nil }
        return AccountProfile(id: entry.accountID ?? profile?.id ?? entry.engine, name: entry.accountName ?? profile?.name ?? entry.name, engine: entry.engine, directory: directory, useDefaultStore: entry.useDefaultAccountStore)
    }
    @discardableResult
    func signInSession(_ session: Session, name: String? = nil, freshProfile: AccountProfile? = nil) -> Bool {
        guard let original = loginAccount(for: session) else {
            session.messages.append(Message(role: "notice", text: session.entry.engine == "muse" ? "Sign in using the Muse CLI in Terminal, then return and refresh this session. No login prompt was sent to the model." : "Choose an account with a configuration folder in Settings before signing in.")); save(); return false
        }
        guard !session.busy, !session.changingSetting else {
            session.messages.append(Message(role: "notice", text: "Finish or stop this session’s current turn before changing its login.")); save(); return false
        }
        let profile = freshProfile ?? makeLogin(engine: original.engine, name: name ?? (original.name + " session login"))
        guard sessionsUsingLogin(profile).allSatisfy({ $0 === session }),
              AccountLogin.directoryKey(profile.directory) != AccountLogin.directoryKey(original.directory) || !session.started && session.remoteID == nil else { return false }
        do {
            try SessionLoginContext.copy(session, from: original, to: profile)
            guard signIn(profile, command: session.entry.command, sessionID: session.id) else { return false }
            bindLogin(session, profile: profile)
            session.queuePaused = true; session.needsSignIn = true
            session.messages.append(Message(role: "notice", text: "Sign-in opened in Terminal for this session only. Complete authentication and return here. Its conversation, retained CLI context, draft and attachments are preserved. Other sessions keep their existing login. Queued input is paused until you resume it."))
            save(); return true
        } catch {
            session.messages.append(Message(role: "notice", text: error.localizedDescription)); save(); return false
        }
    }
    func bindLogin(_ session: Session, profile: AccountProfile) {
        var entry = session.entry
        entry.accountID = profile.id; entry.accountName = profile.name; entry.accountDirectory = profile.directory; entry.useDefaultAccountStore = profile.useDefaultStore
        session.entry = entry; session.accountStatus = ""; session.probeError = ""
        session.modelChoices = []; session.accessChoices = []; session.toolStatus.account = nil; session.toolStatus.accountObservedAt = nil
        session.toolStatus.accountUsage = nil; session.toolStatus.quota = nil; session.quotaRefreshedAt = nil
        session.needsSignIn = false
    }
}
