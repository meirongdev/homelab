# DGX 换了主力模型：homelab 侧跟进 SOP

> Last updated: 2026-09-19
> Status: 生效事实 + 切换 SOP
> 触发条件：`100.97.87.120:<port>/v1/models` 返回的 served name 与仓库里的引用不一致
> —— 上游（`~/projects/meirongdev/nv-dgx-spark`）换栈、改 served name、或从换栈中
> **回滚**。也包括它的先兆症状：网关报 404、jobs-sg 富化静默退回规则、
> Open Notebook 选中某模型就报错。任何一次上游模型变更都走本文。
>
> 成功判定（五条全绿，逐条可跑，缺一条就是没做完）：
> 1. `kubectl --context k3s-homelab -n litellm get deploy litellm -o jsonpath='{.spec.template.metadata.annotations.checksum/config}'`
>    的值 = 本地 `just gen-embedded-scripts` 刚写出来的那个；
> 2. **master key** 查 `/v1/models` 能看到两个新别名，且旧别名已消失；
> 3. 用**消费方那把虚拟 key**真发一次指名新别名的补全，回 200 且有 `content`
>    （不是 403，也不是 `/v1/models` 里"看见"就算——见坑 B）；
> 4. 三处直连/经网关的消费方在**集群里**的值已是新名字（`kubectl get … -o jsonpath` 读 env，
>    不是看 git）；
> 5. 全部虚拟 key 的白名单复跑一遍是"0 把待改"。
>
> 回滚：本文的每一步都可逆，但**回滚 = 再做一次换栈**（§7）。上游权重/镜像保留期就是
> 回滚窗口，那之前别在上游清盘。

## 0. 先分流：是"换了模型"还是"上游挂了"

☠️ **先确认端口** —— 这一步 2026-09-19 之前不存在，那次把人坑了：换栈会连端点一起换
（`:8000` k3s/vLLM → `:8888` docker/SGLang），旧端口**完全不监听**（connection refused，
不是 404）。端口也区分不了后端（`:8888` 被三个上游栈轮流用过），所以判据是 served name，
不是端口。现取上游的真相源：

```bash
# 上游 stacks/ 注册表是"谁是主力"的唯一事实源（2026-09-19 起）
cd ~/projects/meirongdev/nv-dgx-spark
PRIMARY=$(cat stacks/PRIMARY)
grep -E '^STACK_(PORT|MODEL|HEAD|RUNTIME|ENGINE|CTXWIN|LOAD_TIME)=' "stacks/$PRIMARY/stack.env"
```

```bash
PORT=8888   # ← 上面读出来的 STACK_PORT
curl -s -m 8 http://100.97.87.120:$PORT/v1/models | python3 -c 'import sys,json
d=json.load(sys.stdin)["data"]
[print(m["id"],"| root=",m.get("root"),"| ctx=",m.get("max_model_len")) for m in d]'
```

| 现象 | 结论 | 去哪 |
|---|---|---|
| 200，但 served name 不是仓库里那个 | **换栈**，走本文 | 本文 |
| 新端口 200、旧端口 refused | **换栈且换了端点**，走本文（端点也要改，见 §2）| 本文 |
| 连不上 / 非 200，而 node-exporter 在线 | 引擎挂了 | 告警 `DgxSparkInferenceDown` 的 description |
| 两个 target 都抓不到 | 整机或整条出网没了 | 告警 `DgxSparkNodeDown`（☠️ 2026-09-19 起只盯 S1）|
| 200、name 也没变，但生成超时 | 引擎卡死 | `DgxSparkInferenceStuck` |

☠️ 别用 `/health` 或 `/v1/models` 判活：卡死时它们照样 200。SGLang 另有
`/health_generate`（**真跑一次生成**），那个才有判别力。
☠️ 也别用「请求成功了」判断模型名对不对：**SGLang 接受任意 model 名并原样回显**
（上游 gotcha #10），只有 vLLM 会 404。

