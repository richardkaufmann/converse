import AppKit
import Foundation

struct KAOSFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// One sanctioned front door. Credentials never follow redirects, enter an
// archive, or travel with public image requests. No inbox operation exists.
final class KAOSRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class KAOSHTTP {
    private var activeSession: URLSession?
    var session: URLSession {
        if let activeSession { return activeSession }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 660; config.timeoutIntervalForResource = 690
        // The stateless delegate is retained by URLSession independently of
        // this owner. Never instantiate a lazy session from deinit (that can
        // resurrect a half-destroyed delegate during its invalidate callback).
        let created = URLSession(configuration: config, delegate: KAOSRedirectGuard(), delegateQueue: nil)
        activeSession = created; return created
    }
    deinit { activeSession?.invalidateAndCancel() }
}

struct KAOSSchema {
    let document: [String: Any]
    var title: String { (document["info"] as? [String: Any])?["title"] as? String ?? "KAOS" }
    var version: String { (document["info"] as? [String: Any])?["version"] as? String ?? "" }
    func operation(_ path: String, method: String) throws -> [String: Any] {
        guard let paths = document["paths"] as? [String: Any], let entry = paths[path] as? [String: Any], let op = entry[method.lowercased()] as? [String: Any] else { throw KAOSFailure(message: "The live bridge schema does not offer this operation. Refresh the connection.") }
        return op
    }
    func body(_ path: String) throws -> [String: Any] {
        let op = try operation(path, method: "POST")
        guard let request = op["requestBody"] as? [String: Any], let content = request["content"] as? [String: Any], let json = content["application/json"] as? [String: Any], let schema = json["schema"] as? [String: Any] else { throw KAOSFailure(message: "The live bridge has no JSON request schema for this operation.") }
        return schema
    }
    func validate(_ value: Any, schema: [String: Any], field: String = "request") throws {
        func fail(_ note: String) throws { throw KAOSFailure(message: field + " " + note) }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any] else { try fail("must be a JSON object."); return }
            for key in schema["required"] as? [String] ?? [] where object[key] == nil { try fail("requires " + key + ".") }
            for (key, child) in schema["properties"] as? [String: [String: Any]] ?? [:] { if let v = object[key] { try validate(v, schema: child, field: field + "." + key) } }
        case "string":
            guard let text = value as? String else { try fail("must be text."); return }
            if let max = schema["maxLength"] as? Int, text.unicodeScalars.count > max { try fail("exceeds the bridge limit of \(max) characters.") }
        case "array":
            guard let array = value as? [Any] else { try fail("must be a JSON array."); return }
            if let max = schema["maxItems"] as? Int, array.count > max { try fail("has too many items (maximum \(max)).") }
            if let item = schema["items"] as? [String: Any] { for v in array { try validate(v, schema: item, field: field + "[]") } }
        case "integer", "number":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { try fail("must be numeric."); return }
            let v = number.doubleValue
            if schema["type"] as? String == "integer", v.rounded() != v { try fail("must be an integer.") }
            if let min = schema["minimum"] as? Double, v < min { try fail("is below the bridge minimum.") }
            if let max = schema["maximum"] as? Double, v > max { try fail("exceeds the bridge maximum.") }
        default: break // Unconstrained scalar (scenario value) is validated by the bridge.
        }
    }
    func example(_ schema: [String: Any]) -> Any {
        if let value = schema["default"] { return value }
        switch schema["type"] as? String {
        case "object": return (schema["properties"] as? [String: [String: Any]] ?? [:]).filter { $0.key != "request_id" }.mapValues(example)
        case "array": return (schema["items"] as? [String: Any]).map { [$0["type"] as? String == "object" ? example($0) : ""] } ?? []
        case "string": return ""
        case "integer", "number": return 0
        default: return NSNull()
        }
    }
}

struct KAOSPrepared: Identifiable {
    enum Kind { case job, scenario }
    let id: String
    let kind: Kind
    let summary: String
    let lane: String
    fileprivate let token: String
}

