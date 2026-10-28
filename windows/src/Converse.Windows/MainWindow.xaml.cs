using Converse.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using System.Text.Json.Nodes;
using WinRT.Interop;

namespace Converse.App;

// Sidebar outline: one header per home (This PC, each paired computer),
// sessions beneath their home, nothing else. Nearby undiscovered devices
// live only in the Connect dialog, never inline with conversations.
public abstract record SidebarItem(string Key);
public sealed record SidebarHeader(string Key, string Title, string Status) : SidebarItem(Key);
public sealed record SidebarSession(string Key, string Title, string Subtitle, string? GlobalID, Guid? LocalSessionID, bool ShowPark, bool ShowTake, bool ShowClose) : SidebarItem(Key);

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

// Per-request answer state for approval questions (Mac RemoteComposer
// selections/answers): chosen option labels and free text per question id.
internal sealed class RequestAnswerState
{
    public Dictionary<string, HashSet<string>> Selections { get; } = new();
    public Dictionary<string, string> FreeText { get; } = new();
}

public sealed partial class MainWindow : Window
{
    // RichEdit paragraph breaks are single \r in both directions.
    private static string Breaks(string text) => text.Replace("\r\n", "\r").Replace("\n", "\r");
    private const string DefaultHint = "Type at the end in blue. Return sends or queues · Ctrl+Return for newline";

    private readonly SessionStore _store;
    private readonly DeviceSyncService _devices;
    private readonly string _dataFolder;
    private readonly SidebarLayoutState _layout;
    private readonly HelpDocument? _help;
    private SidebarSession? _selected;
    private bool _draggingSplitter;
    private double _windowWidth = 1200;
    private bool _suppressSelection;

    // Editor state: protected history (plain text with \r breaks) plus an
    // editable blue draft tail. The document is rebuilt only when the history
    // actually changes, and caret position is preserved across rebuilds, so
    // streaming output cannot jerk the text the user is reading or typing.
    // RichEdit does not round-trip trailing breaks exactly, so every split
    // goes through EditorBoundary and every range is measured from the live
    // document, never assumed from the last SetText.
    private string _historyText = "";
    private string _draftText = "";
    private string? _lastSentText;
    private bool _rebuilding;
    private string _sidebarSignature = "";
    private string _bannerSignature = "";
    private bool _suppressSettings;
    private ScrollViewer? _transcriptScroller;
    private int _draftSeq;
    private DateTime _lastDraftFlush = DateTime.MinValue;
    private int _localCap = 200;
    private int _hiddenLocal;
    private string? _notice;
    private readonly Dictionary<string, RequestAnswerState> _answerStates = new();
    private readonly Dictionary<string, List<string>> _remoteHashes = new();

