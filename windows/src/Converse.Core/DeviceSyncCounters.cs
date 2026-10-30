using System.Text.Json;
using System.Text.Json.Serialization;

namespace Converse.Core;

// HomeSeq is device-wide, not connection-local: Mac viewers retain their
// last accepted value across reconnects. Reserve ranges before using them
// so a crash/restart never reuses a published sequence, without writing on
// every streaming delta. Lease epochs and the process boot are durable too.
internal sealed class DeviceSyncCounters
{
    private const ulong RangeSize = 4096;
    private const ulong Maximum = (1UL << 53) - 1;
    // Older Windows builds had no counter file. Start above their practical
    // process-local range so already-running Mac viewers accept the upgrade.
    private const ulong MigrationFloor = 1UL << 48;
    private readonly string _file;
    private readonly object _gate = new();
    private State _state;
    private ulong _next;

    private sealed record State
    {
        [JsonRequired] public ulong ReservedThrough { get; init; } = MigrationFloor;
        [JsonRequired] public ulong Boot { get; init; } = 1;
        [JsonRequired] public Dictionary<Guid, ulong> Epochs { get; init; } = new();
    }

    public DeviceSyncCounters(string folder)
    {
        Directory.CreateDirectory(folder);
        _file = Path.Combine(folder, "device-sync-counters.json");
        // Corrupt state must fail closed, never silently reset generations.
        _state = File.Exists(_file)
            ? JsonSerializer.Deserialize<State>(File.ReadAllBytes(_file)) ?? throw new InvalidDataException("Invalid sync counters.")
            : new State();
        if (_state.ReservedThrough > Maximum - RangeSize || _state.Boot >= Maximum
            || _state.Epochs is null || _state.Epochs.Values.Any(epoch => epoch >= Maximum))
            throw new InvalidDataException("Invalid or exhausted sync counters.");
        _next = _state.ReservedThrough;
        var started = _state with { Boot = _state.Boot + 1, ReservedThrough = _next + RangeSize };
        AtomicJson.Write(_file, started);
        _state = started;
    }

    public ulong Boot => _state.Boot;
    public Dictionary<Guid, ulong> Epochs => new(_state.Epochs);

    public ulong NextSequence()
    {
        lock (_gate)
        {
            if (_next == _state.ReservedThrough)
            {
                if (_next > Maximum - RangeSize) throw new InvalidOperationException("Sync sequence exhausted.");
                var reserved = _state with { ReservedThrough = _next + RangeSize };
                AtomicJson.Write(_file, reserved);
                _state = reserved;
            }
            return ++_next;
        }
    }

    public bool SaveEpochs(Dictionary<Guid, ulong> epochs)
    {
        lock (_gate)
        {
            if (epochs.Values.Any(epoch => epoch >= Maximum)
                || _state.Epochs.Any(pair => epochs.GetValueOrDefault(pair.Key) < pair.Value)) return false;
            var candidate = _state with { Epochs = new(epochs) };
            try { AtomicJson.Write(_file, candidate); }
            catch { return false; }
            _state = candidate;
            return true;
        }
    }
}
