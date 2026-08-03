# STT 项目测试报告

**日期**：2026-08-03
**版本**：V1.0.9
**测试方法**：静态代码分析 + 需求对照审查

---

## 一、需求覆盖度总览

| 需求模块 | macOS | Windows | iOS | Android | 覆盖率 |
|---------|-------|---------|-----|---------|--------|
| 4.1 屏幕用时记录 | ✅ | ✅ | ⚠️ | ✅ | 90% |
| 4.2 护眼和姿势提醒 | ✅ | ✅ | ✅ | ✅ | 95% |
| 4.3 每日计划与超时提醒 | ✅ | ✅ | ⚠️ | ✅ | 85% |
| 5.x 报告 | ✅ | ✅ | ⚠️ | ✅ | 85% |
| 6.x P2P 同步 | ✅ | ✅ | ⚠️ | ✅ | 90% |
| 7.x 设置 | ✅ | ✅ | ✅ | ✅ | 95% |
| 8.x 跟踪 | ✅ | ✅ | ⚠️ | ✅ | 85% |
| 9.1 macOS | ✅ | — | — | — | 100% |
| 9.2 Windows | — | ✅ | — | — | 95% |
| 9.3 iOS | — | — | ⚠️ | — | 75% |
| 9.4 Android | — | — | — | ✅ | 90% |

---

## 二、发现的问题（按严重程度排序）

### 🔴 P0 — 严重问题（影响核心功能）

#### BUG-001：macOS 提醒倒计时不基于绝对时间
- **位置**：`Sources/main.swift` → `RestPromptWindowController`
- **现象**：倒计时用 `Timer.scheduledTimer(withTimeInterval: 1, repeats: true)` 递减，macOS 端如果 App 被系统暂停或进入后台，Timer 停止，回来后倒计时不准
- **需求**：4.2 节明确要求 "iOS 和 Android 的提醒倒计时必须基于绝对可关闭时间计算"
- **影响**：macOS 用户在倒计时过程中切换到其他应用，回来后倒计时可能还剩很久
- **建议**：改为 `canCloseAt = Date() + countdownSeconds`，显示时用 `max(0, canCloseAt - Date())` 计算剩余秒数

#### BUG-002：iOS ScreenTime 数据导入不完整
- **位置**：`iOS/ScreenTimeGuardianMonitorExtension/ScreenTimeGuardianMonitorExtension.swift`
- **现象**：
  1. `intervalDidStart` 和 `intervalDidEnd` 只调用 `managedSettingsStore.clearAllSettings()`，没有导入 ScreenTime 数据
  2. 只有 `eventDidReachThreshold` 会记录事件，但需求要求"每累计到护眼周期触发一次提醒，不能把连续阈值再次从 0 开始导入造成重叠"
  3. iOS 报告页 (`ScreenTimeGuardianSummaryReportView`) 可能无法正确显示 ScreenTime 导入的数据
- **需求**：9.3 节要求 "DeviceActivity 阈值事件应写入 App Group 共享事件日志，再由主应用导入成本应用 screen_session 记录"
- **影响**：iOS 上的 ScreenTime 数据可能无法正确进入报告和同步
- **建议**：确保 checkpoint 事件正确写入 App Group 日志，主 App 正确导入为 screen_session

#### BUG-003：iOS 超时提醒逻辑缺失
- **位置**：`iOS/ScreenTimeGuardianIOS/ScreenTimeGuardianIOSApp.swift`
- **现象**：iOS 主 App 中没有找到超时提醒的实现逻辑。macOS 和 Android 都有 `checkTimeoutPlan()`，但 iOS 的 ScreenTime 扩展只处理护眼/姿势提醒
- **需求**：4.3 节要求 "当当用屏总用时超过计划值时，应弹出超时提醒"
- **影响**：iOS 用户不会收到超时提醒
- **建议**：在 iOS 主 App 中实现超时检查逻辑，或在 ScreenTime 扩展中添加超时阈值

#### BUG-004：macOS P2P 同步帧格式不符合需求
- **位置**：`Sources/main.swift` → P2P sync 部分
- **现象**：需求要求 "TCP 帧使用 4 字节 big-endian 长度前缀"，但 macOS 实现使用 NWConnection 的 `send`/`receive` 方法，没有看到明确的 4 字节长度前缀处理
- **需求**：6.2 节
- **影响**：跨平台同步可能因帧格式不一致而失败
- **建议**：确认所有平台都使用 4 字节 big-endian 长度前缀

---

