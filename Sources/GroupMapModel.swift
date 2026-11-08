import Foundation

// Pure model behind View → Group. The feed captures an immutable GroupMapInput
// on the main thread; everything here runs on a worker and never sees message
// text, because GroupMapInput carries no field that could hold it.

enum GroupMapDeliveryState: String, Codable, CaseIterable {
    case queued, sent, delivered, awaitingAnswer, answered, failed, unknown
    var pending: Bool { self == .queued || self == .sent || self == .awaitingAnswer }
}
enum GroupMapDeliveryKind: String, Codable { case tell, ask, reply }
/// How a permission edge stands. No edge at all means the rules forbid it.
enum GroupMapReach: String, Codable { case can, offline, unknown }

/// A remote tell as the transport saw it. Plain remote tells have no durable
/// record on the sending home, so this is the only evidence for them.
enum GroupMapTellPhase: String, Codable { case sent, accepted, rejected, unconfirmed }
struct SwitchboardTellEvent {
    var id: UUID
    var phase: GroupMapTellPhase
    var source: String? = nil
    var target: String? = nil
    var kind: GroupMapDeliveryKind? = nil
}
struct GroupMapTellRecord {
    var id: UUID
    var phase: GroupMapTellPhase
    var source: String
    var target: String
    var kind: GroupMapDeliveryKind
    var at: Date
}

struct GroupMapInput {
    struct LocalSession {
        var id: UUID
        var title: String
        var assistant: String
        var busy: Bool
        var queued: Int
        var queuePaused: Bool
        var switchboardEnabled: Bool
        var taught: Bool
        var agent: AgentConfig?
        var obligations: [SwitchboardObligation]
        var expectations: [SwitchboardExpectation]
        var queuedPromptIDs: Set<UUID>
    }
    struct RemoteRow {
        var globalID: String
        var title: String
        var assistant: String
        var isAgent: Bool
        var busy: Bool
        var queued: Int
        var queuePaused: Bool
        var messagingEnabled: Bool
    }
    struct RemoteHome {
        var deviceID: String
        var name: String
        var online: Bool
        // participantOnline: connected with the capability tells require.
        var reachable: Bool
        var rows: [RemoteRow]
    }
    var localDeviceID: String?
    var localDeviceName: String
    var groupName: String?
    var sessions: [LocalSession]
    var homes: [RemoteHome]
    var pendingTellIDs: Set<UUID>
    // Delivery IDs a fresh authenticated queue-watch report lists as queued on
    // the recipient's home. The only remote recipient evidence the protocol has.
    var remoteQueuedIDs: Set<UUID>
    var tells: [GroupMapTellRecord]
    var now: Date
}

struct GroupMapDevice: Encodable, Equatable, Identifiable {
    var id: String
    var name: String
    var online: Bool
    var local: Bool
    var x: Double
    var y: Double
    var r: Double
}
struct GroupMapNode: Encodable, Equatable, Identifiable {
    var id: String
    var device: String
    var label: String
    var assistant: String
    var kind: String
    var busy: Bool
    var queued: Int
    var paused: Bool
    var messaging: Bool
    var taught: Bool?
    var online: Bool
    var x: Double
    var y: Double
    var pendingIn = 0
    var pendingOut = 0
    var oldestPendingAt: Int64?
}
struct GroupMapEdge: Encodable, Equatable, Identifiable {
    var id: String
    var a: String
    var b: String
    var ab: GroupMapReach?
    var ba: GroupMapReach?
    var abWhy: String?
    var baWhy: String?
    var counts: [String: Int] = [:]
    var pending = 0
    var total = 0
    var oldestPendingAt: Int64?
}
struct GroupMapDelivery: Encodable, Equatable, Identifiable {
    var id: String
    var edge: String?
    var from: String
    var to: String
    var fromName: String
    var toName: String
    var kind: GroupMapDeliveryKind
    var state: GroupMapDeliveryState
    var createdAt: Int64?
    var detail: String
    // Set when the recipient lives on another home that reports nothing further.
    var recipient: String?
}
struct GroupMapPulse: Encodable, Equatable {
    var delivery: String
    var edge: String
    var from: String
    var to: String
    var state: GroupMapDeliveryState
}
struct GroupMapGraph: Equatable {
    var groupName: String?
    var devices: [GroupMapDevice] = []
    var nodes: [GroupMapNode] = []
    var edges: [GroupMapEdge] = []
    var deliveries: [GroupMapDelivery] = []
}
struct GroupMapPayload: Encodable {
    var v = 1
    var full: Bool
    var now: Int64
    var groupName: String?
    var devices: [GroupMapDevice] = []
    var nodes: [GroupMapNode] = []
    var edges: [GroupMapEdge] = []
    var deliveries: [GroupMapDelivery] = []
    var removedDevices: [String] = []
    var removedNodes: [String] = []
    var removedEdges: [String] = []
    var removedDeliveries: [String] = []
    var pulses: [GroupMapPulse] = []
}

