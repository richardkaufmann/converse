import Foundation

struct DiscordMentionRequest: Codable, Equatable {
    var id: String
    var channel: String
    var botID: String
    var author: String
    var question: String
    var sessionID: UUID?
    var receivedAt: Date
    var state = "queued"
    var reply: String? = nil
    var receipt: String? = nil
    var imageHash: String? = nil
    var sharedSessionInformation: Bool? = nil
}
struct DiscordMentionJournal: Codable {
    var botID = ""
    var cursors: [String: String] = [:]
    var requests: [DiscordMentionRequest] = []
}

// One listener for all Mac-home agents. The journal and each agent's monitoring
// cursor are separate: monitoring cannot consume a command or vice versa.
// Requests are marked running BEFORE invoking a model, and sending BEFORE a
// POST. Ambiguous interrupted operations are never automatically repeated.
@MainActor final class AgentDiscordRouter {
    private var journal = DiscordMentionJournal()
    private var loadedPath: String?
    private var polling = false
    private var stopped = false
    private var retryAt = Date.distantPast
    private var lastError = ""
    private var task: Task<Void, Never>?
    var pendingRequests: [DiscordMentionRequest] { journal.requests }
    static func file(_ store: Store) -> URL { store.folder.appendingPathComponent("Discord/mentions.json") }
    static func snowflake(at date: Date) -> String {
        String(UInt64(max(0, min(4_398_046_511_103, (date.timeIntervalSince1970 * 1000 - 1_420_070_400_000)))) << 22)
    }
    static func date(of id: String) -> Date? {
        guard let value = UInt64(id) else { return nil }
        return Date(timeIntervalSince1970: Double((value >> 22) + 1_420_070_400_000) / 1000)
    }
    static func eligible(_ session: Session, channel: String) -> Bool {
        session.agent?.discordMentions == true && session.agent?.discordChannelID == channel
    }
    static func permits(_ request: DiscordMentionRequest, session: Session) -> Bool {
        eligible(session, channel: request.channel) && request.receivedAt >= (session.agent?.discordMentionSince ?? .distantFuture)
    }
    static func question(_ message: AgentDiscordMessage, botID: String) -> String? {
        guard !message.automated, message.mentions?.contains(botID) == true,
              let author = message.authorID, (try? AgentDiscord.channelID(author)) != nil else { return nil }
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["<@" + botID + ">", "<@!" + botID + ">"] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
    static func resolve(_ text: String, sessions: [Session]) -> (Session?, String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("please ") { text = String(text.dropFirst(7)) }
        let asks = text.lowercased().hasPrefix("ask ")
        if asks { text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let defaults = sessions.filter { $0.agent?.discordDefault == true }
        let matches = sessions.filter { s in
            let title = s.title.lowercased(), value = text.lowercased()
            return value == title || value.hasPrefix(title + ":") || value.hasPrefix(title + " ")
                || value.hasPrefix(s.id.uuidString.lowercased() + ":")
        }
        if matches.count == 1, let s = matches.first {
            let length = text.lowercased().hasPrefix(s.id.uuidString.lowercased() + ":") ? s.id.uuidString.count : s.title.count
            let question = String(text.dropFirst(length)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
            return (s, question)
        }
        if matches.isEmpty, asks, defaults.count == 1, text.lowercased().hasPrefix("converse agent ") {
            return (defaults[0], String(text.dropFirst("converse agent".count)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Unknown explicit names must never fall through to the default.
        if !matches.isEmpty || asks || text.contains(":") { return (nil, text) }
        if defaults.count == 1 { return (defaults[0], text) }
        return (sessions.count == 1 ? sessions[0] : nil, text)
    }
    func status(for session: Session) -> String {
        if !lastError.isEmpty { return "Discord mentions: " + lastError }
        if journal.requests.contains(where: { $0.sessionID == session.id && $0.state == "sending" }) { return "Discord reply unconfirmed · check channel" }
        let count = journal.requests.filter { $0.sessionID == session.id && $0.state == "queued" }.count
        return count > 0 ? "Discord · \(count) queued" : "Discord mentions on · checks every 5s"
    }
    func stop() { stopped = true; task?.cancel(); task = nil }
    func tick(store: Store, runtime: AgentRuntime) {
        guard !polling, !stopped, Date() >= retryAt else { return }
        task = Task { @MainActor in await self.poll(store: store, runtime: runtime) }
    }
    private func persist(_ store: Store) throws {
        let file = Self.file(store)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(journal).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func load(_ store: Store) throws {
        guard loadedPath != store.folder.path else { return }
        let file = Self.file(store)
        if FileManager.default.fileExists(atPath: file.path) {
            journal = try JSONDecoder().decode(DiscordMentionJournal.self, from: Data(contentsOf: file))
        } else { journal = DiscordMentionJournal() }
        for index in journal.requests.indices {
            switch journal.requests[index].state {
            case "running":
                journal.requests[index].state = "ready"
                journal.requests[index].reply = "Converse restarted during this request. It was not repeated; please send a new mention if you still need an answer."
            case "sending":
                journal.requests[index].state = "done"
                lastError = "a reply was interrupted; check Discord before repeating it"
            default: break
            }
        }
        for session in store.sessions where session.agent?.discordActiveRequestID != nil { session.agent?.discordActiveRequestID = nil }
        try persist(store); try store.saveChecked()
        loadedPath = store.folder.path
    }
    func poll(store: Store, runtime: AgentRuntime, now: Date = Date()) async {
        guard !polling, !stopped else { return }
        polling = true
        defer { polling = false }
        do {
            try load(store)
            let enabled = store.sessions.filter { $0.agent?.discordMentions == true }
            guard !enabled.isEmpty || journal.requests.contains(where: { $0.state == "ready" }) else { return }
            guard let token = try runtime.keyReader("discordBot"), !token.isEmpty else { throw AgentFailure.message("add a bot token in Agent Setup") }
            let bot = try await runtime.discordClient.botID(token: token, api: runtime.api)
            try Task.checkCancellation()
            if journal.botID != bot {
                journal = DiscordMentionJournal(botID: bot)
                try persist(store)
            }
            // Retain completed receipts for a day. Channel cursors provide the
            // permanent duplicate barrier without an unbounded message log.
            journal.requests.removeAll { $0.state == "done" && now.timeIntervalSince($0.receivedAt) > 86400 }
            let channels = Set(enabled.compactMap { $0.agent?.discordChannelID }).sorted()
            journal.cursors = journal.cursors.filter { channels.contains($0.key) }
            var channelErrors: [String] = []
            for channel in channels {
                do {
                _ = try AgentDiscord.channelID(channel)
                let scope = enabled.filter { Self.eligible($0, channel: channel) }
                let since = scope.compactMap { $0.agent?.discordMentionSince }.min() ?? now
                let baseline = Self.snowflake(at: since)
                let cursor = journal.cursors[channel].map { AgentDiscord.newer($0, than: baseline) ? $0 : baseline } ?? baseline
                // Persist a first-enable boundary even for an empty channel.
                journal.cursors[channel] = cursor
                try persist(store)
                let batch = try await runtime.discordClient.readMentions(channel: channel, after: cursor, token: token, api: runtime.api)
                try Task.checkCancellation()
                // Recompute scope after network suspension, before accepting.
                let current = store.sessions.filter { Self.eligible($0, channel: channel) }
                for message in batch.messages {
                    guard let question = Self.question(message, botID: bot),
                          !journal.requests.contains(where: { $0.id == message.id && $0.channel == channel }),
                          let created = Self.date(of: message.id), now.timeIntervalSince(created) < 600 else { continue }
                    let candidates = current.filter { created >= ($0.agent?.discordMentionSince ?? now) }
                    guard !candidates.isEmpty else { continue }
                    let (target, prompt) = Self.resolve(question, sessions: candidates)
                    var item = DiscordMentionRequest(id: message.id, channel: channel, botID: bot, author: message.author, question: prompt, sessionID: target?.id, receivedAt: now)
                    if target == nil || prompt.isEmpty {
                        item.state = "ready"
                        item.reply = "Use @Converse Agent Name: question. Available here: " + candidates.map(\.title).joined(separator: ", ")
                    } else if journal.requests.filter({ $0.state == "queued" || $0.state == "running" }).count >= 20 {
                        item.state = "ready"; item.reply = "The agent queue is full. Please try again later."
                    } else if (target?.agent?.turnLimit ?? 0) <= 0 {
                        item.state = "ready"; item.reply = "This agent has an invalid per-loop limit. Review Agent Setup, then send a new mention."
                    }
                    guard journal.requests.count < 4000 else { throw AgentFailure.message("Discord request journal is full; commands remain unread until room is available") }
                    journal.requests.append(item)
                }
                // Snapshot the accepted commands and cursor together. Never
                // start a model or post a reply before this atomic write.
                journal.cursors[channel] = batch.newestID ?? cursor
                try persist(store)
                } catch let error as AgentFailure {
                    channelErrors.append(error.localizedDescription)
                }
            }
            try startQueued(store: store, now: now)
            lastError = channelErrors.first ?? ""
            await flush(store: store, runtime: runtime, token: token, botID: bot)
            if lastError.isEmpty { retryAt = .distantPast }
        } catch is CancellationError { }
        catch {
            lastError = error is AgentFailure ? error.localizedDescription : "could not save/read the request journal"
            retryAt = Date().addingTimeInterval(30)
            // A failed durable write must not leave an in-memory cursor that
            // can silently skip a command. Stop until journal recovery at restart.
            if !(error is AgentFailure) { stopped = true; lastError += "; restart Converse after checking disk access" }
        }
    }
    func startQueued(store: Store, now: Date = Date()) throws {
        for i in journal.requests.indices where journal.requests[i].state == "queued" {
            let request = journal.requests[i]
            guard let session = store.sessions.first(where: { $0.id == request.sessionID }), Self.permits(request, session: session) else {
                journal.requests[i].state = "done"; try persist(store); continue
            }
            if now.timeIntervalSince(request.receivedAt) > 600 {
                journal.requests[i].state = "ready"; journal.requests[i].reply = "This request expired while waiting. Send a new mention if it is still needed."
                try persist(store); continue
            }
            guard !session.busy, !session.queuePaused, session.pending.isEmpty, !session.changingSetting,
                  !AgentConversation.shared.owns(session), session.agent?.jollyRequestID == nil,
                  session.agent?.discordActiveRequestID == nil else { continue }
            guard var config = session.agent, config.turnLimit > 0 else {
                journal.requests[i].state = "ready"; journal.requests[i].reply = "This agent has an invalid per-loop limit. Review Agent Setup, then send a new mention."
                try persist(store); continue
            }
            journal.requests[i].state = "running"; try persist(store)
            let previous = session.agent
            config.discordActiveRequestID = request.id; session.agent = config
            do { try store.saveChecked() } catch { session.agent = previous; throw error }
            let draft = session.draft, images = session.attachments
            session.draft = "[Discord mention · " + request.author + " · " + request.id + "]\n" + request.question
            session.attachments = []
            store.send(session, preservingAgentDraft: (draft, images))
            session.draft = draft; session.attachments = images
            if !session.busy {
                try complete(request.id, text: "The agent could not start. Check its session in Converse.", store: store)
            }
        }
    }
    func active(_ session: Session) -> DiscordMentionRequest? {
        journal.requests.first { $0.id == session.agent?.discordActiveRequestID && $0.sessionID == session.id && $0.state == "running" }
    }
    func complete(_ id: String, text: String, store: Store, image: Data? = nil, sharedSessionInformation: Bool = false) throws {
        guard let i = journal.requests.firstIndex(where: { $0.id == id && $0.state == "running" }) else { return }
        if let image {
            let hash = DeviceBlob.sha256Hex(image)
            let folder = Self.file(store).deletingLastPathComponent().appendingPathComponent("Images")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try image.write(to: folder.appendingPathComponent(hash + ".png"), options: .atomic)
            journal.requests[i].imageHash = hash
        }
        journal.requests[i].sharedSessionInformation = sharedSessionInformation
        journal.requests[i].reply = String(text.prefix(1700)); journal.requests[i].state = "ready"
        try persist(store)
        if let session = store.sessions.first(where: { $0.id == journal.requests[i].sessionID }) {
            session.agent?.discordActiveRequestID = nil; try store.saveChecked()
        }
    }
    private func flush(store: Store, runtime: AgentRuntime, token: String, botID: String) async {
        for i in journal.requests.indices where journal.requests[i].state == "ready" {
            let request = journal.requests[i]
            let targets = store.sessions.filter { Self.eligible($0, channel: request.channel) }
            guard !stopped, request.botID == botID, !targets.isEmpty,
                  request.sessionID == nil || targets.contains(where: { $0.id == request.sessionID && Self.permits(request, session: $0) }) else { continue }
            do {
                // Persist the attempt before network I/O; a timeout or crash
                // cannot cause a duplicate public reply on the next poll.
                var image: Data? = nil
                var reply = request.reply ?? "Request ended without a reply."
                if let hash = request.imageHash {
                    if targets.first(where: { $0.id == request.sessionID })?.agent?.discordShareScoreboard != true {
                        reply = "Portrait sharing was turned off before delivery. No image was sent."
                    } else {
                        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw AgentFailure.message("Invalid saved Discord image.") }
                        let file = Self.file(store).deletingLastPathComponent().appendingPathComponent("Images/" + hash + ".png")
                        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 8_000_000 else { throw AgentFailure.message("Saved Discord image is unavailable or too large.") }
                        let bytes = try Data(contentsOf: file)
                        guard bytes.count <= 8_000_000, DeviceBlob.verify(bytes, sha256Hex: hash) else { throw AgentFailure.message("Saved Discord image could not be verified.") }
                        image = bytes
                    }
                }
                if request.sharedSessionInformation == true {
                    let allowed = targets.first(where: { $0.id == request.sessionID })?.agent?.discordShareSessionInformation == true
                    let privateChannel = allowed ? ((try? await runtime.discordClient.isPrivateChannel(request.channel, token: token, api: runtime.api)) == true) : false
                    // Recheck after the network suspension: revocation takes effect
                    // even for a reply already generated and journaled.
                    if !privateChannel || targets.first(where: { $0.id == request.sessionID })?.agent?.discordShareSessionInformation != true {
                        reply = "Session information was not shared: enable Share session information and use a private channel."
                        image = nil
                    }
                }
                guard targets.contains(where: { $0.id == request.sessionID && Self.permits(request, session: $0) }) || request.sessionID == nil else { continue }
                journal.requests[i].state = "sending"; try persist(store)
                let title = targets.first(where: { $0.id == request.sessionID })?.title ?? "Converse"
                let receipt = try await runtime.discordClient.post("[" + String(title.prefix(60)) + "] " + reply, channel: request.channel, token: token, api: runtime.api, replyingTo: request.id, nonce: request.id, image: image)
                journal.requests[i].receipt = receipt; journal.requests[i].state = "done"
                try persist(store)
                lastError = ""
            } catch {
                lastError = "reply delivery unconfirmed; check the channel before retrying"
                if let session = store.sessions.first(where: { $0.id == request.sessionID }) {
                    session.messages.append(Message(role: "notice", text: "Discord reply delivery is unconfirmed. Check the channel before repeating the request; Converse will not automatically repost it."))
                    session.agent?.attention = "Discord reply delivery unconfirmed; check the channel before retrying."
                    store.save()
                }
                // Keep the sending marker: no automatic retry, even if the
                // failure occurred after Discord accepted the message.
                try? persist(store)
            }
        }
    }
}
