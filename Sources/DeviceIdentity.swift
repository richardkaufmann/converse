import CryptoKit
import Foundation
import Security

struct DeviceIdentity {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    var publicKey: Data { privateKey.publicKey.rawRepresentation }
    var deviceID: String { DeviceBlob.sha256Hex(publicKey) }
    var fingerprint: String { String(deviceID.prefix(16)).uppercased() }
    var deviceName: String { Host.current().localizedName ?? "Mac" }

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
}

final class DeviceTrustStore {
    private let file: URL
    private(set) var devices: [TrustedDevice] = []
    init(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = folder.appendingPathComponent("devices.json")
        if let data = try? Data(contentsOf: file) { devices = (try? JSONDecoder().decode([TrustedDevice].self, from: data)) ?? [] }
    }
    func check(deviceID: String, publicKey: Data) -> DeviceTrustCheck {
        guard let device = devices.first(where: { $0.deviceID == deviceID }) else { return .unknown }
        return device.publicKey == publicKey ? .trusted : .keyChanged
    }
    // Transactional: persist the candidate list first; memory changes only
    // after durable save succeeds, so a failed pin never grants trust.
    func pin(deviceID: String, name: String, publicKey: Data, host: String? = nil, port: Int? = nil) throws {
        var next = devices.filter { $0.deviceID != deviceID }
        next.append(TrustedDevice(deviceID: deviceID, name: name, publicKey: publicKey, pairedAt: Date(), lastHost: host, lastPort: port))
        try save(next); devices = next
    }
    func forget(deviceID: String) throws {
        let next = devices.filter { $0.deviceID != deviceID }
        try save(next); devices = next
    }
    func hasNameCollision(name: String, deviceID: String) -> Bool {
        devices.contains { $0.name == name && $0.deviceID != deviceID }
    }
    private func save(_ value: [TrustedDevice]) throws {
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
