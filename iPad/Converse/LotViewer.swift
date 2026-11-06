import SwiftUI
import UIKit

// Read-only Parking Lot viewer for iPhone and iPad. The Mac sends each lot row
// as one message in ParkingLotStore.exportMessages' Markdown form; this file
// turns those back into rows and renders them with the Mac editor's styling.

struct LotViewerComment: Equatable {
    var author: String
    var text: String
}

struct LotViewerRow: Equatable, Identifiable {
    var id: UUID
    var heading: Bool
    var number: Int?
    var done: Bool
    var text: String
    var comments: [LotViewerComment]
    var images: [String]
    // Nil is the legacy flat format; nested Mac rows carry two spaces per level.
    var depth: Int? = nil
    /// The label as the Mac wrote it ("3", "b", "ii"); nil for headings.
    var label: String? = nil
    var marker: String { label.map { $0 + "." } ?? number.map { "\($0)." } ?? "•" }
}

enum LotViewerEntry: Equatable, Identifiable {
    case row(LotViewerRow)
    // A message this viewer cannot read back is shown as it arrived.
    case plain(DeviceWireMessage)
    var id: UUID {
        switch self {
        case .row(let row): return row.id
        case .plain(let message): return message.id
        }
    }
    var isHeading: Bool { if case .row(let row) = self { return row.heading }; return false }
}

enum LotViewerParser {
    static let continuation = "   "
    static let doneMarker = "[Done] "
    /// Inverse of ParkingLotStore.markdown for one exported row. Returns nil
    /// unless the whole message has that shape, so callers can fall back.
    static func parse(_ message: DeviceWireMessage) -> LotViewerRow? {
        guard message.role == "assistant" else { return nil }
        let lines = message.text.components(separatedBy: "\n")
        let indentation = lines[0].prefix(while: { $0 == " " }).count
        guard indentation % 2 == 0, indentation <= 14 else { return nil }
        let first = String(lines[0].dropFirst(indentation))
        var heading = false, number: Int?, label: String?
        var rest: Substring
        if first.hasPrefix("# "), indentation == 0 {
            heading = true; rest = first.dropFirst(2)
        } else if let dot = first.range(of: ". "), !first[..<dot.lowerBound].isEmpty, first[..<dot.lowerBound].count <= 8,
                  first[..<dot.lowerBound].allSatisfy({ $0.isASCII && $0.isNumber }) || first[..<dot.lowerBound].allSatisfy({ $0.isASCII && $0.isLowercase }) {
            // The Mac labels nested levels 1, 2, 3 → a, b, c → i, ii, iii (since 0.6.8).
            let raw = String(first[..<dot.lowerBound])
            if let value = Int(raw) { guard value > 0 else { return nil }; number = value }
            label = raw; rest = first[dot.upperBound...]
        } else { return nil }
        var done = false
        if rest.hasPrefix(doneMarker) { done = true; rest = rest.dropFirst(doneMarker.count) }
        var text = [String(rest)]
        var comments: [LotViewerComment] = []
        let rowContinuation = String(repeating: " ", count: indentation) + continuation
        for line in lines.dropFirst() {
            guard line.hasPrefix(rowContinuation) else { return nil }
            let body = line.dropFirst(rowContinuation.count)
            if body.hasPrefix("> "), let comment = commentStart(body.dropFirst(2)) {
                comments.append(comment)
            } else if !comments.isEmpty {
                // Comments come last; every later line continues the latest one.
                guard body.hasPrefix("> ") else { return nil }
                comments[comments.count - 1].text += "\n" + body.dropFirst(2)
            } else {
                text.append(String(body))
            }
        }
        return LotViewerRow(id: message.id, heading: heading, number: number, done: done, text: text.joined(separator: "\n"),
                            comments: comments, images: message.imageHashes, depth: indentation == 0 ? nil : indentation / 2 + 1, label: label)
    }
    // "author: text", split at the first ": ". An author may contain a colon
    // that is not followed by a space (for example "Agent:Planner").
    private static func commentStart(_ body: Substring) -> LotViewerComment? {
        guard let separator = body.range(of: ": ") else { return nil }
        let author = body[..<separator.lowerBound]
        guard !author.isEmpty, author.first?.isWhitespace == false else { return nil }
        return LotViewerComment(author: String(author), text: String(body[separator.upperBound...]))
    }
    static func entries(_ messages: [DeviceWireMessage]) -> [LotViewerEntry] {
        messages.map { message in parse(message).map(LotViewerEntry.row) ?? .plain(message) }
    }
    static func depth(_ entry: LotViewerEntry) -> Int {
        if case .row(let row) = entry { return row.depth ?? (row.heading ? 0 : 1) }
        return 1
    }
    /// Rows to draw after local collapse state. A collapsed row reports how
    /// many descendants it hides.
    static func visible(_ entries: [LotViewerEntry], collapsed: Set<UUID>) -> [(entry: LotViewerEntry, hidden: Int)] {
        var result: [(entry: LotViewerEntry, hidden: Int)] = []
        var hiding: (depth: Int, index: Int)?
        for entry in entries {
            let depth = depth(entry)
            if let current = hiding, depth <= current.depth { hiding = nil }
            if let current = hiding { result[current.index].hidden += 1; continue }
            result.append((entry, 0))
            if collapsed.contains(entry.id) { hiding = (depth, result.count - 1) }
        }
        return result
    }
}

