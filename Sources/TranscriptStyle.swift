import Foundation

// Display classification only; never executes JSON or changes stored text.
enum TranscriptStyle {
    static func isTraffic(_ source: String) -> Bool {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[Converse message from ") || text.hasPrefix("[Converse switchboard ") || text.hasPrefix("Switchboard:") { return true }
        if text.range(of: "^tell(?:-urgently)?\\s+\\S+\\s+", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if text.hasPrefix("```converse\n") { return true }
        var json = text
        if json.hasPrefix("```json\n"), json.hasSuffix("```") { json = String(json.dropFirst(8).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard json.hasPrefix("{") || json.hasPrefix("["), let data = json.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { return false }
        return value is [String: Any] || value is [Any]
    }
}
