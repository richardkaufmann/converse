using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

namespace Converse.Core;

// Minimal mDNS for _converse._tcp.local (RFC 6762/6763 subset): PTR/SRV/A
// advertise + PTR browse with compression-aware decoding. Discovery is
// unauthenticated hints only; pairing remains the trust boundary.
public sealed record MdnsService(string Name, string Host, int Port, ConverseGroup? Group = null, string? DeviceID = null);

public sealed class MdnsDiscovery : IDisposable
{
    public const string ServiceType = "_converse._tcp.local";
    private static readonly IPAddress Group = IPAddress.Parse("224.0.0.251");
    private readonly UdpClient _udp;
    private readonly string _instanceName;
    private readonly int _port;
    private ConverseGroup? _group;
    private string _deviceId;
    private CancellationTokenSource? _shutdown;
    public event Action<MdnsService>? Found;

    public MdnsDiscovery(string instanceName, int port, ConverseGroup? group = null, string deviceId = "")
    {
        _instanceName = instanceName;
        _port = port;
        _group = group;
        _deviceId = deviceId;
        _udp = new UdpClient(AddressFamily.InterNetwork);
        _udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _udp.Client.Bind(new IPEndPoint(IPAddress.Any, 5353));
        _udp.JoinMulticastGroup(Group);
    }

    public void Start()
    {
        _shutdown = new CancellationTokenSource();
        _ = LoopAsync(_shutdown.Token);
        _ = AnnounceAsync();
        _ = QueryAsync();
    }

    public async Task QueryAsync()
    {
        var query = BuildQuery(ServiceType, 12);
        await _udp.SendAsync(query, query.Length, new IPEndPoint(Group, 5353));
    }

    private async Task AnnounceAsync()
    {
        var response = BuildResponse(queryName: ServiceType);
        await _udp.SendAsync(response, response.Length, new IPEndPoint(Group, 5353));
    }

    // Group changes re-announce with fresh TXT hints.
    public void UpdateGroup(ConverseGroup? group, string deviceId)
    {
        _group = group;
        _deviceId = deviceId;
        _ = AnnounceAsync();
    }

