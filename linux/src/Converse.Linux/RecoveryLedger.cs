using System.Text.Json;
using System.Text.Json.Serialization;
using Converse.Core;

namespace Converse.Linux;

internal sealed class RecoveryRequiredException(string message) : InvalidOperationException(message);

internal sealed class OperationConflictException(string message) : InvalidOperationException(message);

internal sealed class RecoveryLedger
{
    [JsonPropertyName("ledgerVersion")] public int LedgerVersion { get; set; } = 1;
    [JsonPropertyName("deviceID")] public string DeviceID { get; set; } = "";
    [JsonPropertyName("sequence")] public ulong Sequence { get; set; }
    [JsonPropertyName("updatedAt")] public string UpdatedAt { get; set; } = "";
    [JsonPropertyName("counterFloors")] public LedgerCounterFloors CounterFloors { get; set; } = new();
    [JsonPropertyName("commandReceipts")] public List<LedgerCommandReceipt> CommandReceipts { get; set; } = new();
    [JsonPropertyName("operations")] public List<LedgerOperation> Operations { get; set; } = new();
    [JsonPropertyName("membership")] public LedgerMembership Membership { get; set; } = new();
    [JsonPropertyName("dissolvedGroupIDs")] public List<string> DissolvedGroupIDs { get; set; } = new();
    [JsonPropertyName("displayRestorations")] public List<LedgerDisplayRestoration> DisplayRestorations { get; set; } = new();
    [JsonPropertyName("updateEpisode")] public UpdateEpisode? UpdateEpisode { get; set; }
}

internal sealed class LedgerCounterFloors
{
    [JsonPropertyName("nextBoot")] public ulong NextBoot { get; set; } = 1;
    [JsonPropertyName("nextHomeSeq")] public ulong NextHomeSeq { get; set; } = 1;
    [JsonPropertyName("nextLeaseEpoch")] public ulong NextLeaseEpoch { get; set; } = (1UL << 48) + 1;
    [JsonPropertyName("nextMembershipGeneration")] public ulong NextMembershipGeneration { get; set; } = 1;
}

internal sealed class LedgerCommandReceipt
{
    [JsonPropertyName("commandID")] public Guid CommandID { get; set; }
    [JsonPropertyName("sessionGlobalID")] public string SessionGlobalID { get; set; } = "";
    [JsonPropertyName("originDeviceID")] public string OriginDeviceID { get; set; } = "";
    [JsonPropertyName("state")] public string State { get; set; } = "accepted";
    [JsonPropertyName("acceptedAt")] public string AcceptedAt { get; set; } = "";
    [JsonPropertyName("terminalAt")] public string? TerminalAt { get; set; }
    [JsonPropertyName("resultCode")] public string? ResultCode { get; set; }
}

internal sealed class LedgerOperation
{
    [JsonPropertyName("operationID")] public Guid OperationID { get; set; }
    [JsonPropertyName("kind")] public string Kind { get; set; } = "";
    [JsonPropertyName("state")] public string State { get; set; } = "accepted";
    [JsonPropertyName("requestSHA256")] public string RequestSHA256 { get; set; } = "";
    [JsonPropertyName("episodeID")] public Guid? EpisodeID { get; set; }
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
    [JsonPropertyName("updatedAt")] public string UpdatedAt { get; set; } = "";
    [JsonPropertyName("terminalAt")] public string? TerminalAt { get; set; }
    [JsonPropertyName("resultCode")] public string? ResultCode { get; set; }

    public bool IsTerminal => State is "completed" or "aborted" or "failed";
    public LedgerOperation Clone() => (LedgerOperation)MemberwiseClone();
}

internal sealed class LedgerMembership
{
    [JsonPropertyName("generationFloors")] public Dictionary<string, ulong> GenerationFloors { get; set; } = new();
    [JsonPropertyName("removedDeviceIDs")] public List<string> RemovedDeviceIDs { get; set; } = new();
}

