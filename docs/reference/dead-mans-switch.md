# Dead-man's switch — 目的、链路与覆盖边界

> Last updated: 2026-09-01
> Status: 生效事实
>
> 本文是死人开关的**唯一真相源**：它为什么存在、链路每一跳长什么样、
> 覆盖什么与不覆盖什么、以及怎么验证它真的有效。
> 告警路由的其余部分见 [observability-alerting-slo.md](observability-alerting-slo.md)。
> 两次相关故障：[2026-08-01 oracle DNS](../records/2026-08-01-oracle-k3s-dns-outage.md) ·
> [2026-08-14 失明窗口](../records/2026-08-14-oracle-reboot-loop-and-blind-dead-mans-switch.md)。
>
> ⚠️ 文中所有数值均为 2026-08-14 实测，会漂。判据是机制，不是这些数字。

## 一、为什么需要它

**其它所有告警都是阳性信号：它们要求监控栈本身活着才能响。**
Prometheus 挂了、Alertmanager 崩了、节点没了、网络断了，你收到的是沉默，
而沉默和"一切正常"在 Telegram 里长得一模一样。

死人开关把判据反过来：**对心跳的缺席告警，且报警方与被监控方不共命运。**

- 被监控方：homelab（Prometheus + Alertmanager + 节点 + 出网路径）
- 报警方：oracle-k3s 的 Uptime Kuma，独立集群、独立网络、独立到 Telegram 的路径

homelab 只要还活着就必须每隔几十秒证明一次；一旦停止证明，oracle 替它喊。

⚠️ **「没有消息 = 坏消息」本身并不稀奇**：仓库里另有十来条 `absent()` 规则
（`OracleTelemetryAbsent`、`ClusterMeshMetricsAbsent*`、`ReadlistMetricsAbsent`…）
也是判缺席的。死人开关的独特之处**不在判据，而在判定方的位置**：
那些 `absent()` 规则全部跑在 homelab 自己的 Prometheus 里，homelab 一死它们
连评估都不会发生；死人开关的判定方在 oracle。
不共命运才是它存在的全部理由，这也解释了为什么它一旦与被监控方一起挂掉
（见第四节）就完全归零。

## 二、完整链路（6 跳）

| # | 跳 | 实现 | 这一跳断了会怎样 |
|---|---|---|---|
| 1 | 常燃告警 | homelab Prometheus 内置 `Watchdog` 规则，`expr: vector(1)`（实测 `state=firing health=ok`），按构造永远 firing | 规则没了 → 心跳停 → 正确触发（这正是要检测的）|
| 2 | 路由 | `watchdog` AlertmanagerConfig CRD（`alerts/alertmanager-config.yaml`）：`matchers: alertname=Watchdog`、`groupWait 0s`、`groupInterval 15s`、`repeatInterval 30s` → receiver `watchdog-webhook` | 同上，正确触发 |
| 3 | 出网 | webhook GET `https://status.meirong.dev/api/push/alertmanager-watchdog-homelab?status=up&msg=OK&ping=` | homelab 出网/Cloudflare/隧道断 → 正确触发，但归因会指向 homelab（见覆盖矩阵注） |
| 4 | 入口 | Cloudflare DNS → 隧道 → oracle `oracle-gateway`:80 → HTTPRoute `uptime-kuma`（PathPrefix `/`）→ Service `uptime-kuma:3001`。⚠️ v2 起 `/api/push` 不再需要专用 rule 与 nginx 边车（v1 的端点只收 GET，v2 是 `router.all`） | oracle 网关/入口断 → ☠️ **失明**，见覆盖矩阵 |
| 5 | 判定 | Uptime Kuma push monitor `id=1` "Alertmanager Watchdog"：`interval=60`、`retry_interval=60`、`maxretries=1`、`resend_interval=0`、`active=1` | uptime-kuma 自己下线 → ☠️ **失明且不留痕迹** |
| 6 | 通知 | notification `id=50` "Telegram (dead-man)"（`active=1 is_default=1`，已挂到 monitor 1）→ oracle 直连 `api.telegram.org`，不回经 homelab | 发送失败 → ☠️ **静默**，无任何指标或告警（开放项 2）|

