# Studio 文生图：mflux-server + 自写 OpenAI 转接层，而不是 OMLX 或 mlx-openai-server

> 日期: 2026-10-03
> 状态: ✅ 已完成

## 上下文

想在 Mac Studio（M5 Max / 128G）上跑 **Qwen-Image-2.1**（`Qwen/Qwen-Image-2.1`，diffusers 格式，
33 GB bf16：7.1B 单流 transformer + Qwen3-VL 文本编码器 + 64 通道 VAE），并**接进 LiteLLM 网关**，
即对外是 OpenAI Images API（`POST /v1/images/generations`）。

起点是「装进 OMLX」，那条路不存在（见选项 A）。于是问题变成两件事：**用什么跑模型**，
**怎么变成 OpenAI 接口**。

运行时没什么可争的：[mflux](https://github.com/filipstrand/mflux) 从 0.20.0 起有原生 MLX 的
`QwenImage21`，它的文档在 M5 Max 上实测 1024² / 40 步约 78s，比 diffusers 的 MPS 参考实现（~85s）还快、
数值相关 0.989–0.992。ComfyUI 走 PyTorch MPS、权重格式不同，用户在选型时没选。

## 评估过的选项

### A：OMLX 本身 —— ❌ 它不做文生图

OMLX 0.7.0 的路由只有 chat / completions / responses / embeddings / rerank / audio，
没有 `/v1/images/*`；引擎类型是 batched / vlm / reranker / audio_*。代码里的 "diffusion"
指的是**扩散式语言模型**（按 canvas tok/s 计速，输出是文本），不是图像。venv 里也没有 mflux / diffusers。

### B：`cubist38/mlx-openai-server` 1.8.1 —— ❌ 接口对，模型版本不对

现成的 OpenAI 兼容服务器，`--model-type image-generation` 底层就是 mflux，有
`/v1/images/generations`。但它 `pyproject.toml` 钉着 **`mflux>=0.17.4,<0.18`**，图像预设只有
1.x 的 `qwen-image`；`QwenImage21` 要 mflux ≥0.20。补上 = fork + 升依赖，且它同时钉着
`mlx-lm<0.32`，与 mflux 0.20 要的 `mlx>=0.32.2` 一起解是另一场依赖仗。代价远大于选项 C 缺的那一块。

### C：`Orbiter/mflux-server`（Apache-2.0）—— ✅ 采用为运行时

钉在 `7e26074e4da5`（requirements 钉着 `mflux==0.20.0`）。它明确支持 `qwen-image-2.1`，
自带**排队（一次只跑一个任务，GPU 独占）**、耗时预估、失败不拖垮 worker、网页界面。
**实际跑过**（不是读 README）：1024² / 40 步 **63s**（去噪 52s，1.31 s/step），常驻 42.1 GiB、
峰值 RSS 68.5 GiB，出图正确（中文提示词要素全部到位）。

缺的那块：接口是**异步**的 `POST /api/generate → GET /api/status → GET /api/image`，
LiteLLM 与任何 OpenAI 客户端都接不上。另外两条它自己的毛病决定了部署方式：
`/api/load`（换模型、触发任意下载）与 `/api/clear` **没有鉴权**；出错的任务**不会自己离开队列**。

### D：整个服务自己写（FastAPI + mflux）—— ❌

缺的只是协议翻译，自己写等于重做 C 已经做好的排队、模型装载与任务管理。

### E：LiteLLM `CustomLLM` handler（翻译放在网关里）—— ❌

能用，但翻译与轮询逻辑会住在 homelab 的网关 pod 里，而且**只有经网关的调用者**能用。
放在 Studio 上的转接层让任何 OpenAI 客户端都能直连，和 OMLX 的用法一致。

## 决策

C + 一个自写的薄转接层：

```
tailnet ─► :8010  openai_images_shim.py ─► 127.0.0.1:4030  Orbiter/mflux-server ─► mflux 0.20.0 (MLX)
            /v1/images/generations             异步队列，一次一张
            /v1/models  /healthz  /metrics
```

- 转接层：`macbook/ansible/files/openai_images_shim.py`，标准库单文件，跑在 mflux-server 的 venv 里。
  提交 → 轮询 → 取图（取即删）→ 回 `b64_json`；失败与超时调 `/api/cancel`。
- mflux-server **只监听 127.0.0.1**，对 tailnet 只暴露转接层（无鉴权，与 OMLX 推理端点同口径）。
- 部署：`cd macbook/ansible && just image-gen`（inventory 组 `image_gen`），两个 LaunchAgent，
  最后真生成一张 256² 小图验收。运行时 `HF_HUB_OFFLINE=1`。
- 网关别名 `studio/qwen-image-2.1`；Prometheus job `mflux-mac-studio` 抓转接层的 `/metrics`，
  告警 `MfluxUpstreamDown` 补「转接层活、上游死」那个 TargetDown 看不见的洞。

## 后果

- **只回 `b64_json`**：上游不存图。直连转接层时 `response_format=url` 回 400；但**经网关时**
  LiteLLM 不认识这个模型名，会把 `response_format` 整个当成不支持而 400（连 `b64_json` 也拒），
  唯一有效的绕法是该模型开 `drop_params`（`allowed_openai_params` 对 image_generation 无效），
  代价是经网关请求 `url` 会静默拿到 `b64_json`。
- **串行**：一次一张，1024² 约 63s。经 `llm.meirong.dev` 有 Cloudflare 100s 源站超时（524），
  排到第二张就会超；批量走 Tailscale NodePort。
- ☠️ **内存随出现过的分辨率单调增长，永不释放**（上线当天才发现）：首张 1024² 后常驻 42 GB，
  之后每个新尺寸 +26 GB（1024→256→512→768 一路涨到 122 GB，系统 swap 吃满 49 GB，1024² 从 55s
  掉到 107s、每步 1.31s→4s，经公网必然 524）。同尺寸重复不涨。关掉 `--qwen21-context-cache`
  后起点 29 GB、每个新尺寸 +13 GB —— **减半但不消失**，泄漏的另一半在上游。于是转接层加了
  **尺寸白名单**（4 个，最坏 ≈ 68 GB）。已膨胀时 kickstart mflux-server 即可归零；转接层报
  `mflux_upstream_rss_bytes` 盯它。OMLX 的池天花板（自动档 ~106 GB）**不知道这个进程**。
- ☠️ **SDK 自动重试会放大排队**：OpenAI SDK 对 524 默认重试 2 次，**每次重试都重新提交一张图**，
  实测一个请求在上游堆出 3 张、总耗时 625s、客户端照样失败。转接层在上游已有 2 个未完成任务时
  直接回 429 + `Retry-After: 60`，对外说明里要求文生图 `max_retries=0`。
- **维护面**：一个约 240 行的转接层（本地用假上游测过成功 / n=2 / url 拒绝 / 尺寸透传 400 /
  上游失败 500 / 超时 504 且 cancel 正确），外加一个单人维护的上游。两者都钉版本。
- 上游 main 在 0.20.0 之后合了文本前缀 KV 缓存、融合 Metal 内核、步数复用（TeaCache 式），
  都还没发版；等 mflux 发版、Orbiter 跟进后再升。

## 重新评估的触发条件

- OMLX 支持文生图 → 迁过去，统一到一个服务、一把 key、一套指标。
- `mlx-openai-server` 支持 mflux ≥0.20 / Qwen-Image-2.1 → 换它，删掉转接层。
- Orbiter 自己加了 OpenAI 兼容端点 → 删掉转接层。
- Orbiter 停更且跟不上 mflux 升级 → 转接层改为直接调 mflux 的 Python API（选项 D 的最小形态）。

## 复现

```bash
# A：OMLX 有哪些路由（Studio 上）
ssh -i ~/.ssh/vgio matstudio@100.98.220.75 \
  'grep -o -E "@(app|router)\.(post|get)\(\"/v1/[^\"]+" /opt/homebrew/opt/omlx/libexec/lib/python3.11/site-packages/omlx/server.py | sort -u'
# B：mlx-openai-server 的 mflux 钉版
gh api repos/cubist38/mlx-openai-server/contents/pyproject.toml -H "Accept: application/vnd.github.raw" | grep mflux
# C：部署 + 端到端验收（幂等）
cd macbook/ansible && just image-gen
```
