#!/usr/bin/env bash
# Generic, idempotent ZITADEL OIDC client provisioner, via the management REST API.
#
# WHY REST and not the Terraform module: the zitadel TF provider drives the v1
# gRPC API. Native-gRPC *write* responses lose their trailers across the
# Cloudflare edge ("server closed the stream without sending trailers"), and a
# direct/bypass connection fails ZITADEL's instance-host check. REST is plain
# HTTP/JSON — no trailers — and works through the gateway. Same reason SMTP and
# the Bifrost client are done by their own scripts. See
# docs/runbooks/zitadel-console-grpc-404.md.
#
# Generalises configure-bifrost-oauth.sh: creates (idempotently) a WEB OIDC app
# with BASIC client auth in a project (default "Homelab"). On first create it
# prints clientId + clientSecret ONCE and a ready-to-paste `vault kv put`. These
# apps are confidential server-side clients (they hold the secret and exchange
# the auth code themselves) — so WEB + BASIC, exactly like bifrost-admin.
#
# Config from zitadel/terraform/.env (ZITADEL_TOKEN = service-user PAT) or env.
# Optional ZITADEL_ORG_ID targets a specific org (else the token's default org).
#
# Usage:
#   APP_NAME=stirling-pdf \
#   REDIRECT_URIS=https://pdf.meirong.dev/login/oauth2/code/oidc,https://pdf.meirong.dev/login/oauth2/code/zitadel \
#   POST_LOGOUT_URIS=https://pdf.meirong.dev/ \
#   VAULT_PATH=secret/oracle-k3s/stirling-pdf \
#   ./configure-oidc-app.sh
#
# REDIRECT_URIS / POST_LOGOUT_URIS are comma-separated. VAULT_PATH only shapes
# the printed helper command; it writes nothing.

set -euo pipefail

DOMAIN="${ZITADEL_DOMAIN:-auth.meirong.dev}"
PROJECT_NAME="${ZITADEL_PROJECT_NAME:-Homelab}"

: "${APP_NAME:?set APP_NAME (e.g. stirling-pdf)}"
: "${REDIRECT_URIS:?set REDIRECT_URIS (comma-separated)}"
POST_LOGOUT_URIS="${POST_LOGOUT_URIS:-}"
VAULT_PATH="${VAULT_PATH:-secret/homelab/${APP_NAME}-oidc}"

# Load .env next to the terraform module if the vars aren't already exported.
ENV_FILE="$(cd "$(dirname "$0")/../terraform" && pwd)/.env"
if [[ -f "$ENV_FILE" ]]; then set -a; source "$ENV_FILE"; set +a; fi

: "${ZITADEL_TOKEN:?set ZITADEL_TOKEN (service-user PAT) or provide zitadel/terraform/.env}"

BASE="https://${DOMAIN}/management/v1"
AUTH=(-H "Authorization: Bearer ${ZITADEL_TOKEN}" -H "Content-Type: application/json")
if [[ -n "${ZITADEL_ORG_ID:-}" ]]; then AUTH+=(-H "x-zitadel-orgid: ${ZITADEL_ORG_ID}"); fi

# --- project -----------------------------------------------------------------
echo "==> finding project '${PROJECT_NAME}' ..."
PROJECTS=$(curl -fsS -X POST "${BASE}/projects/_search" "${AUTH[@]}" -d '{}')
PROJECT_ID=$(printf '%s' "$PROJECTS" | python3 -c "
import json,sys
d=json.load(sys.stdin); name=sys.argv[1]
for p in (d.get('result') or []):
    if p.get('name')==name: print(p.get('id','')); break
" "$PROJECT_NAME" || true)

if [[ -z "${PROJECT_ID:-}" ]]; then
  echo "==> creating project '${PROJECT_NAME}' ..."
  PROJECT_ID=$(curl -fsS -X POST "${BASE}/projects" "${AUTH[@]}" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'name': sys.argv[1]}))" "$PROJECT_NAME")" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  echo "    created project ${PROJECT_ID}"
else
  echo "    found project ${PROJECT_ID}"
fi

# --- oidc app ----------------------------------------------------------------
echo "==> finding app '${APP_NAME}' ..."
APPS=$(curl -fsS -X POST "${BASE}/projects/${PROJECT_ID}/apps/_search" "${AUTH[@]}" -d '{}')
APP_ID=$(printf '%s' "$APPS" | python3 -c "
import json,sys
d=json.load(sys.stdin); name=sys.argv[1]
for a in (d.get('result') or []):
    if a.get('name')==name: print(a.get('id','')); break
" "$APP_NAME" || true)

if [[ -n "${APP_ID:-}" ]]; then
  CLIENT_ID=$(printf '%s' "$APPS" | python3 -c "
import json,sys
d=json.load(sys.stdin); name=sys.argv[1]
for a in (d.get('result') or []):
    if a.get('name')==name: print((a.get('oidcConfig') or {}).get('clientId','')); break
" "$APP_NAME" || true)
  echo "    found existing app ${APP_ID} (clientId=${CLIENT_ID})"
  echo "    clientSecret is shown only at creation; if lost, regenerate with:"
  echo "      curl -X POST '${BASE}/projects/${PROJECT_ID}/apps/${APP_ID}/oidc_config/_regenerate_clientsecret' \\"
  echo "        -H 'Authorization: Bearer \$ZITADEL_TOKEN' -H 'Content-Type: application/json' -d '{}'"
  exit 0
fi

echo "==> creating OIDC web app '${APP_NAME}' ..."
BODY=$(python3 - "$APP_NAME" "$REDIRECT_URIS" "$POST_LOGOUT_URIS" <<'PY'
import json,sys
_, name, redirects, logouts = sys.argv
def split(s): return [x.strip() for x in s.split(',') if x.strip()]
print(json.dumps({
  "name": name,
  "redirectUris": split(redirects),
  "postLogoutRedirectUris": split(logouts),
  "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
  "grantTypes": ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"],
  "appType": "OIDC_APP_TYPE_WEB",
  "authMethodType": "OIDC_AUTH_METHOD_TYPE_BASIC",
  "accessTokenType": "OIDC_TOKEN_TYPE_BEARER",
  "devMode": False,
}))
PY
)
RESP=$(curl -fsS -X POST "${BASE}/projects/${PROJECT_ID}/apps/oidc" "${AUTH[@]}" -d "$BODY")
CLIENT_ID=$(printf '%s' "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('clientId',''))")
CLIENT_SECRET=$(printf '%s' "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('clientSecret',''))")

cat <<EOF

    created OIDC app '${APP_NAME}' — client credentials (shown ONCE):
      client-id     = ${CLIENT_ID}
      client-secret = ${CLIENT_SECRET}

==> store them in Vault for ESO (run from a host with vault access):

  vault kv put ${VAULT_PATH} \\
    oauth_client_id='${CLIENT_ID}' \\
    oauth_client_secret='${CLIENT_SECRET}'

  (merge — if the path already holds other keys, fetch + re-put them too, or use
   'vault kv patch ${VAULT_PATH} oauth_client_id=... oauth_client_secret=...')

ESO then syncs these into the app's K8s Secret. Done.
EOF
