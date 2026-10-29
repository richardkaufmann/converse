using System.Diagnostics;
using System.Text.RegularExpressions;

namespace Converse.Core;

/// <summary>
/// Resolves a configured CLI command to something Process.Start can launch
/// with UseShellExecute=false. Native .exe wins wherever it is found. A
/// standard npm .cmd shim is unwrapped to node + script so the prompt never
/// passes through cmd.exe; an unrecognized .cmd/.bat falls back to a cmd.exe
/// wrapper with every argument quoted by construction (quotes doubled,
/// percents doubled, everything else literal inside quotes). Detection
/// (Setup) and spawn share this resolver so they can never disagree.
/// </summary>
public sealed record ResolvedCommand(string FileName, IReadOnlyList<string> PrefixArguments, string Display, bool UsesCmd = false, string? CmdPrefix = null);

public static class CommandResolution
{
    private static readonly Regex NpmShimScript = new(@"%dp0%\\([^""]+\.(?:js|mjs|cjs))", RegexOptions.IgnoreCase);

    public static ResolvedCommand? Resolve(string command) =>
        Resolve(command, OperatingSystem.IsWindows(), null);

    internal static ResolvedCommand? Resolve(string command, bool windows, IEnumerable<string>? directories)
    {
        if (string.IsNullOrWhiteSpace(command)) return null;
        var dirs = (directories ?? SearchDirectories())
            .Where(d => !string.IsNullOrWhiteSpace(d)).Select(d => d.Trim()).ToList();
        var rooted = Path.IsPathRooted(command) || (windows && Regex.IsMatch(command, @"^[A-Za-z]:[\\/]"));
        if (!windows)
        {
            if (rooted) return File.Exists(command) ? new ResolvedCommand(command, Array.Empty<string>(), command) : null;
            foreach (var dir in dirs)
            {
                var candidate = Path.Combine(dir, command);
                if (File.Exists(candidate)) return new ResolvedCommand(candidate, Array.Empty<string>(), candidate);
            }
            return null;
        }
        var hasExtension = Path.HasExtension(command);
        var candidates = new List<string>();
        foreach (var dir in rooted ? new List<string> { "" } : dirs)
        {
            var basePath = rooted ? command : Path.Combine(dir, command);
            if (hasExtension) candidates.Add(basePath);
            else { candidates.Add(basePath + ".exe"); candidates.Add(basePath + ".cmd"); candidates.Add(basePath + ".bat"); }
        }
        var exe = candidates.FirstOrDefault(c => c.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && File.Exists(c));
        if (exe is not null) return new ResolvedCommand(exe, Array.Empty<string>(), exe);
        foreach (var shim in candidates.Where(c => c.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) && File.Exists(c)))
            if (UnwrapNpmShim(shim, dirs) is { } unwrapped) return unwrapped;
        var batch = candidates.FirstOrDefault(c =>
            (c.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) || c.EndsWith(".bat", StringComparison.OrdinalIgnoreCase)) && File.Exists(c));
        if (batch is not null)
        {
            var comSpec = Environment.GetEnvironmentVariable("ComSpec");
            if (string.IsNullOrWhiteSpace(comSpec)) comSpec = "cmd.exe";
            return new ResolvedCommand(comSpec, Array.Empty<string>(), batch, true, QuoteCmdArg(batch));
        }
        return null;
    }

    internal static ResolvedCommand? UnwrapNpmShim(string shimPath, IReadOnlyList<string> dirs)
    {
        string text;
        try { text = File.ReadAllText(shimPath); } catch (IOException) { return null; }
        var match = NpmShimScript.Match(text);
        if (!match.Success) return null;
        var shimDir = Path.GetDirectoryName(shimPath) ?? "";
        var relative = match.Groups[1].Value.Replace('\\', Path.DirectorySeparatorChar);
        var script = Path.GetFullPath(Path.Combine(shimDir, relative));
        if (!File.Exists(script)) return null;
        var node = Path.Combine(shimDir, "node.exe");
        if (!File.Exists(node))
            node = dirs.Select(d => Path.Combine(d, "node.exe")).FirstOrDefault(File.Exists) ?? "";
        if (node.Length == 0) return null;
        return new ResolvedCommand(node, new[] { script }, shimPath + " (node " + script + ")");
    }

    /// <summary>Quote one argument for a cmd.exe /c command line.</summary>
    public static string QuoteCmdArg(string value) =>
        "\"" + value.Replace("%", "%%").Replace("\"", "\"\"") + "\"";

    public static void Apply(ProcessStartInfo psi, ResolvedCommand resolved, IEnumerable<string> args)
    {
        if (!resolved.UsesCmd)
        {
            psi.FileName = resolved.FileName;
            foreach (var pre in resolved.PrefixArguments) psi.ArgumentList.Add(pre);
            foreach (var arg in args) psi.ArgumentList.Add(arg);
            return;
        }
        psi.FileName = resolved.FileName;
        var line = new System.Text.StringBuilder("/d /s /c ");
        line.Append(resolved.CmdPrefix);
        foreach (var arg in args) { line.Append(' '); line.Append(QuoteCmdArg(arg)); }
        psi.Arguments = line.ToString();
    }

    /// <summary>Resolved launcher path for display, or null when not found.</summary>
    public static string? FindOnPath(string command) => Resolve(command)?.Display;

    // PATH first, then the usual per-user install folders that are often not
    // on PATH for a GUI app: the native Claude Code installer and npm globals.
    private static IEnumerable<string> SearchDirectories()
    {
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            yield return dir;
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (home.Length > 0) yield return Path.Combine(home, ".local", "bin");
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (OperatingSystem.IsWindows() && appData.Length > 0) yield return Path.Combine(appData, "npm");
    }
}
