# 信息管道：Miniflux → Redpanda Connect → KaraKeep → Gotify → Telegram

**日期**: 2026-02-28
**状态**: ✅ 完成（见 ROADMAP.md Phase 3）

## 概览

构建一条信息管道，将 Miniflux 的保存文章通过 Webhook 传递给 Redpanda Connect，再转存至 KaraKeep（书签管理器）。同时 Redpanda Connect 定时轮询 KaraKeep 中 `tag=telegram` 的精选条目，推送到 Gotify 通知服务，最终通过 Gotify Telegram 插件转发至 Telegram 频道。

## 架构

```
┌─────────────────────────────── Oracle K3s ────────────────────────────────┐
│                                                                          │
│  ┌──────────┐  Webhook POST     ┌──────────────────┐    KaraKeep API     │
│  │ Miniflux │ ───────────────►  │ Redpanda Connect │ ──────────────────► │
│  │ (已有)    │  /save_entry      │ (新部署)          │                     │
│  └──────────┘                   │                  │   ┌──────────┐      │
│                                 │  每 5 分钟轮询    │ ──│ KaraKeep │      │
│                                 │  tag=telegram    │◄──│ (新部署)  │      │
│                                 │  + 内存去重       │   └──────────┘      │
│                                 └────────┬─────────┘                     │
│                                          │                               │
└──────────────────────────────────────────┼───────────────────────────────┘
                                           │ Gotify API (via Tailscale)
                                           ▼
┌─────────────────────────── Homelab K3s ─────────────────────────────────┐
│                                                                         │
│  ┌────────┐   Telegram Plugin   ┌──────────────────┐                    │
│  │ Gotify │ ──────────────────► │ Telegram Channel │                    │
│  │ (新部署) │                     └──────────────────┘                    │
│  └────────┘                                                             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## 数据流详细说明

### 流程 1：Miniflux → KaraKeep（保存文章）

1. 用户在 Miniflux 中标记文章为"已保存" (star)
2. Miniflux Webhook 触发 `POST` 请求到 Redpanda Connect 的 HTTP 端点
3. Redpanda Connect 提取文章 URL 和标题
4. 调用 KaraKeep API `POST /api/v1/bookmarks` 创建书签

### 流程 2：KaraKeep → Gotify（精选推送）

1. Redpanda Connect 每 5 分钟调用 KaraKeep API `GET /api/v1/bookmarks?favourited=false&archived=false`
2. 筛选含有 `tag=telegram` 的书签
3. 内存中维护已推送 ID 集合，跳过重复
4. 新书签通过 Gotify API `POST /message` 推送
5. Gotify 通过 Telegram 插件转发到 Telegram 频道

## 部署规划

### Oracle K3s 新增服务

| 服务 | 命名空间 | 镜像 | 端口 | 持久存储 | 外部访问 |
|------|---------|------|------|---------|---------|
| KaraKeep | `rss-system` | `karakeep/karakeep:release` | 3000 | 是 (local-path 5Gi) | `keep.meirong.dev` |
| Redpanda Connect | `rss-system` | `docker.redpanda.com/redpandadata/connect:latest` | 4195 | 否 | 否 (仅集群内) |

> KaraKeep 需要 Chrome (Chromium) 和 Meilisearch 作为 sidecar。

### Homelab 新增服务

| 服务 | 命名空间 | 镜像 | 端口 | 持久存储 | 外部访问 |
|------|---------|------|------|---------|---------|
| Gotify | `personal-services` | `gotify/server:latest` | 80 | 是 (nfs-client 1Gi) | `notify.meirong.dev` |

## Vault 密钥

在 Vault `secret/homelab/` 路径下创建：

| 路径 | Key | 说明 |
|------|-----|------|
| `homelab/karakeep` | `nextauth_secret` | KaraKeep NextAuth 密钥 |
| `homelab/karakeep` | `meili_master_key` | Meilisearch 主密钥 |
| `homelab/karakeep` | `api_key` | KaraKeep API Key (用于 Redpanda Connect) |
| `homelab/gotify` | `default_user_password` | Gotify 默认用户密码 |
| `homelab/redpanda-connect` | `gotify_token` | Gotify 应用 Token (推送消息用) |
| `homelab/redpanda-connect` | `karakeep_api_key` | KaraKeep API Key (同上) |
| `homelab/redpanda-connect` | `miniflux_webhook_secret` | Miniflux Webhook 共享密钥 (可选) |

## 实施步骤

### 1. Vault 密钥准备
```bash
# 在 Vault 中创建密钥（通过 Vault UI 或 CLI）
vault kv put secret/homelab/karakeep \
  nextauth_secret=$(openssl rand -hex 32) \
  meili_master_key=$(openssl rand -hex 16) \
  api_key=""  # 部署后从 KaraKeep UI 获取

