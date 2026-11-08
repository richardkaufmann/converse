import SwiftUI
import PhotosUI
import UIKit.UIGestureRecognizerSubclass
import UniformTypeIdentifiers

@main
struct ConversePadApp: App {
    @StateObject private var model = PadModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            PadRoot(model: model).background { PadTouchWatcher { model.service.noteHumanInput() } }.onAppear { model.foreground() }
                .onChange(of: phase) { _, value in
                    if value == .background { model.background() }
                    else if value == .active { model.foreground() }
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) { Button("About Converse…") { model.aboutShown = true } }
            CommandGroup(replacing: .appSettings) {
                Button("Converse Groups / Setup…") { model.connectShown = true }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Menu("New session on") {
                    ForEach(Array(model.service.homes.values).filter { $0.online && model.service.canCreateRemote($0.deviceID) }.sorted { $0.deviceName < $1.deviceName }, id: \.deviceID) { home in
                        Menu(model.service.displayName(for: home.deviceID, fallback: home.deviceName)) {
                            ForEach(["claude", "codex", "muse"], id: \.self) { provider in
                                Button(provider.capitalized) {
                                    Task { @MainActor in
                                        let result = await model.service.requestParticipant(home: home.deviceID, action: "session.create", provider: provider)
                                        if result.outcome != "completed" { model.error = result.detail }
                                    }
                                }
                            }
                        }
                    }
                }
                Menu("New agent on") {
                    ForEach(Array(model.service.homes.values).filter { $0.online && model.service.canHostAgent($0.deviceID) }.sorted { $0.deviceName < $1.deviceName }, id: \.deviceID) { home in
                        Button(model.service.displayName(for: home.deviceID, fallback: home.deviceName)) { model.newAgentHome = home.deviceID }
                    }
                }
            }
            CommandMenu("View") {
                Toggle("Show sidebar", isOn: Binding(get: { !model.state.sidebarHidden }, set: { model.state.sidebarHidden = !$0; model.persist() }))
                Toggle("Message numbers", isOn: $model.lineNumbers)
            }
            CommandGroup(replacing: .help) {
                Button("Converse Help…") { model.helpShown = true }.keyboardShortcut("?")
                Link("Report a Bug on GitHub…", destination: ConverseAbout.bugReports)
                Link("GitHub README (sign-in required)", destination: ConverseAbout.readme)
            }
        }
    }
}

