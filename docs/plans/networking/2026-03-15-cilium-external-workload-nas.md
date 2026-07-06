# Connect Debian NAS to Cilium Network via External Workload

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Join the Debian NAS (`192.168.50.106`) to the homelab Cilium network as a managed external workload, so the NAS can reach cluster Services and pods can reach the NAS over Cilium-controlled paths with policy support.

**Architecture:** Cilium's External Workloads feature installs a full Cilium agent on the NAS in "external workload" mode. The cluster-side `CiliumExternalWorkload` CR reserves a Pod-CIDR IP for the NAS. The agent tunnels back to the homelab node over the existing LAN (VXLAN on top of the same underlay used by in-cluster traffic). No new Tailscale config needed — both nodes are on `192.168.50.0/24`.

**Tech Stack:** Cilium ≥ 1.15 external workloads, Debian (NAS host OS), kubectl, Helm, just, ArgoCD

---

## Background

The NAS currently serves NFS at `192.168.50.106`. Pods reach it by its LAN IP. There is no policy enforcement on NFS access, and the NAS cannot use Kubernetes DNS or reach cluster Services without a routable path.

Cilium External Workloads solves this by:

1. Installing the Cilium agent on the NAS (not as a pod, as a systemd service)
2. Giving the NAS a virtual IP in `10.42.0.0/16` (its Cilium identity)
3. Running a VXLAN tunnel from the NAS back to the homelab K3s node
4. Registering the NAS as a `CiliumNode` so the rest of the cluster sees it like any other node

After this, network policies can govern which pods may access NFS, and the NAS can resolve `*.cluster.local` names via kube-dns.

## Key Decisions

### 1. External Workload vs. Subnet Route

Cilium External Workloads requires running the full Cilium agent on the NAS. The alternative (just adding a static CIDR route) gives reachability but no identity or policy. We choose External Workloads to get policy enforcement on NFS traffic.

### 2. Tunnel underlay: LAN (not Tailscale)

Both the homelab node and NAS are on `192.168.50.0/24`. Using the LAN directly is simpler and avoids Tailscale MTU overhead. The VXLAN port (8472/udp) must be open on the NAS firewall.

### 3. Pod CIDR allocation for the NAS

We reserve `10.42.200.0/24` for external workloads by adding it explicitly to the Cilium IPAM config. The NAS gets `10.42.200.1`. This range is outside K3s's default node allocations (which start at `10.42.0.0/24` and count up) so there is no collision risk.

### 4. Cilium values change is non-destructive

Adding `externalWorkloads.enabled: true` and an IPAM reservation to `cilium-values.yaml` only changes what the Cilium operator makes available. It does not restart the dataplane or affect in-flight connections.

---

## Phase 1: Cluster-Side Changes

### Files

| Action | File |
|--------|------|
| MODIFY | `k8s/helm/values/cilium-values.yaml` |
| CREATE | `k8s/helm/manifests/nas-external-workload.yaml` |
| MODIFY | `argocd/applications/personal-services.yaml` (add include glob) |

---

### Task 1: Enable External Workloads in Cilium Values

**File:** `k8s/helm/values/cilium-values.yaml`

- [ ] **Step 1.1: Add the externalWorkloads stanza**

  Append to `k8s/helm/values/cilium-values.yaml`:

  ```yaml
  # --- External Workloads: allow non-K8s hosts to join the Cilium network ---
  externalWorkloads:
    enabled: true
  ```

  Also extend the IPAM block to reserve the external-workload subnet so the operator does not assign those IPs to pods:

  ```yaml
  ipam:
    operator:
      clusterPoolIPv4PodCIDRList:
        - "10.42.0.0/16"
      # Reserve /24 for external workloads so K3s node allocations don't collide
      clusterPoolIPv4Mask: 24
  ```

  > Note: `clusterPoolIPv4Mask` controls per-node allocation size, not the external range. The important thing is that `10.42.200.0/24` is not handed to any in-cluster node. K3s single-node means only one node CIDR is ever allocated, so collision is unlikely — but documenting the reserved range in comments is sufficient.

- [ ] **Step 1.2: Upgrade Cilium**

  ```bash
  cd k8s/helm
  just deploy-cilium
  ```

  Expected: `helm upgrade` exits 0. Cilium pods restart; node stays `Ready`.

  ```bash
  kubectl --context k3s-homelab get pods -n kube-system -l k8s-app=cilium
  ```

  Expected: all pods `Running`.

- [ ] **Step 1.3: Verify external workloads CRD exists**

  ```bash
  kubectl --context k3s-homelab get crd ciliumexternalworkloads.cilium.io
  ```

  Expected: CRD present.

- [ ] **Step 1.4: Commit**

  ```bash
  git add k8s/helm/values/cilium-values.yaml
  git commit -m "feat: enable Cilium external workloads for NAS integration"
  ```

---

