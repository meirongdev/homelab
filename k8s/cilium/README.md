# Cilium (homelab)

Cilium is the CNI for the homelab K3s cluster (eBPF + VXLAN, kube-proxy replacement,
Gateway API, Hubble, ClusterMesh peer to oracle-k3s). It was originally installed by
hand with the Helm CLI, so its configuration lived only in the live release.
`values.yaml` here is the codified source of truth — keep it in sync with the cluster.

> **Not managed by ArgoCD.** Like Vault and the Helm observability stack, Cilium is
> applied manually. ArgoCD must not own the CNI.

## Version

- Chart: `cilium/cilium`; running images pinned to **v1.19.1** (by digest, in-cluster).
- Keep `--version 1.19.1` on upgrades so the chart matches the pinned images.

## Apply / upgrade

```bash
helm repo add cilium https://helm.cilium.io/ && helm repo update   # once
# caBundle is not in values.yaml (see note there) — supply it from the live cluster:
kubectl --context k3s-homelab -n kube-system get secret cilium-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/cilium-ca.crt

helm --kube-context k3s-homelab upgrade --install cilium cilium/cilium \
  --namespace kube-system --version 1.19.1 \
  -f k8s/cilium/values.yaml \
  --set-file tls.caBundle.content=/tmp/cilium-ca.crt

kubectl --context k3s-homelab -n kube-system rollout restart deploy/cilium-operator
```

> **Automated:** `cd k8s/helm && just deploy-cilium` runs exactly this — it restores the
> live `cilium-ca` (or self-signs on a fresh install), pins `--version 1.19.1`, applies
> this `values.yaml`, and refreshes the Hubble certs. Prefer it over the raw command above.

After a config change that affects Gateway API translation, the operator regenerates
the `CiliumEnvoyConfig`; Envoy picks it up via xDS (no envoy restart needed).

## Notable settings

- **`gatewayAPI.enableAppProtocol: true`** — required for the ZITADEL console. Makes
  Cilium honour Service `appProtocol`, so `zitadel:8080` (`kubernetes.io/h2c`) gets an
  explicit h2c upstream and its v1 gRPC services work through the gateway. Turning this
  off resurfaces the console `/ui/console/*` 404s. Full story:
  `docs/runbooks/zitadel-console-grpc-404.md`.
- **ClusterMesh** to oracle-k3s (`100.107.166.37:32379`, KVStoreMesh). The shared CA
  (`cilium-ca` secret) must be preserved/restored on reinstall or clustermesh trust breaks.

## Verify

```bash
kubectl --context k3s-homelab -n kube-system exec ds/cilium -c cilium-agent -- cilium status
# Gateway API h2c honoured? zitadel cluster should show explicitHttpConfig.http2ProtocolOptions:
kubectl --context k3s-homelab -n kube-system get ciliumenvoyconfig cilium-gateway-homelab-gateway -o yaml \
  | grep -A2 'zitadel:zitadel:8080'
```
