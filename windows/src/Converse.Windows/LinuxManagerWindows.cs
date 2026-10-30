using System.Diagnostics;
using Converse.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using WinRT.Interop;

namespace Converse.App;

// Windows reference manager for the frozen Linux contract. All SSH/admin
// behavior lives in Converse.Core so fake-process tests cover the command
// boundary; this file only presents state and explicit human approvals.
public sealed partial class MainWindow
{
    private Window? _linuxWindow;
    private LinuxDeploymentManager? _linuxManager;
    private LinuxDeployment? _linuxSelected;
    private LinuxStatusSnapshot? _linuxStatus;
    private LinuxPairingBinding? _linuxJoinBinding;
    private LinuxPairingBinding? _linuxReviewBinding;
    private List<LinuxPairingBinding> _linuxRequestBindings = new();
    private Guid? _linuxOperationID;
    private string _linuxMessage = "";
    private string? _linuxTrustDestination;
    private string? _linuxVerifiedFingerprint;
    private bool _linuxBusy;

    private ComboBox? _linuxDeploymentsBox;
    private TextBlock? _linuxMessageBlock;
    private TextBlock? _linuxDetailsBlock;
    private TextBlock? _linuxHostKeyBlock;
    private TextBlock? _linuxJoinCodeBlock;
    private TextBlock? _linuxReviewCodeBlock;
    private TextBox? _linuxDisplayNameBox;
    private TextBox? _linuxDestinationBox;
    private TextBox? _linuxBootstrapPathBox;
    private TextBox? _linuxGroupNameBox;
    private TextBox? _linuxSponsorHostBox;
    private TextBox? _linuxSponsorPortBox;
    private TextBox? _linuxBundlePathBox;
    private TextBox? _linuxReleaseIDBox;
    private PasswordBox? _linuxSecretBox;
    private CheckBox? _linuxComparedHostKeyBox;
    private ComboBox? _linuxRequestsBox;

    private LinuxDeploymentManager LinuxManager =>
        _linuxManager ??= new LinuxDeploymentManager(
            new LinuxDeploymentRegistryStore(_dataFolder));

    private void OnLinuxClick(object sender, RoutedEventArgs e)
    {
        if (_linuxWindow is not null)
        {
            _linuxWindow.Activate();
            return;
        }

        var panel = new StackPanel { Spacing = 10, Padding = new Thickness(18), Width = 720 };

        TextBlock Header(string text) => new()
        {
            Text = text,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        };
        TextBlock Note(string text) => new()
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        Button ActionButton(string text)
        {
            return new Button
            {
                Content = text,
                HorizontalAlignment = HorizontalAlignment.Left,
            };
        }
        StackPanel Row(params UIElement[] children)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            foreach (var child in children) row.Children.Add(child);
            return row;
        }

        panel.Children.Add(Header("Linux homes"));
        panel.Children.Add(Note(
            "Linux runs headless at home: provider CLIs, credentials, sessions, agents, "
            + "and side effects stay there. This PC manages it with the system OpenSSH client. "
            + "SSH host trust, Converse group pairing, and release signing are separate checks."));