vault kv put secret/homelab/gotify \
  default_user_password="<password>"

vault kv put secret/homelab/redpanda-connect \
  gotify_token=""  # 部署后从 Gotify UI 获取
  karakeep_api_key=""  # 部署后从 KaraKeep UI 获取
```

### 2. KaraKeep 部署 (Oracle K3s)
- 创建 `cloud/oracle/manifests/rss-system/karakeep.yaml`
- 包含 Deployment (web + chrome + meilisearch)、Service、PVC、ExternalSecret

### 3. Redpanda Connect 部署 (Oracle K3s)
- 创建 `cloud/oracle/manifests/rss-system/redpanda-connect.yaml`
- 配置包含两条管道：
  - HTTP server 输入 (接收 Miniflux webhook) → KaraKeep API 输出
  - 定时 HTTP 轮询输入 (KaraKeep API) → 内存去重 → Gotify API 输出

### 4. Gotify 部署 (Homelab)
- 创建 `k8s/helm/manifests/gotify.yaml`
- 添加到 `argocd/applications/personal-services.yaml`
- 添加 HTTPRoute 到 `k8s/helm/manifests/gateway.yaml`
- 添加 Cloudflare DNS: `notify.meirong.dev`

### 5. Miniflux Webhook 配置
- 在 Miniflux 设置中添加 Webhook URL: `http://redpanda-connect.rss-system.svc:4195/save_entry`
- 事件类型: `save_entry`

### 6. 网关 & DNS 更新
- Oracle: 添加 `keep.meirong.dev` 的 HTTPRoute 和 Cloudflare DNS
- Homelab: 添加 `notify.meirong.dev` 的 HTTPRoute 和 Cloudflare DNS

### 7. Homepage 更新
- Oracle: 添加 KaraKeep 和 Redpanda Connect 到 Homepage
- Homelab: 添加 Gotify 到 Homepage（如有）

## Redpanda Connect 配置 (rpcn.yaml)

```yaml
# HTTP server: 接收 Miniflux Webhook → 保存到 KaraKeep
input:
  http_server:
    path: /save_entry
    allowed_verbs: ["POST"]

pipeline:
  processors:
    # 提取 Miniflux entry 信息
    - mapping: |
        root.type = "link"
        root.url = this.entry.url
        root.title = this.entry.title
        root.tags = []

output:
  http_client:
    url: "http://karakeep.rss-system.svc:3000/api/v1/bookmarks"
    verb: POST
    headers:
      Authorization: "Bearer ${KARAKEEP_API_KEY}"
      Content-Type: application/json

---
# 定时轮询 KaraKeep tag=telegram → Gotify 推送
input:
  generate:
    interval: "5m"
    mapping: 'root = {}'

pipeline:
  processors:
    - http:
        url: "http://karakeep.rss-system.svc:3000/api/v1/bookmarks?favourited=false&archived=false"
        verb: GET
        headers:
          Authorization: "Bearer ${KARAKEEP_API_KEY}"
    - mapping: |
        root = this.bookmarks.filter(b -> b.tags.any(t -> t.name == "telegram"))
    - unarchive:
        format: json_array
    - cache:
        operator: set
        resource: dedup_cache
        key: ${! this.id }
        value: "seen"
    - dedupe:
        cache: dedup_cache
        key: ${! this.id }
    - mapping: |
        root.title = "📌 " + this.title.or(this.content.title).or("New Bookmark")
        root.message = this.url.or(this.content.url).or("")
        root.priority = 5

output:
  http_client:
    url: "http://gotify.personal-services.svc.cluster.local:80/message"
    verb: POST
    headers:
      X-Gotify-Key: "${GOTIFY_TOKEN}"
      Content-Type: application/json

resources:
  caches:
    dedup_cache:
      memory:
        default_ttl: "24h"
```

## 验证清单

- [ ] KaraKeep Web UI 可通过 `keep.meirong.dev` 访问
- [ ] KaraKeep API 可正常使用 (创建/查询书签)
- [ ] Gotify Web UI 可通过 `notify.meirong.dev` 访问
- [ ] Miniflux 保存文章后，KaraKeep 中出现对应书签
- [ ] KaraKeep 中 tag=telegram 的书签，5 分钟内推送到 Gotify
- [ ] Gotify 消息成功转发到 Telegram 频道（需手动配置 Telegram 插件）
- [ ] 重复书签不会重复推送（内存去重生效）
