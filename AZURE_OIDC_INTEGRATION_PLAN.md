# Plan: Azure AD OIDC Integration for LiteLLM

## Goal

Replace the mock JWT issuer (local RSA keys + nginx JWKS endpoint) with Azure AD (Entra ID) as the real identity provider, so that:

- Users authenticate via Azure AD and receive a real OIDC token.
- `custom_auth.py` validates Azure-issued JWTs against Microsoft's JWKS endpoint.
- Azure AD groups map to LiteLLM teams for model/budget scoping.
- Key ownership binding (`JWT sub == key user_id`) continues to work.
- All 7 existing test scenarios still pass with Azure tokens instead of mock tokens.

---

## Current State (Mock JWT — What We Have)

```
Client                    custom_auth.py              AI Governance Proxy
  │                            │                               │
  │ X-Identity-Token: <JWT>    │                               │
  │ (signed by local RSA key)  │                               │
  │ iss: http://mock-issuer    │                               │
  │ aud: litellm-proxy         │                               │
  │ sub: user-c                │                               │
  │ email: user-c@example.com  │                               │
  │ groups: [team-c]           │                               │
  │────────────────────────────>                               │
  │                            │ Validate JWT via JWKS          │
  │                            │ (jwks-mock nginx pod)          │
  │                            │ POST /authz/litellm (JSON)     │
  │                            │────────────────────────────────>
  │                            │ allow + audit (CEL policies)   │
  │                            │<────────────────────────────────
  │                            │                               │
  │                            │ key ownership: sub == user_id? │
  │                            │ (user-c == user-c → OK)        │
```

### Current configuration

| Setting | Current value | Source |
|---------|---------------|--------|
| `JWT_JWKS_URL` | `http://jwks-mock.litellm.svc:8080/.well-known/jwks.json` | ConfigMap `litellm-jwt-config` |
| `JWT_ISSUER` | `http://mock-issuer` | ConfigMap `litellm-jwt-config` |
| `JWT_AUDIENCE` | `litellm-proxy` | ConfigMap `litellm-jwt-config` |
| `JWT_HEADER_NAME` | `X-Identity-Token` | ConfigMap `litellm-jwt-config` |
| JWT `sub` claim | Friendly name: `user-c` | `generate_test_jwt.py` |
| JWT `groups` claim | Friendly name: `["team-c"]` | `generate_test_jwt.py` |
| JWT `email` claim | `user-c@example.com` | `generate_test_jwt.py` |
| Signing algorithm | RS256, single key (`kid: mock-key-1`) | `generate_test_jwt.py` |
| Key ownership match | `key.user_id == jwt.sub` (e.g., `user-c == user-c`) | `custom_auth.py` |

### What works today

- Health probe bypass, master key bypass
- JWT validation (signature, expiry, issuer, audience)
- Key ownership binding on inference routes
- Management/UI routes work without JWT
- AI Governance Proxy evaluates `/authz/litellm` (CEL; configured in `governance-helm/values-authz.yml`)

---

## Target State (Azure AD OIDC)

```
Client                    custom_auth.py              AI Governance Proxy
  │                            │                                │
  │ X-Identity-Token: <JWT>    │                                │
  │ (signed by Microsoft)      │                                │
  │ iss: https://login.../{t}  │                                │
  │ aud: <azure-app-client-id> │                                │
  │ sub: AaBb11Cc-...          │                                │
  │ oid: AaBb11Cc-...          │                                │
  │ email: anudeep@corp.com    │                                │
  │ groups: [guid-1, guid-2]   │                                │
  │────────────────────────────>                                │
  │                            │ Validate JWT via JWKS           │
  │                            │ (login.microsoftonline.com)     │
  │                            │ POST /authz/litellm             │
  │                            │─────────────────────────────────>
  │                            │ allow/deny + audit (CEL)        │
  │                            │<─────────────────────────────────
  │                            │                                │
  │                            │ key ownership: oid == user_id?  │
  │                            │ (AaBb11Cc == AaBb11Cc → OK)     │
```

### Key differences from mock setup

