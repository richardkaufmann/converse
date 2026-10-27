import Foundation
import AppKit

struct SessionIdentity: Codable {
    var title: String
    var transcriptUuid: String
    var converseSessionId: String
    var createdAt: Date
    var titleUpdatedAt: Date
    var converseVersion: String
    var live: Bool
    var closedAt: Date?
}

extension Store {
    func identityURL(_ session: Session) -> URL? {
        guard session.entry.engine == "claude", let uuid = UUID(uuidString: session.remoteID ?? session.id.uuidString) else { return nil }
        return identityFolder.appendingPathComponent(uuid.uuidString.lowercased() + ".json")
    }
    private func writeIdentity(_ session: Session, at url: URL, live: Bool) throws {
        try FileManager.default.createDirectory(at: identityFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let record = SessionIdentity(title: session.title, transcriptUuid: url.deletingPathExtension().lastPathComponent, converseSessionId: session.id.uuidString, createdAt: session.createdAt, titleUpdatedAt: session.titleUpdatedAt, converseVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development", live: live, closedAt: live ? nil : Date())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // The replacement is prepared read-only before rename. Readers see an
        // entire old or new record, including when the previous file is 0444.
        let temp = identityFolder.appendingPathComponent("." + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        try encoder.encode(record).write(to: temp, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: temp.path)
        guard rename(temp.path, url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    func syncIdentity(_ session: Session) {
        do {
            let url = identityURL(session)
            if let previous = session.identityPath, previous != url?.path {
                try writeIdentity(session, at: URL(fileURLWithPath: previous), live: false)
                session.identityPath = nil
            }
            if let url { try writeIdentity(session, at: url, live: true); session.identityPath = url.path }
            session.identityError = ""
        } catch {
            session.identityError = error.localizedDescription
            session.probeError = "Could not update session identity: " + error.localizedDescription
            NSLog("Session identity update failed: %@", error.localizedDescription)
        }
    }
    func closeIdentity(_ session: Session) throws {
        if let path = session.identityPath { try writeIdentity(session, at: URL(fileURLWithPath: path), live: false) }
    }
    func localContext(_ session: Session, directory: String, at date: Date = Date()) -> String {
        let zone = TimeZone.current
        let formatter = ISO8601DateFormatter(); formatter.timeZone = zone
        let quoted = String(data: try! JSONEncoder().encode(session.title), encoding: .utf8)!
        var identity = "session title \(quoted); session id \(session.id.uuidString)"
        if let path = session.identityPath, session.identityError.isEmpty {
            identity += "; Claude transcript UUID \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent); read-only session identity sidecar \(path)"
        }
        if !session.identityError.isEmpty { identity += "; session identity sidecar unavailable" }
        return "[Local context from Converse: \(identity); time zone \(zone.identifier) (\(zone.abbreviation() ?? "local")); local time at send \(formatter.string(from: date)); working directory \(directory). Use this time zone for dates and times unless I request another.]"
    }
}

func identitySelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-identity-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root)
    let entry = Entry(name: "Claude", command: "claude", directory: root.path, engine: "claude")
    let session = store.create(entry)
    func read(_ url: URL) -> SessionIdentity? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(SessionIdentity.self, from: $0) }
    }
    let initial = store.identityURL(session)!
    check(read(initial)?.converseSessionId == session.id.uuidString && read(initial)?.live == true, "Claude identity is written at session creation")
    let transcript = UUID().uuidString
    session.remoteID = transcript; session.started = true
    let path = store.identityURL(session)!
    check(path.lastPathComponent == transcript.lowercased() + ".json" && read(initial)?.live == false, "Actual transcript UUID selects sidecar and retires an earlier key")
    let peer = store.create(entry); peer.title = "Other seat"
    session.busy = true; session.title = "Renamed \"seat\""
    let record = read(path)!
    check(record.title == session.title && record.transcriptUuid == transcript.lowercased() && record.live && read(store.identityURL(peer)!)?.title == "Other seat", "Renaming a running Claude updates only its own transcript identity immediately")
    let context = store.localContext(session, directory: root.path)
    check(context.contains("session title \"Renamed \\\"seat\\\"\"") && context.contains(session.id.uuidString) && context.contains(path.path), "Next message context quotes the current title and identifies its Converse seat and sidecar")
    let loaded = Store(folder: root)
    check(loaded.sessions.first(where: { $0.id == session.id })?.title == session.title && read(path)?.title == session.title, "Identity title and timestamps survive archive reload")
    check((try? FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int) == 0o444, "Identity records are published read-only")
    try! store.closeIdentity(session)
    check(read(path)?.live == false && read(path)?.closedAt != nil, "Closing a session publishes an explicit tombstone")
    // Exercise the same atomic writer while a reader repeatedly decodes it.
    let failures = NSMutableArray()
    let group = DispatchGroup(); group.enter()
    DispatchQueue.global().async {
        for _ in 0..<500 { if read(path) == nil { failures.add("partial") } }
        group.leave()
    }
    for index in 0..<50 { session.title = "Atomic \(index)" }
    group.wait()
    check(failures.count == 0 && read(path)?.title == session.title, "Concurrent sidecar reads always decode a complete record during repeated renames")
    let fixture = FileManager.default.currentDirectoryPath + "/Tests/provider_fixture.py"
    let liveEntry = Entry(name: "Claude", command: "python3 " + ProviderCommand.quote(fixture) + " claude", directory: root.path, engine: "claude", accountDirectory: root.appendingPathComponent("fixture-claude-account").path)
    let live = store.create(liveEntry)
    store.includesLocalContext = true
    func pump(_ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    live.title = "Before rename"; live.draft = "identity-wait"; store.send(live)
    pump { live.remoteID != nil }
    check(live.busy && live.remoteID?.lowercased() == live.id.uuidString.lowercased(), "Running CLI reports the exact transcript UUID used by its sidecar")
    live.title = "Renamed while running"
    pump { !live.busy }
    live.draft = "identity-check"; store.send(live); pump { !live.busy }
    let answer = live.messages.last?.text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let pulled = answer?["identity"] as? [String: Any]
    let pushed = answer?["prompt"] as? String ?? ""
    check(pulled?["title"] as? String == live.title && pulled?["transcriptUuid"] as? String == live.remoteID?.lowercased() && pushed.contains("session title \"Renamed while running\"") && pushed.contains(live.id.uuidString), "End-to-end: rename during a running CLI turn is visible in its file read and next dispatched prompt")
    let text = ConversationTextView(frame: .zero)
    text.copyBlocks = [.init(range: NSRange(location: 0, length: 6), role: "user", source: "prompt", formatted: NSAttributedString(string: "prompt")), .init(range: NSRange(location: 10, length: 8), role: "assistant", source: "response", formatted: NSAttributedString(string: "response"))]
    check(text.copyAction(at: 2)?.title == "Copy this prompt" && text.copyAction(at: 12)?.title == "Copy this response" && text.copyAction(at: 8) == nil && text.copyAction(at: 18) == nil, "Copy menu chooses one message action and none for gaps or the draft")
}