        _linuxDeploymentsBox = new ComboBox
        {
            Header = "Saved Linux deployments",
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        _linuxDeploymentsBox.SelectionChanged += async (_, _) =>
        {
            if (_linuxDeploymentsBox.SelectedItem is SettingItem item &&
                Guid.TryParse(item.Id, out var deploymentID))
            {
                _linuxSelected = LinuxManager.Deployments
                    .FirstOrDefault(deployment => deployment.DeploymentID == deploymentID);
                await RefreshLinuxStatusAsync();
            }
        };
        panel.Children.Add(_linuxDeploymentsBox);

        var refresh = ActionButton("Refresh status");
        refresh.Click += async (_, _) => await RefreshLinuxStatusAsync();
        var forget = ActionButton("Forget locally");
        forget.Click += (_, _) =>
        {
            if (_linuxSelected is null) return;
            LinuxManager.RegistryStore.Remove(_linuxSelected.DeploymentID);
            _linuxSelected = null;
            _linuxStatus = null;
            SetLinuxMessage("Deployment removed from this PC only; the Linux home was not changed.");
            RenderLinuxDeployments();
            RenderLinuxDetails();
        };
        panel.Children.Add(Row(refresh, forget));
        _linuxDetailsBlock = Note("No Linux deployment selected.");
        panel.Children.Add(_linuxDetailsBlock);

        panel.Children.Add(Header("Set up a new Linux home"));
        _linuxDisplayNameBox = new TextBox { Header = "Display name", Text = "Linux Home" };
        _linuxDestinationBox = new TextBox
        {
            Header = "SSH destination or config alias",
            PlaceholderText = "linux-home",
        };
        _linuxBootstrapPathBox = new TextBox
        {
            Header = "Published Linux converse executable",
            PlaceholderText = @"C:\path\to\converse",
        };
        panel.Children.Add(_linuxDisplayNameBox);
        panel.Children.Add(_linuxDestinationBox);
        var browseBootstrap = ActionButton("Choose executable…");
        browseBootstrap.Click += async (_, _) =>
        {
            var path = await PickLinuxFileAsync();
            if (path is not null) _linuxBootstrapPathBox.Text = path;
        };
        panel.Children.Add(_linuxBootstrapPathBox);
        panel.Children.Add(browseBootstrap);

        panel.Children.Add(Note(
            "1. Open SSH Terminal. OpenSSH shows the host-key fingerprint; compare every "
            + "character with a trusted source from the Linux console or provider, and type "
            + "yes only if it matches. The following “Permission denied (none)” is expected "
            + "because this trust-only connection deliberately disables authentication."));
        var trustTerminal = ActionButton("Open SSH Terminal (host-key check)");
        trustTerminal.Click += (_, _) =>
        {
            var destination = _linuxDestinationBox.Text.Trim();
            _linuxTrustDestination = destination;
            _linuxVerifiedFingerprint = null;
            _linuxComparedHostKeyBox!.IsChecked = false;
            OpenSshTerminal(LinuxSshCommands.TrustOnlySsh(destination));
        };
        var verifyHostKey = ActionButton("Verify installed host key");
        verifyHostKey.Click += async (_, _) =>
        {
            var destination = _linuxDestinationBox.Text.Trim();
            await RunLinuxAsync("Verifying installed host key", async () =>
            {
                var key = await LinuxManager.VerifyInstalledHostKeyAsync(destination);
                _linuxTrustDestination = destination;
                _linuxVerifiedFingerprint = key?.FingerprintSHA256;
                if (_linuxHostKeyBlock is not null)
                {
                    _linuxHostKeyBlock.Text = key is null
                        ? "No installed host key was found yet."
                        : $"Installed {key.KeyType} host key: {key.FingerprintSHA256}";
                }
                SetLinuxMessage(key is null
                    ? "No approved SSH host key was found."
                    : "Installed host key found. Confirm that you compared it in the SSH terminal.");
            });
        };
        panel.Children.Add(Row(trustTerminal, verifyHostKey));
        _linuxHostKeyBlock = Note("No host key verified in this window yet.");
        panel.Children.Add(_linuxHostKeyBlock);
        _linuxComparedHostKeyBox = new CheckBox
        {
            Content = "I compared the full SSH fingerprint and approved it in the terminal",
        };
        panel.Children.Add(_linuxComparedHostKeyBox);

        var install = ActionButton("Install Converse on Linux");
        install.Click += async (_, _) =>
        {
            var destination = _linuxDestinationBox.Text.Trim();
            if (_linuxComparedHostKeyBox.IsChecked != true ||
                _linuxVerifiedFingerprint is null || _linuxTrustDestination != destination)
            {
                SetLinuxMessage("Verify the installed host key and confirm your terminal comparison first.");
                return;
            }
            await RunLinuxAsync("Installing Linux home", async () =>
            {
                var result = await LinuxManager.BootstrapAsync(
                    destination,
                    _linuxDisplayNameBox.Text,
                    _linuxBootstrapPathBox.Text.Trim(),
                    message => DispatcherQueue.TryEnqueue(() => SetLinuxMessage(message)));
                if (!result.Success)
                {
                    SetLinuxMessage(result.Message);
                    return;
                }
                _linuxSelected = result.Value;
                RenderLinuxDeployments();
                await RefreshLinuxStatusAsync();
                SetLinuxMessage("Linux home installed. Pair it with a group below.");
            });
        };
        panel.Children.Add(install);

        panel.Children.Add(Header("Group and pairing"));
        _linuxGroupNameBox = new TextBox { Header = "New group name on Linux", Text = "Converse Group" };
        panel.Children.Add(_linuxGroupNameBox);
        var createGroup = ActionButton("Create group on Linux");
        createGroup.Click += async (_, _) =>
        {
            if (_linuxSelected is null) { SetLinuxMessage("Select a Linux deployment first."); return; }
            await RunLinuxAsync("Creating Linux group", async () =>
            {
                var result = await LinuxManager.CreateGroupAsync(
                    _linuxSelected, _linuxGroupNameBox.Text.Trim());
                SetLinuxMessage(result.Success ? "Group created on Linux." : result.Message);
                if (result.Success) await RefreshLinuxStatusAsync();
            });
        };
        panel.Children.Add(createGroup);

        _linuxSponsorHostBox = new TextBox
        {
            Header = "This PC address reachable from Linux",
            Text = System.Net.Dns.GetHostName(),
        };
        _linuxSponsorPortBox = new TextBox
        {
            Header = "This PC Converse port",
            Text = (_devices.ListeningPort > 0
                ? _devices.ListeningPort
                : DeviceSyncService.DefaultPort).ToString(),
        };
        panel.Children.Add(_linuxSponsorHostBox);
        panel.Children.Add(_linuxSponsorPortBox);
        var beginJoin = ActionButton("Join this PC's group");
        beginJoin.Click += async (_, _) =>
        {
            if (_linuxSelected is null) { SetLinuxMessage("Select a Linux deployment first."); return; }
            if (_devices.CurrentGroup is null)
            {
                SetLinuxMessage("This PC is not in a group. Create or join one here, or create a group on Linux.");
                return;
            }
            if (!int.TryParse(_linuxSponsorPortBox.Text, out var port))
            {
                SetLinuxMessage("Enter this PC's Converse port.");
                return;
            }
            await RunLinuxAsync("Starting Linux group join", async () =>
            {
                var result = await LinuxManager.BeginJoinAsync(
                    _linuxSelected, _devices.DeviceId, _devices.DeviceId,
                    _linuxSponsorHostBox.Text.Trim(), port, _devices.CurrentGroup.Id);
                _linuxJoinBinding = result.Value;
                RenderLinuxJoinBinding();
                SetLinuxMessage(result.Success
                    ? "Compare all 8 groups with Converse Groups on this PC, then Pair on both sides."
                    : result.Message);
            });
        };
        panel.Children.Add(beginJoin);
        _linuxJoinCodeBlock = new TextBlock
        {
            Text = "Linux join code will appear here.",
            FontFamily = new FontFamily("Consolas"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        panel.Children.Add(_linuxJoinCodeBlock);
        var confirmJoin = ActionButton("Pair Linux side");
        confirmJoin.Click += async (_, _) =>
        {
            if (_linuxSelected is null || _linuxJoinBinding is null) return;
            await RunLinuxAsync("Pairing Linux with this group", async () =>
            {
                var result = await LinuxManager.PairJoinAsync(
                    _linuxSelected, _linuxJoinBinding,
                    () => _devices.GroupRequests.ToList(),
                    async request =>
                    {
                        if (_devices.GroupReview?.Request.Id != request.Id)
                            await _devices.ReviewGroupRequestAsync(request);
                        return _devices.GroupReview?.Request.Id == request.Id
                            ? _devices.GroupReview.Code : null;
                    },
                    async (request, binding, code) =>
                        await _devices.TryApproveGroupReviewAsync(request.Id, code));
                _linuxJoinBinding = result.Value ?? _linuxJoinBinding;
                RenderLinuxJoinBinding();
                SetLinuxMessage(result.Success
                    ? "Both sides approved. Refresh join until it completes."
                    : result.Message);
            });
        };
        var refreshJoin = ActionButton("Refresh join");
        refreshJoin.Click += async (_, _) =>
        {
            if (_linuxSelected is null || _linuxJoinBinding is null) return;
            await RunLinuxAsync("Refreshing Linux join", async () =>
            {
                var result = await LinuxManager.JoinStatusAsync(
                    _linuxSelected, _linuxJoinBinding.PairingID,
                    _linuxJoinBinding.RequestCorrelationID);
                _linuxJoinBinding = result.Value;
                RenderLinuxJoinBinding();
                if (result.Value?.State == "completed") await RefreshLinuxStatusAsync();
            });
        };
        var cancelJoin = ActionButton("Cancel join");
        cancelJoin.Click += async (_, _) =>
        {
            if (_linuxSelected is null || _linuxJoinBinding is null) return;
            await RunLinuxAsync("Cancelling Linux join", async () =>
            {
                var result = await LinuxManager.CancelJoinAsync(
                    _linuxSelected, _linuxJoinBinding);
                _linuxJoinBinding = result.Value;
                RenderLinuxJoinBinding();
            });
        };
        panel.Children.Add(Row(confirmJoin, refreshJoin, cancelJoin));

        panel.Children.Add(Note(
            "If this PC is joining a group created on Linux, start in Converse Groups, "
            + "then review the request here."));
        _linuxRequestsBox = new ComboBox
        {
            Header = "Pending Linux group requests",
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        panel.Children.Add(_linuxRequestsBox);
        var listRequests = ActionButton("List requests");
        listRequests.Click += async (_, _) =>
        {
            if (_linuxSelected is null) return;
            await RunLinuxAsync("Listing Linux group requests", async () =>
            {
                var result = await LinuxManager.ListPairingRequestsAsync(_linuxSelected);
                _linuxRequestBindings = result.Value ?? new List<LinuxPairingBinding>();
                _linuxRequestsBox.Items.Clear();
                foreach (var request in result.Value ?? [])
                {
                    _linuxRequestsBox.Items.Add(new SettingItem(
                        request.PairingID.ToString("D"),
                        $"{request.PeerName} · {request.PeerDeviceID[..8]}…"));
                }
                if (_linuxRequestsBox.Items.Count > 0) _linuxRequestsBox.SelectedIndex = 0;
                SetLinuxMessage(result.Success
                    ? $"{_linuxRequestsBox.Items.Count} pending request(s)."
                    : result.Message);
            });
        };
        var reviewRequest = ActionButton("Review");
        reviewRequest.Click += async (_, _) =>
        {
            if (_linuxSelected is null ||
                _linuxRequestsBox.SelectedItem is not SettingItem item ||
                !Guid.TryParse(item.Id, out var pairingID)) return;
            var listed = _linuxRequestBindings.FirstOrDefault(
                binding => binding.PairingID == pairingID);
            if (listed is null) { SetLinuxMessage("List requests again before reviewing."); return; }
            await RunLinuxAsync("Reviewing Linux group request", async () =>
            {
                var result = await LinuxManager.ReviewRequestAsync(_linuxSelected, listed);
                _linuxReviewBinding = result.Value;
                if (_linuxReviewCodeBlock is not null)
                {
                    _linuxReviewCodeBlock.Text = result.Value?.VerificationCode ??
                        "Code is not ready yet; review again in a moment.";
                }
                SetLinuxMessage(result.Success
                    ? "Compare every group with the joining device."
                    : result.Message);
            });
        };
        var approveRequest = ActionButton("Approve");
        approveRequest.Click += async (_, _) =>
        {
            if (_linuxSelected is null || _linuxReviewBinding is null) return;
            await RunLinuxAsync("Approving Linux group request", async () =>
            {
                if (!await BindLinuxReviewRequesterAsync()) return;
                await ConfirmLocalJoinPromptAsync(_linuxReviewBinding);
                if (_devices.GroupReview?.Request.Id != _linuxReviewBinding.PairingID)
                {
                    SetLinuxMessage("The local review changed. Review the Linux request again before approving.");
                    return;
                }
                var result = await LinuxManager.ApproveRequestAsync(
                    _linuxSelected, _linuxReviewBinding);
                SetLinuxMessage(result.Success ? "Request approved on Linux." : result.Message);
            });
        };
        var rejectRequest = ActionButton("Reject");
        rejectRequest.Click += async (_, _) =>
        {
            if (_linuxSelected is null || _linuxReviewBinding is null) return;
            await RunLinuxAsync("Rejecting Linux group request", async () =>
            {
                var result = await LinuxManager.RejectRequestAsync(
                    _linuxSelected, _linuxReviewBinding);
                SetLinuxMessage(result.Success ? "Request rejected on Linux." : result.Message);
            });
        };
        panel.Children.Add(Row(listRequests, reviewRequest, approveRequest, rejectRequest));
        _linuxReviewCodeBlock = new TextBlock
        {
            Text = "Reviewed code will appear here.",
            FontFamily = new FontFamily("Consolas"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        panel.Children.Add(_linuxReviewCodeBlock);

        panel.Children.Add(Header("Updates"));
        panel.Children.Add(Note(
            "Activation drains active work and aborts on timeout; it never kills a turn. "
            + "A new release stays in probation until you explicitly health-commit or roll back."));
        _linuxBundlePathBox = new TextBox
        {
            Header = "Signed Linux release bundle (.tar.gz)",
        };
        var browseBundle = ActionButton("Choose bundle…");
        browseBundle.Click += async (_, _) =>
        {
            var path = await PickLinuxFileAsync();
            if (path is not null) _linuxBundlePathBox.Text = path;
        };
        _linuxReleaseIDBox = new TextBox
        {
            Header = "Release ID (blank reads signed manifest)",
        };
        panel.Children.Add(_linuxBundlePathBox);
        panel.Children.Add(browseBundle);
        panel.Children.Add(_linuxReleaseIDBox);

        var stageActivate = ActionButton("Stage and activate");
        stageActivate.Click += async (_, _) =>
        {
            if (_linuxSelected is null) { SetLinuxMessage("Select a Linux deployment first."); return; }
            await RunLinuxAsync("Staging and activating Linux update", async () =>
            {
                var bundle = _linuxBundlePathBox.Text.Trim();
                var releaseID = _linuxReleaseIDBox.Text.Trim();
                if (releaseID.Length == 0)
                    releaseID = LinuxDeploymentManager.ReadBundleReleaseID(bundle) ?? "";
                if (releaseID.Length == 0)
                {
                    SetLinuxMessage("Enter the signed bundle release ID.");
                    return;
                }
                _linuxReleaseIDBox.Text = releaseID;
                var staged = await LinuxManager.StageUpdateAsync(
                    _linuxSelected, bundle, releaseID);
                if (!staged.Success) { SetLinuxMessage(staged.Message); return; }
                _linuxOperationID = Guid.NewGuid();
                var activated = await LinuxManager.ActivateUpdateAsync(
                    _linuxSelected, releaseID, 600, _linuxOperationID);
                if (!activated.Success)
                {
                    SetLinuxMessage(activated.Message +
                        (activated.OperationID is { } id ? $" Operation: {id:D}" : ""));
                    return;
                }
                var polled = await LinuxManager.PollOperationAsync(
                    _linuxSelected, _linuxOperationID.Value,
                    stopAtProbation: true, timeoutSeconds: 30);
                SetLinuxMessage(polled.Value?.State == "probation_new_release"
                    ? "New release is in probation. Health-commit or roll back explicitly."
                    : $"Activation state: {polled.Value?.State ?? polled.Message}");
                await RefreshLinuxStatusAsync();
            });
        };
        var pollOperation = ActionButton("Poll operation");
        pollOperation.Click += async (_, _) =>
        {
            if (_linuxSelected is null || _linuxOperationID is null) return;
            await RunLinuxAsync("Polling Linux operation", async () =>
            {
                var result = await LinuxManager.PollOperationAsync(
                    _linuxSelected, _linuxOperationID.Value,
                    stopAtProbation: true, timeoutSeconds: 30);
                SetLinuxMessage(result.Success
                    ? $"Operation {_linuxOperationID:D}: {result.Value?.State}"
                    : result.Message);
                await RefreshLinuxStatusAsync();
            });
        };
        var healthCommit = ActionButton("Health-commit");
        healthCommit.Click += async (_, _) =>
        {
            if (_linuxSelected is null) return;
            await RunLinuxAsync("Health-committing Linux release", async () =>
            {
                var status = await LinuxManager.GetStatusAsync(_linuxSelected);
                if (status.Value?.UpdateEpisodeID is not { } episodeID)
                {
                    SetLinuxMessage("No probationary update episode is active.");
                    return;
                }
                var result = await LinuxManager.HealthCommitAsync(
                    _linuxSelected, episodeID, Guid.NewGuid());
                SetLinuxMessage(result.Success ? "Linux release health-committed." : result.Message);
                await RefreshLinuxStatusAsync();
            });
        };
        var rollback = ActionButton("Roll back");
        rollback.Click += async (_, _) =>
        {
            if (_linuxSelected is null) return;
            await RunLinuxAsync("Rolling back Linux release", async () =>
            {
                var status = await LinuxManager.GetStatusAsync(_linuxSelected);
                if (status.Value?.UpdateEpisodeID is not { } episodeID)
                {
                    SetLinuxMessage("No probationary update episode is active.");
                    return;
                }
                var result = await LinuxManager.RollbackAsync(
                    _linuxSelected, episodeID,
                    "Rollback requested in Windows Linux manager", Guid.NewGuid());
                SetLinuxMessage(result.Success
                    ? "Rollback requested; the Linux daemon will restart."
                    : result.Message);
            });
        };
        panel.Children.Add(Row(stageActivate, pollOperation, healthCommit, rollback));

        panel.Children.Add(Header("Linux-held secrets and service"));
        _linuxSecretBox = new PasswordBox
        {
            Header = "Meta API key (stored only on Linux)",
        };
        panel.Children.Add(_linuxSecretBox);
        var setSecret = ActionButton("Set key on Linux");
        setSecret.Click += async (_, _) =>
        {
            if (_linuxSelected is null || string.IsNullOrWhiteSpace(_linuxSecretBox.Password)) return;
            var value = _linuxSecretBox.Password;
            _linuxSecretBox.Password = "";
            await RunLinuxAsync("Setting Linux secret", async () =>
            {
                var result = await LinuxManager.SetSecretAsync(
                    _linuxSelected, "agent.meta.api-key", "provider_api_key", value);
                SetLinuxMessage(result.Success ? "Meta API key saved on Linux." : result.Message);
                await RefreshLinuxStatusAsync();
            });
        };
        var deleteSecret = ActionButton("Delete key");
        deleteSecret.Click += async (_, _) =>
        {
            if (_linuxSelected is null) return;
            await RunLinuxAsync("Deleting Linux secret", async () =>
            {
                var result = await LinuxManager.DeleteSecretAsync(
                    _linuxSelected, "agent.meta.api-key");
                SetLinuxMessage(result.Success ? "Meta API key deleted on Linux." : result.Message);
                await RefreshLinuxStatusAsync();
            });
        };
        var restart = ActionButton("Restart daemon");
        restart.Click += async (_, _) =>
        {
            if (_linuxSelected is null) return;
            await RunLinuxAsync("Restarting Linux daemon", async () =>
            {
                _linuxOperationID = Guid.NewGuid();
                var result = await LinuxManager.RestartAsync(
                    _linuxSelected, _linuxOperationID);
                SetLinuxMessage(result.Success
                    ? "Restart requested. Poll the operation after the daemon returns."
                    : result.Message);
            });
        };
        var providerTerminal = ActionButton("Open SSH Terminal");
        providerTerminal.Click += (_, _) =>
        {
            var destination = _linuxSelected?.Ssh.Destination ?? _linuxDestinationBox.Text.Trim();
            if (destination.Length == 0) return;
            OpenSshTerminal(LinuxSshCommands.InteractiveSsh(destination));
            SetLinuxMessage("Use the terminal to install/sign in to provider CLIs on Linux. Converse does not read that terminal.");
        };
        panel.Children.Add(Row(setSecret, deleteSecret, restart, providerTerminal));
        var startService = ActionButton("Start daemon");
        startService.Click += async (_, _) =>
        {
            if (_linuxSelected is null) return;
            await RunLinuxAsync("Starting Linux daemon", async () =>
            {
                var result = await LinuxManager.StartServiceAsync(_linuxSelected, Guid.NewGuid());
                SetLinuxMessage(result.Success ? "Linux daemon start requested." : result.Message);
            });
        };
        var stopService = ActionButton("Stop daemon");
        stopService.Click += async (_, _) =>
        {
            if (_linuxSelected is null) return;
            await RunLinuxAsync("Stopping Linux daemon", async () =>
            {
                var result = await LinuxManager.StopServiceAsync(_linuxSelected, Guid.NewGuid());
                SetLinuxMessage(result.Success ? "Linux daemon stopped." : result.Message);
            });
        };
        panel.Children.Add(Row(startService, stopService));

        panel.Children.Add(Header("New Linux session"));
        var sessionTitleBox = new TextBox { Header = "Session title", Text = "Linux session" };
        var sessionEngineBox = new TextBox { Header = "Engine (claude, codex, muse, or agent)", Text = "codex" };
        panel.Children.Add(sessionTitleBox);
        panel.Children.Add(sessionEngineBox);
        var createSession = ActionButton("Create session on Linux");
        createSession.Click += async (_, _) =>
        {
            if (_linuxSelected is null) return;
            await RunLinuxAsync("Creating Linux session", async () =>
            {
                var result = await LinuxManager.CreateSessionAsync(_linuxSelected,
                    new LinuxSessionCreateInput(Guid.NewGuid(),
                        sessionEngineBox.Text.Trim(), sessionTitleBox.Text.Trim()));
                SetLinuxMessage(result.Success
                    ? $"Created {result.Value?.GlobalID}. Take it from the sidebar."
                    : result.Message);
                if (result.Success) await RefreshLinuxStatusAsync();
            });
        };
        panel.Children.Add(createSession);

        _linuxMessageBlock = Note(_linuxMessage);
        panel.Children.Add(_linuxMessageBlock);

        _linuxWindow = new Window
        {
            Title = "Set up Linux",
            Content = new ScrollViewer
            {
                Content = panel,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            },
        };
        _linuxWindow.Closed += (_, _) => _linuxWindow = null;
        RenderLinuxDeployments();
        RenderLinuxDetails();
        _linuxWindow.Activate();
        if (_linuxSelected is not null) _ = RefreshLinuxStatusAsync();
    }

    private async Task<bool> BindLinuxReviewRequesterAsync()
    {
        if (_linuxSelected is null || _linuxReviewBinding is null) return false;
        if (_linuxReviewBinding.RequesterConnectionInstanceID is not null) return true;
        var prompts = _devices.GroupPairingPrompts.Where(item =>
            _linuxReviewBinding.VerificationCode is not null &&
            item.Code == _linuxReviewBinding.VerificationCode).ToList();
        if (prompts.Count == 0) return true;
        if (prompts.Select(item => item.PeerId).Distinct().Count() != 1)
        {
            SetLinuxMessage("More than one local join prompt matches. Pairing stopped.");
            return false;
        }
        _linuxReviewBinding.RequesterConnectionInstanceID = prompts[0].PeerId;
        var bound = await LinuxManager.BindPeerConnectionAsync(
            _linuxSelected, _linuxReviewBinding, Guid.NewGuid());
        if (!bound.Success)
        {
            SetLinuxMessage(bound.Message);
            return false;
        }
        if (bound.Value!.VerificationCodeFingerprint !=
            _linuxReviewBinding.VerificationCodeFingerprint)
        {
            SetLinuxMessage("The pairing changed while binding. Review the new code and Pair again.");
            return false;
        }
        _linuxReviewBinding = bound.Value!;
        return true;
    }

    private async Task ConfirmLocalJoinPromptAsync(LinuxPairingBinding binding)
    {
        var peerIDs = _devices.GroupPairingPrompts
            .Where(item => item.PeerId == binding.RequesterConnectionInstanceID ||
                (binding.VerificationCode is not null && item.Code == binding.VerificationCode))
            .Select(item => item.PeerId).Distinct().ToList();
        if (peerIDs.Count == 1) await _devices.ConfirmPairing(peerIDs[0]);
    }

    private async Task RunLinuxAsync(string label, Func<Task> action)
    {
        if (_linuxBusy) return;
        _linuxBusy = true;
        SetLinuxMessage(label + "…");
        try { await action(); }
        catch (Exception error)
        {
            SetLinuxMessage(error is ArgumentException
                ? error.Message
                : "Linux operation failed. Check SSH, the Linux daemon, and the selected deployment.");
        }
        finally { _linuxBusy = false; }
    }

    private async Task RefreshLinuxStatusAsync()
    {
        if (_linuxSelected is null)
        {
            RenderLinuxDetails();
            return;
        }
        await RunLinuxAsync("Refreshing Linux status", async () =>
        {
            var result = await LinuxManager.GetStatusAsync(_linuxSelected);
            _linuxStatus = result.Value;
            _linuxSelected = LinuxManager.Deployments.FirstOrDefault(
                deployment => deployment.DeploymentID == _linuxSelected.DeploymentID) ?? _linuxSelected;
            SetLinuxMessage(result.Success ? "Linux status refreshed." : result.Message);
            RenderLinuxDeployments();
            RenderLinuxDetails();
        });
    }

    private void RenderLinuxDeployments()
    {
        if (_linuxDeploymentsBox is null) return;
        var selectedID = _linuxSelected?.DeploymentID;
        _linuxDeploymentsBox.Items.Clear();
        foreach (var deployment in LinuxManager.Deployments)
        {
            _linuxDeploymentsBox.Items.Add(new SettingItem(
                deployment.DeploymentID.ToString("D"),
                $"{deployment.DisplayName} · {deployment.Ssh.Destination}"));
        }
        if (selectedID is not null)
        {
            for (var index = 0; index < _linuxDeploymentsBox.Items.Count; index++)
            {
                if (_linuxDeploymentsBox.Items[index] is SettingItem item &&
                    item.Id == selectedID.Value.ToString("D"))
                {
                    _linuxDeploymentsBox.SelectedIndex = index;
                    break;
                }
            }
        }
        else if (_linuxDeploymentsBox.Items.Count > 0)
        {
            _linuxDeploymentsBox.SelectedIndex = 0;
        }
    }

    private void RenderLinuxDetails()
    {
        if (_linuxDetailsBlock is null) return;
        if (_linuxSelected is null)
        {
            _linuxDetailsBlock.Text = "No Linux deployment selected.";
            return;
        }
        var status = _linuxStatus;
        _linuxDetailsBlock.Text =
            $"{_linuxSelected.DisplayName} · SSH {_linuxSelected.Ssh.Destination}\n"
            + $"Host key {_linuxSelected.Ssh.HostKeyFingerprintSHA256}\n"
            + (status is null
                ? "Status has not been refreshed yet."
                : $"Converse {status.ProductVersion} ({status.Build}) · {status.ProcessState} · admission {status.Admission}\n"
                  + $"Device {status.DeviceID}\n"
                  + $"Group {status.GroupName ?? "none"} · peers {status.ConnectedPeerCount}/{status.PeerCount} connected\n"
                  + $"Sessions {status.SessionCount} · active turns {status.ActiveTurnCount} · agents {status.AgentCount}\n"
                  + $"Release {status.CurrentReleaseID ?? "unknown"}"
                  + (status.StagedReleaseID is null ? "" : $" · staged {status.StagedReleaseID}")
                  + (status.UpdatePhase is null ? "" : $" · update {status.UpdatePhase}")
                  + $"\nSupervisor {status.Supervisor} · desired running {status.DesiredRunning} · configured secrets: "
                  + (status.ConfiguredSecrets.Count == 0
                      ? "none" : string.Join(", ", status.ConfiguredSecrets)));
    }

    private void RenderLinuxJoinBinding()
    {
        if (_linuxJoinCodeBlock is null) return;
        _linuxJoinCodeBlock.Text = _linuxJoinBinding is null
            ? "Linux join code will appear here."
            : $"State {_linuxJoinBinding.State}\n{_linuxJoinBinding.VerificationCode ?? "No code is shown in this state."}";
    }

    private void SetLinuxMessage(string message)
    {
        _linuxMessage = message;
        if (_linuxMessageBlock is not null) _linuxMessageBlock.Text = message;
    }

    private async Task<string?> PickLinuxFileAsync()
    {
        try
        {
            var picker = new Windows.Storage.Pickers.FileOpenPicker();
            picker.FileTypeFilter.Add("*");
            InitializeWithWindow.Initialize(picker, WindowHandle);
            var file = await picker.PickSingleFileAsync();
            return file?.Path;
        }
        catch
        {
            SetLinuxMessage("File picker could not open. Paste the full path instead.");
            return null;
        }
    }

    private void OpenSshTerminal(string[] sshArguments)
    {
        try
        {
            var start = new ProcessStartInfo
            {
                FileName = "wt.exe",
                Arguments = DisplayCommand(sshArguments),
                UseShellExecute = true,
            };
            if (Process.Start(start) is null) throw new InvalidOperationException();
        }
        catch
        {
            SetLinuxMessage(
                "Windows Terminal could not be opened. Run this in a terminal: "
                + DisplayCommand(sshArguments));
        }
    }

    private static string DisplayCommand(IEnumerable<string> arguments) =>
        string.Join(" ", arguments.Select(argument =>
            argument.Any(character => char.IsWhiteSpace(character) || character is '"' or '$')
                ? "\"" + argument.Replace("\"", "\\\"") + "\""
                : argument));
}