| Aspect | Mock (current) | Azure AD (target) |
|--------|---------------|-------------------|
| JWKS endpoint | In-cluster nginx pod | `https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys` |
| Issuer | `http://mock-issuer` | `https://login.microsoftonline.com/{tenant}/v2.0` |
| Audience | `litellm-proxy` | Azure App Registration client ID (GUID) |
| `sub` claim | Friendly name (`user-c`) | Azure object ID (GUID like `AaBb11Cc-dDeE-...`) |
| `oid` claim | Not present | Azure object ID (same as `sub` for v2.0 tokens, always a GUID) |
| `groups` claim | Friendly names (`["team-c"]`) | Azure group object IDs (GUIDs like `["1a2b3c-..."]`) |
| `email` claim | `user-c@example.com` | Real email (`anudeep@corp.com`) |
| `preferred_username` | Not present | UPN (`anudeep@corp.com`) |
| `tid` claim | Not present | Tenant ID (GUID) |
| Token lifetime | 30 days (test) | ~1 hour (Azure default), refresh via OIDC flow |
| Signing keys | Single static RSA key | Rotating RSA keys (multiple kids) |
| Key rotation | Manual | Automatic (Microsoft rotates keys periodically) |

---

## Implementation Steps

### Step 1: Azure AD App Registration

Register an application in Azure AD (Entra ID) to represent the LiteLLM proxy.

**Azure Portal → Entra ID → App Registrations → New Registration:**

| Field | Value |
|-------|-------|
| Name | `litellm-proxy` |
| Supported account types | Single tenant (or multi-tenant if cross-org) |
| Redirect URI | `http://localhost:8000/callback` (for local dev token acquisition) |

**After registration, note down:**

| Value | Example | Where it goes |
|-------|---------|---------------|
| Application (client) ID | `a1b2c3d4-e5f6-7890-abcd-ef1234567890` | `JWT_AUDIENCE` in ConfigMap |
| Directory (tenant) ID | `f1e2d3c4-b5a6-7890-abcd-ef1234567890` | Used in `JWT_ISSUER` and `JWT_JWKS_URL` |
| Client secret (optional) | `~abc...` | Only needed if using client-credentials flow |

**Configure token claims:**

1. **Token configuration → Add groups claim:**
   - Select "Security groups" (or "All groups")
   - For ID tokens: check "Group ID"
   - For Access tokens: check "Group ID"

2. **Token configuration → Add optional claims:**
   - ID token: `email`, `preferred_username`
   - Access token: `email`, `preferred_username`

3. **API permissions:**
   - `User.Read` (default, for sign-in)
   - No additional Graph permissions needed unless handling group overage

4. **Expose an API → Set Application ID URI:**
   - `api://litellm-proxy` (or accept default `api://<client-id>`)

### Step 2: Create Azure AD Groups

Create groups that map to LiteLLM teams:

| Azure AD Group | Group Object ID (GUID) | Maps to LiteLLM team |
|----------------|----------------------|---------------------|
| `litellm-team-a` | `11111111-aaaa-bbbb-cccc-dddddddddddd` | team-a (gemini only) |
| `litellm-team-b` | `22222222-aaaa-bbbb-cccc-dddddddddddd` | team-b (claude only) |
| `litellm-team-c` | `33333333-aaaa-bbbb-cccc-dddddddddddd` | team-c (gemini + claude) |
| `litellm-team-d` | `44444444-aaaa-bbbb-cccc-dddddddddddd` | team-d (gemini + claude) |

Add users to groups:

| Azure AD User | UPN | Member of |
|---------------|-----|-----------|
| User A | `user-a@corp.com` | `litellm-team-a` |
| User B | `user-b@corp.com` | `litellm-team-b` |
| User C | `user-c@corp.com` | `litellm-team-c` |
| User D | `user-d@corp.com` | `litellm-team-d` |

### Step 3: Update Kubernetes ConfigMap (no code changes)

This is the only deployment change. No Docker image rebuild needed.

```bash
# Get your tenant ID and client ID from Azure Portal
TENANT_ID="f1e2d3c4-b5a6-7890-abcd-ef1234567890"
CLIENT_ID="a1b2c3d4-e5f6-7890-abcd-ef1234567890"

kubectl create configmap litellm-jwt-config \
  -n litellm \
  --from-literal=JWT_JWKS_URL="https://login.microsoftonline.com/${TENANT_ID}/discovery/v2.0/keys" \
  --from-literal=JWT_ISSUER="https://login.microsoftonline.com/${TENANT_ID}/v2.0" \
  --from-literal=JWT_AUDIENCE="${CLIENT_ID}" \
  --from-literal=JWT_HEADER_NAME="X-Identity-Token" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deploy/litellm -n litellm
```