推送 token 与 URL 的对应关系由 `cloud/oracle/manifests/uptime-kuma/provisioner.yaml`
里的常量保证（库不在 `add_monitor` 上暴露 `pushToken`，靠 monkeypatch 注入；
不注入则服务端自生成随机 token，URL 永远对不上、开关静默失效）。

## 三、关键参数各自在防什么

这几个数是耦合的，**改任何一个都要重算另外两个**：

| 参数 | 值 | 作用 |
|---|---|---|
| `repeatInterval`（Alertmanager）| 30s | 心跳发送节奏。**实测到达间隔中位 45.7s**（近 2000 条心跳：min 6.4s，1997 条 <50s），Alertmanager 的重复调度不是精确 30s，别按 30s 算余量 |
| `interval`（monitor）| 60s | 判定窗口。对 45.7s 的中位间隔只剩 ~14s 余量 |
| `maxretries` + `retry_interval` | 1 × 60s | **这才是防误报的那个设置**：超窗口先转 PENDING 而非 DOWN，再等 60s 仍无心跳才 DOWN |

→ **实际报警延迟 ≈ 120s**（最后一条心跳之后），不是 ROADMAP 里那句"60s 窗口"。

实测佐证（库里全部 3 次 DOWN 之一）：2026-08-08 06:21:37 那次缺口 121s，
正常转 DOWN 并恢复。即 121s 会响、而 <120s 的抖动不会：`maxretries=1` 在吸收
推送间隔的抖动，去掉它的话一次延迟推送就会误报。

## 四、☠️ 覆盖矩阵

### 覆盖（会正确报警）

| 故障 | 依据 |
|---|---|
| homelab 节点整机没了 | 心跳源消失 |
| homelab Prometheus / Alertmanager 挂了 | 同上 |
| homelab 出网 / Cloudflare / 隧道断 | 2026-08-01 实录：链路断时 monitor 确实 `No heartbeat in the time window` |
| 告警链路配置被改坏（规则被删、路由被改） | 心跳停即暴露 |

⚠️ 归因注意：第 3 行触发时 homelab 本身可能是好的。
死人开关报的是"心跳没到"，不是"homelab 死了"，两者不等价。

### 不覆盖（☠️ 静默失明）

| 盲区 | 证据 | 现状 |
|---|---|---|
| **接收方与发送方一起挂**（oracle 重启 / uptime-kuma 下线）| 2026-08-13 三次节点重启造成心跳缺口 561s / 546s / 580s，全部远超 120s 阈值，而当天 `important` 翻转数是 0：没转 DOWN、没报警、库里不留痕迹 | 由 `DeadMansSwitchReceiverDown` 从发送侧捞（2026-08-14 加），但只是让失明可见，没有消除它 |
| **uptime-kuma 自己的通知发不出去** | 实测 `/metrics` 返回 401（需 API key），且没有任何采集方在抓它，Prometheus 里查不到任何 uptime-kuma 指标 | ☠️ 开放（2026-08-01 就提出，至今未闭）|
| **oracle 侧 DNS 坏** | 通知配置无自定义 server URL → 走 `api.telegram.org`，发通知也要解析域名 | 2026-08-01 真发生过；当时靠 homelab Alertmanager 的独立 Telegram 链路救场 |

**为什么"失明"比"误报"更难发现**：push monitor 的检查跑在 uptime-kuma 进程内，
它自己下线就没人做检查；重启回来后 ~45s 内新推送已到，看上去"一直 UP"。
数据库里不留任何痕迹，事后翻不出来。

## 五、拓扑取舍

- **接收端为什么在 oracle 而不是 homelab**：避免共命运。放 homelab 的话，
  homelab 挂了报警方也一起挂，整个机制归零。
- **为什么不用 Prometheus 的 `absent()` 规则**：同样是共命运，全舰队只有 homelab 一个
  Prometheus（oracle 无 Prometheus Operator，走 otel remote-write 推到 homelab），
  规则跑在它自己身上，它死了规则也不评估。