@MainActor final class KAOSClient {
    private let http = KAOSHTTP()
    var request: ((URLRequest) async throws -> (Data, HTTPURLResponse))?
    var token: () throws -> String = {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("muse-kaos/secrets/muse-bridge.token")
        guard let data = try? Data(contentsOf: path), data.count <= 16_384, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !text.contains("\n"), !text.contains("\r") else { throw KAOSFailure(message: "Bridge token unavailable. The existing muse-kaos/secrets/muse-bridge.token file must be readable on this Mac.") }
        return text
    }
    private(set) var schema: KAOSSchema?
    private(set) var asking = false
    static let base = URL(string: "http://127.0.0.1:4691")!
    static func lane(_ json: [String: Any]) -> String {
        let lane = json["lane"] as? [String: Any] ?? [:]
        let name = lane["name"] as? String ?? "Unknown lane"
        return name + (lane["scenarioRevision"].map { " · r" + String(describing: $0) } ?? "")
    }
    func exchange(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            if let request { return try await request(req) }
            let (data, response) = try await http.session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw KAOSFailure(message: "Invalid bridge response.") }
            return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch let error as KAOSFailure { throw error }
        catch { throw KAOSFailure(message: "Bridge request did not finish. Check the local bridge. No automatic retry was made.") }
    }
    private func json(_ path: String, method: String = "GET", body: [String: Any]? = nil, authorized: Bool = true) async throws -> [String: Any] {
        var req = URLRequest(url: Self.base.appendingPathComponent(path)); req.httpMethod = method; req.timeoutInterval = path == "v1/ask" ? 660 : 180
        if authorized { req.setValue("Bearer " + (try token()), forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await exchange(req)
        guard data.count <= 4_194_304 else { throw KAOSFailure(message: "Bridge response was too large.") }
        let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(response.statusCode), value["ok"] as? Bool != false else {
            if value["error"] as? String == "Lane busy." { throw KAOSFailure(message: "Lane busy.") }
            switch response.statusCode {
            case 401, 403: throw KAOSFailure(message: "Bridge authorization refused. Check the existing token file.")
            case 429: throw KAOSFailure(message: (value["error"] as? String == "another ask is in flight; retry shortly") ? "Lane busy." : "Bridge hourly request limit reached. Try later.")
            default: throw KAOSFailure(message: "Bridge refused the request (HTTP \(response.statusCode)). Nothing was retried automatically.")
            }
        }
        guard !value.isEmpty else { throw KAOSFailure(message: "Bridge returned invalid JSON.") }
        return value
    }
    func connect() async throws -> String {
        schema = nil
        let health = try await json("health", authorized: false)
        guard health["ok"] as? Bool == true, health["service"] as? String == "muse-bridge" else { throw KAOSFailure(message: "The local service is not the Muse bridge.") }
        let live = KAOSSchema(document: try await json("openapi.json", authorized: false))
        _ = try live.operation("/identity", method: "GET"); _ = try live.body("/v1/ask")
        let identity = try await json("identity")
        schema = live
        return Self.lane(identity) + " · " + live.title + " " + live.version
    }
    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let schema else { throw KAOSFailure(message: "Connect to the bridge first.") }
        try schema.validate(body, schema: schema.body("/" + path))
        return try await json(path, method: "POST", body: body)
    }
    func ask(_ question: String, context: String) async throws -> [String: Any] {
        guard !asking else { throw KAOSFailure(message: "Lane busy.") }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KAOSFailure(message: "Enter a question.") }
        asking = true; defer { asking = false }
        return try await post("v1/ask", body: ["question": question, "context": context, "request_id": UUID().uuidString])
    }
    func prepare(scenario: Bool, body: [String: Any]) async throws -> KAOSPrepared {
        let json = try await post(scenario ? "v1/scenario/propose" : "v1/jobs/prepare", body: body)
        guard let id = json[scenario ? "proposalId" : "jobId"] as? String, Self.validID(id), let summary = json["summary"] as? String, !summary.isEmpty, let token = json["confirmToken"] as? String, !token.isEmpty else { throw KAOSFailure(message: "Bridge returned an incomplete proposal. Nothing was approved.") }
        return KAOSPrepared(id: id, kind: scenario ? .scenario : .job, summary: summary, lane: Self.lane(json), token: token)
    }
    static func validID(_ id: String) -> Bool { id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil }
    func confirm(_ prepared: KAOSPrepared) async throws -> [String: Any] {
        let template = prepared.kind == .job ? "/v1/jobs/{jobId}/confirm" : "/v1/scenario/{proposalId}/apply"
        guard let schema, Self.validID(prepared.id) else { throw KAOSFailure(message: "Invalid prepared action.") }
        try schema.validate(["confirmToken": prepared.token], schema: schema.body(template))
        let path = prepared.kind == .job ? "v1/jobs/\(prepared.id)/confirm" : "v1/scenario/\(prepared.id)/apply"
        return try await json(path, method: "POST", body: ["confirmToken": prepared.token])
    }
    func job(_ id: String, cancel: Bool = false) async throws -> [String: Any] {
        guard let schema, Self.validID(id) else { throw KAOSFailure(message: "Invalid job ID.") }
        _ = try schema.operation(cancel ? "/v1/jobs/{jobId}/cancel" : "/v1/jobs/{jobId}", method: cancel ? "POST" : "GET")
        return try await json("v1/jobs/" + id + (cancel ? "/cancel" : ""), method: cancel ? "POST" : "GET")
    }
    func image(_ url: URL) async throws -> Data {
        guard url.scheme == "https", url.host == "muse.kaoslabs.app", url.port == nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.hasPrefix("/v1/images/"), Self.validID(String(url.path.dropFirst("/v1/images/".count))) else { throw KAOSFailure(message: "Bridge image URL was not recognized.") }
        var req = URLRequest(url: url); req.timeoutInterval = 30
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("muse-kaos/secrets/cf-access-muse-bridge.json")
        if let data = try? Data(contentsOf: file), data.count < 65_536, let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let headers = document["headers"] as? [String: Any] ?? document
            let id = headers["CF-Access-Client-Id"] as? String ?? headers["client_id"] as? String ?? headers["clientId"] as? String
            let secret = headers["CF-Access-Client-Secret"] as? String ?? headers["client_secret"] as? String ?? headers["clientSecret"] as? String
            if let id, let secret, !id.contains("\r"), !id.contains("\n"), !secret.contains("\r"), !secret.contains("\n") { req.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id"); req.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret") }
        }
        let (data, response) = try await exchange(req)
        guard response.statusCode == 200, data.count <= 8_000_000, let png = ResponseImages.normalizedPNG(data) else { throw KAOSFailure(message: "Image unavailable or expired. Open its link to view it.") }
        return png
    }
    static func displayJSON(_ json: [String: Any]) -> String {
        func redact(_ value: Any) -> Any {
            if let object = value as? [String: Any] { return object.filter { key, _ in !["token", "secret", "authorization"].contains(where: key.lowercased().contains) }.mapValues(redact) }
            if let array = value as? [Any] { return array.map(redact) }
            return value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: redact(json), options: [.prettyPrinted, .sortedKeys]) else { return "Invalid bridge result." }
        return String(decoding: data, as: UTF8.self)
    }
}

