# Records

> 故障复盘、事故报告、排障记录。按日期倒序。

| 日期 | 记录 | 内容 |
|------|------|------|
| 2026-08-22 | [podcast-tts-unload-pending](2026-08-22-podcast-tts-unload-pending.md) | 播客整集败于 Mac 换模型时的 `is busy`：重试只等 15s；☠️ 并发被实测否掉（5 路比串行快一倍），病因是耐心不是并发 |
| 2026-08-19 | [opencost-bingen-replay-crashloop](2026-08-19-opencost-bingen-replay-crashloop.md) | collector WAL 积 5.5GB，启动全量重放 3m43s > 探针预算 160s → 节点重启后永久崩循环烧 1.1/2 核 24h；retention 参数就是重放窗口 |
| 2026-08-18 | [multica-frontend-idle-rightsizing-oom](2026-08-18-multica-frontend-idle-rightsizing-oom.md) | 按「空载实测」把 frontend 上限收到 512Mi → OOM 崩循环（`memory.peak` 顶死上限、`oom_kill` 6 次）；sharp 图片优化单任务 +68Mi 是空载采样看不见的；CPU 500m throttle 66% 让首页间歇 4.5s，**全程对外 200 故无告警** |
| 2026-08-18 | [calibre-dedup-stale-paths](2026-08-18-calibre-dedup-stale-paths.md) | 过期的 `books.path` / 被复用的 `(id)` 被当成空壳记录 → **误删 20 本**（当日从磁盘+快照全数恢复）；旧去重脚本只认完全同名（60 组里只抓 6 组）；`cat` 一个 WAL 库得到的「已校验」备份是假的 |
| 2026-08-14 | [oracle-reboot-loop-and-blind-dead-mans-switch](2026-08-14-oracle-reboot-loop-and-blind-dead-mans-switch.md) | oracle 6 天硬重启 6 次、死人开关静默失明（非缺信号，是缺模式）；修 `NodeRebootLoop` + `DeadMansSwitchReceiverDown` |
| 2026-08-13 | [iprule-guard-render-bug](2026-08-13-iprule-guard-render-bug.md) | Jinja `join('\n')` 渲染出字面 `\n` → ip rule 收敛器断言塌行、防线名存实亡；修渲染 + 规则清单统一 + 对账指标 |
| 2026-08-13 | [k3s-worker-join-106](2026-08-13-k3s-worker-join-106.md) | 106 入编 worker 四个坑：`tailscale up` 致命窗口 · 5250 被占 · `disable-kube-proxy` 仅 server · k8s-node 缺 ip rule |
| 2026-08-13 | [oracle-musl-dns-servfail](2026-08-13-oracle-musl-dns-servfail.md) | 加的 DNS 上游让 OCI 私有域 SERVFAIL → musl 放弃整轮 search，Alpine 外网解析变抽签（glibc 免疫） |
| 2026-08-13 | [macos-local-network-tcc](2026-08-13-macos-local-network-tcc.md) | 本机 terraform/kubectl 连 LAN "no route to host" → macOS 本地网络隐私授权，与真路由故障同形 |
| 2026-08-12 | [tailscale-iprule-guard-drift](2026-08-12-tailscale-iprule-guard-drift.md) | networkd 清扫外来 ip rule 把 fwmark 防护清光、homepage 断连 33h 无告警；修成两道防线 + 5 条告警 |
| 2026-08-12 | [slo-nan-poisoning](2026-08-12-slo-nan-poisoning.md) | SLI 0/0 产出 NaN 写入 TSDB、传染 30d 序列 → 5 个错误预算面板全 N/A 而告警链路全绿 |
| 2026-08-11 | [gateway-api-crd-stall](2026-08-11-gateway-api-crd-stall.md) | Cilium 1.20 漏配 Gateway API CRD → 控制器静默未初始化 30h；旧路由照常 200，只有新增路由 503 |
| 2026-08-03 | [namespace-prune-cascade](2026-08-03-namespace-prune-cascade.md) | Namespace 内嵌清单 → 删文件 prune 掉整个 ns → 级联删光同 ns 数据（`Prune=false` 拦不住）；已从 restic 恢复 |
| 2026-08-01 | [oracle-k3s-dns-outage](2026-08-01-oracle-k3s-dns-outage.md) | oracle 丢 OCI DNS 上游 → CoreDNS 全挂 → cloudflared 崩溃 → meirong.dev 不可达 ~20min |
| 2026-07-12 | [pve-screen-backlight-always-on](2026-07-12-pve-screen-backlight-always-on.md) | pve 屏幕常亮（`setterm powersave` 静默失败） |
| 2026-06-07 | [zitadel-console-grpc-404](2026-06-07-zitadel-console-grpc-404.md) | ZITADEL Console v1 gRPC 经网关 404 → Cilium `enableAppProtocol` |
| 2026-03-15 | [cilium-hubble-tls-issue](2026-03-15-cilium-hubble-tls-issue.md) | Hubble TLS 证书问题排查 |
| 2026-03-09 | [oracle-k3s-outage-report](2026-03-09-oracle-k3s-outage-report.md) | oracle-k3s 宕机复盘 |

## 约定

新增复盘：`YYYY-MM-DD-<topic>.md`，并更新上表。全目录已符合该命名
（`zitadel-console-grpc-404.md` 于 2026-07-31 补上日期前缀，其 9 处引用同步更新）。
