# Cilium 网络策略：双集群定向收口

> 日期: 2026-11-10
> 状态: 🚧 实施中（推翻了 ROADMAP「集群级网络默认拒绝：刻意延后」的前提，但那条结论本身不变：**仍不做集群级默认拒绝**）
> 结论: 不追求零信任，只堵一类现实攻击：**公网应用被打穿或被当作 SSRF 跳板之后能摸到哪里**。
>       三个必做阶段：①私网出口护栏 ②皇冠资产入口白名单 ③抓取类负载出口白名单；④对外 ns 入口隔离为可选。
>       全部用 `CiliumNetworkPolicy` 走 GitOps。每个集群开一次全局 audit 窗口，soak 至少 8 天、零 audit 判决才翻 enforce。
>       先做 homelab，稳定一周后再做 oracle。
>       例外：oracle 的 IMDS 不等 audit 窗口，单独先做（关 IMDSv1，加一条只拦 TCP 80 的 CCNP，见 §5.1）。
> 进度（2026-11-10）：
>       ✅ §5.1 oracle IMDS 已完成。
>       ✅ homelab 阶段 0 已部署（helm rev 20，connect-clustermesh 后 rev 21）：两个 agent 都是 `PolicyAuditMode: Enabled`，Hubble 指标已被抓取。
>       ✅ homelab 阶段 1–3 的 10 条 CNP 已上线（`8ffceae`），全部 `Valid=True`，16 个 endpoint 都处于 audit（`audit-egress` / `audit-ingress` / `audit-both`）。
>       ✅ PoC（§7.1）完成，证伪了 §3.3-3。
>       ⏳ homelab soak 中，最早 2026-11-18 翻 enforce。
>       🚧 oracle 提前开始（2026-11-10，为尽早收住 rss-system 这个头号 SSRF 面；audit 期的行为和写法陷阱已在 homelab 验完）：
>          阶段 0 已部署（helm rev 21，agent `PolicyAuditMode: Enabled`），12 条阶段 1–3 策略随后并入 main（`93957da`）。
>          ⚠️ 那次 `just oracle deploy-cilium` 卡在 hubble 证书上（配方漏删旧 certgen Job），已修。
>          oracle 翻 enforce 仍排在 homelab 之后。
>       §11 的 4 条按默认处理：tailnet 例外照表开，2b 和阶段 4 不做。
> 关联: [security.md §8 / §11-2](../reference/security.md) · [security-hardening 末节](../runbooks/security-hardening.md) ·
>       [tailscale-network.md](../reference/tailscale-network.md) · [networking-ingress.md](../reference/networking-ingress.md)

---

## 1. 为什么现在做：威胁模型要重算

原先延后的理由是「单用户、没有敌对的多租户，横向移动收益边际低」。这个理由针对的是多租户隔离。
真正该问的是另一件事：**某个公网应用被打穿，或者被当成 SSRF 跳板之后，它能碰到什么**。
2026-11-10 实测的答案是几乎什么都能碰到：

| 路径 | 现状 | 依据 |
|---|---|---|
| pod → tailnet 全部设备的全部端口 | Tailscale ACL 写的是 `tag:homelab`/`tag:oracle → *:*`；pod 的出口经节点 SNAT 进入 tailscale0，于是继承了节点在 tailnet 里的全部权限（两台 Mac、DGX、pve、106、MacBook） | `tailscale/terraform/main.tf`；Hubble 中 pod → `100.x` 的流量全部是 `world` 且 FORWARDED |
| homelab pod → LAN | `192.168.50.0/24`（pve :8006、106 的 sftp 即 restic 仓库、路由器）与 `10.10.10.0/24` 全部可达 | 两集群自建 CNP 为 0 |
| oracle pod → OCI IMDS | 在 rsshub 里发一个不带任何头的 GET，就能拿到实例主体（instance principal）的证书**和私钥**。IMDSv1 没关。**已于 2026-11-10 处理**（§5.1） | rsshub pod 内 `GET /opc/v1/identity/key.pem` → 200；terraform state 中 `are_legacy_imds_endpoints_disabled = false`。详见 §5.1 |
| 任意 pod → 集群内无认证服务 | Prometheus；Alertmanager（可以静默告警）；Loki（历史上存过 argv 里的密钥）；cloudflared `/metrics` | [cloudflare-tunnel-observability](../reference/cloudflare-tunnel-observability.md) 已记录 |
| 任意 pod → Vault / Postgres | 有认证，但网络上全通 | — |

SSRF 跳板并非假设。下面这些负载的本职工作就是「按外部输入去请求 URL」：rsshub 配 browserless（无头 Chrome，抓任意页面）、
miniflux（抓任意 feed）、readlist-ingest、calibre-metadata-*、open-notebook、jobs-sg/ingest。

## 2. 现状实测（2026-11-10）

**策略面**：homelab 一条都没有。oracle 有 6 条标准 NetworkPolicy：argocd chart 自带 4 条，readlist 的 no-egress 2 条。
两个集群的 CNP 和 CCNP 都是 0。

**Cilium**（两集群一致，1.20.0）：`enable-policy=default`；`policy-audit-mode` 关闭，但运行时选项
`PolicyAuditMode` 可用（`cilium-dbg config`）；`policy-deny-response=none`，被拒的连接表现为静默超时；
Hubble 环形缓冲 4095 条，按 85–108 flows/s 算**只保留 40–50 秒历史**；Hubble metrics 未开启；
`hubble-network-policy-correlation-enabled=true`；pod 只有 IPv4；`policy-default-local-cluster=true`。

**身份分类**。写任何规则之前都要先知道这张表，数据来自 `cilium-dbg ip list -n` 和 Hubble：

