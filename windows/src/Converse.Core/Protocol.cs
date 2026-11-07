using System.Runtime.InteropServices;
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

// Command payload binding, mirror of DeviceCommandBinding in
// Sources/DeviceProtocol.swift. Viewers send canonical bytes once and resend
// exactly those bytes; the home binds a command ID to the SHA-256 of the
// payload's canonical JSON. Every field is kept, known or not: keys sorted
// by code point, no whitespace, numbers and literals verbatim, strings
// re-escaped minimally. Duplicate keys, invalid UTF-8, lone surrogates and
// non-JSON are rejected. Tests/command-payload-canonical-vectors.json is
// shared with the Swift suite; output must stay byte-identical.
//
// Payloads come from remote devices, so cost stays near linear, with the
// same limits as Swift: input is capped at MaxBytes (the whole device frame
// limit; real commands are a few KB) and nesting at MaxDepth, output goes
// into one buffer, duplicate keys are found with a per-object hash set of
// exact scalar sequences, and only objects whose keys arrive out of order
// are rearranged (each byte moves at most MaxDepth times).
public static class DeviceCommandBinding
{
    public const string RawScheme = "raw";
    public const string CanonicalScheme = "canonical-v1";
    public const string RawMismatchDetail = "Home already recorded this command ID from an older version and can't confirm the content matches. It may already be applied; check home before sending again.";
    public const string UnrecordedDetail = "Home has no record of this send, so nothing was applied there.";
    public const int MaxBytes = 4_194_304;
    public const int MaxDepth = 64;

    public sealed class UnbindableException(string reason) : Exception(reason);

    public static byte[] Encode<T>(T value) => Canonical(DeviceJson.Encode(value));

    // Records without a scheme predate canonical binding and keep raw hashes.
    public static string? Hash(byte[] payload, string? scheme)
    {
        switch (scheme ?? RawScheme)
        {
            case RawScheme: return DeviceBlob.Sha256Hex(payload);
            case CanonicalScheme:
                try { return DeviceBlob.Sha256Hex(Canonical(payload)); }
                catch (UnbindableException) { return null; }
            default: return null;
        }
    }

    public static byte[] Canonical(byte[] payload)
    {
        if (payload.Length > MaxBytes) throw new UnbindableException("Payload exceeds " + MaxBytes + " bytes.");
        var parser = new Parser(payload);
        parser.SkipSpace();
        parser.Value(0);
        parser.SkipSpace();
        if (parser.Index != payload.Length) throw new UnbindableException("Trailing content after JSON value.");
        return parser.Output.ToArray();
    }

    // Exact scalar sequences, like Swift's [UInt32] keys: ordinal, never
    // canonical equivalence, so "é" and "e\u0301" stay distinct.
    private sealed class ScalarKeyComparer : IEqualityComparer<int[]>
    {
        public static readonly ScalarKeyComparer Instance = new();
        public bool Equals(int[]? a, int[]? b) => a.AsSpan().SequenceEqual(b);
        public int GetHashCode(int[] key) { var hash = new HashCode(); hash.AddBytes(MemoryMarshal.AsBytes(key.AsSpan())); return hash.ToHashCode(); }
    }

    private sealed class Parser(byte[] bytes)
    {
        public int Index;
        public readonly List<byte> Output = new(bytes.Length);
        private byte[] _scratch = [];

        public void SkipSpace()
        {
            while (Index < bytes.Length && bytes[Index] is 0x20 or 0x09 or 0x0A or 0x0D) Index++;
        }

        private UnbindableException Fail(string reason) => new(reason + " at byte " + Index + ".");

        public void Value(int depth)
        {
            if (Index >= bytes.Length) throw Fail("Unexpected end of JSON");
            switch (bytes[Index])
            {
                case (byte)'{': Object(depth + 1); break;
                case (byte)'[': Array(depth + 1); break;
                case (byte)'"': Emit(String()); break;
                case (byte)'t': Literal("true"u8); break;
                case (byte)'f': Literal("false"u8); break;
                case (byte)'n': Literal("null"u8); break;
                case (byte)'-' or (>= (byte)'0' and <= (byte)'9'): Number(); break;
                default: throw Fail("Unexpected character");
            }
        }

