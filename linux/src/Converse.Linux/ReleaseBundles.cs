using System.Formats.Tar;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace Converse.Linux;

internal sealed class AdminException(
    string code,
    string message,
    bool retryable = false,
    bool uncertain = false) : InvalidOperationException(message)
{
    public string Code { get; } = code;
    public bool Retryable { get; } = retryable;
    public bool Uncertain { get; } = uncertain;
}

internal static class ReleaseTrust
{
    // Production public keys are added by the signed release pipeline. Until
    // then staging fails closed instead of trusting SSH upload alone.
    public static IReadOnlyDictionary<string, byte[]> EmbeddedPublicKeys { get; } =
        new Dictionary<string, byte[]>();
}

internal sealed record VerifiedRelease(
    ReleaseManifest Manifest,
    string ReleaseDirectory,
    string ArtifactPath,
    string ArtifactSHA256);

internal sealed class ReleaseBundleVerifier
{
    private static readonly HashSet<string> AllowedFiles = new(StringComparer.Ordinal)
    {
        "converse", "manifest.json", "manifest.json.sig", "LICENSE", "VERSION.json",
    };

    private readonly LinuxPaths _paths;
    private readonly IReadOnlyDictionary<string, byte[]> _trustedKeys;
    private readonly string _expectedArchitecture;

    public ReleaseBundleVerifier(
        LinuxPaths paths,
        IReadOnlyDictionary<string, byte[]>? trustedKeys = null,
        string? expectedArchitecture = null)
    {
        _paths = paths;
        _trustedKeys = trustedKeys ?? ReleaseTrust.EmbeddedPublicKeys;
        foreach (var key in _trustedKeys.Values)
            if (key.Length != 32) throw new InvalidDataException("A trusted release key is invalid.");
        _expectedArchitecture = expectedArchitecture ??
            (System.Runtime.InteropServices.RuntimeInformation.OSArchitecture switch
            {
                System.Runtime.InteropServices.Architecture.X64 => "x64",
                System.Runtime.InteropServices.Architecture.Arm64 => "arm64",
                _ => "unknown",
            });
    }

