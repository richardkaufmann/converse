import Foundation

/// Best-effort removal of secrets and personal details from exported text.
/// Pure and deterministic: one scrubber is used for a whole export, so the same
/// address or device gets the same numbered placeholder everywhere in the file.
struct ExportScrubber {
    struct Device: Equatable { var id: String; var names: [String] }
    struct Context: Equatable {
        var homePath = ""
        var fullName = ""
        var accountName = ""
        var devices: [Device] = []
        static var current: Context {
            Context(homePath: NSHomeDirectory(), fullName: NSFullUserName(), accountName: NSUserName(), devices: DeviceSyncService.shared.scrubDevices)
        }
    }
    static let categories = ["secret", "email", "phone", "ip", "path", "name", "device", "host", "discord"]
    let context: Context
    private(set) var counts: [String: Int] = [:]
    private var numbers: [String: [String: Int]] = [:]
    init(context: Context) { self.context = context }

    var total: Int { counts.values.reduce(0, +) }
    static func describe(_ counts: [String: Int]) -> String {
        let nouns = ["secret": ("secret", "secrets"), "email": ("email address", "email addresses"), "phone": ("phone number", "phone numbers"),
                     "ip": ("IP address", "IP addresses"), "path": ("home folder path", "home folder paths"), "name": ("name", "names"),
                     "device": ("device name or ID", "device names or IDs"), "host": ("local host name", "local host names"), "discord": ("Discord ID", "Discord IDs")]
        let parts = categories.compactMap { key -> String? in
            guard let count = counts[key], count > 0, let noun = nouns[key] else { return nil }
            return "\(count) " + (count == 1 ? noun.0 : noun.1)
        }
        return parts.isEmpty ? "Nothing was found to remove." : "Removed " + parts.joined(separator: ", ") + "."
    }

