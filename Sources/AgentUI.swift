import AppKit
import SwiftUI

struct AgentSetupView: View {
    @ObservedObject var session: Session
    @State private var settings: AgentConfig
    @State private var metaKey = ""
    @State private var githubKey = ""
    @State private var discordURL = ""
    @State private var removeSecrets: Set<String> = []
    @State private var error = ""
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    init(session: Session, onClose: (() -> Void)? = nil) { self.session = session; self.onClose = onClose; _settings = State(initialValue: session.agent ?? AgentConfig()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Setup · " + session.title).font(.title2.bold())
            Text("Runs on this home computer while Converse is open. Only the selected sessions are sent to Meta. Keys and the Discord webhook stay in this computer’s Keychain.").font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SecureField("Meta API key · blank keeps saved key", text: $metaKey)
                    Toggle("Remove saved", isOn: Binding(get: { removeSecrets.contains("meta") }, set: { if $0 { removeSecrets.insert("meta") } else { removeSecrets.remove("meta") } })).toggleStyle(.checkbox).fixedSize().help("Remove this saved credential from this Mac for all agents when you click Save")
                }
                HStack {
                    SecureField("GitHub token · optional, blank keeps saved token", text: $githubKey)
                    Toggle("Remove saved", isOn: Binding(get: { removeSecrets.contains("github") }, set: { if $0 { removeSecrets.insert("github") } else { removeSecrets.remove("github") } })).toggleStyle(.checkbox).fixedSize().help("Remove this saved credential from this Mac for all agents when you click Save")
                }
                HStack {
                    SecureField("Discord webhook · optional", text: $discordURL)
                    Toggle("Remove saved", isOn: Binding(get: { removeSecrets.contains("discord") }, set: { if $0 { removeSecrets.insert("discord") } else { removeSecrets.remove("discord") } })).toggleStyle(.checkbox).fixedSize().help("Remove this saved credential from this Mac for all agents when you click Save")
                }
                HStack { Text("Model").frame(width: 90, alignment: .leading); TextField("Model", text: $settings.model) }
                HStack { Text("Repository").frame(width: 90, alignment: .leading); TextField("GitHub repository · owner/name", text: $settings.repository) }
                Text("What should this agent do? How will you judge success?").font(.headline)
                TextEditor(text: $settings.objective).frame(height: 85).border(Color.secondary.opacity(0.3))
                HStack {
                    Text("Run every"); TextField("Seconds", value: $settings.intervalSeconds, format: .number).frame(width: 70); Text("seconds (minimum 60)")
                }
                Stepper("Autonomous runs remaining: \(settings.remainingRuns)", value: $settings.remainingRuns, in: 0...1000)
                Toggle("Enable automatic loop", isOn: $settings.enabled)
                Toggle("Generate mood art with Muse Image (at most once per hour or mood change)", isOn: $settings.generateArt)
                Toggle("Speak replies with expressive pace", isOn: $settings.speak)
                Toggle("Accept file events from this agent’s Inbox", isOn: Binding(get: { settings.fileTriggers == true }, set: { settings.fileTriggers = $0 }))
                if settings.fileTriggers == true { Text(Store.shared.folder.appendingPathComponent("Agents/" + session.id.uuidString + "/Inbox").path).font(.caption).textSelection(.enabled) }
                Toggle("Allow Discord webhook alerts", isOn: $settings.discord)
                Text("Sessions this agent may read and message · select explicitly").font(.headline)
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(Store.shared.sessions.filter { $0.id != session.id }) { other in
                            Toggle(other.title, isOn: Binding(get: { settings.allows(local: other.id, home: DeviceSyncService.shared.localDeviceID) }, set: { on in
                                settings.watchedSessions.removeAll { $0 == other.id }
                                if let home = DeviceSyncService.shared.localDeviceID { settings.watchedParticipants?.removeAll { $0 == DeviceGlobalID(home: home, session: other.id).string } }
                                if on { settings.watchedSessions.append(other.id) }
                            }))
                        }
                        ForEach((settings.watchedParticipants ?? []).filter { !availableScope.contains($0) }, id: \.self) { id in
                            Toggle("Unavailable selected participant · " + id, isOn: Binding(get: { true }, set: { if !$0 { settings.watchedParticipants?.removeAll { $0 == id } } })).font(.caption)
                        }
                        ForEach(DeviceSyncService.shared.participantHomes, id: \.deviceID) { home in
                            Text(home.deviceName).font(.caption).foregroundStyle(.secondary)
                            ForEach(home.rows) { row in
                                Toggle(row.title + (home.online ? "" : " · offline"), isOn: Binding(get: { settings.watchedParticipants?.contains(row.globalID) == true }, set: { on in
                                    settings.watchedParticipants = (settings.watchedParticipants ?? []).filter { $0 != row.globalID }
                                    if on { settings.watchedParticipants?.append(row.globalID) }
                                }))
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 120)
            }
            .textFieldStyle(.roundedBorder)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack { Button("Cancel") { close() }; Button("Reload settings") { settings = session.agent ?? AgentConfig(); error = "" }; Spacer(); Button("Save") { save() }.keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 650)
    }
    private var availableScope: Set<String> {
        let service = DeviceSyncService.shared
        return Set(service.participantHomes.flatMap { $0.rows.map(\.globalID) } + Store.shared.sessions.compactMap { session in service.localDeviceID.map { DeviceGlobalID(home: $0, session: session.id).string } })
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    private func save() {
        guard AgentRepoSnapshot.validRepository(settings.repository), !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Enter a model and a repository as owner/name."; return }
        guard settings.intervalSeconds.isFinite else { error = "Enter a valid interval."; return }
        do {
            var current = session.agent ?? AgentConfig()
            try current.apply(settings.wire(home: DeviceSyncService.shared.localDeviceID ?? "local"))
            guard ![("meta", metaKey), ("github", githubKey), ("discord", discordURL)].contains(where: { removeSecrets.contains($0.0) && !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { error = "Choose either replacement or removal for each credential."; return }
            try AgentSecrets.update("meta", value: metaKey, remove: removeSecrets.contains("meta"))
            try AgentSecrets.update("github", value: githubKey, remove: removeSecrets.contains("github"))
            try AgentSecrets.update("discord", value: discordURL, remove: removeSecrets.contains("discord"))
            session.agent = current; session.toolStatus.model = current.model
            Store.shared.save(); close()
        } catch { self.error = error.localizedDescription }
    }
}

struct AgentControls: View {
    @ObservedObject var session: Session
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 12) {
            Text(session.busy ? "Working…" : session.status).font(.caption)
            Text(session.agent?.model ?? "Agent").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(session.agent?.remainingRuns ?? 0) runs left").font(.caption).foregroundStyle(.secondary)
            Button(session.agent?.enabled == true ? "Pause loop" : "Resume loop") {
                session.agent?.settingsChanged(); session.agent?.enabled.toggle(); session.agent?.nextRunAt = Date().addingTimeInterval(max(60, session.agent?.intervalSeconds ?? 900)); Store.shared.save()
            }.disabled((session.agent?.remainingRuns ?? 0) == 0)
            Button("Dictate") {
                guard let input = session.inputTextView else { return }
                input.window?.makeFirstResponder(input)
                input.setSelectedRange(NSRange(location: (input.string as NSString).length, length: 0))
                NSApp.sendAction(Selector(("startDictation:")), to: input, from: nil)
            }.help("Talk into the blue draft with macOS Dictation; review it, then press Return to send")
            Button("Scoreboard") { AgentWindows.shared.widget(session) }
            Button("Agent Setup…") { AgentWindows.shared.setup(session) }
        }.padding(8) }.frame(height: 40)
    }
}