// Sees every touch in the window without taking part in gesture handling.
// The keyboard is outside the window; PadModel.edit covers typing.
struct PadTouchWatcher: UIViewRepresentable {
    var touched: () -> Void
    final class Recognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var touched: () -> Void = {}
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { touched(); state = .failed }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
    final class Host: UIView {
        let recognizer = Recognizer(target: nil, action: nil)
        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.cancelsTouchesInView = false; recognizer.delaysTouchesBegan = false; recognizer.delaysTouchesEnded = false
            recognizer.delegate = recognizer
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
    func makeUIView(context: Context) -> Host { let host = Host(); host.recognizer.touched = touched; return host }
    func updateUIView(_ view: Host, context: Context) { view.recognizer.touched = touched }
}

struct PadAgentTarget: Identifiable { var id = UUID(); var home: String; var target: String? }

struct PadRoot: View {
    @ObservedObject var model: PadModel
    @ObservedObject private var service: DeviceSyncService
    @State private var agentTarget: PadAgentTarget?
    @State private var dragWidth: Double?
    @State private var closingTarget: DeviceSidebarRow?
    @State private var sessionActions: DeviceSidebarRow?
    @State private var closeInFlight = Set<String>()
    @State private var phoneSessionsShown = false
    @State private var phoneDestination: String?
    @State private var keyboardShown = false
    @AppStorage("sidebarSort") private var sidebarSort = SidebarSort.alphabetical.rawValue
    @GestureState private var resizingText = false
    @ObservedObject private var phoneKeyboard: PhoneKeyboardController
    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    init(model: PadModel) { self.model = model; self.service = model.service; self.phoneKeyboard = model.phoneKeyboard }
    var body: some View {
        GeometryReader { geometry in
            if isPhone {
                phoneLayout(availableHeight: geometry.size.height)
            } else {
            let width = PadLayout.sidebarWidth(preferred: model.state.sidebarWidth, available: geometry.size.width)
            HStack(spacing: 0) {
                if !model.state.sidebarHidden {
                    sidebar.frame(width: width)
                    PadSidebarDivider(drag: { delta in
                        if dragWidth == nil { dragWidth = width }
                        model.state.sidebarWidth = min(geometry.size.width * 0.5, max(120, (dragWidth ?? width) + delta))
                    }, end: { dragWidth = nil; model.persist() }).frame(width: PadSidebarDivider.width)
                }
                VStack(spacing: 0) {
                    HStack {
                        if model.state.sidebarHidden { pin }
                        Text("Converse").font(.headline)
                        Spacer()
                        Menu {
                            Button("Converse Groups…") { model.connectShown = true }
                            Button("Converse Help…") { model.helpShown = true }
                            Divider()
                            Button("About Converse…") { model.aboutShown = true }
                            Link("Report a Bug on GitHub…", destination: ConverseAbout.bugReports)
                            Link("GitHub README (sign-in required)", destination: ConverseAbout.readme)
                            Toggle("Line numbers", isOn: $model.lineNumbers)
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Converse menu")
                    }.padding(10)
                    Divider()
                    let assigned = model.state.placements.indices.filter { model.state.placements[$0] != nil }
                    if assigned.isEmpty {
                        ContentUnavailableView {
                            Label("Your conversations, here", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            if service.currentGroup != nil {
                                Text("Take a session here by tapping 1, 2, or 3 beside its name in the sidebar.")
                            } else {
                                Text("Join a Converse group, then tap 1, 2 or 3 beside a session. Models and logins stay on its home computer.")
                            }
                        } actions: {
                            if service.currentGroup == nil {
                                Button("Converse Groups") { model.connectShown = true }.buttonStyle(.borderedProminent)
                            } else if model.state.sidebarHidden {
                                Button("Show sessions") { model.state.sidebarHidden = false; model.persist() }.buttonStyle(.borderedProminent)
                            }
                        }
                    } else if geometry.size.width - (model.state.sidebarHidden ? 0 : width + PadSidebarDivider.width) >= CGFloat(assigned.count) * 360 {
                        HStack(spacing: 0) {
                            ForEach(assigned, id: \.self) { pane in
                                if pane != assigned.first { Divider() }
                                PadPane(id: model.state.placements[pane]!, pane: pane, model: model)
                            }
                        }
                    } else {
                        if assigned.count > 1 {
                            Picker("Visible pane", selection: $model.focusedPane) {
                                ForEach(assigned, id: \.self) { pane in Text("\(pane + 1) · " + (service.remoteRow(globalID: model.state.placements[pane]!)?.title ?? "Session")).tag(pane) }
                            }.pickerStyle(.segmented).padding(6)
                        }
                        let visible = assigned.contains(model.focusedPane) ? model.focusedPane : assigned[0]
                        PadPane(id: model.state.placements[visible]!, pane: visible, model: model).id(model.state.placements[visible])
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(Color(uiColor: .systemBackground))
            }
        }
        .simultaneousGesture(MagnifyGesture(minimumScaleDelta: 0.04)
            .updating($resizingText) { _, active, _ in active = true }
            .onChanged { model.pinchText($0.magnification) }
            .onEnded { model.pinchText($0.magnification); model.endTextPinch() })
        .onChange(of: resizingText) { _, active in if !active { model.endTextPinch() } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardShown = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardShown = false }
        .sheet(isPresented: $phoneSessionsShown, onDismiss: {
            let destination = phoneDestination; phoneDestination = nil
            switch destination {
            case "groups": model.connectShown = true
            case "help": model.helpShown = true
            case "about": model.aboutShown = true
            default: break
            }
        }) {
            PhoneSessionPicker(model: model) { action in
                phoneDestination = action; phoneSessionsShown = false
            }
        }
        .onChange(of: service.groupRequests) { old, requests in
            let previous = Set(old.map(\.id))
            if requests.contains(where: { !$0.approved && !previous.contains($0.id) }) { model.connectShown = true }
        }
        .alert("Close ‘" + (closingTarget?.title ?? "session") + "’ on its home?", isPresented: Binding(get: { closingTarget != nil }, set: { if !$0 { closingTarget = nil } }), presenting: closingTarget) { row in
            Button("Cancel", role: .cancel) { closingTarget = nil }
            Button("Close session", role: .destructive) {
                closeInFlight.insert(row.globalID); closingTarget = nil
                Task { @MainActor in
                    let result = await service.closeRemoteSession(row.globalID)
                    closeInFlight.remove(row.globalID)
                    if result.outcome != "completed" { model.error = result.detail }
                }
            }
        } message: { _ in Text("Stops its work and removes the session from every viewer. A recovery snapshot stays on its home.") }
        .sheet(isPresented: $model.connectShown) { PadConnect(model: model) }
        .sheet(isPresented: $model.helpShown) { PadHelp() }
            .sheet(isPresented: $model.aboutShown) { PadAbout() }
            .sheet(item: $sessionActions) { row in PadSessionActions(row: row, park: { model.park(row.globalID) }) }
        .sheet(isPresented: Binding(get: { model.newAgentHome != nil }, set: { if !$0 { model.newAgentHome = nil } })) {
            if let home = model.newAgentHome { PadAgentPanel(home: home, target: nil) }
        }
        .sheet(item: $agentTarget) { PadAgentPanel(home: $0.home, target: $0.target) }
        .alert("Converse", isPresented: Binding(get: { !model.error.isEmpty }, set: { if !$0 { model.error = "" } })) { Button("OK") { model.error = "" } } message: { Text(model.error) }
    }
    private func phoneLayout(availableHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Converse").font(.headline)
                Spacer()
                let visible = model.state.placements.indices.filter { model.state.placements[$0] != nil }
                let selected = visible.contains(model.focusedPane) ? model.focusedPane : visible.first
                let session = selected.flatMap { model.state.placements[$0] }
                Button {
                    if phoneKeyboard.isRequested { phoneKeyboard.hide() }
                    else if let session { phoneKeyboard.show(session) }
                } label: {
                    Label(phoneKeyboard.isRequested ? "Hide keyboard" : "Show keyboard",
                          systemImage: phoneKeyboard.isRequested ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.subheadline).frame(minHeight: 44)
                }.disabled(!phoneKeyboard.isRequested && !(session.map { model.canControl($0) } ?? false))
                    .accessibilityIdentifier("phone-keyboard-toggle")
                Button { phoneKeyboard.hide(); phoneSessionsShown = true } label: {
                    Image(systemName: "rectangle.stack").foregroundStyle(.secondary).frame(width: 44, height: 44)
                }.accessibilityLabel("Choose sessions and app options")
            }.padding(.horizontal, 12)
            Divider()
            let assigned = model.state.placements.indices.filter { model.state.placements[$0] != nil }
            if assigned.isEmpty {
                ContentUnavailableView {
                    Label("Your conversations, here", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Choose one or two sessions. They run on your computers and appear here.")
                } actions: {
                    Button(service.currentGroup == nil ? "Pair a computer" : "Choose sessions") {
                        if service.currentGroup == nil { model.connectShown = true } else { phoneSessionsShown = true }
                    }.buttonStyle(.borderedProminent)
                }
            } else {
                let focused = assigned.contains(model.focusedPane) ? model.focusedPane : assigned[0]
                VStack(spacing: 0) {
                    ForEach(assigned, id: \.self) { pane in
                        let id = model.state.placements[pane]!
                        if pane != assigned.first { Divider().overlay(Color.secondary.opacity(0.3)) }
                        let collapsed = (phoneKeyboard.isRequested || keyboardShown || availableHeight < 500) && pane != focused
                        VStack(spacing: 0) {
                        if collapsed {
                            Button {
                                model.focusedPane = pane
                                phoneKeyboard.select(id)
                            } label: {
                                HStack {
                                    Text(String(pane + 1)).font(.caption.bold())
                                    Text(service.remoteRow(globalID: id)?.title ?? "Session").lineLimit(1)
                                    PadSessionActivity(id: id, service: service)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                                }.padding(.horizontal, 12).frame(minHeight: 44)
                            }.buttonStyle(.plain).accessibilityLabel("Show " + (service.remoteRow(globalID: id)?.title ?? "session"))
                        }
                        // Keep the native editor mounted during focus changes. Removing
                        // it here also removes its first responder and hides the keyboard.
                        PadPane(id: id, pane: pane, model: model)
                            .frame(maxHeight: .infinity)
                            .frame(height: collapsed ? 0 : nil)
                            .clipped().allowsHitTesting(!collapsed).accessibilityHidden(collapsed)
                        }.frame(maxHeight: collapsed ? nil : .infinity)
                    }
                }
            }
        }.background(Color(uiColor: .systemBackground))
    }
    var pin: some View {
        Button {
            model.state.sidebarHidden.toggle(); model.persist()
        } label: { Image(systemName: model.state.sidebarHidden ? "pin" : "pin.fill").frame(width: 30, height: 30) }
            .accessibilityLabel(model.state.sidebarHidden ? "Show conversation sidebar" : "Hide conversation sidebar")
    }
    var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) { pin; Text("Conversation").font(.caption).foregroundStyle(.secondary); Spacer(); PadSortMenu(sort: $sidebarSort); Button { model.connectShown = true } label: { Image(systemName: "network") }.accessibilityLabel("Converse Groups") }.padding(6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if let group = service.currentGroup { Text(group.name + " group").font(.title2.weight(.semibold)).foregroundStyle(Color.accentColor).padding(.top, 6).help("Devices sharing sessions in " + group.name) }
                    ForEach((service.currentGroup == nil ? [] : Array(service.homes.values)).sorted { $0.deviceName < $1.deviceName }, id: \.deviceID) { home in
                        if home.online {
                        HStack { DeviceDisplayLabel(service: service, deviceID: home.deviceID, fallback: home.deviceName).fontWeight(.bold).foregroundStyle(Color.green).lineLimit(1); Text("remote").font(.caption).foregroundStyle(.secondary)
                            if service.canCreateRemote(home.deviceID) || service.canHostAgent(home.deviceID) {
                                Menu {
                                    if service.canCreateRemote(home.deviceID) {
                                        ForEach(["claude", "codex", "muse"], id: \.self) { provider in
                                            Button("New " + provider.capitalized + " session") {
                                                Task { @MainActor in
                                                    let result = await service.requestParticipant(home: home.deviceID, action: "session.create", provider: provider)
                                                    if result.outcome != "completed" { model.error = result.detail }
                                                }
                                            }
                                        }
                                    }
                                    if service.canHostAgent(home.deviceID) { Button("New agent…") { agentTarget = PadAgentTarget(home: home.deviceID, target: nil) } }
                                } label: { Image(systemName: "plus") }
                                .accessibilityLabel("Create session on " + home.deviceName)
                            }
                        }.padding(.top, 10)
                        if home.rows.isEmpty { Text("No sessions available.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8) }
                        ForEach(SidebarSort.rows(home.rows, by: SidebarSort(rawValue: sidebarSort) ?? .alphabetical)) { row in
                            let pane = model.state.placements.firstIndex(of: row.globalID)
                            let attention = !(row.attention ?? "").isEmpty || (row.status.hasPrefix("Waiting") && pane == nil)
                            let markers = service.remoteMarkers(row)
                            HStack(spacing: 3) {
                                if row.busy && home.online { ProgressView().controlSize(.mini).frame(width: 14) }
                                else if markers.paused || (markers.unseen && !attention) { PadRowMarker(markers: markers).frame(width: 14) }
                                else { Text(attention ? "!" : "").bold().frame(width: 14) }
                                Button { sessionActions = row } label: {
                                    PadSessionName(title: row.title, isAgent: row.isAgentRow, isParkingLot: row.engine == "parking", isPaused: markers.paused, unread: markers.unseen).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Actions for " + row.title + PadRowMarker.spoken(markers))
                                    .simultaneousGesture(LongPressGesture().onEnded { _ in sessionActions = row })
                                PadProviderLogo(engine: row.engine).frame(width: 24).help(row.model)
                                HStack(spacing: 3) {
                                    placementButton("P", selected: pane == nil) { model.park(row.globalID) }
                                    ForEach(0..<3) { index in placementButton(String(index + 1), selected: pane == index) { model.assign(row.globalID, pane: index) } }
                                    if row.engine == "parking" { Color.clear.frame(width: 24) } else {
                                        placementButton("X", selected: false) { closingTarget = row }
                                            .disabled(closeInFlight.contains(row.globalID) || !service.canCloseRemote(home.deviceID)).accessibilityLabel("Close " + row.title + " on home")
                                    }
                                }.frame(width: 132).fixedSize(horizontal: true, vertical: false).disabled(!home.online)
                            }.font(.system(size: 13)).padding(.vertical, 4).padding(.horizontal, 3)
                                .background(attention ? Color.yellow.opacity(0.65) : (pane == nil ? .clear : Color.accentColor.opacity(0.07)))
                                .accessibilityElement(children: .contain)
                        }
                        } else { DeviceDisplayLabel(service: service, deviceID: home.deviceID, fallback: home.deviceName).fontWeight(.bold).foregroundStyle(Color.green.opacity(0.4)).padding(.top, 10) }
                    }
                    if service.homes.isEmpty { Text("Join a Converse group to see its devices and sessions.").font(.callout).foregroundStyle(.secondary).padding(10) }
                }.padding(.horizontal, 5)
            }
            Button("Converse Groups") { model.connectShown = true }.padding(8)
            Text(service.serviceStatus).font(.caption2).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    func placementButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(selected ? .white : .primary).frame(width: 24, height: 28).background(selected ? Color.green.opacity(0.9) : Color(uiColor: .systemBackground)).clipShape(RoundedRectangle(cornerRadius: 3)).overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.3), lineWidth: 0.5)) }.buttonStyle(.plain)
    }
}

/// A sheet keeps controls reachable without spending transcript width on a sidebar.
struct PhoneSessionPicker: View {
    @ObservedObject var model: PadModel
    @ObservedObject private var service: DeviceSyncService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sidebarSort") private var sidebarSort = SidebarSort.alphabetical.rawValue
    var open: (String) -> Void
    init(model: PadModel, open: @escaping (String) -> Void) { self.model = model; self.service = model.service; self.open = open }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select up to two sessions. Two sessions stack vertically. Deselecting parks the display; work continues on its home.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(service.homes.values).sorted { $0.deviceName < $1.deviceName }, id: \.deviceID) { home in
                    Section {
                        ForEach(SidebarSort.rows(home.rows, by: SidebarSort(rawValue: sidebarSort) ?? .alphabetical)) { row in
                            let selected = model.state.placements.contains(row.globalID)
                            let markers = service.remoteMarkers(row)
                            Button { model.togglePhoneSession(row.globalID) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary)
                                    PadRowMarker(markers: markers).frame(width: 14)
                                    VStack(alignment: .leading, spacing: 3) {
                                        PadSessionName(title: row.title, isAgent: row.isAgentRow, isParkingLot: row.engine == "parking", isPaused: markers.paused, unread: markers.unseen)
                                        Text(row.status).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    PadProviderLogo(engine: row.engine)
                                }.frame(minHeight: 40).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .disabled(!selected && (!home.online || model.state.placements.compactMap { $0 }.count >= 2))
                                .accessibilityLabel((selected ? "Deselect " : "Select ") + row.title + PadRowMarker.spoken(markers))
                                .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                        if home.online && service.canCreateRemote(home.deviceID) {
                            Menu("New session") {
                                ForEach(["claude", "codex", "muse"], id: \.self) { provider in
                                    Button(provider.capitalized) {
                                        Task { @MainActor in
                                            let result = await service.requestParticipant(home: home.deviceID, action: "session.create", provider: provider)
                                            if result.outcome != "completed" { model.error = result.detail }
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            DeviceDisplayLabel(service: service, deviceID: home.deviceID, fallback: home.deviceName)
                            if !home.online { Text("offline") }
                        }
                    }
                }
                Section("Converse") {
                    Button("Groups / Pair a computer…") { open("groups") }
                    Button("Help…") { open("help") }
                    Button("About Converse…") { open("about") }
                    Toggle("Message numbers", isOn: $model.lineNumbers)
                    Link("Report a Bug on GitHub…", destination: ConverseAbout.bugReports)
                    Link("GitHub README (sign-in required)", destination: ConverseAbout.readme)
                }
            }.navigationTitle("Sessions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// Turn state comes from the home, including turns producing no text yet.
/// The ˯ beside the sidebar title: session order, shared with the iPhone picker.
struct PadSortMenu: View {
    @Binding var sort: String
    var body: some View {
        Menu {
            Picker("Sort sessions", selection: $sort) {
                ForEach([SidebarSort.alphabetical, .recent], id: \.self) { Text($0.title).tag($0.rawValue) }
            }
        } label: { Image(systemName: "chevron.down").frame(width: 30, height: 30) }
            .accessibilityLabel("Sort sessions")
    }
}

struct PadSessionActivity: View {
    let id: String
    @ObservedObject var service: DeviceSyncService
    var body: some View {
        let snapshot = service.remoteTranscripts[id]
        let row = service.remoteRow(globalID: id)
        let offline = service.remoteOffline.contains(id) || DeviceGlobalID(id).flatMap { service.homes[$0.home] }?.online == false
        if !offline && (snapshot?.busy ?? row?.busy ?? false) {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Working").font(.caption)
            }.fixedSize().accessibilityElement(children: .ignore)
                .accessibilityLabel("Working. " + (snapshot?.status ?? row?.status ?? ""))
                .accessibilityIdentifier("session-working")
        }
    }
}

struct PadPane: View {
    let id: String
    let pane: Int
    @ObservedObject var model: PadModel
    @ObservedObject private var service: DeviceSyncService
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var imageTools = false
    @State private var imageToolsHash: String?
    @State private var sessionActions: DeviceSidebarRow?
    @State private var scoreboardExpanded = false
    @State private var editingModel = false
    @State private var customModel = ""
    var snapshot: DeviceTranscriptPayload? { service.remoteTranscripts[id] }
    init(id: String, pane: Int, model: PadModel) { self.id = id; self.pane = pane; self.model = model; self.service = model.service }
    var body: some View {
        if model.isParkingLot(id) { PadLotPane(id: id, pane: pane, model: model) } else { sessionBody }
    }
    var sessionBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(pane + 1)).font(.caption.bold()).foregroundStyle(.white).padding(5).background(.green, in: RoundedRectangle(cornerRadius: 3))
                PadProviderLogo(engine: snapshot?.engine.isEmpty == false ? snapshot!.engine : service.remoteRow(globalID: id)?.engine ?? "")
                PadSessionName(title: snapshot?.title ?? service.remoteRow(globalID: id)?.title ?? "Session", isAgent: service.remoteRow(globalID: id)?.isAgentRow == true, isPaused: service.remoteRow(globalID: id)?.showsLoopPaused == true).font(UIDevice.current.userInterfaceIdiom == .phone ? .headline : .title3).lineLimit(1).truncationMode(.tail)
                PadSessionActivity(id: id, service: service)
                Spacer(minLength: 0)
                Button { sessionActions = service.remoteRow(globalID: id) } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }.fixedSize().accessibilityLabel("Session actions")
                    .disabled(service.remoteRow(globalID: id) == nil)
                    .sheet(item: $sessionActions) { row in
                        PadSessionActions(row: row, park: { model.park(id) }, showScoreboard: snapshot?.agentWidget == nil ? nil : { scoreboardExpanded = true })
                    }
                Button("P") { model.park(id) }.accessibilityLabel("Park this conversation")
            }.padding(8)
            Divider()
            if service.remoteDisplayReconnecting(id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reconnecting…")
                    Spacer()
                }.font(.callout).padding(10).foregroundStyle(.secondary)
                    .accessibilityIdentifier("session-reconnecting")
            } else if !model.canControl(id) {
                HStack {
                    Text(service.remoteOffline.contains(id) ? "Home offline. Your draft is preserved." : "Take this session to edit and send.")
                    Spacer(); Button("Take here") { service.acquireRemote(globalID: id) }
                }.font(.callout).padding(10).background(Color.orange.opacity(0.18))
            }
            if model.conflicts.contains(id) {
                VStack(alignment: .leading) {
                    Text("Recovered draft differs from the home draft. Both are preserved; choose which to edit.").font(.caption)
                    HStack { Button("Keep my recovered draft") { model.resolveDraft(id, keepLocal: true) }; Button("Use home draft") { model.resolveDraft(id, keepLocal: false) } }
                }.padding(8).background(Color.yellow.opacity(0.3))
            }
            if let widget = snapshot?.agentWidget {
                DisclosureGroup("Agent assessment", isExpanded: $scoreboardExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let hash = widget.artHash, let file = service.blobCache[hash], let image = UIImage(contentsOfFile: file.path) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180) }
                        if let line = widget.assessmentLine { Text(line).font(.caption.bold()) }
                        Text(widget.summary).font(.caption).textSelection(.enabled)
                        Text(widget.metrics.map { $0.label + ": " + $0.value }.joined(separator: " · ")).font(.caption).textSelection(.enabled)
                    }
                }.padding(8)
                if !widget.attention.isEmpty { Label(widget.attention, systemImage: "exclamationmark.triangle.fill").padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.yellow).foregroundStyle(.black) }
            }
            if let request = snapshot?.requests.first { PadRequest(id: id, request: request).disabled(!model.canControl(id)) }
            if let snapshot, !snapshot.pending.isEmpty {
                PadQueue(pending: snapshot.pending, paused: snapshot.queuePaused, canRemove: service.canRemoveQueuedRemote(id)) { service.sendRemoteCommand(globalID: id, command: $0) }
                    .disabled(!model.canControl(id))
            }
            if let conflict = service.draftConflicts[id] {
                Text(conflict).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.15))
            }
            if let record = model.pending(id) {
                HStack {
                    Text("Send: " + record.outcome).font(.caption); Spacer()
                    if record.outcome == "uncertain" { Button("Check home") { service.queryOutbox(record) } }
                    if record.outcome == "failed" || record.outcome == "rejected" { Button("Restore") { model.discard(record, restore: true) } }
                    if ["pending", "accepted", "running"].contains(record.outcome) { Button("Check home") { service.queryOutbox(record) } }
                    else { Button("Discard") { model.discard(record, restore: false) } }
                }.padding(8).background(Color.orange.opacity(0.12))
            }
            if let snapshot, snapshot.offset > 0 { Button("Load \(snapshot.offset) earlier messages") { service.requestEarlier(globalID: id) }.font(.caption).padding(4) }
            PadTranscript(messages: snapshot?.messages ?? [], draft: model.draft(id).text, images: service.blobCache, draftImageHashes: model.draft(id).hashes, editable: model.canControl(id), lineNumbers: model.lineNumbers, displayEpoch: service.remoteLeases[id],
                          edit: { model.edit(id, text: $0) }, send: { model.send(id) }, attach: { model.attach(id, data: $0) }, removeImage: { model.removeImage(id, hash: $0) }, pasteError: { model.error = $0 }, imageTools: { originalHash, bytes in
                              let existing = originalHash.flatMap { model.draft(id).hashes.contains($0) ? $0 : nil }
                              if let hash = existing ?? model.attach(id, data: bytes) { imageToolsHash = hash; imageTools = true }
                          }, didFocus: { model.focusedPane = pane; if UIDevice.current.userInterfaceIdiom == .phone { model.phoneKeyboard.select(id) } },
                          phoneKeyboard: UIDevice.current.userInterfaceIdiom == .phone ? model.phoneKeyboard : nil,
                          keyboardSession: id, textSize: model.textSize(pane),
                          beganEditing: { model.cursorPane = pane }, endedEditing: { model.endedEditing(pane: pane) })
                .overlay(alignment: .bottomTrailing) {
                    if let state = snapshot?.compaction, state.visible {
                        Button(state.title) { command(state.phase == "queued" ? "cancelCompact" : "compact") }
                            .buttonStyle(.borderedProminent).tint(state.phase == "available" ? .yellow : .gray).foregroundStyle(.black)
                            .font(.caption).help(state.detail).accessibilityHint(state.detail)
                            .disabled(!model.canControl(id) || state.phase == "running").padding(.trailing, 12).padding(.bottom, 46)
                    }
                }
            Divider()
            if let status = snapshot?.agentWidget?.loopStatus { Text(status).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(6) }
            if let snapshot {
                ViewThatFits(in: .horizontal) {
                    HStack { settings(snapshot); Spacer(); Text(snapshot.status).font(.caption).foregroundStyle(.secondary) }
                    settings(snapshot)
                }.padding(.horizontal, 8).padding(.vertical, 4)
            }
            if !model.draft(id).hashes.isEmpty {
                Text(model.draft(id).hashes.allSatisfy { service.blobReady[$0] == true } ? "Images stored on home." : "Uploading images; Send waits for home storage.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            if service.lastOutcome.hasPrefix("failed") || service.lastOutcome.hasPrefix("Attachment failed") {
                Text(service.lastOutcome).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(8)
            }
            HStack {
                PasteButton(supportedContentTypes: [.image]) { providers in
                    let destination = id
                    Task { @MainActor in
                        do {
                            for provider in providers { model.attach(destination, data: try await PadClipboard.imageData(from: provider)) }
                        } catch { model.error = "Could not paste image: " + error.localizedDescription }
                    }
                }.labelStyle(.iconOnly).accessibilityLabel("Paste clipboard image")
                PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo") }.accessibilityLabel("Choose image from Photos")
                Button { importing = true } label: { Image(systemName: "paperclip") }.accessibilityLabel("Attach image file")
                if !model.draft(id).hashes.isEmpty {
                    Button { imageToolsHash = nil; imageTools = true } label: { Image(systemName: "wand.and.stars") }.accessibilityLabel("Image tools")
                    Text("\(model.draft(id).hashes.count) images").font(.caption)
                }
                Spacer()
                if snapshot?.busy == true { Button("Stop") { command("stop") } }
                Button(snapshot?.busy == true ? "Queue" : "Send") { model.send(id) }.buttonStyle(.borderedProminent).disabled(!model.canSend(id))
            }.padding(8).disabled(!model.canControl(id))
        }.background(Color(uiColor: .systemBackground)).frame(maxWidth: .infinity, maxHeight: .infinity)
            .alert("Set model on home", isPresented: $editingModel) {
                TextField("Model ID", text: $customModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    let value = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "model", model: value.isEmpty ? nil : value))
                }.disabled(!model.canControl(id))
            } message: { Text("Enter the provider's model ID. Leave blank for the CLI default. Applies on the home device to the next turn.") }
            .onChange(of: photo) { _, value in
                guard let value else { return }
                let destination = id
                Task {
                    do {
                        if let bytes = try await value.loadTransferable(type: Data.self), photo == value, id == destination {
                            model.attach(destination, data: bytes)
                        }
                    } catch { model.error = error.localizedDescription }
                    if photo == value { photo = nil }
                }
            }
            .sheet(isPresented: $imageTools) { PadImageTools(id: id, model: model, initialHash: imageToolsHash) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 50_000_000 else { throw CocoaError(.fileReadTooLarge) }
                    model.attach(id, data: try Data(contentsOf: url))
                } catch { model.error = error.localizedDescription }
            }
    }
    func command(_ action: String) { service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: action)) }
    func settings(_ snapshot: DeviceTranscriptPayload) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { remoteSettings(snapshot); compactAction(snapshot) }.fixedSize(horizontal: true, vertical: false)
            HStack {
                Spacer(minLength: 0)
                Menu { remoteSettings(snapshot); compactAction(snapshot) } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Session settings")
            }
        }.font(.caption).disabled(!model.canControl(id))
    }
    @ViewBuilder func compactAction(_ snapshot: DeviceTranscriptPayload) -> some View {
        if let state = snapshot.compaction {
            Button(snapshot.busy ? "Compact after this turn" : "Compact context") { command("compact") }.disabled(state.phase != "available")
        }
    }
    @ViewBuilder func remoteSettings(_ snapshot: DeviceTranscriptPayload) -> some View {
        Menu(snapshot.model.isEmpty ? "Model: CLI default" : snapshot.model) {
            if snapshot.engine != "muse" {
            Button("CLI default") { service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "model")) }
            }
            ForEach(snapshot.modelOptions) { option in
                Button(option.label) { service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "model", model: option.id, modelProvider: option.provider, modelProfile: option.profile)) }
            }
            Button("Custom model…") { customModel = snapshot.model; editingModel = true }
        }
        Menu(snapshot.effort.isEmpty ? "Effort: CLI default" : "Effort: " + snapshot.effort) {
            if snapshot.engine != "muse" {
            Button("CLI default") { service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "effort")) }
            }
            ForEach(snapshot.effortOptions, id: \.self) { value in
                Button(value) { service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "effort", effort: value)) }
            }
        }
        Menu(snapshot.access.isEmpty ? "Permissions: CLI default" : (snapshot.accessOptions.first { $0.id == snapshot.access }?.label ?? snapshot.access)) {
            if snapshot.engine != "muse" {
            Button("CLI default") { service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "access")) }
            }
            if snapshot.engine == "codex" { Text("Ask for approval requires interactive Codex support") }
            ForEach(snapshot.accessOptions) { option in
                Button(option.label) { service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "access", access: option.id)) }
            }
        }
    }

}

