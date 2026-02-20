# Kopia Backup Server

## Overview

Kopia is deployed in the `kopia` namespace as a backup repository server.
Clients connect via gRPC over HTTPS to back up and restore data.

## Architecture

```
Browser (Web UI)   --HTTPS--> backup.meirong.dev --> Cloudflare Tunnel --> Traefik --> kopia pod:51515
Client (kopia CLI) --gRPC/HTTPS--> K8s Node:31515 (NodePort) --> kopia pod:51515
```

- **Repository storage**: NFS PVC (`kopia-repository`, 1Ti)
- **Config/TLS certs**: NFS PVC (`kopia-config`, 1Gi)
- **Secrets**: Vault (`secret/homelab/kopia`) → ESO → `kopia-secret`
  - `password` — server HTTP Basic Auth password
  - `repo-password` — repository encryption password
- **TLS**: Self-signed cert generated on first run, persisted in `kopia-config` PVC
- **ArgoCD**: Managed via `kopia` Application (auto-sync + selfHeal)

## Access

### Web UI

Kopia 的管理界面可通过 Cloudflare Tunnel 正常访问：

```
https://backup.meirong.dev
```

### CLI (NodePort)

Kopia CLI 使用 HTTP/2 双向流式 gRPC (`Session()` RPC)，无法通过 Cloudflare Tunnel（524 超时）。
CLI 客户端须直连 NodePort：

```bash
kopia repository connect server \
  --url=https://10.10.10.10:31515 \
  --server-cert-fingerprint=15c5a2e2e2d9c19162a3a500dddfce763d15e0bdba59b7adc16e316881934109 \
  --override-username=admin
```

The password at the prompt is the **server password** (Vault key: `password`).

> **原因**：常规 HTTP/2 请求（Web UI）可正常通过 Cloudflare；但 kopia CLI 的 gRPC-Go 双向流式 RPC 会触发 524 超时，即使开启了 Cloudflare gRPC zone 设置。CLI 只能走 NodePort 直连。

## User Management

Each client machine needs a registered user in the format `username@hostname`.
Use the justfile recipes to manage users:

```bash
# From k8s/helm/
just kopia-add-user admin@my-laptop
just kopia-list-users
```

After adding a user, the client can connect using the server password.

## Future Improvements

### Envoy gRPC Sidecar

一个潜在的优化方案是在 kopia pod 旁边部署 Envoy 作为 sidecar 代理，用于处理 gRPC 流量：

- **目标**：通过 Envoy 的 `grpc_web` 过滤器将 kopia 的 HTTP/2 双向流式 gRPC (`Session()` RPC) 转换为 gRPC-Web（单向流），从而绕过 Cloudflare Tunnel 对 HTTP/2 双向流的限制。
- **方案**：Envoy sidecar 监听一个新端口（如 51514），将 gRPC-Web 请求转码后转发给 kopia 的原生 gRPC 端口（51515）。Cloudflare Tunnel 指向 Envoy 端口。
- **注意**：kopia CLI 目前不支持 gRPC-Web，需等待上游支持或使用 grpc-web-proxy 方案。此方案仍需验证。

## TLS Certificate

The TLS cert is generated once and stored in the `kopia-config` PVC.
If you need to regenerate it (e.g., after PVC wipe):

1. Delete the cert files: `kubectl exec -n kopia <pod> -c kopia -- rm /app/config/tls.cert /app/config/tls.key`
2. Add `--tls-generate-cert` back to the server command in `kopia.yaml`
3. Apply and restart, then remove `--tls-generate-cert` again
4. Get the new fingerprint: `just kopia-fingerprint`
