import CryptoKit
import Foundation
import Network

struct DiscoveredDevice: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var endpoint: NWEndpoint
    static func == (a: DiscoveredDevice, b: DiscoveredDevice) -> Bool { a.name == b.name }
}

struct PairingPrompt: Identifiable {
    var id: UUID { connectionID }
    var connectionID: UUID
    var peerName: String
    var fingerprint: String
    var code: String
    var keyChanged: Bool
    var nameCollision: Bool = false
    var isInitiator: Bool = true
    var actionLabel: String { isInitiator ? "Pair" : "Approve" }
    var instruction: String {
        isInitiator ? "Compare all eight code groups with the other Mac, then click Pair here and Approve there." : "The other Mac requested a connection. Compare all eight code groups, then click Approve here and Pair there."
    }
}

struct RemoteHomeState: Equatable {
    var deviceID: String
    var deviceName: String
    var online = false
    var rows: [DeviceSidebarRow] = []
    var lastSeen: Date? = nil
}

final class DevicePeer {
    let id = UUID()
    let connection: NWConnection
    let isInitiator: Bool
    var displayName: String
    var manualHost: String?
    var manualPort: Int?
    var handshake: DeviceHandshake?
    var keys: DeviceTransportKeys?
    var hello: DeviceHello?
    var buffer = Data()
    var plainDecoder = DeviceFrameDecoder()
    var trustedReady = false
    var localConfirmed = false
    var remoteConfirmed = false
    var alive = true
    var leasedSessions: Set<UUID> = []
    var startedAt = Date()
    var lastSeen = Date()
    var testSink: ((Data) -> Void)?
    init(connection: NWConnection, isInitiator: Bool, displayName: String, manualHost: String? = nil, manualPort: Int? = nil) {
        self.connection = connection; self.isInitiator = isInitiator; self.displayName = displayName
        self.manualHost = manualHost; self.manualPort = manualPort
    }
}

final class DeviceSyncService: ObservableObject {
    static let shared = DeviceSyncService()
    static let defaultPort: NWEndpoint.Port = 48721
    static let serviceType = "_converse._tcp"
    @Published var discovered: [DiscoveredDevice] = []
    @Published var trusted: [TrustedDevice] = []
    @Published var homes: [String: RemoteHomeState] = [:]
    @Published var pairingPrompt: PairingPrompt?
    @Published var remoteLeases: [String: UInt64] = [:]
    @Published var remoteTranscripts: [String: DeviceTranscriptPayload] = [:]
    @Published var remoteOffline: Set<String> = []
    @Published var outbox: [DeviceOutboxRecord] = []
    @Published var blobReady: [String: Bool] = [:]
    @Published var blobCache: [String: URL] = [:]
    @Published var lastOutcome = ""
    @Published var serviceStatus = "Device sync off"
    @Published var localCodeNote = ""

    private(set) var identity: DeviceIdentity?
    private var trustStore: DeviceTrustStore?
    private var commandStore: DeviceCommandStore?
    private var stateStore: DeviceSyncStateStore?
    private var draftStore: DeviceDraftStore?
    private var outboxStore: DeviceOutboxStore?
    private var leases: DeviceLeaseManager?
    private var boot: UInt64 = 0
    private var drafts = DeviceDraftTracker()
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [UUID: DevicePeer] = [:]
    private var heartbeatTimer: Timer?
    private var publishTimer: Timer?
    private var lastSidebarJSON = ""
    private var stagedBlobs: [String: Data] = [:]
    private var blobPaths: [String: String] = [:]
    private var downloadBuffers: [String: Data] = [:]
    private var imageHashCache: [String: String] = [:]
    private var pendingTakes: [String: Date] = [:]
    private var leaseBoots: [String: UInt64] = [:]
    private var pendingUploads: Set<String> = []
    private var pendingDownloads: Set<String> = []
    private var pendingAsyncAcks: [(commandID: UUID, peerID: UUID, sessionID: String, homeSession: UUID, epoch: UInt64)] = []
    @Published var draftConflicts: [String: String] = [:]
    @Published var completedCommands: Set<UUID> = []
    @Published var draftAttachments: [String: [String]] = [:]
    private var lastSeqByHome: [String: UInt64] = [:]
    private var tickCount = 0
    private var started = false
    var isTestEnvironment: Bool { ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil }

