import AppKit
import SwiftUI
import Security

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General", debug = "Debug", jolly = "Jolly", welcome = "New User Experience / Reset"
    var id: String { rawValue }
    var icon: String { switch self { case .general: return "gearshape"; case .debug: return "waveform.path.ecg"; case .jolly: return "bubble.left.and.bubble.right"; case .welcome: return "sparkles" } }
}
struct SettingsView: View {
    @ObservedObject var state: WindowState
    @ObservedObject var store = Store.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sessionID: UUID?
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Settings").font(.title2.bold()).padding(.bottom, 12)
                ForEach(SettingsCategory.allCases) { category in
                    Button { state.settingsCategory = category } label: {
                        Label(category.rawValue, systemImage: category.icon)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(state.settingsCategory == category ? Color.accentColor.opacity(0.18) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Button("Done") { store.save(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16).frame(width: 210).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            Group {
                switch state.settingsCategory {
                case .general:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("General").font(.title2.bold())
                            Toggle("Collapse Parking Lot data and outgoing messages", isOn: $store.collapseTranscriptPayloads)
                            Text("A disclosure arrow shows the full message. Copy Message always retains the complete content.").font(.caption).foregroundStyle(.secondary)
                            Divider()
                            Text("Transcript limits").font(.headline)
                            Picker("Session", selection: $sessionID) {
                                Text("Choose a session").tag(nil as UUID?)
                                ForEach(store.sessions) { session in Text(session.title).tag(Optional(session.id)) }
                            }
                            if let session = store.sessions.first(where: { $0.id == sessionID }) {
                                TranscriptLimitsView(session: session).id(session.id)
                            }
                            TranscriptDefaultLimitsView()
                            Text("Limits apply to this Mac’s saved transcript; the assistant’s own provider history isn’t changed. " + TranscriptLimits.unitExplanation + " " + TranscriptLimits.imageExplanation)
                                .font(.caption).foregroundStyle(.secondary)
                            TrimImagesView(store: store)
                            Divider()
                            ModelsSettingsView(state: state)

                        }.padding(22)
                    }
                case .debug: PerformanceDebugView()
                case .jolly: JollyView()
                case .welcome: ResetSettingsView(state: state)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(width: 900, height: 660).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { sessionID = store.sessions.first?.id }
    }
}
struct TranscriptLimitsView: View {
    @ObservedObject var session: Session
    @State private var days = ""
    @State private var count = ""
    @State private var saved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TranscriptLimitFields(days: $days, count: $count)
            Text("Leave either field blank for None. Defaults: no age limit, 1,000 messages. " + TranscriptLimits.timingExplanation)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Save limits") {
                    saved = Store.shared.applyTranscriptLimits(session, TranscriptLimits(days: TranscriptLimitFields.parse(days), count: TranscriptLimitFields.parse(count)))
                }.disabled(!TranscriptLimitFields.valid(days, count))
                if saved { Text("Saved · " + session.transcriptLimits.summary).font(.caption).foregroundStyle(.secondary) }
            }
        }.textFieldStyle(.roundedBorder)
            .onAppear { days = session.transcriptLimits.days.map(String.init) ?? ""; count = session.transcriptLimits.count.map(String.init) ?? "" }
            .onChange(of: days) { _, _ in saved = false }.onChange(of: count) { _, _ in saved = false }
    }
}
struct TranscriptLimitFields: View {
    @Binding var days: String
    @Binding var count: String
    static func parse(_ text: String) -> Int? { Int(text.trimmingCharacters(in: .whitespaces)) }
    static func valid(_ days: String, _ count: String) -> Bool {
        [days, count].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty || parse($0).map { TranscriptLimits.range.contains($0) } == true }
    }
    var body: some View {
        HStack { Text("Delete messages older than"); TextField("None", text: $days).frame(width: 85); Text("days") }
        HStack { Text("Keep the most recent"); TextField("None", text: $count).frame(width: 85); Text("messages (each prompt and each response is one)") }
    }
}
/// Seeds sessions created from now on; existing sessions keep their own limits.
struct TranscriptDefaultLimitsView: View {
    @State private var days = ""
    @State private var count = ""
    @State private var saved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New sessions start with").font(.subheadline.bold())
            TranscriptLimitFields(days: $days, count: $count)
            HStack {
                Button("Save default") {
                    TranscriptLimits.newSessionDefault = TranscriptLimits(days: TranscriptLimitFields.parse(days), count: TranscriptLimitFields.parse(count)); saved = true
                }.disabled(!TranscriptLimitFields.valid(days, count))
                if saved { Text("Saved · applies to sessions you create next").font(.caption).foregroundStyle(.secondary) }
            }
        }.textFieldStyle(.roundedBorder)
            .onAppear { let limits = TranscriptLimits.newSessionDefault; days = limits.days.map(String.init) ?? ""; count = limits.count.map(String.init) ?? "" }
            .onChange(of: days) { _, _ in saved = false }.onChange(of: count) { _, _ in saved = false }
    }
}
/// Removes every image from the chosen sessions' transcripts after confirmation.
struct TrimImagesView: View {
    @ObservedObject var store: Store
    @State private var chosen: Set<UUID> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trim all images").font(.subheadline.bold())
            Text("Removes every image from the chosen transcripts and deletes its file from Converse’s Attachments folder when nothing else uses it. Text, drafts and queued prompts are kept.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.sessions) { session in
                        let images = session.messages.reduce(0) { $0 + $1.images.count }
                        Toggle(session.title + (images > 0 ? " · \(images) image" + (images == 1 ? "" : "s") : ""), isOn: Binding(
                            get: { chosen.contains(session.id) }, set: { if $0 { chosen.insert(session.id) } else { chosen.remove(session.id) } }))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 140)
            Button("Trim All Images…") {
                if store.confirmTrimAllImages(store.sessions.filter { chosen.contains($0.id) }) { chosen = [] }
            }.disabled(chosen.isEmpty)
        }
    }
}
final class ProfileResetState: ObservableObject {
    static let shared = ProfileResetState()
    @Published var scheduled = false
}
struct ResetSettingsView: View {
    @ObservedObject var state: WindowState
    @ObservedObject private var reset = ProfileResetState.shared
    @State private var confirmation = ""
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New User Experience / Reset").font(.title2.bold())
            Text("Walk through provider setup without deleting your conversations.")
            Button("Open setup walkthrough…") {
                state.settings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { state.setup = true }
            }
            Divider()
            Text("☠ Reset this Converse profile ☠").font(.headline)
            Text("On your next normal quit, schedule a fresh start. The next launch backs up this profile, then removes its sessions, Parking Lots, saved API keys, app-managed logins and device pairing. Other apps and project files are untouched. External CLI login stores are unchanged.")
            if reset.scheduled {
                Text("Reset is scheduled for your next quit.").foregroundStyle(.red)
                Button("Cancel scheduled reset") { reset.scheduled = false; confirmation = "" }
            } else {
                TextField("Type YES to enable reset", text: $confirmation).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Button("☠ Reset on Quit ☠") {
                    do { try ProfileReset.validate(folder: Store.shared.folder); reset.scheduled = true; confirmation = "" }
                    catch { self.error = error.localizedDescription }
                }.disabled(confirmation != "YES").tint(.red)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            Spacer()
        }.padding(24)
    }
}
/// Only this application profile can be reset. Consumed before Store or network startup.
enum ProfileReset {
    static let marker = "reset-profile-on-quit"
    static var names: [String] { ["Converse", "Converse Demo"] + DemoReset.testProviders.map { $0 + " Converse TEST" } }
    static func validate(folder: URL) throws {
        guard names.contains(folder.lastPathComponent), folder.standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL else {
            throw NSError(domain: "ConverseReset", code: 1, userInfo: [NSLocalizedDescriptionKey: "Reset requires a standard Converse profile folder without symbolic links."])
        }
    }
    static func request(folder: URL, confirmation: String) throws {
        guard confirmation == "YES" else { throw NSError(domain: "ConverseReset", code: 2) }
        try validate(folder: folder)
        try Data("YES".utf8).write(to: folder.appendingPathComponent(marker), options: .atomic)
    }
    static func consume(folder: URL, clearCredentials: () throws -> Void) throws -> URL? {
        let fm = FileManager.default
        let request = folder.appendingPathComponent(marker)
        guard fm.fileExists(atPath: request.path) else { return nil }
        try validate(folder: folder)
        guard try Data(contentsOf: request) == Data("YES".utf8) else { throw NSError(domain: "ConverseReset", code: 3) }
        let backups = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + " Backups")
        try fm.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = backups.appendingPathComponent(UUID().uuidString)
        try fm.copyItem(at: folder, to: backup)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backup.path)
        // A restored backup must not request another reset.
        try fm.removeItem(at: backup.appendingPathComponent(marker))
        try clearCredentials()
        try fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return backup
    }
    static func clearCredentials() throws {
        for service in [AgentSecrets.service, DeviceIdentity.service] {
            let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
    }
}

