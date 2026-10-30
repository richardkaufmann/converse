import Foundation
import AppKit

// Discord REST polling adapted from KAOS Hub's channel reader. Converse owns
// its credentials and cursors; it never loads KAOS configuration or state.
struct AgentDiscordMessage: Codable, Equatable {
    var id: String
    var author: String
    var content: String
    var timestamp: String
    var automated: Bool
    var attachmentNames: [String]
    var authorID: String? = nil
    var mentions: [String]? = nil
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
    // Discord supports inline Markdown, but not GFM tables. Keep wide tables
    // readable on phones by turning each row into labelled fields.
    static func format(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = [], i = 0, fence: String? = nil
        while i < lines.count {
            let line = lines[i], trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                result.append(line); i += 1; continue
            }
            if fence == nil && i + 1 < lines.count && line.contains("|") && MarkdownText.tableDivider(lines[i + 1]) {
                let labels = MarkdownText.cells(line); i += 2
                while i < lines.count && lines[i].contains("|") && !lines[i].isEmpty {
                    let row = MarkdownText.cells(lines[i])
                    result.append(labels.indices.map { "**" + labels[$0] + ":** " + ($0 < row.count ? row[$0] : "") }.joined(separator: " · "))
                    i += 1
                }
            } else { result.append(line); i += 1 }
        }
        return result.joined(separator: "\n")
    }
    static func newer(_ a: String, than b: String) -> Bool { (UInt64(a) ?? 0) > (UInt64(b) ?? 0) }
}

// One host client serves N agents. Concurrent identical reads share a request;
// cursors belong to agents, so one agent cannot consume another agent's input.
// The short cache is memory-only, including the credential used to partition it.
@MainActor final class AgentDiscordClient {
    struct Query: Hashable { var token: String; var channel: String; var after: String?; var before: String? }
    private var pending: [Query: Task<AgentDiscordBatch, Error>] = [:]
    private var cache: [Query: (Date, AgentDiscordBatch)] = [:]
    private var retryAt: Date = .distantPast
    private var identities: [String: String] = [:]

