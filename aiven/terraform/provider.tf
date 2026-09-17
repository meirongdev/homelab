terraform {
  required_providers {
    aiven = {
      source  = "aiven/aiven"
      version = "~> 4.62"
    }
  }

  # Backend intentionally omitted = local state, same as every other root here.
  # Moving state to R2 is ONE decision for ALL roots (docs/ROADMAP.md, 开放项 #2,
  # plan docs/plans/2026-08-03-tf-state-r2.md). Do not migrate this root alone:
  # "one remote, seven local" is the kind of silent split this repo keeps
  # having to clean up.
}

# Auth is an Aiven API key. Scope it as narrowly as the console allows (Project,
# otherwise Organization) -- a broader key is more power than this root needs.
#
# ☠️ Plan eligibility is NOT something a billing field can predict, so do not
#    "verify" it by looking for a card on file: the account in use here reports
#    payment_method=card with card_info=null and costs nothing. The free plan is
#    confirmed by the Console's plan picker, not by billing metadata. README.
provider "aiven" {
  api_token = var.aiven_api_token
}