/// What the viewer shows versus the newest snapshot from home. The first
/// snapshot is shown as it arrives; later changes wait for Refresh.
struct LotViewerState: Equatable {
    private(set) var displayed: [DeviceWireMessage]?
    private(set) var latest: [DeviceWireMessage]?
    private(set) var entries: [LotViewerEntry] = []
    var refreshAvailable: Bool {
        guard let displayed, let latest else { return false }
        return Self.differs(displayed, latest)
    }
    /// Returns whether visible state changed.
    @discardableResult mutating func receive(_ messages: [DeviceWireMessage]) -> Bool {
        if displayed == nil {
            displayed = messages; latest = messages; entries = LotViewerParser.entries(messages); return true
        }
        // Home resends the lot on every sync tick; identical content is no news.
        if let latest, !Self.differs(latest, messages) { return false }
        latest = messages
        return true
    }
    mutating func applyRefresh() {
        guard let latest else { return }
        displayed = latest; entries = LotViewerParser.entries(latest)
    }
    // Row ids, order, text (which carries done and comments) and images.
    static func differs(_ a: [DeviceWireMessage], _ b: [DeviceWireMessage]) -> Bool {
        a.count != b.count || zip(a, b).contains { $0.id != $1.id || $0.role != $1.role || $0.text != $1.text || $0.imageHashes != $1.imageHashes }
    }
}

enum LotSubscription {
    /// Whether to (re)subscribe a displayed lot now. Only Parking Lots qualify:
    /// their subscription is nonexclusive, so renewing never takes or parks
    /// anything on home. Ordinary sessions keep their explicit Take.
    static func shouldSubscribe(placed: Bool, isLot: Bool, suspended: Bool, homeReachable: Bool, subscribed: Bool, pending: Bool) -> Bool {
        placed && isLot && !suspended && homeReachable && !subscribed && !pending
    }
}

extension PadModel {
    func isLotRow(_ id: String) -> Bool { service.remoteRow(globalID: id)?.engine == "parking" }
    func reconcileLots() {
        let placed = Set(state.placements.compactMap { $0 })
        for id in Array(lotViews.keys) where !placed.contains(id) { lotViews.removeValue(forKey: id) }
        for id in Array(lotCollapsed.keys) where !placed.contains(id) { lotCollapsed.removeValue(forKey: id) }
        for id in placed where isParkingLot(id) {
            if let rows = service.remoteLotSnapshots[id] {
                var view = lotViews[id] ?? LotViewerState()
                if view.receive(rows) { lotViews[id] = view }
                for hash in rows.flatMap(\.imageHashes) where service.blobCache[hash] == nil { service.fetchBlob(globalID: id, hash: hash) }
            }
            ensureLotSubscription(id)
        }
    }
    func ensureLotSubscription(_ id: String) {
        guard LotSubscription.shouldSubscribe(placed: state.placements.contains(id), isLot: isLotRow(id), suspended: lotSubscriptionsSuspended,
                                              homeReachable: service.lotHomeReachable(id), subscribed: service.remoteLeases[id] != nil,
                                              pending: service.lotSubscriptionPending(id)) else { return }
        service.acquireRemote(globalID: id)
    }
    func applyLotRefresh(_ id: String) {
        guard var view = lotViews[id] else { return }
        view.applyRefresh(); lotViews[id] = view
    }
    func toggleLotHeading(_ id: String, heading: UUID) {
        var collapsed = lotCollapsed[id] ?? []
        if collapsed.contains(heading) { collapsed.remove(heading) } else { collapsed.insert(heading) }
        lotCollapsed[id] = collapsed
    }
}

