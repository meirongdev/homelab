# Homelab Roadmap

> Last updated: 2026-08-27
> 本文只回答两件事：**还剩什么没做**，和**做过什么/为什么不做**。
> 实施细节不写在这里——每条都链到 `decisions/`（取舍）或 `plans/`（执行过程）。
>
> 相关：[技术债盘点与演进路线](plans/architecture/2026-07-07-tech-debt-and-evolution.md)（工具链层，含 Crossplane 否决结论）·
> [机器与集群架构优化](plans/architecture/2026-07-04-fleet-architecture-optimization.md)（物理层，编号 P0-x/P1-x/P2-x 出自这里）

---

## 开放项

> ✅ **已完成（2026-08-05/06）**：oracle-k3s 缩容 **4 OCPU/24GB → 2/12**（前置改动：requests
> 2712m→1372m、`bulk` 分档、hugepages 回收、`system-reserved`）。过程/验证/回滚与实测数值见
> [runbooks/oracle-k3s-shape-downsize.md](runbooks/oracle-k3s-shape-downsize.md)。
> ⚠️ **这是单向操作**（A1 长期无容量，涨回去不保证）——**新服务别再按"容量宽裕"规划**，
> requests 按实测填，非核心挂 `bulk`。

按优先级排列。括号内是出处文档。

> ⚠️ **编号是稳定标识，不是序号**——`reference/`、`decisions/`、runbook 都按 `开放项 #N`
> 引用它们。**关闭一条不重新编号、也不把号让给新条目**：空档就是"这号已经关掉了"的证据
> （#8 = oracle DNS 上游冗余，见下方已完成表）。曾经因为挪过号，三处文档的
> `Renovate #10` 与一处 `#13` 全指错了地方（2026-08-13 修）。

