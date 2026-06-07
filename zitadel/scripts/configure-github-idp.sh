#!/usr/bin/env bash
# Idempotent ZITADEL GitHub external IdP (social login) via the admin REST API.
#
# WHY REST and not the Terraform module: the zitadel TF provider drives the v1
# gRPC API. Native-gRPC *write* responses lose their trailers across the
# Cloudflare edge ("server closed the stream without sending trailers"), and a
# direct/bypass connection fails ZITADEL's instance-host check. REST is plain
# HTTP/JSON — no trailers — and works through the gateway. Same reason as
# configure-smtp.sh and configure-bifrost-oauth.sh. See
# docs/runbooks/zitadel-console-grpc-404.md.
#
# Federates GitHub into ZITADEL so every OIDC / oauth2-proxy app (Bifrost admin,
# etc.) gains a "Sign in with GitHub" button WITHOUT any app change — ZITADEL
# stays the single IdP / unified login. Creates (idempotently) an instance-level
# GitHub IdP and binds it to the instance login policy so the button shows.
#
# SECURITY — locked down by default: isCreationAllowed/isAutoCreation = false,
# isLinkingAllowed = true, autoLinking = EMAIL. Only a GitHub account whose
# verified primary email already matches an existing ZITADEL user can sign in;
# no stranger can self-provision. This matters because Bifrost's oauth2-proxy
# runs --email-domain=* (ANY authenticated email passes), so the real gate has
# to live here. To open self-registration instead, run with
# ALLOW_OPEN_SIGNUP=true and add per-app authorization (ZITADEL project roles +
# oauth2-proxy --allowed-groups). GitHub login is additive — username/password
# still works, so a not-yet-matching email just means the GitHub button fails
# gracefully, it does not lock you out of the instance.
#
# Needs ZITADEL_TOKEN = service-user PAT with IAM_OWNER (instance admin; an org
# role gives "membership not found"). GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET
# come from a GitHub OAuth App you register first
# (Settings → Developer settings → OAuth Apps → New) with callback URL:
#   https://auth.meirong.dev/idps/callback
# NOTE: this instance runs the Login V2 app (zitadel-login pod), whose IdP
# callback is /idps/callback — NOT the v1 /ui/login/login/externalidp/callback.
# Verified ground truth via POST /v2/idp_intents (the authUrl's redirect_uri).
#
# Config from zitadel/terraform/.env (same file the other scripts use) or env.
#
# Usage:   ./configure-github-idp.sh

set -euo pipefail

DOMAIN="${ZITADEL_DOMAIN:-auth.meirong.dev}"
IDP_NAME="${IDP_NAME:-GitHub}"

# Load .env next to the terraform module if the vars aren't already exported.
ENV_FILE="$(cd "$(dirname "$0")/../terraform" && pwd)/.env"
if [[ -f "$ENV_FILE" ]]; then set -a; source "$ENV_FILE"; set +a; fi

: "${ZITADEL_TOKEN:?set ZITADEL_TOKEN (service-user PAT, IAM_OWNER) or provide zitadel/terraform/.env}"
: "${GITHUB_CLIENT_ID:?set GITHUB_CLIENT_ID (from the GitHub OAuth App)}"
: "${GITHUB_CLIENT_SECRET:?set GITHUB_CLIENT_SECRET (from the GitHub OAuth App)}"

BASE="https://${DOMAIN}/admin/v1"
AUTH=(-H "Authorization: Bearer ${ZITADEL_TOKEN}" -H "Content-Type: application/json")

# Locked down unless ALLOW_OPEN_SIGNUP=true (see header).
if [[ "${ALLOW_OPEN_SIGNUP:-false}" == "true" ]]; then
  CREATION=true;  AUTO_CREATION=true
else
  CREATION=false; AUTO_CREATION=false
fi

# --- find existing IdP (idempotency) ----------------------------------------
echo "==> looking for existing IdP '${IDP_NAME}' ..."
IDPS=$(curl -fsS -X POST "${BASE}/idps/_search" "${AUTH[@]}" -d '{}')
IDP_ID=$(printf '%s' "$IDPS" | python3 -c "
import json,sys
d=json.load(sys.stdin); name=sys.argv[1]
for i in (d.get('result') or []):
    if i.get('name')==name: print(i.get('id','')); break
" "$IDP_NAME" || true)

if [[ -n "${IDP_ID:-}" ]]; then
  echo "    found existing IdP ${IDP_ID} — leaving its config untouched."
  echo "    (to change client id/secret or the lockdown flags, edit it in the"
  echo "     Console: Default Settings → Identity Providers → ${IDP_NAME})"
else
  echo "==> creating GitHub IdP '${IDP_NAME}' (creation=${CREATION}, autoCreation=${AUTO_CREATION}) ..."
  BODY=$(python3 - "$IDP_NAME" "$GITHUB_CLIENT_ID" "$GITHUB_CLIENT_SECRET" "$CREATION" "$AUTO_CREATION" <<'PY'
import json, sys
_, name, cid, secret, creation, auto = sys.argv
print(json.dumps({
  "name": name,
  "clientId": cid,
  "clientSecret": secret,
  "scopes": ["openid", "profile", "email"],
  "providerOptions": {
    "isLinkingAllowed": True,
    "isCreationAllowed": creation == "true",
    "isAutoCreation": auto == "true",
    "isAutoUpdate": True,
    "autoLinking": "AUTO_LINKING_OPTION_EMAIL",
  },
}))
PY
)
  IDP_ID=$(curl -fsS -X POST "${BASE}/idps/github" "${AUTH[@]}" -d "$BODY" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  echo "    created IdP ${IDP_ID}"
fi

# --- bind to the instance login policy (so the button shows) ----------------
echo "==> ensuring IdP is on the instance login policy ..."
LINK_BODY=$(python3 -c "import json,sys; print(json.dumps({'idpId': sys.argv[1], 'ownerType': 'IDP_OWNER_TYPE_SYSTEM'}))" "$IDP_ID")
HTTP=$(curl -sS -o /tmp/zitadel-idp-link.out -w '%{http_code}' \
  -X POST "${BASE}/policies/login/idps" "${AUTH[@]}" -d "$LINK_BODY")
if [[ "$HTTP" == "200" ]]; then
  echo "    linked."
elif grep -qiE 'already|exist' /tmp/zitadel-idp-link.out; then
  echo "    already linked — ok."
else
  echo "    !! login-policy link failed (HTTP $HTTP):" >&2
  cat /tmp/zitadel-idp-link.out >&2; echo >&2
  exit 1
fi

cat <<EOF

Done. GitHub IdP '${IDP_NAME}' (${IDP_ID}) is active on the login policy.

Verify: open https://${DOMAIN} in a private window — the login page should now
show "Sign in with GitHub". Bifrost admin (llm.meirong.dev) and every other
ZITADEL-OIDC app pick it up automatically; no app change needed.

Reminders:
  • GitHub OAuth App "Authorization callback URL" must be EXACTLY (Login V2):
      https://${DOMAIN}/idps/callback
  • Your GitHub account's PRIMARY email must be VERIFIED and equal to your
    existing ZITADEL user's email — autoLinking matches on email and
    self-registration is OFF by default, so a mismatch just means the GitHub
    button won't link (password login still works).
  • Record the creds in Vault for rotation (ZITADEL keeps its own copy):
      vault kv put secret/homelab/zitadel-github-idp \\
        client-id='${GITHUB_CLIENT_ID}' client-secret='<the-secret>'
EOF
