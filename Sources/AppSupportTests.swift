import AppKit
import Foundation
import SwiftUI

@MainActor func appSupportSelfTests(_ check: @escaping (Bool, String) -> Void) {
    let linkText = NSMutableAttributedString(string: "Café 🐈 and docs")
    linkText.addAttribute(.link, value: URL(string: "https://example.com/a?b=1")!, range: NSRange(location: 0, length: 7))
    check(TranscriptClipboard.plainText(linkText) == "Café 🐈 (https://example.com/a?b=1) and docs", "Copy selection retains link destinations with Unicode ranges")
    let privateReport = "Bug 123\nBearer fixture-secret\ngithub_pat_fixture\nuser@example.com\n/Users/alice/private.txt\nC:\\Users\\alice\\private.txt\n192.168.1.2\n-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----"
    let scrubbed = BugReportPrivacy.scrub(privateReport)
    check(scrubbed.contains("Bug 123") && !scrubbed.contains("alice") && !scrubbed.contains("fixture") && !scrubbed.contains("example.com") && !scrubbed.contains("192.168"), "Bug report scrubber removes common credentials and identifiers locally while preserving symptoms")
    check(BugReportPrivacy.summary(version: "test", os: "macOS", grouped: true, peers: 2, online: 1, sessions: 3, busy: 1).contains("Known peers: 2; online: 1"), "Diagnostics consist of allowlisted versions and counts")
    let resetRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("demo-reset-" + UUID().uuidString)
    let demoFolder = resetRoot.appendingPathComponent("Converse Demo")
    let realFolder = resetRoot.appendingPathComponent("Converse")
    try! FileManager.default.createDirectory(at: demoFolder, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
    try! Data("demo fixture".utf8).write(to: demoFolder.appendingPathComponent("sessions.json"))
    try! Data("production fixture".utf8).write(to: realFolder.appendingPathComponent("sessions.json"))
    defer { try? FileManager.default.removeItem(at: resetRoot) }
    check((try? DemoReset.request(folder: realFolder, enabled: true)) == nil && (try? DemoReset.request(folder: demoFolder, enabled: false)) == nil, "Demo Reset rejects production profiles and normal editions")
    try! DemoReset.request(folder: demoFolder, enabled: true)
    var clearedDemoKeys = 0
    let backup = try! DemoReset.consume(folder: demoFolder, enabled: true, clearCredentials: { clearedDemoKeys += 1 })!
    check((try! String(contentsOf: backup.appendingPathComponent("sessions.json"), encoding: .utf8)) == "demo fixture" && (try! FileManager.default.contentsOfDirectory(atPath: demoFolder.path)).isEmpty && clearedDemoKeys == 1, "Demo Reset backs up demo data and clears it before fresh NUX")
    check((try! String(contentsOf: realFolder.appendingPathComponent("sessions.json"), encoding: .utf8)) == "production fixture" && (try! DemoReset.consume(folder: demoFolder, enabled: true, clearCredentials: { clearedDemoKeys += 1 })) == nil && clearedDemoKeys == 1, "Demo Reset preserves production and is consumed only once")
    try! DemoReset.request(folder: demoFolder, enabled: true)
    check((try? DemoReset.consume(folder: demoFolder, enabled: true, clearCredentials: { throw NSError(domain: "fixture", code: 1) })) == nil && FileManager.default.fileExists(atPath: demoFolder.appendingPathComponent(DemoReset.marker).path), "Failed Demo credential reset retains request for retry instead of starting NUX")
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
    check(AppSupport.welcome.contains("[README](converse-help://readme)") && AppSupport.welcome.contains("[Discord](converse-help://discord)") && AppSupport.welcome.contains("[Home Assistant](converse-help://home-assistant)") && AppSupport.welcome.contains("[Connect the Meta Muse iPhone app](converse-help://muse-iphone)"), "Support welcome links to Home Assistant and the other connector guides")
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
    // A long teaching message must retain its trailing request in model input.
    let longRequest = String(repeating: "Teaching context. ", count: 600) + "Introduce yourself as Converse App Support and show the welcome links."
    let oldRequest = Message(role: "user", text: String(repeating: "old", count: 3000))
    let currentRequest = Message(role: "user", text: longRequest)
    let response = Message(role: "assistant", text: "")
    let input = AgentPromptContext.conversation([oldRequest, currentRequest, response], excluding: response.id)
    check(input.count == 2 && input[0]["text"]?.count == 6000 && input[1]["text"] == longRequest, "Agent input preserves the full current request beyond 6000 characters while bounding history")
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
    check(taught.agent?.enabled == true && taught.agent?.intervalSeconds == 86400 && taught.agent?.repository == "richardkaufmann/converse" && taught.agent?.generateArt == false && taught.agent?.watchedSessions.isEmpty == true && taught.agent?.autoPaceOn == true, "App Support becomes a daily repository agent with Auto pacing on and no art or watched sessions")
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
    check(taught.displayedMessages.contains { $0.role == "assistant" && $0.text.contains("Welcome to Converse!") }, "Provider handoff displays the welcome after clearing login and teaching")
    check(taught.clearedThroughMessageID != nil && !taught.displayedMessages.contains { $0.role == "user" || $0.text.contains("[Converse setup and control teaching") } && taught.messages.contains { $0.text.contains("[Converse switchboard instructions]") }, "Support onboarding clears login and teaching from display while retaining learned context")

    // Regression: onboarding's verified login must be reused, even after restart
    // and after App Support is converted from a CLI session into an agent.
    for engine in ["muse", "claude", "codex"] {
        let fresh = Store(folder: folder.appendingPathComponent("reuse-" + engine))
        let verified = fresh.makeLogin(engine: engine, name: "Verified setup login")
        let support = fresh.supportSession()
        support.entry = fresh.defaultEntry(engine: engine); support.entry.accountID = verified.id
        support.entry.accountDirectory = verified.directory
        fresh.setupCompleted = true; fresh.configureSupportAgent(support)
        let reloaded = Store(folder: fresh.folder)
        let restoredSupport = reloaded.sessions.first { $0.supportAssistant }!
        check(reloaded.preferredLogin(engine: engine)?.id == verified.id, "New-session picker prefers the verified onboarding login after restart: " + engine)
        let ordinary = reloaded.create(reloaded.defaultEntry(engine: engine))
        check(ordinary.entry.accountID == verified.id && ordinary.entry.accountDirectory == verified.directory, "Ordinary session creation shares the verified login: " + engine)
        let operation = AppSupportCommand(action: "create-session", title: "My project", provider: engine, directory: folder.path)
        let outcome = try? reloaded.appSupportResult(operation, session: restoredSupport, openUI: false)
        let coding = reloaded.sessions.first { $0.title == "My project" }!
        check(outcome?.contains(coding.id.uuidString) == true && coding.entry.accountID == verified.id && !coding.busy && coding.draft.isEmpty, "App Support creates a coding session with the verified login and no model request: " + engine)
        _ = try? reloaded.appSupportResult(operation, session: restoredSupport, openUI: false)
        check(reloaded.sessions.filter { $0.title == "My project" }.count == 1, "Retried session creation does not duplicate: " + engine)
        let beforeInvalid = reloaded.sessions.count
        check((try? reloaded.appSupportResult(AppSupportCommand(action: "create-session", provider: engine, directory: folder.path + "/missing"), session: restoredSupport, openUI: false)) == nil && reloaded.sessions.count == beforeInvalid, "Invalid project folder cannot create a session: " + engine)
        let newAgent = reloaded.createAgent(title: "Next agent")
        check(newAgent.agent?.model == restoredSupport.agent?.model, "New agents inherit the working provider instead of requiring a Meta key: " + engine)
        let label = AgentModels.label(restoredSupport.agent!.model)
        check(!label.contains("cli|") && label.contains("CLI default"), "Encoded login routing is never a user-facing model label: " + engine)
        let explicit = reloaded.makeLogin(engine: engine, name: "Other")
        var bound = reloaded.defaultEntry(engine: engine); bound.accountID = explicit.id
        check(reloaded.create(bound).entry.accountID == explicit.id && ordinary.entry.accountID == verified.id, "Explicit alternate login and existing session bindings are preserved: " + engine)
    }

}

// First run on a brand-new data folder: four sessions, one pane, a provider
// choice that renames and binds them, and /login through the provider's CLI.
@MainActor func firstRunSelfTests(_ check: @escaping (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-first-run-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func spin(_ seconds: Double = 10, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    func fresh(_ name: String, cli: Set<String> = ["muse", "codex", "claude"], metaKey: Bool = false) -> (Store, FirstRunGuide, ParkingLotLibrary, SidebarOrder) {
        let folder = root.appendingPathComponent(name)
        let store = Store(folder: folder)
        // Isolated logins: never the real ~/.claude or ~/.codex.
        store.accounts = ["muse", "codex", "claude"].map { AccountProfile(id: $0 + "-default", name: AssistantFamily.name($0), engine: $0, directory: folder.appendingPathComponent("Logins/" + $0).path, useDefaultStore: false) }
        let library = ParkingLotLibrary(folder: folder), order = SidebarOrder(folder: folder)
        let guide = store.firstRun
        guide.cliCheck = { cli.contains($0.engine) }
        guide.metaKeySaved = { metaKey }
        _ = guide.seedIfNeeded(library: library, order: order)
        guide.checkCLIs(); spin { !guide.cli.values.contains(.checking) }
        return (store, guide, library, order)
    }

    // Seeding
    let (store, guide, library, order) = fresh("seed")
    let record = guide.record!
    let support = guide.support!, coding = guide.coding!, agent = guide.agent!
    check(store.sessions.count == 3 && support.supportAssistant && library.records.count == 1 && record.lotID == ParkingLotStore.id && record.stage == "choose", "First run seeds App Support, the starter Parking Lot, a coding session and an agent")
    let ids = [support.id, record.lotID, coding.id, agent.id].map(\.uuidString)
    check(order.ordered(ids.shuffled(), scope: "local") == ids && SidebarOrder(folder: store.folder).ordered(ids.reversed(), scope: "local") == ids, "Sidebar order is App Support, Parking Lot, Coding, Agent and survives restart")
    check(store.setupCompleted && support.entry.engine == "support" && support.messages.isEmpty && support.title == "Converse App Support" && library.records.first?.name == "Parking Lot" && coding.title == "Coding" && agent.title == "Agent", "Seeding skips the setup sheet; App Support waits for a provider choice")
    check(guide.seedIfNeeded(library: library, order: order) == nil && store.sessions.count == 3, "Seeding runs once")
    // Launch places only App Support (AppDelegate.select uses the first free pane).
    let workspace = Workspace(), window = WindowState(workspace: workspace)
    workspace.assign(support.id, to: window.id, pane: workspace.firstAvailablePane(in: window.id))
    check(workspace.pane(for: support.id, in: window.id) == 1 && workspace.placements.count == 1 && [coding.id, agent.id, record.lotID].allSatisfy { workspace.placements[$0] == nil }, "One pane up: App Support in pane 1; Parking Lot, coding session and agent parked")
    let lot = library.lot(record.lotID)!
    let shoeRow = lot.document.rows.first { $0.images?.isEmpty == false }
    check(shoeRow?.text == "An app that pulls data from wherever and figures out how to do whatever" && shoeRow.flatMap { $0.images?.first }.map { FileManager.default.fileExists(atPath: $0) } == true, "Starter Parking Lot's first item carries the shoe picture")
    check(lot.document.rows.map(\.text) == ["What Are We Building", FirstRunText.lotFirstItem, "New features", "Bugs"] && lot.document.rows.map(\.heading) == [true, false, true, true], "Starter Parking Lot: What Are We Building with one item, then New features and Bugs headings")
    check(!lot.document.rows.contains { !$0.heading && $0.text.isEmpty } && !lot.document.rows.contains { $0.text.contains("Welcome to Converse") }, "Starter Parking Lot has no empty items and no old welcome section")
    check(agent.agent?.watchedSessions.contains(record.lotID) == true && agent.agent?.watchedSessions.contains(coding.id) == true, "Agent may read the starter lot and coding session")
    check(agent.agent?.enabled == true && agent.agent?.intervalSeconds == 3600 && agent.agent?.autoPaceOn == true && agent.agent?.paceMinMinutes == 5 && agent.agent?.paceMaxMinutes == 4320
          && agent.agent?.objective == "Monitor the health of the Coding session." && agent.agent?.artDirection == "Show me a picture that matches the sentiment of the app's progress." && agent.agent?.generateArt == false,
          "Starter agent starts on, hourly, Auto pacing 5 min–72 h, watching the Coding session, mood art off without a Meta key")
    check(!agent.agentLoopPaused && agent.pausedLoopReason == nil && agent.agent?.attention.isEmpty == true && agent.agent?.pauseReason == nil, "Starter agent is never shown red or paused before a provider is chosen")
    // Held until sign-in: even an overdue deadline starts no run while the provider is unchosen.
    agent.agent?.nextRunAt = .distantPast
    AgentRuntime().tick(store: store)
    check(guide.holdsAgent(agent) && agent.pending.isEmpty && !agent.busy && agent.agent?.lastLoopAt == nil, "Starter agent never runs before a provider is chosen and signed in")
    agent.agent?.nextRunAt = Date().addingTimeInterval(3600)
    let shoe = ConverseShoe.save(in: store.folder).flatMap { NSImage(contentsOfFile: $0) }
    check(shoe.map { $0.size.width <= 160 && $0.size.width >= 100 } == true, "Shoe picture is small (≤ 160 pt)")
    guide.linkLot(home: "home-mac", library: library)
    let links = library.links(record.lotID)
    check(Set(links) == Set([coding.id, agent.id].map { DeviceGlobalID(home: "home-mac", session: $0).string }), "Starter Parking Lot links to the coding session and agent")
    guide.linkLot(home: "home-mac", library: library)
    check(library.links(record.lotID) == links && ParkingLotLibrary(folder: store.folder).links(record.lotID) == links, "Lot links are added once and persist")
    let restoredStore = Store(folder: store.folder), restoredGuide = restoredStore.firstRun
    check(restoredGuide.record == guide.record && restoredGuide.active, "First-run progress survives restart")

    // Typing before choosing never disappears or reaches a provider.
    support.draft = "hello?"
    store.submit(support)
    check(support.draft == "hello?" && support.messages.last?.text.contains("Pick a provider above") == true && !support.busy, "Typing in App Support before a choice keeps the draft and explains what to do")

    // Missing CLI disables its button with a hint.
    let (partialStore, partial, _, _) = fresh("missing", cli: ["claude"])
    defer { withExtendedLifetime(partialStore) {} }
    if case .missing(let hint) = partial.cli["codex"] { check(hint.contains("codex") && hint.contains("Check again"), "Missing CLI shows a one-line install hint") } else { check(false, "Missing CLI is detected") }
    check(partial.cli["claude"] == .installed, "Installed CLI is enabled")
    partial.choose("codex")
    check(partial.stage == "choose" && partial.coding?.entry.engine == "claude" && partial.support?.entry.engine == "support", "A missing provider cannot be chosen")
    let help = try? HelpBook.load()
    check(help?.topics.contains { $0.id == FirstRunText.installTopic } == true, "How to install opens a bundled Help topic")

    // Richard's 126 test: App Support runs as an agent; choosing Muse without a Meta key
    // must bind it to the Muse sign-in, not leave it on Muse Spark via the Meta API.
    do {
        let (s, g, _, _) = fresh("support-agent-muse", metaKey: false)
        let sup = g.support!
        if sup.agent == nil { sup.agent = AgentConfig() }
        sup.agent?.model = "muse-spark-1.3"; sup.agent?.attention = "Paused: Add a Meta API key"
        g.choose("muse")
        let profile = s.preferredLogin(engine: "muse")!
        let parsed = AgentModels.parse(sup.agent?.model ?? "")
        check(parsed?.engine == "muse" && parsed?.account == profile.id && sup.agent?.attention == "", "Choosing Muse without a Meta key runs App Support on the Muse sign-in and clears the Meta-key banner")
    }

    // Each provider choice
    for engine in FirstRunText.providers {
        for key in engine == "muse" ? [false, true] : [false] {
            let (s, g, _, _) = fresh("choose-" + engine + (key ? "-key" : ""), metaKey: key)
            g.choose(engine)
            let name = AssistantFamily.name(engine)
            let profile = s.preferredLogin(engine: engine)!
            let c = g.coding!, a = g.agent!, sup = g.support!
            check(c.entry.engine == engine && c.entry.accountID == profile.id && c.title == name + " Coding" && c.switchboardEnabled, "Coding session uses the chosen provider and login: " + engine)
            check(c.messages.map(\.text) == ["What shall we build today? You can also ask me to read the Parking Lot and react to it and update it."] && c.messages[0].role == "assistant", "Coding session shows its pre-loaded welcome once: " + engine)
            check(c.title == ["muse": "Muse Coding", "codex": "Codex Coding", "claude": "Claude Coding"][engine] && a.title == ["muse": "Muse Agent", "codex": "Codex Agent", "claude": "Claude Agent"][engine], "Starter sessions take the short provider name: " + engine)
            let model = a.agent?.model ?? ""
            if engine == "muse" && key { check(model == "muse-spark-1.3", "Muse with a saved Meta key runs the agent on Muse Spark") }
            else { check(AgentModels.parse(model)?.engine == engine && AgentModels.parse(model)?.account == profile.id, "Agent runs on the chosen provider's CLI login: " + engine + (key ? " with key" : "")) }
            check(a.title == name + " Agent" && a.messages.count == 1 && a.messages[0].text.contains("Right-click \(name) Agent in the left panel for Agent Setup, Run once, Show scoreboard"), "Agent welcome explains right-clicking its name: " + engine)
            check(sup.entry.engine == engine && sup.entry.accountID == profile.id, "App Support uses the same login: " + engine)
            if sup.agent != nil {
                let supportModel = sup.agent?.model ?? ""
                if engine == "muse" && key { check(supportModel == "muse-spark-1.3", "App Support uses Muse Spark when a Meta key is saved") }
                else { check(AgentModels.parse(supportModel)?.engine == engine && AgentModels.parse(supportModel)?.account == profile.id, "App Support's agent model follows the chosen sign-in (no Meta key needed): " + engine) }
            }
            check(a.agent?.enabled == true && a.agent?.intervalSeconds == 3600 && a.agent?.autoPaceOn == true && a.agent?.objective == "Monitor the health of the \(name) Coding session." && a.agent?.artDirection == FirstRunText.agentArtDirection, "Starter agent stays on, hourly, Auto, monitoring \(name) Coding: " + engine + (key ? " with key" : ""))
            check(a.agent?.generateArt == key, "Starter agent's mood art is on only with a saved Meta key: " + engine + (key ? " with key" : ""))
            check(!a.agentLoopPaused && a.pausedLoopReason == nil && a.agent?.attention.isEmpty == true, "Starter agent shows normally (not red or paused) after the provider choice: " + engine)
            a.agent?.nextRunAt = .distantPast
            AgentRuntime().tick(store: s)
            check(a.pending.isEmpty && !a.busy && a.agent?.lastLoopAt == nil, "Starter agent does not run while sign-in is pending: " + engine)
            check(sup.draft == "/login" && sup.messages.filter { $0.text == FirstRunText.loginPrompt(engine) }.count == 1, "App Support asks to press Return with /login prefilled: " + engine)
            check(sup.messages.filter { $0.text.hasPrefix("# " + FirstRunText.title) && !$0.images.isEmpty }.count == 1, "Welcome with the shoe appears once: " + engine)
            check(g.record?.stage == "login" && g.record?.provider == engine && g.record?.teachCoding == true, "First run waits for login and remembers to teach the coding session: " + engine)
            // Sign-in completes: the hand-off is queued for App Support but never started here (no provider call).
            g.place = { _, _ in }
            let signedIn = Date()
            g.connected(sup)
            sup.pending.removeAll(); sup.queuePaused = true
            let first = a.agent?.nextRunAt ?? .distantPast
            check(!g.holdsAgent(a) && first.timeIntervalSince(signedIn) >= 3600 - 1 && first.timeIntervalSince(signedIn) < 3600 + 60 && !a.agentLoopPaused && a.pausedLoopReason == nil, "Starter agent's first check comes an hour after sign-in completes, shown normally: " + engine)
            AgentRuntime().tick(store: s)
            check(a.pending.isEmpty && a.agent?.lastLoopAt == nil, "Sign-in completing does not fire an immediate agent run: " + engine)
        }
    }
    // Changing provider before login replaces, never duplicates.
    let (switching, switchGuide, _, _) = fresh("switch")
    switchGuide.choose("claude"); switchGuide.reopen(); switchGuide.choose("codex")
    check(switchGuide.coding?.title == "Codex Coding" && switchGuide.agent?.title == "Codex Agent" && switchGuide.support?.messages.filter { $0.role == "assistant" }.count == 2 && switchGuide.support?.messages.last?.text == FirstRunText.loginPrompt("codex") && switching.sessions.count == 3, "Changing the provider rebinds everything without duplicate welcomes")
    // Other text during login is held.
    let held = switchGuide.support!
    held.draft = "What can you do?"; switching.submit(held)
    check(held.draft == "What can you do?" && !held.busy && held.messages.last?.role == "notice", "Text other than /login waits until sign-in")

    // Richard's Pascal test: the coding session learns the switchboard in the same
    // turn as its first request. One turn, no "Got it", only the typed text shown.
    do {
        let (teachStore, teachGuide, _, _) = fresh("teach-first-request")
        teachGuide.choose("muse")
        let c = teachGuide.coding!
        // The local echo provider replies "echo: <prompt>", exposing exactly what the model received.
        c.entry.command = ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] ?? "muse"; c.entry.directory = NSTemporaryDirectory()
        let typed = "show me hello world in pascal"
        c.draft = typed; teachStore.submit(c)
        check(teachGuide.record?.teachCoding == false && c.switchboardEnabled && c.pending.isEmpty && c.busy, "First request starts at once as a single turn")
        spin { !c.busy && c.pending.isEmpty }
        // Echo repeats the teaching's example converse blocks, so the switchboard may add its own
        // "Converse: …" correction turn afterwards; only the first turn is the user's.
        let typedIndex = c.messages.firstIndex { $0.role == "user" } ?? 0
        let ownUsers = c.messages.filter { $0.role == "user" && !$0.text.hasPrefix("Converse: ") }
        check(c.messages[..<typedIndex].map(\.text) == [FirstRunText.codingWelcome] && ownUsers.map(\.text) == [typed] && c.displayedMessages.filter { $0.role == "user" && !$0.text.hasPrefix("Converse: ") }.map(\.text) == [typed], "The transcript shows exactly the typed text as the user message, with no acknowledgement before it")
        let reply = c.messages[(typedIndex + 1)...].first { $0.role == "assistant" }?.text ?? ""
        let teachingAt = reply.range(of: "[Converse switchboard instructions]"), typedAt = reply.range(of: "\n\n" + typed)
        check(reply.hasPrefix("echo: [Converse switchboard instructions]") && teachingAt != nil && typedAt != nil && teachingAt!.lowerBound < typedAt!.lowerBound, "First request is one turn whose prompt carries the teaching, then the typed text")
        check(reply.contains("Do not acknowledge these instructions. Answer the user's message below.") && !reply.contains("First acknowledge these instructions"), "First-run teaching asks for an answer, not an acknowledgement")
        check(!c.messages.contains { $0.role == "user" && $0.text.contains("[Converse switchboard instructions]") } && c.displayedMessages.first?.text == FirstRunText.codingWelcome && c.clearedThroughMessageID == nil, "Teaching never shows as a user message and the welcome stays visible")
        c.draft = "second"; teachStore.submit(c)
        spin { !c.busy && c.pending.isEmpty }
        let later = c.messages.filter { $0.role == "assistant" }.last?.text ?? ""
        check(later.contains("echo: second") && !later.contains("[Converse switchboard instructions]") && c.messages.filter { $0.role == "user" && !$0.text.hasPrefix("Converse: ") }.map(\.text) == [typed, "second"], "Later requests are sent unchanged and teaching is not repeated")
        check(teachGuide.teachIfNeeded(c) == nil, "Teaching happens exactly once")
        // Ordinary sessions: Teach Session keeps its own acknowledgement turn.
        check(teachStore.switchboardTeaching(c).contains("First acknowledge these instructions briefly."), "Teach Session menu teaching is unchanged")
    }
    // Queued behind other work, the teaching travels with that same request.
    let codingSession = switchGuide.coding!
    codingSession.queuePaused = true; codingSession.busy = true
    codingSession.draft = "hi"; switching.submit(codingSession)
    check(codingSession.pending.count == 1 && codingSession.pending[0].text == "hi" && codingSession.pending[0].hiddenPreamble?.contains("[Converse switchboard instructions]") == true && codingSession.pending[0].clearDisplayBeforeReply == nil, "A queued first request keeps its teaching in the same prompt")
    codingSession.draft = "again"; switching.submit(codingSession)
    check(codingSession.pending.count == 2 && codingSession.pending[1].hiddenPreamble == nil && switchGuide.record?.teachCoding == false, "Coding session is taught once")
    codingSession.pending = []; codingSession.busy = false

    // A crash after the first-run record is written but before the sessions are saved
    // leaves a record with no sessions; the next launch must seed again.
    do {
        let (stale, staleGuide, staleLibrary, staleOrder) = fresh("stale")
        stale.sessions = []; stale.setupCompleted = false
        check(staleGuide.seedIfNeeded(library: staleLibrary, order: staleOrder) != nil && stale.sessions.count >= 3 && stale.setupCompleted, "A first-run record whose sessions were never saved is recovered by seeding again")
    }

    // Decide later
    let (later, laterGuide, _, _) = fresh("later")
    laterGuide.decideLater()
    let laterSupport = laterGuide.support!
    laterSupport.draft = "hi"; later.submit(laterSupport)
    check(laterGuide.stage == "later" && later.setupCompleted && laterSupport.draft == "hi" && !laterSupport.busy && later.sessions.count == 3, "Decide later leaves a usable app and keeps App Support waiting")
    laterGuide.cli = [:] // a restart at stage "later" starts with no CLI check results
    laterGuide.reopen()
    check(FirstRunText.providers.allSatisfy { laterGuide.cli[$0] != nil }, "Choose a provider after Decide later re-checks provider CLIs instead of leaving the buttons stuck")
    spin { !laterGuide.cli.values.contains(.checking) }
    laterGuide.choose("claude")
    check(laterGuide.stage == "login" && laterGuide.coding?.title == "Claude Coding", "Choose a provider works after Decide later")

    // Meta key: secure field only, saved via Keychain writer, never in chat.
    let (museStore, museGuide, _, _) = fresh("meta")
    museGuide.choose("muse")
    var written: [String] = []
    museGuide.metaKeyWriter = { written.append($0) }
    museGuide.metaKey = "  fixture-meta-key  "; museGuide.saveMetaKey()
    check(written == ["fixture-meta-key"] && museGuide.metaKey.isEmpty && museGuide.agent?.agent?.model == "muse-spark-1.3", "Saving a Meta key switches the Muse agent to Muse Spark")
    check(!museStore.sessions.contains { $0.messages.contains { $0.text.contains("fixture-meta-key") } || $0.draft.contains("fixture-meta-key") }, "The Meta key never enters a transcript or draft")
    check(AppSupport.credentialStatus(metaKeySaved: true).contains("already saved") && AppSupport.credentialStatus(metaKeySaved: true).contains("never tell them to add one") && AppSupport.credentialStatus(metaKeySaved: false).contains("secure field"), "App Support teaching reflects whether a Meta key is saved")
    check(AppSupport.instructions(agent: true).contains("Credential status"), "Teaching includes the live credential status")

    // Existing stores are untouched.
    let existingFolder = root.appendingPathComponent("existing")
    let existing = Store(folder: existingFolder)
    let kept = existing.create(existing.defaultEntry(engine: "codex")); kept.title = "My work"; existing.save()
    let reopened = Store(folder: existingFolder)
    check(reopened.firstRun.seedIfNeeded(library: ParkingLotLibrary(folder: existingFolder), order: SidebarOrder(folder: existingFolder)) == nil && reopened.sessions.map(\.title) == ["My work"] && !FileManager.default.fileExists(atPath: existingFolder.appendingPathComponent("first-run.json").path), "Existing stores with sessions are untouched")
    let completed = Store(folder: root.appendingPathComponent("completed")); completed.setupCompleted = true; completed.save()
    let completedReload = Store(folder: completed.folder)
    check(completedReload.firstRun.seedIfNeeded(library: ParkingLotLibrary(folder: completed.folder), order: SidebarOrder(folder: completed.folder)) == nil && completedReload.sessions.isEmpty, "A store that already finished setup is never reseeded")
    let reopenedSupport = reopened.sessions[0]; reopenedSupport.draft = "/login"
    check(!reopened.firstRun.intercept(reopenedSupport), "/login keeps its normal meaning outside first run")

    // Return on /login opens each provider's own login command for the shared login.
    for engine in ["muse", "codex"] {
        let (loginStore, loginGuide, _, _) = fresh("login-" + engine)
        if engine == "muse" { loginStore.accounts[0].directory = "" } // the real Muse default
        var scripts: [String] = []
        loginStore.loginFileOpener = { scripts.append((try? String(contentsOf: $0, encoding: .utf8)) ?? ""); return true }
        loginGuide.choose(engine)
        let target = loginGuide.support!
        loginStore.submit(target)
        let expected = engine == "codex" ? "CODEX_HOME" : "exec muse"
        check(scripts.count == 1 && scripts[0].contains("login") && scripts[0].contains(expected) && loginGuide.login.waitingForLogin && target.draft.isEmpty, "Return on /login opens \(engine) login in Terminal and waits for it")
    }

    // /login journey with a deterministic local CLI: login, model check, handoff.
    let (journey, journeyGuide, _, _) = fresh("journey")
    let fakeCLI = root.appendingPathComponent("fake-claude.command")
    try! """
    #!/bin/zsh
    if [[ "$1" == "--version" ]]; then print 'fixture 1'; exit 0; fi
    if [[ "$1" == "auth" && "$2" == "login" ]]; then print -n login > \(ProviderCommand.quote(root.appendingPathComponent("login-ran").path)); exit 0; fi
    cat >/dev/null
    if [[ "$*" != *"--tools"* ]]; then
      print '{"type":"result","is_error":false,"result":"CONVERSE_CONNECTION_OK"}'
    else
      print -r '{"type":"result","is_error":false,"result":"{\\"reply\\":\\"Hi, I am Converse App Support.\\",\\"attention\\":\\"\\"}"}'
    fi
    """.write(to: fakeCLI, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
    journey.entries[journey.entries.firstIndex { $0.engine == "claude" }!].command = ProviderCommand.quote(fakeCLI.path)
    var opened: [URL] = []
    journey.loginFileOpener = { file in
        opened.append(file)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = [file.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
    }
    let journeyPanes = Workspace(), journeyWindow = WindowState(workspace: journeyPanes)
    journeyGuide.place = { journeyPanes.assign($0.id, to: journeyWindow.id, pane: $1) }
    journeyGuide.choose("claude")
    let journeySupport = journeyGuide.support!
    journeyPanes.assign(journeySupport.id, to: journeyWindow.id, pane: 1)
    check(journeyPanes.placements.count == 1, "Journey: only App Support is up before sign-in")
    check(journeySupport.draft == "/login", "Journey: /login is prefilled")
    journey.submit(journeySupport)
    check(opened.count == 1 && (try? String(contentsOf: opened[0], encoding: .utf8)).map { $0.contains("auth") && $0.contains("login") && $0.contains(fakeCLI.lastPathComponent) } == true, "Return on /login opens the chosen provider's own login (claude auth login)")
    spin(20) { journeyGuide.stage == "done" }
    check(FileManager.default.fileExists(atPath: root.appendingPathComponent("login-ran").path) && journeyGuide.stage == "done", "Journey: provider login finished and one model response verified the connection")
    check(AgentModels.parse(journeySupport.agent?.model ?? "")?.engine == "claude" && AgentModels.parse(journeySupport.agent?.model ?? "")?.account == "claude-default" && journeySupport.supportTeachingVersion == AppSupport.version, "Journey: App Support becomes a taught agent on the same Claude login")
    check(journey.preferredLogin(engine: "claude")?.id == journeyGuide.coding?.entry.accountID, "Journey: new sessions keep using the login the coding session uses")
    spin(20) { !journeySupport.busy && journeySupport.pending.isEmpty }
    check(journeyPanes.pane(for: journeySupport.id, in: journeyWindow.id) == 1 && journeyPanes.pane(for: journeyGuide.coding!.id, in: journeyWindow.id) == 2 && journeyPanes.placements.count == 2, "Journey: after sign-in App Support is in pane 1 and Claude Coding in pane 2")
    check(journeySupport.displayedMessages.first.map { $0.role == "notice" && $0.text == FirstRunText.supportHelp } == true && journeySupport.displayedMessages.contains { $0.role == "assistant" && $0.text.contains("Converse App Support") }, "Journey: App Support shows the help message, then its reply")
    check(FirstRunText.supportHelp.hasPrefix("You can ask me to set up your agent, change options in the app, or just ask me about the weather!") && FirstRunText.supportHelp.hasSuffix("Those \"1 2 3\" icons on the left can be used to assign these sessions (including me) to the first, second and third panes."), "Help message uses Richard's wording")
    check(!journeySupport.messages.contains { $0.role == "user" && $0.text.contains(FirstRunText.supportHelp) } && !AgentPromptContext.conversation(journeySupport.messages, excluding: UUID()).contains { $0["text"] == FirstRunText.supportHelp }, "Journey: the help message is never model input")
    check(!journeySupport.displayedMessages.contains { $0.text.contains("[Converse switchboard instructions]") || $0.text.contains(AppSupport.connectionReply) } && journeySupport.messages.contains { $0.text.contains("[Converse switchboard instructions]") }, "Journey: login check and teaching are hidden from view but retained")
    journeyGuide.dismiss()
    check(!journeyGuide.active && withExtendedLifetime(Store(folder: journey.folder)) { $0.firstRun.stage == "dismissed" }, "The finished first-run bar can be hidden for good")

    renderFirstRun(root: root, check: check)
}

/// Offscreen PNGs of the App Support welcome in each state (no screen capture).
@MainActor func renderFirstRun(root: URL, check: (Bool, String) -> Void) {
    let environment = ProcessInfo.processInfo.environment
    guard let target = environment["CONVERSE_NUX_RENDERS"] ?? environment["CONVERSE_NUX4_RENDERS"] else { return }
    let output = URL(fileURLWithPath: target)
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    func save<V: View>(_ view: V, _ name: String, width: CGFloat = 900, height: CGFloat) -> Bool {
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.close()
        return (try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))) != nil
    }
    var states: [(String, FirstRunGuide, Store, ParkingLotLibrary)] = []
    for (name, engine, cli, key) in [("1-choose", nil, ["muse", "codex", "claude"], false), ("2-choose-codex-missing", nil, ["muse", "claude"], false),
                                     ("3-login-claude", "claude", ["muse", "codex", "claude"], false), ("4-login-muse-no-key", "muse", ["muse", "codex", "claude"], false),
                                     ("5-login-muse-key-saved", "muse", ["muse", "codex", "claude"], true), ("6-decide-later", "later", ["muse", "codex", "claude"], false),
                                     ("7-done", "done", ["muse", "codex", "claude"], false)] as [(String, String?, [String], Bool)] {
        let folder = root.appendingPathComponent("render-" + name)
        let store = Store(folder: folder)
        store.accounts = ["muse", "codex", "claude"].map { AccountProfile(id: $0 + "-default", name: AssistantFamily.name($0), engine: $0, directory: folder.appendingPathComponent("Logins/" + $0).path, useDefaultStore: false) }
        for index in store.entries.indices { store.entries[index].command = "/usr/bin/true" }
        let guide = store.firstRun, library = ParkingLotLibrary(folder: folder)
        guide.cliCheck = { cli.contains($0.engine) }; guide.metaKeySaved = { key }; guide.place = { _, _ in }
        _ = guide.seedIfNeeded(library: library, order: SidebarOrder(folder: folder))
        guide.checkCLIs()
        let deadline = Date().addingTimeInterval(5)
        while guide.cli.values.contains(.checking) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        if engine == "later" { guide.decideLater() }
        else if engine == "done" {
            // As send() shows the hand-off: hidden request, cleared display, help notice, reply.
            guide.choose("claude"); guide.connected(guide.support!)
            let support = guide.support!, handoff = support.pending.removeFirst(); support.pending.removeAll(); support.draft = ""
            support.messages.append(Message(role: "user", text: handoff.text)); store.clearSessionDisplay(support)
            support.messages.append(Message(role: "notice", text: handoff.displayNotice ?? ""))
            support.messages.append(Message(role: "assistant", text: AppSupport.closingInvitation))
        }
        else if let engine { guide.choose(engine) }
        states.append((name, guide, store, library))
    }
    var saved = 0
    for (name, guide, store, _) in states {
        if save(Conversation(session: guide.support!, store: store), name, height: 640) { saved += 1 }
    }
    if let done = states.last {
        if save(Conversation(session: done.1.coding!, store: done.2), "8-coding-welcome", height: 420) { saved += 1 }
        if save(Conversation(session: done.1.agent!, store: done.2), "9-agent-welcome", height: 420) { saved += 1 }
        // Panes 1 and 2 as the window shows them after sign-in (sidebar omitted).
        let panes = HStack(spacing: 0) { Conversation(session: done.1.support!, store: done.2); Divider(); Conversation(session: done.1.coding!, store: done.2) }
        if save(panes, "10-signed-in-two-panes", width: 1400, height: 640) { saved += 1 }
        if let lot = done.3.lot(done.1.record!.lotID), save(ParkingLotView(lot: lot, workspace: Workspace(), pane: 3), "11-starter-lot", height: 520) { saved += 1 }
    }
    // Sidebar rows for App Support, Coding and the starter agent: before a choice, after it, after sign-in.
    for (name, index) in [("12-sidebar-before-choice", 0), ("13-sidebar-after-choice", 2), ("14-sidebar-signed-in", states.count - 1)] where states.indices.contains(index) {
        let guide = states[index].1, workspace = Workspace(), window = WindowState(workspace: workspace)
        let rows = VStack(alignment: .leading, spacing: 4) {
            ForEach([guide.support, guide.coding, guide.agent].compactMap { $0 }, id: \.id) { SidebarSession(session: $0, workspace: workspace, state: window) }
            Spacer(minLength: 0)
        }.padding(10).background(Color(nsColor: .windowBackgroundColor))
        if save(rows, name, width: 300, height: 130) { saved += 1 }
    }
    check(saved == states.count + 7, "Saved \(saved) offscreen first-run renders to " + output.path)
}
