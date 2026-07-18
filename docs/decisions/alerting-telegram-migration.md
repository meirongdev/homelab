# Alerting Delivery: Gotify Bridge → Native Telegram

> Date: 2026-07-18
> Decision status: Completed

## Scope

记录 homelab Alertmanager 的告警投递从 `alertmanager-gotify-bridge`（第三方 bridge）迁移到 Alertmanager 原生 `telegramConfigs` 的结论，含评估过但放弃的替代方案。

## Problem

`alertmanager-gotify-bridge`（druggeri/alertmanager_gotify_bridge，`ghcr.io/druggeri/alertmanager_gotify_bridge` digest-pinned）50 天内重启 66 次。根因是上游代码的并发 bug：

```go
var metrics = make(map[string]int)   // 全局，无 mutex
```

`handleCall`（处理每个 Alertmanager webhook 的函数）对该 map 做 `metrics["requests_received"]++` 等自增，无锁保护。Go 运行时对并发写 map **强制终止进程**（`fatal error: concurrent map writes`，不是 panic，`recover()` 拦不住）。触发条件：Alertmanager 同时投递 ≥2 个 webhook。上游仓库 `master` 分支至今仍是这段无锁代码，判定无维护。

## Alternatives Evaluated

| 方案 | 结论 | 备注 |
|------|------|------|
| **自建补丁镜像**（fork 上游加 `sync.Mutex`） | 放弃 | 需自己维护一个 fork + CI，长期负担 |
| **`ocimea/gotify-alertmanager-plugin`**（Gotify 原生插件） | 放弃（但已验证技术可行） | 见下 |
| **`crisidev/alertmanager-gotify-relay`** | 放弃 | 5 commits、0 star、无发布镜像、无优先级映射，比原 bridge 更没维护 |
| **Alertmanager 原生 `telegramConfigs`** | **采用** | 零中间件，Alertmanager v0.33 内置支持 |

### Gotify 原生插件：verified working，仍然放弃

`ocimea/gotify-alertmanager-plugin` 是编译进 Gotify server 的 Go plugin（`.so`），不是独立进程，理论上没有 bridge 那类进程崩溃面。**实际针对 oracle-k3s 当时运行的 Gotify v2.9.1（arm64）用 `gotify/build:1.26.0-linux-arm64` 交叉编译容器构建成功**，产出 39MB 的 arm64 `.so`，证明这条路技术可行。

放弃原因：
1. **Go plugin ABI 与 Gotify server 版本强绑定**——每次 Gotify 升级（哪怕 patch 版本）插件大概率需要针对新版本重新编译才能加载，长期是持续的运维负担，而不是一次性成本。
2. **要求 bot 拿群 admin + Manage Topics 权限**，权限面比"发消息"大。
3. 半维护项目（commit 频率低），且插件把 severity 映射成 emoji 前缀而非 Gotify 数字优先级（一开始误判为功能缺失，实际读源码后确认它设了 `Priority: 10/7/0`，但仍是相对小众的实现，遇到问题难找到帮助）。

原生 Telegram 路线没有这两个负担：Alertmanager 本身维护，Telegram Bot API 长期稳定，不随 Gotify 版本变化。

## Decision

1. homelab Alertmanager 告警改用原生 `telegramConfigs`，投到群 **MatthewDaily** 的「🚨 Homelab 告警」forum topic（`chatID: -1003981213530`，`messageThreadID: 2`）。
2. Bot token 走 Vault（`secret/homelab/telegram` → ESO → k8s Secret `monitoring/alertmanager-telegram`），与仓库"密钥全走 Vault+ESO"的约定一致。
3. 删除 `alertmanager-gotify-bridge` 全部资源（`k8s/helm/manifests/gotify.yaml`：Deployment/Service/ExternalSecret），从 `personal-services` App 的 include glob 移除。
4. **Gotify 本体不受影响，继续运行**（oracle-k3s，`notify.meirong.dev`）——它只服务 Falco（falcosidekick 原生推送，见 `reference/security.md` §8.5），这条链路从未经过坏掉的 bridge，因此本次迁移零影响。

## Forum Topic 设计（为后续扩展铺路）

Telegram Forum Topics 只存在于**超级群**，私聊没有。设计为按消息来源分话题，同群同 bot：

- 群需先 `is_forum: true`（群设置里开 Topics，自动升级为超级群，chat ID 变为负数的 `-100...` 形式，旧的普通群 ID 作废）。
- Bot 需群管理员 + `can_manage_topics` 权限，才能用 `createForumTopic` API 建话题（建话题直接返回 `message_thread_id`，无需在 Telegram UI 手动建）。
- 当前只有一个话题：「🚨 Homelab 告警」(`thread_id=2`)。以后接入 RSS/阅读推送等新来源时，同一个 bot、同一个群、新建一个话题即可（例如 Miniflux 的 Telegram Bot 集成原生支持指定 Topic ID）。

## Verification

- `alertmanager_notifications_total{integration="telegram"}` 递增、`..._failed_total{integration="telegram"}` 恒为 0（发了 critical 测试告警 + resolve，全链路含话题路由都验证过）。
- `monitoring` ns 内 `alertmanager-gotify-bridge` 的 Deployment/Service/ExternalSecret 已被 ArgoCD prune，无残留。

## Consequences

- 新增/改任何 homelab 告警路由，改 `k8s/helm/manifests/alertmanager-config.yaml` 里的 `telegramConfigs`（`chatID`/`messageThreadID`/`message` 模板），不再有 bridge 这层可调。
- 若未来 Gotify 完全退役（目前仍为 Falco 服务，不建议现在做），本文档的"零影响"结论会需要重新确认 Falco 侧的 falcosidekick 配置。
- 相关：`CONVENTIONS.md` GitOps/Alerting 段、`reference/security.md` §9。
