import CryptoKit
import Foundation
import Security

struct DeviceIdentity {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    var publicKey: Data { privateKey.publicKey.rawRepresentation }
    var deviceID: String { DeviceBlob.sha256Hex(publicKey) }
    var fingerprint: String { String(deviceID.prefix(16)).uppercased() }
    var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "iPad"
        #endif
    }

    // Keychain in the app. Isolated test data uses a 0600 file to avoid prompts.
    // Fail closed: only errSecItemNotFound may create a key. Any other
    // Keychain status throws and never deletes or replaces identity.
    static func loadOrCreate(folder: URL, useKeychain: Bool) throws -> DeviceIdentity {
        if useKeychain {
            if let data = try keychainRead() {
                return DeviceIdentity(privateKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data))
            }
            let key = Curve25519.KeyAgreement.PrivateKey()
            try keychainWrite(key.rawRepresentation)
            return DeviceIdentity(privateKey: key)
        }
        let file = folder.appendingPathComponent("device-key.bin")
        if let data = try? Data(contentsOf: file), data.count == 32 {
            return DeviceIdentity(privateKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data))
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try key.rawRepresentation.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return DeviceIdentity(privateKey: key)
    }
    private static let service = "local.richard.Converse.device"
    static func keychainDecision(status: OSStatus) -> Bool { status == errSecItemNotFound }
    private static func keychainRead() throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "static-v1", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess { return result as? Data }
        if keychainDecision(status: status) { return nil }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain read failed; device identity preserved."])
    }
    private static func keychainWrite(_ data: Data) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "static-v1"]
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain write failed; device identity not created."])
        }
    }
}

enum DeviceTrustCheck: Equatable { case trusted, unknown, keyChanged }
struct TrustedDevice: Codable, Equatable, Identifiable {
    var id: String { deviceID }
    var deviceID: String
    var name: String
    var publicKey: Data
    var pairedAt: Date
    var lastHost: String? = nil
    var lastPort: Int? = nil
    var generation: UInt64? = nil
    var changedBy: String? = nil
    var removed: Bool? = nil
    var metadataGeneration: UInt64? = nil
    var metadataBy: String? = nil
    var groupID: String? = nil
}

