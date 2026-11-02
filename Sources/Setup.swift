import AppKit
import SwiftUI

struct SetupCatalog {
    static var entries: [Entry] {
        [Entry(name: "Muse", command: "muse", directory: "~", engine: "muse"),
         Entry(name: "Claude", command: "claude", directory: "~", engine: "claude"),
         Entry(name: "Codex", command: "codex", directory: "~", engine: "codex")]
    }
    static func validDirectory(_ directory: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: NSString(string: directory).expandingTildeInPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
extension Store {
    // Existing archives are already configured; rerunning the guide must not
    // remove their assistants, account snapshots, conversations or drafts.
    @discardableResult
    func completeSetup(selected: Set<UUID>, sessionEntryID: UUID? = nil, accountID: String? = nil) -> Session? {
        let chosen = entries.filter { selected.contains($0.id) }
        guard !chosen.isEmpty, chosen.allSatisfy({ !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && SetupCatalog.validDirectory($0.directory) }) else { return nil }
        if !setupCompleted && sessions.isEmpty { entries.removeAll { !selected.contains($0.id) } }
        setupCompleted = true
        guard let id = sessionEntryID, var entry = entries.first(where: { $0.id == id }),
              SetupCatalog.validDirectory(entry.directory),
              let profile = accounts.first(where: { $0.id == accountID && $0.engine == entry.engine }) else { save(); return nil }
        entry.accountID = profile.id; entry.accountName = nil; entry.accountDirectory = nil; entry.useDefaultAccountStore = profile.useDefaultStore
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index] = entry }
        let session = create(entry); save(); return session
    }
}
final class SetupChecks: ObservableObject {
    @Published var checking = Set<UUID>()
    @Published var results: [UUID: String] = [:]
    static func version(_ entry: Entry) -> String {
        let process = ProviderCommand.process(entry: entry, arguments: ["--version"])
        let output = Pipe(); process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); timeout.cancel()
            guard process.terminationStatus == 0 else { return "Could not run CLI. Install it or correct the command, then check again." }
            let version = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return "CLI available" + (version.isEmpty ? "" : ": " + version) + ". Sign-in is checked separately by the CLI."
        } catch { return "Could not run CLI: " + error.localizedDescription }
    }
    func check(_ entry: Entry) {
        guard !checking.contains(entry.id) else { return }
        checking.insert(entry.id); results[entry.id] = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.version(entry)
            DispatchQueue.main.async { self.checking.remove(entry.id); self.results[entry.id] = result }
        }
    }
}
final class SetupProgress: ObservableObject {
    @Published var step = 0
    @Published var selected = Set<UUID>()
    @Published var sessionEntryID = UUID()
    @Published var accountID = ""
}
struct SetupView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var state: WindowState
    var body: some View {
        Group {
            if store.setupCompleted { LegacySetupView(state: state) }
            else { SupportNUXView(state: state) }
        }.onChange(of: store.setupCompleted) { _, completed in if completed { state.setup = false } }
    }
}
struct LegacySetupView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var state: WindowState
    @StateObject private var checks = SetupChecks()
    @StateObject private var progress = SetupProgress()
    private var step: Int { get { progress.step } nonmutating set { progress.step = newValue } }
    private var selected: Set<UUID> { get { progress.selected } nonmutating set { progress.selected = newValue } }
    private var sessionEntryID: UUID { get { progress.sessionEntryID } nonmutating set { progress.sessionEntryID = newValue } }
    private var accountID: String { get { progress.accountID } nonmutating set { progress.accountID = newValue } }
    private var selectedEntries: [Entry] { store.entries.filter { selected.contains($0.id) } }
    private var sessionEntry: Entry? { selectedEntries.first { $0.id == sessionEntryID } }
    private var validSelection: Bool {
        !selectedEntries.isEmpty && selectedEntries.allSatisfy { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && SetupCatalog.validDirectory($0.directory) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Welcome to Converse").font(.title2.bold())
                Spacer()
                Text("\(step + 1) of 3").foregroundStyle(.secondary)
            }
            Text(["Choose your assistants", "Connect your accounts", "Start a conversation"][step]).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if step == 0 { assistants }
                    else if step == 1 { accounts }
                    else { firstSession }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
            }
            Divider()
            HStack {
                Button("Set up later") { store.setupCompleted = true; store.save(); state.setup = false }
                    .help("You can reopen Setup from Converse → Setup")
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                if step < 2 {
                    Button("Continue") {
                        if step == 1 { chooseSessionDefaults() }
                        step += 1
                    }.keyboardShortcut(.defaultAction).disabled(!validSelection)
                } else {
                    Button("Finish without a session") { finish(createSession: false) }
                    Button("Create session") { finish(createSession: true) }
                        .keyboardShortcut(.defaultAction).disabled(sessionEntry == nil || accountID.isEmpty || !validSelection)
                }
            }
        }.padding(24).frame(width: 650, height: 590).textFieldStyle(.roundedBorder)
            .interactiveDismissDisabled()
            .onAppear {
                if store.setupCompleted { selected = Set(store.entries.map(\.id)) }
            }
    }
    private var assistants: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose one or more assistants. Converse uses their installed command-line apps and existing subscriptions; it does not include the CLIs or an AI account.").foregroundStyle(.secondary)
            Text("Install each selected CLI using its provider’s official installer. Check CLI runs --version without sending a model prompt. You can also use a full executable path.").font(.callout)
            HStack {
                Link("Codex installation", destination: URL(string: "https://developers.openai.com/codex/cli/")!)
                Link("Claude Code installation", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
            }.font(.callout)
            Text("Muse is optional; use the Muse CLI supplied by your provider if you have access to it.").font(.caption).foregroundStyle(.secondary)
            ForEach($store.entries) { $entry in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(entry.name, isOn: Binding(get: { selected.contains(entry.id) }, set: { if $0 { selected.insert(entry.id) } else { selected.remove(entry.id) } }))
                    if selected.contains(entry.id) {
                        TextField("Command", text: $entry.command).disabled(checks.checking.contains(entry.id)).onChange(of: entry.command) { _, _ in checks.results[entry.id] = nil }
                        HStack {
                            TextField("Working folder", text: $entry.directory).disabled(checks.checking.contains(entry.id))
                            Button("Choose folder…") {
                                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                                if panel.runModal() == .OK, let url = panel.url { entry.directory = url.path }
                            }.disabled(checks.checking.contains(entry.id))
                        }
                        Text("The assistant can work with files in this folder. Choose a project folder or leave ~ for your home folder.").font(.caption).foregroundStyle(.secondary)
                        if !SetupCatalog.validDirectory(entry.directory) { Text("Choose a folder that exists.").font(.caption).foregroundStyle(.red) }
                        HStack {
                            Button(checks.checking.contains(entry.id) ? "Checking…" : "Check CLI") { checks.check(entry) }.disabled(checks.checking.contains(entry.id))
                            if let result = checks.results[entry.id] { Text(result).font(.caption).textSelection(.enabled) }
                        }
                    }
                }.padding(12).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text("You can add more assistants and change these settings later in Settings (⌘,).").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var accounts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default accounts reuse each CLI’s existing login. If you already signed in through Terminal, you can keep it. Add another named account to keep work and personal sign-ins separate.").foregroundStyle(.secondary)
            ForEach(Array(Set(selectedEntries.map(\.engine))).sorted(), id: \.self) { engine in
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectedEntries.first { $0.engine == engine }?.name ?? engine.capitalized).font(.headline)
                    ForEach($store.accounts) { $profile in
                        if profile.engine == engine {
                            HStack {
                                TextField("Account name", text: $profile.name)
                                if engine != "muse" {
                                    Button("Sign in…") { store.signIn(profile, command: selectedEntries.first { $0.engine == engine }?.command) }.disabled(store.accountIsBusy(profile) || !store.sessionsUsingLogin(profile).isEmpty)
                                }
                            }
                            Text(profile.directory.isEmpty ? "Uses the CLI’s current sign-in" : profile.directory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if engine == "muse" {
                        Text("Sign into Muse in Terminal using its CLI, then return here. Converse reuses that sign-in.").font(.caption)
                    } else {
                        Button("Add another \(engine.capitalized) account") { store.addAccount(engine: engine) }
                    }
                }.padding(12).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text("Sign in… opens the selected CLI in Terminal; finish its browser or terminal flow, then return to Converse. CLI accounts are separate from desktop-app sign-ins. Credentials stay with the CLI. You can sign in later from Settings.").font(.callout)
        }
    }
    private var firstSession: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A session is one conversation with its own history, account and model settings. Create one now, or finish and use + beside any assistant later.").foregroundStyle(.secondary)
            Picker("Assistant", selection: $progress.sessionEntryID) { ForEach(selectedEntries) { Text($0.name).tag($0.id) } }
                .onChange(of: sessionEntryID) { _, _ in chooseAccountDefault() }
            if let entry = sessionEntry {
                Picker("Account", selection: $progress.accountID) {
                    ForEach(store.accounts.filter { $0.engine == entry.engine }) { Text($0.name).tag($0.id) }
                }
                Text("Working folder: " + entry.directory).font(.caption).foregroundStyle(.secondary)
            }
            Text("Creating a session sends no model prompt. Type at the bottom and press Return when you are ready.").font(.callout)
            Text("Use + for more sessions. Use 1, 2 or 3 to display a session in a pane, or P to park it. The account, model, effort and access controls are at the bottom of each conversation. Changing a login affects only that session and preserves its conversation.").font(.callout)
            Text("Your conversations and drafts are saved on this Mac. Settings manages additional accounts and assistants; Converse → Setup reopens these steps.").font(.callout)
        }
    }
    private func chooseSessionDefaults() {
        if !selected.contains(sessionEntryID), let first = selectedEntries.first { sessionEntryID = first.id }
        chooseAccountDefault()
    }
    private func chooseAccountDefault() {
        guard let entry = sessionEntry else { accountID = ""; return }
        accountID = store.accounts.first { $0.id == entry.accountID && $0.engine == entry.engine }?.id ?? store.accounts.first { $0.engine == entry.engine }?.id ?? ""
    }
    private func finish(createSession: Bool) {
        _ = store.completeSetup(selected: selected, sessionEntryID: createSession ? sessionEntryID : nil, accountID: accountID)
        state.setup = false
    }
}