// Queued input on the home. Per-item Remove appears only when the home
// advertises queue-remove-v1; older homes keep Clear all. Inline buttons,
// not a context menu: the queue updates live under the pointer.
struct PadQueue: View {
    struct Action: Identifiable { let label: String; let command: DeviceCommandPayload; var id: String { label } }
    static let clearAll = "Clear all"
    let pending: [DevicePendingDTO]
    let paused: Bool
    let canRemove: Bool
    let send: (DeviceCommandPayload) -> Void
    var bulkActions: [Action] {
        [Action(label: paused ? "Resume" : "Pause", command: DeviceCommandPayload(action: paused ? "resumeQueue" : "pauseQueue"))]
            + (pending.count > 1 ? [Action(label: "Inject all", command: DeviceCommandPayload(action: "injectAll"))] : [])
            + [Action(label: Self.clearAll, command: DeviceCommandPayload(action: "clearQueue"))]
    }
    func itemActions(_ item: DevicePendingDTO) -> [Action] {
        [Action(label: "Inject now", command: DeviceCommandPayload(action: "inject", pendingID: item.id))]
            + (canRemove ? [Action(label: "Remove", command: DeviceCommandPayload(action: "removeQueued", pendingID: item.id))] : [])
    }
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("\(pending.count) queued"); Spacer()
                ForEach(bulkActions) { action in Button(action.label) { send(action.command) } }
            }
            ForEach(pending) { item in
                HStack {
                    Text(TranscriptStyle.queueSummary(item.text, components: item.components) ?? item.text).help(item.text).foregroundStyle(TranscriptStyle.queueSummary(item.text, components: item.components) != nil ? Color(uiColor: PadPalette.traffic) : Color.primary).lineLimit(1)
                    Spacer()
                    ForEach(itemActions(item)) { action in Button(action.label, role: action.command.action == "removeQueued" ? .destructive : nil) { send(action.command) } }
                }
            }
        }.font(.caption).padding(8).background(Color.blue.opacity(0.06))
    }
}

