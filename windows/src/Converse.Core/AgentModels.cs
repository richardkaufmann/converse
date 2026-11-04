using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace Converse.Core;

public static class AgentModels
{
    public static string Reference(string engine, string account, string model = "") => "cli|" + engine + "|" + Convert.ToBase64String(Encoding.UTF8.GetBytes(account)) + "|" + Convert.ToBase64String(Encoding.UTF8.GetBytes(model));
    public static (string Engine, string Account, string Model)? Parse(string value)
    {
        var p = value.Split('|');
        if (p.Length != 4 || p[0] != "cli" || p[1] is not ("claude" or "codex" or "muse")) return null;
        try { var account = Encoding.UTF8.GetString(Convert.FromBase64String(p[2])); return account.Length == 0 ? null : (p[1], account, Encoding.UTF8.GetString(Convert.FromBase64String(p[3]))); }
        catch (FormatException) { return null; }
    }
    public static string Label(string value) => Parse(value) is { } route ? route.Engine + " · " + (route.Model.Length == 0 ? "CLI default" : route.Model) : "Meta API · " + value;
    public static AgentEntry Resolve(SessionStore store, string value)
    {
        var route = Parse(value) ?? throw new ArgumentException("Invalid provider selection.");
        var entry = Accounts(store).FirstOrDefault(p => p.Account == route.Account).Entry;
        if (entry?.Engine != route.Engine || !store.Entries.Any(e => e.Engine == route.Engine)) throw new InvalidOperationException("Selected provider/login is no longer available. Choose a model in Agent Setup.");
        return entry.Copy();
    }
    public static string AccountKey(AgentEntry entry) => Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(System.Text.Json.JsonSerializer.Serialize(new { entry.Engine, entry.Command, entry.AccountDirectory, entry.UseDefaultAccountStore })))).ToLowerInvariant()[..24];
    public static List<(string Account, AgentEntry Entry)> Accounts(SessionStore store) => store.Sessions.Where(s => s.Entry.Engine is "claude" or "codex" or "muse")
        .Select(s => (AccountKey(s.Entry), s.Entry)).Concat(store.Entries.Where(e => e.Engine is "claude" or "codex" or "muse").Select(e => (AccountKey(e), e)))
        .Where(p => store.Entries.Any(e => e.Engine == p.Item2.Engine)).DistinctBy(p => (p.Item2.Engine, p.Item2.AccountDirectory, p.Item2.UseDefaultAccountStore)).ToList();
    // Accounts whose CLI command resolves on this computer.
    public static List<(string Account, AgentEntry Entry)> Installed(SessionStore store) => Accounts(store).Where(p => store.AgentCommandAvailable(p.Entry)).ToList();
    // Preferred CLI for a new agent without a Meta key: Claude, then Codex, then Muse.
    public static string? DefaultCli(SessionStore store) => Installed(store).OrderBy(p => Array.IndexOf(new[] { "claude", "codex", "muse" }, p.Entry.Engine))
        .Select(p => Reference(p.Entry.Engine, p.Account)).FirstOrDefault();
    public static List<DeviceChoiceDto> Options(SessionStore store) => Accounts(store).Select(p => new DeviceChoiceDto { Id = Reference(p.Entry.Engine, p.Account), Label = p.Entry.Name + " · " + (p.Entry.AccountName ?? "CLI login") + " · CLI default" }).ToList();
    public static async Task<List<DeviceChoiceDto>> DiscoverAsync(SessionStore store, string? metaKey = null)
    {
        var options = Options(store);
        foreach (var (account, entry) in Accounts(store))
        {
            try
            {
                IEnumerable<(string Id, string Label)> rows;
                if (entry.Engine == "codex") rows = (await store.CodexModels.GetAsync(entry)).Models.Select(m => (m.Id, m.Label));
                else if (entry.Engine == "muse")
                {
                    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                    using var client = MuseMspClient.StartProcess(entry, Guid.NewGuid().ToString());
                    await client.InitializeAsync(timeout.Token);
                    var catalog = await client.RpcAsync("model/list", new(), timeout.Token);
                    rows = (catalog["models"] as JsonArray ?? new()).OfType<JsonObject>().Where(m => m["id"] is not null).Select(m => (m["id"]!.GetValue<string>(), m["displayName"]?.GetValue<string>() ?? m["id"]!.GetValue<string>())).ToArray();
                }
                else rows = await ClaudeModels(entry);
                foreach (var (id, label) in rows) options.Add(new() { Id = Reference(entry.Engine, account, id), Label = entry.Name + " · " + (entry.AccountName ?? "CLI login") + " · " + label });
            }
            catch { /* Keep explicit default; catalog failure is not account authorization. */ }
        }
        if (!string.IsNullOrEmpty(metaKey)) try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
            http.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", metaKey);
            var root = JsonNode.Parse(await http.GetStringAsync("https://api.meta.ai/v1/models"));
            foreach (var row in (root?["data"] as JsonArray ?? new()).OfType<JsonObject>())
                if (row["id"]?.GetValue<string>() is { } id && (id.Contains("spark") || id.Contains("wonder"))) options.Add(new() { Id = id, Label = "Meta API · " + id });
        }
        catch { }
        return options.DistinctBy(o => o.Id).ToList();
    }
    private static async Task<List<(string, string)>> ClaudeModels(AgentEntry entry)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15)); var token = timeout.Token;
        var start = AgentCLI.Start(entry, new[] { "--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json", "--no-session-persistence" });
        using var process = Process.Start(start) ?? throw new InvalidOperationException("CLI unavailable");
        using var registration = token.Register(() => { try { process.Kill(true); } catch { } });
        _ = process.StandardError.BaseStream.CopyToAsync(Stream.Null, token);
        try
        {
            await process.StandardInput.WriteLineAsync("{\"type\":\"control_request\",\"request_id\":\"converse-models\",\"request\":{\"subtype\":\"initialize\"}}");
            while (await process.StandardOutput.ReadLineAsync(token) is { } line)
            {
                var root = JsonNode.Parse(line); var response = root?["response"];
                if (response?["request_id"]?.GetValue<string>() != "converse-models") continue;
                return (response["response"]?["models"] as JsonArray ?? new()).OfType<JsonObject>().Where(m => m["value"] is not null).Select(m => (m["value"]!.GetValue<string>(), m["displayName"]?.GetValue<string>() ?? m["value"]!.GetValue<string>())).ToList();
            }
            return new();
        }
        finally { try { if (!process.HasExited) process.Kill(true); } catch { } }
    }
}