    // Isolated harness wiring without listener, browser, timers, or Keychain.
    func configureForTesting(folder: URL) throws {
        identity = try DeviceIdentity.loadOrCreate(folder: folder, useKeychain: false)
        trustStore = try DeviceTrustStore(folder: folder)
        commandStore = try DeviceCommandStore(folder: folder)
        stateStore = try DeviceSyncStateStore(folder: folder)
        draftStore = try DeviceDraftStore(folder: folder)
        outboxStore = try DeviceOutboxStore(folder: folder)
        boot = stateStore?.beginBoot() ?? 0
        let store = stateStore
        leases = DeviceLeaseManager(initialEpochs: store?.loadedEpochs ?? [:]) { store?.saveEpochs($0) == true }
        started = true
    }
    func adoptPeerForTesting(_ peer: DevicePeer) { peers[peer.id] = peer }
    func startIfNeeded() {
        guard !started, !isTestEnvironment else { return }
        started = true
        do {
            let folder = Store.shared.folder
            identity = try DeviceIdentity.loadOrCreate(folder: folder, useKeychain: true)
            trustStore = try DeviceTrustStore(folder: folder)
            commandStore = try DeviceCommandStore(folder: folder)
            stateStore = try DeviceSyncStateStore(folder: folder)
            draftStore = try DeviceDraftStore(folder: folder)
            outboxStore = try DeviceOutboxStore(folder: folder)
            outbox = outboxStore?.records ?? []
            boot = stateStore?.beginBoot() ?? 0
            let store = stateStore
            leases = DeviceLeaseManager(initialEpochs: store?.loadedEpochs ?? [:]) { store?.saveEpochs($0) == true }
            let savedDrafts = draftStore?.load() ?? DeviceDraftFile()
            drafts.restore(versions: savedDrafts.versions, texts: savedDrafts.texts)
            draftAttachments = savedDrafts.attachments
            rebuildBlobPaths(folder: folder)
            trusted = trustStore?.devices ?? []
            for device in trusted { homes[device.deviceID] = RemoteHomeState(deviceID: device.deviceID, deviceName: device.name) }
            if let cache = stateStore?.state.sidebarCache, let payloads = try? JSONDecoder().decode([DeviceSidebarPayload].self, from: cache) {
                for payload in payloads where homes[payload.homeDeviceID] != nil {
                    homes[payload.homeDeviceID]?.rows = payload.rows
                    for row in payload.rows { remoteOffline.insert(row.globalID) }
                }
            }
            try startListener()
            startBrowser()
            serviceStatus = "Listening as " + (identity?.deviceName ?? "Mac")
            localCodeNote = "Fingerprint " + (identity?.fingerprint ?? "")
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
            publishTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.publishSidebarIfChanged() }
            reconnectTrusted()
        } catch { serviceStatus = "Device sync unavailable: " + error.localizedDescription }
    }

    private func startListener() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let requested = ProcessInfo.processInfo.environment["CONVERSE_DEVICE_PORT"].flatMap { Int($0) }.flatMap { (1...65535).contains($0) ? NWEndpoint.Port(rawValue: UInt16($0)) : nil } ?? Self.defaultPort
        let listener = try NWListener(using: parameters, on: requested)
        listener.service = NWListener.Service(name: identity?.deviceName, type: Self.serviceType)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.serviceStatus = "Listen failed: " + error.localizedDescription }
            if case .ready = state, let port = self?.listener?.port { self?.serviceStatus = "Listening on port " + String(port.rawValue) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }
    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: NWParameters.tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.discovered = results.compactMap { result in
                if case .service(let name, _, _, _) = result.endpoint, name != self.identity?.deviceName {
                    return DiscoveredDevice(name: name, endpoint: result.endpoint)
                }
                return nil
            }.sorted { $0.name < $1.name }
        }
        self.browser = browser
        browser.start(queue: .main)
    }
    func connect(discovered device: DiscoveredDevice) { connect(to: device.endpoint, displayName: device.name) }
    func connectManual(host: String, port: Int) {
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { lastOutcome = "Port must be between 1 and 65535."; return }
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: nwPort), displayName: host, manualHost: host, manualPort: port)
    }
    private func reconnectTrusted() {
        for device in trusted where homes[device.deviceID]?.online != true {
            if let found = discovered.first(where: { $0.name == device.name }) { connect(discovered: found) }
            else if let host = device.lastHost, let port = device.lastPort { connectManual(host: host, port: port) }
        }
    }
    private func connect(to endpoint: NWEndpoint, displayName: String, manualHost: String? = nil, manualPort: Int? = nil) {
        guard let identity else { return }
        if peers.values.contains(where: { $0.displayName == displayName && $0.alive }) { return }
        let connection = NWConnection(to: endpoint, using: .tcp)
        let peer = DevicePeer(connection: connection, isInitiator: true, displayName: displayName, manualHost: manualHost, manualPort: manualPort)
        peer.handshake = DeviceHandshake(isInitiator: true, staticKey: identity.privateKey)
        peers[peer.id] = peer; wire(peer); connection.start(queue: .main)
    }
    private func accept(_ connection: NWConnection) {
        guard let identity else { connection.cancel(); return }
        let peer = DevicePeer(connection: connection, isInitiator: false, displayName: "Incoming device")
        peer.handshake = DeviceHandshake(isInitiator: false, staticKey: identity.privateKey)
        peers[peer.id] = peer; wire(peer); connection.start(queue: .main)
    }
    private func wire(_ peer: DevicePeer) {
        peer.connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .ready: if peer.isInitiator { self.sendHandshake(peer) }; self.receiveMore(peer)
            case .failed, .cancelled: self.disconnect(peer)
            default: break
            }
        }
    }
    private func helloPayload() -> Data {
        let hello = DeviceHello(deviceID: identity?.deviceID ?? "", deviceName: identity?.deviceName ?? "Mac",
                                converseVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development")
        return (try? JSONEncoder().encode(hello)) ?? Data()
    }
    private func sendHandshake(_ peer: DevicePeer) {
        do {
            guard var handshake = peer.handshake else { return }
            let message = try handshake.writeMessage(payload: helloPayload())
            peer.handshake = handshake; sendRaw(peer, message)
        } catch { disconnect(peer) }
    }
    private func sendRaw(_ peer: DevicePeer, _ message: Data) {
        guard message.count <= 65535 else { disconnect(peer); return }
        if let testSink = peer.testSink { testSink(message); return }
        var framed = Data(count: 2)
        framed.withUnsafeMutableBytes { $0.storeBytes(of: UInt16(message.count).bigEndian, as: UInt16.self) }
        peer.connection.send(content: framed + message, completion: .contentProcessed { [weak self, weak peer] error in
            if error != nil, let peer { self?.disconnect(peer) }
        })
    }
    private func receiveMore(_ peer: DevicePeer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak peer] data, _, isComplete, error in
            guard let self, let peer, peer.alive else { return }
            if let data, !data.isEmpty {
                peer.buffer.append(data)
                if peer.buffer.count > 1_048_576 { self.disconnect(peer); return }
                self.drain(peer)
            }
            if isComplete || error != nil { self.disconnect(peer); return }
            if peer.alive { self.receiveMore(peer) }
        }
    }
    private func drain(_ peer: DevicePeer) {
        while peer.buffer.count >= 2 {
            let length = peer.buffer.prefix(2).withUnsafeBytes { Int(UInt16(bigEndian: $0.load(as: UInt16.self))) }
            guard peer.buffer.count >= 2 + length else { return }
            let message = Data(peer.buffer.dropFirst(2).prefix(length))
            peer.buffer.removeFirst(2 + length)
            handleRaw(peer, message)
            if !peer.alive { return }
        }
    }
}

