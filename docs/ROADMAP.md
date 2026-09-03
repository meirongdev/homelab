# Homelab Roadmap

> Last updated: 2026-09-03
> 本文只回答两件事：**还剩什么没做**，和**为什么不做**。做过什么在
> [CHANGELOG.md](CHANGELOG.md)（2026-09-02 拆出，原因见那里）。
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
| 13 | **oracle 清单树拆 App** | `cloud/oracle/manifests/` 仍是 140 个对象的单体 kustomize 树、一个 App 同步：任一文件坏掉整个集群停同步，且新文件漏登记 `kustomization.yaml` 就静默不生效（homelab 侧 2026-07-31 已改掉，oracle 侧没跟）。**不阻塞任何东西**，纯布局债。步骤已备好，需一个维护窗口 + 有人盯：[runbook](runbooks/oracle-manifests-split-to-apps.md)。☠️ `namespace.yaml` 一律不动，否则重放 2026-08-03 的级联删除 |
| 12 | **低优先 / 可选** | **Renovate 只做完一半**：配置与 CI 已合入，但 GitHub App 仍未安装，至今一个 PR 都没开过（判据：`git ls-remote --heads origin` 无 `renovate/*`）。装 App 是纯人工一步（[决策](decisions/renovate-adoption.md)，状态 🚧）· MacBook `TargetDown` 静默规则 · Vault Dynamic Secrets（规模不需要）· Cloudflare Pro WAF。（母文档 P2） |

### 已知问题（不阻塞，无人认领）

- **ClusterMesh 是纯待命能力，缺自愈**（监测缺口已闭环）。2026-08-05 曾静默断开约一个月，
  根因是 apiserver up-but-stuck 且不自愈，配置从未丢过；重建靠
  `just connect-clustermesh <homelab-ts>:32379 <oracle-ts>:32379`。告警兜底与 oracle 侧 peer
  固化均已补齐。仍未做的是自愈：两集群 `service.cilium.io/global` Service 都是 0，
  ClusterMesh 纯待命，加自愈探针不划算；另一条路是明确退役它、跨集群一律走 NodePort。
  机制与判据见 [reference/tailscale-network.md](reference/tailscale-network.md)。

- **DGX 再换模型时值得先做掉的优化**（这次的成本：16 处 git 字面值人肉搜替 + 8 把虚拟 key
  + 3 条阈值 + 7 项现场采集，全靠记忆串联）。四件事：① CI 字面值门禁（漏改一处从静默 404
  变 CI 红灯）；② 契约回归脚本（判据只认 `usage`，识破"200 但空操作"）；③ 虚拟 key 卫生
  —— 顺带修一个**当下就坏**的缺陷：16 把 key 只有 1 把有 alias，且 4 把的白名单里还挂着
  已死的 `mac/qwen3.6-35b`，那几条 fallback 现在就是断的；④ served name 漂移哨兵 ——
  ☠️ 形态已从"json-exporter 抓 `/v1/models`"改成**一条 PromQL**（vLLM 指标自带 `model_name`
  且已被 `vllm-dgx-spark` 抓取）。展开方案与否决项 →
  [plans/apps/2026-09-03-dgx-model-swap-optimizations.md](plans/apps/2026-09-03-dgx-model-swap-optimizations.md)；
  SOP 与七项采集清单见
  [runbooks/dgx-model-swap-homelab-followup.md](runbooks/dgx-model-swap-homelab-followup.md)。

- **DGX 新主力栈的质量闸门没跑**。2026-09-02 换栈只过了速度闸门：NVFP4 是无校准 RTN
  量化，公开分数由量化方自报，本仓库未独立验证（aider-polyglot 在 nv-dgx-spark 侧待跑）。
  跑挂就 `make qwen38fn-rollback` 回 V4-Flash —— ☠️ 那要把网关别名 + jobs-sg +
  Open Notebook + oracle calibre **四处一起回退**，外加虚拟 key 白名单，见
  [litellm-gateway.md](reference/litellm-gateway.md) 坑 A。

