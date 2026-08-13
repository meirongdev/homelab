# Decisions

> 关键技术决策记录（轻量 ADR）：当时的场景、可选项、为什么这么选。

| 决策 | 结论 |
|------|------|
| [gateway-controller-evaluation](gateway-controller-evaluation.md) | Traefik vs Cilium Gateway → 选 Cilium Gateway API 作唯一入口 |
| [external-dns-adoption](external-dns-adoption.md) | 子域名 DNS 从 Terraform 手管 → HTTPRoute 声明式。含 `upsert-only` 共存安全性 |
| [crossplane-not-adopted](crossplane-not-adopted.md) | ❌ 不引入 Crossplane：最大云面（Cloudflare）provider 2023-01 即死；且控制面管"集群赖以存在的资源"会把 DR 路径搞复杂。含痛点的逐个轻解与重评条件 |
| [manual-helm-to-argocd-adoption](manual-helm-to-argocd-adoption.md) | 采纳现存 Helm release 的**渲染等价性验证法**；`skipCrds` 把 CRD 陈旧与迁移解耦。⚠️ 跨集群同 chart 的正解是 `helm.releaseName` 而非 `fullnameOverride` |
| [manifests-directory-per-app](manifests-directory-per-app.md) | `k8s/helm/manifests/` 一个 App 一个目录（目录即清单），废除 `directory.include` glob |
| [no-helm-chart-for-in-house-apps](no-helm-chart-for-in-house-apps.md) | 自研应用一律 kustomize/目录源，**不打 chart**；Helm 只用于消费上游 chart。含推翻条件 |
| [otel-2026-alignment](otel-2026-alignment.md) | homelab collector 首次落地（k8s 裁剪发行版）+ oracle 现代化（container operator、file_storage 持久队列、0.120→0.156） |
| [alerting-telegram-migration](alerting-telegram-migration.md) | gotify-bridge 有 `concurrent map writes` 崩溃 bug → 改 Alertmanager 原生 Telegram，Gotify 整体退役 |
| [opencost-krr-data-sources](opencost-krr-data-sources.md) | 同一个 cAdvisor 缺口，OpenCost 走 collector 旁路、KRR 补窄口径采集。含 krr-enforcer 否决 |
| [orphaned-resources](orphaned-resources.md) | 配置漂移体检否决 kor（信噪比 0.6%，误判 `argocd-secret`/`vault-token`），改用 ArgoCD 原生 `orphanedResources` + `warn: false` |
| [argocd-image-updater](argocd-image-updater.md) | CRD 模型与约束（⚠️ 当前闲置，集群内无 `ImageUpdater` CR） |
| [storage106-experiment-vm](storage106-experiment-vm.md) | 实验田要"独立小集群"不要"入集群 worker"：同硬件下实验可用内存 2G vs 0.5-0.9G（DaemonSet 入伙税），且爆炸半径归零、不推翻 106 与 prod 的解耦。含 8G 内存三方分配（ARC 2G / 宿主 2.1G / VM 3G） |
| [cluster-placement-for-new-services](cluster-placement-for-new-services.md) | 落点按资源画像选：**计算密集/大流量走 homelab**（7.5 核 + 6.6GB 余量、amd64），轻量无状态仍默认 oracle-k3s（只剩 0.5 核 + 2.6GB）。含必写 CPU limit 与 thermal 代价 |
| [dgx-clustermesh-not-adopted](dgx-clustermesh-not-adopted.md) | ❌ DGX Spark 双机 k3s **不接 ClusterMesh**：那两台机是**外部 tailnet 的共享节点**，节点共享不携带 subnet route → VXLAN 要发往的节点 IP（`192.168.200.x` / `10.10.10.10`）双向不可达，且全程 DERP 2.28 MB/s。改用 homelab 侧 Service + 手写 Endpoints。含 `cluster.id` 撞车（两边都是 1）与 DGX `mtu` 键名拼错从未生效 |
| [shared-postgres-platform](shared-postgres-platform.md) | 手搓 `rss-postgres` → CNPG `apps-pg` 共享库；**不**并入 `zitadel-pg`（节点内存 87% + SSO 带 critical 优先级）。含备份从 `pg_dumpall` 改逐库 `pg_dump` 的连带影响 |

## 写新 ADR

- **命名**：描述性 kebab-case `<topic>.md`（如 `external-dns-adoption.md`），日期写在文首、不靠文件名排序。
- **必含**：标题 / 日期 / 状态 / 上下文 Context / 决策 Decision / 后果 Consequences。
- **决策被推翻时不删旧文件**：把文首状态改成 `已废弃`，并链到取代它的记录。
