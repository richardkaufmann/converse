using System.Text;
using System.Text.Json;
using Converse.Core;

namespace Converse.Linux;

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
                metadata.UpdatedAt ??= LinuxTime.Format(File.GetLastWriteTimeUtc(file));
            }
            foreach (var metadata in byID.Values)
                if (!File.Exists(ValuePath(metadata.SecretID))) metadata.Configured = false;
            return byID.Values.OrderBy(item => item.SecretID, StringComparer.Ordinal).ToList();
        }, cancellationToken);
    }

    public async Task<SecretMetadata> SetAsync(
        string secretID, string kind, string value, CancellationToken cancellationToken = default)
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
            item.Configured = true;
            item.UpdatedAt = LinuxTime.Now();
            WriteMetadata(metadata);
            return Clone(item);
        }, cancellationToken);
    }

    public async Task<SecretMetadata?> DeleteAsync(
        string secretID, CancellationToken cancellationToken = default)
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
            item.Configured = false;
            item.UpdatedAt = LinuxTime.Now();
            WriteMetadata(metadata);
            return Clone(item);
        }, cancellationToken);
    }

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
        Configured = item.Configured,
        UpdatedAt = item.UpdatedAt,
    };
}
