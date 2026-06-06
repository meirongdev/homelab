# ZITADEL Terraform

> ⚠️ **This module does not work against `auth.meirong.dev` for *writes*.** The
> provider uses native gRPC; its write responses lose their trailers across the
> Cloudflare edge (`server closed the stream without sending trailers`), and a
> direct/bypass connection fails ZITADEL's instance-host check. **SMTP is instead
> configured via REST** by `../scripts/configure-smtp.sh` (idempotent, plain
> HTTP/JSON — no trailers). This module is kept for reference / for the day the
> provider can reach ZITADEL over a trailers-clean path. The service user still
> needs **IAM_OWNER** either way (instance-level membership; an org role is not
> enough — you get `membership not found (AUTHZ-...)`).

Manages the **instance-level SMTP email provider** for the ZITADEL instance at
`auth.meirong.dev` declaratively, replacing the manual Console click-through.

This is what makes ZITADEL able to send notification / verification / password-reset
emails. Without it, the server logs `could not create email channel —
Errors.SMTPConfig.NotFound` whenever an email action runs.

> **Why Terraform and not `zitadel.yaml`?** The Helm chart's
> `DefaultInstance.SMTPConfiguration` only *seeds a brand-new instance* at first
> setup. Our instance already exists (created 2026-03-08), so a Helm value would
> never apply to it. SMTP on a running instance is runtime state in ZITADEL's DB,
> reachable only via Console / API / this Terraform.

## Email backend

Gmail relay (`smtp.gmail.com:587`, STARTTLS, `tls = true`) authenticated with a
Google **App Password**. Self-hosting SMTP from the homelab is intentionally
avoided (port 25 blocked, IP on blocklists, poor deliverability).

- Sender (`smtp_from`) **must** be the Gmail address — Gmail rewrites any other From.
- Requires 2FA on the Google account, then an App Password from
  <https://myaccount.google.com/apppasswords> (strip the spaces).
- Caveat: a Google **Workspace** account whose admin disabled App Passwords will
  not work — switch `smtp_*` vars to a transactional relay (Brevo / SES) in that case.

## One-time bootstrap (manual, in the Console)

Terraform authenticates as a ZITADEL **service user** holding an instance-manager
role. Create it once:

1. Console → **Users → Service Users → New**: e.g. `terraform-smtp`, access token
   type **Bearer**. Create.
2. Grant instance admin: Console → **Default Settings (instance) → Administrators
   → New** → pick `terraform-smtp` → role **IAM_OWNER**.
   (SMTP is an instance-level resource, so IAM_OWNER is required.)
3. On the service user → **Personal Access Tokens → New** → set an expiry → copy
   the token (shown once).
4. Store secrets in Vault for the record:
   ```bash
   vault kv put secret/homelab/zitadel-terraform \
     pat="<personal-access-token>" \
     smtp-user="youraddress@gmail.com" \
     smtp-from="youraddress@gmail.com" \
     smtp-password="<gmail-app-password>"
   ```

## Usage

Fill secrets either way (both gitignored):

- **env + justfile**: `cp .env.example .env` and edit, then use the targets, or
- **tfvars**: `cp terraform.tfvars.example terraform.tfvars` and edit, then plain `terraform`.

```bash
just init     # terraform init
just plan     # preview
just apply    # create/activate the SMTP provider on the live instance
```

After `apply`, verify in the Console (Instance → Notifications → SMTP shows the
provider active) or send yourself a test, and confirm the
`Errors.SMTPConfig.NotFound` error stops appearing in the `zitadel` pod logs.

## Notes

- **Not** under ArgoCD — like the Cloudflare and Tailscale modules, this is a
  non-K8s resource applied manually with `just`.
- State is local (`terraform.tfstate`, gitignored). The only managed resource is
  `zitadel_email_provider_smtp.default`.
- Rotating the App Password or PAT: update Vault + `.env`/tfvars, re-run `just apply`.