public static class AgentCLI
{
    internal static ProcessStartInfo Start(AgentEntry entry, IEnumerable<string> args)
    {
        var start = new ProcessStartInfo { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardInputEncoding = new UTF8Encoding(false) };
        CommandResolution.Apply(start, CommandResolution.Resolve(entry.Command) ?? throw new InvalidOperationException("Provider CLI unavailable."), args);
        if (Directory.Exists(entry.Directory)) start.WorkingDirectory = entry.Directory;
        ProviderProfile.Apply(start, entry); return start;
    }
    public static List<string> Arguments(string engine, string model, string prompt, string output)
    {
        var args = engine switch {
            "claude" => new List<string> { "--print", "--output-format", "json", "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--disable-slash-commands", "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}" },
            "codex" => new List<string> { "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--sandbox", "read-only", "--disable", "shell_tool", "--disable", "apps", "--disable", "plugins", "--disable", "multi_agent", "--disable", "hooks", "-c", "approval_policy=\"never\"", "-c", "web_search=\"disabled\"", "--output-last-message", output },
            "muse" => new List<string> { "exec", "--json", "--preset", "empty", "--disable-shell", "--disable-write", "--disable-web-tools", "--disable-reminders", "--disable-request-user-input", "--no-foreign-personal-context", "--no-session-log", "--max-model-steps", "1", "--prompt-file", prompt },
            _ => throw new ArgumentException("Unsupported provider.")
        };
        if (model.Length > 0) args.AddRange(new[] { "--model", model }); return args;
    }
    public static async Task<string> RespondAsync(AgentEntry entry, string model, string instructions, string input, CancellationToken cancellation)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation); timeout.CancelAfter(TimeSpan.FromMinutes(3)); var token = timeout.Token;
        var folder = Directory.CreateTempSubdirectory("converse-agent-").FullName;
        try
        {
            var prompt = Path.Combine(folder, "prompt.txt"); var output = Path.Combine(folder, "final.txt");
            var text = instructions + "\nUse only supplied evidence. Tool-based research is unavailable for this CLI activation. Return the required JSON only.\n" + input;
            await File.WriteAllTextAsync(prompt, text, token);
            var isolated = entry.Copy(); isolated.Directory = folder;
            using var process = Process.Start(Start(isolated, Arguments(entry.Engine, model, prompt, output))) ?? throw new InvalidOperationException("Provider could not start.");
            using var registration = token.Register(() => { try { process.Kill(true); } catch { } });
            var stderr = process.StandardError.BaseStream.CopyToAsync(Stream.Null, token);
            var stdout = ReadBounded(process.StandardOutput.BaseStream, token);
            await process.StandardInput.WriteAsync(text.AsMemory(), token); process.StandardInput.Close();
            await process.WaitForExitAsync(token);
            var data = await stdout; await stderr;
            if (process.ExitCode != 0) throw new InvalidOperationException("Provider request failed. Check the selected login; no actions applied.");
            token.ThrowIfCancellationRequested();
            if (entry.Engine == "codex" && File.Exists(output)) return await File.ReadAllTextAsync(output, token);
            if (entry.Engine == "claude" && JsonNode.Parse(data) is JsonObject root && root["is_error"]?.GetValue<bool>() != true && root["result"] is { } result) return result.GetValue<string>();
            if (entry.Engine == "muse") foreach (var line in data.Split('\n').AsEnumerable().Reverse())
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                var row = JsonNode.Parse(line);
                if (row?["payload_type"]?.GetValue<string>() == "run.terminal.completed" && row["payload"]?["terminal"]?.GetValue<string>() == "completed") return row["payload"]!["text"]!.GetValue<string>();
            }
            throw new InvalidOperationException("Provider returned no completed final response.");
        }
        finally { try { Directory.Delete(folder, true); } catch { } }
    }
    private static async Task<string> ReadBounded(Stream stream, CancellationToken token)
    {
        using var output = new MemoryStream(); var buffer = new byte[8192]; int count;
        while ((count = await stream.ReadAsync(buffer, token)) > 0) { if (output.Length + count > 8_000_000) throw new InvalidDataException("Provider output exceeded limit."); output.Write(buffer, 0, count); }
        return Encoding.UTF8.GetString(output.ToArray());
    }
}
