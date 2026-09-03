# DGX 换了主力模型：homelab 侧跟进 SOP

> Last updated: 2026-09-03
> Status: 生效事实 + 切换 SOP
> 触发条件：`100.97.87.120:8000/v1/models` 返回的 served name 与仓库里的引用不一致
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

```bash
curl -s -m 8 http://100.97.87.120:8000/v1/models | python3 -c 'import sys,json
d=json.load(sys.stdin)["data"]
[print(m["id"],"| root=",m.get("root"),"| ctx=",m.get("max_model_len")) for m in d]'
```

| 现象 | 结论 | 去哪 |
|---|---|---|
| 200，但 served name 不是仓库里那个 | **换栈**，走本文 | 本文 |
| 连不上 / 非 200，而 node-exporter 在线 | 引擎挂了 | 告警 `DgxSparkVllmDown` 的 description（runbook 在 nv-dgx-spark 仓库） |
| 两个 target 都抓不到 | 整机或整条出网没了 | 告警 `DgxSparkNodeDown` |
| 200、name 也没变，但生成超时 | 僵尸 TP 组（探针级故障） | `DgxSparkVllmStuck` |

☠️ 别用 `/health` 或 `/v1/models` 判活：僵尸 TP 组下它们照样 200。

## 1. 采集新模型的事实（只读，约 5 分钟）

**先采再改**——下面每个数字都直接决定某条配置或某条告警的阈值，抄上游 commit message
会漏掉本仓库特有的耦合。

| 要采什么 | 怎么采 | 谁在用它 |
|---|---|---|
| served name | 上面那条 `/v1/models` | 网关两个别名 + 三处清单的字面值 |
| `max_model_len` | 同上 `max_model_len` | Open Notebook 的 `large_context_model` 与三个播客 profile（按旧 ctx 做的规划会静默超窗） |
| 并发上限 | `curl -s :8000/metrics \| grep cache_config_info` 读 `kv_cache_max_concurrency`，与启动参数 `--max-num-seqs` 比 | `DgxSparkRequestsQueued` 的阈值（§4） |
| 冷启动时长 | 上游 Makefile/commit（`loads Nmin`） | `DgxSparkVllmDown` 的 `for`（§4） |
| 关思考的 kwargs 名与 effort 枚举 | 见下方"三条静默失效" | jobs-sg 的 `DisableThinking`、codex profiles 的 `model_reasoning_effort` |
| 工具调用 | 发一次带 `tools` 的请求看 `finish_reason=tool_calls` | codex / 一切 agentic 消费方 |
| 严格 JSON | 用**消费方自己的提示词**打一次，`json.loads` 其 `content` | calibre 元数据、jobs-sg enrich |

☠️ **这一节存在的理由是三条"看着成功其实没生效"**（全部 2026-09-03 实测过）：

