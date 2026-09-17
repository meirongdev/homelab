# Databases and users, one entry per consumer.
#
# ☠️ A free-tier database is NOT covered by any backup here. The restic CronJobs
#    run `pg_dump` against the in-cluster instances, and H4 only inspects PVCs in
#    manifests — a database that is not behind a PVC is invisible to it, so a
#    consumer that moves here silently stops being backed up. If something here
#    starts to matter, add it to the backup story in docs/reference/storage.md
#    FIRST.
#
# ⚠️ The service ships with its own database, `defaultdb`, owned by the admin user
#    `avnadmin` (read off the service URI's path, 2026-09-17 — it is named after
#    Aiven's default, NOT after the service). Do not also declare it: Aiven
#    rejects the duplicate. Same for the admin user — it belongs to the service,
#    and an `aiven_pg_user` for it detaches on the next refresh.
#
# Prefer one database + one user per consumer over sharing. The isolation is free
# in PostgreSQL terms and it keeps `pg_dump` per tenant trivial — but "on a 1 GB
# plan" is doing a lot of work in that sentence: every tenant shares the SAME
# 1 GB, so two chatty apps starve each other regardless of who owns which
# database. The plan is the real ceiling, not the database boundary.
#
# ☠️ Dropping a name from var.pg_databases DESTROYS that database. This file used
#    to claim the opposite ("for_each forgets a name, it does not drop it") and
#    that reading is backwards: removing a key from a for_each set removes the
#    resource instance, so `plan` reports `1 to destroy` and apply drops the real
#    database with whatever is in it. The `prevent_destroy` below is what makes
#    that mistake fail loudly instead of running.
#    To stop managing a database without dropping it, the tool is
#    `terraform state rm 'aiven_pg_database.this["<name>"]'`, not an edit here.

resource "aiven_pg_database" "this" {
  for_each = toset(var.pg_databases)

  project       = data.aiven_project.this.project
  service_name  = aiven_pg.this.service_name
  database_name = each.value

  # See the note above: this is the guard that turns "I tidied up the variable"
  # from a silent data loss into a failed plan.
  #
  # ⚠️ Terraform's own lifecycle flag, NOT the provider's `termination_protection`
  #    — that attribute exists on this resource but the provider deprecates it and
  #    points here instead (`terraform validate` says so out loud). The price is
  #    that `prevent_destroy` cannot be driven by a variable: retiring a database
  #    on purpose means commenting this line out in the same commit that removes
  #    the name, which is a reviewable edit rather than a silent one.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aiven_pg_user" "this" {
  for_each = toset(var.pg_users)

  project      = data.aiven_project.this.project
  service_name = aiven_pg.this.service_name
  username     = each.value
}
