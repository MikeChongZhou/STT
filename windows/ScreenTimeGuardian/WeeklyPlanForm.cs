using System.Drawing;
using System.Windows.Forms;

namespace ScreenTimeGuardian;

internal sealed class WeeklyPlanForm : Form
{
    private readonly NumericUpDown plannedHoursBox = new();
    private readonly NumericUpDown plannedMinuteRemainderBox = new();

    public WeeklyPlanForm(int previousWeekTotalSeconds, int previousWeekAverageSeconds, int defaultMinutes, string language = "zh")
    {
        Text = L10n.Text("上周用时总结", "Previous Week Summary", language);
        StartPosition = FormStartPosition.CenterScreen;
        Size = new Size(480, 260);
        MaximizeBox = false;
        MinimizeBox = false;
        FormBorderStyle = FormBorderStyle.FixedDialog;

        var normalizedDefault = Math.Clamp(defaultMinutes, 1, 1440);
        plannedHoursBox.Minimum = 0;
        plannedHoursBox.Maximum = 24;
        plannedHoursBox.Value = normalizedDefault / 60;
        plannedMinuteRemainderBox.Minimum = 0;
        plannedMinuteRemainderBox.Maximum = 59;
        plannedMinuteRemainderBox.Value = normalizedDefault % 60;
        plannedMinuteRemainderBox.Increment = 5;

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 4,
            Padding = new Padding(20)
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        root.Controls.Add(new Label
        {
            Text = $"{L10n.Text("上周总用时", "Previous week total", language)}：{DateTools.FormatDuration(previousWeekTotalSeconds, language)}\n{L10n.Text("每天平均用时", "Daily average", language)}：{DateTools.FormatDuration(previousWeekAverageSeconds, language)}",
            AutoSize = true,
            Dock = DockStyle.Fill,
            Margin = new Padding(0, 0, 0, 14)
        }, 0, 0);

        var inputRow = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            FlowDirection = FlowDirection.LeftToRight
        };
        inputRow.Controls.Add(new Label { Text = L10n.Text("本周每天计划用时", "This week's daily plan", language), AutoSize = true, Margin = new Padding(0, 7, 12, 0) });
        inputRow.Controls.Add(plannedHoursBox);
        inputRow.Controls.Add(new Label { Text = L10n.Text("小时", "h", language), AutoSize = true, Margin = new Padding(6, 7, 10, 0) });
        inputRow.Controls.Add(plannedMinuteRemainderBox);
        inputRow.Controls.Add(new Label { Text = L10n.Text("分钟", "min", language), AutoSize = true, Margin = new Padding(6, 7, 0, 0) });
        root.Controls.Add(inputRow, 0, 1);

        var saveButton = new Button { Text = L10n.Text("保存", "Save", language), AutoSize = true, DialogResult = DialogResult.OK };
        var laterButton = new Button { Text = L10n.Text("稍后", "Later", language), AutoSize = true, DialogResult = DialogResult.Cancel };
        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft,
            AutoSize = true
        };
        buttons.Controls.Add(laterButton);
        buttons.Controls.Add(saveButton);
        root.Controls.Add(buttons, 0, 3);

        AcceptButton = saveButton;
        CancelButton = laterButton;
        Controls.Add(root);
    }

    public int PlannedMinutes
    {
        get
        {
            var total = (int)plannedHoursBox.Value * 60 + (int)plannedMinuteRemainderBox.Value;
            return Math.Clamp(total <= 0 ? 480 : total, 1, 1440);
        }
    }
}
