# Architecture Simplification Recommendations (2026-03)

> Context: oracle-k3s has completed the Cilium migration. Both clusters now run Cilium + Cilium Gateway API + Cloudflare Tunnel, with Tailscale still carrying cross-cluster pod routing and operational access. ClusterMesh prerequisites are configured, but the mesh is not connected yet.
> Goal: reduce operational coupling, lower recovery complexity, and keep the architecture understandable for a single-operator homelab.

## Current Assessment

The platform is now in a good state:

1. Dual-cluster CNI is unified on Cilium.
2. Core user-facing services are healthy on both clusters.
3. Backup automation exists for homelab and oracle-k3s stateful workloads.
4. Ingress and observability work across clusters, and shared ingress-layer SSO has been removed.

The next risk is no longer "missing capability". It is accumulated complexity:

1. Multiple control planes still overlap: Cilium, Tailscale, Cloudflare Tunnel, ArgoCD, ESO, Vault.
2. Some workloads are GitOps-managed while others still require imperative Helm/bootstrap steps.
3. "Current state" facts are spread across `README.md`, `docs/`, runbooks, and dated plans.

## Recommendation Summary

### 1. Keep ClusterMesh as the next optional step, not an immediate rollout

Recommendation: keep ClusterMesh in a prepared-but-disabled state until there is a concrete pain point that Tailscale pod routing cannot solve.

Why:

1. Current cross-cluster traffic volume is small.
2. Existing traffic types are already handled: observability export, Vault access, and admin access.
3. ClusterMesh adds certificate lifecycle, clustermesh-apiserver operations, and another failure domain.
4. A single-node homelab control plane is the wrong place to introduce networking magic without a strong payoff.

Trigger to revisit:

1. You need cross-cluster service discovery without NodePort or public URLs.
2. You want cross-cluster service failover or locality-aware routing.
3. Tailscale subnet routing becomes unstable or operationally expensive.

## 2. Narrow Tailscale to underlay and management only

Recommendation: document and enforce one principle: Tailscale carries node-to-node traffic, not app-to-app service design.

Keep using Tailscale for:

1. SSH and operator access.
2. Vault access from oracle-k3s to homelab.
3. OTel export to homelab NodePorts.
4. Backup traffic to Kopia.

Avoid introducing new dependencies on:

1. Remote cluster Service CIDRs.
2. Remote cluster ClusterIP assumptions.
3. Private-only service URLs for app traffic unless there is no public or NodePort option.

Expected benefit:

1. Fewer hidden cross-cluster dependencies.
2. Easier disaster recovery when one cluster is down.
3. Less pressure to adopt ClusterMesh early.

## 3. Convert remaining imperative bootstrap into declarative assets

Recommendation: reduce "operator memory" by eliminating one-off terminal procedures.

Highest-value targets:

1. Timeslot deployment.
2. Vault token bootstrap for oracle-k3s.
3. Cloudflare tunnel protocol override knowledge (`--protocol http2`).

Practical direction:

1. Vendor or fork the Timeslot chart so the probe and init-container fixes live in Git, not in a runtime patch step.
2. Replace the manual Vault token handoff with a short-lived bootstrap runbook plus explicit renewal procedure, or move to a more durable auth model if feasible.
3. Keep the cloudflared HTTP/2 decision encoded in manifests and documented as an OCI-specific constraint.

## 4. Separate "current truth" from historical plans more aggressively

Recommendation: treat dated `docs/plans/` files as history, not living truth.

Operational facts should live in:

1. `docs/README.md`
2. `docs/architecture/*.md`
3. `docs/runbooks/*.md`
4. cluster-local READMEs such as `cloud/oracle/README.md`

Historical files should not be the only place that contains:

1. active ports,
2. probe endpoints,
3. current cluster topology,
4. supported operational commands.

Practical follow-up:

1. Add a monthly documentation audit checklist.
2. Prefer linking to architecture docs from plans rather than duplicating current-state tables.

## 5. Reduce split-brain deployment modes on oracle-k3s

Recommendation: keep kustomize for most workloads, but shrink the number of exceptions.

Current exceptions:

1. Timeslot is Helm-managed outside the main `apply -k manifests/` flow.
2. Some secrets and bootstrap order still depend on manual sequencing.

Suggested direction:

1. Either fully adopt a small App-of-Apps/GitOps model for oracle-k3s, or keep it explicitly imperative but documented as such.
2. Minimize the middle ground where some apps are declarative and others need hidden post-apply patching.

The simplest path is probably:

1. keep oracle-k3s outside ArgoCD for now,
2. but make `just bootstrap` and `just deploy-timeslot` fully reproducible from repo state,
3. and remove any manual JSON patch or one-off shell quoting traps.

## 6. Prefer "boring" networking choices over theoretical performance wins

Recommendation: stay on `routingMode: tunnel` for now.

Why:

1. It is already working on both clusters.
2. It keeps homelab and Oracle deployment behavior aligned.
3. It avoids introducing OCI-specific direct-routing or L2 assumptions.

Only revisit native routing if one of these becomes real:

1. sustained throughput bottlenecks,
2. MTU pain you cannot mitigate,
3. a compelling need for better host-path behavior that outweighs simplicity.

## 7. Add one validation layer for doc + automation drift

Recommendation: add a lightweight periodic audit task.

Scope:

1. verify referenced ports against manifests,
2. verify documented probes against deployments,
3. verify `just` recipes referenced in READMEs actually exist,
4. verify key URLs still respond with expected status codes.

This does not need a large framework. Even a small shell-based validation script run manually or in CI would catch most drift.

## Suggested Priority

### Now

1. Keep current dual-Cilium state stable.
2. Finish documentation consolidation.
3. Remove imperative rough edges in `deploy-timeslot`.

### Next

1. Add doc/automation drift checks.
2. Add backup restore rehearsal evidence to docs.
3. Review whether Oracle-side workloads that are still special cases can be normalized.

### Later

1. ClusterMesh PoC in an isolated branch or disposable environment.
2. Traefik to Cilium Gateway evaluation only after auth story is simpler.
3. Native routing experiments only when there is measurable pressure.

## Bottom Line

The best next move is simplification, not expansion.

You already have enough moving parts to run a capable dual-cluster homelab. The platform will become more robust by removing exceptional paths, tightening documentation, and deferring ClusterMesh until the need is undeniable.
