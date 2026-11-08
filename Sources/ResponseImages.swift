import AppKit
import CryptoKit
import ImageIO

// Explicit image references become managed attachments. File imports stay
// inside permitted roots; HTTPS downloads use a bounded, credential-free client.
enum ResponseImages {
    /// Keep recurring prompt overhead small; the complete explanation lives in Teach.
    static func deliveryReminder(output: URL) -> String {
        "[Converse image output: save images in \(output.path); embed each as ![caption](\(output.appendingPathComponent("name.png").absoluteString)) using its real filename, on its own line in the SAME final reply, outside code and before any converse fence. Saving alone does not display it. Do not open a desktop viewer.]"
    }
    // Local screenshots may be much larger than the attachment sent to peers.
    // Keep network downloads and normalized output at their existing 8 MB limit.
    static let localInputLimit = 32_000_000
    struct Captured { var range: NSRange; var caption: String; var file: URL }
    static func capture(_ text: String, roots: [URL], destination: URL) -> [Captured] {
        let allowed = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
        var captured: [Captured] = []
        for reference in TranscriptStyle.localImageReferences(text) {
            guard captured.count < 8 else { break }
            let file = reference.url.resolvingSymlinksInPath().standardizedFileURL
            guard allowed.contains(where: { file.path.hasPrefix($0) }),
                  let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), properties.isRegularFile == true,
                  let size = properties.fileSize, size <= localInputLimit,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let bytes = try? handle.read(upToCount: localInputLimit + 1); try? handle.close()
            guard let bytes, bytes.count <= localInputLimit, let png = normalizedPNG(bytes) else { continue }
            let hash = DeviceBlob.sha256Hex(png)
            let output = destination.appendingPathComponent("Response-" + hash + ".png")
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try png.write(to: output, options: .atomic)
                captured.append(Captured(range: reference.range, caption: reference.caption, file: output))
            } catch { continue }
        }
        return captured
    }
    // The host leads the failure notice so a prompt-injected link is
    // identifiable before its full attacker-chosen text.
    static func unreachableNotice(url: URL) -> String {
        "Image could not be loaded from " + (url.host ?? "an unknown host") + ": " + url.absoluteString + "\nOpen the image link to view it in a browser."
    }
    static func normalizedPNG(_ bytes: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 131072, height <= 131072, width <= 64_000_000 / height else { return nil }
        // Preserve readable detail in stitched pages and panoramas. The result
        // still fits the existing peer dimension and byte limits.
        let longImage = max(width, height) / min(width, height) >= 4
        var dimension = min(longImage ? 16384 : 2048, max(width, height))
        while dimension >= 128 || dimension == max(width, height) {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: dimension, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
            if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), png.count <= 8_000_000 { return png }
            if dimension <= 128 { return nil }; dimension = max(128, dimension * 7 / 10)
        }
        return nil
    }
}

/// Explicit navigation for a local image that could not be imported. Never
/// widen capture roots or open the referenced file as an executable/document.
enum LocalImageFallback {
    static let attribute = NSAttributedString.Key("Converse.localImageFallback")
    static func follow(_ url: URL, onHome: Bool,
                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                       reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) -> String? {
        guard onHome else { return "This image is a local file on the session's home device. Open this conversation on its home Mac to reveal it, or ask the assistant to send it as a Converse attachment." }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return "This is not a local image path on this Mac." }
        guard exists(url.path) else { return "The image file is no longer available at " + url.path + ". Ask the assistant to recreate it or send it as a Converse attachment." }
        reveal(url); return nil
    }
    private static func isFileLink(_ value: Any?) -> Bool { ((value as? URL) ?? (value as? String).flatMap(URL.init(string:)))?.isFileURL == true }
    static func hasFileLink(_ text: NSAttributedString, in ranges: [NSRange]) -> Bool {
        var found = false
        for range in ranges where range.length > 0 && NSMaxRange(range) <= text.length {
            text.enumerateAttribute(.link, in: range) { value, _, stop in if isFileLink(value) { found = true; stop.pointee = true } }
        }
        return found
    }
    // Formatted clipboard data keeps the visible text but no link into this
    // Mac's files. The transcript itself keeps its in-app reveal.
    static func withoutFileLinks(_ text: NSAttributedString) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard isFileLink(value) else { return }
            for key in [NSAttributedString.Key.link, .toolTip, attribute] { result.removeAttribute(key, range: range) }
        }
        return result
    }
    // A selection holding a file link writes rich text without it and none of
    // AppKit's URL types. Nil leaves plain text to AppKit.
    static func writeSelection(_ selection: NSAttributedString, to board: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool? {
        let documentType: NSAttributedString.DocumentType
        switch type.rawValue {
        case NSPasteboard.PasteboardType.string.rawValue, "NSStringPboardType": return nil
        case NSPasteboard.PasteboardType.rtf.rawValue, "NeXT Rich Text Format v1.0 pasteboard type": documentType = .rtf
        case NSPasteboard.PasteboardType.rtfd.rawValue, "com.apple.flat-rtfd", "NeXT RTFD pasteboard type": documentType = .rtfd
        default: return false
        }
        let clean = withoutFileLinks(selection)
        guard let data = try? clean.data(from: NSRange(location: 0, length: clean.length), documentAttributes: [.documentType: documentType]) else { return false }
        return board.setData(data, forType: type)
    }
}

