# Homelab 机器与集群架构优化建议

> 日期: 2026-07-04
> 范围: 全舰队（homelab / oracle-k3s / storage-106 / DGX Spark ×2 / MacBook）机器角色与集群架构
> 定位: 承接 `docs/plans/networking/2026-03-07-homelab-oracle-architecture-optimization.md` 与 `docs/reference/simplification-recommendations-2026-03.md`，聚焦**物理层错配**而非新增组件

---

## 总诊断

软件层已相当完整（GitOps 双集群、LGTM 全信号、SLO、准入/扫描/运行时检测、WAF）。短板不在"再加组件"，而在**物理层的两个结构性错配**：

1. **算力倒挂**：最关键的负载（Vault、ArgoCD hub、可观测中枢；ZITADEL 已于 2026-07-06 迁 oracle-k3s，不再算在内）全部跑在舰队里**最弱的机器**上——16GB 物理内存、idle ~74°C 的 5600H 笔记本（VM 硬分配 12GB 无 balloon，宿主实测仅 ~987Mi available；见 §4 2026-07-12 实测）。而 Oracle 免费节点有 24GB（两倍），两台 DGX Spark 各 128GB 基本闲置（仅接了 node_exporter / smartctl_exporter）。

2. **故障域集中**：~~身份（ZITADEL）、~~密钥（Vault）、GitOps（管两个集群）、告警出口（Alertmanager → ~~gotify-bridge → Gotify~~ **原生 telegramConfigs → Telegram，2026-07-18 起**）——三种"救命能力"住在同一台笔记本的同一个 VM 里（ZITADEL 已随 2026-07-06 迁移脱离，见上条）。**homelab 整机挂掉时，指标告警链全哑**（Watchdog 被 drop，没有 dead-man's switch），只能靠人工发现。

3. **数据单点**：Kopia 已于 2026-07-05 移除，~~当前全系统无任何备份~~ **已由 restic 取代**（2026-07-06 上线 + 恢复演练通过，见下方 P0-1）。`docs/plans/ROADMAP.md` Phase 4 的"离站备份"仍未做，是当前唯一**不可逆**的残余风险。

优化按"数据不可再生 > 告警可达 > 容量 > 质量"排序，分三级。

---

## P0 — 补致命短板（不动架构，一两个周末）

### 1. 离站备份（roadmap 已有，提为第一优先）

唯一能造成**永久损失**的场景是 storage-106 磁盘 + 屋内事故。

> ✅ **已定方案（2026-07-06）**：serverless **restic**，每集群 CronJob 逻辑 dump（Vault raft snapshot / pg_dump / sqlite `.backup`）→ **106 ZFS 加密仓库**（`mrstorage/restic`，raidz1 + sanoid 保护）。**先本地仓库、离站 later**（后续 rclone/`restic copy` → OCI always-free 20GB 或 B2）。完整执行计划见 **`docs/plans/2026-07-06-storage-local-migration-and-backup-redesign.md`**。

- 分层：**P0 小数据（Vault + 各 PG + sqlite，总量 <2GB）** 进 restic；**Calibre 书库（100Gi）** 不进 restic，靠 ZFS raidz1 + sanoid（书可再下载，用户已确认不离站）。
- 凭据：restic repo 密码 + 专用 SSH key 入 Vault `secret/homelab/restic` → ESO。
- **恢复演练**并入 restic 计划 Phase 1 DoD（从仓库真恢复 Vault+PG+sqlite），否则备份只是薛定谔的备份。

### 2. 告警链路脱离 homelab 故障域

原则：**报告 homelab 死讯的组件不能住在 homelab。**

> ✅ **已定方案（2026-07-06）**：**Gotify + ZITADEL 都迁 oracle-k3s**（用户确认）；dead-man's switch 一并落地。执行见 2026-07-06 计划 Phase 3+4。

