using Converse.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Converse.App;

// Sidebar outline: one header per home (This PC, each paired computer),
// sessions beneath their home, nothing else. Nearby undiscovered devices
// live only in the Connect dialog, never inline with conversations.
public abstract record SidebarItem(string Key);
public sealed record SidebarHeader(string Key, string Title, string Status) : SidebarItem(Key);
public sealed record SidebarSession(string Key, string Title, string Subtitle, string? GlobalID, Guid? LocalSessionID, bool ShowPark, bool ShowTake) : SidebarItem(Key);

public sealed class SidebarTemplateSelector : DataTemplateSelector
{
    public DataTemplate? HeaderTemplate { get; set; }
    public DataTemplate? SessionTemplate { get; set; }
    protected override DataTemplate SelectTemplateCore(object item) => item switch
    {
        SidebarHeader => HeaderTemplate ?? base.SelectTemplateCore(item),
        SidebarSession => SessionTemplate ?? base.SelectTemplateCore(item),
        _ => base.SelectTemplateCore(item),
    };
    protected override DataTemplate SelectTemplateCore(object item, DependencyObject container) => SelectTemplateCore(item);
}

public sealed partial class MainWindow : Window
{
    // RichEdit paragraph breaks are single \r in both directions.
    private static string Breaks(string text) => text.Replace("\r\n", "\r").Replace("\n", "\r");

    private readonly SessionStore _store;
    private readonly DeviceSyncService _devices;
    private readonly string _dataFolder;
    private readonly SidebarLayoutState _layout;
    private SidebarSession? _selected;
    private bool _draggingSplitter;
    private double _windowWidth = 1200;
    private bool _suppressSelection;

