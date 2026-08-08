# Homelab Roadmap

> Last updated: 2026-08-06
> 本文只回答两件事：**还剩什么没做**，和**做过什么/为什么不做**。
> 实施细节不写在这里——每条都链到 `decisions/`（取舍）或 `plans/`（执行过程）。
>
> 相关：[技术债盘点与演进路线](plans/architecture/2026-07-07-tech-debt-and-evolution.md)（工具链层，含 Crossplane 否决结论）·
> [机器与集群架构优化](plans/architecture/2026-07-04-fleet-architecture-optimization.md)（物理层，编号 P0-x/P1-x/P2-x 出自这里）

---

## 开放项

> ✅ **已完成（2026-08-05/06）**：oracle-k3s 缩容 4 OCPU/24GB → **2/12** 已 apply 并核实
> （实测 `capacity.cpu=2`、`allocatable.cpu=1800m`、`capacity.memory≈11.6Gi`）。
> 前置改动（requests 2712m→1372m、`bulk` 分档、hugepages 回收、`system-reserved`）也已生效。
> 过程/验证/回滚留档在 [runbooks/oracle-k3s-shape-downsize.md](runbooks/oracle-k3s-shape-downsize.md)。
> ⚠️ **这是单向操作**：ap-osaka-1 的 A1 长期没容量，涨回去不保证做得到 —— 所以
> **新服务别再按"容量宽裕"来规划**，requests 按实测填，非核心的挂 `bulk`。

按优先级排列。括号内是出处文档。

