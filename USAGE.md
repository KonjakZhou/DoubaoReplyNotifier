# 豆包工作原生任务通知器 4.1

这是一个独立的 macOS 菜单栏应用。它直接监听豆包工作在本机写入的原生运行信号，在回复完成或明确等待用户操作时发送系统通知。

## 4.1 新增：点击通知回到豆包

通知器发出的每条通知都带有受控 action 标记。点击通知（默认点击）或通知上的“打开豆包”按钮时：

- 豆包主应用（Bundle ID `com.bot.pc.doubao`）已在运行：按 Bundle ID 找到并激活，同时激活其所有窗口；
- 豆包主应用未运行：通过 NSWorkspace 按 Bundle ID 定位主应用并启动；
- 划掉通知（dismiss）或收到未知 action：不做任何动作；
- 定位失败、Bundle ID 校验不通过、或解析结果指向 `*.browser` 辅助进程：拒绝启动，并把结构化错误写入
  `~/Library/Application Support/DoubaoReplyNotifier/activation-errors.log`；
- 全程不使用 CDP、DOM、Renderer、辅助功能 API，也不硬编码任何会话/深链 URL。

> 注意：本插件只激活/启动豆包主应用 `com.bot.pc.doubao`，绝不会启动 `com.bot.pc.doubao.browser`，也不修改 `/Applications/Doubao.app`。

## 4.0 修复内容

- 修复“测试消息”等极简、无工具回复漏通知：回复完成不再依赖主 Agent 是否写入最终 assistant 轨迹。
- 覆盖当前与后台会话：事件按 conversation ID 归属，不依赖当前打开页面。
- 消除完成后误报等待：普通正文中的“请确认”“等待你”等文字完全不参与状态判断。
- 通知标题直接读取豆包会话列表 IndexedDB 中与 conversation ID 对应的真实 `name`，不再使用 assignment 的首条需求摘要。
- 同一轮多个 blocker 归并为一个运行实例，最后一个 blocker 结束后才通知。
- 使用持久化事件账本和稳定通知 identifier，重复日志、应用重启不会重复通知。
- 安装或升级发生在任务运行中时，会从已有日志恢复仍活跃的 blocker，不重放已结束历史。

## 原生双源状态判定

### 回复完成：豆包主进程运行日志

通知器监听：

```text
~/Library/Application Support/Doubao/sdk_storage/log/saman_*.log
```

以 `scope_id=local-task-conversation` 的 blocker 生命周期作为运行边界：

```text
Register added blocker   → 本轮开始/仍在运行
Unregister blocker       → blocker 结束
```

同一会话最后一个 blocker 注销后进入 3 秒合并窗口；窗口内若没有明确的等待用户事件，则发送：

```text
当前对话轮次回复完成
```

### 等待用户：主 Agent 明确交互工具

通知器同时增量监听所有 Profile 下的主 Agent 轨迹：

```text
~/Library/Application Support/Doubao/<Profile>/.doubao/
  agent_mode/workspace/.sessions/<conversation_id>/
  agents/<main-agent>/system/trajectory.jsonl
```

仅当主 Agent 明确调用以下交互工具时发送等待通知：

```text
interaction.ask
interaction.request_action
interaction.authorize_folder
```

兼容对应下划线名称。通知正文为：

```text
等待你确认或提供信息
```

等待事件是该运行实例的终态；之后到来的注销日志不会再补发完成通知。

### 通知标题：豆包会话名称

通知标题从各 Profile 的豆包聊天 IndexedDB 中按 conversation ID 读取真实 `name` 字段：

```text
~/Library/Application Support/Doubao/<Profile>/IndexedDB/
  chrome_doubao-chat_0.indexeddb.leveldb
```

每次发送通知前会重新读取最新记录，因此用户重命名对话后，新通知会采用新名称。若标题暂时不可读取，显示“豆包工作”，不会用首条提问或任务摘要冒充会话名称。

## 已完全移除

- DOM、按钮、文案、侧边栏 loading、朗读控件等页面推断；
- Renderer JavaScript 注入和 MutationObserver；
- CDP 调试端口；
- 辅助功能树；
- 本地 HTTP 事件服务。

插件不需要辅助功能权限，也不要求豆包会话处于当前页面。

## 安装

1. 解压 `DoubaoReplyNotifier-4.0.0.zip`。
2. 双击 `Install.command`。
3. 首次运行时允许“豆包回复通知”发送通知。

安装器复制包内预编译应用，不要求接收方安装 Xcode 或 Swift。预编译应用支持 Intel（x86_64）和 Apple 芯片（arm64）。安装位置：

```text
~/Applications/Doubao Reply Notifier.app
```

安装后应用注册为 macOS 登录项，并在菜单栏显示铃铛图标。菜单中可手动选择“发送测试通知”。

如果 macOS 阻止打开，可在“系统设置 → 隐私与安全性”中选择仍要打开。

## 隐私

- 运行日志只解析 blocker 类型、conversation ID、序号和生命周期，不读取回复正文。
- Agent 轨迹只解析角色和交互工具名称，不把回答正文写入状态文件。
- 不读取 Cookie、令牌或网络请求。
- 所有数据仅在本机处理。

## 幂等与状态恢复

状态保存在：

```text
~/Library/Application Support/DoubaoReplyNotifier/state.json
```

- 日志与轨迹按字节偏移增量读取。
- 完成事件绑定完整 Register 日志哈希，豆包重启后 sequence 复用不会误去重。
- 最近 7 天、最多 4000 个事件用于持久化幂等。
- 首次安装不重放历史终态，但会恢复日志末尾仍未结束的 blocker。

## 覆盖范围与限制

覆盖本机豆包工作的当前和后台 Agent 会话，包括极简无工具回复。

不覆盖：

- 网页端、手机端或另一台设备独立运行的任务；
- 完全没有本地 `local-task-conversation` blocker 的非 Agent 普通聊天；
- 豆包未来版本若改变 Saman 日志位置或 `exit_intercept` 格式，可能需要更新适配。

## 测试

```bash
node tests/test-trajectory.mjs
node tests/test-activation-router.mjs
node tests/test-native-contract.mjs
bash -n install.sh
bash tests/test-integration.sh "Doubao Reply Notifier.app/Contents/MacOS/DoubaoReplyNotifier"
```

- `test-trajectory.mjs`：等待用户信号的纯逻辑单测。
- `test-activation-router.mjs`：点击通知路由与激活目标校验的纯逻辑单测（默认点击/显式 activate → 激活；dismiss/未知 → 忽略；browser 变体拒绝；completion 恰好一次）。
- `test-native-contract.mjs`：源码契约检查，禁止 CDP/DOM/Renderer/辅助功能/硬编码深链，禁止启动 browser 变体。
- 集成测试覆盖：历史不重放、极简回复完成、普通文字防误报、等待覆盖完成、重复注销、并发 blocker 逆序注销和重启幂等。

## 卸载

双击或执行：

```bash
./uninstall.sh
```

卸载会移除应用和通知器自己的状态文件，不修改豆包工作数据。