        private void Object(int depth)
        {
            if (depth > MaxDepth) throw Fail("JSON nested too deeply");
            Index++; SkipSpace();
            Output.Add((byte)'{');
            if (Index < bytes.Length && bytes[Index] == (byte)'}') { Index++; Output.Add((byte)'}'); return; }
            var seen = new HashSet<int[]>(ScalarKeyComparer.Instance);
            var members = new List<(int[] Key, int Start, int End)>();
            var inOrder = true;
            var start = Output.Count;
            while (true)
            {
                if (Index >= bytes.Length || bytes[Index] != (byte)'"') throw Fail("Expected object key");
                var key = String();
                if (!seen.Add(key)) throw Fail("Duplicate object key");
                if (members.Count > 0 && members[^1].Key.AsSpan().SequenceCompareTo(key) >= 0) inOrder = false;
                SkipSpace();
                if (Index >= bytes.Length || bytes[Index] != (byte)':') throw Fail("Expected colon");
                Index++; SkipSpace();
                if (members.Count > 0) Output.Add((byte)',');
                var memberStart = Output.Count;
                Emit(key); Output.Add((byte)':');
                Value(depth);
                members.Add((key, memberStart, Output.Count));
                SkipSpace();
                if (Index >= bytes.Length) throw Fail("Unterminated object");
                if (bytes[Index] == (byte)',') { Index++; SkipSpace(); continue; }
                if (bytes[Index] != (byte)'}') throw Fail("Expected comma or closing brace");
                Index++; break;
            }
            if (!inOrder)
            {
                // Code point order, the same as Swift's UTF-8 byte order.
                members.Sort((a, b) => a.Key.AsSpan().SequenceCompareTo(b.Key));
                // Same members and commas, so rewrite the region in place.
                var region = CollectionsMarshal.AsSpan(Output)[start..];
                if (_scratch.Length < region.Length) _scratch = new byte[Math.Max(region.Length, _scratch.Length * 2)];
                region.CopyTo(_scratch);
                var at = 0;
                for (var i = 0; i < members.Count; i++)
                {
                    if (i > 0) region[at++] = (byte)',';
                    _scratch.AsSpan(members[i].Start - start, members[i].End - members[i].Start).CopyTo(region[at..]);
                    at += members[i].End - members[i].Start;
                }
            }
            Output.Add((byte)'}');
        }

        private void Array(int depth)
        {
            if (depth > MaxDepth) throw Fail("JSON nested too deeply");
            Index++; SkipSpace();
            Output.Add((byte)'[');
            if (Index < bytes.Length && bytes[Index] == (byte)']') { Index++; Output.Add((byte)']'); return; }
            while (true)
            {
                Value(depth);
                SkipSpace();
                if (Index >= bytes.Length) throw Fail("Unterminated array");
                if (bytes[Index] == (byte)',') { Index++; SkipSpace(); Output.Add((byte)','); continue; }
                if (bytes[Index] != (byte)']') throw Fail("Expected comma or closing bracket");
                Index++; break;
            }
            Output.Add((byte)']');
        }

        private void Literal(ReadOnlySpan<byte> expected)
        {
            if (Index + expected.Length > bytes.Length || !bytes.AsSpan(Index, expected.Length).SequenceEqual(expected)) throw Fail("Invalid literal");
            Output.AddRange(expected);
            Index += expected.Length;
        }

        // JSON number grammar, kept verbatim: no float conversion can differ
        // between Swift and C#, and differing spellings stay different content.
        private void Number()
        {
            var start = Index;
            int Digits() { var from = Index; while (Index < bytes.Length && bytes[Index] is >= (byte)'0' and <= (byte)'9') Index++; return Index - from; }
            if (bytes[Index] == (byte)'-') Index++;
            if (Index >= bytes.Length) throw Fail("Invalid number");
            if (bytes[Index] == (byte)'0') Index++;
            else if (Digits() == 0) throw Fail("Invalid number");
            if (Index < bytes.Length && bytes[Index] == (byte)'.') { Index++; if (Digits() == 0) throw Fail("Invalid number"); }
            if (Index < bytes.Length && bytes[Index] is (byte)'e' or (byte)'E')
            {
                Index++;
                if (Index < bytes.Length && bytes[Index] is (byte)'+' or (byte)'-') Index++;
                if (Digits() == 0) throw Fail("Invalid number");
            }
            Output.AddRange(bytes.AsSpan(start, Index - start));
        }

