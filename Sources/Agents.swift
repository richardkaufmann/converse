import AppKit
import Foundation
import Security

struct AgentConfig: Codable, Equatable {
    var settingsRevision: UInt64? = nil
    mutating func settingsChanged() { settingsRevision = min((settingsRevision ?? 0), UInt64.max - 1) + 1 }
    var objective = "Help me achieve the goals we agree on. Ask what success means, compare evidence with those goals, distinguish verified results from claims, and flag blockers. When research is available, identify the exact subject before searching: qualify ambiguous names with the project, owner, repository/domain, product category or other relevant context. Prefer official or primary sources, verify that each result is about the intended subject, and ignore unrelated namesakes. Use only public information in search queries, never private session text or secrets. If relevant evidence or a search tool is unavailable, say so instead of guessing."
    var repository = ""
    var hasRepository: Bool { !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var repositorySnapshot: AgentRepoSnapshot? { hasRepository && snapshot?.repository == repository ? snapshot : nil }
    var parkingLotTalkID: UUID? = nil
    var parkingLotRequiresReview: Bool? = nil
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
    var supportDefaultsVersion: Int? = nil
    var model = "muse-spark-1.3"
    var intervalSeconds: Double = 900
    var scheduleText: String? = nil
    var scheduleTimeZone: String? = nil
    var remainingRuns = 20
    // Legacy counter remains decodable for saved archives and older peers.
    // It no longer limits the number of scheduled activations.
    var maxTurnsPerLoop: Int? = nil
    var turnLimit: Int {
        get { maxTurnsPerLoop ?? max(1, remainingRuns) }
        set { maxTurnsPerLoop = newValue }
    }
    var scoreboardEveryLoops: Int? = nil
    var loopsSinceScoreboard: Int? = nil
    var enabled = false
    // Auto pacing: on for new agents; older archives decode nil (off).
    var autoPace: Bool? = true
    // Set on agents created with objective pacing defaults (Auto on, 72 h
    // maximum). Older archives decode nil and keep the 4 h maximum.
    var pacingDefaults: Int? = 1
    // Timing read from the objective, the objective hash it came from, and a
    // migrated schedule still waiting to be read.
    var pacingSpec: AgentPacingSpec? = nil
    var pacingObjectiveHash: String? = nil
    var pacingPending: Bool? = nil
    var autoPaceMinMinutes: Double? = nil
    var autoPaceMaxMinutes: Double? = nil
    var autoPaceReason: String? = nil
    var nextRunAt: Date? = nil
    var lastLoopAt: Date? = nil
    var attention = ""
    // Consecutive transient run failures (nil = none); a success resets it.
    var transientFailures: Int? = nil
    // "Paused: <reason> (<time>)" when the host paused the loop. It stays
    // visible through later manual runs until re-enabled or cleared.
    var pauseReason: String? = nil
    var artDirection: String? = nil
    var lastArtDirection: String? = nil
    var generateArt = true
    var fileTriggers: Bool? = nil
    var processedEvents: [UUID]? = nil
    var speak = false
    var discord = false
    var discordRead: Bool? = nil
    var discordChannelID: String? = nil
    var discordCursorChannel: String? = nil
    var discordLastMessageID: String? = nil
    var discordMentions: Bool? = nil
    var discordDefault: Bool? = nil
    var discordShareScoreboard: Bool? = nil
    var discordShareSessionInformation: Bool? = nil
    var discordMentionSince: Date? = nil
    var discordActiveRequestID: String? = nil
    var lastArtMood: String? = nil
    var lastArtAt: Date? = nil
    // Art throttle (nil = defaults) and the scoreboard the current art reflects.
    var artMinIntervalMinutes: Double? = nil
    var artMaxStaleHours: Double? = nil
    var lastArtScoreboard: AgentScoreboard? = nil
    // Numeric scoreboard values the current art reflects (percent trigger).
    var lastArtMetricValues: [String: Double]? = nil
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
        let seconds = Int(min(31536000, max(60, effectiveIntervalSeconds.isFinite ? effectiveIntervalSeconds : 900)))
        if seconds % 3600 == 0 { return "\(seconds / 3600) hr" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) sec"
    }
    func loopStatus(at now: Date, busy: Bool, queuePaused: Bool, pendingCount: Int) -> String {
        guard enabled else { return "Loop paused · automatic checks off" }
        if queuePaused { return "Loop on · queue paused" }
        if pendingCount > 0 && !busy { return "Loop on · waiting for \(pendingCount) queued message\(pendingCount == 1 ? "" : "s")" }
        guard let rule = try? scheduleRule(), let future = rule.next(after: now) else { return "Loop blocked · review schedule/calendar" }
        let schedule = scheduleText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "Loop on · " + (scheduleText ?? "")
            : rule.kind == .interval ? "Loop on · every " + intervalLabel : "Loop on · " + pacingSummary().components(separatedBy: " · ")[0].replacingOccurrences(of: "Runs ", with: "runs ")
        let next = max(nextRunAt ?? future, rule.permits(now) ? (nextRunAt ?? future) : future)
        if pacesAutomatically { return next > now ? autoPaceStatus(next: next, now: now, rule: rule) : "Auto · " + (busy ? "next check after this run" : "check due") }
        guard next > now else { return schedule + (busy ? " · next check after this run" : " · check due") }
        return schedule + " · next " + rule.nextRunLabel(next)
    }
    var canSchedule: Bool { enabled && turnLimit > 0 }
    // A not-yet-migrated text schedule still governs; otherwise the objective's.
    func scheduleRule() throws -> AgentSchedule {
        if let text = scheduleText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return try AgentSchedule.compile(interval: intervalSeconds, text: text, zone: scheduleTimeZone) }
        return try objectiveRule()
    }
    func nextScheduledRun(after date: Date) -> Date? { (try? scheduleRule())?.next(after: date) }
    mutating func restoreSchedule(at now: Date) throws {
        guard canSchedule else { return }
        let rule = try scheduleRule()
        // The saved deadline already reflects the last reserved check. Keep it,
        // including an overdue deadline: the normal tick coalesces missed runs.
        if nextRunAt == nil { nextRunAt = rule.next(after: lastLoopAt ?? lastRunAt ?? now) }
    }
    func due(at now: Date) -> Bool { canSchedule && (nextRunAt ?? now) <= now && (try? scheduleRule().permits(now)) == true }
    mutating func reserveRun(at now: Date) -> Bool {
        guard due(at: now) else { return false }
        lastLoopAt = now
        nextRunAt = nextScheduledRun(after: now)
        return true
    }
}

