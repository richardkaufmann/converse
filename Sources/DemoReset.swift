import Foundation
import Security

// Reset is consumed before any store, provider or peer connection is opened.
// The running app only writes the request, then performs its normal shutdown.
enum DemoReset {
    static var enabled: Bool { Bundle.main.object(forInfoDictionaryKey: "ConverseDemo") as? Bool == true }
    static let marker = "reset-demo-request"
    static func validate(folder: URL, enabled: Bool) throws {
        guard enabled, folder.lastPathComponent == "Converse Demo",
              folder.standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL else {
            throw NSError(domain: "ConverseDemoReset", code: 1, userInfo: [NSLocalizedDescriptionKey: "Reset is only available for the separate Converse Demo profile."])
        }
    }
    static func request(folder: URL, enabled: Bool) throws {
        try validate(folder: folder, enabled: enabled)
        try Data("Reset Demo on next launch\n".utf8).write(to: folder.appendingPathComponent(marker), options: .atomic)
    }
    @discardableResult static func consume(folder: URL, enabled: Bool, clearCredentials: () throws -> Void) throws -> URL? {
        guard enabled else { return nil }
        try validate(folder: folder, enabled: enabled)
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent(marker).path) else { return nil }
        let backups = folder.deletingLastPathComponent().appendingPathComponent("Converse Demo Backups")
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
        for service in ["app.kaoslabs.Converse.Demo.Agent", "local.richard.Converse.Demo.device"] {
            let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not clear Demo’s saved keys. Unlock Keychain and reopen Demo to retry."])
            }
        }
    }
}
