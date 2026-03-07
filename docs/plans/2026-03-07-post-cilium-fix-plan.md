# Cilium 引入后架构调整与服务修复方案

> 日期: 2026-03-07
> 状态: ✅ 全部修复完成
> 背景: homelab K3s 集群从 Flannel 切换到 Cilium CNI 后，多个服务出现异常。本文档总结问题、根因分析、修复过程和架构调整建议。

## 当前集群状态总览

### Homelab 集群

| 服务 | 状态 | 问题 |
|------|------|------|
| Cilium | ✅ 正常 | 209/209 controllers healthy, 1/1 node reachable |
| Traefik | ✅ 正常 | Running, Gateway API 正常 |
| CoreDNS | ✅ 正常 | Running |
| ArgoCD | ✅ 正常 | 所有组件 Running |
| Vault | ✅ 正常 | Running, unsealed |
| ESO | ✅ 正常 | ExternalSecrets synced |
| Grafana/Prometheus/Loki/Tempo | ✅ 正常 | LGTM stack running |
| Calibre-Web | ✅ 正常 | Running |
| Gotify | ✅ 正常 | Running |
| Kopia | ✅ 正常 | Running |
| NFS Provisioner | ✅ 正常 | Running |
| **ZITADEL** | ✅ 已修复 | masterkey 截断为 32 字节，setup 完成 |
| **Cloudflared** | ✅ 已修复 | 强制 HTTP/2 协议，2/2 pod 正常 |
| **Metrics Server** | ✅ 已修复 | hostNetwork: true + port 10251 |
| **helm-install-zitadel** | ✅ 已修复 | 删除旧 Job，K3s 重建成功 |

### Oracle 集群

| 服务 | 状态 | 问题 |
|------|------|------|
| 所有核心服务 | ✅ 正常 | — |
| **RSSHub 旧 RS** | ✅ 已清理 | 旧 ReplicaSet 已删除 |

### 外部可达性

| URL | 状态 | 说明 |
|-----|------|------|
| book.meirong.dev | 302 | ✅ SSO 重定向正常 |
| notify.meirong.dev | 302 | ✅ SSO 重定向正常 |
| grafana.meirong.dev | 302 | ✅ SSO 重定向正常 |
| argocd.meirong.dev | 200 | ✅ 不走 SSO |
| auth.meirong.dev | 302 | ✅ ZITADEL 登录页正常 |
| home.meirong.dev | 200 | ✅ oracle-k3s |
| tool.meirong.dev | 200 | ✅ oracle-k3s |
| status.meirong.dev | 200 | ✅ oracle-k3s |
| rss.meirong.dev | 200 | ✅ oracle-k3s |

## 问题根因分析

### 问题 1: ZITADEL Setup 失败 (Critical) — ✅ 已修复

**现象**: `zitadel-setup` Job 持续失败，错误: `masterkey must be 32 bytes, but is 44`

**根因**: 上次会话修复 ZITADEL 时，在 Vault 中写入了 44 字符的 master-key (`6ac56c3da96d43a0b3bb631193e16fe4f52dfdd0616c`)。ZITADEL 要求 master key 为 **恰好 32 字节 (32 个 ASCII 字符)**。

**影响链**:
- ZITADEL 不启动 → `auth.meirong.dev` 返回 500
- SSO 不可用 → 所有受保护 homelab 服务 (book/grafana/vault/notify) 302 → 500
- `helm-install-zitadel` Job 死循环重试

**修复过程**:
1. `vault kv put secret/homelab/zitadel master-key=6ac56c3da96d43a0b3bb631193e16fe4 db-password=57226c513b294a1591f51e9d82a7ffd9` (截断为 32 字符)
2. `kubectl annotate externalsecret zitadel-masterkey -n zitadel force-sync=$(date +%s)` 强制 ESO 重新同步
3. 删除失败的 `helm-install-zitadel` Job → K3s HelmChart controller 自动重建
4. ZITADEL setup 成功运行完所有数据库迁移
5. `auth.meirong.dev` 恢复 ZITADEL Console 登录页

### 问题 2: Cloudflared QUIC 超时 (High) — ✅ 已修复

**现象**: 2 个新 cloudflared pod 无法与 Cloudflare Edge 建立 QUIC 连接，持续 CrashLoop。1 个旧 pod 仍在工作（Cilium 替换前的连接）。

**根因**: 
- Git `main` 分支的 `cloudflare-tunnel.yaml` 没有 `--protocol http2` 参数
- Cloudflared 默认使用 QUIC (UDP/443)
- Cilium VXLAN 隧道 + IPTables masquerading 下，QUIC 握手超时
- 本地已修改 manifest 添加 `--protocol http2`，但**未 commit/push**
- ArgoCD 从 `main` 同步 → 部署的依然是默认 QUIC 版本