        private int Hex4()
        {
            if (Index + 4 > bytes.Length) throw Fail("Invalid unicode escape");
            var value = 0;
            for (var i = 0; i < 4; i++)
            {
                var b = bytes[Index + i];
                int digit = b switch
                {
                    >= (byte)'0' and <= (byte)'9' => b - '0',
                    >= (byte)'a' and <= (byte)'f' => b - 'a' + 10,
                    >= (byte)'A' and <= (byte)'F' => b - 'A' + 10,
                    _ => throw Fail("Invalid unicode escape"),
                };
                value = value * 16 + digit;
            }
            Index += 4;
            return value;
        }

        // Decoded Unicode scalars; never repairs invalid input.
        private int[] String()
        {
            Index++;
            var scalars = new List<int>();
            while (true)
            {
                if (Index >= bytes.Length) throw Fail("Unterminated string");
                var b = bytes[Index];
                if (b == (byte)'"') { Index++; return scalars.ToArray(); }
                if (b < 0x20) throw Fail("Unescaped control character");
                if (b == (byte)'\\')
                {
                    Index++;
                    if (Index >= bytes.Length) throw Fail("Unterminated escape");
                    var escape = bytes[Index++];
                    switch (escape)
                    {
                        case (byte)'"': scalars.Add(0x22); break;
                        case (byte)'\\': scalars.Add(0x5C); break;
                        case (byte)'/': scalars.Add(0x2F); break;
                        case (byte)'b': scalars.Add(0x08); break;
                        case (byte)'f': scalars.Add(0x0C); break;
                        case (byte)'n': scalars.Add(0x0A); break;
                        case (byte)'r': scalars.Add(0x0D); break;
                        case (byte)'t': scalars.Add(0x09); break;
                        case (byte)'u':
                            var unit = Hex4();
                            if (unit is >= 0xD800 and <= 0xDBFF)
                            {
                                if (Index + 2 > bytes.Length || bytes[Index] != (byte)'\\' || bytes[Index + 1] != (byte)'u') throw Fail("Lone surrogate escape");
                                Index += 2;
                                var low = Hex4();
                                if (low is < 0xDC00 or > 0xDFFF) throw Fail("Lone surrogate escape");
                                scalars.Add(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00));
                            }
                            else
                            {
                                if (unit is >= 0xDC00 and <= 0xDFFF) throw Fail("Lone surrogate escape");
                                scalars.Add(unit);
                            }
                            break;
                        default: throw Fail("Invalid escape");
                    }
                    continue;
                }
                if (b < 0x80) { scalars.Add(b); Index++; continue; }
                // Strict UTF-8: no overlongs, surrogates or values past U+10FFFF.
                int length, minimum, scalar;
                switch (b)
                {
                    case >= 0xC2 and <= 0xDF: length = 2; minimum = 0x80; scalar = b & 0x1F; break;
                    case >= 0xE0 and <= 0xEF: length = 3; minimum = 0x800; scalar = b & 0x0F; break;
                    case >= 0xF0 and <= 0xF4: length = 4; minimum = 0x10000; scalar = b & 0x07; break;
                    default: throw Fail("Invalid UTF-8");
                }
                if (Index + length > bytes.Length) throw Fail("Invalid UTF-8");
                for (var i = 1; i < length; i++)
                {
                    var continuation = bytes[Index + i];
                    if ((continuation & 0xC0) != 0x80) throw Fail("Invalid UTF-8");
                    scalar = scalar << 6 | (continuation & 0x3F);
                }
                if (scalar < minimum || scalar > 0x10FFFF || scalar is >= 0xD800 and <= 0xDFFF) throw Fail("Invalid UTF-8");
                scalars.Add(scalar); Index += length;
            }
        }