extension DeviceSyncService {
    private func handleRaw(_ peer: DevicePeer, _ message: Data) {
        peer.lastSeen = Date()
        do {
            if peer.keys == nil {
                guard var handshake = peer.handshake else { disconnect(peer); return }
                let payload = try handshake.readMessage(message)
                peer.handshake = handshake
                if let hello = try? JSONDecoder().decode(DeviceHello.self, from: payload), !hello.deviceID.isEmpty {
                    guard hello.protocolVersion == 1, Set(hello.capabilities).isSuperset(of: ["sidebar", "lease", "transcript", "commands", "blobs"]) else { disconnect(peer); return }
                    peer.hello = hello; peer.displayName = hello.deviceName
                }
                var probe = handshake
                if (try? probe.finish()) == nil {
                    let reply = try handshake.writeMessage(payload: helloPayload())
                    peer.handshake = handshake; sendRaw(peer, reply)
                    if peer.isInitiator {
                        peer.keys = try peer.handshake!.finish(); peer.handshake = nil; beginTrust(peer)
                    }
                    return
                }
                peer.keys = try handshake.finish(); peer.handshake = nil; beginTrust(peer)
            } else {
                guard var keys = peer.keys else { return }
                let plain = try keys.receiver.decrypt(message)
                peer.keys = keys
                for envelope in try peer.plainDecoder.append(plain) {
                    guard envelope.version == 1 else { disconnect(peer); return }
                    handleEnvelope(peer, envelope)
                }
            }
        } catch { disconnect(peer) }
    }
    private func beginTrust(_ peer: DevicePeer) {
        guard let keys = peer.keys, let hello = peer.hello, let trustStore else { disconnect(peer); return }
        guard hello.deviceID == DeviceBlob.sha256Hex(keys.remoteStatic) else { disconnect(peer); return }
        switch trustStore.check(deviceID: hello.deviceID, publicKey: keys.remoteStatic) {
        case .trusted:
            peer.localConfirmed = true
            sendEnvelope(peer, DeviceEnvelope(kind: "pair.confirm")); finishTrustIfReady(peer)
        case .unknown, .keyChanged:
            pairingPrompt = PairingPrompt(connectionID: peer.id, peerName: hello.deviceName,
                                          fingerprint: String(hello.deviceID.prefix(16)).uppercased(),
                                          code: DeviceSAS.code(keys.handshakeHash),
                                          keyChanged: trustStore.check(deviceID: hello.deviceID, publicKey: keys.remoteStatic) == .keyChanged,
                                          nameCollision: trustStore.hasNameCollision(name: hello.deviceName, deviceID: hello.deviceID), isInitiator: peer.isInitiator)
            if !peer.isInitiator, !isTestEnvironment {
                DispatchQueue.main.async { AppDelegate.shared?.showDeviceConnect() }
            }
        }
    }
    func confirmPairing() {
        guard let prompt = pairingPrompt, let peer = peers[prompt.connectionID] else { return }
        peer.localConfirmed = true
        serviceStatus = peer.isInitiator ? "Waiting for Approve on " + prompt.peerName + "…" : "Approved. Waiting for Pair on " + prompt.peerName + "…"
        sendEnvelope(peer, DeviceEnvelope(kind: "pair.confirm")); pairingPrompt = nil; finishTrustIfReady(peer)
    }
    func rejectPairing() {
        guard let prompt = pairingPrompt, let peer = peers[prompt.connectionID] else { pairingPrompt = nil; return }
        disconnect(peer); pairingPrompt = nil
    }
    private func finishTrustIfReady(_ peer: DevicePeer) {
        guard peer.localConfirmed, peer.remoteConfirmed, !peer.trustedReady, let hello = peer.hello, let keys = peer.keys else { return }
        do {
            try trustStore?.pin(deviceID: hello.deviceID, name: hello.deviceName, publicKey: keys.remoteStatic, host: peer.manualHost, port: peer.manualPort)
            trusted = trustStore?.devices ?? trusted
        } catch {
            lastOutcome = "Could not save paired device. Control not granted."
            disconnect(peer); return
        }
        peer.trustedReady = true
        homes[hello.deviceID] = RemoteHomeState(deviceID: hello.deviceID, deviceName: hello.deviceName, online: true, rows: homes[hello.deviceID]?.rows ?? [], lastSeen: Date())
        sendSidebar(to: peer)
        serviceStatus = "Connected to " + hello.deviceName + ". Take a session again to control it."
    }
    func forgetDevice(_ device: TrustedDevice) {
        do {
            try trustStore?.forget(deviceID: device.deviceID)
            trusted = trustStore?.devices ?? []
            homes.removeValue(forKey: device.deviceID)
            for peer in peers.values where peer.hello?.deviceID == device.deviceID { disconnect(peer) }
        } catch { lastOutcome = "Could not forget device: " + error.localizedDescription }
    }
    private func sendEnvelope(_ peer: DevicePeer, _ envelope: DeviceEnvelope) {
        guard peer.alive, var keys = peer.keys else { return }
        do {
            let framed = try DeviceFrame.encode(envelope)
            var offset = 0
            while offset < framed.count {
                let chunk = Data(framed.dropFirst(offset).prefix(60_000)); offset += chunk.count
                sendRaw(peer, try keys.sender.encrypt(chunk))
            }
            peer.keys = keys
        } catch { disconnect(peer) }
    }
    private func disconnect(_ peer: DevicePeer) {
        guard peer.alive else { return }
        peer.alive = false; peer.connection.cancel()
        if let hello = peer.hello, let device = peer.hello?.deviceID {
            homes[hello.deviceID]?.online = false; homes[hello.deviceID]?.lastSeen = Date()
            // Viewer authority never survives disconnect.
            for row in homes[hello.deviceID]?.rows ?? [] {
                remoteLeases.removeValue(forKey: row.globalID); remoteOffline.insert(row.globalID)
                try? outboxStore?.markUncertain(sessionID: row.globalID)
            }
            outbox = outboxStore?.records ?? outbox
            // Home leases held by this peer end immediately.
            if let leases { for sessionID in peer.leasedSessions { if leases.holder(session: sessionID)?.device == device { leases.release(session: sessionID, device: device, epoch: leases.holder(session: sessionID)?.epoch ?? 0) } } }
            _ = device
        }
        peers.removeValue(forKey: peer.id)
    }
    private func tick() {
        tickCount += 1
        let now = Date()
        for peer in Array(peers.values) {
            if !peer.trustedReady && now.timeIntervalSince(peer.startedAt) > 60 { disconnect(peer); continue }
            if peer.trustedReady {
                sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.ping.rawValue))
                // Silent partition: no frame for 20s means offline, sends blocked.
                if now.timeIntervalSince(peer.lastSeen) > 20, let id = peer.hello?.deviceID, homes[id]?.online == true {
                    homes[id]?.online = false
                    for row in homes[id]?.rows ?? [] { remoteOffline.insert(row.globalID); remoteLeases.removeValue(forKey: row.globalID) }
                }
            }
        }
        if let leases {
            for expired in leases.sweepExpired() {
                for peer in peers.values where peer.hello?.deviceID == expired.device {
                    peer.leasedSessions.remove(expired.session)
                    if let home = identity?.deviceID {
                        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseStolen.rawValue, sessionID: DeviceGlobalID(home: home, session: expired.session).string))
                    }
                }
            }
        }
        // Leases for sessions no longer placed anywhere are released, so a
        // displaced or parked remote pane cannot heartbeat forever.
        for globalID in Array(remoteLeases.keys) where Workspace.shared.placements[placementID(forGlobal: globalID)] == nil {
            releaseRemote(globalID: globalID)
        }
        for (globalID, epoch) in remoteLeases {
            guard let global = DeviceGlobalID(globalID), let peer = peerForHome(global.home) else { continue }
            sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseHeartbeat.rawValue, sessionID: globalID, epoch: epoch))
        }
        // Async Muse setting changes complete after their accepted ack.
        var stillPending: [(commandID: UUID, peerID: UUID, sessionID: String, homeSession: UUID, epoch: UInt64)] = []
        for pending in pendingAsyncAcks {
            if let session = Store.shared.sessions.first(where: { $0.id == pending.homeSession }), session.changingSetting { stillPending.append(pending); continue }
            let notice = Store.shared.sessions.first(where: { $0.id == pending.homeSession })?.settingNotice ?? "Session closed before the change finished"
            let failed = notice.hasPrefix("Change not confirmed:") || !Store.shared.sessions.contains(where: { $0.id == pending.homeSession })
            do {
                if failed { try commandStore?.markFailed(id: pending.commandID) }
                else { try commandStore?.markCompleted(id: pending.commandID) }
                if let peer = peers[pending.peerID] { sendAck(peer, commandID: pending.commandID, sessionID: pending.sessionID, outcome: failed ? "failed" : "completed", detail: notice, epoch: pending.epoch) }
            } catch {
                if let peer = peers[pending.peerID] { sendAck(peer, commandID: pending.commandID, sessionID: pending.sessionID, outcome: "uncertain", detail: "Setting finished but its outcome could not be saved. Check home.", epoch: pending.epoch) }
            }
        }
        pendingAsyncAcks = stillPending
        for peer in peers.values where peer.trustedReady {
            for sessionID in Array(peer.leasedSessions) { sendTranscript(to: peer, sessionID: sessionID) }
        }
        if tickCount % 6 == 0 { reconnectTrusted() }
    }
}