enum LotStyle {
    // Sources/ParkingLotEditor.swift ParkingOutlineText.headingColor.
    static let heading = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.48, green: 0.75, blue: 1, alpha: 1)
            : UIColor(red: 0.05, green: 0.25, blue: 0.55, alpha: 1)
    })
    static var compact: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    static var thumbnailHeight: CGFloat { compact ? 56 : 80 }
    static var gutter: CGFloat { compact ? 26 : 34 }
    // Sources/LotLinks.swift: web and Markdown links match the Mac lot. File
    // links name the home Mac's disk, so they stay plain text here.
    static func linked(_ text: String) -> AttributedString { LotLinks.attributed(text, files: false) }
}

enum LotThumbnails {
    private static let cache = NSCache<NSString, UIImage>()
    static func image(_ url: URL, height: CGFloat) -> UIImage? {
        let key = (url.path + "#" + String(Int(height))) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let full = UIImage(contentsOfFile: url.path), full.size.height > 0 else { return nil }
        let scale = UIScreen.main.scale
        let pixels = height * 2 * scale
        let ratio = min(1, pixels / max(full.size.width, full.size.height))
        let image = full.preparingThumbnail(of: CGSize(width: full.size.width * ratio, height: full.size.height * ratio)) ?? full
        cache.setObject(image, forKey: key)
        return image
    }
}

struct LotImageItem: Identifiable { var id: String; var url: URL }

