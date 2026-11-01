import Foundation

// Bound historical excerpts, but never cut the request this activation must answer.
// Teaching and onboarding requests can be longer than an ordinary chat message.
enum AgentPromptContext {
    static func conversation(_ messages: [Message], excluding responseID: UUID) -> [[String: String]] {
        let recent = Array(messages.filter { ["user", "assistant"].contains($0.role) && $0.id != responseID }.suffix(24))
        let request = recent.lastIndex { $0.role == "user" }
        return recent.enumerated().map { index, message in
            ["role": message.role, "text": index == request ? message.text : String(message.text.prefix(6000))]
        }
    }
}

// A model selection identifies its provider AND local login. Never infer a
// provider from a model name or silently fall back to another account.
enum AgentModels {
    static func reference(engine: String, account: String, model: String = "") -> String {
        "cli|" + engine + "|" + Data(account.utf8).base64EncodedString() + "|" + Data(model.utf8).base64EncodedString()
    }
    static func parse(_ value: String) -> (engine: String, account: String, model: String)? {
        let p = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 4, p[0] == "cli", ["claude", "codex", "muse"].contains(p[1]),
              let a = Data(base64Encoded: p[2]), let m = Data(base64Encoded: p[3]),
              let account = String(data: a, encoding: .utf8), let model = String(data: m, encoding: .utf8), !account.isEmpty else { return nil }
        return (p[1], account, model)
    }
    static func label(_ value: String) -> String {
        guard let choice = parse(value) else { return "Meta API · " + value }
        return choice.engine.capitalized + " · " + (choice.model.isEmpty ? "CLI default" : choice.model)
    }
    static func entry(_ value: String, store: Store) throws -> Entry {
        guard let route = parse(value), let base = store.entries.first(where: { $0.engine == route.engine }),
              let account = store.accounts.first(where: { $0.id == route.account && $0.engine == route.engine }) else {
            throw AgentFailure.message("This agent's provider/login is no longer enabled. Choose a model and login in Agent Setup.")
        }
        var entry = base
        entry.accountID = account.id; entry.accountName = account.name; entry.accountDirectory = account.directory; entry.useDefaultAccountStore = account.useDefaultStore
        return entry
    }
    static func options(store: Store) -> [DeviceChoiceDTO] {
        var choices: [DeviceChoiceDTO] = []
        for account in store.accounts where store.entries.contains(where: { $0.engine == account.engine }) {
            let sessions = store.sessions.filter { $0.entry.accountID == account.id && !$0.isAgentSession }
            let prefix = account.engine.capitalized + " · " + account.name + " · "
            choices.append(DeviceChoiceDTO(id: reference(engine: account.engine, account: account.id), label: prefix + "CLI default"))
            for model in sessions.flatMap(\.modelChoices) {
                let id = reference(engine: account.engine, account: account.id, model: model.id)
                if !choices.contains(where: { $0.id == id }) { choices.append(DeviceChoiceDTO(id: id, label: prefix + model.label)) }
            }
        }
        return choices
    }
    @MainActor static func catalog(store: Store) async -> [DeviceChoiceDTO] {
        let entries = store.entries, accounts = store.accounts
        var result = options(store: store)
        let discovered = await Task.detached { discover(entries: entries, accounts: accounts) }.value
        for option in discovered where !result.contains(where: { $0.id == option.id }) { result.append(option) }
        if let key = try? AgentSecrets.read("meta"), let (raw, _) = try? await AgentAPI().json(URL(string: "https://api.meta.ai/v1/models")!, key: key), let rows = (raw as? [String: Any])?["data"] as? [[String: Any]] {
            for row in rows { if let id = row["id"] as? String, id.contains("spark") || id.contains("wonder") { result.append(DeviceChoiceDTO(id: id, label: "Meta API · " + id)) } }
        }
        return result
    }
    // Prompt-free catalogs, including accounts with no currently visible session.
    static func discover(entries: [Entry], accounts: [AccountProfile]) -> [DeviceChoiceDTO] {
        var result: [DeviceChoiceDTO] = []
        for account in accounts {
            guard var entry = entries.first(where: { $0.engine == account.engine }) else { continue }
            entry.accountID = account.id; entry.accountDirectory = account.directory; entry.useDefaultAccountStore = account.useDefaultStore
            let models: [MuseModelChoice]
            if entry.engine == "muse" { models = (try? MuseStatusProbe.query(entry: entry, sessionID: "").models) ?? [] }
            else { models = (try? ProviderStatus.query(entry: entry, remoteID: nil).models) ?? [] }
            for model in models { result.append(DeviceChoiceDTO(id: reference(engine: entry.engine, account: account.id, model: model.id), label: entry.engine.capitalized + " · " + account.name + " · " + model.label)) }
        }
        return result
    }
}

