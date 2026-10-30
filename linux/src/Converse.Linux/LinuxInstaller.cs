using System.Diagnostics;
using System.Text;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Converse.Core;

namespace Converse.Linux;

internal sealed class BootstrapInstallRequest
{
    [JsonPropertyName("operationID")] public Guid OperationID { get; set; }
    [JsonPropertyName("stagingToken")] public string StagingToken { get; set; } = "";
}

internal sealed class BootstrapReceipt
{
    [JsonPropertyName("receiptVersion")] public int ReceiptVersion { get; set; } = 1;
    [JsonPropertyName("operationID")] public Guid OperationID { get; set; }
    [JsonPropertyName("stagingToken")] public string StagingToken { get; set; } = "";
    [JsonPropertyName("deviceID")] public string DeviceID { get; set; } = "";
    [JsonPropertyName("releaseID")] public string ReleaseID { get; set; } = "";
    [JsonPropertyName("sourceSHA256")] public string SourceSHA256 { get; set; } = "";
    [JsonPropertyName("supervisor")] public string Supervisor { get; set; } = "";
    [JsonPropertyName("completedAt")] public string CompletedAt { get; set; } = "";
}

internal static class LinuxInstaller
{
    public static async Task<LinuxStatus> BuildPreflightStatusAsync(
        LinuxPaths paths, ProductInfo product)
    {
        var installed = File.Exists(paths.BinLink) || paths.LinkedReleaseID() is not null;
        string? deviceID = null;
        var keyFile = Path.Combine(paths.DataRoot, "device-key.bin");
        if (File.Exists(keyFile))
        {
            var key = await File.ReadAllBytesAsync(keyFile);
            if (key.Length == 32)
                deviceID = DeviceBlob.DeviceIdForPublicKey(X25519.PublicKeyFromPrivate(key));
        }

        LinuxUpdateState updateState = new();
        if (File.Exists(paths.UpdateStateFile))
        {
            try
            {
                updateState = JsonSerializer.Deserialize<LinuxUpdateState>(
                    await File.ReadAllBytesAsync(paths.UpdateStateFile), DurableJson.Options) ?? new LinuxUpdateState();
            }
            catch { /* Status reports recovery instead of guessing release state. */ }
        }
        UpdateEpisode? episode = null;
        var recovery = false;
        if (File.Exists(paths.LedgerFile))
        {
            try
            {
                var ledger = JsonSerializer.Deserialize<RecoveryLedger>(
                    await File.ReadAllBytesAsync(paths.LedgerFile), DurableJson.Options);
                episode = ledger?.UpdateEpisode;
                recovery = ledger is null;
            }
            catch { recovery = true; }
        }

        using var executor = new SerializedStateExecutor();
        var secrets = new LinuxSecretStore(paths, executor);
        return new LinuxStatus
        {
            ProductVersion = product.Version,
            Build = product.Build,
            SourceCommit = product.SourceCommit,
            Architecture = product.Architecture,
            Device = new StatusDevice
            {
                DeviceID = deviceID,
                Name = Environment.MachineName,
            },
            Runtime = new StatusRuntime
            {
                ProcessState = !installed ? "not_installed" : recovery ? "recovery_required" : "stopped",
                Supervisor = updateState.Supervisor,
                DesiredRunning = paths.DesiredRunning,
                StartedAt = null,
                Admission = !installed ? "closed_not_installed" : recovery ? "closed_recovery" : "closed_stopped",
            },
            Filesystem = new StatusFilesystem
            {
                InstallRoot = paths.InstallRoot,
                StateRoot = paths.StateRoot,
                ConfigRoot = paths.ConfigRoot,
                DataRoot = paths.DataRoot,
            },
            Release = new StatusRelease
            {
                CurrentReleaseID = installed
                    ? paths.LinkedReleaseID() ?? updateState.CurrentReleaseID ?? product.ReleaseID
                    : null,
                PreviousReleaseID = updateState.PreviousReleaseID,
                StagedReleaseID = updateState.StagedReleaseID,
                UpdateEpisode = episode,
            },
            Secrets = await secrets.ListAsync(),
            Capabilities =
            [
                "linux-home-v1", "admin-v1", "offline-status-v1", "secret-stdin-v1",
                "fabric-membership-v1", "converse-groups-v1", "agent-host-v1",
            ],
        };
    }

