using Converse.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Security.Credentials;
namespace Converse.App;

public sealed partial class MainWindow
{
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _agentTimer;
    private bool _agentDialogOpen, _quitAccepted;
    private readonly List<Window> _agentWindows = new();
    private static string? ReadAgentKey(string name)
    {
        try { var credential = new PasswordVault().Retrieve(SetupPreview.CredentialResource, name); credential.RetrievePassword(); return credential.Password; }
        catch { return null; }
    }
    private void InitializeAgents()
    {
        _devices.Agents.ReadSecret = ReadAgentKey;
        _store.AgentSecret = ReadAgentKey;
        _agentTimer = DispatcherQueue.CreateTimer(); _agentTimer.Interval = TimeSpan.FromSeconds(5);
        _agentTimer.Tick += (_, _) => _devices.Agents.Tick(DateTime.UtcNow); _agentTimer.Start();
        _devices.AgentWidgetRequested += session => DispatcherQueue.TryEnqueue(() => ShowAgentScoreboard(session));
        AppWindow.Closing += async (_, e) =>
        {
            if (_quitAccepted) return;
            if (_supportDialog is not null) { _quitAccepted = true; return; }
            var (busy, loops) = _store.QuitActivity();
            if (loops == 0 && busy == 0) return;
            e.Cancel = true;
            var text = (loops > 0 ? $"{loops} agent{(loops == 1 ? "" : "s")} with enabled loops will not run until the app is restarted.\n\n" : "") + (busy > 0 ? $"{busy} active turn(s) will stop.\n\n" : "") + "Your conversations and drafts are saved.";
            try
            {
                var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Quit Converse?", Content = text, PrimaryButtonText = "Quit", CloseButtonText = "Cancel" };
                if (await dialog.ShowAsync() == ContentDialogResult.Primary) { _quitAccepted = true; Close(); }
            }
            catch { /* An existing dialog must finish before another quit review. */ }
        };
        Closed += (_, _) => { _agentTimer?.Stop(); _devices.Agents.Shutdown(); _store.Save(); _devices.Dispose(); };
    }
    private async void OnAgentSetupRow(object sender, RoutedEventArgs e)
    {
        if (sender is MenuFlyoutItem { Tag: SidebarSession row }) await OpenAgentSetup(row);
    }
    private async void OnTeachRow(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuFlyoutItem { Tag: SidebarSession row }) return;
        if (row.LocalSessionID is { } id && _store.Sessions.FirstOrDefault(s => s.Id == id) is { } session) _devices.TeachSwitchboard(session);
        else if (row.GlobalID is { } target) await _devices.SendRemoteCommandAsync(target, new DeviceCommandPayload { Action = "teachSwitchboard" });
    }
    private async void OnNewAgentClick(object sender, RoutedEventArgs e)
    {
        if (_agentDialogOpen) return;
        _agentDialogOpen = true;
        try
        {
            var name = new TextBox { Header = "Agent name", Text = "New Agent" };
            var homes = new ComboBox { Header = "Runs on", HorizontalAlignment = HorizontalAlignment.Stretch };
            homes.Items.Add(new SettingItem(_devices.DeviceId, "This PC"));
            foreach (var home in _devices.Homes.Values.Where(h => h.Online && _devices.CanHostAgent(h.DeviceID))) homes.Items.Add(new SettingItem(home.DeviceID, home.DeviceName));
            homes.SelectedIndex = 0;
            var content = new StackPanel { Spacing = 10 }; content.Children.Add(name); content.Children.Add(homes);
            content.Children.Add(new TextBlock { Text = "Starts paused. API credentials stay on the selected home computer.", TextWrapping = TextWrapping.Wrap });
            var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Create Agent", Content = content, PrimaryButtonText = "Create", CloseButtonText = "Cancel" };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || homes.SelectedItem is not SettingItem homeItem) return;
            if (homeItem.Id == _devices.DeviceId) _store.CreateAgent(name.Text);
            else { var response = await _devices.RequestParticipantAsync(homeItem.Id, "agent.create", title: name.Text); await AgentNotice(response.Detail); }
        }
        catch (Exception ex) { await AgentNotice(ex is ArgumentException ? ex.Message : "Could not create this agent. Check the home connection."); }
        finally { _agentDialogOpen = false; Refresh(); }
    }
    internal async Task AgentNotice(string text)
    {
        try { await new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Agent", Content = text, CloseButtonText = "OK" }.ShowAsync(); } catch { }
    }
    internal async Task OpenAgentSetup(SidebarSession row)
    {
        if (_agentDialogOpen) return; _agentDialogOpen = true;
        try
        {
            var local = row.LocalSessionID is { } id ? _store.Sessions.FirstOrDefault(s => s.Id == id) : null;
            var target = row.GlobalID ?? (local is not null ? new DeviceGlobalID(_devices.DeviceId, local.Id).ToString() : null);
            if (target is null || DeviceGlobalID.Parse(target) is not { } reference) return;
            DeviceAgentSettings? settings;
            if (local?.Agent is { } agent) settings = DeviceJson.Decode<DeviceAgentSettings>(DeviceJson.Encode(agent.Settings));
            else { var response = await _devices.RequestParticipantAsync(reference.Home, "agent.settings", target); settings = response.Settings; if (settings is null) { await AgentNotice(response.Detail); return; } }
            var initialHAURL = settings.HomeAssistantURL;
            var initialHAEntities = settings.HomeAssistantEntities;
            var initialHARead = settings.HomeAssistantRead;
            var panel = new StackPanel { Spacing = 8, Width = 470 };
            panel.Children.Add(new TextBlock { Text = "Runs on " + (local is null ? "the home system" : "this system") + " when Converse is open. Your messages here are shared with the selected provider. If you enable this agent to examine selected sessions, those sessions’ content will also be shared.", TextWrapping = TextWrapping.Wrap });
            var modelOptions = local is null ? settings.ModelOptions ?? new() : await AgentModels.DiscoverAsync(_store, ReadAgentKey("meta"));
            if (!modelOptions.Any(o => o.Id == settings.Model)) modelOptions.Insert(0, new() { Id = settings.Model, Label = AgentModels.Label(settings.Model) + " · current" });
            var model = new ComboBox { Header = "Model", ItemsSource = modelOptions, DisplayMemberPath = "Label", SelectedValuePath = "Id", SelectedValue = settings.Model, HorizontalAlignment = HorizontalAlignment.Stretch }; panel.Children.Add(model);
            var repo = new TextBox { Header = "GitHub owner/name · optional", Text = settings.Repository }; panel.Children.Add(repo);
            var haURL = new TextBox { Header = "Home Assistant URL · optional", Text = settings.HomeAssistantURL ?? "", PlaceholderText = "http://homeassistant.local:8123" }; panel.Children.Add(haURL);
            var haEntities = new TextBox { Header = "Readable Home Assistant entity IDs · comma separated", Text = settings.HomeAssistantEntities ?? "" }; panel.Children.Add(haEntities);
            var haRead = new CheckBox { Content = "Let this agent read selected Home Assistant states", IsChecked = settings.HomeAssistantRead == true }; panel.Children.Add(haRead);
            if (local is null) { haURL.IsEnabled = false; haEntities.IsEnabled = false; haRead.IsEnabled = false; }
            panel.Children.Add(new TextBlock { Text = local is null ? "Home Assistant access is set on the agent's home computer." : "Read only. Choose up to 32 entities; their states, names and observation times go to the selected model, never the token. Use HTTPS outside a trusted local network. Tokens stay on this computer.", TextWrapping = TextWrapping.Wrap });
            var objective = new TextBox { Header = "Objective and success criteria", Text = settings.Objective, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 90 }; panel.Children.Add(objective);
            var enabled = new CheckBox { Content = "Enable automatic loop", IsChecked = settings.Enabled }; panel.Children.Add(enabled);
            var seconds = new NumberBox { Header = "Fixed interval · minutes", Value = settings.IntervalSeconds / 60, Minimum = 1, Maximum = 525600 }; panel.Children.Add(seconds);
            var schedule = new TextBox { Header = "Text schedule · leave blank for fixed interval", Text = settings.ScheduleText ?? "", PlaceholderText = "every 20 minutes while the US stock market is open" }; panel.Children.Add(schedule);
            var zone = new TextBox { Header = "Time zone", Text = settings.ScheduleTimeZone ?? "America/New_York" }; panel.Children.Add(zone);
            var preview = new TextBlock { TextWrapping = TextWrapping.Wrap }; panel.Children.Add(preview);
            var previewButton = new Button { Content = "Preview schedule" }; panel.Children.Add(previewButton);
            void ReadSchedule() { settings.IntervalSeconds = seconds.Value * 60; settings.ScheduleText = schedule.Text; settings.ScheduleTimeZone = zone.Text; }
            previewButton.Click += (_, _) => { try { ReadSchedule(); var rule = AgentSchedule.Compile(settings); var now = DateTime.UtcNow; var times = new List<string>(); for (var n = 0; n < 3 && rule.Next(now) is { } next; n++) { times.Add(next.ToLocalTime().ToString("g")); now = next; } preview.Text = string.Join(" · ", times) + " (this device's time)"; } catch (Exception ex) { preview.Text = ex.Message; } };
            var runs = new NumberBox { Header = "Maximum turns per loop", Value = settings.TurnLimit, Minimum = 1, Maximum = 1000 }; panel.Children.Add(runs);
            var cadence = new NumberBox { Header = "Refresh scoreboard every N loops", Value = settings.ScoreboardEveryLoops ?? 1, Minimum = 1, Maximum = 1000 }; panel.Children.Add(cadence);
            var artDirection = new TextBox { Header = "Scoreboard art direction", Text = settings.ArtDirection ?? "", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxLength = 4000 }; panel.Children.Add(artDirection);
            var art = new CheckBox { Content = "Generate mood art", IsChecked = settings.GenerateArt }; panel.Children.Add(art);
            panel.Children.Add(new TextBlock { Text = "Sessions this agent may read and message · select explicitly", TextWrapping = TextWrapping.Wrap });
            var scope = new List<(string Id, CheckBox Box)>();
            void AddScope(string global, string label) { if (global == target) return; var box = new CheckBox { Content = label, IsChecked = settings.Watched.Contains(global) }; scope.Add((global, box)); panel.Children.Add(box); }
            foreach (var s in _store.Sessions) AddScope(new DeviceGlobalID(_devices.DeviceId, s.Id).ToString(), "This PC · " + s.Title);
            foreach (var home in _devices.Homes.Values) foreach (var s in home.Rows) AddScope(s.GlobalID, home.DeviceName + " · " + s.Title);
            var error = new TextBlock { TextWrapping = TextWrapping.Wrap };
            PasswordBox? key = null, githubKey = null, haKey = null; CheckBox? remove = null, removeGithub = null, removeHA = null;
            if (local is not null)
            {
                key = new PasswordBox { PasswordRevealMode = PasswordRevealMode.Hidden, Header = "Meta API key · blank keeps saved key" }; panel.Children.Add(key);
                remove = new CheckBox { Content = "Remove saved Meta key" }; panel.Children.Add(remove);
                githubKey = new PasswordBox { Header = "GitHub token · optional, blank keeps saved token", PasswordRevealMode = PasswordRevealMode.Hidden }; panel.Children.Add(githubKey);
                removeGithub = new CheckBox { Content = "Remove saved GitHub token" }; panel.Children.Add(removeGithub);
                haKey = new PasswordBox { Header = "Home Assistant long-lived token · blank keeps saved token", PasswordRevealMode = PasswordRevealMode.Hidden }; panel.Children.Add(haKey);
                removeHA = new CheckBox { Content = "Remove saved Home Assistant token" }; panel.Children.Add(removeHA);
                var testHA = new Button { Content = "Test Home Assistant" }; panel.Children.Add(testHA);
                testHA.Click += async (_, _) => {
                    testHA.IsEnabled = false; error.Text = "Checking selected entities…";
                    try { error.Text = await HomeAssistantAgent.TestAsync(haURL.Text, haEntities.Text, string.IsNullOrWhiteSpace(haKey.Password) ? ReadAgentKey("homeAssistant") : haKey.Password); }
                    catch (Exception ex) { error.Text = ex is ArgumentException or InvalidOperationException ? ex.Message : "Could not reach Home Assistant. Check its URL and the network."; }
                    finally { testHA.IsEnabled = true; }
                };
                panel.Children.Add(new TextBlock { Text = "Saved in Windows Credential Manager. Voice, Discord and file triggers remain Mac-home features in this release.", TextWrapping = TextWrapping.Wrap });
            }
            panel.Children.Add(error);
            var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Agent Setup / Loop", Content = new ScrollViewer { Content = panel, MaxHeight = 620 }, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
            dialog.PrimaryButtonClick += async (_, args) =>
            {
                var deferral = args.GetDeferral();
                try
                {
                    ReadSchedule(); AgentSchedule.Compile(settings);
                    if (!double.IsFinite(runs.Value) || !double.IsFinite(cadence.Value)) throw new ArgumentException("Enter a run allowance and scoreboard interval.");
                    settings.Model = model.SelectedValue as string ?? throw new ArgumentException("Choose a model."); settings.Repository = repo.Text.Trim(); settings.Objective = objective.Text; settings.Enabled = enabled.IsChecked == true;
                    settings.HomeAssistantURL = local is null ? initialHAURL : haURL.Text.Trim();
                    settings.HomeAssistantEntities = local is null ? initialHAEntities : haEntities.Text.Trim();
                    settings.HomeAssistantRead = local is null ? initialHARead : haRead.IsChecked == true;
                    HomeAssistantAgent.Validate(settings.HomeAssistantURL, settings.HomeAssistantEntities, settings.HomeAssistantRead == true);
                    settings.TurnLimit = checked((int)runs.Value); settings.ScoreboardEveryLoops = checked((int)cadence.Value); settings.GenerateArt = art.IsChecked == true; settings.ArtDirection = artDirection.Text;
                    // Preserve selected IDs temporarily absent from the current directory.
                    settings.Watched = settings.Watched.Except(scope.Select(s => s.Id)).Concat(scope.Where(s => s.Box.IsChecked == true).Select(s => s.Id)).Distinct().ToList();
                    if (local?.Agent is { } config)
                    {
                        if (remove?.IsChecked == true && !string.IsNullOrWhiteSpace(key?.Password)) throw new ArgumentException("Choose key replacement or removal, not both.");
                        if (removeGithub?.IsChecked == true && !string.IsNullOrWhiteSpace(githubKey?.Password)) throw new ArgumentException("Choose GitHub token replacement or removal, not both.");
                        if (removeHA?.IsChecked == true && !string.IsNullOrWhiteSpace(haKey?.Password)) throw new ArgumentException("Choose Home Assistant token replacement or removal, not both.");
                        if (settings.HomeAssistantRead == true && (removeHA?.IsChecked == true || string.IsNullOrWhiteSpace(haKey?.Password) && string.IsNullOrWhiteSpace(ReadAgentKey("homeAssistant")))) throw new ArgumentException("Add a Home Assistant token before enabling state reading.");
                        config.Apply(settings); _store.Save();
                        var vault = new PasswordVault();
                        if (removeGithub?.IsChecked == true) { try { vault.Remove(vault.Retrieve(SetupPreview.CredentialResource, "github")); } catch { } }
                        else if (!string.IsNullOrWhiteSpace(githubKey?.Password)) vault.Add(new PasswordCredential(SetupPreview.CredentialResource, "github", githubKey.Password.Trim()));
                        if (remove?.IsChecked == true) { try { vault.Remove(vault.Retrieve(SetupPreview.CredentialResource, "meta")); } catch { } }
                        else if (!string.IsNullOrWhiteSpace(key?.Password)) vault.Add(new PasswordCredential(SetupPreview.CredentialResource, "meta", key.Password.Trim()));
                        if (removeHA?.IsChecked == true) { try { vault.Remove(vault.Retrieve(SetupPreview.CredentialResource, "homeAssistant")); } catch { } }
                        else if (!string.IsNullOrWhiteSpace(haKey?.Password)) vault.Add(new PasswordCredential(SetupPreview.CredentialResource, "homeAssistant", haKey.Password.Trim()));
                    }
                    else { var response = await _devices.RequestParticipantAsync(reference.Home, "agent.configure", target, settings: settings); if (response.Outcome != "completed") throw new ArgumentException(response.Detail); }
                }
                catch (Exception ex) { args.Cancel = true; error.Text = ex is ArgumentException ? ex.Message : "Could not save. Reload settings before retrying."; }
                finally { deferral.Complete(); }
            };
            await dialog.ShowAsync();
        }
        catch { await AgentNotice("Agent Setup could not open. Finish any existing dialog or check the home connection, then retry."); }
        finally { _agentDialogOpen = false; Refresh(); }
    }
    internal async Task RunAgentOnce(SidebarSession row)
    {
        if (row.LocalSessionID is { } id && _store.Sessions.FirstOrDefault(s => s.Id == id) is { Agent: not null } session)
        {
            session.Pending.Add(new PendingPrompt { Text = "[Human-requested agent run] Check progress and refresh the scoreboard.", Autonomous = true }); _store.Save(); _store.RunNext(session);
        }
        else if (row.GlobalID is { } target && DeviceGlobalID.Parse(target) is { } reference) { var result = await _devices.RequestParticipantAsync(reference.Home, "agent.run", target); await AgentNotice(result.Detail); }
    }
    internal void ShowAgentScoreboard(ChatSession session)
    {
        if (session.Agent is not { } agent) return;
        var window = new Window { Title = session.Title + " · Scoreboard" };
        var scroll = new ScrollViewer(); window.Content = scroll;
        string? signature = null;
        void Render()
        {
            var next = System.Text.Json.JsonSerializer.Serialize(agent.Widget) + agent.ArtPath + agent.ArtAtUtc;
            if (next == signature) return; signature = next;
            var panel = new StackPanel { Spacing = 12, Padding = new Thickness(20), Background = new SolidColorBrush(Microsoft.UI.Colors.Black) };
            if (agent.ArtPath is { } path && File.Exists(path)) panel.Children.Add(new Image { Source = new BitmapImage(new Uri(path)), MaxHeight = 380, Stretch = Stretch.UniformToFill });
            foreach (var metric in agent.Widget?.Metrics ?? new()) panel.Children.Add(new TextBlock { Text = metric.Label + ": " + metric.Value, FontSize = 24, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White), TextWrapping = TextWrapping.Wrap });
            panel.Children.Add(new TextBlock { Text = agent.Widget?.Summary ?? "No scoreboard yet. Run the agent to collect evidence.", Foreground = new SolidColorBrush(Microsoft.UI.Colors.White), TextWrapping = TextWrapping.Wrap });
            scroll.Content = panel;
        }
        void Changed() => DispatcherQueue.TryEnqueue(Render);
        _store.Changed += Changed;
        Render(); _agentWindows.Add(window);
        window.Closed += (_, _) => { _store.Changed -= Changed; _agentWindows.Remove(window); }; window.Activate();
    }
}