## 1. 采集新模型的事实（只读，约 5 分钟）

**先采再改**——下面每个数字都直接决定某条配置或某条告警的阈值，抄上游 commit message
会漏掉本仓库特有的耦合。

| 要采什么 | 怎么采 | 谁在用它 |
|---|---|---|
| served name | 上面那条 `/v1/models` | 网关两个别名 + 三处清单的字面值 |
| `max_model_len` | 同上 `max_model_len` | Open Notebook 的 `large_context_model` 与三个播客 profile（按旧 ctx 做的规划会静默超窗） |
| **端点端口** | 上游 `stacks/$(cat stacks/PRIMARY)/stack.env` 的 `STACK_PORT` | 网关 `api_base` + 两处直连清单 + Prometheus scrape target（§2/§4）|
| **指标前缀** | `curl -s :$PORT/metrics \| head -1` —— `vllm:` 还是 `sglang:` | 四条告警的表达式 + 整个 dashboard（§4）。☠️ 写错 = 表达式恒空 = 永不触发，且不报错 |
| 并发上限 | `curl -s :$PORT/server_info` 读 `max_running_requests` / `max_total_num_tokens`（SGLang）；vLLM 读 `/metrics` 的 `cache_config_info` | `DgxSparkRequestsQueued` 的阈值（§4） |
| 冷启动时长 | 上游 `stack.env` 的 `STACK_LOAD_TIME` | `DgxSparkInferenceDown` 的 `for`（§4） |
| 有没有自愈 | 上游栈是 k3s（有 liveness 探针）还是 docker（**无探针、无 `--restart`**）| 决定 `DgxSparkInferenceStuck` 的窗口松紧（§4）|
| 关思考的 kwargs 名与 effort 枚举 | 见下方"三条静默失效" | jobs-sg 的 `DisableThinking`、codex profiles 的 `model_reasoning_effort` |
| 工具调用 | 发一次带 `tools` 的请求看 `finish_reason=tool_calls` | codex / 一切 agentic 消费方 |
| 严格 JSON | 用**消费方自己的提示词**打一次，`json.loads` 其 `content` | calibre 元数据、jobs-sg enrich |

☠️ **这一节存在的理由是三条"看着成功其实没生效"**（全部 2026-09-03 实测过）：

1. **用虚拟 key 查 `/v1/models` 看到的是白名单视图**，不是 live config → 必用 master key（坑 B）。
2. **关思考的 kwargs 名写错也回 200**。当前栈认 `enable_thinking`，更早那个栈的 `thinking`
   打上去不报错也不生效。
   ☠️ **判据本身换过一次**：`usage.completion_tokens_details.reasoning_tokens` 是 **vLLM**
   导出的，**SGLang 恒为 `null`** —— 在新栈上照抄下面这段会看到 `reasoning_tokens= None`，
   而那与"推理确实被关掉了"**完全同形**。在 SGLang 栈上请改看
   `choices[0].message.reasoning_content` 的**字符数**（关掉时是 0）。
   下面这段脚本两种判据都打，换栈后看哪一个非空就用哪一个：
   ```bash
   GW=http://100.94.186.7:31400   # 别走 llm.meirong.dev：WAF 对非浏览器 UA 回 1010
   MK=$(kubectl --context k3s-homelab -n litellm get secret litellm-secret \
         -o jsonpath='{.data.master-key}' | base64 -d)
   NEW=<新 served name>
   # 三种写法都回 200，区别只在 reasoning_tokens
   for kw in '' ',"chat_template_kwargs":{"thinking":false}' \
                ',"chat_template_kwargs":{"enable_thinking":false}'; do
     curl -s -m 60 -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
       -d "{\"model\":\"$NEW\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with exactly: OK\"}],\"max_tokens\":128$kw}" \
       $GW/v1/chat/completions \
     | python3 -c 'import sys,json;d=json.load(sys.stdin);u=d.get("usage") or {}
   m=(d.get("choices") or [{}])[0].get("message") or {}
   print("reasoning_tokens=",(u.get("completion_tokens_details") or {}).get("reasoning_tokens"),
         "| reasoning_content_chars=",len(m.get("reasoning_content") or ""),
         "| completion_tokens=",u.get("completion_tokens"))'
   done
   ```
   ✅ 2026-09-19 在 `qwen3.8-27b-sglang` 上跑出来的样子（reasoning_tokens 那列全是 None，
   有判别力的是后两列）：默认 216 字符 / 59 token；`{"thinking":false}` 417 字符 / 117
   token（**静默无效**）；`{"enable_thinking":false}` **0 字符 / 7 token**（生效）。