| 地址 | Cilium 把它认作 | 对规则的影响 |
|---|---|---|
| 本集群与对端集群节点的 LAN/VCN IP（`10.10.10.10` `192.168.50.107` `10.0.0.26`） | `host` / `remote-node`（对端节点经 ClusterMesh 同步进来） | 用 `fromEntities`；CIDR 规则默认匹配不到节点 |
| **所有 Tailscale IP**，包括对端节点的 `100.94.186.7` / `100.107.166.37` | `world` | 跨集群 NodePort 只能写 `fromCIDR`/`toCIDR`，`remote-node`、`cluster-mesh` 实体都匹配不到。实测 oracle ESO → homelab Vault 的源就是 `world 100.107.166.37` |
| Gateway 转发给后端的流量 | `reserved:ingress` | 后端用 `fromEntities: [ingress]` 放行 |
| pod 访问 **Gateway 的 ClusterIP**（cloudflared → `10.43.219.148:80`，即 `cilium-gateway-homelab-gateway`） | Hubble 显示为 `world`，但流量被重定向给 Envoy（`to-proxy`），**不经 pod 的出口策略** | 无影响。原先担心「10/8 deny 不 except Service CIDR 会整站 530」，PoC 在 enforce 下证伪（§7.1-c） |

**5 分钟 Hubble 采样**只统计新建连接（TCP SYN 和 UDP）。§5–§6 的规则就是照它和清单写的。
**它漏掉的部分更要紧**：homelab otel → oracle Loki `:31080`、oracle otel → homelab Prometheus `:31090`、
ArgoCD → homelab API `:6443`、oracle cloudflared → Gateway，这 5 分钟内**一条新连接也没有**，因为它们全是长连接。
基线采样和 audit 判决都只在**建连时**产生，所以 soak 期间必须主动滚动重启客户端（§7.3），
否则长连接要等到某次偶然重连才会暴露，而那时策略早已 enforce。

## 3. 取舍

### 3.1 做什么

| 阶段 | 内容 | 防的是 | 破坏面 |
|---|---|---|---|
| 0 | Hubble 指标与告警、`policyDenyResponse: icmp`、全局 audit、紧急刹车配方 | 策略丢包不再静默 | 每集群一次 helm 升级（之后要重连 ClusterMesh） |
| 1 | **私网出口护栏**：对外 ns 禁止访问 LAN、tailnet、链路本地地址 | 公网应用或 SSRF → 内网 / tailnet / IMDS | 只拒绝列出的网段，其余出口照旧 |
| 2 | **皇冠资产入口白名单**：Vault 和三个 Postgres；可选 2b 覆盖 Loki、Tempo、Alertmanager | 横向打 Vault 或数据库，篡改观测链 | 只锁这几个 pod 的入口 |
| 3 | **抓取类负载出口白名单**：rss-system、readlist-ingest、calibre-metadata-*、open-notebook、jobs-sg | 通过 SSRF 打集群内任意服务 | 这些 pod 的出口改为默认拒绝 |
| 4（可选） | 对外 ns 的入口隔离 | 被打穿的 pod 横向进入同类应用 | 最大，ROI 最低，默认不做 |

### 3.2 不做什么，以及为什么

- **集群级默认拒绝**（`endpointSelector: {}` 的 CCNP）：kube-system、monitoring、argocd、backup、trivy、kyverno、ESO 的依赖面又宽又会漂移，
  漏掉任何一条都是静默超时。ArgoCD 在 oracle 上，一旦策略挡住它，修复就同步不下去。相对阶段 1–3，它多出的收益很小。
- **L7 HTTP 策略**：每条都要把流量经过 Envoy 代理，CPU 由热笔记本承担。眼下没有非 L7 不可的需求。
- **`toFQDNs`**：要把 DNS 交给 agent 的 DNS 代理，agent 重启或升级期间受管 pod 的解析会抖。
  放行公网一律写「`0.0.0.0/0` except 私网」，不按域名放行。
- **基础设施 ns 一律不动**：kube-system、monitoring（2b 除外）、argocd、backup、external-secrets、external-dns、
  trivy-system、kyverno、cnpg-system、tetragon、falco、kube-bench。
- **Host firewall**（`hostFirewall.enabled`）：NodePort 在 LAN 和 tailnet 上全开，这确实是个口子。
  但 oracle 出过 firewalld 冲掉 Cilium 规则的事（[records/2026-10-01](../records/2026-10-01-oracle-firewalld-flushes-cilium-iptables.md)），值得单独评估。
  节点级的口子用 Tailscale ACL 收更合适（§9）。
- **hostNetwork pod**（cilium、cilium-envoy、node-exporter、tetragon）：它们的身份是 `host`，pod 级策略本来就管不到。

### 3.3 写法约定（每一条都来自实测，或会造成整站中断）

1. ☠️ **只写 deny 的护栏必须显式声明 `enableDefaultDeny: {ingress: false, egress: false}`**。CRD 原文的意思是：不写时，凡是有规则的方向默认为 true；
   `egressDeny` 也算 egress 规则。漏了这一行，整个 ns 的出口（包括 DNS）立刻变成默认拒绝。
2. ☠️ **deny 永远压过 allow**，与端口粒度无关。例外只有两种写法：在 deny 规则里写 `except`，或者用 `endpointSelector` 把那个 pod 排除出去。
   另写一条 allow 不起作用。
3. 私网 deny 照样 except 本集群的 Service CIDR 和 Pod CIDR（homelab `10.43/16` `10.42/16`，oracle `10.53/16` `10.52/16`），但**只是防御性的**。
   原先以为不 except 会挡住 Gateway、整站 530，PoC 在 enforce 下证伪了：访问 Gateway ClusterIP 的流量被重定向给 Envoy，不经 pod 出口策略（§7.1-c）。
   Pod CIDR 的 except 防的是 pod 刚起、ipcache 还没同步时被当成 world。
4. 跨集群一律写 **Tailscale IP 的 /32 CIDR**，不要用 entity。
5. **选择器只用 pod 现有的标签**，不要为了写策略去改 pod 标签。改标签会重新分配 identity，又要面对一次「identity 低字节 = `0x08` 撞上 Tailscale fwmark」的 1/256 抽签。
   虽然有 5200 规则兜底，但没必要去碰（[tailscale-network.md](../reference/tailscale-network.md)）。
