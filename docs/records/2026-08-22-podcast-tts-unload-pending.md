# 播客整集失败于一句 `is busy`：Mac 换模型时 TTS 拒绝服务，而重试只等 15 秒

> 日期: 2026-08-22
> 影响: Open Notebook 播客「agent memory」（solo_expert，45 个 clip）在音频合成阶段整集失败；
>       此前已完成的 outline + transcript（DGX 调用）全部作废。**只影响播客生成，
>       摄取/对话/嵌入均正常**，无数据损坏。
> 结果: 重跑即成功（45 clip / 9 批）；把重试耐心从 ~15s 提到 ~135s 收进清单
>       （`PODCAST_RETRY_MAX_ATTEMPTS=6` / `PODCAST_RETRY_WAIT_MAX=60`）。
> 触发: 合成第 2 批 clip 时，我正在同一台 Mac 上跑 ASR 选型评测
>       （见 [decisions/omlx-speech-model-selection.md](../decisions/omlx-speech-model-selection.md)），
>       反复换入 Mega-ASR / GLM-ASR-Nano → OMLX 决定腾出 TTS 模型。
> 根因: OMLX 把待卸载的模型标成 `unload pending` 后**对所有请求报错**，
>       而 podcast_creator 的默认重试只等约 15 秒，等不到卸载完成。

## 一句话根因

**Mac 是按需换入换出模型的笔记本**：另一个模型要内存时，OMLX 会把 TTS 模型标为待卸载，
此后它对每个请求回

```
Model 'mlx-community__Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit' is busy;
cannot start work while unload is pending until active requests finish or are aborted
```

这个状态**一直持续到对面那个在飞的请求跑完** —— 我那次在飞的是一个 10 分钟音频的 STT 请求，
单次 172.8s。而 podcast_creator 的默认重试是 3 次 / `wait_exponential(multiplier=5, max=30)`
= 只等 5s + 10s ≈ **15 秒**，第 3 次失败就抛。

`generate_all_audio_node` 用 `asyncio.gather` 且不吞异常，所以**一个 clip 失败 = 整集失败**，
而它前面已经烧掉了 outline + transcript 的 LLM 调用。

## 时间线（UTC）

| 时刻 | 事件 |
|---|---|
| 06:26:20 | 用户提交播客 `agent memory`（solo_expert / 4 段）|
| — | outline + transcript 完成（DGX `deepseek-v4-flash`）|
| 06:35:05 | 批 2 的 clip 0006–0009 在 60ms 内并发发出 |
| 06:35:07 | 第 3 次重试失败 → `RuntimeError: Failed to generate speech: ... is busy` → 整集 failed |
| 06:58 | 排查：`/v1/models/status` 显示 `loaded=0/15`（Mac 已全部空闲驱逐）|
| 07:00 | 单发 TTS 请求 200 / 3.7s —— 确认是瞬时争抢，不是配置缺陷 |
| 07:02:12 | `POST /api/podcasts/episodes/<id>/retry` 重新提交（此期间不在 Mac 上跑任何东西）|
| 07:02:46 | outline 完成（4 段，31s）|
| 07:07– | 45 个 clip 分 9 批合成，每批 5 路并发约 2 分钟 |

## 排查中被否掉的那条路

第一反应是「并发太高」——日志里 5 个 clip 在 60ms 内齐发，很像把笔记本打爆了。
**实测否掉**：空闲 Mac 上 5 路并发全 200，且**比串行快一倍**（16.6s vs 33.9s，OMLX 会合批）。

| | 5 路并发 | 串行 |
|---|---|---|
| 5 个 clip 总耗时 | **16.6s** | 33.9s |
| 失败数 | 0 | 0 |

所以 `TTS_BATCH_SIZE`（默认 5）不是病因，调小它只会让播客更慢。
**病因是重试耐心配不上「模型换入换出」这个物理事实**，改的必须是耐心。

## 修复

清单里加两个环境变量（`k8s/helm/manifests/personal-services/open-notebook.yaml`）：

| 变量 | 上游默认 | 现值 | 效果 |
|---|---|---|---|
| `PODCAST_RETRY_MAX_ATTEMPTS` | 3 | **6** | — |
| `PODCAST_RETRY_WAIT_MAX` | 30 | **60** | 退避 5+10+20+40+60 ≈ **135s** 耐心 |

（`podcast_creator/retry.py::get_retry_config` 读这两个 env，优先级低于 configurable dict、
高于硬编码默认值。`PODCAST_RETRY_WAIT_MULTIPLIER` 保持 5。）

## 留下的话

- ⚠️ **在 Mac 上跑别的模型工作时不要同时生成播客**，反之亦然。135s 耐心能跨过一次普通的
  模型换入换出，但**跨不过一个 10 分钟音频的 STT 请求**（172.8s）——那种批量活儿要么错开，
  要么先跑完再点播客。
- 一集 45 个 clip、每批约 2 分钟 → 音频阶段约 18 分钟。中途任何一个 clip 用尽重试，
  整集连同前面的 LLM 产出一起作废；上游没有断点续跑。
- 这次的错误信息是**清楚**的（`is busy` 直说了原因），代价只是重试太浅。
  这与同期语音选型踩的那类静默失败（HTTP 200 却截断/重复）正好相反 ——
  见 [decisions/omlx-speech-model-selection.md](../decisions/omlx-speech-model-selection.md)。
