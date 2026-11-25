# jobs-sg — LLM 富化（enrich）

> Last updated: 2026-11-25
> Status: 生效事实
> Scope: `enrich` 阶段经 LiteLLM 网关调 DGX 的接线与取舍、耗时与超时、提速与封顶旋钮、归档读取。
> 2026-11-25 从 [jobs-sg.md](jobs-sg.md) 拆出；部署形态、备份、告警等仍在那篇。DGX 栈本身的事实在
> [litellm-upstreams.md](litellm-upstreams.md)。

## LLM 富化：经 LiteLLM 网关打 DGX

2026-11-11 起 `enrich` 的 `LLM_BASE_URL` 是集群内的 `http://litellm.litellm.svc.cluster.local:4000`，
`LLM_MODELS` 是网关别名 `custom_dgx/DeepSeek-V4.1-Flash-1017`（2026-11-15 前是 `custom_dgx/qwen3.8-flash-next-tp2`；这是对外别名，DGX 实际跑什么见下方链接），带虚拟 key（`key_alias=jobs-sg`，
Vault `secret/homelab/jobs-sg` 的 `llm_api_key` → ExternalSecret `jobs-sg-llm` → env `LLM_API_KEY`）。
此前直连 DGX 的 Tailscale IP；改走网关是为了让 jobs-sg ns 的网络策略碰不到 tailnet。
DGX 栈本身（模型、端口、引擎、档位）的唯一真相源是 [litellm-upstreams.md](litellm-upstreams.md) 的「DGX 主力栈」；
换栈照 [runbooks/dgx-model-swap-homelab-followup.md](../runbooks/dgx-model-swap-homelab-followup.md) 走。

- ☠️ **用 `custom_dgx/` 前缀那条，不用同名裸别名**：裸别名配了兜底，DGX 出错时网关静默换成 Studio 的 Qwen3.8-27B
  作答；而模型名同时是 enrich 缓存键和 `job_tech` 的出处，别的模型的结果会挂着 DGX 的名字进缓存。
  前缀这条没有兜底，DGX 不通就如实报错，岗位留在积压里第二天再试。
- ☠️ 换别名要同时改 key 的白名单（[litellm-gateway.md](litellm-gateway.md) 坑 A），这把 key 只认这一个别名。
- ⚠️ 走集群内 Service，不走 `llm.meirong.dev`：后者经 Cloudflare，有 100s 上限。网关自身不会先于
  `LLM_TIMEOUT` 超时（2026-11-11 查 30 天：15 个 >300s 的请求经网关成功，最长 1267s）。
- ⚠️ 2026-11-11 换名（裸引擎名 → 网关别名）只让缓存对重复描述多算一次：积压按处理层（`source='llm'`）判断，
  与模型名无关，不重跑历史。
- 经网关时思维链在 `reasoning_content`（直连时是 `message.reasoning`）。判「思考关没关」看
  `usage.completion_tokens_details.reasoning_tokens`（关思考时为 0），2026-11-11 经网关实测为 0。

enrich 要模型回严格 JSON（上游 `ExtractPrompt`，六个 key），换模型要连这条一起验。

模型相关参数全部是 `LLM_*` 环境变量（上游 `internal/llm/config.go` 一处解析）：
`LLM_BASE_URL / LLM_MODELS / LLM_TIMEOUT / LLM_CONCURRENCY / LLM_RETRIES / LLM_THINKING /
LLM_THINKING_KWARG / LLM_MAX_TOKENS / LLM_MAX_DESC_CHARS / LLM_PROMPT / LLM_PROMPT_VERSION /
LLM_API_KEY / LLM_AUTH_HEADER / LLM_EXTRA_BODY`。换模型不改代码、不发版；参数写错只丢那一个
旋钮并打告警，启动日志 `llm enabled` 打的是生效值。全表与调参口径在上游
`docs/09-deploy-runbook.md` §3.2/§5，本文只留 homelab 的取值与理由。

换模型的验收（在 jobs-sg 仓库根目录跑，默认跳过、不进 CI）：真调一次并断言推理确实被关掉，
挂了就换 `LLM_LIVE_KWARG` 试。2026-10-04（当时的 Qwen 栈）PASS，即 `LLM_THINKING_KWARG` 保持默认值。

