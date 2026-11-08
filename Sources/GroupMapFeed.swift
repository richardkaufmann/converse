import Foundation
import Combine

/// At most one build per minimumInterval, and never two at once: the next one
/// waits for the page to finish applying the last, so a slow page cannot queue.
final class GroupMapCoalescer {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    private let minimumInterval: TimeInterval
    private let now: () -> Date
    private let schedule: Schedule
    private let action: () -> Void
    private var dirty = false, scheduled = false, busy = false, generation = 0
    private var lastRun: Date?
    init(minimumInterval: TimeInterval, now: @escaping () -> Date, schedule: @escaping Schedule, action: @escaping () -> Void) {
        self.minimumInterval = minimumInterval; self.now = now; self.schedule = schedule; self.action = action
    }
    func mark() { dirty = true; arm() }
    func finished() { busy = false; if dirty { arm() } }
    func stop() { generation += 1; dirty = false; scheduled = false; busy = false }
    private func arm() {
        guard !scheduled, !busy else { return }
        scheduled = true
        let token = generation, wait = lastRun.map { max(0, minimumInterval - now().timeIntervalSince($0)) } ?? 0
        schedule(wait) { [weak self] in
            guard let self, token == self.generation else { return }
            self.scheduled = false
            guard self.dirty else { return }
            self.dirty = false; self.busy = true; self.lastRun = self.now()
            self.action()
        }
    }
}

/// Watches only the published fields that change a map, so transcript streaming
/// costs nothing here. stop() removes every observer; nothing runs while the
/// window is closed or hidden.
final class GroupMapFeed {
    typealias Run = (@escaping () -> Void) -> Void
    private static let tellRetention: TimeInterval = 1800
    private static let maximumTells = 128
    // Queue-watch evidence older than this is treated as absent, as the supervisor does.
    private static let remoteEvidenceSeconds: TimeInterval = 15

    private let store: Store
    private let service: DeviceSyncService
    private let now: () -> Date
    private let worker: Run
    private let main: Run
    private let heartbeatSeconds: TimeInterval?
    private let performance: PerformanceCapture
    private let emit: (Data, @escaping () -> Void) -> Void
    private let builder = GroupMapBuilder()
    private var coalescer: GroupMapCoalescer!
    private var shared: Set<AnyCancellable> = []
    private var perSession: [UUID: Set<AnyCancellable>] = [:]
    private var heartbeat: Timer?
    private var tells: [UUID: GroupMapTellRecord] = [:]
    private var generation = 0
    private var wantsFull = true
    private(set) var isRunning = false
    var observerCount: Int { shared.count + perSession.values.reduce(0) { $0 + $1.count } }

