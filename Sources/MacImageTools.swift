import AppKit
import SwiftUI

@MainActor final class PhotoImageShare: NSObject, NSSharingServiceDelegate, @preconcurrency NSSharingServicePickerDelegate {
    private static var pending: [UUID: PhotoImageShare] = [:]
    private let id = UUID()
    private var service: NSSharingService?
    private var file: URL?
    private var picker: NSSharingServicePicker?
    private var notice: (String) -> Void = { _ in }
    static func showPicker(_ image: NSImage, from view: NSView, notice: @escaping (String) -> Void) {
        let owner = PhotoImageShare()
        owner.notice = notice
        do {
            let file = try owner.prepare(image)
            let picker = NSSharingServicePicker(items: [file]); owner.picker = picker; picker.delegate = owner
            pending[owner.id] = owner
            picker.show(relativeTo: view.visibleRect, of: view, preferredEdge: .minY)
        } catch { owner.finish(error: error) }
    }
    private func prepare(_ image: NSImage) throws -> URL {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { throw ImageAssistError.invalid("Could not encode the image.") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Converse-\(id).png")
        try png.write(to: file, options: .atomic); self.file = file
        return file
    }
    static func save(_ image: NSImage, notice: @escaping (String) -> Void) {
        let owner = PhotoImageShare()
        owner.notice = notice
        do {
            let file = try owner.prepare(image)
            guard let service = NSSharingService(named: .addToIPhoto), service.canPerform(withItems: [file]) else { throw ImageAssistError.invalid("The Photos sharing service is unavailable on this Mac.") }
            owner.service = service; service.delegate = owner; pending[owner.id] = owner
            service.perform(withItems: [file])
        } catch { owner.finish(error: error) }
    }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        service = sharingService; return self
    }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service == nil { Self.pending.removeValue(forKey: id) }
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish(error: nil) }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { finish(error: error) }
    static func noticeText(photos: Bool, serviceTitle: String?, errorMessage: String?) -> String {
        if let errorMessage { return "Couldn't share image: " + errorMessage }
        if photos { return "Photo sent to Photos." }
        if let serviceTitle, !serviceTitle.isEmpty { return "Image shared via " + serviceTitle + "." }
        return "Image shared."
    }
    private func finish(error: Error?) {
        let photos = picker == nil || service?.title == NSSharingService(named: .addToIPhoto)?.title
        let text = Self.noticeText(photos: photos, serviceTitle: service?.title, errorMessage: error?.localizedDescription)
        NSLog("Converse Photos share %@: %@", id.uuidString, error?.localizedDescription ?? "accepted")
        notice(text)
        // Keep a successful share's file available while Photos finishes reading.
        // macOS manages the temporary directory; no user attachment is removed.
        Self.pending.removeValue(forKey: id)
    }
}

// A snapshot of the clicked image: never edit the transcript attachment in place.
enum MacImageSource {
    static func normalized(_ image: NSImage) throws -> Data {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ImageAssistError.invalid("Could not read this image.") }
        let ratio = min(1, 2048 / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * ratio)), h = max(1, Int(Double(cg.height) * ratio))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageAssistError.invalid("Could not prepare this image.") }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rendered = context.makeImage(), let data = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]), data.count <= 8 * 1024 * 1024 else { throw ImageAssistError.invalid("This image is too large for image tools.") }
        return data
    }
}

@MainActor func photoShareSelfTests(_ check: (Bool, String) -> Void) {
    check(PhotoImageShare.noticeText(photos: true, serviceTitle: nil, errorMessage: nil) == "Photo sent to Photos.", "Photos success reads as a short sent row")
    check(PhotoImageShare.noticeText(photos: false, serviceTitle: "Mail", errorMessage: nil) == "Image shared via Mail.", "Other services name their destination")
    check(PhotoImageShare.noticeText(photos: false, serviceTitle: nil, errorMessage: nil) == "Image shared.", "A missing service name still confirms the share")
    check(PhotoImageShare.noticeText(photos: true, serviceTitle: nil, errorMessage: "No photos here") == "Couldn't share image: No photos here", "Share failures keep their reason in the row instead of a modal")
}

