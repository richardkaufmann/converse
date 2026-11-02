using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Converse.Core;

// Mirror of Sources/DeviceProtocol.swift. JSON keys must match Swift Codable
// exactly; Data fields travel as base64 (byte[] in System.Text.Json).
public static class DeviceJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };
    public static byte[] Encode<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);
    public static T Decode<T>(ReadOnlySpan<byte> data) =>
        JsonSerializer.Deserialize<T>(data, Options) ?? throw new InvalidDataException("Invalid device JSON.");
}

public sealed class DeviceEnvelope
{
    [JsonPropertyName("version")] public int Version { get; set; } = 1;
    [JsonPropertyName("kind")] public string Kind { get; set; } = "";
    [JsonPropertyName("homeSeq")] public ulong? HomeSeq { get; set; }
    [JsonPropertyName("boot")] public ulong? Boot { get; set; }
    [JsonPropertyName("sessionID")] public string? SessionID { get; set; }
    [JsonPropertyName("commandID")] public Guid? CommandID { get; set; }
    [JsonPropertyName("epoch")] public ulong? Epoch { get; set; }
    [JsonPropertyName("payload")] public byte[]? Payload { get; set; }
}

public static class DeviceKind
{
    public const string Hello = "hello";
    public const string SidebarSnapshot = "sidebar.snapshot";
    public const string LeaseAcquire = "lease.acquire";
    public const string LeaseGranted = "lease.granted";
    public const string LeaseDenied = "lease.denied";
    public const string LeaseResume = "lease.resume";
    public const string LeaseExpired = "lease.expired";
    public const string LeaseStolen = "lease.stolen";
    public const string LeaseHeartbeat = "lease.heartbeat";
    public const string LeaseRelease = "lease.release";
    public const string TranscriptSnapshot = "transcript.snapshot";
    public const string TranscriptRequest = "transcript.request";
    public const string DraftPatch = "draft.patch";
    public const string DraftAck = "draft.ack";
    public const string Command = "command";
    public const string CommandAck = "command.ack";
    public const string CommandQuery = "command.query";
    public const string BlobOffer = "blob.offer";
    public const string BlobChunk = "blob.chunk";
    public const string BlobComplete = "blob.complete";
    public const string BlobAck = "blob.ack";
    public const string BlobRequest = "blob.request";
    public const string BlobData = "blob.data";
    public const string Ping = "ping";
    public const string Pong = "pong";
    public const string PairConfirm = "pair.confirm";
    public const string FabricMembers = "fabric.members";
    public const string GroupState = "group.state";
    public const string GroupRequests = "group.requests";
    public const string GroupReview = "group.review";
    public const string GroupReviewDetail = "group.review.detail";
    public const string GroupApprove = "group.approve";
}

public static class DeviceFrame
{
    public const int MaxPayload = 4_194_304;
    public static byte[] Encode(DeviceEnvelope envelope)
    {
        var body = DeviceJson.Encode(envelope);
        if (body.Length > MaxPayload) throw new InvalidDataException("Device frame exceeds size limit.");
        var frame = new byte[4 + body.Length];
        frame[0] = (byte)(body.Length >> 24); frame[1] = (byte)(body.Length >> 16);
        frame[2] = (byte)(body.Length >> 8); frame[3] = (byte)body.Length;
        body.CopyTo(frame, 4);
        return frame;
    }
}

public sealed class DeviceFrameDecoder
{
    private readonly List<byte> _buffer = new();
    public List<DeviceEnvelope> Append(ReadOnlySpan<byte> chunk)
    {
        _buffer.AddRange(chunk.ToArray());
        var envelopes = new List<DeviceEnvelope>();
        while (_buffer.Count >= 4)
        {
            var length = (_buffer[0] << 24) | (_buffer[1] << 16) | (_buffer[2] << 8) | _buffer[3];
            if (length <= 0 || length > DeviceFrame.MaxPayload) throw new InvalidDataException("Device frame exceeds size limit.");
            if (_buffer.Count < 4 + length) break;
            var body = _buffer.GetRange(4, length).ToArray();
            _buffer.RemoveRange(0, 4 + length);
            envelopes.Add(DeviceJson.Decode<DeviceEnvelope>(body));
        }
        return envelopes;
    }
}