struct PadLotPane: View {
    let id: String
    let pane: Int
    @ObservedObject var model: PadModel
    @ObservedObject private var service: DeviceSyncService
    @State private var sessionActions: DeviceSidebarRow?
    @State private var fullImage: LotImageItem?
    init(id: String, pane: Int, model: PadModel) { self.id = id; self.pane = pane; self.model = model; self.service = model.service }
    private var home: String { DeviceGlobalID(id)?.home ?? "" }
    private var offline: Bool { service.remoteOffline.contains(id) || service.homes[home]?.online == false }
    var body: some View {
        let view = model.lotViews[id]
        VStack(spacing: 0) {
            header
            Divider()
            if offline && view != nil {
                notice("Home offline. Showing the last copy received.", systemImage: "wifi.slash")
            } else if service.remoteLeases[id] == nil && view != nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reconnecting…"); Spacer() }
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
                    .accessibilityIdentifier("lot-reconnecting")
            }
            if view?.refreshAvailable == true { refreshBar }
            if let view {
                rows(view)
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    if offline { Label("Home offline", systemImage: "wifi.slash").foregroundStyle(.secondary) }
                    else { ProgressView(); Text("Opening lot…").foregroundStyle(.secondary) }
                    Spacer()
                }.frame(maxWidth: .infinity)
            }
        }
        .background(Color(uiColor: .systemBackground)).frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: view?.refreshAvailable == true)
        .onAppear { model.ensureLotSubscription(id) }
        .fullScreenCover(item: $fullImage) { item in LotImageViewer(item: item) }
    }
    private var header: some View {
        HStack(spacing: 8) {
            Text(String(pane + 1)).font(.caption.bold()).foregroundStyle(.white).padding(5).background(.green, in: RoundedRectangle(cornerRadius: 3))
            Image(systemName: "parkingsign.square").foregroundStyle(LotStyle.heading).accessibilityLabel("Parking Lot")
            PadSessionName(title: service.remoteRow(globalID: id)?.title ?? service.remoteTranscripts[id]?.title ?? "Parking Lot", isAgent: false)
                .font(LotStyle.compact ? .headline : .title3).lineLimit(1).truncationMode(.tail)
            ViewThatFits(in: .horizontal) {
                Label("Read only", systemImage: "lock").labelStyle(.titleAndIcon)
                Image(systemName: "lock")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
            .accessibilityElement(children: .ignore).accessibilityLabel("Read only").accessibilityIdentifier("lot-read-only")
            Spacer(minLength: 0)
            Button { sessionActions = service.remoteRow(globalID: id) } label: {
                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
            }.fixedSize().accessibilityLabel("Session actions")
                .disabled(service.remoteRow(globalID: id) == nil)
                .sheet(item: $sessionActions) { row in PadSessionActions(row: row, park: { model.park(id) }) }
            Button("P") { model.park(id) }.accessibilityLabel("Park this Parking Lot")
        }.padding(8)
    }
    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage).font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
    }
    private var refreshBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.accentColor)
            Text("Updated on " + service.displayName(for: home)).font(.callout).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Button { model.applyLotRefresh(id) } label: { Label("Refresh", systemImage: "arrow.clockwise").fontWeight(.semibold) }
                .buttonStyle(.borderedProminent).controlSize(LotStyle.compact ? .regular : .large)
                .accessibilityIdentifier("lot-refresh").accessibilityHint("Shows the newest copy of this lot")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
    private func rows(_ view: LotViewerState) -> some View {
        let lines = LotViewerParser.visible(view.entries, collapsed: model.lotCollapsed[id] ?? [])
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if lines.isEmpty { Text("This lot is empty.").foregroundStyle(.secondary).padding(.vertical, 20) }
                ForEach(Array(lines.enumerated()), id: \.element.entry.id) { index, line in
                    switch line.entry {
                    case .row(let row):
                        let sourceIndex = view.entries.firstIndex(where: { $0.id == row.id })
                        let expandable = sourceIndex.map { $0 + 1 < view.entries.count && LotViewerParser.depth(view.entries[$0 + 1]) > LotViewerParser.depth(view.entries[$0]) } ?? false
                        LotRowView(row: row, hidden: line.hidden, first: index == 0, collapsed: model.lotCollapsed[id]?.contains(row.id) == true,
                                   expandable: expandable, images: service.blobCache, toggle: { model.toggleLotHeading(id, heading: row.id) }, open: { fullImage = $0 })
                    case .plain(let message):
                        LotPlainRow(message: message, images: service.blobCache, open: { fullImage = $0 })
                    }
                }
                Text("Read only. Edit this lot on its Mac, or ask a session or agent to change it.")
                    .font(.footnote).foregroundStyle(.tertiary).padding(.top, 18).padding(.bottom, 24)
            }
            .padding(.horizontal, LotStyle.compact ? 10 : 16).padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("lot-viewer")
    }
}

