import AppKit
import SwiftUI

final class SupportNUXController: ObservableObject {
    @Published var status = ""
    @Published var checking = false
    @Published var waitingForLogin = false
    @Published var selected: String?
    @Published var installationURL: URL?
    private var generation = UUID()
    private var timer: Timer?
    private var loginResult: URL?
    private weak var session: Session?
    /// Set by the first-run guide; replaces the legacy sheet's handoff prompt.
    var onConnected: ((Session) -> Void)?
    unowned let store: Store
    init(store: Store = .shared) { self.store = store }
    deinit { timer?.invalidate() }
    func prepare(state: WindowState) {
        guard !store.setupCompleted else { return }
        let support = store.supportSession(); session = support
        // A new profile has only this session. Never rearrange existing sessions.
        if store.sessions.count == 1 { AppDelegate.shared?.select(support, state: state) }
        if support.entry.engine != "support" { selected = support.entry.engine; status = "Setup is unfinished. Pick your provider to resume login and verify a model response." }
    }
    func attach(_ support: Session) { session = support; selected = support.entry.engine }
    func begin(_ support: Session) {
        guard !checking, !waitingForLogin else { return }
        attach(support); startLogin(support)
    }
    static func loginArguments(_ engine: String) -> [String] {
        engine == "claude" ? ["auth", "login"] : ["login"]
    }
    func choose(_ engine: String) {
        guard !checking, ["muse","claude","codex"].contains(engine) else { return }
        guard session?.busy != true else { status = "The previous connection check is still stopping. Try again when it finishes."; return }
        timer?.invalidate(); waitingForLogin = false; installationURL = nil
        generation = UUID(); let token = generation
        selected = engine; checking = true; status = "Checking \(engine.capitalized)…"
        guard let base = store.entries.first(where: { $0.engine == engine }) else { checking = false; status = "Provider definition is missing. Open Settings to restore it."; return }
        let support = store.supportSession(); session = support
        let directory = store.folder.appendingPathComponent("SetupWorkspace")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { checking = false; status = error.localizedDescription; return }
        let profile: AccountProfile
        if let existing = store.accounts.first(where: { $0.id == "support-" + engine }) { profile = existing }
        else {
            profile = AccountProfile(id: "support-" + engine, name: "Converse Support · " + base.name, engine: engine, directory: store.folder.appendingPathComponent("SupportAccounts/" + engine).path, useDefaultStore: false)
            store.accounts.append(profile)
        }
        var entry = base
        entry.directory = directory.path; entry.accountID = profile.id; entry.accountName = profile.name
        entry.accountDirectory = profile.directory; entry.useDefaultAccountStore = false
        if support.entry.engine != engine { support.remoteID = nil; support.started = false }
        support.entry = entry; store.save()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = SetupChecks.version(entry)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.checking = false
                guard result.hasPrefix("CLI available") else {
                    self.status = "Install \(base.name)’s command-line app, then pick it again. " + result
                    self.installationURL = URL(string: engine == "codex" ? "https://developers.openai.com/codex/cli/" : engine == "claude" ? "https://code.claude.com/docs/en/setup" : "https://api.meta.ai/muse-launcher.sh")
                    return
                }
                self.startLogin(support)
            }
        }
    }
    func startLogin(_ session: Session) {
        timer?.invalidate(); checking = false; waitingForLogin = false
        do {
            // Muse's default login has no separate folder; it uses the CLI's own store.
            if let profileDirectory = session.entry.accountDirectory, !profileDirectory.isEmpty {
                try FileManager.default.createDirectory(atPath: profileDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
            }
            let directory = store.folder.appendingPathComponent("Login")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
            let id = UUID().uuidString
            let script = directory.appendingPathComponent(id + ".command")
            let result = directory.appendingPathComponent(id + ".result")
            let command = ProviderCommand.script(entry: session.entry, arguments: Self.loginArguments(session.entry.engine))
            let body = "#!/bin/zsh\numask 077\n# Converse Support: provider-owned login; no credentials enter the transcript.\n/bin/zsh -lc " + ProviderCommand.quote(command) + "\nresult=$?\nprintf '%s' \"$result\" > " + ProviderCommand.quote(result.path) + "\nexit \"$result\"\n"
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: script.path)
            guard store.loginFileOpener(script) else { throw AgentFailure.message("Could not open the provider login in Terminal.") }
            loginResult = result; waitingForLogin = true
            status = "Finish \(session.entry.name)’s login in Terminal or your browser. I’ll check a real model response automatically afterward."
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pollLogin() }
        } catch { status = error.localizedDescription }
    }
    func pollLogin() {
        guard let file = loginResult, let code = try? String(contentsOf: file, encoding: .utf8) else { return }
        timer?.invalidate(); timer = nil; waitingForLogin = false
        if code.trimmingCharacters(in: .whitespacesAndNewlines) == "0" { verify() }
        else { status = onConnected != nil ? "The provider login didn’t finish. Click Log in again to retry." : "The provider login did not finish successfully. Pick the provider again to retry; setup remains locked." }
    }
    func verify() {
        guard !checking, let session, session.entry.engine != "support", !session.busy else { return }
        timer?.invalidate(); timer = nil; waitingForLogin = false; checking = true
        status = "Checking one short model response…"
        let token = UUID(); generation = token
        session.queuePaused = false; session.pending.removeAll(); session.needsSignIn = false
        session.supportProbeCompletion = { [weak self, weak session] connected in
            guard let self, self.generation == token, let session else { return }
            self.checking = false
            if connected {
                self.store.configureSupportAgent(session)
                self.status = "Connected. Converse App Support is ready."
                if let handoff = self.onConnected { handoff(session); return }
                self.store.enqueueSwitchboard(session, text: "The user has completed provider login. Introduce yourself briefly as Converse App Support. Offer Security and privacy at converse-help://security, the README, Discord and Connect the Meta Muse iPhone app as Markdown links using converse-help://readme, converse-help://discord and converse-help://muse-iphone. Also include these getting-started links: \(AppSupport.guideLinks). Do not ask for another provider, start configuration, or claim any integration is connected. Wait for the user's setup request. End your welcome with exactly: \(AppSupport.closingInvitation)" + "\n\n" + self.store.switchboardTeaching(session) + "\n\n" + AppSupport.instructions(agent: true), clearDisplayBeforeReply: true)
            } else { self.status = self.onConnected != nil ? "The model didn’t answer yet. Click Log in again, or I’m already signed in to check once more." : "The model did not confirm a working connection. Setup remains locked. Retry login or check the connection again." }
        }
        session.draft = "Connection check only: reply with exactly " + AppSupport.connectionReply + ". Do not call tools, change files, or add any other text."
        store.send(session)
        if !session.busy { session.supportProbeCompletion = nil; checking = false; status = "Could not start the connection check. Retry the provider login." }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self, weak session] in
            guard let self, self.generation == token, self.checking, let session else { return }
            session.supportProbeCompletion = nil; self.store.stop(session); self.checking = false
            self.status = "The connection check timed out. Setup remains locked; retry when the provider is ready."
        }
    }
}

