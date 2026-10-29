import AppKit
import Foundation
import Security

struct AgentConfig: Codable, Equatable {
    var settingsRevision: UInt64? = nil
    mutating func settingsChanged() { settingsRevision = min((settingsRevision ?? 0), UInt64.max - 1) + 1 }
    var objective = "Monitor this project. Ask what success means, compare actual progress with those goals, distinguish verified results from claims, and flag blockers."
    var repository = ""
    var hasRepository: Bool { !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var repositorySnapshot: AgentRepoSnapshot? { hasRepository && snapshot?.repository == repository ? snapshot : nil }
    var watchedSessions: [UUID] = []
    var watchedParticipants: [String]? = nil
    func allows(local id: UUID, home: String?) -> Bool {
        watchedSessions.contains(id) || home.map { watchedParticipants?.contains(DeviceGlobalID(home: $0, session: id).string) == true } == true
    }
    func allows(global: String, home: String?) -> Bool {
        guard let id = DeviceGlobalID(global) else { return false }
        return watchedParticipants?.contains(id.string) == true || (id.home == home && watchedSessions.contains(id.session))
    }
    var webSearch: Bool? = nil
    var jollyAllowed: Bool? = nil
    var jollyRequestID: String? = nil
    var scoreboard: AgentScoreboard? = nil
    var model = "muse-spark-1.3"
    var intervalSeconds: Double = 900
    var remainingRuns = 20
    var scoreboardEveryLoops: Int? = nil
    var loopsSinceScoreboard: Int? = nil
    var enabled = false
    var nextRunAt: Date? = nil
    var attention = ""
    var generateArt = true
    var fileTriggers: Bool? = nil
    var processedEvents: [UUID]? = nil
    var speak = false
    var discord = false
    var lastArtMood: String? = nil
    var lastArtAt: Date? = nil
    var snapshot: AgentRepoSnapshot? = nil
    var workingMemory: String? = nil
    var widgetSummary = "Tell me what you’re building and how you’ll judge success."
    var artPath: String? = nil
    var lastRunAt: Date? = nil
    var lastOutcome = "Not run yet"
    var scoreboardCadence: Int { min(1000, max(1, scoreboardEveryLoops ?? 1)) }
    func shouldRefreshScoreboard(loopTick: Bool) -> Bool {
        !loopTick || snapshot == nil || snapshot?.repository != repository || (loopsSinceScoreboard ?? 0) >= scoreboardCadence - 1
    }
    var intervalLabel: String {
        let seconds = Int(min(31536000, max(60, intervalSeconds.isFinite ? intervalSeconds : 900)))
        if seconds % 3600 == 0 { return "\(seconds / 3600) hr" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) sec"
    }
    func loopStatus(at now: Date, busy: Bool, queuePaused: Bool, pendingCount: Int) -> String {
        if remainingRuns <= 0 { return "Loop stopped · no automatic runs left" }
        guard enabled else { return "Loop paused · automatic checks off" }
        if queuePaused { return "Loop on · queue paused" }
        if pendingCount > 0 && !busy { return "Loop on · waiting for \(pendingCount) queued message\(pendingCount == 1 ? "" : "s")" }
        let schedule = "Loop on · every " + intervalLabel
        guard let nextRunAt, nextRunAt > now else { return schedule + (busy ? " · next check after this run" : " · check due") }
        return schedule + " · next " + nextRunAt.formatted(date: .omitted, time: .shortened)
    }
    var canSchedule: Bool { enabled && remainingRuns > 0 }
    func due(at now: Date) -> Bool { canSchedule && (nextRunAt ?? now) <= now }
    mutating func reserveRun(at now: Date) -> Bool {
        guard due(at: now) else { return false }
        settingsChanged()
        remainingRuns -= 1; nextRunAt = now.addingTimeInterval(max(60, intervalSeconds))
        if remainingRuns == 0 { enabled = false }
        return true
    }
}

struct AgentRepoSnapshot: Codable, Equatable {
    var repository: String
    var observedAt = Date()
    var stars: Int?
    var openPRs: Int?
    var openIssues: Int?
    var openBugs: Int?
    var conversationComments: Int?
    var releaseDownloads: Int?
    var visitors14d: Int?
    var notes: [String] = []
    var hasMeasurements: Bool {
        [stars, openPRs, openIssues, openBugs, conversationComments, releaseDownloads, visitors14d].contains { $0 != nil }
    }
    var metrics: [(String, String)] {
        [("Users", "Not measured"), ("Visitors · 14d", visitors14d.map(String.init) ?? "Unavailable"),
         ("Stars", stars.map(String.init) ?? "Unavailable"), ("Open PRs", openPRs.map(String.init) ?? "Unavailable"),
         ("Open issues", openIssues.map(String.init) ?? "Unavailable"), ("Bugs · label:bug", openBugs.map(String.init) ?? "Unavailable"),
         ("Conversation comments", conversationComments.map(String.init) ?? "Unavailable"), ("Release downloads", releaseDownloads.map(String.init) ?? "Unavailable")]
    }
    func mood(previous: AgentRepoSnapshot?) -> String {
        guard let bugs = openBugs else { return "unknown" }
        if let old = previous?.openBugs, bugs > old { return "urgent" }
        return bugs == 0 ? "peaceful" : "watchful"
    }
    static func validRepository(_ string: String) -> Bool {
        let parts = string.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.count <= 100 && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }
    }
}