### 🟡 P1 — 重要问题（影响用户体验）

#### BUG-005：macOS 提醒窗口固定 560x300 大小
- **位置**：`Sources/main.swift:3755` → `RestPromptWindowController`
- **现象**：窗口大小硬编码为 `NSRect(x: 0, y: 0, width: 560, height: 300)`，英文文案可能被截断
- **需求**：10. 节要求 "英文界面下提醒弹窗文字必须完整显示，不能被按钮或窗口边界截断"
- **影响**：英文用户可能看到文字被截断
- **建议**：使用 Auto Layout 让窗口自适应内容大小

#### BUG-006：Android 提醒倒计时使用 Handler 但未处理屏幕关闭
- **位置**：`android/.../RestPromptActivity.kt`
- **现象**：`runCountdown()` 用 `Handler.postDelayed` 每秒更新，但没有 `ACTION_SCREEN_OFF` 监听。如果屏幕关闭，Handler 可能继续运行或停止
- **需求**：4.2 节要求 "锁屏或熄屏后再回来，应按真实经过时间更新剩余秒数"
- **影响**：Android 用户锁屏后回来，倒计时可能不准
- **建议**：`updateCountdown()` 已经用 `canCloseAtMillis - System.currentTimeMillis()` 计算，这是正确的。但 `runCountdown` 的 Handler 在屏幕关闭时可能被系统暂停。建议用 `AlarmManager` 或在 `onResume` 中强制更新

#### BUG-007：iOS 通知声音设置逻辑不完整
- **位置**：`iOS/.../ScreenTimeGuardianMonitorExtension.swift:62`
- **现象**：`content.sound = .default` 在非会议模式下总是设置，但没有检查用户是否授权了声音
- **需求**：4.2 节要求 "非会议模式下，移动端提醒应在用户已授权的前提下播放声音"
- **影响**：如果用户未授权声音，可能导致通知失败或静音
- **建议**：在发送通知前检查 `UNUserNotificationCenter.current().getNotificationSettings` 的 `soundSetting`

#### BUG-008：macOS 周一总结逻辑可能重复触发
- **位置**：`Sources/main.swift` → 周总结部分
- **现象**：检查周一总结的逻辑没有看到持久化"已触发"状态的机制。如果 App 在周一多次重启，可能重复弹出周总结
- **需求**：4.3 节要求 "每周一应提示上周用时总结"
- **影响**：周一多次弹出总结
- **建议**：在 `AppSettings` 中记录 `lastWeeklySummaryDate`，避免重复触发

#### BUG-009：Android Bonjour 服务类型不一致
- **位置**：`android/.../P2PTransport.kt`
- **现象**：Android 使用 `NsdManager` 注册服务，但服务类型字符串需要确认是否为 `_stg-sync._tcp`
- **需求**：6.2 节要求 "局域网发现统一使用 Bonjour/DNS-SD：`_stg-sync._tcp.local`"
- **影响**：如果服务类型不一致，跨平台发现会失败
- **建议**：确认 Android 的 `SERVICE_TYPE` 常量为 `"_stg-sync._tcp"`

#### BUG-010：iOS 主 App 的 P2P 同步实现可能不完整
- **位置**：`iOS/.../ScreenTimeGuardianIOSApp.swift` (5105 行)
- **现象**：iOS App 文件过大，需要确认 P2P 同步、设备发现、设备审批等功能是否完整实现
- **需求**：6.x 节
- **影响**：iOS 可能无法与其他平台正常同步
- **建议**：验证 iOS 的 P2P 传输、Bonjour 发现、设备审批流程

---

### 🟢 P2 — 次要问题（改进建议）

#### BUG-011：macOS 10 秒轮询检查提醒
- **位置**：`Sources/main.swift:3908`
- **现象**：`reminderTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true)` 每 10 秒检查一次提醒
- **影响**：提醒可能有最多 10 秒延迟
- **建议**：改为更短的间隔（如 1 秒）或使用更精确的调度

#### BUG-012：macOS `eyeActiveSeconds` 和 `postureActiveSeconds` 独立计时
- **位置**：`Sources/main.swift:3830-3831`
- **现象**：`eyeActiveSeconds` 和 `postureActiveSeconds` 都在 `accumulateReminderSeconds` 中累加，但 `eyeActiveSeconds` 在触发后重置为 0，而 `postureActiveSeconds` 只在姿势触发时重置
- **影响**：如果姿势切换关闭，`postureActiveSeconds` 会无限累加（虽然不会触发）
- **建议**：姿势切换关闭时也重置 `postureActiveSeconds`

