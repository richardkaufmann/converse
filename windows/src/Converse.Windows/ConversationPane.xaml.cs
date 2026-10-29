using Converse.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using System.Text.Json.Nodes;
using WinRT.Interop;

namespace Converse.App;

// One visible conversation: transcript blocks, draft tail, banners and
// settings for a single placed session. MainWindow hosts up to three of
// these side by side (Mac WorkspacePanes parity) and owns the sidebar,
// services, placements, and dialogs. All per-pane state lives here; the
// host only assigns sessions, tracks focus, and routes refresh.
public sealed partial class ConversationPane : UserControl
{
    private MainWindow _host = null!;
    private int _pane;
    private SidebarSession? _selected;

    public ConversationPane()
    {
        InitializeComponent();
    }

    internal int Pane => _pane;

    internal SidebarSession? Current => _selected;

    internal void Attach(MainWindow host, int pane)
    {
        _host = host;
        _pane = pane;
        PaneBadge.Content = pane > 0 ? pane.ToString() : "\u2014";
        PaneBadge.Visibility = pane > 0 ? Visibility.Visible : Visibility.Collapsed;
        SyncLineNumbersBox();
    }

    // The numbers checkbox mirrors the shared layout pref in every pane.
    // Programmatic syncs must not retrigger the toggle handler.
    private bool _syncingBox;

    internal void SyncLineNumbersBox()
    {
        _syncingBox = true;
        try { LineNumbersBox.IsChecked = _host.Layout.ShowLineNumbers; }
        finally { _syncingBox = false; }
    }

    internal void FocusDraft() => DraftBox.Focus(FocusState.Programmatic);

    internal void SetFocused(bool focused)
    {
        PaneBadge.Background = focused
            ? new SolidColorBrush(Microsoft.UI.Colors.SteelBlue)
            : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        PaneBadge.Foreground = focused
            ? new SolidColorBrush(Microsoft.UI.Colors.White)
            : new SolidColorBrush(Microsoft.UI.Colors.Gray);
    }

    private void OnBadgeClick(object sender, RoutedEventArgs e)
    {
        _host.FocusPane(this);
        DraftBox.Focus(FocusState.Programmatic);
    }

    private void OnPanePointerPressed(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        _host.FocusPane(this);
    }

    private void OnDraftGotFocus(object sender, RoutedEventArgs e) => _host.FocusPane(this);

    // RichEdit paragraph breaks are single \r in both directions.
    private static string Breaks(string text) => text.Replace("\r\n", "\r").Replace("\n", "\r");

    private const string DefaultHint = "Type at the end in blue. Return sends or queues · Ctrl+Return for newline";


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


    // Visible transcript lines for the selected conversation with the local
    // cap applied (remote paging comes from home instead). Hidden messages
    // are counted so the message numbers stay continuous with what paging
    // hid — every visible message is numbered, prompts and responses.
    private (List<(string Role, string Text)> Lines, int Hidden) VisibleLines()
    {
        List<(string Role, string Text)>? lines = null;
        if (_selected?.LocalSessionID is { } localId)
            lines = _host.Store.Sessions.FirstOrDefault(s => s.Id == localId)?.Messages
                .Where(m => m.Role is "user" or "assistant" && !string.IsNullOrEmpty(m.Text))
                .Select(m => (m.Role, m.Text)).ToList();
        else if (_selected?.GlobalID is { } globalId)
            lines = _host.Devices.RemoteTranscripts.GetValueOrDefault(globalId)?.Messages
                .Where(m => m.Role is "user" or "assistant" && !string.IsNullOrEmpty(m.Text))
                .Select(m => (m.Role, m.Text)).ToList();
        if (lines is null) return (new List<(string Role, string Text)>(), 0);
        var cap = _selected?.LocalSessionID is not null ? _localCap : lines.Count;
        var hidden = Math.Max(0, lines.Count - cap);
        if (hidden > 0) lines = lines.Skip(hidden).ToList();
        return (lines, hidden);
    }


