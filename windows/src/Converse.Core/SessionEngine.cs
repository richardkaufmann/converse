using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Converse.Core;

// Session engine mirroring the Mac Store/Session turn pipeline for the
// claude/codex JSONL providers. Muse uses its exec JSON mode here; the
// long-lived MSP connection (approvals/questions) is milestone 3 and must
// not be faked: answer commands ack failed until then.
public sealed class AgentEntry
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Command { get; set; } = "";
    public string Directory { get; set; } = "";
    public string Engine { get; set; } = "";
    public string? AccountName { get; set; }
    public string? AccountDirectory { get; set; }
    public bool? UseDefaultAccountStore { get; set; }
}

public sealed class SessionChoices
{
    public string? Model { get; set; }
    public string? ModelProvider { get; set; }
    public string? ModelProfile { get; set; }
    public string? Effort { get; set; }
    public string? Access { get; set; }
    public string? Approval { get; set; }
}

public sealed class ChatMessage
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Role { get; set; } = "";
    public string Text { get; set; } = "";
    public List<string> Images { get; set; } = new();
    public DateTime? CreatedAt { get; set; }
    public string? FinalReply { get; set; }
}

public sealed class PendingPrompt
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Text { get; set; } = "";
    public List<string> Images { get; set; } = new();
}

public sealed class ChatSession
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "New session";
    public AgentEntry Entry { get; set; } = new();
    public List<ChatMessage> Messages { get; set; } = new();
    public List<PendingPrompt> Pending { get; set; } = new();
    public string Draft { get; set; } = "";
    public List<string> Attachments { get; set; } = new();
    public SessionChoices Choices { get; set; } = new();
    public string? RemoteID { get; set; }
    public bool Started { get; set; }
    public bool QueuePaused { get; set; }
    // Runtime-only state.
    [System.Text.Json.Serialization.JsonIgnore] public bool Busy { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] public string Status { get; set; } = "Ready";
    [System.Text.Json.Serialization.JsonIgnore] public bool TurnFailed { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] public bool Interrupted { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] internal bool StreamedText { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] internal bool ResumeAfterInterrupt { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] internal bool ClaudeTextBlockPending { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] internal List<(int Location, int Length)> ClaudeStreamSeparators { get; } = new();
    [System.Text.Json.Serialization.JsonIgnore] public List<MuseRequest> Requests { get; set; } = new();
    [System.Text.Json.Serialization.JsonIgnore] public bool AnsweringRequest { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] internal MuseMspClient? Muse { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] internal Dictionary<string, Guid> MuseItems { get; set; } = new();
    [System.Text.Json.Serialization.JsonIgnore] internal TaskCompletionSource<(string Status, string? Notice)>? MuseTurnDone { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] internal Process? RunningProcess { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] internal CancellationTokenSource? TurnCancellation { get; set; }
}

public interface IAgentRunner
{
    // Runs one turn, invoking onLine for each stdout/stderr line. Returns exit code.
    Task<int> RunAsync(ChatSession session, IReadOnlyList<string> arguments, string prompt,
        Action<string> onLine, CancellationToken cancellationToken);
}

