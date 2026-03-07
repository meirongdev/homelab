# Cloudflare Tunnel Observability

当前架构的入口路径为：`Cloudflare DNS -> Cloudflare Tunnel -> Cilium Gateway API -> Services`。

本仓库已经移除 Traefik 和基于 Traefik router label 的按域名流量拆分方案，因此这里仅记录仍然有效的 Tunnel 健康观测方式，以及现阶段看不到什么。

## 观测范围

可以观测：

1. `cloudflared` 是否在线
2. 每个隧道的 HA 连接数
3. 活跃 streams 和总请求量
4. 边缘 PoP 连接分布
5. 隧道级错误与重试

当前看不到：

1. 每个 hostname 的请求量拆分
2. 每个 hostname 的延迟分位数
3. 入口层按路由聚合的 4xx/5xx

原因很简单：`cloudflared` 官方指标本身不暴露 hostname 标签，而仓库里也不再保留 Traefik 的 `router` 指标作为补充来源。

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

## 当前采集路径

### homelab

- `cloudflared` 在 `cloudflare` namespace 暴露 `:2000/metrics`
- homelab Prometheus 直接采集本集群 `cloudflared` 指标

### oracle-k3s

- `cloudflared` 在 `cloudflare` namespace 暴露 `:2000/metrics`
- oracle-k3s 的 OTel Collector 采集 `cloudflared` 指标后，通过 `prometheusremotewrite` 写回 homelab Prometheus

### 已移除的旧采集项

- `traefik-metrics` NodePort
- `prometheus/traefik` receiver
- 基于 Traefik router 的 per-domain dashboard

## 推荐面板

现阶段 Grafana 面板应聚焦在 tunnel 健康，而不是 hostname 维度。

建议保留以下图表：

1. Tunnel up/down 状态
2. `cloudflared_tunnel_ha_connections`
3. `cloudflared_tunnel_active_streams`
4. `rate(cloudflared_tunnel_total_requests[5m])`
5. `cloudflared_tunnel_request_errors`
6. `cloudflared_tunnel_server_locations`

## 常用 PromQL

```promql
# 每个集群的 tunnel HA 连接数
sum by (cluster) (cloudflared_tunnel_ha_connections)

# 每个集群当前活跃 streams
sum by (cluster) (cloudflared_tunnel_active_streams)

# 每个集群最近 5 分钟请求速率
sum by (cluster) (rate(cloudflared_tunnel_total_requests[5m]))

# 错误请求速率
sum by (cluster) (rate(cloudflared_tunnel_request_errors[5m]))

# 按 PoP 观察边缘连接
sum by (cluster, location) (cloudflared_tunnel_server_locations)
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

## 限制与后续方向

如果未来确实需要 hostname 级入口指标，有两个更合理的方向：

1. 研究 Cilium Gateway / Envoy 暴露的可消费路由指标，再决定是否接入
2. 在应用层补充统一访问日志或 OTel HTTP server metrics，而不是重新引入 Traefik

在此之前，这份文档的定位就是：只把 Tunnel 视为一层“连通性和负载入口”的健康信号源。
