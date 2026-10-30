using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Converse.Linux;

internal static class AdminJson
{
    public static readonly JsonSerializerOptions Options = new();

    public static string Serialize(object value) =>
        JsonSerializer.Serialize(value, value.GetType(), Options);

    public static string PayloadHash(JsonElement payload)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
            WriteCanonical(writer, payload);
        return Convert.ToHexString(SHA256.HashData(stream.ToArray())).ToLowerInvariant();
    }

    public static string RequestHash(AdminRequest request)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WritePropertyName("expectedDeviceID");
            if (request.ExpectedDeviceID is null) writer.WriteNullValue();
            else writer.WriteStringValue(request.ExpectedDeviceID);
            writer.WritePropertyName("operation");
            writer.WriteStringValue(request.Operation);
            writer.WritePropertyName("payload");
            WriteCanonical(writer, request.Payload);
            writer.WriteEndObject();
        }
        return Convert.ToHexString(SHA256.HashData(stream.ToArray())).ToLowerInvariant();
    }

    private static void WriteCanonical(Utf8JsonWriter writer, JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in value.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    WriteCanonical(writer, property.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in value.EnumerateArray()) WriteCanonical(writer, item);
                writer.WriteEndArray();
                break;
            default:
                value.WriteTo(writer);
                break;
        }
    }
}

internal sealed class AdminRequest
{
    [JsonPropertyName("adminApiVersion")] public int AdminApiVersion { get; set; }
    [JsonPropertyName("requestID")] public Guid RequestID { get; set; }
    [JsonPropertyName("operation")] public string Operation { get; set; } = "";
    [JsonPropertyName("expectedDeviceID")] public string? ExpectedDeviceID { get; set; }
    [JsonPropertyName("operationID")] public Guid? OperationID { get; set; }
    [JsonPropertyName("payload")] public JsonElement Payload { get; set; }
}

internal sealed class AdminResponse
{
    [JsonPropertyName("adminApiVersion")] public int AdminApiVersion { get; set; } = 1;
    [JsonPropertyName("requestID")] public Guid RequestID { get; set; }
    [JsonPropertyName("ok")] public bool Ok { get; set; }
    [JsonPropertyName("result")] public JsonNode? Result { get; set; }
    [JsonPropertyName("operation")] public AdminOperation? Operation { get; set; }
    [JsonPropertyName("error")] public AdminError? Error { get; set; }

    public static AdminResponse Success(Guid requestID, object? result = null, AdminOperation? operation = null)
    {
        return new AdminResponse
        {
            RequestID = requestID,
            Ok = true,
            Result = result is null ? null : JsonSerializer.SerializeToNode(result, result.GetType(), AdminJson.Options),
            Operation = operation,
            Error = null,
        };
    }

    public static AdminResponse Failure(
        Guid requestID, string code, string message, bool retryable = false, bool uncertain = false)
    {
        return new AdminResponse
        {
            RequestID = requestID,
            Ok = false,
            Result = null,
            Operation = null,
            Error = new AdminError
            {
                Code = code,
                Message = message,
                Retryable = retryable,
                Uncertain = uncertain,
            },
        };
    }
}

internal sealed class AdminError
{
    [JsonPropertyName("code")] public string Code { get; set; } = "";
    [JsonPropertyName("message")] public string Message { get; set; } = "";
    [JsonPropertyName("retryable")] public bool Retryable { get; set; }
    [JsonPropertyName("uncertain")] public bool Uncertain { get; set; }
}

internal sealed class AdminOperation
{
    [JsonPropertyName("operationID")] public Guid OperationID { get; set; }
    [JsonPropertyName("kind")] public string Kind { get; set; } = "";
    [JsonPropertyName("state")] public string State { get; set; } = "";
    [JsonPropertyName("episodeID")] public Guid? EpisodeID { get; set; }
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
    [JsonPropertyName("updatedAt")] public string UpdatedAt { get; set; } = "";
    [JsonPropertyName("stage")] public string Stage { get; set; } = "";
    [JsonPropertyName("message")] public string? Message { get; set; }
    [JsonPropertyName("retryable")] public bool Retryable { get; set; }
    [JsonPropertyName("uncertain")] public bool Uncertain { get; set; }
    [JsonPropertyName("result")] public JsonNode? Result { get; set; }
}

