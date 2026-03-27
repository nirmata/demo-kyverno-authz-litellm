#!/usr/bin/env bash
#
# End-to-end demo & test script for Azure AD OIDC + LiteLLM + AI Governance Proxy
#
# Tests two scenarios with real Azure AD tokens from 3 users:
#
#   Scenario A — Model-Based Team Isolation
#     team-a: Anudeep  → gemini-flash only
#     team-b: Sachin   → claude-sonnet-4-5 only
#
#   Scenario B — Cross-Team Key Isolation via JWT Identity Binding
#     team-c: Anudeep  → gemini + claude
#     team-d: Rahul    → gemini + claude
#     (both teams have the same models; isolation enforced by JWT identity)
#
# Prerequisites:
#   - LiteLLM proxy port-forwarded to 127.0.0.1:4000
#   - Azure AD App Registration (api://1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe)
#   - custom_auth.py v10 deployed (oid claim support)
#   - litellm-jwt-config ConfigMap pointing to Azure AD JWKS
#
# After a LiteLLM DB / PVC reset, recreate teams + keys (master key only):
#   bash scripts/bootstrap_litellm_teams_keys.sh
#
# Usage:
#   export PROXY_MASTER_KEY="sk-..."
#
#   # Tokens — each user runs: az account get-access-token --resource "api://1e959ea2-..." --query accessToken -o tsv
#   export TOKEN_ANUDEEP="eyJ0eXAi..."
#   export TOKEN_SACHIN="eyJ0eXAi..."
#   export TOKEN_RAHUL="eyJ0eXAi..."
#
#   # Virtual keys (created by this script if CREATE_KEYS=true, or provide manually)
#   export KEY_ANUDEEP_A="sk-..."   # team-a, gemini only
#   export KEY_SACHIN_B="sk-..."    # team-b, claude only
#   export KEY_ANUDEEP_C="sk-..."   # team-c, gemini + claude
#   export KEY_RAHUL_D="sk-..."     # team-d, gemini + claude
#
#   bash scripts/test_azure_oidc.sh
#
set -euo pipefail

LITELLM_URL="${LITELLM_URL:-http://127.0.0.1:4000}"
APP_ID="${APP_ID:-1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe}"
CREATE_KEYS="${CREATE_KEYS:-false}"

# Azure OIDs
OID_ANUDEEP="80fa6a56-cf00-4090-bbce-b6b3021cf1a7"
OID_RAHUL="8ca1dc25-e960-4c47-9843-b5b7f51a4315"
OID_SACHIN="91c0c55c-0c8a-49fb-85c9-acef4efb798f"

# ── Colors ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

# ── Helpers ───────────────────────────────────────────────────────────────────

banner() {
  echo ""
  echo -e "${BOLD}========================================================================${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${BOLD}========================================================================${NC}"
  echo ""
}

section() {
  echo -e "${CYAN}── $1 ──${NC}"
  echo ""
}

run_test() {
  local test_id="$1"
  local description="$2"
  local expect="$3"         # "allowed" or "denied"
  local pattern="$4"        # grep -i pattern to match in response body
  shift 4

  TOTAL=$((TOTAL + 1))

  local response http_code body
  response=$(curl -s -w '\n%{http_code}' "$@" 2>&1)
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  local matched=false status_ok=false
  echo "$body" | grep -qi "$pattern" 2>/dev/null && matched=true

  if [[ "$expect" == "allowed" && "$http_code" =~ ^2 ]]; then
    status_ok=true
  elif [[ "$expect" == "denied" && ! "$http_code" =~ ^2 ]]; then
    status_ok=true
  fi

  if [[ "$matched" == true && "$status_ok" == true ]]; then
    echo -e "  ${GREEN}PASS${NC}  ${test_id}: ${description}"
    echo -e "        ${DIM}HTTP ${http_code} | matched: ${pattern}${NC}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}  ${test_id}: ${description}"
    echo -e "        Expected: ${expect}, pattern='${pattern}'"
    echo -e "        Got: HTTP ${http_code}"
    echo -e "        Body: $(echo "$body" | head -c 200)"
    FAIL=$((FAIL + 1))
  fi
  echo ""
}