@MainActor final class MacImageToolsWindow: NSObject, NSWindowDelegate {
    private static var open: [UUID: MacImageToolsWindow] = [:]
    private let id = UUID()
    private var window: NSWindow!
    static func show(image: NSImage, canApply: @escaping () -> Bool, addNotes: @escaping (String) -> Void, addImage: @escaping (NSImage) -> Void) {
        do {
            let data = try MacImageSource.normalized(image)
            let owner = MacImageToolsWindow()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            owner.window = window; window.delegate = owner; window.isReleasedWhenClosed = false
            window.title = "Image tools"
            window.contentView = NSHostingView(rootView: MacImageTools(data: data, canApply: canApply, addNotes: addNotes, addImage: addImage))
            open[owner.id] = owner; window.center(); window.makeKeyAndOrderFront(nil)
        } catch { let alert = NSAlert(); alert.messageText = "Image tools"; alert.informativeText = error.localizedDescription; alert.runModal() }
    }
    func windowWillClose(_ notification: Notification) { Self.open.removeValue(forKey: id) }
}

struct MacImageTools: View {
    let data: Data
    let canApply: () -> Bool
    let addNotes: (String) -> Void
    let addImage: (NSImage) -> Void
    @State private var concept = ""
    @State private var notes = ""
    @State private var described = false
    @State private var segments: [ImageSegment] = []
    @State private var selected = Set<Int>()
    @State private var busy = false
    @State private var status = ""
    private var cgImage: CGImage { NSBitmapImageRep(data: data)!.cgImage! }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Meta image tools work with any session model. Find Segments sends this image to Meta using this Mac's saved API key. Review before adding to your draft.")
                SegmentPicker(image: cgImage, segments: segments, selected: $selected).disabled(busy)
                TextField("Discover objects — or describe what to find", text: $concept).textFieldStyle(.roundedBorder).disabled(busy)
                Text("Leave blank to discover up to six object types with Spark, then segment them with SAM. A description searches SAM directly.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Find Segments") { run("segments") }.buttonStyle(.borderedProminent)
                    Button("Describe image · Spark") { run("describe") }
                }.disabled(busy)
                if busy { ProgressView("Finding objects can take a minute…") }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
                if !segments.isEmpty {
                    HStack {
                        Button("Add selected to draft") { export(copy: false) }
                        Button("Copy selected") { export(copy: true) }
                    }.disabled(busy || selected.isEmpty)
                    Text("Add creates separate transparent PNG cutouts. Copy preserves the original canvas and positions with everything else transparent.").font(.caption).foregroundStyle(.secondary)
                }
                if described {
                    TextEditor(text: $notes).frame(minHeight: 120).border(.secondary.opacity(0.4))
                    Button("Add notes to draft") { apply { addNotes(notes) } }.disabled(busy || notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding()
        }.frame(minWidth: 400, minHeight: 480)
    }
    private func apply(_ action: () -> Void) {
        guard canApply() else { status = "This session is no longer editable here. Return to its pane before adding the result."; return }
        action(); status = "Added to the draft. Nothing was sent."
    }
    private func export(copy: Bool) {
        do {
            let chosen = selected.sorted().compactMap { segments.indices.contains($0) ? segments[$0] : nil }
            if copy {
                let png = try ImageSegment.png(ImageSegment.export(cgImage, segments: chosen, crop: false))
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setData(png, forType: .png) else { throw ImageAssistError.invalid("Could not copy the PNG.") }
                status = "Copied a transparent PNG in the original positions."
            } else {
                let images = try chosen.map { NSImage(cgImage: try ImageSegment.export(cgImage, segments: [$0], crop: true), size: .zero) }
                apply { images.forEach(addImage) }
            }
        } catch { status = error.localizedDescription }
    }
    private func run(_ operation: String) {
        guard !busy else { return }
        busy = true; status = ""
        let request = DeviceImageAssistRequest(hash: DeviceBlob.sha256Hex(data), operation: operation, epoch: 0, concept: concept)
        Task { @MainActor in
            defer { busy = false }
            do {
                guard let key = try AgentSecrets.read("meta"), !key.isEmpty else { throw ImageAssistError.invalid("Add a Meta API key in Agent Setup on this Mac first.") }
                let result = try await AgentAPI().assistImage(data, request: request, key: key)
                if let text = result.notes { notes = text; described = true }
                if let wire = result.segments {
                    segments = try await Task.detached { try ImageSegment.prepare(wire) }.value; selected = []
                }
                status = result.summary ?? "Review the result before adding it."
            } catch { status = "Image processing failed: " + error.localizedDescription + " No automatic retry was made." }
        }
    }
}
