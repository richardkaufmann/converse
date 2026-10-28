import AppKit
import CryptoKit
import ImageIO

// Only explicit Markdown image references become attachments. Never fetch
// network URLs or let a file symlink escape the permitted output directories.
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
    private static func normalizedPNG(_ bytes: Data) -> Data? {
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
        let store = Store(folder: root.appendingPathComponent("store"))
        let session = store.create(Entry(name: "Fixture", command: "unused", directory: allowed.path, engine: "codex"))
        session.messages = [Message(role: "assistant", text: source)]
        check(store.importResponseImages(session) && session.messages[0].images.count == 1 && !session.messages[0].text.contains("!["), "Returned image is promoted into the session transcript attachment list")
        store.save()
        let restored = Store(folder: store.folder)
        check(restored.sessions.first?.messages.first?.images == session.messages[0].images && !restored.importResponseImages(restored.sessions[0]), "Imported response image survives restart without duplicate attachments")
    } catch { check(false, "Response image fixture: " + error.localizedDescription) }
}
