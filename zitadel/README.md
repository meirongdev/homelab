# ZITADEL — 身份 / SSO

自托管 OIDC 身份提供商，作为整站 SSO（应用经 oauth2-proxy / 直接 OIDC 接入，`auth.meirong.dev`），
跑在 oracle-k3s 集群。

## 目录

```
zitadel/
├── terraform/    # bootstrap 用户 / 项目 / 应用客户端（入口见 terraform/README.md）
└── scripts/      # 一次性/幂等的配置脚本：OIDC 应用、GitHub IdP、SMTP（旧 OAuth 配置脚本已移除）
```

## 快速上手

```bash
cd zitadel/terraform && just init && just apply
```

## 详见

- 入口: [terraform/README.md](terraform/README.md)
- 踩坑记录: [docs/records/2026-06-07-zitadel-console-grpc-404.md](../docs/records/2026-06-07-zitadel-console-grpc-404.md)
