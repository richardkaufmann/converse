import Foundation

func setupSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-setup-" + UUID().uuidString)
    let store = Store(folder: root)
    check(!store.setupCompleted && store.entries.count == 3 && store.accounts.map(\.name).sorted() == ["Claude", "Codex", "Muse"], "Fresh setup uses only generic default accounts and opens onboarding")
    check(store.entries.allSatisfy { SetupCatalog.validDirectory($0.directory) }, "Every default assistant starts with an existing working folder")
    store.completeSetup(selected: [])
    check(!store.setupCompleted && store.entries.count == 3, "Empty setup selections cannot erase assistants")
    store.addAccount(engine: "codex"); store.addAccount(engine: "codex")
    let extra = store.accounts.filter { $0.engine == "codex" && $0.id != "codex-default" }
    check(extra.count == 2 && extra[0].directory != extra[1].directory && extra[0].name != extra[1].name && extra.allSatisfy { $0.directory.hasPrefix(root.path) }, "Additional accounts get distinct generic names and isolated local stores")
    check(!Store(folder: root).setupCompleted, "Partially completed setup reappears after relaunch")
    let codex = store.entries.first { $0.engine == "codex" }!
    let session = store.completeSetup(selected: [codex.id], sessionEntryID: codex.id, accountID: extra[0].id)!
    check(store.setupCompleted && store.entries.count == 1 && session.entry.accountID == extra[0].id && session.entry.accountDirectory == extra[0].directory && session.messages.isEmpty && !session.busy, "Setup creates selected assistant/account session without submitting a prompt")
    check(store.entries[0].accountID == extra[0].id, "Setup account selection becomes the default for later sessions")
    session.draft = "keep this draft"; session.remoteID = "retained-session"; store.save()
    let restored = Store(folder: root)
    check(restored.setupCompleted && restored.sessions.first?.draft == "keep this draft" && restored.sessions.first?.entry.accountDirectory == extra[0].directory, "Completed setup and account snapshots survive relaunch")
    restored.entries.append(SetupCatalog.entries.first { $0.engine == "claude" }!)
    restored.completeSetup(selected: [codex.id])
    check(restored.entries.count == 2 && restored.sessions.count == 1 && restored.sessions[0].remoteID == "retained-session", "Reopening setup preserves other assistants and existing conversations")
    let legacyRoot = root.appendingPathComponent("legacy")
    try! FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
    let legacyAccount = AccountProfile(id: "codex-existing", name: "Existing work account", engine: "codex", directory: root.appendingPathComponent("existing-account").path)
    let archive = Archive(entries: [codex], sessions: [session.saved], accounts: [legacyAccount])
    try! JSONEncoder().encode(archive).write(to: legacyRoot.appendingPathComponent("sessions.json"))
    let legacy = Store(folder: legacyRoot)
    check(legacy.setupCompleted && legacy.accounts == [legacyAccount] && legacy.sessions[0].draft == "keep this draft", "Upgrading an older archive skips onboarding and preserves custom accounts and drafts")
    let skip = Store(folder: root.appendingPathComponent("skip")); skip.setupCompleted = true; skip.save()
    check(Store(folder: skip.folder).setupCompleted, "Set up later stays dismissed after relaunch")
    check(SetupChecks.version(Entry(name: "Test", command: "/usr/bin/true", directory: "~", engine: "codex")).hasPrefix("CLI available"), "Setup checks CLI installation without a model turn")
    check(SetupChecks.version(Entry(name: "Missing", command: "/nonexistent/converse-cli", directory: "~", engine: "codex")).contains("Could not run CLI"), "Missing CLI has actionable setup feedback")
}
