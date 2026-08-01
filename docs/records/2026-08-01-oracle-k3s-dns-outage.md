# 2026-08-01 oracle-k3s DNS 上游故障复盘

> 日期: 2026-08-01
> 影响: 全部 `*.meirong.dev` 公网不可达约 20 分钟（07-31 22:31–22:52 UTC = 08-01 06:31–06:52 UTC+8），触发多条 Telegram 告警；无数据丢失
> 根因: oracle-k3s 节点短暂丢失到 Oracle Cloud DNS（`169.254.169.254:53`）的连通性 → CoreDNS 全外网解析失败 → cloudflared 崩溃（exit 1）→ Cloudflare Tunnel 整体下线

## 症状：收到的 Telegram 告警

用户在「🚨 Homelab 告警」话题收到多条告警，均来自 **homelab Alertmanager**（近 6h 发出 18 条 Telegram 通知，集中在 22:40–23:15 UTC）：

| 告警 | 集群 | 严重度 | 说明 |
|------|------|--------|------|
| `KubePodCrashLooping` | oracle-k3s | warning | cloudflared 崩溃重启 |
| `KubePodNotReady` | oracle-k3s | warning | 同上 |
| `KubeDeploymentReplicasMismatch` | oracle-k3s | warning | 同上 |
| `TargetDown` | oracle-k3s | warning | 隧道相关抓取目标丢失 |
| `AlertmanagerFailedToSendAlerts` | homelab | warning | Watchdog webhook 投递失败（Cloudflare 530/1033） |
| `TrivyImageCriticalVulnerabilities` | homelab | warning | 存量例行告警，非本次触发 |

⚠️ **uptime-kuma 的告警这次没有送达**：它检测到全部 `*.meirong.dev` 监控 DOWN 后尝试发 Telegram，但当时集群 DNS 全挂，`getaddrinfo EAI_AGAIN api.telegram.org` 发送失败（日志见下）。用户能收到告警靠的是 homelab 侧 Alertmanager 那条独立链路。

## 影响

- 全部 `*.meirong.dev`（双集群服务经同一条 Cloudflare Tunnel + Cilium ClusterMesh 网关暴露）公网不可达。
- 受影响 uptime-kuma 监控：Calibre-Web / Grafana / HashiCorp Vault / ArgoCD / `Alertmanager Watchdog`（dead-man's switch）。
- homelab Alertmanager 的 Watchdog webhook（`status.meirong.dev/api/push/...`）持续失败，触发 `AlertmanagerFailedToSendAlerts` 自指告警。
- 集群内部链路（Tailscale、ClusterMesh、备份）不受影响；在线服务无数据丢失。

## 根因分析（证据链）

### 1. oracle-k3s 节点丢失到 OCI DNS 的连通性

oracle-k3s 的 CoreDNS 把外网查询转发到 `169.254.169.254:53`（OCI VCN 默认 DNS/元数据地址）。07-31 22:31–22:51 UTC 期间该上游全部超时：

```text
[ERROR] plugin/errors: 2 book.meirong.dev. A: read udp 10.52.0.130:44886->169.254.169.254:53: i/o timeout
[ERROR] plugin/errors: 2 _v2-origintunneld._tcp.argotunnel.com. SRV: read udp 10.52.0.130:41486->169.254.169.254:53: i/o timeout
```

确认窗口（`kubectl --context oracle-k3s logs -n kube-system coredns-695cbbfcb9-wpwcd --timestamps=true`）：

```text
2026-08-01T06:31 ~ 06:51 +08:00  →  169.254.169.254:53: i/o timeout（每分钟几十条）
```

### 2. CoreDNS 失败 → 集群内全部外网解析挂掉

CoreDNS（`10.53.0.10`）对外网查询返回 `server misbehaving`，波及所有 pod：

- uptime-kuma 监控全部 `EAI_AGAIN`（`getaddrinfo EAI_AGAIN book.meirong.dev`），dead-man's switch 报 `No heartbeat in the time window`。
- uptime-kuma 发 Telegram 通知也因 `EAI_AGAIN api.telegram.org` 失败。
- cloudflared 无法解析 `_v2-origintunneld._tcp.argotunnel.com` 做 edge discovery，直接崩溃：