3. **`finish_reason=tool_calls` 不等于 JSON 契约通过**：工具调用与"按提示词返回严格 JSON"
   是两件事，后者要用真提示词复验（历史反例：NVIDIA 侧同模型换 provider，思维链分离就变）。

## 2. 改引用（四处清单 + 监控两处 + 一个命名决定）

**命名约定：按真实 served name 命名，不做"与模型无关的稳定别名"。** 稳定别名看着能少改，
代价是让"清单写 deepseek、实际给 Qwen"这种谎话进网关（结论与代价见
[litellm-llm-gateway.md 的 2026-09-03 修订](../decisions/litellm-llm-gateway.md)）。

| # | 文件 | 字段 | 备注 |
|---|---|---|---|
| 1 | `k8s/helm/manifests/litellm/litellm.yaml` | `custom_dgx/<name>` 与裸 `<name>` 的 `model_name` + `model: openai/<name>` | `fallbacks: ["mac/ornith"]` 保持不动；☠️ 改完**必须** `cd k8s/helm && just gen-embedded-scripts` |
| 2 | `k8s/helm/manifests/jobs-sg/cronjob-enrich.yaml` | `LLM_MODELS` | **直连** DGX，网关清单帮不上忙；值必须是裸 served name，带前缀会 404 |
| 3 | `k8s/helm/manifests/personal-services/open-notebook-provision.yaml` | `MODELS` + `DEFAULTS` 四个角色 + `EPISODE_PROFILE_LLMS` 三个 profile | 也是裸名（不走网关）；声明式，push 即生效 |
| 4 | `cloud/oracle/manifests/calibre-metadata/metadata-llm.yaml` | 内嵌脚本的 `LLM_MODEL` 默认值 + CronJob 的 `LLM_MODEL` | 走网关，走的是**裸名别名** |

☠️ **端点变了的话（不只是模型名），上面 1–3 还各有一个 URL 要改**，而且 4 不用改
（它走网关，网关帮它挡住了端点变化）：

| # | 字段 | 2026-09-19 的值 |
|---|---|---|
| 1 | 两个别名的 `api_base` | `http://100.97.87.120:8888/v1` |
| 2 | `LLM_BASE_URL` | `http://100.97.87.120:8888` |
| 3 | `CREDENTIALS` 里 `dgx-vllm` 的 `base_url` | `http://100.97.87.120:8888/v1` |

⚠️ 3 的**凭据名不要跟着改**（provisioner 只增不删，改名 = 多一条新凭据 + 一条死条目）。

**监控侧还有两处**，它们在 §4 展开，但属于"必改"而不是"重估"：

| # | 文件 | 改什么 |
|---|---|---|
| 5 | `k8s/helm/values/kube-prometheus-stack.yaml` | `dgx-inference` job 的 target 端口 |
| 6 | 告警 `prometheus-rules.yaml` + 面板 `dashboards/dgx-vllm-dashboard.yaml` | **指标前缀**（`vllm:` ↔ `sglang:`）与随之而来的指标名映射 |

改完跑 `cd /Users/matthew/projects/homelab && just check`（渲染层 `just check-render` 本机
需要 `kubeconform`，CI 覆盖）。

## 3. ☠️ 同步 Postgres 里的虚拟 key 白名单

