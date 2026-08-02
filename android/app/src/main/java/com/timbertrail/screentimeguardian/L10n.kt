package com.timbertrail.screentimeguardian

object L10n {
    fun text(zh: String, en: String, language: String): String =
        if (language == "en") en else zh

    fun syncStatus(value: String, language: String): String {
        if (language != "en") return value
        var text = value
        val replacements = listOf(
            "P2P 已关闭" to "P2P is off",
            "本机" to "This device",
            "来自同步数据" to "From synced data",
            "已同意，当前未发现" to "Approved; not currently discovered",
            "已同意，等待同步" to "Approved; waiting to sync",
            "已同意设备，等待同步" to "Approved device; waiting to sync",
            "已拒绝，未同步" to "Rejected; not synced",
            "待确认，未同步" to "Pending approval; not synced",
            "已发现设备，但尚未同意任何同步设备" to "Devices found, but no sync device has been approved",
            "正在同步" to "Syncing",
            "同步完成" to "Sync complete",
            "无新记录" to "No new records",
            "收到待确认设备请求" to "Received pending device request",
            "已拒绝设备尝试同步" to "Rejected device attempted to sync",
            "P2P 已同步" to "P2P synced",
            "P2P 已连接，无新记录" to "P2P connected; no new records",
            "后台服务初始化中" to "background service is starting",
            "待确认" to "Pending approval",
            "已同意" to "Approved",
            "已拒绝" to "Rejected"
        )
        replacements.forEach { (zh, en) -> text = text.replace(zh, en) }
        return text
            .replace("条记录", " records")
            .replace("台设备", " devices")
            .replace("设备", " device")
    }
}
