import SwiftUI
import UIKit

struct PadImageTools: View {
    let id: String
    @ObservedObject var model: PadModel
    @ObservedObject private var service: DeviceSyncService
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    @State private var epoch: UInt64?
    @State private var concept = ""
    @State private var notes = ""
    @State private var described = false
    @State private var segments: [ImageSegment] = []
    @State private var chosen = Set<Int>()
    @State private var busy = false
    @State private var status = ""
    @State private var lastRequest: DeviceImageAssistRequest?
    @State private var operationID = UUID()
    @State private var uncertain = false
    let initialHash: String?
    init(id: String, model: PadModel, initialHash: String? = nil) { self.id = id; self.model = model; self.service = model.service; self.initialHash = initialHash }
    var image: UIImage? { service.blobCache[selected].flatMap { UIImage(contentsOfFile: $0.path) } }
    var valid: Bool { model.canApplyImageResult(id, hash: selected, epoch: epoch) }
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
                        SegmentPicker(image: cg, segments: segments, selected: $chosen).disabled(busy)
                    }
                    TextField("Discover objects — or describe what to find", text: $concept).textFieldStyle(.roundedBorder).disabled(busy)
                    Text("Leave blank to discover up to six object types with Spark, then segment them with SAM. A description searches SAM directly.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Find Segments") { run("segments") }.buttonStyle(.borderedProminent)
                        Button("Describe image") { run("describe") }.buttonStyle(.bordered)
                    }.disabled(busy || uncertain || !valid || service.blobReady[selected] != true)
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
                    if !segments.isEmpty {
                        HStack {
                            Button("Add selected to draft") { export(copy: false) }.buttonStyle(.borderedProminent)
                            Button("Copy selected") { export(copy: true) }.buttonStyle(.bordered)
                        }.disabled(!valid || busy || chosen.isEmpty)
                        Text("Add creates separate transparent PNG cutouts. Copy keeps the original canvas and positions, with everything else transparent.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !valid { Text("The attachment, pending send or session ownership changed. Close this panel and reopen Image tools for the current draft.").foregroundStyle(.orange) }
                }.padding()
            }.navigationTitle("Image tools")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .onAppear { if selected.isEmpty { selected = initialHash ?? model.draft(id).hashes.first ?? ""; epoch = service.remoteLeases[id] } }
                .onChange(of: selected) { _, _ in concept = ""; notes = ""; described = false; segments = []; chosen = []; status = ""; uncertain = false }
        }
    }
    private func run(_ operation: String, retry: Bool = false) {
        guard valid, let epoch, let global = DeviceGlobalID(id) else { return }
        let request: DeviceImageAssistRequest
        if retry, let saved = lastRequest { request = saved }
        else {
            request = DeviceImageAssistRequest(hash: selected, operation: operation, epoch: epoch, concept: concept)
            operationID = UUID(); lastRequest = request; notes = ""; described = false; segments = []; chosen = []
        }
        busy = true; status = ""; uncertain = false; model.flush(id)
        Task { @MainActor in
            let response = await service.requestParticipant(home: global.home, action: "image.assist", target: id, imageAssist: request, id: operationID)
            defer { busy = false }; status = response.detail; uncertain = ["pending", "uncertain"].contains(response.outcome)
            guard valid, selected == request.hash else { status = "Result not applied: the draft or session changed."; return }
            if response.outcome == "completed", let result = response.imageAssist {
                notes = result.notes ?? ""; described = result.notes != nil
                do {
                    let wire = result.segments ?? []
                    let prepared = try await Task.detached { try ImageSegment.prepare(wire) }.value
                    guard valid, selected == request.hash else { status = "Result not applied: the draft or session changed."; return }
                    segments = prepared; chosen = []; status = result.summary ?? response.detail
                } catch { status = error.localizedDescription }
            }
        }
    }
    private func export(copy: Bool) {
        guard valid, let cg = image?.cgImage else { return }
        do {
            let items = chosen.sorted().compactMap { segments.indices.contains($0) ? segments[$0] : nil }
            if copy {
                let png = try ImageSegment.png(ImageSegment.export(cg, segments: items, crop: false))
                UIPasteboard.general.setData(png, forPasteboardType: "public.png")
                status = "Copied a transparent PNG in the original positions."
            } else {
                let images = try items.map { try ImageSegment.png(ImageSegment.export(cg, segments: [$0], crop: true)) }
                var count = 0
                for png in images {
                    guard model.attach(id, data: png) != nil else { status = "Added \(count) cutouts. " + model.error; return }; count += 1
                }
                status = "Added \(count) transparent cutouts to the draft. Nothing was sent."
            }
        } catch { status = error.localizedDescription }
    }
}
