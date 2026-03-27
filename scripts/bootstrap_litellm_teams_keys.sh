#!/usr/bin/env bash
#
# Recreate LiteLLM teams + virtual keys after an empty DB (e.g. Postgres PVC wiped).
# Matches the layout expected by scripts/test_azure_oidc.sh
#
# Prerequisites:
#   - LiteLLM reachable (default http://127.0.0.1:4000 — port-forward if needed)
#   - PROXY_MASTER_KEY in env (same as litellm-env-secret PROXY_MASTER_KEY)
#
# Usage:
#   export PROXY_MASTER_KEY="sk-..."
#   bash scripts/bootstrap_litellm_teams_keys.sh
#
# If team aliases already exist from a previous partial run:
#   export BOOTSTRAP_SUFFIX="$(date +%s)"
#   bash scripts/bootstrap_litellm_teams_keys.sh
#
set -euo pipefail

LITELLM_URL="${LITELLM_URL:-http://127.0.0.1:4000}"
BOOTSTRAP_SUFFIX="${BOOTSTRAP_SUFFIX:-}"

# Azure AD object IDs (must match test_azure_oidc.sh and key user_id bindings)
OID_ANUDEEP="80fa6a56-cf00-4090-bbce-b6b3021cf1a7"
OID_RAHUL="8ca1dc25-e960-4c47-9843-b5b7f51a4315"
OID_SACHIN="91c0c55c-0c8a-49fb-85c9-acef4efb798f"

if [[ -z "${PROXY_MASTER_KEY:-}" ]]; then
  echo "ERROR: set PROXY_MASTER_KEY (LiteLLM master key)"
  exit 1
fi

suffix_tag() {
  if [[ -n "$BOOTSTRAP_SUFFIX" ]]; then
    echo "-${BOOTSTRAP_SUFFIX}"
  else
    echo ""
  fi
}

SUF="$(suffix_tag)"

api_post_json() {
  local url="$1" data="$2"
  local resp code
  resp=$(curl -s -w '\n%{http_code}' -X POST "${url}" \
    -H "Authorization: Bearer ${PROXY_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "${data}")
  code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | sed '$d')
  if [[ ! "$code" =~ ^2 ]]; then
    echo "HTTP ${code} body: ${body:0:500}"
    return 1
  fi
  echo "$body"
}

parse_team_id() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('team_id') or d.get('team','') or '')" 2>/dev/null || true
}

parse_key() {
  python3 -c "import json,sys; d=json.load(sys.stdin); k=d.get('key'); assert k, d; print(k)"
}

echo "LiteLLM URL: ${LITELLM_URL}"
echo "Creating teams (suffix: ${SUF:-<none>})..."

TEAM_A_BODY=$(api_post_json "${LITELLM_URL}/team/new" \
  "{\"team_alias\":\"litellm-team-a${SUF}\",\"models\":[\"gemini-flash\"],\"max_budget\":10}") || exit 1
TEAM_A_ID=$(echo "$TEAM_A_BODY" | parse_team_id)
[[ -n "$TEAM_A_ID" ]] || { echo "Unexpected response: $TEAM_A_BODY"; exit 1; }
echo "  team-a (gemini):     ${TEAM_A_ID}"

TEAM_B_BODY=$(api_post_json "${LITELLM_URL}/team/new" \
  "{\"team_alias\":\"litellm-team-b${SUF}\",\"models\":[\"claude-sonnet-4-5\"],\"max_budget\":10}") || exit 1
TEAM_B_ID=$(echo "$TEAM_B_BODY" | parse_team_id)
echo "  team-b (claude):     ${TEAM_B_ID}"

TEAM_C_BODY=$(api_post_json "${LITELLM_URL}/team/new" \
  "{\"team_alias\":\"litellm-team-c${SUF}\",\"models\":[\"gemini-flash\",\"claude-sonnet-4-5\"],\"max_budget\":10}") || exit 1