6. 策略放在**工作负载所属 App 的目录**里（`network-policy.yaml`），与工作负载一起创建、一起删除。不另建「策略 App」，服务退役时策略随之被 prune。
7. 每条策略都写 `spec.description`，再用 `spec.log.value`（不超过 32 个字符）打标签，在 Hubble 流里能直接看出命中的是哪一条。
8. ☠️ **oracle 上的 `169.254.169.254` 也是 VCN 的 DNS 解析器**。CoreDNS 拿它当上游，而 `oraclevcn.com` 这个 server 块**只**转发给它
   （[coredns-custom.yaml](../../cloud/oracle/manifests/base/coredns-custom.yaml)）。所以对这个地址的 deny 只能写 TCP 80，不能拦全端口，
   kube-system 也不能放进 `169.254/16` 护栏，否则 2026-08-13 那次 musl 遇 SERVFAIL 放弃整轮 search 的故障会重现。
   受护 ns 里的 pod 都是 `ClusterFirst`，DNS 走 `10.53.0.10`，不受 `169.254/16` 护栏影响（2026-11-10 实测：除 CoreDNS 自己是 `Default` 外，
   只有 uptime-kuma 是 `None`，而它的 nameserver 写的也是 `10.53.0.10`）。

## 4. 阶段 0：观测与刹车

### 4.1 Cilium values（每个集群一次 helm 升级）

```yaml
# 在 k8s/cilium/values.yaml 与 cloud/oracle/values/cilium.yaml 中同时加入
policyDenyResponse: icmp   # 出口被策略拒绝时回 ICMP 不可达：应用立即报错，不再超时
policyAuditMode: true      # audit 窗口开始；翻 enforce 时改回 false（§7.4）
hubble:
  metrics:
    enabled:
      - "drop:sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity;labelsContext=source_namespace,destination_namespace"
      - "policy:sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity;labelsContext=source_namespace,destination_namespace,traffic_direction"
    serviceMonitor:          # 仅 homelab。oracle 没有 Prometheus Operator，改由 otel 抓取（见下）
      enabled: true
      labels: { release: kube-prometheus-stack }
```

- 只开 `drop` 和 `policy` 两个指标，粒度是 workload 名，不带 IP。`policy` 只在有策略的 endpoint 上产生，所以序列很稀疏，
  不违背 [prometheus-series-reduction](../decisions/prometheus-series-reduction.md)。要看具体是哪个 IP，用 `hubble observe` 现场复现（§7.3）。
- oracle 在 `cloud/oracle/manifests/monitoring/otel-collector-config.yaml` 里照 `prometheus/cilium-envoy` 的写法，
  新增一个对 `hubble-metrics.kube-system.svc:9965` 的抓取。
- `policyAuditMode` 在 chart 1.20 的 values.yaml 里只是一行注释，但模板用 `hasKey` 读它，写上就生效（已核对 `cilium-configmap.yaml`）。
- 2026-11-10 渲染比对：除了这 6 个 ConfigMap 键，只新增 `hubble-metrics` Service 和 `hubble` ServiceMonitor（interval 设 60s，chart 默认 10s），
  外加 DaemonSet 多一个 `hostPort 9965`（两节点都确认无占用）。因为 pod 模板变了，**helm 会自己滚 agent**。
  DaemonSet 是 `maxUnavailable: 2`，两节点的 agent 会同时重启，已有连接靠 eBPF 照常转发。滚完仍要逐个核实。
  基线：agent CPU 76–79m，节流比例 0.1–0.3%（6h 均值）。
- ☠️ **`policyAuditMode` 和 `policyDenyResponse` 只改 ConfigMap，不会触发 agent 滚动**：chart 的 `rollOutCiliumPods: false`，
  而 `just deploy-cilium` 只重启 operator。所以部署完必须手动 `rollout restart ds/cilium`，并**逐个** agent 核实（`exec ds/cilium` 只会落到其中一个 pod）。

```bash
cd k8s/helm && just deploy-cilium
just connect-clustermesh 100.94.186.7:32379 100.107.166.37:32379   # ☠️ --reset-values 会冲掉跨集群 CA 信任
kubectl --context k3s-homelab -n kube-system rollout restart ds/cilium
kubectl --context k3s-homelab -n kube-system rollout status ds/cilium
for p in $(kubectl --context k3s-homelab -n kube-system get pods -l k8s-app=cilium -o name); do
  kubectl --context k3s-homelab -n kube-system exec "$p" -c cilium-agent -- cilium-dbg config | grep PolicyAuditMode
done                                                                  # 每个 agent 都应是 Enabled
kubectl --context k3s-homelab -n kube-system exec ds/cilium -c cilium-agent -- cilium status | grep -A3 ClusterMesh   # retrieved=true
# oracle 同理：cd cloud/oracle && just deploy-cilium，context 换成 oracle-k3s
```

验收：滚动前后对比 cilium-agent 的 CPU 节流比例。热约束下的判据是 cAdvisor 的 `throttled_periods` 比例，
`kubectl top` 看不出节流（[k8s-qos-resource-management.md](../reference/k8s-qos-resource-management.md)）。

### 4.2 告警与看板

`k8s/helm/manifests/monitoring/alerts/cilium-policy-alerts.yaml`（必须带 `release: kube-prometheus-stack` 标签）：

```yaml
- alert: CiliumPolicyDrops
  # POLICY_DENIED = 默认拒绝丢包；POLICY_DENY = 显式 deny 规则丢包。两个都要。
  expr: sum by (cluster, source_namespace, source, destination_namespace, destination, reason)
          (increase(hubble_drop_total{reason=~"POLICY_DENIED|POLICY_DENY"}[10m])) > 0
  labels: { severity: warning }
```

audit 窗口期间的判决由同文件第二条告警 `CiliumPolicyAuditVerdicts`（warning，进 Telegram）推送，
按 `traffic_direction` 而不是 `reason` 分组，表达式同样带 `unless … offset` 分支；不需要每天手动看面板。
`action="audit"` 是 PoC 实测的取值（§7.1-d）。上线前在 live Prometheus 回放过：只在 PoC 那 10 分钟命中，其余时间为空。
☠️ 两条告警的 annotation 都不能出现 `<xxx>`（Telegram 的 HTML 模式回 400，告警永远发不出去），
`CiliumPolicyDrops` 原来的 `netpol-brake <context>` 就是这个雷，已改成 `$context`。