extension DeviceSyncService {
    func remoteRow(globalID: String) -> DeviceSidebarRow? {
        homes.values.lazy.flatMap(\.rows).first { $0.globalID == globalID }
    }
    func remoteRow(placementID: UUID) -> DeviceSidebarRow? {
        homes.values.lazy.flatMap(\.rows).first { self.placementID(forGlobal: $0.globalID) == placementID }
    }
    func globalID(forPlacement placementID: UUID) -> String? { remoteRow(placementID: placementID)?.globalID }
    // Deterministic placement identity per global session. Workspace keys
    // panes by UUID; deriving it from the full global ID prevents copied
    // archives on two homes (same session UUID) from colliding locally.
    func placementID(forGlobal globalID: String) -> UUID {
        let digest = SHA256.hash(data: Data(("converse-placement:" + globalID).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private func persistDrafts() {
        let snap = drafts.snapshot
        do { try draftStore?.save(DeviceDraftFile(versions: snap.versions, texts: snap.texts, attachments: draftAttachments)) }
        catch { lastOutcome = "Could not save draft state: " + error.localizedDescription }
    }
    private func rebuildBlobPaths(folder: URL) {
        let root = folder.appendingPathComponent("Attachments")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix("Remote-") {
                if let data = try? Data(contentsOf: file) { blobPaths[DeviceBlob.sha256Hex(data)] = file.path }
            }
        }
    }
    private func imageHash(path: String) -> String? {
        if let cached = imageHashCache[path] { return cached }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let hash = DeviceBlob.sha256Hex(data); imageHashCache[path] = hash; blobPaths[hash] = path; return hash
    }
    private func wireMessage(_ message: Message) -> DeviceWireMessage {
        DeviceWireMessage(id: message.id, role: message.role, text: message.text, imageHashes: message.images.compactMap { imageHash(path: $0) })
    }
    private func requestDTOs(_ session: Session) -> [DeviceRequestDTO] {
        session.requests.map { request in
            let choices = (request.params["availableChoices"] as? [[String: Any]] ?? []).compactMap { choice -> DeviceChoiceDTO? in
                guard let id = choice["choiceId"] as? String else { return nil }
                return DeviceChoiceDTO(id: id, label: choice["label"] as? String ?? id, detail: choice["rulePreview"] as? String ?? choice["scope"] as? String)
            }
            let questions = request.params["questions"] as? [[String: Any]]
            return DeviceRequestDTO(id: request.id, kind: request.kind, toolName: request.params["toolName"] as? String,
                                    rawArgs: request.params["rawArgs"] as? String, choices: choices,
                                    questionsJSON: questions.flatMap { try? JSONSerialization.data(withJSONObject: $0) })
        }
    }
    private func sidebarPayload() -> DeviceSidebarPayload {
        let home = identity?.deviceID ?? ""
        let rows = Store.shared.sessions.map { session in
            DeviceSidebarRow(globalID: DeviceGlobalID(home: home, session: session.id).string, sessionID: session.id,
                             title: session.title, assistant: session.entry.name, engine: session.entry.engine,
                             model: session.toolStatus.model, effort: session.toolStatus.effort, access: session.toolStatus.access,
                             status: session.status, busy: session.busy, queued: session.pending.count, queuePaused: session.queuePaused,
                             leaseHolder: leases?.holder(session: session.id)?.device, leaseEpoch: leases?.holder(session: session.id)?.epoch,
                             accountName: session.entry.accountName)
        }
        return DeviceSidebarPayload(homeDeviceID: home, homeDeviceName: identity?.deviceName ?? "Mac", homeSeq: stateStore?.state.homeSeq ?? 0, rows: rows)
    }
    private func sendSidebar(to peer: DevicePeer) {
        guard let payload = try? JSONEncoder().encode(sidebarPayload()) else { return }
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.sidebarSnapshot.rawValue, homeSeq: stateStore?.nextSeq(), payload: payload))
    }
    private func publishSidebarIfChanged() {
        guard started, peers.values.contains(where: { $0.trustedReady }) else { return }
        let json = (try? JSONEncoder().encode(sidebarPayload())).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard json != lastSidebarJSON else { return }
        lastSidebarJSON = json
        for peer in peers.values where peer.trustedReady { sendSidebar(to: peer) }
    }
    private func sendTranscript(to peer: DevicePeer, sessionID: UUID, beforeOffset: Int? = nil) {
        guard let session = Store.shared.sessions.first(where: { $0.id == sessionID }), let home = identity?.deviceID, let leases, let device = peer.hello?.deviceID else { return }
        // Never stream without a current lease for this exact peer and epoch.
        guard let holder = leases.holder(session: sessionID), holder.device == device else { peer.leasedSessions.remove(sessionID); return }
        let total = session.messages.count
        let end = min(max(beforeOffset ?? total, 0), total)
        let start = max(0, end - 200)
        let slice = Array(session.messages[start..<end].map { wireMessage($0) })
        let draftKey = sessionID.uuidString
        let imageHashes = session.attachments.compactMap { imageHash(path: $0) }
        if draftAttachments[draftKey] != imageHashes {
            draftAttachments[draftKey] = imageHashes
            _ = drafts.bump(session: draftKey, text: session.draft)
            persistDrafts()
        }
        // Local home edits bump the version so transfer never reuses one.
        if drafts.text(session: draftKey) == nil { drafts.adopt(session: draftKey, version: max(1, drafts.version(session: draftKey)), text: session.draft); persistDrafts() }
        else if drafts.text(session: draftKey) != session.draft { _ = drafts.bump(session: draftKey, text: session.draft); persistDrafts() }
        let payload = DeviceTranscriptPayload(globalID: DeviceGlobalID(home: home, session: sessionID).string,
                                              homeSeq: stateStore?.nextSeq() ?? 0, epoch: holder.epoch, boot: boot,
                                              messages: slice, offset: start, total: total, prepend: beforeOffset != nil,
                                              draft: session.draft, draftVersion: drafts.version(session: sessionID.uuidString), draftImageHashes: imageHashes,
                                              pending: session.pending.map { DevicePendingDTO(id: $0.id, text: $0.text) },
                                              busy: session.busy, status: session.status, title: session.title, engine: session.entry.engine,
                                              accountName: session.entry.accountName, model: session.toolStatus.model, effort: session.toolStatus.effort, access: session.toolStatus.access,
                                              modelOptions: session.modelChoices.map { DeviceChoiceDTO(id: $0.id, label: $0.label, provider: $0.provider, profile: $0.profile) },
                                              effortOptions: session.availableEfforts,
                                              accessOptions: session.accessChoices.filter(\.available).map { DeviceChoiceDTO(id: $0.id, label: $0.label) },
                                              requests: requestDTOs(session), queuePaused: session.queuePaused)
        if let data = try? JSONEncoder().encode(payload) {
            sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.transcriptSnapshot.rawValue, homeSeq: payload.homeSeq, boot: boot, sessionID: payload.globalID, epoch: holder.epoch, payload: data))
        }
    }
    private func homeSession(_ envelope: DeviceEnvelope) -> (Session, DeviceGlobalID)? {
        guard let idString = envelope.sessionID, let global = DeviceGlobalID(idString), global.home == identity?.deviceID,
              let session = Store.shared.sessions.first(where: { $0.id == global.session }) else { return nil }
        return (session, global)
    }
    private func requireLease(_ peer: DevicePeer, _ envelope: DeviceEnvelope, _ session: Session) -> Bool {
        guard let device = peer.hello?.deviceID, let epoch = envelope.epoch, leases?.validate(session: session.id, device: device, epoch: epoch) == true else {
            if let commandID = envelope.commandID { sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: "rejected", detail: "Stale or missing display lease. Take the session again.", epoch: envelope.epoch) }
            return false
        }
        return true
    }
    private func sendAck(_ peer: DevicePeer, commandID: UUID, sessionID: String?, outcome: String, detail: String? = nil, epoch: UInt64? = nil) {
        let payload = try? JSONEncoder().encode(DeviceAckPayload(outcome: outcome, detail: detail, epoch: epoch))
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.commandAck.rawValue, sessionID: sessionID, commandID: commandID, epoch: epoch, payload: payload))
    }
    private func executeHomeCommand(_ peer: DevicePeer, _ envelope: DeviceEnvelope) {
        guard let (session, _) = homeSession(envelope), let commandID = envelope.commandID,
              let data = envelope.payload, let command = try? JSONDecoder().decode(DeviceCommandPayload.self, from: data) else { return }
        guard requireLease(peer, envelope, session) else { return }
        guard let origin = peer.hello?.deviceID, let commandStore else { return }
        let payloadHash = DeviceBlob.sha256Hex(data)
        let known = ["submit", "inject", "injectAll", "stop", "resumeQueue", "pauseQueue", "clearQueue", "rename", "model", "effort", "access", "answer"]
        do {
            guard try commandStore.begin(id: commandID, origin: origin, sessionID: envelope.sessionID ?? "", payloadHash: payloadHash) else {
                if commandStore.bindingMatches(id: commandID, origin: origin, sessionID: envelope.sessionID ?? "", payloadHash: payloadHash) {
                    sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: (commandStore.outcome(id: commandID) ?? .rejected).rawValue, detail: "Already recorded on home.", epoch: envelope.epoch)
                } else {
                    sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: "rejected", detail: "Command ID reused with different content.", epoch: envelope.epoch)
                }
                return
            }
            guard known.contains(command.action) else { try commandStore.markFailed(id: commandID); sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: "failed", detail: "Unknown action.", epoch: envelope.epoch); return }
            if command.action == "submit" {
                let missing = command.blobHashes.filter { blobPaths[$0] == nil || !FileManager.default.fileExists(atPath: blobPaths[$0] ?? "") }
                guard missing.isEmpty else { try commandStore.markFailed(id: commandID); sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: "failed", detail: "Attachments not stored on home yet. Nothing was submitted.", epoch: envelope.epoch); return }
                guard !(command.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !command.blobHashes.isEmpty else { try commandStore.markFailed(id: commandID); sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: "failed", detail: "Empty message.", epoch: envelope.epoch); return }
            }
            try commandStore.markRunning(id: commandID)
        } catch { sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: "uncertain", detail: "Home could not durably record the command. Check home before retrying.", epoch: envelope.epoch); return }
        let store = Store.shared
        var asyncSetting = false
        switch command.action {
        case "submit":
            let savedDraft = session.draft, savedAttachments = session.attachments
            let consumesHomeDraft = (command.text ?? "") == savedDraft
            session.draft = command.text ?? ""; session.attachments = command.blobHashes.compactMap { blobPaths[$0] }
            store.submit(session)
            // Atomically consume the synced home draft on accepted submit so
            // the next holder cannot resubmit it; independent text preserves it.
            session.draft = consumesHomeDraft ? "" : savedDraft; session.attachments = consumesHomeDraft ? [] : savedAttachments
            let key = session.id.uuidString
            if consumesHomeDraft { _ = drafts.bump(session: key, text: "") } else { drafts.adopt(session: key, version: drafts.version(session: key), text: savedDraft) }
            persistDrafts(); store.saveSoon()
        case "inject": store.injectPending(session, id: command.pendingID)
        case "injectAll": store.injectPending(session)
        case "stop": store.stop(session)
        case "resumeQueue": session.queuePaused = false; store.save(); store.runNext(session)
        case "pauseQueue": session.queuePaused = true; store.save()
        case "clearQueue": session.pending = []; store.save()
        case "rename":
            // Same path as local rename: title didSet updates identity sidecar.
            if let text = command.text, !text.isEmpty { session.title = text; store.save() }
        case "model": if let model = command.model { store.changeSetting(session, .model(MuseModelChoice(id: model, label: model, provider: command.modelProvider ?? session.entry.engine, profile: command.modelProfile, efforts: session.availableEfforts))); asyncSetting = session.changingSetting }
        case "effort": if let effort = command.effort { store.changeSetting(session, .effort(effort)); asyncSetting = session.changingSetting }
        case "access": if let access = command.access { store.changeSetting(session, .access(access)); asyncSetting = session.changingSetting }
        case "answer":
            if let request = session.requests.first(where: { $0.id == command.requestID }) {
                if let answersJSON = command.answersJSON, let answers = (try? JSONSerialization.jsonObject(with: answersJSON)) as? [[String: Any]] {
                    store.answerMuse(session, request: request, answers: answers)
                } else { store.answerMuse(session, request: request, choice: command.choiceID) }
            }
        default: break
        }
        if asyncSetting {
            pendingAsyncAcks.append((commandID: commandID, peerID: peer.id, sessionID: envelope.sessionID ?? "", homeSession: session.id, epoch: envelope.epoch ?? 0))
            sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: "accepted", detail: "Setting change in progress on home; completion will follow.", epoch: envelope.epoch)
            sendTranscript(to: peer, sessionID: session.id); publishSidebarIfChanged(); return
        }
        do { try commandStore.markCompleted(id: commandID) }
        catch { sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: "uncertain", detail: "Applied on home but completion was not recorded. Check home; do not resend.", epoch: envelope.epoch); return }
        sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: "completed",
                detail: "Applied once on home.", epoch: envelope.epoch)
        sendTranscript(to: peer, sessionID: session.id); publishSidebarIfChanged()
    }
}

