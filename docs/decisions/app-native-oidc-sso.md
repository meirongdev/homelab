# SSO 走应用原生 OIDC，不做共享入口层认证

> 日期: 2026-03-08（决策）· 2026-09-02 补写本 ADR
> 状态: ✅ 已实施（现役接入清单以 [reference/identity.md](../reference/identity.md) 为准）
> 关联：[当时的方案与分期](../plans/security/2026-03-08-cilium-zitadel-sso-plan.md)（快照，
> 里面列的接入方**已全部过期**）· [gateway-controller-evaluation](gateway-controller-evaluation.md)

> ⚠️ **本文是 2026-09-02 补写的**：此前身份架构的唯一记录是上面那份 plan。

## Context

从 Traefik 迁到 Cilium Gateway API 后，原来的入口层 SSO（Traefik ForwardAuth Middleware）
随之失效。ZITADEL 本身还在 `auth.meirong.dev`，可以继续做 OIDC Identity Provider，
问题是**认证在哪一层做**。

约束（当时写在 plan 里，至今成立）：

1. 不重新引入 Traefik Middleware / `ExtensionRef` ForwardAuth。
2. 不让 `HTTPRoute` 绑定 controller-specific 的 auth filter，保持资源可移植。
3. 要同时适配 homelab 与 oracle-k3s 两个集群。
4. 尽量减少跨集群实时依赖，别把 oracle 的业务链路建在 homelab 的 Service CIDR 上。

## Options

### Pattern A：应用原生 OIDC ← 主选
应用自己接 ZITADEL。`HTTPRoute` 只做路由，不承担认证。

### Pattern B：per-app `oauth2-proxy`
给不支持原生 OIDC 的应用旁挂一个 `oauth2-proxy`，`HTTPRoute` 指向它、它再反代到应用。
**作为兜底保留**，不是主选。

### Pattern C：共享 auth gateway ← 否决
一个共享入口代理或 Envoy ext_authz 风格的集成，在入口处统一鉴权。否决理由三条：
需要额外引入共享代理组件；复杂度高且容易再次形成 controller lock-in（刚从 Traefik 那里
逃出来）；与「纯 Gateway API + 应用自治认证」的方向冲突。

## Decision

**A 优先，B 兜底，不做 C。**认证是应用自己的事，入口层只路由。

## Consequences

- ✅ `HTTPRoute` 保持纯路由，换 Gateway 实现不牵动认证；两个集群用同一套模式。
- ⚠️ **认证质量因应用而异，且没有统一视图**。原生 OIDC 的应用（Grafana、ArgoCD 等）
  在 ZITADEL 后面；不支持的应用要么挂 oauth2-proxy，要么就只有自带的口令。
  这不是理论问题，当前有两个实例：
  - ☠️ **Nakama 管理台裸挂公网**，只有 Nakama 自带的用户名口令
    （[security.md §11](../reference/security.md)）。
  - ☠️ **Timeslot 的管理口令是上游公开 chart 的默认值**（2026-09-02 发现）。
  换成 C 这两个都不会发生 —— 这是为「不 lock-in」付的真实代价，不是纸面取舍。
- ⚠️ **per-app oauth2-proxy 当前零实例**：当年用它的 KaraKeep、Stirling-PDF、旧 LLM 网关
  管理面都已退役。所以 B 这条路径**没有活的参考实现**，下次要用得从头验一遍。
- 入口层没有统一的「未认证一律拒绝」地板，新服务默认是公开的 —— 加服务时要显式想一次
  认证，`add-service` skill 不会替你决定。

## 重新评估条件

- 需要认证的服务多到「逐个接」明显更贵时；或
- 出现第三个「无法原生 OIDC 又必须保护」的应用时（届时先把 B 跑通一个真实例，
  再评估要不要直接上 C）；或
- Cilium/Envoy 的 ext_authz 集成成熟到不构成 lock-in 时。
