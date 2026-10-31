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
    let store: Store
    init(store: Store = .shared) { self.store = store }
    deinit { timer?.invalidate() }
    func prepare(state: WindowState) {
        guard !store.setupCompleted else { return }
        let support = store.supportSession(); session = support
        // A new profile has only this session. Never rearrange existing sessions.
        if store.sessions.count == 1 { AppDelegate.shared?.select(support, state: state) }
        if support.entry.engine != "support" { selected = support.entry.engine; status = "Setup is unfinished. Pick your provider to resume login and verify a model response." }
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
            if let profileDirectory = session.entry.accountDirectory {
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
        else { status = "The provider login did not finish successfully. Pick the provider again to retry; setup remains locked." }
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
                self.status = "Connected. Converse App Support is ready."
                self.store.enqueueSwitchboard(session, text: self.store.switchboardTeaching(session) + "\n\n" + AppSupport.instructions(agent: false) + "\nThe user has completed provider login. Introduce yourself briefly as Converse App Support. Offer the README, Discord and Connect the Meta Muse iPhone app as Markdown links using converse-help://readme, converse-help://discord and converse-help://muse-iphone. Also include these getting-started links: \(AppSupport.guideLinks). Do not ask for another provider, start configuration, or claim any integration is connected. Wait for the user's setup request. End your welcome with exactly: \(AppSupport.closingInvitation)", clearDisplayBeforeReply: true)
            } else { self.status = "The model did not confirm a working connection. Setup remains locked. Retry login or check the connection again." }
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
                Text("SETUP PREVIEW · Separate conversations, logins, credentials and device identity").font(.caption).foregroundStyle(.secondary)
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
