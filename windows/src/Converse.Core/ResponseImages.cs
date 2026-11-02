using System.Net.Http;
using System.Text.RegularExpressions;

namespace Converse.Core;

// Response image capture (Mac ResponseImages parity): explicit markdown
// image refs in assistant replies become managed attachments, and the
// markdown collapses to its caption. File imports stay inside permitted
// roots; at most 8 images per message; files cap at 8 MB. Home file
// paths never cross the wire — viewers resolve content by hash.
public static class ResponseImages
{
    public const int MaxImages = 8;
    public const long MaxBytes = 8_000_000;

    public sealed record Captured(int Start, int Length, string Caption, byte[] Bytes);

    private static readonly Regex RefPattern = new(
        @"!\[([^\]\r\n]*)\]\(\s*(?:<([^>\r\n]+)>|([^\s\)]+))\s*\)",
        RegexOptions.Compiled);

    private static readonly Regex DriveRooted = new(@"^[A-Za-z]:[\\/]", RegexOptions.Compiled);

    private static readonly byte[] PngSignature = { 137, 80, 78, 71, 13, 10, 26, 10 };

    // Pure parser: file-backed ![caption](path) refs outside fences,
    // blockquotes, and inline code. HTTPS refs are NOT captured here;
    // the importer downloads those first through the bounded client.
    public static List<(int Start, int Length, string Caption, string Path)> ParseFileRefs(string text)
    {
        var found = new List<(int, int, string, string)>();
        var offset = 0;
        string? fence = null;
        foreach (var line in text.Split('\n'))
        {
            var lineStart = offset;
            offset += line.Length + 1;
            var trimmed = line.Trim();
            if (trimmed.StartsWith("```", StringComparison.Ordinal) || trimmed.StartsWith("~~~", StringComparison.Ordinal))
            {
                var marker = trimmed[..3];
                if (fence == marker) fence = null;
                else if (fence is null) fence = marker;
                continue;
            }
            if (fence is not null || trimmed.StartsWith('>') || line.Contains('`')) continue;
            foreach (Match match in RefPattern.Matches(line))
            {
                if (found.Count >= MaxImages) break;
                if (match.Index > 0 && line[match.Index - 1] == '\\') continue;
                var target = match.Groups[2].Success ? match.Groups[2].Value : match.Groups[3].Value;
                if (!IsFileRef(target)) continue;
                found.Add((lineStart + match.Index, match.Length, match.Groups[1].Value, target));
            }
        }
        return found;
    }

    // Pure parser twin for https refs (downloaded, never read from disk).
    public static List<(int Start, int Length, string Caption, string Url)> ParseWebRefs(string text)
    {
        var found = new List<(int, int, string, string)>();
        var offset = 0;
        string? fence = null;
        foreach (var line in text.Split('\n'))
        {
            var lineStart = offset;
            offset += line.Length + 1;
            var trimmed = line.Trim();
            if (trimmed.StartsWith("```", StringComparison.Ordinal) || trimmed.StartsWith("~~~", StringComparison.Ordinal))
            {
                var marker = trimmed[..3];
                if (fence == marker) fence = null;
                else if (fence is null) fence = marker;
                continue;
            }
            if (fence is not null || trimmed.StartsWith('>') || line.Contains('`')) continue;
            foreach (Match match in RefPattern.Matches(line))
            {
                if (found.Count >= MaxImages) break;
                if (match.Index > 0 && line[match.Index - 1] == '\\') continue;
                var target = match.Groups[2].Success ? match.Groups[2].Value : match.Groups[3].Value;
                if (!target.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) continue;
                found.Add((lineStart + match.Index, match.Length, match.Groups[1].Value, target));
            }
        }
        return found;
    }

    private static bool IsFileRef(string target)
    {
        if (target.StartsWith("file://", StringComparison.OrdinalIgnoreCase)) return true;
        if (target.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
            || target.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) return false;
        return Path.IsPathRooted(target) || DriveRooted.IsMatch(target);
    }

    public static string? FileRefToLocalPath(string target)
    {
        if (target.StartsWith("file://", StringComparison.OrdinalIgnoreCase))
        {
            try { return new Uri(target).LocalPath; }
            catch { return null; }
        }
        return target;
    }