| # | 项目 | 说明 |
|---|------|------|
| 1 | **离站备份** | restic 仓库 → 云（OCI always-free / B2，`rclone` 或 `restic copy`）。当前只有 106 本地副本，火灾/失窃即全损。需人工先开云桶。⚠️ 2026-08-13 起**唯一缺口就是这个**——恢复演练已自动化（原 #6，见 [storage.md](reference/storage.md#月度恢复演练2026-08-13-上线)），但演练只能证明「106 上那份能恢复」，屋内灾难仍是敞口。同日**刻意搁置了 rclone 同步段的实现**（等开桶时一并做，免得留一段跑不起来的死配置）。（[方案](plans/storage/2026-08-03-offsite-backup.md) · [2026-07-06 计划 Phase 5](plans/storage/2026-07-06-storage-local-migration-and-backup-redesign.md)，母文档 P0-1） |
| 2 | **Terraform state → R2** | 5 个 root 全本地 state：笔记本单点、无锁、含明文密钥。顺带可评估 OpenTofu + `use_lockfile`。（[方案](plans/architecture/2026-08-03-tf-state-r2.md) · [演进路线 Phase A](plans/architecture/2026-07-07-tech-debt-and-evolution.md)） |
| 3 | **DGX ×2 文件系统指标（待重部署）** | `nv-dgx-spark` 的 `node-exporter-deploy.yml` **已含** `-v /:/host:ro,rslave` + `--path.rootfs=/host`，但 **live 未生效**：2026-08-03 实测两台 DGX node-exporter 均 `up==1`，`count by (job)(node_filesystem_size_bytes)` 仍无 `node-exporter-dgx-spark`——现网跑的仍是修复前的旧容器。动作 = 对两台机重跑 `make node-exporter-deploy`（`cd /Users/matthew/projects/meirongdev/nv-dgx-spark`）。同理 macbook 无 `node_memory_MemAvailable_bytes`（darwin 固有限制，不可修）。 |
| 4 | **prometheus-operator CRD 补升** | 集群 10 个 `monitoring.coreos.com` CRD 停在 operator v0.89.0，实际运行 v0.92.1——`helm upgrade` 从不升级 chart 的 `crds/`。采纳进 ArgoCD 时刻意 `skipCrds: true` 把它与迁移解耦。两条路：去掉 `skipCrds` 让 ArgoCD 接管（推荐，之后随 chart 自动跟进），或手工 `kubectl apply --server-side`。需单独维护窗口验证。（[manual-helm 采纳决策](decisions/manual-helm-to-argocd-adoption.md)） |
| 5 | **DGX Spark 入编** | 推理服务 IaC + GPU 指标（dcgm）+ 双机 fallback + SLO。当前两台 GB10（各 128GB）只接了 node_exporter / smartctl_exporter。2026-08-13 两台已自组**双节点 k3s + Cilium 1.19.6**（`nv-dgx-spark/k8s/`）。⚠️ **网络对接部分已有结论：不接 ClusterMesh**，走 Tailscale + 手写 Endpoints——那两台是外部 tailnet 的共享节点，节点共享不携带 subnet route，VXLAN 的节点 IP 平面双向不可达（[决策](decisions/dgx-clustermesh-not-adopted.md)）。（母文档 P1-5） |
| 9 | **jobs-sg 收尾（2026-08-03 上线）** | 均不阻塞服务：① **周报 Telegram 已接好**（bot token 复用 `secret/homelab/telegram`，投 `jobs-sg` 话题 thread 552），尚未做的只是**端到端实测一次推送**——首次由周一 08-10 01:00 UTC 的 CronJob 触发。② **Grafana 面板未做**（`jobs_sg_*` 已在采，可用 Explore）。③ ~~`work_mode` 分类法缺口~~ **已修（2026-08-08，上游 `af34eed`）**：分类器不再拿排班字段冒充办公地点，`Unknown` 是一等状态；同批合入的还有 `JobsSgReconcileStale` 盲点（97ad3fc）、`JobsSgIngestStale` 同类哑火（35b3c69）、写事务撞锁重跑（80c91cb）。剩 `closed` 寿命口径 A/B 待首个周日 reconcile（08-09）后观察 2–3 周再定。（[reference/jobs-sg.md](reference/jobs-sg.md)） |
| 10 | **readlist 公开面缺准入过滤（①仍未做）** | `readlist.meirong.dev` 2026-08-06 已公开；公开 catalog 里的第三方简历（BHRC / Mint Wu）已从 calibre 移除，重跑 score 后公开端点核验 0 命中。公开面已多轮收窄：v0.3.0（08-06）catalog 收窄成「公开榜并集」并删 `/api/v1/matrix`；v0.4.0（08-08）公开榜收敛到三份、徽章按参与排序的维度评；v0.5.0（08-09）修掉 C/F 两个「静默为 0」缺陷（snapshot 覆写外部 pubdate、HN 含副标题整名匹配）并补 2 条判别力告警（readlist 共 9 条）。**仍未处理**：修法① 准入过滤没做（`internal/calibre` 读 tags 但不据此筛选）——非书文档照样参与打分，只要碰巧上了公开榜，title+author 仍会上公网，判据依旧只有人眼。⚠️ 做 catalog SSR/sitemap（上游 C1）前建议先补①，否则偶发泄漏会被搜索引擎收录固化。 |
| 11 | **readlist 边缘限流（受 Cloudflare Free 限制）** | 上游 NFR-14 要求分档限流（页面一档、`/api/` 更严一档），**Free 计划只允许 1 条 rate limiting 规则**，而那唯一一条已被 auth 端点 + Excalidraw collab relay 占用且共享计数器（见 [`waf.tf`](../cloudflare/terraform/waf.tf) 注释）。所以「分档」在 Free 上做不到。三选一：把 `readlist.meirong.dev/api/` 并入现有那条（单档、共享计数、30 req/10s，改动会影响全站 auth 防爆破的语义）· 升 Pro（另见第 11 项母条目里的 Cloudflare Pro WAF）· 或先不做（**当前选择**）。理由：v0.2.0 已在应用侧堵掉自伤路径——published_run 进程内缓存、ETag/304（实测经 Cloudflare 仍回 304/0 字节）、不碰库的 `/livez` 存活探针、HTTP 读写超时；边缘限流原本主要就是防那条。站点只读、单副本 500m CPU 上限，剩余风险可接受。 |
| 12 | **低优先 / 可选** | **Renovate 只做完了一半**（2026-08-13）：`.github/renovate.json5` + `check-version-pairs.py` 的 V1-V3 已合入并在 CI 跑，但**GitHub App 仍未安装**，所以它至今一个 PR 都没开过（判据：`git ls-remote --heads origin` 没有 `renovate/*` 分支）。装 App 是纯人工的一步，见 [决策](decisions/renovate-adoption.md)（状态仍是 🚧）· MacBook `TargetDown` 静默规则 · Vault Dynamic Secrets（PostgreSQL 动态凭据，规模不需要）· Cloudflare Pro WAF（Managed Ruleset + OWASP CRS）。（母文档 P2） |

### 已知问题（不阻塞，无人认领）

- **ClusterMesh 是纯待命能力，缺自愈（监测缺口已闭环）**。2026-08-05 曾静默断开约一个月：
  缩容验收时发现两集群 `0/1 remote clusters ready`，跑
  `just connect-clustermesh 100.94.186.7:32379 100.107.166.37:32379` 重建
  clustermesh-apiserver pod 后恢复（双向 `retrieved=true`）。根因是 apiserver
  **up-but-stuck 且不自愈**、配置从未丢过——机制/判据/两个 secret 分工见
  [reference/tailscale-network.md](reference/tailscale-network.md)。告警兜底（kvstoremesh
  `:9964` + 5 条规则）与 oracle 侧 peer 固化（`cilium-values.yaml` 补
  `clustermesh.config.clusters`）均已于 08-05 补齐。**仍未做的是自愈**：两集群
  `service.cilium.io/global` Service 都是 0（无工作负载用跨集群服务发现，遥测与
  ArgoCD→homelab 走 Tailscale + NodePort），ClusterMesh 纯待命——加自愈探针不划算；
  另一条路是明确退役 ClusterMesh、跨集群一律走 NodePort（连同 5 条告警一起消失）。