    public static async Task<LinuxStatus> InstallSelfAsync(
        LinuxPaths paths,
        ProductInfo product,
        string? sourceOverride = null,
        string? supervisorOverride = null,
        BootstrapInstallRequest? bootstrap = null)
    {
        paths.EnsurePrivateDirectories();
        var source = ResolveSource(sourceOverride);
        var sourceHash = ReleaseBundleVerifier.HashFile(source);
        var releaseID = Environment.GetEnvironmentVariable("CONVERSE_RELEASE_ID");
        if (string.IsNullOrWhiteSpace(releaseID))
            releaseID = $"{product.Version}-{product.Build}-linux-{product.Architecture}";

        if (bootstrap is not null)
        {
            if (bootstrap.OperationID == Guid.Empty ||
                !LinuxPaths.IsValidBootstrapToken(bootstrap.StagingToken))
                throw new InvalidDataException("The bootstrap operation request is invalid.");
            var existingReceipt = ReadReceipt(paths, bootstrap.StagingToken);
            if (existingReceipt is not null)
            {
                if (existingReceipt.OperationID != bootstrap.OperationID ||
                    existingReceipt.SourceSHA256 != sourceHash ||
                    existingReceipt.ReleaseID != releaseID ||
                    !File.Exists(paths.ReleaseExecutable(existingReceipt.ReleaseID)))
                    throw new InvalidOperationException(
                        "The bootstrap staging token belongs to a different installation.");
                return await AdminClient.TryStatusAsync(paths)
                    ?? await BuildPreflightStatusAsync(paths, product);
            }
        }

        InstallExecutable(paths, product, source, releaseID);

        string deviceID;
        string supervisor;
        using (var executor = new SerializedStateExecutor())
        {
            var store = new SessionStore(paths.DataRoot);
            var devices = new DeviceSyncService(paths.DataRoot, store, Environment.MachineName);
            deviceID = devices.DeviceId;
            paths.ProtectIdentity();
            var ledger = new RecoveryLedgerStore(paths, executor);
            await ledger.InitializeAsync(deviceID);
            await ledger.SyncAuthorityAsync(
                devices.SyncCounterSnapshot(),
                devices.Trust.NextGenerationFloor,
                devices.Trust.Records,
                devices.GroupStore.Groups,
                devices.CommandReceipts);
            if (bootstrap is not null)
            {
                var requestHash = Convert.ToHexString(SHA256.HashData(
                    Encoding.UTF8.GetBytes(
                        $"bootstrap.install\0{deviceID}\0{bootstrap.StagingToken}\0{sourceHash}")))
                    .ToLowerInvariant();
                await ledger.BeginOperationAsync(
                    bootstrap.OperationID, "bootstrap.install", requestHash,
                    null, "running");
            }
            devices.Dispose();

            supervisor = await InstallSupervisorAsync(paths, supervisorOverride);
            paths.WriteDesiredRunning(true);
            WriteUpdateState(paths, releaseID, supervisor);
            if (bootstrap is not null)
            {
                var receipt = new BootstrapReceipt
                {
                    OperationID = bootstrap.OperationID,
                    StagingToken = bootstrap.StagingToken,
                    DeviceID = deviceID,
                    ReleaseID = releaseID,
                    SourceSHA256 = sourceHash,
                    Supervisor = supervisor,
                    CompletedAt = LinuxTime.Now(),
                };
                LinuxFileModes.Directory700(paths.BootstrapReceiptsDirectory);
                DurableJson.Write(paths.BootstrapReceiptFile(bootstrap.StagingToken), receipt);
                LinuxFileModes.File600(paths.BootstrapReceiptFile(bootstrap.StagingToken));
                await ledger.TransitionOperationAsync(
                    bootstrap.OperationID, "completed", "installed", resultRef: deviceID);
            }
        }

        if (supervisor is "systemd-user" or "cron-fallback")
        {
            for (var attempt = 0; attempt < 30; attempt++)
            {
                var live = await AdminClient.TryStatusAsync(paths);
                if (live is not null) return live;
                await Task.Delay(100);
            }
        }
        return await BuildPreflightStatusAsync(paths, product);
    }

