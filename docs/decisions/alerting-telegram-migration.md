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
4. **Gotify 本体当时不受影响，继续运行**（oracle-k3s，`notify.meirong.dev`）——它只服务 Falco（falcosidekick 原生推送，见 `reference/security.md` §8.5），这条链路从未经过坏掉的 bridge，因此本次迁移零影响。（**2026-07 后续更新**：Gotify 已彻底退役，见下方章节。）

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
- 相关：`CONVENTIONS.md` GitOps/Alerting 段、`reference/security.md` §9。

---

## 2026-07 更新：Gotify 彻底退役

上面第 4 点提到的"若未来 Gotify 完全退役"在同一批工作里就发生了。Gotify 当时有三个活跃消费者（不是零影响可以直接删），逐一处理：

### 消费者盘点与处理

| 消费者 | 处理方式 | 决策 |
|--------|----------|------|
| Falco → Falcosidekick → Gotify（安全告警） | 迁移到 falcosidekick **原生 telegram output**，併入「🚨 Homelab 告警」话题 | 用户选择：合併话题（不新建独立话题） |
| Uptime Kuma dead-man's switch（homelab 整机失联报警） | 迁移到 `uptime_kuma_api` 的 **`NotificationType.TELEGRAM`**，同样併入「🚨 Homelab 告警」话题 | 用户选择：合併话题——homelab 真挂时这会是该话题唯一的消息，信号反而更清楚 |
| Redpanda Connect → KaraKeep（telegram 标签书签）→ Gotify（阅读推送） | **直接砍掉**该管道（pipeline 2），不迁移 | 用户选择：不需要；且该管道的 Gotify token 早已 401 失效，推送本就静默失败多时 |

### 技术要点

- **falcosidekick 原生支持 Telegram**（chart `falcosecurity/falco` 内嵌的 falcosidekick 子 chart，`config.telegram.{token,chatid,messagethreadid,minimumpriority,checkcert}`），且 `messagethreadid` 字段直接支持 forum topic——不需要额外 bridge。机制与旧 Gotify 配置一致：`existingSecret` 只覆盖 `TELEGRAM_TOKEN` 一个键，与其余明文 `telegram.*` 键通过两个 `envFrom.secretRef` 叠加生效（chart `secrets.yaml` 模板决定，后者覆盖同名键）。
- **`uptime_kuma_api`（Python 库，provisioner 脚本已在用）原生支持 `NotificationType.TELEGRAM`**，字段 `telegramBotToken`/`telegramChatID`/`telegramMessageThreadID`，与已用的 `NotificationType.GOTIFY` 同库同版本（1.2.1），迁移只是换字段名，无需升级依赖。
- 两条链路（Alertmanager `telegramConfigs` 与 falcosidekick 原生 output）都直连 Telegram Bot API，**互相独立、代码路径不同**，只是共用同一个 bot + 同一个话题。

### Bot token 复用

Falco 和 Uptime Kuma 都改为跨集群读取 **`secret/homelab/telegram`**（与 homelab Alertmanager 同一个 Vault 路径/同一个 bot token），沿用 zitadel 已验证过的跨集群 Vault 读取模式（oracle ClusterSecretStore 经 Tailscale 连回 homelab Vault）。

### Gotify 本体彻底删除

处理完三个消费者后，删除：
- `cloud/oracle/manifests/gotify/gotify.yaml`（Deployment/PVC/Service/ExternalSecret）+ 从 `kustomization.yaml` 移除
- `notify.meirong.dev` 的 HTTPRoute（`base/gateway.yaml`）
- Homepage 书签、`slos.yaml` 的 `gotify-availability` SLO、oracle backup 脚本的 `gotify-data` 备份模式
- Vault 残留：`secret/homelab/gotify`（整个删除）、`secret/oracle-k3s/falco`（整个删除）、`secret/oracle-k3s/redpanda-connect` 的 `gotify_token`/`gotify_url` 两个键（patch 移除，保留仍在用的 `karakeep_api_key`）
- PVC `gotify-data`（`Prune=false` 保护，需手动 `kubectl delete`，7.7MB 纯推送历史 sqlite，无需保留）

**⚠️ 未完成**：`cloud/oracle/cloudflare/terraform.tfvars` 的 `notify` ingress rule 条目已从配置移除，但 `CLOUDFLARE_API_TOKEN` 当时失效，未能 `terraform apply`——DNS/tunnel 路由的实际摘除需要拿到有效 token 后手动 `cd cloud/oracle/cloudflare && just apply`。

### Verification（追加）

- falcosidekick 渲染出的 `TELEGRAM_CHATID`/`TELEGRAM_MESSAGE_THREAD_ID`/`TELEGRAM_MINIMUMPRIORITY` base64 解码值均正确。
- 所有改动的 manifest 均通过 `kubectl apply --dry-run=server` 校验（oracle-k3s / homelab 两个 context）。
- provisioner.py 内嵌脚本 `py_compile` 语法校验通过。
- Vault 读写：`secret/homelab/gotify`、`secret/oracle-k3s/falco` 确认已不存在；`secret/oracle-k3s/redpanda-connect` 确认只剩 `karakeep_api_key`。
