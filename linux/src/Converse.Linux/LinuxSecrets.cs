using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Converse.Core;

namespace Converse.Linux;

internal sealed class AppliedSecretOperation
{
    [JsonPropertyName("operationID")] public Guid OperationID { get; set; }
    [JsonPropertyName("commitment")] public string Commitment { get; set; } = "";
    [JsonPropertyName("metadata")] public SecretMetadata Metadata { get; set; } = new();
}

internal sealed class LinuxSecretStore
{
    private readonly LinuxPaths _paths;
    private readonly SerializedStateExecutor _executor;

    public LinuxSecretStore(LinuxPaths paths, SerializedStateExecutor executor)
    {
        _paths = paths;
        _executor = executor;
    }

    public async Task<List<SecretMetadata>> ListAsync(CancellationToken cancellationToken = default)
    {
        return await _executor.RunAsync(() =>
        {
            LinuxFileModes.Directory700(_paths.SecretsDirectory);
            var byID = ReadMetadata().ToDictionary(item => item.SecretID, StringComparer.Ordinal);
            if (!byID.ContainsKey("agent.meta.api-key"))
            {
                byID["agent.meta.api-key"] = new SecretMetadata
                {
                    SecretID = "agent.meta.api-key",
                    Kind = "provider_api_key",
                    Configured = false,
                    UpdatedAt = null,
                };
            }
            foreach (var file in Directory.EnumerateFiles(_paths.SecretsDirectory, "*.secret"))
            {
                var id = Path.GetFileNameWithoutExtension(file);
                if (!byID.TryGetValue(id, out var metadata))
                {
                    metadata = new SecretMetadata { SecretID = id, Kind = "other" };
                    byID[id] = metadata;
                }
                metadata.Configured = true;
                if (metadata.StoredVersion == 0) metadata.StoredVersion = 1;
                metadata.EffectiveVersion = metadata.StoredVersion;
                metadata.PendingRestart = false;
                metadata.Backend = "linux-file-0600";
                metadata.UpdatedAt ??= LinuxTime.Format(File.GetLastWriteTimeUtc(file));
            }
            foreach (var metadata in byID.Values)
                if (!File.Exists(ValuePath(metadata.SecretID))) metadata.Configured = false;
            return byID.Values.OrderBy(item => item.SecretID, StringComparer.Ordinal).ToList();
        }, cancellationToken);
    }

    public async Task<SecretMetadata> SetAsync(
        string secretID, string kind, string value, CancellationToken cancellationToken = default,
        Guid? operationID = null, string? commitment = null)
    {
        return await _executor.RunAsync(() =>
        {
            LinuxFileModes.Directory700(_paths.SecretsDirectory);
            var path = ValuePath(secretID);
            var temp = path + $".{Guid.NewGuid():N}.tmp";
            try
            {
                using (var stream = new FileStream(
                    temp, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                    bufferSize: 4096, FileOptions.WriteThrough))
                {
                    var bytes = Encoding.UTF8.GetBytes(value);
                    stream.Write(bytes);
                    stream.Flush(flushToDisk: true);
                }
                File.Move(temp, path, overwrite: true);
                LinuxFileModes.File600(path);
                DurableJson.TrySyncDirectory(_paths.SecretsDirectory);
            }
            finally
            {
                try { if (File.Exists(temp)) File.Delete(temp); } catch { /* best effort */ }
            }

            var metadata = ReadMetadata();
            var item = metadata.FirstOrDefault(entry => entry.SecretID == secretID);
            if (item is null)
            {
                item = new SecretMetadata { SecretID = secretID };
                metadata.Add(item);
            }
            item.Kind = kind;
            item.Backend = "linux-file-0600";
            item.Configured = true;
            item.StoredVersion = checked(Math.Max(1, item.StoredVersion + 1));
            item.EffectiveVersion = item.StoredVersion;
            item.PendingRestart = false;
            item.UpdatedAt = LinuxTime.Now();
            WriteMetadata(metadata);
            if (operationID is { } appliedID && commitment is not null)
                WriteApplied(appliedID, commitment, item);
            return Clone(item);
        }, cancellationToken);
    }

    public async Task<SecretMetadata?> DeleteAsync(
        string secretID, CancellationToken cancellationToken = default,
        Guid? operationID = null, string? commitment = null)
    {
        return await _executor.RunAsync(() =>
        {
            LinuxFileModes.Directory700(_paths.SecretsDirectory);
            var metadata = ReadMetadata();
            var item = metadata.FirstOrDefault(entry => entry.SecretID == secretID);
            var path = ValuePath(secretID);
            if (!File.Exists(path) && item?.Configured != true) return null;
            if (File.Exists(path)) File.Delete(path);
            DurableJson.TrySyncDirectory(_paths.SecretsDirectory);
            item ??= new SecretMetadata { SecretID = secretID };
            if (!metadata.Contains(item)) metadata.Add(item);
            item.Backend = "linux-file-0600";
            item.Configured = false;
            item.StoredVersion = checked(Math.Max(1, item.StoredVersion + 1));
            item.EffectiveVersion = item.StoredVersion;
            item.PendingRestart = false;
            item.UpdatedAt = LinuxTime.Now();
            WriteMetadata(metadata);
            if (operationID is { } appliedID && commitment is not null)
                WriteApplied(appliedID, commitment, item);
            return Clone(item);
        }, cancellationToken);
    }