internal sealed class LinuxStatus
{
    [JsonPropertyName("product")] public string Product { get; set; } = "Converse";
    [JsonPropertyName("productVersion")] public string ProductVersion { get; set; } = "";
    [JsonPropertyName("build")] public int Build { get; set; }
    [JsonPropertyName("sourceCommit")] public string? SourceCommit { get; set; }
    [JsonPropertyName("architecture")] public string Architecture { get; set; } = "unknown";
    [JsonPropertyName("device")] public StatusDevice Device { get; set; } = new();
    [JsonPropertyName("protocols")] public StatusProtocols Protocols { get; set; } = new();
    [JsonPropertyName("runtime")] public StatusRuntime Runtime { get; set; } = new();
    [JsonPropertyName("filesystem")] public StatusFilesystem Filesystem { get; set; } = new();
    [JsonPropertyName("fabric")] public StatusFabric Fabric { get; set; } = new();
    [JsonPropertyName("work")] public StatusWork Work { get; set; } = new();
    [JsonPropertyName("release")] public StatusRelease Release { get; set; } = new();
    [JsonPropertyName("secrets")] public List<SecretMetadata> Secrets { get; set; } = new();
    [JsonPropertyName("capabilities")] public List<string> Capabilities { get; set; } = new();
}

internal sealed class StatusDevice
{
    [JsonPropertyName("deviceID")] public string? DeviceID { get; set; }
    [JsonPropertyName("name")] public string Name { get; set; } = "";
}

internal sealed class StatusProtocols
{
    [JsonPropertyName("deviceProtocolVersion")] public int DeviceProtocolVersion { get; set; } = 1;
    [JsonPropertyName("adminApiVersion")] public int AdminApiVersion { get; set; } = 1;
    [JsonPropertyName("stateSchemaVersion")] public int StateSchemaVersion { get; set; } = 1;
    [JsonPropertyName("recoveryLedgerVersion")] public int RecoveryLedgerVersion { get; set; } = 1;
}

internal sealed class StatusRuntime
{
    [JsonPropertyName("processState")] public string ProcessState { get; set; } = "starting";
    [JsonPropertyName("supervisor")] public string Supervisor { get; set; } = "none";
    [JsonPropertyName("desiredRunning")] public bool DesiredRunning { get; set; } = true;
    [JsonPropertyName("startedAt")] public string? StartedAt { get; set; }
    [JsonPropertyName("admission")] public string Admission { get; set; } = "closed_recovery";
}

internal sealed class StatusFilesystem
{
    [JsonPropertyName("installRoot")] public string? InstallRoot { get; set; }
    [JsonPropertyName("stateRoot")] public string? StateRoot { get; set; }
    [JsonPropertyName("configRoot")] public string? ConfigRoot { get; set; }
    [JsonPropertyName("dataRoot")] public string? DataRoot { get; set; }
}

internal sealed class StatusFabric
{
    [JsonPropertyName("groupID")] public string? GroupID { get; set; }
    [JsonPropertyName("groupName")] public string? GroupName { get; set; }
    [JsonPropertyName("peerCount")] public int PeerCount { get; set; }
    [JsonPropertyName("connectedPeerCount")] public int ConnectedPeerCount { get; set; }
}

internal sealed class StatusWork
{
    [JsonPropertyName("sessionCount")] public int SessionCount { get; set; }
    [JsonPropertyName("activeTurnCount")] public int ActiveTurnCount { get; set; }
    [JsonPropertyName("agentCount")] public int AgentCount { get; set; }
    [JsonPropertyName("scheduledRunCount")] public int ScheduledRunCount { get; set; }
    [JsonPropertyName("pendingCommandCount")] public int PendingCommandCount { get; set; }
}

internal sealed class StatusRelease
{
    [JsonPropertyName("currentReleaseID")] public string? CurrentReleaseID { get; set; }
    [JsonPropertyName("previousReleaseID")] public string? PreviousReleaseID { get; set; }
    [JsonPropertyName("stagedReleaseID")] public string? StagedReleaseID { get; set; }
    [JsonPropertyName("updateEpisode")] public UpdateEpisode? UpdateEpisode { get; set; }
}

internal sealed class UpdateEpisode
{
    [JsonPropertyName("episodeID")] public Guid EpisodeID { get; set; }
    [JsonPropertyName("phase")] public string Phase { get; set; } = "";
    [JsonPropertyName("fromReleaseID")] public string FromReleaseID { get; set; } = "";
    [JsonPropertyName("toReleaseID")] public string ToReleaseID { get; set; } = "";
    [JsonPropertyName("startedAt")] public string StartedAt { get; set; } = "";
    [JsonPropertyName("updatedAt")] public string UpdatedAt { get; set; } = "";
    [JsonPropertyName("explicitResolutionRequired")] public bool ExplicitResolutionRequired { get; set; }
    [JsonPropertyName("health")] public string Health { get; set; } = "pending";

