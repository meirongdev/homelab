# Homelab Project TODO

> Last updated: 2026-07-19
> 当前主线: [2026-07-06 存储本地化迁移 + 备份体系重建](../plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md)
> 演进路线（技术债盘点 + 2026 工具链选型，含 Crossplane 不引入结论）: [evolution-roadmap-2026-07-07](../reference/evolution-roadmap-2026-07-07.md)

## Phase 1: Foundation ✅

- [x] Terraform setup for VM provisioning (Proxmox)
- [x] Ansible playbooks for K3s installation (On-prem)
- [x] Helm-based application deployment
- [x] Observability stack (Prometheus, Grafana, Loki, Tempo)
- [x] OTel Collector DaemonSet — 替换 Promtail，OTLP HTTP → Loki 3.x
- [x] Grafana Loki Dashboards — Overview / Pod Browser / Errors / Cluster Search（GitOps via ArgoCD）
- [x] log-exporter sidecar pattern — 支持文件日志应用（Calibre-Web 已实施）
- [x] Oracle Cloud Free Tier K3s Cluster (Terraform + Ansible)
- [x] OTel Tracing — 双集群 OTLP traces → Tempo 全链路追踪

## Phase 2: Security & GitOps ✅

- [x] Deploy HashiCorp Vault to Kubernetes (Helm, `vault` namespace)
- [x] Initialize and unseal Vault
- [x] Configure Kubernetes authentication for ESO
- [x] Install External Secrets Operator (ESO)
- [x] Create ClusterSecretStore (`vault-backend`)
- [x] Migrate all app secrets to Vault
- [x] GitOps with ArgoCD (auto-sync + selfHeal for all managed apps)
- [x] ArgoCD Image Updater — automated `it-tools` image tracking via GHCR

## Phase 3: Multi-Cloud & Security ✅

- [x] Cross-Cluster Networking — Tailscale 双向 Pod CIDR 路由 (homelab ↔ oracle-k3s)
- [x] Identity simplification — 保留 ZITADEL 身份服务，移除共享入口层 SSO
- [x] 信息管道 — Miniflux → Redpanda Connect → KaraKeep（telegram 标签收藏，推送已于 2026-07 随 Gotify 下线砍掉未迁移——token 早已 401 失效，用得不多）
- [x] Cloudflare WAF — Zone 级 WAF 防护 (自定义规则、速率限制、安全设置)
- [x] Uptime Kuma — 外部健康监控 (status.meirong.dev)
- [x] Cilium CNI — homelab K3s 集群从 Flannel 迁移到 Cilium

## Phase 4: Reliability & Backup 📋 (Current — 主线 = 2026-07-06 计划)

