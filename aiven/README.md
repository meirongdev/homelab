# Aiven (free tier)

One Terraform root: `aiven/terraform/`. It manages **one free-tier PostgreSQL
service inside an Aiven project that already exists** (`meirongdev-homelab`,
created in the console and read via `data.aiven_project`). It does not create,
rename, or delete that project — see "Why the project is read, not declared".

> ☠️ **This is additive and stays that way.** It is *not* the shared application
> Postgres. That is `databases/apps-pg` in each cluster — litellm, multica,
> nakama and blogstats live there, and it is what
> [shared-postgres-platform.md](../docs/decisions/shared-postgres-platform.md)
> is about. This root never references, replaces, or migrates it, and no ArgoCD
> Application points at it. If a future change starts moving workloads here, that
> decision belongs in a new ADR, not in a `.tf` edit.

## Current state (2026-09-17)

**Initialized and imported; not applied.** The root has never run `apply`, so
Terraform has changed nothing at Aiven — but the database **does exist**, because
the console created it first and `terraform import` adopted it.

| | measured value |
|---|---|
| Service | `pg-3cb9cb09`, PostgreSQL 18, cloud `do-ams` (Aiven picked it; free tier has no region choice) |
| State | ☠️ **`POWEROFF`** as of 2026-09-17 evening — it was `RUNNING` earlier the same day. This is the free tier's idle shutdown, not a fault, and **Terraform cannot power it back on**: that is the Console or `aiven service poweron`. Everything below that says "reachable" was measured while it was up. |
| Plan | `free-1-1gb` |
| `termination_protection` | **false in the cloud** — the service is deletable right now; config wants `true` |
| `ip_filter` | **`0.0.0.0/0` and `::/0`** — reachable from the entire internet, set by the console quick-create. Still true; the config now plans to remove both (see below), but nothing has been applied. |
| Default database | `defaultdb`, owner `avnadmin` (read off the service URI, not off the service name) |
| Local state | exists, from `import`; `*.tfstate*` is gitignored |
| Pending diff | `0 to add, 1 to change, 0 to destroy`, all on that one resource: `termination_protection false→true`, `service_log false→true`, `ip_filter` **losing `0.0.0.0/0` and `::/0`**, `+ public_access { pg = true }`, and a `+ timeouts` block. `public_access` asserts the endpoint the service already exposes; it does not open a new one. `timeouts` is config-only and changes nothing at Aiven. |

⚠️ **The first apply closes the database to everyone, including this laptop.**
`pg_ip_filter` defaults to `[]`, and since the root drives the `ip_filter`
attribute that is a real deny rather than a no-op. Put the callers' egress
addresses in `terraform.tfvars` **before** applying if you need to keep reaching
it — and re-read the service from the API afterwards, because on the shape this
root originally shipped a clean-looking plan is exactly what hid the problem.

Nothing is backed up, and that is not going to change quietly: see "What is NOT
backed up" below.

## Why Terraform for something free

The Console would do it in four clicks, and Terraform then earns its keep the way
it does everywhere else in this repo: `ip_filter` edits become reviewable,
`terraform state list` is the inventory, and a rebuild is `just aiven apply`.

What Terraform does **not** buy: the account, the API key, or the project. All
three are made in the console first, and the project's **name can never be
changed** after that — see Bootstrap.

## Which account, and which token

**Token file: `aiven/terraform/.env`** (`AIVEN_API_TOKEN=...`, mode 0600,
gitignored by the `.env` rule). Both `just aiven plan` from the repo root and
`just plan` from this directory pick it up — `mod` runs the recipe with this
directory as cwd, and `set dotenv-load` reads the `.env` next to the justfile.
Placed 2026-09-17; it is a **personal-account** key.

☠️ **`~/.config/aiven/` on this machine is the COMPANY account, not this one.**
The `aiven` CLI reads that directory by default, so a bare `aiven service ...`
here would talk to company infrastructure, not to these free-tier resources.
That is not a cosmetic mistake either — the CLI is not installed on this machine
as of 2026-09-17, so the first person to install it gets the company creds
silently. Either pass the token explicitly or set `AIVEN_PROJECT`, and prefer
`terraform output` / the Console for reading state.

