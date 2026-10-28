using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Converse.Core;

// Muse MSP client mirroring Sources/MuseConnection.swift: one `muse serve`
// host per conversation over stdio JSON-RPC. Approval/question RPCs get an
// immediate presentation receipt; decisions go through AnswerAsync with the
// server-minted choice IDs and current requirement ID (race-guarded).
public sealed class MuseRequest
{
    public required string Id { get; init; }
    public required string Kind { get; init; } // approval | question
    public JsonObject Params { get; set; } = new();
}

public sealed class MuseMspClient : IDisposable
{
    private readonly Stream _input;
    private readonly Stream _output;
    private readonly Process? _process;
    private int _nextId;
    private readonly Dictionary<int, TaskCompletionSource<JsonObject>> _callbacks = new();
    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private bool _closing;
    public string SessionId { get; private set; }
    public string? TurnId { get; set; }
    public string? SettingWarning { get; private set; }
    public event Action<string, JsonObject>? Event;
    public event Action<string>? Disconnected;

    private MuseMspClient(string sessionId, Stream input, Stream output, Process? process)
    {
        SessionId = sessionId.ToLowerInvariant();
        _input = input; _output = output; _process = process;
        _ = ReadLoopAsync();
    }

    public static MuseMspClient StartProcess(AgentEntry entry, string sessionId, IReadOnlyList<string>? serverArguments = null)
    {
        var start = new ProcessStartInfo
        {
            FileName = entry.Command,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        start.ArgumentList.Add("serve");
        foreach (var arg in serverArguments ?? Array.Empty<string>()) start.ArgumentList.Add(arg);
        if (Directory.Exists(entry.Directory)) start.WorkingDirectory = entry.Directory;
        start.Environment["NO_COLOR"] = "1";
        var process = new Process { StartInfo = start };
        process.Start();
        return new MuseMspClient(sessionId, process.StandardInput.BaseStream, process.StandardOutput.BaseStream, process);
    }

    // Test seam: any duplex stream (loopback TCP in tests).
    public static MuseMspClient OverStream(string sessionId, Stream duplex) =>
        new(sessionId, duplex, duplex, null);

    public static string CommandId()
    {
        var time = ((ulong)(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())).ToString("x12");
        var random = Guid.NewGuid().ToString("N").ToLowerInvariant();
        return $"{time[..8]}-{time[8..]}-7{random[..3]}-8{random[3..6]}-{random[6..18]}";
    }

    public async Task InitializeAsync(CancellationToken token = default)
    {
        await RpcAsync("initialize", new JsonObject
        {
            ["clientInfo"] = new JsonObject { ["name"] = "converse", ["version"] = "0.4" },
            ["capabilities"] = new JsonObject { ["userInputDialogs"] = true, ["experimentalApi"] = true },
        }, token);
        await WriteAsync(new JsonObject { ["jsonrpc"] = "2.0", ["method"] = "initialized", ["params"] = new JsonObject() });
    }

    public async Task LoadAsync(AgentEntry entry, SessionChoices choices, CancellationToken token = default)
    {
        SettingWarning = null;
        JsonObject result;
        bool exists;
        try
        {
            await RpcAsync("session/read", new JsonObject { ["sessionId"] = SessionId, ["excludeItems"] = true }, token);
            exists = true;
        }
        catch (MuseRpcException error) when (error.Kind == "sessionNotFound") { exists = false; }
        if (exists)
        {
            var resume = BaseParams();
            if (choices.Access is not null) resume["permissionProfile"] = choices.Access;
            resume["excludeItems"] = true;
            result = await RpcAsync("session/resume", resume, token);
        }
        else
        {
            if (SessionId.Split('-').Skip(2).FirstOrDefault()?.StartsWith("7") != true) SessionId = CommandId();
            var startParams = BaseParams();
            if (choices.Access is not null) startParams["permissionProfile"] = choices.Access;
            startParams["workspaceRoot"] = entry.Directory;
            if (choices.Model is not null) startParams["modelId"] = choices.Model;
            result = await RpcAsync("session/start", startParams, token);
        }
        _ = result;
        if (choices.Model is { } model)
        {
            try { await ChangeModelAsync(model, choices.ModelProvider, choices.ModelProfile, token); }
            catch (Exception error)
            {
                SettingWarning = "Saved model selection could not be applied: " + error.Message + ". Continuing with the session's current model.";
            }
        }
    }

    private JsonObject BaseParams() => new() { ["commandId"] = CommandId(), ["sessionId"] = SessionId };

    public Task ChangeModelAsync(string modelId, string? provider, string? profile, CancellationToken token = default)
    {
        var selection = new JsonObject { ["modelId"] = modelId };
        if (!string.IsNullOrEmpty(provider)) selection["providerId"] = provider;
        if (profile is not null) selection["profileId"] = profile;
        var p = BaseParams(); p["model"] = selection;
        return RpcAsync("session/setModel", p, token);
    }

    public async Task SubmitAsync(string prompt, string display, IReadOnlyList<string> images, string? effort, CancellationToken token = default)
    {
        var parts = new JsonArray { new JsonObject { ["type"] = "text", ["text"] = prompt } };
        foreach (var path in images)
            parts.Add(new JsonObject { ["type"] = "image", ["mediaType"] = "image/png", ["base64Data"] = Convert.ToBase64String(await File.ReadAllBytesAsync(path, token)) });
        var p = BaseParams();
        p["input"] = parts; p["displayText"] = display; p["ifBusy"] = "queue";
        if (effort is not null) p["reasoningEffort"] = effort;
        var result = await RpcAsync("turn/start", p, token);
        TurnId = result["turnId"]?.GetValue<string>();
    }

    public async Task InterruptAsync()
    {
        var p = BaseParams();
        if (TurnId is not null) p["turnId"] = TurnId;
        try { await RpcAsync("turn/interrupt", p); } catch { /* best effort */ }
    }

    public async Task AnswerApprovalAsync(MuseRequest request, string choiceId, CancellationToken token = default)
    {
        var requirement = request.Params["currentRequirementId"]?.DeepClone()
            ?? throw new InvalidOperationException("Approval is missing its requirement ID.");
        var choices = request.Params["availableChoices"] as JsonArray ?? new JsonArray();
        if (!choices.Any(c => c?["choiceId"]?.GetValue<string>() == choiceId))
            throw new InvalidOperationException("Choice is no longer offered for this approval.");
        var p = BaseParams();
        p["approvalId"] = request.Id; p["choiceId"] = choiceId; p["requirementId"] = requirement;
        await RpcAsync("approval/decide", p, token);
    }

    public async Task AnswerQuestionAsync(MuseRequest request, JsonArray answers, bool cancel = false, CancellationToken token = default)
    {
        var p = BaseParams();
        p["userInputId"] = request.Id;
        if (cancel) { await RpcAsync("userInput/cancel", p, token); return; }
        p["answers"] = answers;
        await RpcAsync("userInput/answer", p, token);
    }

    public async Task<(List<MuseRequest> Approvals, List<MuseRequest> Questions)> ListPendingAsync(CancellationToken token = default)
    {
        var value = await RpcAsync("approval/listPending", new JsonObject { ["sessionId"] = SessionId }, token);
        List<MuseRequest> Map(string key, string idKey, string kind) =>
            (value[key] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
                .Where(p => p[idKey] is not null)
                .Select(p => new MuseRequest { Id = p[idKey]!.GetValue<string>(), Kind = kind, Params = p }).ToList();
        return (Map("approvals", "approvalId", "approval"), Map("userInputs", "userInputId", "question"));
    }

    public async Task<JsonObject> RpcAsync(string method, JsonObject @params, CancellationToken token = default)
    {
        var id = Interlocked.Increment(ref _nextId);
        var completion = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_callbacks) _callbacks[id] = completion;
        await WriteAsync(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = method, ["params"] = @params });
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try { return await completion.Task.WaitAsync(timeout.Token); }
        catch (OperationCanceledException)
        {
            lock (_callbacks) _callbacks.Remove(id);
            throw new MuseRpcException("Muse did not acknowledge " + method + ". The operation may still be running; check session status before retrying.", null);
        }
    }

