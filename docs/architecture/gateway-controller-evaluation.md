# Gateway Controller Evaluation: Traefik vs Cilium Gateway

> Date: 2026-03-07
> Decision status: In evaluation

## Scope

评估是否用 Cilium Gateway API（Envoy）替换当前 Traefik Gateway API 控制器。

## Current Reality

1. 两个集群的 `GatewayClass` 当前均为 `traefik`
2. 多条 `HTTPRoute` 依赖 `ExtensionRef -> traefik.io/Middleware`
3. SSO 依赖 ForwardAuth 语义（oauth2-proxy）

## Comparison

| Capability | Traefik (current) | Cilium Gateway (target) |
|-----------|--------------------|--------------------------|
| Gateway API support | Mature in current repo | Supported (Envoy data plane) |
| Existing config compatibility | Full (zero migration) | Requires migration of ExtensionRef usage |
| SSO integration effort | Already done | Needs ext_authz design and rollout |
| Operational complexity | Low (existing) | Medium during migration, lower after unification |
| Dataplane consistency with Cilium | No | Yes |
| Long-term standardization | Medium | High |

## Recommendation

1. **Short-term**: keep Traefik for production stability.
2. **Mid-term**: remove Traefik-specific `ExtensionRef` dependencies first.
3. **Long-term**: migrate to Cilium Gateway to unify dataplane + gateway stack.

## Migration Guardrails

1. Never cut all hostnames in one change.
2. Canary public routes first, protected routes second.
3. Keep Traefik manifests deployable until two full business cycles pass.
4. Rollback is DNS/route-level, not emergency live patch.
