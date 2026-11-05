import Foundation
import Security

// Reset is consumed before any store, provider or peer connection is opened.
// The running app only writes the request, then performs its normal shutdown.
enum DemoReset {
    static let testProviders = ["Codex", "Claude", "Muse"]
    static func testName(provider: String?) -> String? {
        guard let provider, testProviders.contains(provider) else { return nil }
        return provider + " Converse TEST"
    }
    static var testName: String? { testName(provider: Bundle.main.object(forInfoDictionaryKey: "ConverseTestProvider") as? String) }
    static var profileName: String { testName ?? "Converse Demo" }
    static var enabled: Bool { testName != nil || Bundle.main.object(forInfoDictionaryKey: "ConverseDemo") as? Bool == true }
    static let marker = "reset-demo-request"
    static func validate(folder: URL, enabled: Bool, profileName: String = "Converse Demo") throws {
        guard enabled, (["Converse Demo"] + testProviders.map { $0 + " Converse TEST" }).contains(profileName),
              folder.lastPathComponent == profileName,
              folder.standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL else {
            throw NSError(domain: "ConverseDemoReset", code: 1, userInfo: [NSLocalizedDescriptionKey: "Reset is only available for a separate Demo or TEST profile."])
        }
    }
    static func request(folder: URL, enabled: Bool, profileName: String = "Converse Demo") throws {
        try validate(folder: folder, enabled: enabled, profileName: profileName)
        try Data("Reset Demo on next launch\n".utf8).write(to: folder.appendingPathComponent(marker), options: .atomic)
    }
    @discardableResult static func consume(folder: URL, enabled: Bool, profileName: String = "Converse Demo", clearCredentials: () throws -> Void) throws -> URL? {
        guard enabled else { return nil }
        try validate(folder: folder, enabled: enabled, profileName: profileName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent(marker).path) else { return nil }
        let backups = folder.deletingLastPathComponent().appendingPathComponent(profileName + " Backups")
        try fm.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = backups.appendingPathComponent(UUID().uuidString)
        // Copy first: failures leave the live profile and reset request intact.
        try fm.copyItem(at: folder, to: backup)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backup.path)
        try clearCredentials()
        try fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return backup
    }
    static func clearCredentials() throws {
        guard enabled else { throw NSError(domain: "ConverseDemoReset", code: 2) }
        for service in [AgentSecrets.service, DeviceIdentity.service] {
            let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not clear this profile’s saved keys. Unlock Keychain and reopen the app to retry."])
            }
        }
    }

    /// Setup Preview (not Demo) is for screenshots and first-run testing: it starts
    /// clean on every launch. Only its own folder and Keychain items are touched.
    static func wipeSetupPreview(folder: URL) throws {
        guard Bundle.main.object(forInfoDictionaryKey: "ConverseNUXPreview") as? Bool == true,
              Bundle.main.object(forInfoDictionaryKey: "ConverseDemo") as? Bool != true,
              folder.lastPathComponent == "Converse Setup Preview" else { return }
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        for service in ["app.kaoslabs.Converse.NUXPreview.Agent", "local.richard.Converse.NUXPreview.device"] {
            let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not clear Setup Preview's saved keys. Unlock Keychain and reopen it to retry."])
            }
        }
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
    }
}