- [x] ~~**Kopia 自动快照**~~: ❌ Kopia 已于 2026-07-05 整体移除（server + CronJob + PVC + Vault secret），全系统当前**零备份**
- [x] **备份体系重建（restic）**: ✅ 2026-07-06 双集群 CronJob 逻辑 dump（Vault raft snapshot / pg_dump(all) / sqlite）→ 106 ZFS 加密仓库 `881fb124bf`，上线
- [x] **恢复演练**: ✅ 2026-07-06 从仓库恢复 Vault snapshot + 两 PG dump + sqlite integrity_check 全通过（2026-07-06 计划 Phase 1 DoD）
- [x] **存储本地化迁移**: ✅ 2026-07-11 全部完成 — 106 宕机 3 天事故后，剩余 PVC（alertmanager/audit-vault-0/trivy）+ **Calibre 书库 24G**（超出原计划范围，原定留 NFS）全迁 `local-path`；nfs-client provisioner 卸载；书库纳入 restic 夜备 + 新增 PVE 每周 vzdump（VM 100 → 106 `backups`，keep-last=3）。106 降级为纯冷备份目标
- [ ] **离站备份**: restic 仓库 → 云（OCI always-free/B2），当前仅本地副本。见 2026-07-06 计划 Phase 5
- [x] **dead-man's switch**: ✅ 2026-07-19 端到端打通——homelab Watchdog → AlertmanagerConfig `watchdog`(webhook, repeat 30s) → status.meirong.dev/api/push/... → oracle Uptime Kuma push monitor(60s 窗口) → Telegram。⚠️ 踩坑两个:① Kuma push 端点**只收 GET**而 Alertmanager webhook 只发 POST——加了 nginx `proxy_method GET` sidecar(`push-shim`:3002)+ HTTPRoute `/api/push` 分流才通(`77e0922`);② `uptime-kuma-api==1.2.1` 没有 `pushToken` 参数且服务端不会自动生成 token——provisioner 注入过库白名单修复
- [x] **zpool/SMART 告警**: ✅ 其实 2026-07-06 就已随 `storage-alerts.yaml`(storage-health-alerts)上线——SmartHealthFailed/ZpoolNotOnline/介质错误/NVMe 磨损+备件/scrub 超期,指标名为 exporter 实际输出(`smartctl_device_smart_status`/`node_zfs_zpool_state`)。本条一直没打勾导致 2026-07-19 又按过时描述重复加了两条**指标名不存在的死规则**(`node_zfs_zpool_healthy`/`smartctl_device_smart_healthy`,查询返回空),已删
- [x] **Loki 日志保留**: ✅ 2026-03-19 compactor + retention 168h 已启用
- [x] **Alertmanager**: ✅ severity=warning|critical → 原生 telegramConfigs → Telegram（生产运行；2026-07-18 起，gotify-bridge 因 concurrent-map-write 崩溃 bug 下线，见 `decisions/alerting-telegram-migration.md`）
- [x] **Gotify 彻底退役**: ✅ 2026-07——三个消费者（Falco/dead-man's switch 迁 Telegram 原生 output/通知；RSS 阅读推送直接砍掉未迁移）处理完后，Gotify 本体（Deployment/PVC/Service/ExternalSecret/notify.meirong.dev 网关路由/homepage 书签/gotify-availability SLO/backup 条目/相关 Vault secret）全部移除。Cloudflare tunnel ingress 条目 + DNS record 已 `terraform apply` 摘除，`notify.meirong.dev` 确认不可达。详见 `decisions/alerting-telegram-migration.md`
- [x] **oracle-k3s Cilium**: 从 Flannel 迁移到 Cilium，统一双集群数据面
- [x] **Uptime Kuma SSO 修复**: maxredirects=0 + accepted_statuscodes 300-399
- [x] **homelab Ubuntu 24.04 重建**: ✅ 2026-03-08 重建完成，K3s v1.34.5+k3s1 + Cilium 1.19.1
- [x] **homelab Cilium Gateway 恢复**: ✅ kube-proxy replacement + Gateway API 验证通过
- [x] **oracle-k3s GitOps 纳管**: ✅ 2026-06-04 hub-and-spoke ArgoCD 经 Tailscale 纳管 oracle-k3s manifests，auto-sync/selfHeal/prune 启用

## Phase 5: Production Hardening 🎯 (Future)