struct LotRowView: View {
    let row: LotViewerRow
    let hidden: Int
    let first: Bool
    let collapsed: Bool
    let expandable: Bool
    let images: [String: URL]
    var toggle: () -> Void
    var open: (LotImageItem) -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if expandable {
                    HStack(spacing: 2) {
                        Button(action: toggle) {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.caption2.weight(.semibold))
                        }.buttonStyle(.plain).accessibilityLabel(collapsed ? "Expand item" : "Collapse item")
                        if !row.heading { Text(row.marker).font(.body.monospacedDigit()) }
                    }
                } else {
                    Text(row.marker).font(.body.monospacedDigit())
                }
            }
            .foregroundStyle(.secondary).frame(width: LotStyle.gutter, alignment: .trailing).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                text
                if !row.images.isEmpty { LotThumbnailStrip(hashes: row.images, images: images, open: open) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !row.comments.isEmpty { LotCommentsButton(row: row) }
        }
        .padding(.top, row.heading && !first ? 14 : (row.heading ? 4 : 5))
        .padding(.bottom, row.heading ? 4 : 5)
        .padding(.leading, CGFloat(max(0, min(5, (row.depth ?? (row.heading ? 0 : 1)) - 1))) * (LotStyle.compact ? 12 : 18))
        .contentShape(Rectangle())
        .gesture(row.heading && expandable ? TapGesture().onEnded(toggle) : nil)
    }
    private var text: some View {
        var styled = LotStyle.linked(row.text.isEmpty ? " " : row.text)
        if row.done { styled.strikethroughStyle = .single }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(styled)
                .font(row.heading ? .body.weight(.bold) : .body)
                .foregroundStyle(row.done ? AnyShapeStyle(.secondary) : (row.heading ? AnyShapeStyle(LotStyle.heading) : AnyShapeStyle(.primary)))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if expandable && collapsed && hidden > 0 {
                Text("\(hidden) \(hidden == 1 ? "item" : "items")").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((row.label.map { $0 + ". " } ?? "") + row.text)
        .accessibilityAddTraits(row.heading ? [.isHeader, .isButton] : (expandable ? [.isButton] : []))
        .accessibilityValue(accessibilityValue)
        .accessibilityAction { if expandable { toggle() } }
    }
    private var accessibilityValue: String {
        var parts: [String] = []
        if row.done { parts.append("Done") }
        if expandable && collapsed { parts.append("Collapsed, \(hidden) hidden") }
        if !row.comments.isEmpty { parts.append("\(row.comments.count) \(row.comments.count == 1 ? "comment" : "comments")") }
        if !row.images.isEmpty { parts.append("\(row.images.count) \(row.images.count == 1 ? "image" : "images")") }
        return parts.joined(separator: ", ")
    }
}

struct LotPlainRow: View {
    let message: DeviceWireMessage
    let images: [String: URL]
    var open: (LotImageItem) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LotStyle.linked(message.text)).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !message.imageHashes.isEmpty { LotThumbnailStrip(hashes: message.imageHashes, images: images, open: open) }
        }
        .padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LotCommentsButton: View {
    let row: LotViewerRow
    @State private var shown = false
    var body: some View {
        let count = row.comments.count
        Button { shown = true } label: {
            Label("\(count)", systemImage: "text.bubble").labelStyle(.titleAndIcon)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                .frame(minWidth: 44, minHeight: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .accessibilityLabel("Show \(count) \(count == 1 ? "comment" : "comments")")
        .popover(isPresented: $shown) { LotCommentsList(row: row).presentationDetents([.medium, .large]) }
    }
}

struct LotCommentsList: View {
    let row: LotViewerRow
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(row.text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    ForEach(Array(row.comments.enumerated()), id: \.offset) { _, comment in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(comment.author).font(.subheadline.weight(.semibold))
                            Text(LotStyle.linked(comment.text)).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Comments").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 320, idealWidth: 380, minHeight: 240, idealHeight: 420)
    }
}

struct LotThumbnailStrip: View {
    let hashes: [String]
    let images: [String: URL]
    var open: (LotImageItem) -> Void
    var body: some View {
        let height = LotStyle.thumbnailHeight
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(hashes.enumerated()), id: \.offset) { _, hash in
                    if let url = images[hash], let image = LotThumbnails.image(url, height: height) {
                        Button { open(LotImageItem(id: hash, url: url)) } label: {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(maxWidth: height * 2, maxHeight: height)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(uiColor: .separator), lineWidth: 0.5))
                        }.buttonStyle(.plain).accessibilityLabel("Image. Tap to view full size")
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: .tertiarySystemFill))
                            .frame(width: height * 1.3, height: height)
                            .overlay(ProgressView().controlSize(.small))
                            .accessibilityLabel("Image loading")
                    }
                }
            }
        }
        .frame(height: height)
    }
}

struct LotImageViewer: View {
    let item: LotImageItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let image = UIImage(contentsOfFile: item.url.path) { LotZoomingImage(image: image) }
                else { Text("Image unavailable").foregroundStyle(.secondary) }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct LotZoomingImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6; scroll.delegate = context.coordinator
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        let view = UIImageView(image: image); view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view); context.coordinator.view = view
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor)
        ])
        view.isAccessibilityElement = true; view.accessibilityLabel = "Parking Lot image"
        return scroll
    }
    func updateUIView(_ view: UIScrollView, context: Context) { context.coordinator.view?.image = image }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var view: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view }
    }
}