// A snapshot-backed sheet keeps actions stationary while sidebar/status updates
// arrive. Native context menus rebuilt from live row text can move under a pointer.
struct PadSessionActions: View {
    let row: DeviceSidebarRow
    var park: () -> Void
    var showScoreboard: (() -> Void)? = nil
    @ObservedObject private var service = DeviceSyncService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var renameShown = false
    @State private var agentSetupShown = false
    @State private var teachingID: UUID?
    @State private var running = false
    @State private var error: String?
    private var home: String { DeviceGlobalID(row.globalID)?.home ?? "" }
    private var isAgent: Bool { row.participantKind == "agent" || row.engine == "agent" }
    var body: some View {
        NavigationStack {
            Form {
                Section("Actions") {
                    Button("Rename…") { renameShown = true }.disabled(row.engine == "parking" || !service.canRenameRemote(home))
                    Button("Teach / Refresh Switchboard Instructions") {
                        teachingID = service.sendRemoteCommand(globalID: row.globalID, command: DeviceCommandPayload(action: "teachSwitchboard"))
                        if teachingID == nil { error = "Could not queue instructions. Check that the session's home is connected." }
                    }.disabled(!service.canTeachRemote(row.globalID) || teachingID != nil)
                    if isAgent {
                        Button("Agent Setup / Loop…") { agentSetupShown = true }.disabled(!service.canHostAgent(home))
                        Button("Run once") { runAgent() }.disabled(running || service.remoteRow(globalID: row.globalID)?.busy == true || !service.canHostAgent(home))
                        Button("Assessment") { showScoreboard?(); dismiss() }.disabled(showScoreboard == nil)
                    }
                    Button("Park") { park(); dismiss() }
                }
                Section {
                    Text("Teaching queues the current rules on home and preserves your draft. Close this panel and use Inject now on the queued instructions to interrupt a busy turn.")
                    if teachingID != nil { Text("Instructions requested. Check the session queue for delivery.").foregroundStyle(.secondary) }
                }
                Section("Session") {
                    LabeledContent("Name", value: row.title)
                    LabeledContent("Home", value: service.displayName(for: home))
                    LabeledContent("Account", value: row.accountName ?? "Not reported")
                    LabeledContent("Model", value: row.model)
                    LabeledContent("Status when opened", value: row.status)
                    if let warning = row.attention, !warning.isEmpty { Text(warning) }
                }
            }
            .navigationTitle("Session actions").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $renameShown) { PadRenameSession(row: row) }
            .sheet(isPresented: $agentSetupShown) { PadAgentPanel(home: home, target: row.globalID) }
            .alert("Session action failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private func runAgent() {
        running = true
        Task { @MainActor in
            let result = await service.requestParticipant(home: home, action: "agent.run", target: row.globalID)
            running = false
            if result.outcome != "completed" { error = result.detail }
        }
    }
}


struct PadSidebarDivider: UIViewRepresentable {
    static let width: CGFloat = 22
    var drag: (CGFloat) -> Void
    var end: () -> Void
    func makeUIView(context: Context) -> PadResizeHandle { PadResizeHandle() }
    func updateUIView(_ view: PadResizeHandle, context: Context) { view.drag = drag; view.end = end }
}

final class PadResizeHandle: UIView, UIPointerInteractionDelegate {
    var drag: (CGFloat) -> Void = { _ in }
    var end: () -> Void = {}
    private var highlighted = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        addInteraction(UIPointerInteraction(delegate: self))
        isAccessibilityElement = true; accessibilityLabel = "Resize conversation sidebar"
        accessibilityHint = "Drag left or right to resize"; accessibilityTraits = .adjustable
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        UIColor.separator.setFill(); UIRectFill(CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height))
        (highlighted ? UIColor.systemBlue : UIColor.secondaryLabel).setFill()
        UIBezierPath(roundedRect: CGRect(x: bounds.midX - 2, y: bounds.midY - 22, width: 4, height: 44), cornerRadius: 2).fill()
    }
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed: highlighted = true; drag(gesture.translation(in: window).x)
        case .ended, .cancelled, .failed: highlighted = false; end()
        default: break
        }
        setNeedsDisplay()
    }
    override func accessibilityIncrement() { drag(20); end() }
    override func accessibilityDecrement() { drag(-20); end() }
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        let arrow = UIBezierPath()
        let points: [CGPoint] = [CGPoint(x: -14, y: 0), CGPoint(x: -7, y: -6), CGPoint(x: -7, y: -2), CGPoint(x: 7, y: -2), CGPoint(x: 7, y: -6), CGPoint(x: 14, y: 0), CGPoint(x: 7, y: 6), CGPoint(x: 7, y: 2), CGPoint(x: -7, y: 2), CGPoint(x: -7, y: 6)]
        arrow.move(to: points[0]); points.dropFirst().forEach { arrow.addLine(to: $0) }; arrow.close()
        return UIPointerStyle(shape: UIPointerShape.path(arrow), constrainedAxes: [])
    }
    func pointerInteraction(_ interaction: UIPointerInteraction, willEnter region: UIPointerRegion, animator: UIPointerInteractionAnimating) {
        highlighted = true; setNeedsDisplay()
    }
    func pointerInteraction(_ interaction: UIPointerInteraction, willExit region: UIPointerRegion, animator: UIPointerInteractionAnimating) {
        highlighted = false; setNeedsDisplay()
    }
}


