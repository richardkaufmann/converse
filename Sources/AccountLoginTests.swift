import Foundation

func accountLoginSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-login-" + UUID().uuidString)
    let store = Store(folder: root)
    var opened: [URL] = []
    store.loginFileOpener = { opened.append($0); return true }
    for engine in ["claude", "codex"] {
        let original = root.appendingPathComponent(engine + " original")
        let profile = AccountProfile(id: engine + "-test", name: "Work", engine: engine, directory: original.path)
        store.accounts.append(profile)
        let context = original.appendingPathComponent(engine == "claude" ? "projects/test/retained-context.jsonl" : "sessions/test/rollout-retained-context.jsonl")
        try! FileManager.default.createDirectory(at: context.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("retained conversation".utf8).write(to: context)
        try! Data("must-not-copy".utf8).write(to: original.appendingPathComponent(".credentials.json"))
        let entry = Entry(name: "Assistant", command: "custom-" + engine + " --option 'literal'", directory: "~", engine: engine, accountID: profile.id, accountName: profile.name, accountDirectory: original.path)
        let session = store.create(entry); session.remoteID = "retained-context"; session.started = true
        session.draft = "keep draft"; session.attachments = ["keep.png"]
        session.pending = [PendingPrompt(text: "hold queued message", images: [])]
        let peer = store.create(entry); peer.title = "Other session"; peer.busy = true
        let originalPeer = peer.entry
        let id = session.id
        store.signInSession(session)
        let isolated = store.loginAccount(for: session)!
        let script = try! String(contentsOf: opened.last!, encoding: .utf8)
        check(isolated.directory != original.path && session.id == id && script.contains(ProviderCommand.quote(isolated.directory)) && script.contains("custom-" + engine), engine + " session sign-in authenticates a fresh private store for the same session")
        check(script.contains(engine == "claude" ? "'auth' 'login'" : "'login'") && script.contains("unset "), engine + " isolated login uses official CLI flow and excludes inherited credentials")
        check(peer.entry == originalPeer && peer.busy && !peer.queuePaused, engine + " signing into one session leaves another session's login and active work untouched")
        check(session.remoteID == "retained-context" && session.draft == "keep draft" && session.attachments == ["keep.png"] && session.queuePaused, engine + " private sign-in preserves CLI identity, draft and attachments and holds only its own queue")
        let copied = URL(fileURLWithPath: isolated.directory).appendingPathComponent(engine == "claude" ? "projects/test/retained-context.jsonl" : "sessions/test/rollout-retained-context.jsonl")
        check(FileManager.default.contentsEqual(atPath: context.path, andPath: copied.path) && !FileManager.default.fileExists(atPath: URL(fileURLWithPath: isolated.directory).appendingPathComponent(".credentials.json").path), engine + " login migration copies only this conversation's context and never credentials")
        let previous = opened.count; session.busy = true
        store.signInSession(session); session.busy = false
        check(opened.count == previous, engine + " a busy session cannot change its login")
        peer.busy = false
        check(!store.signIn(profile) && opened.count == previous, engine + " direct profile authentication cannot overwrite a login used by another session")
        session.draft = "/login"
        check(store.handleLocalCommand(session) && session.draft.isEmpty && !session.busy && opened.count == previous + 1, engine + " local slash login isolates authentication without a model turn")
        check(session.attachments == ["keep.png"] && session.pending.first?.text == "hold queued message", engine + " slash login preserves attachments and queued input")
    }
    let defaultProfile = AccountProfile(id: "legacy-default", name: "Installed login", engine: "claude", directory: root.path, useDefaultStore: true)
    var legacyEntry = Entry(name: "Claude", command: "claude", directory: root.path, engine: "claude", accountID: defaultProfile.id, accountDirectory: root.path, useDefaultAccountStore: true)
    let legacy = store.create(legacyEntry)
    legacyEntry.accountID = "explicit"; legacyEntry.useDefaultAccountStore = false
    let explicit = store.create(legacyEntry)
    let script = ProviderCommand.script(entry: legacy.entry, arguments: ["auth", "status", "--json"])
    check(script.contains("unset CLAUDE_CONFIG_DIR") && !script.contains("export CLAUDE_CONFIG_DIR"), "Installed Claude login keeps its original authentication namespace")
    check(store.sessionsUsingLogin(defaultProfile).contains { $0 === legacy } && !store.sessionsUsingLogin(defaultProfile).contains { $0 === explicit }, "Same physical Claude folder can represent distinct explicit and installed login namespaces")
    legacy.entry.command = "env -u CLAUDE_CONFIG_DIR claude"; legacy.remoteID = "imported-context"; legacy.started = true
    store.save()
    let importedStore = Store(folder: root)
    let imported = importedStore.sessions.first { $0.id == legacy.id }!
    check(imported.entry.command == "claude" && imported.entry.useDefaultAccountStore == true && imported.remoteID == "imported-context" && importedStore.sessions.first(where: { $0.id == explicit.id })?.entry == explicit.entry, "Importing an installed-login command override preserves its session and leaves explicit login bindings unchanged")
    let muse = store.create(Entry(name: "Muse", command: "muse", directory: "~", engine: "muse"))
    let count = opened.count; muse.draft = "/login"
    check(store.handleLocalCommand(muse) && opened.count == count && muse.messages.last?.text.contains("Muse CLI in Terminal") == true, "Muse slash login gives local guidance instead of sending an unsupported command")
    check(AccountLogin.requiresSignIn("Not logged in · Please run /login") && !AccountLogin.requiresSignIn("Network timeout"), "Authentication failures are distinguished from unrelated command errors")
}
