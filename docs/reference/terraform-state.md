# Terraform state — R2 远程后端

> Last updated: 2026-11-10
> Status: 生效事实（2026-11-09 起全部 root 的 state 在 R2）
>
> 全部 terraform root 的 state 放在 Cloudflare R2 的私有桶 `homelab-tfstate`，S3 backend +
> `use_lockfile` 做锁。凭据在 Vault，由 `scripts/tf-r2.sh` 现取；**入口一律走 `just`**。

## 布局

| 项 | 值 |
|----|----|
| 桶 | `homelab-tfstate`。控制台手工建，**不在 IaC 里**（state 自己不能住在它管的桶里）。默认 jurisdiction，无公共访问 |
| key | `<root 的仓库相对路径>/terraform.tfstate`，如 `cloud/oracle/terraform/terraform.tfstate`。每个 root 的 `provider.tf` 里写死 |
| root 清单 | 会漂，现算：`find . -name '*.tf' -not -path '*/.terraform/*' -exec dirname {} \; \| sort -u`（仓库根） |
| 锁 | `use_lockfile = true`：同目录写一个 `<key>.tflock` 对象，靠 S3 条件写（`If-None-Match: *`）互斥。R2 支持条件写，2026-11-09 实测 |
| 凭据 | Vault `secret/homelab/terraform-r2`，字段 `access_key_id` / `secret_access_key` / `endpoint`。Account API token，`Object Read & Write`，**只授权这一个桶** |
| CI | 刻意没有凭据。`static-checks.yml` 用 `init -backend=false` 做 validate，不碰 state |

☠️ **别和 home-stack 共用 `terraform-backend` 桶。** R2 token 的权限最细只到桶、到不了前缀，
而 home-stack 是公开仓库，它的 CI secret 里有一枚对 `terraform-backend` 的读写 token。homelab
的 state 含明文密钥（两台 VM 的 cloud-init 用户密码、Tailscale 预授权 key、Aiven 服务的连接信息与密码），放进那个桶
就等于交给了那枚 token。归属表 → [decisions/home-stack-repo-boundary.md](../decisions/home-stack-repo-boundary.md)。

## 怎么用

```bash
cd cloudflare/terraform && just plan          # 既有配方照旧，内部已改走包装
cd cloudflare/terraform && just tf state list # 任意子命令：just tf <子命令…>
just oracle-terraform tf output -raw instance_public_ip   # 仓库根：just <模块> tf …
```

⚠️ **裸敲 `terraform` 会失败**：缺凭据时报 `Error: No valid credential sources found`。
本机 `~/.aws` 若有有效的 AWS 登录，报错会变成真 AWS 侧的 `AccessDenied` / `NoSuchBucket`
（请求发去了 AWS 而不是 R2）。两种都是没走包装，换成 `just tf …` 即可。

## `scripts/tf-r2.sh` 做的两件事

1. **注入凭据**：从 Vault 取三个字段，导出为 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
   `AWS_ENDPOINT_URL_S3`，只活在这个 terraform 进程里；并 unset `AWS_PROFILE` / `AWS_SESSION_TOKEN`。
   三个变量**都已在环境里时不碰 Vault**（见下方 break-glass）。
2. **改 state 前拍快照**：R2 没有对象版本，远程后端也不像本地后端那样留 `terraform.tfstate.backup`，
   所以 `apply` / `destroy` / `import` / `taint` / `untaint` / `state rm|mv|push|replace-provider`
   执行前先 `state pull` 到 `<root>/.tfstate-snapshots/<时间戳>-<pid>.tfstate`（0600、gitignored、
   每 root 留最近 20 份）。**拉不下来就中止**，不执行原命令。

从快照恢复（快照的 serial 比远端旧，必须 `-force`；`state push` 本身也会先拍一份当前快照）：

```bash
cd <root> && ls -1 .tfstate-snapshots/ | tail -3
cd <root> && just tf state push -force .tfstate-snapshots/<文件名>
cd <root> && just plan     # 核对
```

⚠️ 快照只在**执行那次命令的机器**上，不进 restic。

## Break-glass：Vault 不可用

Vault 跑在 homelab 集群上，而 `proxmox/terraform` 恰恰是重建那台控制面 VM 用的，所以「集群没了 →
取不到凭据 → 跑不了 terraform」是个真实的环。

**Vault 还在、但马上要没了**（如 [homelab 重建](../runbooks/homelab-rebuild-ubuntu-24-04.md)要先销毁 VM）：
趁它还在，把三个变量带进当前 shell，此后这个 shell 里的 `just` 不再找 Vault（2026-11-09 实测：
`VAULT_ADDR` 指向不可达地址时 `just tf state list` 照常）：

```bash
export VAULT_ADDR=https://vault.meirong.dev
eval "$(vault kv get -format=json secret/homelab/terraform-r2 | jq -r '.data.data | @sh "export AWS_ACCESS_KEY_ID=\(.access_key_id) AWS_SECRET_ACCESS_KEY=\(.secret_access_key) AWS_ENDPOINT_URL_S3=\(.endpoint)"')"
```

**Vault 已经不在**：不经 Vault 另建一枚 token：

1. Cloudflare 控制台 → R2 → Manage API tokens → Create **Account** API token：
   `Object Read & Write`，`Apply to specific buckets only` 只勾 `homelab-tfstate`。
2. 当前 shell 里 export 三个变量（S3 端点就是建 token 那页给的 `https://<account_id>.r2.cloudflarestorage.com`）：

   ```bash
   export AWS_ACCESS_KEY_ID=<…> AWS_SECRET_ACCESS_KEY=<…> AWS_ENDPOINT_URL_S3=<…>
   cd proxmox/terraform && just plan
   ```

3. Vault 恢复后在控制台吊销这枚临时 token。

## 判据与踩坑（2026-11-09 迁移实测）

- **迁移成没成看 resources，别看 serial / lineage。**`init -migrate-state` 之后 R2 那份是
  `serial 1` + 全新 lineage，但 `resources` / `outputs` 与迁移前逐字节相同（7 个 root 全部核对过）。
- **本地 `terraform.tfstate` 迁完会被清空成 0 字节**（已删掉），`terraform.tfstate.backup` 是迁移前内容。
  每个 root 另留了 `terraform.tfstate.pre-r2.backup`（及更早一版 `pre-r2-prev.backup`），只在 M5 上。
- **空 state 不会被迁移。**`zitadel/terraform` 迁移时是 0 个资源，R2 上至今没有它的对象，
  第一次 apply 才会建。⚠️ 它的 plan 是 `1 to add`（SMTP provider），见 [zitadel/terraform/README.md](../../zitadel/terraform/README.md)。
- **Terraform 1.17 平时不打印 `Acquiring state lock`**，所以 plan 日志里没有这句不代表没加锁。
  正向判据：手动放一个 `<key>.tflock` 对象，plan 应报 `Error acquiring the state lock` 并列出锁的 `ID` / `Who`；
  删掉对象后恢复。真遇到崩溃残留的锁用 `cd <root> && just tf force-unlock <ID>`。
- **aws CLI 直接打 R2** 要设 `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` 和
  `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required`；terraform 那边由 backend 块里的 `skip_s3_checksum` 处理。

## 回滚到本地 state

```bash
# 1. 在该 root 的 provider.tf 里注释掉 backend "s3" 块
cd <root> && just tf init -migrate-state   # 交互确认，把 R2 那份拷回本地 terraform.tfstate
cd <root> && just plan                     # 应与迁移前一致
```

R2 对象删不删都不影响真实资源；先回滚、确认 plan 正常，再决定要不要删桶里那份。
