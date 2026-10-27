# zitadel ns 一个 PSA 标签都没有：装着 SSO 与身份库，敞了一个多月

> 日期: 2026-08-10（发现并当天收口；自 2026-07-06 迁入 oracle 起暴露）
> 影响: `zitadel` ns（oracle，装着 SSO 与身份库 `zitadel-pg`）吃 PSA 内置默认 `privileged`，
>       且 warn/audit 全空。实测 server dry-run 一个 `hostPID + hostNetwork + privileged + hostPath:/`
>       的 Pod 能建成、零 warning；同一个 Pod 打到 `databases` ns 直接 Forbidden。没有被利用的迹象
> 根因: Namespace 清单里一个 PSA 标签都没写。PSA 对缺标签不报错，静默回落到 `privileged`；
>       `security.md` 等级矩阵旁一直挂着「⚠️ zitadel 没标签」的注释，注释不拦人
> 处置: 当天走完 无标签 → baseline → restricted；CI 加 H5（Namespace 必须显式写 PSA 等级），
>       另加 `just psa-check` 漂移哨兵

## 经过

分两步收紧，因为**顺序不能反**：先在 [`zitadel.yaml`](../../cloud/oracle/manifests/zitadel/zitadel.yaml)
的 `valuesContent` 补 `securityContext` / `podSecurityContext`（chart 默认缺
`allowPrivilegeEscalation: false`、`capabilities.drop[ALL]`、`seccompProfile`；CNPG 渲出来的
`zitadel-pg` 本就达标），helm upgrade 后 10 个容器逐个复核通过、`auth.meirong.dev` 仍 200，
才翻 enforce。反过来先翻 enforce，`zitadel-init` / `zitadel-setup` Job 会被拒。

## 留下的约束

- ☠️ ns 是 restricted 之后，`zitadel.yaml` 里那段 securityContext 不能删。删了运行中的 Pod 毫无异样
  （PSA 只在创建/更新时评估），要等下一次 helm upgrade 才现形，现形方式是 init/setup Job 被拒、
  升级卡在 DB 迁移中途。现行写法见 [security.md §5.1](../reference/security.md)。
- 规则全文见 [manifest-safety-checks.md 的 H5](../reference/manifest-safety-checks.md)。
