using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Converse.Linux;

internal enum StartupAdmission
{
    Open,
    Probation,
    RecoveryRequired,
}

internal interface ILinuxUpdateRuntime
{
    int OutstandingWorkCount { get; }
    bool IsWorkQuiescent();
    bool FabricStarted { get; }
    void SetAcceptingWork(bool accepting);
    Task StartFabricAsync(CancellationToken cancellationToken);
    void RequestRestart(string reason);
}

internal sealed class LinuxUpdateState
{
    [JsonPropertyName("currentReleaseID")] public string? CurrentReleaseID { get; set; }
    [JsonPropertyName("previousReleaseID")] public string? PreviousReleaseID { get; set; }
    [JsonPropertyName("stagedReleaseID")] public string? StagedReleaseID { get; set; }
    [JsonPropertyName("supervisor")] public string Supervisor { get; set; } = "none";
    [JsonPropertyName("uploads")] public List<StagedUpload> Uploads { get; set; } = new();
}

internal sealed class StagedUpload
{
    [JsonPropertyName("uploadID")] public Guid UploadID { get; set; }
    [JsonPropertyName("releaseID")] public string ReleaseID { get; set; } = "";
    [JsonPropertyName("bundleSHA256")] public string BundleSHA256 { get; set; } = "";
    [JsonPropertyName("bundleSize")] public long BundleSize { get; set; }
    [JsonPropertyName("uploadPath")] public string UploadPath { get; set; } = "";
    [JsonPropertyName("expiresAt")] public string ExpiresAt { get; set; } = "";
    [JsonPropertyName("verified")] public bool Verified { get; set; }
    [JsonPropertyName("artifactSHA256")] public string? ArtifactSHA256 { get; set; }
}

internal sealed class LinuxUpdateManager
{
    private readonly LinuxPaths _paths;
    private readonly RecoveryLedgerStore _ledger;
    private readonly ReleaseBundleVerifier _verifier;
    private readonly ILinuxUpdateRuntime _runtime;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private LinuxUpdateState _state = new();
    private Task? _activationTask;

    public LinuxUpdateManager(
        LinuxPaths paths,
        RecoveryLedgerStore ledger,
        ReleaseBundleVerifier verifier,
        ILinuxUpdateRuntime runtime,
        string initialReleaseID,
        string initialSupervisor = "none")
    {
        _paths = paths;
        _ledger = ledger;
        _verifier = verifier;
        _runtime = runtime;
        LoadState(initialReleaseID, initialSupervisor);
    }

    public LinuxUpdateState Snapshot()
    {
        // Caller either holds the manager gate or accepts this point-in-time
        // clone for status. State objects are cloned so callers cannot mutate.
        var bytes = JsonSerializer.SerializeToUtf8Bytes(_state, DurableJson.Options);
        return JsonSerializer.Deserialize<LinuxUpdateState>(bytes, DurableJson.Options) ?? new LinuxUpdateState();
    }