```sh
LLM_LIVE_URL=http://100.94.186.7:31400 LLM_LIVE_MODEL=custom_dgx/DeepSeek-V4.1-Flash-1017 \
  LLM_LIVE_KEY=$(VAULT_ADDR=https://vault.meirong.dev vault kv get -field=llm_api_key secret/homelab/jobs-sg) \
  go test ./internal/llm -run Live -v
```

**取舍**：经网关多一跳和一条 Vault 依赖，换来用量计量（spend log 按 `key_alias=jobs-sg` 可查）和
「jobs-sg 碰不到 tailnet」。刻意不要网关的兜底（见上）。DGX 是跨 tailnet 共享的境内机器
（RTT 66–83ms），不可用时 enrich fail-open 退回纯规则。

### 耗时、超时与并发

- 单次调用（上游 2026-09-03 用 16 条真实岗位、并发 8 实测，当时是 qwen38-flash-next）：开推理
  均值 18.7s、最坏 58.7s、15 条/分钟；`LLM_THINKING=false` 是 2.8s / 6.1s / 154 条/分钟。
  本仓库整轮实测 6.9 条/分钟（242 次调用 / 35 分钟）。两个数口径不同（抽样 vs 整轮、共享 GPU
  上还有别的租户），别互相替换。
- ⚠️ 小样本测不出尾巴：封顶前生产约 1.3% 的调用超过 300s。判断要不要干预看这个比例，不看抽样
  最坏值；短 prompt（约 15s）更不能拿来规划容量。
- `LLM_TIMEOUT=300`。该端点非流式，生成完才回 header，所以预算覆盖整个生成过程（报错里的
  "awaiting headers" 极具误导性）；客户端放弃不会让服务端停止生成，每次超时还白耗一次共享 GPU。
  ☠️ 超时值别卡在真实耗时下面：只有短帖侥幸跑完，表现像「慢」不像「坏」。
- 进度逐条落库，中途被 deadline 杀掉不丢；`enrich_cache` 按 `description_sha256` 去重。
  baseline 积压 2026-09-03 前已排空。
- ⚠️ 并发和 CPU 都不是提速的答案：LLM 阶段 CPU 只有 1m（在等推理），加 CPU 只加速一次性的归档
  扫描；旧模型实测 8× 并发只换来 3.3× 吞吐，DGX 已接近饱和，再加只会加深排队并挤占 Open Notebook。
  清单的 `LLM_CONCURRENCY` 现为 4：11-15 为 TensorFold 的 `max_batch_size: 4` 从 8 降下来，11-17 DGX 换回
  vLLM 后没调回，回调多少合适未实测（待办在 [ROADMAP.md](../ROADMAP.md)）。真正的杠杆是减少 token（下两节）。

## 真正的提速杠杆：关掉 reasoning（`LLM_THINKING=false`）

reasoning 占这类模型约 95% 的 output token。`LLM_THINKING=false` 时发 `chat_template_kwargs`，
键名是 `LLM_THINKING_KWARG`，默认 `enable_thinking`（Qwen 栈 2026-10-04 实测生效）。

- ☠️ 旧键名 `{"thinking": false}` 回 200 但**静默**不生效。设了 `LLM_THINKING=false` 而模型仍在
  推理时，客户端每进程打一条 `reasoning was not disabled` 的 WARN，并点名要改的键。
- 旧栈上 4 条真实岗位实测：平均 60.5s → 3.2s（18.8×），completion token 降一个数量级。键名别照抄
  旧栈，倍率可参考。
- 质量代价小且不是单向变差：裸输出更松（"wear many hats" 会抽出 "hats"），但每个词都过
  `tech_taxonomy` 白名单，没命中的进 `unmapped_tech`、进不了 `job_tech`。白名单才是质量闸门。
- **用法定位**：只用来啃积压，不用于稳态。清单不设它（= 开推理），啃积压走下一节的一次性 Job；
  稳态用封顶。

## 一次性积压回填

当前无积压，需要时照这个做。实测 26–29 条/分钟：8 并发照样把 DGX 推满，别拿「DGX 空闲时单条
3.2s」推成 150 条/分钟。

```bash
# 先停掉正在跑的 enrich：两个进程会争同一个 SQLite 库，且读到同一份积压、把每次 LLM 调用做两遍
kubectl --context k3s-homelab -n jobs-sg delete job -l job-name --ignore-not-found
# 一次性 Job：与 CronJob 同 podspec，只多一个 LLM_THINKING=false，
# 且不带 ArgoCD 标签（否则可能被 sync prune 掉）
kubectl --context k3s-homelab -n jobs-sg apply -f <一次性 Job yaml>
```

