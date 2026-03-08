# Homelab Rebuild on Ubuntu 24.04 LTS

## Goal

Rebuild the single-node homelab VM on Proxmox with Ubuntu 24.04 LTS, reinstall K3s, and restore a stable baseline before resuming the Cilium Gateway / ClusterMesh rollout.

## When to Use

Use this runbook when the homelab node becomes unstable after Cilium datapath changes, especially if `dmesg` shows a `cilium-agent` BPF verifier bug on a development kernel.

## Expected Outcome

At the end of this runbook:

- Proxmox VM `k8s-node` is recreated from the Ubuntu 24.04 LTS cloud image.
- `k3s-homelab` is reachable again.
- Cilium is reinstalled in conservative mode on homelab.
- The node is stable enough to continue with `cilium-gateway-cutover.md` later.

## Important Notes

- Stateful application data stored on the NFS backend is not deleted by recreating the VM itself.
- This does destroy the homelab cluster control plane and all in-cluster resources on the VM.
- The repo's active Proxmox task runner is `proxmox/terraform/justfile`. The historical `Makefile` is currently empty.
- Homelab no longer relies on `ufw`; Cilium owns the datapath and the node should keep host firewalling disabled to avoid reboot-time loss of SSH / kube-apiserver reachability.
- `qemu-guest-agent` is part of the homelab baseline so Proxmox can inspect the guest even when SSH is unavailable.
- Homelab Cilium values are intentionally rolled back in `k8s/helm/values/cilium-values.yaml`:
  - `kubeProxyReplacement: false`
  - `gatewayAPI.enabled: false`

## Phase 0: Preflight

Run from the repo root:

```bash
cd /Users/matthew/projects/homelab
kubectl config current-context || true
git status --short
```

Check the image target now points to Ubuntu 24.04 LTS:

```bash
cd /Users/matthew/projects/homelab/proxmox/terraform
grep cloud_image_id terraform.tfvars
```

Expected value:

```bash
cloud_image_id = "local:iso/ubuntu-24.04-cloudimg-amd64.img"
```

## Phase 1: Download the Ubuntu 24.04 Image

```bash
cd /Users/matthew/projects/homelab/proxmox/ansible
just download-cloud-image
```

This downloads:

```bash
/var/lib/vz/template/iso/ubuntu-24.04-cloudimg-amd64.img
```

## Phase 2: Destroy and Recreate the Proxmox VM

Destroy only the K3s VM:

```bash
cd /Users/matthew/projects/homelab/proxmox/terraform
just destroy-vm
```

Recreate it from the 24.04 image:

```bash
cd /Users/matthew/projects/homelab/proxmox/terraform
just apply-vm
```

If you prefer a full Terraform cycle instead:

```bash
cd /Users/matthew/projects/homelab/proxmox/terraform
just destroy
just apply
```

Validate the VM on Proxmox:

```bash
ssh -i ~/.ssh/vgio root@100.118.193.51 'qm status 100 && qm config 100 | sed -n "1,80p"'
```

## Phase 3: Reinstall K3s

Remove any stale local kubeconfig entries first:

```bash
cd /Users/matthew/projects/homelab/k8s/ansible
just remove-kubeconfig
```

Install K3s on the rebuilt VM:

```bash
cd /Users/matthew/projects/homelab/k8s/ansible
just setup-k8s
```

This also installs and enables `qemu-guest-agent`, and explicitly disables `ufw` on the node.

Fetch kubeconfig back to the local machine:

```bash
cd /Users/matthew/projects/homelab/k8s/ansible
just fetch-kubeconfig
```

Validate the cluster:

```bash
kubectl --context k3s-homelab get nodes -o wide
kubectl --context k3s-homelab get pods -A
```

## Phase 4: Reinstall Cilium in Conservative Mode

The homelab values file is already prepared to avoid the verifier bug on the unstable kernel combination.

Deploy Cilium:

```bash
cd /Users/matthew/projects/homelab/k8s/helm
just deploy-cilium
```

Validate Cilium:

```bash
cd /Users/matthew/projects/homelab/k8s/helm
just cilium-status
kubectl --context k3s-homelab -n kube-system get pods -l k8s-app=cilium
```

Confirm the problematic flags are disabled on homelab:

```bash
kubectl --context k3s-homelab -n kube-system exec ds/cilium -- cilium-dbg status --verbose | sed -n '1,30p'
```

Expected direction:

- `KubeProxyReplacement: False`
- No Gateway API programming on homelab yet

## Phase 5: Reinstall Homelab Platform Components

Once the node is stable, reinstall the base platform pieces in the usual order.

Examples:

```bash
cd /Users/matthew/projects/homelab/k8s/helm
just deploy-argocd
just deploy-cloudflare-tunnel
just deploy-prometheus
just deploy-loki
just deploy-tempo
```

Then verify critical namespaces:

```bash
kubectl --context k3s-homelab get pods -A
kubectl --context k3s-homelab get pvc -A
```

## Phase 6: Resume Gateway / ClusterMesh Work Later

Do not immediately re-enable Cilium Gateway API on homelab.

Only resume after the rebuilt node is stable on Ubuntu 24.04 LTS.

When ready:

1. Re-enable `kubeProxyReplacement` in `k8s/helm/values/cilium-values.yaml`
2. Re-deploy Cilium and validate node stability
3. Re-enable `gatewayAPI.enabled`
4. Resume `docs/runbooks/cilium-gateway-cutover.md`
5. Only after both clusters are stable, continue ClusterMesh connect steps

## Validation Checklist

```bash
kubectl --context k3s-homelab get nodes
kubectl --context k3s-homelab get pods -A
kubectl --context k3s-homelab -n kube-system get pods
kubectl --context k3s-homelab -n kube-system exec ds/cilium -- cilium-dbg status --brief
```

Success means:

- node is `Ready`
- no recurring `cilium-agent` crash loops
- kube-apiserver is stable over repeated checks
- no new verifier bug in `dmesg`

## Rollback

If the rebuilt node is still unstable:

1. Stay on Ubuntu 24.04 LTS
2. Keep homelab Cilium in conservative mode
3. Do not re-enable Gateway API or KPR yet
4. Capture fresh `dmesg` and `journalctl -u k3s -u tailscaled` output before any further changes

## Follow-up

After the rebuild succeeds, add a short timeline and root-cause note under `docs/plans/` describing:

- the verifier bug on the development kernel
- the move back to Ubuntu 24.04 LTS
- when Cilium Gateway / ClusterMesh was resumed
