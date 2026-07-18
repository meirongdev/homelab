# Decisions

> 关键技术决策记录 (轻量 ADR)。记录当时场景、选项、取舍。

1. [gateway-controller-evaluation.md](gateway-controller-evaluation.md) — Traefik vs Cilium Gateway 评估
2. [argocd-image-updater.md](argocd-image-updater.md) — ArgoCD Image Updater CRD 模型与约束
3. [alerting-telegram-migration.md](alerting-telegram-migration.md) — Gotify bridge 崩溃 bug → Alertmanager 原生 Telegram（含 Gotify 插件方案评估）

## ADR Convention

新建决策记录:
- 命名: `NNNN-title.md` (如 `0003-use-restic-over-kopia.md`)
- 必含: 标题/日期/状态/上下文/决策/结论/后果
