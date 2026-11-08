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
    /// A dropped file as a Markdown link: the filename is shown and the path is
    /// percent-encoded, so spaces and parentheses stay inside one link.
    static func markdown(file url: URL) -> String {
        let label = url.lastPathComponent.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{2028}", with: " ")
        let target = URL(fileURLWithPath: url.path).absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "[" + label + "](" + target + ")"
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

// Standard Markdown emphasis in plain row text: **bold**, *italic*, ***both***.
// Found at display time like links; delimiters may never split a link or code span.
enum LotInline {
    struct Span: Equatable {
        var range: NSRange    // whole source span, delimiters included
        var content: NSRange  // the part shown
        var bold: Bool
        var italic: Bool
        var marker: Int { content.location - range.location }
    }
    private static let pattern = try! NSRegularExpression(pattern: #"(?<![\\*\w])(\*{1,3})(?=[^\s*])(.+?)(?<=[^\s*])\1(?![*\w])"#)
    private static let code = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    static func spans(in text: String) -> [Span] {
        guard text.contains("*") else { return [] }
        let all = NSRange(location: 0, length: (text as NSString).length)
        let blocked = LotLinks.find(in: text).map(\.range) + code.matches(in: text, range: all).map(\.range)
        return pattern.matches(in: text, range: all).compactMap { match in
            let marker = match.range(at: 1).length
            let open = NSRange(location: match.range.location, length: marker)
            let close = NSRange(location: NSMaxRange(match.range) - marker, length: marker)
            guard !blocked.contains(where: { NSIntersectionRange($0, open).length > 0 || NSIntersectionRange($0, close).length > 0 }) else { return nil }
            return Span(range: match.range, content: match.range(at: 2), bold: marker >= 2, italic: marker != 2)
        }
    }
    /// The delimiters themselves, in source offsets.
    static func delimiters(in text: String) -> [NSRange] {
        spans(in: text).flatMap { span -> [NSRange] in
            [NSRange(location: span.range.location, length: span.marker), NSRange(location: NSMaxRange(span.content), length: span.marker)]
        }
    }
    /// End of the word containing a span, so conversion waits for a boundary.
    static func tokenEnd(_ span: Span, in text: String) -> Int {
        let source = text as NSString
        var end = NSMaxRange(span.range)
        while end < source.length, let scalar = Unicode.Scalar(source.character(at: end)), !CharacterSet.whitespacesAndNewlines.contains(scalar) { end += 1 }
        return end
    }
    /// True when a space typed at `offset` finishes a span.
    static func completes(in text: String, at offset: Int) -> Bool {
        spans(in: text).contains { NSMaxRange($0.range) == offset }
    }
    enum Style { case bold, italic; var stars: Int { self == .bold ? 2 : 1 } }
    private static func starsOutside(_ selection: NSRange, in source: NSString) -> Int {
        var before = 0, after = 0
        while before < 3, selection.location - before - 1 >= 0, source.character(at: selection.location - before - 1) == 42 { before += 1 }
        while after < 3, NSMaxRange(selection) + after < source.length, source.character(at: NSMaxRange(selection) + after) == 42 { after += 1 }
        return min(before, after)
    }
    private static func has(_ style: Style, _ stars: Int) -> Bool { style == .bold ? stars >= 2 : stars == 1 || stars == 3 }
    /// The word, span content or trimmed selection this command applies to.
    private static func target(in text: String, selection: NSRange) -> NSRange {
        let source = text as NSString
        if selection.length > 0 {
            var start = selection.location, end = NSMaxRange(selection)
            while start < end, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(source.character(at: start)) ?? " ") { start += 1 }
            while end > start, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(source.character(at: end - 1)) ?? " ") { end -= 1 }
            return NSRange(location: start, length: end - start)
        }
        if let span = spans(in: text).first(where: { selection.location >= $0.content.location && selection.location <= NSMaxRange($0.content) }) { return span.content }
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-'’_"))
        var start = selection.location, end = selection.location
        while start > 0, let scalar = UnicodeScalar(source.character(at: start - 1)), word.contains(scalar) { start -= 1 }
        while end < source.length, let scalar = UnicodeScalar(source.character(at: end)), word.contains(scalar) { end += 1 }
        return NSRange(location: start, length: end - start)
    }
    static func isActive(_ style: Style, in text: String, selection: NSRange) -> Bool {
        has(style, starsOutside(target(in: text, selection: selection), in: text as NSString))
    }
    /// The new text and selection after toggling `style`. Stars already around
    /// the target are counted, so bold and italic combine and come apart cleanly.
    static func toggling(_ style: Style, in text: String, selection: NSRange, on: Bool? = nil) -> (text: String, selection: NSRange) {
        let source = text as NSString
        let target = target(in: text, selection: selection)
        let stars = starsOutside(target, in: source)
        let active = has(style, stars)
        let wanted = on ?? !active
        let count = wanted == active ? stars : stars + (active ? -style.stars : style.stars)
        let content = source.substring(with: target)
        let replacement = String(repeating: "*", count: count) + content + String(repeating: "*", count: count)
        let whole = NSRange(location: target.location - stars, length: target.length + 2 * stars)
        let result = source.replacingCharacters(in: whole, with: replacement)
        let delta = count - stars
        let next = selection.length > 0 ? NSRange(location: whole.location + count, length: target.length)
            : NSRange(location: selection.location + delta + (target.length == 0 ? count - delta : 0), length: 0)
        return (result, NSRange(location: min(max(0, next.location), (result as NSString).length), length: next.length))
    }
}

