# Oracle K3s Cluster

> Last updated: 2026-09-02
>
> 本文只讲**这个目录里有什么、怎么跑**。架构事实不在这里：集群角色与对比见
> [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md)，服务清单见
> [docs/reference/services.md](../../docs/reference/services.md)，网络与防火墙见
> [docs/reference/tailscale-network.md](../../docs/reference/tailscale-network.md)。

Oracle Cloud Free Tier 上的单节点 K3s（Ampere A1，arm64；shape 见 ARCHITECTURE），CNI 是 Cilium，
承载公网服务、ArgoCD 控制面、Loki/Tempo 与 ZITADEL。

## 目录

```
cloud/oracle/
├── ansible/        # 节点预配：K3s、Tailscale、firewalld（playbooks/ + inventory/）
├── bootstrap/      # argocd-manager.yaml：ArgoCD 纳管前必须先存在的 RBAC，手工 apply 一次，刻意不进 GitOps
├── cloudflare/     # 本集群的 Cloudflare Tunnel terraform（与 homelab 那份独立；DNS 记录不在这里，见下）
├── manifests/      # ArgoCD `oracle-k3s` App 同步的 kustomize 树。⚠️ 新文件必须登记进 kustomization.yaml
│   ├── base/               # gateway、cloudflared、ClusterSecretStore、CoreDNS 扩展、PriorityClass、external-dns 的 ns 与密钥
│   ├── argocd/             # 控制面的 ns、ESO 凭据、路由（ArgoCD 本体是 manual-helm，见 k8s/helm/justfile）
│   ├── calibre-metadata/   # 独立 ArgoCD App（需要专门的 ignoreDifferences），不在整树里
│   ├── databases/          # CNPG 共享实例 apps-pg
│   ├── falco/ monitoring/ opencost/   # ns + 密钥 + 配置；工作负载由各自的 Helm App 部署
│   ├── homepage/ rss-system/ uptime-kuma/ zitadel/
│   ├── personal-services/  # 个人服务（清单即真相源，名单见 services.md）
│   └── kustomization.yaml
├── terraform/      # OCI 基础设施（VCN、实例）。全仓库唯一用 make 的 terraform root
├── values/         # manual-helm 的 values：cilium-values.yaml、external-secrets-values.yaml
├── justfile        # 节点 / CNI / bootstrap / 巡检。日常部署不走这里
└── .env.example    # VAULT_TOKEN（`just create-vault-token` 用）
```

## 部署方式（先读这段再动手）

**日常一律 GitOps**：改 `manifests/` → `git push` → ArgoCD 3 分钟内同步。不要 `kubectl apply`
覆盖已纳管资源，selfHeal 会拉回。两个例外：

- **manual-helm**：Cilium（`just deploy-cilium`）与 ESO（`just install-eso`），改 `values/` 后要手动跑；
  ArgoCD 本体在 `k8s/helm/justfile` 的 `deploy-argocd`。改 values 不等于部署。
- **bootstrap**：全新重建时 ArgoCD 还不存在，`just bootstrap` 会 apply 一次整树把入口链路拉起来，
  之后交给 ArgoCD。完整步骤与不入 git 的前置依赖见
  [docs/runbooks/oracle-k3s-rebuild.md](../../docs/runbooks/oracle-k3s-rebuild.md)。

## 常用命令

```bash
cd cloud/oracle
just verify-node        # 重启 / 改 shape 后：只读核全部不变量（条数动态，别写死）
just check-node-drift   # ansible --check：配置有没有漂移
just cilium-status
just clustermesh-status
just status             # pods / svc / externalsecret / httproute / gateway 一览
just psa-check          # 跑着 Pod 却没 PSA enforce 标签的 ns
just logs <deploy> [ns] # 默认 ns rss-system
```

## 加子域名

在对应的 `manifests/<app>/` 目录写一条 HTTPRoute（并登记进 `kustomization.yaml`），push 即可：
DNS 记录由 external-dns 自动创建，隧道是 `*.meirong.dev` 通配路由。**不要改 `cloudflare/` 的
terraform**。机制见 [docs/reference/networking-ingress.md](../../docs/reference/networking-ingress.md)。

## 网络备忘（只放指针）

- firewalld / nftables 与 Tailscale、Pod CIDR 不再跨集群广播：
  [docs/reference/tailscale-network.md](../../docs/reference/tailscale-network.md)
- DNS：OCI 私有域交给 OCI 解析器、上游走 systemd-resolved 的 `DNS=`，
  见 `manifests/base/coredns-custom.yaml` 文件头与
  [docs/records/2026-08-01-oracle-k3s-dns-outage.md](../../docs/records/2026-08-01-oracle-k3s-dns-outage.md)
- cloudflared 钉 `--protocol http2`（本节点出向 UDP/QUIC 实测不通）：`manifests/base/cloudflare-tunnel.yaml`
- ClusterMesh 重建任一集群后要重连：
  `just connect-clustermesh <homelab-ts>:32379 <oracle-ts>:32379`，判据是 `cilium status` 的
  `remote configuration: retrieved=true`