internal sealed class LedgerDisplayRestoration
{
    [JsonPropertyName("sessionGlobalID")] public string SessionGlobalID { get; set; } = "";
    [JsonPropertyName("lastAuthorizedOwnerDeviceID")] public string? LastAuthorizedOwnerDeviceID { get; set; }
    [JsonPropertyName("takeGeneration")] public ulong TakeGeneration { get; set; }
    [JsonPropertyName("lastExecutionEpoch")] public ulong LastExecutionEpoch { get; set; }
    [JsonPropertyName("restorationEligible")] public bool RestorationEligible { get; set; }
    [JsonPropertyName("updatedAt")] public string UpdatedAt { get; set; } = "";
}

internal sealed class RecoveryLedgerStore
{
    private readonly LinuxPaths _paths;
    private readonly SerializedStateExecutor _executor;
    private RecoveryLedger? _ledger;

    public RecoveryLedgerStore(LinuxPaths paths, SerializedStateExecutor executor)
    {
        _paths = paths;
        _executor = executor;
        if (!File.Exists(_paths.LedgerFile)) return;
        try
        {
            _ledger = JsonSerializer.Deserialize<RecoveryLedger>(
                File.ReadAllBytes(_paths.LedgerFile), DurableJson.Options)
                ?? throw new InvalidDataException("empty");
            if (_ledger.LedgerVersion != 1 || string.IsNullOrWhiteSpace(_ledger.DeviceID))
                throw new InvalidDataException("unsupported version or identity");
        }
        catch (Exception error)
        {
            throw new RecoveryRequiredException(
                $"The recovery ledger cannot be read safely: {error.Message}");
        }
    }

    public RecoveryLedger? Existing => _ledger is null ? null : Clone(_ledger);

    public bool IsInitialized => _ledger is not null;

    public async Task InitializeAsync(string deviceID, CancellationToken cancellationToken = default)
    {
        await _executor.RunAsync(() =>
        {
            if (_ledger is not null)
            {
                if (!string.Equals(_ledger.DeviceID, deviceID, StringComparison.Ordinal))
                    throw new RecoveryRequiredException(
                        "The recovery ledger belongs to a different Converse identity.");
                return;
            }
            _ledger = new RecoveryLedger
            {
                DeviceID = deviceID,
                UpdatedAt = LinuxTime.Now(),
            };
            Save();
        }, cancellationToken);
    }

    public Task<RecoveryLedger> SnapshotAsync(CancellationToken cancellationToken = default) =>
        _executor.RunAsync(() => Clone(RequireLedger()), cancellationToken);

    public async Task UpdateAsync(Action<RecoveryLedger> update, CancellationToken cancellationToken = default)
    {
        await _executor.RunAsync(() =>
        {
            var ledger = RequireLedger();
            update(ledger);
            Save();
        }, cancellationToken);
    }

    public async Task<LedgerOperation> BeginOperationAsync(
        Guid operationID,
        string kind,
        string requestHash,
        Guid? episodeID,
        string initialState = "accepted",
        CancellationToken cancellationToken = default)
    {
        return await _executor.RunAsync(() =>
        {
            var ledger = RequireLedger();
            var existing = ledger.Operations.FirstOrDefault(operation => operation.OperationID == operationID);
            if (existing is not null)
            {
                if (existing.Kind != kind || existing.RequestSHA256 != requestHash)
                    throw new OperationConflictException(
                        "The operation ID was already used for a different request.");
                return existing.Clone();
            }
            var now = LinuxTime.Now();
            var operation = new LedgerOperation
            {
                OperationID = operationID,
                Kind = kind,
                State = initialState,
                RequestSHA256 = requestHash,
                EpisodeID = episodeID,
                CreatedAt = now,
                UpdatedAt = now,
            };
            ledger.Operations.Add(operation);
            Save();
            return operation.Clone();
        }, cancellationToken);
    }

    public async Task<LedgerOperation?> GetOperationAsync(
        Guid operationID, CancellationToken cancellationToken = default)
    {
        return await _executor.RunAsync(() =>
            RequireLedger().Operations.FirstOrDefault(operation => operation.OperationID == operationID)?.Clone(),
            cancellationToken);
    }

