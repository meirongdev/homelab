variable "zitadel_domain" {
  description = "ZITADEL external domain"
  type        = string
  default     = "auth.meirong.dev"
}

variable "zitadel_token" {
  description = "Personal Access Token of a service user with IAM_OWNER (manages the instance-level SMTP provider)"
  type        = string
  sensitive   = true
}

variable "smtp_host" {
  description = "SMTP host:port. Gmail relay uses STARTTLS on 587."
  type        = string
  default     = "smtp.gmail.com:587"
}

variable "smtp_user" {
  description = "SMTP username (the Gmail address)"
  type        = string
}

variable "smtp_password" {
  description = "SMTP password — Gmail App Password (16 chars, spaces stripped)"
  type        = string
  sensitive   = true
}

variable "smtp_from" {
  description = "Sender address. For the Gmail relay this MUST be the Gmail address (Gmail rewrites any other From)."
  type        = string
}

variable "smtp_from_name" {
  description = "Sender display name"
  type        = string
  default     = "ZITADEL Homelab"
}

variable "smtp_reply_to" {
  description = "Reply-To address (optional, blank to omit)"
  type        = string
  default     = ""
}
