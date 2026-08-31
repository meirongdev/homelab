# `TrivyExposedSecretFound` 烧了 25 小时：豁免早已生效，报告卡在 0 副本 ReplicaSet 上永不重扫

> 日期: 2026-08-31（告警始于 2026-08-30 11:11 UTC，人工介入 2026-08-31 12:54 UTC）
> 影响: **无服务影响，也没有任何真实密钥泄漏**。一条 critical 告警按 30m
>       `repeat_interval` 连续投递 Telegram —— 实测 24h **42 条**、最后 14h **24 条**，
>       且**不会自愈**：再等多久都不会停
> 根因: 2026-08-30 给上游测试夹具私钥加的 path 豁免**确实生效了**，但它只对**还会被重扫的**
>       workload 有效。trivy-operator 给每个 ReplicaSet 各建一份 `ExposedSecretReport`，
>       按 `OPERATOR_SCANNER_REPORT_TTL=24h` 刷新——**而 `replicas=0` 的历史 ReplicaSet
>       永远不刷新**。calibre-web 攒了 10 个这样的僵尸 rs，它们的报告永久停在豁免前的快照上，
>       `trivy_image_exposedsecrets` 因此恒为 20（10×2 条 finding），告警恒 firing
> 处置: 删掉那 10 个 0 副本 ReplicaSet（ownerRef 级联带走报告）→ 指标两集群归零；
>       并给 Deployment 加 `revisionHistoryLimit: 2` 防复发

全文时刻均为 **UTC**。

## 一、先回答那个真正要紧的问题：没有泄漏

告警指向的镜像是

```
crocodilestick/calibre-web-automated@sha256:4ff5be5cd6f18d91cc72bf316260d8c34c980f09a862372bc77d25c9ddb0efef
registry: index.docker.io
```

**上游第三方镜像，不是本仓库构建的，GitHub / GHCR 上没有它的任何副本**
（`cloud/oracle/manifests/` 里 6 处都直接钉 Docker Hub digest）。所以"把 GitHub 上那个
镜像删掉"这个动作**没有对象**——排障时先确认 `.report.registry.server`，别默认镜像是自己的。

两条 finding 是：

```
[HIGH] private-key  /lsiopy/lib/python3.13/site-packages/slapdtest/certs/client.key
[HIGH] private-key  /lsiopy/lib/python3.13/site-packages/slapdtest/certs/server.key
```

