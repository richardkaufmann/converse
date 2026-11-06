import Foundation
import CryptoKit

// Diagnostic metadata is separate from recoverable private configuration snapshots.
// Never log configuration values, transcript text, commands, credentials or titles.
final class ConfigurationAudit {
    let directory: URL
    let runID = UUID().uuidString
    private let archive: URL
    private let lock = NSRecursiveLock()
    // Only in-memory change diagnostics use this queue. Recovery snapshots and
    // archive commit bookkeeping retain their synchronous ordering.
    private let changes = DispatchQueue(label: "local.richard.Converse.configuration-changes", qos: .utility)
    // Injection point for deterministic contention tests; nil in the app.
    private let beforeEventWrite: ((String) -> Void)?
    private struct Origin {
        let at = Date()
        let mainThread = Thread.isMainThread
    }
    private var known: [UUID: AgentConfig] = [:]
    private var knownAgentIDs: Set<UUID> = []
    private var expectedStamp: String?
    private var lastCheckpoint = Date.distantPast
    private var reportedFailure = false
    private let limit: Int
    private var log: URL { directory.appendingPathComponent("events-" + runID + ".jsonl") }
    init(folder: URL, limit: Int = 1_048_576, beforeEventWrite: ((String) -> Void)? = nil) {
        self.beforeEventWrite = beforeEventWrite
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
        record(event, details, origin: Origin())
    }
    private func record(_ event: String, _ details: [String: Any], origin: Origin) {
        lock.lock(); defer { lock.unlock() }
        beforeEventWrite?(event)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var row = details
            row["event"] = event; row["at"] = ISO8601DateFormatter().string(from: origin.at)
            row["runID"] = runID; row["pid"] = ProcessInfo.processInfo.processIdentifier
            row["mainThread"] = origin.mainThread
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
    // Match the settings that warrant a caller stack without encoding the
    // runtime state (repository snapshots, working memory, event journals).
    private static func settingsChanged(_ old: AgentConfig?, _ new: AgentConfig?) -> Bool {
        old?.objective != new?.objective || old?.repository != new?.repository ||
        old?.model != new?.model || old?.watchedSessions != new?.watchedSessions ||
        old?.watchedParticipants != new?.watchedParticipants || old?.intervalSeconds != new?.intervalSeconds ||
        old?.scheduleText != new?.scheduleText || old?.scheduleTimeZone != new?.scheduleTimeZone ||
        old?.enabled != new?.enabled || old?.maxTurnsPerLoop != new?.maxTurnsPerLoop ||
        old?.discordChannelID != new?.discordChannelID || old?.discordMentions != new?.discordMentions ||
        old?.discordRead != new?.discordRead || old?.discord != new?.discord ||
        old?.fileTriggers != new?.fileTriggers || old?.jollyAllowed != new?.jollyAllowed ||
        old?.webSearch != new?.webSearch || old?.speak != new?.speak ||
        old?.generateArt != new?.generateArt || old?.artDirection != new?.artDirection
    }
    func agentChanged(id: UUID, old: AgentConfig?, new: AgentConfig?) {
        let origin = Origin()
        // Capture the originating caller, never the diagnostics worker's stack.
        let stack = new == nil || Self.settingsChanged(old, new) ? Array(Thread.callStackSymbols.prefix(18)) : nil
        let write = {
            var detail: [String: Any] = ["sessionID": id.uuidString, "beforePresent": old != nil,
                                        "afterPresent": new != nil, "changedFields": Self.changedFields(old, new)]
            if let stack { detail["stack"] = stack }
            self.record(new == nil ? "agent_configuration_removed_in_memory" : "agent_configuration_changed_in_memory", detail, origin: origin)
        }
        if new == nil {
            // A removal must retain its last valid configuration before returning.
            // Drain earlier diagnostics BEFORE taking the recovery/log lock.
            flushChanges()
            if let old { snapshot(id, old) }
            write()
        } else {
            changes.async(execute: DispatchWorkItem(block: write))
        }
    }
    /// Must be called without holding lock; queued records acquire it themselves.
    /// Archive flushes also drain prior change diagnostics through willSave.
    func flushChanges() {
        dispatchPrecondition(condition: .notOnQueue(changes))
        changes.sync {}
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
        flushChanges()
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
