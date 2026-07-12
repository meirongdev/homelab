# 服务资源分配优化建议

> 日期: 2026-07-06
> 范围: homelab 集群（5600H, 12GB VM）常驻服务资源 requests/limits 调整
> 前置: `architecture-optimization-2026-07-04.md`（物理层架构优化）、`k8s-qos-resource-management.md`（QoS 策略基准）

---

## 背景

homelab 集群跑在 5600H 笔记本的 12GB Proxmox VM 上，除 k3s 系统组件（Cilium、k3s 自身、CoreDNS）外，承载：

- 个人服务: calibre-web（含 3 个 sidecars + 同步/元数据 CronJobs）
- 网关: Bifrost（LLM 代理）+ oauth2-proxy
- 基础设施: Prometheus/Grafana/Alertmanager, Loki, Tempo, OTel Collector, Tetragon
- 入口: cloudflared（2 副本）
- 密钥/存储: Vault + 注入器, PostgreSQL, External Secrets
- GitOps: ArgoCD（controller/repo-server/server/redis + image-updater）
- 备份: restic CronJob

常驻 Pod 总量 ~25–30 个（不含系统组件），memory limits 累加 ≈ 6.5Gi，加上 k3s + OS 开销约 2–3Gi，12GB VM 余量紧张。

---

## 优化原则

1. **requests 反映稳态基线**，不过度预留
2. **limits 防单 Pod 在节点高压时无限抢占 CPU**，不限正常 burst
3. Batch/CronJob 资源按实际 peak 削，不削到失败
4. 每次改动的预期释放量 + 风险等级明确标注

---

## 调整明细

### 1. calibre-web 主容器 — 高收益

| 维度 | 当前 | 目标 | 释放 |
|------|------|------|------|
| memory request | 512Mi | 256Mi | 256Mi |
| memory limit | 2Gi | 1Gi | 1Gi |
| CPU request | 200m | 100m | 100m |
| CPU limit | 2000m | 1000m | 1000m |

**理由**: Python Web 服务，I/O bound（书库读取，2026-07-11 已从 NFS 迁移至 `local-path`），非 CPU/内存密集型。500Mi+ request 逾于所需。
**风险**: 低。冷启动或并发封面生成时可能需要 >256Mi，1Gi limit 留有 4× 余量。

### 2. cloudflared — 高收益（2 副本）

| 维度 | 当前 | 目标 | 释放 |
|------|------|------|------|
| memory limit | 256Mi × 2 | 128Mi × 2 | 256Mi |
| CPU limit | 500m × 2 | 200m × 2 | 600m |

**理由**: cloudflared 典型稳态 ~30–50Mi，当前 limit 是 5–8× 实际用量。
**风险**: 极低。cloudflared 仅转发 Tunnel 流量，不做数据处理。

### 3. calibre-metadata CronJob & Job — 中收益

| 维度 | 当前 | 目标 | 释放 |
|------|------|------|------|
| memory request | 512Mi | 256Mi | 256Mi |
| memory limit | 2Gi | 1Gi | 1Gi |
| CPU request | 500m | 200m | 300m |
| CPU limit | 2000m | 1000m | 1000m |

**理由**: `ebook-meta` 单线程从 EPUB/PDF 提取元数据，不会吃 2Gi。metadata-updater 调度从 02:00 改为 04:00 以错开 restic-backup。
**风险**: 低。极端情况（数千本新书的首次 enrich）可能需更多内存，但 Enrich Job 已完成。

### 4. restic-backup CronJob — 中收益

| 维度 | 当前 | 目标 | 释放 |
|------|------|------|------|
| memory limit | 512Mi | 256Mi | 256Mi |
| CPU limit | 500m | 200m | 300m |

**理由**: restic backup 到本地 NFS，非 CPU 密集型。
**风险**: 低。256Mi 足够 restic + 管道操作。

### 5. bifrost — 微调

| 维度 | 当前 | 目标 | 释放 |
|------|------|------|------|
| memory limit | 512Mi | 384Mi | 128Mi |
| CPU limit | 1000m | 500m | 500m |

**理由**: LLM 代理网关，纯转发，不做推理。
**风险**: 低。384Mi 足够处理短时突发。

### 6. oauth2-proxy — CPU limit 补全

| 维度 | 当前 | 目标 | 释放 |
|------|------|------|------|
| CPU limit | (无) | 100m | — |

**理由**: 当前无 CPU limit，热节点上可能抢占。设 100m 限流。
**风险**: 极低。

### 7. Tempo — 微调

| 维度 | 当前 | 目标 | 释放 |
|------|------|------|------|
| memory limit | 512Mi | 384Mi | 128Mi |
| CPU limit | 500m | 300m | 200m |

**理由**: 单副本 + local storage + 微量追踪（仅集群自身操作）。
**风险**: 低。

### 8. Loki — 微调

| 维度 | 当前 | 目标 | 释放 |
|------|------|------|------|
| memory limit | 512Mi | 384Mi | 128Mi |

**理由**: 已禁 chunksCache + resultsCache，SingleBinary 模式稳态约 100–150Mi。
**风险**: 低。

---

## 调度错开

```
优化前:  02:00 metadata-updater (2Gi/2CPU burst) + 03:00 backup (512Mi/500m burst)
优化后:  03:00 backup (256Mi/200m burst) + 04:00 metadata-updater (1Gi/1CPU burst)
```

**改变**: metadata-updater 从 `0 2 * * *` → `0 4 * * *`，与 backup 之间留 1h 缓冲。

---

## 累计释放

| 类别 | 常驻 Memory limits | 常驻 CPU limits | CronJob 峰值 Memory |
|------|-------------------|----------------|--------------------|
| 优化前 | ~6.5Gi | ~5.5 core | ~5.5Gi |
| 优化后 | ~5.0Gi | ~4.0 core | ~3.5Gi |
| 释放 | **~1.5Gi** | **~1.5 core** | **~2.0Gi** |

---

## 回滚

所有改动在 ArgoCD 管理的 manifest 中，回滚只需:

```bash
git checkout HEAD~1 -- k8s/helm/manifests/
git checkout HEAD~1 -- k8s/helm/values/tempo.yaml
git checkout HEAD~1 -- k8s/helm/values/loki.yaml
argocd app sync personal-services bifrost monitoring -l app.kubernetes.io/instance=...
```