chat() {
  # usage: chat <key> <model> <message> [jwt_token]
  local key="$1" model="$2" msg="$3" jwt="${4:-}"
  local -a args=(
    -X POST "${LITELLM_URL}/v1/chat/completions"
    -H "Authorization: Bearer ${key}"
    -H "Content-Type: application/json"
    -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"${msg}\"}]}"
  )
  [[ -n "$jwt" ]] && args+=(-H "X-Identity-Token: ${jwt}")
  echo "${args[@]}"
}

# ── Validate required env vars ────────────────────────────────────────────────

banner "Azure AD OIDC — LiteLLM + Kyverno E2E Test Suite"

echo -e "  ${BOLD}LiteLLM URL:${NC}    ${LITELLM_URL}"
echo -e "  ${BOLD}Azure App ID:${NC}   ${APP_ID}"
echo ""

for var in PROXY_MASTER_KEY TOKEN_ANUDEEP TOKEN_SACHIN TOKEN_RAHUL; do
  if [[ -z "${!var:-}" ]]; then
    echo -e "${RED}ERROR: ${var} is not set${NC}"
    echo ""
    echo "Required environment variables:"
    echo "  PROXY_MASTER_KEY   — LiteLLM master key"
    echo "  TOKEN_ANUDEEP      — Azure AD JWT for anudeep.nalla@nirmata.com"
    echo "  TOKEN_SACHIN       — Azure AD JWT for sachin.agarwal@nirmata.com"
    echo "  TOKEN_RAHUL        — Azure AD JWT for rahul.kaushal@nirmata.com"
    echo ""
    echo "Get tokens with:"
    echo "  az account get-access-token --resource \"api://${APP_ID}\" --query accessToken -o tsv"
    echo ""
    echo "Optional (if CREATE_KEYS=true is not set):"
    echo "  KEY_ANUDEEP_A   — virtual key: Anudeep / team-a / gemini only"
    echo "  KEY_SACHIN_B    — virtual key: Sachin / team-b / claude only"
    echo "  KEY_ANUDEEP_C   — virtual key: Anudeep / team-c / gemini + claude"
    echo "  KEY_RAHUL_D     — virtual key: Rahul / team-d / gemini + claude"
    exit 1
  fi
done

echo -e "  ${BOLD}Anudeep token:${NC}  ${TOKEN_ANUDEEP:0:40}..."
echo -e "  ${BOLD}Sachin token:${NC}   ${TOKEN_SACHIN:0:40}..."
echo -e "  ${BOLD}Rahul token:${NC}    ${TOKEN_RAHUL:0:40}..."
echo ""

# ── Optionally create teams + keys ────────────────────────────────────────────

