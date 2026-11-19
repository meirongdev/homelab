# Cilium (homelab)

Cilium is the CNI for the homelab K3s cluster (eBPF + VXLAN, kube-proxy replacement,
Gateway API, Hubble, ClusterMesh peer to oracle-k3s). It was originally installed by
hand with the Helm CLI, so its configuration lived only in the live release.
`values.yaml` here is the codified source of truth — keep it in sync with the cluster.

> **Not managed by ArgoCD.** Like Vault and the Helm observability stack, Cilium is
> applied manually. ArgoCD must not own the CNI.

## Version

- Chart: `cilium/cilium`; running images pinned to **v1.20.5** (by digest, in-cluster).
- Keep `--version` equal to `cilium_version` in `versions.just` (shared with oracle) on upgrades.

## Apply / upgrade

```bash
helm repo add cilium https://helm.cilium.io/ && helm repo update   # once
# caBundle is not in values.yaml (see note there) — supply it from the live cluster:
kubectl --context k3s-homelab -n kube-system get secret cilium-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/cilium-ca.crt

helm --kube-context k3s-homelab upgrade --install cilium cilium/cilium \
  --namespace kube-system --version 1.20.5 \
  -f k8s/cilium/values.yaml \
  --set-file tls.caBundle.content=/tmp/cilium-ca.crt

kubectl --context k3s-homelab -n kube-system rollout restart deploy/cilium-operator
```

> **Automated:** `cd k8s/helm && just deploy-cilium` runs exactly this — it restores the
> live `cilium-ca` (or self-signs on a fresh install), pins `--version <cilium_version>` from `versions.just`, applies
> this `values.yaml`, and refreshes the Hubble certs. Prefer it over the raw command above.

## Before you bump `cilium_version` (even a patch)

☠️ A patch bump is not automatically safe: chart **defaults** move between patch releases and the
release notes do not say so. 1.20.0 → 1.20.5 silently flipped `envoy.xdsMode` from `ads` to `split`
(and moved Envoy 1.37 → 1.39) for any values file that did not pin it. Do this first:

```bash
for v in <old> <new>; do
  helm template cilium cilium --repo https://helm.cilium.io/ --version $v -n kube-system \
    -f k8s/cilium/values.yaml --set tls.caBundle.enabled=false > /tmp/cilium-$v.yaml
done
# compare the ConfigMaps *structurally* (cilium-config, cilium-envoy-config bootstrap JSON),
# not just image tags; TLS secrets differ on every render, ignore them
```

Then: deploy one cluster, run `just connect-clustermesh …` (every `--reset-values` deploy drops
cross-cluster trust), compare the HTTP status of **every routed hostname** against a baseline taken
before (a Gateway canary only proves route status, not forwarding), soak a few minutes, then the next
cluster. Gate on the Gateway API CRD pair (`versions.just`, check V3) and on the minor being inside
Cilium's tested Kubernetes range (1.20: 1.33–1.36) before raising k3s.

After a config change that affects Gateway API translation, the operator regenerates
the `CiliumEnvoyConfig`; Envoy picks it up via xDS (no envoy restart needed).

## Notable settings

- **`gatewayAPI.enableAppProtocol: true`** — makes Cilium honour Service `appProtocol`
  (`kubernetes.io/h2c` → explicit h2c upstream)，任何 gRPC/h2c 后端过网关都依赖它。
  历史上为 ZITADEL console 引入（关掉会复现 `/ui/console/*` 404，全程见
  `docs/records/2026-06-07-zitadel-console-grpc-404.md`）。ZITADEL 已于 2026-07 迁至
  oracle-k3s，homelab 当前无 h2c 后端——设置无害，刻意保留以备未来 gRPC 服务。
- **`envoy.xdsMode: ads`** — pinned explicitly (2026-11-20). Live clusters run ADS; the chart's
  own default changed between 1.20.0 and 1.20.5, so an unpinned file silently switches mode.
- **ClusterMesh** to oracle-k3s (`100.107.166.37:32379`, KVStoreMesh). The shared CA
  (`cilium-ca` secret) must be preserved/restored on reinstall or clustermesh trust breaks.

## Verify

```bash
kubectl --context k3s-homelab -n kube-system exec ds/cilium -c cilium-agent -- cilium status
# Gateway API h2c honoured?（仅当网关后面有 appProtocol=kubernetes.io/h2c 的后端时适用；
# 该后端的 envoy cluster 应显示 explicitHttpConfig.http2ProtocolOptions。
# 示例为迁移前的 zitadel，当前 homelab 无 h2c 后端，grep 会为空）
kubectl --context k3s-homelab -n kube-system get ciliumenvoyconfig cilium-gateway-homelab-gateway -o yaml \
  | grep -B1 -A2 'http2ProtocolOptions'
```
