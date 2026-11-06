import Foundation
import CryptoKit

// Diagnostic metadata is separate from recoverable private configuration snapshots.
// Never log configuration values, transcript text, commands, credentials or titles.
final class ConfigurationAudit {
    let directory: URL
    let runID = UUID().uuidString
    private let archive: URL
    private let lock = NSRecursiveLock()
    private var known: [UUID: AgentConfig] = [:]
    private var knownAgentIDs: Set<UUID> = []
    private var expectedStamp: String?
    private var lastCheckpoint = Date.distantPast
    private var reportedFailure = false
    private let limit: Int
    private var log: URL { directory.appendingPathComponent("events-" + runID + ".jsonl") }
    init(folder: URL, limit: Int = 1_048_576) {
        directory = folder.appendingPathComponent("Configuration Diagnostics")
        archive = folder.appendingPathComponent("sessions.json")
        self.limit = limit
        expectedStamp = stamp()
        record("process_started", ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                                   "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                                   "sourceCommit": (try? HelpBook.load())?.sourceCommit ?? "unknown",
                                   "executable": Bundle.main.executableURL?.path ?? "unknown"])
        // Bound previous-run diagnostics; keep snapshots separately for recovery.
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let logs = files.filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for file in logs.dropFirst(16) where file != log { try? FileManager.default.removeItem(at: file) }
        }
    }
    private func stamp() -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: archive.path) else { return nil }
        return "\(a[.systemFileNumber] ?? 0)|\(a[.size] ?? 0)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func fields(_ config: AgentConfig?) -> [String: Any] {
        guard let config, let data = try? JSONEncoder().encode(config), let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return fields
    }
    static func changedFields(_ old: AgentConfig?, _ new: AgentConfig?) -> [String] {
        let a = fields(old), b = fields(new)
        return Set(a.keys).union(b.keys).filter { !NSDictionary(dictionary: ["v": a[$0] ?? NSNull()]).isEqual(to: ["v": b[$0] ?? NSNull()]) }.sorted()
    }
    func record(_ event: String, _ details: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var row = details
            row["event"] = event; row["at"] = ISO8601DateFormatter().string(from: Date())
            row["runID"] = runID; row["pid"] = ProcessInfo.processInfo.processIdentifier
            row["mainThread"] = Thread.isMainThread
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10)
            if let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size]) as? NSNumber, size.intValue + data.count > limit {
                let previous = directory.appendingPathComponent("events-" + runID + "-previous.jsonl")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: log, to: previous)
            }
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let file = try FileHandle(forWritingTo: log); defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: data)
        } catch {
            if !reportedFailure { reportedFailure = true; NSLog("Configuration diagnostics unavailable (%@, %ld)", (error as NSError).domain, (error as NSError).code) }
        }
    }
    func failure(_ event: String, error: Error, source: String = "") {
        let e = error as NSError
        record(event, ["errorDomain": e.domain, "errorCode": e.code, "source": source])
    }
    func loaded(_ sessions: [Session], data: Data) {
        lock.lock(); defer { lock.unlock() }
        knownAgentIDs = Set(sessions.filter(\.isAgentSession).map(\.id))
        known = Dictionary(uniqueKeysWithValues: sessions.compactMap { s in s.agent.map { (s.id, $0) } })
        record("archive_loaded", ["archiveSHA256": Self.digest(data), "sessionCount": sessions.count,
                                  "configuredAgents": known.keys.map(\.uuidString).sorted(),
                                  "missingAgentConfigurations": sessions.filter(\.needsAgentSetup).map { $0.id.uuidString }.sorted()])
        for (id, config) in known { snapshot(id, config) }
    }
    func agentChanged(id: UUID, old: AgentConfig?, new: AgentConfig?) {
        let changed = Self.changedFields(old, new)
        let settings: Set<String> = ["objective", "repository", "model", "watchedSessions", "watchedParticipants", "intervalSeconds", "scheduleText", "scheduleTimeZone", "enabled", "maxTurnsPerLoop", "discordChannelID", "discordMentions", "discordRead", "discord", "fileTriggers", "jollyAllowed", "webSearch", "speak", "generateArt", "artDirection"]
        var detail: [String: Any] = ["sessionID": id.uuidString, "beforePresent": old != nil, "afterPresent": new != nil, "changedFields": changed]
        if new == nil || !settings.isDisjoint(with: changed) { detail["stack"] = Array(Thread.callStackSymbols.prefix(18)) }
        if let old, new == nil { snapshot(id, old) }
        record(new == nil ? "agent_configuration_removed_in_memory" : "agent_configuration_changed_in_memory", detail)
    }
    private func snapshot(_ id: UUID, _ config: AgentConfig) {
        lock.lock(); defer { lock.unlock() }
        do {
            let folder = directory.appendingPathComponent("Agent Recovery").appendingPathComponent(id.uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(config), latest = folder.appendingPathComponent("latest.json")
            if let prior = try? Data(contentsOf: latest) {
                if prior == data { return }
                // Preserve a valid previous configuration before replacing the latest.
                _ = try JSONDecoder().decode(AgentConfig.self, from: prior)
                let previous = folder.appendingPathComponent("previous.json")
                try prior.write(to: previous, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.path)
            }
            try data.write(to: latest, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: latest.path)
        } catch { failure("agent_recovery_snapshot_failed", error: error) }
    }
    /// What the audit needs from the sessions, captured on the main thread so
    /// the archive can be written in the background.
    struct SaveSummary {
        let agents: [UUID: AgentConfig]; let agentIDs: Set<UUID>; let sessionIDs: Set<UUID>; let missingAgentCount: Int
        init(_ sessions: [Session]) {
            agents = Dictionary(uniqueKeysWithValues: sessions.compactMap { s in s.agent.map { (s.id, $0) } })
            agentIDs = Set(sessions.filter(\.isAgentSession).map(\.id)); sessionIDs = Set(sessions.map(\.id))
            missingAgentCount = sessions.filter(\.needsAgentSetup).count
        }
    }
    func willSave(_ sessions: [Session], data: Data, source: String) { willSave(SaveSummary(sessions), data: data, source: source) }
    func didSave(_ sessions: [Session]) { didSave(SaveSummary(sessions)) }
    func willSave(_ summary: SaveSummary, data: Data, source: String) {
        lock.lock(); defer { lock.unlock() }
        if stamp() != expectedStamp {
            let disk = try? Data(contentsOf: archive)
            let object = disk.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let rows = object?["sessions"] as? [[String: Any]] ?? []
            record("archive_changed_outside_this_store", ["source": source, "diskSHA256": disk.map(Self.digest) ?? "missing",
                "diskConfiguredAgents": rows.filter { $0["agent"] is [String: Any] }.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:))?.uuidString }.sorted()])
        }
        let current = summary.agents, currentIDs = summary.agentIDs
        var changed = false
        for id in Set(known.keys).union(current.keys) where known[id] != current[id] {
            changed = true
            record("agent_configuration_save", ["sessionID": id.uuidString, "beforePresent": known[id] != nil, "afterPresent": current[id] != nil,
                                                 "sessionStillExists": summary.sessionIDs.contains(id), "changedFields": Self.changedFields(known[id], current[id]), "source": source])
            if let previous = known[id] { snapshot(id, previous) }
            if let config = current[id] { snapshot(id, config) }
        }
        if changed || currentIDs != knownAgentIDs || Date().timeIntervalSince(lastCheckpoint) >= 30 {
            record("archive_save_begin", ["source": source, "archiveSHA256": Self.digest(data), "sessionCount": summary.sessionIDs.count, "configuredAgentCount": current.count, "missingAgentCount": summary.missingAgentCount])
            lastCheckpoint = Date()
        }
    }
    func didSave(_ summary: SaveSummary) {
        lock.lock(); defer { lock.unlock() }
        let current = summary.agents
        if current != known { record("agent_configuration_save_committed", ["configuredAgents": current.keys.map(\.uuidString).sorted()]) }
        known = current; knownAgentIDs = summary.agentIDs; expectedStamp = stamp()
    }
}