### Task 2: Create the CiliumExternalWorkload Manifest

**File:** `k8s/helm/manifests/nas-external-workload.yaml` (new)

- [ ] **Step 2.1: Write the manifest**

  ```yaml
  # CiliumExternalWorkload: registers the Debian NAS as a Cilium-managed endpoint.
  # The NAS gets Cilium identity 10.42.200.1 and can be targeted by NetworkPolicy.
  apiVersion: cilium.io/v2alpha1
  kind: CiliumExternalWorkload
  metadata:
    name: nas
    labels:
      app: nas
      role: storage
  spec:
    # IPv4AllocCIDR is the /32 (or small subnet) assigned to this workload.
    # The Cilium agent on the NAS will configure this as its identity address.
    ipv4AllocCIDR: "10.42.200.1/32"
  ```

- [ ] **Step 2.2: Apply manually to verify the CR is accepted**

  ```bash
  kubectl --context k3s-homelab apply -f k8s/helm/manifests/nas-external-workload.yaml
  kubectl --context k3s-homelab get ciliumexternalworkload nas -o yaml
  ```

  Expected: CR created, `status` block appears (may be empty until the agent connects).

- [ ] **Step 2.3: Add the file to the ArgoCD personal-services include list**

  Edit `argocd/applications/personal-services.yaml` — find the `include` field and add:

  ```yaml
  - manifests/nas-external-workload.yaml
  ```

  Then re-apply the Application object (ArgoCD does not manage Application definitions themselves):

  ```bash
  kubectl apply -f argocd/applications/personal-services.yaml
  cd k8s/helm && just argocd-sync
  ```

- [ ] **Step 2.4: Commit**

  ```bash
  git add k8s/helm/manifests/nas-external-workload.yaml argocd/applications/personal-services.yaml
  git commit -m "feat: add CiliumExternalWorkload CR for NAS"
  ```

- [ ] **Step 2.5: Push and verify ArgoCD sync**

  ```bash
  git push
  cd k8s/helm && just argocd-status
  ```

  Expected: `personal-services` app shows `Synced` / `Healthy`.

---

## Phase 2: NAS-Side Installation

These steps run on the Debian NAS (`192.168.50.106`). SSH as root: `ssh -i ~/.ssh/vgio root@192.168.50.106`.

---

### Task 3: Prepare the NAS Host

- [ ] **Step 3.1: Open VXLAN port on the NAS firewall**

  If the NAS runs `nftables` or `iptables`:

  ```bash
  # Check active firewall
  ssh -i ~/.ssh/vgio root@192.168.50.106 'iptables -L INPUT -n --line-numbers | head -20'
  ```

  If a firewall is active, add the rule (iptables example):

  ```bash
  ssh -i ~/.ssh/vgio root@192.168.50.106 \
    'iptables -I INPUT -p udp --dport 8472 -s 192.168.50.0/24 -j ACCEPT'
  ```

  Persist it for the distro's mechanism (e.g. `iptables-save > /etc/iptables/rules.v4`).

- [ ] **Step 3.2: Confirm kernel BPF support**

  ```bash
  ssh -i ~/.ssh/vgio root@192.168.50.106 \
    'uname -r && ls /sys/fs/bpf 2>/dev/null && echo "bpf ok"'
  ```

  Expected: kernel ≥ 4.19 and `bpf ok`. Debian 11/12 both satisfy this.

- [ ] **Step 3.3: Mount BPF filesystem if not already mounted**

  ```bash
  ssh -i ~/.ssh/vgio root@192.168.50.106 \
    'mount | grep bpf || (mount bpffs /sys/fs/bpf -t bpf && echo "mounted")'
  ```

  Add to `/etc/fstab` for persistence:

  ```
  bpffs  /sys/fs/bpf  bpf  defaults  0 0
  ```

---

### Task 4: Generate the Cilium Install Script for the NAS

Cilium provides a `cilium external-workloads install` command that generates a shell script configured for this specific cluster.

- [ ] **Step 4.1: Generate the install script**

  From your workstation:

  ```bash
  cilium external-workloads install \
    --id nas \
    --cidr 10.42.200.1/32 \
    > /tmp/cilium-install-nas.sh
  chmod +x /tmp/cilium-install-nas.sh
  ```

  Inspect the script before running it on the NAS:

  ```bash
  head -60 /tmp/cilium-install-nas.sh
  ```

  The script will:
  - Download the correct Cilium version's agent binary (matching the cluster version)
  - Create a systemd unit `cilium-external-workload`
  - Write a config that points back to the homelab cluster API

- [ ] **Step 4.2: Copy the script to the NAS**

  ```bash
  scp -i ~/.ssh/vgio /tmp/cilium-install-nas.sh root@192.168.50.106:/tmp/
  ```