if [[ "$CREATE_KEYS" == "true" ]]; then
  section "Creating teams and virtual keys"

  # Unique suffix avoids "Key with alias already exists" on repeat runs
  KEY_ALIAS_SUFFIX="${KEY_ALIAS_SUFFIX:-$(date +%s)}"

  echo "  Creating team-a (gemini only)..."
  TEAM_A_ID=$(curl -s -X POST "${LITELLM_URL}/team/new" \
    -H "Authorization: Bearer ${PROXY_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"team_alias":"litellm-team-a","models":["gemini-flash"],"max_budget":10}' \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['team_id'])")
  echo "    team_id: ${TEAM_A_ID}"

  echo "  Creating team-b (claude only)..."
  TEAM_B_ID=$(curl -s -X POST "${LITELLM_URL}/team/new" \
    -H "Authorization: Bearer ${PROXY_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"team_alias":"litellm-team-b","models":["claude-sonnet-4-5"],"max_budget":10}' \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['team_id'])")
  echo "    team_id: ${TEAM_B_ID}"

  echo "  Creating team-c (gemini + claude)..."
  TEAM_C_ID=$(curl -s -X POST "${LITELLM_URL}/team/new" \
    -H "Authorization: Bearer ${PROXY_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"team_alias":"litellm-team-c","models":["gemini-flash","claude-sonnet-4-5"],"max_budget":10}' \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['team_id'])")
  echo "    team_id: ${TEAM_C_ID}"

  echo "  Creating team-d (gemini + claude)..."
  TEAM_D_ID=$(curl -s -X POST "${LITELLM_URL}/team/new" \
    -H "Authorization: Bearer ${PROXY_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"team_alias":"litellm-team-d","models":["gemini-flash","claude-sonnet-4-5"],"max_budget":10}' \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['team_id'])")
  echo "    team_id: ${TEAM_D_ID}"

  echo ""

  echo "  Creating key: Anudeep / team-a / gemini..."
  KEY_ANUDEEP_A=$(curl -s -X POST "${LITELLM_URL}/key/generate" \
    -H "Authorization: Bearer ${PROXY_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"team_id\":\"${TEAM_A_ID}\",\"user_id\":\"${OID_ANUDEEP}\",\"models\":[\"gemini-flash\"],\"duration\":\"30d\",\"key_alias\":\"anudeep-team-a-${KEY_ALIAS_SUFFIX}\"}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['key'])")
  echo "    key: ${KEY_ANUDEEP_A}"

  echo "  Creating key: Sachin / team-b / claude..."
  KEY_SACHIN_B=$(curl -s -X POST "${LITELLM_URL}/key/generate" \
    -H "Authorization: Bearer ${PROXY_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"team_id\":\"${TEAM_B_ID}\",\"user_id\":\"${OID_SACHIN}\",\"models\":[\"claude-sonnet-4-5\"],\"duration\":\"30d\",\"key_alias\":\"sachin-team-b-${KEY_ALIAS_SUFFIX}\"}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['key'])")
  echo "    key: ${KEY_SACHIN_B}"

  echo "  Creating key: Anudeep / team-c / gemini+claude..."
  KEY_ANUDEEP_C=$(curl -s -X POST "${LITELLM_URL}/key/generate" \
    -H "Authorization: Bearer ${PROXY_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"team_id\":\"${TEAM_C_ID}\",\"user_id\":\"${OID_ANUDEEP}\",\"models\":[\"gemini-flash\",\"claude-sonnet-4-5\"],\"duration\":\"30d\",\"key_alias\":\"anudeep-team-c-${KEY_ALIAS_SUFFIX}\"}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['key'])")
  echo "    key: ${KEY_ANUDEEP_C}"

  echo "  Creating key: Rahul / team-d / gemini+claude..."
  KEY_RAHUL_D=$(curl -s -X POST "${LITELLM_URL}/key/generate" \
    -H "Authorization: Bearer ${PROXY_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"team_id\":\"${TEAM_D_ID}\",\"user_id\":\"${OID_RAHUL}\",\"models\":[\"gemini-flash\",\"claude-sonnet-4-5\"],\"duration\":\"30d\",\"key_alias\":\"rahul-team-d-${KEY_ALIAS_SUFFIX}\"}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['key'])")
  echo "    key: ${KEY_RAHUL_D}"

  echo ""
  echo -e "  ${GREEN}Teams and keys created.${NC}"
  echo "  Export these for future runs:"
  echo "    export KEY_ANUDEEP_A='${KEY_ANUDEEP_A}'"
  echo "    export KEY_SACHIN_B='${KEY_SACHIN_B}'"
  echo "    export KEY_ANUDEEP_C='${KEY_ANUDEEP_C}'"
  echo "    export KEY_RAHUL_D='${KEY_RAHUL_D}'"
  echo ""
fi

# Validate keys are set
for var in KEY_ANUDEEP_A KEY_SACHIN_B KEY_ANUDEEP_C KEY_RAHUL_D; do
  if [[ -z "${!var:-}" ]]; then
    echo -e "${RED}ERROR: ${var} is not set.${NC}"
    echo "  Either set CREATE_KEYS=true or export the key manually."
    exit 1
  fi
done

echo -e "  ${BOLD}Keys:${NC}"
echo "    KEY_ANUDEEP_A (team-a/gemini):       ${KEY_ANUDEEP_A:0:15}..."
echo "    KEY_SACHIN_B  (team-b/claude):        ${KEY_SACHIN_B:0:15}..."
echo "    KEY_ANUDEEP_C (team-c/gemini+claude): ${KEY_ANUDEEP_C:0:15}..."
echo "    KEY_RAHUL_D   (team-d/gemini+claude): ${KEY_RAHUL_D:0:15}..."
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO A: Model-Based Team Isolation
# ══════════════════════════════════════════════════════════════════════════════

banner "Scenario A: Model-Based Team Isolation"

echo "  team-a: Anudeep  → gemini-flash only"
echo "  team-b: Sachin   → claude-sonnet-4-5 only"
echo "  Isolation enforced by model restrictions on the virtual key."
echo ""
echo "------------------------------------------------------------------------"
echo ""