    public UpdateEpisode Clone() => (UpdateEpisode)MemberwiseClone();
}

internal sealed class SecretMetadata
{
    [JsonPropertyName("secretID")] public string SecretID { get; set; } = "";
    [JsonPropertyName("kind")] public string Kind { get; set; } = "other";
    [JsonPropertyName("backend")] public string Backend { get; set; } = "linux-file-0600";
    [JsonPropertyName("configured")] public bool Configured { get; set; }
    [JsonPropertyName("storedVersion")] public long StoredVersion { get; set; }
    [JsonPropertyName("effectiveVersion")] public long EffectiveVersion { get; set; }
    [JsonPropertyName("pendingRestart")] public bool PendingRestart { get; set; }
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }
}

internal sealed class PairingBinding
{
    [JsonPropertyName("bindingVersion")] public int BindingVersion { get; set; } = 1;
    [JsonPropertyName("pairingID")] public Guid PairingID { get; set; }
    [JsonPropertyName("requestCorrelationID")] public Guid RequestCorrelationID { get; set; }
    [JsonPropertyName("nativeRequestID")] public Guid? NativeRequestID { get; set; }
    [JsonPropertyName("role")] public string Role { get; set; } = "";
    [JsonPropertyName("state")] public string State { get; set; } = "";
    [JsonPropertyName("linuxDeviceID")] public string LinuxDeviceID { get; set; } = "";
    [JsonPropertyName("requesterDeviceID")] public string RequesterDeviceID { get; set; } = "";
    [JsonPropertyName("sponsorDeviceID")] public string SponsorDeviceID { get; set; } = "";
    [JsonPropertyName("peerName")] public string PeerName { get; set; } = "";
    [JsonPropertyName("linuxPublicKeyFingerprint")] public string LinuxPublicKeyFingerprint { get; set; } = "";
    [JsonPropertyName("requesterPublicKeyFingerprint")] public string RequesterPublicKeyFingerprint { get; set; } = "";
    [JsonPropertyName("sponsorPublicKeyFingerprint")] public string SponsorPublicKeyFingerprint { get; set; } = "";
    [JsonPropertyName("groupID")] public string GroupID { get; set; } = "";
    [JsonPropertyName("groupName")] public string? GroupName { get; set; }
    [JsonPropertyName("requesterConnectionInstanceID")] public Guid? RequesterConnectionInstanceID { get; set; }
    [JsonPropertyName("sponsorConnectionInstanceID")] public Guid? SponsorConnectionInstanceID { get; set; }
    [JsonPropertyName("verificationCode")] public string? VerificationCode { get; set; }
    [JsonPropertyName("verificationCodeFingerprint")] public string? VerificationCodeFingerprint { get; set; }
    [JsonPropertyName("expiresAt")] public string ExpiresAt { get; set; } = "";
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
    [JsonPropertyName("updatedAt")] public string UpdatedAt { get; set; } = "";
}

internal sealed class PairingListResult
{
    [JsonPropertyName("requests")] public List<PairingBinding> Requests { get; set; } = new();
}

internal sealed class SecretRequestHeader
{
    [JsonPropertyName("secretApiVersion")] public int SecretApiVersion { get; set; }
    [JsonPropertyName("requestID")] public Guid RequestID { get; set; }
    [JsonPropertyName("operationID")] public Guid OperationID { get; set; }
    [JsonPropertyName("expectedDeviceID")] public string? ExpectedDeviceID { get; set; }
    [JsonPropertyName("action")] public string Action { get; set; } = "";
    [JsonPropertyName("secretID")] public string SecretID { get; set; } = "";
    [JsonPropertyName("kind")] public string? Kind { get; set; }
    [JsonPropertyName("valueByteCount")] public int ValueByteCount { get; set; }
    [JsonPropertyName("valueSHA256")] public string? ValueSHA256 { get; set; }
}

internal sealed class SecretResponse
{
    [JsonPropertyName("secretApiVersion")] public int SecretApiVersion { get; set; } = 1;
    [JsonPropertyName("requestID")] public Guid RequestID { get; set; }
    [JsonPropertyName("ok")] public bool Ok { get; set; }
    [JsonPropertyName("receipt")] public SecretReceipt? Receipt { get; set; }
    [JsonPropertyName("error")] public AdminError? Error { get; set; }

    public static SecretResponse Success(Guid requestID, SecretReceipt receipt) => new()
    {
        RequestID = requestID,
        Ok = true,
        Receipt = receipt,
        Error = null,
    };

