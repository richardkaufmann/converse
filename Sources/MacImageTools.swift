import AppKit
import SwiftUI

@MainActor final class PhotoImageShare: NSObject, NSSharingServiceDelegate, @preconcurrency NSSharingServicePickerDelegate {
    private static var pending: [UUID: PhotoImageShare] = [:]
    private let id = UUID()
    private var service: NSSharingService?
    private var file: URL?
    private var picker: NSSharingServicePicker?
    static func showPicker(_ image: NSImage, from view: NSView) {
        let owner = PhotoImageShare()
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
    static func save(_ image: NSImage) {
        let owner = PhotoImageShare()
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
    private func finish(error: Error?) {
        let alert = NSAlert()
        let photos = picker == nil || service?.title == NSSharingService(named: .addToIPhoto)?.title
        alert.messageText = error == nil ? (photos ? "Sent to Photos" : "Image shared") : "Could not share image"
        alert.informativeText = error?.localizedDescription ?? (photos ? "Photos accepted the image on this Mac. It will appear on your other devices after iCloud Photos syncs." : "The sharing service accepted the image.")
        NSLog("Converse Photos share %@: %@", id.uuidString, error?.localizedDescription ?? "accepted")
        alert.runModal()
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
    @State private var point: CGPoint?
    @State private var notes = ""
    @State private var described = false
    @State private var regions: [DeviceImageRegion] = []
    @State private var chosen = 0
    @State private var busy = false
    @State private var status = ""
    private var bitmap: NSBitmapImageRep { NSBitmapImageRep(data: data)! }
    private var region: DeviceImageRegion? { regions.indices.contains(chosen) ? regions[chosen] : nil }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Use Meta image tools with any session model. Processing uses the Meta API key saved on this Mac. Review results before adding them to your draft. The original image stays unchanged.")
                GeometryReader { space in
                    let ratio = min(space.size.width / CGFloat(bitmap.pixelsWide), space.size.height / CGFloat(bitmap.pixelsHigh))
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: NSImage(data: data)!).resizable().frame(width: CGFloat(bitmap.pixelsWide) * ratio, height: CGFloat(bitmap.pixelsHigh) * ratio)
                        if let box = region {
                            Rectangle().stroke(.orange, lineWidth: 3).background(.orange.opacity(0.15)).frame(width: CGFloat(box.width) * ratio, height: CGFloat(box.height) * ratio).offset(x: CGFloat(box.x) * ratio, y: CGFloat(box.y) * ratio).allowsHitTesting(false)
                        }
                        if let point {
                            Circle().fill(.orange).overlay(Circle().stroke(.white, lineWidth: 2)).frame(width: 12, height: 12).offset(x: point.x * ratio - 6, y: point.y * ratio - 6).allowsHitTesting(false)
                        }
                    }.contentShape(Rectangle()).onTapGesture { location in
                        guard !busy else { return }
                        point = CGPoint(x: max(0, min(CGFloat(bitmap.pixelsWide - 1), location.x / ratio)), y: max(0, min(CGFloat(bitmap.pixelsHigh - 1), location.y / ratio)))
                        regions = []; chosen = 0
                    }
                }.frame(height: 300)
                Text("Click an object, then Find region. SAM currently offers a rectangular crop.").font(.caption)
                HStack {
                    Button("Describe image · Spark") { run("describe") }
                    Button("Find region · SAM") { run("focus") }.disabled(point == nil)
                }.disabled(busy)
                if busy { ProgressView("Processing…") }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
                if described {
                    TextEditor(text: $notes).frame(minHeight: 120).border(.secondary.opacity(0.4))
                    Button("Add notes to draft") { apply { addNotes(notes) } }.disabled(busy || notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !regions.isEmpty {
                    if regions.count > 1 { Picker("Region", selection: $chosen) { ForEach(regions.indices, id: \.self) { Text("Region \($0 + 1)").tag($0) } } }
                    Button("Add focused crop to draft") {
                        guard let box = region, let cg = bitmap.cgImage?.cropping(to: CGRect(x: box.x, y: box.y, width: box.width, height: box.height)) else { return }
                        apply { addImage(NSImage(cgImage: cg, size: .zero)) }
                    }.disabled(busy)
                }
            }.padding()
        }.frame(minWidth: 400, minHeight: 480)
    }
    private func apply(_ action: () -> Void) {
        guard canApply() else { status = "This session is no longer editable here. Return to its pane before adding the result."; return }
        action(); status = "Added to the draft. Nothing was sent."
    }
    private func run(_ operation: String) {
        guard !busy else { return }
        busy = true; status = ""
        let request = DeviceImageAssistRequest(hash: DeviceBlob.sha256Hex(data), operation: operation, epoch: 0, x: point.map { Int($0.x) }, y: point.map { Int($0.y) })
        Task { @MainActor in
            defer { busy = false }
            do {
                guard let key = try AgentSecrets.read("meta"), !key.isEmpty else { throw ImageAssistError.invalid("Add a Meta API key in Agent Setup on this Mac first.") }
                let result = try await AgentAPI().assistImage(data, request: request, key: key)
                if let text = result.notes { notes = text; described = true }
                regions = result.regions; chosen = 0
                status = "Review the result before adding it."
            } catch { status = "Image processing failed: " + error.localizedDescription + " No automatic retry was made." }
        }
    }
}
