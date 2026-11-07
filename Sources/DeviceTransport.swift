import Combine
import CryptoKit
import Foundation
import Network
import os

private let lotSyncLog = Logger(subsystem: "local.richard.Converse", category: "lotsync")

struct DiscoveredDevice: Identifiable, Equatable {
    var id: String { endpoint.debugDescription }
    var name: String
    var endpoint: NWEndpoint
    var group: ConverseGroup? = nil
    var deviceID: String? = nil
    static func == (a: DiscoveredDevice, b: DiscoveredDevice) -> Bool { a.id == b.id && a.name == b.name && a.group == b.group && a.deviceID == b.deviceID }
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
    var actionLabel: String { "Pair" }
    var instruction: String {
        isInitiator ? "Compare all eight code groups with a reviewing group member, then press Pair on both devices." : "Compare all eight code groups with the requesting device, then press Pair on both devices."
    }
}

struct RemoteHomeState: Equatable {
    var deviceID: String
    var deviceName: String
    var online = false
    var rows: [DeviceSidebarRow] = []
    var lastSeen: Date? = nil
}

/// What a paired device's authenticated hello reported about its own install.
struct DeviceInstalledVersion: Equatable {
    var version: String
    var build: String?
    var observedAt: Date
    var versionBuild: String? { build.map { version + " (" + $0 + ")" } }
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
    var joiningGroupID: String?
    var wantsJoin = false
    var admissionGroup: ConverseGroup?
    var controlOnly = false
    var trustedReady = false
    var humanConfirmed = false
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
    @Published var currentGroup: ConverseGroup?
    @Published var knownGroups: [ConverseGroup] = []
    @Published var groupRequests: [GroupJoinRequest] = [] {
        didSet {
            #if os(macOS)
            let previous = Set(oldValue.map(\.id))
            if !isTestEnvironment && groupRequests.contains(where: { !$0.approved && !previous.contains($0.id) }) {
                DispatchQueue.main.async { AppDelegate.shared?.showDeviceConnect() }
            }
            #endif
        }
    }
    @Published var groupReview: GroupJoinReview?
    private var groupStore: ConverseGroupStore?
    private var sponsoredRequests: [UUID: GroupJoinRequest] = [:]
    var groupsEnabled: Bool { groupStore != nil }
    @Published var discovered: [DiscoveredDevice] = []
    @Published var trusted: [TrustedDevice] = []
    @Published var homes: [String: RemoteHomeState] = [:]
    /// Last installed version each paired device reported after trust was
    /// established, kept across disconnects for this launch only.
    private(set) var installedVersions: [String: DeviceInstalledVersion] = [:]
    @Published var pairingPrompt: PairingPrompt?
    private var waitingPairings: [PairingPrompt] = []
    var pairingRequestCount: Int { waitingPairings.count + (pairingPrompt == nil ? 0 : 1) }
    @Published var remoteLeases: [String: UInt64] = [:]
    @Published var remoteTranscripts: [String: DeviceTranscriptPayload] = [:]
    #if os(iOS)
    // Newest whole-document lot rows, unmerged. The transcript merge keeps paged
    // session history; a lot snapshot always replaces the document it describes.
    @Published var remoteLotSnapshots: [String: [DeviceWireMessage]] = [:]
    #endif
    @Published var remoteOffline: Set<String> = []
    @Published private(set) var remoteSeen = RemoteSeenWatermarks()
    @Published var outbox: [DeviceOutboxRecord] = []
    @Published var blobReady: [String: Bool] = [:]
    @Published var blobCache: [String: URL] = [:]
    // Mac-hosted editable lots are enabled; the override supports legacy interop fixtures.
    var editableLotsEnabled = ProcessInfo.processInfo.environment["CONVERSE_EDITABLE_LOTS"] != "0"
    @Published var lotEditors: [String: LotEditQueue] = [:]
    // Manual recovery only; never replay into a new authority epoch.
    @Published var lotRecovery: [String: ParkingLotDocument] = [:]
    @Published var lotBlobReady: [String: Set<String>] = [:]
    private var lotPendingUploads: [String: [String: UInt64]] = [:]
    @Published var lotProposals: [String: LotProposalPreview] = [:]
    private var lotRenewed: [String: Date] = [:]
    private var lotSent: [String: Date] = [:]
    private var lotStarted: [String: Date] = [:]
    @Published var lotNotices: [String: String] = [:]
    private var lotReleases: Set<String> = []
    private var lotHandoffs: Set<String> = []
    #if os(macOS)
    private var lotStreams: [UUID: LotHomeStream] = [:]
    private var lotTransfers: [UUID: LotTransfer] = [:]
    private var lotProposalRequests: [UUID: LotHomeProposal] = [:]
    private var lotWritePermit: Set<UUID> = []
    private var lotUploads: [String: Data] = [:]
    private var lotImagePaths: [UUID: [String: String]] = [:]
    #endif
    @Published var lastOutcome = ""
    @Published var serviceStatus = "Device sync off"
    @Published var localCodeNote = ""

    // Platform adapters keep the reviewed transport identical on Mac and iPad.
    #if os(macOS)
    var participantStore: Store { storeOverride ?? .shared }
    var storeOverride: Store?
    var parkingLibraryOverride: ParkingLotLibrary?
    var parkingLibrary: ParkingLotLibrary { parkingLibraryOverride ?? .shared }
    #endif
    var deviceNameOverride: String?
    var isPlaced: ((String) -> Bool)?
    var onRemotePark: ((String) -> Void)?
    @Published var localNetworkDenied = false
    private var testFolder: URL?
    var storageFolder: URL {
        if let testFolder { return testFolder }
        #if os(macOS)
        return Store.shared.folder
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Converse")
        #endif
    }
    private var locallyRemoved: Bool { trustStore?.records.first(where: { $0.deviceID == identity?.deviceID })?.removed == true }
    private var deviceName: String { deviceNameOverride ?? identity?.deviceName ?? "Converse" }
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
    private var lastSidebarSnapshot: DeviceSidebarPayload?
    private var stagedBlobs: [String: Data] = [:]
    private var blobPaths: [String: String] = [:]
    private var downloadBuffers: [String: Data] = [:]
    private var imageHashCache: [String: String] = [:]
    @Published var participantIntents: [DeviceParticipantIntent] = []
    private var participantReplies: [UUID: (home: String, group: String, finish: (DeviceParticipantResponse) -> Void)] = [:]
    private var pendingTells: [UUID: (source: UUID, home: String, group: String)] = [:]
    var switchboardQueueReports: [String: (report: DeviceQueueWatchReport, at: Date)] = [:]
    private var pendingTakes: [String: Date] = [:]
    private var resumeEpochs: [String: UInt64] = [:]
    private var leaseBoots: [String: UInt64] = [:]
    private var pendingUploads: Set<String> = []
    private var recoveredUploads: [String: [String: UInt64]] = [:]
    private var pendingDownloads: Set<String> = []
    private var pendingAsyncAcks: [(commandID: UUID, peerID: UUID, sessionID: String, homeSession: UUID, epoch: UInt64)] = []
    @Published var draftConflicts: [String: String] = [:]
    @Published var completedCommands: Set<UUID> = []
    #if os(macOS)
    var imageAssistAPI = AgentAPI()
    var imageAssistKey: () throws -> String? = { try AgentSecrets.read("meta") }
    #endif
    private var imageAssistInFlight = Set<UUID>()
    @Published var draftAttachments: [String: [String]] = [:]
    private var lastSeqByHome: [String: UInt64] = [:]
    private var tickCount = 0
    private var started = false
    var isTestEnvironment: Bool { ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    // Isolated harness wiring without listener, browser, timers, or Keychain.
    func configureForTesting(folder: URL) throws {
        editableLotsEnabled = false // Each editing fixture opts in explicitly.
        testFolder = folder
        #if os(macOS)
        parkingLibraryOverride = ParkingLotLibrary(folder: folder.appendingPathComponent("parking-test-profile"))
        #endif
        loadResumeEpochs(); loadRemoteSeen()
        identity = try DeviceIdentity.loadOrCreate(folder: folder, useKeychain: false)
        trustStore = try DeviceTrustStore(folder: folder)
        commandStore = try DeviceCommandStore(folder: folder)
        stateStore = try DeviceSyncStateStore(folder: folder)
        draftStore = try DeviceDraftStore(folder: folder)
        outboxStore = try DeviceOutboxStore(folder: folder)
        try loadParticipantIntents()
        boot = stateStore?.beginBoot() ?? 0
        let store = stateStore
        leases = DeviceLeaseManager(initialEpochs: store?.loadedEpochs ?? [:]) { store?.saveEpochs($0) == true }
        started = true
    }
    func adoptPeerForTesting(_ peer: DevicePeer) { peers[peer.id] = peer }
    var testingPort: UInt16? { listener?.port.flatMap { $0.rawValue > 0 ? $0.rawValue : nil } }
    private var testingDiscoveryPrefix: String?
    func startNetworkForTesting(discoveryPrefix: String? = nil) throws {
        guard isTestEnvironment, testFolder != nil else { throw CocoaError(.executableNotLoadable) }
        if let discoveryPrefix {
            guard discoveryPrefix.hasPrefix("QA-"), discoveryPrefix.count <= 20 else { throw CocoaError(.coderInvalidValue) }
            testingDiscoveryPrefix = discoveryPrefix
        }
        try startListener(portOverride: .any)
        if discoveryPrefix != nil { startBrowser() }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        publishTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.publishSidebarIfChanged() }
    }

    func startIfNeeded() {
        guard !started, !isTestEnvironment else { return }
        started = true
        do {
            let folder = storageFolder
            if Bundle.main.object(forInfoDictionaryKey: "ConverseNUXPreview") as? Bool == true { deviceNameOverride = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Converse Setup Preview" }
            loadResumeEpochs(); loadRemoteSeen()
            identity = try DeviceIdentity.loadOrCreate(folder: folder, useKeychain: true)
            trustStore = try DeviceTrustStore(folder: folder)
            try initializeGroups(folder: folder)
            commandStore = try DeviceCommandStore(folder: folder)
            stateStore = try DeviceSyncStateStore(folder: folder)
            draftStore = try DeviceDraftStore(folder: folder)
            outboxStore = try DeviceOutboxStore(folder: folder)
            outbox = outboxStore?.records ?? []
            try loadParticipantIntents()
            boot = stateStore?.beginBoot() ?? 0
            let store = stateStore
            leases = DeviceLeaseManager(initialEpochs: store?.loadedEpochs ?? [:]) { store?.saveEpochs($0) == true }
            let savedDrafts = draftStore?.load() ?? DeviceDraftFile()
            drafts.restore(versions: savedDrafts.versions, texts: savedDrafts.texts)
            draftAttachments = savedDrafts.attachments
            rebuildBlobPaths(folder: folder)
            refreshGroupMembers()
            for device in trusted { homes[device.deviceID] = RemoteHomeState(deviceID: device.deviceID, deviceName: device.name) }
            if let cache = stateStore?.state.sidebarCache, let payloads = try? JSONDecoder().decode([DeviceSidebarPayload].self, from: cache) {
                for payload in payloads where homes[payload.homeDeviceID] != nil {
                    homes[payload.homeDeviceID]?.rows = payload.rows
                    for row in payload.rows { remoteOffline.insert(row.globalID) }
                }
            }
            try startListener()
            startBrowser()
            serviceStatus = "Listening as " + (deviceName)
            localCodeNote = "Fingerprint " + (identity?.fingerprint ?? "")
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
            publishTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.publishSidebarIfChanged() }
            reconnectTrusted()
        } catch { serviceStatus = "Device sync unavailable: " + error.localizedDescription }
    }