final class DeviceTrustStore {
    private let file: URL
    private(set) var records: [TrustedDevice] = []
    var devices: [TrustedDevice] { records.filter { $0.removed != true } }
    init(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = folder.appendingPathComponent("devices.json")
        if FileManager.default.fileExists(atPath: file.path) {
            records = try JSONDecoder().decode([TrustedDevice].self, from: Data(contentsOf: file)).map { var record = $0; record.name = Self.boundedName(record.name); return record }
        }
    }
    func check(deviceID: String, publicKey: Data) -> DeviceTrustCheck {
        guard let device = devices.first(where: { $0.deviceID == deviceID }) else { return .unknown }
        return device.publicKey == publicKey ? .trusted : .keyChanged
    }
    private func nextGeneration() throws -> UInt64 {
        let highest = records.map { $0.generation ?? 0 }.max() ?? 0
        guard highest < UInt64.max - 2 else { throw CocoaError(.coderInvalidValue) }
        return highest + 1
    }
    static func boundedName(_ name: String) -> String {
        var bytes = Array(name.utf8.prefix(200))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
    func pin(deviceID: String, name: String, publicKey: Data, host: String? = nil, port: Int? = nil, issuer: String? = nil, allowAdmission: Bool = true, groupID: String? = nil) throws {
        let name = Self.boundedName(name)
        let old = records.first { $0.deviceID == deviceID }
        let active = old?.removed != true && old?.publicKey == publicKey && old?.groupID == groupID
        guard active || allowAdmission else { throw CocoaError(.coderInvalidValue) }
        if active, let old, old.name == name, (host == nil || old.lastHost == host), (port == nil || old.lastPort == port) { return }
        guard (old?.metadataGeneration ?? 0) < UInt64.max - 2 else { throw CocoaError(.coderInvalidValue) }
        var next = records.filter { $0.deviceID != deviceID }
        next.append(TrustedDevice(deviceID: deviceID, name: name, publicKey: publicKey, pairedAt: active ? old!.pairedAt : Date(), lastHost: host ?? old?.lastHost, lastPort: port ?? old?.lastPort,
                                  generation: active ? old!.generation : try nextGeneration(), changedBy: active ? old!.changedBy : issuer ?? deviceID, removed: false,
                                  metadataGeneration: (old?.metadataGeneration ?? 0) + 1, metadataBy: issuer ?? deviceID, groupID: groupID))
        guard next.count <= 512 else { throw CocoaError(.coderInvalidValue) }
        try save(next); records = next
    }
    func forget(deviceID: String, issuer: String? = nil) throws {
        guard var record = records.first(where: { $0.deviceID == deviceID }) else { return }
        record.removed = true; record.generation = try nextGeneration(); record.changedBy = issuer ?? deviceID
        let next = records.filter { $0.deviceID != deviceID } + [record]
        try save(next); records = next
    }
    // Called ONLY after transport authentication of an existing member. All
    // members may admit/remove members; this is intentionally transitive trust.
    // Versioned removals prevent a stale offline roster from resurrecting one.
    func merge(_ incoming: [TrustedDevice]) throws -> Bool {
        guard incoming.count <= 512, incoming.allSatisfy({ ($0.groupID == nil || UUID(uuidString: $0.groupID!) != nil) && $0.publicKey.count == 32 && DeviceBlob.sha256Hex($0.publicKey) == $0.deviceID && $0.name.utf8.count <= 200 && ($0.metadataBy?.count ?? 0) <= 64 && ($0.metadataGeneration ?? 0) < UInt64.max - 1 && ($0.changedBy?.count ?? 0) <= 64 && ($0.lastHost?.count ?? 0) <= 253 && ($0.lastPort == nil || (1...65535).contains($0.lastPort!)) && ($0.generation ?? 0) < UInt64.max - 1 }) else { throw CocoaError(.coderInvalidValue) }
        var next = records
        for record in incoming {
            if let index = next.firstIndex(where: { $0.deviceID == record.deviceID }) {
                let old = next[index]
                let newRank = (record.generation ?? 0, record.removed == true ? 1 : 0, record.changedBy ?? "")
                let oldRank = (old.generation ?? 0, old.removed == true ? 1 : 0, old.changedBy ?? "")
                if newRank > oldRank { next[index] = record }
                else if newRank == oldRank, record.publicKey == old.publicKey,
                        (record.metadataGeneration ?? 0, record.metadataBy ?? "") > (old.metadataGeneration ?? 0, old.metadataBy ?? "") {
                    // Hint freshness is independent of admission authority.
                    // No amount of metadata churn can beat a tombstone.
                    next[index].name = record.name; next[index].lastHost = record.lastHost; next[index].lastPort = record.lastPort
                    next[index].metadataGeneration = record.metadataGeneration; next[index].metadataBy = record.metadataBy
                }
            } else { next.append(record) }
        }
        guard next.count <= 512 else { throw CocoaError(.coderInvalidValue) }
        guard next != records else { return false }
        try save(next); records = next; return true
    }
    func migrateLegacyGroup(_ id: String) throws {
        var next = records
        for index in next.indices where next[index].groupID == nil { next[index].groupID = id }
        try save(next); records = next
    }
    func hasNameCollision(name: String, deviceID: String) -> Bool {
        devices.contains { $0.name == name && $0.deviceID != deviceID }
    }
    private func save(_ value: [TrustedDevice]) throws {
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

// A group is an immutable identity/name plus a permanent dissolution tombstone.
// Discovery supplies hints; only an authenticated member may convey state.
struct ConverseGroup: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var creator: String
    var dissolved = false
    var valid: Bool {
        UUID(uuidString: id) != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 120 && creator.count == 64 && creator.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
struct ConverseGroupFile: Codable {
    var currentID: String?
    var groups: [ConverseGroup] = []
}
final class ConverseGroupStore {
    private let file: URL
    private(set) var state: ConverseGroupFile
    var current: ConverseGroup? { state.groups.first { $0.id == state.currentID && !$0.dissolved } }
    init(folder: URL) throws {
        file = folder.appendingPathComponent("converse-groups.json")
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(ConverseGroupFile.self, from: Data(contentsOf: file))
            guard state.groups.count <= 2048, state.groups.allSatisfy(\.valid), Set(state.groups.map(\.id)).count == state.groups.count else { throw CocoaError(.coderInvalidValue) }
        } else { state = ConverseGroupFile() }
    }
    private func save(_ next: ConverseGroupFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        state = next
    }
    func adopt(_ group: ConverseGroup) throws {
        guard group.valid, !group.dissolved, state.groups.first(where: { $0.id == group.id })?.dissolved != true else { throw CocoaError(.coderInvalidValue) }
        if let old = state.groups.first(where: { $0.id == group.id }), old.name != group.name || old.creator != group.creator { throw CocoaError(.coderInvalidValue) }
        var next = state
        next.groups.removeAll { $0.id == group.id }; next.groups.append(group); next.currentID = group.id
        guard next.groups.count <= 2048 else { throw CocoaError(.coderInvalidValue) }; try save(next)
    }
    func leave() throws { var next = state; next.currentID = nil; try save(next) }
    func dissolve(_ group: ConverseGroup) throws {
        guard group.valid else { throw CocoaError(.coderInvalidValue) }
        if let old = state.groups.first(where: { $0.id == group.id }), old.name != group.name || old.creator != group.creator { throw CocoaError(.coderInvalidValue) }
        var dead = group; dead.dissolved = true
        var next = state; next.groups.removeAll { $0.id == group.id }; next.groups.append(dead)
        if next.currentID == group.id { next.currentID = nil }
        guard next.groups.count <= 2048 else { throw CocoaError(.coderInvalidValue) }; try save(next)
    }
    static func migration(_ members: [TrustedDevice]) -> ConverseGroup? {
        let active = members.filter { $0.removed != true }
        guard active.count > 1, let first = active.map(\.deviceID).sorted().first else { return nil }
        let digest = DeviceBlob.sha256Hex(Data(("Converse legacy group v1/" + first).utf8))
        let chars = Array(digest.prefix(32)); let raw = String(chars)
        let id = [String(raw.prefix(8)), String(raw.dropFirst(8).prefix(4)), String(raw.dropFirst(12).prefix(4)), String(raw.dropFirst(16).prefix(4)), String(raw.dropFirst(20))].joined(separator: "-")
        return ConverseGroup(id: String(id), name: "Converse Group", creator: first)
    }
}
