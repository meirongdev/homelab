# 2026-03-09 Oracle / Public Sites Outage Report

## Summary

On 2026-03-09, most public sites backed by the `oracle-k3s` cluster became unreachable.
Externally, Cloudflare returned `530` for multiple domains including:

- `home.meirong.dev`
- `status.meirong.dev`
- `rss.meirong.dev`
- `keep.meirong.dev`
- `slot.meirong.dev`
- `tool.meirong.dev`
- `squoosh.meirong.dev`
- `pdf.meirong.dev`

The `k3s-homelab` cluster did **not** have the same outage pattern. Its core services stayed healthy and public homelab sites such as `argocd.meirong.dev`, `grafana.meirong.dev`, and `vault.meirong.dev` remained reachable.

## Impact

- Public Oracle-hosted services behind the Cloudflare tunnel were unavailable.
- Uptime Kuma itself was affected because the tunnel and in-cluster routing were broken.
- RSS / Miniflux was additionally broken by an app-level configuration error after cluster networking recovered.

## Root Causes

### Root cause 1: oracle-k3s Cilium bootstrap drift

The live `oracle-k3s` Cilium DaemonSet had drifted from the repository's intended configuration.

The repository already declares:

- `cloud/oracle/values/cilium-values.yaml`
  - `k8sServiceHost: "10.0.0.26"`
  - `k8sServicePort: 6443`

However, the live oracle Cilium DaemonSet was missing the corresponding:

- `KUBERNETES_SERVICE_HOST=10.0.0.26`
- `KUBERNETES_SERVICE_PORT=6443`

Because `kubeProxyReplacement` is enabled, Cilium must be able to reach the API server directly during bootstrap. Without the explicit API endpoint, the Cilium init container attempted to contact the in-cluster service IP instead:

- `https://10.53.0.1:443`

That failed with timeout:

```text
Unable to contact k8s api-server ... dial tcp 10.53.0.1:443: i/o timeout
```

This caused the following cascade on `oracle-k3s`:

- `cilium` bootstrap failed
- `cilium-operator` kept failing probes / restarting
- many pods emitted repeated `SandboxChanged` events
- `cloudflared` exited after receiving `SIGTERM`
- Cloudflare tunnel lost all active origin connections
- public requests returned `HTTP 530`

### Root cause 2: stale Miniflux database URL

After oracle networking recovered, `rss.meirong.dev` still returned `503`.

`miniflux` was in `CrashLoopBackOff` with:

```text
dial tcp: lookup miniflux-db.rss-system.svc.cluster.local on 10.53.0.10:53: no such host
```

The synced secret `miniflux-db-secret` still carried a stale `database-url` pointing to a nonexistent service:

- bad host: `miniflux-db.rss-system.svc.cluster.local`
- actual service: `rss-postgres.rss-system.svc.cluster.local`

This was coming from the Vault-backed `database_url` field, which was more fragile than deriving the URL from the known in-cluster service name.

## Evidence Collected

### External symptoms

- `curl -I https://status.meirong.dev` returned `HTTP/2 530`
- Cloudflare body contained `error code: 1033`

### oracle-k3s tunnel state before fix

`cloudflared` logs showed the tunnel had connected successfully earlier, then shut down:

```text
Initiating graceful shutdown due to signal terminated
...
ERR no more connections active and exiting
```

### oracle-k3s cluster symptoms before fix

- most app Deployments were `0/1` or `0/2`
- many pods were `Completed`, `Error`, or `Unknown`
- repeated `SandboxChanged` events were present across namespaces
- `Gateway/kube-system/oracle-gateway` remained `Programmed=False`

### k3s-homelab comparison

`k3s-homelab` remained healthy:

- Cilium healthy
- Cloudflare tunnel healthy
- core public services reachable

This confirmed the outage was concentrated on `oracle-k3s`, not a global Cloudflare or repo-wide failure.

