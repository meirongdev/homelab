# Tailscale — 跨集群网络 + 远程访问

Tailscale 只做节点级 underlay：节点间直连（NodePort 上的 Vault / 监控 / ClusterMesh 控制面、ClusterMesh 的
VXLAN 外层包、restic→106；Pod CIDR 不通告），
以及无公网节点的远程访问。**集群内**数据面与网关是 Cilium（见 `k8s/cilium/`）。

## 目录

```
tailscale/
├── ansible/      # 各主机 Tailscale 安装 / 密钥 / 路由（roles）
└── terraform/    # Tailscale 账号侧：ACL 策略 + 预授权密钥（tag 管理）
```

## 快速上手

```bash
# 账号侧 ACL / 预授权密钥
cd tailscale/terraform && just init && just apply
```

## 详见

- 架构事实: [docs/reference/tailscale-network.md](../docs/reference/tailscale-network.md)（跨集群网络，最容易踩坑的一层）
- 集群互联: `cd k8s/helm && just connect-clustermesh <homelab-ts>:32379 <oracle-ts>:32379`
