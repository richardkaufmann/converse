using System.Net.Http.Headers;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Converse.Core;

/// <summary>Read only selected Home Assistant states; the model never receives a credential.</summary>
public static class HomeAssistantAgent
{
    public static (Uri? Address, string[] Entities) Validate(string? address, string? entityText, bool enabled)
    {
        var raw = (address ?? "").Trim();
        Uri? uri = null;
        if (raw.Length > 0)
        {
            if (raw.Length > 500 || !Uri.TryCreate(raw, UriKind.Absolute, out uri) ||
                uri.Scheme is not ("http" or "https") || !string.IsNullOrEmpty(uri.UserInfo) ||
                !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
                throw new ArgumentException("Enter a Home Assistant HTTP(S) address without a login, query or fragment.");
        }
        var ids = (entityText ?? "").Split([',', ' ', '\t', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Distinct(StringComparer.Ordinal).OrderBy(x => x, StringComparer.Ordinal).ToArray();
        if (ids.Length > 32 || ids.Any(id => id.Length > 128 || !Regex.IsMatch(id, @"^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$")))
            throw new ArgumentException("Choose up to 32 Home Assistant entity IDs, such as sensor.living_room_temperature.");
        if (enabled && (uri is null || ids.Length == 0))
            throw new ArgumentException("Choose a Home Assistant address and at least one entity before enabling reading.");
        return (uri, ids);
    }

    private static Uri Endpoint(Uri baseUri, string? id = null)
    {
        var path = baseUri.AbsolutePath.TrimEnd('/') + "/api/" + (id is null ? "" : "states/" + id);
        return new UriBuilder(baseUri) { Path = path }.Uri;
    }

    private static async Task<JsonObject> GetAsync(HttpClient client, Uri url, string token, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.ParseAdd("application/json");
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException(response.StatusCode == System.Net.HttpStatusCode.Unauthorized
            ? "Home Assistant rejected the token." : $"Home Assistant returned HTTP {(int)response.StatusCode}.");
        if (response.Content.Headers.ContentLength > 262144) throw new InvalidOperationException("Home Assistant response is too large.");
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellation);
        if (bytes.Length > 262144) throw new InvalidOperationException("Home Assistant response is too large.");
        return JsonNode.Parse(bytes) as JsonObject ?? throw new InvalidOperationException("Home Assistant returned invalid JSON.");
    }

    public static async Task<string> TestAsync(string? address, string? entityText, string? token, CancellationToken cancellation = default)
    {
        var (uri, ids) = Validate(address, entityText, true);
        if (string.IsNullOrWhiteSpace(token)) throw new ArgumentException("Enter a Home Assistant token or save one first.");
        using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(12) };
        var root = await GetAsync(client, Endpoint(uri!), token, cancellation);
        if (root["message"]?.GetValue<string>() != "API running.") throw new ArgumentException("Home Assistant did not confirm its API is running.");
        var started = DateTime.UtcNow;
        foreach (var id in ids)
        {
            if (DateTime.UtcNow - started > TimeSpan.FromSeconds(20)) throw new ArgumentException("Home Assistant test took too long. Try fewer entities or check the network.");
            _ = await GetAsync(client, Endpoint(uri!, id), token, cancellation);
        }
        return $"Home Assistant connected. {ids.Length} selected entities readable. Nothing was changed.";
    }

    public static async Task<JsonObject> EvidenceAsync(string? address, string? entityText, string? token, CancellationToken cancellation)
    {
        try
        {
            var (uri, ids) = Validate(address, entityText, true);
            if (string.IsNullOrWhiteSpace(token)) return new() { ["error"] = "Home Assistant token missing; add it in Agent Setup." };
            using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(12) };
            var rows = new JsonArray();
            var started = DateTime.UtcNow;
            foreach (var id in ids)
            {
                cancellation.ThrowIfCancellationRequested();
                if (DateTime.UtcNow - started > TimeSpan.FromSeconds(20))
                {
                    rows.Add(new JsonObject { ["entityID"] = id, ["error"] = "Lookup time budget exhausted; state unknown." });
                    continue;
                }
                try
                {
                    var state = await GetAsync(client, Endpoint(uri!, id), token, cancellation);
                    if (state["entity_id"]?.GetValue<string>() != id || state["state"] is null) throw new InvalidOperationException("Mismatched entity.");
                    var attributes = state["attributes"] as JsonObject;
                    rows.Add(new JsonObject {
                        ["entityID"] = id,
                        ["state"] = Clip(state["state"]?.GetValue<string>(), 256),
                        ["name"] = Clip(attributes?["friendly_name"]?.GetValue<string>() ?? id, 120),
                        ["unit"] = Clip(attributes?["unit_of_measurement"]?.GetValue<string>(), 32),
                        ["lastChanged"] = Clip(state["last_changed"]?.GetValue<string>(), 64)
                    });
                }
                catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { throw; }
                catch { rows.Add(new JsonObject { ["entityID"] = id, ["error"] = "Unavailable on this check; do not assume the entity is off." }); }
            }
            return new() { ["source"] = uri!.ToString(), ["observedAt"] = DateTime.UtcNow.ToString("O"), ["entities"] = rows,
                ["scope"] = "Read-only states for explicitly selected entities; no actions or hidden attributes." };
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { throw; }
        catch (ArgumentException ex) { return new() { ["error"] = ex.Message }; }
    }

    private static string Clip(string? value, int max) => (value ?? "")[..Math.Min(value?.Length ?? 0, max)];
}