func lotInlineSelfTests(_ check: (Bool, String) -> Void) {
    func shown(_ text: String) -> [String] { LotInline.spans(in: text).map { (text as NSString).substring(with: $0.content) } }
    check(shown("say **bold** and *italic* and ***both***") == ["bold", "italic", "both"] && LotInline.spans(in: "***x***")[0].bold && LotInline.spans(in: "***x***")[0].italic, "Markdown emphasis finds bold, italic and both")
    check(shown("2 * 3 * 4") == [] && shown("a*b*c") == [] && shown("** spaced **") == [] && shown("\\*not*") == [] && shown("`*code*`") == [], "Emphasis ignores arithmetic, intraword stars, spaced markers, escapes and code")
    check(shown("see [a*b](https://x.com/*y*) and https://x.com/*z*") == [] && shown("**[the repo](https://x.com)**") == ["[the repo](https://x.com)"], "Emphasis never splits a link, but can wrap one")
    check(shown("**across\nlines**") == [], "Emphasis stays on one line")
    func toggle(_ style: LotInline.Style, _ text: String, _ location: Int, _ length: Int = 0) -> String { LotInline.toggling(style, in: text, selection: NSRange(location: location, length: length)).text }
    check(toggle(.bold, "say hello now", 4, 5) == "say **hello** now" && toggle(.italic, "say hello now", 4, 5) == "say *hello* now", "Toggling wraps the selection")
    check(toggle(.bold, "say **hello** now", 6, 5) == "say hello now" && toggle(.italic, "say *hello* now", 5, 5) == "say hello now", "Toggling a selection that is already styled removes it")
    check(toggle(.bold, "say hello now", 6) == "say **hello** now" && LotInline.toggling(.bold, in: "say hello now", selection: NSRange(location: 6, length: 0)).selection == NSRange(location: 8, length: 0), "Toggling at a caret applies to the word and keeps the caret in it")
    check(toggle(.bold, "say **hello** now", 8) == "say hello now", "Toggling inside a styled word removes the style")
    check(toggle(.italic, "say **hello** now", 6, 5) == "say ***hello*** now" && toggle(.italic, "say ***hello*** now", 7, 5) == "say **hello** now" && toggle(.bold, "say ***hello*** now", 7, 5) == "say *hello* now", "Bold and italic combine and come apart")
    check(toggle(.bold, " x ", 1, 2) == " **x** ", "Selected spaces stay outside the markers")
    let empty = LotInline.toggling(.bold, in: "a  b", selection: NSRange(location: 2, length: 0))
    check(empty.text == "a **** b" && empty.selection == NSRange(location: 4, length: 0), "With no word to act on, the markers go in and the caret goes between them")
    check(LotInline.completes(in: "go **bold**", at: 11) && !LotInline.completes(in: "go **bold", at: 9), "A space after finished markup is recognized")
    let unicode = LotInline.toggling(.bold, in: "🦊 word", selection: NSRange(location: 3, length: 0))
    check(unicode.text == "🦊 **word**", "Toggling uses UTF-16 offsets")
}

func lotLinkSelfTests(_ check: (Bool, String) -> Void) {
    lotInlineSelfTests(check)
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
    for path in ["/Users/me/Downloads/KAOS Labs Logo.png", "/Users/me/Desktop/Shot (1) [v2] 10.15\u{202F}AM.png", "/tmp/x"] {
        let source = LotLinks.markdown(file: URL(fileURLWithPath: path))
        let found = LotLinks.find(in: "See " + source + " now")
        check(found.count == 1 && found[0].isMarkdown && found[0].url.path == path && NSMaxRange(found[0].range) == 4 + (source as NSString).length, "Lot links: a dropped file's Markdown link keeps the whole path: " + path)
    }
    check(LotLinks.markdown(file: URL(fileURLWithPath: "/Users/me/a b.txt")) == "[a b.txt](file:///Users/me/a%20b.txt)", "Lot links: dropped file links show the filename")
    check(LotLinks.tokenEnd(LotLinks.find(in: typing)[0], in: typing) == (typing as NSString).length && LotLinks.tokenEnd(LotLinks.find(in: "https://x.com/a. more")[0], in: "https://x.com/a. more") == 16, "Lot links: live styling waits for the word boundary")
}
