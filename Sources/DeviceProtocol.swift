import CryptoKit
import Foundation

enum SwitchboardPolicy {
    static let maxHops = 100
}

// Versioned wire protocol for device sync. Independent of UI and Store types
// so later Windows and iPad clients can implement the same schema.
enum DeviceMessageKind: String, Codable {
    case hello, sidebarSnapshot = "sidebar.snapshot", sidebarDelta = "sidebar.delta"
    case leaseAcquire = "lease.acquire", leaseGranted = "lease.granted", leaseDenied = "lease.denied"
    case leaseResume = "lease.resume", leaseExpired = "lease.expired"
    case leaseStolen = "lease.stolen", leaseHeartbeat = "lease.heartbeat", leaseRelease = "lease.release"
    case transcriptSnapshot = "transcript.snapshot", transcriptTail = "transcript.tail"
    case draftPatch = "draft.patch", draftAck = "draft.ack", command, commandAck = "command.ack", commandQuery = "command.query"
    case blobOffer = "blob.offer", blobChunk = "blob.chunk", blobComplete = "blob.complete", blobAck = "blob.ack"
    case blobRequest = "blob.request", blobData = "blob.data", transcriptRequest = "transcript.request"
    case ping, pong, goodbye
}

struct DeviceEnvelope: Codable, Equatable {
    var version = 1
    var kind: String
    var homeSeq: UInt64? = nil
    var boot: UInt64? = nil
    var sessionID: String? = nil
    var commandID: UUID? = nil
    var epoch: UInt64? = nil
    var payload: Data? = nil
}

enum DeviceFrameError: LocalizedError {
    case oversize, invalid
    var errorDescription: String? { self == .oversize ? "Device frame exceeds size limit." : "Invalid device frame." }
}

enum DeviceFrame {
    static let maxPayload = 4_194_304
    static func encode(_ envelope: DeviceEnvelope) throws -> Data {
        let body = try JSONEncoder().encode(envelope)
        guard body.count <= maxPayload else { throw DeviceFrameError.oversize }
        let count = UInt32(body.count)
        let frame = Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        return frame + body
    }
}

struct DeviceFrameDecoder {
    private var buffer = Data()
    mutating func append(_ chunk: Data) throws -> [DeviceEnvelope] {
        buffer.append(chunk)
        var envelopes: [DeviceEnvelope] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= DeviceFrame.maxPayload else { throw DeviceFrameError.oversize }
            guard buffer.count >= 4 + length else { break }
            let body = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(4 + length)
            envelopes.append(try JSONDecoder().decode(DeviceEnvelope.self, from: body))
        }
        return envelopes
    }
}

struct DeviceGlobalID: Equatable, Hashable {
    let home: String
    let session: UUID
    var string: String { home + "/" + session.uuidString.lowercased() }
    init(home: String, session: UUID) { self.home = home; self.session = session }
    init?(_ string: String) {
        let parts = string.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let uuid = UUID(uuidString: String(parts[1])) else { return nil }
        home = String(parts[0]); session = uuid
    }
}

// Verification code rationale: a short truncation is grindable offline by
// an active MITM who controls the final handshake payload (confirmed by
// review reproduction against the former six-digit code). The code is
// therefore the first 128 bits of the Noise handshake hash (the channel
// binding value, Noise 11.2) as 32 hex characters in eight groups. Users
// must compare ALL groups on both devices. Grinding a 128-bit match is
// computationally infeasible within any pairing window, and no online
// attempt limit is load-bearing for this property.
enum DeviceSAS {
    static func code(_ handshakeHash: Data) -> String {
        let hex = handshakeHash.prefix(16).map { String(format: "%02x", $0) }.joined()
        var groups: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            groups.append(String(hex[index..<next])); index = next
        }
        return groups.joined(separator: " ")
    }
}

struct DeviceHello: Codable, Equatable {
    var deviceID: String
    var deviceName: String
    var converseVersion: String
    /// Build number beside converseVersion. Older releases omit it (and some
    /// sent a fixed placeholder version), so only a hello with a build counts
    /// as installed-version evidence.
    var converseBuild: String? = nil
    var protocolVersion = 1
    var capabilities: [String] = ["sidebar", "lease", "lease-resume-v1", "transcript", "commands", "blobs", "fabric-membership-v1", "switchboard-teach-v1", "converse-groups-v1"]
    var listenPort: Int? = nil
    var group: ConverseGroup? = nil
    var joinGroupID: String? = nil
}

