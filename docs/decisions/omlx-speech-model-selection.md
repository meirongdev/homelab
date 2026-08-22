# Mac OMLX 新增的四个语音模型全部不采纳：现役 Qwen3-ASR / Qwen3-TTS 留任

> 日期: 2026-08-22
> 状态: ❌ 否决四个新增模型 —— Open Notebook 的 STT/TTS 接线一字不改（重评条件见文末）
> 关联：[reference/open-notebook.md](../reference/open-notebook.md)（模型接线的**唯一真相源**）·
> 真相源清单在 `k8s/helm/manifests/personal-services/open-notebook-provision.yaml`
> 复现脚本与音频样本是一次性的，未入仓；复现方法见文末（十几行，重跑即得）。

## Context

Mac（`mbp-m2-pro`，OMLX `100.89.15.120:8000`）上语音相关模型从 2 个变成 6 个（4 个是新增）：

| 模型 | 引擎 | 估算常驻 | ctx | 状态 |
|---|---|---|---|---|
| `mlx-community__Qwen3-ASR-1.7B-8bit` | audio_stt | 2.41G | 131072 | **现役 STT** |
| `mlx-community__Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` | audio_tts | 2.34G | 131072 | **现役 TTS** |
| `mlx-community__Mega-ASR-8bit` | audio_stt（`config_model_type: qwen3_asr`）| 2.41G | 65536 | 新增 |
| `kamilobad__GLM-ASR-Nano-2512-8bit` | audio_stt（`glmasr`）| 2.36G | 65536 | 新增 |
| `mlx-community__Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit` | audio_tts | 2.34G | 131072 | 新增 |
| `mlx-community__chatterbox-multilingual-v3` | audio_tts | — | 49152 | 新增 |

⚠️ **显存不是判据**：四个 ASR/TTS 的 `estimated_size` 都在 2.3–2.4G，选谁都一样。
（`/v1/models/status` 里 Qwen3-ASR 的 `actual_size` 只有 0.27G，那是"当前实际驻留"的
惰性加载读数，不是模型体积，别拿它当"更省内存"的证据。）

**判据不能看模型卡，只能对着两条真实调用口径测** —— 这两条口径决定了大半个结论：

| | 谁在调 | 实际发出去的是什么 |
|---|---|---|
| **TTS** | `podcast_creator/nodes.py:273` → esperanto `agenerate_speech()` | **只有 `text` / `voice` / `output_file` 三个参数**。没有任何途径传"音色描述"或"参考音频" |
| **STT** | `content_core/processors/media/audio.py:146` → `atranscribe()` | 音频按 **10 分钟**切段、重编码成 **mp3**、**不带 language 提示**、多段并发。**单次请求最长 10 分钟音频** |

STT 那条尤其反直觉：短句准确率几乎不影响结果，**能不能扛住 10 分钟**才是。

## Options — TTS

现役 CustomVoice 的音色白名单现取（9 个：`aiden dylan eric ono_anna ryan serena sohee uncle_fu vivian`）。
两个新 TTS 的 `/v1/audio/voices` 都返回 **空表**，按上面的调用口径直打：

| 模型 | 结果 |
|---|---|
| **CustomVoice（现役）** | ✅ `voice=eric` → 6.3s 出 307KB 真 WAV |
| VoiceDesign | ❌ HTTP 500 `VoiceDesign model requires 'instruct' to describe the voice`。`voice` 字段填音色名、填描述、留空**都是同一个 500**；只有 OpenAI 的 `instructions` 字段能满足它（实测 200/265KB），而 `podcast_creator` 从不发这个字段。**即便**经 speaker profile 的 `tts_config` 注入，那也是 per-profile 不是 per-speaker —— 一档播客里所有人同一个声音，比现状更差 |
| chatterbox-multilingual-v3 | ❌ HTTP 500 `No conditionals available. Either provide audio_prompt/audio_prompt_sr for voice cloning, or ensure conds.safetensors is in the model directory.` 它是零样本音色克隆，要参考音频；**没有"按音色名选人"的入口** |

☠️ 这两个不是"效果差一点"，是**结构上不可能被 Open Notebook 驱动**。它们看起来都像升级
（更新、更灵活、多语言），换上去 `needsModelSetup()` 的黄条照样消失、defaults 照样全绿，
**只在真去合成播客那一步 500**。

## Options — STT

样本全部由现役 CustomVoice 合成（参考文本即 TTS 输入原文），WER 按中文切字、英文切词计。
最后一行是**生产口径**：571s 音频、mp3、无 language 提示。

