using System.Globalization;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ScreenTimeGuardian;

internal sealed class LLMRankingCache
{
    [JsonPropertyName("week_id")]
    public string WeekId { get; set; } = "";

    [JsonPropertyName("period_start")]
    public string? PeriodStart { get; set; }

    [JsonPropertyName("period_end")]
    public string? PeriodEnd { get; set; }

    [JsonPropertyName("source")]
    public string Source { get; set; } = "openrouter.ai";

    [JsonPropertyName("fetched_at_utc")]
    public DateTimeOffset FetchedAtUtc { get; set; }

    [JsonPropertyName("rows")]
    public List<LLMRankingRow> Rows { get; set; } = [];
}

internal sealed class LLMRankingRow
{
    [JsonPropertyName("rank")]
    public int Rank { get; set; }

    [JsonPropertyName("llm_name")]
    public string LLMName { get; set; } = "";

    [JsonPropertyName("prompt_tokens")]
    public double PromptTokens { get; set; }

    [JsonPropertyName("output_tokens")]
    public double OutputTokens { get; set; }

    [JsonPropertyName("weighted_average_input_price")]
    public double WeightedAverageInputPrice { get; set; }

    [JsonPropertyName("weighted_average_output_price")]
    public double WeightedAverageOutputPrice { get; set; }

    [JsonPropertyName("weekly_revenue")]
    public double WeeklyRevenue { get; set; }
}

internal sealed class OpenRouterClient
{
    private static readonly HttpClient Client = new()
    {
        BaseAddress = new Uri("https://openrouter.ai"),
        Timeout = TimeSpan.FromSeconds(30)
    };

    public async Task<LLMRankingCache> FetchWeeklyPromptTokenTop20Async(CancellationToken token = default)
    {
        var entries = await FetchRankingEntriesAsync(token);
        var topEntries = entries
            .Where(row => !string.IsNullOrWhiteSpace(row.Permaslug) && row.PromptTokens > 0)
            .OrderByDescending(row => row.PromptTokens)
            .Take(20)
            .ToList();

        var rows = new List<LLMRankingRow>();
        var rank = 1;
        foreach (var entry in topEntries)
        {
            var pricing = await FetchEffectivePricingOrDefaultAsync(entry.Permaslug, entry.Variant, token);
            var revenue =
                entry.PromptTokens / 1_000_000 * pricing.WeightedInputPricePerMillion
                + entry.OutputTokens / 1_000_000 * pricing.WeightedOutputPricePerMillion;
            rows.Add(new LLMRankingRow
            {
                Rank = rank++,
                LLMName = entry.Permaslug,
                PromptTokens = entry.PromptTokens,
                OutputTokens = entry.OutputTokens,
                WeightedAverageInputPrice = pricing.WeightedInputPricePerMillion,
                WeightedAverageOutputPrice = pricing.WeightedOutputPricePerMillion,
                WeeklyRevenue = revenue
            });
        }

        var weekStart = DateTools.CurrentWeekStart();
        return new LLMRankingCache
        {
            WeekId = DateTools.WeekId(),
            PeriodStart = DateTools.DateString(weekStart),
            PeriodEnd = DateTools.DateString(weekStart.AddDays(6)),
            Source = "openrouter.ai/api/frontend/v1",
            FetchedAtUtc = DateTimeOffset.UtcNow,
            Rows = rows
        };
    }

    private static async Task<List<OpenRouterRankingEntry>> FetchRankingEntriesAsync(CancellationToken token)
    {
        using var response = await Client.GetAsync("/api/frontend/v1/rankings/models?view=week", token);
        response.EnsureSuccessStatusCode();
        using var document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(token), cancellationToken: token);
        if (!document.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException("OpenRouter rankings 返回格式缺少 data 数组");
        }

        var entries = new List<OpenRouterRankingEntry>();
        foreach (var row in data.EnumerateArray())
        {
            var permaslug = StringValue(row, "model_permaslug");
            if (string.IsNullOrWhiteSpace(permaslug))
            {
                continue;
            }

            entries.Add(new OpenRouterRankingEntry(
                permaslug,
                string.IsNullOrWhiteSpace(StringValue(row, "variant")) ? "standard" : StringValue(row, "variant"),
                NumberValue(row, "total_prompt_tokens"),
                NumberValue(row, "total_completion_tokens")));
        }

        if (entries.Count == 0)
        {
            throw new InvalidOperationException("OpenRouter rankings 没有返回可用数据");
        }

        return entries;
    }

    private static async Task<OpenRouterEffectivePricing> FetchEffectivePricingOrDefaultAsync(string permaslug, string variant, CancellationToken token)
    {
        try
        {
            var url = $"/api/frontend/v1/stats/effective-pricing?permaslug={Uri.EscapeDataString(permaslug)}&variant={Uri.EscapeDataString(string.IsNullOrWhiteSpace(variant) ? "standard" : variant)}";
            using var response = await Client.GetAsync(url, token);
            response.EnsureSuccessStatusCode();
            var payload = await response.Content.ReadFromJsonAsync<JsonElement>(cancellationToken: token);
            if (!payload.TryGetProperty("data", out var data))
            {
                return new OpenRouterEffectivePricing(0, 0);
            }

            return new OpenRouterEffectivePricing(
                NumberValue(data, "weightedInputPrice"),
                NumberValue(data, "weightedOutputPrice"));
        }
        catch
        {
            return new OpenRouterEffectivePricing(0, 0);
        }
    }

    private static string StringValue(JsonElement row, string property)
    {
        return row.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? ""
            : "";
    }

    private static double NumberValue(JsonElement row, string property)
    {
        if (!row.TryGetProperty(property, out var value))
        {
            return 0;
        }

        return value.ValueKind switch
        {
            JsonValueKind.Number => value.GetDouble(),
            JsonValueKind.String when double.TryParse(value.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var result) => result,
            _ => 0
        };
    }
}

internal sealed record OpenRouterRankingEntry(string Permaslug, string Variant, double PromptTokens, double OutputTokens);

internal sealed record OpenRouterEffectivePricing(double WeightedInputPricePerMillion, double WeightedOutputPricePerMillion);