public readonly record struct DeviceGlobalID(string Home, Guid Session)
{
    public override string ToString() => Home + "/" + Session.ToString("D");
    public static DeviceGlobalID? Parse(string value)
    {
        var slash = value.IndexOf('/');
        if (slash <= 0 || !Guid.TryParse(value[(slash + 1)..], out var session)) return null;
        return new DeviceGlobalID(value[..slash], session);
    }
}

// 128-bit verification code: first 16 bytes of the Noise handshake hash as
// 32 hex characters in eight groups. Never truncate further (grindable).
public static class DeviceSas
{
    public static string Code(ReadOnlySpan<byte> handshakeHash)
    {
        var hex = Convert.ToHexString(handshakeHash[..Math.Min(16, handshakeHash.Length)]).ToLowerInvariant();
        var groups = new List<string>();
        for (var i = 0; i < hex.Length; i += 4) groups.Add(hex.Substring(i, Math.Min(4, hex.Length - i)));
        return string.Join(" ", groups);
    }
}

public static class DeviceBlob
{
    public const int MaxBlob = 25_000_000;
    public static string Sha256Hex(ReadOnlySpan<byte> data) =>
        Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
    public static bool Verify(ReadOnlySpan<byte> data, string expected) =>
        string.Equals(Sha256Hex(data), expected, StringComparison.OrdinalIgnoreCase);
    public static string DeviceIdForPublicKey(ReadOnlySpan<byte> publicKey) => Sha256Hex(publicKey);
}

public sealed class DeviceHello
{
    [JsonPropertyName("deviceID")] public string DeviceID { get; set; } = "";
    [JsonPropertyName("deviceName")] public string DeviceName { get; set; } = "";
    [JsonPropertyName("converseVersion")] public string ConverseVersion { get; set; } = "";
    [JsonPropertyName("protocolVersion")] public int ProtocolVersion { get; set; } = 1;
    [JsonPropertyName("capabilities")] public string[] Capabilities { get; set; } = { "sidebar", "lease", "lease-resume-v1", "transcript", "commands", "blobs", "fabric-membership-v1", "converse-groups-v1" };
    [JsonPropertyName("listenPort")] public int? ListenPort { get; set; }
    [JsonPropertyName("group")] public ConverseGroup? Group { get; set; }
    [JsonPropertyName("joinGroupID")] public string? JoinGroupID { get; set; }
}

// A group is an immutable identity/name plus a permanent dissolution
// tombstone. Discovery supplies hints; only an authenticated member may
// convey state. JSON keys match Swift ConverseGroup Codable exactly.
public sealed class ConverseGroup
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("creator")] public string Creator { get; set; } = "";
    [JsonPropertyName("dissolved")] public bool Dissolved { get; set; }
    [JsonIgnore]
    public bool Valid =>
        Guid.TryParse(Id, out _) && Name.Trim().Length > 0
        && System.Text.Encoding.UTF8.GetByteCount(Name) <= 120
        && Creator.Length == 64 && Creator.All(c => Uri.IsHexDigit(c) && !char.IsUpper(c));
}

public sealed class GroupJoinRequest
{
    [JsonPropertyName("id")] public Guid Id { get; set; }
    [JsonPropertyName("groupID")] public string GroupID { get; set; } = "";
    [JsonPropertyName("requesterID")] public string RequesterID { get; set; } = "";
    [JsonPropertyName("requesterName")] public string RequesterName { get; set; } = "";
    [JsonPropertyName("sponsorID")] public string SponsorID { get; set; } = "";
    // Apple-epoch DOUBLE, preserved exactly end to end. Never convert to
    // DateTime ticks: tick rounding breaks request equality checks.
    [JsonPropertyName("expiresAt")] public double ExpiresAt { get; set; }
    [JsonPropertyName("approved")] public bool Approved { get; set; }
}

public sealed class GroupJoinReview
{
    [JsonPropertyName("request")] public GroupJoinRequest Request { get; set; } = new();
    [JsonPropertyName("code")] public string Code { get; set; } = "";
}

