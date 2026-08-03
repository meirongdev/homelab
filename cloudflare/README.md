# Cloudflare — 外部接入（DNS + Tunnel + WAF）

对外流量一律走 `Internet → Cloudflare DNS → Cloudflare Tunnel → Cilium Gateway → Service`。
Terraform 管 DNS 记录、隧道与 WAF；集群侧 ingress 入口是 Cilium Gateway API（见 `k8s/cilium/`）。

## 目录

```
cloudflare/
└── terraform/     # DNS + Tunnel + WAF（入口见 terraform/README.md）
```

> 这里只剩 terraform 一个子目录。曾有过的 `workers/`（Sink 短链，submodule）
> 已于 2026-05-27 整体退役，方案存档见
> [plans/archive/2026-03-03-sink-cloudflare-worker.md](../docs/plans/archive/2026-03-03-sink-cloudflare-worker.md)。

## 快速上手

```bash
cd cloudflare/terraform && just init && just apply
```

> ⚠️ 新加子域名**不需要**动这里：写一个 HTTPRoute 即可（external-dns 建记录 + 通配隧道路由转发）。

## 详见

- 入口: [terraform/README.md](terraform/README.md)
- 隧道可观测性: [docs/reference/cloudflare-tunnel-observability.md](../docs/reference/cloudflare-tunnel-observability.md)
