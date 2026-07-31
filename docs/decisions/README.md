# Decisions

> 关键技术决策记录（轻量 ADR）：当时的场景、可选项、为什么这么选。

| 决策 | 结论 |
|------|------|
| [gateway-controller-evaluation](gateway-controller-evaluation.md) | Traefik vs Cilium Gateway → 选 Cilium Gateway API 作唯一入口 |
| [external-dns-adoption](external-dns-adoption.md) | 子域名 DNS 从 Terraform 手管 → HTTPRoute 声明式。含 Crossplane 否决、`upsert-only` 共存安全性 |
| [manual-helm-to-argocd-adoption](manual-helm-to-argocd-adoption.md) | 采纳现存 Helm release 的**渲染等价性验证法**；`skipCrds` 把 CRD 陈旧与迁移解耦。⚠️ 跨集群同 chart 的正解是 `helm.releaseName` 而非 `fullnameOverride` |
| [manifests-directory-per-app](manifests-directory-per-app.md) | `k8s/helm/manifests/` 一个 App 一个目录（目录即清单），废除 `directory.include` glob |
| [otel-2026-alignment](otel-2026-alignment.md) | homelab collector 首次落地（k8s 裁剪发行版）+ oracle 现代化（container operator、file_storage 持久队列、0.120→0.156） |
| [alerting-telegram-migration](alerting-telegram-migration.md) | gotify-bridge 有 `concurrent map writes` 崩溃 bug → 改 Alertmanager 原生 Telegram，Gotify 整体退役 |
| [opencost-krr-data-sources](opencost-krr-data-sources.md) | 同一个 cAdvisor 缺口，OpenCost 走 collector 旁路、KRR 补窄口径采集。含 krr-enforcer 否决 |
| [orphaned-resources](orphaned-resources.md) | 配置漂移体检否决 kor（信噪比 0.6%，误判 `argocd-secret`/`vault-token`），改用 ArgoCD 原生 `orphanedResources` + `warn: false` |
| [argocd-image-updater](argocd-image-updater.md) | CRD 模型与约束（⚠️ 当前闲置，集群内无 `ImageUpdater` CR） |

## 写新 ADR

- **命名**：描述性 kebab-case `<topic>.md`（如 `external-dns-adoption.md`），日期写在文首、不靠文件名排序。
- **必含**：标题 / 日期 / 状态 / 上下文 Context / 决策 Decision / 后果 Consequences。
- **决策被推翻时不删旧文件**：把文首状态改成 `已废弃`，并链到取代它的记录。
