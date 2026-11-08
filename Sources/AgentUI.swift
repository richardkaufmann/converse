import AppKit
import SwiftUI

struct AgentSetupView: View {
    @ObservedObject var session: Session
    @ObservedObject var parkingLots = ParkingLotLibrary.shared
    @State private var settings: AgentConfig
    @State private var metaKey = ""
    @State private var metaKeySaved = true
    private var metaKeyAvailable: Bool { !removeSecrets.contains("meta") && (metaKeySaved || !metaKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    @State private var testingServices: Set<String> = []
    @State private var testOutcomes: [String: String] = [:]
    @State private var githubKey = ""
    @State private var discordToken = ""
    @State private var homeAssistantToken = ""
    @State private var discordClient = AgentDiscordClient()
    @State private var removeSecrets: Set<String> = []
    @State private var error = ""
    @State private var modelOptions: [DeviceChoiceDTO] = []
    @State private var loadingModels = false
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    init(session: Session, onClose: (() -> Void)? = nil) { self.session = session; self.onClose = onClose; _settings = State(initialValue: session.agent ?? AgentConfig()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Setup · " + session.title).font(.title2.bold())
            Text("Runs on this system when Converse is open. Your messages here are shared with the selected provider. If you enable this agent to examine selected sessions, those sessions’ content will also be shared.").font(.callout).foregroundStyle(.secondary)
            if session.needsAgentSetup {
                Text("This session has no saved agent configuration. Review the new settings below before saving. Session access starts empty and the automatic loop starts off; existing transcript and draft are retained. Saved credentials are kept unless you replace or remove them.")
                    .font(.callout).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SecureField("Meta API key · blank keeps saved key", text: $metaKey).disabled(testingServices.contains("meta"))
                            Button(testingServices.contains("meta") ? "Testing…" : "Test key") { testService("meta") }.disabled(testingServices.contains("meta") || removeSecrets.contains("meta")).help("One short model request with no session history; tests the entered key or the saved key")
                            Toggle("Remove saved", isOn: Binding(get: { removeSecrets.contains("meta") }, set: { if $0 { removeSecrets.insert("meta") } else { removeSecrets.remove("meta") } })).toggleStyle(.checkbox).disabled(testingServices.contains("meta")).fixedSize().help("Remove this saved credential from this Mac for all agents when you click Save")
                        }
                        testStatus("meta")
                        HStack {
                            SecureField("GitHub token · optional, blank keeps saved token", text: $githubKey).disabled(testingServices.contains("github"))
                            Button(testingServices.contains("github") ? "Testing…" : "Test GitHub") { testService("github") }.disabled(testingServices.contains("github") || removeSecrets.contains("github")).help("Check the entered or saved token, repository metadata and optional visitor metrics. With no token, tests public access.")
                            Toggle("Remove saved", isOn: Binding(get: { removeSecrets.contains("github") }, set: { if $0 { removeSecrets.insert("github") } else { removeSecrets.remove("github") } })).toggleStyle(.checkbox).disabled(testingServices.contains("github")).fixedSize().help("Remove this saved credential from this Mac for all agents when you click Save")
                        }
                        testStatus("github")
                        HStack {
                            SecureField("Discord bot token · shared on this Mac", text: $discordToken).disabled(testingServices.contains("discordBot"))
                            Button(testingServices.contains("discordBot") ? "Testing…" : "Test Discord") { testService("discordBot") }.disabled(testingServices.contains("discordBot") || removeSecrets.contains("discordBot"))
                                .help("Posts one labeled test and reads it back through channel history. No session content or mentions. Does not save credentials or advance any agent’s read position.")
                            Toggle("Remove saved", isOn: Binding(get: { removeSecrets.contains("discordBot") }, set: { if $0 { removeSecrets.insert("discordBot") } else { removeSecrets.remove("discordBot") } })).toggleStyle(.checkbox).disabled(testingServices.contains("discordBot")).fixedSize()
                        }
                        HStack {
                            Text("Discord channel").frame(width: 110, alignment: .leading)
                            TextField("Channel ID · this agent", text: Binding(get: { settings.discordChannelID ?? "" }, set: { settings.discordChannelID = $0 })).disabled(testingServices.contains("discordBot"))
                        }
                        Text("One Converse bot serves all agents. Enable Message Content Intent in Discord; invite it with View Channel, Read Message History and Send Messages. Copy the channel ID with Discord Developer Mode enabled.").font(.caption).foregroundStyle(.secondary)
                        testStatus("discordBot")
                        Text("Home Assistant").font(.headline)
                        TextField("Home Assistant URL · e.g. http://homeassistant.local:8123", text: Binding(get: { settings.homeAssistantURL ?? "" }, set: { settings.homeAssistantURL = $0 }))
                        HStack {
                            SecureField("Long-lived access token · blank keeps saved token", text: $homeAssistantToken).disabled(testingServices.contains("homeAssistant"))
                            Button(testingServices.contains("homeAssistant") ? "Testing…" : "Test HA") { testService("homeAssistant") }
                                .disabled(testingServices.contains("homeAssistant") || removeSecrets.contains("homeAssistant"))
                            Toggle("Remove saved", isOn: Binding(get: { removeSecrets.contains("homeAssistant") }, set: { if $0 { removeSecrets.insert("homeAssistant") } else { removeSecrets.remove("homeAssistant") } })).toggleStyle(.checkbox).fixedSize()
                        }
                        testStatus("homeAssistant")
                        TextField("Readable entity IDs · comma separated", text: Binding(get: { settings.homeAssistantEntities ?? "" }, set: { settings.homeAssistantEntities = $0 }))
                        Toggle("Let this agent read selected Home Assistant states", isOn: Binding(get: { settings.homeAssistantRead == true }, set: { settings.homeAssistantRead = $0 }))
                        Text("Read only. Choose up to 32 entity IDs; the agent receives their states, names and observation times, never the token. Use HTTPS outside a trusted local network. Credentials are shared by agents on this Mac; each agent selects its own entities.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Picker("Model", selection: $settings.model) {
                                if !modelOptions.contains(where: { $0.id == settings.model }) { Text(AgentModels.label(settings.model) + " · current").tag(settings.model) }
                                ForEach(modelOptions) { option in Text(option.label).tag(option.id) }
                            }.disabled(session.busy || testingServices.contains("meta"))
                            Button(loadingModels ? "Loading…" : "Refresh models") { loadModels() }.disabled(loadingModels)
                        }
                        Text("CLI models use the selected login. Meta API models, portraits and voice use the Meta key. Catalog visibility does not guarantee access. CLI agents use supplied evidence; hosted web research currently requires a Meta API model.").font(.caption).foregroundStyle(.secondary)
                        HStack { Text("Repository").frame(width: 90, alignment: .leading); TextField("Optional · owner/name or leave blank", text: $settings.repository).disabled(testingServices.contains("github")) }
                        Text("What should this agent do? How will you judge success?").font(.headline)
                        TextEditor(text: $settings.objective).frame(height: 85).border(Color.secondary.opacity(0.3))
                        Text(settings.objective != session.agent?.objective ? "Timing is read from the objective when you save. Say how often to run, e.g. “run every five minutes while the US market is open”."
                             : settings.pacingSummary(extracting: AgentRuntime.shared.readingPacing(session)))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            .help("Describe how often to run in the objective. Converse reads it once per edit with this agent’s model; Stop, budgets, a 1 minute floor and a 72 hour ceiling always apply.")
                        Stepper("Maximum turns per loop: \(settings.turnLimit)", value: $settings.turnLimit, in: 1...1000)
                        Toggle("Enable automatic loop", isOn: $settings.enabled)
                        Toggle("Auto pacing · the agent picks each next check", isOn: Binding(get: { settings.autoPaceOn }, set: { settings.autoPace = $0 }))
                            .help("Each run may suggest when to check next, with a short reason. Sooner while things change or someone waits, later when quiet. Kept within the bounds below and any window in the objective. A cadence stated in the objective always wins.")
                        if settings.autoPaceOn {
                            HStack(spacing: 16) {
                                Stepper("No sooner than " + AgentPacing.durationText(minutes: settings.paceMinMinutes), value: Binding(get: { settings.paceMinMinutes }, set: { settings.autoPaceMinMinutes = $0; if settings.paceMaxMinutes < $0 { settings.autoPaceMaxMinutes = $0 } }), in: 1...1440, step: 1)
                                Stepper("no later than " + AgentPacing.durationText(minutes: settings.paceMaxMinutes), value: Binding(get: { settings.paceMaxMinutes }, set: { settings.autoPaceMaxMinutes = max($0, settings.paceMinMinutes) }), in: 1...10080, step: settings.paceMaxMinutes >= 120 ? 60 : 5)
                            }.font(.caption)
                        }
                        Text("Every turn updates this agent's assessment against the objective above.").font(.caption).foregroundStyle(.secondary)
                        Text("Portrait art direction").font(.headline)
                        TextEditor(text: Binding(get: { settings.artDirection ?? "" }, set: { settings.artDirection = $0 })).frame(height: 80).border(Color.secondary.opacity(0.3))
                        Text("Portraits are made on demand with Muse Image" + (metaKeyAvailable ? "" : " (needs a Meta API key)") + ", from this agent's assessment, objective and this direction: View → Portraits, Get Portrait, a session, Jolly or Discord. Nothing is generated automatically. Factual numbers stay out of the art; ask here for stylistic lettering if you want it.").font(.caption).foregroundStyle(.secondary)
                        Stepper("New portrait at most every " + AgentPacing.minutesText(settings.portraitMinutes) + " min · Refresh always works", value: Binding(get: { settings.portraitMinutes }, set: { settings.portraitMinMinutes = $0 }), in: 1...1440, step: settings.portraitMinutes >= 30 ? 10 : 1).font(.caption)
                        Toggle("Allow web research for current facts and news", isOn: Binding(get: { settings.webSearch != false }, set: { settings.webSearch = $0 }))
                        Toggle("Allow Jolly to address this agent", isOn: Binding(get: { settings.jollyAllowed != false }, set: { settings.jollyAllowed = $0 }))
                        Text("Speech starts only with Start talking in the session. Scheduled runs stay silent.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Accept file events from this agent’s Inbox", isOn: Binding(get: { settings.fileTriggers == true }, set: { settings.fileTriggers = $0 }))
                        if settings.fileTriggers == true { Text(Store.shared.folder.appendingPathComponent("Agents/" + session.id.uuidString + "/Inbox").path).font(.caption).textSelection(.enabled) }
                        Toggle("Read Discord channel during agent runs", isOn: Binding(get: { settings.discordRead == true }, set: { settings.discordRead = $0 }))
                        Toggle("Allow Discord channel alerts", isOn: $settings.discord)
                        Toggle("Anyone in this channel may @mention this agent", isOn: Binding(get: { settings.discordMentions == true }, set: { settings.discordMentions = $0 }))
                        if settings.discordMentions == true {
                            Toggle("Share session information", isOn: Binding(get: { settings.discordShareSessionInformation == true }, set: { settings.discordShareSessionInformation = $0 }))
                                .help("Allows this agent’s recent conversation, working notes and assessment in Discord replies, only in a verified private channel.")
                            Toggle("Share assessments and portraits on Discord requests", isOn: Binding(get: { settings.discordShareScoreboard == true }, set: { settings.discordShareScoreboard = $0 }))
                            Toggle("Default agent for this channel", isOn: Binding(get: { settings.discordDefault == true }, set: { settings.discordDefault = $0 }))
                            Text("Checks every 5 seconds while Converse is open. Use @Converse Agent Name: question, or just @Converse question for the default. Each request gets a fresh activation limit and queues while busy. Public answers have no private session history or working notes. DMs and unconfigured threads are not monitored.").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Sessions this agent may read and message · select explicitly").font(.headline)
                        // Keep the scope list in the form’s single scroll view so every row is reachable.
                        VStack(alignment: .leading) {
                            ForEach(parkingLots.records) { lot in
                                Toggle(lot.name + " · read and edit", isOn: Binding(get: { settings.allows(local: lot.id, home: DeviceSyncService.shared.localDeviceID) }, set: { on in
                                    settings.watchedSessions.removeAll { $0 == lot.id }
                                    if let home = DeviceSyncService.shared.localDeviceID { settings.watchedParticipants?.removeAll { $0 == DeviceGlobalID(home: home, session: lot.id).string } }
                                    if on { settings.watchedSessions.append(lot.id) }
                                }))
                            }
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
                    }
                    .textFieldStyle(.roundedBorder)
                    if !error.isEmpty { Text(error).foregroundStyle(.red) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Button("Cancel") { close() }; Button("Reload settings") { settings = session.agent ?? AgentConfig(); error = "" }.disabled(!testingServices.isEmpty); Spacer(); Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!testingServices.isEmpty) }
        }.padding(22).frame(width: 650, height: 750).onAppear { loadModels() }
    }
    private func loadModels() {
        guard !loadingModels else { return }; loadingModels = true
        metaKeySaved = ((try? AgentSecrets.read("meta")) ?? nil)?.isEmpty == false
        modelOptions = AgentModels.options(store: .shared)
        Task { @MainActor in
            modelOptions = await AgentModels.catalog(store: .shared)
            loadingModels = false
        }
    }

    @ViewBuilder private func testStatus(_ service: String) -> some View {
        if let outcome = testOutcomes[service], !outcome.isEmpty {
            Text(outcome).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func testService(_ service: String) {
        guard !testingServices.contains(service), !removeSecrets.contains(service) else { return }
        testingServices.insert(service)
        testOutcomes[service] = service == "discordBot" ? "Testing send and read with one labeled message; no session content or mentions." : "Checking access; no session history is sent."
        let entered = service == "meta" ? metaKey : service == "github" ? githubKey : service == "homeAssistant" ? homeAssistantToken : discordToken
        let discordChannel = settings.discordChannelID ?? ""
        let model = AgentModels.parse(settings.model) == nil ? settings.model : "muse-spark-1.3", repository = settings.repository.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            defer { testingServices.remove(service) }
            do {
                let key = try AgentCredentialProbe.resolve(entered, name: service)
                let api = AgentAPI()
                switch service {
                case "homeAssistant":
                    guard let key else { throw AgentFailure.message("Enter a Home Assistant token or save one first.") }
                    testOutcomes[service] = try await AgentHomeAssistant().test(address: settings.homeAssistantURL ?? "", token: key, entityText: settings.homeAssistantEntities ?? "")
                case "github": testOutcomes[service] = try await api.testGitHub(repository: repository, token: key)
                case "discordBot":
                    guard let key else { throw AgentFailure.message("Enter a Converse bot token or save one first.") }
                    testOutcomes[service] = try await discordClient.test(channel: discordChannel, token: key, api: api)
                default:
                    guard let key else { throw AgentFailure.message("Enter a Meta API key or save one first.") }
                    _ = try await api.respond(model: model, instructions: "Reply with the words Connection verified. Do not use tools.", input: "Converse API connection test. No private session data is included.", key: key)
                    testOutcomes[service] = "Key accepted; the selected model returned a complete response. No session history was sent."
                }
            } catch let error as AgentFailure { testOutcomes[service] = error.localizedDescription }
            catch { testOutcomes[service] = "Could not complete the test. Check Keychain access and the network, then try again." }
        }
    }
    private var availableScope: Set<String> {
        let service = DeviceSyncService.shared
        return Set((service.localDeviceID.map { home in parkingLots.records.map { DeviceGlobalID(home: home, session: $0.id).string } } ?? []) + service.participantHomes.flatMap { $0.rows.map(\.globalID) } + Store.shared.sessions.compactMap { session in service.localDeviceID.map { DeviceGlobalID(home: $0, session: session.id).string } })
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    private func save() {
        settings.repository = settings.repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Enter a model."; return }
        guard settings.repository.isEmpty || AgentRepoSnapshot.validRepository(settings.repository) else { error = "Enter a repository as owner/name, or leave it blank."; return }
        guard settings.intervalSeconds.isFinite else { error = "Enter a valid interval."; return }
        do {
            var current = session.agent ?? AgentConfig()
            let migrationNotice = try current.apply(settings.wire(home: DeviceSyncService.shared.localDeviceID ?? "local"))
            guard ![("meta", metaKey), ("github", githubKey), ("discordBot", discordToken), ("homeAssistant", homeAssistantToken)].contains(where: { removeSecrets.contains($0.0) && !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { error = "Choose either replacement or removal for each credential."; return }
            if settings.homeAssistantRead == true {
                guard !removeSecrets.contains("homeAssistant"), try AgentCredentialProbe.resolve(homeAssistantToken, name: "homeAssistant") != nil else {
                    throw AgentFailure.message("Add a Home Assistant token before enabling state reading.")
                }
            }
            let channel = (settings.discordChannelID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !channel.isEmpty || settings.discordRead == true || settings.discord || settings.discordMentions == true { _ = try AgentDiscord.channelID(channel) }
            if settings.discordRead == true || settings.discord || settings.discordMentions == true {
                guard !removeSecrets.contains("discordBot"), try AgentCredentialProbe.resolve(discordToken, name: "discordBot") != nil else { throw AgentFailure.message("Add a Converse bot token before enabling Discord reading or alerts.") }
            }
            if current.discordChannelID != channel { current.discordLastMessageID = nil; current.discordCursorChannel = nil }
            if settings.discordMentions == true && settings.discordDefault == true && Store.shared.sessions.contains(where: {
                $0.id != session.id && $0.agent?.discordMentions == true && $0.agent?.discordDefault == true && $0.agent?.discordChannelID == channel
            }) { throw AgentFailure.message("This channel already has a default agent. Turn off its Default setting first, or use explicit agent names.") }
            if current.discordMentions != settings.discordMentions || current.discordChannelID != channel {
                current.discordMentionSince = settings.discordMentions == true ? Date() : nil
            }
            current.discordShareScoreboard = settings.discordShareScoreboard
            current.discordShareSessionInformation = settings.discordShareSessionInformation
            current.discordMentions = settings.discordMentions; current.discordDefault = settings.discordDefault
            current.discordChannelID = channel; current.discordRead = settings.discordRead
            try AgentSecrets.update("meta", value: metaKey, remove: removeSecrets.contains("meta"))
            try AgentSecrets.update("github", value: githubKey, remove: removeSecrets.contains("github"))
            try AgentSecrets.update("discordBot", value: discordToken, remove: removeSecrets.contains("discordBot"))
            try AgentSecrets.update("homeAssistant", value: homeAssistantToken, remove: removeSecrets.contains("homeAssistant"))
            current.webSearch = settings.webSearch; current.jollyAllowed = settings.jollyAllowed
            let notice = migrationNotice
            try current.setAutoPace(settings.autoPaceOn, minMinutes: settings.paceMinMinutes, maxMinutes: settings.paceMaxMinutes, now: Date())
            try current.setPortraitInterval(minutes: settings.portraitMinutes)
            session.agent = current; session.toolStatus.model = AgentModels.label(current.model)
            session.probeError = ""; session.needsSignIn = false
            if !session.busy { session.status = "Ready" }
            if current.enabled && session.pending.isEmpty { session.queuePaused = false }
            Store.shared.save()
            AgentRuntime.shared.objectiveSaved(session, store: .shared, notice: notice, retryFailed: true)
            close()
        } catch { self.error = error.localizedDescription }
    }
}

struct AgentControls: View {
    @ObservedObject var session: Session
    @State private var loopSettings = false
    @State private var dictating = false
    @StateObject private var voice = AgentDictation()
    @ObservedObject private var conversation = AgentConversation.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                HStack(spacing: 8) {
                    ConversationActivity(busy: session.busy, status: "Agent thinking", waiting: false)
                    let loop = session.agent?.loopStatus(at: context.date, busy: session.busy, queuePaused: session.queuePaused, pendingCount: session.pending.count) ?? "Loop off"
                    StatusMenu(help: loop + (session.agent.map { "\n" + $0.pacingSummary(extracting: AgentRuntime.shared.readingPacing(session)) } ?? "")
                               + "\nClick to pause or resume the loop, stop this run or run once.") {
                        AgentRunControls(session: session, runOnce: true)
                    } label: { hovering in
                        HStack(spacing: 8) {
                            Text(session.interrupted ? "Stopping…" : session.busy ? "Thinking now" : "Idle").fontWeight(.semibold).underline(hovering)
                            Text(loop).foregroundStyle(.secondary).lineLimit(1).underline(hovering)
                        }
                    }
                    Spacer(minLength: 0)
                }.font(.caption)
            }
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 12) {
                    Text(session.agent.map { AgentModels.label($0.model) } ?? "Agent").font(.caption).foregroundStyle(.secondary)
                    if let agent = session.agent {
                        let timing = agent.pacingSummary(extracting: AgentRuntime.shared.readingPacing(session))
                        Text(timing).font(.caption).foregroundStyle(.secondary).lineLimit(1).help("Timing from the objective: " + timing)
                    }
                    Text("\(session.agent?.turnLimit ?? 0) maximum turns per loop").font(.caption).foregroundStyle(.secondary)
                    if session.agent?.discordMentions == true {
                        TimelineView(.periodic(from: .now, by: 5)) { _ in
                            Text(AgentRuntime.shared.discordRouter.status(for: session)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if session.toolStatus.usage != "not reported" {
                        Text("Last turn: " + session.toolStatus.usage).font(.caption).foregroundStyle(.secondary).help("Last turn: " + session.toolStatus.usage + ". Cached input is billed at a lower rate.")
                    }
                    if let account = AgentModels.apiKeyAccount(session.agent?.model) {
                        Text(account.label).font(.caption).foregroundStyle(.secondary).help(account.help)
                    } else {
                        AccountStatusView(status: session.toolStatus, refreshing: false) { Store.shared.refreshStatus(session) }.font(.caption)
                    }
                } }.frame(maxWidth: .infinity)
                Menu {
                    AgentRunControls(session: session, runOnce: false)
                    Divider()
                    Button("Agent Setup / Loop…") { AgentWindows.shared.setup(session) }
                    Button("Run once") { Store.shared.queueAgentRun(session) }
                        .disabled(session.busy || (session.agent?.turnLimit ?? 0) == 0)
                    Button("Refresh assessment now") { Store.shared.queueAssessmentRefresh(session) }
                        .disabled((session.agent?.turnLimit ?? 0) == 0)
                        .help("Ask the agent to reassess now without other actions; while it is busy, this runs as its next turn")
                    Button("Assessment") { AgentWindows.shared.widget(session) }
                    Divider()
                    Button("Loop controls…") { loopSettings = true }
                    Button(conversation.owns(session) ? "Stop talking" : "Start talking!") {
                        if conversation.owns(session) { conversation.stop() }
                        else { dictating = false; voice.cancel(); conversation.start(session, store: .shared) }
                    }
                    Button("Dictate…") { conversation.stop(); dictating = true }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Agent actions: pause, resume or stop; setup, loop, run once, assessment and voice")
                    .accessibilityLabel("Agent actions")
                    .popover(isPresented: $loopSettings) { AgentLoopOptions(session: session, close: { loopSettings = false }) }
                    .popover(isPresented: $dictating) { AgentDictationView(voice: voice, session: session, close: { dictating = false }) }
            }
            if conversation.sessionID == session.id {
                HStack {
                    Label(conversation.status, systemImage: conversation.phase == .listening ? "mic.fill" : "speaker.wave.2.fill")
                        .font(.caption).foregroundStyle(conversation.active ? Color.orange : Color.secondary)
                        .lineLimit(2).help(conversation.lastHeard.isEmpty ? conversation.status : "Heard: " + conversation.lastHeard)
                    if conversation.active { Button("Stop talking") { conversation.stop() }.keyboardShortcut(.escape, modifiers: []) }
                }
            }
        }.padding(8).frame(height: conversation.sessionID == session.id ? 94 : 66)
            .onChange(of: session.id) { old, _ in
                voice.cancel(); dictating = false
                if conversation.sessionID == old { conversation.stop() }
            }
            .onDisappear { if conversation.owns(session) { conversation.stop() } }
    }
}

// Pause/Resume loop and Stop current run, shared by the … menu and the
// clickable footer status.
struct AgentRunControls: View {
    @ObservedObject var session: Session
    var runOnce: Bool
    var body: some View {
        if session.agent?.enabled == true {
            Button("Pause loop") { Store.shared.pauseAgentLoop(session) }
                .help("Stop automatic checks. A run in progress finishes.")
        } else {
            Button("Resume loop") { Store.shared.resumeAgentLoop(session) }
                .disabled((session.agent?.turnLimit ?? 0) == 0)
                .help("Clear the pause and schedule the next check")
        }
        if session.busy {
            Button("Stop current run") { Store.shared.stopAgentRun(session) }
                .disabled(session.interrupted)
                .help("Cancel this run only; the loop stays on unless paused")
        }
        if runOnce {
            Button("Run once") { Store.shared.queueAgentRun(session) }
                .disabled(session.busy || (session.agent?.turnLimit ?? 0) == 0)
        }
        if !session.pending.isEmpty {
            Button(session.queuePaused ? "Resume queue" : "Pause queue") { Store.shared.toggleQueue(session) }
        }
    }
}

// Footer status text that opens a small control menu. It underlines and
// shows a pointing hand on hover so it reads as clickable.
struct StatusMenu<Content: View, Label: View>: View {
    var help: String
    var fixed = true
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: (Bool) -> Label
    @State private var hovering = false
    var body: some View {
        Menu { content() } label: { label(hovering).contentShape(Rectangle()) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: fixed, vertical: true)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help(help)
    }
}

// An ordinary session's footer status: Stop interrupts the current turn,
// as the Stop button does; the queue can be paused or resumed.
struct SessionStatusMenu: View {
    @ObservedObject var session: Session
    var compact: Bool
    var body: some View {
        StatusMenu(help: session.status + "\nClick to stop this turn" + (session.pending.isEmpty ? "" : " or pause the queue"), fixed: !compact) {
            Button("Stop") { Store.shared.stop(session) }
                .disabled(!session.busy && session.claudeLive == nil)
                .help("Interrupt the current turn; queued messages wait")
            if !session.pending.isEmpty {
                Button(session.queuePaused ? "Resume queue" : "Pause queue") { Store.shared.toggleQueue(session) }
            }
        } label: { hovering in
            Text(session.status).foregroundStyle(StatusTint.status(session)).underline(hovering)
                .lineLimit(1).truncationMode(.tail)
        }
    }
}

struct AgentLoopOptions: View {
    @ObservedObject var session: Session
    @State private var enabled = false
    @State private var minutes: Double = 15
    @State private var turns = 20
    @State private var revision: UInt64 = 0
    @State private var error = ""
    @State private var modelOptions: [DeviceChoiceDTO] = []
    @State private var loadingModels = false
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent loop").font(.headline)
            Text(session.busy ? "Thinking now. Changing the loop does not stop this run." : "Idle. You can still talk to this agent while its loop is off.").font(.callout).foregroundStyle(.secondary)
            Toggle("Automatic loop", isOn: $enabled)
            Text(session.agent?.pacingSummary(extracting: AgentRuntime.shared.readingPacing(session)) ?? "").font(.caption).foregroundStyle(.secondary)
                .help("Timing comes from the objective. Edit it in Agent Setup to change how often this agent runs.")
            Stepper("Maximum turns per loop: \(turns)", value: $turns, in: 1...1000)
            Text("A fresh ceiling for each activation. Checks currently use one model response; future scheduled checks are not spent.").font(.caption).foregroundStyle(.secondary)
            Text("Every turn, including Run once, updates the assessment. Loops run while Converse is open on this agent’s home. Hiccups retry with back-off and never pause the loop; only problems you must fix, such as a rejected key, pause it.").font(.caption).foregroundStyle(.secondary)
            if session.queuePaused && !session.pending.isEmpty { Text("Held messages require Resume queue before the loop can continue.").font(.caption).foregroundStyle(.orange) }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Reload") { reload() }
                Button("Run once now") { if save() { Store.shared.queueAgentRun(session); close() } }.disabled(session.busy || turns == 0)
                Spacer()
                Button("Done") { if save() { close() } }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 410).textFieldStyle(.roundedBorder).onAppear { reload() }
    }
    private func reload() {
        let config = session.agent ?? AgentConfig()
        enabled = config.enabled; minutes = config.intervalSeconds / 60; turns = config.turnLimit; revision = config.settingsRevision ?? 0; error = ""
    }
    private func save() -> Bool {
        do { try Store.shared.configureAgentLoop(session, enabled: enabled, interval: minutes * 60, turns: turns, expectedRevision: revision); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}

// The widget window shows the agent's latest assessment, the same content
// remote viewers, the HTML export and the Discord status image derive from.
struct AgentWidgetView: View {
    @ObservedObject var session: Session
    private let ink = Color(red: 0.07, green: 0.10, blue: 0.15)
    private let card = Color(red: 0.12, green: 0.16, blue: 0.22)
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date, content = (session.agent ?? AgentConfig()).widgetContent(now: now)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Background art must never contribute its intrinsic size to the document.
                    ZStack(alignment: .bottomLeading) {
                        GeometryReader { geometry in
                            if let path = session.agent?.portrait?.latest?.path ?? session.agent?.artPath, let image = NSImage(contentsOfFile: path) {
                                Image(nsImage: image).resizable().scaledToFill()
                                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            } else {
                                LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                        }
                        LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("AGENT ASSESSMENT").font(.caption.bold()).tracking(2).foregroundStyle(.white.opacity(0.8))
                            Text(session.title).font(.system(size: 28, weight: .bold)).lineLimit(2)
                            Text(session.agent?.repository ?? "")
                                .font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                        }.padding(24)
                    }.frame(height: 220).clipped()
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 8) {
                            if let status = content.status { AssessmentStatusPill(status: status) }
                            Text(content.line(now: now)).font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                        Text(content.summary).font(.title3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let problem = content.problem {
                            Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                        if !content.facts.isEmpty {
                            LazyVGrid(columns: [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))], spacing: 10) {
                                ForEach(content.facts) { fact in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(fact.value == AgentFact.unavailable ? "—" : fact.value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(2).textSelection(.enabled)
                                        Text(fact.label).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                                        Text(fact.kind.label + " · " + AgentAge.short(fact.observedAt, now: now)).font(.caption2).foregroundStyle(.white.opacity(0.55)).help(fact.kind.help + " · " + fact.source)
                                    }.frame(maxWidth: .infinity, minHeight: 65, alignment: .leading).padding(14)
                                        .background(card, in: RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                        if let attention = session.agent?.attention, !attention.isEmpty {
                            Label(attention, systemImage: "exclamationmark.triangle.fill").font(.callout)
                                .foregroundStyle(.black).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                .background(.yellow, in: RoundedRectangle(cornerRadius: 10))
                        }
                        HStack {
                            Button("Agent Setup…") { AgentWindows.shared.setup(session) }
                            Button("Refresh assessment now") { Store.shared.queueAssessmentRefresh(session) }.disabled((session.agent?.turnLimit ?? 0) == 0)
                            Spacer()
                            Button("Export…") { AgentWindows.shared.export(session) }
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(ink).foregroundStyle(.white).preferredColorScheme(.dark)
            .frame(minWidth: 420, minHeight: 500)
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
        // The assessment widget is a companion view, including when requested remotely.
        // Showing it must not move keyboard focus away from an active draft.
        if let window = widgets[session.id] { window.orderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = session.title + " · Assessment"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AgentWidgetView(session: session)); widgets[session.id] = window
        window.center(); window.orderFront(nil)
    }
    func setup(_ session: Session) {
        if let old = setups[session.id], old.isVisible { old.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 750), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Agent Setup"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AgentSetupView(session: session, onClose: { [weak window] in window?.close() }))
        setups[session.id] = window; window.center(); window.makeKeyAndOrderFront(nil)
    }
    func export(_ session: Session) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = session.title + " Assessment.html"; panel.allowedContentTypes = [.html]
        if panel.runModal() == .OK, let url = panel.url {
            do { try AgentWidgetExport.html(session).write(to: url, atomically: true, encoding: .utf8) }
            catch { let alert = NSAlert(); alert.messageText = "Could not export assessment"; alert.informativeText = error.localizedDescription; alert.runModal() }
        }
    }
}

enum AgentWidgetExport {
    static func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
    static func html(_ session: Session, now: Date = Date()) -> String {
        let config = session.agent ?? AgentConfig(), content = config.widgetContent(now: now)
        var art = ""
        if let path = config.portrait?.latest?.path ?? config.artPath, let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)), bytes.count <= 8_000_000 { art = "<img class=art alt='Agent portrait' src='data:image/png;base64," + bytes.base64EncodedString() + "'>" }
        let cells = content.facts.map { fact in
            "<div class=metric><strong>" + escape(fact.value == AgentFact.unavailable ? "—" : fact.value) + "</strong><span>" + escape(fact.label) + "</span><small>" + escape(fact.kind.label + " · " + fact.source + (fact.observedAt.map { " · " + $0.formatted() } ?? "")) + "</small></div>"
        }.joined()
        let facts = cells.isEmpty ? "" : "<div class=grid>" + cells + "</div>"
        let problem = content.problem.map { "<p class=problem>" + escape($0) + "</p>" } ?? ""
        return """
        <!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content="width=device-width, initial-scale=1"><meta http-equiv=Content-Security-Policy content="default-src 'none'; img-src data:; style-src 'unsafe-inline'"><title>\(escape(session.title))</title><style>
        *{box-sizing:border-box}body{margin:0;background:#121a26;color:#fff;font:15px/1.6 system-ui}main{max-width:780px;margin:auto}header{position:relative;isolation:isolate;min-height:240px;display:flex;align-items:flex-end;overflow:hidden;background:linear-gradient(135deg,#373064,#174e59)}.art{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;z-index:-2}header:after{content:'';position:absolute;inset:0;background:linear-gradient(transparent,#000e);z-index:-1}.heading{padding:28px;overflow-wrap:anywhere}.eyebrow{font-size:11px;letter-spacing:.18em;color:#ddd}h1{font-size:30px;line-height:1.2;margin:8px 0}.repository{color:#ddd}.content{padding:28px;overflow-wrap:anywhere}.status{font-size:13px;color:#bbc4d1;margin-bottom:10px}.summary{font-size:19px;margin-bottom:20px}.problem{color:#fdba74;margin-bottom:16px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}.metric{padding:18px;background:#1f2938;border-radius:12px}.metric strong{display:block;font-size:26px;line-height:1.3}.metric span{display:block;font-size:12px;color:#bbc4d1}.metric small{font-size:11px;color:#8b97a8}p{white-space:pre-wrap;margin:0}.attention{background:#facc15;color:#111;padding:16px;border-radius:10px;margin-top:20px}footer{font-size:12px;color:#a3afbf;margin-top:24px}@media(max-width:420px){.heading,.content{padding:18px}h1{font-size:25px}}
        </style><main><header>\(art)<div class=heading><div class=eyebrow>AGENT ASSESSMENT</div><h1>\(escape(session.title))</h1><div class=repository>\(escape(config.repository))</div></div></header><div class=content><p class=status>\(escape(content.line(now: now)))</p><p class=summary>\(escape(content.summary))</p>\(problem)\(facts)\(config.attention.isEmpty ? "" : "<p class=attention>" + escape(config.attention) + "</p>")<footer>Assessment · \(escape(content.updatedAt.map { "updated " + $0.formatted() } ?? "none yet"))\(escape(content.checkedAt.map { " · checked " + $0.formatted() } ?? ""))<br>Richard Kaufmann · richard@kaoslabs.app · www.kaoslabs.app</footer></div></main></html>
        """
    }

    static func writeSnapshot(_ session: Session, store: Store) throws {
        let folder = store.folder.appendingPathComponent("Agents/" + session.id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try html(session).write(to: folder.appendingPathComponent("widget.html"), atomically: true, encoding: .utf8)
        let metricsURL = folder.appendingPathComponent("metrics.json")
        if let snapshot = session.agent?.repositorySnapshot { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; try encoder.encode(snapshot).write(to: metricsURL, options: .atomic) }
        else if FileManager.default.fileExists(atPath: metricsURL.path) { try FileManager.default.removeItem(at: metricsURL) }
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
    @State private var settings = DeviceAgentSettings(objective: "", repository: "", model: "muse-spark-1.3", watched: [], intervalSeconds: 900, remainingRuns: 20, enabled: false, generateArt: true, speak: false, discord: false)
    @State private var loaded = false
    @State private var working = false
    @State private var outcome = "Loading home settings…"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Setup").font(.title2.bold())
            Text("Credentials are configured on the execution home. This device changes settings without receiving API keys.").font(.callout).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 10) {
                TextField("Objective and success criteria", text: $settings.objective, axis: .vertical).lineLimit(3...6)
                TextField("Optional repository · owner/name", text: $settings.repository)
                TextField("Model", text: $settings.model)
                HStack { Text("Check every"); TextField("Minutes", value: Binding(get: { settings.intervalSeconds / 60 }, set: { settings.intervalSeconds = $0 * 60 }), format: .number).frame(width: 80); Text("minutes") }
                Text("Homes that read timing from the objective use it instead; describe how often to run there.").font(.caption).foregroundStyle(.secondary)
                Stepper("Maximum turns per loop: \(settings.turnLimit)", value: $settings.turnLimit, in: 1...1000)
                Toggle("Enable scheduled loop", isOn: $settings.enabled)
                TextField("Portrait art direction", text: Binding(get: { settings.artDirection ?? "" }, set: { settings.artDirection = $0 }), axis: .vertical).lineLimit(3...6)
                Text("Speech requires Start talking on the viewing Mac.").font(.caption).foregroundStyle(.secondary)
                Toggle("Allow configured Discord alerts", isOn: $settings.discord)
                Toggle("Share session information", isOn: Binding(get: { settings.discordShareSessionInformation == true }, set: { settings.discordShareSessionInformation = $0 })).help("Only in verified private Discord channels.")
                Toggle("Share assessments and portraits on Discord requests", isOn: Binding(get: { settings.discordShareScoreboard == true }, set: { settings.discordShareScoreboard = $0 }))
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
                Button("Show assessment on home") { perform("agent.widget") }.disabled(!loaded || working)
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

