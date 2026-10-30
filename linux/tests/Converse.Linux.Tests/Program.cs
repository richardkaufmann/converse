using System.Formats.Tar;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Converse.Core;
using Converse.Linux;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;

var checks = new Checks();
var cleanup = new List<string>();

string TempHome()
{
    var path = Path.Combine("/tmp", "clx-" + Guid.NewGuid().ToString("N")[..10]);
    Directory.CreateDirectory(path);
    cleanup.Add(path);
    return path;
}

string CurrentArchitecture() => RuntimeInformation.OSArchitecture switch
{
    Architecture.X64 => "x64",
    Architecture.Arm64 => "arm64",
    _ => "unknown",
};

(AsymmetricCipherKeyPair Pair, byte[] PublicKey) MakeReleaseKey()
{
    var generator = new Ed25519KeyPairGenerator();
    generator.Init(new KeyGenerationParameters(new SecureRandom(), 255));
    var pair = generator.GenerateKeyPair();
    var publicKey = ((Ed25519PublicKeyParameters)pair.Public).GetEncoded();
    return (pair, publicKey);
}

CreatedBundle CreateBundle(
    string directory, string releaseID, AsymmetricCipherKeyPair pair, bool extraEntry = false)
{
    Directory.CreateDirectory(directory);
    var artifact = Encoding.UTF8.GetBytes("fake converse executable for " + releaseID);
    var manifest = new ReleaseManifest
    {
        ManifestVersion = 1,
        ReleaseID = releaseID,
        Product = "Converse",
        ProductVersion = "1.0.0",
        Build = 2,
        SourceCommit = new string('a', 40),
        CreatedAt = "2026-10-30T16:00:00Z",
        SigningKeyID = "test-release-key",
        Protocols = new ReleaseProtocols
        {
            DeviceProtocolVersion = 1,
            AdminApiVersion = 1,
            StateSchemaVersion = 1,
            RecoveryLedgerVersion = 1,
        },
        Artifact = new ReleaseArtifact
        {
            FileName = "converse",
            OperatingSystem = "linux",
            Architecture = CurrentArchitecture(),
            Size = artifact.Length,
            Sha256 = Convert.ToHexString(SHA256.HashData(artifact)).ToLowerInvariant(),
        },
    };
    var manifestBytes = JsonSerializer.SerializeToUtf8Bytes(manifest, DurableJson.Options);
    var signer = new Ed25519Signer();
    signer.Init(true, pair.Private);
    signer.BlockUpdate(manifestBytes, 0, manifestBytes.Length);
    var signature = Convert.ToBase64String(signer.GenerateSignature());

    var bundlePath = Path.Combine(directory, releaseID + ".tar.gz");
    using (var file = File.Create(bundlePath))
    using (var gzip = new GZipStream(file, CompressionLevel.Optimal, leaveOpen: false))
    using (var tar = new TarWriter(gzip, TarEntryFormat.Pax, leaveOpen: false))
    {
        void Add(string name, byte[] bytes)
        {
            tar.WriteEntry(new PaxTarEntry(TarEntryType.RegularFile, name)
            {
                DataStream = new MemoryStream(bytes),
            });
        }
        Add("converse", artifact);
        Add("manifest.json", manifestBytes);
        Add("manifest.json.sig", Encoding.UTF8.GetBytes(signature));
        Add("LICENSE", Encoding.UTF8.GetBytes("Apache-2.0"));
        Add("VERSION.json", Encoding.UTF8.GetBytes("{\"version\":\"1.0.0\",\"build\":2}"));
        if (extraEntry) Add("extra.txt", Encoding.UTF8.GetBytes("not allowed"));
    }
    var info = new FileInfo(bundlePath);
    return new CreatedBundle(
        bundlePath,
        Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(bundlePath))).ToLowerInvariant(),
        info.Length,
        manifest);
}

