# Decisions

> 关键技术决策记录 (轻量 ADR)。记录当时场景、选项、取舍。

1. [gateway-controller-evaluation.md](gateway-controller-evaluation.md) — Traefik vs Cilium Gateway 评估
2. [argocd-image-updater.md](argocd-image-updater.md) — ArgoCD Image Updater CRD 模型与约束
3. [alerting-telegram-migration.md](alerting-telegram-migration.md) — Gotify bridge 崩溃 bug → Alertmanager 原生 Telegram（含 Gotify 插件方案评估）
4. [external-dns-adoption.md](external-dns-adoption.md) — 子域名 DNS 从 Terraform 手管 → HTTPRoute 声明式（含 Crossplane 否决、upsert-only 共存安全性）
5. [opencost-krr-data-sources.md](opencost-krr-data-sources.md) — 同一个 cAdvisor 缺口，OpenCost 走 collector 旁路、KRR 补窄口径采集（含 krr-enforcer 否决、一处论据自我更正）
6. [orphaned-resources.md](orphaned-resources.md) — 配置漂移体检选型：否决 kor（信噪比 0.6%，且误判 argocd-secret/vault-token 等要害），改用 ArgoCD 原生 `orphanedResources` 且 `warn: false`

## ADR Convention

新建决策记录:
- 命名: `NNNN-title.md` (如 `0003-use-restic-over-kopia.md`)
- 必含: 标题/日期/状态/上下文/决策/结论/后果
