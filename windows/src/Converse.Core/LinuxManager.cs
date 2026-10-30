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
}

public sealed class LinuxDeployment
{
    [JsonPropertyName("deploymentID")] public Guid DeploymentID { get; set; } = Guid.NewGuid();
    [JsonPropertyName("displayName")] public string DisplayName { get; set; } = "Linux Home";
    [JsonPropertyName("ssh")] public LinuxDeploymentSsh Ssh { get; set; } = new();
    [JsonPropertyName("remote")] public LinuxDeploymentRemote Remote { get; set; } = new();
    [JsonPropertyName("converse")] public LinuxDeploymentConverse Converse { get; set; } = new();
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
    public static string Now() =>
        DateTimeOffset.UtcNow.UtcDateTime.ToString(
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
}

public sealed record LinuxProcessRequest(
    string FileName,
    IReadOnlyList<string> Arguments,
    string? StandardInput = null,
    bool RequestMayHaveBeenAccepted = false);

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
            if (request.StandardInput is not null)
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
    public const string BootstrapLock = "mkdir \"$HOME/.converse-bootstrap.lock\"";
    public const string BootstrapPreflight =
        "chmod 700 \"$HOME/.converse-bootstrap.bin\" && exec \"$HOME/.converse-bootstrap.bin\" preflight";
    public const string BootstrapInstall = "exec \"$HOME/.converse-bootstrap.bin\" install-self";
    public const string BootstrapCleanup =
        "rm -f \"$HOME/.converse-bootstrap.bin\"; rmdir \"$HOME/.converse-bootstrap.lock\"";
    public const string AdminRequest = "exec \"$HOME/.local/bin/converse\" admin-request";

    public static readonly IReadOnlyList<string> FixedRemoteCommands =
    [
        TrustProbe, BootstrapLock, BootstrapPreflight, BootstrapInstall,
        BootstrapCleanup, AdminRequest,
    ];

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
        if (!FixedRemoteCommands.Contains(fixedRemoteCommand))
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
        if (trustOnly && result.StandardOutput.Contains("Permanently added", StringComparison.Ordinal) &&
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
    [JsonPropertyName("bindingVersion")] public int BindingVersion { get; set; }
    [JsonPropertyName("pairingID")] public Guid PairingID { get; set; }
    [JsonPropertyName("role")] public string Role { get; set; } = "";
    [JsonPropertyName("state")] public string State { get; set; } = "";
    [JsonPropertyName("linuxDeviceID")] public string LinuxDeviceID { get; set; } = "";
    [JsonPropertyName("peerDeviceID")] public string PeerDeviceID { get; set; } = "";
    [JsonPropertyName("peerName")] public string PeerName { get; set; } = "";
    [JsonPropertyName("groupID")] public string GroupID { get; set; } = "";
    [JsonPropertyName("groupName")] public string? GroupName { get; set; }
    [JsonPropertyName("verificationCode")] public string? VerificationCode { get; set; }
    [JsonPropertyName("expiresAt")] public string? ExpiresAt { get; set; }
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
    [JsonPropertyName("updatedAt")] public string UpdatedAt { get; set; } = "";
}