public sealed class ProcessAgentRunner : IAgentRunner
{
    public async Task<int> RunAsync(ChatSession session, IReadOnlyList<string> arguments, string prompt,
        Action<string> onLine, CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        var allArgs = arguments.Append("--").Append(prompt);
        var resolved = CommandResolution.Resolve(session.Entry.Command)
            ?? new ResolvedCommand(session.Entry.Command, Array.Empty<string>(), session.Entry.Command);
        CommandResolution.Apply(start, resolved, allArgs);
        if (System.IO.Directory.Exists(session.Entry.Directory)) start.WorkingDirectory = session.Entry.Directory;
        start.Environment["NO_COLOR"] = "1";
        start.Environment["TERM"] = "dumb";
        if (!string.IsNullOrEmpty(session.Entry.AccountDirectory))
        {
            if (session.Entry.Engine == "codex")
            {
                start.Environment.Remove("CODEX_ACCESS_TOKEN");
                start.Environment.Remove("OPENAI_API_KEY");
                start.Environment["CODEX_HOME"] = session.Entry.AccountDirectory;
            }
            if (session.Entry.Engine == "claude")
            {
                start.Environment.Remove("ANTHROPIC_API_KEY");
                start.Environment.Remove("ANTHROPIC_AUTH_TOKEN");
                if (session.Entry.UseDefaultAccountStore != true)
                    start.Environment["CLAUDE_CONFIG_DIR"] = session.Entry.AccountDirectory;
            }
        }
        if (session.Entry.Engine == "claude" && session.Choices.Effort is { } effort)
            start.Environment["CLAUDE_CODE_EFFORT_LEVEL"] = effort;
        using var process = new Process { StartInfo = start };
        session.RunningProcess = process;
        process.Start();
        process.StandardInput.Close();
        using var registration = cancellationToken.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { /* already gone */ }
        });
        var outputTask = ReadLinesAsync(process.StandardOutput, onLine);
        var errorTask = ReadLinesAsync(process.StandardError, onLine);
        await process.WaitForExitAsync(CancellationToken.None);
        await Task.WhenAll(outputTask, errorTask);
        session.RunningProcess = null;
        return process.ExitCode;
    }

    private static async Task ReadLinesAsync(StreamReader reader, Action<string> onLine)
    {
        while (await reader.ReadLineAsync() is { } line) onLine(line);
    }
}

public static class TurnArguments
{
    public static List<string> For(ChatSession session, IReadOnlyList<string> images)
    {
        var choices = session.Choices;
        var entry = session.Entry;
        var args = new List<string>();
        if (entry.Engine == "claude")
        {
            args.AddRange(new[] { "--print", "--verbose", "--output-format", "stream-json", "--include-partial-messages" });
            if (session.Started || session.RemoteID is not null) { args.Add("--resume"); args.Add(session.RemoteID ?? session.Id.ToString("D")); }
            else { args.Add("--session-id"); args.Add(session.Id.ToString("D")); }
            if (choices.Model is not null) { args.Add("--model"); args.Add(choices.Model); }
            if (choices.Effort is not null) { args.Add("--effort"); args.Add(choices.Effort); }
            // "manual" is the CLI's vocabulary (claude --help); accept the Mac's legacy "default" id too.
            if (choices.Access is not null) { args.Add("--permission-mode"); args.Add(choices.Access == "default" ? "manual" : choices.Access); }
            foreach (var dir in images.Select(Path.GetDirectoryName).Where(d => d is not null).Distinct().OrderBy(d => d))
            { args.Add("--add-dir"); args.Add(dir!); }
        }
        else if (entry.Engine == "muse")
        {
            args.AddRange(new[] { "exec", "--json", "--session-id", session.Id.ToString("D") });
            if (choices.Model is not null) { args.Add("--model"); args.Add(choices.Model); }
            if (choices.Effort is not null) { args.Add("--reasoning-effort"); args.Add(choices.Effort); }
            if (choices.Access is not null) { args.Add("--permission-profile"); args.Add(choices.Access); }
            foreach (var image in images) { args.Add("--image"); args.Add(image); }
        }
        else
        {
            args.Add("exec");
            if (session.RemoteID is not null) { args.Add("resume"); args.Add(session.RemoteID); }
            args.AddRange(new[] { "--json", "--skip-git-repo-check" });
            if (choices.Model is not null) { args.Add("--model"); args.Add(choices.Model); }
            if (choices.Effort is not null) { args.Add("-c"); args.Add("model_reasoning_effort=" + Toml(choices.Effort)); }
            if (choices.Access is not null) { args.Add("-c"); args.Add("sandbox_mode=" + Toml(choices.Access)); }
            if (choices.Approval is not null) { args.Add("-c"); args.Add("approval_policy=" + Toml(choices.Approval)); }
            foreach (var image in images) { args.Add("--image"); args.Add(image); }
        }
        return args;
    }
    private static string Toml(string value) => "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
}

public sealed class SessionStore
{
    public string Folder { get; }
    public List<ChatSession> Sessions { get; private set; } = new();
    public List<AgentEntry> Entries { get; private set; } = new();
    public event Action? Changed;
    private readonly IAgentRunner _runner;
    private sealed class Archive
    {
        public List<AgentEntry> Entries { get; set; } = new();
        public List<ChatSession> Sessions { get; set; } = new();
    }