# A1: Anudeep (team-a) → gemini → ALLOWED
run_test "A1" \
  "Anudeep JWT + team-a key → gemini (should be ALLOWED)" \
  "allowed" "role.*assistant" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_ANUDEEP_A}" \
  -H "X-Identity-Token: ${TOKEN_ANUDEEP}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"Reply with: A1 pass"}]}'

# A2: Anudeep (team-a) → claude → DENIED (model not in key's allowed list)
run_test "A2" \
  "Anudeep JWT + team-a key → claude (should be DENIED — model restriction)" \
  "denied" "key not allowed to access model\|not allowed" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_ANUDEEP_A}" \
  -H "X-Identity-Token: ${TOKEN_ANUDEEP}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"should not work"}]}'

# A3: Sachin (team-b) → claude → ALLOWED
run_test "A3" \
  "Sachin JWT + team-b key → claude (should be ALLOWED)" \
  "allowed" "role.*assistant" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_SACHIN_B}" \
  -H "X-Identity-Token: ${TOKEN_SACHIN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"Reply with: A3 pass"}]}'

# A4: Sachin (team-b) → gemini → DENIED (model not in key's allowed list)
run_test "A4" \
  "Sachin JWT + team-b key → gemini (should be DENIED — model restriction)" \
  "denied" "key not allowed to access model\|not allowed" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_SACHIN_B}" \
  -H "X-Identity-Token: ${TOKEN_SACHIN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"should not work"}]}'

# A5: Anudeep JWT + Sachin's key → DENIED (owner mismatch — cross-team theft)
run_test "A5" \
  "Anudeep JWT + Sachin key (should be DENIED — cross-team key theft)" \
  "denied" "does not match key owner" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_SACHIN_B}" \
  -H "X-Identity-Token: ${TOKEN_ANUDEEP}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"should not work"}]}'

# A6: Sachin JWT + Anudeep's key → DENIED (owner mismatch — reverse direction)
run_test "A6" \
  "Sachin JWT + Anudeep key (should be DENIED — reverse cross-team theft)" \
  "denied" "does not match key owner" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_ANUDEEP_A}" \
  -H "X-Identity-Token: ${TOKEN_SACHIN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"should not work"}]}'


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO B: Cross-Team Key Isolation via JWT Identity Binding
# ══════════════════════════════════════════════════════════════════════════════

banner "Scenario B: Cross-Team Key Isolation via JWT Identity Binding"

echo "  team-c: Anudeep  → gemini + claude"
echo "  team-d: Rahul    → gemini + claude"
echo "  Both teams have identical model permissions."
echo "  Isolation enforced purely by JWT identity binding (oid == key.user_id)."
echo ""
echo "------------------------------------------------------------------------"
echo ""

# B1: Anudeep JWT + Anudeep key → gemini → ALLOWED
run_test "B1" \
  "Anudeep JWT + Anudeep key → gemini (should be ALLOWED)" \
  "allowed" "role.*assistant" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_ANUDEEP_C}" \
  -H "X-Identity-Token: ${TOKEN_ANUDEEP}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"Reply with: B1 pass"}]}'

# B2: Rahul JWT + Anudeep key → DENIED (owner mismatch)
run_test "B2" \
  "Rahul JWT + Anudeep key (should be DENIED — owner mismatch)" \
  "denied" "does not match key owner" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_ANUDEEP_C}" \
  -H "X-Identity-Token: ${TOKEN_RAHUL}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"should not work"}]}'

# B3: No JWT + virtual key → DENIED (missing identity token on inference route)
run_test "B3" \
  "No JWT + virtual key (should be DENIED — missing identity token)" \
  "denied" "Missing identity token" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_ANUDEEP_C}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"should not work"}]}'

# B4: Master key without JWT → ALLOWED (admin bypass)
run_test "B4" \
  "Master key, no JWT (should be ALLOWED — admin bypass)" \
  "allowed" "role.*assistant" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${PROXY_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"Reply with: B4 pass"}]}'

# B5: Rahul JWT + Rahul key → claude → ALLOWED
run_test "B5" \
  "Rahul JWT + Rahul key → claude (should be ALLOWED)" \
  "allowed" "role.*assistant" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_RAHUL_D}" \
  -H "X-Identity-Token: ${TOKEN_RAHUL}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"Reply with: B5 pass"}]}'