⚠️ Like every other terraform root here, the justfile passes the key on the
child command line (`-var="aiven_api_token=..."`), so it is briefly readable from
the process table by anything running as this user. Consistent with
`cloudflare/terraform` and friends rather than worse; noted because it is a real
exposure and not a secret-in-git one.

Verify a token is live without creating anything (read-only):

```bash
cd aiven/terraform
curl -sS -H "Authorization: Bearer $(sed -n 's/^AIVEN_API_TOKEN=//p' .env)" \
     https://api.aiven.io/v1/me
```

⚠️ Note the `sed`: `awk -F=` **drops the trailing `=`** of the base64 token and
you get a confusing `401 Invalid token` for a perfectly good key. That happened
on 2026-09-17 while wiring this up.

## Bootstrap (manual, once)

1. **Sign up at <https://aiven.io>.** The free tier is advertised as not needing a
   card, but the account in use as of 2026-09-17 reports `payment_method: card`
   with `card_info: null` and balance `0.00`, so "card on file" is **not**
   evidence of a billable account and the earlier claim in this file that a
   card-less organization is *required* was wrong. Do not read billing fields as
   a proxy for plan eligibility — check the plan itself (step 4).
2. Create an API key: Console → Security → API keys, scoped as narrowly as the
   console allows (Project scope where offered, otherwise Organization).
3. Point `aiven_project_name` (default `meirongdev-homelab`) at the project that
   already exists on the account. **Nothing to pre-create and nothing to
   `terraform import`** — the project is a `data` source, so it never enters
   state and there is no adoption step.

   `just plan` proves the wiring before anything is written, because it reads the
   project over the API. Expected shape with no local state: `1 to add, 0 to
   change, 0 to destroy` — the `1` is the PostgreSQL service. Measured that way
   on 2026-09-17, before the import in step 4; **after** it the same command
   reports `0 to add, 1 to change, 0 to destroy`. Neither shape ever contains a
   `destroy`, and a wrong project name aborts with
   `Error: project <name> not found` instead of planning one.

4. The service itself already existed here (console quick-create, 2026-09-16), so
   it is **imported, not created**:

   ```bash
   cd aiven/terraform
   terraform import 'aiven_pg.this' meirongdev-homelab/pg-3cb9cb09
   ```

   Do the import instead of applying if state is ever lost. Applying with no
   state plans `1 to add` and would create a **second** service — which the free
   allowance may refuse, or may not, and either outcome is worse than importing.
   Undo a wrong import with `terraform state rm 'aiven_pg.this'`; that detaches
   from state without touching the service.

## Day 2

The token is already in `aiven/terraform/.env`, so nothing needs exporting —
`set dotenv-load` supplies it, including when you go through the root justfile.

```bash
just aiven plan                       # from the repo root
# or, equivalently:
cd aiven/terraform && just plan && just apply
```

| Recipe | Notes |
|--------|-------|
| `just aiven init` | from repo root: `just aiven init` (the root justfile `mod`s this one) |
| `just aiven plan` | read-only; safe, and always the first step after touching a name |
| `just aiven apply` | **interactive** — deliberately not `-auto-approve` |
| `just aiven destroy` | needs `pg_termination_protection = false` applied first |
| `just aiven conn-uri` | prints the admin URI — into Vault, never into a manifest |
| `just aiven endpoints` | host / port / state, nothing sensitive |

⚠️ `apply` prompts, unlike the other terraform roots here. That is a deliberate
break with convention: `pg_service_name` is immutable and owned by this root, so
renaming it is a **destroy-and-create whose payload is the only copy of the
data** — nothing backs this database up. Auto-approve would hide the one line
that says `destroy`. It also catches a typo'd `plan` name turning a free service
into a billed one, which `plan` itself will not catch.

## Adding a consumer

