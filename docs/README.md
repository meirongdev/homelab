# Homelab Docs Portal

> Last updated: 2026-08-09
> 这是**索引 + 文档规则**。运行态事实都在下面链接的文档里，本页不复制副本。

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

---

# 文档组织规则

以下 7 条是**强制**的。新增或改动文档前先对照；违反的一律按下面的处理方式修。

## 怎么检查

```bash
python3 scripts/check-docs.py          # 有违规则 exit 1
python3 scripts/check-docs.py --list   # 看哪几条能自动查
```

CI 在每次 PR 与 push to main 时跑（`.github/workflows/docs-check.yml`）。

> 另有 `.github/workflows/static-checks.yml` 管**代码侧**的静态检查（YAML 语法+重复键 /
> `just --list` 可解析 / `terraform fmt` / shellcheck），与本文的文档规则互不重叠。

| | 规则 | 谁来查 |
|---|------|--------|
| R2 | 命名 | ✅ 脚本 |
| R3 | H1 位置 + 文首必填字段 | ✅ 脚本 |
| R4 | 状态枚举标记 | ✅ 脚本 |
| R5 | 目录索引双向完整 + `plans/README.md` 份数与实际一致 | ✅ 脚本 |
| — | 相对链接 + 非 docs 文件对 `docs/` 的引用 | ✅ 脚本 |
| — | 非 docs README 的目录树只画真实存在的子目录 | ✅ 脚本 |
| R1 | 目录归属 | ⚠️ 人 |
| R6 | 唯一真相源 | ⚠️ 人 |
| R7 | 命令带执行上下文 | ⚠️ 人 |

> ⚠️ **脚本只看结构，看不出内容是否属实。** 2026-07-31 发现的那处 NFS 描述错误
> （文档说 4 个 PVC 还在 NFS 上，实际全在 local-path）格式完全合规，是 `kubectl` 照出来的。
> **改了架构就得手动核文档，没有检查能代劳。**
>
> 改规则时**必须同步改 `scripts/check-docs.py`**——两边不一致的话，
> 要么规则是摆设，要么脚本在误伤。

## R1 — 目录归属：一篇文档只属于一类

先问「这篇文档回答什么问题」，再决定放哪。

| 目录 | 回答的问题 | 收 | **不收** |
|------|-----------|-----|---------|
| `reference/` | **现在是什么样？** | 当前生效的架构事实，长期维护 | 带日期的建议、执行过程、一次性排障 |
| `decisions/` | **为什么选 A 不选 B？** | 选型场景、被否决的选项、取舍 | 怎么做（步骤） |
| `runbooks/` | **出事了怎么办？** | 针对本基础设施、可照抄执行的 SOP | 一次性迁移记录、非基础设施的工具说明 |
| `guides/` | **这个跨领域任务怎么走？** | 非故障处置的流程（含本地工具） | 单组件故障 SOP |
| `records/` | **那次到底怎么回事？** | 已发生的故障/排障复盘 | 计划、建议 |
| `plans/<类别>/` | **当时打算怎么做？** | 带日期的方案，**写完即冻结** | 需要长期维护的事实 |
| `plans/archive/` | **当初为什么考虑过 X，后来为什么没做？** | 不存在于当前系统的方案 | 已完成的方案（见下） |
| `ROADMAP.md` | **还剩什么没做？** | 唯一的开放项清单 | 实施细节（链到 decisions/plans） |

类别：`apps` / `architecture` / `networking` / `observability` / `security` / `storage`。

**什么时候移进 `archive/`**：一份方案记录的东西**从未存在，或已被整体移除**——
状态为 `❌ 未实施` / `❌ 已取消` / `⚠️ 已被取代` / 前提已消失。判据是一句话：
**读它对理解当前系统有没有帮助？** 没有就归档。
⚠️ **`✅ 已完成` 一律不归档**——完成的方案正是当前架构的依据（`cilium-mesh-installation`
就是 CNI 选型的唯一记录），归档等于把依据藏起来。归档是**移动不是删除**，且必须在
`archive/README.md` 写明「为什么死了 / 被谁取代」。

**判据**：一篇文档如果需要「随架构变化持续更新」，它属于 `reference/`；
如果它「记录某一天的判断」，它属于 `plans/` 或 `decisions/`。**建议 ≠ 事实。**

## R2 — 命名

| 位置 | 格式 | 例 |
|------|------|-----|
| `plans/*/`、`records/` | `YYYY-MM-DD-<topic>.md` | `2026-07-06-resource-optimization.md` |
| `reference/`、`decisions/`、`runbooks/`、`guides/` | `<topic>.md`，**文件名不带日期** | `tailscale-network.md` |

全部小写 kebab-case。常青文档的文件名带日期是 R1 违规的信号——说明它其实是快照。

## R3 — 文首必填字段

**所有文档**：H1 标题必须是文件第一行（banner/warning 放 H1 之后）。

| 目录 | 还必须有 |
|------|---------|
| `reference/` | `Last updated` + `Status` |
| `decisions/` | `日期` + `状态` + Context / Decision / Consequences |
| `plans/` | `日期` + `状态` + 结论 |
| `runbooks/` | 触发条件 + 成功判定 + 回滚（恢复类 runbook 本身即回滚，注明豁免） |
| `records/` | 日期 + 影响 + 根因 |

## R4 — 状态枚举

`plans/` 与 `decisions/` 的状态只用这几个值，便于扫读：

`✅ 已完成` · `🚧 执行中` · `📐 设计` · `⚠️ 部分完成` · `⚠️ 已被取代` · `❌ 未实施` · `❌ 已取消`

`⚠️ 已被取代` / `❌` 必须链到取代它的文档或说明原因。

## R5 — 每个目录的 README 是完整索引

`reference/` `decisions/` `runbooks/` `guides/` `records/` 和 `plans/<类别>/` 都必须有 README，
**列出该目录的全部文档**，且只列自己目录的（不跨目录索引）。加文档就更新索引。

## R6 — 唯一真相源

一个事实只在一处维护，别处只链接。已确立的真相源：

| 事实 | 唯一位置 |
|------|---------|
| 服务清单 | [reference/services.md](reference/services.md) |
| 开放项 / 待办 | [ROADMAP.md](ROADMAP.md) |
| 安全逐层状态 | [reference/security.md](reference/security.md) |
| 资源实际数值 | `k8s/helm/values/` 与集群本身（文档只写原则） |

## R7 — 命令必须可执行

写明执行目录与集群 context（`cd k8s/helm && just …`、`kubectl --context oracle-k3s …`），
避免「思路型」描述。过期内容不删除：标 `Deprecated` 并链到替代文档。

---

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