public sealed class DeviceSidebarRow
{
    [JsonPropertyName("globalID")] public string GlobalID { get; set; } = "";
    [JsonPropertyName("sessionID")] public Guid SessionID { get; set; }
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("assistant")] public string Assistant { get; set; } = "";
    [JsonPropertyName("engine")] public string Engine { get; set; } = "";
    [JsonPropertyName("model")] public string Model { get; set; } = "";
    [JsonPropertyName("effort")] public string Effort { get; set; } = "";
    [JsonPropertyName("access")] public string Access { get; set; } = "";
    [JsonPropertyName("status")] public string Status { get; set; } = "";
    [JsonPropertyName("busy")] public bool Busy { get; set; }
    [JsonPropertyName("queued")] public int Queued { get; set; }
    [JsonPropertyName("queuePaused")] public bool QueuePaused { get; set; }
    [JsonPropertyName("leaseHolder")] public string? LeaseHolder { get; set; }
    [JsonPropertyName("leaseEpoch")] public ulong? LeaseEpoch { get; set; }
    [JsonPropertyName("accountName")] public string? AccountName { get; set; }
    [JsonPropertyName("messagingEnabled")] public bool? MessagingEnabled { get; set; }
    [JsonPropertyName("participantKind")] public string? ParticipantKind { get; set; }
    [JsonPropertyName("attention")] public string? Attention { get; set; }
    [JsonPropertyName("linkedSessionIDs")] public string[]? LinkedSessionIDs { get; set; }

}

public sealed class DeviceSidebarPayload
{
    [JsonPropertyName("homeDeviceID")] public string HomeDeviceID { get; set; } = "";
    [JsonPropertyName("homeDeviceName")] public string HomeDeviceName { get; set; } = "";
    [JsonPropertyName("homeSeq")] public ulong HomeSeq { get; set; }
    [JsonPropertyName("rows")] public List<DeviceSidebarRow> Rows { get; set; } = new();
}

public sealed class DeviceWireMessage
{
    [JsonPropertyName("id")] public Guid Id { get; set; }
    [JsonPropertyName("role")] public string Role { get; set; } = "";
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("imageHashes")] public string[] ImageHashes { get; set; } = Array.Empty<string>();
    // Optional UTC Unix seconds shared with Swift; absent in old peers/history.
    [JsonPropertyName("createdAtUnixSeconds")] public double? CreatedAtUnixSeconds { get; set; }
    [JsonIgnore] public DateTime? CreatedAt
    {
        get => CreatedAtUnixSeconds is { } seconds && double.IsFinite(seconds)
            && seconds >= -62135596800 && seconds < 253402300800
            ? DateTime.UnixEpoch.AddSeconds(seconds) : null;
        set => CreatedAtUnixSeconds = value is { } date ? (date.ToUniversalTime() - DateTime.UnixEpoch).TotalSeconds : null;
    }

}

public sealed class DevicePendingDto
{
    [JsonPropertyName("id")] public Guid Id { get; set; }
    [JsonPropertyName("text")] public string Text { get; set; } = "";
}

public sealed class DeviceChoiceDto
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("label")] public string Label { get; set; } = "";
    [JsonPropertyName("detail")] public string? Detail { get; set; }
    [JsonPropertyName("provider")] public string? Provider { get; set; }
    [JsonPropertyName("profile")] public string? Profile { get; set; }
}

public sealed class DeviceRequestDto
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("kind")] public string Kind { get; set; } = "";
    [JsonPropertyName("toolName")] public string? ToolName { get; set; }
    [JsonPropertyName("rawArgs")] public string? RawArgs { get; set; }
    [JsonPropertyName("choices")] public List<DeviceChoiceDto> Choices { get; set; } = new();
    [JsonPropertyName("questionsJSON")] public byte[]? QuestionsJson { get; set; }
}

public sealed class DeviceTranscriptPayload
{
    [JsonPropertyName("agentWidget")] public DeviceAgentWidget? AgentWidget { get; set; }