    public SessionStore(string folder, IAgentRunner? runner = null)
    {
        Folder = folder;
        _runner = runner ?? new ProcessAgentRunner();
        Directory.CreateDirectory(Folder);
        var file = Path.Combine(Folder, "sessions.json");
        if (File.Exists(file))
        {
            var archive = JsonSerializer.Deserialize<Archive>(File.ReadAllBytes(file));
            if (archive is not null) { Entries = archive.Entries; Sessions = archive.Sessions; }
        }
        if (Entries.Count == 0) Entries = DefaultEntries();
        // One-time repair: early builds named the claude entry "Muse" or
        // "Claude Code". Sessions embed their own entry copy, so repair
        // those too, plus untouched session titles that still carry a
        // default wrong name. Mac parity is "Claude".
        var renamed = false;
        foreach (var entry in Entries)
            if (entry.Engine == "claude" && entry.Name is "Muse" or "Claude Code") { entry.Name = "Claude"; renamed = true; }
        foreach (var session in Sessions.Where(s => s.Entry.Engine == "claude" && s.Entry.Name is "Muse" or "Claude Code"))
        {
            if (session.Title == session.Entry.Name) session.Title = "Claude";
            session.Entry.Name = "Claude";
            renamed = true;
        }
        if (renamed) Save();
    }

