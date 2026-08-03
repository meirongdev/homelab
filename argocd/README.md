# ArgoCD — GitOps 控制面

整个 homelab + oracle-k3s 的部署都归 ArgoCD 管：charts + values + manifests 全部进 Git，
`git push` → ArgoCD 3 分钟轮询自动同步。**不要**手动 `kubectl apply` 覆盖已纳管资源（会被下次同步拉回）。

## 目录

```
argocd/
├── applications/   # 每个 Application 一个 YAML。root.yaml 是 App-of-Apps，
│                   #   watch 本目录（`recurse: false`，只认本层 *.yaml，
│                   #   子目录不生效），所以改任一 *.yaml + push 即生效。
│                   #   （kube-prometheus-stack / otel / external-dns / backup /
│                   #     personal-services / vault-eso / gateway / falco / …）
├── projects/       # AppProject（homelab.yaml）：命名空间/来源白名单等权限边界
└── install/        # 安装期 patch（argocd-cm-patch.yaml，注入 config）
```

## 快速上手

- 安装控制面: `cd k8s/helm && just deploy-argocd`（幂等；只装 chart + AppProject，**不含** Application 注册）
- 注册 Application: `just deploy-argocd-apps`（单独一步）
- 初始 admin 密码: `just argocd-password`
- 加服务: 走 skill `.claude/skills/add-service/SKILL.md`（要点见 [docs/AGENTS.md · Working Conventions](../docs/AGENTS.md)）

## ☠️ destination 语义（最容易踩的一条）

**2026-08-02 起控制面在 oracle-k3s**，所以 Application 里的
`destination.server: https://kubernetes.default.svc` 指的是 **oracle**；
homelab 负载必须显式写 `https://100.94.186.7:6443`。写错再跑
`just deploy-argocd-apps` 会把整套 homelab 负载装到 oracle 上。
CI 的 H2 规则（`scripts/check-manifests.py`）会校验 `path` 与 `destination` 同集群。

## 详见

- 架构事实: [docs/reference/argocd-app-patterns.md](../docs/reference/argocd-app-patterns.md)
- 控制面迁移/重装 SOP: [docs/runbooks/argocd-control-plane-on-oracle.md](../docs/runbooks/argocd-control-plane-on-oracle.md)
- 主机: `argocd.meirong.dev`（**oracle-k3s 集群**，经 Tailscale 纳管 homelab）
