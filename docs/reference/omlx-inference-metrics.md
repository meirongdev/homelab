# Mac OMLX 推理指标（采集口径与陷阱）

> Last updated: 2026-09-01
> Status: 生效事实

## 速览

- **OMLX 自己没有 `/metrics`**（0.6.3rc2 实测）。指标靠两条互补链路拼出来，
  都不需要鉴权、都不改 OMLX 本身：

| | 链路 A：json-exporter（拉） | 链路 B：textfile（推） |
|---|---|---|
| 数据源 | OMLX 的 `/api/status` + `/v1/models/status` | Mac 上的 `~/.omlx/stats.json` |
| 谁在跑 | 集群内 `json-exporter.monitoring` Deployment | Mac 上的 LaunchAgent，每 60s 渲染一次 `.prom` |
| 怎么进 Prometheus | job `omlx-status` / `omlx-models` 抓 `/probe` | node_exporter textfile collector，随 job `node-exporter-macbook` |
| 新鲜度 | 30s | 源文件 300s 才落盘（且只在有请求时落）|
| 独有内容 | 驻留/内存/队列/能力位（实时状态） | 累计 prefill/generate 秒数、per-model token 账本、跨重启持久化 |
| 指标前缀 | `omlx_*` | `omlx_alltime_*`（☠️ 抓取时改名，见陷阱 8）|

- 链路 B 是 2026-08-23 加的，补的是链路 A 结构性拿不到的**分母**：
  `/api/status` 只给「自启动以来的累计平均 TPS」，跑久了几乎不动；
  有了累计秒数，`rate(tokens)/rate(seconds)` 才是真的「最近半小时多快」。
- 面板：Grafana → **Hardware / Mac OMLX 推理**（uid `omlx-inference`）。
- 这台机器的头号故障模式是**换模型**（换入换出期间对请求回 `is busy`，
  见 [records/2026-08-22-podcast-tts-unload-pending.md](../records/2026-08-22-podcast-tts-unload-pending.md)），
  所以面板把「驻留时间线 + 换入换出事件 + 空闲 TTL」排在吞吐之前。

## 组件与文件

| 东西 | 位置 |
|---|---|
| **A** exporter 清单（Deployment/Service） | `k8s/helm/manifests/monitoring/json-exporter/json-exporter.yaml` |
| **A** 模块配置（JSON→指标的映射） | `k8s/helm/manifests/monitoring/json-exporter/json-exporter-cm.yaml` |
| **B** 生产端（Mac LaunchAgent，写 `.prom`） | `macbook/ansible/playbooks/omlx-metrics.yaml` + `templates/com.meirongdev.omlx-textfile-collector.plist.j2` |
| **B** 读取端（给 node_exporter 加 textfile flag） | `macbook/ansible/playbooks/node-exporter.yaml` + `templates/com.prometheus.node_exporter.plist.j2` |
| B 渲染器（☠️ **不在本仓**） | `mlx-learning` 仓的 `src/mlx_learning/omlx_textfile_collector.py`，装在 Mac 的 `~/projects/meirongdev/mlx-learning/.venv/` 里 |
| 抓取配置（A 两个 job + B 的改名规则） | `k8s/helm/values/kube-prometheus-stack.yaml` 的 `additionalScrapeConfigs` |
| 面板 | `k8s/helm/manifests/monitoring/dashboards/omlx-dashboard.yaml` |
| Mac 侧主机指标（同一个 node_exporter） | 见 [observability-multicluster.md](observability-multicluster.md) |

部署，**两侧分开**：

- 集群侧（A 的 exporter、两侧的抓取配置、面板）：`git push` → ArgoCD `monitoring-dashboards`
  （管 `manifests/monitoring/` 整个目录）与 `kube-prometheus-stack`（多源 values）各自同步，
  **无需手动 helm/kubectl**。
- Mac 侧（B 的两个 LaunchAgent）：Ansible，可重复执行。
  ```bash
  cd macbook/ansible
  just node-exporter   # 读取端：--collector.textfile.directory（改了 plist 必须重启进程，handler 会做）
  just omlx-metrics    # 生产端：每 60s 渲染一次 .prom
  ```
  两个 playbook 都会**自己验收整条链路**（`node_textfile_scrape_error==0` + `omlx_` 条数 >0），
  少跑一个不会报错、指标静默不出现，所以别只跑一个。`just site` 已按正确顺序包含两者。

