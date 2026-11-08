import AppKit
import SwiftUI
import Security

struct TranscriptLimits: Codable, Equatable {
    var days: Int? = nil
    var count: Int? = 1000
    var valid: Bool { [days, count].allSatisfy { $0 == nil || (1...1_000_000).contains($0!) } }
    /// Delete a prefix only, retaining the prompt that starts a retained turn.
    func cut(_ messages: [Message], now: Date) -> Int {
        guard valid else { return 0 }
        let counted = messages.indices.filter { ["user", "assistant"].contains(messages[$0].role) }
        var boundary = 0
        if let count, counted.count > count { boundary = counted[counted.count - count] }
        if let days {
            let oldest = now.addingTimeInterval(-Double(days) * 86400)
            // Unknown legacy times are never assumed to be old.
            let ageBoundary = messages.firstIndex { $0.createdAt == nil || $0.createdAt! >= oldest } ?? messages.count
            boundary = max(boundary, ageBoundary)
        }
        if boundary >= messages.count { return messages.count }
        if messages[boundary].role != "user", let prompt = messages[..<boundary].lastIndex(where: { $0.role == "user" }) { boundary = prompt }
        return boundary
    }
}
extension Store {
    @discardableResult func trimIdleTranscripts(now: Date = Date()) -> Int {
        guard !applicationQuitting else { return 0 }
        var removed = 0
        for session in sessions {
            guard !session.busy, !session.compacting, !session.changingSetting,
                  session.draft.isEmpty, session.attachments.isEmpty, session.pending.isEmpty,
                  session.requests.isEmpty, session.handoffPending == nil, session.restoreRetry == nil,
                  !session.switchboardObligations.contains(where: { !$0.terminal }),
                  !session.switchboardExpectations.contains(where: { !$0.answered }) else { continue }
            let cut = session.transcriptLimits.cut(session.messages, now: now)
            guard cut > 0 else { continue }
            let deleted = Set(session.messages.prefix(cut).map(\.id))
            session.messages.removeFirst(cut)
            if let marker = session.clearedThroughMessageID, deleted.contains(marker) { session.clearedThroughMessageID = nil }
            removed += cut
        }
        if removed > 0 { save() }
        return removed
    }
}

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
                            Text("Limits apply to this Mac’s saved transcript. Each prompt and each response counts as one message; a prompt/response pair counts as two. A retained turn stays together, so the count can exceed the limit. Attachments and provider-owned history are not deleted.")
                                .font(.caption).foregroundStyle(.secondary)
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
    private func parse(_ text: String) -> Int? { Int(text.trimmingCharacters(in: .whitespaces)) }
    private var valid: Bool { [days, count].allSatisfy { $0.isEmpty || parse($0).map { (1...1_000_000).contains($0) } == true } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Delete messages older than"); TextField("None", text: $days).frame(width: 85); Text("days") }
            HStack { Text("Keep the most recent"); TextField("None", text: $count).frame(width: 85); Text("prompts and responses") }
            Text("Leave either field blank for None. Defaults: no age limit, 1,000 messages. Checked once a minute while the session is idle, with no draft or pending work. Either limit can remove older messages.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Save limits") {
                    session.transcriptLimits = TranscriptLimits(days: parse(days), count: parse(count))
                    Store.shared.save(); saved = true
                }.disabled(!valid)
                if saved { Text("Saved · applies when idle").font(.caption).foregroundStyle(.secondary) }
            }
        }.textFieldStyle(.roundedBorder)
            .onAppear { days = session.transcriptLimits.days.map(String.init) ?? ""; count = session.transcriptLimits.count.map(String.init) ?? "" }
            .onChange(of: days) { _, _ in saved = false }.onChange(of: count) { _, _ in saved = false }
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
    let preferenceProbe = PerformanceDebugState()
    preferenceProbe.initialize(folder: store.folder, defaults: defaults, info: [:], environment: [:])
    guard !preferenceProbe.automatic, defaults.object(forKey: "performanceRecordOnLaunch") == nil else { throw NSError(domain: "PerformancePreview", code: 2) }
    preferenceProbe.initialize(folder: store.folder, defaults: defaults, info: ["ConverseDevelopmentBuild": true], environment: [:])
    guard preferenceProbe.automatic, defaults.object(forKey: "performanceRecordOnLaunch") == nil else { throw NSError(domain: "PerformancePreview", code: 3) }
    preferenceProbe.turnOff()
    preferenceProbe.initialize(folder: store.folder, defaults: defaults, info: ["ConverseDevelopmentBuild": true], environment: [:])
    guard !preferenceProbe.automatic, defaults.object(forKey: "performanceRecordOnLaunch") as? Bool == false else { throw NSError(domain: "PerformancePreview", code: 4) }
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
    let savedFile = diagnostics.file!
    let savedBytes = try Data(contentsOf: savedFile)
    diagnostics.record(folder: store.folder)
    PerformanceCapture.shared.recordForTesting(.keyDelivery, milliseconds: 500)
    diagnostics.turnOff()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    guard !diagnostics.recording, !diagnostics.paused, diagnostics.file == savedFile,
          try Data(contentsOf: savedFile) == savedBytes else { throw NSError(domain: "PerformancePreview", code: 5) }
    print("PASS: computed recording defaults remain unset; explicit Off persists; Record then Off preserves paused export bytes")
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = NSAppearance(named: appearanceName)!
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
            UserDefaults.standard.set(history, forKey: "performanceHistorySeconds")
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
        request += 1
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
            Toggle("Record automatically on launch", isOn: $capture.automatic)
            Text("Keep a rolling buffer of typing, rendering, saving and main-thread timings locally. No conversations, key characters or credentials are recorded. Nothing is uploaded.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                Text("Keep the last \(Int(capture.history)) seconds").monospacedDigit()
                Slider(value: $capture.history, in: 30...600, step: 10)
                    .accessibilityLabel("History in seconds")
            }.disabled(capture.busy)
            HStack(spacing: 14) {
                Button("Record") { capture.record(folder: Store.shared.folder) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(capture.recording || capture.busy)
                Button("Pause") { capture.pause() }
                    .disabled(!capture.recording || capture.busy)
                Button("Off") { capture.turnOff() }
                    .disabled((!capture.recording && !capture.paused) || capture.busy)
                Button("Export…") { capture.export() }
                    .disabled(capture.file == nil || capture.busy)
            }
            Text(capture.status).foregroundStyle(.secondary).accessibilityIdentifier("performanceCaptureStatus")
            if let error = capture.exportError { Text(error).foregroundStyle(.red) }
            Text("You can close Settings while recording. Pause freezes the recent buffer. Off also disables automatic recording. Record starts a new buffer; Export saves the last paused buffer, which stays saved until you pause again.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
    }
}
