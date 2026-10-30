using System.Runtime.InteropServices;
using System.Text.Json;

namespace Converse.Linux;

internal static class DurableJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = false,
    };

    public static void Write<T>(string file, T value)
    {
        var directory = Path.GetDirectoryName(file)
            ?? throw new InvalidOperationException("A durable file needs a directory.");
        Directory.CreateDirectory(directory);
        var temp = Path.Combine(directory, $".{Path.GetFileName(file)}.{Guid.NewGuid():N}.tmp");
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(value, Options);
            using (var stream = new FileStream(
                temp, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                bufferSize: 8192, FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temp, file, overwrite: true);
            TrySyncDirectory(directory);
        }
        finally
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch { /* best effort */ }
        }
    }

    public static void TrySyncDirectory(string directory)
    {
        if (OperatingSystem.IsWindows()) return;
        var fd = -1;
        try
        {
            fd = OpenDirectory(directory);
            if (fd >= 0) _ = Fsync(fd);
        }
        catch { /* Directory fsync is best-effort across Unix variants. */ }
        finally
        {
            if (fd >= 0) _ = Close(fd);
        }
    }

    private static int OpenDirectory(string directory)
    {
        // O_RDONLY on Linux and macOS. Opening the directory itself is only
        // for fsync; any failure is handled by TrySyncDirectory.
        return Open(directory, 0);
    }

    [DllImport("libc", EntryPoint = "open", SetLastError = true, CharSet = CharSet.Ansi)]
    private static extern int Open(string path, int flags);

    [DllImport("libc", EntryPoint = "fsync", SetLastError = true)]
    private static extern int Fsync(int fd);

    [DllImport("libc", EntryPoint = "close", SetLastError = true)]
    private static extern int Close(int fd);
}

internal static class LinuxFileModes
{
    public static void Directory700(string path)
    {
        Directory.CreateDirectory(path);
        Set(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }

    public static void File600(string path)
    {
        if (File.Exists(path))
            Set(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }

    public static void File700(string path)
    {
        if (File.Exists(path))
            Set(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }

    private static void Set(string path, UnixFileMode mode)
    {
        if (OperatingSystem.IsWindows()) return;
        try { File.SetUnixFileMode(path, mode); }
        catch { /* The per-user install still relies on the account boundary. */ }
    }
}

internal static class LinuxTime
{
    public static string Now() => Format(DateTimeOffset.UtcNow);

    public static string Format(DateTimeOffset value) =>
        value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'",
            System.Globalization.CultureInfo.InvariantCulture);

    public static string FromAppleEpoch(double seconds) =>
        Format(DateTimeOffset.FromUnixTimeMilliseconds(
            checked((long)Math.Round((seconds + 978307200) * 1000))));
}
