using System.Net.Sockets;
using System.Security.Cryptography;
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
    private readonly Dictionary<Guid, RequestMeta> _requestMeta = new();
    private readonly CancellationTokenSource _shutdown = new();
    private readonly DateTimeOffset _startedAt = DateTimeOffset.UtcNow;

    private FileStream? _instanceLock;
    private SessionStore? _store;
    private DeviceSyncService? _devices;
    private LinuxUpdateManager? _updates;
    private Socket? _adminSocket;
    private Socket? _secretSocket;
    private Task? _adminTask;
    private Task? _secretTask;
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
    public string SecretSocketPath => _paths.SecretSocketPath;
    public bool FabricStarted { get; private set; }
    public int ActiveTurnCount => _store?.Sessions.Count(session => session.Busy) ?? 0;

    public int OutstandingWorkCount => _devices?.WorkSnapshot().Total ?? ActiveTurnCount;

    public bool IsWorkQuiescent() => _devices?.IsWorkQuiescent() ?? ActiveTurnCount == 0;

    private static readonly HashSet<string> OrdinaryMutations = new(StringComparer.Ordinal)
    {
        "group.create", "pairing.join.begin", "pairing.bindPeerConnection",
        "pairing.join.confirm", "pairing.join.cancel", "pairing.request.review",
        "pairing.request.approve", "pairing.request.reject",
        "update.stage.begin", "update.stage.verify", "session.create",
    };

    private async Task<bool> OrdinaryWorkClosedAsync(CancellationToken cancellationToken)
    {
        if (_admission != StartupAdmission.Open) return true;
        if (_devices is not null && !_devices.AcceptingWork) return true;
        if (_ledger.IsInitialized)
        {
            var ledger = await _ledger.SnapshotAsync(cancellationToken);
            if (ledger.UpdateEpisode?.Phase is
                "draining_old_release" or "activating_new_release" or "probation_new_release")
                return true;
        }
        return false;
    }

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
            await _ledger.MarkAbandonedOperationsUncertainAsync(cancellationToken);
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
        StartSecretSocket();
        if (_options.EnableAgentTicker)
            _tickerTask = Task.Run(() => AgentTickerAsync(_shutdown.Token));
    }

    public async Task StopAsync()
    {
        _shutdown.Cancel();
        try { _adminSocket?.Dispose(); } catch { /* closing */ }
        try { _secretSocket?.Dispose(); } catch { /* closing */ }
        if (_adminTask is not null)
        {
            try { await _adminTask; } catch { /* shutdown */ }
        }
        if (_secretTask is not null)
        {
            try { await _secretTask; } catch { /* shutdown */ }
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
        try { if (File.Exists(_paths.SecretSocketPath)) File.Delete(_paths.SecretSocketPath); } catch { /* stale socket */ }
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
        var fabric = _devices;
        fabric.CanSuperviseSwitchboard = () =>
            !_shutdown.IsCancellationRequested &&
            _admission == StartupAdmission.Open &&
            fabric.AcceptingWork;
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
                // Agent ticks run on the serialized state executor so
                // supervision recovery cannot interleave with ledger, secret,
                // or update transitions. Tick itself refuses closed admission,
                // and CanSuperviseSwitchboard independently gates recovery.
                await _stateExecutor.RunAsync(() =>
                {
                    if (FabricStarted && _devices?.AcceptingWork == true &&
                        _admission == StartupAdmission.Open)
                        _devices.Agents.Tick(DateTime.UtcNow);
                }, cancellationToken);
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

    private void StartSecretSocket()
    {
        LinuxFileModes.Directory700(_paths.RuntimeDirectory);
        if (File.Exists(_paths.SecretSocketPath)) File.Delete(_paths.SecretSocketPath);
        _secretSocket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        _secretSocket.Bind(new UnixDomainSocketEndPoint(_paths.SecretSocketPath));
        _secretSocket.Listen(4);
        LinuxFileModes.File600(_paths.SecretSocketPath);
        _secretTask = Task.Run(() => SecretAcceptLoopAsync(_shutdown.Token));
    }

    private async Task SecretAcceptLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            Socket client;
            try { client = await _secretSocket!.AcceptAsync(cancellationToken); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) { return; }
            _ = Task.Run(() => HandleSecretClientAsync(client, cancellationToken), cancellationToken);
        }
    }

    private async Task HandleSecretClientAsync(Socket client, CancellationToken cancellationToken)
    {
        await using var stream = new NetworkStream(client, ownsSocket: true);
        SecretResponse response;
        Guid requestID = Guid.Empty;
        try
        {
            using var buffer = new MemoryStream();
            var chunk = new byte[4096];
            while (true)
            {
                var read = await stream.ReadAsync(chunk, cancellationToken);
                if (read == 0) break;
                if (buffer.Length + read > 96 * 1024)
                    throw new AdminException("invalid_request", "The secret request exceeds the size limit.");
                buffer.Write(chunk, 0, read);
            }
            var input = buffer.ToArray();
            var newline = Array.IndexOf(input, (byte)'\n');
            if (newline < 0)
                throw new AdminException("invalid_request", "The secret request header is missing.");
            var header = JsonSerializer.Deserialize<SecretRequestHeader>(
                    Encoding.UTF8.GetString(input, 0, newline).TrimEnd('\r'), AdminJson.Options)
                ?? throw new AdminException("invalid_request", "The secret request header is empty.");
            requestID = header.RequestID;
            var value = input.AsMemory(newline + 1);
            response = await DispatchSecretAsync(header, value, cancellationToken);
        }
        catch (AdminException error)
        {
            response = SecretResponse.Failure(
                requestID, error.Code, error.Message, error.Retryable, error.Uncertain);
        }
        catch (JsonException)
        {
            response = SecretResponse.Failure(
                requestID, "invalid_request", "The secret request header is not valid JSON.");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error)
        {
            response = SecretResponse.Failure(
                requestID, "internal_error", error.Message, retryable: true);
        }
        var bytes = Encoding.UTF8.GetBytes(AdminJson.Serialize(response) + "\n");
        await stream.WriteAsync(bytes, cancellationToken);
    }

    internal async Task<SecretResponse> DispatchSecretForTestsAsync(
        SecretRequestHeader header, ReadOnlyMemory<byte> value,
        CancellationToken cancellationToken = default) =>
        await DispatchSecretAsync(header, value, cancellationToken);

    private async Task<SecretResponse> DispatchSecretAsync(
        SecretRequestHeader header, ReadOnlyMemory<byte> value, CancellationToken cancellationToken)
    {
        return await _adminExecutor.RunAsync(async () =>
        {
            if (_devices is null)
                return SecretResponse.Failure(header.RequestID, "daemon_unavailable",
                    "The daemon is starting.", retryable: true);
            if (_recoveryRequired || _admission == StartupAdmission.RecoveryRequired)
                return SecretResponse.Failure(header.RequestID, "daemon_unavailable",
                    "The Linux home is closed until its recovery state is resolved.", retryable: true);
            if (header.SecretApiVersion != 1)
                return SecretResponse.Failure(header.RequestID, "unsupported_secret_api",
                    "This Linux home supports secret API version 1.");
            if (header.OperationID == Guid.Empty || header.RequestID == Guid.Empty ||
                !SecretIDPattern.IsMatch(header.SecretID) ||
                header.Action is not ("set" or "delete"))
                return SecretResponse.Failure(header.RequestID, "invalid_request",
                    "The secret request is invalid.");
            if (header.ExpectedDeviceID is not null &&
                !string.Equals(header.ExpectedDeviceID, _devices.DeviceId, StringComparison.Ordinal))
                return SecretResponse.Failure(header.RequestID, "identity_mismatch",
                    "The Linux Converse identity does not match this deployment.");
            if (await OrdinaryWorkClosedAsync(cancellationToken))
                return SecretResponse.Failure(header.RequestID, "daemon_unavailable",
                    "The Linux home is not accepting new work right now.", retryable: true);

            string? text = null;
            if (header.Action == "set")
            {
                if (header.Kind is not ("provider_api_key" or "webhook_url" or "oauth_token" or "other") ||
                    header.ValueByteCount is < 1 or > 16384 || value.Length != header.ValueByteCount ||
                    header.ValueSHA256 is null || !HashPattern.IsMatch(header.ValueSHA256) ||
                    !string.Equals(
                        Convert.ToHexString(SHA256.HashData(value.Span)).ToLowerInvariant(),
                        header.ValueSHA256, StringComparison.Ordinal))
                    return SecretResponse.Failure(header.RequestID, "invalid_request",
                        "The secret value does not match its header.");
                try { text = new UTF8Encoding(false, true).GetString(value.Span); }
                catch { return SecretResponse.Failure(header.RequestID, "invalid_request", "The secret value is not valid UTF-8."); }
            }
            else if (header.Kind is not null || header.ValueByteCount != 0 ||
                     header.ValueSHA256 is not null || value.Length != 0)
            {
                return SecretResponse.Failure(header.RequestID, "invalid_request",
                    "A delete request carries no secret value.");
            }

            var kind = header.Action == "set" ? "secret.set" : "secret.delete";
            var commitment = await _secrets.CommitmentAsync(
                kind, header.SecretID, header.Kind, value, cancellationToken);
            using var hashDocument = JsonDocument.Parse(JsonSerializer.Serialize(new Dictionary<string, object?>
            {
                ["action"] = header.Action,
                ["commitment"] = commitment,
                ["expectedDeviceID"] = header.ExpectedDeviceID,
                ["kind"] = header.Kind,
                ["secretID"] = header.SecretID,
                ["valueByteCount"] = header.ValueByteCount,
            }));
            var requestHash = AdminJson.PayloadHash(hashDocument.RootElement);

            LedgerOperation operation;
            try
            {
                var existing = await _ledger.GetOperationAsync(header.OperationID, cancellationToken);
                operation = await _ledger.BeginOperationAsync(
                    header.OperationID, kind, requestHash, null, "running", cancellationToken);
                if (existing is not null)
                {
                    var applied = await _secrets.AppliedForOperationAsync(
                        header.OperationID, cancellationToken);
                    if (operation.IsTerminal && operation.State == "completed" &&
                        applied is not null && applied.Commitment == commitment)
                        return SecretResponse.Success(
                            header.RequestID, ToReceipt(header.OperationID, applied.Metadata));
                    if (operation.State == "uncertain" && applied is not null &&
                        applied.Commitment == commitment)
                    {
                        await _ledger.TransitionOperationAsync(
                            header.OperationID, "completed", "reconciled",
                            resultRef: header.SecretID, cancellationToken: cancellationToken);
                        return SecretResponse.Success(
                            header.RequestID, ToReceipt(header.OperationID, applied.Metadata));
                    }
                    return SecretResponse.Failure(header.RequestID, "internal_error",
                        "That secret operation was already recorded; check its state instead of replaying it.",
                        uncertain: !operation.IsTerminal);
                }
            }
            catch (OperationConflictException error)
            {
                return SecretResponse.Failure(header.RequestID, "operation_conflict", error.Message);
            }

            try
            {
                SecretMetadata? metadata;
                if (header.Action == "set")
                {
                    metadata = await _secrets.SetAsync(
                        header.SecretID, header.Kind!, text!, cancellationToken,
                        header.OperationID, commitment);
                }
                else
                {
                    metadata = await _secrets.DeleteAsync(
                        header.SecretID, cancellationToken, header.OperationID, commitment);
                    if (metadata is null)
                    {
                        await _ledger.TransitionOperationAsync(
                            header.OperationID, "failed", "secret_not_found",
                            cancellationToken: cancellationToken);
                        return SecretResponse.Failure(header.RequestID, "secret_not_found",
                            "That secret is not configured.");
                    }
                }
                await _ledger.TransitionOperationAsync(
                    header.OperationID, "completed", header.Action == "set" ? "stored" : "deleted",
                    resultRef: header.SecretID, cancellationToken: cancellationToken);
                return SecretResponse.Success(header.RequestID, ToReceipt(header.OperationID, metadata));
            }
            catch (Exception error)
            {
                try
                {
                    await _ledger.TransitionOperationAsync(
                        header.OperationID, "uncertain", "secret_backend_failed",
                        cancellationToken: CancellationToken.None);
                }
                catch { /* The accepted receipt remains for startup reconciliation. */ }
                return SecretResponse.Failure(header.RequestID, "internal_error", error.Message,
                    uncertain: true);
            }
        }, cancellationToken);
    }

    private static SecretReceipt ToReceipt(Guid operationID, SecretMetadata metadata) => new()
    {
        OperationID = operationID,
        SecretID = metadata.SecretID,
        Kind = metadata.Kind,
        Backend = metadata.Backend,
        Configured = metadata.Configured,
        StoredVersion = metadata.StoredVersion,
        EffectiveVersion = metadata.EffectiveVersion,
        PendingRestart = metadata.PendingRestart,
        UpdatedAt = metadata.UpdatedAt,
    };

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

        if (OrdinaryMutations.Contains(request.Operation) &&
            await OrdinaryWorkClosedAsync(cancellationToken))
            return AdminResponse.Failure(
                request.RequestID, "admission_closed",
                "The Linux home is not accepting new work right now.", retryable: true);

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
                    var operationID = RequiredOperationID(request);
                    var replay = await ReplayMutationAsync(request, cancellationToken);
                    if (replay is not null)
                    {
                        return replay.IsTerminal && replay.State == "completed"
                            ? await SuccessWithOperationAsync(request.RequestID,
                                await BuildStatusAsync(cancellationToken), replay, cancellationToken)
                            : await OperationResponseAsync(request.RequestID, replay, cancellationToken);
                    }
                    var name = RequiredString(request.Payload, "name", 120);
                    if (string.IsNullOrWhiteSpace(name)) throw Invalid("Group name is empty.");
                    var operation = await BeginMutationAsync(request, cancellationToken);
                    try
                    {
                        var before = _devices.CurrentGroup?.Id;
                        await _devices.CreateGroupAsync(name);
                        if (_devices.CurrentGroup is null || _devices.CurrentGroup.Id == before ||
                            !string.Equals(_devices.CurrentGroup.Name, name.Trim(), StringComparison.Ordinal))
                            throw Invalid(string.IsNullOrWhiteSpace(_devices.LastOutcome)
                                ? "The group could not be created." : _devices.LastOutcome);
                        await SyncAuthorityAsync(cancellationToken);
                        await CompleteMutationAsync(
                            operationID, "created", _devices.CurrentGroup.Id, cancellationToken);
                        return await SuccessWithOperationAsync(request.RequestID,
                            await BuildStatusAsync(cancellationToken),
                            await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation,
                            cancellationToken);
                    }
                    catch (AdminException error)
                    {
                        await FailMutationAsync(operationID, error, cancellationToken);
                        throw;
                    }
                }
                case "pairing.join.begin":
                {
                    var operationID = RequiredOperationID(request);
                    var replay = await ReplayMutationAsync(request, cancellationToken);
                    if (replay is not null)
                    {
                        if (replay.State == "completed" &&
                            Guid.TryParse(replay.ResultRef, out var replayPairingID) &&
                            _joins.ContainsKey(replayPairingID))
                            return await SuccessWithOperationAsync(request.RequestID,
                                JoinStatus(replayPairingID), replay, cancellationToken);
                        return await OperationResponseAsync(request.RequestID, replay, cancellationToken);
                    }
                    var operation = await BeginMutationAsync(request, cancellationToken);
                    try
                    {
                        var binding = await BeginJoinAsync(request.Payload, cancellationToken);
                        await CompleteMutationAsync(
                            operationID, "begun", binding.PairingID.ToString("D"), cancellationToken);
                        return await SuccessWithOperationAsync(request.RequestID, binding,
                            await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation,
                            cancellationToken);
                    }
                    catch (AdminException error)
                    {
                        await FailMutationAsync(operationID, error, cancellationToken);
                        throw;
                    }
                }
                case "pairing.join.status":
                {
                    var pairingID = RequiredGuid(request.Payload, "pairingID");
                    var correlationID = RequiredGuid(request.Payload, "requestCorrelationID");
                    if (!_joins.TryGetValue(pairingID, out var join))
                        throw new AdminException("pairing_not_found", "That pairing attempt was not found.");
                    if (join.RequestCorrelationID != correlationID)
                        throw new AdminException("pairing_binding_mismatch",
                            "The request correlation does not match this pairing attempt.");
                    return AdminResponse.Success(request.RequestID, JoinStatus(pairingID));
                }
                case "pairing.bindPeerConnection":
                {
                    var operationID = RequiredOperationID(request);
                    var supplied = RequiredBinding(request.Payload);
                    var replay = await ReplayMutationAsync(request, cancellationToken);
                    if (replay is not null)
                        return await PairingReplayResponseAsync(request, supplied, replay, cancellationToken);
                    var current = ValidateBindPeerConnection(supplied);
                    var operation = await BeginMutationAsync(request, cancellationToken);
                    try
                    {
                        var binding = ApplyBindPeerConnection(supplied, current);
                        await CompleteMutationAsync(
                            operationID, "bound", binding.PairingID.ToString("D"), cancellationToken);
                        return await SuccessWithOperationAsync(request.RequestID, binding,
                            await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation,
                            cancellationToken);
                    }
                    catch (AdminException error)
                    {
                        await FailMutationAsync(operationID, error, cancellationToken);
                        throw;
                    }
                }
                case "pairing.join.confirm":
                {
                    var operationID = RequiredOperationID(request);
                    var supplied = RequiredBinding(request.Payload);
                    var replay = await ReplayMutationAsync(request, cancellationToken);
                    if (replay is not null)
                        return await PairingReplayResponseAsync(request, supplied, replay, cancellationToken);
                    var current = ValidateJoinBinding(supplied, requireCodeFingerprint: true);
                    var operation = await BeginMutationAsync(request, cancellationToken);
                    try
                    {
                        var binding = await ConfirmJoinAsync(current.PairingID);
                        await CompleteMutationAsync(
                            operationID, "confirmed", binding.PairingID.ToString("D"), cancellationToken);
                        return await SuccessWithOperationAsync(request.RequestID, binding,
                            await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation,
                            cancellationToken);
                    }
                    catch (AdminException error)
                    {
                        await FailMutationAsync(operationID, error, cancellationToken);
                        throw;
                    }
                }
                case "pairing.join.cancel":
                {
                    var operationID = RequiredOperationID(request);
                    var supplied = RequiredBinding(request.Payload);
                    var replay = await ReplayMutationAsync(request, cancellationToken);
                    if (replay is not null)
                        return await PairingReplayResponseAsync(request, supplied, replay, cancellationToken);
                    var current = ValidateJoinBinding(supplied, requireCodeFingerprint: false);
                    var operation = await BeginMutationAsync(request, cancellationToken);
                    try
                    {
                        var binding = CancelJoin(current.PairingID);
                        await CompleteMutationAsync(
                            operationID, "rejected", binding.PairingID.ToString("D"), cancellationToken);
                        return await SuccessWithOperationAsync(request.RequestID, binding,
                            await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation,
                            cancellationToken);
                    }
                    catch (AdminException error)
                    {
                        await FailMutationAsync(operationID, error, cancellationToken);
                        throw;
                    }
                }
                case "pairing.requests.list":
                    return AdminResponse.Success(request.RequestID, new PairingListResult
                    {
                        Requests = SnapshotGroupRequests().Select(item => RequestBinding(item, false)).ToList(),
                    });
                case "pairing.request.review":
                {
                    var operationID = RequiredOperationID(request);
                    var supplied = RequiredBinding(request.Payload);
                    var replay = await ReplayMutationAsync(request, cancellationToken);
                    if (replay is not null)
                        return await PairingReplayResponseAsync(request, supplied, replay, cancellationToken);
                    var current = ValidateRequestBinding(supplied, requireCodeFingerprint: false);
                    var operation = await BeginMutationAsync(request, cancellationToken);
                    try
                    {
                        var binding = await ReviewRequestAsync(current.PairingID, cancellationToken);
                        await CompleteMutationAsync(
                            operationID, "reviewed", binding.PairingID.ToString("D"), cancellationToken);
                        return await SuccessWithOperationAsync(request.RequestID, binding,
                            await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation,
                            cancellationToken);
                    }
                    catch (AdminException error)
                    {
                        await FailMutationAsync(operationID, error, cancellationToken);
                        throw;
                    }
                }
                case "pairing.request.approve":
                {
                    var operationID = RequiredOperationID(request);
                    var supplied = RequiredBinding(request.Payload);
                    var replay = await ReplayMutationAsync(request, cancellationToken);
                    if (replay is not null)
                        return await PairingReplayResponseAsync(request, supplied, replay, cancellationToken);
                    var current = ValidateRequestBinding(supplied, requireCodeFingerprint: true);
                    var operation = await BeginMutationAsync(request, cancellationToken);
                    try
                    {
                        var binding = await ApproveRequestAsync(current.PairingID);
                        await CompleteMutationAsync(
                            operationID, "approved", binding.PairingID.ToString("D"), cancellationToken);
                        return await SuccessWithOperationAsync(request.RequestID, binding,
                            await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation,
                            cancellationToken);
                    }
                    catch (AdminException error)
                    {
                        await FailMutationAsync(operationID, error, cancellationToken);
                        throw;
                    }
                }
                case "pairing.request.reject":
                {
                    var operationID = RequiredOperationID(request);
                    var supplied = RequiredBinding(request.Payload);
                    var replay = await ReplayMutationAsync(request, cancellationToken);
                    if (replay is not null)
                        return await PairingReplayResponseAsync(request, supplied, replay, cancellationToken);
                    var current = ValidateRequestBinding(supplied, requireCodeFingerprint: false);
                    var operation = await BeginMutationAsync(request, cancellationToken);
                    try
                    {
                        var binding = RejectRequest(current.PairingID);
                        await CompleteMutationAsync(
                            operationID, "rejected", binding.PairingID.ToString("D"), cancellationToken);
                        return await SuccessWithOperationAsync(request.RequestID, binding,
                            await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation,
                            cancellationToken);
                    }
                    catch (AdminException error)
                    {
                        await FailMutationAsync(operationID, error, cancellationToken);
                        throw;
                    }
                }
                case "update.stage.begin":
                {
                    var operationID = RequiredOperationID(request);
                    var replay = await ReplayMutationAsync(request, cancellationToken);
                    if (replay is not null)
                    {
                        if (replay.State == "completed" &&
                            Guid.TryParse(replay.ResultRef, out var replayUploadID) &&
                            _updates.Snapshot().Uploads.FirstOrDefault(
                                upload => upload.UploadID == replayUploadID) is { } replayUpload)
                            return await SuccessWithOperationAsync(request.RequestID, new StageBeginResult
                            {
                                UploadID = replayUpload.UploadID,
                                UploadPath = replayUpload.UploadPath,
                                ExpiresAt = replayUpload.ExpiresAt,
                            }, replay, cancellationToken);
                        return await OperationResponseAsync(request.RequestID, replay, cancellationToken);
                    }
                    var releaseID = RequiredReleaseID(request.Payload, "releaseID");
                    var hash = RequiredHash(request.Payload, "bundleSHA256");
                    var size = RequiredLong(request.Payload, "bundleSize", 1, 536870912);
                    var operation = await BeginMutationAsync(request, cancellationToken);
                    try
                    {
                        var result = await _updates.StageBeginAsync(releaseID, hash, size, cancellationToken);
                        await CompleteMutationAsync(
                            operationID, "staged", result.UploadID.ToString("D"), cancellationToken);
                        return await SuccessWithOperationAsync(request.RequestID, result,
                            await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation,
                            cancellationToken);
                    }
                    catch (AdminException error)
                    {
                        await FailMutationAsync(operationID, error, cancellationToken);
                        throw;
                    }
                }
                case "update.stage.verify":
                {
                    var operationID = RequiredOperationID(request);
                    var replay = await ReplayMutationAsync(request, cancellationToken);
                    if (replay is not null)
                    {
                        var parts = (replay.ResultRef ?? "").Split('|');
                        if (replay.State == "completed" && parts.Length == 2)
                            return await SuccessWithOperationAsync(request.RequestID, new StageVerifyResult
                            {
                                ReleaseID = parts[0],
                                ArtifactSHA256 = parts[1],
                            }, replay, cancellationToken);
                        return await OperationResponseAsync(request.RequestID, replay, cancellationToken);
                    }
                    var operation = await BeginMutationAsync(request, cancellationToken);
                    try
                    {
                        var result = await _updates.StageVerifyAsync(
                            RequiredGuid(request.Payload, "uploadID"), cancellationToken);
                        await CompleteMutationAsync(
                            operationID, "verified", result.ReleaseID + "|" + result.ArtifactSHA256,
                            cancellationToken);
                        return await SuccessWithOperationAsync(request.RequestID, result,
                            await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation,
                            cancellationToken);
                    }
                    catch (AdminException error)
                    {
                        await FailMutationAsync(operationID, error, cancellationToken);
                        throw;
                    }
                }
                case "update.activate":
                {
                    var operationID = RequiredOperationID(request);
                    var operation = await _updates.ActivateAsync(
                        operationID,
                        AdminJson.RequestHash(request),
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
                        AdminJson.RequestHash(request),
                        RequiredGuid(request.Payload, "episodeID"),
                        cancellationToken);
                    return await OperationResponseAsync(request.RequestID, operation, cancellationToken);
                }
                case "update.rollback":
                {
                    var operationID = RequiredOperationID(request);
                    var operation = await _updates.RollbackAsync(
                        operationID,
                        AdminJson.RequestHash(request),
                        RequiredGuid(request.Payload, "episodeID"),
                        RequiredString(request.Payload, "reason", 500),
                        cancellationToken);
                    return await OperationResponseAsync(request.RequestID, operation, cancellationToken);
                }
                case "session.create":
                {
                    var operationID = RequiredOperationID(request);
                    var replay = await ReplayMutationAsync(request, cancellationToken);
                    if (replay is not null)
                    {
                        if (replay.State == "completed" &&
                            Guid.TryParse(replay.ResultRef, out var replaySessionID))
                        {
                            var existing = _store.Sessions.FirstOrDefault(
                                session => session.Id == replaySessionID);
                            if (existing is not null)
                                return await SuccessWithOperationAsync(request.RequestID,
                                    SessionResult(existing), replay, cancellationToken);
                        }
                        return await OperationResponseAsync(request.RequestID, replay, cancellationToken);
                    }
                    var parsed = ParseSessionCreate(request.Payload);
                    var operation = await BeginMutationAsync(request, cancellationToken);
                    try
                    {
                        var session = CreateSession(parsed);
                        await CompleteMutationAsync(
                            operationID, "created", session.Id.ToString("D"), cancellationToken);
                        return await SuccessWithOperationAsync(request.RequestID,
                            SessionResult(session),
                            await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation,
                            cancellationToken);
                    }
                    catch (AdminException error)
                    {
                        await FailMutationAsync(operationID, error, cancellationToken);
                        throw;
                    }
                }
                case "service.start":
                {
                    var operationID = RequiredOperationID(request);
                    var operation = await _ledger.BeginOperationAsync(
                        operationID, "service.start", AdminJson.RequestHash(request),
                        null, "running", cancellationToken);
                    if (!operation.IsTerminal)
                    {
                        _paths.WriteDesiredRunning(true);
                        await _ledger.TransitionOperationAsync(
                            operationID, "completed", "started",
                            resultRef: _updates.Snapshot().Supervisor,
                            cancellationToken: cancellationToken);
                        operation = await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation;
                    }
                    return await OperationResponseAsync(request.RequestID, operation, cancellationToken);
                }
                case "service.stop":
                {
                    var operationID = RequiredOperationID(request);
                    var operation = await _ledger.BeginOperationAsync(
                        operationID, "service.stop", AdminJson.RequestHash(request),
                        null, "running", cancellationToken);
                    if (!operation.IsTerminal)
                    {
                        _paths.WriteDesiredRunning(false);
                        SetAcceptingWork(false);
                        await _ledger.TransitionOperationAsync(
                            operationID, "completed", "stopped",
                            resultRef: _updates.Snapshot().Supervisor,
                            cancellationToken: cancellationToken);
                        operation = await _ledger.GetOperationAsync(operationID, cancellationToken) ?? operation;
                        RequestRestart("service stop");
                    }
                    return await OperationResponseAsync(request.RequestID, operation, cancellationToken);
                }
                case "service.restart":
                {
                    var operationID = RequiredOperationID(request);
                    var operation = await _ledger.BeginOperationAsync(
                        operationID, "service.restart", AdminJson.RequestHash(request),
                        null, "running", cancellationToken);
                    if (!operation.IsTerminal)
                    {
                        _paths.WriteDesiredRunning(true);
                        RequestRestart("admin request");
                    }
                    return await OperationResponseAsync(request.RequestID, operation, cancellationToken);
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

    private async Task<LedgerOperation?> ReplayMutationAsync(
        AdminRequest request, CancellationToken cancellationToken)
    {
        var operationID = RequiredOperationID(request);
        var existing = await _ledger.GetOperationAsync(operationID, cancellationToken);
        if (existing is null) return null;
        return await _ledger.BeginOperationAsync(
            operationID, request.Operation, AdminJson.RequestHash(request),
            existing.EpisodeID, cancellationToken: cancellationToken);
    }

    private async Task<LedgerOperation> BeginMutationAsync(
        AdminRequest request, CancellationToken cancellationToken) =>
        await _ledger.BeginOperationAsync(
            RequiredOperationID(request), request.Operation, AdminJson.RequestHash(request),
            null, "running", cancellationToken);

    private async Task CompleteMutationAsync(
        Guid operationID, string resultCode, string? resultRef, CancellationToken cancellationToken) =>
        await _ledger.TransitionOperationAsync(
            operationID, "completed", resultCode, resultRef: resultRef,
            cancellationToken: cancellationToken);

    private async Task FailMutationAsync(
        Guid operationID, AdminException error, CancellationToken cancellationToken)
    {
        try
        {
            await _ledger.TransitionOperationAsync(
                operationID, error.Uncertain ? "uncertain" : "failed", error.Code,
                cancellationToken: cancellationToken);
        }
        catch { /* The original admin error remains the response. */ }
    }

    private async Task<AdminResponse> SuccessWithOperationAsync(
        Guid requestID, object? result, LedgerOperation operation,
        CancellationToken cancellationToken)
    {
        var ledger = await _ledger.SnapshotAsync(cancellationToken);
        return AdminResponse.Success(requestID, result,
            LinuxUpdateManager.ToAdminOperation(operation, ledger.UpdateEpisode));
    }

    private async Task<AdminResponse> PairingReplayResponseAsync(
        AdminRequest request, PairingBinding supplied, LedgerOperation replay,
        CancellationToken cancellationToken)
    {
        if (replay.State == "completed")
        {
            try
            {
                var binding = supplied.Role == "joiner"
                    ? JoinStatus(supplied.PairingID)
                    : CurrentRequestBinding(supplied.PairingID, includeCode: false);
                if (replay.ResultCode is "confirmed" or "approved" or "rejected")
                {
                    binding.State = replay.ResultCode;
                    binding.VerificationCode = null;
                }
                return await SuccessWithOperationAsync(
                    request.RequestID, binding, replay, cancellationToken);
            }
            catch (AdminException) { /* Fall through to the durable operation. */ }
        }
        return await OperationResponseAsync(request.RequestID, replay, cancellationToken);
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
                DesiredRunning = _paths.DesiredRunning,
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
                "linux-home-v1", "admin-v1", "offline-status-v1", "secret-stdin-v1",
                "fabric-membership-v1", "converse-groups-v1", "agent-host-v1",
            ],
        };
    }

    private async Task<PairingBinding> BeginJoinAsync(
        JsonElement payload, CancellationToken cancellationToken)
    {
        if (!FabricStarted)
            throw new AdminException("admission_closed", "The fabric service is not running.", retryable: true);
        var correlationID = RequiredGuid(payload, "requestCorrelationID");
        var sponsorID = RequiredString(payload, "sponsorDeviceID", 64);
        var sponsorFingerprint = RequiredString(payload, "sponsorPublicKeyFingerprint", 64);
        if (!DeviceIDPattern.IsMatch(sponsorID) || sponsorID == _devices!.DeviceId ||
            !string.Equals(sponsorFingerprint, sponsorID, StringComparison.Ordinal))
            throw new AdminException("pairing_binding_mismatch",
                "The sponsor fingerprint does not match the sponsor device ID.");
        var duplicate = _joins.Values.FirstOrDefault(record =>
            record.RequestCorrelationID == correlationID && record.SponsorID == sponsorID &&
            string.Equals(record.GroupID,
                RequiredGuid(payload, "groupID").ToString("D"), StringComparison.OrdinalIgnoreCase) &&
            record.StateOverride is null && DateTimeOffset.UtcNow <= record.ExpiresAt);
        if (duplicate is not null) return JoinStatus(duplicate.PairingID);
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
            RequestCorrelationID = correlationID,
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
        else state = record.Confirmed ? "awaiting_peer" : "connecting";

        var group = devices.KnownGroups.FirstOrDefault(
            item => string.Equals(item.Id, record.GroupID, StringComparison.OrdinalIgnoreCase));
        var peerName = prompt?.PeerName ??
            devices.Trust.Records.FirstOrDefault(device => device.DeviceID == record.SponsorID)?.Name ?? "";
        return new PairingBinding
        {
            PairingID = record.PairingID,
            RequestCorrelationID = record.RequestCorrelationID,
            NativeRequestID = record.NativeRequestID,
            Role = "joiner",
            State = state,
            LinuxDeviceID = devices.DeviceId,
            RequesterDeviceID = devices.DeviceId,
            SponsorDeviceID = record.SponsorID,
            PeerName = peerName,
            LinuxPublicKeyFingerprint = devices.DeviceId,
            RequesterPublicKeyFingerprint = devices.DeviceId,
            SponsorPublicKeyFingerprint = record.SponsorID,
            GroupID = record.GroupID,
            GroupName = group?.Name,
            RequesterConnectionInstanceID = record.PeerID == Guid.Empty ? null : record.PeerID,
            SponsorConnectionInstanceID = record.SponsorConnectionInstanceID,
            VerificationCode = state == "awaiting_user" ? prompt?.Code : null,
            VerificationCodeFingerprint = prompt is null ? null : CodeFingerprint(prompt.Code),
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

    private RequestMeta MetaFor(Guid requestID)
    {
        if (!_requestMeta.TryGetValue(requestID, out var meta))
        {
            meta = new RequestMeta
            {
                RequestCorrelationID = Guid.NewGuid(),
                CreatedAt = LinuxTime.Now(),
            };
            _requestMeta[requestID] = meta;
        }
        return meta;
    }

    private PairingBinding CurrentRequestBinding(Guid pairingID, bool includeCode)
    {
        var request = SnapshotGroupRequests().FirstOrDefault(item => item.Id == pairingID)
            ?? throw new AdminException("pairing_not_found", "That group request was not found.");
        return RequestBinding(request, includeCode);
    }

    private PairingBinding RequestBinding(GroupJoinRequest request, bool includeCode)
    {
        var devices = _devices!;
        var meta = MetaFor(request.Id);
        var review = devices.GroupReview;
        var reviewCode = review?.Request.Id == request.Id ? review.Code : null;
        var code = includeCode ? reviewCode : null;
        var group = devices.KnownGroups.FirstOrDefault(
            item => string.Equals(item.Id, request.GroupID, StringComparison.OrdinalIgnoreCase));
        return new PairingBinding
        {
            PairingID = request.Id,
            RequestCorrelationID = meta.RequestCorrelationID,
            NativeRequestID = request.Id,
            Role = "reviewer",
            State = code is null && includeCode ? "connecting" : "awaiting_user",
            LinuxDeviceID = devices.DeviceId,
            RequesterDeviceID = request.RequesterID,
            SponsorDeviceID = request.SponsorID,
            PeerName = request.RequesterName,
            LinuxPublicKeyFingerprint = devices.DeviceId,
            RequesterPublicKeyFingerprint = request.RequesterID,
            SponsorPublicKeyFingerprint = request.SponsorID,
            GroupID = request.GroupID,
            GroupName = group?.Name ?? devices.CurrentGroup?.Name,
            RequesterConnectionInstanceID = meta.RequesterConnectionInstanceID,
            SponsorConnectionInstanceID = request.Id,
            VerificationCode = code,
            VerificationCodeFingerprint = includeCode && reviewCode is not null
                ? CodeFingerprint(reviewCode) : null,
            ExpiresAt = LinuxTime.FromAppleEpoch(request.ExpiresAt),
            CreatedAt = meta.CreatedAt,
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

    private static string CodeFingerprint(string code) =>
        Convert.ToHexString(SHA256.HashData(
            Encoding.UTF8.GetBytes(code.Replace(" ", "")))).ToLowerInvariant();

    private static PairingBinding RequiredBinding(JsonElement payload)
    {
        if (!payload.TryGetProperty("binding", out var binding) ||
            binding.ValueKind != JsonValueKind.Object)
            throw Invalid("A full pairing binding is required.");
        PairingBinding parsed;
        try
        {
            parsed = JsonSerializer.Deserialize<PairingBinding>(binding.GetRawText(), AdminJson.Options)
                ?? throw Invalid("The pairing binding is empty.");
        }
        catch (JsonException) { throw Invalid("The pairing binding is invalid."); }
        if (parsed.BindingVersion != 1 || parsed.PairingID == Guid.Empty ||
            parsed.RequestCorrelationID == Guid.Empty)
            throw Invalid("The pairing binding is invalid.");
        return parsed;
    }

    private static AdminException BindingMismatch() => new(
        "pairing_binding_mismatch",
        "The pairing changed since it was shown. Refresh and compare the new code.");

    private PairingBinding ValidateJoinBinding(PairingBinding supplied, bool requireCodeFingerprint)
    {
        if (supplied.Role != "joiner") throw BindingMismatch();
        var current = JoinStatus(supplied.PairingID);
        if (current.State == "expired")
            throw new AdminException("pairing_expired", "That pairing attempt has expired.");
        ValidateStableBinding(supplied, current, requireCodeFingerprint, forBind: false);
        if (SnapshotPrompts().FirstOrDefault(prompt =>
                prompt.PeerId == current.RequesterConnectionInstanceID) is { } prompt &&
            !string.Equals(prompt.Fingerprint,
                current.SponsorDeviceID[..Math.Min(16, current.SponsorDeviceID.Length)],
                StringComparison.OrdinalIgnoreCase))
            throw BindingMismatch();
        return current;
    }

    private PairingBinding ValidateRequestBinding(PairingBinding supplied, bool requireCodeFingerprint)
    {
        if (supplied.Role != "reviewer") throw BindingMismatch();
        var current = CurrentRequestBinding(supplied.PairingID, includeCode: true);
        ValidateStableBinding(supplied, current, requireCodeFingerprint, forBind: false);
        return current;
    }

    private PairingBinding ValidateBindPeerConnection(PairingBinding supplied)
    {
        var current = supplied.Role switch
        {
            "joiner" => JoinStatus(supplied.PairingID),
            "reviewer" => CurrentRequestBinding(supplied.PairingID, includeCode: true),
            _ => throw BindingMismatch(),
        };
        if (current.State == "expired")
            throw new AdminException("pairing_expired", "That pairing attempt has expired.");
        ValidateStableBinding(supplied, current, requireCodeFingerprint: false, forBind: true);
        return current;
    }

    private PairingBinding ApplyBindPeerConnection(PairingBinding supplied, PairingBinding current)
    {
        if (supplied.Role == "joiner")
        {
            var record = _joins[supplied.PairingID];
            if (supplied.NativeRequestID is not null &&
                supplied.SponsorConnectionInstanceID is not null &&
                supplied.NativeRequestID != supplied.SponsorConnectionInstanceID)
                throw BindingMismatch();
            record.NativeRequestID ??= supplied.NativeRequestID;
            record.SponsorConnectionInstanceID ??=
                supplied.SponsorConnectionInstanceID ?? supplied.NativeRequestID;
            record.NativeRequestID ??= record.SponsorConnectionInstanceID;
            record.UpdatedAt = DateTimeOffset.UtcNow;
            return JoinStatus(supplied.PairingID);
        }
        var meta = MetaFor(supplied.PairingID);
        meta.RequesterConnectionInstanceID ??= supplied.RequesterConnectionInstanceID;
        return CurrentRequestBinding(supplied.PairingID, includeCode: true);
    }

    private static void ValidateStableBinding(
        PairingBinding supplied, PairingBinding current,
        bool requireCodeFingerprint, bool forBind)
    {
        static bool Eq(string? left, string? right) =>
            string.Equals(left, right, StringComparison.Ordinal);
        var mismatch =
            supplied.PairingID != current.PairingID ||
            supplied.RequestCorrelationID != current.RequestCorrelationID ||
            supplied.Role != current.Role ||
            !Eq(supplied.LinuxDeviceID, current.LinuxDeviceID) ||
            !Eq(supplied.RequesterDeviceID, current.RequesterDeviceID) ||
            !Eq(supplied.SponsorDeviceID, current.SponsorDeviceID) ||
            !Eq(supplied.PeerName, current.PeerName) ||
            !Eq(supplied.LinuxPublicKeyFingerprint, current.LinuxPublicKeyFingerprint) ||
            !Eq(supplied.RequesterPublicKeyFingerprint, current.RequesterPublicKeyFingerprint) ||
            !Eq(supplied.SponsorPublicKeyFingerprint, current.SponsorPublicKeyFingerprint) ||
            !Eq(supplied.LinuxPublicKeyFingerprint, supplied.LinuxDeviceID) ||
            !Eq(supplied.RequesterPublicKeyFingerprint, supplied.RequesterDeviceID) ||
            !Eq(supplied.SponsorPublicKeyFingerprint, supplied.SponsorDeviceID) ||
            !Eq(supplied.GroupID, current.GroupID) ||
            !Eq(supplied.GroupName, current.GroupName) ||
            !Eq(supplied.ExpiresAt, current.ExpiresAt);
        if (forBind)
        {
            mismatch |= current.NativeRequestID is not null &&
                supplied.NativeRequestID != current.NativeRequestID;
            mismatch |= current.RequesterConnectionInstanceID is not null &&
                supplied.RequesterConnectionInstanceID != current.RequesterConnectionInstanceID;
            mismatch |= current.SponsorConnectionInstanceID is not null &&
                supplied.SponsorConnectionInstanceID != current.SponsorConnectionInstanceID;
        }
        else
        {
            mismatch |= supplied.NativeRequestID != current.NativeRequestID ||
                supplied.RequesterConnectionInstanceID != current.RequesterConnectionInstanceID ||
                supplied.SponsorConnectionInstanceID != current.SponsorConnectionInstanceID;
        }
        if (supplied.VerificationCode is not null)
        {
            mismatch |= supplied.VerificationCodeFingerprint is not null &&
                supplied.VerificationCodeFingerprint != CodeFingerprint(supplied.VerificationCode);
            mismatch |= current.VerificationCodeFingerprint is not null &&
                CodeFingerprint(supplied.VerificationCode) != current.VerificationCodeFingerprint;
        }
        if (requireCodeFingerprint)
        {
            mismatch |= supplied.VerificationCodeFingerprint is null ||
                current.VerificationCodeFingerprint is null ||
                supplied.VerificationCodeFingerprint != current.VerificationCodeFingerprint;
        }
        else if (supplied.VerificationCodeFingerprint is not null &&
                 current.VerificationCodeFingerprint is not null)
        {
            mismatch |= supplied.VerificationCodeFingerprint != current.VerificationCodeFingerprint;
        }
        if (mismatch) throw BindingMismatch();
    }

    private sealed record SessionCreateRequest(
        Guid SessionID, string Engine, string? Title, Guid? EntryID, string? EntryName,
        string? WorkingDirectory, string? Model, string? Effort, string? Access,
        bool MessagingEnabled);

    private SessionCreateRequest ParseSessionCreate(JsonElement payload)
    {
        var sessionID = RequiredGuid(payload, "sessionID");
        var engine = RequiredString(payload, "engine", 20);
        if (engine is not ("claude" or "codex" or "muse" or "agent"))
            throw Invalid("Session engine is invalid.");
        if (!payload.TryGetProperty("messagingEnabled", out var messaging) ||
            messaging.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            throw Invalid("messagingEnabled is required.");
        return new SessionCreateRequest(
            sessionID, engine,
            RequiredNullableString(payload, "title", 200),
            RequiredNullableGuid(payload, "entryID"),
            RequiredNullableString(payload, "entryName", 200),
            RequiredNullableString(payload, "workingDirectory", 500),
            RequiredNullableString(payload, "model", 200),
            RequiredNullableString(payload, "effort", 200),
            RequiredNullableString(payload, "access", 200),
            messaging.GetBoolean());
    }

    private ChatSession CreateSession(SessionCreateRequest parsed)
    {
        var existing = _store!.Sessions.FirstOrDefault(session => session.Id == parsed.SessionID);
        if (existing is not null)
        {
            if (existing.Entry.Engine == parsed.Engine &&
                (parsed.Title is null || existing.Title == parsed.Title))
                return existing;
            throw new AdminException("operation_conflict",
                "That session ID already belongs to a different session.");
        }
        if (parsed.WorkingDirectory is not null &&
            (!parsed.WorkingDirectory.StartsWith('/') || parsed.WorkingDirectory.Any(char.IsControl)))
            throw Invalid("Working directory must be an absolute Linux path.");

        ChatSession session;
        if (parsed.Engine == "agent")
        {
            session = new ChatSession
            {
                Id = parsed.SessionID,
                Title = parsed.Title ?? parsed.EntryName ?? "Agent",
                Agent = new AgentConfig(),
                MessagingEnabled = parsed.MessagingEnabled,
                Entry = new AgentEntry
                {
                    Name = parsed.EntryName ?? "Agent",
                    Engine = "agent",
                    Directory = parsed.WorkingDirectory ?? _paths.Home,
                },
            };
            session.Messages.Add(new ChatMessage
            {
                Role = "assistant",
                Text = "Open Agent Setup to add a Meta API key on this computer and select the sessions I may read. Automatic loops start paused.",
            });
        }
        else
        {
            AgentEntry template;
            if (parsed.EntryID is { } entryID)
            {
                template = _store.Entries.FirstOrDefault(entry => entry.Id == entryID)
                    ?? throw Invalid("That provider entry was not found on the Linux home.");
                if (template.Engine != parsed.Engine)
                    throw Invalid("The provider entry engine does not match.");
            }
            else
            {
                template = _store.Entries.FirstOrDefault(entry => entry.Engine == parsed.Engine)
                    ?? new AgentEntry
                    {
                        Name = parsed.EntryName ?? parsed.Engine,
                        Command = parsed.Engine,
                        Engine = parsed.Engine,
                        Directory = _paths.Home,
                    };
            }
            var entry = template.Copy();
            if (parsed.EntryName is not null) entry.Name = parsed.EntryName;
            if (parsed.WorkingDirectory is not null) entry.Directory = parsed.WorkingDirectory;
            session = new ChatSession
            {
                Id = parsed.SessionID,
                Title = parsed.Title ?? entry.Name,
                Entry = entry,
                MessagingEnabled = parsed.MessagingEnabled,
                Choices = new SessionChoices
                {
                    Model = parsed.Model,
                    Effort = parsed.Effort,
                    Access = parsed.Access,
                },
            };
            session.Messages.Add(new ChatMessage
            {
                Role = "system", Text = "", CreatedAt = DateTime.UtcNow,
            });
        }
        _store.Sessions.Add(session);
        _store.Save();
        return session;
    }

    private SessionCreateResult SessionResult(ChatSession session) => new()
    {
        SessionID = session.Id,
        GlobalID = new DeviceGlobalID(_devices!.DeviceId, session.Id).ToString(),
        Title = session.Title,
        Engine = session.Entry.Engine,
    };

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

    private static string? RequiredNullableString(
        JsonElement payload, string name, int maximumLength)
    {
        if (!payload.TryGetProperty(name, out var value))
            throw Invalid($"{name} is required.");
        if (value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.String)
            throw Invalid($"{name} is invalid.");
        var text = value.GetString() ?? "";
        if (text.Length == 0 || text.Length > maximumLength)
            throw Invalid($"{name} is invalid.");
        return text;
    }

    private static Guid? RequiredNullableGuid(JsonElement payload, string name)
    {
        if (!payload.TryGetProperty(name, out var value))
            throw Invalid($"{name} is required.");
        if (value.ValueKind == JsonValueKind.Null) return null;
        var text = value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        if (!Guid.TryParse(text, out var id) || id == Guid.Empty)
            throw Invalid($"{name} must be a UUID.");
        return id;
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

    private sealed class RequestMeta
    {
        public Guid RequestCorrelationID { get; set; }
        public Guid? RequesterConnectionInstanceID { get; set; }
        public string CreatedAt { get; set; } = "";
    }

    private sealed class JoinRecord
    {
        public Guid PairingID { get; set; }
        public Guid RequestCorrelationID { get; set; }
        public Guid? NativeRequestID { get; set; }
        public Guid? SponsorConnectionInstanceID { get; set; }
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