    private enum Action {
        case keep
        case fixed(String, String)                       // replacement, category
        case numbered(prefix: String, category: String, label: String, key: String)
    }
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    private mutating func number(_ category: String, _ key: String) -> Int {
        if let existing = numbers[category]?[key] { return existing }
        let next = (numbers[category]?.count ?? 0) + 1
        numbers[category, default: [:]][key] = next
        return next
    }
    private mutating func apply(_ expression: NSRegularExpression, to text: String, _ decide: (NSTextCheckingResult, NSString) -> Action) -> String {
        let source = text as NSString
        var output = "", last = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let replacement: String
            switch decide(match, source) {
            case .keep: continue
            case let .fixed(value, category):
                counts[category, default: 0] += 1; replacement = value
            case let .numbered(prefix, category, label, key):
                counts[category, default: 0] += 1
                replacement = prefix + "[\(label) \(number(category, key))]"
            }
            output += source.substring(with: NSRange(location: last, length: match.range.location - last)) + replacement
            last = NSMaxRange(match.range)
        }
        return last == 0 && output.isEmpty ? text : output + source.substring(from: last)
    }
    private static func group(_ match: NSTextCheckingResult, _ index: Int, _ source: NSString) -> String {
        let range = match.range(at: index)
        return range.location == NSNotFound ? "" : source.substring(with: range)
    }

    // Secrets. Typed vendor keys first, then generic assignments, then entropy.
    private static let pem = regex(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#)
    private static let vendorKeys = regex(#"(?<![A-Za-z0-9_-])(?:sk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}|(?:ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|xox[abposr]-[A-Za-z0-9-]{10,}|(?:AKIA|ASIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35})(?![A-Za-z0-9_-])"#)
    private static let jwt = regex(#"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#)
    private static let bearer = regex(#"\b(Bearer\s+)([A-Za-z0-9._~+/=-]{16,})"#, [.caseInsensitive])
    private static let webhook = regex(#"(https?://(?:[\w-]+\.)?discord(?:app)?\.com/api/webhooks/\d{17,20}/)[A-Za-z0-9_-]{30,}"#, [.caseInsensitive])
    private static let discordToken = regex(#"(?<![A-Za-z0-9_.-])[MNO][A-Za-z0-9_-]{23,27}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,40}(?![A-Za-z0-9_.-])"#)
    private static let assignment = regex(#"\b([A-Za-z0-9_.-]*(?:password|passwd|secret|token|api[_-]?key)[A-Za-z0-9_.-]*["']?\s*[:=]\s*)("[^"\n]{4,}"|'[^'\n]{4,}'|[^\s"',;\[\]{}()]{5,}[^\s"',;\[\]{}().:!?])"#, [.caseInsensitive])
    private static let entropyCandidate = regex(#"(?<![A-Za-z0-9+_=/.-])[A-Za-z0-9+_=-]{32,}(?![A-Za-z0-9+_=/-])(?!\.[A-Za-z0-9])"#)
    private static let uuid = regex(#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#)
    // Personal details.
    private static let email = regex(#"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(?![A-Za-z0-9-])"#)
    private static let discordURL = regex(#"https?://(?:[\w-]+\.)?discord(?:app)?\.com/[^\s)>\]"'<]*"#, [.caseInsensitive])
    private static let snowflake = regex(#"(?<!\d)\d{17,20}(?!\d)"#)
    private static let localHost = regex(#"(?<![A-Za-z0-9.-])[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9-]+)*\.local(?![A-Za-z0-9-])(?!\.[A-Za-z0-9])"#, [.caseInsensitive])
    private static let ipv4 = regex(#"(?<![\w.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![\w]|\.\d)"#)
    private static let ipv6 = regex(#"(?<![\w:.])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])"#)
    // International (+country) first, then North American 3-3-4, in one pass so numbering follows the text.
    private static let phone = regex(#"(?<![\w+])\+\d{1,3}(?:[ .-]?\(?\d{1,4}\)?){2,5}(?![\w])|(?<![\w.+/-])(?:\(\d{3}\)\s?|\d{3}[ .-])\d{3}[ .-]\d{4}(?![\w.-])"#)

    static func entropy(_ text: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let length = Double(text.count)
        return counts.values.reduce(0) { sum, count in let p = Double(count) / length; return sum - p * log2(p) }
    }
    /// Conservative: mixed case plus several digits and high entropy. Hex digests
    /// (git SHAs, SHA-256), UUIDs and ordinary identifiers do not qualify.
    static func looksRandom(_ token: String) -> Bool {
        guard token.count >= 32, token.count <= 512,
              token.contains(where: \.isUppercase), token.contains(where: \.isLowercase),
              token.filter(\.isNumber).count >= 2,
              uuid.firstMatch(in: token, range: NSRange(location: 0, length: (token as NSString).length)) == nil else { return false }
        if token.allSatisfy(\.isHexDigit) { return false }
        return entropy(token) >= 4.2
    }
    private static func escapedWords(_ value: String) -> NSRegularExpression? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: trimmed) + #"(?![\p{L}\p{N}_])"#, options: [.caseInsensitive])
    }
    private static let commonAccounts: Set<String> = ["admin", "user", "users", "test", "root", "guest", "home", "shared", "mac", "dev", "demo"]
    private static let assignmentValues: Set<String> = ["true", "false", "null", "none", "nil", "undefined", "required", "optional", "missing", "redacted", "[secret]"]

    mutating func scrub(_ input: String) -> String {
        var text = input
        guard !text.isEmpty else { return text }
        text = apply(Self.pem, to: text) { _, _ in .fixed("[secret]", "secret") }
        text = apply(Self.vendorKeys, to: text) { _, _ in .fixed("[secret]", "secret") }
        text = apply(Self.jwt, to: text) { _, _ in .fixed("[secret]", "secret") }
        text = apply(Self.webhook, to: text) { match, source in .fixed(Self.group(match, 1, source) + "[secret]", "secret") }
        text = apply(Self.discordToken, to: text) { _, _ in .fixed("[secret]", "secret") }
        text = apply(Self.bearer, to: text) { match, source in .fixed(Self.group(match, 1, source) + "[secret]", "secret") }
        text = apply(Self.assignment, to: text) { match, source in
            let value = Self.group(match, 2, source)
            let bare = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if bare.hasPrefix("$") || bare.hasPrefix("<") || bare.hasPrefix("[") || bare.hasPrefix("%") || bare.hasPrefix("{")
                || bare.allSatisfy(\.isNumber) || Self.assignmentValues.contains(bare.lowercased()) || bare.contains(" ") && !value.hasPrefix("\"") && !value.hasPrefix("'") { return .keep }
            return .fixed(Self.group(match, 1, source) + "[secret]", "secret")
        }
        text = apply(Self.email, to: text) { match, source in
            let value = source.substring(with: match.range)
            if value.lowercased().hasPrefix("git@") { return .keep }
            return .numbered(prefix: "", category: "email", label: "email", key: value.lowercased())
        }
        for (index, device) in context.devices.enumerated() {
            let id = device.id.trimmingCharacters(in: .whitespacesAndNewlines)
            var spellings = device.names.filter { $0.trimmingCharacters(in: .whitespaces).count >= 3 }
            if id.count >= 16 { spellings.append(id) }
            if id.count >= 32 { spellings.append(String(id.prefix(16)).uppercased()) }
            for spelling in spellings.sorted(by: { $0.count > $1.count }) {
                guard let expression = Self.escapedWords(spelling) else { continue }
                text = apply(expression, to: text) { _, _ in .numbered(prefix: "", category: "device", label: "device", key: "#\(index)") }
            }
        }
        let home = context.homePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if home.count > 1, home != "/" {
            let expression = Self.regex(NSRegularExpression.escapedPattern(for: home) + #"(?![A-Za-z0-9._-])"#)
            text = apply(expression, to: text) { _, _ in .fixed("~", "path") }
        }
        if context.fullName.trimmingCharacters(in: .whitespaces).count >= 3, let expression = Self.escapedWords(context.fullName) {
            text = apply(expression, to: text) { _, _ in .fixed("[name]", "name") }
        }
        let account = context.accountName.trimmingCharacters(in: .whitespaces)
        if account.count >= 4, !Self.commonAccounts.contains(account.lowercased()), let expression = Self.escapedWords(account) {
            text = apply(expression, to: text) { _, _ in .fixed("[user]", "name") }
        }
        // Discord channel, guild, message and webhook IDs inside Discord links.
        let urls = Self.discordURL.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        if !urls.isEmpty {
            let source = text as NSString
            var output = "", last = 0
            for url in urls {
                output += source.substring(with: NSRange(location: last, length: url.range.location - last))
                output += apply(Self.snowflake, to: source.substring(with: url.range)) { match, part in
                    let value = part.substring(with: match.range)
                    return .numbered(prefix: "", category: "discord", label: "discord", key: value)
                }
                last = NSMaxRange(url.range)
            }
            text = output + source.substring(from: last)
        }
        text = apply(Self.localHost, to: text) { match, source in
            .numbered(prefix: "", category: "host", label: "host", key: source.substring(with: match.range).lowercased())
        }
        text = apply(Self.ipv4, to: text) { match, source in
            let value = source.substring(with: match.range)
            if value.hasPrefix("127.") || value == "0.0.0.0" { return .keep }
            return .numbered(prefix: "", category: "ip", label: "ip", key: value)
        }
        text = apply(Self.ipv6, to: text) { match, source in
            let value = source.substring(with: match.range)
            let colons = value.filter { $0 == ":" }.count
            guard value != "::1", value != "::", value.contains(where: \.isHexDigit), value.contains("::") || colons == 7 else { return .keep }
            var address = in6_addr()
            guard inet_pton(AF_INET6, value, &address) == 1 else { return .keep }
            return .numbered(prefix: "", category: "ip", label: "ip", key: value.lowercased())
        }
        text = apply(Self.phone, to: text) { match, source in
            let digits = source.substring(with: match.range).filter(\.isNumber)
            guard (10...15).contains(digits.count) else { return .keep }
            return .numbered(prefix: "", category: "phone", label: "phone", key: String(digits.suffix(10)))
        }
        text = apply(Self.entropyCandidate, to: text) { match, source in
            Self.looksRandom(source.substring(with: match.range)) ? .fixed("[secret]", "secret") : .keep
        }
        return text
    }
}

extension DeviceSyncService {
    /// This Group's device names and IDs, as the scrubber sees them.
    var scrubDevices: [ExportScrubber.Device] {
        var result: [String: Set<String>] = [:]
        if let identity { result[identity.deviceID, default: []].formUnion([identity.deviceName, displayName(for: identity.deviceID)]) }
        for device in trustedDevicesForScrubbing { result[device.deviceID, default: []].formUnion([device.name] + (device.displayName.map { [$0] } ?? [])) }
        for (id, home) in homes { result[id, default: []].insert(home.deviceName) }
        return result.keys.sorted().map { ExportScrubber.Device(id: $0, names: Array(result[$0] ?? []).sorted()) }
    }
}
