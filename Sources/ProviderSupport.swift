import AppKit
import Foundation

struct AccountProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var engine: String
    var directory: String
    var useDefaultStore: Bool? = nil
    static func defaults(dataFolder: URL) -> [AccountProfile] {
        let home = NSHomeDirectory()
        if Bundle.main.object(forInfoDictionaryKey: "ConverseNUXPreview") as? Bool == true {
            return ["muse", "codex", "claude"].map { engine in
                AccountProfile(id: engine + "-default", name: engine.capitalized, engine: engine,
                               directory: dataFolder.appendingPathComponent("PreviewAccounts/" + engine).path, useDefaultStore: false)
            }
        }
        return [AccountProfile(id: "muse-default", name: "Muse", engine: "muse", directory: ""),
                AccountProfile(id: "codex-default", name: "Codex", engine: "codex", directory: home + "/.codex"),
                AccountProfile(id: "claude-default", name: "Claude", engine: "claude", directory: home + "/.claude", useDefaultStore: true)]
    }
}
struct GroupMessageOrigin: Codable { var group: String; var home: String }
struct PendingPrompt: Codable, Identifiable {
    var switchboardHop: Int? = nil
    var originGroupID: String? = nil
    var originHomeID: String? = nil
    var components: [PendingPrompt]? = nil
    var originParticipants: [GroupMessageOrigin]? = nil
    var groupOrigins: [GroupMessageOrigin] { (originParticipants ?? []) + (originGroupID.map { [GroupMessageOrigin(group: $0, home: originHomeID ?? "")] } ?? []) }
    var agentRunReserved: Bool? = nil
    var autonomous: Bool? = nil
    var supportContinuation: Bool? = nil
    var clearDisplayBeforeReply: Bool? = nil
    var agentLoopTick: Bool? = nil
    var id = UUID()
    var text: String
    var images: [String]
}
// Applied after login-shell startup, consistently for turns, catalog queries and login.
// Credentials stay in CLI stores; Converse only retains a label and directory.
struct ProviderCommand {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func script(entry: Entry, arguments: [String], effort: String? = nil) -> String {
        var setup = "export PATH=\(quote(NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS")):\"$PATH\"; "
        if entry.engine == "claude", entry.useDefaultAccountStore == true { setup += "unset CLAUDE_CONFIG_DIR; " }
        if let directory = entry.accountDirectory, !directory.isEmpty {
            let path = NSString(string: directory).expandingTildeInPath
            if entry.engine == "muse" {
                setup += "unset META_API_KEY; export XDG_CONFIG_HOME=\(quote(path + "/config")) XDG_DATA_HOME=\(quote(path + "/data")) XDG_CACHE_HOME=\(quote(path + "/cache")) MUSE_AUTH_PATH=\(quote(path + "/config/muse/auth.json")); "
            }
            if entry.engine == "codex" { setup += "unset CODEX_ACCESS_TOKEN OPENAI_API_KEY; export CODEX_HOME=\(quote(path)); " }
            if entry.engine == "claude" { setup += "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR; \(entry.useDefaultAccountStore == true ? "" : "export CLAUDE_CONFIG_DIR=\(quote(path)); ")" }
        }
        if entry.engine == "claude", let effort { setup += "export CLAUDE_CODE_EFFORT_LEVEL=\(quote(effort)); " }
        return setup + "exec " + entry.command + " " + arguments.map(quote).joined(separator: " ")
    }
    static func process(entry: Entry, arguments: [String], effort: String? = nil) -> Process {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", script(entry: entry, arguments: arguments, effort: effort)]
        let cwd = NSString(string: entry.directory).expandingTildeInPath
        if FileManager.default.fileExists(atPath: cwd) { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["TZ"] = TimeZone.current.identifier; env["NO_COLOR"] = "1"; env["TERM"] = "dumb"; p.environment = env
        return p
    }
    static func turnArguments(entry: Entry, choices: SessionChoices, id: UUID, remoteID: String?, started: Bool, images: [String]) -> [String] {
        var args: [String]
        if entry.engine == "claude" {
            args = ["--print", "--verbose", "--output-format", "stream-json", "--include-partial-messages"]
            args += started || remoteID != nil ? ["--resume", remoteID ?? id.uuidString] : ["--session-id", id.uuidString]
            if let model = choices.model { args += ["--model", model] }
            if let effort = choices.effort { args += ["--effort", effort] }
            if let access = choices.access { args += ["--permission-mode", access] }
            for directory in Set(images.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }).sorted() { args += ["--add-dir", directory] }
        } else {
            args = ["exec"]
            if choices.access == "codex:approve-for-me" { args += ["--approve-for-me"] }
            if choices.access == "codex:full-access" { args += ["--dangerously-bypass-approvals-and-sandbox"] }
            if let remoteID { args += ["resume", remoteID] }
            args += ["--json", "--skip-git-repo-check"]
            if let model = choices.model { args += ["--model", model] }
            if let effort = choices.effort { args += ["-c", "model_reasoning_effort=\(toml(effort))"] }
            // Config overrides work for both exec and resume, whose flag sets differ.
            if choices.access == "codex:approve-for-me" {
                args += ["-c", "sandbox_mode=\(toml("workspace-write"))", "-c", "approval_policy=\(toml("on-request"))", "-c", "approvals_reviewer=\(toml("auto_review"))"]
            } else if choices.access == "codex:full-access" {
                args += ["-c", "sandbox_mode=\(toml("danger-full-access"))", "-c", "approval_policy=\(toml("never"))"]
            } else {
                // Preserve older custom configurations; a named preset always replaces the entire mode.
                if let access = choices.access { args += ["-c", "sandbox_mode=\(toml(access))"] }
                if let approval = choices.approval { args += ["-c", "approval_policy=\(toml(approval))"] }
            }
            for image in images { args += ["--image", image] }
        }
        return args
    }
    static func toml(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}
