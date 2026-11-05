import Foundation

@MainActor func agentHomeAssistantSelfTests(_ check: (Bool, String) -> Void) {
    do {
        let base = try AgentHomeAssistant.base("http://homeassistant.local:8123/house/")
        check(AgentHomeAssistant.endpoint(base, entity: "sensor.office_temperature").absoluteString == "http://homeassistant.local:8123/house/api/states/sensor.office_temperature", "HA respects an installation path when requesting a selected state")
        check(try AgentHomeAssistant.entities("sensor.office_temperature, light.desk sensor.office_temperature") == ["light.desk", "sensor.office_temperature"], "HA selects only unique explicit entity IDs")
        do { _ = try AgentHomeAssistant.base("https://user:secret@example.com/"); check(false, "HA URL rejects embedded credentials") }
        catch { check(true, "HA URL rejects embedded credentials") }
        do { _ = try AgentHomeAssistant.entities("sensor.valid, https://evil.example/"); check(false, "HA entity scope rejects URLs") }
        catch { check(true, "HA entity scope rejects URLs") }
        var config = AgentConfig(); config.homeAssistantURL = base.absoluteString; config.homeAssistantEntities = "sensor.office_temperature"; config.homeAssistantRead = true
        let restored = try JSONDecoder().decode(AgentConfig.self, from: JSONEncoder().encode(config))
        check(restored.homeAssistantRead == true && restored.homeAssistantEntities == config.homeAssistantEntities, "HA scope survives an agent archive reload")
        var oldEditor = config.wire(home: "local"); oldEditor.homeAssistantURL = nil; oldEditor.homeAssistantEntities = nil; oldEditor.homeAssistantRead = nil
        try config.apply(oldEditor)
        check(config.homeAssistantRead == true && config.homeAssistantURL == base.absoluteString, "An older remote editor preserves HA scope")
    } catch { check(false, "HA configuration self-test: " + error.localizedDescription) }

    var requests: [URLRequest] = []
    var client = AgentHomeAssistant()
    client.request = { request in
        requests.append(request)
        let body = request.url?.absoluteString.hasSuffix("/api/") == true ? "{\"message\":\"API running.\"}" : "{\"entity_id\":\"sensor.office_temperature\",\"state\":\"21.5\",\"attributes\":{\"friendly_name\":\"Office temperature\",\"unit_of_measurement\":\"°C\"},\"last_changed\":\"2026-11-04T20:00:00Z\"}"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    var result: [String: Any] = [:], status = "", complete = false
    Task { @MainActor in
        do {
            status = try await client.test(address: "http://homeassistant.local:8123", token: "private-token-canary", entityText: "sensor.office_temperature")
            result = await client.evidence(address: "http://homeassistant.local:8123", token: "private-token-canary", entityText: "sensor.office_temperature")
        } catch { status = error.localizedDescription }
        complete = true
    }
    let deadline = Date().addingTimeInterval(2)
    while !complete && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    let rows = result["entities"] as? [[String: String]] ?? []
    check(complete && status.contains("connected") && rows.count == 1 && rows[0]["state"] == "21.5", "HA test and evidence read selected state")
    check(requests.count == 3 && requests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer private-token-canary" }, "HA client sends only authenticated GET requests")
    check(!String(describing: result).contains("private-token-canary"), "HA evidence never contains the bearer credential")
}