    private func startListener(portOverride: NWEndpoint.Port? = nil) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let requested = ProcessInfo.processInfo.environment["CONVERSE_DEVICE_PORT"].flatMap { Int($0) }.flatMap { (1...65535).contains($0) ? NWEndpoint.Port(rawValue: UInt16($0)) : nil } ?? Self.defaultPort
        #if os(macOS)
        let listenPort = Bundle.main.object(forInfoDictionaryKey: "ConverseNUXPreview") as? Bool == true ? NWEndpoint.Port.any : requested
        #else
        let listenPort = NWEndpoint.Port.any
        _ = requested
        #endif
        let listener = try NWListener(using: parameters, on: portOverride ?? listenPort)
        listener.service = groupAdvertisement()
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.serviceStatus = "Listen failed: " + error.localizedDescription }
            if case .ready = state, let port = self?.listener?.port {
                self?.serviceStatus = "Listening on port " + String(port.rawValue)
                self?.updateGroupAdvertisement()
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }
    private func startBrowser() {
        // Plain .bonjour omits TXT metadata, which contains device/group IDs
        // and the group name. It also misses group changes on an existing service.
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: NWParameters.tcp)
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting(let error), .failed(let error):
                // TN3179: this specific Bonjour policy error means permission
                // was denied. Other connectivity failures must not claim that.
                if case .dns(let code) = error, code == -65570 {
                    self?.localNetworkDenied = true
                    self?.serviceStatus = "Local Network access is off. Enable it in Settings to connect."
                }
            case .ready: self?.localNetworkDenied = false
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.discovered = results.compactMap { result in
                if case .service(let name, _, _, _) = result.endpoint, !name.hasSuffix("[" + String((self.identity?.deviceID ?? "").prefix(8)) + "]") {
                    if let prefix = self.testingDiscoveryPrefix, !name.hasPrefix(prefix) { return nil }
                    var group: ConverseGroup?
                    var deviceID: String?
                    if case .bonjour(let txt) = result.metadata, case .string(let id) = txt.getEntry(for: "device"), id.count == 64, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) { deviceID = id }
                    if case .bonjour(let txt) = result.metadata,
                       case .string(let id) = txt.getEntry(for: "group"),
                       case .string(let label) = txt.getEntry(for: "name"),
                       case .string(let creator) = txt.getEntry(for: "creator") {
                        let candidate = ConverseGroup(id: id, name: label, creator: creator)
                        if candidate.valid { group = candidate }
                    }
                    return DiscoveredDevice(name: name, endpoint: result.endpoint, group: group, deviceID: deviceID)
                }
                return nil
            }.sorted { $0.name < $1.name }
            self.reconnectTrusted()
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
        guard (!groupsEnabled || currentGroup != nil), trustStore?.records.first(where: { $0.deviceID == identity?.deviceID })?.removed != true else { return }
        for device in trusted where homes[device.deviceID]?.online != true {
            if let found = discovered.first(where: { $0.name.hasSuffix("[" + String(device.deviceID.prefix(8)) + "]") || $0.name == device.name }) { connect(discovered: found) }
            else if let host = device.lastHost, let port = device.lastPort { connectManual(host: host, port: port) }
        }
    }
    private func connect(to endpoint: NWEndpoint, displayName: String, manualHost: String? = nil, manualPort: Int? = nil, joiningGroupID: String? = nil, wantsJoin: Bool = false) {
        guard let identity else { return }
        if peers.values.contains(where: { $0.connection.endpoint == endpoint && $0.alive }) { return }
        let connection = NWConnection(to: endpoint, using: .tcp)
        let peer = DevicePeer(connection: connection, isInitiator: true, displayName: displayName, manualHost: manualHost, manualPort: manualPort)
        peer.joiningGroupID = joiningGroupID; peer.wantsJoin = wantsJoin
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
    private func helloPayload(_ peer: DevicePeer) -> Data {
        var hello = DeviceHello(deviceID: identity?.deviceID ?? "", deviceName: deviceName,
                                converseVersion: ConverseAbout.version, converseBuild: ConverseAbout.build, listenPort: listener?.port.flatMap { $0.rawValue > 0 ? Int($0.rawValue) : nil })
        #if os(macOS)
        hello.capabilities.append(contentsOf: ["agent-host-v1", "switchboard-supervision-v1", "image-assist-v1", "image-segments-v1", "transcript-export-v1", "agent-art-direction-v1"])
        #endif
        hello.capabilities.append(contentsOf: ["participant-control-v1", "agent-schedule-v1"])
        #if os(macOS)
        hello.capabilities.append("session-close-v1")
        hello.capabilities.append("session-rename-v1")
        hello.capabilities.append("session-create-v1")
        hello.capabilities.append(Self.queueRemoveCapability)
        #endif
        if editableLotsEnabled { hello.capabilities.append(LotEditing.capability) }
        hello.group = currentGroup
        hello.joinGroupID = peer.wantsJoin ? peer.joiningGroupID : nil
        return (try? JSONEncoder().encode(hello)) ?? Data()
    }
    func helloCapabilitiesForTesting(_ peer: DevicePeer) -> [String] { (try? JSONDecoder().decode(DeviceHello.self, from: helloPayload(peer)))?.capabilities ?? [] }
    private func sendHandshake(_ peer: DevicePeer) {
        do {
            guard var handshake = peer.handshake else { return }
            let message = try handshake.writeMessage(payload: helloPayload(peer))
            peer.handshake = handshake; sendRaw(peer, message)
        } catch { disconnect(peer) }
    }
    private func sendRaw(_ peer: DevicePeer, _ message: Data, completion: ((Bool) -> Void)? = nil) {
        guard message.count <= 65535 else { completion?(false); disconnect(peer); return }
        if let testSink = peer.testSink { testSink(message); completion?(true); return }
        let framed = Data([UInt8((message.count >> 8) & 255), UInt8(message.count & 255)])
        peer.connection.send(content: framed + message, completion: .contentProcessed { [weak self, weak peer] error in
            completion?(error == nil)
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
            let length = peer.buffer.prefix(2).reduce(0) { ($0 << 8) | Int($1) }
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
                    if peer.wantsJoin, peer.joiningGroupID == nil { peer.joiningGroupID = hello.group?.id }
                }
                var probe = handshake
                if (try? probe.finish()) == nil {
                    let reply = try handshake.writeMessage(payload: helloPayload(peer))
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
        guard hello.deviceID == DeviceBlob.sha256Hex(keys.remoteStatic), hello.deviceID != identity?.deviceID else { disconnect(peer); return }
        // Simultaneous connects choose the same socket at both ends. An
        // established socket wins; otherwise the lower identity initiates.
        let preferInitiator = (identity?.deviceID ?? "") < hello.deviceID
        for other in Array(peers.values) where other.id != peer.id && other.alive && other.keys != nil && other.hello?.deviceID == hello.deviceID {
            if other.trustedReady || (other.isInitiator == preferInitiator && peer.isInitiator != preferInitiator) {
                disconnect(peer, preserveDeviceState: true); return
            }
            disconnect(other, preserveDeviceState: true)
        }
        if groupsEnabled {
            guard hello.capabilities.contains("converse-groups-v1") else { lastOutcome = "Update the other device to use Converse Groups."; disconnect(peer); return }
            if peer.wantsJoin {
                guard let group = hello.group, group.valid, !group.dissolved,
                      peer.joiningGroupID == nil || peer.joiningGroupID == group.id,
                      groupStore?.state.groups.first(where: { $0.id == group.id })?.dissolved != true else { disconnect(peer); return }
                peer.admissionGroup = group
                offerPairing(peer)
                return
            }
            if let group = currentGroup, hello.joinGroupID == group.id {
                pruneGroupRequests()
                guard sponsoredRequests.count < 16 else { disconnect(peer); return }
                let request = GroupJoinRequest(id: peer.id, groupID: group.id, requesterID: hello.deviceID,
                                               requesterName: String(hello.deviceName.prefix(100)), sponsorID: identity?.deviceID ?? "", expiresAt: Date().addingTimeInterval(180))
                sponsoredRequests[peer.id] = request; groupRequests.append(request)
                publishGroupRequests(); return
            }
            // Group identity and pinned device identity must both match. Old
            // trust can carry a dissolution notice, never session traffic.
            let known = trustStore.records.first { $0.deviceID == hello.deviceID && $0.publicKey == keys.remoteStatic }
            if let group = currentGroup, hello.group?.id == group.id, known?.groupID == group.id {
                // Continue to the existing removed-member admission rules.
            } else if let known, let id = known.groupID, (groupStore?.state.groups.first(where: { $0.id == id })?.dissolved == true && hello.group?.id == id) || currentGroup?.id == id {
                // A remembered member may have dissolved our stale group and
                // already created another. Authenticate a state-only channel to
                // learn its tombstone; this grants no access to either group's sessions.
                peer.controlOnly = true
            } else { disconnect(peer); return }
            // Only the explicit join paths above may request human admission.
            // Reconnect must never turn an unknown/revoked pin into a generic
            // pairing prompt that bypasses group-wide Review.
            guard !locallyRemoved, trustStore.check(deviceID: hello.deviceID, publicKey: keys.remoteStatic) == .trusted else { disconnect(peer); return }
        }
        let removedLocally = trustStore.records.first { $0.deviceID == identity?.deviceID }?.removed == true
        switch removedLocally ? DeviceTrustCheck.unknown : trustStore.check(deviceID: hello.deviceID, publicKey: keys.remoteStatic) {
        case .trusted:
            peer.localConfirmed = true
            sendEnvelope(peer, DeviceEnvelope(kind: "pair.confirm")); finishTrustIfReady(peer)
        case .unknown, .keyChanged:
            offerPairing(peer)
        }
    }

    private func offerPairing(_ peer: DevicePeer) {
        guard let hello = peer.hello, let keys = peer.keys, let trustStore else { return }
        let prompt = PairingPrompt(connectionID: peer.id, peerName: hello.deviceName,
                              fingerprint: String(hello.deviceID.prefix(16)).uppercased(),
                              code: DeviceSAS.code(keys.handshakeHash),
                              keyChanged: trustStore.check(deviceID: hello.deviceID, publicKey: keys.remoteStatic) == .keyChanged,
                              nameCollision: trustStore.hasNameCollision(name: hello.deviceName, deviceID: hello.deviceID), isInitiator: peer.isInitiator)
        if pairingPrompt == nil { pairingPrompt = prompt } else { waitingPairings.append(prompt) }
        #if os(macOS)
        if !peer.isInitiator, !isTestEnvironment {
            DispatchQueue.main.async { AppDelegate.shared?.showDeviceConnect() }
        }
        #endif
    }
    func confirmPairing() {
        guard let prompt = pairingPrompt, let peer = peers[prompt.connectionID] else { return }
        peer.humanConfirmed = true; peer.localConfirmed = true
        serviceStatus = "Waiting for the other Pair confirmation…"
        sendEnvelope(peer, DeviceEnvelope(kind: "pair.confirm")); advancePairing(removing: peer.id); finishTrustIfReady(peer)
    }
    func rejectPairing() {
        guard let prompt = pairingPrompt, let peer = peers[prompt.connectionID] else { pairingPrompt = nil; return }
        disconnect(peer)
    }
    private func advancePairing(removing id: UUID) {
        waitingPairings.removeAll { $0.connectionID == id }
        if pairingPrompt?.connectionID == id { pairingPrompt = waitingPairings.isEmpty ? nil : waitingPairings.removeFirst() }
    }
    private func finishTrustIfReady(_ peer: DevicePeer) {
        guard peer.localConfirmed, peer.remoteConfirmed, !peer.trustedReady, let hello = peer.hello, let keys = peer.keys else { return }
        do {
            if groupsEnabled, peer.wantsJoin {
                guard peer.humanConfirmed, let group = peer.admissionGroup else { disconnect(peer); return }
                try activateGroup(group, keeping: peer.id)
            }
            guard trustStore?.check(deviceID: hello.deviceID, publicKey: keys.remoteStatic) == .trusted || peer.humanConfirmed else { disconnect(peer); return }
            var host = peer.manualHost
            if host == nil, case .hostPort(let endpointHost, _) = peer.connection.endpoint { host = String(describing: endpointHost) }
            try trustStore?.pin(deviceID: hello.deviceID, name: hello.deviceName, publicKey: keys.remoteStatic, host: host, port: hello.listenPort ?? peer.manualPort, issuer: identity?.deviceID, allowAdmission: peer.humanConfirmed, groupID: groupsEnabled ? (peer.controlOnly ? trustStore?.records.first(where: { $0.deviceID == hello.deviceID })?.groupID : currentGroup?.id ?? hello.group?.id) : nil)
            if !peer.controlOnly, let identity, trustStore?.records.first(where: { $0.deviceID == identity.deviceID })?.removed != true {
                try trustStore?.pin(deviceID: identity.deviceID, name: deviceName, publicKey: identity.publicKey, issuer: identity.deviceID, groupID: groupsEnabled ? currentGroup?.id : nil)
            }
            refreshGroupMembers()
        } catch {
            lastOutcome = "Could not save paired device. Control not granted."
            disconnect(peer); return
        }
        peer.trustedReady = true
        installedVersions[hello.deviceID] = DeviceInstalledVersion(version: hello.converseVersion, build: hello.converseBuild, observedAt: Date())
        if groupsEnabled {
            sendGroupState(peer)
            if peer.controlOnly { return }
            withdrawGroupRequest(peer.id)
        }
        homes[hello.deviceID] = RemoteHomeState(deviceID: hello.deviceID, deviceName: hello.deviceName, online: true, rows: homes[hello.deviceID]?.rows ?? [], lastSeen: Date())
        if !locallyRemoved { sendSidebar(to: peer) }
        broadcastFabric()
        serviceStatus = locallyRemoved ? "Membership exchange only. Fresh sponsor approval is required to rejoin." : "Connected to " + hello.deviceName + ". Previously displayed sessions restore if nobody else took them."
    }
    private func broadcastFabric() {
        guard let records = trustStore?.records, let data = try? JSONEncoder().encode(records.filter { !groupsEnabled || $0.groupID == currentGroup?.id }) else { return }
        for peer in Array(peers.values) where peer.trustedReady && !peer.controlOnly && (!groupsEnabled || currentGroup != nil) && peer.hello?.capabilities.contains("fabric-membership-v1") == true {
            sendEnvelope(peer, DeviceEnvelope(kind: "fabric.members", payload: data))
        }
    }
    func forgetDevice(_ device: TrustedDevice) {
        do {
            try trustStore?.forget(deviceID: device.deviceID, issuer: identity?.deviceID)
            refreshGroupMembers()
            homes.removeValue(forKey: device.deviceID)
            for peer in Array(peers.values) where peer.hello?.deviceID == device.deviceID { disconnect(peer) }
            broadcastFabric()
        } catch { lastOutcome = "Could not forget device: " + error.localizedDescription }
    }
    /// Read-only device directory for export scrubbing; never exported itself.
    var trustedDevicesForScrubbing: [TrustedDevice] { trustStore?.devices ?? [] }
    func displayName(for id: String, fallback: String? = nil) -> String {
        let record = trustStore?.devices.first { $0.deviceID == id && $0.groupID == currentGroup?.id }
        return record?.displayName ?? fallback ?? (id == identity?.deviceID ? deviceName : homes[id]?.deviceName ?? record?.name ?? String(id.prefix(8)))
    }
    /// Installed Converse versions for agents: this device's own build plus what
    /// each paired device last reported in an authenticated hello. A device
    /// that has not connected since launch, or whose release predates build
    /// reporting, is marked unverified rather than guessed.
    func installedVersionEvidence(localVersion: String = ConverseAbout.versionBuild, now: Date = Date()) -> [String: Any] {
        let stamp = ISO8601DateFormatter()
        let devices: [[String: Any]] = trusted.sorted { displayName(for: $0.deviceID) < displayName(for: $1.deviceID) }.map { device in
            var item: [String: Any] = ["name": displayName(for: device.deviceID), "connectedNow": homes[device.deviceID]?.online == true]
            if let observed = installedVersions[device.deviceID] {
                item["installedVersion"] = observed.versionBuild ?? "unverified: this device's release does not report its build"
                item["observedAt"] = stamp.string(from: observed.observedAt)
            } else {
                item["installedVersion"] = "unknown: not connected since this Converse started"
            }
            return item
        }
        return ["thisDevice": ["name": deviceName, "installedVersion": localVersion, "observedAt": stamp.string(from: now)], "pairedDevices": devices]
    }
    func canRenameDevice(_ id: String) -> Bool {
        currentGroup != nil && !locallyRemoved && trustStore?.devices.contains { $0.deviceID == id && $0.groupID == currentGroup?.id } == true
    }
    func renameDeviceDisplayName(_ id: String, name: String) throws {
        guard canRenameDevice(id), let group = currentGroup, let identity, let trustStore else { throw CocoaError(.coderInvalidValue) }
        try trustStore.renameDisplay(deviceID: id, groupID: group.id, name: name, issuer: identity.deviceID)
        refreshGroupMembers(); broadcastFabric(); objectWillChange.send()
    }
    func deviceDetails(_ id: String) -> String {
        let record = trustStore?.devices.first { $0.deviceID == id && $0.groupID == currentGroup?.id }
        let local = id == identity?.deviceID
        let reported = local ? deviceName : homes[id]?.deviceName ?? record?.name ?? "Unknown"
        let status = local ? "This device" : homes[id]?.online == true ? "Online" : "Offline"
        let endpoint = record?.lastHost.map { "\nLast address: " + $0 + (record?.lastPort.map { ":" + String($0) } ?? "") } ?? ""
        return displayName(for: id, fallback: reported) + "\nReported name: " + reported + "\n" + status +
            "\nGroup: " + (currentGroup?.name ?? "None") + "\nDevice ID: " + id + endpoint
    }
    private func sendEnvelope(_ peer: DevicePeer, _ envelope: DeviceEnvelope, completion: ((Bool) -> Void)? = nil) {
        guard peer.alive, var keys = peer.keys else { completion?(false); return }
        // Network callbacks use the connection's main queue. Count every chunk
        // so a large acknowledgment produces one completion, including failure.
        var remaining = 0
        var completed = false
        func finish(_ success: Bool) {
            guard !completed else { return }
            if !success { completed = true; completion?(false); return }
            remaining -= 1
            if remaining == 0 { completed = true; completion?(true) }
        }
        do {
            let framed = try DeviceFrame.encode(envelope)
            remaining = (framed.count + 59_999) / 60_000
            var offset = 0
            while offset < framed.count {
                let chunk = Data(framed.dropFirst(offset).prefix(60_000)); offset += chunk.count
                sendRaw(peer, try keys.sender.encrypt(chunk), completion: completion == nil ? nil : finish)
            }
            peer.keys = keys
        } catch { finish(false); disconnect(peer) }
    }
    private func disconnect(_ peer: DevicePeer, preserveDeviceState: Bool = false) {
        if let home = peer.hello?.deviceID { switchboardQueueReports.removeValue(forKey: home) }
        if sponsoredRequests[peer.id] != nil { withdrawGroupRequest(peer.id) }
        guard peer.alive else { return }
        peer.alive = false; peer.connection.cancel()
        advancePairing(removing: peer.id)
        if !preserveDeviceState, let hello = peer.hello, let device = peer.hello?.deviceID {
            groupRequests.removeAll { $0.sponsorID == device }
            if groupReview?.request.sponsorID == device { groupReview = nil }
            homes[hello.deviceID]?.online = false; homes[hello.deviceID]?.lastSeen = Date()
            // Viewer authority never survives disconnect.
            for row in homes[hello.deviceID]?.rows ?? [] {
                pendingTakes.removeValue(forKey: row.globalID)
                freezeLot(row.globalID, reason: "Home disconnected. Unconfirmed edits are retained here for Copy; take the lot again to resume.", cleanReason: "Home disconnected. No unsaved changes. Reconnecting when home is available…")
                remoteLeases.removeValue(forKey: row.globalID); remoteOffline.insert(row.globalID)
                try? outboxStore?.markUncertain(sessionID: row.globalID)
            }
            outbox = outboxStore?.records ?? outbox
            // Home leases held by this peer end immediately.
            if let leases { for sessionID in peer.leasedSessions {
                #if os(macOS)
                // A mobile editor may not have observed the dropped socket yet.
                // Let its bounded lease expire before allowing another writer.
                if editableLotsEnabled && parkingLibrary.lot(sessionID) != nil { continue }
                #endif
                if leases.holder(session: sessionID)?.device == device { leases.release(session: sessionID, device: device, epoch: leases.holder(session: sessionID)?.epoch ?? 0) }
            } }
            _ = device
        }
        peers.removeValue(forKey: peer.id)
    }
    private func tick() {
        tickLots()
        tickCount += 1
        let now = Date()
        if pruneGroupRequests(at: now) { publishGroupRequests() }
        for peer in Array(peers.values) {
            if !peer.trustedReady && now.timeIntervalSince(peer.startedAt) > 180 { disconnect(peer); continue }
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
                        sendEnvelope(peer, DeviceEnvelope(kind: peer.hello?.capabilities.contains("lease-resume-v1") == true ? DeviceMessageKind.leaseExpired.rawValue : DeviceMessageKind.leaseStolen.rawValue, sessionID: DeviceGlobalID(home: home, session: expired.session).string, epoch: expired.epoch))
                    }
                }
            }
        }
        // Leases for sessions no longer placed anywhere are released, so a
        // displaced or parked remote pane cannot heartbeat forever.
        for globalID in Array(remoteLeases.keys) where !viewerHasPlacement(globalID) {
            releaseRemote(globalID: globalID)
        }
        restoreAvailableDisplays()
        for (globalID, epoch) in remoteLeases {
            guard let global = DeviceGlobalID(globalID), let peer = peerForHome(global.home) else { continue }
            sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseHeartbeat.rawValue, sessionID: globalID, epoch: epoch))
        }
        #if os(macOS)
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
        #endif
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
    #if os(macOS)
    private func wireMessage(_ message: Message) -> DeviceWireMessage {
        DeviceWireMessage(id: message.id, role: message.role, text: message.text, imageHashes: message.images.compactMap { imageHash(path: $0) }, createdAtUnixSeconds: message.createdAt?.timeIntervalSince1970)
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
    #endif
    #if os(macOS)
    func homeSessionClosed(_ sessionID: UUID) {
        guard let home = identity?.deviceID else { return }
        if let holder = leases?.holder(session: sessionID) {
            leases?.release(session: sessionID, device: holder.device, epoch: holder.epoch)
        }
        let globalID = DeviceGlobalID(home: home, session: sessionID).string
        for peer in peers.values where peer.trustedReady && !peer.controlOnly {
            peer.leasedSessions.remove(sessionID)
            // Existing displacement semantics also clear older viewers promptly.
            sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseStolen.rawValue, boot: boot, sessionID: globalID))
        }
        publishSidebarIfChanged()
    }
    #endif
    private func discardRemoteDisplay(_ id: String) {
        freezeLot(id, reason: "This lot moved or closed. Unconfirmed changes remain available to copy.", cleanReason: "This lot moved or closed. All changes were saved on home.")
        forgetDisplay(id)
        pendingTakes.removeValue(forKey: id)
        remoteLeases.removeValue(forKey: id); leaseBoots.removeValue(forKey: id)
        remoteTranscripts.removeValue(forKey: id); remoteOffline.remove(id)
        #if os(iOS)
        remoteLotSnapshots.removeValue(forKey: id)
        #endif
        parkViewer(id)
    }
    private func sidebarPayload() -> DeviceSidebarPayload {
        let home = identity?.deviceID ?? ""
        #if os(macOS)
        let rows = participantStore.sessions.map { session in
            DeviceSidebarRow(globalID: DeviceGlobalID(home: home, session: session.id).string, sessionID: session.id,
                             title: session.title, assistant: session.entry.name, engine: session.entry.engine,
                             model: session.toolStatus.model, effort: session.toolStatus.effort, access: session.toolStatus.access,
                             status: session.status, busy: session.busy, queued: session.pending.count, queuePaused: session.queuePaused,
                             leaseHolder: leases?.holder(session: session.id)?.device, leaseEpoch: leases?.holder(session: session.id)?.epoch,
                             accountName: session.entry.accountName, messagingEnabled: session.switchboardEnabled, participantKind: session.agent == nil ? nil : "agent", attention: session.agent?.attention,
                             loopPaused: session.agent == nil ? nil : session.agentLoopPaused, pausedReason: session.pausedLoopReason, lastResponseAt: session.lastResponseAt,
                             shownOnHome: Workspace.shared.placements[session.id] == nil ? nil : true)
        }
        let availableLotLinks = availableParkingLotLinkIDs
        let parkingRows = parkingLibrary.lots.filter(\.active).map { lot in
            DeviceSidebarRow(globalID: DeviceGlobalID(home: home, session: lot.id).string, sessionID: lot.id,
                             title: lot.name, assistant: "Parking Lot", engine: "parking", model: "", effort: "", access: editableLotsEnabled ? "edit" : "read only",
                             status: editableLotsEnabled ? "Parking Lot" : "Parking Lot · read only", busy: false, queued: 0, queuePaused: false, leaseHolder: editableLotsEnabled ? leases?.holder(session: lot.id)?.device : nil, leaseEpoch: editableLotsEnabled ? leases?.holder(session: lot.id)?.epoch : nil, messagingEnabled: false, participantKind: "parkingLot", linkedSessionIDs: publishedParkingLotLinks(lot.id, available: availableLotLinks), shownOnHome: Workspace.shared.placements[lot.id] != nil)
        }
        #else
        let parkingRows: [DeviceSidebarRow] = []
        let rows: [DeviceSidebarRow] = []
        #endif
        return DeviceSidebarPayload(homeDeviceID: home, homeDeviceName: deviceName, homeSeq: stateStore?.state.homeSeq ?? 0, rows: rows + parkingRows)
    }
    private func sendSidebar(to peer: DevicePeer, snapshot: DeviceSidebarPayload? = nil) {
        guard !groupsEnabled || (!peer.controlOnly && currentGroup != nil && !locallyRemoved) else { return }
        var value = snapshot ?? sidebarPayload()
        value.homeSeq = stateStore?.nextSeq() ?? value.homeSeq
        guard let payload = try? JSONEncoder().encode(value) else { return }
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.sidebarSnapshot.rawValue, homeSeq: value.homeSeq, payload: payload))
    }
    func sidebarPayloadForTesting() -> DeviceSidebarPayload { sidebarPayload() }
    func publishSidebarForTesting() { publishSidebarIfChanged() }
    private func publishSidebarIfChanged() {
        #if os(macOS)
        let measurement = PerformanceCapture.shared.begin()
        defer { PerformanceCapture.shared.end(.sidebarPublish, measurement) }
        #endif
        guard started, peers.values.contains(where: { $0.trustedReady }) else { return }
        // Compare content, not a transport counter. Sending a snapshot itself
        // advances homeSeq; including it caused another send on every idle poll.
        // Equatable also avoids serializing JSON just to detect a change.
        var snapshot = sidebarPayload()
        snapshot.homeSeq = 0
        guard snapshot != lastSidebarSnapshot else { return }
        lastSidebarSnapshot = snapshot
        // Build the shared rows once, instead of again for every connected peer.
        for peer in peers.values where peer.trustedReady { sendSidebar(to: peer, snapshot: snapshot) }
    }
    #if os(macOS)
    func publishSwitchboardQueue(_ sessionID: UUID) {
        for peer in peers.values where peer.trustedReady && peer.leasedSessions.contains(sessionID) {
            sendTranscript(to: peer, sessionID: sessionID)
        }
    }
    private func sendTranscript(to peer: DevicePeer, sessionID: UUID, beforeOffset: Int? = nil) {
        if let lot = parkingLibrary.lot(sessionID), lot.active {
            if editableLotsEnabled { sendLotSnapshot(peer, lot: lot); return }
            guard peer.leasedSessions.contains(sessionID), let home = identity?.deviceID else { return }
            lotSyncLog.debug("lot snapshot rev \(lot.document.revision, privacy: .public) rows \(lot.document.rows.count, privacy: .public) to subscribed viewer")
            let payload = DeviceTranscriptPayload(globalID: DeviceGlobalID(home: home, session: lot.id).string,
                homeSeq: stateStore?.nextSeq() ?? 0, epoch: 0, boot: boot,
                messages: lot.exportMessages.map(wireMessage),
                total: lot.document.rows.count, draft: "", draftVersion: UInt64(max(0, lot.document.revision)), busy: false,
                status: "Parking Lot · read only", title: lot.name, engine: "parking")
            if let data = try? JSONEncoder().encode(payload) {
                sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.transcriptSnapshot.rawValue, homeSeq: payload.homeSeq, boot: boot, sessionID: payload.globalID, epoch: 0, payload: data))
            }
            return
        }
        guard let session = Store.shared.sessions.first(where: { $0.id == sessionID }), let home = identity?.deviceID, let leases, let device = peer.hello?.deviceID else { return }
        // Never stream without a current lease for this exact peer and epoch.
        guard let holder = leases.holder(session: sessionID), holder.device == device else { peer.leasedSessions.remove(sessionID); return }
        if !session.busy, Store.shared.importResponseImages(session) { Store.shared.save() }
        let total = session.messages.count
        let end = min(max(beforeOffset ?? total, 0), total)
        let start = max(0, end - 200)
        let numbers = session.transcriptMessageNumbers()
        let slice = Array(session.messages[start..<end].map { message in
            var wire = wireMessage(message); wire.messageNumber = numbers[message.id]; return wire
        })
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
        var payload = DeviceTranscriptPayload(globalID: DeviceGlobalID(home: home, session: sessionID).string,
                                              homeSeq: stateStore?.nextSeq() ?? 0, epoch: holder.epoch, boot: boot,
                                              messages: slice, offset: start, total: total, prepend: beforeOffset != nil,
                                              draft: session.draft, draftVersion: drafts.version(session: sessionID.uuidString), draftImageHashes: imageHashes,
                                              pending: session.pending.map { DevicePendingDTO(id: $0.id, text: $0.text) },
                                              busy: session.busy, status: session.status, title: session.title, engine: session.entry.engine,
                                              accountName: session.entry.accountName, model: session.toolStatus.model, effort: session.toolStatus.effort, access: session.toolStatus.access,
                                              modelOptions: session.modelChoices.map { DeviceChoiceDTO(id: $0.id, label: $0.label, provider: $0.provider, profile: $0.profile) },
                                              effortOptions: session.availableEfforts,
                                              accessOptions: session.accessChoices.filter(\.available).map { DeviceChoiceDTO(id: $0.id, label: $0.label) },
                                              requests: requestDTOs(session), queuePaused: session.queuePaused, agentWidget: session.agent.map { config in DeviceAgentWidget(summary: config.widgetSummary, metrics: config.scoreboard?.metrics.map { DeviceWidgetMetric(label: $0.label, value: $0.value) } ?? (config.repositorySnapshot?.metrics ?? []).map { DeviceWidgetMetric(label: $0.0, value: $0.1) }, observedAt: config.scoreboard?.observedAt ?? config.repositorySnapshot?.observedAt, attention: config.attention, artHash: config.artPath.flatMap { imageHash(path: $0) }, loopStatus: config.loopStatus(at: Date(), busy: session.busy, queuePaused: session.queuePaused, pendingCount: session.pending.count)) })
        payload.compaction = session.compactionState
        if let data = try? JSONEncoder().encode(payload) {
            sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.transcriptSnapshot.rawValue, homeSeq: payload.homeSeq, boot: boot, sessionID: payload.globalID, epoch: holder.epoch, payload: data))
        }
    }
    private func homeParkingLot(_ envelope: DeviceEnvelope) -> ParkingLotStore? {
        guard let id = envelope.sessionID.flatMap(DeviceGlobalID.init), id.home == identity?.deviceID,
              let lot = parkingLibrary.lot(id.session), lot.active else { return nil }
        return lot
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
        if homeParkingLot(envelope) != nil {
            if let command = envelope.commandID { sendAck(peer, commandID: command, sessionID: envelope.sessionID, outcome: "rejected", detail: "Parking Lots are read only on Group viewers.", epoch: envelope.epoch) }
            return
        }
        guard let (session, _) = homeSession(envelope), let commandID = envelope.commandID,
              let data = envelope.payload, let command = try? JSONDecoder().decode(DeviceCommandPayload.self, from: data) else { return }
        let teaching = command.action == "teachSwitchboard" && envelope.epoch == 0 && peer.hello?.capabilities.contains("switchboard-teach-v1") == true
        guard teaching || requireLease(peer, envelope, session) else { return }
        guard let origin = peer.hello?.deviceID, let commandStore else { return }
        let payloadHash = DeviceBlob.sha256Hex(data)
        let known = ["submit", "inject", "injectAll", "stop", "resumeQueue", "pauseQueue", "clearQueue", "removeQueued", "rename", "model", "effort", "access", "answer", "teachSwitchboard", "compact", "cancelCompact"]
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
        var failure: String?
        var completion = "Applied once on home."
        switch command.action {
        case "teachSwitchboard": store.teachSwitchboard(session)
        case "submit" where session.isUnboundImport:
            failure = "This conversation was imported and has no provider yet. Choose one on its home device first. Nothing was sent."
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
        case "inject":
            if let id = command.pendingID { failure = store.injectPending(session, id: id) }
            else { failure = "Inject not applied: no queued item was specified. Nothing was sent." }
        case "injectAll": failure = store.injectPending(session)
        case "compact": failure = store.requestCompaction(session)
        case "cancelCompact": session.compactionRequested = false
        case "stop": store.stop(session)
        case "resumeQueue": session.queuePaused = false; store.save(); store.runNext(session)
        case "pauseQueue": session.queuePaused = true; store.save()
        case "clearQueue": session.pending = []; store.save()
        case "removeQueued":
            if let id = command.pendingID { failure = store.removePending(session, id: id) }
            else { failure = "Remove not applied: no queued item was specified. Nothing was removed." }
        case "rename":
            // Same path as local rename: title didSet updates identity sidecar.
            if let text = command.text, !text.isEmpty { session.title = text; store.save() }
        case "model":
            if let model = command.model { store.changeSetting(session, .model(MuseModelChoice(id: model, label: model, provider: command.modelProvider ?? session.entry.engine, profile: command.modelProfile, efforts: session.availableEfforts))); asyncSetting = session.changingSetting }
            else if session.entry.engine != "muse" { store.clearOverride(session, field: "model") }
            else { failure = "Choose a model from Muse's catalog." }
        case "effort":
            if let effort = command.effort { store.changeSetting(session, .effort(effort)); asyncSetting = session.changingSetting }
            else if session.entry.engine != "muse" { store.clearOverride(session, field: "effort") }
            else { failure = "Choose an effort supported by the Muse model." }
        case "access":
            if let access = command.access { store.changeSetting(session, .access(access)); asyncSetting = session.changingSetting }
            else if session.entry.engine != "muse" { store.clearOverride(session, field: "access") }
            else { failure = "Choose a Muse permission profile." }
        case "answer":
            if let request = session.requests.first(where: { $0.id == command.requestID }) {
                if let answersJSON = command.answersJSON, let answers = (try? JSONSerialization.jsonObject(with: answersJSON)) as? [[String: Any]] {
                    store.answerMuse(session, request: request, answers: answers)
                } else { store.answerMuse(session, request: request, choice: command.choiceID) }
            }
        default: break
        }
        // Automatic dequeue won the race: the inject completes as a no-op.
        if Store.injectIsNoOp(failure), let detail = failure { completion = detail; failure = nil }
        if let failure {
            do { try commandStore.markFailed(id: commandID) }
            catch { sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: "uncertain", detail: "Nothing was injected, but home could not record the failure. Check home before retrying.", epoch: envelope.epoch); return }
            sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: "failed", detail: failure, epoch: envelope.epoch)
            sendTranscript(to: peer, sessionID: session.id); return
        }
        if asyncSetting {
            pendingAsyncAcks.append((commandID: commandID, peerID: peer.id, sessionID: envelope.sessionID ?? "", homeSession: session.id, epoch: envelope.epoch ?? 0))
            sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: "accepted", detail: "Setting change in progress on home; completion will follow.", epoch: envelope.epoch)
            sendTranscript(to: peer, sessionID: session.id); publishSidebarIfChanged(); return
        }
        do { try commandStore.markCompleted(id: commandID) }
        catch { sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: "uncertain", detail: "Applied on home but completion was not recorded. Check home; do not resend.", epoch: envelope.epoch); return }
        sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: "completed",
                detail: completion, epoch: envelope.epoch)
        sendTranscript(to: peer, sessionID: session.id); publishSidebarIfChanged()
    }
    #endif
}