python-ldap 的 `slapdtest` 模块自带的测试夹具证书，上游仓库里的公开测试数据，
**没有任何可轮换的东西**。这与 [f068b24](https://github.com/meirongdev/homelab/commit/f068b24)
当时逐条读报告得出的结论一致。

复核口径（两集群、不限严重度地把 `.report.secrets[]` 全量摊平）：**除这两条外没有第三种**。
两点已知边界，写下来免得下次误以为查过了：

- `trivy.severity = HIGH,CRITICAL` —— Medium/Low 的 secret 规则在**扫描期**就被滤掉了，
  报告里根本不会有。trivy 内置 secret 规则绝大多数是 HIGH/CRITICAL，但这不是"全量"。
- ignoreFile 会抑制 finding。当前 3 条 secret 豁免（snakeoil / slapdtest / caixin）
  **全部按 path 限定、没有一条按 rule id 全局豁免**，所以它们挡不住别处的真泄漏——
  这正是 f068b24 刻意选择的写法，别改成 `- id: private-key` 了事。
- trivy 扫的是**镜像文件系统**，不是 K8s Secret，也不是 pod 的环境变量。

## 二、指标曲线就是完整的病历

`sum(trivy_image_exposedsecrets{severity=~"High|Critical", cluster="oracle-k3s"})`：

| 时刻 | 值 | 发生了什么 |
|------|-----|-----------|
| 08-29 13:24 | **43** | 稳态。此时告警**不可能响**——规则写的是不存在的 `trivy_exposedsecrets_findings` |
| 08-30 10:51 | 43 | `f068b24` 提交：①改对指标名 ②加 secrets 豁免。ArgoCD 3 分钟内同步 |
| 08-30 11:11 | 43 | 过完 `for: 15m` → **告警首次 firing**，Telegram 开始每 30 分钟一条 |
| 08-30 13:24 → 08-31 09:54 | 41 → 39 → … → **20** | 各 workload 陆续走到自己的 24h TTL，重扫后豁免生效、逐个归零 |
| 08-31 09:54 → 12:54 | **20，平台化** | ☠️ 衰减停在这里不动了 |
| 08-31 12:54 | **0** | 删掉 10 个僵尸 ReplicaSet |

**平台期那个 20 就是全部信息**：`10 个 0 副本 ReplicaSet × 2 条 finding`。
衰减停下来不是"还没轮到"，是**剩下的这些永远轮不到**。

同一 Deployment 的对照，一眼看穿：

| ReplicaSet | replicas | 报告最后刷新 | High |
|-----------|----------|-------------|------|
| `calibre-web-7db6b79cf5` | **1** | 08-30 15:39（创建后正好 24h） | **0** ✅ |
| `calibre-web-8bb5f6644` | 0 | 08-29 10:34 | 2 |
| `calibre-web-dc6cb559c` | 0 | **08-17 17:14**（陈旧 14 天） | 2 |

活着的那个早就干净了。豁免从来没有问题。

## 三、机制：僵尸报告是系统性的，不是 calibre 特有

`OPERATOR_SCANNER_REPORT_TTL=24h` 只驱动**还有副本**的 workload 重扫。Deployment 的
`revisionHistoryLimit` 默认 **10**，于是每滚动一次就多留一个 0 副本 ReplicaSet，
它那份报告从此定格。清点两集群（已在本次清理之后）：

| 集群 | ReplicaSet 总数 | 其中 0 副本 | 挂在 0 副本上的 `ExposedSecretReport` | 挂在 0 副本上的 `VulnerabilityReport` |
|------|----------------|------------|--------------------------------|--------------------------------|
| homelab | 148 | **111** | **21** | 0 |
| oracle-k3s | 144 | **105** | **20** | 0 |

两个值得记住的点：

1. **僵尸 `ExposedSecretReport` 遍布两集群**（41 份），只是它们碰巧 finding 为 0，
   所以现在不点燃任何告警。**下一次给任何镜像加 secret 豁免，同样的哑火会重演。**
2. **`VulnerabilityReport` 没有这个问题**：0 副本 rs 上一份都不挂，而活跃 rs 上的份数
   与 `ExposedSecretReport` **完全相等**（oracle 各 39 份）。也就是说 trivy-operator
   会清掉缩容 ReplicaSet 的漏洞报告、**却把暴露密钥报告留下**。本次没有深挖这个不对称的
   成因，只记录实测结论——它意味着 `TrivyImageCriticalVulnerabilities` 不受此坑影响，
   而 `TrivyExposedSecretFound` 受。

## 四、这次栽的到底是哪个坑

不是"豁免没写对"，也不是"ArgoCD 没同步"——两者本次都正常。是**验收只看了告警灭没灭**：

> 加完豁免后没有确认「指标衰减到 0」，而衰减恰好会**先跌 53%（43→20）再停住**，
> 中途看一眼很像在正常收敛。

配合 30 分钟一条的 critical 重复间隔，一个纯误报烧了 25 小时、推了 40 多条。
本仓库这个月第三次栽在同一形状上——告警链路的某一环**外观正常但实际不通**，
另见 [gateway-api-crd-stall](2026-08-11-gateway-api-crd-stall.md) 与
[memory-alert-page-cache-false-alarm](2026-08-30-memory-alert-page-cache-false-alarm.md)。

**判据**：给 trivy 加豁免后，验收看的是

```bash
# 期望：值降到 0 并保持；停在某个非 0 平台 = 有僵尸报告
kubectl --context=oracle-k3s get exposedsecretreports -A -o json \
  | jq -r '.items[] | select((.report.summary.criticalCount + .report.summary.highCount) > 0)
           | "\(.metadata.namespace)/\(.metadata.name)"'
```

若列出的报告属于 `replicas=0` 的 ReplicaSet，**等下去没有意义**，只能删。
（这是 memory 里"别为清告警手删报告、等自然重扫即可"那条经验的**例外**——
它的前提是"会自然重扫"，僵尸 rs 不成立。）

## 五、处置

1. **删掉 10 个 0 副本 ReplicaSet**（`personal-services/calibre-web-*`），ownerRef 级联
   带走它们的报告。活跃的 `calibre-web-7db6b79cf5` 与其 pod 未受影响，
   指标随即两集群归零。
2. **`revisionHistoryLimit: 2`** 写进 `cloud/oracle/manifests/personal-services/calibre-web.yaml`
   的 Deployment。该 Deployment 是 `strategy: Recreate`（SQLite 写锁，见该文件注释），
   本来就回滚不了，留 10 份历史纯属给僵尸报告供料。

未做、留作开放项：其余 200 多个 0 副本 ReplicaSet 没有统一收口
（可以给各 Deployment 普遍加 `revisionHistoryLimit`，或加一条"僵尸报告数"的巡检）。
当下它们不点燃告警，等下次真需要 secret 豁免时再处理也不迟。
