import AppKit
import CryptoKit
import ImageIO

// Explicit image references become managed attachments. File imports stay
// inside permitted roots; HTTPS downloads use a bounded, credential-free client.
enum ResponseImages {
    struct Captured { var range: NSRange; var caption: String; var file: URL }
    static func capture(_ text: String, roots: [URL], destination: URL) -> [Captured] {
        let expression = try! NSRegularExpression(pattern: #"!\[([^\]\r\n]*)\]\(\s*(?:<([^>\r\n]+)>|([^\s\)]+))\s*\)"#)
        let allowed = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
        var captured: [Captured] = []; var offset = 0; var fence: String?
        for line in text.components(separatedBy: "\n") {
            defer { offset += (line as NSString).length + 1 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3)); if fence == marker { fence = nil } else if fence == nil { fence = marker }; continue
            }
            guard fence == nil, !trimmed.hasPrefix(">"), !line.contains("`"), captured.count < 8 else { continue }
            let source = line as NSString
            for match in expression.matches(in: line, range: NSRange(location: 0, length: source.length)) where captured.count < 8 {
                guard match.range.location == 0 || source.substring(with: NSRange(location: match.range.location - 1, length: 1)) != "\\" else { continue }
                let urlRange = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
                let path = source.substring(with: urlRange)
                let candidate: URL
                if path.hasPrefix("/") { candidate = URL(fileURLWithPath: path.removingPercentEncoding ?? path) }
                else if let url = URL(string: path), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" { candidate = url }
                else { continue }
                let file = candidate.resolvingSymlinksInPath().standardizedFileURL
                guard allowed.contains(where: { file.path.hasPrefix($0) }),
                      let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), properties.isRegularFile == true,
                      let size = properties.fileSize, size <= 8_000_000,
                      let handle = try? FileHandle(forReadingFrom: file) else { continue }
                let bytes = try? handle.read(upToCount: 8_000_001); try? handle.close()
                guard let bytes, bytes.count <= 8_000_000, let png = normalizedPNG(bytes) else { continue }
                let hash = DeviceBlob.sha256Hex(png)
                let output = destination.appendingPathComponent("Response-" + hash + ".png")
                do {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try png.write(to: output, options: .atomic)
                    captured.append(Captured(range: NSRange(location: offset + match.range.location, length: match.range.length), caption: source.substring(with: match.range(at: 1)), file: output))
                } catch { continue }
            }
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
              width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 64_000_000 else { return nil }
        var dimension = min(2048, max(width, height))
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
    // Launch passes allowRemote false: saved history imports its local
    // captures without re-requesting every remote image on every launch.
    @discardableResult func importResponseImages(_ session: Session, allowRemote: Bool = true) -> Bool {
        let output = responseImageFolder(session)
        let attachmentRoot = folder.appendingPathComponent("Attachments").resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard output.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(attachmentRoot) else { return false }
        var roots = [output, URL(fileURLWithPath: "/tmp"), FileManager.default.temporaryDirectory]
        let working = URL(fileURLWithPath: NSString(string: session.entry.directory).expandingTildeInPath).standardizedFileURL
        if working.path != "/" && working.path != NSHomeDirectory() { roots.append(working) }
        var changed = false
        for index in session.messages.indices where session.messages[index].role == "assistant" && session.messages[index].text.contains("![") {
            let message = session.messages[index]
            if allowRemote {
                for ref in TranscriptStyle.imageReferences(message.text).prefix(max(0, 8 - message.images.count)) where ref.url.scheme?.lowercased() == "https" {
                let key = session.id.uuidString + "/" + message.id.uuidString + "/" + ref.url.absoluteString
                responseImageLoader.enqueue(key: key, url: ref.url) { [weak self, weak session] result in
                    guard let self, let session, self.sessions.contains(where: { $0 === session }),
                          let index = session.messages.firstIndex(where: { $0.id == message.id }) else { return }
                    let refs = TranscriptStyle.imageReferences(session.messages[index].text).filter { $0.url == ref.url }
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
                        // A dead image reads as its caption plus an X, never
                        // a hanging blank or a re-clickable trap.
                        let failed = NSMutableString(string: session.messages[index].text)
                        for item in refs.reversed() { failed.replaceCharacters(in: item.range, with: item.caption + " ❌") }
                        session.messages[index].text = failed as String
                        session.messages.append(Message(role: "notice", text: ResponseImages.unreachableNotice(url: ref.url)))
                    }
                    self.saveSoon()
                }
            }
            }
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
        check(fallback.attribute(.link, at: 0, effectiveRange: nil) as? URL == remoteURL && fallback.string.contains("Grasshopper"), "Unloaded response image keeps a clickable caption on Mac")
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
        store.responseImageLoader.configuration = config; store.responseImageLoader.validate = loader.validate
        let remote = store.create(Entry(name: "Remote image", command: "unused", directory: allowed.path, engine: "claude"))
        remote.messages = [Message(role: "assistant", text: "![Grasshopper](" + remoteURL.absoluteString + ")")]
        store.importResponseImages(remote)
        let deadline = Date().addingTimeInterval(5)
        while remote.messages[0].images.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(remote.messages[0].images.count == 1 && remote.messages[0].text == "Grasshopper", "Home promotes HTTPS replies into transcript attachments for remote clients")
        store.save()
        check(Store(folder: store.folder).sessions.first(where: { $0.id == remote.id })?.messages[0].images == remote.messages[0].images, "Downloaded reply images survive archive restore")
        let localOnly = store.create(Entry(name: "Local only", command: "unused", directory: allowed.path, engine: "codex"))
        ResponseImageFixture.lastRequestURL = nil
        localOnly.messages = [Message(role: "assistant", text: "Photo\n![Grasshopper](" + input.absoluteString + ")")]
        check(store.importResponseImages(localOnly, allowRemote: false) && localOnly.messages[0].images.count == 1 && !localOnly.messages[0].text.contains("![") && ResponseImageFixture.lastRequestURL == nil, "Launch imports local captures without remote requests")
        let broken = store.create(Entry(name: "Broken image", command: "unused", directory: allowed.path, engine: "claude"))
        broken.messages = [Message(role: "assistant", text: "![Nope](https://images.example.invalid/missing)")]
        store.importResponseImages(broken)
        let brokenDeadline = Date().addingTimeInterval(5)
        while broken.messages[0].text.contains("![") && Date() < brokenDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(broken.messages[0].text == "Nope ❌" && broken.messages.last?.text.hasPrefix("Image could not be loaded from images.example.invalid") == true, "A dead image reads as its caption plus an X with a host-first notice")

    } catch { check(false, "Response image fixture: " + error.localizedDescription) }
}

// Two concurrent downloads, no cookies, credentials or persistent web cache.
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
