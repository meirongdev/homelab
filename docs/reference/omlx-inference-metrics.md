# Mac OMLX 推理指标（采集口径与陷阱）

> Last updated: 2026-08-22
> Status: 生效事实

## 速览

- **OMLX 自己没有 `/metrics`**（0.6.3rc2 实测）。指标由集群内 **json-exporter**
  （`monitoring` ns，prometheus-community 现成组件）翻译 OMLX 的两个**免鉴权 JSON 端点**而来。
- 抓取形态是 blackbox 那一套：Prometheus 抓 exporter 的 `/probe?module=…&target=…`，
  两个 job：`omlx-status`（流量/吞吐）与 `omlx-models`（驻留/内存）。
- 面板：Grafana → **Hardware / Mac OMLX 推理**（uid `omlx-inference`）。
- 这台机器的头号故障模式是**换模型**（换入换出期间对请求回 `is busy`，
  见 [records/2026-08-22-podcast-tts-unload-pending.md](../records/2026-08-22-podcast-tts-unload-pending.md)），
  所以面板把「驻留时间线 + 换入换出事件 + 空闲 TTL」排在吞吐之前。

## 组件与文件

| 东西 | 位置 |
|---|---|
| exporter 清单（Deployment/Service） | `k8s/helm/manifests/monitoring/json-exporter/json-exporter.yaml` |
| 模块配置（JSON→指标的映射） | `k8s/helm/manifests/monitoring/json-exporter/json-exporter-cm.yaml` |
| 抓取配置（两个 job） | `k8s/helm/values/kube-prometheus-stack.yaml` 的 `additionalScrapeConfigs` |
| 面板 | `k8s/helm/manifests/monitoring/dashboards/omlx-dashboard.yaml` |
| Mac 侧主机指标（另一条链路） | node_exporter LaunchAgent，见 [observability-multicluster.md](observability-multicluster.md) |

部署：`git push` → ArgoCD `monitoring-dashboards`（管 `manifests/monitoring/` 整个目录）
与 `kube-prometheus-stack`（多源 values）各自同步，**无需手动 helm/kubectl**。

☠️ **exporter 必须钉控制面**（清单里已写 `nodeSelector`）：worker-106 是 tagged-device，
netmap 里没有 Mac 这个源（与 litellm 同一约束）。调度到 worker 的表现是 **target down**，
不是报错。

## 数据源：OMLX 暴露了什么

| 端点 | 鉴权 | 内容 |
|---|---|---|
| `GET /api/status` | 无 | 全局累计：请求数/token 数/累计平均 TPS/缓存命中/uptime/自定义内核可用性 |
| `GET /v1/models/status` | 无 | per-model：是否驻留/装载中/体积（估算+实际）/`last_access`/context 长度 + pool 天花板 |
| `GET /admin/api/stats` | ❌ **admin 会话 cookie** | 更细：**per-model** token 账本、`alltime` 持久化口径、内存压力档位 |

**`/admin/api/*` 拿不到**：`omlx/admin/auth.py::require_admin` 只认 cookie，**没有 Bearer 通路**；
唯一的免登录旁路是全局设置 `skip_api_key_verification`，那会把「下载/删除模型、重启服务」
一起开放给整个 tailnet —— 不做。要 per-model token 账本只能走登录流程，暂不值得。

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

## ☠️ 陷阱（按踩到的概率排序）

1. **`avg_*_tps` 不是当前速度**，是 `token 数 ÷ 累计 prefill/generate 秒数`（自启动累计）。
   跑久了几乎不动，拿它当实时指标会一直看到「机器很快」。
   要「现在快不快」只能用 `rate(omlx_completion_tokens_total[…])`，
   而那是**含空闲时间**的墙上时间口径 —— OMLX **不暴露**分窗口的纯推理速度
   （累计 prefill/generate 秒数没有出口，靠 tps 反推会被它的 1 位小数四舍五入放大成噪音）。
2. **天花板核算 ≠ 实际内存**。pool 用 `estimated_size` 记账，实测 reranker 估算 0.35G /
   实际 `actual_size` 0.50G（**+41%**）；但它与 4B 嵌入模型同驻时，两个口径合计只差 4%
   —— **偏差因模型而异，别当固定系数用**。「核算没到 30G」不等于机器还有那么多余量 ——
   余量看 `free -m` 的 available（见 [k8s-qos-resource-management.md](k8s-qos-resource-management.md)）。
3. **未驻留的模型没有 `actual_size` / `last_access` 指标**（源端是 `null`）。
   json_exporter 遇到 `null` 会**丢弃该指标并每次抓取刷一条 ERROR 日志**，
   所以这两个字段单独放在 `omlx_model_resident` 里、用 jsonpath `?(@.loaded == true)` 过滤。
   ⚠️ 谁要是把它们合并回 `omlx_model`，就会得到 11 模型 × 2 字段 × 每 30s 的稳定日志噪音。
4. **`up{job="omlx-*"}` 分不清是 exporter 挂了还是 Mac 合盖了**（probe 形态的固有代价）。
   笔记本本来就会睡，与 `node-exporter-macbook` 一样属预期抖动，未纳入 TargetDown 告警。
5. **所有 `*_total` 随 OMLX 进程重启归零**（`_alltime_*` 那套持久化只在 admin API 里）。
   `rate()`/`increase()` 会跨过重置，但「总量」类面板别用 `max_over_time`。
6. **30s 抓一次，比一次换入换出还慢**：小模型装载 ~1s/GB，时间线可能整段错过。
   判断有没有发生换模型，用 `changes(omlx_model_loaded[…])` 的**事件计数**，别只看时间线。
   （抓取间隔刻意不是 15s：OMLX 是单进程 Python，大 prefill 期间事件循环卡住，
   抓超时恰好发生在最该看数据的时候。）
7. **`custom_kernels` 是字典不是数组**，jsonpath 带不出 key 名，4 个内核只能在配置里逐条写死。
   OMLX 升级新增内核时这里不会自动出现 —— 面板少一格，不报错。

## 这台机器的物理约束（读面板要知道的）

来自 Mac 侧 `~/.omlx/settings.json` 与 `model_settings.json`（2026-08-22 实测值）：

| 设置 | 值 | 对面板的含义 |
|---|---|---|
| `memory.memory_guard_custom_ceiling_gb` | 30.0 | `omlx_pool_ceiling_bytes` = 32212254720 |
| `memory.soft_threshold` / `hard_threshold` | 0.85 / 0.95 | 内存占用 stat 的两档阈值就是它们 |
| `scheduler.max_concurrent_requests` | **2** | 在飞到 2 就满，其余进 `waiting`；5 路齐发必然排队 |
| per-model `ttl_seconds`（语音/嵌入/重排）| 900 | 空闲 15 分钟即卸载；面板的 900s 阈值线 |
| 全局 `idle_timeout_seconds` | `None` | 两个 21G/16G 的 VLM **没有 TTL**，只受内存压力驱逐 |

两个大 VLM 各 16–21G，**同时驻留就顶穿 30G** —— 这是换入换出的物理原因，不是配置失误。

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
