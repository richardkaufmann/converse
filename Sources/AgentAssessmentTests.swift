import AppKit
import Foundation

@MainActor func agentAssessmentSelfTests(_ check: (Bool, String) -> Void) {
    func spin(_ seconds: Double = 4, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    func json(_ text: String) -> AgentJSON { try! JSONDecoder().decode(AgentJSON.self, from: Data(text.utf8)) }
    let now = ISO8601DateFormatter().date(from: "2026-11-07T21:00:00Z")!
    let lotID = UUID()
    let lot = AgentLotScoreboard.measure(id: lotID, home: nil, name: "Converse", document: ParkingLotDocument(revision: 9, rows: [
        ParkingLotRow(heading: true, text: "Bugs"), ParkingLotRow(heading: false, text: "Clipped", tag: .red), ParkingLotRow(heading: false, text: "Slow"),
        ParkingLotRow(heading: true, text: "Ideas"), ParkingLotRow(heading: false, text: "Portraits", tag: .green)]), now: now)
    var snapshot = AgentRepoSnapshot(repository: "kaos/converse", observedAt: now, stars: 41, releaseDownloads: 900, uniqueCloners14d: 12)
    snapshot.uniqueClonersTodayUTC = nil
    let versions: [String: Any] = ["thisDevice": ["name": "Mac", "installedVersion": "0.15.2 (152)", "observedAt": "2026-11-07T21:00:00Z"],
                                   "pairedDevices": [["name": "iPad", "installedVersion": "0.15.2 (152)"], ["name": "PC", "installedVersion": "0.15.1 (151)"]]]
    let measured = AgentAssessments.measured(lots: [lot], repository: "kaos/converse", snapshot: snapshot, discord: (count: 3, atLimit: false, channel: "42"), versions: versions, now: now)
    let ids = Set(measured.map(\.id))
    check(ids.contains("lot." + lotID.uuidString + ".unfinished") && ids.contains("lot." + lotID.uuidString + ".red") && ids.contains("github.stars") && ids.contains("github.downloads")
          && ids.contains("github.cloners14d") && ids.contains("discord.new") && ids.contains("fleet.versions"),
          "Converse measures Parking Lot counts with reds, GitHub stars/downloads/cloners, Discord new and fleet versions")
    check(measured.first { $0.id == "lot." + lotID.uuidString + ".red" }?.value == "1" && measured.first { $0.id == "lot." + lotID.uuidString + ".unfinished" }?.value == "3"
          && measured.first { $0.id == "fleet.versions" }?.value == "2 of 3 devices" && measured.first { $0.id == "discord.new" }?.value == "3",
          "Measured values come from host data")
    check(measured.first { $0.id == "github.clonersToday" }?.value == AgentFact.unavailable && measured.first { $0.id == "github.clonersToday" }?.source == "github.com/kaos/converse",
          "A missing host measurement reads Unavailable with its source")

    // 1. Contract: valid, invented and unknown measured values, malformed.
    let valid = json("""
    {"summary":"Two bugs remain. Release is close.","status":"at-risk","mood":["watchful","busy","hopeful"],
     "facts":[{"id":"github.stars","kind":"measured","value":"9999"},
              {"id":"lot.\(lotID.uuidString).red","label":"Reds","kind":"measured"},
              {"id":"users","label":"Users","value":"5000","kind":"measured","source":"guess"},
              {"label":"Clipping fix","value":"Verified in Writer","kind":"evidence","source":"session 1234","observedAt":"2026-11-07T20:30:00Z","detail":{"steps":[{"name":"repro","ok":true},{"name":"fix","ok":true}],"owner":"Writer"}},
              {"label":"Ship 152 tonight","value":"Likely","kind":"judgment"}],
     "detail":{"risks":{"top":"renderer stall","others":["tests","docs"]}}}
    """)
    guard case .revision(let first) = AgentAssessments.evaluate(valid, measured: measured, previous: nil, now: now) else { check(false, "A valid assessment creates a revision"); return }
    check(first.revision == 1 && first.status == .atRisk && first.summary == "Two bugs remain. Release is close." && first.facts.count == 5 && first.contentHash.count == 64 && first.mood == ["watchful", "busy", "hopeful"],
          "A valid assessment becomes revision 1 with a content hash")
    check(first.facts[0].value == "41" && first.facts[0].source == "github.com/kaos/converse" && first.facts[1].value == "1" && first.facts[1].label == "Converse · red",
          "Measured facts always show the host value, never the model's typed value")
    check(first.facts[2].value == AgentFact.unavailable && first.facts[2].kind == .measured && first.facts[2].source == "Not measured by Converse",
          "A measured fact Converse does not have reads Unavailable instead of the model's invented value")
    check(first.facts[3].kind == .evidence && first.facts[3].observedAt == ISO8601DateFormatter().date(from: "2026-11-07T20:30:00Z") && first.facts[3].detail?["owner"]?.string == "Writer"
          && first.facts[4].kind == .judgment && first.facts[4].source == "judgment", "Evidence keeps its source time and nested detail; judgments are labelled")
    for (raw, label) in [(nil as AgentJSON?, "missing"), (.string("fine"), "a string"), (json("{\"status\":\"on-track\"}"), "no summary"), (json("{\"summary\":\"x\",\"status\":\"great\"}"), "an invalid status"), (json("{\"summary\":\"x\",\"status\":\"done\",\"facts\":7}"), "non-array facts")] {
        if case .rejected = AgentAssessments.evaluate(raw, measured: measured, previous: first, now: now) { check(true, "Assessment rejected when " + label) } else { check(false, "Assessment rejected when " + label) }
    }
    check(AgentReply.decode("{\"reply\":\"Still here\",\"assessment\":\"not json object\"}")?.reply == "Still here"
          && AgentReply.decode("{\"reply\":\"r\",\"assessment\":{\"summary\":[1,{\"deep\":true}],\"status\":null}}")?.assessment != nil,
          "A malformed assessment never makes the agent reply undecodable")

    // 2. Revision vs heartbeat; history; stale marking.
    var config = AgentConfig()
    check(config.recordAssessment(.revision(first), now: now) && config.assessment?.revision == 1, "First assessment is stored")
    let later = now.addingTimeInterval(600)
    var remeasured = measured; for index in remeasured.indices { remeasured[index].observedAt = later }
    let reworded = json("""
    {"summary":"  two bugs remain.   Release is close. ","status":"at-risk",
     "facts":[{"id":"github.stars","kind":"measured"},{"id":"lot.\(lotID.uuidString).red","kind":"measured"},{"id":"users","label":"Users","kind":"measured"},
              {"label":"Clipping fix","value":"Verified in Writer","kind":"evidence","source":"session 1234","observedAt":"2026-11-07T20:30:00Z","detail":{"owner":"Writer","steps":[{"name":"repro","ok":true},{"name":"fix","ok":true}]}},
              {"label":"Ship 152 tonight","value":"Likely","kind":"judgment"}],
     "detail":{"risks":{"others":["tests","docs"],"top":"renderer stall"}}}
    """)
    let beat = AgentAssessments.evaluate(reworded, measured: remeasured, previous: config.assessment, now: later)
    guard case .heartbeat(let unchanged) = beat else { check(false, "Unchanged content is a heartbeat, not a revision"); return }
    check(!config.recordAssessment(beat, now: later) && config.assessment?.revision == 1 && config.assessment?.heartbeats == 1 && config.assessment?.checkedAt == later && config.assessment?.updatedAt == now
          && unchanged.facts[0].observedAt == later && unchanged.facts[3].observedAt == first.facts[3].observedAt,
          "Same content (whitespace, case, key order) heartbeats: revision kept, re-measured facts advance, cited facts keep their own time")
    var changedSnapshot = snapshot; changedSnapshot.stars = 42
    let changed = AgentAssessments.measured(lots: [lot], repository: "kaos/converse", snapshot: changedSnapshot, discord: nil, versions: nil, now: later)
    let second = AgentAssessments.evaluate(reworded, measured: changed, previous: config.assessment, now: later)
    check(config.recordAssessment(second, now: later) && config.assessment?.revision == 2 && config.assessmentHistory?.first?.revision == 1 && config.assessmentHistory?.first?.heartbeats == 1,
          "A changed measurement creates revision 2 and keeps revision 1 in history with its heartbeat count")
    let kept = config.assessment
    config.recordAssessment(AgentAssessments.evaluate(.string("oops"), measured: changed, previous: config.assessment, now: later), now: later)
    check(config.assessment == kept && config.assessmentProblem?.reason == "Assessment was not a JSON object." && AgentAssessmentFreshness.of(config.assessment, problem: config.assessmentProblem, now: later) == .stale("Assessment was not a JSON object."),
          "A malformed assessment keeps the last record and marks it stale with a reason")
    config.recordAssessment(second, now: later)
    check(config.assessmentProblem == nil && AgentAssessmentFreshness.of(config.assessment, problem: nil, now: later) == .fresh
          && AgentAssessmentFreshness.of(config.assessment, problem: nil, now: later.addingTimeInterval(7200)) == .aging, "A good turn clears the stale mark; freshness ages")
    var history = AgentConfig()
    for index in 0..<14 { history.recordAssessment(.revision(AgentAssessment(summary: "s\(index)", status: .onTrack, facts: [], revision: index + 1, contentHash: "\(index)")), now: now) }
    check(history.assessmentHistory?.count == AgentAssessments.historyLimit && history.assessment?.revision == 14, "Assessment history stays bounded")

    // 3. Nested detail: bounded storage, outline rendering, hover/click/keyboard model.
    let nested = json("{\"b\":[1,{\"c\":\"deep\"}],\"a\":{\"x\":true,\"y\":null}}")
    let outline = nested.outline()
    check(outline.map(\.key) == ["a", "x", "y", "b", "1.", "2.", "c"] && outline.map(\.depth) == [0, 1, 1, 0, 1, 1, 2] && outline[1].value == "true" && outline[6].value == "deep" && outline[0].value == nil,
          "Nested detail renders as an indented outline with sorted keys and numbered items")
    var deep = AgentJSON.string("leaf"); for _ in 0..<20 { deep = .object(["n": deep]) }
    let huge = AgentJSON.array((0..<5000).map { .string(String(repeating: "x", count: 3000) + String($0)) })
    check(deep.bounded(nodes: 600).canonical.contains("…") && huge.bounded(nodes: 600).canonical.utf8.count < 200_000, "Stored detail is depth-, size- and node-bounded")
    var expansion = AssessmentDetailExpansion()
    expansion.hover("fact.a", true)
    check(expansion.isExpanded("fact.a") && !expansion.isExpanded("fact.b"), "Hover expands a fact's detail")
    expansion.hover("fact.a", false)
    check(!expansion.isExpanded("fact.a"), "Leaving the row collapses unpinned detail")
    expansion.hover("fact.a", true); expansion.activate("fact.a"); expansion.hover("fact.a", false)
    check(expansion.isExpanded("fact.a"), "Clicking (or Space/Return) pins the detail open after the pointer leaves")
    expansion.activate("fact.a")
    check(!expansion.isExpanded("fact.a"), "Activating again closes it; keyboard and VoiceOver use the same action")
    expansion.activate("card"); expansion.activate("fact.b")
    check(expansion.isExpanded("card") && expansion.isExpanded("fact.b"), "Several rows can be pinned for comparison")

    // 4. Migration: earlier scoreboards seed a labelled assessment; old archives decode.
    var legacy = AgentConfig(); legacy.artDirection = "Ink explorers"; legacy.generateArt = true; legacy.artPath = "/tmp/old.png"
    legacy.scoreboard = AgentScoreboard(summary: "Bugs climbing this week", metrics: [.init(label: "Open bugs", value: "7", sourceURL: "https://example.invalid/bugs", asOf: "Nov 6")], sentiment: "urgent", observedAt: now)
    var seeded = legacy; seeded.seedAssessmentFromScoreboard(now: later)
    check(seeded.assessment?.seeded == true && seeded.assessment?.status == .atRisk && seeded.assessment?.facts.first?.value == "7" && seeded.assessment?.facts.first?.observedAt == now
          && seeded.artDirection == "Ink explorers" && AgentAssessmentFreshness.of(seeded.assessment, problem: nil, now: later) != .fresh,
          "Migration seeds a stale-labelled assessment from the last scoreboard and keeps the art direction for portraits")
    var reseed = seeded; reseed.assessment?.summary = "kept"; reseed.seedAssessmentFromScoreboard(now: later)
    check(reseed.assessment?.summary == "kept", "Seeding never overwrites a real assessment")
    if case .revision(let replaced) = AgentAssessments.evaluate(valid, measured: measured, previous: seeded.assessment, now: later) { check(replaced.revision == 2 && replaced.seeded == nil, "The first real turn replaces the seeded assessment") }
    else { check(false, "The first real turn replaces the seeded assessment") }
    do {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        for field in ["assessment", "assessmentHistory", "assessmentProblem", "portrait", "portraitMinMinutes"] { object.removeValue(forKey: field) }
        let decoded = try JSONDecoder().decode(AgentConfig.self, from: JSONSerialization.data(withJSONObject: object))
        check(decoded.assessment == nil && decoded.artDirection == "Ink explorers" && decoded.artPath == "/tmp/old.png" && decoded.generateArt, "Pre-152 agent archives decode unchanged, existing art path kept")
        var stored = seeded; stored.recordAssessment(second, now: later)
        check(try JSONDecoder().decode(AgentConfig.self, from: JSONEncoder().encode(stored)) == stored, "Assessments with nested detail survive persistence")
    } catch { check(false, "Assessment migration: " + error.localizedDescription) }

    // 5. Portrait prompt: no factual numbers, stylistic opt-in, square.
    var portraitConfig = AgentConfig(); portraitConfig.objective = "Ship Converse 152 with assessments. Then rest."; portraitConfig.assessment = first
    let prompt = PortraitPrompt.build(name: "KAOS Steward", config: portraitConfig)
    check(prompt.contains("KAOS Steward") && prompt.contains("Ship Converse 152 with assessments.") && !prompt.contains("Then rest") && prompt.contains("Two bugs remain")
          && prompt.contains("watchful, busy, hopeful") && prompt.contains(PortraitPrompt.noFacts) && prompt.contains("No text or letters") && prompt.contains(PortraitPrompt.fleetStyle),
          "Portrait prompt: name, one-line objective, assessment summary, mood words, fleet style and the no-facts rule")
    check(!prompt.contains("41") && !prompt.contains("Verified in Writer") && !prompt.contains("Likely"), "Portrait prompt never includes fact values")
    portraitConfig.artDirection = "Retro movie poster with the agent's name in bold lettering"
    let lettered = PortraitPrompt.build(name: "KAOS Steward", config: portraitConfig)
    check(lettered.contains(PortraitPrompt.stylisticText) && lettered.contains(PortraitPrompt.noFacts) && lettered.contains("Retro movie poster"), "Art direction may opt into stylistic text but never factual numbers")
    check(PortraitPrompt.directionVersion("Retro  Poster") == PortraitPrompt.directionVersion("retro poster") && PortraitPrompt.directionVersion("a") != PortraitPrompt.directionVersion("b"), "Art-direction version normalizes whitespace and case")
    let apiProbe = AgentAPI(); var imageBody: [String: Any]?
    let tiny = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
    apiProbe.request = { request in
        imageBody = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (try JSONSerialization.data(withJSONObject: ["data": [["b64_json": tiny.base64EncodedString()]]]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    var probed = false
    Task { @MainActor in _ = try? await apiProbe.art(prompt: prompt, key: "isolated-test-key"); probed = true }
    spin { probed }
    check(imageBody?["size"] as? String == "1024x1024" && imageBody?["model"] as? String == "muse-image-1.0", "Portraits use the existing Muse Image path at square 1:1 by default")

    // 6. PortraitService: cache by content hash, coalescing, mid-generation change, backoff, demand.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-portraits-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root)
    let agent = store.createAgent(title: "KAOS Steward"); agent.agent?.enabled = false
    agent.agent?.recordAssessment(.revision(first), now: now)
    let service = PortraitService()
    var calls = 0, prompts: [String] = [], gate: CheckedContinuation<Void, Never>?, holdNext = false, failNext = false
    func png(_ color: NSColor) -> Data {
        NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in color.setFill(); rect.fill(); return true }.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }!
    }
    service.generator = { prompt in
        calls += 1; prompts.append(prompt)
        if holdNext { holdNext = false; await withCheckedContinuation { gate = $0 } }
        if failNext { failNext = false; throw AgentFailure.message("quota reached") }
        return png(calls % 2 == 0 ? .orange : .purple)
    }
    service.clock = { now }
    agent.agent?.portraitMinMinutes = 0
    var outcomes: [PortraitOutcome] = []
    Task { @MainActor in outcomes.append(await service.request(agent, store: store, origin: .menu)) }
    spin { outcomes.count == 1 }
    check(calls == 1 && outcomes.first?.png != nil && outcomes.first?.stale == false && outcomes.first?.image?.sourceRevision == 1 && agent.agent?.portrait?.latest?.cacheKey == PortraitService.cacheKey(agent: agent.id, config: agent.agent!),
          "First request generates one portrait keyed by agent, content hash and art direction")
    check(!agent.messages.contains { !$0.images.isEmpty }, "A portrait is never attached to a transcript unless the request asks for it")
    agent.agent?.assessment?.revision = 7; agent.agent?.assessment?.heartbeats = 30; agent.agent?.assessment?.checkedAt = later
    Task { @MainActor in outcomes.append(await service.request(agent, store: store, origin: .jolly)) }
    spin { outcomes.count == 2 }
    check(calls == 1 && outcomes[1].cached && outcomes[1].png != nil, "The cache is keyed by content hash, not revision or heartbeat")
    agent.agent?.artDirection = "Steampunk lighthouse keeper"
    Task { @MainActor in outcomes.append(await service.request(agent, store: store, origin: .menu)) }
    spin { outcomes.count == 3 }
    check(calls == 2 && prompts.last?.contains("Steampunk lighthouse keeper") == true, "An art-direction change is a new cache key")
    // Coalescing: matching concurrent requests join one generation.
    agent.agent?.recordAssessment(second, now: later)
    holdNext = true
    Task { @MainActor in outcomes.append(await service.request(agent, store: store, origin: .window)) }
    Task { @MainActor in outcomes.append(await service.request(agent, store: store, origin: .discord)) }
    Task { @MainActor in outcomes.append(await service.request(agent, store: store, origin: .session)) }
    spin { gate != nil }
    check(calls == 3 && service.isGenerating(agent.id), "Three matching requests start one generation")
    // Mid-generation change: the running result keeps its source revision; the latest is queued.
    let third = AgentAssessment(summary: "All clear now.", status: .done, facts: [], revision: 3, contentHash: "third-content", updatedAt: later, checkedAt: later)
    agent.agent?.recordAssessment(.revision(third), now: later)
    Task { @MainActor in outcomes.append(await service.request(agent, store: store, origin: .jolly)) }
    spin(0.3) { false }
    check(calls == 3 && outcomes.count == 3, "A request for changed content waits behind the running generation")
    gate?.resume(); gate = nil
    spin { outcomes.count == 7 }
    let joined = Array(outcomes[3..<6])
    check(joined.allSatisfy { $0.image?.sourceRevision == 2 && $0.stale } && Set(joined.compactMap { $0.image?.path }).count == 1,
          "Joined requests share one result that keeps its source revision and is flagged stale once the assessment moved on")
    check(calls == 4 && outcomes[6].image?.sourceRevision == 3 && !outcomes[6].stale && agent.agent?.portrait?.latest?.sourceRevision == 3 && prompts.last?.contains("All clear now.") == true,
          "The latest demanded revision is generated after the running one finishes")
    check(((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Agents/" + agent.id.uuidString).path)) ?? []).filter { $0.hasPrefix("portrait-") }.count == 1,
          "Superseded portrait files are pruned; transcript copies are separate")
    // Minimum interval: unchanged demand within it returns the latest, flagged.
    agent.agent?.portraitMinMinutes = 10
    agent.agent?.recordAssessment(.revision(AgentAssessment(summary: "New risk appeared.", status: .atRisk, facts: [], revision: 4, contentHash: "fourth", updatedAt: later, checkedAt: later)), now: later)
    Task { @MainActor in outcomes.append(await service.request(agent, store: store, origin: .jolly)) }
    spin { outcomes.count == 8 }
    check(calls == 4 && outcomes[7].stale && outcomes[7].png != nil && outcomes[7].note?.contains("at most every 10 min") == true && !service.hasDeferred(agent.id),
          "Within the minimum interval an explicit request gets the latest portrait, labelled stale, without a new generation")
    Task { @MainActor in outcomes.append(await service.request(agent, store: store, origin: .menu, force: true)) }
    spin { outcomes.count == 9 }
    check(calls == 5 && !outcomes[8].stale && outcomes[8].image?.sourceRevision == 4, "Refresh (force) bypasses the minimum interval")
    // Failure: keep the last image, record the reason, back off; Refresh still works.
    agent.agent?.portraitMinMinutes = 0
    agent.agent?.recordAssessment(.revision(AgentAssessment(summary: "Worse.", status: .blocked, facts: [], revision: 5, contentHash: "fifth", updatedAt: later, checkedAt: later)), now: later)
    failNext = true
    Task { @MainActor in outcomes.append(await service.request(agent, store: store, origin: .window)) }
    spin { outcomes.count == 10 }
    let failedRecord = agent.agent?.portrait
    check(calls == 6 && outcomes[9].png != nil && outcomes[9].stale && outcomes[9].error?.contains("quota reached") == true && failedRecord?.failures == 1
          && failedRecord?.retryAt == now.addingTimeInterval(60) && failedRecord?.latest?.sourceRevision == 4,
          "A failed generation keeps the last image with its reason and schedules a backoff")
    Task { @MainActor in outcomes.append(await service.request(agent, store: store, origin: .jolly)) }
    spin { outcomes.count == 11 }
    check(calls == 6 && outcomes[10].note?.contains("Couldn't refresh: quota reached") == true, "No retry storm: requests during backoff reuse the last image")
    check(PortraitService.backoff(1) == 60 && PortraitService.backoff(2) == 120 && PortraitService.backoff(5) == 960 && PortraitService.backoff(40) == 6 * 3600, "Backoff grows exponentially to a six hour cap")
    Task { @MainActor in outcomes.append(await service.request(agent, store: store, origin: .menu, force: true)) }
    spin { outcomes.count == 12 }
    check(calls == 7 && agent.agent?.portrait?.failures == nil && outcomes[11].image?.sourceRevision == 5, "Refresh retries immediately and a success clears the failure")
    // Window demand: subscribed windows request on turns (debounced); closing ends it.
    service.debounceSeconds = 0.05
    service.agentTurned(agent, store: store)
    check(service.pendingDebounces == 0, "Without an open Portraits window, agent turns request nothing")
    let token = UUID()
    service.subscribe(token, store: store)
    spin(0.3) { false }
    check(calls == 7, "Opening the window requests each agent's portrait; unchanged content is a cache hit")
    agent.agent?.recordAssessment(.revision(AgentAssessment(summary: "Recovered.", status: .onTrack, facts: [], revision: 6, contentHash: "sixth", updatedAt: later, checkedAt: later)), now: later)
    service.agentTurned(agent, store: store); service.agentTurned(agent, store: store); service.agentTurned(agent, store: store)
    check(service.pendingDebounces == 1, "Bursts of turns debounce into one pending request")
    spin { calls == 8 }
    check(calls == 8 && agent.agent?.portrait?.latest?.sourceRevision == 6, "While open, a changed assessment regenerates the portrait")
    agent.agent?.portraitMinMinutes = 10
    agent.agent?.recordAssessment(.revision(AgentAssessment(summary: "Again.", status: .atRisk, facts: [], revision: 7, contentHash: "seventh", updatedAt: later, checkedAt: later)), now: later)
    service.agentTurned(agent, store: store)
    spin { service.hasDeferred(agent.id) }
    check(calls == 8 && service.hasDeferred(agent.id), "A rate-limited window demand is deferred until the interval allows it")
    service.unsubscribe(token)
    check(!service.hasDeferred(agent.id) && service.pendingDebounces == 0 && service.subscribers.isEmpty, "Closing the window cancels deferred and debounced demand")
    service.agentTurned(agent, store: store)
    spin(0.3) { false }
    check(calls == 8 && service.pendingDebounces == 0, "After closing, turns generate nothing")
    // Delivery: inline to a requester and caption format.
    let requester = store.create(Entry(name: "Writer", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")); requester.queuePaused = true
    var delivered: PortraitOutcome?
    Task { @MainActor in delivered = await service.request(agent, store: store, origin: .session, reply: .inline(requester)) }
    spin { delivered != nil }
    let inline = requester.messages.last
    check(inline?.role == "notice" && inline?.images.count == 1 && inline?.images.first?.hasPrefix(store.responseImageFolder(requester).path) == true && FileManager.default.fileExists(atPath: inline?.images.first ?? "")
          && inline?.text.hasPrefix("Portrait of KAOS Steward · assessment rev 6") == true && inline?.text.contains(" · stale") == true && inline?.text.contains("#" + String("sixth".prefix(8))) == true,
          "Inline delivery puts the PNG in the requester's managed outputs with a one-line caption (agent, assessment time, short hash, stale flag)")
    check(PortraitService.isRequest("get me a portrait of KAOS Steward") && PortraitService.isRequest("Self-portrait please") && !PortraitService.isRequest("what is the status"), "Portrait requests are recognized in plain language")

    // 7. Switchboard portrait command returns an inline image and a result.
    let shared = PortraitService.shared, sharedGenerator = shared.generator
    shared.generator = { _ in png(.systemTeal) }
    defer { shared.generator = sharedGenerator }
    agent.agent?.portraitMinMinutes = 0; agent.agent?.portrait?.lastAttemptAt = nil
    requester.switchboardEnabled = true; requester.messages = []
    func command(_ text: String) {
        requester.switchboardTurnStart = requester.messages.count
        requester.messages.append(Message(role: "assistant", text: text, finalReply: text))
        store.processSwitchboard(requester)
    }
    command("Here it comes.\n```converse\n{\"command\":\"portrait\",\"agent\":\"kaos steward\"}\n```")
    spin { requester.pending.contains { $0.text.contains("[Converse portrait result") } }
    let result = requester.pending.last?.text ?? ""
    check(requester.messages.contains { $0.role == "notice" && $0.images.count == 1 && $0.text.hasPrefix("Portrait of KAOS Steward") } && result.contains("\"displayed\":true") && result.contains("already shown"),
          "The switchboard portrait command shows the image inline and sends the session its result")
    command("```converse\n{\"command\":\"portrait\",\"agent\":\"Nobody\"}\n```")
    check(requester.messages.last?.text.contains("no single agent is named") == true, "An unknown portrait target explains what to use instead")
    check(store.switchboardTeaching(requester).contains(SwitchboardCommand.portraitTeaching) && SwitchboardCommand.conversationPolicy.contains("\"command\":\"portrait\"") && SwitchboardTeaching.version == 4,
          "Sessions are taught the portrait command (lesson version 4)")

    // 8. Jolly holds a portrait request open until PNG + caption.
    let router = JollyRouter(); let jollyService = PortraitService(); router.portraits = jollyService
    var jollyGate: CheckedContinuation<Void, Never>?
    jollyService.generator = { _ in await withCheckedContinuation { jollyGate = $0 }; return png(.systemPink) }
    var starts = 0
    store.startAgentRun = { _, _ in starts += 1 }
    router.tick(store: store, now: Date())
    let jollyID = String(repeating: "7", count: 64)
    try? JSONEncoder().encode(JollyRequest(id: jollyID, question: "get me a portrait of KAOS Steward", context: "", agent: "", createdAt: Date().timeIntervalSince1970))
        .write(to: JollyRouter.folder(store).appendingPathComponent("requests/" + jollyID + ".json"), options: .atomic)
    agent.agent?.recordAssessment(.revision(AgentAssessment(summary: "Jolly view.", status: .onTrack, facts: [], revision: 8, contentHash: "eighth", updatedAt: later, checkedAt: later)), now: later)
    agent.busy = true // Portraits do not need the agent's turn or queue.
    router.tick(store: store, now: Date())
    spin { jollyGate != nil }
    let responseFile = JollyRouter.folder(store).appendingPathComponent("responses/" + jollyID + ".json")
    router.tick(store: store, now: Date())
    check(router.holding.contains(jollyID) && !FileManager.default.fileExists(atPath: responseFile.path) && starts == 0, "Jolly holds the portrait request open without starting an agent turn")
    jollyGate?.resume()
    spin { FileManager.default.fileExists(atPath: responseFile.path) }
    let jolly = (try? Data(contentsOf: responseFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    let imageID = jolly["imageID"] as? String ?? ""
    check(jolly["status"] as? String == "completed" && jolly["imageKind"] as? String == "portrait" && (jolly["answer"] as? String)?.hasPrefix("Portrait of KAOS Steward · assessment rev 8") == true
          && (jolly["answer"] as? String)?.contains("#eighth") == true && FileManager.default.fileExists(atPath: JollyRouter.folder(store).appendingPathComponent("images/" + imageID + ".png").path)
          && !router.holding.contains(jollyID), "Jolly publishes the PNG with a one-line caption once ready")
    agent.busy = false
    agent.agent?.jollyRequestID = String(repeating: "6", count: 64)
    router.complete(agent, text: "Status in words", success: true, store: store)
    let plain = (try? Data(contentsOf: JollyRouter.folder(store).appendingPathComponent("responses/" + String(repeating: "6", count: 64) + ".json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    check(plain["answer"] as? String == "Status in words" && plain["imageID"] == nil, "Ordinary Jolly answers no longer attach a scoreboard image")
    store.startAgentRun = nil

    // 9. Discord caption.
    let caption = AgentRuntime.discordCaption(PortraitOutcome(agent: "KAOS Steward", image: agent.agent?.portrait?.latest, png: Data([1]), stale: true, cached: true, note: "Refreshes at most every 10 min; showing the latest portrait.",
        error: nil, caption: service.caption(agent: "KAOS Steward", image: agent.agent?.portrait?.latest, stale: true)))
    check(caption.hasPrefix("Portrait of KAOS Steward · assessment rev ") && caption.contains(" · #") && caption.contains(" · stale\n") && caption.hasSuffix("showing the latest portrait."),
          "Discord posts the PNG with the same caption and any refresh note")
}

/// Real agent runtime, fixture transport: every turn assesses, malformed
/// assessments never stop the loop, and no art is generated or attached.
@MainActor func agentAssessmentRuntimeSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-assess-run-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root)
    let agent = store.createAgent(title: "Assessor"); agent.agent?.generateArt = true; agent.agent?.webSearch = false
    agent.agent?.enabled = true; agent.agent?.turnLimit = 5; agent.queuePaused = true
    let runtime = AgentRuntime(); runtime.keyReader = { name in name == "meta" ? "isolated-test-key" : nil }
    var replies: [String] = [], paths: [String] = [], inputs: [String] = []
    runtime.api.request = { request in
        paths.append(request.url?.path ?? "")
        if request.url?.path == "/v1/responses" {
            inputs.append((request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["input"] as? String) ?? "")
            let text = replies.isEmpty ? "{\"reply\":\"\"}" : replies.removeFirst()
            let object: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": text]]]]]
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func turn(_ reply: String, loopTick: Bool = true) {
        replies = [reply]; agent.busy = true
        let id = UUID(); agent.messages.append(Message(id: id, role: "assistant", text: ""))
        runtime.run(agent, store: store, responseID: id, loopTick: loopTick)
        let deadline = Date().addingTimeInterval(8)
        while agent.busy && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    turn("{\"reply\":\"Progress\",\"assessment\":{\"summary\":\"Moving.\",\"status\":\"on-track\",\"facts\":[{\"id\":\"fleet.versions\",\"kind\":\"measured\",\"value\":\"999\"}]}}")
    let evidence = inputs.last.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check((evidence?["measuredFacts"] as? [[String: Any]])?.contains { $0["id"] as? String == "fleet.versions" } == true && evidence?["previousAssessment"] is NSNull,
          "The agent receives host measurements by id with each turn")
    check(agent.agent?.assessment?.revision == 1 && agent.agent?.assessment?.facts.first?.value.contains("999") == false && agent.agent?.lastOutcome == "Completed",
          "A turn stores its assessment with host-owned measured values")
    check(!paths.contains("/v1/images/generations") && agent.messages.allSatisfy { $0.images.isEmpty } && agent.agent?.portrait == nil,
          "Agent turns no longer generate art or attach scoreboard images, even with the retired art flag on")
    turn("{\"reply\":\"\",\"assessment\":{\"summary\":\"moving.\",\"status\":\"on-track\",\"facts\":[{\"id\":\"fleet.versions\",\"kind\":\"measured\"}]}}", loopTick: true)
    check(agent.agent?.assessment?.revision == 1 && agent.agent?.assessment?.heartbeats == 1, "An unchanged scheduled turn heartbeats; every turn assesses regardless of the scoreboard cadence")
    turn("{\"reply\":\"Still working\",\"assessment\":[\"broken\"]}")
    let rejected = root.appendingPathComponent("Agents/" + agent.id.uuidString + "/assessment-rejected.json")
    check(agent.agent?.enabled == true && agent.agent?.lastOutcome == "Completed" && agent.messages.contains { $0.text == "Still working" } && agent.agent?.assessment?.revision == 1
          && agent.agent?.assessmentProblem?.reason == "Assessment was not a JSON object." && (try? String(contentsOf: rejected, encoding: .utf8))?.contains("broken") == true,
          "A malformed assessment is logged raw, keeps the last record stale and never pauses the loop or drops the reply")
    turn("{\"reply\":\"No assessment this time\"}")
    check(agent.agent?.enabled == true && agent.agent?.assessmentProblem?.reason == "No assessment returned this turn." && agent.agent?.transientFailures == nil, "A missing assessment is a stale mark, not a failure")
    ArchiveWriter.shared.flushAll()
    check(Store(folder: root).sessions.first { $0.id == agent.id }?.agent?.assessment?.revision == 1, "Assessments persist with the agent")
}
