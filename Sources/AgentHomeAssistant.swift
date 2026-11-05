import Foundation

/// One shared credential, with an explicit per-agent list of readable entities.
/// The model never chooses URLs or receives the token. HA calls are GET only.
struct AgentHomeAssistant {
    var request: (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AgentFailure.message("Home Assistant did not return HTTP.") }
        return (data, response)
    }

    static func base(_ raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 500, let parts = URLComponents(string: text),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let url = parts.url else {
            throw AgentFailure.message("Enter a Home Assistant HTTP(S) address without a login, query or fragment.")
        }
        return url
    }
    static func entities(_ raw: String) throws -> [String] {
        let names = raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        let unique = Array(Set(names)).sorted()
        guard unique.count <= 32, unique.allSatisfy(validEntity) else {
            throw AgentFailure.message("Choose up to 32 Home Assistant entity IDs, such as sensor.living_room_temperature.")
        }
        return unique
    }
    private static func validEntity(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && id.utf8.count <= 128 && parts.allSatisfy { part in
            !part.isEmpty && part.first?.isLetter == true && part.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
        }
    }
    static func endpoint(_ base: URL, entity: String? = nil) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = "/" + (parts.path.isEmpty ? "" : parts.path + "/") + "api/" + (entity.map { "states/" + $0 } ?? "")
        return parts.url!
    }
    private func get(_ url: URL, token: String) async throws -> [String: Any] {
        var req = URLRequest(url: url); req.timeoutInterval = 12
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await request(req)
        guard (200..<300).contains(response.statusCode) else {
            throw AgentFailure.message(response.statusCode == 401 ? "Home Assistant rejected the token." :
                response.statusCode == 404 ? "Home Assistant entity was not found." : "Home Assistant returned HTTP \(response.statusCode).")
        }
        guard data.count <= 262_144, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentFailure.message("Home Assistant returned an invalid or oversized response.")
        }
        return json
    }
    func test(address: String, token: String, entityText: String) async throws -> String {
        let base = try Self.base(address), ids = try Self.entities(entityText)
        guard !token.isEmpty else { throw AgentFailure.message("Enter a Home Assistant token or save one first.") }
        let status = try await get(Self.endpoint(base), token: token)
        guard status["message"] as? String == "API running." else { throw AgentFailure.message("Home Assistant did not confirm its API is running.") }
        let started = Date()
        for id in ids {
            guard Date().timeIntervalSince(started) < 20 else { throw AgentFailure.message("Home Assistant test took too long. Try fewer entities or check the network.") }
            _ = try await get(Self.endpoint(base, entity: id), token: token)
        }
        return "Home Assistant connected. \(ids.count) selected \(ids.count == 1 ? "entity" : "entities") readable. Nothing was changed."
    }
    func evidence(address: String, token: String, entityText: String) async -> [String: Any] {
        do {
            let base = try Self.base(address), ids = try Self.entities(entityText)
            guard !token.isEmpty else { throw AgentFailure.message("Home Assistant token missing; add it in Agent Setup.") }
            var rows: [[String: String]] = []
            let started = Date()
            for id in ids {
                if Date().timeIntervalSince(started) >= 20 {
                    rows.append(["entityID": id, "error": "Lookup time budget exhausted; state unknown."])
                    continue
                }
                do {
                    let state = try await get(Self.endpoint(base, entity: id), token: token)
                    guard state["entity_id"] as? String == id, let value = state["state"] as? String else {
                        throw AgentFailure.message("Home Assistant returned a mismatched entity.")
                    }
                    let attributes = state["attributes"] as? [String: Any] ?? [:]
                    rows.append(["entityID": id, "state": String(value.prefix(256)),
                                 "name": String((attributes["friendly_name"] as? String ?? id).prefix(120)),
                                 "unit": String((attributes["unit_of_measurement"] as? String ?? "").prefix(32)),
                                 "lastChanged": String((state["last_changed"] as? String ?? "").prefix(64))])
                } catch {
                    rows.append(["entityID": id, "error": "Unavailable on this check; do not assume the entity is off."])
                }
            }
            return ["source": base.absoluteString, "observedAt": ISO8601DateFormatter().string(from: Date()),
                    "entities": rows, "scope": "Read-only states for explicitly selected entities; no actions or hidden attributes."]
        } catch {
            return ["error": error.localizedDescription]
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
