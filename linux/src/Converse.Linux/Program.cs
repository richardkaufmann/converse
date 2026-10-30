using System.Diagnostics;
using System.Runtime.InteropServices;

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
                case "preflight":
                {
                    var status = await AdminClient.TryStatusAsync(paths)
                        ?? await LinuxInstaller.BuildPreflightStatusAsync(paths, product);
                    Console.WriteLine(AdminJson.Serialize(status));
                    return 0;
                }
                case "install-self":
                {
                    var status = await LinuxInstaller.InstallSelfAsync(paths, product);
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
                        "Usage: converse [serve|admin-request|preflight|install-self|supervise|--version]");
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
        while (true)
        {
            var started = DateTimeOffset.UtcNow;
            var start = new ProcessStartInfo
            {
                FileName = paths.BinLink,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            start.ArgumentList.Add("serve");
            using var process = Process.Start(start)
                ?? throw new InvalidOperationException("Could not start the Converse daemon.");
            await process.WaitForExitAsync();
            if (DateTimeOffset.UtcNow - started < TimeSpan.FromSeconds(2))
                await Task.Delay(2000);
        }
    }
}
