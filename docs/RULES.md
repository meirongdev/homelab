# Homelab 文档组织规则 (R1–R7)

> Last updated: 2026-08-21
> 2026-08-14 从 [docs/README.md](README.md)（门户）拆出：门户只做导航，**写文档的规则集中在本页**。
>
> 以下 7 条是**强制**的。新增或改动文档前先对照；违反的一律按下面的处理方式修。

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
| — | `Last updated` 不早于最后一次内容提交（R3 的时效部分）| ✅ 脚本 |
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
⚠️ **`✅ 已完成`且东西还在跑的一律不归档**——它正是当前架构的依据（`cilium-mesh-installation`
就是 CNI 选型的唯一记录），归档等于把依据藏起来。
**但"完成后又被整体退役"的要归档**（旧 LLM 网关、ArgoCD Image Updater 都是这样）：判据是东西还在不在，
不是当初做没做成。这类归档时状态从 `✅` 改成 `❌ 已退役（日期）`，并写明**有没有接替者**——
挂着"✅ 生产运行"的死方案比没有文档更坏，这类文档就这样误导过 5 天。
归档是**移动不是删除**，且必须在 `archive/README.md` 写明「为什么死了 / 被谁取代」。

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

**改了内容就改 `Last updated`**（脚本强制）：它不得早于该文件最后一次内容提交
——`git log` 是判据，只改这一行的提交不算数。2026-08-13 清理时 21 篇文档的时间戳
落在实际内容之后（`services.md` 写 08-06，正文已含 08-11 的 BentoPDF），
读者据此判断"这页还新鲜"，判断的是假的。浅克隆时该检查整条跳过，故 CI 用 `fetch-depth: 0`。

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

入口与阅读顺序见 [docs/README.md](README.md)。
