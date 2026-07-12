# Cloudflare AI Gateway 配置设计文档

**日期**: 2026-05-31  
**状态**: 已批准 → **❌ Deprecated（已退役）**: 落地后 `cloudflare_ai_gateway` Terraform 资源已整体移除（`terraform state rm`），AI 网关需求改由自建 **Bifrost** 满足，见 [2026-06-07-bifrost-llm-gateway.md](2026-06-07-bifrost-llm-gateway.md)。本仓库当前不存在任何 Cloudflare AI Gateway 资源。  
**目标**: 在 `cloudflare/terraform/` 中引入 Cloudflare AI Gateway 的基础 Terraform 配置，为后续接入自建模型与多集群 AI 应用提供统一出口。

---

## 背景与动机

当前仓库已经将 Cloudflare 侧能力按层放在 `cloudflare/terraform/` 管理，主要包含：

- Zero Trust Tunnel 配置
- DNS 记录
- Zone 级 WAF 与安全设置

接下来会有两类自建模型入口需要纳入统一治理：

1. `nv-dgx-spark` 项目中的 OpenAI-compatible 模型入口
2. 一台通过 Tailscale 互联的独立机器（`100.89.15.120`）上的模型入口

目标不是把 AI Gateway “部署到某个 cluster”，而是把它作为 **Cloudflare 账号层能力** 管理。Kubernetes 集群中的应用只负责调用该 gateway，不承载 gateway 本身。

---

## 设计决策

### 决策 1：AI Gateway 放在 Cloudflare 层，而不是任何 cluster

- **放置位置**: `cloudflare/terraform/`
- **原因**:
  - AI Gateway 是 Cloudflare 托管能力，不是 K8s 工作负载
  - `homelab` 与 `oracle-k3s` 都可能成为调用方，放在 Cloudflare 层更符合复用目标
  - 与现有 Tunnel / DNS / WAF 的 IaC 分层一致

### 决策 2：本次只创建 gateway 本身，不创建 custom providers

本次变更只落地 **gateway 基础资源**，不提前创建指向自建模型的 provider 条目。

- **原因**:
  - `nv-dgx-spark` 当前对外可见的是 Tailscale 地址与 HTTP 端口，不满足 AI Gateway custom provider 对 **HTTPS base URL** 的要求
  - 未来 provider 的命名、认证方式、暴露路径仍可能变化
  - 先把 gateway 作为稳定底座纳入 Terraform，避免用占位 URL 制造漂移和错误配置

### 决策 3：升级 Cloudflare Terraform provider 到支持 AI Gateway 的版本

当前仓库的 provider 约束为 `~> 5.0`，本地已安装版本停留在 `5.17.0`；而 `cloudflare_ai_gateway` 资源从 `5.19.0` 起才可用。

因此本设计要求：

- 在 `provider.tf` 中将 provider 约束升级到 **`>= 5.19.0, < 6.0.0`** 或等价的 `~> 5.19`
- 让 AI Gateway 与现有 Tunnel / DNS / WAF 继续由同一 Terraform 工程管理

---

## 架构设计

### 当前阶段的数据流

```text
AI client / app
  -> Cloudflare AI Gateway
  -> 公有模型厂商（如 OpenAI / Anthropic / Workers AI，后续接入时）
```

### 后续接入自建模型后的目标数据流

```text
homelab / oracle-k3s / external clients
  -> Cloudflare AI Gateway
  -> Custom Provider (HTTPS endpoint)
  -> 自建模型入口
     - DGX Spark Bifrost / vLLM
     - 100.89.15.120 上的模型服务
```

### 关键约束

Cloudflare AI Gateway 的 custom provider `base_url` 必须是 **Cloudflare 可访问的 HTTPS 地址**。  
**不能直接使用 Tailscale `100.x` 地址作为 provider URL。**

这意味着未来接入自建模型时，必须先把模型入口暴露为以下任一形式：

1. **Cloudflare Tunnel + hostname**（推荐）
2. 其他 Cloudflare 可访问的 **HTTPS 公网入口**

对于 `nv-dgx-spark`，优先暴露 **Bifrost 网关**，而不是直接暴露每个 vLLM 节点端口。原因是 Bifrost 已经承担了：

- 统一 OpenAI-compatible 入口
- provider 级路由
- 虚拟 key 治理

这样 AI Gateway 只需要面向一个稳定的 HTTPS upstream。

---

## Terraform 资源设计

### 新增资源

在 `cloudflare/terraform/` 中新增独立文件（例如 `ai-gateway.tf`），声明：

```hcl
resource "cloudflare_ai_gateway" "shared" {
  account_id = var.cloudflare_account_id
  id         = var.ai_gateway_id

  authentication            = var.ai_gateway_authentication
  cache_invalidate_on_update = var.ai_gateway_cache_invalidate_on_update
  cache_ttl                 = var.ai_gateway_cache_ttl
  collect_logs              = var.ai_gateway_collect_logs
  rate_limiting_interval    = var.ai_gateway_rate_limiting_interval
  rate_limiting_limit       = var.ai_gateway_rate_limiting_limit
}
```

