# Homelab Roadmap

> Last updated: 2026-07-31
> 本文只回答两件事：**还剩什么没做**，和**做过什么/为什么不做**。
> 实施细节不写在这里——每条都链到 `decisions/`（取舍）或 `plans/`（执行过程）。
>
> 相关：[技术债盘点与演进路线](plans/architecture/2026-07-07-tech-debt-and-evolution.md)（工具链层，含 Crossplane 否决结论）·
> [机器与集群架构优化](plans/architecture/2026-07-04-fleet-architecture-optimization.md)（物理层，编号 P0-x/P1-x/P2-x 出自这里）

---

## 开放项

按优先级排列。括号内是出处文档。

| # | 项目 | 说明 |
|---|------|------|
| 1 | **离站备份** | restic 仓库 → 云（OCI always-free / B2，`rclone` 或 `restic copy`）。当前只有 106 本地副本，火灾/失窃即全损。需人工先开云桶。（[2026-07-06 计划 Phase 5](plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md)，母文档 P0-1） |
| 2 | **Terraform state → R2** | 5 个 root 全本地 state：笔记本单点、无锁、含明文密钥。顺带可评估 OpenTofu + `use_lockfile`。（[演进路线 Phase A](plans/architecture/2026-07-07-tech-debt-and-evolution.md)） |
| 3 | **prometheus-operator CRD 补升** | 集群 10 个 `monitoring.coreos.com` CRD 停在 operator v0.89.0，实际运行 v0.92.1——`helm upgrade` 从不升级 chart 的 `crds/`。采纳进 ArgoCD 时刻意 `skipCrds: true` 把它与迁移解耦。两条路：去掉 `skipCrds` 让 ArgoCD 接管（推荐，之后随 chart 自动跟进），或手工 `kubectl apply --server-side`。需单独维护窗口验证。（[manual-helm 采纳决策](decisions/manual-helm-to-argocd-adoption.md)） |
| 4 | **DGX Spark 入编** | 推理服务 IaC + GPU 指标（dcgm）+ Bifrost 双机 fallback + SLO。当前两台 GB10（各 128GB）只接了 node_exporter / smartctl_exporter。（母文档 P1-5） |
| 5 | **恢复演练自动化** | 月度 CronJob 自动校验 restic restore，取代手工演练。（母文档 P2-8） |
| 6 | **PSA: `backup` ns 定级** | 实测后决定是否纳入 `psa_baseline_ns`（`k8s/helm/justfile` 注释有标记）。注意 sqlite 备份 CronJob 用特权 hostPath 读 local-path 根，大概率要走 privileged/豁免。 |
| 7 | **oracle external-dns 可观测** | homelab 的 4 条 external-dns 告警规则限定 `cluster="homelab"`，未覆盖 oracle 实例；需 oracle OTel 抓 `:7979`。非阻塞。（[external-dns 决策](decisions/external-dns-adoption.md)） |
| 8 | **低优先 / 可选** | Renovate（chart/image 版本自动 PR）· MacBook `TargetDown` 静默规则 · Vault Dynamic Secrets（PostgreSQL 动态凭据，规模不需要）· Cloudflare Pro WAF（Managed Ruleset + OWASP CRS）。（母文档 P2） |

### 已知问题（不阻塞，无人认领）

- **`argocd-image-updater` App 已装未用**：chart 1.2.4 在跑但 0 个 `ImageUpdater` CR，oracle-k3s App 只有旧式注解、无对应 CR——实际没在更新任何镜像。要么补 CR 接上，要么退役（见 `docs/decisions/argocd-image-updater.md`）。
- **这台 Mac 上 `terraform plan/apply` 连 `192.168.50.4:8006`（Proxmox API）100% `no route to host`**，但 `ping`/`curl`/`ssh` 到同一地址全部正常（curl 有响应，偏慢 ~3s）。**已排除 Tailscale**——整个 `tailscale down` 后仍 100% 复现。当前无阻塞（VM 变更改走 `qm`/SSH）。若日后要用 terraform 管 Proxmox，从 provider 的 HTTP client 行为或本机残留 utun0-3/网络扩展查起，不是标准路由表问题。

---

## 不做 / 已取消

