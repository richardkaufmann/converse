using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Converse.App;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
        // WinUI surfaces startup failures as a bare stowed exception (0xc000027b)
        // with no message; keep the real one where a user can find it.
        UnhandledException += (_, e) => WriteCrashLog(e.Exception);
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Single instance: two writers on one sessions.json lose data. A second
        // launch redirects to the running copy instead of opening its own window.
        var instance = AppInstance.FindOrRegisterForKey("ConverseMain");
        if (!instance.IsCurrent)
        {
            var activated = AppInstance.GetCurrent()?.GetActivatedEventArgs();
            if (activated is not null) await instance.RedirectActivationToAsync(activated);
            System.Diagnostics.Process.GetCurrentProcess().Kill();
            return;
        }
        instance.Activated += (_, _) =>
            _window?.DispatcherQueue.TryEnqueue(() => _window.Activate());
        try
        {
            _window = new MainWindow();
            _window.Activate();
        }
        catch (Exception ex)
        {
            WriteCrashLog(ex);
            throw;
        }
    }

    private static void WriteCrashLog(Exception ex)
    {
        try
        {
            var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Converse");
            Directory.CreateDirectory(folder);
            File.AppendAllText(Path.Combine(folder, "crash.log"), $"{DateTime.Now:O}\n{ex}\n\n");
        }
        catch (IOException) { }
    }
}
