# Homelab Docs Portal

> Last updated: 2026-09-09
> 这是入口索引。运行态事实都在下面链接的文档里，本页不复制副本。
> 写文档的强制规则（R1–R8）见 [RULES.md](RULES.md)，本页只做导航。

## 从哪里开始

| 想知道什么 | 读这个 |
|-----------|--------|
| **第一次接触这套系统** | [reference/tech-stack.md](reference/tech-stack.md)：技术栈全景 —— 每个组件是什么、为什么是它、配置钉在哪 |
| 整体长什么样 | [ARCHITECTURE.md](ARCHITECTURE.md)：单页双集群总览 |
| 怎么在这个 repo 里干活 | [AGENTS.md](AGENTS.md)：命令、约定、硬约束。它是**唯一的 AI 上下文文件**，根 `AGENTS.md`/`CLAUDE.md`/`.gemini.md`/copilot 都软链到它；各组件细节按域在 [reference/](reference/README.md) |
| 现在跑着哪些服务 | [reference/services.md](reference/services.md)：**服务清单的唯一真相源** |
| 还剩什么没做 | [ROADMAP.md](ROADMAP.md)：开放项 + 明确不做 + **待重评**（触发条件已满足但没重看的结论） |
| 做过什么 | [CHANGELOG.md](CHANGELOG.md)：已完成条目，一条一行（2026-09-02 从 ROADMAP 拆出） |
| 出事了怎么办 | [runbooks/](runbooks/README.md)：可直接执行的 SOP |
| 为什么是这个方案 | [decisions/](decisions/README.md)：轻量 ADR |
| 安全做到哪一层 | [reference/security.md](reference/security.md)：逐层状态 + 威胁覆盖矩阵 |

## 目录一览

| 目录 | 内容 |
|------|------|
| [reference/](reference/README.md) | 当前生效的架构事实（source of truth） |
| [decisions/](decisions/README.md) | 轻量 ADR |
| [runbooks/](runbooks/README.md) | 可执行运维 SOP |
| [guides/](guides/README.md) | 跨领域任务流程 |
| [records/](records/README.md) | 故障复盘 |
| [plans/](plans/README.md) | 带日期的方案档案（扁平，死方案在 `archive/`） |

## 学习路径

按顺序读，每一站都建立在前一站上。括号里是「读完应该能回答的问题」。

**第 1 阶段 · 建立全局（约 30 分钟）**

1. [reference/tech-stack.md](reference/tech-stack.md) — 技术栈全景（这套系统由什么组成？每个东西是干嘛的？为什么是它？）
2. [ARCHITECTURE.md](ARCHITECTURE.md) — 拓扑与双集群分工（东西都跑在哪台机器上？）
3. [reference/terminology.md](reference/terminology.md) — 命名正典（同一个集群为什么有好几个名字？）

**第 2 阶段 · 能动手（约 1 小时）**

4. [AGENTS.md](AGENTS.md) — 命令、约定、硬约束（怎么在这个 repo 里干活而不搞坏东西？）
5. [reference/argocd-app-patterns.md](reference/argocd-app-patterns.md) — GitOps 模型（改一行 YAML 之后发生了什么？）
6. [runbooks/add-service.md](runbooks/add-service.md) — 跟着加一个服务（端到端走一遍最省事）
7. [reference/manifest-safety-checks.md](reference/manifest-safety-checks.md) — CI 护栏 H/V/E 系列（我会被拦在哪，为什么）

**第 3 阶段 · 逐层深入（按需）**

8. [reference/networking-ingress.md](reference/networking-ingress.md) — 南北向：外部流量怎么进来
9. [reference/tailscale-network.md](reference/tailscale-network.md) — 东西向：跨集群，最容易踩坑的一层
10. [reference/observability-multicluster.md](reference/observability-multicluster.md) — 日志/指标/追踪怎么汇总（注意遥测是双向的）
11. [reference/security.md](reference/security.md) — 纵深防御 11 层（注意第 9 层只到「可见性」）
12. [reference/storage.md](reference/storage.md) + [runbooks/backup-recovery.md](runbooks/backup-recovery.md) — 数据在哪、怎么恢复

**第 4 阶段 · 读事故**

13. [records/](records/README.md) — 这套系统实际是怎么坏的。多数「为什么这么规定」的答案在这里，
    尤其是几类**静默失败**：入口看着 200 其实新路由已经建不了、备份没覆盖到、扫描没重跑。
14. [decisions/](decisions/README.md) — 为什么不是另一种做法，以及**被否决的方案**。

> 只想解决眼前一个具体问题：跳过上面，直接查 [reference/ 索引](reference/README.md)（现状）
> 或 [runbooks/ 索引](runbooks/README.md)（怎么办）。

## 新增 / 修改文档

规则在 [RULES.md](RULES.md)（R1–R8：目录归属、命名、文首字段、状态标记、索引维护、
唯一真相源、命令上下文、长度预算），CI 的 `check-docs.py` 强制。写之前读一遍，
提交之后跑一遍 `python3 scripts/check-docs.py`。
