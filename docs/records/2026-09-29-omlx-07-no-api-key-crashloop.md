# OMLX 0.7 没配 API key 拒绝监听：M2 重启后崩溃循环 34h

> 日期: 2026-09-29（09-29 02:52 UTC 起停服，09-30 配 key 恢复）
> 影响: mbp-m2-pro 上的 OMLX 34h 起不来，launchd 拉起后立即退出，累计 11,233 次。期间这台 Mac 的
>       推理与管理端点全部不可用；告警只有 `TargetDown @ macbook`（`omlx-status` / `omlx-models`）每 4h 一条
> 根因: 09-26 OMLX 被悄悄升到 0.7.0rc1（旧进程一直跑到 09-29 重启）。这版不再允许无 API key 监听非回环地址，
>       启动时打出「will be changed to 127.0.0.1… Press Enter to continue」等输入；launchd 下 stdin 是 EOF →
>       退出码 1 → KeepAlive 每 10s 拉起。`network_auth_error` 是硬拒，没有跳过开关
> 处置: Mac 上 `~/.omlx/settings.json` 写入 `auth.api_key`（Vault `secret/homelab/omlx`）+
>       `allow_unauthenticated_inference: true`；json-exporter 经 ESO 挂同一把 key 探管理端点；
>       2026-10-03 起 `just omlx` 纳管这几个键，且 OMLX 不再随 Ansible 升级

## 经过

| 时刻 | 事件 |
|------|------|
| 09-26 | OMLX 升到 0.7.0rc1。旧进程还在跑，看不出任何变化 |
| 09-29 02:52 UTC | 进程重启，新版没 key 拒绝监听 `0.0.0.0`，开始崩溃循环。`TargetDown @ macbook`（omlx-*）开始每 4h 一条，`node-exporter-macbook` 一直是活的 |
| 09-30 | 定位为真故障。Mac 侧手工写入 key（经 stdin 从 Vault 管道写入，不上命令行）+ 推理免鉴权开关，文件改 0600；集群侧 json-exporter 两个模块加 `http_client_config.authorization` |
| 10-03 | `macbook/ansible/playbooks/omlx.yaml` 上线，host/port/key 四个键由 `just omlx` 合并维护 |

## 根因

**版本行为变了，而进程重启前看不出来。**0.7 起非回环监听必须有 key，没 key 时不是报错退出，而是交互式
等确认；在 launchd 下这等于每次启动都立即退出。升级发生在 09-26，炸在三天后的重启，两者之间没有任何信号。

**管理端点从此要 key。**`/api/status` 与 `/v1/models/status` 走 `verify_api_key`，不受
`allow_unauthenticated_inference` 影响；推理端点（`/v1/models`、chat、embeddings、audio）走
`verify_inference_api_key`，开关打开后照旧免鉴权。所以修法是 key + 开关两件一起：只配 key，
LiteLLM `mac/*` 与 Open Notebook 填的 `api_key: dummy` 会一起 401。

## 告警口径

当时文档写着 `omlx-*` 两个 job「未纳入 TargetDown」，这是错的：内置 `TargetDown` 对全部 job 生效、没有
排除项。那条说法的前提（Mac 会睡眠，TargetDown 多是抖动）也已失效：Mac 早已 `pmset disablesleep` 常开，
2026-09 整月 macbook 的 TargetDown 全是真故障。现行判据见
[omlx-inference-metrics.md 陷阱 4](../reference/omlx-inference-metrics.md)：`omlx-*` 挂而
`node-exporter-macbook` 活 = Mac 在、OMLX 不在。

## 验证

- 经 Tailscale：推理端点无认证 / `Bearer dummy` 均 200；管理端点无认证 / dummy 401、带 key 200。
- 用真实 ConfigMap 抽出的配置在本地跑 json_exporter v0.8.0 打 Mac：两模块 200，`omlx-status` 的指标名与
  故障前一致。key 文件换成错值立即 503、换回立即 200，进程不重启，所以轮换 key 不用重启 pod。

## 教训

- OMLX 升级是有意识的动作（`brew upgrade jundot/omlx/omlx`），`omlx.yaml` 只 `state=present`，不跟最新。
- 重装、升级或在 admin 面板里重置设置之后重跑 `cd macbook/ansible && just omlx`。
- 现行配法、端点边界、轮换命令与症状表 →
  [omlx-inference-metrics.md 的「鉴权」](../reference/omlx-inference-metrics.md#鉴权omlx-07-起)。