    public async Task SetSupervisorAsync(string supervisor, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            _state.Supervisor = supervisor;
            SaveState();
        }
        finally { _gate.Release(); }
    }

    public async Task<StageBeginResult> StageBeginAsync(
        string releaseID, string bundleSHA256, long bundleSize,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var ledger = await _ledger.SnapshotAsync(cancellationToken);
            if (ledger.UpdateEpisode is { Phase: "draining_old_release" or "activating_new_release" or "probation_new_release" })
                throw new AdminException("admission_closed", "An update episode is already active.");
            CleanupExpiredUploads();
            var uploadID = Guid.NewGuid();
            var token = Guid.NewGuid().ToString("N") + Guid.NewGuid().ToString("N")[..8];
            var upload = new StagedUpload
            {
                UploadID = uploadID,
                ReleaseID = releaseID,
                BundleSHA256 = bundleSHA256,
                BundleSize = bundleSize,
                UploadPath = Path.Combine(_paths.IncomingDirectory, token + ".tar.gz"),
                ExpiresAt = LinuxTime.Format(DateTimeOffset.UtcNow.AddHours(2)),
            };
            _state.Uploads.Add(upload);
            SaveState();
            return new StageBeginResult
            {
                UploadID = upload.UploadID,
                UploadPath = upload.UploadPath,
                ExpiresAt = upload.ExpiresAt,
            };
        }
        finally { _gate.Release(); }
    }

    public async Task<StageVerifyResult> StageVerifyAsync(
        Guid uploadID, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            CleanupExpiredUploads();
            var upload = _state.Uploads.FirstOrDefault(item => item.UploadID == uploadID)
                ?? throw new AdminException("stage_verification_failed", "The staged upload was not found or expired.");
            var verified = _verifier.VerifyAndInstall(
                upload.UploadPath, upload.BundleSHA256, upload.BundleSize);
            if (verified.Manifest.ReleaseID != upload.ReleaseID)
                throw new AdminException(
                    "stage_verification_failed",
                    "The signed manifest release ID does not match the staged upload.");
            upload.Verified = true;
            upload.ArtifactSHA256 = verified.ArtifactSHA256;
            _state.StagedReleaseID = verified.Manifest.ReleaseID;
            SaveState();
            return new StageVerifyResult
            {
                ReleaseID = verified.Manifest.ReleaseID,
                ArtifactSHA256 = verified.ArtifactSHA256,
            };
        }
        finally { _gate.Release(); }
    }

    public async Task<StartupAdmission> ReconcileStartupAsync(
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var ledger = await _ledger.SnapshotAsync(cancellationToken);
            var episode = ledger.UpdateEpisode;
            if (episode is null)
            {
                await CompleteServiceRestartsAsync(ledger, cancellationToken);
                return StartupAdmission.Open;
            }

            switch (episode.Phase)
            {
                case "draining_old_release":
                {
                    var aborted = episode.Clone();
                    aborted.Phase = "aborted";
                    aborted.ExplicitResolutionRequired = false;
                    aborted.Health = "not_applicable";
                    aborted.UpdatedAt = LinuxTime.Now();
                    await _ledger.SetEpisodeAsync(aborted, cancellationToken);
                    await TransitionEpisodeOperationsAsync(
                        ledger, episode.EpisodeID, "aborted", "abandoned_old_release_drain", cancellationToken);
                    return StartupAdmission.Open;
                }
                case "activating_new_release":
                {
                    var current = CurrentReleaseFromDisk();
                    if (current == episode.ToReleaseID)
                    {
                        _state.PreviousReleaseID = episode.FromReleaseID;
                        _state.CurrentReleaseID = episode.ToReleaseID;
                        _state.StagedReleaseID = null;
                        SaveState();
                        var probation = episode.Clone();
                        probation.Phase = "probation_new_release";
                        probation.ExplicitResolutionRequired = true;
                        probation.Health = "pending";
                        probation.UpdatedAt = LinuxTime.Now();
                        await _ledger.SetEpisodeAsync(probation, cancellationToken);
                        await TransitionEpisodeOperationsAsync(
                            ledger, episode.EpisodeID, "probation_new_release", null, cancellationToken);
                        return StartupAdmission.Probation;
                    }
                    if (current == episode.FromReleaseID)
                    {
                        var aborted = episode.Clone();
                        aborted.Phase = "aborted";
                        aborted.ExplicitResolutionRequired = false;
                        aborted.Health = "not_applicable";
                        aborted.UpdatedAt = LinuxTime.Now();
                        await _ledger.SetEpisodeAsync(aborted, cancellationToken);
                        await TransitionEpisodeOperationsAsync(
                            ledger, episode.EpisodeID, "aborted", "activation_did_not_switch", cancellationToken);
                        return StartupAdmission.Open;
                    }
                    return StartupAdmission.RecoveryRequired;
                }
                case "probation_new_release":
                {
                    var current = CurrentReleaseFromDisk();
                    if (current != episode.ToReleaseID) return StartupAdmission.RecoveryRequired;
                    _state.PreviousReleaseID = episode.FromReleaseID;
                    _state.CurrentReleaseID = episode.ToReleaseID;
                    _state.StagedReleaseID = null;
                    SaveState();
                    return StartupAdmission.Probation;
                }
                case "committed":
                case "rolled_back":
                case "aborted":
                {
                    var operationState = episode.Phase == "committed" ? "completed" : "aborted";
                    await TransitionEpisodeOperationsAsync(
                        ledger, episode.EpisodeID, operationState, episode.Phase, cancellationToken);
                    if (episode.Phase == "rolled_back")
                    {
                        foreach (var rollback in ledger.Operations.Where(operation =>
                                     operation.EpisodeID == episode.EpisodeID &&
                                     operation.Kind == "update.rollback" && !operation.IsTerminal))
                        {
                            await _ledger.TransitionOperationAsync(
                                rollback.OperationID, "completed", "rolled_back",
                                cancellationToken: cancellationToken);
                        }
                    }
                    await CompleteServiceRestartsAsync(ledger, cancellationToken);
                    return StartupAdmission.Open;
                }
                default:
                    return StartupAdmission.RecoveryRequired;
            }
        }
        finally { _gate.Release(); }
    }

    public Task? ActivationTask => _activationTask;

    public async Task<LedgerOperation> ActivateAsync(
        Guid operationID,
        string requestHash,
        string releaseID,
        int drainTimeoutSeconds,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var existing = await _ledger.GetOperationAsync(operationID, cancellationToken);
            if (existing is not null)
                return await _ledger.BeginOperationAsync(
                    operationID, "update.activate", requestHash, existing.EpisodeID,
                    cancellationToken: cancellationToken);

            var ledger = await _ledger.SnapshotAsync(cancellationToken);
            if (ledger.UpdateEpisode is { Phase: "draining_old_release" or "activating_new_release" or "probation_new_release" })
                throw new AdminException("admission_closed", "An update episode is already active.");
            var current = CurrentReleaseFromDisk()
                ?? throw new AdminException("recovery_required", "The current release cannot be proven.");
            if (current == releaseID)
                throw new AdminException("invalid_request", "That release is already current.");
            if (_state.StagedReleaseID != releaseID ||
                !_state.Uploads.Any(upload => upload.ReleaseID == releaseID && upload.Verified) ||
                !File.Exists(_paths.ReleaseExecutable(releaseID)))
                throw new AdminException("stage_verification_failed", "The release has not been staged and verified.");

            var episodeID = Guid.NewGuid();
            var operation = await _ledger.BeginOperationAsync(
                operationID, "update.activate", requestHash, episodeID,
                cancellationToken: cancellationToken);
            var now = LinuxTime.Now();
            var episode = new UpdateEpisode
            {
                EpisodeID = episodeID,
                Phase = "draining_old_release",
                FromReleaseID = current,
                ToReleaseID = releaseID,
                StartedAt = now,
                UpdatedAt = now,
                ExplicitResolutionRequired = false,
                Health = "not_applicable",
            };
            await _ledger.SetEpisodeAsync(episode, cancellationToken);
            await _ledger.TransitionOperationAsync(
                operationID, "draining_old_release", episodeID: episodeID,
                cancellationToken: cancellationToken);
            _runtime.SetAcceptingWork(false);
            _activationTask = Task.Run(() =>
                DrainAndActivateAsync(operationID, episode, drainTimeoutSeconds));
            return await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation;
        }
        finally { _gate.Release(); }
    }

    private async Task DrainAndActivateAsync(
        Guid operationID, UpdateEpisode episode, int drainTimeoutSeconds)
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(drainTimeoutSeconds);
        // Admission closed before this task started under the shared Core
        // admission lock, so no new external work can begin and the
        // in-flight count can only shrink. The final quiescence decision
        // below runs under _gate and rechecks that same shared boundary.
        while (!_runtime.IsWorkQuiescent() && DateTimeOffset.UtcNow < deadline)
            await Task.Delay(100);

        var restart = false;
        await _gate.WaitAsync();
        try
        {
            var ledger = await _ledger.SnapshotAsync();
            if (ledger.UpdateEpisode?.EpisodeID != episode.EpisodeID ||
                ledger.UpdateEpisode.Phase != "draining_old_release") return;

            if (!_runtime.IsWorkQuiescent())
            {
                var aborted = episode.Clone();
                aborted.Phase = "aborted";
                aborted.UpdatedAt = LinuxTime.Now();
                await _ledger.SetEpisodeAsync(aborted);
                await _ledger.TransitionOperationAsync(operationID, "aborted", "drain_timeout");
                _runtime.SetAcceptingWork(true);
                return;
            }

            var activating = episode.Clone();
            activating.Phase = "activating_new_release";
            activating.UpdatedAt = LinuxTime.Now();
            await _ledger.SetEpisodeAsync(activating);
            await _ledger.TransitionOperationAsync(operationID, "activating_new_release");

            try
            {
                SwitchCurrentRelease(episode.ToReleaseID);
                _state.PreviousReleaseID = episode.FromReleaseID;
                _state.CurrentReleaseID = episode.ToReleaseID;
                _state.StagedReleaseID = null;
                SaveState();

                var probation = activating.Clone();
                probation.Phase = "probation_new_release";
                probation.ExplicitResolutionRequired = true;
                probation.Health = "pending";
                probation.UpdatedAt = LinuxTime.Now();
                await _ledger.SetEpisodeAsync(probation);
                await _ledger.TransitionOperationAsync(operationID, "probation_new_release");
                restart = true;
            }
            catch
            {
                if (CurrentReleaseFromDisk() == episode.ToReleaseID)
                {
                    await _ledger.TransitionOperationAsync(
                        operationID, "uncertain", "activation_uncertain");
                }
                else
                {
                    var aborted = activating.Clone();
                    aborted.Phase = "aborted";
                    aborted.UpdatedAt = LinuxTime.Now();
                    await _ledger.SetEpisodeAsync(aborted);
                    await _ledger.TransitionOperationAsync(
                        operationID, "failed", "activation_failed");
                    _runtime.SetAcceptingWork(true);
                }
            }
        }
        finally { _gate.Release(); }
        if (restart) _runtime.RequestRestart("update activation");
    }

    public async Task<LedgerOperation> HealthCommitAsync(
        Guid operationID, string requestHash, Guid episodeID,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var operation = await _ledger.BeginOperationAsync(
                operationID, "update.healthCommit", requestHash, episodeID,
                cancellationToken: cancellationToken);
            if (operation.IsTerminal) return operation;
            var ledger = await _ledger.SnapshotAsync(cancellationToken);
            var episode = ledger.UpdateEpisode;
            if (episode is null || episode.EpisodeID != episodeID ||
                episode.Phase != "probation_new_release" ||
                CurrentReleaseFromDisk() != episode.ToReleaseID)
                throw new AdminException(
                    "probation_health_failed",
                    "The probationary release cannot be proven current.");

            await _ledger.TransitionOperationAsync(operationID, "running", cancellationToken: cancellationToken);
            try
            {
                await _runtime.StartFabricAsync(cancellationToken);
            }
            catch
            {
                await _ledger.TransitionOperationAsync(
                    operationID, "failed", "probation_health_failed", cancellationToken: cancellationToken);
                throw new AdminException(
                    "probation_health_failed",
                    "The probationary release did not start its fabric service.");
            }

            _runtime.SetAcceptingWork(true);
            var committed = episode.Clone();
            committed.Phase = "committed";
            committed.ExplicitResolutionRequired = false;
            committed.Health = "passed";
            committed.UpdatedAt = LinuxTime.Now();
            await _ledger.SetEpisodeAsync(committed, cancellationToken);
            await TransitionEpisodeOperationsAsync(
                ledger, episodeID, "completed", "health_committed", cancellationToken);
            await _ledger.TransitionOperationAsync(
                operationID, "completed", "health_committed", cancellationToken: cancellationToken);
            return await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation;
        }
        finally { _gate.Release(); }
    }

    public async Task<LedgerOperation> RollbackAsync(
        Guid operationID, string requestHash, Guid episodeID, string reason,
        CancellationToken cancellationToken = default)
    {
        LedgerOperation operation;
        await _gate.WaitAsync(cancellationToken);
        try
        {
            operation = await _ledger.BeginOperationAsync(
                operationID, "update.rollback", requestHash, episodeID,
                cancellationToken: cancellationToken);
            if (operation.IsTerminal) return operation;
            var ledger = await _ledger.SnapshotAsync(cancellationToken);
            var episode = ledger.UpdateEpisode;
            if (episode is null || episode.EpisodeID != episodeID ||
                episode.Phase is not ("probation_new_release" or "activating_new_release") ||
                CurrentReleaseFromDisk() != episode.ToReleaseID ||
                !File.Exists(_paths.ReleaseExecutable(episode.FromReleaseID)))
                throw new AdminException("recovery_required", "The rollback target cannot be proven.");

            await _ledger.TransitionOperationAsync(operationID, "running", cancellationToken: cancellationToken);
            SwitchCurrentRelease(episode.FromReleaseID);
            _state.PreviousReleaseID = episode.ToReleaseID;
            _state.CurrentReleaseID = episode.FromReleaseID;
            _state.StagedReleaseID = null;
            SaveState();

            var rolledBack = episode.Clone();
            rolledBack.Phase = "rolled_back";
            rolledBack.ExplicitResolutionRequired = false;
            rolledBack.Health = "not_applicable";
            rolledBack.UpdatedAt = LinuxTime.Now();
            await _ledger.SetEpisodeAsync(rolledBack, cancellationToken);
            await TransitionEpisodeOperationsAsync(
                ledger, episodeID, "aborted", "rolled_back", cancellationToken);
            operation = await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation;
        }
        finally { _gate.Release(); }
        _runtime.RequestRestart("update rollback");
        return operation;
    }

    public static AdminOperation ToAdminOperation(
        LedgerOperation operation, UpdateEpisode? episode)
    {
        JsonObject? result = null;
        if (episode is not null && operation.EpisodeID == episode.EpisodeID)
        {
            result = new JsonObject
            {
                ["fromReleaseID"] = episode.FromReleaseID,
                ["toReleaseID"] = episode.ToReleaseID,
            };
        }
        var message = operation.State switch
        {
            "draining_old_release" => "Waiting for active work to drain; no work will be killed.",
            "probation_new_release" => "New release is admission-closed pending explicit health commit.",
            "uncertain" => "The accepted operation outcome is uncertain and has been preserved.",
            "aborted" when operation.ResultCode == "drain_timeout" =>
                "Drain timed out; the old release resumed without killing active work.",
            _ => operation.ResultCode,
        };
        return new AdminOperation
        {
            OperationID = operation.OperationID,
            Kind = operation.Kind,
            State = operation.State,
            EpisodeID = operation.EpisodeID,
            CreatedAt = operation.CreatedAt,
            UpdatedAt = operation.UpdatedAt,
            Stage = operation.State,
            Message = message,
            Retryable = operation.State is "failed" or "aborted",
            Uncertain = operation.State == "uncertain",
            Result = result,
        };
    }

    private async Task TransitionEpisodeOperationsAsync(
        RecoveryLedger ledger, Guid episodeID, string state, string? resultCode,
        CancellationToken cancellationToken)
    {
        foreach (var operation in ledger.Operations.Where(operation =>
                     operation.EpisodeID == episodeID &&
                     operation.Kind == "update.activate" && !operation.IsTerminal))
        {
            await _ledger.TransitionOperationAsync(
                operation.OperationID, state, resultCode, episodeID,
                cancellationToken: cancellationToken);
        }
    }

    private async Task CompleteServiceRestartsAsync(
        RecoveryLedger ledger, CancellationToken cancellationToken)
    {
        foreach (var operation in ledger.Operations.Where(operation =>
                     operation.Kind == "service.restart" && !operation.IsTerminal))
        {
            await _ledger.TransitionOperationAsync(
                operation.OperationID, "completed", "restarted",
                cancellationToken: cancellationToken);
        }
    }

    private string? CurrentReleaseFromDisk()
    {
        var linked = _paths.LinkedReleaseID();
        if (linked is not null && File.Exists(_paths.ReleaseExecutable(linked))) return linked;
        if (_state.CurrentReleaseID is not null &&
            File.Exists(_paths.ReleaseExecutable(_state.CurrentReleaseID)))
            return _state.CurrentReleaseID;
        return linked ?? _state.CurrentReleaseID;
    }

    private void SwitchCurrentRelease(string releaseID)
    {
        var target = _paths.ReleaseExecutable(releaseID);
        if (!File.Exists(target)) throw new FileNotFoundException("Release executable is missing.", target);
        LinuxFileModes.File700(target);
        LinuxFileModes.Directory700(_paths.BinDirectory);
        var temporary = Path.Combine(_paths.BinDirectory, $".converse-{Guid.NewGuid():N}.tmp");
        try
        {
            File.CreateSymbolicLink(temporary, target);
            File.Move(temporary, _paths.BinLink, overwrite: true);
            DurableJson.TrySyncDirectory(_paths.BinDirectory);
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); } catch { /* best effort */ }
        }
    }

    private void CleanupExpiredUploads()
    {
        var changed = false;
        foreach (var upload in _state.Uploads.ToList())
        {
            if (upload.Verified) continue;
            if (!DateTimeOffset.TryParse(upload.ExpiresAt, out var expires) || expires > DateTimeOffset.UtcNow)
                continue;
            _state.Uploads.Remove(upload);
            changed = true;
            try { if (File.Exists(upload.UploadPath)) File.Delete(upload.UploadPath); }
            catch { /* The upload record is expired even if cleanup races. */ }
        }
        if (changed) SaveState();
    }

    private void LoadState(string initialReleaseID, string initialSupervisor)
    {
        var existed = File.Exists(_paths.UpdateStateFile);
        if (existed)
        {
            _state = JsonSerializer.Deserialize<LinuxUpdateState>(
                File.ReadAllBytes(_paths.UpdateStateFile), DurableJson.Options) ?? new LinuxUpdateState();
        }
        var current = _paths.LinkedReleaseID() ?? _state.CurrentReleaseID ?? initialReleaseID;
        var changed = !existed || _state.CurrentReleaseID != current;
        _state.CurrentReleaseID = current;
        if (initialSupervisor != "none" && _state.Supervisor == "none")
        {
            _state.Supervisor = initialSupervisor;
            changed = true;
        }
        if (changed) SaveState();
    }

    private void SaveState()
    {
        LinuxFileModes.Directory700(_paths.StateRoot);
        DurableJson.Write(_paths.UpdateStateFile, _state);
        LinuxFileModes.File600(_paths.UpdateStateFile);
    }
}
