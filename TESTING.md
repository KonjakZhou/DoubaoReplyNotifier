# 架构重构测试方案（v4.7.2）

## 目标

验证统一事件模型、事件归属 Resolver 与会话状态机在正常、乱序、缺失映射、并发、重启和升级条件下均不会漏发等待通知、重复通知或提前发送完成通知。

## 端到端验收范围

端到端测试样例以 `AGENT-E2E-TEST-GUIDE.md` 为准，共 17 个场景。“等待请求快速出现并快速结束” 已从端到端验收样例中删除；后续场景已顺延编号：14 为长时间等待后继续、15 为失败后的最终通知、16 为部分完成后的最终通知、17 为点击通知返回豆包。

本次调整仅变更测试文档，不修改插件实现，也不删除已有自动化回归中的同批 call/result、乱序及迟到 waiting 防护测试。端到端结论仍须依据真实系统反馈与用户反馈逐场景记录，自动回归通过不能替代端到端验收。

## 4.7.2 标题专项

新增长度前缀与多层Snappy封装解码回归、畸形压缩与未知前缀拒绝测试。标题用例支持传入本机真实 `real-title-value.bin` 复核完整值；该夹具按 `.gitignore` 保留在本机，不分发。真实数据库同时验证异常对话与原有对话标题；本次不改变通知状态和时序规则。

## 4.7.2 自动启动专项

真实安装后检查 LaunchAgent 服务运行、进程恰好一个、runtime-health.json 的版本/build/PID匹配且 ready=true。再次安装应自动停止旧服务并启动新实例；旧 SMAppService 登录项不再并存。隔离安装必须设置 SKIP_LAUNCH，不能注册真实用户服务。首次通知权限不代替用户授权；服务启动成功也不等于通知展示已验收。

## 4.7.1 修复专项

17 场景正式验收仍暂停于场景 10；专项修复与本次真实反馈见 `artifacts/E2E-REPAIR-RESULTS.md`，不能把自动回归扩展为所有场景通过。

本次增加：完整 LevelDB SST/Snappy/V8 标题读取与权限名称污染防护、v12 标题缓存迁移、客户端来源绑定、旧目标不可用回退、主线程激活、等待通知精确撤销及异步提交竞争处理。扫描周期为 250ms；时间敏感提醒仍受 macOS 展示策略约束，不修改用户系统设置。

## 测试分层

### 1. 静态契约

命令：



```
node tests/test-native-contract.mjs
```

检查项：



* 四类原有数据源仍存在：Saman blocker、Saman toolcall、trajectory、IndexedDB WAL。

* 权限审阅 UI 作为独立实时来源，产生统一 `CanonicalEvent`。

* 所有来源统一生成 `CanonicalEvent`。

* 所有业务状态变更只经过 `applyCanonicalEvent`。

* Resolver 状态被持久化。

* 未映射原生 interaction 不会被静默丢弃。

* 不重新引入 DOM、CDP、辅助功能推断或本地 Renderer 事件服务。

### 2. Resolver 纯单元测试

命令：



