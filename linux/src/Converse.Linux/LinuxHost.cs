using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Converse.Core;

namespace Converse.Linux;

internal sealed class LinuxHostOptions
{
    public LinuxPaths Paths { get; init; } = LinuxPaths.FromEnvironment();
    public string? DeviceName { get; init; }
    public int Port { get; init; } = DeviceSyncService.DefaultPort;
    public bool EnableDiscovery { get; init; } = true;
    public bool LoopbackOnly { get; init; }
    public string InitialSupervisor { get; init; } = "none";
    public bool EnableAgentTicker { get; init; } = true;

    public static LinuxHostOptions FromEnvironment()
    {
        var paths = LinuxPaths.FromEnvironment();
        return new LinuxHostOptions
        {
            Paths = paths,
            DeviceName = Environment.GetEnvironmentVariable("CONVERSE_DEVICE_NAME"),
            Port = int.TryParse(Environment.GetEnvironmentVariable("CONVERSE_LINUX_PORT"), out var port)
                ? port : DeviceSyncService.DefaultPort,
            EnableDiscovery = Environment.GetEnvironmentVariable("CONVERSE_LINUX_DISCOVERY") != "0",
            LoopbackOnly = Environment.GetEnvironmentVariable("CONVERSE_LINUX_LOOPBACK") == "1",
            InitialSupervisor = Environment.GetEnvironmentVariable("CONVERSE_LINUX_SUPERVISOR") ?? "none",
        };
    }
}

internal sealed class LinuxHost : ILinuxUpdateRuntime, IAsyncDisposable
{
    private static readonly Regex DeviceIDPattern = new("^[0-9a-f]{64}$", RegexOptions.Compiled);
    private static readonly Regex SecretIDPattern = new("^[a-z0-9][a-z0-9._-]{0,63}$", RegexOptions.Compiled);
    private static readonly Regex HashPattern = new("^[0-9a-f]{64}$", RegexOptions.Compiled);

    private readonly LinuxHostOptions _options;
    private readonly LinuxPaths _paths;
    private readonly ProductInfo _product;
    private readonly SerializedStateExecutor _stateExecutor = new();
    private readonly SerializedStateExecutor _adminExecutor = new();
    private readonly RecoveryLedgerStore _ledger;
    private readonly LinuxSecretStore _secrets;
    private readonly Dictionary<Guid, JoinRecord> _joins = new();
    private readonly Dictionary<Guid, string> _requestFirstSeen = new();
    private readonly CancellationTokenSource _shutdown = new();
    private readonly DateTimeOffset _startedAt = DateTimeOffset.UtcNow;

    private FileStream? _instanceLock;
    private SessionStore? _store;
    private DeviceSyncService? _devices;
    private LinuxUpdateManager? _updates;
    private Socket? _adminSocket;
    private Task? _adminTask;
    private Task? _tickerTask;
    private StartupAdmission _admission = StartupAdmission.RecoveryRequired;
    private bool _recoveryRequired;
    private bool _started;
    private bool _restartRequested;
    private int _authoritySyncQueued;

    public LinuxHost(LinuxHostOptions options)
    {
        _options = options;
        _paths = options.Paths;
        _product = ProductInfo.Load(_paths);
        _ledger = new RecoveryLedgerStore(_paths, _stateExecutor);
        _secrets = new LinuxSecretStore(_paths, _stateExecutor);
    }

    public string? DeviceID => _devices?.DeviceId;
    public int ListeningPort => _devices?.ListeningPort ?? 0;
    public string SocketPath => _paths.SocketPath;
    public bool FabricStarted { get; private set; }
    public int ActiveTurnCount => _store?.Sessions.Count(session => session.Busy) ?? 0;