extension DeviceSyncService {
    // Internal for the service-level self-test harness.
    func handleEnvelope(_ peer: DevicePeer, _ envelope: DeviceEnvelope) {
        peer.lastSeen = Date()
        if envelope.kind == "pair.confirm" { peer.remoteConfirmed = true; finishTrustIfReady(peer); return }
        guard peer.trustedReady, let peerHome = peer.hello?.deviceID else { return }
        if groupsEnabled {
            if handleGroupEnvelope(peer, envelope) { return }
            guard !peer.controlOnly, currentGroup != nil else { return }
        }
        if locallyRemoved && !["fabric.members", "ping", "pong"].contains(envelope.kind) { return }
        #if os(macOS)
        if handleQueueWatch(peer, envelope) { return }
        if handleParticipantTell(peer, envelope) { return }
        #endif
        if handleLotEnvelope(peer, envelope) { return }
        if handleParticipantControl(peer, envelope) { return }
        switch envelope.kind {
        case "fabric.members":
            guard peer.hello?.capabilities.contains("fabric-membership-v1") == true, let data = envelope.payload,
                  let members = try? JSONDecoder().decode([TrustedDevice].self, from: data),
                  !groupsEnabled || members.allSatisfy({ $0.groupID == currentGroup?.id }) else { return }
            do {
                let wasRemoved = locallyRemoved
                if try trustStore?.merge(members) == true {
                    refreshGroupMembers()
                    let active = Set(trusted.map(\.deviceID))
                    for connection in Array(peers.values) where connection.trustedReady && !active.contains(connection.hello?.deviceID ?? "") { disconnect(connection) }
                    for device in trusted where homes[device.deviceID] == nil { homes[device.deviceID] = RemoteHomeState(deviceID: device.deviceID, deviceName: device.name) }
                    let removed = Set(members.filter { $0.removed == true }.map(\.deviceID)).subtracting(active)
                    for id in removed { homes.removeValue(forKey: id) }
                    // An offline device removed from the fabric cannot rejoin
                    // through an old pin: it must obtain fresh human admission.
                    if locallyRemoved && !wasRemoved {
                        if groupsEnabled {
                            try groupStore?.leave(); refreshGroupMembers(); parkGroupViews(); updateGroupAdvertisement()
                        }
                        for connection in Array(peers.values) { disconnect(connection) }
                        serviceStatus = "This device was removed from the fabric. Pair again to rejoin."; return
                    }
                    if wasRemoved && !locallyRemoved { sendSidebar(to: peer) }
                    broadcastFabric(); reconnectTrusted()
                }
            } catch { lastOutcome = "Could not save fabric membership. No new trust granted." }
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
            if envelope.kind == DeviceMessageKind.sidebarSnapshot.rawValue {
                let present = Set(payload.rows.map(\.globalID))
                let known = Set((homes[peerHome]?.rows ?? []).map(\.globalID))
                    .union(remoteLeases.keys).union(remoteTranscripts.keys).union(pendingTakes.keys).union(resumeEpochs.keys)
                for id in known where DeviceGlobalID(id)?.home == peerHome && !present.contains(id) { discardRemoteDisplay(id) }
            }
            homes[peerHome] = RemoteHomeState(deviceID: peerHome, deviceName: payload.homeDeviceName, online: true, rows: payload.rows, lastSeen: Date())
            for row in payload.rows { remoteOffline.remove(row.globalID) }
            observeRemoteResponses(home: peerHome, rows: payload.rows)
            if let encoded = try? JSONEncoder().encode(homes.values.map { DeviceSidebarPayload(homeDeviceID: $0.deviceID, homeDeviceName: $0.deviceName, homeSeq: 0, rows: $0.rows) }) { stateStore?.saveSidebarCache(encoded) }
        #if os(macOS)
        case DeviceMessageKind.leaseAcquire.rawValue, DeviceMessageKind.leaseResume.rawValue:
            // Notes are nonexclusive read subscriptions: viewing never displaces another reader or the home editor.
            if let lot = homeParkingLot(envelope) {
                peer.leasedSessions.insert(lot.id)
                lotSyncLog.info("lot subscribed: \(lot.name, privacy: .public)")
                sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseGranted.rawValue, boot: boot, sessionID: envelope.sessionID, epoch: 0))
                sendTranscript(to: peer, sessionID: lot.id); return
            }
            guard let (session, _) = homeSession(envelope), let leases else { return }
            let restoring = envelope.kind == DeviceMessageKind.leaseResume.rawValue
            let result = restoring
                ? leases.resume(session: session.id, device: peerHome, expectedEpoch: envelope.epoch ?? 0)
                : leases.acquire(session: session.id, device: peerHome)
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
            if let lot = homeParkingLot(envelope) {
                lotSyncLog.info("lot unsubscribed: \(lot.name, privacy: .public)")
                peer.leasedSessions.remove(lot.id); return
            }
            if let (session, _) = homeSession(envelope), let epoch = envelope.epoch {
                leases?.release(session: session.id, device: peerHome, epoch: epoch); peer.leasedSessions.remove(session.id); publishSidebarIfChanged()
            }
        #endif
        case DeviceMessageKind.leaseGranted.rawValue:
            guard let idString = envelope.sessionID, let global = DeviceGlobalID(idString), global.home == peerHome, let epoch = envelope.epoch else { return }
            if pendingTakes[idString] != nil {
                pendingTakes.removeValue(forKey: idString)
                rememberDisplay(idString, epoch: epoch)
                remoteLeases[idString] = epoch; leaseBoots[idString] = envelope.boot; remoteOffline.remove(idString)
                lastOutcome = "Display taken. Epoch " + String(epoch) + "."
            } else if let current = remoteLeases[idString], epoch > current {
                // Second grant from a coalesced duplicate: adopt monotonically.
                rememberDisplay(idString, epoch: epoch)
                remoteLeases[idString] = epoch; leaseBoots[idString] = envelope.boot
            } else {
                // Late grant after park/cancel: release it at home immediately.
                sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseRelease.rawValue, sessionID: idString, epoch: epoch))
            }
        case DeviceMessageKind.leaseExpired.rawValue:
            if let id = envelope.sessionID, DeviceGlobalID(id)?.home == peerHome, let epoch = envelope.epoch, remoteLeases[id] == epoch {
                freezeLot(id, reason: "The editing lease expired. Copy unconfirmed changes or take the lot again.", cleanReason: "The editing lease expired. No unsaved changes. Reconnecting…")
                remoteLeases.removeValue(forKey: id); leaseBoots.removeValue(forKey: id)
                remoteOffline.insert(id)
                // Retain the pane and its remembered epoch; restore is conditional.
            }
        case DeviceMessageKind.leaseStolen.rawValue, DeviceMessageKind.leaseDenied.rawValue:
            if let idString = envelope.sessionID, let global = DeviceGlobalID(idString), global.home == peerHome {
                discardRemoteDisplay(idString)
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
                existing.homeSeq = payload.homeSeq; existing.busy = payload.busy; existing.status = payload.status; existing.agentWidget = payload.agentWidget
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
            #if os(iOS)
            if payload.engine == "parking" && !payload.prepend { remoteLotSnapshots[payload.globalID] = payload.messages }
            #endif
            if drafts.adoptIfNewer(session: payload.globalID, version: payload.draftVersion, text: payload.draft) {
                draftAttachments[payload.globalID] = payload.draftImageHashes ?? []
                persistDrafts()
            }
            remoteOffline.remove(payload.globalID)
        #if os(macOS)
        case DeviceMessageKind.transcriptRequest.rawValue:
            if let lot = homeParkingLot(envelope) { sendTranscript(to: peer, sessionID: lot.id); return }
            guard let (session, _) = homeSession(envelope), let data = envelope.payload, let request = try? JSONDecoder().decode(DeviceTranscriptRequest.self, from: data) else { return }
            guard requireLease(peer, envelope, session) else { return }
            sendTranscript(to: peer, sessionID: session.id, beforeOffset: request.beforeOffset)
        case DeviceMessageKind.draftPatch.rawValue:
            if let lot = homeParkingLot(envelope) { sendTranscript(to: peer, sessionID: lot.id); return }
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
        #endif
        case DeviceMessageKind.draftAck.rawValue:
            if let idString = envelope.sessionID, let global = DeviceGlobalID(idString), global.home == peerHome, remoteLeases[idString] == envelope.epoch,
               let data = envelope.payload, let ack = try? JSONDecoder().decode(DeviceDraftPayload.self, from: data) {
                let localVersion = drafts.version(session: idString)
                // Several edits may be in flight. Acknowledging an earlier
                // one is normal, not rejection of the latest local edit.
                guard ack.version >= localVersion else { return }
                if ack.text != drafts.text(session: idString) {
                    draftConflicts[idString] = "Home kept a newer draft (version " + String(ack.version) + "). Your last edit was not applied."
                } else { draftConflicts.removeValue(forKey: idString) }
                if ack.version > localVersion {
                    drafts.adopt(session: idString, version: ack.version, text: drafts.text(session: idString) ?? ack.text)
                    persistDrafts()
                }
            }
        #if os(macOS)
        case DeviceMessageKind.command.rawValue:
            executeHomeCommand(peer, envelope)
        case DeviceMessageKind.commandQuery.rawValue:
            if let commandID = envelope.commandID, let commandStore {
                if let record = commandStore.records[commandID], record.origin != peerHome || record.sessionID != envelope.sessionID { return }
                sendAck(peer, commandID: commandID, sessionID: envelope.sessionID, outcome: (commandStore.outcome(id: commandID) ?? .rejected).rawValue, detail: "Home record lookup.", epoch: envelope.epoch)
            }
        #endif
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
        #if os(macOS)
        case DeviceMessageKind.blobChunk.rawValue, DeviceMessageKind.blobComplete.rawValue, DeviceMessageKind.blobOffer.rawValue:
            guard let (session, _) = homeSession(envelope), let data = envelope.payload, let blob = try? JSONDecoder().decode(DeviceBlobPayload.self, from: data) else { return }
            guard requireLease(peer, envelope, session) else { return }
            if envelope.kind == DeviceMessageKind.blobOffer.rawValue {
                let stored = blobPaths[blob.sha256Hex].map { FileManager.default.fileExists(atPath: $0) } ?? false
                // A fresh offer negotiates a complete upload. Abandon any
                // prefix left by an interrupted attempt before resending.
                if !stored { stagedBlobs.removeValue(forKey: blob.sha256Hex) }
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
        #endif
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
                if ack.outcome == "stored" { lastOutcome = "Attachment stored on home." }
                else if !recoverCachedUpload(globalID: idString, hash: hash, ackEpoch: envelope.epoch) {
                    lastOutcome = "Attachment failed: " + (ack.detail ?? "") + " Take the session again to retry, or attach the image again."
                }
            }
        #if os(macOS)
        case DeviceMessageKind.blobRequest.rawValue:
            guard let data = envelope.payload, let blob = try? JSONDecoder().decode(DeviceBlobPayload.self, from: data) else { return }
            let path: String
            if let lot = homeParkingLot(envelope) {
                // Legacy readers use epoch zero; current read-only viewers hold an exclusive lease.
                // Never use the global blob cache to authorize access to another lot's images.
                guard (editableLotsEnabled ? (envelope.epoch.map { leases?.validate(session: lot.id, device: peerHome, epoch: $0) == true } ?? false) : envelope.epoch == 0), peer.leasedSessions.contains(lot.id) else { return }
                if let image = lot.document.rows.flatMap({ $0.images ?? [] }).first(where: { imageHash(path: $0) == blob.sha256Hex }) { path = image }
                else if editableLotsEnabled, let proposal = lotProposalRequests[lot.id], proposal.epoch == envelope.epoch,
                        proposal.preview?.after?.rows.contains(where: { ($0.images ?? []).contains(blob.sha256Hex) }) == true,
                        let image = lotImagePaths[lot.id]?[blob.sha256Hex] { path = image }
                else { return }
            } else {
                guard let (session, _) = homeSession(envelope), requireLease(peer, envelope, session),
                      let image = blobPaths[blob.sha256Hex] else { return }
                path = image
            }
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)), bytes.count <= DeviceBlob.maxBlob else { return }
            var offset = 0
            while offset < bytes.count {
                let chunk = Data(bytes.dropFirst(offset).prefix(32_768)); offset += chunk.count
                let payload = try? JSONEncoder().encode(DeviceBlobPayload(sha256Hex: blob.sha256Hex, size: bytes.count, chunk: chunk, done: offset >= bytes.count))
                sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.blobData.rawValue, sessionID: envelope.sessionID, epoch: envelope.epoch, payload: payload))
            }
        #endif
        case DeviceMessageKind.blobData.rawValue:
            guard let idString = envelope.sessionID, let global = DeviceGlobalID(idString), global.home == peerHome, remoteLeases[idString] == envelope.epoch,
                  let data = envelope.payload, let blob = try? JSONDecoder().decode(DeviceBlobPayload.self, from: data), pendingDownloads.contains(blob.sha256Hex) else { return }
            if let chunk = blob.chunk {
                downloadBuffers[blob.sha256Hex, default: Data()].append(chunk)
                if (downloadBuffers[blob.sha256Hex]?.count ?? 0) > DeviceBlob.maxBlob { downloadBuffers.removeValue(forKey: blob.sha256Hex); pendingDownloads.remove(blob.sha256Hex); return }
            }
            if blob.done, let bytes = downloadBuffers[blob.sha256Hex], DeviceBlob.verify(bytes, sha256Hex: blob.sha256Hex) {
                let dir = storageFolder.appendingPathComponent("RemoteCache")
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
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.blobAck.rawValue, boot: boot, sessionID: envelope.sessionID, epoch: envelope.epoch, payload: payload))
    }

    private func recordEpoch(_ record: DeviceOutboxRecord) -> UInt64 { record.epoch }
    // MARK: Viewer actions
    private func peerForHome(_ home: String) -> DevicePeer? {
        guard !locallyRemoved else { return nil }
        return peers.values.first { $0.trustedReady && !$0.controlOnly && (!groupsEnabled || currentGroup != nil) && $0.hello?.deviceID == home && Date().timeIntervalSince($0.lastSeen) <= 20 && homes[home]?.online == true }
    }
    // Unseen-response markers are per viewing device and survive relaunch.
    private var remoteSeenFile: URL { storageFolder.appendingPathComponent("remote-seen.json") }
    private func loadRemoteSeen() {
        remoteSeen = (try? JSONDecoder().decode(RemoteSeenWatermarks.self, from: Data(contentsOf: remoteSeenFile))) ?? RemoteSeenWatermarks()
    }
    private func saveRemoteSeen() { try? JSONEncoder().encode(remoteSeen).write(to: remoteSeenFile, options: .atomic) }
    func observeRemoteResponses(home: String, rows: [DeviceSidebarRow]) {
        if remoteSeen.observe(home: home, rows: rows, displayed: viewerHasPlacement) { saveRemoteSeen() }
    }
    func markRemoteSeen(globalID: String) {
        guard let row = remoteRow(globalID: globalID), remoteSeen.markSeen(row) else { return }
        saveRemoteSeen()
    }
    // Sidebar marker inputs for a remote row, shared by Mac and iPad views.
    func remoteMarkers(_ row: DeviceSidebarRow) -> RemoteRowMarkers {
        RemoteRowMarkers(paused: row.showsLoopPaused, pausedReason: row.showsLoopPaused ? row.pausedHelp : nil,
                         unseen: remoteSeen.isUnseen(row) && !viewerHasPlacement(row.globalID))
    }
    private func loadResumeEpochs() {
        resumeEpochs = (try? JSONDecoder().decode([String: UInt64].self, from: Data(contentsOf: storageFolder.appendingPathComponent("display-resume.json")))) ?? [:]
    }
    private func rememberDisplay(_ id: String, epoch: UInt64) {
        resumeEpochs[id] = epoch
        saveResumeEpochs()
    }
    private func forgetDisplay(_ id: String) {
        guard resumeEpochs.removeValue(forKey: id) != nil else { return }
        saveResumeEpochs()
    }
    private func saveResumeEpochs() {
        do { try JSONEncoder().encode(resumeEpochs).write(to: storageFolder.appendingPathComponent("display-resume.json"), options: .atomic) }
        catch { lastOutcome = "Could not save display restore state. Take manually after restarting." }
    }
    // Never use lease.acquire here: an automatic reconnect must not steal.
    func restoreAvailableDisplays() {
        for (id, epoch) in resumeEpochs {
            // Clean lots can resume conditionally, just like sessions. Never replay pending edits.
            guard !(editableLotsEnabled && remoteRow(globalID: id)?.engine == "parking" && (lotEditors[id]?.unconfirmedCount ?? 0) > 0),
                  viewerHasPlacement(id), remoteLeases[id] == nil, pendingTakes[id] == nil,
                  let global = DeviceGlobalID(id), let peer = peerForHome(global.home),
                  peer.hello?.capabilities.contains("lease-resume-v1") == true else { continue }
            remoteTranscripts.removeValue(forKey: id)
            pendingTakes[id] = Date()
            sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseResume.rawValue, sessionID: id, epoch: epoch))
        }
    }
    // A saved pane has no lease during startup/reconnect. Do not present this
    // transient state as an invitation to take control from another device.
    func remoteDisplayReconnecting(_ id: String) -> Bool {
        guard let global = DeviceGlobalID(id), let peer = peerForHome(global.home),
              !remoteOffline.contains(id) else { return true }
        if pendingTakes[id] != nil { return true }
        if remoteLeases[id] != nil { return remoteTranscripts[id] == nil }
        return resumeEpochs[id] != nil && peer.hello?.capabilities.contains("lease-resume-v1") == true
    }
    func acquireRemote(globalID: String) {
        guard let global = DeviceGlobalID(globalID), let peer = peerForHome(global.home) else { lastOutcome = "Home is offline."; return }
        if editableLotsEnabled && remoteRow(globalID: globalID)?.engine == "parking" && peer.hello?.capabilities.contains(LotEditing.capability) != true {
            lastOutcome = "Update Converse on the lot’s home to edit this Parking Lot."; return
        }
        markRemoteSeen(globalID: globalID)
        // Coalesce: moving panes or double-clicking must not mint a second
        // epoch that invalidates the first grant.
        guard pendingTakes[globalID] == nil, remoteLeases[globalID] == nil else { return }
        // Fresh take must not hydrate from a stale retained transcript.
        remoteTranscripts.removeValue(forKey: globalID)
        #if os(iOS)
        remoteLotSnapshots.removeValue(forKey: globalID)
        #endif
        pendingTakes[globalID] = Date()
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseAcquire.rawValue, sessionID: globalID))
    }
    func releaseRemote(globalID: String, preservingDisplay: Bool = false) {
        if var editor = lotEditors[globalID], editor.unconfirmedCount > 0, editor.frozenReason == nil {
            editor.draining = true; lotEditors[globalID] = editor; lotReleases.insert(globalID); return
        }
        if !preservingDisplay { forgetDisplay(globalID) }
        pendingTakes.removeValue(forKey: globalID)
        guard let global = DeviceGlobalID(globalID), let epoch = remoteLeases[globalID], let peer = peerForHome(global.home) else {
            remoteLeases.removeValue(forKey: globalID); leaseBoots.removeValue(forKey: globalID); return
        }
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseRelease.rawValue, sessionID: globalID, epoch: epoch))
        remoteLeases.removeValue(forKey: globalID); leaseBoots.removeValue(forKey: globalID)
    }
    #if os(macOS)
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
    /// The paired device currently displaying this home session, if any.
    /// The home's own fence is excluded: its panes are read from the workspace.
    func remoteDisplayHolder(_ sessionID: UUID) -> String? {
        guard let holder = leases?.holder(session: sessionID)?.device, holder != identity?.deviceID else { return nil }
        return holder
    }
    func localTake(sessionID: UUID) {
        guard started, let home = identity?.deviceID, let leases else { return }
        if leases.holder(session: sessionID)?.device == home { return }
        let result = leases.acquire(session: sessionID, device: home)
        guard result.granted else { lastOutcome = "Could not record local display fence."; return }
        let globalID = DeviceGlobalID(home: home, session: sessionID).string
        for peer in peers.values where peer.trustedReady && peer.leasedSessions.contains(sessionID) {
            peer.leasedSessions.remove(sessionID)
            sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseStolen.rawValue, boot: boot, sessionID: globalID, epoch: result.epoch))
        }
        publishSidebarIfChanged()
    }
    #endif
    func canTeachRemote(_ globalID: String) -> Bool {
        guard remoteRow(globalID: globalID)?.engine != "parking" else { return false }
        guard let global = DeviceGlobalID(globalID), let peer = peerForHome(global.home) else { return false }
        return peer.hello?.capabilities.contains("switchboard-teach-v1") == true
    }
    @discardableResult
    func sendRemoteCommand(globalID: String, command: DeviceCommandPayload) -> UUID? {
        guard remoteRow(globalID: globalID)?.engine != "parking", remoteTranscripts[globalID]?.engine != "parking" else { lastOutcome = "Parking Lots are read only on Group viewers."; return nil }
        // Older homes only know Clear queue; never send them a single removal.
        guard command.action != "removeQueued" || canRemoveQueuedRemote(globalID) else { lastOutcome = "Update the home device to remove one queued message."; return nil }
        // A double click is the same outstanding queue intent, not a second
        // interrupt. Uncertain requests require a home query before retrying.
        if Self.queueActions.contains(command.action), let active = queueCommand(globalID: globalID),
           ["pending", "accepted", "uncertain"].contains(active.outcome) {
            lastOutcome = "Queue request already pending. Check home for its result."
            return active.payload.action == command.action && active.payload.pendingID == command.pendingID ? active.commandID : nil
        }
        let epoch = command.action == "teachSwitchboard" && canTeachRemote(globalID) ? 0 : remoteLeases[globalID]
        guard let global = DeviceGlobalID(globalID), let epoch, let peer = peerForHome(global.home) else {
            lastOutcome = "Take the session again before sending."; return nil
        }
        guard let payloadData = try? JSONEncoder().encode(command) else { return nil }
        let record = DeviceOutboxRecord(commandID: UUID(), sessionID: globalID, payload: command, payloadHash: DeviceBlob.sha256Hex(payloadData), epoch: epoch)
        do { try outboxStore?.add(record); outbox = outboxStore?.records ?? outbox } catch { lastOutcome = "Could not save outgoing message. Nothing sent."; return nil }
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: globalID, commandID: record.commandID, epoch: epoch, payload: payloadData))
        return record.commandID
    }
    func retryOutbox(_ record: DeviceOutboxRecord) {
        let epoch = record.payload.action == "teachSwitchboard" && canTeachRemote(record.sessionID) ? 0 : remoteLeases[record.sessionID]
        guard record.outcome == "pending", let global = DeviceGlobalID(record.sessionID), let epoch, let peer = peerForHome(global.home),
              let payloadData = try? JSONEncoder().encode(record.payload) else { lastOutcome = "Take the session again before retrying."; return }
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: record.sessionID, commandID: record.commandID, epoch: epoch, payload: payloadData))
    }
    func queryOutbox(_ record: DeviceOutboxRecord) {
        guard let global = DeviceGlobalID(record.sessionID), let peer = peerForHome(global.home) else { return }
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.commandQuery.rawValue, sessionID: record.sessionID, commandID: record.commandID, epoch: record.epoch))
    }
    func discardOutbox(_ record: DeviceOutboxRecord) { try? outboxStore?.remove(commandID: record.commandID); outbox = outboxStore?.records ?? outbox }
    func unresolved(globalID: String) -> [DeviceOutboxRecord] { outbox.filter { $0.sessionID == globalID } }
    static let queueActions: Set<String> = ["inject", "injectAll", "pauseQueue", "resumeQueue", "clearQueue", "removeQueued"]
    static let queueRemoveCapability = "queue-remove-v1"
    func canRemoveQueuedRemote(_ globalID: String) -> Bool {
        DeviceGlobalID(globalID).flatMap { peerForHome($0.home) }?.hello?.capabilities.contains(Self.queueRemoveCapability) == true
    }
    func queueCommand(globalID: String) -> DeviceOutboxRecord? {
        let records = unresolved(globalID: globalID).filter { Self.queueActions.contains($0.payload.action) }
        return records.first { ["pending", "accepted", "uncertain"].contains($0.outcome) } ?? records.last
    }
    func sendRemoteDraft(globalID: String, text: String, imageHashes: [String]? = nil) {
        guard let global = DeviceGlobalID(globalID), let epoch = remoteLeases[globalID], let peer = peerForHome(global.home) else { return }
        if let imageHashes { draftAttachments[globalID] = imageHashes }
        let version = drafts.bump(session: globalID, text: text); persistDrafts()
        let payload = try? JSONEncoder().encode(DeviceDraftPayload(version: version, text: text, imageHashes: draftAttachments[globalID] ?? []))
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.draftPatch.rawValue, sessionID: globalID, epoch: epoch, payload: payload))
    }
    func saveDraftAttachments(globalID: String, hashes: [String]) {
        guard (draftAttachments[globalID] ?? []) != hashes else { return }
        draftAttachments[globalID] = hashes; persistDrafts()
        if hashes.allSatisfy({ blobReady[$0] == true }), let text = drafts.text(session: globalID) ?? remoteTranscripts[globalID]?.draft {
            sendRemoteDraft(globalID: globalID, text: text)
        }
    }
    func queryBlob(globalID: String, hash: String) {
        guard let global = DeviceGlobalID(globalID), let epoch = remoteLeases[globalID], let peer = peerForHome(global.home) else { return }
        blobReady[hash] = false; pendingUploads.insert(hash)
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
    private func recoverCachedUpload(globalID: String, hash: String, ackEpoch: UInt64?) -> Bool {
        guard let epoch = remoteLeases[globalID], ackEpoch == epoch,
              recoveredUploads[globalID]?[hash] != epoch,
              let global = DeviceGlobalID(globalID), let peer = peerForHome(global.home),
              hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
        let cache = storageFolder.appendingPathComponent("RemoteCache")
        let candidates = [blobCache[hash], cache.appendingPathComponent(hash + ".png"), cache.appendingPathComponent(String(hash.prefix(16)) + ".png")].compactMap { $0 }
        guard let cached = candidates.lazy.compactMap({ url -> (URL, Data)? in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= DeviceBlob.maxBlob,
                  let bytes = try? Data(contentsOf: url), bytes.count <= DeviceBlob.maxBlob, DeviceBlob.verify(bytes, sha256Hex: hash) else { return nil }
            return (url, bytes)
        }).first else { return false }
        // Record before sending: the offer's own not-stored ack must not
        // recurse into another retry. A new lease permits one new attempt.
        recoveredUploads[globalID, default: [:]][hash] = epoch
        blobCache[hash] = cached.0
        let offer = try? JSONEncoder().encode(DeviceBlobPayload(sha256Hex: hash))
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.blobOffer.rawValue, sessionID: globalID, epoch: epoch, payload: offer))
        guard sendRemoteBlob(globalID: globalID, data: cached.1) == hash else { return false }
        lastOutcome = "Retrying cached image upload…"
        return true
    }
    // Isolated interoperability fixture: drop halfway through an upload,
    // then exercise the normal reconnect/offer/recovery path.
    func sendPartialBlobForTesting(globalID: String, data: Data) -> Bool {
        guard isTestEnvironment, testFolder != nil, data.count > 1, data.count <= DeviceBlob.maxBlob,
              let global = DeviceGlobalID(globalID), let epoch = remoteLeases[globalID], let peer = peerForHome(global.home) else { return false }
        let hash = DeviceBlob.sha256Hex(data); blobReady[hash] = false; pendingUploads.insert(hash)
        let payload = try? JSONEncoder().encode(DeviceBlobPayload(sha256Hex: hash, size: data.count, chunk: Data(data.prefix(data.count / 2)), done: false))
        sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.blobChunk.rawValue, sessionID: globalID, epoch: epoch, payload: payload))
        return true
    }
    func sendRemoteBlob(globalID: String, data: Data) -> String? {
        guard data.count <= DeviceBlob.maxBlob, let global = DeviceGlobalID(globalID),
              let epoch = remoteLeases[globalID], let peer = peerForHome(global.home) else { return nil }
        let hash = DeviceBlob.sha256Hex(data)
        if editableLotsEnabled && remoteRow(globalID: globalID)?.engine == "parking" {
            guard lotCanEdit(globalID) else { return nil }
            lotBlobReady[globalID, default: []].remove(hash)
            lotPendingUploads[globalID, default: [:]][hash] = epoch
        } else { blobReady[hash] = false; pendingUploads.insert(hash) }
        var offset = 0
        while offset < data.count {
            let chunk = Data(data.dropFirst(offset).prefix(32_768)); offset += chunk.count
            let payload = try? JSONEncoder().encode(DeviceBlobPayload(sha256Hex: hash, size: data.count, chunk: chunk, done: offset >= data.count))
            sendEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.blobChunk.rawValue, sessionID: globalID, epoch: epoch, payload: payload))
        }
        return hash
    }
}




