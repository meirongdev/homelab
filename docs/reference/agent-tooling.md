# Agent 工具链与仓库边界 (Agent Tooling)

> Last updated: 2026-10-28
> Status: 生效事实
> 本文回答三件事：**AI 助手的上下文从哪里进来**、**哪些 agent 文件是仓库内容（进 git）**、
> **哪些是本机每套 agent 各装一份的工具（不进 git）**，以及这两条边界上已知的重复与代价。
> 写文档的规则在 [RULES.md](../RULES.md)，清单规则在
> [manifest-safety-checks.md](manifest-safety-checks.md)，本文只管 agent 侧。

## 上下文入口只有一份

`docs/AGENTS.md` 是**唯一**的 agent 上下文文件，其余全是软链（`git ls-files -s` 里 mode 是 `120000`）：

| 入口 | 指向 |
|---|---|
| `AGENTS.md` · `CLAUDE.md` · `.gemini.md` | `docs/AGENTS.md` |
| `.github/copilot-instructions.md` | `../docs/AGENTS.md` |

⚠️ 别把这些软链换成普通文件写内容，那就是第二份真相源；软链被某些工具当普通文件读时不报错，只读到空字符串。
要加内容就改 `docs/AGENTS.md`，并守 [R8](../RULES.md) 的 **14000 字节预算**。

## 四类来源与 git 边界

| 类别 | 位置 | 进 git？ | 例 |
|---|---|---|---|
| **项目自有的流程** | `docs/runbooks/`、`docs/guides/`、`docs/reference/` | ✅ | 新增服务、备份恢复、电子书同步的流程 |
| **agent 技能入口（壳）** | `.claude/skills/<name>/SKILL.md` | ✅（只跟踪壳） | `add-service`：正文只有指针 |
| **vendored 第三方技能** | `.agents/skills/<name>/` | ✅ | `humanizer`（含自带 LICENSE / plugin.json） |
| **per-agent 安装的工具** | `.qwen/{skills,tmp}` `.qwen/skill-curator.json` | ❌ `.gitignore` | qwen 的 auto-skill |

- **流程的真相源必须在 `docs/`**。技能壳只负责被 agent 发现，正文放 `docs/` 才受 R1 / R3 / R5 / R8 与
  `check-docs.py` 约束。
- **技能壳与 vendored 技能用软链复用，不复制**。`.claude/skills/humanizer` 是指向 `.agents/skills/humanizer`
  的软链；`.agents/skills/<name>/` 是跨 agent 通用的落点，`skills-lock.json`（进 git）记来源与 hash。
  复制一份到每个 agent 目录 = 各自漂移。
- ☠️ **一个流程只允许一份实现**。两份并存时「另一份也能用」必须实测，不能假定：电子书同步的 bash 版
  曾静默跑不通 8 个月，只有技能目录里的 python 版在用，删错一份就全断。现在只剩 `scripts/sync-ebooks.sh`，
  技能壳只留指针（三个缺陷见 [guides/ebook-sync.md](../guides/ebook-sync.md)）。
- `.claude/settings.local.json` / `.qwen/settings.local.json` 刻意 gitignore：允许列表里可能内联真实凭据
  （例如 `wrangler` 命令带着 `CLOUDFLARE_API_TOKEN`）。规则写在仓库的 `.gitignore` 里，别只靠个人的
  `~/.config/git/ignore`，换台机器就没保护了。

## opsx / OpenSpec 已整套移除

移除的是 `.agent/` `.codex/` `.gemini/` `openspec/` 整目录，加上 `.claude/{commands,skills/openspec-*}`
`.github/{prompts,skills}` `.qwen/{commands,skills/openspec-*}`。它们全部被 gitignore，git 里一个都没有，
也就无法从 git 还原（ROADMAP 开放项 #14 收在「停用」，见 [CHANGELOG](../CHANGELOG.md) 2026-09-08）。

为什么停用（判据不是「占地方」）：

- ☠️ **产物不落库**：`openspec/` 整体被 gitignore，提案写完即丢。本仓库的设计产物只有一条路：
  `docs/plans/`（写完即冻结）与 `docs/decisions/`（ADR），由 R1 与 `check-docs.py` 强制。
  **装了、产出不进 git，等于没发生过。**
- 同一批 `SKILL.md` 在 6 个 agent 目录各一份，技能发现会看到重复条目。
- 新克隆仓库后这些目录一个都不存在，**任何流程都不许依赖它们**。

⚠️ **别照着旧提交把它们加回来**（`.gitignore` 里留了同样的提醒）。要重新引入这类工具，先解决「产出进 git」。

⚠️ **`.agent/`（已删）与 `.agents/`（保留）是两个目录**，差一个 s：后者是 vendored 第三方技能的落点
（`humanizer` + `skills-lock.json`），**进 git**，与 opsx 无关。

## 新增一个项目自有技能

1. 先写 `docs/`（runbook / guide / reference），按 R1 选目录、按 R3 补齐文首字段、进该目录 README 索引。
2. 再建 `.claude/skills/<name>/SKILL.md` 壳：只留 frontmatter（`name` / `description` / `argument-hint` /
   `allowed-tools`）+ 指向 `docs/` 的一段 + 最易漏的几条硬约束。
3. 壳里写一句「改流程改 runbook，不要改本文件」，否则壳会变成真相源：`add-service` 的流程曾只存在于
   `.claude/skills/`，带着两条错误指令没人发现（见
   [plans/2026-08-01-open-notebook-homelab.md](../plans/2026-08-01-open-notebook-homelab.md)），
   现已移到 [runbooks/add-service.md](../runbooks/add-service.md)。
4. 第三方技能用安装器装进 `.agents/skills/`，让 `skills-lock.json` 记账，别手工拷贝。
