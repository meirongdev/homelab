# Sink URL Shortener — Cloudflare Workers Deployment

**Date**: 2026-03-03
**Status**: ✅ 已部署
**Service URL**: https://s.meirong.dev

## Overview

[Sink](https://github.com/miantiao-me/Sink) 是一个基于 Cloudflare Workers 的无服务器短链服务，具备以下功能：
- 自定义 slug 短链生成
- 实时 Analytics（访客统计、设备类型）
- 二维码生成
- 链接过期日期
- 批量 JSON/CSV 导入导出
- AI 辅助功能（Cloudflare AI）
- 自动每日 R2 备份

Sink 是 **Cloudflare-native 应用**，无 Docker 镜像，不能部署在 K8s 中。部署目标为 Cloudflare Workers。

## 架构

```
Browser → Cloudflare DNS (s.meirong.dev) → Cloudflare Worker (sink)
                                              ├── KV Namespace (link storage)
                                              ├── R2 Bucket (daily backups)
                                              ├── Analytics Engine (visitor stats)
                                              └── AI Binding (slug suggestions)
```

DNS 记录由 Wrangler custom domain 自动创建（不经过 Cloudflare Tunnel，不通过 K8s）。

## 目录结构

```
cloudflare/workers/
├── justfile              # 部署命令
└── sink/                 # git submodule → https://github.com/miantiao-me/Sink
    ├── .env              # 本地 secrets（gitignored）
    └── wrangler.jsonc    # Cloudflare Workers 配置（含 custom domain）
```

## 前置条件

### Cloudflare API Token 权限
部署 Sink 需要一个具备以下权限的 API Token：
- `Workers Scripts:Edit`
- `Workers KV Storage:Edit`
- `Workers R2 Storage:Edit` (可选，备份用)
- `Account Analytics:Edit` (Analytics Engine 数据集)
- `Zone DNS:Edit` (s.meirong.dev custom domain 绑定)

> 建议在 Cloudflare Dashboard 创建单独的 "Sink Deploy" Token，或扩展现有 homelab Token 权限。

### 工具
- Node.js / pnpm
- `npx wrangler` (通过 npx 调用，无需全局安装)

## Sink wrangler.jsonc 配置说明

以下字段从原始 `wrangler.jsonc` 修改：

| 字段 | 值 | 说明 |
|------|-----|------|
| `routes` | `[{"pattern": "s.meirong.dev", "custom_domain": true}]` | 绑定自定义域名 |
| `kv_namespaces[0].id` | `<KV_NAMESPACE_ID>` | 创建后填入 |
| `kv_namespaces[0].preview_id` | `<KV_NAMESPACE_ID>` | 同上 |
| `r2_buckets[0].bucket_name` | `sink` | R2 bucket 名称 |

## 环境变量

在 Sink 目录的 `.env` 文件中配置（gitignored）：

```bash
NUXT_SITE_TOKEN=<管理员令牌，用于访问 /dashboard>
NUXT_CF_ACCOUNT_ID=<Cloudflare Account ID>
NUXT_CF_API_TOKEN=<具有 Analytics Engine Read 权限的 Token>
NUXT_HOME_URL=https://s.meirong.dev
NUXT_DATASET=sink
NUXT_REDIRECT_STATUS_CODE=308
NUXT_PUBLIC_SLUG_DEFAULT_LENGTH=5
NUXT_DISABLE_AUTO_BACKUP=false
```

## 部署步骤

### 1. 初始化 submodule

```bash
git submodule update --init cloudflare/workers/sink
cd cloudflare/workers/sink
pnpm install
```

### 2. 创建 Cloudflare 资源

```bash
# 创建 KV namespace
npx wrangler kv namespace create "SINK_KV"
# 记录输出的 id，填入 wrangler.jsonc

# 创建 R2 bucket（可选，用于备份）
npx wrangler r2 bucket create sink
```

### 3. 配置 .env

```bash
cp .env.example .env
# 编辑 .env 填入实际值
```

### 4. 构建并部署

```bash
pnpm build
npx wrangler deploy
```

### 5. 验证

- 访问 https://s.meirong.dev 确认重定向到 dashboard
- 访问 https://s.meirong.dev/dashboard 用 `NUXT_SITE_TOKEN` 登录

## 后续运维

### 更新 Sink 版本

```bash
cd cloudflare/workers/sink
git pull origin master
pnpm install
pnpm build
npx wrangler deploy
```

### 修改配置

编辑 `.env` 后重新 `pnpm build && npx wrangler deploy`，或用 `wrangler secret put <KEY>` 更新单个 secret。

## 实际部署记录（2026-03-03）

### 使用的 API Token
现有 homelab Cloudflare API Token（Zone DNS+WAF+Tunnel）意外具备 Workers 部署权限，无需新建 Token。

### 实际执行步骤
1. `git submodule add https://github.com/miantiao-me/Sink cloudflare/workers/sink`
2. 通过 Cloudflare REST API 创建 KV namespace：`POST /accounts/{id}/storage/kv/namespaces` → ID: `84c48683eb77432885b479d424f8ee82`
3. 通过 Cloudflare REST API 创建 R2 bucket：`POST /accounts/{id}/r2/buckets` → `sink` (APAC region)
4. 修改 `wrangler.jsonc`：填入 KV ID、添加 `vars`（env vars）、移除 analytics 绑定
5. `pnpm install && pnpm build` 成功
6. `npx wrangler deploy` 上传 Worker 成功（86 个静态资源）
7. 通过 API 绑定 custom domain：`PUT /accounts/{id}/workers/domains` → `s.meirong.dev`
8. 通过 Cloudflare API 设置 Worker secret：`NUXT_SITE_TOKEN`

### Analytics Engine
已启用（免费，100,000 数据点/天）。需一次性在 Dashboard 激活：`workers/analytics-engine`。

### Rate Limiting
Workers Rate Limiting binding 配置为 **30 请求/10 秒/IP**（等价于 3/s，最小 period=10s）。
通过 `server/middleware/rate-limit.ts` Nitro 中间件实现（读取 `cf-connecting-ip`）。

### 注意事项
- Analytics Engine 写入无需额外 token；但 Sink dashboard 内的图表显示需 `NUXT_CF_API_TOKEN`（需 Account Analytics Read 权限），目前未配置，图表页数据为空属正常现象
- Custom domain 通过 API 绑定而非 wrangler routes（Token 缺少 Zone Workers Routes 权限）
- `wrangler deploy` 每次都会报 custom domain 绑定错误（可忽略，domain 已通过 API 持久绑定）
- Sink 不通过 K8s Traefik，DNS 由 Cloudflare Workers 自动管理，无需修改 Cloudflare Terraform
- 不需要添加到 ArgoCD（非 K8s 工作负载）
- 管理员 Token：`NUXT_SITE_TOKEN` 存储在 Worker secrets 中（通过 Cloudflare API 设置）
- Site Token 值记录于 `cloudflare/workers/sink/.env`（gitignored）
