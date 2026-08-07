# jobs-sg 三处问题诊断（2026-08-08）

> 状态: 🔍 **诊断完成，修复待合并**。两处修复已写好并验证，各在一个分支上，**均未推 main、未部署**；
> 第三处不是缺陷，是"还没到时候"，且它的口径**需要你拍板**。
> **本文是冻结的诊断快照**——现状事实看 [reference/jobs-sg.md](../../reference/jobs-sg.md)。
> 日期: 2026-08-08
> 范围: 升级到上游 `90cd4e8` 之后，对 `closed` 恒为 0、reconcile 告警、work_mode 三个疑点的核实与处置。

## 一句话结论

| # | 疑点 | 核实结果 | 处置 |
|---|---|---|---|
| 1 | `closed` 恒为 0 | **不是缺陷** —— 关岗位只在周日 SGT 那轮做，上线是 08-03 周一，**第一次 reconcile 是 08-09** | 等数据；口径 A/B 由你定，见 §3 |
| 2 | `JobsSgReconcileStale` | **真缺陷**：series 不存在时 `time() - <no data>` 算不出结果，最该响的场景永远沉默 | 已修，分支 `fix/jobs-sg-reconcile-alert-blindspot` |
| 3 | `work_mode` 全是 Onsite | **真缺陷**：拿排班字段冒充办公地点，约 100% 岗位被标 Onsite 并显示在首页与周报 | 已修，jobs-sg 分支 `fix/work-mode-taxonomy` |

---

## 1. `closed` 恒为 0 —— 不是缺陷

**观测**：`jobs_sg_jobs{state="active"} 11499`、`{state="closed"} 0`，上线五天一条都没关。

**核实**：只有周日 SGT 的全量 reconcile 会关岗位。

- `cmd/ingest/main.go:32` —— `isSunday := time.Now().In(sgt.Zone).Weekday() == time.Sunday`
- `internal/ingest/ingest.go:112` —— "Only reconcile applies close logic"

上线日 2026-08-03 是**周一**，其后至今没有周日。因此 `MissAndClose` 一次都没被调用过。
旁证：`jobs_sg_last_success_timestamp_seconds{kind="full_reconcile"}` 这条 series 在
Prometheus 里**不存在**（`absent(...)` 返回 1）——按上游"无值即不输出，绝不补 0"的约定，
这正是"从未跑过"的正确表现。

**第一次 reconcile = 2026-08-09 SGT 02:15（= 08-08 18:15 UTC）**。

⚠️ 但它未必能关成：关闭逻辑被 `status == success` **与** `deviation < 2%` 双重门控
（`ingest.go:280`）。reconcile 要扫 ~867 页约 20 分钟，期间只要 web 在渲染聚合页就可能
撞上 `SQLITE_BUSY`（DELETE journal 下读者持 SHARED 锁挡住写者，2026-08-08 实测复现过
一次）→ 该轮记成 `partial` → 关闭整个跳过。所以 §2 那条告警必须先修好。

---

## 2. `JobsSgReconcileStale` 结构性哑火 —— 真缺陷，已修

**缺陷**：原表达式只有一个减法。

```promql
time() - jobs_sg_last_success_timestamp_seconds{kind="full_reconcile"} > 10 * 24 * 3600
```

series 不存在时 `time() - <no data>` 得不到任何结果，告警永远 inactive。实测：

```
absent(jobs_sg_last_success_timestamp_seconds{kind="full_reconcile"})  => 1
原表达式                                                               => <no data>
```

即：**"reconcile 一次都没成功过"这个最该报警的场景，它永远沉默。**

**为什么这不是理论风险**：结合 §1，失败会自我掩盖 ——
reconcile 撞锁 → `partial` → 关闭逻辑跳过 → 不写 `full_reconcile` 成功 → series 仍不存在
→ 告警继续哑火 → 没人知道在架职位数正在失真。

**修法**（分支 `fix/jobs-sg-reconcile-alert-blindspot`）：

```promql
(time() - jobs_sg_last_success_timestamp_seconds{kind="full_reconcile"} > 10 * 24 * 3600)
or
(
  absent_over_time(jobs_sg_last_success_timestamp_seconds{kind="full_reconcile"}[10d])
  and on() (sum(count_over_time(up{job="jobs-sg-web"}[10d])) > 11520)
)
```

`and on()` 那半是**冷启动闸门**：应用 08-03 才上线，不能一上线就响。用累计抓取样本数当
"我们已经观察了多久"的代理——60s 间隔满 10 天 = 14400，取 80% = 11520。

☠️ **必须 `sum()`**。`count_over_time(up[10d])` 按 pod 实例分裂，pod 一滚动就变成十条
几十到几千的小 series，不聚合的话 11520 这个门槛**永远够不着**，分支直接成死代码——
那等于用一个新的哑火去修旧的哑火。第一版就是这么写的，是实测把它抓出来的。

**验证**（把清单渲染出来的那一份原样喂给真 Prometheus，两个方向都跑）：

