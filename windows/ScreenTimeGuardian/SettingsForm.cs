using System.Drawing;
using System.Windows.Forms;

namespace ScreenTimeGuardian;

internal sealed class SettingsForm : Form
{
    private readonly SessionStore store;
    private readonly P2PTransport p2pTransport;
    private readonly ComboBox languageBox = new();
    private readonly CheckBox postureSwitchBox = new();
    private readonly TextBox eyeRestIntervalMinutesBox = new();
    private readonly TextBox postureRestIntervalMinutesBox = new();
    private readonly TextBox plannedDailyHoursBox = new();
    private readonly TextBox plannedDailyMinuteRemainderBox = new();
    private readonly ComboBox trackingObjectBox = new();
    private readonly TextBox deviceNameBox = new();
    private readonly CheckBox p2pEnabledBox = new();
    private readonly TextBox pairingCodeBox = new();
    private readonly TextBox syncIntervalMinutesBox = new();
    private readonly ComboBox peerBox = new();
    private readonly Label syncStatusLabel = new();
    private readonly TextBox dataDirectoryBox = new();
    private readonly Button browseDataDirectoryButton = new();
    private readonly CheckBox meetingModeBox = new();
    private readonly CheckBox autoStartBox = new();
    private readonly Button syncNowButton = new();
    private readonly Button approvePeerButton = new();
    private readonly Button rejectPeerButton = new();
    private readonly System.Windows.Forms.Timer refreshTimer = new();
    private string CurrentLanguage => languageBox.SelectedIndex == 1 ? "en" : store.Settings.Language;

    public SettingsForm(SessionStore store, P2PTransport p2pTransport)
    {
        this.store = store;
        this.p2pTransport = p2pTransport;

        Text = L10n.Text("设置", "Settings", store.Settings.Language);
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(640, 720);
        Size = new Size(760, 780);
        FormBorderStyle = FormBorderStyle.Sizable;
        MaximizeBox = false;

        BuildUi();
        LoadSettings();
        RefreshP2PState();

        this.p2pTransport.StateChanged += OnP2PStateChanged;
        refreshTimer.Interval = 3000;
        refreshTimer.Tick += (_, _) => RefreshP2PState();
        refreshTimer.Start();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        refreshTimer.Stop();
        refreshTimer.Dispose();
        p2pTransport.StateChanged -= OnP2PStateChanged;
        base.OnFormClosed(e);
    }