// One bounded, fresh CLI response. No previous CLI transcript is resumed, and
// no working project is exposed. The host supplies all agent evidence.
final class AgentCLIControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func attach(_ p: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }; process = p; try p.run()
    }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; if process?.isRunning == true { process?.terminate() } }
}
enum AgentCLI {
    static func arguments(engine: String, model: String, prompt: String, output: String) -> [String] {
        var args: [String]
        switch engine {
        case "claude": args = ["--print", "--output-format", "json", "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--disable-slash-commands", "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}"]
        case "codex": args = ["exec", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--sandbox", "read-only", "--disable", "shell_tool", "--disable", "apps", "--disable", "plugins", "--disable", "multi_agent", "--disable", "hooks", "-c", "approval_policy=\"never\"", "-c", "web_search=\"disabled\"", "--output-last-message", output]
        default: args = ["exec", "--json", "--preset", "empty", "--disable-shell", "--disable-write", "--disable-web-tools", "--disable-reminders", "--disable-request-user-input", "--no-foreign-personal-context", "--no-session-log", "--max-model-steps", "1", "--prompt-file", prompt]
        }
        if !model.isEmpty { args += ["--model", model] }
        return args
    }
    static func finalReply(engine: String, data: Data, final: String?) throws -> String {
        if engine == "codex", let final, !final.isEmpty { return final }
        if engine == "claude", let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["is_error"] as? Bool != true, let text = root["result"] as? String { return text }
        if engine == "muse" {
            for line in data.split(separator: 10).reversed() {
                if let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], row["payload_type"] as? String == "run.terminal.completed",
                   let payload = row["payload"] as? [String: Any], payload["terminal"] as? String == "completed", let text = payload["text"] as? String { return text }
            }
        }
        throw AgentFailure.message("Provider did not return a completed final response. No actions applied.")
    }
    static func respond(entry: Entry, model: String, instructions: String, input: String) async throws -> String {
        let control = AgentCLIControl()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("converse-agent-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
                defer { try? FileManager.default.removeItem(at: folder) }
                let prompt = folder.appendingPathComponent("prompt.txt"), output = folder.appendingPathComponent("final.txt"), log = folder.appendingPathComponent("stdout.txt")
                try Data((instructions + "\nUse only the supplied evidence. Tool-based research is unavailable for this CLI activation. Return the required JSON only.\n" + input).utf8).write(to: prompt)
                FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions:0o600])
                let inputHandle = try FileHandle(forReadingFrom: prompt), outputHandle = try FileHandle(forWritingTo: log)
                defer { try? inputHandle.close(); try? outputHandle.close() }
                var isolated = entry; isolated.directory = folder.path
                let process = ProviderCommand.process(entry: isolated, arguments: arguments(engine: entry.engine, model: model, prompt: prompt.path, output: output.path))
                process.standardInput = inputHandle; process.standardOutput = outputHandle; process.standardError = FileHandle.nullDevice
                try control.attach(process)
                let deadline = Date().addingTimeInterval(180)
                while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
                guard !process.isRunning else { control.cancel(); throw AgentFailure.message("Provider timed out; no actions applied.") }
                guard process.terminationStatus == 0 else { throw AgentFailure.message("Provider request failed. Check the selected login in Setup; no actions applied.") }
                let size = (try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= 8_000_000 else { throw AgentFailure.message("Provider output exceeded the limit.") }
                return try finalReply(engine: entry.engine, data: Data(contentsOf: log), final: try? String(contentsOf: output, encoding: .utf8))
            }.value
        }, onCancel: { control.cancel() })
    }
}