    public static BootstrapReceipt? ReadReceipt(LinuxPaths paths, string stagingToken)
    {
        var file = paths.BootstrapReceiptFile(stagingToken);
        if (!File.Exists(file)) return null;
        var receipt = JsonSerializer.Deserialize<BootstrapReceipt>(
            File.ReadAllBytes(file), DurableJson.Options);
        return receipt is not null && receipt.ReceiptVersion == 1 &&
            receipt.StagingToken == stagingToken
            ? receipt
            : throw new InvalidDataException("The bootstrap receipt is invalid.");
    }

    internal static string ResolveSource(string? sourceOverride = null)
    {
        var candidate = sourceOverride ??
            Environment.GetEnvironmentVariable("CONVERSE_LINUX_BOOTSTRAP_SOURCE");
        if (!string.IsNullOrWhiteSpace(candidate))
        {
            var full = Path.GetFullPath(candidate);
            if (File.Exists(full)) return full;
            throw new FileNotFoundException("The bootstrap executable was not found.", full);
        }
        var process = Environment.ProcessPath;
        if (!string.IsNullOrWhiteSpace(process) &&
            !string.Equals(Path.GetFileNameWithoutExtension(process), "dotnet", StringComparison.OrdinalIgnoreCase) &&
            File.Exists(process))
            return Path.GetFullPath(process);
        throw new InvalidOperationException(
            "install-self requires the published converse executable, not a dotnet host process.");
    }

    private static void InstallExecutable(
        LinuxPaths paths, ProductInfo product, string source, string releaseID)
    {
        var destination = paths.ReleaseExecutable(releaseID);
        var releaseDirectory = Path.GetDirectoryName(destination)!;
        LinuxFileModes.Directory700(releaseDirectory);
        var sourceHash = ReleaseBundleVerifier.HashFile(source);
        if (File.Exists(destination))
        {
            if (!string.Equals(ReleaseBundleVerifier.HashFile(destination), sourceHash, StringComparison.Ordinal))
                throw new InvalidOperationException("A different executable already uses this release ID.");
        }
        else
        {
            var temporary = Path.Combine(releaseDirectory, $".converse-{Guid.NewGuid():N}.tmp");
            try
            {
                File.Copy(source, temporary, overwrite: false);
                LinuxFileModes.File700(temporary);
                File.Move(temporary, destination, overwrite: false);
                DurableJson.TrySyncDirectory(releaseDirectory);
            }
            finally
            {
                try { if (File.Exists(temporary)) File.Delete(temporary); } catch { /* best effort */ }
            }
        }
        LinuxFileModes.File700(destination);
        var versionFile = Path.Combine(releaseDirectory, "VERSION.json");
        if (!File.Exists(versionFile))
        {
            DurableJson.Write(versionFile, new Dictionary<string, object>
            {
                ["version"] = product.Version,
                ["build"] = product.Build,
            });
        }
        SwitchLink(paths, destination);
    }