struct AgentWidgetView: View {
    @ObservedObject var session: Session
    var body: some View {
        ZStack {
            if let path = session.agent?.artPath, let image = NSImage(contentsOfFile: path) { Image(nsImage: image).resizable().scaledToFill() }
            else { LinearGradient(colors: [.indigo, .teal, .black], startPoint: .topLeading, endPoint: .bottomTrailing) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(session.title).font(.title.bold())
                    Text(session.agent?.snapshot?.repository ?? "Set a repository in Agent Setup").font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(session.agent?.snapshot?.metrics ?? [], id: \.0) { item in
                            VStack(alignment: .leading, spacing: 3) { Text(item.1).font(.title2.bold()); Text(item.0).font(.caption) }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    Text(session.agent?.widgetSummary ?? "Tell me what success looks like.")
                    if session.agent?.lastArtAt == nil { Text("Art has not been generated yet.").font(.caption).foregroundStyle(.white.opacity(0.75)) }
                    if let attention = session.agent?.attention, !attention.isEmpty { Label(attention, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.black).padding(10).background(.yellow, in: RoundedRectangle(cornerRadius: 8)) }
                    if let at = session.agent?.snapshot?.observedAt { Text("Measured " + at.formatted(date: .abbreviated, time: .shortened)).font(.caption) }
                    ForEach(session.agent?.snapshot?.notes ?? [], id: \.self) { Text($0).font(.caption) }
                    HStack { Button("Export widget…") { AgentWindows.shared.export(session) }; Button("Agent Setup…") { AgentWindows.shared.setup(session) } }
                }.foregroundStyle(.white).padding(24).background(.black.opacity(0.35))
            }
        }.clipped().frame(minWidth: 420, minHeight: 500)
    }
}

