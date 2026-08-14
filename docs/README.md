# Homelab Docs Portal

> Last updated: 2026-08-14
> 这是**入口索引**。运行态事实都在下面链接的文档里，本页不复制副本。
> 写文档的强制规则（R1–R7）见 [RULES.md](RULES.md)，本页只做导航。

## 从哪里开始

| 想知道什么 | 读这个 |
|-----------|--------|
| 整体长什么样 | [ARCHITECTURE.md](ARCHITECTURE.md) — 单页双集群总览 |
| 怎么在这个 repo 里干活 | [AGENTS.md](AGENTS.md) — 命令、约定、硬约束（**唯一 AI 上下文**，根 `AGENTS.md`/`CLAUDE.md`/`.gemini.md`/copilot 都软链到它）；各组件细节按域在 [reference/](reference/README.md) |
| 现在跑着哪些服务 | [reference/services.md](reference/services.md) — **服务清单唯一真相源** |
| 还剩什么没做 | [ROADMAP.md](ROADMAP.md) — 开放项 + 已完成 + 明确不做 |
| 出事了怎么办 | [runbooks/](runbooks/README.md) — 可直接执行的 SOP |
| 为什么是这个方案 | [decisions/](decisions/README.md) — 轻量 ADR |
| 安全做到哪一层 | [reference/security.md](reference/security.md) — 逐层状态 + 威胁覆盖矩阵 |

## 目录一览

| 目录 | 内容 |
|------|------|
| [reference/](reference/README.md) | 当前生效的架构事实（source of truth） |
| [decisions/](decisions/README.md) | 轻量 ADR |
| [runbooks/](runbooks/README.md) | 可执行运维 SOP |
| [guides/](guides/README.md) | 跨领域任务流程 |
| [records/](records/README.md) | 故障复盘 |
| [plans/](plans/README.md) | 带日期的方案档案（6 个类别） |
| `assets/` | 图片/架构图（目前为空） |

## 推荐阅读顺序

1. [ARCHITECTURE.md](ARCHITECTURE.md) — 先看全局
2. [reference/tailscale-network.md](reference/tailscale-network.md) — 跨集群网络（最容易踩坑的一层）
3. [reference/observability-multicluster.md](reference/observability-multicluster.md) — 日志/指标/追踪怎么汇总
4. [reference/security.md](reference/security.md) — 纵深防御 11 层，注意第 9 层只到"可见性"
5. [runbooks/backup-recovery.md](runbooks/backup-recovery.md) — 备份与恢复

## 新增 / 修改文档

写文档前先读 [RULES.md](RULES.md) 的 **R1–R7**（目录归属/命名/文首字段/状态枚举/索引维护/
唯一真相源），CI 的 `check-docs.py` 强制（`python3 scripts/check-docs.py`）。
放错目录、漏建索引都算违规。
