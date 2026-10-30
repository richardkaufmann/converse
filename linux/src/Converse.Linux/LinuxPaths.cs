using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Converse.Linux;

internal sealed class LinuxPaths
{
    public string Home { get; }
    public string ConfigRoot { get; }
    public string DataRoot { get; }
    public string StateRoot { get; }
    public string RuntimeDirectory { get; }
    public string InstallRoot { get; }
    public string ReleasesRoot { get; }
    public string BinDirectory { get; }
    public string BinLink { get; }
    public string IncomingDirectory { get; }
    public string LedgerDirectory { get; }
    public string LedgerFile { get; }
    public string UpdateStateFile { get; }
    public string SecretsDirectory { get; }
    public string SecretsMetadataFile { get; }
    public string SocketPath { get; }
    public string SecretSocketPath { get; }
    public string DesiredRunningFile { get; }
    public string SupervisorLockFile { get; }
    public string SupervisorPidFile { get; }
    public string BootstrapRoot { get; }
    public string BootstrapReceiptsDirectory { get; }
    public string LockFile { get; }
    public string SystemdUserDirectory { get; }
    public string SystemdUnitFile { get; }

    public LinuxPaths(string? homeOverride = null)
    {
        var isolated = !string.IsNullOrWhiteSpace(homeOverride);
        Home = Path.GetFullPath(isolated
            ? homeOverride!
            : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        if (string.IsNullOrWhiteSpace(Home))
            throw new InvalidOperationException("The Linux user home directory is unavailable.");

        var configHome = isolated ? Path.Combine(Home, ".config") : Xdg("XDG_CONFIG_HOME", ".config");
        var dataHome = isolated ? Path.Combine(Home, ".local", "share") : Xdg("XDG_DATA_HOME", Path.Combine(".local", "share"));
        var stateHome = isolated ? Path.Combine(Home, ".local", "state") : Xdg("XDG_STATE_HOME", Path.Combine(".local", "state"));

        ConfigRoot = Path.Combine(configHome, "converse");
        DataRoot = Path.Combine(dataHome, "converse");
        StateRoot = Path.Combine(stateHome, "converse");
        InstallRoot = Path.Combine(Home, ".local", "lib", "converse");
        ReleasesRoot = Path.Combine(InstallRoot, "releases");
        BinDirectory = Path.Combine(Home, ".local", "bin");
        BinLink = Path.Combine(BinDirectory, "converse");
        IncomingDirectory = Path.Combine(StateRoot, "incoming");
        LedgerDirectory = Path.Combine(StateRoot, "recovery-ledger", "v1");
        LedgerFile = Path.Combine(LedgerDirectory, "ledger.json");
        UpdateStateFile = Path.Combine(StateRoot, "update-state.json");
        SecretsDirectory = Path.Combine(ConfigRoot, "secrets");
        SecretsMetadataFile = Path.Combine(SecretsDirectory, "metadata.json");
        DesiredRunningFile = Path.Combine(StateRoot, "desired-running");
        SupervisorLockFile = Path.Combine(StateRoot, "supervisor.lock");
        SupervisorPidFile = Path.Combine(StateRoot, "supervisor.pid");
        BootstrapRoot = Path.Combine(Home, ".converse-bootstrap");
        BootstrapReceiptsDirectory = Path.Combine(StateRoot, "bootstrap-receipts");
        LockFile = Path.Combine(StateRoot, "converse.lock");
        SystemdUserDirectory = Path.Combine(configHome, "systemd", "user");
        SystemdUnitFile = Path.Combine(SystemdUserDirectory, "converse.service");

        var runtime = isolated ? null : Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        RuntimeDirectory = !string.IsNullOrWhiteSpace(runtime) && Path.IsPathFullyQualified(runtime)
            ? Path.Combine(runtime, "converse")
            : Path.Combine(StateRoot, "run");
        SocketPath = Path.Combine(RuntimeDirectory, "admin.sock");
        SecretSocketPath = Path.Combine(RuntimeDirectory, "secrets.sock");
    }

    public static LinuxPaths FromEnvironment() =>
        new(Environment.GetEnvironmentVariable("CONVERSE_LINUX_HOME"));

    private string Xdg(string variable, string fallbackRelative)
    {
        var value = Environment.GetEnvironmentVariable(variable);
        return !string.IsNullOrWhiteSpace(value) && Path.IsPathFullyQualified(value)
            ? value
            : Path.Combine(Home, fallbackRelative);
    }

    public static bool IsValidBootstrapToken(string token) =>
        Regex.IsMatch(token, "^[A-Za-z0-9-]{32,64}$");

    public string BootstrapStagingDirectory(string token)
    {
        if (!IsValidBootstrapToken(token)) throw new InvalidDataException("Invalid bootstrap staging token.");
        return Path.Combine(BootstrapRoot, token);
    }

    public string BootstrapExecutable(string token) =>
        Path.Combine(BootstrapStagingDirectory(token), "converse");

    public string BootstrapReceiptFile(string token)
    {
        if (!IsValidBootstrapToken(token)) throw new InvalidDataException("Invalid bootstrap staging token.");
        return Path.Combine(BootstrapReceiptsDirectory, token + ".json");
    }

    public bool DesiredRunning
    {
        get
        {
            try
            {
                return !File.Exists(DesiredRunningFile) ||
                    !string.Equals(File.ReadAllText(DesiredRunningFile).Trim(), "false", StringComparison.OrdinalIgnoreCase);
            }
            catch { return true; }
        }
    }

    public void WriteDesiredRunning(bool desired)
    {
        LinuxFileModes.Directory700(StateRoot);
        var temporary = DesiredRunningFile + $".{Guid.NewGuid():N}.tmp";
        File.WriteAllText(temporary, desired ? "true\n" : "false\n");
        LinuxFileModes.File600(temporary);
        File.Move(temporary, DesiredRunningFile, overwrite: true);
        LinuxFileModes.File600(DesiredRunningFile);
        DurableJson.TrySyncDirectory(StateRoot);
    }

    public string ReleaseDirectory(string releaseID)
    {
        if (string.IsNullOrWhiteSpace(releaseID) || releaseID.Contains('/') ||
            releaseID.Contains('\\') || releaseID is "." or "..")
            throw new InvalidDataException("Invalid release ID.");
        return Path.Combine(ReleasesRoot, releaseID);
    }

    public string ReleaseExecutable(string releaseID) =>
        Path.Combine(ReleaseDirectory(releaseID), "converse");

    public string? LinkedReleaseID()
    {
        try
        {
            var info = new FileInfo(BinLink);
            var target = info.ResolveLinkTarget(returnFinalTarget: true);
            var directory = target is null ? info.DirectoryName : Path.GetDirectoryName(target.FullName);
            if (directory is null) return null;
            var parent = Path.GetDirectoryName(directory);
            return string.Equals(parent, ReleasesRoot, StringComparison.Ordinal)
                ? Path.GetFileName(directory)
                : null;
        }
        catch { return null; }
    }

    public void EnsurePrivateDirectories()
    {
        foreach (var directory in new[]
                 {
                     ConfigRoot, DataRoot, StateRoot, RuntimeDirectory, InstallRoot,
                     ReleasesRoot, BinDirectory, IncomingDirectory, LedgerDirectory,
                     SecretsDirectory, BootstrapRoot, BootstrapReceiptsDirectory,
                 })
            LinuxFileModes.Directory700(directory);
    }

    public void ProtectIdentity()
    {
        LinuxFileModes.File600(Path.Combine(DataRoot, "device-key.bin"));
        LinuxFileModes.File600(LedgerFile);
    }
}

internal sealed record ProductInfo(
    string Version,
    int Build,
    string? SourceCommit,
    string Architecture,
    string ReleaseID)
{
    public const int DeviceProtocolVersion = 1;
    public const int AdminApiVersion = 1;
    public const int StateSchemaVersion = 1;
    public const int RecoveryLedgerVersion = 1;

    public static ProductInfo Load(LinuxPaths paths)
    {
        var version = Environment.GetEnvironmentVariable("CONVERSE_VERSION");
        var buildText = Environment.GetEnvironmentVariable("CONVERSE_BUILD");
        var commit = Environment.GetEnvironmentVariable("CONVERSE_SOURCE_COMMIT")
            ?? typeof(ProductInfo).Assembly
                .GetCustomAttributes<AssemblyMetadataAttribute>()
                .FirstOrDefault(attribute => attribute.Key == "ConverseSourceCommit")?.Value;
        int? build = int.TryParse(buildText, out var parsedBuild) ? parsedBuild : null;

        foreach (var candidate in VersionFiles(paths))
        {
            try
            {
                if (!File.Exists(candidate)) continue;
                using var document = JsonDocument.Parse(File.ReadAllText(candidate));
                version ??= document.RootElement.GetProperty("version").GetString();
                build ??= document.RootElement.GetProperty("build").GetInt32();
                break;
            }
            catch { /* Assembly metadata remains the fallback. */ }
        }

        if (string.IsNullOrWhiteSpace(version) || build is null)
        {
            var informational = typeof(ProductInfo).Assembly
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0+0";
            var parts = informational.Split('+', 2);
            version ??= parts[0];
            if (build is null && parts.Length == 2 && int.TryParse(parts[1], out var assemblyBuild))
                build = assemblyBuild;
        }

        var architecture = RuntimeInformation.OSArchitecture switch
        {
            System.Runtime.InteropServices.Architecture.X64 => "x64",
            System.Runtime.InteropServices.Architecture.Arm64 => "arm64",
            _ => "unknown",
        };
        version = string.IsNullOrWhiteSpace(version) ? "0.0.0" : version;
        build ??= 0;
        commit = !string.IsNullOrWhiteSpace(commit) &&
                 commit.Length == 40 && commit.All(Uri.IsHexDigit)
            ? commit.ToLowerInvariant()
            : null;
        var releaseID = Environment.GetEnvironmentVariable("CONVERSE_RELEASE_ID");
        if (string.IsNullOrWhiteSpace(releaseID))
            releaseID = paths.LinkedReleaseID() ?? $"{version}-{build}-linux-{architecture}";
        return new ProductInfo(version, build.Value, commit, architecture, releaseID);
    }

    private static IEnumerable<string> VersionFiles(LinuxPaths paths)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        IEnumerable<string> Candidates()
        {
            var process = Environment.ProcessPath;
            if (!string.IsNullOrWhiteSpace(process))
                yield return Path.Combine(Path.GetDirectoryName(process) ?? "", "VERSION.json");
            var current = new DirectoryInfo(AppContext.BaseDirectory);
            for (var depth = 0; current is not null && depth < 9; depth++)
            {
                yield return Path.Combine(current.FullName, "VERSION.json");
                current = current.Parent;
            }
            var linked = paths.LinkedReleaseID();
            if (linked is not null)
                yield return Path.Combine(paths.ReleaseDirectory(linked), "VERSION.json");
        }
        foreach (var candidate in Candidates())
            if (seen.Add(candidate)) yield return candidate;
    }
}
