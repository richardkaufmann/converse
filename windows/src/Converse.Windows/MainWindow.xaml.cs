using Converse.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Converse.App;

public sealed record SidebarRowItem(string Title, string Subtitle, string? GlobalID, Guid? LocalSessionID);

public sealed partial class MainWindow : Window
{
    private readonly SessionStore _store;
    private readonly DeviceSyncService _devices;
    private readonly string _dataFolder;
    private readonly SidebarLayoutState _layout;
    private SidebarRowItem? _selected;
    private bool _draggingSplitter;
    private double _windowWidth = 1200;

    public MainWindow()
    {
        InitializeComponent();
        Title = "Converse";
        var folder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Converse");
        _dataFolder = folder;
        _layout = SidebarLayoutState.Load(folder);
        _store = new SessionStore(folder);
        _devices = new DeviceSyncService(folder, _store);
        _devices.PairingConfirmation = ShowPairingPromptAsync;
        _store.Changed += Refresh;
        _devices.Changed += Refresh;
        _ = _devices.StartAsync();
        ApplyLayout();
        Refresh();
    }

    // Sidebar pin (shared contract): collapse/restore is layout only. It never
    // parks a session, releases a lease, or touches the device service.
    private void ApplyLayout()
    {
        var width = _layout.EffectiveWidth(_windowWidth);
        SidebarColumn.Width = new GridLength(width);
        SplitterColumn.Width = new GridLength(_layout.Collapsed ? 0 : 4);
        SidebarPanel.Visibility = _layout.Collapsed ? Visibility.Collapsed : Visibility.Visible;
        Splitter.Visibility = _layout.Collapsed ? Visibility.Collapsed : Visibility.Visible;
        RestorePin.Visibility = _layout.Collapsed ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnPinClick(object sender, RoutedEventArgs e)
    {
        _layout.Toggle();
        _layout.Save(_dataFolder);
        ApplyLayout();
    }

    private void OnRootSizeChanged(object sender, SizeChangedEventArgs e)
    {
        _windowWidth = e.NewSize.Width;
        if (!_layout.Collapsed && !_draggingSplitter) ApplyLayout();
    }

    private void OnSplitterPressed(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        _draggingSplitter = true;
        Splitter.CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnSplitterMoved(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (!_draggingSplitter || Content is not FrameworkElement root) return;
        var x = e.GetCurrentPoint(root).Position.X;
        SidebarColumn.Width = new GridLength(SidebarLayoutState.ClampWidth(x, _windowWidth));
    }

    private void OnSplitterReleased(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (!_draggingSplitter) return;
        _draggingSplitter = false;
        Splitter.ReleasePointerCapture(e.Pointer);
        _layout.RecordUserWidth(SidebarColumn.Width.Value, _windowWidth);
        _layout.Save(_dataFolder);
        ApplyLayout();
    }

    // Converse > Setup (moved out of Help on every platform): assistants,
    // CLI presence, and the data folder. Help is searchable documentation only.
    private async void OnSetupClick(object sender, RoutedEventArgs e)
    {
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(new TextBlock
        {
            Text = "Converse runs the Muse, Claude Code, and Codex CLIs installed on this PC. "
                 + "Install and sign in to each CLI separately; credentials stay in the CLI stores. "
                 + "Creating a session sends no prompt.",
            TextWrapping = TextWrapping.Wrap,
        });
        foreach (var entry in _store.Entries)
        {
            var found = FindOnPath(entry.Command);
            panel.Children.Add(new TextBlock
            {
                Text = $"{entry.Name} — command “{entry.Command}” · folder {entry.Directory} · "
                     + (found is null ? "CLI not found on PATH" : "CLI available: " + found),
                TextWrapping = TextWrapping.Wrap,
            });
        }
        panel.Children.Add(new TextBlock
        {
            Text = "Conversations, drafts, and device pairing state live in " + _dataFolder + ". "
                 + "Use New session to start, and Help > Converse Help for searchable documentation.",
            TextWrapping = TextWrapping.Wrap,
        });
        var dialog = new ContentDialog
        {
            Title = "Setup",
            Content = new ScrollViewer { Content = panel },
            CloseButtonText = "Done",
            XamlRoot = Content.XamlRoot,
        };
        await dialog.ShowAsync();
    }

    private static string? FindOnPath(string command)
    {
        if (string.IsNullOrWhiteSpace(command)) return null;
        if (File.Exists(command)) return command;
        var extensions = new[] { "", ".exe", ".cmd", ".bat" };
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            foreach (var ext in extensions)
            {
                var candidate = Path.Combine(dir.Trim(), command + ext);
                if (File.Exists(candidate)) return candidate;
            }
        return null;
    }

    // Help > Converse Help: offline, versioned artifact generated from the
    // tracked README by scripts/build-help.py (Assets/help.json). Search is a
    // case-insensitive substring over topic titles and plain text.
    private async void OnHelpClick(object sender, RoutedEventArgs e)
    {
        var help = HelpDocument.TryLoadFile(Path.Combine(AppContext.BaseDirectory, "Assets", "help.json"))
                   ?? HelpDocument.TryLoadFile(Path.Combine(AppContext.BaseDirectory, "Assets", "Content.json"))
                   ?? HelpDocument.TryLoadFile(Path.Combine(AppContext.BaseDirectory, "help.json"))
                   ?? HelpDocument.TryLoadFile(Path.Combine(AppContext.BaseDirectory, "Content.json"));
        var search = new TextBox { PlaceholderText = "Search help…" };
        var topics = new ListView { SelectionMode = ListViewSelectionMode.Single, Height = 140 };
        var body = new TextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        var version = new TextBlock
        {
            Text = help is null
                ? "Help content is generated at build time from README.md (scripts/build-help.py); this build does not include it yet."
                : $"Converse Help · version {help.AppVersion}" + (help.AppBuild.Length > 0 ? $" ({help.AppBuild})" : "")
                  + $" · source {help.Source} @{help.SourceCommit}",
            TextWrapping = TextWrapping.Wrap,
        };
        void ShowTopic(HelpTopic? topic) => body.Text = topic is null ? "" : RenderMarkdownPlain(topic.Markdown);
        void Refill()
        {
            var results = help?.Search(search.Text) ?? Array.Empty<HelpTopic>();
            topics.ItemsSource = results.Select(t => t.Title).ToList();
            ShowTopic(results.FirstOrDefault());
        }
        search.TextChanged += (_, _) => Refill();
        topics.SelectionChanged += (_, _) =>
        {
            var results = help?.Search(search.Text) ?? Array.Empty<HelpTopic>();
            if (topics.SelectedIndex >= 0 && topics.SelectedIndex < results.Count) ShowTopic(results[topics.SelectedIndex]);
        };
        Refill();
        var panel = new StackPanel { Spacing = 8, Width = 640 };
        panel.Children.Add(version);
        panel.Children.Add(search);
        panel.Children.Add(topics);
        panel.Children.Add(new ScrollViewer { Content = body, Height = 320 });
        var dialog = new ContentDialog
        {
            Title = "Converse Help",
            Content = panel,
            CloseButtonText = "Close",
            XamlRoot = Content.XamlRoot,
        };
        await dialog.ShowAsync();
    }

    // Minimal native rendering adapter for the shared markdown subset:
    // keep paragraph structure, drop emphasis/code markers, links become labels.
    private static string RenderMarkdownPlain(string markdown)
    {
        var text = System.Text.RegularExpressions.Regex.Replace(markdown, @"\[([^\]]+)\]\([^)]*\)", "$1");
        text = System.Text.RegularExpressions.Regex.Replace(text, @"!\[[^\]]*\]\([^)]*\)", "");
        text = System.Text.RegularExpressions.Regex.Replace(text, @"^#{1,6}\s*", "",
            System.Text.RegularExpressions.RegexOptions.Multiline);
        return text.Replace("**", "").Replace("`", "").Trim();
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
