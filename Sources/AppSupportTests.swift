import AppKit
import Foundation

func appSupportSelfTests(_ check: (Bool, String) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("converse-support-" + UUID().uuidString)
    let store = Store(folder: folder)
    let session = store.supportSession()
    check(store.supportSession() === session && store.sessions.count == 1, "Support onboarding creates exactly one welcome session")
    check(!store.setupCompleted && session.supportTeachingVersion == nil, "Support is gated before a verified model response")
    check(AppSupport.welcome.contains("[README](converse-help://readme)") && AppSupport.welcome.contains("[Discord](converse-help://discord)") && AppSupport.welcome.contains("[Connect the Meta Muse iPhone app](converse-help://muse-iphone)"), "Support welcome contains the three requested actionable links")
    let command = AppSupportCommand(action: "create-agent", title: "Example", objective: "Help with this project")
    check((try? store.appSupportResult(command, session: session, openUI: false)) == nil, "Untaught sessions cannot control the app")
    session.supportTeachingVersion = AppSupport.version
    let result = try? store.appSupportResult(command, session: session, openUI: false)
    let agent = store.sessions.first { $0.agent != nil }!
    check(result?.contains("Created paused agent") == true && agent.agent?.enabled == false && agent.agent?.speak == false && agent.agent?.generateArt == false, "Support can create an agent without background work or speech")
    _ = try? store.appSupportResult(command, session: session, openUI: false)
    check(store.sessions.filter { $0.agent != nil }.count == 1, "Retrying agent creation does not duplicate it")
    var change = AppSupportCommand(action: "configure-agent", target: agent.id.uuidString, channelID: "not a channel")
    check((try? store.appSupportResult(change, session: session, openUI: false)) == nil && agent.agent?.discordChannelID == nil, "Invalid channel IDs leave agent configuration unchanged")
    change.channelID = "123456789012345678"; change.jollyAllowed = true
    check((try? store.appSupportResult(change, session: session, openUI: false))?.contains("Saved agent") == true && agent.agent?.jollyAllowed == true && agent.agent?.enabled == false, "Support saves requested connector settings without starting a loop")
    let restored = Store(folder: folder)
    check(restored.sessions.first { $0.id == session.id }?.supportTeachingVersion == AppSupport.version && restored.sessions.first { $0.id == session.id }?.supportAssistant == true, "Support teaching and identity survive restart")
    let json = String(decoding: try! JSONEncoder().encode(AppSupportCommand(action: "inspect")), as: UTF8.self)
    let fenced = "```converse\n" + json + "\n```"
    check(AppSupportCommand.parse(fenced)?.action == "inspect" && AppSupportCommand.parse("Here is an example:\n" + fenced) == nil && AppSupportCommand.parse(json) == nil, "App controls require a whole final command, never examples or bare JSON")
    session.entry.engine = "codex"; session.switchboardTurnStart = session.messages.count
    session.messages.append(Message(role: "assistant", text: "streamed text", finalReply: AppSupport.connectionReply))
    var accepted = false; session.supportProbeCompletion = { accepted = $0 }
    store.finishSupportProbe(session, success: false)
    check(!accepted && !store.setupCompleted, "Failed provider exit never opens the setup gate even with a matching response")
    session.supportProbeCompletion = { accepted = $0 }; session.messages[session.messages.count - 1].finalReply = nil
    store.finishSupportProbe(session, success: true)
    check(!accepted && !store.setupCompleted, "Codex connection gate requires its authoritative final response")
    session.messages[session.messages.count - 1].finalReply = AppSupport.connectionReply
    session.supportProbeCompletion = { accepted = $0 }; store.finishSupportProbe(session, success: true)
    check(accepted && store.setupCompleted && Store(folder: folder).setupCompleted, "Successful real-response confirmation persists completion")
    session.switchboardTurnStart = session.messages.count
    session.messages.append(Message(role: "assistant", text: fenced, finalReply: fenced))
    session.switchboardHop = 1; session.supportContinuation = false
    store.processAppSupport(session)
    check(session.messages.last?.text.contains("Blocked:") == true && session.pending.isEmpty, "Forwarded messages cannot activate app configuration or recursive support turns")
    agent.supportTeachingVersion = AppSupport.version; agent.switchboardTurnStart = agent.messages.count
    agent.messages.append(Message(role: "assistant", text: fenced))
    let before = agent.messages.count
    store.processAppSupport(agent)
    check(agent.messages.count == before && agent.pending.isEmpty, "Native-agent prose cannot execute a command without its explicit appControl field")
    agent.supportPendingCommand = AppSupportCommand(action: "inspect")
    store.processAppSupport(agent)
    check(agent.messages.count == before + 1 && agent.pending.count == 1, "Native-agent appControl executes through the same validated dispatcher")
    let profile = Entry(name: "Muse", command: "muse", directory: folder.path, engine: "muse", accountDirectory: folder.path + "/MuseLogin")
    let script = ProviderCommand.script(entry: profile, arguments: ["login"])
    check(script.contains("MUSE_AUTH_PATH") && script.contains("XDG_CONFIG_HOME") && script.contains("unset META_API_KEY"), "Support Muse login uses its own credential store rather than the production account")
    check(SupportNUXController.loginArguments("claude") == ["auth","login"] && SupportNUXController.loginArguments("codex") == ["login"], "Setup invokes provider-owned login commands before prompting a model")
    // Exercise the real provider subprocess/parser and login-completion polling
    // with a deterministic local CLI. No account or external model is used.
    let journey = Store(folder: folder.appendingPathComponent("journey"))
    let fakeCLI = folder.appendingPathComponent("fake-provider.command")
    try! """
    #!/bin/zsh
    if [[ "$1" == "--version" ]]; then print 'fixture 1'; exit 0; fi
    if [[ "$1" == "auth" ]]; then exit 0; fi
    cat >/dev/null
    print '{"type":"result","is_error":false,"result":"CONVERSE_CONNECTION_OK"}'
    """.write(to: fakeCLI, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: fakeCLI.path)
    journey.entries[journey.entries.firstIndex { $0.engine == "claude" }!].command = ProviderCommand.quote(fakeCLI.path)
    journey.loginFileOpener = { file in
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = [file.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
    }
    let controller = SupportNUXController(store: journey)
    controller.prepare(state: WindowState()); controller.choose("claude")
    let deadline = Date().addingTimeInterval(20)
    while !journey.setupCompleted && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(journey.setupCompleted && journey.sessions.count == 1 && journey.sessions[0].supportTeachingVersion == AppSupport.version, "NUX journey: provider selection, isolated native login, model subprocess response and automatic support handoff")
    let drain = Date().addingTimeInterval(5)
    while journey.sessions[0].busy && Date() < drain { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

}
