# Cloudflare Tunnel Observability

> Last updated: 2026-08-15
> Status: 生效事实

当前架构的入口路径为：`Cloudflare DNS -> Cloudflare Tunnel -> Cilium Gateway API -> Services`。

本仓库已经移除 Traefik 和基于 Traefik router label 的按域名流量拆分方案，因此这里仅记录仍然有效的 Tunnel 健康观测方式，以及现阶段看不到什么。

## 观测范围

可以观测：

1. `cloudflared` 是否在线
2. 每个隧道的 HA 连接数
3. 活跃 streams 和总请求量
4. 边缘 PoP 连接分布
5. 隧道级错误与重试

当前看不到（**从 cloudflared 指标**）：

1. 每个 hostname 的请求量拆分
2. 每个 hostname 的延迟分位数
3. 入口层按路由聚合的 4xx/5xx

原因很简单：`cloudflared` 官方指标本身不暴露 hostname 标签，而仓库里也不再保留 Traefik 的 `router` 指标作为补充来源。

> ⚠️ 第 1 条自 2026-08-15 起**换了一条路**补上了：不是从 cloudflared，而是直接问
> Cloudflare Analytics API —— 见下面的
> [按域名的请求量与访问 IP 数](#按域名的请求量与访问-ip-数cloudflare-analytics-api)。
> 代价是粒度只有「天」、按域名只回溯 7–8 天，所以它替代不了实时的入口指标，
> 第 2、3 条依然看不到。

## 架构概览

```text
Internet
  -> Cloudflare DNS
  -> Cloudflare Tunnel
  -> cloudflared pods
  -> cilium-gateway-<gateway-name>.kube-system.svc:80
  -> HTTPRoute
  -> backend Services

metrics path:
cloudflared:2000 -> Prometheus / OTel Collector -> Grafana
```

## 副本数：两个集群都是 1

2026-08-13 起两侧 cloudflared 均为**单副本**，这是结论不是疏忽。隧道级冗余来自 cloudflared
自身——**单个进程持有 4 条边缘连接、跨 3–4 个 colo**（`cloudflared_tunnel_ha_connections` = 4/pod），
副本数只加 pod 级冗余。而历史上每一次 cloudflared 重启都是**节点级**事件（两副本同时死），
2 副本一次也没挡住。完整实测依据写在两份清单的文件尾注里：
`k8s/helm/manifests/cloudflare/cloudflare-tunnel.yaml` 与
`cloud/oracle/manifests/base/cloudflare-tunnel.yaml`。

☠️ **两侧都故意不带 PodDisruptionBudget**：单副本下 `minAvailable: 1` 会让
`disruptionsAllowed` 变成 0 而卡死 `kubectl drain`，`maxUnavailable: 1` 则恒定放行等于没约束。
要恢复 PDB 必须先把 replicas 提回 ≥2。

## 当前采集路径

### homelab

- `cloudflared` 在 `cloudflare` namespace 暴露 `:2000/metrics`
- `monitoring/cloudflared` ServiceMonitor 抓取（`k8s/helm/manifests/monitoring/cloudflared-servicemonitor.yaml`）

  ⚠️ **这条 2026-08-13 之前是假的**：本文档当时写着「homelab Prometheus 直接采集本集群
  `cloudflared` 指标」，`opentelemetry-collector.yaml` 的文件头也写着「含 cloudflared」，
  但实际上 homelab 从来没有过 cloudflared 的 scrape job，也没有任何 ServiceMonitor/PodMonitor
  —— `cloudflared-metrics` 这个 Service 自建成起就无人采集。判据是
  `curl -s $PROM/api/v1/targets | grep cloudflared`，**不是文档里怎么写的**。

### oracle-k3s

- `cloudflared` 在 `cloudflare` namespace 暴露 `:2000/metrics`
- oracle-k3s 的 OTel Collector 采集 `cloudflared` 指标后，通过 `prometheusremotewrite` 写回 homelab Prometheus

  ⚠️ 这里的 prometheus receiver 指向 **ClusterIP DNS 名**（`cloudflared-metrics.cloudflare.svc:2000`），
  抓的是 VIP，每次只随机命中一个 pod。单副本下无所谓，但**副本数一旦提回 ≥2 就分不出单副本死活**
  （挂掉一个，`ha_connections` 照样报 4）。homelab 侧不受影响：ServiceMonitor 抓的是
  Endpoints，每个 pod 一个 target。

### 已移除的旧采集项

- `traefik-metrics` NodePort
- `prometheus/traefik` receiver
- 基于 Traefik router 的 per-domain dashboard

## 推荐面板

现阶段 Grafana 面板应聚焦在 tunnel 健康，而不是 hostname 维度。

建议保留以下图表：

1. Tunnel up/down 状态
2. `cloudflared_tunnel_ha_connections`
3. `cloudflared_tunnel_concurrent_requests_per_tunnel`
4. `rate(cloudflared_tunnel_response_by_code_total[5m])` by `status_code`
5. `cloudflared_tunnel_server_locations`

### ☠️ 指标名与标签的坑（2026-08-13 逐条对着 `/metrics` 核过）

本节此前列的四个名字里有三个**根本不存在**，面板不可能出过数据。真实情况：

| 文档曾经写的（不存在） | 真实的 |
|------|--------|
| `cloudflared_tunnel_total_requests` | `cloudflared_tunnel_requests_total`（⚠️ 但见下，恒为 0） |
| `cloudflared_tunnel_request_errors` | `cloudflared_tunnel_request_errors_total` |
| `cloudflared_tunnel_active_streams` | `cloudflared_tunnel_concurrent_requests_per_tunnel` |
| `server_locations` 的 `location` 标签 | `edge_location`（另有 `connection_id`） |

⚠️ 更坑的是：**即使把 `cloudflared_tunnel_requests_total` 的名字写对，它实测也恒为 0**
（四个 pod 全 0，同一时刻 `concurrent_requests_per_tunnel` 是 3），当前 cloudflared 版本已废弃它。
隧道侧真正有数的请求计数器是 `cloudflared_tunnel_response_by_code_total{status_code}`。
判活优先用 `ha_connections`。

按 hostname / 路由的 RED 依然只能看 cilium-envoy 的 `envoy_cluster_upstream_rq`
（cloudflared 指标不带 hostname 标签），见 `k8s/helm/manifests/monitoring/cilium-envoy-servicemonitor.yaml`。

## 常用 PromQL

```promql
# 每个集群的 tunnel HA 连接数（单副本下正常值 = 4）
sum by (cluster) (cloudflared_tunnel_ha_connections)

# 每个集群当前在途请求数
sum by (cluster) (cloudflared_tunnel_concurrent_requests_per_tunnel)

# 每个集群最近 5 分钟按状态码的响应速率
sum by (cluster, status_code) (rate(cloudflared_tunnel_response_by_code_total[5m]))

# 错误请求速率
sum by (cluster) (rate(cloudflared_tunnel_request_errors_total[5m]))

# 按 PoP 观察边缘连接
sum by (cluster, edge_location) (cloudflared_tunnel_server_locations)
```

## 故障排查

### `cloudflared` 指标无数据

1. 检查 Pod 是否健康：

```bash
kubectl get pods -n cloudflare
```

2. 检查 Service 和端点：

```bash
kubectl get svc,endpoints -n cloudflare | grep cloudflared
```

3. 在集群内验证指标端点：

```bash
kubectl exec -n cloudflare deploy/cloudflared -- curl -fsS http://127.0.0.1:2000/metrics | head
```

4. 检查采集侧：

- homelab: Prometheus target 页面
- oracle-k3s: OTel Collector 日志与 `prometheusremotewrite` exporter 状态

### Tunnel 在线但业务不可达

这通常不是指标链路问题，而是 Gateway 或后端服务问题。按下面顺序检查：

1. `cloudflared` 日志里是否能看到转发错误
2. `cilium-gateway-<gateway-name>` Service 是否存在
3. `Gateway` 和 `HTTPRoute` 是否已 `Accepted`
4. backend Service / Endpoint 是否正常

可用命令：

```bash
kubectl get svc -n kube-system | grep cilium-gateway
kubectl get gateway,httproute -A
kubectl describe httproute -A
```

## 按域名的请求量与访问 IP 数（Cloudflare Analytics API）

2026-08-15 起，「哪个域名、被多少个不同 IP 访问」这一层由 **cf-analytics-exporter** 提供。
它不碰 cloudflared 指标，而是每 6h 调一次 Cloudflare GraphQL Analytics API，把聚合结果
以 Prometheus 指标暴露出来。

- 清单 `k8s/helm/manifests/monitoring/cf-analytics-exporter/`（Deployment + Service +
  ConfigMap + ExternalSecret，落在 homelab `monitoring` ns 的 `k8s-worker-106`）
- 抓取 `k8s/helm/values/kube-prometheus-stack.yaml` 的 `additionalScrapeConfigs`
  （static target，显式打 `cluster=homelab`）
- 面板 Grafana → Platform → **Cloudflare / 公网流量（按域名访问 IP）**（uid `cf-analytics-overview`）
- 告警 `k8s/helm/manifests/monitoring/alerts/cf-analytics-alerts.yaml`
- **为什么是自写的而不是现成 exporter** →
  [decisions/cf-analytics-custom-exporter.md](../decisions/cf-analytics-custom-exporter.md)
  （官方与 lablabs 两个都实测否决过，别重复调研）

指标（**全部 gauge**，值的口径是「某个完整 UTC 自然日」，`date` 是标签不是时间戳）：

| 指标 | 含义 |
|------|------|
| `cf_analytics_daily_client_ips{host,date}` | 该域名当天的**独立客户端 IP 数**；`host="__total__"` 是跨域名再去重的全站值 |
| `cf_analytics_daily_requests{host,date}` | 该域名当天的请求数；同样有 `__total__` |
| `cf_analytics_daily_uniques{date}` | Cloudflare 自己算的全站独立访客（edge 去重） |
| `cf_analytics_scrape_success` / `cf_analytics_last_success_timestamp_seconds` | 抓取健康 |
| `cf_analytics_host_window_days` / `cf_analytics_host_days_failed` / `cf_analytics_rows_truncated` | 窗口与数据质量 |

### 三条实测硬限制（2026-08-15 用本仓库那把 token 逐条打过，别照文档猜）

1. ☠️ **两个数据集的保留期差 4 倍**。按域名/IP 拆分的 `httpRequestsAdaptiveGroups` 免费版
   只留 **1w1d（约 8 天）**，更早直接报 `cannot request data older than 1w1d`；
   全站的 `httpRequests1dGroups` 实测 30 天可读。所以面板上「全站趋势 14 天、按域名只有
   7–8 天」是套餐决定的，不是配置漏了。exporter 故意多试一天，靠服务端的报错定位边界，
   而不是在代码里写死一个会随套餐变的常量。
2. ☠️ **`httpRequestsAdaptiveGroups` 单次查询时间跨度 ≤ 1 天**，必须逐日查再合并。
   一轮刷新 = 1 次 uniques + 最多 8 次逐日，共约 9 次调用。
3. ⚠️ **该数据集没有 `uniq { uniques }` 字段**（实测报 `unknown field "uniq"`）。
   独立 IP 只能按 `clientIP` 维度拉回来在本地去重 —— 单日约 2500 行，API 硬上限 10000 行，
   撞上限会低估 IP 数，`cf_analytics_rows_truncated` 就是报这个的。

### 读数时容易搞错的三件事

- **`daily_uniques` ≠ `daily_client_ips{host="__total__"}`**。前者是 Cloudflare 的 uniq
  （口径不公开、adaptive 数据集有自适应采样），后者是我们自己数的 IP。2026-08-14 分别是
  2376 和 2416 —— 接近但不该相等，**不要拿它们互相对账**。
- **各域名的 IP 数之和 > 全站 IP 数**。同一个 IP 常常访问多个子域，全站那格跨域名去重过。
- **相当一部分「流量」是自建探测**。Uptime Kuma / ArgoCD / 各种健康检查会让某些域名出现
  「IP 数个位数、请求数上千」的组合。面板里的「人均请求」列就是拿来一眼认出这种的。

☠️ **不导出任何客户端 IP 本身**，只导出去重后的计数：原始 IP 是访客 PII，放进 label 还会
把基数炸到几千。仓库「不落公网 IP」的硬约束同样适用于指标标签。

### 与 ingress-traffic 面板的分工

两块面板看着像，但量的不是同一件事，排查时别混用：

| | 本节（Cloudflare Analytics） | `ingress-traffic-overview`（cilium-envoy） |
|---|---|---|
| 位置 | Cloudflare **边缘**，缓存命中/WAF 拦截**都算** | Cloudflare **之后**，服务实际收到的量 |
| 维度 | 域名（`host`）+ 独立 IP 数 | 服务（`ns_svc`）+ 状态码 |
| 粒度 | 天 | 秒级实时 |
| 回溯 | 按域名 7–8 天 / 全站 14 天 | 中枢 Prometheus retention（7d）|

两者对不上是正常的：差额就是边缘缓存命中 + WAF 拦截 + 直接由 Cloudflare 应答的部分。

## 限制与后续方向

hostname 级的**实时**入口指标依然没有（上一节是天粒度的事后聚合）。真要做，两个方向：

1. 研究 Cilium Gateway / Envoy 暴露的可消费路由指标，再决定是否接入
2. 在应用层补充统一访问日志或 OTel HTTP server metrics，而不是重新引入 Traefik

在此之前，这份文档的定位就是：把 Tunnel 视为一层“连通性和负载入口”的健康信号源，
域名维度的「有多少人来过」由 Cloudflare Analytics 那条旁路回答。