extension Store {
    func responseImageFolder(_ session: Session) -> URL { folder.appendingPathComponent("Attachments").appendingPathComponent(session.id.uuidString).appendingPathComponent("Outputs") }
    func responseImageTeaching(_ session: Session) -> String {
        let output = responseImageFolder(session)
        let example = output.appendingPathComponent("example.png").absoluteString
        return """
        [Converse inline images]
        To SHOW an image in the conversation, do BOTH steps in the same turn:
        1. Save the image you create or download as a PNG in this session's Outputs folder: \(output.path)
        2. Include a Markdown IMAGE in your final reply, using the actual saved file's absolute file URL. Example (replace example.png with your real filename):
        ![A short description](\(example))
        The leading ! is required. Put the image Markdown on its own line, outside code fences, inline code and blockquotes. Encode spaces in file URLs as %20. Saving a file alone, mentioning its path, or writing an ordinary [link](file:///...) does NOT display it inline. Do not claim an image is displayed without including its image Markdown in that same reply.
        Converse imports the referenced image and displays it in the conversation, including on remote devices. Do not open Preview, a browser or another desktop viewer to show it. If the reply also sends a switchboard command, put the image Markdown BEFORE the final converse command fence; that command fence must still be last.
        """
    }
    // Local captures only. Web images wait for the reader's click
    // (loadResponseImage): fetching one unasked would let a prompt-injected
    // link leak conversation details through its hostname or path.
    @discardableResult func importResponseImages(_ session: Session) -> Bool {
        let output = responseImageFolder(session)
        let attachmentRoot = folder.appendingPathComponent("Attachments").resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard output.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(attachmentRoot) else { return false }
        var roots = [output, URL(fileURLWithPath: "/tmp"), FileManager.default.temporaryDirectory]
        let working = URL(fileURLWithPath: NSString(string: session.entry.directory).expandingTildeInPath).standardizedFileURL
        if working.path != "/" && working.path != NSHomeDirectory() { roots.append(working) }
        var changed = false
        for index in session.messages.indices where session.messages[index].role == "assistant" && session.messages[index].imported != true && session.messages[index].text.contains("![") {
            let items = ResponseImages.capture(session.messages[index].text, roots: roots, destination: output)
            guard !items.isEmpty else { continue }
            session.messages[index].text = TranscriptStyle.splice(session.messages[index].text, items.map { ($0.range, $0.caption) })
            for item in items where !session.messages[index].images.contains(item.file.path) { session.messages[index].images.append(item.file.path) }
            changed = true
        }
        return changed
    }
    // The reader clicked Load image under one web image link. Fetches that
    // image once through the bounded client and keeps it as a transcript
    // attachment, so it survives relaunch and reaches viewers as a blob.
    func loadResponseImage(_ session: Session, messageID: UUID, url: URL) {
        let output = responseImageFolder(session)
        let attachmentRoot = folder.appendingPathComponent("Attachments").resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard sessions.contains(where: { $0 === session }), output.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(attachmentRoot),
              let message = session.messages.first(where: { $0.id == messageID }), message.role == "assistant", message.images.count < 8,
              TranscriptStyle.imageReferences(message.text).contains(where: { $0.url == url }) else { return }
        let key = session.id.uuidString + "/" + messageID.uuidString + "/" + url.absoluteString
        responseImageLoader.enqueue(key: key, url: url) { [weak self, weak session] result in
            guard let self, let session, self.sessions.contains(where: { $0 === session }),
                  let index = session.messages.firstIndex(where: { $0.id == messageID }) else { return }
            let refs = TranscriptStyle.imageReferences(session.messages[index].text).filter { $0.url == url }
            guard !refs.isEmpty else { return }
            switch result {
            case .success(let png):
                guard session.messages[index].images.count < 8, output.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(attachmentRoot) else { return }
                let file = output.appendingPathComponent("Response-" + DeviceBlob.sha256Hex(png) + ".png")
                do {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try png.write(to: file, options: .atomic)
                    session.messages[index].text = TranscriptStyle.splice(session.messages[index].text, refs.map { ($0.range, $0.caption) })
                    if !session.messages[index].images.contains(file.path) { session.messages[index].images.append(file.path) }
                } catch { session.messages.append(Message(role: "notice", text: "Image could not be saved. Its link remains available.")) }
            case .failure:
                session.messages.append(Message(role: "notice", text: ResponseImages.unreachableNotice(url: url)))
            }
            self.saveSoon()
        }
    }
}

// Pure and offline (no DNS): reasons a reply's image link deserves a
// second look before the reader loads it. Injected links exfiltrate
// through hostnames and paths, so random-looking tokens weigh most.
enum ImageLinkSuspicion {
    static func reasons(_ url: URL, caption: String = "") -> [String] {
        var found: [String] = []
        func flag(_ reason: String) { if !found.contains(reason) { found.append(reason) } }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme != "https" { flag("not HTTPS") }
        if url.user != nil || url.password != nil { flag("user name in link") }
        if let port = url.port, port != (scheme == "http" ? 80 : 443) { flag("unusual port " + String(port)) }
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard !host.isEmpty else { flag("no hostname"); return found }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var v4 = in_addr(), v6 = in6_addr()
        let privateSuffixes: Set<String> = ["localhost", "local", "lan", "internal", "intranet", "home", "corp", "localdomain", "arpa"]
        if inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 || host.allSatisfy({ $0.isNumber || $0 == "." }) { flag("IP address instead of a name") }
        else if labels.count < 2 || privateSuffixes.contains(labels.last ?? "") { flag("private network name") }
        if host.contains("xn--") { flag("punycode (lookalike) hostname") }
        if labels.count > 4 { flag("many subdomains") }
        if labels.contains(where: { $0.count > 24 }) { flag("long hostname label") }
        if labels.contains(where: randomLooking) { flag("long random-looking hostname") }
        if url.pathComponents.contains(where: { randomLooking($0.removingPercentEncoding ?? $0) }) { flag("long random-looking path") }
        let named = caption.trimmingCharacters(in: .whitespaces).lowercased()
        var claimed: String?
        if let link = URL(string: named), link.scheme != nil, let linkHost = link.host { claimed = linkHost }
        else if let match = named.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(?=/|$)"#, options: .regularExpression),
                !["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "heic", "tif", "tiff"].contains(named[match].split(separator: ".").last.map(String.init) ?? "") { claimed = String(named[match]) }
        if let claimed {
            func bare(_ value: String) -> String { value.hasPrefix("www.") ? String(value.dropFirst(4)) : value }
            if bare(claimed) != bare(host) && !host.hasSuffix("." + bare(claimed)) { flag("link text names " + claimed) }
        }
        return found
    }
    // A 20+ character run of letters and digits that reads as a hash, a
    // number, base64 or consonant noise rather than words.
    static func randomLooking(_ part: String) -> Bool {
        part.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).contains { token in
            guard token.count >= 20 else { return false }
            let digits = token.filter(\.isNumber).count, letters = token.count - digits
            if digits > 0 && (letters == 0 || token.allSatisfy(\.isHexDigit) || digits >= 2) { return true }
            var changes = 0, previous: Bool?
            for character in token where character.isLetter { if let previous, previous != character.isUppercase { changes += 1 }; previous = character.isUppercase }
            if changes >= 6 { return true }
            let vowels = token.lowercased().filter { "aeiouy".contains($0) }.count
            return letters > 0 && Double(vowels) / Double(letters) < 0.2
        }
    }
    static func warning(_ reasons: [String]) -> String { reasons.isEmpty ? "" : "⚠︎ Looks suspicious: " + reasons.joined(separator: ", ") }
}