```text
ERR edge discovery: error looking up Cloudflare edge IPs: ... lookup _v2-origintunneld._tcp.argotunnel.com on 10.53.0.10:53: server misbehaving
ERR Initiating shutdown error="Could not lookup srv records on _v2-origintunneld._tcp.argotunnel.com: ..."
```

### 3. Tunnel 下线 → 全网不可达

cloudflared 两副本在 22:49–22:55 UTC 相继退出（exit 1 / 重启），Cloudflare Tunnel 失去全部 origin 连接：

- 公网到 `*.meirong.dev` 返回 Cloudflare `530 error 1033`（homelab Alertmanager 视角，Watchdog webhook）。
- 22:51–22:55 UTC 网络恢复后 cloudflared 自动重连（日志 `Starting tunnel ... 22:55:32Z`），全部监控 22:51:49–22:52:43 UTC 回 UP。

## 时间线（UTC；本地 +8 加 8 小时）

| 时间 (UTC) | 事件 |
|-----------|------|
| 22:31 | CoreDNS 上游 `169.254.169.254:53` 开始超时 |
| 22:32:13–22:32:53 | uptime-kuma：dead-man's switch / Vault / Calibre-Web / ArgoCD 依次 DOWN |
| 22:40–23:15 | homelab Alertmanager 集中发 Telegram 告警（KubePod 系列 + TargetDown + AlertmanagerFailedToSendAlerts） |
| 22:49–22:55 | cloudflared 两副本崩溃重启（`server misbehaving` → exit 1） |
| 22:51–22:52 | CoreDNS 恢复；uptime-kuma 监控回 UP |
| 22:55:32 | cloudflared 重连 tunnel 成功 |

## 验证当前状态（已恢复）

```bash
kubectl --context oracle-k3s get node              # Ready
kubectl --context oracle-k3s get pods -n cloudflare # cloudflared 1/1 Running
kubectl --context oracle-k3s exec -n personal-services deploy/uptime-kuma -- \
  curl -sI https://book.meirong.dev                # HTTP 302
# uptime-kuma 全部监控 UP；homelab Alertmanager 当前无 firing→Telegram 告警
```

## 教训与建议（待 review / 修复）

1. **CoreDNS 上游单点**：oracle-k3s 只依赖 OCI `169.254.169.254:53`，单个上游一抖 = 全集群外网 DNS 全挂。建议给节点 `/etc/resolv.conf` 或 CoreDNS `forward` 加备用上游（如 `1.1.1.1`），或确认 OCI 侧可用的 backup resolver。→ 已挂入 ROADMAP 开放项。
2. **cloudflared 无独立 fallback**：它靠 CoreDNS 解析 `argotunnel.com`，DNS 挂它就崩。上游冗余后本链自动受益。cloudflared 24 天重启 24–28 次，说明此类外部 DNS 抖动反复发生，值得跟进（可评估 `--edge-ip-version` 等连接参数）。
3. **dead-man's switch 链路单点盲区**：Watchdog → uptime-kuma → Telegram 依赖 oracle-k3s 的 DNS（连发送通知也要 DNS）。本次是 homelab Alertmanager 的独立链路（经 homelab 网络直连 `api.telegram.org`）救场。接受"双链路冗余"现状即可，但应文档化；若要加固，可给 uptime-kuma 的 Telegram 通知配固定 IP / 备用 DNS。
4. **uptime-kuma 告警静默失败无对等保护**：本次其 DOWN 通知发不出去但无自指告警；Alertmanager 侧有 `AlertmanagerFailedToSendAlerts`，uptime-kuma 侧没有对等机制，属已知盲区。
5. **外部故障**：非仓库变更引起，更接近 OCI 侧 / 实例网络的瞬时闪断；若反复出现需开 OCI support ticket 或核查实例网络路径。