    internal void RenderPane(bool caretToEnd = false)
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
            ? _host.Store.Sessions.FirstOrDefault(s => s.Id == localId)?.Draft ?? ""
            : _host.Devices.RemoteTranscripts.GetValueOrDefault(_selected.GlobalID ?? "")?.Draft ?? "";
        if (_draftText == "" && homeDraft != "" && homeDraft != _lastSentText)
        {
            _draftText = Breaks(homeDraft);
            SetDraftBox();
        }
        // A remote draft clears only after its exact sent text is acknowledged.
        // A draft clears once its exact sent text is acknowledged (remote)
        // or consumed (local submit clears synchronously). Either way the
        // sent text never re-adopts into the tail.
        if (_lastSentText is not null && homeDraft == "" && _draftText == Breaks(_lastSentText))
        {
            _draftText = "";
            _lastSentText = null;
            _host.RemoteHashes.Remove(_selected.GlobalID);
            SetDraftBox();
        }
        var (lines, hidden) = VisibleLines();
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
                            var (fresh, freshHidden) = VisibleLines();
                            SyncLines(fresh, freshHidden, caretToEnd: false);
                        };
                    }
                    _rebuildTimer.Interval = TimeSpan.FromMilliseconds(200);
                    _rebuildTimer.Start();
                }
            }
            else
            {
                _lastStreamRebuildUtc = DateTime.UtcNow;
                SyncLines(lines, hidden, caretToEnd);
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
            return _host.Store.Sessions.FirstOrDefault(s => s.Id == localId)?.Busy == true;
        if (_selected?.GlobalID is { } globalId)
            return _host.Devices.RemoteTranscripts.GetValueOrDefault(globalId)?.Busy == true;
        return false;
    }


    // Mac parity: remote input needs a live display lease on an online home.
    // Without one the editor locks and Take here is the way back in; local
    // sessions (busy or idle) always accept typing and queue while busy.
    private bool InputAllowed()
    {
        if (_selected?.LocalSessionID is not null) return true;
        if (_selected?.GlobalID is string gid)
            return _host.Devices.RemoteLeases.ContainsKey(gid) && !_host.Devices.RemoteOffline.Contains(gid);
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
            && (!_host.Devices.RemoteLeases.ContainsKey(gid) || _host.Devices.RemoteOffline.Contains(gid));
        TakeButton.Visibility = showTake ? Visibility.Visible : Visibility.Collapsed;
        if (showTake && DeviceGlobalID.Parse(_selected!.GlobalID!) is { } parsed)
            TakeButton.IsEnabled = _host.Devices.Homes.GetValueOrDefault(parsed.Home)?.Online == true;
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
            var session = _host.Store.Sessions.FirstOrDefault(s => s.Id == localId);
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
            var transcript = _host.Devices.RemoteTranscripts.GetValueOrDefault(globalId);
            busy = transcript?.Busy == true;
            if (transcript is not null)
            {
                parts.Add(transcript.Status);
                if (!string.IsNullOrEmpty(transcript.AccountName)) parts.Add(transcript.AccountName);
                if (transcript.Pending.Count > 0)
                    parts.Add(transcript.Pending.Count + " queued" + (transcript.QueuePaused ? " (paused)" : ""));
            }
            if (_host.Devices.RemoteOffline.Contains(globalId)) parts.Add("reconnect to resume");
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
        if (_host.Devices.LastOutcome.Length > 0) HintText.Text = _host.Devices.LastOutcome;
        else if (_notice is not null) HintText.Text = _notice;
        else
        {
            var hint = DefaultHint;
            var attached = _selected?.LocalSessionID is { } localId
                ? _host.Store.Sessions.FirstOrDefault(s => s.Id == localId)?.Attachments.Count ?? 0
                : _selected?.GlobalID is string gid ? _host.RemoteHashes.GetValueOrDefault(gid)?.Count ?? 0 : 0;
            if (attached > 0) hint += $" · {attached} image(s) attached";
            HintText.Text = hint;
        }
        var hasImages = _selected?.LocalSessionID is { } lid
            ? _host.Store.Sessions.FirstOrDefault(s => s.Id == lid)?.Attachments.Count > 0
            : _selected?.GlobalID is string g && _host.RemoteHashes.GetValueOrDefault(g)?.Count > 0;
        ClearImagesButton.Visibility = hasImages ? Visibility.Visible : Visibility.Collapsed;
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
            var session = _host.Store.Sessions.FirstOrDefault(s => s.Id == localId);
            if (session is null) return;
            engine = session.Entry.Engine;
            model = session.Choices.Model; effort = session.Choices.Effort; access = session.Choices.Access;
        }
        else if (_selected.GlobalID is { } globalId)
        {
            var transcript = _host.Devices.RemoteTranscripts.GetValueOrDefault(globalId);
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


    internal static void SyncCombo(ComboBox box, List<SettingItem> items, string currentId)
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
            var session = _host.Store.Sessions.FirstOrDefault(s => s.Id == localId);
            if (session is null) return;
            if (kind == "model") session.Choices.Model = value;
            else if (kind == "effort") session.Choices.Effort = value;
            else session.Choices.Access = value;
            _host.Store.Save();
        }
        else if (_selected?.GlobalID is { } globalId)
        {
            _ = _host.Devices.SendRemoteCommandAsync(globalId, new DeviceCommandPayload
            {
                Action = kind,
                Model = kind == "model" ? value : null,
                Effort = kind == "effort" ? value : null,
                Access = kind == "access" ? value : null,
            });
        }
        _host.RequestRefresh();
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


    private void SyncLines(List<(string Role, string Text)> lines, int hiddenMessages, bool caretToEnd)
    {
        var key = (_selected?.Key ?? "none") + "|" + hiddenMessages;
        // Message numbers: every visible message is numbered in order,
        // continuing past the paged-away ones — prompts and responses
        // alike, so any single message is addressable.
        var numbers = new int[lines.Count];
        var n = hiddenMessages;
        for (var i = 0; i < lines.Count; i++) numbers[i] = ++n;
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
        var showNumbers = _host.Layout.ShowLineNumbers;
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        // The message number, as a chip beside every block: prompts print
        // it steel blue, responses grey. Same left edge for all body text.
        var chip = new TextBlock
        {
            Text = showNumbers ? number.ToString() : "",
            FontSize = 16,
            MinWidth = showNumbers ? 28 : 0,
            TextAlignment = TextAlignment.Right,
            Margin = new Thickness(0, 2, 0, 0),
            Foreground = new SolidColorBrush(isUser ? Microsoft.UI.Colors.SteelBlue : Microsoft.UI.Colors.Gray),
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
            ? new List<MdBlock> { new MdText(flat, new List<MdRun>()) }
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
            var start = Math.Clamp(run.Start, cursor, block.Plain.Length);
            var end = Math.Clamp(run.Start + run.Length, start, block.Plain.Length);
            AddRunSegment(para, block.Plain, cursor, start, null, isUser);
            if (end > start) AddRunSegment(para, block.Plain, start, end, run, isUser);
            cursor = Math.Max(cursor, end);
        }
        AddRunSegment(para, block.Plain, cursor, block.Plain.Length, null, isUser);
        view.Blocks.Add(para);
        return view;
    }


    // A null styled run is unstyled text between runs. Table-kind runs
    // should not appear inside text segments (the parser lifts whole
    // tables out first); if one ever does, it washes Consolas like code
    // rather than rendering raw.
    private void AddRunSegment(Paragraph para, string source, int start, int end, MdRun? styled, bool isUser)
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
            else switch (styled?.Kind)
            {
                case MdRunKind.Bold:
                case MdRunKind.Heading:
                    var bold = new Bold();
                    bold.Inlines.Add(run);
                    para.Inlines.Add(bold);
                    break;
                case MdRunKind.Code:
                case MdRunKind.Table:
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
    // stated semantics), alignments from the divider row. The parser puts
    // the header first in Rows and drops the divider, and alignments are
    // the raw divider cells (":---" / ":---:" / "---:").
    private static int AlignmentOf(string dividerCell)
    {
        var cell = dividerCell.Trim();
        var left = cell.StartsWith(':');
        var right = cell.EndsWith(':');
        return left && right ? 1 : right ? 2 : 0;
    }


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
                var align = c < table.Alignments.Count ? AlignmentOf(table.Alignments[c]) : 0;
                var header = r == 0;
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



    // Click-anywhere-to-type (Mac parity): a plain left-click on history
    // or the header jumps to the end and focuses the draft. A press that
    // moves becomes a selection drag and never yanks; right-button presses
    // (context menu) and DraftBox presses (editing) are excluded. Known
    // tradeoff, same as the Mac: double-click word-select in history jumps
    // instead — drag to select, right-click to copy.
    private bool _pressArmed;
    private Windows.Foundation.Point _pressPoint;

    // Draft presses edit; scrollbar presses scroll. Everything else in
    // the transcript is history, and a plain click there jumps to entry.
    private bool IsEntryOrChrome(DependencyObject? source)
    {
        var current = source;
        while (current is not null)
        {
            if (ReferenceEquals(current, DraftBox)) return true;
            if (current is Microsoft.UI.Xaml.Controls.Primitives.ScrollBar) return true;
            current = VisualTreeHelper.GetParent(current);
        }
        return false;
    }

    private void JumpToEntry()
    {
        _userScrollUtc = DateTime.UtcNow;
        _unreadUpdates = 0;
        UpdateJumpButton(following: true);
        ScrollTranscriptToEnd();
        DraftBox.Focus(FocusState.Programmatic);
    }

    private void OnTranscriptPressed(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        _pressArmed = false;
        var at = e.GetCurrentPoint(TranscriptScroller);
        if (at.Properties.PointerUpdateKind != Microsoft.UI.Input.PointerUpdateKind.LeftButtonPressed) return;
        if (IsEntryOrChrome(e.OriginalSource as DependencyObject)) return;
        _pressArmed = true;
        _pressPoint = at.Position;
    }

    private void OnTranscriptMoved(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (!_pressArmed) return;
        var at = e.GetCurrentPoint(TranscriptScroller).Position;
        if (Math.Abs(at.X - _pressPoint.X) + Math.Abs(at.Y - _pressPoint.Y) > 6) _pressArmed = false;
    }

    private void OnTranscriptReleased(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (!_pressArmed) return;
        _pressArmed = false;
        var at = e.GetCurrentPoint(TranscriptScroller);
        if (at.Properties.PointerUpdateKind != Microsoft.UI.Input.PointerUpdateKind.LeftButtonReleased) return;
        if (IsEntryOrChrome(e.OriginalSource as DependencyObject)) return;
        JumpToEntry();
    }

    private void OnPaneHeaderPressed(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        var at = e.GetCurrentPoint(PaneHeader);
        if (at.Properties.PointerUpdateKind != Microsoft.UI.Input.PointerUpdateKind.LeftButtonPressed) return;
        JumpToEntry();
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
        if (_syncingBox) return;
        _host.Layout.ShowLineNumbers = LineNumbersBox.IsChecked == true;
        _host.Layout.Save(_host.DataFolder);
        // Chips are baked into blocks at build time: force a full re-sync.
        _lastChangeKey = null;
        _host.RequestRefresh();
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
            var session = _host.Store.Sessions.FirstOrDefault(s => s.Id == localId);
            if (session is null) return;
            session.Draft = text;
            _host.Store.Save();
        }
        else if (selected.GlobalID is { } globalId)
        {
            _ = _host.Devices.SendRemoteDraftAsync(globalId, text);
        }
    }


    internal void ShowSession(SidebarSession? session, bool caretToEnd)
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
            _draftText = Breaks(_host.Store.Sessions.FirstOrDefault(s => s.Id == localId)?.Draft ?? "");
        else if (session?.GlobalID is { } globalId)
            _draftText = Breaks(_host.Devices.RemoteTranscripts.GetValueOrDefault(globalId)?.Draft ?? "");
        SetDraftBox();
        RenderPane(caretToEnd);
        if (caretToEnd) DraftBox.Focus(FocusState.Programmatic);
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
            local = _host.Store.Sessions.FirstOrDefault(s => s.Id == localId);
            scope = "local:" + localId;
            if (local is not null)
                requests = local.Requests.Select(RequestViews.FromLocal).ToList();
        }
        else if (_selected?.GlobalID is { } globalId)
        {
            gid = globalId;
            scope = "remote:" + globalId;
            var transcript = _host.Devices.RemoteTranscripts.GetValueOrDefault(globalId);
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
        else if (gid is not null && _host.Devices.RemoteTranscripts.GetValueOrDefault(gid) is { } transcript)
        {
            pending = transcript.Pending.Select(p => (p.Id, p.Text)).ToList();
            paused = transcript.QueuePaused;
        }
        foreach (var (id, preview) in pending) signature.Append($"|q:{id}:{preview.Length}:{preview.GetHashCode()}");
        signature.Append("|paused:").Append(paused);
        var outbox = gid is null ? null : _host.Devices.Unresolved(gid).FirstOrDefault();
        if (outbox is not null) signature.Append($"|out:{outbox.CommandID}:{outbox.Outcome}:{outbox.Detail}");
        signature.Append("|lease:").Append(gid is null || _host.Devices.RemoteLeases.ContainsKey(gid));
        var text = signature.ToString();
        if (text == _bannerSignature) return;
        _bannerSignature = text;
        foreach (var stale in _host.AnswerStates.Keys.Where(k => !liveKeys.Contains(k)).ToList())
            _host.AnswerStates.Remove(stale);
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
        if (!_host.AnswerStates.TryGetValue(stateKey, out var state))
        {
            state = new RequestAnswerState();
            _host.AnswerStates[stateKey] = state;
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
            if (!await _host.Store.AnswerMuseAsync(local, request, choice: choiceId))
                _notice = "Answer failed: the request is no longer pending on this PC.";
            else _notice = null;
            _host.RequestRefresh();
        }
        else if (gid is not null)
        {
            await _host.Devices.SendRemoteCommandAsync(gid, new DeviceCommandPayload
            { Action = "answer", RequestID = view.Id, ChoiceID = choiceId });
            _host.RequestRefresh();
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
            if (!await _host.Store.AnswerMuseAsync(local, request, answers: answers))
                _notice = "Answer failed: the request is no longer pending on this PC.";
            else _notice = null;
            _host.RequestRefresh();
        }
        else if (gid is not null)
        {
            await _host.Devices.SendRemoteCommandAsync(gid, new DeviceCommandPayload
            { Action = "answer", RequestID = view.Id, AnswersJson = json });
            _host.RequestRefresh();
        }
        DraftBox.Focus(FocusState.Programmatic);
    }


    private StackPanel BuildPendingPanel(List<(Guid Id, string Text)> pending, bool paused, ChatSession? local, string? gid)
    {
        var panel = new StackPanel { Spacing = 4 };
        // Mac parity: one outstanding remote queue intent disables the whole
        // queue panel (double presses reuse it via the send-side guard), so
        // a blocked press can never go silent. Local repeats stay enabled.
        var queueRecord = gid is not null && local is null ? _host.Devices.QueueCommand(gid) : null;
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
                if (local is not null) { local.QueuePaused = false; _host.Store.Save(); _host.Store.RunNext(local); _host.RequestRefresh(); }
                else if (gid is not null)
                {
                    _ = _host.Devices.SendRemoteCommandAsync(gid, new DeviceCommandPayload { Action = "resumeQueue" });
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
                _host.Store.Save();
                if (!local.QueuePaused) _host.Store.RunNext(local);
                _host.RequestRefresh();
            }
            else if (gid is not null)
            {
                _ = _host.Devices.SendRemoteCommandAsync(gid,
                    new DeviceCommandPayload { Action = paused ? "resumeQueue" : "pauseQueue" });
            }
            DraftBox.Focus(FocusState.Programmatic);
        };
        controls.Children.Add(pause);
        var clear = new Button { Content = "Clear queue", FontSize = 12, IsEnabled = !queueBusy };
        clear.Click += (_, _) =>
        {
            if (local is not null) { local.Pending.Clear(); _host.Store.Save(); _host.RequestRefresh(); }
            else if (gid is not null)
            {
                _ = _host.Devices.SendRemoteCommandAsync(gid, new DeviceCommandPayload { Action = "clearQueue" });
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
                    var failure = _host.Store.InjectPending(local, id);
                    _notice = failure
                        ?? (wasBusy ? "Interrupting the current turn — the queued prompt runs next."
                            : "Queued prompt moved up — sending now.");
                    _noticeUtc = DateTime.UtcNow;
                    _host.RequestRefresh();
                }
                else if (gid is not null)
                {
                    _notice = "Sent — waiting for home to interrupt and run it.";
                    _noticeUtc = DateTime.UtcNow;
                    _ = _host.Devices.SendRemoteCommandAsync(gid,
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
            check.Click += async (_, _) => { await _host.Devices.QueryOutboxAsync(record); _host.RequestRefresh(); DraftBox.Focus(FocusState.Programmatic); };
            row.Children.Add(check);
            var discard = new Button { Content = "Discard", FontSize = 12 };
            discard.Click += (_, _) => { _host.Devices.DiscardOutbox(record.CommandID); _host.RequestRefresh(); DraftBox.Focus(FocusState.Programmatic); };
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
                _host.Devices.DiscardOutbox(record.CommandID);
                _host.RequestRefresh();
                DraftBox.Focus(FocusState.Programmatic);
            };
            row.Children.Add(restore);
            var discard = new Button { Content = "Discard", FontSize = 12 };
            discard.Click += (_, _) => { _host.Devices.DiscardOutbox(record.CommandID); _host.RequestRefresh(); DraftBox.Focus(FocusState.Programmatic); };
            row.Children.Add(discard);
        }
        else if (record.Outcome == "accepted")
        {
            var dismiss = new Button { Content = "Dismiss", FontSize = 12 };
            dismiss.Click += (_, _) => { _host.Devices.DiscardOutbox(record.CommandID); _host.RequestRefresh(); DraftBox.Focus(FocusState.Programmatic); };
            row.Children.Add(dismiss);
        }
        else
        {
            var resend = new Button { Content = "Resend same ID", FontSize = 12 };
            resend.Click += async (_, _) => { await _host.Devices.RetryOutboxAsync(record); _host.RequestRefresh(); DraftBox.Focus(FocusState.Programmatic); };
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
            && _host.Devices.RemoteTranscripts.GetValueOrDefault(gid) is { } transcript
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
            _host.RequestRefresh();
        }
        else if (_selected?.GlobalID is { } gid)
        {
            await _host.Devices.RequestEarlierAsync(gid);
            _host.RequestRefresh();
        }
    }


    private async void OnTakeHereClick(object sender, RoutedEventArgs e)
    {
        if (_selected?.GlobalID is not { } gid) return;
        await _host.Devices.AcquireRemoteAsync(gid);
        _host.RequestRefresh();
    }


    private async void OnSendClick(object sender, RoutedEventArgs e)
    {
        var text = _draftText.Replace("\r", "\n");
        if (string.IsNullOrWhiteSpace(text) || _selected is null || !InputAllowed()) return;
        _notice = null;
        _noticeUtc = null;
        // The just-sent text must never come back. A debounced draft flush
        // scheduled while typing would otherwise resurrect it into the
        // store after submit cleared it (the send-then-leftover bug), so a
        // pending flush dies here; and the adopt rule below must not refill
        // the tail with it either, local or remote.
        _lastSentText = text;
        _draftSeq++;
        if (_selected.LocalSessionID is { } localId)
        {
            var session = _host.Store.Sessions.FirstOrDefault(s => s.Id == localId);
            if (session is null) return;
            session.Draft = text;
            _draftText = "";
            _host.Store.Submit(session);
            // A busy submit changes no history, so RenderPane would skip the
            // sync and the sent text would linger in the draft, inviting a
            // duplicate send. Clear the box now; the refresh below no-ops.
            SetDraftBox();
        }
        else if (_selected.GlobalID is { } globalId)
        {
            // Draft stays until home ack completes (outbox in core service).
            var hashes = _host.RemoteHashes.GetValueOrDefault(globalId)?.ToArray() ?? Array.Empty<string>();
            await _host.Devices.SendRemoteCommandAsync(globalId,
                new DeviceCommandPayload { Action = "submit", Text = text, BlobHashes = hashes });
        }
        _host.RequestRefresh();
        DraftBox.Focus(FocusState.Programmatic);
    }


    private async void OnStopClick(object sender, RoutedEventArgs e)
    {
        _notice = null;
        _noticeUtc = null;
        if (_selected?.LocalSessionID is { } localId)
        {
            var session = _host.Store.Sessions.FirstOrDefault(s => s.Id == localId);
            if (session is not null) _host.Store.Stop(session);
        }
        else if (_selected?.GlobalID is { } globalId)
        {
            await _host.Devices.SendRemoteCommandAsync(globalId, new DeviceCommandPayload { Action = "stop" });
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
            InitializeWithWindow.Initialize(picker, _host.WindowHandle);
            var files = await picker.PickMultipleFilesAsync();
            if (files.Count == 0) return;
            if (_selected.LocalSessionID is { } localId)
            {
                var session = _host.Store.Sessions.FirstOrDefault(s => s.Id == localId);
                if (session is null) return;
                var dir = Path.Combine(_host.DataFolder, "Attachments", localId.ToString("D"));
                Directory.CreateDirectory(dir);
                foreach (var file in files)
                {
                    var dest = Path.Combine(dir, DateTime.UtcNow.Ticks + "-" + file.Name);
                    File.Copy(file.Path, dest);
                    session.Attachments.Add(dest);
                }
                _host.Store.Save();
            }
            else if (_selected.GlobalID is { } globalId)
            {
                if (!_host.RemoteHashes.TryGetValue(globalId, out var hashes))
                {
                    hashes = new List<string>();
                    _host.RemoteHashes[globalId] = hashes;
                }
                foreach (var file in files)
                {
                    var hash = await _host.Devices.UploadBlobAsync(globalId, await File.ReadAllBytesAsync(file.Path));
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
        _host.RequestRefresh();
    }


    private void OnClearImagesClick(object sender, RoutedEventArgs e)
    {
        if (_selected?.LocalSessionID is { } localId)
        {
            var session = _host.Store.Sessions.FirstOrDefault(s => s.Id == localId);
            if (session is not null) { session.Attachments.Clear(); _host.Store.Save(); }
        }
        else if (_selected?.GlobalID is { } globalId)
        {
            _host.RemoteHashes.Remove(globalId);
        }
        _host.RequestRefresh();
    }
}