> 字段名以 Terraform 资源 `cloudflare_ai_gateway` 的实际 schema 为准；本设计的重点是管理边界、默认值策略与文件布局。

### 建议默认值

| 配置项 | 默认值 | 原因 |
|---|---:|---|
| `ai_gateway_id` | `shared-llm` | 表达这是共享的账号级 AI 出口 |
| `authentication` | `true` | 避免未认证请求直接穿过 gateway |
| `collect_logs` | `true` | 先获得可观测性 |
| `cache_ttl` | `0` | 默认关闭缓存，避免对推理请求产生意外语义影响 |
| `cache_invalidate_on_update` | `true` | 后续 provider 变化时避免旧缓存残留 |
| `rate_limiting_interval` | `0` | 默认关闭限流，先不影响现有客户端 |
| `rate_limiting_limit` | `0` | 与上面配套，显式表示未启用 |

### 本次不纳入 Terraform 的字段

以下能力暂不在第一阶段落地，除非后续确认确有需求：

- `logpush`
- `retry_*`
- `otel`
- `zdr`
- `dlp`
- `stripe`
- `store_id`
- `ai_gateway_dynamic_routing`

原因是这些都属于“已经有明确流量和运营诉求后再打开”的增强项；在没有真实调用流量前先加进去，只会扩大配置面和误配风险。

---

## 文件变更清单

### 修改

- `cloudflare/terraform/provider.tf`
  - 升级 Cloudflare provider 版本约束到支持 `cloudflare_ai_gateway`
- `cloudflare/terraform/variables.tf`
  - 新增 AI Gateway 相关变量
- `cloudflare/terraform/terraform.tfvars.example`
  - 补充 AI Gateway 示例变量
- `cloudflare/terraform/README.md`
  - 说明 AI Gateway 的角色、默认配置与后续接入 custom providers 的前提

### 新增

- `cloudflare/terraform/ai-gateway.tf`
  - 承载 `cloudflare_ai_gateway` 资源定义

### 本次明确不修改

- `k8s/helm/`
- `cloud/oracle/manifests/`
- `argocd/`

原因：本次不涉及任何 in-cluster AI workload、Gateway API、HTTPRoute 或 ArgoCD Application 变更。

---

## 错误处理与边界

### 为什么不直接接 Tailscale IP

虽然 `nv-dgx-spark` 与后续机器都通过 Tailscale 互联，但 Cloudflare AI Gateway 的上游请求并不会运行在 Tailnet 里。  
因此即使 `100.97.87.120`、`100.89.15.120` 对你的设备可达，也 **不代表对 Cloudflare 边缘可达**。

### 为什么默认禁用缓存与限流

- **缓存**：推理请求往往带上下文、温度参数、会话状态。默认开启缓存容易制造“看起来成功但语义错误”的结果。
- **限流**：在还不知道真实客户端并发模式之前，先设成关闭，避免误伤后续集成。

### 为什么先只建 gateway

如果现在就创建 custom provider，只能在以下两种坏选项里二选一：

1. 使用虚假的占位 HTTPS URL
2. 直接写入当前 Tailscale 私网地址

前者会导致配置无意义，后者会导致请求不可达。两者都不值得纳入第一阶段。

---

## 测试与验收

实现阶段需要满足以下验收标准：

1. `cloudflare/terraform` 能成功初始化升级后的 provider
2. Terraform plan 中能正确显示 AI Gateway 资源创建
3. 现有 Tunnel / DNS / WAF 资源无意外漂移
4. README 能明确说明：
   - gateway 不是 cluster workload
   - custom provider 不能直接指向 Tailscale `100.x`
   - 后续推荐先给自建模型入口加 Cloudflare 可访问的 HTTPS 暴露层

---

## 后续阶段（不在本次实现范围内）

### Phase 2：接入 DGX Spark

建议顺序：

1. 给 DGX Spark 的 Bifrost 入口加 HTTPS 暴露层
2. 在 Cloudflare AI Gateway 中创建 custom provider，例如 `dgx-spark`
3. 客户端通过 AI Gateway 调用 `custom-dgx-spark`

### Phase 3：接入 `100.89.15.120`

建议顺序：

1. 先确认该机器上的模型服务接口是否 OpenAI-compatible
2. 给它提供 Cloudflare 可访问的 HTTPS 入口
3. 再创建对应的 custom provider

### Phase 4：增强治理

当真实流量稳定后，再评估是否启用：

- rate limiting
- caching
- retry policy
- logpush / OTEL
- dynamic routing / failover

---

## 最终结论

本次最小且正确的落地范围是：

1. 在 `cloudflare/terraform/` 中引入 `cloudflare_ai_gateway`
2. 升级 provider 到支持该资源的版本
3. 只创建共享 gateway，不提前接任何自建模型 provider
4. 把“自建模型必须先暴露成 Cloudflare 可访问的 HTTPS endpoint”写进仓库文档

这样可以先把 AI Gateway 纳入 IaC，又不会把当前仍处于 Tailscale 私网中的模型入口错误地硬编码进 Cloudflare 配置。
