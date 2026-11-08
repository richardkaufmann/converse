import Foundation

/// Bounded, opt-in timings. Operation names are closed: no text, paths, titles,
/// session IDs, key characters or provider payloads enter the capture.
final class PerformanceCapture {
    static let shared = PerformanceCapture()
    enum Operation: String, Codable, CaseIterable {
        case mainQueueDelay, keyDelivery, keyHandling, textInsertion, transcriptRender
        case paneArrangement, transcriptMount, transcriptInitialRender, transcriptLayout
        case archiveSnapshot, archiveEncodeWrite, checkedSave, sidebarPublish
        case mouseHover, dragDelivery, dragHandling, dragFrameWait, dragApply, resizeDraw, wrapThaw
        case lotEditHandling, lotEditCommit, lotAckEncodeQueue, lotEditToAckProcessed, lotAckSendFailed
        case lotKeyDelivery, lotKeyHandling, lotTextInsertion, lotScrollDelivery, lotScrollHandling
        case sessionScrollDelivery, sessionScrollHandling
        case lotRoundTrip, lotAckApply, lotLocalEdit, lotTextUpdate, lotTextLayout, lotInputToChange
        // Mac Parking Lot typing substages, nested inside lotKeyHandling/lotTextInsertion.
        case lotSubstitution, lotProjectionEdit, lotRowsCommit, lotValidate, lotNormalize, lotSnapshotCheck
        case lotEncodeWrite, lotUndoRegister, lotPublish, lotSeenWrite, lotRender, lotProjectionBuild
        case lotAttributes, lotStorageApply, lotSelection, lotCommentButtons, lotImageSpacing, lotScrollVisible, lotDraw
        // View → Group: Store capture on main, worker build, page apply round trip.
        case groupMapCapture, groupMapBuild, groupMapApply
    }
    struct Span { let start: Double; let generation: Int; let mainThread: Bool }
    struct Event: Codable {
        let operation: Operation
        let uptime: Double
        let milliseconds: Double
        let mainThread: Bool
    }
    struct Summary: Codable {
        var count = 0
        var totalMilliseconds = 0.0
        var maximumMilliseconds = 0.0
        // <=8, <=16, <=50, <=100, <=250, >250 ms.
        var buckets = [Int](repeating: 0, count: 6)
        mutating func add(_ milliseconds: Double) {
            count += 1; totalMilliseconds += milliseconds
            maximumMilliseconds = max(maximumMilliseconds, milliseconds)
            let index = [8.0, 16, 50, 100, 250].firstIndex { milliseconds <= $0 } ?? 5
            buckets[index] += 1
        }
    }
    struct Snapshot: Codable {
        let schemaVersion: Int
        let startedAt: Date
        let measuredAt: Date
        let version: String
        let build: String
        let historySeconds: Double
        let droppedSamples: Int
        let summaries: [String: Summary]
        let slowEvents: [Event]
        let droppedSlowEvents: Int
        let pendingRoundTrips: Int
        let droppedRoundTrips: Int
        // A lower bound when a queued main-thread probe has not returned by stop.
        let unfinishedMainQueueDelayMilliseconds: Double?
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "local.richard.Converse.performance", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var active = false, pendingProbe = false, dirty = false
    private var generation = 0, ticks = 0, dropped = 0
    private var pendingProbeStart: Double?
    private var startedAt = Date()
    private var events: [Event] = []
    private var eventHead = 0
    private var historySeconds: TimeInterval = 60
    private var droppedSamples: [(uptime: Double, count: Int)] = []
    private var frozen: Snapshot?
    private let uptime: () -> Double
    init(uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.uptime = uptime }
    static func clampedHistory(_ seconds: Double) -> Double { seconds.isFinite ? min(600, max(30, seconds)) : 60 }
    static func recordingDefault(info: [String: Any], environment: [String: String]) -> Bool {
        if let override = environment["CONVERSE_PERFORMANCE_DIAGNOSTICS"] { return override == "1" }
        return info["ConverseDevelopmentBuild"] as? Bool == true || info["ConverseTestProvider"] != nil
    }
    var retainedSeconds: Double { lock.lock(); defer { lock.unlock() }; return historySeconds }
    func setHistory(seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        historySeconds = Self.clampedHistory(seconds)
        if active { prune(now: uptime()); dirty = true }
    }
    // IDs exist only in memory for matching receipts; never export them.
    private var roundTrips: [UUID: Span] = [:]
    private var droppedRoundTrips = 0
    private var destination: URL?
    private let capacity = 50_000
    private let slowCapacity = 512
    var enabled: Bool { lock.lock(); defer { lock.unlock() }; return active }
    var file: URL? { lock.lock(); defer { lock.unlock() }; return destination }

