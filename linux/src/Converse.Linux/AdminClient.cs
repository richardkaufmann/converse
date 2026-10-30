using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace Converse.Linux;

internal static class AdminClient
{
    public static async Task<int> RunAsync(LinuxPaths paths)
    {
        var input = await Console.In.ReadToEndAsync();
        var line = input.Trim('\r', '\n');
        Guid requestID = Guid.Empty;
        try
        {
            if (line.Length == 0 || Encoding.UTF8.GetByteCount(line) > 64 * 1024 ||
                line.Contains('\n') || line.Contains('\r'))
                return 64;
            using (var document = JsonDocument.Parse(line))
            {
                if (document.RootElement.TryGetProperty("requestID", out var id))
                    Guid.TryParse(id.GetString(), out requestID);
            }
        }
        catch { return 64; }

        var responseLine = await SendLineAsync(paths, line, TimeSpan.FromSeconds(30));
        if (responseLine is null)
        {
            Console.WriteLine(AdminJson.Serialize(AdminResponse.Failure(
                requestID, "daemon_unavailable",
                "The Converse daemon is not accepting local admin requests.", retryable: true)));
            return 70;
        }
        Console.WriteLine(responseLine);
        try
        {
            using var document = JsonDocument.Parse(responseLine);
            var code = document.RootElement.GetProperty("error").ValueKind == JsonValueKind.Object
                ? document.RootElement.GetProperty("error").GetProperty("code").GetString()
                : null;
            return code == "daemon_unavailable" ? 70 : 0;
        }
        catch { return 70; }
    }

    public static async Task<int> RunSecretAsync(LinuxPaths paths)
    {
        Guid requestID = Guid.Empty;
        byte[] input;
        try
        {
            await using var stdin = Console.OpenStandardInput();
            using var buffer = new MemoryStream();
            await stdin.CopyToAsync(buffer);
            if (buffer.Length is 0 or > 96 * 1024) return 64;
            input = buffer.ToArray();
            var newline = Array.IndexOf(input, (byte)'\n');
            if (newline < 0) return 64;
            using var header = JsonDocument.Parse(Encoding.UTF8.GetString(input, 0, newline));
            if (header.RootElement.TryGetProperty("requestID", out var id))
                Guid.TryParse(id.GetString(), out requestID);
        }
        catch { return 64; }

        string? responseLine = null;
        try
        {
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            using var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            await socket.ConnectAsync(
                new UnixDomainSocketEndPoint(paths.SecretSocketPath), cancellation.Token);
            await using var stream = new NetworkStream(socket, ownsSocket: true);
            await stream.WriteAsync(input, cancellation.Token);
            socket.Shutdown(SocketShutdown.Send);
            responseLine = await LinuxHost.ReadOneLineAsync(
                stream, 1024 * 1024, cancellation.Token);
        }
        catch { /* Response below. */ }

        if (responseLine is null)
        {
            Console.WriteLine(AdminJson.Serialize(SecretResponse.Failure(
                requestID, "daemon_unavailable",
                "The Converse daemon is not accepting local secret requests.", retryable: true)));
            return 70;
        }
        Console.WriteLine(responseLine);
        try
        {
            using var document = JsonDocument.Parse(responseLine);
            var code = document.RootElement.GetProperty("error").ValueKind == JsonValueKind.Object
                ? document.RootElement.GetProperty("error").GetProperty("code").GetString()
                : null;
            return code == "daemon_unavailable" ? 70 : 0;
        }
        catch { return 70; }
    }

    public static async Task<AdminResponse?> SendAsync(
        LinuxPaths paths, AdminRequest request, TimeSpan? timeout = null)
    {
        var line = await SendLineAsync(
            paths, AdminJson.Serialize(request), timeout ?? TimeSpan.FromSeconds(30));
        return line is null
            ? null
            : JsonSerializer.Deserialize<AdminResponse>(line, AdminJson.Options);
    }

    public static async Task<LinuxStatus?> TryStatusAsync(LinuxPaths paths)
    {
        var response = await SendAsync(paths, new AdminRequest
        {
            AdminApiVersion = 1,
            RequestID = Guid.NewGuid(),
            Operation = "status.get",
            ExpectedDeviceID = null,
            OperationID = null,
            Payload = JsonDocument.Parse("{}").RootElement.Clone(),
        }, TimeSpan.FromSeconds(2));
        if (response is not { Ok: true } || response.Result is null) return null;
        return response.Result.Deserialize<LinuxStatus>(AdminJson.Options);
    }

    private static async Task<string?> SendLineAsync(
        LinuxPaths paths, string line, TimeSpan timeout)
    {
        using var cancellation = new CancellationTokenSource(timeout);
        try
        {
            using var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            await socket.ConnectAsync(
                new UnixDomainSocketEndPoint(paths.SocketPath), cancellation.Token);
            await using var stream = new NetworkStream(socket, ownsSocket: true);
            await stream.WriteAsync(Encoding.UTF8.GetBytes(line + "\n"), cancellation.Token);
            return await LinuxHost.ReadOneLineAsync(stream, 1024 * 1024, cancellation.Token);
        }
        catch { return null; }
    }
}
