# Kopia Backup Server

## Overview

Kopia is deployed in the `kopia` namespace as a backup repository server.
Clients connect via gRPC over HTTPS to back up and restore data.

## Architecture

```
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

Kopia is exposed via **NodePort 31515** on the K8s node (`10.10.10.10`).

```bash
kopia repository connect server \
  --url=https://10.10.10.10:31515 \
  --server-cert-fingerprint=15c5a2e2e2d9c19162a3a500dddfce763d15e0bdba59b7adc16e316881934109 \
  --override-username=admin
```

The password at the prompt is the **server password** (Vault key: `password`).

### Why not Cloudflare Tunnel?

Kopia's gRPC-Go client uses HTTP/2 bidirectional streaming for the `Session()` RPC.
This fails through Cloudflare Tunnel with a 524 timeout, even though:
- Regular HTTP/2 requests work fine (verified with curl)
- Cloudflare gRPC zone setting is enabled
- `http2_origin: true` and `noTLSVerify: true` are configured

The Cloudflare tunnel config and DNS record for `backup.meirong.dev` are kept in
Terraform for future investigation, but the route is non-functional for the kopia CLI.

## User Management

Each client machine needs a registered user in the format `username@hostname`.
Use the justfile recipes to manage users:

```bash
# From k8s/helm/
just kopia-add-user admin@my-laptop
just kopia-list-users
```

After adding a user, the client can connect using the server password.

## TLS Certificate

The TLS cert is generated once and stored in the `kopia-config` PVC.
If you need to regenerate it (e.g., after PVC wipe):

1. Delete the cert files: `kubectl exec -n kopia <pod> -c kopia -- rm /app/config/tls.cert /app/config/tls.key`
2. Add `--tls-generate-cert` back to the server command in `kopia.yaml`
3. Apply and restart, then remove `--tls-generate-cert` again
4. Get the new fingerprint: `just kopia-fingerprint`
