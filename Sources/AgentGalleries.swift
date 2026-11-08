import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GallerySelection: Equatable {
    var assessments: Set<UUID> = []
    var portraits: Set<UUID> = []
    var monitor = false
    var isEmpty: Bool { assessments.isEmpty && portraits.isEmpty && !monitor }
    var cards: [String] {
        assessments.map { "assessment:" + $0.uuidString }.sorted() + portraits.map { "portrait:" + $0.uuidString }.sorted() + (monitor ? ["monitor"] : [])
    }
}

@MainActor final class GalleryWindows: NSObject, NSWindowDelegate {
    static let shared = GalleryWindows()
    private struct Entry { var window: NSWindow; var selection: GallerySelection?; var token: UUID }
    private var windows: [ObjectIdentifier: Entry] = [:]
    private func makeWindow(title: String, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentMinSize = NSSize(width: 360, height: 300)
        window.center()
        return window
    }
    func showPicker() {
        let window = makeWindow(title: "Galleries", width: 620, height: 480)
        window.contentMinSize = NSSize(width: 560, height: 300)
        let hosting = NSHostingView(rootView: GalleryPicker { [weak self, weak window] selection in
            guard let self else { return }
            window?.close(); self.show(selection)
        })
        hosting.sizingOptions = []; window.contentView = hosting
        windows[ObjectIdentifier(window)] = Entry(window: window, selection: nil, token: UUID())
        window.makeKeyAndOrderFront(nil)
    }
    func show(_ selection: GallerySelection) {
        guard !selection.isEmpty else { return }
        let window = makeWindow(title: "Gallery", width: 900, height: 660)
        let hosting = NSHostingView(rootView: GalleryView(selection: selection))
        hosting.sizingOptions = []; window.contentView = hosting
        windows[ObjectIdentifier(window)] = Entry(window: window, selection: selection, token: UUID())
        window.makeKeyAndOrderFront(nil); updateDemand(window)
    }
    func showAll(portraits: Bool) {
        let ids = Set(Store.shared.sessions.filter { $0.agent != nil && $0.agent?.parkingLotTalkID == nil }.map(\.id))
        show(portraits ? GallerySelection(portraits: ids) : GallerySelection(assessments: ids))
    }
    private func updateDemand(_ window: NSWindow) {
        guard let entry = windows[ObjectIdentifier(window)], let selection = entry.selection else { return }
        let visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        if visible {
            if !PortraitService.shared.subscribers.contains(entry.token) {
                PortraitService.shared.subscribe(entry.token, store: .shared, agents: selection.portraits)
            }
            if selection.monitor { HostMonitor.shared.subscribe(entry.token) }
        } else {
            PortraitService.shared.unsubscribe(entry.token); HostMonitor.shared.unsubscribe(entry.token)
        }
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { if let window = notification.object as? NSWindow { updateDemand(window) } }
    func windowDidMiniaturize(_ notification: Notification) { if let window = notification.object as? NSWindow { updateDemand(window) } }
    func windowDidDeminiaturize(_ notification: Notification) { if let window = notification.object as? NSWindow { updateDemand(window) } }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let entry = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
        PortraitService.shared.unsubscribe(entry.token); HostMonitor.shared.unsubscribe(entry.token)
    }
}

