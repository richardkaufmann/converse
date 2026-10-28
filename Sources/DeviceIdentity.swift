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
}

final class DeviceTrustStore {
    private let file: URL
    private(set) var records: [TrustedDevice] = []
    var devices: [TrustedDevice] { records.filter { $0.removed != true } }
    init(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = folder.appendingPathComponent("devices.json")
        if FileManager.default.fileExists(atPath: file.path) {
            records = try JSONDecoder().decode([TrustedDevice].self, from: Data(contentsOf: file))
        }
    }
    func check(deviceID: String, publicKey: Data) -> DeviceTrustCheck {
        guard let device = devices.first(where: { $0.deviceID == deviceID }) else { return .unknown }
        return device.publicKey == publicKey ? .trusted : .keyChanged
    }
    private func nextGeneration() throws -> UInt64 {
        let highest = records.map { $0.generation ?? 0 }.max() ?? 0
        guard highest < UInt64.max - 1 else { throw CocoaError(.coderInvalidValue) }
        return highest + 1
    }
    func pin(deviceID: String, name: String, publicKey: Data, host: String? = nil, port: Int? = nil, issuer: String? = nil) throws {
        let old = devices.first { $0.deviceID == deviceID }
        if let old, old.publicKey == publicKey, old.name == name, (host == nil || old.lastHost == host), (port == nil || old.lastPort == port) { return }
        var next = records.filter { $0.deviceID != deviceID }
        next.append(TrustedDevice(deviceID: deviceID, name: String(name.prefix(200)), publicKey: publicKey, pairedAt: old?.pairedAt ?? Date(), lastHost: host ?? old?.lastHost, lastPort: port ?? old?.lastPort, generation: try nextGeneration(), changedBy: issuer ?? deviceID, removed: false))
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
        guard incoming.count <= 512, incoming.allSatisfy({ $0.publicKey.count == 32 && DeviceBlob.sha256Hex($0.publicKey) == $0.deviceID && $0.name.count <= 200 && ($0.changedBy?.count ?? 0) <= 64 && ($0.lastHost?.count ?? 0) <= 253 && ($0.lastPort == nil || (1...65535).contains($0.lastPort!)) && ($0.generation ?? 0) < UInt64.max - 1 }) else { throw CocoaError(.coderInvalidValue) }
        var next = records
        for record in incoming {
            if let index = next.firstIndex(where: { $0.deviceID == record.deviceID }) {
                let old = next[index]
                let newRank = (record.generation ?? 0, record.removed == true ? 1 : 0, record.changedBy ?? "")
                let oldRank = (old.generation ?? 0, old.removed == true ? 1 : 0, old.changedBy ?? "")
                if newRank > oldRank { next[index] = record }
            } else { next.append(record) }
        }
        guard next.count <= 512 else { throw CocoaError(.coderInvalidValue) }
        guard next != records else { return false }
        try save(next); records = next; return true
    }
    func hasNameCollision(name: String, deviceID: String) -> Bool {
        devices.contains { $0.name == name && $0.deviceID != deviceID }
    }
    private func save(_ value: [TrustedDevice]) throws {
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