| # | 项目 | 说明 |
|---|------|------|
| 1 | **离站备份** | restic 仓库 → 云（OCI always-free / B2，`rclone` 或 `restic copy`）。当前只有 106 本地副本，火灾/失窃即全损。需人工先开云桶。（[方案](plans/storage/2026-08-03-offsite-backup.md) · [2026-07-06 计划 Phase 5](plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md)，母文档 P0-1） |
| 2 | **Terraform state → R2** | 5 个 root 全本地 state：笔记本单点、无锁、含明文密钥。顺带可评估 OpenTofu + `use_lockfile`。（[方案](plans/architecture/2026-08-03-tf-state-r2.md) · [演进路线 Phase A](plans/architecture/2026-07-07-tech-debt-and-evolution.md)） |
| 3 | **DGX ×2 文件系统指标（待重部署）** | `nv-dgx-spark` 的 `node-exporter-deploy.yml` **已含** `-v /:/host:ro,rslave` + `--path.rootfs=/host`，但 **live 未生效**：2026-08-03 实测两台 DGX node-exporter 均 `up==1`，`count by (job)(node_filesystem_size_bytes)` 仍无 `node-exporter-dgx-spark`——现网跑的仍是修复前的旧容器。动作 = 对两台机重跑 `make node-exporter-deploy`（`cd /Users/matthew/projects/meirongdev/nv-dgx-spark`）。同理 macbook 无 `node_memory_MemAvailable_bytes`（darwin 固有限制，不可修）。 |
| 4 | **prometheus-operator CRD 补升** | 集群 10 个 `monitoring.coreos.com` CRD 停在 operator v0.89.0，实际运行 v0.92.1——`helm upgrade` 从不升级 chart 的 `crds/`。采纳进 ArgoCD 时刻意 `skipCrds: true` 把它与迁移解耦。两条路：去掉 `skipCrds` 让 ArgoCD 接管（推荐，之后随 chart 自动跟进），或手工 `kubectl apply --server-side`。需单独维护窗口验证。（[manual-helm 采纳决策](decisions/manual-helm-to-argocd-adoption.md)） |
| 5 | **DGX Spark 入编** | 推理服务 IaC + GPU 指标（dcgm）+ 双机 fallback + SLO。当前两台 GB10（各 128GB）只接了 node_exporter / smartctl_exporter。（母文档 P1-5） |
| 6 | **恢复演练自动化** | 月度 CronJob 自动校验 restic restore，取代手工演练。（母文档 P2-8） |
| 7 | **oracle external-dns 可观测** | homelab 的 4 条 external-dns 告警规则限定 `cluster="homelab"`，未覆盖 oracle 实例；需 oracle OTel 抓 `:7979`。非阻塞。（[external-dns 决策](decisions/external-dns-adoption.md)） |
| 8 | **oracle-k3s 外部 DNS 冗余** | 单点上游 `169.254.169.254:53` 曾致全网 ~20min 不可达（2026-08-01）。给节点 `resolv.conf` / CoreDNS `forward` 加备用上游（如 1.1.1.1），顺带降低 cloudflared 崩溃率。**仍在发作**：2026-08-03 复核，oracle 两个 cloudflared 副本 26d 各重启 24/28 次（homelab 侧 0 次）。（[复盘](records/2026-08-01-oracle-k3s-dns-outage.md)） |
| 9 | **PriorityClass 覆盖不全（homelab 侧）** | oracle 侧 2026-08-05 随缩容做完了四档（`critical`/`high`/默认/新增 `bulk` -10），**homelab 只有 8/38 运行 pod 有优先级**（2026-08-06 实测；Vault ×2、external-dns、cloudflared×2，当日新增 opencost / trivy-operator / trivy-server 三个 `bulk`），Prometheus/Grafana/Alertmanager 仍在 priority 0，与个人服务同级。homelab 内存压力比 oracle 更紧（7d 最低 MemAvailable 3.31G / 12.66G），照 oracle 的分档补一遍即可。两处**设不了**已确认并记录：ZITADEL（chart 9.34.1 无此 values 键）、timeslot（仓库外手工 Helm release）。模型见 [reference/k8s-qos-resource-management.md](reference/k8s-qos-resource-management.md)。 |
| 10 | **jobs-sg 收尾（2026-08-03 上线）** | 三项，均不阻塞服务：① **周报 Telegram 已接好**（bot token 复用 `secret/homelab/telegram`、chat id 与 thread id 明文，投群里的 `jobs-sg` 话题 thread 552）；尚未做的只是**端到端实测一次推送**——首次由周一 01:00 UTC 的 CronJob 触发。② **Grafana 面板未做**（`jobs_sg_*` 已在采，可用 Explore）。③ **`classify.WorkMode` 分类法缺口** —— 只认 `remote/hybrid/onsite`，MCF 真实标签是 "Creative Scheduling"/"Flexi-place"，故所有岗位 `work_mode` 都是 `Onsite`（上游应用问题，非部署问题；三项里只有这条有实际产品影响）。（[reference/jobs-sg.md](reference/jobs-sg.md)） |
| 11 | **readlist 公开面缺准入过滤（修法②已落地，①仍未做）** | 2026-08-06 `readlist.meirong.dev` 已公开。**已处理（其一）**：此前出现在公开 catalog 里的第三方简历（BHRC / Mint Wu）已从 calibre 移除，重跑 score 后全部公开端点核验 0 命中。**已处理（其二）**：**修法② 随 v0.3.0 落地**（`feat(api)!`，2026-08-06 部署）——`/api/v1/catalog` 从「全库 2,045 本」收窄成「**7 个公开榜的并集**」，实测**只剩 22 本**（5 个公开榜是空的：`readlist_dim_measured` 实测 A=39 C=0 D=0 F=338 T=1334，而 timeless 需 A+C、deep-dive 需 D、ship-this-week 需 F+P、read-and-loved 需 A+T+D，ai-llm 的主题分类也靠 LLM 标注；那 5 个榜升级前就是空的，v0.3.0 只是不再拿全库目录盖住）；`/api/v1/matrix/{run}` 直接删除；两个 `visibility: internal` 榜（publisher-picks / library-hygiene）不进公开集合，其中 library-hygiene 恰是「元数据最差的书」，本就最不该外发。**仍未处理**：修法① 准入过滤没做（`internal/calibre` 读了 tags 但不据此筛选），所以非书文档照样参与打分，**只要碰巧上了任一公开榜，title+author 仍会上公网**——收窄把命中概率从「必然」降到「偶然」，判据依旧只有人眼。⚠️ 上游 `review-2026-08-05-b` 的 C1（catalog 做 SSR + sitemap）的硬前置**已解除**，但做 SSR 前仍建议先补①，否则偶发泄漏会被搜索引擎收录固化。 |
| 12 | **readlist 边缘限流（受 Cloudflare Free 限制）** | 上游 NFR-14 要求分档限流（页面一档、`/api/` 更严一档），**Free 计划只允许 1 条 rate limiting 规则**，而那唯一一条已被 auth 端点 + Excalidraw collab relay 占用且共享计数器（见 [`waf.tf`](../cloudflare/terraform/waf.tf) 注释）。所以「分档」在 Free 上做不到。三选一：把 `readlist.meirong.dev/api/` 并入现有那条（单档、共享计数、30 req/10s，改动会影响全站 auth 防爆破的语义）· 升 Pro（另见第 11 项母条目里的 Cloudflare Pro WAF）· 或先不做（**当前选择**）。理由：v0.2.0 已在应用侧堵掉自伤路径——published_run 进程内缓存、ETag/304（实测经 Cloudflare 仍回 304/0 字节）、不碰库的 `/livez` 存活探针、HTTP 读写超时；边缘限流原本主要就是防那条。站点只读、单副本 500m CPU 上限，剩余风险可接受。 |
| 13 | **低优先 / 可选** | Renovate（chart/image 版本自动 PR）· MacBook `TargetDown` 静默规则 · Vault Dynamic Secrets（PostgreSQL 动态凭据，规模不需要）· Cloudflare Pro WAF（Managed Ruleset + OWASP CRS）。（母文档 P2） |