### 4.3 紧急刹车

配方 `just helm netpol-brake <ctx>`（`k8s/helm/justfile`，已提交）：对该集群**每一个** cilium agent 执行 `cilium-dbg config PolicyAuditMode=Enabled`。
同批还有 `just helm netpol-audit [window] [cluster]`：按 workload 对列出 audit 判决。日常靠 §4.2 的 Telegram 告警，翻 enforce 前用它核最近 72h。
效果是全集群的策略立刻只记录不拦截，不需要 helm，ArgoCD 也不会来抢。它在 agent 重启后回到 ConfigMap 里的值，所以只能当止血手段，不能当状态。

⚠️ oracle 上刹车（以及整个 audit 窗口）会让现有 6 条 NP（readlist no-egress、argocd 的 4 条）一起变成只记录（§11 第 1 条）。

## 5. 阶段 1：私网出口护栏

每个被护的 ns 放一条 `guard-private-egress`。模板以 homelab 的 jobs-sg 为例：

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: guard-private-egress
  namespace: jobs-sg
spec:
  description: 公网负载不得访问 LAN / tailnet / 链路本地；例外写在 except 里
  log: { value: guard-private-egress }
  endpointSelector: {}
  enableDefaultDeny:        # ☠️ 必须显式写 false，见 §3.3-1
    ingress: false
    egress: false
  egressDeny:
    - toCIDRSet:
        - cidr: 10.0.0.0/8
          except:
            - 10.42.0.0/16        # 本集群 Pod CIDR
            - 10.43.0.0/16        # Service CIDR：防御性保留（§3.3-3）
        - cidr: 172.16.0.0/12
        - cidr: 192.168.0.0/16
        - cidr: 169.254.0.0/16
        - cidr: 100.64.0.0/10
          except:
            - 100.97.87.120/32    # DGX rank0 :8000（enrich 直连）
```

oracle 版本把 except 改成 `10.52.0.0/16` 和 `10.53.0.0/16`。

| 集群 | ns | `100.64/10` 的 except | 备注 |
|---|---|---|---|
| homelab | `personal-services` | `100.89.15.120` `100.97.87.120` | open-notebook 及其 provision 直连 M2 OMLX 和 DGX 的 :8000 |
| homelab | `jobs-sg` | `100.97.87.120` | enrich 直连 DGX |
| homelab | `litellm` | `100.97.87.120` `100.89.15.120` `100.98.220.75` | 推理后端：DGX、M2、Studio |
| homelab | `media` | 无 | NFS 是 kubelet 挂载，不走 pod 网络，不受影响 |
| homelab | `cloudflare` | 无 | 只连 Cloudflare 边缘和 Gateway ClusterIP（后者走 Envoy 重定向，不经出口策略） |
| homelab | `vault` | 无 | Vault 自己没有私网出口需求 |
| oracle | `rss-system` | 无 | 头号 SSRF 面 |
| oracle | `homepage` | 无 | widget 走 k8s API（`kube-apiserver` 实体，不是 CIDR） |
| oracle | `zitadel` | 无 | |
| oracle | `cloudflare` | 无 | |
| oracle | `personal-services` | 用 `endpointSelector` 排除 `app=uptime-kuma` 和 `app=calibre-metadata,role=llm` | uptime-kuma 的本职就是探内部；llm job 要访问 litellm NodePort 和 DGX，交给阶段 3 用端口精确的白名单 |

2026-11-10 落地时核对的补充：
- personal-services 还有 **xiaogpt**（在 worker 上）。它走集群内的 `litellm.litellm.svc`，不需要 tailnet 例外。
- ⚠️ **护栏挡不住 pod 访问节点 IP**：CIDR 规则默认匹配不到 host / remote-node 身份，所以 `10.10.10.10`、`192.168.50.107` 照样能连
  （sshd 只认 key，kubelet 和 API 要认证）。要挡只能按实体 deny `host`、`remote-node`，那会连 API server 一起断（multica 要用），所以不做。

⚠️ except 不能限定端口。`personal-services` 放行了 DGX 和 M2，意味着同 ns 的 nakama 也能连到那两个推理端口。
推理端口不是皇冠资产，可以接受。想收得更紧，见 §11 第 3 条。

### 5.1 oracle IMDS：单独先做，不等 audit 窗口

> 进度（2026-11-10）：第 2 步已 apply 并验收（pod 内 v1 → 404，带头的 v2 → 200，节点没有重启，cloud agent 仍是 active）。
> 第 3 步 `2c3b6fc` 已 push，ArgoCD 已同步，验收通过：CCNP `Valid=True`；rsshub 和 uptime-kuma 请求 IMDS 都超时，
> Hubble 记为 `Policy denied by denylist`；CoreDNS → `:53` 仍是 FORWARDED，`oraclevcn` 仍是 `ENOTFOUND`。
> 第 1 步已在控制台核对：没有 dynamic group 匹配这台实例。§5.1 全部完成，结论已回写到 security.md §8。

**它是什么**：每台 OCI VM 都能访问 `http://169.254.169.254/opc/v{1,2}/` 上的实例元数据服务（IMDS）。它返回实例信息（tenancy 和 compartment 的 OCID、region、shape），
也返回**实例主体凭据**（`identity/cert.pem` 和 `identity/key.pem`）。拿着这对凭据，就能以「这台 VM」的身份调用 OCI API，
权限等于所有匹配这台实例的 dynamic group 被授予的 policy 之和。pod 的出口经过节点 SNAT，IMDS 分辨不出请求来自 pod 还是节点。

**2026-11-10 实测**（只看状态码和长度，没有读取内容）：

