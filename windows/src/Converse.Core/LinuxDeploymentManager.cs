using System.Formats.Tar;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Converse.Core;

public sealed record LinuxManagerResult<T>(
    bool Success,
    string Classification,
    string Message,
    T? Value = default,
    Guid? OperationID = null);

public sealed class LinuxDeploymentManager
{
    private static readonly Regex UploadToken = new("^[A-Za-z0-9-]{32,64}$", RegexOptions.Compiled);
    private static readonly HashSet<string> MutatingOperations = new(StringComparer.Ordinal)
    {
        "group.create", "pairing.join.begin", "pairing.join.confirm", "pairing.join.cancel",
        "pairing.request.approve", "pairing.request.reject", "update.stage.begin",
        "update.stage.verify", "update.activate", "update.healthCommit", "update.rollback",
        "service.restart", "secret.set", "secret.delete",
    };

    private readonly ILinuxProcessRunner _runner;

    public LinuxDeploymentManager(
        LinuxDeploymentRegistryStore registryStore,
        ILinuxProcessRunner? runner = null)
    {
        RegistryStore = registryStore;
        _runner = runner ?? new SystemLinuxProcessRunner();
    }

    public LinuxDeploymentRegistryStore RegistryStore { get; }
    public IReadOnlyList<LinuxDeployment> Deployments => RegistryStore.Deployments;