// Bounded prompt-free RPC. Reading status never resumes or attaches a conversation.
final class ProviderProbeConnection {
    let process: Process
    let input = Pipe(), output = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private var timeout: DispatchWorkItem?
    init(entry: Entry, arguments: [String], timeoutSeconds: Double = 12) throws {
        process = ProviderCommand.process(entry: entry, arguments: arguments)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let p = process
        let task = DispatchWorkItem { if p.isRunning { p.terminate() } }
        timeout = task; DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: task)
    }
    deinit { timeout?.cancel(); try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() } }
    func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func read() throws -> [String: Any] {
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let data = Data(buffer[..<end]); buffer.removeSubrange(...end)
                if let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return value }; continue
            }
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { throw NSError(domain: "Converse", code: 1, userInfo: [NSLocalizedDescriptionKey: "CLI status is unavailable: the process exited or timed out before responding."]) }
            buffer.append(data)
        }
    }
    func rpc(_ method: String, _ params: [String: Any], notification: (([String: Any]) throws -> Void)? = nil) throws -> [String: Any] {
        nextID += 1; let id = nextID
        try write(["id": id, "method": method, "params": params])
        while true {
            let value = try read(); guard value["id"] as? Int == id else { try notification?(value); continue }
            if let error = value["error"] as? [String: Any] { throw NSError(domain: "Converse", code: 2, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "CLI rejected status query"]) }
            return value["result"] as? [String: Any] ?? [:]
        }
    }
}
struct ProviderSnapshot {
    var status = ToolStatus()
    var models: [MuseModelChoice] = []
    var access: [MuseAccessChoice] = []
    var account = ""
    var detail = ""
}
struct ProviderStatus {
    static func query(entry: Entry, remoteID: String?) throws -> ProviderSnapshot {
        if entry.engine == "claude" { return try claude(entry: entry, remoteID: remoteID) }
        let rpc = try ProviderProbeConnection(entry: entry, arguments: ["app-server"])
        _ = try rpc.rpc("initialize", ["clientInfo": ["name": "converse", "version": "0.5"], "capabilities": ["experimentalApi": true]])
        try rpc.write(["method": "initialized", "params": [:]])
        var catalog = try rpc.rpc("model/list", ["includeHidden": true])
        var models = catalog["data"] as? [[String: Any]] ?? []
        var cursors = Set<String>()
        while let cursor = catalog["nextCursor"] as? String, cursors.insert(cursor).inserted {
            catalog = try rpc.rpc("model/list", ["cursor": cursor, "includeHidden": true]); models += catalog["data"] as? [[String: Any]] ?? []
        }
        catalog["data"] = models
        let config = try rpc.rpc("config/read", ["includeLayers": false, "cwd": NSString(string: entry.directory).expandingTildeInPath])["config"] as? [String: Any] ?? [:]
        let account = try rpc.rpc("account/read", [:])["account"] as? [String: Any]
        var thread: [String: Any] = [:]
        if let remoteID { thread = try rpc.rpc("thread/read", ["threadId": remoteID, "includeTurns": false])["thread"] as? [String: Any] ?? [:] }
        var result = resolveCodex(catalog: catalog, config: config, thread: thread)
        // Optional telemetry must never make model/account discovery fail.
        if let limits = try? rpc.rpc("account/rateLimits/read", [:]) {
            let context = result.status.accountUsage?.context
            let compactedAt = result.status.accountUsage?.contextCompactedAt
            result.status.accountUsage = AccountUsage.codexLimits(limits)
            result.status.accountUsage?.context = context
            result.status.accountUsage?.contextCompactedAt = compactedAt
        }
        result.account = account?["email"] as? String ?? (account == nil ? "Not signed in" : "API key account")
        result.detail = "Model: \(result.status.model)\nEffort: \(result.status.effort)\nAccess: \(result.status.access)\nApprovals: \(result.status.approval ?? "CLI default")\nAccount: \(result.account)\nCatalog availability does not guarantee account access."
        return result
    }
    static func resolveCodex(catalog: [String: Any], config: [String: Any], thread: [String: Any]) -> ProviderSnapshot {
        var result = ProviderSnapshot()
        let rows = catalog["data"] as? [[String: Any]] ?? []
        result.models = rows.compactMap { row in
            guard let id = row["model"] as? String else { return nil }
            return MuseModelChoice(id: id, label: row["displayName"] as? String ?? id, provider: "codex", profile: nil, efforts: (row["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String })
        }
        let defaultModel = rows.first { $0["isDefault"] as? Bool == true }
        result.status.model = thread["model"] as? String ?? config["model"] as? String ?? defaultModel?["model"] as? String ?? "Model unavailable"
        let model = rows.first { $0["model"] as? String == result.status.model }
        result.status.effort = thread["reasoningEffort"] as? String ?? config["model_reasoning_effort"] as? String ?? model?["defaultReasoningEffort"] as? String ?? "CLI default"
        result.status.access = config["sandbox_mode"] as? String ?? "CLI default"
        result.status.approval = config["approval_policy"] as? String
        result.access = [MuseAccessChoice(id: "codex:ask", label: "Ask for approval (not yet supported in Converse)", available: false),
                         MuseAccessChoice(id: "codex:approve-for-me", label: "Approve for me", available: true),
                         MuseAccessChoice(id: "codex:full-access", label: "Full access", available: true)]
        if let path = thread["path"] as? String {
            for object in tailRecords(path: path) {
                if object["type"] as? String == "compacted" {
                    if result.status.accountUsage == nil { result.status.accountUsage = AccountUsage() }
                    result.status.accountUsage?.context = nil
                    result.status.accountUsage?.contextCompactedAt = (object["timestamp"] as? String).flatMap(AccountUsage.parseDate)
                }
                if let context = AccountUsage.codexContext(object) {
                    if result.status.accountUsage == nil { result.status.accountUsage = AccountUsage() }
                    result.status.accountUsage?.context = context
                }
                guard object["type"] as? String == "turn_context" else { continue }
                if let context = object["payload"] as? [String: Any], let sandbox = context["sandbox_policy"] as? [String: Any], let type = sandbox["type"] as? String { result.status.access = type }
            }
        }
        return result
    }
    static func tailRecords(path: String) -> [[String: Any]] {
        guard let file = FileHandle(forReadingAtPath: path) else { return [] }; defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return [] }
        try? file.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
        return file.readDataToEndOfFile().split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
    }
    static func claude(entry: Entry, remoteID: String?) throws -> ProviderSnapshot {
        let rpc = try ProviderProbeConnection(entry: entry, arguments: ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json", "--no-session-persistence"])
        try rpc.write(["type": "control_request", "request_id": "converse-status", "request": ["subtype": "initialize"]])
        while true {
            let value = try rpc.read()
            guard value["type"] as? String == "control_response", let response = value["response"] as? [String: Any], response["request_id"] as? String == "converse-status" else { continue }
            guard response["subtype"] as? String == "success", let payload = response["response"] as? [String: Any] else { throw NSError(domain: "Converse", code: 3, userInfo: [NSLocalizedDescriptionKey: response["error"] as? String ?? "Claude catalog query failed"]) }
            var result = resolveClaude(payload: payload)
            let home = entry.accountDirectory.map { NSString(string: $0).expandingTildeInPath } ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.claude")
            let cwd = NSString(string: entry.directory).expandingTildeInPath
            var settings: [String: Any] = [:]
            for path in [home + "/settings.json", cwd + "/.claude/settings.json", cwd + "/.claude/settings.local.json"] {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { settings.merge(object) { _, new in new } }
            }
            if let model = settings["model"] as? String { result.status.model = resolvedClaudeModel(model, models: payload["models"] as? [[String: Any]] ?? []) }
            if let effort = settings["effortLevel"] as? String { result.status.effort = effort + " (config)" }
            if let remoteID {
                let encoded = cwd.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
                for object in tailRecords(path: home + "/projects/" + encoded + "/" + remoteID + ".jsonl") {
                    if let message = object["message"] as? [String: Any], let model = message["model"] as? String, model != "<synthetic>" { result.status.model = model }
                }
            }
            if !result.account.contains("@"), let email = try? claudeAccountEmail(entry: entry) { result.account = email }
            result.detail = "Model: \(result.status.model)\nEffort: \(result.status.effort)\nAccess: \(result.status.access)\nAccount: \(result.account)"
            return result
        }
    }
    static func claudeAccountEmail(entry: Entry) throws -> String? {
        let query = try ProviderProbeConnection(entry: entry, arguments: ["auth", "status", "--json"])
        try query.input.fileHandleForWriting.close()
        let data = query.output.fileHandleForReading.readDataToEndOfFile()
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["email"] as? String
    }
    static func resolvedClaudeModel(_ model: String, models: [[String: Any]]) -> String { models.first { $0["value"] as? String == model }?["resolvedModel"] as? String ?? model }
    static func resolveClaude(payload: [String: Any]) -> ProviderSnapshot {
        var result = ProviderSnapshot(); let rows = payload["models"] as? [[String: Any]] ?? []
        result.models = rows.compactMap { row in
            guard let id = row["value"] as? String else { return nil }
            return MuseModelChoice(id: id, label: (row["displayName"] as? String ?? id) + " · " + (row["resolvedModel"] as? String ?? id), provider: "claude", profile: nil, efforts: row["supportedEffortLevels"] as? [String] ?? [])
        }
        result.status.model = rows.first { $0["value"] as? String == "default" }?["resolvedModel"] as? String ?? "Model unavailable"
        result.status.effort = "CLI default"; result.status.access = payload["current_permission_mode"] as? String ?? "CLI default"
        result.access = [("default", "Manual"), ("acceptEdits", "Accept edits"), ("auto", "Auto"), ("plan", "Plan"), ("dontAsk", "Don’t ask (deny unapproved)"), ("bypassPermissions", "Bypass permissions")].map { MuseAccessChoice(id: $0.0, label: $0.1, available: true) }
        let account = payload["account"] as? [String: Any] ?? [:]
        result.account = account["email"] as? String ?? ((account["tokenSource"] as? String ?? "none") == "none" ? "Not signed in" : "Signed in · " + (account["tokenSource"] as? String ?? "CLI"))
        return result
    }
}

extension Session {
    var availableEfforts: [String] {
        let selected = (choices.model ?? toolStatus.model).replacingOccurrences(of: " (requested)", with: "")
        let model = modelChoices.first { $0.id == selected || $0.label.contains(selected) }
        return model?.efforts ?? []
    }
}
extension Store {
    func refreshProviderStatus(_ s: Session, completion: (() -> Void)? = nil) {
        guard !s.isAgentSession else { refreshStatus(s, completion: completion); return }
        if let completion { s.statusCallbacks.append(completion) }
        guard !s.probingStatus else { return }
        s.probingStatus = true
        let entry = s.entry, remoteID = s.remoteID
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try ProviderStatus.query(entry: entry, remoteID: remoteID) }
            DispatchQueue.main.async {
                s.probingStatus = false
                // An agent can finish configuration while an older probe is in flight.
                if s.isAgentSession {
                    self.refreshStatus(s)
                    let callbacks = s.statusCallbacks; s.statusCallbacks = []; callbacks.forEach { $0() }; return
                }
                // A catalog returned for a previous account must never label the new one.
                if s.entry != entry { self.refreshProviderStatus(s); return }
                if s.entry == entry {
                    switch result {
                    case .success(let snapshot):
                        s.modelChoices = snapshot.models; s.accessChoices = snapshot.access
                        s.toolStatus.model = snapshot.status.model; s.toolStatus.effort = snapshot.status.effort; s.toolStatus.access = snapshot.access.first { $0.id == snapshot.status.access }?.label ?? snapshot.status.access
                        s.toolStatus.approval = snapshot.status.approval
                        if s.entry.engine != "claude" || snapshot.status.accountUsage != nil { s.toolStatus.accountUsage = snapshot.status.accountUsage }
                        if let date = snapshot.status.accountUsage?.contextCompactedAt, date > (s.lastCompactedAt ?? .distantPast) { s.lastCompactedAt = date }
                        s.accountStatus = snapshot.account; s.toolStatus.account = snapshot.account; s.toolStatus.accountObservedAt = Date()
                        s.statusDetails = snapshot.detail; s.probeError = ""; s.needsSignIn = AccountLogin.requiresSignIn(snapshot.account)
                    case .failure(let error): s.probeError = error.localizedDescription; if AccountLogin.requiresSignIn(s.probeError) { s.needsSignIn = true }
                    }
                    self.updateExplicitStatus(s); self.saveSoon()
                }
                let callbacks = s.statusCallbacks; s.statusCallbacks = []; callbacks.forEach { $0() }
            }
        }
    }
    func chooseCustomModel(_ s: Session) {
        let alert = NSAlert(); alert.messageText = "Choose a model"
        alert.informativeText = "Enter a model ID supported by this CLI and account. It applies to subsequent turns in this conversation."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 24)); field.stringValue = s.choices.model ?? ""
        alert.accessoryView = field; alert.addButton(withTitle: "Use model"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        changeSetting(s, .model(MuseModelChoice(id: value, label: value, provider: s.entry.engine, profile: nil, efforts: s.availableEfforts)))
    }
    func chooseCustomEffort(_ s: Session) {
        let alert = NSAlert(); alert.messageText = "Choose reasoning effort"
        alert.informativeText = "Enter an effort level supported by the selected model. The CLI validates custom values on the next turn."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); alert.accessoryView = field
        alert.addButton(withTitle: "Use effort"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let effort = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !effort.isEmpty { changeSetting(s, .effort(effort)) }
    }
    @discardableResult
    func chooseAccount(_ s: Session, profile: AccountProfile) -> Session {
        guard !s.busy, !s.changingSetting, profile.engine == s.entry.engine else { return s }
        guard s.entry.accountID != profile.id || AccountLogin.directoryKey(s.entry.accountDirectory ?? "") != AccountLogin.directoryKey(profile.directory) || (s.entry.useDefaultAccountStore == true) != (profile.useDefaultStore == true) else { return s }
        do {
            if let source = loginAccount(for: s) { try SessionLoginContext.copy(s, from: source, to: profile) }
            bindLogin(s, profile: profile)
            save(); refreshStatus(s)
        } catch { s.messages.append(Message(role: "notice", text: error.localizedDescription)); save() }
        return s
    }

