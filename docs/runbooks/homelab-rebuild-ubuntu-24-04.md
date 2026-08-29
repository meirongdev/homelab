# Homelab Rebuild on Ubuntu 24.04 LTS

> **触发条件**：homelab 节点在 Cilium 数据面变更后不稳定，尤其 `dmesg` 出现开发内核上的
> `cilium-agent` BPF verifier bug（见 § When to Use）。
> **成功判定**：K3s 起来 + Cilium 健康 + Gateway 通，见 § Validation。
> **回滚**：本文本身就是恢复流程；Cilium 侧回退用 `just deploy-cilium` 重装。
>
> ⚠️ **Phase 4 不要照抄**：其中的保守模式（`kubeProxyReplacement: false`、`gatewayAPI.enabled: false`）
> 是当年为绕开那个 BPF bug 的临时手段。**标准配置是 `kubeProxyReplacement: true` + Cilium Gateway API**，
> 见 `k8s/cilium/README.md` 与 `just deploy-cilium`。
> Last updated: 2026-08-29

## Goal

Rebuild the homelab **control-plane** VM (`k8s-node`, on `pve`) with Ubuntu 24.04 LTS,
reinstall K3s, and restore a stable baseline before resuming the Cilium Gateway /
ClusterMesh rollout.

⚠️ **自 2026-08-13 homelab 是双节点**：本文只重建控制面。worker `k8s-worker-106`
（106 上的另一台 VM）不在本流程内 —— 它会在控制面消失期间变 `NotReady`，控制面回来后
用 `cd k8s/ansible && just join-worker` 重新入编（新集群 = 新 token，必须重跑）。
worker 上的 PVC（`navidrome-data-local` / `jellyfin-config-local`）**不随控制面重建丢失**。

## When to Use

Use this runbook when the homelab node becomes unstable after Cilium datapath changes, especially if `dmesg` shows a `cilium-agent` BPF verifier bug on a development kernel.

## Expected Outcome

At the end of this runbook:

- Proxmox VM `k8s-node` is recreated from the Ubuntu 24.04 LTS cloud image.
- `k3s-homelab` is reachable again.
- Cilium is reinstalled in conservative mode on homelab.
- The node is stable enough to continue with `cilium-gateway-cutover.md` later.

## Important Notes

- ☠️ **本条 2026-08-20 更正 —— 原文写的是"有状态数据在 NFS 后端上，重建 VM 不会删掉它"，
  那个前提已经在 2026-07-11 消失了。** 现在控制面上所有应用数据都在 **`local-path`**，
  也就是**这台 VM 自己的盘上**：重建 VM = 这些数据全没。控制面上现有 12 个 local-path PVC
  （vault raft、prometheus/alertmanager/grafana、open-notebook、jobs-sg、apps-pg（2026-08-25 起共享实例，含 litellm/multica 两个库）、
  multica ×2、trivy-server；清单见 [reference/storage.md](../reference/storage.md)）。
  **唯一安全网是 106 上的 restic 夜备** —— 开工前先确认仓库里有当天的新快照，恢复步骤见
  [backup-recovery.md](backup-recovery.md)。
  （`media` ns 的 5 个只读 NFS PV 确实不受影响，它们的真身在 106 的 ZFS 上；
  worker 上那 2 个 local-path PVC 也不受影响。）
- This does destroy the homelab cluster control plane and all in-cluster resources on the VM.
- The repo's active Proxmox task runner is `proxmox/terraform/justfile`.
- Homelab no longer relies on `ufw`; Cilium owns the datapath and the node should keep host firewalling disabled to avoid reboot-time loss of SSH / kube-apiserver reachability.
- `qemu-guest-agent` is part of the homelab baseline so Proxmox can inspect the guest even when SSH is unavailable.
- The Cilium config source of truth is `k8s/cilium/values.yaml` (applied by `just deploy-cilium`; see `k8s/cilium/README.md`). If the node is on an unstable kernel, temporarily run Cilium in conservative mode by setting in that file:
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

If the node is on an unstable kernel, first apply the conservative-mode settings above to `k8s/cilium/values.yaml` to avoid the verifier bug; otherwise deploy the standard config.

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
# 各 App 的 manifests（cloudflare/gateway/personal-services 等）由 ArgoCD 随 git push 同步，无需手动 kubectl apply
# LGTM 栈（kube-prometheus-stack/loki/tempo/sloth/otel-collector）由 ArgoCD 自动同步，无需手动 helm
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

1. Re-enable `kubeProxyReplacement` in `k8s/cilium/values.yaml`
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
