# oracle Uptime Kuma 的 Telegram 通知丢了一半：Node 的 Happy Eyeballs 250ms 计时器

> 日期: 2026-09-30（定位与修复；影响至少覆盖整个 9 月）
> 影响: oracle 的 Uptime Kuma 在 9 月 118 次状态变化里有 61 次通知没发出去，其中包括死人开关
>       自己那条（09-21、09-29）。监控本身全绿，没有任何告警，唯一的痕迹是 pod 日志里的
>       `Cannot send notification … AggregateError [ETIMEDOUT, ENETUNREACH]`
> 根因: Node ≥20 默认开 Happy Eyeballs（autoSelectFamily），除最后一个地址外每个地址只给 250ms
>       建连。`--dns-result-order=ipv4first` 把 IPv4 排在第一个（带计时器），本 pod 到
>       `api.telegram.org` 的 TCP 建连实测 252–268ms，超时后转试 IPv6，而 oracle 没有 IPv6 路由，
>       立即 ENETUNREACH
> 处置: `cloud/oracle/manifests/uptime-kuma/uptime-kuma.yaml` 的 `NODE_OPTIONS` 加
>       `--no-network-family-autoselection`（只走 IPv4、用内核的建连超时）

## 经过

- oracle 的 VM 没有 IPv6 出网，而 Cloudflare 的域名会返回 AAAA 记录，所以 uptime-kuma 早就设了
  `NODE_OPTIONS=--dns-result-order=ipv4first`，本意是强制走 IPv4。
- Node 20 起默认开 autoselection。ipv4first 恰好让 IPv4 排第一、挂着 250ms 计时器，而到 Telegram
  的建连 20/20 次超过 250ms，于是多数通知失败；能发出去的，是延迟恰好掉到 250ms 以下的那几天。
- 被监控的目标大多在 Cloudflare 边缘，离得近，建连远低于 250ms，所以监控全绿、只有通知失败。
- 2026-09-30 从 pod 日志里的 `Cannot send notification` 定位到这个计时器。Loki 里也有这些日志行，
  但没有任何规则在看。

## 验证

pod 内 Node v22.22.3，每组 10 次全新建连：原值 10/10 失败，加 `--no-network-family-autoselection`
后 10/10 成功，Cloudflare 双栈目标 5/5 正常。

调大 `--network-family-autoselection-attempt-timeout`（2000ms）也能 10/10，但 IPv4 仍挂着计时器，
只是把阈值挪远了。这里没有 IPv6，保留 autoselection 没有任何收益，所以没采用。

## 教训

- ⚠️ 别改回只剩 `ipv4first`：在 Node ≥20 上，它正是让远端目标必现失败的那个开关。
- 通知发送失败在 uptime-kuma 侧没有任何告警（它的 `/metrics` 没人采集），这次靠人翻日志才发现。
  补告警是死人开关的开放项 → [reference/dead-mans-switch.md](../reference/dead-mans-switch.md)。
