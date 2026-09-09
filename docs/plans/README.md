# Plans

> **这是档案，不是现状。** 每份 plan 记录写它那天的世界——里面的路径、版本、拓扑可能早就
> 变了（Traefik、Kopia、Gotify、NFS 都还活在某些 plan 里）。
>
> 要知道**今天**是什么样：读 [reference/](../reference/README.md)。
> 要知道**还剩什么没做**：读 [../ROADMAP.md](../ROADMAP.md)。

2026-09-09 起 plans **不再分类别子目录**（原 apps/networking/observability/security/architecture/storage
六个目录已扁平化）：按类别归档的收益抵不上六份索引的维护成本，且多数方案本来就横跨两三个类别。

## 当前方案

东西还在跑、或还打算做的。**已完成且东西还在跑的不归档**——它们解释了系统为何是现在这样。

| 日期 | 方案 | 状态 |
|------|------|------|
| 2026-09-03 | [DGX 换模型提速：事故式切换 → 改一个值 + 跑两条命令](2026-09-03-dgx-model-swap-optimizations.md) | 📐 设计（未实施；[换栈 SOP §8](../runbooks/dgx-model-swap-homelab-followup.md) 的展开） |
| 2026-08-16 | [多媒体仓库（音乐 / 自录 podcast / 视频）](2026-08-16-multimedia-repository.md) | ⚠️ 部分完成（Jellyfin/Navidrome/podcast 已上线） |
| 2026-08-16 | [多媒体目录重组（storage-106 `/storage/tv` 清理去重）](2026-08-16-media-directory-reorganization.md) | ✅ 已完成（回收 ~146G） |
| 2026-08-08 | [jobs-sg 三处问题诊断](2026-08-08-jobs-sg-three-defect-diagnosis.md) | ✅ 已完成（两处真缺陷已修复并部署） |
| 2026-08-03 | [Terraform state → R2](2026-08-03-tf-state-r2.md)（5 个 root 迁远程后端） | 📐 设计（等 R2 桶 + token） |
| 2026-08-03 | [离站备份（restic copy → 云）](2026-08-03-offsite-backup.md) | 📐 设计（等开云桶） |
| 2026-08-02 | [homelab → oracle 负载迁移](2026-08-02-homelab-to-oracle-workload-migration.md)（Loki/Tempo + ArgoCD + calibre 全迁完，含残余清扫；**推翻 2026-07-04 的两条结论**。可复用 SOP 已提炼为 [runbook](../runbooks/stateful-service-cross-cluster-migration.md)） | ✅ 已完成（Vault 仍为剩余候选） |
| 2026-08-01 | [LiteLLM LLM 网关迁移（替换旧网关）](2026-08-01-litellm-gateway-migration.md) | ✅ 已完成（2026-08-16 上线；现状见 [decisions/litellm-llm-gateway.md](../decisions/litellm-llm-gateway.md)） |
| 2026-08-01 | [Open Notebook 部署（homelab k3s）](2026-08-01-open-notebook-homelab.md) | ✅ 已完成（现状见 [reference/open-notebook.md](../reference/open-notebook.md)） |
| 2026-07-30 | [OpenCost 双集群成本可观测](2026-07-30-opencost-multicluster.md) | ✅ 已完成（定价仍为占位值） |
| 2026-07-30 | [KRR 双集群资源右尺寸周报](2026-07-30-krr-rightsizing.md) | ✅ 已完成 |
| 2026-07-07 | [技术债盘点与演进路线](2026-07-07-tech-debt-and-evolution.md)（Crossplane 结论已拆成 [ADR](../decisions/crossplane-not-adopted.md)） | ⚠️ 部分落地 |
| 2026-07-06 | [存储本地化迁移 + 备份体系重建](2026-07-06-storage-local-migration-and-backup-redesign.md) | ⚠️ 部分完成（Phase 0-4 ✅，Phase 5 离站备份未做） |
| 2026-07-04 | [ZITADEL 迁移至 oracle-k3s](2026-07-04-zitadel-to-oracle-k3s.md) | ✅ 已完成 |
| 2026-07-04 | [舰队机器与集群架构优化](2026-07-04-fleet-architecture-optimization.md)（ROADMAP 的 `P0-x`/`P1-x`/`P2-x` 编号出自这里；文首有拆分导航，**四条结论已被推翻**） | ⚠️ 部分落地 |
| 2026-06-18 | [Phase 2 运行时检测 — Tetragon + Falco](2026-06-18-runtime-detection.md) | ✅ 已完成 |
| 2026-06-16 | [K3s 集群内部安全加固 Phase 0+1](2026-06-16-k3s-security-hardening.md) | ⚠️ 部分完成（节点 CIS 待重启生效） |
| 2026-06-15 | [Grafana 监控面板整改](2026-06-15-grafana-dashboard-reorg.md) | ✅ 已完成（面板组织约定见 [observability-alerting-slo.md](../reference/observability-alerting-slo.md)） |
| 2026-06-04 | [oracle-k3s 纳入 ArgoCD GitOps](2026-06-04-oracle-k3s-argocd-gitops.md) | ✅ 已完成（**方向已反转**，控制面现在 oracle 侧） |
| 2026-03-08 | [Cilium + ZITADEL SSO 重建](2026-03-08-cilium-zitadel-sso-plan.md) | ✅ 已完成（落点为应用原生 OIDC） |
| 2026-03-08 | [Cilium Gateway / ClusterMesh 稳定化](2026-03-08-cilium-gateway-clustermesh-stabilization.md) | ✅ 已完成 |
| 2026-03-07 | [Cilium 引入后架构调整与服务修复](2026-03-07-post-cilium-fix-plan.md) | ✅ 已完成 |
| 2026-03-06 | [homelab Cilium Mesh 安装](2026-03-06-cilium-mesh-installation.md) | ✅ 已完成（**CNI 选型的唯一记录**，无独立 ADR，别归档） |
| 2026-03-02 | [Timeslot 部署](2026-03-02-timeslot-deployment.md) | ✅ 已完成 |
| 2026-03-01 | [OTel Tracing & Collector 改进](2026-03-01-otel-tracing-improvement.md) | ✅ 已完成（collector 形态后续又变过） |
| 2026-02-22 | [Oracle 迁移与跨集群可观测](2026-02-22-oracle-migration-observability.md) | ✅ 已完成 |
| 2026-02-21 | [Uptime Kuma 部署](2026-02-21-uptime-kuma-deployment.md) | ✅ 已完成 |
| 2026-02-21 | [OTel 日志迁移](2026-02-21-otel-log-migration.md) | ✅ 已完成（Promtail 已移除；含原设计的选型 tradeoff） |
| 2026-02-21 | [Grafana Loki 面板](2026-02-21-grafana-loki-dashboards.md) | ✅ 已完成（含原设计的选型 tradeoff） |
| 2026-02-21 | [Calibre-Web-Automated 迁移](2026-02-21-calibre-web-automated-migration.md) | ✅ 已完成（含原设计的选型 tradeoff） |
| 2026-02-20 | [Oracle Cloud Free Tier K3s 集群](2026-02-20-oracle-cloud-k3s-cluster.md) | ✅ 已完成 |

## 已归档

东西不存在了（从未实施 / 已取消 / 已被取代 / 完成后又整体退役 / 前提消失）——
读它对理解当前系统帮不上忙。清单与死因见 [archive/](archive/README.md)。

## 写新 plan

1. 路径：`docs/plans/YYYY-MM-DD-<topic>.md`（**不分子目录**）
2. 文首必须有 `日期` + `状态` + `结论`；状态取 [R4 枚举](../RULES.md#r4-状态枚举)
3. **完成后把稳定结论回写 `reference/`**，然后就不要再改这份 plan 了——它从此是历史快照
4. 被取代时不删文件：文首标状态 + 链到取代它的文档
5. 更新本页索引

完整规则见 [文档组织规则](../RULES.md)。
