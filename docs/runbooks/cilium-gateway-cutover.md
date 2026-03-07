# Cilium Gateway Cutover Runbook

> Purpose: deploy the current repo state for `Cloudflare Tunnel -> Cilium Gateway API -> Services`, then validate traffic end to end.
> Scope: homelab + oracle-k3s.
> Last updated: 2026-03-07

## Goal

Success means all of the following are true:

1. Both clusters run Cilium with `gatewayAPI.enabled=true` and `kubeProxyReplacement=true`.
2. Both clusters expose a local Cilium-managed Gateway Service in `kube-system`.
3. Cloudflare Tunnel forwards to the local Cilium Gateway Service on each cluster.
4. `Gateway` and `HTTPRoute` resources are accepted.
5. Public domains respond through the new path.
6. No shared ingress-layer SSO or Traefik dependency remains in the live request path.

## Important Notes

1. Do not use `k8s/helm/justfile` target `deploy-gateway` for this cutover. It still references the old Traefik helper path.
2. ArgoCD manages the homelab `gateway` and `cloudflare` manifests, but ArgoCD Application definitions themselves are not auto-managed. Re-apply changed Application manifests explicitly.
3. oracle-k3s base manifests are still applied from `cloud/oracle/manifests/`.
4. ClusterMesh is optional in this runbook. The repo is prepared for it, but the mesh is not considered part of the ingress cutover.

## Preconditions

1. Local kubeconfig contains both contexts:
   - `k3s-homelab`
   - `oracle-k3s`
2. Vault / ESO secrets already exist for `cloudflare-tunnel-token` and other app secrets.
3. Tailscale underlay is healthy enough for cross-cluster observability and control-plane access.
4. You have reviewed `git status` and are deploying the intended revision.
5. You have a rollback commit or tag for the previous known-good state.

## Phase 0: Preflight

Run these commands from the repository root unless noted otherwise.

```bash
kubectl config get-contexts
kubectl --context k3s-homelab get nodes
kubectl --context oracle-k3s get nodes
kubectl --context k3s-homelab get pods -n kube-system
kubectl --context oracle-k3s get pods -n kube-system
```

Check the current Gateway and Tunnel health before making changes:

```bash
kubectl --context k3s-homelab get gateway,httproute -A
kubectl --context oracle-k3s get gateway,httproute -A
kubectl --context k3s-homelab get pods -n cloudflare
kubectl --context oracle-k3s get pods -n cloudflare
```

Optional but recommended: capture the current public behavior for comparison.

```bash
curl -I https://argocd.meirong.dev
curl -I https://grafana.meirong.dev
curl -I https://home.meirong.dev
curl -I https://rss.meirong.dev
```

## Phase 1: Deploy Cilium Changes

### 1.1 Homelab

```bash
cd k8s/helm
just deploy-cilium
just cilium-status
```

Validate the key settings from the live ConfigMap / status:

```bash
kubectl --context k3s-homelab -n kube-system get pods -l k8s-app=cilium
kubectl --context k3s-homelab -n kube-system get svc | grep cilium
kubectl --context k3s-homelab exec -n kube-system ds/cilium -c cilium-agent -- cilium status --verbose
```

### 1.2 oracle-k3s

```bash
cd cloud/oracle
just deploy-cilium
just cilium-status
```

Validate:

```bash
kubectl --context oracle-k3s -n kube-system get pods -l k8s-app=cilium
kubectl --context oracle-k3s -n kube-system get svc | grep cilium
kubectl --context oracle-k3s exec -n kube-system ds/cilium -c cilium-agent -- cilium status --verbose
```

## Phase 2: Apply Gateway and Tunnel Manifests

### 2.1 Re-apply homelab ArgoCD Application definitions

This ensures ArgoCD is tracking the updated source layout.

```bash
kubectl --context k3s-homelab apply -f argocd/projects/homelab.yaml
kubectl --context k3s-homelab apply -f argocd/applications/gateway.yaml
kubectl --context k3s-homelab apply -f argocd/applications/cloudflare.yaml
kubectl --context k3s-homelab apply -f argocd/applications/monitoring-dashboards.yaml
```

Then trigger sync:

```bash
cd k8s/helm
just argocd-sync
just argocd-status
```

Validate the synced resources:

```bash
kubectl --context k3s-homelab get gateway,httproute -A
kubectl --context k3s-homelab get svc -n kube-system | grep cilium-gateway
kubectl --context k3s-homelab get pods -n cloudflare
```

### 2.2 Apply oracle-k3s manifests

oracle-k3s base resources, including `base/gateway.yaml` and `base/cloudflare-tunnel.yaml`, come from the Kustomize tree.

```bash
cd cloud/oracle
just deploy-manifests
```

Validate:

```bash
kubectl --context oracle-k3s get gateway,httproute -A
kubectl --context oracle-k3s get svc -n kube-system | grep cilium-gateway
kubectl --context oracle-k3s get pods -n cloudflare
```

## Phase 3: Apply Cloudflare Tunnel Configuration

### 3.1 Homelab Cloudflare config

