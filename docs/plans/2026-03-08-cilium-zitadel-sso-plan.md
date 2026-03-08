# 2026-03-08 Cilium + ZITADEL SSO Reintroduction Plan

## Goal

在保留 `Cilium Gateway API + pure HTTPRoute` 架构的前提下，重新为需要登录的应用提供统一身份能力，并避免回退到 Traefik-specific ForwardAuth。

## Current State

1. 两个集群都已经切到 Cilium 数据面。
2. 入口层共享 SSO 已移除，`HTTPRoute` 目前只做路由。
3. `auth.meirong.dev` 上的 ZITADEL 仍可作为统一 OIDC Identity Provider。
4. 当前大多数应用依赖内置登录、Basic Auth，或直接公开。

## Constraints

1. 不重新引入 Traefik Middleware / `ExtensionRef` ForwardAuth。
2. 不让 `HTTPRoute` 绑定 controller-specific auth filter，尽量保持资源可移植。
3. 方案需要同时适配 homelab 和 oracle-k3s 双集群。
4. 尽量减少跨集群实时依赖，避免把 Oracle 业务链路建立在 homelab Service CIDR 上。

## Recommended Architecture

### Pattern A: Native OIDC First

适用对象：Grafana、Miniflux、未来支持 OIDC 的应用。

做法：

1. 在 ZITADEL 中为每个应用单独创建 OIDC client。
2. 应用直接配置 `issuer`, `client_id`, `client_secret`, `redirect_uri`。
3. Vault 按集群归档密钥：
   - homelab 应用：`secret/homelab/<app>-oidc`
   - oracle-k3s 应用：`secret/oracle-k3s/<app>-oidc`
4. 通过 External Secrets 将 OIDC 凭据同步到应用 namespace。

优点：

1. 不需要额外代理层。
2. 登录链路最短，故障面最小。
3. 与 Cilium Gateway API 完全解耦。

### Pattern B: Per-App `oauth2-proxy` Reverse Proxy

适用对象：Calibre-Web、Gotify、KaraKeep 等不支持原生 OIDC 或 OIDC 能力不完整的应用。

做法：

1. 每个需要 SSO 的应用旁边部署一个独立的 `oauth2-proxy` Deployment + Service。
2. `HTTPRoute` 的 backend 直接指向 `oauth2-proxy` Service，而不是指向应用本身。
3. `oauth2-proxy` 通过集群内 Service 将流量反代到真实应用。
4. 每个应用使用独立的 Cookie Secret、Client Secret、回调地址。

流量模型：

`Cloudflare Tunnel -> Cilium Gateway HTTPRoute -> oauth2-proxy -> app Service`

优点：

1. 不依赖 Gateway filter/ExtensionRef。
2. 每个应用隔离，某个代理出问题不会拖垮其他应用。
3. 适合逐个应用灰度切回 SSO。

代价：

1. 额外 Deployment / Service / Secret。
2. 回调 URI、Cookie 域、登出逻辑需要每应用维护。

### Pattern C: Shared Auth Gateway

不作为当前推荐方案。

原因：

1. 需要额外引入共享入口代理或 Envoy ext_authz 风格集成。
2. 复杂度高，且容易再次形成 controller lock-in。
3. 与当前“纯 Gateway API + 应用自治认证”的架构方向冲突。

## Phased Rollout

### Phase 1: Foundation

1. 整理 ZITADEL projects / applications，按集群和应用命名。
2. 将 Oracle 专用密钥全部迁移到 `secret/oracle-k3s/*`。
3. 补全文档，明确哪些应用是 `public`、`built-in auth`、`native OIDC`、`oauth2-proxy`。

### Phase 2: Native OIDC Apps

1. 先接入原生支持最好的应用。
2. 每个应用单独验证：登录、刷新 token、登出、回调 URL。
3. 更新 Uptime Kuma 监控接受码，避免把登录跳转误报成故障。

### Phase 3: Legacy Apps Through `oauth2-proxy`

1. 为单个应用创建独立 `oauth2-proxy`。
2. `HTTPRoute` 切换 backend 到代理 Service。
3. 验证匿名访问、登录回调、Cookie、上游头透传。
4. 成功后再复制到下一应用，不做一次性全量切换。

## Validation Checklist

1. `auth.meirong.dev` 登录页可访问。
2. 应用未登录时返回预期状态：`302` 到登录页或 `401` Basic Auth，而不是 `500`。
3. 登录成功后，应用自身 Session/Cookie 正常。
4. `kubectl get httproute -A` 中相关路由 `Accepted=True`、`ResolvedRefs=True`。
5. Uptime Kuma 监控规则与应用真实认证行为一致。
6. Vault 中 OIDC/代理密钥路径符合集群边界。

## Files To Introduce When Executing

1. `cloud/oracle/manifests/<app>/oauth2-proxy.yaml` or `k8s/helm/manifests/<app>-oauth2-proxy.yaml`
2. `ExternalSecret` for `client-id`, `client-secret`, `cookie-secret`
3. `HTTPRoute` backend changes for protected apps
4. Homepage / Uptime Kuma metadata updates

## Decision

短期内不恢复“入口层统一 SSO”。

执行顺序采用：

1. 原生 OIDC 优先
2. 不支持 OIDC 的应用使用每应用独立 `oauth2-proxy`
3. 保持 Cilium Gateway 只负责路由，不负责共享鉴权逻辑