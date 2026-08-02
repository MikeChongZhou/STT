using System.Drawing;
using System.Windows.Forms;

namespace ScreenTimeGuardian;

internal sealed class ReportForm : Form
{
    private readonly SessionStore store;
    private readonly P2PTransport? p2pTransport;
    private readonly ComboBox modeBox = new();
    private readonly DateTimePicker datePicker = new();
    private readonly DateTimePicker startPicker = new();
    private readonly DateTimePicker endPicker = new();
    private readonly Button clearDayButton = new();
    private readonly Label summaryLabel = new();
    private readonly DataGridView deviceGrid = new();
    private readonly DataGridView platformGrid = new();
    private readonly DataGridView detailGrid = new();
    private bool refreshing;
    private string Language => store.Settings.Language;

    public ReportForm(SessionStore store, P2PTransport? p2pTransport = null)
    {
        this.store = store;
        this.p2pTransport = p2pTransport;
        Text = L10n.Text("报告", "Report", Language);
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(980, 560);
        Size = new Size(1180, 720);

        BuildUi();
        RefreshReport();
    }

    private void BuildUi()
    {
        var language = Language;
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 5,
            Padding = new Padding(16)
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 34));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 66));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        root.Controls.Add(BuildToolbar(), 0, 0);

        summaryLabel.AutoSize = true;
        summaryLabel.Dock = DockStyle.Fill;
        summaryLabel.Font = new Font(Font, FontStyle.Bold);
        summaryLabel.Margin = new Padding(0, 0, 0, 10);
        root.Controls.Add(summaryLabel, 0, 1);

        var topTables = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            RowCount = 1,
            Margin = new Padding(0, 0, 0, 12)
        };
        topTables.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        topTables.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        topTables.Controls.Add(BuildGridPanel(L10n.Text("本报告范围各设备用时", "Device Usage in This Report", language), deviceGrid), 0, 0);
        topTables.Controls.Add(BuildGridPanel(L10n.Text("上周各平台统计", "Previous Week by Platform", language), platformGrid), 1, 0);
        root.Controls.Add(topTables, 0, 2);

        root.Controls.Add(BuildGridPanel(L10n.Text("明细", "Details", language), detailGrid), 0, 3);

        var closeButton = new Button { Text = L10n.Text("关闭", "Close", language), AutoSize = true, DialogResult = DialogResult.OK };
        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft,
            AutoSize = true,
            Padding = new Padding(0, 12, 0, 0)
        };
        buttons.Controls.Add(closeButton);
        root.Controls.Add(buttons, 0, 4);

        AcceptButton = closeButton;
        CancelButton = closeButton;
        Controls.Add(root);
    }

    private Control BuildToolbar()
    {
        var toolbar = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            AutoSize = true,
            WrapContents = false,
            Margin = new Padding(0, 0, 0, 12)
        };

        modeBox.DropDownStyle = ComboBoxStyle.DropDownList;
        var language = Language;
        modeBox.Items.AddRange([L10n.Text("日报", "Daily", language), L10n.Text("多日报", "Multi-Day", language)]);
        modeBox.SelectedIndex = 0;
        modeBox.SelectedIndexChanged += (_, _) => RefreshReport();
        toolbar.Controls.Add(modeBox);

        ConfigureDatePicker(datePicker);
        ConfigureDatePicker(startPicker);
        ConfigureDatePicker(endPicker);
        toolbar.Controls.Add(datePicker);
        toolbar.Controls.Add(startPicker);
        toolbar.Controls.Add(endPicker);

        var refreshButton = new Button { Text = L10n.Text("刷新", "Refresh", language), AutoSize = true };
        refreshButton.Click += (_, _) => RefreshReport();
        toolbar.Controls.Add(refreshButton);

        clearDayButton.Text = L10n.Text("清除当日记录", "Clear Day Records", language);
        clearDayButton.AutoSize = true;
        clearDayButton.Click += (_, _) => ClearDailyRecords();
        toolbar.Controls.Add(clearDayButton);
        return toolbar;
    }

    private static Control BuildGridPanel(string title, DataGridView grid)
    {
        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            Padding = new Padding(0, 0, 8, 0)
        };
        panel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        panel.Controls.Add(new Label
        {
            Text = title,
            AutoSize = true,
            Dock = DockStyle.Fill,
            Font = new Font(FontFamily.GenericSansSerif, 9, FontStyle.Bold),
            Margin = new Padding(0, 0, 0, 6)
        }, 0, 0);
        ConfigureGrid(grid);
        panel.Controls.Add(grid, 0, 1);
        return panel;
    }

    private static void ConfigureGrid(DataGridView grid)
    {
        grid.Dock = DockStyle.Fill;
        grid.ReadOnly = true;
        grid.AllowUserToAddRows = false;
        grid.AllowUserToDeleteRows = false;
        grid.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
        grid.MultiSelect = false;
        grid.RowHeadersVisible = false;
        grid.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
        grid.BackgroundColor = SystemColors.Window;
        grid.BorderStyle = BorderStyle.FixedSingle;
    }

    private void ConfigureDatePicker(DateTimePicker picker)
    {
        picker.Format = DateTimePickerFormat.Custom;
        picker.CustomFormat = "yyyy-MM-dd";
        picker.Width = 130;
        picker.ValueChanged += (_, _) => RefreshReport();
    }

    private void RefreshReport()
    {
        if (refreshing || modeBox.SelectedIndex < 0)
        {
            return;
        }

        refreshing = true;
        try
        {
            store.CloseExpiredOpenSessions();
            var isDaily = modeBox.SelectedIndex == 0;
            datePicker.Visible = isDaily;
            startPicker.Visible = !isDaily;
            endPicker.Visible = !isDaily;
            clearDayButton.Visible = isDaily;
            if (isDaily)
            {
                FillDailyReport();
            }
            else
            {
                FillMultiDayReport();
            }
        }
        finally
        {
            refreshing = false;
        }
    }

    private void ClearDailyRecords()
    {
        var language = Language;
        var result = MessageBox.Show(
            L10n.Text(
                "将清除所选日期已记录的屏幕用时，并通过 P2P 同步删除到已同意设备。清除后新产生的记录会继续保存。",
                "This clears recorded screen time for the selected date and syncs the deletion to approved devices. New records after clearing will continue to be saved.",
                language),
            L10n.Text("清除当日记录？", "Clear this day's records?", language),
            MessageBoxButtons.OKCancel,
            MessageBoxIcon.Warning);
        if (result != DialogResult.OK)
        {
            return;
        }

        var removed = store.ClearSessionsForDate(datePicker.Value.Date);
        _ = p2pTransport?.SyncNowAsync();
        RefreshReport();
        summaryLabel.Text = $"{summaryLabel.Text}    {L10n.Text("已清除记录", "Cleared records", language)}：{removed}";
    }

    private void FillDailyReport()
    {
        var date = datePicker.Value.Date;
        var dayStartUtc = date.ToUniversalTime();
        var dayEndUtc = date.AddDays(1).ToUniversalTime();
        var total = store.TotalSecondsForDayIncludingOpen(date);
        var language = Language;
        summaryLabel.Text = $"{L10n.Text("日报", "Daily", language)} {DateTools.DateString(date)}    {L10n.Text("去重总用时", "Deduplicated Total", language)}：{DateTools.FormatDuration(total, language)}";
        FillDeviceUsage(dayStartUtc, dayEndUtc, 1);
        FillWeeklyPlatformUsage();
        FillDailyDetails(date);
    }

    private void FillMultiDayReport()
    {
        var startDate = startPicker.Value.Date <= endPicker.Value.Date ? startPicker.Value.Date : endPicker.Value.Date;
        var endDate = startPicker.Value.Date <= endPicker.Value.Date ? endPicker.Value.Date : startPicker.Value.Date;
        var rows = new List<(DateTime Date, int Seconds)>();
        for (var date = startDate; date <= endDate; date = date.AddDays(1))
        {
            rows.Add((date, store.TotalSecondsForDayIncludingOpen(date)));
        }

        var total = rows.Sum(row => row.Seconds);
        var average = rows.Count == 0 ? 0 : total / rows.Count;
        var language = Language;
        summaryLabel.Text = $"{L10n.Text("多日报", "Multi-Day", language)} {DateTools.DateString(startDate)} {L10n.Text("至", "to", language)} {DateTools.DateString(endDate)}    {L10n.Text("去重总用时", "Deduplicated Total", language)}：{DateTools.FormatDuration(total, language)}    {L10n.Text("每天平均", "Daily Average", language)}：{DateTools.FormatDuration(average, language)}";
        FillDeviceUsage(startDate.ToUniversalTime(), endDate.AddDays(1).ToUniversalTime(), Math.Max(1, rows.Count));
        FillWeeklyPlatformUsage();
        FillMultiDayDetails(rows);
    }

    private void FillDeviceUsage(DateTime startUtc, DateTime endUtc, int dayCount)
    {
        deviceGrid.Columns.Clear();
        deviceGrid.Rows.Clear();
        var language = Language;
        deviceGrid.Columns.Add("device", L10n.Text("设备", "Device", language));
        deviceGrid.Columns.Add("platform", L10n.Text("平台", "Platform", language));
        deviceGrid.Columns.Add("total", L10n.Text("总用时", "Total", language));
        deviceGrid.Columns.Add("average", L10n.Text("平均每天", "Daily Average", language));
        deviceGrid.Columns["device"]!.FillWeight = 190;
        deviceGrid.Columns["platform"]!.FillWeight = 70;

        foreach (var row in store.DeviceUsage(startUtc, endUtc, dayCount))
        {
            deviceGrid.Rows.Add(
                row.DeviceName,
                DateTools.PlatformTitle(row.Platform),
                DateTools.FormatDuration(row.TotalSeconds, language),
                DateTools.FormatDuration(row.AverageDailySeconds, language));
        }

        if (deviceGrid.Rows.Count == 0)
        {
            deviceGrid.Rows.Add(L10n.Text("暂无记录", "No records", language), "-", "-", "-");
        }
    }

    private void FillWeeklyPlatformUsage()
    {
        platformGrid.Columns.Clear();
        platformGrid.Rows.Clear();
        var language = Language;
        platformGrid.Columns.Add("platform", L10n.Text("平台", "Platform", language));
        platformGrid.Columns.Add("total", L10n.Text("上周总计", "Weekly Total", language));
        platformGrid.Columns.Add("average", L10n.Text("平均每天", "Daily Average", language));

        var weekly = store.PreviousWeekSummary();
        platformGrid.Rows.Add(L10n.Text("全部平台去重", "All Platforms Deduplicated", language), DateTools.FormatDuration(weekly.totalSeconds, language), DateTools.FormatDuration(weekly.averageDailySeconds, language));
        foreach (var row in weekly.platforms)
        {
            platformGrid.Rows.Add(
                DateTools.PlatformTitle(row.Platform),
                DateTools.FormatDuration(row.TotalSeconds, language),
                DateTools.FormatDuration(row.AverageDailySeconds, language));
        }
    }

    private void FillDailyDetails(DateTime date)
    {
        detailGrid.Columns.Clear();
        detailGrid.Rows.Clear();
        var language = Language;
        detailGrid.Columns.Add("start", L10n.Text("开始", "Start", language));
        detailGrid.Columns.Add("end", L10n.Text("结束", "End", language));
        detailGrid.Columns.Add("duration", L10n.Text("时长", "Duration", language));
        detailGrid.Columns.Add("action", L10n.Text("停止动作", "Stop Action", language));
        detailGrid.Columns.Add("platform", L10n.Text("平台", "Platform", language));
        detailGrid.Columns.Add("device", L10n.Text("设备", "Device", language));
        detailGrid.Columns.Add("scope", L10n.Text("数据范围", "Scope", language));
        detailGrid.Columns["device"]!.FillWeight = 170;

        var dayStartUtc = date.Date.ToUniversalTime();
        var dayEndUtc = date.Date.AddDays(1).ToUniversalTime();
        var now = DateTimeOffset.UtcNow;
        foreach (var session in store.SessionsForDate(date))
        {
            var sessionEnd = store.EffectiveEndUtc(session, now);
            var effectiveStartUtc = session.StartAtUtc.UtcDateTime > dayStartUtc ? session.StartAtUtc.UtcDateTime : dayStartUtc;
            var effectiveEndUtc = sessionEnd.UtcDateTime < dayEndUtc ? sessionEnd.UtcDateTime : dayEndUtc;
            var isStillOpenInSelectedDay = store.IsLocalOpenSession(session) && effectiveEndUtc >= now.UtcDateTime;
            detailGrid.Rows.Add(
                DateTools.DateTimeString(ToUtcOffset(effectiveStartUtc)),
                isStillOpenInSelectedDay ? L10n.Text("进行中", "In progress", language) : DateTools.DateTimeString(ToUtcOffset(effectiveEndUtc)),
                DateTools.FormatDuration(Math.Max(0, (int)(effectiveEndUtc - effectiveStartUtc).TotalSeconds), language),
                DateTools.StopActionTitle(session.StopAction, language),
                DateTools.PlatformTitle(session.Platform),
                session.DeviceName,
                session.MeasurementScope);
        }

        if (detailGrid.Rows.Count == 0)
        {
            detailGrid.Rows.Add(L10n.Text("暂无记录", "No records", language), "-", "-", "-", "-", "-", "-");
        }
    }

    private static DateTimeOffset ToUtcOffset(DateTime utc)
    {
        return new DateTimeOffset(DateTime.SpecifyKind(utc, DateTimeKind.Utc));
    }

    private void FillMultiDayDetails(IEnumerable<(DateTime Date, int Seconds)> rows)
    {
        detailGrid.Columns.Clear();
        detailGrid.Rows.Clear();
        var language = Language;
        detailGrid.Columns.Add("date", L10n.Text("日期", "Date", language));
        detailGrid.Columns.Add("duration", L10n.Text("去重总用时", "Deduplicated Total", language));
        foreach (var row in rows)
        {
            detailGrid.Rows.Add(DateTools.DateString(row.Date), DateTools.FormatDuration(row.Seconds, language));
        }
    }
}