**修复过程**:
1. `git commit` cloudflare-tunnel.yaml (含 `--protocol http2` + cpu limit)
2. `git push origin main` → commit `eb56230`
3. `just argocd-sync` 触发立即同步
4. 2/2 新 pod Running，logs 显示 `protocol=http2` 连接到 sin06/sin07/sin08/sin22

### 问题 3: Metrics Server 不可用 (Medium)

**现象**: `metrics-server` 无法抓取 kubelet，报 `dial tcp 10.10.10.10:10250: connect: connection refused`

**根因分析**:
- kubelet 在节点上**确实监听** 10250 端口 (已通过 Tailscale IP 确认 `ss -tlnp | grep 10250`)
- 但 Pod 通过 Cilium 网络路径访问宿主 IP 10.10.10.10 时被拒
- 可能原因:
  - Cilium routing mode `Host: Legacy` 下 Pod→Host 流量走 iptables，可能未正确 SNAT
  - K3s 内置 metrics-server 参数使用 `--kubelet-preferred-address-types=InternalIP` 但在 Cilium 下该路径不通

**修复方案**: 
- 方案 A: 在 Cilium values 中启用 `hostPort.enabled: true` 或设置 `bpf.masquerade: true`
- 方案 B (推荐): 确认 Cilium 宿主策略, 检查是否需要设置 `devices` 列表或调整 `hostServicesProbe`
- 方案 C: 给 metrics-server 添加 `--kubelet-insecure-tls` + `hostNetwork: true`

### 问题 4: ArgoCD NetworkPolicies (Low / 潜在风险)

**现象**: ArgoCD Helm chart 创建了 7 条 NetworkPolicy。在 Flannel 下被忽略，Cilium 会实际执行。

**当前策略**: 都是 `Ingress: [{}]` (允许所有入站) + `policyTypes: Ingress` (不限出站)，**暂时不影响功能**。

**风险**: 未来如果 ArgoCD 升级引入更严格的 NetworkPolicy，可能导致 ArgoCD 组件间通信中断。

**建议**: 在 ArgoCD Helm values 中显式设置 `global.networkPolicy.create: false`，或保留策略但定期审计内容。

## Cilium 架构调整建议

### 1. Cilium Values 补充配置

当前 `cilium-values.yaml` 缺少几项关键配置:

```yaml
# 确保 Pod → Host 流量正常
hostServices:
  enabled: true

# 指定主网络接口 (Proxmox VM 通常是 eth0 或 ens18)
devices:
  - eth0+

# 启用 eBPF masquerade (替代 iptables，更高性能)
bpf:
  masquerade: true

# 健康检查端口 (已在 Ansible 防火墙规则中开放)
healthPort: 9879
```

### 2. QUIC 兼容性

Cilium VXLAN 模式下，出站 QUIC (UDP/443) 可能因为 MTU 或 masquerade 问题失败。两种应对策略:

- **短期**: 强制 cloudflared 使用 HTTP/2 (`--protocol http2`) — 已在 manifest 中修改
- **长期**: 如需 QUIC，考虑切换 Cilium routing mode 为 `native` (direct routing) 而非 `tunnel`

### 3. Hubble 可观测性利用

Hubble 已启用 (4095/4095 flows)。建议:
- 在排障时活用 `hubble observe --verdict DROPPED` 检测被 Cilium 丢弃的流量
- 后续考虑启用 Hubble metrics 并接入 Prometheus/Grafana

### 4. NetworkPolicy 策略

当前集群**没有**任何 CiliumNetworkPolicy 或 CiliumClusterwideNetworkPolicy。仅有 ArgoCD 的标准 K8s NetworkPolicy (全允许入站)。

建议保持当前状态 — 在单节点 homelab 环境下 NetworkPolicy 价值有限。如需安全隔离，优先使用 CiliumNetworkPolicy (L7 能力更强)。

## 修复执行顺序

```
1. Fix ZITADEL master key (Vault) → 恢复 SSO → 所有受保护服务恢复
2. Push cloudflare-tunnel.yaml → 恢复 cloudflared → 外部访问可靠性提升
3. Fix metrics-server → 恢复 HPA 和 kubectl top
4. Clean up stale ReplicaSets (cloudflared, rsshub)
5. Git commit 所有未提交的变更
```

## 验证清单

- [ ] `auth.meirong.dev` 返回 200 (ZITADEL 登录页)
- [ ] `book.meirong.dev` SSO 流程正常
- [ ] `kubectl --context k3s-homelab -n cloudflare get pods` 全部 Running
- [ ] `kubectl --context k3s-homelab top nodes` 正常输出
- [ ] `kubectl --context k3s-homelab -n argocd get app` 全部 Synced + Healthy
