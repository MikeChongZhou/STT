# MEMORY.md - 会话记录
## 2026-08-07

### 会话 1 - STT 项目状态检查

**用户请求：** 检查 STT 项目是否还有问题

**AI 回复：**
- 检查了 OpenClaw 的 STT（Speech-to-Text）配置
- 发现 `tools.media.audio` 没有配置任何音频转录 provider
- 询问用户具体遇到的 STT 问题表现

**用户回复：** 指向 GitHub 仓库 https://github.com/MikeChongZhou/STT/tree/fix/test-issues

**AI 行动：**
- 克隆了 STT 仓库的 `fix/test-issues` 分支
- 发现这是一个名为 "Screen Time Guardian" 的跨设备屏幕时间管理应用
- 项目包含 macOS、iOS、Windows、Android 平台的代码

### 会话 2 - 三个 iOS 问题修复

**用户提出三个修改需求：**

#### 问题 1：超时提醒逻辑迁移
- **问题：** 当日累计屏幕用时超时提醒只在 App 内实现，需要移到 Screen Time 的 checkpoint 逻辑中
- **要求：** 每次 checkpoint 核查累计用时，超时后每新增 25 分钟提醒（非连续使用，累计新增）
- **实现：** 重复间隔 = checkpoint 周期 + 可配置的 extra minutes（默认 5 分钟）

#### 问题 2：屏幕使用时间记录不准确（Race Condition）
- **问题：** 多 Event 触发时的 Baseline 并发竞争
- **原因：** EyeRest 和 Checkpoint 在同一分钟数触发时，后触发的 Event 读取 baseline 已更新，导致增量为 0
- **用户分析：** 分离事件的 Baseline 标记，只让 Checkpoint 独占更新
- **AI 验证：** 用户分析正确，reminder 事件不应碰 baseline

#### 问题 3：P2P 同步依赖前台
- **问题：** iOS P2P 同步只在 App 前台运行，macOS/Android/Windows 都能后台同步
- **要求：** 同步触发挂到 checkpoint，删除设置界面的同步周期
- **方案：** 使用"快速同步"——前台 App 做 Bonjour 发现并缓存 peer 地址到 App Group，Extension 的 checkpoint 读取缓存直接 TCP 连接同步

**讨论过程：**
- AI 分析了各平台 P2P 实现差异（macOS 常驻、Android ForegroundService、Windows 托盘、iOS 需前台）
- 确认 iOS 是唯一 P2P 依赖前台的平台
- 讨论了 Extension 网络能力限制（可短时请求，不能维持长连接）
- 用户同意"快速同步方案"

**实现细节：**

**Issue 2 修复（Race Condition）：**
- `eventDidReachThreshold` 中 reminder 分支不再更新 baseline
- `recordEvent` 中 baseline 更新移到 `if !isCheckpointEvent { return }` 之后
- 只有 checkpoint 写 `last_recorded_threshold_minutes`

**Issue 1 修复（超时提醒）：**
- `checkDailyPlanOvertime` 改为基于累计屏幕时间判断重复间隔
- 重复间隔 = `checkpointIntervalMinutes + overtimeRepeatExtraMinutes`（默认 2+5=7 分钟）
- 新增 `overtimeRepeatExtraMinutes` 设置项，UI 中可调节
- 主 App 前台的 `shouldShowTimeoutPrompt` 调用已移除

**Issue 3 修复（P2P 快速同步）：**
- 前台 App 的 `notifyChanged()` 自动缓存 trusted peer 地址到 App Group
- Extension 的 `fastSyncOnCheckpoint()` 读取缓存，直接 TCP 连接同步
- 设置界面的"同步间隔"已删除，替换为说明文字
- P2P 设置（开关、配对码）同步到 App Group 供 Extension 读取

**提交记录：**
- commit `8655a9c` — 添加 MEMORY.md
- commit `5cb5b48` — fix: 修复三个 iOS 问题（+214 行，-46 行）

**修改的文件：**
1. `iOS/.../ScreenTimeGuardianMonitorExtension.swift` — +182 -28
2. `iOS/.../ScreenTimeGuardianIOSApp.swift` — +75 -18
3. `iOS/.../ScreenTimeGuardianScreenTimeNames.swift` — +3

**待办：**
- [ ] 用户本地 Xcode 编译验证（服务器无 Xcode 环境）
- [ ] 如有编译错误需要修复

---

## 项目信息

- **仓库：** https://github.com/MikeChongZhou/STT
- **当前分支：** fix/test-issues
- **项目类型：** 跨平台屏幕时间管理应用（Screen Time Guardian）
- **主要文档：** README.md, TEST_REPORT.md, DESIGN_GAP_ANALYSIS.md
- **平台：** macOS (Swift), iOS (SwiftUI), Windows (C#), Android (Kotlin)


修复内容：
当日总用时提醒还有些问题，1.设置中 overtime reminder interval 显示5分钟，可以修改，这个不对，应该为 5分钟+ screen time record interval 20 分钟 = 25分钟，这个20分钟是直接从上面设置去复制下来的，和上面的相同，如果用户修改 screen time record interval 为3分钟，这里就位 5+3 = 8分钟；2.另外，我修改daily plan 为1小时，总屏幕用时已经时3个多小时，但是没有出现通知和提醒。请看下为何？

1.UI — 超时提醒间隔现在显示总间隔（如 25 分钟 = 20 记录间隔 + 5 额外），不再是单独的 5
2.即时同步 — daily plan 和 overtime extra 修改后立刻写入 App Group，不再等离开设置页。这解决了你改了 1 小时计划但 Extension 还读到旧值 480 分钟的问题


1.所有的设置修改，都看下有没有做相关的保存和更新？增加保存按钮和取消按钮；2.设置界面中各个数字的修改比较难以操作，请提供上下按钮或手表按钮以方便修改；3.在记录时间补偿中，补偿过一次后，下一次就不再补偿了，但实际上数据还是对不齐的，4.还是有出现reminder 提醒了，但是没有看到 checkpoint 记录用时数据

1.Save/Cancel — 设置页打开时拍快照，Cancel 恢复快照，Save 保存并关闭
2.Stepper 控件 — 所有数字输入旁边都有 [-] [+] 按钮
3.Gap 补偿增强 — 即使 actualSegmentSeconds=0（重复 threshold），仍检查 gap 并更新 appTotalRecordedSeconds
4.Checkpoint 不被跳过 — isLikelyHistoricalCatchUp 现在只对 reminder 生效。之前 reminder 更新 notificationBaseline 后，checkpoint 在几秒内触发会被误判为"历史追赶"而跳过，这就是你看到 reminder 有通知但没有数据的原因