- **jobs-sg 的 `DisableThinking` 在新栈上是静默空操作**。它发的是
  `chat_template_kwargs {"thinking": false}`（旧栈的 kwargs 名），新栈只认
  `enable_thinking`：实测 `{"thinking":false}` 的 reasoning tokens 是 134（基线 142），
  `{"enable_thinking":false}` 才是 0。默认不发这个字段所以线上没坏，但**别指望用它清积压**
  （白花约 6 倍 token）。改 kwargs 名是 jobs-sg 上游仓库的活，见
  [jobs-sg.md](reference/jobs-sg.md)。

- **DGX 别名的 key 白名单已同步，但 fallback 是否也受白名单约束仍未验证**。
  2026-09-03 实测 16 把 key 有 8 把引用 DGX 别名（已全部换成新名），其中 4 把**只有**
  DGX 别名、白名单里没有 `mac/ornith`。按坑 A 的推论它们的"主→兜底"拿不到兜底，
  但要证实得制造 DGX 不可达 —— 共享 GPU 机器不能为验证去停。判据见
  [litellm-gateway.md](reference/litellm-gateway.md) 坑 A。

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

### 待重评（触发条件已满足，结论还没重看）

☠️ **否决不是永久的，但没人盯着触发条件就等于永久。**2026-09-02 首次汇总时发现：
「加第二台 worker 时重评」这条触发条件早在 **2026-08-13 就满足了**（`k8s-worker-106` 入编），
而 Talos 与多节点 HA 两条结论从那天起再没被看过一眼，ADR 与复盘里也都没提。
新写否决类结论时把触发条件同时登记到这张表，否则它只活在正文里没人读。

| 条目 | 触发条件 | 何时满足 | 现状 |
|------|---------|---------|------|
| [Talos 迁移](plans/architecture/2026-07-07-tech-debt-and-evolution.md) | 加第二台 worker | 2026-08-13 | ⏳ 未重评。⚠️ 重评时注意前提已变：worker 是 106 上的 VM、跨网段、多一条 ip rule，"重装成本低"这条对它不成立 |
| homelab 多节点 HA / etcd 三节点 | 加第二台 worker（与 Talos 一并） | 2026-08-13 | ⏳ 未重评。硬件那条理由仍然成立（worker 只有 2c/4G），但"单节点"这个前提本身已经不对了 |
| [Crossplane](decisions/crossplane-not-adopted.md) | ADR 文末四条，满足其一 | 未满足 | ✅ 结论有效 |
| [cf-analytics 自写 exporter](decisions/cf-analytics-custom-exporter.md) | zone 升 Pro/Business，或上游 exporter 支持 Free zone | 未满足 | ✅ 结论有效 |
| [DGX 不接 ClusterMesh](decisions/dgx-clustermesh-not-adopted.md) | ADR 文末条件 | 未满足 | ✅ 结论有效 |
| [Multica 邮件走 Gmail SMTP](decisions/multica-email-delivery.md) | ADR 文末条件 | 未满足 | ✅ 结论有效 |
| [OMLX 四个语音模型不采纳](decisions/omlx-speech-model-selection.md) | ADR 文末条件 | 未满足 | ✅ 结论有效 |
| [自研应用不打 chart](decisions/no-helm-chart-for-in-house-apps.md) | ADR 文末四条，满足任一 | 未满足 | ✅ 结论有效 |
| [ArgoCD project 按集群拆](decisions/argocd-project-per-cluster.md) | 要消费 orphanedResources 告警，或第三个集群入编 | 未满足 | ✅ 结论有效 |

---

## 做过什么

已完成的条目（Phase 1-5 + 审计与清理）2026-09-02 拆到 [CHANGELOG.md](CHANGELOG.md)。
本文只留「还没做」与「不做」两类，这样开放项不会被历史淹没。
