# Instance-level SMTP email provider. Replaces the deprecated zitadel_smtp_config.
# set_active = true makes ZITADEL send through this provider immediately, which is
# what clears the "Errors.SMTPConfig.NotFound" error on the running instance.
resource "zitadel_email_provider_smtp" "default" {
  host           = var.smtp_host
  user           = var.smtp_user
  password       = var.smtp_password
  sender_address = var.smtp_from
  sender_name    = var.smtp_from_name
  tls            = true # Gmail 587 requires STARTTLS
  set_active     = true
  description    = "Gmail relay (managed by Terraform)"

  reply_to_address = var.smtp_reply_to
}