        private void Emit(int[] scalars)
        {
            const string hex = "0123456789abcdef";
            Output.Add((byte)'"');
            foreach (var scalar in scalars)
            {
                switch (scalar)
                {
                    case 0x22: Escape((byte)'"'); break;
                    case 0x5C: Escape((byte)'\\'); break;
                    case 0x08: Escape((byte)'b'); break;
                    case 0x0C: Escape((byte)'f'); break;
                    case 0x0A: Escape((byte)'n'); break;
                    case 0x0D: Escape((byte)'r'); break;
                    case 0x09: Escape((byte)'t'); break;
                    case < 0x20: Escape((byte)'u'); Output.Add((byte)'0'); Output.Add((byte)'0'); Output.Add((byte)hex[scalar >> 4]); Output.Add((byte)hex[scalar & 0xF]); break;
                    case < 0x80: Output.Add((byte)scalar); break;
                    case < 0x800: Output.Add((byte)(0xC0 | scalar >> 6)); Output.Add((byte)(0x80 | scalar & 0x3F)); break;
                    case < 0x10000: Output.Add((byte)(0xE0 | scalar >> 12)); Output.Add((byte)(0x80 | scalar >> 6 & 0x3F)); Output.Add((byte)(0x80 | scalar & 0x3F)); break;
                    default: Output.Add((byte)(0xF0 | scalar >> 18)); Output.Add((byte)(0x80 | scalar >> 12 & 0x3F)); Output.Add((byte)(0x80 | scalar >> 6 & 0x3F)); Output.Add((byte)(0x80 | scalar & 0x3F)); break;
                }
            }
            Output.Add((byte)'"');
        }

        private void Escape(byte letter) { Output.Add((byte)'\\'); Output.Add(letter); }
    }
}

public sealed class DeviceHello
{
    [JsonPropertyName("deviceID")] public string DeviceID { get; set; } = "";
    [JsonPropertyName("deviceName")] public string DeviceName { get; set; } = "";
    [JsonPropertyName("converseVersion")] public string ConverseVersion { get; set; } = "";
    // Older releases omit the build (and sent a fixed placeholder version), so
    // peers treat only a hello with a build as installed-version evidence.
    [JsonPropertyName("converseBuild")] public string? ConverseBuild { get; set; }
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
    // Viewer sidebar markers (Sources/DeviceProtocol.swift parity). Optional
    // so older peers ignore them. lastResponseAt is an Apple-epoch double on
    // the home's clock, compared only with earlier values from that home.
    [JsonPropertyName("loopPaused")] public bool? LoopPaused { get; set; }
    [JsonPropertyName("pausedReason")] public string? PausedReason { get; set; }
    [JsonPropertyName("lastResponseAt")] public double? LastResponseAt { get; set; }
}

// Home-side marker values, Mac Session.agentLoopPaused / pausedLoopReason /
// lastResponseAt parity.
public static class SidebarMarkers
{
    private static readonly DateTime AppleEpoch = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);
    public static bool? LoopPaused(ChatSession session) => session.Agent is null ? null : !session.Agent.Settings.Enabled;
    public static string? PausedReason(ChatSession session)
    {
        if (session.Agent is not { } agent || agent.Settings.Enabled) return null;
        if (!string.IsNullOrEmpty(agent.Attention)) return agent.Attention;
        return agent.LastLoopUtc is null ? "Never run — enable the loop in Agent Setup." : "Loop paused. Re-enable it in Agent Setup / Loop.";
    }
    // Newest assistant response; a running turn's partial reply never counts.
    public static double? LastResponseAt(IReadOnlyList<ChatMessage> messages, bool busy)
    {
        var end = messages.Count;
        if (busy) { var turn = -1; for (var i = messages.Count - 1; i >= 0; i--) if (messages[i].Role == "user") { turn = i; break; } if (turn >= 0) end = turn; }
        for (var i = end - 1; i >= 0; i--)
        {
            var m = messages[i];
            if (m.Role != "assistant" || (string.IsNullOrEmpty(m.Text) && m.Images.Count == 0)) continue;
            if (m.CreatedAt is not { } at) continue; // Older archives carry no times.
            var utc = at.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(at, DateTimeKind.Utc) : at.ToUniversalTime();
            return (utc - AppleEpoch).TotalSeconds;
        }
        return null;
    }
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
    /// True on a home's answer to a status query. Older homes omit it.
    [JsonPropertyName("query")] public bool? Query { get; set; }
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