@MainActor final class AgentWindows {
    static let shared = AgentWindows()
    private var creation: NSWindow?
    private var remoteSetups: [String: NSWindow] = [:]
    private var widgets: [UUID: NSWindow] = [:]
    private var setups: [UUID: NSWindow] = [:]
    func create() {
        if let window = creation, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "New agent"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AgentCreationView(onClose: { [weak window] in window?.close() }))
        creation = window; window.center(); window.makeKeyAndOrderFront(nil)
    }
    func remoteSetup(_ globalID: String) {
        if let window = remoteSetups[globalID], window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Agent Setup · remote home"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RemoteAgentSetupView(globalID: globalID, onClose: { [weak window] in window?.close() }))
        remoteSetups[globalID] = window; window.center(); window.makeKeyAndOrderFront(nil)
    }
    func widget(_ session: Session) {
        if let window = widgets[session.id] { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = session.title + " · Scoreboard"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AgentWidgetView(session: session)); widgets[session.id] = window
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    func setup(_ session: Session) {
        if let old = setups[session.id], old.isVisible { old.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 750), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Agent Setup"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AgentSetupView(session: session, onClose: { [weak window] in window?.close() }))
        setups[session.id] = window; window.center(); window.makeKeyAndOrderFront(nil)
    }
    func export(_ session: Session) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = session.title + " Scoreboard.html"; panel.allowedContentTypes = [.html]
        if panel.runModal() == .OK, let url = panel.url {
            do { try AgentWidgetExport.html(session).write(to: url, atomically: true, encoding: .utf8) }
            catch { let alert = NSAlert(); alert.messageText = "Could not export scoreboard"; alert.informativeText = error.localizedDescription; alert.runModal() }
        }
    }
}