| 项 | 结果 |
|---|---|
| v1，不带头：`/opc/v1/instance/id` | 200 |
| v2：`/opc/v2/instance/id` | 不带头 → 403；带 `Authorization: Bearer Oracle` → 200 |
| v1，不带头：`identity/cert.pem`、`identity/key.pem` | 都是 200 |
| `instance/metadata` 的键 | 只有 `ssh_authorized_keys`，没有 user_data，没有密钥经元数据泄露 |
| 节点上还有谁在用 v1 | cloud-init 26.1 先试 v2，失败才回退 v1。oracle-cloud-agent 1.48 的二进制里有 `opc/v1` 字符串。在节点上抓了 5 分钟，共 4 个请求，全部是 `GET /opc/v2/instance`，没有一个走 v1。cloud-init 只在开机时跑，这次抓不到它；但它是先试 v2 的 |
| 有没有 dynamic group 匹配这台实例 | 没有（2026-11-10 在控制台核对），实例主体凭据当前没有任何权限 |

**眼下的实际危害取决于 dynamic group**。如果没有任何 dynamic group 匹配这台实例，这对凭据没有任何权限，泄露的只是几个 OCID。
但它是个地雷：一旦以后用实例主体授权，**每个 pod 都会自动继承这份权限**。比如[离站备份](2026-08-03-offsite-backup.md)选了 OCI 对象存储并走 instance principal，
那么每个 pod 都能删备份桶。

**三步，全部可逆：**

1. **在控制台核对 dynamic group**（1 分钟）：Identity & Security → Domains → Default → Dynamic groups，看有没有规则能匹配这台实例
   （例如 `instance.compartment.id = ...` 或 `instance.id = ...`）；再到 Policies 里搜 `dynamic-group`。如果有匹配的，按事故处理，先收权限。
2. **关 IMDSv1**：在 `cloud/oracle/terraform/main.tf` 的 `oci_core_instance.k3s` 里加：

   ```hcl
   instance_options {
     are_legacy_imds_endpoints_disabled = true
   }
   ```

   前提：上表的 tcpdump 里没有节点进程只走 `/opc/v1/`。
   `just tf plan` 必须显示 `~ update in-place`；如果出现 `-/+`（重建实例），立刻停手。
   apply 之后验收：pod 内 v1 → 404，带头的 v2 → 200；`snap services oracle-cloud-agent` 仍是 active。
   这一步堵住的是 **SSRF**。SSRF 通常只能让服务端发出不带自定义头的请求：跟随重定向不会带上 `Authorization`；
   浏览器里跨源带这个头要先过 CORS 预检，而 IMDS 不响应预检。
   它**挡不住 pod 被拿下 RCE**，因为有 shell 的人可以自己加头。这就是第 3 步存在的原因。
3. **加一条 CCNP，禁止所有 pod 访问 IMDS 的 HTTP 端口**。文件放 `cloud/oracle/manifests/base/deny-oci-imds.yaml`，并在 `cloud/oracle/manifests/kustomization.yaml` 里登记（由 oracle-k3s App 同步）：

   ```yaml
   apiVersion: cilium.io/v2
   kind: CiliumClusterwideNetworkPolicy
   metadata:
     name: deny-oci-imds
   spec:
     description: 所有 pod 禁止访问 OCI IMDS 的 HTTP；同一地址的 53 端口是 VCN DNS，CoreDNS 要用，不能拦
     log: { value: deny-oci-imds }
     endpointSelector: {}
     enableDefaultDeny:        # ☠️ 见 §3.3-1
       ingress: false
       egress: false
     egressDeny:
       - toCIDR: [169.254.169.254/32]
         toPorts:
           - ports:
               - { port: "80", protocol: TCP }   # ☠️ 只拦 80，见 §3.3-8
   ```

   它覆盖了阶段 1 护栏管不到的 ns：argocd（repo-server 会渲染外部 chart）、monitoring、backup、databases。
   hostNetwork 进程（oracle-cloud-agent、cloud-init）不受 pod 策略约束，照常访问。
   **不等 audit 窗口**，因为 pod 访问 IMDS 的 HTTP 没有任何合法用途：集群没装 OCI CCM/CSI，仓库里也没有用 OCI SDK 的负载。
   以后 oracle 开全局 audit 的那段时间，这条会退化成只记录不拦截；那时第 2 步仍然挡着 SSRF，可以接受。

   验收命令（2026-11-10 的基线：`oraclevcn: ENOTFOUND`、`external: 4 A records`、`imds v2: 200`）：

   ```bash
   kubectl --context oracle-k3s -n rss-system exec deploy/rsshub -- node -e '
   const r=new (require("dns").promises.Resolver)();r.setServers(["10.53.0.10"]);
   r.resolve4("x.oraclevcn.com").then(a=>console.log("oraclevcn:",a),e=>console.log("oraclevcn:",e.code));
   r.resolve4("dl-cdn.alpinelinux.org").then(a=>console.log("external:",a.length,"A records"),e=>console.log("external:",e.code));
   fetch("http://169.254.169.254/opc/v2/instance/id",{headers:{Authorization:"Bearer Oracle"},signal:AbortSignal.timeout(4000)}).then(r=>console.log("imds v2:",r.status),e=>console.log("imds v2 blocked:",e.name))'
   ```

   通过标准：前两行与基线一致。`oraclevcn` 必须仍是 `ENOTFOUND`（即 NXDOMAIN）；如果变成 `ESERVFAIL`，说明误拦了 53 端口，立刻 revert。
   第三行变成 `imds v2 blocked: TimeoutError`。阶段 0 把 `policyDenyResponse` 设成 icmp 之后，失败会立即返回，不再等超时。
   回滚：git revert。

## 6. 阶段 2、3、4

### 6.1 阶段 2：皇冠资产入口白名单

只写 `ingress`，所以只有被选中 pod 的入口进入默认拒绝，出口不受影响。kubelet 探针来自本机 `host`，Cilium 默认放行。