    func addAccount(engine: String) {
        let id = UUID().uuidString
        accounts.append(AccountProfile(id: id, name: engine.capitalized + " account \(accounts.filter { $0.engine == engine }.count + 1)", engine: engine, directory: folder.appendingPathComponent("Accounts/" + id).path)); save()
    }
    func accountIsBusy(_ profile: AccountProfile) -> Bool {
        sessionsUsingLogin(profile).contains { $0.busy || $0.changingSetting }
    }
    @discardableResult
    func signIn(_ profile: AccountProfile, command: String? = nil, sessionID: UUID? = nil) -> Bool {
        guard ["codex", "claude"].contains(profile.engine), !accountIsBusy(profile) else { return false }
        // Saved logins in use are immutable authentication identities. Session
        // sign-in always stages a fresh store, so it cannot overwrite another.
        guard sessionsUsingLogin(profile).allSatisfy({ $0.id == sessionID }) else { return false }
        do {
            let directory = NSString(string: profile.directory).expandingTildeInPath
            guard !directory.isEmpty else { return false }
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let entry = Entry(name: profile.name, command: command ?? entries.first(where: { $0.engine == profile.engine })?.command ?? profile.engine, directory: "~", engine: profile.engine, accountID: profile.id, accountName: profile.name, accountDirectory: directory, useDefaultAccountStore: profile.useDefaultStore)
            let args = profile.engine == "codex" ? ["login"] : ["auth", "login"]
            let scripts = folder.appendingPathComponent("Login")
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = scripts.appendingPathComponent(UUID().uuidString + ".command")
            let contents = "#!/bin/zsh\n" + ProviderCommand.script(entry: entry, arguments: args) + "\n"
            try contents.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            guard loginFileOpener(file) else { throw NSError(domain: "Converse", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open Terminal for sign-in."]) }
            save(); return true
        } catch {
            let alert = NSAlert(); alert.messageText = "Could not start sign-in"; alert.informativeText = error.localizedDescription; alert.runModal(); return false
        }
    }
    func restorePending(_ s: Session, id: UUID) {
        guard let index = s.pending.firstIndex(where: { $0.id == id }) else { return }
        let prompt = s.pending.remove(at: index)
        s.draft = prompt.text + (s.draft.isEmpty ? "" : "\n" + s.draft); s.attachments = prompt.images + s.attachments
        save()
    }
}

import SwiftUI

struct ProviderStatusRepairView: View {
    @ObservedObject var session: Session
    @State private var showingHelp = false
    var body: some View {
        Button { showingHelp = true } label: {
            Text(session.probeError + " · Help / repair…").foregroundStyle(.orange).lineLimit(1)
        }.buttonStyle(.plain).help(session.probeError + " Click for recovery options.")
            .popover(isPresented: $showingHelp) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Status unavailable").font(.headline)
                    Text(session.probeError).textSelection(.enabled)
                    Text("This check reads CLI status without sending a model prompt. A timeout or process exit does not prove your login expired. Retry first; if it persists, check the session’s command and login.")
                    HStack {
                        Button("Retry status") { Store.shared.refreshStatus(session, quota: true) }.disabled(session.probingStatus)
                        if ["codex", "claude"].contains(session.entry.engine) {
                            Button("Login settings…") { showingHelp = false; AppDelegate.shared.chooseLogin(session) }
                                .disabled(session.busy || session.changingSetting)
                        }
                        Button("Session settings…") { showingHelp = false; AppDelegate.shared.configureSession(session) }.disabled(session.busy)
                    }
                    Button("Read troubleshooting help") { showingHelp = false; AppDelegate.shared.helpController.show(query: "Status unavailable") }
                    if session.probeError.isEmpty { Text("Status refreshed successfully.").foregroundStyle(.green) }
                }.font(.callout).lineLimit(nil).padding(16).frame(width: 430)
            }
    }
}

