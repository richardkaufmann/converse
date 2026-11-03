import Foundation

// Parking Lot text stays plain; links are found at display time. Shared by the
// Mac editor and the iPad/iPhone viewer. Ranges are UTF-16, matching NSString.
enum LotLinks {
    struct Link: Equatable {
        var range: NSRange   // whole source span, e.g. "[label](url)"
        var label: NSRange   // the part shown and clicked
        var url: URL
        var isFile: Bool { url.isFileURL }
        var isMarkdown: Bool { range != label }
    }
    private static let markdown = try! NSRegularExpression(pattern: #"\[([^\[\]\n ]+)\]\(([^()\s]+)\)"#)
    private static let bare = try! NSRegularExpression(pattern: #"(?<![^\s(<\[{"'])(?:(?i:https?://|mailto:|file://)|~/|/)\S+"#)
    static func find(in text: String) -> [Link] {
        let source = text as NSString
        let all = NSRange(location: 0, length: source.length)
        var links: [Link] = []
        for match in markdown.matches(in: text, range: all) {
            guard let url = url(source.substring(with: match.range(at: 2))) else { continue }
            links.append(Link(range: match.range, label: match.range(at: 1), url: url))
        }
        for match in bare.matches(in: text, range: all) where !links.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
            let token = trimmed(source.substring(with: match.range))
            guard let url = url(token) else { continue }
            let range = NSRange(location: match.range.location, length: (token as NSString).length)
            links.append(Link(range: range, label: range, url: url))
        }
        return links.sorted { $0.range.location < $1.range.location }
    }
    /// Only web, mail and local file forms. javascript: and custom schemes are never links.
    static func url(_ value: String) -> URL? {
        let lower = value.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: value), let host = url.host, !host.isEmpty else { return nil }
            return url
        }
        if lower.hasPrefix("mailto:") {
            guard value.dropFirst(7).contains("@"), let url = URL(string: value) else { return nil }
            return url
        }
        if lower.hasPrefix("file://") {
            guard let url = URL(string: value), url.isFileURL, url.host == nil || url.host == "localhost" || url.host == "",
                  url.path.hasPrefix("/"), url.path.count > 1 else { return nil }
            return url
        }
        // Bare absolute paths need two components ("/Users/x") so prose like "A /B" stays plain.
        if value.hasPrefix("~/"), value.count > 2 { return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath) }
        if value.range(of: #"^/[^/\s]+/"#, options: .regularExpression) != nil { return URL(fileURLWithPath: value) }
        return nil
    }
    /// Sentence punctuation and unbalanced closing brackets end a bare link.
    static func trimmed(_ token: String) -> String {
        var value = token
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{", ">": "<"]
        while let last = value.last {
            if ".,;:!?'\"".contains(last) { value.removeLast(); continue }
            if let open = pairs[last], value.filter({ $0 == last }).count > value.filter({ $0 == open }).count { value.removeLast(); continue }
            break
        }
        return value
    }
    /// End of the word containing a link, so live styling waits for a boundary.
    static func tokenEnd(_ link: Link, in text: String) -> Int {
        let source = text as NSString
        var end = NSMaxRange(link.range)
        while end < source.length, let scalar = Unicode.Scalar(source.character(at: end)), !CharacterSet.whitespacesAndNewlines.contains(scalar) { end += 1 }
        return end
    }
    /// Read-only display: Markdown links show only their label. File links are
    /// dropped when they would refer to another device's disk.
    static func attributed(_ text: String, files: Bool) -> AttributedString {
        let source = text as NSString
        var result = AttributedString()
        var cursor = 0
        for link in find(in: text) where files || !link.isFile {
            result += AttributedString(source.substring(with: NSRange(location: cursor, length: link.range.location - cursor)))
            var label = AttributedString(source.substring(with: link.label))
            label.link = link.url
            result += label
            cursor = NSMaxRange(link.range)
        }
        result += AttributedString(source.substring(from: cursor))
        return result
    }
}

func lotLinkSelfTests(_ check: (Bool, String) -> Void) {
    func urls(_ text: String) -> [String] { LotLinks.find(in: text).map(\.url.absoluteString) }
    check(urls("See https://github.com/x/y today") == ["https://github.com/x/y"], "Lot links: bare https URL")
    check(urls("Read https://x.com/a.") == ["https://x.com/a"] && urls("(https://x.com/a)") == ["https://x.com/a"] && urls("https://x.com/a, then") == ["https://x.com/a"], "Lot links: trailing punctuation and wrapping parentheses are not part of the URL")
    check(urls("https://en.wikipedia.org/wiki/Foo_(bar)") == ["https://en.wikipedia.org/wiki/Foo_(bar)"], "Lot links: balanced parentheses stay inside the URL")
    let markdown = "Open [the repo](https://github.com/x/y) now"
    let link = LotLinks.find(in: markdown)
    check(link.count == 1 && (markdown as NSString).substring(with: link[0].label) == "the repo" && (markdown as NSString).substring(with: link[0].range) == "[the repo](https://github.com/x/y)" && link[0].isMarkdown, "Lot links: Markdown link label and source span")
    check(String(LotLinks.attributed(markdown, files: true).characters) == "Open the repo now", "Lot links: read-only display shows only the Markdown label")
    check(urls("a https://a.com b [B](http://b.com) c mailto:me@x.com") == ["https://a.com", "http://b.com", "mailto:me@x.com"], "Lot links: multiple links in order")
    check(urls("file:///Users/me/a%20b.txt") == ["file:///Users/me/a%20b.txt"] && LotLinks.find(in: "file:///Users/me/a%20b.txt")[0].url.path == "/Users/me/a b.txt", "Lot links: file URL with an escaped space")
    let path = LotLinks.find(in: "Log is at /Users/me/Library/x.log.")
    check(path.count == 1 && path[0].isFile && path[0].url.path == "/Users/me/Library/x.log", "Lot links: absolute path ends before trailing punctuation")
    let home = LotLinks.find(in: "~/Desktop/notes.md")
    check(home.count == 1 && home[0].isFile && home[0].url.path == NSString(string: "~/Desktop/notes.md").expandingTildeInPath, "Lot links: tilde path expands to the home folder")
    let fileMarkdown = LotLinks.find(in: "[Spec](file:///Users/me/My%20Spec.pdf)")
    check(fileMarkdown.count == 1 && fileMarkdown[0].isFile && fileMarkdown[0].url.path == "/Users/me/My Spec.pdf", "Lot links: Markdown file link")
    check(urls("javascript:alert(1) [x](javascript:alert(1)) [y](converse-help://a) myapp://open ftp://x.com") == [] && String(LotLinks.attributed("[x](javascript:alert(1))", files: true).characters) == "[x](javascript:alert(1))", "Lot links: disallowed schemes stay plain text")
    check(urls("and/or A /B test, 3/4 http:// nothing") == [] && String(LotLinks.attributed("Plain text — no links.", files: true).characters) == "Plain text — no links.", "Lot links: text without links is unchanged")
    check(LotLinks.attributed("[Spec](file:///Users/me/a.pdf) and /Users/me/b", files: false).runs.allSatisfy { $0.link == nil }, "Lot links: remote viewers render file links as plain text")
    let typing = "go https://x.com"
    check(LotLinks.tokenEnd(LotLinks.find(in: typing)[0], in: typing) == (typing as NSString).length && LotLinks.tokenEnd(LotLinks.find(in: "https://x.com/a. more")[0], in: "https://x.com/a. more") == 16, "Lot links: live styling waits for the word boundary")
}
