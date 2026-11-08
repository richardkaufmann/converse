import SwiftUI

// Agent execution and credentials stay on the selected desktop home. Controls
// use the same durable participant protocol as Mac, without taking a pane lease.
struct PadAgentPanel: View {
    let home: String
    let target: String?
    @ObservedObject private var service = DeviceSyncService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var title = "New Agent"
    @State private var settings: DeviceAgentSettings?
    @State private var working = false
    @State private var notice = ""
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("Runs on \(service.displayName(for: home, fallback: service.homes[home]?.deviceName ?? "its home computer")) while Converse is open there. Your messages are shared with the selected provider. Selected sessions are shared too. API keys stay on the home computer.").font(.caption) }
                if target == nil {
                    TextField("Agent name", text: $title)
                    Button("Create Agent") { perform("agent.create") }.disabled(working || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if settings != nil {
                    Picker("Model", selection: field(\.model)) {
                        if let settings, !(settings.modelOptions ?? []).contains(where: { $0.id == settings.model }) { Text("Current model").tag(settings.model) }
                        ForEach(settings?.modelOptions ?? []) { option in Text(option.label).tag(option.id) }
                    }
                    TextField("GitHub repository · optional", text: field(\.repository))
                    Section("Objective and success criteria") { TextEditor(text: field(\.objective)).frame(minHeight: 110) }
                    Section("Loop") {
                        Toggle("Enable automatic loop", isOn: field(\.enabled))
                        Picker("Frequency", selection: Binding(get: { !(settings?.scheduleText ?? "").isEmpty }, set: { settings?.scheduleText = $0 ? "every 20 minutes while the US stock market is open" : "" })) {
                            Text("Fixed interval").tag(false)
                            Text("Text schedule").tag(true)
                        }.pickerStyle(.segmented)
                        if (settings?.scheduleText ?? "").isEmpty {
                            TextField("Interval in seconds", value: field(\.intervalSeconds), format: .number).keyboardType(.decimalPad)
                        } else {
                        TextField("Text schedule · optional", text: Binding(get: { settings?.scheduleText ?? "" }, set: { settings?.scheduleText = $0.isEmpty ? " " : $0 }), axis: .vertical)
                        TextField("Time zone", text: Binding(get: { settings?.scheduleTimeZone ?? TimeZone.current.identifier }, set: { settings?.scheduleTimeZone = $0 }))
                        }
                        if let settings {
                            switch Result(catching: { try AgentSchedule.compile(interval: settings.intervalSeconds, text: settings.scheduleText, zone: settings.scheduleTimeZone) }) {
                            case .success(let rule):
                                Text(rule.description).font(.caption)
                                Text("Next: " + rule.preview(after: Date()).map { $0.formatted(date: .abbreviated, time: .shortened) }.joined(separator: " · ")).font(.caption)
                            case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red)
                            }
                        }
                        Stepper("Maximum turns per loop: \(settings?.turnLimit ?? 1)", value: field(\.turnLimit), in: 1...1000)
                        Text("The schedule repeats until paused. Each activation currently makes one model response, within this limit; it does not spend future loops.").font(.caption)
                        Stepper("Scoreboard every \(settings?.scoreboardEveryLoops ?? 1) loops", value: Binding(get: { settings?.scoreboardEveryLoops ?? 1 }, set: { settings?.scoreboardEveryLoops = $0 }), in: 1...1000)
                        TextField("Portrait art direction", text: Binding(get: { settings?.artDirection ?? "" }, set: { settings?.artDirection = $0 }), axis: .vertical).lineLimit(3...6)
                        Text("Subject, style, colors or humor for on-demand portraits. Separate from the objective and success criteria. Requires an updated home.").font(.caption)
                        Text("Scheduled runs are silent. Start talking is available on a Mac viewing the agent.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Allow Discord alerts", isOn: field(\.discord))
                        Toggle("Share session information", isOn: Binding(get: { settings?.discordShareSessionInformation == true }, set: { settings?.discordShareSessionInformation = $0 }))
                        Text("Shares this agent’s recent conversation, working notes and scoreboard only in a verified private Discord channel.").font(.caption)
                        Toggle("Share assessments and portraits on Discord requests", isOn: Binding(get: { settings?.discordShareScoreboard == true }, set: { settings?.discordShareScoreboard = $0 }))
                    }
                    Section("Sessions this agent may read and message") {
                        ForEach(service.participantHomes, id: \.deviceID) { host in
                            Text(service.displayName(for: host.deviceID, fallback: host.deviceName)).font(.caption)
                            ForEach(host.rows.filter { $0.globalID != target }) { row in
                                Toggle(row.title, isOn: Binding(get: { settings?.watched.contains(row.globalID) == true }, set: { selected in
                                    settings?.watched.removeAll { $0 == row.globalID }
                                    if selected { settings?.watched.append(row.globalID) }
                                }))
                            }
                        }
                    }
                    Button("Save settings") { perform("agent.configure") }.disabled(working)
                    Button("Save and run once on home") { perform("agent.configure", runAfterSave: true) }.disabled(working)
                    Button("Open scoreboard on home") { perform("agent.widget") }.disabled(working)
                    Button("Reload settings") { perform("agent.settings") }.disabled(working)
                } else if !working { Button("Load Agent Setup") { perform("agent.settings") } }
                if working { ProgressView("Waiting for home…") }
                if !notice.isEmpty { Text(notice).textSelection(.enabled) }
            }.disabled(working).navigationTitle(target == nil ? "Create Agent" : "Agent Setup")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { perform("agent.configure", dismissAfterSave: true) }.disabled(working || settings == nil)
                    }
                }
                .alert("Settings were not saved", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                    Button("OK", role: .cancel) { failure = nil }
                } message: { Text(failure ?? "") }
                .task { if target != nil && settings == nil { perform("agent.settings") } }
        }
    }
    func field<T>(_ path: WritableKeyPath<DeviceAgentSettings, T>) -> Binding<T> {
        Binding(get: { settings![keyPath: path] }, set: { settings?[keyPath: path] = $0 })
    }
    func perform(_ action: String, runAfterSave: Bool = false, dismissAfterSave: Bool = false) {
        guard !working else { return }
        if action == "agent.configure", let settings {
            do { _ = try AgentSchedule.compile(interval: settings.intervalSeconds, text: settings.scheduleText, zone: settings.scheduleTimeZone) }
            catch { notice = error.localizedDescription; failure = notice; return }
        }
        let submitted = settings
        working = true
        Task { @MainActor in
            let response = await service.requestParticipant(home: home, action: action, target: target, title: title, settings: action == "agent.configure" ? submitted : nil)
            if let saved = response.settings { settings = saved }
            notice = response.detail; working = false
            if response.outcome != "completed" { failure = response.detail }
            if action == "agent.configure", response.outcome == "completed" {
                if dismissAfterSave { dismiss() }
                else if runAfterSave { perform("agent.run") }
            }
        }
    }
}
