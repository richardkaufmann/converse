import Foundation

struct HelpTopic: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let markdown: String
    let plainText: String
}

// Shared content format for Mac, iPad, and Windows. Generated from README.md;
// search and rendering adapters do not need a network connection.
struct HelpBook: Codable {
    let schemaVersion: Int
    let appVersion: String
    let appBuild: String
    let sourceCommit: String
    let title: String
    let sourceURL: String
    let sourceSHA256: String
    let topics: [HelpTopic]

    static func load(bundle: Bundle = .main) throws -> HelpBook {
        guard let url = bundle.url(forResource: "Content", withExtension: "json", subdirectory: "Help") else { throw CocoaError(.fileNoSuchFile) }
        let book = try JSONDecoder().decode(HelpBook.self, from: Data(contentsOf: url))
        guard book.schemaVersion == 1, !book.topics.isEmpty, Set(book.topics.map(\.id)).count == book.topics.count else { throw CocoaError(.fileReadCorruptFile) }
        return book
    }
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    func search(_ query: String, limit: Int = .max) -> [HelpTopic] {
        let phrase = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !phrase.isEmpty else { return Array(topics.prefix(max(0, limit))) }
        return topics.enumerated().compactMap { index, topic -> (Int, Int, HelpTopic)? in
            let text = Self.normalized(topic.plainText), title = Self.normalized(topic.title)
            guard text.contains(phrase) || title.contains(phrase) else { return nil }
            return (title.contains(phrase) ? 0 : 1, index, topic)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.prefix(max(0, limit)).map { $0.2 }
    }
}

func helpSelfTests(_ check: (Bool, String) -> Void) {
    let topics = [HelpTopic(id: "connect", title: "Connect devices", markdown: "Compare all eight code groups.", plainText: "Connect devices Compare all eight code groups."), HelpTopic(id: "accounts", title: "Accounts", markdown: "Connect a named login.", plainText: "Accounts Connect a named login.")]
    let book = HelpBook(schemaVersion: 1, appVersion: "test", appBuild: "0", sourceCommit: "fixture", title: "Help", sourceURL: "https://example.invalid", sourceSHA256: "fixture", topics: topics)
    check(book.search("CONNECT").map(\.id) == ["connect", "accounts"] && book.search("eight code").map(\.id) == ["connect"], "Help search covers topic titles and article phrases, ignoring case")
    check(book.search("missing").isEmpty && book.search("connect", limit: 0).isEmpty && book.search("", limit: 1).count == 1, "Help search handles no matches, empty searches and menu result limits")
    do {
        let bundled = try HelpBook.load()
        check(bundled.sourceSHA256.count == 64 && bundled.topics.contains { $0.id == "accounts" } && !bundled.search("pair").isEmpty, "Offline Help contains searchable README topics and source provenance")
    } catch { check(false, "Offline Help content loads from this app bundle: \(error.localizedDescription)") }
}