func responseImageSelfTests(_ check: (Bool, String) -> Void) {
    let reminderOutput = URL(fileURLWithPath: "/Users/example/Library/Application Support/Converse/Attachments/00000000-0000-0000-0000-000000000000/Outputs")
    let reminder = ResponseImages.deliveryReminder(output: reminderOutput)
    check(reminder.count < 650 && !reminder.contains("\n"), "Per-turn image reminder stays one line under 650 characters for a normal session path")
    check(TranscriptStyle.localImageReferences(reminder).first?.url == reminderOutput.appendingPathComponent("name.png"), "Compact image reminder example resolves through the real image parser, including spaces")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-response-images-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let allowed = root.appendingPathComponent("allowed"); let output = root.appendingPathComponent("outputs")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let input = allowed.appendingPathComponent("photo.jpg"); try bitmap.representation(using: .jpeg, properties: [:])!.write(to: input)
        let source = "Photo 😀\n![Grasshopper](" + input.absoluteString + ")"
        let images = ResponseImages.capture(source, roots: [allowed], destination: output)
        let bytes = try images.first.map { try Data(contentsOf: $0.file) }
        check(images.count == 1 && bytes?.prefix(8) == Data([137,80,78,71,13,10,26,10]), "Response image references become bounded managed PNG attachments")
        check(images.first.map { (source as NSString).substring(with: $0.range).hasPrefix("![Grasshopper]") } == true, "Response image ranges preserve Unicode transcript offsets")
        let outside = root.appendingPathComponent("outside.jpg"); try Data(contentsOf: input).write(to: outside)
        let fallbackSpaced = root.appendingPathComponent("image with spaces.png")
        try Data(contentsOf: input).write(to: fallbackSpaced)
        let fallbackSource = "![Local picture](" + fallbackSpaced.absoluteString + ")"
        check(ResponseImages.capture(fallbackSource, roots: [allowed], destination: output).isEmpty,
              "Clickable fallback does not broaden permitted attachment imports")
        let fallbackSession = Session(entry: Entry(name: "Fallback QA", command: "/usr/bin/false", directory: root.path, engine: "codex"))
        fallbackSession.messages = [Message(role: "assistant", text: fallbackSource)]
        let fallbackText = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        let fallbackCoordinator = ScrollingConversation.Coordinator(fallbackSession)
        fallbackCoordinator.render(fallbackText)
        var target: URL?, position = -1, revealed: [URL] = [], notices: [String] = []
        fallbackText.textStorage?.enumerateAttribute(LocalImageFallback.attribute, in: NSRange(location: 0, length: fallbackText.inputStart)) { value, range, _ in
            if let url = value as? URL { target = url; position = range.location }
        }
        check(target == fallbackSpaced && position >= 0 && fallbackText.textStorage?.attribute(.link, at: max(0, position), effectiveRange: nil) as? URL == fallbackSpaced,
              "Native local fallback retains a clickable file URL with spaces")
        fallbackCoordinator.localImageIsHome = { true }
        fallbackCoordinator.localImageReveal = { revealed.append($0) }
        fallbackCoordinator.localImageNotice = { message, _ in notices.append(message) }
        if let target, position >= 0 {
            _ = fallbackCoordinator.textView(fallbackText, clickedOnLink: target, at: position)
            check(revealed == [fallbackSpaced] && notices.isEmpty, "Native fallback click reveals the exact local file")
            fallbackCoordinator.localImageIsHome = { false }
            _ = fallbackCoordinator.textView(fallbackText, clickedOnLink: target, at: position)
            check(revealed.count == 1 && notices.last?.contains("home device") == true, "Remote fallback click explains the home path without opening a local file")
            fallbackCoordinator.localImageIsHome = { true }
            try FileManager.default.removeItem(at: fallbackSpaced)
            _ = fallbackCoordinator.textView(fallbackText, clickedOnLink: target, at: position)
            check(revealed.count == 1 && notices.last?.contains("no longer available") == true, "Missing local fallback reports the path without opening Finder")
        }
        func hasHyperlink(_ data: Data?) -> Bool { String(decoding: data ?? Data(), as: UTF8.self).contains("HYPERLINK") }
        let formattedBoard = NSPasteboard.withUniqueName()
        fallbackText.copyBlock(0, to: formattedBoard)
        let formattedRTF = formattedBoard.data(forType: .rtf), formattedHTML = String(decoding: formattedBoard.data(forType: .html) ?? Data(), as: UTF8.self)
        let decodedRTF = formattedRTF.flatMap { try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
        check(formattedRTF != nil && !hasHyperlink(formattedRTF) && decodedRTF?.string.contains("image%20with%20spaces.png") == true, "Copy Message RTF keeps the fallback text without its file link")
        check(!formattedHTML.isEmpty && !formattedHTML.contains("href=\"file:") && !formattedHTML.lowercased().contains("reveal image"), "Copy Message HTML carries no file link")
        check(formattedBoard.string(forType: .string) == fallbackSource, "Copy Message plain text stays the exact source")
        formattedBoard.releaseGlobally()
        if position >= 0 {
            let selectionBoard = NSPasteboard.withUniqueName()
            fallbackText.setSelectedRange(NSRange(location: position, length: 12))
            fallbackText.copySelection(to: selectionBoard)
            let selectionRTF = selectionBoard.data(forType: .rtf)
            check(selectionRTF != nil && !hasHyperlink(selectionRTF) && selectionBoard.data(forType: .URL) == nil && selectionBoard.string(forType: NSPasteboard.PasteboardType("public.url-name")) == nil,
                  "Selection copy writes rich text without a file link or URL types")
            check(selectionBoard.string(forType: .string)?.contains(fallbackSpaced.absoluteString) == true, "Selection copy plain text still names the file")
            selectionBoard.releaseGlobally()
            check(fallbackText.textStorage?.attribute(.link, at: position, effectiveRange: nil) as? URL == fallbackSpaced && fallbackText.textStorage?.attribute(LocalImageFallback.attribute, at: position, effectiveRange: nil) as? URL == fallbackSpaced,
                  "Copying leaves the in-app reveal link in place")
        }
        let mixedLinks = NSMutableAttributedString(string: "web file")
        mixedLinks.addAttribute(.link, value: URL(string: "https://example.com/a")!, range: NSRange(location: 0, length: 3))
        mixedLinks.addAttribute(.link, value: "file:///tmp/a.png", range: NSRange(location: 4, length: 4))
        let cleanedLinks = LocalImageFallback.withoutFileLinks(mixedLinks)
        check(cleanedLinks.attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "https://example.com/a") && cleanedLinks.attribute(.link, at: 4, effectiveRange: nil) == nil && cleanedLinks.string == "web file",
              "Formatted copy strips file links only, whether stored as URL or string")
        var probedRemoteDisk = false
        _ = LocalImageFallback.follow(fallbackSpaced, onHome: false, exists: { _ in probedRemoteDisk = true; return true }, reveal: { _ in check(false, "Remote path must never reveal") })
        check(!probedRemoteDisk, "Remote image fallback does not even probe the viewer's filesystem")
        let arbitrary = MarkdownText.inline("[Run](file:///tmp/example.command)")
        check(arbitrary.attribute(.link, at: 0, effectiveRange: nil) == nil,
              "Ordinary file links do not gain the image fallback navigation privilege")
        check(fallbackSession.messages.first?.text == fallbackSource && fallbackSession.messages.first?.images.isEmpty == true,
              "Fallback navigation leaves stored source and attachment ownership unchanged")

        let escape = allowed.appendingPathComponent("escape.jpg"); try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        check(ResponseImages.capture("![private](" + escape.absoluteString + ")", roots: [allowed], destination: output).isEmpty, "Response image imports reject symlink escapes")
        let quoted = "```md\n![Example](" + input.absoluteString + ")\n```\n[ordinary link](" + input.absoluteString + ")\n![remote](https://example.invalid/image.jpg)"
        check(ResponseImages.capture(quoted, roots: [allowed], destination: output).isEmpty, "Response image imports ignore code examples, ordinary links and network URLs")
        let spaced = allowed.appendingPathComponent("full page.png")
        let tall = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 17000, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(tall.bitmapData!, 180, tall.bytesPerRow * tall.pixelsHigh)
        var tallBytes = tall.representation(using: .png, properties: [:])!
        tallBytes.append(Data(count: 8_000_001 - tallBytes.count))
        try tallBytes.write(to: spaced)
        for target in [spaced.absoluteString, "file://" + spaced.path, "<file://" + spaced.path + ">"] {
            let captured = ResponseImages.capture("![Full page](" + target + ")", roots: [allowed], destination: output)
            let normalized = captured.first.flatMap { try? Data(contentsOf: $0.file) }
            let decoded = normalized.flatMap(NSBitmapImageRep.init(data:))
            check(captured.count == 1 && (normalized?.count ?? Int.max) <= 8_000_000 && (decoded?.pixelsHigh ?? 0) > 2048 && (decoded?.pixelsHigh ?? Int.max) <= 16384, "Tall image above old byte/height limits imports with detail and bounded output: " + (target.contains("%20") ? "encoded" : "spaces"))
        }
        check((try Data(contentsOf: spaced)) == tallBytes, "Normalization preserves the original full-page file")
        let tooLarge = allowed.appendingPathComponent("over-limit.png")
        FileManager.default.createFile(atPath: tooLarge.path, contents: nil)
        let oversizedHandle = try FileHandle(forWritingTo: tooLarge)
        try oversizedHandle.truncate(atOffset: UInt64(ResponseImages.localInputLimit + 1)); try oversizedHandle.close()
        check(ResponseImages.capture("![Large](" + tooLarge.absoluteString + ")", roots: [allowed], destination: output).isEmpty, "Local image input limit remains bounded")
        let unavailable = MarkdownText.render("![Missing](" + spaced.absoluteString + ")")
        check(unavailable.string.contains("Image not displayed") && unavailable.string.contains("full%20page.png"), "Uncaptured local images retain an explicit fallback path")
        check(ConverseExchange.neutralizeLocalImages("![Raw](file://" + spaced.path + ")").hasPrefix("[Raw]"), "Imported raw-space local embeds remain neutralized")
        for planted in ["!![x](/tmp/a.png)", "!!![x](/tmp/a.png)", "!!!!![x](file:///tmp/a.png)", "!![x](< /tmp/a.png>)", "!![x](FILE:///tmp/a.png) !![y](/tmp/b.png)"] {
            let neutral = ConverseExchange.neutralizeLocalImages(planted)
            check(TranscriptStyle.localImageReferences(neutral).isEmpty && neutral.contains("[x]("), "Stacked image markers cannot rebuild a local embed: " + planted)
        }
        // A hostile import with long marker runs must stay linear: whole runs go at once.
        for target in ["(/tmp/nonexistent.png)", "(~/a.png)", "(file:///tmp/a.png)", "(relative.png)"] {
            let hostile = String(repeating: "!", count: 20_000) + "[x]" + target
            let started = Date()
            let neutral = ConverseExchange.neutralizeLocalImages(hostile)
            // Relative paths were never local embeds and stay as written.
            let neutralized = target == "(relative.png)" ? neutral == hostile : neutral.hasPrefix("[x]")
            check(TranscriptStyle.localImageReferences(neutral).isEmpty && neutralized && Date().timeIntervalSince(started) < 0.5, "20,000 stacked image markers are handled in one bounded pass: " + target)
        }
        let fencedExample = "```\n![![x](/tmp/code-example.png)\n```\n" + String(repeating: "![", count: 3) + "x](/tmp/nonexistent.png)"
        let fencedNeutral = ConverseExchange.neutralizeLocalImages(fencedExample)
        check(TranscriptStyle.localImageReferences(fencedNeutral).isEmpty && fencedNeutral.hasPrefix("```\n![[x](/tmp/code-example.png)\n```\n"), "Nested-marker cleanup only edits lines the fence-aware scan flags")
        // Rejecting long nested or unclosed lines must stay bounded too.
        for tail in ["x](https://example.com/w.png)", "x](relative.png)", "x(/tmp/a.png", "x](/tmp/a.png)"] {
            let line = String(repeating: "![", count: 10_000) + tail
            let started = Date()
            let local = TranscriptStyle.localImageReferences(line), web = TranscriptStyle.imageReferences(line)
            let neutral = ConverseExchange.neutralizeLocalImages(line)
            check(Date().timeIntervalSince(started) < 0.5 && TranscriptStyle.localImageReferences(neutral).isEmpty && local.count <= 1 && web.count <= 1, "10,000 nested image openers are scanned in bounded time: " + tail)
        }
        check(TranscriptStyle.imageReferences("![" + String(repeating: "a", count: 600) + "](https://example.com/w.png)").isEmpty && TranscriptStyle.imageReferences("![Chart](https://example.com/w.png)").count == 1, "Image captions longer than 512 characters are not treated as images")
        let balancedShot = "![x](/tmp/shot(1).png)"
        let balancedRefs = TranscriptStyle.localImageReferences(balancedShot)
        check(balancedRefs.count == 1 && balancedRefs.first?.url.path == "/tmp/shot(1).png" && balancedRefs.first?.range == NSRange(location: 0, length: (balancedShot as NSString).length), "Image paths keep balanced parentheses")
        check(TranscriptStyle.localImageReferences("![x](/tmp/a(b(c))(d).png) ![y](/tmp/y.png)").map(\.url.path) == ["/tmp/a(b(c))(d).png", "/tmp/y.png"], "Nested parentheses end at the image's own closer and the next image still parses")
        check(TranscriptStyle.localImageReferences("![x](file:///tmp/my%20shot(1).png)").first?.url.path == "/tmp/my shot(1).png" && TranscriptStyle.localImageReferences("![x](file:///tmp/my shot(1).png)").first?.url.path == "/tmp/my shot(1).png", "File URLs keep balanced parentheses, encoded or with raw spaces")
        check(TranscriptStyle.imageReferences("![w](https://example.com/w_(1).png)").first?.url.absoluteString == "https://example.com/w_(1).png", "Web image URLs keep balanced parentheses")
        check(TranscriptStyle.imageLinks("![w](https://example.com/w_(1).png) tail") == "w: [https://example.com/w\\_(1).png](https://example.com/w_(1).png) tail", "Image fallbacks replace the whole parenthesized reference")
        let unbalancedLine = "![x](/tmp/a(b.png) and more)"
        check(TranscriptStyle.localImageReferences(unbalancedLine).first?.url.path == "/tmp/a(b.png" && TranscriptStyle.localImageReferences(unbalancedLine).first?.range.length == ("![x](/tmp/a(b.png)" as NSString).length, "An unbalanced parenthesis keeps the original first-closer match")
        let prose = TranscriptStyle.localImageReferences("![x](file:///tmp/a(b.png) and more)")
        check(prose.first?.url.path == "/tmp/a(b.png" && prose.first?.range.length == ("![x](file:///tmp/a(b.png)" as NSString).length, "A raw-space file target keeps its first closer instead of absorbing later prose")
        let pastBound = "![x](/tmp/a(" + String(repeating: "b", count: 4080) + ")" + String(repeating: "c", count: 20) + ".png)"
        check(TranscriptStyle.localImageReferences(pastBound).first?.url.path.hasSuffix("b") == true, "Balanced scanning never reads past the target bound")
        let balancedFallback = MarkdownText.inline(balancedShot), balancedURL = URL(fileURLWithPath: "/tmp/shot(1).png")
        var balancedAttribute: URL?
        balancedFallback.enumerateAttribute(LocalImageFallback.attribute, in: NSRange(location: 0, length: balancedFallback.length)) { value, _, _ in if let url = value as? URL { balancedAttribute = url } }
        check(balancedAttribute == balancedURL && !balancedFallback.string.hasSuffix(".png)"), "A parenthesized local image renders one complete fallback link")
        check(ConverseExchange.neutralizeLocalImages(balancedShot) == "[x](/tmp/shot(1).png)" && TranscriptStyle.localImageReferences(ConverseExchange.neutralizeLocalImages(balancedShot)).isEmpty, "Import neutralization covers parenthesized paths")
        do {
            let hostile = String(repeating: "![x](/tmp/a()", count: 20_000), started = Date()
            let found = TranscriptStyle.localImageReferences(hostile)
            check(found.count == 20_000 && found.allSatisfy { $0.url.path == "/tmp/a(" } && Date().timeIntervalSince(started) < 1, "Repeated open parentheses stay linear and keep their first-closer matches")
        }
        check(TranscriptStyle.localImageReferences("![![x](/tmp/a.png)").count == 1 && TranscriptStyle.localImageReferences(ConverseExchange.neutralizeLocalImages("![![x](/tmp/a.png)")).isEmpty, "A nested local embed is still found and neutralized")
        // Nested opening markers once needed one round per level; any depth now goes in one pass.
        for depth in [2, 6, 10, 100, 5_000] {
            let nestedImport = String(repeating: "![", count: depth) + "x](/tmp/nonexistent.png)\n![web](https://example.com/w.png)"
            let started = Date()
            let neutral = ConverseExchange.neutralizeLocalImages(nestedImport)
            check(TranscriptStyle.localImageReferences(neutral).isEmpty && neutral.hasSuffix("\n![web](https://example.com/w.png)") && Date().timeIntervalSince(started) < 0.5, "Nested image markers cannot keep a local embed: depth \(depth)")
        }
        check(TranscriptStyle.splice("abc", [(NSRange(location: Int.max - 1, length: 5), "X"), (NSRange(location: 1, length: Int.max), "Y"), (NSRange(location: 4, length: 0), "Z")]) == "abc", "Splice ignores malformed ranges without overflowing")
        let mixed = ConverseExchange.neutralizeLocalImages("![web](https://example.com/w.png)\n!![local](/tmp/a.png) ![two](https://example.com/v.png)")
        check(mixed == "![web](https://example.com/w.png)\n[local](/tmp/a.png) ![two](https://example.com/v.png)" && TranscriptStyle.imageReferences(mixed).count == 2, "Neutralizing local embeds leaves web images intact")
        // Separate web and local scans can enclose one another; rendering must never raise.
        let nested = "![a](file:///x ![](https://y.co/i.png" + String(repeating: " ", count: 40) + ")"
        let nestedRefs = TranscriptStyle.imageReferences(nested).map(\.range) + TranscriptStyle.localImageReferences(nested).map(\.range)
        check(nestedRefs.count == 2 && nestedRefs.contains { outer in nestedRefs.contains { $0 != outer && NSIntersectionRange($0, outer).length > 0 } }, "Nested image fixture really produces overlapping references")
        let nestedOutput = TranscriptStyle.imageLinks(nested)
        check(nestedOutput.hasPrefix("Image not displayed: a: [") && !nestedOutput.contains("!["), "An image reference enclosing another renders once without raising")
        let nestedRender = MarkdownText.render(nested + "\nafter").string
        check(nestedRender.hasPrefix("Image not displayed: a: ") && nestedRender.trimmingCharacters(in: .newlines).hasSuffix("after"), "Overlapping image references render through Markdown")
        check(TranscriptStyle.splice("abcdef", [(NSRange(location: 1, length: 4), "X"), (NSRange(location: 2, length: 1), "Y")]) == "aXf", "Splice keeps the outer of nested ranges")
        check(TranscriptStyle.splice("abcdef", [(NSRange(location: 2, length: 3), "Y"), (NSRange(location: 1, length: 2), "X")]) == "aXdef", "Splice keeps the earlier of partly overlapping ranges")
        check(TranscriptStyle.splice("abcdef", [(NSRange(location: 1, length: 2), "X"), (NSRange(location: 1, length: 2), "Y")]).count == 5, "Splice applies identical ranges once")
        check(TranscriptStyle.splice("abcdef", [(NSRange(location: 3, length: 2), "Y"), (NSRange(location: 1, length: 2), "X")]) == "aXYf", "Splice applies adjacent ranges in order")
        check(TranscriptStyle.splice("abc", [(NSRange(location: 2, length: 9), "X"), (NSRange(location: 9, length: 1), "Y"), (NSRange(location: 0, length: 1), "Z")]) == "Zbc", "Splice ignores ranges beyond the text")
        check(TranscriptStyle.imageLinks("See ![one](https://example.com/1.png) and ![](https://example.com/2.png)\n![three](/tmp/missing-3.png)") == "See one: [https://example.com/1.png](https://example.com/1.png) and [https://example.com/2.png](https://example.com/2.png)\nImage not displayed: three: [file:///tmp/missing-3.png](file:///tmp/missing-3.png)", "Single and multiple image fallbacks render as before")
        if let fixture = ProcessInfo.processInfo.environment["CONVERSE_RESPONSE_IMAGE_FIXTURE"] {
            let file = URL(fileURLWithPath: fixture)
            let captured = ResponseImages.capture("![Full-page regression](" + file.absoluteString + ")", roots: [file.deletingLastPathComponent()], destination: output)
            check(captured.count == 1, "Real full-page screenshot captures into a managed attachment")
            if let captured = captured.first {
                let fixtureSession = Session(entry: Entry(name: "Image fixture", command: "unused", directory: root.path, engine: "codex"))
                fixtureSession.messages = [Message(role: "assistant", text: captured.caption, images: [captured.file.path])]
                let view = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
                let coordinator = ScrollingConversation.Coordinator(fixtureSession); coordinator.render(view)
                var attachments = 0
                view.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.textStorage?.length ?? 0)) { value, _, _ in if value is NSTextAttachment { attachments += 1 } }
                check(attachments == 1, "Real full-page screenshot renders as a native transcript image")
            }
        }
        let remoteURL = URL(string: "https://images.example.invalid/valid.jpg")!
        let loader = ResponseImageLoader()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ResponseImageFixture.self]
        loader.configuration = config; loader.validate = { $0.host == "images.example.invalid" && $0.scheme == "https" }
        ResponseImageFixture.photo = try Data(contentsOf: input)
        func fetch(_ path: String) -> Result<Data, Error>? {
            var result: Result<Data, Error>?
            let url = URL(string: "https://images.example.invalid/" + path)!
            loader.enqueue(key: path, url: url) { result = $0 }
            let deadline = Date().addingTimeInterval(5)
            while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            return result
        }
        if case .success(let png)? = fetch("valid.jpg") { check(png.prefix(8) == Data([137,80,78,71,13,10,26,10]), "HTTPS image download normalizes into managed PNG bytes") }
        else { check(false, "HTTPS image download fixture completes") }
        ResponseImageFixture.lastRequestURL = nil
        if case .success? = fetch("valid.jpg?smuggled=secret#fragment") {
            let requested = ResponseImageFixture.lastRequestURL
            check(requested?.query == nil && requested?.fragment == nil && requested?.path == "/valid.jpg", "Image requests carry no query or fragment")
        } else { check(false, "Image request stripping fixture completes") }
        check(ResponseImages.unreachableNotice(url: URL(string: "https://evil.example.invalid/x?k=v")!).hasPrefix("Image could not be loaded from evil.example.invalid"), "Unreachable image notices lead with the host")
        for path in ["large-header", "large-body", "not-an-image", "missing"] {
            if case .failure? = fetch(path) { check(true, "HTTPS image rejects " + path) } else { check(false, "HTTPS image rejects " + path) }
        }
        check(!ResponseImageDownload.publicHTTPS(URL(string: "http://example.com/a.jpg")!) && !ResponseImageDownload.publicHTTPS(URL(string: "https://127.0.0.1/a.jpg")!) && !ResponseImageDownload.publicHTTPS(URL(string: "https://user:password@example.com/a.jpg")!), "Image downloads reject insecure, private and credential-bearing URLs")
        check(!ResponseImageDownload.allowedIPv4(0x0a000001) && !ResponseImageDownload.allowedIPv4(0xc0a80101) && !ResponseImageDownload.allowedIPv4(0x7f000001) && ResponseImageDownload.allowedIPv4(0x08080808), "Image destination checks distinguish private and public IPv4")
        let fallback = MarkdownText.render("![Grasshopper](" + remoteURL.absoluteString + ")")
        let urlStart = (fallback.string as NSString).range(of: remoteURL.absoluteString).location
        check(urlStart != NSNotFound && fallback.attribute(.link, at: urlStart, effectiveRange: nil) as? URL == remoteURL && fallback.string.hasPrefix("Grasshopper: "), "Unloaded response image shows its caption and clickable URL on Mac")
        check(TranscriptStyle.imageLinks("![](https://example.com/a_b*c*.png)") == "[https://example.com/a\\_b\\*c\\*.png](https://example.com/a_b*c*.png)", "Image URL labels escape Markdown punctuation")
        check(TranscriptStyle.imageLinks("```md\n![example](" + remoteURL.absoluteString + ")\n```").hasPrefix("```md\n!["), "Image fallbacks leave fenced examples untouched")
        let redirectClient = ResponseImageDownload(configuration: .ephemeral, validate: ResponseImageDownload.publicHTTPS) { _ in }
        let redirectSession = URLSession(configuration: .ephemeral)
        let redirectTask = redirectSession.dataTask(with: remoteURL)
        var redirectBlocked = false
        redirectClient.urlSession(redirectSession, task: redirectTask, willPerformHTTPRedirection: HTTPURLResponse(url: remoteURL, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: URLRequest(url: URL(string: "https://127.0.0.1/private")!)) { redirectBlocked = $0 == nil }
        redirectSession.invalidateAndCancel()
        check(redirectBlocked, "Image redirects cannot enter private network destinations")
        let store = Store(folder: root.appendingPathComponent("store"))
        let session = store.create(Entry(name: "Fixture", command: "unused", directory: allowed.path, engine: "codex"))
        session.messages = [Message(role: "assistant", text: source)]
        check(store.importResponseImages(session) && session.messages[0].images.count == 1 && !session.messages[0].text.contains("!["), "Returned image is promoted into the session transcript attachment list")
        store.save()
        let restored = Store(folder: store.folder)
        check(restored.sessions.first?.messages.first?.images == session.messages[0].images && !restored.importResponseImages(restored.sessions[0]), "Imported response image survives restart without duplicate attachments")
        var validations = 0
        store.responseImageLoader.configuration = config
        store.responseImageLoader.validate = { validations += 1; return loader.validate($0) }
        let remote = store.create(Entry(name: "Remote image", command: "unused", directory: allowed.path, engine: "claude"))
        remote.messages = [Message(role: "assistant", text: "![Grasshopper](" + remoteURL.absoluteString + ")")]
        ResponseImageFixture.lastRequestURL = nil
        store.finishQueue(remote, success: true)
        store.importResponseImages(remote)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check(validations == 0 && ResponseImageFixture.lastRequestURL == nil && remote.messages[0].images.isEmpty && remote.messages[0].text.contains("!["), "Finishing a turn never fetches or resolves a web image")
        store.loadResponseImage(remote, messageID: remote.messages[0].id, url: remoteURL)
        store.loadResponseImage(remote, messageID: remote.messages[0].id, url: remoteURL)
        let deadline = Date().addingTimeInterval(5)
        while remote.messages[0].images.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(remote.messages[0].images.count == 1 && remote.messages[0].text == "Grasshopper" && validations == 1 && ResponseImageFixture.lastRequestURL?.path == "/valid.jpg", "Load image fetches the clicked web image exactly once into transcript attachments")
        store.loadResponseImage(remote, messageID: remote.messages[0].id, url: remoteURL)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check(validations == 1, "A loaded web image is never fetched again")
        store.save()
        check(Store(folder: store.folder).sessions.first(where: { $0.id == remote.id })?.messages[0].images == remote.messages[0].images, "Loaded reply images survive archive restore")
        let hoverSession = store.create(Entry(name: "Hover image", command: "unused", directory: allowed.path, engine: "claude"))
        hoverSession.messages = [Message(role: "assistant", text: "Look\n![Grasshopper](" + remoteURL.absoluteString + ")\nmore text")]
        let hoverView = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        hoverView.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        ScrollingConversation.Coordinator(hoverSession).render(hoverView)
        var hoverClicks = 0
        check(hoverView.hasImageLinks && hoverView.imageHoverTracking == nil, "A rendered web image link is detected; no move tracking until Load image is available")
        hoverView.loadImage = { _ in hoverClicks += 1 }
        check(hoverView.imageHoverTracking?.options.contains(.mouseMoved) == true, "Move tracking exists while a hoverable web image link is shown")
        let plainSession = store.create(Entry(name: "Plain hover", command: "unused", directory: allowed.path, engine: "claude"))
        plainSession.messages = [Message(role: "assistant", text: "No images here, just [a link](https://example.invalid/page) and text")]
        let plainView = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        plainView.loadImage = { _ in }
        ScrollingConversation.Coordinator(plainSession).render(plainView)
        check(!plainView.hasImageLinks && plainView.imageHoverTracking == nil, "Transcripts without web image links install no per-move tracking")
        check(ConversationTextView.containsImageLinks(NSAttributedString(string: "x"), in: NSRange(location: 5, length: 3)) == false, "Image link scan tolerates out-of-range requests")
        let beforeHover = validations
        var linkRange = NSRange(location: NSNotFound, length: 0)
        hoverView.textStorage?.enumerateAttribute(.converseImageLink, in: NSRange(location: 0, length: hoverView.textStorage?.length ?? 0)) { value, range, stop in
            if (value as? ResponseImageLink)?.url == remoteURL { linkRange = range; stop.pointee = true }
        }
        if linkRange.location != NSNotFound, let layout = hoverView.layoutManager, let container = hoverView.textContainer {
            layout.ensureLayout(for: container)
            let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: linkRange, actualCharacterRange: nil), in: container).offsetBy(dx: hoverView.textContainerOrigin.x, dy: hoverView.textContainerOrigin.y)
            check((hoverView.string as NSString).substring(with: linkRange) == remoteURL.absoluteString, "Unloaded web image shows its URL as the hover target")
            hoverView.updateImageHover(NSPoint(x: rect.minX + 4, y: rect.midY))
            check(hoverView.imageHover?.isHidden == false && (hoverView.imageHover?.frame.minY ?? 0) >= rect.maxY && hoverView.imageHover?.link?.url == remoteURL, "Hovering a web image link shows Load image directly beneath it")
            hoverView.updateImageHover(NSPoint(x: rect.minX + 4, y: rect.minY - 30))
            check(hoverView.imageHover?.isHidden == true && hoverClicks == 0 && validations == beforeHover, "Moving off the link hides Load image; hovering never fetches")
            // A real mouse-moved event, as AppKit delivers it through the tracking area.
            let hoverWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            hoverWindow.isReleasedWhenClosed = false; hoverWindow.contentView = hoverView
            func move(to point: NSPoint) {
                guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: hoverView.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: hoverWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { check(false, "Mouse-moved fixture event"); return }
                hoverView.mouseMoved(with: event)
            }
            move(to: NSPoint(x: rect.minX + 4, y: rect.midY))
            check(hoverView.imageHoverTracking != nil && hoverView.imageHover?.isHidden == false && hoverView.imageHover?.link?.url == remoteURL, "A real mouse-moved event over a web image link shows Load image")
            move(to: NSPoint(x: rect.minX + 4, y: rect.minY - 30))
            check(hoverView.imageHover?.isHidden == true && hoverClicks == 0 && validations == beforeHover, "A real mouse-moved event off the link hides Load image without fetching")
            hoverWindow.contentView = nil; hoverWindow.close()
            hoverView.loadImage = nil
            hoverView.updateImageHover(NSPoint(x: rect.minX + 4, y: rect.midY))
            check(hoverView.imageHover?.isHidden != false, "Viewer panes offer no Load image")
            check(hoverView.imageHoverTracking == nil, "Viewer panes drop per-move tracking with Load image")
        } else { check(false, "Web image link carries a hover target in the rendered transcript") }
        let missingURL = URL(string: "https://images.example.invalid/missing")!
        let failing = store.create(Entry(name: "Failing image", command: "unused", directory: allowed.path, engine: "claude"))
        failing.messages = [Message(role: "assistant", text: "![Gone](" + missingURL.absoluteString + ")")]
        func clickMissing() { let before = failing.messages.count; store.loadResponseImage(failing, messageID: failing.messages[0].id, url: missingURL); let end = Date().addingTimeInterval(5); while failing.messages.count == before && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) } }
        clickMissing(); clickMissing()
        check(failing.messages.filter { $0.role == "notice" }.count == 2 && failing.messages[0].text.contains("!["), "A failed Load image reports the host and can be retried")
        let localOnly = store.create(Entry(name: "Local only", command: "unused", directory: allowed.path, engine: "codex"))
        ResponseImageFixture.lastRequestURL = nil
        localOnly.messages = [Message(role: "assistant", text: "Photo\n![Grasshopper](" + input.absoluteString + ")")]
        check(store.importResponseImages(localOnly) && localOnly.messages[0].images.count == 1 && !localOnly.messages[0].text.contains("![") && ResponseImageFixture.lastRequestURL == nil, "Local image captures need no click or remote request")
        store.sessions.removeAll { [remote.id, failing.id, localOnly.id, hoverSession.id].contains($0.id) }

    } catch { check(false, "Response image fixture: " + error.localizedDescription) }
    imageLinkSuspicionSelfTests(check)
}