    public async Task TransitionOperationAsync(
        Guid operationID,
        string state,
        string? resultCode = null,
        Guid? episodeID = null,
        CancellationToken cancellationToken = default)
    {
        await _executor.RunAsync(() =>
        {
            var ledger = RequireLedger();
            var operation = ledger.Operations.FirstOrDefault(item => item.OperationID == operationID)
                ?? throw new InvalidOperationException("Unknown durable operation.");
            operation.State = state;
            operation.UpdatedAt = LinuxTime.Now();
            operation.ResultCode = resultCode;
            if (episodeID is not null) operation.EpisodeID = episodeID;
            operation.TerminalAt = operation.IsTerminal ? operation.UpdatedAt : null;
            Save();
        }, cancellationToken);
    }

    public async Task SetEpisodeAsync(UpdateEpisode? episode, CancellationToken cancellationToken = default)
    {
        await _executor.RunAsync(() =>
        {
            RequireLedger().UpdateEpisode = episode?.Clone();
            Save();
        }, cancellationToken);
    }

    public async Task RecordDisplayGrantAsync(
        string homeDeviceID, Guid sessionID, string ownerDeviceID, ulong epoch,
        CancellationToken cancellationToken = default)
    {
        await _executor.RunAsync(() =>
        {
            var ledger = RequireLedger();
            var globalID = $"{homeDeviceID}/{sessionID:D}";
            var record = ledger.DisplayRestorations.FirstOrDefault(
                item => item.SessionGlobalID == globalID);
            if (record is null)
            {
                record = new LedgerDisplayRestoration { SessionGlobalID = globalID };
                ledger.DisplayRestorations.Add(record);
            }
            if (record.LastAuthorizedOwnerDeviceID != ownerDeviceID ||
                record.LastExecutionEpoch != epoch)
                record.TakeGeneration = checked(record.TakeGeneration + 1);
            record.LastAuthorizedOwnerDeviceID = ownerDeviceID;
            record.LastExecutionEpoch = Math.Max(record.LastExecutionEpoch, epoch);
            record.RestorationEligible = true;
            record.UpdatedAt = LinuxTime.Now();
            Save();
        }, cancellationToken);
    }

    public async Task RecordDisplayReleaseAsync(
        string homeDeviceID, Guid sessionID, string ownerDeviceID, ulong epoch,
        CancellationToken cancellationToken = default)
    {
        await _executor.RunAsync(() =>
        {
            var ledger = RequireLedger();
            var globalID = $"{homeDeviceID}/{sessionID:D}";
            var record = ledger.DisplayRestorations.FirstOrDefault(
                item => item.SessionGlobalID == globalID);
            if (record is null || record.LastAuthorizedOwnerDeviceID != ownerDeviceID ||
                record.LastExecutionEpoch != epoch) return;
            record.RestorationEligible = false;
            record.UpdatedAt = LinuxTime.Now();
            Save();
        }, cancellationToken);
    }

