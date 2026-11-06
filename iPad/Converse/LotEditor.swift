import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct PadLotPane: View {
    let id: String
    let pane: Int
    @ObservedObject var model: PadModel
    var body: some View {
        if model.service.editableLotsEnabled { EditableLotPane(id: id, pane: pane, model: model) }
        else { LegacyPadLotPane(id: id, pane: pane, model: model) }
    }
}

struct EditableLotPane: View {
    let id: String
    let pane: Int
    @ObservedObject var model: PadModel
    @ObservedObject private var service: DeviceSyncService
    @State private var selected = Set<UUID>()
    @State private var selecting = false
    @State private var selectionAnchor: UUID?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var dragStart: UUID?
    @State private var dragBase = Set<UUID>()
    @State private var firstVisibleRow: UUID?
    @State private var commentsFor: LotMenuSelection?
    @State private var moving: LotMenuSelection?
    @State private var photo: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var imageRow: UUID?
    @State private var pendingImage: (UUID, String, UInt64, UInt64)?
    @State private var pendingPaste: (LotOperation, [String], UInt64, UInt64)?
    @State private var undo: [[ParkingLotRow]] = []
    @State private var redo: [[ParkingLotRow]] = []
    @State private var error = ""
    @State private var fullImage: LotImageItem?
    @State private var exporting = false
    @FocusState private var focus: UUID?
    init(id: String, pane: Int, model: PadModel, initialSelection: Set<UUID> = []) {
        self.id = id; self.pane = pane; self.model = model; service = model.service
        _selected = State(initialValue: initialSelection); _selecting = State(initialValue: !initialSelection.isEmpty)
    }
    private var editor: LotEditQueue? { service.lotEditors[id] }
    private var rows: [ParkingLotRow] { editor?.projected.rows ?? [] }
    private var canEdit: Bool { service.lotCanEdit(id) }
    private var hierarchy: [UUID: ParkingLotTree.Node] { (try? ParkingLotTree.nodes(rows)) ?? [:] }
    private var labels: [UUID: String] {
        let nodes = hierarchy
        var counts: [UUID?: Int] = [:], result: [UUID: String] = [:]
        for row in rows where !row.heading {
            let parent = nodes[row.id]?.parentID
            counts[parent, default: 0] += 1
            result[row.id] = ParkingLotTree.label(counts[parent]!, depth: nodes[row.id]?.depth ?? 1) + "."
        }
        return result
    }
    private var collapsed: Set<UUID> { model.lotCollapsed[id] ?? [] }
    private var visibleRows: [ParkingLotRow] {
        rows.filter { row in
            var parent = hierarchy[row.id]?.parentID
            while let ancestor = parent { if collapsed.contains(ancestor) { return false }; parent = hierarchy[ancestor]?.parentID }
            return true
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            status
            if editor != nil {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleRows) { row in rowView(row) }
                        if rows.isEmpty { Text("Add a heading or item to start this Parking Lot.").foregroundStyle(.secondary).padding() }
                    }.scrollTargetLayout().padding(.horizontal, 10).padding(.vertical, 10)
                    .coordinateSpace(name: "lot-rows")
                    .onPreferenceChange(LotRowFrames.self) { rowFrames = $0 }
                    .gesture(DragGesture(minimumDistance: 10, coordinateSpace: .named("lot-rows"))
                        .onChanged { value in
                            guard selecting, canEdit else { return }
                            if dragStart == nil { dragStart = rowAt(value.startLocation); dragBase = selected }
                            if let first = dragStart, let last = rowAt(value.location) {
                                selected = dragBase.union(LotMenuSelection.range(from: first, to: last, visible: visibleRows.map(\.id)))
                            }
                        }.onEnded { _ in dragStart = nil }, including: selecting ? .all : .subviews)
                }.scrollPosition(id: $firstVisibleRow, anchor: .top).accessibilityIdentifier("lot-editor")
                Divider()
                toolbar
            } else {
                ContentUnavailableView("Parking Lot", systemImage: "parkingsign.square", description: Text(service.supportsLotEditing(id) ? "Take this lot to edit it here." : "Connect to an updated home to edit this lot."))
                Button("Take here") { service.acquireRemote(globalID: id) }.buttonStyle(.borderedProminent).padding()
            }
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(item: $commentsFor) { row in commentSheet(row) }
        .sheet(item: $moving) { selection in moveSheet(selection) }
        .sheet(isPresented: Binding(get: { service.lotProposals[id] != nil }, set: { if !$0 { service.decideLotProposal(id, approved: false) } })) {
            proposalSheet.interactiveDismissDisabled()
        }
        .fullScreenCover(item: $fullImage) { LotImageViewer(item: $0) }
        .sheet(isPresented: $exporting) {
            if let saved = editor?.saved { MobileLotExportSheet(snapshot: saved, images: service.blobCache, devices: service.scrubDevices) }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, choice in
            guard let choice, let row = imageRow, let authority = editor?.saved else { return }
            Task { @MainActor in
                do { if let data = try await choice.loadTransferable(type: Data.self) {
                    guard editor?.saved.leaseEpoch == authority.leaseEpoch, editor?.saved.homeBoot == authority.homeBoot else { throw ParkingLotError.message("The lot moved while the image was opening. Attach it again after taking the lot.") }
                    try uploadImage(data, row: row)
                } }
                catch { self.error = error.localizedDescription }
                photo = nil
            }
        }
        .onReceive(service.$lotBlobReady) { readyByLot in
            let ready = readyByLot[id] ?? []
            if let (row, hash, epoch, boot) = pendingImage, ready.contains(hash) {
                pendingImage = nil
                if canEdit, editor?.saved.leaseEpoch == epoch, editor?.saved.homeBoot == boot { perform(LotOperation(kind: .addImage, rowID: row, imageHash: hash)) }
            }
            if let (operation, hashes, epoch, boot) = pendingPaste, hashes.allSatisfy({ ready.contains($0) }) {
                pendingPaste = nil
                if canEdit, editor?.saved.leaseEpoch == epoch, editor?.saved.homeBoot == boot { perform(operation) }
            }
        }
        .onChange(of: service.lotProposals[id]?.id) { _, value in if value != nil { undo = []; redo = []; focus = nil } }
        .onChange(of: editor?.saved.leaseEpoch) { _, _ in undo = []; redo = []; selected = []; focus = nil }
        .onChange(of: focus) { _, value in
            if value != nil { model.cursorPane = pane } else { model.endedEditing(pane: pane) }
        }
        .onDisappear { model.endedEditing(pane: pane) }
        .onChange(of: visibleRows.map(\.id)) { _, ids in selected.formIntersection(ids) }
        .onChange(of: canEdit) { _, editable in if !editable {
            focus = nil
            if pendingImage != nil || pendingPaste != nil { error = "The lot moved or paused before the attachment finished. Attach or paste it again when editing resumes." }
            pendingImage = nil; pendingPaste = nil
        } }
    }
    private var header: some View {
        HStack {
            Text(String(pane + 1)).font(.caption.bold()).padding(6).background(.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            Text(editor?.saved.name ?? service.remoteRow(globalID: id)?.title ?? "Parking Lot").font(.headline).lineLimit(1)
            Spacer()
            if !selected.isEmpty {
                Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                Menu { entryActions(selected) } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .accessibilityLabel("Actions for selected entries").disabled(!canEdit)
            }
            Button(selecting ? "Cancel" : "Select") {
                focus = nil; selecting.toggle(); selected = []; selectionAnchor = nil
            }.disabled(!canEdit)
            Button("P") { focus = nil; model.park(id) }.frame(minWidth: 44, minHeight: 44).accessibilityLabel("Save and park this lot")
        }.padding(.horizontal, 10)
    }
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let editor {
                if let reason = editor.frozenReason {
                    Label(reason, systemImage: "wifi.slash").foregroundStyle(.orange)
                    HStack {
                        Button("Copy unconfirmed text") { UIPasteboard.general.string = Self.markdown(editor.projected.rows) }
                        Button("Take again") { service.releaseRemote(globalID: id); service.acquireRemote(globalID: id) }
                    }
                } else if editor.draining { Label("Finishing saves…", systemImage: "pause.circle") }
                else if editor.unconfirmedCount > 0 { Text("Saving \(editor.unconfirmedCount) change(s)… · home saved revision \(editor.saved.document.revision)") }
                else { Label("Saved on home · revision \(editor.saved.document.revision)", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
            if let notice = service.lotNotices[id] { Text(notice).foregroundStyle(.orange) }
            if let recovery = service.lotRecovery[id] {
                Button("Copy previous unconfirmed changes") { UIPasteboard.general.string = Self.markdown(recovery.rows) }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 5)
    }
    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Menu {
                    Button("New heading") { insert(heading: true) }
                    Button("New item") { insert(heading: false) }
                    Button("Paste item") { paste() }
                } label: { Label("Add", systemImage: "plus") }
                Menu {
                    Button("Collapse All") {
                        model.lotCollapsed[id] = Set(rows.filter(\.heading).map(\.id)).union(hierarchy.values.compactMap(\.parentID))
                    }
                    Button("Expand All") { model.lotCollapsed[id] = [] }
                } label: { Label("Outline", systemImage: "list.bullet.indent") }
                Button { undoEdit() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(undo.isEmpty || editor?.unconfirmedCount != 0).accessibilityLabel("Undo lot edit").keyboardShortcut("z")
                Button { redoEdit() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(redo.isEmpty || editor?.unconfirmedCount != 0).accessibilityLabel("Redo lot edit").keyboardShortcut("z", modifiers: [.command, .shift])
                if let saved = editor?.saved {
                    Button { exporting = true } label: { Label("Export saved copy", systemImage: "square.and.arrow.up") }
                        .disabled(editor?.unconfirmedCount != 0)
                        .help("Export revision \(saved.document.revision), saved on home")
                }
            }.buttonStyle(.bordered).frame(minHeight: 44).padding(.horizontal, 10)
        }.disabled(!canEdit)
    }
    @ViewBuilder private func rowView(_ row: ParkingLotRow) -> some View {
        let depth = hierarchy[row.id]?.depth ?? 0
        let expandable = (ParkingLotTree.range(row.id, in: rows)?.count ?? 0) > 1
        HStack(alignment: .top, spacing: 5) {
            if expandable {
                Button { model.toggleLotHeading(id, heading: row.id) } label: {
                    Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down").frame(width: 30, height: 44)
                }.accessibilityLabel("Collapse or expand entry")
            } else { Color.clear.frame(width: 30, height: 1).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let label = labels[row.id] { Text(label).font(.system(size: model.textSize(pane))).monospacedDigit().foregroundStyle(.secondary) }
                if selecting {
                    Text(row.text.isEmpty ? (row.heading ? "Heading" : "Item") : row.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.system(size: model.textSize(pane), weight: row.heading ? .semibold : .regular))
                        .foregroundStyle(row.isDone ? Color.secondary : tagColor(row.tag, heading: row.heading))
                        .strikethrough(row.isDone)
                } else {
                    TextField(row.heading ? "Heading" : "Item", text: Binding(get: { rows.first(where: { $0.id == row.id })?.text ?? row.text }, set: { perform(LotOperation(kind: .setText, rowID: row.id, text: $0)) }), axis: .vertical)
                        .font(.system(size: model.textSize(pane), weight: row.heading ? .semibold : .regular))
                        .foregroundStyle(row.isDone ? Color.secondary : tagColor(row.tag, heading: row.heading))
                        .strikethrough(row.isDone).focused($focus, equals: row.id).disabled(!canEdit)
                        .accessibilityIdentifier("lot-text-" + row.id.uuidString)
                }
                }
                if !(row.images ?? []).isEmpty { LotThumbnailStrip(hashes: row.images ?? [], images: service.blobCache, open: { fullImage = $0 }) }
                if let notes = row.notes, !notes.isEmpty {
                    Button { commentsFor = LotMenuSelection(ids: [row.id]) } label: { Label(notes.count == 1 ? "1 comment" : "\(notes.count) comments", systemImage: "text.bubble") }.font(.caption).frame(minHeight: 44)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if selected.isEmpty {
                Menu { entryActions([row.id]) } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .accessibilityLabel("Actions for " + (row.text.isEmpty ? "entry" : row.text)).disabled(!canEdit)
            }
        }.padding(.leading, CGFloat(min(6, max(0, depth - 1))) * 12).padding(.top, row.heading ? 10 : 0)
        .padding(.vertical, 3)
        .background(selected.contains(row.id) ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .gesture(TapGesture().onEnded { if canEdit { toggleSelection(row.id) } }, including: selecting ? .all : .subviews)
        .contextMenu {
            if selecting, let anchor = selectionAnchor {
                Button("Select through this entry") {
                    selected = LotMenuSelection.range(from: anchor, to: row.id, visible: visibleRows.map(\.id))
                }
            }
            entryActions(selected.isEmpty ? [row.id] : selected)
        }
        .accessibilityAddTraits(selected.contains(row.id) ? .isSelected : [])
        .background(GeometryReader { geometry in Color.clear.preference(key: LotRowFrames.self, value: [row.id: geometry.frame(in: .named("lot-rows"))]) })
    }
    @ViewBuilder private func entryActions(_ ids: Set<UUID>) -> some View {
        let targets = rows.filter { ids.contains($0.id) }
        let single = targets.count == 1 ? targets.first : nil
        let allDone = targets.allSatisfy(\.isDone)
        if selected.isEmpty {
            Button("Select entry") { focus = nil; selecting = true; selected = ids; selectionAnchor = targets.first?.id }
        } else {
            Text("\(targets.count) selected")
            Button("Select all") { selected = Set(visibleRows.map(\.id)) }
            Button("Clear selection") { selected = []; selectionAnchor = nil }
        }
        Button(allDone ? "Mark not done" : "Mark done") {
            performBatch(targets.map { LotOperation(kind: .setDone, rowID: $0.id, done: !allDone) })
        }
        Menu("Color") {
            Button("None") { performBatch(targets.map { LotOperation(kind: .setTag, rowID: $0.id) }) }
            ForEach(ParkingLotTag.allCases, id: \.rawValue) { tag in
                Button(tag.rawValue.capitalized) { performBatch(targets.map { LotOperation(kind: .setTag, rowID: $0.id, tag: tag) }) }
            }
        }
        Button("Indent") { perform(LotOperation(kind: .indent, rowIDs: targets.map(\.id))) }.disabled(targets.contains(where: \.heading))
        Button("Outdent") { perform(LotOperation(kind: .outdent, rowIDs: targets.map(\.id))) }.disabled(targets.contains(where: \.heading))
        Button("Move…") { moving = LotMenuSelection(ids: ids) }
            .disabled(Set(targets.map(\.heading)).count > 1)
        Button("Add comment") { commentsFor = LotMenuSelection(ids: ids) }
        if let row = single {
            Button("Add image…") { imageRow = row.id; choosingPhoto = true }
            Button("Paste image") { if let png = UIPasteboard.general.image?.pngData() { do { try uploadImage(png, row: row.id) } catch { self.error = error.localizedDescription } } }
            ForEach(row.images ?? [], id: \.self) { hash in Button("Remove image " + String(hash.prefix(6)), role: .destructive) { perform(LotOperation(kind: .removeImage, rowID: row.id, imageHash: hash)) } }
            ForEach(Self.links(in: row.text), id: \.absoluteString) { url in Link("Open " + url.absoluteString, destination: url) }
        }
        Button("Copy with children") { copySelection(ids, cut: false) }
        Button("Cut with children") { copySelection(ids, cut: true) }
        Button("Delete with children", role: .destructive) { perform(LotOperation(kind: .deleteSelection, rowIDs: targets.map(\.id))) }
    }
    private func toggleSelection(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        selectionAnchor = id
    }
    private func rowAt(_ point: CGPoint) -> UUID? {
        rowFrames.first(where: { $0.value.minY <= point.y && point.y <= $0.value.maxY })?.key
    }
    private func performBatch(_ operations: [LotOperation]) {
        guard let document = editor?.projected, !operations.isEmpty else { return }
        do {
            let changed = try LotMenuSelection.applying(operations, to: document, author: service.identity?.deviceName ?? "Mobile")
            perform(LotOperation(kind: .replaceRows, rows: changed.rows))
        } catch { self.error = error.localizedDescription }
    }
    private func tagColor(_ tag: ParkingLotTag?, heading: Bool) -> Color {
        guard let tag else { return heading ? LotStyle.heading : .primary }
        return Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? tag.darkHex : tag.lightHex
            let value = UInt32(hex.dropFirst(), radix: 16)!
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    private func perform(_ operation: LotOperation, history: Bool = true) {
        do {
            let before = rows
            let coalescing = operation.kind == .setText && editor?.pending.last?.kind == .setText && editor?.pending.last?.rowID == operation.rowID
            try service.editLot(id, operation: operation)
            if history && !coalescing { undo.append(before); if undo.count > 100 { undo.removeFirst() }; redo = [] }
            error = ""
        } catch { self.error = error.localizedDescription }
    }
    private func insert(heading: Bool) {
        let parent = heading ? nil : (focus.flatMap { row in rows.first(where: { $0.id == row })?.heading == true ? row : hierarchy[row]?.parentID } ?? rows.last(where: \.heading)?.id)
        let row = ParkingLotRow(heading: heading, text: "", parentID: parent)
        perform(LotOperation(kind: .insert, row: row, parentID: parent)); focus = row.id
    }
    private func undoEdit() {
        guard editor?.unconfirmedCount == 0, let previous = undo.last else { return }; let current = rows
        do { try service.editLot(id, operation: LotOperation(kind: .replaceRows, rows: previous)); undo.removeLast(); redo.append(current) }
        catch { self.error = error.localizedDescription }
    }
    private func redoEdit() {
        guard editor?.unconfirmedCount == 0, let next = redo.last else { return }; let current = rows
        do { try service.editLot(id, operation: LotOperation(kind: .replaceRows, rows: next)); redo.removeLast(); undo.append(current) }
        catch { self.error = error.localizedDescription }
    }
    private func copySelection(_ ids: Set<UUID>, cut: Bool) {
        var indices = Set<Int>()
        for row in ids { if let range = ParkingLotTree.range(row, in: rows) { indices.formUnion(range) } }
        let copy = indices.sorted().map { rows[$0] }
        guard !copy.isEmpty else { return }
        if let data = try? LotEditing.encoded(copy) {
            UIPasteboard.general.setItems([["app.kaoslabs.converse.lot-rows": data, "public.utf8-plain-text": Self.markdown(copy)]])
        }
        if cut { perform(LotOperation(kind: .deleteSelection, rowIDs: Array(ids))); selected = [] }
    }
    private func paste() {
        guard canEdit, let authority = editor?.saved, pendingPaste == nil else { return }
        if let data = UIPasteboard.general.data(forPasteboardType: "app.kaoslabs.converse.lot-rows"), let original = try? JSONDecoder().decode([ParkingLotRow].self, from: data) {
            var ids: [UUID: UUID] = [:]; for row in original { ids[row.id] = UUID() }
            let parent = focus.flatMap { hierarchy[$0]?.parentID } ?? rows.last(where: \.heading)?.id
            let copy = original.map { row -> ParkingLotRow in
                var row = row; row.id = ids[row.id]!; row.parentID = row.heading ? nil : row.parentID.flatMap { ids[$0] } ?? parent
                row.notes = row.notes?.map { ParkingLotNote(author: $0.author, text: $0.text) }
                return row
            }
            let operation = LotOperation(kind: .insertSubtree, parentID: parent, rows: copy)
            let hashes = Array(Set(copy.flatMap { $0.images ?? [] }))
            do {
                for hash in hashes {
                    guard let url = service.blobCache[hash], let bytes = try? Data(contentsOf: url), service.sendRemoteBlob(globalID: id, data: bytes) == hash else { throw ParkingLotError.message("Wait for the copied images to download before pasting.") }
                }
                if hashes.isEmpty { perform(operation) } else { pendingPaste = (operation, hashes, authority.leaseEpoch, authority.homeBoot) }
            } catch { self.error = error.localizedDescription }
        } else if let text = UIPasteboard.general.string {
            let parent = rows.last(where: \.heading)?.id
            perform(LotOperation(kind: .insert, row: ParkingLotRow(heading: false, text: text), parentID: parent))
        }
    }
    private func uploadImage(_ data: Data, row: UUID) throws {
        guard canEdit, let authority = editor?.saved else { throw ParkingLotError.message("Take the lot before attaching an image.") }
        guard pendingImage == nil else { throw ParkingLotError.message("Wait for the current image to finish uploading.") }
        let png = try PadImage.normalize(data)
        guard let hash = service.sendRemoteBlob(globalID: id, data: png) else { throw ParkingLotError.message("Could not send the image to home.") }
        pendingImage = (row, hash, authority.leaseEpoch, authority.homeBoot)
    }
    private func commentSheet(_ selection: LotMenuSelection) -> some View {
        let targets = rows.filter { selection.ids.contains($0.id) }
        let row = targets.count == 1 ? targets[0] : ParkingLotRow(heading: false, text: "\(targets.count) selected entries")
        return LotCommentSheet(row: row, enabled: canEdit, add: { text in
            performBatch(targets.map { LotOperation(kind: .appendComment, rowID: $0.id, text: text, commentID: UUID()) })
        }, remove: { note in
            if targets.count == 1 { perform(LotOperation(kind: .removeComment, rowID: row.id, commentID: note)) }
        })
    }
    private func moveSheet(_ selection: LotMenuSelection) -> some View {
        let roots = selection.roots(in: rows)
        let row = roots.first ?? ParkingLotRow(heading: false, text: "")
        let subtree = Set(roots.flatMap { root in ParkingLotTree.range(root.id, in: rows).map { rows[$0].map(\.id) } ?? [] })
        let candidates = rows.filter { !subtree.contains($0.id) }
        return NavigationStack {
            List {
                Section("Before entry") {
                    ForEach(candidates.filter { row.heading ? $0.heading : !$0.heading }) { sibling in
                        Button(sibling.text.isEmpty ? "Untitled entry" : sibling.text) {
                            performBatch(roots.map { LotOperation(kind: .move, rowID: $0.id, before: sibling.id, parentID: row.heading ? nil : hierarchy[sibling.id]?.parentID) }); moving = nil
                        }
                    }
                }
                if !row.heading {
                    Section("Inside entry") {
                        ForEach(candidates) { parent in
                            Button(parent.text.isEmpty ? "Untitled entry" : parent.text) { performBatch(roots.map { LotOperation(kind: .move, rowID: $0.id, parentID: parent.id) }); moving = nil }
                        }
                    }
                }
                Button(row.heading ? "End of lot" : "End of current level") { performBatch(roots.map { LotOperation(kind: .move, rowID: $0.id, parentID: row.heading ? nil : hierarchy[row.id]?.parentID) }); moving = nil }
            }.navigationTitle("Move entry").toolbar { Button("Cancel") { moving = nil } }
        }
    }
    private var proposalSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if let proposal = service.lotProposals[id] {
                    Text("Changes from " + proposal.author).font(.headline)
                    if let before = proposal.before, let after = proposal.after {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Before").bold(); previewRows(before.document.rows)
                                Divider(); Text("After").bold(); previewRows(after.rows)
                            }
                        }
                    } else { ProgressView("Finishing your saves before showing the changes…") }
                    HStack {
                        Button("Decline", role: .cancel) { service.decideLotProposal(id, approved: false) }
                        Spacer()
                        Button("Approve") { service.decideLotProposal(id, approved: true) }.buttonStyle(.borderedProminent).disabled(proposal.previewDigest == nil || !(proposal.after?.rows ?? []).flatMap({ $0.images ?? [] }).allSatisfy { service.blobCache[$0] != nil })
                    }
                }
            }.padding().navigationTitle("Review Parking Lot changes")
        }
    }
    private func previewRows(_ entries: [ParkingLotRow]) -> some View {
        let nodes = (try? ParkingLotTree.nodes(entries)) ?? [:]
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(entries) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.text.isEmpty ? (row.heading ? "Empty heading" : "Empty item") : row.text)
                        .font(row.heading ? .headline : .body).strikethrough(row.isDone).textSelection(.enabled)
                    if let tag = row.tag { Text(tag.rawValue.capitalized + " tag").font(.caption).foregroundStyle(tagColor(tag, heading: false)) }
                    ForEach(row.notes ?? []) { note in Text(note.author + ": " + note.text).font(.callout).italic().textSelection(.enabled) }
                    if !(row.images ?? []).isEmpty {
                        LotThumbnailStrip(hashes: row.images ?? [], images: service.blobCache, open: { fullImage = $0 })
                        if !(row.images ?? []).allSatisfy({ service.blobCache[$0] != nil }) { Text("Waiting for images before approval…").font(.caption) }
                    }
                }.padding(.leading, CGFloat(min(6, max(0, (nodes[row.id]?.depth ?? 0) - 1))) * 12)
            }
        }
    }
    static func markdown(_ rows: [ParkingLotRow]) -> String {
        let nodes = (try? ParkingLotTree.nodes(rows)) ?? [:]
        return rows.map { row in
            let prefix = row.heading ? "# " : String(repeating: "  ", count: max(0, (nodes[row.id]?.depth ?? 1) - 1)) + (row.isDone ? "- [x] " : "- ")
            let notes = (row.notes ?? []).map { "\n  > " + $0.author + ": " + $0.text }.joined()
            return prefix + row.text + notes
        }.joined(separator: "\n")
    }
    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<URL>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? ""), seen.insert(url).inserted else { return nil }
            return url
        }
    }
}

