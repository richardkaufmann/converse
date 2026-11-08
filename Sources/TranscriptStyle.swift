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
        if role != "assistant", let summary = TranscriptSelfRead.disclosureSummary(text) {
            return Self(prefix: "", details: text, summary: summary)
        }
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

/// One part of a message that Inject all combined from several queued
/// prompts: a UTF-16 range of the stored text and how that part renders.
/// Presentation only. The stored text stays authoritative for the provider,
/// Copy Message, context and handoff.
struct MessageComponent: Codable, Equatable {
    var offset: Int
    var length: Int
    /// "traffic" may collapse to its own summary. "human" (typed in a
    /// composer) and "text" (anything else) always stay visible.
    var kind: String
    static let traffic = "traffic", human = "human", text = "text"
    /// Stands in for recorded parts that could not be decoded (a null
    /// entry, a wrong type). It never tiles, so the message shows whole and
    /// expanded, like any other invalid parts.
    static let undecodable = [MessageComponent(offset: -1, length: 0, kind: text)]
}
extension MessageComponent {
    /// A missing or null kind is an ordinary visible part (Windows parity).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offset = try c.decode(Int.self, forKey: .offset); length = try c.decode(Int.self, forKey: .length)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? Self.text
    }
}
extension KeyedDecodingContainer {
    /// Inject all parts are presentation only: unreadable ones never fail
    /// the message, archive or snapshot that carries them. Core's
    /// LenientComponentsConverter mirrors this; both run the shared
    /// Tests/inject-components-vectors.json.
    func decodeComponents(forKey key: Key) -> [MessageComponent]? {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return nil }
        guard let parts = try? decode([MessageComponent?].self, forKey: key), !parts.contains(where: { $0 == nil }) else { return MessageComponent.undecodable }
        return parts.compactMap { $0 }
    }
}
/// One rendered part of a message. A nil summary shows `text` in full.
struct TranscriptSegment: Equatable {
    var text: String
    var summary: String?
}
extension TranscriptStyle {
    /// Inject all joins queued prompts with this separator.
    static let injectSeparator = "\n\n"
    static func componentKind(_ text: String, typed: Bool) -> String {
        typed ? MessageComponent.human : trafficSummary(text) != nil ? MessageComponent.traffic : MessageComponent.text
    }
    /// Component ranges for parts joined by Inject all, or nil unless the
    /// parts reproduce the merged text exactly.
    static func components(joining parts: [(text: String, kind: String)], into text: String) -> [MessageComponent]? {
        guard parts.count > 1, parts.map(\.text).joined(separator: injectSeparator) == text else { return nil }
        var offset = 0
        return parts.map { part in
            let length = (part.text as NSString).length
            defer { offset += length + (injectSeparator as NSString).length }
            return MessageComponent(offset: offset, length: length, kind: part.kind)
        }
    }
    /// One visible part over all of `text`: what a merged message renders
    /// as when its recorded ranges cannot be carried through a rewrite.
    static func expandedComponents(_ text: String) -> [MessageComponent] {
        [MessageComponent(offset: 0, length: (text as NSString).length, kind: MessageComponent.text)]
    }
    /// Whether recorded ranges are in order, inside the text, and leave
    /// nothing but whitespace uncovered.
    static func componentsTile(_ source: String, _ components: [MessageComponent]) -> Bool {
        let whole = source as NSString
        func blank(_ range: NSRange) -> Bool { whole.substring(with: range).allSatisfy(\.isWhitespace) }
        var cursor = 0
        for component in components {
            guard component.offset >= cursor, component.offset <= whole.length, component.length >= 0,
                  component.length <= whole.length - component.offset,
                  blank(NSRange(location: cursor, length: component.offset - cursor)) else { return false }
            cursor = component.offset + component.length
        }
        return blank(NSRange(location: cursor, length: whole.length - cursor))
    }
    /// Components for `text`, a display, export or import rewrite of
    /// `source`. Parts survive when rewriting each piece reproduces `text`
    /// exactly; anything else that had parts becomes one visible part, so
    /// lost or invalid ranges never fall back to a whole-message summary.
    static func components(_ components: [MessageComponent]?, from source: String, to text: String, rewrite: (String) -> String) -> [MessageComponent]? {
        guard let components else { return nil }
        guard componentsTile(source, components) else { return expandedComponents(text) }
        if text == source { return components }
        let whole = source as NSString
        var rebuilt = "", cursor = 0, result: [MessageComponent] = []
        for component in components {
            rebuilt += rewrite(whole.substring(with: NSRange(location: cursor, length: component.offset - cursor)))
            let part = rewrite(whole.substring(with: NSRange(location: component.offset, length: component.length)))
            result.append(MessageComponent(offset: (rebuilt as NSString).length, length: (part as NSString).length, kind: component.kind))
            rebuilt += part
            cursor = component.offset + component.length
        }
        rebuilt += rewrite(whole.substring(from: cursor))
        return rebuilt == text ? result : expandedComponents(text)
    }
    /// Order-sensitive key for recorded parts (offset, length, kind); nil
    /// and [] differ. Parts alone decide what a message or queue row shows,
    /// so any cache of one keys on this along with its text.
    static func componentsKey(_ components: [MessageComponent]?) -> String {
        guard let components else { return "-" }
        return "[" + components.map { "\($0.offset),\($0.length),\($0.kind.utf16.count):\($0.kind)" }.joined(separator: ";") + "]"
    }
    /// One-line queue label: a summary only when the whole item is traffic.
    static func queueSummary(_ text: String, components: [MessageComponent]? = nil) -> String? {
        segments(text, components: components) == nil ? trafficSummary(text, queued: true) : nil
    }
    /// Parts of a merged message to render separately: traffic parts with
    /// their own summary, everything else in full. Nil renders the message
    /// whole, exactly as before. Recorded components that do not tile the
    /// text show it all expanded; only messages without them use the
    /// conservative legacy split.
    static func segments(_ source: String, components: [MessageComponent]?, resolveName: (String) -> String? = { _ in nil }) -> [TranscriptSegment]? {
        guard let components else { return legacySegments(source, resolveName: resolveName) }
        // Untrusted ranges never hide text, and never fall back to a
        // whole-message summary that could cover a typed part.
        guard componentsTile(source, components) else { return [TranscriptSegment(text: source, summary: nil)] }
        let whole = source as NSString
        var result: [TranscriptSegment] = [], plainStart: Int?
        for component in components {
            let part = whole.substring(with: NSRange(location: component.offset, length: component.length))
            let summary = component.kind == MessageComponent.traffic ? trafficSummary(part, resolveName: resolveName) : nil
            let end = component.offset + component.length
            if part.allSatisfy(\.isWhitespace) { continue }
            // Adjacent visible parts stay one block with their separator.
            if summary == nil, let start = plainStart {
                result[result.count - 1].text = whole.substring(with: NSRange(location: start, length: end - start)); continue
            }
            plainStart = summary == nil ? component.offset : nil
            result.append(TranscriptSegment(text: part, summary: summary))
        }
        // Plain parts alone render as before, unless the whole would
        // otherwise collapse over a visible part.
        return !result.isEmpty && (result.contains { $0.summary != nil } || trafficSummary(source) != nil) ? result : nil
    }
    /// Messages merged before component metadata. Splits only after a
    /// complete delivery block followed by the Inject all separator, and
    /// never says who wrote the remainder. A delivery block followed by
    /// anything else shows the whole message expanded. A plain tell has no
    /// delivery block, so an old merge of one with typed text cannot be told
    /// apart from a multi-paragraph tell: it still collapses, as before.
    static func legacySegments(_ source: String, resolveName: (String) -> String? = { _ in nil }) -> [TranscriptSegment]? {
        let envelope = "[Converse message from "
        // Every render asks about ordinary prompts too; check before copying.
        guard source.drop(while: \.isWhitespace).hasPrefix(envelope) else { return nil }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [TranscriptSegment] = [], rest = Substring(text), trailing = false
        while rest.hasPrefix(envelope) {
            guard let (end, next) = deliveryEnd(rest, trailing: &trailing) else { break }
            let part = String(rest[..<end])
            result.append(TranscriptSegment(text: part, summary: trafficSummary(part, resolveName: resolveName)))
            rest = rest[next...]
        }
        if result.isEmpty { return trailing ? [TranscriptSegment(text: source, summary: nil)] : nil }
        let remainder = rest.trimmingCharacters(in: .newlines)
        if !remainder.isEmpty { result.append(TranscriptSegment(text: remainder, summary: nil)) }
        return result.count > 1 ? result : nil
    }
    /// End of the first delivery block that closes an envelope, and where
    /// the next part starts (the end of the text when nothing follows).
    private static func deliveryEnd(_ text: Substring, trailing: inout Bool) -> (Substring.Index, Substring.Index)? {
        let reply = "[Reply to request ", expected = "[Reply expected · request ID:\n"
        func uuid(_ from: Substring.Index) -> Substring.Index? {
            guard let end = text.index(from, offsetBy: 36, limitedBy: text.endIndex), UUID(uuidString: String(text[from..<end])) != nil else { return nil }
            return end
        }
        func expectedEnd(_ from: Substring.Index) -> Substring.Index? {
            guard text[from...].hasPrefix(expected), let id = uuid(text.index(from, offsetBy: expected.count)),
                  text[id...].hasPrefix("\n"), let close = text[id...].firstIndex(of: "]") else { return nil }
            return text.index(after: close)
        }
        func blockEnd(_ from: Substring.Index) -> Substring.Index? {
            if text[from...].hasPrefix(reply) {
                guard let id = uuid(text.index(from, offsetBy: reply.count)), text[id...].hasPrefix("]") else { return nil }
                let end = text.index(after: id)
                if text[end...].hasPrefix("\n" + expected) { return expectedEnd(text.index(after: end)) }
                return end
            }
            return expectedEnd(from)
        }
        var search = text.startIndex
        while let marker = text[search...].firstIndex(of: "\n") {
            search = text.index(after: marker)
            guard text[search...].hasPrefix(reply) || text[search...].hasPrefix(expected), let end = blockEnd(search) else { continue }
            let after = text[end...]
            if after.allSatisfy(\.isWhitespace) { return (end, text.endIndex) }
            if after.hasPrefix(injectSeparator) { return (end, text.index(end, offsetBy: injectSeparator.count)) }
            trailing = true
        }
        return nil
    }
}