- [x] Cilium ClusterMesh 启用 (跨集群 Service 发现) ✅ 2026-03-08 双集群 connected
- [x] Gateway 标准化: 当前架构以 Cilium Gateway API 为统一入口
- [x] **集群内部安全加固** ✅ 2026-06 已部署: PSA + Kyverno(Audit) + Trivy + kube-bench + 节点 CIS(待重启)
- [x] **运行时检测** ✅ 2026-06 已部署: Tetragon(homelab) + Falco(oracle)
- [x] **服务重定位（脱离 homelab 故障域）**: Gotify + ZITADEL → oracle-k3s ✅ 2026-07-06 迁移并验证（见 [apps/2026-07-04-zitadel-to-oracle-k3s](apps/2026-07-04-zitadel-to-oracle-k3s.md)）
- [ ] **homelab 旧 ZITADEL 退役**: 迁移后保留作回滚，真实浏览器登录确认后删（zitadel 计划遗留尾巴）
- [x] **ZITADEL DB 迁 CloudNativePG**: ✅ 2026-07-18 完成——`bitnamilegacy/postgresql:15.4.0`(冻结镜像安全债) → CNPG 1.30.0 + 官方 PG **17.6**(`zitadel-pg`,单实例,local-path)。pg_dump/pg_restore 实际停机 **~4.5 分钟**;逐表行数核对通过;真实 OIDC 登录/console 验证通过;旧库/PVC/ExternalSecret 已删(最终态 dump 存本地 `~/backups/zitadel-migration/` + restic 历史)。backup 脚本已指向 `zitadel-pg-rw`——⚠️ 顺带踩坑:备份容器 pg_dump 16 拒绝 dump PG17 server,alpine 升 3.22 + `postgresql17-client` 修复(手动验证抓到,否则夜备静默丢 zitadel dump)。见 [演进路线 Phase C](../reference/evolution-roadmap-2026-07-07.md)
- [ ] **Terraform state → R2 backend**: 5 个 root 全本地 state（笔记本单点、无锁、含明文密钥）。见演进路线 Phase A
- [~] **external-dns (Gateway API source)**: ✅ 2026-07-19 上线并端到端验证（`external-dns` App，`gateway-httproute` source，`homelab-gateway` 打 tunnel target 注解，policy=upsert-only 安全默认）。**未完成部分**：`argocd`/`book`/`grafana`/`llm`/`vault` 这 5 条现有记录仍在 terraform 手管，尚未把归属权转给 external-dns、也未精简 `cloudflare/terraform/terraform.tfvars`——新加子域名目前仍可以走 HTTPRoute 单文件（有 external-dns 接管），但老的还是两步走并存。顺带发现 homelab 自己的 `cloudflare/terraform/terraform.tfvars` 的 `cloudflare_api_token` 是无效值（tunnel token 格式），该项目 `terraform plan` 现在直接报错，待修
- [ ] **离站备份 (OCI always-free / B2)**: restic 仓库 → 云（rclone/`restic copy`）。见 2026-07-06 计划 Phase 5（later）
- [ ] **DGX Spark 入编**: 推理服务 IaC + GPU 指标(dcgm) + Bifrost 双机 fallback + SLO。见母文档 P1-5
- [ ] **恢复演练自动化**: 月度 CronJob 校验 restic restore。见母文档 P2-8
- [ ] Vault Dynamic Secrets (PostgreSQL 动态凭据) — 低优先，规模不需要
- [ ] Cloudflare Pro WAF (Managed Ruleset + OWASP CRS) — 可选
- [ ] Renovate (chart/image 版本自动 PR)；MacBook `TargetDown` 静默规则 — 母文档 P2