- ~~**这台 Mac 上 `terraform plan/apply` 连 `192.168.50.4:8006` 100% `no route to host`**~~ **已定性（2026-08-13）**：不是网络问题，是 **macOS 本地网络隐私授权（TCC）**——未获授权的**非 Apple 签名**二进制（terraform/kubectl/Homebrew python）访问 LAN 一律 `EHOSTUNREACH`，而 `ping`/`curl`/`ssh`/`nc` 是 Apple 自带故全通（这正是当年误判"网络正常、是 provider 的锅"的原因），Tailscale/loopback 不受限故一直好用。根治 = 系统设置→隐私与安全性→本地网络里给终端授权；不依赖授权的绕法（SSH 隧道 / Tailscale 寻址）已固化进 `proxmox/terraform-storage`。→ [复盘](records/2026-08-13-macos-local-network-tcc.md)

- **oracle-k3s：1 个 Docker Hub 镜像仍未被 Trivy 扫过，等配额恢复后重试一次**（2026-08-05；
  2026-08-11 从 3 个减为 2 个 —— `stirling-pdf` 已退役，接替者 BentoPDF 在 ghcr.io，
  不受 Docker Hub 匿名配额影响；2026-08-14 再减为 1 个 —— `redpanda-connect` 随
  karakeep 管道退役）。
  `rsshub-browserless`(browserless/chrome) 的扫描 Job 均因
  `TOOMANYREQUESTS: unauthenticated pull rate limit` FATAL。配额是 Docker Hub 匿名的
  **100 pulls / 6h / IP**，当天被清 73 条 Critical 时的强制重扫（删 6 份报告 + 3 次
  operator 重启）打空了。**失败的扫描不会自动重试**（详见
  `reference/security.md` §6），所以配额恢复后必须人工推一次：

  ```bash
  kubectl --context oracle-k3s -n trivy-system rollout restart deploy/trivy-operator
  # 6-8 分钟后回查（镜像很大，单个扫描要几分钟）
  kubectl --context oracle-k3s get vulnerabilityreports -A -o json | jq -r \
    '.items[] | select(.metadata.labels."trivy-operator.resource.name"
     | test("browserless")) | "\(.metadata.labels."trivy-operator.resource.name") crit=\(.report.summary.criticalCount)"'
  ```

  ⚠️ 在此之前 `TrivyImageCriticalVulnerabilities` 读到的 0 **不覆盖这 2 个镜像**——
  告警只数现存报告，缺报告按 0 计入。根治办法（给扫描 Job 配 Docker Hub 认证，
  `trivy.privateRegistryScanSecretsNames`）已评估但**刻意没做**：需要新增 Docker Hub
  凭据，当前判断不值得为 2 个镜像引入。

---

## 不做 / 已取消