/// Positions depend only on the order devices and sessions were first seen, so
/// message traffic cannot move anything. Slots are never reused while the
/// window lives: a session that comes back returns to its old place.
struct GroupMapLayout {
    static let nodeSpacing = 62.0
    private(set) var deviceSlots: [String: Int] = [:]
    private(set) var nodeSlots: [String: [String: Int]] = [:]
    private(set) var columns = 0
    private(set) var cell = 0.0

    static func clusterRadius(slots: Int) -> Double { nodeSpacing * Double(max(slots, 1)).squareRoot() + 60 }

    private func center(_ slot: Int) -> (Double, Double) {
        let column = slot % columns, row = slot / columns
        return (Double(column) * cell, Double(row) * cell)
    }
    /// Sizing is fixed by the first snapshot, so a later arrival shifts nothing.
    mutating func prepare(devices: [(id: String, count: Int)]) {
        guard columns == 0 else { return }
        columns = max(1, Int(Double(max(devices.count, 1)).squareRoot().rounded(.up)))
        cell = max(560, 2 * (devices.map { Self.clusterRadius(slots: $0.count) }.max() ?? 0) + 120)
    }
    mutating func place(device: String) -> (x: Double, y: Double) {
        let slot = deviceSlots[device] ?? deviceSlots.count
        deviceSlots[device] = slot
        return center(slot)
    }
    mutating func place(node: String, device: String) -> (x: Double, y: Double) {
        var slots = nodeSlots[device] ?? [:]
        let slot = slots[node] ?? slots.count
        slots[node] = slot; nodeSlots[device] = slots
        let c = center(deviceSlots[device] ?? 0)
        let angle = Double(slot) * 2.399963, radius = Self.nodeSpacing * Double(slot).squareRoot()
        return (c.0 + radius * cos(angle), c.1 + radius * sin(angle))
    }
    func usedSlots(device: String) -> Int { nodeSlots[device]?.count ?? 0 }
}

enum GroupMapModel {
    static let maximumDeliveries = 400
    static let maximumPulses = 64
    static let localDevicePlaceholder = "local"
    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func label(_ text: String) -> String { String(text.prefix(80)) }
    static func edgeID(_ a: String, _ b: String) -> String { a < b ? a + "|" + b : b + "|" + a }

    // MARK: Message state, from recorded evidence only

