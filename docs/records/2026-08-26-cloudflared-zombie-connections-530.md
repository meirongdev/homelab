# homelab 隧道公网 530 十五分钟：cloudflared 握着 4 条僵尸连接，本地指标全程正常

> 日期: 2026-08-26（04:52Z 约 1 分钟、06:06–06:21Z 15 分钟，两次）
> 影响: homelab 隧道后的 6 个服务（Grafana / Open Notebook / Vault / Multica / Nakama / Jobs SG）
>       公网全部返回 Cloudflare 530（error 1033）。oracle 隧道未受影响
> 根因: 未完全查明。到 Cloudflare 边缘（sin* colo）的那条路坏了，而 cloudflared 没察觉，
>       `cloudflared_tunnel_ha_connections` 全程恒为 4，直到 06:21:07Z 才一次性断开 4 条并重连
> 处置: 两集群 cloudflared 升到 2026.8.2（同一个多架构 index digest）。升级不是已证实的修复，
>       只是唯一现成的杠杆；不加新的 Prometheus 规则

## 经过

| 时刻（UTC） | 事件 |
|------|------|
| 04:52 | 第一次 530，约 1 分钟自愈 |
| 06:06 | 第二次 530 开始，6 个 homelab 服务全不可达。发现靠 oracle 上 Uptime Kuma 的跨集群黑盒探测（直发 Telegram） |
| 06:06–06:21 | cloudflared 认为 4 条边缘连接都健康，`ha_connections` 恒为 4 |
| 06:21:07 | cloudflared 一次性 `Lost connection` 全部 4 条，立刻重连，服务即恢复 |
| 当天 | homelab 2026.7.2 → 2026.8.2，oracle 2026.7.3 → 2026.8.2（`4181aa1`） |

## 定位

- **不是整体出网挂了**：同一窗口 homelab↔oracle 的 Tailscale 采样 211/211 零缺口。坏的是到
  Cloudflare 边缘的那条路。同期 Alertmanager 的 watchdog webhook（也走 Cloudflare 边缘）报
  `contextDeadlineExceeded`，与之互证；Telegram 投递本身 0 失败，告警没受影响。
- **本地指标一个都没看见**：cloudflared 持有的是僵尸连接，`ha_connections` 全程正常。
  看见它的只有站在集群外、走公网回来的黑盒探测。
- 旧版自己在日志里提示 `Your version 2026.7.2 is outdated`，这是升级的全部依据。

## 处置与取舍

- 升级而不是换传输层：`--protocol quic` 对路径失效的探测比 http2 快，但会改变入口传输层，
  本次刻意不动。
- oracle 当天没出问题也一起升：两侧版本分叉会让下次判断「是不是版本差异」失去对照组。
- 不加 Prometheus 规则：跨集群黑盒探测已经覆盖这类故障，而集群内指标原理上看不见它。

## 复发判据

再出现「530 期间 `ha_connections` 仍为 4」，就说明升级没解决，那时再评估 `--protocol quic`。
判断隧道是否真通，看 oracle Uptime Kuma 对 homelab 域名的探测，不看 `ha_connections`。

## 教训

- `ha_connections = 4` 只说明 cloudflared 自己认为连着，不说明边缘到它的路通。隧道判活要有一路
  从集群外打进来的探测。
- 现状与指标口径见 [reference/cloudflare-tunnel-observability.md](../reference/cloudflare-tunnel-observability.md)，
  版本与动因写在 `k8s/helm/manifests/cloudflare/cloudflare-tunnel.yaml` 的镜像注释里。
