# 豆包工作原生任务通知器 4.6.0

这是一个独立的 macOS 菜单栏应用。它监听豆包工作写入本机的原生运行信号，在回复完成或明确等待用户操作时发送系统通知。全程不使用 DOM、CDP、Renderer 注入、MutationObserver 或辅助功能树；权限审阅通过豆包工作原生日志中的审阅页面生命周期识别，不操作页面。

## 4.6 权限审阅通知修复

当豆包工作显示“拒绝 / 允许一次”的本地工具执行审阅时，通知器现在会在审阅界面出现时立即建立等待状态并发送通知，不再等待用户允许后才可能写入的 IndexedDB 授权记录。

* 同一次审阅的两个操作按钮合并为一个事件；
* 页面重绘和通知器重启不会重复提醒；
* 工具获准开始、用户拒绝后 Agent 恢复，或后续 Agent 活动会解除等待；
* 已处理审阅对应的迟到 IndexedDB 授权记录只用于关联，不再二次通知；
* 普通页面导航、聊天文本和权限模式诊断不会触发审阅通知。

## 4.5.1 等待通知修复

当页面切换产生的短暂同步边界被忽略后，如果随后出现一个已经明确归属到对话的实时用户操作请求，该请求现在会自行建立本轮等待状态并立即通知用户。相同请求重复到达时不会重复提醒；请求结束后仍只发送一次完成通知。历史记录中的迟到请求不会自行建立新轮次。

## 4.5 架构重构

Saman 权限审阅、blocker、toolcall、trajectory 和 IndexedDB WAL 现在分别作为数据源适配器，统一生成 `CanonicalEvent`。所有运行、等待、恢复和完成状态只通过一个会话状态机入口处理。

新增 `EventResolver` 负责 `sandbox_id`、`tcid/tool_call_id` 与 `conversation_id` 的归属：

* 已有可靠 sandbox 映射时即时通知；
* 新 sandbox 缺少映射、且只有一个活跃 run 时，先做可校正的临时归属；
* trajectory 到达后确认或迁移到权威会话；
* 多个活跃 run 时不猜测归属，只对候选会话施加短期完成门禁；
* `settled` 早于 `received` 时，用短期 tombstone 抑制迟到的陈旧等待；
* Resolver 状态持久化，重启后仍可继续对账。

因此等待事件不会因新 sandbox 缺少映射而静默丢失，也不会在等待未解除时误发完成通知。

## 4.4 修复

### 1. ask、授权、接管即时通知

主要等待信号改为豆包 Saman 原生日志中的 toolcall 生命周期：



```
toolcall status=received                  → 立即进入等待并通知
toolcall phase=execution_settled/success → 立即解除该 interaction 等待
```

支持：



```
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

### 3. 过滤新建 / 切换会话的页面同步 blocker

`local-task-conversation` blocker 只作为候选运行边界。紧邻以下组合的 blocker 被标记为页面同步并完全忽略：



```
chat_page_navigate_event
presentation_sync_*
```

因此新建或切换会话时的约 100ms 展示同步 blocker 不会创建任务 run，也不会在发送消息后立即误报完成。真实任务 blocker 仍保留，极简无工具回复继续支持。

## 状态判定

### 回复完成

监听：



```
~/Library/Application Support/Doubao/sdk_storage/log/saman_*.log
```

真实 `local-task-conversation` blocker：



```
Register added blocker   → 本轮开始/仍在运行
Unregister blocker       → blocker 结束
```

同一会话最后一个真实 blocker 注销，且没有未完成 interaction 时，经合并窗口发送 “当前对话轮次回复完成”。

### 等待用户

主要来源同样是 Saman 原生日志的 toolcall `received/settled`。trajectory 作为精确持久化对账与漏报兜底：



```
~/Library/Application Support/Doubao/<Profile>/.doubao/
  agent_mode/workspace/.sessions/<conversation_id>/
  agents/<main-agent>/system/trajectory.jsonl