void InstallFakeRelease(LinuxPaths paths, string releaseID)
{
    var executable = paths.ReleaseExecutable(releaseID);
    Directory.CreateDirectory(Path.GetDirectoryName(executable)!);
    File.WriteAllText(executable, "fake release " + releaseID);
    if (!OperatingSystem.IsWindows())
    {
        File.SetUnixFileMode(executable,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }
}

void LinkRelease(LinuxPaths paths, string releaseID)
{
    Directory.CreateDirectory(paths.BinDirectory);
    if (File.Exists(paths.BinLink)) File.Delete(paths.BinLink);
    File.CreateSymbolicLink(paths.BinLink, paths.ReleaseExecutable(releaseID));
}

async Task<(int ExitCode, string Stdout)> RunAdminRequestProcessAsync(
    LinuxPaths paths, string line)
{
    var processPath = Environment.ProcessPath ?? "";
    var candidates = new[]
    {
        string.Equals(
            Path.GetFileNameWithoutExtension(processPath), "dotnet", StringComparison.OrdinalIgnoreCase)
            ? processPath : null,
        Environment.GetEnvironmentVariable("DOTNET_ROOT") is { } root
            ? Path.Combine(root, "dotnet") : null,
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".dotnet", "dotnet"),
        "dotnet",
    };
    var dotnet = candidates.FirstOrDefault(
        candidate => candidate is not null && (candidate == "dotnet" || File.Exists(candidate))) ?? "dotnet";
    var start = new System.Diagnostics.ProcessStartInfo
    {
        FileName = dotnet,
        RedirectStandardInput = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        UseShellExecute = false,
        CreateNoWindow = true,
    };
    start.ArgumentList.Add(Path.Combine(AppContext.BaseDirectory, "Converse.Linux.dll"));
    start.ArgumentList.Add("admin-request");
    start.Environment["CONVERSE_LINUX_HOME"] = paths.Home;
    using var process = System.Diagnostics.Process.Start(start)
        ?? throw new InvalidOperationException("Could not start admin-request.");
    await process.StandardInput.WriteLineAsync(line);
    process.StandardInput.Close();
    var stdout = await process.StandardOutput.ReadToEndAsync();
    await process.StandardError.ReadToEndAsync();
    await process.WaitForExitAsync();
    return (process.ExitCode, stdout.Trim());
}