    init(store: Store, service: DeviceSyncService, minimumInterval: TimeInterval = 0.25, heartbeatSeconds: TimeInterval? = 5,
         now: @escaping () -> Date = Date.init, schedule: GroupMapCoalescer.Schedule? = nil, worker: Run? = nil, main: Run? = nil, performance: PerformanceCapture = .shared,
         emit: @escaping (Data, @escaping () -> Void) -> Void) {
        self.store = store; self.service = service; self.now = now; self.heartbeatSeconds = heartbeatSeconds; self.performance = performance; self.emit = emit
        let queue = DispatchQueue(label: "local.richard.Converse.groupmap", qos: .utility)
        self.worker = worker ?? { queue.async(execute: $0) }
        self.main = main ?? { DispatchQueue.main.async(execute: $0) }
        let schedule = schedule ?? { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        coalescer = GroupMapCoalescer(minimumInterval: minimumInterval, now: now, schedule: schedule) { [weak self] in self?.perform() }
    }
    func start() {
        guard !isRunning else { return }
        isRunning = true; wantsFull = true
        store.$sessions.sink { [weak self] in self?.observe($0); self?.coalescer.mark() }.store(in: &shared)
        service.$homes.sink { [weak self] _ in self?.coalescer.mark() }.store(in: &shared)
        service.$trusted.sink { [weak self] _ in self?.coalescer.mark() }.store(in: &shared)
        service.$currentGroup.sink { [weak self] _ in self?.coalescer.mark() }.store(in: &shared)
        service.groupMapTellObserver = { [weak self] in self?.receive($0) }
        if let heartbeatSeconds {
            // Remote evidence expires without any event, so it needs a slow clock.
            let timer = Timer(timeInterval: heartbeatSeconds, repeats: true) { [weak self] _ in self?.coalescer.mark() }
            RunLoop.main.add(timer, forMode: .common); heartbeat = timer
        }
        coalescer.mark()
    }
    func stop() {
        guard isRunning else { return }
        isRunning = false; generation += 1
        coalescer.stop(); heartbeat?.invalidate(); heartbeat = nil
        shared.removeAll(); perSession.removeAll()
        service.groupMapTellObserver = nil
    }
    private func observe(_ sessions: [Session]) {
        let current = Set(sessions.map(\.id))
        for id in perSession.keys where !current.contains(id) { perSession.removeValue(forKey: id) }
        for session in sessions where perSession[session.id] == nil {
            var set: Set<AnyCancellable> = []
            func watch<T: Publisher>(_ publisher: T) where T.Failure == Never {
                publisher.sink { [weak self] _ in self?.coalescer.mark() }.store(in: &set)
            }
            watch(session.$pending); watch(session.$switchboardObligations); watch(session.$switchboardEnabled)
            watch(session.$switchboardTeachingVersion); watch(session.$queuePaused); watch(session.$busy)
            watch(session.$title); watch(session.$agent); watch(session.$entry)
            perSession[session.id] = set
        }
    }
    private func receive(_ event: SwitchboardTellEvent) {
        let at = now()
        if event.phase == .sent, let source = event.source, let target = event.target {
            tells[event.id] = GroupMapTellRecord(id: event.id, phase: .sent, source: source, target: target, kind: event.kind ?? .tell, at: at)
        } else { tells[event.id]?.phase = event.phase }
        tells = tells.filter { at.timeIntervalSince($0.value.at) <= Self.tellRetention }
        if tells.count > Self.maximumTells {
            for record in tells.values.sorted(by: { $0.at < $1.at }).prefix(tells.count - Self.maximumTells) { tells.removeValue(forKey: record.id) }
        }
        coalescer.mark()
    }
    func capture() -> GroupMapInput {
        let span = performance.begin()
        defer { performance.end(.groupMapCapture, span) }
        let at = now(), localID = service.localDeviceID, group = service.currentGroup
        let sessions = store.sessions.map { session -> GroupMapInput.LocalSession in
            // Only prompt IDs are read; prompt text never leaves the Store.
            let hasQueued = session.switchboardObligations.contains { $0.state == "queued" }
            let queuedIDs = hasQueued ? Set(session.pending.flatMap { [$0.id] + ($0.components ?? []).map(\.id) }) : []
            return GroupMapInput.LocalSession(id: session.id, title: session.title, assistant: session.entry.name, busy: session.busy,
                queued: session.pending.count, queuePaused: session.queuePaused, switchboardEnabled: session.switchboardEnabled,
                taught: session.switchboardTeachingVersion != nil || session.isAgentSession, agent: session.agent,
                obligations: session.switchboardObligations, expectations: session.switchboardExpectations, queuedPromptIDs: queuedIDs)
        }
        var homes = service.participantHomes.map { home in
            GroupMapInput.RemoteHome(deviceID: home.deviceID, name: service.displayName(for: home.deviceID, fallback: home.deviceName), online: home.online, reachable: service.participantOnline(home.deviceID),
                rows: home.rows.filter { $0.engine != "parking" }.map {
                    GroupMapInput.RemoteRow(globalID: $0.globalID, title: $0.title, assistant: $0.assistant, isAgent: $0.participantKind == "agent", busy: $0.busy, queued: $0.queued, queuePaused: $0.queuePaused, messagingEnabled: $0.messagingEnabled == true)
                })
        }
        if let group {
            let known = Set(homes.map(\.deviceID) + [localID ?? ""])
            for device in service.trusted where device.groupID == group.id && !known.contains(device.deviceID) {
                homes.append(GroupMapInput.RemoteHome(deviceID: device.deviceID, name: service.displayName(for: device.deviceID), online: false, reachable: false, rows: []))
            }
        }
        let remoteQueued = service.switchboardQueueReports.values.filter {
            at.timeIntervalSince($0.at) >= 0 && at.timeIntervalSince($0.at) <= Self.remoteEvidenceSeconds
        }.flatMap { $0.report.entries.map(\.delivery) }
        return GroupMapInput(localDeviceID: localID, localDeviceName: localID.map { service.displayName(for: $0) } ?? "This Mac", groupName: group?.name,
            sessions: sessions, homes: homes, pendingTellIDs: service.groupMapPendingTellIDs, remoteQueuedIDs: Set(remoteQueued), tells: Array(tells.values), now: at)
    }
    private func perform() {
        let input = capture(), token = generation, full = wantsFull
        wantsFull = false
        worker { [weak self, builder, performance] in
            let span = performance.begin()
            if full { builder.forgetPrevious() }
            let data = builder.build(input).flatMap(GroupMapModel.encode)
            performance.end(.groupMapBuild, span)
            self?.main { [weak self] in
                guard let self, token == self.generation else { return }
                guard let data else { self.coalescer.finished(); return }
                self.emit(data) { [weak self] in
                    guard let self, token == self.generation else { return }
                    self.coalescer.finished()
                }
            }
        }
    }
}