enum AgentWidgetExport {
    static func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
    static func html(_ session: Session) -> String {
        let config = session.agent ?? AgentConfig()
        var art = ""
        if let path = config.artPath, let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)), bytes.count <= 8_000_000 { art = "<img class=art alt='Generated status art' src='data:image/png;base64," + bytes.base64EncodedString() + "'>" }
        let cells = (config.snapshot?.metrics ?? []).map { "<div class=metric><strong>" + escape($0.1) + "</strong><span>" + escape($0.0) + "</span></div>" }.joined()
        return """
        <!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content="width=device-width, initial-scale=1"><meta http-equiv=Content-Security-Policy content="default-src 'none'; img-src data:; style-src 'unsafe-inline'"><title>\(escape(session.title))</title><style>body{margin:0;background:#0f172a;color:white;font:16px system-ui}main{max-width:780px;margin:auto;padding:32px;position:relative}.art{position:fixed;inset:0;width:100%;height:100%;object-fit:cover;opacity:.5;z-index:-1}.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:12px}.metric{padding:18px;background:#101827d9;border-radius:12px}.metric strong{display:block;font-size:28px}.metric span{opacity:.8}p{white-space:pre-wrap;background:#101827cc;padding:16px;border-radius:12px}.attention{background:#facc15;color:#111}footer{font-size:12px}</style>\(art)<main><h1>\(escape(session.title))</h1><h2>\(escape(config.snapshot?.repository ?? config.repository))</h2><div class=grid>\(cells)</div><p>\(escape(config.widgetSummary))</p>\(config.attention.isEmpty ? "" : "<p class=attention>" + escape(config.attention) + "</p>")<footer>Snapshot · \(escape(config.snapshot?.observedAt.formatted() ?? "Not measured yet"))<br>\(escape((config.snapshot?.notes ?? []).joined(separator: " · ")))<br>Richard Kaufmann · richard@kaoslabs.app · www.kaoslabs.app</footer></main></html>
        """
    }
    static func writeSnapshot(_ session: Session, store: Store) throws {
        let folder = store.folder.appendingPathComponent("Agents/" + session.id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try html(session).write(to: folder.appendingPathComponent("widget.html"), atomically: true, encoding: .utf8)
        if let snapshot = session.agent?.snapshot { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; try encoder.encode(snapshot).write(to: folder.appendingPathComponent("metrics.json"), options: .atomic) }
    }
}

struct AgentCreationView: View {
    @ObservedObject var service = DeviceSyncService.shared
    @State private var title = "Converse Steward"
    @State private var home = "local"
    @State private var working = false
    @State private var outcome = ""
    var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New agent").font(.title2.bold())
            TextField("Agent name", text: $title)
            Picker("Runs on", selection: $home) {
                #if os(macOS)
                Text("This Mac").tag("local")
                #endif
                ForEach(service.participantHomes.filter { service.canHostAgent($0.deviceID) }, id: \.deviceID) { device in Text(device.deviceName).tag(device.deviceID) }
            }
            Text("The agent starts paused. Its API credentials, loop and optional scoreboard stay on the chosen home. Select the sessions it may read in Agent Setup.").font(.callout).foregroundStyle(.secondary)
            if !outcome.isEmpty { Text(outcome).font(.callout) }
            HStack { Button("Cancel", action: onClose); Spacer(); Button(working ? "Creating…" : "Create agent") { create() }.disabled(working || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 440)
        .onAppear {
            #if !os(macOS)
            home = service.participantHomes.first(where: { service.canHostAgent($0.deviceID) })?.deviceID ?? ""
            #endif
        }
    }
    private func create() {
        #if os(macOS)
        if home == "local" {
            let session = Store.shared.createAgent(title: title)
            if let (_, state) = AppDelegate.shared.windows.first(where: { $0.0.isKeyWindow }) ?? AppDelegate.shared.windows.last { AppDelegate.shared.select(session, state: state) }
            onClose(); AgentWindows.shared.setup(session)
            return
        }
        #endif
        do {
            working = true
            Task { @MainActor in
                let result = await service.requestParticipant(home: home, action: "agent.create", title: title)
                working = false; outcome = result.detail
                if result.outcome == "completed", let id = result.target {
                    onClose()
                    #if os(macOS)
                    AgentWindows.shared.remoteSetup(id)
                    #endif
                }
            }
        }
    }
}