☠️ **exporter 必须钉控制面**（清单里已写 `nodeSelector`）：worker-106 是 tagged-device，
netmap 里没有 Mac 这个源（与 litellm 同一约束）。调度到 worker 的表现是 **target down**，
不是报错。

## 数据源：OMLX 暴露了什么

| 来源 | 鉴权 | 内容 | 用在 |
|---|---|---|---|
| `GET /api/status` | 无 | 全局累计：请求数/token 数/累计平均 TPS/缓存命中/uptime/自定义内核可用性 | 链路 A |
| `GET /v1/models/status` | 无 | per-model：是否驻留/装载中/体积（估算+实际）/`last_access`/context 长度 + pool 天花板 | 链路 A |
| 文件 `~/.omlx/stats.json` | 无 | 原始累计和：token / 请求 / prefill 与 generate 秒数，全局 + per-model | 链路 B |
| `GET /admin/api/stats` | ❌ **admin 会话 cookie** | 更细：内存压力档位、队列深度 | 未采集 |

**`stats.json` 是怎么回事**：`server_metrics.save_alltime()` 每 300s（`_SAVE_INTERVAL`）
把 `alltime` 计数器**原子重写**进这个文件，进程退出时再写一次。这就是 admin API 那套
`alltime` 口径的落盘副本：免鉴权、跨进程重启累加，且**带着 `/api/status` 没有的秒数分母**。

**`/admin/api/*` 拿不到**：`omlx/admin/auth.py::require_admin` 只认 cookie，**没有 Bearer 通路**。
☠️ **不要为此去开 `skip_api_key_verification`**：`server.host` 是 `0.0.0.0` 且
`cors_origins` 是 `["*"]`，那等于把「改设置、下载/删除模型、清缓存、重启服务」整个
admin 面板开放给 LAN 和整个 tailnet。原本唯一卡在 admin API 后面的 **per-model token 账本，
现在链路 B 免鉴权就能拿到**；仍然拿不到的只剩内存压力档位与队列深度（都不值得为它登录）。

## 指标清单

`omlx-status` job（源 `/api/status`）：

| 指标 | 说明 |
|---|---|
| `omlx_uptime_seconds{version,default_model}` | 进程 uptime；版本号在标签上 |
| `omlx_requests_total` / `_active` / `_waiting` | 累计请求 / 在飞 / 排队 |
| `omlx_prompt_tokens_total` / `_completion_` / `_cached_` | 累计 token |
| `omlx_cache_efficiency_percent` | 已经是百分数（0–100），不用再 ×100 |
| `omlx_avg_prefill_tps` / `omlx_avg_generation_tps` | ⚠️ **自启动以来的累计平均**，见下 |
| `omlx_custom_kernel_available{kernel}` | 4 个自定义 Metal 内核；本机实测**全 0** |
| `omlx_ane_prefill_patch_available` / `_configured_models` | ANE prefill 补丁可用性 / 已配置模型数 |

`omlx-models` job（源 `/v1/models/status`）：

| 指标 | 说明 |
|---|---|
| `omlx_model_loaded{model,engine,source}` | 0/1，驻留状态（面板的 state-timeline 就是它）|
| `omlx_model_loading` / `omlx_model_pinned` | 装载中 / 是否 pin 住 |
| `omlx_model_estimated_size_bytes` | 估算体积（**天花板核算用的就是这个**）|
| `omlx_model_context_length` | 模型 context 长度 |
| `omlx_model_resident_actual_size_bytes{model,engine}` | 实际驻留字节，**只有驻留中的模型才有** |
| `omlx_model_resident_last_access_seconds` | unix 秒；空闲时长 = `time() - 本值` |
| `omlx_pool_ceiling_bytes` / `_current_memory_bytes` | 30G 天花板 / 当前核算占用 |
| `omlx_pool_model_count` / `_loaded_count` | 发现的模型数 / 驻留数 |
| `omlx_pool_load_seconds_per_gb` / `_load_observations` | 装载速度滚动估计 + 样本数 |

### 链路 B：`omlx_alltime_*`（源 `stats.json`，随 job `node-exporter-macbook`）

全部是 counter，全部**跨 OMLX 进程重启累加**。每个字段出两份：
全局不带标签，per-model 带 `{model="<slug>"}` 且名字里多一节 `model`。
☠️ **两份别混进同一个 `sum()`**。

