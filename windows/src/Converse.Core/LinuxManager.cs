using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Converse.Core;

// Shared GUI-side Linux deployment logic. The exact SSH argument arrays and
// remote command allowlist mirror docs/linux.md; platform apps own only the
// terminal/PTY presentation and dialogs around these calls.

public sealed class LinuxDeploymentRegistryFile
{
    [JsonPropertyName("registryVersion")] public int RegistryVersion { get; set; } = 1;
    [JsonPropertyName("deployments")] public List<LinuxDeployment> Deployments { get; set; } = new();
    [JsonPropertyName("provisionalDeployments")]
    public List<LinuxProvisionalDeployment> ProvisionalDeployments { get; set; } = new();
}

public sealed class LinuxProvisionalDeployment
{
    [JsonPropertyName("operationID")] public Guid OperationID { get; set; } = Guid.NewGuid();
    [JsonPropertyName("stagingToken")] public string StagingToken { get; set; } = "";
    [JsonPropertyName("stage")] public string Stage { get; set; } = "created";
    [JsonPropertyName("displayName")] public string DisplayName { get; set; } = "Linux Home";
    [JsonPropertyName("destination")] public string Destination { get; set; } = "";
    [JsonPropertyName("hostKeyFingerprintSHA256")] public string? HostKeyFingerprintSHA256 { get; set; }
    [JsonPropertyName("bootstrapSHA256")] public string? BootstrapSHA256 { get; set; }
    [JsonPropertyName("bootstrapSize")] public long BootstrapSize { get; set; }
    [JsonPropertyName("releaseID")] public string? ReleaseID { get; set; }
    [JsonPropertyName("deviceID")] public string? DeviceID { get; set; }
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = LinuxManagerTime.Now();
    [JsonPropertyName("updatedAt")] public string UpdatedAt { get; set; } = LinuxManagerTime.Now();
    [JsonPropertyName("expiresAt")] public string ExpiresAt { get; set; } =
        LinuxManagerTime.Format(DateTimeOffset.UtcNow.AddHours(24));
}

public sealed class LinuxDeploymentInstallation
{
    [JsonPropertyName("operationID")] public Guid? OperationID { get; set; }
    [JsonPropertyName("stagingToken")] public string? StagingToken { get; set; }
    [JsonPropertyName("completedAt")] public string? CompletedAt { get; set; }
}

public sealed class LinuxDeployment
{
    [JsonPropertyName("deploymentID")] public Guid DeploymentID { get; set; } = Guid.NewGuid();
    [JsonPropertyName("displayName")] public string DisplayName { get; set; } = "Linux Home";
    [JsonPropertyName("ssh")] public LinuxDeploymentSsh Ssh { get; set; } = new();
    [JsonPropertyName("remote")] public LinuxDeploymentRemote Remote { get; set; } = new();
    [JsonPropertyName("converse")] public LinuxDeploymentConverse Converse { get; set; } = new();
    [JsonPropertyName("installation")] public LinuxDeploymentInstallation Installation { get; set; } = new();
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = LinuxManagerTime.Now();
    [JsonPropertyName("updatedAt")] public string UpdatedAt { get; set; } = LinuxManagerTime.Now();
}

public sealed class LinuxDeploymentSsh
{
    [JsonPropertyName("destination")] public string Destination { get; set; } = "";
    [JsonPropertyName("hostKeyFingerprintSHA256")] public string HostKeyFingerprintSHA256 { get; set; } = "";
    [JsonPropertyName("proxyJump")] public string? ProxyJump { get; set; }
    [JsonPropertyName("lastVerifiedAt")] public string? LastVerifiedAt { get; set; }
}

public sealed class LinuxDeploymentRemote
{
    [JsonPropertyName("linuxUser")] public string LinuxUser { get; set; } = "";
    [JsonPropertyName("installRoot")] public string InstallRoot { get; set; } = "";
    [JsonPropertyName("stateRoot")] public string StateRoot { get; set; } = "";
    [JsonPropertyName("supervisor")] public string Supervisor { get; set; } = "none";
}

public sealed class LinuxDeploymentConverse
{
    [JsonPropertyName("deviceID")] public string? DeviceID { get; set; }
    [JsonPropertyName("groupID")] public string? GroupID { get; set; }
    [JsonPropertyName("groupName")] public string? GroupName { get; set; }
    [JsonPropertyName("lastKnownReleaseID")] public string? LastKnownReleaseID { get; set; }
    [JsonPropertyName("lastStatusAt")] public string? LastStatusAt { get; set; }
    [JsonPropertyName("capabilities")] public List<string> Capabilities { get; set; } = new();
}