- **Dead-man's switch**：把 Alertmanager 的 Watchdog 从 `receiver:"null"` 改为路由到外部心跳——oracle 上 Uptime Kuma 的 **Push monitor**（Alertmanager webhook 每分钟打一次 push URL，5 分钟无心跳即告警）。homelab Prometheus/Alertmanager 停跳 → oracle 侧立刻知道。
- **Gotify 迁 oracle-k3s**：SQLite + 1Gi PVC（迁 local-path），manifest 挪 `cloud/oracle/manifests/gotify/`、tunnel ingress + DNS 换集群，URL 不变（`notify.meirong.dev`），KaraKeep → Gotify 管道无感。**这一步是 dead-man's switch 真正生效的前提**：Gotify 到了 oracle 后，Uptime Kuma → Gotify(oracle) → Telegram 在 homelab 全灭时仍畅通。
  - ⚠️ Uptime Kuma provisioner 目前只建 monitor、**无通知渠道**——Task 9 需补配其 Gotify(oracle)→Telegram 通知渠道，否则 push monitor 触发也发不出。

### 3. storage-106 的 ZFS 冗余（已确认，2026-07-04）

已核实：`mrstorage` = **raidz1，3×4TB WD Red Plus**（6% 用量，2026-06-14 scrub 0 错误）。**已有 1 盘容错**，不是单盘——原疑问消除。剩余动作：

- 配置每月 `zpool scrub` 定时 + scrub/degraded 结果告警（SMART 指标已在抓，补一条 PrometheusRule 即可）。
- ⚠️ raidz1 只容 **1 盘**；resilver 期间第二盘故障会毁池 → **离站备份（P0-1）仍是最终安全网**，raidz1 不能替代它。

> 补充：106 = Celeron J4105 / 7.6GB 的 Proxmox 节点，算力/内存都很弱，**不适合作为 k3s 计算节点**（会与 NFS 存储角色抢资源、放大爆炸半径）。详见文末"附:关于把 106 加入集群"。

---

## P1 — 机器角色再平衡（核心架构优化）

目标态：

| 机器 | 现状 | 目标角色 |
|---|---|---|
| pve（5600H, 16GB 物理/13.5GB OS 可见） | 全家核心混载 | **数据面/有状态核心**（Vault、ArgoCD、LGTM）——先收核显 UMA 显存，加内存待核实可行性（见 §4） |
| storage-106 | NFS + ZFS | 不变：**纯存储，保持 boring**，永不进集群 |
| oracle-k3s（4C/24G） | 公网无状态服务 | 公网服务 + **身份面 + 告警面/状态面**（✅ ZITADEL 已迁入 2026-07-06 + Uptime Kuma + Gotify + dead-man's switch） |
| DGX Spark ×2（128G） | 仅指标 | **裸金属推理层**，纳入 IaC + GPU 观测 + Bifrost 双机容错 |
| MacBook | 仅指标 | 不变（roaming，不承担服务） |

### 4. pve 内存——2026-07-12 实测 + 加内存性价比重新评估

12GB VM 里 LGTM + Kyverno/Trivy/Tetragon + Vault/ArgoCD 已贴着天花板跑（ZITADEL 已于 2026-07-06 迁出，不再占这台机器的内存），这也是安全组件被迫 fail-open、串行扫描的间接原因之一。

**2026-07-12 实测**（`ssh root@192.168.50.4`，只读排查，未做任何变更）：

- 物理内存 2×8GB SO-DIMM = 16GB，但 OS 仅见 13.5GB（`MemTotal` 14169656 kB）。差额中 **2GB 被核显（AMD Cezanne/Vega）的 UMA 显存占用**——`/proc/iomem` 有一段专属 reserved 区间，`amdgpu` debugfs 确认 `size: 2147483648`（2048MiB）。这台机器是无头 Proxmox 服务器，核显显存纯属浪费。
- VM（`k8s-node`, vmid 100）`memory: 12288`、`balloon: 0`——硬分配，host 无法动态回收；qemu 进程实际 RSS ~11GB。
- host 侧：`free -h` 为 199Mi free / 987Mi available；swap 2.1GB/8GB 已用，但连续 `vmstat` 采样 si/so 均为 0（当前是静态残留，非活跃换页）；`journalctl` 近 30 天无 OOM-kill 记录——**没有火烧眉毛的危机，但余量确实很薄**。

