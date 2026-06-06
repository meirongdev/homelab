#!/usr/bin/env bash
# Idempotent ZITADEL OIDC client for the Bifrost admin oauth2-proxy, via the
# management REST API.
#
# WHY REST and not the Terraform module: the zitadel TF provider drives the v1
# gRPC API. Native-gRPC *write* responses lose their trailers across the
# Cloudflare edge ("server closed the stream without sending trailers"), and a
# direct/bypass connection fails ZITADEL's instance-host check. REST is plain
# HTTP/JSON — no trailers — and works through the gateway. Same reason SMTP is
# done by configure-smtp.sh. See docs/runbooks/zitadel-console-grpc-404.md.
#
# Creates (idempotently): a project ("Homelab" by default) and a WEB OIDC app
# ("bifrost-admin") whose redirect URI is the oauth2-proxy callback on
# llm.meirong.dev. On first create it prints clientId + clientSecret — store them
# (plus a generated cookie-secret) in Vault so ESO can sync them to the
# oauth2-proxy-secret in the `bifrost` namespace.
#
# Config from zitadel/terraform/.env (ZITADEL_TOKEN = service-user PAT) or env.
# Optional ZITADEL_ORG_ID targets a specific org (else the token's default org).
#
# Usage:   ./configure-bifrost-oauth.sh

set -euo pipefail

DOMAIN="${ZITADEL_DOMAIN:-auth.meirong.dev}"
PROJECT_NAME="${ZITADEL_PROJECT_NAME:-Homelab}"
APP_NAME="${BIFROST_APP_NAME:-bifrost-admin}"
REDIRECT_URI="https://llm.meirong.dev/oauth2/callback"
POST_LOGOUT_URI="https://llm.meirong.dev/"

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
BODY=$(python3 - "$APP_NAME" "$REDIRECT_URI" "$POST_LOGOUT_URI" <<'PY'
import json,sys
_, name, redirect, logout = sys.argv
print(json.dumps({
  "name": name,
  "redirectUris": [redirect],
  "postLogoutRedirectUris": [logout],
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
COOKIE_SECRET=$(python3 -c "import secrets,base64; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())")

cat <<EOF

    created OIDC app — client credentials (shown ONCE):
      client-id     = ${CLIENT_ID}
      client-secret = ${CLIENT_SECRET}

==> store them (plus a generated cookie-secret) in Vault for ESO:

  vault kv put secret/homelab/bifrost-oauth2-proxy \\
    client-id='${CLIENT_ID}' \\
    client-secret='${CLIENT_SECRET}' \\
    cookie-secret='${COOKIE_SECRET}'

ESO (ExternalSecret oauth2-proxy-secret in the bifrost namespace) then syncs these
into the K8s Secret oauth2-proxy uses. Done.
EOF