    func configure(folder: URL, enabled: Bool, sampleMainQueue: Bool = true, historySeconds: Double = 60) {
        lock.lock()
        let finalSnapshot = active ? snapshot() : nil
        let previousDestination = destination
        generation += 1
        let token = generation
        active = enabled; pendingProbe = false; pendingProbeStart = nil; dirty = enabled
        startedAt = Date(); events = []; eventHead = 0; dropped = 0; droppedSamples = []; frozen = nil
        self.historySeconds = Self.clampedHistory(historySeconds)
        roundTrips = [:]; droppedRoundTrips = 0
        destination = folder.appendingPathComponent("Performance Diagnostics/performance.json")
        lock.unlock()
        queue.async {
            self.timer?.cancel(); self.timer = nil; self.ticks = 0
            if let finalSnapshot, let previousDestination {
                self.write(finalSnapshot, to: previousDestination)
            }
            guard enabled, sampleMainQueue else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(25))
            timer.setEventHandler { [weak self = self] in self?.tick(generation: token) }
            self.timer = timer; timer.resume()
        }
    }
    func begin() -> Span? {
        lock.lock(); defer { lock.unlock() }
        return active ? Span(start: uptime(), generation: generation, mainThread: Thread.isMainThread) : nil
    }
    func end(_ operation: Operation, _ span: Span?) {
        guard let span else { return }
        record(operation, since: span.start, generation: span.generation, mainThread: span.mainThread)
    }
    @discardableResult func measure<T>(_ operation: Operation, _ body: () throws -> T) rethrows -> T {
        let span = begin(); defer { end(operation, span) }
        return try body()
    }
    func startRoundTrip(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard active, roundTrips[id] == nil else { return }
        guard roundTrips.count < 128 else { droppedRoundTrips += 1; dirty = true; return }
        roundTrips[id] = Span(start: uptime(), generation: generation, mainThread: false)
        dirty = true
    }
    func finishRoundTrip(_ id: UUID) {
        lock.lock(); let span = roundTrips.removeValue(forKey: id); if span != nil { dirty = true }; lock.unlock()
        end(.lotRoundTrip, span)
    }
    func abandonRoundTrip(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if roundTrips.removeValue(forKey: id) != nil { droppedRoundTrips += 1; dirty = true }
    }
    /// Flush asynchronously before offering the timing-only JSON for export.
    func prepareExport(_ completion: @escaping (URL?) -> Void) {
        queue.async {
            self.writeSnapshot()
            self.lock.lock(); let file = self.destination; self.lock.unlock()
            let available = file.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            DispatchQueue.main.async { completion(available) }
        }
    }
    /// Stop at the deadline on the diagnostic worker, even if the UI is stalled.
    /// The completion reflects this exact run's final write, never an older file.
    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        lock.lock()
        guard active, let destination else {
            lock.unlock()
            completion(.failure(NSError(domain: "PerformanceCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No capture is running."])))
            return
        }
        let final = snapshot(); frozen = final
        active = false; generation += 1; dirty = false; pendingProbe = false
        roundTrips = [:]
        lock.unlock()
        queue.async {
            self.timer?.cancel(); self.timer = nil
            do { try self.writeChecked(final, to: destination); completion(.success(destination)) }
            catch { completion(.failure(error)) }
        }
    }
    func delivery(since timestamp: Double, operation: Operation = .keyDelivery) {
        guard timestamp > 0, let span = begin() else { return }
        record(operation, since: timestamp, generation: span.generation, mainThread: true)
    }
    private func record(_ operation: Operation, since start: Double, generation token: Int, mainThread: Bool) {
        let now = uptime()
        record(operation, milliseconds: (now - start) * 1000, uptime: now, generation: token, mainThread: mainThread)
    }
    private func record(_ operation: Operation, milliseconds: Double, uptime: Double, generation token: Int, mainThread: Bool) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard active, token == generation else { return }
        prune(now: uptime)
        if events.count - eventHead >= capacity {
            eventHead += 1
            if let last = droppedSamples.indices.last, Int(droppedSamples[last].uptime) == Int(uptime) {
                droppedSamples[last].count += 1
            } else { droppedSamples.append((uptime, 1)) }
        }
        events.append(Event(operation: operation, uptime: uptime, milliseconds: milliseconds, mainThread: mainThread))
        dirty = true
    }
    private func tick(generation token: Int) {
        lock.lock()
        let shouldProbe = active && generation == token && !pendingProbe
        if shouldProbe { pendingProbe = true; pendingProbeStart = uptime() }
        lock.unlock()
        if shouldProbe {
            let start = uptime()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.record(.mainQueueDelay, since: start, generation: token, mainThread: true)
                self.lock.lock()
                if self.generation == token { self.pendingProbe = false; self.pendingProbeStart = nil }
                self.lock.unlock()
            }
        }
        ticks += 1
        if ticks % 20 == 0 { writeSnapshot() }
    }
    // Amortized deque pruning; recording never shifts the whole buffer per event.
    private func prune(now: Double) {
        let cutoff = now - historySeconds
        while eventHead < events.count && events[eventHead].uptime < cutoff { eventHead += 1 }
        if eventHead > 2048 && eventHead * 2 >= events.count {
            events.removeFirst(eventHead); eventHead = 0
        }
        droppedSamples.removeAll { $0.uptime < cutoff }
        roundTrips = roundTrips.filter { $0.value.start >= cutoff }
    }
    private func snapshot() -> Snapshot {
        if !active, let frozen { return frozen }
        let now = uptime()
        prune(now: now)
        return Snapshot(schemaVersion: 3, startedAt: max(startedAt, Date().addingTimeInterval(-historySeconds)), measuredAt: Date(),
                 version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                 build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                 historySeconds: historySeconds, droppedSamples: droppedSamples.reduce(0) { $0 + $1.count },
                 summaries: [:], slowEvents: Array(events.dropFirst(eventHead)), droppedSlowEvents: 0,
                 pendingRoundTrips: roundTrips.count, droppedRoundTrips: droppedRoundTrips,
                 unfinishedMainQueueDelayMilliseconds: pendingProbeStart.map { max(0, (now - $0) * 1000) })
    }
    /// Runs on the diagnostic queue. Never makes the UI wait on disk I/O.
    private func writeSnapshot() {
        lock.lock()
        guard active, let destination else { lock.unlock(); return }
        let value = snapshot(); dirty = false
        lock.unlock()
        write(value, to: destination)
    }
    private func write(_ value: Snapshot, to destination: URL) {
        try? writeChecked(value, to: destination)
    }
    private func writeChecked(_ raw: Snapshot, to destination: URL) throws {
        // Summarize on the diagnostics worker, outside the recording lock.
        var summaries: [String: Summary] = [:]
        var slow: [Event] = []
        for event in raw.slowEvents {
            summaries[event.operation.rawValue, default: Summary()].add(event.milliseconds)
            if event.milliseconds >= 50 { slow.append(event) }
        }
        let value = Snapshot(schemaVersion: raw.schemaVersion, startedAt: raw.startedAt, measuredAt: raw.measuredAt,
            version: raw.version, build: raw.build, historySeconds: raw.historySeconds, droppedSamples: raw.droppedSamples,
            summaries: summaries, slowEvents: Array(slow.suffix(slowCapacity)), droppedSlowEvents: max(0, slow.count - slowCapacity),
            pendingRoundTrips: raw.pendingRoundTrips, droppedRoundTrips: raw.droppedRoundTrips,
            unfinishedMainQueueDelayMilliseconds: raw.unfinishedMainQueueDelayMilliseconds)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    // Deterministic tests use the same accumulator and writer without timers.
    func recordForTesting(_ operation: Operation, milliseconds: Double) {
        guard let span = begin() else { return }
        record(operation, milliseconds: milliseconds, uptime: span.start, generation: span.generation, mainThread: span.mainThread)
    }
    func flushForTesting() { queue.sync { writeSnapshot() } }
    /// Retained events, for in-process profiles that need medians.
    func eventsForTesting() -> [Event] { lock.lock(); defer { lock.unlock() }; return Array(events.dropFirst(eventHead)) }
}

func performanceCaptureSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-performance-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = PerformanceCapture()
    capture.configure(folder: root, enabled: false, sampleMainQueue: false)
    capture.recordForTesting(.transcriptRender, milliseconds: 200); capture.flushForTesting()
    check(!FileManager.default.fileExists(atPath: capture.file!.path), "Disabled performance capture writes no diagnostic data")
    capture.configure(folder: root, enabled: true, sampleMainQueue: false)
    capture.recordForTesting(.textInsertion, milliseconds: 2)
    capture.recordForTesting(.textInsertion, milliseconds: -1)
    capture.recordForTesting(.textInsertion, milliseconds: .nan)
    for _ in 0..<600 { capture.recordForTesting(.transcriptRender, milliseconds: 75) }
    capture.flushForTesting()
    do {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(PerformanceCapture.Snapshot.self, from: Data(contentsOf: capture.file!))
        check(snapshot.slowEvents.count == 512 && snapshot.droppedSlowEvents == 88, "Performance events stay bounded while preserving dropped-event count")
        check(snapshot.summaries["transcriptRender"]?.count == 600 && snapshot.summaries["transcriptRender"]?.buckets[3] == 600 && snapshot.summaries["textInsertion"]?.count == 1, "Performance summaries retain all valid timings, including fast operations")
        let stale = capture.begin()
        capture.configure(folder: root, enabled: true, sampleMainQueue: false)
        capture.end(.checkedSave, stale); capture.flushForTesting()
        let reset = try decoder.decode(PerformanceCapture.Snapshot.self, from: Data(contentsOf: capture.file!))
        check(reset.summaries.isEmpty, "An old capture span cannot contaminate a newly started capture")
        let requests = (0..<130).map { _ in UUID() }
        requests.forEach(capture.startRoundTrip)
        capture.startRoundTrip(requests[0]) // A retry must not reset its clock.
        capture.finishRoundTrip(UUID()) // An unrelated receipt completes nothing.
        capture.finishRoundTrip(requests[0]); capture.finishRoundTrip(requests[0])
        capture.abandonRoundTrip(requests[1]); capture.flushForTesting()
        let roundTripData = try Data(contentsOf: capture.file!)
        let trips = try decoder.decode(PerformanceCapture.Snapshot.self, from: roundTripData)
        check(trips.summaries["lotRoundTrip"]?.count == 1 && trips.pendingRoundTrips == 126 && trips.droppedRoundTrips == 3,
              "Round-trip timings match each receipt once, stay bounded and disclose unfinished or dropped requests")
        let json = String(decoding: roundTripData, as: UTF8.self)
        check(!requests.contains { json.contains($0.uuidString) }, "Round-trip matching IDs never enter exported timings")
        capture.configure(folder: root, enabled: true, sampleMainQueue: false)
        capture.finishRoundTrip(requests[2]); capture.flushForTesting()
        let restarted = try decoder.decode(PerformanceCapture.Snapshot.self, from: Data(contentsOf: capture.file!))
        check(restarted.pendingRoundTrips == 0 && restarted.summaries["lotRoundTrip"] == nil,
              "A receipt from an earlier capture cannot contaminate the next capture")
    } catch { check(false, "Performance capture fixture: " + error.localizedDescription) }
    var clock = 1000.0
    let rolling = PerformanceCapture(uptime: { clock })
    rolling.configure(folder: root, enabled: true, sampleMainQueue: false, historySeconds: 60)
    rolling.recordForTesting(.keyDelivery, milliseconds: 200)
    clock += 59
    rolling.recordForTesting(.keyDelivery, milliseconds: 3)
    clock += 2
    rolling.flushForTesting()
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    func readRolling() -> PerformanceCapture.Snapshot? {
        (try? Data(contentsOf: rolling.file!)).flatMap { try? decoder.decode(PerformanceCapture.Snapshot.self, from: $0) }
    }
    check(readRolling()?.summaries["keyDelivery"]?.count == 1 && readRolling()?.summaries["keyDelivery"]?.maximumMilliseconds == 3 && readRolling()?.slowEvents.isEmpty == true,
          "Rolling history expires old slow events and their summary maxima while retaining newer fast samples")
    rolling.setHistory(seconds: 30)
    clock += 31; rolling.flushForTesting()
    check(readRolling()?.summaries.isEmpty == true && readRolling()?.historySeconds == 30,
          "Shrinking the window and idle time expire summary samples")
    rolling.setHistory(seconds: 600)
    rolling.recordForTesting(.keyHandling, milliseconds: 71)
    let done = DispatchSemaphore(value: 0)
    rolling.finish { _ in done.signal() }
    check(done.wait(timeout: .now() + 3) == .success, "Pause writes its frozen buffer")
    let paused = try? Data(contentsOf: rolling.file!)
    clock += 1000; rolling.recordForTesting(.keyHandling, milliseconds: 90); rolling.flushForTesting()
    check(paused != nil && paused == (try? Data(contentsOf: rolling.file!)), "Paused buffer remains byte-identical after time advances and new events arrive")
    check(PerformanceCapture.clampedHistory(1) == 30 && PerformanceCapture.clampedHistory(900) == 600 && PerformanceCapture.clampedHistory(.nan) == 60,
          "History duration clamps to 30–600 seconds with a 60-second default")
    check(!PerformanceCapture.recordingDefault(info: [:], environment: [:]) &&
          PerformanceCapture.recordingDefault(info: ["ConverseTestProvider": "Codex"], environment: [:]) &&
          !PerformanceCapture.recordingDefault(info: ["ConverseTestProvider": "Codex"], environment: ["CONVERSE_PERFORMANCE_DIAGNOSTICS": "0"]),
          "Public builds default off, TEST builds default on, and explicit environment off wins")
    rolling.configure(folder: root, enabled: true, sampleMainQueue: false)
    for _ in 0..<50_010 { rolling.recordForTesting(.textInsertion, milliseconds: 1) }
    rolling.flushForTesting()
    check(readRolling()?.summaries["textInsertion"]?.count == 50_000 && readRolling()?.droppedSamples == 10,
          "Exceptional event floods remain memory-bounded and disclose incomplete summaries")
    // Exercise the real scheduler while deliberately withholding the main run loop.
    let timed = PerformanceCapture()
    let run = PerformanceCaptureRun(capture: timed)
    var finished: URL?
    run.start(folder: root, delay: 0.05, duration: 0.15) {
        if case .complete(let file) = $0 { finished = file }
    }
    let startDeadline = Date().addingTimeInterval(2)
    while !timed.enabled && Date() < startDeadline { Thread.sleep(forTimeInterval: 0.005) }
    check(timed.enabled, "Delayed diagnostic run starts without main-thread callbacks")
    timed.recordForTesting(.lotKeyHandling, milliseconds: 75)
    let stopDeadline = Date().addingTimeInterval(2)
    while timed.enabled && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.005) }
    check(!timed.enabled, "Capture deadline stops recording even while the main thread is blocked")
    let resultDeadline = Date().addingTimeInterval(2)
    while finished == nil && Date() < resultDeadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    if let finished, let data = try? Data(contentsOf: finished) {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result = try? decoder.decode(PerformanceCapture.Snapshot.self, from: data)
        check(result?.summaries["lotKeyHandling"]?.count == 1, "Completed export contains this run's final lot timing")
        check((result?.unfinishedMainQueueDelayMilliseconds ?? 0) > 0, "A probe still blocked at the deadline is disclosed as an unfinished delay")
    } else { check(false, "Completed export contains this run's final lot timing") }
    var cancelled = false, unexpectedRecording = false
    run.start(folder: root, delay: 0.15, duration: 0.05) {
        if case .recording = $0 { unexpectedRecording = true }
    }
    run.cancel(folder: root) { if case .cancelled = $0 { cancelled = true } }
    let cancelDeadline = Date().addingTimeInterval(0.3)
    while Date() < cancelDeadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    check(cancelled && !unexpectedRecording && !timed.enabled, "Cancelling a delayed capture prevents recording and completion")
    var oldCompleted = false, replacementFinished: URL?
    run.start(folder: root, delay: 0, duration: 0.1) {
        if case .complete = $0 { oldCompleted = true }
    }
    let activeDeadline = Date().addingTimeInterval(2)
    while !timed.enabled && Date() < activeDeadline { Thread.sleep(forTimeInterval: 0.005) }
    check(timed.enabled, "Cancellation replacement fixture reaches active recording")
    timed.recordForTesting(.lotKeyHandling, milliseconds: 81)
    run.cancel(folder: root) { _ in }
    run.start(folder: root, delay: 0.15, duration: 0.1) {
        if case .complete(let file) = $0 { replacementFinished = file }
    }
    let replacementDeadline = Date().addingTimeInterval(3)
    while replacementFinished == nil && Date() < replacementDeadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    if let replacementFinished, let data = try? Data(contentsOf: replacementFinished) {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result = try? decoder.decode(PerformanceCapture.Snapshot.self, from: data)
        check(!oldCompleted && result != nil && result?.summaries["lotKeyHandling"] == nil,
              "Cancelling active capture preserves the replacement deadline and excludes old samples and completion")
    } else { check(false, "Cancelling active capture preserves the replacement deadline and excludes old samples and completion") }
    let badRoot = root.appendingPathComponent("not-a-directory")
    try? Data([1]).write(to: badRoot)
    var reportedFailure = false, exportedFailure = false
    run.start(folder: badRoot, delay: 0, duration: 0.02) {
        if case .failed = $0 { reportedFailure = true }
        if case .complete = $0 { exportedFailure = true }
    }
    let failureDeadline = Date().addingTimeInterval(2)
    while !reportedFailure && Date() < failureDeadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    check(reportedFailure && !exportedFailure, "Failed final write cannot enable export or reuse a previous capture")

}

