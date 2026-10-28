using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Converse.App;

public partial class App : Application
{
    private Window? _window;
    public App() => InitializeComponent();

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
        _window = new MainWindow();
        _window.Activate();
    }
}
