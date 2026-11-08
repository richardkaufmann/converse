import AppKit
import CryptoKit
import Foundation

// Portraits are art, on demand only. Nothing generates one unless a person,
// session, agent, Jolly or Discord asks, or a View → Portraits window is open.
// Cache by meaningful assessment content and art direction, never revision;
// join matching requests; keep failures quiet and never block an agent loop.

struct AgentPortraitRecord: Codable, Equatable {
    struct Image: Codable, Equatable {
        var path: String
        var cacheKey: String
        var sourceRevision: Int
        var sourceHash: String
        var assessedAt: Date?
        var generatedAt: Date
        var directionVersion: String
    }
    var latest: Image? = nil
    var lastAttemptAt: Date? = nil
    var failure: String? = nil
    var failedAt: Date? = nil
    var failures: Int? = nil
    var retryAt: Date? = nil
}

enum PortraitOrigin: String { case menu, window, session, agent, jolly, discord }
enum PortraitReply {
    /// Show the image and caption in the requesting session's transcript.
    case inline(Session)
    /// Show it in the portrayed agent's own transcript.
    case transcript
    case none
}

struct PortraitOutcome {
    var agent: String
    var image: AgentPortraitRecord.Image?
    var png: Data?
    var stale: Bool
    var cached: Bool
    var note: String?
    var error: String?
    var caption: String
}

