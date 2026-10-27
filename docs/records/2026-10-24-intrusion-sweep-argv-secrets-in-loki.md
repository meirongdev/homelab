# 双集群入侵排查：未见入侵，但 Tetragon 把命令行里的密钥送进了 Loki

> 日期: 2026-10-24（排查与第一轮修复）· 2026-10-27（第二轮）
> 影响: 未发现入侵迹象。4 处密钥以明文进了 homelab Loki，7 天保留期内能查 Loki 的人都读得到：
>       krr 的 Telegram bot token、夜备的 SurrealDB 口令（7 晚）、homelab cloudflared 的隧道 token、
>       夜备的 Vault token（7 晚，每晚 2 次调用；period 720h、每晚自续期，等于永不过期）。
>       同时查出：oracle 节点上 3 个 k3s 之前的手工遗留在监听（其中 Dante SOCKS 无认证）；
>       oracle 上一份闲置的 cluster-admin SA；两集群 cloudflared 的 `/debug/vars` 对任何 Pod 吐出隧道 token
> 根因: Tetragon v1 把每个进程事件的完整 argv 经 `export-stdout` → OTel 送进 Loki，而脚本把密钥写在
>       命令行里（curl 的 URL、`-u`、`-H`，cloudflared 的 `--token`）。exit 事件与 Tetragon 重启时的
>       补发事件也带 argv，所以长期运行的进程同样会漏。节点遗留与 SA 是仓库外 / 迁移后没人回收的东西
> 处置: 源头把密钥移出 argv（curl `--variable`、env `TUNNEL_TOKEN`），Tetragon 加 6 条
>       `redactionFilters` 兜底；cloudflared 升 2026.10.5；停用节点遗留；删 oracle 的 `argocd-manager`。
>       bot token、两条隧道 token、备份 Vault token 都未轮换（隧道与备份 token 是 10-27 明确决定暂不轮换）

## 经过

| 时间 | 事件 |
|------|------|
| 10-24 | 双集群入侵排查：工作负载 / RBAC / webhook / Falco / Tetragon 事件 / 三节点 SSH 与持久化逐项核过，未见入侵迹象 |
| 10-24 | 在 Loki 的 Tetragon 进程事件里查到两处明文：krr 的 Telegram bot token（拼在 curl URL 里）、夜备的 SurrealDB 口令（`curl -u root:<口令>`，7 晚） |
| 10-24 | `c745393`：krr ×2（两集群各一份）与夜备 SurrealDB 导出改用 curl `--variable`；Tetragon 加 4 条 `redactionFilters`（bot token / `-u` 口令 / Bearer / URL userinfo）；oracle 节点停用 3 个手工遗留；删 oracle 的 `argocd-manager` |
| 10-24 | 同日 Tetragon 重启，给存量进程补发 exec 事件（`flags=procFS`），把 homelab cloudflared 的 `--token` 写进 Loki：当时的过滤器不认 `--token` |
| 10-27 | `67054e6`：为 Cloudflare 安全通告（eMudhra 中间证书）把 cloudflared 升到 2026.10.5，token 改由 env `TUNNEL_TOKEN` 注入 |
| 10-27 | 为 cloudflared 那条回查 Loki，查到夜备每晚 `curl -H "X-Vault-Token: …"` 两次，7 天 28 行明文：10-24 只改了同一脚本里 SurrealDB 那条 |
| 10-27 | `2e2c3c7`：夜备 Vault 调用改 `--variable %VT` + `--expand-header`；过滤器补 `-token`/`--token` 参数值与 `…Token:` 请求头两条 |

## 根因：命令行等于公开

- Tetragon v1 只开了默认的进程 exec/exit 可见性。事件带完整 argv，经 `export-stdout` → OTel → Loki 落盘。
- 不只在进程启动时记一次：exit 事件也带 argv；Tetragon 自己重启时会给所有存量进程补发 exec 事件
  （`flags=procFS`）。所以从没重启过的长期进程（cloudflared 就是），每次 Tetragon 重启都会再进一次 Loki。
- 写法：脚本把密钥拼进 URL、`-u`、`-H` 或 `--token`。oracle 没有 Tetragon，同样的写法只在
  `/proc/<pid>/cmdline` 可见，不进 Loki。
- cloudflared 另有一条独立的漏法：2026.10.4 之前 metrics 端口的 `/debug/vars` 原样吐出 `os.Args`
  （VULN-176088）。两集群的 2026.8.2 实测返回 200 且含 `--token`，而两集群都没有 NetworkPolicy，
  任何 Pod 都读得到隧道 token。

## 处置

1. **源头。**krr、夜备 SurrealDB、夜备 Vault 三处 curl 改成 `export VAR` 后用 `--variable %VAR` +
   `--expand-url` / `--expand-user` / `--expand-header`（curl ≥ 8.3），命令行里只剩 `{{VAR}}`。变量
   缺失时 curl 以 2 退出（variable expansion failure），不会带空值发出去。cloudflared 改由 env
   `TUNNEL_TOKEN` 注入（`tunnel run` 的 `--token` 绑定了这个变量，新镜像实测过），版本选 2026.10.5
   而不是通告点名的 10.3：10.4 修了 VULN-176088，10.5 另修了 VULN-183456。
2. **兜底。**`k8s/helm/values/tetragon.yaml` 的 `redactionFilters` 共 6 条。验证：解析与替换逻辑照抄
   Tetragon v1.7.0 的 `fieldfilters/redaction.go`，输入是 chart 1.7.0 渲染出的 ConfigMap 值，24 个
   样例全过；用 7 天真实 argv（1214 条）回放，密钥形态从 30 条降到 0，唯一误伤是一句
   `seed-token: keep …` 提示文字。
3. **已落盘的明文**随 Loki 7 天保留期过期，没有另行清理。
4. **oracle 节点的手工遗留**（k3s 之前装的，仓库里从没有过），口子后面真有进程在听的三个：
   - 无认证的 Dante SOCKS 代理 `:10080`：`socksmethod: none` + 放行 `0.0.0.0/0`，tailnet 与所有 Pod 都能借它出网
   - 两年没握过手的 WireGuard `wg0 :51420`
   - root 跑的独立 node_exporter `:19898`（哈希与上游 1.3.1 一致）

   文件挪进节点的 `/root/decommissioned-2026-10-24/`（0700），没删。firewalld 规则一条没动：
   `firewall-cmd --reload` 有冲掉 Cilium iptables 的前科（[2026-10-01](2026-10-01-oracle-firewalld-flushes-cilium-iptables.md)）。
5. **oracle 的 `kube-system/argocd-manager`**（cluster-admin + 永不过期 token）自 08-02 控制面迁到
   oracle 后就闲置，live 对象与清单 `cloud/oracle/bootstrap/argocd-manager.yaml` 同日删除。

## 留下的

- bot token（`secret/homelab/telegram`，Alertmanager / falcosidekick / krr / jobs-sg 共用）与备份
  Vault token、两条隧道 token 都未轮换（后两者 10-27 明确决定暂不轮换）；SurrealDB 口令是否轮换没有记录。
- 过滤器只是兜底：带空格且加引号的口令只能打掉一半。新脚本的密钥别进 argv，规则见
  [security.md §8.5](../reference/security.md)。
- oracle firewalld 的收口仍是开放项（[security.md §11](../reference/security.md) 第 6 条）。