    /// The receiving home owns an obligation, so this is direct evidence.
    static func state(of item: SwitchboardObligation, queuedLocally: Bool) -> (state: GroupMapDeliveryState, detail: String) {
        switch item.state {
        case "queued": return (.queued, item.intervenedAt != nil ? "Recovery queued" : queuedLocally ? "In the recipient's queue" : "Leaving the recipient's queue")
        case "submitted":
            if item.kind == "request" { return (.awaitingAnswer, item.finishedAt == nil ? "Recipient is working" : "Recipient finished without answering") }
            return (.delivered, item.finishedAt == nil ? "Recipient is processing it" : "Recipient processed it")
        case "completed": return (.delivered, "Recipient processed it")
        case "interrupted": return (.delivered, "Reply reached the transcript; that turn was interrupted")
        case "resolved":
            guard item.kind == "request" else { return (.delivered, "Delivered") }
            return item.replyDeliveryID == nil ? (.unknown, "Marked resolved with no matching reply on record") : (.answered, "Reply matched by inReplyTo")
        case "awaitingReceipt": return (.awaitingAnswer, "Reply sent; its transport receipt has not arrived")
        case "failed": return (.failed, "Recipient's turn failed")
        case "deliveryFailed": return (.failed, "The asker's home rejected the reply")
        case "escalated": return (.failed, "Needs attention: unresolved after the one automatic recovery")
        case "cancelled": return (.failed, "Cancelled before it was processed")
        default: return (.unknown, "Unrecognized supervision state")
        }
    }
    /// The asker's own record. A transport receipt never makes this answered:
    /// only a reply matched by inReplyTo records replyDeliveryID.
    static func state(of item: SwitchboardExpectation, pendingTell: Bool, remoteQueued: Bool) -> (state: GroupMapDeliveryState, detail: String) {
        if item.replyDeliveryID != nil { return (.answered, "Reply matched by inReplyTo") }
        if item.homeAccepted == false { return (.failed, "The recipient's home rejected it") }
        if item.answered { return (.unknown, "Closed before Converse recorded whether it was answered or rejected") }
        if pendingTell { return (.sent, "Sent; waiting for the recipient's home to accept it") }
        if remoteQueued { return (.queued, "The recipient's home reports it queued") }
        if item.homeAccepted == true { return (.awaitingAnswer, "The recipient's home accepted it. A transport receipt is not an answer.") }
        return (.unknown, "No acceptance from the recipient's home is on record")
    }
    static func state(of tell: GroupMapTellRecord) -> (state: GroupMapDeliveryState, detail: String) {
        switch tell.phase {
        case .sent: return (.sent, "Sent; waiting for the recipient's home to accept it")
        case .accepted: return (.delivered, "The recipient's home accepted it. Queued does not mean read.")
        case .rejected: return (.failed, "The recipient's home rejected it")
        case .unconfirmed: return (.unknown, "The recipient's home did not confirm it in time")
        }
    }

    // MARK: Permissions, mirroring deliverSwitchboard and handleParticipantTell

    struct Participant {
        var id: String
        var device: String
        var local: LocalRef?
        var remote: RemoteRef?
        struct LocalRef { var session: GroupMapInput.LocalSession }
        struct RemoteRef { var row: GroupMapInput.RemoteRow; var reachable: Bool }
    }
    static func reach(from sender: Participant, to target: Participant, localDevice: String?) -> (reach: GroupMapReach, why: String)? {
        guard sender.id != target.id else { return nil }
        if let source = sender.local?.session {
            guard source.switchboardEnabled else { return nil }
            if let local = target.local?.session {
                if let agent = source.agent, !agent.allows(local: local.id, home: localDevice) { return nil }
                return (.can, source.agent == nil ? "Messaging is on" : "In this agent's selected sessions")
            }
            guard let remote = target.remote, remote.row.messagingEnabled else { return nil }
            if let agent = source.agent, !agent.allows(global: remote.row.globalID, home: localDevice) { return nil }
            return remote.reachable ? (.can, "Same Group, messaging is on") : (.offline, "Permitted when that device is online")
        }
        guard let source = sender.remote, source.row.messagingEnabled else { return nil }
        if let local = target.local?.session {
            guard local.switchboardEnabled else { return nil }
            if !source.reachable { return (.offline, "Permitted when that device is online") }
            return source.row.isAgent ? (.unknown, "An agent's scope is enforced on its own device, which does not report it") : (.can, "Same Group, messaging is on")
        }
        guard let target = target.remote, target.row.messagingEnabled else { return nil }
        return (.unknown, "Both sessions are on other devices; this device cannot see their link or scope")
    }

    // MARK: Graph

