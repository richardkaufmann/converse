import CryptoKit
import Foundation

// Versioned wire protocol for device sync. Independent of UI and Store types
// so later Windows and iPad clients can implement the same schema.
enum DeviceMessageKind: String, Codable {
    case hello, sidebarSnapshot = "sidebar.snapshot", sidebarDelta = "sidebar.delta"
    case leaseAcquire = "lease.acquire", leaseGranted = "lease.granted", leaseDenied = "lease.denied"
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
    var protocolVersion = 1
    var capabilities: [String] = ["sidebar", "lease", "transcript", "commands", "blobs", "fabric-membership-v1", "switchboard-teach-v1", "converse-groups-v1"]
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
}
struct DevicePendingDTO: Codable, Equatable, Identifiable {
    var id: UUID
    var text: String
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
struct DeviceAgentWidget: Codable {
    var summary: String
    var metrics: [DeviceWidgetMetric]
    var observedAt: Date?
    var attention: String
    var artHash: String?
    var loopStatus: String? = nil
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
}
struct GroupTellReceipt: Codable {
    var id: UUID
    var origin: String
    var payloadHash: String
}

struct DeviceAgentSettings: Codable, Equatable {
    var objective: String
    var repository: String
    var model: String
    var watched: [String]
    var intervalSeconds: Double
    var remainingRuns: Int
    var enabled: Bool
    var generateArt: Bool
    var speak: Bool
    var discord: Bool
    var fileTriggers: Bool = false
    var revision: UInt64? = nil
    var scoreboardEveryLoops: Int? = nil
    var scheduleText: String? = nil
    var scheduleTimeZone: String? = nil
}
struct DeviceParticipantRequest: Codable, Equatable {
    var groupID: String
    var action: String
    var target: String? = nil
    var title: String? = nil
    var settings: DeviceAgentSettings? = nil
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
struct DeviceParticipantIntent: Codable, Identifiable {
    var id: UUID
    var home: String
    var request: DeviceParticipantRequest
    var outcome: String = "pending"
    var response: DeviceParticipantResponse? = nil
}