    public static SecretResponse Failure(
        Guid requestID, string code, string message, bool retryable = false, bool uncertain = false) => new()
    {
        RequestID = requestID,
        Ok = false,
        Receipt = null,
        Error = new AdminError
        {
            Code = code,
            Message = message,
            Retryable = retryable,
            Uncertain = uncertain,
        },
    };
}

internal sealed class SecretReceipt
{
    [JsonPropertyName("operationID")] public Guid OperationID { get; set; }
    [JsonPropertyName("secretID")] public string SecretID { get; set; } = "";
    [JsonPropertyName("kind")] public string Kind { get; set; } = "other";
    [JsonPropertyName("backend")] public string Backend { get; set; } = "linux-file-0600";
    [JsonPropertyName("configured")] public bool Configured { get; set; }
    [JsonPropertyName("storedVersion")] public long StoredVersion { get; set; }
    [JsonPropertyName("effectiveVersion")] public long EffectiveVersion { get; set; }
    [JsonPropertyName("pendingRestart")] public bool PendingRestart { get; set; }
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }
}

internal sealed class SessionCreateResult
{
    [JsonPropertyName("sessionID")] public Guid SessionID { get; set; }
    [JsonPropertyName("globalID")] public string GlobalID { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("engine")] public string Engine { get; set; } = "";
}

internal sealed class ReleaseManifest
{
    [JsonPropertyName("manifestVersion")] public int ManifestVersion { get; set; }
    [JsonPropertyName("releaseID")] public string ReleaseID { get; set; } = "";
    [JsonPropertyName("product")] public string Product { get; set; } = "";
    [JsonPropertyName("productVersion")] public string ProductVersion { get; set; } = "";
    [JsonPropertyName("build")] public int Build { get; set; }
    [JsonPropertyName("sourceCommit")] public string SourceCommit { get; set; } = "";
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
    [JsonPropertyName("signingKeyID")] public string SigningKeyID { get; set; } = "";
    [JsonPropertyName("protocols")] public ReleaseProtocols Protocols { get; set; } = new();
    [JsonPropertyName("artifact")] public ReleaseArtifact Artifact { get; set; } = new();
}

internal sealed class ReleaseProtocols
{
    [JsonPropertyName("deviceProtocolVersion")] public int DeviceProtocolVersion { get; set; }
    [JsonPropertyName("adminApiVersion")] public int AdminApiVersion { get; set; }
    [JsonPropertyName("stateSchemaCompatibility")] public ReleaseStateCompatibility StateSchemaCompatibility { get; set; } = new();
    [JsonPropertyName("recoveryLedgerVersion")] public int RecoveryLedgerVersion { get; set; }
}

internal sealed class ReleaseStateCompatibility
{
    [JsonPropertyName("minimumReadableStateSchemaVersion")] public int MinimumReadableStateSchemaVersion { get; set; }
    [JsonPropertyName("maximumReadableStateSchemaVersion")] public int MaximumReadableStateSchemaVersion { get; set; }
    [JsonPropertyName("writableStateSchemaVersion")] public int WritableStateSchemaVersion { get; set; }

    public bool IsCoherent =>
        MinimumReadableStateSchemaVersion >= 1 &&
        MinimumReadableStateSchemaVersion <= WritableStateSchemaVersion &&
        WritableStateSchemaVersion <= MaximumReadableStateSchemaVersion;

    public bool CanRead(int version) =>
        IsCoherent && version >= MinimumReadableStateSchemaVersion &&
        version <= MaximumReadableStateSchemaVersion;
}

internal sealed class ReleaseArtifact
{
    [JsonPropertyName("fileName")] public string FileName { get; set; } = "";
    [JsonPropertyName("operatingSystem")] public string OperatingSystem { get; set; } = "";
    [JsonPropertyName("architecture")] public string Architecture { get; set; } = "";
    [JsonPropertyName("size")] public long Size { get; set; }
    [JsonPropertyName("sha256")] public string Sha256 { get; set; } = "";
}

internal sealed class StageBeginResult
{
    [JsonPropertyName("uploadID")] public Guid UploadID { get; set; }
    [JsonPropertyName("uploadPath")] public string UploadPath { get; set; } = "";
    [JsonPropertyName("expiresAt")] public string ExpiresAt { get; set; } = "";
}

internal sealed class StageVerifyResult
{
    [JsonPropertyName("releaseID")] public string ReleaseID { get; set; } = "";
    [JsonPropertyName("artifactSHA256")] public string ArtifactSHA256 { get; set; } = "";
    [JsonPropertyName("staged")] public bool Staged { get; set; } = true;
}