git 管不到这一半。**只做 §2 不做本节 = 「清单正确 + ArgoCD Synced + 调用全 403」**，
这是本网关最贵的一条坑（全文见 [litellm-gateway.md](../reference/litellm-gateway.md) 坑 A）。

爆炸半径的历史数字：2026-09-03 与 2026-09-19 **两次都是 16 把 key 里 8 把**引用 DGX 别名。
正确预期是"改 8 把"，不是"改自己那把"。其中一把带 alias `calibre-metadata-llm`
（窄白名单，只有 DGX 那一个别名），漏改它 = oracle 的元数据作业全 403。

```bash
GW=http://100.94.186.7:31400
MK=$(kubectl --context k3s-homelab -n litellm get secret litellm-secret \
      -o jsonpath='{.data.master-key}' | base64 -d)
# 列全量：POST 是 405，要 GET + 分页；返回的 keys 是 token 的 sha256（不是 key 原文）
for p in 1 2 3; do curl -s -H "Authorization: Bearer $MK" "$GW/key/list?page_size=50&page=$p"; echo; done
# 逐把看白名单（models 只在 info 里）
curl -s -H "Authorization: Bearer $MK" "$GW/key/info?key=<sha256>" | python3 -c 'import sys,json;d=json.load(sys.stdin);print((d.get("info") or {}).get("models"))'
```

`/key/update` 是**整表替换**，不是增量。脚本必须先读原列表、只映射要改的那两项、其余
原样带回，并且**先 DRY-RUN 打印新旧对照再落库**。想找出哪把是本机的 `LITELLM_VK`：
`printf %s "$LITELLM_VK" | sha256sum` 去匹配列表（别把 key 打进日志）。

## 4. 监控侧：先改"必改"，再重估三个量

### 4.0 ☠️ 必改：换引擎 = 换指标前缀（2026-09-19 新增的一整类工作）

**换引擎（vLLM ↔ SGLang）时，scrape 端口和每一条 PromQL 的指标名都要改。**
这一类失效是**双重静默**的：

- 过期的 scrape target → 该 job `up==0` → `DgxSparkInferenceDown` 会误报一次 critical
  （2026-09-19 实际发生了，而且它是唯一响过的信号，报的原因还是错的）；
- 过期的 `vllm:*` 表达式 → **求值为空 = 永不触发**，Prometheus 不报错、规则页显示 ok，
  面板则全部空白，与"最近没流量"长得一模一样。

☠️ **不能逐字替换前缀了事**，指标名与标签集都不是一一对应的。2026-09-19 实测的映射：

| vLLM | SGLang | 注意 |
|---|---|---|
| `vllm:num_requests_running` | `sglang:num_running_reqs` | |
| `vllm:num_requests_waiting` | `sglang:num_queue_reqs` | |
| `vllm:kv_cache_usage_perc` | `sglang:token_usage` | 都是 0–1 |
| `vllm:iteration_tokens_total_count` | `sglang:generation_tokens_total` | ☠️ **标签集不同**，见下 |
| `vllm:request_queue_time_seconds_bucket` | `sglang:queue_time_seconds_bucket` | 名字少了 `request_` |
| `vllm:prefix_cache_hits/queries_total` | `sglang:prefill_effective_tokens_total{mode}` | ☠️ 口径从**请求数**变成 **token 数**，两栈数值不可比 |
| `process_start_time_seconds` | **不存在** | SGLang 不导出，改用 `resets(sglang:process_cpu_seconds_total[30m]) > 0` |
| `vllm:engine_sleep_state` | **不存在** | 改用 `up` |
| `vllm:num_requests_waiting_by_reason` | **不存在** | 改成 queue/grammar/paused/retracted 四个计数 |

☠️ **两个标签陷阱，踩了就是恒空且不报错**（这是本节最贵的部分）：

