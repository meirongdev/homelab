# Mac OMLX 推理指标（采集口径与陷阱）

> Last updated: 2026-10-28
> Status: 生效事实

## 速览

- **两个 OMLX 节点**：`mbp-m2-pro`（M2 笔记本，`100.89.15.120`）与 `mac-studio`（M5 Max / 128G 台式机，
  `100.98.220.75`，登录用户 `matstudio`）。同一套 Ansible（`macbook/ansible`，inventory 组 `omlx`）、
  同一个 json-exporter、同一把 key、同一张面板，面板顶部 `nodename` **单选**切机器。
- **OMLX 自己没有 `/metrics`**（0.6.3rc2 实测）。指标靠两条互补链路拼出来，都不改 OMLX 本身：

| | 链路 A：json-exporter（拉） | 链路 B：textfile（推） |
|---|---|---|
| 数据源 | `/api/status` + `/v1/models/status`（要 API key，见[鉴权](#鉴权omlx-07-起)）| Mac 上的 `~/.omlx/stats.json`（免鉴权）|
| 谁在跑 | 集群内 `json-exporter.monitoring` Deployment | Mac 上的 LaunchAgent，每 60s 渲染一次 `.prom` |
| 怎么进 Prometheus | job `omlx-status` / `omlx-models` 抓 `/probe`，每台 Mac 一个 target | node_exporter textfile collector，随各 Mac 的 job（`node-exporter-macbook` / `node-exporter-mac-studio`）|
| 新鲜度 | 30s | 源文件 300s 才落盘（且只在有请求时落）|
| 独有内容 | 驻留/内存/队列/能力位（实时状态），**随 OMLX 重启归零** | 累计 prefill/generate 秒数、per-model token 账本，**跨重启累加** |
| 指标前缀 | `omlx_*` | `omlx_alltime_*`（☠️ 抓取时改名，见陷阱 8）|

- 链路 B 补的是链路 A 拿不到的**分母**：有了累计秒数，`rate(tokens)/rate(seconds)` 才是「最近半小时多快」。
- 面板：Grafana → **Hardware / Mac OMLX 推理**（uid `omlx-inference`）。头号故障模式是**换模型**
  （换入换出期间对请求回 `is busy`，见 [records/2026-08-22-podcast-tts-unload-pending.md](../records/2026-08-22-podcast-tts-unload-pending.md)），
  所以面板把「驻留时间线 + 换入换出事件 + 空闲 TTL」排在吞吐之前。

## 组件与部署

| 东西 | 位置 |
|---|---|
| OMLX 本体（brew + LaunchAgent + `settings.json` 的 host/port/鉴权四个键） | `macbook/ansible/playbooks/omlx.yaml`（只合并这四个键，不升级、不碰模型与其它设置）|
| **A** exporter 清单 / 模块配置（指标名与 help 的真相源）/ API key 的 ExternalSecret | `k8s/helm/manifests/monitoring/json-exporter/` 的 `json-exporter.yaml` / `json-exporter-cm.yaml` / `json-exporter-external-secret.yaml` |
| **B** 生产端（Mac LaunchAgent，写 `.prom`） | `macbook/ansible/playbooks/omlx-metrics.yaml` + `templates/com.meirongdev.omlx-textfile-collector.plist.j2` |
| **B** 读取端（给 node_exporter 加 textfile flag） | `macbook/ansible/playbooks/node-exporter.yaml` + `templates/com.prometheus.node_exporter.plist.j2` |
| B 渲染器（☠️ **不在本仓**，见陷阱 11） | `mlx-learning` 仓的 `src/mlx_learning/omlx_textfile_collector.py`，装在 Mac 的 `~/projects/meirongdev/mlx-learning/.venv/` |
| 抓取配置（A 两个 job + B 的改名规则） | `k8s/helm/values/kube-prometheus-stack.yaml` 的 `additionalScrapeConfigs` |
| 面板 | `k8s/helm/manifests/monitoring/dashboards/omlx-dashboard.yaml` |
| Mac 侧主机指标（同一个 node_exporter） | [observability-multicluster.md](observability-multicluster.md) |

- 集群侧：`git push` → ArgoCD `monitoring-dashboards`（管 `manifests/monitoring/` 整个目录）与
  `kube-prometheus-stack` 各自同步。
- Mac 侧：Ansible，可重复执行。不带参数作用于全部 OMLX 节点，带主机名只跑一台（如 `just omlx-metrics mac-studio`）。
  ```bash
  cd macbook/ansible
  just omlx            # OMLX 本体：host/port/key 四个键（key 从 Vault 现取）
  just node-exporter   # 读取端：--collector.textfile.directory（改了 plist 必须重启进程，handler 会做）
  just omlx-metrics    # 生产端：每 60s 渲染一次 .prom
  ```
  ⚠️ B 的两个 playbook 少跑一个不报错、指标静默不出现；两者都会验收整条链路
  （`node_textfile_scrape_error==0` + `omlx_` 条数 >0），`just site` 已按正确顺序包含两者。

☠️ **exporter 必须钉控制面**（清单里已写 `nodeSelector`）：worker-106 是 tagged-device，netmap 里没有
Mac 这个源（与 litellm 同一约束）。调度到 worker 的表现是 target down，不是报错。

## 数据源：OMLX 暴露了什么

- `GET /api/status`（全局累计 + 能力位）与 `GET /v1/models/status`（per-model 驻留/体积 + pool 天花板）是
  管理端点，要 API key，供链路 A。
- `~/.omlx/stats.json` 是 admin API 那套 `alltime` 计数器的落盘副本：`server_metrics.save_alltime()` 每 300s
  （`_SAVE_INTERVAL`）原子重写一次、进程退出时再写一次，免鉴权，供链路 B。
- `GET /admin/api/stats`（更细：内存压力档位、队列深度）**未采集**：`/admin/api/*` 只认 admin 会话 cookie
  （`omlx/admin/auth.py::require_admin` 没有 Bearer 通路）。

☠️ **不要为它去开 `skip_api_key_verification`**：`server.host` 是 `0.0.0.0` 且 `cors_origins` 是 `["*"]`，
等于把整个 admin 面板（改设置、下载/删除模型、清缓存、重启服务）开放给 LAN 和整个 tailnet；0.7 起非回环
监听下开它也会被启动校验拒绝。

## 鉴权（OMLX 0.7 起）

OMLX 0.7 起**不再允许无 API key 监听非回环地址**，没有跳过开关（`network_auth_error` 硬拒）。没 key 时启动
等「Press Enter」，launchd 下 stdin 是 EOF → 退出码 1 → KeepAlive 反复拉起，重启后即停服
（[records/2026-09-29-omlx-07-no-api-key-crashloop.md](../records/2026-09-29-omlx-07-no-api-key-crashloop.md)）。
症状：`launchctl print gui/501/sh.brew.omlx` 的 `runs` 飞涨、`last exit code = 1`，日志反复「Startup canceled」。

**现行配法**：每台 Mac 的 `~/.omlx/settings.json` 里 `auth` 两个键（0600），由
`cd macbook/ansible && just omlx` 合并维护（连同 `server.host`/`server.port`，别的设置归 admin 面板）：

| 键 | 值 | 效果 |
|---|---|---|
| `api_key` | Vault `secret/homelab/omlx` 的 `api_key`（**所有 OMLX 节点共用**：json-exporter 只挂一个 key 文件）| 满足启动校验；管理端点只认它 |
| `allow_unauthenticated_inference` | `true` | **推理**端点（`verify_inference_api_key`）免鉴权 |

| 端点 | 无认证 / `Bearer dummy` | `Bearer <key>` | 谁在用 |
|---|---|---|---|
| `/v1/models`、`/v1/chat/completions`、`/v1/embeddings`、audio | 200 | 200 | LiteLLM `mac/*` 与 `studio/*`、Open Notebook（都填 `api_key: dummy`）|
| `/api/status`、`/v1/models/status`（管理端点，`verify_api_key`）| 401 | 200 | 链路 A 的 json-exporter |

☠️ **`dummy` 能用全靠 `allow_unauthenticated_inference: true` 这一个开关**。重装 OMLX、在 admin 面板里重置
设置或有人把它关掉，`mac/*` 别名和 Open Notebook 的对话/嵌入/TTS/STT 会一起 401。修法：开关开回来，或给
这两处换真 key（网关另见 [litellm-gateway.md](litellm-gateway.md)）。

⚠️ **对不存在的模型名，chat 会回退到默认模型并把它装进来**（触发换入换出）。测鉴权用 `/v1/models` 或
`/v1/embeddings`（后者对未知模型直接 404）。

**json-exporter 那半边**：Vault → ESO → Secret `monitoring/json-exporter-omlx` → 挂到
`/secrets/omlx/api-key` → 两个模块的 `http_client_config.authorization.credentials_file`。这个文件
**每次请求都重读**（v0.8.0 实测：错 key 立即 503、换回立即 200），轮换 key 不用重启 pod。
OMLX 日志刷 `GET /api/status → 401` 而推理正常 = 这边的 key 与 Mac 上的不一致（或 Secret 没同步）。

**轮换 key**（集群与**每一台** Mac 必须一致；中间几分钟 `up{job="omlx-*"}=0`，没超过 TargetDown 的
`for: 10m` 就不会告警）。在本机仓库根目录跑：

```bash
export VAULT_ADDR=https://vault.meirong.dev
vault kv put secret/homelab/omlx api_key="$(openssl rand -hex 32)"
# ESO 默认 1h 才刷新，打注解立即同步
kubectl --context k3s-homelab -n monitoring annotate externalsecret json-exporter-omlx force-sync="$(date +%s)" --overwrite
# 把新 key 写进每台 Mac 的 settings.json 并重启 OMLX（key 经环境变量传，不上命令行）
cd macbook/ansible && just omlx
```

## 指标清单

链路 A（名字与 help 以 `json-exporter-cm.yaml` 为准）：

| 指标 | 说明 |
|---|---|
| `omlx_uptime_seconds{version,default_model}` | 版本号在标签上 |
| `omlx_requests_total` / `_active` / `_waiting` | 累计请求 / 在飞 / 排队 |
| `omlx_prompt_tokens_total` / `omlx_completion_tokens_total` / `omlx_cached_tokens_total` | 累计 token |
| `omlx_cache_efficiency_percent` | 已是百分数（0–100），别再 ×100 |
| `omlx_avg_prefill_tps` / `omlx_avg_generation_tps` | ⚠️ 自启动以来的累计平均，见陷阱 1 |
| `omlx_custom_kernel_available{kernel}` / `omlx_ane_prefill_patch_available` / `_configured_models` | 能力位（M2 实测 4 个内核全 0）|
| `omlx_model_loaded{model,engine,source}` | 驻留 0/1（面板的 state-timeline 就是它）|
| `omlx_model_loading` / `omlx_model_pinned` / `omlx_model_context_length` | 装载中 / 是否 pin 住 / context 长度 |
| `omlx_model_estimated_size_bytes` | 估算体积（**天花板核算用的就是这个**）|
| `omlx_model_resident_actual_size_bytes{model,engine}` / `omlx_model_resident_last_access_seconds` | 实际驻留字节 / 最近访问（unix 秒，空闲 = `time() - 本值`）；**只有驻留中的模型才有** |
| `omlx_pool_ceiling_bytes` / `_current_memory_bytes` | 池天花板 / 当前核算占用 |
| `omlx_pool_model_count` / `_loaded_count` | 发现的模型数 / 驻留数 |
| `omlx_pool_load_seconds_per_gb` / `_load_observations` | 装载速度滚动估计 + 样本数 |

链路 B（`omlx_alltime_*`）：全部是 counter，每个字段出两份，全局不带标签，per-model 带 `{model="<slug>"}`
且名字里多一节 `model`。☠️ **两份别混进同一个 `sum()`**。

| 指标（全局 / per-model） | 说明 |
|---|---|
| `omlx_alltime_requests_total` / `omlx_alltime_model_requests_total` | 累计完成请求数 |
| `omlx_alltime_prompt_tokens_total` / `…model_prompt_tokens_total` | 累计 prompt token（**含缓存命中**）|
| `omlx_alltime_cached_prompt_tokens_total` / `…model_…` | 其中由 KV 缓存直接供给、没有真的 prefill 的部分 |
| `omlx_alltime_processed_prompt_tokens_total` / `…model_…` | prompt 减 cached，**真正 prefill 过的量**（算 prefill 速度只能用它）|
| `omlx_alltime_completion_tokens_total` / `…model_…` | 累计解码产出 token |
| `omlx_alltime_prefill_seconds_total` / `…model_…` | 累计 prefill 墙上秒数（链路 A 没有的分母）|
| `omlx_alltime_generation_seconds_total` / `…model_…` | 累计解码墙上秒数（同上）|
| `omlx_alltime_stats_file_mtime_seconds` | 源文件 mtime（**源数据**新鲜度）|
| `omlx_alltime_stats_collected_timestamp_seconds` | 快照渲染时刻（**采集器**新鲜度，见陷阱 9）|

```promql
# prefill tok/s：分子必须扣掉缓存命中，否则被命中率放大（命中率高时是数倍虚高）
rate(omlx_alltime_processed_prompt_tokens_total[30m]) / rate(omlx_alltime_prefill_seconds_total[30m])
# 解码 tok/s，按模型
rate(omlx_alltime_model_completion_tokens_total[30m]) / rate(omlx_alltime_model_generation_seconds_total[30m])
# KV 缓存命中率（与 omlx_cache_efficiency_percent 同义，但分窗口）
rate(omlx_alltime_cached_prompt_tokens_total[30m]) / rate(omlx_alltime_prompt_tokens_total[30m])
```

☠️ **`rate()` 窗口不得短于 15m，建议 30m 起**：源文件 300s 才落盘，计数器是台阶状的，窗口一短大部分
采样点读到 0，曲线变成一排尖刺加一片空白。

## ☠️ 陷阱（按踩到的概率排序）

1. **`avg_*_tps` 不是当前速度**，是自启动以来的累计平均，跑久了几乎不动。「现在多快」有两个口径，别混：
   `rate(omlx_completion_tokens_total{job="omlx-status"}[…])` 是**含空闲**的墙上吞吐（闲着掉到 0）；
   链路 B 的 tokens/seconds 比值是**纯推理速度**（闲着不动）。
2. **天花板核算 ≠ 实际内存**。pool 按 `estimated_size` 记账，`actual_size` 可能高出几十个百分点，偏差因模型
   而异，别当固定系数。「核算没到天花板」不等于还有余量。余量在那台 Mac 上看 `memory_pressure` 末行的
   `System-wide memory free percentage`（macOS 没有 `free`；`free -m` 那套判据只适用于 Linux 节点）。
3. **未驻留模型没有 `actual_size` / `last_access`**（源端 `null`）。json_exporter 遇 `null` 丢弃该指标并
   **每次抓取刷一条 ERROR**，所以这两个字段单独放在 `omlx_model_resident`、用 `?(@.loaded == true)` 过滤，
   ⚠️ 别合并回 `omlx_model`。绕不开的一条：根对象上的 `load_seconds_per_gb_estimate` 在**这次启动后还没
   装载过模型**时是 `null`（filter 只作用于数组；v0.8.0 的 `SanitizeValue` 只认 `<nil>`），那段时间
   `omlx_pool_load_seconds_per_gb` 缺席、日志每 30s 一条 `path="{ .load_seconds_per_gb_estimate }" value=null`。
   **这条 ERROR 是信号不是故障**，别为它删指标。
4. **`up{job="omlx-*"}` 分不清 exporter 挂了还是 Mac/OMLX 挂了**（probe 形态的固有代价）。这两个 job 与各
   Mac 的 node-exporter job 都在内置 `TargetDown` 的覆盖面里（没有排除项）；Mac `pmset disablesleep` 常开，
   响了就是真故障，**别为降噪去排除**。`omlx-*` 挂、`node-exporter-macbook` 活 = Mac 在、OMLX 不在：先看
   `launchctl print gui/501/sh.brew.omlx` 的 `runs` / `last exit code` 与 `/opt/homebrew/var/log/omlx.log`。
5. **两套计数器重启行为相反**：链路 A 的 `omlx_*_total` 随进程重启归零，链路 B 的 `omlx_alltime_*_total`
   跨重启累加。`rate()`/`increase()` 两边都能跨过重置；「总量」类面板别对链路 A 上 `max_over_time`，要真·总量用 `omlx_alltime_*`。
6. **30s 抓一次，比一次换入换出还慢**（小模型装载 ~1s/GB），时间线可能整段错过；判断有没有换模型用
   `changes(omlx_model_loaded[…])` 的事件计数。间隔刻意不是 15s：OMLX 是单进程 Python，大 prefill 期间
   事件循环卡住，抓超时恰好发生在最该看数据的时候。
7. **`custom_kernels` 是字典不是数组**，jsonpath 带不出 key 名，4 个内核只能在配置里逐条写死。OMLX 新增
   内核时这里不会自动出现，面板少一格，不报错。
8. **链路 B 在抓取时改名**（`omlx_` → `omlx_alltime_`，`kube-prometheus-stack.yaml` 里 `metric_relabel_configs`
   的锚点 `*omlx_alltime_rename`，每个跑 OMLX 的 Mac 的 node-exporter job 都要挂）。不改名的话同名不同义的两份
   序列（自启动 vs 跨重启）只差 `job` 标签，漏写 `job=` 的 `sum()` 得到一条**看起来完全合理的双倍曲线**，
   不报错。反过来，Mac 上的 `omlx.prom` 和 **mlx-learning 仓 `docs/serving.md` 的 PromQL 示例**用的是原名，
   照抄进 Grafana 查不到，自己补 `alltime`。
9. **「陈旧」有两种，别拿一个当另一个**：`omlx_alltime_stats_file_mtime_seconds` 老了 = OMLX 闲着或停了
   （只在有请求时落盘），正常；`node_textfile_mtime_seconds{file="omlx.prom"}` /
   `omlx_alltime_stats_collected_timestamp_seconds` 老了 = **采集器死了**。☠️ 渲染器读文件失败时故意保留旧
   `.prom` 不写归零的（归零会被读成计数器重置，把跨空档的每条 `rate()` 打出洞），所以采集器死了只能靠
   这两个 mtime 看出来。
10. **退役模型永远不消失**：`stats.json` 保留每个服务过的模型、从不清理，序列数（7 字段 × 模型数 × 2 +
   元数据）只增不减。面板按 `model=` 过滤，别默认 `All`。
11. **渲染器在另一个仓**。本仓 Ansible 只调度它、**不创建那个 venv**：缺 venv 时 `just omlx-metrics` 明确失败
   并给出 `uv sync` 的修法。升级 mlx-learning 后不用重跑 playbook，plist 指的就是 venv 里的脚本。

## 物理约束（读面板要知道的）

**mac-studio**：OMLX 设置全用默认，内存天花板是自动档（约 106 GiB，随可用内存小幅浮动）。模型
`Qwen3.8-27B-MLX-4bit`，开了 DFlash2 投机解码（草稿模型另占内存），见 `macbook/ansible/README.md`。
下表**只是 mbp-m2-pro 的**（取自其 `~/.omlx/settings.json` 与 `model_settings.json`，归 admin 面板管）：

| 设置 | 值 | 对面板的含义 |
|---|---|---|
| `memory.memory_guard_custom_ceiling_gb` | 30.0 | `omlx_pool_ceiling_bytes` = 32212254720 |
| `memory.soft_threshold` / `hard_threshold` | 0.85 / 0.95 | 内存占用 stat 的两档阈值 |
| `scheduler.max_concurrent_requests` | 2 | 在飞到 2 就满，其余进 `waiting` |
| per-model `ttl_seconds`（语音/嵌入/重排）| 900 | 空闲 15 分钟即卸载；面板的 900s 阈值线 |
| 全局 `idle_timeout_seconds` | `None` | 大模型没有 TTL，只受内存压力驱逐 |

两个大模型同时驻留就顶穿 30G，这是换入换出的物理原因，不是配置失误（网关因此只暴露一个，见
[decisions/litellm-llm-gateway.md](../decisions/litellm-llm-gateway.md)）。

## 为什么是这两条链路

- **B 走 textfile 不再加 exporter**：`stats.json` 是本地文件，够着它就得给 tailnet 上的笔记本新开端口；
  textfile collector 零新端口、零常驻进程、零额外 target，渲染器是 `mlx-learning` 仓已有的
  `omlx-textfile-collector`（带单元测试）。
- **A 用现成 json_exporter 不自研**（按 [decisions/](../decisions/README.md) 惯例先跑现成方案）：v0.8.0 覆盖两个
  端点全部有用字段（含数组展开成 per-model 标签），零代码、零 E1 内嵌脚本，两处别扭（陷阱 3、7）在配置层
  绕开，所以没有 ADR。

复现（本机 docker，不动集群；在仓库根目录跑）：

```bash
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

`cd macbook/ansible && just omlx-metrics` 会跑完下面这套并打印结论。单独看某一段（以 M2 为例，Studio 换成
`matstudio@100.98.220.75`）：

```bash
# 1. node_exporter 在读那个目录吗（缺 flag 时这条指标根本不存在，不是 0）
ssh -i ~/.ssh/vgio matthew@100.89.15.120 \
  'curl -s localhost:9100/metrics | grep -E "^node_textfile_(scrape_error|mtime_seconds)"'
# 2. 快照本身（条数 >0）
ssh -i ~/.ssh/vgio matthew@100.89.15.120 \
  'grep -c "^omlx_" ~/.local/var/lib/node_exporter/textfile_collector/omlx.prom'
# 3. LaunchAgent 在按 60s 转吗（☠️ 是 StartInterval 不是 KeepAlive，state=not running 正常）
ssh -i ~/.ssh/vgio matthew@100.89.15.120 \
  'launchctl print gui/$(id -u)/com.meirongdev.omlx-textfile-collector | head -5;
   stat -f "%Sm %N" ~/.local/var/lib/node_exporter/textfile_collector/omlx.prom'
```

```promql
count(omlx_alltime_requests_total)                       # 应等于在跑链路 B 的 Mac 台数（每台一份全局）
count(omlx_alltime_model_requests_total)                 # 应等于各台 stats.json 里的模型数之和
time() - omlx_alltime_stats_collected_timestamp_seconds  # 采集器新鲜度，应 < 120s
```