struct DeviceSidebarRow: Codable, Equatable, Identifiable {
    var id: String { globalID }
    var globalID: String
    var sessionID: UUID
    var title: String
    var assistant: String
    var engine: String
    var model: String
    var effort: String
    var access: String
    var status: String
    var busy: Bool
    var queued: Int
    var queuePaused: Bool
    var leaseHolder: String? = nil
    var leaseEpoch: UInt64? = nil
    var accountName: String? = nil
    var messagingEnabled: Bool? = nil
    var participantKind: String? = nil
    var attention: String? = nil
    var linkedSessionIDs: [String]? = nil
    // Sidebar markers for viewers. Optional so older peers ignore them and
    // older payloads still decode. lastResponseAt is the home's clock (the
    // default Date encoding, as observedAt); viewers only compare it with
    // earlier values from the same home.
    var loopPaused: Bool? = nil
    var pausedReason: String? = nil
    var lastResponseAt: Date? = nil
    // The home itself shows the session in one of its panes, so taking it here steals it.
    var shownOnHome: Bool? = nil
    var isAgentRow: Bool { participantKind == "agent" || engine == "agent" }
    // Same red marker as a local paused agent loop.
    var showsLoopPaused: Bool { isAgentRow && loopPaused == true }
    var pausedHelp: String { pausedReason.flatMap { $0.isEmpty ? nil : $0 } ?? "Loop paused. Re-enable it in Agent Setup / Loop." }
}

struct RemoteRowMarkers: Equatable {
    var paused = false
    var pausedReason: String? = nil
    var unseen = false
}

// Per-viewing-device unseen-response watermarks for remote sessions, keyed by
// global ID. A row is unseen when its home reports a newer response than the
// last one this device displayed. The first observation of a session counts
// as seen, so installs and relaunches never mark everything unseen. Agents
// and Parking Lots never carry the eye (matching local Mac rows).
struct RemoteSeenWatermarks: Codable, Equatable {
    var seen: [String: Date] = [:]
    static func eligible(_ row: DeviceSidebarRow) -> Bool { !row.isAgentRow && row.engine != "parking" }
    func isUnseen(_ row: DeviceSidebarRow) -> Bool {
        guard Self.eligible(row), let latest = row.lastResponseAt, let mark = seen[row.globalID] else { return false }
        return latest > mark
    }
    // Adopts one home's snapshot. Displayed sessions advance to the latest
    // response; sessions the home no longer lists are forgotten. Returns
    // whether anything changed so callers persist only real changes.
    @discardableResult
    mutating func observe(home: String, rows: [DeviceSidebarRow], displayed: (String) -> Bool) -> Bool {
        let before = seen
        let present = Set(rows.map(\.globalID))
        for id in seen.keys where DeviceGlobalID(id)?.home == home && !present.contains(id) { seen.removeValue(forKey: id) }
        for row in rows where Self.eligible(row) {
            if seen[row.globalID] == nil || displayed(row.globalID) { markSeen(row) }
        }
        return seen != before
    }
    // Taking or displaying a session here shows its transcript.
    @discardableResult
    mutating func markSeen(_ row: DeviceSidebarRow) -> Bool {
        let before = seen[row.globalID]
        let mark = max(before ?? .distantPast, row.lastResponseAt ?? .distantPast)
        seen[row.globalID] = mark
        return before != mark
    }
}

// Discovery metadata only; links never confer permission to read or edit.
struct ParkingLotRoute: Codable, Equatable {
    var id: UUID
    var globalID: String
    var name: String
    var homeDeviceID: String
    var homeDeviceName: String
    var online: Bool
    var linkedToMe: Bool
    var access: String
}

struct DeviceSidebarPayload: Codable, Equatable {
    var homeDeviceID: String
    var homeDeviceName: String
    var homeSeq: UInt64
    var rows: [DeviceSidebarRow]
}