func imageLinkSuspicionSelfTests(_ check: (Bool, String) -> Void) {
    func reasons(_ link: String, _ caption: String = "") -> [String] { ImageLinkSuspicion.reasons(URL(string: link)!, caption: caption) }
    for clean in ["https://upload.wikimedia.org/wikipedia/commons/thumb/a/a9/Example.jpg/320px-Example.jpg",
                  "https://raw.githubusercontent.com/apple/swift/main/docs/swift-logo.png",
                  "https://github.com/user-attachments/assets/1c6f4f4e-8f43-4a0e-9b8e-2b0c3e8d7a11",
                  "https://avatars.githubusercontent.com/u/9919?s=200&v=4"] {
        check(reasons(clean, "Example diagram").isEmpty, "Clean image link passes the suspicion check: " + clean)
    }
    check(reasons("https://upload.wikimedia.org/a.png", "upload.wikimedia.org").isEmpty && reasons("https://www.github.com/a.png", "github.com").isEmpty, "Link text naming the same site passes")
    let cases: [(String, String, String)] = [
        ("http://example.com/a.png", "", "not HTTPS"),
        ("https://93.184.216.34/a.png", "", "IP address instead of a name"),
        ("https://[2606:4700::1111]/a.png", "", "IP address instead of a name"),
        ("https://localhost/a.png", "", "private network name"),
        ("https://printer.local/a.png", "", "private network name"),
        ("https://xn--gthub-n4a.com/a.png", "", "punycode (lookalike) hostname"),
        ("https://a.b.c.example.com/a.png", "", "many subdomains"),
        ("https://averyveryverylonghostnamelabel.example.com/a.png", "", "long hostname label"),
        ("https://a1b2c3d4e5f6a7b8c9d0e1f2.attacker.com/a.png", "", "long random-looking hostname"),
        ("https://attacker.com/c2VjcmV0LWtleS0xMjM0NTY3ODkw.png", "", "long random-looking path"),
        ("https://attacker.com/kqzjxvbwmpltrfhgdnsyxc.png", "", "long random-looking path"),
        ("https://user@example.com/a.png", "", "user name in link"),
        ("https://example.com:8443/a.png", "", "unusual port 8443"),
        ("https://evil.example/a.png", "github.com", "link text names github.com"),
        ("https://evil.example/a.png", "https://github.com/logo.png", "link text names github.com"),
    ]
    for (link, caption, reason) in cases { check(reasons(link, caption).contains(reason), "Suspicion check flags " + reason + ": " + link) }
    check(ImageLinkSuspicion.warning(["not HTTPS"]) == "⚠︎ Looks suspicious: not HTTPS" && ImageLinkSuspicion.warning([]).isEmpty, "Suspicion warning reads as one short line")
}

