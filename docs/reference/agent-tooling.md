# Agent 工具链与仓库边界 (Agent Tooling)

> Last updated: 2026-09-08
> Status: 生效事实
> 本文回答三件事：**AI 助手的上下文从哪里进来**、**哪些 agent 文件是仓库内容（进 git）**、
> **哪些是本机每套 agent 各装一份的工具（不进 git）**，以及这两条边界上已知的重复与代价。
> 写文档的规则在 [RULES.md](../RULES.md)，清单规则在
> [manifest-safety-checks.md](manifest-safety-checks.md)，本文只管 agent 侧。

## 上下文入口只有一份

`docs/AGENTS.md` 是**唯一**的 agent 上下文文件，其余全是软链（`git ls-files -s` 里 mode 是
`120000`）：

| 入口 | 指向 |
|---|---|
| `AGENTS.md` · `CLAUDE.md` · `.gemini.md` | `docs/AGENTS.md` |
| `.github/copilot-instructions.md` | `../docs/AGENTS.md` |

所以「顺手在根目录建一个 CLAUDE.md 写点东西」= 造出第二份真相源。软链被某些工具当普通文件
读时不会报错，只会读到空字符串——要加内容就改 `docs/AGENTS.md`，并注意 R8 的
**14000 字节预算**（它是每次会话全量加载的常驻上下文，超预算的正确动作是把细节挪进
`reference/` 再指过去，不是删字）。

## 三类来源，只有一类进 git

| 类别 | 位置 | 进 git？ | 例 |
|---|---|---|---|
| **项目自有的流程** | `docs/runbooks/`、`docs/guides/`、`docs/reference/` | ✅ | 新增服务、备份恢复、电子书同步的流程 |
| **agent 技能入口（壳）** | `.claude/skills/<name>/SKILL.md` | ✅（只跟踪壳） | `add-service`：正文只有指针 |
| **vendored 第三方技能** | `.agents/skills/<name>/` | ✅ | `humanizer`（含自带 LICENSE / plugin.json） |
| **per-agent 安装的工具** | `.qwen/{skills,tmp}` `.qwen/skill-curator.json` | ❌ `.gitignore` | qwen 的 5 个 auto-skill |

要点：

- **流程的真相源必须在 `docs/`**。技能壳只负责被 agent 发现，正文放 `docs/` 才能受
  R1（归属）/ R3（触发条件·成功判定·回滚）/ R5（进索引）/ R8 与 `check-docs.py` 约束。
  反面教材：`add-service` 的流程曾只存在于 `.claude/skills/` 里，两条错误指令静默存在
  （见 [../plans/apps/2026-08-01-open-notebook-homelab.md](../plans/apps/2026-08-01-open-notebook-homelab.md)），
  2026-09-05 移到 [runbooks/add-service.md](../runbooks/add-service.md)。
- **技能壳与 vendored 技能用软链复用，不复制**。`.claude/skills/humanizer` 是指向
  `.agents/skills/humanizer` 的软链；`.agents/skills/<name>/` 是跨 agent 通用的落点，
  `skills-lock.json`（进 git）记来源与 hash。复制一份到每个 agent 目录 = 各自漂移。
- **一个流程只允许一份实现**。`.claude/skills/sync-ebooks/scripts/sync_ebooks.py` 与
  `scripts/sync-ebooks.sh` 曾并存 8 个月，**2026-09-08 已合一**（python 删除，能力并入
  bash，技能壳只留指针）。☠️ 那次合并的教训值得记住：并存期间"两份都还能用"这个前提
  **是错的** —— bash 那份有三个先前就存在的缺陷（缺 conf 文件即静默 exit 1、epub 校验
  恒假、循环变量泄漏改写调用方的文件路径），实际一直跑不通，只有 python 那份在用。
  **一个流程两份实现时，"另一份也能用"必须实测，不能假定**；否则删错那一份，或者像这次
  一样，坏了 8 个月没人发现（四条 `just sync-ebooks*` 配方全程空转）。
  → [guides/ebook-sync.md](../guides/ebook-sync.md)
- `.claude/settings.local.json` / `.qwen/settings.local.json` 刻意 gitignore：允许列表里可能
  内联真实凭据（例如 `wrangler` 命令带着 `CLOUDFLARE_API_TOKEN`）。以前只靠
  `~/.config/git/ignore` 兜，换台机器就没保护了，所以规则固化在仓库的 `.gitignore` 里。

## opsx / OpenSpec 已整套移除（2026-09-08）

ROADMAP 开放项 #14 收在「停用」这条。移除的是 **50 个文件**，横跨 **6 个** agent 目录
（不是当时记的 5 个，`.github/` 也各存了一份）：`.agent/` `.codex/` `.gemini/` `openspec/`
整目录，加上 `.claude/{commands,skills/openspec-*}` `.github/{prompts,skills}`
`.qwen/{commands,skills/openspec-*}`。**git 里一个都没有**（全部 gitignore），
所以这次清理在提交里只体现为 `.gitignore` 与本文的改动。

**为什么停用**（判据不是"占地方"）：

- ☠️ **产物不落库**：`openspec/` 整体被 gitignore，本地 `specs/` 是空目录、`changes/`
  只剩一个空 `archive/` —— 提案写完即丢。而本仓库的设计产物只有一条路：
  `docs/plans/`（带日期的方案，写完即冻结）与 `docs/decisions/`（ADR），
  由 R1 与 `check-docs.py` 强制。**装了、产出不进 git，等于没发生过。**
- 同一批 4 个 `SKILL.md` × 6 个目录 = 24 份副本，agent 的技能发现会看到重复条目；
  命令文件还混着 `.md` + `.toml` + `.toml.backup` 三种形态（`.qwen/commands/` 实测）。
- 新克隆仓库后这些目录一个都不存在 —— **任何流程都不许依赖它们**，
  所以删除不影响任何可重复流程。

⚠️ **别照着旧提交把它们加回来**，`.gitignore` 里留了同样的提醒。要重新引入这类工具，
前提是先解决「产出进 git」那一条，否则重蹈同一个坑。

⚠️ **`.agent/`（已删）与 `.agents/`（保留）是两个不同目录**，差一个 s：后者是 vendored
第三方技能的落点（`humanizer` + `skills-lock.json`），**进 git**，与 opsx 无关。

## 新增一个项目自有技能

1. 先写 `docs/`（runbook / guide / reference），按 R1 选目录、按 R3 补齐文首字段、进该目录 README 索引。
2. 再建 `.claude/skills/<name>/SKILL.md` 壳：只留 frontmatter（`name` / `description` /
   `argument-hint` / `allowed-tools`）+ 指向 `docs/` 的一段 + 最易漏的几条硬约束。
3. 壳里写一句「改流程改 runbook，不要改本文件」——否则壳会在半年内变成真相源（已发生过一次）。
4. 第三方技能用安装器装进 `.agents/skills/`，让 `skills-lock.json` 记账，别手工拷贝。