func settingsSelfTests(_ check: (Bool, String) -> Void) {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("converse-settings-" + UUID().uuidString).resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: root) }
    let now = Date()
    let old = now.addingTimeInterval(-86400 * 10)
    let messages = [Message(role: "user", text: "old prompt", createdAt: old), Message(role: "assistant", text: "old reply", createdAt: old), Message(role: "user", text: "new prompt", createdAt: now), Message(role: "assistant", text: "new reply", createdAt: now)]
    check(TranscriptLimits().days == nil && TranscriptLimits().count == 1000, "Transcript defaults are None days and 1000 individual messages")
    check(TranscriptLimits(days: nil, count: nil).cut(messages, now: now) == 0, "Both limits None preserves all messages")
    check(TranscriptLimits(days: 2, count: nil).cut(messages, now: now) == 2, "Age trims the old completed turn")
    check(TranscriptLimits(count: 1).cut(messages, now: now) == 2, "Count preserves the prompt for a retained response")
    var legacy = messages; legacy[0].createdAt = nil
    check(TranscriptLimits(days: 2, count: nil).cut(legacy, now: now) == 0, "Unknown legacy timestamps are not aged out")
    check(TranscriptLimits(count: 0).cut(messages, now: now) == 0, "Invalid decoded limits cannot erase a transcript")
    let store = Store(folder: root.appendingPathComponent("archive"))
    let session = store.create(Entry(name: "Offline", command: "false", directory: root.path, engine: "codex"))
    session.messages = messages; session.transcriptLimits = TranscriptLimits(count: 2)
    session.draft = "unsent"
    check(store.trimIdleTranscripts(now: now) == 0 && session.messages.count == 4 && session.draft == "unsent", "Retention preserves a session with an active draft")
    session.draft = ""; session.busy = true
    check(store.trimIdleTranscripts(now: now) == 0, "Retention skips streaming sessions")
    session.busy = false
    session.switchboardExpectations = [SwitchboardExpectation(id: UUID(), target: "peer")]
    check(store.trimIdleTranscripts(now: now) == 0, "Retention skips outstanding asks")
    session.switchboardExpectations = []
    check(store.trimIdleTranscripts(now: now) == 2 && session.messages.map(\.text) == ["new prompt", "new reply"], "Idle retention removes only the old prefix")
    try? store.saveChecked()
    let reload = Store(folder: store.folder)
    check(reload.sessions.first?.transcriptLimits.count == 2 && reload.sessions.first?.messages.count == 2, "Limits and retained history persist")
    let profile = root.appendingPathComponent("Converse")
    do {
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("keep backup".utf8).write(to: profile.appendingPathComponent("sessions.json"))
        do { try ProfileReset.request(folder: profile, confirmation: "yes"); check(false, "Reset must reject lowercase yes") } catch { check(true, "Reset requires exact YES") }
        try ProfileReset.request(folder: profile, confirmation: "YES")
        check(fm.fileExists(atPath: profile.appendingPathComponent("sessions.json").path), "Scheduling reset does not erase the live profile")
        var keysCleared = false
        let backup = try ProfileReset.consume(folder: profile) { keysCleared = true }
        check(keysCleared && backup != nil && fm.fileExists(atPath: backup!.appendingPathComponent("sessions.json").path), "Reset backs up the profile before clearing it")
        check(!fm.fileExists(atPath: profile.appendingPathComponent("sessions.json").path) && !fm.fileExists(atPath: backup!.appendingPathComponent(ProfileReset.marker).path), "Reset leaves a fresh profile and a backup safe to restore")
        try Data("preserve on failure".utf8).write(to: profile.appendingPathComponent("sessions.json"))
        try ProfileReset.request(folder: profile, confirmation: "YES")
        do {
            _ = try ProfileReset.consume(folder: profile) { throw NSError(domain: "fixture-keychain", code: 1) }
            check(false, "Failed credential clearing must abort reset")
        } catch {
            check(fm.fileExists(atPath: profile.appendingPathComponent("sessions.json").path), "Credential failure preserves the original profile for retry")
        }
        let unrelated = root.appendingPathComponent("project")
        do { try ProfileReset.request(folder: unrelated, confirmation: "YES"); check(false, "Reset refuses arbitrary project directories") } catch { check(true, "Reset refuses arbitrary project directories") }
    } catch { check(false, "Reset fixture: " + error.localizedDescription) }
}

