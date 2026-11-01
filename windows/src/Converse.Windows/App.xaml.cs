using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using System.Threading;

namespace Converse.App;

public partial class App : Application
{
    private Window? _window;
    private Mutex? _singleInstance;

    public App()
    {
        SetupPreview.Initialize();
        InitializeComponent();
        // WinUI surfaces startup failures as a bare stowed exception (0xc000027b)
        // with no message; keep the real one where a user can find it.
        UnhandledException += (_, e) => WriteCrashLog(e.Exception);
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Single instance: two writers on one sessions.json lose data. A second
        // launch redirects to the running copy instead of opening its own window.
        // AppInstance alone is not enough: unpackaged exes at different paths
        // do not see each other's registration, so a held mutex backs it.
        // A dead previous owner counts as acquired (the OS hands us the lock).
        var instanceSuffix = SetupPreview.Demo ? "-Demo" : SetupPreview.Enabled ? "-SetupPreview" : "";
        var testFolder = Environment.GetEnvironmentVariable("CONVERSE_DATA_DIR");
        if (!SetupPreview.Enabled && Environment.GetEnvironmentVariable("CONVERSE_UI_TEST") == "1" &&
            !string.IsNullOrWhiteSpace(testFolder) && Path.IsPathFullyQualified(testFolder) &&
            Path.GetFullPath(testFolder).StartsWith(Path.GetTempPath(), StringComparison.OrdinalIgnoreCase))
            instanceSuffix = "-Test-" + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
                System.Text.Encoding.UTF8.GetBytes(Path.GetFullPath(testFolder).ToUpperInvariant())));
        bool owned = true;
        try { _singleInstance = new Mutex(true, "ConverseSingleInstance" + instanceSuffix, out owned); }
        catch (AbandonedMutexException) { owned = true; }
        catch { _singleInstance?.Dispose(); _singleInstance = null; }
        var instance = AppInstance.FindOrRegisterForKey("ConverseMain" + instanceSuffix);
        if (!instance.IsCurrent || !owned)
        {
            if (!instance.IsCurrent)
            {
                var activated = AppInstance.GetCurrent()?.GetActivatedEventArgs();
                if (activated is not null) await instance.RedirectActivationToAsync(activated);
            }
            _singleInstance?.Dispose();
            _singleInstance = null;
            System.Diagnostics.Process.GetCurrentProcess().Kill();
            return;
        }
        instance.Activated += (_, _) =>
            _window?.DispatcherQueue.TryEnqueue(() => _window.Activate());
        try
        {
            Converse.Core.DemoReset.Consume(SetupPreview.Folder, SetupPreview.Demo, () => {
                var vault = new Windows.Security.Credentials.PasswordVault();
                foreach (var credential in vault.RetrieveAll().Where(c => c.Resource == "Converse.Demo.Agent"))
                    vault.Remove(credential);
            });
            _window = new MainWindow();
            _window.Activate();
            if (instanceSuffix.Length > 0 && Environment.GetEnvironmentVariable("CONVERSE_UI_CHECK") == "pane-reset")
            {
                try {
                    await ((MainWindow)_window).RunPaneResetCheckAsync();
                    File.WriteAllText(Path.Combine(testFolder!, "pane-reset-result.txt"), "PASS: nonempty to empty to nonempty, delayed refresh, return, and unassigned pane");
                } catch (Exception ex) {
                    File.WriteAllText(Path.Combine(testFolder!, "pane-reset-result.txt"), "FAIL: " + ex.Message);
                }
                _window.Close();
            }
        }
        catch (Exception ex)
        {
            // A constructor failure must never leave a headless process
            // holding the mutex (later launches would redirect to it and
            // die): release the lock and exit instead of re-throwing into
            // WinUI's stowed exception, which keeps the process alive.
            WriteCrashLog(ex);
            _singleInstance?.Dispose();
            _singleInstance = null;
            System.Diagnostics.Process.GetCurrentProcess().Kill();
        }
    }

    private static void WriteCrashLog(Exception ex)
    {
        try
        {
            var folder = SetupPreview.Enabled ? SetupPreview.Folder : Environment.GetEnvironmentVariable("CONVERSE_DATA_DIR") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Converse");
            Directory.CreateDirectory(folder);
            File.AppendAllText(Path.Combine(folder, "crash.log"), $"{DateTime.Now:O}\n{ex}\n\n");
        }
        catch (IOException) { }
    }
}