    static func build(_ input: GroupMapInput, layout: inout GroupMapLayout) -> GroupMapGraph {
        let localDevice = input.localDeviceID ?? localDevicePlaceholder
        func address(_ id: UUID) -> String { input.localDeviceID.map { DeviceGlobalID(home: $0, session: id).string } ?? id.uuidString }
        var graph = GroupMapGraph(groupName: input.groupName)
        var participants: [Participant] = []
        let order = [(id: localDevice, count: input.sessions.count)] + input.homes.map { (id: $0.deviceID, count: $0.rows.count) }
        layout.prepare(devices: order)

        _ = layout.place(device: localDevice)
        for session in input.sessions.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let id = address(session.id), point = layout.place(node: id, device: localDevice)
            graph.nodes.append(GroupMapNode(id: id, device: localDevice, label: label(session.title), assistant: label(session.assistant),
                kind: session.agent == nil ? "session" : "agent", busy: session.busy, queued: session.queued, paused: session.queuePaused,
                messaging: session.switchboardEnabled, taught: session.taught, online: true, x: point.x, y: point.y))
            participants.append(Participant(id: id, device: localDevice, local: .init(session: session)))
        }
        for home in input.homes {
            _ = layout.place(device: home.deviceID)
            for row in home.rows.sorted(by: { $0.globalID < $1.globalID }) {
                let point = layout.place(node: row.globalID, device: home.deviceID)
                graph.nodes.append(GroupMapNode(id: row.globalID, device: home.deviceID, label: label(row.title), assistant: label(row.assistant),
                    kind: row.isAgent ? "agent" : "session", busy: row.busy, queued: row.queued, paused: row.queuePaused,
                    messaging: row.messagingEnabled, taught: nil, online: home.online, x: point.x, y: point.y))
                participants.append(Participant(id: row.globalID, device: home.deviceID, remote: .init(row: row, reachable: home.reachable)))
            }
        }
        func device(_ id: String, name: String, online: Bool, local: Bool) -> GroupMapDevice {
            let point = layout.place(device: id)
            return GroupMapDevice(id: id, name: label(name), online: online, local: local, x: point.x, y: point.y, r: GroupMapLayout.clusterRadius(slots: layout.usedSlots(device: id)))
        }
        graph.devices.append(device(localDevice, name: input.localDeviceName, online: true, local: true))
        graph.devices += input.homes.map { device($0.deviceID, name: $0.name, online: $0.online, local: false) }

        var edges: [String: GroupMapEdge] = [:]
        func edge(_ a: String, _ b: String) -> GroupMapEdge {
            let (first, second) = a < b ? (a, b) : (b, a)
            return edges[edgeID(a, b)] ?? GroupMapEdge(id: edgeID(a, b), a: first, b: second)
        }
        for sender in participants {
            for target in participants {
                guard let result = reach(from: sender, to: target, localDevice: input.localDeviceID) else { continue }
                var value = edge(sender.id, target.id)
                if sender.id == value.a { value.ab = result.reach; value.abWhy = result.why } else { value.ba = result.reach; value.baWhy = result.why }
                edges[value.id] = value
            }
        }

