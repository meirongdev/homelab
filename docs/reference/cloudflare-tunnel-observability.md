# Cloudflare Tunnel Observability

> Last updated: 2026-10-28
> Status: 生效事实

入口路径 `Cloudflare DNS -> Cloudflare Tunnel -> Cilium Gateway API -> Services`（见
[networking-ingress.md](networking-ingress.md)）。本文讲隧道这一层能观测到什么、看不到什么。
Traefik 及其按 router 拆域名的指标已移除。

## 观测范围

cloudflared 指标能看到：是否在线、每个隧道的 HA 连接数、在途请求与按状态码的响应、边缘 PoP
连接分布、隧道级错误。

看不到（cloudflared 官方指标不带 hostname 标签）：

1. 每个 hostname 的请求量拆分
2. 每个 hostname 的延迟分位数
3. 入口层按路由聚合的 4xx/5xx

第 1 条由 Cloudflare Analytics API 补上，但只有天粒度（见文末）。按服务（`ns_svc`，非域名）的实时
RED 看 cilium-envoy 的 `envoy_cluster_upstream_rq`
（`k8s/helm/manifests/monitoring/cilium-envoy-servicemonitor.yaml`）。

☠️ **`ha_connections = 4` 不等于隧道通**。2026-08-26 homelab 公网 530 了 15 分钟，它全程恒为 4
（cloudflared 握着僵尸连接不自知），集群内指标一个都没看见，抓到它的是 oracle 上 Uptime Kuma 的跨集群
黑盒探测。判断隧道真通看那路探测；`ha_connections` 只用来看 cloudflared 自认的连接状态。
复盘 [records/2026-08-26-cloudflared-zombie-connections-530.md](../records/2026-08-26-cloudflared-zombie-connections-530.md)。

## 副本数：两个集群都是 1

单副本是结论不是疏忽。隧道级冗余来自 cloudflared 自身：**单个进程持有 4 条边缘连接、跨 3–4 个
colo**，副本数只加 pod 级冗余；而 cloudflared 的重启历来是节点级事件（两副本同时死），2 副本一次也
没挡住。实测依据在两份清单的文件尾注：`k8s/helm/manifests/cloudflare/cloudflare-tunnel.yaml` 与
`cloud/oracle/manifests/base/cloudflare-tunnel.yaml`。

☠️ **两侧都故意不带 PodDisruptionBudget**：单副本下 `minAvailable: 1` 让 `disruptionsAllowed` 变成 0、
卡死 `kubectl drain`，`maxUnavailable: 1` 则恒定放行等于没约束。要恢复 PDB 必须先把 replicas 提回 ≥2。

## 当前采集路径

两侧的 `cloudflared:2000` 指标最终都进 homelab Prometheus，在 Grafana 里看。

> ⚠️ `:2000` 上不只有 `/metrics`，还挂着 `/ready` 和 `/debug/*`，而且整个集群内都能访问
> （两集群都没有 NetworkPolicy）。2026.10.4 之前，`/debug/vars` 会原样吐出进程的 argv，
> 当时 token 就写在 argv 里。2026-10-27 起两侧都升到 2026.10.5，token 改由环境变量
> `TUNNEL_TOKEN` 注入，不再进 argv。原因见两份 `cloudflare-tunnel.yaml` 清单里的注释。

- **homelab**：`monitoring/cloudflared` ServiceMonitor 抓 `cloudflare` ns 的 `:2000/metrics`
  （`k8s/helm/manifests/monitoring/cloudflared-servicemonitor.yaml`），抓的是 Endpoints，每个 pod 一个
  target。⚠️ 是否真被采集只认 `curl -s $PROM/api/v1/targets | grep cloudflared`，不认文档或注释。
- **oracle-k3s**：OTel Collector 的 prometheus receiver 采集后经 `prometheusremotewrite` 写回 homelab
  Prometheus。⚠️ receiver 指向 ClusterIP DNS 名（`cloudflared-metrics.cloudflare.svc:2000`），抓的是 VIP，
  每次随机命中一个 pod：单副本下无所谓，**副本数一旦提回 ≥2 就分不出单副本死活**（挂掉一个，
  `ha_connections` 照样报 4），届时要改用 PodMonitor 或 headless Service。

## 指标名与面板

