# homelab → oracle-k3s 负载迁移

> 日期: 2026-08-02
> 状态: ✅ Phase 2(Loki/Tempo) + Phase 3(ArgoCD) + calibre **全部完成**；剩余候选见 §5
> ⚠️ calibre 退役步骤引发过一次事故（Namespace 内嵌在应用清单里→prune 级联删数据），
>   数据已完整恢复，复盘见 [records/2026-08-03-namespace-prune-cascade.md](../../records/2026-08-03-namespace-prune-cascade.md)
> 范围: 盘点 homelab 上还有哪些负载能搬到 oracle-k3s，并执行其中两项
> 定位: 承接 [2026-07-04 舰队架构优化](2026-07-04-fleet-architecture-optimization.md)
>   的「算力倒挂 / 故障域集中」问题陈述，但**推翻了它的两条结论**（见 §4）

## 1. 触发的实测数字

| | homelab (k8s-node) | oracle-k3s |
|---|---|---|
| CPU | 8 vCPU，实测 **795m (10%)** | 4 vCPU，实测 303m (7%) |
| 内存 | 11.37 GiB 可分配，实测 **8853 Mi (76%)** | 21.4 GiB 可分配，实测 8375 Mi (38%) |
| 磁盘 | 123.7 GB，已用 80.7 GB，**仅剩 43 GB (66%)** | 194 GB，已用 37 GB，**剩 157 GB** |
| 架构 | x86_64 | **aarch64** ← 硬过滤条件 |

**结论：homelab 的瓶颈是内存与磁盘，不是 CPU（才 10%）。** 搬迁应冲着腾内存/磁盘去，
搬走「CPU 密集但内存小」的东西没有意义。

## 2. 可搬清单（完整盘点）

| # | 工作负载 | 释放内存 | 释放磁盘 | arm64 | 结论 |
|---|---|---|---|---|---|
| 1 | calibre-web (CWA) + 2 个 CronJob | ~203 Mi | **38 GB** | ✅ 已核实 | ✅ **2026-08-03 完成** |
| 2 | **Loki + loki-gateway + Tempo** | ~240 Mi | ~5 GB | ✅ | ✅ **本次完成（Phase 2）** |
| 3 | **ArgoCD**（5 个 pod） | **~730 Mi** | — | ✅ | ✅ **本次完成（Phase 3）** |
| 4 | Vault | ~160 Mi | ~12 GB PVC | ✅ | 未做（方向性决策，见 §4）|

### 硬阻塞，不能搬

- **open-notebook + surrealdb（717 Mi，homelab 上最肥的一块）** —— 两台 DGX Spark 与
  Mac OMLX 是**跨 tailnet 按「人」共享**的节点，`meirongdev@` 的设备可达，
  oracle 的 tagged-device **在 netmap 里根本没有它们**。搬过去 = 模型后端全断。
  已记录在 [../../reference/open-notebook.md](../../reference/open-notebook.md)。
- **bifrost（及设计中替换它的 LiteLLM）** —— 同一原因，`bifrost.yaml:4-6` 的注释就是为此写的。
- **集群本地基础设施** —— 概念上不是「搬」，只能各集群一份：cilium / coredns /
  local-path / metrics-server / kyverno（准入 webhook）/ tetragon / kube-bench /
  trivy-operator / ESO / external-dns / cloudflared / opencost / restic CronJob /
  node-exporter / otel-collector agent。
- **Prometheus + Alertmanager + Grafana** —— 技术上能搬但不该搬：Prometheus 要贴着
  抓取目标；Alertmanager 单独搬**零收益**（homelab 死了 Prometheus 也死了，本来就发不出，
  这个洞已由 Watchdog→Kuma dead-man's switch 补上）；Grafana 跟 Prometheus 走最省事。

## 3. 已执行

### Phase 2 —— Loki + Tempo 迁 oracle

数据流反转：**日志/追踪汇聚在 oracle，指标仍汇聚在 homelab**。
架构事实见 [../../reference/observability-multicluster.md](../../reference/observability-multicluster.md)。

验证：oracle Loki 中 `cluster` 标签同时可见 `homelab` 与 `oracle-k3s`；
Grafana 两个 datasource 健康检查均 OK（跨 Tailscale RTT ~175ms）。

途中修掉两个**既有的静默 bug**（都不是本次引入）：

1. **Tempo 从未真正持久化。** `persistence` 是 grafana/tempo chart 的**顶层**键，
   而 values 里写在 `tempo.persistence` 之下 —— 无效键，不报错。homelab tempo STS 的
   `volumeClaimTemplates` 实测为空，即一直跑在 emptyDir 上，每次 Pod 重启丢光全部 trace，
   与 values 里宣称的「7 天保留」不符。同 `tempo.image.tag` 那个坑。
2. **oracle otel-collector 改配置不生效。** 它是裸 manifest（非 Helm），ConfigMap 更新后
   DaemonSet spec 没变 → Pod 根本不重启（实测 age 2d5h / 0 restart），而 OTel Collector
   只在启动时读一次配置文件。**此前任何对该配置的修改都是静默无效的。**
   已改用 kustomize `configMapGenerator`（内容哈希后缀 → 配置一变名字就变 → 自动滚动）。

