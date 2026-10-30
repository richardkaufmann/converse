namespace Converse.Core;

// One-at-a-time execution for durable state transitions. This is deliberately
// a small seam: callers decide which operations must be serialized, while
// existing fine-grained store locks keep protecting their own records.
public sealed class SerializedStateExecutor : IDisposable
{
    private readonly SemaphoreSlim _gate = new(1, 1);

    public async Task RunAsync(Func<Task> operation, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(operation);
        await _gate.WaitAsync(cancellationToken);
        try { await operation(); }
        finally { _gate.Release(); }
    }

    public async Task<T> RunAsync<T>(Func<Task<T>> operation, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(operation);
        await _gate.WaitAsync(cancellationToken);
        try { return await operation(); }
        finally { _gate.Release(); }
    }

    public Task RunAsync(Action operation, CancellationToken cancellationToken = default) =>
        RunAsync(() => { operation(); return Task.CompletedTask; }, cancellationToken);

    public Task<T> RunAsync<T>(Func<T> operation, CancellationToken cancellationToken = default) =>
        RunAsync(() => Task.FromResult(operation()), cancellationToken);

    public void Dispose() => _gate.Dispose();
}