**Why no code changes?** The current `custom_auth.py` reads `JWT_JWKS_URL`, `JWT_ISSUER`, `JWT_AUDIENCE` from environment variables. PyJWKClient handles multiple rotating keys and key rotation automatically.

### Step 4: Provision LiteLLM Teams and Keys Using Azure OIDs

When creating LiteLLM teams and virtual keys, use Azure object IDs (GUIDs) instead of friendly names.

**Create teams:**

```bash
# team-c (Azure group GUID as team alias, or as team_id)
curl -s -X POST "http://127.0.0.1:4000/team/new" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_alias": "litellm-team-c",
    "models": ["gemini-flash", "claude-sonnet-4-5"],
    "max_budget": 10
  }'
# Note the returned team_id (LiteLLM-generated UUID)
```

**Create virtual keys bound to Azure OIDs:**

```bash
# The user_id MUST match the Azure AD 'oid' (or 'sub') claim from the JWT.
# This is how key ownership binding works.
AZURE_OID_USER_C="AaBb11Cc-dDeE-fFgG-hHiI-jJkKlLmMnN"

curl -s -X POST "http://127.0.0.1:4000/key/generate" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"team_id\": \"<team-c-id>\",
    \"user_id\": \"${AZURE_OID_USER_C}\",
    \"models\": [\"gemini-flash\", \"claude-sonnet-4-5\"],
    \"duration\": \"30d\",
    \"key_alias\": \"user-c-azure\"
  }"
```

**Critical point:** The `user_id` in the key generation request must be the user's Azure `oid` (or `sub`) — the same value that appears in the JWT `sub` claim. This is the value `custom_auth.py` compares during the key ownership check.

### Step 5: custom_auth.py Changes (if needed)

**What works without changes:**

- `_validate_jwt()` — PyJWT + PyJWKClient handles Microsoft's JWKS (multiple rotating keys, RS256). Works as-is.
- `_get_key_owner()` — looks up `user_id` from LiteLLM's DB. Works as-is.
- Key ownership check (`jwt_sub != key_owner`) — works as-is, as long as `user_id` in the key matches the Azure `sub`/`oid`.

**What may need changes:**

#### 5a. Claim extraction (sub vs oid)

Azure v2.0 tokens: `sub` is a pairwise identifier (same user gets different `sub` per app). The `oid` claim is the stable object ID across all apps.

**Decision:** Use `oid` as the primary identity claim instead of `sub`.

```python
# Current (mock):
jwt_sub = claims.get("sub", "")

# Change to (Azure):
jwt_sub = claims.get("oid", claims.get("sub", ""))
```

This is a one-line change. If `oid` is present (Azure tokens), use it. Fall back to `sub` for backward compatibility with mock tokens.

#### 5b. Group claim format

Azure sends group GUIDs as a flat list of strings:
```json
"groups": ["11111111-aaaa-bbbb-cccc-dddddddddddd", "22222222-aaaa-bbbb-cccc-dddddddddddd"]
```

The current code already handles this:
```python
jwt_groups = claims.get("groups", [])
extra_headers["X-Jwt-Groups"] = ",".join(jwt_groups) if jwt_groups else ""
```

No change needed.

#### 5c. Group overage handling (optional, Phase 2)

If a user is in >200 groups, Azure omits the `groups` claim and includes an overage indicator:
```json
"_claim_names": {"groups": "src1"},
"_claim_sources": {"src1": {"endpoint": "https://graph.microsoft.com/..."}}
```

For Phase 2, `custom_auth.py` could detect overage and call Microsoft Graph. For now, this can be deferred — most users will be in fewer than 200 groups.

#### 5d. Full diff for custom_auth.py

```python
# Line 140 — change from:
jwt_sub = claims.get("sub", "")

# To:
jwt_sub = claims.get("oid", claims.get("sub", ""))
```

That's the only required code change. Everything else (JWKS URL, issuer, audience, header name) is already externalized to environment variables.

### Step 6: Token Acquisition (Client Side)

Clients need to obtain an Azure AD token and send it in the `X-Identity-Token` header alongside their LiteLLM virtual key.

#### Option A: Device code flow (CLI / developer testing)

```bash
# Using Azure CLI
az login
TOKEN=$(az account get-access-token \
  --resource "api://litellm-proxy" \
  --query accessToken -o tsv)

curl -X POST "http://127.0.0.1:4000/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_VIRTUAL_KEY" \
  -H "X-Identity-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"hello"}]}'
```