struct SupportNUXView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var state: WindowState
    @StateObject private var controller = SupportNUXController()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to Converse!").font(.largeTitle.bold())
            Text("I’m Converse App Support. I can help you set up and use Converse.").font(.title3)
            HStack(spacing: 18) {
                Button("README") { AppSupport.open("readme") }
                Button("Security & privacy") { AppSupport.open("security") }
                Button("Discord") { AppSupport.open("discord") }
                Button("Connect the Meta Muse iPhone app") { AppSupport.open("muse-iphone") }
            }.buttonStyle(.link)
            HStack(spacing: 18) {
                Button("First coding session") { AppSupport.open("first-session") }
                Button("First agent") { AppSupport.open("first-agent") }
                Button("Create a Group") { AppSupport.open("first-group") }
            }.buttonStyle(.link)
            Divider()
            Text("But first, you need to set up one provider. Pick 1, 2, or 3.").font(.headline)
            HStack(spacing: 14) {
                provider("1. Meta Muse", engine: "muse", key: "1")
                provider("2. Claude", engine: "claude", key: "2")
                provider("3. Codex", engine: "codex", key: "3")
            }
            Text("Your provider opens its own login. Converse continues after a model responds successfully.").font(.callout).foregroundStyle(.secondary)
            if !controller.status.isEmpty {
                HStack(alignment: .top) {
                    if controller.checking || controller.waitingForLogin { ProgressView().controlSize(.small) }
                    Text(controller.status).textSelection(.enabled)
                }
            }
            if let url = controller.installationURL { Link("Open provider installation instructions", destination: url) }
            if controller.selected != nil && !controller.checking {
                Button("I’m signed in · Check connection") { controller.verify() }
            }
            Spacer(minLength: 0)
            Text(AppSupport.closingInvitation).font(.callout)
            if Bundle.main.object(forInfoDictionaryKey: "ConverseNUXPreview") as? Bool == true {
                Text((Bundle.main.object(forInfoDictionaryKey: "ConverseDemo") as? Bool == true ? "DEMO" : "SETUP PREVIEW") + " · Separate conversations, logins, credentials and device identity").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Quit") { AppDelegate.shared.quitConverse(nil) } }
        }.padding(26).frame(width: 670, height: 440).interactiveDismissDisabled()
            .onAppear { controller.prepare(state: state) }
            .onChange(of: store.setupCompleted) { _, completed in if completed { state.setup = false } }
    }
    private func provider(_ label: String, engine: String, key: KeyEquivalent) -> some View {
        Button(label) { controller.choose(engine) }.keyboardShortcut(key, modifiers: []).disabled(controller.checking)
    }
}

