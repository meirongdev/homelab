# Uptime Kuma 部署实施计划

**日期：** 2026-02-21
**状态：** ✅ 已完成 (Completed 2026-02-21)

## 目标
部署 Uptime Kuma 到 Kubernetes 集群，用于监控 Homelab 各项服务的外部可用性、证书状态及网络延迟。

---

## 架构设计

### 1. 资源规格
| 组件 | 规格 |
|------|------|
| **Namespace** | `personal-services` |
| **镜像** | `louislam/uptime-kuma:1` |
| **存储** | 10Gi (NFS / `nfs-client` StorageClass) |
| **外部访问** | `status.meirong.dev` (Cloudflare Tunnel -> Traefik) |

### 2. Kubernetes 资源
*   **PersistentVolumeClaim**: `uptime-kuma-pvc` 用于持久化 SQLite 数据库。
*   **Deployment**: 运行 Uptime Kuma 容器，挂载数据目录 `/app/data`。
*   **Service**: ClusterIP 暴露端口 3001。
*   **HTTPRoute**: 在 `manifests/gateway.yaml` 中定义路由规则。

---

## 实施步骤

### Task 1: 编写清单 (Manifests)
- 创建 `k8s/helm/manifests/uptime-kuma.yaml`，包含 PVC, Service, Deployment。
- 更新 `k8s/helm/manifests/gateway.yaml`，添加 `status.meirong.dev` 的 HTTPRoute 规则。

### Task 2: GitOps 注册
- 修改 `argocd/applications/personal-services.yaml`，在 `include` 列表中添加 `uptime-kuma.yaml`。

### Task 3: 域名解析
- 修改 `cloudflare/terraform/terraform.tfvars`，添加 `status` 子域名。
- 执行 `cd cloudflare/terraform && just apply`。

### Task 4: 验证与配置
- 在 ArgoCD 中确认应用同步状态。
- 访问 `https://status.meirong.dev` 进行初始化配置。
- 设置报警通知（Discord/Telegram）。

---

## 实际实施说明

- 监控配置通过 ArgoCD **PostSync Hook Job** 自动完成，无需手动在 UI 中添加
- 监控列表定义在 `manifests/uptime-kuma.yaml` 的 `uptime-kuma-provisioner` ConfigMap 中
- 新增服务时，只需在 ConfigMap 的 `MONITORS` 列表追加一条记录并 `git push` 即可
- Admin 凭证存储在 Vault `secret/homelab/uptime-kuma`，通过 ESO 同步为 K8s Secret

---

## 监控端点配置说明（2026-02-27 更新）

所有服务启用了 SSO（oauth2-proxy ForwardAuth），外部访问均返回 302。
Uptime Kuma 通过**内部 ClusterIP 直接访问**服务，完全绕过 SSO 和 Cloudflare Tunnel。

### oracle-k3s 本地服务（直接 K8s DNS）

| 监控名称 | 内部 URL | 期望状态码 | 说明 |
|---------|---------|-----------|------|
| Homepage | `http://homepage.homepage.svc:3000` | 200 | 直接访问 |
| Miniflux | `http://miniflux.rss-system.svc:8080` | 200 | HEAD 请求对 Miniflux 返回 405，内部 GET 正常 |
| IT-Tools | `http://it-tools.personal-services.svc:80` | 200 | 直接访问 |
| Squoosh | `http://squoosh.personal-services.svc:8080` | 200 | 直接访问 |
| Stirling-PDF | `http://stirling-pdf.personal-services.svc:8080/login` | 200 | 根路径返回 401（自带认证），`/login` 返回 200 |
| Uptime Kuma | `http://uptime-kuma.personal-services.svc:3001` | 200 | 自监控 |

### k3s-homelab 远端服务（通过 Tailscale 子网路由访问 ClusterIP）

> **网络路径**：oracle pod → oracle node cni0 → iptables MASQUERADE → tailscale0 → homelab node → homelab ClusterIP
>
> **前提**：oracle node 上需有 iptables-legacy MASQUERADE 规则：
> ```bash
> iptables-legacy -t nat -A POSTROUTING -s 10.52.0.0/16 -d 10.43.0.0/16 -j MASQUERADE
> iptables-legacy -t nat -A POSTROUTING -s 10.52.0.0/16 -d 10.42.0.0/16 -j MASQUERADE
> ```
> homelab 服务 CIDR `10.43.0.0/16` 已通过 Tailscale 子网路由（table 52）可达。

| 监控名称 | 内部 ClusterIP URL | 期望状态码 | 说明 |
|---------|------------------|-----------|------|
| Grafana | `http://10.43.70.241:80/api/health` | 200 | `/api/health` 无需认证 |
| HashiCorp Vault | `http://10.43.29.201:8200/v1/sys/health` | 200 | `/v1/sys/health` 无需认证，初始化且已解封时返回 200 |
| Calibre-Web | `http://10.43.206.163:8083/login` | 200 | 根路径 302→`/login`，`/login` 页面直接返回 200 |
| ArgoCD | `https://10.43.158.192/` | 200 | HTTP→307→HTTPS，HTTPS 直接返回 200（忽略自签名证书）|
| Kopia Backup | `https://10.43.114.55:51515` | 401 | 使用 HTTPS + 基础认证，401 代表服务正常运行 |

### Provisioner 运行方式

oracle-k3s 没有 ArgoCD，provisioner 为独立 Job，需手动触发：

```bash
cd cloud/oracle
just provision-uptime-kuma
```

或直接：
```bash
kubectl --context oracle-k3s delete job uptime-kuma-provisioner -n personal-services --ignore-not-found
kubectl --context oracle-k3s apply -f manifests/uptime-kuma/provisioner.yaml
kubectl --context oracle-k3s logs job/uptime-kuma-provisioner -n personal-services -f
```

## 回滚方案
1. 从 `personal-services.yaml` 的 include 列表中移除。
2. `kubectl delete -f k8s/helm/manifests/uptime-kuma.yaml`。