### Phase 3 —— ArgoCD 控制面迁 oracle

操作 SOP、回滚路径、退役地雷全部收进
[../../runbooks/argocd-control-plane-on-oracle.md](../../runbooks/argocd-control-plane-on-oracle.md)。

核心风险点是 **`https://kubernetes.default.svc` 的所指会跟着控制面变**：
不重写 destination 就推送，旧控制面会把整棵 oracle kustomize 树部署到 homelab。
因此「重写 destination」与「冻结旧控制面」必须成对发生。

去风险手法（值得复用）：先把 `automated` 剥掉、把 Application apply 到新控制面，
让它**只算 diff 不动手** —— 27 个里 26 个直接 Synced/Healthy，证明两个控制面从同一份
git + 同样的 chart 版本算出完全一致的期望状态，接管不会有意外改动。之后再冻结、推送、
恢复 automated。切换后实测 **28/28 Synced+Healthy**，两集群零异常 Pod。

## 4. 与 2026-07-04 舰队文档的分歧（重要）

那份文档的目标态表把 pve 定为「数据面/有状态核心（Vault、ArgoCD、LGTM）」，
并明确写了「**LGTM 整体搬迁不建议**」「相比之下把 LGTM 搬去别的机器复杂度高得多、
收益反而低」。本次推翻其中两条，理由：

1. **它把 LGTM 当成一个不可分割的整体。** 实际上 Loki/Tempo 是纯「写入-存储」组件，
   与 Prometheus 的「必须贴着抓取目标」是完全不同的约束。只搬这个子集，
   既没有它担心的「双写复杂度」，也没有「搬迁窗口长」——实测两个提交、无停机。
2. **它对 ArgoCD 的判断基于「pve 加内存」这条路。** 而同一份文档 §4 后来自己核实了
   `dmidecode -t 16` 的 `Maximum Capacity: 16 GB` 且两槽已满 —— 加内存这条路大概率走不通，
   核显 UMA 那 ~1.5-2GB 也已经收完了。前提没了，结论就得重算。

**仍然同意**它的：Prometheus/Grafana/Alertmanager 不搬、homelab 不做多节点 HA、
storage-106 永不进集群、Crossplane 否决。

Vault 是唯一保留分歧的一项：舰队文档把它留在 pve，而它自己列的「故障域集中」
问题又点了 Vault 的名。本次未动，判断留给下一轮 —— 它的内存收益很小（~160 Mi），
真正的收益是「homelab 重启后 Vault sealed 期间 oracle 刷不了密钥」这个窗口，
属可用性而非容量问题，不该和本次的容量目标混在一起做。

## 5. 收尾实测 + 剩余候选

### 迁移前后（实测）

| | 迁移前 | 迁移后 |
|---|---|---|
| homelab pod 内存合计 | ~6.2 GB | **5.2 GB**（-1.0 GB；calibre 迁走后节点用量进一步降到 67%）|
| homelab 节点 MemAvailable | 3.3–4.2 GB | **4.4 GB** |
| homelab 磁盘可用 | 43.0 GB | **84.0 GB**（65%→32%；Loki 只省了 0.5GB，真正的 38GB 来自 calibre）|
| oracle 内存 | 8375 Mi (38%) | 9715 Mi (44%) |
| ArgoCD Applications | 28（homelab 控制面）| **28/28 Synced+Healthy**（oracle 控制面）|

⚠️ **别用 `kubectl top nodes` 的百分比衡量这类迁移的收益**：homelab 节点 workingSet
8463 Mi 里有 **3236 Mi 是 OS/页缓存**，删 Pod 不会让它缩（页缓存是可回收的，但不会
主动释放）。所以节点百分比只从 76% 动到 72%，而 Pod 层面实际释放了整整 1.0 GB。
要看真实头寸就看 **MemAvailable**，或把各 Pod 的 workingSet 加总。

**磁盘几乎没省** —— Loki 的 PVC 配额虽是 5Gi，7 天保留期下实际只占约 0.5 GB。
homelab 的磁盘压力（65%，剩 43.5 GB）**得靠搬 calibre 才能解决**，那才是 38 GB。

### 剩余候选

| 项 | 说明 |
|---|---|
| **Vault 迁 oracle** | 见 §4，属可用性议题而非容量议题，内存收益仅 ~160 Mi |
| ~~calibre 镜像不再被扫描~~ | ✅ **2026-08-03 已解决**：oracle 也上了一份 trivy-operator（`values/trivy-operator-oracle.yaml`），accepted-risk CVE 按镜像实际所在集群重排。顺带覆盖了同期迁过去的 ArgoCD/Loki/Tempo |
| Vault 孤儿 path 清理 | `secret/homelab/argocd-oracle-cluster` 随本次迁移失去消费者，未删 |

## 相关

- [2026-07-04 舰队架构优化](2026-07-04-fleet-architecture-optimization.md)（本文推翻其两条结论）
- [ArgoCD 控制面 runbook](../../runbooks/argocd-control-plane-on-oracle.md)
- [多集群可观测性架构事实](../../reference/observability-multicluster.md)
- [2026-06-04 oracle-k3s 纳入 ArgoCD](../networking/2026-06-04-oracle-k3s-argocd-gitops.md)（反方向的原始设计）
