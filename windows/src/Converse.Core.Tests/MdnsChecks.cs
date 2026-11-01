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
            (normal, 16, Txt("device=normal-id", "group=" + normalGroup, "name=Inside Air"), 120u),
            (demo, 16, Txt("device=demo-id", "group=" + demoGroup, "name=My First Group"), 120u),
            (host, 1, new byte[] { 192, 0, 2, 1 }, 120u),
            ("unrelated._other._tcp.local", 16, Txt("group=" + normalGroup, "name=Wrong group"), 120u)
        };
        bool Correct(IReadOnlyList<MdnsService> result) => result.Count == 2 &&
            result.Any(s => s.Name == "Richard-Air [aaaaaaaa]" && s.Port == 48721 && s.DeviceID == "normal-id" && s.Group?.Name == "Inside Air" && s.Host == "192.0.2.1") &&
            result.Any(s => s.Name == "Converse Demo.v2 [bbbbbbbb]" && s.Port == 59082 && s.DeviceID == "demo-id" && s.Group?.Name == "My First Group" && s.Host == "192.0.2.1");
        check(Correct(new MdnsResponseCache().Read(Packet(ptrs.Concat(details).ToArray()), now)), "mDNS preserves both groups, identities and ports when one Mac advertises production and Demo together");
        check(Correct(new MdnsResponseCache().Read(Packet(details.Concat(ptrs).Reverse().ToArray()), now)), "mDNS associates records by owner independently of order and unrelated TXT");
        var cache = new MdnsResponseCache();
        check(cache.Read(Packet(ptrs), now).Count == 0 && Correct(cache.Read(Packet(details), now)), "mDNS joins PTR and details across separate packets");
        var update = cache.Read(Packet((demo.ToUpperInvariant(), 16, Txt("device=demo-id", "group=" + demoGroup, "name=Renamed Demo"), 120u)), now.AddSeconds(1));
        check(update.Single(s => s.DeviceID == "demo-id").Group?.Name == "Renamed Demo" && update.Single(s => s.DeviceID == "normal-id").Group?.Name == "Inside Air", "mDNS TXT-only group changes update only the matching instance case-insensitively");
        check(cache.Read(Packet((service, 12, Name(demo), 0u)), now.AddSeconds(2)).Count == 1, "mDNS goodbye removes only the announced instance");
        check(cache.Read(Packet(), now.AddSeconds(122)).Count == 0, "mDNS expired records do not keep vanished groups discoverable");
        var malformed = Packet(ptrs)[..^1]; var rejected = false;
        try { cache.Read(malformed, now); } catch (InvalidDataException) { rejected = true; }
        check(rejected, "mDNS rejects truncated record data");
    }
}