// No secret is part of the Codable session or exported widget.
enum AgentSecrets {
    static let service = "app.kaoslabs.Converse.Agent"
    static func read(_ name: String) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw AgentFailure.message("Could not read the agent credential from Keychain.") }
        return value
    }
    static func delete(_ name: String) throws {
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AgentFailure.message("Could not remove the saved agent credential from Keychain.") }
    }
    static func update(_ name: String, value: String, remove: Bool,
                       write: (String, String) throws -> Void = AgentSecrets.write,
                       delete: (String) throws -> Void = AgentSecrets.delete) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if remove {
            guard value.isEmpty else { throw AgentFailure.message("Choose either replacement or removal for each credential.") }
            try delete(name)
        } else if !value.isEmpty { try write(name, value) }
    }
    static func write(_ name: String, value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData] = data; add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw AgentFailure.message("Could not save the agent credential to Keychain.") }; return
        }
        guard status == errSecSuccess else { throw AgentFailure.message("Could not update the agent credential in Keychain.") }
    }
}

enum AgentCredentialProbe {
    // Probes never save replacements or delete the currently saved credential.
    static func resolve(_ entered: String, name: String, read: (String) throws -> String? = AgentSecrets.read) throws -> String? {
        let entered = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = entered.isEmpty ? try read(name)?.trimmingCharacters(in: .whitespacesAndNewlines) : entered
        return value?.isEmpty == false ? value : nil
    }
}

enum AgentFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct AgentReply: Decodable {
    struct Tell: Decodable { var to: String; var text: String }
    var reply: String
    var attention: String?
    var artPrompt: String?
    var tell: [Tell]?
    var memory: String?
    var speechIntent: String?
    var notifyDiscord: String?
    var scoreboard: AgentScoreboard?
    static func decode(_ text: String) -> AgentReply? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```json\n"), value.hasSuffix("\n```") { value = String(value.dropFirst(8).dropLast(4)) }
        return try? JSONDecoder().decode(Self.self, from: Data(value.utf8))
    }
}

struct AgentResponseDiagnostic: Codable {
    var model: String
    var status: String
    var incompleteReason: String?
    var outputTokenLimit: Int
    var inputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var observedAt = Date()
}