struct PendingMessagesView: View {
    @ObservedObject var session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(session.pending.count) queued" + (session.queuePaused ? " · paused" : ""))
                Spacer()
                Button(session.queuePaused ? "Resume queue" : "Pause queue") {
                    session.queuePaused.toggle()
                    Store.shared.save()
                    if !session.queuePaused { Store.shared.runNext(session) }
                }
                Button("Inject all") { Store.shared.injectPending(session) }.disabled(session.changingSetting || (session.interrupted && session.resumeAfterInterrupt)).help("Interrupt and send all queued messages together, in order")
                Button("Clear queue") { session.pending = []; Store.shared.save() }
            }
            ForEach(session.pending) { prompt in
                HStack {
                    Text(TranscriptStyle.trafficSummary(prompt.text, queued: true) ?? (prompt.text.isEmpty ? "Attached image" : prompt.text)).help(prompt.text).foregroundStyle(TranscriptStyle.isTraffic(prompt.text) ? Color(nsColor: TranscriptPalette.traffic) : Color.primary).lineLimit(1)
                    Spacer()
                    Button(session.interrupted && session.injectionTargetID == prompt.id ? "Interrupting…" : "Inject now") { Store.shared.injectPending(session, id: prompt.id) }.disabled(session.changingSetting || (session.interrupted && session.resumeAfterInterrupt)).help("Interrupt and send this message next")
                    Button("Edit") { Store.shared.restorePending(session, id: prompt.id) }
                    Button { session.pending.removeAll { $0.id == prompt.id }; Store.shared.save() } label: { Image(systemName: "xmark") }
                }
            }
        }.font(.caption).padding(8).background(Color.accentColor.opacity(0.06))
    }
}