1. `sglang:generation_tokens_total` 的标签是 `{engine_type,is_streaming,model_name}`，
   而 `sglang:num_running_reqs` 还多 `moe_ep_rank/pp_rank/tp_rank`。默认的 `and` 要求
   **标签全等** → 直接把两者 `and` 起来**恒为空**。必须显式 `and on(nodename)` 并先
   `sum by (nodename)` 掉 `is_streaming`。
2. `sglang:http_responses_total` **没有 `model_name` 标签** → 面板里加 `$model` 过滤会恒空。

✅ **验证方法（别只靠肉眼比对）**：拿线上 `/metrics` 存成文件，起一个一次性 Prometheus
把规则跑一遍，**正反用例都要**（健康态不报 + 合成故障态真的 firing）。
2026-09-19 就是这么抓到上面第 1 条的：朴素的逐字移植版返回 0 series，显式 join 版返回 1。
☠️ 两个环境坑：Docker 连不到 `100.64/10`（所以要用本地回放而不是直连 DGX），
且 Prometheus 3.x 拒收 `python -m http.server` 的 `application/octet-stream`
（要自己发 `text/plain`）—— 这两个现象都与"我的表达式没匹配上"长得一样。

### 4.1 重估三个量（别机械等比）

| 量 | 重估方法 | 2026-09-19 的结论 |
|---|---|---|
| `DgxSparkInferenceDown` 的 `for` | 必须 > 新栈冷启动（读 `STACK_LOAD_TIME`），且留得住余量 | 15m→**10m**：新栈只加载约 3 分钟（权重 23 GiB，上一栈 126 GiB），余量已有 3 倍；而新栈**无自动重启**，这条是唯一叫人的信号，早 5 分钟有价值 |
| `DgxSparkRequestsQueued` 的 `> 4` | 看**有效**并发上限：条数上限与 KV 池取小的 | **第三次不动**。有效上限 6 → 5.34 → 现在 16（`max_running_requests`；KV 池 1.22M token ≈ 4.6 路满窗，这次条数才是瓶颈）。这条量的是"有没有人在挨饿"不是"用了几成容量"，按 16 等比抬到 12 会让它几乎不可能触发 |
| `DgxSparkInferenceStuck` 的窗口 | 看上游栈**有没有 liveness 探针**：有 → 本条只是兜底，可松；无 → 它是唯一检测，要紧 | `increase[5m]+for5m` → **`increase[3m]+for2m`**。新栈是 docker + tmux，**无探针、无 `--restart`**，兑现了上一版注释里"若哪天探针被移除就收紧"那句预留 |
| 告警 description 里的 runbook 指针 | `make <旧栈>-*`、`-n <旧ns> logs deploy/<旧deploy>` 全量替换 | 上游 2026-09-19 起改成**栈无关**的 `make status/restart/logs/test`（读 `stacks/PRIMARY`），所以这些指针从此不用再跟着换栈改 |
| **告警与 job 的命名** | — | 2026-09-19 一次性去掉引擎名：job `vllm-dgx-spark`→`dgx-inference`，`DgxSparkVllm*`→`DgxSparkInference*`。下次换引擎不用再改名 |
| **`DgxSparkNodeDown` 的范围** | 看主力栈是不是多节点 | 单节点栈下**只盯 S1**（S2 空闲，为它半夜发 🆘 是纯误报）。⚠️ 若换回 TP=2 的栈，**必须把 nodename 过滤去掉**，否则对端节点死了一声不吭 —— 那正是 2026-08-13 事故的成因 |

面板在**只换模型名**时不用改：`model_name` 是 `label_values()` 的模板变量，换模型自适应
（scrape target 也不含模型名）。⚠️ 但**换引擎时整张面板都要改**（见 §4.0），
2026-09-19 那次 19 个面板里有 3 个指标完全没有等价物，只能换口径重画。

## 5. 下发与验收

`git push` → ArgoCD 轮询 3 分钟自动同步（**不要 `kubectl apply` 覆盖**）。按文首"成功判定"
逐条验，注意三条"Synced ≠ 生效"：

