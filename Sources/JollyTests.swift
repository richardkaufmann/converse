import AppKit
import Foundation

@MainActor func jollySelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-jolly-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root)
    let first = store.createAgent(); first.title = "Stock"; first.agent?.generateArt = false
    let second = store.createAgent(); second.title = "Project"
    let router = JollyRouter()
    let now = Date()
    func request(_ digit: String, agent: String = "", question: String = "Report status") -> JollyRequest {
        JollyRequest(id: String(repeating: digit, count: 64), question: question, context: "", agent: agent, createdAt: now.timeIntervalSince1970)
    }
    let support = store.createAgent(title: AppSupport.title); support.supportAssistant = true
    check(JollyRouter.resolve(request("f", agent: "converse", question: "Which hosts are in the group?"), sessions: [first, support]) === support && JollyRouter.resolve(request("f", question: "ask converse if the app is up, what group is it in, which hosts are in the group"), sessions: [first, support]) === support, "Jolly routes general app health to the explicitly identified App Support agent")
    check(JollyRouter.resolve(request("f", agent: "Unknown", question: "is Converse up?"), sessions: [support]) == nil, "Explicit unknown targets never fall through to App Support")
    support.agent?.jollyAllowed = false
    check(JollyRouter.resolve(request("f", agent: "converse"), sessions: [support]) == nil, "App health alias respects revoked Jolly access")
    store.sessions.removeAll { $0 === support }
    check(JollyRouter.resolve(request("a"), sessions: [first, second]) == nil, "Jolly never guesses or broadcasts an ambiguous destination")
    check(JollyRouter.resolve(request("b", agent: "sToCk"), sessions: [first, second]) === first &&
          JollyRouter.resolve(request("c", question: "Stock: current price?"), sessions: [first, second]) === first, "Jolly routes by exact case-insensitive name or explicit name prefix")
    check(JollyRouter.resolve(request("d", agent: "Unknown"), sessions: [first]) == nil, "An explicit unknown Jolly target never falls back to the only agent")
    second.title = "Stock"
    check(JollyRouter.resolve(request("e", agent: "Stock"), sessions: [first, second]) == nil, "Duplicate agent names require an ID")
    second.title = "Project"; second.agent?.jollyAllowed = false
    check(JollyRouter.eligible(store).map(\.id) == [first.id], "Jolly directory excludes agents disabled by the user")
    router.tick(store: store, now: now)
    func enqueue(_ req: JollyRequest) {
        try! JSONEncoder().encode(req).write(to: JollyRouter.folder(store).appendingPathComponent("requests/" + req.id + ".json"), options: .atomic)
    }
    func result(_ id: String) -> [String: Any] {
        let file = JollyRouter.folder(store).appendingPathComponent("responses/" + id + ".json")
        return (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    var starts = 0, draftPersistedAtStart = false
    store.startAgentRun = { session, _ in
        starts += 1; try! store.saveChecked()
        let saved = Store(folder: root).sessions.first { $0.id == session.id }
        draftPersistedAtStart = saved?.draft == "keep my typing" && saved?.attachments == ["keep-image"]
    }
    first.draft = "keep my typing"; first.attachments = ["keep-image"]
    let req = request("a", agent: first.id.uuidString)
    enqueue(req); router.tick(store: store, now: now)
    check(starts == 1 && first.agent?.turnLimit == 20 && first.agent?.jollyRequestID == req.id && first.draft == "keep my typing" && first.attachments == ["keep-image"], "Jolly reserves and persists one turn before starting while preserving the human draft")
    check(draftPersistedAtStart, "Jolly preserves the human draft in every save before the model starts, including a crash during handoff")
    router.tick(store: store, now: now)
    check(starts == 1, "Repeated polling cannot start a second copy of an active Jolly request")
    first.busy = false
    router.complete(first, text: "A correlated answer", success: true, store: store)
    router.tick(store: store, now: now)
    check(result(req.id)["answer"] as? String == "A correlated answer" && starts == 1 && first.agent?.jollyRequestID == nil, "Jolly persists a correlated reply and never replays its completed request")
    first.queuePaused = true
    let held = request("b"); enqueue(held); router.tick(store: store, now: now)
    check(result(held.id)["status"] as? String == "busy" && starts == 1 && first.agent?.turnLimit == 20, "Paused queues refuse Jolly without injection or budget consumption")
    first.queuePaused = false; first.agent?.turnLimit = 0
    let exhausted = request("c"); enqueue(exhausted); router.tick(store: store, now: now)
    check(result(exhausted.id)["status"] as? String == "budget_exhausted" && starts == 1, "Jolly cannot bypass the agent turn budget")
    first.agent?.jollyRequestID = String(repeating: "d", count: 64)
    try! store.saveChecked()
    let restartedStore = Store(folder: root)
    JollyRouter().tick(store: restartedStore, now: now)
    check(result(String(repeating: "d", count: 64))["status"] as? String == "failed" && (result(String(repeating: "d", count: 64))["answer"] as? String)?.contains("uncertain") == true, "Restart marks interrupted Jolly work uncertain without automatic execution")
    first.agent?.jollyRequestID = req.id
    try! store.saveChecked()
    let afterPublication = Store(folder: root)
    JollyRouter().tick(store: afterPublication, now: now)
    check(result(req.id)["answer"] as? String == "A correlated answer" && afterPublication.sessions.first(where: { $0.id == first.id })?.agent?.jollyRequestID == nil, "Restart after reply publication preserves the completed answer instead of replacing it with uncertainty")
    try! JollyRouter.send("Explicit message", store: store)
    let outbox = try! FileManager.default.contentsOfDirectory(atPath: JollyRouter.folder(store).appendingPathComponent("outbox").path)
    check(outbox.count == 1, "Explicit Jolly send persists one message in the Converse-owned outbox")
    jollyMisrouteTests(check)
    router.stop(store: store)
    let directory = try! JSONSerialization.jsonObject(with: Data(contentsOf: JollyRouter.folder(store).appendingPathComponent("directory.json"))) as! [String: Any]
    check(directory["available"] as? Bool == false, "App exit explicitly withdraws Jolly agent availability")
}

@MainActor func jollyMisrouteTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-jolly-route-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(folder: root)
    func agent(_ title: String) -> Session { let s = store.createAgent(); s.title = title; s.agent?.generateArt = false; return s }
    let steward = agent("Converse Steward"), news = agent("News Checker"), kaos = agent("KAOS Steward")
    let support = store.createAgent(title: AppSupport.title); support.supportAssistant = true
    let sessions = [steward, news, support, kaos]
    let kaosLot = ParkingLotLibrary.Record(id: UUID(), name: "KAOS"), plain = ParkingLotLibrary.Record(id: UUID(), name: "Parking Lot")
    let garden = ParkingLotLibrary.Record(id: UUID(), name: "Garden Parking Lot")
    let lots = [kaosLot, plain, garden]
    let now = Date()
    func ask(_ question: String, _ digit: String = "1", agent: String = "Converse Steward") -> JollyRequest {
        JollyRequest(id: String(repeating: digit, count: 64), question: question, context: "", agent: agent, createdAt: now.timeIntervalSince1970)
    }
    func bounce(_ question: String, to target: Session? = nil) -> Session? {
        JollyRouter.misroute(ask(question), target: target ?? steward, sessions: sessions, lots: lots, home: nil)?.agent
    }
    let first = "Please talk to the KAOS Steward and ask it to get a summary of its parking lot, and report back that summary."
    let second = "Please summarize the KAOS Parking Lot"
    check(bounce(first) === kaos && bounce(second) === kaos, "Jolly bounces both recorded KAOS requests addressed to Converse Steward")
    check(bounce("What new features were added to Converse in the last week?") == nil && bounce("What is our security posture?") == nil, "Generic Converse questions still reach the addressed agent")
    check(JollyRouter.agentsNamed("ask the kaos steward, please", sessions: sessions).map(\.id) == [kaos.id], "Full agent titles match case-insensitively on word boundaries")
    check(JollyRouter.agentsNamed("How is kaos doing?", sessions: sessions).map(\.id) == [kaos.id] && JollyRouter.agentsNamed("Anything from the checker?", sessions: sessions).map(\.id) == [news.id], "Distinctive title words name their agent")
    check(JollyRouter.agentsNamed("steward converse chaos newsy", sessions: sessions).isEmpty && JollyRouter.agentsNamed("Does the app support this?", sessions: sessions).isEmpty, "Shared, partial and App Support words never name an agent")
    let short = agent("Steward")
    check(JollyRouter.agentsNamed("Ask KAOS Steward", sessions: [short, kaos]).map(\.id) == [kaos.id], "A longer title is not also read as a shorter agent's title")
    store.sessions.removeAll { $0 === short }
    check(bounce("Ask Converse Steward whether KAOS Steward is behind") == nil, "Naming the addressed agent always reaches it")
    check(bounce("Compare the KAOS Steward and News Checker reports") == nil, "A question naming two other agents is not guessed; the addressed agent judges it")
    check(bounce("Ask KAOS Steward if Converse is up", to: support) == nil, "App Support keeps its existing routing")
    check(bounce("Summarize the Parking Lot") == nil, "A lot nobody can read passes through so the agent can say it lacks access")
    check(JollyRouter.lotsNamed("Summarize the KAOS Parking Lot", lots: lots).map(\.id) == [kaosLot.id] && JollyRouter.lotsNamed("the kaos lot and the garden parking lot", lots: lots).map(\.id) == [kaosLot.id, garden.id] && JollyRouter.lotsNamed("kaos parking", lots: lots).isEmpty, "Lots match by full name; a longer lot name is not also read as Parking Lot")
    news.agent?.watchedSessions = [garden.id]
    check(bounce("Summarize the Garden Parking Lot") === news, "A lot only another agent can read suggests that agent")
    check(JollyRouter.misroute(ask("Summarize the Garden Parking Lot"), target: steward, sessions: sessions, lots: lots, home: nil)?.text.contains("names the Garden Parking Lot, which Converse Steward cannot access; News Checker can.") == true, "The lot bounce explains which agent can read it")
    steward.agent?.watchedSessions = [garden.id]
    check(bounce("Summarize the Garden Parking Lot") == nil, "A lot the addressed agent can read reaches it")
    steward.agent?.watchedSessions = []; kaos.agent?.watchedSessions = [garden.id]
    check(bounce("Summarize the Garden Parking Lot") == nil, "Several agents with lot access are not guessed")
    kaos.agent?.watchedSessions = []
    let router = JollyRouter()
    var starts = 0
    store.startAgentRun = { _, _ in starts += 1 }
    router.tick(store: store, now: now, lots: lots)
    let id = ask(first, "2").id, explicit = ask(second, "3", agent: steward.id.uuidString)
    for request in [ask(first, "2"), explicit] {
        try! JSONEncoder().encode(request).write(to: JollyRouter.folder(store).appendingPathComponent("requests/" + request.id + ".json"), options: .atomic)
    }
    router.tick(store: store, now: now, lots: lots)
    func result(_ id: String) -> [String: Any] {
        (try? Data(contentsOf: JollyRouter.folder(store).appendingPathComponent("responses/" + id + ".json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    let reply = result(id)
    check(reply["status"] as? String == "misrouted" && (reply["suggestedAgent"] as? [String: Any])?["id"] as? String == kaos.id.uuidString &&
          (reply["answer"] as? String)?.contains("names KAOS Steward but was addressed to Converse Steward. Nothing was sent. Resend with agent=\"KAOS Steward\" (id " + kaos.id.uuidString + ")") == true,
          "A misrouted Jolly request is answered with the agent to use")
    check(result(explicit.id)["status"] as? String == "misrouted" && starts == 0 && steward.agent?.jollyRequestID == nil && steward.pending.isEmpty, "Misrouted requests, including by agent ID, inject nothing and start no turn")
    let good = ask("What is our security posture?", "4")
    try! JSONEncoder().encode(good).write(to: JollyRouter.folder(store).appendingPathComponent("requests/" + good.id + ".json"), options: .atomic)
    router.tick(store: store, now: now, lots: lots)
    check(starts == 1 && steward.agent?.jollyRequestID == good.id, "A request meant for the addressed agent still starts it")
    router.stop(store: store)
}
