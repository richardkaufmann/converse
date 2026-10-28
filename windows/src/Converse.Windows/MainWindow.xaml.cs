using Converse.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Converse.App;

public sealed record SidebarRowItem(string Title, string Subtitle, string? GlobalID, Guid? LocalSessionID);

public sealed partial class MainWindow : Window
{
    private readonly SessionStore _store;
    private readonly DeviceSyncService _devices;
    private SidebarRowItem? _selected;

    public MainWindow()
    {
        InitializeComponent();
        Title = "Converse";
        var folder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Converse");
        _store = new SessionStore(folder);
        _devices = new DeviceSyncService(folder, _store);
        _devices.PairingConfirmation = ShowPairingPromptAsync;
        _store.Changed += Refresh;
        _devices.Changed += Refresh;
        _ = _devices.StartAsync();
        Refresh();
    }

    private async Task<bool> ShowPairingPromptAsync(PairingPrompt prompt)
    {
        var accepted = false;
        var done = new TaskCompletionSource<bool>();
        DispatcherQueue.TryEnqueue(async () =>
        {
            var dialog = new ContentDialog
            {
                Title = "Pair with " + prompt.PeerName + "?",
                Content = "Compare EVERY group on both devices. Pair only if all 8 groups match exactly:\n\n"
                          + prompt.Code + "\n\nFingerprint " + prompt.Fingerprint
                          + (prompt.KeyChanged ? "\n\nWarning: stored key mismatch." : "")
                          + "\n\nPairing allows remote prompts and tool execution on the home device.",
                PrimaryButtonText = prompt.IsInitiator ? "Pair" : "Approve",
                CloseButtonText = "Reject",
                XamlRoot = Content.XamlRoot,
            };
            accepted = await dialog.ShowAsync() == ContentDialogResult.Primary;
            done.TrySetResult(accepted);
        });
        return await done.Task;
    }

    private void Refresh()
    {
        if (!DispatcherQueue.HasThreadAccess)
        {
            DispatcherQueue.TryEnqueue(Refresh);
            return;
        }
        var rows = new List<SidebarRowItem>();
        foreach (var session in _store.Sessions)
            rows.Add(new SidebarRowItem((session.Busy ? "● " : "") + session.Title, session.Entry.Name + " · this PC · " + session.Status, null, session.Id));
        foreach (var home in _devices.Homes.Values.OrderBy(h => h.DeviceName))
        {
            if (home.Rows.Count == 0)
                rows.Add(new SidebarRowItem(home.DeviceName, home.Online ? "No sessions available" : "Offline", null, null));
            foreach (var row in home.Rows)
                rows.Add(new SidebarRowItem((row.Busy ? "● " : "") + row.Title, home.DeviceName + (home.Online ? " · home" : " · offline") + " · " + row.Status, row.GlobalID, null));
        }
        foreach (var found in _devices.DiscoveredDevices)
            rows.Add(new SidebarRowItem(found.Name, "Nearby · " + found.Host + ":" + found.Port, "discover:" + found.Host + ":" + found.Port, null));
        Sidebar.ItemsSource = rows;
        RenderPane();
    }

    private void RenderPane()
    {
        if (_selected is null)
        {
            PaneTitle.Text = "No conversation selected";
            Messages.ItemsSource = Array.Empty<string>();
            return;
        }
        PaneTitle.Text = _selected.Title;
        if (_selected.LocalSessionID is { } localId)
        {
            var session = _store.Sessions.FirstOrDefault(s => s.Id == localId);
            Messages.ItemsSource = session?.Messages
                .Where(m => m.Role is "user" or "assistant" && !string.IsNullOrEmpty(m.Text))
                .Select(m => (m.Role == "user" ? "You: " : "") + m.Text).ToList() ?? new List<string>();
        }
        else if (_selected.GlobalID is { } globalId)
        {
            var transcript = _devices.RemoteTranscripts.GetValueOrDefault(globalId);
            Messages.ItemsSource = transcript?.Messages
                .Where(m => m.Role is "user" or "assistant" && !string.IsNullOrEmpty(m.Text))
                .Select(m => (m.Role == "user" ? "You: " : "") + m.Text).ToList() ?? new List<string> { "Take this session to load its transcript." };
            if (transcript is not null && Composer.Text.Length == 0) Composer.Text = transcript.Draft;
        }
    }

