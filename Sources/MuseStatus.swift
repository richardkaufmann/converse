import Foundation

// This probe only initializes a host and reads existing state. It never resumes,
// starts, attaches to, or submits a turn to a Muse session.
struct MuseStatusProbe {
    struct Result {
        var status: ToolStatus
        var detail: String
    }
    static func query(entry: Entry, sessionID: String) throws -> Result {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec " + entry.command + " serve"]
        let cwd = NSString(string: entry.directory).expandingTildeInPath
        if FileManager.default.fileExists(atPath: cwd) { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        let input = Pipe(); let output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
        defer { timeout.cancel(); try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() }; process.waitUntilExit() }
        var buffer = Data()
        func write(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func rpc(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            while true {
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                    guard let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], value["id"] as? Int == id else { continue }
                    if let error = value["error"] as? [String: Any] {
                        throw NSError(domain: "MuseStatus", code: error["code"] as? Int ?? -1, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Muse rejected status read"])
                    }
                    return value["result"] as? [String: Any] ?? [:]
                }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { throw NSError(domain: "MuseStatus", code: -1, userInfo: [NSLocalizedDescriptionKey: "Muse status connection closed or timed out"]) }
                buffer.append(chunk)
            }
        }
        _ = try rpc(1, "initialize", ["clientInfo": ["name": "converse", "version": "0.3"], "capabilities": ["userInputDialogs": false]])
        try write(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
        let configRoot = env["XDG_CONFIG_HOME"] ?? (NSHomeDirectory() + "/.config")
        let configURL = URL(fileURLWithPath: configRoot).appendingPathComponent("muse/settings.json")
        let config = (try? Data(contentsOf: configURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var read: [String: Any] = [:]
        var readError: String?
        do { read = try rpc(2, "session/read", ["sessionId": sessionID.lowercased(), "excludeItems": true]) }
        catch { readError = error.localizedDescription }
        let usage = (try? rpc(3, "usage/read", [:])) ?? [:]
        let session = read["session"] as? [String: Any] ?? [:]
        var records = [[String: Any]]()
        if let path = session["path"] as? String, !path.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            records = data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
        }
        var result = resolve(config: config, session: session, records: records, quota: usage["usage"] as? [String: Any])
        if let readError, session.isEmpty { result.detail += "\nSession read: " + readError }
        return result
    }
    static func resolve(config: [String: Any], session: [String: Any], records: [[String: Any]], quota: [String: Any]?) -> Result {
        var status = ToolStatus()
        status.model = session["modelId"] as? String ?? config["model"] as? String ?? "No model selected"
        var effortSource = "saved config"
        var accessSource = "retained session"
        let permission = session["approvalMode"] as? [String: Any]
        status.access = permission?["mode"] as? String ?? "Session not started"
        var lastInput = 0; var lastOutput = 0; var totalInput = 0; var totalOutput = 0; var calls = 0
        var hasTurn = false
        var retainedEffort: String?
        var profile: String?
        func visit(_ value: Any) {
            if let object = value as? [String: Any] {
                let kind = object["kind"] as? String ?? ""
                let type = object["payload_type"] as? String ?? ""
                if kind == "top_level_turn_started" { lastInput = 0; lastOutput = 0; hasTurn = true }
                if kind == "run_model", let record = object["record"] as? [String: Any], let model = record["model_id"] as? String { status.model = model }
                if kind == "model_completed", let usage = object["usage"] as? [String: Any] {
                    let input = usage["input_tokens"] as? Int ?? 0; let output = usage["output_tokens"] as? Int ?? 0
                    lastInput += input; lastOutput += output; totalInput += input; totalOutput += output; calls += 1
                    if let model = object["model"] as? String { status.model = model }
                }
                if type == "runtime.session.permission_profile_committed", let payload = object["payload"] as? [String: Any], let source = payload["source"] as? [String: Any] { profile = source["display_name"] as? String ?? source["id"] as? String }
                if type.contains("reasoning_effort_reconfigure"), let payload = object["payload"] as? [String: Any] { retainedEffort = payload["reasoning_effort"] as? String ?? payload["effort"] as? String }
                if let json = object["record_json"] as? String, let data = json.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data) { visit(decoded) }
                // Only recurse through structural containers. Never parse message text,
                // reminder agents, tool arguments, or model-authored status claims.
                for key in ["children", "payload", "event", "outcome", "record"] { if let child = object[key] { visit(child) } }
            } else if let array = value as? [Any] { for child in array { visit(child) } }
        }
        for record in records { visit(record) }
        let efforts = config["model_reasoning_efforts"] as? [String: Any] ?? [:]
        if let retainedEffort { status.effort = retainedEffort; effortSource = "retained session" }
        else if let effort = efforts[status.model] as? String ?? config["reasoning_effort"] as? String { status.effort = effort + " (config)" }
        else { status.effort = "No saved override" }
        if let profile { status.access = profile + " / " + status.access }
        if session.isEmpty { accessSource = "no retained session yet" }
        status.usage = hasTurn || calls > 0 ? "\(lastInput.formatted()) in / \(lastOutput.formatted()) out" : "0 in / 0 out"
        status.totalUsage = "\(totalInput.formatted()) in / \(totalOutput.formatted()) out"
        if (session["turnCount"] as? Int ?? 0) > 0 && records.isEmpty {
            status.usage = "Log unavailable"; status.totalUsage = "Log unavailable"
        }
        status.quota = quota.map { quotaSummary($0) } ?? "Muse has no observed account quota"
        let modelSource = session.isEmpty ? "saved config" : "retained session"
        let detail = "Model: \(status.model) (\(modelSource))\nEffort: \(status.effort) — \(effortSource)\nAccess: \(status.access) (\(accessSource))\nLast turn: \(status.usage)\nSession total: \(status.totalUsage!) · \(calls) model calls\nAccount quota: \(status.quota!)"
        return Result(status: status, detail: detail)
    }
    static func quotaSummary(_ quota: [String: Any]) -> String {
        let tier = quota["tier"] as? String ?? "subscription"
        let window = quota["window"] as? [String: Any] ?? [:]
        let weekly = quota["weekly"] as? [String: Any] ?? [:]
        var parts = [tier]
        if let used = window["usedPercent"] as? Int { parts.append("window \(used)% used") }
        if let used = weekly["usedPercent"] as? Int { parts.append("weekly \(used)% used") }
        let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
        if let reset = window["resetsAtMs"] as? Double { parts.append("resets " + formatter.string(from: Date(timeIntervalSince1970: reset / 1000))) }
        if let observed = quota["observedAtMs"] as? Double { parts.append("observed " + formatter.string(from: Date(timeIntervalSince1970: observed / 1000))) }
        return parts.joined(separator: " · ")
    }
}
