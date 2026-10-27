# Networking & Ingress — 入口链路与 DNS 自动化

> Last updated: 2026-10-28
> Status: 生效事实
>
> 南北向入口（Cloudflare → Cilium Gateway）与 DNS 自动化（external-dns）。
> **跨集群**网络（Tailscale underlay + ClusterMesh）在 [tailscale-network.md](tailscale-network.md)；
> 隧道能观测到什么见 [cloudflare-tunnel-observability.md](cloudflare-tunnel-observability.md)。

## 外部流量链

```
Internet → Cloudflare DNS → Cloudflare Tunnel(cloudflared) → Cilium Gateway API → Service
```

应用流量零公网入站（cloudflared 主动出站连边缘），但节点并非零入站端口：oracle 的 OCI
Security List 另有 3 条管理入站，见 [security.md §2](security.md)（WAF/限流也在那里）。

- **cloudflared**：`cloudflare` ns 的 pod，转发到 `cilium-gateway-<gateway-name>.kube-system.svc:80`。
  ⚠️ oracle-k3s 侧必须 `--protocol http2`（Oracle Cloud NSG 拦出站 UDP/QUIC）。
- Cilium Gateway API 是集群内唯一 HTTP 入口（不用 K8s `Ingress`）。

## Cilium（CNI + Gateway 控制器）

- 双集群 Cilium（eBPF + VXLAN），manual-helm，**不走 ArgoCD**：homelab `cd k8s/helm && just deploy-cilium`
  （values `k8s/cilium/values.yaml` + 同目录 README），oracle `cd cloud/oracle && just deploy-cilium`
  （values `cloud/oracle/values/cilium.yaml`）。版本 pin 在根 `versions.just` 的 `cilium_version`。
  homelab 配方会恢复 live `cilium-ca`；fresh install 会自签 CA，装完要重跑 `just connect-clustermesh …`。
- ☠️ **Gateway API CRD 与 Cilium 版本是一对**（`versions.just` 的 `gateway_api_version`，CI V3 查兼容表）。
  CRD 不齐时 Gateway API 控制器整个不初始化：旧路由照常 200，新路由静默 503。升 Cilium 必跑
  `just deploy-gateway-api-crds`（两个 justfile 各一份）。验收只认新建的 HTTPRoute 能拿到 `.status`；
  operator 日志里的 `Required GatewayAPI resources are not found` 是故障信号。
  [../records/2026-08-11-gateway-api-crd-stall.md](../records/2026-08-11-gateway-api-crd-stall.md)。
- ⚠️ **`gatewayAPI.enableAppProtocol: true` 是两集群硬前提**：没有它，ZITADEL console 的 v1 gRPC
  过网关 404（Envoy 要尊重 Service `appProtocol` 才给 `zitadel:8080` 用 h2c）。
  [../records/2026-06-07-zitadel-console-grpc-404.md](../records/2026-06-07-zitadel-console-grpc-404.md)。

## Gateway API 布局与 HTTPRoute 约定