**homelab `vault/vault`**（来源以清单与 Hubble 实测为准）：

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: vault-ingress, namespace: vault }
spec:
  description: Vault 只接受 Gateway、两侧 ESO、备份和 Prometheus
  log: { value: vault-ingress }
  endpointSelector:
    matchLabels: { app.kubernetes.io/name: vault, component: server }
  ingress:
    - fromEntities: [ingress]                       # vault.meirong.dev：运维 CLI 和 UI 都走这里
      toPorts: [{ ports: [{ port: "8200", protocol: TCP }] }]
    - fromEndpoints:
        - matchLabels: { k8s:io.kubernetes.pod.namespace: external-secrets, app.kubernetes.io/name: external-secrets }
        - matchLabels: { k8s:io.kubernetes.pod.namespace: backup, app: restic-backup }   # raft snapshot
        - matchLabels: { k8s:io.kubernetes.pod.namespace: monitoring, app.kubernetes.io/name: prometheus }
      toPorts: [{ ports: [{ port: "8200", protocol: TCP }] }]
    - fromCIDR: [100.107.166.37/32]                 # oracle ESO 经 NodePort 31952；Tailscale IP 在这里是 world
      toPorts: [{ ports: [{ port: "8200", protocol: TCP }] }]
```

| 对象 | 放行来源 |
|---|---|
| homelab `databases/apps-pg` :5432 | `litellm`；`personal-services` 的 multica-backend、nakama；`monitoring` 的 grafana（blogstats 只读）和 blog-stats-rollup；`backup/restic-backup`（pg_dump） |
| oracle `databases/apps-pg`（CNPG） | :5432 ← `rss-system/miniflux`、`backup`；:8000 ← `cnpg-system` operator（实测有这条） |
| oracle `zitadel/zitadel-pg`（CNPG） | :5432 ← `zitadel` ns 内的 zitadel 及 init/setup Job、`backup`；:8000 ← `cnpg-system` |
| （2b，可选）oracle Loki gateway / Tempo | `monitoring` ns 内部；homelab 节点的 Tailscale IP `100.94.186.7/32` `100.74.162.97/32`（otel 写入、Grafana 查询） |
| （2b，可选）homelab Alertmanager | Prometheus、Grafana；`100.107.166.37/32`（oracle Loki ruler 经 NodePort 31093） |

⚠️ 2b 的来源比其它项多，而且挂掉的是观测链本身（坏了也不会有告警告诉你）。所以放到 2 稳定之后再做，做不做可以由你决定。

### 6.2 阶段 3：抓取类负载出口白名单

对象是 oracle 的 `rss-system` 全部 pod、`readlist-ingest`、`calibre-metadata-*`，以及 homelab 的 `open-notebook`、`jobs-sg`。
出口改为默认拒绝，只放行 DNS、同 ns、已知的集群内依赖，以及「公网 except 私网」：

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: fetcher-egress, namespace: rss-system }
spec:
  description: 抓取类负载只能出公网和自身依赖，碰不到集群内其它服务
  log: { value: fetcher-egress }
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels: { k8s:io.kubernetes.pod.namespace: kube-system, k8s-app: kube-dns }
      toPorts: [{ ports: [{ port: "53", protocol: ANY }] }]   # 纯 L4，不启用 DNS 代理
    - toEndpoints: [{}]                                         # 同 ns：rsshub ↔ browserless ↔ redis
    - toEndpoints:
        - matchLabels: { k8s:io.kubernetes.pod.namespace: databases, cnpg.io/cluster: apps-pg }
      toPorts: [{ ports: [{ port: "5432", protocol: TCP }] }]   # miniflux
    - toCIDRSet:
        - cidr: 0.0.0.0/0
          except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10]
```

- 访问自家公网域名（`*.meirong.dev`）会出公网，经 Cloudflare 和 WAF 绕回来，这是允许的，也正好让 SSRF 无法绕开 WAF。
- `calibre-metadata` 的 llm job 另加一条端口精确的 `toCIDR`：`100.94.186.7/32:31400`（litellm NodePort）和 `100.97.87.120/32:8000`。
- readlist-snapshot/score 已经有 no-egress NP，保持不动。

**2026-11-10 oracle 落地时的调整**（依据：清单里的连接串、5 分钟 Hubble 采样、oracle agent 的 conntrack 全表）：
- calibre-metadata 的 llm job 只连 litellm NodePort `:31400`，清单里没有直连 DGX，所以没开 `100.97.87.120`。
- 新增两条入口规则：`rsshub-browserless`（没有 TOKEN）和 `rsshub-redis`（没有密码）只接受 rsshub。
- `calibre-metadata-enrich`、`calibre-metadata-updater`、`ebook-sync-monitor`、`open-notebook-ingest` 的 pod 没有标签，只受 ns 护栏约束。
- ⚠️ oracle 的 `open-notebook-ingest` 指向 `open-notebook.personal-services.svc:5055`，而 oracle 上没有这个 Service（open-notebook 在 homelab），
  这个手动 Job 本来就跑不通，与策略无关；§7.3 的手动触发清单里它可以跳过。

### 6.3 阶段 4（可选）：对外 ns 入口隔离

每个对外 ns 一条：放行 `ingress` 实体、同 ns、monitoring（抓指标）以及基线里实测到的跨 ns 调用方
（例如 uptime-kuma → homepage、miniflux；各 ns → litellm；oracle → litellm NodePort 走 CIDR）。
有了阶段 1–3，它多防住的只剩「打穿一个对外应用后再横向进另一个对外应用」，依赖面却最宽。
**建议阶段 1–3 enforce 满一个月、`CiliumPolicyDrops` 一直安静时，再决定做不做。**

## 7. 灰度与验收（每个集群走一遍：先 homelab，稳定一周后 oracle）

### 7.1 阶段 0 部署后的 PoC（≤ 1 小时）

建一个 ArgoCD 不跟踪的临时 ns `netpol-poc`（打上 PSA baseline 标签；镜像要钉 tag，Kyverno 会 Enforce 拦 `:latest`），起一个 curl pod，
在全局 audit 下用 `hubble observe -n netpol-poc --verdict AUDIT --follow` 验证四件事：