internal static class LinuxManagerTime
{
    public static string Now() => Format(DateTimeOffset.UtcNow);

    public static string Format(DateTimeOffset value) =>
        value.UtcDateTime.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture);
}

public sealed class LinuxDeploymentRegistryStore
{
    private readonly string _file;

    public LinuxDeploymentRegistryStore(string folder)
    {
        Directory.CreateDirectory(folder);
        _file = Path.Combine(folder, "linux-deployments.json");
        Registry = Load();
    }

    public LinuxDeploymentRegistryFile Registry { get; }
    public IReadOnlyList<LinuxDeployment> Deployments => Registry.Deployments;

    public LinuxDeploymentRegistryFile Load()
    {
        if (!File.Exists(_file)) return new LinuxDeploymentRegistryFile();
        var loaded = JsonSerializer.Deserialize<LinuxDeploymentRegistryFile>(
            File.ReadAllBytes(_file)) ?? new LinuxDeploymentRegistryFile();
        if (loaded.RegistryVersion != 1)
            throw new InvalidDataException("Unsupported Linux deployment registry version.");
        return loaded;
    }

    public void Save()
    {
        Registry.Deployments = Registry.Deployments
            .OrderBy(deployment => deployment.DisplayName, StringComparer.OrdinalIgnoreCase)
            .ThenBy(deployment => deployment.Ssh.Destination, StringComparer.Ordinal)
            .ToList();
        AtomicJson.Write(_file, Registry);
    }

    public LinuxDeployment Upsert(LinuxDeployment deployment)
    {
        var existing = Registry.Deployments.FirstOrDefault(item =>
            item.DeploymentID == deployment.DeploymentID ||
            (item.Ssh.Destination == deployment.Ssh.Destination &&
             item.Converse.DeviceID is not null &&
             item.Converse.DeviceID == deployment.Converse.DeviceID));
        if (existing is null)
        {
            Registry.Deployments.Add(deployment);
            existing = deployment;
        }
        else
        {
            var created = existing.CreatedAt;
            existing.DisplayName = deployment.DisplayName;
            existing.Ssh = deployment.Ssh;
            existing.Remote = deployment.Remote;
            existing.Converse = deployment.Converse;
            existing.Installation = deployment.Installation;
            existing.CreatedAt = created;
        }
        existing.UpdatedAt = LinuxManagerTime.Now();
        Save();
        return existing;
    }

    public void Remove(Guid deploymentID)
    {
        Registry.Deployments.RemoveAll(item => item.DeploymentID == deploymentID);
        Save();
    }

    public IReadOnlyList<LinuxProvisionalDeployment> Provisionals =>
        Registry.ProvisionalDeployments;

    public LinuxProvisionalDeployment SaveProvisional(LinuxProvisionalDeployment provisional)
    {
        var existing = Registry.ProvisionalDeployments.FirstOrDefault(
            item => item.OperationID == provisional.OperationID);
        if (existing is null) Registry.ProvisionalDeployments.Add(provisional);
        else if (!ReferenceEquals(existing, provisional))
        {
            existing.StagingToken = provisional.StagingToken;
            existing.Stage = provisional.Stage;
            existing.DisplayName = provisional.DisplayName;
            existing.Destination = provisional.Destination;
            existing.HostKeyFingerprintSHA256 = provisional.HostKeyFingerprintSHA256;
            existing.BootstrapSHA256 = provisional.BootstrapSHA256;
            existing.BootstrapSize = provisional.BootstrapSize;
            existing.ReleaseID = provisional.ReleaseID;
            existing.DeviceID = provisional.DeviceID;
            existing.ExpiresAt = provisional.ExpiresAt;
            provisional = existing;
        }
        provisional.UpdatedAt = LinuxManagerTime.Now();
        Save();
        return provisional;
    }

    public void SetProvisionalStage(Guid operationID, string stage, string? deviceID = null)
    {
        var provisional = Registry.ProvisionalDeployments.FirstOrDefault(
            item => item.OperationID == operationID);
        if (provisional is null) return;
        provisional.Stage = stage;
        if (deviceID is not null) provisional.DeviceID = deviceID;
        provisional.UpdatedAt = LinuxManagerTime.Now();
        Save();
    }

    public void RemoveProvisional(Guid operationID)
    {
        Registry.ProvisionalDeployments.RemoveAll(item => item.OperationID == operationID);
        Save();
    }
}