| 指标（全局 / per-model） | 说明 |
|---|---|
| `omlx_alltime_requests_total` / `omlx_alltime_model_requests_total` | 累计完成请求数 |
| `omlx_alltime_prompt_tokens_total` / `…model_prompt_tokens_total` | 累计 prompt token（**含缓存命中的那部分**）|
| `omlx_alltime_cached_prompt_tokens_total` / `…model_…` | 其中由 KV 缓存直接供给、**没有真的 prefill** 的部分 |
| `omlx_alltime_processed_prompt_tokens_total` / `…model_…` | prompt 减 cached，**真正 prefill 过的量**（算 prefill 速度只能用它）|
| `omlx_alltime_completion_tokens_total` / `…model_…` | 累计解码产出 token |
| `omlx_alltime_prefill_seconds_total` / `…model_…` | 累计 prefill 墙上秒数（**链路 A 没有的分母**）|
| `omlx_alltime_generation_seconds_total` / `…model_…` | 累计解码墙上秒数（同上）|
| `omlx_alltime_stats_file_mtime_seconds` | 源文件 `stats.json` 的 mtime（**源数据**新鲜度）|
| `omlx_alltime_stats_collected_timestamp_seconds` | 快照渲染时刻（**采集器**新鲜度，两者含义不同，见陷阱 9）|

这才是「最近半小时到底多快」的正确算法，分母是纯推理秒数，不含空闲：

```promql
# prefill tok/s：分子必须扣掉缓存命中，否则被缓存命中率放大
#（本机实测命中率 78.5%，不扣就是 4.6 倍虚高）
rate(omlx_alltime_processed_prompt_tokens_total[30m])
  / rate(omlx_alltime_prefill_seconds_total[30m])

# 解码 tok/s，按模型
rate(omlx_alltime_model_completion_tokens_total[30m])
  / rate(omlx_alltime_model_generation_seconds_total[30m])

# KV 缓存命中率（与链路 A 的 omlx_cache_efficiency_percent 同义，但这条是分窗口的）
rate(omlx_alltime_cached_prompt_tokens_total[30m])
  / rate(omlx_alltime_prompt_tokens_total[30m])
```

☠️ **`rate()` 窗口不得短于 15m，建议 30m 起**：源文件 300s 才落一次盘，
计数器是台阶状的，窗口一短大部分采样点读到 0，曲线会变成一排尖刺加一片空白。

## ☠️ 陷阱（按踩到的概率排序）

1. **`avg_*_tps` 不是当前速度**，是 `token 数 ÷ 累计 prefill/generate 秒数`（自启动累计）。
   跑久了几乎不动，拿它当实时指标会一直看到「机器很快」。要「现在快不快」有两个口径，
   **别混**：
   - `rate(omlx_completion_tokens_total{job="omlx-status"}[…])` = **含空闲时间**的
     墙上吞吐（「这台机器这半小时产出了多少 token」）；
   - `rate(omlx_alltime_model_completion_tokens_total[30m]) / rate(omlx_alltime_model_generation_seconds_total[30m])`
     = **纯推理速度**（「它干活的时候有多快」）。机器闲着时前者掉到 0，后者不动。
   ⚠️ 2026-08-23 之前这里写的是「OMLX 不暴露分窗口的纯推理速度」，那是只看 HTTP 端点
   得出的结论，秒数分母在 `stats.json` 里一直有，链路 B 把它取出来了。
2. **天花板核算 ≠ 实际内存**。pool 用 `estimated_size` 记账，实测 reranker 估算 0.35G /
   实际 `actual_size` 0.50G（**+41%**）；但它与 4B 嵌入模型同驻时，两个口径合计只差 4%
   **偏差因模型而异，别当固定系数用**。「核算没到 30G」不等于机器还有那么多余量，
   余量看 `free -m` 的 available（见 [k8s-qos-resource-management.md](k8s-qos-resource-management.md)）。
3. **未驻留的模型没有 `actual_size` / `last_access` 指标**（源端是 `null`）。
   json_exporter 遇到 `null` 会**丢弃该指标并每次抓取刷一条 ERROR 日志**，
   所以这两个字段单独放在 `omlx_model_resident` 里、用 jsonpath `?(@.loaded == true)` 过滤。
   ⚠️ 谁要是把它们合并回 `omlx_model`，就会得到 11 模型 × 2 字段 × 每 30s 的稳定日志噪音。
4. **`up{job="omlx-*"}` 分不清是 exporter 挂了还是 Mac 合盖了**（probe 形态的固有代价）。
   笔记本本来就会睡，与 `node-exporter-macbook` 一样属预期抖动，未纳入 TargetDown 告警。