    public async Task<LinuxSshConfig?> ResolveSshConfigAsync(
        string destination, CancellationToken cancellationToken = default)
    {
        LinuxSshCommands.ValidateDestination(destination);
        var result = await _runner.RunAsync(
            new LinuxProcessRequest("ssh", ["-G", destination]), cancellationToken);
        if (result.ExecutableMissing || result.ExitCode != 0) return null;
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var rawLine in result.StandardOutput.Split('\n'))
        {
            var line = rawLine.Trim();
            var separator = line.IndexOf(' ');
            if (separator <= 0) continue;
            values[line[..separator]] = line[(separator + 1)..].Trim();
        }
        string? Value(string key) => values.TryGetValue(key, out var value) && value.Length > 0 ? value : null;
        var proxy = Value("proxyjump");
        var files = (Value("userknownhostsfile") ?? "~/.ssh/known_hosts")
            .Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(ExpandHome)
            .ToList();
        return new LinuxSshConfig(
            destination,
            Value("user") ?? "",
            Value("hostname") ?? destination,
            Value("hostkeyalias"),
            proxy is null || proxy == "none" ? null : proxy,
            files);
    }

    public async Task<LinuxHostKeyInfo?> VerifyInstalledHostKeyAsync(
        string destination, CancellationToken cancellationToken = default)
    {
        var config = await ResolveSshConfigAsync(destination, cancellationToken);
        if (config is null) return null;
        var candidates = new[] { config.HostKeyAlias, config.HostName, destination }
            .Where(candidate => !string.IsNullOrWhiteSpace(candidate))
            .Select(candidate => candidate!)
            .Distinct(StringComparer.OrdinalIgnoreCase);
        foreach (var file in config.UserKnownHostsFiles)
        {
            if (!File.Exists(file)) continue;
            foreach (var candidate in candidates)
            {
                var result = await _runner.RunAsync(
                    new LinuxProcessRequest("ssh-keygen", ["-F", candidate, "-f", file]),
                    cancellationToken);
                if (result.ExitCode != 0) continue;
                foreach (var rawLine in result.StandardOutput.Split('\n'))
                {
                    var line = rawLine.Trim();
                    if (line.Length == 0 || line.StartsWith('#')) continue;
                    var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length < 3) continue;
                    try
                    {
                        var digest = SHA256.HashData(Convert.FromBase64String(parts[2]));
                        var fingerprint = "SHA256:" + Convert.ToBase64String(digest).TrimEnd('=');
                        return new LinuxHostKeyInfo(fingerprint, parts[1]);
                    }
                    catch { /* Try the next known-hosts entry. */ }
                }
            }
        }
        return null;
    }

    public async Task<LinuxAdminCallResult> AdminAsync(
        string destination,
        string operation,
        JsonObject? payload = null,
        string? expectedDeviceID = null,
        Guid? operationID = null,
        CancellationToken cancellationToken = default)
    {
        LinuxSshCommands.ValidateDestination(destination);
        var requestID = Guid.NewGuid();
        var request = new JsonObject
        {
            ["adminApiVersion"] = 1,
            ["requestID"] = requestID.ToString("D"),
            ["operation"] = operation,
            ["expectedDeviceID"] = expectedDeviceID,
            ["operationID"] = operationID?.ToString("D"),
            ["payload"] = payload ?? new JsonObject(),
        };
        var mayHaveBeenAccepted = MutatingOperations.Contains(operation);
        var argv = LinuxSshCommands.AutomatedSsh(destination, LinuxSshCommands.AdminRequest);
        var process = await _runner.RunAsync(new LinuxProcessRequest(
            argv[0], argv.Skip(1).ToArray(), request.ToJsonString() + "\n", mayHaveBeenAccepted),
            cancellationToken);

        if (process.ExecutableMissing)
            return new LinuxAdminCallResult("ssh_not_found", null, process, operationID);
        if (process.ExitCode == 255)
        {
            return new LinuxAdminCallResult(
                LinuxSshCommands.Classify(process, mayHaveBeenAccepted), null, process, operationID);
        }

        LinuxAdminResponse? response = null;
        var line = process.StandardOutput.Trim();
        if (line.Length > 0 && !line.Contains('\n'))
        {
            try { response = JsonSerializer.Deserialize<LinuxAdminResponse>(line); }
            catch { /* Protocol error below. */ }
        }
        if (response is null || response.AdminApiVersion != 1 || response.RequestID != requestID)
        {
            return new LinuxAdminCallResult(
                mayHaveBeenAccepted && process.ExitCode != 0
                    ? "ssh_disconnected_uncertain" : "ssh_protocol_error",
                null, process, operationID);
        }
        return new LinuxAdminCallResult("admin_response", response, process, operationID);
    }

    public Task<LinuxAdminCallResult> AdminAsync(
        LinuxDeployment deployment,
        string operation,
        JsonObject? payload = null,
        Guid? operationID = null,
        CancellationToken cancellationToken = default) =>
        AdminAsync(
            deployment.Ssh.Destination, operation, payload,
            deployment.Converse.DeviceID, operationID, cancellationToken);

    public async Task<LinuxManagerResult<LinuxStatusSnapshot>> GetStatusAsync(
        LinuxDeployment deployment, bool save = true,
        CancellationToken cancellationToken = default)
    {
        var call = await AdminAsync(deployment, "status.get", cancellationToken: cancellationToken);
        if (!call.Success) return Failure<LinuxStatusSnapshot>(call);
        try
        {
            var status = LinuxStatusSnapshot.Parse(call.Response!.Result);
            if (save) await SaveStatusAsync(deployment, status, cancellationToken);
            return new LinuxManagerResult<LinuxStatusSnapshot>(true, call.Classification, "", status);
        }
        catch (Exception error)
        {
            return new LinuxManagerResult<LinuxStatusSnapshot>(
                false, "ssh_protocol_error", error.Message);
        }
    }

    public async Task<LinuxManagerResult<LinuxStatusSnapshot>> StrictStatusAsync(
        string destination, CancellationToken cancellationToken = default)
    {
        var call = await AdminAsync(destination, "status.get", cancellationToken: cancellationToken);
        if (!call.Success) return Failure<LinuxStatusSnapshot>(call);
        try
        {
            return new LinuxManagerResult<LinuxStatusSnapshot>(
                true, call.Classification, "", LinuxStatusSnapshot.Parse(call.Response!.Result));
        }
        catch (Exception error)
        {
            return new LinuxManagerResult<LinuxStatusSnapshot>(
                false, "ssh_protocol_error", error.Message);
        }
    }

    public async Task<LinuxManagerResult<LinuxDeployment>> BootstrapAsync(
        string destination,
        string displayName,
        string bootstrapExecutable,
        Action<string>? progress = null,
        CancellationToken cancellationToken = default)
    {
        LinuxSshCommands.ValidateDestination(destination);
        if (!File.Exists(bootstrapExecutable))
            return new LinuxManagerResult<LinuxDeployment>(
                false, "invalid_request", "Choose the published Linux converse executable first.");

        progress?.Invoke("Verifying the installed SSH host key…");
        var hostKey = await VerifyInstalledHostKeyAsync(destination, cancellationToken);
        if (hostKey is null)
        {
            return new LinuxManagerResult<LinuxDeployment>(
                false, "ssh_host_untrusted",
                "No approved SSH host key was found. Use Open SSH Terminal, compare the full fingerprint, then retry.");
        }
        var config = await ResolveSshConfigAsync(destination, cancellationToken);
        if (config is null)
            return new LinuxManagerResult<LinuxDeployment>(
                false, "ssh_not_found", "OpenSSH configuration could not be read.");

        progress?.Invoke("Reserving the bootstrap path…");
        var locked = await RemoteCommandAsync(
            destination, LinuxSshCommands.BootstrapLock, cancellationToken);
        if (locked.ExitCode != 0)
            return ProcessFailure<LinuxDeployment>(locked, "Another bootstrap may be in progress, or a stale bootstrap lock needs explicit cleanup.");

        var installed = false;
        try
        {
            progress?.Invoke("Uploading the Linux executable…");
            var uploaded = await ScpAsync(
                bootstrapExecutable, destination, ".converse-bootstrap.bin", cancellationToken);
            if (uploaded.ExitCode != 0) return ProcessFailure<LinuxDeployment>(uploaded);

            progress?.Invoke("Running strict preflight…");
            var preflightProcess = await RemoteCommandAsync(
                destination, LinuxSshCommands.BootstrapPreflight, cancellationToken);
            if (preflightProcess.ExitCode != 0)
                return ProcessFailure<LinuxDeployment>(preflightProcess);
            var preflight = ParseStatusLine(preflightProcess.StandardOutput);
            if (preflight is null)
            {
                return new LinuxManagerResult<LinuxDeployment>(
                    false, "ssh_protocol_error", "Bootstrap preflight did not return a valid status.");
            }

            progress?.Invoke("Installing the Linux home…");
            var installProcess = await RemoteCommandAsync(
                destination, LinuxSshCommands.BootstrapInstall, cancellationToken);
            if (installProcess.ExitCode != 0)
                return ProcessFailure<LinuxDeployment>(installProcess);
            var installStatus = ParseStatusLine(installProcess.StandardOutput);
            if (installStatus?.DeviceID is null)
            {
                return new LinuxManagerResult<LinuxDeployment>(
                    false, "ssh_protocol_error", "Installation did not return a Converse identity.");
            }
            installed = true;

            progress?.Invoke("Checking the running daemon…");
            LinuxStatusSnapshot status = installStatus;
            for (var attempt = 0; attempt < 12; attempt++)
            {
                var live = await StrictStatusAsync(destination, cancellationToken);
                if (live.Success && live.Value is not null)
                {
                    if (live.Value.DeviceID != installStatus.DeviceID)
                    {
                        return new LinuxManagerResult<LinuxDeployment>(
                            false, "identity_mismatch",
                            "The running Linux home identity differs from the installer identity.");
                    }
                    status = live.Value;
                    break;
                }
                await Task.Delay(250, cancellationToken);
            }

            var existing = Deployments.FirstOrDefault(item =>
                item.Ssh.Destination == destination && item.Converse.DeviceID == status.DeviceID);
            var deployment = existing ?? new LinuxDeployment();
            deployment.DisplayName = string.IsNullOrWhiteSpace(displayName) ? status.DeviceName : displayName.Trim();
            deployment.Ssh = new LinuxDeploymentSsh
            {
                Destination = destination,
                HostKeyFingerprintSHA256 = hostKey.FingerprintSHA256,
                ProxyJump = config.ProxyJump,
                LastVerifiedAt = LinuxManagerTime.Now(),
            };
            deployment.Remote = new LinuxDeploymentRemote
            {
                LinuxUser = config.User,
                InstallRoot = status.InstallRoot ?? "",
                StateRoot = status.StateRoot ?? "",
                Supervisor = status.Supervisor,
            };
            deployment.Converse = new LinuxDeploymentConverse
            {
                DeviceID = status.DeviceID,
                GroupID = status.GroupID,
                GroupName = status.GroupName,
                LastKnownReleaseID = status.CurrentReleaseID,
                LastStatusAt = LinuxManagerTime.Now(),
                Capabilities = status.Capabilities,
            };
            RegistryStore.Upsert(deployment);
            return new LinuxManagerResult<LinuxDeployment>(true, "admin_response", "", deployment);
        }
        finally
        {
            // If install-self was accepted, protocol errors are not safe proof
            // that deleting the bootstrap binary/lock is appropriate. Only a
            // completed deployment record above reaches this path with
            // installed=true; earlier failures also need their lock removed
            // before another attempt. Cleanup itself is best-effort.
            try
            {
                await RemoteCommandAsync(
                    destination, LinuxSshCommands.BootstrapCleanup, CancellationToken.None);
            }
            catch { /* The next attempt reports a stale lock explicitly. */ }
            _ = installed;
        }
    }

    public async Task<LinuxManagerResult<LinuxPairingBinding>> BeginJoinAsync(
        LinuxDeployment deployment, string sponsorDeviceID, string sponsorHost, int sponsorPort,
        string groupID, CancellationToken cancellationToken = default)
    {
        var payload = new JsonObject
        {
            ["sponsorDeviceID"] = sponsorDeviceID,
            ["sponsorEndpoint"] = new JsonObject { ["host"] = sponsorHost, ["port"] = sponsorPort },
            ["groupID"] = groupID,
        };
        return await PairingCallAsync(
            deployment, "pairing.join.begin", payload, cancellationToken);
    }

    public Task<LinuxManagerResult<LinuxPairingBinding>> JoinStatusAsync(
        LinuxDeployment deployment, Guid pairingID, CancellationToken cancellationToken = default) =>
        PairingCallAsync(deployment, "pairing.join.status", PairingPayload(pairingID), cancellationToken);

    public Task<LinuxManagerResult<LinuxPairingBinding>> ConfirmJoinAsync(
        LinuxDeployment deployment, Guid pairingID, CancellationToken cancellationToken = default) =>
        PairingCallAsync(deployment, "pairing.join.confirm", PairingPayload(pairingID), cancellationToken);

    public Task<LinuxManagerResult<LinuxPairingBinding>> CancelJoinAsync(
        LinuxDeployment deployment, Guid pairingID, CancellationToken cancellationToken = default) =>
        PairingCallAsync(deployment, "pairing.join.cancel", PairingPayload(pairingID), cancellationToken);

    public async Task<LinuxManagerResult<List<LinuxPairingBinding>>> ListPairingRequestsAsync(
        LinuxDeployment deployment, CancellationToken cancellationToken = default)
    {
        var call = await AdminAsync(deployment, "pairing.requests.list", cancellationToken: cancellationToken);
        if (!call.Success) return Failure<List<LinuxPairingBinding>>(call);
        try
        {
            var array = call.Response!.Result?["requests"] as JsonArray ?? new JsonArray();
            var bindings = array.Select(node =>
                JsonSerializer.Deserialize<LinuxPairingBinding>(node!.ToJsonString())!).ToList();
            return new LinuxManagerResult<List<LinuxPairingBinding>>(true, call.Classification, "", bindings);
        }
        catch (Exception error)
        {
            return new LinuxManagerResult<List<LinuxPairingBinding>>(
                false, "ssh_protocol_error", error.Message);
        }
    }

    public Task<LinuxManagerResult<LinuxPairingBinding>> ReviewRequestAsync(
        LinuxDeployment deployment, Guid pairingID, CancellationToken cancellationToken = default) =>
        PairingCallAsync(deployment, "pairing.request.review", PairingPayload(pairingID), cancellationToken);

    public Task<LinuxManagerResult<LinuxPairingBinding>> ApproveRequestAsync(
        LinuxDeployment deployment, Guid pairingID, CancellationToken cancellationToken = default) =>
        PairingCallAsync(deployment, "pairing.request.approve", PairingPayload(pairingID), cancellationToken);

    public Task<LinuxManagerResult<LinuxPairingBinding>> RejectRequestAsync(
        LinuxDeployment deployment, Guid pairingID, CancellationToken cancellationToken = default) =>
        PairingCallAsync(deployment, "pairing.request.reject", PairingPayload(pairingID), cancellationToken);

    public async Task<LinuxManagerResult<LinuxStatusSnapshot>> CreateGroupAsync(
        LinuxDeployment deployment, string name, CancellationToken cancellationToken = default)
    {
        var call = await AdminAsync(
            deployment, "group.create",
            new JsonObject { ["name"] = name }, cancellationToken: cancellationToken);
        if (!call.Success) return Failure<LinuxStatusSnapshot>(call);
        var status = LinuxStatusSnapshot.Parse(call.Response!.Result);
        await SaveStatusAsync(deployment, status, cancellationToken);
        return new LinuxManagerResult<LinuxStatusSnapshot>(true, call.Classification, "", status);
    }

    public async Task<LinuxManagerResult<Guid>> StageUpdateAsync(
        LinuxDeployment deployment, string bundlePath, string? releaseID = null,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(bundlePath))
            return new LinuxManagerResult<Guid>(false, "invalid_request", "Choose a signed Linux release bundle.");
        releaseID ??= ReadBundleReleaseID(bundlePath);
        if (string.IsNullOrWhiteSpace(releaseID))
            return new LinuxManagerResult<Guid>(false, "invalid_request", "Enter the release ID from the signed bundle.");

        var statusResult = await GetStatusAsync(deployment, cancellationToken: cancellationToken);
        if (!statusResult.Success) return new LinuxManagerResult<Guid>(
            false, statusResult.Classification, statusResult.Message);
        var status = statusResult.Value!;
        var file = new FileInfo(bundlePath);
        var hash = await HashFileAsync(bundlePath, cancellationToken);
        var begin = await AdminAsync(deployment, "update.stage.begin", new JsonObject
        {
            ["releaseID"] = releaseID,
            ["bundleSHA256"] = hash,
            ["bundleSize"] = file.Length,
        }, cancellationToken: cancellationToken);
        if (!begin.Success) return Failure<Guid>(begin);

        var result = begin.Response!.Result as JsonObject;
        var uploadIDText = result?["uploadID"]?.GetValue<string>();
        var uploadPath = result?["uploadPath"]?.GetValue<string>();
        if (!Guid.TryParse(uploadIDText, out var uploadID) ||
            !ValidateUploadPath(status.StateRoot, uploadPath))
        {
            return new LinuxManagerResult<Guid>(
                false, "ssh_protocol_error", "The Linux home returned an unsafe upload path.");
        }

        var upload = await ScpAsync(bundlePath, deployment.Ssh.Destination, uploadPath!, cancellationToken);
        if (upload.ExitCode != 0) return ProcessFailure<Guid>(upload);

        var verify = await AdminAsync(deployment, "update.stage.verify", new JsonObject
        {
            ["uploadID"] = uploadID.ToString("D"),
        }, cancellationToken: cancellationToken);
        if (!verify.Success) return Failure<Guid>(verify);
        return new LinuxManagerResult<Guid>(true, verify.Classification, "", uploadID);
    }

    public async Task<LinuxManagerResult<LinuxAdminOperation>> ActivateUpdateAsync(
        LinuxDeployment deployment, string releaseID, int drainTimeoutSeconds = 600,
        Guid? operationID = null, CancellationToken cancellationToken = default)
    {
        operationID ??= Guid.NewGuid();
        var call = await AdminAsync(deployment, "update.activate", new JsonObject
        {
            ["releaseID"] = releaseID,
            ["drainTimeoutSeconds"] = drainTimeoutSeconds,
        }, operationID, cancellationToken);
        return OperationResult(call, operationID.Value);
    }

    public async Task<LinuxManagerResult<LinuxAdminOperation>> PollOperationAsync(
        LinuxDeployment deployment, Guid operationID,
        bool stopAtProbation = false, int timeoutSeconds = 120,
        CancellationToken cancellationToken = default)
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(timeoutSeconds);
        while (true)
        {
            var call = await AdminAsync(deployment, "operation.get", new JsonObject
            {
                ["operationID"] = operationID.ToString("D"),
            }, cancellationToken: cancellationToken);
            var result = OperationResult(call, operationID);
            if (!result.Success) return result;
            var operation = result.Value!;
            if (operation.IsTerminal || (stopAtProbation && operation.State == "probation_new_release"))
                return result;
            if (DateTimeOffset.UtcNow >= deadline) return result;
            await Task.Delay(500, cancellationToken);
        }
    }

    public async Task<LinuxManagerResult<LinuxAdminOperation>> HealthCommitAsync(
        LinuxDeployment deployment, Guid episodeID, Guid? operationID = null,
        CancellationToken cancellationToken = default)
    {
        operationID ??= Guid.NewGuid();
        var call = await AdminAsync(deployment, "update.healthCommit", new JsonObject
        {
            ["episodeID"] = episodeID.ToString("D"),
        }, operationID, cancellationToken);
        return OperationResult(call, operationID.Value);
    }

    public async Task<LinuxManagerResult<LinuxAdminOperation>> RollbackAsync(
        LinuxDeployment deployment, Guid episodeID, string reason, Guid? operationID = null,
        CancellationToken cancellationToken = default)
    {
        operationID ??= Guid.NewGuid();
        var call = await AdminAsync(deployment, "update.rollback", new JsonObject
        {
            ["episodeID"] = episodeID.ToString("D"),
            ["reason"] = reason,
        }, operationID, cancellationToken);
        return OperationResult(call, operationID.Value);
    }

    public async Task<LinuxManagerResult<LinuxAdminOperation>> RestartAsync(
        LinuxDeployment deployment, Guid? operationID = null,
        CancellationToken cancellationToken = default)
    {
        operationID ??= Guid.NewGuid();
        var call = await AdminAsync(
            deployment, "service.restart", new JsonObject(), operationID, cancellationToken);
        return OperationResult(call, operationID.Value);
    }

    public async Task<LinuxManagerResult<bool>> SetSecretAsync(
        LinuxDeployment deployment, string secretID, string kind, string value,
        CancellationToken cancellationToken = default)
    {
        var call = await AdminAsync(deployment, "secret.set", new JsonObject
        {
            ["secretID"] = secretID,
            ["kind"] = kind,
            ["value"] = value,
        }, cancellationToken: cancellationToken);
        return call.Success
            ? new LinuxManagerResult<bool>(true, call.Classification, "", true)
            : Failure<bool>(call);
    }

    public async Task<LinuxManagerResult<bool>> DeleteSecretAsync(
        LinuxDeployment deployment, string secretID, CancellationToken cancellationToken = default)
    {
        var call = await AdminAsync(deployment, "secret.delete", new JsonObject
        {
            ["secretID"] = secretID,
        }, cancellationToken: cancellationToken);
        return call.Success
            ? new LinuxManagerResult<bool>(true, call.Classification, "", true)
            : Failure<bool>(call);
    }

    public static bool ValidateUploadPath(string? stateRoot, string? uploadPath)
    {
        if (string.IsNullOrWhiteSpace(stateRoot) || string.IsNullOrWhiteSpace(uploadPath)) return false;
        var prefix = stateRoot.TrimEnd('/') + "/incoming/";
        if (!uploadPath.StartsWith(prefix, StringComparison.Ordinal)) return false;
        var file = uploadPath[prefix.Length..];
        if (!file.EndsWith(".tar.gz", StringComparison.Ordinal)) return false;
        var token = file[..^".tar.gz".Length];
        return UploadToken.IsMatch(token);
    }

    public static string? ReadBundleReleaseID(string bundlePath)
    {
        try
        {
            using var file = File.OpenRead(bundlePath);
            using var gzip = new GZipStream(file, CompressionMode.Decompress);
            using var tar = new TarReader(gzip);
            while (tar.GetNextEntry(copyData: false) is { } entry)
            {
                var name = entry.Name.Trim();
                if (name.StartsWith("./", StringComparison.Ordinal)) name = name[2..];
                if (name != "manifest.json" || entry.DataStream is null) continue;
                using var document = JsonDocument.Parse(entry.DataStream);
                return document.RootElement.GetProperty("releaseID").GetString();
            }
        }
        catch { /* The daemon remains the signature/hash authority. */ }
        return null;
    }

    private async Task SaveStatusAsync(
        LinuxDeployment deployment, LinuxStatusSnapshot status,
        CancellationToken cancellationToken)
    {
        deployment.Converse.DeviceID = status.DeviceID;
        deployment.Converse.GroupID = status.GroupID;
        deployment.Converse.GroupName = status.GroupName;
        deployment.Converse.LastKnownReleaseID = status.CurrentReleaseID;
        deployment.Converse.LastStatusAt = LinuxManagerTime.Now();
        deployment.Converse.Capabilities = status.Capabilities;
        if (!string.IsNullOrWhiteSpace(status.InstallRoot))
            deployment.Remote.InstallRoot = status.InstallRoot;
        if (!string.IsNullOrWhiteSpace(status.StateRoot))
            deployment.Remote.StateRoot = status.StateRoot;
        deployment.Remote.Supervisor = status.Supervisor;
        if (await ResolveSshConfigAsync(deployment.Ssh.Destination, cancellationToken) is { } config)
        {
            if (config.User.Length > 0) deployment.Remote.LinuxUser = config.User;
            deployment.Ssh.ProxyJump = config.ProxyJump;
        }
        var hostKey = await VerifyInstalledHostKeyAsync(deployment.Ssh.Destination, cancellationToken);
        if (hostKey is not null)
        {
            deployment.Ssh.HostKeyFingerprintSHA256 = hostKey.FingerprintSHA256;
            deployment.Ssh.LastVerifiedAt = LinuxManagerTime.Now();
        }
        RegistryStore.Upsert(deployment);
    }

    private async Task<LinuxManagerResult<LinuxPairingBinding>> PairingCallAsync(
        LinuxDeployment deployment, string operation, JsonObject payload,
        CancellationToken cancellationToken)
    {
        var call = await AdminAsync(deployment, operation, payload, cancellationToken: cancellationToken);
        if (!call.Success) return Failure<LinuxPairingBinding>(call);
        try
        {
            var binding = JsonSerializer.Deserialize<LinuxPairingBinding>(
                call.Response!.Result!.ToJsonString())!;
            return new LinuxManagerResult<LinuxPairingBinding>(true, call.Classification, "", binding);
        }
        catch (Exception error)
        {
            return new LinuxManagerResult<LinuxPairingBinding>(
                false, "ssh_protocol_error", error.Message);
        }
    }

    private static JsonObject PairingPayload(Guid pairingID) =>
        new() { ["pairingID"] = pairingID.ToString("D") };

    private static LinuxManagerResult<LinuxAdminOperation> OperationResult(
        LinuxAdminCallResult call, Guid operationID)
    {
        if (call.Response?.Operation is { } operation)
            return new LinuxManagerResult<LinuxAdminOperation>(
                call.Success, call.Classification, call.Success ? "" : call.Message,
                operation, operationID);
        return new LinuxManagerResult<LinuxAdminOperation>(
            false, call.Classification, call.Message, null, operationID);
    }

    private async Task<LinuxProcessResult> RemoteCommandAsync(
        string destination, string fixedRemoteCommand, CancellationToken cancellationToken)
    {
        var argv = LinuxSshCommands.AutomatedSsh(destination, fixedRemoteCommand);
        return await _runner.RunAsync(
            new LinuxProcessRequest(argv[0], argv.Skip(1).ToArray()), cancellationToken);
    }

    private async Task<LinuxProcessResult> ScpAsync(
        string localPath, string destination, string remotePath,
        CancellationToken cancellationToken)
    {
        var argv = LinuxSshCommands.AutomatedScp(localPath, destination, remotePath);
        return await _runner.RunAsync(
            new LinuxProcessRequest(argv[0], argv.Skip(1).ToArray()), cancellationToken);
    }

    private static LinuxStatusSnapshot? ParseStatusLine(string stdout)
    {
        var line = stdout.Trim();
        if (line.Length == 0 || line.Contains('\n')) return null;
        try
        {
            return LinuxStatusSnapshot.Parse(JsonNode.Parse(line));
        }
        catch { return null; }
    }

    private static async Task<string> HashFileAsync(string path, CancellationToken cancellationToken)
    {
        await using var stream = File.OpenRead(path);
        return Convert.ToHexString(await SHA256.HashDataAsync(stream, cancellationToken)).ToLowerInvariant();
    }

    private static string ExpandHome(string path)
    {
        if (path == "~") return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (path.StartsWith("~/", StringComparison.Ordinal))
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), path[2..]);
        return path;
    }

    private static LinuxManagerResult<T> Failure<T>(LinuxAdminCallResult call) =>
        new(false, call.Classification, call.Message, default, call.OperationID);

    private static LinuxManagerResult<T> ProcessFailure<T>(
        LinuxProcessResult process, string? message = null)
    {
        var classification = LinuxSshCommands.Classify(process);
        var detail = message ?? (process.StandardError.Trim().Length > 0
            ? Bound(process.StandardError.Trim())
            : "The SSH command failed.");
        return new LinuxManagerResult<T>(false, classification, detail);
    }

    private static string Bound(string value) =>
        value.Length <= 500 ? value : value[..500];
}