    public async Task<AppliedSecretOperation?> AppliedForOperationAsync(
        Guid operationID, CancellationToken cancellationToken = default) =>
        await _executor.RunAsync(() =>
        {
            var applied = ReadApplied().FirstOrDefault(
                entry => entry.OperationID == operationID);
            return applied is null ? null : new AppliedSecretOperation
            {
                OperationID = applied.OperationID,
                Commitment = applied.Commitment,
                Metadata = Clone(applied.Metadata),
            };
        }, cancellationToken);

    public async Task<string> CommitmentAsync(
        string action, string secretID, string? kind, ReadOnlyMemory<byte> value,
        CancellationToken cancellationToken = default)
    {
        return await _executor.RunAsync(() =>
        {
            LinuxFileModes.Directory700(_paths.SecretsDirectory);
            var keyPath = Path.Combine(_paths.SecretsDirectory, ".receipt-key");
            byte[] key;
            if (File.Exists(keyPath))
            {
                key = File.ReadAllBytes(keyPath);
                if (key.Length != 32) throw new InvalidDataException("The secret receipt key is invalid.");
            }
            else
            {
                key = RandomNumberGenerator.GetBytes(32);
                var temporary = keyPath + $".{Guid.NewGuid():N}.tmp";
                File.WriteAllBytes(temporary, key);
                LinuxFileModes.File600(temporary);
                File.Move(temporary, keyPath, overwrite: false);
                LinuxFileModes.File600(keyPath);
            }
            using var hmac = new HMACSHA256(key);
            var prefix = Encoding.UTF8.GetBytes(
                $"{action}\0{secretID}\0{kind ?? ""}\0{value.Length}\0");
            hmac.TransformBlock(prefix, 0, prefix.Length, null, 0);
            var bytes = value.ToArray();
            hmac.TransformFinalBlock(bytes, 0, bytes.Length);
            return Convert.ToHexString(hmac.Hash!).ToLowerInvariant();
        }, cancellationToken);
    }

    public async Task<SecretMetadata?> GetAsync(
        string secretID, CancellationToken cancellationToken = default) =>
        (await ListAsync(cancellationToken))
            .FirstOrDefault(item => item.SecretID == secretID);

    public string? Read(string name)
    {
        var id = name == "meta" ? "agent.meta.api-key" : name;
        try
        {
            var path = ValuePath(id);
            return File.Exists(path) ? File.ReadAllText(path, Encoding.UTF8) : null;
        }
        catch { return null; }
    }

    private string AppliedFile =>
        Path.Combine(_paths.SecretsDirectory, "applied-operations.json");

    private List<AppliedSecretOperation> ReadApplied()
    {
        if (!File.Exists(AppliedFile)) return new List<AppliedSecretOperation>();
        return JsonSerializer.Deserialize<List<AppliedSecretOperation>>(
            File.ReadAllBytes(AppliedFile), DurableJson.Options)
            ?? new List<AppliedSecretOperation>();
    }

    private void WriteApplied(Guid operationID, string commitment, SecretMetadata metadata)
    {
        var applied = ReadApplied();
        applied.RemoveAll(entry => entry.OperationID == operationID);
        applied.Add(new AppliedSecretOperation
        {
            OperationID = operationID,
            Commitment = commitment,
            Metadata = Clone(metadata),
        });
        DurableJson.Write(AppliedFile, applied);
        LinuxFileModes.File600(AppliedFile);
    }

    private string ValuePath(string secretID) =>
        Path.Combine(_paths.SecretsDirectory, secretID + ".secret");

    private List<SecretMetadata> ReadMetadata()
    {
        if (!File.Exists(_paths.SecretsMetadataFile)) return new List<SecretMetadata>();
        return JsonSerializer.Deserialize<List<SecretMetadata>>(
            File.ReadAllBytes(_paths.SecretsMetadataFile), DurableJson.Options) ?? new List<SecretMetadata>();
    }

    private void WriteMetadata(List<SecretMetadata> metadata)
    {
        DurableJson.Write(_paths.SecretsMetadataFile,
            metadata.OrderBy(item => item.SecretID, StringComparer.Ordinal).ToList());
        LinuxFileModes.File600(_paths.SecretsMetadataFile);
    }

    private static SecretMetadata Clone(SecretMetadata item) => new()
    {
        SecretID = item.SecretID,
        Kind = item.Kind,
        Backend = item.Backend,
        Configured = item.Configured,
        StoredVersion = item.StoredVersion,
        EffectiveVersion = item.EffectiveVersion,
        PendingRestart = item.PendingRestart,
        UpdatedAt = item.UpdatedAt,
    };
}