// Retry telemetry is transient UI state, never conversation history or a failed
// turn. Keep terminal errors visible; only explicit retry events are classified.
enum ProviderRetry {
    static func status(_ engine: String) -> String {
        "Waiting for " + (engine == "codex" ? "OpenAI" : engine == "claude" ? "Claude" : "Muse") + "… reconnecting"
    }
    static func detail(_ line: String) -> String? {
        var message = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = line.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            guard let type = obj["type"] as? String, type == "error" || type == "system" else { return nil }
            if obj["subtype"] as? String == "api_retry" { return "Provider is retrying the request." }
            if obj["willRetry"] as? Bool == false { return nil }
            message = obj["message"] as? String ?? ""
            if obj["willRetry"] as? Bool == true { return message }
        }
        return message.range(of: #"^Reconnecting(?:\.\.\.|…)\s*\d+/\d+(?:\s|$)"#, options: [.regularExpression, .caseInsensitive]) != nil ? message : nil
    }
}

// Compaction is a provider operation, never a synthetic user prompt. This
// connection owns only an idle thread for the duration of this operation.
struct CodexCompactor {
    static func failure(_ message: String) -> NSError {
        NSError(domain: "Converse.Compaction", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func run(entry: Entry, threadID: String, started: (Process) -> Void) throws {
        let rpc = try ProviderProbeConnection(entry: entry, arguments: ["app-server"], timeoutSeconds: 180)
        defer { rpc.closeAndWait() }
        started(rpc.process)
        _ = try rpc.rpc("initialize", ["clientInfo": ["name": "converse_compaction", "version": "1"]])
        try rpc.write(["method": "initialized", "params": [:]])
        let result = try rpc.rpc("thread/resume", ["threadId": threadID, "excludeTurns": true])
        guard let thread = result["thread"] as? [String: Any], thread["id"] as? String == threadID,
              (thread["status"] as? [String: Any])?["type"] as? String == "idle" else {
            throw failure("The provider did not return this exact thread as idle. Nothing was compacted.")
        }
        var turnID: String?, itemID: String?
        var compacted = false, finished = false
        func observe(_ event: [String: Any]) throws {
            guard let method = event["method"] as? String,
                  let params = event["params"] as? [String: Any], params["threadId"] as? String == threadID else { return }
            if method == "turn/started", let turn = params["turn"] as? [String: Any] {
                guard turnID == nil else { throw failure("Unexpected overlapping turn during compaction.") }
                turnID = turn["id"] as? String
            }
            if method == "item/started" || method == "item/completed" {
                guard let turnID, params["turnId"] as? String == turnID,
                      let item = params["item"] as? [String: Any], item["type"] as? String == "contextCompaction",
                      let id = item["id"] as? String else { return }
                if method == "item/started" { itemID = id }
                else if id == itemID { compacted = true }
            }
            if method == "turn/completed", let turn = params["turn"] as? [String: Any],
               let turnID, turn["id"] as? String == turnID {
                guard turn["status"] as? String == "completed", compacted else {
                    throw failure("Provider compaction did not complete. The saved conversation is retained.")
                }
                finished = true
            }
        }
        _ = try rpc.rpc("thread/compact/start", ["threadId": threadID], notification: observe)
        while !finished { try observe(rpc.read()) }
        // Acknowledge unloading before a later CLI resume can begin.
        _ = try rpc.rpc("thread/unsubscribe", ["threadId": threadID])
    }
}

extension Session {
    var compactionState: DeviceCompactionState? {
        guard ["codex", "claude"].contains(entry.engine), agent == nil, remoteID != nil else { return nil }
        let context = toolStatus.accountUsage?.context
        let phase = compacting ? "running" : compactionRequested ? "queued" : "available"
        let detail = phase == "queued" ? "Compact after the current turn, before queued prompts. Click to cancel." : phase == "running" ? "Compacting the model's context. Your displayed transcript and draft are retained." : (context.map { "Last reported context: \($0.percent)% full. " } ?? "Context usage is unknown. ") + "Summarize older model context to make room. The visible conversation remains; some details may be lost from the model's working context." + (busy ? " Runs after this turn." : "")
        return DeviceCompactionState(recommended: CompactionPolicy.recommends(context, after: lastCompactedAt), phase: phase, percent: context?.percent, detail: detail)
    }
}

extension Store {
    @discardableResult func requestCompaction(_ s: Session) -> String? {
        guard !applicationQuitting, sessions.contains(where: { $0 === s }), s.compactionState != nil else { return "Compaction is not supported for this session." }
        guard !s.compacting, !s.compactionRequested else { return nil } // duplicate intent
        guard !s.changingSetting, !s.interrupted else { return "Wait for the current settings change or interruption to finish." }
        s.compactionRequested = true
        if !s.busy { startCompaction(s) }
        return nil
    }
    func startCompaction(_ s: Session) {
        guard !applicationQuitting, !s.busy, !s.changingSetting, s.compactionRequested,
              ["codex", "claude"].contains(s.entry.engine), let threadID = s.remoteID else { return }
        s.compactionRequested = false; s.compacting = true; s.busy = true; s.interrupted = false
        s.status = "Compacting…"
        do { try saveChecked() }
        catch {
            s.compacting = false; s.busy = false; s.queuePaused = true; s.status = "Compaction not started"
            s.messages.append(Message(role: "notice", text: "Could not save compaction intent. Nothing was compacted.")); return
        }
        let entry = s.entry
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                let started: (Process) -> Void = { process in
                    DispatchQueue.main.sync { s.process = process; if s.interrupted || self.applicationQuitting { process.terminate() } }
                }
                if entry.engine == "claude" { try ClaudeCompactor.run(entry: entry, threadID: threadID, started: started) }
                else { try CodexCompactor.run(entry: entry, threadID: threadID, started: started) }
            }
            DispatchQueue.main.async {
                let cancelled = s.interrupted
                s.process = nil; s.compacting = false; s.busy = false; s.interrupted = false; s.resumeAfterInterrupt = false
                switch result {
                case .success where !cancelled:
                    s.lastCompactedAt = Date(); s.toolStatus.accountUsage?.context = nil; s.status = "Ready"
                    s.messages.append(Message(role: "notice", text: "Context compacted. The full displayed conversation and draft are retained."))
                default:
                    s.queuePaused = true; s.status = "Compaction incomplete"
                    let detail: String
                    if case .failure(let error) = result { detail = error.localizedDescription } else { detail = "Interrupted." }
                    s.messages.append(Message(role: "notice", text: "Compaction completion could not be confirmed. " + detail + " Your transcript and draft are retained; queued prompts are paused. Compaction will not retry automatically."))
                }
                self.save(); self.objectWillChange.send()
                if !self.applicationQuitting && !cancelled {
                    if ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] == nil { self.refreshStatus(s) }
                    if case .success = result { self.runNext(s) }
                }
            }
        }
    }
}