    public MainWindow()
    {
        InitializeComponent();
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
        _help = LoadHelp();
        Title = "Converse" + (_help is null ? " (dev)" : " " + _help.AppVersion
            + (_help.AppBuild.Length > 0 ? " (" + _help.AppBuild + ")" : ""));
        LineNumbersBox.IsChecked = _layout.ShowLineNumbers;
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

    private static HelpDocument? LoadHelp() =>
        HelpDocument.TryLoadFile(Path.Combine(AppContext.BaseDirectory, "Assets", "help.json"))
        ?? HelpDocument.TryLoadFile(Path.Combine(AppContext.BaseDirectory, "Assets", "Content.json"))
        ?? HelpDocument.TryLoadFile(Path.Combine(AppContext.BaseDirectory, "help.json"))
        ?? HelpDocument.TryLoadFile(Path.Combine(AppContext.BaseDirectory, "Content.json"));

    // Converse > Setup (moved out of Help on every platform): version first
    // so a screenshot always identifies the installed build, then assistants,
    // CLI presence, and the data folder. Help is searchable documentation only.
    private async void OnSetupClick(object sender, RoutedEventArgs e)
    {
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(new TextBlock
        {
            Text = _help is null
                ? "Converse (development build: no generated Help artifact bundled)."
                : $"Converse {_help.AppVersion}"
                  + (_help.AppBuild.Length > 0 ? $" ({_help.AppBuild})" : "")
                  + $" · source {_help.SourceCommit}",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
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

    // Setup detection shares the spawn resolver, so "CLI available" always means launchable.
    private static string? FindOnPath(string command) => CommandResolution.FindOnPath(command);

    // Help > Converse Help: offline, versioned artifact generated from the
    // tracked README by scripts/build-help.py (Assets/help.json). Search is a
    // case-insensitive substring over topic titles and plain text.
    private async void OnHelpClick(object sender, RoutedEventArgs e)
    {
        var help = _help;
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
            done.TrySetResult(await dialog.ShowAsync() == ContentDialogResult.Primary);
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
                session.Entry.Name + " · " + session.Status, null, session.Id, ShowPark: false, ShowTake: false, ShowClose: true));
        foreach (var home in _devices.Homes.Values.OrderBy(h => h.DeviceName))
        {
            items.Add(new SidebarHeader("home:" + home.DeviceID, home.DeviceName,
                home.Online ? home.Rows.Count + " session(s)" : "Offline"));
            if (home.Rows.Count == 0)
                items.Add(new SidebarSession("home:" + home.DeviceID + ":empty",
                    home.Online ? "No sessions available" : "Offline", "", null, null, ShowPark: false, ShowTake: false, ShowClose: false));
            foreach (var row in home.Rows)
                items.Add(new SidebarSession("remote:" + row.GlobalID, (row.Busy ? "● " : "") + row.Title,
                    (home.Online ? "" : "Offline · ") + row.Status, row.GlobalID, null, ShowPark: true, ShowTake: home.Online, ShowClose: false));
        }
        var signature = string.Join("\n", items.Select(i => i.Key + "|" + (i switch
        {
            SidebarHeader h => h.Title + "|" + h.Status,
            SidebarSession s => s.Title + "|" + s.Subtitle + "|" + s.ShowPark + "|" + s.ShowTake + "|" + s.ShowClose,
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

    // Builds the protected history text for the selected conversation, the
    // character ranges that render as italic user turns, and how many earlier
    // messages the local cap hides (remote paging comes from home instead).
    private (string History, List<(int Start, int Length)> UserRuns, int Hidden) BuildHistory()
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
        if (lines is null) return ("", runs, 0);
        var cap = _selected?.LocalSessionID is not null ? _localCap : lines.Count;
        var hidden = Math.Max(0, lines.Count - cap);
        if (hidden > 0)
        {
            text.Append("… earlier messages hidden …\r\r");
            lines = lines.Skip(hidden).ToList();
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
        return (text.ToString(), runs, hidden);
    }

    private void RenderPane()
    {
        if (_selected is null)
        {
            PaneTitle.Text = "No conversation selected";
            PaneSubtitle.Text = "";
            Transcript.IsEnabled = false;
            SendButton.IsEnabled = false;
            StopButton.IsEnabled = false;
            AttachButton.IsEnabled = false;
            SettingsRow.IsEnabled = false;
            TakeButton.Visibility = Visibility.Collapsed;
            BusyRing.IsActive = false;
            if (_historyText != "" || _draftText != "") { _historyText = ""; _draftText = ""; RebuildDocument(caretToEnd: true); }
            RenderBanners();
            UpdateEarlier();
            UpdateHint();
            return;
        }
        PaneTitle.Text = _selected.Title;
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
            _remoteHashes.Remove(_selected.GlobalID);
        }
        var (history, _, hidden) = BuildHistory();
        _hiddenLocal = _selected.LocalSessionID is not null ? hidden : 0;
        if (history != _historyText)
        {
            _historyText = history;
            RebuildDocument(caretToEnd: false);
        }
        UpdateGate();
        UpdateBusy();
        RenderBanners();
        UpdateEarlier();
        UpdateHint();
        RefreshSettings();
    }

    // Mac parity: remote input needs a live display lease on an online home.
    // Without one the editor locks and Take here is the way back in; local
    // sessions (busy or idle) always accept typing and queue while busy.
    private bool InputAllowed()
    {
        if (_selected?.LocalSessionID is not null) return true;
        if (_selected?.GlobalID is string gid)
            return _devices.RemoteLeases.ContainsKey(gid) && !_devices.RemoteOffline.Contains(gid);
        return false;
    }

    private void UpdateGate()
    {
        var allowed = _selected is not null && InputAllowed();
        Transcript.IsEnabled = allowed;
        SendButton.IsEnabled = allowed;
        StopButton.IsEnabled = allowed;
        AttachButton.IsEnabled = allowed;
        SettingsRow.IsEnabled = allowed;
        var showTake = _selected?.GlobalID is string gid
            && (!_devices.RemoteLeases.ContainsKey(gid) || _devices.RemoteOffline.Contains(gid));
        TakeButton.Visibility = showTake ? Visibility.Visible : Visibility.Collapsed;
        if (showTake && DeviceGlobalID.Parse(_selected!.GlobalID!) is { } parsed)
            TakeButton.IsEnabled = _devices.Homes.GetValueOrDefault(parsed.Home)?.Online == true;
    }

    private void UpdateBusy()
    {
        bool busy;
        var parts = new List<string> { _selected?.Subtitle ?? "" };
        if (_selected?.LocalSessionID is { } localId)
        {
            var session = _store.Sessions.FirstOrDefault(s => s.Id == localId);
            busy = session?.Busy == true;
            if (session is not null && session.Pending.Count > 0)
                parts.Add(session.Pending.Count + " queued" + (session.QueuePaused ? " (paused)" : ""));
        }
        else if (_selected?.GlobalID is { } globalId)
        {
            var transcript = _devices.RemoteTranscripts.GetValueOrDefault(globalId);
            busy = transcript?.Busy == true;
            if (transcript is not null)
            {
                if (!string.IsNullOrEmpty(transcript.AccountName)) parts.Add(transcript.AccountName);
                if (transcript.Pending.Count > 0)
                    parts.Add(transcript.Pending.Count + " queued" + (transcript.QueuePaused ? " (paused)" : ""));
            }
            if (_devices.RemoteOffline.Contains(globalId)) parts.Add("reconnect to resume");
        }
        else busy = false;
        BusyRing.IsActive = busy;
        PaneSubtitle.Text = string.Join(" · ", parts.Where(p => p.Length > 0));
    }

    private void UpdateHint()
    {
        if (_devices.LastOutcome.Length > 0) HintText.Text = _devices.LastOutcome;
        else if (_notice is not null) HintText.Text = _notice;
        else
        {
            var hint = DefaultHint;
            var attached = _selected?.LocalSessionID is { } localId
                ? _store.Sessions.FirstOrDefault(s => s.Id == localId)?.Attachments.Count ?? 0
                : _selected?.GlobalID is string gid ? _remoteHashes.GetValueOrDefault(gid)?.Count ?? 0 : 0;
            if (attached > 0) hint += $" · {attached} image(s) attached";
            HintText.Text = hint;
        }
        var hasImages = _selected?.LocalSessionID is { } lid
            ? _store.Sessions.FirstOrDefault(s => s.Id == lid)?.Attachments.Count > 0
            : _selected?.GlobalID is string g && _remoteHashes.GetValueOrDefault(g)?.Count > 0;
        ClearImagesButton.Visibility = hasImages ? Visibility.Visible : Visibility.Collapsed;
    }

    private sealed record SettingItem(string Id, string Label)
    {
        public override string ToString() => Label;
    }

    private const string CliDefault = "CLI default";

    // Bottom settings row: model (editable combo — new model IDs never need an
    // app update), effort, access. Remote sessions use the home's live option
    // lists when the snapshot carries them, else the static per-engine catalog.
    private void RefreshSettings()
    {
        if (_selected is null) return;
        string engine;
        string? model, effort, access;
        List<SettingItem> modelItems = new() { new SettingItem("", CliDefault) };
        List<SettingItem> effortItems = new() { new SettingItem("", CliDefault) };
        List<SettingItem> accessItems = new() { new SettingItem("", CliDefault) };
        if (_selected.LocalSessionID is { } localId)
        {
            var session = _store.Sessions.FirstOrDefault(s => s.Id == localId);
            if (session is null) return;
            engine = session.Entry.Engine;
            model = session.Choices.Model; effort = session.Choices.Effort; access = session.Choices.Access;
        }
        else if (_selected.GlobalID is { } globalId)
        {
            var transcript = _devices.RemoteTranscripts.GetValueOrDefault(globalId);
            if (transcript is null) return;
            engine = transcript.Engine;
            model = transcript.Model.Length > 0 ? transcript.Model : null;
            effort = transcript.Effort.Length > 0 ? transcript.Effort : null;
            access = transcript.Access.Length > 0 ? transcript.Access : null;
            foreach (var option in transcript.ModelOptions)
                modelItems.Add(new SettingItem(option.Id, option.Label.Length > 0 ? option.Label : option.Id));
            var liveEfforts = transcript.EffortOptions;
            var liveAccess = transcript.AccessOptions;
            if (liveEfforts.Length > 0)
                foreach (var id in liveEfforts) effortItems.Add(new SettingItem(id, id));
            else
                foreach (var id in ChoicesCatalog.EffortsFor(engine)) effortItems.Add(new SettingItem(id, id));
            if (liveAccess.Count > 0)
                foreach (var option in liveAccess) accessItems.Add(new SettingItem(option.Id, option.Label.Length > 0 ? option.Label : option.Id));
            else
                foreach (var option in ChoicesCatalog.AccessFor(engine)) accessItems.Add(new SettingItem(option.Id, option.Label));
        }
        else return;
        if (_selected.LocalSessionID is not null)
        {
            foreach (var option in ChoicesCatalog.ModelsFor(engine)) modelItems.Add(new SettingItem(option.Id, option.Label));
            foreach (var id in ChoicesCatalog.EffortsFor(engine)) effortItems.Add(new SettingItem(id, id));
            foreach (var option in ChoicesCatalog.AccessFor(engine)) accessItems.Add(new SettingItem(option.Id, option.Label));
        }
        if (model is not null && modelItems.All(i => i.Id != model)) modelItems.Add(new SettingItem(model, model));
        if (effort is not null && effortItems.All(i => i.Id != effort)) effortItems.Add(new SettingItem(effort, effort));
        if (access is not null && accessItems.All(i => i.Id != access)) accessItems.Add(new SettingItem(access, access));
        _suppressSettings = true;
        try
        {
            SyncCombo(ModelBox, modelItems, model ?? "");
            // Never overwrite a model ID the user is still typing: streaming
            // refreshes arrive while the box has focus.
            if (!ModelBox.IsDropDownOpen && ModelBox.FocusState == FocusState.Unfocused) ModelBox.Text = model ?? CliDefault;
            SyncCombo(EffortBox, effortItems, effort ?? "");
            SyncCombo(AccessBox, accessItems, access ?? "");
        }
        finally { _suppressSettings = false; }
    }

    private static void SyncCombo(ComboBox box, List<SettingItem> items, string currentId)
    {
        if (box.IsDropDownOpen) return;
        var existing = box.ItemsSource as List<SettingItem>;
        if (existing is null || !existing.Select(i => i.Id).SequenceEqual(items.Select(i => i.Id)))
            box.ItemsSource = items;
        var match = items.FirstOrDefault(i => i.Id == currentId) ?? items[0];
        if (!Equals(box.SelectedItem, match)) box.SelectedItem = match;
    }

    private void OnSettingChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSettings || _selected is null || sender is not ComboBox box) return;
        if (box == ModelBox)
        {
            if (box.SelectedItem is SettingItem picked) ApplySetting("model", picked.Id == "" ? null : picked.Id);
            return;
        }
        if (box.SelectedItem is SettingItem item)
            ApplySetting(box == EffortBox ? "effort" : "access", item.Id == "" ? null : item.Id);
    }

    private void OnModelCommitted(object sender, RoutedEventArgs e)
    {
        if (_suppressSettings || _selected is null) return;
        var text = ModelBox.Text.Trim();
        if (text == CliDefault) text = "";
        ApplySetting("model", text == "" ? null : text);
    }

    private void OnModelKeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; OnModelCommitted(sender, e); }
    }

    private void ApplySetting(string kind, string? value)
    {
        if (_selected?.LocalSessionID is { } localId)
        {
            var session = _store.Sessions.FirstOrDefault(s => s.Id == localId);
            if (session is null) return;
            if (kind == "model") session.Choices.Model = value;
            else if (kind == "effort") session.Choices.Effort = value;
            else session.Choices.Access = value;
            _store.Save();
        }
        else if (_selected?.GlobalID is { } globalId)
        {
            _ = _devices.SendRemoteCommandAsync(globalId, new DeviceCommandPayload
            {
                Action = kind,
                Model = kind == "model" ? value : null,
                Effort = kind == "effort" ? value : null,
                Access = kind == "access" ? value : null,
            });
        }
        Refresh();
    }

    private void RebuildDocument(bool caretToEnd)
    {
        _rebuilding = true;
        try
        {
            // Measure the live document before replacing it: the draft is
            // always the document tail, so the history region is whatever
            // precedes it, regardless of break normalization.
            var oldDocLength = CurrentDocLength();
            var oldHistoryLength = Math.Max(0, oldDocLength - _draftText.Length);
            var selection = Transcript.Document.Selection;
            var wasAtEnd = selection.StartPosition >= oldDocLength && selection.EndPosition >= oldDocLength;
            var draftRelative = selection.StartPosition >= oldHistoryLength ? selection.StartPosition - oldHistoryLength : (int?)null;
            var draftLength = selection.EndPosition > selection.StartPosition
                ? Math.Min(selection.Length, Math.Max(0, _draftText.Length - (draftRelative ?? 0))) : 0;

            Transcript.Document.SetText(TextSetOptions.None, _historyText + _draftText);
            var (_, runs, _) = BuildHistory();
            foreach (var (start, runLength) in runs)
            {
                var range = Transcript.Document.GetRange(start, start + runLength);
                range.CharacterFormat.Italic = FormatEffect.On;
            }
            if (_draftText.Length > 0)
            {
                // Tail-measured: the history region may read back shorter
                // than _historyText when trailing breaks collapse.
                var docLength = CurrentDocLength();
                var draft = Transcript.Document.GetRange(
                    Math.Max(0, docLength - _draftText.Length), docLength);
                draft.CharacterFormat.ForegroundColor = Microsoft.UI.Colors.Blue;
            }

            var newDocLength = CurrentDocLength();
            var newHistoryLength = Math.Max(0, newDocLength - _draftText.Length);
            int position, length;
            if (caretToEnd || wasAtEnd)
            {
                position = newDocLength;
                length = 0;
            }
            else if (draftRelative is { } relative)
            {
                position = Math.Min(newDocLength, newHistoryLength + relative);
                length = Math.Min(draftLength, newDocLength - position);
            }
            else
            {
                var shift = newHistoryLength - oldHistoryLength;
                position = Math.Max(0, Math.Min(newDocLength, selection.StartPosition + shift));
                length = Math.Min(selection.Length, newDocLength - position);
            }
            Transcript.Document.Selection.SetRange(position, position + length);
            if (caretToEnd || wasAtEnd) ScrollTranscriptToEnd();
            UpdateGutter();
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
            if (current is ScrollViewer found)
            {
                _transcriptScroller = found;
                found.ViewChanged += OnTranscriptViewChanged;
                return found;
            }
            var count = VisualTreeHelper.GetChildrenCount(current);
            for (var i = 0; i < count; i++) queue.Enqueue(VisualTreeHelper.GetChild(current, i));
        }
        return null;
    }

    private void OnTranscriptViewChanged(object? sender, ScrollViewerViewChangedEventArgs e)
    {
        if (sender is ScrollViewer scroller && _layout.ShowLineNumbers)
            GutterScroller.ChangeView(null, scroller.VerticalOffset, null, true);
    }

    private void ScrollTranscriptToEnd()
    {
        var scroller = TranscriptScroller();
        scroller?.ChangeView(null, scroller.ScrollableHeight, null);
    }

    // Line-number gutter: one number per paragraph, prompt paragraphs (user
    // turns plus the draft tail, like the Mac ruler) tinted steel blue.
    private void UpdateGutter()
    {
        var show = _layout.ShowLineNumbers && _selected is not null;
        GutterScroller.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (!show) return;
        var parts = (_historyText + _draftText).Split('\r');
        var count = parts.Length;
        if (count > 0 && parts[count - 1] == "") count--;
        count = Math.Max(1, count);
        var prompt = new HashSet<int>();
        var (_, runs, _) = BuildHistory();
        foreach (var (start, _) in runs)
        {
            var index = 0;
            for (var i = 0; i < start && i < _historyText.Length; i++)
                if (_historyText[i] == '\r') index++;
            prompt.Add(index);
        }
        var draftStart = _historyText.Count(c => c == '\r');
        for (var i = draftStart; i < count; i++) prompt.Add(i);
        LineGutter.Inlines.Clear();
        var normal = new SolidColorBrush(Microsoft.UI.Colors.Gray);
        var accent = new SolidColorBrush(Microsoft.UI.Colors.SteelBlue);
        for (var i = 0; i < count; i++)
            LineGutter.Inlines.Add(new Run
            {
                Text = (i + 1) + (i + 1 < count ? "\n" : ""),
                Foreground = prompt.Contains(i) ? accent : normal,
            });
    }

    private void OnLineNumbersToggled(object sender, RoutedEventArgs e)
    {
        _layout.ShowLineNumbers = LineNumbersBox.IsChecked == true;
        _layout.Save(_dataFolder);
        UpdateGutter();
    }

    private void OnTranscriptTextChanged(object sender, RoutedEventArgs e)
    {
        if (_rebuilding || _selected is null) return;
        Transcript.Document.GetText(TextGetOptions.None, out var full);
        full = full.Replace("\r\n", "\r");
        var (ok, draft) = EditorBoundary.Split(full, _historyText);
        if (!ok)
        {
            // Edit touched protected history: revert and park the caret at the end.
            RebuildDocument(caretToEnd: true);
            return;
        }
        if (draft == _draftText) return;
        _draftText = draft;
        // The tail the user just typed is always blue (tail-measured so
        // collapsed history breaks cannot shift the range off the draft).
        var docLength = CurrentDocLength();
        var range = Transcript.Document.GetRange(Math.Max(0, docLength - _draftText.Length), docLength);
        range.CharacterFormat.ForegroundColor = Microsoft.UI.Colors.Blue;
        UpdateGutter();
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
        _localCap = 200;
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

    private async void OnCloseClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SidebarSession row } || row.LocalSessionID is not { } localId) return;
        var session = _store.Sessions.FirstOrDefault(s => s.Id == localId);
        if (session is null) return;
        var dialog = new ContentDialog
        {
            Title = "Close session?",
            Content = "“" + session.Title + "” leaves the sidebar. Its CLI process stops.",
            PrimaryButtonText = "Close session",
            CloseButtonText = "Cancel",
            XamlRoot = Content.XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (_selected?.LocalSessionID == localId) SelectSession(null, caretToEnd: false);
        _store.DeleteSession(session);
        Refresh();
    }

    // ---- Banners above the editor (Mac parity): approvals/questions, queued
    // prompts, and outbox recovery. Rebuilt only when the content signature
    // changes, so typing in an answer box survives streaming refreshes.
    private void RenderBanners()
    {
        var liveKeys = new HashSet<string>();
        var signature = new System.Text.StringBuilder();
        signature.Append(_selected?.Key ?? "none");
        List<RequestView> requests = new();
        string scope = "";
        ChatSession? local = null;
        string? gid = null;
        if (_selected?.LocalSessionID is { } localId)
        {
            local = _store.Sessions.FirstOrDefault(s => s.Id == localId);
            scope = "local:" + localId;
            if (local is not null)
                requests = local.Requests.Select(RequestViews.FromLocal).ToList();
        }
        else if (_selected?.GlobalID is { } globalId)
        {
            gid = globalId;
            scope = "remote:" + globalId;
            var transcript = _devices.RemoteTranscripts.GetValueOrDefault(globalId);
            if (transcript is not null)
                requests = transcript.Requests.Select(RequestViews.FromRemote).ToList();
        }
        foreach (var request in requests)
        {
            liveKeys.Add(scope + ":" + request.Id);
            signature.Append($"|req:{request.Id}:{request.Kind}:{request.ToolName}:{request.Choices.Count}:{request.Questions.Count}");
        }
        List<(Guid Id, string Text)> pending = new();
        var paused = false;
        if (local is not null)
        {
            pending = local.Pending.Select(p => (p.Id, p.Text)).ToList();
            paused = local.QueuePaused;
        }
        else if (gid is not null && _devices.RemoteTranscripts.GetValueOrDefault(gid) is { } transcript)
        {
            pending = transcript.Pending.Select(p => (p.Id, p.Text)).ToList();
            paused = transcript.QueuePaused;
        }
        foreach (var (id, preview) in pending) signature.Append($"|q:{id}:{preview.Length}:{preview.GetHashCode()}");
        signature.Append("|paused:").Append(paused);
        var outbox = gid is null ? null : _devices.Unresolved(gid).FirstOrDefault();
        if (outbox is not null) signature.Append($"|out:{outbox.CommandID}:{outbox.Outcome}:{outbox.Detail}");
        signature.Append("|lease:").Append(gid is null || _devices.RemoteLeases.ContainsKey(gid));
        var text = signature.ToString();
        if (text == _bannerSignature) return;
        _bannerSignature = text;
        foreach (var stale in _answerStates.Keys.Where(k => !liveKeys.Contains(k)).ToList())
            _answerStates.Remove(stale);
        BannerStack.Children.Clear();
        foreach (var request in requests)
            BannerStack.Children.Add(BuildRequestPanel(request, local, gid, scope));
        if (pending.Count > 0 || paused)
            BannerStack.Children.Add(BuildPendingPanel(pending, paused, local, gid));
        if (outbox is not null && gid is not null)
            BannerStack.Children.Add(BuildOutboxPanel(outbox, gid));
        BannerScroller.Visibility = BannerStack.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private StackPanel BuildRequestPanel(RequestView view, ChatSession? local, string? gid, string scope)
    {
        var panel = new StackPanel { Spacing = 6 };
        var stateKey = scope + ":" + view.Id;
        if (!_answerStates.TryGetValue(stateKey, out var state))
        {
            state = new RequestAnswerState();
            _answerStates[stateKey] = state;
        }
        if (view.Kind == "approval")
        {
            var header = new TextBlock
            {
                Text = "PERMISSION REQUIRED — Review before continuing",
                FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                FontSize = 12,
                Padding = new Thickness(8, 4, 8, 4),
            };
            var banner = new Border
            {
                Background = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 255, 199, 44)),
                Child = header,
            };
            header.Foreground = new SolidColorBrush(Microsoft.UI.Colors.Black);
            panel.Children.Add(banner);
        }
        else
        {
            panel.Children.Add(new TextBlock { Text = "Home session has a question", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        }
        if (view.Kind == "approval")
        {
            if (view.ToolName is not null)
                panel.Children.Add(new TextBlock { Text = view.ToolName, FontWeight = Microsoft.UI.Text.FontWeights.Medium });
            if (view.RawArgs is not null)
                panel.Children.Add(new TextBlock
                {
                    Text = view.RawArgs,
                    FontFamily = new FontFamily("Consolas"),
                    IsTextSelectionEnabled = true,
                    TextWrapping = TextWrapping.Wrap,
                });
            foreach (var choice in view.Choices)
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                var choiceId = choice.Id;
                var button = new Button { Content = choice.Label };
                button.Click += async (_, _) => await AnswerChoiceAsync(view, choiceId, local, gid);
                row.Children.Add(button);
                if (choice.Detail is not null)
                    row.Children.Add(new TextBlock
                    {
                        Text = choice.Detail,
                        FontSize = 12,
                        VerticalAlignment = VerticalAlignment.Center,
                        Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray),
                    });
                panel.Children.Add(row);
            }
            if (view.Choices.Count == 0)
                panel.Children.Add(new TextBlock
                {
                    Text = "No decision choices received yet.",
                    Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray),
                });
        }
        else
        {
            foreach (var question in view.Questions)
            {
                panel.Children.Add(new TextBlock { Text = question.Text, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap });
                foreach (var option in question.Options)
                {
                    var label = option.Label;
                    var selected = state.Selections.TryGetValue(question.Id, out var set) && set.Contains(label);
                    var toggle = new Button { Content = (selected ? "✓ " : "○ ") + label };
                    toggle.Click += (_, _) =>
                    {
                        if (!state.Selections.TryGetValue(question.Id, out var chosen))
                        {
                            chosen = new HashSet<string>();
                            state.Selections[question.Id] = chosen;
                        }
                        if (question.Multiple)
                        {
                            if (!chosen.Add(label)) chosen.Remove(label);
                        }
                        else
                        {
                            chosen.Clear();
                            chosen.Add(label);
                        }
                        // Refresh just this button's mark; the banner keeps focus elsewhere.
                        toggle.Content = (chosen.Contains(label) ? "✓ " : "○ ") + label;
                    };
                    panel.Children.Add(toggle);
                    if (option.Description is not null)
                        panel.Children.Add(new TextBlock
                        {
                            Text = option.Description,
                            FontSize = 12,
                            Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray),
                        });
                }
                var qid = question.Id;
                var answer = new TextBox
                {
                    PlaceholderText = question.Options.Count == 0 ? "Your answer" : "Or type your own",
                    Text = state.FreeText.GetValueOrDefault(qid, ""),
                    AcceptsReturn = true,
                    TextWrapping = TextWrapping.Wrap,
                };
                answer.TextChanged += (_, _) => state.FreeText[qid] = answer.Text;
                panel.Children.Add(answer);
            }
            var send = new Button { Content = "Send answer" };
            send.Click += async (_, _) => await AnswerQuestionsAsync(view, state, local, gid);
            panel.Children.Add(send);
        }
        return panel;
    }

    private async Task AnswerChoiceAsync(RequestView view, string choiceId, ChatSession? local, string? gid)
    {
        if (local is not null)
        {
            var request = local.Requests.FirstOrDefault(r => r.Id == view.Id);
            if (request is null) return;
            if (!await _store.AnswerMuseAsync(local, request, choice: choiceId))
                _notice = "Answer failed: the request is no longer pending on this PC.";
            else _notice = null;
            Refresh();
        }
        else if (gid is not null)
        {
            await _devices.SendRemoteCommandAsync(gid, new DeviceCommandPayload
            { Action = "answer", RequestID = view.Id, ChoiceID = choiceId });
            Refresh();
        }
    }

    private async Task AnswerQuestionsAsync(RequestView view, RequestAnswerState state, ChatSession? local, string? gid)
    {
        var json = RequestViews.BuildAnswersJson(view, state.Selections, state.FreeText);
        if (local is not null)
        {
            var request = local.Requests.FirstOrDefault(r => r.Id == view.Id);
            if (request is null) return;
            var answers = JsonNode.Parse(System.Text.Encoding.UTF8.GetString(json)) as JsonArray ?? new JsonArray();
            if (!await _store.AnswerMuseAsync(local, request, answers: answers))
                _notice = "Answer failed: the request is no longer pending on this PC.";
            else _notice = null;
            Refresh();
        }
        else if (gid is not null)
        {
            await _devices.SendRemoteCommandAsync(gid, new DeviceCommandPayload
            { Action = "answer", RequestID = view.Id, AnswersJson = json });
            Refresh();
        }
    }

    private StackPanel BuildPendingPanel(List<(Guid Id, string Text)> pending, bool paused, ChatSession? local, string? gid)
    {
        var panel = new StackPanel { Spacing = 4 };
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        controls.Children.Add(new TextBlock
        {
            Text = pending.Count + " queued" + (paused ? " (paused)" : ""),
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var pause = new Button { Content = paused ? "Resume queue" : "Pause queue", FontSize = 12 };
        pause.Click += (_, _) =>
        {
            if (local is not null)
            {
                local.QueuePaused = !local.QueuePaused;
                _store.Save();
                if (!local.QueuePaused) _store.RunNext(local);
                Refresh();
            }
            else if (gid is not null)
            {
                _ = _devices.SendRemoteCommandAsync(gid,
                    new DeviceCommandPayload { Action = paused ? "resumeQueue" : "pauseQueue" });
            }
        };
        controls.Children.Add(pause);
        var clear = new Button { Content = "Clear queue", FontSize = 12 };
        clear.Click += (_, _) =>
        {
            if (local is not null) { local.Pending.Clear(); _store.Save(); Refresh(); }
            else if (gid is not null)
            {
                _ = _devices.SendRemoteCommandAsync(gid, new DeviceCommandPayload { Action = "clearQueue" });
            }
        };
        controls.Children.Add(clear);
        panel.Children.Add(controls);
        foreach (var (id, text) in pending)
        {
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var preview = new TextBlock
            {
                Text = text.Replace("\r", " ").Replace("\n", " "),
                FontSize = 12,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(preview, 0);
            row.Children.Add(preview);
            var inject = new Button { Content = "Inject now", FontSize = 12 };
            inject.Click += (_, _) =>
            {
                if (local is not null) { _store.InjectPending(local, id); Refresh(); }
                else if (gid is not null)
                {
                    _ = _devices.SendRemoteCommandAsync(gid,
                        new DeviceCommandPayload { Action = "inject", PendingID = id });
                }
            };
            Grid.SetColumn(inject, 1);
            row.Children.Add(inject);
            panel.Children.Add(row);
        }
        return panel;
    }

    private StackPanel BuildOutboxPanel(DeviceOutboxRecord record, string gid)
    {
        var panel = new StackPanel { Spacing = 4 };
        var summary = (record.Payload.Text ?? record.Payload.Action).Replace("\r", " ").Replace("\n", " ");
        if (summary.Length > 120) summary = summary[..120] + "…";
        panel.Children.Add(new TextBlock
        {
            Text = $"Outbox: {record.Outcome}" + (record.Detail is null ? "" : " — " + record.Detail),
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = new SolidColorBrush(Microsoft.UI.Colors.DarkOrange),
        });
        panel.Children.Add(new TextBlock
        {
            Text = summary,
            FontSize = 12,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (record.Outcome == "uncertain")
        {
            var check = new Button { Content = "Check home", FontSize = 12 };
            check.Click += async (_, _) => { await _devices.QueryOutboxAsync(record); Refresh(); };
            row.Children.Add(check);
            var discard = new Button { Content = "Discard", FontSize = 12 };
            discard.Click += (_, _) => { _devices.DiscardOutbox(record.CommandID); Refresh(); };
            row.Children.Add(discard);
        }
        else if (record.Outcome is "failed" or "rejected")
        {
            var restore = new Button { Content = "Restore to composer", FontSize = 12 };
            restore.Click += (_, _) =>
            {
                if (_draftText == "" && record.Payload.Text is { } text && text.Length > 0)
                {
                    _draftText = Breaks(text);
                    RebuildDocument(caretToEnd: true);
                }
                _devices.DiscardOutbox(record.CommandID);
                Refresh();
            };
            row.Children.Add(restore);
            var discard = new Button { Content = "Discard", FontSize = 12 };
            discard.Click += (_, _) => { _devices.DiscardOutbox(record.CommandID); Refresh(); };
            row.Children.Add(discard);
        }
        else if (record.Outcome == "accepted")
        {
            var dismiss = new Button { Content = "Dismiss", FontSize = 12 };
            dismiss.Click += (_, _) => { _devices.DiscardOutbox(record.CommandID); Refresh(); };
            row.Children.Add(dismiss);
        }
        else
        {
            var resend = new Button { Content = "Resend same ID", FontSize = 12 };
            resend.Click += async (_, _) => { await _devices.RetryOutboxAsync(record); Refresh(); };
            row.Children.Add(resend);
        }
        panel.Children.Add(row);
        return panel;
    }

    private void UpdateEarlier()
    {
        if (_selected is null)
        {
            EarlierButton.Visibility = Visibility.Collapsed;
            return;
        }
        if (_selected.LocalSessionID is not null && _hiddenLocal > 0)
        {
            EarlierButton.Content = $"Show earlier messages ({_hiddenLocal} more)";
            EarlierButton.Visibility = Visibility.Visible;
        }
        else if (_selected.GlobalID is string gid
            && _devices.RemoteTranscripts.GetValueOrDefault(gid) is { } transcript
            && transcript.Offset > 0)
        {
            EarlierButton.Content = $"Load earlier messages ({transcript.Offset} earlier)";
            EarlierButton.Visibility = Visibility.Visible;
        }
        else EarlierButton.Visibility = Visibility.Collapsed;
    }

    private async void OnEarlierClick(object sender, RoutedEventArgs e)
    {
        if (_selected?.LocalSessionID is not null)
        {
            _localCap += 200;
            Refresh();
        }
        else if (_selected?.GlobalID is { } gid)
        {
            await _devices.RequestEarlierAsync(gid);
            Refresh();
        }
    }

    private void OnNewSessionClick(object sender, RoutedEventArgs e)
    {
        var entry = _store.Entries.FirstOrDefault();
        if (entry is null) return;
        var session = _store.Create(entry);
        var key = "local:" + session.Id;
        RefreshSidebar();
        SelectSession(new SidebarSession(key, session.Title, "", null, session.Id, ShowPark: false, ShowTake: false, ShowClose: true), caretToEnd: true);
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
        if (_devices.Trust.Devices.Count > 0)
        {
            panel.Children.Add(new TextBlock { Text = "Paired devices:" });
            foreach (var device in _devices.Trust.Devices)
            {
                var row = new Grid();
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var name = new TextBlock { Text = device.Name, VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(name, 0);
                row.Children.Add(name);
                var forget = new Button { Content = "Forget", FontSize = 12 };
                forget.Click += (_, _) => { _devices.ForgetDevice(device); dialog?.Hide(); Refresh(); };
                Grid.SetColumn(forget, 1);
                row.Children.Add(forget);
                panel.Children.Add(row);
            }
        }
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

    private async void OnTakeHereClick(object sender, RoutedEventArgs e)
    {
        if (_selected?.GlobalID is not { } gid) return;
        await _devices.AcquireRemoteAsync(gid);
        Refresh();
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
        if (string.IsNullOrWhiteSpace(text) || _selected is null || !InputAllowed()) return;
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
            var hashes = _remoteHashes.GetValueOrDefault(globalId)?.ToArray() ?? Array.Empty<string>();
            await _devices.SendRemoteCommandAsync(globalId,
                new DeviceCommandPayload { Action = "submit", Text = text, BlobHashes = hashes });
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

    private async void OnAttachClick(object sender, RoutedEventArgs e)
    {
        if (_selected is null || !InputAllowed()) return;
        try
        {
            var picker = new Windows.Storage.Pickers.FileOpenPicker();
            picker.FileTypeFilter.Add(".png");
            picker.FileTypeFilter.Add(".jpg");
            picker.FileTypeFilter.Add(".jpeg");
            picker.FileTypeFilter.Add(".gif");
            picker.FileTypeFilter.Add(".bmp");
            picker.FileTypeFilter.Add(".webp");
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            var files = await picker.PickMultipleFilesAsync();
            if (files.Count == 0) return;
            if (_selected.LocalSessionID is { } localId)
            {
                var session = _store.Sessions.FirstOrDefault(s => s.Id == localId);
                if (session is null) return;
                var dir = Path.Combine(_dataFolder, "Attachments", localId.ToString("D"));
                Directory.CreateDirectory(dir);
                foreach (var file in files)
                {
                    var dest = Path.Combine(dir, DateTime.UtcNow.Ticks + "-" + file.Name);
                    File.Copy(file.Path, dest);
                    session.Attachments.Add(dest);
                }
                _store.Save();
            }
            else if (_selected.GlobalID is { } globalId)
            {
                if (!_remoteHashes.TryGetValue(globalId, out var hashes))
                {
                    hashes = new List<string>();
                    _remoteHashes[globalId] = hashes;
                }
                foreach (var file in files)
                {
                    var hash = await _devices.UploadBlobAsync(globalId, await File.ReadAllBytesAsync(file.Path));
                    if (hash is null) break;
                    hashes.Add(hash);
                }
            }
            _notice = null;
        }
        catch (Exception error)
        {
            _notice = "Attach failed: " + error.Message;
        }
        Refresh();
    }

    private void OnClearImagesClick(object sender, RoutedEventArgs e)
    {
        if (_selected?.LocalSessionID is { } localId)
        {
            var session = _store.Sessions.FirstOrDefault(s => s.Id == localId);
            if (session is not null) { session.Attachments.Clear(); _store.Save(); }
        }
        else if (_selected?.GlobalID is { } globalId)
        {
            _remoteHashes.Remove(globalId);
        }
        Refresh();
    }
}
