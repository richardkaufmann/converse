import Foundation

// Clock-injected policy: incoming output never extends a user's reading
// timeout. Only scroll/keyboard/selection interaction does.
struct TranscriptFollowState {
    private(set) var following = true
    private(set) var unreadUpdates = 0
    private(set) var lastInteractionAt: TimeInterval = 0
    static let idleDelay: TimeInterval = 5
    mutating func pause(now: TimeInterval) { following = false; lastInteractionAt = now }
    mutating func interaction(now: TimeInterval) { lastInteractionAt = now }
    mutating func scroll(nearBottom: Bool, now: TimeInterval) {
        lastInteractionAt = now
        if nearBottom { resume() } else { following = false }
    }
    mutating func outputArrived() { if !following { unreadUpdates += 1 } }
    mutating func resume() { following = true; unreadUpdates = 0 }
    mutating func resumeIfIdle(now: TimeInterval, selecting: Bool, scrolling: Bool) -> Bool {
        guard !following, !selecting, !scrolling, now - lastInteractionAt >= Self.idleDelay else { return false }
        resume(); return true
    }
}

// Display classification only; never executes JSON or changes stored text.
enum TranscriptStyle {
    static func trafficSummary(_ source: String, queued: Bool = false) -> String? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        func clipped(_ value: String, limit: Int = 100) -> String {
            let flat = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
        }
        func name(_ value: String) -> String { clipped(value.components(separatedBy: " · session ")[0].components(separatedBy: " [")[0], limit: 35) }
        let lines = text.components(separatedBy: "\n")
        let detail = clipped(lines.dropFirst().joined(separator: " "))
        if text.hasPrefix("[Converse message from ") {
            let who = String((lines.first ?? "").dropFirst("[Converse message from ".count))
            return (queued ? "Queued ← " : "Received ← ") + name(who) + (text.contains("[Reply expected") ? " · Reply expected" : "") + (detail.isEmpty ? "" : " · " + detail)
        }
        if text.hasPrefix("[Converse switchboard recovery") { return "Reply needed · " + clipped(detail) }
        if text.hasPrefix("[Converse switchboard supervision") { return "Needs attention · " + clipped(detail) }
        if text.hasPrefix("[Converse switchboard ") { return "Switchboard · " + clipped(String((lines.first ?? "").dropFirst(1).dropLast())) }
        if text.hasPrefix("Switchboard:") {
            let header = String((lines.first ?? "").dropFirst("Switchboard:".count)).trimmingCharacters(in: .whitespaces)
            if header.hasPrefix("message queued from ") {
                return "Queued ← " + name(String(header.dropFirst("message queued from ".count))) + (detail.isEmpty ? "" : " · " + detail)
            }
            if let arrow = header.range(of: "→") {
                let status = header.contains("awaiting home") ? "Sending" : header.hasPrefix("queued") ? "Queued" : "Sent"
                return status + " → " + name(String(header[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)) + (detail.isEmpty ? "" : " · " + detail)
            }
            return "Switchboard · " + clipped(header)
        }
        if text.hasPrefix("```converse\n"), text.hasSuffix("\n```"),
           let data = String(text.dropFirst(12).dropLast(4)).data(using: .utf8),
           let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let action = command["command"] as? String ?? "command"
            if action == "tell" || action == "ask" || action == "tell-urgently" {
                return (action == "ask" ? "Ask → " : "Tell → ") + clipped(command["to"] as? String ?? "session", limit: 28) + " · " + clipped(command["text"] as? String ?? "")
            }
            return "Switchboard · " + action
        }
        return nil
    }
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
