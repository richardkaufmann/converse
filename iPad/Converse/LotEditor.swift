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
    @State private var focus: UUID?
    @State private var caretRequest: (UUID, Int)?
    @State private var editActivity: UInt64 = 0
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
        let tree = hierarchy, folded = collapsed
        return rows.filter { row in
            var parent = tree[row.id]?.parentID
            while let ancestor = parent { if folded.contains(ancestor) { return false }; parent = tree[ancestor]?.parentID }
            return true
        }
    }
    var body: some View {
        let shown = visibleRows, tree = hierarchy, rowLabels = labels
        let parents = Set(tree.values.compactMap(\.parentID))
        let sectionEnds = sectionEnds(visible: shown)
        return VStack(spacing: 0) {
            header
            Divider()
            status
            if editor != nil {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(shown) { row in
                            rowView(row, depth: tree[row.id]?.depth ?? 0, label: rowLabels[row.id], expandable: parents.contains(row.id))
                            if let section = sectionEnds[row.id] {
                                Button("New item…") { insert(heading: false, section: section) }
                                    .foregroundStyle(.secondary).padding(.leading, 35).frame(minHeight: 36)
                                    .disabled(!canEdit).accessibilityIdentifier("lot-new-item-" + section.uuidString)
                            }
                        }
                        Button("New Heading…") { insert(heading: true, atEnd: true) }
                            .foregroundStyle(.secondary).padding(.leading, 35).frame(minHeight: 44).disabled(!canEdit)
                            .accessibilityIdentifier("lot-new-heading")
                        if rows.isEmpty { Text("Add a heading or item to start this Parking Lot.").foregroundStyle(.secondary).padding() }
                    }.scrollTargetLayout().padding(.horizontal, 10).padding(.vertical, 10)
                    .coordinateSpace(name: "lot-rows")
                    .onPreferenceChange(LotRowFrames.self) { rowFrames = $0 }
                    .highPriorityGesture(DragGesture(minimumDistance: 10, coordinateSpace: .global)
                        .onChanged { value in
                            guard selecting, canEdit else { return }
                            if dragStart == nil { dragStart = rowAt(value.startLocation); dragBase = selected }
                            if let first = dragStart, let last = rowAt(value.location) {
                                selected = dragBase.union(LotMenuSelection.range(from: first, to: last, visible: visibleRows.map(\.id)))
                            }
                        }.onEnded { _ in dragStart = nil }, including: selecting ? .all : .subviews)
                }
                .background(LotPointerSelection(enabled: canEdit, frames: rowFrames, visible: visibleRows.map(\.id)) { ids in
                    focus = nil; selecting = true; selected = ids
                })
                .scrollPosition(id: $firstVisibleRow, anchor: .top).accessibilityIdentifier("lot-editor")
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
            ParkingLotShoe().frame(width: 20, height: 20).accessibilityLabel("Parking Lot")
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
                        if editor.unconfirmedCount > 0 {
                            Button("Copy unconfirmed text") { UIPasteboard.general.string = Self.markdown(editor.projected.rows) }
                        }
                        Button("Take again") { service.releaseRemote(globalID: id); service.acquireRemote(globalID: id) }
                    }
                } else if editor.draining { Label("Finishing saves…", systemImage: "pause.circle") }
                else {
                    LotSaveGauge(saved: editor.saved.document.rows, projected: editor.projected.rows,
                        activity: editActivity, pending: editor.unconfirmedCount > 0)
                }
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
    @ViewBuilder private func rowView(_ row: ParkingLotRow, depth: Int, label: String?, expandable: Bool) -> some View {
        HStack(alignment: .top, spacing: 5) {
            if expandable {
                Button { model.toggleLotHeading(id, heading: row.id) } label: {
                    Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down").frame(width: 30, height: 44)
                }.accessibilityLabel("Collapse or expand entry")
            } else { Color.clear.frame(width: 30, height: 1).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let label { Text(label).font(.system(size: model.textSize(pane))).monospacedDigit().foregroundStyle(.secondary) }
                if selecting {
                    Text(row.text.isEmpty ? (row.heading ? "Heading" : "Item") : row.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.system(size: model.textSize(pane), weight: row.heading ? .semibold : .regular))
                        .foregroundStyle(row.isDone ? Color.secondary : tagColor(row.tag, heading: row.heading))
                        .strikethrough(row.isDone)
                } else {
                    LotEntryText(text: rows.first(where: { $0.id == row.id })?.text ?? row.text,
                        font: .systemFont(ofSize: model.textSize(pane), weight: row.heading ? .semibold : .regular),
                        color: UIColor(row.isDone ? Color.secondary : tagColor(row.tag, heading: row.heading)),
                        done: row.isDone, editable: canEdit, focused: focus == row.id,
                        caret: caretRequest?.0 == row.id ? caretRequest?.1 : nil,
                        identifier: "lot-text-" + row.id.uuidString,
                        changed: { perform(LotOperation(kind: .setText, rowID: row.id, text: $0)) },
                        focusChanged: { active in
                            if active { focus = row.id; caretRequest = nil }
                            else if focus == row.id { focus = nil }
                        },
                        returned: { range in splitEntry(row.id, at: range) },
                        emptyBackspace: { removeEmptyEntry(row.id) })
                        // UIViewRepresentable otherwise supplies its bottom edge as the
                        // baseline: an empty native editor then sits below its number.
                        .alignmentGuide(.firstTextBaseline) { _ in
                            UIFont.systemFont(ofSize: model.textSize(pane), weight: row.heading ? .semibold : .regular).ascender
                        }
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
        .background(GeometryReader { geometry in Color.clear.preference(key: LotRowFrames.self, value: [row.id: geometry.frame(in: .global)]) })
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
        if let row = single {
            Button("New item below") { insert(heading: false, after: row.id) }
            Button("New heading below") { insert(heading: true, after: row.id) }
        }
        Button("Indent") { perform(LotOperation(kind: .indent, rowIDs: targets.map(\.id))) }
            .disabled(ParkingLotTree.changingIndent(ids, in: rows, deeper: true) == nil)
        Button("Outdent") { perform(LotOperation(kind: .outdent, rowIDs: targets.map(\.id))) }
            .disabled(ParkingLotTree.changingIndent(ids, in: rows, deeper: false) == nil)
        if !targets.contains(where: \.heading) {
            Menu("Move to heading") {
                ForEach(rows.filter(\.heading)) { heading in
                    Button(heading.text.isEmpty ? "Untitled heading" : heading.text) {
                        let roots = LotMenuSelection(ids: ids).roots(in: rows)
                        performBatch(roots.map { LotOperation(kind: .move, rowID: $0.id, parentID: heading.id) })
                    }.disabled(targets.allSatisfy { hierarchy[$0.id]?.parentID == heading.id })
                }
            }
        }
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
        guard !operations.isEmpty else { return }
        perform(LotOperation(kind: .batch, operations: operations))
    }
    private func tagColor(_ tag: ParkingLotTag?, heading: Bool) -> Color {
        guard let tag else { return heading ? LotStyle.heading : .primary }
        return Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? tag.darkHex : tag.lightHex
            let value = UInt32(hex.dropFirst(), radix: 16)!
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    @discardableResult private func perform(_ operation: LotOperation, history: Bool = true) -> Bool {
        editActivity &+= 1
        do {
            let before = rows
            let coalescing = operation.kind == .setText && editor?.pending.last?.kind == .setText && editor?.pending.last?.rowID == operation.rowID
            try service.editLot(id, operation: operation)
            if history && !coalescing { undo.append(before); if undo.count > 100 { undo.removeFirst() }; redo = [] }
            error = ""; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func sectionEnds(visible: [ParkingLotRow]) -> [UUID: UUID] {
        var section: UUID?, lastBySection: [UUID: UUID] = [:]
        for row in visible {
            if row.heading { section = row.id }
            if let section, !collapsed.contains(section) { lastBySection[section] = row.id }
        }
        return Dictionary(uniqueKeysWithValues: lastBySection.map { ($0.value, $0.key) })
    }
    private func insert(heading: Bool, after anchor: UUID? = nil, section: UUID? = nil, atEnd: Bool = false) {
        do {
            let edit = try LotEntryEditing.inserting(in: rows, heading: heading, after: atEnd ? nil : (anchor ?? focus), section: section)
            applyEntryEdit(edit)
        } catch { self.error = error.localizedDescription }
    }
    private func splitEntry(_ row: UUID, at range: NSRange) {
        do { applyEntryEdit(try LotEntryEditing.splitting(row, at: range, in: rows)) }
        catch { self.error = error.localizedDescription }
    }
    private func removeEmptyEntry(_ row: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == row }), rows[index].text.isEmpty,
              (rows[index].notes ?? []).isEmpty, (rows[index].images ?? []).isEmpty,
              ParkingLotTree.range(row, in: rows)?.count == 1 else { return }
        let previous = index > 0 ? rows[index - 1] : nil
        if perform(LotOperation(kind: .deleteSubtree, rowID: row)) {
            focus = previous?.id
            caretRequest = previous.map { ($0.id, ($0.text as NSString).length) }
        }
    }
    private func applyEntryEdit(_ edit: LotEntryEditing.Result) {
        if perform(edit.operation) {
            selecting = false; selected = []; caretRequest = (edit.focus, edit.offset); focus = edit.focus
            if let parent = (try? ParkingLotTree.nodes(edit.rows))?[edit.focus]?.parentID { model.lotCollapsed[id]?.remove(parent) }
            firstVisibleRow = edit.focus
        }
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
        try LotOperation(kind: .batch, operations: operations).applying(to: document, author: author)
    }
}

/// The same insertion positions as the Mac outline; every structural edit is
/// submitted as one revision so Return and Undo cannot leave half an item.
enum LotEntryEditing {
    struct Result { var rows: [ParkingLotRow]; var focus: UUID; var offset: Int = 0; var operation: LotOperation }
    static func inserting(in source: [ParkingLotRow], heading: Bool, after anchor: UUID?, section: UUID? = nil) throws -> Result {
        var rows = try ParkingLotTree.normalized(source)
        let tree = try ParkingLotTree.nodes(rows)
        var index = rows.count, parent: UUID?
        if let section, let range = ParkingLotTree.range(section, in: rows) {
            index = range.upperBound; parent = section
        } else if let anchor, let at = rows.firstIndex(where: { $0.id == anchor }) {
            if heading {
                let section = rows[...at].last(where: \.heading)?.id
                index = section.flatMap { ParkingLotTree.range($0, in: rows)?.upperBound } ?? rows.count
            } else {
                index = ParkingLotTree.range(anchor, in: rows)?.upperBound ?? rows.count
                parent = rows[at].heading ? anchor : tree[anchor]?.parentID
            }
        }
        if !heading && parent == nil { parent = ParkingLotTree.parentForInsertion(at: index, in: rows, heading: false) }
        let row = ParkingLotRow(heading: heading, text: "", parentID: heading ? nil : parent)
        rows.insert(row, at: index)
        _ = try ParkingLotTree.nodes(rows)
        let before = index + 1 < rows.count && (heading ? rows[index + 1].heading : tree[rows[index + 1].id]?.parentID == parent) ? rows[index + 1].id : nil
        return Result(rows: rows, focus: row.id, operation: LotOperation(kind: .insert, row: row, before: before, parentID: row.parentID))
    }
    static func splitting(_ id: UUID, at selection: NSRange, in source: [ParkingLotRow]) throws -> Result {
        var rows = try ParkingLotTree.normalized(source)
        guard let index = rows.firstIndex(where: { $0.id == id }), selection.location != NSNotFound,
              selection.location >= 0, selection.length >= 0, NSMaxRange(selection) <= (rows[index].text as NSString).length else {
            throw ParkingLotError.message("The entry changed before Return. Try again.")
        }
        let original = rows[index], text = original.text as NSString
        let prefix = text.substring(to: selection.location), suffix = text.substring(from: NSMaxRange(selection))
        let parent = original.heading ? original.id : original.parentID
        if selection.length == 0 && selection.location == 0 && !text.isEqual(to: "") && !original.heading {
            let blank = ParkingLotRow(heading: false, text: "", parentID: original.parentID)
            rows.insert(blank, at: index)
            return Result(rows: rows, focus: original.id, operation: LotOperation(kind: .insert, row: blank, before: original.id, parentID: blank.parentID))
        }
        let destination = original.heading ? index + 1 : (ParkingLotTree.range(id, in: rows)?.upperBound ?? index + 1)
        rows[index].text = prefix
        let next = ParkingLotRow(heading: false, text: suffix, parentID: parent)
        rows.insert(next, at: destination)
        _ = try ParkingLotTree.nodes(rows)
        let tree = try ParkingLotTree.nodes(rows)
        let before = destination + 1 < rows.count && tree[rows[destination + 1].id]?.parentID == parent ? rows[destination + 1].id : nil
        var operations: [LotOperation] = []
        if prefix != original.text { operations.append(LotOperation(kind: .setText, rowID: id, text: prefix)) }
        operations.append(LotOperation(kind: .insert, row: next, before: before, parentID: parent))
        return Result(rows: rows, focus: next.id, operation: LotOperation(kind: .batch, operations: operations))
    }
}

/// Net text still different from the acknowledged home copy, in user-visible
/// characters. Replacements count the larger span; deletes count too. Structural
/// changes are not represented as characters, and failures have their own notice.
enum LotTextBacklog {
    static func count(saved: [ParkingLotRow], projected: [ParkingLotRow]) -> Int {
        var previous = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0.text) })
        var count = 0
        for row in projected {
            count += difference(previous.removeValue(forKey: row.id) ?? "", row.text)
        }
        return count + previous.values.reduce(0) { $0 + $1.count }
    }
    static func difference(_ before: String, _ after: String) -> Int {
        guard before != after else { return 0 }
        let a = Array(before), b = Array(after)
        var prefix = 0, suffix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count, b.count) - prefix,
              a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        return max(a.count, b.count) - prefix - suffix
    }
}

