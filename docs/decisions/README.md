# Decisions

> 关键技术决策记录 (轻量 ADR)。记录当时场景、选项、取舍。

1. [gateway-controller-evaluation.md](gateway-controller-evaluation.md) — Traefik vs Cilium Gateway 评估
2. [argocd-image-updater.md](argocd-image-updater.md) — ArgoCD Image Updater CRD 模型与约束
3. [alerting-telegram-migration.md](alerting-telegram-migration.md) — Gotify bridge 崩溃 bug → Alertmanager 原生 Telegram（含 Gotify 插件方案评估）
4. [external-dns-adoption.md](external-dns-adoption.md) — 子域名 DNS 从 Terraform 手管 → HTTPRoute 声明式（含 Crossplane 否决、upsert-only 共存安全性）
5. [opencost-krr-data-sources.md](opencost-krr-data-sources.md) — 同一个 cAdvisor 缺口，OpenCost 走 collector 旁路、KRR 补窄口径采集（含 krr-enforcer 否决、一处论据自我更正）
6. [orphaned-resources.md](orphaned-resources.md) — 配置漂移体检选型：否决 kor（信噪比 0.6%，且误判 argocd-secret/vault-token 等要害），改用 ArgoCD 原生 `orphanedResources` 且 `warn: false`
7. [manifests-directory-per-app.md](manifests-directory-per-app.md) — `k8s/helm/manifests/` 目录化：一个 App 一个目录（目录即清单），废除 `directory.include` glob；`values/` 命名统一 `<app>.yaml`
8. [manual-helm-to-argocd-adoption.md](manual-helm-to-argocd-adoption.md) — 采纳现存 Helm release 的渲染等价性验证法；CRD 陈旧与迁移解耦（`skipCrds`）；更正「`fullnameOverride` 可解决跨集群同 chart」的旧说法（正解是 `helm.releaseName`）；otel-collector 其实从未部署

## ADR Convention

新建决策记录:
- 命名: **描述性 kebab-case**，`<topic>.md`（如 `external-dns-adoption.md`）——上面 8 条全部如此，
  沿用即可。（本节此前写的是 `NNNN-title.md` 编号式，但**从未有任何一条 ADR 采用**，
  2026-07-31 改为记录实际约定。日期写在文首，不靠文件名排序。）
- 必含: 标题/日期/状态/上下文(Context)/决策(Decision)/后果(Consequences)
- 决策被推翻时**不删旧文件**：改文首状态为 `已废弃`，并链到取代它的记录