public sealed record LinuxProcessRequest(
    string FileName,
    IReadOnlyList<string> Arguments,
    string? StandardInput = null,
    bool RequestMayHaveBeenAccepted = false,
    byte[]? StandardInputBytes = null);

public sealed record LinuxProcessResult(
    int ExitCode,
    string StandardOutput,
    string StandardError,
    bool ExecutableMissing = false);

public interface ILinuxProcessRunner
{
    Task<LinuxProcessResult> RunAsync(
        LinuxProcessRequest request, CancellationToken cancellationToken = default);
}

public sealed class SystemLinuxProcessRunner : ILinuxProcessRunner
{
    public async Task<LinuxProcessResult> RunAsync(
        LinuxProcessRequest request, CancellationToken cancellationToken = default)
    {
        var start = new ProcessStartInfo
        {
            FileName = request.FileName,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            StandardInputEncoding = Encoding.UTF8,
        };
        foreach (var argument in request.Arguments) start.ArgumentList.Add(argument);

        Process? process;
        try { process = Process.Start(start); }
        catch (System.ComponentModel.Win32Exception)
        {
            return new LinuxProcessResult(127, "", "", ExecutableMissing: true);
        }
        if (process is null) return new LinuxProcessResult(127, "", "", ExecutableMissing: true);

        using (process)
        using (cancellationToken.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { /* already gone */ }
        }))
        {
            var stdout = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var stderr = process.StandardError.ReadToEndAsync(cancellationToken);
            if (request.StandardInputBytes is not null)
                await process.StandardInput.BaseStream.WriteAsync(
                    request.StandardInputBytes, cancellationToken);
            else if (request.StandardInput is not null)
                await process.StandardInput.WriteAsync(request.StandardInput.AsMemory(), cancellationToken);
            process.StandardInput.Close();
            await process.WaitForExitAsync(cancellationToken);
            return new LinuxProcessResult(process.ExitCode, await stdout, await stderr);
        }
    }
}

public sealed record LinuxSshConfig(
    string Destination,
    string User,
    string HostName,
    string? HostKeyAlias,
    string? ProxyJump,
    IReadOnlyList<string> UserKnownHostsFiles);

public sealed record LinuxHostKeyInfo(string FingerprintSHA256, string KeyType);

public static class LinuxSshCommands
{
    public const string TrustProbe = "true";
    public const string BootstrapReceipt = "exec \"$HOME/.local/bin/converse\" bootstrap-receipt";
    public const string AdminRequest = "exec \"$HOME/.local/bin/converse\" admin-request";
    public const string SecretStdin = "exec \"$HOME/.local/bin/converse\" secret-stdin";
    public const string OfflineStatus = "exec \"$HOME/.local/bin/converse\" offline-status";
    public const string ServiceStart = "exec \"$HOME/.local/bin/converse\" service-start";
    public const string ServiceStop = "exec \"$HOME/.local/bin/converse\" service-stop";

    private static readonly Regex TokenPattern = new("^[A-Za-z0-9-]{32,64}$", RegexOptions.Compiled);

    public static readonly IReadOnlyList<string> FixedRemoteCommands =
    [
        TrustProbe, BootstrapReceipt, AdminRequest, SecretStdin,
        OfflineStatus, ServiceStart, ServiceStop,
    ];

    public static string NewBootstrapToken() => Guid.NewGuid().ToString("N");

    public static void ValidateBootstrapToken(string token)
    {
        if (!TokenPattern.IsMatch(token))
            throw new ArgumentException("Invalid bootstrap staging token.");
    }

    public static string BootstrapCreateStaging(string token)
    {
        ValidateBootstrapToken(token);
        return $"mkdir -p \"$HOME/.converse-bootstrap\" && mkdir \"$HOME/.converse-bootstrap/{token}\"";
    }

    public static string BootstrapPreflight(string token)
    {
        ValidateBootstrapToken(token);
        return $"chmod 700 \"$HOME/.converse-bootstrap/{token}/converse\" && exec \"$HOME/.converse-bootstrap/{token}/converse\" preflight";
    }

    public static string BootstrapInstall(string token)
    {
        ValidateBootstrapToken(token);
        return $"exec \"$HOME/.converse-bootstrap/{token}/converse\" install-self";
    }

    public static string BootstrapCleanup(string token)
    {
        ValidateBootstrapToken(token);
        return $"rm -rf \"$HOME/.converse-bootstrap/{token}\"";
    }

