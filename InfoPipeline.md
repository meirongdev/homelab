# Spec: K8s-Curator-Engine (v2026.1)

## 1. 项目定义 (Project Definition)
**K8s-Curator-Engine** 是一个运行在 Kubernetes 环境下的高度定制化信息聚合与策展系统。它旨在解决“信息过载”问题，通过“机器采集 + 人工筛选 + 自动分发”的链路，实现高质量技术资讯的精准推送。

## 2. 系统架构 (System Architecture)
系统采用分层解耦设计，通过标准协议（RSS/API/Webhook）进行通信：

1. **采集层 (Ingestion)**: 
   - **RSSHub (Custom Clone)**: 负责将非标准网页（GitHub, Blog, Security Bulletins）转换为标准 RSS。
2. **存储与筛选层 (Storage & Curation)**: 
   - **Miniflux**: 作为数据中心和人工审核后台。用户通过“打星 (Star)”动作标记待发送内容。
3. **编排与逻辑层 (Orchestration)**: 
   - **n8n**: 自动化引擎。定时轮询 Miniflux API，抓取已打星条目，进行清洗、转义并执行多平台分发。
4. **分发层 (Distribution)**: 
   - **Telegram Channel**: 通过 Bot API 发送 MarkdownV2 格式消息。
   - **Discord Server**: 通过 Webhook 发送 Rich Embed 格式消息。

## 3. 部署环境规范 (K8s Infrastructure)
AI 在生成 YAML 时需遵循以下约束：

- **Namespace**: `rss-system`
- **Workloads**: 
    - `rsshub`: Deployment (Port 1200) + Service + Redis (Cache)
    - `miniflux`: Deployment (Port 8080) + Service + PostgreSQL
    - `n8n`: Deployment (Port 5678) + Service (需持久化 `/home/node/.n8n`)
- **Persistence**: 
    - 使用 `PersistentVolumeClaim` 为 PostgreSQL 和 n8n 提供持久化存储。
- **Ingress**: 
    - 需配置基于 Host 的路由（例如 `miniflux.example.com`）。
- **Security**: 
    - 所有敏感 Token（TG_BOT_TOKEN, DB_PASSWORD）需通过 `Secret` 对象管理。

## 4. 自动化逻辑规范 (Workflow Logic)

### 4.1 触发策略
- **模式**: 定时拉取 (Pull Mode)。
- **频率**: 每 15 分钟执行一次。
- **API 端点**: `/v1/entries?starred=true&status=unread`。

### 4.2 数据清洗与转义 (Data Sanitization)
由于 Telegram MarkdownV2 对特殊字符极其敏感，逻辑层必须对以下字符执行转义处理：
`_` , `*` , `[` , `]` , `(` , `)` , `~` , `` ` `` , `>` , `#` , `+` , `-` , `=` , `|` , `{` , `}` , `.` , `!`

### 4.3 状态闭环
- 在推送任务完成后，n8n 必须发起反向回调，将 Miniflux 中该条目的状态由 `unread` 改为 `read`，防止重复推送。

## 5. 任务清单 (Action Items for AI)

1. **Task 1**: 生成完整的 K8s Manifests 压缩包（包含 Deployment, Service, PVC, Secret, Ingress）。
2. **Task 2**: 提供一套符合上述逻辑的 n8n 工作流 JSON 定义（或详细的节点参数说明）。
3. **Task 3**: 编写一个用于处理 Telegram MarkdownV2 转义的 JavaScript 函数片段（用于 n8n Code 节点）。
4. **Task 4**: 设计一个适合 K8s 技术资讯的 Telegram 消息模板。

## 6. 未来演进 (Roadmap)
- 接入 Ollama 节点实现本地化 AI 摘要生成。
- 增加基于 Prometheus 的推送成功率监控。