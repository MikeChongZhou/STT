using System.Drawing;
using System.Windows.Forms;

namespace ScreenTimeGuardian;

internal sealed class RestPromptForm : Form
{
    private readonly int countdownSeconds;
    private readonly bool immediateClose;
    private readonly string language;
    private readonly Label countdownLabel = new();
    private readonly Button closeButton = new();
    private readonly System.Windows.Forms.Timer timer = new();
    private int remainingSeconds;

    public RestPromptForm(string title, string message, int countdownSeconds, bool immediateClose, string language = "zh")
    {
        this.countdownSeconds = Math.Max(0, countdownSeconds);
        this.immediateClose = immediateClose;
        this.language = language;
        remainingSeconds = this.countdownSeconds;

        Text = title;
        StartPosition = FormStartPosition.CenterScreen;
        Size = new Size(560, 320);
        MinimumSize = new Size(520, 280);
        MaximizeBox = false;
        MinimizeBox = false;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        TopMost = true;

        BuildUi(message);
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        UpdateCountdownLabel();
        if (!immediateClose && countdownSeconds > 0)
        {
            timer.Interval = 1000;
            timer.Tick += (_, _) => Tick();
            timer.Start();
        }
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        timer.Stop();
        timer.Dispose();
        base.OnFormClosed(e);
    }

    private void BuildUi(string message)
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 3,
            Padding = new Padding(24)
        };
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        root.Controls.Add(new Label
        {
            Text = message,
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font(Font.FontFamily, 14, FontStyle.Bold)
        }, 0, 0);

        countdownLabel.Dock = DockStyle.Fill;
        countdownLabel.TextAlign = ContentAlignment.MiddleCenter;
        countdownLabel.Font = new Font(FontFamily.GenericMonospace, 12, FontStyle.Regular);
        countdownLabel.Margin = new Padding(0, 8, 0, 12);
        root.Controls.Add(countdownLabel, 0, 1);

        closeButton.Text = L10n.Text("关闭", "Close", language);
        closeButton.AutoSize = true;
        closeButton.Anchor = AnchorStyles.None;
        closeButton.Enabled = immediateClose || countdownSeconds == 0;
        closeButton.DialogResult = DialogResult.OK;
        root.Controls.Add(closeButton, 0, 2);

        AcceptButton = closeButton;
        Controls.Add(root);
    }

    private void Tick()
    {
        remainingSeconds -= 1;
        UpdateCountdownLabel();
        if (remainingSeconds <= 0)
        {
            timer.Stop();
            closeButton.Enabled = true;
            closeButton.Focus();
        }
    }

    private void UpdateCountdownLabel()
    {
        if (immediateClose)
        {
            countdownLabel.Text = L10n.Text("会议模式：可以立即关闭", "Meeting mode: can close immediately", language);
        }
        else if (remainingSeconds > 0)
        {
            countdownLabel.Text = language == "en" ? $"{remainingSeconds} seconds remaining" : $"剩余 {remainingSeconds} 秒";
        }
        else
        {
            countdownLabel.Text = L10n.Text("可以关闭", "Ready to close", language);
        }
    }
}
