# Cilium Mesh Installation on Homelab K3s

## 背景

当前 homelab K3s 集群使用默认的 Flannel CNI + kube-proxy（iptables 模式）。Cilium 基于 eBPF 提供更高效的网络数据面、Network Policy 执行和 Hubble 可观测性。

本次变更将 Flannel 替换为 Cilium，保留 kube-proxy，启用 Hubble 可观测，并避免把跨集群认证链路绑定到私有 Service CIDR。

> [!CAUTION]
> 这是一个**破坏性变更**——需要重装 K3s（带新参数），然后重新部署所有工作负载。计划停机时间约 30-60 分钟。

## 当前架构

| 组件 | 当前状态 |
|------|---------|
| CNI | Flannel (VXLAN) |
| kube-proxy | iptables 模式 |
| Network Policy | K3s 内置 (kube-router) |
| Ingress | Traefik (K3s 内置, Gateway API) |
| Service LB | K3s ServiceLB (Klipper) |
| Pod CIDR | 10.42.0.0/16 |
| Service CIDR | 10.43.0.0/16 |
| 跨集群网络 | Tailscale 子网路由 (广播 10.42/10.43) |

## 目标架构

| 组件 | 变更后 |
|------|--------|
| CNI | **Cilium** (eBPF datapath) |
| kube-proxy | **K3s kube-proxy 保留** |
| Network Policy | **Cilium** (L3/L4/L7) |
| Ingress | **Traefik (保留)**，K3s 内置 |
| Service LB | **K3s ServiceLB (保留)** |
| Hubble | **启用** (可观测性 UI + Relay) |
| Pod CIDR | 10.42.0.0/16 (不变) |
| Service CIDR | 10.43.0.0/16 (不变) |
| 跨集群网络 | Tailscale 子网路由 (保留为 underlay；当前未启用 Cilium ClusterMesh) |

## 关键决策

### 1. 保留 Traefik

Cilium 自带 Gateway API 实现，但替换 Traefik 的工作量太大（SSO ForwardAuth Middleware 依赖 Traefik CRD）。本次**保留 Traefik** 作为 Ingress/Gateway。

### 2. 保留 K3s ServiceLB

单节点集群下 ServiceLB (Klipper) 足以满足 LoadBalancer Service 需求，不需要 Cilium 的 L2/BGP 方案。

### 3. 不禁用 Traefik

K3s 启动参数不加 `--disable traefik`，继续让 K3s 管理 Traefik 生命周期。

### 4. 不把跨集群认证链路绑定到 Service CIDR

虽然 homelab 已切到 Cilium，但当前没有启用跨集群 Cilium ClusterMesh。为了降低复杂度，homelab 的 Traefik ForwardAuth 不再直连 oracle-k3s 的 `oauth2-proxy` ClusterIP，而是统一走公开 `https://oauth.meirong.dev/`。这样可以减少对 Tailscale 静态路由和 oracle Service CIDR 的运行时依赖，也更符合 ArgoCD 的 GitOps 模式。

## 实施步骤

### Phase 1: 准备工作（本地）

#### 1.1 修改 K3s 安装 Playbook

**文件**: `k8s/ansible/playbooks/setup-k3s.yaml`

在 K3s config.yaml 中增加参数，禁用 Flannel、内置 Network Policy：

```yaml
# /etc/rancher/k3s/config.yaml 新增内容
flannel-backend: "none"
disable-network-policy: true
```

#### 1.2 更新防火墙规则

**文件**: `k8s/ansible/playbooks/setup-k3s.yaml`

Cilium 需要开放额外端口：
- **4240/tcp**: Cilium 健康检查
- **8472/udp**: VXLAN overlay (Cilium 默认 tunnel 模式)
- **4244/tcp**: Hubble Relay

#### 1.3 创建 Cilium Helm Values

**文件**: `k8s/helm/values/cilium-values.yaml`（新建）

```yaml
# Cilium values for homelab K3s
kubeProxyReplacement: false
routingMode: tunnel
tunnelProtocol: vxlan

ipam:
  operator:
    clusterPoolIPv4PodCIDRList:
      - "10.42.0.0/16"

operator:
  replicas: 1  # 单节点集群

hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true

# 保留 Traefik 的 Gateway API，不启用 Cilium 的
gatewayAPI:
  enabled: false

# 从 cgroup 挂载推断 (K3s 默认路径)
cgroup:
  autoMount:
    enabled: false
  hostRoot: /sys/fs/cgroup
```

#### 1.4 更新 Helm justfile

**文件**: `k8s/helm/justfile`