    public VerifiedRelease VerifyAndInstall(
        string bundlePath, string expectedBundleSHA256, long expectedBundleSize)
    {
        var file = new FileInfo(bundlePath);
        if (!file.Exists || file.Length != expectedBundleSize)
            throw VerificationFailed("The uploaded release bundle size does not match.");
        if (!string.Equals(HashFile(bundlePath), expectedBundleSHA256, StringComparison.Ordinal))
            throw VerificationFailed("The uploaded release bundle hash does not match.");

        LinuxFileModes.Directory700(_paths.IncomingDirectory);
        LinuxFileModes.Directory700(_paths.ReleasesRoot);
        var tempDirectory = Path.Combine(_paths.IncomingDirectory, $".extract-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDirectory);
        try
        {
            Extract(bundlePath, tempDirectory);
            var manifestBytes = File.ReadAllBytes(Path.Combine(tempDirectory, "manifest.json"));
            if (manifestBytes.Length is 0 or > 1024 * 1024)
                throw VerificationFailed("The release manifest is missing or oversized.");
            var manifest = JsonSerializer.Deserialize<ReleaseManifest>(manifestBytes, DurableJson.Options)
                ?? throw VerificationFailed("The release manifest is invalid.");
            ValidateManifest(manifest);
            VerifySignature(manifest, manifestBytes, Path.Combine(tempDirectory, "manifest.json.sig"));

            var artifactPath = Path.Combine(tempDirectory, "converse");
            var artifact = new FileInfo(artifactPath);
            if (artifact.Length != manifest.Artifact.Size)
                throw VerificationFailed("The release executable size does not match its manifest.");
            var artifactHash = HashFile(artifactPath);
            if (!string.Equals(artifactHash, manifest.Artifact.Sha256, StringComparison.Ordinal))
                throw VerificationFailed("The release executable hash does not match its manifest.");
            LinuxFileModes.File700(artifactPath);

            var destination = _paths.ReleaseDirectory(manifest.ReleaseID);
            if (Directory.Exists(destination))
            {
                var existingArtifact = Path.Combine(destination, "converse");
                if (!File.Exists(existingArtifact) ||
                    !string.Equals(HashFile(existingArtifact), artifactHash, StringComparison.Ordinal))
                    throw VerificationFailed("A different release already uses this release ID.");
                Directory.Delete(tempDirectory, recursive: true);
            }
            else
            {
                Directory.Move(tempDirectory, destination);
                tempDirectory = "";
            }
            LinuxFileModes.Directory700(destination);
            LinuxFileModes.File700(Path.Combine(destination, "converse"));
            return new VerifiedRelease(
                manifest, destination, Path.Combine(destination, "converse"), artifactHash);
        }
        finally
        {
            if (!string.IsNullOrEmpty(tempDirectory) && Directory.Exists(tempDirectory))
            {
                try { Directory.Delete(tempDirectory, recursive: true); }
                catch { /* A failed staging directory is private and inert. */ }
            }
        }
    }

    private void ValidateManifest(ReleaseManifest manifest)
    {
        if (manifest.ManifestVersion != 1 || manifest.Product != "Converse" ||
            string.IsNullOrWhiteSpace(manifest.ReleaseID) ||
            manifest.ReleaseID.Contains('/') || manifest.ReleaseID.Contains('\\') ||
            manifest.SourceCommit.Length != 40 || !manifest.SourceCommit.All(Uri.IsHexDigit) ||
            manifest.Protocols.DeviceProtocolVersion != ProductInfo.DeviceProtocolVersion ||
            manifest.Protocols.AdminApiVersion != ProductInfo.AdminApiVersion ||
            !manifest.Protocols.StateSchemaCompatibility.CanRead(ProductInfo.StateSchemaVersion) ||
            manifest.Protocols.RecoveryLedgerVersion != ProductInfo.RecoveryLedgerVersion ||
            manifest.Artifact.FileName != "converse" ||
            manifest.Artifact.OperatingSystem != "linux" ||
            manifest.Artifact.Architecture != _expectedArchitecture ||
            manifest.Artifact.Size is < 1 or > 536870912 ||
            manifest.Artifact.Sha256.Length != 64 ||
            !manifest.Artifact.Sha256.All(character => Uri.IsHexDigit(character) && !char.IsUpper(character)))
            throw VerificationFailed("The signed release manifest is not valid for this Linux home.");
    }

    private void VerifySignature(ReleaseManifest manifest, byte[] manifestBytes, string signaturePath)
    {
        if (!_trustedKeys.TryGetValue(manifest.SigningKeyID, out var publicKey))
            throw VerificationFailed("The release signing key is not trusted by this build.");
        byte[] signature;
        try
        {
            var text = File.ReadAllText(signaturePath).Trim();
            if (text.Length > 4096) throw new FormatException("oversized signature");
            signature = Convert.FromBase64String(text);
        }
        catch { throw VerificationFailed("The detached release signature is invalid."); }
        if (signature.Length != 64)
            throw VerificationFailed("The detached release signature is invalid.");

        var signer = new Ed25519Signer();
        signer.Init(false, new Ed25519PublicKeyParameters(publicKey, 0));
        signer.BlockUpdate(manifestBytes, 0, manifestBytes.Length);
        if (!signer.VerifySignature(signature))
            throw VerificationFailed("The detached release signature does not verify.");
    }

    private static void Extract(string bundlePath, string destination)
    {
        using var file = File.OpenRead(bundlePath);
        using var gzip = new GZipStream(file, CompressionMode.Decompress);
        using var tar = new TarReader(gzip);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        long total = 0;
        while (tar.GetNextEntry(copyData: false) is { } entry)
        {
            var name = entry.Name.Trim();
            if (name.StartsWith("./", StringComparison.Ordinal)) name = name[2..];
            if (!AllowedFiles.Contains(name) || !seen.Add(name) ||
                entry.EntryType is not (TarEntryType.RegularFile or TarEntryType.V7RegularFile) ||
                entry.Length < 0)
                throw VerificationFailed("The release bundle contains an unsafe or unexpected entry.");
            var limit = name switch
            {
                "manifest.json" => 1024L * 1024,
                "manifest.json.sig" => 4096L,
                "VERSION.json" => 65536L,
                "LICENSE" => 1024L * 1024,
                _ => 536870912L,
            };
            if (entry.Length > limit || total > 536870912L - entry.Length)
                throw VerificationFailed("The release bundle exceeds a size limit.");
            total += entry.Length;
            var output = Path.Combine(destination, name);
            using var target = new FileStream(
                output, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            entry.DataStream?.CopyTo(target);
            target.Flush(flushToDisk: true);
            if (target.Length != entry.Length)
                throw VerificationFailed("A release bundle entry was truncated.");
        }
        if (!seen.SetEquals(AllowedFiles))
            throw VerificationFailed("The release bundle is missing a required file.");
    }

    internal static string HashFile(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static AdminException VerificationFailed(string message) =>
        new("stage_verification_failed", message);
}
