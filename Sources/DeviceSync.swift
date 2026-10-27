import CryptoKit
import Foundation

enum DeviceBlob {
    static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func verify(_ data: Data, sha256Hex expected: String) -> Bool { sha256Hex(data) == expected.lowercased() }
    static let maxBlob = 25_000_000
}

struct DeviceLease: Equatable {
    var device: String
    var epoch: UInt64
    var expiresAt: Date
}

final class DeviceLeaseManager {
    private let now: () -> Date
    private let ttl: TimeInterval
    private let persistEpochs: (([UUID: UInt64]) -> Bool)?
    private(set) var leases: [UUID: DeviceLease] = [:]
    private(set) var epochs: [UUID: UInt64]
    init(now: @escaping () -> Date = Date.init, ttl: TimeInterval = 15, initialEpochs: [UUID: UInt64] = [:], persistEpochs: (([UUID: UInt64]) -> Bool)? = nil) {
        self.now = now; self.ttl = ttl; epochs = initialEpochs; self.persistEpochs = persistEpochs
    }
    func acquire(session: UUID, device: String) -> (granted: Bool, epoch: UInt64, displaced: String?) {
        // Report any previous holder, even expired, so callers clear its stream.
        let displaced = leases[session].flatMap { $0.device != device ? $0.device : nil }
        let epoch = (epochs[session] ?? 0) + 1
        var candidate = epochs; candidate[session] = epoch
        // Fail closed: an epoch that cannot be persisted must never grant,
        // or a restart could reuse it and resurrect stale authority.
        if let persistEpochs, !persistEpochs(candidate) { return (false, epochs[session] ?? 0, nil) }
        epochs = candidate
        leases[session] = DeviceLease(device: device, epoch: epoch, expiresAt: now().addingTimeInterval(ttl))
        return (true, epoch, displaced)
    }
    func heartbeat(session: UUID, device: String, epoch: UInt64) -> Bool {
        guard validate(session: session, device: device, epoch: epoch) else { return false }
        leases[session]?.expiresAt = now().addingTimeInterval(ttl); return true
    }
    func release(session: UUID, device: String, epoch: UInt64) {
        if leases[session]?.device == device && leases[session]?.epoch == epoch { leases.removeValue(forKey: session) }
    }
    func validate(session: UUID, device: String, epoch: UInt64) -> Bool {
        guard let lease = leases[session] else { return false }
        if lease.expiresAt <= now() { leases.removeValue(forKey: session); return false }
        return lease.device == device && lease.epoch == epoch
    }
    func sweepExpired() -> [(session: UUID, device: String)] {
        let expired = leases.filter { $0.value.expiresAt <= now() }
        for key in expired.keys { leases.removeValue(forKey: key) }
        return expired.map { (session: $0.key, device: $0.value.device) }
    }
    func holder(session: UUID) -> DeviceLease? {
        guard let lease = leases[session], lease.expiresAt > now() else { return nil }
        return lease
    }
}

enum DeviceCommandOutcome: String, Codable, Equatable { case accepted, running, completed, failed, uncertain, rejected }
struct DeviceCommandRecord: Codable, Equatable {
    var id: UUID
    var origin: String
    var outcome: DeviceCommandOutcome
    var updatedAt: Date
    var sessionID: String = ""
    var payloadHash: String = ""
}