    public static string BootstrapRemoteTarget(string token)
    {
        ValidateBootstrapToken(token);
        return $".converse-bootstrap/{token}/converse";
    }

    public static bool IsFixedRemoteCommand(string command)
    {
        if (FixedRemoteCommands.Contains(command)) return true;
        var match = Regex.Match(command, "\\.converse-bootstrap/([A-Za-z0-9-]{32,64})");
        if (!match.Success) return false;
        var token = match.Groups[1].Value;
        return command == BootstrapCreateStaging(token) ||
            command == BootstrapPreflight(token) ||
            command == BootstrapInstall(token) ||
            command == BootstrapCleanup(token);
    }

    public static void ValidateDestination(string destination)
    {
        if (string.IsNullOrWhiteSpace(destination) ||
            Encoding.UTF8.GetByteCount(destination) > 255 ||
            destination.StartsWith('-') ||
            destination.Any(character => char.IsWhiteSpace(character) || char.IsControl(character)))
            throw new ArgumentException("Enter one SSH destination or config alias without spaces.");
    }

    public static string[] AutomatedSsh(string destination, string fixedRemoteCommand)
    {
        ValidateDestination(destination);
        if (!IsFixedRemoteCommand(fixedRemoteCommand))
            throw new ArgumentException("Remote command is not in the Linux allowlist.");
        return
        [
            "ssh",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "RequestTTY=no",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "--",
            destination,
            fixedRemoteCommand,
        ];
    }

    public static string[] AutomatedScp(
        string localPath, string destination, string remotePath)
    {
        ValidateDestination(destination);
        if (string.IsNullOrWhiteSpace(localPath) || string.IsNullOrWhiteSpace(remotePath) ||
            remotePath.Contains('\n') || remotePath.Contains('\r'))
            throw new ArgumentException("Invalid upload path.");
        return
        [
            "scp",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "--",
            localPath,
            destination + ":" + remotePath,
        ];
    }

    public static string[] TrustOnlySsh(string destination)
    {
        ValidateDestination(destination);
        return
        [
            "ssh",
            "-o", "BatchMode=no",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "RequestTTY=no",
            "-o", "PreferredAuthentications=none",
            "-o", "PubkeyAuthentication=no",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ClearAllForwardings=yes",
            "--",
            destination,
            TrustProbe,
        ];
    }

    public static string[] InteractiveSsh(string destination)
    {
        ValidateDestination(destination);
        return ["ssh", "--", destination];
    }

    public static string Classify(
        LinuxProcessResult result, bool requestMayHaveBeenAccepted = false, bool trustOnly = false)
    {
        if (result.ExecutableMissing) return "ssh_not_found";
        var stderr = result.StandardError;
        if (trustOnly &&
            (result.StandardOutput + stderr).Contains("Permanently added", StringComparison.Ordinal) &&
            stderr.Contains("Permission denied", StringComparison.Ordinal))
            return "trust_captured_verify_then_strict_preflight";
        if (result.ExitCode == 255)
        {
            if (stderr.Contains("REMOTE HOST IDENTIFICATION HAS CHANGED", StringComparison.Ordinal) ||
                stderr.Contains("Host key verification failed", StringComparison.Ordinal))
                return "ssh_host_key_changed";
            if (requestMayHaveBeenAccepted) return "ssh_disconnected_uncertain";
            if (stderr.Contains("Permission denied", StringComparison.Ordinal))
                return "ssh_auth_failed";
            return "ssh_unreachable";
        }
        return "process_completed";
    }
}

public sealed class LinuxAdminError
{
    [JsonPropertyName("code")] public string Code { get; set; } = "";
    [JsonPropertyName("message")] public string Message { get; set; } = "";
    [JsonPropertyName("retryable")] public bool Retryable { get; set; }
    [JsonPropertyName("uncertain")] public bool Uncertain { get; set; }
}

public sealed class LinuxAdminResponse
{
    [JsonPropertyName("adminApiVersion")] public int AdminApiVersion { get; set; }
    [JsonPropertyName("requestID")] public Guid RequestID { get; set; }
    [JsonPropertyName("ok")] public bool Ok { get; set; }
    [JsonPropertyName("result")] public JsonNode? Result { get; set; }
    [JsonPropertyName("operation")] public LinuxAdminOperation? Operation { get; set; }
    [JsonPropertyName("error")] public LinuxAdminError? Error { get; set; }
}