// MARK: - First run on a brand-new data folder
// Four sessions, one pane: App Support asks which provider should lead, then
// renames and binds the coding session, agent and App Support to that login.
// Existing archives never reach this path (they already have sessions).

struct FirstRunRecord: Codable, Equatable {
    /// choose · later · login · done · dismissed
    var stage: String
    var provider: String? = nil
    var supportID: UUID
    var codingID: UUID
    var agentID: UUID
    var lotID: UUID
    var teachCoding: Bool? = nil
    var lotLinked: Bool? = nil
}

enum FirstRunText {
    static let providers = ["muse", "codex", "claude"]
    static func product(_ engine: String) -> String { ["muse": "Meta Muse", "codex": "OpenAI Codex", "claude": "Anthropic Claude"][engine] ?? AssistantFamily.name(engine) }
    static func codingTitle(_ engine: String) -> String { AssistantFamily.name(engine) + " Coding Session" }
    static func agentTitle(_ engine: String) -> String { AssistantFamily.name(engine) + " Agent" }
    static let title = "Welcome to Converse!"
    static let question = "What provider would you like to have lead this app? (Pick one below.)"
    static func loginPrompt(_ engine: String) -> String { "Please press Return to log into \(AssistantFamily.name(engine)) using its normal process." }
    static let loginCommand = "/login"
    static let codingWelcome = """
    Welcome to your coding session. You're good to go. Try typing:

    Add a new heading called Things To Do to the Parking Lot, with a first item "Get with Converse"
    """
    static func agentWelcome(_ title: String) -> String {
        "Welcome to your agent. You're good to go. It can read your Parking Lot and coding session. Try typing: What's in the Parking Lot, and what should I do first?\n\nRight-click \(title) in the left panel for Agent Setup, Run once, Show scoreboard and more."
    }
    static let placeholder = "Pick a provider in Converse App Support to finish setting up this session."
    static let cli = ["muse": "muse", "codex": "codex", "claude": "claude"]
    static let installURL = ["muse": URL(string: "https://api.meta.ai/muse-launcher.sh")!,
                             "codex": URL(string: "https://developers.openai.com/codex/cli/")!,
                             "claude": URL(string: "https://code.claude.com/docs/en/setup")!]
    /// README section bundled as Help: per-provider install commands for Mac.
    static let installTopic = "install-a-provider-cli"
    static let metaKeyURL = URL(string: "https://dev.meta.ai/docs/models")!
    static let lotWelcome = "This is your Parking Lot: an outline for ideas, bugs and future prompts. Your coding session and agent are linked to it and can read it and suggest changes."
    static let agentObjective = "Help me get started with Converse. Read the Parking Lot and my coding session, suggest the next small step, and keep the Parking Lot's Things To Do current when I ask. Distinguish verified results from claims."
}

