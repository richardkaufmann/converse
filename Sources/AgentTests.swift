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
    let agent = store.createAgent(); agent.queuePaused = true
    let recipient = store.create(Entry(name: "Fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")); recipient.queuePaused = true
    let blocked = store.create(recipient.entry); blocked.queuePaused = true
    agent.agent?.watchedSessions = [recipient.id]
    let runtime = AgentRuntime()
    runtime.deliver(AgentReply(reply: "report", tell: [.init(to: recipient.id, text: "Please review"), .init(to: blocked.id, text: "Forbidden")]), from: agent, store: store)
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

    // Real engine path, fake HTTP. No credentials, external requests or billable calls.
    runtime.keyReader = { _ in "isolated-test-key" }
    var requests: [URLRequest] = []
    runtime.api.request = { request in
        requests.append(request)
        let path = request.url!.path
        var object: Any = [:]
        if path == "/v1/responses" {
            object = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "{\"reply\":\"Measured progress\",\"attention\":\"Need a success criterion\",\"tell\":[]}"]]]]]
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
    check(!archive.contains("isolated-test-key") && !AgentWidgetExport.html(agent).contains("isolated-test-key"), "Agent credentials never enter persisted sessions or widget exports")
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
        (Data("{\"output\":[],\"status\":\"incomplete\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    agent.busy = true; let failedID = UUID(); agent.messages.append(Message(id: failedID, role: "assistant", text: "")); runtime.run(agent, store: store, responseID: failedID)
    let failedDeadline = Date().addingTimeInterval(8)
    while agent.busy && Date() < failedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!agent.busy && agent.agent?.enabled == false && agent.agent?.attention.contains("No actions applied") == true, "Incomplete model responses cannot apply actions and pause the agent loop")
}
