using System.Text;
using Converse.Core;

static class MdnsChecks
{
    internal static void Run(Action<bool, string> check)
    {
        const string service = MdnsDiscovery.ServiceType;
        const string normal = "Richard-Air [aaaaaaaa]." + service;
        const string demo = "Converse Demo.v2 [bbbbbbbb]." + service;
        const string host = "Richard-Air.local";
        var normalGroup = Guid.NewGuid().ToString(); var demoGroup = Guid.NewGuid().ToString();
        var now = DateTime.UtcNow;
        var normalId = new string('a', 64); var demoId = new string('b', 64);
        static byte[] Name(string name) => name.Split('.').SelectMany(s => new[] { (byte)Encoding.UTF8.GetByteCount(s) }.Concat(Encoding.UTF8.GetBytes(s))).Append((byte)0).ToArray();
        static byte[] Txt(params string[] entries) => entries.SelectMany(s => new[] { (byte)Encoding.UTF8.GetByteCount(s) }.Concat(Encoding.UTF8.GetBytes(s))).ToArray();
        static byte[] Srv(string host, int port) => new byte[] { 0, 0, 0, 0, (byte)(port >> 8), (byte)port }.Concat(Name(host)).ToArray();
        static byte[] Packet(params (string Owner, int Type, byte[] Data, uint Ttl)[] records)
        {
            using var output = new MemoryStream();
            output.Write(new byte[] { 0, 0, 0x84, 0, 0, 0, 0, (byte)records.Length, 0, 0, 0, 0 });
            foreach (var (owner, type, data, ttl) in records)
            {
                output.Write(Name(owner));
                output.Write(new byte[] { (byte)(type >> 8), (byte)type, 0, 1, (byte)(ttl >> 24), (byte)(ttl >> 16), (byte)(ttl >> 8), (byte)ttl, (byte)(data.Length >> 8), (byte)data.Length });
                output.Write(data);
            }
            return output.ToArray();
        }
        var ptrs = new[] { (service, 12, Name(normal), 120u), (service, 12, Name(demo), 120u) };
        var details = new[] {
            (normal, 33, Srv(host, 48721), 120u), (demo, 33, Srv(host, 59082), 120u),
            (normal, 16, Txt("device=" + normalId, "group=" + normalGroup, "name=Inside Air"), 120u),
            (demo, 16, Txt("device=" + demoId, "group=" + demoGroup, "name=My First Group"), 120u),
            (host, 1, new byte[] { 192, 0, 2, 1 }, 120u),
            ("unrelated._other._tcp.local", 16, Txt("group=" + normalGroup, "name=Wrong group"), 120u)
        };
        bool Correct(IReadOnlyList<MdnsService> result) => result.Count == 2 &&
            result.Any(s => s.Name == "Richard-Air [aaaaaaaa]" && s.Port == 48721 && s.DeviceID == normalId && s.Group?.Name == "Inside Air" && s.Host == "192.0.2.1") &&
            result.Any(s => s.Name == "Converse Demo.v2 [bbbbbbbb]" && s.Port == 59082 && s.DeviceID == demoId && s.Group?.Name == "My First Group" && s.Host == "192.0.2.1");
        check(Correct(new MdnsResponseCache().Read(Packet(ptrs.Concat(details).ToArray()), now)), "mDNS preserves both groups, identities and ports when one Mac advertises production and Demo together");
        check(Correct(new MdnsResponseCache().Read(Packet(details.Concat(ptrs).Reverse().ToArray()), now)), "mDNS associates records by owner independently of order and unrelated TXT");
        var cache = new MdnsResponseCache();
        check(cache.Read(Packet(ptrs), now).Count == 0 && Correct(cache.Read(Packet(details), now)), "mDNS joins PTR and details across separate packets");
        var update = cache.Read(Packet((demo.ToUpperInvariant(), 16, Txt("device=" + demoId, "group=" + demoGroup, "name=Renamed Demo"), 120u)), now.AddSeconds(1));
        check(update.Single(s => s.DeviceID == demoId).Group?.Name == "Renamed Demo" && update.Single(s => s.DeviceID == normalId).Group?.Name == "Inside Air", "mDNS TXT-only group changes update only the matching instance case-insensitively");
        check(cache.Read(Packet((service, 12, Name(demo), 0u)), now.AddSeconds(2)).Count == 1, "mDNS goodbye removes only the announced instance");
        check(cache.Read(Packet(), now.AddSeconds(122)).Count == 0, "mDNS expired records do not keep vanished groups discoverable");
        var malformed = Packet(ptrs)[..^1]; var rejected = false;
        try { cache.Read(malformed, now); } catch (InvalidDataException) { rejected = true; }
        check(rejected, "mDNS rejects truncated record data");

        // A compression pointer as the SRV's last byte used to be cached and
        // then throw on every later lookup until its TTL (up to 24h) expired.
        cache = new MdnsResponseCache();
        check(Correct(cache.Read(Packet(ptrs.Concat(details).ToArray()), now)), "mDNS baseline before a malformed SRV");
        var badSrv = Packet((normal, 33, new byte[] { 0, 0, 0, 0, 0xBE, 0x51, 0xC0 }, 86400u));
        rejected = false;
        try { cache.Read(badSrv, now.AddSeconds(1)); } catch (InvalidDataException) { rejected = true; }
        check(rejected && Correct(cache.Read(Packet(), now.AddSeconds(2))),
            "mDNS rejects an SRV ending in a compression pointer without poisoning later reads");
        var unterminated = new MdnsResponseCache();
        rejected = false;
        try { unterminated.Read(Packet(ptrs.Concat(details).Append((normal, 33, new byte[] { 0, 0, 0, 0, 0xBE, 0x51, 0xC0 }, 120u)).ToArray()), now); }
        catch (InvalidDataException) { rejected = true; }
        check(rejected && unterminated.Read(Packet(ptrs.Concat(details).ToArray()), now.AddSeconds(1)).Count == 2,
            "mDNS validates the whole packet, including SRV targets, before caching any record");
        var shortSrv = new MdnsResponseCache();
        rejected = false;
        try { shortSrv.Read(Packet((normal, 33, new byte[] { 0, 0, 0, 0, 0xBE }, 120u)), now); } catch (InvalidDataException) { rejected = true; }
        check(rejected, "mDNS rejects SRV data too short to hold a target");
        var foreignPtr = new MdnsResponseCache().Read(Packet(ptrs.Concat(details).Append(
            (normal, 12, Name("x"), 120u)).ToArray()), now);
        check(Correct(foreignPtr), "mDNS ignores PTR records outside the Converse service type");

        // TXT device= is a lookup key; anything but 64 lowercase hex is dropped.
        foreach (var bogus in new[] { "ab", "", new string('A', 64), new string('a', 63), new string('a', 65), new string('g', 64), "aaaaaaa\u00e9" + new string('a', 56) })
        {
            var found = new MdnsResponseCache().Read(Packet(ptrs[0], details[0], details[4],
                (normal, 16, Txt("device=" + bogus, "group=" + normalGroup, "name=Inside Air"), 120u)), now).SingleOrDefault();
            check(found is { DeviceID: null, Port: 48721 } && found.Group?.Name == "Inside Air",
                $"mDNS ignores invalid device hint '{(bogus.Length > 12 ? bogus[..12] + "…" : bogus)}' ({bogus.Length} chars) but keeps the service");
        }
    }