    private void BuildUi()
    {
        ConfigureControls();
        var language = store.Settings.Language;

        var content = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            RowCount = 0,
            Padding = new Padding(24),
            AutoScroll = true
        };
        content.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 160));
        content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        AddRow(content, L10n.Text("APP 语言", "App Language", language), languageBox);
        AddRow(content, "", postureSwitchBox);
        AddRow(content, L10n.Text("护眼间隔（分钟）", "Eye Rest Interval (minutes)", language), intervalPanel(eyeRestIntervalMinutesBox, L10n.Text("默认 3", "Default 3", language)));
        AddRow(content, L10n.Text("姿势提醒间隔", "Posture Interval", language), intervalPanel(postureRestIntervalMinutesBox, L10n.Text("护眼间隔的 2 倍", "2x eye rest", language)));
        AddRow(content, L10n.Text("每日计划用时", "Daily Plan", language), plannedDailyPanel(language));
        AddRow(content, L10n.Text("跟踪对象", "Tracking Target", language), trackingObjectBox);
        AddRow(content, L10n.Text("设备名称", "Device Name", language), deviceNameBox);
        AddRow(content, L10n.Text("同步方式", "Sync Method", language), p2pEnabledBox);
        AddRow(content, L10n.Text("P2P 配对码", "P2P Pairing Code", language), inlineWithHint(pairingCodeBox, L10n.Text("多台设备填同一码", "Use the same code", language)));
        AddRow(content, L10n.Text("同步间隔（分钟）", "Sync Interval (minutes)", language), syncIntervalPanel());
        AddRow(content, L10n.Text("配对设备", "Paired Devices", language), peerPanel());
        AddRow(content, "", syncStatusLabel);
        AddRow(content, "", meetingModeBox);
        AddRow(content, "", autoStartBox);
        AddRow(content, L10n.Text("数据目录", "Data Directory", language), dataDirectoryPanel());

        var saveButton = new Button
        {
            Text = L10n.Text("保存", "Save", language),
            AutoSize = true,
            DialogResult = DialogResult.OK
        };
        saveButton.Click += (_, _) => SaveAndClose();

        var cancelButton = new Button
        {
            Text = L10n.Text("取消", "Cancel", language),
            AutoSize = true,
            DialogResult = DialogResult.Cancel
        };

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft,
            Padding = new Padding(8, 10, 24, 16),
            AutoSize = true
        };
        buttons.Controls.Add(cancelButton);
        buttons.Controls.Add(saveButton);

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2
        };
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.Controls.Add(content, 0, 0);
        root.Controls.Add(buttons, 0, 1);

        AcceptButton = saveButton;
        CancelButton = cancelButton;
        Controls.Add(root);
    }

    private void ConfigureControls()
    {
        languageBox.DropDownStyle = ComboBoxStyle.DropDownList;
        languageBox.Items.AddRange(["中文", "English"]);
        languageBox.Width = 180;

        ConfigureMinuteTextBox(plannedDailyHoursBox, 64);
        ConfigureMinuteTextBox(plannedDailyMinuteRemainderBox, 64);
        ConfigureMinuteTextBox(eyeRestIntervalMinutesBox, 80);
        ConfigureMinuteTextBox(postureRestIntervalMinutesBox, 80);
        postureRestIntervalMinutesBox.ReadOnly = true;

        trackingObjectBox.DropDownStyle = ComboBoxStyle.DropDownList;
        trackingObjectBox.Items.Add("LLM Ranking");
        trackingObjectBox.Width = 180;

        deviceNameBox.Width = 300;

        var language = store.Settings.Language;
        postureSwitchBox.Text = L10n.Text("启用姿势切换", "Enable posture switch", language);
        postureSwitchBox.AutoSize = true;

        p2pEnabledBox.Text = L10n.Text("P2P 同步（局域网）", "P2P Sync (Local Network)", language);
        p2pEnabledBox.AutoSize = true;
        p2pEnabledBox.CheckedChanged += (_, _) => syncNowButton.Enabled = p2pEnabledBox.Checked;

        pairingCodeBox.Width = 120;
        pairingCodeBox.CharacterCasing = CharacterCasing.Upper;
        pairingCodeBox.MaxLength = 32;

        ConfigureMinuteTextBox(syncIntervalMinutesBox, 80);

        peerBox.DropDownStyle = ComboBoxStyle.DropDownList;
        peerBox.SelectedIndexChanged += (_, _) => UpdatePeerButtons();

        syncStatusLabel.AutoSize = false;
        syncStatusLabel.Height = 24;
        syncStatusLabel.Dock = DockStyle.Fill;
        syncStatusLabel.TextAlign = ContentAlignment.MiddleLeft;
        syncStatusLabel.AutoEllipsis = true;

        meetingModeBox.Text = L10n.Text("会议模式", "Meeting Mode", language);
        meetingModeBox.AutoSize = true;
        autoStartBox.Text = L10n.Text("系统启动时自动启动", "Launch at system startup", language);
        autoStartBox.AutoSize = true;

        syncNowButton.Text = L10n.Text("立即同步", "Sync Now", language);
        syncNowButton.AutoSize = true;
        syncNowButton.Click += async (_, _) => await SyncNowAsync();

        approvePeerButton.Text = L10n.Text("同意", "Approve", language);
        approvePeerButton.AutoSize = true;
        approvePeerButton.Click += (_, _) => ApproveSelectedPeer();

        rejectPeerButton.Text = L10n.Text("拒绝", "Reject", language);
        rejectPeerButton.AutoSize = true;
        rejectPeerButton.Click += (_, _) => RejectSelectedPeer();

        dataDirectoryBox.Width = 360;
        browseDataDirectoryButton.Text = L10n.Text("选择", "Browse", language);
        browseDataDirectoryButton.AutoSize = true;
        browseDataDirectoryButton.Click += (_, _) => BrowseDataDirectory();
    }

    private void LoadSettings()
    {
        var settings = store.GetSettingsSnapshot();
        languageBox.SelectedIndex = settings.Language == "en" ? 1 : 0;
        postureSwitchBox.Checked = settings.PostureSwitchEnabled;
        eyeRestIntervalMinutesBox.Text = settings.EyeRestIntervalMinutes.ToString();
        postureRestIntervalMinutesBox.Text = AppSettings.DerivedPostureRestIntervalMinutes(settings.EyeRestIntervalMinutes).ToString();
        plannedDailyHoursBox.Text = (settings.PlannedDailyMinutes / 60).ToString();
        plannedDailyMinuteRemainderBox.Text = (settings.PlannedDailyMinutes % 60).ToString();
        trackingObjectBox.SelectedItem = "LLM Ranking";
        deviceNameBox.Text = settings.DeviceName;
        p2pEnabledBox.Checked = settings.P2PSyncEnabled;
        pairingCodeBox.Text = settings.P2PPairingCode;
        syncIntervalMinutesBox.Text = settings.P2PSyncIntervalMinutes.ToString();
        dataDirectoryBox.Text = store.AppDirectory;
        meetingModeBox.Checked = settings.MeetingMode;
        autoStartBox.Checked = settings.AutoStartEnabled;
    }

    private void SaveAndClose()
    {
        ApplySettingsFromControls(restartP2P: true);
        DialogResult = DialogResult.OK;
        Close();
    }

    private bool ApplySettingsFromControls(bool restartP2P)
    {
        var settings = store.GetSettingsSnapshot();
        var oldP2PEnabled = settings.P2PSyncEnabled;
        var oldPairingCode = settings.P2PPairingCode;
        var oldSyncInterval = settings.P2PSyncIntervalMinutes;
        var oldDeviceName = settings.DeviceName;

        settings.Language = languageBox.SelectedIndex == 1 ? "en" : "zh";
        settings.PostureSwitchEnabled = postureSwitchBox.Checked;
        settings.EyeRestIntervalMinutes = ClampText(eyeRestIntervalMinutesBox.Text, 1, 1440, 3);
        settings.PostureRestIntervalMinutes = AppSettings.DerivedPostureRestIntervalMinutes(settings.EyeRestIntervalMinutes);
        settings.PlannedDailyMinutes = ReadPlannedDailyMinutes();
        settings.TrackingObject = "LLM Ranking";
        settings.DeviceName = deviceNameBox.Text.Trim();
        settings.P2PSyncEnabled = p2pEnabledBox.Checked;
        settings.P2PPairingCode = AppSettings.NormalizePairingCode(pairingCodeBox.Text);
        settings.P2PSyncIntervalMinutes = ClampText(syncIntervalMinutesBox.Text, 1, 1440, 5);
        settings.MeetingMode = meetingModeBox.Checked;
        settings.AutoStartEnabled = autoStartBox.Checked;
        settings.DataDirectory = dataDirectoryBox.Text.Trim();
        store.UpdateSettings(settings);

        var p2pChanged =
            oldP2PEnabled != settings.P2PSyncEnabled ||
            !string.Equals(oldPairingCode, settings.P2PPairingCode, StringComparison.OrdinalIgnoreCase) ||
            oldSyncInterval != settings.P2PSyncIntervalMinutes ||
            !string.Equals(oldDeviceName, settings.DeviceName, StringComparison.Ordinal);
        if (restartP2P && p2pChanged)
        {
            p2pTransport.Restart();
        }

        return p2pChanged;
    }

    private async Task SyncNowAsync()
    {
        syncNowButton.Enabled = false;
        try
        {
            var p2pChanged = ApplySettingsFromControls(restartP2P: true);
            if (p2pChanged)
            {
                syncStatusLabel.Text = L10n.Text("同步设置已保存，正在重新发现设备", "Sync settings saved; rediscovering devices", CurrentLanguage);
                await Task.Delay(500);
            }

            await p2pTransport.SyncNowAsync();
            RefreshP2PState();
        }
        finally
        {
            syncNowButton.Enabled = p2pEnabledBox.Checked;
        }
    }

    private void OnP2PStateChanged(object? sender, EventArgs e)
    {
        if (IsDisposed)
        {
            return;
        }

        if (InvokeRequired)
        {
            BeginInvoke(new Action(RefreshP2PState));
            return;
        }

        RefreshP2PState();
    }

    private void RefreshP2PState()
    {
        if (IsDisposed)
        {
            return;
        }

        var language = CurrentLanguage;
        syncStatusLabel.Text = L10n.SyncStatus(p2pTransport.Status, language);
        syncNowButton.Enabled = p2pEnabledBox.Checked;
        var selectedId = SelectedPeerId();
        peerBox.BeginUpdate();
        peerBox.Items.Clear();

        foreach (var peer in p2pTransport.KnownPeers)
        {
            var trustStatus = peer.PairingMatched ? store.TrustStatus(peer.DeviceId) : "配对码不一致";
            peerBox.Items.Add(new PeerComboItem(
                peer.DeviceId,
                $"{peer.DeviceName} · {PlatformTitle(peer.Platform)} · {L10n.SyncStatus(trustStatus, language)} · {L10n.SyncStatus(peer.LastStatus, language)}"));
        }

        if (peerBox.Items.Count == 0)
        {
            peerBox.Items.Add(new PeerComboItem(null, L10n.Text("暂无发现设备", "No devices found", language)));
        }

        peerBox.EndUpdate();
        var selectedIndex = 0;
        if (!string.IsNullOrWhiteSpace(selectedId))
        {
            for (var index = 0; index < peerBox.Items.Count; index++)
            {
                if (peerBox.Items[index] is PeerComboItem item &&
                    string.Equals(item.DeviceId, selectedId, StringComparison.OrdinalIgnoreCase))
                {
                    selectedIndex = index;
                    break;
                }
            }
        }
        peerBox.SelectedIndex = selectedIndex;
        UpdatePeerButtons();
    }

    private void ApproveSelectedPeer()
    {
        if (SelectedPeerId() is not { } deviceId)
        {
            return;
        }

        p2pTransport.ApprovePeer(deviceId);
        RefreshP2PState();
    }

    private void RejectSelectedPeer()
    {
        if (SelectedPeerId() is not { } deviceId)
        {
            return;
        }

        p2pTransport.RejectPeer(deviceId);
        RefreshP2PState();
    }

    private string? SelectedPeerId()
    {
        return peerBox.SelectedItem is PeerComboItem item ? item.DeviceId : null;
    }

    private void UpdatePeerButtons()
    {
        var selectedPeer = SelectedPeer();
        var hasSelection = selectedPeer is not null;
        approvePeerButton.Enabled = selectedPeer?.PairingMatched == true;
        rejectPeerButton.Enabled = hasSelection;
    }

    private P2PPeerInfo? SelectedPeer()
    {
        var selectedId = SelectedPeerId();
        return string.IsNullOrWhiteSpace(selectedId)
            ? null
            : p2pTransport.KnownPeers.FirstOrDefault(peer => string.Equals(peer.DeviceId, selectedId, StringComparison.OrdinalIgnoreCase));
    }

    private static void ConfigureMinuteTextBox(TextBox box, int width)
    {
        box.Width = width;
        box.TextAlign = HorizontalAlignment.Left;
    }

    private static Control inlineWithHint(Control control, string hint)
    {
        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            AutoSize = true
        };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        control.Margin = new Padding(0, 4, 12, 4);
        panel.Controls.Add(control, 0, 0);
        panel.Controls.Add(new Label
        {
            Text = hint,
            AutoSize = true,
            Anchor = AnchorStyles.Left,
            Margin = new Padding(0, 7, 0, 4)
        }, 1, 0);
        return panel;
    }

    private static Control intervalPanel(Control control, string hint)
    {
        return inlineWithHint(control, hint);
    }

    private Control plannedDailyPanel(string language)
    {
        var panel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            FlowDirection = FlowDirection.LeftToRight
        };
        plannedDailyHoursBox.Margin = new Padding(0, 4, 6, 4);
        plannedDailyMinuteRemainderBox.Margin = new Padding(12, 4, 6, 4);
        panel.Controls.Add(plannedDailyHoursBox);
        panel.Controls.Add(new Label { Text = L10n.Text("小时", "h", language), AutoSize = true, Margin = new Padding(0, 7, 0, 4) });
        panel.Controls.Add(plannedDailyMinuteRemainderBox);
        panel.Controls.Add(new Label { Text = L10n.Text("分钟", "min", language), AutoSize = true, Margin = new Padding(0, 7, 12, 4) });
        panel.Controls.Add(new Label { Text = L10n.Text("默认 8小时0分钟", "Default 8h 0m", language), AutoSize = true, Margin = new Padding(0, 7, 0, 4) });
        return panel;
    }

    private int ReadPlannedDailyMinutes()
    {
        var hours = ClampText(plannedDailyHoursBox.Text, 0, 24, 8);
        var minutes = ClampText(plannedDailyMinuteRemainderBox.Text, 0, 59, 0);
        var total = hours * 60 + minutes;
        return Math.Clamp(total <= 0 ? 480 : total, 1, 1440);
    }

    private Control syncIntervalPanel()
    {
        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            AutoSize = true
        };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        syncIntervalMinutesBox.Margin = new Padding(0, 4, 12, 4);
        syncNowButton.Margin = new Padding(0, 1, 0, 0);
        panel.Controls.Add(syncIntervalMinutesBox, 0, 0);
        panel.Controls.Add(syncNowButton, 1, 0);
        return panel;
    }

    private Control peerPanel()
    {
        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 3,
            AutoSize = true
        };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        peerBox.Dock = DockStyle.Fill;
        peerBox.Margin = new Padding(0, 4, 10, 4);
        approvePeerButton.Margin = new Padding(0, 1, 6, 0);
        rejectPeerButton.Margin = new Padding(0, 1, 0, 0);
        panel.Controls.Add(peerBox, 0, 0);
        panel.Controls.Add(approvePeerButton, 1, 0);
        panel.Controls.Add(rejectPeerButton, 2, 0);
        return panel;
    }

    private Control dataDirectoryPanel()
    {
        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            AutoSize = true
        };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        dataDirectoryBox.Dock = DockStyle.Fill;
        dataDirectoryBox.Margin = new Padding(0, 4, 8, 4);
        browseDataDirectoryButton.Margin = new Padding(0, 1, 0, 0);
        panel.Controls.Add(dataDirectoryBox, 0, 0);
        panel.Controls.Add(browseDataDirectoryButton, 1, 0);
        return panel;
    }

    private void BrowseDataDirectory()
    {
        using var dialog = new FolderBrowserDialog
        {
            Description = L10n.Text("选择数据保存目录", "Choose data directory", CurrentLanguage),
            SelectedPath = Directory.Exists(dataDirectoryBox.Text) ? dataDirectoryBox.Text : store.AppDirectory,
            UseDescriptionForTitle = true
        };
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            dataDirectoryBox.Text = dialog.SelectedPath;
        }
    }

    private static void AddRow(TableLayoutPanel grid, string labelText, Control control)
    {
        var row = grid.RowCount++;
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        control.Dock = DockStyle.Fill;
        control.Margin = new Padding(0, 6, 0, 6);
        grid.Controls.Add(new Label
        {
            Text = labelText,
            AutoSize = true,
            Anchor = AnchorStyles.Left,
            Margin = new Padding(0, 9, 12, 6)
        }, 0, row);
        grid.Controls.Add(control, 1, row);
    }

    private static int ClampText(string text, int minimum, int maximum, int fallback)
    {
        if (!int.TryParse(text.Trim(), out var value))
        {
            value = fallback;
        }

        return Math.Clamp(value, minimum, maximum);
    }

    private static string PlatformTitle(string platform) => platform.ToLowerInvariant() switch
    {
        "macos" => "macOS",
        "ios" => "iOS",
        "ipados" => "iPadOS",
        "windows" => "Windows",
        "android" => "Android",
        _ => platform
    };

    private sealed record PeerComboItem(string? DeviceId, string Text)
    {
        public override string ToString() => Text;
    }
}
