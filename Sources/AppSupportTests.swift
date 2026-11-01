import AppKit
import Foundation

@MainActor func appSupportSelfTests(_ check: @escaping (Bool, String) -> Void) {
    let linkText = NSMutableAttributedString(string: "Café 🐈 and docs")
    linkText.addAttribute(.link, value: URL(string: "https://example.com/a?b=1")!, range: NSRange(location: 0, length: 7))
    check(TranscriptClipboard.plainText(linkText) == "Café 🐈 (https://example.com/a?b=1) and docs", "Copy selection retains link destinations with Unicode ranges")
    let privateReport = "Bug 123\nBearer fixture-secret\ngithub_pat_fixture\nuser@example.com\n/Users/alice/private.txt\nC:\\Users\\alice\\private.txt\n192.168.1.2\n-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----"
    let scrubbed = BugReportPrivacy.scrub(privateReport)
    check(scrubbed.contains("Bug 123") && !scrubbed.contains("alice") && !scrubbed.contains("fixture") && !scrubbed.contains("example.com") && !scrubbed.contains("192.168"), "Bug report scrubber removes common credentials and identifiers locally while preserving symptoms")
    check(BugReportPrivacy.summary(version: "test", os: "macOS", grouped: true, peers: 2, online: 1, sessions: 3, busy: 1).contains("Known peers: 2; online: 1"), "Diagnostics consist of allowlisted versions and counts")
    let oldAPI = AgentRuntime.shared.api, oldKeyReader = AgentRuntime.shared.keyReader
    defer { AgentRuntime.shared.api = oldAPI; AgentRuntime.shared.keyReader = oldKeyReader }
    AgentRuntime.shared.keyReader = { _ in nil }
    AgentRuntime.shared.api.request = { request in
        (Data("{\"total_count\":0,\"items\":[],\"tag_name\":\"test\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("converse-support-" + UUID().uuidString)
    let store = Store(folder: folder)
    let session = store.supportSession()
    check(store.supportSession() === session && store.sessions.count == 1, "Support onboarding creates exactly one welcome session")
    check(!store.setupCompleted && session.supportTeachingVersion == nil && !session.switchboardEnabled, "Support is gated before a verified model response")
    check(AppSupport.welcome.contains("[README](converse-help://readme)") && AppSupport.welcome.contains("[Discord](converse-help://discord)") && AppSupport.welcome.contains("[Connect the Meta Muse iPhone app](converse-help://muse-iphone)"), "Support welcome contains the three requested actionable links")
    let help = try! HelpBook.load()
    check(AppSupport.guideTopics.values.allSatisfy { id in help.topics.contains { $0.id == id } } && AppSupport.guideTopics.keys.allSatisfy { AppSupport.welcome.contains("converse-help://" + $0) }, "All three support getting-started links resolve to bundled Help topics")
    let report = GitHubBugReport(title: "A & B / café", body: "Line one\n@someone &title=wrong # ?")
    let browser = try! report.browserURL()
    let query = URLComponents(url: browser, resolvingAgainstBaseURL: false)!.queryItems!
    check(browser.host == "github.com" && browser.path == "/richardkaufmann/converse/issues/new" && query.first { $0.name == "title" }?.value == report.title && query.first { $0.name == "body" }?.value == report.body, "GitHub report URL preserves Unicode and query-like report text in the fixed repository")
    check((try? GitHubBugReport(title: " ", body: "x").validated()) == nil && (try? GitHubBugReport(title: "x", body: String(repeating: "界", count: 2000)).browserURL()) == nil, "Bug reports reject empty titles and overly long browser URLs without truncating evidence")
    var reportTestsFinished = false
    Task { @MainActor in
        defer { reportTestsFinished = true }
        let api = AgentAPI(); var requests = 0
        api.request = { request in
            requests += 1
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            check(request.httpMethod == "POST" && request.url?.absoluteString == "https://api.github.com/repos/richardkaufmann/converse/issues" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture" && body == ["title": report.title, "body": report.body], "GitHub submission sends only reviewed report text and keeps authorization out of its body")
            return (Data("{\"number\":42,\"html_url\":\"https://github.com/richardkaufmann/converse/issues/42\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        }
        let receipt = try? await report.submit(token: "fixture", api: api)
        check(receipt?.absoluteString == "https://github.com/richardkaufmann/converse/issues/42" && requests == 1, "GitHub confirms a filed report with its exact issue receipt")
        for status in [401, 403, 404, 429, 500] {
            requests = 0
            api.request = { request in requests += 1; return (Data("secret must not be echoed".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) }
            do { _ = try await report.submit(token: "fixture", api: api); check(false, "GitHub failure must not report success") }
            catch { check(requests == 1 && !error.localizedDescription.contains("secret must"), "GitHub HTTP \(status) fails once without reposting or echoing service content") }
        }
        requests = 0
        api.request = { _ in requests += 1; throw URLError(.timedOut) }
        do { _ = try await report.submit(token: "fixture", api: api); check(false, "Timeout cannot confirm filing") }
        catch { check(requests == 1 && error.localizedDescription.contains("Check the issue list"), "Ambiguous network outcome asks to check GitHub and never automatically retries") }
        api.request = { request in (Data("{\"number\":42,\"html_url\":\"https://example.invalid/issues/42\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!) }
        check((try? await report.submit(token: "fixture", api: api)) == nil, "Foreign receipt URLs cannot become successful bug reports")
    }
    let reportDeadline = Date().addingTimeInterval(5)
    while !reportTestsFinished && Date() < reportDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(reportTestsFinished, "GitHub reporting fixture tests complete without network or Discord")
    let command = AppSupportCommand(action: "create-agent", title: "Example", objective: "Help with this project")
    check((try? store.appSupportResult(command, session: session, openUI: false)) == nil, "Untaught sessions cannot control the app")
    session.supportTeachingVersion = AppSupport.version
    let reportResult = try? store.appSupportResult(AppSupportCommand(action: "report-bug", target: "https://example.invalid", title: "Fixture", body: "Only this description"), session: session, openUI: false)
    check(reportResult?.contains("Nothing has been submitted") == true && session.agent == nil, "Reporting prepares a review without requiring an agent, Discord or credentials, and does not claim filing")
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
    check(!accepted && !store.setupCompleted && !session.switchboardEnabled, "Failed provider exit never opens the setup gate even with a matching response")
    session.supportProbeCompletion = { accepted = $0 }; session.messages[session.messages.count - 1].finalReply = nil
    store.finishSupportProbe(session, success: true)
    check(!accepted && !store.setupCompleted && !session.switchboardEnabled, "Codex connection gate requires its authoritative final response")
    session.messages[session.messages.count - 1].finalReply = AppSupport.connectionReply
    session.supportProbeCompletion = { accepted = $0 }; store.finishSupportProbe(session, success: true)
    let completed = Store(folder: folder)
    check(accepted && store.setupCompleted && completed.setupCompleted && session.switchboardEnabled && completed.sessions.first { $0.id == session.id }?.switchboardEnabled == true, "Successful provider confirmation persists both app control and switchboard capability")
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
    // Clearing is presentation-only: model context, teaching and pending work survive.
    session.pending = [PendingPrompt(text: "Retain queued work", images: [])]
    let history = session.messages
    session.attachments = ["/tmp/retained-draft-image.png"]
    session.draft = "/clear"
    check(store.handleLocalCommand(session) && session.displayedMessages.isEmpty && session.messages == history && session.pending.count == 1 && session.attachments.count == 1 && session.switchboardEnabled && session.supportTeachingVersion != nil && !session.busy, "/clear hides history without changing context, teaching, attachments or queued work")
    let cleared = Store(folder: folder).sessions.first { $0.id == session.id }!
    check(cleared.displayedMessages.isEmpty && cleared.messages == history, "Cleared display persists across restart while retaining the full transcript")
    let newReply = Message(role: "assistant", text: "Visible after clear")
    session.messages.append(newReply)
    check(session.displayedMessages == [newReply], "New output appears after /clear")
    session.draft = "/unclear"
    check(store.handleLocalCommand(session) && session.displayedMessages == history + [newReply], "/unclear restores all retained history locally without a model request")
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
    if [[ "$*" != *"--tools"* ]]; then
      print '{"type":"result","is_error":false,"result":"CONVERSE_CONNECTION_OK"}'
    else
      print -r '{"type":"result","is_error":false,"result":"{\\"reply\\":\\"Welcome to Converse!\\",\\"attention\\":\\"\\"}"}'
    fi
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
    check(journey.setupCompleted && journey.sessions.count == 1 && journey.sessions[0].supportTeachingVersion == AppSupport.version && journey.sessions[0].switchboardEnabled, "NUX journey: provider selection, isolated native login, model subprocess response and automatic support handoff")
    let taught = journey.sessions[0]
    check(taught.agent?.enabled == true && taught.agent?.intervalSeconds == 86400 && taught.agent?.repository == "richardkaufmann/converse" && taught.agent?.generateArt == false && taught.agent?.watchedSessions.isEmpty == true, "App Support becomes a daily repository agent with no art or watched sessions")
    check(AgentModels.parse(taught.agent?.model ?? "")?.engine == "claude", "Support agent keeps the verified provider instead of switching to Meta")
    taught.agent?.enabled = false; journey.configureSupportAgent(taught)
    check(taught.agent?.enabled == false, "Default migration never re-enables a loop the user paused")
    for engine in ["claude", "codex", "muse"] {
        let route = AgentModels.reference(engine: engine, account: "login:with|separators", model: "same-model")
        check(AgentModels.parse(route)?.account == "login:with|separators" && AgentModels.parse(route)?.engine == engine, "Model choice retains explicit provider and account: " + engine)
        let args = AgentCLI.arguments(engine: engine, model: "same-model", prompt: "/tmp/prompt", output: "/tmp/final")
        check(args.contains("--model") && !args.contains("--resume") && !args.contains("--yolo") && !args.contains("--dangerously-bypass-approvals-and-sandbox"), "Agent CLI uses a fresh bounded turn without bypass flags: " + engine)
    }
    check(AgentModels.parse("cli|claude|bad-base64|bad") == nil && (try? AgentCLI.finalReply(engine: "claude", data: Data("{\"is_error\":true,\"result\":\"unsafe\"}".utf8), final: nil)) == nil, "Malformed model routes and failed provider results cannot execute actions")
    check((taught.pending.map(\.text) + taught.messages.filter { $0.role == "user" }.map(\.text)).contains { $0.contains("[Converse switchboard instructions]") && $0.contains("[Converse setup and control teaching") }, "NUX injects both teaching prompts together after the provider gate")
    let drain = Date().addingTimeInterval(20)
    while (taught.busy || !taught.pending.isEmpty) && Date() < drain { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(taught.agent?.lastOutcome == "Completed", "The taught support agent completes its first turn using the selected CLI provider")
    check(taught.clearedThroughMessageID != nil && !taught.displayedMessages.contains { $0.role == "user" || $0.text.contains("[Converse setup and control teaching") } && taught.messages.contains { $0.text.contains("[Converse switchboard instructions]") }, "Support onboarding clears login and teaching from display while retaining learned context")

}
