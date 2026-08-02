using System.Drawing;
using System.Globalization;
using System.Windows.Forms;

namespace ScreenTimeGuardian;

internal sealed class TrackingForm : Form
{
    private readonly SessionStore store;
    private readonly Label statusLabel = new();
    private readonly DataGridView grid = new();
    private readonly Button refreshButton = new();
    private List<LLMRankingRow> currentRows = [];
    private string sortColumn = "prompt";
    private bool sortAscending;
    private bool isFetching;
    private string Language => store.Settings.Language;

    public TrackingForm(SessionStore store)
    {
        this.store = store;
        Text = $"{L10n.Text("跟踪", "Tracking", Language)} - LLM Ranking";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(980, 520);
        Size = new Size(1180, 640);

        BuildUi();
        LoadCacheOrFetch();
    }

    private void BuildUi()
    {
        var language = Language;
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 3,
            Padding = new Padding(16)
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var top = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            AutoSize = true,
            Margin = new Padding(0, 0, 0, 12)
        };
        top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        top.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        statusLabel.AutoSize = true;
        statusLabel.Anchor = AnchorStyles.Left;
        refreshButton.Text = L10n.Text("刷新数据", "Refresh", language);
        refreshButton.AutoSize = true;
        refreshButton.Click += async (_, _) => await FetchLatestAsync();
        top.Controls.Add(statusLabel, 0, 0);
        top.Controls.Add(refreshButton, 1, 0);
        root.Controls.Add(top, 0, 0);

        grid.Dock = DockStyle.Fill;
        grid.ReadOnly = true;
        grid.AllowUserToAddRows = false;
        grid.AllowUserToDeleteRows = false;
        grid.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
        grid.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
        grid.RowHeadersVisible = false;
        grid.ColumnHeadersVisible = true;
        grid.ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.AutoSize;
        grid.Columns.Add("rank", L10n.Text("排名", "Rank", language));
        grid.Columns.Add("name", L10n.Text("LLM 名字", "LLM Name", language));
        grid.Columns.Add("prompt", "Prompt Tokens");
        grid.Columns.Add("output", "Output Tokens");
        grid.Columns.Add("inputPrice", "Input Price / 1M");
        grid.Columns.Add("outputPrice", "Output Price / 1M");
        grid.Columns.Add("revenue", "Weekly Revenue");
        grid.Columns["rank"]!.FillWeight = 45;
        grid.Columns["name"]!.FillWeight = 230;
        foreach (DataGridViewColumn column in grid.Columns)
        {
            column.SortMode = DataGridViewColumnSortMode.Programmatic;
            column.ToolTipText = L10n.Text("点击排序", "Click to sort", language);
        }
        grid.ColumnHeaderMouseClick += (_, e) => SortByColumnIndex(e.ColumnIndex);
        root.Controls.Add(grid, 0, 1);

