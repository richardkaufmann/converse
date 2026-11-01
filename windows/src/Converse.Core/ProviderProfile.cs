using System.Diagnostics;

namespace Converse.Core;

// Login and every subsequent provider process must use the same account store.
public static class ProviderProfile
{
    public static void Apply(ProcessStartInfo start, AgentEntry entry)
    {
        if (string.IsNullOrEmpty(entry.AccountDirectory)) return;
        var folder = entry.AccountDirectory;
        if (entry.Engine == "codex")
        {
            start.Environment.Remove("CODEX_ACCESS_TOKEN"); start.Environment.Remove("OPENAI_API_KEY");
            start.Environment["CODEX_HOME"] = folder;
        }
        if (entry.Engine == "claude")
        {
            start.Environment.Remove("ANTHROPIC_API_KEY"); start.Environment.Remove("ANTHROPIC_AUTH_TOKEN");
            start.Environment.Remove("CLAUDE_CODE_OAUTH_TOKEN"); start.Environment.Remove("CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR");
            if (entry.UseDefaultAccountStore != true) start.Environment["CLAUDE_CONFIG_DIR"] = folder;
        }
        if (entry.Engine == "muse" && entry.UseDefaultAccountStore != true)
        {
            start.Environment.Remove("META_API_KEY");
            start.Environment["XDG_CONFIG_HOME"] = Path.Combine(folder, "config");
            start.Environment["XDG_DATA_HOME"] = Path.Combine(folder, "data");
            start.Environment["XDG_CACHE_HOME"] = Path.Combine(folder, "cache");
            start.Environment["MUSE_AUTH_PATH"] = Path.Combine(folder, "config", "muse", "auth.json");
        }
    }

    public static ProcessStartInfo Login(AgentEntry entry)
    {
        var command = CommandResolution.Resolve(entry.Command) ?? throw new InvalidOperationException("Install this provider's CLI, then select it again.");
        var start = new ProcessStartInfo { UseShellExecute = false, CreateNoWindow = false, WorkingDirectory = entry.Directory };
        CommandResolution.Apply(start, command, entry.Engine == "claude" ? new[] { "auth", "login" } : new[] { "login" });
        Apply(start, entry);
        return start;
    }
}
