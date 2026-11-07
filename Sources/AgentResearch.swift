import Foundation

struct AgentWebSource: Codable, Equatable {
    var title: String
    var url: String
    // A 1-2 word citation label from the result title, falling back to the
    // domain when the title is missing or unwieldy. Brackets never survive:
    // labels render inside Markdown links.
    static func shortLabel(title: String, url: String) -> String {
        let words = title.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(CharacterSet(charactersIn: "[]()"))) }
            .filter { !$0.isEmpty }
        let candidate = words.prefix(2).joined(separator: " ")
        if !candidate.isEmpty, candidate.count <= 30 { return candidate }
        return domainLabel(url) ?? "Source"
    }
    static func domainLabel(_ value: String) -> String? {
        guard let host = safeURL(value)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    static func safeURL(_ value: String) -> URL? {
        guard value.utf8.count <= 2048, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct AgentResearch {
    var searched = false
    var sources: [AgentWebSource] = []
    static func parse(_ response: [String: Any]) -> Self {
        var result = Self()
        for item in response["output"] as? [[String: Any]] ?? [] {
            if item["type"] as? String == "web_search_call" {
                result.searched = true
                for source in item["results"] as? [[String: Any]] ?? [] { result.add(source) }
            }
            for block in item["content"] as? [[String: Any]] ?? [] {
                for source in block["annotations"] as? [[String: Any]] ?? [] where source["type"] as? String == "url_citation" { result.add(source) }
            }
        }
        return result
    }
    private mutating func add(_ source: [String: Any]) {
        guard sources.count < 32, let url = source["url"] as? String, AgentWebSource.safeURL(url) != nil,
              !sources.contains(where: { $0.url == url }) else { return }
        sources.append(AgentWebSource(title: String((source["title"] as? String ?? URL(string: url)?.host ?? "Source").prefix(200)), url: url))
    }
    /// Search sources the host appends after a reply. The agent's own citations
    /// follow its objective (e.g. "max two links"), so when the reply already
    /// links anything, add nothing; otherwise show at most three.
    func appendix(for reply: String) -> String {
        guard !sources.isEmpty, !reply.contains("http://"), !reply.contains("https://") else { return "" }
        return "\n\nSources: " + AgentResearch(searched: searched, sources: Array(sources.prefix(3))).markdown
    }
    var markdown: String {
        sources.map { source in
            "[\(AgentWebSource.shortLabel(title: source.title, url: source.url))](<\(source.url.replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "<", with: "%3C"))>)"
        }.joined(separator: " · ")
    }
}

struct AgentScoreboard: Codable, Equatable {
    struct Metric: Codable, Equatable {
        var label: String
        var value: String
        var sourceURL: String?
        var asOf: String?
    }
    var title: String?
    var summary: String
    var metrics: [Metric]
    var sentiment: String?
    var observedAt: Date?
    var sources: [AgentWebSource]?
    func validated(research: AgentResearch, at now: Date = Date()) -> Self {
        var result = self
        result.title = title.map { String($0.prefix(100)) }
        result.summary = summary.split(whereSeparator: { $0.isWhitespace }).prefix(20).joined(separator: " ")
        result.sentiment = ["up", "down", "mixed", "neutral", "urgent", "peaceful"].contains(sentiment ?? "") ? sentiment : "neutral"
        result.observedAt = now
        result.sources = research.sources
        result.metrics = metrics.prefix(12).map { item in
            let supported = research.searched && research.sources.contains { $0.url == item.sourceURL }
            return Metric(label: String(item.label.prefix(60)), value: supported ? String(item.value.prefix(120)) : "Unavailable",
                          sourceURL: supported ? item.sourceURL : nil, asOf: supported ? item.asOf.map { String($0.prefix(160)) } : nil)
        }
        return result
    }
}

// Local counts are measured by the host, never inferred from generated prose or
// passed through the validator for external web-search claims.
struct AgentLotScoreboard: Codable, Equatable {
    struct Section: Codable, Equatable {
        var title: String
        var unfinished: Int
        var colors: [String: Int]
        var value: String {
            let tags = ParkingLotTag.allCases.compactMap { tag -> String? in
                let count = colors[tag.rawValue] ?? 0
                return count == 0 ? nil : "\(count) \(tag.rawValue)"
            }
            return String(unfinished) + (tags.isEmpty ? "" : " (" + tags.joined(separator: ", ") + ")")
        }
    }
    var id: UUID
    var home: String?
    var name: String
    var revision: Int
    var observedAt: Date
    var sections: [Section]
    static func measure(id: UUID, home: String?, name: String, document: ParkingLotDocument, now: Date) -> Self {
        var sections: [Section] = []
        for row in document.rows {
            if row.heading { sections.append(Section(title: row.text, unfinished: 0, colors: [:])); continue }
            guard !row.isDone else { continue }
            if sections.isEmpty { sections.append(Section(title: "Items", unfinished: 0, colors: [:])) }
            sections[sections.count - 1].unfinished += 1
            if let tag = row.tag { sections[sections.count - 1].colors[tag.rawValue, default: 0] += 1 }
        }
        return Self(id: id, home: home, name: name, revision: document.revision, observedAt: now, sections: sections)
    }
}

extension AgentConfig {
    var visibleLotScoreboards: [AgentLotScoreboard] {
        (lotScoreboards ?? []).filter { allows(local: $0.id, home: $0.home) }
    }
    // Strip timestamps and explanatory prose out of the art-change comparison.
    // Include host measurements even when the model omits a scoreboard object.
    var artMeasurementBoard: AgentScoreboard {
        var board = scoreboard ?? AgentScoreboard(summary: "", metrics: [])
        for lot in visibleLotScoreboards {
            board.metrics += lot.sections.map { .init(label: lot.id.uuidString + "/" + $0.title, value: $0.value) }
        }
        if let repo = repositorySnapshot { board.metrics += repo.metrics.map { .init(label: "GitHub/" + $0.0, value: $0.1) } }
        return board
    }
    func measuredArtMood(fallback: String) -> String {
        let sections = visibleLotScoreboards.flatMap(\.sections)
        if sections.contains(where: { ($0.colors["red"] ?? 0) > 0 }) { return "urgent" }
        let bugs = sections.filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "bugs" }
        if bugs.contains(where: { $0.unfinished > 0 }) || (repositorySnapshot?.openBugs ?? 0) > 0 { return "watchful" }
        if !bugs.isEmpty || repositorySnapshot?.openBugs == 0 { return "peaceful" }
        return fallback
    }
}
