# Networking & Ingress — 入口链路与 DNS 自动化

> Last updated: 2026-09-01
> Status: 生效事实
>
> 南北向入口（Cloudflare → Cilium Gateway）与 DNS 自动化（external-dns）。
> **跨集群**网络（Tailscale underlay + ClusterMesh）在 [tailscale-network.md](tailscale-network.md)；
> 隧道能观测到什么见 [cloudflare-tunnel-observability.md](cloudflare-tunnel-observability.md)。

## 外部流量链

```
Internet → Cloudflare DNS → Cloudflare Tunnel(cloudflared) → Cilium Gateway API → Service
```

集群零公网入站端口；WAF/限流等边缘安全见 [security.md §2](security.md)。

- **cloudflared**: `cloudflare` ns 的 pod，转发到 Cilium 托管的 Gateway service
  （`cilium-gateway-<gateway-name>.kube-system.svc:80`）。
  ⚠️ oracle-k3s 侧必须 `--protocol http2`（Oracle Cloud NSG 拦出站 UDP/QUIC）。
- **Ingress**: Cilium Gateway API 是集群内唯一 HTTP 入口。

## Cilium（CNI + Gateway 控制器）

- 双集群 Cilium（eBPF + VXLAN）；homelab 2026-03-06 部署，oracle 2026-03-07 从 Flannel 迁入。
- **homelab Cilium 是 Helm 手动管理，不走 ArgoCD**: `just deploy-cilium`（`k8s/helm/`），
  values 固化在 `k8s/cilium/values.yaml`（+ 同目录 README），pin v1.20.0（2026-08-10 双集群
  例行部署随 chart repo 升到 1.20.0，过程与 Gateway API breaking change 见
  [../records/2026-08-11-gateway-api-crd-stall.md](../records/2026-08-11-gateway-api-crd-stall.md)；
  两 justfile 的 `cilium_version` 都是 1.20.0）。
  该配方会 pin `--version 1.20.0` 并恢复 live `cilium-ca`（fresh install 会自签，装完要重跑
  `just connect-clustermesh …`）。oracle 侧 values 在 `cloud/oracle/values/cilium-values.yaml`
  （`cd cloud/oracle && just deploy-cilium`）。
- **⚠️ `gatewayAPI.enableAppProtocol: true` 是两集群硬前提**: 没有它，ZITADEL console 的
  v1 gRPC 过网关 404（Envoy grpc_web filter 把转换后的原生 gRPC 用 HTTP/1.1 发给需要 h2c 的
  后端；尊重 Service `appProtocol` 才给 `zitadel:8080` 显式 h2c upstream）。
  记录: [../records/2026-06-07-zitadel-console-grpc-404.md](../records/2026-06-07-zitadel-console-grpc-404.md)。

## Gateway API 布局与 HTTPRoute 约定

- **homelab**: `k8s/helm/manifests/gateway/`（ArgoCD `gateway` App）：`gateway.yaml` =
  GatewayClass + Gateway 本体；每条对外路由一个 `route-<service>.yaml`（ReferenceGrant +
  HTTPRoute 成对）。**新子域名 = 新建一个 `route-*.yaml`**。parentRef
  `homelab-gateway`/`kube-system`/8000。
- **oracle-k3s**: HTTPRoute 与服务写在同一个 manifest 文件里
  （`cloud/oracle/manifests/personal-services/<service>.yaml`），parentRef
  `oracle-gateway`/`kube-system`/80。
- **跨 ns 引用必须有目标 ns 里的 ReferenceGrant，且 apiVersion 写 `v1beta1`**：
  声明成 `v1` 会让整个 App `ComparisonError`（CI H3 拦截）。
- **HTTPRoute 模板纪律**: `parentRefs` 写全 `group`/`kind`，`backendRefs` 写全
  `group`/`kind`/`weight`，否则 Gateway controller 补默认值导致 ArgoCD 永久 OutOfSync。
- **单个路径开小灶用 `Exact`，☠️ 不能用 `PathPrefix`**。规范原文「precedence must be
  given to the match having: * "Exact" path match. * "Prefix" path match with largest
  number of characters.」（就在本集群 HTTPRoute CRD 的 `rules.matches` description 里），
  所以 Exact 稳赢 Prefix、与 rule 顺序无关，不用赌平局。反过来用 `PathPrefix: /`
  给单个路径挂 filter 会把全站吃进去。某个 filter 能不能用，查
  `kubectl get gatewayclass <class> -o yaml` 的 `status.supportedFeatures`
  （Cilium v1.20 列了 `HTTPRoutePathRedirect` 等）。