enum PadLayout {
    static func sidebarWidth(preferred: Double, available: CGFloat) -> CGFloat {
        min(max(0, available) * 0.5, max(120, preferred))
    }
}

struct PadProviderLogo: View {
    let engine: String
    var body: some View {
        let key = engine.lowercased() == "agent" ? "muse" : engine.lowercased()
        let provider = ["muse": "meta", "claude": "anthropic", "codex": "openai"][key] ?? key
        let label = ["muse": "Meta", "claude": "Anthropic", "codex": "OpenAI", "parking": "Parking Lot", "unassigned": "Choose a provider", "imported": "Imported · choose a provider"][key] ?? engine.capitalized
        let color: Color = key == "muse" ? Color(red: 4/255, green: 103/255, blue: 223/255) : key == "claude" ? Color(red: 217/255, green: 119/255, blue: 87/255) : .primary
        if !engine.isEmpty {
            Group {
                if key == "parking" || key == "unassigned" {
                    ParkingLotShoe()
                } else if key == "imported" {
                    Image(systemName: "tray.and.arrow.down").resizable().scaledToFit()
                } else if let url = Bundle.main.url(forResource: provider, withExtension: "png", subdirectory: "ProviderLogos"), let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).renderingMode(.template).resizable().scaledToFit()
                } else {
                    Text(String(label.prefix(1))).font(.system(size: 14, weight: .bold))
                }
            }.frame(width: 20, height: 20).foregroundStyle(color).accessibilityLabel(label)
        }
    }
}

