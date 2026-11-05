import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine

enum TranscriptExportFormat: String, CaseIterable, Identifiable {
    case html = "HTML", text = "Text", converse = "Converse"
    var id: Self { self }
    var contentType: UTType { self == .html ? .html : self == .text ? .plainText : ConverseExchange.contentType }
    var fileExtension: String { self == .html ? "html" : self == .text ? "txt" : ConverseExchange.fileExtension }
    func fileName(_ current: String) -> String {
        let name = current as NSString
        let base = ["html", "htm", "txt", ConverseExchange.fileExtension].contains(name.pathExtension.lowercased()) ? name.deletingPathExtension : current
        return base + "." + fileExtension
    }
}

enum TranscriptExportOrder: String, CaseIterable, Identifiable {
    case interleaved = "Interleaved by time", sequential = "One after the other"
    var id: Self { self }
}
enum TranscriptExportContent: String, CaseIterable, Identifiable {
    case prompts = "Prompts", responses = "Responses", both = "Both"
    var id: Self { self }
    func includes(_ role: String) -> Bool {
        role == "user" ? self != .responses : role == "assistant" && self != .prompts
    }
}
struct ExportSession: Identifiable {
    let id: UUID
    var title: String
    var provider: String
    var messages: [Message]
    var remoteID: String? = nil
    var isParkingLot = false
    var engine = ""
    var isAgent = false
    // A local lot's own rows, for the Converse format. Remote lots export as transcripts.
    var lotDocument: ParkingLotDocument? = nil
    init(_ session: Session) { id = session.id; title = session.title; provider = session.entry.name; messages = session.messages; engine = session.entry.engine; isAgent = session.isAgentSession }
    init(lot: ParkingLotStore) {
        id = lot.id; title = lot.name; provider = "Parking Lot"; messages = lot.exportMessages; isParkingLot = true; engine = "parking"; lotDocument = lot.document
    }
    init(row: DeviceSidebarRow, home: String, id: UUID) {
        self.id = id; title = row.title + " · " + home; provider = row.assistant
        messages = []; remoteID = row.globalID; isParkingLot = row.engine == "parking"; engine = row.engine; isAgent = row.engine == "agent"
    }
    /// A copy with titles, text and lot rows scrubbed; images dropped unless included.
    func scrubbed(_ scrubber: inout ExportScrubber, includeImages: Bool) -> ExportSession {
        var copy = self
        copy.title = scrubber.scrub(title); copy.provider = scrubber.scrub(provider)
        copy.messages = messages.map { message in
            var clean = message; clean.text = scrubber.scrub(message.text); if !includeImages { clean.images = [] }; return clean
        }
        return copy
    }
}
final class TranscriptExportSelection: ObservableObject {
    let sessions: [ExportSession]
    @Published var selected: Set<UUID>
    @Published var order = TranscriptExportOrder.sequential
    @Published var content = TranscriptExportContent.both
    @Published var lineNumbers = true
    @Published var format = TranscriptExportFormat.html { didSet { if format != oldValue && !scrubChosen { scrub = format == .converse } } }
    // Default on for the shareable Converse format; a deliberate choice sticks.
    @Published var scrub = false
    var scrubChosen = false
    @Published var includeImages = false
    init(sessions: [ExportSession]) { self.sessions = sessions; selected = Set(sessions.map(\.id)) }
    /// Images cannot be inspected, so scrubbing leaves them out unless asked.
    var exportsImages: Bool { !scrub || includeImages }
    var chosen: [ExportSession] { sessions.filter { selected.contains($0.id) } }
    var selectionState: NSControl.StateValue {
        let count = chosen.count
        return count == 0 ? .off : count == sessions.count ? .on : .mixed
    }
    func toggleAll() { selected = selectionState == .on ? [] : Set(sessions.map(\.id)) }
    var includesUntimedMessages: Bool { chosen.contains { $0.messages.contains { content.includes($0.role) && $0.createdAt == nil } } }
}

