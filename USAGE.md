# 豆包工作原生任务通知器 4.4

这是一个独立的 macOS 菜单栏应用。它监听豆包工作写入本机的原生运行信号，在回复完成或明确等待用户操作时发送系统通知。全程不使用 DOM、CDP、Renderer 注入、MutationObserver、辅助功能树或页面按钮/文案/loading 推断。

## 4.4 修复

### 1. ask、授权、接管即时通知

主要等待信号改为豆包 Saman 原生日志中的 toolcall 生命周期：

```text
toolcall status=received                  → 立即进入等待并通知
toolcall phase=execution_settled/success → 立即解除该 interaction 等待
```

支持：

```text
interaction.ask
interaction.authorize_folder
interaction.request_action
```

兼容对应的下划线名称。日志中的 `sandbox_id` 会先通过带 `conversation_id` 的原生记录建立映射，因此当前会话与后台会话都能正确归属；`tcid` 与 trajectory 的 `tool_call_id`一致，用于精确解除等待。

聊天 IndexedDB WAL 只作为已验证的结构化授权卡片冗余源：解析完整 LevelDB physical/logical record、WriteBatch 和完整 value，只接受 `schema_payload → tool_call` 结构，不再使用 UUID 邻域、`dbx_ic`、`required`、`capability` 等裸字符串推断。

### 2. trajectory 整批两阶段处理

每次新增 trajectory 数据先整批收集 waiting calls 和 tool results：

1. 先解除本批已有结果的 interaction；
2. 再登记本批仍未回答的 waiting call；
3. 同一批已出现 call + result 时不发送等待通知；
4. run 已完成后，迟到 trajectory 不得补发旧等待；
5. Saman、IndexedDB、trajectory 按同一 run 和交互类型跨源合并，避免重复通知。

### 3. 过滤新建/切换会话的页面同步 blocker

`local-task-conversation` blocker 只作为候选运行边界。紧邻以下组合的 blocker 被标记为页面同步并完全忽略：

```text
chat_page_navigate_event
presentation_sync_*
```

因此新建或切换会话时的约 100ms 展示同步 blocker 不会创建任务 run，也不会在发送消息后立即误报完成。真实任务 blocker 仍保留，极简无工具回复继续支持。

## 状态判定

### 回复完成

监听：

```text
~/Library/Application Support/Doubao/sdk_storage/log/saman_*.log
```

真实 `local-task-conversation` blocker：

```text
Register added blocker   → 本轮开始/仍在运行
Unregister blocker       → blocker 结束
```

同一会话最后一个真实 blocker 注销，且没有未完成 interaction 时，经合并窗口发送“当前对话轮次回复完成”。

### 等待用户

主要来源同样是 Saman 原生日志的 toolcall `received/settled`。trajectory 作为精确持久化对账与漏报兜底：

```text
~/Library/Application Support/Doubao/<Profile>/.doubao/
  agent_mode/workspace/.sessions/<conversation_id>/
  agents/<main-agent>/system/trajectory.jsonl
```

等待通知正文为“等待你确认或提供信息”。等待是可恢复中间状态；每个 `tool_call_id/tcid` 独立解除，最后仍会发送一次完成通知。

### 通知标题

标题从豆包聊天 IndexedDB 的 conversation-list-data 真实 `name` 字段读取；发送前会刷新。暂不可读时显示“豆包工作”，不会用首条问题或任务摘要冒充标题。

## 安装

1. 解压 `DoubaoReplyNotifier-4.4.0.zip`。
2. 双击 `Install.command`。
3. 首次运行时允许“豆包回复通知”发送通知。

包内是预编译通用 App，支持 Intel（x86_64）和 Apple Silicon（arm64），接收方不需要安装 Xcode 或 Swift。安装位置：

```text
~/Applications/Doubao Reply Notifier.app
```

安装后会注册为登录项，并在菜单栏显示铃铛图标。菜单中可手动发送测试通知。

## 隐私

- 运行日志只解析 conversation ID、sandbox ID、tool 名称、tcid、blocker 生命周期和页面同步事件名。
- trajectory 只解析角色、交互工具名称、调用 ID和结果关联。
- IndexedDB WAL 只解析 LevelDB 结构、结构化 tool_call ID 和本地会话 ID。
- 不读取 Cookie、令牌或网络请求；不保存待办正文；所有数据仅在本机处理。

## 状态与幂等

状态文件：

```text
~/Library/Application Support/DoubaoReplyNotifier/state.json
```

- 状态格式版本 8。
- 运行日志、trajectory 与 WAL 使用持久化偏移。
- 最近 7 天、最多 4000 个事件用于幂等。
- 初次安装与升级会基线化历史记录，不重放旧等待或终态。
- 升级过程中仍活跃的真实 blocker 会从日志尾部恢复。

## 覆盖范围

覆盖本机豆包工作的当前和后台 Agent 会话，包括极简无工具回复、选择问题、补充内容、文件夹授权和浏览器/应用接管。

不覆盖网页端、手机端、另一台设备的独立任务，以及完全没有本地 Agent 原生运行信号的普通聊天。豆包未来版本若改变 Saman 日志格式或位置，需更新适配。

## 测试

```bash
node tests/test-trajectory.mjs
node tests/test-activation-router.mjs
node tests/test-native-contract.mjs
swiftc tests/test-marker-bridging.swift -o /tmp/test-marker-bridging && /tmp/test-marker-bridging
swiftc Sources/ConversationTitleReader.swift tests/test-title-reader.swift -o /tmp/test-title-reader && /tmp/test-title-reader
swiftc Sources/IndexedDBInteractionReader.swift tests/test-indexeddb-reader.swift -o /tmp/test-indexeddb-reader
/tmp/test-indexeddb-reader tests/fixtures/real-authorize-wal.bin
bash tests/test-native-toolcall.sh "Doubao Reply Notifier.app/Contents/MacOS/DoubaoReplyNotifier"
bash tests/test-inflight-recovery.sh "Doubao Reply Notifier.app/Contents/MacOS/DoubaoReplyNotifier"
bash tests/test-wait-active-blocker.sh "Doubao Reply Notifier.app/Contents/MacOS/DoubaoReplyNotifier"
bash tests/test-integration.sh "Doubao Reply Notifier.app/Contents/MacOS/DoubaoReplyNotifier"
```

集成测试覆盖：三类原生交互即时进入/解除、后台会话映射、真实 WAL 授权结构、页面同步误完成、同批 call/result、完成后的迟到 waiting、连续交互、blocker 活跃、并发 blocker、运行中升级恢复、重启和历史不重放。

## 卸载

双击或执行：

```bash
./uninstall.sh
```

卸载只移除通知器应用及其状态，不修改豆包工作数据。