public sealed class LinuxAdminOperation
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
    public bool IsTerminal => State is "completed" or "aborted" or "failed";
}

public sealed record LinuxAdminCallResult(
    string Classification,
    LinuxAdminResponse? Response,
    LinuxProcessResult Process,
    Guid? OperationID = null)
{
    public bool Success => Response?.Ok == true;
    public string Message => Response?.Error?.Message ??
        (Classification switch
        {
            "ssh_not_found" => "OpenSSH was not found.",
            "ssh_host_key_changed" => "The SSH host key changed. Setup stopped.",
            "ssh_auth_failed" => "SSH key or agent authentication failed.",
            "ssh_unreachable" => "The Linux computer could not be reached over SSH.",
            "ssh_disconnected_uncertain" => "SSH disconnected after the request may have been accepted. Check the operation instead of retrying it.",
            "ssh_protocol_error" => "The Linux admin response was not valid.",
            _ => Process.StandardError.Trim(),
        });
}

public sealed class LinuxStatusSnapshot
{
    public string ProductVersion { get; init; } = "";
    public int Build { get; init; }
    public string? DeviceID { get; init; }
    public string DeviceName { get; init; } = "";
    public string ProcessState { get; init; } = "";
    public string Supervisor { get; init; } = "none";
    public bool DesiredRunning { get; init; } = true;
    public string Admission { get; init; } = "";
    public string? InstallRoot { get; init; }
    public string? StateRoot { get; init; }
    public string? ConfigRoot { get; init; }
    public string? DataRoot { get; init; }
    public string? GroupID { get; init; }
    public string? GroupName { get; init; }
    public int PeerCount { get; init; }
    public int ConnectedPeerCount { get; init; }
    public int SessionCount { get; init; }
    public int ActiveTurnCount { get; init; }
    public int AgentCount { get; init; }
    public string? CurrentReleaseID { get; init; }
    public string? PreviousReleaseID { get; init; }
    public string? StagedReleaseID { get; init; }
    public Guid? UpdateEpisodeID { get; init; }
    public string? UpdatePhase { get; init; }
    public List<string> ConfiguredSecrets { get; init; } = new();
    public List<string> Capabilities { get; init; } = new();

    public static LinuxStatusSnapshot Parse(JsonNode? node)
    {
        if (node is not JsonObject root) throw new InvalidDataException("Missing Linux status.");
        var device = Obj(root, "device");
        var runtime = Obj(root, "runtime");
        var filesystem = Obj(root, "filesystem");
        var fabric = Obj(root, "fabric");
        var work = Obj(root, "work");
        var release = Obj(root, "release");
        var episode = release?["updateEpisode"] as JsonObject;
        return new LinuxStatusSnapshot
        {
            ProductVersion = Text(root, "productVersion") ?? "",
            Build = Int(root, "build"),
            DeviceID = Text(device, "deviceID"),
            DeviceName = Text(device, "name") ?? "",
            ProcessState = Text(runtime, "processState") ?? "",
            Supervisor = Text(runtime, "supervisor") ?? "none",
            DesiredRunning = runtime?["desiredRunning"]?.GetValueKind() != JsonValueKind.False,
            Admission = Text(runtime, "admission") ?? "",
            InstallRoot = Text(filesystem, "installRoot"),
            StateRoot = Text(filesystem, "stateRoot"),
            ConfigRoot = Text(filesystem, "configRoot"),
            DataRoot = Text(filesystem, "dataRoot"),
            GroupID = Text(fabric, "groupID"),
            GroupName = Text(fabric, "groupName"),
            PeerCount = Int(fabric, "peerCount"),
            ConnectedPeerCount = Int(fabric, "connectedPeerCount"),
            SessionCount = Int(work, "sessionCount"),
            ActiveTurnCount = Int(work, "activeTurnCount"),
            AgentCount = Int(work, "agentCount"),
            CurrentReleaseID = Text(release, "currentReleaseID"),
            PreviousReleaseID = Text(release, "previousReleaseID"),
            StagedReleaseID = Text(release, "stagedReleaseID"),
            UpdateEpisodeID = Guid.TryParse(Text(episode, "episodeID"), out var episodeID) ? episodeID : null,
            UpdatePhase = Text(episode, "phase"),
            ConfiguredSecrets = (root["secrets"] as JsonArray)?
                .OfType<JsonObject>()
                .Where(secret => secret["configured"]?.GetValue<bool>() == true)
                .Select(secret => Text(secret, "secretID") ?? "")
                .Where(id => id.Length > 0)
                .ToList() ?? new List<string>(),
            Capabilities = (root["capabilities"] as JsonArray)?
                .Select(capability => capability?.GetValue<string>() ?? "")
                .Where(capability => capability.Length > 0)
                .ToList() ?? new List<string>(),
        };
    }

