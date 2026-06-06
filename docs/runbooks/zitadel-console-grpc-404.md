# Runbook: ZITADEL console 404 (v1 gRPC through Cilium Gateway)

## Symptom

`https://auth.meirong.dev/ui/console/users/me` (and other console pages) throw **404**.
Login (`/ui/v2/login`) works. The ZITADEL pod logs show no errors.

## Quick triage

The console SPA loads (HTML/JS = 200) but its **v1 gRPC API calls** 404. Probe anonymously
(grpc-web/connect returns HTTP 200 even on errors, so 404 = route/handler miss):

```bash
B=https://auth.meirong.dev
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$B/zitadel.auth.v1.AuthService/GetMyUser" \
  -H 'content-type: application/grpc-web+proto' -H 'x-grpc-web: 1' -d ''     # broken -> 404
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$B/zitadel.user.v2.UserService/GetUserByID" \
  -H 'content-type: application/grpc-web+proto' -H 'x-grpc-web: 1' -d ''     # healthy -> 200
```

If v1 = 404 and v2 = 200, it's the gateway issue below. (Backend is fine — `kubectl
port-forward svc/zitadel 8080` and the same v1 call returns 200 over any protocol.)

## Root cause

Cilium Gateway's Envoy listener runs the `grpc_web` filter, which converts the browser's
grpc-web request into **native gRPC** (`application/grpc`). With
`enable-gateway-api-app-protocol=false` (Cilium default), Cilium ignores Service
`appProtocol` and uses `useDownstreamProtocolConfig` for every backend cluster. The
cloudflared → Envoy hop is **HTTP/1.1**, so Envoy forwards the converted native gRPC over
h1. ZITADEL's **v1 gRPC server only serves over HTTP/2** → 404 (`grpc-status: 12`,
`{"code":5,"message":"Not Found"}`). v2 (connectrpc) tolerates h1, so it works.

Layer isolation that confirms it:
- direct to pod (h1 / h2c / grpc / grpc-web): v1 → 200 (backend healthy)
- via Envoy over **h1**: v1 → 404 ; via Envoy over **h2**: v1 → 200
- Cloudflare is not involved (same 404 hitting the gateway NodePort directly)

## Fix

Enable Cilium's Gateway API appProtocol support so `zitadel:8080`
(`appProtocol: kubernetes.io/h2c`) gets an explicit **h2c** upstream cluster (while
`zitadel-login`, appProtocol empty, stays HTTP/1.1 — it does NOT support h2c):

```bash
helm --kube-context k3s-homelab upgrade cilium cilium/cilium \
  --namespace kube-system --version 1.19.1 --reuse-values \
  --set gatewayAPI.enableAppProtocol=true
kubectl --context k3s-homelab -n kube-system rollout restart deploy/cilium-operator
```

Codified in `k8s/cilium/values.yaml`. Only `zitadel:8080` has `appProtocol: h2c`
cluster-wide, so the flag is surgical — no other backend changes.

## Verify

```bash
# CEC: zitadel cluster -> explicitHttpConfig.http2ProtocolOptions ; login -> httpProtocolOptions
kubectl --context k3s-homelab -n kube-system get ciliumenvoyconfig cilium-gateway-homelab-gateway -o yaml \
  | grep -EA2 'zitadel:(zitadel|zitadel-login)'
# v1 over h1 through the gateway should now be 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  https://auth.meirong.dev/zitadel.auth.v1.AuthService/GetMyUser \
  -H 'content-type: application/grpc-web+proto' -H 'x-grpc-web: 1' -d ''
```

## Notes

- This also unblocks the **ZITADEL Terraform provider** (`zitadel/terraform/`), which
  drives the v1 `admin.v1` gRPC API and would otherwise hit the same 404.
- Fixed 2026-06-07 (Cilium 1.19.1, Helm rev 11). The upgrade without `--version` bumped
  the chart to 1.19.3 while images stayed v1.19.1 (pinned by digest) — realign with
  `--version 1.19.1` if desired.