**⚠️ "升到 32GB" 这条旧建议存疑，已核实为错误/未验证假设**：`dmidecode -t 16` 显示这块板子 `Maximum Capacity: 16 GB`，且两条插槽已用 2×8GB 插满——这台具体机器可能已经到内存天花板，"5600H 笔记本通常 2×SODIMM 可升 32GB"只是未针对这台机型验证的泛化说法。真要扩容前必须先核实 Lenovo（BIOS `GZCN14WW`, 2021-02-03）该型号的官方最大内存规格，不能按"笔记本通常能上 32GB"直接下单。

**建议顺序**：
1. **免费、无风险**：下次维护窗口去 BIOS 收回核显 UMA 显存（~1.5-2GB），不影响 VM 配额，也不用买硬件。
2. 核实该型号官方最大内存规格后，再决定是否值得为潜在的主板/插槽限制冒险买内存。
3. 加内存到手前，**热约束（74°C 是散热物理极限）不受影响**，但内存仍是加组件时的第一顾虑。
4. 相比之下"把 LGTM 搬去别的机器"复杂度高得多、收益反而低——**不建议搬**（见下）。

### 5. DGX Spark 正式入编（最大的闲置资产）

两台 GB10 是舰队算力总和的 90%+，目前只有监控接入。建议（都在 `nv-dgx-spark` 仓库侧做，**不加入 K8s**）：

- 推理服务（vLLM/MLX server）做成 systemd/compose 的 IaC + 健康检查端点，与 node_exporter/smartctl 同等待遇——现在 Bifrost `custom_dgx` 后端挂了应是无告警的。
- 补 **GPU 指标**：dcgm-exporter（有 arm64 镜像）或 nvidia-smi textfile collector，接入现有 Prometheus 抓取（照抄 `smartctl-dgx-spark` job 模式）。
- **Bifrost 配双 DGX fallback**（Bifrost 支持 provider fallback 链），一台跑主力模型、另一台做备份/实验位；`llm.meirong.dev` 加进 Uptime Kuma，并在 `manifests/slos.yaml` 给 Bifrost 路由加一条 SLO——Sloth 基建现成。

### 6. Oracle 24GB 余量的用法

个人服务很轻，24GB 用不满。除接收 Gotify（P0）外：

- ✅ **ZITADEL 迁 oracle 已决（2026-07-06）**：不再只是预案——全家 SSO 可用性 > 家里笔记本；`auth.meirong.dev` 走 tunnel、在哪个集群对外无感；PG 迁 oracle local-path，用现成 pg_dump/restore SOP。执行见 2026-07-06 计划 Phase 3 Task 8（纳入 `docs/plans/2026-07-04-zitadel-to-oracle-k3s.md`）。

---

## P2 — 平台工程质量（顺手做，低成本高回报）

7. **Renovate**（GitHub App，免费）：仓库在 GitHub，接上后自动 PR chart/image 版本 bump。直接消灭 CLAUDE.md 里"chart 版本 pin 部署前须 `helm search repo` 人肉核对"这一环，regex manager 可覆盖 `argocd/applications/*.yaml` 的 `targetRevision`。

8. **恢复演练自动化**：每月 CronJob 从 restic restore 最新 Vault/PG 快照到临时目录做校验（`pg_restore --list`、文件 checksum），失败告警。把一次性"演练"变成持续验证。

9. **告警噪声治理**：MacBook 睡眠导致的 `TargetDown` 已知会烦人，提前加 Alertmanager 静默/inhibit 规则（CLAUDE.md 里自己标了 "if it bites"）。

---

## 明确不建议做的（防过度工程）

