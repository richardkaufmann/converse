using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace Converse.Core;

public sealed record CodexModel(string Id, string Label, string[] Efforts, bool IsDefault);
public sealed record CodexCatalogResult(IReadOnlyList<CodexModel> Models, DateTime ExpiresAt, string? Error = null)
{
    public string[] EffortsFor(string? selected) =>
        (Models.FirstOrDefault(m => m.Id == selected) ?? (selected is null ? Models.FirstOrDefault(m => m.IsDefault) : null))?.Efforts
        ?? ChoicesCatalog.EffortsFor("codex").ToArray();
}

// Read-only app-server discovery, scoped to the same executable, working
// directory and login as inference. Never starts/resumes a thread or a turn.
public sealed class CodexModelCatalog
{
    private readonly object _gate = new();
    private readonly Dictionary<string, Task<CodexCatalogResult>> _cache = new();
    internal Func<AgentEntry, Task<IReadOnlyList<CodexModel>>> Probe { get; set; } = QueryAsync;
    public static string Key(AgentEntry e) => System.Text.Json.JsonSerializer.Serialize(new { e.Command, e.Directory, e.AccountDirectory, e.UseDefaultAccountStore });
    public CodexCatalogResult? Cached(AgentEntry e)
    {
        lock (_gate) return _cache.TryGetValue(Key(e), out var task) && task.IsCompletedSuccessfully ? task.Result : null;
    }
    public Task<CodexCatalogResult> GetAsync(AgentEntry entry)
    {
        var copy = entry.Copy(); var key = Key(copy);
        lock (_gate)
        {
            if (_cache.TryGetValue(key, out var existing) && (!existing.IsCompleted || existing.Result.ExpiresAt > DateTime.UtcNow)) return existing;
            return _cache[key] = LoadAsync(copy);
        }
    }
    private async Task<CodexCatalogResult> LoadAsync(AgentEntry entry)
    {
        try { return new(await Probe(entry), DateTime.UtcNow.AddMinutes(5)); }
        catch { return new(Array.Empty<CodexModel>(), DateTime.UtcNow.AddSeconds(30), "Could not read the Codex model catalog on this home. Check its CLI login; custom model IDs remain available."); }
    }
    internal static async Task<IReadOnlyList<CodexModel>> ReadAsync(Func<string, JsonObject, Task<JsonObject>> rpc)
    {
        await rpc("initialize", new() { ["clientInfo"] = new JsonObject { ["name"] = "converse", ["version"] = "0.5" }, ["capabilities"] = new JsonObject { ["experimentalApi"] = true } });
        var models = new List<CodexModel>(); var ids = new HashSet<string>(); var cursors = new HashSet<string>(); string? cursor = null;
        for (var page = 0; page < 32; page++)
        {
            var args = new JsonObject { ["includeHidden"] = true }; if (cursor is not null) args["cursor"] = cursor;
            var result = await rpc("model/list", args);
            foreach (var row in (result["data"] as JsonArray ?? new()).OfType<JsonObject>())
            {
                var id = row["model"]?.GetValue<string>();
                if (string.IsNullOrWhiteSpace(id) || id.Length > 256 || !ids.Add(id)) continue;
                var label = row["displayName"]?.GetValue<string>() ?? id;
                var efforts = (row["supportedReasoningEfforts"] as JsonArray ?? new()).OfType<JsonObject>().Select(e => e["reasoningEffort"]?.GetValue<string>()).Where(e => !string.IsNullOrWhiteSpace(e)).Cast<string>().Distinct().ToArray();
                models.Add(new(id, label.Length > 256 ? id : label, efforts, row["isDefault"]?.GetValue<bool>() == true));
                if (models.Count > 4096) throw new InvalidDataException("Catalog too large");
            }
            cursor = result["nextCursor"]?.GetValue<string>();
            if (string.IsNullOrEmpty(cursor)) return models.AsReadOnly();
            if (!cursors.Add(cursor)) throw new InvalidDataException("Repeated catalog cursor");
        }
        throw new InvalidDataException("Too many catalog pages");
    }
    private static async Task<IReadOnlyList<CodexModel>> QueryAsync(AgentEntry entry)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20)); var token = timeout.Token;
        var start = new ProcessStartInfo { RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true, StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false) };
        var resolved = CommandResolution.Resolve(entry.Command) ?? throw new FileNotFoundException("Codex executable unavailable");
        CommandResolution.Apply(start, resolved, new[] { "app-server" });
        if (Directory.Exists(entry.Directory)) start.WorkingDirectory = entry.Directory;
        start.Environment["NO_COLOR"] = "1";
        // Match ProcessAgentRunner's per-login binding; never copy credentials.
        if (!string.IsNullOrEmpty(entry.AccountDirectory))
        {
            start.Environment.Remove("CODEX_ACCESS_TOKEN"); start.Environment.Remove("OPENAI_API_KEY"); start.Environment["CODEX_HOME"] = entry.AccountDirectory;
        }
        start.Environment.Remove("CREDENTIALS_DIRECTORY");
        using var process = new Process { StartInfo = start }; process.Start();
        using var cancel = token.Register(() => { try { if (!process.HasExited) process.Kill(true); } catch { } });
        // Discard diagnostics without retaining credentials or unbounded stderr.
        var stderr = process.StandardError.BaseStream.CopyToAsync(Stream.Null, token);
        var nextID = 0;
        try
        {
            return await ReadAsync(async (method, args) =>
            {
                var id = ++nextID;
                await process.StandardInput.WriteLineAsync(new JsonObject { ["id"] = id, ["method"] = method, ["params"] = args }.ToJsonString().AsMemory(), token);
                await process.StandardInput.FlushAsync(token);
                while (true)
                {
                    var line = await process.StandardOutput.ReadLineAsync(token) ?? throw new EndOfStreamException();
                    if (line.Length > 2_000_000) throw new InvalidDataException("Catalog frame too large");
                    var response = JsonNode.Parse(line) as JsonObject;
                    if (response?["id"]?.ToString() != id.ToString()) continue;
                    if (response["error"] is not null) throw new InvalidDataException("Codex rejected catalog request");
                    if (method == "initialize")
                    {
                        await process.StandardInput.WriteLineAsync("{\"method\":\"initialized\",\"params\":{}}".AsMemory(), token);
                        await process.StandardInput.FlushAsync(token);
                    }
                    return response["result"] as JsonObject ?? new();
                }
            });
        }
        finally
        {
            try { process.StandardInput.Close(); if (!process.HasExited) process.Kill(true); } catch { }
            try { await stderr; } catch { }
        }
    }
}
