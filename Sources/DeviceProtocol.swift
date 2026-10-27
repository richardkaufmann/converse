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
        var frame = Data(count: 4)
        frame.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(body.count).bigEndian, as: UInt32.self) }
        return frame + body
    }
}

struct DeviceFrameDecoder {
    private var buffer = Data()
    mutating func append(_ chunk: Data) throws -> [DeviceEnvelope] {
        buffer.append(chunk)
        var envelopes: [DeviceEnvelope] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { Int(UInt32(bigEndian: $0.load(as: UInt32.self))) }
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

// SAS rationale: the code is the first 32 bits of the Noise handshake hash
// (the channel-binding value, Noise 11.2) reduced to six decimal digits and
// compared by the user on both devices. An active MITM terminates two
// different handshakes, yielding different hashes; matching codes therefore
// bind both static keys and the full transcript. Six digits give roughly
// one-in-a-million blind success per pairing attempt; pairing allows one
// attempt per connection and disconnects on reject or timeout.
enum DeviceSAS {
    static func code(_ handshakeHash: Data) -> String {
        let value = handshakeHash.prefix(4).withUnsafeBytes { $0.count == 4 ? UInt32(bigEndian: $0.load(as: UInt32.self)) : 0 }
        return String(format: "%06d", value % 1_000_000)
    }
}

struct DeviceHello: Codable, Equatable {
    var deviceID: String
    var deviceName: String
    var converseVersion: String
    var protocolVersion = 1
    var capabilities: [String] = ["sidebar", "lease", "transcript", "commands", "blobs"]
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
}
struct DevicePendingDTO: Codable, Equatable, Identifiable {
    var id: UUID
    var text: String
}
struct DeviceChoiceDTO: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var detail: String? = nil
}
struct DeviceRequestDTO: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var toolName: String? = nil
    var rawArgs: String? = nil
    var choices: [DeviceChoiceDTO] = []
    var questionsJSON: Data? = nil
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
}

struct DeviceAckPayload: Codable, Equatable {
    var outcome: String
    var detail: String? = nil
    var epoch: UInt64? = nil
}

struct DeviceDraftPayload: Codable, Equatable {
    var version: UInt64
    var text: String
}

struct DeviceBlobPayload: Codable, Equatable {
    var sha256Hex: String
    var size: Int? = nil
    var chunk: Data? = nil
    var done: Bool = false
}
