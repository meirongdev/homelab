# Cloudflare Tunnel Observability

监控两个 K8s 集群（`homelab` 和 `oracle-k3s`）的 Cloudflare Tunnel 健康状态与各域名流量。

## 架构概述

```
                    Cloudflare Edge
                         │
          ┌──────────────┴──────────────┐
          │                             │
    homelab-k3s                   oracle-k3s
    cloudflared ─── metrics:2000  cloudflared ─── metrics:2000
    NodePort: 31200               NodePort: 31201
          │                             │
    Traefik ──────── metrics:9100  Traefik ──────── metrics:9100
    NodePort: 31910               NodePort: 31911
          │                             │
          └──────────┐   ┌─────────────┘
                     ▼   ▼
               homelab Prometheus
               (scrapes all 4 endpoints via Tailscale)
                     │
               homelab Grafana
               Dashboard: "Cloudflare Tunnel & Per-Domain Traffic"
```

## 为什么需要 Traefik metrics

**cloudflared 不提供 per-hostname 流量标签。** 官方 [cloudflared metrics](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/monitor-tunnels/metrics/) 只暴露全局计数器（tunnel 总请求数、活跃 streams 数等），无法区分 `book.meirong.dev` vs `rss.meirong.dev` 的流量。

**Traefik** 是真正处理路由的组件，它的 `traefik_router_requests_total` 指标带有 `router` 标签，该标签对应每个 HTTPRoute 的 hostname，因此可以实现 per-domain 流量可视化。

## 域名分布

| 集群 | 域名 | Traefik router label |
|------|------|----------------------|
| homelab | `book.meirong.dev` | `calibre` |
| homelab | `grafana.meirong.dev` | `grafana` |
| homelab | `vault.meirong.dev` | `vault` |
| homelab | `argocd.meirong.dev` | `argocd` |
| homelab | `backup.meirong.dev` | `kopia` |
| oracle-k3s | `rss.meirong.dev` | `miniflux` |
| oracle-k3s | `home.meirong.dev` | `homepage` |
| oracle-k3s | `status.meirong.dev` | `uptime-kuma` |
| oracle-k3s | `n8n.meirong.dev` | `n8n` |

## 已部署的资源

### NodePort 一览

| 集群 | 服务 | NodePort | 用途 |
|------|------|----------|------|
| homelab | `cloudflare/cloudflared-metrics` | **31200** | cloudflared metrics |
| homelab | `kube-system/traefik-metrics` | **31910** | Traefik per-domain metrics |
| oracle-k3s | `cloudflare/cloudflared-metrics` | **31201** | cloudflared metrics |
| oracle-k3s | `kube-system/traefik-metrics` | **31911** | Traefik per-domain metrics |

### Prometheus Scrape Jobs（homelab）

```yaml
# kube-prometheus-stack.yaml additionalScrapeConfigs:
- job_name: 'cloudflared-homelab'         # 100.107.254.112:31200
- job_name: 'cloudflared-oracle-k3s'      # 100.107.166.37:31201
- job_name: 'traefik-homelab'             # 100.107.254.112:31910
- job_name: 'traefik-oracle-k3s'          # 100.107.166.37:31911
```

### Oracle Prometheus Agent（本地 scrape + remote_write）

```yaml
# prometheus-agent-values.yaml additionalScrapeConfigs:
- job_name: 'cloudflared'   # cloudflared-metrics.cloudflare.svc:2000
- job_name: 'traefik'       # traefik-metrics.kube-system.svc:9100
```

## Grafana Dashboard

**Dashboard UID**: `cloudflare-tunnel-traffic`  
**Dashboard 名称**: `Cloudflare Tunnel & Per-Domain Traffic`  
**Tags**: `cloudflare`, `tunnel`, `traefik`, `traffic`, `per-domain`, `multi-cluster`

ConfigMap 自动通过 kube-prometheus-stack sidecar 加载（label: `grafana_dashboard: "1"`）。

### Dashboard 面板说明