- a. 只写 `egressDeny` 且显式 `enableDefaultDeny: false`：只有去私网段的流量出 AUDIT，DNS 与公网流量不出。
- b. 去掉 `enableDefaultDeny`：DNS 和公网流量**也**开始出 AUDIT。这一步用来证明 §3.3-1 的坑是真的。
- c. 私网 deny 不 except Service CIDR：curl Gateway 的 ClusterIP 出 AUDIT。证明 §3.3-3。
- d. 记下 `hubble_policy_verdicts_total` 里 audit 判决对应的 `action` 标签取值，回填 §4.2 的面板查询。

做完之后删掉这个 ns。

**2026-11-10 结果**（homelab，全局 audit 下；c 另用 `cilium-dbg endpoint config <id> PolicyAuditMode=Disabled` 只把 PoC 这一个 endpoint 切到 enforce）：

| 项 | 结果 |
|---|---|
| a | ✅ 只有去 `192.168.50.4:8006` 的出 AUDIT（`policy-verdict:L3-Only`）；DNS、公网、Gateway 都不出 |
| b | ✅ 坑是真的：去掉 `enableDefaultDeny` 后，去 CoreDNS :53 和公网 :443 的也出 AUDIT（`policy-verdict:none`，即默认拒绝） |
| c | ❌ **原假设被证伪**：10/8 deny 不 except Service CIDR，即使在 enforce 下 Gateway ClusterIP 照样 200；同一时刻去 LAN 的被拦（`EGRESS DENIED`），0.2ms 立即失败，`policyDenyResponse: icmp` 生效。§2、§3.3-3 已改 |
| d | ✅ `action="audit"`；显式 deny 丢包的 `reason=POLICY_DENY`，告警的正则对得上。`just helm netpol-audit` 能列出 PoC 的判决 |

⚠️ 两个顺手发现：节点时钟比 Mac 快 14 秒，`hubble observe --since` 要用 agent 里 `date -u` 取的时间；`cilium-dbg endpoint config` 改完要等 endpoint 重新生成，立刻测会拿到旧行为。

### 7.2 落地策略

阶段 1–3 的 CNP 通过 git 提交，ArgoCD 同步。此时全局 audit 已开，提交本身不会拦截任何流量。
ArgoCD 管 Cilium CR 不会常驻 OutOfSync：oracle 的 CCNP `deny-oci-imds` 同步后 oracle-k3s App 是 Synced / Healthy，不需要 `ignoreDifferences`。

homelab 的 10 条先放在分支上，等每个 agent 都确认是 `PolicyAuditMode: Enabled` 后才 cherry-pick 进 main（`8ffceae`）。oracle 照此办理。

### 7.3 soak（至少 8 天）

- 8 天覆盖所有日任务和周任务：周一的 jobs-sg/report 和 krr、周日的 calibre-metadata-backfill 和 kube-bench、每 6 小时一次的 ebook-sync-monitor。
- **手动触发**月度任务与纯手动任务：homelab 的 `backup/restic-restore-drill`；oracle 的 `calibre-metadata-{correct,covers,llm}` 和 `open-notebook-ingest`
  （这几个的 schedule 是 `0 5 31 2 *`，永远不会自动跑）：
  `kubectl --context <ctx> -n <ns> create job --from=cronjob/<name> netpol-soak-<name>`
- **滚动重启长连接的客户端**，强制重新建连：两侧的 otel-collector、两侧的 ESO、
  所有被策略选中 ns 内的 Deployment、grafana、miniflux、litellm。不重启 ArgoCD（它不在任何策略里）。
- `CiliumPolicyAuditVerdicts` 响了（Telegram）就处理：用 `hubble observe --verdict AUDIT -n <ns> --since 1h` 看 IP 和端口，补规则后重新计时。

**homelab soak 记录**：2026-11-10 16:41（UTC+8）10 条 CNP 同步完成，soak 从这时算起，**最早 2026-11-18 可翻 enforce**。
`netpol-poc/-` 那几条 audit 是 PoC 留下的，2026-11-13 之后会滚出 72h 窗口，不算数。
同理 `netpol-e2e/telegram-test`：2026-11-10 22:09（UTC+8）端到端测了一次 `CiliumPolicyAuditVerdicts`，约 1 分钟触发并投递到 Telegram，约 10 分钟后发出恢复消息，`alertmanager_notifications_failed_total` 保持 0。ns 已删。
上线当天不靠重启也已核实（cilium-dbg 读 BPF 策略表的命中计数）：
- vault-0 的 Allow Ingress 条目全部在走流量：Gateway、ESO、Prometheus、oracle 节点 `100.107.166.37`（跨集群源 IP 确实保住了）。
- apps-pg：litellm、multica-backend、nakama 在走；grafana 要等有人打开 blogstats 面板；restic-backup 和 blog-stats-rollup 的 pod 不在场时选择器匹配 0 个 identity，属正常，等它们自然跑（每晚 03:00 / 每天 10:30 UTC）。
- open-notebook 的出口白名单：surrealdb、DNS、DGX、M2 都有命中，私网 deny 条目全是 0。
- conntrack 扫描里唯一「会被拒」的是 vault-agent-injector → `10.10.10.10:6443`，是误报：节点 IP 是 host 身份（identity 1），CIDR 选择器选不到它。
所以上面「滚动重启长连接客户端」可以省掉大半；ESO 重启被权限拦了，但上面的命中计数已经给出同样的答案。

**oracle soak 记录**：2026-11-11 00:14（UTC+8）12 条 CNP 同步完成（6 个 App 在 `67471ea` 上 Synced / Healthy，全部 `Valid=True`，
目标 ns 的 21 个 endpoint 都处于 audit），soak 从这时算起，**最早 2026-11-19 可翻，且排在 homelab 翻 enforce 之后**。
oracle 的 Hubble 指标已带 `cluster=oracle-k3s` 进 homelab Prometheus，指标名没被 otel 改（没有多出 `_total`），两条告警自动覆盖。
上线当天的 BPF 命中计数：apps-pg ← miniflux、zitadel-pg ← zitadel、rsshub-redis ← rsshub 都在走；私网 deny 条目全是 0；
browserless ← rsshub 的条目已就位、等 rsshub 下次渲染页面；restic-backup 要等 03:30 自然跑。
⚠️ 这次 `connect-clustermesh` 在 oracle 侧的 helm upgrade（rev 22）**滚了 agent**（homelab 侧没有）。滚完仍是 `PolicyAuditMode: Enabled`
（来自 ConfigMap），但翻 enforce 那天不能假设 connect 不会动 agent，跑完要再逐个核一遍。
待手动触发（会改书库元数据，先问用户）：`calibre-metadata-{correct,covers,llm}`。