    private async Task WriteAsync(JsonObject payload)
    {
        var bytes = Encoding.UTF8.GetBytes(payload.ToJsonString() + "\n");
        await _writeLock.WaitAsync();
        try { await _input.WriteAsync(bytes); await _input.FlushAsync(); }
        finally { _writeLock.Release(); }
    }

    private async Task ReadLoopAsync()
    {
        using var reader = new StreamReader(_output, Encoding.UTF8, leaveOpen: true);
        try
        {
            while (await reader.ReadLineAsync() is { } line)
            {
                if (JsonNode.Parse(line) is not JsonObject obj) continue;
                await ReceiveAsync(obj);
            }
        }
        catch { /* fall through to closed */ }
        Closed();
    }

    private async Task ReceiveAsync(JsonObject obj)
    {
        if (obj["method"]?.GetValue<string>() is { } method)
        {
            var @params = obj["params"] as JsonObject ?? new JsonObject();
            var session = @params["sessionId"]?.GetValue<string>();
            if (session is not null && !string.Equals(session, SessionId, StringComparison.OrdinalIgnoreCase)) return;
            Event?.Invoke(method, @params);
            if (obj["id"] is { } id && method is "approval/request" or "userInput/request")
                await WriteAsync(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id.DeepClone(), ["result"] = new JsonObject() });
        }
        else if (obj["id"]?.GetValue<int>() is { } id)
        {
            TaskCompletionSource<JsonObject>? completion;
            lock (_callbacks) { _callbacks.Remove(id, out completion); }
            if (completion is null) return;
            if (obj["error"] is JsonObject error)
            {
                var detail = error["data"] as JsonObject;
                completion.TrySetException(new MuseRpcException(
                    error["message"]?.GetValue<string>() ?? "Muse rejected the request",
                    detail?["kind"]?.GetValue<string>()));
            }
            else completion.TrySetResult(obj["result"] as JsonObject ?? new JsonObject());
        }
    }

    private void Closed()
    {
        List<TaskCompletionSource<JsonObject>> pending;
        lock (_callbacks) { pending = _callbacks.Values.ToList(); _callbacks.Clear(); }
        foreach (var completion in pending)
            completion.TrySetException(new MuseRpcException("Muse connection closed.", null));
        if (!_closing) Disconnected?.Invoke("Muse connection closed.");
        _closing = true;
    }

    public void Dispose()
    {
        _closing = true;
        try { _input.Dispose(); } catch { /* process streams */ }
        try { if (_process is { HasExited: false }) _process.Kill(entireProcessTree: true); } catch { /* already gone */ }
        _process?.Dispose();
    }
}

public sealed class MuseRpcException(string message, string? kind) : Exception(message)
{
    public string? Kind { get; } = kind;
}
