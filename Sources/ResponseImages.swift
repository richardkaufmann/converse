import AppKit
import CryptoKit
import ImageIO

// Explicit image references become managed attachments. File imports stay
// inside permitted roots; HTTPS downloads use a bounded, credential-free client.
enum ResponseImages {
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

extension Store {
    func responseImageFolder(_ session: Session) -> URL { folder.appendingPathComponent("Attachments").appendingPathComponent(session.id.uuidString).appendingPathComponent("Outputs") }
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
        for index in session.messages.indices where session.messages[index].role == "assistant" && session.messages[index].text.contains("![") {
            let items = ResponseImages.capture(session.messages[index].text, roots: roots, destination: output)
            guard !items.isEmpty else { continue }
            let text = NSMutableString(string: session.messages[index].text)
            for item in items.reversed() { text.replaceCharacters(in: item.range, with: item.caption) }
            session.messages[index].text = text as String
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
                    let text = NSMutableString(string: session.messages[index].text)
                    for item in refs.reversed() { text.replaceCharacters(in: item.range, with: item.caption) }
                    session.messages[index].text = text as String
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
        hoverView.loadImage = { _ in hoverClicks += 1 }
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
            hoverView.loadImage = nil
            hoverView.updateImageHover(NSPoint(x: rect.minX + 4, y: rect.midY))
            check(hoverView.imageHover?.isHidden != false, "Viewer panes offer no Load image")
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