```bash
cd cloudflare/terraform
just plan
just apply
```

Expected service target in `terraform.tfvars`:

- `http://cilium-gateway-homelab-gateway.kube-system.svc:80`

### 3.2 oracle-k3s Cloudflare config

```bash
cd cloud/oracle/cloudflare
just plan
just apply
```

Expected service target in `terraform.tfvars`:

- `http://cilium-gateway-oracle-gateway.kube-system.svc:80`

## Phase 4: In-Cluster Validation

### 4.1 Gateway resources accepted

```bash
kubectl --context k3s-homelab describe gateway homelab-gateway -n kube-system
kubectl --context oracle-k3s describe gateway oracle-gateway -n kube-system
kubectl --context k3s-homelab get httproute -A
kubectl --context oracle-k3s get httproute -A
```

Look for:

1. `Accepted=True`
2. `ResolvedRefs=True`
3. backend services and endpoints exist

### 4.2 Gateway Service exists

```bash
kubectl --context k3s-homelab get svc -n kube-system cilium-gateway-homelab-gateway
kubectl --context oracle-k3s get svc -n kube-system cilium-gateway-oracle-gateway
```

### 4.3 Internal traffic test via Host header

Homelab example:

```bash
kubectl --context k3s-homelab run test-curl-homelab \
  --image=curlimages/curl --rm -it --restart=Never \
  -- sh -c "curl -sS -D - -o /dev/null -H 'Host: grafana.meirong.dev' http://cilium-gateway-homelab-gateway.kube-system.svc/"
```

oracle-k3s example:

```bash
kubectl --context oracle-k3s run test-curl-oracle \
  --image=curlimages/curl --rm -it --restart=Never \
  -- sh -c "curl -sS -D - -o /dev/null -H 'Host: home.meirong.dev' http://cilium-gateway-oracle-gateway.kube-system.svc/"
```

## Phase 5: Public Validation

Run these from your workstation after DNS / tunnel changes are live.

```bash
curl -I https://argocd.meirong.dev
curl -I https://grafana.meirong.dev
curl -I https://vault.meirong.dev
curl -I https://book.meirong.dev
curl -I https://home.meirong.dev
curl -I https://rss.meirong.dev
curl -I https://keep.meirong.dev
curl -I https://status.meirong.dev
```

Expected outcomes:

1. Requests reach the app or the app's own auth page.
2. No redirect chain to a shared `oauth2-proxy` endpoint.
3. `cloudflared` pods remain healthy on both clusters.

Useful checks:

```bash
kubectl --context k3s-homelab logs -n cloudflare deploy/cloudflared --tail=100
kubectl --context oracle-k3s logs -n cloudflare deploy/cloudflared --tail=100
kubectl --context k3s-homelab get svc -n kube-system | grep cilium-gateway
kubectl --context oracle-k3s get svc -n kube-system | grep cilium-gateway
```

## Phase 6: Optional ClusterMesh Enablement

Only do this after ingress is already stable.

### 6.1 Preconditions

1. Both clusters are already running the updated Cilium Helm values.
2. Port `32379/tcp` is reachable between nodes over Tailscale.
3. The `cilium` CLI is installed locally.

### 6.2 Enable and connect

```bash
cilium clustermesh enable --context k3s-homelab --service-type NodePort
cilium clustermesh enable --context oracle-k3s --service-type NodePort
cilium clustermesh connect --context k3s-homelab --destination-context oracle-k3s
```

### 6.3 Validate mesh status

```bash
cilium clustermesh status --context k3s-homelab --wait
cilium clustermesh status --context oracle-k3s --wait
kubectl --context k3s-homelab get svc -n kube-system | grep clustermesh
kubectl --context oracle-k3s get svc -n kube-system | grep clustermesh
```

ClusterMesh is not required for the Cloudflare -> Gateway cutover itself. Treat it as a second rollout.

## Rollback

If validation fails, roll back in this order.

### 1. Roll back Git state

Return the repo to the last known-good revision, then re-apply the manifests and DNS config from that revision.

### 2. Roll back Cloudflare routing

Apply the previous Terraform state / config revision for:

```bash
cd cloudflare/terraform && just apply
cd cloud/oracle/cloudflare && just apply
```

### 3. Roll back Kubernetes manifests

Re-apply the previous known-good manifests / Application definitions from Git:

```bash
kubectl --context k3s-homelab apply -f argocd/applications/
cd k8s/helm && just argocd-sync
cd cloud/oracle && just deploy-manifests
```

### 4. Confirm recovery

```bash
kubectl --context k3s-homelab get gateway,httproute -A
kubectl --context oracle-k3s get gateway,httproute -A
curl -I https://argocd.meirong.dev
curl -I https://home.meirong.dev
```

## Post-Cutover Checks

1. Confirm `docs/architecture/cloudflare-tunnel-observability.md` still matches live behavior.
2. Confirm `docs/architecture/tailscale-network.md` still reflects the underlay role only.
3. If the cutover succeeded, record timestamps and anomalies in the relevant `docs/plans/` note.