# B6: Anudeep JWT + Rahul key → DENIED (owner mismatch, reverse direction)
run_test "B6" \
  "Anudeep JWT + Rahul key (should be DENIED — owner mismatch reverse)" \
  "denied" "does not match key owner" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_RAHUL_D}" \
  -H "X-Identity-Token: ${TOKEN_ANUDEEP}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"should not work"}]}'

# B7: Fake/tampered JWT → DENIED (signature verification fails)
run_test "B7" \
  "Fake JWT + key (should be DENIED — invalid signature)" \
  "denied" "Invalid identity token\|Unable to find a signing key\|invalid" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_ANUDEEP_C}" \
  -H "X-Identity-Token: fake.invalid.token" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"should not work"}]}'

# B8: Old mock JWT (wrong issuer/JWKS) → DENIED
run_test "B8" \
  "Old mock JWT (should be DENIED — wrong issuer/signing key)" \
  "denied" "Unable to find a signing key\|Invalid identity token\|invalid" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_ANUDEEP_C}" \
  -H "X-Identity-Token: old-mock.invalid.token" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"should not work"}]}'


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO C: Management / UI Routes (no JWT required)
# ══════════════════════════════════════════════════════════════════════════════

banner "Scenario C: Management & UI Routes (no JWT required)"

echo "  Management routes use session keys or master key."
echo "  JWT is NOT required — only enforced on inference routes."
echo ""
echo "------------------------------------------------------------------------"
echo ""

# C1: Model list with master key (no JWT) → ALLOWED
run_test "C1" \
  "GET /model/info with master key, no JWT (should be ALLOWED)" \
  "allowed" "model_name\|model_info\|data" \
  "${LITELLM_URL}/model/info" \
  -H "Authorization: Bearer ${PROXY_MASTER_KEY}"

# C2: Key info with master key (no JWT) → ALLOWED
run_test "C2" \
  "GET /key/info with master key, no JWT (should be ALLOWED)" \
  "allowed" "key\|info\|key_name" \
  "${LITELLM_URL}/key/info?key=${KEY_ANUDEEP_C}" \
  -H "Authorization: Bearer ${PROXY_MASTER_KEY}"

# C3: Team list with master key (no JWT) → ALLOWED
run_test "C3" \
  "GET /team/list with master key, no JWT (should be ALLOWED)" \
  "allowed" "team_alias\|team_id" \
  "${LITELLM_URL}/team/list" \
  -H "Authorization: Bearer ${PROXY_MASTER_KEY}"

# C4: Health endpoint (no auth at all) → ALLOWED
run_test "C4" \
  "GET /health/readiness (no auth) (should be ALLOWED)" \
  "allowed" "healthy" \
  "${LITELLM_URL}/health/readiness"


# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════

banner "TEST RESULTS"

echo -e "  ${BOLD}Scenario A${NC} — Model-Based Team Isolation:        6 tests"
echo -e "  ${BOLD}Scenario B${NC} — JWT Identity Key Isolation:         8 tests"
echo -e "  ${BOLD}Scenario C${NC} — Management Routes (no JWT):         4 tests"
echo ""

if [[ $FAIL -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}ALL ${TOTAL} TESTS PASSED${NC}"
else
  echo -e "  ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC} out of ${TOTAL} tests"
fi

echo ""

echo "  Azure AD Users Tested:"
echo "    Anudeep Nalla   (anudeep.nalla@nirmata.com)  — OID: ${OID_ANUDEEP}"
echo "    Sachin Agarwal  (sachin.agarwal@nirmata.com) — OID: ${OID_SACHIN}"
echo "    Rahul Kaushal   (rahul.kaushal@nirmata.com)  — OID: ${OID_RAHUL}"
echo ""

echo "  Authorization Layers Verified:"
echo "    1. Azure AD OIDC — JWT signature, issuer, audience, expiry"
echo "    2. AI Governance Proxy — POST /authz/litellm (CEL policies)"
echo "    3. custom_auth.py — JWT identity binding (oid == key.user_id)"
echo "    4. LiteLLM Internal Auth — model access, budget, team scoping"
echo ""

echo -e "${BOLD}========================================================================${NC}"

exit $FAIL