5. **两套计数器的重启行为相反**：链路 A 的 `omlx_*_total` 取自 `/api/status`，
   **随 OMLX 进程重启归零**；链路 B 的 `omlx_alltime_*_total` 取自落盘的 `alltime`，
   **跨重启累加**。`rate()`/`increase()` 两边都能跨过重置，但「总量」类面板
   用链路 A 的别上 `max_over_time`，要真·总量就用 `omlx_alltime_*`。
6. **30s 抓一次，比一次换入换出还慢**：小模型装载 ~1s/GB，时间线可能整段错过。
   判断有没有发生换模型，用 `changes(omlx_model_loaded[…])` 的**事件计数**，别只看时间线。
   （抓取间隔刻意不是 15s：OMLX 是单进程 Python，大 prefill 期间事件循环卡住，
   抓超时恰好发生在最该看数据的时候。）
7. **`custom_kernels` 是字典不是数组**，jsonpath 带不出 key 名，4 个内核只能在配置里逐条写死。
   OMLX 升级新增内核时这里不会自动出现，面板少一格，不报错。
8. **链路 B 的指标在抓取时被改了名**（`omlx_` → `omlx_alltime_`，规则写在
   `node-exporter-macbook` job 的 `metric_relabel_configs`）。两个后果：
   - Mac 上 `omlx.prom` 里、以及 **mlx-learning 仓 `docs/serving.md` 的 PromQL 示例**
     用的都是没有前缀的原名，照抄进 Grafana 一定查不到东西，自己补 `alltime`。
   - 改名的理由不是洁癖：不改的话 `omlx_prompt_tokens_total` 会同时存在两份
     **同名不同义**的序列（自启动 vs 跨重启），只差 `job` 标签。它们会互相跟随，
     于是漏写 `job=` 的 `sum()` 得到的是一条**看起来完全合理的双倍曲线**，不报错、
     不告警、肉眼看不出来。（同类教训见
     [prometheus 的 cluster 标签不等于集群成员](observability-multicluster.md)。）
9. **「陈旧」有两种，指标也有两个**，别拿一个当另一个：
   - `omlx_alltime_stats_file_mtime_seconds` 老了 = **OMLX 闲着或停了**（源文件 300s
     才落一次盘，且只在这期间有过请求才落）。这是**正常状态**，不是故障。
   - `node_textfile_mtime_seconds{file="omlx.prom"}` /
     `omlx_alltime_stats_collected_timestamp_seconds` 老了 = **采集器死了**。
   ☠️ 渲染器读文件失败时**故意保留旧 `.prom` 而不是写一份归零的**，归零会被
   Prometheus 读成计数器重置，把跨越这段空档的每一条 `rate()` 都打出一个洞。
   代价就是「采集器死了」只能靠上面那两个 mtime 看出来，数值本身看不出来。
10. **退役模型永远不消失**：`stats.json` 保留每一个曾经服务过的模型且从不清理
   （今天 27 个），所以早就删掉的模型仍然以平坦的计数器一直上报。序列数
   = 7 字段 × 模型数 × 2（全局/per-model 那份）+ 元数据 = 当前 198 条，
   **只增不减**。按 `model=` 过滤面板，别默认 `All`。
11. **渲染器在另一个仓**（`mlx-learning` 的 venv）。本仓的 Ansible 只负责调度它，
   **不负责创建那个 venv**：缺了 `just omlx-metrics` 会明确失败并给出 `uv sync` 的修法，
   而不是装一个每 60s 空转的 LaunchAgent。反过来，升级 mlx-learning 之后
   不需要重跑 playbook，plist 指的就是 venv 里的脚本本身。

## 这台机器的物理约束（读面板要知道的）

来自 Mac 侧 `~/.omlx/settings.json` 与 `model_settings.json`（2026-08-22 实测值）：

| 设置 | 值 | 对面板的含义 |
|---|---|---|
| `memory.memory_guard_custom_ceiling_gb` | 30.0 | `omlx_pool_ceiling_bytes` = 32212254720 |
| `memory.soft_threshold` / `hard_threshold` | 0.85 / 0.95 | 内存占用 stat 的两档阈值就是它们 |
| `scheduler.max_concurrent_requests` | 2 | 在飞到 2 就满，其余进 `waiting`；5 路齐发必然排队 |
| per-model `ttl_seconds`（语音/嵌入/重排）| 900 | 空闲 15 分钟即卸载；面板的 900s 阈值线 |
| 全局 `idle_timeout_seconds` | `None` | 两个 21G/16G 的 VLM **没有 TTL**，只受内存压力驱逐 |

