# Gateway Controller Evaluation: Traefik vs Cilium Gateway

> Date: 2026-03-07
> Decision status: Completed

## Scope

记录从 Traefik Gateway API 控制器切换到 Cilium Gateway API（Envoy）的结论。

## Current Reality

1. 两个集群已经统一到 Cilium 数据面。
2. Traefik-specific `ExtensionRef` 和 ForwardAuth 依赖已从入口层移除。
3. Cloudflare Tunnel 现在直接指向 Cilium 生成的 Gateway Service。

## Comparison

| Capability | Traefik (historical) | Cilium Gateway (current) |
|-----------|--------------------|--------------------------|
| Gateway API support | Mature | Supported (Envoy data plane) |
| Existing config compatibility | Required Traefik-specific middleware | Pure Gateway API resources in current repo |
| Shared SSO integration | ForwardAuth chain | Removed from ingress layer |
| Operational complexity | Extra controller + middleware CRDs | Lower after unification |
| Dataplane consistency with Cilium | No | Yes |
| Long-term standardization | Medium | High |

## Recommendation

1. **Ingress**: keep Cilium Gateway API as the single HTTP entrypoint.
2. **Auth**: keep ingress layer stateless and let applications own their own auth unless there is a strong reason to centralize again.
3. **ClusterMesh**: treat it as a separate concern from ingress; prepare the control plane in values, but enable/connect it explicitly with Cilium CLI.
4. **Future SSO**: if shared sign-in is reintroduced, prefer native OIDC or per-app reverse-proxy auth instead of reviving controller-specific ForwardAuth. See `docs/plans/2026-03-08-cilium-zitadel-sso-plan.md`.

## Migration Guardrails

1. Keep Cloudflare Tunnel targets aligned with generated Cilium Gateway service names.
2. Avoid reintroducing controller-specific filters into `HTTPRoute` unless the feature is worth the lock-in.
3. Treat ClusterMesh rollout as a dedicated change with its own validation and rollback path.