- ☠️ **被网关 filter 就地应答的路径，不能拿来当存活探针**：`RequestRedirect` 之类的
  响应由 Envoy 直接返回，请求根本到不了 pod。2026-08-25 给 `multica.meirong.dev` 的
  `/` 挂 302 → `/homelab/issues`（收掉上游 SaaS 营销页）时踩到：Uptime Kuma 原本探的就是
  `/`，改完等于「探网关」，后端死透也全绿；探测已改打 `/api/config`。这是本仓库目前
  唯一用 HTTPRoute filter 的地方，见
  [`route-multica.yaml`](../../k8s/helm/manifests/gateway/route-multica.yaml)。

## DNS 自动化（external-dns）

**净效果：新增子域名只需要写一个 HTTPRoute**。DNS 记录自动建、通配隧道路由自动转发，
`cloudflare/terraform` 不需要任何改动（✅ 2026-07-20 两集群全量完成：15 条既有记录零停机
移交，两条隧道都改成单条 `*.meirong.dev` 通配路由）。采纳理由与迁移过程见
[../decisions/external-dns-adoption.md](../decisions/external-dns-adoption.md)。

- **实例**: 两个 ArgoCD App，homelab `external-dns` + oracle `external-dns-oracle`
  （chart 1.21.1 多源 + `$values`；homelab 实例同时管 `manifests/external-dns/` 的 ExternalSecret）。
  ⚠️ oracle 侧必须带 `helm.releaseName: external-dns`（Application 名 ≠ release 名的坑，见
  [argocd-app-patterns.md](argocd-app-patterns.md)）。
- **配置**: `sources: [gateway-httproute]`、`provider: cloudflare`、`domainFilters: [meirong.dev]`、
  `policy: upsert-only`（永不删除，安全默认）+ `registry: txt`（owner id `homelab-externaldns` /
  `oracle-externaldns`，两实例独立）。两集群 Gateway 都打了
  `external-dns.alpha.kubernetes.io/target` 注解指向各自 tunnel CNAME（Cilium NodePort Gateway
  没有可读的 LB 地址）。
- ⚠️ **`upsert-only` 意味着删 HTTPRoute 不删 DNS 记录**，退役服务要手工清 CNAME + ownership TXT。
- **Cloudflare token**: 两集群共用同一把 Zone 级 API Token（Vault `secret/homelab/external-dns` → ESO）。
  ⚠️ `cloudflare/terraform/` 这个 root 的有效 token 在 gitignored 的 `.env` 里，由 justfile
  （`set dotenv-load`）经 `-var` 注入，**必须用 `just plan`/`just apply`**；裸跑 `terraform plan`
  会读到 `terraform.tfvars` 里留存的无效值而报错（2026-07-19 曾误判为"token 失效"）。

## 不走这条链的 meirong.dev 主机名（集群外托管）

> 跨仓库那条（`stack.meirong.dev` 由 home-stack 自己的 terraform 拥有）的取舍与完整
> 归属表见 [decisions/home-stack-repo-boundary.md](../decisions/home-stack-repo-boundary.md)。

⚠️ **"写 HTTPRoute 即建 DNS" 只覆盖跑在集群里的服务**。集群外托管的站点没有 HTTPRoute，
两套自动化都够不着它：external-dns 的 source 只有 `gateway-httproute`（看不见），通配隧道
路由只对 CNAME 指向隧道的主机名生效（用不上）。这类记录**通常必须**在
`cloudflare/terraform/main.tf` 的 `local.external_origin_dns` 里显式声明，这是"加子域名别动
那个模块"的例外。⚠️ 而 Workers 自定义域名是例外的例外：它自己建记录，反倒不能写进那个
map（见下表第 3 行）。

