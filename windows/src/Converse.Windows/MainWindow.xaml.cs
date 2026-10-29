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
public sealed record SidebarSession(string Key, string Title, string Subtitle, string? GlobalID, Guid? LocalSessionID, bool ShowPark, bool ShowClose, bool ShowPlace, bool ShowGreyClose = false) : SidebarItem(Key);

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

    // Block-transcript state (Mac parity renderer): history renders as
    // per-message read-only blocks; the draft is one persistent editable
    // tail box. History is never a rich-edit document again, so no SetText
    // churn, no seam bookkeeping, and no backspace hole can exist. The
    // renderer diffs the visible lines against what it last showed: a
    // streaming tick only re-renders the final message block and appends
    // any new ones; anything else takes a full block swap (cheap visual
    // swap, not a document rebuild).
    private List<(string Role, string Text)> _renderedLines = new();
    private string? _lastChangeKey;
    private string _draftText = "";
    private bool _draftSetting;
    private string? _lastSentText;
    private string _sidebarSignature = "";
    private string _bannerSignature = "";
    private bool _suppressSettings;
    private bool _modelEditing;
    private int _draftSeq;
    private DateTime _lastDraftFlush = DateTime.MinValue;
    private int _localCap = 200;
    private int _hiddenLocal;
    private string? _notice;
    // Notices set with a timestamp expire on their own (inject feedback);
    // notices without one persist until the next related action.
    private DateTime? _noticeUtc;
    private readonly Dictionary<string, RequestAnswerState> _answerStates = new();
    private readonly Dictionary<string, List<string>> _remoteHashes = new();
    // Pane slots 1-3 (Mac P/1/2/3/X parity): placements persist in
    // pane-layout.json; focus (_selected) is independent of placement.
    private readonly PanePlacements _placements;
    private string _paneSignature = "";
    // Scroll-follow: the tail is sticky while the caret sits at the end, but
    // a manual scroll up parks the viewport (Jump to latest appears) until
    // the user jumps back, or new arrivals come in after ~5s of no scroll
    // input. A text selection always pins the viewport: looking around and
    // copy-pasting never yanks.
    private DateTime? _userScrollUtc;
    private int _unreadUpdates;
    // Scrolling single source of truth: every programmatic ChangeView goes
    // through OwnChangeView, which counts it. The scroll handler consumes
    // one count per finished event without touching the idle clock. Any
    // uncounted change is the user.
    private int _ownScrolls;
    // Streaming coalescing: while the shown session works, block syncs run
    // at most every 200ms with one trailing catch-up.
    private DateTime _lastStreamRebuildUtc;
    private bool _rebuildCoalesced;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _rebuildTimer;
    private StackPanel? _groupsPanel;
    private string _groupsSignature = "";
    private string _groupsCreateName = "";
    private string _groupsJoinHost = "";
    private string _groupsJoinPort = "";
    private string _groupsJoinGroupId = "";
    private string? _groupsArmDissolve;
    private readonly HashSet<Guid> _groupsSeen = new();

    public MainWindow()
    {
        InitializeComponent();
        var folder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Converse");
        _dataFolder = folder;
        _layout = SidebarLayoutState.Load(folder);
        _placements = PanePlacements.Load(folder);
        _store = new SessionStore(folder);
        _devices = new DeviceSyncService(folder, _store);
        // No modal pairing prompt: joins surface as codes in the Groups
        // dialog, where both sides compare all eight groups. (The
        // PairingConfirmation callback stays for headless tests only.)
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

    private void Refresh()
    {
        if (!DispatcherQueue.HasThreadAccess)
        {
            DispatcherQueue.TryEnqueue(Refresh);
            return;
        }
        // Parked by a group move: the selected home no longer exists.
        if (_selected?.GlobalID is { } gid && DeviceGlobalID.Parse(gid) is { } parsed
            && !_devices.Homes.ContainsKey(parsed.Home))
            SelectSession(null, caretToEnd: false);
        RefreshSidebar();
        RenderPane();
        RenderPaneBar();
        RenderGroupsDialog();
        AutoOpenGroups();
    }

    private void RefreshSidebar()
    {
        var items = new List<SidebarItem>();
        // Group heading above the sessions; remote homes appear only while
        // this device belongs to the group (the service scopes Homes).
        if (_devices.CurrentGroup is { } current)
            items.Add(new SidebarHeader("group", "Group: " + current.Name,
                _devices.Trust.Devices.Count(d => d.GroupID == current.Id) + " member(s)"));
        items.Add(new SidebarHeader("local", "This PC", _store.Sessions.Count + " session(s)"));
        foreach (var session in _store.Sessions)
            items.Add(new SidebarSession("local:" + session.Id, (session.Busy ? "● " : "") + session.Title,
                session.Entry.Name + " · " + session.Status, null, session.Id, ShowPark: true, ShowClose: true, ShowPlace: true));
        foreach (var home in _devices.Homes.Values.OrderBy(h => h.DeviceName))
        {
            items.Add(new SidebarHeader("home:" + home.DeviceID, home.DeviceName,
                home.Online ? home.Rows.Count + " session(s)" : "Offline"));
            if (home.Rows.Count == 0)
                items.Add(new SidebarSession("home:" + home.DeviceID + ":empty",
                    home.Online ? "No sessions available" : "Offline", "", null, null, ShowPark: false, ShowClose: false, ShowPlace: false));
            foreach (var row in home.Rows)
                items.Add(new SidebarSession("remote:" + row.GlobalID, (row.Busy ? "● " : "") + row.Title,
                    (home.Online ? "" : "Offline · ") + row.Status, row.GlobalID, null, ShowPark: true, ShowClose: false, ShowPlace: true, ShowGreyClose: true));
        }
        var signature = string.Join("\n", items.Select(i => i.Key + "|" + (i switch
        {
            SidebarHeader h => h.Title + "|" + h.Status,
            SidebarSession s => s.Title + "|" + s.Subtitle + "|" + s.ShowPark + "|" + s.ShowClose + "|" + s.ShowPlace,
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

    // Visible transcript lines for the selected conversation with the local
    // cap applied (remote paging comes from home instead). Hidden user turns
    // are counted so the prologue numbers stay continuous with what paging
    // hid — the Mac numbers every submitted turn from 1.
    private (List<(string Role, string Text)> Lines, int Hidden, int HiddenUsers) VisibleLines()
    {
        List<(string Role, string Text)>? lines = null;
        if (_selected?.LocalSessionID is { } localId)
            lines = _store.Sessions.FirstOrDefault(s => s.Id == localId)?.Messages
                .Where(m => m.Role is "user" or "assistant" && !string.IsNullOrEmpty(m.Text))
                .Select(m => (m.Role, m.Text)).ToList();
        else if (_selected?.GlobalID is { } globalId)
            lines = _devices.RemoteTranscripts.GetValueOrDefault(globalId)?.Messages
                .Where(m => m.Role is "user" or "assistant" && !string.IsNullOrEmpty(m.Text))
                .Select(m => (m.Role, m.Text)).ToList();
        if (lines is null) return (new List<(string Role, string Text)>(), 0, 0);
        var cap = _selected?.LocalSessionID is not null ? _localCap : lines.Count;
        var hidden = Math.Max(0, lines.Count - cap);
        var hiddenUsers = lines.Take(hidden).Count(line => line.Role == "user");
        if (hidden > 0) lines = lines.Skip(hidden).ToList();
        return (lines, hidden, hiddenUsers);
    }

    private void RenderPane(bool caretToEnd = false)
    {
        if (_selected is null)
        {
            PaneTitle.Text = "No conversation selected";
            PaneSubtitle.Text = "";
            DraftBox.IsEnabled = false;
            SendButton.IsEnabled = false;
            StopButton.IsEnabled = false;
            AttachButton.IsEnabled = false;
            ModelBox.IsEnabled = EffortBox.IsEnabled = AccessBox.IsEnabled = false; // WinUI 3 panels have no IsEnabled
            TakeButton.Visibility = Visibility.Collapsed;
            BusyRing.IsActive = false;
            // Force the empty sync: the cleared state may equal the tracked
            // state while blocks still show the old session.
            _draftText = "";
            SetDraftBox();
            _lastChangeKey = null;
            SyncLines(new List<(string Role, string Text)>(), 0, caretToEnd: true);
            RenderBanners();
            UpdateEarlier();
            UpdateHint();
            return;
        }
        PaneTitle.Text = _selected.Title;
        // Adopt the home draft only into an untouched tail; never over typing.
        // Stored drafts use \n; the draft box uses \r, so normalize on adopt.
        var homeDraft = _selected.LocalSessionID is { } localId
            ? _store.Sessions.FirstOrDefault(s => s.Id == localId)?.Draft ?? ""
            : _devices.RemoteTranscripts.GetValueOrDefault(_selected.GlobalID ?? "")?.Draft ?? "";
        if (_draftText == "" && homeDraft != "" && homeDraft != _lastSentText)
        {
            _draftText = Breaks(homeDraft);
            SetDraftBox();
        }
        // A remote draft clears only after its exact sent text is acknowledged.
        if (_selected.GlobalID is not null && _lastSentText is not null && homeDraft == "" && _draftText == Breaks(_lastSentText))
        {
            _draftText = "";
            _lastSentText = null;
            _remoteHashes.Remove(_selected.GlobalID);
            SetDraftBox();
        }
        var (lines, hidden, hiddenUsers) = VisibleLines();
        _hiddenLocal = _selected.LocalSessionID is not null ? hidden : 0;
        if (!LinesEqual(lines, _renderedLines))
        {
            if (SelectedBusy() && (DateTime.UtcNow - _lastStreamRebuildUtc).TotalMilliseconds < 200)
            {
                if (!_rebuildCoalesced)
                {
                    _rebuildCoalesced = true;
                    if (_rebuildTimer is null)
                    {
                        _rebuildTimer = DispatcherQueue.CreateTimer();
                        _rebuildTimer.Tick += (_, _) =>
                        {
                            _rebuildTimer.Stop();
                            _rebuildCoalesced = false;
                            _lastStreamRebuildUtc = DateTime.UtcNow;
                            // Re-read at fire time so the catch-up shows the
                            // freshest lines, not the ones that scheduled it.
                            var (fresh, _, freshHiddenUsers) = VisibleLines();
                            SyncLines(fresh, freshHiddenUsers, caretToEnd: false);
                        };
                    }
                    _rebuildTimer.Interval = TimeSpan.FromMilliseconds(200);
                    _rebuildTimer.Start();
                }
            }
            else
            {
                _lastStreamRebuildUtc = DateTime.UtcNow;
                SyncLines(lines, hiddenUsers, caretToEnd);
            }
        }
        else if (caretToEnd) ScrollTranscriptToEnd();
        UpdateGate();
        UpdateBusy();
        RenderBanners();
        UpdateEarlier();
        UpdateHint();
        RefreshSettings();
    }

    private bool SelectedBusy()
    {
        if (_selected?.LocalSessionID is { } localId)
            return _store.Sessions.FirstOrDefault(s => s.Id == localId)?.Busy == true;
        if (_selected?.GlobalID is { } globalId)
            return _devices.RemoteTranscripts.GetValueOrDefault(globalId)?.Busy == true;
        return false;
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
        DraftBox.IsEnabled = allowed;
        SendButton.IsEnabled = allowed;
        StopButton.IsEnabled = allowed;
        AttachButton.IsEnabled = allowed;
        ModelBox.IsEnabled = EffortBox.IsEnabled = AccessBox.IsEnabled = allowed; // WinUI 3 panels have no IsEnabled
        var showTake = _selected?.GlobalID is string gid
            && (!_devices.RemoteLeases.ContainsKey(gid) || _devices.RemoteOffline.Contains(gid));
        TakeButton.Visibility = showTake ? Visibility.Visible : Visibility.Collapsed;
        if (showTake && DeviceGlobalID.Parse(_selected!.GlobalID!) is { } parsed)
            TakeButton.IsEnabled = _devices.Homes.GetValueOrDefault(parsed.Home)?.Online == true;
        DraftBox.PlaceholderText = _selected is null ? "Select a conversation to begin." : "";
    }

    private void UpdateBusy()
    {
        // Live status, never the selected sidebar snapshot: the snapshot
        // freezes at selection time and disagrees with the sidebar.
        bool busy;
        var parts = new List<string>();
        if (_selected?.LocalSessionID is { } localId)
        {
            var session = _store.Sessions.FirstOrDefault(s => s.Id == localId);
            busy = session?.Busy == true;
            if (session is not null)
            {
                parts.Add(session.Entry.Name + " · " + session.Status);
                if (session.Pending.Count > 0)
                    parts.Add(session.Pending.Count + " queued" + (session.QueuePaused ? " (paused)" : ""));
            }
        }
        else if (_selected?.GlobalID is { } globalId)
        {
            var transcript = _devices.RemoteTranscripts.GetValueOrDefault(globalId);
            busy = transcript?.Busy == true;
            if (transcript is not null)
            {
                parts.Add(transcript.Status);
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
        if (_noticeUtc is { } stamp && (DateTime.UtcNow - stamp).TotalSeconds > 30)
        {
            _notice = null;
            _noticeUtc = null;
        }
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
            // Never overwrite a model ID the user is still typing: streaming
            // refreshes arrive while the box has focus, and re-selecting an
            // item in an editable ComboBox replaces its text too.
            if (!ModelBox.IsDropDownOpen && !_modelEditing)
            {
                SyncCombo(ModelBox, modelItems, model ?? "");
                ModelBox.Text = model ?? CliDefault;
            }
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

    // Focus lands on the editable ComboBox's inner TextBox, so ModelBox.FocusState
    // stays Unfocused while typing; track editing from the bubbled focus events.
    private void OnModelGotFocus(object sender, RoutedEventArgs e) => _modelEditing = true;

    private void OnModelCommitted(object sender, RoutedEventArgs e)
    {
        _modelEditing = false;
        CommitModel(ModelBox.Text);
    }

    // An editable ComboBox consumes Enter itself and raises TextSubmitted instead of KeyDown.
    private void OnModelTextSubmitted(ComboBox sender, ComboBoxTextSubmittedEventArgs e)
    {
        e.Handled = true;
        // Let the refresh select the submitted ID; otherwise the box reverts to
        // its old selection and the next LostFocus commits that instead.
        _modelEditing = false;
        CommitModel(e.Text);
    }

    private void CommitModel(string raw)
    {
        if (_suppressSettings || _selected is null) return;
        var text = raw.Trim();
        // The box shows labels; map a shown label back to its model ID.
        if ((ModelBox.ItemsSource as List<SettingItem>)?.FirstOrDefault(i => i.Label == text) is { } shown) text = shown.Id;
        if (text == CliDefault) text = "";
        ApplySetting("model", text == "" ? null : text);
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

    // ---- Block transcript renderer (Mac parity) ----
    // History renders as per-message blocks in TranscriptStack; the last
    // child is always the DraftBox. A streaming tick re-renders only the
    // final block and appends new ones; anything else (session switch,
    // paging, cap change) swaps the blocks wholesale. Blocks are cheap
    // visual elements — no transcript document is ever mutated, which
    // retires by construction the SetText crash class, the seam/tracker
    // bookkeeping, and the backspace hole of the single-document editor.
    private static bool SameLine((string Role, string Text) a, (string Role, string Text) b)
        => a.Role == b.Role && a.Text == b.Text;

    private static bool LinesEqual(List<(string Role, string Text)> a, List<(string Role, string Text)> b)
    {
        if (a.Count != b.Count) return false;
        for (var i = 0; i < a.Count; i++) if (!SameLine(a[i], b[i])) return false;
        return true;
    }

    private void SyncLines(List<(string Role, string Text)> lines, int hiddenUsers, bool caretToEnd)
    {
        var key = (_selected?.Key ?? "none") + "|" + hiddenUsers;
        // Prologue numbers: prompts count up from 1 (past the paged-away
        // ones); a response sits under its prompt's number, like the Mac
        // ruler. Only prompt blocks print the number.
        var numbers = new int[lines.Count];
        var n = hiddenUsers;
        for (var i = 0; i < lines.Count; i++) { if (lines[i].Role == "user") n++; numbers[i] = n; }
        var samePrefix = _lastChangeKey == key && lines.Count >= _renderedLines.Count;
        if (samePrefix)
            for (var i = 0; i < Math.Max(0, _renderedLines.Count - 1); i++)
                if (!SameLine(lines[i], _renderedLines[i])) { samePrefix = false; break; }
        if (samePrefix && lines.Count == _renderedLines.Count
            && (lines.Count == 0 || SameLine(lines[^1], _renderedLines[^1]))) return;
        var follow = ComputeFollow(caretToEnd);
        if (samePrefix)
        {
            if (_renderedLines.Count > 0
                && !SameLine(lines[_renderedLines.Count - 1], _renderedLines[^1]))
                TranscriptStack.Children[_renderedLines.Count - 1] =
                    BuildMessageBlock(lines[_renderedLines.Count - 1], numbers[_renderedLines.Count - 1]);
            for (var i = _renderedLines.Count; i < lines.Count; i++)
                TranscriptStack.Children.Insert(TranscriptStack.Children.Count - 1,
                    BuildMessageBlock(lines[i], numbers[i]));
        }
        else
        {
            if (SelectedBusy() && _lastChangeKey == key) LogFallback("block-full-while-busy");
            while (TranscriptStack.Children.Count > 1) TranscriptStack.Children.RemoveAt(0);
            for (var i = 0; i < lines.Count; i++)
                TranscriptStack.Children.Insert(i, BuildMessageBlock(lines[i], numbers[i]));
        }
        _renderedLines = lines;
        _lastChangeKey = key;
        // A parked reader gets no scroll and no selection touch — only the
        // unread count grows. Following scrolls after layout settles, when
        // ScrollableHeight carries the fresh blocks.
        if (follow)
        {
            _unreadUpdates = 0;
            UpdateJumpButton(following: true);
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
                () => OwnChangeView(TranscriptScroller, TranscriptScroller.ScrollableHeight));
        }
        else
        {
            _unreadUpdates++;
            UpdateJumpButton(following: false);
        }
    }

    private bool ComputeFollow(bool caretToEnd)
    {
        if (caretToEnd) return true;
        if (HasBlockSelection()) return false; // a selection never yanks
        var scroller = TranscriptScroller;
        var nearBottom = scroller.ScrollableHeight - scroller.VerticalOffset < 200;
        var caretAtEnd = DraftBox.Document.Selection.StartPosition >= GetDraftText().Length;
        if (nearBottom && caretAtEnd) return true;
        // Mac parity: five idle seconds without scrolling or selecting
        // rejoins the tail on the next arrival.
        return _userScrollUtc is { } lastLook && (DateTime.UtcNow - lastLook).TotalSeconds > 5;
    }

    private bool HasBlockSelection()
    {
        for (var i = 0; i + 1 < TranscriptStack.Children.Count; i++)
            foreach (var rich in RichTextsUnder(TranscriptStack.Children[i]))
                if (rich.SelectedText.Length > 0) return true;
        return false;
    }

    private static IEnumerable<RichTextBlock> RichTextsUnder(DependencyObject root)
    {
        var queue = new Queue<DependencyObject>();
        queue.Enqueue(root);
        while (queue.Count > 0)
        {
            var current = queue.Dequeue();
            if (current is RichTextBlock rich) yield return rich;
            var count = VisualTreeHelper.GetChildrenCount(current);
            for (var j = 0; j < count; j++) queue.Enqueue(VisualTreeHelper.GetChild(current, j));
        }
    }
    private Border BuildMessageBlock((string Role, string Text) line, int number)
    {
        var isUser = line.Role == "user";
        var showNumbers = _layout.ShowLineNumbers;
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        // The Mac ruler's number, as a chip beside each prompt: prompts
        // print it, responses keep the same left edge without one.
        var chip = new TextBlock
        {
            Text = isUser && showNumbers ? number.ToString() : "",
            FontSize = 16,
            MinWidth = showNumbers ? 28 : 0,
            TextAlignment = TextAlignment.Right,
            Margin = new Thickness(0, 2, 0, 0),
            Foreground = new SolidColorBrush(Microsoft.UI.Colors.SteelBlue),
        };
        Grid.SetColumn(chip, 0);
        grid.Children.Add(chip);
        var body = new StackPanel { Spacing = 8 };
        Grid.SetColumn(body, 1);
        grid.Children.Add(body);
        var flat = MarkdownRuns.SanitizeLoneSurrogates(line.Text.Replace("\r\n", "\n").Replace('\r', '\n'));
        // Prompts are never markdown (Mac parity): italic plain text on the
        // light-blue ground. Responses parse to blocks with real tables.
        var blocks = isUser
            ? new List<MdBlock> { new MdText(flat, new List<MdInline>()) }
            : MarkdownBlocks.Parse(flat);
        foreach (var block in blocks) body.Children.Add(RenderMdBlock(block, isUser));
        if (body.Children.Count == 0) body.Children.Add(new RichTextBlock { FontSize = 16 });
        var dark = (Content as FrameworkElement)?.ActualTheme == ElementTheme.Dark;
        var border = new Border
        {
            Child = grid,
            Padding = new Thickness(6),
            CornerRadius = new CornerRadius(4),
            Background = isUser
                ? new SolidColorBrush(dark
                    ? Windows.UI.Color.FromArgb(255, 26, 41, 77)
                    : Windows.UI.Color.FromArgb(255, 225, 238, 255))
                : null,
        };
        AttachBlockMenu(border, line);
        return border;
    }

    private FrameworkElement RenderMdBlock(MdBlock block, bool isUser) => block switch
    {
        MdTable table => RenderMdTable(table),
        MdText text => RenderMdText(text, isUser),
        _ => new RichTextBlock { FontSize = 16 },
    };

    private RichTextBlock RenderMdText(MdText block, bool isUser)
    {
        var view = new RichTextBlock { FontSize = 16, TextWrapping = TextWrapping.Wrap };
        // Selecting is looking: veto the idle-follow while it changes.
        view.SelectionChanged += (_, _) =>
        {
            if (view.SelectedText.Length > 0) _userScrollUtc = DateTime.UtcNow;
        };
        // One paragraph per block; every \n is a LineBreak so parser run
        // offsets stay in one coordinate system.
        var para = new Paragraph();
        var cursor = 0;
        foreach (var run in block.Runs)
        {
            var start = Math.Clamp(run.Start, cursor, block.Text.Length);
            var end = Math.Clamp(run.Start + run.Length, start, block.Text.Length);
            AddRunSegment(para, block.Text, cursor, start, MdRunKind.Plain, isUser);
            if (end > start) AddRunSegment(para, block.Text, start, end, run.Kind, isUser);
            cursor = Math.Max(cursor, end);
        }
        AddRunSegment(para, block.Text, cursor, block.Text.Length, MdRunKind.Plain, isUser);
        view.Blocks.Add(para);
        return view;
    }

    private void AddRunSegment(Paragraph para, string source, int start, int end, MdRunKind kind, bool isUser)
    {
        if (end <= start) return;
        var parts = source[start..end].Split('\n');
        for (var i = 0; i < parts.Length; i++)
        {
            if (i > 0) para.Inlines.Add(new LineBreak());
            if (parts[i].Length == 0) continue;
            var run = new Run { Text = parts[i] };
            if (isUser)
            {
                var italic = new Italic();
                italic.Inlines.Add(run);
                para.Inlines.Add(italic);
            }
            else switch (kind)
            {
                case MdRunKind.Bold:
                case MdRunKind.Heading:
                    var bold = new Bold();
                    bold.Inlines.Add(run);
                    para.Inlines.Add(bold);
                    break;
                case MdRunKind.Italic:
                    var italic = new Italic();
                    italic.Inlines.Add(run);
                    para.Inlines.Add(italic);
                    break;
                case MdRunKind.Code:
                    var span = new Span { FontFamily = new FontFamily("Consolas") };
                    span.Inlines.Add(run);
                    para.Inlines.Add(span);
                    break;
                default:
                    para.Inlines.Add(run);
                    break;
            }
        }
    }

    // NSTextTable parity: real borders, header row bold (the Mac's own
    // stated semantics), alignments from the divider row.
    private Grid RenderMdTable(MdTable table)
    {
        var cols = 0;
        foreach (var row in table.Rows) cols = Math.Max(cols, row.Count);
        var grid = new Grid();
        for (var c = 0; c < cols; c++)
            grid.ColumnDefinitions.Add(new ColumnDefinition
            { Width = c + 1 < cols ? GridLength.Auto : new GridLength(1, GridUnitType.Star) });
        for (var r = 0; r < table.Rows.Count; r++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            for (var c = 0; c < cols; c++)
            {
                var cellText = c < table.Rows[r].Count ? table.Rows[r][c] : "";
                var align = c < table.Alignments.Count ? table.Alignments[c] : 0;
                var header = table.HasHeader && r == 0;
                var text = new TextBlock
                {
                    Text = cellText,
                    FontSize = 15,
                    TextWrapping = TextWrapping.Wrap,
                    IsTextSelectionEnabled = true,
                    FontWeight = header ? Microsoft.UI.Text.FontWeights.Bold : Microsoft.UI.Text.FontWeights.Normal,
                    TextAlignment = align switch
                    {
                        1 => TextAlignment.Center,
                        2 => TextAlignment.Right,
                        _ => TextAlignment.Left,
                    },
                };
                var cell = new Border
                {
                    Child = text,
                    Padding = new Thickness(6, 4, 6, 4),
                    BorderThickness = new Thickness(0.5),
                    BorderBrush = new SolidColorBrush(Microsoft.UI.Colors.Gray),
                };
                Grid.SetRow(cell, r);
                Grid.SetColumn(cell, c);
                grid.Children.Add(cell);
            }
        }
        return grid;
    }

    // Right-click copy per message (Mac spec): Copy acts on this block's
    // selection, whole Prompt/Response copy below it, and no Cut/Paste
    // anywhere near history.
    private void AttachBlockMenu(Border border, (string Role, string Text) line)
    {
        var copySelection = new MenuFlyoutItem { Text = "Copy" };
        var menu = new MenuFlyout();
        var selection = "";
        copySelection.Click += (_, _) => CopyToClipboard(selection);
        var copyMessage = new MenuFlyoutItem
        { Text = line.Role == "user" ? "Copy Prompt" : "Copy Response" };
        copyMessage.Click += (_, _) =>
            CopyToClipboard(MarkdownRuns.SanitizeLoneSurrogates(line.Text));
        menu.Items.Add(copySelection);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(copyMessage);
        menu.Opening += (_, _) =>
        {
            selection = "";
            foreach (var rich in RichTextsUnder(border))
                if (rich.SelectedText.Length > 0) { selection = rich.SelectedText; break; }
            copySelection.IsEnabled = selection.Length > 0;
        };
        border.ContextFlyout = menu;
    }

    private static void CopyToClipboard(string text)
    {
        try
        {
            var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(text);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
        }
        catch { /* clipboard busy: keyboard copy still works */ }
    }

    // ---- The draft tail: one persistent editable box, blue like the Mac.
    // History blocks are read-only, so the draft physically cannot reach
    // protected text — the backspace hole has nowhere to live. ----
    private string GetDraftText()
    {
        DraftBox.Document.GetText(TextGetOptions.None, out var text);
        return text.Replace("\r\n", "\r");
    }

    private void SetDraftBox()
    {
        _draftSetting = true;
        try
        {
            DraftBox.Document.SetText(TextSetOptions.None, _draftText);
            var length = GetDraftText().Length;
            if (length > 0)
            {
                var range = DraftBox.Document.GetRange(0, length);
                range.CharacterFormat.ForegroundColor = Microsoft.UI.Colors.Blue;
                range.CharacterFormat.Italic = FormatEffect.Off;
            }
            DraftBox.Document.Selection.SetRange(length, length);
        }
        finally { _draftSetting = false; }
    }

    private void OnDraftTextChanged(object sender, RoutedEventArgs e)
    {
        if (_draftSetting || _selected is null) return;
        var text = GetDraftText();
        if (text == _draftText) return;
        _draftText = text;
        // Typed text renders blue (Mac inline formatting); a programmatic
        // format change does not retrigger TextChanged.
        var range = DraftBox.Document.GetRange(0, text.Length);
        range.CharacterFormat.ForegroundColor = Microsoft.UI.Colors.Blue;
        range.CharacterFormat.Italic = FormatEffect.Off;
        ScheduleDraftFlush();
    }

    private void OnDraftKeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        // Mac parity: Return sends; Control+Return inserts a newline.
        if (e.Key != Windows.System.VirtualKey.Enter) return;
        var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (ctrl) return;
        e.Handled = true;
        OnSendClick(sender, e);
    }


    private void OnTranscriptScrolled(object sender, ScrollViewerViewChangedEventArgs e)
    {
        var scroller = TranscriptScroller;
        // Counted programmatic scroll: never touch the idle clock.
        // Intermediate frames share the count without consuming it; any
        // uncounted change is the user.
        if (_ownScrolls > 0)
        {
            if (!e.IsIntermediate) _ownScrolls--;
            return;
        }
        _userScrollUtc = DateTime.UtcNow;
        UpdateJumpButton(following: scroller.VerticalOffset >= scroller.ScrollableHeight - 200);
    }

    private void UpdateJumpButton(bool following)
    {
        JumpLatestButton.Content = _unreadUpdates == 0
            ? "↓ Latest" : $"↓ Latest ({_unreadUpdates} new)";
        var scrollable = TranscriptScroller.ScrollableHeight;
        JumpLatestButton.Visibility = !following && scrollable > 200
            ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnJumpLatestClick(object sender, RoutedEventArgs e)
    {
        _userScrollUtc = DateTime.UtcNow;
        _unreadUpdates = 0;
        UpdateJumpButton(following: true);
        ScrollTranscriptToEnd();
        DraftBox.Focus(FocusState.Programmatic);
    }

    // Counts full block swaps that fire while the shown session works, to
    // a log beside the exe. The VM tails it: a nonzero count means a sync
    // missed the incremental path (now cheap, but worth seeing).
    private void LogFallback(string reason)
    {
        try
        {
            var path = System.IO.Path.Combine(AppContext.BaseDirectory, "rebuild-fallback.log");
            System.IO.File.AppendAllText(path,
                $"{DateTime.UtcNow:o} session={_selected?.Key} reason={reason} lines={_renderedLines.Count}\n");
        }
        catch { /* logging never breaks rendering */ }
    }

    private void OwnChangeView(ScrollViewer scroller, double vertical)
    {
        // No event comes when the offset is already there; counting one
        // would eat the next real user scroll.
        if (Math.Abs(vertical - scroller.VerticalOffset) <= 1) return;
        _ownScrolls++;
        scroller.ChangeView(null, vertical, null, true);
    }

    private void ScrollTranscriptToEnd()
    {
        var scroller = TranscriptScroller;
        if (Math.Abs(scroller.ScrollableHeight - scroller.VerticalOffset) > 1) _ownScrolls++;
        scroller.ChangeView(null, scroller.ScrollableHeight, null);
    }

    private void OnLineNumbersToggled(object sender, RoutedEventArgs e)
    {
        _layout.ShowLineNumbers = LineNumbersBox.IsChecked == true;
        _layout.Save(_dataFolder);
        // Chips are baked into blocks at build time: force a full re-sync.
        _lastChangeKey = null;
        Refresh();
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
        _draftText = "";
        // Fresh blocks start empty: the next sync swaps everything in.
        _renderedLines = new List<(string Role, string Text)>();
        _lastChangeKey = null;
        _ownScrolls = 0;
        _lastSentText = null;
        _userScrollUtc = null;
        _unreadUpdates = 0;
        UpdateJumpButton(following: true);
        _localCap = 200;
        if (session?.LocalSessionID is { } localId)
            _draftText = Breaks(_store.Sessions.FirstOrDefault(s => s.Id == localId)?.Draft ?? "");
        else if (session?.GlobalID is { } globalId)
            _draftText = Breaks(_devices.RemoteTranscripts.GetValueOrDefault(globalId)?.Draft ?? "");
        SetDraftBox();
        RenderPane(caretToEnd);
        if (caretToEnd) DraftBox.Focus(FocusState.Programmatic);
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
        _placements.Park("local:" + localId);
        _placements.Save(_dataFolder);
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
        DraftBox.Focus(FocusState.Programmatic);
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
        DraftBox.Focus(FocusState.Programmatic);
    }

    private StackPanel BuildPendingPanel(List<(Guid Id, string Text)> pending, bool paused, ChatSession? local, string? gid)
    {
        var panel = new StackPanel { Spacing = 4 };
        // Mac parity: one outstanding remote queue intent disables the whole
        // queue panel (double presses reuse it via the send-side guard), so
        // a blocked press can never go silent. Local repeats stay enabled.
        var queueRecord = gid is not null && local is null ? _devices.QueueCommand(gid) : null;
        var queueBusy = queueRecord is not null
            && queueRecord.Outcome is "pending" or "accepted" or "uncertain";
        if (pending.Count == 0)
        {
            // Paused with nothing held: a slim Resume row instead of a
            // "0 queued (paused)" banner. Focus returns to the composer so
            // Return keeps sending instead of re-clicking Resume.
            var slim = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            slim.Children.Add(new TextBlock
            {
                Text = "Queue paused",
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
            });
            var resume = new Button { Content = "Resume queue", FontSize = 12 };
            resume.Click += (_, _) =>
            {
                if (local is not null) { local.QueuePaused = false; _store.Save(); _store.RunNext(local); Refresh(); }
                else if (gid is not null)
                {
                    _ = _devices.SendRemoteCommandAsync(gid, new DeviceCommandPayload { Action = "resumeQueue" });
                }
                DraftBox.Focus(FocusState.Programmatic);
            };
            resume.IsEnabled = !queueBusy;
            slim.Children.Add(resume);
            panel.Children.Add(slim);
            return panel;
        }
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        controls.Children.Add(new TextBlock
        {
            Text = pending.Count + " queued" + (paused ? " (paused)" : ""),
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var pause = new Button { Content = paused ? "Resume queue" : "Pause queue", FontSize = 12, IsEnabled = !queueBusy };
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
            DraftBox.Focus(FocusState.Programmatic);
        };
        controls.Children.Add(pause);
        var clear = new Button { Content = "Clear queue", FontSize = 12, IsEnabled = !queueBusy };
        clear.Click += (_, _) =>
        {
            if (local is not null) { local.Pending.Clear(); _store.Save(); Refresh(); }
            else if (gid is not null)
            {
                _ = _devices.SendRemoteCommandAsync(gid, new DeviceCommandPayload { Action = "clearQueue" });
            }
            DraftBox.Focus(FocusState.Programmatic);
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
            var injectingThis = queueBusy && queueRecord?.Payload.Action == "inject" && queueRecord.Payload.PendingID == id;
            var inject = new Button
            {
                Content = injectingThis ? "Injecting…" : "Inject now",
                FontSize = 12,
                IsEnabled = !queueBusy,
            };
            inject.Click += (_, _) =>
            {
                // Instant, unmissable feedback: interrupting a busy turn
                // takes seconds (SIGINT, escalate, notice), and every
                // inject path was silent until then — the mash-three-times
                // bug. Repeat presses while stopping are harmless.
                if (local is not null)
                {
                    var wasBusy = local.Busy;
                    var failure = _store.InjectPending(local, id);
                    _notice = failure
                        ?? (wasBusy ? "Interrupting the current turn — the queued prompt runs next."
                            : "Queued prompt moved up — sending now.");
                    _noticeUtc = DateTime.UtcNow;
                    Refresh();
                }
                else if (gid is not null)
                {
                    _notice = "Sent — waiting for home to interrupt and run it.";
                    _noticeUtc = DateTime.UtcNow;
                    _ = _devices.SendRemoteCommandAsync(gid,
                        new DeviceCommandPayload { Action = "inject", PendingID = id });
                }
                DraftBox.Focus(FocusState.Programmatic);
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
            check.Click += async (_, _) => { await _devices.QueryOutboxAsync(record); Refresh(); DraftBox.Focus(FocusState.Programmatic); };
            row.Children.Add(check);
            var discard = new Button { Content = "Discard", FontSize = 12 };
            discard.Click += (_, _) => { _devices.DiscardOutbox(record.CommandID); Refresh(); DraftBox.Focus(FocusState.Programmatic); };
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
                    SetDraftBox();
                }
                _devices.DiscardOutbox(record.CommandID);
                Refresh();
                DraftBox.Focus(FocusState.Programmatic);
            };
            row.Children.Add(restore);
            var discard = new Button { Content = "Discard", FontSize = 12 };
            discard.Click += (_, _) => { _devices.DiscardOutbox(record.CommandID); Refresh(); DraftBox.Focus(FocusState.Programmatic); };
            row.Children.Add(discard);
        }
        else if (record.Outcome == "accepted")
        {
            var dismiss = new Button { Content = "Dismiss", FontSize = 12 };
            dismiss.Click += (_, _) => { _devices.DiscardOutbox(record.CommandID); Refresh(); DraftBox.Focus(FocusState.Programmatic); };
            row.Children.Add(dismiss);
        }
        else
        {
            var resend = new Button { Content = "Resend same ID", FontSize = 12 };
            resend.Click += async (_, _) => { await _devices.RetryOutboxAsync(record); Refresh(); DraftBox.Focus(FocusState.Programmatic); };
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

    private async void OnNewSessionClick(object sender, RoutedEventArgs e)
    {
        if (_store.Entries.Count == 0) return;
        // New session asks which provider to run: entries carry bare
        // commands resolved at spawn, so show what each resolves to and flag
        // the ones with no CLI on PATH.
        AgentEntry? chosen = null;
        ContentDialog? dialog = null;
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(new TextBlock { Text = "Start a new session with:" });
        foreach (var candidate in _store.Entries)
        {
            var resolved = FindOnPath(candidate.Command);
            var entry = candidate;
            var button = new Button
            {
                Content = candidate.Name + "  ·  " + candidate.Command
                    + (resolved is null ? "  (not found)" : "  →  " + resolved),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            button.Click += (_, _) => { chosen = entry; dialog?.Hide(); };
            panel.Children.Add(button);
        }
        dialog = new ContentDialog
        {
            Title = "New session",
            Content = new ScrollViewer { Content = panel },
            CloseButtonText = "Cancel",
            XamlRoot = Content.XamlRoot,
        };
        await dialog.ShowAsync();
        if (chosen is null) return;
        var session = _store.Create(chosen);
        var key = "local:" + session.Id;
        RefreshSidebar();
        SelectSession(new SidebarSession(key, session.Title, "", null, session.Id, ShowPark: true, ShowClose: true, ShowPlace: true), caretToEnd: true);
        DraftBox.Focus(FocusState.Programmatic);
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
        var peers = _devices.Trust.Devices.Where(d => d.DeviceID != _devices.DeviceId).ToList();
        if (peers.Count > 0)
        {
            panel.Children.Add(new TextBlock { Text = "Paired devices:" });
            foreach (var device in peers)
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

    // ---- Converse Groups dialog (mirrors Mac GroupView) ----
    private void OnGroupsClick(object sender, RoutedEventArgs e) => OpenGroupsDialog();

    private void OpenGroupsDialog()
    {
        if (_groupsPanel is not null) return;
        _groupsSignature = "";
        _groupsArmDissolve = null;
        // No fixed width: a 620px panel overflows narrower dialogs, clips
        // headers, and breaks the scroller's measure. Height caps to the
        // live window so Create/Join stay reachable; horizontal scroll stays
        // off so long names wrap or trim instead of pushing buttons out.
        var panel = new StackPanel { Spacing = 8 };
        _groupsPanel = panel;
        RenderGroupsDialog();
        var groupsScroller = new ScrollViewer
        {
            Content = panel,
            MaxHeight = Math.Max(320, Bounds.Height - 260),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        // The dialog swallows wheel routing to nested scrollers; drive it
        // directly so the wheel works like the scrollbar does.
        groupsScroller.PointerWheelChanged += (_, e) =>
        {
            e.Handled = true;
            var delta = e.GetCurrentPoint(groupsScroller).Properties.MouseWheelDelta;
            groupsScroller.ChangeView(null, groupsScroller.VerticalOffset - delta / 2, null);
        };
        var dialog = new ContentDialog
        {
            Title = "Converse Groups",
            Content = groupsScroller,
            CloseButtonText = "Done",
            XamlRoot = Content.XamlRoot,
        };
        _ = dialog.ShowAsync().AsTask().ContinueWith(_ =>
        {
            DispatcherQueue.TryEnqueue(() => _groupsPanel = null);
        });
    }

    private void AutoOpenGroups()
    {
        // New join requests surface automatically, like the Mac.
        var fresh = _devices.GroupRequests
            .Where(r => !r.Approved && r.ExpiresAt > DeviceTrustStore.AppleNow() && !_groupsSeen.Contains(r.Id)).ToList();
        foreach (var request in fresh) _groupsSeen.Add(request.Id);
        foreach (var stale in _groupsSeen.Where(id => _devices.GroupRequests.All(r => r.Id != id)).ToList())
            _groupsSeen.Remove(stale);
        if (fresh.Count > 0 && _groupsPanel is null) OpenGroupsDialog();
    }

    private void RenderGroupsDialog()
    {
        if (_groupsPanel is not { } panel) return;
        var signature = new System.Text.StringBuilder();
        signature.Append("g:").Append(_devices.CurrentGroup?.Id ?? "none");
        foreach (var pairing in _devices.GroupPairingPrompts) signature.Append("|p:").Append(pairing.PeerId).Append(pairing.Code);
        if (_devices.GroupReview is { } review) signature.Append("|r:").Append(review.Request.Id).Append(review.Code);
        foreach (var request in _devices.GroupRequests)
            signature.Append("|q:").Append(request.Id).Append(request.Approved).Append(request.RequesterName);
        foreach (var group in _devices.AvailableGroups())
            signature.Append("|a:").Append(group.Id).Append(group.Name)
                .Append(string.Join(",", _devices.GroupDevices(group).Select(d => d.DeviceID + d.Label)));
        signature.Append("|s:").Append(_devices.ServiceStatus).Append(_devices.LastOutcome).Append(_groupsArmDissolve ?? "");
        var text = signature.ToString();
        if (text == _groupsSignature) return;
        _groupsSignature = text;
        panel.Children.Clear();

        TextBlock Note(string value) => new() { Text = value, FontSize = 12, TextWrapping = TextWrapping.Wrap };
        TextBlock Mono(string value) => new()
        {
            Text = value, FontFamily = new FontFamily("Consolas"), FontSize = 14,
            IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap,
        };

        panel.Children.Add(Note(_devices.CurrentGroup is { } current
            ? "This device is in " + current.Name + "."
            : "This device is not in a group."));
        panel.Children.Add(Note("Admission through any member joins the whole group. "
            + "Compare EVERY number group on both devices; join only if all 8 match exactly. "
            + "Any member can admit or dissolve. Remote sessions are visible only while grouped."));

        var prompt = _devices.GroupPairingPrompts.FirstOrDefault();
        if (prompt is not null)
        {
            panel.Children.Add(new TextBlock { Text = "Join requested", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            panel.Children.Add(Note("Your security number — read it to the reviewing member:"));
            panel.Children.Add(Mono(prompt.Code));
            if (prompt.KeyChanged)
                panel.Children.Add(Note("Warning: stored key mismatch."));
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var pair = new Button { Content = "Pair" };
            var peerId = prompt.PeerId;
            pair.Click += async (_, _) => { await _devices.ConfirmPairing(peerId); Refresh(); };
            var cancel = new Button { Content = "Cancel" };
            cancel.Click += (_, _) => { _devices.RejectPairing(peerId); Refresh(); };
            row.Children.Add(pair);
            row.Children.Add(cancel);
            panel.Children.Add(row);
        }

        if (_devices.GroupReview is { } detail)
        {
            var code = detail.Code;
            panel.Children.Add(new TextBlock { Text = "Reviewing " + detail.Request.RequesterName, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            panel.Children.Add(Note("Compare against the number the joiner reads out. Pair only if all 8 match:"));
            panel.Children.Add(Mono(code));
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var back = new Button { Content = "Back" };
            back.Click += (_, _) => { _devices.GroupReview = null; Refresh(); };
            var pair = new Button { Content = "Pair" };
            pair.Click += async (_, _) => { await _devices.ApproveGroupReviewAsync(); Refresh(); };
            row.Children.Add(back);
            row.Children.Add(pair);
            panel.Children.Add(row);
        }

        var live = _devices.GroupRequests
            .Where(r => !r.Approved && r.ExpiresAt > DeviceTrustStore.AppleNow()).ToList();
        if (live.Count > 0)
        {
            panel.Children.Add(new TextBlock { Text = "Join requests", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            foreach (var request in live)
            {
                var row = new Grid();
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var name = new TextBlock
                {
                    Text = request.RequesterName + " wants to join",
                    VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap,
                };
                Grid.SetColumn(name, 0);
                row.Children.Add(name);
                var reviewButton = new Button { Content = "Review", FontSize = 12 };
                reviewButton.Click += async (_, _) => { await _devices.ReviewGroupRequestAsync(request); Refresh(); };
                Grid.SetColumn(reviewButton, 1);
                row.Children.Add(reviewButton);
                panel.Children.Add(row);
            }
        }

        panel.Children.Add(new TextBlock { Text = "Groups", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        foreach (var group in _devices.AvailableGroups())
        {
            // Grid, not an unbounded horizontal stack: the name trims with
            // an ellipsis and the buttons keep their space at any width.
            var header = new Grid { ColumnSpacing = 8 };
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var title = new TextBlock
            {
                Text = group.Name + (group.Id == _devices.CurrentGroup?.Id ? " (current)" : ""),
                FontWeight = Microsoft.UI.Text.FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            Grid.SetColumn(title, 0);
            header.Children.Add(title);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            Grid.SetColumn(actions, 1);
            if (group.Id == _devices.CurrentGroup?.Id)
            {
                var leave = new Button { Content = "Leave", FontSize = 12 };
                leave.Click += async (_, _) => { await _devices.LeaveGroupAsync(); Refresh(); };
                actions.Children.Add(leave);
            }
            else if (_devices.CanJoinGroup(group.Id))
            {
                var join = new Button { Content = "Join", FontSize = 12 };
                join.Click += async (_, _) => { await _devices.JoinGroupAsync(group); Refresh(); };
                actions.Children.Add(join);
            }
            var dissolve = new Button
            {
                Content = _groupsArmDissolve == group.Id ? "Confirm dissolve" : "Dissolve",
                FontSize = 12,
            };
            dissolve.Click += async (_, _) =>
            {
                // Two-step in place of a nested confirmation dialog.
                if (_groupsArmDissolve != group.Id) { _groupsArmDissolve = group.Id; _groupsSignature = ""; Refresh(); return; }
                _groupsArmDissolve = null;
                await _devices.DissolveGroupAsync(group);
                Refresh();
            };
            actions.Children.Add(dissolve);
            header.Children.Add(actions);
            panel.Children.Add(header);
            foreach (var (_, label) in _devices.GroupDevices(group))
                panel.Children.Add(new TextBlock
                {
                    Text = "    " + label, FontSize = 12, TextWrapping = TextWrapping.Wrap,
                    Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray),
                });
        }
        if (_groupsArmDissolve is not null)
            panel.Children.Add(Note("Dissolving removes every device. Press Confirm dissolve to proceed."));

        var createRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var createBox = new TextBox { PlaceholderText = "New group name", Width = 280, Text = _groupsCreateName };
        createBox.TextChanged += (_, _) => _groupsCreateName = createBox.Text;
        var create = new Button { Content = "Create Group", FontSize = 12 };
        create.Click += async (_, _) =>
        {
            await _devices.CreateGroupAsync(_groupsCreateName);
            // Clear the live box directly as well as the field: a skipped
            // re-render must never leave a stale name behind.
            createBox.Text = "";
            _groupsCreateName = "";
            _groupsSignature = "";
            Refresh();
        };
        createRow.Children.Add(createBox);
        createRow.Children.Add(create);
        panel.Children.Add(createRow);

        // Join by address needs an explicit group: a blank group ID is
        // refused by every member, so the picker names one of this device's
        // known groups (no discovery required). The sponsor path is the same
        // reviewed one discovery joins use; only the ID source differs.
        var candidates = _devices.AvailableGroups()
            .Where(g => g.Id != _devices.CurrentGroup?.Id).ToList();
        if (!candidates.Any(g => g.Id == _groupsJoinGroupId))
            _groupsJoinGroupId = candidates.FirstOrDefault()?.Id ?? "";
        var joinRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var hostBox = new TextBox { PlaceholderText = "Host or IP", Width = 160, Text = _groupsJoinHost };
        hostBox.TextChanged += (_, _) => _groupsJoinHost = hostBox.Text;
        var portBox = new TextBox { PlaceholderText = "Port", Width = 70, Text = _groupsJoinPort };
        portBox.TextChanged += (_, _) => _groupsJoinPort = portBox.Text;
        var groupBox = new ComboBox { Width = 200, FontSize = 12, PlaceholderText = "Group to join" };
        var groupItems = candidates.Select(c => new SettingItem(c.Id, c.Name)).ToList();
        if (groupItems.Count > 0) SyncCombo(groupBox, groupItems, _groupsJoinGroupId);
        groupBox.SelectionChanged += (_, _) =>
        {
            if (groupBox.SelectedItem is SettingItem picked) _groupsJoinGroupId = picked.Id;
        };
        var joinByAddress = new Button
        {
            Content = "Join by address",
            FontSize = 12,
            IsEnabled = groupItems.Count > 0,
        };
        joinByAddress.Click += async (_, _) =>
        {
            if (groupBox.SelectedItem is SettingItem picked) _groupsJoinGroupId = picked.Id;
            if (int.TryParse(_groupsJoinPort, out var port))
                await _devices.JoinGroupByAddressAsync(_groupsJoinHost, port, _groupsJoinGroupId);
            Refresh();
        };
        joinRow.Children.Add(hostBox);
        joinRow.Children.Add(portBox);
        joinRow.Children.Add(groupBox);
        joinRow.Children.Add(joinByAddress);
        panel.Children.Add(joinRow);

        if (_devices.ServiceStatus.Length > 0) panel.Children.Add(Note(_devices.ServiceStatus));
        if (_devices.LastOutcome.Length > 0) panel.Children.Add(Note(_devices.LastOutcome));
    }

    private async void OnTakeHereClick(object sender, RoutedEventArgs e)
    {
        if (_selected?.GlobalID is not { } gid) return;
        await _devices.AcquireRemoteAsync(gid);
        Refresh();
    }

    private async void OnParkClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SidebarSession row }) return;
        // Parking is view state only: the lease releases for remotes, the
        // placement clears for all, and the session keeps running at home.
        _placements.Park(row.Key);
        _placements.Save(_dataFolder);
        if (row.GlobalID is not null) await _devices.ReleaseRemoteAsync(row.GlobalID);
        if (_selected?.Key == row.Key) SelectSession(null, caretToEnd: false);
        Refresh();
    }

    // Pane slots 1-3 (Mac parity): placing focuses the session, takes the
    // lease for remotes, evicts the pane's previous occupant, and persists.
    private async void OnPlaceClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SidebarSession row, Content: string label }) return;
        if (label is not ("1" or "2" or "3")) return;
        var pane = label[0] - '0';
        _placements.Assign(row.Key, pane);
        _placements.Save(_dataFolder);
        if (_selected?.Key != row.Key) SelectSession(row, caretToEnd: true);
        if (row.GlobalID is { } gid) await _devices.AcquireRemoteAsync(gid);
        Refresh();
    }

    private void OnPaneClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: int pane }) return;
        var key = _placements.KeyIn(pane);
        if (key is null) return;
        var item = Sidebar.Items.OfType<SidebarSession>().FirstOrDefault(i => i.Key == key);
        if (item is null)
        {
            _placements.Park(key);
            _placements.Save(_dataFolder);
            Refresh();
            return;
        }
        if (_selected?.Key != key) SelectSession(item, caretToEnd: true);
        Refresh();
    }

    private void RenderPaneBar()
    {
        var keys = new HashSet<string>(Sidebar.Items.OfType<SidebarSession>().Select(i => i.Key));
        var pruned = false;
        foreach (var pane in new[] { 1, 2, 3 })
            if (_placements.KeyIn(pane) is { } parked && !keys.Contains(parked))
            {
                _placements.Park(parked);
                pruned = true;
            }
        // Mac parity (Workspace.shared.park on remote take): a local session
        // whose display lease is held by another device cannot stay on screen
        // here. Park it and clear the selection so this end goes quiet.
        foreach (var pane in new[] { 1, 2, 3 })
            if (_placements.KeyIn(pane) is { } key && key.StartsWith("local:", StringComparison.Ordinal)
                && Guid.TryParse(key["local:".Length..], out var localId)
                && _devices.DisplayHolder(localId) is { } holder && holder.Device != _devices.DeviceId)
            {
                _placements.Park(key);
                pruned = true;
                if (_selected?.Key == key) SelectSession(null, caretToEnd: false);
            }
        if (pruned) _placements.Save(_dataFolder);
        var titles = Sidebar.Items.OfType<SidebarSession>().ToDictionary(i => i.Key, i => i.Title);
        var signature = string.Join("|", new[] { 1, 2, 3 }.Select(pane =>
            pane + "=" + (_placements.KeyIn(pane) ?? "-") + "~"
            + (titles.GetValueOrDefault(_placements.KeyIn(pane) ?? "") ?? "")))
            + "|focus=" + (_selected?.Key ?? "-");
        if (signature == _paneSignature) return;
        _paneSignature = signature;
        PaneBar.Children.Clear();
        foreach (var pane in new[] { 1, 2, 3 })
        {
            var key = _placements.KeyIn(pane);
            var title = key is not null && titles.TryGetValue(key, out var found) ? found : "—";
            if (title.Length > 18) title = title[..17] + "…";
            var slot = new Button
            {
                Content = pane + ": " + title,
                Tag = pane,
                FontSize = 11,
                FontWeight = key is not null && key == _selected?.Key
                    ? Microsoft.UI.Text.FontWeights.SemiBold
                    : Microsoft.UI.Text.FontWeights.Normal,
            };
            Microsoft.UI.Xaml.Controls.ToolTipService.SetToolTip(slot,
                key is null ? "Empty pane" : titles.GetValueOrDefault(key) ?? "");
            slot.Click += OnPaneClick;
            PaneBar.Children.Add(slot);
        }
    }

    private async void OnSendClick(object sender, RoutedEventArgs e)
    {
        var text = _draftText.Replace("\r", "\n");
        if (string.IsNullOrWhiteSpace(text) || _selected is null || !InputAllowed()) return;
        _notice = null;
        _noticeUtc = null;
        if (_selected.LocalSessionID is { } localId)
        {
            var session = _store.Sessions.FirstOrDefault(s => s.Id == localId);
            if (session is null) return;
            session.Draft = text;
            _draftText = "";
            _store.Submit(session);
            // A busy submit changes no history, so RenderPane would skip the
            // sync and the sent text would linger in the draft, inviting a
            // duplicate send. Clear the box now; the refresh below no-ops.
            SetDraftBox();
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
        DraftBox.Focus(FocusState.Programmatic);
    }

    private async void OnStopClick(object sender, RoutedEventArgs e)
    {
        _notice = null;
        _noticeUtc = null;
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