@MainActor func settingsPreview(directory: URL) throws {
    let store = Store.shared
    store.setupCompleted = true
    if store.sessions.isEmpty {
        let session = store.create(Entry(name: "Example", command: "false", directory: NSTemporaryDirectory(), engine: "codex"))
        session.title = "Example conversation"
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let diagnostics = PerformanceDebugState.shared
    func titlePreview(_ name: String) {
        let state = WindowState(); Workspace.shared.rename(state.id, to: "Converse App Development")
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: appearanceName)!
            let view = NSHostingView(rootView: WindowTitle(workspace: .shared, state: state).background(Color(nsColor: .windowBackgroundColor)))
            view.frame = NSRect(x: 0, y: 0, width: 510, height: 24)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = appearance; view.appearance = appearance; window.contentView = view
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            appearance.performAsCurrentDrawingAppearance {
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("telemetry-title-" + name + "-" + appearanceName.rawValue + ".png"))
                }
            }
        }
    }
    let suite = "Converse.PerformancePreview." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    diagnostics.initialize(folder: store.folder, defaults: defaults, info: [:], environment: [:])
    titlePreview("off")
    diagnostics.record(folder: store.folder)
    titlePreview("recording")
    PerformanceCapture.shared.recordForTesting(.keyDelivery, milliseconds: 125)
    diagnostics.pause()
    let deadline = Date().addingTimeInterval(3)
    while diagnostics.busy && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    guard diagnostics.paused, !diagnostics.recording, diagnostics.file != nil, !diagnostics.busy else {
        throw NSError(domain: "PerformancePreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pause did not freeze a capture"])
    }
    titlePreview("paused")
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = NSAppearance(named: appearanceName)!
        let invitation = NSHostingView(rootView: FeedbackInvitationPanel(repository: {}, issue: {}, report: {}, close: {}).background(Color(nsColor: .windowBackgroundColor)))
        invitation.frame = NSRect(x: 0, y: 0, width: 488, height: 480)
        let invitationWindow = NSWindow(contentRect: invitation.frame, styleMask: .borderless, backing: .buffered, defer: false)
        invitationWindow.appearance = appearance; invitation.appearance = appearance; invitationWindow.contentView = invitation
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        invitation.layoutSubtreeIfNeeded()
        appearance.performAsCurrentDrawingAppearance {
            if let bitmap = invitation.bitmapImageRepForCachingDisplay(in: invitation.bounds) {
                invitation.cacheDisplay(in: invitation.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("feedback-invitation-" + appearanceName.rawValue + ".png"))
            }
        }
        for (index, category) in SettingsCategory.allCases.enumerated() {
            let state = WindowState(); state.settingsCategory = category
            let view = NSHostingView(rootView: SettingsView(state: state))
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 660)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = appearance; view.appearance = appearance; window.contentView = view
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            view.layoutSubtreeIfNeeded()
            appearance.performAsCurrentDrawingAppearance {
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let url = directory.appendingPathComponent("settings-\(index)-\(appearanceName.rawValue).png")
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
                    print(url.path)
                }
            }
        }
    }
}

