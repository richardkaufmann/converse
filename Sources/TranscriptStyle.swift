import Foundation
#if os(macOS)
import AppKit

/// Presentation only. The original message stays in the archive, model context,
/// switchboard parser and Copy Message source.
struct TranscriptDisclosure {
    let prefix: String
    let details: String
    let summary: String
    static let attribute = NSAttributedString.Key("ConverseDisclosure")

    static func parse(_ source: String, role: String, resolveName: (String) -> String? = { _ in nil }) -> Self? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if role != "assistant", text.hasPrefix("[Parking Lot · "),
           let start = text.range(of: "\n{"),
           let json = String(text[start.lowerBound...]).data(using: .utf8) {
            if let value = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
               let revision = value["revision"] as? Int, value["rows"] is [[String: Any]] {
                return Self(prefix: "", details: text, summary: "Read Parking Lot · revision \(revision)")
            }
        }
        guard role == "assistant", case .command(let command) = SwitchboardCommand.trailing(text),
              ["ask", "tell", "tell-urgently", "parking-lot-edit"].contains(command.command),
              let opening = text.range(of: "```converse\n", options: .backwards) else { return nil }
        let fence = String(text[opening.lowerBound...])
        let summary: String
        if command.command == "parking-lot-edit", let edits = command.parkingLotEdits {
            summary = "Parking Lot changes · \(edits.operations.count) operations · revision \(edits.revision)"
        } else {
            guard command.to != nil, command.text != nil, let value = TranscriptStyle.trafficSummary(fence, resolveName: resolveName) else { return nil }; summary = value
        }
        return Self(prefix: String(text[..<opening.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                    details: fence, summary: summary)
    }

    func rendered(id: UUID, expanded: Bool, fontSize: CGFloat,
                  base: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
        let body = prefix.isEmpty ? NSMutableAttributedString(string: "") : MarkdownText.render(prefix)
        if !prefix.isEmpty {
            PaneTextSize.scale(body, by: fontSize / CGFloat(PaneTextSize.standard))
            let references = TranscriptStyle.imageReferences(prefix)
            body.enumerateAttribute(.link, in: NSRange(location: 0, length: body.length)) { value, range, _ in
                guard let url = value as? URL, let reference = references.first(where: { $0.url == url }) else { return }
                body.addAttribute(.converseImageLink, value: ResponseImageLink(messageID: id, url: url, caption: reference.caption), range: range)
            }
            body.append(NSAttributedString(string: "\n", attributes: base))
        }
        let attributes = base.merging([
            .link: URL(string: "converse-disclosure://" + id.uuidString)!,
            Self.attribute: id.uuidString,
            .toolTip: expanded ? "Hide full message" : "Show full message",
            .foregroundColor: NSColor.secondaryLabelColor
        ]) { _, new in new }
        body.append(NSAttributedString(string: (expanded ? "▾ " : "▸ ") + summary, attributes: attributes))
        if expanded { body.append(NSAttributedString(string: "\n" + details, attributes: base)) }
        return body
    }
}
#endif

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
        // Every render asks about ordinary history too. Reject it before
        // splitting, flattening and scanning the entire message body.
        guard text.hasPrefix("[Converse message from ") || text.hasPrefix("[Converse switchboard")
                || text.hasPrefix("Switchboard:") || text.hasPrefix("```converse\n") else { return nil }
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
    // Captions stop at any bracket, and caption and target are bounded and
    // never backtrack, so each `!` costs a few steps even on long nested or
    // unclosed lines. A bracket inside a caption means it is not an image.
    static func localImageReferences(_ text: String) -> [TranscriptImageReference] {
        let expression = try! NSRegularExpression(pattern: #"!\[([^\[\]\r\n]{0,512}+)\]\(\s*(?:<([^>\r\n]{1,4096})>|(file://[^\r\n\)]{1,4096}|[^\s\)]{1,4096}+))\s*\)"#)
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
        let regex = try! NSRegularExpression(pattern: #"!\[([^\[\]\r\n]{0,512}+)\]\(\s*(?:<([^>\r\n]{1,4096})>|([^\s\)]{1,4096}+))\s*\)"#)
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
        // A failed local capture must not collapse silently to just its alt text.
        // This is display-only: the original reference remains retryable on disk.
        let references = imageReferences(text) + localImageReferences(text).map {
            TranscriptImageReference(range: $0.range, caption: "Image not displayed" + ($0.caption.isEmpty ? "" : ": " + $0.caption), url: $0.url)
        }
        return splice(text, references.map { ref in
            var label = ""
            for character in ref.url.absoluteString { if "\\`*_[]<>~".contains(character) { label.append("\\") }; label.append(character) }
            return (ref.range, (ref.caption.isEmpty ? "" : ref.caption + ": ") + "[" + label + "](" + ref.url.absoluteString + ")")
        })
    }
    // Replaces ranges found in `text` in one forward pass. Separate scans can
    // overlap (a spaced file:// reference may enclose a web image), so the
    // earliest, then longest, range wins and any range it touches is dropped.
    // Ranges outside the text are ignored rather than raising.
    static func splice(_ text: String, _ replacements: [(range: NSRange, with: String)]) -> String {
        let source = text as NSString
        let result = NSMutableString()
        var cursor = 0
        for item in replacements.sorted(by: { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length })
        where item.range.location >= cursor && item.range.length > 0 && item.range.location <= source.length && item.range.length <= source.length - item.range.location {
            result.append(source.substring(with: NSRange(location: cursor, length: item.range.location - cursor)))
            result.append(item.with)
            cursor = NSMaxRange(item.range)
        }
        result.append(source.substring(from: cursor))
        return result as String
    }
}
