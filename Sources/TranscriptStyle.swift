import Foundation

// Keep destinations when a rich-text selection is pasted into a plain-text app.
enum TranscriptClipboard {
    static func plainText(_ selection: NSAttributedString) -> String {
        let output = NSMutableString(string: selection.string)
        var links: [(Int, String)] = []
        selection.enumerateAttribute(NSAttributedString.Key("NSLink"), in: NSRange(location: 0, length: selection.length)) { value, range, _ in
            let url = (value as? URL)?.absoluteString ?? value as? String ?? ""
            guard !url.isEmpty, (selection.string as NSString).substring(with: range) != url else { return }
            links.append((NSMaxRange(range), " (\(url))"))
        }
        for (offset, suffix) in links.reversed() { output.insert(suffix, at: offset) }
        return output as String
    }
}

// Only user navigation pauses following. Scrolling without a planted cursor
// returns to the live tail after a short idle period.
struct TranscriptFollowState {
    private(set) var following = true
    private(set) var unreadUpdates = 0
    private(set) var lastInteractionAt: TimeInterval = 0
    static let idleDelay: TimeInterval = 30
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
    static func trafficSummary(_ source: String, queued: Bool = false, resolveName: (String) -> String? = { _ in nil }) -> String? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        func clipped(_ value: String, limit: Int = 100) -> String {
            let flat = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
        }
        func name(_ value: String) -> String { clipped(value.components(separatedBy: " · ")[0].components(separatedBy: " [")[0], limit: 35) }
        func destination(_ value: String) -> String {
            if let resolved = resolveName(value) { return clipped(resolved, limit: 35) }
            return UUID(uuidString: value) != nil || value.contains("/") ? "Unavailable session" : clipped(value, limit: 35)
        }
        let asks = text.contains("[Reply expected") || text.components(separatedBy: "\n")[0].contains("[ask]")
        // An incoming message carrying inReplyTo answers the recipient's own
        // request; it must read as a reply, not as a fresh tell or ask.
        let replies = text.contains("\n[Reply to request ")
        let kind = replies ? (asks ? "reply + ask" : "reply") : asks ? "ask" : "tell"
        // The delivery instructions trail the body; keep them out of the detail.
        let body = ["\n[Reply to request ", "\n[Reply expected"].compactMap { text.range(of: $0)?.lowerBound }.min().map { String(text[..<$0]) } ?? text
        let lines = text.components(separatedBy: "\n")
        let detail = clipped(body.components(separatedBy: "\n").dropFirst().joined(separator: " "))
        if text.hasPrefix("[Converse message from ") {
            let who = String((lines.first ?? "").dropFirst("[Converse message from ".count))
            return (queued ? "Queued " : "Received ") + kind + " from " + name(who) + (detail.isEmpty ? "" : " · " + detail)
        }
        if text.hasPrefix("[Converse switchboard recovery") { return "Reply needed · " + clipped(detail) }
        if text.hasPrefix("[Converse switchboard supervision") { return "Needs attention · " + clipped(detail) }
        if text.hasPrefix("[Converse switchboard ") { return "Switchboard · " + clipped(String((lines.first ?? "").dropFirst(1).dropLast())) }
        if text.hasPrefix("Switchboard:") {
            let header = String((lines.first ?? "").dropFirst("Switchboard:".count)).trimmingCharacters(in: .whitespaces)
            if header.hasPrefix("message queued from ") {
                return "Queued " + kind + " from " + name(String(header.dropFirst("message queued from ".count))) + (detail.isEmpty ? "" : " · " + detail)
            }
            if let arrow = header.range(of: "→") {
                if header.hasPrefix("reply delivered · turn interrupted →") {
                    return "Reply delivered to " + name(String(header[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)) + " · turn interrupted" + (detail.isEmpty ? "" : " · " + detail)
                }
                let known = ["reply sent · awaiting receipt", "recovery queued", "awaiting reply", "needs attention", "processing", "completed", "answered", "processed", "delivered", "failed", "cancelled"]
                let status = known.first(where: { header.hasPrefix($0 + " →") }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    ?? (header.contains("awaiting home") ? "Sending" : header.hasPrefix("queued") ? "Queued" : header.hasPrefix("rejected") ? "Rejected" : header.hasPrefix("delivery unconfirmed") ? "Unconfirmed" : "Sent")
                return status + " " + kind + " to " + name(String(header[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)) + (detail.isEmpty ? "" : " · " + detail)
            }
            return "Switchboard · " + clipped(header.components(separatedBy: " · ")[0])
        }
        if text.hasPrefix("```converse\n"), text.hasSuffix("\n```"),
           let data = String(text.dropFirst(12).dropLast(4)).data(using: .utf8),
           let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let action = command["command"] as? String ?? "command"
            if action == "tell" || action == "ask" || action == "tell-urgently" {
                return (action == "ask" || command["replyExpected"] as? Bool == true ? "Ask to " : "Tell to ") + destination(command["to"] as? String ?? "session") + " · " + clipped(command["text"] as? String ?? "")
            }
            return "Switchboard · " + action
        }
        return nil
    }
    static func isQueueReceipt(_ text: String) -> Bool { text.hasPrefix("Switchboard: message queued from ") }
    static let blockSpacing: CGFloat = 8
    // Trim only display terminators. Internal paragraphs and stored source,
    // including explicitly typed draft newlines, remain untouched.
    static func blockContentLength(_ source: String) -> Int {
        var value = source
        while value.last?.isNewline == true { value.removeLast() }
        return (value as NSString).length
    }
    static func isTraffic(_ source: String) -> Bool {
        trafficSummary(source) != nil
    }
}

struct TranscriptImageReference {
    var range: NSRange
    var caption: String
    var url: URL
}
extension TranscriptStyle {
    static func localImageReferences(_ text: String) -> [TranscriptImageReference] {
        let expression = try! NSRegularExpression(pattern: #"!\[([^\]\r\n]*)\]\(\s*(?:<([^>\r\n]+)>|(file://[^\r\n\)]+|[^\s\)]+))\s*\)"#)
        var result: [TranscriptImageReference] = [], offset = 0
        var fence: String?
        for line in text.components(separatedBy: "\n") {
            defer { offset += (line as NSString).length + 1 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3)); if fence == marker { fence = nil } else if fence == nil { fence = marker }; continue
            }
            guard fence == nil, !trimmed.hasPrefix(">"), !line.contains("`") else { continue }
            let source = line as NSString
            for match in expression.matches(in: line, range: NSRange(location: 0, length: source.length)) {
                guard match.range.location == 0 || source.substring(with: NSRange(location: match.range.location - 1, length: 1)) != "\\" else { continue }
                let urlRange = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
                let path = source.substring(with: urlRange).trimmingCharacters(in: .whitespaces)
                let candidate: URL
                if path.hasPrefix("/") { candidate = URL(fileURLWithPath: path.removingPercentEncoding ?? path) }
                else if let url = URL(string: path), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" { candidate = url }
                else { continue }
                result.append(TranscriptImageReference(range: NSRange(location: offset + match.range.location, length: match.range.length), caption: source.substring(with: match.range(at: 1)), url: candidate))
            }
        }
        return result
    }
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
    // Web images are never fetched unasked. Until the reader loads one, show
    // its caption and full URL as an ordinary link so the destination is plain.
    static func imageLinks(_ text: String) -> String {
        let result = NSMutableString(string: text)
        // A failed local capture must not collapse silently to just its alt text.
        // This is display-only: the original reference remains retryable on disk.
        let references = imageReferences(text) + localImageReferences(text).map {
            TranscriptImageReference(range: $0.range, caption: "Image not displayed" + ($0.caption.isEmpty ? "" : ": " + $0.caption), url: $0.url)
        }
        for ref in references.sorted(by: { $0.range.location > $1.range.location }) {
            var label = ""
            for character in ref.url.absoluteString { if "\\`*_[]<>~".contains(character) { label.append("\\") }; label.append(character) }
            result.replaceCharacters(in: ref.range, with: (ref.caption.isEmpty ? "" : ref.caption + ": ") + "[" + label + "](" + ref.url.absoluteString + ")")
        }
        return result as String
    }
}