// The Converse shoe, kept small. Saved once into the data folder so the
// transcript and Parking Lot keep a stable local file path.
enum ConverseShoe {
    static var image: NSImage? {
        if let url = Bundle.main.url(forResource: "Converse", withExtension: "png"), let image = NSImage(contentsOf: url) { return image }
        return NSApp?.applicationIconImage
    }
    /// A 144 pt PNG (288 px, 144 dpi) for transcripts and lot items.
    static func png(points: CGFloat = 144) -> Data? {
        guard let source = image else { return nil }
        let pixels = Int(points * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: points, height: points)
        return rep.representation(using: .png, properties: [:])
    }
    static func save(in folder: URL) -> String? {
        let url = folder.appendingPathComponent("Welcome/converse-shoe.png")
        if FileManager.default.fileExists(atPath: url.path) { return url.path }
        guard let data = png() else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic); return url.path
        } catch { return nil }
    }
}

enum FirstRunCLI: Equatable { case checking, installed, missing(String) }

final class FirstRunGuide: ObservableObject {
    @Published private(set) var record: FirstRunRecord?
    @Published var cli: [String: FirstRunCLI] = [:]
    @Published var metaKey = ""
    @Published var metaStatus = ""
    unowned let store: Store
    let login: SupportNUXController
    /// Injectable for tests: true when the provider's CLI runs `--version`.
    var cliCheck: (Entry) -> Bool = { SetupChecks.version($0).hasPrefix("CLI available") }
    var metaKeySaved: () -> Bool = { AppSupport.metaKeySaved() }
    var metaKeyWriter: (String) throws -> Void = { try AgentSecrets.update("meta", value: $0, remove: false) }
    private var file: URL { store.folder.appendingPathComponent("first-run.json") }
    init(store: Store) {
        self.store = store; login = SupportNUXController(store: store)
        if let data = try? Data(contentsOf: store.folder.appendingPathComponent("first-run.json")) { record = try? JSONDecoder().decode(FirstRunRecord.self, from: data) }
    }
    var active: Bool { record.map { !["done", "dismissed"].contains($0.stage) } ?? false }
    var stage: String? { record?.stage }
    private func update(_ change: (inout FirstRunRecord) -> Void) {
        guard var next = record else { return }
        change(&next); record = next
        do { try JSONEncoder().encode(next).write(to: file, options: .atomic) } catch { NSLog("Converse could not save first-run progress.") }
    }
    func session(_ id: UUID?) -> Session? { id.flatMap { id in store.sessions.first { $0.id == id } } }
    var support: Session? { session(record?.supportID) }
    var coding: Session? { session(record?.codingID) }
    var agent: Session? { session(record?.agentID) }

