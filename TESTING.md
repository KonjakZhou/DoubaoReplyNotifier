# 架构重构测试方案（v4.5）

## 目标

验证统一事件模型、事件归属 Resolver 与会话状态机在正常、乱序、缺失映射、并发、重启和升级条件下均不会漏发等待通知、重复通知或提前发送完成通知。

## 测试分层

### 1. 静态契约

命令：

```bash
node tests/test-native-contract.mjs
```

检查项：

- 四类数据源仍存在：Saman blocker、Saman toolcall、trajectory、IndexedDB WAL。
- 所有来源统一生成 `CanonicalEvent`。
- 所有业务状态变更只经过 `applyCanonicalEvent`。
- Resolver 状态被持久化。
- 未映射原生 interaction 不会被静默丢弃。
- 不重新引入 DOM、CDP、辅助功能推断或本地 Renderer 事件服务。

### 2. Resolver 纯单元测试

命令：

```bash
swiftc Sources/EventArchitecture.swift tests/test-event-resolver.swift -o /tmp/test-event-resolver
/tmp/test-event-resolver
```

覆盖 12 类场景：

1. 已知 sandbox 映射时即时归属。
2. `received` 早于 sandbox 映射，映射晚到后只回放一次。
3. 映射永不到时由 trajectory 的 `tool_call_id` 完成归属。
4. 单活跃 run 临时归属后，trajectory 确认同会话时不重复通知。
5. 临时归属错误时，先解除旧会话再迁移到权威会话。
6. 映射缺失但 `settled` 到达时，立即解除临时等待且不产生陈旧通知。
7. 同批 call + result 不发送已过时的等待通知。
8. 多 sandbox、多会话严格隔离。
9. Resolver 状态编码、解码后仍可回放。
10. settled 与 unresolved 使用不同 TTL 清理。
11. `settled` 早于 `received` 时，用短期 tombstone 抑制迟到的陈旧等待。
12. 多活跃 run 时不猜测归属，只对事发时的候选会话施加短期完成门禁。

### 3. 真实进程回放

命令：

```bash
bash tests/test-unmapped-native.sh "<签名 App 内的 DoubaoReplyNotifier 二进制>"
```

复现本次真实缺陷：

1. 建立唯一活跃 blocker。
2. 写入一个没有 `conversation_id → sandbox_id` 映射的 `interaction.ask received`。
3. 断言立即登记等待通知，并在 Resolver 中记录可校正的临时归属。
4. 注销 blocker，断言等待未解除前不能发送完成通知。
5. 写入相同 `tcid` 的 `execution_settled`，仍不提供映射。
6. 断言等待解除、完成通知恰好发送一次、状态升级为 v9。

### 4. 旧行为回归

必须全部运行：

```bash
node tests/test-trajectory.mjs
node tests/test-activation-router.mjs
node tests/test-native-contract.mjs
swiftc tests/test-marker-bridging.swift -o /tmp/test-marker-bridging && /tmp/test-marker-bridging
swiftc Sources/ConversationTitleReader.swift tests/test-title-reader.swift -o /tmp/test-title-reader && /tmp/test-title-reader
swiftc Sources/IndexedDBInteractionReader.swift tests/test-indexeddb-reader.swift -o /tmp/test-indexeddb-reader
/tmp/test-indexeddb-reader tests/fixtures/real-authorize-wal.bin
bash tests/test-native-toolcall.sh "<binary>"
bash tests/test-inflight-recovery.sh "<binary>"
bash tests/test-wait-active-blocker.sh "<binary>"
bash tests/test-wait-without-active-run.sh "<binary>"
bash tests/test-unmapped-native.sh "<binary>"
bash tests/test-integration.sh "<binary>"
```

继续覆盖：

- 三类交互即时等待与解除。
- 后台会话显式 sandbox 映射。
- 运行中升级恢复与历史不重放。
- blocker 活跃期间禁止完成。
- 页面同步边界被忽略后，明确归属的实时等待仍可建立轮次并通知。
- 连续 interaction、并发 blocker。
- 页面同步 blocker 过滤。
- 同批 call/result 和 run 终态后的迟到 waiting。
- 通知点击回跳只激活豆包主应用。

## 安装验证

1. 使用 `install.sh` 从源码编译临时签名 App。
2. 只有编译和签名校验成功后才停止旧版本并替换安装目录。
3. 校验版本为 4.5.1、build 10。
4. 校验进程唯一运行。
5. 校验旧 v8 状态自动解码并迁移为 v9。
6. 校验安装二进制哈希与本次构建产物一致。

## 验收标准

- 全部命令退出码为 0。
- Resolver 单测 12/12 通过。
- 无映射真实回放中：等待 1 次、提前完成 0 次、settled 后完成 1 次。
- 旧回归测试全部保持通过。
- 没有新增 Swift 编译警告。
- Git 差异检查无空白错误。