☠️ 名字以 `/metrics` 实际输出为准（2026-08-13 逐条核过），常见写法有三个根本不存在：

| 不存在的写法 | 真实的 |
|------|--------|
| `cloudflared_tunnel_total_requests` | `cloudflared_tunnel_requests_total`（⚠️ 但恒为 0，见下） |
| `cloudflared_tunnel_request_errors` | `cloudflared_tunnel_request_errors_total` |
| `cloudflared_tunnel_active_streams` | `cloudflared_tunnel_concurrent_requests_per_tunnel` |
| `server_locations` 的 `location` 标签 | `edge_location`（另有 `connection_id`） |

⚠️ **`cloudflared_tunnel_requests_total` 写对了也恒为 0**（当前版本已废弃）。隧道侧真正有数的请求
计数器是 `cloudflared_tunnel_response_by_code_total{status_code}`。

目前没有隧道看板。要做的话只聚焦隧道健康，不做 hostname 维度：up/down、
`cloudflared_tunnel_ha_connections`、`cloudflared_tunnel_concurrent_requests_per_tunnel`、按 `status_code` 的
`rate(cloudflared_tunnel_response_by_code_total[5m])`、`cloudflared_tunnel_server_locations`。

## 常用 PromQL

在 Grafana 的 homelab Prometheus 数据源里跑（oracle 的序列经 remote-write 也在这里，按 `cluster` 区分）。

```promql
# 每个集群的 tunnel HA 连接数（单副本下正常值 = 4；只是 cloudflared 自认的状态）
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

`<ctx>` 是 `k3s-homelab` 或 `oracle-k3s`，任意目录执行。

### `cloudflared` 指标无数据

```bash
kubectl --context <ctx> get pods -n cloudflare
kubectl --context <ctx> get svc,endpoints -n cloudflare | grep cloudflared
# 直接看指标端点：先端口转发（不依赖镜像里有没有 curl），另开一个终端再 curl
kubectl --context <ctx> -n cloudflare port-forward deploy/cloudflared 2000:2000
curl -fsS http://127.0.0.1:2000/metrics | head
```

再查采集侧：homelab 看 Prometheus `/api/v1/targets`；oracle-k3s 看 OTel Collector 日志与
`prometheusremotewrite` exporter 状态。

### Tunnel 在线但业务不可达

通常是 Gateway 或后端问题。依次查 cloudflared 日志里的转发错误、`cilium-gateway-<gateway-name>`
Service、`Gateway`/`HTTPRoute` 是否 `Accepted`、后端 Service/Endpoint：

```bash
kubectl --context <ctx> get svc -n kube-system | grep cilium-gateway
kubectl --context <ctx> get gateway,httproute -A
kubectl --context <ctx> describe httproute -A
```

公网 530 而上面全正常时，先怀疑僵尸连接（见「观测范围」末条）。

## 按域名的请求量与访问 IP 数（Cloudflare Analytics API）

cf-analytics-exporter 每 6h 调一次 Cloudflare GraphQL Analytics API，补的是「看不到」的第 1 条：
天粒度、按域名只回溯 7–8 天，替代不了实时入口指标。口径、分类法、指标、PromQL、免费版能力边界的
唯一真相源是 **[public-traffic-analysis.md](public-traffic-analysis.md)**，这里只留两条：

- ☠️ **它与 `ingress-traffic-overview` 量的不是同一件事**：它在 Cloudflare 边缘（缓存命中/WAF 拦截
  都算），Envoy 那一侧是 Cloudflare 之后服务实收的量。两者对不上是正常的，差额就是边缘消化掉的部分。
- ☠️ **原始访问量里很大一块是自建监控**（Uptime Kuma / Alertmanager 绕公网回来），看数前先读那份文档。

清单 `k8s/helm/manifests/monitoring/cf-analytics-exporter/` · 面板 Grafana → Platform →
「Cloudflare / 公网访问分析」 · 告警 `alerts/cf-analytics-alerts.yaml` · 选型依据
[decisions/cf-analytics-custom-exporter.md](../decisions/cf-analytics-custom-exporter.md)

hostname 级的实时入口指标至今没有。要做的话方向是 Cilium Gateway / Envoy 的路由指标，或应用层的
访问日志 / OTel HTTP server metrics，不是重新引入 Traefik。
