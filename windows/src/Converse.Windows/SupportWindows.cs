using Converse.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Diagnostics;
using System.Text.Json.Nodes;

namespace Converse.App;

internal static class SetupPreview
{
#if CONVERSE_SETUP_PREVIEW
    public static bool Enabled => true;
#else
    public static bool Enabled => false;
#endif
#if CONVERSE_DEMO
    public static bool Demo => true;
#else
    public static bool Demo => false;
#endif
    public static string Name => Demo ? "Converse Demo" : "Converse Setup Preview";
    public static string Folder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Name);
    public static string CredentialResource => Demo ? "Converse.Demo.Agent" : Enabled ? "Converse.SetupPreview.Agent" : "Converse.Agent";
    public static void Initialize()
    {
        if (Enabled) Environment.SetEnvironmentVariable("CONVERSE_DATA_DIR", Folder);
    }
}

public sealed partial class MainWindow
{
    private async void OnResetDemo(object sender, RoutedEventArgs e)
    {
        if (!SetupPreview.Demo) return;
        try
        {
            var dialog = new ContentDialog {
                XamlRoot = Content.XamlRoot, Title = "Reset Converse Demo?",
                Content = "This stops Demo’s work and quits. Reopen Converse Demo to start the welcome walkthrough again, with fresh sessions, provider logins and Group pairing. Saved Demo API tokens will be removed. The old Demo files are kept in a local backup. Your normal Converse app and project files are untouched.",
                PrimaryButtonText = "Reset and Quit", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            DemoReset.Request(_dataFolder, SetupPreview.Demo);
            _quitAccepted = true;
            Close();
        }
        catch (Exception ex) { await AgentNotice("Demo reset could not be started: " + ex.Message); }
    }
    private ContentDialog? _supportDialog;
    private readonly CancellationTokenSource _supportCancellation = new();
    private Process? _supportLogin;
    private readonly List<Window> _supportHelpWindows = new();
    private void InitializeSupport()
    {
        _store.AppSupportRequest = HandleSupportRequest;
        foreach (var support in _store.Sessions.Where(s => s.SupportAssistant)) SupportSetup.ConfigureAgent(_store, support);
        Closed += (_, _) =>
        {
            _supportCancellation.Cancel();
            try { if (_supportLogin is { HasExited: false }) _supportLogin.Kill(entireProcessTree: true); } catch { }
            foreach (var window in _supportHelpWindows.ToArray()) window.Close();
        };
        if (SetupPreview.Enabled) foreach (var entry in _store.Entries)
        {
            entry.AccountDirectory = Path.Combine(_store.Folder, "SupportAccounts", entry.Engine);
            entry.UseDefaultAccountStore = false;
            Directory.CreateDirectory(entry.AccountDirectory);
        }
        // Existing workspaces opt in through Help; a fresh workspace gets NUX.
        if (_store.Sessions.Any(s => !s.SupportAssistant)) return;
        _store.Save();
        var setup = new SupportSetup(_store);
        var session = setup.Session();
        if (_store.Sessions.Count == 1) { _placements.Clear(); ShowSupportSession(session); }
        if (!session.SupportSetupCompleted)
        {
            bool shown = false;
            if (Content is FrameworkElement root)
                root.Loaded += async (_, _) => { if (!shown) { shown = true; await ShowSupportSetup(closeOnCancel: true); } };
        }
    }

    private async void OnAppSupport(object sender, RoutedEventArgs e)
    {
        var support = new SupportSetup(_store).Session();
        ShowSupportSession(support);
        if (!support.SupportSetupCompleted) await ShowSupportSetup();
    }

    private void ShowSupportSession(ChatSession session)
    {
        _placements.Assign("local:" + session.Id, 1); _placements.Save(_dataFolder); _focusedPane = 1; Refresh();
    }

    internal StackPanel SupportLinks()
    {
        var panel = new StackPanel { Orientation = Orientation.Vertical, Spacing = 0 };
        foreach (var row in new[] {
            new[] { ("README", "readme"), ("Security & privacy", "security"), ("Discord", "discord"), ("Connect the Meta Muse iPhone app", "muse-iphone") },
            new[] { ("First coding session", "first-session"), ("First agent", "first-agent"), ("Create a Group", "first-group") } })
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (var (label, target) in row)
            {
                var link = new HyperlinkButton { Content = label, Padding = new Thickness(4), FontSize = 12 };
                link.Click += (_, _) => ShowSupportHelp(target);
                line.Children.Add(link);
            }
            panel.Children.Add(line);
        }
        return panel;
    }
    private void OnSecurityHelp(object sender, RoutedEventArgs e) => ShowSupportHelp("security");
    private void ShowSupportHelp(string target)
    {
        var topic = AppSupportTeaching.Topics.GetValueOrDefault(target);
        var query = target == "muse-iphone" ? "Jolly" : target == "discord" ? "Discord" : target;
        var selected = topic is null ? null : _help?.Topic(topic);
        selected ??= _help?.Search(query).FirstOrDefault();
        var window = new Window { Title = "Converse Help · " + (selected?.Title ?? target) };
        var panel = new StackPanel { Padding = new Thickness(20), Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = selected?.Title ?? "Converse Help", FontSize = 24, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new TextBlock { Text = selected?.PlainText ?? "This build does not include the requested Help article.", IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap });
        window.Content = new ScrollViewer { Content = panel }; window.AppWindow.Resize(new Windows.Graphics.SizeInt32(740, 650));
        _supportHelpWindows.Add(window); window.Closed += (_, _) => _supportHelpWindows.Remove(window); window.Activate();
    }
    private async Task ShowSupportSetup(bool closeOnCancel = false)
    {
        if (_supportDialog is not null || _supportCancellation.IsCancellationRequested) return;
        var setup = new SupportSetup(_store); var session = setup.Session();
        if (session.SupportSetupCompleted) return;
        ShowSupportSession(session);
        var panel = new StackPanel { Spacing = 12, Width = 600 };
        panel.Children.Add(new TextBlock { Text = "I’m Converse App Support. I can help you set up and use Converse.", TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(SupportLinks());
        panel.Children.Add(new TextBlock { Text = "But first, you need to set up one provider. Pick 1, 2, or 3.", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        var choices = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; panel.Children.Add(choices);
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap }; panel.Children.Add(status);
        var check = new Button { Content = "I’m signed in · Check connection", IsEnabled = session.Entry.Engine != "support" }; panel.Children.Add(check);
        var install = new HyperlinkButton { Content = "Provider installation instructions", Visibility = Visibility.Collapsed }; panel.Children.Add(install);
        var cancel = new Button { Content = "Cancel connection check", Visibility = Visibility.Collapsed }; panel.Children.Add(cancel);
        panel.Children.Add(new TextBlock { Text = AppSupportTeaching.Invitation, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new TextBlock { Text = (SetupPreview.Demo ? "DEMO" : "SETUP PREVIEW") + " · Separate conversations, logins, credentials and device identity", FontSize = 11, TextWrapping = TextWrapping.Wrap });
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Welcome to Converse!", Content = new ScrollViewer { Content = panel, MaxHeight = 540 }, CloseButtonText = "Quit" };
        dialog.Resources["ContentDialogMaxWidth"] = 700d;
        _supportDialog = dialog;
        var working = false; var allowClose = false; CancellationTokenSource? probeCancellation = null;
        dialog.Closing += (_, args) => { if (!allowClose) args.Cancel = true; };
        dialog.CloseButtonClick += (_, _) => { allowClose = true; _quitAccepted = true; };
        void Enable(bool enabled) { working = !enabled; choices.IsHitTestVisible = enabled; choices.Opacity = enabled ? 1 : .5; check.IsEnabled = enabled && session.Entry.Engine != "support"; }
        async Task Verify()
        {
            if (working || session.Busy) { status.Text = "Wait for the previous check to stop, then retry."; return; }
            Enable(false); cancel.Visibility = Visibility.Visible;
            probeCancellation = CancellationTokenSource.CreateLinkedTokenSource(_supportCancellation.Token);
            status.Text = "Checking one short model response…";
            try
            {
                if (await setup.VerifyAsync(TimeSpan.FromSeconds(90), probeCancellation.Token))
                { allowClose = true; dialog.Hide(); }
                else status.Text = "Connection was not confirmed. Setup remains locked. Retry login or check again.";
            }
            catch (Exception ex) { status.Text = "Connection check failed: " + ex.Message; }
            finally { cancel.Visibility = Visibility.Collapsed; Enable(true); probeCancellation.Dispose(); probeCancellation = null; }
        }
        cancel.Click += (_, _) => probeCancellation?.Cancel();
        check.Click += async (_, _) => await Verify();
        async Task Choose(string engine)
        {
            if (working) return;
            Enable(false); install.Visibility = Visibility.Collapsed;
            try
            {
                session = setup.SelectProvider(engine);
                if (CommandResolution.Resolve(session.Entry.Command) is null)
                {
                    status.Text = "Install " + session.Entry.Name + "’s command-line app, then select it again.";
                    install.NavigateUri = new Uri(engine == "claude" ? "https://code.claude.com/docs/en/setup" : engine == "codex" ? "https://developers.openai.com/codex/cli/" : "https://developers.meta.com/" );
                    install.Visibility = Visibility.Visible; return;
                }
                status.Text = "Finish " + session.Entry.Name + "’s login in its console/browser. A model response will be checked afterward.";
                using var login = Process.Start(ProviderProfile.Login(session.Entry)) ?? throw new InvalidOperationException("Could not start provider login.");
                _supportLogin = login;
                await login.WaitForExitAsync(_supportCancellation.Token);
                _supportLogin = null;
                if (login.ExitCode != 0) { status.Text = "Login did not finish successfully. Select the provider to retry."; return; }
                Enable(true); await Verify();
            }
            catch (OperationCanceledException) { }
            catch (Exception ex) { status.Text = ex.Message; }
            finally { Enable(true); }
        }
        foreach (var (label, engine) in new[] { ("1. Meta Muse", "muse"), ("2. Claude", "claude"), ("3. Codex", "codex") })
        {
            var button = new Button { Content = label }; button.Click += async (_, _) => await Choose(engine); choices.Children.Add(button);
        }
        dialog.KeyDown += async (_, e) =>
        {
            var engine = e.Key switch { Windows.System.VirtualKey.Number1 => "muse", Windows.System.VirtualKey.Number2 => "claude", Windows.System.VirtualKey.Number3 => "codex", _ => null };
            if (engine is not null) { e.Handled = true; await Choose(engine); }
        };
        try { await dialog.ShowAsync(); }
        finally { _supportDialog = null; }
        if (!session.SupportSetupCompleted && closeOnCancel) { _quitAccepted = true; Close(); }
        else { Refresh(); _panes[0].FocusDraft(); }
    }

    // authority is the requesting turn's, captured when its prompt started;
    // the session may be running a different turn by the time this
    // dispatches, so nothing here reads that turn's provenance.
    private Task HandleSupportRequest(ChatSession source, JsonObject command, TurnAuthority authority)
    {
        var done = new TaskCompletionSource();
        if (!DispatcherQueue.TryEnqueue(async () =>
        {
            try
            {
                string result;
                try
                {
                    result = AppSupportActions.Execute(_store, source, authority, command, _help);
                    if (result.StartsWith("Coding session ready: ") && Guid.TryParse(result[22..], out var createdID))
                    {
                        ShowSupportSession(_store.Sessions.First(s => s.Id == createdID));
                        result += ". Displayed with the saved provider login; no prompt was sent.";
                    }
                    if (result == "UI")
                    {
                        var target = command["target"]?.GetValue<string>() ?? "";
                        if (command["action"]?.GetValue<string>() == "report-bug")
                        { result = await ShowBugReport(new GitHubBugReport(command["title"]!.GetValue<string>(), command["body"]!.GetValue<string>())); }
                        else if (command["action"]?.GetValue<string>() == "show-session")
                        {
                            var session = _store.Sessions.FirstOrDefault(s => s.Id.ToString().Equals(target, StringComparison.OrdinalIgnoreCase)) ?? throw new ArgumentException("Unknown local session ID.");
                            ShowSupportSession(session); result = "Session displayed.";
                        }
                        else if (target == "devices") { OpenGroupsDialog(); result = "Opened Groups. The human must complete pairing."; }
                        else if (target == "settings") { OnSetupClick(this, new RoutedEventArgs()); result = "Opened Setup."; }
                        else if (target == "agents" && command["title"]?.GetValue<string>() is { } title && _store.Sessions.FirstOrDefault(s => s.Agent is not null && s.Title == title) is { } agent)
                        {
                            await OpenAgentSetup(new SidebarSession("local:" + agent.Id, agent.Title, "", null, agent.Id, true, true, true)); result = "Agent settings closed. Configuration may have changed; inspect before claiming it was saved.";
                        }
                        else if (AppSupportTeaching.Topics.ContainsKey(target)) { ShowSupportHelp(target); result = "Opened installed Help."; }
                        else throw new ArgumentException("Unknown setup page.");
                    }
                }
                catch (Exception ex) { result = "App operation blocked: " + ex.Message; }
                AppSupportActions.Continue(_store, source, authority, result);
                done.TrySetResult();
            }
            catch (Exception ex) { done.TrySetException(ex); }
        })) done.TrySetException(new InvalidOperationException("Window is closing."));
        return done.Task;
    }
    private void OnTeachAppRow(object sender, RoutedEventArgs e)
    {
        if (sender is MenuFlyoutItem { Tag: SidebarSession { LocalSessionID: { } id } } && _store.Sessions.FirstOrDefault(s => s.Id == id) is { } session)
        {
            AppSupportTeaching.Teach(_store, session);
        }
    }
    private void OnDisableAppRow(object sender, RoutedEventArgs e)
    {
        if (sender is MenuFlyoutItem { Tag: SidebarSession { LocalSessionID: { } id } } && _store.Sessions.FirstOrDefault(s => s.Id == id) is { } session)
        { session.SupportTeachingVersion = null; _store.Save(); }
    }
}