// Leading-column marker for a remote row: the Mac's red paused-loop icon or
// the unseen-response eye. Busy takes precedence; approval "!" outranks the eye.
struct PadRowMarker: View {
    let markers: RemoteRowMarkers
    static func spoken(_ markers: RemoteRowMarkers) -> String {
        (markers.paused ? ". Agent loop paused: " + (markers.pausedReason ?? "") : "") + (markers.unseen ? ". Unseen response" : "")
    }
    var body: some View {
        if markers.paused {
            Image(systemName: "pause.circle.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.red)
                .accessibilityLabel("Agent loop paused: " + (markers.pausedReason ?? ""))
                .help(markers.pausedReason ?? "Loop paused. Re-enable it in Agent Setup / Loop.")
                .accessibilityIdentifier("session-paused")
        } else if markers.unseen {
            Text("👀").font(.system(size: 10)).fixedSize()
                .accessibilityLabel("Unseen response").help("Unseen response: take with 1, 2 or 3 to read it.")
                .accessibilityIdentifier("session-unseen")
        }
    }
}

struct PadSessionName: View {
    let title: String
    let isAgent: Bool
    var isParkingLot = false
    var isPaused = false
    var unread = false
    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1).truncationMode(.tail).bold(unread).foregroundStyle(isPaused ? Color.red : Color.primary)
            if isAgent { Text("😎").fixedSize().help("Agent session").accessibilityLabel("Agent") }
            if isParkingLot { Text("🚗").fixedSize().help("Parking Lot").accessibilityLabel("Parking Lot") }
        }
    }
}
