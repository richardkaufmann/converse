import AppKit
import SwiftUI

struct AgentSetupView: View {
    @ObservedObject var session: Session
    @State private var settings: AgentConfig
    @State private var metaKey = ""
    @State private var testingServices: Set<String> = []
    @State private var testOutcomes: [String: String] = [:]
    @State private var githubKey = ""
    @State private var discordToken = ""
    @State private var discordClient = AgentDiscordClient()
    @State private var removeSecrets: Set<String> = []
    @State private var error = ""
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    init(session: Session, onClose: (() -> Void)? = nil) { self.session = session; self.onClose = onClose; _settings = State(initialValue: session.agent ?? AgentConfig()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Setup · " + session.title).font(.title2.bold())
            Text("Runs on this home computer while Converse is open. Selected sessions and enabled Discord channel messages are sent to Meta. Keys stay in this computer’s Keychain.").font(.callout).foregroundStyle(.secondary)
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
                        HStack { Text("Model").frame(width: 90, alignment: .leading); TextField("Model", text: $settings.model).disabled(testingServices.contains("meta")) }
                        HStack { Text("Repository").frame(width: 90, alignment: .leading); TextField("Optional · owner/name or leave blank", text: $settings.repository).disabled(testingServices.contains("github")) }
                        Text("What should this agent do? How will you judge success?").font(.headline)
                        TextEditor(text: $settings.objective).frame(height: 85).border(Color.secondary.opacity(0.3))
                        AgentScheduleEditor(seconds: $settings.intervalSeconds, text: $settings.scheduleText, zone: $settings.scheduleTimeZone)
                        Stepper("Maximum turns per loop: \(settings.turnLimit)", value: $settings.turnLimit, in: 1...1000)
                        Toggle("Enable automatic loop", isOn: $settings.enabled)
                        Stepper("Refresh scoreboard every \(settings.scoreboardCadence) loops", value: Binding(get: { settings.scoreboardCadence }, set: { settings.scoreboardEveryLoops = $0 }), in: 1...1000)
                        Toggle("Generate mood art with Muse Image (at most once per hour or mood change)", isOn: $settings.generateArt)
                        Toggle("Allow web research for current facts and news", isOn: Binding(get: { settings.webSearch != false }, set: { settings.webSearch = $0 }))
                        Toggle("Allow Jolly to address this agent", isOn: Binding(get: { settings.jollyAllowed != false }, set: { settings.jollyAllowed = $0 }))
                        Toggle("Speak replies with expressive pace", isOn: $settings.speak)
                        Toggle("Accept file events from this agent’s Inbox", isOn: Binding(get: { settings.fileTriggers == true }, set: { settings.fileTriggers = $0 }))
                        if settings.fileTriggers == true { Text(Store.shared.folder.appendingPathComponent("Agents/" + session.id.uuidString + "/Inbox").path).font(.caption).textSelection(.enabled) }
                        Toggle("Read Discord channel during agent runs", isOn: Binding(get: { settings.discordRead == true }, set: { settings.discordRead = $0 }))
                        Toggle("Allow Discord channel alerts", isOn: $settings.discord)
                        Toggle("Anyone in this channel may @mention this agent", isOn: Binding(get: { settings.discordMentions == true }, set: { settings.discordMentions = $0 }))
                        if settings.discordMentions == true {
                            Toggle("Share session information", isOn: Binding(get: { settings.discordShareSessionInformation == true }, set: { settings.discordShareSessionInformation = $0 }))
                                .help("Allows this agent’s recent conversation, working notes and scoreboard in Discord replies, only in a verified private channel.")
                            Toggle("Share scoreboard and mood image on Discord requests", isOn: Binding(get: { settings.discordShareScoreboard == true }, set: { settings.discordShareScoreboard = $0 }))
                            Toggle("Default agent for this channel", isOn: Binding(get: { settings.discordDefault == true }, set: { settings.discordDefault = $0 }))
                            Text("Checks every 5 seconds while Converse is open. Use @Converse Agent Name: question, or just @Converse question for the default. Each request gets a fresh activation limit and queues while busy. Public answers have no private session history or working notes. DMs and unconfigured threads are not monitored.").font(.caption).foregroundStyle(.secondary)
                        }
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
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Button("Cancel") { close() }; Button("Reload settings") { settings = session.agent ?? AgentConfig(); error = "" }.disabled(!testingServices.isEmpty); Spacer(); Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!testingServices.isEmpty) }
        }.padding(22).frame(width: 650, height: 750)
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
        let entered = service == "meta" ? metaKey : service == "github" ? githubKey : discordToken
        let discordChannel = settings.discordChannelID ?? ""
        let model = settings.model, repository = settings.repository.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            defer { testingServices.remove(service) }
            do {
                let key = try AgentCredentialProbe.resolve(entered, name: service)
                let api = AgentAPI()
                switch service {
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
        return Set(service.participantHomes.flatMap { $0.rows.map(\.globalID) } + Store.shared.sessions.compactMap { session in service.localDeviceID.map { DeviceGlobalID(home: $0, session: session.id).string } })
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    private func save() {
        settings.repository = settings.repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Enter a model."; return }
        guard settings.repository.isEmpty || AgentRepoSnapshot.validRepository(settings.repository) else { error = "Enter a repository as owner/name, or leave it blank."; return }
        guard settings.intervalSeconds.isFinite else { error = "Enter a valid interval."; return }
        do {
            var current = session.agent ?? AgentConfig()
            try current.apply(settings.wire(home: DeviceSyncService.shared.localDeviceID ?? "local"))
            guard ![("meta", metaKey), ("github", githubKey), ("discordBot", discordToken)].contains(where: { removeSecrets.contains($0.0) && !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { error = "Choose either replacement or removal for each credential."; return }
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
            current.webSearch = settings.webSearch; current.jollyAllowed = settings.jollyAllowed
            session.agent = current; session.toolStatus.model = current.model
            if current.enabled && session.pending.isEmpty { session.queuePaused = false }
            Store.shared.save(); close()
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
                    Text(session.busy ? "Thinking now" : "Idle").fontWeight(.semibold)
                    Text(session.agent?.loopStatus(at: context.date, busy: session.busy, queuePaused: session.queuePaused, pendingCount: session.pending.count) ?? "Loop off")
                        .foregroundStyle(.secondary).lineLimit(1)
                        .help(session.agent?.loopStatus(at: context.date, busy: session.busy, queuePaused: session.queuePaused, pendingCount: session.pending.count) ?? "Loop off")
                    Spacer(minLength: 0)
                }.font(.caption)
            }
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 12) {
                    Text(session.agent?.model ?? "Agent").font(.caption).foregroundStyle(.secondary)
                    Text("\(session.agent?.turnLimit ?? 0) maximum turns per loop").font(.caption).foregroundStyle(.secondary)
                    if session.agent?.discordMentions == true {
                        TimelineView(.periodic(from: .now, by: 5)) { _ in
                            Text(AgentRuntime.shared.discordRouter.status(for: session)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    AccountStatusView(status: session.toolStatus, refreshing: false) { Store.shared.refreshStatus(session) }.font(.caption)
                } }.frame(maxWidth: .infinity)
                Menu {
                    Button("Agent Setup / Loop…") { AgentWindows.shared.setup(session) }
                    Button("Run once") { Store.shared.queueAgentRun(session) }
                        .disabled(session.busy || (session.agent?.turnLimit ?? 0) == 0)
                    Button("Scoreboard") { AgentWindows.shared.widget(session) }
                    Divider()
                    Button("Loop controls…") { loopSettings = true }
                    Button(conversation.owns(session) ? "Stop talking" : "Start talking!") {
                        if conversation.owns(session) { conversation.stop() }
                        else { dictating = false; voice.cancel(); conversation.start(session, store: .shared) }
                    }
                    Button("Dictate…") { conversation.stop(); dictating = true }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Agent actions: setup, loop, run once, scoreboard and voice")
                    .accessibilityLabel("Agent actions")
                    .popover(isPresented: $loopSettings) { AgentLoopOptions(session: session, close: { loopSettings = false }) }
                    .popover(isPresented: $dictating) { AgentDictationView(voice: voice, session: session, close: { dictating = false }) }
            }
            if conversation.sessionID == session.id {
                Text(conversation.status).font(.caption).foregroundStyle(conversation.active ? Color.accentColor : Color.secondary)
                    .lineLimit(2).help(conversation.lastHeard.isEmpty ? conversation.status : "Heard: " + conversation.lastHeard)
            }
        }.padding(8).frame(height: conversation.sessionID == session.id ? 94 : 66)
            .onChange(of: session.id) { old, _ in
                voice.cancel(); dictating = false
                if conversation.sessionID == old { conversation.stop() }
            }
            .onDisappear { if conversation.owns(session) { conversation.stop() } }
    }
}

struct AgentScheduleEditor: View {
    @Binding var seconds: Double
    @Binding var text: String?
    @Binding var zone: String?
    private var isText: Bool { !(text ?? "").isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Frequency", selection: Binding(get: { isText }, set: { text = $0 ? "every 20 minutes while the US stock market is open" : ""; if zone == nil { zone = TimeZone.current.identifier } })) {
                Text("Fixed interval").tag(false)
                Text("Text schedule").tag(true)
            }.pickerStyle(.segmented)
            if isText {
                TextField("Describe when to run", text: Binding(get: { text ?? "" }, set: { text = $0.isEmpty ? " " : $0 }), axis: .vertical).lineLimit(2...4)
                TextField("Time zone", text: Binding(get: { zone ?? TimeZone.current.identifier }, set: { zone = $0 }))
                    .help("IANA time zone. Market schedules always use America/New_York. Explicit ‘in America/New_York’ in the text overrides this field.")
            } else {
                HStack { Text("Check every"); TextField("Minutes", value: Binding(get: { seconds / 60 }, set: { seconds = $0 * 60 }), format: .number).frame(width: 80); Text("minutes (minimum 1)") }
            }
            TimelineView(.periodic(from: .now, by: 60)) { timeline in preview(at: timeline.date) }
            Text("No overlapping runs or backlog bursts. A missed check may run once within its allowed window. Run once, messages and external events can still run outside this schedule.").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func preview(at now: Date) -> some View {
        switch Result(catching: { try AgentSchedule.compile(interval: seconds, text: text, zone: zone) }) {
        case .failure(let error): Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
        case .success(let rule):
            let dates = rule.preview(after: now)
            Text(rule.description).font(.caption).foregroundStyle(.secondary)
            if dates.isEmpty { Text("No future run in the supported calendar. Update the calendar or choose another schedule.").font(.caption).foregroundStyle(.red) }
            else {
                Text("Next slots: " + dates.map { date in
                    let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: rule.zoneID); formatter.dateFormat = "EEE MMM d, HH:mm z"
                    return formatter.string(from: date)
                }.joined(separator: " · ")).font(.caption).textSelection(.enabled)
            }
            if rule.kind == .market { Text("Published NYSE calendar through 2028; emergency closures and trading halts are not detected.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct AgentLoopOptions: View {
    @ObservedObject var session: Session
    @State private var enabled = false
    @State private var minutes: Double = 15
    @State private var scheduleText: String?
    @State private var scheduleTimeZone: String?
    @State private var turns = 20
    @State private var scoreboardEvery = 1
    @State private var revision: UInt64 = 0
    @State private var error = ""
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent loop").font(.headline)
            Text(session.busy ? "Thinking now. Changing the loop does not stop this run." : "Idle. You can still talk to this agent while its loop is off.").font(.callout).foregroundStyle(.secondary)
            Toggle("Automatic loop", isOn: $enabled)
            AgentScheduleEditor(seconds: Binding(get: { minutes * 60 }, set: { minutes = $0 / 60 }), text: $scheduleText, zone: $scheduleTimeZone)
            Stepper("Maximum turns per loop: \(turns)", value: $turns, in: 1...1000)
            Text("A fresh ceiling for each activation. Checks currently use one model response; future scheduled checks are not spent.").font(.caption).foregroundStyle(.secondary)
            Stepper("Refresh scoreboard every \(scoreboardEvery) loop\(scoreboardEvery == 1 ? "" : "s")", value: $scoreboardEvery, in: 1...1000)
            Text("Run once refreshes the scoreboard immediately. Artwork keeps its mood-change / hourly limit. Loops run while Converse is open on this agent’s home. Errors pause the loop.").font(.caption).foregroundStyle(.secondary)
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
        enabled = config.enabled; minutes = config.intervalSeconds / 60; scheduleText = config.scheduleText; scheduleTimeZone = config.scheduleTimeZone; turns = config.turnLimit; scoreboardEvery = config.scoreboardCadence; revision = config.settingsRevision ?? 0; error = ""
    }
    private func save() -> Bool {
        do { try Store.shared.configureAgentLoop(session, enabled: enabled, interval: minutes * 60, turns: turns, scoreboardEvery: scoreboardEvery, scheduleText: scheduleText, scheduleTimeZone: scheduleTimeZone, expectedRevision: revision); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}

struct AgentWidgetView: View {
    @ObservedObject var session: Session
    @State private var expandedReport = false
    private let ink = Color(red: 0.07, green: 0.10, blue: 0.15)
    private let card = Color(red: 0.12, green: 0.16, blue: 0.22)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Background art must never contribute its intrinsic size to the document.
                ZStack(alignment: .bottomLeading) {
                    GeometryReader { geometry in
                        if let path = session.agent?.artPath, let image = NSImage(contentsOfFile: path) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        } else {
                            LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(session.agent?.hasRepository == true ? "PROJECT SCOREBOARD" : "AGENT SCOREBOARD").font(.caption.bold()).tracking(2).foregroundStyle(.white.opacity(0.8))
                        Text(session.title).font(.system(size: 28, weight: .bold)).lineLimit(2)
                        Text(session.agent?.repository ?? "")
                            .font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    }.padding(24)
                }.frame(height: 220).clipped()
                VStack(alignment: .leading, spacing: 22) {
                    if let board = session.agent?.scoreboard {
                        AgentScoreboardCards(board: board)
                    }
                    if let snapshot = session.agent?.repositorySnapshot, snapshot.hasMeasurements {
                        LazyVGrid(columns: [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))], spacing: 10) {
                            ForEach(snapshot.metrics, id: \.0) { item in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(item.1 == "Unavailable" ? "—" : item.1).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                                    Text(item.0).font(.caption).foregroundStyle(.white.opacity(0.7))
                                }.frame(maxWidth: .infinity, minHeight: 65, alignment: .leading).padding(14)
                                    .background(card, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    } else if session.agent?.hasRepository == true {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Repository data unavailable", systemImage: "chart.bar.xaxis").font(.headline)
                            Text("Check the repository and GitHub access in Agent Setup, then run the agent again. Public repository counts can work without a token; visitor counts require traffic access.")
                                .font(.callout).foregroundStyle(.white.opacity(0.75))
                            Button("Set up GitHub…") { AgentWindows.shared.setup(session) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(card, in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Agent update").font(.headline)
                        Text((try? AttributedString(markdown: session.agent?.widgetSummary ?? "Tell me what success looks like.", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(session.agent?.widgetSummary ?? "Tell me what success looks like."))
                            .font(.callout).lineSpacing(4).lineLimit(expandedReport ? nil : 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(expandedReport ? "Show less" : "Read full update") { expandedReport.toggle() }.buttonStyle(.link)
                    }
                    if let attention = session.agent?.attention, !attention.isEmpty {
                        Label(attention, systemImage: "exclamationmark.triangle.fill").font(.callout)
                            .foregroundStyle(.black).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            .background(.yellow, in: RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if let at = session.agent?.snapshot?.observedAt {
                            Text("Checked " + at.formatted(date: .abbreviated, time: .shortened))
                        }
                        if session.agent?.repositorySnapshot?.hasMeasurements == true {
                            ForEach(session.agent?.repositorySnapshot?.notes ?? [], id: \.self) { Text($0) }
                        }
                    }.font(.caption).foregroundStyle(.white.opacity(0.6))
                    HStack {
                        Button("Agent Setup…") { AgentWindows.shared.setup(session) }
                        Spacer()
                        Button("Export widget…") { AgentWindows.shared.export(session) }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, alignment: .leading)
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
        let cells = (config.repositorySnapshot?.metrics ?? []).map { "<div class=metric><strong>" + escape($0.1 == "Unavailable" ? "—" : $0.1) + "</strong><span>" + escape($0.0) + "</span></div>" }.joined()
        let metrics = AgentScoreboardCards.html(config.scoreboard) + (!config.hasRepository ? "" : config.repositorySnapshot?.hasMeasurements == true ? "<div class=grid>" + cells + "</div>" : "<section class=empty><h2>Repository data unavailable</h2><p>Check the repository and GitHub access in Agent Setup, then run the agent again. Public repository counts can work without a token; visitor counts require traffic access.</p></section>")
        return """
        <!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content="width=device-width, initial-scale=1"><meta http-equiv=Content-Security-Policy content="default-src 'none'; img-src data:; style-src 'unsafe-inline'"><title>\(escape(session.title))</title><style>
        *{box-sizing:border-box}body{margin:0;background:#121a26;color:#fff;font:15px/1.6 system-ui}main{max-width:780px;margin:auto}header{position:relative;isolation:isolate;min-height:240px;display:flex;align-items:flex-end;overflow:hidden;background:linear-gradient(135deg,#373064,#174e59)}.art{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;z-index:-2}header:after{content:'';position:absolute;inset:0;background:linear-gradient(transparent,#000e);z-index:-1}.heading{padding:28px;overflow-wrap:anywhere}.eyebrow{font-size:11px;letter-spacing:.18em;color:#ddd}h1{font-size:30px;line-height:1.2;margin:8px 0}h2{font-size:17px;margin:0 0 10px}.repository{color:#ddd}.content{padding:28px;overflow-wrap:anywhere}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}.metric,.empty{padding:18px;background:#1f2938;border-radius:12px}.metric strong{display:block;font-size:28px;line-height:1.3}.metric span{font-size:12px;color:#bbc4d1}p{white-space:pre-wrap;margin:0}section{margin-bottom:24px}details{margin:24px 0}summary{cursor:pointer;font-weight:600;margin-bottom:10px}.attention{background:#facc15;color:#111;padding:16px;border-radius:10px}footer{font-size:12px;color:#a3afbf;margin-top:24px}@media(max-width:420px){.heading,.content{padding:18px}h1{font-size:25px}}
        </style><main><header>\(art)<div class=heading><div class=eyebrow>\(config.hasRepository ? "PROJECT SCOREBOARD" : "AGENT SCOREBOARD")</div><h1>\(escape(session.title))</h1><div class=repository>\(escape(config.repository))</div></div></header><div class=content>\(metrics)<details open><summary>Agent update</summary><p>\(escape(config.widgetSummary))</p></details>\(config.attention.isEmpty ? "" : "<p class=attention>" + escape(config.attention) + "</p>")<footer>Snapshot · \(escape(config.snapshot?.observedAt.formatted() ?? "Not measured yet"))<br>\(escape((config.repositorySnapshot?.notes ?? []).joined(separator: " · ")))<br>Richard Kaufmann · richard@kaoslabs.app · www.kaoslabs.app</footer></div></main></html>
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
                AgentScheduleEditor(seconds: $settings.intervalSeconds, text: $settings.scheduleText, zone: $settings.scheduleTimeZone)
                Stepper("Maximum turns per loop: \(settings.turnLimit)", value: $settings.turnLimit, in: 1...1000)
                Toggle("Enable scheduled loop", isOn: $settings.enabled)
                Toggle("Generate status art", isOn: $settings.generateArt)
                Toggle("Speak on the home", isOn: $settings.speak)
                Toggle("Allow configured Discord alerts", isOn: $settings.discord)
                Toggle("Share session information", isOn: Binding(get: { settings.discordShareSessionInformation == true }, set: { settings.discordShareSessionInformation = $0 })).help("Only in verified private Discord channels.")
                Toggle("Share scoreboard and mood image on Discord requests", isOn: Binding(get: { settings.discordShareScoreboard == true }, set: { settings.discordShareScoreboard = $0 }))
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

struct AgentScoreboardCards: View {
    let board: AgentScoreboard
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = board.title { Text(title).font(.title2.bold()) }
            Text(board.summary).font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Array(board.metrics.enumerated()), id: \.offset) { _, metric in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(metric.label).font(.caption)
                        Text(metric.value).font(.title2.bold()).textSelection(.enabled)
                        if let at = metric.asOf { Text("Source time: " + at).font(.caption) }
                        if let link = metric.sourceURL.flatMap(AgentWebSource.safeURL) { Link("Source", destination: link).font(.caption) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Color(red: 0.12, green: 0.16, blue: 0.22), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if let at = board.observedAt { Text("Retrieved " + at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            ForEach(board.sources ?? [], id: \.url) { source in
                if let url = AgentWebSource.safeURL(source.url) { Link(source.title, destination: url).font(.caption) }
            }
        }
    }
    static func html(_ board: AgentScoreboard?) -> String {
        guard let board else { return "" }
        func e(_ s: String) -> String { AgentWidgetExport.escape(s) }
        let cells = board.metrics.map { metric in
            "<div class=metric><span>" + e(metric.label) + "</span><strong>" + e(metric.value) + "</strong><span>" + e(metric.asOf.map { "Source time: " + $0 } ?? "") + "</span>" +
            (metric.sourceURL.flatMap(AgentWebSource.safeURL).map { "<br><a href=\"" + e($0.absoluteString) + "\" rel=\"noreferrer\">Source</a>" } ?? "") + "</div>"
        }.joined()
        let sources = (board.sources ?? []).compactMap { source -> String? in
            guard let url = AgentWebSource.safeURL(source.url) else { return nil }
            return "<a href=\"" + e(url.absoluteString) + "\" rel=\"noreferrer\">" + e(source.title) + "</a>"
        }.joined(separator: " · ")
        return "<section><h2>" + e(board.title ?? "Scoreboard") + "</h2><p>" + e(board.summary) + "</p><div class=grid>" + cells + "</div><p>Retrieved " + e(board.observedAt?.formatted() ?? "Unknown") + "</p><p>" + sources + "</p></section>"
    }
}