- **homelab 多节点 HA / etcd 三节点**——硬件不支持，单用户收益为零；单节点 + 快速重建（`just homelab-recover` + 本方案备份体系）就是正确形态。
- **storage-106 加入 K8s 集群**——NFS hang 会 wedge 节点是亲测过的，存储主机混入计算只放大爆炸半径。
- **LGTM 整体搬迁 / Thanos·Mimir·对象存储长期化**——搬迁窗口长、双写复杂；加内存 + retention 控制就够。
- **CNPG 之类 Postgres operator**——pg_dump + restic 对这个规模已够，别为运维一个 operator 而运维。
- **Cert-Manager**（roadmap Phase 5）——建议**降级/划掉**：TLS 在 Cloudflare 边缘终结、集群内走 HTTP，没有内网直连 TLS 的实际需求前它是纯负担（结论已在 ROADMAP 执行，见"❌ 已划掉"一节）。
- **Vault auto-unseal**（roadmap High Effort）——单用户下 sealed 已被 ESO 告警覆盖、恢复路径已文档化；transit auto-unseal 要再养一个 Vault，不值。保持手动，优先级排在以上所有事之后。
- **ClusterMesh / Cilium 网络策略扩大用途**——维持现状，与 2026-03 简化建议方向一致。

---

## 建议执行顺序

1. **本周末**：离站备份（P0-1）+ dead-man's switch（P0-2 前半）——消掉仅有的"不可逆损失"和"静默死亡"风险。
2. **下个迭代**：Gotify 迁 oracle、zpool 冗余确认、恢复演练跑通一次。
3. **一个月内**：pve 内存升级（下单即可）、Renovate 接入。
4. **随后**：DGX 入编三件套（IaC + GPU 指标 + Bifrost fallback/SLO）。

其中第 1、2、8 项本质是把 `docs/plans/ROADMAP.md` 里躺了三个月的 unchecked 项提到最前——方向早已判断正确，缺的只是排期。

---

## 附：关于把 storage-106 加入 homelab 集群（2026-07-04 专项评估）

**结论：技术上可行，但不建议。**

**实测事实**：106 是 **Proxmox VE 9.0.3** 主机（非裸 NAS），CPU = **Celeron J4105 4 核 @ 1.5GHz**（约 5600H 的 1/8 算力），RAM = **7.6GB 总 / ~5GB 可用**（ARC 封顶 0.8GB），是全集群 PVC 的 NFS 后端。现有 homelab 节点瓶颈是**内存**（live 71%）而非 CPU（live 23%）。

**不建议的三个决定性理由**：

1. **增容无效**——缺的是内存，106 可用内存（~5GB）比现 VM 余量还少，CPU 弱 8 倍。
2. **放大爆炸半径**——计算压上存储后端，失控 Pod 拖垮 106 → NFS 挂 → 全集群 PVC hang（`nfs-hang-wedges-node` 的集群级版本）。计算/存储分离正是它稳的原因。
3. **DaemonSet 税 + 监控冲突**——所有 DS 会调度到这台弱鸡；且 106 已有宿主机级 node_exporter(:9100)，in-cluster DS 版本会冲突/重复计数。

单控制面下 106 只能当 worker，给不了 HA；太弱也当不了第二控制面 → 既不增容也不增可用性。

**若确有理由**：因 106 是 Proxmox，相对不糟的做法是**在 106 上开受限 VM（封 3GB）当 worker**，靠 hypervisor 隔离保护 NFS/ARC——而非直接在存储宿主机装 k3s agent。但净收益仅"一个 3GB/1.5GHz 弱节点"，不值。

**对症方案**：想增内存 → 给 pve 加内存条（P1-4）；想要真·第二计算节点 → 加一台 N100 级迷你 PC 当 worker，勿复用存储机。

**106 的正确用法（不是加计算，而是升级存储层）**：抬 ARC 读缓存 + ZFS 快照 + 云端离站,把它从"单点裸盘"变成三层受保护存储——同时落地本文档 P0-1 的离站备份。执行细节（备份方案待重新设计）见 **`docs/plans/2026-07-04-storage-106-utilization-and-backup-simplification.md`**。
