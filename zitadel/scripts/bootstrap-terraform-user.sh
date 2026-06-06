#!/usr/bin/env bash
# One-time bootstrap: create the `terraform-smtp` ZITADEL service user, grant it
# IAM_OWNER (instance manager), and generate a Personal Access Token (PAT) that
# zitadel/terraform uses as ZITADEL_TOKEN.
#
# WHY a script and not the Console: nothing here is unauthenticated — it still
# needs an existing admin token. You supply that ONCE, via env var, copied from
# your logged-in Console session. The token stays on your machine.
#
# How to get ZITADEL_ADMIN_TOKEN:
#   1. Log into https://auth.meirong.dev as an IAM_OWNER (e.g. zitadel-admin).
#   2. Open browser DevTools → Network → click any API request (e.g. *.GetMyUser).
#   3. Copy the value of the `authorization` request header AFTER "Bearer ".
#
# Usage:
#   export ZITADEL_ADMIN_TOKEN='paste-the-bearer-token'
#   ./bootstrap-terraform-user.sh
#
# Optional overrides:
#   ZITADEL_DOMAIN (default auth.meirong.dev)
#   ORG_ID         (default 363176129403617312 — the instance's default org)
#   PAT_EXPIRY     (RFC3339, e.g. 2027-06-06T00:00:00Z; omit = never expires)
#   SA_USERNAME    (default terraform-smtp)

set -euo pipefail

DOMAIN="${ZITADEL_DOMAIN:-auth.meirong.dev}"
ORG_ID="${ORG_ID:-363176129403617312}"
SA_USERNAME="${SA_USERNAME:-terraform-smtp}"
BASE="https://${DOMAIN}"

if [[ -z "${ZITADEL_ADMIN_TOKEN:-}" ]]; then
  echo "ERROR: set ZITADEL_ADMIN_TOKEN to a bearer token of an IAM_OWNER user." >&2
  echo "       (Console → DevTools → Network → copy the Authorization header.)" >&2
  exit 1
fi

AUTH=(-H "Authorization: Bearer ${ZITADEL_ADMIN_TOKEN}"
      -H "Content-Type: application/json"
      -H "x-zitadel-orgid: ${ORG_ID}")

# Fail loudly if a response is not JSON (e.g. a Cloudflare WAF challenge page).
json_or_die() {
  local body="$1" ctx="$2"
  if ! printf '%s' "$body" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    echo "ERROR during '${ctx}': response was not JSON. Raw response:" >&2
    printf '%s\n' "$body" | head -20 >&2
    exit 1
  fi
}

echo "==> 1/3 Creating machine user '${SA_USERNAME}' in org ${ORG_ID} ..."
CREATE=$(curl -sS "${AUTH[@]}" -X POST "${BASE}/management/v1/users/machine" \
  -d "$(python3 - "$SA_USERNAME" <<'PY'
import json,sys
u=sys.argv[1]
print(json.dumps({
  "userName": u,
  "name": "Terraform SMTP",
  "description": "Service user for zitadel/terraform (manages instance SMTP)",
  "accessTokenType": "ACCESS_TOKEN_TYPE_BEARER",
}))
PY
)") || true
json_or_die "$CREATE" "create machine user"

USER_ID=$(printf '%s' "$CREATE" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("userId",""))')

if [[ -z "$USER_ID" ]]; then
  # Likely already exists — look it up by username.
  echo "    (create returned no userId — searching for existing '${SA_USERNAME}')"
  SEARCH=$(curl -sS "${AUTH[@]}" -X POST "${BASE}/management/v1/users/_search" \
    -d "$(python3 - "$SA_USERNAME" <<'PY'
import json,sys
print(json.dumps({"queries":[{"userNameQuery":{"userName":sys.argv[1],"method":"TEXT_QUERY_METHOD_EQUALS"}}]}))
PY
)")
  json_or_die "$SEARCH" "search user"
  USER_ID=$(printf '%s' "$SEARCH" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("result") or []; print(r[0]["id"] if r else "")')
fi

[[ -n "$USER_ID" ]] || { echo "ERROR: could not determine service user id. Response was:" >&2; echo "$CREATE" >&2; exit 1; }
echo "    userId = ${USER_ID}"

echo "==> 2/3 Granting IAM_OWNER (instance manager) ..."
MEMBER=$(curl -sS "${AUTH[@]}" -X POST "${BASE}/admin/v1/members" \
  -d "$(python3 - "$USER_ID" <<'PY'
import json,sys
print(json.dumps({"userId":sys.argv[1],"roles":["IAM_OWNER"]}))
PY
)")
# Already-a-member is fine; only die on non-JSON (e.g. WAF/HTML).
json_or_die "$MEMBER" "grant IAM_OWNER"
if printf '%s' "$MEMBER" | grep -qi 'alreadyexist\|already a member\|AlreadyExists'; then
  echo "    (already a member — ok)"
else
  echo "    granted"
fi

echo "==> 3/3 Creating Personal Access Token ..."
PAT_BODY='{}'
if [[ -n "${PAT_EXPIRY:-}" ]]; then
  PAT_BODY=$(python3 - "$PAT_EXPIRY" <<'PY'
import json,sys
print(json.dumps({"expirationDate":sys.argv[1]}))
PY
)
fi
PAT=$(curl -sS "${AUTH[@]}" -X POST "${BASE}/management/v1/users/${USER_ID}/pats" -d "$PAT_BODY")
json_or_die "$PAT" "create PAT"
TOKEN=$(printf '%s' "$PAT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))')

[[ -n "$TOKEN" ]] || { echo "ERROR: no token in PAT response:" >&2; echo "$PAT" >&2; exit 1; }

echo
echo "============================================================"
echo "  PAT created. Shown ONCE — store it now."
echo "============================================================"
echo "ZITADEL_TOKEN=${TOKEN}"
echo
echo "Next:"
echo "  # store in Vault for the record"
echo "  vault kv patch secret/homelab/zitadel-terraform pat=\"${TOKEN}\""
echo "  # and put it in zitadel/terraform/.env  (ZITADEL_TOKEN=...)"