    [JsonPropertyName("globalID")] public string GlobalID { get; set; } = "";
    [JsonPropertyName("homeSeq")] public ulong HomeSeq { get; set; }
    [JsonPropertyName("epoch")] public ulong? Epoch { get; set; }
    [JsonPropertyName("boot")] public ulong? Boot { get; set; }
    [JsonPropertyName("messages")] public List<DeviceWireMessage> Messages { get; set; } = new();
    [JsonPropertyName("offset")] public int Offset { get; set; }
    [JsonPropertyName("total")] public int Total { get; set; }
    [JsonPropertyName("prepend")] public bool Prepend { get; set; }
    [JsonPropertyName("draft")] public string Draft { get; set; } = "";
    [JsonPropertyName("draftVersion")] public ulong DraftVersion { get; set; }
    [JsonPropertyName("draftImageHashes")] public string[]? DraftImageHashes { get; set; }
    [JsonPropertyName("pending")] public List<DevicePendingDto> Pending { get; set; } = new();
    [JsonPropertyName("busy")] public bool Busy { get; set; }
    [JsonPropertyName("status")] public string Status { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("engine")] public string Engine { get; set; } = "";
    [JsonPropertyName("accountName")] public string? AccountName { get; set; }
    [JsonPropertyName("model")] public string Model { get; set; } = "";
    [JsonPropertyName("effort")] public string Effort { get; set; } = "";
    [JsonPropertyName("access")] public string Access { get; set; } = "";
    [JsonPropertyName("modelOptions")] public List<DeviceChoiceDto> ModelOptions { get; set; } = new();
    [JsonPropertyName("effortOptions")] public string[] EffortOptions { get; set; } = Array.Empty<string>();
    [JsonPropertyName("accessOptions")] public List<DeviceChoiceDto> AccessOptions { get; set; } = new();
    [JsonPropertyName("requests")] public List<DeviceRequestDto> Requests { get; set; } = new();
    [JsonPropertyName("queuePaused")] public bool QueuePaused { get; set; }
}

public sealed class DeviceTranscriptRequest
{
    [JsonPropertyName("beforeOffset")] public int BeforeOffset { get; set; }
}

public sealed class DeviceCommandPayload
{
    [JsonPropertyName("action")] public string Action { get; set; } = "";
    [JsonPropertyName("text")] public string? Text { get; set; }
    [JsonPropertyName("blobHashes")] public string[] BlobHashes { get; set; } = Array.Empty<string>();
    [JsonPropertyName("model")] public string? Model { get; set; }
    [JsonPropertyName("effort")] public string? Effort { get; set; }
    [JsonPropertyName("access")] public string? Access { get; set; }
    [JsonPropertyName("pendingID")] public Guid? PendingID { get; set; }
    [JsonPropertyName("requestID")] public string? RequestID { get; set; }
    [JsonPropertyName("choiceID")] public string? ChoiceID { get; set; }
    [JsonPropertyName("answersJSON")] public byte[]? AnswersJson { get; set; }
    [JsonPropertyName("modelProvider")] public string? ModelProvider { get; set; }
    [JsonPropertyName("modelProfile")] public string? ModelProfile { get; set; }
}

public sealed class DeviceAckPayload
{
    [JsonPropertyName("outcome")] public string Outcome { get; set; } = "";
    [JsonPropertyName("detail")] public string? Detail { get; set; }
    [JsonPropertyName("epoch")] public ulong? Epoch { get; set; }
}

public sealed class DeviceDraftPayload
{
    [JsonPropertyName("version")] public ulong Version { get; set; }
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("imageHashes")] public string[]? ImageHashes { get; set; }
}

public sealed class DeviceBlobPayload
{
    [JsonPropertyName("sha256Hex")] public string Sha256Hex { get; set; } = "";
    [JsonPropertyName("size")] public int? Size { get; set; }
    [JsonPropertyName("chunk")] public byte[]? Chunk { get; set; }
    [JsonPropertyName("done")] public bool Done { get; set; }
}

public static class Hex
{
    public static byte[] Decode(string hex)
    {
        var bytes = new byte[hex.Length / 2];
        for (var i = 0; i < bytes.Length; i++) bytes[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
        return bytes;
    }
    public static string Encode(ReadOnlySpan<byte> data) => Convert.ToHexString(data).ToLowerInvariant();
    public static byte[] Utf8(string value) => Encoding.UTF8.GetBytes(value);
}