    // Editor state: protected history (plain text with \r breaks) plus an
    // editable blue draft tail. The document is rebuilt only when the history
    // actually changes, and caret position is preserved across rebuilds, so
    // streaming output cannot jerk the text the user is reading or typing.
    private string _historyText = "";
    private string _draftText = "";
    private string? _lastSentText;
    private bool _rebuilding;
    private string _sidebarSignature = "";
    private ScrollViewer? _transcriptScroller;
    private int _draftSeq;
    private DateTime _lastDraftFlush = DateTime.MinValue;

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
        RefreshSidebar();
        RenderPane();
    }

    private void RefreshSidebar()
    {
        var items = new List<SidebarItem>();
        items.Add(new SidebarHeader("local", "This PC", _store.Sessions.Count + " session(s)"));
        foreach (var session in _store.Sessions)
            items.Add(new SidebarSession("local:" + session.Id, (session.Busy ? "● " : "") + session.Title,
                session.Entry.Name + " · " + session.Status, null, session.Id, ShowPark: false, ShowTake: false));
        foreach (var home in _devices.Homes.Values.OrderBy(h => h.DeviceName))
        {
            items.Add(new SidebarHeader("home:" + home.DeviceID, home.DeviceName,
                home.Online ? home.Rows.Count + " session(s)" : "Offline"));
            if (home.Rows.Count == 0)
                items.Add(new SidebarSession("home:" + home.DeviceID + ":empty",
                    home.Online ? "No sessions available" : "Offline", "", null, null, ShowPark: false, ShowTake: false));
            foreach (var row in home.Rows)
                items.Add(new SidebarSession("remote:" + row.GlobalID, (row.Busy ? "● " : "") + row.Title,
                    (home.Online ? "" : "Offline · ") + row.Status, row.GlobalID, null, ShowPark: true, ShowTake: home.Online));
        }
        var signature = string.Join("\n", items.Select(i => i.Key + "|" + (i switch
        {
            SidebarHeader h => h.Title + "|" + h.Status,
            SidebarSession s => s.Title + "|" + s.Subtitle + "|" + s.ShowPark + "|" + s.ShowTake,
            _ => "",
        })));
        if (signature == _sidebarSignature) return;
        _sidebarSignature = signature;
        _suppressSelection = true;
        Sidebar.ItemsSource = items;
        if (_selected is not null)
            Sidebar.SelectedItem = items.OfType<SidebarSession>().FirstOrDefault(i => i.Key == _selected.Key);
        _suppressSelection = false;
    }

    // Builds the protected history text for the selected conversation, plus
    // the character ranges that render as italic user turns.
    private (string History, List<(int Start, int Length)> UserRuns) BuildHistory()
    {
        var runs = new List<(int Start, int Length)>();
        var text = new System.Text.StringBuilder();
        List<(string Role, string Text)>? lines = null;
        if (_selected?.LocalSessionID is { } localId)
            lines = _store.Sessions.FirstOrDefault(s => s.Id == localId)?.Messages
                .Where(m => m.Role is "user" or "assistant" && !string.IsNullOrEmpty(m.Text))
                .Select(m => (m.Role, m.Text)).ToList();
        else if (_selected?.GlobalID is { } globalId)
            lines = _devices.RemoteTranscripts.GetValueOrDefault(globalId)?.Messages
                .Where(m => m.Role is "user" or "assistant" && !string.IsNullOrEmpty(m.Text))
                .Select(m => (m.Role, m.Text)).ToList();
        if (lines is null) return ("", runs);
        const int cap = 200;
        if (lines.Count > cap)
        {
            text.Append("… earlier messages hidden …\r\r");
            lines = lines.Skip(lines.Count - cap).ToList();
        }
        foreach (var (role, body) in lines)
        {
            if (role == "user")
            {
                var label = "You: ";
                var start = text.Length;
                text.Append(label).Append(Breaks(body)).Append("\r\r");
                runs.Add((start, label.Length + Breaks(body).Length));
            }
            else
            {
                text.Append(Breaks(body)).Append("\r\r");
            }
        }
        return (text.ToString(), runs);
    }

    private void RenderPane()
    {
        if (_selected is null)
        {
            PaneTitle.Text = "No conversation selected";
            PaneSubtitle.Text = "";
            Transcript.IsEnabled = false;
            if (_historyText != "" || _draftText != "") { _historyText = ""; _draftText = ""; RebuildDocument(caretToEnd: true); }
            return;
        }
        Transcript.IsEnabled = true;
        PaneTitle.Text = _selected.Title;
        PaneSubtitle.Text = _selected.Subtitle;
        // Adopt the home draft only into an untouched tail; never over typing.
        var homeDraft = _selected.LocalSessionID is { } localId
            ? _store.Sessions.FirstOrDefault(s => s.Id == localId)?.Draft ?? ""
            : _devices.RemoteTranscripts.GetValueOrDefault(_selected.GlobalID ?? "")?.Draft ?? "";
        if (_draftText == "" && homeDraft != "" && homeDraft != _lastSentText) _draftText = homeDraft;
        // A remote draft clears only after its exact sent text is acknowledged.
        if (_selected.GlobalID is not null && _lastSentText is not null && homeDraft == "" && _draftText == _lastSentText)
        {
            _draftText = "";
            _lastSentText = null;
        }
        var (history, _) = BuildHistory();
        if (history != _historyText)
        {
            var oldHistoryLength = _historyText.Length;
            _historyText = history;
            RebuildDocument(caretToEnd: false, oldHistoryLength: oldHistoryLength);
        }
    }

    private void RebuildDocument(bool caretToEnd, int? oldHistoryLength = null)
    {
        _rebuilding = true;
        try
        {
            var oldHistory = oldHistoryLength ?? _historyText.Length;
            var selection = Transcript.Document.Selection;
            var wasAtEnd = selection.StartPosition >= CurrentDocLength() && selection.EndPosition >= CurrentDocLength();
            var draftRelative = selection.StartPosition >= oldHistory ? selection.StartPosition - oldHistory : (int?)null;
            var draftLength = selection.EndPosition > selection.StartPosition
                ? Math.Min(selection.Length, Math.Max(0, _draftText.Length - (draftRelative ?? 0))) : 0;

            Transcript.Document.SetText(TextSetOptions.None, _historyText + _draftText);
            var (_, runs) = BuildHistory();
            foreach (var (start, length) in runs)
            {
                var range = Transcript.Document.GetRange(start, start + length);
                range.CharacterFormat.Italic = FormatEffect.On;
            }
            if (_draftText.Length > 0)
            {
                var draft = Transcript.Document.GetRange(_historyText.Length, _historyText.Length + _draftText.Length);
                draft.CharacterFormat.ForegroundColor = Microsoft.UI.Colors.Blue;
            }

            int position, length;
            if (caretToEnd || wasAtEnd)
            {
                position = _historyText.Length + _draftText.Length;
                length = 0;
            }
            else if (draftRelative is { } relative)
            {
                position = Math.Min(_historyText.Length + _draftText.Length, _historyText.Length + relative);
                length = Math.Min(draftLength, _historyText.Length + _draftText.Length - position);
            }
            else
            {
                var shift = _historyText.Length - oldHistory;
                position = Math.Max(0, Math.Min(_historyText.Length + _draftText.Length, selection.StartPosition + shift));
                length = Math.Min(selection.Length, _historyText.Length + _draftText.Length - position);
            }
            Transcript.Document.Selection.SetRange(position, position + length);
            if (caretToEnd || wasAtEnd) ScrollTranscriptToEnd();
        }
        finally { _rebuilding = false; }
    }

    private int CurrentDocLength()
    {
        Transcript.Document.GetText(TextGetOptions.None, out var text);
        return text.Length;
    }

    private ScrollViewer? TranscriptScroller()
    {
        if (_transcriptScroller is not null) return _transcriptScroller;
        var queue = new Queue<DependencyObject>();
        queue.Enqueue(Transcript);
        while (queue.Count > 0)
        {
            var current = queue.Dequeue();
            if (current is ScrollViewer found) return _transcriptScroller = found;
            var count = VisualTreeHelper.GetChildrenCount(current);
            for (var i = 0; i < count; i++) queue.Enqueue(VisualTreeHelper.GetChild(current, i));
        }
        return null;
    }

    private void ScrollTranscriptToEnd()
    {
        var scroller = TranscriptScroller();
        scroller?.ChangeView(null, scroller.ScrollableHeight, null);
    }

    private void OnTranscriptTextChanged(object sender, RoutedEventArgs e)
    {
        if (_rebuilding || _selected is null) return;
        Transcript.Document.GetText(TextGetOptions.None, out var full);
        full = full.Replace("\r\n", "\r");
        if (!full.StartsWith(_historyText, StringComparison.Ordinal))
        {
            // Edit touched protected history: revert and park the caret at the end.
            RebuildDocument(caretToEnd: true);
            return;
        }
        var draft = full.Substring(_historyText.Length);
        if (draft == _draftText) return;
        _draftText = draft;
        // The tail the user just typed is always blue.
        var range = Transcript.Document.GetRange(_historyText.Length, _historyText.Length + _draftText.Length);
        range.CharacterFormat.ForegroundColor = Microsoft.UI.Colors.Blue;
        ScheduleDraftFlush();
    }

    private void ScheduleDraftFlush()
    {
        var selected = _selected;
        if (selected is null) return;
        var seq = ++_draftSeq;
        var text = _draftText.Replace("\r", "\n");
        var now = DateTime.UtcNow;
        if ((now - _lastDraftFlush).TotalMilliseconds >= 300)
        {
            _lastDraftFlush = now;
            FlushDraft(selected, text);
            return;
        }
        _ = Task.Run(async () =>
        {
            await Task.Delay(300);
            if (seq != _draftSeq) return;
            _lastDraftFlush = DateTime.UtcNow;
            FlushDraft(selected, text);
        });
    }

    private void FlushDraft(SidebarSession selected, string text)
    {
        if (selected.LocalSessionID is { } localId)
        {
            var session = _store.Sessions.FirstOrDefault(s => s.Id == localId);
            if (session is null) return;
            session.Draft = text;
            _store.Save();
        }
        else if (selected.GlobalID is { } globalId)
        {
            _ = _devices.SendRemoteDraftAsync(globalId, text);
        }
    }

    private void SelectSession(SidebarSession? session, bool caretToEnd)
    {
        _selected = session;
        _historyText = "";
        _draftText = "";
        _lastSentText = null;
        if (session?.LocalSessionID is { } localId)
            _draftText = _store.Sessions.FirstOrDefault(s => s.Id == localId)?.Draft ?? "";
        else if (session?.GlobalID is { } globalId)
            _draftText = _devices.RemoteTranscripts.GetValueOrDefault(globalId)?.Draft ?? "";
        RenderPane();
        if (caretToEnd) { RebuildDocument(caretToEnd: true); Transcript.Focus(FocusState.Programmatic); }
    }

    private void OnSidebarSelection(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelection) return;
        var item = Sidebar.SelectedItem as SidebarItem;
        if (item is SidebarHeader)
        {
            _suppressSelection = true;
            Sidebar.SelectedItem = _selected is not null
                ? Sidebar.Items.OfType<SidebarSession>().FirstOrDefault(i => i.Key == _selected.Key)
                : null;
            _suppressSelection = false;
            return;
        }
        if (item is not SidebarSession session || (session.GlobalID is null && session.LocalSessionID is null))
        {
            SelectSession(null, caretToEnd: false);
            return;
        }
        if (_selected?.Key != session.Key) SelectSession(session, caretToEnd: true);
    }

    private void OnNewSessionClick(object sender, RoutedEventArgs e)
    {
        var entry = _store.Entries.FirstOrDefault();
        if (entry is null) return;
        var session = _store.Create(entry);
        var key = "local:" + session.Id;
        RefreshSidebar();
        SelectSession(new SidebarSession(key, session.Title, "", null, session.Id, ShowPark: false, ShowTake: false), caretToEnd: true);
        Transcript.Focus(FocusState.Programmatic);
    }

    private async void OnConnectClick(object sender, RoutedEventArgs e)
    {
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(new TextBlock { Text = "Nearby Converses (pairing asks both sides to compare all 8 code groups):" });
        (string Host, int Port)? chosen = null;
        ContentDialog? dialog = null;
        foreach (var found in _devices.DiscoveredDevices)
        {
            var host = found.Host;
            var port = found.Port;
            var button = new Button
            {
                Content = found.Name + " · " + host + ":" + port,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            button.Click += (_, _) => { chosen = (host, port); dialog?.Hide(); };
            panel.Children.Add(button);
        }
        if (_devices.DiscoveredDevices.Count == 0)
            panel.Children.Add(new TextBlock { Text = "Nothing discovered yet. Check Wi-Fi and the firewall, or connect by address." });
        panel.Children.Add(new TextBlock { Text = "Connect by address:" });
        var hostBox = new TextBox { PlaceholderText = "Host or IP" };
        var portBox = new TextBox { Text = DeviceSyncService.DefaultPort.ToString() };
        panel.Children.Add(hostBox);
        panel.Children.Add(portBox);
        dialog = new ContentDialog
        {
            Title = "Connect to Other Converses",
            Content = new ScrollViewer { Content = panel },
            PrimaryButtonText = "Connect",
            CloseButtonText = "Cancel",
            XamlRoot = Content.XamlRoot,
        };
        var result = await dialog.ShowAsync();
        if (chosen is { } nearby)
        {
            await _devices.ConnectManualAsync(nearby.Host, nearby.Port);
            return;
        }
        if (result == ContentDialogResult.Primary && int.TryParse(portBox.Text, out var parsed))
            await _devices.ConnectManualAsync(hostBox.Text.Trim(), parsed);
    }

    private async void OnTakeClick(object sender, RoutedEventArgs e)
    {
        var button = sender as Button;
        if (button?.Tag is not SidebarSession row || row.GlobalID is null) return;
        SelectSession(row, caretToEnd: true);
        await _devices.AcquireRemoteAsync(row.GlobalID);
        Refresh();
    }

    private void OnTranscriptKeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
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
        if (sender is not Button { Tag: SidebarSession row } || row.GlobalID is null) return;
        await _devices.ReleaseRemoteAsync(row.GlobalID);
        if (_selected?.GlobalID == row.GlobalID) SelectSession(null, caretToEnd: false);
        Refresh();
    }

    private async void OnSendClick(object sender, RoutedEventArgs e)
    {
        var text = _draftText.Replace("\r", "\n");
        if (string.IsNullOrWhiteSpace(text) || _selected is null) return;
        if (_selected.LocalSessionID is { } localId)
        {
            var session = _store.Sessions.FirstOrDefault(s => s.Id == localId);
            if (session is null) return;
            session.Draft = text;
            _draftText = "";
            _store.Submit(session);
        }
        else if (_selected.GlobalID is { } globalId)
        {
            // Draft stays until home ack completes (outbox in core service).
            _lastSentText = text;
            await _devices.SendRemoteCommandAsync(globalId,
                new DeviceCommandPayload { Action = "submit", Text = text });
        }
        Refresh();
        Transcript.Focus(FocusState.Programmatic);
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
