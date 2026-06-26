# Hermes Agent — Profile 管理与 MCP 集成

> Last updated: 2026-06-26
> 适用版本：Hermes Agent v0.17.x（macbook，Homebrew 安装）

---

## Profile 管理

### 查看所有 Profile

```bash
hermes profile list
```

输出示例：

```
 Profile          Model                        Gateway      Alias
 ◆default         <model>                      running      —
  profile-a       <model>                      stopped      profile-a
  profile-b       <model>                      stopped      profile-b
  profile-c       <model>                      stopped      profile-c
```

`◆` 标记表示当前 sticky 默认 profile。`Gateway` 列显示该 profile 的后台 gateway 服务状态。

---

### 切换活跃 Profile

切换 profile 分两步：停止当前 gateway → 切换 sticky 默认 → 启动新 gateway。

```bash
# 1. 停止当前正在运行的 gateway（属于当前活跃 profile）
hermes gateway stop

# 2. 切换 sticky 默认到目标 profile（例如 profile-b）
hermes profile use <target-profile>

# 3. 为新 profile 启动 gateway
hermes gateway start
```

验证：

```bash
hermes gateway status   # 查看当前 gateway 实际运行状态（比 profile list 更准确）
hermes profile list     # ◆ 应出现在目标 profile 前
```

> **注意**：`profile list` 的 Gateway 列存在轻微刷新延迟，以 `hermes gateway status` 的 PID 为准。

---

## MCP 集成

### Jira Cloud（via `mcp-atlassian`）

**前置条件**：
- Hermes 已安装 `mcp` 依赖（见下方安装步骤）
- Jira Cloud API Token（在 [Atlassian Account Settings](https://id.atlassian.com/manage-profile/security/api-tokens) 创建）

**一次性依赖安装**（每台机器只需安装一次）：

```bash
# 在 Hermes 自带的 Python 环境中安装 mcp-atlassian
HERMES_PY=$(ls -d /opt/homebrew/Cellar/hermes-agent/*/libexec/bin/python | tail -1)
$HERMES_PY -m pip install "hermes-agent[mcp]" mcp-atlassian
```

**添加 Jira MCP 到指定 profile**：

先切换到目标 profile（参见上方切换步骤），再执行：

```bash
HERMES_MCP_ATLASSIAN=$(ls -d /opt/homebrew/Cellar/hermes-agent/*/libexec/bin/mcp-atlassian | tail -1)

hermes mcp add jira \
  --command "$HERMES_MCP_ATLASSIAN" \
  --env JIRA_URL=https://<your-org>.atlassian.net \
      JIRA_USERNAME=<your@email.com> \
      JIRA_API_TOKEN=<api-token>
```

交互提示 `Enable all 49 tools? [Y/n]` 时输入 `Y`。

非交互模式（脚本/SSH 场景）：

```bash
echo "Y" | hermes mcp add jira \
  --command "$HERMES_MCP_ATLASSIAN" \
  --env JIRA_URL=https://<your-org>.atlassian.net \
      JIRA_USERNAME=<your@email.com> \
      JIRA_API_TOKEN=<api-token>
```

**验证**：

```bash
hermes mcp list         # jira 应出现，Status = ✓ enabled
hermes mcp test jira    # 连接测试，应报告 Connected + 49 tools
```

**可用工具概览**（49 个，均为 `jira_` 前缀）：

| 类别 | 工具示例 |
|------|---------|
| 查询 | `jira_get_issue`、`jira_search`（JQL）、`jira_get_all_projects` |
| 创建/更新 | `jira_create_issue`、`jira_update_issue`、`jira_add_comment` |
| 状态流转 | `jira_get_transitions`、`jira_transition_issue` |
| Sprint | `jira_get_sprints_from_board`、`jira_add_issues_to_sprint` |
| Epic | `jira_link_to_epic`、`jira_create_issue_link` |
| Worklog | `jira_add_worklog`、`jira_get_worklog` |

新开 Hermes session 后工具即生效：

```bash
hermes  # 或 hermes chat
```

---

### 更新 API Token

Token 轮换后更新配置：

```bash
hermes mcp rm jira          # 移除旧配置
# 重新执行上方"添加 Jira MCP"步骤，填入新 token
```
