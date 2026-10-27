import Foundation

func sessionSetupSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-session-setup-" + UUID().uuidString)
    let store = Store(folder: root)
    let personal = store.makeLogin(engine: "claude", name: "Personal")
    let work = store.makeLogin(engine: "claude", name: "Work")
    let a = Entry(name: "Claude", command: "claude", directory: root.path, engine: "claude")
    let b = Entry(name: "Legacy account-specific launcher", command: "custom-claude", directory: root.path, engine: "claude")
    store.entries = [a, b]
    let first = store.createBoundSession(entry: a, profile: personal, title: "Personal session")!
    let second = store.createBoundSession(entry: b, profile: work, title: "Work session")!
    check(store.assistantFamilies == ["claude"] && store.sessions.filter { $0.entry.engine == "claude" }.count == 2, "Legacy account launchers group under one model without migrating session identity")
    check(first.entry.accountDirectory == personal.directory && second.entry.accountDirectory == work.directory && first.id != second.id, "New sessions bind independent logins at creation")
    check(store.createBoundSession(entry: a, profile: AccountProfile(id: "wrong", name: "Wrong", engine: "codex", directory: root.path), title: "") == nil, "Session creation rejects a login from another model")
    first.accountStatus = "qa@example.invalid"
    check(store.loginLabel(personal).contains("qa@example.invalid") && !store.loginLabel(work).contains("qa@example.invalid"), "Login picker reuses observed identity only from its own login directory")
    let context = URL(fileURLWithPath: personal.directory).appendingPathComponent("projects/test/retained.jsonl")
    try! FileManager.default.createDirectory(at: context.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data("retained conversation".utf8).write(to: context)
    first.remoteID = "retained"; first.started = true; first.messages = [Message(role: "assistant", text: "keep context")]
    first.draft = "keep draft"; first.attachments = ["attachment.png"]
    let next = store.chooseAccount(first, profile: work)
    check(next === first && first.remoteID == "retained" && first.entry.accountID == work.id && first.messages.last?.text == "keep context" && store.sessions.count == 2, "Rebinding a login preserves the same conversation and its retained CLI identity")
    check(next.draft == "keep draft" && next.attachments == ["attachment.png"] && second.entry.accountID == work.id, "Changing a session login preserves its unsent input and other sessions")
    next.busy = true
    check(store.chooseAccount(next, profile: personal) === next && next.entry.accountID == work.id, "Login selection cannot rebind an active session")
    next.busy = false
    store.entries = []
    check(store.assistantFamilies == ["claude"], "Sessions remain visible when their old launch configuration is absent")
    let claude = ProviderStatus.resolveClaude(payload: [:])
    check(claude.access.contains { $0.id == "bypassPermissions" } && claude.access.contains { $0.id == "dontAsk" && $0.label.contains("deny") }, "Claude exposes distinct bypass and deny-unapproved modes")
    let claudeArgs = ProviderCommand.turnArguments(entry: a, choices: SessionChoices(access: "bypassPermissions"), id: UUID(), remoteID: "retained", started: true, images: [])
    check(claudeArgs.contains("bypassPermissions") && claudeArgs.contains("--permission-mode") && claudeArgs.contains("--resume"), "Claude bypass choice reaches resumed CLI turns")
    let codex = Entry(name: "Codex", command: "codex", directory: root.path, engine: "codex")
    let choices = SessionChoices(model: "test", effort: "xhigh", access: "danger-full-access", approval: "never")
    let args = ProviderCommand.turnArguments(entry: codex, choices: choices, id: UUID(), remoteID: "retained", started: true, images: [])
    check(args.contains("sandbox_mode=\"danger-full-access\"") && args.contains("approval_policy=\"never\"") && args.contains("model_reasoning_effort=\"xhigh\""), "Codex sandbox, approval and reasoning controls remain independent on resume")
    let decoded = try! JSONDecoder().decode(SessionChoices.self, from: JSONEncoder().encode(choices))
    let legacy = try! JSONDecoder().decode(SessionChoices.self, from: Data("{}".utf8))
    check(decoded.approval == "never" && legacy.approval == nil, "Codex approval choice persists and old archives remain compatible")
}