struct LotSaveGauge: View {
    let saved: [ParkingLotRow]
    let projected: [ParkingLotRow]
    let activity: UInt64
    let pending: Bool
    @State private var quietActivity: UInt64?
    private var characters: Int { pending ? LotTextBacklog.count(saved: saved, projected: projected) : 0 }
    var body: some View {
        // Do not scan lot text on keystrokes while the gauge is hidden.
        let count = quietActivity == activity ? characters : 0
        // Reserve a small, fixed rail so acknowledgements never move the text.
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Capsule().fill(Color.secondary.opacity(0.55))
                    .frame(width: 4 + 52 * min(1, Double(count) / 100))
            }
            .frame(width: 56, height: 4)
            .opacity(quietActivity == activity && count > 10 ? 1 : 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) characters waiting to save")
            .accessibilityHidden(quietActivity != activity || count <= 10)
            .accessibilityIdentifier("lot-save-backlog")
            Spacer(minLength: 0)
        }.frame(height: 6)
        .task(id: activity) {
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            guard !Task.isCancelled else { return }
            quietActivity = activity
        }
    }
}

/// A real multiline native editor with an outline Return, instead of a SwiftUI
/// vertical TextField that silently turns Return into a newline inside the row.
struct LotEntryText: UIViewRepresentable {
    var text: String
    var font: UIFont
    var color: UIColor
    var done: Bool
    var editable: Bool
    var focused: Bool
    var caret: Int?
    var identifier: String
    var changed: (String) -> Void
    var focusChanged: (Bool) -> Void
    var returned: (NSRange) -> Void
    var emptyBackspace: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> LotEntryTextView {
        let view = LotEntryTextView()
        view.delegate = context.coordinator; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: LotEntryTextView, context: Context) {
        let measurement = PerformanceCapture.shared.begin()
        defer { PerformanceCapture.shared.end(.lotTextUpdate, measurement) }
        context.coordinator.parent = self
        view.accessibilityIdentifier = identifier; view.isEditable = editable; view.isSelectable = editable
        view.onEmptyBackspace = emptyBackspace
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .strikethroughStyle: done ? NSUnderlineStyle.single.rawValue : 0]
        // Never replace marked text during an input-method composition.
        if view.markedTextRange == nil {
            let rendered = NSAttributedString(string: text, attributes: attributes)
            if !view.attributedText.isEqual(to: rendered) {
                let selection = view.selectedRange
                view.attributedText = rendered
                view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: min(selection.length, max(0, (text as NSString).length - min(selection.location, (text as NSString).length))))
            }
        }
        view.typingAttributes = attributes; view.font = font
        view.wantsFocus = focused && editable
        if let caret, focused { view.selectedRange = NSRange(location: min(caret, (view.text as NSString).length), length: 0) }
        if view.wantsFocus && !view.isFirstResponder && view.window != nil { view.becomeFirstResponder() }
        if !view.wantsFocus && view.isFirstResponder { view.resignFirstResponder() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LotEntryTextView, context: Context) -> CGSize? {
        let measurement = PerformanceCapture.shared.begin()
        defer { PerformanceCapture.shared.end(.lotTextLayout, measurement) }
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: max(font.lineHeight, uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LotEntryText
        init(_ parent: LotEntryText) { self.parent = parent }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focusChanged(true) }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focusChanged(false) }
        func textViewDidChange(_ textView: UITextView) {
            if let view = textView as? LotEntryTextView {
                PerformanceCapture.shared.end(.lotInputToChange, view.inputMeasurement); view.inputMeasurement = nil
            }
            parent.changed(textView.text); textView.invalidateIntrinsicContentSize()
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard parent.editable else { return false }
            if text == "\n", (textView as? LotEntryTextView)?.softReturn != true, textView.markedTextRange == nil {
                parent.returned(range); return false
            }
            (textView as? LotEntryTextView)?.inputMeasurement = PerformanceCapture.shared.begin()
            return true
        }
    }
}
final class LotEntryTextView: UITextView {
    var inputMeasurement: PerformanceCapture.Span?
    var wantsFocus = false
    var softReturn = false
    var onEmptyBackspace: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && wantsFocus { becomeFirstResponder() }
    }
    override func deleteBackward() {
        if text.isEmpty && isEditable { onEmptyBackspace?() } else { super.deleteBackward() }
    }
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(softNewline))]
    }
    @objc private func softNewline() { softReturn = true; insertText("\n"); softReturn = false }
}