final class PerformanceDebugState: ObservableObject {
    static let shared = PerformanceDebugState()
    @Published private(set) var recording = false
    @Published private(set) var paused = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Off."
    @Published private(set) var file: URL?
    @Published var exportError: String?
    @Published var history = 60.0 {
        didSet {
            if !loadingPreferences { preferences.set(history, forKey: "performanceHistorySeconds") }
            PerformanceCapture.shared.setHistory(seconds: history)
        }
    }
    @Published var automatic = false {
        didSet { if !loadingPreferences { preferences.set(automatic, forKey: "performanceRecordOnLaunch") } }
    }
    private var loadingPreferences = false
    private var preferences = UserDefaults.standard
    private var request = 0
    private var folder: URL?
    func initialize(folder: URL, defaults: UserDefaults = .standard, info: [String: Any] = Bundle.main.infoDictionary ?? [:], environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.folder = folder; preferences = defaults
        loadingPreferences = true
        defer { loadingPreferences = false }
        history = PerformanceCapture.clampedHistory((defaults.object(forKey: "performanceHistorySeconds") as? Double) ?? 60)
        automatic = (defaults.object(forKey: "performanceRecordOnLaunch") as? Bool) ?? PerformanceCapture.recordingDefault(
            info: info, environment: environment)
        let paused = folder.appendingPathComponent("Performance Diagnostics/paused-performance.json")
        if FileManager.default.fileExists(atPath: paused.path) { file = paused }
        if automatic { record(folder: folder) }
    }
    func record(folder: URL) {
        guard !recording, !busy else { return }
        self.folder = folder; request += 1; exportError = nil
        PerformanceCapture.shared.configure(folder: folder, enabled: true, historySeconds: history)
        recording = true; paused = false; status = "Recording recent activity. Pause after a stutter."
    }
    func setMonitoringEnabled(_ enabled: Bool, folder: URL) {
        guard !busy else { return }
        if enabled {
            automatic = true
            if !recording && !paused { record(folder: folder) }
        } else { turnOff() }
    }
    func pause() {
        guard recording, !busy, let folder else { return }
        request += 1; let token = request
        recording = false; paused = true; busy = true; status = "Saving paused buffer…"
        PerformanceCapture.shared.finish { result in
            var result = result
            if case .success(let current) = result {
                do {
                    let paused = folder.appendingPathComponent("Performance Diagnostics/paused-performance.json")
                    try Data(contentsOf: current).write(to: paused, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paused.path)
                    result = .success(paused)
                } catch { result = .failure(error) }
            }
            DispatchQueue.main.async {
                guard self.request == token else { return }
                self.busy = false
                switch result {
                case .success(let file): self.file = file; self.status = "Paused. Buffer saved locally and ready to export."
                case .failure(let error): self.file = nil; self.status = "Could not save buffer: " + error.localizedDescription
                }
            }
        }
    }
    func turnOff() {
        guard !busy else { return }
        automatic = false
        if let folder, recording { PerformanceCapture.shared.configure(folder: folder, enabled: false) }
        recording = false; paused = false
        status = "Off. Last paused buffer remains available to export."
    }
    func export() {
        guard let file, !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Converse-performance.json"
        panel.title = "Export performance capture"
        let token = request
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            DispatchQueue.global(qos: .utility).async {
                do {
                    let data = try Data(contentsOf: file)
                    try data.write(to: destination, options: .atomic)
                    DispatchQueue.main.async { if self.request == token { self.status = self.recording ? "Paused buffer exported. Recording continues." : "Paused buffer exported." } }
                } catch {
                    DispatchQueue.main.async { if self.request == token { self.exportError = "Could not export: " + error.localizedDescription } }
                }
            }
        }
    }
}
struct PerformanceDebugView: View {
    @ObservedObject private var capture = PerformanceDebugState.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Debug").font(.title2.bold())
            Toggle("Performance monitoring", isOn: Binding(
                get: { capture.recording || capture.paused },
                set: { capture.setMonitoringEnabled($0, folder: Store.shared.folder) }))
                .disabled(capture.busy)
            Text("On starts monitoring and remembers your choice for the next launch. Use Record and Pause beside the window title to capture a stutter.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Keep a rolling buffer of typing, rendering, saving and main-thread timings locally. No conversations, key characters or credentials are recorded. Nothing is uploaded.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                Text("Keep the last \(Int(capture.history)) seconds").monospacedDigit()
                Slider(value: $capture.history, in: 30...600, step: 10)
                    .accessibilityLabel("History in seconds")
            }.disabled(capture.busy)
            HStack(spacing: 14) {
                Button("Export…") { capture.export() }
                    .disabled(capture.file == nil || capture.busy)
            }
            Text(capture.status).foregroundStyle(.secondary).accessibilityIdentifier("performanceCaptureStatus")
            if let error = capture.exportError { Text(error).foregroundStyle(.red) }
            Text("You can close Settings while monitoring. Pause freezes the recent buffer. Off also disables monitoring at launch. Record starts a new buffer; Export saves the last paused buffer, which stays saved until you pause again.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("GitHub banner").font(.headline)
            if Store.shared.sessions.contains(where: { $0.feedbackRepository != nil }) {
                Button("Trigger GitHub banner") { FeedbackInvitation.shared.triggerTestBanner() }
                Text("Shows the blue banner now, beside each agent that enables it. This is only a test: it doesn’t count as this release’s invitation or record that you gave feedback. Close it with its X.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No agent shows the feedback banner yet. Turn on “Show the feedback banner for this repository” in Agent Setup to test it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Run by the ordinary test.sh self-test, with isolated preferences and capture files.
func performanceDebugSelfTests(_ check: (Bool, String) -> Void) {
    let suite = "Converse.PerformanceTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let standardBefore = ["performanceRecordOnLaunch", "performanceHistorySeconds"].map { UserDefaults.standard.object(forKey: $0).map { String(describing: $0) } }
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
    let probe = PerformanceDebugState()
    probe.initialize(folder: folder, defaults: defaults, info: [:], environment: [:])
    check(!probe.automatic && defaults.object(forKey: "performanceRecordOnLaunch") == nil && defaults.object(forKey: "performanceHistorySeconds") == nil, "Production recording/history defaults do not become saved user choices")
    probe.initialize(folder: folder, defaults: defaults, info: ["ConverseDevelopmentBuild": true], environment: [:])
    check(probe.automatic && defaults.object(forKey: "performanceRecordOnLaunch") == nil, "Development recording default remains computed")
    probe.turnOff(); probe.history = 120
    probe.initialize(folder: folder, defaults: defaults, info: ["ConverseDevelopmentBuild": true], environment: [:])
    check(!probe.automatic && probe.history == 120 && defaults.object(forKey: "performanceRecordOnLaunch") as? Bool == false, "Explicit Off and history survive initialization using injected preferences")
    probe.setMonitoringEnabled(true, folder: folder)
    check(probe.recording && probe.automatic && defaults.bool(forKey: "performanceRecordOnLaunch"), "Monitoring On starts capture and remembers the launch choice")
    PerformanceCapture.shared.recordForTesting(.keyDelivery, milliseconds: 125)
    probe.pause()
    let deadline = Date().addingTimeInterval(5)
    while probe.busy && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    guard let file = probe.file, let bytes = try? Data(contentsOf: file), !probe.busy else { check(false, "Controller pause writes isolated capture"); return }
    probe.setMonitoringEnabled(true, folder: folder)
    check(probe.paused && !probe.recording && (try? Data(contentsOf: file)) == bytes, "Monitoring On while paused preserves the frozen capture")
    probe.record(folder: folder)
    PerformanceCapture.shared.recordForTesting(.keyDelivery, milliseconds: 500)
    probe.setMonitoringEnabled(false, folder: folder)
    check(!probe.recording && !probe.paused && probe.file == file && (try? Data(contentsOf: file)) == bytes, "Record then Off preserves the previous paused export bytes")
    let standardAfter = ["performanceRecordOnLaunch", "performanceHistorySeconds"].map { UserDefaults.standard.object(forKey: $0).map { String(describing: $0) } }
    check(standardAfter == standardBefore, "Controller regression tests never alter standard recording or history preferences")
}