    /// Seeds App Support, the starter Parking Lot, a coding session and an
    /// agent. Only for a store that has never had a session.
    @discardableResult
    func seedIfNeeded(library: ParkingLotLibrary, order: SidebarOrder) -> Session? {
        guard !store.setupCompleted, store.sessions.isEmpty, record == nil else { return nil }
        let shoe = ConverseShoe.save(in: store.folder)
        let support = store.supportSession()
        support.messages = []
        let lotID = library.records.first?.id ?? ParkingLotStore.id
        if let lot = library.lot(lotID) {
            var welcome = ParkingLotRow(heading: false, text: FirstRunText.lotWelcome)
            if let image = shoe.flatMap(NSImage.init(contentsOfFile:)), let path = try? lot.saveImage(image) { welcome.images = [path] }
            lot.openStarter([ParkingLotRow(heading: true, text: "Welcome to Converse"), welcome,
                             ParkingLotRow(heading: true, text: "New features"), ParkingLotRow(heading: false, text: ""),
                             ParkingLotRow(heading: true, text: "Bugs"), ParkingLotRow(heading: false, text: "")])
        }
        let coding = store.create(store.defaultEntry(engine: "claude"), persist: false)
        coding.title = "Coding Session"
        coding.messages = [Message(role: "notice", text: FirstRunText.placeholder)]
        let agent = store.createAgent(title: "Agent", persist: false)
        agent.messages = [Message(role: "notice", text: FirstRunText.placeholder)]
        agent.agent?.objective = FirstRunText.agentObjective
        agent.agent?.watchedSessions = [lotID, coding.id]
        agent.agent?.enabled = false
        store.setupCompleted = true
        store.save()
        let ids = [support.id.uuidString, lotID.uuidString, coding.id.uuidString, agent.id.uuidString]
        for id in ids { order.move(id, before: nil, scope: "local", available: ids) }
        record = FirstRunRecord(stage: "choose", supportID: support.id, codingID: coding.id, agentID: agent.id, lotID: lotID)
        update { _ in }
        return support
    }
    /// Links need this Mac's device identity, available once sync starts.
    func linkLot(home: String?, library: ParkingLotLibrary) {
        guard let record, record.lotLinked != true, let home else { return }
        let links = [record.codingID, record.agentID].filter { session($0) != nil }.map { DeviceGlobalID(home: home, session: $0).string }
        do { try library.setLinks(record.lotID, to: library.links(record.lotID) + links, expected: library.links(record.lotID)); update { $0.lotLinked = true } }
        catch { NSLog("Converse could not link the starter Parking Lot.") }
    }
    func checkCLIs() {
        for engine in FirstRunText.providers where cli[engine] != .installed {
            cli[engine] = .checking
            let entry = store.defaultEntry(engine: engine), check = cliCheck
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let ok = check(entry)
                DispatchQueue.main.async {
                    self?.cli[engine] = ok ? .installed : .missing("The \(FirstRunText.cli[engine] ?? engine) command-line app isn’t installed on this Mac. Install it, then click Check again.")
                }
            }
        }
    }
    func bind(_ entry: inout Entry, _ profile: AccountProfile) {
        entry.accountID = profile.id; entry.accountName = profile.name; entry.accountDirectory = profile.directory; entry.useDefaultAccountStore = profile.useDefaultStore
    }
    func agentModel(_ engine: String, account: String) -> String {
        engine == "muse" && metaKeySaved() ? "muse-spark-1.3" : AgentModels.reference(engine: engine, account: account)
    }
    /// Binds all three sessions to the chosen provider's login, then waits for
    /// the human to press Return on the prefilled /login.
    func choose(_ engine: String) {
        guard active, FirstRunText.providers.contains(engine), cli[engine] != .checking, !(cli[engine].map { if case .missing = $0 { return true }; return false } ?? false),
              let support, support.supportProbeCompletion == nil, !support.busy,
              let profile = store.preferredLogin(engine: engine) else { return }
        var entry = store.defaultEntry(engine: engine); bind(&entry, profile)
        let workspace = store.folder.appendingPathComponent("SetupWorkspace")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var supportEntry = entry; supportEntry.directory = workspace.path
        if support.entry.engine != engine { support.remoteID = nil; support.started = false }
        support.entry = supportEntry
        if let coding, !coding.busy, !coding.messages.contains(where: { $0.role == "user" }) {
            if coding.entry.engine != engine || coding.entry.accountID != profile.id {
                coding.remoteID = nil; coding.started = false; coding.choices = SessionChoices(); coding.toolStatus = ToolStatus()
            }
            coding.entry = entry; coding.title = FirstRunText.codingTitle(engine)
            coding.switchboardEnabled = true
            coding.messages = [Message(role: "assistant", text: FirstRunText.codingWelcome)]
        }
        if let agent, !agent.busy, !agent.messages.contains(where: { $0.role == "user" }) {
            let model = agentModel(engine, account: profile.id)
            agent.agent?.model = model; agent.toolStatus.model = AgentModels.label(model)
            agent.title = FirstRunText.agentTitle(engine)
            agent.messages = [Message(role: "notice", text: FirstRunText.agentWelcome(agent.title))]
        }
        let shoe = ConverseShoe.save(in: store.folder)
        // Changing the provider replaces the earlier welcome and login prompt.
        support.messages.removeAll { $0.role == "assistant" && ($0.text.hasPrefix("# " + FirstRunText.title) || $0.text.hasPrefix("Please press Return to log into")) }
        support.messages.insert(Message(role: "assistant", text: "# \(FirstRunText.title)\n\n\(FirstRunText.product(engine)) will lead Converse.", images: shoe.map { [$0] } ?? []), at: 0)
        support.messages.append(Message(role: "assistant", text: FirstRunText.loginPrompt(engine)))
        support.draft = FirstRunText.loginCommand
        login.status = ""
        update { $0.stage = "login"; $0.provider = engine; $0.teachCoding = true }
        store.save()
    }
    func decideLater() {
        guard active, record?.stage == "choose" else { return }
        support?.messages.append(Message(role: "notice", text: "No problem. Click Choose a provider above when you’re ready. Until then, you can still open Parking Lots, Groups and Settings."))
        update { $0.stage = "later" }; store.save()
    }
    func reopen() { guard active, let support, support.supportProbeCompletion == nil, !support.busy else { return }; update { $0.stage = "choose" } }
    func dismiss() { update { $0.stage = "dismissed" } }
    /// Return on the prefilled /login runs the chosen provider's own login in
    /// Terminal for the shared login, then checks one model response.
    func intercept(_ s: Session) -> Bool {
        guard active, let record, s.id == record.supportID, s.supportProbeCompletion == nil else { return false }
        let text = s.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.entry.engine == "support" || record.stage == "choose" || record.stage == "later" {
            guard !text.isEmpty else { return true }
            s.messages.append(Message(role: "notice", text: "Pick a provider above first. App Support uses it to answer."))
            store.saveSoon(); return true
        }
        guard record.stage == "login" else { return false }
        if text.lowercased() == FirstRunText.loginCommand {
            s.draft = ""; s.messages.append(Message(role: "user", text: FirstRunText.loginCommand))
            login.onConnected = { [weak self] session in self?.connected(session) }
            login.begin(s); store.save(); return true
        }
        guard !text.isEmpty else { return true }
        s.messages.append(Message(role: "notice", text: "First, press Return on /login (or click I’m already signed in). Your text is kept in the draft."))
        store.saveSoon(); return true
    }
    func alreadySignedIn() {
        guard let support, record?.stage == "login" else { return }
        login.onConnected = { [weak self] session in self?.connected(session) }
        if support.draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == FirstRunText.loginCommand { support.draft = "" }
        login.attach(support); login.verify()
    }
    func connected(_ session: Session) {
        guard let engine = record?.provider else { return }
        update { $0.stage = "done" }
        let coding = coding?.title ?? FirstRunText.codingTitle(engine), agent = agent?.title ?? FirstRunText.agentTitle(engine)
        store.enqueueSwitchboard(session, text: "The user picked \(FirstRunText.product(engine)) and finished login. Introduce yourself in two or three short sentences as Converse App Support. Say their \(coding) and \(agent) are ready in the left panel, linked to the Parking Lot, and suggest clicking \(coding) to start. Mention [Security and privacy](converse-help://security) and [README](converse-help://readme). Do not ask for another provider or claim any integration is connected. End with exactly: \(AppSupport.closingInvitation)" + "\n\n" + store.switchboardTeaching(session) + "\n\n" + AppSupport.instructions(agent: true), clearDisplayBeforeReply: true)
    }
    /// The coding session learns the switchboard with its first human request.
    func teachIfNeeded(_ s: Session) {
        guard let record, s.id == record.codingID, record.teachCoding == true, !s.isAgentSession else { return }
        update { $0.teachCoding = false }
        s.switchboardEnabled = true
        // Hidden like the support hand-off: the reply and the request stay visible.
        store.enqueueSwitchboard(s, text: store.switchboardTeaching(s), clearDisplayBeforeReply: true)
    }
    func loginAgain() {
        guard let support, record?.stage == "login", !login.checking, !login.waitingForLogin, !support.busy else { return }
        if support.draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == FirstRunText.loginCommand { support.draft = "" }
        login.onConnected = { [weak self] session in self?.connected(session) }
        login.begin(support)
    }
    func saveMetaKey() {
        let value = metaKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { metaStatus = "Paste a key first."; return }
        do {
            try metaKeyWriter(value); metaKey = ""
            metaStatus = "Saved in your Mac’s Keychain. Muse Spark agents and image tools can use it."
            if record?.provider == "muse", let agent, !agent.busy, AgentModels.parse(agent.agent?.model ?? "") != nil {
                agent.agent?.model = "muse-spark-1.3"; agent.toolStatus.model = AgentModels.label("muse-spark-1.3"); store.save()
            }
            objectWillChange.send()
        } catch { metaStatus = error.localizedDescription }
    }
    func show(_ session: Session?) {
        guard let session, let app = AppDelegate.shared, let state = app.windows.first?.1 else { return }
        app.select(session, state: state)
    }
}