1. Add the name to `pg_databases` and `pg_users` in `terraform.tfvars`, then
   `just aiven apply`.

   ☠️ **Taking a name back out is a destroy, not a detach.** `for_each` drops the
   instance and apply drops the real database with whatever is in it — this file
   used to claim the opposite ("state only forgets names"), and acting on that
   would have cost a database. `tenants.tf` therefore carries `prevent_destroy`,
   so the mistake fails the plan instead of running; retiring a database on
   purpose means commenting that out in the same commit that removes the name.
   To stop managing a database while keeping it, use
   `terraform state rm 'aiven_pg_database.this["<name>"]'`.
2. `aiven_pg_user` generates its password. ⚠️ **That password is in
   `terraform.tfstate` in plaintext** — `sensitive` keeps it out of command
   output, not out of the file — so read it with `terraform output` or from the
   Console, whichever is handier, and treat the state file itself as a secret at
   rest either way. Store it under `secret/oracle-k3s/<service>` or
   `secret/homelab/<service>` — the same paths every other service uses
   (`docs/reference/identity.md`).
3. Consume it through an `ExternalSecret`. **Do not** interpolate
   `terraform output` into a manifest: this repository is public.
4. **Decide the backup story before writing any data.** Nothing here is backed
   up. See the next section — this is the free tier's real cost.

## What is NOT backed up

☠️ The restic CronJobs run `pg_dump` against the **in-cluster** instances, and
CI rule H4 only looks at PVCs in manifests. A database that lives at Aiven
behind no PVC is therefore invisible to both, and an app that moves here stops
being backed up **with no signal at all** — git clean, ArgoCD Synced, pod
Running. That is the exact failure shape this repo keeps writing records about.

So: treat this database as **disposable**. If it becomes worth backing up, either
add a dump job and register it in `docs/reference/storage.md`, or move the
workload to `apps-pg`, which already has that machinery.

## Who may connect

The public endpoint is on by default because there is no other way in — no
peered VPC, and PrivateLink is paid.

☠️ **The service as it stands is open to the whole internet** (`0.0.0.0/0` and
`::/0`, from the console quick-create) and stays that way until someone applies.
Since 2026-09-17 the config can actually close it: an empty `pg_ip_filter` plans
`- "0.0.0.0/0"` / `- "::/0"`, where before it planned nothing at all. "Empty
means deny" is now proven at plan time and still unproven at apply time —
re-read the service from the API once you have applied.

Add each caller's **egress** address, which is not the address you might expect:

| Caller | Egress address |
|--------|----------------|
| homelab control plane `k8s-node` | behind pve NAT on `10.10.10.0/24` — the laptop's ISP address, **changes** |
| `k8s-worker-106` | the LAN's NAT address at 106 |
| oracle-k3s `10.0.0.26` | OCI public IP; read it with `cd cloud/oracle/terraform && terraform output -raw instance_public_ip` |

⚠️ Do not commit any of those into a tracked file —
`scripts/check-public-ips.py` blocks public IPs repo-wide, and it is right to.
They belong in `terraform.tfvars` (gitignored). If a caller's address churns
more than it changes, that is the signal this database is the wrong home for it.

## Measured: reachability and latency (2026-09-17)

Connected once, read-only (`SELECT` / `pg_sleep` only — no DDL, no DML), from this
laptop and from both clusters, **while the service was `RUNNING`**. It has since
gone `POWEROFF` (see Current state), so none of this is reproducible until it is
powered on again from the Console — the numbers stand, the reachability claim
does not.

| Path | measured |
|---|---|
| TCP connect, this machine (SG) → `do-ams` | 176 ms |
| `SELECT 1` round trip on a held connection | median 175.7 ms, p90 182 ms (n=40) |
| cold connect: TCP + TLS + SCRAM + startup | 1.27-1.30 s (≈7 往返) |
| homelab control plane → same port | 190-243 ms |
| oracle-k3s (`ap-osaka-1`) → same port | 243-257 ms |

☠️ **All of it is the network, not Postgres.** `pg_sleep(0.5)` returned in 681 ms =
500 + one round trip, so server-side time is noise at this distance. The number that
decides whether an app works here is **round trips per request**: 20 sequential
`SELECT 1` took 3.54 s, while the same 20 results in one query took 177 ms. The free
plan has no PgBouncer, so there is no pooling layer to hide that, and a cold
connection costs more than most single requests would.