// Wire DTO independent of the app persistence Message struct. Home file
// paths never cross the wire; attachments travel as content hashes.
struct DeviceWireMessage: Codable, Identifiable, Equatable {
    var id: UUID
    var role: String
    var text: String
    var imageHashes: [String] = []
    // Optional home-assigned visible-message ordinal, independent of raw
    // paging offsets (which also count hidden activity and empty messages).
    var messageNumber: Int? = nil
    // UTC Unix seconds, not Swift's default Date encoding (2001 epoch).
    // Optional for older peers and history with no original timestamp.
    var createdAtUnixSeconds: Double? = nil
    // Inject all parts (UTF-16 ranges of `text`). Optional: older peers
    // omit and ignore it; viewers then use the conservative text split.
    var components: [MessageComponent]? = nil
    var createdAt: Date? {
        guard let seconds = createdAtUnixSeconds, seconds.isFinite,
              seconds >= -62135596800, seconds < 253402300800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
extension DeviceWireMessage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); role = try c.decode(String.self, forKey: .role); text = try c.decode(String.self, forKey: .text)
        imageHashes = try c.decode([String].self, forKey: .imageHashes)
        messageNumber = try c.decodeIfPresent(Int.self, forKey: .messageNumber)
        createdAtUnixSeconds = try c.decodeIfPresent(Double.self, forKey: .createdAtUnixSeconds)
        components = c.decodeComponents(forKey: .components)
    }
}
struct DevicePendingDTO: Codable, Equatable, Identifiable {
    var id: UUID
    var text: String
    // Inject all parts of a merged queue item, as on DeviceWireMessage.
    // Optional: older peers omit and ignore it.
    var components: [MessageComponent]? = nil
}
extension DevicePendingDTO {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); text = try c.decode(String.self, forKey: .text)
        components = c.decodeComponents(forKey: .components)
    }
}
struct DeviceChoiceDTO: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var detail: String? = nil
    var provider: String? = nil
    var profile: String? = nil
}
struct DeviceRequestDTO: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var toolName: String? = nil
    var rawArgs: String? = nil
    var choices: [DeviceChoiceDTO] = []
    var questionsJSON: Data? = nil
}
struct DeviceWidgetMetric: Codable { var label: String; var value: String }
// Derived from the agent's latest assessment (AgentConfig.widgetContent).
// Older homes still send a scoreboard-shaped widget without status or
// freshness; viewers show whatever fields arrive.
struct DeviceAgentWidget: Codable {
    var summary: String
    var metrics: [DeviceWidgetMetric]
    var observedAt: Date?
    var attention: String
    var artHash: String?
    var loopStatus: String? = nil
    var status: String? = nil
    var freshness: String? = nil
    var revision: Int? = nil
    /// "On track · Fresh · rev 3", or nothing from an older home.
    var assessmentLine: String? {
        let parts = [status, freshness, revision.map { "rev \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
struct DeviceTranscriptPayload: Codable {
    var globalID: String
    var homeSeq: UInt64
    var epoch: UInt64? = nil
    var boot: UInt64? = nil
    var messages: [DeviceWireMessage]
    var offset: Int = 0
    var total: Int = 0
    var prepend: Bool = false
    var draft: String
    var draftVersion: UInt64
    var draftImageHashes: [String]? = nil
    var pending: [DevicePendingDTO] = []
    var busy: Bool
    var status: String
    var title: String = ""
    var engine: String = ""
    var accountName: String? = nil
    var model: String = ""
    var effort: String = ""
    var access: String = ""
    var modelOptions: [DeviceChoiceDTO] = []
    var effortOptions: [String] = []
    var accessOptions: [DeviceChoiceDTO] = []
    var requests: [DeviceRequestDTO] = []
    var queuePaused: Bool = false
    var agentWidget: DeviceAgentWidget? = nil
    var compaction: DeviceCompactionState? = nil
}
// Optional capability/state: older homes omit it and viewers show no action.
struct DeviceCompactionState: Codable, Equatable {
    var recommended: Bool
    var phase: String // available, queued, running
    var percent: Int?
    var detail: String
    var title: String { phase == "running" ? "Compacting…" : phase == "queued" ? "Cancel compact" : "Compact" }
    var visible: Bool { recommended || phase != "available" }
}
struct DeviceTranscriptRequest: Codable, Equatable {
    var beforeOffset: Int
}

struct DeviceCommandPayload: Codable, Equatable {
    var action: String
    var text: String? = nil
    var blobHashes: [String] = []
    var model: String? = nil
    var effort: String? = nil
    var access: String? = nil
    var pendingID: UUID? = nil
    var requestID: String? = nil
    var choiceID: String? = nil
    var answersJSON: Data? = nil
    var modelProvider: String? = nil
    var modelProfile: String? = nil
}

struct DeviceAckPayload: Codable, Equatable {
    var outcome: String
    var detail: String? = nil
    var epoch: UInt64? = nil
    /// True on a home's answer to a status query. Older homes omit it.
    var query: Bool? = nil
}

struct DeviceDraftPayload: Codable, Equatable {
    var version: UInt64
    var text: String
    var imageHashes: [String]? = nil
}

struct DeviceBlobPayload: Codable, Equatable {
    var sha256Hex: String
    var size: Int? = nil
    var chunk: Data? = nil
    var done: Bool = false
}

struct GroupJoinRequest: Codable, Equatable, Identifiable {
    var id: UUID
    var groupID: String
    var requesterID: String
    var requesterName: String
    var sponsorID: String
    var expiresAt: Date
    var approved = false
}
struct GroupJoinReview: Codable, Identifiable {
    var id: UUID { request.id }
    var request: GroupJoinRequest
    var code: String
}

struct GroupDeviceLabel: Identifiable {
    var id: String
    var name: String
}

// Home-addressed control. These messages never acquire a display lease.
struct DeviceTellPayload: Codable, Equatable {
    var groupID: String
    var source: String
    var sourceTitle: String
    var target: String
    var text: String
    var hop: Int
    var urgent: Bool = false
    var replyExpected: Bool? = nil
    var inReplyTo: UUID? = nil
}
struct GroupTellReceipt: Codable {
    var id: UUID
    var origin: String
    var payloadHash: String
}

struct DeviceAgentSettings: Codable, Equatable {
    var modelOptions: [DeviceChoiceDTO]? = nil
    var objective: String
    var repository: String
    var model: String
    var watched: [String]
    var intervalSeconds: Double
    var remainingRuns: Int
    // Legacy counter remains decodable for saved archives and older peers.
    // It no longer limits the number of scheduled activations.
    var maxTurnsPerLoop: Int? = nil
    var turnLimit: Int {
        get { maxTurnsPerLoop ?? max(1, remainingRuns) }
        set { maxTurnsPerLoop = newValue }
    }
    var enabled: Bool
    var generateArt: Bool
    var speak: Bool
    var discord: Bool
    var fileTriggers: Bool = false
    var revision: UInt64? = nil
    // Retired scoreboard cadence: older editors still send it and current
    // homes ignore it, because every agent turn assesses.
    var scoreboardEveryLoops: Int? = nil
    var scheduleText: String? = nil
    var scheduleTimeZone: String? = nil
    var discordShareScoreboard: Bool? = nil
    var discordShareSessionInformation: Bool? = nil
    var artDirection: String? = nil
    var homeAssistantURL: String? = nil
    var homeAssistantEntities: String? = nil
    var homeAssistantRead: Bool? = nil
}
struct DeviceParticipantRequest: Codable, Equatable {
    var provider: String? = nil
    var groupID: String
    var action: String
    var target: String? = nil
    var title: String? = nil
    var settings: DeviceAgentSettings? = nil
    var imageAssist: DeviceImageAssistRequest? = nil
    var exportRequest: DeviceExportRequest? = nil
}
struct DeviceParticipantEvidence: Codable {
    var globalID: String
    var title: String
    var busy: Bool
    var status: String
    var messages: [DeviceWireMessage]
}
struct DeviceParticipantResponse: Codable {
    var groupID: String
    var outcome: String
    var detail: String
    var target: String? = nil
    var evidence: DeviceParticipantEvidence? = nil
    var settings: DeviceAgentSettings? = nil
    var imageAssist: DeviceImageAssistResult? = nil
    var exportPage: DeviceExportPage? = nil
    var exportImage: Data? = nil
    var exportImageTotal: Int? = nil
}
struct ParticipantMutationReceipt: Codable {
    var id: UUID
    var origin: String
    var payloadHash: String
    var response: DeviceParticipantResponse
}

enum DeviceCanonical {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

// Command payload binding. Viewers send canonical bytes once and resend
// exactly those bytes; the home binds a command ID to the SHA-256 of the
// payload's canonical JSON so key order alone can never turn a retry into
// "changed content". Canonical form keeps every field, known or not: keys
// sorted by code point, no whitespace, numbers and literals verbatim,
// strings re-escaped minimally. Duplicate keys, invalid UTF-8, lone
// surrogates and non-JSON are rejected rather than normalized away.
// Mirrored byte-for-byte by DeviceCommandBinding in
// windows/src/Converse.Core/Protocol.cs; both suites run
// Tests/command-payload-canonical-vectors.json.
//
// Payloads arrive from remote devices and are canonicalized on the home's
// connection queue, so cost stays near linear: input is capped at maxBytes
// (the whole device frame limit; real commands are a few KB) and nesting at
// maxDepth, output goes into one buffer, duplicate keys are found with a
// per-object hash set of exact scalar sequences, and only objects whose keys
// arrive out of order are rearranged (each byte moves at most once per
// enclosing unsorted object, so at most maxDepth times).
enum DeviceCommandBinding {
    static let rawScheme = "raw", canonicalScheme = "canonical-v1"
    static let rawMismatchDetail = "Home already recorded this command ID from an older version and can't confirm the content matches. It may already be applied; check home before sending again."
    static let unrecordedDetail = "Home has no record of this send, so nothing was applied there."
    static let maxBytes = 4_194_304, maxDepth = 64
    struct Unbindable: Error { var reason: String }
    static func encode<T: Encodable>(_ value: T) throws -> Data { try canonical(JSONEncoder().encode(value)) }
    // Records without a scheme predate canonical binding and keep raw hashes.
    static func hash(_ payload: Data, scheme: String?) -> String? {
        switch scheme ?? rawScheme {
        case rawScheme: return DeviceBlob.sha256Hex(payload)
        case canonicalScheme: return (try? canonical(payload)).map(DeviceBlob.sha256Hex)
        default: return nil
        }
    }
    static func canonical(_ payload: Data) throws -> Data {
        guard payload.count <= maxBytes else { throw Unbindable(reason: "Payload exceeds " + String(maxBytes) + " bytes.") }
        var parser = Parser(bytes: [UInt8](payload))
        parser.out.reserveCapacity(payload.count)
        parser.skipSpace()
        try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw Unbindable(reason: "Trailing content after JSON value.") }
        return Data(parser.out)
    }
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var out: [UInt8] = []
        var scratch: [UInt8] = []
        mutating func skipSpace() {
            while index < bytes.count {
                switch bytes[index] { case 0x20, 0x09, 0x0A, 0x0D: index += 1; default: return }
            }
        }
        func fail(_ reason: String) -> Unbindable { Unbindable(reason: reason + " at byte " + String(index) + ".") }
        mutating func value(depth: Int) throws {
            guard index < bytes.count else { throw fail("Unexpected end of JSON") }
            switch bytes[index] {
            case UInt8(ascii: "{"): try object(depth: depth + 1)
            case UInt8(ascii: "["): try array(depth: depth + 1)
            case UInt8(ascii: "\""): emit(try string())
            case UInt8(ascii: "t"): try literal("true")
            case UInt8(ascii: "f"): try literal("false")
            case UInt8(ascii: "n"): try literal("null")
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): try number()
            default: throw fail("Unexpected character")
            }
        }
        mutating func object(depth: Int) throws {
            guard depth <= DeviceCommandBinding.maxDepth else { throw fail("JSON nested too deeply") }
            index += 1; skipSpace()
            out.append(UInt8(ascii: "{"))
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; out.append(UInt8(ascii: "}")); return }
            // Keys compare as exact scalar sequences: String equality would
            // merge canonically equivalent keys such as "é" and "e\u{301}".
            var seen = Set<[UInt32]>()
            var members: [(key: [UInt32], bytes: Range<Int>)] = []
            var inOrder = true
            let start = out.count
            while true {
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("Expected object key") }
                let key = try string()
                guard seen.insert(key).inserted else { throw fail("Duplicate object key") }
                if let last = members.last, !last.key.lexicographicallyPrecedes(key) { inOrder = false }
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail("Expected colon") }
                index += 1; skipSpace()
                if !members.isEmpty { out.append(UInt8(ascii: ",")) }
                let memberStart = out.count
                emit(key); out.append(UInt8(ascii: ":"))
                try value(depth: depth)
                members.append((key, memberStart..<out.count))
                skipSpace()
                guard index < bytes.count else { throw fail("Unterminated object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; skipSpace(); continue }
                guard bytes[index] == UInt8(ascii: "}") else { throw fail("Expected comma or closing brace") }
                index += 1; break
            }
            if !inOrder {
                // UTF-8 byte order equals code point order, the same in C#.
                members.sort { $0.key.lexicographicallyPrecedes($1.key) }
                // Same members and commas, so rewrite the region in place.
                scratch.removeAll(keepingCapacity: true)
                scratch += out[start...]
                var at = start
                for (offset, member) in members.enumerated() {
                    if offset > 0 { out[at] = UInt8(ascii: ","); at += 1 }
                    let from = member.bytes.lowerBound - start, count = member.bytes.count
                    out.replaceSubrange(at..<at + count, with: scratch[from..<from + count]); at += count
                }
            }
            out.append(UInt8(ascii: "}"))
        }
        mutating func array(depth: Int) throws {
            guard depth <= DeviceCommandBinding.maxDepth else { throw fail("JSON nested too deeply") }
            index += 1; skipSpace()
            out.append(UInt8(ascii: "["))
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; out.append(UInt8(ascii: "]")); return }
            while true {
                try value(depth: depth)
                skipSpace()
                guard index < bytes.count else { throw fail("Unterminated array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; skipSpace(); out.append(UInt8(ascii: ",")); continue }
                guard bytes[index] == UInt8(ascii: "]") else { throw fail("Expected comma or closing bracket") }
                index += 1; break
            }
            out.append(UInt8(ascii: "]"))
        }
        mutating func literal(_ word: StaticString) throws {
            let count = word.utf8CodeUnitCount
            guard index + count <= bytes.count else { throw fail("Invalid literal") }
            for offset in 0..<count where bytes[index + offset] != word.utf8Start[offset] { throw fail("Invalid literal") }
            out += bytes[index..<index + count]; index += count
        }
        // JSON number grammar, kept verbatim: no float conversion can differ
        // between Swift and C#, and differing spellings stay different content.
        mutating func number() throws {
            let start = index
            func digits() -> Int { let from = index; while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }; return index - from }
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { throw fail("Invalid number") }
            if bytes[index] == UInt8(ascii: "0") { index += 1 } else { guard digits() > 0 else { throw fail("Invalid number") } }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") { index += 1; guard digits() > 0 else { throw fail("Invalid number") } }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw fail("Invalid number") }
            }
            out += bytes[start..<index]
        }
        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw fail("Invalid unicode escape") }
            var value: UInt32 = 0
            for byte in bytes[index..<index + 4] {
                let digit: UInt8
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
                default: throw fail("Invalid unicode escape")
                }
                value = value * 16 + UInt32(digit)
            }
            index += 4; return value
        }
        // Decoded Unicode scalars; never repairs invalid input.
        mutating func string() throws -> [UInt32] {
            index += 1
            var scalars: [UInt32] = []
            while true {
                guard index < bytes.count else { throw fail("Unterminated string") }
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") { index += 1; return scalars }
                if byte < 0x20 { throw fail("Unescaped control character") }
                if byte == UInt8(ascii: "\\") {
                    index += 1
                    guard index < bytes.count else { throw fail("Unterminated escape") }
                    let escape = bytes[index]; index += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append(0x22)
                    case UInt8(ascii: "\\"): scalars.append(0x5C)
                    case UInt8(ascii: "/"): scalars.append(0x2F)
                    case UInt8(ascii: "b"): scalars.append(0x08)
                    case UInt8(ascii: "f"): scalars.append(0x0C)
                    case UInt8(ascii: "n"): scalars.append(0x0A)
                    case UInt8(ascii: "r"): scalars.append(0x0D)
                    case UInt8(ascii: "t"): scalars.append(0x09)
                    case UInt8(ascii: "u"):
                        let unit = try hex4()
                        if (0xD800...0xDBFF).contains(unit) {
                            guard index + 2 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { throw fail("Lone surrogate escape") }
                            index += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw fail("Lone surrogate escape") }
                            scalars.append(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
                        } else {
                            guard !(0xDC00...0xDFFF).contains(unit) else { throw fail("Lone surrogate escape") }
                            scalars.append(unit)
                        }
                    default: throw fail("Invalid escape")
                    }
                    continue
                }
                if byte < 0x80 { scalars.append(UInt32(byte)); index += 1; continue }
                // Strict UTF-8: no overlongs, surrogates or values past U+10FFFF.
                let length: Int, minimum: UInt32
                var scalar: UInt32
                switch byte {
                case 0xC2...0xDF: length = 2; minimum = 0x80; scalar = UInt32(byte & 0x1F)
                case 0xE0...0xEF: length = 3; minimum = 0x800; scalar = UInt32(byte & 0x0F)
                case 0xF0...0xF4: length = 4; minimum = 0x10000; scalar = UInt32(byte & 0x07)
                default: throw fail("Invalid UTF-8")
                }
                guard index + length <= bytes.count else { throw fail("Invalid UTF-8") }
                for continuation in bytes[index + 1..<index + length] {
                    guard continuation & 0xC0 == 0x80 else { throw fail("Invalid UTF-8") }
                    scalar = scalar << 6 | UInt32(continuation & 0x3F)
                }
                guard scalar >= minimum, scalar <= 0x10FFFF, !(0xD800...0xDFFF).contains(scalar) else { throw fail("Invalid UTF-8") }
                scalars.append(scalar); index += length
            }
        }
        static let hex = Array("0123456789abcdef".utf8)
        mutating func emit(_ scalars: [UInt32]) {
            out.append(UInt8(ascii: "\""))
            for scalar in scalars {
                switch scalar {
                case 0x22: escape(UInt8(ascii: "\""))
                case 0x5C: escape(UInt8(ascii: "\\"))
                case 0x08: escape(UInt8(ascii: "b"))
                case 0x0C: escape(UInt8(ascii: "f"))
                case 0x0A: escape(UInt8(ascii: "n"))
                case 0x0D: escape(UInt8(ascii: "r"))
                case 0x09: escape(UInt8(ascii: "t"))
                case 0..<0x20: escape(UInt8(ascii: "u")); out.append(UInt8(ascii: "0")); out.append(UInt8(ascii: "0")); out.append(Self.hex[Int(scalar >> 4)]); out.append(Self.hex[Int(scalar & 0xF)])
                case 0..<0x80: out.append(UInt8(scalar))
                case 0..<0x800: out.append(UInt8(0xC0 | scalar >> 6)); out.append(UInt8(0x80 | scalar & 0x3F))
                case 0..<0x10000: out.append(UInt8(0xE0 | scalar >> 12)); out.append(UInt8(0x80 | scalar >> 6 & 0x3F)); out.append(UInt8(0x80 | scalar & 0x3F))
                default: out.append(UInt8(0xF0 | scalar >> 18)); out.append(UInt8(0x80 | scalar >> 12 & 0x3F)); out.append(UInt8(0x80 | scalar >> 6 & 0x3F)); out.append(UInt8(0x80 | scalar & 0x3F))
                }
            }
            out.append(UInt8(ascii: "\""))
        }
        mutating func escape(_ letter: UInt8) { out.append(UInt8(ascii: "\\")); out.append(letter) }
    }
}
struct DeviceParticipantIntent: Codable, Identifiable {
    var id: UUID
    var home: String
    var request: DeviceParticipantRequest
    var outcome: String = "pending"
    var response: DeviceParticipantResponse? = nil
}

// Only queue identities, never prompt text. Readiness is computed on its home.
struct DeviceQueueWatch: Codable {
    var target: String
    var source: String
    var delivery: UUID
}
struct DeviceQueueWatchReport: Codable {
    var groupID: String
    var entries: [DeviceQueueWatch]
}

// Read-only export: no display lease, no draft, no mutation receipt.
struct DeviceExportRequest: Codable, Equatable {
    var offset: Int = 0
    var total: Int? = nil
    var fingerprint: String? = nil
    var imageHash: String? = nil
}
struct DeviceExportPage: Codable {
    var title: String
    var provider: String
    var offset: Int
    var total: Int
    var fingerprint: String
    var messages: [DeviceWireMessage]
}