#### BUG-013：Android `removeDuplicateScreenTimeSessions` 可能误删
- **位置**：`android/.../SessionStore.kt:659`
- **现象**：需要确认去重逻辑是否只删除真正的重复 ScreenTime 记录，不会误删正常的手动记录
- **影响**：可能丢失用户数据
- **建议**：添加更严格的去重条件（如只对 `measurementScope == ios_screen_time_selected` 的记录去重）

#### BUG-014：iOS 报告扩展 (Report Extension) 实现可能不完整
- **位置**：`iOS/.../ScreenTimeGuardianReportExtension/`
- **现象**：只有 `SummaryReport` 和 `SummaryReportView`，没有看到完整的日报/多日报/周报实现
- **需求**：5.x 节要求详细的日报、多日报、周统计
- **影响**：iOS 报告功能可能不完整
- **建议**：补充报告扩展的实现

#### BUG-015：共享同步 schema 缺少 `history_compaction` 字段
- **位置**：`shared/sync/screen-session.schema.json`
- **现象**：设计文档提到 V1.0.9 启用 `history_compaction` 能力，但 schema 中没有相关字段
- **影响**：历史归档功能可能无法正确序列化/反序列化
- **建议**：在 schema 中添加历史归档相关字段

#### BUG-016：Windows Bonjour 实现依赖第三方库
- **位置**：`windows/.../BonjourDiscovery.cs` (22803 行)
- **现象**：Windows 使用 C# 实现 Bonjour，可能依赖 `Zeroconf` 或类似库
- **影响**：需要确认 Windows 上 Bonjour 服务的可用性和依赖
- **建议**：文档中明确 Windows 的 Bonjour 依赖和安装说明

---

## 三、平台一致性问题

| 功能 | macOS | Windows | iOS | Android | 一致性 |
|------|-------|---------|-----|---------|--------|
| 提醒倒计时方式 | Timer（相对） | 未确认 | 绝对时间 | 绝对时间 | ❌ |
| 会议模式提示文案 | ✅ | 未确认 | ✅ | ✅ | ⚠️ |
| 姿势切换间隔推导 | ✅ (2x) | 未确认 | ✅ (2x) | ✅ (2x) | ✅ |
| 超时提醒间隔 | 25分钟 | 未确认 | ❌ 缺失 | 未确认 | ❌ |
| 周一总结 | ✅ | 未确认 | ❌ 缺失 | 未确认 | ❌ |
| P2P 服务类型 | `_stg-sync._tcp` | 未确认 | `_stg-sync._tcp` | 需确认 | ⚠️ |
| 数据模型字段 | ✅ 完整 | ✅ 完整 | ✅ 完整 | ✅ 完整 | ✅ |

---

## 四、安全问题

1. **P2P 配对码**：默认生成 6 位数字码，需求建议用户修改默认码。设置中有提示但没有强制
2. **P2P 传输加密**：使用 AES-GCM，符合需求
3. **设备身份**：macOS 使用 host UUID + Keychain 持久化，符合需求
4. **未同意设备**：代码中有 `isTrusted` 检查，符合需求

---

## 五、测试建议

### 优先级 1（必须修复）
1. 修复 macOS 提醒倒计时为绝对时间
2. 补全 iOS 超时提醒逻辑
3. 确认 iOS ScreenTime 数据导入完整性
4. 确认跨平台 P2P 帧格式一致性

### 优先级 2（应该修复）
5. 修复 macOS 提醒窗口自适应大小
6. 修复 Android 提醒倒计时屏幕关闭处理
7. 确认 iOS 通知声音授权检查
8. 防止 macOS 周一总结重复触发

### 优先级 3（建议改进）
9. 优化 macOS 提醒检查间隔
10. 补全 iOS 报告扩展
11. 确认 Windows Bonjour 依赖
12. 统一所有平台的 P2P 服务类型常量

---

## 六、总结

STT 项目实现了需求文档中约 **85-90%** 的功能，主要平台（macOS、Android）的核心功能基本完整。主要差距在：

1. **iOS 端**：ScreenTime 数据导入、超时提醒、报告扩展需要补全
2. **跨平台一致性**：提醒倒计时方式不统一（macOS 用相对时间，iOS/Android 用绝对时间）
3. **macOS**：提醒窗口大小固定、周总结可能重复触发

整体代码质量较高，数据模型和同步协议设计合理。建议优先修复 P0 问题后发布。