try
{
    // Serialized executor: overlapping callers never enter together.
    {
        using var executor = new SerializedStateExecutor();
        var active = 0;
        var maximum = 0;
        async Task Work()
        {
            maximum = Math.Max(maximum, Interlocked.Increment(ref active));
            await Task.Delay(10);
            Interlocked.Decrement(ref active);
        }
        await Task.WhenAll(Enumerable.Range(0, 24).Select(_ => executor.RunAsync(Work)));
        checks.That(maximum == 1, "SerializedStateExecutor admits one state transition at a time");
    }

    // Recovery ledger: operation intent is durable and duplicate-safe.
    {
        var paths = new LinuxPaths(TempHome());
        paths.EnsurePrivateDirectories();
        using var executor = new SerializedStateExecutor();
        var ledger = new RecoveryLedgerStore(paths, executor);
        var deviceID = new string('a', 64);
        await ledger.InitializeAsync(deviceID);
        var operationID = Guid.NewGuid();
        var first = await ledger.BeginOperationAsync(
            operationID, "service.restart", "hash-123", null, "running");
        var repeated = await ledger.BeginOperationAsync(
            operationID, "service.restart", "hash-123", null, "running");
        checks.That(first.OperationID == repeated.OperationID && repeated.State == "running",
            "Recovery ledger returns an existing operation for the same ID and payload");
        var conflict = false;
        try
        {
            await ledger.BeginOperationAsync(
                operationID, "service.restart", "different-hash", null, "running");
        }
        catch (OperationConflictException) { conflict = true; }
        checks.That(conflict, "Recovery ledger rejects an operation ID reused with another payload");

        await ledger.UpdateAsync(item => item.CommandReceipts.Add(new LedgerCommandReceipt
        {
            CommandID = Guid.NewGuid(),
            SessionGlobalID = deviceID + "/" + Guid.NewGuid(),
            OriginDeviceID = new string('b', 64),
            State = "uncertain",
            AcceptedAt = "2026-10-30T16:00:00Z",
        }));
        var reloaded = new RecoveryLedgerStore(paths, executor);
        var snapshot = await reloaded.SnapshotAsync();
        checks.That(snapshot.Sequence >= 3 &&
                    snapshot.CommandReceipts.Any(receipt => receipt.State == "uncertain") &&
                    snapshot.Operations.Any(operation => operation.OperationID == operationID),
            "Recovery ledger reload preserves sequence, operations, and uncertain receipts");
    }

    // Core floors: a restored process allocates above the ledger, never below.
    {
        var root = TempHome();
        var sessionID = Guid.NewGuid();
        var acceptedID = Guid.NewGuid();
        var floors = new DeviceRecoveryFloors
        {
            NextBoot = 123,
            NextHomeSeq = 999999,
            NextLeaseEpoch = (1UL << 48) + 77,
            NextMembershipGeneration = 50,
            SessionEpochFloors = new Dictionary<Guid, ulong> { [sessionID] = 12345 },
            CommandReceipts =
            [
                new DeviceCommandRecord
                {
                    Id = acceptedID,
                    Origin = new string('b', 64),
                    Outcome = "accepted",
                    SessionID = new string('a', 64) + "/" + sessionID,
                    UpdatedAt = DateTime.UtcNow,
                },
            ],
        };
        using var service = new DeviceSyncService(
            root, new SessionStore(root, new FakeRunner()), "FloorHome", floors);
        var snapshot = service.SyncCounterSnapshot();
        checks.That(snapshot.Boot >= 123 && snapshot.NextHomeSeq >= 999999 &&
                    snapshot.NextLeaseEpoch >= (1UL << 48) + 77 &&
                    snapshot.Epochs[sessionID] == 12345,
            "DeviceSyncCounters apply Boot, HomeSeq, and lease-epoch floors");
        checks.That(service.CommandReceipts.Any(receipt =>
                receipt.Id == acceptedID && receipt.Outcome == "uncertain"),
            "Seeded accepted command receipts recover as uncertain, not replayable");

        var privateKey = new byte[32];
        RandomNumberGenerator.Fill(privateKey);
        var publicKey = X25519.PublicKeyFromPrivate(privateKey);
        var peerID = DeviceBlob.DeviceIdForPublicKey(publicKey);
        service.Trust.Pin(
            new TrustedDevice(peerID, "Peer", publicKey, null, null), peerID, true);
        checks.That((service.Trust.Records.Single(device => device.DeviceID == peerID).Generation ?? 0) >= 50,
            "Membership generation floor prevents generation reuse after restore");
        service.SetAcceptingWork(false);
        checks.That(!service.AcceptingWork, "Core work-admission seam closes for drain");
    }

    // Signed release bundles: exact-byte manifest signature plus artifact hash.
    {
        var home = TempHome();
        var paths = new LinuxPaths(home);
        paths.EnsurePrivateDirectories();
        var (pair, publicKey) = MakeReleaseKey();
        var verifier = new ReleaseBundleVerifier(
            paths, new Dictionary<string, byte[]> { ["test-release-key"] = publicKey });
        var bundle = CreateBundle(Path.Combine(home, "bundles"), "1.0.0-2-linux-test", pair);
        var verified = verifier.VerifyAndInstall(bundle.Path, bundle.Sha256, bundle.Size);
        checks.That(File.Exists(verified.ArtifactPath) &&
                    verified.ArtifactSHA256 == bundle.Manifest.Artifact.Sha256,
            "Signed release bundle verifies and installs by artifact hash");

        var extra = CreateBundle(
            Path.Combine(home, "bundles-extra"), "1.0.0-3-linux-test", pair, extraEntry: true);
        var rejected = false;
        try { verifier.VerifyAndInstall(extra.Path, extra.Sha256, extra.Size); }
        catch (AdminException error) { rejected = error.Code == "stage_verification_failed"; }
        checks.That(rejected, "Release bundle rejects unexpected entries before staging");
    }

    // Update lifecycle: drain timeout, probation, rollback, then health commit.
    {
        var home = TempHome();
        var paths = new LinuxPaths(home);
        paths.EnsurePrivateDirectories();
        using var executor = new SerializedStateExecutor();
        var ledger = new RecoveryLedgerStore(paths, executor);
        await ledger.InitializeAsync(new string('a', 64));
        var (pair, publicKey) = MakeReleaseKey();
        var verifier = new ReleaseBundleVerifier(
            paths, new Dictionary<string, byte[]> { ["test-release-key"] = publicKey });
        var runtime = new FakeUpdateRuntime();
        InstallFakeRelease(paths, "1.0.0-1-linux-test");
        LinkRelease(paths, "1.0.0-1-linux-test");
        var manager = new LinuxUpdateManager(
            paths, ledger, verifier, runtime, "1.0.0-1-linux-test", "manual-test");
        checks.That(await manager.ReconcileStartupAsync() == StartupAdmission.Open,
            "Clean update state starts with admission open");

        var bundle = CreateBundle(Path.Combine(home, "bundles"), "1.0.0-2-linux-test", pair);
        async Task StageBundleAsync()
        {
            var begin = await manager.StageBeginAsync(
                bundle.Manifest.ReleaseID, bundle.Sha256, bundle.Size);
            File.Copy(bundle.Path, begin.UploadPath, overwrite: true);
            var verified = await manager.StageVerifyAsync(begin.UploadID);
            checks.That(verified.Staged && verified.ReleaseID == bundle.Manifest.ReleaseID,
                "Update staging verifies the uploaded signed bundle");
        }
        await StageBundleAsync();

        runtime.ActiveTurnCount = 1;
        var drainOperationID = Guid.NewGuid();
        var drainOperation = await manager.ActivateAsync(
            drainOperationID, "activate-drain", bundle.Manifest.ReleaseID, 0);
        if (manager.ActivationTask is not null) await manager.ActivationTask;
        var afterDrain = await ledger.SnapshotAsync();
        checks.That(drainOperation.State == "draining_old_release" &&
                    afterDrain.UpdateEpisode?.Phase == "aborted" &&
                    afterDrain.Operations.Single(operation => operation.OperationID == drainOperationID).State == "aborted" &&
                    paths.LinkedReleaseID() == "1.0.0-1-linux-test" && runtime.Accepting,
            "Drain timeout aborts on the old release without killing work");

        runtime.ActiveTurnCount = 0;
        var activationID = Guid.NewGuid();
        await manager.ActivateAsync(
            activationID, "activate-success", bundle.Manifest.ReleaseID, 5);
        if (manager.ActivationTask is not null) await manager.ActivationTask;
        var probation = await ledger.SnapshotAsync();
        checks.That(probation.UpdateEpisode?.Phase == "probation_new_release" &&
                    probation.UpdateEpisode.ExplicitResolutionRequired &&
                    paths.LinkedReleaseID() == bundle.Manifest.ReleaseID &&
                    !runtime.Accepting && runtime.Restarts.Count == 1,
            "Successful drain switches releases into explicit probation");
        checks.That(await manager.ReconcileStartupAsync() == StartupAdmission.Probation,
            "Restart during probation remains admission-closed");

        var rollbackID = Guid.NewGuid();
        await manager.RollbackAsync(
            rollbackID, "rollback", probation.UpdateEpisode!.EpisodeID, "test rollback");
        checks.That(paths.LinkedReleaseID() == "1.0.0-1-linux-test" &&
                    (await ledger.SnapshotAsync()).UpdateEpisode?.Phase == "rolled_back",
            "Probation rollback restores the previous release pointer");
        checks.That(await manager.ReconcileStartupAsync() == StartupAdmission.Open &&
                    (await ledger.GetOperationAsync(rollbackID))?.State == "completed",
            "Restart after rollback completes its durable operation and opens admission");

        await StageBundleAsync();
        var secondActivationID = Guid.NewGuid();
        await manager.ActivateAsync(
            secondActivationID, "activate-again", bundle.Manifest.ReleaseID, 5);
        if (manager.ActivationTask is not null) await manager.ActivationTask;
        var secondProbation = await ledger.SnapshotAsync();
        var healthID = Guid.NewGuid();
        await manager.HealthCommitAsync(
            healthID, "health", secondProbation.UpdateEpisode!.EpisodeID);
        var committed = await ledger.SnapshotAsync();
        checks.That(committed.UpdateEpisode?.Phase == "committed" &&
                    runtime.FabricStarted && runtime.Accepting &&
                    committed.Operations.Single(operation => operation.OperationID == secondActivationID).State == "completed",
            "Explicit health commit opens the probationary release");
    }

    // Abandoned old-release drains are clearable at startup.
    {
        var paths = new LinuxPaths(TempHome());
        paths.EnsurePrivateDirectories();
        using var executor = new SerializedStateExecutor();
        var ledger = new RecoveryLedgerStore(paths, executor);
        await ledger.InitializeAsync(new string('a', 64));
        var episodeID = Guid.NewGuid();
        var operationID = Guid.NewGuid();
        await ledger.BeginOperationAsync(
            operationID, "update.activate", "drain-crash", episodeID, "draining_old_release");
        await ledger.SetEpisodeAsync(new UpdateEpisode
        {
            EpisodeID = episodeID,
            Phase = "draining_old_release",
            FromReleaseID = "1.0.0-1-linux-test",
            ToReleaseID = "1.0.0-2-linux-test",
            StartedAt = "2026-10-30T16:00:00Z",
            UpdatedAt = "2026-10-30T16:00:00Z",
            Health = "not_applicable",
        });
        var manager = new LinuxUpdateManager(
            paths, ledger, new ReleaseBundleVerifier(paths),
            new FakeUpdateRuntime(), "1.0.0-1-linux-test", "manual-test");
        checks.That(await manager.ReconcileStartupAsync() == StartupAdmission.Open &&
                    (await ledger.GetOperationAsync(operationID))?.State == "aborted",
            "Crash during old-release drain clears the abandoned drain at startup");
    }

    // Installer creates identity, ledger, release link, and supervisor metadata.
    {
        var home = TempHome();
        var paths = new LinuxPaths(home);
        var source = Path.Combine(home, "bootstrap.bin");
        await File.WriteAllTextAsync(source, "fake bootstrap executable");
        var product = ProductInfo.Load(paths);
        var status = await LinuxInstaller.InstallSelfAsync(
            paths, product, source, supervisorOverride: "manual-test");
        checks.That(status.Device.DeviceID is { Length: 64 } &&
                    File.Exists(paths.LedgerFile) &&
                    paths.LinkedReleaseID() == product.ReleaseID &&
                    status.Runtime.Supervisor == "manual-test",
            "Installer creates identity, recovery ledger, release link, and supervisor state");
    }

    // Real host and Unix-socket admin path.
    {
        var paths = new LinuxPaths(TempHome());
        await using var host = new LinuxHost(new LinuxHostOptions
        {
            Paths = paths,
            Port = 0,
            EnableDiscovery = false,
            LoopbackOnly = true,
            InitialSupervisor = "manual-test",
            EnableAgentTicker = false,
        });
        await host.StartAsync();
        try
        {
            AdminRequest Request(string operation, string payload = "{}",
                string? expectedDeviceID = null, Guid? operationID = null) => new()
            {
                AdminApiVersion = 1,
                RequestID = Guid.NewGuid(),
                Operation = operation,
                ExpectedDeviceID = expectedDeviceID,
                OperationID = operationID,
                Payload = JsonDocument.Parse(payload).RootElement.Clone(),
            };

            var statusResponse = await AdminClient.SendAsync(paths, Request("status.get"));
            var status = statusResponse?.Result?.Deserialize<LinuxStatus>(AdminJson.Options);
            checks.That(statusResponse is { Ok: true } && status is not null &&
                        status.Device.DeviceID == host.DeviceID &&
                        status.Runtime.Supervisor == "manual-test" &&
                        status.Runtime.Admission == "open",
                "Unix-socket status reports the running Linux home");

            var mismatch = await AdminClient.SendAsync(
                paths, Request("status.get", expectedDeviceID: new string('0', 64)));
            checks.That(mismatch is { Ok: false } && mismatch.Error?.Code == "identity_mismatch",
                "Admin API rejects a mismatched expected Converse identity");

            const string sentinel = "TEST_SECRET_SENTINEL_DO_NOT_LOG";
            var secret = await AdminClient.SendAsync(paths, Request(
                "secret.set",
                JsonSerializer.Serialize(new Dictionary<string, object>
                {
                    ["secretID"] = "agent.meta.api-key",
                    ["kind"] = "provider_api_key",
                    ["value"] = sentinel,
                })));
            var secretJson = secret is null ? "" : AdminJson.Serialize(secret);
            checks.That(secret is { Ok: true } && !secretJson.Contains(sentinel, StringComparison.Ordinal),
                "Secret set returns metadata without echoing the value");

            var group = await AdminClient.SendAsync(paths, Request(
                "group.create", JsonSerializer.Serialize(new Dictionary<string, object>
                {
                    ["name"] = "Linux Test Group",
                })));
            var groupStatus = group?.Result?.Deserialize<LinuxStatus>(AdminJson.Options);
            checks.That(group is { Ok: true } && groupStatus?.Fabric.GroupName == "Linux Test Group",
                "Admin API can create a Linux-home group");

            var missing = await AdminClient.SendAsync(paths, Request(
                "operation.get",
                JsonSerializer.Serialize(new Dictionary<string, object>
                {
                    ["operationID"] = Guid.NewGuid().ToString("D"),
                })));
            checks.That(missing is { Ok: false } && missing.Error?.Code == "operation_not_found",
                "Unknown durable operations fail honestly");

            var deleted = await AdminClient.SendAsync(paths, Request(
                "secret.delete",
                JsonSerializer.Serialize(new Dictionary<string, object>
                {
                    ["secretID"] = "agent.meta.api-key",
                })));
            checks.That(deleted is { Ok: true }, "Secret delete removes the configured value");

            var processLine = AdminJson.Serialize(
                Request("status.get", expectedDeviceID: host.DeviceID));
            var processResult = await RunAdminRequestProcessAsync(paths, processLine);
            var processResponse = JsonSerializer.Deserialize<AdminResponse>(
                processResult.Stdout, AdminJson.Options);
            checks.That(processResult.ExitCode == 0 && processResponse is { Ok: true },
                "Cross-process admin-request forwards stdin to the Unix socket");
        }
        finally { await host.StopAsync(); }

        var unavailableLine = AdminJson.Serialize(new AdminRequest
        {
            AdminApiVersion = 1,
            RequestID = Guid.NewGuid(),
            Operation = "status.get",
            Payload = JsonDocument.Parse("{}").RootElement.Clone(),
        });
        var unavailable = await RunAdminRequestProcessAsync(paths, unavailableLine);
        var unavailableResponse = JsonSerializer.Deserialize<AdminResponse>(
            unavailable.Stdout, AdminJson.Options);
        checks.That(unavailable.ExitCode == 70 &&
                    unavailableResponse?.Error?.Code == "daemon_unavailable",
            "Cross-process admin-request reports an unavailable daemon with exit 70");
    }
}
finally
{
    foreach (var path in cleanup)
    {
        try { Directory.Delete(path, recursive: true); } catch { /* test cleanup */ }
    }
}