struct ClaudeCompactor {
    static func run(entry: Entry, threadID: String, started: (Process) -> Void) throws {
        let rpc = try ProviderProbeConnection(entry: entry, arguments: ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json", "--resume", threadID], timeoutSeconds: 180)
        defer { rpc.closeAndWait() }
        started(rpc.process)
        try rpc.write(["type": "control_request", "request_id": "compact-init", "request": ["subtype": "initialize"]])
        while true {
            let event = try rpc.read()
            guard event["type"] as? String == "control_response", let response = event["response"] as? [String: Any], response["request_id"] as? String == "compact-init" else { continue }
            let payload = response["response"] as? [String: Any] ?? [:]
            let commands = payload["commands"] as? [[String: Any]] ?? []
            guard response["subtype"] as? String == "success", commands.contains(where: { $0["name"] as? String == "compact" }) else {
                throw CodexCompactor.failure("This Claude CLI does not advertise native compaction. Nothing was submitted.")
            }
            break
        }
        // /compact is a CLI command only after the native command catalog above
        // confirms it; never ask the model to invent its own compaction.
        try rpc.write(["type": "user", "session_id": threadID, "message": ["role": "user", "content": "/compact"], "parent_tool_use_id": NSNull()])
        var boundary = false
        while true {
            let event = try rpc.read()
            guard (event["session_id"] as? String)?.lowercased() == threadID.lowercased() else { continue }
            if event["type"] as? String == "system", event["subtype"] as? String == "compact_boundary",
               (event["compact_metadata"] as? [String: Any])?["trigger"] as? String == "manual" { boundary = true }
            if event["type"] as? String == "result" {
                guard boundary, event["subtype"] as? String == "success", event["is_error"] as? Bool != true else {
                    throw CodexCompactor.failure("Claude did not confirm a completed compaction. There may be too little history to compact.")
                }
                return
            }
        }
    }
}

extension Store {
    func updateClaudeContext(_ event: [String: Any], session s: Session) {
        if event["type"] as? String == "system", event["subtype"] as? String == "compact_boundary" {
            s.lastCompactedAt = Date(); s.claudeLastContext = nil; s.toolStatus.accountUsage?.context = nil
        }
        if event["type"] as? String == "assistant", let message = event["message"] as? [String: Any],
           let model = message["model"] as? String, let usage = message["usage"] as? [String: Any] {
            let keys = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
            let counts = keys.map { usage[$0] as? Int ?? 0 }
            if counts.allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000 }), usage["input_tokens"] is Int {
                s.claudeLastContext = (model, counts.reduce(0, +))
            }
        }
        if event["type"] as? String == "result", let last = s.claudeLastContext,
           let models = event["modelUsage"] as? [String: [String: Any]], let model = models[last.model],
           let context = AccountUsage.context(tokens: last.tokens, capacity: model["contextWindow"], at: Date()) {
            if s.toolStatus.accountUsage == nil { s.toolStatus.accountUsage = AccountUsage() }
            s.toolStatus.accountUsage?.context = context
        }
    }
}

extension ProviderProbeConnection {
    // Wait until the owned CLI releases its session lock before a queued turn
    // can resume. The separate probe deadline still bounds incomplete requests.
    func closeAndWait() {
        try? input.fileHandleForWriting.close()
        let p = process
        let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
        let killTask = DispatchWorkItem { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: stop)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killTask)
        p.waitUntilExit(); stop.cancel(); killTask.cancel()
    }
}