### 已知问题（不阻塞，无人认领）

- **ClusterMesh 静默断开无人知晓（已修，但监测缺口仍在）**。2026-08-05 缩容验收时发现
  两集群都是 `0/1 remote clusters ready`；当天用
  `just connect-clustermesh 100.94.186.7:32379 100.107.166.37:32379` 修好，双向
  `retrieved=true` + 数据同步全 true（oracle 见 homelab 33 endpoints，homelab 见 oracle 48）。
  机制、正确的诊断判据、以及两个 secret 的分工见
  [reference/tailscale-network.md](reference/tailscale-network.md#两个-secret别把正常的当成配错了2026-08-05-踩过)。

  **两个缺口 2026-08-05 当天都已补完**：
  - **告警**：抓 kvstoremesh `:9964`（homelab ServiceMonitor + oracle otel
    `prometheus/clustermesh`）+ 5 条规则，见
    [observability-alerting-slo.md](reference/observability-alerting-slo.md)。
  - **oracle 侧 peer 固化**：`cloud/oracle/values/cilium-values.yaml` 补上
    `clustermesh.config.clusters`（+ 三个容器的 resources，此前是 BestEffort）。
    该目录的 `just deploy-cilium` 带 `--reset-values`，之前跑一次就会删掉对端条目。
    已用 `helm template` 验证渲染出的 `hostAliases` 与 live 一致。

  ⚠️ **根因更正（当天连着说错三次，以 helm release 历史为准）**：**配置从来没丢过**。
  oracle 的 peer 条目自 `cilium.v11`（2026-03-15）、homelab 自 `cilium.v10`（2026-04-27）
  起就一直正确，直到断开时的 v15 都在。所以既不是"endpoint 写成集群内 DNS 名"
  （那是 KVStoreMesh 的正常形态），也不是"升级把配置抹了"。真实情况是
  **clustermesh-apiserver 卡在 up-but-stuck 且不自愈**——修好它的是
  `cilium clustermesh connect` 顺带触发的 helm upgrade **重建了 homelab 那个 pod**
  （新 pod `restarts=0`），配置一字未改。**教训**：先看 helm release 历史再下根因结论，
  别从当前状态倒推。

  仍未做的是**自愈**：卡死没有自动恢复，只有告警 + 人工跑一次 `just connect-clustermesh`。
  两集群 `service.cilium.io/global` 的 Service 数量**都是 0**（没有工作负载在用跨集群服务
  发现，遥测与 ArgoCD→homelab 走 Tailscale + NodePort 直连），ClusterMesh 是**纯待命
  能力**，为它加自愈探针不划算。另一条路是明确退役 ClusterMesh、跨集群一律走 NodePort，
  那这条连同那 5 条告警一起消失。

- **这台 Mac 上 `terraform plan/apply` 连 `192.168.50.4:8006`（Proxmox API）100% `no route to host`**，但 `ping`/`curl`/`ssh` 到同一地址全部正常（curl 有响应，偏慢 ~3s）。**已排除 Tailscale**——整个 `tailscale down` 后仍 100% 复现。当前无阻塞（VM 变更改走 `qm`/SSH）。若日后要用 terraform 管 Proxmox，从 provider 的 HTTP client 行为或本机残留 utun0-3/网络扩展查起，不是标准路由表问题。

- **oracle-k3s：3 个 Docker Hub 镜像仍未被 Trivy 扫过，等配额恢复后重试一次**（2026-08-05）。
  `rsshub-browserless`(browserless/chrome)、`stirling-pdf`(stirlingtools/stirling-pdf)、
  `redpanda-connect`(docker.redpanda.com/redpandadata/connect) 三者的扫描 Job 均因
  `TOOMANYREQUESTS: unauthenticated pull rate limit` FATAL。配额是 Docker Hub 匿名的
  **100 pulls / 6h / IP**，当天被清 73 条 Critical 时的强制重扫（删 6 份报告 + 3 次
  operator 重启）打空了。**失败的扫描不会自动重试**（详见
  `reference/security.md` §6），所以配额恢复后必须人工推一次：

  ```bash
  kubectl --context oracle-k3s -n trivy-system rollout restart deploy/trivy-operator
  # 6-8 分钟后回查（这 3 个镜像都很大，单个扫描要几分钟）
  kubectl --context oracle-k3s get vulnerabilityreports -A -o json | jq -r \
    '.items[] | select(.metadata.labels."trivy-operator.resource.name"
     | test("browserless|stirling|redpanda")) | "\(.metadata.labels."trivy-operator.resource.name") crit=\(.report.summary.criticalCount)"'
  ```

  ⚠️ 在此之前 `TrivyImageCriticalVulnerabilities` 读到的 0 **不覆盖这 3 个镜像**——
  告警只数现存报告，缺报告按 0 计入。根治办法（给扫描 Job 配 Docker Hub 认证，
  `trivy.privateRegistryScanSecretsNames`）已评估但**刻意没做**：需要新增 Docker Hub
  凭据，当前判断不值得为 3 个镜像引入。

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
| 2026-08-03 | **calibre 迁 oracle-k3s**：书库 23G + config，homelab 磁盘 65%→**32%**（可用 43→84GB）。arm64 镜像 digest 原样复用（已核实是多架构 list）。⚠️ 退役步骤触发事故：Namespace 内嵌在 calibre-web.yaml 里，删文件 prune 掉整个 ns → 级联删光同 ns 的 open-notebook 数据；已从 restic 完整恢复，并把全仓库 4 处同类内嵌 Namespace 拆成专职文件。([复盘](records/2026-08-03-namespace-prune-cascade.md)) |
| 2026-08-03 | **PSA `backup` ns 定级闭环**：homelab + oracle 的 `backup` ns 均已 `enforce: privileged`（走的就是特权/豁免路径）。无需再纳入 `psa_baseline_ns`，从开放项移除（原 #7）。 |
| 2026-08-03 | **DGX vLLM metrics 探明**（供开放项 #5 入编用）：DGX1 `:8000/metrics` live（`deepseek-v4-flash`：2278 请求完成、KV 缓存 72%、TTFT 均值 ≈19.8s）；DGX2 `vllm_node` 容器 up 但**无任何监听端口、引擎未起**（8000/8001/30000 全 HTTP000）。⚠️ 实测暴露端口是 `:8000/metrics`，与 `nv-dgx-spark/config/vllm.env` 里写的 `VLLM_PROMETHEUS_PORT=8001` **不符**。 |
| 2026-08-02 | **负载迁 oracle-k3s**：Loki+Tempo（日志/追踪汇聚点搬到云端，homelab 整机故障时故障前的日志还在）+ ArgoCD 控制面（打破「homelab 死了 ArgoCD 也死了、必须人工 bootstrap 才能拉回来」的鸡生蛋）。Pod 层面释放 1.0 GB；旧实例与域名均已退役，28/28 App Synced。途中修掉两个既有静默 bug：tempo `persistence` 写错层级导致一直跑在 emptyDir 上、oracle otel-collector 裸 manifest 改 ConfigMap 不触发 Pod 重启（改用 kustomize configMapGenerator）。([方案+实测](plans/architecture/2026-08-02-homelab-to-oracle-workload-migration.md) · [runbook](runbooks/argocd-control-plane-on-oracle.md)) |
| 2026-08-02 | **OOM 盲区闭环**（起因：`argocd-application-controller` 当天 10:01:47Z 静默 OOMKilled，无任何告警，靠人工翻 `lastState` 才发现）：① ArgoCD controller limit `1Gi→1536Mi`（同一故障 512Mi→1Gi 后在 App 数涨到 28 + CNPG/OpenCost 大 CRD 时复发；实测非泄漏，是 reconcile 尖峰，2d 峰值达 limit 94%）② 新增 `ContainerOOMKilled` 告警——此前**零条规则**引用 `kube_pod_container_status_last_terminated_reason`，且 `KubePodCrashLooping` 结构上抓不到（OOM 后干净重启不进 `CrashLoopBackOff`）③ 新增 `metal-nodes-resources` 组补齐 pve/106/DGX 的内存与文件系统告警——chart 的 node-exporter mixin 全部硬编码 `job="node-exporter"`，此前这几台机（含承载整个集群的 hypervisor）只有 `up==0`。阈值按主机分别实测标定，详见 [reference/observability-alerting-slo.md](reference/observability-alerting-slo.md) 与 [k8s-qos-resource-management § 检测 OOMKill](reference/k8s-qos-resource-management.md) |
| 2026-08-06 | **共享 PostgreSQL 平台**：手搓的 `rss-postgres`(Deployment/PG15/外挂 exporter/`Recreate` 防双写) → CNPG `apps-pg`(PG17，`databases` ns)，miniflux 库经 `bootstrap.initdb.import` 逻辑迁入并逐表对账（14 表 13 表精确一致，唯一差异是运行中的 miniflux 新建会话）。**刻意不并入 `zitadel-pg`**：limits 超卖 224% 且 SSO 库带 `critical`，合库等于让 RSS 负载和 SSO 抢同一个 memory limit。以后应用要库 = 加 `Database`/`DatabaseRole` CR，不再自带实例 ([决策](decisions/shared-postgres-platform.md)) |
| 2026-08-06 | **PriorityClass 去个人前缀**：`meirong-{critical,high,bulk}` → `critical`/`high`/`bulk`，33 处引用。三步走（加新 class → 改引用 → 删旧），因为 PriorityClass 与引用它的工作负载分属不同 ArgoCD App、同步无先后保证。收尾时三处不跟 GitOps 滚需单独处理：Vault(manual-helm **且 STS 是 OnDelete**，helm upgrade 不重启 pod)、ArgoCD(不自管自己)、`zitadel-pg`(CNPG 不为 priorityClassName 变更滚动) |

### 审计与清理（历史）

| 时间 | 内容 |
|------|------|
| 2026-07-07 | repo↔集群一致性清零：helm pin 对齐、homelab postgres 残留移除、ReferenceGrant v1beta1、gotify-bridge 双 App 争抢去重 |
| 2026-07-12 | 双集群清理审计：孤儿 Job×7 / 0 副本 RS×97 / 未用镜像 ≈19G；**falco inotify 根因修复**（`fs.inotify.max_user_instances` 默认 128 导致崩了 23 天）+ ansible 固化；7 条 SLO errorQuery 空集加固；`NFSStorageNodeDown` → `BackupTargetNodeDown` 降级 |
| 2026-07-12 | justfile 卫生：`deploy-prometheus` 双 `--version` 去重、`loki_version` 对齐 ArgoCD、Kopia 退役残留清除 |
| 2026-07-12 | 仓库级第二轮审计：**`scripts/sync-ebooks.sh` 真实 bug**（写入迁移前遗留的孤儿 NFS 快照目录，checksum 在副本上核对、全程报绿但书从未入库；已删整条 NFS 路径改走 `kubectl cp`）· PSA 命名空间清单漂移补 `kube-bench` · 死链修正 · 脚本引号/`mktemp` 硬化 · 6 个 terraform root 的 `.terraform.lock.hcl` 纳入版本控制 |
| 2026-07-12 | **Tailscale 根因修复**：mbpm5 停止广播 `192.168.50.0/24`，pve 保留为唯一 subnet router。`nfs-lan-route` ip-rule 经 2026-07-19 实测裁定**永久保留**，理由见 [tailscale-network.md](reference/tailscale-network.md) |
| 2026-07-18 | **Vault 孤儿 secret 清理**：全 Vault × 两集群 ExternalSecret 交叉核对，销毁 4 个无消费者的 path（`homelab/postgres`、`homelab/zitadel-oidc`、`oracle-k3s/oauth2-proxy`、`homelab/kopia`）。剩余 16 个 path 全部有消费者。⚠️ `secret/homelab/zitadel` 是活的（oracle 3 个 ExternalSecret + 跨集群 backup 读它） |
| 2026-07-31 | 本地明文 Vault 清单 `k8s/helm/values/vault_values.md` 实际删除。⚠️ 此前 07-18 就声明"已删除"但文件一直在磁盘上——它是 gitignored 的，删除不产生 diff，所以声明落空没人发现。约定见 [reference/security.md §4](reference/security.md) |
| 2026-08-03 | **ArgoCD Image Updater 退役**：0 个 `ImageUpdater` CR、空转数月的控制器卸载（删 `argocd/applications/argocd-image-updater.yaml` App + `k8s/helm/values/argocd-image-updater.yaml`），`oracle-k3s` App 上遗留的旧式注解一并移除（那个 controller 没了注解即死配置）。机制文档保留在 [decisions/argocd-image-updater.md](decisions/argocd-image-updater.md)，日后要自动升级可重新接入或走 Renovate（见开放项 #10）。 |
| 2026-08-06 | **oracle VM 清理**：`crictl rmi --prune` 删 32 个死镜像（96→64），磁盘 71G→62G 回收 **9GB**（containerd 37G→28G）。积压原因是 kubelet 镜像 GC 为阈值触发（`imageGCHighThresholdPercent` 85%）而磁盘才 37%，**从未跑过**。⚠️ 首轮报一屏 `DeadlineExceeded` 是 crictl 默认调用超时仅 2s，containerd 实际删成了 |
| 2026-08-06 | **image-updater 残留凭据清除**：退役 3 天后 `cloud/oracle/manifests/argocd/image-updater-secrets.yaml` 仍在 kustomize 树里，**每分钟从 Vault 拉一次 GitHub 凭据**产出两个无人消费的 Secret。⚠️ 其一名为 `git-creds`，确认过它没有 `argocd.argoproj.io/secret-type` 标签、ArgoCD 不认作仓库凭据才删 |
| 2026-08-06 | **孤儿资源复跑**（控制面迁 oracle 后首次双集群跑）：信号面各 6 条，**真孤儿 0 条**。补 3 条结构性 ignore（Vault 两个 volumeClaimTemplate PVC、CNPG 的 `cnpg-default-monitoring`）；另汇总 4 条**永久孤儿**（不入 git 的 bootstrap 依赖），刻意不进 ignore —— 那份清单就是「从 Git 重建会缺什么」([决策](decisions/orphaned-resources.md)) |
