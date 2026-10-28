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
                Stepper("Automatic runs remaining: \(settings.remainingRuns)", value: $settings.remainingRuns, in: 0...1000)
                Toggle("Enable automatic loop", isOn: $settings.enabled)
                Toggle("Generate mood art with Muse Image (at most once per hour or mood change)", isOn: $settings.generateArt)
                Toggle("Speak replies with expressive pace", isOn: $settings.speak)
                Toggle("Allow Discord webhook alerts", isOn: $settings.discord)
                Text("Sessions this agent may read and message · select explicitly").font(.headline)
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(Store.shared.sessions.filter { $0.id != session.id && $0.agent == nil }) { other in
                            Toggle(other.title, isOn: Binding(get: { settings.watchedSessions.contains(other.id) }, set: { on in settings.watchedSessions.removeAll { $0 == other.id }; if on { settings.watchedSessions.append(other.id) } }))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 100)
            }
            .textFieldStyle(.roundedBorder)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack { Button("Cancel") { close() }; Spacer(); Button("Save") { save() }.keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 650)
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    private func save() {
        guard AgentRepoSnapshot.validRepository(settings.repository), !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Enter a model and a repository as owner/name."; return }
        guard settings.intervalSeconds.isFinite else { error = "Enter a valid interval."; return }
        do {
            guard ![("meta", metaKey), ("github", githubKey), ("discord", discordURL)].contains(where: { removeSecrets.contains($0.0) && !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { error = "Choose either replacement or removal for each credential."; return }
            try AgentSecrets.update("meta", value: metaKey, remove: removeSecrets.contains("meta"))
            try AgentSecrets.update("github", value: githubKey, remove: removeSecrets.contains("github"))
            try AgentSecrets.update("discord", value: discordURL, remove: removeSecrets.contains("discord"))
            var current = session.agent ?? AgentConfig()
            current.objective = settings.objective; current.repository = settings.repository; current.model = settings.model
            current.watchedSessions = settings.watchedSessions; current.intervalSeconds = max(60, settings.intervalSeconds)
            current.remainingRuns = settings.remainingRuns; current.enabled = settings.enabled && settings.remainingRuns > 0
            current.generateArt = settings.generateArt; current.speak = settings.speak; current.discord = settings.discord
            current.nextRunAt = Date().addingTimeInterval(current.intervalSeconds)
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
            Text("\(session.agent?.remainingRuns ?? 0) loops left").font(.caption).foregroundStyle(.secondary)
            Button(session.agent?.enabled == true ? "Pause loop" : "Resume loop") {
                session.agent?.enabled.toggle(); session.agent?.nextRunAt = Date().addingTimeInterval(max(60, session.agent?.intervalSeconds ?? 900)); Store.shared.save()
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
    private var widgets: [UUID: NSWindow] = [:]
    private var setups: [UUID: NSWindow] = [:]
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