    private static JsonObject? Obj(JsonObject? root, string name) => root?[name] as JsonObject;
    private static string? Text(JsonObject? root, string name) =>
        root?[name]?.GetValueKind() == JsonValueKind.String ? root[name]!.GetValue<string>() : null;
    private static int Int(JsonObject? root, string name) =>
        root?[name]?.GetValueKind() == JsonValueKind.Number ? root[name]!.GetValue<int>() : 0;
}

public sealed class LinuxPairingBinding
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
    [JsonPropertyName("expiresAt")] public string? ExpiresAt { get; set; }
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
    [JsonPropertyName("updatedAt")] public string UpdatedAt { get; set; } = "";

    [JsonIgnore]
    public string PeerDeviceID => Role == "joiner" ? SponsorDeviceID : RequesterDeviceID;
}

public sealed class LinuxSecretReceipt
{
    [JsonPropertyName("operationID")] public Guid OperationID { get; set; }
    [JsonPropertyName("secretID")] public string SecretID { get; set; } = "";
    [JsonPropertyName("kind")] public string Kind { get; set; } = "other";
    [JsonPropertyName("backend")] public string Backend { get; set; } = "";
    [JsonPropertyName("configured")] public bool Configured { get; set; }
    [JsonPropertyName("storedVersion")] public long StoredVersion { get; set; }
    [JsonPropertyName("effectiveVersion")] public long EffectiveVersion { get; set; }
    [JsonPropertyName("pendingRestart")] public bool PendingRestart { get; set; }
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }
}

public sealed class LinuxSecretResponse
{
    [JsonPropertyName("secretApiVersion")] public int SecretApiVersion { get; set; }
    [JsonPropertyName("requestID")] public Guid RequestID { get; set; }
    [JsonPropertyName("ok")] public bool Ok { get; set; }
    [JsonPropertyName("receipt")] public LinuxSecretReceipt? Receipt { get; set; }
    [JsonPropertyName("error")] public LinuxAdminError? Error { get; set; }
}

public sealed record LinuxSecretCallResult(
    string Classification,
    LinuxSecretResponse? Response,
    LinuxProcessResult Process,
    Guid? OperationID = null)
{
    public bool Success => Response?.Ok == true;
    public string Message => Response?.Error?.Message ??
        (Classification switch
        {
            "ssh_not_found" => "OpenSSH was not found.",
            "ssh_host_key_changed" => "The SSH host key changed. Setup stopped.",
            "ssh_auth_failed" => "SSH key or agent authentication failed.",
            "ssh_unreachable" => "The Linux computer could not be reached over SSH.",
            "ssh_disconnected_uncertain" => "SSH disconnected after the secret request may have been accepted. Check the operation instead of resending with a new ID.",
            "ssh_protocol_error" => "The Linux secret response was not valid.",
            _ => Process.StandardError.Trim(),
        });
}

public sealed record LinuxSessionCreateInput(
    Guid SessionID,
    string Engine,
    string? Title = null,
    Guid? EntryID = null,
    string? EntryName = null,
    string? WorkingDirectory = null,
    string? Model = null,
    string? Effort = null,
    string? Access = null,
    bool MessagingEnabled = false);

public sealed class LinuxSessionCreateResult
{
    [JsonPropertyName("sessionID")] public Guid SessionID { get; set; }
    [JsonPropertyName("globalID")] public string GlobalID { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("engine")] public string Engine { get; set; } = "";
}

public sealed class LinuxBootstrapReceipt
{
    [JsonPropertyName("receiptVersion")] public int ReceiptVersion { get; set; }
    [JsonPropertyName("operationID")] public Guid OperationID { get; set; }
    [JsonPropertyName("stagingToken")] public string StagingToken { get; set; } = "";
    [JsonPropertyName("deviceID")] public string DeviceID { get; set; } = "";
    [JsonPropertyName("releaseID")] public string ReleaseID { get; set; } = "";
    [JsonPropertyName("sourceSHA256")] public string SourceSHA256 { get; set; } = "";
    [JsonPropertyName("supervisor")] public string Supervisor { get; set; } = "";
    [JsonPropertyName("completedAt")] public string CompletedAt { get; set; } = "";
}