// Explicit user action only. Invoke the EXISTING app tool, rather than create
// a second outbox implementation or call the unauthenticated KAOS app port.
enum JollyOutbox {
    static func send(_ text: String, root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("muse-kaos/app"), testData: URL? = nil) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.unicodeScalars.count <= 500 else { throw KAOSFailure(message: "Enter a message of at most 500 characters.") }
        let python = root.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path), FileManager.default.fileExists(atPath: root.appendingPathComponent("claude_assistant.py").path) else { throw KAOSFailure(message: "The existing KAOS outbox tool is not installed on this Mac.") }
        let process = Process(); process.executableURL = python; process.currentDirectoryURL = root
        process.arguments = ["-c", "import json,sys\nfrom claude_assistant import tool_send_jolly_message\nr=tool_send_jolly_message(json.load(sys.stdin))\nprint('CONVERSE_JOLLY_RESULT:'+json.dumps(r))"]
        var env = ProcessInfo.processInfo.environment
        if let testData {
            guard env["CONVERSE_TEST_COMMAND"] != nil else { throw KAOSFailure(message: "Outbox test isolation requires the test harness.") }
            env["AI_RACK_LANDING_DATA_DIR"] = testData.path
        }
        process.environment = env
        let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["message": text])); try? input.fileHandleForWriting.close()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } } } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); timeout.cancel()
        let line = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n").last { $0.hasPrefix("CONVERSE_JOLLY_RESULT:") }
        guard process.terminationStatus == 0, let line, let data = String(line.dropFirst("CONVERSE_JOLLY_RESULT:".count)).data(using: .utf8), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any], result["ok"] as? Bool == true else { throw KAOSFailure(message: "Outbox result was not confirmed. Check KAOS before retrying; no automatic resend was made.") }
        return "Left in the shared outbox. Jolly will relay it when you say ‘check KAOS’. This is not a push notification."
    }
}
