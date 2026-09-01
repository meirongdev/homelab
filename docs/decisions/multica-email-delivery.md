# Multica 验证码投递：选 Gmail SMTP，否决 Cloudflare Email Sending 与 Resend

> 日期: 2026-08-18
> 状态: ✅ 已实施
> 关联: [`runbooks/multica-install.md`](../runbooks/multica-install.md) ·
> [`k8s/helm/manifests/personal-services/multica-secret.yaml`](../../k8s/helm/manifests/personal-services/multica-secret.yaml)

## Context

Multica 的登录靠邮箱验证码（它不支持通用 OIDC，接不进 ZITADEL；另一条路是 Google OAuth）。

**真正的驱动力不是「能发邮件」，而是「停止把验证码写进日志」。** 后端的投递优先级是
**SMTP → Resend → stdout**：两者都没配时，它把 6 位验证码 `fmt.Printf` 到 stdout。而本集群
所有 pod 日志都进 Loki：等于把登录凭据索引进了日志库，任何能查 Loki 的人都能拿到。
这是唯一还敞着的口子，其余（注册白名单、workspace 创建收口）都已关闭。

约束：单用户实例，收件人只有账号持有者本人一个地址。

## Decision

**Gmail SMTP**（`smtp.gmail.com:465`，implicit TLS，应用专用密码），凭据经 Vault → ESO →
`envFrom: secretRef` 注入 backend。chart 没有 `SMTP_*` 字段，但因为 backend 用 `envFrom`
整个注入 Secret，往 Secret 加 key 就是加环境变量：不用改 chart，也不用 fork。

### 否决 Cloudflare Email Sending

首选本来是它：DNS 就在 Cloudflare 手里，记录能自动建，且文档有一条
*"Sending to verified destination addresses in your account is free on all plans, even when
only Email Routing is configured."*：收件人只有自己，看着正好落在免费口子里。

实测否决，两点：

1. 定价表里 **Outbound（Email Sending）在 Workers Free 档写的是 "Not available"**；
   那条免费例外只出现在 **REST API / Workers binding** 的上下文，**SMTP relay 是否同样适用
   没有确证**（Cloudflare 自己的文档也没说）。
2. 实测被挡在域名 onboard 这一关：`550 5.7.1 Email sending is not enabled for domain
   meirong.dev`。⚠️ 注意 **SMTP AUTH 本身是通过的**：token 权限没问题，缺的是把域名
   onboard 到 Email Sending，而这个**没有公开 API**（探过 `accounts/<id>/email_sending*`
   全是 `No route for that URI`），只能在面板点，且大概率会要求升 Workers Paid。

Email Routing（收件）不受影响，仍是免费无限：但它是**纯入站转发，发不了信**。

### 否决 Resend

可行且更规范（免费档 3000 封/月、发任意收件人、非 Beta、API key **只能发信**），
但要新注册第三方账号 + 往 zone 加 SPF/DKIM/DMARC 记录并写进 terraform。
为「一个单用户实例每月几封验证码」付这份接线成本，收益不成比例。

⚠️ 若将来要**邀请他人加入 workspace**，邀请邮件要发给未验证地址：
Gmail 能发（约 500 封/天），Cloudflare 免费档不能。那时优先考虑 Resend。

### 未选 Google OAuth 的原因

它能让日常登录完全不经过验证码，但**关不掉那个口子**：`/auth/send-code` 端点仍在，
任何人用白名单邮箱打一次就会生成一个码并写进 stdout。所以它是 UX 改进，不是本问题的修复。

## Consequences

- ✅ 验证码不再进 pod 日志。实测判据：请一次码后 `verification_code` 表有新行
  （证明码确实生成了）而 backend 日志 `[DEV] Verification code` 行数为 **0**。
  「日志里没有」必须配上「库里有」才成立，否则可能只是压根没生成。
- ⚠️ **发信人只能是那个 Gmail 地址**，写不了 `noreply@meirong.dev`：Gmail 只接受认证账号
  本身或已验证别名当 From。邮件形式上是自己发给自己。
- ⚠️ **爆炸半径比 API key 大**：Gmail 应用专用密码不是只能发信的，同一串密码也能走
  IMAP/POP 读该邮箱**全部邮件**。它不碰 Drive/Photos 且可单独吊销
  （`myaccount.google.com/apppasswords`），但这是这个选择付的主要代价。
  两条收紧路径：换一个**专用发信 Gmail**（泄露时读到的是空邮箱），或转 Resend。
- 换任何 SMTP 服务商都只是改 Vault 里那几个 `smtp_*` key，无需改清单或 chart。

## 重评触发条件

出现任一条就回来重看：① 要邀请他人加入 workspace；② Cloudflare 把 Email Sending 的
SMTP relay 明确纳入免费的 verified-destination 路径（或账号升了 Workers Paid）；
③ 想把发信人换成 `@meirong.dev` 的地址；④ 不再接受 IMAP 可读这个爆炸半径。