extension DeviceSyncService {
    // Internal for the service-level self-test harness.
    func handleEnvelope(_ peer: DevicePeer, _ envelope: DeviceEnvelope) {
        peer.lastSeen = Date()
        if envelope.kind == "pair.confirm" { peer.remoteConfirmed = true; finishTrustIfReady(peer); return }
        guard peer.trustedReady, let peerHome = peer.hello?.deviceID else { return }
        switch envelope.kind {
        case DeviceMessageKind.ping.rawValue:
            sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.pong.rawValue))
            if homes[peerHome]?.online == false { homes[peerHome]?.online = true; for row in homes[peerHome]?.rows ?? [] { remoteOffline.remove(row.globalID) } }
        case DeviceMessageKind.pong.rawValue:
            if homes[peerHome]?.online == false { homes[peerHome]?.online = true; for row in homes[peerHome]?.rows ?? [] { remoteOffline.remove(row.globalID) } }
        case DeviceMessageKind.sidebarSnapshot.rawValue, DeviceMessageKind.sidebarDelta.rawValue:
            guard let data = envelope.payload, let payload = try? JSONDecoder().decode(DeviceSidebarPayload.self, from: data),
                  payload.homeDeviceID == peerHome, payload.rows.allSatisfy({ DeviceGlobalID($0.globalID)?.home == peerHome }) else { disconnect(peer); return }
            if let seq = envelope.homeSeq {
                if let last = lastSeqByHome[peerHome], seq <= last { return }
                lastSeqByHome[peerHome] = seq
            }
            homes[peerHome] = RemoteHomeState(deviceID: peerHome, deviceName: payload.homeDeviceName, online: true, rows: payload.rows, lastSeen: Date())
            for row in payload.rows { remoteOffline.remove(row.globalID) }
            if let encoded = try? JSONEncoder().encode(homes.values.map { DeviceSidebarPayload(homeDeviceID: $0.deviceID, homeDeviceName: $0.deviceName, homeSeq: 0, rows: $0.rows) }) { stateStore?.saveSidebarCache(encoded) }
        case DeviceMessageKind.leaseAcquire.rawValue:
            guard let (session, _) = homeSession(envelope), let leases else { return }
            let result = leases.acquire(session: session.id, device: peerHome)
            guard result.granted else {
                sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseDenied.rawValue, boot: boot, sessionID: envelope.sessionID)); return
            }
            if let displaced = result.displaced, displaced != peerHome, let old = peers.values.first(where: { $0.hello?.deviceID == displaced }) {
                old.leasedSessions.remove(session.id)
                sendEnvelope(old, DeviceEnvelope(kind: DeviceMessageKind.leaseStolen.rawValue, boot: boot, sessionID: envelope.sessionID, epoch: result.epoch))
            }
            peer.leasedSessions.insert(session.id)
            Workspace.shared.park(session.id)
            sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseGranted.rawValue, boot: boot, sessionID: envelope.sessionID, epoch: result.epoch))
            sendTranscript(to: peer, sessionID: session.id); publishSidebarIfChanged()
        case DeviceMessageKind.leaseHeartbeat.rawValue:
            if let (session, _) = homeSession(envelope), let epoch = envelope.epoch { _ = leases?.heartbeat(session: session.id, device: peerHome, epoch: epoch) }
        case DeviceMessageKind.leaseRelease.rawValue:
            if let (session, _) = homeSession(envelope), let epoch = envelope.epoch {
                leases?.release(session: session.id, device: peerHome, epoch: epoch); peer.leasedSessions.remove(session.id); publishSidebarIfChanged()
            }
        case DeviceMessageKind.leaseGranted.rawValue:
            guard let idString = envelope.sessionID, let global = DeviceGlobalID(idString), global.home == peerHome, let epoch = envelope.epoch else { return }
            if pendingTakes[idString] != nil {
                pendingTakes.removeValue(forKey: idString)
                remoteLeases[idString] = epoch; leaseBoots[idString] = envelope.boot; remoteOffline.remove(idString)
                lastOutcome = "Display taken. Epoch " + String(epoch) + "."
            } else if let current = remoteLeases[idString], epoch > current {
                // Second grant from a coalesced duplicate: adopt monotonically.
                remoteLeases[idString] = epoch; leaseBoots[idString] = envelope.boot
            } else {
                // Late grant after park/cancel: release it at home immediately.
                sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseRelease.rawValue, sessionID: idString, epoch: epoch))
            }
        case DeviceMessageKind.leaseStolen.rawValue, DeviceMessageKind.leaseDenied.rawValue:
            if let idString = envelope.sessionID, let global = DeviceGlobalID(idString), global.home == peerHome {
                pendingTakes.removeValue(forKey: idString)
                remoteLeases.removeValue(forKey: idString); leaseBoots.removeValue(forKey: idString)
                remoteTranscripts.removeValue(forKey: idString)
                Workspace.shared.park(placementID(forGlobal: idString))
                lastOutcome = "Display moved to another device."
            }
        case DeviceMessageKind.transcriptSnapshot.rawValue, DeviceMessageKind.transcriptTail.rawValue:
            guard let data = envelope.payload, let payload = try? JSONDecoder().decode(DeviceTranscriptPayload.self, from: data),
                  let global = DeviceGlobalID(payload.globalID), global.home == peerHome,
                  let epoch = payload.epoch, remoteLeases[payload.globalID] == epoch else { return }
            if let expectedBoot = leaseBoots[payload.globalID], let payloadBoot = payload.boot, expectedBoot != payloadBoot {
                remoteLeases.removeValue(forKey: payload.globalID); lastOutcome = "Home restarted. Take the session again."; return
            }
            if let existingSeq = remoteTranscripts[payload.globalID]?.homeSeq, payload.homeSeq <= existingSeq { return }
            if var existing = remoteTranscripts[payload.globalID] {
                // Merge by stable message ID so loaded history survives tails.
                var combined: [DeviceWireMessage]
                if payload.prepend {
                    let known = Set(existing.messages.map(\.id))
                    combined = payload.messages.filter { !known.contains($0.id) } + existing.messages
                } else if let firstID = payload.messages.first?.id, let cut = existing.messages.firstIndex(where: { $0.id == firstID }) {
                    combined = Array(existing.messages[..<cut]) + payload.messages
                } else {
                    let known = Set(existing.messages.map(\.id))
                    combined = existing.messages + payload.messages.filter { !known.contains($0.id) }
                }
                existing.messages = combined; existing.offset = min(existing.offset, payload.offset); existing.total = payload.total
                existing.homeSeq = payload.homeSeq; existing.busy = payload.busy; existing.status = payload.status
                existing.pending = payload.pending; existing.requests = payload.requests; existing.queuePaused = payload.queuePaused
                existing.model = payload.model; existing.effort = payload.effort; existing.access = payload.access
                existing.modelOptions = payload.modelOptions; existing.effortOptions = payload.effortOptions; existing.accessOptions = payload.accessOptions
                existing.draft = payload.draft; existing.draftVersion = payload.draftVersion; existing.draftImageHashes = payload.draftImageHashes
                existing.title = payload.title; existing.engine = payload.engine; existing.accountName = payload.accountName
                existing.epoch = payload.epoch; existing.boot = payload.boot
                remoteTranscripts[payload.globalID] = existing
            } else {
                remoteTranscripts[payload.globalID] = payload
            }
            if drafts.adoptIfNewer(session: payload.globalID, version: payload.draftVersion, text: payload.draft) {
                draftAttachments[payload.globalID] = payload.draftImageHashes ?? []
                persistDrafts()
            }
            remoteOffline.remove(payload.globalID)
        case DeviceMessageKind.transcriptRequest.rawValue:
            guard let (session, _) = homeSession(envelope), let data = envelope.payload, let request = try? JSONDecoder().decode(DeviceTranscriptRequest.self, from: data) else { return }
            guard requireLease(peer, envelope, session) else { return }
            sendTranscript(to: peer, sessionID: session.id, beforeOffset: request.beforeOffset)
        case DeviceMessageKind.draftPatch.rawValue:
            guard let (session, _) = homeSession(envelope), let data = envelope.payload, let draft = try? JSONDecoder().decode(DeviceDraftPayload.self, from: data) else { return }
            guard requireLease(peer, envelope, session) else { return }
            let hashes = draft.imageHashes ?? []
            guard hashes.allSatisfy({ blobPaths[$0].map { FileManager.default.fileExists(atPath: $0) } == true }) else {
                sendTranscript(to: peer, sessionID: session.id); return
            }
            let applied = drafts.apply(session: session.id.uuidString, version: draft.version, text: draft.text)
            if applied {
                session.draft = draft.text; session.attachments = hashes.compactMap { blobPaths[$0] }
                draftAttachments[session.id.uuidString] = hashes
                Store.shared.save(); persistDrafts()
            }
            let ack = try? JSONEncoder().encode(DeviceDraftPayload(version: applied ? draft.version : drafts.version(session: session.id.uuidString), text: session.draft))
            sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.draftAck.rawValue, sessionID: envelope.sessionID, epoch: envelope.epoch, payload: ack))
        case DeviceMessageKind.draftAck.rawValue:
            if let idString = envelope.sessionID, let global = DeviceGlobalID(idString), global.home == peerHome, remoteLeases[idString] == envelope.epoch,
               let data = envelope.payload, let ack = try? JSONDecoder().decode(DeviceDraftPayload.self, from: data) {
                if ack.version < drafts.version(session: idString) {
                    draftConflicts[idString] = "Home kept a newer draft (version " + String(ack.version) + "). Your last edit was not applied."
                } else { draftConflicts.removeValue(forKey: idString) }
            }
        case DeviceMessageKind.command.rawValue:
            executeHomeCommand(peer, envelope)
        case DeviceMessageKind.commandQuery.rawValue:
            if let commandID = envelope.commandID, let commandStore {
                if let record = commandStore.records[commandID], record.origin != peerHome || record.sessionID != envelope.sessionID { return }
                sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: (commandStore.outcome(id: commandID) ?? .rejected).rawValue, detail: "Home record lookup.", epoch: envelope.epoch)
            }
        case DeviceMessageKind.commandAck.rawValue:
            // Bind to authenticated home + exact outbox session. A different
            // paired peer that somehow knows an ID cannot complete it.
            if let commandID = envelope.commandID, let idString = envelope.sessionID, let global = DeviceGlobalID(idString), global.home == peerHome,
               let record = outbox.first(where: { $0.commandID == commandID }), record.sessionID == idString,
               envelope.epoch != nil && (envelope.epoch == recordEpoch(record) || remoteLeases[idString] == envelope.epoch),
               let data = envelope.payload, let ack = try? JSONDecoder().decode(DeviceAckPayload.self, from: data) {
                lastOutcome = ack.detail.map { ack.outcome + ": " + $0 } ?? ack.outcome
                try? outboxStore?.resolve(commandID: commandID, outcome: ack.outcome, detail: ack.detail)
                outbox = outboxStore?.records ?? outbox
                if ack.outcome == "completed" { completedCommands.insert(commandID) }
                if ack.outcome == "rejected" { remoteLeases.removeValue(forKey: idString); leaseBoots.removeValue(forKey: idString) }
            }
        case DeviceMessageKind.blobChunk.rawValue, DeviceMessageKind.blobComplete.rawValue, DeviceMessageKind.blobOffer.rawValue:
            guard let (session, _) = homeSession(envelope), let data = envelope.payload, let blob = try? JSONDecoder().decode(DeviceBlobPayload.self, from: data) else { return }
            guard requireLease(peer, envelope, session) else { return }
            if envelope.kind == DeviceMessageKind.blobOffer.rawValue {
                let stored = blobPaths[blob.sha256Hex].map { FileManager.default.fileExists(atPath: $0) } ?? false
                sendBlobAck(peer, envelope: envelope, hash: blob.sha256Hex, stored: stored, detail: stored ? "Already stored on home." : "Not stored on home."); return
            }
            if let chunk = blob.chunk {
                stagedBlobs[blob.sha256Hex, default: Data()].append(chunk)
                if (stagedBlobs[blob.sha256Hex]?.count ?? 0) > DeviceBlob.maxBlob { stagedBlobs.removeValue(forKey: blob.sha256Hex); sendBlobAck(peer, envelope: envelope, hash: blob.sha256Hex, stored: false, detail: "Attachment too large."); return }
            }
            if blob.done {
                guard let bytes = stagedBlobs[blob.sha256Hex], DeviceBlob.verify(bytes, sha256Hex: blob.sha256Hex) else {
                    stagedBlobs.removeValue(forKey: blob.sha256Hex); sendBlobAck(peer, envelope: envelope, hash: blob.sha256Hex, stored: false, detail: "Attachment checksum mismatch."); return
                }
                do {
                    let dir = Store.shared.folder.appendingPathComponent("Attachments/" + session.id.uuidString)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let file = dir.appendingPathComponent("Remote-" + String(blob.sha256Hex.prefix(16)) + ".png")
                    try bytes.write(to: file, options: .atomic)
                    guard FileManager.default.fileExists(atPath: file.path) else { throw CocoaError(.fileWriteUnknown) }
                    blobPaths[blob.sha256Hex] = file.path; stagedBlobs.removeValue(forKey: blob.sha256Hex)
                    sendBlobAck(peer, envelope: envelope, hash: blob.sha256Hex, stored: true, detail: "Stored on home.")
                } catch { sendBlobAck(peer, envelope: envelope, hash: blob.sha256Hex, stored: false, detail: "Home could not store attachment: " + error.localizedDescription) }
            }
        case DeviceMessageKind.blobAck.rawValue:
            if let idString = envelope.sessionID, let global = DeviceGlobalID(idString), global.home == peerHome, envelope.epoch == nil || remoteLeases[idString] == envelope.epoch,
               let data = envelope.payload, let ack = try? JSONDecoder().decode(DeviceAckPayload.self, from: data), let hash = ack.detail?.split(separator: "|").first.map(String.init),
               pendingUploads.contains(hash) {
                blobReady[hash] = ack.outcome == "stored"
                if ack.outcome == "stored" {
                    pendingUploads.remove(hash)
                    if let hashes = draftAttachments[idString], hashes.contains(hash), hashes.allSatisfy({ blobReady[$0] == true }), let text = drafts.text(session: idString) ?? remoteTranscripts[idString]?.draft {
                        sendRemoteDraft(globalID: idString, text: text)
                    }
                }
                lastOutcome = ack.outcome == "stored" ? "Attachment stored on home." : ("Attachment failed: " + (ack.detail ?? ""))
            }
        case DeviceMessageKind.blobRequest.rawValue:
            guard let (session, _) = homeSession(envelope), let data = envelope.payload, let blob = try? JSONDecoder().decode(DeviceBlobPayload.self, from: data) else { return }
            guard requireLease(peer, envelope, session), let path = blobPaths[blob.sha256Hex], let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
            var offset = 0
            while offset < bytes.count {
                let chunk = Data(bytes.dropFirst(offset).prefix(32_768)); offset += chunk.count
                let payload = try? JSONEncoder().encode(DeviceBlobPayload(sha256Hex: blob.sha256Hex, size: bytes.count, chunk: chunk, done: offset >= bytes.count))
                sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.blobData.rawValue, sessionID: envelope.sessionID, epoch: envelope.epoch, payload: payload))
            }
        case DeviceMessageKind.blobData.rawValue:
            guard let idString = envelope.sessionID, let global = DeviceGlobalID(idString), global.home == peerHome, remoteLeases[idString] == envelope.epoch,
                  let data = envelope.payload, let blob = try? JSONDecoder().decode(DeviceBlobPayload.self, from: data), pendingDownloads.contains(blob.sha256Hex) else { return }
            if let chunk = blob.chunk {
                downloadBuffers[blob.sha256Hex, default: Data()].append(chunk)
                if (downloadBuffers[blob.sha256Hex]?.count ?? 0) > DeviceBlob.maxBlob { downloadBuffers.removeValue(forKey: blob.sha256Hex); pendingDownloads.remove(blob.sha256Hex); return }
            }
            if blob.done, let bytes = downloadBuffers[blob.sha256Hex], DeviceBlob.verify(bytes, sha256Hex: blob.sha256Hex) {
                let dir = Store.shared.folder.appendingPathComponent("RemoteCache")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent(String(blob.sha256Hex.prefix(16)) + ".png")
                if (try? bytes.write(to: file, options: .atomic)) != nil { blobCache[blob.sha256Hex] = file }
                downloadBuffers.removeValue(forKey: blob.sha256Hex); pendingDownloads.remove(blob.sha256Hex)
            }
        default: break
        }
    }
    private func sendBlobAck(_ peer: DevicePeer, envelope: DeviceEnvelope, hash: String, stored: Bool, detail: String) {
        let payload = try? JSONEncoder().encode(DeviceAckPayload(outcome: stored ? "stored" : "failed", detail: hash + "|" + detail))
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.blobAck.rawValue, sessionID: envelope.sessionID, epoch: envelope.epoch, payload: payload))
    }

    private func recordEpoch(_ record: DeviceOutboxRecord) -> UInt64 { record.epoch }
    // MARK: Viewer actions
    private func peerForHome(_ home: String) -> DevicePeer? {
        peers.values.first { $0.trustedReady && $0.hello?.deviceID == home && Date().timeIntervalSince($0.lastSeen) <= 20 && homes[home]?.online == true }
    }
    func acquireRemote(globalID: String) {
        guard let global = DeviceGlobalID(globalID), let peer = peerForHome(global.home) else { lastOutcome = "Home is offline."; return }
        // Coalesce: moving panes or double-clicking must not mint a second
        // epoch that invalidates the first grant.
        guard pendingTakes[globalID] == nil, remoteLeases[globalID] == nil else { return }
        // Fresh take must not hydrate from a stale retained transcript.
        remoteTranscripts.removeValue(forKey: globalID)
        pendingTakes[globalID] = Date()
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseAcquire.rawValue, sessionID: globalID))
    }
    func releaseRemote(globalID: String) {
        pendingTakes.removeValue(forKey: globalID)
        guard let global = DeviceGlobalID(globalID), let epoch = remoteLeases[globalID], let peer = peerForHome(global.home) else {
            remoteLeases.removeValue(forKey: globalID); leaseBoots.removeValue(forKey: globalID); return
        }
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseRelease.rawValue, sessionID: globalID, epoch: epoch))
        remoteLeases.removeValue(forKey: globalID); leaseBoots.removeValue(forKey: globalID)
    }
    func releaseWindow(placements: [UUID: PaneLocation], windowID: UUID) {
        for (placement, location) in placements where location.windowID == windowID {
            if let globalID = globalID(forPlacement: placement) { releaseRemote(globalID: globalID) }
        }
    }
    // Called before any pane assignment that may displace a remote session.
    func releaseDisplaced(in windowID: UUID, pane: Int, incomingPlacement: UUID) {
        guard let displaced = Workspace.shared.session(in: windowID, pane: pane), displaced != incomingPlacement,
              let globalID = globalID(forPlacement: displaced) else { return }
        releaseRemote(globalID: globalID)
    }
    func localTake(sessionID: UUID) {
        guard started, let home = identity?.deviceID, let leases, leases.holder(session: sessionID) != nil else { return }
        let result = leases.acquire(session: sessionID, device: home)
        guard result.granted else { lastOutcome = "Could not record local display fence."; return }
        let globalID = DeviceGlobalID(home: home, session: sessionID).string
        for peer in peers.values where peer.trustedReady && peer.leasedSessions.contains(sessionID) {
            peer.leasedSessions.remove(sessionID)
            sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseStolen.rawValue, boot: boot, sessionID: globalID, epoch: result.epoch))
        }
        publishSidebarIfChanged()
    }
    @discardableResult
    func sendRemoteCommand(globalID: String, command: DeviceCommandPayload) -> UUID? {
        guard let global = DeviceGlobalID(globalID), let epoch = remoteLeases[globalID], let peer = peerForHome(global.home) else {
            lastOutcome = "Take the session again before sending."; return nil
        }
        guard let payloadData = try? JSONEncoder().encode(command) else { return nil }
        let record = DeviceOutboxRecord(commandID: UUID(), sessionID: globalID, payload: command, payloadHash: DeviceBlob.sha256Hex(payloadData), epoch: epoch)
        do { try outboxStore?.add(record); outbox = outboxStore?.records ?? outbox } catch { lastOutcome = "Could not save outgoing message. Nothing sent."; return nil }
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: globalID, commandID: record.commandID, epoch: epoch, payload: payloadData))
        return record.commandID
    }
    func retryOutbox(_ record: DeviceOutboxRecord) {
        guard record.outcome == "pending", let global = DeviceGlobalID(record.sessionID), let epoch = remoteLeases[record.sessionID], let peer = peerForHome(global.home),
              let payloadData = try? JSONEncoder().encode(record.payload) else { lastOutcome = "Take the session again before retrying."; return }
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: record.sessionID, commandID: record.commandID, epoch: epoch, payload: payloadData))
    }
    func queryOutbox(_ record: DeviceOutboxRecord) {
        guard let global = DeviceGlobalID(record.sessionID), let peer = peerForHome(global.home) else { return }
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.commandQuery.rawValue, sessionID: record.sessionID, commandID: record.commandID, epoch: record.epoch))
    }
    func discardOutbox(_ record: DeviceOutboxRecord) { try? outboxStore?.remove(commandID: record.commandID); outbox = outboxStore?.records ?? outbox }
    func unresolved(globalID: String) -> [DeviceOutboxRecord] { outbox.filter { $0.sessionID == globalID } }
    func sendRemoteDraft(globalID: String, text: String) {
        guard let global = DeviceGlobalID(globalID), let epoch = remoteLeases[globalID], let peer = peerForHome(global.home) else { return }
        let version = drafts.bump(session: globalID, text: text); persistDrafts()
        let payload = try? JSONEncoder().encode(DeviceDraftPayload(version: version, text: text, imageHashes: draftAttachments[globalID] ?? []))
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.draftPatch.rawValue, sessionID: globalID, epoch: epoch, payload: payload))
    }
    func saveDraftAttachments(globalID: String, hashes: [String]) {
        draftAttachments[globalID] = hashes; persistDrafts()
        if hashes.allSatisfy({ blobReady[$0] == true }), let text = drafts.text(session: globalID) ?? remoteTranscripts[globalID]?.draft {
            sendRemoteDraft(globalID: globalID, text: text)
        }
    }
    func queryBlob(globalID: String, hash: String) {
        guard let global = DeviceGlobalID(globalID), let epoch = remoteLeases[globalID], let peer = peerForHome(global.home) else { return }
        pendingUploads.insert(hash)
        let payload = try? JSONEncoder().encode(DeviceBlobPayload(sha256Hex: hash))
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.blobOffer.rawValue, sessionID: globalID, epoch: epoch, payload: payload))
    }
    func requestEarlier(globalID: String) {
        guard let global = DeviceGlobalID(globalID), let epoch = remoteLeases[globalID], let peer = peerForHome(global.home),
              let current = remoteTranscripts[globalID], current.offset > 0 else { return }
        let payload = try? JSONEncoder().encode(DeviceTranscriptRequest(beforeOffset: current.offset))
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.transcriptRequest.rawValue, sessionID: globalID, epoch: epoch, payload: payload))
    }
    func fetchBlob(globalID: String, hash: String) {
        guard blobCache[hash] == nil, !pendingDownloads.contains(hash), let global = DeviceGlobalID(globalID), let epoch = remoteLeases[globalID], let peer = peerForHome(global.home) else { return }
        pendingDownloads.insert(hash)
        let payload = try? JSONEncoder().encode(DeviceBlobPayload(sha256Hex: hash))
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.blobRequest.rawValue, sessionID: globalID, epoch: epoch, payload: payload))
    }
    func sendRemoteBlob(globalID: String, data: Data) -> String? {
        guard data.count <= DeviceBlob.maxBlob, let global = DeviceGlobalID(globalID),
              let epoch = remoteLeases[globalID], let peer = peerForHome(global.home) else { return nil }
        let hash = DeviceBlob.sha256Hex(data); blobReady[hash] = false; pendingUploads.insert(hash)
        var offset = 0
        while offset < data.count {
            let chunk = Data(data.dropFirst(offset).prefix(32_768)); offset += chunk.count
            let payload = try? JSONEncoder().encode(DeviceBlobPayload(sha256Hex: hash, size: data.count, chunk: chunk, done: offset >= data.count))
            sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.blobChunk.rawValue, sessionID: globalID, epoch: epoch, payload: payload))
        }
        return hash
    }
}


