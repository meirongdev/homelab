# Homelab Roadmap

> Last updated: 2026-09-01
> 本文只回答两件事：还剩什么没做，和做过什么、为什么不做。
> **实施细节不写在这里**：每条压到一句话，展开看链接指向的 `reference/`（事实）、
> `decisions/`（取舍）、`records/`（复盘）、`plans/`（当时的执行过程）。
>
> 相关：[技术债盘点与演进路线](plans/architecture/2026-07-07-tech-debt-and-evolution.md)（工具链层，含 Crossplane 否决结论）·
> [机器与集群架构优化](plans/architecture/2026-07-04-fleet-architecture-optimization.md)（物理层，编号 P0-x/P1-x/P2-x 出自这里）

---

## 开放项

> ⚠️ **oracle-k3s 已单向缩容到 2 OCPU/12GB**（2026-08-05/06，A1 长期无容量、涨不回去）。
> 新服务别再按"容量宽裕"规划：requests 按实测填，非核心挂 `bulk`。
> 过程/验证/回滚见 [runbooks/oracle-k3s-shape-downsize.md](runbooks/oracle-k3s-shape-downsize.md)。

> ⚠️ **编号是稳定标识，不是序号**。`reference/`、`decisions/`、runbook 都按 `开放项 #N`
> 引用它们，所以关闭一条时不重新编号，也不把号让给新条目，留下的空档表示这号已经关掉了。
> 曾经因为挪过号，三处文档的 `Renovate #10` 与一处 `#13` 全指错了地方（2026-08-13 修）。

| # | 项目 | 说明 |
|---|------|------|
| 1 | **离站备份** | restic 仓库 → 云（OCI always-free / B2）。当前只有 106 本地副本，**火灾/失窃即全损**。恢复演练已自动化，但只证明「106 上那份能恢复」。需人工先开云桶；rclone 同步段刻意等开桶时一并做。（[方案](plans/storage/2026-08-03-offsite-backup.md) · [Phase 5](plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md) · [演练](reference/storage.md)，母文档 P0-1） |
| 2 | **Terraform state → R2** | 5 个 root 全本地 state：笔记本单点、无锁、含明文密钥。顺带可评估 OpenTofu + `use_lockfile`。（[方案](plans/architecture/2026-08-03-tf-state-r2.md) · [演进路线 Phase A](plans/architecture/2026-07-07-tech-debt-and-evolution.md)） |
| 3 | **DGX ×2 文件系统指标（待重部署）** | `node-exporter-deploy.yml` 已含 `--path.rootfs=/host`，但 **live 跑的仍是修复前的旧容器**（2026-08-03 实测 `up==1` 却无 `node_filesystem_size_bytes`）。动作 = 在 `nv-dgx-spark` 对两台重跑 `make node-exporter-deploy`。macbook 缺 `node_memory_MemAvailable_bytes` 是 darwin 固有限制，不可修。 |
| 4 | **prometheus-operator CRD 补升** | 10 个 CRD 停在 v0.89.0、实际运行 v0.92.1（`helm upgrade` 从不升 chart 的 `crds/`）。两条路：去掉 `skipCrds` 让 ArgoCD 接管（推荐），或手工 `kubectl apply --server-side`。需单独维护窗口。（[决策](decisions/manual-helm-to-argocd-adoption.md)） |
| 5 | **DGX Spark 入编** | 推理服务 IaC + GPU 指标（dcgm）+ 双机 fallback + SLO。两台 GB10 已自组双节点 k3s + Cilium 1.19.6，当前只接了 node_exporter / smartctl。⚠️ 网络对接已有结论：**不接 ClusterMesh**，走 Tailscale + 手写 Endpoints（[决策](decisions/dgx-clustermesh-not-adopted.md)）。⚠️ vLLM 指标实际在 `:8000/metrics`，与 `nv-dgx-spark/config/vllm.env` 的 `VLLM_PROMETHEUS_PORT=8001` 不符；DGX2 引擎未起。（母文档 P1-5） |
| 9 | **jobs-sg 收尾** | 均不阻塞服务：① 周报 Telegram 已接好，只差端到端实测一次推送；② Grafana 面板未做（`jobs_sg_*` 已在采，可用 Explore）；③ `closed` 寿命口径 A/B 待观察 2–3 周再定。（[jobs-sg.md](reference/jobs-sg.md)） |
| 10 | **readlist 公开面缺准入过滤** | 公开面已多轮收窄（v0.3.0 catalog 收敛、v0.4.0 公开榜三份、v0.5.0 修两个「静默为 0」缺陷）。**仍未做修法①**：`internal/calibre` 读 tags 但不据此筛选，非书文档照样参与打分，碰巧上榜则 title+author 上公网，判据只有人眼。⚠️ 做 catalog SSR/sitemap 前应先补①，否则偶发泄漏会被搜索引擎收录固化。 |
| 11 | **readlist 边缘限流（Cloudflare Free 限制）** | Free 只允许 1 条 rate limiting 规则，已被 auth 端点 + Excalidraw collab relay 占用且共享计数器（见 [`waf.tf`](../cloudflare/terraform/waf.tf) 注释），"分档"做不到。**当前选择：先不做**，v0.2.0 已在应用侧堵掉自伤路径（published_run 缓存、ETag/304、不碰库的 `/livez`、读写超时），站点只读且单副本 500m 上限，剩余风险可接受。 |
| 12 | **低优先 / 可选** | **Renovate 只做完一半**：配置与 CI 已合入，但 GitHub App 仍未安装，至今一个 PR 都没开过（判据：`git ls-remote --heads origin` 无 `renovate/*`）。装 App 是纯人工一步（[决策](decisions/renovate-adoption.md)，状态 🚧）· MacBook `TargetDown` 静默规则 · Vault Dynamic Secrets（规模不需要）· Cloudflare Pro WAF。（母文档 P2） |

