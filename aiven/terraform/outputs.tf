# What an app needs to connect. Everything sensitive is `sensitive`, which keeps
# it out of `terraform plan`'s human output — but note it is STILL stored in
# terraform.tfstate in plaintext, exactly like the PVE password in
# proxmox/terraform. That is the known gap behind docs/ROADMAP.md (开放项 #2).
#
# ☠️ Do not wire these straight into a Kubernetes manifest. Connection details
#    reach the clusters through Vault + ESO like every other secret here
#    (docs/reference/identity.md); a `value: ${terraform output ...}` in a
#    manifest would put a password in a public git repo.

# Full connection URI including the admin password. Printed only on explicit
# `terraform output -raw` (with -json, not -raw, it is masked). Prefer the
# pieces below for wiring anything.
output "pg_service_uri" {
  description = "PostgreSQL connection URI for the service admin user"
  value       = aiven_pg.this.service_uri
  sensitive   = true
}

output "pg_host" {
  description = "Public hostname of the PostgreSQL service"
  value       = aiven_pg.this.service_host
}

output "pg_port" {
  value = aiven_pg.this.service_port
}

output "pg_admin_username" {
  description = "Service admin user. For provisioning only — no app should connect as this."
  value       = aiven_pg.this.service_username
}

# The CA is per-project, not per-service, and clients need it: the chain is
# self-signed (`CN=<uuid> Project CA`), so a client using the system trust store
# fails the handshake outright — measured 2026-09-17, openssl verify error 19.
# Read from the project data source, so it is available even though this root
# does not own the project. The provider marks ca_cert sensitive, so it only
# leaves Terraform through `terraform output -raw project_ca_cert` — the
# certificate itself is public; marking is the provider's choice, not a claim
# that this is a secret.
output "project_ca_cert" {
  description = "PEM CA certificate to pass as sslrootcert (sslmode=verify-ca; verify-full untested here)"
  value       = data.aiven_project.this.ca_cert
  sensitive   = true
}

# `state` is what to check after a quiet period: POWEROFF means Aiven stopped an
# idle free-tier service (or someone powered it off). Terraform cannot power it
# back on — that is Console or `aiven CLI service poweron` — and a `plan` right
# after will look empty, so this output is the only place the fact surfaces.
output "pg_state" {
  description = "Service state; POWEROFF means the database is unreachable until powered on by hand"
  value       = aiven_pg.this.state
}

# Only the databases created by THIS root. The service also carries `defaultdb`,
# owned by the admin user `avnadmin`, and it is deliberately absent here.
output "pg_databases" {
  description = "Databases created by this root; the service's own `defaultdb` is not listed"
  value       = sort(keys(aiven_pg_database.this))
}

output "pg_users" {
  description = "Service users created by this root; the service admin user is not listed"
  value       = sort(keys(aiven_pg_user.this))
}

# ☠️ There is deliberately NO "databases that exist but are unmanaged" output
#    here, and re-adding one would be re-adding a lie. The version that used to
#    live in this file computed
#      setsubtract(toset(var.pg_databases), keys(aiven_pg_database.this))
#    which is identically empty: `for_each = toset(var.pg_databases)` makes those
#    two sets the same set, in every plan, forever. It reported "nothing
#    unmanaged" whether or not anything was, which is worse than no output.
#
#    It was also answering a question that does not arise: dropping a name from
#    var.pg_databases does not orphan a database, it DESTROYS it (see tenants.tf).
#    The guard for that is `prevent_destroy`, not a report.