    public static List<AgentEntry> DefaultEntries() => new()
    {
        new AgentEntry { Name = "Claude", Command = "claude", Engine = "claude", Directory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) },
        new AgentEntry { Name = "Codex", Command = "codex", Engine = "codex", Directory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) },
        new AgentEntry { Name = "Muse", Command = "muse", Engine = "muse", Directory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) },
    };

    public ChatSession Create(AgentEntry entry)
    {
        var session = new ChatSession { Entry = entry, Title = entry.Name };
        session.Messages.Add(new ChatMessage { Role = "system", Text = "", CreatedAt = DateTime.UtcNow });
        Sessions.Add(session);
        Save();
        return session;
    }

    public void DeleteSession(ChatSession session)
    {
        Stop(session);
        Sessions.Remove(session);
        Save();
    }

    public void Save()
    {
        AtomicJson.Write(Path.Combine(Folder, "sessions.json"), new Archive { Entries = Entries, Sessions = Sessions });
        Changed?.Invoke();
    }

    public static string VisibleText(string text)
    {
        // Strip fenced switchboard command blocks from display text.
        var builder = new StringBuilder();
        var inFence = false;
        foreach (var line in text.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith("```converse")) { inFence = true; continue; }
            if (inFence && trimmed.StartsWith("```")) { inFence = false; continue; }
            if (!inFence) builder.Append(line).Append('\n');
        }
        return builder.ToString().Trim('\n');
    }

    // Mac Store.submit parity: a busy session (or a nonempty queue)
    // enqueues only — the user message enters the transcript when the turn
    // actually starts, so clearing a queued prompt leaves no trace of an
    // unsent message. Submitting unpauses the queue, like the Mac.
    public void Submit(ChatSession session)
    {
        var text = session.Draft;
        if (string.IsNullOrWhiteSpace(text) && session.Attachments.Count == 0) return;
        var images = new List<string>(session.Attachments);
        session.Draft = "";
        session.Attachments.Clear();
        if (text.Length == 0 && images.Count > 0) text = "Please examine the attached image.";
        if (session.Busy || session.Pending.Count > 0)
        {
            session.Pending.Add(new PendingPrompt { Text = text, Images = images });
            session.QueuePaused = false;
            if (!session.Busy) RunNext(session);
            Save();
            return;
        }
        AppendUserMessage(session, text, images);
        _ = RunTurnAsync(session, text, images);
    }

    public void RunNext(ChatSession session)
    {
        if (session.Busy || session.QueuePaused || session.Pending.Count == 0) return;
        var next = session.Pending[0];
        session.Pending.RemoveAt(0);
        AppendUserMessage(session, next.Text, next.Images);
        _ = RunTurnAsync(session, next.Text, next.Images);
    }

    // Mac injectPending parity: a named prompt moves to the front; with no
    // id the whole queue merges into one prompt. A busy session is
    // interrupted and the prompt runs when the old turn winds down (never
    // alongside it), via ResumeAfterInterrupt.
    public void InjectPending(ChatSession session, Guid? id = null)
    {
        if (session.Pending.Count == 0) return;
        if (id is null && session.Pending.Count > 1)
        {
            var merged = string.Join("\n\n", session.Pending.Select(p => p.Text));
            var images = session.Pending.SelectMany(p => p.Images).ToList();
            session.Pending.Clear();
            session.Pending.Add(new PendingPrompt { Text = merged, Images = images });
        }
        else if (id is not null)
        {
            var target = session.Pending.FirstOrDefault(p => p.Id == id);
            if (target is null) return;
            session.Pending.Remove(target);
            session.Pending.Insert(0, target);
        }
        session.QueuePaused = false;
        if (session.Busy) { session.ResumeAfterInterrupt = true; Stop(session); }
        else RunNext(session);
    }

    private static void AppendUserMessage(ChatSession session, string text, IReadOnlyList<string> images)
    {
        var first = !session.Messages.Any(m => m.Role == "user");
        session.Messages.Add(new ChatMessage
        { Role = "user", Text = text, Images = new List<string>(images), CreatedAt = DateTime.UtcNow });
        if (first && (session.Title == "New session" || session.Title == session.Entry.Name))
            session.Title = text.Length <= 45 ? text : text[..45];
    }

    public void Stop(ChatSession session)
    {
        session.Interrupted = true;
        session.TurnCancellation?.Cancel();
        if (session.Muse is not null) _ = session.Muse.InterruptAsync();
    }

    // Factory seam so tests can drive MSP over a loopback stream.
    public Func<AgentEntry, ChatSession, MuseMspClient>? MuseFactory { get; set; }

    private async Task RunMuseTurnAsync(ChatSession session, string prompt, IReadOnlyList<string> images)
    {
        session.Busy = true;
        session.Interrupted = false;
        session.ResumeAfterInterrupt = false;
        session.Status = "Connecting…";
        session.Requests.Clear();
        session.MuseItems.Clear();
        var response = new ChatMessage { Role = "assistant", Text = "", CreatedAt = DateTime.UtcNow };
        session.Messages.Add(response);
        var responseId = response.Id;
        var client = MuseFactory?.Invoke(session.Entry, session)
            ?? MuseMspClient.StartProcess(session.Entry, session.RemoteID ?? session.Id.ToString("D"));
        session.Muse = client;
        session.MuseTurnDone = new TaskCompletionSource<(string, string?)>(TaskCreationOptions.RunContinuationsAsynchronously);
        client.Event += (method, @params) => ConsumeMuse(method, @params, session, responseId);
        client.Disconnected += error => session.MuseTurnDone?.TrySetResult(("Disconnected", error));
        Save();
        try
        {
            await client.InitializeAsync();
            await client.LoadAsync(session.Entry, session.Choices);
            if (client.SettingWarning is { } warning) session.Messages.Add(new ChatMessage { Role = "notice", Text = warning });
            session.Started = true;
            session.RemoteID = client.SessionId;
            session.Status = "Working…";
            session.TurnCancellation = new CancellationTokenSource();
            using var registration = session.TurnCancellation.Token.Register(() => _ = client.InterruptAsync());
            await client.SubmitAsync(prompt, prompt, images, session.Choices.Effort);
            if (session.Interrupted) await client.InterruptAsync();
            var (status, notice) = await session.MuseTurnDone.Task;
            FinishMuse(session, status, notice);
        }
        catch (Exception error)
        {
            FinishMuse(session, "Connection failed", error.Message);
        }
    }

    private void FinishMuse(ChatSession session, string status, string? notice)
    {
        var client = session.Muse;
        session.Muse = null;
        client?.Dispose();
        session.Busy = false;
        session.Requests.Clear();
        session.AnsweringRequest = false;
        session.Status = status;
        session.Messages.RemoveAll(m => m.Role == "assistant" && string.IsNullOrEmpty(m.Text));
        if (!string.IsNullOrEmpty(notice)) session.Messages.Add(new ChatMessage { Role = "notice", Text = notice });
        // Mac finishQueue parity: an interrupted turn runs the queue only
        // when an inject asked for the resume; anything else held pauses.
        var shouldRun = status == "Ready" || (session.Interrupted && session.ResumeAfterInterrupt);
        session.ResumeAfterInterrupt = false;
        if (!shouldRun) session.QueuePaused = session.Pending.Count > 0;
        Save();
        if (shouldRun) RunNext(session);
        Changed?.Invoke();
    }

    public void ConsumeMuse(string method, System.Text.Json.Nodes.JsonObject @params, ChatSession session, Guid responseId)
    {
        switch (method)
        {
            case "turn/started":
                session.Busy = true;
                session.Muse!.TurnId = @params["turnId"]?.GetValue<string>();
                session.Status = "Working…";
                break;
            case "turn/completed":
                var terminal = @params["terminal"]?.GetValue<string>() ?? "unknown";
                var notice = (@params["error"] as System.Text.Json.Nodes.JsonObject)?["message"]?.GetValue<string>()
                    ?? @params["reason"]?.GetValue<string>();
                session.MuseTurnDone?.TrySetResult((terminal == "completed" ? "Ready" : char.ToUpperInvariant(terminal[0]) + terminal[1..], notice));
                break;
            case "session/statusChanged":
                var attention = (@params["attention"] as System.Text.Json.Nodes.JsonArray)?.Select(a => a?.GetValue<string>()).ToList() ?? new();
                if (attention.Contains("inputPending")) session.Status = "Waiting for your answer";
                else if (attention.Contains("approvalPending")) session.Status = "Waiting for approval";
                break;
            case "approval/request":
            case "userInput/request":
                var kind = method == "approval/request" ? "approval" : "question";
                var id = @params[kind == "approval" ? "approvalId" : "userInputId"]?.GetValue<string>() ?? "";
                if (string.IsNullOrEmpty(id)) return;
                session.Requests.RemoveAll(r => r.Id == id);
                session.Requests.Add(new MuseRequest { Id = id, Kind = kind, Params = @params });
                session.Status = kind == "approval" ? "Waiting for approval" : "Waiting for your answer";
                break;
            case "approval/updated":
                if (@params["approvalId"]?.GetValue<string>() is { } updatedId &&
                    session.Requests.FirstOrDefault(r => r.Id == updatedId) is { } existing)
                {
                    foreach (var pair in @params) existing.Params[pair.Key] = pair.Value?.DeepClone();
                }
                break;
            case "approval/resolved":
            case "userInput/settled":
                var settledId = @params["approvalId"]?.GetValue<string>() ?? @params["userInputId"]?.GetValue<string>();
                session.Requests.RemoveAll(r => r.Id == settledId);
                session.AnsweringRequest = false;
                session.Status = session.Requests.Count == 0 ? "Working…" : "Waiting for your answer";
                break;
            case "item/started":
            case "item/updated":
            case "item/completed":
                if (@params["item"] is System.Text.Json.Nodes.JsonObject item && item["itemId"]?.GetValue<string>() is { } itemId)
                {
                    if (item["kind"]?.GetValue<string>() == "agentMessage")
                    {
                        if (!session.MuseItems.ContainsKey(itemId))
                        {
                            if (session.MuseItems.Count == 0) session.MuseItems[itemId] = responseId;
                            else
                            {
                                var newId = Guid.NewGuid();
                                session.MuseItems[itemId] = newId;
                                session.Messages.Add(new ChatMessage { Id = newId, Role = "assistant", Text = "" });
                            }
                        }
                        if (item["text"]?.GetValue<string>() is { } value) UpdateMuseText(value, append: false, itemId, session);
                    }
                    else if (item["kind"]?.GetValue<string>() == "toolCall" && method == "item/completed" && item["status"]?.GetValue<string>() == "failed")
                        session.Messages.Add(new ChatMessage { Role = "notice", Text = item["failureReason"]?.GetValue<string>() ?? "Tool failed" });
                }
                break;
            case "item/delta":
                if ((@params["field"]?.GetValue<string>() ?? "text") == "text" &&
                    @params["itemId"]?.GetValue<string>() is { } deltaItem &&
                    @params["delta"]?.GetValue<string>() is { } delta)
                    UpdateMuseText(delta, append: true, deltaItem, session);
                break;
        }
        Changed?.Invoke();
    }

    private static void UpdateMuseText(string value, bool append, string itemId, ChatSession session)
    {
        if (!session.MuseItems.TryGetValue(itemId, out var id)) return;
        var message = session.Messages.FirstOrDefault(m => m.Id == id);
        if (message is null) return;
        message.Text = append ? message.Text + value : value;
    }

    public async Task<bool> AnswerMuseAsync(ChatSession session, MuseRequest request, string? choice = null,
        System.Text.Json.Nodes.JsonArray? answers = null, bool cancel = false)
    {
        if (session.Muse is not { } client || session.AnsweringRequest) return false;
        session.AnsweringRequest = true;
        try
        {
            if (request.Kind == "approval")
            {
                if (choice is null) { session.AnsweringRequest = false; return false; }
                await client.AnswerApprovalAsync(request, choice);
            }
            else await client.AnswerQuestionAsync(request, answers ?? new System.Text.Json.Nodes.JsonArray(), cancel);
            return true;
        }
        catch
        {
            session.AnsweringRequest = false;
            try
            {
                var (approvals, questions) = await client.ListPendingAsync();
                session.Requests = approvals.Concat(questions).ToList();
            }
            catch { /* keep current requests on refresh failure */ }
            return false;
        }
    }

    private async Task RunTurnAsync(ChatSession session, string prompt, IReadOnlyList<string> images)
    {
        if (session.Entry.Engine == "muse") { await RunMuseTurnAsync(session, prompt, images); return; }
        session.Busy = true;
        session.Interrupted = false;
        session.ResumeAfterInterrupt = false;
        session.TurnFailed = false;
        session.StreamedText = false;
        session.ClaudeTextBlockPending = false;
        session.ClaudeStreamSeparators.Clear();
        session.Status = "Working…";
        var response = new ChatMessage { Role = "assistant", Text = "", CreatedAt = DateTime.UtcNow };
        session.Messages.Add(response);
        session.TurnCancellation = new CancellationTokenSource();
        var args = TurnArguments.For(session, images);
        string? finalDirectory = null;
        if (session.Entry.Engine == "codex")
        {
            finalDirectory = Directory.CreateTempSubdirectory("converse-final-").FullName;
            args.Add("--output-last-message");
            args.Add(Path.Combine(finalDirectory, "answer.txt"));
        }
        Save();
        var exit = -1;
        try
        {
            exit = await _runner.RunAsync(session, args, prompt,
                line => Consume(line, session, response), session.TurnCancellation.Token);
        }
        catch (Exception error)
        {
            session.Messages.Add(new ChatMessage { Role = "notice", Text = error.Message });
        }
        string? finalReply = null;
        if (finalDirectory is not null)
        {
            var answerPath = Path.Combine(finalDirectory, "answer.txt");
            if (File.Exists(answerPath)) finalReply = await File.ReadAllTextAsync(answerPath);
            try { Directory.Delete(finalDirectory, recursive: true); } catch { /* temp cleanup best effort */ }
        }
        session.Busy = false;
        var success = exit == 0 && !session.TurnFailed;
        session.Status = session.Interrupted ? "Interrupted" : success ? "Ready" : "Failed · exit " + exit;
        if (exit == 0) session.Started = true;
        if (session.Entry.Engine == "codex" && success && !session.Interrupted)
        {
            response.FinalReply = finalReply;
            if (string.IsNullOrEmpty(response.Text) && finalReply is not null)
                response.Text = VisibleText(finalReply);
        }
        if (string.IsNullOrEmpty(response.Text)) session.Messages.Remove(response);
        var shouldRun = success || (session.Interrupted && session.ResumeAfterInterrupt);
        session.ResumeAfterInterrupt = false;
        if (!shouldRun) session.QueuePaused = session.Pending.Count > 0;
        Save();
        if (shouldRun) RunNext(session);
        Changed?.Invoke();
    }

    // JSONL consumption mirroring Store.consume for claude/codex/muse-exec.
    public void Consume(string line, ChatSession session, ChatMessage response)
    {
        if (string.IsNullOrEmpty(line)) return;
        JsonDocument? doc;
        try { doc = JsonDocument.Parse(line); }
        catch { session.Messages.Add(new ChatMessage { Role = "activity", Text = line }); return; }
        using var document = doc;
        var obj = document.RootElement;
        string? text = null;
        var replace = false;
        var delta = false;
        var startsTextBlock = false;
        var type = GetString(obj, "type") ?? "";
        if (session.Entry.Engine == "muse")
        {
            var kind = GetString(obj, "payload_type") ?? "";
            var payload = obj.TryGetProperty("payload", out var p) ? p : default;
            if (kind.StartsWith("run.terminal")) { text = GetString(payload, "text"); replace = true; }
            else if (kind == "run.output.delta" || kind.Contains("text.delta") || kind.Contains("text_delta"))
            { text = GetString(payload, "delta") ?? GetString(payload, "text"); delta = true; }
        }
        else if (session.Entry.Engine == "claude")
        {
            if (GetString(obj, "session_id") is { } sid) session.RemoteID = sid;
            if (type == "stream_event" && obj.TryGetProperty("event", out var ev) && ev.ValueKind == JsonValueKind.Object)
            {
                if (GetString(ev, "type") == "content_block_start" && ev.TryGetProperty("content_block", out var started)
                    && started.ValueKind == JsonValueKind.Object && GetString(started, "type") == "text")
                {
                    session.ClaudeTextBlockPending = true;
                    if (GetString(started, "text") is { } initial && initial.Length > 0)
                    {
                        text = initial; delta = true; startsTextBlock = true;
                        session.ClaudeTextBlockPending = false; session.StreamedText = true;
                    }
                }
                if (ev.TryGetProperty("delta", out var chunk) && chunk.ValueKind == JsonValueKind.Object
                    && GetString(chunk, "type") == "text_delta" && GetString(chunk, "text") is { } value && value.Length > 0)
                {
                    text = value; delta = true; startsTextBlock = session.ClaudeTextBlockPending;
                    session.ClaudeTextBlockPending = false; session.StreamedText = true;
                }
            }
            if (type == "assistant" && obj.TryGetProperty("message", out var message) &&
                message.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.Array)
            {
                foreach (var block in content.EnumerateArray())
                {
                    if (GetString(block, "text") is { } value && !session.StreamedText) text = (text ?? "") + value;
                    if (GetString(block, "type") == "tool_use")
                        session.Messages.Add(new ChatMessage { Role = "activity", Text = "Using " + (GetString(block, "name") ?? "tool") });
                }
            }
            else if (type == "result")
            {
                if (obj.TryGetProperty("is_error", out var isError) && isError.ValueKind == JsonValueKind.True) session.TurnFailed = true;
                if (GetString(obj, "result") is { } result)
                {
                    // Some CLI final snapshots join text blocks directly.
                    // Keep only our display separators when the content is
                    // otherwise byte-for-byte the same; genuine corrections
                    // and error results still replace the accumulated text.
                    var accumulated = response.Text;
                    var unseparated = accumulated;
                    foreach (var (location, length) in session.ClaudeStreamSeparators.OrderByDescending(s => s.Location))
                        if (location + length <= unseparated.Length) unseparated = unseparated.Remove(location, length);
                    text = !session.TurnFailed && session.ClaudeStreamSeparators.Count > 0 && unseparated == result
                        ? accumulated : result;
                    replace = true;
                }
            }
        }
        else
        {
            if (type == "thread.started") session.RemoteID = GetString(obj, "thread_id");
            if (type == "item.completed" && obj.TryGetProperty("item", out var item))
            {
                if (GetString(item, "type") == "agent_message") text = GetString(item, "text");
                else if (GetString(item, "command") is { } command)
                    session.Messages.Add(new ChatMessage { Role = "activity", Text = command });
            }
            if (type is "error" or "turn.failed")
            {
                session.TurnFailed = true;
                session.Messages.Add(new ChatMessage { Role = "notice", Text = GetString(obj, "message") ?? "Command failed" });
            }
        }
        if (text is null) return;
        var visible = VisibleText(text);
        if (string.IsNullOrEmpty(visible)) return;
        string separator;
        if (string.IsNullOrEmpty(response.Text)) separator = "";
        else if (startsTextBlock && !response.Text.EndsWith('\n')) separator = "\n\n";
        else if (delta) separator = "";
        else separator = "\n";
        if (session.Entry.Engine == "claude" && startsTextBlock && !replace && separator.Length > 0)
            session.ClaudeStreamSeparators.Add((response.Text.Length, separator.Length));
        response.Text = replace ? visible : response.Text + separator + visible;
    }

    private static string? GetString(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;
}