// Shared fixed-host HTTPS client; errors deliberately omit response bodies,
// which may echo credentials or private prompts. Tests inject the transport.
final class AgentAPI {
    var request: (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentFailure.message("No HTTP response.") }
        return (data, http)
    }
    func json(_ url: URL, body: [String: Any]? = nil, key: String? = nil) async throws -> (Any, HTTPURLResponse) {
        var req = URLRequest(url: url); req.timeoutInterval = 180
        req.setValue("Converse", forHTTPHeaderField: "User-Agent")
        if let key, !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        if let body { req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (bytes, response) = try await request(req)
        guard (200..<300).contains(response.statusCode) else {
            if url.host == "api.meta.ai", response.statusCode == 401 { throw AgentFailure.message("Meta rejected the API key (HTTP 401). Check or replace it in Agent Setup.") }
            if url.host == "api.meta.ai", response.statusCode == 403 { throw AgentFailure.message("Meta denied access (HTTP 403). Check this key’s model/account permissions.") }
            if url.host == "api.github.com" {
                if response.statusCode == 401 { throw AgentFailure.message("GitHub rejected the token (HTTP 401). Check or replace it in Agent Setup.") }
                if response.statusCode == 403 { throw AgentFailure.message("GitHub denied access or reached its rate limit (HTTP 403). Check token permissions or try again later.") }
                if response.statusCode == 404 { throw AgentFailure.message("GitHub could not find this repository, or the token cannot access it (HTTP 404). Check owner/name and repository permissions.") }
            }
            if url.host == "discord.com" {
                if [401, 403].contains(response.statusCode) { throw AgentFailure.message("Discord denied webhook access (HTTP \(response.statusCode)). Check or replace the webhook in Agent Setup.") }
                if response.statusCode == 404 { throw AgentFailure.message("Discord could not find this webhook (HTTP 404). It may have been deleted; copy a new webhook URL from Discord.") }
                if response.statusCode == 429 { throw AgentFailure.message("Discord is rate limiting this webhook (HTTP 429). Wait before testing again.") }
            }
            throw AgentFailure.message("\(url.host ?? "Service") returned HTTP \(response.statusCode).")
        }
        guard bytes.count <= 32_000_000 else { throw AgentFailure.message("Service response too large.") }
        return (bytes.isEmpty ? [:] : try JSONSerialization.jsonObject(with: bytes), response)
    }
    func testGitHub(repository: String, token: String?) async throws -> String {
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard repository.isEmpty || AgentRepoSnapshot.validRepository(repository) else { throw AgentFailure.message("Enter a GitHub repository as owner/name, or leave it blank.") }
        do {
            let authenticated = token?.isEmpty == false
            if authenticated {
                let (user, _) = try await json(URL(string: "https://api.github.com/user")!, key: token)
                guard (user as? [String: Any])?["id"] as? Int != nil else { throw AgentFailure.message("GitHub returned an invalid token verification response.") }
            }
            guard !repository.isEmpty else { return authenticated ? "GitHub token accepted. No repository configured; repository checks skipped." : "GitHub is optional. No repository or token configured; nothing to test." }
            let (raw, _) = try await json(URL(string: "https://api.github.com/repos/" + repository)!, key: token)
            guard (raw as? [String: Any])?["id"] as? Int != nil else { throw AgentFailure.message("GitHub returned an invalid repository response.") }
            guard authenticated else { return "No token: public repository metadata is readable. Add a token with traffic access for visitor metrics. Nothing was changed." }
            var traffic = false
            do {
                let (raw, _) = try await json(URL(string: "https://api.github.com/repos/" + repository + "/traffic/views")!, key: token)
                traffic = ((raw as? [String: Any])?["uniques"] as? Int).map { $0 >= 0 } == true
            } catch { /* Token/repository success remains useful when optional traffic access is denied. */ }
            return traffic ? "GitHub token accepted; repository metadata and visitor metrics are readable. Nothing was changed." : "GitHub token accepted; repository metadata is readable. Visitor metrics unavailable: check repository traffic access (Administration: read for a fine-grained token). Nothing was changed."
        } catch let error as AgentFailure { throw error }
        catch { throw AgentFailure.message("Could not complete the GitHub test. Check the network and try again.") }
    }
    func sendDiscord(_ text: String, webhook: String) async throws {
        // Accept only Discord's executable webhook endpoint, never an arbitrary URL.
        guard var components = URLComponents(string: webhook), components.scheme == "https", components.host == "discord.com",
              components.user == nil, components.password == nil, components.fragment == nil,
              components.port == nil || components.port == 443,
              components.percentEncodedPath.range(of: "^/api/(v[0-9]+/)?webhooks/[0-9]+/[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              (components.queryItems ?? []).allSatisfy({ $0.name == "wait" || ($0.name == "thread_id" && $0.value?.allSatisfy(\.isNumber) == true && $0.value?.isEmpty == false) }) else {
            throw AgentFailure.message("Enter a Discord webhook URL copied from the channel’s Integrations settings.")
        }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "wait" } + [URLQueryItem(name: "wait", value: "true")]
        guard let url = components.url else { throw AgentFailure.message("Enter a valid Discord webhook URL.") }
        do {
            let (raw, _) = try await json(url, body: ["content": String(text.prefix(1800)), "allowed_mentions": ["parse": []]])
            guard let id = (raw as? [String: Any])?["id"] as? String, !id.isEmpty else { throw AgentFailure.message("Discord did not confirm message delivery. Check the channel before retrying.") }
        } catch let error as AgentFailure { throw error }
        catch { throw AgentFailure.message("Could not confirm Discord delivery. Check the channel and network before retrying.") }
    }
    func testDiscord(webhook: String) async throws -> String {
        try await sendDiscord("Converse connection test — this webhook is working. No session content is included.", webhook: webhook)
        return "Discord confirmed the test message. Check the webhook’s channel; no session content was sent."
    }
    static let outputTokenLimit = 8192
    func respond(model: String, instructions: String, input: String, key: String, webSearch: Bool = false, research: ((AgentResearch) -> Void)? = nil, observe: ((AgentResponseDiagnostic) -> Void)? = nil) async throws -> String {
        var body: [String: Any] = ["model": model, "instructions": instructions, "input": input, "max_output_tokens": Self.outputTokenLimit, "reasoning": ["effort": "low"], "store": false]
        if webSearch { body["tools"] = [["type": "web_search"]]; body["include"] = ["web_search_call.results"]; body["max_tool_calls"] = 4 }
        let (raw, _) = try await json(URL(string: "https://api.meta.ai/v1/responses")!, body: body, key: key)
        guard let response = raw as? [String: Any] else { throw AgentFailure.message("Agent service returned an invalid response. No actions applied.") }
        research?(AgentResearch.parse(response))
        let rawStatus = response["status"] as? String ?? "unknown"
        let status = ["completed", "incomplete", "failed", "cancelled", "queued", "in_progress"].contains(rawStatus) ? rawStatus : "unknown"
        let rawReason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String
        let reason = ["max_output_tokens", "content_filter"].contains(rawReason ?? "") ? rawReason : nil
        let usage = response["usage"] as? [String: Any]
        observe?(AgentResponseDiagnostic(model: model, status: status, incompleteReason: reason, outputTokenLimit: Self.outputTokenLimit,
            inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int,
            reasoningTokens: (usage?["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int))
        guard status == "completed" else {
            if reason == "max_output_tokens" { throw AgentFailure.message("Agent hit its response limit (\(Self.outputTokenLimit) tokens including reasoning). No actions applied. Try fewer watched sessions or a shorter request, then Run once.") }
            if reason == "content_filter" { throw AgentFailure.message("The model service stopped this response under its content policy. No actions applied.") }
            throw AgentFailure.message("Agent response stopped before completion (\(status)). No actions applied. The loop is paused; try Run once.")
        }
        // Hosted search can emit progress messages before its final answer.
        // Only the final message is actionable; never splice commentary into JSON.
        let messages = (response["output"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "message" }
        let final = messages.last { $0["phase"] as? String == "final_answer" } ?? messages.last
        let text = (final?["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else { throw AgentFailure.message("Agent returned no answer.") }; return text
    }
    func art(prompt: String, key: String) async throws -> Data {
        let (raw, _) = try await json(URL(string: "https://api.meta.ai/v1/images/generations")!, body: ["model": "muse-image-1.0", "prompt": prompt, "n": 1, "output_format": "png", "response_format": "b64_json", "size": "1536x1024"], key: key)
        guard let root = raw as? [String: Any], let item = (root["data"] as? [[String: Any]])?.first, let b64 = item["b64_json"] as? String, let bytes = Data(base64Encoded: b64), bytes.count <= 8_000_000, let image = NSBitmapImageRep(data: bytes), image.pixelsWide <= 4096, image.pixelsHigh <= 4096,
              let png = image.representation(using: .png, properties: [:]) else { throw AgentFailure.message("Image service returned an unsupported or oversized image.") }
        return png
    }
    func metrics(repository: String, token: String?) async -> AgentRepoSnapshot {
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        var snapshot = AgentRepoSnapshot(repository: repository)
        guard !repository.isEmpty else { return snapshot }
        guard AgentRepoSnapshot.validRepository(repository) else { snapshot.notes = ["Set a repository as owner/name."]; return snapshot }
        func get(_ path: String) async throws -> (Any, HTTPURLResponse) { try await json(URL(string: "https://api.github.com/" + path)!, key: token) }
        do {
            let (raw, _) = try await get("repos/" + repository)
            snapshot.stars = (raw as? [String: Any])?["stargazers_count"] as? Int
        } catch { snapshot.notes.append("Repository metadata unavailable.") }
        for (filter, kind) in [("is:pr is:open", 0), ("is:issue is:open", 1), ("is:issue is:open label:bug", 2)] {
            do {
                let query = ("repo:" + repository + " " + filter).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&?#")))!
                let (raw, _) = try await get("search/issues?q=" + query + "&per_page=1")
                let obj = raw as? [String: Any]
                guard obj?["incomplete_results"] as? Bool != true else { throw AgentFailure.message("Incomplete search") }
                let count = obj?["total_count"] as? Int
                if kind == 0 { snapshot.openPRs = count }; if kind == 1 { snapshot.openIssues = count }; if kind == 2 { snapshot.openBugs = count }
            } catch { snapshot.notes.append("An issue/PR count is unavailable.") }
        }
        do {
            let (raw, response) = try await get("repos/" + repository + "/issues/comments?per_page=1")
            guard let items = raw as? [[String: Any]] else { throw AgentFailure.message("Invalid comments response") }
            let link = response.value(forHTTPHeaderField: "Link") ?? ""
            let last = link.components(separatedBy: ",").first { $0.contains("rel=\"last\"") }?.components(separatedBy: ";").first?.trimmingCharacters(in: CharacterSet(charactersIn: " <>"))
            snapshot.conversationComments = last.flatMap { URLComponents(string: $0)?.queryItems?.first { $0.name == "page" }?.value }.flatMap(Int.init) ?? items.count
        } catch { snapshot.notes.append("Conversation comment count unavailable.") }
        do {
            var count = 0, complete = false
            for page in 1...10 {
                let (raw, _) = try await get("repos/" + repository + "/releases?per_page=100&page=\(page)")
                guard let releases = raw as? [[String: Any]] else { throw AgentFailure.message("Invalid releases") }
                count += releases.flatMap { $0["assets"] as? [[String: Any]] ?? [] }.reduce(0) { $0 + ($1["download_count"] as? Int ?? 0) }
                if releases.count < 100 { complete = true; break }
            }
            if complete { snapshot.releaseDownloads = count } else { snapshot.notes.append("Download count unavailable: release pagination limit reached.") }
        } catch { snapshot.notes.append("Release downloads unavailable.") }
        if let token, !token.isEmpty {
            do { let (raw, _) = try await get("repos/" + repository + "/traffic/views"); snapshot.visitors14d = (raw as? [String: Any])?["uniques"] as? Int }
            catch { snapshot.notes.append("Visitors require GitHub repository traffic access.") }
        } else { snapshot.notes.append("Add a GitHub token in Agent Setup for private traffic metrics and higher rate limits.") }
        return snapshot
    }
}

extension AgentConfig {
    func wire(home: String) -> DeviceAgentSettings {
        DeviceAgentSettings(objective: objective, repository: repository, model: model,
            watched: Array(Set((watchedParticipants ?? []) + watchedSessions.map { DeviceGlobalID(home: home, session: $0).string })).sorted(),
            intervalSeconds: intervalSeconds, remainingRuns: remainingRuns, enabled: enabled,
            generateArt: generateArt, speak: speak, discord: discord, fileTriggers: fileTriggers == true, revision: settingsRevision ?? 0, scoreboardEveryLoops: scoreboardCadence)
    }
    mutating func apply(_ wire: DeviceAgentSettings) throws {
        guard (wire.revision ?? 0) == (settingsRevision ?? 0), (settingsRevision ?? 0) < UInt64.max else {
            throw AgentFailure.message("Agent settings or run budget changed. Reload settings before saving.")
        }
        let repository = wire.repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard repository.isEmpty || AgentRepoSnapshot.validRepository(repository), !wire.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, wire.model.utf8.count <= 200,
              wire.objective.utf8.count <= 16000, wire.watched.count <= 64, wire.watched.allSatisfy({ DeviceGlobalID($0) != nil }),
              wire.intervalSeconds.isFinite, (60...31536000).contains(wire.intervalSeconds), (0...1000).contains(wire.remainingRuns), wire.scoreboardEveryLoops.map({ (1...1000).contains($0) }) ?? true else {
            throw AgentFailure.message("Invalid agent settings. Check scope, interval and run budget.")
        }
        settingsChanged()
        if self.repository != repository { snapshot = nil; loopsSinceScoreboard = 0 }
        objective = wire.objective; self.repository = repository; model = wire.model
        watchedParticipants = Array(Set(wire.watched)).sorted(); watchedSessions = []
        intervalSeconds = wire.intervalSeconds; remainingRuns = wire.remainingRuns; enabled = wire.enabled && wire.remainingRuns > 0
        if let cadence = wire.scoreboardEveryLoops { scoreboardEveryLoops = cadence }
        generateArt = wire.generateArt; speak = wire.speak; discord = wire.discord; fileTriggers = wire.fileTriggers
        nextRunAt = Date().addingTimeInterval(intervalSeconds)
    }
}