struct TranscriptImageReference {
    var range: NSRange
    var caption: String
    var url: URL
}
extension TranscriptStyle {
    // A bare target ends at its first `)`. If that leaves a `(` open, the
    // parenthesis is part of the path: scan to the balancing `)` within the
    // target's bound. Stopping at the next `![` keeps a whole line linear.
    // No balancing `)` leaves the original match unchanged.
    private static func balancedImageMatch(_ match: NSTextCheckingResult, in source: NSString) -> (target: NSRange, whole: NSRange) {
        guard match.range(at: 2).location == NSNotFound else { return (match.range(at: 2), match.range) }
        let bare = match.range(at: 3)
        var depth = 0
        for index in bare.location..<NSMaxRange(bare) where source.character(at: index) == 40 { depth += 1 }
        guard depth > 0 else { return (bare, match.range) }
        let spaced = source.substring(with: bare).hasPrefix("file://")
        func isSpace(_ unit: unichar) -> Bool { UnicodeScalar(unit).map(CharacterSet.whitespacesAndNewlines.contains) ?? false }
        let limit = min(source.length, bare.location + 4096)
        var index = NSMaxRange(bare)
        func closed(_ end: Int, _ close: Int) -> (target: NSRange, whole: NSRange) {
            (NSRange(location: bare.location, length: end - bare.location), NSRange(location: match.range.location, length: close + 1 - match.range.location))
        }
        while index < limit {
            let unit = source.character(at: index)
            if unit == 33, index + 1 < source.length, source.character(at: index + 1) == 91 { break }
            if unit == 13 { break }
            if !spaced, isSpace(unit) {
                var next = index
                while next < limit, isSpace(source.character(at: next)) { next += 1 }
                if depth == 0, next < limit, source.character(at: next) == 41 { return closed(index, next) }
                break
            }
            if unit == 40 { depth += 1 }
            else if unit == 41 {
                if depth == 0 { return closed(index, index) }
                depth -= 1
            }
            index += 1
        }
        return (bare, match.range)
    }
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
                let balanced = balancedImageMatch(match, in: source)
                let path = source.substring(with: balanced.target).trimmingCharacters(in: .whitespaces)
                let candidate: URL
                if path.hasPrefix("/") { candidate = URL(fileURLWithPath: path.removingPercentEncoding ?? path) }
                else if let url = URL(string: path), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" { candidate = url }
                else { continue }
                result.append(TranscriptImageReference(range: NSRange(location: offset + balanced.whole.location, length: balanced.whole.length), caption: source.substring(with: match.range(at: 1)), url: candidate))
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
                let balanced = balancedImageMatch(match, in: source)
                guard let url = URL(string: source.substring(with: balanced.target)), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { continue }
                result.append(TranscriptImageReference(range: NSRange(location: offset + balanced.whole.location, length: balanced.whole.length), caption: source.substring(with: match.range(at: 1)), url: url))
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