struct RemoteAgentSetupView: View {
    var globalID: String
    var onClose: () -> Void
    @ObservedObject var service = DeviceSyncService.shared
    @State private var settings = DeviceAgentSettings(objective: "", repository: "richardkaufmann/converse", model: "muse-spark-1.3", watched: [], intervalSeconds: 900, remainingRuns: 20, enabled: false, generateArt: true, speak: false, discord: false)
    @State private var loaded = false
    @State private var working = false
    @State private var outcome = "Loading home settings…"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Setup").font(.title2.bold())
            Text("Credentials are configured on the execution home. This device changes settings without receiving API keys.").font(.callout).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 10) {
                TextField("Objective and success criteria", text: $settings.objective, axis: .vertical).lineLimit(3...6)
                TextField("Repository · owner/name", text: $settings.repository)
                TextField("Model", text: $settings.model)
                HStack { Text("Interval, seconds"); TextField("Seconds", value: $settings.intervalSeconds, format: .number) }
                Stepper("Autonomous runs remaining: \(settings.remainingRuns)", value: $settings.remainingRuns, in: 0...1000)
                Toggle("Enable scheduled loop", isOn: $settings.enabled)
                Toggle("Generate status art", isOn: $settings.generateArt)
                Toggle("Speak on the home", isOn: $settings.speak)
                Toggle("Allow configured Discord alerts", isOn: $settings.discord)
                Toggle("Accept home Inbox file events", isOn: $settings.fileTriggers)
                Text("Allowed sessions").bold()
                #if os(macOS)
                ForEach(Store.shared.sessions) { session in
                    if let home = service.localDeviceID { scopeRow(DeviceGlobalID(home: home, session: session.id).string, title: session.title + " · this Mac") }
                }
                #endif
                ForEach(settings.watched.filter { !availableScope.contains($0) }, id: \.self) { id in
                    scopeRow(id, title: "Unavailable selected participant · " + id)
                }
                ForEach(service.participantHomes, id: \.deviceID) { home in
                    ForEach(home.rows) { row in if row.globalID != globalID { scopeRow(row.globalID, title: row.title + " · " + home.deviceName) } }
                }
            }.disabled(!loaded || working) }
            Text(outcome).font(.callout)
            HStack {
                Button("Close", action: onClose)
                Button("Reload") { perform("agent.settings") }.disabled(working)
                Button("Run once") { perform("agent.run") }.disabled(!loaded || working)
                Button("Show scoreboard on home") { perform("agent.widget") }.disabled(!loaded || working)
                Spacer(); Button("Save") { perform("agent.configure") }.disabled(!loaded || working)
            }
        }.textFieldStyle(.roundedBorder).padding(20).frame(minWidth: 540, minHeight: 580)
        .task {
            guard let id = DeviceGlobalID(globalID) else { return }
            let result = await service.requestParticipant(home: id.home, action: "agent.settings", target: globalID)
            if let config = result.settings { settings = config; loaded = true }
            outcome = result.detail
        }
    }
    private var availableScope: Set<String> {
        var ids = service.participantHomes.flatMap { $0.rows.map(\.globalID) }
        #if os(macOS)
        if let home = service.localDeviceID { ids += Store.shared.sessions.map { DeviceGlobalID(home: home, session: $0.id).string } }
        #endif
        return Set(ids)
    }
    private func scopeRow(_ id: String, title: String) -> some View {
        Toggle(title, isOn: Binding(get: { settings.watched.contains(id) }, set: { on in settings.watched.removeAll { $0 == id }; if on { settings.watched.append(id) } }))
    }
    private func perform(_ action: String) {
        guard let id = DeviceGlobalID(globalID) else { return }; working = true
        Task { @MainActor in
            let response = await service.requestParticipant(home: id.home, action: action, target: globalID, settings: action == "agent.configure" ? settings : nil)
            outcome = response.detail; working = false
            if let config = response.settings { settings = config; loaded = true }
            else if response.outcome == "completed", ["agent.configure", "agent.run"].contains(action) {
                let fresh = await service.requestParticipant(home: id.home, action: "agent.settings", target: globalID)
                if let config = fresh.settings { settings = config }
            }
        }
    }
}