| 项目 | 结论 |
|------|------|
| Cert-Manager (Let's Encrypt + DNS-01) | TLS 在 Cloudflare 边缘终结、集群内 HTTP，无内网直连 TLS 需求 → 纯负担 |
| Vault HA / auto-unseal | 单节点无 HA 意义；sealed 已被 ESO 告警覆盖 + 恢复路径已文档化，transit auto-unseal 要再养一个 Vault |
| Crossplane | 2026-07-07 否决：CF provider 已死 2 年、问题规模不匹配（单人静态云面）、控制面鸡生蛋、单节点内存开销。重评条件见 [ADR](decisions/crossplane-not-adopted.md) |
| Talos 迁移 | 2026-03 刚重建 Ubuntu 24.04 且流程已顺，单节点收益不抵成本。加第二台 worker 时重评（[演进路线 §五](plans/architecture/2026-07-07-tech-debt-and-evolution.md)） |
| Cilium External Workloads（NAS 入网） | 2026-03-19 取消：`CiliumExternalWorkload` CRD 与 CLI 已从 Cilium 1.15+ 移除，1.19.1 不支持。若要限制 NFS 访问，改用 `CiliumNetworkPolicy` + `fromCIDR: 192.168.50.106/32`（[原方案](plans/archive/2026-03-15-cilium-external-workload-nas.md)） |
| 集群级网络默认拒绝 | **刻意延后**（非取消）：单用户威胁模型下横向移动收益边际低、debug 成本高。Hubble 已开做可见性，作为日后单 ns 灰度的前置。见 [security.md](reference/security.md) |
| homelab 多节点 HA / etcd 三节点 | 2026-07-04 否决：硬件不支持、单用户收益为零。正确形态是**单节点 + 快速重建**（`just homelab-recover` + restic 备份体系）。加第二台 worker 时与 Talos 一并重评 |
| Thanos / Mimir / 指标对象存储长期化 | 2026-07-04 否决：双写复杂、搬迁窗口长，`retention` + `retentionSize` 控制就够（见 `k8s/helm/values/kube-prometheus-stack.yaml`）。⚠️ 同批"LGTM 整体不搬"那半条**已被推翻**——Loki/Tempo 于 2026-08-02 迁 oracle（[迁移计划](plans/architecture/2026-08-02-homelab-to-oracle-workload-migration.md)），Prometheus/Grafana/Alertmanager 仍在 homelab |
| storage-106 并入 homelab 集群 | ⛔ **2026-08-13 已推翻并实施**：106 上的 VM 以 `k8s-worker-106` 入编 homelab（[ADR](decisions/storage106-as-homelab-worker.md) · [施工复盘](records/2026-08-13-k3s-worker-join-106.md)）。入编的是 **VM 不是宿主**，所以 2026-07-04 那条「计算压上 NFS 后端放大爆炸半径」的理由已不适用（NFS 2026-07-11 就退役了）；实测入伙税也远低于估算（requests 928Mi/2311Mi）。代价是 106 与 prod 的解耦被主动放弃 |

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
| 2026-08-10 | **PSA 收口（三件事，同一天）**：① `zitadel` ns 从**无标签**（吃内置默认 privileged、warn/audit 全空，实测特权 Pod 可建成且零 warning）一路推到 **restricted** —— 先补 chart 的 `securityContext` 三项再翻 enforce，顺序反了会在下次 helm upgrade 把 `zitadel-init`/`zitadel-setup` Job 挡在准入外；翻前后都用 `kubectl label … --dry-run=server` 问准入本人（补齐前点名 4 个违规 Pod，补齐后零 warning）。⚠️ 由此产生一条承重关系：ns 是 restricted 之后，`zitadel.yaml` 那段 securityContext 不能删。② 清单外 ns 全部补齐（homelab `personal-services`——08-03 级联删除后重建、标签丢了近一周——加 `external-dns`/`opencost`；oracle `default`/`external-secrets`/`cnpg-system` 与 `kube-system`/`trivy-system`），并加 `just psa-check` 漂移哨兵（有 Pod 却无标签 → 非零退出）。③ CI 新增 **H5**：清单里的 Namespace 必须显式声明 PSA 等级。全量核过 124 个 Pod，无一违反自己 ns 的档。（[security.md §5.1](reference/security.md) · [manifest-safety-checks.md](reference/manifest-safety-checks.md)） |
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
| 2026-08-08 | **jobs-sg 缺陷收口**：升级 `90cd4e8`（web 端口拆分 8080/9090、告警改口径、路由重排）后，按 [三处问题诊断](plans/apps/2026-08-08-jobs-sg-three-defect-diagnosis.md) 修掉 `JobsSgReconcileStale` 结构性哑火（97ad3fc）、`work_mode` 拿排班冒充办公地点（7dfd873，上游 `af34eed`）、`JobsSgIngestStale` 同类哑火（35b3c69）、写事务撞锁重跑（80c91cb，上游 `730c6f3`） |
| 2026-08-08 | **LLM 网关注册退役**：整个旧网关 ArgoCD App（LLM 网关 + oauth2-proxy + dgx-proxy）删除；LLM 网关由 LiteLLM 接替（[计划](plans/apps/2026-08-01-litellm-gateway-migration.md)，**已于 2026-08-16 落地**，见下） |
| 2026-08-26 | **接上 godot-games**（另一个仓库的家庭游戏大厅）：Nakama 挂上服务端 Lua 模块（initContainer 从 `ghcr.io/meirongdev/godot-games-nakama-modules:<sha>` 拷进 `/nakama/data/modules`，换 tag 即发版且**自动滚动** —— Nakama 只在进程启动时加载 Lua，这正是上游放弃 ConfigMap 的原因）+ 按契约设 `runtime.lua_{min,max}_count=1/4`（**必须成对**，`min` 默认 16 且校验 `min<=max`，只调 max 直接启动失败；M4 词库 1.12MB × 默认 48 VM ≈ 400MB 会顶穿 512Mi limit）+ 新服务 `game.meirong.dev`。顺手撤掉指向 API 的 Nakama 磁贴 —— 那个 href 打开是空白页（`content-length: 0`）。首版卡在两处、当天未 push：ghcr 包 private（集群 403）与上游 web 客户端硬编码 `127.0.0.1:7350`；两者均于 08-27 由上游修掉（前者加了 CI 门禁，后者改成按页面来源推导）。契约见上游 https://github.com/meirongdev/godot-games/blob/main/docs/deployment-contract.md |
| 2026-08-27 | **游戏大厅打通**：客户端改成从页面来源推导服务器地址后，`game.meirong.dev` 的 HTTPRoute 变成三条规则 —— `/v2/*` + `/ws` → `nakama:7350`，其余 → 静态站。☠️ **这两条是"游戏能不能打开"的前提，而上游 e2e 直连 `nakama.meirong.dev:443`、结构上绕过它们**：路由写错/漏写/WS 没放 Upgrade，e2e 照样全绿，唯一判据是用浏览器真开一次。同时把 `socket.server_key` 从 Vault 挪进 git 字面量（`family-lobby-2026`）—— 它跟着 web 制品公开发布、按契约 §5 不是机密，放 Vault 只会让"与上游 `NakamaConfig.SERVER_KEY` 是否一致"变得看不见；防滥用靠上游新加的建房限流（5 次/60s per user_id）。模块数 7→8（多了 `rules/rate_limit.lua`）|
| 2026-08-25 | **Nakama 游戏后端上线**（homelab，`nakama.meirong.dev` 客户端 API + `nakama-console.meirong.dev` 管理台）：3.40.0，多架构 index digest 固定；**无 PVC**，状态全在共享实例 `apps-pg` 的第三个租户 —— 也就顺带把「加租户」那套流程实跑了一遍（含备份脚本 2e 段，那步没有任何检查兜底）。密钥走 ESO 渲染整份 `config.yml` 挂成文件，**不进命令行**（Nakama 的密钥都是 flag，写进 pod spec 等于人人可读；它也不读环境变量）。上线前在本地 throwaway 容器实测过：migrate 19 条、`/healthcheck` 200、metrics 52 条真实 `nakama_*`（路径是 **`/`** 不是 `/metrics`）、空载仅 15.55 MiB（**上限刻意没按这个收**）。☠️ 管理台裸挂公网、只有自带口令,已记入 [security.md 已知缺口 #7](reference/security.md) |
| 2026-08-25 | **homelab 的两个 Postgres 收敛成一个**：`litellm-pg`(手搓 Deployment) + `multica-postgres`(上游 chart 自带) → 共享实例 `databases/apps-pg`（裸 Deployment，租户 litellm/multica）。逻辑 `pg_dump\|psql` 迁入并逐表对账（litellm 68 表/374 行含 17 个虚拟 key；multica 108 表/2558 行、365 索引、`schema_migrations` 381 行）。**刻意不装 CNPG**：operator 自己实测 rss 45Mi/ws 69Mi，比省下的 postmaster 还贵 —— 所以两个集群的 `databases/apps-pg` 同名同角色但形态不同。租户不再是 superuser 且 `REVOKE CONNECT FROM PUBLIC`（跨租户连库实测被拒）；代价是 multica 的库故障能把 LLM 网关一起拖下去。顺手修掉三处：Kyverno 镜像白名单要显式 `docker.io/` 前缀（旧的两个实例都在违规）、`manifest-safety-checks.md` 的 H4 豁免表漏了 6 条、夜备清单漏记 `litellm.dump` ([决策四](decisions/shared-postgres-platform.md)) |
| 2026-08-16 | **LiteLLM LLM 网关落地**：`litellm` App 上线 `llm.meirong.dev`（DGX `deepseek-v4-flash` 主 + Mac `Qwen3.6-35B` 兜底 fallback，[决策](decisions/litellm-llm-gateway.md)）；旧 LLM 网关全线退役（Vault secret / ZITADEL client 残留清理，client 需 ZITADEL console 手删）。网关钉控制面、litellm 清单走 GitOps |
| 2026-08-09 | **探针误杀修复 ×2**：Uptime Kuma（4 天 11 次重启）与 ZITADEL login（27 次重启）都补上 `startupProbe`——此前是探针在重启风暴里误杀 |
| 2026-08-09 | **readlist v0.5.0**：修掉 C/F 两个「静默为 0」结构性缺陷（snapshot 覆写外部 pubdate 338→0、HN 含副标题整名匹配致 C 恒 0、mentions 预算被 editions 烧光）；补 2 条判别力告警（C 维 3d / F 维 24h），readlist 告警 7→9 条 |
| 2026-08-09 | **Cilium identity-mark 撞 Tailscale fwmark**：位段冲突修复（单个 pod 到 100.64/10 全超时的 1/256 抽签），机制见 [tailscale-network.md](reference/tailscale-network.md) |
| 2026-08-09 | **oracle journald 持久化**：非正常重启的现场不再每次蒸发 |
| 2026-08-09 | **告警盲区闭环**：DGX 内存告警改 PSI+OOM、补 `NodeRebooted` 堵重启盲区；dead-man's switch 的投递失败不再冒充「告警链路坏了」 |
| 2026-08-10 | **KRR 首轮完整分诊**（homelab 42 行 + oracle 70 行）：BestEffort pod oracle **15→5** / homelab **9→1**、逼近 limit 的 11 个容器全部抬 limit、oracle CPU requests **83%→71%**。分诊方法固化为 [runbooks/krr-report-triage.md](runbooks/krr-report-triage.md)。真正的收获是照出**三处「配置在 git 里却从未生效」**：kps 的 `kubeStateMetrics`/`nodeExporter` 写在父 chart 开关键下（正确位置是子 chart 别名）、tetragon 顶层 `resources:` 在 chart 1.7.0 根本不存在（导致那台热笔记本上的 eBPF 安全组件**一直没有 CPU limit**，与「安全组件 fail-open + 控 CPU」硬约束相反）、cilium 的 resources 写进 git 但没跑过 `deploy-cilium`。三者共性是 **Helm 静默忽略写错层级的键、不报错**，只能靠 `helm template` 实证 |
| 2026-08-10 | **QoS 与 Pod Priority 的两条实测推论**（补进 [k8s-qos-resource-management.md](reference/k8s-qos-resource-management.md)）：① **BestEffort 会让 `priorityClassName` 整行失效** —— external-dns 标着 `high`(900) 却因无 resources 落进「超 request」桶，反而排在守规矩的 `bulk`(-10) 应用前面；② 反过来，带 `system-*-critical` 的 Pod 即使 BestEffort 也排最后，据此**放弃**补 oracle 侧 cilium 全家的 requests（会把该节点内存 requests 从 85% 推到 95%，收益接近零） |
| 2026-08-10 | **OOM 告警补齐事前一环**：此前三条规则全是事后的（容器被杀了才响）。新增 `ContainerMemoryNearLimit`（7d 峰值 >85% limit，双集群）与 `ContainerOOMKilledCadvisor`（kubelet 内嵌 cAdvisor 的 OOM 计数器，仅 homelab，用来交叉验证 `ContainerOOMKilled` 的 `reason` 标签值——30d 内两集群**从没出现过 OOMKilled 样本**，那条规则的拼写至今未经实测证实）。同时记录覆盖口径：**没有独立部署 cAdvisor**——`container_*` 全来自 kubelet 内嵌 cAdvisor；oracle 的 otel-collector 只 keep `container_(cpu_usage_seconds_total\|memory_working_set_bytes)` 两个指标（为 KRR），故 `container_oom_events_total`（116/0）、`container_cpu_cfs_throttled_*`（41/0）在 oracle 侧**不进中枢 Prometheus**，查询返回**空结果**与「值为 0」外观一致，当天据此误判过一次 |
| 2026-08-10 | **Cilium 双集群 1.19.1→1.20.0**（计划外）：`cloud/oracle/justfile` 的 `deploy-cilium` **缺 `--version`**（homelab 那份一直有），一次只为改 resources 的例行部署随 `helm repo update` 静默升版。连带发现 `--reset-values` 会冲掉 `cilium clustermesh connect` 交换的**跨集群 CA 信任**（证书不入库，values 保不住），mesh 静默断开且形态极具迷惑性：`troubleshoot clustermesh` 六项全 ✅、NodePort 双向可达，唯一真判据是 `cilium status` 的 `retrieved=false` 与**对端** etcd 日志的 `tls: bad certificate`。已给 oracle 的 cilium/ESO recipe 补 pin，并在两个 `deploy-cilium` 收尾加 echo 提示必跑 `connect-clustermesh` |
| 2026-08-10 | **homelab PriorityClass 分档补齐，从开放项移除（原 #9）**：15/36 → 27/36 有 priorityClassName。`high`(900) 给 Prometheus / Alertmanager / otel-collector（指标源、告警投递、遥测出口）；`bulk`(-10) 给 tetragon ×2、kyverno ×4、open-notebook ×2、jobs-sg-web。**Grafana 刻意留默认档**——它只是 UI（可直接查 Prometheus），且是 monitoring ns 内存最大的一个。kyverno 敢归 bulk 的判据是实测 webhook failurePolicy：唯一管工作负载准入的 `kyverno-resource-validating-webhook-cfg` 是 **Ignore**，其余 `Fail` 的只管 Kyverno 自己的 CR，所以它掉线不挡 pod 创建 = 真 fail-open。⚠️ 前提是今天已把 resources 补齐——**BestEffort 会让 priorityClassName 整行失效**，只补优先级等于装饰。第三处「设不了」：**sloth**（chart 0.16.0 无此键，逐键 + `--set` 双重实证），与 ZITADEL / timeslot 同类 |
| 2026-08-10 | **CPU limit 的反向陷阱**：给此前无 limit 的 node-exporter 配 `200m` 后节流率 **31%**（`CPUThrottlingHigh` 当场告警），而它 1m 粒度峰值仅 **3m** —— 采集型组件是亚秒级突发，CFS 100ms 周期掐得住、1m rate 看不见。已撤回其 CPU limit；对照同批加同样 limit 的 kube-state-metrics 实测 **0%**，故保留——**必须逐个实测，不能按组件类别想当然**。顺带修既有的 sloth 节流 20%（limit 50m→200m） |
| 2026-08-12 | **oracle DNS 上游冗余真正生效（原开放项 #8 关闭）**：此前的 `FallbackDNS=` 版是**无效修复**——它不进 `/run/systemd/resolve/resolv.conf`，而 kubelet 喂给 CoreDNS（集群路径，当初真正死掉的那条）的正是该文件；装完后 cloudflared 照样 26d 重启 24/28 次，与「已修」的自我认知并存了十来天。改 `DNS=1.1.1.1 1.0.0.1`（全局池、进文件、只配 v4——节点无 v6 默认路由）+ **重建 CoreDNS pod**（kubelet 在 pod 创建时快照 resolv.conf，不重建吃不到新上游）。**故障演练实证**：iptables 掐死 →`169.254.169.254:53` 30s，pod 内 4 域名全部解析成功、DROP 计数 15 包——查询确实被掐、确实走了备胎。后续观察项：cloudflared 重启率应显著回落。（[复盘](records/2026-08-01-oracle-k3s-dns-outage.md)·playbook `setup-k3s.yaml` 注释） |
| 2026-08-23 | **集群外三站点补上可用性监控**（原开放项 #13）：`stack.meirong.dev`（另一个仓库部到 Cloudflare Workers，[决策](decisions/home-stack-repo-boundary.md)）、`playgrounds.meirong.dev`、apex 博客三个此前**一个监控都没有**。☠️ 顺带揪出 uptime-kuma provisioner 一个静默滞后 bug：`add_monitor()` 之后 `get_monitors()` **看不见**刚建的监控（客户端列表靠服务端推事件填），于是状态页的 `publicGroupList` **落后一次运行** —— 监控确实建成、告警也会响，可公开状态页上一条都没有，而日志三条全绿、ArgoCD hook 报 Succeeded，无处可查。同一 bug 也解释了 Multica 自 08-18 起一直不在状态页上。已改为「等所有声明的监控都出现在服务端返回里再存状态页」，等不到则响亮警告但**不失败**（这是 PostSync hook，失败会连累整个 App 的 sync）。⚠️ 这三条不能当集群存活信号 |
| 2026-08-24 | **capacity 组两条告警从 homelab-only 改为覆盖两集群**（原开放项 #14）：`HomelabCpu/MemoryRequestsSaturated` → `ClusterCpu/MemoryRequestsSaturated`，`sum()` 改 `sum by (cluster)`。**改名不是洁癖** —— 旧 annotation 里"迁负载去 oracle"的建议对 oracle 自己讲不通，现改成写明**两集群出路不对称**（oracle 已单向缩容到 2 OCPU/12GB，满了只能砍 requests 或退役，没有"挪去另一个集群"这条路）。起因是补文档时去核清单注释里"oracle 的序列不进中枢 Prometheus"这句，**发现它已经不成立**：`count by (cluster)` 显示分子分母两边都有序列，而逼近阈值的恰是没被覆盖的 oracle。6d 回放定的账（5min 步长 1729 点）：homelab CPU 25.2–28.3% / 内存 57.9–64.8%，oracle CPU 60.1–71.2% / 内存 73.6–**85.2%**；>90% 采样点 **0**（零误报），oracle 内存 >85% **只持续 5 分钟**（单点，rollout 期间新旧 pod requests 并存的尖峰，`for: 30m` 正好滤掉），而 >75% 有过 **115 分钟连续** —— 即 90% 既够不着又不会哑火，阈值与 `for` 都不用改。⚠️ 分母仍保留 `job="kube-state-metrics"`（opencost 吐同名指标，两集群各 2+2 series）。**教训**：写死集群的选择器会在采集面变化后**静默失效**，要定期复核 —— 同类的 external-dns 那条已在同日修掉（原开放项 #7，见下一行） |
| 2026-08-24 | **external-dns 的元故障告警改为覆盖两集群**（原开放项 #7）：⚠️ **本条描述本身有一半是过期的** —— 它说"4 条仍写死 `cluster="homelab"`"，实测只有 1 条如此，另 3 条（`ReconcileStalled`/`RegistryErrors`/`SourceErrors`）压根没有集群选择器、本来就按 series 逐集群评估。真正剩下的是 `ExternalDNSMetricsAbsent`，而它限定 homelab 是**有据的刻意决定**（清单注释写着"oracle 是 best-effort remote-write，absent() 会因缺口误报"）。6d/60s 实测推翻了那个理由：homelab 8641 点 **0 个** >2min 缺口，oracle 8637 点 **1 个 3 分钟**缺口 —— `for: 15m` 能吸收五倍。**改法刻意不是加一条 `absent(...{cluster="oracle-k3s"})`**：`absent()` 只能断言一个具名标签集缺失，覆盖 N 集群就要硬编码 N 个名字。改成拿 `kube_deployment_status_replicas_available{namespace="external-dns"}` 当参照做 `count by (cluster) (...) unless count by (cluster) (...)` —— 自维护（第三个集群出现即自动纳入），且语义更准：只在「deployment 在跑但指标没了」时响 = 遥测路径断了，「pod 挂了」交给 `KubePodNotReady`/`CrashLooping`（oracle 的 KSM 确实带 `cluster=oracle-k3s` 进来，213 个 series）。依赖项兜底 = `OracleTelemetryAbsent`。三项验证：当前 0 命中 · **把指标名换成不存在的 → {homelab:1, oracle-k3s:1}**（这条才证明它真能判出缺失）· 6d 回放零误报 |

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
| 2026-08-03 | **ArgoCD Image Updater 退役**：0 个 `ImageUpdater` CR、空转数月的控制器卸载（删 `argocd/applications/argocd-image-updater.yaml` App + `k8s/helm/values/argocd-image-updater.yaml`），`oracle-k3s` App 上遗留的旧式注解一并移除（那个 controller 没了注解即死配置）。机制文档保留在 [decisions/argocd-image-updater.md](decisions/argocd-image-updater.md)，日后要自动升级可重新接入或走 Renovate（见开放项 #12）。 |
| 2026-08-06 | **oracle VM 清理**：`crictl rmi --prune` 删 32 个死镜像（96→64），磁盘 71G→62G 回收 **9GB**（containerd 37G→28G）。积压原因是 kubelet 镜像 GC 为阈值触发（`imageGCHighThresholdPercent` 85%）而磁盘才 37%，**从未跑过**。⚠️ 首轮报一屏 `DeadlineExceeded` 是 crictl 默认调用超时仅 2s，containerd 实际删成了 |
| 2026-08-06 | **image-updater 残留凭据清除**：退役 3 天后 `cloud/oracle/manifests/argocd/image-updater-secrets.yaml` 仍在 kustomize 树里，**每分钟从 Vault 拉一次 GitHub 凭据**产出两个无人消费的 Secret。⚠️ 其一名为 `git-creds`，确认过它没有 `argocd.argoproj.io/secret-type` 标签、ArgoCD 不认作仓库凭据才删 |
| 2026-08-13 | **月度恢复演练自动化**（原开放项 #6）：`restic-restore-drill` CronJob 每月真恢复 + 跑 8 条判据（仓库结构 · 两集群快照新鲜度 · Vault raft 快照 · jobs.db integrity · 两个 pg dump 收尾标记 · raw 归档实解压），配 3 条告警。☠️ 判据敏感度用**损坏数据**逐条实测：7 种坏法全判出、零漏报——截断的 `vault.snap` 仍非空、合法空库的 `integrity_check` 返回 `ok`、半截 `pg_dump` 大小正常，只验"文件在且非空"三种全放过。另记一条会咬夜备的坑：restic 的陈旧锁判定靠 hostname+PID，K8s 里跨 Pod 泄漏的锁 30 分钟内 `unlock` 清不掉（[storage.md](reference/storage.md)） |
| 2026-08-13 | **Renovate + 版本配对 CI**（原开放项 #12 里的一项）：`.github/renovate.json5`（内置 argocd/kubernetes manager + 3 个 regex manager，实测识别 16 条自定义依赖）配 `scripts/check-version-pairs.py` 的 V1-V3——同名 chart 跨集群同版本、声明为同一事实的版本变量组一致、cilium↔gateway-api 符合兼容表。六个破坏场景实测全判红（含**今天真实发现的** oracle 剧本漂在 1.2.1）。⚠️ **仍待人工装一次 GitHub App** 才会真正开 PR（[决策](decisions/renovate-adoption.md)） |
| 2026-08-14 | **信息管道（Miniflux→KaraKeep）退役**：`redpanda-connect` + `karakeep` 两个 Deployment、`keep.meirong.dev` HTTPRoute、Homepage/Uptime Kuma 条目、备份白名单全删；Miniflux/RSSHub 保留。起因：`webhook-to-karakeep` 内存告警（7d 峰值达 limit 95%，冷启动尖峰）——实测近 7d 零 webhook 流量、SQLite 仅 564K，用户确认不需要；顺带释放 oracle ~1Gi memory requests。PVC 与 ZITADEL client、Vault 残留均已删除。方案已归档 [plans/archive/2026-02-28-info-pipeline-miniflux-karakeep-gotify.md](plans/archive/2026-02-28-info-pipeline-miniflux-karakeep-gotify.md) |
| 2026-08-06 | **孤儿资源复跑**（控制面迁 oracle 后首次双集群跑）：信号面各 6 条，**真孤儿 0 条**。补 3 条结构性 ignore（Vault 两个 volumeClaimTemplate PVC、CNPG 的 `cnpg-default-monitoring`）；另汇总 4 条**永久孤儿**（不入 git 的 bootstrap 依赖），刻意不进 ignore —— 那份清单就是「从 Git 重建会缺什么」([决策](decisions/orphaned-resources.md)) |
