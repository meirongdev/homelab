# Records

> 故障复盘、事故报告、排障记录。按日期倒序。

| 日期 | 记录 | 内容 |
|------|------|------|
| 2026-10-26 | [litellm-keys-in-public-repo](2026-10-26-litellm-keys-in-public-repo.md) | 两把 LiteLLM 虚拟 key（白名单含 `openrouter/*`）明文推上公开仓库 7h40m，零调用，已吊销重发、历史已改写。☠️ 本地与 CI 两道 gitleaks 全绿：默认规则认不出 `sk-`+22 位，pre-push 钩子三台 clone 都没启用 |
| 2026-10-24 | [intrusion-sweep-argv-secrets-in-loki](2026-10-24-intrusion-sweep-argv-secrets-in-loki.md) | 双集群入侵排查未见入侵；Tetragon 把 argv 里 4 处密钥送进 Loki（bot token / SurrealDB 口令 / 隧道 token / 备份 Vault token），两轮移出命令行 + redactionFilters 兜底；oracle 停用 3 个手工遗留 |
| 2026-10-01 | [oracle-firewalld-flushes-cilium-iptables](2026-10-01-oracle-firewalld-flushes-cilium-iptables.md) | oracle pod 出站全断 30min、全站入口断 24min。needrestart 升 libssl 后重启 firewalld，**有 direct 规则就 flush 全部 iptables**，Cilium masquerade 被清。☠️ 08-01「OCI DNS 故障」是同一个病 |
| 2026-09-26 | [render-check-red-on-main](2026-09-26-render-check-red-on-main.md) | 渲染检查在 main 上红了 18 天没人看：去掉 `skipCrds` 后 CRD 里的裸 `=` 被 PyYAML 按 YAML 1.1 解析失败，整个 App 渲染挂；修法 `RenderedLoader`。☠️ 本地复现要用空 helm 环境 |
| 2026-09-19 | [litellm-fallbacks-never-active](2026-09-19-litellm-fallbacks-never-active.md) | 网关兜底链从 08-01 落地起七周没生效：`fallbacks` 写在 `litellm_params` 里被当 SDK kwarg，主上游一挂就 500。☠️ LiteLLM 不按错误类型跳过兜底，判据看日志 `run_async_fallback`；key 白名单不挡兜底 |
| 2026-09-12 | [falco-syscall-drops-apt-upgrade](2026-09-12-falco-syscall-drops-apt-upgrade.md) | Falco 一分钟丢 **402,586 个 syscall**（检测盲区）。☠️ 别查 CPU limit——全程 0.024/1 核零 throttle；真因是 `unattended-upgrades` 升 glibc+locales+python3.12 打出 fork 21/s，灌满**全机共用的那一个 8MB** 缓冲区。已改 32MB，阈值仍 `>0` |
| 2026-09-08 | [codex-subagent-agent-message-400](2026-09-08-codex-subagent-agent-message-400.md) | codex 一派 subagent 就 400：v2 私有 item `agent_message` 不在上游校验的 union 里（`Input should be 'shell_call'` 是误导）。网关 hook 降级 4 种 type；☠️ 修掉 400 后 v2 的 NEW_TASK payload 仍为空 |
| 2026-09-04 | [jobs-sg-enrich-runaway-reasoning](2026-09-04-jobs-sg-enrich-runaway-reasoning.md) | enrich 超时一夜 1.2%→7.8%。☠️ 不是 DGX 慢（引擎读数与前夜一致），是推理在长岗位上跑飞；`chat_template_kwargs` 预算键全部静默无效，顶层 `reasoning_effort: medium` 封顶后 8–22s 完成 |
| 2026-09-01 | [oracle-apparmor-af-unix-panic](2026-09-01-oracle-apparmor-af-unix-panic.md) | oracle 三个月的「宿主层硬重置」实为**内核 AppArmor 空指针**。☠️ 客场查不到是因为 `panic_on_oops=1` 让 journald 来不及落盘——「日志戛然而止」恰是 guest panic 的标准形态，不是宿主层证据。触发方是 uptime-kuma 容器内默认自启的 nscd，关掉后该函数调用 69→**0** |
| 2026-08-31 | [trivy-stale-replicaset-reports](2026-08-31-trivy-stale-replicaset-reports.md) | `TrivyExposedSecretFound` 烧 25h／42 条 Telegram，**没有任何真泄漏**：报告挂在 `replicas=0` 的 ReplicaSet 上，**24h TTL 只重扫有副本的**，指标衰减到 20 就平台化，永不自愈 |
| 2026-08-30 | [memory-alert-page-cache-false-alarm](2026-08-30-memory-alert-page-cache-false-alarm.md) | `ContainerMemoryNearLimit` 报 99.45%，峰值 87% 是页缓存（RSS 口径 26.4%），顶死 limit 却没有 OOM。☠️ 对照实验：同容器同 limit 重启三次，峰值 99.45%/70.1%/23.7%——读数由**节点页缓存冷热**决定 |
| 2026-08-24 | [jobs-sg-tech-alias-false-positives](2026-08-24-jobs-sg-tech-alias-false-positives.md) | 规则层别名撞普通英文词：`express` 精度 25%，`go` 靠假阳性进周报 top-30。☠️ 删别名对已有库是空操作（`Seed()` 只 upsert、运行时读表）；词义门 + `retech` 重放 + 逐周重算 |
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
| 2026-08-10 | [zitadel-ns-without-psa-labels](2026-08-10-zitadel-ns-without-psa-labels.md) | 装着 SSO 与身份库的 `zitadel` ns 一个 PSA 标签都没有，静默吃默认 `privileged` 一个多月（特权 Pod 能建成、零 warning）。当天收到 restricted，CI 加 H5。☠️ 先补 securityContext 再翻 enforce |
| 2026-08-09 | [jobs-sg-reconcile-never-succeeded](2026-08-09-jobs-sg-reconcile-never-succeeded.md) | 全量 reconcile 从未成功，2770 条过期岗位一条没关；`JobsSgIngestStale` 响时数据其实是新的。偏差拿全程峰值 total 比逐页累加和；闸门改覆盖率 ≥80%，到期关闭不再门控 |
| 2026-08-09 | [cilium-identity-fwmark-collision](2026-08-09-cilium-identity-fwmark-collision.md) | alertmanager 单个 pod 到整个 100.64/10 超时：Cilium identity 编进 mark 高位，撞上 Tailscale 的 fwmark ip rule，identity & 0xFF == 0x08 即中签（1/256）；修法是 5200 钉死 table 52 |
| 2026-08-06 | [priorityclass-missing-pods-rejected](2026-08-06-priorityclass-missing-pods-rejected.md) | homelab 缺 `meirong-bulk` 定义，opencost/trivy 滚动时新 pod 被拒，静默下线约 25 分钟，ArgoCD 全程 Synced。☠️ 两份 priorityclasses.yaml 必须逐字段同步；改名要「加新 → 改引用 → 删旧」三步 |
| 2026-08-05 | [jobs-sg-daily-partial](2026-08-05-jobs-sg-daily-partial.md) | `/daily` 头三天天天 partial：`newPostingDate` 是纯日期，按 RFC3339 解析让增量早停成死代码；零命中岗位永留积压（`llm_cached ≈ backlog`）。fixture 与实现错得一致，CI 全绿 |
| 2026-08-05 | [clustermesh-up-but-stuck](2026-08-05-clustermesh-up-but-stuck.md) | ClusterMesh 双向断开零告警：clustermesh-apiserver 卡死不自愈，配置从未丢。根因先后判错三次（secret endpoint / pod startTime / --reset-values），以 helm release 历史为准；补 kvstoremesh 告警 |
| 2026-08-03 | [namespace-prune-cascade](2026-08-03-namespace-prune-cascade.md) | Namespace 内嵌清单 → 删文件 prune 掉整个 ns → 级联删光同 ns 数据（`Prune=false` 拦不住）；已从 restic 恢复 |
| 2026-08-03 | [jobs-sg-launch-defects](2026-08-03-jobs-sg-launch-defects.md) | jobs-sg 上线当天七个缺陷：scratch 镜像无 zoneinfo 致 panic、字段建模错致整页解码失败、归档每条重扫、超时 60s < 66.5s、ESO 引用空路径告警、只读挂载开不了 WAL、`/tmp` 不可写致 500 |
| 2026-08-02 | [oracle-otel-config-not-reloaded](2026-08-02-oracle-otel-config-not-reloaded.md) | oracle otel-collector 改 ConfigMap 后 DaemonSet 不滚动（collector 只在启动时读配置）→ 迁移当天日志仍发往 homelab 旧 NodePort，ArgoCD 全程 Synced/Healthy。改 `configMapGenerator` 根治 |
| 2026-08-01 | [oracle-k3s-dns-outage](2026-08-01-oracle-k3s-dns-outage.md) | cloudflared 崩溃 → meirong.dev 不可达 ~20min。⚠️ 原定性「OCI DNS 上游故障」是**错的**，真因见 2026-10-01 |
| 2026-07-12 | [pve-screen-backlight-always-on](2026-07-12-pve-screen-backlight-always-on.md) | pve 屏幕常亮（`setterm powersave` 静默失败） |
| 2026-06-07 | [zitadel-console-grpc-404](2026-06-07-zitadel-console-grpc-404.md) | ZITADEL Console v1 gRPC 经网关 404 → Cilium `enableAppProtocol` |
| 2026-03-15 | [cilium-hubble-tls-issue](2026-03-15-cilium-hubble-tls-issue.md) | Hubble TLS 证书问题排查 |
| 2026-03-09 | [oracle-k3s-outage-report](2026-03-09-oracle-k3s-outage-report.md) | oracle-k3s 宕机复盘 |

## 约定

新增复盘：`YYYY-MM-DD-<topic>.md`，并更新上表。全目录已符合该命名
（`zitadel-console-grpc-404.md` 于 2026-07-31 补上日期前缀，其 9 处引用同步更新）。