```

等待通知正文为 “等待你确认或提供信息”。等待是可恢复中间状态；每个 `tool_call_id/tcid` 独立解除，最后仍会发送一次完成通知。

### 通知标题

标题从豆包聊天 IndexedDB 的 conversation-list-data 真实 `name` 字段读取；发送前会刷新。暂不可读时显示 “豆包工作”，不会用首条问题或任务摘要冒充标题。

## 安装



1. 从 Git 仓库 clone 或下载源码。

2. 双击 `Install.command`，或在终端执行 `./install.sh`。

3. 安装脚本会先在临时目录从源码编译并验证签名，成功后才替换旧版本。

4. 首次运行时允许 “豆包回复通知” 发送通知。

源码安装需要 macOS 13 或以上及 Apple Command Line Tools；脚本找不到 Swift 编译器时会提示执行 `xcode-select --install`。安装位置：



```
~/Applications/Doubao Reply Notifier.app
```

安装后会注册为登录项，并在菜单栏显示铃铛图标。菜单中可手动发送测试通知。

## 隐私



* 运行日志只解析 conversation ID、sandbox ID、tool 名称、tcid、blocker 生命周期和页面同步事件名。

* trajectory 只解析角色、交互工具名称、调用 ID 和结果关联。

* IndexedDB WAL 只解析 LevelDB 结构、结构化 tool\_call ID 和本地会话 ID。

* 不读取 Cookie、令牌或网络请求；不保存待办正文；所有数据仅在本机处理。

## 状态与幂等

状态文件：



```
~/Library/Application Support/DoubaoReplyNotifier/state.json
```



* 状态格式版本 10；新增权限审阅与后续工具调用的短期关联记录，并继续持久化 Resolver 状态和已结束 interaction tombstone。

* 运行日志、trajectory 与 WAL 使用持久化偏移。

* 最近 7 天、最多 4000 个事件用于幂等。

* 初次安装与升级会基线化历史记录，不重放旧等待或终态。

* 升级过程中仍活跃的真实 blocker 会从日志尾部恢复。

## 覆盖范围

覆盖本机豆包工作的当前和后台 Agent 会话，包括极简无工具回复、选择问题、补充内容、文件夹授权和浏览器 / 应用接管。

不覆盖网页端、手机端、另一台设备的独立任务，以及完全没有本地 Agent 原生运行信号的普通聊天。豆包未来版本若改变 Saman 日志格式或位置，需更新适配。

## 测试



```
node tests/test-trajectory.mjs
node tests/test-activation-router.mjs
node tests/test-native-contract.mjs
swiftc tests/test-marker-bridging.swift -o /tmp/test-marker-bridging && /tmp/test-marker-bridging
swiftc Sources/ConversationTitleReader.swift tests/test-title-reader.swift -o /tmp/test-title-reader && /tmp/test-title-reader
swiftc Sources/IndexedDBInteractionReader.swift tests/test-indexeddb-reader.swift -o /tmp/test-indexeddb-reader
/tmp/test-indexeddb-reader tests/fixtures/real-authorize-wal.bin
swiftc Sources/PermissionReviewSource.swift tests/test-permission-review-source.swift -o /tmp/test-permission-review-source && /tmp/test-permission-review-source
swiftc Sources/EventArchitecture.swift tests/test-event-resolver.swift -o /tmp/test-event-resolver && /tmp/test-event-resolver
bash tests/test-permission-review.sh "<签名 App 内的 DoubaoReplyNotifier 二进制>"
bash tests/test-native-toolcall.sh "<签名 App 内的 DoubaoReplyNotifier 二进制>"
bash tests/test-inflight-recovery.sh "<签名 App 内的 DoubaoReplyNotifier 二进制>"
bash tests/test-wait-active-blocker.sh "<签名 App 内的 DoubaoReplyNotifier 二进制>"
bash tests/test-wait-without-active-run.sh "<签名 App 内的 DoubaoReplyNotifier 二进制>"
bash tests/test-unmapped-native.sh "<签名 App 内的 DoubaoReplyNotifier 二进制>"
bash tests/test-integration.sh "<签名 App 内的 DoubaoReplyNotifier 二进制>"
```

完整方案见 `TESTING.md`。集成测试覆盖：统一事件模型、权限审阅双按钮合并与重启恢复、12 类 Resolver 时序、新 sandbox 无映射、三类原生交互即时进入 / 解除、后台会话映射、真实 WAL 授权结构、页面同步误完成、同批 call/result、完成后的迟到 waiting、连续交互、blocker 活跃、并发 blocker、运行中升级恢复、重启和历史不重放。

## 卸载

双击或执行：



```
./uninstall.sh
```

卸载只移除通知器应用及其状态，不修改豆包工作数据。