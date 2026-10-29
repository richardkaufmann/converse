import Foundation

struct AgentWebSource: Codable, Equatable {
    var title: String
    var url: String
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
    var markdown: String {
        sources.enumerated().map { index, source in
            "[Source \(index + 1)](<\(source.url.replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "<", with: "%3C"))>)"
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
