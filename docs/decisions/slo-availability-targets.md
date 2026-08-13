# SLO 可用性目标：99% 的推导、服务选择判据与错误预算算术

> 日期: 2026-08-13
> 状态: ⚠️ 部分完成（目标值与算术即为现状、已固化；服务清单的重新对齐是本文建议，未实施）

## 上下文

2026-06-16（`d5caa50`）上线 Sloth + 5 条「可用性 99% / 30d」SLO。**机制层文档一直是完整的**
——指标来源、SLI 公式、兜底推导、告警映射见
[reference/observability-alerting-slo.md › SLI / SLO](../reference/observability-alerting-slo.md#sli--slosloth--cilium-envoy-一手指标)
与 `k8s/helm/manifests/monitoring/slos.yaml` 头部注释，本文**不重复**。

缺的一直是**判断**：为什么是 99%、为什么是这 5 个服务、这些数字到底在量化什么。
全仓 grep `99%` 只有描述现状的命中；上线 commit 正文只写了"做了什么"。

这不是文档洁癖。2026-08-12 的 NaN 故障
（[records](../records/2026-08-12-slo-nan-poisoning.md)）里，5 个服务的错误预算面板全
N/A 潜伏了一个多月没人察觉——**因为没人知道那个数该是多少，也没有任何决定依赖它**。
一个没有判据、不喂给任何决策的 SLO，坏了当然没人喊。

本文补三件事：目标值的推导、服务选择判据、错误预算的标准算术。
**不改任何现有 SLO 定义**——量化后确实发现清单该调，那是本文的建议而非既成事实。

---

## 实测（2026-08-13，5 天窗口）

⚠️ 下面所有数都是**当时的现场值，会漂**。判据是算法（[D3](#d3--错误预算的标准算术)），
不是这张表里的数字。复现命令见文末。

### 一、分母的真相：4/5 个 SLO 量的是 Uptime Kuma 探针

Uptime Kuma 的 HTTP 监控固定 `interval=60`（`provisioner.yaml:220`），
其中 7 个探的是 `https://*.meirong.dev/`——**这些请求穿过 Cloudflare → 隧道 → Cilium
Gateway，因此全部计入 SLI 分母**。基线：1440 次/天 = **7200 次 / 5d**。

减掉这条基线后：

| 服务 | 5d 总请求 | 探针基线 | **真实流量** | 有 SLO? |
|---|---:|---:|---:|:--:|
| calibre-web | 22997 | 7200 | **15797** | ✅ |
| **uptime-kuma** | 9742 | 0（内网探测，不过 gateway） | **9742** | ❌ |
| grafana | 10185 | 7200 | **2985** | ✅ |
| karakeep | 2414 | 0 | 2414 | ❌ |
| it-tools | 1387 | 0 | 1387 | ❌ |
| jobs-sg | 8137 | 7200 | 937 | ❌ |
| homepage | 687 | 0 | 687 | ❌ |
| open-notebook | 7355 | 7200 | 155 | ❌ |
| zitadel | 1644 | ~1600（探针 08-12 才加，仅 ~1.1d） | **~44** | ✅ |
| **argocd** | 7168 | 7200 | **≈0** | ✅ |
| **vault** | 7145 | 7200 | **≈0** | ✅ |

vault 和 argocd 的总量**低于**探针基线（7145 / 7168 < 7200，差额是漏掉的几次探测），
这本身就是"真实流量约等于零"的交叉验证。vault 更直接：5 天里 `2xx` 计数是 **1**。

> 结论：**vault 与 argocd 的 SLO 除了 Uptime Kuma 的探针之外什么都没测到**，
> zitadel 只多 44 个请求。它们是**穿着 SLO 外衣的黑盒存活探测**，而这件事
> Uptime Kuma 已经在做，更直接也更便宜。
>
> 这同时纠正了 reference 里那句选型理由——"基于真实入口请求，**非合成探测**"。
> 该说法对 calibre-web 成立，对另外 4 个不成立。

### 二、"30d 周期" 的真实窗口是 ~6 天，而且会漂

`retention=7d` 使 `sum_over_time([30d])` 只读得到 retention 内的数据。实测样本数
（`evaluationInterval=30s`）：

| 测量时间 | 样本数 | 真实窗口 |
|---|---:|---:|
| 2026-08-12（[records](../records/2026-08-12-slo-nan-poisoning.md)） | 20592 | 7.15d |
| 2026-08-13（本文） | 16951 | **5.89d** |

**窗口长度本身不是常数**：Prometheus 按 block 粒度删除过期数据，retained span 因此在
~6d 与 ~7.2d 之间锯齿波动。→ **任何依赖窗口长度的换算都必须现测，不许引用文档里的数**
（同 `just verify-node` 那条"别写死条数"）。

一个反直觉的连带效果：**这让 SLO 比它的标签更严，不是更松。**
预算恒为窗口内请求数的 1%，窗口从 30d 缩到 6d，同一次故障消耗的预算**比例**就大 5 倍。
所以现状实际执行的是「**任意滚动 6 天内 99%**」，严于「30d 内 99%」。
这也是"30d 周期跑在 7d retention 上"刻意不修的**第二个**理由（第一个见 slos.yaml：
换窗口要自带 sloth catalog 并重标定燃尽率系数）——它错在安全的那一侧。

### 三、一个 5xx 值多少预算

99% 目标 → 预算 = 分母的 1%。窗口内总请求 N 时，**单个 5xx 消耗 100/N 的预算**：

| SLO | N (5d) | 预算(错误数) | 单个 5xx | 实测已耗 |
|---|---:|---:|---:|---|
| calibre-web | 22997 | 230.0 | 0.43% | 13 个 5xx → **5.7%**（剩 94.3%）|
| grafana | 10185 | 101.9 | 0.98% | 0 |
| argocd | 7168 | 71.7 | 1.40% | 0 |
| vault | 7145 | 71.5 | 1.40% | 0 |
| zitadel | 1644 | 16.4 | **6.08%** | 0 |

zitadel 那个 6% 就是"样本量太小 → 目标失真"的量化形态：一次无关紧要的抖动就吃掉
6% 月度预算。探针跑满一个窗口后会降到 ~1.4%，但那只是把噪声换成了探针噪声。

**时间等价**：当分母以恒速探针为主时（4/5 个 SLO 是这样），请求制 SLI ≈ 时间制 SLI，
预算 ≈ 窗口时长的 1%：

- 真实窗口 5.89d = 8496 min → **≈ 85 分钟**
- 若 30d 周期名副其实 → 432 min = 7.2h

---

## 决策

### D1 — 目标值维持 99%，判据是「单节点 + 无 HA + 手工维护窗口」

两个集群都是**单节点、无 HA、手工运维**：homelab 的 gateway 是 Cilium Envoy DaemonSet
跑在单 control-plane 上（worker 不承载 gateway），oracle 是单台 free-tier VM。
会打断 gateway 的计划内动作：Cilium 升级（必须连跑 `just deploy-gateway-api-crds`）、
k3s 升级、内核/BIOS 重启。

按真实窗口的 85 分钟预算推：

| 目标 | 预算（真实窗口 ≈6d） | 一次 30 分钟手工维护窗口占 | 结论 |
|---|---:|---:|---|
| 99.9% | 8.5 min | **353%** | 任何一次升级都直接违约，不可信 |
| 99.5% | 42 min | 71% | 一次维护就吃掉七成，容不下任何意外 |
| **99%** | **85 min** | **35%** | 每 6 天两次维护 = 70%，留 30% 给意外 ✅ |

→ **99% 是单节点无 HA 前提下最紧的可信目标**。数字不变，但从此有推导。

⚠️ 推翻条件：homelab 或 oracle 任一侧做到 gateway 层 HA（多节点承载 Envoy + 滚动升级
不掉流量）后，99.5% 才值得重谈。**在那之前调高目标只会制造假违约。**

### D2 — 服务选择判据：两维，缺一不建 SLO

**维度一 · 真实流量**（去掉探针基线后）≥ **1000 请求/窗口**。
理由直接来自上面第三张表：低于此，预算不足 10 个错误、单个 5xx >10% 预算，
SLI 是统计噪声而非信号。

**维度二 · 有人会注意到**：有真实使用者（含"我自己每天用"）。

| 情形 | 处置 |
|---|---|
| 两维都满足 | **建 SLO** |
| 关键但无真实流量（SSO 这类单点依赖） | **只做 Uptime Kuma 存活探测 + 告警，不建 SLO** |
| 有流量但没人在意 | 不建 |

第二行是关键：**关键性不是建 SLO 的理由，可测量性才是**。zitadel 是全站 SSO 单点，
但 44 个请求上的 99% 只会产生假信号；它需要的是存活探测（2026-08-12 已补上），不是 SLO。

### D3 — 错误预算的标准算术

以后别再拍脑袋，按这个顺序算（全部现测，不引用文档里的数）：

1. **窗口真实长度** = `count_over_time(slo:sli_error:ratio_rate5m{...}[30d])` × `evaluationInterval`
2. **探针基线** = 1440 × 窗口天数（**仅**对有 `https://*.meirong.dev` 外部探针的服务；
   探内网 ClusterIP 的监控不过 gateway、不计入）
3. **真实流量** = 窗口内总请求 − 探针基线
4. **预算（错误数）** = 0.01 × 窗口内总请求（99% 目标）
5. **单个 5xx 代价** = 100 / 窗口内总请求
6. **时间等价** = 窗口时长 × 1% —— ⚠️ 仅在分母以恒速探针为主时成立；
   calibre-web 这种有真实流量的，请求制 SLI 是**按用户加权**的（忙时的 5xx 更贵），
   不能换算成分钟

### D4 — 错误预算政策：显式地「只做优先级信号，不做变更闸门」

homelab 没有发布节奏、没有团队、没有值班表。设"预算耗尽冻结变更"是仪式而非控制手段。
**显式记录这个取舍**，免得以后有人以为是漏了。

但两条硬规则，都是 2026-08-12 的直接教训：

1. ☠️ **N/A / NaN ≠ 健康**。预算数无效时按「**未知**」处理，不按「没问题」处理。
   执行者是哨兵告警 `SLOSLIProducingNaN`（不是人看面板——人已经看漏过一个多月）。
2. 预算剩余 <25% 时，**先做 4xx/5xx 归因，再往同集群加新服务**
   （与 [cluster-placement-for-new-services](cluster-placement-for-new-services.md) 联动）。

### D5 — 新增 SLO 的检查清单

1. **先按 D3 测真实流量**，过不了 D2 的 1000 门槛就别建——建了是负资产
2. 分子分母都兜底，照 `slos.yaml` 现有 5 条抄（两个坑独立，推导在文件头）
3. oracle 侧记得 `_total` 后缀 + `cluster="oracle-k3s"`
4. 建完 **24h 后**核：`rate5m` 无 NaN、`rate1h` 是实数
5. ⚠️ **别拿 30d 面板当验收**——它要等窗口填满，新 SLO 头几天本来就是 N/A

---

## 后果

### 现状与判据的差距（本文只记录，不修）

按 D2 复核现有 5 条：

| SLO | 真实流量 | D2 判定 | 建议 |
|---|---:|---|---|
| calibre-web | 15797 | ✅ 合格 | 保留（唯一名副其实的一条）|
| grafana | 2985 | ✅ 合格 | 保留 |
| vault | ≈0 | ❌ 不合格 | 降为 Uptime Kuma 存活探测（已有） |
| argocd | ≈0 | ❌ 不合格 | 同上（已有探测） |
| zitadel | ~44 | ❌ 不合格 | 同上（探测 2026-08-12 已补） |

**5 条里 3 条不合格**。三条都是 2026-06/07 按"重要的基础设施"直觉选的，而非按可测量性。

☠️ **反向缺口更值得注意**：`uptime-kuma` 是 oracle gateway 第二大真实流量后端
（9742 请求/5d），**5 天 134 个 5xx = 错误率 1.376%**——若它有 99% SLO，
**现在就是违约状态（预算剩余 −37.6%）**。且 5xx 在持续累加（近 1d 就 64 个）。
它是全舰队唯一有稳定真实错误率的对外服务，却没有 SLO；
按 D2 它**两维都满足，是最该补的一条**。

⚠️ 顺带的风险面：homelab Alertmanager 的 Watchdog dead-man's switch 正是推到
`status.meirong.dev/api/push/...`（`provisioner.yaml:170-172`），走的就是这条 5xx 率
1.4% 的路径。**这需要独立排查，不属本 ADR 范围。**

### 遗留（刻意不做）

- **不调整现有 5 条 SLO**。删 SLO 会断掉告警名与历史序列连续性；且在弄清 uptime-kuma
  的 5xx 之前，不宜同时动清单和目标——两个变化叠在一起会让下次归因无从下手。
- **不改 30d/7d 错配**。理由现在有两条：换窗口的工程量（slos.yaml 头部），
  以及上面第二节的发现——它错在**偏严**那一侧。
- **不设变更冻结**（D4 已说明理由）。

### 复现命令

```bash
cd /Users/matthew/projects/homelab
kubectl --context k3s-homelab -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &
q() { curl -sG --data-urlencode "query=$1" localhost:19090/api/v1/query; }

# 窗口真实长度（D3 步骤 1）——样本数 × evaluationInterval(30s)
q 'count_over_time(slo:sli_error:ratio_rate5m{sloth_window="5m"}[30d])'

# 各 gateway 后端真实流量排名（oracle；homelab 去掉 _total 与 cluster 标签）
q 'sort_desc(sum by (envoy_cluster_name) (increase(envoy_cluster_upstream_rq_xx_total{cluster="oracle-k3s", envoy_cluster_name=~".*cilium-gateway.*"}[5d])))'

# 单服务按响应类拆分（换 envoy_cluster_name 选择器）
q 'sum by (envoy_response_code_class) (increase(envoy_cluster_upstream_rq_xx{envoy_cluster_name=~".*/vault_vault_.*"}[5d]))'
```