    public async Task SyncAuthorityAsync(
        DeviceSyncCounterSnapshot counters,
        ulong nextMembershipGeneration,
        IEnumerable<TrustedDevice> trustRecords,
        IEnumerable<ConverseGroup> groups,
        IEnumerable<DeviceCommandRecord> commandRecords,
        CancellationToken cancellationToken = default)
    {
        await _executor.RunAsync(() =>
        {
            var ledger = RequireLedger();
            // Counters.Boot is the current boot; a subsequent process must
            // allocate at least the next value. Snapshot sequence/epoch are
            // already next-allocation values.
            ledger.CounterFloors.NextBoot = Math.Max(ledger.CounterFloors.NextBoot, counters.Boot + 1);
            ledger.CounterFloors.NextHomeSeq = Math.Max(
                ledger.CounterFloors.NextHomeSeq, counters.NextHomeSeq);
            ledger.CounterFloors.NextLeaseEpoch = Math.Max(
                ledger.CounterFloors.NextLeaseEpoch, counters.NextLeaseEpoch);
            ledger.CounterFloors.NextMembershipGeneration = Math.Max(
                ledger.CounterFloors.NextMembershipGeneration, nextMembershipGeneration);

            foreach (var record in trustRecords)
            {
                var generation = record.Generation ?? 0;
                ledger.Membership.GenerationFloors[record.DeviceID] = Math.Max(
                    ledger.Membership.GenerationFloors.GetValueOrDefault(record.DeviceID), generation);
                if (record.Removed == true && !ledger.Membership.RemovedDeviceIDs.Contains(record.DeviceID))
                    ledger.Membership.RemovedDeviceIDs.Add(record.DeviceID);
            }
            ledger.Membership.RemovedDeviceIDs.Sort(StringComparer.Ordinal);

            foreach (var group in groups.Where(group => group.Dissolved))
                if (!ledger.DissolvedGroupIDs.Contains(group.Id, StringComparer.OrdinalIgnoreCase))
                    ledger.DissolvedGroupIDs.Add(group.Id);
            ledger.DissolvedGroupIDs.Sort(StringComparer.OrdinalIgnoreCase);

            foreach (var command in commandRecords) MergeCommand(ledger, command);
            Save();
        }, cancellationToken);
    }

    private static void MergeCommand(RecoveryLedger ledger, DeviceCommandRecord command)
    {
        if (command.Id == Guid.Empty || string.IsNullOrWhiteSpace(command.SessionID) ||
            string.IsNullOrWhiteSpace(command.Origin)) return;
        var incoming = command.Outcome switch
        {
            "running" => "started",
            "accepted" => "accepted",
            "completed" => "completed",
            "failed" => "failed",
            "uncertain" => "uncertain",
            _ => "uncertain",
        };
        var updated = LinuxTime.Format(command.UpdatedAt == default
            ? DateTimeOffset.UtcNow
            : new DateTimeOffset(DateTime.SpecifyKind(command.UpdatedAt, DateTimeKind.Utc)));
        var existing = ledger.CommandReceipts.FirstOrDefault(receipt => receipt.CommandID == command.Id);
        if (existing is null)
        {
            ledger.CommandReceipts.Add(new LedgerCommandReceipt
            {
                CommandID = command.Id,
                SessionGlobalID = command.SessionID,
                OriginDeviceID = command.Origin,
                State = incoming,
                AcceptedAt = updated,
                TerminalAt = incoming is "completed" or "failed" ? updated : null,
                ResultCode = incoming is "completed" or "failed" ? incoming : null,
            });
            return;
        }

        var existingTerminal = existing.State is "completed" or "failed";
        var incomingTerminal = incoming is "completed" or "failed";
        if (existingTerminal && !incomingTerminal) return;
        if (existing.State == "uncertain" && incoming is "accepted" or "started") return;
        existing.State = incoming;
        existing.TerminalAt = incomingTerminal ? updated : existing.TerminalAt;
        existing.ResultCode = incomingTerminal ? incoming : existing.ResultCode;
    }

    private RecoveryLedger RequireLedger() => _ledger
        ?? throw new RecoveryRequiredException("The recovery ledger has not been initialized.");

    private void Save()
    {
        var ledger = RequireLedger();
        ledger.Sequence = checked(ledger.Sequence + 1);
        ledger.UpdatedAt = LinuxTime.Now();
        LinuxFileModes.Directory700(_paths.LedgerDirectory);
        DurableJson.Write(_paths.LedgerFile, ledger);
        LinuxFileModes.File600(_paths.LedgerFile);
    }

    private static RecoveryLedger Clone(RecoveryLedger ledger)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(ledger, DurableJson.Options);
        return JsonSerializer.Deserialize<RecoveryLedger>(bytes, DurableJson.Options)
            ?? throw new InvalidDataException("Could not clone the recovery ledger.");
    }
}
