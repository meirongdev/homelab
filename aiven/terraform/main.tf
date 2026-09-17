# Aiven free-tier PostgreSQL — a small, external database. Entirely additive.
#
# ☠️ This is NOT the shared app Postgres. That one lives in-cluster
#    (`databases/apps-pg` in both clusters; tenants litellm / multica / nakama /
#    blogstats; backed up by per-database pg_dump into restic) and this root does
#    not touch it. See docs/decisions/shared-postgres-platform.md. Nothing here
#    references, replaces, or migrates that instance.
#
# What this root IS for: a zero-cost managed PG for experiments, and for a future
# service that genuinely wants an external database. An app that consumes it must
# carry its own backup story — H4 only inspects PVCs in manifests, so a database
# that is not behind a PVC is invisible to it and will silently not be backed up.

# The project is READ, not declared. It predates this root (created in the
# console) and is reused deliberately — free-plan allowances are account-level, so
# a second project per root would just be litter.
#
# ☠️ This is the safer shape, not the tidier one. A data source cannot delete or
#    replace a project, so there is no path from a typo'd `aiven_project_name` to
#    "destroy aiven_project.this and everything inside it". With a managed
#    resource that path existed, because `project` is immutable and Terraform
#    resolves an immutable-attribute change by destroying the project. A wrong
#    name here fails the plan with a not-found read instead, which is the only
#    sane outcome for a name you did not create.
#
# ⚠️ Consequence: project settings (technical_emails, billing_group, tags) are
#    owned by the console, NOT by this root. `terraform plan` will never show
#    them drifting because it never intends to converge them. That is the trade
#    for not being able to delete the project.
data "aiven_project" "this" {
  project = var.aiven_project_name
}

resource "aiven_pg" "this" {
  project      = data.aiven_project.this.project
  service_name = var.pg_service_name

  # ☠️ The free plan is `free-1-1gb`. It is NOT `hobbyist`, and getting this
  #    wrong is a bill, not an error: on Aiven's own pricing table Hobbyist is a
  #    PAID tier ("starting from $12 / month") and the $0 tier is a separate one.
  #    Evidence for the exact string, rather than another guess — the service in
  #    this project reports plan=free-1-1gb (measured via GET
  #    /v1/project/<p>/service/<svc>, 2026-09-17). `startup-4`, which appears in
  #    most provider examples, is likewise paid.
  #
  #    Provider docs and this provider's own examples cannot be trusted for the
  #    free plan name: they show `startup-4` / `hobbyist` because those are the
  #    generic tiers. Read the plan off the account.
  #
  # ⚠️ Terraform does NOT validate the plan against the account during `plan` —
  #    it prints "will be created" for a plan that would bill or be refused.
  #    Eligibility and price only surface at apply, so keep apply interactive.
  plan = "free-1-1gb"

  # Intentionally absent, each for a reason:
  #   cloud_name  — free tier does not let you choose a region (see variables)
  #   disk_space  — fixed by the plan
  #   static_ips  — not available on the free plan
  #   node_count  — free tier is single-node; a replica would bill
  pg_user_config {
    service_log = true

    # ☠️ `ip_filter` is the DEPRECATED attribute and it is used on purpose — the
    #    provider's own deprecation notice points at `ip_filter_string`, and that
    #    field cannot control this service. Both names write the same API key, but
    #    the value Aiven actually enforces round-trips into `ip_filter`, so a
    #    config driving `ip_filter_string` produces a plan that never mentions the
    #    live filter at all. Measured 2026-09-17, same service, same plan run:
    #      ip_filter_string = ["192.0.2.9/32"]  ->  ~ ip_filter_string = [+ "192.0.2.9/32"]
    #                                               (ip_filter = ["0.0.0.0/0","::/0"] stays,
    #                                                hidden among unchanged attributes)
    #      ip_filter        = ["192.0.2.9/32"]  ->  ~ ip_filter = [- "0.0.0.0/0", - "::/0",
    #                                                             + "192.0.2.9/32"]
    #    The first shape is how this root shipped, and it is why the service is
    #    still open to the internet: the plan looked clean the whole time.
    #
    # ⚠️ Consequence of the switch: the default `[]` now MEANS something. It plans
    #    `- "0.0.0.0/0"` / `- "::/0"`, i.e. the first apply closes the service to
    #    everything, including this laptop. That is the right default for a
    #    database with no backup, but it is a change of behaviour, not a no-op —
    #    fill pg_ip_filter in terraform.tfvars before applying if you need access.
    #    Verify the result by re-reading the service from the API afterwards;
    #    "plan showed what I wanted" is exactly the evidence that failed here.
    ip_filter = var.pg_ip_filter

    # Public endpoint. A `project_vpc_id` here would need a peered cloud network
    # this setup does not have, and `privatelink_access` requires a paid plan.
    # The ip_filter above is therefore the only thing in front of this port.
    public_access {
      pg = var.pg_public_access
    }
  }

  # Unlike the project, this resource IS owned here, and its name is immutable —
  # so renaming pg_service_name really does mean destroy-and-create, with the
  # only copy of the data inside. Free tier carries no SLA and Aiven may shut an
  # idle service down (their call, unpreventable); what this flag prevents is the
  # deletion we can cause ourselves. Flip the variable to false to tear it down
  # on purpose, and apply that change first.
  termination_protection = var.pg_termination_protection

  timeouts {
    create = "20m"
    update = "20m"
  }
}

# Tenants (extra databases / users) live in tenants.tf.