TEAM_C_ID=$(echo "$TEAM_C_BODY" | parse_team_id)
echo "  team-c (both):       ${TEAM_C_ID}"

TEAM_D_BODY=$(api_post_json "${LITELLM_URL}/team/new" \
  "{\"team_alias\":\"litellm-team-d${SUF}\",\"models\":[\"gemini-flash\",\"claude-sonnet-4-5\"],\"max_budget\":10}") || exit 1
TEAM_D_ID=$(echo "$TEAM_D_BODY" | parse_team_id)
echo "  team-d (both):       ${TEAM_D_ID}"

KEY_ALIAS_SUFFIX="${KEY_ALIAS_SUFFIX:-$(date +%s)}"
echo ""
echo "Creating virtual keys (key alias suffix: ${KEY_ALIAS_SUFFIX})..."

KEY_BODY=$(api_post_json "${LITELLM_URL}/key/generate" \
  "{\"team_id\":\"${TEAM_A_ID}\",\"user_id\":\"${OID_ANUDEEP}\",\"models\":[\"gemini-flash\"],\"duration\":\"30d\",\"key_alias\":\"anudeep-team-a-${KEY_ALIAS_SUFFIX}\"}") || exit 1
KEY_ANUDEEP_A=$(echo "$KEY_BODY" | parse_key)

KEY_BODY=$(api_post_json "${LITELLM_URL}/key/generate" \
  "{\"team_id\":\"${TEAM_B_ID}\",\"user_id\":\"${OID_SACHIN}\",\"models\":[\"claude-sonnet-4-5\"],\"duration\":\"30d\",\"key_alias\":\"sachin-team-b-${KEY_ALIAS_SUFFIX}\"}") || exit 1
KEY_SACHIN_B=$(echo "$KEY_BODY" | parse_key)

KEY_BODY=$(api_post_json "${LITELLM_URL}/key/generate" \
  "{\"team_id\":\"${TEAM_C_ID}\",\"user_id\":\"${OID_ANUDEEP}\",\"models\":[\"gemini-flash\",\"claude-sonnet-4-5\"],\"duration\":\"30d\",\"key_alias\":\"anudeep-team-c-${KEY_ALIAS_SUFFIX}\"}") || exit 1
KEY_ANUDEEP_C=$(echo "$KEY_BODY" | parse_key)

KEY_BODY=$(api_post_json "${LITELLM_URL}/key/generate" \
  "{\"team_id\":\"${TEAM_D_ID}\",\"user_id\":\"${OID_RAHUL}\",\"models\":[\"gemini-flash\",\"claude-sonnet-4-5\"],\"duration\":\"30d\",\"key_alias\":\"rahul-team-d-${KEY_ALIAS_SUFFIX}\"}") || exit 1
KEY_RAHUL_D=$(echo "$KEY_BODY" | parse_key)

for k in KEY_ANUDEEP_A KEY_SACHIN_B KEY_ANUDEEP_C KEY_RAHUL_D; do
  v="${!k}"
  if [[ -z "$v" ]]; then
    echo "ERROR: failed to create ${k}"
    exit 1
  fi
  echo "  ${k}=${v}"
done

echo ""
echo "Done. Export these for test_azure_oidc.sh (CREATE_KEYS=false):"
echo ""
echo "export KEY_ANUDEEP_A='${KEY_ANUDEEP_A}'"
echo "export KEY_SACHIN_B='${KEY_SACHIN_B}'"
echo "export KEY_ANUDEEP_C='${KEY_ANUDEEP_C}'"
echo "export KEY_RAHUL_D='${KEY_RAHUL_D}'"
echo ""
echo "Then run E2E (with fresh Azure tokens):"
echo "  export TOKEN_ANUDEEP=\$(az account get-access-token --resource \"api://1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe\" --query accessToken -o tsv)"
echo "  # TOKEN_RAHUL / TOKEN_SACHIN from colleagues or az for their users"
echo "  bash scripts/test_azure_oidc.sh"