- **为什么 oracle 侧的 Telegram 通知直连而不绕回 homelab**：绕回去就又共命运了。
  代价是这条路径依赖 oracle 的 DNS（见上表第 3 行）。
- **为什么并入同一个 Telegram 话题**（而非独立话题）：homelab 真挂时，
  这会是该话题里唯一还在动的消息，信号反而更清楚
  （决策见 [alerting-telegram-migration.md](../decisions/alerting-telegram-migration.md)）。
- **为什么 `priorityClassName: high`**：uptime-kuma 被驱逐等于死人开关的接收端
  和全舰队探测底噪一起消失。

## 六、怎么验证它真的有效

☠️ **查配置查不出这类前提缺口。** 2026-08-09 做过一次验证，查的是
"monitor `active=1`、token 对得上、notification 已挂、心跳每 45s 一条全 UP"，
全部正确，但**没有制造一个缺口看它会不会真的转 DOWN**。结论"这条兜底是活的"
因此漏掉了整个失明窗口，直到 2026-08-14 才被发现。

> **安全网只能用触发它来验证。** 检查项应当是"制造缺口 → 是否在 ~2 分钟内收到
> Telegram"，而不是"配置是否正确"。

### 演练程序（⚠️ 尚未实测，会真发一条 Telegram 告警）

思路：用 Alertmanager 的静默停掉心跳（完全可逆、不碰 git、不惊动 ArgoCD），
等它转 DOWN，确认 Telegram 到达，再撤销静默。

```bash
# 1) 起 port-forward（homelab Alertmanager）
kubectl --context k3s-homelab -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 19093:9093 &

# 2) 静默 Watchdog 4 分钟 —— 心跳随即停止
curl -sX POST localhost:19093/api/v2/silences -H 'Content-Type: application/json' -d '{
  "matchers":[{"name":"alertname","value":"Watchdog","isRegex":false,"isEqual":true}],
  "startsAt":"'"$(date -u +%FT%TZ)"'",
  "endsAt":"'"$(date -u -v+4M +%FT%TZ)"'",
  "createdBy":"dead-mans-switch-drill","comment":"drill"}'

# 3) 等 ~2 分钟，确认库里出现 DOWN（这是机制生效的硬证据）
kubectl --context oracle-k3s -n personal-services exec deploy/uptime-kuma -c uptime-kuma -- \
  sqlite3 /app/data/kuma.db \
  "SELECT time,status,msg FROM heartbeat WHERE monitor_id=1 AND important=1 ORDER BY time DESC LIMIT 3;"

# 4) 确认 Telegram 收到「Alertmanager Watchdog」DOWN
# 5) 撤销静默（静默 4 分钟后也会自然过期，故第 2 步已是安全兜底）
curl -s localhost:19093/api/v2/silences | \
  python3 -c 'import sys,json;[print(s["id"]) for s in json.load(sys.stdin) if s.get("createdBy")=="dead-mans-switch-drill"]' | \
  xargs -I{} curl -sX DELETE localhost:19093/api/v2/silence/{}
```

⚠️ 演练期间死人开关本身是关的，**别在 homelab 有任何异动时做**。
⚠️ 第 3 步查的是 `important=1`：失明时恰恰是这张表没有新行，
所以"没有新行"要读成失败而不是"还没到时候"。

## 七、开放项

1. **失明窗口未消除**。`DeadMansSwitchReceiverDown` 只让它可见。
   彻底解决需要第二个**不与 oracle 共命运**的接收端（外部 healthchecks.io 之类），
   会引入新外部依赖与密钥，刻意暂缓，先观察新告警的信噪比。
2. ☠️ **uptime-kuma 侧无对等的"通知发送失败"告警**（2026-08-01 提出，至今开放）。
   Alertmanager 侧有 `AlertmanagerFailedToSendAlerts`，uptime-kuma 侧没有对等物，
   且它的指标根本没被采集。可行路径：给 `/metrics` 配 API key 并让 oracle 的
   otel-collector 抓取，再对 monitor 状态做规则。**未实施。**
3. **演练从未真正做过**（第六节的程序尚未实测）。按第六节自己的论证，
   在做完一次之前，"这条链路有效"仍属未经验证的断言。