        var closeButton = new Button { Text = L10n.Text("关闭", "Close", language), AutoSize = true, DialogResult = DialogResult.OK };
        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft,
            AutoSize = true,
            Padding = new Padding(0, 12, 0, 0)
        };
        buttons.Controls.Add(closeButton);
        root.Controls.Add(buttons, 0, 2);

        AcceptButton = closeButton;
        CancelButton = closeButton;
        Controls.Add(root);
    }

    private void LoadCacheOrFetch()
    {
        try
        {
            var cache = store.LoadCurrentLLMRanking();
            if (cache is not null)
            {
                Apply(cache);
                return;
            }

            statusLabel.Text = L10n.Text("本周 OpenRouter LLM Ranking 缓存不存在，将尝试获取。", "This week's OpenRouter LLM Ranking cache does not exist; fetching now.", Language);
            _ = FetchLatestAsync();
        }
        catch (Exception ex)
        {
            statusLabel.Text = $"{L10n.Text("缓存读取失败", "Failed to read cache", Language)}：{ex.Message}";
        }
    }

    private async Task FetchLatestAsync()
    {
        if (isFetching)
        {
            return;
        }

        isFetching = true;
        refreshButton.Enabled = false;
        statusLabel.Text = L10n.Text("正在从 OpenRouter 获取本周 prompt token Top 20...", "Fetching this week's prompt token Top 20 from OpenRouter...", Language);
        grid.Rows.Clear();

        try
        {
            var cache = await new OpenRouterClient().FetchWeeklyPromptTokenTop20Async();
            store.SaveLLMRankingCache(cache);
            Apply(cache);
        }
        catch (Exception ex)
        {
            statusLabel.Text = $"{L10n.Text("OpenRouter 获取失败", "OpenRouter fetch failed", Language)}：{ex.Message}";
        }
        finally
        {
            isFetching = false;
            refreshButton.Enabled = true;
        }
    }

    private void Apply(LLMRankingCache cache)
    {
        currentRows = cache.Rows.ToList();
        FillRows();
        var language = Language;
        statusLabel.Text = $"{L10n.Text("来源", "Source", language)}：{cache.Source}  {L10n.Text("周", "Week", language)}：{cache.WeekId}  {L10n.Text("抓取", "Fetched", language)}：{cache.FetchedAtUtc.ToLocalTime():yyyy-MM-dd HH:mm:ss}";
    }

    private void SortByColumn(string columnName)
    {
        if (!grid.Columns.Contains(columnName))
        {
            return;
        }

        if (sortColumn == columnName)
        {
            sortAscending = !sortAscending;
        }
        else
        {
            sortColumn = columnName;
            sortAscending = columnName is "rank" or "name";
        }

        FillRows();
    }

    private void SortByColumnIndex(int columnIndex)
    {
        if (columnIndex < 0 || columnIndex >= grid.Columns.Count)
        {
            return;
        }

        SortByColumn(grid.Columns[columnIndex].Name);
    }

    private void FillRows()
    {
        grid.SuspendLayout();
        try
        {
            grid.Rows.Clear();
            foreach (var column in grid.Columns.Cast<DataGridViewColumn>())
            {
                column.HeaderCell.SortGlyphDirection = SortOrder.None;
            }
            if (grid.Columns.Contains(sortColumn))
            {
                grid.Columns[sortColumn]!.HeaderCell.SortGlyphDirection = sortAscending ? SortOrder.Ascending : SortOrder.Descending;
            }

            foreach (var row in SortedRows())
            {
                grid.Rows.Add(
                    row.Rank,
                    row.LLMName,
                    FormatNumber(row.PromptTokens),
                    FormatNumber(row.OutputTokens),
                    FormatPrice(row.WeightedAverageInputPrice),
                    FormatPrice(row.WeightedAverageOutputPrice),
                    FormatWholeCurrency(row.WeeklyRevenue));
            }
        }
        finally
        {
            grid.ResumeLayout();
        }
    }

    private IEnumerable<LLMRankingRow> SortedRows()
    {
        return sortColumn switch
        {
            "rank" => Sort(currentRows, row => row.Rank),
            "name" => Sort(currentRows, row => row.LLMName),
            "output" => Sort(currentRows, row => row.OutputTokens),
            "inputPrice" => Sort(currentRows, row => row.WeightedAverageInputPrice),
            "outputPrice" => Sort(currentRows, row => row.WeightedAverageOutputPrice),
            "revenue" => Sort(currentRows, row => row.WeeklyRevenue),
            _ => Sort(currentRows, row => row.PromptTokens)
        };
    }

    private IEnumerable<LLMRankingRow> Sort<TKey>(IEnumerable<LLMRankingRow> rows, Func<LLMRankingRow, TKey> keySelector)
    {
        return sortAscending
            ? rows.OrderBy(keySelector).ThenBy(row => row.Rank).ThenBy(row => row.LLMName)
            : rows.OrderByDescending(keySelector).ThenBy(row => row.Rank).ThenBy(row => row.LLMName);
    }

    private static string FormatNumber(double value) => value.ToString("N0", CultureInfo.InvariantCulture);

    private static string FormatPrice(double value) => $"${value:N2}";

    private static string FormatWholeCurrency(double value) => $"${value:N0}";
}
