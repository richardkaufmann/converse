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
    // A remembered display may return only if no newer take occurred, even if
    // that newer holder has since disconnected. Epochs survive home restarts.
    func resume(session: UUID, device: String, expectedEpoch: UInt64) -> (granted: Bool, epoch: UInt64, displaced: String?) {
        guard epochs[session] == expectedEpoch,
              holder(session: session).map({ $0.device == device }) ?? true else {
            return (false, epochs[session] ?? 0, nil)
        }
        return acquire(session: session, device: device)
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
    func sweepExpired() -> [(session: UUID, device: String, epoch: UInt64)] {
        let expired = leases.filter { $0.value.expiresAt <= now() }
        for key in expired.keys { leases.removeValue(forKey: key) }
        return expired.map { (session: $0.key, device: $0.value.device, epoch: $0.value.epoch) }
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
    // Absent on records written before canonical binding: those keep raw
    // byte hashes, so only an identical legacy retry still matches.
    var hashScheme: String? = nil
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
    func begin(id: UUID, origin: String, sessionID: String = "", payloadHash: String = "", hashScheme: String? = nil) throws -> Bool {
        guard records[id] == nil else { return false }
        records[id] = DeviceCommandRecord(id: id, origin: origin, outcome: .accepted, updatedAt: Date(), sessionID: sessionID, payloadHash: payloadHash, hashScheme: hashScheme)
        try save(); return true
    }
    // Compares under the scheme the record was written with.
    func bindingMatches(id: UUID, origin: String, sessionID: String, payload: Data) -> Bool {
        guard let record = records[id], record.origin == origin, record.sessionID == sessionID,
              let hash = DeviceCommandBinding.hash(payload, scheme: record.hashScheme) else { return false }
        return record.payloadHash == hash
    }
    // An earlier home hashed raw bytes, so a key-reordered retry of the same
    // command misses. Its original may already have run: never call it rejected.
    func rawBindingUnconfirmed(id: UUID, origin: String, sessionID: String) -> Bool {
        guard let record = records[id], record.origin == origin, record.sessionID == sessionID else { return false }
        return (record.hashScheme ?? DeviceCommandBinding.rawScheme) == DeviceCommandBinding.rawScheme
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
// authoritative home ack. Retries reuse the same ID and the exact bytes
// first sent; uncertain entries are never resent automatically.
struct DeviceOutboxRecord: Codable, Equatable, Identifiable {
    var id: UUID { commandID }
    var commandID: UUID
    var sessionID: String
    var payload: DeviceCommandPayload
    var payloadHash: String
    var epoch: UInt64 = 0
    var outcome: String = "pending"
    var detail: String? = nil
    // Absent on records saved by earlier versions, which cannot be resent.
    var payloadData: Data? = nil
    static let legacyDetail = "Saved by an earlier Converse version, so it cannot be resent exactly. Check home for its result."
}

enum DeviceDraftRecovery {
    static func canRestore(text: String, hashes: [String], record: DeviceOutboxRecord) -> Bool {
        (text.isEmpty && hashes.isEmpty) || (text == (record.payload.text ?? "") && hashes == record.payload.blobHashes)
    }
}

final class DeviceOutboxStore {
    private let file: URL
    private(set) var records: [DeviceOutboxRecord] = []
    init(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = folder.appendingPathComponent("device-outbox.json")
        if let data = try? Data(contentsOf: file) { records = (try? JSONDecoder().decode([DeviceOutboxRecord].self, from: data)) ?? [] }
        // Re-encoding a legacy payload could differ from what home bound, and
        // a fresh command ID could apply it twice. Only Check home is safe.
        let legacy = records.indices.filter { records[$0].payloadData == nil && records[$0].outcome == "pending" }
        for index in legacy { records[index].outcome = "uncertain"; records[index].detail = DeviceOutboxRecord.legacyDetail }
        // Never block sync start: memory keeps the migration and the next save writes it.
        if !legacy.isEmpty {
            do { try save() } catch { NSLog("Device outbox migration not saved yet: %@", error.localizedDescription) }
        }
    }
    func markLegacyUncertain(commandID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.commandID == commandID }) else { return }
        records[index].outcome = "uncertain"; records[index].detail = DeviceOutboxRecord.legacyDetail; try save()
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