### ❌ 已划掉（防过度工程，见母文档"明确不建议做的"）
- ~~Cert-Manager (Let's Encrypt + DNS-01)~~ — TLS 在 Cloudflare 边缘终结、集群内 HTTP，无内网直连 TLS 需求 → 纯负担
- ~~Vault HA / auto-unseal~~ — 单节点无 HA 意义；sealed 已被 ESO 告警覆盖 + 恢复路径已文档化，transit auto-unseal 要再养一个 Vault，不值
- ~~Crossplane~~ — 2026-07-07 评估否决：CF provider 已死 2 年、问题规模不匹配（单人静态云面）、控制面鸡生蛋、单节点内存开销。重评条件与替代方案见 [演进路线 §三](../reference/evolution-roadmap-2026-07-07.md)
- ~~Talos 迁移~~ — 2026-03 刚重建 Ubuntu 24.04 且流程已顺，单节点收益不抵成本；加第二台 worker 时重评（演进路线 §五）

---

## Task Roadmap (By Effort)

### 🟢 Quick Wins

- [x] Uptime Kuma SSO 监控修复 (maxredirects config)
- [x] Loki retention 配置 (values.yaml update) ✅ 2026-03-19
- [x] Grafana 旧 dashboard 清理 ✅ 2026-03-19 禁用 AIX/Darwin/proxy dashboard
- [x] repo↔集群一致性清零（helm pin 对齐、homelab postgres 残留移除、ReferenceGrant v1beta1、gotify-bridge 双 App 争抢去重）✅ 2026-07-07
- [x] 双集群清理审计 ✅ 2026-07-12（孤儿 Job×7 / 0 副本 RS×97 / 未用镜像≈19G；falco inotify 根因修复 + ansible 固化；zitadel/gotify SLO 迁 oracle 指标 + 7 条 SLO errorQuery 空集加固 + 补 bifrost SLO；NFSStorageNodeDown→BackupTargetNodeDown；zitadel 迁移残留注释清零）
- [x] justfile 卫生 ✅ 2026-07-12: `deploy-prometheus`/`-nowait` 双 `--version` 去重（删死变量 `prometheus_stack_version=82.10.1`，实际生效的一直是 `kube_prometheus_stack_version=87.6.0`）；`loki_version` 6.53.0→7.0.0 对齐 ArgoCD 实际部署（防 `just deploy-loki` 意外降级）；顺带清理 Kopia 退役残留——justfile `kopia-*` 配方块删除、`KopiaBackupNotRunning` 告警改名 `BackupNotRunning` 并修正幽灵 `02:00/UTC` → 实际 `03:00/03:30 Asia/Shanghai`、kube-bench/setup-k3s/prune 警告的陈旧注释校正
- [x] 仓库级第二轮审计 ✅ 2026-07-12（CI/terraform/scripts/docs/manifests 5 路并行 fork 排查，逐条人工验证后修复）：
  - **`scripts/sync-ebooks.sh` 真实 bug**：NFS "主路径" 写入 storage-106 上迁移前遗留的孤儿快照目录（书库已 2026-07-11 迁 local-path，calibre-web 早已不读那份 NFS 拷贝）——checksum 在孤儿副本上核对，脚本全程报绿，书却从未真正入库。删除整条 NFS 传输路径，统一走 kubectl cp（唯一仍有效的路径）
  - PSA 命名空间清单漂移：`k8s/helm/justfile` `psa_privileged_ns` 缺 `kube-bench`（该 ns 需 hostPID+host 挂载，此前完全未被 `just harden-psa` 标注）补上；`docs/reference/security.md` + `docs/runbooks/security-hardening.md` 的 baseline/privileged 表格同步现状（清掉 zitadel/kopia/database 早已退役的条目，补齐 kyverno/trivy-system/tetragon/kube-bench）
  - `docs/reference/security.md`："Kopia 已移除→零备份/紧急缺口" 改为反映 restic 已上线 + 恢复演练通过的现状（残余缺口是离站备份未上线，非"无备份"）
  - 死链接/陈旧引用修正：`docs/decisions/gateway-controller-evaluation.md`（漏 `security/` 路径段）、`docs/runbooks/dns-network-failure-recovery.md`（强制重启循环里的 `kopia`/`homepage` 命名空间在 homelab context 下不适用）、`zitadel/scripts/configure-*.sh` ×4（`docs/runbooks/zitadel-console-grpc-404.md` → 实际路径 `docs/records/`）
  - 脚本硬化：`scripts/cleanup-duplicates.sh` 补全 `$CONTEXT`/`$POD` 引号；`configure-github-idp.sh` 用 `mktemp` 替换硬编码 `/tmp/zitadel-idp-link.out`
  - **两处结构性决策，已征得用户确认后执行**：`.github/copilot-instructions.md` 转 symlink → `docs/CONVENTIONS.md`（同 `.claudemd`/`.gemini.md` 模式）；6 个 terraform root 的 `.terraform.lock.hcl` 全部纳入版本控制（此前仅 `cloudflare/terraform` 提交，其余 5 个被 `.gitignore` 排除——本地均已有 init 生成的 lock 文件，未跑新 init）
- [x] **Vault 孤儿 secret 清理** ✅ 2026-07-18：全 Vault 枚举 × 两集群全部 ExternalSecret 交叉核对（且确认无 Vault Agent Injector，全走 ESO），删除 4 个确认无消费者的孤儿——`secret/homelab/postgres`（bitnami PG 退役遗物）、`secret/homelab/zitadel-oidc`（旧 SSO 共享 OIDC client）、`secret/oracle-k3s/oauth2-proxy`（同批遗留，client-id 与 zitadel-oidc 相同，核查确认亦为孤儿、oracle 无 oauth2-proxy 工作负载）、`secret/homelab/kopia`（2026-07-05 已软删，本次 metadata 彻底清除）。均 `DELETE /v1/secret/metadata/<path>` 全版本销毁。删后重新枚举确认剩余 16 个 path 全部有对应 ExternalSecret 消费者。
  - **⚠️ `secret/homelab/zitadel` 是活的，未动**——oracle zitadel ns 的 3 个 ExternalSecret（config/masterkey/postgres-auth）+ oracle backup 跨集群读它；删前专门对照过 keys（db-password/master-key）确认与孤儿 `zitadel-oidc` 不是同一个。
  - 本地明文清单 `k8s/helm/values/vault_values.md`（gitignored）**已删除**：它是 2026-03 的陈旧全量明文 dump（16 条里 10 条已死），维护成本高且是纯明文密钥落盘的安全负担。Vault 本身是真相源且有 restic 夜备，需要临时清单时按需重新生成即可（`.gitignore` 规则 `**/vault_values.md` 保留，重生成物仍会被忽略），不再维护常驻明文副本。
- [ ] PSA: 实测 `backup` ns 后决定是否纳入 `psa_baseline_ns`（`k8s/helm/justfile` 注释有标记；注意 sqlite 备份 CronJob 用特权 hostPath 读 local-path 根，大概率要走 privileged/豁免路线）
- [x] **Tailscale 根因修复** ✅ 2026-07-12: mbpm5 已 `tailscale set --advertise-routes=` 停止广播 `192.168.50.0/24`（`AdvertiseRoutes` 确认清空）。pve 自己仍在广播同一网段（合理——24/7 在线，不像笔记本会睡眠/离线，更适合当 subnet router），mbpm5 accept-routes 保持开启不变（kubectl 访问 k3s API 依赖它接受 pve 广播的 `10.10.10.0/24`，关掉会破功能）。✅ 2026-07-19 实测裁定：`nfs-lan-route` workaround **不退役，永久保留**。k8s-node 上非破坏性实测（临时摘规则→查路由→立即恢复）证实：只要 pve 继续广播 `192.168.50.0/24`（设计如此，pve 24/7 在线适合当 subnet router）+ k8s-node 开 accept-routes（kubectl 访问 K8s API 依赖），不装这条 `ip rule`（priority 5260，逼 `to 192.168.50.0/24` 走 `lookup main`）就会绕道 Tailscale 隧道（`table 52` 里一直有这条路由，摘规则后立即切到 `dev tailscale0`）——多打一次到同一台 pve 的转发。这不是"两个广播者"遗留问题（那部分已被 07-12 的根因修复解决），是 pve 自己合理广播导致的结构性结果，`k8s-node`/`pve` 两边规则都要长期保留。
  - ⚠️ 排查中发现一个**未解之谜，和上面这条修复无关**：这台 Mac 上 `terraform plan/apply`（连 `192.168.50.4:8006` Proxmox API）100% 复现 `dial tcp ...: connect: no route to host`，但 `ping`/`curl`/`ssh` 到同一地址全部正常（curl 能拿到响应，只是偏慢 ~3s）。**已排除 Tailscale 路由是根因**——把 Tailscale 整个 `down` 掉复测，问题依旧 100% 复现。当前无阻塞（VM 内存等变更已改走 `qm`/SSH 绕过 terraform 执行），暂不深究；如果以后要用 terraform 管 Proxmox 且还是连不上，从这条线索继续查（怀疑是 terraform provider 的 HTTP client 行为或本机残留的 utun0-3/网络扩展相关，不是标准路由表问题）。

### 🟡 Medium Effort

- [x] restic 备份 CronJob（双集群，取代已移除的 Kopia）✅ 2026-07-06
- [x] 存储本地化迁移（nfs-client → local-path）✅ 2026-07-11 全部完成（含书库，见上方详情）
- [x] dead-man's switch（Watchdog → oracle Uptime Kuma push）✅ 2026-07-19,含 POST→GET shim,见 Phase 4 详情
- [ ] Terraform state → R2 backend + `use_lockfile`（5 root；可顺带评估 OpenTofu）
- [~] external-dns 上线（`--source=gateway-httproute` + cloudflare-proxied）✅ 2026-07-19，5 条既有记录迁移未做，见 Phase 4 详情
- [x] Alertmanager → Telegram 通知模板 ✅（2026-07-18 起原生 telegramConfigs，见上）
- [x] oracle-k3s Cilium 迁移

### 🔴 High Effort

- [x] Cilium ClusterMesh connect + failover validation ✅ 2026-03-08
- [x] homelab Cilium Gateway 恢复后双集群统一 cutover 验证 ✅ 2026-03-08
- [x] Gotify + ZITADEL 迁 oracle-k3s（脱离 homelab 故障域）✅ 2026-07-06
- [x] ZITADEL DB → CloudNativePG ✅ 2026-07-18（实际停机 ~4.5 分钟,PG 17.6,见 Phase 4 详情）
- [ ] DGX Spark 入编（IaC + GPU 指标 + Bifrost fallback + SLO）

### ❌ 已取消

- ~~Cilium External Workloads — NAS 纳入 Cilium 网络~~ (取消，2026-03-19)
  - 原因：`CiliumExternalWorkload` CRD 及 `cilium external-workloads` CLI 命令已从 Cilium 1.15+ Helm chart 中移除，Cilium 1.19.1 不再支持此功能。
  - 若需限制 NFS 访问，可改用 `CiliumNetworkPolicy` + `fromCIDR: 192.168.50.106/32` 的轻量方案，无需在 NAS 上安装 Cilium agent。