- **homelab**：`k8s/helm/manifests/gateway/`（ArgoCD `gateway` App），`gateway.yaml` = GatewayClass +
  Gateway；**新子域名 = 新建一个 `route-<service>.yaml`**（`jobs-sg`、`media` 的路由写在服务清单里，
  是存量例外）。parentRef `homelab-gateway`/`kube-system`/**80**（不是 8000）。
- **oracle-k3s**：HTTPRoute 与服务写在同一个文件
  （`cloud/oracle/manifests/personal-services/<service>.yaml`），parentRef `oracle-gateway`/`kube-system`/80。
- ☠️ **HTTPRoute 与后端 Service 同 ns 时不需要 ReferenceGrant**。Gateway 接管别的 ns 的路由靠
  listener 上的 `allowedRoutes: {namespaces: {from: All}}`（两个 Gateway 都这么写）；ReferenceGrant
  只管**跨 ns 的 `backendRefs`**。判据（2026-09-06 实测）：`jobs-sg` / `litellm` / `media` / `zitadel`
  有线上路由却没有任何 grant，照常 200/302。仓库现存 grant 全是同 ns 的空操作，别当成新服务的必做
  步骤；真要收紧，改的是 `allowedRoutes`。
- **真跨 ns 引用时**，目标 ns 里必须有 ReferenceGrant，apiVersion 写 `v1beta1`：写 `v1` 会让整个 App
  `ComparisonError`（CI H3 拦截）。
- **模板纪律**：`parentRefs` 写全 `group`/`kind`，`backendRefs` 写全 `group`/`kind`/`weight`，
  否则 Gateway controller 补默认值，ArgoCD 永久 OutOfSync。
- **单个路径开小灶用 `Exact`，☠️ 不能用 `PathPrefix`**：规范规定 Exact 优先于任何 Prefix、与 rule
  顺序无关（原文在 HTTPRoute CRD 的 `rules.matches` description 里）；用 `PathPrefix: /` 给单个路径挂
  filter 会把全站吃进去。filter 是否支持查
  `kubectl --context <ctx> get gatewayclass <class> -o yaml` 的 `status.supportedFeatures`。
- ☠️ **被网关 filter 就地应答的路径，不能拿来当存活探针**：`RequestRedirect` 之类由 Envoy 直接返回，
  请求到不了 pod，后端死透也全绿。目前唯一的就地应答是 `multica.meirong.dev` 的 `/` 302 →
  `/homelab/issues`（[`route-multica.yaml`](../../k8s/helm/manifests/gateway/route-multica.yaml)），
  所以 Uptime Kuma 探 `/api/config`。`URLRewrite`（oracle 的 `scalar.yaml`）照常转到后端，不在此列。

## DNS 自动化（external-dns）

**新增子域名只需要写一个 HTTPRoute**：记录由 external-dns 建，隧道的单条 `*.meirong.dev` 通配路由
负责转发，`cloudflare/terraform` 不需要任何改动。采纳理由与迁移过程见
[../decisions/external-dns-adoption.md](../decisions/external-dns-adoption.md)。

- **实例**：两个 ArgoCD App，homelab `external-dns` + oracle `external-dns-oracle`（多源 + `$values`，
  chart 版本见 `argocd/applications/external-dns*.yaml`；homelab 实例同时管 `manifests/external-dns/`
  的 ExternalSecret）。⚠️ oracle 侧必须带 `helm.releaseName: external-dns`（见
  [argocd-app-patterns.md](argocd-app-patterns.md)）。
- **配置**（`k8s/helm/values/external-dns.yaml` / `cloud/oracle/values/external-dns.yaml`）：
  `sources: [gateway-httproute]`、`provider: cloudflare`、`domainFilters: [meirong.dev]`、
  `policy: upsert-only` + `registry: txt`（owner id `homelab-externaldns` / `oracle-externaldns`，必须不同）。
  Gateway 上的 `external-dns.alpha.kubernetes.io/target` 注解指向各自 tunnel CNAME（NodePort Gateway
  没有可读的 LB 地址）。
- ⚠️ **`upsert-only` 意味着删 HTTPRoute 不删 DNS 记录**，退役服务要手工清 CNAME + ownership TXT。
- **Cloudflare token**：两集群共用同一把 Zone 级 API Token（Vault `secret/homelab/external-dns` → ESO）。
  ⚠️ `cloudflare/terraform/` 的有效 token 在 gitignored 的 `.env`，由 justfile（`set dotenv-load`）经
  `-var` 注入，必须 `cd cloudflare/terraform && just plan`/`just apply`；裸跑 `terraform plan` 读到
  `terraform.tfvars` 里的无效值而报错，看着像 token 失效，其实不是。

## 不走这条链的 meirong.dev 主机名（集群外托管）

> 跨仓库那条（`stack.meirong.dev` 由 home-stack 自己的 terraform 拥有）的取舍与完整
> 归属表见 [decisions/home-stack-repo-boundary.md](../decisions/home-stack-repo-boundary.md)。

⚠️ **"写 HTTPRoute 即建 DNS" 只覆盖跑在集群里的服务**。集群外站点没有 HTTPRoute：external-dns
只读 `gateway-httproute`，通配隧道路由只对 CNAME 到隧道的主机名生效。这类记录**通常**要在
`cloudflare/terraform/main.tf` 的 `local.external_origin_dns` 显式声明（"加子域名别动那个模块"的例外，
步骤见 [cloudflare/terraform/README.md](../../cloudflare/terraform/README.md)）。Workers 自定义域名是
例外的例外：它自己建记录，不能写进那个 map。

| 主机名 | 托管 | 记录归属 | 代理 |
|--------|------|----------|------|
| `meirong.dev`（apex，博客） | Cloudflare Pages `meirongdevblog.pages.dev` | Cloudflare Pages 自建，不在 terraform state 里 | 橙云 |
| `playgrounds.meirong.dev` | GitHub Pages `meirongdev.github.io`（repo `meirongdev/playgrounds`） | `local.external_origin_dns` | DNS-only |
| `stack.meirong.dev` | Cloudflare Workers（repo `meirongdev/home-stack`，Rust→wasm SSR + 静态资源层） | home-stack 仓库的 terraform（`cloudflare_workers_custom_domain`），不在本仓库 state 里 | 橙云 |

- ⚠️ **GitHub Pages 必须 DNS-only（灰云）**：GitHub 用 HTTP-01 签自定义域证书，橙云 + 全区
  *Always Use HTTPS* 会把校验重定向到还没证书的 HTTPS 源，成死循环。Settings → Pages 显示证书已签发后
  才可按需改回 `proxied = true`。
- ⚠️ **DNS-only 的主机名完全绕过边缘**：WAF / 限流 / 缓存（[security.md §2](security.md)）对它都不生效。
- ⚠️ **DNS 通了 ≠ 站点通了**：Pages 用自定义 Actions workflow（`actions/deploy-pages`）发布时仓库里的
  `CNAME` 文件被忽略，要在仓库 Pages 设置登记域名，再重跑一次部署（旧构建的 `baseurl` 是 `/<repo>`，
  挂到根域会让静态资源全 404）。命令与验收（看资源路径，不只看页面）见上面那份 README。
- ☠️ **`stack.meirong.dev`：别在本仓库声明，也别删它**。`cloudflare_workers_custom_domain` 自己建记录，
  且不能建在已有 CNAME 的主机名上，两边各写一份必然打架。它不在本仓库 state、也没有 ownership TXT，
  看着像游离记录，删掉就是把站点摘掉；自动化不会动它（external-dns `upsert-only`、terraform 不 prune
  state 外的记录），风险只在人。记录是 `AAAA → 100::`（IPv6 丢弃地址段），Workers 的占位，不是配错。
  它走橙云，zone 级 WAF/限流对它全部生效。

## 节点地址速查

| 主机 | LAN | Tailscale |
|------|-----|-----------|
| homelab 控制面节点 `k8s-node` | `10.10.10.10` | `100.94.186.7` |
| homelab worker `k8s-worker-106`（VM on 106） | `192.168.50.107` | `100.74.162.97` |
| Proxmox host (`pve`，跑 k8s-node VM 的 5600H 笔记本) | `192.168.50.4` | `100.118.193.51` |
| oracle-k3s node | `10.0.0.26` | `100.107.166.37` |
| storage-106（worker 的宿主 + 备份/媒体源） | `192.168.50.106` | `100.110.27.111` |

⚠️ **worker 与控制面不在同一网段**（LAN `192.168.50.0/24` vs pve 内的 `10.10.10.0/24`），它另有一条
ip rule；命名正典见 [terminology.md](terminology.md)。

Pod CIDR：homelab `10.42.0.0/16`、oracle `10.52.0.0/16`。⚠️ Tailscale **不**路由 Pod CIDR（只做节点级
underlay，各节点只广播自身 /32），跨集群 pod 流量走 ClusterMesh VXLAN，见
[tailscale-network.md](tailscale-network.md)。