| 主机名 | 托管 | 记录归属 | 代理 |
|--------|------|----------|------|
| `meirong.dev`（apex，博客） | Cloudflare Pages `meirongdevblog.pages.dev` | Cloudflare Pages 自建，不在 terraform state 里 | 橙云 |
| `playgrounds.meirong.dev` | GitHub Pages `meirongdev.github.io`（repo `meirongdev/playgrounds`） | `local.external_origin_dns`（2026-08-13） | DNS-only |
| `stack.meirong.dev` | Cloudflare Workers（repo `meirongdev/home-stack`，Rust→wasm SSR + 静态资源层） | home-stack 仓库的 terraform（`cloudflare_workers_custom_domain`），不在本仓库 state 里（2026-08-23） | 橙云 |

- ⚠️ **GitHub Pages 必须 DNS-only（灰云）**：GitHub 给自定义域签 Let's Encrypt 证书走 HTTP-01，
  橙云 + 全区 *Always Use HTTPS* 会把校验重定向到「还没有证书的 HTTPS 源」，成死循环。
  仓库 Settings → Pages 显示证书已签发后，才可以按需改回 `proxied = true`。
- ⚠️ **DNS-only 的主机名完全绕过边缘**：WAF / 限流 / 缓存（[security.md §2](security.md)）
  对它一条都不生效，别把它算进那几层防护的覆盖面。
- ⚠️ **Workers 自定义域名：别在本仓库声明，也别删它**。`cloudflare_workers_custom_domain`
  会自己建 DNS 记录并签证书，而 Cloudflare 不允许把它建在已存在 CNAME 的主机名上，
  两个仓库各写一份必然打架。反过来，那条记录既不在本仓库 state、也没有 external-dns 的
  ownership TXT，看着像"游离记录"，**但不要清理**：删掉就是把站点域名摘掉，而线索在另一个
  仓库。自动化不会动它（两个 external-dns 都是 `policy: upsert-only`，terraform 也不 prune
  不在自己 state 里的记录），唯一的风险是人。
- 记录长相是 `AAAA → 100::`（IPv6 丢弃地址段）。这不是配错：Workers 自定义域名的记录
  就是这种占位，真实流量在边缘被截走，压根不会去解析它。
- ⚠️ 与上面的 GitHub Pages 相反，这个主机名走**橙云**，所以 zone 级 WAF/限流对它全部生效
  （[security.md §2](security.md)），加规则时记得它也在覆盖面里。
- ⚠️ **DNS 通了 ≠ 站点通了**：Pages 用自定义 Actions workflow（`actions/deploy-pages`）发布时，
  仓库里提交的 `CNAME` 文件会被忽略，自定义域得在仓库 Pages 设置里登记，否则解析正常但
  返回 "There isn't a GitHub Pages site here"（`gh api -X PUT repos/<o>/<r>/pages -f cname=…`）。
- ⚠️ **登记完还得重新部署一次**（`gh workflow run pages.yml`）：登记后新域名会继续 404
  （同时 `<org>.github.io/<repo>` 开始 301 到新域名），且上一次构建的 `baseurl` 还是 `/<repo>`，
  直接挂到根域会让每个静态资源 404（页面能开、样式全丢）。重跑一次以空 base path 重建。
  验收要看资源不只看页面：`curl -s https://<host>/ | grep -o 'href="/[^"]*"'` 应该是
  `/assets/...`，不是 `/<repo>/assets/...`。

## 节点地址速查

| 主机 | LAN | Tailscale |
|------|-----|-----------|
| homelab 控制面节点 `k8s-node` | `10.10.10.10` | `100.94.186.7` |
| homelab worker `k8s-worker-106`（VM on 106，2026-08-13 入编） | `192.168.50.107` | `100.74.162.97` |
| Proxmox host (`pve`，跑 k8s-node VM 的 5600H 笔记本) | `192.168.50.4` | `100.118.193.51` |
| oracle-k3s node | `10.0.0.26` | `100.107.166.37` |
| storage-106（worker 的宿主 + 备份/媒体源） | `192.168.50.106` | `100.110.27.111` |

⚠️ **worker 与控制面不在同一网段**（LAN `192.168.50.0/24` vs pve 内的 `10.10.10.0/24`），
它另有一条 ip rule；命名正典见 [terminology.md](terminology.md)。

Pod CIDR: homelab `10.42.0.0/16`、oracle `10.52.0.0/16`。⚠️ Tailscale **不**路由 Pod CIDR
（2026-07-07 起只做节点级 underlay，各节点只广播自身 /32）；跨集群 pod 流量走 Cilium
ClusterMesh VXLAN；连接命令与验证见 [tailscale-network.md](tailscale-network.md)。
