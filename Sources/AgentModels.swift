import Foundation
import AppKit

// Bound historical excerpts, but never cut the request this activation must answer.
// Teaching and onboarding requests can be longer than an ordinary chat message.
enum AgentPromptContext {
    /// Current local date and time for agents, e.g. "Wednesday, November 4, 2026 at 7:23 AM PST (America/Los_Angeles)".
    static func localNow(_ date: Date = Date(), zone: TimeZone = .current) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = zone
        format.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        return format.string(from: date) + " (" + zone.identifier + ")"
    }
    static func conversation(_ messages: [Message], excluding responseID: UUID) -> [[String: String]] {
        let recent = Array(messages.filter { ["user", "assistant"].contains($0.role) && $0.id != responseID }.suffix(24))
        let request = recent.lastIndex { $0.role == "user" }
        return recent.enumerated().map { index, message in
            ["id": message.id.uuidString, "role": message.role, "text": index == request ? message.text : String(message.text.prefix(6000)), "imageCount": String(message.images.count)]
        }
    }
}

// Only images explicitly attached to this agent's own user messages travel with
// its conversation. Watched-session and Discord attachments are not imported.
struct AgentInputImage: Sendable {
    var label: String
    var png: Data
    var dataURL: String { "data:image/png;base64," + png.base64EncodedString() }
}
extension AgentPromptContext {
    static func images(_ messages: [Message], excluding responseID: UUID) throws -> [AgentInputImage] {
        try imageContext(messages, excluding: responseID).images
    }
    static func imageContext(_ messages: [Message], excluding responseID: UUID) throws -> (images: [AgentInputImage], omitted: [String]) {
        let recent = messages.filter { ["user", "assistant"].contains($0.role) && $0.id != responseID }.suffix(24)
        let requestID = recent.last(where: { $0.role == "user" })?.id
        let attachments = recent.filter { $0.role == "user" }.flatMap { message in
            message.images.enumerated().map { (message.id, $0.offset + 1, $0.element) }
        }
        var bytes = 0, images: [AgentInputImage] = [], omitted: [String] = []
        // Reserve the bounded payload for newest attachments before older history.
        for (id, index, path) in attachments.suffix(8).reversed() {
            let label = "Image \(index) attached to user message \(id.uuidString)"
            do {
                let url = URL(fileURLWithPath: path)
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 32_000_000, let image = NSImage(contentsOf: url) else {
                    throw AgentFailure.message("Could not read an attached agent image. Reattach it in a new message and retry.")
                }
                let png = try MacImageSource.normalized(image)
                guard bytes + png.count <= 24_000_000 else { throw AgentFailure.message("Agent images exceed the request limit. Use fewer or smaller images.") }
                bytes += png.count
                images.append(AgentInputImage(label: label, png: png))
            } catch {
                // A failed current request must be explicit. A missing historical
                // attachment must not poison every subsequent turn or prevent retry.
                if id == requestID { throw error }
                omitted.append(label + " (unavailable or exceeds the request limit)")
            }
        }
        return (Array(images.reversed()), Array(omitted.reversed()))
    }
    static func visualInput(_ input: String, images: [AgentInputImage]) -> Any {
        guard !images.isEmpty else { return input }
        var content: [[String: Any]] = [["type": "input_text", "text": input]]
        for image in images {
            content.append(["type": "input_text", "text": image.label])
            content.append(["type": "input_image", "image_url": image.dataURL])
        }
        return [["type": "message", "role": "user", "content": content]]
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
    static let missingMetaKey = "Add a Meta API key in Agent Setup, or choose Claude/Codex as this agent's model."
    static func installed(_ account: AccountProfile, store: Store) -> Bool {
        store.entries.first(where: { $0.engine == account.engine }).map(store.agentCommandAvailable) == true
    }
    // Preferred CLI for a new agent without a Meta key: Claude, then Codex, then Muse.
    static func defaultCLI(store: Store) -> String? {
        for engine in ["claude", "codex", "muse"] {
            if let account = store.accounts.first(where: { $0.engine == engine && installed($0, store: store) }) { return reference(engine: engine, account: account.id) }
        }
        return nil
    }
    static func options(store: Store) -> [DeviceChoiceDTO] {
        var choices: [DeviceChoiceDTO] = []
        // Omit providers whose CLI is not installed; Agent Setup still shows the saved choice.
        for account in store.accounts where installed(account, store: store) {
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
        let entries = store.entries, accounts = store.accounts.filter { installed($0, store: store) }
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
    static func claudeInput(_ text: String, images: [AgentInputImage]) throws -> Data {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        for image in images {
            content.append(["type": "text", "text": image.label])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": image.png.base64EncodedString()]])
        }
        var data = try JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user", "content": content]])
        data.append(10); return data
    }
    static func finalReply(engine: String, data: Data, final: String?) throws -> String {
        if engine == "codex", let final, !final.isEmpty { return final }
        if engine == "claude" {
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                ?? data.split(separator: 10).reversed().compactMap { line -> [String: Any]? in
                    guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], row["type"] as? String == "result" else { return nil }
                    return row
                }.first
            if let root, root["is_error"] as? Bool != true, let text = root["result"] as? String { return text }
        }
        if engine == "muse" {
            for line in data.split(separator: 10).reversed() {
                if let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], row["payload_type"] as? String == "run.terminal.completed",
                   let payload = row["payload"] as? [String: Any], payload["terminal"] as? String == "completed", let text = payload["text"] as? String { return text }
            }
        }
        throw AgentFailure.message("Provider did not return a completed final response. No actions applied.")
    }
    static func respond(entry: Entry, model: String, instructions: String, input: String, images: [AgentInputImage] = []) async throws -> String {
        let control = AgentCLIControl()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("converse-agent-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
                defer { try? FileManager.default.removeItem(at: folder) }
                let prompt = folder.appendingPathComponent("prompt.txt"), output = folder.appendingPathComponent("final.txt"), log = folder.appendingPathComponent("stdout.txt")
                let text = instructions + "\nUse only the supplied evidence. Tool-based research is unavailable for this CLI activation. Return the required JSON only.\n" + input
                var args = arguments(engine: entry.engine, model: model, prompt: prompt.path, output: output.path)
                if entry.engine == "claude", !images.isEmpty {
                    if let format = args.firstIndex(of: "--output-format") { args[format + 1] = "stream-json" }
                    args += ["--input-format", "stream-json", "--verbose"]
                    try claudeInput(text, images: images).write(to: prompt)
                } else {
                    try Data((text + images.map { "\n" + $0.label }.joined()).utf8).write(to: prompt)
                    for (index, image) in images.enumerated() {
                        let file = folder.appendingPathComponent("image-\(index + 1).png")
                        try image.png.write(to: file)
                        args += ["--image", file.path]
                    }
                }
                FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions:0o600])
                let inputHandle = try FileHandle(forReadingFrom: prompt), outputHandle = try FileHandle(forWritingTo: log)
                defer { try? inputHandle.close(); try? outputHandle.close() }
                var isolated = entry; isolated.directory = folder.path
                let process = ProviderCommand.process(entry: isolated, arguments: args)
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
