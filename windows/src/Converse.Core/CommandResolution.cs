using System.Diagnostics;

namespace Converse.Core;

/// <summary>
/// Resolves a configured CLI command to something Process.Start can launch.
/// Windows npm installs ship only .cmd shims, which CreateProcess cannot run
/// directly; those are wrapped in cmd.exe /d /s /c with every argument quoted
/// by construction (quotes doubled, % doubled, everything else literal inside
/// quotes), so prompt text containing &amp; | " ^ % cannot break out or inject.
/// Detection (Setup) and spawn share this resolver so they can never disagree.
/// </summary>
public sealed record ResolvedCommand(string FileName, string? CmdPrefix, string DisplayPath, bool UsesCmd);

public static class CommandResolution
{
    private const string DefaultPathExt = ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC";

    public static ResolvedCommand Resolve(string command) =>
        Resolve(command, Environment.GetEnvironmentVariable("PATH"),
            Environment.GetEnvironmentVariable("PATHEXT"), OperatingSystem.IsWindows());

    /// <summary>Resolved launcher path for display, or null when not found.</summary>
    public static string? FindOnPath(string command)
    {
        if (string.IsNullOrWhiteSpace(command)) return null;
        var resolved = Resolve(command);
        if (resolved.UsesCmd) return resolved.DisplayPath;
        return File.Exists(resolved.DisplayPath) ? resolved.DisplayPath : null;
    }

    internal static ResolvedCommand Resolve(string command, string? pathEnv, string? pathExtEnv, bool windows)
    {
        var trimmed = (command ?? "").Trim();
        string? found = null;
        if (trimmed.Contains(Path.DirectorySeparatorChar) || trimmed.Contains(Path.AltDirectorySeparatorChar) ||
            (windows && trimmed.Contains(':')))
        {
            if (File.Exists(trimmed)) found = Path.GetFullPath(trimmed);
        }
        else if (trimmed.Length > 0)
        {
            var extensions = windows
                ? (pathExtEnv ?? DefaultPathExt).Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                : new[] { "" };
            foreach (var dir in (pathEnv ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                foreach (var ext in extensions)
                {
                    var candidate = Path.Combine(dir, trimmed + ext.ToLowerInvariant());
                    if (File.Exists(candidate)) { found = candidate; break; }
                    if (!windows) continue;
                    var exact = Path.Combine(dir, trimmed + ext);
                    if (File.Exists(exact)) { found = exact; break; }
                }
                if (found is not null) break;
            }
        }
        if (found is null) return new ResolvedCommand(trimmed, null, trimmed, false);
        var lowerExt = Path.GetExtension(found).ToLowerInvariant();
        if (windows && (lowerExt == ".cmd" || lowerExt == ".bat"))
        {
            var comSpec = Environment.GetEnvironmentVariable("ComSpec");
            if (string.IsNullOrWhiteSpace(comSpec)) comSpec = "cmd.exe";
            return new ResolvedCommand(comSpec, QuoteCmdArg(found), found, true);
        }
        return new ResolvedCommand(found, null, found, false);
    }

    /// <summary>Quote one argument for the cmd.exe /c command line.</summary>
    public static string QuoteCmdArg(string value) =>
        "\"" + value.Replace("%", "%%").Replace("\"", "\"\"") + "\"";

    public static void Apply(ProcessStartInfo psi, ResolvedCommand resolved, IEnumerable<string> args)
    {
        if (!resolved.UsesCmd)
        {
            psi.FileName = resolved.FileName;
            foreach (var arg in args) psi.ArgumentList.Add(arg);
            return;
        }
        psi.FileName = resolved.FileName;
        var line = new System.Text.StringBuilder("/d /s /c ");
        line.Append(resolved.CmdPrefix);
        foreach (var arg in args) { line.Append(' '); line.Append(QuoteCmdArg(arg)); }
        psi.Arguments = line.ToString();
    }
}