// Use the standard Mac checkbox so the header has a real mixed state, including
// its accessibility value, rather than drawing a checkbox-shaped button.
struct ExportSelectAllCheckbox: NSViewRepresentable {
    let state: NSControl.StateValue
    let enabled: Bool
    let action: () -> Void
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func changed(_ sender: NSButton) { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        button.allowsMixedState = true
        button.setAccessibilityLabel("Select or clear all sessions")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action; button.state = state; button.isEnabled = enabled
    }
}
struct TranscriptExportOptionsView: View {
    @ObservedObject var selection: TranscriptExportSelection
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sessions and Parking Lots").fontWeight(.semibold)
                Text("\(selection.selected.count) selected").foregroundStyle(.secondary)
                Spacer()
            }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ExportSelectAllCheckbox(state: selection.selectionState, enabled: !selection.sessions.isEmpty, action: selection.toggleAll)
                        .frame(width: 24, height: 18).help(selection.selectionState == .on ? "Clear all sessions" : "Select all sessions")
                    Text("Session").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Type / Model").frame(width: 120, alignment: .leading)
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 6)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(selection.sessions) { session in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(get: { selection.selected.contains(session.id) }, set: { enabled in
                                    if enabled { selection.selected.insert(session.id) } else { selection.selected.remove(session.id) }
                                })).toggleStyle(.checkbox).labelsHidden().frame(width: 24).accessibilityLabel("Export " + session.title)
                                Text(session.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).help(session.title)
                                Text(session.provider).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary).frame(width: 120, alignment: .leading).help(session.provider)
                            }.padding(.horizontal, 8).padding(.vertical, 4)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 100)
            }.background(.quaternary.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 5))
            Picker("Order", selection: $selection.order) {
                ForEach(TranscriptExportOrder.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.radioGroup).disabled(selection.format == .converse)
            Picker("Include", selection: $selection.content) {
                ForEach(TranscriptExportContent.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Picker("Format", selection: $selection.format) {
                ForEach(TranscriptExportFormat.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("Line numbers", isOn: $selection.lineNumbers).disabled(selection.format != .html)
            HStack(spacing: 16) {
                Toggle("Remove secrets and personal info", isOn: Binding(get: { selection.scrub }, set: { selection.scrub = $0; selection.scrubChosen = true }))
                    .help("Best-effort: replaces keys, tokens, passwords, email addresses, phone numbers, IP addresses, your name, home folder and this Group’s device names with placeholders such as [email 1].")
                Toggle("Include images (not scrubbed)", isOn: $selection.includeImages).disabled(!selection.scrub || selection.format == .text)
                    .help("Images can’t be checked for private details. Leave this off unless you have looked at them.")
            }
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if selection.order == .interleaved && selection.format != .converse && selection.includesUntimedMessages {
                Text("Older messages have no recorded times. They appear after timed messages in their original session order, labeled “Time unavailable.”").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).frame(width: 510)
    }
    private var caption: String {
        switch selection.format {
        case .html: return "Formatted HTML with embedded images. Parking Lots include every item. Drafts and tool activity are excluded."
        case .text: return "UTF-8 text preserves Markdown source; images are listed by filename. No line numbers, drafts or tool activity."
        case .converse: return "A file another Converse can import: sessions arrive as new conversations and Parking Lots as new lots. Agent settings, logins, drafts and tool activity are never included."
        }
    }
}

final class TranscriptExportController: NSObject, NSOpenSavePanelDelegate {
    let selection: TranscriptExportSelection
    let panel = NSSavePanel()
    private var formatObserver: AnyCancellable?
    var completed: (() -> Void)?
    init(sessions: [ExportSession]) { selection = TranscriptExportSelection(sessions: sessions); super.init() }
    func show(for window: NSWindow?) {
        panel.title = "Export Conversations"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "Converse Transcripts.html"
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let view = NSHostingView(rootView: TranscriptExportOptionsView(selection: selection))
        view.frame = NSRect(x: 0, y: 0, width: 510, height: 470)
        panel.accessoryView = view
        panel.delegate = self
        formatObserver = selection.$format.removeDuplicates().sink { [weak self] format in
            guard let self else { return }
            panel.allowedContentTypes = [format.contentType]
            panel.nameFieldStringValue = format.fileName(panel.nameFieldStringValue)
        }
        let finish: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .OK, let url = panel.url else { completed?(); return }
            Task { @MainActor in
            defer { completed?() }
            let progress = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
            progress.isReleasedWhenClosed = false
            progress.title = "Exporting conversations"
            progress.contentView = NSHostingView(rootView: ProgressView("Reading selected transcripts and images…").padding())
            progress.center(); progress.makeKeyAndOrderFront(nil)
            defer { progress.close() }
            do {
                var sessions: [ExportSession] = [], images: [String: Data] = [:]
                let withImages = selection.exportsImages
                for chosen in selection.chosen {
                    let loaded = try await Self.load(chosen, includeImages: selection.format != .text && withImages)
                    sessions.append(loaded.0); images.merge(loaded.1) { old, _ in old }
                }
                var scrubber = selection.scrub ? ExportScrubber(context: .current) : nil
                let document: Data
                switch selection.format {
                case .converse:
                    document = try ConverseExchange.export(sessions, content: selection.content, scrubber: &scrubber, includeImages: withImages, imageData: { images[$0] ?? Self.imageData($0) })
                case .html, .text:
                    if var active = scrubber { sessions = sessions.map { $0.scrubbed(&active, includeImages: withImages) }; scrubber = active }
                    let text = selection.format == .html
                        ? try TranscriptExport.html(sessions: sessions, order: selection.order, content: selection.content, lineNumbers: selection.lineNumbers, imageData: { images[$0] ?? Self.imageData($0) })
                        : try TranscriptExport.text(sessions: sessions, order: selection.order, content: selection.content)
                    document = Data(text.utf8)
                }
                if let scrubber {
                    progress.orderOut(nil)
                    let review = NSAlert(); review.messageText = "Review before sharing"
                    review.informativeText = ExportScrubber.describe(scrubber.counts) + " Removal is best-effort: it can miss secrets or personal details written in unusual ways" + (withImages && selection.format != .text ? ", and images are not checked" : "") + ". Read the file before you share it."
                    review.addButton(withTitle: "Save"); review.addButton(withTitle: "Cancel")
                    guard review.runModal() == .alertFirstButtonReturn else { return }
                }
                try document.write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert(); alert.messageText = "Could not export conversations"; alert.informativeText = error.localizedDescription; alert.runModal()
            }
        }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
    func panel(_ sender: Any, validate url: URL) throws {
        guard !selection.selected.isEmpty else { throw TranscriptExport.error("Select at least one session to export.") }
        guard selection.chosen.contains(where: { $0.remoteID != nil || $0.isParkingLot || $0.messages.contains { selection.content.includes($0.role) && (!$0.text.isEmpty || (!$0.images.isEmpty && selection.exportsImages)) } }) else {
            throw TranscriptExport.error("There are no submitted messages matching these options.")
        }
    }
    @MainActor static func load(_ session: ExportSession, includeImages: Bool, service: DeviceSyncService = .shared) async throws -> (ExportSession, [String: Data]) {
        guard let id = session.remoteID, let global = DeviceGlobalID(id) else { return (session, [:]) }
        var q = DeviceExportRequest(), messages: [DeviceWireMessage] = []
        while true {
            let response = await service.requestParticipant(home: global.home, action: "session.export", target: id, exportRequest: q)
            guard response.outcome == "completed", response.target == id, let page = response.exportPage,
                  page.offset == messages.count, page.total >= messages.count, page.total <= 1_000_000,
                  q.fingerprint == nil || q.fingerprint == page.fingerprint,
                  q.total == nil || q.total == page.total else { throw TranscriptExport.error(session.title + ": " + response.detail) }
            guard !page.messages.isEmpty || messages.count == page.total, messages.count + page.messages.count <= page.total else { throw TranscriptExport.error("Invalid export page from " + session.title) }
            messages += page.messages
            if messages.count == page.total { break }
            q = DeviceExportRequest(offset: messages.count, total: page.total, fingerprint: page.fingerprint)
        }
        var images: [String: Data] = [:]
        if includeImages {
            for hash in Set(messages.flatMap(\.imageHashes)).sorted() {
                var data = Data(), total: Int?
                while total == nil || data.count < total! {
                    let response = await service.requestParticipant(home: global.home, action: "session.export", target: id, exportRequest: DeviceExportRequest(offset: data.count, imageHash: hash))
                    guard response.outcome == "completed", response.target == id, let chunk = response.exportImage, let size = response.exportImageTotal,
                          size > 0, size <= 25_000_000, total == nil || total == size, !chunk.isEmpty, chunk.count <= 262144, data.count + chunk.count <= size else { throw TranscriptExport.error(session.title + ": could not export an attached image. " + response.detail) }
                    total = size; data.append(chunk)
                }
                guard DeviceBlob.sha256Hex(data) == hash, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else { throw TranscriptExport.error("Remote image failed integrity validation.") }
                images["remote-image-" + hash + ".png"] = png
            }
        }
        var result = session
        result.messages = messages.map { Message(id: $0.id, role: $0.role, text: $0.text, images: $0.imageHashes.map { "remote-image-" + $0 + ".png" }, createdAt: $0.createdAt) }
        return (result, images)
    }
    static func imageData(_ path: String) -> Data? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let root = Store.shared.folder.appendingPathComponent("Attachments").resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(root), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 25_000_000,
              let data = try? Data(contentsOf: url), let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
extension AppDelegate {
    @objc func exportTranscripts() {
        if let exporter = transcriptExporter { exporter.panel.makeKeyAndOrderFront(nil); return }
        let service = DeviceSyncService.shared
        let remote = service.homes.values.sorted { $0.deviceName < $1.deviceName }.flatMap { home in
            home.rows.map { ExportSession(row: $0, home: home.deviceName, id: service.placementID(forGlobal: $0.globalID)) }
        }
        let exporter = TranscriptExportController(sessions: Store.shared.sessions.map(ExportSession.init) + ParkingLotLibrary.shared.lots.filter(\.active).map(ExportSession.init(lot:)) + remote)
        transcriptExporter = exporter
        exporter.completed = { [weak self] in self?.transcriptExporter = nil }
        exporter.show(for: windows.first(where: { $0.0.isKeyWindow })?.0 ?? windows.last?.0)
    }
}

enum TranscriptExport {
    static func error(_ text: String) -> NSError { NSError(domain: "Converse Export", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    static func text(sessions: [ExportSession], order: TranscriptExportOrder, content: TranscriptExportContent) throws -> String {
        let selected = items(sessions: sessions, order: order, content: content)
        guard !selected.isEmpty else { throw error("There are no submitted messages matching these options.") }
        let date = DateFormatter(); date.dateStyle = .medium; date.timeStyle = .medium; date.timeZone = .current
        var output = "Converse Transcripts\n====================\n\(sessions.count) sessions · \(content.rawValue) · \(order.rawValue)\nTimes: \(TimeZone.current.identifier)\n"
        if selected.contains(where: { !$0.session.isParkingLot && $0.message.createdAt == nil }) {
            output += "Older messages without recorded times are labeled Time unavailable. When interleaved they follow timed messages in their original session order.\n"
        }
        var previousSession: UUID?
        for item in selected {
            if order == .sequential && previousSession != item.session.id {
                output += "\n\(item.session.title) · \(item.session.provider)\n" + String(repeating: "=", count: 40) + "\n"
                previousSession = item.session.id
            }
            let message = item.message
            let time = message.createdAt.map { date.string(from: $0) } ?? "Time unavailable"
            if !item.session.isParkingLot { output += "\n[\(message.role == "user" ? "Prompt" : "Response") · \(item.session.title) · \(time)]\n" }
            output += Store.visibleText(message.text) + "\n"
            for image in message.images { output += "[Attached image: \((image as NSString).lastPathComponent)]\n" }
        }
        return output
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
    static func inline(_ source: String) -> String {
        let rich = MarkdownText.inline(source)
        var output = ""
        rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attrs, range, _ in
            var text = escape((rich.string as NSString).substring(with: range))
            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) { text = "<strong>" + text + "</strong>" }
                if traits.contains(.italicFontMask) { text = "<em>" + text + "</em>" }
                if traits.contains(.fixedPitchFontMask) { text = "<code>" + text + "</code>" }
            }
            if attrs[.strikethroughStyle] != nil { text = "<s>" + text + "</s>" }
            if let url = attrs[.link] as? URL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                text = "<a href=\"" + escape(url.absoluteString) + "\" rel=\"noreferrer\">" + text + "</a>"
            }
            output += text
        }
        return output
    }
    struct Item { let session: ExportSession; let message: Message; let position: Int }
    static func items(sessions: [ExportSession], order: TranscriptExportOrder, content: TranscriptExportContent) -> [Item] {
        var result: [Item] = []
        for session in sessions {
            for message in session.messages where (session.isParkingLot || content.includes(message.role)) && (!Store.visibleText(message.text).isEmpty || !message.images.isEmpty) {
                result.append(Item(session: session, message: message, position: result.count))
            }
        }
        if order == .interleaved {
            result.sort {
                switch ($0.message.createdAt, $1.message.createdAt) {
                case let (a?, b?): return a == b ? $0.position < $1.position : a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return $0.position < $1.position
                }
            }
        }
        return result
    }
    static func html(sessions: [ExportSession], order: TranscriptExportOrder, content: TranscriptExportContent,
                     lineNumbers: Bool, imageData: (String) -> Data? = { _ in nil }) throws -> String {
        let selected = items(sessions: sessions, order: order, content: content)
        guard !selected.isEmpty else { throw error("There are no submitted messages matching these options.") }
        let date = DateFormatter(); date.dateStyle = .medium; date.timeStyle = .medium; date.timeZone = .current
        var body = ""; var number = 1; var previousSession: UUID?
        func numberCell() -> String { defer { number += 1 }; return lineNumbers ? "<span class=\"ln\">\(number)</span>" : "" }
        func row(_ html: String, extra: String = "") -> String { "<div class=\"line \(extra)\">" + numberCell() + "<div class=\"text\">" + (html.isEmpty ? "&#160;" : html) + "</div></div>" }
        for item in selected {
            if order == .sequential && previousSession != item.session.id {
                body += "<h2 class=\"session\">" + escape(item.session.title) + "<small>" + escape(item.session.provider) + "</small></h2>"
                previousSession = item.session.id
            }
            let message = item.message
            let prompt = message.role == "user"
            let time = message.createdAt.map { date.string(from: $0) } ?? "Time unavailable"
            let label = (prompt ? "Prompt" : "Response") + " · " + item.session.title
            body += "<article class=\"message \(prompt ? "prompt" : "response")\">"
            if !item.session.isParkingLot { body += "<header><b>" + escape(label) + "</b><time>" + escape(time) + "</time></header>" }
            let lines = Store.visibleText(message.text).components(separatedBy: "\n")
            var index = 0
            while index < lines.count {
                let text = lines[index]; let trimmed = text.trimmingCharacters(in: .whitespaces)
                if prompt { body += row(escape(text), extra: "literal"); index += 1; continue }
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    let fence = String(trimmed.prefix(3)); index += 1
                    while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { body += row("<code>" + escape(lines[index]) + "</code>", extra: "code-line"); index += 1 }
                    if index < lines.count { index += 1 }; continue
                }
                if index + 1 < lines.count && text.contains("|") && MarkdownText.tableDivider(lines[index + 1]) {
                    var rows = [MarkdownText.cells(text)]; index += 2
                    while index < lines.count && !lines[index].isEmpty && lines[index].contains("|") { rows.append(MarkdownText.cells(lines[index])); index += 1 }
                    body += "<div class=\"table-scroll\"><table>"
                    for (r, cells) in rows.enumerated() {
                        body += "<tr>" + (lineNumbers ? "<td class=\"ln\">\(number)</td>" : ""); number += 1
                        let tag = r == 0 ? "th" : "td"
                        for cell in cells { body += "<\(tag)>" + inline(cell) + "</\(tag)>" }
                        body += "</tr>"
                    }
                    body += "</table></div>"; continue
                }
                if let match = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                    let level = min(6, trimmed[match].filter { $0 == "#" }.count)
                    body += row("<h\(level)>" + inline(String(trimmed[match.upperBound...])) + "</h\(level)>")
                } else if trimmed.hasPrefix("> ") { body += row("<blockquote>" + inline(String(trimmed.dropFirst(2))) + "</blockquote>") }
                else if let marker = trimmed.range(of: "^(?:[-*+] |[0-9]+[.)] )", options: .regularExpression) {
                    let bullet = String(trimmed[marker]); let indent = text.prefix { $0 == " " || $0 == "\t" }.count
                    body += row("<div class=\"list-item\" style=\"margin-left:\(min(indent, 32) * 4)px\"><span class=\"bullet\">" + escape(bullet.first?.isNumber == true ? bullet : "•") + "</span>" + inline(String(trimmed[marker.upperBound...])) + "</div>")
                } else if ["---", "***", "___"].contains(trimmed) { body += row("<hr>") }
                else { body += row(inline(text)) }
                index += 1
            }
            for path in message.images {
                if let data = imageData(path) { body += row("<img alt=\"Attached image\" src=\"data:image/png;base64," + data.base64EncodedString() + "\">") }
                else { body += row("<span class=\"unavailable\">Attached image unavailable</span>") }
            }
            body += "</article>"
        }
        let untimed = selected.contains { $0.message.createdAt == nil }
        let note = untimed ? " Older messages without recorded times retain their session order after timed messages when interleaved." : ""
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <title>Converse Transcripts</title><style>
        *{box-sizing:border-box}body{margin:0;background:#f5f7fa;color:#222;font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}main{max-width:1000px;margin:auto;padding:40px 24px}h1{font-size:30px;margin:0}.summary{font-size:13px;color:#657083;margin:4px 0 30px}.session{margin:32px 0 12px;font-size:23px}.session small{display:block;font-size:13px;font-weight:400;color:#657083}.message{margin:0 0 22px;background:white;border:1px solid #dde3eb;border-radius:10px;overflow:hidden;break-inside:auto}.message header{display:flex;gap:16px;justify-content:space-between;flex-wrap:wrap;padding:10px 16px;background:#f8fafc;border-bottom:1px solid #e6eaf0;font-size:12px;color:#526174}.line{display:grid;grid-template-columns:\(lineNumbers ? "48px minmax(0,1fr)" : "minmax(0,1fr)")}.ln{background:white;color:#797979;text-align:right;font:11px/25.6px ui-monospace,monospace;padding:0 10px;user-select:none;border-right:1px solid #e6eaf0}.prompt .ln{background:#e0eeff}.text{padding:0 16px;min-width:0;overflow-wrap:anywhere;white-space:pre-wrap}.literal .text{font-style:italic}.message header+.line{padding-top:10px}.message .line:last-child{padding-bottom:10px}h1,h2,h3,h4,h5,h6,blockquote{white-space:normal}h1,h2,h3,h4,h5,h6{line-height:1.3;margin:8px 0}blockquote{margin:4px 0;border-left:3px solid #adbed6;padding-left:12px;color:#526174}code{font:14px/1.7 ui-monospace,SFMono-Regular,Consolas,monospace;background:#f1f4f8;border-radius:3px}.code-line .text{background:#f1f4f8;overflow-wrap:normal;overflow-x:auto}a{color:#175eba;text-decoration:underline}.list-item{white-space:normal;display:flex;gap:8px}.bullet{min-width:20px}img{max-width:100%;max-height:720px;object-fit:contain;margin:8px 0}.table-scroll{overflow-x:auto;padding:8px 0}table{border-collapse:collapse;width:100%}th,td{border:1px solid #dce3ed;padding:7px 12px;text-align:left;vertical-align:top}th{background:#f1f5fa}td.ln{width:48px}.unavailable{color:#7e6470;font-size:13px}hr{border:0;border-top:1px solid #ccd5e2}@media print{body{background:white}main{max-width:none;padding:0}.message{border-radius:0}.message header{break-after:avoid}tr,img{break-inside:avoid}}
        </style></head><body><main><h1>Converse Transcripts</h1><p class="summary">\(sessions.count) session\(sessions.count == 1 ? "" : "s") · \(escape(content.rawValue)) · \(escape(order.rawValue)) · Times: \(escape(TimeZone.current.identifier)).\(escape(note))</p>\(body)</main></body></html>
        """
    }
}
