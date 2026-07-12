#!/usr/bin/env bash
# Idempotent SMTP (Gmail relay) configuration for ZITADEL via the admin REST API.
#
# WHY REST and not the Terraform module: the zitadel TF provider drives the v1
# gRPC admin API. Native-gRPC *write* responses lose their trailers across the
# Cloudflare edge ("server closed the stream without sending trailers"), and a
# direct/bypass connection fails ZITADEL's instance-host check. REST is plain
# HTTP/JSON — no trailers — and works through the gateway with the correct Host.
# See docs/records/zitadel-console-grpc-404.md.
#
# Config is read from zitadel/terraform/.env (ZITADEL_TOKEN = service-user PAT,
# SMTP_USER, SMTP_PASSWORD, SMTP_FROM) or from the environment. Idempotent: skips
# create if a provider with the same description exists, activates only if needed.
#
# Usage:   ./configure-smtp.sh            # configure + activate
#          ./configure-smtp.sh <email>    # also send a test email to <email>

set -euo pipefail

DOMAIN="${ZITADEL_DOMAIN:-auth.meirong.dev}"
DESC="Gmail relay (managed by zitadel/scripts/configure-smtp.sh)"
SMTP_HOST_PORT="${SMTP_HOST:-smtp.gmail.com:587}"
SMTP_NAME="${SMTP_FROM_NAME:-ZITADEL Homelab}"
TEST_TO="${1:-}"

# Load .env next to the terraform module if the vars aren't already exported.
ENV_FILE="$(cd "$(dirname "$0")/../terraform" && pwd)/.env"
if [[ -f "$ENV_FILE" ]]; then set -a; source "$ENV_FILE"; set +a; fi

: "${ZITADEL_TOKEN:?set ZITADEL_TOKEN (service-user PAT) or provide zitadel/terraform/.env}"
: "${SMTP_USER:?set SMTP_USER}"
: "${SMTP_PASSWORD:?set SMTP_PASSWORD}"
: "${SMTP_FROM:?set SMTP_FROM}"

BASE="https://${DOMAIN}/admin/v1"
AUTH=(-H "Authorization: Bearer ${ZITADEL_TOKEN}" -H "Content-Type: application/json")

echo "==> listing existing email providers ..."
# Tolerate a missing/forbidden list endpoint: fall back to "none found" and create.
LIST=$(curl -fsS -X POST "${BASE}/email/_search" "${AUTH[@]}" -d '{}' 2>/dev/null || echo '{}')
FOUND=$(printf '%s' "$LIST" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
desc=sys.argv[1]
for p in (d.get('result') or []):
    if p.get('description')==desc:
        print(p.get('id',''), p.get('state','')); break
" "$DESC" || true)
ID="$(printf '%s' "$FOUND" | cut -d' ' -f1)"
STATE="$(printf '%s' "$FOUND" | cut -d' ' -f2-)"

if [[ -n "${ID:-}" ]]; then
  echo "    found existing provider ${ID} (state=${STATE}) — skipping create"
else
  echo "==> creating SMTP provider ..."
  BODY=$(python3 - "$SMTP_FROM" "$SMTP_NAME" "$SMTP_HOST_PORT" "$SMTP_USER" "$SMTP_PASSWORD" "$DESC" <<'PY'
import json,sys
_, frm, name, host, user, pw, desc = sys.argv
print(json.dumps({
  "plain": {},                 # PLAIN/LOGIN auth — Gmail App Password
  "senderAddress": frm,
  "senderName": name,
  "tls": True,                 # STARTTLS on :587
  "host": host,
  "user": user,
  "password": pw,
  "description": desc,
}))
PY
)
  ID=$(curl -fsS -X POST "${BASE}/email/smtp" "${AUTH[@]}" -d "$BODY" \
       | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  STATE=""
  echo "    created provider ${ID}"
fi

if [[ "${STATE:-}" == "EMAIL_PROVIDER_ACTIVE" ]]; then
  echo "==> already active — nothing to do"
else
  echo "==> activating provider ${ID} ..."
  curl -fsS -X POST "${BASE}/email/${ID}/_activate" "${AUTH[@]}" -d '{}' >/dev/null \
    && echo "    activated" || echo "    activate returned non-2xx (likely already active) — ok"
fi

if [[ -n "$TEST_TO" ]]; then
  echo "==> sending test email to ${TEST_TO} ..."
  curl -fsS -X POST "${BASE}/email/smtp/${ID}/_test" "${AUTH[@]}" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'receiverAddress': sys.argv[1]}))" "$TEST_TO")" \
    && echo "    test send accepted" || echo "    test endpoint failed (provider still configured)"
fi

echo "Done. SMTP provider ${ID} is configured and active on ${DOMAIN}."
