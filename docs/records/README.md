# Records

> 故障复盘、事故报告、排障记录。按日期倒序。

| 日期 | 记录 | 内容 |
|------|------|------|
| 2026-08-03 | [namespace-prune-cascade](2026-08-03-namespace-prune-cascade.md) | Namespace 内嵌在应用清单里 → 删该文件 prune 掉整个 ns → 级联删光同 ns 下无关应用的数据（`Prune=false` 护栏对此无效）；已从 restic 完整恢复 |
| 2026-08-01 | [oracle-k3s-dns-outage](2026-08-01-oracle-k3s-dns-outage.md) | oracle-k3s 丢失 OCI DNS 上游 `169.254.169.254:53` → CoreDNS 全挂 → cloudflared 崩溃 → 全部 meirong.dev 不可达 ~20min |
| 2026-07-12 | [pve-screen-backlight-always-on](2026-07-12-pve-screen-backlight-always-on.md) | pve 屏幕常亮（`setterm powersave` 静默失败） |
| 2026-06-07 | [zitadel-console-grpc-404](2026-06-07-zitadel-console-grpc-404.md) | ZITADEL Console v1 gRPC 经网关 404 → Cilium `enableAppProtocol` |
| 2026-03-15 | [cilium-hubble-tls-issue](2026-03-15-cilium-hubble-tls-issue.md) | Hubble TLS 证书问题排查 |
| 2026-03-09 | [oracle-k3s-outage-report](2026-03-09-oracle-k3s-outage-report.md) | oracle-k3s 宕机复盘 |

## 约定

新增复盘：`YYYY-MM-DD-<topic>.md`，并更新上表。全目录已符合该命名
（`zitadel-console-grpc-404.md` 于 2026-07-31 补上日期前缀，其 9 处引用同步更新）。