| 静默失效 | 为什么 | 判据 |
|---|---|---|
| 网关按**旧路由表**继续跑 | subPath 挂载不收 ConfigMap 更新 + LiteLLM 只在启动时读 config | 看 pod 模板的 `checksum/config` 与 pod AGE（§6 的坑 C） |
| 调用全 403 | 白名单在 Postgres | §3 复跑 = 0 把待改 |
| Open Notebook 默认角色没动 | provisioner 是 PostSync hook，得看它跑没跑 | ArgoCD `syncResult.resources` 里 `kind: Job` 的 `hookType: PostSync` = Synced |

集群内取值的命令形态（别只信 git）：

```bash
kubectl --context k3s-homelab -n jobs-sg get cronjob enrich \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env}' | tr ',' '\n' | grep -A1 LLM_MODELS
kubectl --context oracle-k3s -n personal-services get cronjob calibre-metadata-llm \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env}' | tr ',' '\n' | grep -A1 LLM_MODEL
```

Open Notebook 的接线只能在应用里看（值存的是模型 id，不是名字），照
[open-notebook.md](../reference/open-notebook.md) 那节口径查 `/models`、
`/models/defaults`、`/episode-profiles`。

## 6. 消费方与收尾清理

- **本机 dotfiles**（不在本仓库）：`~/.codex/litellm.config.toml`、
  `~/Library/Application Support/k8sgpt/k8sgpt.yaml`。DGX profile 与 Qwen 启动默认由
  nv-dgx-spark 仓库的 `scripts/qwen-model-switch.sh` 管。
  ☠️ **改端点时先看主机名再看端口**：Mac 本地 omlx 一直是 `100.89.15.120:8000`，而 DGX
  的端口随栈变（`:8000` → 2026-09-19 起 `:8888`）。上游 `stack-switch-cn.md` §3.1 记着
  同一次事故：codex 的 `[model_providers.*] base_url` 漏改，于是它指着一个停机的 `:8000`，
  而 `status` 报一切正常。**只改 model 名不改 base_url = 指向空端口。**
- **Open Notebook 的旧条目不会自动消失**：provisioner 只增不删。删之前先扫引用
  （notebook / profile 里搜那个 model id），确认无引用再走 `DELETE /models/<id>`。
- **上游侧的回滚条目要留着**：`~/.codex/dgx-models.json` 与 `~/.qwen/settings.json` 里旧模型
  那几条是刻意保留的回滚路径，别当垃圾清掉；自己打的 `.bak-*` 确认可用后再清。
- 护栏依赖模型行为的作业（calibre 元数据），改模型后**先 `DRY_RUN=1` 跑一轮**再置 0；
  合成输入的复验不等于真书库的 DRY-RUN。

## 7. 回滚（上游退回旧栈时）

上游动作在它自己的仓库：**`make switch TO=<stack-id>`**（2026-09-19 起统一成这一个动词，
`make stack-check` 列出可选栈；旧权重/镜像保留期内有效）。
☠️ 回滚**不是**"git revert 一次就完"：本仓库要按 §2/§3/§4 反向**再走一遍** ——
四处清单 + 端点 + 监控两处 + 全部 key 白名单 + 三个阈值。
最省事的做法是把旧栈当"下一个新栈"处理，照本文从头执行。

⚠️ 回滚到一个**不同引擎**的栈（例如从 SGLang 退回 vLLM 的 `qwen38fn`）时，§4.0 的
指标前缀映射要**反向**做一遍，并且 `DgxSparkNodeDown` 的 nodename 过滤要去掉
（那是 TP=2 的栈）。这两条都是静默的，回滚后照 §4.0 的一次性 Prometheus 复验一遍。

## 8. 历史与后续优化（本节的目的是让下一次更快）