private struct LotCommentSheet: View {
    let row: ParkingLotRow
    let enabled: Bool
    var add: (String) -> Void
    var remove: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                List { ForEach(row.notes ?? []) { note in
                    VStack(alignment: .leading) { Text(note.author).font(.caption.bold()); Text(note.text).textSelection(.enabled) }
                        .swipeActions { Button("Delete", role: .destructive) { remove(note.id); dismiss() }.disabled(!enabled) }
                } }
                TextField("Comment", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).disabled(!enabled)
                Button("Add comment") { add(text); dismiss() }.buttonStyle(.borderedProminent).disabled(!enabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding().navigationTitle("Comments").toolbar { Button("Done") { dismiss() } }
        }
    }
}

private struct MobileLotFile: FileDocument {
    static let type = UTType(exportedAs: "local.richard.converse.export", conformingTo: .json)
    static var readableContentTypes: [UTType] { [type] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
private struct MobileLotExportSheet: View {
    let snapshot: LotSnapshot
    let images: [String: URL]
    let devices: [ExportScrubber.Device]
    @State private var scrub = true
    @State private var includeImages = true
    @State private var busy = false
    @State private var error = ""
    @State private var file: MobileLotFile?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Text("Exports the copy saved on home at revision \(snapshot.document.revision), including its outline, colors and comments.")
                Toggle("Scrub secrets and personal information", isOn: $scrub)
                Toggle("Include images", isOn: $includeImages)
                Text("Text scrubbing is best effort. Images are included unchanged.").font(.footnote).foregroundStyle(.secondary)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Button(busy ? "Preparing…" : "Save Converse file…") { prepare() }.disabled(busy)
            }.navigationTitle("Export Parking Lot").toolbar { Button("Done") { dismiss() } }
        }.fileExporter(isPresented: $saving, document: file, contentType: MobileLotFile.type, defaultFilename: snapshot.name + ".converse") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
    }
    private func prepare() {
        busy = true; error = ""
        let selectedScrub = scrub, selectedImages = includeImages
        let snapshot = self.snapshot, images = self.images, devices = self.devices
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        Task { @MainActor in
            do {
                let data = try await Task.detached {
                    var scrubber: ExportScrubber? = selectedScrub ? ExportScrubber(context: .init(devices: devices)) : nil
                    return try LotPortableExport.encode(snapshot, includeImages: selectedImages, scrubber: &scrubber, version: version, build: build) { hash in
                        guard let url = images[hash] else { throw ParkingLotError.message("Wait for the lot's images to finish downloading, then try again.") }
                        return try Data(contentsOf: url)
                    }
                }.value
                file = MobileLotFile(data: data); saving = true
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

private struct LotRowFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { _, next in next } }
}

struct LotMenuSelection: Identifiable {
    var id = UUID()
    var ids: Set<UUID>
    static func range(from first: UUID, to last: UUID, visible: [UUID]) -> Set<UUID> {
        guard let a = visible.firstIndex(of: first), let b = visible.firstIndex(of: last) else { return [] }
        return Set(visible[min(a,b)...max(a,b)])
    }
    func roots(in rows: [ParkingLotRow]) -> [ParkingLotRow] {
        let nodes = (try? ParkingLotTree.nodes(rows)) ?? [:]
        return rows.filter { row in
            guard ids.contains(row.id) else { return false }
            var parent = nodes[row.id]?.parentID
            while let ancestor = parent { if ids.contains(ancestor) { return false }; parent = nodes[ancestor]?.parentID }
            return true
        }
    }
    static func applying(_ operations: [LotOperation], to document: ParkingLotDocument, author: String) throws -> ParkingLotDocument {
        try operations.reduce(document) { try $1.applying(to: $0, author: author) }
    }
}
