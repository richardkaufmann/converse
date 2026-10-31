import SwiftUI
import UIKit

struct PadImageTools: View {
    let id: String
    @ObservedObject var model: PadModel
    @ObservedObject private var service: DeviceSyncService
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    @State private var epoch: UInt64?
    @State private var point: CGPoint?
    @State private var notes = ""
    @State private var described = false
    @State private var regions: [DeviceImageRegion] = []
    @State private var selectedRegion = 0
    @State private var busy = false
    @State private var status = ""
    @State private var lastRequest: DeviceImageAssistRequest?
    @State private var operationID = UUID()
    @State private var uncertain = false
    let initialHash: String?
    init(id: String, model: PadModel, initialHash: String? = nil) { self.id = id; self.model = model; self.service = model.service; self.initialHash = initialHash }
    var image: UIImage? { service.blobCache[selected].flatMap { UIImage(contentsOfFile: $0.path) } }
    var valid: Bool { model.canApplyImageResult(id, hash: selected, epoch: epoch) }
    var region: DeviceImageRegion? { regions.indices.contains(selectedRegion) ? regions[selectedRegion] : nil }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Use Meta image tools with any session model. Images are sent to Meta through the Mac home using its saved API key. Review the result before adding it; your original stays attached.").font(.callout)
                    if model.draft(id).hashes.count > 1 {
                        Picker("Attachment", selection: $selected) {
                            ForEach(Array(model.draft(id).hashes.enumerated()), id: \.element) { index, hash in Text("Image \(index + 1)").tag(hash) }
                        }.disabled(busy)
                    }
                    if let image, let cg = image.cgImage {
                        GeometryReader { bounds in
                            let ratio = min(bounds.size.width / CGFloat(cg.width), bounds.size.height / CGFloat(cg.height))
                            ZStack(alignment: .topLeading) {
                                Image(uiImage: image).resizable().frame(width: CGFloat(cg.width) * ratio, height: CGFloat(cg.height) * ratio)
                                if let box = region {
                                    Rectangle().stroke(.orange, lineWidth: 3).background(.orange.opacity(0.15))
                                        .frame(width: CGFloat(box.width) * ratio, height: CGFloat(box.height) * ratio)
                                        .offset(x: CGFloat(box.x) * ratio, y: CGFloat(box.y) * ratio).allowsHitTesting(false)
                                }
                                if let point {
                                    Circle().fill(.orange).overlay(Circle().stroke(.white, lineWidth: 2)).frame(width: 14, height: 14)
                                        .offset(x: point.x * ratio - 7, y: point.y * ratio - 7).allowsHitTesting(false)
                                }
                            }.contentShape(Rectangle()).onTapGesture { location in
                                guard !busy else { return }
                                point = CGPoint(x: min(CGFloat(cg.width - 1), max(0, location.x / ratio)), y: min(CGFloat(cg.height - 1), max(0, location.y / ratio)))
                                regions = []; uncertain = false; status = ""
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }.frame(height: 300)
                        Text("Tap the object you want to focus on, then choose Find region. SAM returns a rectangular region for this first version.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Describe image") { run("describe") }.buttonStyle(.borderedProminent)
                        Button("Find region · SAM") { run("focus") }.buttonStyle(.bordered).disabled(point == nil)
                    }.disabled(busy || !valid || service.blobReady[selected] != true)
                    if busy { ProgressView("Processing on home…") }
                    if !status.isEmpty { Text(status).font(.callout).foregroundStyle(uncertain ? .orange : .secondary).textSelection(.enabled) }
                    if uncertain { Button("Check result (does not run again)") { run(lastRequest?.operation ?? "describe", retry: true) }.disabled(busy || !valid) }
                    if described {
                        Text("Image notes · Muse Spark").font(.headline)
                        TextEditor(text: $notes).frame(minHeight: 160).overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.4)))
                        Button("Add notes to draft") {
                            guard valid else { return }
                            if model.addImageNotes(id, hash: selected, epoch: epoch, notes: notes) { dismiss() }
                        }.buttonStyle(.borderedProminent).disabled(!valid || busy || notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !regions.isEmpty {
                        if regions.count > 1 { Picker("Region", selection: $selectedRegion) { ForEach(regions.indices, id: \.self) { Text("Region \($0 + 1)").tag($0) } } }
                        Button("Add focused crop to draft") { addCrop() }.buttonStyle(.borderedProminent).disabled(!valid || busy)
                    }
                    if !valid { Text("The attachment, pending send or session ownership changed. Close this panel and reopen Image tools for the current draft.").foregroundStyle(.orange) }
                }.padding()
            }.navigationTitle("Image tools")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .onAppear { if selected.isEmpty { selected = initialHash ?? model.draft(id).hashes.first ?? ""; epoch = service.remoteLeases[id] } }
                .onChange(of: selected) { _, _ in point = nil; notes = ""; described = false; regions = []; status = ""; uncertain = false }
        }
    }
    private func run(_ operation: String, retry: Bool = false) {
        guard valid, let epoch, let global = DeviceGlobalID(id) else { return }
        let request: DeviceImageAssistRequest
        if retry, let saved = lastRequest { request = saved }
        else {
            request = DeviceImageAssistRequest(hash: selected, operation: operation, epoch: epoch, x: point.map { Int($0.x) }, y: point.map { Int($0.y) })
            operationID = UUID(); lastRequest = request; notes = ""; described = false; regions = []; selectedRegion = 0
        }
        busy = true; status = ""; uncertain = false; model.flush(id)
        Task { @MainActor in
            let response = await service.requestParticipant(home: global.home, action: "image.assist", target: id, imageAssist: request, id: operationID)
            busy = false; status = response.detail; uncertain = ["pending", "uncertain"].contains(response.outcome)
            guard valid, selected == request.hash else { status = "Result not applied: the draft or session changed."; return }
            if response.outcome == "completed", let result = response.imageAssist { notes = result.notes ?? ""; described = result.notes != nil; regions = result.regions; selectedRegion = 0 }
        }
    }
    private func addCrop() {
        guard valid, let box = region, let cg = image?.cgImage, cg.width == box.imageWidth, cg.height == box.imageHeight,
              box.x >= 0, box.y >= 0, box.width > 0, box.height > 0, box.x <= cg.width - box.width, box.y <= cg.height - box.height,
              let crop = cg.cropping(to: CGRect(x: box.x, y: box.y, width: box.width, height: box.height)), let png = UIImage(cgImage: crop).pngData() else { status = "This crop could not be created."; return }
        guard model.attach(id, data: png) != nil else { status = model.error; return }
        let text = model.draft(id).text
        model.edit(id, text: text + (text.isEmpty ? "" : "\n\n") + "[Focus: the additional image is a SAM-selected crop of the original attachment.]")
        dismiss()
    }
}
