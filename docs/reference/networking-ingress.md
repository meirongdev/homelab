# Networking & Ingress — 入口链路与 DNS 自动化

> Last updated: 2026-08-03
> Status: 生效事实
>
> 南北向入口（Cloudflare → Cilium Gateway）与 DNS 自动化（external-dns）。
> **跨集群**网络（Tailscale underlay + ClusterMesh）在 [tailscale-network.md](tailscale-network.md)；
> 隧道能观测到什么见 [cloudflare-tunnel-observability.md](cloudflare-tunnel-observability.md)。

## 外部流量链

```
Internet → Cloudflare DNS → Cloudflare Tunnel(cloudflared) → Cilium Gateway API → Service
```

集群**零公网入站端口**；WAF/限流等边缘安全见 [security.md §2](security.md)。

- **cloudflared**: `cloudflare` ns 的 pod，转发到 Cilium 托管的 Gateway service
  （`cilium-gateway-<gateway-name>.kube-system.svc:80`）。
  ⚠️ oracle-k3s 侧必须 `--protocol http2`（Oracle Cloud NSG 拦出站 UDP/QUIC）。
- **Ingress**: Cilium Gateway API 是集群内唯一 HTTP 入口。

## Cilium（CNI + Gateway 控制器）

- 双集群 Cilium（eBPF + VXLAN）；homelab 2026-03-06 部署，oracle 2026-03-07 从 Flannel 迁入。
- **homelab Cilium 是 Helm 手动管理，不走 ArgoCD**: `just deploy-cilium`（`k8s/helm/`），
  values 固化在 `k8s/cilium/values.yaml`（+ 同目录 README），pin **v1.19.1**。
  该配方会 pin `--version 1.19.1` 并恢复 live `cilium-ca`（fresh install 会自签，装完要重跑
  `just connect-clustermesh …`）。oracle 侧 values 在 `cloud/oracle/values/cilium-values.yaml`
  （`cd cloud/oracle && just deploy-cilium`）。
- **⚠️ `gatewayAPI.enableAppProtocol: true` 是两集群硬前提**: 没有它，ZITADEL console 的
  v1 gRPC 过网关 404（Envoy grpc_web filter 把转换后的原生 gRPC 用 HTTP/1.1 发给需要 h2c 的
  后端；尊重 Service `appProtocol` 才给 `zitadel:8080` 显式 h2c upstream）。
  记录: [../records/2026-06-07-zitadel-console-grpc-404.md](../records/2026-06-07-zitadel-console-grpc-404.md)。

## Gateway API 布局与 HTTPRoute 约定

- **homelab**: `k8s/helm/manifests/gateway/`（ArgoCD `gateway` App）——`gateway.yaml` =
  GatewayClass + Gateway 本体；每条对外路由一个 `route-<service>.yaml`（ReferenceGrant +
  HTTPRoute 成对）。**新子域名 = 新建一个 `route-*.yaml`**。parentRef
  `homelab-gateway`/`kube-system`/**8000**。
- **oracle-k3s**: HTTPRoute 与服务写在同一个 manifest 文件里
  （`cloud/oracle/manifests/personal-services/<service>.yaml`），parentRef
  `oracle-gateway`/`kube-system`/**80**。
- **跨 ns 引用必须有目标 ns 里的 ReferenceGrant，且 apiVersion 写 `v1beta1`** ——
  声明成 `v1` 会让整个 App `ComparisonError`（CI H3 拦截）。
- **HTTPRoute 模板纪律**: `parentRefs` 写全 `group`/`kind`，`backendRefs` 写全
  `group`/`kind`/`weight` —— 否则 Gateway controller 补默认值导致 ArgoCD 永久 OutOfSync。

## DNS 自动化（external-dns）

**净效果：新增子域名只需要写一个 HTTPRoute** —— DNS 记录自动建、通配隧道路由自动转发，
`cloudflare/terraform` 不需要任何改动（✅ 2026-07-20 两集群全量完成：15 条既有记录零停机
移交，两条隧道都改成单条 `*.meirong.dev` 通配路由）。采纳理由与迁移过程见
[../decisions/external-dns-adoption.md](../decisions/external-dns-adoption.md)。

- **实例**: 两个 ArgoCD App——homelab `external-dns` + oracle `external-dns-oracle`
  （chart 1.21.1 多源 + `$values`；homelab 实例同时管 `manifests/external-dns/` 的 ExternalSecret）。
  ⚠️ oracle 侧必须带 `helm.releaseName: external-dns`（Application 名 ≠ release 名的坑，见
  [argocd-app-patterns.md](argocd-app-patterns.md)）。
- **配置**: `sources: [gateway-httproute]`、`provider: cloudflare`、`domainFilters: [meirong.dev]`、
  `policy: upsert-only`（永不删除，安全默认）+ `registry: txt`（owner id `homelab-externaldns` /
  `oracle-externaldns`，两实例独立）。两集群 Gateway 都打了
  `external-dns.alpha.kubernetes.io/target` 注解指向各自 tunnel CNAME（Cilium NodePort Gateway
  没有可读的 LB 地址）。
- ⚠️ **`upsert-only` 意味着删 HTTPRoute 不删 DNS 记录** —— 退役服务要手工清 CNAME + ownership TXT。
- **Cloudflare token**: 两集群共用同一把 Zone 级 API Token（Vault `secret/homelab/external-dns` → ESO）。
  ⚠️ `cloudflare/terraform/` 这个 root 的有效 token 在 gitignored 的 `.env` 里，由 justfile
  （`set dotenv-load`）经 `-var` 注入——**必须用 `just plan`/`just apply`**，裸跑 `terraform plan`
  会读到 `terraform.tfvars` 里留存的无效值而报错（2026-07-19 曾误判为"token 失效"）。

## 节点地址速查

| 主机 | LAN | Tailscale |
|------|-----|-----------|
| homelab K8s node | `10.10.10.10` | `100.94.186.7` |
| Proxmox host (`pve`，跑 k8s-node VM 的 5600H 笔记本) | `192.168.50.4` | `100.118.193.51` |
| oracle-k3s node | `10.0.0.26` | `100.107.166.37` |
| storage-106 | `192.168.50.106` | `100.110.27.111` |

Pod CIDR: homelab `10.42.0.0/16`、oracle `10.52.0.0/16`（Tailscale 只路由 Pod CIDR；
ClusterMesh 连接命令与验证见 [tailscale-network.md](tailscale-network.md)）。