        let names = Dictionary(graph.nodes.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        var deliveries: [GroupMapDelivery] = []
        func append(id: UUID, from: String, to: String, fromName: String? = nil, kind: GroupMapDeliveryKind, result: (state: GroupMapDeliveryState, detail: String), createdAt: Date?, recipient: String? = nil) {
            guard seen.insert(id).inserted else { return }
            deliveries.append(GroupMapDelivery(id: id.uuidString, edge: nil, from: from, to: to, fromName: names[from] ?? fromName.map(label) ?? "Unavailable", toName: names[to] ?? "Unavailable",
                kind: kind, state: result.state, createdAt: createdAt.map(milliseconds), detail: result.detail, recipient: recipient))
        }
        // The receiving home's record wins over the asker's copy of the same ID.
        for session in input.sessions {
            let to = address(session.id)
            for item in session.obligations {
                let kind: GroupMapDeliveryKind = item.kind == "request" ? .ask : item.kind == "reply" ? .reply : .tell
                append(id: item.id, from: item.source, to: to, fromName: item.sourceName, kind: kind, result: state(of: item, queuedLocally: session.queuedPromptIDs.contains(item.promptID)), createdAt: item.createdAt)
            }
        }
        for session in input.sessions {
            let from = address(session.id)
            for item in session.expectations {
                let remote = DeviceGlobalID(item.target).map { $0.home != localDevice } ?? false
                append(id: item.id, from: from, to: item.target, kind: .ask,
                       result: state(of: item, pendingTell: input.pendingTellIDs.contains(item.id), remoteQueued: input.remoteQueuedIDs.contains(item.id)),
                       createdAt: item.createdAt, recipient: remote ? "unknown" : nil)
            }
        }
        for tell in input.tells { append(id: tell.id, from: tell.source, to: tell.target, kind: tell.kind, result: state(of: tell), createdAt: tell.at, recipient: "unknown") }

        // Pending first, then newest: a flood of old records cannot hide live work.
        deliveries.sort {
            if $0.state.pending != $1.state.pending { return $0.state.pending }
            if $0.createdAt != $1.createdAt { return ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
            return $0.id < $1.id
        }
        let nodeIndex = Dictionary(graph.nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in deliveries.prefix(maximumDeliveries).indices {
            let item = deliveries[index]
            if item.state.pending {
                if let i = nodeIndex[item.from] { graph.nodes[i].pendingOut += 1; graph.nodes[i].oldestPendingAt = minimum(graph.nodes[i].oldestPendingAt, item.createdAt) }
                if let i = nodeIndex[item.to] { graph.nodes[i].pendingIn += 1; graph.nodes[i].oldestPendingAt = minimum(graph.nodes[i].oldestPendingAt, item.createdAt) }
            }
            guard names[item.from] != nil, names[item.to] != nil else { continue }
            // Real traffic stays visible even if the permission has since been removed.
            var value = edge(item.from, item.to)
            value.counts[item.state.rawValue, default: 0] += 1
            value.total += 1
            if item.state.pending { value.pending += 1; value.oldestPendingAt = minimum(value.oldestPendingAt, item.createdAt) }
            edges[value.id] = value
            deliveries[index].edge = value.id
        }
        graph.edges = edges.values.sorted { $0.id < $1.id }
        graph.deliveries = Array(deliveries.prefix(maximumDeliveries)).sorted { $0.id < $1.id }
        graph.devices.sort { $0.id < $1.id }
        graph.nodes.sort { $0.id < $1.id }
        return graph
    }
    private static func minimum(_ a: Int64?, _ b: Int64?) -> Int64? {
        guard let a else { return b }
        guard let b else { return a }
        return Swift.min(a, b)
    }

    // MARK: Diff

    private static func changes<T: Identifiable & Equatable>(_ old: [T], _ new: [T]) -> (changed: [T], removed: [T.ID]) where T.ID == String {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = Set(new.map(\.id))
        return (new.filter { previous[$0.id] != $0 }, old.map(\.id).filter { !current.contains($0) })
    }
    /// A pulse is one real change of one message, in the direction it travelled.
    static func pulses(from old: [GroupMapDelivery], to new: [GroupMapDelivery]) -> [GroupMapPulse] {
        let previous = Dictionary(old.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        return Array(new.compactMap { item -> GroupMapPulse? in
            guard let edge = item.edge, previous[item.id] != item.state else { return nil }
            let backwards = item.state == .answered && item.kind == .ask
            return GroupMapPulse(delivery: item.id, edge: edge, from: backwards ? item.to : item.from, to: backwards ? item.from : item.to, state: item.state)
        }.prefix(maximumPulses))
    }
    /// Nil means nothing visible changed, so the page is left alone.
    static func payload(previous: GroupMapGraph?, next: GroupMapGraph, now: Date) -> GroupMapPayload? {
        guard let previous else {
            return GroupMapPayload(full: true, now: milliseconds(now), groupName: next.groupName, devices: next.devices, nodes: next.nodes, edges: next.edges, deliveries: next.deliveries)
        }
        guard previous != next else { return nil }
        let devices = changes(previous.devices, next.devices), nodes = changes(previous.nodes, next.nodes)
        let edges = changes(previous.edges, next.edges), deliveries = changes(previous.deliveries, next.deliveries)
        return GroupMapPayload(full: false, now: milliseconds(now), groupName: next.groupName, devices: devices.changed, nodes: nodes.changed, edges: edges.changed, deliveries: deliveries.changed,
            removedDevices: devices.removed, removedNodes: nodes.removed, removedEdges: edges.removed, removedDeliveries: deliveries.removed,
            pulses: pulses(from: previous.deliveries, to: next.deliveries))
    }
    static func encode(_ payload: GroupMapPayload) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(payload)
    }
}

/// Holds layout and the last graph between builds. Confined to the feed's worker.
final class GroupMapBuilder {
    private var layout = GroupMapLayout()
    private var previous: GroupMapGraph?
    func forgetPrevious() { previous = nil }
    func build(_ input: GroupMapInput) -> GroupMapPayload? {
        let graph = GroupMapModel.build(input, layout: &layout)
        let result = GroupMapModel.payload(previous: previous, next: graph, now: input.now)
        previous = graph
        return result
    }
}