enum PortraitPrompt {
    /// Bump when the template changes so cached art is regenerated once.
    static let templateVersion = 2
    static let composition = "Create a square artwork expressing this particular agent and its work. Follow the owner’s chosen subject, medium, palette and composition. A portrait can be a place, object, abstract composition or scene; it need not depict a person. Do not impose a shared fleet style, mascot, uniform or head-and-shoulders framing. When direction is absent, derive a distinctive visual subject from this agent’s objective."
    static let noFacts = "Do not draw factual numbers, scores, scoreboards, measured charts or dashboards; facts live in the app's table, not in the art. Never invent factual labels or captions."
    static let stylisticText = "Stylistic lettering is allowed only as the owner's art direction asks; never factual numbers or scoreboards."
    static func allowsStylisticText(_ direction: String) -> Bool {
        direction.range(of: #"(?i)\b(text|letter(ing|s)?|words?|sign(age)?|title|caption|logo|typograph\w*|name\s+(on|in))\b"#, options: .regularExpression) != nil
    }
    static func directionVersion(_ direction: String?) -> String {
        let normalized = (direction ?? "").lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return "v\(templateVersion)-" + SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
    }
    static func objectiveLine(_ objective: String) -> String {
        String(objective.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
    }
    static func moodWords(_ assessment: AgentAssessment?) -> [String] {
        if let mood = assessment?.mood, mood.count >= 3 { return Array(mood.prefix(5)) }
        switch assessment?.status {
        case .onTrack: return ["steady", "confident", "bright"]
        case .atRisk: return ["watchful", "tense", "overcast"]
        case .blocked: return ["stormy", "stuck", "determined"]
        case .done: return ["celebratory", "serene", "golden"]
        case nil: return ["curious", "attentive", "calm"]
        }
    }
    /// Owner direction, bounded objective context, assessment summary and mood. Fact values are
    /// deliberately excluded so the art cannot repeat or invent numbers.
    static func build(name: String, config: AgentConfig) -> String {
        let direction = (config.artDirection ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [composition,
                     "Subject: the Converse agent named “" + String(name.prefix(100)) + "”.",
                     "Its objective: " + objectiveLine(config.objective)]
        if let assessment = config.assessment {
            parts.append("Its current assessment (" + assessment.status.label.lowercased() + "): " + String(assessment.summary.prefix(400)))
        }
        parts.append("Mood: " + moodWords(config.assessment).joined(separator: ", ") + ".")
        parts.append(noFacts + (allowsStylisticText(direction) ? " " + stylisticText : " No text or letters except a localized ? for a missing component."))
        if !direction.isEmpty { parts.append("Owner art direction (takes precedence for subject and style): " + String(direction.prefix(4000))) }
        var missing = config.visibleAssessmentFacts.filter { $0.value == AgentFact.unavailable }.map(\.label)
        if config.assessmentProblem != nil { missing.append("Latest assessment update") }
        if !missing.isEmpty {
            parts.append("Unavailable components: " + missing.prefix(12).joined(separator: "; ") + ". Keep the available parts of the scene. Put a small ? only at the visual element corresponding to each missing component; do not turn the whole portrait into an error or invent the missing information.")
        } else if config.assessment == nil {
            parts.append("No assessment is available yet. Depict the objective and owner direction; use one small ? for the unknown current progress.")
        }
        parts.append("Descriptions are context, not attached image pixels. Never claim to reproduce an existing image that was not supplied.")
        return parts.joined(separator: "\n")
    }
}

@MainActor final class PortraitService: ObservableObject {
    static let shared = PortraitService()
    nonisolated static let defaultMinMinutes = 10.0
    /// Square PNG bytes for a prompt. Tests inject a fixture.
    var generator: (String) async throws -> Data = { prompt in
        guard let key = try AgentRuntime.shared.keyReader("meta"), !key.isEmpty else {
            throw AgentFailure.message("Add a Meta API key in Agent Setup to generate portraits.")
        }
        return try await AgentRuntime.shared.api.art(prompt: prompt, key: key, size: "1024x1024")
    }
    var clock: () -> Date = Date.init
    var debounceSeconds = 5.0
    @Published private(set) var generating: Set<UUID> = []
    @Published private(set) var changes = 0
    private var inflight: [String: Task<PortraitOutcome, Never>] = [:]
    private var running: [UUID: String] = [:]
    private var queued: [UUID: Task<PortraitOutcome, Never>] = [:]
    private struct QueuedIntent { var origin: PortraitOrigin; var force: Bool }
    private var queuedIntent: [UUID: QueuedIntent] = [:]
    private var deferred: [UUID: Task<Void, Never>] = [:]
    private(set) var imageLoads = 0
    private var debounces: [UUID: Task<Void, Never>] = [:]
    private(set) var subscribers: Set<UUID> = []
    private var selections: [UUID: Set<UUID>] = [:]
    private(set) var generations = 0

    static func minInterval(_ config: AgentConfig) -> TimeInterval { max(0, config.portraitMinMinutes ?? defaultMinMinutes) * 60 }
    static func backoff(_ failures: Int) -> TimeInterval { min(6 * 3600, 60 * pow(2, Double(max(0, failures - 1)))) }
    static func cacheKey(agent: UUID, config: AgentConfig) -> String {
        agent.uuidString + ":" + (config.assessment?.contentHash ?? "none") + ":" + PortraitPrompt.directionVersion(config.artDirection) + ":" + PortraitPrompt.directionVersion(config.objective) + ":" + PortraitPrompt.directionVersion(config.assessmentProblem?.reason) + ":" + PortraitPrompt.directionVersion(config.visibleAssessmentFacts.map(\.id).joined(separator: ","))
    }
    func isGenerating(_ id: UUID) -> Bool { generating.contains(id) }
    func hasDeferred(_ id: UUID) -> Bool { deferred[id] != nil }
    func caption(agent: String, image: AgentPortraitRecord.Image?, stale: Bool) -> String {
        guard let image else { return "Portrait of " + agent + " · unavailable" }
        let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd HH:mm zzz"; format.locale = Locale(identifier: "en_US_POSIX")
        let assessed = image.sourceRevision > 0 ? "assessment rev \(image.sourceRevision) · " + (image.assessedAt.map(format.string) ?? "time unknown") : "no assessment yet"
        return "Portrait of " + agent + " · " + assessed + " · #" + String(image.sourceHash.prefix(8)) + (stale ? " · stale" : " · current")
    }
    private func load(_ image: AgentPortraitRecord.Image?, agent: UUID, store: Store) -> Data? {
        guard let image else { return nil }
        imageLoads += 1
        let root = store.folder.appendingPathComponent("Agents/" + agent.uuidString).resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let file = URL(fileURLWithPath: image.path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root), let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8_000_000,
              let bytes = try? Data(contentsOf: file), NSBitmapImageRep(data: bytes) != nil else { return nil }
        return bytes
    }
    private func outcome(_ session: Session, store: Store, cached: Bool, note: String? = nil, error: String? = nil, loadPNG: Bool = true, loadedPNG: Data? = nil) -> PortraitOutcome {
        let config = session.agent ?? AgentConfig()
        let image = config.portrait?.latest
        let png = loadPNG ? (loadedPNG ?? load(image, agent: session.id, store: store)) : nil
        let stale = image.map { $0.cacheKey != Self.cacheKey(agent: session.id, config: config) } ?? false
        let shown = loadPNG && png == nil ? nil : image
        return PortraitOutcome(agent: session.title, image: shown, png: png, stale: stale, cached: cached, note: note,
                               error: shown == nil ? (error ?? config.portrait?.failure ?? "No portrait yet.") : error,
                               caption: caption(agent: session.title, image: shown, stale: stale))
    }

    /// The single entry point. Never throws and never touches the agent's loop.
    @discardableResult func request(_ session: Session, store: Store, origin: PortraitOrigin, reply: PortraitReply = .none, force: Bool = false) async -> PortraitOutcome {
        let result = await obtain(session, store: store, origin: origin, force: force)
        deliver(result, for: session, reply: reply, store: store)
        return result
    }
    private func obtain(_ session: Session, store: Store, origin: PortraitOrigin, force: Bool) async -> PortraitOutcome {
        guard let config = session.agent, store.sessions.contains(where: { $0 === session }) else {
            return PortraitOutcome(agent: session.title, image: nil, png: nil, stale: false, cached: false, note: nil, error: "Not an agent.", caption: "Portrait unavailable: not an agent")
        }
        let key = Self.cacheKey(agent: session.id, config: config)
        if !force, config.portrait?.latest?.cacheKey == key {
            // Visibility notifications need metadata only. Never read/decode PNGs on uncover.
            if origin == .window { return outcome(session, store: store, cached: true, loadPNG: false) }
            if let bytes = load(config.portrait?.latest, agent: session.id, store: store) {
                return outcome(session, store: store, cached: true, loadedPNG: bytes)
            }
        }
        if let task = inflight[key] { return await task.value }
        if let current = running[session.id], current != key {
            // The assessment changed mid-generation. That result keeps its own
            // source revision; the latest demanded content is queued behind it.
            if let task = queued[session.id] {
                if origin != .window { queuedIntent[session.id]?.origin = origin }
                if force { queuedIntent[session.id]?.force = true }
                return await task.value
            }
            let task = Task { @MainActor [weak self] () -> PortraitOutcome in
                guard let self else { return PortraitOutcome(agent: session.title, image: nil, png: nil, stale: false, cached: false, note: nil, error: "Portraits stopped.", caption: "") }
                if let earlier = self.inflight[current] { _ = await earlier.value }
                self.queued[session.id] = nil
                let intent = self.queuedIntent.removeValue(forKey: session.id) ?? QueuedIntent(origin: origin, force: force)
                if intent.origin == .window && !self.isDemanded(session.id) { return self.outcome(session, store: store, cached: true, loadPNG: false) }
                return await self.obtain(session, store: store, origin: intent.origin, force: intent.force)
            }
            queuedIntent[session.id] = QueuedIntent(origin: origin, force: force)
            queued[session.id] = task
            return await task.value
        }
        let now = clock()
        if !force, let record = config.portrait {
            if let retry = record.retryAt, retry > now {
                return outcome(session, store: store, cached: true, note: "Couldn't refresh: " + (record.failure ?? "failed") + ". Retrying after " + AgentPacing.relative(retry.timeIntervalSince(now)) + "; Refresh retries now.", loadPNG: origin != .window)
            }
            if let last = record.lastAttemptAt, now.timeIntervalSince(last) < Self.minInterval(config) {
                let allowed = last.addingTimeInterval(Self.minInterval(config))
                if origin == .window && isDemanded(session.id) { scheduleDeferred(session, store: store, at: allowed) }
                return outcome(session, store: store, cached: true, note: "Refreshes at most every " + AgentPacing.minutesText(Self.minInterval(config) / 60) + " min; showing the latest portrait.", loadPNG: origin != .window)
            }
        }
        // An immediate explicit refresh supersedes any timer for this agent.
        deferred.removeValue(forKey: session.id)?.cancel()
        return await generate(session, store: store, key: key)
    }
    private func generate(_ session: Session, store: Store, key: String) async -> PortraitOutcome {
        let config = session.agent ?? AgentConfig()
        let prompt = PortraitPrompt.build(name: session.title, config: config)
        let source = (revision: config.assessment?.revision ?? 0, hash: config.assessment?.contentHash ?? "none", at: config.assessment?.updatedAt,
                      direction: PortraitPrompt.directionVersion(config.artDirection))
        let started = clock()
        session.agent?.portrait = { var record = config.portrait ?? AgentPortraitRecord(); record.lastAttemptAt = started; return record }()
        running[session.id] = key; generating.insert(session.id); generations += 1
        let task = Task { @MainActor [weak self] () -> PortraitOutcome in
            guard let self else { return PortraitOutcome(agent: session.title, image: nil, png: nil, stale: false, cached: false, note: nil, error: "Portraits stopped.", caption: "") }
            var failure: String?
            var image: AgentPortraitRecord.Image?
            do {
                let bytes = try await self.generator(prompt)
                guard bytes.count <= 8_000_000, let bitmap = NSBitmapImageRep(data: bytes), bitmap.pixelsWide <= 4096, bitmap.pixelsHigh <= 4096,
                      let png = bitmap.representation(using: .png, properties: [:]) else { throw AgentFailure.message("The image service returned an unsupported image.") }
                guard store.sessions.contains(where: { $0 === session }) else { throw AgentFailure.message("The agent was closed.") }
                let folder = store.folder.appendingPathComponent("Agents/" + session.id.uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("portrait-" + DeviceBlob.sha256Hex(png).prefix(16) + ".png")
                try png.write(to: file, options: .atomic)
                image = AgentPortraitRecord.Image(path: file.path, cacheKey: key, sourceRevision: source.revision, sourceHash: source.hash,
                                                  assessedAt: source.at, generatedAt: self.clock(), directionVersion: source.direction)
            } catch { failure = (error as? AgentFailure)?.localizedDescription ?? "The image request failed." }
            self.running[session.id] = nil; self.inflight[key] = nil; self.generating.remove(session.id)
            if store.sessions.contains(where: { $0 === session }) {
                var record = session.agent?.portrait ?? AgentPortraitRecord()
                if let image {
                    let previous = record.latest
                    record.latest = image; record.failure = nil; record.failedAt = nil; record.failures = nil; record.retryAt = nil
                    if let previous, previous.path != image.path { try? FileManager.default.removeItem(atPath: previous.path) }
                } else if let failure {
                    let count = (record.failures ?? 0) + 1
                    record.failure = failure; record.failedAt = self.clock(); record.failures = count
                    record.retryAt = self.clock().addingTimeInterval(Self.backoff(count))
                }
                session.agent?.portrait = record
                store.save()
            }
            self.changes += 1
            return self.outcome(session, store: store, cached: false, error: failure.map { "Couldn't refresh: " + $0 })
        }
        inflight[key] = task
        return await task.value
    }
    private func scheduleDeferred(_ session: Session, store: Store, at date: Date) {
        guard deferred[session.id] == nil else { return }
        let delay = max(0, date.timeIntervalSince(clock()))
        let task = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, let session, !Task.isCancelled else { return }
            self.deferred[session.id] = nil
            guard self.isDemanded(session.id) else { return }
            _ = await self.obtain(session, store: store, origin: .window, force: false)
        }
        deferred[session.id] = task
    }
    private func deliver(_ result: PortraitOutcome, for session: Session, reply: PortraitReply, store: Store) {
        let target: Session
        switch reply {
        case .none: return
        case .transcript: target = session
        case .inline(let requester): target = requester
        }
        guard store.sessions.contains(where: { $0 === target }) else { return }
        guard let png = result.png else {
            target.messages.append(Message(role: "notice", text: "Portrait of " + session.title + " unavailable: " + (result.error ?? "no image")))
            store.save(); return
        }
        // A copy in the requester's managed outputs, like any inline image,
        // so it survives the portrait cache and reaches remote viewers.
        let folder = store.responseImageFolder(target)
        let file = folder.appendingPathComponent("Portrait-" + DeviceBlob.sha256Hex(png) + ".png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: file.path) { try png.write(to: file, options: .atomic) }
            target.messages.append(Message(role: "notice", text: result.caption + (result.note.map { "\n" + $0 } ?? ""), images: [file.path]))
        } catch { target.messages.append(Message(role: "notice", text: "Portrait of " + session.title + " could not be saved here.")) }
        store.save(); store.objectWillChange.send()
    }

    // MARK: View → Portraits demand

    /// An open Portraits window. While any is open, agent turns request
    /// portraits (debounced); closing the last one ends automatic demand.
    func subscribe(_ token: UUID, store: Store, agents: Set<UUID>? = nil) {
        subscribers.insert(token)
        selections[token] = agents ?? Set(store.sessions.filter { $0.agent != nil }.map(\.id))
        for session in store.sessions where selections[token]?.contains(session.id) == true && session.agent != nil {
            Task { @MainActor in
                guard self.isDemanded(session.id) else { return }
                await self.request(session, store: store, origin: .window)
            }
        }
    }
    func isDemanded(_ agent: UUID) -> Bool { selections.values.contains { $0.contains(agent) } }
    func unsubscribe(_ token: UUID) {
        subscribers.remove(token); selections[token] = nil
        for id in Array(debounces.keys) where !isDemanded(id) { debounces.removeValue(forKey: id)?.cancel() }
        for id in Array(deferred.keys) where !isDemanded(id) { deferred.removeValue(forKey: id)?.cancel() }
    }
    /// Called after every agent turn. Without an open window this does nothing.
    func agentTurned(_ session: Session, store: Store) {
        guard isDemanded(session.id), session.agent != nil else { return }
        debounces[session.id]?.cancel()
        let delay = debounceSeconds
        debounces[session.id] = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, let session, !Task.isCancelled, self.isDemanded(session.id) else { return }
            self.debounces[session.id] = nil
            await self.request(session, store: store, origin: .window)
        }
    }
    var pendingDebounces: Int { debounces.count }

    /// "get me a portrait of KAOS Steward", "portrait of the News Checker please".
    static func isRequest(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(self[- ]?)?portraits?\b"#, options: .regularExpression) != nil
    }
}

extension AgentConfig {
    var portraitMinutes: Double { portraitMinMinutes ?? PortraitService.defaultMinMinutes }
}

/// Isolated portrait edits preserve live loop state and reject concurrent edits.
enum AgentPortraitSettings {
    static func onlyPortraitChanged(from old: AgentConfig, to edited: AgentConfig) -> Bool {
        var copy = edited
        copy.artDirection = old.artDirection; copy.portraitMinMinutes = old.portraitMinMinutes
        return copy == old && (edited.artDirection != old.artDirection || edited.portraitMinMinutes != old.portraitMinMinutes)
    }
    static func applying(_ edited: AgentConfig, baseline: AgentConfig, current: AgentConfig) throws -> AgentConfig {
        guard onlyPortraitChanged(from: baseline, to: edited), baseline.settingsRevision == current.settingsRevision else {
            throw AgentFailure.message("Agent settings changed. Reload settings and try again.")
        }
        let direction = (edited.artDirection ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard direction.utf8.count <= 4000 else { throw AgentFailure.message("Art direction must be at most 4000 bytes.") }
        var result = current
        result.artDirection = direction
        try result.setPortraitInterval(minutes: edited.portraitMinutes)
        result.settingsChanged()
        return result
    }
}