    // GroupDevices sliced id[..8] on the UI thread; short IDs from LAN hints
    // or a hand-edited trust file must not throw.
    internal static void RunGroupDevices(Action<bool, string> check)
    {
        var dir = Directory.CreateTempSubdirectory("converse-mdns-labels-").FullName;
        try
        {
            using var a = new DeviceSyncService(dir, new SessionStore(dir, new FakeRunner()), "A");
            a.CreateGroupAsync("Home").GetAwaiter().GetResult();
            var home = a.CurrentGroup!;
            a.Trust.Pin(new TrustedDevice("abc", "Twin", new byte[32], null, null), groupID: home.Id);
            lock (a.DiscoveredDevices)
            {
                a.DiscoveredDevices.Add(new MdnsService("Twin", "127.0.0.1", 1, home, "xy", DateTime.UtcNow));
                a.DiscoveredDevices.Add(new MdnsService("Stranger", "127.0.0.1", 2, home, "", DateTime.UtcNow));
            }
            List<(string DeviceID, string Label)>? rows = null;
            try { rows = a.GroupDevices(home); } catch { }
            check(rows is not null && rows.Any(r => r.Label == "Twin [abc]") && rows.Any(r => r.Label == "Twin [xy]")
                && rows.Any(r => r.DeviceID == a.DeviceId),
                "Group device labels tolerate device IDs shorter than eight characters");
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }
}