Also measured: `max_connections = 20` on this plan; a 156 KB result set took 727 ms
(~215 KB/s) — single-stream throughput is RTT-limited, not Aiven-limited.

☠️ **TLS verification fails as shipped.** The chain is issued by a per-project
self-signed CA (`CN=<uuid> Project CA`), not a public CA: openssl returns `verify
error:num=19:self-signed certificate in certificate chain`, and Python's `ssl` with
the system store refuses the handshake outright (this test had to disable verification
to connect at all). Any consumer must either set `ca_model = "letsencrypt"` on
`aiven_pg` — **untested on the free plan, and it is an apply** — or carry the project
CA as `sslrootcert` / `sslmode=verify-ca`. Handshake negotiated TLSv1.2.

Reproduction: `pg8000` in a throwaway venv; host and port come from `just aiven
endpoints`, password from local state. There is no `psql` on this machine.

## Why the project is read, not declared

Deliberate, and the reason is a specific failure mode rather than tidiness.

`aiven_project.project` is **immutable**, so Terraform resolves any change to it
the only way it can: destroy and recreate. As long as this root *owned* the
project, a mistyped `aiven_project_name` was a plan containing
`destroy aiven_project.this` — taking the project and every service in it, with
nothing backing any of it up. The project also pre-dates this root and was made
by hand, so owning it bought nothing except that risk.

As a `data` source it can only be read. The same typo now aborts the plan with
`project ... not found`, which was verified rather than assumed.

⚠️ The price, stated plainly: **project-level settings are owned by the console**
— `technical_emails`, `billing_group`, tags. Terraform will never report them
drifting, because it never intends to converge them. Same trade-off shape as
`docs/decisions/` notes elsewhere: fewer ways to lose things, in exchange for one
more thing that is not in Git.

## Limits that will bite

From <https://aiven.io/pricing> and <https://aiven.io/free-tier>, as of 2026-09:

- **1 CPU / 1 GB RAM / 1 GB storage.** The storage number is the one to
  watch: Postgres WAL plus a modest schema reaches 1 GB, and on the free plan
  you cannot extend it.
- **No cloud or region selection.** That is why `main.tf` has no `cloud_name`
  (`do-ams` here, chosen by Aiven, and omitting the attribute produced no diff on
  the imported service — verified rather than assumed).
- **No connection pooling (PgBouncer) and no integrations** on the free plan.
  `pgbouncer` blocks in `pg_user_config` will not help.
- **No SLA, and idle services may be shut down.** Check `pg_state`
  (`just aiven endpoints`) if it seems gone; a `POWEROFF` service cannot be
  powered on by Terraform — Console or `aiven service poweron`.

## State

Local `terraform.tfstate` in this directory, like the other seven roots. The
move to an R2 backend is **one decision for all of them**
([docs/ROADMAP.md](../docs/ROADMAP.md), 开放项 #2,
[plan](../docs/plans/2026-08-03-tf-state-r2.md)); do not migrate this root on its
own — "one remote, seven local" is a new drift, not less drift.

Until then, be aware state holds the admin password, every `aiven_pg_user`
password this root creates, and the CA, all in plaintext (`sensitive` hides a
value from output, not from the file). `*.tfstate*` is gitignored.

## Plan names: the one edit that starts a bill

`plan = "free-1-1gb"` is the free tier. This file previously asserted
`hobbyist`, **which was wrong and would have cost money**: on Aiven's own
pricing table the $0 tier is "Free" and Hobbyist is a separate paid tier
("starting from $12 / month"). `startup-4`, the name in most provider examples,
is paid too. Neither the provider docs nor its examples name the free plan,
because the free plan names are account-specific — `free-1-1gb` was read off the
running service via `GET /v1/project/<p>/service/<svc>`.

So the rule is: **read the plan name off the account, never from a doc.** Two
wrong names both fail silently in the same direction — `plan` is not validated
during `plan`, so the diff looks clean either way and the money or the rejection
only appears at apply. There is no automation for this; the check is a human
reading the diff.