#### Option B: Client credentials flow (service-to-service)

```bash
TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "scope=api://litellm-proxy/.default" \
  -d "grant_type=client_credentials" \
  | jq -r '.access_token')
```

Note: Client credentials tokens have no `oid` or `groups` — they represent an application, not a user. Key ownership binding would need to be skipped or adapted for service identities. This is a Phase 2 consideration.

#### Option C: Authorization code flow (web app)

Standard OIDC redirect flow — the web app obtains tokens via the `/authorize` and `/token` endpoints.

#### Option D: MSAL Python SDK (programmatic)

```python
from msal import PublicClientApplication

app = PublicClientApplication(CLIENT_ID, authority=f"https://login.microsoftonline.com/{TENANT_ID}")
result = app.acquire_token_interactive(scopes=["api://litellm-proxy/.default"])
token = result["access_token"]
```

### Step 7: AI Governance Proxy policy (`values-authz.yml`)

When switching from mock JWT to Azure AD, keep **`governance-helm/values-authz.yml`** aligned with the same tenant and audience as LiteLLM’s `litellm-jwt-config`:

- **`identity.oidcProviders`** — `issuer`, JWKS URL, and `audience` must match `JWT_ISSUER` / `JWT_JWKS_URL` / `JWT_AUDIENCE`.
- **`litellmPolicies` / `litellmPolicy`** — CEL rules run in the proxy (e.g. require authenticated user, audit). Tighten or add rules for Azure group GUIDs if you need route- or model-level gates at the governance layer.

After edits: `helm upgrade` the governance release and `kubectl rollout restart deploy/ai-governance-proxy -n governance` if needed.

### Step 8: Docker Image Changes

**Minimal change.** If implementing the `oid` claim fallback (Step 5a), rebuild the image:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag anuddeeph/litellm-custom-auth:v10 \
  --push .
```

Update `values.yaml`:
```yaml
image:
  tag: "v10"
```

If NOT implementing the `oid` fallback (i.e., Azure v2.0 `sub` is acceptable as the identity), then no image rebuild is needed at all — only the ConfigMap update from Step 3.

---

## Migration Checklist

### Pre-migration (can be done while mock is still active)

- [ ] Register Azure AD app (`litellm-proxy`)
- [ ] Note down tenant ID and client ID
- [ ] Configure token claims (groups, email, preferred_username)
- [ ] Create Azure AD groups (`litellm-team-a` through `litellm-team-d`)
- [ ] Add test users to groups
- [ ] Verify token acquisition: `az login && az account get-access-token --resource api://litellm-proxy`
- [ ] Decode a sample Azure token (`jwt.io`) to verify claims: `oid`, `sub`, `groups`, `email`, `iss`, `aud`

### Migration (switchover)

- [ ] Update `custom_auth.py`: change `claims.get("sub")` to `claims.get("oid", claims.get("sub"))` (1-line change)
- [ ] Build and push v10 image (only if code changed)
- [ ] Update `litellm-jwt-config` ConfigMap with Azure JWKS URL, issuer, audience
- [ ] Update `values.yaml` image tag to v10 (only if code changed)
- [ ] Recreate LiteLLM teams using Azure group names/IDs
- [ ] Recreate virtual keys with `user_id` set to Azure `oid` (the GUID from the JWT)
- [ ] `kubectl rollout restart deploy/litellm -n litellm`

### Post-migration validation

- [ ] Test 1: Azure user-c token + user-c key → Allowed
- [ ] Test 2: Azure user-d token + user-c key → Denied (owner mismatch)
- [ ] Test 3: No token + virtual key → Denied (missing identity)
- [ ] Test 4: Master key, no token → Allowed (admin bypass)
- [ ] Test 5: Azure user-d token + user-d key → Allowed
- [ ] Test 6: Azure user-c token + user-d key → Denied (owner mismatch)
- [ ] Test 7: Expired/tampered token → Denied (invalid signature or expired)
- [ ] Test 8: UI login with master key → Allowed (no JWT needed)
- [ ] Test 9: UI tabs (management routes) → Allowed (no JWT needed)

### Cleanup (after validation)

- [ ] Delete mock JWKS deployment: `kubectl delete -f scripts/jwks-deployment.yaml`
- [ ] Delete mock JWKS ConfigMap: `kubectl delete configmap jwks-mock-data -n litellm`
- [ ] Revoke old virtual keys that used friendly-name `user_id` values

