using Converse.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Diagnostics;
using Windows.Security.Credentials;
using Windows.ApplicationModel.DataTransfer;

namespace Converse.App;

public sealed partial class MainWindow
{
    private async void OnReportBug(object sender, RoutedEventArgs args)
    {
        await ShowBugReport(new GitHubBugReport("", "What happened:\n\nSteps to reproduce:\n\nWhat I expected:\n\nConverse " + VersionBuild));
    }
    private async Task<string> ShowBugReport(GitHubBugReport report)
    {
        string? key = null;
        try { var saved = new PasswordVault().Retrieve(SetupPreview.CredentialResource, "github"); saved.RetrievePassword(); key = saved.Password; } catch { }
        var title = new TextBox { Header = "Title", Text = report.Title, MaxLength = 200 };
        var body = new TextBox { Header = "Description", Text = report.Body, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 230, MaxLength = 12000 };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(new TextBlock { Text = "To: richardkaufmann/converse on GitHub" }); panel.Children.Add(title); panel.Children.Add(body);
        panel.Children.Add(new TextBlock { Text = "Review what you’re sharing. No logs, attachments or other conversations are added automatically.", TextWrapping = TextWrapping.Wrap });
        var diagnostics = new Button { Content = "Add diagnostic summary" };
        diagnostics.Click += (_, _) =>
        {
            var homes = _devices.Homes.Values.Where(h => _devices.IsParticipantAllowed(h.DeviceID, _devices.CurrentGroup?.Id)).ToArray();
            body.Text += BugReportPrivacy.Summary(VersionBuild, Environment.OSVersion.VersionString, _devices.CurrentGroup is not null, homes.Length, homes.Count(h => h.Online), _store.Sessions.Count, _store.Sessions.Count(s => s.Busy));
            status.Text = "Added only versions and counts. Review before submitting.";
        };
        var scrub = new Button { Content = "Remove likely secrets" };
        scrub.Click += (_, _) =>
        {
            title.Text = BugReportPrivacy.Scrub(title.Text); body.Text = BugReportPrivacy.Scrub(body.Text);
            status.Text = "Common secrets, email addresses, home paths and IPv4 addresses removed locally. This cannot guarantee anonymity; review the entire report.";
        };
        panel.Children.Add(diagnostics); panel.Children.Add(scrub);
        var credentialStatus = new TextBlock { Text = string.IsNullOrWhiteSpace(key) ? "Recommended: save a GitHub token once, then submit reports here." : "GitHub token saved. Submit reports directly from Converse.", TextWrapping = TextWrapping.Wrap };
        panel.Children.Add(credentialStatus);
        var tokenInput = new PasswordBox { Header = "GitHub token · blank keeps saved token", PasswordRevealMode = PasswordRevealMode.Hidden };
        var saveToken = new Button { Content = "Save token" }; panel.Children.Add(tokenInput); panel.Children.Add(saveToken);
        panel.Children.Add(new HyperlinkButton { Content = "Create or manage a GitHub token", NavigateUri = new Uri("https://github.com/settings/tokens") });
        panel.Children.Add(new TextBlock { Text = "The token needs repository access and permission to create issues. Without one, copy the report and submit it on GitHub instead. Discord is not required.", TextWrapping = TextWrapping.Wrap });
        var copy = new Button { Content = "Copy description" };
        copy.Click += (_, _) => { var data = new DataPackage(); data.SetText(body.Text); Clipboard.SetContent(data); }; panel.Children.Add(copy);
        var issues = new HyperlinkButton { Content = "Issue list", NavigateUri = new Uri("https://github.com/richardkaufmann/converse/issues") }; panel.Children.Add(issues); panel.Children.Add(status);
        var hasToken = !string.IsNullOrWhiteSpace(key);
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Report a Converse bug", Content = new ScrollViewer { Content = panel, MaxHeight = 580 }, PrimaryButtonText = hasToken ? "Submit report" : "Continue on GitHub…", SecondaryButtonText = hasToken ? "Continue on GitHub…" : "", CloseButtonText = "Cancel" };
        saveToken.Click += (_, _) =>
        {
            var value = tokenInput.Password.Trim();
            if (value.Length == 0) { status.Text = "Paste a GitHub token first."; return; }
            try
            {
                new PasswordVault().Add(new PasswordCredential(SetupPreview.CredentialResource, "github", value));
                key = value; tokenInput.Password = ""; hasToken = true;
                dialog.PrimaryButtonText = "Submit report"; dialog.SecondaryButtonText = "Continue on GitHub…";
                credentialStatus.Text = "GitHub token saved in Windows Credential Manager. It is also available in Agent Setup.";
            }
            catch { status.Text = "Could not save the GitHub token in Windows Credential Manager."; }
        };
        string result = "Bug report review closed. Nothing was submitted.";
        bool attempted = false;
        void OpenBrowser(ContentDialogButtonClickEventArgs e)
        {
            try
            {
                Process.Start(new ProcessStartInfo(new GitHubBugReport(title.Text, body.Text).BrowserURL().AbsoluteUri) { UseShellExecute = true });
                result = "Draft opened on GitHub. Sign in if asked, then click Submit new issue. Nothing has been filed by Converse.";
            }
            catch (Exception ex) { e.Cancel = true; status.Text = ex.Message; }
        }
        dialog.SecondaryButtonClick += (_, e) => OpenBrowser(e);
        dialog.PrimaryButtonClick += async (_, e) =>
        {
            if (!hasToken) { OpenBrowser(e); return; }
            e.Cancel = true;
            if (attempted) return;
            GitHubBugReport current;
            try { current = new GitHubBugReport(title.Text, body.Text).Validated(); }
            catch (Exception ex) { status.Text = ex.Message; return; }
            attempted = true; dialog.IsPrimaryButtonEnabled = false; dialog.IsSecondaryButtonEnabled = false; title.IsEnabled = false; body.IsEnabled = false; saveToken.IsEnabled = false; tokenInput.IsEnabled = false;
            diagnostics.IsEnabled = false; scrub.IsEnabled = false;
            var deferred = e.GetDeferral();
            try
            {
                using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(30) };
                var receipt = await current.SubmitAsync(key!, client);
                result = "Bug report filed: " + receipt.AbsoluteUri; status.Text = result;
                issues.Content = "View filed issue"; issues.NavigateUri = receipt; dialog.CloseButtonText = "Done";
            }
            catch (Exception ex) { result = status.Text = ex.Message; dialog.IsSecondaryButtonEnabled = true; }
            finally { deferred.Complete(); }
        };
        await dialog.ShowAsync(); return result;
    }
}