return checks.Finish();

sealed class Checks
{
    private int _passed;
    private int _failed;
    public void That(bool condition, string name)
    {
        if (condition) { _passed++; Console.WriteLine("PASS " + name); }
        else { _failed++; Console.WriteLine("FAIL " + name); }
    }
    public int Finish()
    {
        Console.WriteLine($"{_passed} passed, {_failed} failed");
        return _failed == 0 ? 0 : 1;
    }
}

sealed class FakeRunner : IAgentRunner
{
    public Task<int> RunAsync(
        ChatSession session, IReadOnlyList<string> arguments, string prompt,
        Action<string> onLine, CancellationToken cancellationToken) => Task.FromResult(0);
}

sealed record CreatedBundle(string Path, string Sha256, long Size, ReleaseManifest Manifest);

sealed class FakeUpdateRuntime : ILinuxUpdateRuntime
{
    public int ActiveTurnCount { get; set; }
    public bool FabricStarted { get; private set; }
    public bool Accepting { get; private set; } = true;
    public List<string> Restarts { get; } = new();

    public void SetAcceptingWork(bool accepting) => Accepting = accepting;

    public Task StartFabricAsync(CancellationToken cancellationToken)
    {
        FabricStarted = true;
        return Task.CompletedTask;
    }

    public void RequestRestart(string reason) => Restarts.Add(reason);
}
