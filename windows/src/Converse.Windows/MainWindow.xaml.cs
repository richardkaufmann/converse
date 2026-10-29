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
    // Last settled viewport offset, tracked outside rebuilds: back-to-back
    // rebuilds (turn finish + queued auto-start in one tick) must restore
    // the pre-reset position, not the reset top the previous SetText left.
    private double _lastStableOffset;
    private ulong _rebuildSeq;
    private ulong _appliedSeq;
    private string _sidebarSignature = "";
    private string _bannerSignature = "";
    private bool _suppressSettings;
    private bool _modelEditing;
    private ScrollViewer? _transcriptScroller;
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
    // Round-16 single source of truth for scrolling: every programmatic
    // ChangeView goes through OwnChangeView, which counts it. ViewChanged
    // consumes one count per finished event and adopts the position without
    // touching the idle clock. Any uncounted change is the user, even
    // mid-rebuild; only the SetText reset to the top is layout noise.
    private int _ownScrolls;
    // What the document actually holds (readback is unreliable: trailing
    // breaks collapse). The append path absorbs history that extends this
    // prefix; anything else takes the full rebuild.
    private string? _renderedHistory;
    private string _renderedDraft = "";
    // Streaming rebuild coalescing (round-13 crash stack dies inside a
    // per-token full rebuild): while the shown session works, history
    // rebuilds run at most every 200ms with one trailing catch-up.
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

    // Builds the protected history text for the selected conversation, the
    // character ranges that render as italic user turns, the chat-markdown
    // runs (bold/code/headings) inside assistant turns, and how many earlier
    // messages the local cap hides (remote paging comes from home instead).
    // Markdown strips before break normalization, which is length-preserving,
    // so run offsets stay valid in the final document coordinates.
    // Message ranges backing the Copy Prompt / Copy Response menu: document
    // offsets of each rendered message plus its role and source text.
    private List<(int Start, int Length, string Role, string Text)> _lastMessageRanges = new();
    // Start offset of the last rendered message: the planner absorbs any
    // divergence at or after it and takes the full rebuild above it.
    private int _lastMessageStart;
    // User-run ranges from the latest BuildHistory, so the gutter never pays
    // for a second full pass per rebuild.
    private List<(int Start, int Length)> _lastUserRuns = new();

    private (string History, List<(int Start, int Length)> UserRuns,
        List<(int Start, int Length, MdRunKind Kind, int Level)> MdRuns, int Hidden) BuildHistory()
    {
        var runs = new List<(int Start, int Length)>();
        var mdRuns = new List<(int Start, int Length, MdRunKind Kind, int Level)>();
        _lastMessageRanges = new List<(int Start, int Length, string Role, string Text)>();
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
        if (lines is null)
        {
            _lastMessageStart = 0;
            _lastUserRuns = runs;
            return ("", runs, mdRuns, 0);
        }
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
                // Mac parity: submitted turns carry no "You:" label (they
                // render italic, like the Mac's prompt styling).
                var start = text.Length;
                var rendered = Breaks(body);
                text.Append(rendered).Append("\r\r");
                runs.Add((start, rendered.Length));
                _lastMessageRanges.Add((start, rendered.Length, "user", body));
                _lastMessageStart = start;
            }
            else
            {
                var flat = body.Replace("\r\n", "\n").Replace('\r', '\n');
                var (plain, md) = MarkdownRuns.Render(flat);
                var broken = plain.Replace("\n", "\r");
                var start = text.Length;
                text.Append(broken).Append("\r\r");
                foreach (var run in md)
                    mdRuns.Add((start + run.Start, run.Length, run.Kind, run.Level));
                _lastMessageRanges.Add((start, broken.Length, "assistant", body));
                _lastMessageStart = start;
            }
        }
        // Lone surrogates never reach WinRT string marshalling (round-13
        // crash stack); the 1:1 scrub keeps every run offset valid.
        _lastUserRuns = runs;
        return (MarkdownRuns.SanitizeLoneSurrogates(text.ToString()), runs, mdRuns, hidden);
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
            ModelBox.IsEnabled = EffortBox.IsEnabled = AccessBox.IsEnabled = false; // WinUI 3 panels have no IsEnabled
            TakeButton.Visibility = Visibility.Collapsed;
            BusyRing.IsActive = false;
            // Always rebuild: the cleared state may equal the tracked state
            // while the document still shows the old session, greyed out.
            _historyText = "";
            _draftText = "";
            RebuildDocument(caretToEnd: true);
            RenderBanners();
            UpdateEarlier();
            UpdateHint();
            return;
        }
        PaneTitle.Text = _selected.Title;
        // Adopt the home draft only into an untouched tail; never over typing.
        // Stored drafts use \n; the document uses \r, so normalize on adopt —
        // otherwise the gutter, tint, and sent-text comparison all skew.
        var homeDraft = _selected.LocalSessionID is { } localId
            ? _store.Sessions.FirstOrDefault(s => s.Id == localId)?.Draft ?? ""
            : _devices.RemoteTranscripts.GetValueOrDefault(_selected.GlobalID ?? "")?.Draft ?? "";
        if (_draftText == "" && homeDraft != "" && homeDraft != _lastSentText) _draftText = Breaks(homeDraft);
        // A remote draft clears only after its exact sent text is acknowledged.
        if (_selected.GlobalID is not null && _lastSentText is not null && homeDraft == "" && _draftText == Breaks(_lastSentText))
        {
            _draftText = "";
            _lastSentText = null;
            _remoteHashes.Remove(_selected.GlobalID);
        }
        var (history, _, _, hidden) = BuildHistory();
        _hiddenLocal = _selected.LocalSessionID is not null ? hidden : 0;
        if (history != _historyText)
        {
            _historyText = history;
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
                            RebuildDocument(caretToEnd: false);
                        };
                    }
                    _rebuildTimer.Interval = TimeSpan.FromMilliseconds(200);
                    _rebuildTimer.Start();
                }
            }
            else
            {
                _lastStreamRebuildUtc = DateTime.UtcNow;
                RebuildDocument(caretToEnd: false);
            }
        }
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
        Transcript.IsEnabled = allowed;
        SendButton.IsEnabled = allowed;
        StopButton.IsEnabled = allowed;
        AttachButton.IsEnabled = allowed;
        ModelBox.IsEnabled = EffortBox.IsEnabled = AccessBox.IsEnabled = allowed; // WinUI 3 panels have no IsEnabled
        var showTake = _selected?.GlobalID is string gid
            && (!_devices.RemoteLeases.ContainsKey(gid) || _devices.RemoteOffline.Contains(gid));
        TakeButton.Visibility = showTake ? Visibility.Visible : Visibility.Collapsed;
        if (showTake && DeviceGlobalID.Parse(_selected!.GlobalID!) is { } parsed)
            TakeButton.IsEnabled = _devices.Homes.GetValueOrDefault(parsed.Home)?.Online == true;
        Transcript.PlaceholderText = _selected is null ? "Select a conversation to begin." : "";
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

    // Round-16 crash fix, round-18 correction: absorb history at the common
    // prefix without whole-document SetText (the dumps pin SetText as the
    // faulting call). Streaming text lands before the trailing separator, so
    // the absorb point sits inside the last message: the tail from there is
    // replaced and reformatted, never the whole document. A parked reader
    // gets no scroll, no caret move, no selection touch. Returns false
    // (caller takes the full path) on anything unexpected.
    private bool TryReplaceFrom(
        int p,
        string rendered,
        List<(int Start, int Length)> runs,
        List<(int Start, int Length, MdRunKind Kind, int Level)> mdRuns,
        int selStart, int selEnd, bool wasAtEnd, bool nearBottom, bool caretToEnd)
    {
        var newH = _historyText.Length;
        // Never move the caret programmatically unless following the tail.
        // A parked selection keeps its position, shifted past the growth
        // above it; the tail is reserved for following.
        var pinned = selEnd > selStart && !caretToEnd;
        var follow = caretToEnd || (wasAtEnd && nearBottom && !pinned);
        if (!follow && _userScrollUtc is { } lastLook
            && (DateTime.UtcNow - lastLook).TotalSeconds > 5)
            follow = true; // idle resume, same rule as the full path
        if (newH != rendered.Length)
        {
            Transcript.Document.GetRange(p, rendered.Length)
                .SetText(TextSetOptions.None, _historyText.Substring(p));
            // Replaced paragraphs get the locked pitch like the full path.
            var fresh = Transcript.Document.GetRange(p, newH);
            fresh.ParagraphFormat.SpaceBefore = 0;
            fresh.ParagraphFormat.SpaceAfter = 0;
            fresh.ParagraphFormat.SetLineSpacing(LineSpacingRule.Exactly, 18);
            fresh.CharacterFormat.Italic = FormatEffect.Off;
            fresh.CharacterFormat.BackgroundColor = Windows.UI.Color.FromArgb(0, 0, 0, 0);
            foreach (var (start, runLength) in runs)
            {
                var e = start + runLength;
                if (e <= p) continue;
                var s = Math.Clamp(Math.Max(start, p), 0, newH);
                var end = Math.Clamp(e, 0, newH);
                if (end > s) Transcript.Document.GetRange(s, end).CharacterFormat.Italic = FormatEffect.On;
            }
            foreach (var (start, runLength, kind, _) in mdRuns)
            {
                var e = start + runLength;
                if (e <= p) continue;
                var s = Math.Clamp(Math.Max(start, p), 0, newH);
                var end = Math.Clamp(e, 0, newH);
                if (end <= s) continue;
                var format = Transcript.Document.GetRange(s, end).CharacterFormat;
                // Twin of the full-path switch below; keep the two in sync.
                switch (kind)
                {
                    case MdRunKind.Bold:
                    case MdRunKind.Heading:
                        format.Bold = FormatEffect.On;
                        break;
                    case MdRunKind.Code:
                        format.BackgroundColor = Windows.UI.Color.FromArgb(28, 127, 127, 127);
                        break;
                    default:
                        format.Name = "Consolas";
                        format.BackgroundColor = Windows.UI.Color.FromArgb(28, 127, 127, 127);
                        break;
                }
            }
        }
        if (_draftText != _renderedDraft)
        {
            Transcript.Document.GetRange(newH, newH + _renderedDraft.Length)
                .SetText(TextSetOptions.None, _draftText);
            if (_draftText.Length > 0)
            {
                var draft = Transcript.Document.GetRange(newH, newH + _draftText.Length);
                draft.CharacterFormat.ForegroundColor = Microsoft.UI.Colors.Blue;
                draft.CharacterFormat.Italic = FormatEffect.Off;
            }
        }
        var trackedEnd = newH + _draftText.Length;
        if (follow) Transcript.Document.Selection.SetRange(trackedEnd, trackedEnd);
        else
        {
            // Positions before the absorb point are untouched. Old-draft
            // positions shift past the new tail. Positions inside the
            // rewritten span clamp to its start: their text is new.
            int Map(int pos) => pos < p ? pos
                : pos >= rendered.Length
                    ? Math.Min(newH + Math.Min(pos - rendered.Length, _draftText.Length), trackedEnd)
                    : Math.Min(p, trackedEnd);
            Transcript.Document.Selection.SetRange(Map(selStart), Map(selEnd));
        }
        if (follow)
        {
            _unreadUpdates = 0;
            if (TranscriptScroller() is { } scroller) OwnChangeView(scroller, scroller.ScrollableHeight);
            UpdateJumpButton(following: true);
        }
        else
        {
            if (!_historyText.Equals(rendered, StringComparison.Ordinal)) _unreadUpdates++;
            UpdateJumpButton(following: false);
        }
        _renderedHistory = _historyText;
        _renderedDraft = _draftText;
        return true;
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
            Transcript.Document.GetText(TextGetOptions.None, out var oldFull);
            var scrollerBefore = TranscriptScroller();
            var oldScrollable = scrollerBefore?.ScrollableHeight ?? 0;
            var liveBefore = scrollerBefore?.VerticalOffset ?? 0;
            // Following means caret AND viewport at the tail (Mac: 200px).
            // A caret-only test drags mid-stream scrollers back down.
            var nearBottom = scrollerBefore is null || scrollerBefore.ScrollableHeight - liveBefore < 200;
            var oldHistoryLength = Math.Max(0, oldDocLength - _draftText.Length);
            var selection = Transcript.Document.Selection;
            var wasAtEnd = selection.StartPosition >= oldDocLength && selection.EndPosition >= oldDocLength;
            var draftRelative = selection.StartPosition >= oldHistoryLength ? selection.StartPosition - oldHistoryLength : (int?)null;
            var draftLength = selection.EndPosition > selection.StartPosition
                ? Math.Min(selection.Length, Math.Max(0, _draftText.Length - (draftRelative ?? 0))) : 0;

            // Crash mitigation (crash12/ dumps): never let RichEdit lay out a
            // half-formatted document. Everything between SetText and the
            // matching Apply in finally paints as one update.
            Transcript.Document.BatchDisplayUpdates();
            // Formatting runs are pure session state, computed before any
            // mutation so both the append and full paths share them.
            var (_, runs, mdRuns, _) = BuildHistory();
            // Round-16 crash fix, round-18 correction: absorb at the common
            // prefix without whole-document SetText (the dumps pin SetText
            // as the faulting call). Anything unexpected falls through to
            // the full path, which resets the trackers it relies on. Full
            // rebuilds while streaming are logged to rebuild-fallback.log
            // beside the exe so the VM can count them without a dump.
            var (historyOp, absorbAt) = TranscriptHistory.Plan(_renderedHistory, _historyText, _lastMessageStart);
            if (historyOp == HistoryOp.Full)
            {
                if (SelectedBusy()) LogFallback("full-while-busy");
            }
            else
            {
                try
                {
                    if (TryReplaceFrom(absorbAt, _renderedHistory!, runs, mdRuns,
                        selection.StartPosition, selection.EndPosition, wasAtEnd, nearBottom, caretToEnd))
                    {
                        UpdateGutter();
                        return;
                    }
                    if (SelectedBusy()) LogFallback("replace-catch");
                }
                catch { if (SelectedBusy()) LogFallback("replace-catch"); /* fall through below */ }
            }
            Transcript.Document.SetText(TextSetOptions.None, _historyText + _draftText);
            // Locked row pitch: every paragraph is exactly 18pt (= 24px, the
            // gutter TextBlock's LineHeight), so editor rows and gutter rows
            // cannot drift apart no matter how long the transcript gets.
            // 24px leaves headroom over the ~19px a 16px line needs, so
            // fallback glyphs (emoji etc.) don't clip. Both controls run
            // zero top padding so row 1 starts at the same offset.
            // Known limit: wrapped editor lines have no gutter counterpart;
            // the gutter counts paragraphs, like an outline margin.
            var whole = Transcript.Document.GetRange(0, CurrentDocLength());
            whole.ParagraphFormat.SpaceBefore = 0;
            whole.ParagraphFormat.SpaceAfter = 0;
            whole.ParagraphFormat.SetLineSpacing(LineSpacingRule.Exactly, 18); // WinUI 3: both properties are read-only
            // Mac parity: submitted user turns render italic, everything
            // else upright. RichEdit paragraph marks inherit the preceding
            // run's format, so one italic run otherwise infects every
            // following paragraph: pin the document upright first, apply
            // user italics, then pin the complement upright again.
            whole.CharacterFormat.Italic = FormatEffect.Off;
            var docEnd = CurrentDocLength();
            foreach (var (start, runLength) in runs)
            {
                var s = Math.Clamp(start, 0, docEnd);
                var e = Math.Clamp(start + runLength, 0, docEnd);
                if (e > s) Transcript.Document.GetRange(s, e).CharacterFormat.Italic = FormatEffect.On;
            }
            var cursor = 0;
            foreach (var (start, runLength) in runs)
            {
                var s = Math.Clamp(start, 0, docEnd);
                if (s > cursor) Transcript.Document.GetRange(cursor, s).CharacterFormat.Italic = FormatEffect.Off;
                cursor = Math.Max(cursor, Math.Clamp(start + runLength, 0, docEnd));
            }
            if (cursor < docEnd) Transcript.Document.GetRange(cursor, docEnd).CharacterFormat.Italic = FormatEffect.Off;
            // Chat markdown inside assistant turns: bold spans and headings
            // bold on, code spans get a translucent grey wash that reads in
            // both themes. Sizes stay untouched so the locked line pitch
            // never clips. Assistant turns are upright, so no italic
            // interaction; ranges clamp like the user runs above.
            foreach (var (start, runLength, kind, level) in mdRuns)
            {
                var s = Math.Clamp(start, 0, docEnd);
                var e = Math.Clamp(start + runLength, 0, docEnd);
                if (e <= s) continue;
                var format = Transcript.Document.GetRange(s, e).CharacterFormat;
                switch (kind)
                {
                    case MdRunKind.Bold:
                    case MdRunKind.Heading:
                        format.Bold = FormatEffect.On;
                        break;
                    case MdRunKind.Code:
                        format.BackgroundColor = Windows.UI.Color.FromArgb(28, 127, 127, 127);
                        break;
                    default:
                        // Pipe tables: monospace so space-padded columns
                        // align (RichEdit has no real tables), divider row
                        // already dropped by the parser.
                        format.Name = "Consolas";
                        format.BackgroundColor = Windows.UI.Color.FromArgb(28, 127, 127, 127);
                        break;
                }
            }
            if (_draftText.Length > 0)
            {
                // Tail-measured: the history region may read back shorter
                // than _historyText when trailing breaks collapse.
                var docLength = CurrentDocLength();
                var draft = Transcript.Document.GetRange(
                    Math.Max(0, docLength - _draftText.Length), docLength);
                draft.CharacterFormat.ForegroundColor = Microsoft.UI.Colors.Blue;
                draft.CharacterFormat.Italic = FormatEffect.Off;
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
            // Deferred past layout at low priority, so selection auto-scroll
            // settles first: SetText parks the viewport at the top while
            // SetRange alone does not reliably scroll back. Every branch
            // restores its scroll target here: the tail when following, the
            // preserved offset otherwise (shifted when earlier messages were
            // prepended above). Only the newest rebuild in a tick owns the
            // viewport; a user scroll mid-rebuild wins over the restore. The
            // gutter resyncs in the same tick: syncing it synchronously
            // reads the pre-scroll offset and leaves stale numbers beside
            // fresh paragraphs.
            var selectionPinned = Transcript.Document.Selection.Length > 0 && !caretToEnd;
            var followTail = caretToEnd || (wasAtEnd && nearBottom && !selectionPinned);
            var appended = (_historyText + _draftText).StartsWith(oldFull ?? "", StringComparison.Ordinal);
            if (!followTail && appended && !selectionPinned && _userScrollUtc is { } lastLook
                && (DateTime.UtcNow - lastLook).TotalSeconds > 5)
                followTail = true; // idle resume: quiet looking rejoins new arrivals
            // Unread updates count output that arrives while parked (Mac
            // parity); typing never rebuilds, so a parked miss is real news.
            if (followTail) _unreadUpdates = 0;
            else _unreadUpdates++;
            // Synchronous restore: SetText parks the viewport at the top,
            // and the deferred pass below runs after paint — without this,
            // every streamed token flashes the top before jumping back (the
            // jerk). ChangeView clamps against the stale layout; the
            // deferred pass still corrects to the exact target.
            if (TranscriptScroller() is { } syncScroller)
            {
                if (followTail) OwnChangeView(syncScroller, syncScroller.ScrollableHeight);
                else
                {
                    var liveSync = syncScroller.VerticalOffset;
                    if (liveSync > 1 && Math.Abs(liveSync - _lastStableOffset) > 1)
                        _lastStableOffset = liveSync;
                    else
                    {
                        var syncDelta = appended ? 0 : Math.Max(0, syncScroller.ScrollableHeight - oldScrollable);
                        OwnChangeView(syncScroller, Math.Max(0, _lastStableOffset + syncDelta));
                    }
                }
            }
            UpdateJumpButton(followTail);
            var seq = ++_rebuildSeq;
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                if (seq != _rebuildSeq) return;
                if (TranscriptScroller() is not { } scroller) return;
                if (followTail)
                {
                    ScrollTranscriptToEnd();
                    UpdateJumpButton(following: true);
                }
                else
                {
                    // Untouched resets sit at ~0; anything else moved by hand.
                    var liveNow = scroller.VerticalOffset;
                    if (liveNow > 1 && Math.Abs(liveNow - _lastStableOffset) > 1)
                        _lastStableOffset = liveNow;
                    else
                    {
                        var delta = appended ? 0 : Math.Max(0, scroller.ScrollableHeight - oldScrollable);
                        OwnChangeView(scroller, Math.Max(0, _lastStableOffset + delta));
                    }
                }
                // The gutter has one driver only: OnTranscriptViewChanged.
                // A second copy here races it and the numbers lag the text.
                _appliedSeq = seq;
            });
            // The full path rewrites everything: re-anchor the trackers the
            // append path relies on.
            _renderedHistory = _historyText;
            _renderedDraft = _draftText;
            UpdateGutter();
        }
        finally { try { Transcript.Document.ApplyDisplayUpdates(); } catch { /* already applied */ } _rebuilding = false; }
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
        if (sender is not ScrollViewer scroller) return;
        if (_layout.ShowLineNumbers)
            GutterScroller.ChangeView(null, scroller.VerticalOffset, null, true);
        var offset = scroller.VerticalOffset;
        // Counted programmatic scroll: adopt the position, never the clock.
        // Intermediate frames share the count without consuming it. Anything
        // uncounted is the user, even mid-rebuild; only the SetText reset to
        // the top is layout noise, not the user.
        if (_ownScrolls > 0)
        {
            _lastStableOffset = offset;
            if (!e.IsIntermediate) _ownScrolls--;
            return;
        }
        if (_rebuilding && offset < 1) return;
        _lastStableOffset = offset;
        _userScrollUtc = DateTime.UtcNow;
        UpdateJumpButton(following: offset >= scroller.ScrollableHeight - 200);
    }

    private void UpdateJumpButton(bool following)
    {
        JumpLatestButton.Content = _unreadUpdates == 0
            ? "↓ Latest" : $"↓ Latest ({_unreadUpdates} new)";
        var scrollable = TranscriptScroller()?.ScrollableHeight ?? 0;
        JumpLatestButton.Visibility = !following && scrollable > 200
            ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnCopyClick(object sender, RoutedEventArgs e)
    {
        try { Transcript.Document.Selection.Copy(); } catch { /* clipboard busy: keyboard copy still works */ }
        Transcript.Focus(FocusState.Programmatic);
    }

    private void OnSelectAllClick(object sender, RoutedEventArgs e)
    {
        Transcript.Document.Selection.SetRange(0, CurrentDocLength());
        Transcript.Focus(FocusState.Programmatic);
    }

    // Whole-message copy: the menu opens at the caret, and a right click
    // moves the caret to the pointer, so the selection start identifies the
    // message. Cut/Paste are deliberately absent — history is protected, so
    // Cut would only be reverted, and Paste belongs at the draft tail.
    private string _contextMessage = "";

    private void OnContextMenuOpening(object sender, object e)
    {
        var offset = Transcript.Document.Selection.StartPosition;
        var hit = _lastMessageRanges.FirstOrDefault(r => offset >= r.Start && offset < r.Start + r.Length);
        if (hit.Text is null)
        {
            CopyMessageItem.Visibility = Visibility.Collapsed;
            CopyMessageSeparator.Visibility = Visibility.Collapsed;
            return;
        }
        CopyMessageItem.Text = hit.Role == "user" ? "Copy Prompt" : "Copy Response";
        _contextMessage = MarkdownRuns.SanitizeLoneSurrogates(hit.Text);
        CopyMessageItem.Visibility = Visibility.Visible;
        CopyMessageSeparator.Visibility = Visibility.Visible;
    }

    private void OnCopyMessageClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(_contextMessage);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
        }
        catch { /* clipboard busy: keyboard copy still works */ }
        Transcript.Focus(FocusState.Programmatic);
    }

    private void OnJumpLatestClick(object sender, RoutedEventArgs e)
    {
        _userScrollUtc = DateTime.UtcNow;
        _unreadUpdates = 0;
        UpdateJumpButton(following: true);
        ScrollTranscriptToEnd();
        Transcript.Focus(FocusState.Programmatic);
    }

    // Counts full rebuilds that fire while the shown session works, to a
    // log beside the exe. The VM tails it instead of dumping: any nonzero
    // count means the incremental path missed and SetText ran hot again.
    private void LogFallback(string reason)
    {
        try
        {
            var path = System.IO.Path.Combine(AppContext.BaseDirectory, "rebuild-fallback.log");
            System.IO.File.AppendAllText(path,
                $"{DateTime.UtcNow:o} session={_selected?.Key} reason={reason} historyLen={_historyText.Length}\n");
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
        var scroller = TranscriptScroller();
        if (scroller is null) return;
        if (Math.Abs(scroller.ScrollableHeight - scroller.VerticalOffset) > 1) _ownScrolls++;
        scroller.ChangeView(null, scroller.ScrollableHeight, null);
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
        // User runs come from the latest BuildHistory via the shared field:
        // a second full pass per rebuild kept the UI thread hot every chunk.
        foreach (var (start, _) in _lastUserRuns)
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
        // No same-tick drive: the gutter extent is stale until layout
        // settles, so driving here parks the numbers short (the round-16
        // freeze). OnTranscriptViewChanged is the only driver; every
        // transcript scroll event re-syncs against the live offset.
    }

    private void OnLineNumbersToggled(object sender, RoutedEventArgs e)
    {
        _layout.ShowLineNumbers = LineNumbersBox.IsChecked == true;
        _layout.Save(_dataFolder);
        UpdateGutter();
        // Toggle-on while scrolled: one post-layout nudge, since no scroll
        // event fires to carry the single-driver sync.
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            if (TranscriptScroller() is { } scroller)
                GutterScroller.ChangeView(null, scroller.VerticalOffset, null, true);
        });
    }

    private void OnTranscriptTextChanged(object sender, RoutedEventArgs e)
    {
        if (_rebuilding || _selected is null) return;
        Transcript.Document.GetText(TextGetOptions.None, out var full);
        full = full.Replace("\r\n", "\r");
        // The post-change caret disambiguates seam deletions strings alone
        // cannot (a masked history-tail deletion settles inside the core).
        var (ok, draft) = EditorBoundary.Split(full, _historyText, Transcript.Document.Selection.StartPosition);
        if (!ok)
        {
            // Edit touched protected history: revert and park the caret at
            // the end. The document no longer matches the trackers, so the
            // append path is blind — force the full rebuild that repairs it.
            _renderedHistory = null;
            RebuildDocument(caretToEnd: true);
            return;
        }
        if (draft == _draftText) return;
        _draftText = draft;
        // Round-16 ghost fix: the typed tail lives only in the document, so
        // the render trackers must follow the typing, not just rebuilds.
        // Otherwise a send (history append, empty draft) sees rendered and
        // actual drafts both empty and leaves the typed text on screen.
        _renderedDraft = draft;
        // The tail the user just typed is always blue (tail-measured so
        // collapsed history breaks cannot shift the range off the draft).
        var docLength = CurrentDocLength();
        var range = Transcript.Document.GetRange(Math.Max(0, docLength - _draftText.Length), docLength);
        range.CharacterFormat.ForegroundColor = Microsoft.UI.Colors.Blue;
        range.CharacterFormat.Italic = FormatEffect.Off;
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
        // A new document starts unwritten: the next rebuild must SetText.
        _renderedHistory = null;
        _renderedDraft = "";
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
        Transcript.Focus(FocusState.Programmatic);
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
        Transcript.Focus(FocusState.Programmatic);
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
                Transcript.Focus(FocusState.Programmatic);
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
            Transcript.Focus(FocusState.Programmatic);
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
            Transcript.Focus(FocusState.Programmatic);
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
                Transcript.Focus(FocusState.Programmatic);
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
            check.Click += async (_, _) => { await _devices.QueryOutboxAsync(record); Refresh(); Transcript.Focus(FocusState.Programmatic); };
            row.Children.Add(check);
            var discard = new Button { Content = "Discard", FontSize = 12 };
            discard.Click += (_, _) => { _devices.DiscardOutbox(record.CommandID); Refresh(); Transcript.Focus(FocusState.Programmatic); };
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
                Transcript.Focus(FocusState.Programmatic);
            };
            row.Children.Add(restore);
            var discard = new Button { Content = "Discard", FontSize = 12 };
            discard.Click += (_, _) => { _devices.DiscardOutbox(record.CommandID); Refresh(); Transcript.Focus(FocusState.Programmatic); };
            row.Children.Add(discard);
        }
        else if (record.Outcome == "accepted")
        {
            var dismiss = new Button { Content = "Dismiss", FontSize = 12 };
            dismiss.Click += (_, _) => { _devices.DiscardOutbox(record.CommandID); Refresh(); Transcript.Focus(FocusState.Programmatic); };
            row.Children.Add(dismiss);
        }
        else
        {
            var resend = new Button { Content = "Resend same ID", FontSize = 12 };
            resend.Click += async (_, _) => { await _devices.RetryOutboxAsync(record); Refresh(); Transcript.Focus(FocusState.Programmatic); };
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
            // rebuild and the sent text would linger in the editor, inviting
            // a duplicate send. Rebuild now; the refresh below no-ops.
            RebuildDocument(caretToEnd: true);
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
