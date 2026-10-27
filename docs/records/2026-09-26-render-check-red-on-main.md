# 渲染检查在 main 上红了 18 天：PyYAML 不认 CRD 里的裸 `=`

> 日期: 2026-09-26（09-08 起红，09-26 发现并修复）
> 影响: static-checks 的 `render` job 自 2026-09-08（run #338）起在 main 上每次都红，18 天里渲染检查对全部
>       App 没有提供任何保护，期间无人发现
> 根因: 2026-09-08 去掉 kube-prometheus-stack 的 `skipCrds` 后，prometheus-operator CRD 里 PromQL 匹配运算符的
>       enum `- =` 进了渲染结果。PyYAML 按 YAML 1.1 把裸 `=` 解析成 `tag:yaml.org,2002:value`，SafeLoader
>       没有它的构造器（`could not determine a constructor`），整个 App 渲染失败
> 处置: `scripts/render-manifests.py` 的 `count_objects` 改用 `RenderedLoader`（SafeLoader 子类，把该类型当普通
>       字符串），与 K8s / kubeconform 的 YAML 1.2 语义对齐，不是放宽校验（`5af6964`）

## 经过

| 日期 | 事件 |
|------|------|
| 09-02 | 渲染检查上线。首次在 CI 上跑就有一个 chart 仓库 DNS 超时（`lookup cloudnative-pg.io … i/o timeout`），整个检查变红；随后加了只针对网络形状错误的重试 |
| 09-08 | `b4cecfa` 移除 kube-prometheus-stack 的 `skipCrds`，prometheus-operator CRD 交 ArgoCD 接管。render job 从这次起每次都红 |
| 09-26 | 发现并修复（`5af6964`） |

## 为什么 18 天没人发现

- Actions 的 step 日志要登录才能读，未登录只能从 run 页面看出是哪一步挂的。
- 红着的 job 没人看，效果等于没有这道检查。

## 本地复现的坑

本机 helm 的 `repositories.yaml` 里有条目但缓存缺失时，**每个** chart 都报 `no cached repo found`，
把真错误淹掉。复现要用干净的 helm 环境模拟 CI runner（仓库根目录执行）：

```bash
HELM_CONFIG_HOME=$(mktemp -d) HELM_CACHE_HOME=$(mktemp -d) HELM_DATA_HOME=$(mktemp -d) \
  uv run --with pyyaml python scripts/render-manifests.py --app kube-prometheus-stack
```

## 验证

干净 helm 环境 + kubeconform v0.8.0 跑全量：修复前 kube-prometheus-stack 失败，修复后 38 个 App 全部渲染
并通过 schema。

## 相关

- 规则与当前行为：[reference/manifest-safety-checks.md](../reference/manifest-safety-checks.md) 的「渲染检查」
