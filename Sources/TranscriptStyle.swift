import Foundation

// Display classification only; never executes JSON or changes stored text.
enum TranscriptStyle {
    static let blockSpacing: CGFloat = 8
    // Trim only display terminators. Internal paragraphs and stored source,
    // including explicitly typed draft newlines, remain untouched.
    static func blockContentLength(_ source: String) -> Int {
        var value = source
        while value.last?.isNewline == true { value.removeLast() }
        return (value as NSString).length
    }
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

struct TranscriptImageReference {
    var range: NSRange
    var caption: String
    var url: URL
}
extension TranscriptStyle {
    static func imageReferences(_ text: String) -> [TranscriptImageReference] {
        let regex = try! NSRegularExpression(pattern: #"!\[([^\]\r\n]*)\]\(\s*(?:<([^>\r\n]+)>|([^\s\)]+))\s*\)"#)
        var result: [TranscriptImageReference] = [], offset = 0
        var fence: String?
        for line in text.components(separatedBy: "\n") {
            defer { offset += (line as NSString).length + 1 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                continue
            }
            guard fence == nil, !trimmed.hasPrefix(">"), !line.contains("`") else { continue }
            let source = line as NSString
            for match in regex.matches(in: line, range: NSRange(location: 0, length: source.length)) {
                guard match.range.location == 0 || source.substring(with: NSRange(location: match.range.location - 1, length: 1)) != "\\" else { continue }
                let range = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
                guard let url = URL(string: source.substring(with: range)), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { continue }
                result.append(TranscriptImageReference(range: NSRange(location: offset + match.range.location, length: match.range.length), caption: source.substring(with: match.range(at: 1)), url: url))
            }
        }
        return result
    }
    // Markdown image runs often expose only alt text. Until an attachment is
    // available, render an ordinary link so the destination never disappears.
    static func imageLinks(_ text: String) -> String {
        let result = NSMutableString(string: text)
        for ref in imageReferences(text).reversed() {
            let label = ref.caption.isEmpty ? "Open image" : ref.caption
            result.replaceCharacters(in: ref.range, with: "[" + label + "](" + ref.url.absoluteString + ")")
        }
        return result as String
    }
}