/// Owns delayed, bounded runs independently of the Settings window's lifetime.
/// No UI timer or animation is needed while measuring UI responsiveness.
final class PerformanceCaptureRun {
    enum State {
        case waiting, recording, complete(URL), failed(String), cancelled
    }
    private let queue = DispatchQueue(label: "local.richard.Converse.performance-run", qos: .utility)
    private let capture: PerformanceCapture
    private var generation = 0
    init(capture: PerformanceCapture = .shared) { self.capture = capture }
    func start(folder: URL, delay: TimeInterval, duration: TimeInterval,
               update: @escaping (State) -> Void) {
        queue.async {
            self.generation += 1
            let token = self.generation
            self.capture.configure(folder: folder, enabled: false)
            let runFolder = folder.appendingPathComponent("Performance Diagnostics/Runs/" + UUID().uuidString)
            func publish(_ state: State) { DispatchQueue.main.async { update(state) } }
            guard delay.isFinite, duration.isFinite, delay >= 0, duration > 0, delay <= 60, duration <= 300 else {
                publish(.failed("Choose a delay from 0–60 seconds and a duration up to 300 seconds.")); return
            }
            publish(.waiting)
            self.queue.asyncAfter(deadline: .now() + delay) {
                guard token == self.generation else { return }
                self.capture.configure(folder: runFolder, enabled: true)
                publish(.recording)
                self.queue.asyncAfter(deadline: .now() + duration) {
                    guard token == self.generation else { return }
                    self.capture.finish { result in
                        self.queue.async {
                            guard token == self.generation else { return }
                            switch result {
                            case .success(let file): publish(.complete(file))
                            case .failure(let error): publish(.failed("Could not save the capture: " + error.localizedDescription))
                            }
                        }
                    }
                }
            }
        }
    }
    func cancel(folder: URL, update: @escaping (State) -> Void) {
        queue.async {
            self.generation += 1
            self.capture.configure(folder: folder, enabled: false)
            DispatchQueue.main.async { update(.cancelled) }
        }
    }
}