- [ ] **Step 4.3: Run the install script on the NAS**

  ```bash
  ssh -i ~/.ssh/vgio root@192.168.50.106 'bash /tmp/cilium-install-nas.sh'
  ```

  Expected: Cilium agent installed, `cilium-external-workload.service` started.

- [ ] **Step 4.4: Check the Cilium agent status on the NAS**

  ```bash
  ssh -i ~/.ssh/vgio root@192.168.50.106 \
    'systemctl status cilium-external-workload && cilium status'
  ```

  Expected: `active (running)`, status shows `OK`.

---

## Phase 3: Verification

### Task 5: Confirm the NAS Appears in the Cluster

- [ ] **Step 5.1: Check CiliumNode is created**

  ```bash
  kubectl --context k3s-homelab get ciliumnode nas
  ```

  Expected: `nas` node present with `10.42.200.1` in its IPAM allocations.

- [ ] **Step 5.2: Check CiliumExternalWorkload status**

  ```bash
  kubectl --context k3s-homelab get ciliumexternalworkload nas -o jsonpath='{.status}'
  ```

  Expected: `id` field populated (the Cilium numeric identity assigned to the NAS).

- [ ] **Step 5.3: Ping the NAS Cilium IP from a pod**

  ```bash
  kubectl --context k3s-homelab run ping-test --rm -it --image=busybox -- ping -c 3 10.42.200.1
  ```

  Expected: 3 packets received, latency < 5ms (LAN).

- [ ] **Step 5.4: Ping the homelab node Cilium IP from the NAS**

  ```bash
  ssh -i ~/.ssh/vgio root@192.168.50.106 'ping -c 3 10.42.0.0'
  ```

  Expected: replies received (the K3s node's Pod CIDR gateway).

- [ ] **Step 5.5: Verify DNS resolution works from the NAS**

  ```bash
  ssh -i ~/.ssh/vgio root@192.168.50.106 \
    'dig @10.43.0.10 kubernetes.default.svc.cluster.local +short'
  ```

  Expected: `10.43.0.1` (or the cluster's kubernetes Service IP).

  > Note: `10.43.0.10` is the default kube-dns ClusterIP for K3s. Confirm with:
  > `kubectl --context k3s-homelab get svc -n kube-system kube-dns`

---

## Phase 4: Optional — Network Policy for NFS

Once the NAS is a managed workload, you can restrict which pods can reach NFS.

- [ ] **Step 6.1: Add a CiliumNetworkPolicy to the NAS external workload manifest**

  Append to `k8s/helm/manifests/nas-external-workload.yaml`:

  ```yaml
  ---
  # Allow only pods in personal-services and rss-system to reach NFS (2049/tcp)
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata:
    name: nas-nfs-access
    namespace: personal-services
  spec:
    endpointSelector:
      matchLabels:
        role: storage
    ingress:
      - fromEndpoints:
          - matchLabels:
              io.kubernetes.pod.namespace: personal-services
          - matchLabels:
              io.kubernetes.pod.namespace: kopia
        toPorts:
          - ports:
              - port: "2049"
                protocol: TCP
  ```

  > Note: `endpointSelector` here targets the NAS identity. Adjust `fromEndpoints` namespaces to match actual NFS consumers.

- [ ] **Step 6.2: Apply and verify policy**

  ```bash
  kubectl --context k3s-homelab apply -f k8s/helm/manifests/nas-external-workload.yaml
  kubectl --context k3s-homelab get ciliumnetworkpolicy -A
  ```

- [ ] **Step 6.3: Commit**

  ```bash
  git add k8s/helm/manifests/nas-external-workload.yaml
  git commit -m "feat: add NFS CiliumNetworkPolicy for NAS external workload"
  git push
  ```

---

## Files Changed Summary

| Action | File |
|--------|------|
| MODIFY | `k8s/helm/values/cilium-values.yaml` |
| CREATE | `k8s/helm/manifests/nas-external-workload.yaml` |
| MODIFY | `argocd/applications/personal-services.yaml` |

## Rollback

If the NAS agent destabilises the cluster network:

```bash
# 1. Stop Cilium on the NAS
ssh -i ~/.ssh/vgio root@192.168.50.106 'systemctl stop cilium-external-workload'

# 2. Delete the CiliumExternalWorkload (cluster will forget the NAS identity)
kubectl --context k3s-homelab delete ciliumexternalworkload nas

# 3. Remove the manifest from ArgoCD include list and re-apply
# (edit argocd/applications/personal-services.yaml, then:)
kubectl apply -f argocd/applications/personal-services.yaml
cd k8s/helm && just argocd-sync
```

The homelab Cilium dataplane is unaffected — only the NAS loses its Cilium identity. All existing in-cluster traffic continues normally.

## References

- Cilium External Workloads: https://docs.cilium.io/en/stable/network/external-workloads/
- Prior Cilium install plan: `docs/plans/2026-03-06-cilium-mesh-installation.md`
- NAS NFS server: `192.168.50.106:/export`
