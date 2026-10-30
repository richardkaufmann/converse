import Foundation

@MainActor func agentDiscordRouterSelfTests(_ check: (Bool, String) -> Void) {
    func wait(_ operation: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in await operation(); done = true }
        let deadline = Date().addingTimeInterval(8)
        while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(done, "Discord routing fixture completes without live services")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-discord-router-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root), runtime = AgentRuntime()
    let a = store.createAgent(title: "Steward"), b = store.createAgent(title: "Meta Stock Agent")
    let now = Date(), since = Date().addingTimeInterval(-30)
    for s in [a, b] {
        s.agent?.discordMentions = true; s.agent?.discordChannelID = "42"; s.agent?.discordMentionSince = since
        s.agent?.turnLimit = 5; s.agent?.generateArt = false; s.agent?.webSearch = false
    }
    a.agent?.discordDefault = true
    check(AgentDiscordRouter.resolve("What is new?", sessions: [a, b]).0 === a, "Unqualified Discord mention selects only the configured channel default")
    check(AgentDiscordRouter.resolve("ask Meta Stock Agent price?", sessions: [a, b]).0 === b && AgentDiscordRouter.resolve("Meta Stock Agent: price?", sessions: [a, b]).1 == "price?", "Explicit exact agent names route without model guessing")
    check(AgentDiscordRouter.resolve("ask Missing Agent something", sessions: [a, b]).0 == nil, "Unknown explicit Discord target never falls back to default")
    let duplicate = store.createAgent(title: "Meta Stock Agent")
    check(AgentDiscordRouter.resolve("Meta Stock Agent: question", sessions: [a, b, duplicate]).0 == nil, "Duplicate agent names require disambiguation rather than broadcast")
    b.agent?.discordDefault = true
    check(AgentDiscordRouter.resolve("hello", sessions: [a, b]).0 == nil, "Ambiguous Discord defaults do not broadcast")
    b.agent?.discordDefault = false
    var message = AgentDiscordMessage(id: "1", author: "Tester", content: "<@7> hello", timestamp: "", automated: false, attachmentNames: [], authorID: "8", mentions: ["7"])
    check(AgentDiscordRouter.question(message, botID: "7") == "hello", "Only a real direct bot mention becomes a request")
    message.automated = true
    check(AgentDiscordRouter.question(message, botID: "7") == nil, "Bot and webhook mentions cannot create reply loops")
    message.automated = false; message.mentions = []
    check(AgentDiscordRouter.question(message, botID: "7") == nil, "Spoofed textual mention without Discord mention metadata is ignored")
    message.mentions = ["7"]; message.content = "quoted <@7> hello"
    check(AgentDiscordRouter.question(message, botID: "7") == nil, "Incidental mention inside channel discussion does not wake an agent")

    let id1 = AgentDiscordRouter.snowflake(at: now.addingTimeInterval(-2))
    let id2 = AgentDiscordRouter.snowflake(at: now.addingTimeInterval(-1))
    var rows: [[String: Any]] = []
    func row(_ id: String, _ question: String, bot: Bool = false) -> [String: Any] {
        ["id": id, "channel_id": "42", "content": "<@7> " + question, "author": ["id": "8", "username": "Tester", "bot": bot], "mentions": [["id": "7"]]]
    }
    var posts: [[String: Any]] = [], reads = 0, models = 0, modelInput = "", failPost = false
    runtime.keyReader = { _ in "synthetic-discord-fixture" }
    runtime.api.request = { request in
        var object: Any
        if request.url?.host == "discord.com" {
            if request.url?.path.hasSuffix("users/@me") == true { object = ["id": "7", "bot": true] }
            else if request.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                posts.append(body)
                if failPost { throw NSError(domain: "fixture-lost-receipt", code: 1) }
                object = ["id": "900", "channel_id": "42"]
            } else {
                reads += 1
                let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "after" })?.value ?? "0"
                object = rows.filter { AgentDiscord.newer($0["id"] as! String, than: after) }
            }
        } else {
            models += 1; modelInput = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let reply = "{\"reply\":\"Public fixture answer\",\"tell\":[{\"to\":\"" + b.id.uuidString + "\",\"text\":\"must not execute\"}],\"memory\":\"must not persist\",\"notifyDiscord\":\"must not repost\"}"
            object = ["status": "completed", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": reply]]]]]
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    a.busy = true; a.draft = "PRIVATE-DRAFT-CANARY"; a.attachments = ["/private/attachment"]
    a.agent?.workingMemory = "PRIVATE-MEMORY-CANARY"; a.agent?.objective = "PRIVATE-OBJECTIVE-CANARY"
    a.messages.append(Message(role: "assistant", text: "PRIVATE-TRANSCRIPT-CANARY"))
    a.agent?.watchedSessions = [b.id]
    rows = [row(id1, "question")]
    wait { await runtime.discordRouter.poll(store: store, runtime: runtime, now: now) }
    check(runtime.discordRouter.pendingRequests.count == 1 && runtime.discordRouter.pendingRequests[0].state == "queued" && a.busy && a.agent?.turnLimit == 5 && models == 0, "Busy Discord target queues durably without interruption or early budget spending")
    check(reads == 1, "N agents in one channel share one listener read")
    wait { await runtime.discordRouter.poll(store: store, runtime: runtime, now: now) }
    check(runtime.discordRouter.pendingRequests.count == 1, "Repeated polling cannot enqueue a duplicate Discord message")
    a.busy = false; a.queuePaused = true
    wait { await runtime.discordRouter.poll(store: store, runtime: runtime, now: now) }
    check(models == 0 && a.agent?.turnLimit == 5, "Discord respects the user's paused queue")
    a.queuePaused = false
    store.startAgentRun = { session, responseID in runtime.run(session, store: store, responseID: responseID) }
    wait { await runtime.discordRouter.poll(store: store, runtime: runtime, now: now) }
    let end = Date().addingTimeInterval(8)
    while a.busy && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(!a.busy && models == 1 && a.agent?.turnLimit == 5 && a.draft == "PRIVATE-DRAFT-CANARY" && a.attachments == ["/private/attachment"], "Queued mention runs once, preserves the per-activation limit and preserves editable draft and attachments")
    check(!modelInput.contains("PRIVATE-") && modelInput.contains("question") && b.pending.isEmpty && a.agent?.workingMemory == "PRIVATE-MEMORY-CANARY", "Public Discord turn excludes private evidence and cannot execute tell, memory or alert actions")
    wait { await runtime.discordRouter.poll(store: store, runtime: runtime, now: now) }
    check(posts.count == 1 && (posts.first?["message_reference"] as? [String: Any])?["message_id"] as? String == id1 && (posts.first?["allowed_mentions"] as? [String: Any])?["replied_user"] as? Bool == false && posts.first?["enforce_nonce"] as? Bool == true, "Discord result replies to its source message with mentions suppressed and nonce deduplication")
    let restarted = AgentRuntime(); restarted.api.request = runtime.api.request; restarted.keyReader = runtime.keyReader
    wait { await restarted.discordRouter.poll(store: store, runtime: restarted, now: now) }
    check(models == 1 && posts.count == 1, "Restart restores receipt and cursor without re-running or re-posting completed mentions")

    rows.append(row(id2, "ask Missing Agent hello")); failPost = true
    let lostReply = AgentRuntime(); lostReply.api.request = runtime.api.request; lostReply.keyReader = runtime.keyReader
    wait { await lostReply.discordRouter.poll(store: store, runtime: lostReply, now: now) }
    let postCount = posts.count
    wait { await lostReply.discordRouter.poll(store: store, runtime: lostReply, now: now) }
    let afterFailure = AgentRuntime(); afterFailure.api.request = runtime.api.request; afterFailure.keyReader = runtime.keyReader
    wait { await afterFailure.discordRouter.poll(store: store, runtime: afterFailure, now: now) }
    check(postCount == 2 && posts.count == 2 && models == 1, "Unconfirmed Discord POST is never automatically repeated across polling or restart")

    do {
        let restored = try JSONDecoder().decode(DiscordMentionJournal.self, from: Data(contentsOf: AgentDiscordRouter.file(store)))
        check(restored.cursors["42"] == id2 && restored.requests.contains(where: { $0.id == id1 && $0.receipt == "900" }), "Journal atomically retains message cursor and verified reply receipt")
        var interrupted = restored
        interrupted.requests.append(DiscordMentionRequest(id: "999", channel: "42", botID: "7", author: "Tester", question: "do not repeat", sessionID: a.id, receivedAt: now, state: "running"))
        try JSONEncoder().encode(interrupted).write(to: AgentDiscordRouter.file(store), options: .atomic)
        failPost = false
        let recovery = AgentRuntime(); recovery.api.request = runtime.api.request; recovery.keyReader = runtime.keyReader
        wait { await recovery.discordRouter.poll(store: store, runtime: recovery, now: now) }
        check(models == 1 && posts.last?["content"] as? String == "[Steward] Converse restarted during this request. It was not repeated; please send a new mention if you still need an answer.", "Interrupted model request reports uncertainty instead of replaying work")
    } catch { check(false, "Discord journal recovery fixture: " + error.localizedDescription) }
    // Durable queued requests are rechecked against scope, budget and age
    // immediately before dispatch, not merely at the time of ingestion.
    func queuedFixture(state: String = "queued", received: Date = now) throws {
        let journal = DiscordMentionJournal(botID: "7", cursors: ["42": id2], requests: [
            DiscordMentionRequest(id: "777", channel: "42", botID: "7", author: "Tester", question: "queued fixture", sessionID: a.id, receivedAt: received, state: state)
        ])
        try JSONEncoder().encode(journal).write(to: AgentDiscordRouter.file(store), options: .atomic)
    }
    do {
        try queuedFixture(); a.agent?.turnLimit = 0
        let budget = AgentRuntime(); budget.api.request = runtime.api.request; budget.keyReader = runtime.keyReader
        let beforeModels = models
        wait { await budget.discordRouter.poll(store: store, runtime: budget, now: now) }
        check(models == beforeModels && (posts.last?["content"] as? String)?.contains("invalid per-loop limit") == true, "Queued mention rechecks invalid activation limit before a model call")
        a.agent?.turnLimit = 3; a.agent?.discordMentionSince = now.addingTimeInterval(-900)
        try queuedFixture(received: now.addingTimeInterval(-601))
        let expiry = AgentRuntime(); expiry.api.request = runtime.api.request; expiry.keyReader = runtime.keyReader
        wait { await expiry.discordRouter.poll(store: store, runtime: expiry, now: now) }
        check(models == beforeModels && a.agent?.turnLimit == 3 && (posts.last?["content"] as? String)?.contains("expired") == true, "Stale queued mentions expire without spending a turn")
        try queuedFixture(); a.agent?.discordMentions = false
        let revoked = AgentRuntime(); revoked.api.request = runtime.api.request; revoked.keyReader = runtime.keyReader
        let beforePosts = posts.count
        wait { await revoked.discordRouter.poll(store: store, runtime: revoked, now: now) }
        check(models == beforeModels && posts.count == beforePosts && revoked.discordRouter.pendingRequests.first?.state == "done", "Disabling a target cancels queued mentions without posting to its former channel")
        a.agent?.discordMentions = true
        try queuedFixture()
        let resumed = AgentRuntime(); resumed.api.request = runtime.api.request; resumed.keyReader = runtime.keyReader
        store.startAgentRun = { session, responseID in resumed.run(session, store: store, responseID: responseID) }
        wait { await resumed.discordRouter.poll(store: store, runtime: resumed, now: now) }
        let end = Date().addingTimeInterval(8)
        while a.busy && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(models == beforeModels + 1 && a.agent?.turnLimit == 3, "An accepted queued mention survives restart and starts exactly once")
        resumed.prepareForQuit()
        let beforeReads = reads
        wait { await resumed.discordRouter.poll(store: store, runtime: resumed, now: now) }
        check(reads == beforeReads, "Quit stops the Discord listener before further network work")
        try Data("broken journal".utf8).write(to: AgentDiscordRouter.file(store), options: .atomic)
        let broken = AgentRuntime(); broken.api.request = runtime.api.request; broken.keyReader = runtime.keyReader
        wait { await broken.discordRouter.poll(store: store, runtime: broken, now: now) }
        check(reads == beforeReads && broken.discordRouter.status(for: a).contains("journal"), "Unreadable journal fails closed instead of resetting deduplication state")
    } catch { check(false, "Discord queued recovery fixture: " + error.localizedDescription) }
    let oldRequest = DiscordMentionRequest(id: "888", channel: "42", botID: "7", author: "Tester", question: "old scope", sessionID: a.id, receivedAt: now.addingTimeInterval(-30))
    a.agent?.discordMentionSince = now
    check(!AgentDiscordRouter.permits(oldRequest, session: a), "Re-enabling mentions does not revive requests accepted under the previous scope")

    let isolationRoot = root.appendingPathComponent("isolation")
    let isolatedStore = Store(folder: isolationRoot), isolatedRuntime = AgentRuntime()
    let healthy = isolatedStore.createAgent(title: "Healthy"), denied = isolatedStore.createAgent(title: "Denied")
    for s in [healthy, denied] { s.agent?.discordMentions = true; s.agent?.discordMentionSince = since }
    healthy.agent?.discordChannelID = "42"; denied.agent?.discordChannelID = "43"
    isolatedRuntime.keyReader = runtime.keyReader
    isolatedRuntime.api.request = { request in
        if request.url?.path.contains("/channels/43/") == true {
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        return try await runtime.api.request(request)
    }
    var healthyStarts = 0
    isolatedStore.startAgentRun = { session, _ in if session === healthy { healthyStarts += 1 } }
    rows = [row(id1, "public question")]
    wait { await isolatedRuntime.discordRouter.poll(store: isolatedStore, runtime: isolatedRuntime, now: now) }
    check(healthyStarts == 1 && healthy.agent?.turnLimit == 20, "A denied channel cannot starve queued requests in another enabled channel")
    isolatedRuntime.prepareForQuit()
    runtime.prepareForQuit(); restarted.prepareForQuit(); afterFailure.prepareForQuit()
}