---

## What Changes vs What Stays the Same

| Component | Changes? | Details |
|-----------|----------|---------|
| `custom_auth.py` | **1-line change** (if not already) | `oid` claim fallback: `claims.get("oid", claims.get("sub"))` |
| `governance-helm/values-authz.yml` | **Update** | Azure `issuer` / audience / CEL policies; redeploy governance Helm release |
| `ai-governance-proxy` image | **Optional rebuild** | If you change proxy code; tag must match `proxy.image` in values |
| `Dockerfile` (LiteLLM) | **No change** | Same base image, same PyJWT install |
| `litellm-helm/values.yaml` | **Tag bump** | Only if custom_auth.py changes |
| `litellm-jwt-config` ConfigMap | **3 values change** | JWKS URL, issuer, audience → Azure endpoints |
| LiteLLM teams | **Recreate** | Use Azure group names/IDs |
| Virtual keys | **Recreate** | `user_id` must be Azure `oid` (GUID) |
| `test_jwt_identity.sh` | **Update** | Load Azure tokens instead of mock JWTs |

---

## Architecture Comparison

### Before (Mock)

```
generate_test_jwt.py → private.pem + jwks.json
                        ↓
                  jwks-mock (nginx pod) ← custom_auth.py fetches JWKS
                        ↓
                  Validate mock JWT
                        ↓
              sub: "user-c" == key.user_id: "user-c" → OK
```

### After (Azure AD)

```
User → az login → Azure AD → access_token (JWT signed by Microsoft)
                                ↓
                  login.microsoftonline.com/keys ← custom_auth.py fetches JWKS
                                ↓
                  Validate Azure JWT
                                ↓
              oid: "AaBb11Cc-..." == key.user_id: "AaBb11Cc-..." → OK
```

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Azure JWKS endpoint unreachable | Low | PyJWKClient caches keys; keys rotate infrequently (~every 24h). Add retry/timeout. |
| Token audience mismatch | Medium | Verify `aud` claim matches exactly. Azure may use `api://<client-id>` or just `<client-id>` depending on scope requested. Test both. |
| Group overage (>200 groups) | Low (Phase 2) | Defer to Phase 2. Log a warning when `_claim_names.groups` is present. |
| `sub` vs `oid` confusion | Medium | Always use `oid` for Azure. Document clearly that key `user_id` must be the Azure OID. |
| v1.0 vs v2.0 token endpoints | Medium | Use v2.0 exclusively. Issuer format differs between v1.0 (`sts.windows.net`) and v2.0 (`login.microsoftonline.com`). |
| Client credentials (no user context) | Low (Phase 2) | Service-to-service flows have no `oid`/`groups`. Needs separate handling if needed. |
| Existing mock keys become invalid | Expected | After ConfigMap switch, mock JWTs fail validation (wrong issuer/audience/signature). This is the desired behavior. |

---

## Timeline Estimate

| Step | Effort | Dependency |
|------|--------|------------|
| 1. Azure AD App Registration | 15 min | Azure Portal access |
| 2. Create groups + add users | 10 min | Azure Portal access |
| 3. Update ConfigMap | 5 min | Tenant ID + Client ID |
| 4. custom_auth.py 1-line change + rebuild | 15 min | Docker Buildx |
| 5. Recreate teams + keys with OIDs | 15 min | Azure tokens decoded |
| 6. Helm upgrade + rollout restart | 5 min | — |
| 7. Run test suite with Azure tokens | 15 min | Token acquisition working |
| 8. Cleanup mock resources | 5 min | — |
| **Total** | **~1.5 hours** | |

---

## Open Questions

1. **Single tenant or multi-tenant?** — Determines `supported_account_types` in App Registration and whether `tid` claim needs validation.
2. **Access token or ID token?** — For API calls, access tokens are standard. Ensure the audience scope is set correctly (`api://litellm-proxy/.default`).
3. **Service-to-service calls?** — If non-human clients (CI/CD, automation) need access, client-credentials flow tokens lack `oid`/`groups`. Need a policy decision: skip key ownership for app tokens, or require a different auth path.
4. **Group naming convention?** — Azure group display names (`litellm-team-c`) vs object IDs (GUIDs). The JWT only contains GUIDs. Teams need to be mapped by GUID, not display name.
5. **Token refresh strategy?** — Azure tokens expire in ~1 hour. Clients must implement token refresh. This is a client-side concern, not a server-side change.