/// Watches primary-button pointer drags without claiming ordinary touch scrolls
/// or within-row text selections. Only crossing a row boundary begins selection.
struct LotPointerSelection: UIViewRepresentable {
    var enabled: Bool
    var frames: [UUID: CGRect]
    var visible: [UUID]
    var select: (Set<UUID>) -> Void
    func makeUIView(context: Context) -> LotPointerSelectionHost { LotPointerSelectionHost() }
    func updateUIView(_ view: LotPointerSelectionHost, context: Context) {
        view.gesture.isEnabled = enabled
        view.gesture.frames = frames; view.gesture.visible = visible; view.gesture.select = select
        view.install()
    }
    static func dismantleUIView(_ view: LotPointerSelectionHost, coordinator: ()) { view.gesture.view?.removeGestureRecognizer(view.gesture) }
}
final class LotPointerSelectionHost: UIView {
    let gesture = LotPointerRangeGesture()
    override func didMoveToWindow() { super.didMoveToWindow(); install() }
    override func didMoveToSuperview() { super.didMoveToSuperview(); install() }
    func install() {
        guard let window else { gesture.view?.removeGestureRecognizer(gesture); return }
        gesture.viewport = { [weak self] in
            guard let self, let window = self.window else { return .zero }
            return self.convert(self.bounds, to: window)
        }
        // SwiftUI backgrounds have their own hosting branch. Observe at the
        // window, restricted to this lot's viewport and measured row bounds.
        if gesture.view !== window {
            gesture.view?.removeGestureRecognizer(gesture); window.addGestureRecognizer(gesture)
        }
    }
}
final class LotPointerRangeGesture: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var frames: [UUID: CGRect] = [:]
    var visible: [UUID] = []
    var select: ((Set<UUID>) -> Void)?
    var viewport: (() -> CGRect)?
    private var start: UUID?
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delegate = self; allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        cancelsTouchesInView = true; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    convenience init() { self.init(target: nil, action: nil) }
    private func row(at point: CGPoint) -> UUID? { visible.first { frames[$0]?.contains(point) == true } }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard touch.type == .indirectPointer, viewport?().contains(touch.location(in: view?.window)) == true else { return false }
        var target = touch.view
        while let current = target, current !== view {
            if current is UIControl { return false }
            target = current.superview
        }
        return true
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first, event.buttonMask.contains(.primary),
              let first = row(at: touch.location(in: view?.window)) else { state = .failed; return }
        start = first
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start, let touch = touches.first, let last = row(at: touch.location(in: view?.window)) else { return }
        if state == .possible && start == last { return }
        state = state == .possible ? .began : .changed
        select?(LotMenuSelection.range(from: start, to: last, visible: visible))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = state == .possible ? .failed : .ended }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func reset() { start = nil; super.reset() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
