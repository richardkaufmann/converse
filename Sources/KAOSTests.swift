import AppKit
import SwiftUI

@MainActor func kaosSelfTests(_ check: (Bool, String) -> Void) {
    func wait(_ action: @escaping @MainActor () async throws -> Void) -> String? {
        var done = false; var failure: String?
        Task { @MainActor in do { try await action() } catch { failure = error.localizedDescription }; done = true }
        let deadline = Date().addingTimeInterval(8)
        while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return done ? failure : "Fixture timed out"
    }
    // Synthetic schema with deliberately tiny limits: proves runtime schema
    // use rather than embedding the production bridge's limits or document.
    let string: [String: Any] = ["type": "string"]
    func post(_ body: [String: Any]) -> [String: Any] { ["requestBody": ["content": ["application/json": ["schema": body]]]] }
    let confirmation: [String: Any] = ["type": "object", "required": ["confirmToken"], "properties": ["confirmToken": string]]
    let schema: [String: Any] = ["info": ["title": "Fixture bridge", "version": "test"], "paths": [
        "/identity": ["get": [:]],
        "/v1/ask": ["post": post(["type": "object", "required": ["question"], "properties": ["question": ["type": "string", "maxLength": 3], "context": ["type": "string", "maxLength": 4]]])],
        "/v1/jobs/prepare": ["post": post(["type": "object", "required": ["world"], "properties": ["world": string, "autoTuneLoops": ["type": "integer", "minimum": 0, "maximum": 2]]])],
        "/v1/scenario/propose": ["post": post(["type": "object", "required": ["edits"], "properties": ["edits": ["type": "array", "maxItems": 1, "items": ["type": "object", "required": ["path", "value"], "properties": ["path": string, "value": [:]]]]]])],
        "/v1/jobs/{jobId}/confirm": ["post": post(confirmation)], "/v1/scenario/{proposalId}/apply": ["post": post(confirmation)],
        "/v1/jobs/{jobId}": ["get": [:]], "/v1/jobs/{jobId}/cancel": ["post": [:]]
    ]]
    let client = KAOSClient(); client.token = { "fixture-bearer" }
    var requests: [URLRequest] = []; var status = 200; var refuse = false
    client.request = { req in
        requests.append(req)
        let path = req.url!.path
        var value: [String: Any] = ["ok": true]
        if path == "/health" { value["service"] = "muse-bridge" }
        if path == "/openapi.json" { value = schema }
        if path == "/identity" { value["lane"] = ["name": "Fixture", "scenarioRevision": 7] }
        if path == "/v1/ask" { value["answer"] = "answer"; value["readOnly"] = true }
        if path.hasSuffix("prepare") || path.hasSuffix("propose") { value.merge(["jobId": "job-1", "proposalId": "edit-1", "summary": "EXACT REVIEW SUMMARY", "confirmToken": "fixture-confirm", "lane": ["name": "Fixture", "scenarioRevision": 7]]) { _, new in new } }
        if path == "/v1/jobs/job-1" { value["job"] = ["state": "done"] }
        if refuse { value = ["ok": false, "error": "private error fixture-bearer"] }
        return (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    var identity = ""
    check(wait { identity = try await client.connect() } == nil && identity.contains("Fixture · r7") && identity.contains("test"), "KAOS connection proves bridge sequence and displays lane provenance plus live schema version")
    check(requests.map { $0.url!.path } == ["/health", "/openapi.json", "/identity"] && requests.prefix(2).allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil } && requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-bearer", "KAOS proves public health/schema before bearer identity without consuming inbox")
    requests = []
    let limit = wait { _ = try await client.ask("long", context: "") }
    check(limit?.contains("3 characters") == true && requests.isEmpty, "KAOS enforces live question limit before sending")
    check(wait { _ = try await client.ask("ok", context: "12345") }?.contains("4 characters") == true && requests.isEmpty, "KAOS enforces live context limit")
    check(wait { _ = try await client.ask("ok", context: "") } == nil && requests.count == 1 && requests[0].url?.host == "127.0.0.1" && requests[0].url?.port == 4691 && requests[0].timeoutInterval == 660, "KAOS ask uses authenticated loopback and generous asynchronous timeout")
    let body = requests.last?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(body?["question"] as? String == "ok" && body?["request_id"] as? String != nil && body?["context"] as? String == "", "KAOS asks send only explicit question/context plus correlation ID")
    let model = KAOSModel(client: client); model.connected = true; model.input = "{\"world\":\"fixture\",\"autoTuneLoops\":0}"
    requests = []
    check(wait { await model.prepare() } == nil && model.prepared?.summary == "EXACT REVIEW SUMMARY" && requests.map { $0.url!.path } == ["/v1/jobs/prepare"], "KAOS prepare stops before confirmation and preserves exact summary for human review")
    _ = wait { await model.approve(id: "wrong-review") }
    check(requests.count == 1 && model.prepared != nil, "KAOS approval must match the currently reviewed proposal")
    _ = wait { await model.approve(id: "job-1") }
    _ = wait { await model.approve(id: "job-1") }
    check(requests.filter { $0.url!.path.hasSuffix("/confirm") }.count == 1 && model.prepared == nil, "KAOS explicit approval confirms once and consumes local proposal before awaiting")
    let confirm = requests.first { $0.url!.path.hasSuffix("/confirm") }?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(confirm?["confirmToken"] as? String == "fixture-confirm", "KAOS approval uses the exact bridge-issued confirmation token")
    model.stopWatching()
    _ = wait { await model.cancelJob() }
    check(requests.contains { $0.url!.path == "/v1/jobs/job-1/cancel" && $0.httpMethod == "POST" }, "KAOS job cancellation uses bridge cancel endpoint")
    model.scenario = true; model.input = "{\"edits\":[{\"path\":\"fixture.value\",\"value\":3}]}"
    _ = wait { await model.prepare() }
    check(model.prepared?.kind == .scenario && requests.last?.url?.path == "/v1/scenario/propose", "KAOS scenario edits use separate propose flow")
    _ = wait { await model.discard() }
    check(!requests.contains { $0.url!.path.hasSuffix("/apply") }, "Dismissing a scenario proposal never applies edits")
    _ = wait { await model.prepare() }; _ = wait { await model.approve(id: "edit-1") }
    check(requests.filter { $0.url!.path == "/v1/scenario/edit-1/apply" }.count == 1, "KAOS scenario changes apply only after explicit matching approval")
    requests = []
    check(wait { _ = try await client.prepare(scenario: false, body: ["world": "fixture", "autoTuneLoops": 3]) } != nil && requests.isEmpty, "KAOS validates live run parameter range before prepare")
    refuse = true; status = 401
    let auth = wait { _ = try await client.ask("ok", context: "") }
    check(auth?.contains("authorization refused") == true && auth?.contains("fixture-bearer") == false, "KAOS auth failures never expose response bodies or bearer tokens")
    refuse = false; status = 200
    let display = KAOSClient.displayJSON(["confirmToken": "must-hide", "result": ["secret": "must-hide", "summary": "safe"]])
    check(!display.contains("must-hide") && display.contains("safe"), "KAOS status rendering strips confirmation and credential fields recursively")
    check(wait { _ = try await client.job("../identity") } != nil, "KAOS refuses job path traversal before request")
    let requestCount = requests.count
    check(wait { _ = try await client.image(URL(string: "https://attacker.test/v1/images/a")!) } != nil && requests.count == requestCount, "KAOS refuses images from unrecognized origins before loading any Access credentials")
    check(requests.allSatisfy { $0.url?.port == 4691 && $0.url?.path != "/v1/inbox" }, "KAOS client never uses the unauthenticated app port or consumed-on-read inbox")
    let missing = KAOSClient(); missing.token = { throw KAOSFailure(message: "missing fixture token") }
    var authenticated = false
    missing.request = { req in
        if req.value(forHTTPHeaderField: "Authorization") != nil { authenticated = true }
        let object: [String: Any] = req.url!.path == "/openapi.json" ? schema : ["ok": true, "service": "muse-bridge"]
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    check(wait { _ = try await missing.connect() } != nil && !authenticated && missing.schema == nil, "Missing KAOS token fails closed without enabling UI operations")
    var jollySends: [String] = []
    model.outbox = { text in jollySends.append(text); return "Left in outbox" }
    model.jollyMessage = "Explicit fixture message"
    check(jollySends.isEmpty, "Opening KAOS client never sends Jolly a message automatically")
    _ = wait { await model.leaveForJolly() }
    check(jollySends == ["Explicit fixture message"] && model.jollyMessage.isEmpty, "Explicit Jolly action sends exact text once and clears only the confirmed draft")
    model.jollyMessage = String(repeating: "x", count: 501); _ = wait { await model.leaveForJolly() }
    check(jollySends.count == 1 && model.jollyMessage.count == 501, "Overlong Jolly messages are retained without sending")
    let originalRequest = client.request
    var held: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    var firstFinished = false
    client.request = { req in try await withCheckedThrowingContinuation { held = $0 } }
    Task { @MainActor in _ = try? await client.ask("one", context: ""); firstFinished = true }
    let busyDeadline = Date().addingTimeInterval(2)
    while held == nil && Date() < busyDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(wait { _ = try await client.ask("two", context: "") } == "Lane busy.", "Concurrent KAOS asks fail immediately with exact Lane busy phrase")
    held?.resume(returning: (try! JSONSerialization.data(withJSONObject: ["ok": true, "answer": "done", "readOnly": true]), HTTPURLResponse(url: KAOSClient.base, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    let finishDeadline = Date().addingTimeInterval(2)
    while !firstFinished && Date() < finishDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(firstFinished && !client.asking, "KAOS asynchronous ask releases its single-flight slot after completion")
    client.request = originalRequest
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("muse-kaos/app")
    if FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(".venv/bin/python").path) {
        do {
            let data = FileManager.default.temporaryDirectory.appendingPathComponent("converse-jolly-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: data) }
            let note = try JollyOutbox.send("Converse isolated fixture", root: root, testData: data)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: data.appendingPathComponent("jolly_outbox.json"))) as? [String: Any]
            let message = (saved?["messages"] as? [[String: Any]])?.last
            check(note.contains("not a push") && message?["text"] as? String == "Converse isolated fixture" && message?["read"] as? Bool == false && message?["id"] as? Int == 1, "Jolly uses actual existing KAOS tool with shared outbox format in isolated data, without phone delivery")
        } catch { check(false, "Existing Jolly outbox isolated integration: " + error.localizedDescription) }
    }
    let bridgeHTTP = KAOSHTTP(); var redirect: URLRequest? = URLRequest(url: URL(string: "https://attacker.test")!)
    KAOSRedirectGuard().urlSession(bridgeHTTP.session, task: bridgeHTTP.session.dataTask(with: KAOSClient.base), willPerformHTTPRedirection: HTTPURLResponse(url: KAOSClient.base, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: redirect!) { redirect = $0 }
    check(redirect == nil, "KAOS HTTP refuses redirects so bearer and Access headers cannot leak to another origin")
    weak var unusedHTTP: KAOSHTTP?
    weak var usedHTTP: KAOSHTTP?
    do { let owner = KAOSHTTP(); unusedHTTP = owner }
    do { let owner = KAOSHTTP(); usedHTTP = owner; _ = owner.session }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    check(unusedHTTP == nil && usedHTTP == nil, "KAOS HTTP cleanup never creates a session during deinit or retains its owner as the delegate")
    if ProcessInfo.processInfo.environment["CONVERSE_KAOS_LIVE_IDENTITY"] == "1" {
        let live = KAOSClient(); var liveIdentity = ""
        check(wait { liveIdentity = try await live.connect() } == nil && !liveIdentity.isEmpty, "Live signed Mac client reaches loopback health/schema/authenticated identity without asking or mutating")
    }
    if let path = ProcessInfo.processInfo.environment["CONVERSE_KAOS_PREVIEW_DIR"] {
        model.connection = "Sample lane · r7 · Ask KAOS"; model.connected = true
        model.conversation.messages = [Message(role: "user", text: "Which lane is answering?"), Message(role: "assistant", text: "This read-only answer comes from the KAOS lane shown above.\n\nYou can ask questions here without changing the scenario.")]
        model.conversation.draft = "Ask a read-only question…"
        let host = NSHostingView(rootView: KAOSView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.frame = window.contentView!.bounds; host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = URL(fileURLWithPath: path).appendingPathComponent("Jolly-KAOS-Mac-preview.png")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
    }

}