### 已知问题（不阻塞，无人认领）

- **ClusterMesh 是纯待命能力，缺自愈**（监测缺口已闭环）。2026-08-05 曾静默断开约一个月，
  根因是 apiserver up-but-stuck 且不自愈，配置从未丢过；重建靠
  `just connect-clustermesh <homelab-ts>:32379 <oracle-ts>:32379`。告警兜底与 oracle 侧 peer
  固化均已补齐。仍未做的是自愈：两集群 `service.cilium.io/global` Service 都是 0，
  ClusterMesh 纯待命，加自愈探针不划算；另一条路是明确退役它、跨集群一律走 NodePort。
  机制与判据见 [reference/tailscale-network.md](reference/tailscale-network.md)。

- **oracle-k3s：1 个 Docker Hub 镜像仍未被 Trivy 扫过**（`rsshub-browserless`，扫描 Job 因匿名
  拉取配额 FATAL）。**失败的扫描不会自动重试**，配额恢复后须人工推一次
  `kubectl --context oracle-k3s -n trivy-system rollout restart deploy/trivy-operator`。
  ⚠️ 在此之前 `TrivyImageCriticalVulnerabilities` 读到的 0 不覆盖这个镜像（告警只数现存
  报告，缺报告按 0 计入）。根治办法（给扫描 Job 配 Docker Hub 认证）已评估但刻意没做。
  → [reference/trivy-cve-ops.md](reference/trivy-cve-ops.md)

---

## 不做 / 已取消

