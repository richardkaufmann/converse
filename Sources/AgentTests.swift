import AppKit
import Foundation

@MainActor func agentSelfTests(_ check: (Bool, String) -> Void) {
    let now = Date(timeIntervalSince1970: 1_000)
    var config = AgentConfig(); config.enabled = true; config.remainingRuns = 1; config.nextRunAt = now
    check(config.reserveRun(at: now) && config.remainingRuns == 0 && !config.enabled && !config.reserveRun(at: now), "Agent reserves its last scheduled run once and stops at the persisted cap")
    check(AgentRepoSnapshot.validRepository("owner/repo-name") && !AgentRepoSnapshot.validRepository("../repo") && !AgentRepoSnapshot.validRepository("owner/repo?token=x"), "Agent repository paths cannot inject queries or escape their namespace")
    let old = AgentRepoSnapshot(repository: "owner/repo", openBugs: 2)
    check(AgentRepoSnapshot(repository: "owner/repo", openBugs: 3).mood(previous: old) == "urgent" && AgentRepoSnapshot(repository: "owner/repo", openBugs: 0).mood(previous: old) == "peaceful", "Widget mood follows measured bug changes")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-agents-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root)
    for title in ["Converse Development", "MuseConverse"] {
        let suggestion = store.create(Entry(name: "Fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")); suggestion.title = title
    }
    let agent = store.createAgent(); agent.queuePaused = true
    check(agent.agent?.watchedSessions.isEmpty == true, "New agents have no transcript scope until the user explicitly selects sessions")
    let recipient = store.create(Entry(name: "Fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")); recipient.queuePaused = true
    let blocked = store.create(recipient.entry); blocked.queuePaused = true
    agent.agent?.watchedSessions = [recipient.id]
    var secretWrites = 0, secretDeletes = 0
    do {
        try AgentSecrets.update("fixture", value: "", remove: false, write: { _, _ in secretWrites += 1 }, delete: { _ in secretDeletes += 1 })
        try AgentSecrets.update("fixture", value: "new test value", remove: false, write: { _, _ in secretWrites += 1 }, delete: { _ in secretDeletes += 1 })
        try AgentSecrets.update("fixture", value: "", remove: true, write: { _, _ in secretWrites += 1 }, delete: { _ in secretDeletes += 1 })
        check(secretWrites == 1 && secretDeletes == 1, "Agent credentials support explicit removal while blank fields preserve saved values")
        do { try AgentSecrets.update("fixture", value: "replacement", remove: true, write: { _, _ in secretWrites += 1 }, delete: { _ in secretDeletes += 1 }); check(false, "Conflicting secret edit rejected") }
        catch { check(secretWrites == 1 && secretDeletes == 1, "Conflicting credential replacement/removal changes nothing") }
    } catch { check(false, "Credential edit policy: " + error.localizedDescription) }
    let runtime = AgentRuntime()
    runtime.deliver(AgentReply(reply: "report", tell: [.init(to: recipient.id.uuidString, text: "Please review"), .init(to: blocked.id.uuidString, text: "Forbidden")]), from: agent, store: store)
    check(recipient.pending.count == 1 && blocked.pending.isEmpty && recipient.pending[0].text.contains(agent.id.uuidString), "Agent messages are visibly attributed and restricted to selected sessions")
    agent.switchboardTurnStart = agent.messages.count
    agent.messages.append(Message(role: "assistant", text: "```converse\n{\"command\":\"tell\",\"to\":\"" + blocked.id.uuidString + "\",\"text\":\"Forbidden through alternate protocol\"}\n```"))
    store.processSwitchboard(agent)
    check(blocked.pending.isEmpty && !store.switchboardDirectory(for: agent).contains(blocked.id.uuidString), "Agent scope also fences normal switchboard commands and directory lookup")
    agent.agent?.widgetSummary = "<script>alert('x')</script>"
    check(AgentWidgetExport.html(agent).contains("&lt;script&gt;") && !AgentWidgetExport.html(agent).contains("<script>"), "Exported agent widget escapes model text and disables scripts")
    agent.agent?.enabled = true; agent.agent?.remainingRuns = 2; agent.agent?.nextRunAt = now
    agent.draft = "User's unfinished thought"
    runtime.tick(store: store, now: now)
    check(agent.pending.isEmpty && agent.agent?.remainingRuns == 2, "Paused agent queues prevent scheduled wakeups")
    agent.queuePaused = false; agent.busy = true; runtime.tick(store: store, now: now)
    check(agent.agent?.remainingRuns == 2, "Agent scheduler never overlaps a running turn")
    agent.busy = false; agent.queuePaused = true; store.save()
    let reloaded = Store(folder: root).sessions.first { $0.id == agent.id }
    check(reloaded?.agent?.watchedSessions == [recipient.id] && reloaded?.draft == "User's unfinished thought", "Agent settings and editable draft survive archive reload")

    let stimulated = store.createAgent(title: "External stimulus fixture")
    stimulated.agent?.fileTriggers = true; stimulated.agent?.remainingRuns = 1
    stimulated.draft = "A separate human draft"
    var starts = 0
    store.startAgentRun = { session, _ in starts += 1; session.busy = true }
    let inbox = root.appendingPathComponent("Agents/" + stimulated.id.uuidString + "/Inbox")
    try! FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let event = AgentRuntime.FileEvent(id: UUID(), text: "A test result arrived; ask for evidence.")
    let eventFile = inbox.appendingPathComponent("event.json")
    try! JSONEncoder().encode(event).write(to: eventFile)
    runtime.ingestFileEvents(store: store)
    check(stimulated.pending.count == 1 && stimulated.agent?.processedEvents == [event.id] && !FileManager.default.fileExists(atPath: eventFile.path), "Opt-in file events persist provenance and deduplication before consuming the input file")
    store.runNext(stimulated)
    check(starts == 1 && stimulated.agent?.remainingRuns == 0 && stimulated.draft == "A separate human draft", "External stimuli reserve a persisted run budget before starting and preserve the human draft")
    stimulated.busy = false
    try! JSONEncoder().encode(event).write(to: eventFile)
    runtime.ingestFileEvents(store: store)
    check(stimulated.pending.isEmpty && starts == 1, "Repeated external event IDs do not enqueue or start duplicate runs")
    store.enqueueSwitchboard(stimulated, text: "Another agent asks for work", hop: 1)
    store.runNext(stimulated)
    check(stimulated.queuePaused && stimulated.pending.count == 1 && starts == 1 && stimulated.agent?.attention.contains("budget exhausted") == true, "Incoming agent tells cannot bypass the autonomous turn allowance")
    stimulated.agent?.fileTriggers = false; stimulated.pending = []
    store.startAgentRun = nil
    let migrated = AgentConfig(watchedSessions: [recipient.id])
    let localHome = String(repeating: "a", count: 64), otherHome = String(repeating: "b", count: 64)
    check(migrated.allows(global: DeviceGlobalID(home: localHome, session: recipient.id).string, home: localHome)
        && !migrated.allows(global: DeviceGlobalID(home: otherHome, session: recipient.id).string, home: localHome), "Legacy agent scope migrates only within its original home, never a same-UUID remote session")

    var revisionFixture = AgentConfig()
    let staleSettings = revisionFixture.wire(home: localHome)
    revisionFixture.settingsChanged(); revisionFixture.remainingRuns -= 1
    do { try revisionFixture.apply(staleSettings); check(false, "Stale settings must reject") }
    catch { check(revisionFixture.remainingRuns == 19, "Saving a stale setup form cannot restore an autonomous run already spent") }

    // Real engine path, fake HTTP. No credentials, external requests or billable calls.
    runtime.keyReader = { _ in "isolated-test-key" }
    var requests: [URLRequest] = []
    recipient.messages.append(Message(role: "assistant", text: "private scope canary"))
    runtime.api.request = { request in
        requests.append(request)
        let path = request.url!.path
        if path != "/v1/responses" { agent.agent?.watchedSessions = [] } // Revoke scope while repository requests are in flight.
        var object: Any = [:]
        if path == "/v1/responses" {
            object = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "{\"reply\":\"Measured progress\",\"attention\":\"Need a success criterion\",\"tell\":[],\"memory\":\"Keep release acceptance criteria\"}"]]]]]
        } else if path.contains("search/issues") { object = ["total_count": 0, "incomplete_results": false] }
        else if path.hasSuffix("/releases") || path.hasSuffix("/comments") { object = [] }
        else if path.hasSuffix("/views") { object = ["uniques": 7] }
        else { object = ["stargazers_count": 12] }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    agent.agent?.generateArt = false; agent.agent?.enabled = false; agent.pending = []; agent.queuePaused = true
    agent.messages.append(Message(role: "user", text: "How is the project doing?"))
    let responseID = UUID(); agent.messages.append(Message(id: responseID, role: "assistant", text: "")); agent.busy = true
    runtime.run(agent, store: store, responseID: responseID)
    let deadline = Date().addingTimeInterval(8)
    while agent.busy && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!agent.busy && agent.messages.contains { $0.text == "Measured progress" } && agent.agent?.snapshot?.stars == 12 && agent.agent?.snapshot?.visitors14d == 7 && agent.needsApproval, "Direct API agent completes a measured report and raises yellow attention")
    check(FileManager.default.fileExists(atPath: root.appendingPathComponent("Agents/" + agent.id.uuidString + "/widget.html").path) && requests.contains { $0.url?.path == "/v1/responses" }, "Agent exports its scoreboard after the model response")
    let archive = (try? String(contentsOf: root.appendingPathComponent("sessions.json"), encoding: .utf8)) ?? ""
    check(Store(folder: root).sessions.first(where: { $0.id == agent.id })?.agent?.workingMemory == "Keep release acceptance criteria", "Agent's learned human criteria survive archive reload beyond the recent conversation window")
    check(!archive.contains("isolated-test-key") && !AgentWidgetExport.html(agent).contains("isolated-test-key"), "Agent credentials never enter persisted sessions or widget exports")
    let modelInput = requests.first { $0.url?.path == "/v1/responses" }?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check(!modelInput.contains("private scope canary"), "Scope revoked during repository collection is excluded from the next model request")

    let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
    runtime.api.request = { request in
        let image = request.url?.path == "/v1/images/generations"
        let object: [String: Any] = image ? ["data": [["b64_json": png.base64EncodedString()]]] : ["stargazers_count": 1]
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    var art: Data?; var artDone = false
    Task { @MainActor in art = try? await runtime.api.art(prompt: "Test background", key: "isolated-test-key"); artDone = true }
    let artDeadline = Date().addingTimeInterval(3)
    while !artDone && Date() < artDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(art != nil && NSBitmapImageRep(data: art!) != nil, "Muse Image response bytes become a validated portable PNG")
    runtime.api.request = { request in
        let object: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "Not a structured agent action"]]]]]
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    agent.busy = true; let malformedID = UUID(); agent.messages.append(Message(id: malformedID, role: "assistant", text: "")); runtime.run(agent, store: store, responseID: malformedID)
    let malformedDeadline = Date().addingTimeInterval(8)
    while agent.busy && Date() < malformedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!agent.busy && agent.agent?.enabled == false && agent.agent?.attention.contains("invalid action format") == true, "Malformed completed agent output pauses the loop without applying actions")
    runtime.api.request = { request in
        (Data("{\"output\":[],\"status\":\"incomplete\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    agent.busy = true; let failedID = UUID(); agent.messages.append(Message(id: failedID, role: "assistant", text: "")); runtime.run(agent, store: store, responseID: failedID)
    let failedDeadline = Date().addingTimeInterval(8)
    while agent.busy && Date() < failedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!agent.busy && agent.agent?.enabled == false && agent.agent?.attention.contains("No actions applied") == true, "Incomplete model responses cannot apply actions and pause the agent loop")
}