    // Root gate: the resolved path must sit inside one of the roots.
    // Comparison is case-insensitive on Windows, exact elsewhere.
    public static bool IsUnderRoot(string path, IReadOnlyList<string> roots)
    {
        string full;
        try { full = Path.GetFullPath(path); }
        catch { return false; }
        var comparison = Path.DirectorySeparatorChar == '\\'
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        foreach (var root in roots)
        {
            string fullRoot;
            try { fullRoot = Path.GetFullPath(root); }
            catch { continue; }
            if (!fullRoot.EndsWith(Path.DirectorySeparatorChar)) fullRoot += Path.DirectorySeparatorChar;
            if (full.StartsWith(fullRoot, comparison)) return true;
        }
        return false;
    }

    // Magic-byte validation for common raster formats. PNG dimensions
    // parse from IHDR (pure, tested); other rasters pass by magic — the
    // WinUI renderer decodes them, and failures show the caption.
    public static bool IsSupportedImage(byte[] bytes)
    {
        if (bytes.Length < 16 || bytes.Length > MaxBytes) return false;
        if (StartsWith(bytes, PngSignature)) return TryPngDimensions(bytes, out _, out _);
        if (bytes is [0xFF, 0xD8, 0xFF, ..]) return true; // JPEG
        if (bytes.Length >= 6 && bytes[0] == 'G' && bytes[1] == 'I' && bytes[2] == 'F') return true;
        if (bytes is [(byte)'B', (byte)'M', ..]) return true; // BMP
        if (bytes.Length >= 12 && StartsWith(bytes, "RIFF"u8.ToArray()) && bytes[8] == 'W' && bytes[9] == 'E'
            && bytes[10] == 'B' && bytes[11] == 'P') return true;
        return false;
    }

    private static bool StartsWith(byte[] bytes, byte[] prefix)
    {
        if (bytes.Length < prefix.Length) return false;
        for (var i = 0; i < prefix.Length; i++) if (bytes[i] != prefix[i]) return false;
        return true;
    }

    public static bool TryPngDimensions(byte[] bytes, out int width, out int height)
    {
        width = height = 0;
        if (bytes.Length < 24 || !StartsWith(bytes, PngSignature)) return false;
        if (bytes[12] != 'I' || bytes[13] != 'H' || bytes[14] != 'D' || bytes[15] != 'R') return false;
        width = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
        height = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
        return width > 0 && height > 0 && width <= 16384 && height <= 16384
            && (long)width * height <= 64_000_000;
    }

    private static readonly HttpClient NoRedirectClient = new(new SocketsHttpHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromSeconds(30) };

