namespace ScreenTimeGuardian;

internal static class L10n
{
    public static string Text(string zh, string en, string language) => language == "en" ? en : zh;

    public static string SyncStatus(string value, string language)
    {
        if (language != "en")
        {
            return value;
        }

        var text = value;
        var replacements = new (string Zh, string En)[]
        {
            ("P2P 同步已关闭", "P2P sync is off"),
            ("P2P 同步已停止", "P2P sync stopped"),
            ("P2P 已关闭", "P2P is off"),
            ("已同意，等待同步", "Approved; waiting to sync"),
            ("已拒绝，未同步", "Rejected; not synced"),
            ("待确认，未同步", "Pending approval; not synced"),
            ("已发现设备，但尚未同意任何同步设备", "Devices found, but no sync device has been approved"),
            ("手动同步完成", "Manual sync complete"),
            ("手动同步失败：没有设备响应", "Manual sync failed: no device responded"),
            ("对方未返回同步数据，请确认两端都已同意该设备并使用最新版本", "The other device did not return sync data. Make sure both devices approved each other and are on the latest version."),
            ("正在同步", "Syncing"),
            ("同步完成：无新增数据", "Sync complete: no new records"),
            ("同步完成：合并", "Sync complete: merged"),
            ("同步完成", "Sync complete"),
            ("同步失败", "Sync failed"),
            ("接收同步连接失败", "Failed to receive sync connection"),
            ("已发现 STG 设备，但配对码不一致", "Found STG device, but pairing code does not match"),
            ("发现 STG 设备但配对码不一致", "Found STG device but pairing code does not match"),
            ("配对码不一致，不能同意该设备", "Pairing code mismatch; cannot approve this device"),
            ("配对码不一致，不能同步", "Pairing code mismatch; cannot sync"),
            ("已同步", "Synced"),
            ("同步数据无法解密或解析", "Sync data could not be decrypted or parsed"),
            ("已拒绝设备尝试同步", "Rejected device attempted to sync"),
            ("收到待确认设备请求", "Received pending device request"),
            ("配对码不一致", "Pairing code mismatch"),
            ("离线", "Offline"),
            ("待确认", "Pending approval"),
            ("已同意", "Approved"),
            ("已拒绝", "Rejected")
        };

        foreach (var (zh, en) in replacements)
        {
            text = text.Replace(zh, en, StringComparison.Ordinal);
        }

        return text
            .Replace("条记录", " records", StringComparison.Ordinal)
            .Replace("台设备", " devices", StringComparison.Ordinal)
            .Replace("设备", " device", StringComparison.Ordinal);
    }
}
