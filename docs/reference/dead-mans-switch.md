# Dead-man's switch — 目的、链路与覆盖边界

> Last updated: 2026-10-28
> Status: 生效事实
>
> 死人开关的**唯一真相源**：为什么存在、链路每一跳、覆盖与不覆盖什么、怎么验证。
> 告警路由的其余部分见 [observability-alerting-slo.md](observability-alerting-slo.md)。
> 相关故障：[2026-08-01 oracle 出网中断](../records/2026-08-01-oracle-k3s-dns-outage.md) ·
> [2026-08-14 失明窗口](../records/2026-08-14-oracle-reboot-loop-and-blind-dead-mans-switch.md) ·
> [2026-09-30 通知丢一半](../records/2026-09-30-uptime-kuma-telegram-happy-eyeballs.md)。

## 一、为什么需要它

其它告警都要求监控栈本身活着才能响；监控栈挂了，Telegram 里的沉默和「一切正常」长得一样。
死人开关反过来：**对心跳的缺席告警，且报警方与被监控方不共命运。**被监控方是 homelab
（Prometheus + Alertmanager + 节点 + 出网路径），报警方是 oracle-k3s 的 Uptime Kuma。

仓库里另有十来条 `absent()` 规则（`OracleTelemetryAbsent`、`ClusterMeshMetricsAbsent*`、
`ReadlistMetricsAbsent`…）也判缺席，但全跑在 homelab 自己的 Prometheus 里，homelab 一死就不评估。
死人开关的价值全在判定方的位置，所以它与被监控方一起挂掉时（第四节）就完全归零。

## 二、完整链路（6 跳）

| # | 跳 | 实现 | 这一跳断了会怎样 |
|---|---|---|---|
| 1 | 常燃告警 | homelab Prometheus 内置 `Watchdog`，`expr: vector(1)`，永远 firing | 心跳停 → 正确触发 |
| 2 | 路由 | `watchdog` AlertmanagerConfig（`alerts/alertmanager-config.yaml`）：`alertname=Watchdog`、`groupWait 0s`、`groupInterval 15s`、`repeatInterval 30s` → receiver `watchdog-webhook` | 同上 |
| 3 | 出网 | webhook POST `https://status.meirong.dev/api/push/alertmanager-watchdog-homelab?status=up&msg=OK&ping=` | homelab 出网/Cloudflare/隧道断 → 正确触发，但归因指向 homelab |
| 4 | 入口 | Cloudflare → 隧道 → oracle `oracle-gateway`:80 → HTTPRoute `uptime-kuma`（PathPrefix `/`）→ `uptime-kuma:3001`。Kuma v2 的 `/api/push` 是 `router.all`，原生收 POST | oracle 入口断 → ☠️ 失明 |
| 5 | 判定 | push monitor `id=1` "Alertmanager Watchdog"：`interval=60`、`retry_interval=60`、`maxretries=1`、`resend_interval=0`、`active=1` | uptime-kuma 下线 → ☠️ 失明且不留痕迹 |
| 6 | 通知 | notification "Telegram (dead-man)"（`is_default=1`，挂全部监控；⚠️ provisioner 每次都删了重建，id 不固定，按名字查）→ oracle 直连 `api.telegram.org` | 发送失败 → ☠️ 静默（开放项 2） |

☠️ push token 靠 `cloud/oracle/manifests/uptime-kuma/provisioner.yaml` 里的常量对上 URL：库不在
`add_monitor` 上暴露 `pushToken`，靠 monkeypatch 注入；不注入则服务端自生成随机 token，开关静默失效。

## 三、关键参数各自在防什么

三个数耦合，改一个就要重算另外两个：

| 参数 | 值 | 作用 |
|---|---|---|
| `repeatInterval`（Alertmanager）| 30s | 发送节奏。重复调度不精确，实测到达间隔中位约 45s，别按 30s 算余量 |
| `interval`（monitor）| 60s | 判定窗口，对约 45s 的实际间隔只剩十几秒余量 |
| `maxretries` + `retry_interval` | 1 × 60s | 防误报靠它：超窗口先 PENDING，再等 60s 仍无心跳才 DOWN。去掉它，一次延迟推送就误报 |

→ 实际报警延迟 ≈ 120s（从最后一条心跳算），不是 60s。实测 121s 的缺口会转 DOWN，更短的抖动不会。

## 四、☠️ 覆盖矩阵

**覆盖**：homelab 整机没了、Prometheus / Alertmanager 挂了（心跳源消失）· homelab 出网 /
Cloudflare / 隧道断（2026-08-01 实录 `No heartbeat in the time window`）· 告警链路配置被改坏。
⚠️ 出网那一类触发时 homelab 本身可能是好的：它报的是「心跳没到」，不是「homelab 死了」。