1. **用虚拟 key 查 `/v1/models` 看到的是白名单视图**，不是 live config → 必用 master key（坑 B）。
2. **关思考的 kwargs 名写错也回 200**。新栈认 `enable_thinking`，旧栈的 `thinking` 打上去
   不报错也不生效。判据**只能**是 `usage.completion_tokens_details.reasoning_tokens`：
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
     | python3 -c 'import sys,json;d=json.load(sys.stdin);u=d.get("usage",{})
   print("reasoning_tokens=",(u.get("completion_tokens_details") or {}).get("reasoning_tokens"))'
   done
   ```
3. **`finish_reason=tool_calls` 不等于 JSON 契约通过**：工具调用与"按提示词返回严格 JSON"
   是两件事，后者要用真提示词复验（历史反例：NVIDIA 侧同模型换 provider，思维链分离就变）。

## 2. 改引用（四处清单 + 一个命名决定）

**命名约定：按真实 served name 命名，不做"与模型无关的稳定别名"。** 稳定别名看着能少改，
代价是让"清单写 deepseek、实际给 Qwen"这种谎话进网关（结论与代价见
[litellm-llm-gateway.md 的 2026-09-03 修订](../decisions/litellm-llm-gateway.md)）。

| # | 文件 | 字段 | 备注 |
|---|---|---|---|
| 1 | `k8s/helm/manifests/litellm/litellm.yaml` | `custom_dgx/<name>` 与裸 `<name>` 的 `model_name` + `model: openai/<name>` | `fallbacks: ["mac/ornith"]` 保持不动；☠️ 改完**必须** `cd k8s/helm && just gen-embedded-scripts` |
| 2 | `k8s/helm/manifests/jobs-sg/cronjob-enrich.yaml` | `LLM_MODELS` | **直连** DGX，网关清单帮不上忙；值必须是裸 served name，带前缀会 404 |
| 3 | `k8s/helm/manifests/personal-services/open-notebook-provision.yaml` | `MODELS` + `DEFAULTS` 四个角色 + `EPISODE_PROFILE_LLMS` 三个 profile | 也是裸名（不走网关）；声明式，push 即生效 |
| 4 | `cloud/oracle/manifests/calibre-metadata/metadata-llm.yaml` | 内嵌脚本的 `LLM_MODEL` 默认值 + CronJob 的 `LLM_MODEL` | 走网关，走的是**裸名别名** |

改完跑 `cd /Users/matthew/projects/homelab && just check`（渲染层 `just check-render` 本机
需要 `kubeconform`，CI 覆盖）。

## 3. ☠️ 同步 Postgres 里的虚拟 key 白名单

git 管不到这一半。**只做 §2 不做本节 = 「清单正确 + ArgoCD Synced + 调用全 403」**，
这是本网关最贵的一条坑（全文见 [litellm-gateway.md](../reference/litellm-gateway.md) 坑 A）。

爆炸半径的历史数字：2026-09-03 那次是 **16 把 key 里 8 把**引用 DGX 别名。正确预期是
"改 8 把"，不是"改自己那把"。

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

## 4. 监控侧要重估的三个量（别机械等比）

| 量 | 重估方法 | 上次（2026-09-02/03）的结论 |
|---|---|---|
| `DgxSparkVllmDown` 的 `for` | 必须 > 新栈冷启动，且留得住余量 | 10m→15m：新栈加载 8–11min，10m 会被**正常重启**烧成 critical。刻意不取 2 倍余量（22m）——critical 多盲 7 分钟比误报一次更贵 |
| `DgxSparkRequestsQueued` 的 `> 4` | 看**有效**并发上限：`kv_cache_max_concurrency`（KV 池）与 `--max-num-seqs` 取小的 | 阈值不动：`max_num_seqs` 6→8，但 KV 实测 5.34 才是真瓶颈，等比抬到 6 反而推迟"有人在挨饿" |
| 三条告警 description 里的 runbook 指针 | `make <旧栈>-*`、`-n <旧ns> logs deploy/<旧deploy>` 全量替换 | `v4flash-*` → `qwen38fn-*`、`-n v4flash deploy/v4flash-leader` → `qwen38fn` |

面板通常不用改：`model_name` 是 `label_values()` 的模板变量，换模型自适应
（scrape target 也不含模型名）。

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
  nv-dgx-spark 仓库的 `scripts/qwen-model-switch.sh` 管，改端点时**先看主机名**（Mac 本地
  omlx 与 DGX 都用 8000）。
- **Open Notebook 的旧条目不会自动消失**：provisioner 只增不删。删之前先扫引用
  （notebook / profile 里搜那个 model id），确认无引用再走 `DELETE /models/<id>`。
- **上游侧的回滚条目要留着**：`~/.codex/dgx-models.json` 与 `~/.qwen/settings.json` 里旧模型
  那几条是刻意保留的回滚路径，别当垃圾清掉；自己打的 `.bak-*` 确认可用后再清。
- 护栏依赖模型行为的作业（calibre 元数据），改模型后**先 `DRY_RUN=1` 跑一轮**再置 0；
  合成输入的复验不等于真书库的 DRY-RUN。

## 7. 回滚（上游退回旧模型时）

上游动作在它自己的仓库（`make qwen38fn-rollback` → `make v4flash-run`，旧权重/镜像保留期内
有效）。☠️ 回滚**不是**"git revert 一次就完"：本仓库要按 §2/§3/§4 反向**再走一遍**——
四处清单 + 全部 key 白名单 + 冷启动阈值（旧栈 5m29s，那时 `for` 可以缩回 10m）。
最省事的做法是把旧名字当"下一个新模型"处理，照本文从头执行。

## 8. 历史与后续优化（本节的目的是让下一次更快）

| 时间 | 事件 | 记下的一课 |
|---|---|---|
| 2026-08-01 | 网关落地（DGX 主 + Mac 兜底） | [decisions/litellm-llm-gateway.md](../decisions/litellm-llm-gateway.md) |
| 2026-08-25 | Mac 兜底换 Ornith，别名改名 → key 白名单没跟着改，**全挂** | 坑 A 的由来；从此"改别名必同步改 key" |
| 2026-09-02/03 | DGX 换 Flash-Next，本文全流程 | 8/16 把 key 受影响；两条阈值要重估；`{"thinking":false}` 变静默空操作 |

下一次想省事，值得做的是这两件（已挂 [ROADMAP 开放项](../ROADMAP.md)）：

1. **把 §1 与 §3 脚本化**：一条命令采完 served name/ctx/KV 上限，一条命令 DRY-RUN 列出
   待改 key。今天它们是手写的，下次还要重想。
2. **给 served name 漂移加哨兵**，让"上游换模型"由本仓库主动发现而不是等第一个 404。
   可行形态：黑盒 exporter 抓 `:8000/v1/models` 把 name 导出成指标 + `absent()` /
   与 git 里的期望值不符就 warning。⚠️ 别照抄"抓得到就算活着"——那正是
   `DgxSparkVllmStuck` 要补的盲区。
