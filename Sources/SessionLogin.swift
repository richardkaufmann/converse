import Foundation

// Move this conversation's retained context, never credentials or whole stores.
enum SessionLoginContext {
    static func copy(_ session: Session, from source: AccountProfile, to target: AccountProfile) throws {
        guard source.engine == target.engine else { throw failure("The login must use the same assistant.") }
        guard AccountLogin.directoryKey(source.directory) != AccountLogin.directoryKey(target.directory),
              session.started || session.remoteID != nil else { return }
        let manager = FileManager.default
        let sourceRoot = URL(fileURLWithPath: AccountLogin.directoryKey(source.directory))
        let targetRoot = URL(fileURLWithPath: AccountLogin.directoryKey(target.directory))
        let id = (session.remoteID ?? session.conversationID.uuidString).lowercased()
        let roots = source.engine == "claude" ? ["projects"] : ["sessions", "archived_sessions"]
        var matches: [URL] = []
        for root in roots {
            guard let files = manager.enumerator(at: sourceRoot.appendingPathComponent(root), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in files where file.pathExtension == "jsonl" {
                let name = file.lastPathComponent.lowercased()
                if source.engine == "claude" ? name == id + ".jsonl" : name.contains(id) {
                    let canonical = file.resolvingSymlinksInPath()
                    guard canonical.path.hasPrefix(sourceRoot.path + "/") else { continue }
                    matches.append(canonical)
                }
            }
        }
        guard !matches.isEmpty else { throw failure("The CLI transcript for this conversation could not be found. Its login was left unchanged to preserve context.") }
        var copies: [(URL, URL)] = []
        for file in matches {
            let relative = String(file.path.dropFirst(sourceRoot.path.count + 1))
            let destination = targetRoot.appendingPathComponent(relative)
            if manager.fileExists(atPath: destination.path) {
                guard manager.contentsEqual(atPath: file.path, andPath: destination.path) else {
                    throw failure("This login already holds a different copy of this conversation. Choose New login… to preserve both copies.")
                }
            } else { copies.append((file, destination)) }
        }
        for (file, destination) in copies {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.copyItem(at: file, to: destination)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }
    static func failure(_ text: String) -> NSError { NSError(domain: "Converse", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
