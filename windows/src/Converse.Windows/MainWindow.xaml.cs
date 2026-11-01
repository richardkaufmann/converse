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
public sealed record SidebarHeader(string Key, string Title, string Status, bool Offline = false, bool CanCreate = false,
    string? DeviceID = null, string Details = "", bool CanRename = false) : SidebarItem(Key)
{
    public double Opacity => Offline ? 0.3 : 1;
    public bool HasStatus => Status.Length > 0;
    public Windows.UI.Text.FontWeight Weight => Offline ? Microsoft.UI.Text.FontWeights.Normal : Microsoft.UI.Text.FontWeights.SemiBold;
}
public sealed record SidebarSession(string Key, string Title, string Subtitle, string? GlobalID, Guid? LocalSessionID, bool ShowPark, bool ShowClose, bool ShowPlace, bool ShowGreyClose = false, bool PActive = false, bool In1 = false, bool In2 = false, bool In3 = false, string Engine = "", string Model = "", bool IsAgent = false) : SidebarItem(Key);

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

// Setting rows (model/effort/access labels): shared by the conversation
// panes and the Groups dialog.
internal sealed record SettingItem(string Id, string Label)
{
    public override string ToString() => Label;
}

public sealed partial class MainWindow : Window
{
    private readonly SessionStore _store;

    private readonly DeviceSyncService _devices;

    private readonly string _dataFolder;

    private readonly SidebarLayoutState _layout;

    private readonly HelpDocument? _help;

    private bool _draggingSplitter;

    private double _windowWidth = 1200;

    private bool _suppressSelection;

    private string _sidebarSignature = "";

    private readonly Dictionary<string, RequestAnswerState> _answerStates = new();

    private readonly Dictionary<string, List<string>> _remoteHashes = new();

    // Pane slots 1-3 (Mac P/1/2/3/X parity): placements persist in
    // pane-layout.json; focus is independent of placement.
    private readonly PanePlacements _placements;

    // Visible panes and keyboard focus (Mac WorkspacePanes parity). Panes
    // are created once and re-shown per placement; an empty layout shows
    // one disabled placeholder instead.
    private readonly List<ConversationPane> _panes = new();
    private ConversationPane _placeholder = null!;
    private int _focusedPane = 1;

    internal SessionStore Store => _store;
    internal DeviceSyncService Devices => _devices;
    internal string DataFolder => _dataFolder;
    internal SidebarLayoutState Layout => _layout;
    internal nint WindowHandle => WindowNative.GetWindowHandle(this);
    internal Dictionary<string, RequestAnswerState> AnswerStates => _answerStates;
    internal Dictionary<string, List<string>> RemoteHashes => _remoteHashes;
    internal void RequestRefresh() => Refresh();