```
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

### 3. 权限审阅实时回放

命令：



```
swiftc Sources/PermissionReviewSource.swift tests/test-permission-review-source.swift -o /tmp/test-permission-review-source
/tmp/test-permission-review-source
bash tests/test-permission-review.sh "<签名 App 内的 DoubaoReplyNotifier 二进制>"
```

覆盖：



1. “拒绝 / 允许一次” 两个按钮合并为一个审阅。

2. 审阅显示后立即通知，不依赖工具已经执行。

3. 通知器重启保留等待且不重放通知。

4. 实际工具开始后解除等待并记录短期关联。

5. 审阅 UI 重绘不重复通知。

6. 普通导航及权限模式诊断不产生误报。

### 4. 状态收敛与伪等待回放

命令：



```
bash tests/test-state-convergence.sh "<签名 App 内的 DoubaoReplyNotifier 二进制>"
```

覆盖：



1. blocker 清零后在 500ms 可取消合并窗口内完成，1.6 秒观察窗口内可见完成事件。

2. v10 升级到 v11 时清除旧 `indexeddb.*` 伪等待与权限关联垃圾。

3. 升级时重建运行中 blocker，不保留旧版漏掉的 unregister 状态。

4. 普通工具 `execution_settled` 能按相同调用 ID 清理冗余等待。

5. 未知结构化 IndexedDB 工具不默认归类为 `request_action`。

### 5. 真实进程回放

命令：



```
bash tests/test-unmapped-native.sh "<签名 App 内的 DoubaoReplyNotifier 二进制>"
```

复现本次真实缺陷：



1. 建立唯一活跃 blocker。

2. 写入一个没有 `conversation_id → sandbox_id` 映射的 `interaction.ask received`。

3. 断言立即登记等待通知，并在 Resolver 中记录可校正的临时归属。

4. 注销 blocker，断言等待未解除前不能发送完成通知。

5. 写入相同 `tcid` 的 `execution_settled`，仍不提供映射。

6. 断言等待解除、完成通知恰好发送一次、状态升级为 v12。

### 6. 旧行为回归

必须全部运行：

真实 WAL 用例依赖本机保留、已忽略且取消跟踪的 `tests/fixtures/real-authorize-wal.bin`。仅检出源码时若没有该夹具，必须记为缺少材料，不能用人工排列字段替代，也不能宣称该用例已通过。现场修复与诊断记录亦仅在本机保留；取消跟踪不清除既有提交历史。



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
bash tests/test-state-convergence.sh "<binary>"
bash tests/test-permission-review.sh "<binary>"
bash tests/test-native-toolcall.sh "<binary>"
bash tests/test-inflight-recovery.sh "<binary>"
bash tests/test-wait-active-blocker.sh "<binary>"
bash tests/test-wait-without-active-run.sh "<binary>"
bash tests/test-unmapped-native.sh "<binary>"
bash tests/test-doubaowork-support.sh "<binary>"
bash tests/test-integration.sh "<binary>"
```

继续覆盖：



* 三类交互即时等待与解除。

* 后台会话显式 sandbox 映射。

* 运行中升级恢复与历史不重放。

* blocker 活跃期间禁止完成。

* 页面同步边界被忽略后，明确归属的实时等待仍可建立轮次并通知。

* 连续 interaction、并发 blocker。

* 页面同步 blocker 过滤。

* 同批 call/result 和 run 终态后的迟到 waiting。

* 通知点击回跳只激活豆包主应用。

## 安装验证



1. 使用 `install.sh` 从源码编译临时签名 App。

2. 只有编译和签名校验成功后才停止旧版本并替换安装目录。

3. 校验版本为 4.7.2、build 16。

4. 校验进程唯一运行。

5. 校验 v11 状态自动迁移为 v12，清除旧标题缓存并保留事件账本；更早版本的伪等待清理及 blocker 重建仍保留。

6. 校验安装二进制哈希与本次构建产物一致。

## 验收标准



* 全部命令退出码为 0。

* Resolver 单测 12/12 通过。

* 权限审阅解析与进程回放通过：双按钮 1 次、重启 0 重放、工具启动后解除、重绘 0 重复。

* 状态收敛回放通过：未知工具 0 等待、v10 残留已清除、普通工具 settled 可对账、完成事件在 1.6 秒观察窗口内出现。

* 无映射真实回放中：等待 1 次、提前完成 0 次、settled 后完成 1 次。

* 豆包工作真实路径回放：无 `- Role: main` 的 assignment 仍发现 `.doubaowork` trajectory，读取 `chrome_doubaowork-chat` 标题并完成一次通知事件。

* 真实安装状态同时出现豆包工作 Saman 日志和 `.doubaowork` trajectory 偏移。

* 真实双产品启动：同一 Agent ID /conversation ID 同时存在于旧豆包与豆包工作时，使用 `productBundleID|agentID|conversationID` 复合身份保留全部来源且进程不崩溃。

* 旧回归测试全部保持通过。

* 没有新增 Swift 编译警告。

* Git 差异检查无空白错误。