| 检查 | 结果 |
|---|---|
| `sum(count_over_time(up{job="jobs-sg-web"}[10d]))` | 6267（≈4.4 天，与上线时间吻合） |
| 正式表达式（门槛 11520） | `<no data>` → 现在不触发 ✅ 无冷启动误报 |
| 同式门槛降到 5000 | `1` → 会触发 ✅ 证明分支活着，不是死代码 |

### 同一个洞还有一处（未修，留给你决定）

`JobsSgIngestStale` 是同一种结构：两条 series 若同时消失（空库、web 起不来）也是
`<no data>` → 哑火。没顺手改是因为它是"最重要的那条告警"，改动要单独审。现成表达式：

```promql
(min without(kind) (time() - jobs_sg_last_success_timestamp_seconds{kind=~"incremental|full_reconcile"}) > 36 * 3600)
or
(
  absent_over_time(jobs_sg_last_success_timestamp_seconds{kind="incremental"}[36h])
  and on() (sum(count_over_time(up{job="jobs-sg-web"}[36h])) > 1728)
)
```

（36h 满窗 = 2160 样本，取 80% = 1728。**未实测**，合之前要照 §2 的两个方向验一遍。）

---

## 3. `work_mode` 全是 Onsite —— 真缺陷，已修

**缺陷**：分类器拿**排班**字段冒充**办公地点**。

`internal/classify/classify.go` 旧实现只匹配 `remote` / `hybrid` / `onsite` 三组拼写，
**而 MCF 一个都不吐**，于是全部落到兜底 `return "Onsite", true`。

2026-08-08 抓 500 条实测词表（全行业，`limit=100` × 5 页）：

| 出现次数 | 取值 | 性质 |
|---|---|---|
| 19 | `Flexi-Hours` | 排班 |
| 13 | `Employees Choice of Days Off` | 排班 |
| 4 | `Compressed Work Schedule` | 排班 |
| 3 | `Telecommuting` | **地点** → Remote |
| 2 | `Staggered Time` | 排班 |

**500 条里只有 37 条（7.4%）带这个字段**，其中唯一的地点信号 `Telecommuting` 占 3 条（0.6%）。
也就是说这个字段回答的是"什么时候上班"，不是"在哪上班"。

**影响不止于一列数据**：`work_mode` 的分布被渲染在首页（`internal/view/market.go:67`）
和周报 HTML/MD（`internal/report/render.go:88,162`），还被物化进 `weekly_metric`
（`internal/report/metrics.go:166`）。也就是说**首页和周报上那个"办公模式分布"是编造的**，
性质等同于"值缺失就填 0"——而上游 `docs/04 §3.1` 恰恰明令禁止这么做，理由正是要让
"不知道"和"测得是 0"可区分。

另外 `WorkModeInferred` 这个标志**从未落库**（`internal/store/jobs.go:97` 只写
`res.WorkMode`），所以视图层就算想抑制也拿不到依据。

**修法**（jobs-sg 分支 `fix/work-mode-taxonomy`）：地点类 arrangement 才产生地点结论，
排班类一律不产生；没有地点信号时返回 `Unknown` 而不是编一个 Onsite。
`Flexi-Place` 映射到 `Hybrid` 而非 `Remote` 是有意的——新加坡 FWA 词表里它指工作地点
有弹性，比"完全远程"弱。`remote/hybrid/onsite` 三种拼写保留，好让上游哪天真改词表时
落到真实分支上，而不是无声地淌进 `Unknown`。

测试改成表驱动，把上面五个实测词全部钉住（`go vet` + `go test ./...` 全绿）。

**数据连续性**：`work_mode` 由 ingest 每轮 upsert 重写，所以**仍在架的岗位下一轮就自愈**；
已关闭/归档的历史行会保留旧的 `Onsite`，`weekly_metric` 里已物化的历史周同理，**不会追溯变对**。

---

## 4. 合并这些改动要走什么路

| 改动 | 分支 | 回路 |
|---|---|---|
| reconcile 告警 | homelab `fix/jobs-sg-reconcile-alert-blindspot` | 合进 main → ArgoCD 同步。**不需要重建镜像** |
| work_mode | jobs-sg `fix/work-mode-taxonomy` | 合进 main → CI 构镜像 → 取 index digest → 改 `kustomization.yaml` 一行 → ArgoCD 同步 |

两个分支都**没有推到远端**，本地提交而已；ArgoCD 跟的是 main，因此**当前线上完全没有被影响**。

## 5. 还没做的

- §2 末尾那条 `JobsSgIngestStale` 的同类洞（表达式已写好，未实测）。
- `closed` 的寿命口径 A/B —— 上游作者刻意留给使用者定，且明说要**看生产数据**决定
  （`/ops` 的 `jobs_closed` 逐周趋势：趋近 0 = 正常；稳定非零 = reopen/re-close 在打转）。
  第一次 reconcile 是 08-09，建议**观察 2–3 个周日**再定，现在拍板等于凭空猜。
- Grafana 面板仍未做；恢复演练仍未做（`reference/jobs-sg.md` 的「已知缺口」）。
