#!/usr/bin/env bash
#
# End-to-end test suite for JWT Identity Binding (Phase 1).
#
# Prerequisites:
#   - LiteLLM proxy port-forwarded to 127.0.0.1:4000
#   - Mock JWKS endpoint deployed (scripts/jwks-deployment.yaml)
#   - Test JWTs generated (python scripts/generate_test_jwt.py)
#   - Teams (team-c, team-d) and users (user-c, user-d) created with virtual keys
#
# Usage:
#   export PROXY_MASTER_KEY="sk-..."
#   export KEY_USER_C="sk-..."        # virtual key with user_id=user-c
#   export KEY_USER_D="sk-..."        # virtual key with user_id=user-d
#   bash scripts/test_jwt_identity.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LITELLM_URL="${LITELLM_URL:-http://127.0.0.1:4000}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

# ── Validate required env vars ─────────────────────────────────────────────────

for var in PROXY_MASTER_KEY KEY_USER_C KEY_USER_D; do
  if [[ -z "${!var:-}" ]]; then
    echo -e "${RED}ERROR: $var is not set${NC}"
    echo ""
    echo "Required environment variables:"
    echo "  PROXY_MASTER_KEY  — LiteLLM master key"
    echo "  KEY_USER_C        — virtual key owned by user-c"
    echo "  KEY_USER_D        — virtual key owned by user-d"
    echo ""
    echo "Example:"
    echo "  export PROXY_MASTER_KEY=\$(kubectl get secret -n litellm litellm-env-secret -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)"
    echo "  export KEY_USER_C='sk-...'"
    echo "  export KEY_USER_D='sk-...'"
    exit 1
  fi
done

# ── Load JWTs from disk ────────────────────────────────────────────────────────

JWT_C=$(cat "$SCRIPT_DIR/keys/user-c.jwt")
JWT_D=$(cat "$SCRIPT_DIR/keys/user-d.jwt")

# ── Helper functions ───────────────────────────────────────────────────────────

run_test() {
  local test_num="$1"
  local description="$2"
  local expect_result="$3"   # "allowed" or "denied"
  local expect_pattern="$4"  # grep pattern in response
  shift 4
  # remaining args: curl arguments

  TOTAL=$((TOTAL + 1))

  local response
  response=$(curl -s -w '\n%{http_code}' "$@" 2>&1)
  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  local matched=false
  if echo "$body" | grep -qi "$expect_pattern"; then
    matched=true
  fi

  local status_ok=false
  if [[ "$expect_result" == "allowed" && "$http_code" =~ ^2 ]]; then
    status_ok=true
  elif [[ "$expect_result" == "denied" && ! "$http_code" =~ ^2 ]]; then
    status_ok=true
  fi

  if [[ "$matched" == true && "$status_ok" == true ]]; then
    echo -e "  ${GREEN}PASS${NC}  Test $test_num: $description"
    echo "        HTTP $http_code | pattern matched: $expect_pattern"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}  Test $test_num: $description"
    echo "        Expected: $expect_result, pattern='$expect_pattern'"
    echo "        Got: HTTP $http_code"
    echo "        Body: $(echo "$body" | head -c 300)"
    FAIL=$((FAIL + 1))
  fi
  echo ""
}

chat_request() {
  # $1 = api_key, $2 = model, $3 = message, $4 = jwt (optional, empty to skip)
  local api_key="$1"
  local model="$2"
  local message="$3"
  local jwt_token="${4:-}"

  local -a headers=(
    -X POST
    "${LITELLM_URL}/v1/chat/completions"
    -H "Authorization: Bearer ${api_key}"
    -H "Content-Type: application/json"
    -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"${message}\"}]}"
  )

  if [[ -n "$jwt_token" ]]; then
    headers+=(-H "X-Identity-Token: ${jwt_token}")
  fi

  echo "${headers[@]}"
}

# ── Test Suite ─────────────────────────────────────────────────────────────────

echo ""
echo "========================================================================"
echo "  JWT Identity Binding — Test Suite (Phase 1)"
echo "========================================================================"
echo ""
echo "  LiteLLM URL:   $LITELLM_URL"
echo "  JWT user-c:    ${JWT_C:0:40}..."
echo "  JWT user-d:    ${JWT_D:0:40}..."
echo "  Key user-c:    ${KEY_USER_C:0:12}..."
echo "  Key user-d:    ${KEY_USER_D:0:12}..."
echo ""
echo "------------------------------------------------------------------------"
echo ""

# Test 1: user-c JWT + user-c key → Allowed
run_test 1 \
  "user-c JWT + user-c key → gemini (should be allowed)" \
  "allowed" \
  "role.*assistant" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_USER_C}" \
  -H "X-Identity-Token: ${JWT_C}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"Reply with exactly: jwt identity works"}]}'

# Test 2: user-d JWT + user-c key → Denied (owner mismatch)
run_test 2 \
  "user-d JWT + user-c key → Denied (owner mismatch)" \
  "denied" \
  "does not match key owner" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_USER_C}" \
  -H "X-Identity-Token: ${JWT_D}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"should not work"}]}'

# Test 3: No JWT + virtual key → Denied (missing identity token)
run_test 3 \
  "No JWT + virtual key → Denied (missing identity token)" \
  "denied" \
  "Missing identity token" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_USER_C}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"should not work"}]}'

# Test 4: Master key without JWT → Allowed (admin bypass)
run_test 4 \
  "Master key, no JWT → Allowed (admin bypass)" \
  "allowed" \
  "role.*assistant" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${PROXY_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"Reply with exactly: admin bypass works"}]}'

# Test 5: user-d JWT + user-d key → Allowed
run_test 5 \
  "user-d JWT + user-d key → claude (should be allowed)" \
  "allowed" \
  "role.*assistant" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_USER_D}" \
  -H "X-Identity-Token: ${JWT_D}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"Reply with exactly: user-d claude ok"}]}'

# Test 6: user-c JWT + user-d key → Denied (owner mismatch, reverse direction)
run_test 6 \
  "user-c JWT + user-d key → Denied (owner mismatch, reverse)" \
  "denied" \
  "does not match key owner" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_USER_D}" \
  -H "X-Identity-Token: ${JWT_C}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"should not work"}]}'

# Test 7: Invalid/fake JWT → Denied (bad signature)
run_test 7 \
  "Invalid/fake JWT → Denied (bad signature)" \
  "denied" \
  "Invalid identity token\|Unable to find a signing key\|invalid" \
  -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY_USER_C}" \
  -H "X-Identity-Token: eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImZha2Uta2V5In0.eyJzdWIiOiJoYWNrZXIiLCJpc3MiOiJodHRwOi8vbW9jay1pc3N1ZXIiLCJhdWQiOiJsaXRlbGxtLXByb3h5IiwiZXhwIjo5OTk5OTk5OTk5fQ.fakesignature" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"should not work"}]}'

# ── Summary ────────────────────────────────────────────────────────────────────

echo "========================================================================"
echo ""
if [[ $FAIL -eq 0 ]]; then
  echo -e "  ${GREEN}ALL $TOTAL TESTS PASSED${NC}"
else
  echo -e "  ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} out of $TOTAL tests"
fi
echo ""
echo "========================================================================"

exit $FAIL
