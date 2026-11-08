import Foundation

@MainActor func agentDiscordSelfTests(_ check: (Bool, String) -> Void) {
    func run(_ operation: @escaping @MainActor () async throws -> String) -> String {
        var result = "Timed out", done = false
        Task { @MainActor in
            do { result = try await operation() } catch { result = error.localizedDescription }
            done = true
        }
        let deadline = Date().addingTimeInterval(4)
        while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return result
    }
    func row(_ id: String, text: String = "A complaint", bot: Bool = false) -> [String: Any] {
        ["id": id, "channel_id": "42", "content": text, "author": ["username": "Fixture", "bot": bot], "timestamp": "2026-10-30T03:00:00Z", "type": 0]
    }
    let everyone: [[String: Any]] = [["id": "99", "permissions": "1024"]]
    var privacyChannel: [String: Any] = ["guild_id": "99", "type": 0, "permission_overwrites": [["id": "99", "type": 0, "deny": "1024", "allow": "0"]]]
    check(AgentDiscordClient.isPrivate(channel: privacyChannel, roles: everyone), "Discord private text channel denies VIEW_CHANNEL to everyone")
    check(!AgentDiscordClient.isPrivate(channel: privacyChannel, roles: [["id": "99", "permissions": "1032"]]), "Everyone administrator bypass cannot count as private")
    privacyChannel["permission_overwrites"] = [["id": "99", "type": 0, "deny": "1024", "allow": "1024"]]
    check(!AgentDiscordClient.isPrivate(channel: privacyChannel, roles: everyone), "Discord everyone allow wins over deny")
    privacyChannel["permission_overwrites"] = [["id": "99", "type": 0, "deny": "invalid", "allow": "0"]]
    check(!AgentDiscordClient.isPrivate(channel: privacyChannel, roles: everyone) && !AgentDiscordClient.isPrivate(channel: [:], roles: []), "Missing or malformed Discord privacy evidence denies session sharing")
    let table = "### Report\n| Name | State |\n|---|---|\n| Steward | **Ready** |"
    check(AgentDiscord.format(table).contains("**Name:** Steward · **State:** **Ready**") && !AgentDiscord.format(table).contains("|---|"), "Discord preserves Markdown and renders tables as readable labelled fields")
    check(AgentDiscord.format("```\n| a | b |\n|---|---|\n```") == "```\n| a | b |\n|---|---|\n```", "Discord table conversion preserves literal fenced code")
    do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discord-image-" + UUID().uuidString)
        let store = Store(folder: root), session = store.createAgent(title: "Public assessment")
        session.agent?.scoreboard = AgentScoreboard(title: "Fixture", summary: "Synthetic test data", metrics: [.init(label: "Checks", value: "Passed")])
        check(AgentScoreboardImage.lines(session: session).contains { $0.text == "Checks: Passed · Evidence" } && session.agent?.assessment == nil,
              "An older scoreboard draws as a seeded, stale assessment without changing the stored record")
        let png = try AgentScoreboardImage.render(session: session, store: store)
        check(png.starts(with: [137, 80, 78, 71]) && png.count < 8_000_000, "The measured preview renderer produces a bounded PNG")
        let imageAPI = AgentAPI(); var imageRequest: URLRequest?
        imageAPI.request = { request in
            imageRequest = request
            return (Data("{\"id\":\"90\",\"channel_id\":\"42\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let receipt = run { try await AgentDiscordClient().post("**Test**", channel: "42", token: "synthetic", api: imageAPI, replyingTo: "80", nonce: "80", image: png) }
        let body = imageRequest?.httpBody ?? Data(), wire = String(decoding: body, as: UTF8.self)
        check(receipt == "90" && imageRequest?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true && body.range(of: png) != nil && wire.contains("files[0]") && wire.contains("payload_json") && wire.contains("allowed_mentions") && wire.contains("message_reference") && wire.contains("enforce_nonce"), "Discord posts verified PNG bytes with Markdown, reply reference and duplicate/mention guards in one multipart request")
        session.agent?.artPath = root.deletingLastPathComponent().appendingPathComponent("unapproved.png").path
        var outside = false
        do { _ = try AgentScoreboardImage.render(session: session, store: store, kind: "art") } catch { outside = true }
        check(outside, "Image rendering rejects art paths outside this agent's folder")
    } catch { check(false, "Discord image fixture: " + error.localizedDescription) }
    let api = AgentAPI(), client = AgentDiscordClient()
    var requests: [URLRequest] = [], marker = ""
    var missingReadback = false, status = 200
    api.request = { request in
        requests.append(request)
        var object: Any = [row("10")]
        if request.url?.path.hasSuffix("/users/@me") == true { object = ["id": "7", "bot": true] }
        else if request.httpMethod == "POST" {
            marker = ((try JSONSerialization.jsonObject(with: request.httpBody!)) as? [String: Any])?["content"] as? String ?? ""
            object = row("12", text: marker, bot: true)
        } else if request.url?.query?.contains("around=") == true { object = missingReadback ? [] : [row("12", text: marker, bot: true)] }
        if status != 200 { object = ["message": "SECRET-CANARY", "retry_after": 10] }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    let good = run { try await client.test(channel: "42", token: "synthetic-bot-token", api: api) }
    let posted = requests.first(where: { $0.httpMethod == "POST" })?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(good.contains("send and channel-history read verified") && requests.count == 4 && requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bot synthetic-bot-token" && $0.url?.host == "discord.com" }, "Discord uses one bot credential for verified send and history read")
    check(marker.hasPrefix("Converse connection test") && (posted?["allowed_mentions"] as? [String: Any])?["parse"] as? [String] == [] && requests.last?.url?.query?.contains("around=12") == true, "Discord bidirectional test reads its exact labeled marker through channel history with mentions off")
    missingReadback = true
    let notRead = run { try await client.test(channel: "42", token: "synthetic-bot-token", api: api) }
    check(notRead.contains("Reading is not verified"), "Discord POST receipt alone cannot pass the bidirectional test")
    for invalid in ["../42", "42?token=secret", "https://discord.com/channels/1/42", "", "٤٢"] {
        requests = []
        _ = run { _ = try await client.read(channel: invalid, after: nil, token: "fixture", api: api); return "unexpected" }
        check(requests.isEmpty, "Discord rejects malformed channel IDs before transmitting credentials")
    }
    status = 403; requests = []
    let denied = run { try await AgentDiscordClient().test(channel: "42", token: "fixture", api: api) }
    check(denied.contains("denied channel access") && !denied.contains("SECRET-CANARY") && requests.count == 1 && requests[0].httpMethod == "GET", "Discord permission errors are safe and prevent test posting")
    status = 429; requests = []
    let limited = AgentDiscordClient()
    _ = run { try await limited.post("fixture", channel: "42", token: "fixture", api: api) }
    _ = run { try await limited.post("fixture", channel: "42", token: "fixture", api: api) }
    check(requests.count == 1, "Discord rate limit cooldown prevents immediate repeated sends")
    status = 200
    api.request = { request in throw NSError(domain: "SECRET-CANARY", code: 1, userInfo: [NSLocalizedDescriptionKey: "SECRET-CANARY"]) }
    let failed = run { try await AgentDiscordClient().post("fixture", channel: "42", token: "fixture", api: api) }
    check(!failed.contains("SECRET-CANARY") && failed.contains("before retrying a post"), "Discord transport failures do not leak tokens or automatically duplicate posts")

    requests = []
    api.request = { request in
        requests.append(request)
        try await Task.sleep(nanoseconds: 20_000_000)
        return (try JSONSerialization.data(withJSONObject: [row("13", bot: true), row("12"), row("11")]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let shared = AgentDiscordClient()
    let sharedResult = run {
        async let first = shared.read(channel: "42", after: "10", token: "fixture", api: api)
        async let second = shared.read(channel: "42", after: "10", token: "fixture", api: api)
        let (a, b) = try await (first, second)
        return a.messages == b.messages && a.messages.map(\.id) == ["11", "12", "13"] && (a.evidence["messages"] as? [[String: Any]])?.count == 2 && a.newestID == "13" ? "shared" : "wrong"
    }
    check(sharedResult == "shared" && requests.count == 1, "N agents share concurrent reads, receive chronological input, and exclude bot posts from model evidence")
    _ = run { _ = try await shared.read(channel: "42", after: "11", token: "fixture", api: api); return "done" }
    _ = run { _ = try await shared.read(channel: "42", after: "10", token: "different-bot", api: api); return "done" }
    check(requests.count == 3, "Different agent cursors and credentials never reuse the wrong Discord batch")
    api.request = { request in
        (try JSONSerialization.data(withJSONObject: [row("14", text: "")]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let empty = run { _ = try await AgentDiscordClient().read(channel: "42", after: nil, token: "fixture", api: api); return "unexpected" }
    check(empty.contains("Message Content Intent"), "Empty human content fails visibly instead of reporting no complaints")
    // A full newest-first page must not skip the older part of a burst.
    var pages = 0
    api.request = { request in
        pages += 1
        let before = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "before" })?.value
        let values = before == nil ? Array(111...210) : Array(90...110)
        return (try JSONSerialization.data(withJSONObject: values.reversed().map { row(String($0)) }), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let burst = run {
        let result = try await AgentDiscordClient().readMentions(channel: "42", after: "100", token: "fixture", api: api)
        return result.messages.map(\.id) == (101...210).map(String.init) && result.newestID == "210" ? "complete" : "skipped"
    }
    check(burst == "complete" && pages == 2, "Mention listener paginates a burst over 100 messages without skipping the older commands")
    do {
        var a = AgentConfig(); a.discordRead = true; a.discordChannelID = "42"; a.discordCursorChannel = "42"; a.discordLastMessageID = "12"
        let restored = try JSONDecoder().decode(AgentConfig.self, from: JSONEncoder().encode(a))
        var b = AgentConfig(); b.discordChannelID = "42"
        check(restored.discordLastMessageID == "12" && restored.discordRead == true && b.discordLastMessageID == nil, "Discord read positions persist per agent rather than consuming a shared mailbox")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        for key in ["discordRead", "discordChannelID", "discordCursorChannel", "discordLastMessageID"] { object.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(AgentConfig.self, from: JSONSerialization.data(withJSONObject: object))
        check(legacy.discordRead == nil && legacy.discordChannelID == nil, "Old agent archives keep Discord reading off without implicit channel scope")
    } catch { check(false, "Discord persistence: " + error.localizedDescription) }
}