**通过标准**：最近 72 小时零 audit 判决；整个窗口内出现过的每一条 audit 都有解释，并已补规则或确认属于该拦的流量。

### 7.4 翻 enforce

```bash
# 把 values 里的 policyAuditMode 改成 false 并提交，然后：
cd k8s/helm && just deploy-cilium
just connect-clustermesh 100.94.186.7:32379 100.107.166.37:32379
kubectl --context k3s-homelab -n kube-system rollout restart ds/cilium   # ☠️ 只改了 ConfigMap，不重启就不会生效
# 逐个 agent 核实 PolicyAuditMode: Disabled（同 §4.1 的循环）
```

**正向检查**（应该通的都通）：各对外域名 200；两侧 ExternalSecret 都是 `Ready=True`；
手动跑一次 `restic-backup`，日志里 vault.snap 和各库 dump 都成功；Prometheus 的 targets 全部 up；
Grafana 能查 Loki 和 Tempo；ArgoCD 两侧的 App 全部 Synced。

**反向检查**（应该拦的确实拦住，而且立刻失败、不超时）：从 `jobs-sg` 里随便一个 pod 执行
`curl -m5 http://192.168.50.4:8006` 立即报错；oracle 的 `rss-system` 里 `curl -m5 http://loki-gateway.monitoring` 立即报错。

之后观察 7 天，`CiliumPolicyDrops` 只应因反向检查响过。

### 7.5 回滚

由快到慢：

1. **止血**：`just netpol-brake <ctx>`，秒级全集群只记录不拦截，不受 ArgoCD 影响。
2. **定点撤一条**：`git revert` 掉那条 CNP 并 push，ArgoCD prune 掉（不超过 3 分钟）。
   ⚠️ 只用 `kubectl delete cnp` 没用：git 里还有它，selfHeal 会在 3 分钟内把它建回来。
3. **整体退回**：values 改回 `policyAuditMode: true`，按 §7.4 的流程再走一遍。

## 8. CI 护栏（暂缓）

> 2026-11-10 暂缓：check-manifests.py 和 manifest-safety-checks.md 都写明**只收已经发生过（或正在静默发生）的事故**，
> 不为「看起来更规范」加规则，怕误报让整个检查被无视。H6 防的坑还没真出过事，现在加就违背这条收录原则。
> 眼下靠每个策略文件里的 ☠️ 注释和 PoC（§7.1-b）的实证兜底。要不要破例，由你决定。

原设想：在 `scripts/check-manifests.py` 里加一条 **H6**，把 §3.3 中两条会造成整站中断的约定变成静态检查：

- **H6a**：CNP/CCNP 中只要含 `egressDeny` 或 `ingressDeny`，就必须显式写出 `enableDefaultDeny` 的对应方向。
- **H6b**（PoC 已证伪其前提，不再需要）：deny 规则里的 `toCIDRSet` 只要覆盖了本集群的 Service CIDR（按清单路径判断集群：`k8s/` 对应 `10.43.0.0/16`，`cloud/oracle/` 对应 `10.53.0.0/16`），就必须在 `except` 中列出它。

规则原文同步写进 [manifest-safety-checks.md](../reference/manifest-safety-checks.md)。

## 9. 并行建议（不在本方案范围内）

**收紧 Tailscale ACL**。CNP 只管被策略选中的 pod。`tag:homelab/tag:oracle → *:*` 同时放开了节点本身、hostNetwork 进程，
以及没进护栏的 ns（monitoring、backup 等）。把 dst 收到真正用到的端口
（OMLX `:8000`、exporter `:9100`/`:9090`、对端 NodePort、ClusterMesh `:32379`、106 的 `:22`），是节点级的那一半防线。
建议单独列入 ROADMAP。

## 10. 做完之后回写（然后删除本文件）

- `reference/security.md`：§1 第 9 层状态、§8 现状、§10「东西向横向移动」一行、§11 第 2 条；另加 oracle IMDS 一行（v1 已关、pod 禁止访问 :80，以及实例主体授权的地雷）。
- 新建 `runbooks/network-policy.md`：给新服务加例外、排查 `CiliumPolicyDrops`、刹车与回滚。
  它替换 `runbooks/security-hardening.md` 的「延后/门控」末节。
- `runbooks/add-service.md` 加一步：服务落在受护 ns，且需要访问 tailnet 或 LAN 时，要改 except 或补入口规则。
- ROADMAP「集群级网络默认拒绝」那一行：改写成「集群级默认拒绝不做，改为定向收口（已完成）」，并链接到 security.md。
- 「不做集群级默认拒绝、不用 L7 和 toFQDNs」的取舍写进 `decisions/`，作为一份 ADR。

## 11. 需要你拍板的点

1. **oracle 的 audit 窗口（约 8 天）期间，readlist 的 no-egress 和 argocd 的 4 条 NP 只记录不拦截**。
   接受吗？我的判断是可以接受：readlist 那两个 Job 跑的是自己的代码，防的是供应链被投毒，8 天的暴露窗口很小。
2. **Uptime Kuma 不进护栏**（它的本职就是探测内部服务）。接受吗？
3. open-notebook、jobs-sg/enrich、calibre-metadata-llm **绕过 LiteLLM 直连 DGX 或 Mac**，于是这三处都要开 tailnet 例外。
   如果它们改为走 LiteLLM，例外就能收敛到 litellm 一个 ns，但要先确认当初直连是不是为了避开 LiteLLM 的超时（jobs-sg 有过 300s 超时的问题）。
4. **阶段 2b**（Loki、Tempo、Alertmanager 的入口白名单）和**阶段 4**做不做？