| 样本 | Qwen3-ASR（现役） | Mega-ASR | GLM-ASR-Nano |
|---|---|---|---|
| 13s 英文单句 | 0.0% | 0.0% | 0.0% |
| 103s 英文对话 | 2.1% | 2.1% | 57.2% |
| ↑ 叠白噪 | 2.5% | **1.7%** | 57.2% |
| ↑ 32kbps mp3 伪影 | 3.0% | **2.1%** | 57.2% |
| ↑ 1.2× 语速 | 3.0% | **1.3%** | 57.2% |
| 16s 中文 / 14s 中英混排 | **2.5% / 3.3%** | 5.0% / 10.0% | 2.5% / 3.3% |
| 85s 中文（夹英文术语） | **2.5%** | 3.2% | 40.5% |
| **571s mp3（生产口径）** | **4.2%，覆盖 99%，42–45s** | ❌ **470.6%**，7475/1448 token，172.8s | ❌ **92.3%**，覆盖 **8%** |

现役模型那一格跑了三次，`4.2% / 99% / 41.9–45.0s` 三次完全一致，不是抽中的好签。

**两个新 ASR 各有一种静默失败**，都返回 HTTP 200：

- **GLM-ASR-Nano：硬截断在约 45 秒。** 103s 样本吐 102 个 token，571s 样本吐 112 个——
  **输出量与输入时长无关**。10 分钟的讲座进去，出来一段听起来完整通顺的开头，丢掉 92%。
  长中文样本还会把已转录的段落**重复**一遍再停。
- **Mega-ASR：长音频重复崩塌。** ≤300s 正常（625 token / 21.9s），**420s 起崩**
  （6450 token / 160.6s），571s 时 7475 token / 172.8s，尾部是同一句话无限重复。
  内容重复的音频触发得更早（163s 就崩）。它在退化英文上确实比现役准 0.8–1.7 个点 ——
  代价是在生产实际使用的长度上不可用。

顺带记一笔：`Mega-ASR` 的 `config_model_type` 就是 `qwen3_asr`，同架构不同 checkpoint；
"名字更大"不代表是现役模型的升级版。

## Decision

**四个新增模型全部不采纳，`DEFAULTS` 与 `PODCAST_TTS` 一字不改。**

- STT 保持 `mlx-community__Qwen3-ASR-1.7B-8bit` —— 唯一能扛住 10 分钟切段的。
- TTS 保持 `mlx-community__Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` —— 唯一能按音色名选人的。
- 也**不注册成非默认的备选项**：Open Notebook 的音频摄取只读
  `default_speech_to_text_model` 一处，注册进去只是又一个假接线（与 Qwen3-Reranker 同理）。

## Consequences

- 播客/摄取链路零改动、零风险 —— 本次产出全是文档。
- 长音频转写的上限由现役模型的 10 分钟表现决定；`content_core` 的 `10 * 60` 是库里
  写死的，不是我们能调的配置项，所以**没有"把段切小一点就能用 Mega"这条路**。
- 顺带验证掉一个此前没确认过的隐患：esperanto 的 TTS 默认 `response_format=mp3`，
  而 OMLX 确实支持（`Testing mp3 output format.` → 24960B 的 MPEG ADTS）。播客合成不会在这里炸。
- 中英混排是现役 STT 相对最弱的一格（3.3%），但两个替代者在这格都更差（5.0% / 10.0%）。

## 重评触发条件

任一条成立就把上面的表重跑一遍（生产口径那一行是唯一必测项）：

1. OMLX 又装了新的 `audio_stt` / `audio_tts` 模型 —— 尤其任何 **Qwen3-ASR 的更大/更新 checkpoint**。
2. `content_core` 升级后 `audio.py` 的分段长度或 mp3 重编码口径变了。
3. `podcast_creator` 开始往 `agenerate_speech()` 传 `instructions` 或 `ref_audio`
   —— 那一刻 VoiceDesign / chatterbox 才第一次具备可比性。
4. Mega-ASR 换 checkpoint 或 OMLX 侧加了重复惩罚/长音频分块。

## 复现

```bash
# 1) 现役 TTS 合成一段 ≥10 分钟、内容互不重复的音频（重复内容会提前触发崩塌，测不准）
curl -s -X POST http://100.89.15.120:8000/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community__Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
       "input":"<一段 50 词左右的英文>","voice":"eric"}' -o p00.wav
# ...重复十几段不同内容，然后：
printf "file '%s'\n" p*.wav > cat.txt
ffmpeg -f concat -safe 0 -i cat.txt -c:a libmp3lame -q:a 4 full.mp3   # 生产送的是 mp3

# 2) 三个 ASR 各转一次，比的是「覆盖率」不是「像不像」
for m in mlx-community__Qwen3-ASR-1.7B-8bit mlx-community__Mega-ASR-8bit \
         kamilobad__GLM-ASR-Nano-2512-8bit; do
  echo "== $m"
  curl -s -X POST http://100.89.15.120:8000/v1/audio/transcriptions \
    -F "file=@full.mp3" -F "model=$m" | python3 -c \
    'import json,sys; t=json.load(sys.stdin)["text"]; print(len(t.split()),"words:",t[:80],"...",t[-80:])'
done
```

判据：词数应接近参考文本；**明显偏少 = 静默截断，明显偏多 = 重复崩塌**，
两者都返回 HTTP 200，只看转写文本开头一眼是看不出来的。