新增命令：
- `deploy-cilium`: 安装/升级 Cilium (Helm)
- `cilium-status`: 检查 Cilium 状态
- `hubble-ui`: 端口转发 Hubble UI

### Phase 2: 重建集群

> [!WARNING]
> 以下步骤会导致 homelab 集群所有服务短暂中断。

#### 2.1 卸载 K3s
```bash
cd k8s/ansible
just cleanup-k8s
```

#### 2.2 重装 K3s（带新参数）
```bash
just setup-k8s
just fetch-kubeconfig
```

确认 K3s 启动后节点处于 `NotReady` 状态（因为没有 CNI）。

#### 2.3 安装 Cilium
```bash
cd k8s/helm
just add-repos   # helm repo add cilium https://helm.cilium.io/
just deploy-cilium
```

等待节点变为 `Ready`，所有 Cilium Pod 运行正常。

### Phase 3: 重新部署工作负载

按依赖顺序恢复所有服务：

```bash
cd k8s/helm

# 1. 基础设施
just setup-nfs-provisioner
just deploy-vault
just vault-unseal
just deploy-eso
just setup-vault-eso

# 2. 核心网络
just deploy-gateway
just deploy-cloudflare-tunnel

# 3. 可观测性
just deploy-prometheus
just deploy-loki
just deploy-tempo
just deploy-otel-collector

# 4. ArgoCD (会自动同步其他服务)
just deploy-argocd
```

### Phase 4: 恢复 Tailscale 子网路由

确认 Tailscale 仍在运行并广播正确路由：
```bash
ssh root@10.10.10.10 tailscale status
ssh root@10.10.10.10 ip route show table 52
```

## 验证计划

### 自动化检查

```bash
# 1. Cilium 状态
kubectl --context k3s-homelab exec -n kube-system ds/cilium -- cilium status --brief

# 2. Cilium 联通性测试
kubectl --context k3s-homelab apply -f https://raw.githubusercontent.com/cilium/cilium/main/examples/kubernetes/connectivity-check/connectivity-check.yaml
# 等待所有 Pod Ready 后删除

# 3. 所有 Pod 运行状态
kubectl --context k3s-homelab get pods -A --field-selector='status.phase!=Running,status.phase!=Succeeded'

# 4. NFS PVC 绑定
kubectl --context k3s-homelab get pvc -A

# 5. ArgoCD 同步状态
just argocd-status

# 6. 断电恢复检查
just post-restart-check
```

### 手动验证

1. **外部访问**: 浏览器打开 `book.meirong.dev` / `grafana.meirong.dev` / `vault.meirong.dev` / `argocd.meirong.dev`，确认页面正常加载
2. **SSO 流程**: 访问受保护服务，确认跳转到 `auth.meirong.dev` 登录
3. **Hubble UI**: `kubectl port-forward -n kube-system svc/hubble-ui 12000:80`，浏览器打开 `http://localhost:12000`
4. **跨集群连通**: 从 homelab 节点 `ping 10.52.0.2`（Oracle CoreDNS Pod）
5. **Kopia CLI 连接**: `kopia repository connect server --url=https://10.10.10.10:31515 ...`

## 经验总结

- `kubeProxyReplacement: true` 在这套单节点 homelab 环境里曾导致宿主 SSH/网络异常，因此当前生产配置保留 kube-proxy。
- Cilium 已经简化了 homelab 集群内的数据面，但还没有替代跨集群 underlay；跨集群仍由 Tailscale 承担。
- 真正值得优先简化的是控制面依赖链。把 homelab 的 ForwardAuth 改为 `https://oauth.meirong.dev/` 后，认证不再依赖 oracle-k3s Service CIDR、静态路由和临时 ClusterIP。
- `gateway` Application 由 ArgoCD 自愈管理，因此这类修复必须先进 Git，再让 ArgoCD 同步，不能只 patch live 资源。

## 涉及文件清单

| 操作 | 文件 |
|------|------|
| MODIFY | `k8s/ansible/playbooks/setup-k3s.yaml` |
| NEW | `k8s/helm/values/cilium-values.yaml` |
| MODIFY | `k8s/helm/justfile` |
| NEW | `docs/plans/2026-03-06-cilium-mesh-installation.md` |

## 回滚方案

如果 Cilium 安装后出现严重问题：

```bash
# 1. 卸载 K3s
cd k8s/ansible && just cleanup-k8s

# 2. 还原 config.yaml（git checkout setup-k3s.yaml）
git checkout k8s/ansible/playbooks/setup-k3s.yaml

# 3. 重装 K3s（恢复 Flannel）
just setup-k8s && just fetch-kubeconfig

# 4. 重新部署工作负载（同 Phase 3）
```