    // Canonical fetch form: https, no credentials, default port, and no
    // query or fragment — model output can smuggle private context into
    // either, and the host plus path identify the fetch. Null means never
    // fetch this ref.
    public static Uri? CanonicalWebImageUrl(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var parsed)) return null;
        if (!parsed.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase)) return null;
        if (!string.IsNullOrEmpty(parsed.UserInfo)) return null;
        if (!parsed.IsDefaultPort && parsed.Port != 443) return null;
        var builder = new UriBuilder(parsed) { Query = "", Fragment = "" };
        builder.Port = -1;
        return builder.Uri;
    }

    // Mac allowedIPv4/publicHTTPS parity: link-local, private, reserved and
    // documentation ranges never fetch, so a prompt-injected URL cannot probe
    // the LAN. Hostnames resolve first; every returned address must pass.
    public static bool IsPublicAddress(System.Net.IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        var bytes = address.GetAddressBytes();
        if (bytes.Length == 4)
        {
            var (a, b, c) = (bytes[0], bytes[1], bytes[2]);
            if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
            if (a == 100 && b >= 64 && b <= 127) return false;
            if (a == 169 && b == 254) return false;
            if (a == 172 && b >= 16 && b <= 31) return false;
            if (a == 192 && (b == 168 || b == 0 || (b == 88 && c == 99))) return false;
            if (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) return false;
            if (a == 203 && b == 0 && c == 113) return false;
            return true;
        }
        if (bytes.Length == 16)
        {
            if ((bytes[0] & 0xe0) != 0x20) return false;
            if (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8) return false;
            return true;
        }
        return false;
    }

    public static async Task<bool> IsPublicHostAsync(string host)
    {
        System.Net.IPAddress[] addresses;
        try { addresses = await System.Net.Dns.GetHostAddressesAsync(host); }
        catch { return false; }
        return addresses.Length > 0 && addresses.All(IsPublicAddress);
    }

    // Converts an assistant reply's image refs into managed attachments:
    // file refs inside the roots, plus bounded public-HTTPS downloads.
    // The markdown collapses to its caption; validated bytes store as
    // Response-<hash>.png beside the session's attachments. Returns true
    // when the message changed.
    public static async Task<bool> ImportAsync(string dataFolder, ChatSession session, ChatMessage message)
    {
        if (!message.Text.Contains("![", StringComparison.Ordinal)) return false;
        var budget = Math.Max(0, MaxImages - message.Images.Count);
        if (budget == 0) return false;
        var output = Path.Combine(dataFolder, "Attachments", session.Id.ToString("D"));
        var roots = new List<string> { output, Path.GetTempPath() };
        var working = session.Entry.Directory;
        if (!string.IsNullOrWhiteSpace(working) && working != "/" && working != Path.GetPathRoot(working))
            roots.Add(working);
        var takes = new List<(int Start, int Length, string Caption, byte[] Bytes)>();
        var failed = new List<(int Start, int Length, string Caption)>();
        foreach (var (start, length, caption, target) in ParseFileRefs(message.Text))
        {
            if (takes.Count >= budget) break;
            var local = FileRefToLocalPath(target);
            if (local is null || !IsUnderRoot(local, roots)) continue;
            byte[] bytes;
            try
            {
                if (!File.Exists(local)) continue;
                bytes = await File.ReadAllBytesAsync(local);
            }
            catch { continue; }
            if (!IsSupportedImage(bytes)) continue;
            takes.Add((start, length, caption, bytes));
        }
        foreach (var (start, length, caption, url) in ParseWebRefs(message.Text))
        {
            if (takes.Count >= budget) break;
            var bytes = await DownloadWebImageAsync(url);
            if (bytes is null) { failed.Add((start, length, caption)); continue; }
            takes.Add((start, length, caption, bytes));
        }
        // A dead image reads as its caption plus an X, never a hanging
        // blank or a re-clickable trap.
        var text = message.Text;
        foreach (var (start, length, caption) in failed.OrderByDescending(t => t.Start))
            text = text[..start] + caption + " ❌" + text[(start + length)..];
        if (takes.Count == 0) { message.Text = text; return failed.Count > 0; }
        Directory.CreateDirectory(output);
        foreach (var (start, length, caption, bytes) in takes.OrderByDescending(t => t.Start))
        {
            var hash = DeviceBlob.Sha256Hex(bytes);
            try { await File.WriteAllBytesAsync(Path.Combine(output, "Response-" + hash + ".png"), bytes); }
            catch { continue; }
            text = text[..start] + caption + text[(start + length)..];
            var stored = Path.Combine(output, "Response-" + hash + ".png");
            if (!message.Images.Contains(stored)) message.Images.Add(stored);
        }
        message.Text = text;
        return true;
    }

    // Bounded public-HTTPS download: canonical form, public destination,
    // no credentials or cookies, 8 MB cap enforced while reading,
    // magic-validated before return. Redirects are followed manually so
    // every hop re-validates canonical form and destination.
    public static async Task<byte[]?> DownloadWebImageAsync(string url)
    {
        var next = CanonicalWebImageUrl(url);
        try
        {
            for (var hop = 0; hop <= 3 && next is not null; hop++)
            {
                if (!await IsPublicHostAsync(next.Host)) return null;
                using var response = await NoRedirectClient.GetAsync(next, HttpCompletionOption.ResponseHeadersRead);
                if (response.StatusCode is System.Net.HttpStatusCode.MovedPermanently
                    or System.Net.HttpStatusCode.Found or System.Net.HttpStatusCode.SeeOther
                    or System.Net.HttpStatusCode.TemporaryRedirect or System.Net.HttpStatusCode.PermanentRedirect)
                {
                    next = response.Headers.Location is { } target && target.IsAbsoluteUri
                        ? CanonicalWebImageUrl(target.AbsoluteUri)
                        : next is not null && response.Headers.Location is { } relative
                            ? CanonicalWebImageUrl(new Uri(next, relative).AbsoluteUri)
                            : null;
                    continue;
                }
                if (!response.IsSuccessStatusCode) return null;
                var declared = response.Content.Headers.ContentLength;
                if (declared is not null && (declared <= 0 || declared > MaxBytes)) return null;
                using var stream = await response.Content.ReadAsStreamAsync();
                using var buffer = new MemoryStream();
                var chunk = new byte[32_768];
                int read;
                while ((read = await stream.ReadAsync(chunk)) > 0)
                {
                    buffer.Write(chunk, 0, read);
                    if (buffer.Length > MaxBytes) return null;
                }
                var bytes = buffer.ToArray();
                return IsSupportedImage(bytes) ? bytes : null;
            }
            return null;
        }
        catch { return null; }
    }
}