| 项目 | 结论 |
|------|------|
| Cert-Manager (Let's Encrypt + DNS-01) | TLS 在 Cloudflare 边缘终结、集群内 HTTP，无内网直连 TLS 需求 → 纯负担 |
| Vault HA / auto-unseal | 单节点无 HA 意义；sealed 已被 ESO 告警覆盖 + 恢复路径已文档化，transit auto-unseal 要再养一个 Vault |
| Crossplane | 2026-07-07 否决：CF provider 已死 2 年、问题规模不匹配（单人静态云面）、控制面鸡生蛋、单节点内存开销。重评条件见 [ADR](decisions/crossplane-not-adopted.md) |
| Talos 迁移 | 2026-03 刚重建 Ubuntu 24.04 且流程已顺，单节点收益不抵成本。加第二台 worker 时重评（[演进路线 §五](plans/architecture/2026-07-07-tech-debt-and-evolution.md)） |
| Cilium External Workloads（NAS 入网） | 2026-03-19 取消：CRD 与 CLI 已从 Cilium 1.15+ 移除。若要限制 NFS 访问改用 `CiliumNetworkPolicy` + `fromCIDR`（[原方案](plans/archive/2026-03-15-cilium-external-workload-nas.md)） |
| 集群级网络默认拒绝 | **刻意延后**（非取消）：单用户威胁模型下横向移动收益边际低、debug 成本高。Hubble 已开做可见性，作为日后单 ns 灰度的前置。见 [security.md](reference/security.md) |
| homelab 多节点 HA / etcd 三节点 | 2026-07-04 否决：硬件不支持、单用户收益为零。正确形态是单节点 + 快速重建（`just homelab-recover` + restic）。加第二台 worker 时与 Talos 一并重评 |
| Thanos / Mimir / 指标对象存储长期化 | 2026-07-04 否决：双写复杂、搬迁窗口长，`retention` + `retentionSize` 够用。⚠️ 同批"LGTM 整体不搬"那半条**已被推翻**：Loki/Tempo 于 2026-08-02 迁 oracle，Prometheus/Grafana/Alertmanager 仍在 homelab |
| storage-106 并入 homelab 集群 | ⛔ 2026-08-13 已推翻并实施：106 上的 VM 以 `k8s-worker-106` 入编（**入编的是 VM 不是宿主**，原「计算压上 NFS 后端」的理由已不适用）。代价是 106 与 prod 的解耦被主动放弃（[ADR](decisions/storage106-as-homelab-worker.md) · [复盘](records/2026-08-13-k3s-worker-join-106.md)） |

---

## 已完成

> 一条一行。展开细节看链接：复盘在 `records/`，取舍在 `decisions/`，现状在 `reference/`。

### Phase 1：基础设施 ✅

Proxmox Terraform 预配 · Ansible 装 K3s · Helm 应用部署 · LGTM 可观测栈 ·
OTel Collector 替换 Promtail · Loki 面板 4 张（GitOps）· log-exporter sidecar 模式 ·
Oracle Cloud Free Tier K3s · 双集群 OTLP traces → Tempo

### Phase 2：密钥与 GitOps ✅

Vault 部署/初始化/解封 · ESO + `vault-backend` ClusterSecretStore · 全部应用密钥迁入 Vault ·
ArgoCD（auto-sync + selfHeal）· ArgoCD Image Updater（已于 2026-08-03 退役）

### Phase 3：多云与边缘安全 ✅

Tailscale 跨集群 Pod CIDR 路由 · 身份简化（保留 ZITADEL，移除共享入口层 SSO）·
信息管道 Miniflux → Redpanda Connect → KaraKeep（已于 2026-08-14 退役）·
Cloudflare Zone 级 WAF · Uptime Kuma · 双集群从 Flannel 迁 Cilium

### Phase 4：可靠性与备份 ✅

| 时间 | 项目 |
|------|------|
| 2026-03-08 | homelab Ubuntu 24.04 重建（K3s v1.34.5+k3s1 + Cilium 1.19.1）+ Cilium Gateway 恢复 |
| 2026-03-08 | Cilium ClusterMesh 双集群 connected + failover 验证 |
| 2026-03-19 | Loki compactor + retention 168h |
| 2026-06-04 | oracle-k3s 纳入 GitOps（hub-and-spoke，经 Tailscale）([计划](plans/networking/2026-06-04-oracle-k3s-argocd-gitops.md)) |
| 2026-07-05 | Kopia 整体移除（server + CronJob + PVC + Vault secret） |
| 2026-07-06 | **restic 备份上线**：双集群 CronJob 逻辑 dump → 106 ZFS 加密仓库；恢复演练同日通过 ([计划](plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md)) |
| 2026-07-06 | zpool/SMART 告警上线（`storage-alerts.yaml` 5 条） |
| 2026-07-11 | **存储本地化完成**：106 宕机 3 天后，剩余 PVC + 书库 24G 全迁 `local-path`，nfs-client 卸载 ([storage.md](reference/storage.md)) |
| 2026-07-18 | Alertmanager → 原生 `telegramConfigs`，gotify-bridge 下线 ([决策](decisions/alerting-telegram-migration.md)) |
| 2026-07-19 | **dead-man's switch 打通**：Watchdog → webhook → Uptime Kuma push → Telegram ([dead-mans-switch.md](reference/dead-mans-switch.md)) |
| 2026-07 | **Gotify 彻底退役**：三个消费者处理完后本体 + 路由 + DNS + SLO + backup 条目全删 ([决策](decisions/alerting-telegram-migration.md)) |

### Phase 5：生产加固 ✅

| 时间 | 项目 |
|------|------|
| 2026-06 | **集群内部安全加固**：PSA + Kyverno(Audit) + Trivy + kube-bench + 节点 CIS ([计划](plans/security/2026-06-16-k3s-security-hardening.md) · [security.md](reference/security.md)) |
| 2026-06 | **运行时检测**：Tetragon(homelab) + Falco(oracle) ([计划](plans/security/2026-06-18-runtime-detection.md)) |
| 2026-06-15 | Grafana 面板整改：按 folder 分组、多集群选择器、稳定 datasource uid ([计划](plans/observability/2026-06-15-grafana-dashboard-reorg.md)) |
| 2026-07-06 | **服务重定位脱离 homelab 故障域**：Gotify + ZITADEL → oracle-k3s ([计划](plans/apps/2026-07-04-zitadel-to-oracle-k3s.md)) |
| 2026-07-18 | **ZITADEL DB → CloudNativePG**：PG 15.4 → CNPG 1.30.0 + PG 17.6，停机 ~4.5 分钟 ([identity.md](reference/identity.md)) |
| 2026-07-19/20 | **external-dns 双集群全量** + 隧道改 `*.meirong.dev` 通配 → **新增子域名从此只写一个 HTTPRoute** ([决策](decisions/external-dns-adoption.md)) |
| 2026-07-30 | OpenCost 双集群成本归因 + KRR 周报右尺寸 ([OpenCost](plans/observability/2026-07-30-opencost-multicluster.md) · [KRR](plans/observability/2026-07-30-krr-rightsizing.md) · [决策](decisions/opencost-krr-data-sources.md)) |
| 2026-07-31 | **manual-helm → ArgoCD 采纳**：`kube-prometheus-stack` + `external-dns` ×2；chart 版本唯一真源改为 Application 的 `targetRevision` ([决策](decisions/manual-helm-to-argocd-adoption.md)) |
| 2026-07-31 | **OTel 2026 对齐**：homelab collector 首次落地（此前根本没部署，容器日志从未进 Loki）([决策](decisions/otel-2026-alignment.md)) |
| 2026-07-31 | `manifests/` 目录化（一目录一 App）+ `gateway.yaml` 按路由拆 5 文件 ([决策](decisions/manifests-directory-per-app.md)) |
| 2026-08-02 | **负载迁 oracle-k3s**：Loki+Tempo + ArgoCD 控制面（打破「homelab 死了 ArgoCD 也死了」的鸡生蛋）；途中修掉 tempo 跑在 emptyDir、oracle otel-collector 改 ConfigMap 不重启两个静默 bug ([方案](plans/architecture/2026-08-02-homelab-to-oracle-workload-migration.md) · [runbook](runbooks/argocd-control-plane-on-oracle.md)) |
| 2026-08-02 | **OOM 盲区闭环**（起因：ArgoCD controller 静默 OOMKilled 无告警）：抬 limit + 新增 `ContainerOOMKilled` + `metal-nodes-resources` 组补齐 pve/106/DGX ([告警](reference/observability-alerting-slo.md) · [QoS](reference/k8s-qos-resource-management.md)) |
| 2026-08-03 | **calibre 迁 oracle-k3s**：书库 23G，homelab 磁盘 65%→32%。⚠️ 退役步骤触发级联删除事故，已从 restic 完整恢复并把 4 处内嵌 Namespace 拆成专职文件 ([复盘](records/2026-08-03-namespace-prune-cascade.md)) |
| 2026-08-03 | **PSA `backup` ns 定级闭环**：双集群均 `enforce: privileged`（走特权/豁免路径），从开放项移除（原 #7） |
| 2026-08-03 | **DGX vLLM metrics 探明**（供 #5 入编用）：DGX1 `:8000/metrics` live，DGX2 引擎未起；实测端口与 `vllm.env` 声明不符（详见开放项 #5） |
| 2026-08-06 | **共享 PostgreSQL 平台**：手搓 `rss-postgres` → CNPG `apps-pg`（PG17），逐表对账。刻意不并入 `zitadel-pg`（SSO 库带 `critical`，合库=让 RSS 抢同一个 limit）([决策](decisions/shared-postgres-platform.md)) |
| 2026-08-06 | **PriorityClass 去个人前缀**：`meirong-*` → `critical`/`high`/`bulk`，33 处引用，三步走（PriorityClass 与工作负载分属不同 App，同步无先后保证）([QoS](reference/k8s-qos-resource-management.md)) |
| 2026-08-08 | **jobs-sg 缺陷收口**：修掉 `JobsSgReconcileStale`/`JobsSgIngestStale` 结构性哑火、`work_mode` 拿排班冒充办公地点、写事务撞锁重跑 ([诊断](plans/apps/2026-08-08-jobs-sg-three-defect-diagnosis.md)) |
| 2026-08-08 | **旧 LLM 网关注册退役**：整个 ArgoCD App（网关 + oauth2-proxy + dgx-proxy）删除，由 LiteLLM 接替 ([计划](plans/apps/2026-08-01-litellm-gateway-migration.md)) |
| 2026-08-09 | **探针误杀修复 ×2**：Uptime Kuma（4 天 11 次重启）与 ZITADEL login（27 次）补 `startupProbe` |
| 2026-08-09 | **readlist v0.5.0**：修掉 C/F 两个「静默为 0」结构性缺陷；补 2 条判别力告警（7→9 条） |
| 2026-08-09 | **Cilium identity-mark 撞 Tailscale fwmark**：位段冲突（单 pod 到 `100.64/10` 全超时的 1/256 抽签）([tailscale-network.md](reference/tailscale-network.md)) |
| 2026-08-09 | **oracle journald 持久化**：非正常重启的现场不再每次蒸发 |
| 2026-08-09 | **告警盲区闭环**：DGX 内存告警改 PSI+OOM、补 `NodeRebooted`；dead-man's switch 投递失败不再冒充「告警链路坏了」 |
| 2026-08-10 | **PSA 收口**：`zitadel` ns 从无标签推到 restricted（先补 `securityContext` 再翻 enforce，顺序反了会挡住 Job）+ 清单外 ns 全补齐 + `just psa-check` 漂移哨兵 + CI 规则 H5 ([security.md §5.1](reference/security.md) · [H5](reference/manifest-safety-checks.md)) |
| 2026-08-10 | **KRR 首轮完整分诊**：BestEffort pod oracle 15→5 / homelab 9→1，oracle CPU requests 83%→71%。真正的收获是照出**三处「配置在 git 里却从未生效」**（Helm 静默忽略写错层级的键）([runbook](runbooks/krr-report-triage.md)) |
| 2026-08-10 | **QoS 与 Pod Priority 两条实测推论**：BestEffort 会让 `priorityClassName` 整行失效；带 `system-*-critical` 的 Pod 即使 BestEffort 也排最后 ([QoS](reference/k8s-qos-resource-management.md)) |
| 2026-08-10 | **OOM 告警补齐事前一环**：新增 `ContainerMemoryNearLimit` + `ContainerOOMKilledCadvisor`。⚠️ 同时记录覆盖口径：oracle 侧部分 `container_*` 不进中枢 Prometheus，空结果与「值为 0」外观一致，当天据此误判过一次 ([QoS](reference/k8s-qos-resource-management.md)) |
| 2026-08-10 | **Cilium 双集群 1.19.1→1.20.0**（计划外）：oracle 的 `deploy-cilium` 缺 `--version`，例行部署随 `helm repo update` 静默升版；连带发现 `--reset-values` 会冲掉 clustermesh 的跨集群 CA 信任，唯一真判据是 `cilium status` 的 `retrieved=false` ([tailscale-network.md](reference/tailscale-network.md)) |
| 2026-08-10 | **homelab PriorityClass 分档补齐**（原 #9）：15/36 → 27/36。kyverno 敢归 `bulk` 的判据是实测 webhook `failurePolicy` 为 Ignore = 真 fail-open；sloth 是「设不了」那一类 ([QoS](reference/k8s-qos-resource-management.md)) |
| 2026-08-10 | **CPU limit 的反向陷阱**：node-exporter 配 `200m` 后节流 31%（1m 峰值仅 3m，采集型是亚秒突发，CFS 掐得住而 1m rate 看不见），已撤回；kube-state-metrics 同 limit 实测 0% 故保留。**必须逐个实测** ([runbook](runbooks/krr-report-triage.md)) |
| 2026-08-12 | **oracle DNS 上游冗余真正生效**（原 #8）：此前的 `FallbackDNS=` 是无效修复（不进 `resolv.conf`，而 kubelet 喂 CoreDNS 的正是该文件），与「已修」的自我认知并存了十来天。改 `DNS=` + 重建 CoreDNS pod，并做了掐断演练实证 ([复盘](records/2026-08-01-oracle-k3s-dns-outage.md)) |
| 2026-08-16 | **LiteLLM LLM 网关落地**：`llm.meirong.dev` 上线（DGX 主 + Mac 兜底 fallback），旧网关全线退役 ([决策](decisions/litellm-llm-gateway.md) · [网关事实](reference/litellm-gateway.md)) |
| 2026-08-23 | **集群外三站点补上可用性监控**（原 #13）。☠️ 顺带揪出 uptime-kuma provisioner 一个静默滞后 bug：`add_monitor()` 后 `get_monitors()` 看不见刚建的监控，状态页**落后一次运行**而三条日志全绿 ([决策](decisions/home-stack-repo-boundary.md) · [services.md](reference/services.md)) |
| 2026-08-24 | **capacity 两条告警改为覆盖两集群**（原 #14）：`Homelab*` → `Cluster*RequestsSaturated`，`sum()` 改 `sum by (cluster)`。**教训：写死集群的选择器会在采集面变化后静默失效** ([告警](reference/observability-alerting-slo.md)) |
| 2026-08-24 | **external-dns 元故障告警改为覆盖两集群**（原 #7）：改法刻意不是加一条 `absent(...)`（覆盖 N 集群要硬编码 N 个名字），而是 `count by (cluster) … unless …` 拿 deployment 副本数作参照，自维护且语义更准 ([决策](decisions/external-dns-adoption.md)) |
| 2026-08-25 | **Nakama 游戏后端上线**：3.40.0，**无 PVC**，状态全在 `apps-pg` 第三个租户。密钥走 ESO 渲染整份 `config.yml` 挂成文件，不进命令行（Nakama 的密钥都是 flag）。☠️ 管理台裸挂公网只有自带口令，已记入 [security.md 已知缺口](reference/security.md) · [services.md](reference/services.md) |
| 2026-08-25 | **homelab 两个 Postgres 收敛成一个**：`litellm-pg` + `multica-postgres` → `databases/apps-pg`，逐表对账。**刻意不装 CNPG**（operator 自身开销比省下的 postmaster 还贵），所以两集群的 `apps-pg` 同名同角色但形态不同 ([决策四](decisions/shared-postgres-platform.md)) |
| 2026-08-26 | **接上 godot-games**：Nakama 挂服务端 Lua 模块（initContainer 从 OCI 镜像拷入，换 tag 即发版）+ 按契约设 `runtime.lua_{min,max}_count`（**必须成对**，只调 max 直接启动失败）+ 新服务 `game.meirong.dev` ([services.md](reference/services.md)) |
| 2026-08-27 | **游戏大厅打通**：`game.meirong.dev` 的 HTTPRoute 变三条规则（`/v2/*` + `/ws` → nakama，其余静态站）。☠️ **上游 e2e 直连 nakama 域名、结构上绕过这两条**，路由漏写 e2e 照样全绿，唯一判据是用浏览器真开一次 ([services.md](reference/services.md)) |

### 审计与清理（历史）

| 时间 | 内容 |
|------|------|
| 2026-07-07 | repo↔集群一致性清零：helm pin 对齐、homelab postgres 残留移除、ReferenceGrant v1beta1、gotify-bridge 双 App 争抢去重 |
| 2026-07-12 | 双集群清理审计：孤儿 Job×7 / 0 副本 RS×97 / 未用镜像 ≈19G；**falco inotify 根因修复**（默认 `max_user_instances` 128 导致崩了 23 天）([security.md](reference/security.md)) |
| 2026-07-12 | justfile 卫生：`deploy-prometheus` 双 `--version` 去重、`loki_version` 对齐 ArgoCD、Kopia 退役残留清除 |
| 2026-07-12 | 仓库级第二轮审计：**`sync-ebooks.sh` 真实 bug**（checksum 在孤儿 NFS 快照副本上核对，全程报绿但书从未入库）· PSA 清单漂移补 `kube-bench` · 死链修正 · 6 个 terraform root 的 lock 文件纳入版本控制 |
| 2026-07-12 | **Tailscale 根因修复**：mbpm5 停止广播 `192.168.50.0/24`，pve 保留为唯一 subnet router。`nfs-lan-route` ip-rule 经实测裁定**永久保留** ([tailscale-network.md](reference/tailscale-network.md)) |
| 2026-07-18 | **Vault 孤儿 secret 清理**：交叉核对后销毁 4 个无消费者的 path，剩余 16 个全部有消费者。⚠️ `secret/homelab/zitadel` 是活的，别和已删的 `zitadel-oidc` 搞混 |
| 2026-07-31 | 本地明文 Vault 清单 `vault_values.md` 实际删除。⚠️ 此前 07-18 就声明"已删除"但文件一直在磁盘上。它是 gitignored 的，**删除不产生 diff，所以声明落空没人发现** ([security.md §4](reference/security.md)) |
| 2026-08-03 | **ArgoCD Image Updater 退役**：0 个 CR、空转数月的控制器卸载，旧式注解一并移除。机制文档保留 ([决策](decisions/argocd-image-updater.md)) |
| 2026-08-06 | **oracle VM 清理**：`crictl rmi --prune` 删 32 个死镜像，回收 9GB。积压原因是镜像 GC 为阈值触发（磁盘 85%）而实际才 37%，**从未跑过** ([清理表](runbooks/stateful-service-cross-cluster-migration.md)) |
| 2026-08-06 | **image-updater 残留凭据清除**：退役 3 天后 kustomize 树里仍在**每分钟从 Vault 拉一次 GitHub 凭据**，产出两个无人消费的 Secret |
| 2026-08-06 | **孤儿资源复跑**（控制面迁 oracle 后首次双集群跑）：信号面各 6 条，**真孤儿 0 条**。另汇总 4 条永久孤儿（不入 git 的 bootstrap 依赖），刻意不进 ignore，那份清单就是「从 Git 重建会缺什么」([决策](decisions/orphaned-resources.md)) |
| 2026-08-13 | **月度恢复演练自动化**（原 #6）：`restic-restore-drill` CronJob 每月真恢复 + 8 条判据，配 3 条告警。☠️ 判据敏感度用损坏数据逐条实测，7 种坏法全判出 ([storage.md](reference/storage.md)) |
| 2026-08-13 | **Renovate + 版本配对 CI**（原 #12 之一）：`renovate.json5` + `check-version-pairs.py` 的 V1-V3，六个破坏场景实测全判红。⚠️ **仍待人工装一次 GitHub App** 才会真正开 PR ([决策](decisions/renovate-adoption.md)) |
| 2026-08-14 | **信息管道（Miniflux→KaraKeep）退役**：两个 Deployment + 路由 + 监控 + 备份白名单全删，Miniflux/RSSHub 保留；释放 oracle ~1Gi requests ([原方案](plans/archive/2026-02-28-info-pipeline-miniflux-karakeep-gotify.md)) |
