using System.Net;

namespace Converse.Core;

// Bonjour may batch several app instances in one datagram, or send PTR, SRV,
// TXT and address records separately. Join by DNS owner name, never packet order.
internal sealed class MdnsResponseCache
{
    private sealed record Record(byte[] Packet, int Offset, int Length, DateTime Expires, DateTime Seen);
    private readonly Dictionary<(string Name, int Type), Record> _records = new();

    internal IReadOnlyList<MdnsService> Read(byte[] packet, DateTime now)
    {
        if (packet.Length < 12 || (packet[2] & 0x80) == 0) return [];
        int U16(int at) => (packet[at] << 8) | packet[at + 1];
        var offset = 12;
        for (var i = 0; i < U16(4); i++)
        {
            MdnsDiscovery.ReadName(packet, ref offset);
            if (offset + 4 > packet.Length) throw new InvalidDataException("Truncated mDNS question");
            offset += 4;
        }
        var updates = new List<((string Name, int Type) Key, Record Value, bool Remove)>();
        for (var i = 0; i < U16(6) + U16(8) + U16(10); i++)
        {
            var owner = MdnsDiscovery.ReadName(packet, ref offset).ToLowerInvariant();
            if (offset + 10 > packet.Length) throw new InvalidDataException("Truncated mDNS record");
            var type = U16(offset);
            var ttl = ((uint)packet[offset + 4] << 24) | ((uint)packet[offset + 5] << 16) | ((uint)packet[offset + 6] << 8) | packet[offset + 7];
            var length = U16(offset + 8); offset += 10;
            if (offset + length > packet.Length) throw new InvalidDataException("Truncated mDNS data");
            // PTR has multiple values under the service type; key each by its target.
            if (type == 12 && owner == MdnsDiscovery.ServiceType)
            {
                var cursor = offset;
                owner = MdnsDiscovery.ReadName(packet, ref cursor).ToLowerInvariant();
                if (cursor > offset + length) throw new InvalidDataException("Invalid mDNS PTR");
            }
            if (type is 1 or 12 or 16 or 28 or 33)
                updates.Add(((owner, type), new(packet, offset, length, now.AddSeconds(Math.Min(ttl, 86400u)), now), ttl == 0));
            offset += length;
        }
        // Validate the whole packet before altering the cache.
        foreach (var key in _records.Where(p => p.Value.Expires <= now).Select(p => p.Key).ToArray()) _records.Remove(key);
        foreach (var update in updates)
            if (update.Remove) _records.Remove(update.Key); else _records[update.Key] = update.Value;
        // Bound untrusted LAN announcements even if a sender uses long TTLs.
        if (_records.Count > 2048)
            foreach (var key in _records.OrderBy(p => p.Value.Seen).Take(_records.Count - 2048).Select(p => p.Key).ToArray()) _records.Remove(key);

        var found = new List<MdnsService>();
        foreach (var (key, ptr) in _records.Where(p => p.Key.Type == 12))
        {
            var instance = key.Name;
            if (!instance.EndsWith("." + MdnsDiscovery.ServiceType, StringComparison.OrdinalIgnoreCase) ||
                !_records.TryGetValue((instance, 33), out var srv) || srv.Length < 7) continue;
            var port = (srv.Packet[srv.Offset + 4] << 8) | srv.Packet[srv.Offset + 5];
            var cursor = srv.Offset + 6;
            var host = MdnsDiscovery.ReadName(srv.Packet, ref cursor);
            if (cursor > srv.Offset + srv.Length || port == 0) continue;
            var seen = ptr.Seen > srv.Seen ? ptr.Seen : srv.Seen;
            if (_records.TryGetValue((host.ToLowerInvariant(), 1), out var address) && address.Length == 4)
                host = new IPAddress(address.Packet.AsSpan(address.Offset, 4)).ToString();
            else if (_records.TryGetValue((host.ToLowerInvariant(), 28), out address) && address.Length == 16)
                host = new IPAddress(address.Packet.AsSpan(address.Offset, 16)).ToString();
            Dictionary<string, string>? txt = null;
            if (_records.TryGetValue((instance, 16), out var text))
            {
                txt = new(StringComparer.OrdinalIgnoreCase);
                foreach (var (name, value) in MdnsDiscovery.ParseTxt(text.Packet.AsSpan(text.Offset, text.Length).ToArray())) txt[name] = value;
                if (text.Seen > seen) seen = text.Seen;
            }
            // Preserve the advertised spelling, including dots in device names.
            cursor = ptr.Offset;
            var display = MdnsDiscovery.ReadName(ptr.Packet, ref cursor);
            display = display[..^(MdnsDiscovery.ServiceType.Length + 1)];
            found.Add(new(display, host, port, MdnsDiscovery.GroupHint(txt), txt?.GetValueOrDefault("device"), seen));
        }
        return found;
    }
}