    internal void FocusPane(ConversationPane pane)
    {
        _focusedPane = pane.Pane;
        foreach (var view in _panes) view.SetFocused(view == pane);
        _placeholder.SetFocused(false);
    }

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
        ResetDemoItem.Visibility = SetupPreview.Demo ? Visibility.Visible : Visibility.Collapsed;
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Converse.ico"));
        var folder = Environment.GetEnvironmentVariable("CONVERSE_DATA_DIR") ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Converse");
        _dataFolder = folder;
        _layout = SidebarLayoutState.Load(folder);
        _placements = PanePlacements.Load(folder);
        _store = new SessionStore(folder);
        _devices = new DeviceSyncService(folder, _store, SetupPreview.Demo ? "Converse Demo · " + Environment.MachineName : null);
        _devices.IsViewerPlaced = id => PanePlacements.Load(_dataFolder).PaneOf("remote:" + id) is not null;
        InitializeAgents();
        // No modal pairing prompt: joins surface as codes in the Groups
        // dialog, where both sides compare all eight groups. (The
        // PairingConfirmation callback stays for headless tests only.)
        _store.Changed += Refresh;
        _devices.Changed += Refresh;
        _devices.RemoteViewDisplaced += globalId => DispatcherQueue.TryEnqueue(() =>
        {
            if (_devices.RemoteLeases.ContainsKey(globalId)) return; // already taken again
            _placements.Park("remote:" + globalId);
            _placements.Save(_dataFolder);
            Refresh();
        });
        if (Environment.GetEnvironmentVariable("CONVERSE_UI_TEST") != "1") _ = _devices.StartAsync(port: SetupPreview.Enabled ? 0 : DeviceSyncService.DefaultPort, enableDiscovery: !SetupPreview.Enabled || SetupPreview.Demo, loopbackOnly: SetupPreview.Enabled && !SetupPreview.Demo);
        _help = LoadHelp();
        Title = (SetupPreview.Enabled ? SetupPreview.Name + " " : "Converse ") + VersionBuild;
        for (var pane = 1; pane <= 3; pane++)
        {
            var view = new ConversationPane();
            view.Attach(this, pane);
            _panes.Add(view);
        }
        _placeholder = new ConversationPane();
        _placeholder.Attach(this, 0);
        AppWindow.Changed += (_, e) => { if (e.DidSizeChange) ClampWindowWidth(); };
        // The width floor computed pre-Activate uses scale 1.0 (no
        // XamlRoot yet); re-apply it once the root exists. Clamp only
        // ever grows toward the floor, never shrinks the user's window.
        Activated += (_, _) => ClampWindowWidth();
        ApplyLayout();
        Refresh();
        InitializeSupport();
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
        if (SetupPreview.Enabled && !_store.Sessions.Any(s => s.SupportAssistant && s.SupportSetupCompleted)) { await ShowSupportSetup(); return; }
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
        bool parkedByHygiene = false;
        // Placement hygiene: a placed remote whose home is gone (group
        // move) and a local placed session whose display lease is held by
        // another device (Mac Workspace.shared.park on remote take) cannot
        // stay on screen here. Parking never stops the session at home.
        foreach (var pane in new[] { 1, 2, 3 })
        {
            if (_placements.KeyIn(pane) is not { } key) continue;
            if (key.StartsWith("remote:", StringComparison.Ordinal)
                && DeviceGlobalID.Parse(key["remote:".Length..]) is { } parsed
                && !_devices.Homes.ContainsKey(parsed.Home)
                && !_devices.Trust.Devices.Any(d => d.DeviceID == parsed.Home && d.GroupID == _devices.CurrentGroup?.Id))
                { _placements.Park(key); parkedByHygiene = true; }
            else if (key.StartsWith("local:", StringComparison.Ordinal)
                && Guid.TryParse(key["local:".Length..], out var localId)
                && _devices.DisplayHolder(localId) is { } holder && holder.Device != _devices.DeviceId)
                { _placements.Park(key); parkedByHygiene = true; }
        }
        if (parkedByHygiene) _placements.Save(_dataFolder);
        RefreshSidebar();
        RefreshPanes();
        RenderGroupsDialog();
        AutoOpenGroups();
    }

    // Mac WorkspacePanes parity: occupied slots render side by side, each
    // an independent ConversationPane; an empty layout shows one disabled
    // placeholder. Panes keep their shown session across refreshes — only
    // a changed assignment re-shows, so streaming never rebuilds blocks.
    // Focus falls to the lowest occupied pane when its pane goes away.
    // The column tree is rebuilt only when occupancy changes: re-parenting
    // every refresh unloads the panes and drops keyboard focus mid-word,
    // which reads as "can't type into any pane".
    private string _paneLayoutSig = "";
    private int _visiblePaneCount;

    private void RefreshPanes()
    {
        var rows = Sidebar.Items.OfType<SidebarSession>().ToDictionary(i => i.Key, i => i);
        var occupied = new[] { 1, 2, 3 }.Where(pane => _placements.KeyIn(pane) is not null).ToList();
        if (_focusedPane < 1 || _placements.KeyIn(_focusedPane) is null)
            _focusedPane = occupied.Count > 0 ? occupied[0] : 0;
        // Visible slots only: session replacement and focus changes update
        // the existing panes without rebuilding the column tree.
        var sig = string.Join(",", occupied);
        if (sig != _paneLayoutSig)
        {
            _paneLayoutSig = sig;
            RebuildPaneColumns(occupied);
        }
        if (occupied.Count == 0)
        {
            _placeholder.ShowSession(null, caretToEnd: false);
            _placeholder.SyncLineNumbersBox();
            _placeholder.SetFocused(false);
            return;
        }
        foreach (var pane in occupied)
        {
            var view = _panes[pane - 1];
            var key = _placements.KeyIn(pane);
            var row = key is not null && rows.TryGetValue(key, out var found) ? found : null;
            if (view.Current?.Key != row?.Key) view.ShowSession(row, caretToEnd: false);
            else view.RefreshSessionMetadata(row);
            view.SyncLineNumbersBox();
            view.SetFocused(pane == _focusedPane);
        }
        UpdateWindowMinWidth(occupied.Count);
    }

    // Occupancy changed: equal star-width columns with a hand-rolled
    // Border divider between panes (Mac auto-sizes; the divider is the
    // Windows adjustment affordance — GridSplitter would need the
    // Community Toolkit). Columns carry a minimum so a drag can never
    // squeeze a pane shut; user widths survive refreshes until the next
    // count change resets to equal shares; slot moves preserve widths.
    private void RebuildPaneColumns(List<int> occupied)
    {
        var previousWidths = PaneHost.ColumnDefinitions.Where((_, index) => index % 2 == 0).Select(column => column.Width).ToArray();
        var preserveWidths = _visiblePaneCount == occupied.Count && previousWidths.Length == occupied.Count;
        _visiblePaneCount = occupied.Count;
        PaneHost.Children.Clear();
        PaneHost.ColumnDefinitions.Clear();
        if (occupied.Count == 0)
        {
            PaneHost.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            PaneHost.Children.Add(_placeholder);
            UpdateWindowMinWidth(0);
            return;
        }
        var column = 0;
        foreach (var pane in occupied)
        {
            PaneHost.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = preserveWidths ? previousWidths[column / 2] : new GridLength(1, GridUnitType.Star),
                MinWidth = 280,
            });
            var view = _panes[pane - 1];
            Grid.SetColumn(view, column);
            PaneHost.Children.Add(view);
            column++;
            if (pane != occupied[^1])
            {
                PaneHost.ColumnDefinitions.Add(new ColumnDefinition
                {
                    Width = new GridLength(4),
                    MinWidth = 4,
                });
                // Hand-rolled divider: GridSplitter lives in the Community
                // Toolkit (a new third-party dependency), so a thin Border
                // with pointer capture adjusts the two neighbour columns,
                // like the sidebar splitter. The first drag freezes both to
                // pixels; MinWidth keeps a pane from squeezing shut. Column
                // indices are resolved at drag time: the right neighbour
                // does not exist yet while this divider is built.
                var leftIndex = column - 1;
                var rightIndex = column + 1;
                var divider = new Border
                {
                    Width = 4,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    VerticalAlignment = VerticalAlignment.Stretch,
                    Background = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
                };
                var dragging = false;
                var startX = 0.0;
                var startLeft = 0.0;
                var startRight = 0.0;
                divider.PointerPressed += (_, e) =>
                {
                    var cols = PaneHost.ColumnDefinitions;
                    if (leftIndex < 0 || rightIndex >= cols.Count) return;
                    dragging = true;
                    startX = e.GetCurrentPoint(PaneHost).Position.X;
                    startLeft = Math.Max(cols[leftIndex].ActualWidth, 280);
                    startRight = Math.Max(cols[rightIndex].ActualWidth, 280);
                    cols[leftIndex].Width = new GridLength(startLeft, GridUnitType.Pixel);
                    cols[rightIndex].Width = new GridLength(startRight, GridUnitType.Pixel);
                    divider.CapturePointer(e.Pointer);
                    e.Handled = true;
                };
                divider.PointerMoved += (_, e) =>
                {
                    if (!dragging) return;
                    var cols = PaneHost.ColumnDefinitions;
                    if (leftIndex < 0 || rightIndex >= cols.Count) return;
                    var total = startLeft + startRight;
                    var nextLeft = Math.Clamp(
                        startLeft + e.GetCurrentPoint(PaneHost).Position.X - startX,
                        280, total - 280);
                    cols[leftIndex].Width = new GridLength(nextLeft, GridUnitType.Pixel);
                    cols[rightIndex].Width = new GridLength(total - nextLeft, GridUnitType.Pixel);
                    e.Handled = true;
                };
                void EndDrag(Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
                {
                    dragging = false;
                    try { divider.ReleasePointerCapture(e.Pointer); } catch { /* already released */ }
                }
                divider.PointerReleased += (_, e) => EndDrag(e);
                divider.PointerCaptureLost += (_, e) => EndDrag(e);
                Grid.SetColumn(divider, column);
                PaneHost.Children.Add(divider);
                column++;
            }
        }
        UpdateWindowMinWidth(occupied.Count);
    }

    // Mac minimumWidth parity: the window grows to fit new panes instead
    // of squeezing them into a sliver (it never auto-shrinks — like the
    // Mac minimum, it only floors manual resizing). WinUI 3 windows have
    // no MinWidth property, so the AppWindow size is clamped in physical
    // pixels against the rasterization scale.
    private int _minWindowWidthPx;

    private void UpdateWindowMinWidth(int paneCount)
    {
        var sidebar = SidebarColumn.Width.Value;
        if (sidebar <= 0) sidebar = _layout.EffectiveWidth(_windowWidth);
        // XamlRoot is null before Activate(): ?. only guarded Content, so
        // the RasterizationScale read threw in the constructor. Default to
        // 1.0 and re-apply the floor on Activated, when the root exists.
        var scale = (Content as FrameworkElement)?.XamlRoot?.RasterizationScale ?? 1.0;
        _minWindowWidthPx = Math.Max(700, (int)Math.Ceiling((sidebar + 4 + paneCount * 340 + 24) * scale));
        ClampWindowWidth();
    }

    private void ClampWindowWidth()
    {
        try
        {
            var size = AppWindow.Size;
            if (size.Width < _minWindowWidthPx)
                AppWindow.Resize(new Windows.Graphics.SizeInt32(_minWindowWidthPx, size.Height));
        }
        catch { /* window not ready yet; the Changed hook retries */ }
    }


    private async void OnRenameDevice(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuFlyoutItem item || item.Tag is not SidebarHeader header || header.DeviceID is not { } id) return;
        var input = new TextBox { Text = _devices.DisplayName(id), PlaceholderText = "Device display name" };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = new SolidColorBrush(Microsoft.UI.Colors.OrangeRed) };
        var content = new StackPanel { Spacing = 10 };
        content.Children.Add(input);
        content.Children.Add(new TextBlock { Text = "Shared with the group. Device identity, pairing and operating-system name stay unchanged.", TextWrapping = TextWrapping.Wrap });
        content.Children.Add(error);
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Rename device in group", Content = content,
            PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
        dialog.PrimaryButtonClick += (_, args) => {
            if (DeviceTrustStore.ValidDisplayName(input.Text.Trim())) return;
            args.Cancel = true; error.Text = "Use a nonempty name up to 200 UTF-8 bytes, without control characters.";
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try { await _devices.RenameDeviceDisplayNameAsync(id, input.Text); }
        catch (Exception failure) {
            await new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Could not rename device", Content = failure.Message, CloseButtonText = "OK" }.ShowAsync();
        }
        Refresh();
    }

    private void RefreshSidebar()
    {
        var items = new List<SidebarItem>();
        // Group heading above the sessions; remote homes appear only while
        // this device belongs to the group (the service scopes Homes).
        if (_devices.CurrentGroup is { } current)
            items.Add(new SidebarHeader("group", "Group: " + current.Name,
                _devices.Trust.Devices.Count(d => d.GroupID == current.Id) + " member(s)"));
        items.Add(new SidebarHeader("local", _devices.DisplayName(_devices.DeviceId) + " · this device", _store.Sessions.Count + " session(s)",
            DeviceID: _devices.DeviceId, Details: _devices.DeviceDetails(_devices.DeviceId), CanRename: _devices.CanRenameDevice(_devices.DeviceId)));
        foreach (var session in _store.Sessions)
            items.Add(new SidebarSession("local:" + session.Id, (!string.IsNullOrEmpty(session.Agent?.Attention) ? "⚠ " : session.Busy ? "● " : "") + session.Title,
                session.Agent?.LoopStatus ?? session.Entry.Name + " · " + session.Status, null, session.Id, ShowPark: true, ShowClose: true, ShowPlace: true,
                PActive: _placements.PaneOf("local:" + session.Id) is null,
                In1: _placements.KeyIn(1) == "local:" + session.Id,
                In2: _placements.KeyIn(2) == "local:" + session.Id,
                In3: _placements.KeyIn(3) == "local:" + session.Id,
                Engine: session.Entry.Engine, Model: session.Choices.Model ?? "", IsAgent: session.Agent is not null));
        foreach (var home in _devices.Homes.Values.OrderBy(h => h.DeviceName))
        {
            items.Add(new SidebarHeader("home:" + home.DeviceID, _devices.DisplayName(home.DeviceID, home.DeviceName),
                home.Online ? "remote" : "", Offline: !home.Online, CanCreate: home.Online && (_devices.CanCreateRemote(home.DeviceID) || _devices.CanHostAgent(home.DeviceID)),
                DeviceID: home.DeviceID, Details: _devices.DeviceDetails(home.DeviceID), CanRename: _devices.CanRenameDevice(home.DeviceID)));
            if (!home.Online) continue;
            if (home.Rows.Count == 0)
                items.Add(new SidebarSession("home:" + home.DeviceID + ":empty",
                    home.Online ? "No sessions available" : "Offline", "", null, null, ShowPark: false, ShowClose: false, ShowPlace: false));
            foreach (var row in home.Rows)
                items.Add(new SidebarSession("remote:" + row.GlobalID, (!string.IsNullOrEmpty(row.Attention) ? "⚠ " : row.Busy ? "● " : "") + row.Title,
                    (home.Online ? "" : "Offline · ") + row.Status, row.GlobalID, null, ShowPark: true, ShowClose: home.Online && _devices.CanCloseRemote(home.DeviceID), ShowPlace: true, ShowGreyClose: !home.Online || !_devices.CanCloseRemote(home.DeviceID),
                    PActive: _placements.PaneOf("remote:" + row.GlobalID) is null,
                    In1: _placements.KeyIn(1) == "remote:" + row.GlobalID,
                    In2: _placements.KeyIn(2) == "remote:" + row.GlobalID,
                    In3: _placements.KeyIn(3) == "remote:" + row.GlobalID,
                    Engine: row.Engine, Model: row.Model, IsAgent: row.ParticipantKind == "agent" || row.Engine == "agent"));
        }
        var signature = string.Join("\n", items.Select(i => i.Key + "|" + (i switch
        {
            SidebarHeader h => h.Title + "|" + h.Status + "|" + h.CanCreate + "|" + h.Details + "|" + h.CanRename,
            SidebarSession s => s.Title + "|" + s.Subtitle + "|" + s.ShowPark + "|" + s.ShowClose + "|" + s.ShowPlace
                + "|" + s.PActive + "|" + s.In1 + "|" + s.In2 + "|" + s.In3 + "|" + s.Engine + "|" + s.Model + "|" + s.IsAgent,
            _ => "",
        })));
        if (signature == _sidebarSignature) return;
        _sidebarSignature = signature;
        _suppressSelection = true;
        Sidebar.ItemsSource = items;
        // The focused pane's row stays highlighted; nothing is highlighted
        // when no pane is focused.
        var focusKey = _focusedPane >= 1 ? _placements.KeyIn(_focusedPane) : null;
        Sidebar.SelectedItem = focusKey is not null
            ? items.OfType<SidebarSession>().FirstOrDefault(i => i.Key == focusKey)
            : null;
        _suppressSelection = false;
    }





    // Clicking a row shows that session in the focused pane (Mac: the
    // sidebar assigns into focus); the 1/2/3 buttons target a pane
    // explicitly. Headers and empty rows are not placeable: the highlight
    // snaps back to the focused pane's row.
    private async void OnSidebarSelection(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelection) return;
        var item = Sidebar.SelectedItem as SidebarItem;
        var focusKey = _focusedPane >= 1 ? _placements.KeyIn(_focusedPane) : null;
        if (item is not SidebarSession session || (session.GlobalID is null && session.LocalSessionID is null))
        {
            _suppressSelection = true;
            Sidebar.SelectedItem = focusKey is not null
                ? Sidebar.Items.OfType<SidebarSession>().FirstOrDefault(i => i.Key == focusKey)
                : null;
            _suppressSelection = false;
            return;
        }
        var pane = _focusedPane >= 1 ? _focusedPane : 1;
        await PlaceSessionAsync(session, pane);
    }


    private async void OnCloseClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SidebarSession row }) return;
        var session = row.LocalSessionID is { } localId ? _store.Sessions.FirstOrDefault(s => s.Id == localId) : null;
        var remote = row.GlobalID is { } gid ? DeviceGlobalID.Parse(gid) : null;
        if (session is null && remote is null) return;
        var dialog = new ContentDialog
        {
            Title = "Close session?",
            Content = "“" + row.Title + "” closes on its home, stops its work and disappears from every viewer. A recovery snapshot stays on the home.",
            PrimaryButtonText = "Close session",
            CloseButtonText = "Cancel",
            XamlRoot = Content.XamlRoot,
        };
        var closeStyle = new Style(typeof(Button));
        closeStyle.Setters.Add(new Setter(Control.BackgroundProperty, new SolidColorBrush(Microsoft.UI.Colors.DarkRed)));
        closeStyle.Setters.Add(new Setter(Control.ForegroundProperty, new SolidColorBrush(Microsoft.UI.Colors.White)));
        dialog.PrimaryButtonStyle = closeStyle;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            if (remote is { } target)
            {
                var result = await _devices.RequestParticipantAsync(target.Home, "session.close", row.GlobalID);
                if (result.Outcome != "completed") throw new InvalidOperationException(result.Detail);
            }
            else if (session is not null)
            {
                _store.DeleteSession(session);
                _placements.Park("local:" + session.Id); _placements.Save(_dataFolder);
            }
        }
        catch (Exception error) { await new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Could not close session", Content = error.Message, CloseButtonText = "OK" }.ShowAsync(); }
        Refresh();
    }


    internal async Task RunPaneResetCheckAsync()
    {
        // Only called by the isolated temp-profile UI test entry point.
        var first = _store.Create(_store.Entries.First(e => e.Engine == "claude"));
        first.Messages.Add(new ChatMessage { Role = "assistant", Text = "OLD SESSION SENTINEL" });
        var fresh = _store.Create(_store.Entries.First(e => e.Engine == "codex"));
        var pane = _panes[0];
        void Show(ChatSession session) { _placements.Assign("local:" + session.Id, 1); Refresh(); }
        void Require(bool ok, string label) { if (!ok) throw new InvalidOperationException(label); }
        Show(first); Require(pane.VisibleMessageBlockCount == 1, "Nonempty fixture did not render");
        Show(fresh); Require(pane.VisibleMessageBlockCount == 0, "Empty new session retained old transcript blocks");
        await Task.Delay(300);
        Require(pane.VisibleMessageBlockCount == 0, "Delayed render restored previous-session blocks");
        fresh.Messages.Add(new ChatMessage { Role = "user", Text = "NEW SESSION SENTINEL" });
        Refresh(); Require(pane.VisibleMessageBlockCount == 1, "New session content did not render");
        Show(first); Require(pane.VisibleMessageBlockCount == 1, "Returning to prior session lost its transcript");
        pane.ShowSession(null, true); Require(pane.VisibleMessageBlockCount == 0, "Unassigned pane retained transcript");
        Show(fresh);
        foreach (var (width, overflow) in new[] { (1100.0, false), (340.0, true), (900.0, false) })
        {
            pane.Width = width; pane.UpdateLayout(); await Task.Delay(100);
            Require(pane.SettingsUseOverflow == overflow && pane.SettingsShowControls != overflow, "Settings overflow duplicates controls or fails to track pane width " + width);
        }
        pane.Width = double.NaN;
        var longHistory = _store.Create(_store.Entries.First(e => e.Engine == "claude"));
        longHistory.Messages.Add(new ChatMessage { Role = "assistant", Text = string.Concat(Enumerable.Repeat("Long startup transcript line.\n", 160)) });
        Show(longHistory); pane.UpdateLayout(); await Task.Delay(200);
        Require(pane.TranscriptAtEnd, "A mounted long transcript did not start at the end: " + pane.TranscriptGeometry);
        Show(fresh);
        pane.CheckFilePathDrop();
        var third = _store.Create(_store.Entries.First(e => e.Engine == "codex"));
        var sidebarBefore = SidebarColumn.Width;
        void LayoutNow() { PaneHost.UpdateLayout(); }
        void EqualPanes(int count) {
            LayoutNow();
            var widths = PaneHost.ColumnDefinitions.Where((_, index) => index % 2 == 0).Select(c => c.ActualWidth).ToArray();
            Require(widths.Length == count && widths.Max() - widths.Min() < 2, "Pane count change did not equalize widths");
            Require(SidebarColumn.Width.Equals(sidebarBefore), "Pane count change moved the sidebar");
        }
        _placements.Assign("local:" + first.Id, 2); Refresh(); await Task.Delay(100); EqualPanes(2);
        PaneHost.ColumnDefinitions[0].Width = new GridLength(2, GridUnitType.Star);
        PaneHost.ColumnDefinitions[2].Width = new GridLength(1, GridUnitType.Star);
        _placements.Assign("local:" + third.Id, 1); Refresh();
        Require(PaneHost.ColumnDefinitions[0].Width.Value == 2, "Replacing a session reset its pane width");
        _placements.Assign("local:" + fresh.Id, 3); Refresh(); await Task.Delay(100); EqualPanes(3);
        PaneHost.ColumnDefinitions[0].Width = new GridLength(2, GridUnitType.Star);
        _placements.Park("local:" + first.Id); Refresh(); await Task.Delay(100); EqualPanes(2);
        PaneHost.ColumnDefinitions[0].Width = new GridLength(2, GridUnitType.Star);
        _placements.Assign("local:" + fresh.Id, 2); Refresh();
        Require(PaneHost.ColumnDefinitions[0].Width.Value == 2, "Moving slots at the same pane count reset widths");

        await _devices.CreateGroupAsync("Device label UI fixture");
        var originalDeviceName = _devices.DeviceName;
        await _devices.RenameDeviceDisplayNameAsync(_devices.DeviceId, "QA desktop label");
        RefreshSidebar();
        var deviceHeader = ((IEnumerable<SidebarItem>)Sidebar.ItemsSource).OfType<SidebarHeader>().Single(h => h.Key == "local");
        Require(deviceHeader.Title == "QA desktop label · this device" && deviceHeader.CanRename && deviceHeader.Details.Contains(_devices.DeviceId)
            && deviceHeader.Details.Contains(originalDeviceName) && _devices.DeviceName == originalDeviceName, "Device display label or hover identity is wrong");
        Require(Title == "Converse " + VersionBuild && !Title.Contains("Development"), "Window title omits bundled release version/build");
    }

    private void OnRemoteCreateMenu(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button || button.Tag is not SidebarHeader header || !header.Key.StartsWith("home:")) return;
        var home = header.Key[5..]; var menu = new MenuFlyout();
        foreach (var provider in new[] { "claude", "codex", "muse", "agent" })
        {
            if (provider == "agent" ? !_devices.CanHostAgent(home) : !_devices.CanCreateRemote(home)) continue;
            var item = new MenuFlyoutItem { Text = provider == "agent" ? "New agent" : "New " + char.ToUpperInvariant(provider[0]) + provider[1..] + " session" };
            item.Click += async (_, _) => {
                button.IsEnabled = false;
                try {
                    var result = await _devices.RequestParticipantAsync(home, provider == "agent" ? "agent.create" : "session.create", title: provider == "agent" ? "New Agent" : null, provider: provider == "agent" ? null : provider);
                    if (result.Outcome != "completed") await AgentNotice(result.Detail);
                } finally { button.IsEnabled = true; Refresh(); }
            };
            menu.Items.Add(item);
        }
        menu.ShowAt(button);
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
        var pane = _focusedPane >= 1 ? _focusedPane : 1;
        _placements.Assign(key, pane);
        _placements.Save(_dataFolder);
        _focusedPane = pane;
        Refresh();
        _panes[pane - 1].FocusDraft();
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
        }
        else if (result == ContentDialogResult.Primary && int.TryParse(portBox.Text, out var parsed))
            await _devices.ConnectManualAsync(hostBox.Text.Trim(), parsed);
        else return;
        if (_devices.ConnectionNotice.Length > 0)
            await new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Could not connect", Content = _devices.ConnectionNotice, CloseButtonText = "OK" }.ShowAsync();
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
        signature.Append("|s:").Append(_devices.ServiceStatus).Append(_devices.LastOutcome).Append(_devices.ConnectionNotice).Append(_groupsArmDissolve ?? "");
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
        if (groupItems.Count > 0) ConversationPane.SyncCombo(groupBox, groupItems, _groupsJoinGroupId);
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
        if (_devices.ConnectionNotice.Length > 0) panel.Children.Add(Note(_devices.ConnectionNotice));
    }


    private string VersionBuild
    {
        get {
            try {
                using var version = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Assets", "VERSION.json")));
                return version.RootElement.GetProperty("version").GetString() + " (" + version.RootElement.GetProperty("build").ToString() + ")";
            } catch { return _help is null ? "Development (0)" : _help.AppVersion + " (" + _help.AppBuild + ")"; }
        }
    }
    private async void OnAboutClick(object sender, RoutedEventArgs e)
    {
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock { Text = "Converse " + VersionBuild, FontSize = 20 });
        content.Children.Add(new TextBlock { Text = "© 2026 Richard Kaufmann" });
        content.Children.Add(new TextBlock { Text = "GPL version 3 or later, with a SAM codec exception. Third-party licenses apply.", TextWrapping = TextWrapping.Wrap });
        content.Children.Add(new HyperlinkButton { Content = "GPLv3 or later · licensing details", NavigateUri = new Uri("https://github.com/richardkaufmann/converse/blob/main/LICENSING.md") });
        content.Children.Add(new HyperlinkButton { Content = "README on GitHub", NavigateUri = new Uri("https://github.com/richardkaufmann/converse#readme") });
        await new ContentDialog { XamlRoot = Content.XamlRoot, Title = "About Converse", Content = content, CloseButtonText = "Done" }.ShowAsync();
    }

    private async void OnRenameRow(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuFlyoutItem { Tag: SidebarSession row }) return;
        var local = row.LocalSessionID is { } id ? _store.Sessions.FirstOrDefault(s => s.Id == id) : null;
        var remote = row.GlobalID is { } gid ? _devices.Homes.Values.SelectMany(h => h.Rows).FirstOrDefault(s => s.GlobalID == gid) : null;
        if (local is null && remote is null) return;
        try
        {
            if (row.GlobalID is { } target && (DeviceGlobalID.Parse(target) is not { } reference || !_devices.CanRenameRemote(reference.Home)))
            {
                await new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Home update needed", Content = "The home must be online and support remote renaming. You do not need to take the session.", CloseButtonText = "OK" }.ShowAsync();
                return;
            }
            var name = new TextBox { Text = local?.Title ?? remote!.Title, MaxLength = 200, MinWidth = 320 };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(name, "Session name");
            var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Rename session", Content = name, PrimaryButtonText = "Rename", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
            name.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(name.Text);
            dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(name.Text);
            dialog.Opened += (_, _) => { name.Focus(FocusState.Programmatic); name.SelectAll(); };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            if (local is not null) { local.Title = name.Text.Trim(); _store.Save(); }
            else if (row.GlobalID is { } globalId && DeviceGlobalID.Parse(globalId) is { } global)
            {
                var result = await _devices.RequestParticipantAsync(global.Home, "session.rename", globalId, title: name.Text.Trim());
                if (result.Outcome != "completed")
                    await new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Could not rename session", Content = result.Detail, CloseButtonText = "OK" }.ShowAsync();
            }
            Refresh();
        }
        catch (Exception ex) { System.Diagnostics.Debug.WriteLine("Rename dialog: " + ex.GetType().Name); }
    }

    private async void OnParkClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SidebarSession row }) return;
        // Parking is view state only: the lease releases for remotes, the
        // placement clears for all, and the session keeps running at home.
        _placements.Park(row.Key);
        _placements.Save(_dataFolder);
        if (row.GlobalID is not null) await _devices.ReleaseRemoteAsync(row.GlobalID);
        Refresh();
    }


    // Pane slots 1-3 (Mac parity): placing focuses the pane, takes the
    // lease for remotes, evicts the pane's previous occupant, and persists.
    // The badge in each visible pane replaces the old pane strip: focus
    // follows the click, and the draft takes keyboard focus.
    private async void OnPlaceClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SidebarSession row, Content: string label }) return;
        if (label is not ("1" or "2" or "3")) return;
        var pane = label[0] - '0';
        await PlaceSessionAsync(row, pane);
    }

    private async Task PlaceSessionAsync(SidebarSession row, int pane)
    {
        if (row.LocalSessionID is { } local && !await _devices.AcquireLocalAsync(local)) return;
        var displaced = _placements.KeyIn(pane);
        if (displaced is not null && displaced != row.Key && displaced.StartsWith("remote:", StringComparison.Ordinal))
            await _devices.ReleaseRemoteAsync(displaced["remote:".Length..]);
        _placements.Assign(row.Key, pane);
        _placements.Save(_dataFolder);
        _focusedPane = pane;
        if (row.GlobalID is { } gid) await _devices.AcquireRemoteAsync(gid);
        Refresh();
        _panes[pane - 1].FocusDraft();
    }

}