| 时间 | 事件 | 记下的一课 |
|---|---|---|
| 2026-08-01 | 网关落地（DGX 主 + Mac 兜底） | [decisions/litellm-llm-gateway.md](../decisions/litellm-llm-gateway.md) |
| 2026-08-25 | Mac 兜底换 Ornith，别名改名 → key 白名单没跟着改，**全挂** | 坑 A 的由来；从此"改别名必同步改 key" |
| 2026-09-02/03 | DGX 换 Flash-Next，本文全流程 | 8/16 把 key 受影响；两条阈值要重估；`{"thinking":false}` 变静默空操作 |
| 2026-09-19 | DGX 换 qwen38un（**换引擎 + 换端点 + 变单节点**），本文全流程 | 又是 8/16 把 key。新增的三类工作全部源于"这次换的不只是模型名"：① 端点 `:8000`→`:8888`（三处清单 + scrape target）；② 指标前缀 `vllm:`→`sglang:`（四条告警 + 整张面板，且 3 个指标无等价物）；③ 拓扑变单节点（S2 告警范围、冷启动阈值、Stuck 窗口）。☠️ 两条判据同时失效：`reasoning_tokens` 在 SGLang 恒 null、"请求成功"不再证明模型名对（SGLang 原样回显）|

下一次想省事的完整方案（含实测成本、优先级、被否决的选项）已展开成
[plans/2026-09-03-dgx-model-swap-optimizations.md](../plans/2026-09-03-dgx-model-swap-optimizations.md)，
本节只留结论与指针，实施细节**以那份为准**，两边不各存一份：

1. **§1 与 §3 脚本化**（采集 + 列待改 key），并把散在 5 个文件里的 **16 处模型名字面值**
   收敛到 8 处、由 CI 断言它们等于 `versions.just` 里那个声明值。今天 16 处是人肉搜替。
2. **给 served name 漂移加哨兵** —— 仍未实施，形态**依然成立**：SGLang 的指标同样自带
   `model_name` 标签（2026-09-19 实测，例如 `sglang:num_running_reqs{model_name="qwen3.8-27b-sglang"}`），
   `job="dgx-inference"` 本来就在抓 `/metrics`，所以**一条 PromQL 就够**
   （`absent(...model_name=期望值) and on() up == 1`），零新组件。
   ⚠️ 别照抄"抓得到就算活着"——那正是 `DgxSparkInferenceStuck` 要补的盲区；本哨兵只认"名字漂移"。
   ☠️ **2026-09-19 暴露了这个哨兵的一个盲区**：它只认名字漂移，**认不出端点/前缀漂移**。
   那次 `vllm:*` 全部变空，哨兵的 `absent(...)` 反而恒真、`up==1` 恒假，整条表达式为空 =
   不报。真正需要的第二条是"**本该有的指标族整个消失**"，形如
   `absent(sglang:num_running_reqs) and on() up{job="dgx-inference"} == 1`，
   实施时两条一起加。

## 9. 附录：本仓库管不到的依赖（谁有权限改）

换栈这件事**大部分东西不在 git 里**，也不在本仓库能写的地方。出事先照这张表定位归属，
别在 `homelab` 里找不存在的那一半。

### A. 上游推理源（本仓库只有消费权，没有写权限）

| 依赖 | 在哪 | 换栈时的角色 | 坏了是响的还是哑的 |
|---|---|---|---|
| DGX 两台 GB10（`100.97.87.120` head / `100.67.164.92`，2026-09-19 起闲置） | **别人 tailnet 的共享节点**，经 Tailscale node sharing 进来 | served name / **端点** / **引擎** / ctx / 冷启动 / 并发上限 / **拓扑**全部由它单方面决定 | 引擎死 = 响（定向告警）；**换栈 = 哑**（只有第一个 404 或第一张空面板才发现，见 §8 哨兵那条） |
| `nv-dgx-spark` 仓库 | 本机 `~/projects/meirongdev/nv-dgx-spark` | `stacks/PRIMARY` + `stacks/<id>/stack.env` = **"谁是主力"的唯一事实源**（2026-09-19 起）；memwatch、**权重与镜像保留期 = 我们的回滚窗口** | 那边换栈而我们没跟上，表现是哑的（见上一行）。✅ 好消息：make 动词已收敛成栈无关的 `status/restart/logs/test`，我们的 runbook 指针从此不会因换栈而过期 |
| Mac 上的 OMLX（`100.89.15.120:8000`） | 另一台机器（笔记本） | 兜底上游 + embedding / TTS / STT 全在这；`fast` profile 的开关名也在它那边 | 兜底拿不拿得到是哑的（且受 key 白名单影响，见 §3） |
| OpenRouter / NVIDIA build.nvidia.com | 第三方 SaaS | 第三、第四来源；**目录与限额在对方手里**（NVIDIA 点数制 + 40 RPM，OpenRouter 以接口的 pricing 为准） | 免费档 429/503 是响的；目录漂移是哑的 |