// Persisted before CLI start. A record left running across restart becomes
// uncertain and is never executed again automatically.
final class DeviceCommandStore {
    private let file: URL
    private(set) var records: [UUID: DeviceCommandRecord] = [:]
    init(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = folder.appendingPathComponent("device-commands.json")
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode([DeviceCommandRecord].self, from: data) {
            for var record in decoded {
                if record.outcome == .running || record.outcome == .accepted { record.outcome = .uncertain }
                records[record.id] = record
            }
            try save()
        }
    }
    func begin(id: UUID, origin: String, sessionID: String = "", payloadHash: String = "") throws -> Bool {
        guard records[id] == nil else { return false }
        records[id] = DeviceCommandRecord(id: id, origin: origin, outcome: .accepted, updatedAt: Date(), sessionID: sessionID, payloadHash: payloadHash)
        try save(); return true
    }
    func bindingMatches(id: UUID, origin: String, sessionID: String, payloadHash: String) -> Bool {
        guard let record = records[id] else { return false }
        return record.origin == origin && record.sessionID == sessionID && record.payloadHash == payloadHash
    }
    func markRunning(id: UUID) throws { try update(id: id, outcome: .running) }
    func markCompleted(id: UUID) throws { try update(id: id, outcome: .completed) }
    func markFailed(id: UUID) throws { try update(id: id, outcome: .failed) }
    func outcome(id: UUID) -> DeviceCommandOutcome? { records[id]?.outcome }
    private func update(id: UUID, outcome: DeviceCommandOutcome) throws {
        guard records[id] != nil else { return }
        records[id]?.outcome = outcome; records[id]?.updatedAt = Date(); try save()
    }
    private func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Array(records.values)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

// Keyed by routing key: home-local session UUID string on the home,
// full global ID on viewers. Never a bare cross-home UUID alone.
struct DeviceDraftTracker {
    private var versions: [String: UInt64] = [:]
    private var texts: [String: String] = [:]
    mutating func apply(session: String, version: UInt64, text: String) -> Bool {
        guard version > (versions[session] ?? 0) else { return false }
        versions[session] = version; texts[session] = text; return true
    }
    func text(session: String) -> String? { texts[session] }
    func version(session: String) -> UInt64 { versions[session] ?? 0 }
    mutating func bump(session: String, text: String) -> UInt64 {
        let next = (versions[session] ?? 0) + 1; _ = apply(session: session, version: next, text: text); return next
    }
    mutating func adopt(session: String, version: UInt64, text: String) {
        versions[session] = version; texts[session] = text
    }
    // Periodic snapshots must never regress a viewer version or clobber
    // a newer pending edit. Adopt only strictly newer home state.
    mutating func adoptIfNewer(session: String, version: UInt64, text: String) -> Bool {
        guard version > (versions[session] ?? 0) else { return false }
        versions[session] = version; texts[session] = text; return true
    }
    var snapshot: (versions: [String: UInt64], texts: [String: String]) { (versions, texts) }
    mutating func restore(versions: [String: UInt64], texts: [String: String]) { self.versions = versions; self.texts = texts }
}

// Viewer outbox: submitted content and its command ID persist until an
// authoritative home ack. Retries reuse the same ID; uncertain entries are
// never resent automatically.
struct DeviceOutboxRecord: Codable, Equatable, Identifiable {
    var id: UUID { commandID }
    var commandID: UUID
    var sessionID: String
    var payload: DeviceCommandPayload
    var payloadHash: String
    var outcome: String = "pending"
    var detail: String? = nil
}

final class DeviceOutboxStore {
    private let file: URL
    private(set) var records: [DeviceOutboxRecord] = []
    init(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = folder.appendingPathComponent("device-outbox.json")
        if let data = try? Data(contentsOf: file) { records = (try? JSONDecoder().decode([DeviceOutboxRecord].self, from: data)) ?? [] }
    }
    func add(_ record: DeviceOutboxRecord) throws { records.removeAll { $0.commandID == record.commandID }; records.append(record); try save() }
    func resolve(commandID: UUID, outcome: String, detail: String?) throws {
        guard let index = records.firstIndex(where: { $0.commandID == commandID }) else { return }
        // Only success removes the record. Failures retain content for recovery.
        if outcome == "completed" { records.remove(at: index) }
        else { records[index].outcome = outcome; records[index].detail = detail }
        try save()
    }
    func markUncertain(sessionID: String) throws {
        for index in records.indices where records[index].sessionID == sessionID && records[index].outcome == "pending" {
            records[index].outcome = "uncertain"; records[index].detail = "Home disconnected before acknowledgment. Check home before retrying."
        }
        try save()
    }
    func remove(commandID: UUID) throws { records.removeAll { $0.commandID == commandID }; try save() }
    private func save() throws {
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

struct DeviceDraftFile: Codable {
    var versions: [String: UInt64] = [:]
    var texts: [String: String] = [:]
    var attachments: [String: [String]] = [:]
}

final class DeviceDraftStore {
    private let file: URL
    init(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = folder.appendingPathComponent("device-drafts.json")
    }
    func load() -> DeviceDraftFile {
        guard let data = try? Data(contentsOf: file) else { return DeviceDraftFile() }
        return (try? JSONDecoder().decode(DeviceDraftFile.self, from: data)) ?? DeviceDraftFile()
    }
    func save(_ value: DeviceDraftFile) throws {
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

struct DeviceSyncState: Codable {
    var homeSeq: UInt64 = 0
    var epochs: [String: UInt64] = [:]
    var boot: UInt64 = 0
    var sidebarCache: Data? = nil
}

final class DeviceSyncStateStore {
    private let file: URL
    private(set) var state = DeviceSyncState()
    init(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = folder.appendingPathComponent("device-sync.json")
        if let data = try? Data(contentsOf: file) { state = (try? JSONDecoder().decode(DeviceSyncState.self, from: data)) ?? DeviceSyncState() }
    }
    func nextSeq() -> UInt64 { state.homeSeq += 1; try? save(); return state.homeSeq }
    func beginBoot() -> UInt64 { state.boot += 1; try? save(); return state.boot }
    func saveEpochs(_ epochs: [UUID: UInt64]) -> Bool {
        state.epochs = Dictionary(uniqueKeysWithValues: epochs.map { ($0.key.uuidString, $0.value) })
        do { try save(); return true } catch { return false }
    }
    var loadedEpochs: [UUID: UInt64] {
        Dictionary(uniqueKeysWithValues: state.epochs.compactMap { pair in UUID(uuidString: pair.key).map { ($0, pair.value) } })
    }
    func saveSidebarCache(_ data: Data) { state.sidebarCache = data; try? save() }
    private func save() throws { try JSONEncoder().encode(state).write(to: file, options: .atomic) }
}
