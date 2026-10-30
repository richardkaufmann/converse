using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace Converse.Linux;

internal static class LinuxProgram
{
    public static async Task<int> Main(string[] args)
    {
        var paths = LinuxPaths.FromEnvironment();
        var product = ProductInfo.Load(paths);
        var mode = args.Length == 0 ? "serve" : args[0];
        try
        {
            switch (mode)
            {
                case "serve":
                    return await ServeAsync();
                case "admin-request":
                    return await AdminClient.RunAsync(paths);
                case "secret-stdin":
                    return await AdminClient.RunSecretAsync(paths);
                case "offline-status":
                {
                    var status = await AdminClient.TryStatusAsync(paths)
                        ?? await LinuxInstaller.BuildPreflightStatusAsync(paths, product);
                    Console.WriteLine(AdminJson.Serialize(status));
                    return 0;
                }
                case "service-start":
                case "service-stop":
                {
                    var line = await Console.In.ReadLineAsync();
                    if (line is null) return 64;
                    var request = JsonSerializer.Deserialize<AdminRequest>(line, AdminJson.Options);
                    if (request is null) return 64;
                    var response = await LinuxServiceControl.HandleAsync(
                        paths, request, start: mode == "service-start");
                    Console.WriteLine(AdminJson.Serialize(response));
                    return 0;
                }
                case "bootstrap-receipt":
                {
                    var line = await Console.In.ReadLineAsync();
                    if (line is null) return 64;
                    var request = JsonSerializer.Deserialize<BootstrapInstallRequest>(
                        line, AdminJson.Options);
                    var receipt = request is null
                        ? null : LinuxInstaller.ReadReceipt(paths, request.StagingToken);
                    if (receipt is null || receipt.OperationID != request!.OperationID) return 70;
                    Console.WriteLine(AdminJson.Serialize(receipt));
                    return 0;
                }
                case "preflight":
                {
                    var status = await AdminClient.TryStatusAsync(paths)
                        ?? await LinuxInstaller.BuildPreflightStatusAsync(paths, product);
                    Console.WriteLine(AdminJson.Serialize(status));
                    return 0;
                }
                case "install-self":
                {
                    BootstrapInstallRequest? bootstrap = null;
                    if (Console.IsInputRedirected)
                    {
                        var line = await Console.In.ReadLineAsync();
                        if (!string.IsNullOrWhiteSpace(line))
                        {
                            bootstrap = JsonSerializer.Deserialize<BootstrapInstallRequest>(
                                line, AdminJson.Options);
                        }
                    }
                    var status = await LinuxInstaller.InstallSelfAsync(
                        paths, product, bootstrap: bootstrap);
                    Console.WriteLine(AdminJson.Serialize(status));
                    return 0;
                }
                case "supervise":
                    return await SuperviseAsync(paths);
                case "--version":
                    Console.WriteLine($"{product.Version} ({product.Build})");
                    return 0;
                default:
                    Console.Error.WriteLine(
                        "Usage: converse [serve|admin-request|secret-stdin|offline-status|service-start|service-stop|bootstrap-receipt|preflight|install-self|supervise|--version]");
                    return 64;
            }
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.Message);
            return error is IOException or InvalidDataException ? 70 : 1;
        }
    }

    private static async Task<int> ServeAsync()
    {
        var options = LinuxHostOptions.FromEnvironment();
        await using var host = new LinuxHost(options);
        using var shutdown = new CancellationTokenSource();
        using var sigint = PosixSignalRegistration.Create(
            PosixSignal.SIGINT, context => { context.Cancel = true; shutdown.Cancel(); });
        using var sigterm = PosixSignalRegistration.Create(
            PosixSignal.SIGTERM, context => { context.Cancel = true; shutdown.Cancel(); });
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            shutdown.Cancel();
        };
        return await host.RunAsync(shutdown.Token);
    }

    private static async Task<int> SuperviseAsync(LinuxPaths paths)
    {
        paths.EnsurePrivateDirectories();
        FileStream supervisorLock;
        try
        {
            supervisorLock = new FileStream(
                paths.SupervisorLockFile, FileMode.OpenOrCreate,
                FileAccess.ReadWrite, FileShare.None);
        }
        catch (IOException) { return 0; }

        await using var lockLifetime = supervisorLock;
        if (!paths.DesiredRunning) return 0;
        var ownPid = Environment.ProcessId;
        File.WriteAllText(paths.SupervisorPidFile, ownPid + "\n");
        LinuxFileModes.File600(paths.SupervisorPidFile);

        using var shutdown = new CancellationTokenSource();
        using var sigint = PosixSignalRegistration.Create(
            PosixSignal.SIGINT, context => { context.Cancel = true; shutdown.Cancel(); });
        using var sigterm = PosixSignalRegistration.Create(
            PosixSignal.SIGTERM, context => { context.Cancel = true; shutdown.Cancel(); });
        try
        {
            while (!shutdown.IsCancellationRequested && paths.DesiredRunning)
            {
                var started = DateTimeOffset.UtcNow;
                var start = new ProcessStartInfo
                {
                    FileName = paths.BinLink,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                };
                start.ArgumentList.Add("serve");
                start.Environment["PATH"] =
                    Path.Combine(paths.Home, ".local", "bin") + ":/usr/local/bin:/usr/bin:/bin";
                using var process = Process.Start(start)
                    ?? throw new InvalidOperationException("Could not start the Converse daemon.");
                try
                {
                    await process.WaitForExitAsync(shutdown.Token);
                }
                catch (OperationCanceledException)
                {
                    try
                    {
                        if (!process.HasExited) process.Kill(entireProcessTree: true);
                    }
                    catch { /* The daemon is already gone. */ }
                    break;
                }
                if (!paths.DesiredRunning) break;
                if (DateTimeOffset.UtcNow - started < TimeSpan.FromSeconds(2))
                    await Task.Delay(2000, shutdown.Token);
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            try
            {
                if (File.ReadAllText(paths.SupervisorPidFile).Trim() ==
                    ownPid.ToString(System.Globalization.CultureInfo.InvariantCulture))
                    File.Delete(paths.SupervisorPidFile);
            }
            catch { /* The lock remains the authority for a later supervisor. */ }
        }
        return 0;
    }
}