**不覆盖（静默失明）**：

| 盲区 | 机制 | 现状 |
|---|---|---|
| 接收方与发送方一起挂（oracle 重启 / uptime-kuma 下线） | 检查跑在 uptime-kuma 进程内，它下线就没人检查；重启后约 45s 内新推送已到，看上去「一直 UP」。缺口远超 120s 也不转 DOWN、库里不留痕迹（[2026-08-14](../records/2026-08-14-oracle-reboot-loop-and-blind-dead-mans-switch.md)） | `DeadMansSwitchReceiverDown`（homelab 侧 webhook 持续失败）只让失明可见，没有消除 |
| uptime-kuma 的通知发不出去 | `/metrics` 要 API key（401）且没人采集，Prometheus 里没有任何 uptime-kuma 指标。9 月真发生过，一半通知丢失，含死人开关那条（[2026-09-30](../records/2026-09-30-uptime-kuma-telegram-happy-eyeballs.md)） | 那次成因已修（`uptime-kuma.yaml` 的 `NODE_OPTIONS` 带 `--no-network-family-autoselection`，别删）；「发送失败没告警」仍开放 |
| oracle pod 出网坏（DNS 或出站连接） | 通知直连 `api.telegram.org`，要能解析也要能出站 | 2026-08-01 发生过（当时判为 DNS，[10-01 更正](../records/2026-10-01-oracle-firewalld-flushes-cilium-iptables.md)为 firewalld 清掉 Cilium masquerade），靠 homelab Alertmanager 的独立 Telegram 链路救场 |

## 五、拓扑取舍

- 接收端放 oracle、不用 Prometheus `absent()`：都为不共命运。全舰队只有 homelab 一个 Prometheus
  （oracle 无 Prometheus Operator，走 otel remote-write 推到 homelab）。
- oracle 的 Telegram 通知直连、不绕回 homelab（绕回去又共命运），代价是依赖 oracle 自己的出网。
- 并入同一个 Telegram 话题：homelab 真挂时它是话题里唯一还在动的消息，信号更清楚
  （[决策](../decisions/alerting-telegram-migration.md)）。
- uptime-kuma 用 `priorityClassName: high`：它被驱逐，接收端和全舰队探测底噪一起消失。

## 六、怎么验证它真的有效

☠️ 查配置查不出前提缺口：monitor `active=1`、token 对得上、notification 已挂、心跳全 UP 全都对，
也证明不了「制造一个缺口会转 DOWN」，失明窗口就是这样漏过去的。**安全网只能用触发它来验证**：
制造缺口，看约 2 分钟内是否收到 Telegram。

### 演练程序（⚠️ 尚未实测，会真发一条 Telegram 告警）

用 Alertmanager 静默停掉心跳（可逆、不碰 git、不惊动 ArgoCD），等它转 DOWN、确认 Telegram 到达，
再撤销静默。在本机跑（`date -v` 是 macOS 写法）：

```bash
# 1) 起 port-forward（homelab Alertmanager）
kubectl --context k3s-homelab -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 19093:9093 &

# 2) 静默 Watchdog 4 分钟，心跳随即停止
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
# 5) 撤销静默（4 分钟后也会自然过期，第 2 步已是安全兜底）
curl -s localhost:19093/api/v2/silences | \
  python3 -c 'import sys,json;[print(s["id"]) for s in json.load(sys.stdin) if s.get("createdBy")=="dead-mans-switch-drill"]' | \
  xargs -I{} curl -sX DELETE localhost:19093/api/v2/silence/{}
```

⚠️ 演练期间死人开关是关的，别在 homelab 有任何异动时做。第 3 步查 `important=1`：失明时恰恰是
这张表没有新行，所以「没有新行」要读成失败，不是「还没到时候」。

## 七、开放项

1. **失明窗口未消除**。彻底解决要第二个不与 oracle 共命运的接收端（外部 healthchecks.io 之类），
   会引入新外部依赖与密钥，刻意暂缓。
2. ☠️ **uptime-kuma 侧没有「通知发送失败」告警**（Alertmanager 侧有 `AlertmanagerFailedToSendAlerts`）。
   可行路径：给 `/metrics` 配 API key、让 oracle 的 otel-collector 抓取，再对 monitor 状态做规则。
   未实施。这个缺口已经兑现过一次（丢一半持续至少一个月，只有 pod 日志留痕），下一种成因出现时
   依然没人知道。补上之前排查用
   `kubectl --context oracle-k3s -n personal-services logs deploy/uptime-kuma | grep -c 'Cannot send notification'`。
3. **演练从未真正做过**（第六节）。做完一次之前，「这条链路有效」仍是未经验证的断言。