struct GalleryPicker: View {
    @ObservedObject var store = Store.shared
    @State private var selection = GallerySelection()
    var show: (GallerySelection) -> Void
    private var agents: [Session] { store.sessions.filter { $0.agent != nil && $0.agent?.parkingLotTalkID == nil } }
    private func checked(_ id: UUID, portraits: Bool) -> Binding<Bool> {
        Binding(get: { (portraits ? selection.portraits : selection.assessments).contains(id) }, set: { checked in
            if portraits { if checked { selection.portraits.insert(id) } else { selection.portraits.remove(id) } }
            else { if checked { selection.assessments.insert(id) } else { selection.assessments.remove(id) } }
        })
    }
    private func all(_ portraits: Bool) -> Binding<Bool> {
        Binding(get: {
            let ids = Set(agents.map(\.id))
            return portraits ? !ids.isEmpty && ids.isSubset(of: selection.portraits) : ids.isSubset(of: selection.assessments) && selection.monitor
        }, set: { checked in
            if portraits { selection.portraits = checked ? Set(agents.map(\.id)) : [] }
            else { selection.assessments = checked ? Set(agents.map(\.id)) : []; selection.monitor = checked }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose your gallery").font(.title2.bold())
            HStack {
                Text("Agent").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Assessments", isOn: all(false)).frame(width: 140)
                Toggle("Portraits", isOn: all(true)).frame(width: 110)
            }.toggleStyle(.checkbox)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(agents) { agent in
                        HStack {
                            Text(agent.title).frame(maxWidth: .infinity, alignment: .leading)
                            Toggle("Assessment for " + agent.title, isOn: checked(agent.id, portraits: false)).labelsHidden().frame(width: 140)
                            Toggle("Portrait for " + agent.title, isOn: checked(agent.id, portraits: true)).labelsHidden().frame(width: 110)
                        }.padding(.vertical, 9)
                        Divider()
                    }
                    HStack {
                        Label("System Monitor", systemImage: "gauge.with.dots.needle.33percent").frame(maxWidth: .infinity, alignment: .leading)
                        Toggle("System Monitor", isOn: $selection.monitor).labelsHidden().frame(width: 140)
                        Text("—").foregroundStyle(.tertiary).frame(width: 110).help("System Monitor has no portrait")
                    }.padding(.vertical, 9)
                }.toggleStyle(.checkbox)
            }
            HStack {
                Text("Each gallery opens in its own window.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show Gallery") { show(selection) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selection.isEmpty)
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GalleryView: View {
    var selection: GallerySelection
    @ObservedObject private var store = Store.shared
    @ObservedObject private var portraits = PortraitService.shared
    @State private var order: [String] = []
    @State private var expanded: String?
    @State private var dragging: String?
    @State private var notice = ""
    private var cards: [String] { order.isEmpty ? selection.cards : order }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if expanded != nil {
                    Button { expanded = nil } label: { Label("Gallery", systemImage: "square.grid.2x2") }.help("Return to grid").keyboardShortcut(.escape, modifiers: [])
                } else { Text("Gallery").font(.headline) }
                Spacer()
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh selected assessments, portraits and host metrics").accessibilityLabel("Refresh gallery")
            }.padding(12)
            Divider()
            GeometryReader { geometry in
                ScrollView {
                    if let expanded {
                        tile(expanded, expanded: true, imageHeight: max(200, geometry.size.height - 140)).padding(14).frame(minHeight: geometry.size.height, alignment: .top)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: min(320, max(240, geometry.size.width - 28)), maximum: .infinity), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                            ForEach(cards, id: \.self) { id in
                                tile(id, expanded: false)
                                    .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                                        guard let source = dragging, source != id else { return false }
                                        var items = cards
                                        guard let from = items.firstIndex(of: source), let to = items.firstIndex(of: id) else { return false }
                                        items.remove(at: from); items.insert(source, at: to); order = items; dragging = nil
                                        return true
                                    }
                            }
                        }.padding(14)
                    }
                }
            }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary).padding(8) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func session(_ key: String) -> Session? {
        guard let raw = key.split(separator: ":").last, let id = UUID(uuidString: String(raw)) else { return nil }
        return store.sessions.first { $0.id == id && $0.agent != nil }
    }
    private func move(_ key: String, by offset: Int) {
        var items = cards
        guard let index = items.firstIndex(of: key), items.indices.contains(index + offset) else { return }
        items.swapAt(index, index + offset); order = items
    }
    private func refresh() {
        for session in store.sessions {
            if selection.assessments.contains(session.id) { store.queueAssessmentRefresh(session) }
            if selection.portraits.contains(session.id) { Task { await portraits.request(session, store: store, origin: .menu, force: true) } }
        }
        if selection.monitor { HostMonitor.shared.refresh() }
    }
    @ViewBuilder private func tile(_ key: String, expanded: Bool, imageHeight: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if !expanded {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).padding(5).help("Drag to reorder")
                        .onDrag { dragging = key; return NSItemProvider(object: key as NSString) }
                        .accessibilityLabel("Reorder card")
                        .contextMenu {
                            Button("Move earlier") { move(key, by: -1) }.disabled(cards.first == key)
                            Button("Move later") { move(key, by: 1) }.disabled(cards.last == key)
                        }
                }
                Spacer()
                Button { self.expanded = expanded ? nil : key } label: {
                    Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }.buttonStyle(.plain).foregroundStyle(.secondary).help(expanded ? "Return to grid" : "Fill window").accessibilityLabel(expanded ? "Return to grid" : "Expand card")
            }
            if key == "monitor" { HostMonitorCard() }
            else if let session = session(key) {
                if key.hasPrefix("assessment:") { AgentAssessmentCard(session: session) }
                else { AgentPortraitCard(session: session, portraits: portraits, notice: $notice, imageHeight: imageHeight) }
            } else { Text("This agent is no longer available.").foregroundStyle(.secondary).padding() }
        }.padding(8).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor func gallerySelfTests(_ check: (Bool, String) -> Void) {
    // This entrypoint requires an isolated profile (enforced by main.swift).
    _ = NSApplication.shared
    let store = Store.shared
    let first = store.createAgent(title: "Release garden")
    let second = store.createAgent(title: "News desk")
    let third = store.createAgent(title: "Workshop")
    for (index, session) in [first, second, third].enumerated() {
        session.queuePaused = true; session.agent?.enabled = false
        session.agent?.assessment = AgentAssessment(summary: "Available evidence is shown with its observation time. Missing inputs remain local to their own row.", status: .onTrack,
            facts: [AgentFact(id: "work", label: "Work completed", value: "Ready for review", kind: .evidence, source: "Isolated gallery fixture", observedAt: Date()),
                    AgentAssessments.missingInput("discord", label: "Discord input", now: Date())],
            updatedAt: Date().addingTimeInterval(-Double(index) * 3600), checkedAt: Date().addingTimeInterval(-Double(index) * 3600))
    }
    let selection = GallerySelection(assessments: [first.id, second.id, third.id], monitor: true)
    check(selection.cards.count == 4 && Set(selection.cards).count == 4, "Gallery selects independent cards and host monitor")
    let output = ProcessInfo.processInfo.environment["CONVERSE_GALLERY_IMAGES"].map { URL(fileURLWithPath: $0) }
    if let output { try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
    func render<V: View>(_ view: V, name: String, width: CGFloat) {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        let until = Date().addingTimeInterval(0.3)
        while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        window.contentView?.layoutSubtreeIfNeeded()
        check(abs(hosting.bounds.width - width) < 2, "Gallery hosting view accepts \(Int(width))px horizontal resize")
        if let output, let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let bytes = bitmap.representation(using: .png, properties: [:]) { try? bytes.write(to: output.appendingPathComponent(name + ".png")) }
        }
        window.close()
    }
    render(GalleryView(selection: selection), name: "gallery-wide", width: 1100)
    render(GalleryView(selection: selection), name: "gallery-narrow", width: 390)
    render(GalleryPicker(show: { _ in }), name: "gallery-picker", width: 620)
    let a = UUID(), b = UUID()
    HostMonitor.shared.subscribe(a); HostMonitor.shared.subscribe(b)
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(HostMonitor.shared.sample.physical > 0 && HostMonitor.shared.sample.swap != nil, "Host metrics read physical memory and swap without subprocesses")
    HostMonitor.shared.unsubscribe(a); HostMonitor.shared.unsubscribe(b)
    for session in [first, second, third] { session.agent?.enabled = false }
}
