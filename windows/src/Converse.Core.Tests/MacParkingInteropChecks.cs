using Converse.Core;

// Explicit cross-platform probe against --ipad-home-fixture, never a production Group.
internal static class MacParkingInteropChecks
{
    public static async Task<int> Run(string host, int port)
    {
        var folder = Directory.CreateTempSubdirectory("converse-mac-parking-interop-").FullName;
        DeviceSyncService Open()
        {
            var service = new DeviceSyncService(folder, new SessionStore(folder), "Isolated Windows Parking Lot viewer");
            service.PairingConfirmation = _ => Task.FromResult(true);
            return service;
        }
        async Task Until(Func<bool> predicate, string label)
        {
            var deadline = DateTime.UtcNow.AddSeconds(30);
            while (!predicate() && DateTime.UtcNow < deadline) await Task.Delay(50);
            if (!predicate()) throw new InvalidOperationException(label);
            Console.WriteLine("PASS: " + label);
        }
        DeviceSyncService? viewer = null;
        try
        {
            viewer = Open();
            await viewer.StartAsync(0, false);
            await viewer.JoinGroupByAddressAsync(host, port, "");
            await Until(() => viewer.CurrentGroup is not null && viewer.Homes.Values.Any(h => h.Rows.Any(r => r.Engine == "parking" && r.Title == "Mobile Parking Lot fixture")), "Windows discovers isolated Mac Group Parking Lot");
            var lot = viewer.Homes.Values.SelectMany(h => h.Rows).Single(r => r.Engine == "parking" && r.Title == "Mobile Parking Lot fixture");
            await viewer.AcquireRemoteAsync(lot.GlobalID);
            await Until(() => viewer.RemoteTranscripts.GetValueOrDefault(lot.GlobalID)?.Engine == "parking", "Windows opens Mac Parking Lot snapshot");
            var snapshot = viewer.RemoteTranscripts[lot.GlobalID];
            if (Environment.GetEnvironmentVariable("CONVERSE_LOT_READ_INTEROP") == "1" && snapshot.Epoch is not > 0)
                throw new InvalidOperationException("Read-only lot did not receive an exclusive display epoch");
            Console.WriteLine("PASS: Parking Lot display epoch=" + snapshot.Epoch);
            var hash = snapshot.Messages.SelectMany(m => m.ImageHashes).Single();
            var path = await viewer.DownloadBlobAsync(lot.GlobalID, hash);
            if (path is null || !DeviceBlob.Verify(await File.ReadAllBytesAsync(path), hash)) throw new InvalidOperationException("Mac Parking Lot image bytes did not download and verify");
            Console.WriteLine("PASS: Windows downloads and SHA256-verifies Mac Parking Lot item image");
            await Until(() => viewer.RemoteTranscripts[lot.GlobalID].HomeSeq > snapshot.HomeSeq, "Windows receives live Mac Parking Lot edits");
            var command = await viewer.SendRemoteCommandAsync(lot.GlobalID, new DeviceCommandPayload { Action = "submit", Text = "must not mutate fixture" });
            if (command is not null || viewer.Unresolved(lot.GlobalID).Count != 0) throw new InvalidOperationException("Parking Lot viewer created an editing command");
            Console.WriteLine("PASS: Windows Mac Parking Lot viewer rejects edits locally");
            await viewer.ReleaseRemoteAsync(lot.GlobalID);
            viewer.Dispose(); viewer = Open();
            await viewer.StartAsync(0, false);
            await viewer.ConnectManualAsync(host, port);
            await Until(() => viewer.Homes.Values.Any(h => h.Rows.Any(r => r.GlobalID == lot.GlobalID)), "Windows reconnects to trusted Mac Group after restart");
            await viewer.AcquireRemoteAsync(lot.GlobalID);
            await Until(() => viewer.RemoteTranscripts.GetValueOrDefault(lot.GlobalID)?.Engine == "parking", "Windows reopens Mac Parking Lot after reconnect");
            var downloaded = await viewer.DownloadBlobAsync(lot.GlobalID, hash);
            if (downloaded is null || !DeviceBlob.Verify(await File.ReadAllBytesAsync(downloaded), hash)) throw new InvalidOperationException("Parking Lot image unavailable after reconnect");
            Console.WriteLine("PASS: Mac Parking Lot image available after Windows reconnect");
            await viewer.ReleaseRemoteAsync(lot.GlobalID);
            Console.WriteLine("PASS: Windows-Mac Parking Lot interoperability complete");
            return 0;
        }
        catch (Exception ex) { Console.WriteLine("FAIL: " + ex + "; status=" + viewer?.ServiceStatus + "; outcome=" + viewer?.LastOutcome + "; profile=" + folder); return 1; }
        finally { viewer?.Dispose(); }
    }
}