两个大 VLM 各 16–21G，**同时驻留就顶穿 30G**，这是换入换出的物理原因，不是配置失误。

## 为什么链路 B 走 textfile 而不是再加一个 exporter

`stats.json` 是 Mac 本地的文件，不是 HTTP 端点，集群里的 json-exporter 只会
`GET` 一个 URL，够不着它。要让它够着就得在 Mac 上再起一个 HTTP 监听，
那是给一台已经暴露在 tailnet 上的笔记本**新开一个端口**，只为搬运一个本地文件。

node_exporter 已经在那台机器上跑着，它的 **textfile collector 正是为这件事设计的**：
落一个 `.prom` 文件，零新端口、零新进程常驻（渲染器跑 0.03s 就退）、
零额外抓取目标，指标跟着已有的 `node-exporter-macbook` job 一起进来。
渲染器本身也不是新写的，是 `mlx-learning` 仓已有的 `omlx-textfile-collector`
（那边带单元测试），本仓只负责用 Ansible 把它调度起来。

## 为什么是现成的 json_exporter 而不是自研

按 [decisions/](../decisions/README.md) 的惯例先跑现成方案（对照
[cf-analytics 那次自研胜出](../decisions/cf-analytics-custom-exporter.md)）：
prometheus-community 的 json_exporter v0.8.0 实测**覆盖两个端点的全部有用字段**，
含数组展开成 per-model 标签，零代码、零 E1 内嵌脚本机制。唯一两处别扭
（`null` 的日志噪音、字典带不出 key 名）都在配置层绕开了，见上文陷阱 3 与 7。
所以**没有自研 exporter，也不需要 ADR**。

复现（本机 docker，不动集群）：

```bash
# 在仓库根目录
python3 -c "import yaml;print(yaml.safe_load(open('k8s/helm/manifests/monitoring/json-exporter/json-exporter-cm.yaml'))['data']['config.yml'])" > /tmp/omlx-jx.yml
docker run --rm -d --name jx -p 7979:7979 -v /tmp/omlx-jx.yml:/config.yml:ro \
  quay.io/prometheuscommunity/json-exporter:v0.8.0 --config.file=/config.yml
curl -s "http://127.0.0.1:7979/probe?module=omlx_status&target=http://100.89.15.120:8000/api/status"
curl -s "http://127.0.0.1:7979/probe?module=omlx_models&target=http://100.89.15.120:8000/v1/models/status"
docker logs jx 2>&1 | grep -c ERROR    # 必须是 0；非 0 说明又有字段变成了 null
docker rm -f jx
```

判据：`ERROR` 计数为 0，且 `omlx_model_loaded` 的条数等于 `omlx_pool_model_count`。

## 验收（链路 B）

平时不用手动查：`cd macbook/ansible && just omlx-metrics` 自己会跑完下面这套并打印结论
（渲染器 → 源数据 → node_exporter 三段各有各的判据和修法）。要单独看某一段：

```bash
# 1. node_exporter 真的在读那个目录吗（缺 flag 时这条指标**根本不存在**，不是 0）
ssh -i ~/.ssh/vgio matthew@100.89.15.120 \
  'curl -s localhost:9100/metrics | grep -E "^node_textfile_(scrape_error|mtime_seconds)"'

# 2. 快照本身（198 条 omlx_，且带得出源文件 mtime）
ssh -i ~/.ssh/vgio matthew@100.89.15.120 \
  'grep -c "^omlx_" ~/.local/var/lib/node_exporter/textfile_collector/omlx.prom'

# 3. LaunchAgent 在按 60s 转吗（☠️ 它**没有** KeepAlive，是 StartInterval；
#    看 state=not running 是正常的，跑 0.03s 就退了）
ssh -i ~/.ssh/vgio matthew@100.89.15.120 \
  'launchctl print gui/$(id -u)/com.meirongdev.omlx-textfile-collector | head -5;
   stat -f "%Sm %N" ~/.local/var/lib/node_exporter/textfile_collector/omlx.prom'
```

进了 Prometheus 之后（注意是**改名后**的 `omlx_alltime_`）：

```promql
count(omlx_alltime_requests_total)                       # 应为 1（全局那份）
count(omlx_alltime_model_requests_total)                 # 应等于 stats.json 里的模型数
time() - omlx_alltime_stats_collected_timestamp_seconds  # 采集器新鲜度，应 < 120s
```
