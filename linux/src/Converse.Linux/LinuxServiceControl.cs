using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Converse.Core;

namespace Converse.Linux;

internal static class LinuxServiceControl
{
    public static async Task<AdminResponse> HandleAsync(
        LinuxPaths paths, AdminRequest request, bool start)
    {
        if (request.AdminApiVersion != 1)
        {
            return AdminResponse.Failure(
                request.RequestID, "unsupported_admin_api", "This Linux home supports admin API version 1.");
        }
        var expectedOperation = start ? "service.start" : "service.stop";
        if (request.Operation != expectedOperation || request.OperationID is null ||
            request.OperationID == Guid.Empty || request.Payload.ValueKind != JsonValueKind.Object)
        {
            return AdminResponse.Failure(
                request.RequestID, "invalid_request", "A service operation ID and matching operation are required.");
        }

        var identity = await OfflineIdentityAsync(paths);
        if (identity is null)
        {
            return AdminResponse.Failure(
                request.RequestID, "recovery_required",
                "The Linux identity or recovery ledger is unavailable.", retryable: true);
        }
        if (request.ExpectedDeviceID is not null && request.ExpectedDeviceID != identity)
        {
            return AdminResponse.Failure(
                request.RequestID, "identity_mismatch",
                "The Linux Converse identity does not match this deployment.");
        }

        var live = await AdminClient.SendAsync(paths, request, TimeSpan.FromSeconds(5));
        if (live is not null && live.RequestID == request.RequestID)
        {
            if (!start && live.Ok)
            {
                try
                {
                    await Task.Delay(300);
                    await ApplyAsync(paths, ReadUpdateState(paths).Supervisor, start: false);
                }
                catch { /* The daemon already recorded the stop and is exiting. */ }
            }
            return live;
        }

        using var executor = new SerializedStateExecutor();
        var ledger = new RecoveryLedgerStore(paths, executor);
        await ledger.InitializeAsync(identity);
        var operationID = request.OperationID.Value;
        var hash = AdminJson.RequestHash(request);
        LedgerOperation operation;
        try
        {
            operation = await ledger.BeginOperationAsync(
                operationID, expectedOperation, hash, null, "running");
        }
        catch (OperationConflictException error)
        {
            return AdminResponse.Failure(request.RequestID, "operation_conflict", error.Message);
        }
        if (operation.IsTerminal)
            return await ResponseAsync(request.RequestID, ledger, operation);

        var updateState = ReadUpdateState(paths);
        var supervisor = updateState.Supervisor;
        try
        {
            paths.WriteDesiredRunning(start);
            await ApplyAsync(paths, supervisor, start);
            await ledger.TransitionOperationAsync(
                operationID, "completed", start ? "started" : "stopped", resultRef: supervisor);
        }
        catch (AdminException error)
        {
            await ledger.TransitionOperationAsync(operationID, "failed", error.Code);
            return AdminResponse.Failure(
                request.RequestID, error.Code, error.Message, error.Retryable, error.Uncertain);
        }
        catch (Exception error)
        {
            await ledger.TransitionOperationAsync(
                operationID, "uncertain", "service_control_failed");
            return AdminResponse.Failure(
                request.RequestID, "service_control_failed", error.Message, uncertain: true);
        }
        operation = await ledger.GetOperationAsync(operationID) ?? operation;
        return await ResponseAsync(request.RequestID, ledger, operation);
    }

    public static async Task<string?> OfflineIdentityAsync(LinuxPaths paths)
    {
        try
        {
            using var executor = new SerializedStateExecutor();
            var ledger = new RecoveryLedgerStore(paths, executor);
            if (ledger.Existing?.DeviceID is { Length: 64 } ledgerID) return ledgerID;
        }
        catch { return null; }

        try
        {
            var keyFile = Path.Combine(paths.DataRoot, "device-key.bin");
            if (!File.Exists(keyFile)) return null;
            var key = await File.ReadAllBytesAsync(keyFile);
            return key.Length == 32
                ? DeviceBlob.DeviceIdForPublicKey(X25519.PublicKeyFromPrivate(key))
                : null;
        }
        catch { return null; }
    }