    private func call(_ path: String, token: String, api: AgentAPI, body: [String: Any]? = nil, image: Data? = nil) async throws -> Any {
        guard retryAt <= Date() else { throw AgentFailure.message("Discord is rate limited. Try again after " + retryAt.formatted(date: .omitted, time: .standard) + ".") }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentFailure.message("Add a Discord bot token in Agent Setup.") }
        var request = URLRequest(url: URL(string: "https://discord.com/api/v10/" + path)!)
        request.timeoutInterval = 25
        request.setValue("Bot " + token, forHTTPHeaderField: "Authorization")
        request.setValue("Converse/1", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let json = try JSONSerialization.data(withJSONObject: body)
            if let image {
                guard image.count <= 8_000_000 else { throw AgentFailure.message("Discord image exceeds 8 MB.") }
                let boundary = "Converse-" + UUID().uuidString
                request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
                var bytes = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n".utf8)
                bytes.append(json)
                bytes.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"scoreboard.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
                bytes.append(image); bytes.append(Data("\r\n--\(boundary)--\r\n".utf8)); request.httpBody = bytes
            } else { request.httpBody = json }
        }
        do {
            let (data, response) = try await api.request(request)
            if response.statusCode == 429 {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let seconds = (json?["retry_after"] as? Double) ?? 60
                retryAt = Date().addingTimeInterval(seconds.isFinite ? min(3600, max(1, seconds)) : 60)
                throw AgentFailure.message("Discord is rate limited. Wait before trying again; no automatic repost was made.")
            }
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
               let seconds = Double(response.value(forHTTPHeaderField: "X-RateLimit-Reset-After") ?? ""), seconds.isFinite {
                retryAt = Date().addingTimeInterval(min(3600, max(0, seconds)))
            }
            guard (200..<300).contains(response.statusCode) else {
                switch response.statusCode {
                case 401: throw AgentFailure.message("Discord rejected the bot token. Replace it in Agent Setup.")
                case 403: throw AgentFailure.message("Discord denied channel access. Give the bot View Channel, Read Message History and, for posting, Send Messages and Attach Files.")
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
    func read(channel: String, after: String?, token: String, api: AgentAPI, before: String? = nil) async throws -> AgentDiscordBatch {
        let channel = try AgentDiscord.channelID(channel)
        if let after { _ = try AgentDiscord.channelID(after) }
        if let before { _ = try AgentDiscord.channelID(before) }
        let query = Query(token: token, channel: channel, after: after, before: before)
        cache = cache.filter { Date().timeIntervalSince($0.value.0) < 5 }
        if let value = cache[query] { return value.1 }
        if let task = pending[query] { return try await task.value }
        let task = Task { @MainActor in
            let limit = after == nil && before == nil ? 50 : 100
            let suffix = before.map { "&before=" + $0 } ?? after.map { "&after=" + $0 } ?? ""
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
                messages.append(AgentDiscordMessage(id: id, author: String(((author["global_name"] as? String) ?? (author["username"] as? String) ?? "Unknown").prefix(100)), content: String(content.prefix(4000)), timestamp: row["timestamp"] as? String ?? "Unknown", automated: automated, attachmentNames: Array(attachments.prefix(10)), authorID: author["id"] as? String, mentions: (row["mentions"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }))
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
    func readMentions(channel: String, after: String, token: String, api: AgentAPI) async throws -> AgentDiscordBatch {
        var batch = try await read(channel: channel, after: after, token: token, api: api)
        var messages = batch.messages
        // Discord history is newest-first. Walk backwards from a full page so
        // a burst larger than 100 cannot jump over earlier, unseen commands.
        var pages = 1
        while batch.atLimit, let oldest = batch.messages.first?.id, AgentDiscord.newer(oldest, than: after) {
            guard pages < 10 else { throw AgentFailure.message("Discord mention backlog exceeds 1000 messages; no commands were skipped or started. Review the channel before re-enabling mentions.") }
            batch = try await read(channel: channel, after: nil, token: token, api: api, before: oldest)
            let fresh = batch.messages.filter { AgentDiscord.newer($0.id, than: after) }
            messages += fresh
            pages += 1
            if fresh.count != batch.messages.count { break }
        }
        let unique = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { AgentDiscord.newer($1.id, than: $0.id) }
        return AgentDiscordBatch(channel: channel, messages: unique, newestID: unique.last?.id ?? after, atLimit: false)
    }
    func botID(token: String, api: AgentAPI) async throws -> String {
        if let id = identities[token] { return id }
        let user = try await call("users/@me", token: token, api: api) as? [String: Any]
        guard user?["bot"] as? Bool == true, let id = user?["id"] as? String else { throw AgentFailure.message("Use a Discord bot token.") }
        _ = try AgentDiscord.channelID(id)
        identities = [token: id]
        return id
    }
    func post(_ text: String, channel: String, token: String, api: AgentAPI, replyingTo: String? = nil, nonce: String? = nil, image: Data? = nil) async throws -> String {
        let channel = try AgentDiscord.channelID(channel)
        var body: [String: Any] = ["content": String(AgentDiscord.format(text).prefix(1800)), "allowed_mentions": ["parse": [], "replied_user": false]]
        if let replyingTo {
            _ = try AgentDiscord.channelID(replyingTo)
            body["message_reference"] = ["message_id": replyingTo, "channel_id": channel, "fail_if_not_exists": false]
        }
        if let nonce { body["nonce"] = String(nonce.prefix(25)); body["enforce_nonce"] = true }
        if image != nil { body["attachments"] = [["id": 0, "filename": "scoreboard.png"]] }
        let raw = try await call("channels/\(channel)/messages", token: token, api: api, body: body, image: image)
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

// Only host-selected agent artwork and scoreboard fields can become uploads.
// No model-supplied path, transcript, attention text, or working notes are read.
@MainActor enum AgentDiscordImage {
    static func render(session: Session, store: Store, kind: String) throws -> Data {
        guard let config = session.agent, config.discordShareScoreboard == true,
              ["art", "scoreboard"].contains(kind) else { throw AgentFailure.message("Scoreboard sharing is off in Agent Setup.") }
        let root = store.folder.appendingPathComponent("Agents/" + session.id.uuidString).resolvingSymlinksInPath()
        var art: NSImage?
        if let path = config.artPath {
            let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
            if file.path.hasPrefix(root.path + "/"), size?.isRegularFile == true, (size?.fileSize ?? Int.max) <= 8_000_000 { art = NSImage(contentsOf: file) }
        }
        if kind == "art" && art == nil { throw AgentFailure.message("This agent has no saved mood image yet.") }
        let width = 1200, height = kind == "art" ? 900 : (art == nil ? 640 : 1100)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw AgentFailure.message("Could not render scoreboard image.") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        let artHeight: CGFloat = kind == "art" ? CGFloat(height) : (art == nil ? 0 : 460)
        if let art, art.size.width > 0, art.size.height > 0 {
            let scale = min(CGFloat(width) / art.size.width, artHeight / art.size.height)
            let size = NSSize(width: art.size.width * scale, height: art.size.height * scale)
            art.draw(in: NSRect(x: (CGFloat(width) - size.width) / 2, y: CGFloat(height) - artHeight + (artHeight - size.height) / 2, width: size.width, height: size.height))
        }
        if kind == "scoreboard" {
            var y = CGFloat(height) - artHeight - 60
            func label(_ text: String, size: CGFloat, height: CGFloat) {
                let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
                (text as NSString).draw(in: NSRect(x: 40, y: y - height, width: 1120, height: height), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: size > 24 ? .semibold : .regular), .foregroundColor: NSColor.black, .paragraphStyle: style]); y -= height + 12
            }
            label(String(session.title.prefix(100)), size: 32, height: 48)
            if let board = config.scoreboard {
                label(board.summary, size: 23, height: 70)
                for metric in board.metrics.prefix(6) { label(metric.label + ": " + metric.value + (metric.asOf.map { " · " + $0 } ?? ""), size: 21, height: 42) }
                label("Observed: " + (board.observedAt?.formatted() ?? "Unknown"), size: 17, height: 30)
            } else if let repo = config.repositorySnapshot, repo.hasMeasurements {
                for metric in repo.metrics.prefix(6) { label(metric.0 + ": " + metric.1, size: 23, height: 48) }
            } else { label("No measured scoreboard data yet.", size: 23, height: 50) }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count <= 8_000_000 else { throw AgentFailure.message("Scoreboard image exceeds 8 MB.") }
        return data
    }
}