| 项目 | 结论 |
|------|------|
| Cert-Manager (Let's Encrypt + DNS-01) | TLS 在 Cloudflare 边缘终结、集群内 HTTP，无内网直连 TLS 需求 → 纯负担 |
| Vault HA / auto-unseal | 单节点无 HA 意义；sealed 已被 ESO 告警覆盖 + 恢复路径已文档化，transit auto-unseal 要再养一个 Vault |
| Crossplane | 2026-07-07 否决：CF provider 已死 2 年、问题规模不匹配（单人静态云面）、控制面鸡生蛋、单节点内存开销。重评条件见[演进路线 §三](plans/architecture/2026-07-07-tech-debt-and-evolution.md) |
| Talos 迁移 | 2026-03 刚重建 Ubuntu 24.04 且流程已顺，单节点收益不抵成本。加第二台 worker 时重评（[演进路线 §五](plans/architecture/2026-07-07-tech-debt-and-evolution.md)） |
| Cilium External Workloads（NAS 入网） | 2026-03-19 取消：`CiliumExternalWorkload` CRD 与 CLI 已从 Cilium 1.15+ 移除，1.19.1 不支持。若要限制 NFS 访问，改用 `CiliumNetworkPolicy` + `fromCIDR: 192.168.50.106/32`（[原方案](plans/archive/2026-03-15-cilium-external-workload-nas.md)） |
| 集群级网络默认拒绝 | **刻意延后**（非取消）：单用户威胁模型下横向移动收益边际低、debug 成本高。Hubble 已开做可见性，作为日后单 ns 灰度的前置。见 [security.md](reference/security.md) |

---

## 已完成

### Phase 1 — 基础设施 ✅

Proxmox Terraform 预配 · Ansible 装 K3s · Helm 应用部署 · LGTM 可观测栈 ·
OTel Collector 替换 Promtail · Loki 面板 4 张（GitOps）· log-exporter sidecar 模式（Calibre-Web）·
Oracle Cloud Free Tier K3s · 双集群 OTLP traces → Tempo

### Phase 2 — 密钥与 GitOps ✅

Vault 部署/初始化/解封 · ESO + `vault-backend` ClusterSecretStore · 全部应用密钥迁入 Vault ·
ArgoCD（auto-sync + selfHeal）· ArgoCD Image Updater

### Phase 3 — 多云与边缘安全 ✅

Tailscale 跨集群 Pod CIDR 路由 · 身份简化（保留 ZITADEL，移除共享入口层 SSO）·
信息管道 Miniflux → Redpanda Connect → KaraKeep · Cloudflare Zone 级 WAF · Uptime Kuma ·
homelab + oracle-k3s 双双从 Flannel 迁 Cilium

### Phase 4 — 可靠性与备份 ✅

| 时间 | 项目 |
|------|------|
| 2026-03-08 | homelab Ubuntu 24.04 重建（K3s v1.34.5+k3s1 + Cilium 1.19.1）+ Cilium Gateway 恢复 |
| 2026-03-08 | Cilium ClusterMesh 双集群 connected + failover 验证 |
| 2026-03-19 | Loki compactor + retention 168h |
| 2026-06-04 | oracle-k3s 纳入 GitOps（hub-and-spoke，经 Tailscale）([计划](plans/networking/2026-06-04-oracle-k3s-argocd-gitops.md)) |
| 2026-07-05 | Kopia 整体移除（server + CronJob + PVC + Vault secret） |
| 2026-07-06 | **restic 备份上线**：双集群 CronJob 逻辑 dump（Vault raft snapshot / `pg_dump` / sqlite）→ 106 ZFS 加密仓库 `881fb124bf`；**恢复演练同日通过** ([计划](plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md)) |
| 2026-07-06 | zpool/SMART 告警上线（`storage-alerts.yaml`：SmartHealthFailed / ZpoolNotOnline / 介质错误 / NVMe 磨损 / scrub 超期） |
| 2026-07-11 | **存储本地化完成**：106 宕机 3 天后，剩余 PVC + Calibre 书库 24G 全迁 `local-path`，nfs-client 卸载；书库纳入 restic 夜备 + 新增 PVE 每周 vzdump |
| 2026-07-18 | Alertmanager → 原生 `telegramConfigs`，gotify-bridge 下线（concurrent-map-write 崩溃 bug）([决策](decisions/alerting-telegram-migration.md)) |
| 2026-07-19 | **dead-man's switch** 端到端打通：Watchdog → `watchdog` AlertmanagerConfig（webhook, repeat 30s）→ `status.meirong.dev/api/push/…` → oracle Uptime Kuma push monitor（60s 窗口）→ Telegram |
| 2026-07 | **Gotify 彻底退役**：三个消费者处理完（Falco / dead-man's switch 迁原生 Telegram；RSS 推送直接砍掉）后，本体 + 路由 + DNS + SLO + backup 条目全部移除 ([决策](decisions/alerting-telegram-migration.md)) |

### Phase 5 — 生产加固 ✅

| 时间 | 项目 |
|------|------|
| 2026-06 | **集群内部安全加固**：PSA + Kyverno(Audit) + Trivy + kube-bench + 节点 CIS ([计划](plans/security/2026-06-16-k3s-security-hardening.md) · [security.md](reference/security.md)) |
| 2026-06 | **运行时检测**：Tetragon(homelab) + Falco(oracle) ([计划](plans/security/2026-06-18-runtime-detection.md)) |
| 2026-06-15 | Grafana 面板整改：按 folder 分组、多集群选择器、稳定 datasource uid ([计划](plans/observability/2026-06-15-grafana-dashboard-reorg.md)) |
| 2026-07-06 | **服务重定位脱离 homelab 故障域**：Gotify + ZITADEL → oracle-k3s，homelab 旧 ZITADEL 已退役（ns/HelmCharts/PVC 已清）([计划](plans/apps/2026-07-04-zitadel-to-oracle-k3s.md)) |
| 2026-07-18 | **ZITADEL DB → CloudNativePG**：冻结的 `bitnamilegacy/postgresql:15.4.0` → CNPG 1.30.0 + PG 17.6，实际停机 ~4.5 分钟 ([演进路线 Phase C](plans/architecture/2026-07-07-tech-debt-and-evolution.md)) |
| 2026-07-19/20 | **external-dns 双集群全量**：`gateway-httproute` source + `upsert-only`；15 条既有记录零停机移交、terraform 解耦；两条隧道改单条 `*.meirong.dev` 通配路由 → **新增子域名从此只写一个 HTTPRoute** ([决策](decisions/external-dns-adoption.md)) |
| 2026-07-30 | OpenCost 双集群成本归因 + KRR 周报右尺寸 ([计划](plans/observability/2026-07-30-opencost-multicluster.md) · [计划](plans/observability/2026-07-30-krr-rightsizing.md) · [决策](decisions/opencost-krr-data-sources.md)) |
| 2026-07-31 | **manual-helm → ArgoCD 采纳**：`kube-prometheus-stack` + `external-dns` ×2；采纳前逐对象验证渲染等价；justfile 旧手动配方随 2026-08-01 清理删除，chart 版本唯一真源是 `argocd/applications/*.yaml` 的 `targetRevision`（紧急回滚模板见 `k8s/helm/justfile` 头部注释）([决策](decisions/manual-helm-to-argocd-adoption.md)) |
| 2026-07-31 | **OTel 2026 对齐**：homelab collector 首次落地（此前根本没部署，容器日志从未进 Loki）+ oracle collector 现代化 ([决策](decisions/otel-2026-alignment.md)) |
| 2026-07-31 | `manifests/` 目录化（一目录一 App）+ `gateway.yaml` 按路由拆 5 文件 ([决策](decisions/manifests-directory-per-app.md)) |

### 审计与清理（历史）

| 时间 | 内容 |
|------|------|
| 2026-07-07 | repo↔集群一致性清零：helm pin 对齐、homelab postgres 残留移除、ReferenceGrant v1beta1、gotify-bridge 双 App 争抢去重 |
| 2026-07-12 | 双集群清理审计：孤儿 Job×7 / 0 副本 RS×97 / 未用镜像 ≈19G；**falco inotify 根因修复**（`fs.inotify.max_user_instances` 默认 128 导致崩了 23 天）+ ansible 固化；7 条 SLO errorQuery 空集加固；`NFSStorageNodeDown` → `BackupTargetNodeDown` 降级 |
| 2026-07-12 | justfile 卫生：`deploy-prometheus` 双 `--version` 去重、`loki_version` 对齐 ArgoCD、Kopia 退役残留清除 |
| 2026-07-12 | 仓库级第二轮审计：**`scripts/sync-ebooks.sh` 真实 bug**（写入迁移前遗留的孤儿 NFS 快照目录，checksum 在副本上核对、全程报绿但书从未入库；已删整条 NFS 路径改走 `kubectl cp`）· PSA 命名空间清单漂移补 `kube-bench` · 死链修正 · 脚本引号/`mktemp` 硬化 · 6 个 terraform root 的 `.terraform.lock.hcl` 纳入版本控制 |
| 2026-07-12 | **Tailscale 根因修复**：mbpm5 停止广播 `192.168.50.0/24`，pve 保留为唯一 subnet router。`nfs-lan-route` ip-rule 经 2026-07-19 实测裁定**永久保留**，理由见 [tailscale-network.md](reference/tailscale-network.md) |
| 2026-07-18 | **Vault 孤儿 secret 清理**：全 Vault × 两集群 ExternalSecret 交叉核对，销毁 4 个无消费者的 path（`homelab/postgres`、`homelab/zitadel-oidc`、`oracle-k3s/oauth2-proxy`、`homelab/kopia`）。剩余 16 个 path 全部有消费者。⚠️ `secret/homelab/zitadel` 是活的（oracle 3 个 ExternalSecret + 跨集群 backup 读它） |
| 2026-07-31 | 本地明文 Vault 清单 `k8s/helm/values/vault_values.md` 实际删除。⚠️ 此前 07-18 就声明"已删除"但文件一直在磁盘上——它是 gitignored 的，删除不产生 diff，所以声明落空没人发现。约定见 [CONVENTIONS § Secrets](CONVENTIONS.md) |