### B. 运行时状态：在本仓库部署、但**不在 git 里**

| 状态 | 真身 | 后果 |
|---|---|---|
| 虚拟 key 的模型白名单、花费账本 | LiteLLM 在 `databases/apps-pg` 的 `litellm` 库 | §3；漏改 = 清单正确 + Synced + 全 403 |
| Open Notebook 已注册的模型与 defaults | 应用自己的数据库 | provisioner 只增不删 → 旧条目变死选项，得手删（§6） |
| Calibre 书库内容与 `#meta_src` 标记 | oracle 节点上的 `calibre-books-local` PVC | 元数据作业跑没跑成只能查库，git 里看不出来 |

### C. 消费方配置：在本机 dotfiles

`~/.codex/*.config.toml` 与 `~/.codex/models.json`（窗口靠 catalog 的 `context_window`，
不是 `model_context_window`）、`~/.qwen/settings.json`（真正生效的端点是
`security.auth.baseUrl`）、`~/Library/Application Support/k8sgpt/k8sgpt.yaml`、
`~/.zshrc` 里的 `LITELLM_VK`（所有本机消费方共用一把，坑 A 一旦发生是全体）。
DGX profile 与 Qwen 启动默认由 `nv-dgx-spark/scripts/qwen-model-switch.sh` 管；
☠️ Mac 本地 omlx 与 DGX 都用 8000，**改端点先看主机名**。

### D. 应用源码在别的仓库：homelab 只给 env

| 镜像 | 源码 | 我们改不动的东西 |
|---|---|---|
| `ghcr.io/meirongdev/jobs-sg` | `~/projects/meirongdev/jobs-sg` | 提示词、严格 JSON 契约、**关思考的 kwargs 名**（`{"thinking":false}` 在新栈是静默空操作）、`DefaultTimeout` |
| `litellm/litellm@sha256:…` | 上游开源 | 通配别名的拼接行为（`nvidia/*` 双前缀那条） |
| calibre 镜像 | KovidG 上游 | 我们内嵌的脚本在 git，但 calibre 本体与书库格式不在 |

**这一类是本次最贵的教训**：一条静默失效（关思考的开关名）源头在别人的仓库与镜像里，
本仓库 grep 不到。判据只能是运行时的 `usage.completion_tokens_details.reasoning_tokens`。

### E. 密钥真值在 Vault，git 里只有引用

`secret/homelab/litellm*`（master key / UI 口令 / OpenRouter / NVIDIA）、
`secret/oracle-k3s/calibre-metadata`（那把窄白名单 key），经 ESO → Deployment env。
所以"改一把 key"往往是 Vault + Postgres 两处，而不是改一个文件。

### F. 第三方与网络

Cloudflare（Tunnel / DNS / WAF —— 管理接口经公网会被 `error code: 1010` 挡，所以走
NodePort）、Tailscale（tailnet 归属决定了 oracle 这类 tagged 设备**根本连不到**共享节点，
这正是 `litellm-external` 存在的原因）、GitHub（ArgoCD 的 git 源 + CI + pre-push 钩子）、
镜像与权重分发（litellm 镜像按 digest pin；vLLM 镜像与 NVFP4 权重由上游拉，本仓库不碰）。
