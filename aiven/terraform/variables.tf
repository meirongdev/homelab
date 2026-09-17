# Aiven API key. Export it, or keep it in a `.env` next to this file (the
# justfile sets `dotenv-load`). Do not put it in terraform.tfvars: that file is
# gitignored, but it is still a plaintext file full of secrets on disk.
variable "aiven_api_token" {
  description = "Aiven project-scoped API key"
  type        = string
  sensitive   = true
}

# The existing console project this root reads (created 2026-09 before this
# root existed; reused because free-plan allowances are account-level). It is a
# data source, so a wrong value here fails the plan with not-found — it cannot
# create, rename, or delete a project. Still not a free-form knob: point it at a
# real project you intend to spend quota on.
variable "aiven_project_name" {
  description = "Existing Aiven project to host the service"
  type        = string
  default     = "meirongdev-homelab"
}

# The name the console gave this service when it was quick-created
# (`pg-3cb9cb09`, 2026-09-16). Ugly, and unfixable: `service_name` is immutable,
# so "renaming" it means destroying the service and its only copy of the data.
# Adopted as-is; do not prettify.
variable "pg_service_name" {
  description = "PostgreSQL service name (console-generated; immutable)"
  type        = string
  default     = "pg-3cb9cb09"
}

# Aiven does not let you choose a cloud or region on the free plan ("Cannot
# select a specific cloud or region" — aiven.io/pricing); it assigned this
# service to `do-ams`. So this root has NO cloud_name variable on purpose: passing one is a plan-time error
# rather than a silent relocation of the database.
#
# CIDRs allowed to connect. Empty now really does mean closed — but only since
# main.tf started driving the deprecated `ip_filter` attribute instead of
# `ip_filter_string`. ☠️ With `ip_filter_string`, which is what this root shipped,
# an empty list here matched an empty field in state while the live filter stayed
# 0.0.0.0/0 + ::/0 from the console quick-create: `plan` reported no change and
# nothing was ever closed. The reasoning is in main.tf next to the attribute.
#
# ⚠️ So the default below is no longer inert: applying it plans
# `- "0.0.0.0/0"` / `- "::/0"` and locks everyone out, this laptop included. Fill
# it in before you apply if you need to keep reaching the database, and verify
# the result by re-reading the service from the API after apply — never by "plan
# showed what I expected", which is the evidence that failed here.
#
# When you do set it, use each caller's EGRESS address — for our clusters that is
# a NAT address that can change, so this is a file you re-apply, not a one-time
# setting. See README, "Who may connect".
variable "pg_ip_filter" {
  description = "CIDRs allowed to reach the PostgreSQL port"
  type        = list(string)
  default     = []
}

# Whether the internet-facing PG endpoint is enabled. Defaults to true because
# there is no other path in here: no peered VPC, and PrivateLink is a paid
# feature. False + empty ip_filter = a database nothing can reach, useful only as
# a pause rather than a security posture.
variable "pg_public_access" {
  description = "Enable the public PostgreSQL endpoint"
  type        = bool
  default     = true
}

# Free tier has no SLA and Aiven may shut an idle service down — their risk, not
# something this flag can prevent. What it does prevent is US deleting it: a
# `just aiven destroy` from a stale shell. Flip to false only when tearing this
# down on purpose; Terraform has to apply that change before destroy works.
variable "pg_termination_protection" {
  description = "Prevent deletion of the PostgreSQL service"
  type        = bool
  default     = true
}

# Extra databases, one per consumer. Names are the tenant keys, so keep them
# short and stable — renaming means drop and recreate.
#
# ☠️ Removing a name is a DESTROY, not a detach: for_each drops the instance and
# apply drops the real database. tenants.tf carries `prevent_destroy` so that
# fails the plan instead of running; `terraform state rm` is the way to stop
# managing a database you want to keep.
variable "pg_databases" {
  description = "Database names to create beyond the service default"
  type        = list(string)
  default     = []
}

# Service users, created with Aiven-generated passwords.
#
# ☠️ Those passwords ARE stored by this root, in plaintext, in terraform.tfstate:
# the provider marks `aiven_pg_user.password` Computed + Sensitive, and
# `sensitive` hides a value from output, not from the state file. An earlier
# version of this comment claimed the opposite. Treat state as a secret at rest
# (same as the PVE password in proxmox/terraform — docs/ROADMAP.md 开放项 #2).
#
# Read a password once (Console, or `terraform output`/`terraform show`) and put
# it in Vault like every other secret here. The provider does offer `password_wo`
# (write-only, never persisted), but it takes a password you supply — it removes
# the state copy only by making this root the place the password is authored,
# which is a second source of truth against Vault. Not adopted; noted so the next
# person does not have to re-derive the trade-off.
variable "pg_users" {
  description = "Service user names to create (password generated by Aiven)"
  type        = list(string)
  default     = []
}
