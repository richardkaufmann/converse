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