struct FirstRunPanel: View {
    @ObservedObject var guide: FirstRunGuide
    @ObservedObject var login: SupportNUXController
    @ObservedObject var session: Session
    var body: some View {
        Group {
            switch guide.stage {
            case "choose": chooser
            case "later": strip { Text("No provider chosen yet. App Support starts once you pick one.").foregroundStyle(.secondary); Spacer(); Button("Choose a provider…") { guide.reopen() } }
            case "login": loginStrip
            case "done": strip {
                if let engine = guide.record?.provider { ProviderLogo(engine: engine) }
                Text(login.checking ? "Connected. App Support is getting ready…" : "Connected. Your \(guide.coding?.title ?? "coding session") and \(guide.agent?.title ?? "agent") are ready.")
                Spacer()
                Button("Open \(guide.coding?.title ?? "coding session")") { guide.show(guide.coding) }.disabled(guide.coding == nil)
                Button("Open \(guide.agent?.title ?? "agent")") { guide.show(guide.agent) }.disabled(guide.agent == nil)
                Button { guide.dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Hide this bar")
            }
            default: EmptyView()
            }
        }.onAppear { if guide.stage == "choose" { guide.checkCLIs() } }
    }
    private func strip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) { content() }.font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
        }.background(Color.accentColor.opacity(0.06))
    }
    private var chooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                if let image = ConverseShoe.image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 22)).accessibilityLabel("Converse shoe")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(FirstRunText.title).font(.largeTitle.bold())
                    Text(FirstRunText.question).font(.title3)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(FirstRunText.providers, id: \.self) { provider($0) }
            }
            HStack {
                Button("Decide later") { guide.decideLater() }.buttonStyle(.link)
                Spacer()
                Text("Your provider signs you in with its own login. Keys and passwords never go into the chat.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
    }
    private func provider(_ engine: String) -> some View {
        let state = guide.cli[engine] ?? .checking
        return VStack(alignment: .leading, spacing: 6) {
            Button { guide.choose(engine) } label: {
                HStack(spacing: 10) {
                    ProviderLogo(engine: engine).scaleEffect(1.3).frame(width: 28, height: 28)
                    Text(FirstRunText.product(engine)).font(.headline)
                }.frame(maxWidth: .infinity, minHeight: 40)
            }.buttonStyle(.bordered).controlSize(.large).disabled(state != .installed)
                .accessibilityLabel("Use " + FirstRunText.product(engine))
            switch state {
            case .checking: HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Looking for the \(FirstRunText.cli[engine] ?? engine) CLI…") }.font(.caption).foregroundStyle(.secondary)
            case .installed: Text("Ready to sign in").font(.caption).foregroundStyle(.secondary)
            case .missing(let hint):
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("How to install") { AppDelegate.shared?.helpController.show(topic: FirstRunText.installTopic, query: "") }
                    Link("Provider guide", destination: FirstRunText.installURL[engine]!)
                    Button("Check again") { guide.checkCLIs() }
                }.buttonStyle(.link).font(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var loginStrip: some View {
        let engine = guide.record?.provider ?? "claude"
        let name = AssistantFamily.name(engine)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProviderLogo(engine: engine)
                    if login.checking || login.waitingForLogin { ProgressView().controlSize(.small) }
                    Text(login.status.isEmpty ? "\(FirstRunText.product(engine)) selected. Press Return on /login below to sign in to \(name)." : login.status)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if !login.status.isEmpty && !login.checking && !login.waitingForLogin {
                        Button("Log in again") { guide.loginAgain() }.disabled(session.busy)
                    }
                    Button("I’m already signed in") { guide.alreadySignedIn() }.disabled(login.checking || session.busy)
                        .help("Skip the login and check one short model response")
                    Button("Change provider") { guide.reopen() }.disabled(login.checking || login.waitingForLogin || session.busy)
                }
                if engine == "muse" { metaKey }
            }.font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
        }.background(Color.accentColor.opacity(0.06))
    }
    @ViewBuilder private var metaKey: some View {
        if guide.metaKeySaved() {
            Text("Meta Model API key already saved in Keychain · Muse Spark agents and Muse Image scoreboards are on.").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Optional: a Meta Model API key adds Muse Spark agents and Muse Image scoreboards. Coding sessions use your Muse login either way.").font(.caption)
                HStack {
                    SecureField("Meta Model API key", text: $guide.metaKey).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    Button("Save key") { guide.saveMetaKey() }.disabled(guide.metaKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Link("Get a key", destination: FirstRunText.metaKeyURL).font(.caption)
                }
                if !guide.metaStatus.isEmpty { Text(guide.metaStatus).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
