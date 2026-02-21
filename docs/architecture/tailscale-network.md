# Tailscale 跨集群网络架构

## 概述

通过 Tailscale 子网路由实现两个 K3s 集群的 Pod/Service 互访，无需修改应用代码。

## CIDR 分配

| 集群 | Pod CIDR | Service CIDR | 节点 IP |
|------|----------|--------------|---------|
| Homelab K3s | 10.42.0.0/16 | 10.43.0.0/16 | 10.10.10.10 |
| Oracle K3s | 10.52.0.0/16 | 10.53.0.0/16 | 10.0.0.26（内网） |

> Oracle K3s 使用非默认 CIDR（`10.52/10.53`）以避免与 Homelab 冲突。
> 这在 Ansible playbook `cloud/oracle/ansible/playbooks/setup-k3s.yaml` 中通过 `/etc/rancher/k3s/config.yaml` 配置。

## Tailscale 标签

| 标签 | 节点 | 自动批准子网路由 |
|------|------|----------------|
| `tag:homelab` | 10.10.10.10 | 10.42.0.0/16, 10.43.0.0/16 |
| `tag:oracle` | Oracle 节点 | 10.52.0.0/16, 10.53.0.0/16 |

## 数据流

```
[Oracle Pod 10.52.x.x]
        │
        ▼
[Oracle K3s 节点] ──tailscale subnet router──▶ tailnet (100.x.x.x)
                                                       │
                                               ◀───────┘
[Homelab K3s 节点] ◀──tailscale subnet router──
        │
        ▼
[Homelab Pod 10.42.x.x]
```

## 文件清单

### Terraform（`tailscale/terraform/`）

| 文件 | 作用 |
|------|------|
| `provider.tf` | Tailscale provider，OAuth 认证 |
| `main.tf` | ACL 定义 + pre-auth key 资源 |
| `variables.tf` | OAuth Client ID/Secret 变量 |
| `outputs.tf` | homelab/oracle pre-auth key 输出（sensitive） |
| `justfile` | `init / plan / apply / homelab-authkey / oracle-authkey` |
| `.env.example` | 环境变量模板 |

### Ansible 安装 playbooks

| 文件 | 节点 | 广播路由 |
|------|------|---------|
| `k8s/ansible/playbooks/setup-tailscale.yaml` | Homelab | 10.42/10.43 |
| `cloud/oracle/ansible/playbooks/setup-tailscale.yaml` | Oracle | 10.52/10.53 |

## 认证流程

1. 在 [Tailscale Admin Console](https://login.tailscale.com/admin/settings/oauth) 创建 OAuth Client（scope: `auth_keys:write`, `acl:write`）
2. 将凭据存入 Vault：
   ```bash
   kubectl exec -n vault vault-0 -- sh -c "
     VAULT_TOKEN=\$ROOT_TOKEN vault kv put secret/homelab/tailscale \
       oauth_client_id=<id> \
       oauth_client_secret=<secret>
   "
   ```
3. 创建 `tailscale/terraform/.env`（gitignored）：
   ```
   TAILSCALE_OAUTH_CLIENT_ID=<id>
   TAILSCALE_OAUTH_CLIENT_SECRET=<secret>
   ```
4. 运行 Terraform 生成 pre-auth keys
5. 运行 Ansible 在两节点安装 Tailscale

## 运行命令

### 初始设置（完整流程）

```bash
# 1. 重装 Oracle K3s（新 CIDR）
cd cloud/oracle/ansible
just cleanup-k3s
just setup-k3s

# 2. 生成 pre-auth keys
cd tailscale/terraform
just init
just apply

# 3. 安装 Tailscale — homelab 节点
cd k8s/ansible
just setup-tailscale $(cd ../../tailscale/terraform && just homelab-authkey)

# 4. 安装 Tailscale — Oracle 节点
cd cloud/oracle/ansible
just setup-tailscale $(cd ../../../tailscale/terraform && just oracle-authkey)
```

### 验证

```bash
# 在任一节点上运行
tailscale status

# 检查路由已广播
tailscale status --json | jq '.Peer[] | {name: .HostName, routes: .AllowedIPs}'

# 跨集群 Pod 连通性测试
kubectl run test --image=busybox --rm -it -- ping 10.52.0.x   # homelab → oracle
kubectl run test --image=busybox --rm -it -- ping 10.42.0.x   # oracle → homelab
```

## Pre-auth Key 续期

Key 有效期 90 天。到期后：

```bash
# 重新生成 keys
cd tailscale/terraform
just apply

# 重新加入 tailnet（节点不会断线，但 key 需要更新）
cd k8s/ansible
just setup-tailscale $(cd ../../tailscale/terraform && just homelab-authkey)

cd cloud/oracle/ansible
just setup-tailscale $(cd ../../../tailscale/terraform && just oracle-authkey)
```