struct AgentActivationBudget {
    let limit: Int
    private(set) var used = 0
    mutating func consume() throws {
        guard (1...1000).contains(limit), used < limit else { throw AgentFailure.message("This activation reached its turn limit. The next scheduled loop gets a fresh limit.") }
        used += 1
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
    struct Issue: Codable, Equatable { var title: String; var url: String; var labels: [String]; var updatedAt: String; var summary: String }
    var recentOpenIssues: [Issue]? = nil
    var latestRelease: String? = nil
    var latestReleaseURL: String? = nil
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
    static let service = Bundle.main.object(forInfoDictionaryKey: "ConverseDemo") as? Bool == true ? "app.kaoslabs.Converse.Demo.Agent" : Bundle.main.object(forInfoDictionaryKey: "ConverseNUXPreview") as? Bool == true ? "app.kaoslabs.Converse.NUXPreview.Agent" : "app.kaoslabs.Converse.Agent"
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
    struct Tell: Decodable { var to: String; var text: String; var replyExpected: Bool?; var inReplyTo: String? }
    var reply: String
    var appControl: AppSupportCommand?
    var parkingLotEdits: ParkingLotEdits?
    var attention: String?
    var artPrompt: String?
    struct Recovery: Decodable { var target: String; var delivery: UUID }
    var recover: [Recovery]?
    var tell: [Tell]?
    var memory: String?
    var speechIntent: String?
    var discordImage: String?
    var notifyDiscord: String?
    var scoreboard: AgentScoreboard?
    var nextRunInMinutes: AgentLenientNumber?
    var paceReason: AgentLenientText?
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
    var cachedTokens: Int? = nil
    var observedAt = Date()
    var usage: AgentUsage { AgentUsage(input: inputTokens, cached: cachedTokens, output: outputTokens) }
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
        let (bytes, response) = try await send(url, body: body, key: key)
        return try checked(url, bytes: bytes, response: response)
    }
    private func send(_ url: URL, body: [String: Any]?, key: String?) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url); req.timeoutInterval = 180
        req.setValue("Converse", forHTTPHeaderField: "User-Agent")
        if let key, !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        if let body { req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try await request(req)
    }
    private func checked(_ url: URL, bytes: Data, response: HTTPURLResponse) throws -> (Any, HTTPURLResponse) {
        guard (200..<300).contains(response.statusCode) else {
            if url.host == "api.meta.ai", response.statusCode == 401 { throw AgentFailure.message("Meta rejected the API key (HTTP 401). Check or replace it in Agent Setup.") }
            if url.host == "api.meta.ai", response.statusCode == 403 { throw AgentFailure.message("Meta denied access (HTTP 403). Check this key’s model/account permissions.") }
            if url.host == "api.github.com" {
                if response.statusCode == 401 { throw AgentFailure.message("GitHub rejected the token (HTTP 401). Check or replace it in Agent Setup.") }
                if response.statusCode == 403 { throw AgentFailure.message("GitHub denied access or reached its rate limit (HTTP 403). Check token permissions or try again later.") }
                if response.statusCode == 404 { throw AgentFailure.message("GitHub could not find this repository, or the token cannot access it (HTTP 404). Check owner/name and repository permissions.") }
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
    static let outputTokenLimit = 8192
    static let promptCacheFields = ["prompt_cache_key", "prompt_cache_retention"]
    // Prompt-cache hints are additive. If the service rejects them once, this
    // client stops sending them instead of failing every later activation.
    private let cacheLock = NSLock()
    private var promptCacheRejected = false
    var sendsPromptCache: Bool { cacheLock.lock(); defer { cacheLock.unlock() }; return !promptCacheRejected }
    private func rejectPromptCache() { cacheLock.lock(); promptCacheRejected = true; cacheLock.unlock() }
    static func rejectsPromptCache(status: Int, body: Data) -> Bool {
        status == 400 && String(decoding: body.prefix(16384), as: UTF8.self).lowercased().contains("prompt_cache")
    }
    private func responses(_ body: [String: Any], key: String) async throws -> Any {
        let url = URL(string: "https://api.meta.ai/v1/responses")!
        guard body["prompt_cache_key"] != nil else { return try await json(url, body: body, key: key).0 }
        let (bytes, response) = try await send(url, body: body, key: key)
        guard Self.rejectsPromptCache(status: response.statusCode, body: bytes) else { return try checked(url, bytes: bytes, response: response).0 }
        rejectPromptCache()
        var plain = body; for field in Self.promptCacheFields { plain.removeValue(forKey: field) }
        return try await json(url, body: plain, key: key).0
    }
    func respond(model: String, instructions: String, input: String, key: String, images: [AgentInputImage] = [], webSearch: Bool = false, cacheKey: String? = nil, research: ((AgentResearch) -> Void)? = nil, observe: ((AgentResponseDiagnostic) -> Void)? = nil) async throws -> String {
        var body: [String: Any] = ["model": model, "instructions": instructions, "input": AgentPromptContext.visualInput(input, images: images), "max_output_tokens": Self.outputTokenLimit, "reasoning": ["effort": "low"], "store": false]
        if webSearch { body["tools"] = [["type": "web_search"]]; body["include"] = ["web_search_call.results"]; body["max_tool_calls"] = 4 }
        if let cacheKey, sendsPromptCache { body["prompt_cache_key"] = cacheKey; body["prompt_cache_retention"] = "24h" }
        let raw = try await responses(body, key: key)
        guard let response = raw as? [String: Any] else { throw AgentFailure.message("Agent service returned an invalid response. No actions applied.") }
        research?(AgentResearch.parse(response))
        let rawStatus = response["status"] as? String ?? "unknown"
        let status = ["completed", "incomplete", "failed", "cancelled", "queued", "in_progress"].contains(rawStatus) ? rawStatus : "unknown"
        let rawReason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String
        let reason = ["max_output_tokens", "content_filter"].contains(rawReason ?? "") ? rawReason : nil
        let usage = response["usage"] as? [String: Any], tokens = AgentUsage(response: response)
        observe?(AgentResponseDiagnostic(model: model, status: status, incompleteReason: reason, outputTokenLimit: Self.outputTokenLimit,
            inputTokens: tokens.input, outputTokens: tokens.output,
            reasoningTokens: (usage?["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int, cachedTokens: tokens.cached))
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
                let (raw, _) = try await get("search/issues?q=" + query + "&sort=updated&order=desc&per_page=" + (kind == 1 ? "30" : "1"))
                let obj = raw as? [String: Any]
                guard obj?["incomplete_results"] as? Bool != true else { throw AgentFailure.message("Incomplete search") }
                let count = obj?["total_count"] as? Int
                if kind == 1 {
                    snapshot.recentOpenIssues = (obj?["items"] as? [[String: Any]] ?? []).map { issue in
                        AgentRepoSnapshot.Issue(title: String((issue["title"] as? String ?? "").prefix(300)), url: issue["html_url"] as? String ?? "", labels: (issue["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }, updatedAt: issue["updated_at"] as? String ?? "", summary: String((issue["body"] as? String ?? "").prefix(1200)))
                    }
                    if (count ?? 0) > 30 { snapshot.notes.append("Issue details cover the 30 most recently updated open issues, not the full backlog.") }
                }
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
        do {
            let (raw, _) = try await get("repos/" + repository + "/releases/latest")
            snapshot.latestRelease = (raw as? [String: Any])?["tag_name"] as? String
            snapshot.latestReleaseURL = (raw as? [String: Any])?["html_url"] as? String
        } catch { snapshot.notes.append("Latest published release unavailable.") }
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
            intervalSeconds: intervalSeconds, remainingRuns: remainingRuns, maxTurnsPerLoop: turnLimit, enabled: enabled,
            generateArt: generateArt, speak: speak, discord: discord, fileTriggers: fileTriggers == true, revision: settingsRevision ?? 0, scoreboardEveryLoops: scoreboardCadence, scheduleText: scheduleText ?? "", scheduleTimeZone: scheduleTimeZone ?? TimeZone.current.identifier, discordShareScoreboard: discordShareScoreboard == true, discordShareSessionInformation: discordShareSessionInformation == true, artDirection: artDirection ?? "")
    }
    // Returns the transcript notice when a text schedule moved into the objective.
    @discardableResult mutating func apply(_ wire: DeviceAgentSettings) throws -> String? {
        guard (wire.revision ?? 0) == (settingsRevision ?? 0), (settingsRevision ?? 0) < UInt64.max else {
            throw AgentFailure.message("Agent settings or run budget changed. Reload settings before saving.")
        }
        let repository = wire.repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard repository.isEmpty || AgentRepoSnapshot.validRepository(repository), !wire.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, wire.model.utf8.count <= 200,
              wire.objective.utf8.count <= 16000, (wire.artDirection ?? "").utf8.count <= 4000, wire.watched.count <= 64, wire.watched.allSatisfy({ DeviceGlobalID($0) != nil }),
              wire.intervalSeconds.isFinite, (60...31536000).contains(wire.intervalSeconds), (1...1000).contains(wire.turnLimit), wire.scoreboardEveryLoops.map({ (1...1000).contains($0) }) ?? true else {
            throw AgentFailure.message("Invalid agent settings. Check scope, interval and run budget.")
        }
        if !(scheduleText ?? "").isEmpty && wire.scheduleText == nil {
            throw AgentFailure.message("This editor cannot preserve the text schedule. Update the viewing app before changing agent settings.")
        }
        // Validates the interval and zone; a text schedule becomes part of the objective.
        let zoneID = try AgentSchedule.compile(interval: wire.intervalSeconds, text: nil, zone: wire.scheduleTimeZone).zoneID
        let oldRule = try? scheduleRule()
        var next = self
        if wire.enabled && !enabled { next.clearPause() }
        next.settingsChanged()
        if next.repository != repository { next.snapshot = nil; next.loopsSinceScoreboard = 0 }
        next.objective = wire.objective; next.repository = repository; next.model = wire.model
        next.watchedParticipants = Array(Set(wire.watched)).sorted(); next.watchedSessions = []
        next.intervalSeconds = wire.intervalSeconds; next.scheduleText = wire.scheduleText; next.scheduleTimeZone = zoneID; next.turnLimit = wire.turnLimit; next.enabled = wire.enabled
        let notice = next.migrateScheduleText()
        if let cadence = wire.scoreboardEveryLoops { next.scoreboardEveryLoops = cadence }
        if let share = wire.discordShareScoreboard { next.discordShareScoreboard = share }
        if let share = wire.discordShareSessionInformation { next.discordShareSessionInformation = share }
        if let direction = wire.artDirection { next.artDirection = direction.trimmingCharacters(in: .whitespacesAndNewlines) }
        next.generateArt = wire.generateArt; next.speak = wire.speak; next.discord = wire.discord; next.fileTriggers = wire.fileTriggers
        let schedule = try next.scheduleRule()
        guard !wire.enabled || schedule.next(after: Date()) != nil else { throw AgentFailure.message("No future run is available. Review the schedule/calendar.") }
        let keepDeadline = enabled && wire.enabled && oldRule == schedule && nextRunAt != nil
        if !keepDeadline { next.nextRunAt = next.enabled ? schedule.next(after: Date()) : nil }
        self = next
        return notice
    }
}

// Art direction is separate from operational instructions and forwarded directly.
enum AgentArt {
    static func prompt(direction: String, scene: String?, mood: String) -> String {
        "Create a beautifully composed scoreboard illustration. No numerical data or captions; the app overlays those. Mood: " + mood + ". Owner art direction (takes precedence over suggested scene): " + direction + ". Suggested scene: " + String((scene ?? "An imaginative scene expressing current progress.").prefix(1800))
    }
}