    private async Task LoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            UdpReceiveResult result;
            try { result = await _udp.ReceiveAsync(token); }
            catch { break; }
            try { Handle(result.Buffer, result.RemoteEndPoint); }
            catch { /* ignore malformed packets */ }
        }
    }

    private void Handle(byte[] packet, IPEndPoint from)
    {
        if (packet.Length < 12) return;
        var flags = (packet[2] << 8) | packet[3];
        var isResponse = (flags & 0x8000) != 0;
        var questions = (packet[4] << 8) | packet[5];
        var answers = (packet[6] << 8) | packet[7];
        var offset = 12;
        var askedNames = new List<string>();
        for (var i = 0; i < questions; i++)
        {
            askedNames.Add(ReadName(packet, ref offset));
            offset += 4;
        }
        if (!isResponse)
        {
            if (askedNames.Any(n => string.Equals(n, ServiceType, StringComparison.OrdinalIgnoreCase)))
            {
                var response = BuildResponse(queryName: ServiceType);
                _ = _udp.SendAsync(response, response.Length, new IPEndPoint(Group, 5353));
            }
            return;
        }
        string? instance = null;
        string? host = null;
        var port = 0;
        Dictionary<string, string>? txt = null;
        var addresses = new Dictionary<string, string>();
        var records = answers + ((packet[8] << 8) | packet[9]) + ((packet[10] << 8) | packet[11]);
        for (var i = 0; i < records && offset + 10 <= packet.Length; i++)
        {
            var name = ReadName(packet, ref offset);
            var type = (packet[offset] << 8) | packet[offset + 1];
            var rdLength = (packet[offset + 8] << 8) | packet[offset + 9];
            var rdOffset = offset + 10;
            if (type == 12 && string.Equals(name, ServiceType, StringComparison.OrdinalIgnoreCase))
            {
                var p = rdOffset;
                instance = ReadName(packet, ref p);
            }
            else if (type == 33 && rdLength >= 7)
            {
                port = (packet[rdOffset + 4] << 8) | packet[rdOffset + 5];
                var p = rdOffset + 6;
                host = ReadName(packet, ref p);
            }
            else if (type == 1 && rdLength == 4)
            {
                addresses[name] = $"{packet[rdOffset]}.{packet[rdOffset + 1]}.{packet[rdOffset + 2]}.{packet[rdOffset + 3]}";
            }
            else if (type == 16 && rdLength > 0)
            {
                txt ??= new Dictionary<string, string>();
                foreach (var (key, value) in ParseTxt(packet.Skip(rdOffset).Take(rdLength).ToArray()))
                    txt[key] = value;
            }
            offset = rdOffset + rdLength;
        }
        if (instance is not null && host is not null && port > 0)
        {
            var display = instance.Split('.')[0];
            if (!string.Equals(display, _instanceName, StringComparison.OrdinalIgnoreCase))
                Found?.Invoke(new MdnsService(display, addresses.GetValueOrDefault(host, host), port,
                    GroupHint(txt), txt?.GetValueOrDefault("device")));
        }
    }

    private byte[] BuildResponse(string queryName)
    {
        var hostName = Dns.GetHostName().Split('.')[0] + ".local";
        var instance = _instanceName + "." + ServiceType;
        using var stream = new MemoryStream();
        WriteHeader(stream, flags: 0x8400, questions: 0, answers: 4);
        WriteName(stream, queryName);
        WriteRecordHeader(stream, type: 12, ttl: 120, data: EncodeName(instance));
        WriteName(stream, instance);
        var srv = new MemoryStream();
        srv.Write(new byte[] { 0, 0, 0, 0, (byte)(_port >> 8), (byte)_port });
        WriteName(srv, hostName);
        WriteRecordHeader(stream, type: 33, ttl: 120, data: srv.ToArray());
        WriteName(stream, instance);
        WriteRecordHeader(stream, type: 16, ttl: 120, data: EncodeTxt());
        WriteName(stream, hostName);
        var address = LocalIPv4();
        WriteRecordHeader(stream, type: 1, ttl: 120, data: address.GetAddressBytes());
        return stream.ToArray();
    }

    // TXT hints mirror Swift txtRecord keys exactly: device/group always,
    // name/creator only with a group, dissolved only when true. Newlines in
    // names escape as backslash-n; hints are never trusted for admission.
    private byte[] EncodeTxt()
    {
        var entries = new List<string> { "device=" + _deviceId };
        if (_group is { } group)
        {
            entries.Add("group=" + group.Id);
            entries.Add("name=" + group.Name.Replace("\n", "\\n"));
            entries.Add("creator=" + group.Creator);
            if (group.Dissolved) entries.Add("dissolved=1");
        }
        using var stream = new MemoryStream();
        foreach (var entry in entries)
        {
            var bytes = Encoding.UTF8.GetBytes(entry);
            stream.WriteByte((byte)Math.Min(bytes.Length, 255));
            stream.Write(bytes, 0, Math.Min(bytes.Length, 255));
        }
        return stream.ToArray();
    }

    internal static List<(string Key, string Value)> ParseTxt(byte[] rdata)
    {
        var entries = new List<(string, string)>();
        var offset = 0;
        while (offset < rdata.Length)
        {
            var length = rdata[offset++];
            if (length == 0 || offset + length > rdata.Length) break;
            var text = Encoding.UTF8.GetString(rdata, offset, length);
            offset += length;
            var equals = text.IndexOf('=');
            if (equals > 0) entries.Add((text[..equals], text[(equals + 1)..]));
        }
        return entries;
    }

    internal static ConverseGroup? GroupHint(Dictionary<string, string>? txt)
    {
        if (txt is null || !txt.TryGetValue("group", out var id) || !Guid.TryParse(id, out _)) return null;
        return new ConverseGroup
        {
            Id = id, Name = txt.GetValueOrDefault("name", ""),
            Creator = txt.GetValueOrDefault("creator", ""), Dissolved = txt.GetValueOrDefault("dissolved") == "1",
        };
    }

    private static IPAddress LocalIPv4() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Select(a => a.Address)
            .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a))
        ?? IPAddress.Loopback;

    private static byte[] BuildQuery(string name, ushort type)
    {
        using var stream = new MemoryStream();
        WriteHeader(stream, flags: 0, questions: 1, answers: 0);
        WriteName(stream, name);
        stream.Write(new byte[] { (byte)(type >> 8), (byte)type, 0, 1 });
        return stream.ToArray();
    }

    private static void WriteHeader(Stream stream, ushort flags, ushort questions, ushort answers)
    {
        stream.Write(new byte[]
        {
            0, 0, (byte)(flags >> 8), (byte)flags,
            (byte)(questions >> 8), (byte)questions,
            (byte)(answers >> 8), (byte)answers, 0, 0, 0, 0,
        });
    }

    private static void WriteRecordHeader(Stream stream, ushort type, uint ttl, byte[] data)
    {
        stream.Write(new byte[]
        {
            (byte)(type >> 8), (byte)type, 0, 1,
            (byte)(ttl >> 24), (byte)(ttl >> 16), (byte)(ttl >> 8), (byte)ttl,
            (byte)(data.Length >> 8), (byte)data.Length,
        });
        stream.Write(data);
    }

    private static byte[] EncodeName(string name)
    {
        using var stream = new MemoryStream();
        WriteName(stream, name);
        return stream.ToArray();
    }

    private static void WriteName(Stream stream, string name)
    {
        foreach (var label in name.TrimEnd('.').Split('.'))
        {
            var bytes = Encoding.UTF8.GetBytes(label);
            stream.WriteByte((byte)bytes.Length);
            stream.Write(bytes);
        }
        stream.WriteByte(0);
    }

    internal static string ReadName(byte[] packet, ref int offset)
    {
        var labels = new List<string>();
        var jumped = false;
        var next = offset;
        var guard = 0;
        while (offset < packet.Length && guard++ < 32)
        {
            var length = packet[offset];
            if (length == 0) { offset++; break; }
            if ((length & 0xC0) == 0xC0)
            {
                var pointer = ((length & 0x3F) << 8) | packet[offset + 1];
                if (!jumped) next = offset + 2;
                jumped = true;
                offset = pointer;
                continue;
            }
            offset++;
            labels.Add(Encoding.UTF8.GetString(packet, offset, Math.Min(length, packet.Length - offset)));
            offset += length;
        }
        if (jumped) offset = next;
        return string.Join(".", labels);
    }

    public void Dispose()
    {
        _shutdown?.Cancel();
        _udp.Dispose();
    }
}
