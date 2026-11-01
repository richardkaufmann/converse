namespace Converse.Core;

// Called before loading sessions or connecting peers, after the instance lock.
public static class DemoReset
{
    public const string Marker = "reset-demo-request";
    private static void Validate(string folder, bool enabled)
    {
        var path = Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar);
        if (!enabled || Path.GetFileName(path) != "Converse Demo" ||
            (Directory.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0))
            throw new InvalidOperationException("Reset is only available for the separate Converse Demo profile.");
    }
    public static void Request(string folder, bool enabled)
    {
        Validate(folder, enabled);
        File.WriteAllText(Path.Combine(folder, Marker), "Reset Demo on next launch\n");
    }
    public static string? Consume(string folder, bool enabled, Action clearCredentials)
    {
        if (!enabled) return null;
        Validate(folder, enabled);
        if (!File.Exists(Path.Combine(folder, Marker))) return null;
        var backups = Path.Combine(Path.GetDirectoryName(folder)!, "Converse Demo Backups");
        Directory.CreateDirectory(backups);
        var backup = Path.Combine(backups, Guid.NewGuid().ToString());
        // No open writers: the prior instance finished shutdown before this launch.
        // If credential removal fails, retain the profile/request for retry.
        clearCredentials();
        Directory.Move(folder, backup);
        Directory.CreateDirectory(folder);
        return backup;
    }
}