    private static async Task<AdminResponse> ResponseAsync(
        Guid requestID, RecoveryLedgerStore ledger, LedgerOperation operation)
    {
        var snapshot = await ledger.SnapshotAsync();
        return AdminResponse.Success(requestID, operation:
            LinuxUpdateManager.ToAdminOperation(operation, snapshot.UpdateEpisode));
    }

    private static LinuxUpdateState ReadUpdateState(LinuxPaths paths)
    {
        if (!File.Exists(paths.UpdateStateFile)) return new LinuxUpdateState();
        return JsonSerializer.Deserialize<LinuxUpdateState>(
            File.ReadAllBytes(paths.UpdateStateFile), DurableJson.Options) ?? new LinuxUpdateState();
    }

    private static async Task ApplyAsync(LinuxPaths paths, string supervisor, bool start)
    {
        switch (supervisor)
        {
            case "systemd-user":
            {
                var result = await RunAsync(
                    "systemctl", ["--user", start ? "start" : "stop", "converse.service"]);
                if (result.ExitCode != 0)
                {
                    throw new AdminException(
                        "service_control_failed",
                        $"systemctl could not {(start ? "start" : "stop")} Converse: {Bound(result.Stderr)}",
                        retryable: true);
                }
                break;
            }
            case "cron-fallback":
            case "manual-test":
                if (start) StartSupervise(paths);
                else StopSupervise(paths);
                break;
            default:
                throw new AdminException(
                    "unsupported_supervisor",
                    "Service start/stop requires the systemd-user or guarded cron supervisor.");
        }
    }

    internal static void StartSupervise(LinuxPaths paths)
    {
        if (SupervisorIsAlive(paths)) return;
        var setsid = FindOnPath("setsid");
        var startInfo = new ProcessStartInfo
        {
            FileName = setsid ?? paths.BinLink,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        if (setsid is not null) startInfo.ArgumentList.Add(paths.BinLink);
        startInfo.ArgumentList.Add("supervise");
        using var process = Process.Start(startInfo)
            ?? throw new AdminException("service_control_failed", "Could not start the Converse supervisor.");
    }

    private static void StopSupervise(LinuxPaths paths)
    {
        if (!int.TryParse(ReadPid(paths.SupervisorPidFile), out var pid)) return;
        try
        {
            if (OperatingSystem.IsWindows()) return;
            _ = Kill(pid, 15); // SIGTERM; the supervisor then terminates its daemon child tree via process exit.
        }
        catch { /* A stale PID is treated as stopped. */ }
    }

    internal static bool SupervisorIsAlive(LinuxPaths paths)
    {
        if (!int.TryParse(ReadPid(paths.SupervisorPidFile), out var pid)) return false;
        try
        {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch { return false; }
    }

    private static string? ReadPid(string file)
    {
        try { return File.Exists(file) ? File.ReadAllText(file).Trim() : null; }
        catch { return null; }
    }

    private sealed record ProcessResult(int ExitCode, string Stderr);

    private static async Task<ProcessResult> RunAsync(string executable, string[] arguments)
    {
        var start = new ProcessStartInfo
        {
            FileName = executable,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)
            ?? throw new AdminException("service_control_failed", $"Could not start {executable}.");
        var stderr = process.StandardError.ReadToEndAsync();
        await process.StandardOutput.ReadToEndAsync();
        await process.WaitForExitAsync();
        return new ProcessResult(process.ExitCode, await stderr);
    }

    private static string? FindOnPath(string executable)
    {
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "")
                     .Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(directory)) continue;
            var candidate = Path.Combine(directory, executable);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    private static string Bound(string value) =>
        value.Length <= 300 ? value.Trim() : value[..300].Trim();

    [DllImport("libc", EntryPoint = "kill", SetLastError = true)]
    private static extern int Kill(int pid, int signal);
}
