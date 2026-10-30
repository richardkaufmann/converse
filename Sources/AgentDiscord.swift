import Foundation

// Discord REST polling adapted from KAOS Hub's channel reader. Converse owns
// its credentials and cursors; it never loads KAOS configuration or state.
struct AgentDiscordMessage: Codable, Equatable {
    var id: String
    var author: String
    var content: String
    var timestamp: String
    var automated: Bool
    var attachmentNames: [String]
}
struct AgentDiscordBatch {
    var channel: String
    var messages: [AgentDiscordMessage]
    var newestID: String?
    var atLimit: Bool
    var evidence: [String: Any] {
        ["channelID": channel, "observedAt": ISO8601DateFormatter().string(from: Date()),
         "batchAtLimit": atLimit, "messages": messages.filter { !$0.automated }.map {
             ["id": $0.id, "author": $0.author, "text": $0.content,
              "timestamp": $0.timestamp, "attachmentNames": $0.attachmentNames] as [String: Any]
         }]
    }
}

enum AgentDiscord {
    static func channelID(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...20).contains(value.utf8.count), value.utf8.allSatisfy({ (48...57).contains($0) }), UInt64(value) != nil else {
            throw AgentFailure.message("Enter the Discord channel ID (Copy Channel ID in Discord).")
        }
        return value
    }
    static func newer(_ a: String, than b: String) -> Bool { (UInt64(a) ?? 0) > (UInt64(b) ?? 0) }
}

// One host client serves N agents. Concurrent identical reads share a request;
// cursors belong to agents, so one agent cannot consume another agent's input.
// The short cache is memory-only, including the credential used to partition it.
@MainActor final class AgentDiscordClient {
    struct Query: Hashable { var token: String; var channel: String; var after: String? }
    private var pending: [Query: Task<AgentDiscordBatch, Error>] = [:]
    private var cache: [Query: (Date, AgentDiscordBatch)] = [:]
    private var retryAt: Date = .distantPast

