# DNS & Network Failure Recovery

## Symptom

After a network interruption (router reboot, ISP outage, etc.), homelab services fail to
recover automatically:

- Cloudflare Tunnel returns **HTTP 530** (tunnel can't connect)
- All pods stuck in **ImagePullBackOff** / **ErrImagePull**
- `kubectl get nodes` → `dial tcp 10.10.10.10:6443: i/o timeout`
- Local DNS returns **NXDOMAIN** for recently-created records

## Root Cause Chain

```
Network interruption
  → Tailscale MagicDNS (100.100.100.100) caches NXDOMAIN for external domains
      (negative TTL from SOA MINIMUM = 1800s)
  → systemd-resolved on K3s node has no fallback DNS configured
  → CoreDNS (10.43.0.10) forwards to node's systemd-resolved → also broken
  → cloudflared can't resolve argotunnel.com → tunnel stays down → HTTP 530
  → kubelet can't pull images (registry-1.docker.io unresolvable)
      → ImagePullBackOff on ALL pods
  → kubectl can't reach API server on 10.10.10.10 (local network path disrupted)
```

## Permanent Fixes Applied

### 1. systemd-resolved Fallback DNS (K3s node)

File: `/etc/systemd/resolved.conf.d/fallback.conf`

```ini
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=8.8.4.4
```

Applied automatically by `setup-k3s.yaml` Ansible playbook.
Run manually on existing nodes: `cd k8s/ansible && just fix-dns`

### 2. K3s TLS SAN includes Tailscale IP

File: `/etc/rancher/k3s/config.yaml`

```yaml
tls-san:
  - 10.10.10.10       # local network
  - 100.107.254.112   # Tailscale IP
```

Allows `kubectl` to connect via Tailscale when local network is down.
Applied by `setup-k3s.yaml`. kubeconfig now uses Tailscale IP by default.

### 3. cloudflared: 2 replicas + liveness probe

```yaml
replicas: 2
livenessProbe:
  httpGet:
    path: /ready
    port: 2000   # --metrics endpoint
  periodSeconds: 30
  failureThreshold: 3
```

K8s auto-restarts any cloudflared pod that loses tunnel connectivity.
2 replicas = zero-downtime during restarts (Cloudflare load-balances).

## Emergency Recovery Procedure

### Step 1 — SSH via Tailscale

```bash
ssh -i ~/.ssh/vgio root@100.107.254.112
```

> Local network path (`10.10.10.10`) may be down. Use Tailscale IP.

### Step 2 — Fix DNS on the node

```bash
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/fallback.conf << 'EOF'
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=8.8.4.4
EOF
systemctl restart systemd-resolved
nslookup registry-1.docker.io  # verify
```

### Step 3 — Restore kubectl access via Tailscale

```bash
kubectl config set-cluster k3s-homelab --server=https://100.107.254.112:6443
```

If TLS error (`x509: certificate is not valid for 100.107.254.112`):

```bash
# On the node:
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml << 'EOF'
tls-san:
  - 100.107.254.112
  - 10.10.10.10
EOF
systemctl restart k3s
```

### Step 4 — Force restart stuck pods

```bash
for ns in argocd cloudflare homepage kopia personal-services; do
  kubectl --context k3s-homelab delete pods -n $ns --all --force
done
```

### Step 5 — Verify recovery

```bash
curl -sI https://grafana.meirong.dev   # expect 302
curl -sI https://vault.meirong.dev     # expect 307
kubectl --context k3s-homelab get pods -A | grep -v Running
```

## Local Mac DNS: Tailscale Negative Cache

**Symptom**: A newly-created DNS record resolves via `dig @1.1.1.1` but not locally.

**Cause**: Tailscale MagicDNS (`100.100.100.100`) cached NXDOMAIN before the record
was created. SOA MINIMUM = 1800s, so the cache can persist up to 30 minutes.

**Fix (temporary)**: Override system DNS to bypass Tailscale:

```bash
networksetup -setdnsservers Wi-Fi 1.1.1.1 8.8.8.8
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
# ... use the service ...
networksetup -setdnsservers Wi-Fi "Empty"  # restore to DHCP/Tailscale
```

**Fix (wait)**: The negative cache expires automatically after ~30 min.

## Key IPs & Ports

| Resource | Address |
|----------|---------|
| Homelab node (local) | `10.10.10.10` |
| Homelab node (Tailscale) | `100.107.254.112` |
| K3s API server | `:6443` |
| Vault UI | `100.107.254.112:31144` |
| Loki OTLP NodePort | `100.107.254.112:31080` |
