# Records

> 故障复盘、事故报告、排障记录。按日期倒序。

| 日期 | 记录 | 内容 |
|------|------|------|
| 2026-08-13 | [oracle-musl-dns-servfail](2026-08-13-oracle-musl-dns-servfail.md) | 为消除 CoreDNS 单上游而加的 `DNS=1.1.1.1 1.0.0.1`，让 OCI 私有 search 域 `vcn<id>.oraclevcn.com` 的探针拿到 **SERVFAIL 而非 NXDOMAIN** → **musl 放弃整轮 search**，oracle 上所有 Alpine 容器的外网解析变成抽签（glibc 免疫）；夜间备份三连挂当金丝雀。含「评审时看见了副作用、却把 rcode 和受害者都判错」的教训 |
| 2026-08-13 | [macos-local-network-tcc](2026-08-13-macos-local-network-tcc.md) | 工作机上 terraform/kubectl 连 LAN 恒报 `no route to host`（ROADMAP 挂了很久的"原因不明"）→ 定性为 **macOS 本地网络隐私授权**：未授权的非 Apple 二进制访问本地链路返回 `EHOSTUNREACH`，与真路由故障同形。含 2×2 判别实验与三条已固化绕法 |
| 2026-08-12 | [tailscale-iprule-guard-drift](2026-08-12-tailscale-iprule-guard-drift.md) | systemd-networkd 默认清扫外来 ip rule（`ManageForeignRoutingPolicyRules=yes`），8-11 unattended-upgrades 重启 networkd 把 fwmark 撞车防护（5200/5260）**双节点清光**，oneshot 单元仍显 active"看起来修过"；homepage 中签断连 33h 无告警。修成两道防线（networkd drop-in 关清扫 + timer 收敛器）+ textfile 指标 5 条告警。含 A/B 抓现行与「pve 幸存者对照组」破案法 |
| 2026-08-12 | [slo-nan-poisoning](2026-08-12-slo-nan-poisoning.md) | SLI 在零请求窗口 0/0 产出 **NaN 并写入 TSDB**，被 `sum_over_time` 汇总时传染整条 30d 序列 → 5 个服务的错误预算面板**全部 N/A**，而告警链路（≤3d 窗口）全绿、无人察觉。含「别给『没数据』预先写好非故障的解释文案」的教训 |
| 2026-08-11 | [gateway-api-crd-stall](2026-08-11-gateway-api-crd-stall.md) | Cilium 1.20 升级漏配 Gateway API CRD（v1.2.1 vs 要求的 v1.6.1）→ 两集群 Gateway API 控制器**静默未初始化 30 小时**；旧域名照常 200、无告警，只有新增路由才 503。含「用一个必然通过的测试验证假设」的教训 |
| 2026-08-03 | [namespace-prune-cascade](2026-08-03-namespace-prune-cascade.md) | Namespace 内嵌在应用清单里 → 删该文件 prune 掉整个 ns → 级联删光同 ns 下无关应用的数据（`Prune=false` 护栏对此无效）；已从 restic 完整恢复 |
| 2026-08-01 | [oracle-k3s-dns-outage](2026-08-01-oracle-k3s-dns-outage.md) | oracle-k3s 丢失 OCI DNS 上游 `169.254.169.254:53` → CoreDNS 全挂 → cloudflared 崩溃 → 全部 meirong.dev 不可达 ~20min |
| 2026-07-12 | [pve-screen-backlight-always-on](2026-07-12-pve-screen-backlight-always-on.md) | pve 屏幕常亮（`setterm powersave` 静默失败） |
| 2026-06-07 | [zitadel-console-grpc-404](2026-06-07-zitadel-console-grpc-404.md) | ZITADEL Console v1 gRPC 经网关 404 → Cilium `enableAppProtocol` |
| 2026-03-15 | [cilium-hubble-tls-issue](2026-03-15-cilium-hubble-tls-issue.md) | Hubble TLS 证书问题排查 |
| 2026-03-09 | [oracle-k3s-outage-report](2026-03-09-oracle-k3s-outage-report.md) | oracle-k3s 宕机复盘 |

## 约定

新增复盘：`YYYY-MM-DD-<topic>.md`，并更新上表。全目录已符合该命名
（`zitadel-console-grpc-404.md` 于 2026-07-31 补上日期前缀，其 9 处引用同步更新）。