    private func call(_ path: String, token: String, api: AgentAPI, body: [String: Any]? = nil) async throws -> Any {
        guard retryAt <= Date() else { throw AgentFailure.message("Discord is rate limited. Try again after " + retryAt.formatted(date: .omitted, time: .standard) + ".") }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentFailure.message("Add a Discord bot token in Agent Setup.") }
        var request = URLRequest(url: URL(string: "https://discord.com/api/v10/" + path)!)
        request.timeoutInterval = 25
        request.setValue("Bot " + token, forHTTPHeaderField: "Authorization")
        request.setValue("Converse/1", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await api.request(request)
            if response.statusCode == 429 {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let seconds = (json?["retry_after"] as? Double) ?? 60
                retryAt = Date().addingTimeInterval(seconds.isFinite ? min(3600, max(1, seconds)) : 60)
                throw AgentFailure.message("Discord is rate limited. Wait before trying again; no automatic repost was made.")
            }
            guard (200..<300).contains(response.statusCode) else {
                switch response.statusCode {
                case 401: throw AgentFailure.message("Discord rejected the bot token. Replace it in Agent Setup.")
                case 403: throw AgentFailure.message("Discord denied channel access. Give the bot View Channel, Read Message History and, for posting, Send Messages.")
                case 404: throw AgentFailure.message("Discord channel or message not found. Check the channel ID and bot access.")
                default: throw AgentFailure.message("Discord returned HTTP \(response.statusCode). No automatic repost was made.")
                }
            }
            guard data.count <= 2_000_000 else { throw AgentFailure.message("Discord response was too large.") }
            return try JSONSerialization.jsonObject(with: data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as AgentFailure { throw error }
        catch { throw AgentFailure.message("Could not complete the Discord request. Check the network; check the channel before retrying a post.") }
    }
    func read(channel: String, after: String?, token: String, api: AgentAPI) async throws -> AgentDiscordBatch {
        let channel = try AgentDiscord.channelID(channel)
        if let after { _ = try AgentDiscord.channelID(after) }
        let query = Query(token: token, channel: channel, after: after)
        cache = cache.filter { Date().timeIntervalSince($0.value.0) < 5 }
        if let value = cache[query] { return value.1 }
        if let task = pending[query] { return try await task.value }
        let task = Task { @MainActor in
            let limit = after == nil ? 50 : 100
            let suffix = after.map { "&after=" + $0 } ?? ""
            let raw = try await self.call("channels/\(channel)/messages?limit=\(limit)" + suffix, token: token, api: api)
            guard let rows = raw as? [[String: Any]] else { throw AgentFailure.message("Discord returned an invalid channel history response.") }
            var messages: [AgentDiscordMessage] = []
            for row in rows {
                guard let id = row["id"] as? String, (try? AgentDiscord.channelID(id)) != nil,
                      row["channel_id"] as? String == channel,
                      let author = row["author"] as? [String: Any], let content = row["content"] as? String else {
                    throw AgentFailure.message("Discord returned an incomplete message. Read position was not advanced.")
                }
                if let after, !AgentDiscord.newer(id, than: after) { continue }
                let attachments = (row["attachments"] as? [[String: Any]] ?? []).compactMap { $0["filename"] as? String }
                let automated = author["bot"] as? Bool == true || row["webhook_id"] != nil
                if !automated && content.isEmpty && attachments.isEmpty && (row["embeds"] as? [Any] ?? []).isEmpty && (row["type"] as? Int ?? 0) == 0 {
                    throw AgentFailure.message("Discord returned a human message without readable content. Enable Message Content Intent for the Converse bot; read position was not advanced.")
                }
                messages.append(AgentDiscordMessage(id: id, author: String(((author["global_name"] as? String) ?? (author["username"] as? String) ?? "Unknown").prefix(100)), content: String(content.prefix(1200)), timestamp: row["timestamp"] as? String ?? "Unknown", automated: automated, attachmentNames: Array(attachments.prefix(10))))
            }
            messages.sort { AgentDiscord.newer($1.id, than: $0.id) }
            return AgentDiscordBatch(channel: channel, messages: messages, newestID: messages.last?.id ?? after, atLimit: rows.count == limit)
        }
        pending[query] = task
        defer { pending.removeValue(forKey: query) }
        let result = try await task.value
        cache[query] = (Date(), result)
        return result
    }
    func post(_ text: String, channel: String, token: String, api: AgentAPI) async throws -> String {
        let channel = try AgentDiscord.channelID(channel)
        let raw = try await call("channels/\(channel)/messages", token: token, api: api,
                                 body: ["content": String(text.prefix(1800)), "allowed_mentions": ["parse": []]])
        guard let row = raw as? [String: Any], row["channel_id"] as? String == channel,
              let id = row["id"] as? String, (try? AgentDiscord.channelID(id)) != nil else {
            throw AgentFailure.message("Discord did not confirm delivery. Check the channel before retrying.")
        }
        cache.removeAll()
        return id
    }
    func test(channel: String, token: String, api: AgentAPI) async throws -> String {
        let channel = try AgentDiscord.channelID(channel)
        let user = try await call("users/@me", token: token, api: api) as? [String: Any]
        guard user?["bot"] as? Bool == true else { throw AgentFailure.message("Use a Discord bot token, not a user token or webhook URL.") }
        // Check history access before posting, then prove the exact marker comes
        // back via channel history (not the POST receipt or webhook readback).
        _ = try await read(channel: channel, after: nil, token: token, api: api)
        let marker = "Converse connection test · " + UUID().uuidString + " · No session content is included."
        let id = try await post(marker, channel: channel, token: token, api: api)
        let raw = try await call("channels/\(channel)/messages?limit=100&around=\(id)", token: token, api: api)
        guard let rows = raw as? [[String: Any]], rows.contains(where: { $0["id"] as? String == id && $0["channel_id"] as? String == channel && $0["content"] as? String == marker }) else {
            throw AgentFailure.message("Discord accepted the test post, but channel history did not return its exact text. Reading is not verified.")
        }
        return "Discord send and channel-history read verified. The labeled test stays in the channel. Enable Message Content Intent to read ordinary human messages too."
    }
}