#### 🔒 Cloudflare Tunnel Health
| 面板 | 指标 | 说明 |
|------|------|------|
| Tunnel Status | `cloudflared_tunnel_ha_connections > 0` | 隧道是否在线 |
| HA Connections | `cloudflared_tunnel_ha_connections` | 每集群 HA 连接数（通常 4 个） |
| Active Streams | `cloudflared_tunnel_active_streams` | 当前活跃请求流 |
| Total Tunnel Req/s | `rate(cloudflared_tunnel_total_requests)` | 总请求速率 |
| PoP Connections | `cloudflared_tunnel_server_locations` | 连接的 Cloudflare 边缘节点 |
| Errors & Retries | `cloudflared_tunnel_request_errors` | 隧道错误与心跳重试 |

#### 🌐 Per-Domain Traffic（Traefik Router Metrics）
| 面板 | 指标 | 说明 |
|------|------|------|
| Request Rate by Domain | `traefik_router_requests_total` | 每域名请求速率，按 `router` 标签区分 |
| Response Latency (p50/p95) | `traefik_router_request_duration_seconds_bucket` | 每域名响应延迟分位数 |
| 4xx/5xx Errors by Domain | `traefik_router_requests_total{code=~"[45].."}`  | 每域名错误率 |
| Domain Summary Table | 聚合查询 | 实时汇总：Req/s + Error % |

#### 🚦 HTTP Status Code Distribution
- 所有域名的状态码分布（2xx、3xx、4xx、5xx）

#### ⚡ Traefik Entrypoint Overview
- 入口点级别的请求速率和开放连接数

### 变量过滤器
- **Cluster**：`homelab` / `oracle-k3s` / All（自动从 Prometheus 发现）
- **Router / Domain**：动态列出所有 Traefik router（即每个 HTTPRoute）

## 启用说明

### Traefik 配置（已配置）

homelab 的 `traefik-config.yaml` 和 oracle-k3s 的 `base/traefik-config.yaml` 均已添加：

```yaml
metrics:
  prometheus:
    addRoutersLabels: true    # 关键：开启 per-router/hostname 标签
    addServicesLabels: true
    addEntryPointsLabels: true
```

### ArgoCD 同步

dashboard ConfigMap 通过 `monitoring-dashboards` ArgoCD Application 自动部署：

```bash
# 手动触发同步（无需等待 3 分钟轮询）
cd k8s/helm && just argocd-sync
```

## 常用 PromQL 查询

```promql
# 某域名最近 5 分钟的请求速率（例：rss.meirong.dev）
sum(rate(traefik_router_requests_total{router=~".*miniflux.*"}[5m]))

# 所有域名的错误率排行
topk(10, sum by (cluster, router) (rate(traefik_router_requests_total{code=~"[45].."}[5m]))
  / sum by (cluster, router) (rate(traefik_router_requests_total[5m])))

# cloudflared 隧道健康（HA 连接数应 >= 4）
sum by (cluster) (cloudflared_tunnel_ha_connections)

# Traefik router 延迟 p99
histogram_quantile(0.99,
  sum by (router, le) (rate(traefik_router_request_duration_seconds_bucket[5m])))
```

## 故障排查

### Traefik metrics 无数据
1. 检查 `traefik-metrics` NodePort Service 是否创建：
   ```bash
   kubectl get svc -n kube-system traefik-metrics
   ```
2. 验证 metrics 端点可达（在 K8s 节点上）：
   ```bash
   curl http://localhost:9100/metrics | grep traefik_router
   ```
3. 确认 HelmChartConfig 已生效（Traefik pod 需重启）：
   ```bash
   kubectl rollout restart deployment/traefik -n kube-system
   ```

### cloudflared metrics 无数据
1. 检查 NodePort Service：
   ```bash
   # homelab
   kubectl get svc -n cloudflare cloudflared-metrics
   # oracle-k3s
   kubectl get svc -n cloudflare cloudflared-metrics
   ```
2. 验证 Prometheus scrape targets 状态：
   Grafana → Explore → Prometheus → `{job="cloudflared-homelab"}`

### router 标签格式
Traefik 对 Gateway API HTTPRoute 生成的 router 标签格式为：
`<namespace>-<httproute-name>-<random>@kubernetesgateway`

可用以下查询确认实际标签值：
```promql
group by (router) (traefik_router_requests_total)
```