extension DeviceSyncService {
    func viewerHasPlacement(_ globalID: String) -> Bool {
        if let isPlaced { return isPlaced(globalID) }
        #if os(macOS)
        return Workspace.shared.placements[placementID(forGlobal: globalID)] != nil
        #else
        return false
        #endif
    }
    private func parkViewer(_ globalID: String) {
        #if os(macOS)
        Workspace.shared.park(placementID(forGlobal: globalID))
        #else
        onRemotePark?(globalID)
        #endif
    }
    // Called while the scene still has a short background assertion. Files
    // persist synchronously; release is best effort and home TTL is the backstop.
    func suspendViewer() {
        persistDrafts()
        for id in Set(remoteLeases.keys).union(pendingTakes.keys) { releaseRemote(globalID: id, preservingDisplay: true) }
        heartbeatTimer?.invalidate(); publishTimer?.invalidate()
        heartbeatTimer = nil; publishTimer = nil
        browser?.cancel(); listener?.cancel(); browser = nil; listener = nil
        for peer in Array(peers.values) { disconnect(peer) }
        pairingPrompt = nil
        started = false
        serviceStatus = "Disconnected while in background. Available displays restore after reconnecting."
    }
    func resumeViewer() { startIfNeeded() }
    #if os(iOS)
    // Lot viewing is a nonexclusive read subscription, so the mobile viewer may
    // renew it unprompted. These never apply to ordinary session leases.
    func lotHomeReachable(_ globalID: String) -> Bool { DeviceGlobalID(globalID).flatMap { peerForHome($0.home) } != nil }
    func lotSubscriptionPending(_ globalID: String) -> Bool { pendingTakes[globalID] != nil }
    #endif
    func storedDraft(globalID: String) -> String? { drafts.text(session: globalID) }
}