进度逐条落库，中途被杀不丢。跑完删掉 Job，之后每晚的 CronJob 用默认（开推理）处理当天新增。

## 稳态旋钮：给推理封顶（`LLM_EXTRA_BODY` + `reasoning_effort`）

清单写 `LLM_EXTRA_BODY={"reasoning_effort":"medium"}`。推理模型会在个别长岗位上把推理写飞
（生成长度双峰：正常 1000–2000 token、跑飞 >7000，是触发了循环），这是 enrich 记 partial 的
常态成因。

- ☠️ partial 了起手别查「DGX 是不是慢了」：先比每输出 token 耗时、排队、抢占这些引擎读数与前夜
  有没有变，没变就是跑飞。
- 生效的是顶层 `reasoning_effort`：能封顶（2026-09 那个栈上它关不掉推理；现行栈的 `none` 能关，11-18 实测）。`chat_template_kwargs` 里的推理预算键
  （`thinking_budget` / `reasoning_max_tokens` / `max_thinking_tokens`）**静默**无效。
- 档位集合以 [litellm-upstreams.md](litellm-upstreams.md) 的 DGX 一节为准（11-18 实测 `none` / `low` / `medium` / `xhigh`）。默认档是 `xhigh`，
  封顶键不能省。⚠️ 直连时集合外的档位整轮 400 全挂；经 `custom_dgx/` 别名时网关的 `upstream_compat` 会把它换成
  不低于它的最小档（坑 E），不报错。档位集合每次换栈都变过，换栈后先核。
- 经 LiteLLM 网关也能传，但裸别名上传错档位会被兜底吞掉、换模型回 200（见
  [litellm-upstreams.md](litellm-upstreams.md) 的 DGX 一节）。本作业用的是不带兜底的 `custom_dgx/` 别名，不受影响。
- 封顶只能封推理。调大 `LLM_TIMEOUT` 没用（生成长度没有实际上界，只受 `max_model_len` 约束）；
  `LLM_MAX_TOKENS` 更糟，模型先把推理写满、`content` 返回 null，慢成功变硬失败，清单刻意不设。
- 封顶效果是在 qwen38-flash-next 上测的（前夜超时的 5 条全部 8–22s 完成，8 条正常岗位合计
  244s → 82s、抽词几乎不变）；之后的栈（含现行 v5.4）都没拿真实提示词重测过。
- `LLM_RETRIES=0`，理由是封顶后本来就不该有超时。⚠️ 别写成「重试几乎没用」：同一岗位每次都是
  重新抽签（`temperature: 0` 挡不住连续批处理的抖动），超时的岗位隔天重跑 76% 一次过。若封顶后
  仍有残留超时，改成 1 是便宜的保险（待办在 [ROADMAP.md](../ROADMAP.md)）。

经过与数值见 [records/2026-09-04-jobs-sg-enrich-runaway-reasoning.md](../records/2026-09-04-jobs-sg-enrich-runaway-reasoning.md)。

## 归档读取：每轮一次，不是每条一次

上游 `738cb98` 起 `mcf.ReadArchiveDescriptions` 按文件分组待取的记录，每个文件只走一遍、只解码
`description`，取齐即停；两个富化层共用同一份描述表。

- ☠️ 别回滚到 `738cb98` 之前的镜像：按每条岗位从头扫 gzip，一轮约 30 CPU 小时，窗口只有 3h。
- 代价是描述表进内存：4,900 条描述峰值 82.5MiB（enrich 512Mi limit）。归档单文件涨到数十万条时
  要重新量，这是用 CPU 换内存。
- 归档读失败会计数并记日志。若再出现「CPU 满载、无日志、无进度」，先怀疑归档读取。
- ⚠️ 看进度别只看 `jobs_sg_enrich_backlog`：它只数 LLM 层未处理的岗位（缺 `source='llm'` 行
  **且**缺 `enrich_done` 标记），整个规则层阶段它一动不动。看 `job_tech` 的 `source='llm'` 行数
  或 `enrich_cache`。

`enrich_done` 记「这层跑过」：LLM 结果全落 `unmapped_tech` 的岗位也写标记，否则会永留积压
（`llm_cached ≈ backlog` 是这个病的指纹）。