    private static void SwitchLink(LinuxPaths paths, string target)
    {
        LinuxFileModes.Directory700(paths.BinDirectory);
        var temporary = Path.Combine(paths.BinDirectory, $".converse-{Guid.NewGuid():N}.tmp");
        try
        {
            File.CreateSymbolicLink(temporary, target);
            File.Move(temporary, paths.BinLink, overwrite: true);
            DurableJson.TrySyncDirectory(paths.BinDirectory);
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); } catch { /* best effort */ }
        }
    }

    private static async Task<string> InstallSupervisorAsync(
        LinuxPaths paths, string? supervisorOverride)
    {
        var requested = supervisorOverride ??
            Environment.GetEnvironmentVariable("CONVERSE_LINUX_SUPERVISOR");
        var supervisor = string.IsNullOrWhiteSpace(requested)
            ? await DetectSupervisorAsync()
            : requested.Trim();

        switch (supervisor)
        {
            case "systemd-user":
                await InstallSystemdAsync(paths);
                return supervisor;
            case "cron-fallback":
                await InstallCronAsync(paths);
                return supervisor;
            case "manual-test":
            case "none":
                return supervisor;
            default:
                throw new InvalidOperationException($"Unknown Linux supervisor: {supervisor}");
        }
    }

    private static async Task<string> DetectSupervisorAsync()
    {
        if (await RunAsync("systemctl", ["--user", "show-environment"]) is { ExitCode: 0 })
            return "systemd-user";
        if (FindOnPath("crontab") is not null) return "cron-fallback";
        return "none";
    }

    private static async Task InstallSystemdAsync(LinuxPaths paths)
    {
        LinuxFileModes.Directory700(paths.SystemdUserDirectory);
        var unit = $"""
            [Unit]
            Description=Converse Linux home
            After=network-online.target
            Wants=network-online.target

            [Service]
            Type=simple
            ExecStart="{paths.BinLink}" serve
            Restart=always
            RestartSec=2
            UMask=0077
            Environment=CONVERSE_LINUX_SUPERVISOR=systemd-user
            Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin

            [Install]
            WantedBy=default.target

            """;
        await File.WriteAllTextAsync(paths.SystemdUnitFile, unit, Encoding.UTF8);
        LinuxFileModes.File600(paths.SystemdUnitFile);
        var reload = await RunAsync("systemctl", ["--user", "daemon-reload"]);
        if (reload.ExitCode != 0)
            throw new InvalidOperationException("systemctl daemon-reload failed: " + Bound(reload.Stderr));
        var enable = await RunAsync("systemctl", ["--user", "enable", "--now", "converse.service"]);
        if (enable.ExitCode != 0)
            throw new InvalidOperationException("systemctl enable failed: " + Bound(enable.Stderr));
    }

    private static async Task InstallCronAsync(LinuxPaths paths)
    {
        var current = await RunAsync("crontab", ["-l"]);
        var lines = (current.ExitCode == 0 ? current.Stdout : "")
            .Split('\n')
            .Select(line => line.TrimEnd('\r'))
            .Where(line => !line.Contains("# Converse Linux home", StringComparison.Ordinal))
            .ToList();
        while (lines.Count > 0 && string.IsNullOrWhiteSpace(lines[^1])) lines.RemoveAt(lines.Count - 1);
        lines.Add("@reboot \"$HOME/.local/bin/converse\" supervise >/dev/null 2>&1 # Converse Linux home");
        lines.Add("* * * * * \"$HOME/.local/bin/converse\" supervise >/dev/null 2>&1 # Converse Linux home");
        var updated = await RunAsync("crontab", ["-"], string.Join("\n", lines) + "\n");
        if (updated.ExitCode != 0)
            throw new InvalidOperationException("crontab install failed: " + Bound(updated.Stderr));

        var setsid = FindOnPath("setsid");
        var start = new ProcessStartInfo
        {
            FileName = setsid ?? paths.BinLink,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        if (setsid is not null) start.ArgumentList.Add(paths.BinLink);
        start.ArgumentList.Add("supervise");
        using var process = Process.Start(start)
            ?? throw new InvalidOperationException("Could not start the cron-supervised daemon.");
    }

    private static void WriteUpdateState(LinuxPaths paths, string releaseID, string supervisor)
    {
        LinuxUpdateState state = new();
        if (File.Exists(paths.UpdateStateFile))
        {
            try
            {
                state = JsonSerializer.Deserialize<LinuxUpdateState>(
                    File.ReadAllBytes(paths.UpdateStateFile), DurableJson.Options) ?? new LinuxUpdateState();
            }
            catch { /* Install establishes a fresh release pointer below. */ }
        }
        if (state.CurrentReleaseID is not null && state.CurrentReleaseID != releaseID)
            state.PreviousReleaseID = state.CurrentReleaseID;
        state.CurrentReleaseID = releaseID;
        state.Supervisor = supervisor;
        DurableJson.Write(paths.UpdateStateFile, state);
        LinuxFileModes.File600(paths.UpdateStateFile);
    }

    private sealed record ProcessResult(int ExitCode, string Stdout, string Stderr);

    private static async Task<ProcessResult> RunAsync(
        string executable, string[] arguments, string? stdin = null)
    {
        var start = new ProcessStartInfo
        {
            FileName = executable,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = stdin is not null,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        try
        {
            using var process = Process.Start(start)
                ?? throw new InvalidOperationException($"Could not start {executable}.");
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            if (stdin is not null)
            {
                await process.StandardInput.WriteAsync(stdin);
                process.StandardInput.Close();
            }
            await process.WaitForExitAsync();
            return new ProcessResult(process.ExitCode, await stdout, await stderr);
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception)
        {
            return new ProcessResult(127, "", error.Message);
        }
    }

    private static string? FindOnPath(string executable)
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var directory in path.Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(directory)) continue;
            var candidate = Path.Combine(directory, executable);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    private static string Bound(string value) =>
        value.Length <= 500 ? value.Trim() : value[..500].Trim();
}