extension DeviceSyncService {
    private func initializeGroups(folder: URL) throws {
        let existed = FileManager.default.fileExists(atPath: folder.appendingPathComponent("converse-groups.json").path)
        let store = try ConverseGroupStore(folder: folder)
        if !existed, !locallyRemoved, let ownID = identity?.deviceID,
           let migrated = ConverseGroupStore.migration(trustStore?.records ?? [], ownDeviceID: ownID) {
            try trustStore?.migrateLegacyGroup(migrated.id); try store.adopt(migrated)
        }
        groupStore = store; refreshGroupMembers()
    }
    func enableGroupsForTesting() throws { try initializeGroups(folder: storageFolder) }
    private func refreshGroupMembers() {
        currentGroup = groupStore?.current
        knownGroups = groupStore?.state.groups ?? []
        trusted = trustStore?.devices.filter { $0.deviceID != identity?.deviceID && (!groupsEnabled || (currentGroup != nil && $0.groupID == currentGroup?.id)) } ?? []
    }
    private func groupAdvertisement() -> NWListener.Service? {
        // Loopback transport fixtures must not publish onto the real LAN or
        // depend on Bonjour availability. Discovery fixtures opt in by name.
        guard !isTestEnvironment || testingDiscoveryPrefix != nil else { return nil }
        var hints: [String: String] = ["device": identity?.deviceID ?? ""]
        if let group = currentGroup { hints.merge(["group": group.id, "name": group.name, "creator": group.creator]) { _, new in new } }
        return NWListener.Service(name: (testingDiscoveryPrefix ?? "") + deviceName + " [" + String((identity?.deviceID ?? "").prefix(8)) + "]", type: Self.serviceType, txtRecord: NWTXTRecord(hints))
    }
    private func updateGroupAdvertisement() { listener?.service = groupAdvertisement(); lastSidebarSnapshot = nil }
    var availableGroups: [ConverseGroup] {
        var groups = knownGroups.filter { !$0.dissolved }
        for device in discovered {
            if let group = device.group, !knownGroups.contains(where: { $0.id == group.id && $0.dissolved }), !groups.contains(where: { $0.id == group.id }) { groups.append(group) }
        }
        return groups.sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
    }
    func groupDevices(_ id: String) -> [GroupDeviceLabel] {
        let members = trustStore?.devices.filter { $0.groupID == id && $0.deviceID != identity?.deviceID } ?? []
        var labels: [String: String] = [:]
        for member in members { labels[member.deviceID] = (member.displayName ?? member.name) + " [" + String(member.deviceID.prefix(8)) + "]" }
        for device in discovered where device.group?.id == id {
            let key = device.deviceID ?? members.first(where: { device.name.hasSuffix("[" + String($0.deviceID.prefix(8)) + "]") })?.deviceID ?? device.id
            if labels[key] == nil { labels[key] = device.name }
        }
        if currentGroup?.id == id, let identity { labels[identity.deviceID] = displayName(for: identity.deviceID) + " (this device)" }
        return labels.map { GroupDeviceLabel(id: $0.key, name: $0.value) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
    func canJoinGroup(_ id: String) -> Bool { discovered.contains { $0.group?.id == id } && currentGroup?.id != id && pairingPrompt == nil }
    func joinGroup(_ group: ConverseGroup) {
        guard let device = discovered.first(where: { $0.group?.id == group.id }), canJoinGroup(group.id) else { lastOutcome = "No member of this group is currently reachable."; return }
        connect(to: device.endpoint, displayName: device.name, joiningGroupID: group.id, wantsJoin: true)
        serviceStatus = "Requesting to join " + group.name + "…"
    }
    func joinGroupByAddress(host: String, port: Int) {
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { lastOutcome = "Port must be between 1 and 65535."; return }
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: nwPort), displayName: host, manualHost: host, manualPort: port, wantsJoin: true)
    }
    func createGroup(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 120, !availableGroups.contains(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }), let identity else {
            lastOutcome = "Use a unique group name, up to 120 UTF-8 bytes."; return
        }
        do { try activateGroup(ConverseGroup(id: UUID().uuidString.lowercased(), name: name, creator: identity.deviceID)); lastOutcome = "Created " + name + ". Other devices can now request to join." }
        catch { lastOutcome = "Could not create group: " + error.localizedDescription }
    }
    private func parkGroupViews() {
        let remoteIDs = Set(Array(remoteLeases.keys) + remoteTranscripts.keys + homes.values.flatMap { $0.rows.map(\.globalID) } + outbox.map(\.sessionID))
        for id in remoteIDs {
            releaseRemote(globalID: id); parkViewer(id)
            try? outboxStore?.markUncertain(sessionID: id)
        }
        outbox = outboxStore?.records ?? outbox
        #if os(macOS)
        // Also park restored placements whose home is currently unknown/offline.
        let localIDs = Set(Store.shared.sessions.map(\.id))
        for id in Array(Workspace.shared.placements.keys) where !localIDs.contains(id) { Workspace.shared.park(id) }
        #endif
        remoteLeases = [:]; remoteTranscripts = [:]; homes = [:]; remoteOffline = []
        groupRequests = []; groupReview = nil
    }
    private func activateGroup(_ group: ConverseGroup, keeping peerID: UUID? = nil) throws {
        guard let groupStore, let identity, group.valid else { throw CocoaError(.coderInvalidValue) }
        if currentGroup?.id != group.id {
            // Validate and durably save the destination before leaving. A
            // failed/declined join never removes the prior membership.
            let previous = currentGroup
            try groupStore.adopt(group)
            if previous != nil {
                try trustStore?.forget(deviceID: identity.deviceID, issuer: identity.deviceID)
                broadcastFabric()
            }
            parkGroupViews()
            for peer in Array(peers.values) where peer.id != peerID { disconnect(peer) }
        }
        try trustStore?.pin(deviceID: identity.deviceID, name: deviceName, publicKey: identity.publicKey, issuer: identity.deviceID, groupID: group.id)
        refreshGroupMembers(); updateGroupAdvertisement(); lastOutcome = ""
    }
    func leaveGroup() {
        guard currentGroup != nil else { return }
        do {
            try groupStore?.leave()
            if let identity { try trustStore?.forget(deviceID: identity.deviceID, issuer: identity.deviceID) }
            broadcastFabric(); refreshGroupMembers(); parkGroupViews(); updateGroupAdvertisement()
            let old = Array(peers.values)
            for peer in old { peer.controlOnly = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { for peer in old { self.disconnect(peer) } }
            lastOutcome = ""
            serviceStatus = "Not in a Converse group. Local sessions keep running."
        } catch { lastOutcome = "Could not leave group: " + error.localizedDescription }
    }
    func dissolveGroup() {
        guard let group = currentGroup else { return }
        do {
            try groupStore?.dissolve(group)
            for peer in Array(peers.values) where peer.trustedReady { sendGroupState(peer); peer.controlOnly = true }
            refreshGroupMembers(); parkGroupViews(); updateGroupAdvertisement()
            let old = Array(peers.values)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { for peer in old { self.disconnect(peer) } }
            lastOutcome = ""
            serviceStatus = "Group dissolved. Local sessions keep running."
        } catch { lastOutcome = "Could not dissolve group: " + error.localizedDescription }
    }
    private func sendGroupState(_ peer: DevicePeer) {
        guard let groups = groupStore?.state.groups, let data = try? JSONEncoder().encode(groups) else { return }
        sendEnvelope(peer, DeviceEnvelope(kind: "group.state", payload: data))
    }
    private func publishGroupRequests() {
        pruneGroupRequests()
        guard let id = currentGroup?.id, let data = try? JSONEncoder().encode(Array(sponsoredRequests.values).filter { $0.groupID == id }) else { return }
        for member in Array(peers.values) where member.trustedReady && !member.controlOnly { sendEnvelope(member, DeviceEnvelope(kind: "group.requests", payload: data)) }
    }
    @discardableResult private func pruneGroupRequests(at now: Date = Date()) -> Bool {
        let expired = Set(sponsoredRequests.values.filter { $0.expiresAt <= now }.map(\.id))
        let oldCount = groupRequests.count
        // Remove records before disconnect: disconnect's withdrawal path must
        // not recursively republish the entries being expired here.
        for id in expired { sponsoredRequests.removeValue(forKey: id) }
        groupRequests.removeAll { $0.expiresAt <= now || expired.contains($0.id) }
        if let review = groupReview, review.request.expiresAt <= now || expired.contains(review.id) { groupReview = nil }
        for id in expired { if let peer = peers[id] { disconnect(peer) } }
        return !expired.isEmpty || groupRequests.count != oldCount
    }
    func expireGroupRequestsForTesting(at now: Date) {
        guard isTestEnvironment, testFolder != nil else { return }
        if pruneGroupRequests(at: now) { publishGroupRequests() }
    }
    private func withdrawGroupRequest(_ id: UUID) {
        sponsoredRequests.removeValue(forKey: id); groupRequests.removeAll { $0.id == id }
        if groupReview?.id == id { groupReview = nil }
        publishGroupRequests()
    }
    func reviewGroupRequest(_ request: GroupJoinRequest) {
        guard request.groupID == currentGroup?.id, !request.approved, request.expiresAt > Date() else { return }
        if let peer = peers[request.id], sponsoredRequests[request.id] == request, let keys = peer.keys {
            groupReview = GroupJoinReview(request: request, code: DeviceSAS.code(keys.handshakeHash))
        } else if let member = peers.values.first(where: { $0.trustedReady && !$0.controlOnly && $0.hello?.deviceID == request.sponsorID }), let data = try? JSONEncoder().encode(request) {
            sendEnvelope(member, DeviceEnvelope(kind: "group.review", payload: data))
        }
    }
    func approveGroupReview() {
        guard let review = groupReview, review.request.groupID == currentGroup?.id else { return }
        if sponsoredRequests[review.id] != nil { approveSponsored(review) }
        else if let member = peers.values.first(where: { $0.trustedReady && !$0.controlOnly && $0.hello?.deviceID == review.request.sponsorID }), let data = try? JSONEncoder().encode(review) {
            sendEnvelope(member, DeviceEnvelope(kind: "group.approve", payload: data))
        }
        groupReview = nil
    }
    private func approveSponsored(_ review: GroupJoinReview) {
        guard let request = sponsoredRequests[review.id], request == review.request, !request.approved, request.expiresAt > Date(), request.groupID == currentGroup?.id,
              let peer = peers[request.id], let keys = peer.keys, review.code == DeviceSAS.code(keys.handshakeHash) else { return }
        peer.humanConfirmed = true; peer.localConfirmed = true
        var approved = request; approved.approved = true; sponsoredRequests[request.id] = approved
        if let index = groupRequests.firstIndex(where: { $0.id == request.id }) { groupRequests[index] = approved }
        publishGroupRequests()
        sendEnvelope(peer, DeviceEnvelope(kind: "pair.confirm")); finishTrustIfReady(peer)
    }
    private func handleGroupEnvelope(_ peer: DevicePeer, _ envelope: DeviceEnvelope) -> Bool {
        guard envelope.kind.hasPrefix("group.") else { return false }
        guard let data = envelope.payload else { return true }
        if envelope.kind == "group.state" {
            guard let groups = try? JSONDecoder().decode([ConverseGroup].self, from: data), groups.count <= 2048,
                  let issuer = trustStore?.records.first(where: { $0.deviceID == peer.hello?.deviceID && $0.publicKey == peer.keys?.remoteStatic && $0.removed != true }) else { return true }
            for group in groups where group.valid && group.dissolved && group.id == issuer.groupID {
                do {
                    let affected = currentGroup?.id == group.id
                    try groupStore?.dissolve(group)
                    if affected {
                        for connection in Array(peers.values) where connection.trustedReady && connection.id != peer.id { sendGroupState(connection) }
                        refreshGroupMembers(); parkGroupViews(); updateGroupAdvertisement()
                        let old = Array(peers.values)
                        for connection in old { connection.controlOnly = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { for connection in old { self.disconnect(connection) } }
                        serviceStatus = "Group dissolved by another member. Local sessions keep running."
                    }
                } catch { lastOutcome = "Could not persist group dissolution." }
            }
            return true
        }
        guard !peer.controlOnly, trustStore?.devices.contains(where: { $0.deviceID == peer.hello?.deviceID && $0.groupID == currentGroup?.id }) == true, currentGroup != nil, !locallyRemoved else { return true }
        switch envelope.kind {
        case "group.requests":
            guard let requests = try? JSONDecoder().decode([GroupJoinRequest].self, from: data), requests.count <= 16,
                  requests.allSatisfy({ $0.groupID == currentGroup?.id && $0.sponsorID == peer.hello?.deviceID && $0.requesterID.count == 64 && $0.requesterName.utf8.count <= 400 }) else { return true }
            groupRequests.removeAll { $0.sponsorID == peer.hello?.deviceID }
            groupRequests.append(contentsOf: requests.filter { $0.expiresAt > Date() })
            if let review = groupReview, !groupRequests.contains(where: { $0.id == review.id && !$0.approved }) { groupReview = nil }
        case "group.review":
            guard let request = try? JSONDecoder().decode(GroupJoinRequest.self, from: data), sponsoredRequests[request.id] == request,
                  let pending = peers[request.id], let keys = pending.keys, request.expiresAt > Date(), !request.approved,
                  let payload = try? JSONEncoder().encode(GroupJoinReview(request: request, code: DeviceSAS.code(keys.handshakeHash))) else { return true }
            sendEnvelope(peer, DeviceEnvelope(kind: "group.review.detail", payload: payload))
        case "group.review.detail":
            guard let review = try? JSONDecoder().decode(GroupJoinReview.self, from: data), review.request.sponsorID == peer.hello?.deviceID,
                  groupRequests.contains(review.request), !review.request.approved, review.request.expiresAt > Date(), review.code.count == 39 else { return true }
            groupReview = review
        case "group.approve":
            if let review = try? JSONDecoder().decode(GroupJoinReview.self, from: data) { approveSponsored(review) }
        default: break
        }
        return true
    }
}

// MARK: Group participant messaging (independent of display leases)
extension DeviceSyncService {
    var localDeviceID: String? { identity?.deviceID }
    func acceptsParticipant(home: String, groupID: String) -> Bool {
        guard !locallyRemoved, currentGroup?.id == groupID else { return false }
        if home == identity?.deviceID { return true }
        return trusted.contains { $0.deviceID == home && $0.groupID == groupID }
    }
    var participantHomes: [RemoteHomeState] {
        guard let group = currentGroup?.id else { return [] }
        return homes.values.filter { acceptsParticipant(home: $0.deviceID, groupID: group) }.sorted { $0.deviceID < $1.deviceID }
    }
    func participantOnline(_ home: String) -> Bool {
        guard let peer = peerForHome(home) else { return false }
        return peer.hello?.capabilities.contains("participant-control-v1") == true
    }
    #if os(macOS)
    func publishQueueWatch(_ entries: [DeviceQueueWatch]) {
        guard let group = currentGroup?.id else { return }
        for peer in peers.values where peer.trustedReady && !peer.controlOnly {
            guard let home = peer.hello?.deviceID, acceptsParticipant(home: home, groupID: group),
                  peer.hello?.capabilities.contains("switchboard-supervision-v1") == true else { continue }
            let relevant = Array(entries.filter { DeviceGlobalID($0.source)?.home == home }.prefix(128))
            let report = DeviceQueueWatchReport(groupID: group, entries: relevant)
            sendEnvelope(peer, DeviceEnvelope(kind: "participant.queue-watch", payload: try? JSONEncoder().encode(report)))
        }
    }
    private func handleQueueWatch(_ peer: DevicePeer, _ envelope: DeviceEnvelope) -> Bool {
        guard envelope.kind == "participant.queue-watch" else { return false }
        guard let home = peer.hello?.deviceID, let bytes = envelope.payload, bytes.count <= 64000,
              peer.hello?.capabilities.contains("switchboard-supervision-v1") == true,
              let report = try? JSONDecoder().decode(DeviceQueueWatchReport.self, from: bytes), report.entries.count <= 128,
              acceptsParticipant(home: home, groupID: report.groupID), !peer.controlOnly,
              report.entries.allSatisfy({ DeviceGlobalID($0.target)?.home == home && DeviceGlobalID($0.source)?.home == localDeviceID }) else { return true }
        switchboardQueueReports[home] = (report, Date()); return true
    }
    func sendParticipantTell(source: Session, target: String, text: String, id: UUID, hop: Int, urgent: Bool, replyExpected: Bool = false, inReplyTo: UUID? = nil) -> String? {
        guard let global = DeviceGlobalID(target), let home = identity?.deviceID, let group = currentGroup?.id,
              acceptsParticipant(home: global.home, groupID: group), let peer = peerForHome(global.home),
              peer.hello?.capabilities.contains("participant-control-v1") == true else {
            return "Target home is offline, outside this group, or needs a Converse update. Nothing was sent."
        }
        guard let row = homes[global.home]?.rows.first(where: { $0.globalID == global.string }), row.messagingEnabled == true else {
            return "Target is missing or session messaging is disabled on its home. Nothing was sent."
        }
        guard (!replyExpected && inReplyTo == nil) || peer.hello?.capabilities.contains("switchboard-supervision-v1") == true else {
            return "Update the recipient home to support tracked switchboard replies. Nothing was sent."
        }
        let payload = DeviceTellPayload(groupID: group, source: DeviceGlobalID(home: home, session: source.id).string,
                                       sourceTitle: source.title, target: global.string, text: text, hop: hop, urgent: urgent, replyExpected: replyExpected ? true : nil, inReplyTo: inReplyTo)
        let oldExpected = source.switchboardExpectations, oldWatches = source.switchboardObligations
        participantStore.switchboardSent(source, to: target, id: id, replyExpected: replyExpected, inReplyTo: inReplyTo, remote: true)
        do { try participantStore.saveChecked() } catch {
            source.switchboardExpectations = oldExpected; source.switchboardObligations = oldWatches
            return "Could not persist the tracked delivery. Nothing was sent."
        }
        pendingTells[id] = (source.id, global.home, group)
        source.messages.append(Message(role: "notice", text: "Switchboard: awaiting home acceptance → " + row.title + " [" + target + "] · " + id.uuidString + (replyExpected ? " [ask]" : " [tell]") + "\n" + text))
        participantStore.save()
        sendEnvelope(peer, DeviceEnvelope(kind: "participant.tell", commandID: id, payload: try? JSONEncoder().encode(payload)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, let pending = self.pendingTells.removeValue(forKey: id), let source = self.participantStore.sessions.first(where: { $0.id == pending.source }) else { return }
            if let at = source.messages.lastIndex(where: { $0.text.hasPrefix("Switchboard: awaiting home acceptance → ") && $0.text.contains(id.uuidString) }) {
                source.messages[at].text = source.messages[at].text.replacingOccurrences(of: "awaiting home acceptance →", with: "delivery unconfirmed →")
            }
            self.participantStore.save()
        }
        return nil
    }
    private func handleParticipantTell(_ peer: DevicePeer, _ envelope: DeviceEnvelope) -> Bool {
        guard ["participant.tell", "participant.tell.ack"].contains(envelope.kind) else { return false }
        guard let origin = peer.hello?.deviceID, let group = currentGroup?.id,
              acceptsParticipant(home: origin, groupID: group), !peer.controlOnly,
              peer.hello?.capabilities.contains("participant-control-v1") == true, let id = envelope.commandID else { return true }
        let store = participantStore
        if envelope.kind == "participant.tell.ack" {
            guard let pending = pendingTells[id], pending.home == origin, pending.group == group,
                  let bytes = envelope.payload, let ack = try? JSONDecoder().decode(DeviceAckPayload.self, from: bytes) else { return true }
            pendingTells.removeValue(forKey: id)
            if let source = store.sessions.first(where: { $0.id == pending.source }) {
                store.switchboardReceipt(source, delivery: id, accepted: ack.outcome == "queued")
                if let at = source.messages.lastIndex(where: { $0.text.hasPrefix("Switchboard: awaiting home acceptance → ") && $0.text.contains(id.uuidString) }) {
                    let updated = source.messages[at].text.replacingOccurrences(of: "awaiting home acceptance →", with: (ack.outcome == "queued" ? "queued" : "rejected") + " →")
                    let pieces = updated.components(separatedBy: "\n")
                    source.messages[at].text = pieces[0] + " · " + (ack.detail ?? "") + "\n" + pieces.dropFirst().joined(separator: "\n")
                }
                store.save()
                publishSwitchboardQueue(source.id)
            }
            return true
        }
        func ack(_ outcome: String, _ detail: String) {
            sendEnvelope(peer, DeviceEnvelope(kind: "participant.tell.ack", commandID: id, payload: try? JSONEncoder().encode(DeviceAckPayload(outcome: outcome, detail: detail))))
        }
        guard let bytes = envelope.payload, let request = try? JSONDecoder().decode(DeviceTellPayload.self, from: bytes),
              request.groupID == group, let from = DeviceGlobalID(request.source), from.home == origin,
              let to = DeviceGlobalID(request.target), to.home == identity?.deviceID,
              request.hop > 0, request.hop <= SwitchboardPolicy.maxHops, !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.text.utf8.count <= 32768, request.sourceTitle.utf8.count <= 1000 else { ack("rejected", "Invalid or out-of-group message. Nothing was queued."); return true }
        let hash = DeviceBlob.sha256Hex((try? DeviceCanonical.encode(request)) ?? bytes)
        if let receipt = store.groupTellReceipts.first(where: { $0.id == id }) {
            ack(receipt.origin == origin && receipt.payloadHash == hash ? "queued" : "rejected", "Previously recorded delivery; nothing queued twice.")
            return true
        }
        guard let target = store.sessions.first(where: { $0.id == to.session }), target.switchboardEnabled else {
            ack("rejected", "Target is closed or session messaging is disabled. Nothing was queued."); return true
        }
        guard store.groupTellReceipts.count < 100000 else { ack("rejected", "Home delivery journal is full. Nothing was queued."); return true }
        let label = "[Converse message from " + request.sourceTitle + " · session " + from.string + " · delivery " + id.uuidString + " · hop " + String(request.hop) + "/" + String(SwitchboardPolicy.maxHops) + "]\n" + request.text + Store.replyInstruction(id: id, expected: request.replyExpected == true, inReplyTo: request.inReplyTo)
        let prompt = PendingPrompt(switchboardHop: request.hop, originGroupID: group, originHomeID: origin, text: label, images: [])
        guard target.switchboardObligations.filter({ !$0.terminal }).count < 128 else { ack("rejected", "Supervision journal is full."); return true }
        let oldWatches = target.switchboardObligations, oldExpected = target.switchboardExpectations
        let oldPending = target.pending, oldMessages = target.messages
        if request.urgent { target.pending.insert(prompt, at: 0) } else { target.pending.append(prompt) }
        store.switchboardReceived(target, source: from.string, name: request.sourceTitle, id: id, prompt: prompt, replyExpected: request.replyExpected == true, inReplyTo: request.inReplyTo, group: group, home: origin)
        store.groupTellReceipts.append(GroupTellReceipt(id: id, origin: origin, payloadHash: hash))
        do { try store.saveChecked() }
        catch { target.switchboardObligations = oldWatches; target.switchboardExpectations = oldExpected; target.pending = oldPending; target.messages = oldMessages; store.groupTellReceipts.removeAll { $0.id == id }; ack("rejected", "Home could not save delivery. Nothing was queued."); return true }
        publishSwitchboardQueue(target.id)
        ack("queued", "Persisted on " + deviceName + ". Queued does not mean read or answered.")
        if request.urgent { target.queuePaused = false; if target.busy { target.resumeAfterInterrupt = true; store.interruptProcess(target) } }
        if !target.busy { DispatchQueue.main.async { store.runNext(target) } }
        return true
    }
    #endif
}

extension DeviceSyncService {
    func canCreateRemote(_ home: String) -> Bool {
        peerForHome(home)?.hello?.capabilities.contains("session-create-v1") == true
    }
    func canRenameRemote(_ home: String) -> Bool {
        peerForHome(home)?.hello?.capabilities.contains("session-rename-v1") == true
    }
    @MainActor func renameRemoteSession(_ target: String, title: String) async -> DeviceParticipantResponse {
        guard let reference = DeviceGlobalID(target), canRenameRemote(reference.home) else {
            return DeviceParticipantResponse(groupID: currentGroup?.id ?? "", outcome: "rejected", detail: "Home is offline or needs an update for remote renaming.")
        }
        return await requestParticipant(home: reference.home, action: "session.rename", target: target, title: title)
    }
    func canCloseRemote(_ home: String) -> Bool {
        peerForHome(home)?.hello?.capabilities.contains("session-close-v1") == true
    }
    @MainActor func closeRemoteSession(_ target: String) async -> DeviceParticipantResponse {
        guard let reference = DeviceGlobalID(target) else { return DeviceParticipantResponse(groupID: currentGroup?.id ?? "", outcome: "rejected", detail: "Unknown session.") }
        return await requestParticipant(home: reference.home, action: "session.close", target: target)
    }
    func canHostAgent(_ home: String) -> Bool {
        #if os(macOS)
        if home == identity?.deviceID { return true }
        #endif
        return peerForHome(home)?.hello?.capabilities.contains("agent-host-v1") == true
    }
    @MainActor func requestParticipant(home: String, action: String, target: String? = nil, title: String? = nil, settings: DeviceAgentSettings? = nil, provider: String? = nil, imageAssist: DeviceImageAssistRequest? = nil, exportRequest: DeviceExportRequest? = nil, id explicitID: UUID? = nil) async -> DeviceParticipantResponse {
        guard let group = currentGroup?.id, acceptsParticipant(home: home, groupID: group), let peer = peerForHome(home),
              peer.hello?.capabilities.contains("participant-control-v1") == true else {
            return DeviceParticipantResponse(groupID: currentGroup?.id ?? "", outcome: "rejected", detail: "Home is offline, outside this group, or needs an update.")
        }
        if action == "image.assist" && peer.hello?.capabilities.contains("image-assist-v1") != true {
            return DeviceParticipantResponse(groupID: group, outcome: "rejected", detail: "Image tools require an updated Mac home in this first version.")
        }
        if action == "session.export" && peer.hello?.capabilities.contains("transcript-export-v1") != true {
            return DeviceParticipantResponse(groupID: group, outcome: "rejected", detail: "Update this session's home app to export its full transcript remotely.")
        }
        if imageAssist?.operation == "segments" && peer.hello?.capabilities.contains("image-segments-v1") != true {
            return DeviceParticipantResponse(groupID: group, outcome: "rejected", detail: "Update the Mac home to use multi-object segmentation.")
        }
        if !(settings?.artDirection ?? "").isEmpty && peer.hello?.capabilities.contains("agent-art-direction-v1") != true {
            return DeviceParticipantResponse(groupID: group, outcome: "rejected", detail: "Update the home app before saving scoreboard art direction.")
        }
        if !(settings?.scheduleText ?? "").isEmpty && peer.hello?.capabilities.contains("agent-schedule-v1") != true {
            return DeviceParticipantResponse(groupID: group, outcome: "rejected", detail: "Update the home app before using text schedules; it currently supports numeric intervals only.")
        }
        let request = DeviceParticipantRequest(provider: provider, groupID: group, action: action, target: target, title: title, settings: settings, imageAssist: imageAssist, exportRequest: exportRequest)
        let durable = !["inspect", "agent.settings", "session.export"].contains(action)
        let previous = participantIntents.first { $0.home == home && $0.request == request && ["pending", "uncertain"].contains($0.outcome) }
        let id = explicitID ?? previous?.id ?? UUID()
        if let old = participantIntents.first(where: { $0.id == id }), old.home != home || old.request != request {
            return DeviceParticipantResponse(groupID: group, outcome: "rejected", detail: "Command ID is already bound to another operation.")
        }
        if let result = participantIntents.first(where: { $0.id == id })?.response, !["pending", "uncertain"].contains(result.outcome) { return result }
        guard participantReplies[id] == nil else { return DeviceParticipantResponse(groupID: group, outcome: "pending", detail: "This operation is already awaiting home acceptance.") }
        if durable && !participantIntents.contains(where: { $0.id == id }) {
            guard participantIntents.count < 10000 else { return DeviceParticipantResponse(groupID: group, outcome: "rejected", detail: "Outgoing operation journal is full.") }
            participantIntents.append(DeviceParticipantIntent(id: id, home: home, request: request))
            do { try saveParticipantIntents() }
            catch { participantIntents.removeAll { $0.id == id }; return DeviceParticipantResponse(groupID: group, outcome: "rejected", detail: "Could not save outgoing operation. Nothing was sent.") }
        }
        return await withCheckedContinuation { continuation in
            participantReplies[id] = (home, group, { continuation.resume(returning: $0) })
            sendEnvelope(peer, DeviceEnvelope(kind: "participant.request", commandID: id, payload: try? DeviceCanonical.encode(request)))
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, let pending = self.participantReplies.removeValue(forKey: id) else { return }
                if let index = self.participantIntents.firstIndex(where: { $0.id == id }) { self.participantIntents[index].outcome = "uncertain"; try? self.saveParticipantIntents() }
                pending.finish(DeviceParticipantResponse(groupID: group, outcome: "uncertain", detail: "Home response unconfirmed. Retry uses the saved operation ID; nothing replays automatically."))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (action == "image.assist" ? 195 : 20), execute: timeout)
        }
    }
    private func loadParticipantIntents() throws {
        let file = storageFolder.appendingPathComponent("participant-outbox.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        participantIntents = try JSONDecoder().decode([DeviceParticipantIntent].self, from: Data(contentsOf: file))
        for index in participantIntents.indices where participantIntents[index].outcome == "pending" { participantIntents[index].outcome = "uncertain" }
    }
    private func saveParticipantIntents() throws {
        let file = storageFolder.appendingPathComponent("participant-outbox.json")
        try DeviceCanonical.encode(participantIntents).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func handleParticipantControl(_ peer: DevicePeer, _ envelope: DeviceEnvelope) -> Bool {
        guard ["participant.request", "participant.response"].contains(envelope.kind) else { return false }
        guard let origin = peer.hello?.deviceID, let group = currentGroup?.id,
              acceptsParticipant(home: origin, groupID: group), !peer.controlOnly,
              peer.hello?.capabilities.contains("participant-control-v1") == true, let id = envelope.commandID else { return true }
        if envelope.kind == "participant.response" {
            let pending = participantReplies[id]
            let intent = participantIntents.first(where: { $0.id == id })
            guard (pending?.home == origin && pending?.group == group) || (intent?.home == origin && intent?.request.groupID == group),
                  let bytes = envelope.payload, let result = try? JSONDecoder().decode(DeviceParticipantResponse.self, from: bytes), result.groupID == group else { return true }
            if let index = participantIntents.firstIndex(where: { $0.id == id }) {
                participantIntents[index].outcome = result.outcome; participantIntents[index].response = result
                do { try saveParticipantIntents() } catch { lastOutcome = "Home replied, but the local receipt could not be saved. Check home before retrying." }
            }
            participantReplies.removeValue(forKey: id)?.finish(result)
            return true
        }
        func send(_ result: DeviceParticipantResponse) { sendEnvelope(peer, DeviceEnvelope(kind: "participant.response", commandID: id, payload: try? JSONEncoder().encode(result))) }
        func reject(_ detail: String) { send(DeviceParticipantResponse(groupID: group, outcome: "rejected", detail: detail)) }
        guard let bytes = envelope.payload, bytes.count <= 64000, let request = try? JSONDecoder().decode(DeviceParticipantRequest.self, from: bytes), request.groupID == group else { reject("Invalid or former-group request."); return true }
        #if os(macOS)
        let store = participantStore
        // Resolve with a separate binding; never match a same-UUID foreign home.
        let global = request.target.flatMap(DeviceGlobalID.init)
        let session = global.flatMap { reference in reference.home == identity?.deviceID ? store.sessions.first(where: { $0.id == reference.session }) : nil }
        if request.action == "session.export" {
            let lot = global.flatMap { reference in reference.home == identity?.deviceID ? parkingLibrary.lot(reference.session) : nil }
            guard session != nil || lot?.active == true, let q = request.exportRequest, q.offset >= 0 else { reject("Invalid export target or offset."); return true }
            do {
                let messages = lot?.exportMessages ?? session!.messages.filter { ["user", "assistant"].contains($0.role) }
                if let hash = q.imageHash {
                    guard messages.flatMap(\.images).contains(where: { imageHash(path: $0) == hash }), let path = blobPaths[hash],
                          let size = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= 25_000_000, q.offset <= size else { reject("Image unavailable in this transcript."); return true }
                    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
                    try file.seek(toOffset: UInt64(q.offset))
                    let chunk = try file.read(upToCount: 262144) ?? Data()
                    send(DeviceParticipantResponse(groupID: group, outcome: "completed", detail: "Export image chunk.", target: request.target, exportImage: chunk, exportImageTotal: size)); return true
                }
                let total = q.total ?? messages.count
                guard total >= 0, total <= messages.count, q.offset <= total else { reject("Transcript changed; export again."); return true }
                let snapshot = Array(messages.prefix(total))
                let fingerprint = DeviceBlob.sha256Hex(try DeviceCanonical.encode(snapshot))
                guard q.fingerprint == nil || q.fingerprint == fingerprint else { reject("Transcript changed while exporting; try again when the turn finishes."); return true }
                let page = DeviceExportPage(title: lot?.name ?? session!.title, provider: lot != nil ? "Parking Lot" : session!.entry.name, offset: q.offset, total: total, fingerprint: fingerprint,
                    messages: snapshot.dropFirst(q.offset).prefix(20).map { wireMessage($0) })
                let response = DeviceParticipantResponse(groupID: group, outcome: "completed", detail: "Read-only transcript export.", target: request.target, exportPage: page)
                guard try JSONEncoder().encode(response).count <= 2_000_000 else { reject("A message is too large for remote export."); return true }
                send(response)
            } catch { reject("Could not read transcript for export.") }
            return true
        }
        if request.action == "inspect" {
            guard let session, let global else { reject("Target is closed or belongs to another home."); return true }
            let evidence = DeviceParticipantEvidence(globalID: global.string, title: session.title, busy: session.busy, status: session.status,
                messages: session.messages.filter { ["user", "assistant", "notice"].contains($0.role) }.suffix(20).map { DeviceWireMessage(id: $0.id, role: $0.role, text: String($0.text.prefix(4000))) })
            send(DeviceParticipantResponse(groupID: group, outcome: "completed", detail: "Home evidence snapshot.", target: global.string, evidence: evidence)); return true
        }
        if request.action == "agent.settings" {
            guard let config = session?.agent, let home = identity?.deviceID else { reject("Target is not an agent on this home."); return true }
            Task { @MainActor in
                var settings = config.wire(home: home)
                settings.modelOptions = await AgentModels.catalog(store: store)
                send(DeviceParticipantResponse(groupID: group, outcome: "completed", detail: "Home-local credentials are never included.", target: request.target, settings: settings))
            }
            return true
        }
        let hash = DeviceBlob.sha256Hex((try? DeviceCanonical.encode(request)) ?? bytes)
        if let record = store.participantReceipts.first(where: { $0.id == id }) {
            if record.origin == origin && record.payloadHash == hash { send(record.response) } else { reject("Command ID is bound to a different request.") }
            return true
        }
        guard store.participantReceipts.count < 100000 else { reject("Home command journal is full."); return true }
        if request.action == "image.assist" {
            guard let session, let global, let operation = request.imageAssist,
                  leases?.validate(session: session.id, device: origin, epoch: operation.epoch) == true,
                  ["describe", "focus", "segments"].contains(operation.operation),
                  (draftAttachments[session.id.uuidString] ?? []).contains(operation.hash),
                  let path = blobPaths[operation.hash], let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  DeviceBlob.sha256Hex(bytes) == operation.hash else { reject("Take this session and wait for the attachment to be stored on home before using image tools."); return true }
            guard imageAssistInFlight.count < 2 else { reject("Home is processing two images. Try again shortly."); return true }
            let key: String
            do {
                guard let saved = try imageAssistKey(), !saved.isEmpty else { reject("Add a Meta API key in Agent Setup on the Mac home to use image tools. The session can use any provider."); return true }
                key = saved
            } catch { reject("Could not read the Meta API key on home. Open Agent Setup on that Mac."); return true }
            let reserved = DeviceParticipantResponse(groupID: group, outcome: "uncertain", detail: "Image request started. Check this operation again for its result; it will not run twice.", target: global.string)
            store.participantReceipts.append(ParticipantMutationReceipt(id: id, origin: origin, payloadHash: hash, response: reserved))
            do { try store.saveChecked() } catch { store.participantReceipts.removeAll { $0.id == id }; reject("Could not save image operation. Nothing was sent to Meta."); return true }
            imageAssistInFlight.insert(id)
            Task { @MainActor in
                defer { self.imageAssistInFlight.remove(id) }
                var result: DeviceParticipantResponse
                do {
                    let output = try await self.imageAssistAPI.assistImage(bytes, request: operation, key: key)
                    result = DeviceParticipantResponse(groupID: group, outcome: "completed", detail: "Review before adding to your draft.", target: global.string, imageAssist: output)
                } catch {
                    let detail = (error is ImageAssistError || error is AgentFailure) ? error.localizedDescription : "Image request failed or timed out. Original attachment unchanged."
                    result = DeviceParticipantResponse(groupID: group, outcome: "failed", detail: detail, target: global.string)
                }
                guard let index = store.participantReceipts.firstIndex(where: { $0.id == id }) else { return }
                store.participantReceipts[index].response = result
                do { try store.saveChecked() }
                catch { store.participantReceipts[index].response = reserved; result = reserved }
                if self.currentGroup?.id == group, self.acceptsParticipant(home: origin, groupID: group) { send(result) }
            }
            return true
        }
        if request.action == "session.close" {
            guard global?.home == identity?.deviceID else { reject("Target belongs to another home."); return true }
            let result = DeviceParticipantResponse(groupID: group, outcome: "completed", detail: "Session closed on home. A recovery snapshot was saved.", target: request.target)
            let receipt = ParticipantMutationReceipt(id: id, origin: origin, payloadHash: hash, response: result)
            do {
                if let session { try store.closeSessionChecked(session, receipt: receipt); if self !== DeviceSyncService.shared { homeSessionClosed(session.id) } }
                else { store.participantReceipts.append(receipt); try store.saveChecked() }
                send(result); publishSidebarIfChanged()
            } catch {
                store.participantReceipts.removeAll { $0.id == id }
                reject("Home could not save the close operation. The session remains open.")
            }
            return true
        }
        var created: Session?
        let oldTitle = session?.title
        let oldTitleDate = session?.titleUpdatedAt
        let oldIdentityChanged = session?.identityChanged
        let oldQueuePaused = session?.queuePaused
        let oldConfig = session?.agent
        let oldPending = session?.pending
        let oldModel = session?.toolStatus.model
        var runAfterCommit = false
        var widgetAfterCommit = false
        var pacingAfterCommit = false
        var migrationNotice: String? = nil
        do {
            let result: DeviceParticipantResponse
            switch request.action {
            case "session.rename":
                let name = request.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let session, !name.isEmpty, name.utf8.count <= 200 else { reject("Choose a name of 1–200 bytes for an open session on this home."); return true }
                // Persist the rename and receipt in one archive write, before publishing identity.
                session.identityChanged = nil
                session.title = name
                result = DeviceParticipantResponse(groupID: group, outcome: "completed", detail: "Session renamed on home.", target: request.target)
            case "session.create":
                guard let provider = request.provider, ["claude", "codex", "muse"].contains(provider),
                      let entry = store.entries.first(where: { $0.engine == provider }) else { reject("This provider is not configured on home."); return true }
                let newSession = store.create(entry, persist: false); created = newSession
                result = DeviceParticipantResponse(groupID: group, outcome: "completed", detail: "Session created on home. Choose 1, 2 or 3 to display it.", target: DeviceGlobalID(home: identity!.deviceID, session: newSession.id).string)
            case "agent.create":
                let name = request.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Converse Steward"
                guard !name.isEmpty, name.utf8.count <= 200 else { reject("Choose an agent name of 1–200 bytes."); return true }
                let agent = store.createAgent(title: name, persist: false); created = agent
                result = DeviceParticipantResponse(groupID: group, outcome: "completed", detail: "Agent created paused. Configure API credentials on its home.", target: DeviceGlobalID(home: identity!.deviceID, session: agent.id).string)
            case "agent.run":
                guard let session, let config = session.agent, config.turnLimit > 0, session.pending.count < 100 else { reject("Agent missing, budget exhausted, or queue full."); return true }
                session.pending.append(PendingPrompt(originGroupID: group, originHomeID: origin, agentRunReserved: true, autonomous: true, text: "[Human-requested agent run from group device] Check progress and refresh the scoreboard.", images: []))
                runAfterCommit = true
                result = DeviceParticipantResponse(groupID: group, outcome: "completed", detail: session.queuePaused ? "Run saved in paused queue. Resume the queue to run it." : "Agent run queued on home.", target: request.target)
            case "agent.widget":
                guard session?.agent != nil else { reject("Target is not an agent."); return true }
                widgetAfterCommit = true
                result = DeviceParticipantResponse(groupID: group, outcome: "completed", detail: "Scoreboard opened on home.", target: request.target)
            case "agent.configure":
                guard let session, session.agent != nil, let settings = request.settings else { reject("Agent or settings missing."); return true }
                guard (settings.homeAssistantURL == nil || settings.homeAssistantURL == session.agent?.homeAssistantURL),
                      (settings.homeAssistantEntities == nil || settings.homeAssistantEntities == session.agent?.homeAssistantEntities),
                      (settings.homeAssistantRead == nil || settings.homeAssistantRead == session.agent?.homeAssistantRead) else {
                    reject("Change Home Assistant access on the agent's home computer so its saved token and entity scope stay under local control."); return true
                }
                guard settings.watched.allSatisfy({ ref in DeviceGlobalID(ref).map { acceptsParticipant(home: $0.home, groupID: group) } == true }) else { reject("Scope includes a participant outside this group."); return true }
                migrationNotice = try session.agent?.apply(settings); pacingAfterCommit = true; session.toolStatus.model = AgentModels.label(settings.model)
                if settings.enabled && session.pending.isEmpty { session.queuePaused = false }
                result = DeviceParticipantResponse(groupID: group, outcome: "completed", detail: "Agent settings saved on home.", target: request.target, settings: session.agent?.wire(home: identity!.deviceID))
            default: reject("Unsupported participant operation."); return true
            }
            store.participantReceipts.append(ParticipantMutationReceipt(id: id, origin: origin, payloadHash: hash, response: result))
            try store.saveChecked(); send(result); publishSidebarIfChanged()
            if request.action == "session.rename", let session {
                session.identityChanged = oldIdentityChanged; store.syncIdentity(session)
                for holder in peers.values where holder.leasedSessions.contains(session.id) { sendTranscript(to: holder, sessionID: session.id) }
            }
            if let session, runAfterCommit { DispatchQueue.main.async { store.runNext(session) } }
            if let session, widgetAfterCommit, !isTestEnvironment { MainActor.assumeIsolated { AgentWindows.shared.widget(session) } }
            if let session, pacingAfterCommit { MainActor.assumeIsolated { AgentRuntime.shared.objectiveSaved(session, store: store, notice: migrationNotice) } }
        } catch {
            if request.action == "session.rename", let session, let oldTitle {
                session.title = oldTitle; if let oldTitleDate { session.titleUpdatedAt = oldTitleDate }
                session.identityChanged = oldIdentityChanged
            }
            if let created { store.sessions.removeAll { $0 === created } }
            if let session { session.agent = oldConfig; session.pending = oldPending ?? []; if let oldQueuePaused { session.queuePaused = oldQueuePaused }; if let oldModel { session.toolStatus.model = oldModel } }
            store.participantReceipts.removeAll { $0.id == id }
            if let validation = error as? AgentFailure { reject(validation.localizedDescription) }
            else if let validation = error as? AgentScheduleError { reject(validation.localizedDescription) }
            else { reject("Home could not persist the operation. Nothing was applied. Try again after checking the home device.") }
        }
        #else
        reject("This device is a viewer. Choose a capable agent home.")
        #endif
        return true
    }
}


extension DeviceSyncService {
    func switchboardDisplayName(_ raw: String) -> String? {
        let global = DeviceGlobalID(raw)
        #if os(macOS)
        if let id = UUID(uuidString: raw) ?? (global?.home == localDeviceID ? global?.session : nil),
           let session = participantStore.sessions.first(where: { $0.id == id }) { return session.title }
        #endif
        let matches = participantHomes.flatMap { $0.rows }.filter { row in
            row.globalID == raw || (global == nil && DeviceGlobalID(row.globalID)?.session.uuidString.lowercased() == raw.lowercased())
        }
        return matches.count == 1 ? matches[0].title : nil
    }
}

#if os(macOS)
private final class LotHomeStream {
    var sequence: UInt64 = 1
    var receipts: [UUID: (String, LotEditAck)] = [:]
    var order: [UUID] = []
    var lastSnapshot: String?
    var barrier = false
    var history: [String] = []
}
private struct LotTransfer {
    var epoch: UInt64
    var renewUntil: Date
    var finish: () -> Void
}
private final class LotHomeProposal {
    let id: UUID
    let edits: ParkingLotEdits
    let author: String
    let epoch: UInt64
    let allowed: () -> Bool
    let finish: (Result<String, Error>) -> Void
    let expires = Date().addingTimeInterval(120)
    var preview: LotProposalPreview?
    var previewDocument: ParkingLotDocument?
    init(id: UUID, edits: ParkingLotEdits, author: String, epoch: UInt64, allowed: @escaping () -> Bool, finish: @escaping (Result<String, Error>) -> Void) {
        self.id = id; self.edits = edits; self.author = author; self.epoch = epoch; self.allowed = allowed; self.finish = finish
    }
}
#endif

extension DeviceSyncService {
    func supportsLotEditing(_ id: String) -> Bool {
        guard editableLotsEnabled, let global = DeviceGlobalID(id), let peer = peerForHome(global.home) else { return false }
        return peer.hello?.capabilities.contains(LotEditing.capability) == true
    }
    func lotCanEdit(_ id: String) -> Bool {
        guard let editor = lotEditors[id], editor.frozenReason == nil, !editor.draining,
              remoteLeases[id] == editor.saved.leaseEpoch, !remoteOffline.contains(id),
              let renewed = lotRenewed[id], Date().timeIntervalSince(renewed) < 10 else { return false }
        return lotProposals[id] == nil
    }
    func editLot(_ id: String, operation: LotOperation) throws {
        #if os(iOS)
        let measurement = PerformanceCapture.shared.begin()
        defer { PerformanceCapture.shared.end(.lotLocalEdit, measurement) }
        #endif
        guard lotCanEdit(id), var editor = lotEditors[id] else { throw ParkingLotError.message("This lot is not currently editable. Take it again when its home is connected.") }
        if editor.unconfirmedCount >= LotEditing.maximumPending { freezeLot(id, reason: "Too many edits are awaiting confirmation. Copy unsaved text before taking the lot again."); throw ParkingLotError.message("Save queue is full.") }
        try editor.enqueue(operation); lotEditors[id] = editor; sendNextLotEdit(id)
    }
    private func sendNextLotEdit(_ id: String) {
        guard var editor = lotEditors[id], let global = DeviceGlobalID(id), let peer = peerForHome(global.home) else { return }
        do {
            if let edit = try editor.beginNext() {
                lotEditors[id] = editor; lotSent[id] = Date(); lotStarted[id] = Date()
                #if os(iOS)
                PerformanceCapture.shared.startRoundTrip(edit.mutationID)
                #endif
                sendEnvelope(peer, DeviceEnvelope(kind: "lot.edit", boot: edit.homeBoot, sessionID: id, epoch: edit.leaseEpoch, payload: try LotEditing.encoded(edit)))
            } else if editor.unconfirmedCount == 0 {
                if lotHandoffs.remove(id) != nil {
                    onRemotePark?(id)
                    sendEnvelope(peer, DeviceEnvelope(kind: "lot.handoff.ready", boot: editor.saved.homeBoot, sessionID: id, epoch: editor.saved.leaseEpoch, payload: try LotEditing.encoded(editor.saved.digest)))
                    remoteLeases.removeValue(forKey: id); forgetDisplay(id)
                } else if lotReleases.remove(id) != nil { releaseRemote(globalID: id) }
                else if let proposal = lotProposals[id], proposal.before == nil {
                    sendEnvelope(peer, DeviceEnvelope(kind: "lot.barrier", boot: editor.saved.homeBoot, sessionID: id, commandID: proposal.id, epoch: editor.saved.leaseEpoch))
                }
            }
        } catch { freezeLot(id, reason: error.localizedDescription) }
    }
    private func freezeLot(_ id: String, reason: String, cleanReason: String? = nil) {
        guard var editor = lotEditors[id] else { return }
        #if os(iOS)
        if let edit = editor.inFlight { PerformanceCapture.shared.abandonRoundTrip(edit.mutationID) }
        #endif
        if editor.unconfirmedCount > 0 { lotRecovery[id] = editor.projected }
        editor.frozenReason = editor.unconfirmedCount == 0 ? (cleanReason ?? reason) : reason; lotEditors[id] = editor
        lotProposals.removeValue(forKey: id)
        lastOutcome = editor.frozenReason ?? reason
    }
    func decideLotProposal(_ id: String, approved: Bool) {
        guard let proposal = lotProposals[id], let editor = lotEditors[id], let global = DeviceGlobalID(id), let peer = peerForHome(global.home),
              !approved || (proposal.before != nil && proposal.after != nil && proposal.previewDigest != nil) else { return }
        let response = LotProposalDecision(id: proposal.id, approved: approved, previewDigest: proposal.previewDigest)
        sendEnvelope(peer, DeviceEnvelope(kind: "lot.proposal.resolve", boot: editor.saved.homeBoot, sessionID: id, epoch: editor.saved.leaseEpoch, payload: try? LotEditing.encoded(response)))
    }
    private func tickLots() {
        let now = Date()
        for (id, editor) in lotEditors where remoteLeases[id] == editor.saved.leaseEpoch && editor.frozenReason == nil {
            if remoteOffline.contains(id) || now.timeIntervalSince(lotRenewed[id] ?? .distantPast) >= 10 {
                freezeLot(id, reason: "Home connection is uncertain. Editing paused; unconfirmed changes can be copied.", cleanReason: "Home connection is uncertain. No unsaved changes. Editing paused.")
            } else if let start = lotStarted[id], now.timeIntervalSince(start) >= 15 {
                freezeLot(id, reason: "Home has not confirmed the save. Editing paused; unconfirmed text can be copied.")
            } else if let sent = lotSent[id], now.timeIntervalSince(sent) > 5, let edit = editor.inFlight,
                      let global = DeviceGlobalID(id), let peer = peerForHome(global.home) {
                // Same-boot identical retry only; no fresh ID or speculative base revision.
                sendEnvelope(peer, DeviceEnvelope(kind: "lot.edit", boot: edit.homeBoot, sessionID: id, epoch: edit.leaseEpoch, payload: try? LotEditing.encoded(edit)))
                lotSent[id] = now
            }
        }
        #if os(macOS)
        lotUploads = lotUploads.filter { key, _ in
            let parts = key.split(separator: "/")
            guard parts.count == 4, let lot = UUID(uuidString: String(parts[1])), let epoch = UInt64(parts[2]) else { return false }
            return leases?.validate(session: lot, device: String(parts[0]), epoch: epoch) == true
        }
        for (id, transfer) in Array(lotTransfers) where leases?.holder(session: id) == nil {
            lotTransfers.removeValue(forKey: id); transfer.finish()
        }
        for (id, proposal) in Array(lotProposalRequests) where proposal.expires <= now || !proposal.allowed() || leases?.holder(session: id)?.epoch != proposal.epoch {
            finishLotProposal(id, result: .failure(ParkingLotError.message("Parking Lot review expired or its holder changed. No changes applied.")))
        }
        #endif
    }
    private func handleLotEnvelope(_ peer: DevicePeer, _ envelope: DeviceEnvelope) -> Bool {
        guard let device = peer.hello?.deviceID else { return false }
        #if os(macOS)
        if editableLotsEnabled, let lot = homeParkingLot(envelope) {
            let compatible = peer.hello?.capabilities.contains(LotEditing.capability) == true
            let reader = peer.hello?.capabilities.contains(LotEditing.readOnlyCapability) == true
            if ["lease.acquire", "lease.resume"].contains(envelope.kind) {
                guard compatible || reader else {
                    sendEnvelope(peer, DeviceEnvelope(kind: "lease.denied", boot: boot, sessionID: envelope.sessionID, payload: Data("Update Converse to open this Parking Lot.".utf8))); return true
                }
                if envelope.kind == "lease.resume", (leases?.epochs[lot.id] != envelope.epoch || Workspace.shared.placements[lot.id] != nil) {
                    sendEnvelope(peer, DeviceEnvelope(kind: "lease.denied", boot: boot, sessionID: envelope.sessionID)); return true
                }
                if lotTransfers[lot.id] != nil { rejectLot(peer, envelope, "Another take is finishing. Try again once the lot is saved."); return true }
                beginLotTake(lot, target: device) { [weak self, weak peer] in
                    guard let self, let peer, peer.alive, peer.trustedReady else { return }
                    self.grantLot(peer, lot: lot)
                }
                return true
            }
            if envelope.kind == "lease.heartbeat" {
                if let epoch = envelope.epoch, compatible || reader,
                   lotTransfers[lot.id].map({ Date() < $0.renewUntil }) ?? true,
                   leases?.heartbeat(session: lot.id, device: device, epoch: epoch) == true {
                    sendEnvelope(peer, DeviceEnvelope(kind: "lot.lease.renewed", boot: boot, sessionID: envelope.sessionID, epoch: epoch))
                }
                return true
            }
            if envelope.kind == "lease.release" {
                if let epoch = envelope.epoch { leases?.release(session: lot.id, device: device, epoch: epoch) }
                peer.leasedSessions.remove(lot.id); publishSidebarIfChanged(); return true
            }
            if envelope.kind.hasPrefix("lot.") || ["blob.offer", "blob.chunk", "blob.complete", "blob.request"].contains(envelope.kind) {
                guard compatible || (reader && envelope.kind == "blob.request"), let epoch = envelope.epoch, leases?.validate(session: lot.id, device: device, epoch: epoch) == true,
                      envelope.boot == nil || envelope.boot == boot else { rejectLot(peer, envelope, "Parking Lot authority expired. No changes applied."); return true }
                if envelope.kind.hasPrefix("lot."), envelope.boot != boot { rejectLot(peer, envelope, "Home restarted. Take the Parking Lot again."); return true }
                do {
                    switch envelope.kind {
                    case "lot.edit": try receiveLotEdit(peer, envelope, lot: lot)
                    case "lot.handoff.ready":
                        guard let transfer = lotTransfers[lot.id], transfer.epoch == epoch,
                              let data = envelope.payload, let digest = try? JSONDecoder().decode(String.self, from: data),
                              digest == (try lotSnapshot(lot, epoch: epoch)).digest else { throw ParkingLotError.message("Handoff did not confirm the last saved revision.") }
                        lotTransfers.removeValue(forKey: lot.id); transfer.finish()
                    case "lot.barrier": try previewLotProposal(peer, envelope, lot: lot)
                    case "lot.proposal.resolve": try resolveLotProposal(peer, envelope, lot: lot)
                    case "blob.offer", "blob.chunk", "blob.complete": try receiveLotBlob(peer, envelope, lot: lot)
                    case "blob.request": return false // Existing download path does the lot-scoped hash check.
                    default: break
                    }
                } catch { rejectLot(peer, envelope, error.localizedDescription) }
                return true
            }
        }
        #endif
        if editableLotsEnabled, envelope.kind == DeviceMessageKind.blobAck.rawValue,
           let id = envelope.sessionID, remoteRow(globalID: id)?.engine == "parking" {
            guard DeviceGlobalID(id)?.home == device, let epoch = envelope.epoch, remoteLeases[id] == epoch,
                  envelope.boot == leaseBoots[id], let data = envelope.payload,
                  let ack = try? JSONDecoder().decode(DeviceAckPayload.self, from: data),
                  let hash = ack.detail?.split(separator: "|").first.map(String.init), lotPendingUploads[id]?[hash] == epoch else { return true }
            lotPendingUploads[id]?.removeValue(forKey: hash)
            if ack.outcome == "stored" { lotBlobReady[id, default: []].insert(hash) }
            else { lotNotices[id] = "The image was not saved. Attach it again when home is available." }
            return true
        }
        guard envelope.kind.hasPrefix("lot."), let id = envelope.sessionID, DeviceGlobalID(id)?.home == device else { return false }
        if editableLotsEnabled, envelope.kind == "lot.rejected", pendingTakes[id] != nil {
            pendingTakes.removeValue(forKey: id)
            let reason = envelope.payload.map { String(decoding: $0, as: UTF8.self) } ?? "The lot could not be taken."
            lotNotices[id] = reason; lastOutcome = reason; return true
        }
        guard editableLotsEnabled, peer.hello?.capabilities.contains(LotEditing.capability) == true,
              envelope.epoch == remoteLeases[id], envelope.boot == leaseBoots[id] else { return true }
        do {
            switch envelope.kind {
            case "lot.snapshot":
                guard let data = envelope.payload else { return true }
                let snapshot = try JSONDecoder().decode(LotSnapshot.self, from: data)
                guard snapshot.globalID == id, snapshot.homeBoot == envelope.boot, snapshot.leaseEpoch == envelope.epoch else { throw ParkingLotError.message("Snapshot authority mismatch.") }
                if var editor = lotEditors[id], editor.saved.leaseEpoch == snapshot.leaseEpoch, editor.saved.homeBoot == snapshot.homeBoot {
                    try editor.installExternal(snapshot)
                    // A fresh authenticated snapshot under the current lease safely resumes a clean queue.
                    editor.frozenReason = nil; lotEditors[id] = editor
                } else {
                    if let previous = lotEditors[id], previous.unconfirmedCount > 0 { lotRecovery[id] = previous.projected }
                    #if os(iOS)
                    if let previous = lotEditors[id]?.inFlight { PerformanceCapture.shared.abandonRoundTrip(previous.mutationID) }
                    #endif
                    lotEditors[id] = try LotEditQueue(snapshot: snapshot, author: deviceName)
                    lotSent.removeValue(forKey: id); lotStarted.removeValue(forKey: id)
                    lotHandoffs.remove(id); lotReleases.remove(id); lotProposals.removeValue(forKey: id)
                    lotPendingUploads.removeValue(forKey: id); lotBlobReady.removeValue(forKey: id)
                }
                lotNotices.removeValue(forKey: id)
                lotRenewed[id] = Date()
                for hash in snapshot.document.rows.flatMap({ $0.images ?? [] }) { fetchBlob(globalID: id, hash: hash) }
            case "lot.edit.ack":
                #if os(iOS)
                let measurement = PerformanceCapture.shared.begin()
                defer { PerformanceCapture.shared.end(.lotAckApply, measurement) }
                #endif
                guard let data = envelope.payload, var editor = lotEditors[id] else { return true }
                let ack = try JSONDecoder().decode(LotEditAck.self, from: data)
                if editor.inFlight?.mutationID != ack.mutationID { return true }
                try editor.acknowledge(ack); lotEditors[id] = editor; lotSent.removeValue(forKey: id); lotStarted.removeValue(forKey: id)
                #if os(iOS)
                PerformanceCapture.shared.finishRoundTrip(ack.mutationID)
                #endif
                for hash in editor.saved.document.rows.flatMap({ $0.images ?? [] }) { fetchBlob(globalID: id, hash: hash) }
                sendNextLotEdit(id)
            case "lot.lease.renewed": lotRenewed[id] = Date()
            case "lot.rejected": freezeLot(id, reason: envelope.payload.map { String(decoding: $0, as: UTF8.self) } ?? "Edit was not saved.")
            case "lot.handoff.prepare":
                if var editor = lotEditors[id] { editor.draining = true; lotEditors[id] = editor; lotHandoffs.insert(id); sendNextLotEdit(id) }
            case "lot.proposal":
                guard let data = envelope.payload, var editor = lotEditors[id] else { return true }
                let proposal = try JSONDecoder().decode(LotProposalPreview.self, from: data)
                editor.draining = true; lotEditors[id] = editor; lotProposals[id] = proposal
                for hash in (proposal.after?.rows ?? []).flatMap({ $0.images ?? [] }) { fetchBlob(globalID: id, hash: hash) }
                if proposal.before == nil { sendNextLotEdit(id) }
            case "lot.proposal.closed":
                lotProposals.removeValue(forKey: id)
                if var editor = lotEditors[id] { editor.draining = false; lotEditors[id] = editor }
            default: break
            }
        } catch { freezeLot(id, reason: error.localizedDescription) }
        return true
    }
    #if os(macOS)
    private func rejectLot(_ peer: DevicePeer, _ envelope: DeviceEnvelope, _ reason: String) {
        let kind = peer.hello?.capabilities.contains(LotEditing.capability) == true ? "lot.rejected" : "lease.denied"
        sendEnvelope(peer, DeviceEnvelope(kind: kind, boot: boot, sessionID: envelope.sessionID, epoch: envelope.epoch, payload: Data(reason.utf8)))
    }
    private func lotSnapshot(_ lot: ParkingLotStore, epoch: UInt64, document: ParkingLotDocument? = nil) throws -> LotSnapshot {
        var wire = document ?? lot.document; wire.schemaVersion = ParkingLotDocument.currentSchemaVersion
        for index in wire.rows.indices {
            wire.rows[index].images = try wire.rows[index].images.map { paths in try paths.map { path in
                guard let hash = imageHash(path: path) else { throw ParkingLotError.message("A lot image is unavailable on home. Restore or remove it there before taking this lot.") }
                lotImagePaths[lot.id, default: [:]][hash] = path
                return hash
            } }
        }
        return try LotSnapshot(globalID: DeviceGlobalID(home: identity!.deviceID, session: lot.id).string, homeBoot: boot, leaseEpoch: epoch, name: lot.name, document: wire)
    }
    private func readOnlyLotEnvelope(_ lot: ParkingLotStore, epoch: UInt64, document: ParkingLotDocument? = nil) throws -> DeviceEnvelope {
        let document = document ?? lot.document
        let id = DeviceGlobalID(home: identity!.deviceID, session: lot.id).string
        let payload = DeviceTranscriptPayload(globalID: id,
            homeSeq: stateStore?.nextSeq() ?? 0, epoch: epoch, boot: boot,
            messages: ParkingLotStore.exportMessages(document).map(wireMessage), total: document.rows.count,
            draft: "", draftVersion: UInt64(max(0, document.revision)), busy: false,
            status: "Parking Lot · read only", title: lot.name, engine: "parking")
        let envelope = DeviceEnvelope(kind: "transcript.snapshot", homeSeq: payload.homeSeq, boot: boot,
            sessionID: id, epoch: epoch, payload: try JSONEncoder().encode(payload))
        _ = try DeviceFrame.encode(envelope)
        return envelope
    }
    private func sendLotSnapshot(_ peer: DevicePeer, lot: ParkingLotStore, force: Bool = false) {
        guard let device = peer.hello?.deviceID, let holder = leases?.holder(session: lot.id), holder.device == device,
              peer.hello?.capabilities.contains(LotEditing.capability) == true || peer.hello?.capabilities.contains(LotEditing.readOnlyCapability) == true else { return }
        do {
            let snapshot = try lotSnapshot(lot, epoch: holder.epoch)
            if !force && lotStreams[lot.id]?.lastSnapshot == snapshot.digest { return }
            if peer.hello?.capabilities.contains(LotEditing.capability) == true {
                sendEnvelope(peer, try snapshot.envelope())
            } else {
                sendEnvelope(peer, try readOnlyLotEnvelope(lot, epoch: holder.epoch))
            }
            lotStreams[lot.id]?.lastSnapshot = snapshot.digest
        } catch { rejectLot(peer, DeviceEnvelope(kind: "lot.snapshot", sessionID: DeviceGlobalID(home: identity!.deviceID, session: lot.id).string, epoch: holder.epoch), error.localizedDescription) }
    }
    private func installLotGuard(_ lot: ParkingLotStore) {
        lot.authorityCheck = { [weak self, weak lot] in
            guard let self, let lot else { return }
            if !self.lotWritePermit.contains(lot.id), self.remoteDisplayHolder(lot.id) != nil, !self.lotHasReadOnlyHolder(lot.id) {
                throw ParkingLotError.message("This Parking Lot is held on another device. Take it here before editing.")
            }
        }
        lot.snapshotCheck = { [weak self, weak lot] document in
            guard let self, let lot, let holder = self.leases?.holder(session: lot.id), holder.device != self.identity?.deviceID else { return }
            _ = try self.lotSnapshot(lot, epoch: holder.epoch, document: document).envelope()
            if self.lotHasReadOnlyHolder(lot.id) { _ = try self.readOnlyLotEnvelope(lot, epoch: holder.epoch, document: document) }
        }
    }
    private func withLotPermit<T>(_ id: UUID, _ action: () throws -> T) rethrows -> T {
        lotWritePermit.insert(id); defer { lotWritePermit.remove(id) }; return try action()
    }
    private func grantLot(_ peer: DevicePeer, lot: ParkingLotStore) {
        guard let device = peer.hello?.deviceID, let leases else { return }
        do {
            guard !lot.isReadOnly else { throw ParkingLotError.message(lot.readOnlyReason ?? "Open this lot on home for recovery.") }
            guard (leases.epochs[lot.id] ?? 0) < UInt64.max else { throw ParkingLotError.message("Lot lease epoch exhausted.") }
            // Refuse an unsendable document before displacing anyone.
            _ = try lotSnapshot(lot, epoch: (leases.epochs[lot.id] ?? 0) + 1).envelope()
            if peer.hello?.capabilities.contains(LotEditing.capability) != true {
                _ = try readOnlyLotEnvelope(lot, epoch: (leases.epochs[lot.id] ?? 0) + 1)
            }
            let grant = leases.acquire(session: lot.id, device: device)
            guard grant.granted else { throw ParkingLotError.message("Home could not persist the display lease.") }
            let id = DeviceGlobalID(home: identity!.deviceID, session: lot.id).string
            installLotGuard(lot); lot.undoManager.removeAllActions()
            Workspace.shared.park(lot.id)
            for old in peers.values where old !== peer && old.leasedSessions.contains(lot.id) {
                old.leasedSessions.remove(lot.id); sendEnvelope(old, DeviceEnvelope(kind: "lease.stolen", boot: boot, sessionID: id, epoch: grant.epoch))
            }
            lotStreams[lot.id] = LotHomeStream(); peer.leasedSessions.insert(lot.id)
            sendEnvelope(peer, DeviceEnvelope(kind: "lease.granted", boot: boot, sessionID: id, epoch: grant.epoch))
            sendLotSnapshot(peer, lot: lot, force: true); publishSidebarIfChanged()
        } catch { rejectLot(peer, DeviceEnvelope(kind: "lease.acquire", sessionID: DeviceGlobalID(home: identity!.deviceID, session: lot.id).string), error.localizedDescription) }
    }
    private func beginLotTake(_ lot: ParkingLotStore, target: String, finish: @escaping () -> Void) {
        guard lotTransfers[lot.id] == nil else { lastOutcome = "Waiting for the other device to finish saving."; return }
        if lotProposalRequests[lot.id] != nil { finishLotProposal(lot.id, result: .failure(ParkingLotError.message("Review cancelled because the lot is moving."))) }
        if let holder = leases?.holder(session: lot.id), holder.device != identity?.deviceID, holder.device != target {
            // A read-only viewer cannot have queued writes to drain.
            if lotHasReadOnlyHolder(lot.id) { finish(); return }
            lotTransfers[lot.id] = LotTransfer(epoch: holder.epoch, renewUntil: Date().addingTimeInterval(3), finish: finish)
            if let peer = peers.values.first(where: { $0.trustedReady && $0.hello?.deviceID == holder.device }) {
                sendEnvelope(peer, DeviceEnvelope(kind: "lot.handoff.prepare", boot: boot, sessionID: DeviceGlobalID(home: identity!.deviceID, session: lot.id).string, epoch: holder.epoch))
            }
            lastOutcome = "Waiting for the other device to finish saving."
        } else { finish() }
    }
    func prepareLocalLotTake(_ id: UUID, finish: @escaping () -> Void) -> Bool {
        guard editableLotsEnabled, let lot = parkingLibrary.lot(id), let home = identity?.deviceID, remoteDisplayHolder(id) != nil else { return false }
        beginLotTake(lot, target: home) { [weak self] in
            guard let self else { return }; self.localTake(sessionID: id); lot.undoManager.removeAllActions(); finish()
        }
        return true
    }
    private func receiveLotEdit(_ peer: DevicePeer, _ envelope: DeviceEnvelope, lot: ParkingLotStore) throws {
        let measurement = PerformanceCapture.shared.begin()
        defer { PerformanceCapture.shared.end(.lotEditHandling, measurement) }
        func acknowledge(_ ack: LotEditAck) throws {
            let encoding = PerformanceCapture.shared.begin()
            defer { PerformanceCapture.shared.end(.lotAckEncodeQueue, encoding) }
            sendEnvelope(peer, DeviceEnvelope(kind: "lot.edit.ack", boot: boot, sessionID: envelope.sessionID,
                epoch: envelope.epoch, payload: try LotEditing.encoded(ack)), completion: measurement == nil ? nil : { success in
                    PerformanceCapture.shared.end(success ? .lotEditToAckProcessed : .lotAckSendFailed, measurement)
                })
        }
        guard let data = envelope.payload, let stream = lotStreams[lot.id], !stream.barrier else { throw ParkingLotError.message("This lot is paused for review.") }
        let edit = try JSONDecoder().decode(LotEdit.self, from: data)
        let exactHash = try LotEditing.digest(edit)
        if let receipt = stream.receipts[edit.mutationID] {
            guard receipt.0 == exactHash else { throw ParkingLotError.message("A mutation ID was reused with different contents.") }
            try acknowledge(receipt.1); return
        }
        let snapshot = try lotSnapshot(lot, epoch: envelope.epoch!)
        try edit.validate(against: snapshot, sequence: stream.sequence)
        if edit.operation.kind == .replaceRows {
            guard let rows = edit.operation.rows, stream.history.contains(try LotEditing.digest(rows)) else { throw ParkingLotError.message("Undo history is unavailable for this take.") }
        }
        let result = try edit.operation.applying(to: snapshot.document, author: peer.hello!.deviceName)
        let next = try LotSnapshot(globalID: snapshot.globalID, homeBoot: boot, leaseEpoch: snapshot.leaseEpoch, name: snapshot.name, document: result)
        _ = try next.envelope()
        var local = result
        for index in local.rows.indices {
            local.rows[index].images = try local.rows[index].images.map { hashes in try hashes.map { hash in
                guard let path = lotImagePaths[lot.id]?[hash], FileManager.default.fileExists(atPath: path) else { throw ParkingLotError.message("Image has not been stored for this lot.") }; return path
            } }
        }
        let commit = PerformanceCapture.shared.begin()
        do {
            defer { PerformanceCapture.shared.end(.lotEditCommit, commit) }
            try withLotPermit(lot.id) { try lot.commitRemote(local) }
        }
        let ack = LotEditAck(mutationID: edit.mutationID, sequence: edit.sequence, snapshot: next)
        stream.receipts[edit.mutationID] = (exactHash, ack); stream.order.append(edit.mutationID)
        if stream.order.count > 32 { stream.receipts.removeValue(forKey: stream.order.removeFirst()) }
        stream.history.append(try LotEditing.digest(snapshot.document.rows)); stream.history.append(try LotEditing.digest(result.rows))
        if stream.history.count > 202 { stream.history.removeFirst(stream.history.count - 202) }
        stream.sequence += 1; stream.lastSnapshot = next.digest
        try acknowledge(ack)
    }
    #endif
}

#if os(macOS)
extension DeviceSyncService {
    private func receiveLotBlob(_ peer: DevicePeer, _ envelope: DeviceEnvelope, lot: ParkingLotStore) throws {
        guard let data = envelope.payload, let blob = try? JSONDecoder().decode(DeviceBlobPayload.self, from: data),
              LotEditing.hashIsValid(blob.sha256Hex), let device = peer.hello?.deviceID,
              let epoch = envelope.epoch else { throw ParkingLotError.message("Invalid image upload.") }
        let key = device + "/" + lot.id.uuidString + "/" + String(epoch) + "/" + blob.sha256Hex
        if envelope.kind == "blob.offer" {
            lotUploads.removeValue(forKey: key)
            let stored = lotImagePaths[lot.id]?[blob.sha256Hex].map { FileManager.default.fileExists(atPath: $0) } ?? false
            sendBlobAck(peer, envelope: envelope, hash: blob.sha256Hex, stored: stored, detail: stored ? "Stored for this lot." : "Upload needed.")
            return
        }
        guard lotTransfers[lot.id] == nil, lotProposalRequests[lot.id] == nil,
              (blob.size ?? 0) <= DeviceBlob.maxBlob else { throw ParkingLotError.message("Image upload is paused or exceeds the limit.") }
        if let bytes = blob.chunk {
            guard (lotUploads[key] != nil || lotUploads.count < 32),
                  (lotUploads[key]?.count ?? 0) + bytes.count <= DeviceBlob.maxBlob,
                  lotUploads.values.reduce(0, { $0 + $1.count }) + bytes.count <= DeviceBlob.maxBlob * 4 else {
                lotUploads.removeValue(forKey: key); throw ParkingLotError.message("Image upload exceeds the memory limit.")
            }
            lotUploads[key, default: Data()].append(bytes)
        }
        if blob.done {
            guard let bytes = lotUploads.removeValue(forKey: key), DeviceBlob.verify(bytes, sha256Hex: blob.sha256Hex) else { throw ParkingLotError.message("Image checksum mismatch.") }
            try FileManager.default.createDirectory(at: lot.attachmentFolder, withIntermediateDirectories: true)
            let url = lot.attachmentFolder.appendingPathComponent("Remote-" + blob.sha256Hex + ".png")
            try bytes.write(to: url, options: .atomic)
            lotImagePaths[lot.id, default: [:]][blob.sha256Hex] = url.path
            sendBlobAck(peer, envelope: envelope, hash: blob.sha256Hex, stored: true, detail: "Stored for this lot.")
        }
    }
    private func lotHasReadOnlyHolder(_ id: UUID) -> Bool {
        guard let holder = leases?.holder(session: id), holder.device != identity?.deviceID,
              let peer = peers.values.first(where: { $0.trustedReady && $0.hello?.deviceID == holder.device }) else { return false }
        return peer.hello?.capabilities.contains(LotEditing.readOnlyCapability) == true && peer.hello?.capabilities.contains(LotEditing.capability) != true
    }
    func lotRequiresHolderReview(_ id: UUID) -> Bool {
        editableLotsEnabled && remoteDisplayHolder(id) != nil && !lotHasReadOnlyHolder(id)
    }
    @MainActor func reviewOnLotHolder(_ edits: ParkingLotEdits, lot: ParkingLotStore, author: String, allowed: @escaping () -> Bool) async throws -> String {
        guard let holder = leases?.holder(session: lot.id), holder.device != identity?.deviceID,
              let peer = peers.values.first(where: { $0.trustedReady && $0.hello?.deviceID == holder.device }),
              lotProposalRequests[lot.id] == nil, lotTransfers[lot.id] == nil else { throw ParkingLotError.message("The lot holder is unavailable or already reviewing changes.") }
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let request = LotHomeProposal(id: requestID, edits: edits, author: author, epoch: holder.epoch, allowed: allowed) { continuation.resume(with: $0) }
                lotProposalRequests[lot.id] = request
                let preview = LotProposalPreview(id: request.id, author: author)
                sendEnvelope(peer, DeviceEnvelope(kind: "lot.proposal", boot: boot, sessionID: DeviceGlobalID(home: identity!.deviceID, session: lot.id).string, epoch: holder.epoch, payload: try? LotEditing.encoded(preview)))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.lotProposalRequests[lot.id]?.id == requestID else { return }
                self.finishLotProposal(lot.id, result: .failure(CancellationError()))
            }
        }
    }
    private func previewLotProposal(_ peer: DevicePeer, _ envelope: DeviceEnvelope, lot: ParkingLotStore) throws {
        guard let proposal = lotProposalRequests[lot.id], proposal.id == envelope.commandID, proposal.epoch == envelope.epoch,
              proposal.allowed(), let stream = lotStreams[lot.id] else { throw ParkingLotError.message("Review no longer applies to this holder.") }
        do {
            // All earlier holder edits have committed before this ordered barrier.
            stream.barrier = true
            let before = try lotSnapshot(lot, epoch: proposal.epoch)
            var edits = proposal.edits; edits.revision = lot.document.revision
            let rows = try withLotPermit(lot.id) { try lot.preview(edits, author: proposal.author) }
            let after = try lotSnapshot(lot, epoch: proposal.epoch, document: ParkingLotDocument(revision: lot.document.revision + 1, rows: rows))
            _ = try after.envelope()
            let digest = try LotEditing.digest([before.digest, after.digest, proposal.id.uuidString])
            let preview = LotProposalPreview(id: proposal.id, author: proposal.author, before: before, after: after.document, previewDigest: digest)
            proposal.preview = preview
            proposal.previewDocument = ParkingLotDocument(revision: after.document.revision, rows: rows)
            let response = DeviceEnvelope(kind: "lot.proposal", boot: boot, sessionID: before.globalID, epoch: proposal.epoch, payload: try LotEditing.encoded(preview))
            guard try LotEditing.encoded(response).count <= LotEditing.maximumFrameBytes else { throw ParkingLotError.message("The review is too large for this device. Review it on home instead.") }
            sendEnvelope(peer, response)
        } catch { finishLotProposal(lot.id, result: .failure(error)); throw error }
    }
    private func resolveLotProposal(_ peer: DevicePeer, _ envelope: DeviceEnvelope, lot: ParkingLotStore) throws {
        guard let data = envelope.payload, let decision = try? JSONDecoder().decode(LotProposalDecision.self, from: data),
              let proposal = lotProposalRequests[lot.id], decision.id == proposal.id, proposal.epoch == envelope.epoch,
              proposal.allowed() else { throw ParkingLotError.message("This review is no longer available.") }
        if !decision.approved { finishLotProposal(lot.id, result: .success("Parking Lot: changes declined on the holding device. Nothing changed.")); return }
        do {
            guard let preview = proposal.preview, preview.previewDigest == decision.previewDigest,
                  let reviewed = proposal.previewDocument,
                  let before = preview.before, before.digest == (try lotSnapshot(lot, epoch: proposal.epoch)).digest else {
                throw ParkingLotError.message("Parking Lot changed after preview. No changes applied.")
            }
            // Commit exactly what the holder approved. Re-running preview would
            // generate different IDs for additions and comments.
            try withLotPermit(lot.id) { try lot.commitRemote(reviewed) }
            lot.undoManager.removeAllActions(); lotStreams[lot.id]?.history = []
            // Commit succeeded: never report not-applied merely because delivery failed.
            sendLotSnapshot(peer, lot: lot, force: true)
            finishLotProposal(lot.id, result: .success("Parking Lot: saved revision \(lot.document.revision), approved on the holding device."))
        } catch { finishLotProposal(lot.id, result: .failure(error)); throw error }
    }
    private func finishLotProposal(_ id: UUID, result: Result<String, Error>) {
        guard let proposal = lotProposalRequests.removeValue(forKey: id) else { return }
        lotStreams[id]?.barrier = false
        if let holder = leases?.holder(session: id), holder.epoch == proposal.epoch,
           let peer = peers.values.first(where: { $0.trustedReady && $0.hello?.deviceID == holder.device }) {
            sendEnvelope(peer, DeviceEnvelope(kind: "lot.proposal.closed", boot: boot, sessionID: DeviceGlobalID(home: identity!.deviceID, session: id).string, epoch: holder.epoch))
        }
        proposal.finish(result)
    }
    func requireLocalLotManagement(_ id: UUID) throws {
        guard editableLotsEnabled else { return }
        if remoteDisplayHolder(id) != nil || lotTransfers[id] != nil { throw ParkingLotError.message("Take this Parking Lot here before changing its home settings or deleting it.") }
    }
    func fenceDeletedLot(_ id: UUID) throws {
        guard editableLotsEnabled, let home = identity?.deviceID, let leases else { return }
        guard leases.acquire(session: id, device: home).granted else { throw ParkingLotError.message("Could not preserve the lot’s authority fence.") }
        lotStreams.removeValue(forKey: id)
    }
}
#endif