    private void OnSidebarSelection(object sender, SelectionChangedEventArgs e)
    {
        _selected = Sidebar.SelectedItem as SidebarRowItem;
        RenderPane();
    }

    private void OnNewSessionClick(object sender, RoutedEventArgs e)
    {
        var entry = _store.Entries.FirstOrDefault();
        if (entry is null) return;
        var session = _store.Create(entry);
        Refresh();
        _selected = new SidebarRowItem(session.Title, "", null, session.Id);
        RenderPane();
    }

    private async void OnConnectClick(object sender, RoutedEventArgs e)
    {
        var host = new TextBox { PlaceholderText = "Host or IP" };
        var port = new TextBox { Text = DeviceSyncService.DefaultPort.ToString() };
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(new TextBlock { Text = "Connect by address (Bonjour browser lands in a later milestone). Pairing and encryption are identical." });
        panel.Children.Add(host);
        panel.Children.Add(port);
        var dialog = new ContentDialog
        {
            Title = "Connect to Other Converses",
            Content = panel,
            PrimaryButtonText = "Connect",
            CloseButtonText = "Cancel",
            XamlRoot = Content.XamlRoot,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && int.TryParse(port.Text, out var parsed))
            await _devices.ConnectManualAsync(host.Text.Trim(), parsed);
    }

    private async void OnTakeClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SidebarRowItem row } || row.GlobalID is null) return;
        if (row.GlobalID.StartsWith("discover:"))
        {
            var parts = row.GlobalID["discover:".Length..].Split(':');
            if (parts.Length == 2 && int.TryParse(parts[1], out var port)) await _devices.ConnectManualAsync(parts[0], port);
            return;
        }
        _selected = row;
        await _devices.AcquireRemoteAsync(row.GlobalID);
        Refresh();
    }

    private void OnComposerKeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        // Mac parity: Return sends; Control+Return inserts a newline.
        if (e.Key != Windows.System.VirtualKey.Enter) return;
        var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (ctrl) return;
        e.Handled = true;
        OnSendClick(sender, e);
    }

    private async void OnParkClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SidebarRowItem row } || row.GlobalID is null) return;
        await _devices.ReleaseRemoteAsync(row.GlobalID);
        if (_selected?.GlobalID == row.GlobalID) _selected = null;
        Refresh();
    }

    private async void OnSendClick(object sender, RoutedEventArgs e)
    {
        var text = Composer.Text;
        if (string.IsNullOrWhiteSpace(text) || _selected is null) return;
        if (_selected.LocalSessionID is { } localId)
        {
            var session = _store.Sessions.FirstOrDefault(s => s.Id == localId);
            if (session is null) return;
            session.Draft = text;
            Composer.Text = "";
            _store.Submit(session);
        }
        else if (_selected.GlobalID is { } globalId)
        {
            // Draft stays until home ack completes (outbox in core service).
            await _devices.SendRemoteCommandAsync(globalId,
                new DeviceCommandPayload { Action = "submit", Text = text });
        }
        Refresh();
    }

    private async void OnStopClick(object sender, RoutedEventArgs e)
    {
        if (_selected?.LocalSessionID is { } localId)
        {
            var session = _store.Sessions.FirstOrDefault(s => s.Id == localId);
            if (session is not null) _store.Stop(session);
        }
        else if (_selected?.GlobalID is { } globalId)
        {
            await _devices.SendRemoteCommandAsync(globalId, new DeviceCommandPayload { Action = "stop" });
        }
    }
}