## Remediation Performed

### 1. Re-applied oracle Cilium from repo

Executed:

```bash
cd cloud/oracle
just deploy-cilium
```

Result:

- live oracle Cilium DaemonSet regained:
  - `KUBERNETES_SERVICE_HOST=10.0.0.26`
  - `KUBERNETES_SERVICE_PORT=6443`
- `cilium` recovered to `OK`
- oracle cluster workloads re-entered `Running`
- public Oracle sites recovered from `530`

### 2. Made Miniflux DB URL deterministic in Git

Updated:

- `cloud/oracle/manifests/rss-system/secrets.yaml`

Instead of syncing a full `database_url` from Vault, the `ExternalSecret` now templates the secret in-cluster using the fetched DB password and the stable service name:

```text
postgres://miniflux:{{ .password }}@rss-postgres.rss-system.svc.cluster.local:5432/miniflux?sslmode=disable
```

This avoids future breakage if Vault carries an outdated hostname.

### 3. Forced secret sync and restarted Miniflux

Executed:

```bash
kubectl --context oracle-k3s apply -f cloud/oracle/manifests/rss-system/secrets.yaml
kubectl --context oracle-k3s -n rss-system annotate externalsecret miniflux-db-secret force-sync=... --overwrite
kubectl --context oracle-k3s -n rss-system rollout restart deploy/miniflux
kubectl --context oracle-k3s -n rss-system rollout status deploy/miniflux
```

Result:

- `rss.meirong.dev` returned `200`
- new `miniflux` pod became `1/1 Running`

### 4. Cleaned unnecessary pods

Removed:

- completed / failed pods on both clusters
- leftover homelab `node-debugger-*` pods
- old completed Helm install pods
- stale `zitadel` setup pods
- leftover oracle `cilium-test-1` namespace

## Verification After Fix

### Public probes

Observed after remediation:

- `home.meirong.dev` → `200`
- `status.meirong.dev` → `200`
- `rss.meirong.dev` → `200`
- `tool.meirong.dev` → `200`
- `squoosh.meirong.dev` → `200`
- `argocd.meirong.dev` → `200`
- `grafana.meirong.dev` → `302` (expected redirect)
- `vault.meirong.dev` → `307` (expected redirect)
- `keep.meirong.dev` → `307` (expected app redirect/auth flow)
- `slot.meirong.dev` → `302` (expected redirect)
- `pdf.meirong.dev` → `401` (expected auth-protected response, origin healthy)

### Cluster verification

`oracle-k3s` after repair:

- `cloudflared` pods: `1/1 Running`
- `cilium`: healthy
- `cilium-operator`: `1/1 Running`
- `homepage`, `uptime-kuma`, `it-tools`, `timeslot`, `squoosh`, `karakeep`, `rsshub`, `rss-postgres`, `miniflux`: running

`k3s-homelab` after cleanup:

- core workloads remained healthy
- no matching public outage pattern found

## Remaining Notes

- `kube-system/hubble-relay` on `oracle-k3s` was still restarting during verification, but this did not affect public site reachability.
- `pdf.meirong.dev` returning `401` is expected because Stirling-PDF is up and enforcing auth.

## Prevention / Follow-up

1. After any oracle cluster rebuild, restart, or Cilium upgrade, verify the live DaemonSet still contains:
   - `KUBERNETES_SERVICE_HOST`
   - `KUBERNETES_SERVICE_PORT`
2. Prefer generating connection strings inside `ExternalSecret.target.template` when the service hostname is stable and known from Git.
3. Keep Vault entries focused on credentials, not full in-cluster hostnames, where practical.
4. If public Oracle sites suddenly return `530`, first check:
   - `kubectl --context oracle-k3s -n kube-system get pods -l k8s-app=cilium`
   - `kubectl --context oracle-k3s -n cloudflare get pods`
   - `kubectl --context oracle-k3s get events -A | tail`
