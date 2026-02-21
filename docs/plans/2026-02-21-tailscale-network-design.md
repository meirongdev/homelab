# Tailscale 跨集群网络互通设计文档

**日期**: 2026-02-21
**状态**: 实施中

## 背景

homelab 当前有两个独立 K3s 集群：

| 集群 | 节点 IP | 用途 |
|------|---------|------|
| Homelab K3s | 10.10.10.10 | 主集群，运行 personal services |
| Oracle Cloud K3s | 152.69.195.151 | Oracle ARM 免费实例，计划扩展 |

两集群之间只有 Cloudflare Tunnel（外部流量）和公网 SSH，没有私有网络互通。

## 目标

通过 Tailscale 实现：
1. 两集群 Pod/Service IP 互访（子网路由）
2. 节点间私有网络通信
3. Terraform 声明式管理 Tailscale 配置（ACL、pre-auth keys）

## 关键设计决策

### CIDR 冲突解决

两集群原本使用相同默认 CIDR（K3s 默认），导致路由冲突：
- Pod CIDR: 10.42.0.0/16
- Service CIDR: 10.43.0.0/16

**决策**: 修改 Oracle K3s 使用不同 CIDR（重装集群，因为无有状态负载）：

| 集群 | Pod CIDR | Service CIDR | Node IP |
|------|----------|--------------|---------|
| Homelab | 10.42.0.0/16 | 10.43.0.0/16 | 10.10.10.10 |
| Oracle | 10.52.0.0/16（新） | 10.53.0.0/16（新） | 10.0.0.26（内网） |

### 安装方式

**决策**: 节点级 tailscale daemon（非 Kubernetes Operator）

**原因**:
- 更简单，不依赖 K8s 控制器
- 子网路由在节点层面实现，对所有 Pod 透明
- Operator 适合需要 sidecar proxy 的场景

### 认证管理

**决策**: Tailscale OAuth Client 存入 Vault，pre-auth key 通过 Terraform 生成

流程：
1. 用户在 Tailscale Admin Console 创建 OAuth Client
2. OAuth Client 存入 Vault (`secret/homelab/tailscale`)
3. Terraform 读取 OAuth Client → 生成 pre-auth keys（带 tag）
4. Ansible 使用 pre-auth key 加入 tailnet

### Terraform 管理范围

- **Tailscale ACL**: 定义 tag 权限和子网路由自动批准
- **Pre-auth Keys**: 每个节点独立 key，带 tag，90天有效期
- **不管理**: tailscale daemon 安装（由 Ansible 负责）

## 网络数据流

```
[Oracle Pod 10.52.x.x]
        ↓
[Oracle K3s Node] → tailscale subnet router → tailnet
                                                 ↓
[Homelab K3s Node] ← tailscale subnet router ←─┘
        ↓
[Homelab Pod 10.42.x.x]
```

## 实施步骤

1. 修改 Oracle K3s Ansible playbook，加入显式 CIDR
2. 重装 Oracle K3s（用户手动执行）
3. 创建 Tailscale Terraform 模块
4. 存储 OAuth Client 到 Vault（用户手动）
5. 运行 `just apply`（用户手动）
6. Ansible 安装 tailscale daemon（用户手动）

## 验证方案

```bash
# 1. 检查两节点已加入 tailnet
tailscale status

# 2. 验证子网路由已广播并自动批准
tailscale status --json | jq '.Peer[] | {name: .HostName, routes: .AllowedIPs}'

# 3. 从 homelab Pod ping Oracle Pod IP
kubectl run test --image=busybox --rm -it -- ping 10.52.x.x

# 4. 从 Oracle Pod ping homelab Pod IP
kubectl run test --image=busybox --rm -it -- ping 10.42.x.x
```

## 文件清单

### 新建
- `tailscale/terraform/provider.tf`
- `tailscale/terraform/main.tf`
- `tailscale/terraform/variables.tf`
- `tailscale/terraform/outputs.tf`
- `tailscale/terraform/terraform.tfvars.example`
- `tailscale/terraform/.env.example`
- `tailscale/terraform/justfile`
- `cloud/oracle/ansible/playbooks/setup-tailscale.yaml`
- `k8s/ansible/playbooks/setup-tailscale.yaml`
- `docs/architecture/tailscale-network.md`

### 修改
- `cloud/oracle/ansible/playbooks/setup-k3s.yaml` — 加入显式 CIDR
- `cloud/oracle/ansible/justfile` — 新增 setup-tailscale target
- `k8s/ansible/justfile` — 新增 setup-tailscale target
- `docs/architecture/TODO.md` — 更新 Phase 3 状态

## 注意事项

- Oracle K3s 重装会删除所有 K8s 资源，但当前无有状态负载，可以安全重装
- Tailscale pre-auth key 90天有效期，到期后需要通过 Terraform 重新生成并重新运行 Ansible
- `tailscale_tailnet_key` 资源的 key 值在 `terraform apply` 后立即有效，在 `terraform output` 中标记为 sensitive