    public async Task<int> RunAsync(CancellationToken cancellationToken = default)
    {
        await StartAsync(cancellationToken);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken, _shutdown.Token);
        try { await Task.Delay(Timeout.InfiniteTimeSpan, linked.Token); }
        catch (OperationCanceledException) { }
        await StopAsync();
        return 0;
    }

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_started) return;
        _started = true;
        _paths.EnsurePrivateDirectories();
        AcquireInstanceLock();

        var floors = BuildRecoveryFloors(_ledger.Existing);
        _store = new SessionStore(_paths.DataRoot);
        _devices = new DeviceSyncService(
            _paths.DataRoot,
            _store,
            string.IsNullOrWhiteSpace(_options.DeviceName) ? Environment.MachineName : _options.DeviceName,
            floors);
        _paths.ProtectIdentity();
        _devices.IsViewerPlaced = _ => false;
        _devices.Agents.ReadSecret = _secrets.Read;
        _devices.DisplayLeaseGranted += OnDisplayLeaseGranted;
        _devices.DisplayLeaseReleased += OnDisplayLeaseReleased;
        _devices.Changed += QueueAuthoritySync;

        try
        {
            await _ledger.InitializeAsync(_devices.DeviceId, cancellationToken);
        }
        catch (RecoveryRequiredException)
        {
            _recoveryRequired = true;
        }

        var verifier = new ReleaseBundleVerifier(_paths);
        _updates = new LinuxUpdateManager(
            _paths, _ledger, verifier, this, _product.ReleaseID, _options.InitialSupervisor);

        if (!_recoveryRequired)
        {
            await ReconcileLedgerAuthorityAsync(cancellationToken);
            await SyncAuthorityAsync(cancellationToken);
            _admission = await _updates.ReconcileStartupAsync(cancellationToken);
        }
        else
        {
            _admission = StartupAdmission.RecoveryRequired;
        }

        if (_admission == StartupAdmission.Open)
        {
            await StartFabricAsync(cancellationToken);
            SetAcceptingWork(true);
        }
        else
        {
            SetAcceptingWork(false);
        }

        StartAdminSocket();
        if (_options.EnableAgentTicker)
            _tickerTask = Task.Run(() => AgentTickerAsync(_shutdown.Token));
    }

    public async Task StopAsync()
    {
        _shutdown.Cancel();
        try { _adminSocket?.Dispose(); } catch { /* closing */ }
        if (_adminTask is not null)
        {
            try { await _adminTask; } catch { /* shutdown */ }
        }
        if (_tickerTask is not null)
        {
            try { await _tickerTask; } catch { /* shutdown */ }
        }
        if (!_recoveryRequired && _devices is not null && _ledger.IsInitialized)
        {
            try { await SyncAuthorityAsync(); } catch { /* preserve shutdown */ }
        }
        _devices?.Dispose();
        _devices = null;
        FabricStarted = false;
        try { if (File.Exists(_paths.SocketPath)) File.Delete(_paths.SocketPath); } catch { /* stale socket */ }
        _instanceLock?.Dispose();
        _instanceLock = null;
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
        _stateExecutor.Dispose();
        _adminExecutor.Dispose();
        _shutdown.Dispose();
    }

    public void SetAcceptingWork(bool accepting) => _devices?.SetAcceptingWork(accepting);

    public async Task StartFabricAsync(CancellationToken cancellationToken)
    {
        if (FabricStarted || _devices is null) return;
        cancellationToken.ThrowIfCancellationRequested();
        await _devices.StartAsync(
            _options.Port,
            enableDiscovery: _options.EnableDiscovery && !_options.LoopbackOnly,
            loopbackOnly: _options.LoopbackOnly);
        FabricStarted = true;
        if (_admission == StartupAdmission.Probation) _admission = StartupAdmission.Open;
    }

    public void RequestRestart(string reason)
    {
        if (_restartRequested) return;
        _restartRequested = true;
        _ = Task.Run(async () =>
        {
            await Task.Delay(250);
            _shutdown.Cancel();
        });
    }

    internal async Task<AdminResponse> DispatchForTestsAsync(
        AdminRequest request, CancellationToken cancellationToken = default) =>
        await DispatchAsync(request, cancellationToken);

    private void AcquireInstanceLock()
    {
        try
        {
            _instanceLock = new FileStream(
                _paths.LockFile, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            LinuxFileModes.File600(_paths.LockFile);
        }
        catch (IOException error)
        {
            throw new InvalidOperationException(
                "Another Converse Linux daemon is already using this state directory.", error);
        }
    }

    private static DeviceRecoveryFloors? BuildRecoveryFloors(RecoveryLedger? ledger)
    {
        if (ledger is null) return null;
        var floors = new DeviceRecoveryFloors
        {
            NextBoot = ledger.CounterFloors.NextBoot,
            NextHomeSeq = ledger.CounterFloors.NextHomeSeq,
            NextLeaseEpoch = ledger.CounterFloors.NextLeaseEpoch,
            NextMembershipGeneration = ledger.CounterFloors.NextMembershipGeneration,
        };
        foreach (var display in ledger.DisplayRestorations)
        {
            var parsed = DeviceGlobalID.Parse(display.SessionGlobalID);
            if (parsed is not null)
                floors.SessionEpochFloors[parsed.Value.Session] = Math.Max(
                    floors.SessionEpochFloors.GetValueOrDefault(parsed.Value.Session),
                    display.LastExecutionEpoch);
        }
        foreach (var receipt in ledger.CommandReceipts)
        {
            var outcome = receipt.State switch
            {
                "started" => "running",
                _ => receipt.State,
            };
            var updated = DateTimeOffset.TryParse(
                receipt.TerminalAt ?? receipt.AcceptedAt, out var parsed)
                ? parsed.UtcDateTime : DateTime.UtcNow;
            floors.CommandReceipts.Add(new DeviceCommandRecord
            {
                Id = receipt.CommandID,
                Origin = receipt.OriginDeviceID,
                Outcome = outcome,
                UpdatedAt = updated,
                SessionID = receipt.SessionGlobalID,
                PayloadHash = "",
            });
        }
        return floors;
    }

    private async Task ReconcileLedgerAuthorityAsync(CancellationToken cancellationToken)
    {
        if (_devices is null) return;
        var ledger = await _ledger.SnapshotAsync(cancellationToken);
        foreach (var groupID in ledger.DissolvedGroupIDs)
        {
            var group = _devices.GroupStore.Groups.FirstOrDefault(
                item => string.Equals(item.Id, groupID, StringComparison.OrdinalIgnoreCase));
            if (group is not null && !group.Dissolved)
            {
                try { _devices.GroupStore.Dissolve(group); }
                catch { _recoveryRequired = true; }
            }
        }
        foreach (var removedID in ledger.Membership.RemovedDeviceIDs)
        {
            if (_devices.Trust.Devices.Any(device => device.DeviceID == removedID))
                _devices.Trust.Forget(removedID, _devices.DeviceId);
        }
        _devices.RefreshGroupMembers();
    }

    private async Task SyncAuthorityAsync(CancellationToken cancellationToken = default)
    {
        if (_devices is null || !_ledger.IsInitialized) return;
        await _ledger.SyncAuthorityAsync(
            _devices.SyncCounterSnapshot(),
            _devices.Trust.NextGenerationFloor,
            _devices.Trust.Records,
            _devices.GroupStore.Groups,
            _devices.CommandReceipts,
            cancellationToken);
    }

    private void QueueAuthoritySync()
    {
        if (_recoveryRequired || Interlocked.Exchange(ref _authoritySyncQueued, 1) == 1) return;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(500, _shutdown.Token);
                await SyncAuthorityAsync(_shutdown.Token);
            }
            catch { /* A later change or shutdown sync retries. */ }
            finally { Interlocked.Exchange(ref _authoritySyncQueued, 0); }
        });
    }

    private void OnDisplayLeaseGranted(Guid sessionID, string ownerID, ulong epoch)
    {
        if (_devices is null || _recoveryRequired) return;
        _ = Task.Run(async () =>
        {
            try
            {
                await _ledger.RecordDisplayGrantAsync(
                    _devices.DeviceId, sessionID, ownerID, epoch, _shutdown.Token);
            }
            catch { /* The durable Core epoch remains the fencing authority. */ }
        });
    }

    private void OnDisplayLeaseReleased(Guid sessionID, string ownerID, ulong epoch)
    {
        if (_devices is null || _recoveryRequired) return;
        _ = Task.Run(async () =>
        {
            try
            {
                await _ledger.RecordDisplayReleaseAsync(
                    _devices.DeviceId, sessionID, ownerID, epoch, _shutdown.Token);
            }
            catch { /* The durable Core epoch remains the fencing authority. */ }
        });
    }

    private async Task AgentTickerAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(15));
        try
        {
            while (await timer.WaitForNextTickAsync(cancellationToken))
            {
                if (FabricStarted && _devices?.AcceptingWork == true &&
                    _admission == StartupAdmission.Open)
                    _devices.Agents.Tick(DateTime.UtcNow);
            }
        }
        catch (OperationCanceledException) { }
    }

    private void StartAdminSocket()
    {
        LinuxFileModes.Directory700(_paths.RuntimeDirectory);
        if (File.Exists(_paths.SocketPath)) File.Delete(_paths.SocketPath);
        _adminSocket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        _adminSocket.Bind(new UnixDomainSocketEndPoint(_paths.SocketPath));
        _adminSocket.Listen(16);
        LinuxFileModes.File600(_paths.SocketPath);
        _adminTask = Task.Run(() => AdminAcceptLoopAsync(_shutdown.Token));
    }

    private async Task AdminAcceptLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            Socket client;
            try { client = await _adminSocket!.AcceptAsync(cancellationToken); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) { return; }
            _ = Task.Run(() => HandleAdminClientAsync(client, cancellationToken), cancellationToken);
        }
    }

    private async Task HandleAdminClientAsync(Socket client, CancellationToken cancellationToken)
    {
        await using var stream = new NetworkStream(client, ownsSocket: true);
        AdminResponse response;
        Guid requestID = Guid.Empty;
        try
        {
            var line = await ReadOneLineAsync(stream, 64 * 1024, cancellationToken);
            if (line is null) return;
            var request = JsonSerializer.Deserialize<AdminRequest>(line, AdminJson.Options)
                ?? throw new AdminException("invalid_request", "The admin request is empty.");
            requestID = request.RequestID;
            response = await DispatchAsync(request, cancellationToken);
        }
        catch (AdminException error)
        {
            response = AdminResponse.Failure(
                requestID, error.Code, error.Message, error.Retryable, error.Uncertain);
        }
        catch (JsonException)
        {
            response = AdminResponse.Failure(
                requestID, "invalid_request", "The admin request is not valid JSON.");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error)
        {
            response = AdminResponse.Failure(
                requestID, "internal_error", error.Message, retryable: true);
        }

        var bytes = Encoding.UTF8.GetBytes(AdminJson.Serialize(response) + "\n");
        if (bytes.Length > 1024 * 1024)
        {
            bytes = Encoding.UTF8.GetBytes(AdminJson.Serialize(
                AdminResponse.Failure(requestID, "internal_error", "The admin response is too large.")) + "\n");
        }
        await stream.WriteAsync(bytes, cancellationToken);
    }

    internal static async Task<string?> ReadOneLineAsync(
        Stream stream, int maximumBytes, CancellationToken cancellationToken)
    {
        var buffer = new byte[4096];
        using var output = new MemoryStream();
        while (true)
        {
            var read = await stream.ReadAsync(buffer, cancellationToken);
            if (read == 0) return output.Length == 0 ? null : Encoding.UTF8.GetString(output.ToArray());
            for (var index = 0; index < read; index++)
            {
                if (buffer[index] == (byte)'\n')
                {
                    output.Write(buffer, 0, index);
                    return Encoding.UTF8.GetString(output.ToArray()).TrimEnd('\r');
                }
            }
            if (output.Length + read > maximumBytes)
                throw new AdminException("invalid_request", "The admin request exceeds the size limit.");
            output.Write(buffer, 0, read);
        }
    }

    private async Task<AdminResponse> DispatchAsync(
        AdminRequest request, CancellationToken cancellationToken)
    {
        return await _adminExecutor.RunAsync(
            () => DispatchSerializedAsync(request, cancellationToken), cancellationToken);
    }

    private async Task<AdminResponse> DispatchSerializedAsync(
        AdminRequest request, CancellationToken cancellationToken)
    {
        if (_devices is null || _store is null || _updates is null)
            return AdminResponse.Failure(request.RequestID, "daemon_unavailable", "The daemon is starting.", true);
        if (request.AdminApiVersion != 1)
            return AdminResponse.Failure(
                request.RequestID, "unsupported_admin_api", "This Linux home supports admin API version 1.");
        if (request.Payload.ValueKind != JsonValueKind.Object)
            return AdminResponse.Failure(request.RequestID, "invalid_request", "The admin payload must be an object.");
        if (request.ExpectedDeviceID is not null &&
            !string.Equals(request.ExpectedDeviceID, _devices.DeviceId, StringComparison.Ordinal))
            return AdminResponse.Failure(
                request.RequestID, "identity_mismatch",
                "The Linux Converse identity does not match this deployment.");

        if ((_recoveryRequired || _admission == StartupAdmission.RecoveryRequired) &&
            request.Operation is not ("status.get" or "operation.get"))
            return AdminResponse.Failure(
                request.RequestID, "recovery_required",
                "The Linux home is closed until its recovery state is resolved.");

        try
        {
            switch (request.Operation)
            {
                case "status.get":
                    return AdminResponse.Success(request.RequestID,
                        await BuildStatusAsync(cancellationToken));
                case "operation.get":
                {
                    var operationID = RequiredGuid(request.Payload, "operationID");
                    var operation = await _ledger.GetOperationAsync(operationID, cancellationToken);
                    if (operation is null)
                        return AdminResponse.Failure(request.RequestID, "operation_not_found", "The operation was not found.");
                    var ledger = await _ledger.SnapshotAsync(cancellationToken);
                    return AdminResponse.Success(request.RequestID, operation:
                        LinuxUpdateManager.ToAdminOperation(operation, ledger.UpdateEpisode));
                }
                case "group.create":
                {
                    var name = RequiredString(request.Payload, "name", 120);
                    var before = _devices.CurrentGroup?.Id;
                    await _devices.CreateGroupAsync(name);
                    if (_devices.CurrentGroup is null || _devices.CurrentGroup.Id == before ||
                        !string.Equals(_devices.CurrentGroup.Name, name.Trim(), StringComparison.Ordinal))
                        return AdminResponse.Failure(
                            request.RequestID, "invalid_request",
                            string.IsNullOrWhiteSpace(_devices.LastOutcome)
                                ? "The group could not be created." : _devices.LastOutcome);
                    await SyncAuthorityAsync(cancellationToken);
                    return AdminResponse.Success(request.RequestID,
                        await BuildStatusAsync(cancellationToken));
                }
                case "pairing.join.begin":
                    return AdminResponse.Success(request.RequestID,
                        await BeginJoinAsync(request.Payload, cancellationToken));
                case "pairing.join.status":
                    return AdminResponse.Success(request.RequestID,
                        JoinStatus(RequiredGuid(request.Payload, "pairingID")));
                case "pairing.join.confirm":
                    return AdminResponse.Success(request.RequestID,
                        await ConfirmJoinAsync(RequiredGuid(request.Payload, "pairingID")));
                case "pairing.join.cancel":
                    return AdminResponse.Success(request.RequestID,
                        CancelJoin(RequiredGuid(request.Payload, "pairingID")));
                case "pairing.requests.list":
                    return AdminResponse.Success(request.RequestID, new PairingListResult
                    {
                        Requests = SnapshotGroupRequests().Select(item => RequestBinding(item, false)).ToList(),
                    });
                case "pairing.request.review":
                    return AdminResponse.Success(request.RequestID,
                        await ReviewRequestAsync(RequiredGuid(request.Payload, "pairingID"), cancellationToken));
                case "pairing.request.approve":
                    return AdminResponse.Success(request.RequestID,
                        await ApproveRequestAsync(RequiredGuid(request.Payload, "pairingID")));
                case "pairing.request.reject":
                    return AdminResponse.Success(request.RequestID,
                        RejectRequest(RequiredGuid(request.Payload, "pairingID")));
                case "update.stage.begin":
                {
                    var releaseID = RequiredReleaseID(request.Payload, "releaseID");
                    var hash = RequiredHash(request.Payload, "bundleSHA256");
                    var size = RequiredLong(request.Payload, "bundleSize", 1, 536870912);
                    return AdminResponse.Success(request.RequestID,
                        await _updates.StageBeginAsync(releaseID, hash, size, cancellationToken));
                }
                case "update.stage.verify":
                    return AdminResponse.Success(request.RequestID,
                        await _updates.StageVerifyAsync(
                            RequiredGuid(request.Payload, "uploadID"), cancellationToken));
                case "update.activate":
                {
                    var operationID = RequiredOperationID(request);
                    var operation = await _updates.ActivateAsync(
                        operationID,
                        AdminJson.PayloadHash(request.Payload),
                        RequiredReleaseID(request.Payload, "releaseID"),
                        (int)RequiredLong(request.Payload, "drainTimeoutSeconds", 0, 86400),
                        cancellationToken);
                    return await OperationResponseAsync(request.RequestID, operation, cancellationToken);
                }
                case "update.healthCommit":
                {
                    var operationID = RequiredOperationID(request);
                    var operation = await _updates.HealthCommitAsync(
                        operationID,
                        AdminJson.PayloadHash(request.Payload),
                        RequiredGuid(request.Payload, "episodeID"),
                        cancellationToken);
                    return await OperationResponseAsync(request.RequestID, operation, cancellationToken);
                }
                case "update.rollback":
                {
                    var operationID = RequiredOperationID(request);
                    var operation = await _updates.RollbackAsync(
                        operationID,
                        AdminJson.PayloadHash(request.Payload),
                        RequiredGuid(request.Payload, "episodeID"),
                        RequiredString(request.Payload, "reason", 500),
                        cancellationToken);
                    return await OperationResponseAsync(request.RequestID, operation, cancellationToken);
                }
                case "service.restart":
                {
                    var operationID = RequiredOperationID(request);
                    var operation = await _ledger.BeginOperationAsync(
                        operationID, "service.restart", AdminJson.PayloadHash(request.Payload),
                        null, "running", cancellationToken);
                    if (!operation.IsTerminal) RequestRestart("admin request");
                    return await OperationResponseAsync(request.RequestID, operation, cancellationToken);
                }
                case "secret.set":
                {
                    var secretID = RequiredSecretID(request.Payload);
                    var kind = RequiredString(request.Payload, "kind", 40);
                    if (kind is not ("provider_api_key" or "webhook_url" or "oauth_token" or "other"))
                        throw Invalid("Secret kind is invalid.");
                    var value = RequiredString(request.Payload, "value", 16384);
                    if (value.Length == 0) throw Invalid("Secret value is empty.");
                    return AdminResponse.Success(request.RequestID,
                        await _secrets.SetAsync(secretID, kind, value, cancellationToken));
                }
                case "secret.delete":
                {
                    var secretID = RequiredSecretID(request.Payload);
                    var deleted = await _secrets.DeleteAsync(secretID, cancellationToken);
                    return deleted is null
                        ? AdminResponse.Failure(request.RequestID, "secret_not_found", "That secret is not configured.")
                        : AdminResponse.Success(request.RequestID, deleted);
                }
                default:
                    return AdminResponse.Failure(
                        request.RequestID, "invalid_request", "Unknown admin operation.");
            }
        }
        catch (OperationConflictException error)
        {
            return AdminResponse.Failure(request.RequestID, "operation_conflict", error.Message);
        }
        catch (AdminException error)
        {
            return AdminResponse.Failure(
                request.RequestID, error.Code, error.Message, error.Retryable, error.Uncertain);
        }
    }

    private async Task<AdminResponse> OperationResponseAsync(
        Guid requestID, LedgerOperation operation, CancellationToken cancellationToken)
    {
        var ledger = await _ledger.SnapshotAsync(cancellationToken);
        return AdminResponse.Success(requestID, operation:
            LinuxUpdateManager.ToAdminOperation(operation, ledger.UpdateEpisode));
    }

    private async Task<LinuxStatus> BuildStatusAsync(CancellationToken cancellationToken)
    {
        var devices = _devices!;
        var store = _store!;
        var updateState = _updates!.Snapshot();
        RecoveryLedger? ledger = null;
        if (_ledger.IsInitialized)
        {
            try { ledger = await _ledger.SnapshotAsync(cancellationToken); }
            catch { ledger = _ledger.Existing; }
        }
        var episode = ledger?.UpdateEpisode;
        var processState = _recoveryRequired || _admission == StartupAdmission.RecoveryRequired
            ? "recovery_required" : "running";
        var admission = processState == "recovery_required"
            ? "closed_recovery"
            : _admission == StartupAdmission.Probation || episode?.Phase == "probation_new_release"
                ? "closed_probation"
                : !devices.AcceptingWork || episode?.Phase == "draining_old_release"
                    ? "closed_draining"
                    : "open";

        var currentGroup = devices.CurrentGroup;
        var peers = currentGroup is null
            ? 0
            : devices.Trust.Devices.Count(device =>
                device.DeviceID != devices.DeviceId && device.GroupID == currentGroup.Id);
        var connected = devices.Homes.Values.Count(home => home.Online);
        return new LinuxStatus
        {
            ProductVersion = _product.Version,
            Build = _product.Build,
            SourceCommit = _product.SourceCommit,
            Architecture = _product.Architecture,
            Device = new StatusDevice { DeviceID = devices.DeviceId, Name = devices.DeviceName },
            Runtime = new StatusRuntime
            {
                ProcessState = processState,
                Supervisor = updateState.Supervisor,
                StartedAt = LinuxTime.Format(_startedAt),
                Admission = admission,
            },
            Filesystem = new StatusFilesystem
            {
                InstallRoot = _paths.InstallRoot,
                StateRoot = _paths.StateRoot,
                ConfigRoot = _paths.ConfigRoot,
                DataRoot = _paths.DataRoot,
            },
            Fabric = new StatusFabric
            {
                GroupID = currentGroup?.Id,
                GroupName = currentGroup?.Name,
                PeerCount = peers,
                ConnectedPeerCount = connected,
            },
            Work = new StatusWork
            {
                SessionCount = store.Sessions.Count,
                ActiveTurnCount = ActiveTurnCount,
                AgentCount = store.Sessions.Count(session => session.Agent is not null),
                ScheduledRunCount = store.Sessions.Count(
                    session => session.Agent?.CanSchedule == true && session.Agent.NextRunUtc is not null),
                PendingCommandCount = store.Sessions.Sum(session => session.Pending.Count) +
                    devices.Outbox.Count(record => record.Outcome is "pending" or "uncertain"),
            },
            Release = new StatusRelease
            {
                CurrentReleaseID = updateState.CurrentReleaseID,
                PreviousReleaseID = updateState.PreviousReleaseID,
                StagedReleaseID = updateState.StagedReleaseID,
                UpdateEpisode = episode,
            },
            Secrets = await _secrets.ListAsync(cancellationToken),
            Capabilities =
            [
                "linux-home-v1", "admin-v1", "fabric-membership-v1",
                "converse-groups-v1", "agent-host-v1",
            ],
        };
    }

    private async Task<PairingBinding> BeginJoinAsync(
        JsonElement payload, CancellationToken cancellationToken)
    {
        if (!FabricStarted)
            throw new AdminException("admission_closed", "The fabric service is not running.", retryable: true);
        var sponsorID = RequiredString(payload, "sponsorDeviceID", 64);
        if (!DeviceIDPattern.IsMatch(sponsorID) || sponsorID == _devices!.DeviceId)
            throw Invalid("Sponsor device ID is invalid.");
        var groupID = RequiredGuid(payload, "groupID").ToString("D");
        var ledger = await _ledger.SnapshotAsync(cancellationToken);
        if (ledger.DissolvedGroupIDs.Contains(groupID, StringComparer.OrdinalIgnoreCase))
            throw Invalid("That group has been dissolved.");
        if (!payload.TryGetProperty("sponsorEndpoint", out var endpoint) ||
            endpoint.ValueKind != JsonValueKind.Object)
            throw Invalid("Sponsor endpoint is missing.");
        var host = RequiredString(endpoint, "host", 255);
        var port = (int)RequiredLong(endpoint, "port", 1, 65535);
        if (string.IsNullOrWhiteSpace(host)) throw Invalid("Sponsor host is empty.");

        var pairingID = Guid.NewGuid();
        var record = new JoinRecord
        {
            PairingID = pairingID,
            SponsorID = sponsorID,
            GroupID = groupID,
            CreatedAt = DateTimeOffset.UtcNow,
            UpdatedAt = DateTimeOffset.UtcNow,
            ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(180),
        };
        _joins[pairingID] = record;
        record.PeerID = await _devices.BeginGroupJoinAsync(host, port, groupID);
        record.UpdatedAt = DateTimeOffset.UtcNow;
        return JoinStatus(pairingID);
    }

    private PairingBinding JoinStatus(Guid pairingID)
    {
        if (!_joins.TryGetValue(pairingID, out var record))
            throw new AdminException("pairing_not_found", "That pairing attempt was not found.");
        var devices = _devices!;
        var prompt = SnapshotPrompts().FirstOrDefault(item => item.PeerId == record.PeerID);
        var completed = string.Equals(devices.CurrentGroup?.Id, record.GroupID, StringComparison.OrdinalIgnoreCase) &&
            devices.Trust.Devices.Any(device => device.DeviceID == record.SponsorID &&
                string.Equals(device.GroupID, record.GroupID, StringComparison.OrdinalIgnoreCase));
        string state;
        if (record.StateOverride is not null) state = record.StateOverride;
        else if (completed) state = "completed";
        else if (DateTimeOffset.UtcNow > record.ExpiresAt) state = "expired";
        else if (prompt is not null) state = record.Confirmed ? "awaiting_peer" : "awaiting_user";
        else state = record.Confirmed ? "awaiting_peer" : "failed";

        var group = devices.KnownGroups.FirstOrDefault(
            item => string.Equals(item.Id, record.GroupID, StringComparison.OrdinalIgnoreCase));
        var peerName = prompt?.PeerName ??
            devices.Trust.Records.FirstOrDefault(device => device.DeviceID == record.SponsorID)?.Name ?? "";
        return new PairingBinding
        {
            PairingID = record.PairingID,
            Role = "joiner",
            State = state,
            LinuxDeviceID = devices.DeviceId,
            PeerDeviceID = record.SponsorID,
            PeerName = peerName,
            GroupID = record.GroupID,
            GroupName = group?.Name,
            VerificationCode = state == "awaiting_user" ? prompt?.Code : null,
            ExpiresAt = LinuxTime.Format(record.ExpiresAt),
            CreatedAt = LinuxTime.Format(record.CreatedAt),
            UpdatedAt = LinuxTime.Format(record.UpdatedAt),
        };
    }

    private async Task<PairingBinding> ConfirmJoinAsync(Guid pairingID)
    {
        if (!_joins.TryGetValue(pairingID, out var record))
            throw new AdminException("pairing_not_found", "That pairing attempt was not found.");
        if (DateTimeOffset.UtcNow > record.ExpiresAt)
            throw new AdminException("pairing_expired", "That pairing attempt has expired.");
        if (SnapshotPrompts().All(prompt => prompt.PeerId != record.PeerID))
            throw new AdminException("pairing_not_found", "That pairing prompt is no longer live.");
        await _devices!.ConfirmPairing(record.PeerID);
        record.Confirmed = true;
        record.UpdatedAt = DateTimeOffset.UtcNow;
        return JoinStatus(pairingID);
    }

    private PairingBinding CancelJoin(Guid pairingID)
    {
        if (!_joins.TryGetValue(pairingID, out var record))
            throw new AdminException("pairing_not_found", "That pairing attempt was not found.");
        _devices!.RejectPairing(record.PeerID);
        record.StateOverride = "rejected";
        record.UpdatedAt = DateTimeOffset.UtcNow;
        return JoinStatus(pairingID);
    }

    private List<GroupJoinRequest> SnapshotGroupRequests()
    {
        try { return _devices!.GroupRequests.ToList(); }
        catch { return new List<GroupJoinRequest>(); }
    }

    private List<PairingPrompt> SnapshotPrompts()
    {
        try { return _devices!.GroupPairingPrompts.ToList(); }
        catch { return new List<PairingPrompt>(); }
    }

    private PairingBinding RequestBinding(GroupJoinRequest request, bool includeCode)
    {
        var devices = _devices!;
        if (!_requestFirstSeen.TryGetValue(request.Id, out var created))
        {
            created = LinuxTime.Now();
            _requestFirstSeen[request.Id] = created;
        }
        var review = devices.GroupReview;
        var code = includeCode && review?.Request.Id == request.Id ? review.Code : null;
        var group = devices.KnownGroups.FirstOrDefault(
            item => string.Equals(item.Id, request.GroupID, StringComparison.OrdinalIgnoreCase));
        return new PairingBinding
        {
            PairingID = request.Id,
            Role = "reviewer",
            State = code is null && includeCode ? "connecting" : "awaiting_user",
            LinuxDeviceID = devices.DeviceId,
            PeerDeviceID = request.RequesterID,
            PeerName = request.RequesterName,
            GroupID = request.GroupID,
            GroupName = group?.Name ?? devices.CurrentGroup?.Name,
            VerificationCode = code,
            ExpiresAt = LinuxTime.FromAppleEpoch(request.ExpiresAt),
            CreatedAt = created,
            UpdatedAt = LinuxTime.Now(),
        };
    }

    private async Task<PairingBinding> ReviewRequestAsync(
        Guid pairingID, CancellationToken cancellationToken)
    {
        var request = SnapshotGroupRequests().FirstOrDefault(item => item.Id == pairingID)
            ?? throw new AdminException("pairing_not_found", "That group request was not found.");
        if (_devices!.GroupReview?.Request.Id != pairingID)
            await _devices.ReviewGroupRequestAsync(request);
        var deadline = DateTimeOffset.UtcNow.AddSeconds(3);
        while (_devices.GroupReview?.Request.Id != pairingID && DateTimeOffset.UtcNow < deadline)
            await Task.Delay(50, cancellationToken);
        return RequestBinding(request, includeCode: true);
    }

    private async Task<PairingBinding> ApproveRequestAsync(Guid pairingID)
    {
        var request = SnapshotGroupRequests().FirstOrDefault(item => item.Id == pairingID)
            ?? throw new AdminException("pairing_not_found", "That group request was not found.");
        if (_devices!.GroupReview?.Request.Id != pairingID)
            throw new AdminException("pairing_not_found", "Review that group request before approving it.");
        var binding = RequestBinding(request, includeCode: false);
        await _devices.ApproveGroupReviewAsync();
        binding.State = "approved";
        binding.VerificationCode = null;
        binding.UpdatedAt = LinuxTime.Now();
        return binding;
    }

    private PairingBinding RejectRequest(Guid pairingID)
    {
        var request = SnapshotGroupRequests().FirstOrDefault(item => item.Id == pairingID)
            ?? throw new AdminException("pairing_not_found", "That group request was not found.");
        if (request.SponsorID != _devices!.DeviceId)
            throw Invalid("Only the sponsoring Linux home can reject this request directly.");
        var binding = RequestBinding(request, includeCode: false);
        if (_devices.GroupReview?.Request.Id == pairingID) _devices.GroupReview = null;
        _devices.RejectPairing(pairingID);
        binding.State = "rejected";
        binding.VerificationCode = null;
        binding.UpdatedAt = LinuxTime.Now();
        return binding;
    }

    private static Guid RequiredOperationID(AdminRequest request) =>
        request.OperationID is { } id && id != Guid.Empty
            ? id
            : throw Invalid("A durable operation ID is required.");

    private static Guid RequiredGuid(JsonElement payload, string name)
    {
        var value = RequiredString(payload, name, 64);
        if (!Guid.TryParse(value, out var id) || id == Guid.Empty)
            throw Invalid($"{name} must be a UUID.");
        return id;
    }

    private static string RequiredString(JsonElement payload, string name, int maximumLength)
    {
        if (!payload.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String)
            throw Invalid($"{name} is required.");
        var text = value.GetString() ?? "";
        if (text.Length > maximumLength) throw Invalid($"{name} is too long.");
        return text;
    }

    private static long RequiredLong(JsonElement payload, string name, long minimum, long maximum)
    {
        if (!payload.TryGetProperty(name, out var value) || !value.TryGetInt64(out var number) ||
            number < minimum || number > maximum)
            throw Invalid($"{name} is out of range.");
        return number;
    }

    private static string RequiredHash(JsonElement payload, string name)
    {
        var value = RequiredString(payload, name, 64);
        if (!HashPattern.IsMatch(value)) throw Invalid($"{name} must be lowercase SHA-256 hex.");
        return value;
    }

    private static string RequiredReleaseID(JsonElement payload, string name)
    {
        var value = RequiredString(payload, name, 128);
        if (string.IsNullOrWhiteSpace(value) || value.Contains('/') || value.Contains('\\') ||
            value.Any(char.IsControl))
            throw Invalid("Release ID is invalid.");
        return value;
    }

    private static string RequiredSecretID(JsonElement payload)
    {
        var value = RequiredString(payload, "secretID", 64);
        if (!SecretIDPattern.IsMatch(value)) throw Invalid("Secret ID is invalid.");
        return value;
    }

    private static AdminException Invalid(string message) =>
        new("invalid_request", message);

    private sealed class JoinRecord
    {
        public Guid PairingID { get; set; }
        public Guid PeerID { get; set; }
        public string SponsorID { get; set; } = "";
        public string GroupID { get; set; } = "";
        public bool Confirmed { get; set; }
        public string? StateOverride { get; set; }
        public DateTimeOffset CreatedAt { get; set; }
        public DateTimeOffset UpdatedAt { get; set; }
        public DateTimeOffset ExpiresAt { get; set; }
    }
}
