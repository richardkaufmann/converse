import Foundation
import Darwin

// Muse's MSP usage/read only returns an observation held by that host. The TUI
// can fetch subscription data without a model turn. Until MSP exposes refresh,
// ask the installed CLI's /usage in an ephemeral, invisible PTY.
struct MuseQuotaReading {
    var text: String
    var usage: AccountUsage?
}
struct MuseQuota {
    // `muse usage --json` reads the subscription allowance without a model turn.
    // nil means the output is not that report; a report without an allowance
    // throws Muse's own reason instead of showing zero.
    static func allowance(_ data: Data, now: Date = Date()) throws -> MuseQuotaReading? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["schemaVersion"] != nil else { return nil }
        guard var allowance = root["allowance"] as? [String: Any] else {
            let detail = [root["reason"] as? String, root["hint"] as? String].compactMap { $0 }.joined(separator: " ")
            throw NSError(domain: "MuseQuota", code: 3, userInfo: [NSLocalizedDescriptionKey: "Muse reported no subscription allowance." + (detail.isEmpty ? "" : " " + detail)])
        }
        var usage = AccountUsage()
        for (key, name) in [("window", "Window"), ("weekly", "Weekly")] {
            guard let row = allowance[key] as? [String: Any], let used = (row["usedPercent"] as? NSNumber)?.doubleValue,
                  used.isFinite, used >= 0, used <= 100 else { continue }
            let reset = ((row["resetsAtMs"] as? NSNumber)?.doubleValue).flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
            usage.limits.append(AccountLimit(name: name, usedPercent: used, resetsAt: reset))
        }
        guard !usage.limits.isEmpty else { return nil }
        let asOf = ((allowance["asOfMs"] as? NSNumber)?.doubleValue).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        usage.observedAt = asOf.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
        if allowance["observedAtMs"] == nil, let asOf { allowance["observedAtMs"] = asOf }
        return MuseQuotaReading(text: MuseStatusProbe.quotaSummary(allowance), usage: usage)
    }
    static func query(entry: Entry) throws -> MuseQuotaReading {
        if let reading = try usageReport(entry: entry) { return reading }
        return MuseQuotaReading(text: try terminalQuery(entry: entry), usage: nil)
    }
    // Older CLIs lack the subcommand and would read "usage" as a prompt, so
    // confirm it is listed before running it.
    static func usageReport(entry: Entry) throws -> MuseQuotaReading? {
        func run(_ arguments: [String]) -> Data? {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", ProviderCommand.script(entry: entry, arguments: arguments)]
            let cwd = NSString(string: entry.directory).expandingTildeInPath
            if FileManager.default.fileExists(atPath: cwd) { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            process.environment = env
            let output = Pipe()
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); timeout.cancel()
            return process.terminationStatus == 0 ? data : nil
        }
        guard let help = run(["--help"]), listsUsage(String(decoding: help, as: UTF8.self)), let report = run(["usage", "--json"]) else { return nil }
        return try allowance(report)
    }
    static func listsUsage(_ help: String) -> Bool {
        help.range(of: "(?m)^\\s+usage\\s", options: .regularExpression) != nil
    }
    static func parse(_ raw: String, requireObservation: Bool = false) -> String? {
        let osc = "\u{001B}\\][^\u{0007}]*?(?:\u{0007}|\u{001B}\\\\)"
        var plain = raw.replacingOccurrences(of: osc, with: " ", options: .regularExpression)
        plain = plain.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: " ", options: .regularExpression)
        plain = plain.replacingOccurrences(of: "\u{001B}[78M=>]", with: " ", options: .regularExpression)
        func row(_ title: String) -> String? {
            let pattern = title + "\\s+(\\d+)%\\s*used\\s*[·•]?\\s*Resets\\s+([^│\\r\\n]+)[│\\r\\n]"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let text = plain as NSString
            guard let match = regex.matches(in: plain, range: NSRange(location: 0, length: text.length)).last else { return nil }
            let reset = text.substring(with: match.range(at: 2)).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            return title + " " + text.substring(with: match.range(at: 1)) + "% used · resets " + reset
        }
        guard let weekly = row("Weekly") else { return nil }
        var hasObservation = false
        var observed = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        if let regex = try? NSRegularExpression(pattern: "as\\s+of\\s+([^│\\r\\n]+)[│\\r\\n]", options: [.caseInsensitive]),
           let match = regex.matches(in: plain, range: NSRange(location: 0, length: (plain as NSString).length)).last {
            hasObservation = true
            observed = (plain as NSString).substring(with: match.range(at: 1)).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) + " (Muse)"
        }
        if requireObservation && !hasObservation { return nil }
        return [row("Current"), weekly, (hasObservation ? "as of " : "queried ") + observed].compactMap { $0 }.joined(separator: "\n")
    }
    static func terminalQuery(entry: Entry) throws -> String {
        var master: Int32 = -1; var slave: Int32 = -1
        var size = winsize(ws_row: 42, ws_col: 130, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw NSError(domain: "MuseQuota", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open Muse usage terminal"]) }
        var attributes = termios()
        if tcgetattr(slave, &attributes) == 0 { cfmakeraw(&attributes); _ = tcsetattr(slave, TCSANOW, &attributes) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-lc", ProviderCommand.script(entry: entry, arguments: ["--no-session-log"])]
        let cwd = NSString(string: entry.directory).expandingTildeInPath
        if FileManager.default.fileExists(atPath: cwd) { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["TERM"] = "xterm-256color"; env["TZ"] = TimeZone.current.identifier
        process.environment = env
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
        defer {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                process.waitUntilExit()
            }
            close(master); close(slave)
        }
        try process.run()
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let start = ProcessInfo.processInfo.systemUptime
        var sent = false; var entered = false; var retried = false; var readyAt: TimeInterval?; var output = Data(); var bytes = [UInt8](repeating: 0, count: 65536)
        while ProcessInfo.processInfo.systemUptime - start < 15 && process.isRunning {
            let elapsed = readyAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? -1
            if !sent && elapsed >= 0.4 { let command = Array("/usage".utf8); _ = command.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }; sent = true }
            // The TUI's paste-burst guard may interpret the first Return as a pasted
            // newline. A separate Return submits the built-in command; an empty
            // Return after it has already completed cannot submit a model prompt.
            if !entered && elapsed >= 1.6 { let enter: [UInt8] = [13]; _ = enter.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }; entered = true }
            if !retried && elapsed >= 3.4 { let enter: [UInt8] = [13]; _ = enter.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }; retried = true }
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) > 0 {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
                if count > 0 {
                    output.append(contentsOf: bytes.prefix(count))
                    let chunk = String(decoding: bytes.prefix(count), as: UTF8.self)
                    if readyAt == nil && String(decoding: output, as: UTF8.self).contains("❯") { readyAt = ProcessInfo.processInfo.systemUptime }
                    if chunk.contains("\u{001B}[6n") { let reply = Array("\u{001B}[1;1R".utf8); _ = reply.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) } }
                }
                if let result = parse(String(decoding: output, as: UTF8.self), requireObservation: false) { return result }
            }
        }
        if let path = env["CONVERSE_QUOTA_DEBUG_FILE"] { try? output.write(to: URL(fileURLWithPath: path)) }
        throw NSError(domain: "MuseQuota", code: 2, userInfo: [NSLocalizedDescriptionKey: "Muse /usage did not return weekly quota within 15 seconds. Authenticate in Muse and try refresh again."])
    }
}