// Only the reader's Load image click enqueues. Two concurrent downloads, no cookies, credentials or persistent web cache.
// Redirects get the same public HTTPS destination checks as the initial URL.
final class ResponseImageLoader {
    struct Job { let key: String; let url: URL; let completion: (Result<Data, Error>) -> Void }
    var configuration: URLSessionConfiguration = .ephemeral
    var validate: (URL) -> Bool = ResponseImageDownload.publicHTTPS
    private var attempted: Set<String> = []
    private var pending: [Job] = []
    private var active: [String: ResponseImageDownload] = [:]
    func enqueue(key: String, url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        guard !attempted.contains(key), pending.count < 64 else { return }
        attempted.insert(key); pending.append(Job(key: key, url: url, completion: completion)); pump()
    }
    private func pump() {
        while active.count < 2 && !pending.isEmpty {
            let job = pending.removeFirst()
            let download = ResponseImageDownload(configuration: configuration, validate: validate) { [weak self] result in
                // A failed click may be retried; a loaded image never refetches.
                if case .failure = result { self?.attempted.remove(job.key) }
                self?.active.removeValue(forKey: job.key); job.completion(result); self?.pump()
            }
            active[job.key] = download; download.start(job.url)
        }
    }
}
final class ResponseImageDownload: NSObject, URLSessionDataDelegate {
    static let limit = 8_000_000
    let configuration: URLSessionConfiguration
    let validate: (URL) -> Bool
    let completion: (Result<Data, Error>) -> Void
    private var session: URLSession?
    private var bytes = Data()
    private var rejected = false
    private var redirects = 0
    init(configuration: URLSessionConfiguration, validate: @escaping (URL) -> Bool, completion: @escaping (Result<Data, Error>) -> Void) {
        self.configuration = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        self.validate = validate; self.completion = completion
    }
    static func allowedIPv4(_ value: UInt32) -> Bool {
        let a = value >> 24, b = (value >> 16) & 255, c = (value >> 8) & 255
        return !(a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && (64...127).contains(b)) ||
                 (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) ||
                 (a == 192 && (b == 168 || b == 0 || (b == 88 && c == 99))) ||
                 (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) || (a == 203 && b == 0 && c == 113))
    }
    // The request carries no query or fragment: model output can smuggle
    // private context into either, and the host alone identifies the fetch.
    static func stripped(_ url: URL) -> URL? {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.query = nil; parts?.fragment = nil
        return parts?.url
    }
    static func publicHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host, !host.isEmpty else { return false }
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &addresses) == 0, let first = addresses else { return false }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let address = current {
            defer { current = address.pointee.ai_next }
            guard let raw = address.pointee.ai_addr else { return false }
            if address.pointee.ai_family == AF_INET {
                let ipv4 = UnsafeRawPointer(raw).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
                guard allowedIPv4(ipv4) else { return false }
            } else if address.pointee.ai_family == AF_INET6 {
                var ipv6 = UnsafeRawPointer(raw).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                let octets = withUnsafeBytes(of: &ipv6) { Array($0) }
                guard octets[0] & 0xe0 == 0x20, Array(octets.prefix(4)) != [0x20, 0x01, 0x0d, 0xb8] else { return false }
            } else { return false }
        }
        return true
    }
    func start(_ url: URL) {
        DispatchQueue.global(qos: .utility).async {
            guard let fetch = Self.stripped(url), self.validate(fetch) else { self.finish(.failure(URLError(.unsupportedURL))); return }
            let config = self.configuration
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            self.session = session; session.dataTask(with: fetch).resume()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 3, let raw = request.url, let url = Self.stripped(raw), validate(url) else { rejected = true; completionHandler(nil); return }
        var stripped = request; stripped.url = url
        completionHandler(stripped)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !rejected, let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= Int64(Self.limit) else { rejected = true; completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !rejected, bytes.count <= Self.limit - data.count else { rejected = true; dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate(); self.session = nil
        guard !rejected, error == nil, let png = ResponseImages.normalizedPNG(bytes) else { finish(.failure(error ?? URLError(.cannotDecodeContentData))); return }
        finish(.success(png))
    }
    private func finish(_ result: Result<Data, Error>) { DispatchQueue.main.async { self.completion(result) } }
}

// Offline URL loading peer: real URLSession delegates and image decoding, no LAN requests.
final class ResponseImageFixture: URLProtocol {
    static var photo = Data()
    static var lastRequestURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "images.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequestURL = request.url
        let path = request.url!.lastPathComponent
        let body = path == "large-body" ? Data(count: ResponseImageDownload.limit + 1) : (path == "not-an-image" ? Data("plain text".utf8) : Self.photo)
        let headers = path == "large-header" ? ["Content-Length": "9000000"] : ["Content-Type": "image/jpeg"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: path == "missing" ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func probeResponseImage(_ url: URL, folder: URL) -> Bool {
    let loader = ResponseImageLoader()
    var result: Result<Data, Error>?
    loader.enqueue(key: "probe", url: url) { result = $0 }
    let deadline = Date().addingTimeInterval(30)
    while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    guard case .success(let png)? = result else { fputs("Image download failed.\n", stderr); return false }
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("reply-image.png"); try png.write(to: file, options: .atomic)
        print("Downloaded and normalized \(png.count) PNG bytes: \(file.path)"); return true
    } catch { fputs("Could not save image probe.\n", stderr); return false }
}

// Hovering a web image link in a home reply offers Load image directly
// beneath it, with the suspicion warning beside the button.
final class ResponseImageLink: NSObject {
    let messageID: UUID, url: URL, caption: String
    init(messageID: UUID, url: URL, caption: String) { self.messageID = messageID; self.url = url; self.caption = caption }
    func same(_ other: ResponseImageLink?) -> Bool { other?.messageID == messageID && other?.url == url }
}
extension NSAttributedString.Key { static let converseImageLink = NSAttributedString.Key("Converse.imageLink") }
final class ResponseImageLoadControl: NSView {
    private(set) var link: ResponseImageLink?
    private let button = NSButton(title: "Load image", target: nil, action: nil)
    private let warning = NSTextField(labelWithString: "")
    var load: ((ResponseImageLink) -> Void)?
    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 4; layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        button.bezelStyle = .rounded; button.controlSize = .small; button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = self; button.action = #selector(clicked)
        warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize); warning.textColor = .systemOrange
        warning.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [button, warning]); stack.spacing = 6; stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { nil }
    func show(_ link: ResponseImageLink, at origin: NSPoint, maxWidth: CGFloat) {
        if !link.same(self.link) { button.title = "Load image"; button.isEnabled = true }
        self.link = link
        let reasons = ImageLinkSuspicion.reasons(link.url, caption: link.caption)
        warning.stringValue = ImageLinkSuspicion.warning(reasons); warning.isHidden = reasons.isEmpty
        warning.toolTip = reasons.isEmpty ? nil : warning.stringValue
        setAccessibilityLabel("Load image from " + (link.url.host ?? "link"))
        let size = fittingSize
        frame = NSRect(x: origin.x, y: origin.y, width: min(size.width, max(maxWidth, button.fittingSize.width + 8)), height: size.height)
        isHidden = false
    }
    @objc private func clicked() {
        guard let link else { return }
        let reasons = ImageLinkSuspicion.reasons(link.url, caption: link.caption)
        if !reasons.isEmpty {
            let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Load anyway?"
            alert.informativeText = "This image link looks suspicious: " + reasons.joined(separator: ", ") + ".\n\n" + link.url.absoluteString + "\n\nLoading it contacts " + (link.url.host ?? "this host") + ". A link written by a prompt injection can leak conversation details this way."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Load Anyway")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        button.title = "Loading…"; button.isEnabled = false
        load?(link)
    }
}
extension ConversationTextView {
    func updateImageHover(_ point: NSPoint) {
        if let control = imageHover, !control.isHidden, control.frame.insetBy(dx: -4, dy: -4).contains(point) { return }
        guard loadImage != nil, let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { hideImageHover(); return }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        guard glyph < layout.numberOfGlyphs, layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { hideImageHover(); return }
        let character = layout.characterIndexForGlyph(at: glyph)
        guard character < min(inputStart, storage.length), let link = storage.attribute(.converseImageLink, at: character, effectiveRange: nil) as? ResponseImageLink else { hideImageHover(); return }
        showImageHover(link)
    }
    // Re-anchors after a transcript render, or hides once the link is gone
    // (its image loaded and the reference collapsed to a caption).
    func refreshImageHover() {
        guard let link = imageHover?.link, imageHover?.isHidden == false else { return }
        showImageHover(link)
    }
    private func showImageHover(_ link: ResponseImageLink) {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return }
        var found: NSRange?
        storage.enumerateAttribute(.converseImageLink, in: NSRange(location: 0, length: min(inputStart, storage.length))) { value, range, stop in
            if link.same(value as? ResponseImageLink) { found = range; stop.pointee = true }
        }
        guard let range = found else { hideImageHover(); return }
        let control = imageHover ?? {
            let made = ResponseImageLoadControl(); addSubview(made); imageHover = made
            made.load = { [weak self] in self?.loadImage?($0) }
            return made
        }()
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let last = layout.lineFragmentUsedRect(forGlyphAt: max(glyphs.location, NSMaxRange(glyphs) - 1), effectiveRange: nil).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        control.show(link, at: NSPoint(x: rect.minX, y: max(rect.maxY, last.maxY) + 1), maxWidth: bounds.width - rect.minX - textContainerInset.width)
    }
    func hideImageHover() { imageHover?.isHidden = true }
}
