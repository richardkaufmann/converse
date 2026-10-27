import Foundation

func accountLoginSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-login-" + UUID().uuidString)
    let store = Store(folder: root)
    var opened: [URL] = []
    store.loginFileOpener = { opened.append($0); return true }
    for engine in ["claude", "codex"] {
        let original = root.appendingPathComponent(engine + " old account store").path
        let profile = AccountProfile(id: engine + "-test", name: "Work", engine: engine, directory: original)
        store.accounts = [profile]
        let entry = Entry(name: "Assistant", command: "custom-" + engine + " --option 'literal'", directory: "~", engine: engine, accountID: profile.id, accountName: profile.name, accountDirectory: original)
        let session = store.create(entry); session.remoteID = "retained-context"; session.started = true
        session.draft = "keep draft"; session.attachments = ["keep.png"]
        session.pending = [PendingPrompt(text: "hold queued message", images: [])]
        store.accounts[0].directory = root.appendingPathComponent("new default store").path
        store.signInSession(session)
        let script = try! String(contentsOf: opened.last!, encoding: .utf8)
        check(script.contains(ProviderCommand.quote(original)) && script.contains("custom-" + engine) && !script.contains("new default store"), engine + " sign-in uses exact session account snapshot and custom CLI command")
        check(script.contains(engine == "claude" ? "'auth' 'login'" : "'login'") && script.contains("unset "), engine + " login uses official CLI flow and isolates inherited credentials")
        check(session.draft == "keep draft" && session.attachments == ["keep.png"] && session.queuePaused && session.remoteID == "retained-context", engine + " sign-in preserves context, draft and attachments while holding queued input")
        let previous = opened.count
        session.busy = true
        let alias = AccountProfile(id: "alias", name: "Alias", engine: engine, directory: original + "/./")
        check(store.accountIsBusy(alias), engine + " equivalent account directory spellings share the active-login guard")
        store.signInSession(session); session.busy = false
        check(opened.count == previous, engine + " active account cannot be signed in underneath a running turn")
        session.draft = "/login"
        check(store.handleLocalCommand(session) && session.draft.isEmpty && !session.busy && opened.count == previous + 1, engine + " slash login is handled locally without a model turn")
        check(session.attachments == ["keep.png"] && session.pending.first?.text == "hold queued message", engine + " slash login preserves attachments and queued input")
    }
    let muse = store.create(Entry(name: "Muse", command: "muse", directory: "~", engine: "muse"))
    let count = opened.count; muse.draft = "/login"
    check(store.handleLocalCommand(muse) && opened.count == count && muse.messages.last?.text.contains("Muse CLI in Terminal") == true, "Muse slash login gives local guidance instead of sending an unsupported command")
    check(AccountLogin.requiresSignIn("Not logged in · Please run /login") && AccountLogin.requiresSignIn("Not signed in") && !AccountLogin.requiresSignIn("Network timeout"), "Authentication failures are distinguished from unrelated command errors")
}
