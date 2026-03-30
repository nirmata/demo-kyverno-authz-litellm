# AI Auth — LiteLLM + AI Governance Proxy + Azure AD OIDC

A production-grade AI gateway that unifies multiple LLM providers behind a single OpenAI-compatible API, with four-layer authorization: Azure AD OIDC identity verification, **AI Governance Proxy** policy on `POST /authz/litellm` (CEL policies from `governance-helm/values-authz.yml`), custom JWT-to-key ownership binding in `custom_auth.py`, and LiteLLM virtual key management with spend tracking. This demo does **not** deploy cluster Kyverno or `kyverno-authz-server`.

---

## Architecture Overview

```
                    ┌──────────────────────────────────────┐
                    │          Client Application           │
                    │  Authorization: Bearer sk-...         │
                    │  X-Identity-Token: eyJhbG... (JWT)    │
                    └──────────────────┬───────────────────┘
                                       │
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  LiteLLM Proxy (3 replicas, image: anuddeeph/litellm-custom-auth:v10)       │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  custom_auth.py — JWT Identity Binding                                 │  │
│  │                                                                        │  │
│  │  1. Health probe? ──────────────────────────────► bypass (master key)  │  │
│  │  2. Master key?   ──────────────────────────────► bypass (no JWT)     │  │
│  │  3. Inference route?                                                   │  │
│  │     YES → Validate Azure JWT → POST /authz/litellm → key ownership  │  │
│  │     NO  → governance allow (or skip) → LiteLLM DB auth              │  │
│  │  4. Return api_key string for DB lookup                               │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  LiteLLM Internal Auth                                                       │
│  ├── Hash virtual key → PostgreSQL lookup                                    │
│  ├── Validate: model access, budget, team, expiry                            │
│  └── Route to provider                                                       │
│                                                                              │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐                     │
│  │  Gemini API   │   │ Anthropic API│   │  Ollama      │                     │
│  └──────────────┘   └──────────────┘   └──────────────┘                     │
│                                                                              │
│  PostgreSQL (1 primary + 2 read replicas) — keys, teams, spend               │
│  Redis (1 master + 2 replicas) — cache, transaction buffer                   │
└──────────────────────────────────────────────────────────────────────────────┘
                                       │
                 ┌─────────────────────┼──────────────────────┐
                 ▼                     ▼                      ▼
     ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
     │  Azure AD (JWKS)  │  │ AI Governance    │  │ Azure AD (Entra) │
     │  login.microsoft  │  │ Proxy :8081      │  │ Users & Groups   │
     │  online.com/keys  │  │ /authz/litellm   │  │                  │
     └──────────────────┘  └──────────────────┘  └──────────────────┘
```

### Four-Layer Authorization

| Layer | Component | Responsibility |
|-------|-----------|----------------|
| 1. Identity | Azure AD OIDC (PyJWT + JWKS) | Verify caller identity on inference routes via signed JWT. Validate signature, expiry, issuer (`login.microsoftonline.com`), audience (app registration). Extract `oid` as stable user identifier. |
| 2. Policy | AI Governance Proxy (`POST /authz/litellm`) | CEL policies in `governance-helm/values-authz.yml` (Kyverno-flavored CEL in-process). Audit and allow/deny before LiteLLM continues. |
| 3. Ownership | custom_auth.py key binding | On inference routes, compare JWT `oid` claim against virtual key's `user_id`. Prevents cross-user key theft even when teams share model permissions. |
| 4. Access Control | LiteLLM Internal Auth | Token validity (DB lookup), model access, budget enforcement, team/user scoping, spend tracking. |

### Route Classification in custom_auth.py

| Route type | Examples | JWT required? | Key ownership check? | Governance `/authz/litellm`? |
|------------|----------|---------------|---------------------|----------------|
| Health | `/health/readiness`, `/healthz` | No (bypass) | No | No |
| Master key | Any route with master key | No (bypass) | No | No |
| Inference | `/v1/chat/completions`, `/v1/embeddings` | **Yes** | **Yes** | Yes (policy + audit) |
| Management | `/key/*`, `/team/*`, `/user/*`, `/model/*` | No | No | Yes (per `custom_auth.py` + values) |
| UI / SSO | `/ui/*`, `/sso/*`, `/login`, `/global/*`, `/config/*` | No | No | Yes (per `custom_auth.py` + values) |

---

## Components

| Component | Replicas | Namespace | Purpose |
|-----------|----------|-----------|---------|
| LiteLLM Proxy | 3 | `litellm` | AI gateway + custom auth + JWT validation |
| PostgreSQL Primary | 1 | `litellm` | Keys, teams, spend storage |
| PostgreSQL Read Replicas | 2 | `litellm` | Read scaling |
| Redis Master | 1 | `litellm` | Cache + transaction buffer |
| Redis Replicas | 2 | `litellm` | Read scaling |
| AI Governance Proxy | 1 | `governance` | `POST /authz/litellm`, CEL policies, audit |

---

## File Structure

```
AI-auth/
├── README.md                          # This file
├── ARCHITECTURE.md                    # Mermaid diagrams + PNG exports under diagrams/
├── diagrams/                          # 01–05 .mmd + .png; 05 = full stack like governance-helm poster
├── INSTALLATION.md                    # Step-by-step installation guide
├── AZURE_OIDC_INTEGRATION_PLAN.md     # Azure AD OIDC migration plan
├── AUTHZ_LAYER_ARCHITECTURE.md        # Authorization layer design
├── Dockerfile                         # Multi-arch image: LiteLLM + PyJWT + custom_auth.py
├── custom_auth.py                     # JWT validation + governance proxy `/authz/litellm` + key ownership
├── governance-helm/                   # Helm chart for AI Governance Proxy
│   └── values-authz.yml               # Azure OIDC + CEL policies + image tag
├── litellm-helm/
│   ├── values.yaml                    # Helm chart configuration
│   └── ...                            # LiteLLM Helm chart templates
└── scripts/
    ├── generate_test_jwt.py           # Generate RSA keys + mock JWTs (local testing)
    ├── test_azure_oidc.sh             # Automated test suite — 18 tests, 3 Azure AD users
    ├── test_jwt_identity.sh           # Automated test suite — 7 tests, mock JWTs
    ├── jwks-deployment.yaml           # Kubernetes nginx deployment for mock JWKS
    └── keys/
        ├── private.pem                # RSA-2048 private key (test only)
        ├── jwks.json                  # JWKS public key set
        └── user-a.jwt ... user-d.jwt  # Signed mock JWTs per user
```

---

## Request Flow

### Inference Route (Azure AD OIDC + JWT Identity Binding)

```
1. Client sends:
     POST /v1/chat/completions
     Authorization: Bearer sk-C4AV...  (LiteLLM virtual key)
     X-Identity-Token: eyJ0eXAi...    (Azure AD JWT)

2. custom_auth.py:
   ├── Not a health route, not master key
   ├── Path matches INFERENCE_PREFIXES → JWT required
   ├── Extract JWT from X-Identity-Token header
   ├── Validate JWT via PyJWKClient:
   │     ├── Fetch JWKS from https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys
   │     ├── Verify RS256 signature with matching kid
   │     ├── Check exp (not expired)
   │     ├── Check iss (https://login.microsoftonline.com/{tenant}/v2.0)
   │     ├── Check aud (Azure app registration client ID)
   │     └── Extract claims:
   │           oid=80fa6a56-cf00-4090-bbce-b6b3021cf1a7
   │           email=anudeep.nalla@nirmata.com
   │           groups=[1de73371-..., ...]  (Azure AD group GUIDs)
   └── POST JSON → AI Governance Proxy `http://<governance>:8081/authz/litellm`
         (model, path, method, identity token; see `custom_auth.py`)

3. AI Governance Proxy:
   ├── Validates identity token for policy (CEL) per `values-authz.yml`
   ├── Returns `{ result: { allow, message } }` (and audit events when configured)
   └── Deny stops the request before LiteLLM provider routing

4. custom_auth.py — key ownership check:
   ├── GET /key/info?key=sk-C4AV... (internal loopback with master key)
   ├── Key owner: user_id=80fa6a56-cf00-4090-bbce-b6b3021cf1a7
   ├── JWT oid: 80fa6a56-cf00-4090-bbce-b6b3021cf1a7
   └── Match! Proceed

5. custom_auth.py returns "sk-C4AV..." string

6. LiteLLM Internal Auth:
   ├── SHA256("sk-C4AV...") → lookup in PostgreSQL
   ├── Key found, team=litellm-team-c, models=[gemini-flash, claude-sonnet-4-5]
   ├── Model "gemini-flash" allowed, budget not exceeded
   └── Forward to Gemini API (using real GEMINI_API_KEY from secret)

7. Response returned to client, spend recorded
```

### Management / UI Route (no JWT needed)

```
1. Browser / UI sends:
     GET /global/spend/teams
     Authorization: Bearer sk-session... (UI session key)

2. custom_auth.py:
   ├── Not a health route, not master key
   ├── Path does NOT match INFERENCE_PREFIXES → skip JWT
   └── Call governance `/authz/litellm` per current logic (non-inference paths)

3. Governance proxy returns allow/deny per CEL policies in `values-authz.yml`

4. custom_auth.py: skip key ownership check (not inference)

5. Return "sk-session..." → LiteLLM DB lookup → authorize
```

---

## Prerequisites

- Kubernetes cluster (tested on KIND and Docker Desktop)
- Helm 3
- Docker Buildx (for multi-arch image builds: LiteLLM custom image and optionally `ai-governance-proxy`)
- Azure CLI (`az`) for Azure AD setup and token acquisition
- `curl` and `jq` for testing

---

## Deployment

### 1. Build and push AI Governance Proxy (optional if using a prebuilt image)

From the **`ai-governance-proxy`** repository root:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t <your-registry>/ai-governance-proxy:<tag> \
  --push .
```

Set `proxy.image.repository` and `proxy.image.tag` in `governance-helm/values-authz.yml` to match.

### 2. Deploy AI Governance Proxy (Helm)

```bash
helm upgrade --install ai-governance \
  ./governance-helm \
  -f ./governance-helm/values-authz.yml \
  -n governance \
  --create-namespace
```

Service DNS: `http://ai-governance-proxy.governance.svc.cluster.local:8081` — base URL for `AI_GOVERNANCE_PROXY_URL` if you override defaults in `litellm-helm/values.yaml`.

### 3. Create Kubernetes Secrets

```bash
kubectl create namespace litellm

kubectl create secret generic litellm-env-secret \
  -n litellm \
  --from-literal=PROXY_MASTER_KEY='sk-your-master-key-here' \
  --from-literal=LITELLM_MASTER_KEY='sk-your-master-key-here' \
  --from-literal=GEMINI_API_KEY='your-gemini-key' \
  --from-literal=ANTHROPIC_API_KEY='your-anthropic-key'

kubectl create secret generic litellm-dbcredentials \
  -n litellm \
  --from-literal=username=litellm \
  --from-literal=password=NoTaGrEaTpAsSwOrD
```

> `LITELLM_MASTER_KEY` must be the same value as `PROXY_MASTER_KEY` — the UI login depends on it. See [Issue 13](#issue-13-ui-login-returns-invalid-credentials-litellm_master_key-missing).

### 4. Deploy Mock JWKS Endpoint (local testing only)

> Skip this step if using Azure AD OIDC in production. Go to [Step 4b](#4b-configure-jwt-for-azure-ad-oidc-production) instead.

```bash
pip install 'PyJWT[crypto]'
python scripts/generate_test_jwt.py

kubectl create configmap jwks-mock-data \
  -n litellm \
  --from-file=jwks.json=scripts/keys/jwks.json

kubectl apply -f scripts/jwks-deployment.yaml

kubectl create configmap litellm-jwt-config \
  -n litellm \
  --from-literal=JWT_JWKS_URL=http://jwks-mock.litellm.svc:8080/.well-known/jwks.json \
  --from-literal=JWT_ISSUER=http://mock-issuer \
  --from-literal=JWT_AUDIENCE=litellm-proxy \
  --from-literal=JWT_HEADER_NAME=X-Identity-Token
```

### 4b. Configure JWT for Azure AD OIDC (production)

```bash
TENANT_ID="3d95acd6-b6ee-428e-a7a0-196120fc3c65"
CLIENT_ID="1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe"

kubectl create configmap litellm-jwt-config \
  -n litellm \
  --from-literal=JWT_JWKS_URL="https://login.microsoftonline.com/${TENANT_ID}/discovery/v2.0/keys" \
  --from-literal=JWT_ISSUER="https://login.microsoftonline.com/${TENANT_ID}/v2.0" \
  --from-literal=JWT_AUDIENCE="${CLIENT_ID}" \
  --from-literal=JWT_HEADER_NAME=X-Identity-Token \
  --dry-run=client -o yaml | kubectl apply -f -
```

| Config Key | Mock (local) | Azure AD (production) |
|------------|-------------|----------------------|
| `JWT_JWKS_URL` | `http://jwks-mock.litellm.svc:8080/.well-known/jwks.json` | `https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys` |
| `JWT_ISSUER` | `http://mock-issuer` | `https://login.microsoftonline.com/{tenant}/v2.0` |
| `JWT_AUDIENCE` | `litellm-proxy` | Azure App Registration client ID (GUID) |
| `JWT_HEADER_NAME` | `X-Identity-Token` | `X-Identity-Token` |

### 5. Build and Push Custom LiteLLM Image

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag <your-registry>/litellm-custom-auth:v10 \
  --push .
```

The Dockerfile:

```dockerfile
FROM docker.litellm.ai/berriai/litellm-database:main-stable
RUN pip install --no-cache-dir "PyJWT[crypto]"
COPY custom_auth.py /etc/litellm/custom_auth.py
```

Update `litellm-helm/values.yaml` with your image repository and tag:

```yaml
image:
  repository: anuddeeph/litellm-custom-auth
  tag: "v10"
```

### 6. Deploy LiteLLM

```bash
kubectl delete job litellm-migrations -n litellm --ignore-not-found
helm upgrade --install litellm ./litellm-helm \
  -f ./litellm-helm/values.yaml \
  -n litellm
```

### 7. Verify

```bash
kubectl get pods -n litellm
kubectl get pods -n governance
kubectl port-forward -n litellm svc/litellm 4000:4000
```

Test the health endpoint (no auth required):

```bash
curl -s http://127.0.0.1:4000/health/readiness
```

Test with master key:

```bash
export PROXY_MASTER_KEY=$(kubectl get secret -n litellm litellm-env-secret \
  -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)

curl -s http://127.0.0.1:4000/model/info \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" | jq .
```

Verify Azure AD JWKS connectivity from inside the cluster:

```bash
kubectl exec -n litellm deploy/litellm -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('https://login.microsoftonline.com/common/discovery/v2.0/keys').read()[:200])"
```

---

## Azure AD OIDC Setup

### Azure App Registration

An Azure AD application (`litellm-proxy`) was registered in Entra ID to serve as the OIDC provider.

| Setting | Value |
|---------|-------|
| App name | `litellm-proxy` |
| Application (client) ID | `1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe` |
| Directory (tenant) ID | `3d95acd6-b6ee-428e-a7a0-196120fc3c65` |
| Application ID URI | `api://1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe` |
| Supported account types | Single tenant |
| Token version | v2.0 |
| Group membership claims | SecurityGroup |
| Optional claims (access token) | `email`, `preferred_username` |

**Steps performed:**

```bash
# 1. Create app registration
az ad app create --display-name "litellm-proxy" --sign-in-audience "AzureADMyOrg"

# 2. Set Application ID URI
az ad app update --id "$APP_ID" --identifier-uris "api://${APP_ID}"

# 3. Create service principal
az ad sp create --id "$APP_ID"

# 4. Set token version to v2.0
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}" \
  --body '{"api":{"requestedAccessTokenVersion":2}}'

# 5. Configure group claims + optional claims (email, preferred_username)
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}" \
  --body '{
    "groupMembershipClaims": "SecurityGroup",
    "optionalClaims": {
      "accessToken": [
        {"name":"email","essential":false},
        {"name":"preferred_username","essential":false}
      ]
    }
  }'

# 6. Add OAuth2 scope (access_as_user)
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}" \
  --body '{
    "api": {
      "oauth2PermissionScopes": [{
        "adminConsentDescription":"Allow access to LiteLLM proxy",
        "adminConsentDisplayName":"Access LiteLLM Proxy",
        "id":"e1f1a8b0-1234-5678-9abc-def012345678",
        "isEnabled":true,
        "type":"User",
        "value":"access_as_user"
      }]
    }
  }'

# 7. Pre-authorize Azure CLI for token acquisition
az ad sp create --id "04b07795-8ddb-461a-bbee-02f9e1bf7b46"  # Azure CLI SP
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}" \
  --body "{
    \"api\":{\"preAuthorizedApplications\":[{
      \"appId\":\"04b07795-8ddb-461a-bbee-02f9e1bf7b46\",
      \"delegatedPermissionIds\":[\"e1f1a8b0-1234-5678-9abc-def012345678\"]
    }]}
  }"
```

### Azure AD Groups

| Azure AD Group | Group Object ID | Maps to LiteLLM team | Models |
|----------------|-----------------|----------------------|--------|
| `litellm-team-a` | `3412b52e-e01e-48e6-9092-6ad4f9f65496` | team-a | gemini-flash only |
| `litellm-team-b` | `c7c1b22b-2635-4ad1-ab0e-0b0927e8c582` | team-b | claude-sonnet-4-5 only |
| `litellm-team-c` | `1de73371-f70e-4ea0-841d-386f873cc557` | team-c | gemini + claude |
| `litellm-team-d` | `9d7b89cf-1b56-4745-9d8e-279d2e5f59ee` | team-d | gemini + claude |

**Group creation:**

```bash
for team in team-a team-b team-c team-d; do
  az ad group create --display-name "litellm-${team}" --mail-nickname "litellm-${team}"
done
```

### Azure AD Users → Group Membership

| Azure AD User | Email | OID | Group |
|---------------|-------|-----|-------|
| Anudeep Nalla | anudeep.nalla@nirmata.com | `80fa6a56-cf00-4090-bbce-b6b3021cf1a7` | litellm-team-a, litellm-team-c |
| Sachin Agarwal | sachin.agarwal@nirmata.com | `91c0c55c-0c8a-49fb-85c9-acef4efb798f` | litellm-team-b |
| Rahul Kaushal | rahul.kaushal@nirmata.com | `8ca1dc25-e960-4c47-9843-b5b7f51a4315` | litellm-team-d |

```bash
az ad group member add --group "litellm-team-c" --member-id "80fa6a56-cf00-4090-bbce-b6b3021cf1a7"
az ad group member add --group "litellm-team-b" --member-id "91c0c55c-0c8a-49fb-85c9-acef4efb798f"
az ad group member add --group "litellm-team-d" --member-id "8ca1dc25-e960-4c47-9843-b5b7f51a4315"
```

### Azure AD JWT Claim Mapping

| Azure Claim | Example Value | Used by custom_auth.py as |
|-------------|---------------|---------------------------|
| `oid` | `80fa6a56-cf00-4090-bbce-b6b3021cf1a7` | `jwt_sub` — key ownership check (`oid == key.user_id`) |
| `sub` | `074UOXmkq51-sbWz17hOqNGO-...` | **Not used** — pairwise, different per app |
| `email` | `anudeep.nalla@nirmata.com` | Available in governance CEL / audit context |
| `groups` | `["1de73371-...", "4454a15a-..."]` | Azure AD group object IDs for policy / audit |
| `iss` | `https://login.microsoftonline.com/{tenant}/v2.0` | Validated by PyJWT |
| `aud` | `1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe` | Validated by PyJWT |
| `exp` | Unix timestamp | Validated by PyJWT (rejects expired tokens) |

**Why `oid` instead of `sub`?** Azure v2.0 tokens use a pairwise `sub` — the same user gets a different `sub` for each app. The `oid` is the stable Azure object ID across all applications.

### Token Acquisition

Each user acquires a JWT by authenticating with Azure AD:

```bash
az login --tenant "3d95acd6-b6ee-428e-a7a0-196120fc3c65" \
  --scope "api://1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe/.default"

AZURE_TOKEN=$(az account get-access-token \
  --resource "api://1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe" \
  --query 'accessToken' -o tsv)
```

Then calls LiteLLM with **two tokens**:

```bash
curl -X POST "http://127.0.0.1:4000/v1/chat/completions" \
  -H "Authorization: Bearer sk-C4AV66mv57C0hijV_uRxmQ" \
  -H "X-Identity-Token: $AZURE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"hello"}]}'
```

| Header | Token | Purpose |
|--------|-------|---------|
| `Authorization` | LiteLLM virtual key (`sk-...`) | Model access, budget, spend tracking |
| `X-Identity-Token` | Azure AD JWT (`eyJ...`) | Identity proof — who is the caller |

---

## Tested Scenarios (Mock JWT — Phase 1)

Initial validation using locally-generated RSA keys and a mock JWKS endpoint (nginx pod serving `jwks.json`). These tests confirmed the custom auth logic before integrating with Azure AD. Test script: `scripts/test_jwt_identity.sh`.

### Scenario A: Model-Based Team Isolation (Mock JWT)

Teams with different model permissions — isolation enforced by model restrictions on the key.

| Team | User | Models Allowed | Budget |
|------|------|---------------|--------|
| team-a | user-a | gemini-flash only | $10 |
| team-b | user-b | claude-sonnet-4-5 only | $10 |

| Test | Key | Model | Result |
|------|-----|-------|--------|
| user-a key → gemini | team-a | gemini-flash | **Allowed** |
| user-a key → claude | team-a | claude-sonnet-4-5 | **Denied** — "key not allowed to access model" |
| user-b key → claude | team-b | claude-sonnet-4-5 | **Allowed** |
| user-b key → gemini | team-b | gemini-flash | **Denied** — "key not allowed to access model" |

### Scenario B: Same Models, JWT Identity Isolation (Mock JWT)

Teams with identical model permissions — isolation enforced by JWT identity binding (`sub == key.user_id`).

| Team | User | Models Allowed | Budget |
|------|------|---------------|--------|
| team-c | user-c | gemini-flash, claude-sonnet-4-5 | $10 |
| team-d | user-d | gemini-flash, claude-sonnet-4-5 | $10 |

| # | Test | JWT | Key | Result |
|---|------|-----|-----|--------|
| 1 | user-c JWT + user-c key → gemini | user-c | user-c | **Allowed** — "jwt identity works" |
| 2 | user-d JWT + user-c key | user-d | user-c | **Denied** — "JWT sub 'user-d' does not match key owner 'user-c'" |
| 3 | No JWT + virtual key | none | user-c | **Denied** — "Missing identity token in X-Identity-Token header" |
| 4 | Master key, no JWT | admin | master | **Allowed** — admin bypass |
| 5 | user-d JWT + user-d key → claude | user-d | user-d | **Allowed** — "user-d claude ok" |
| 6 | user-c JWT + user-d key | user-c | user-d | **Denied** — "JWT sub 'user-c' does not match key owner 'user-d'" |
| 7 | Invalid/fake JWT + key | fake | user-c | **Denied** — "Unable to find a signing key" |

### Scenario C: UI / Management Access (Mock JWT — no JWT needed)

After the v9 fix, management and UI routes work with just a session key — no JWT required.

| # | Test | Result |
|---|------|--------|
| 8 | UI login (form POST /login with master key) | **Allowed** — returns session cookie with 303 redirect |
| 9 | UI session key → /user/info | **Allowed** — 200 OK |
| 10 | UI session key → /global/spend/teams | **Allowed** — 200 OK |
| 11 | UI session key → /v2/model/info | **Allowed** — 200 OK |
| 12 | UI session key → /config/list | **Allowed** — 200 OK |
| 13 | UI session key → /organization/list | **Allowed** — 200 OK |

### Running the mock JWT tests

```bash
export PROXY_MASTER_KEY=$(kubectl get secret -n litellm litellm-env-secret \
  -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)
export KEY_USER_C="sk-..."   # virtual key owned by user-c
export KEY_USER_D="sk-..."   # virtual key owned by user-d

bash scripts/test_jwt_identity.sh
```

---

## Tested Scenarios (Azure AD OIDC — 18 Tests)

All tests run with real Azure AD tokens from 3 users. Test script: `scripts/test_azure_oidc.sh`.

### All 18 Tests — Summary Table

| # | Scenario | Test | JWT user | Key / Key owner | Expected | Result |
|---|----------|------|----------|-----------------|----------|--------|
| A1 | A: Model isolation | Anudeep JWT + litellm-team-a key → gemini | Anudeep (OID `80fa6a56...`) | litellm-team-a / Anudeep | Allowed | **PASS** — 200, model responded |
| A2 | A: Model isolation | Anudeep JWT + litellm-team-a key → claude | Anudeep (OID `80fa6a56...`) | litellm-team-a / Anudeep | Denied | **PASS** — 401, "key not allowed to access model" |
| A3 | A: Model isolation | Sachin JWT + litellm-team-b key → claude | Sachin (OID `91c0c55c...`) | litellm-team-b / Sachin | Allowed | **PASS** — 200, model responded |
| A4 | A: Model isolation | Sachin JWT + litellm-team-b key → gemini | Sachin (OID `91c0c55c...`) | litellm-team-b / Sachin | Denied | **PASS** — 401, "key not allowed to access model" |
| A5 | A: Model isolation | Anudeep JWT + Sachin's litellm-team-b key | Anudeep (OID `80fa6a56...`) | litellm-team-b / Sachin | Denied | **PASS** — 403, "does not match key owner" |
| A6 | A: Model isolation | Sachin JWT + Anudeep's litellm-team-a key | Sachin (OID `91c0c55c...`) | litellm-team-a / Anudeep | Denied | **PASS** — 403, "does not match key owner" |
| B1 | B: JWT identity | Anudeep JWT + Anudeep litellm-team-c key → gemini | Anudeep (OID `80fa6a56...`) | litellm-team-c / Anudeep | Allowed | **PASS** — 200, model responded |
| B2 | B: JWT identity | Rahul JWT + Anudeep litellm-team-c key | Rahul (OID `8ca1dc25...`) | litellm-team-c / Anudeep | Denied | **PASS** — 403, "JWT sub '8ca1dc25...' does not match key owner '80fa6a56...'" |
| B3 | B: JWT identity | No JWT + Anudeep litellm-team-c key | none | litellm-team-c / Anudeep | Denied | **PASS** — 401, "Missing identity token in X-Identity-Token header" |
| B4 | B: JWT identity | Master key, no JWT | admin | master key | Allowed | **PASS** — 200, admin bypass |
| B5 | B: JWT identity | Rahul JWT + Rahul litellm-team-d key → claude | Rahul (OID `8ca1dc25...`) | litellm-team-d / Rahul | Allowed | **PASS** — 200, model responded |
| B6 | B: JWT identity | Anudeep JWT + Rahul litellm-team-d key | Anudeep (OID `80fa6a56...`) | litellm-team-d / Rahul | Denied | **PASS** — 403, "JWT sub '80fa6a56...' does not match key owner '8ca1dc25...'" |
| B7 | B: JWT identity | Fake JWT + Anudeep key | fake | litellm-team-c / Anudeep | Denied | **PASS** — 401, "Invalid identity token" |
| B8 | B: JWT identity | Old mock JWT (wrong issuer/kid) + Anudeep key | mock | litellm-team-c / Anudeep | Denied | **PASS** — 401, "Unable to find a signing key that matches: mock-key-1" |
| C1 | C: Management | GET /model/info with master key, no JWT | — | master key | Allowed | **PASS** — 200 OK |
| C2 | C: Management | GET /key/info with master key, no JWT | — | master key | Allowed | **PASS** — 200 OK |
| C3 | C: Management | GET /team/list with master key, no JWT | — | master key | Allowed | **PASS** — 200 OK |
| C4 | C: Management | GET /health/readiness (no auth at all) | — | — | Allowed | **PASS** — 200 OK |

### Scenario A: Model-Based Team Isolation (6 tests)

Teams with different model permissions — isolation enforced by model restrictions on the virtual key.

| Team | User | Azure AD OID | Models Allowed | Budget |
|------|------|-------------|---------------|--------|
| litellm-team-a | Anudeep Nalla | `80fa6a56-cf00-4090-bbce-b6b3021cf1a7` | gemini-flash only | $10 |
| litellm-team-b | Sachin Agarwal | `91c0c55c-0c8a-49fb-85c9-acef4efb798f` | claude-sonnet-4-5 only | $10 |

**What these tests prove:**
- **A1/A2**: Anudeep's litellm-team-a key allows gemini but blocks claude — LiteLLM model-level access control works.
- **A3/A4**: Sachin's litellm-team-b key allows claude but blocks gemini — model restrictions are per-key.
- **A5/A6**: Even if a user steals another user's key, `custom_auth.py` compares the JWT `oid` against the key's `user_id` and rejects the mismatch — cross-team key theft is prevented.

### Scenario B: Cross-Team Key Isolation via JWT Identity (8 tests)

Teams with **identical** model permissions — isolation enforced purely by JWT identity binding (`oid == key.user_id`).

| Team | User | Azure AD OID | Models Allowed | Budget |
|------|------|-------------|---------------|--------|
| litellm-team-c | Anudeep Nalla | `80fa6a56-cf00-4090-bbce-b6b3021cf1a7` | gemini + claude | $10 |
| litellm-team-d | Rahul Kaushal | `8ca1dc25-e960-4c47-9843-b5b7f51a4315` | gemini + claude | $10 |

**What these tests prove:**
- **B1/B5**: Users can use their own keys normally — identity match passes.
- **B2/B6**: Cross-user key theft is blocked even when both teams have the same model access. The JWT `oid` doesn't match the key's `user_id`, so `custom_auth.py` rejects it with 403.
- **B3**: Inference routes require a JWT — omitting `X-Identity-Token` returns 401.
- **B4**: Master key bypasses all checks — admin access is preserved.
- **B7**: A completely fake JWT fails signature verification against Azure AD's JWKS.
- **B8**: An old mock JWT (signed with `kid: mock-key-1` by the local RSA key) is rejected because Azure AD's JWKS has no matching signing key.

### Scenario C: Management & UI Routes (4 tests)

Management routes work with just a session key or master key — no JWT required.

**What these tests prove:**
- **C1/C2/C3**: Admin endpoints (`/model/info`, `/key/info`, `/team/list`) work with the master key and no JWT. `custom_auth.py` only enforces JWT on inference routes.
- **C4**: Health endpoints bypass all auth — kubelet probes work without any token.

### Running the test suite

```bash
export PROXY_MASTER_KEY=$(kubectl get secret -n litellm litellm-env-secret \
  -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)

# Each user acquires a fresh token (tokens expire after ~1 hour)
export TOKEN_ANUDEEP=$(az account get-access-token \
  --resource "api://1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe" --query accessToken -o tsv)
export TOKEN_SACHIN="eyJ..."   # from Sachin
export TOKEN_RAHUL="eyJ..."    # from Rahul

export KEY_ANUDEEP_A="sk-..."  KEY_SACHIN_B="sk-..."
export KEY_ANUDEEP_C="sk-..."  KEY_RAHUL_D="sk-..."

# Or use CREATE_KEYS=true to auto-create teams and keys
bash scripts/test_azure_oidc.sh
```

---

## Virtual Key Management

### Generate keys

```bash
curl -s -X POST "http://127.0.0.1:4000/key/generate" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id":"<team-id>",
    "user_id":"80fa6a56-cf00-4090-bbce-b6b3021cf1a7",
    "models":["gemini-flash","claude-sonnet-4-5"],
    "duration":"30d",
    "key_alias":"anudeep-azure-key"
  }'
```

The `user_id` **must** be the Azure AD `oid` (GUID) — this is the value `custom_auth.py` compares against the JWT's `oid` claim during the key ownership check.

### Check key info and spend

```bash
curl -s "http://127.0.0.1:4000/key/info?key=sk-..." \
  -H "Authorization: Bearer $PROXY_MASTER_KEY"
```

### Team management

```bash
curl -s -X POST "http://127.0.0.1:4000/team/new" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_alias":"litellm-team-c","models":["gemini-flash","claude-sonnet-4-5"],"max_budget":10}'
```

### Admin UI

Access at `http://127.0.0.1:4000/ui` — login with username `admin` and the master key as the password (form-encoded POST).

---

## Issues Encountered and Fixes

### Issue 1: PostgreSQL Connectivity in HA Mode

**Symptom:** LiteLLM pods crash with `P1001: Can't reach database server at litellm-postgresql:5432`

**Root Cause:** When PostgreSQL is deployed in `replication` mode, the Bitnami chart creates `litellm-postgresql-primary` as the service name, not `litellm-postgresql`. LiteLLM's templates hardcode `litellm-postgresql`.

**Fix:** Added an `ExternalName` Service in `values.yaml` under `extraResources` to alias `litellm-postgresql` to `litellm-postgresql-primary.litellm.svc.cluster.local`. No template modifications needed.

---

### Issue 2: Master Key Mismatch (401 on /key/generate)

**Symptom:** `Authentication Error, Invalid proxy server token passed` when calling `/key/generate`.

**Root Cause:** The Helm chart auto-generates a `litellm-masterkey` secret if not pinned. This created a different master key than the one in `litellm-env-secret`.

**Fix:** Pinned `masterkeySecretName: "litellm-env-secret"` and `masterkeySecretKey: "PROXY_MASTER_KEY"` in `values.yaml`.

---

### Issue 3: custom_auth.py Not Found (ImportError)

**Symptom:** `ImportError: Could not import user_api_key_auth from custom_auth`

**Root Cause:** `custom_auth.py` was copied to `/app/` (WORKDIR), but LiteLLM expects it at `/etc/litellm/`.

**Fix:** `COPY custom_auth.py /etc/litellm/custom_auth.py` in the Dockerfile.

---

### Issue 4: Health Probes Failing with Custom Auth (CrashLoopBackOff)

**Symptom:** `Only proxy admin can be used to generate, delete, update info for new keys/users/teams. Route=/health/readiness. Your role=unknown`

**Root Cause:** Kubernetes health probes hit `/health/readiness` without an `Authorization` header. Returning `UserAPIKeyAuth(user_role=PROXY_ADMIN)` did not propagate the role in OSS mode.

**Fix:** Return the `master_key` string for health routes. LiteLLM natively resolves the master key to `PROXY_ADMIN`.

---

### Issue 5: UserAPIKeyAuth Role Not Propagating (role=unknown)

**Symptom:** `/key/generate` returns `Your role=unknown` despite returning `UserAPIKeyAuth(user_role=PROXY_ADMIN)`.

**Root Cause:** In LiteLLM OSS mode, the `user_role` field from `UserAPIKeyAuth` does not propagate through internal post-auth checks.

**Fix:** Return the raw key string instead of `UserAPIKeyAuth`. LiteLLM's native auth pipeline correctly resolves roles from strings.

---

### Issue 6: custom_auth_settings mode: "auto" Requires Enterprise

**Symptom:** `mode: "auto"` caused unexpected behavior in OSS LiteLLM.

**Root Cause:** `mode: "auto"` is a LiteLLM Enterprise feature. OSS only supports `mode: "on"`.

**Fix:** Set `mode: "on"` and handle all auth paths inside `custom_auth.py`.

---

### Issue 7: gRPC Proto Compilation Failed in Docker Build

**Symptom:** `Could not make proto path relative: envoy/service/auth/v3/authorization.proto: No such file or directory`

**Root Cause:** Envoy `data-plane-api` repo restructured; transitive proto dependencies unresolvable.

**Fix:** Abandoned gRPC Envoy authz. The current design uses the **AI Governance Proxy** with `POST /authz/litellm` (HTTP JSON) instead of gRPC.

---

### Issue 8: Immutable Migration Job on Helm Upgrade

**Symptom:** `Job.batch "litellm-migrations" is invalid: spec.template: field is immutable`

**Fix:** Delete the old migration Job before upgrading: `kubectl delete job litellm-migrations -n litellm --ignore-not-found`

---

### Issue 9: Superseded — cluster Kyverno authz prototype

Older iterations used `kyverno-authz-server`, raw HTTP `nestedRequest`, and cluster `ValidatingPolicy` CEL (API version, header paths, CRLF encoding). **This demo does not use that path.** Policy is enforced in the **AI Governance Proxy** via `governance-helm/values-authz.yml` and `POST /authz/litellm`.

---

### Issue 10: PostgreSQL Replication Password Missing

**Symptom:** `PASSWORDS ERROR: The secret "litellm-postgresql" does not contain the key "replication-password"`

**Fix:** Added `replicationPassword` to `values.yaml` under `postgresql.auth`.

---

### Issue 11: LiteLLM `Authorization` header vs `api_key` parameter

**Symptom (historical):** Policy layers that re-read `Authorization` from `request.headers` sometimes saw only `Bearer` without the token — LiteLLM passes the virtual key as the `api_key` argument to `custom_auth`, not via the raw header.

**Fix:** `custom_auth.py` sends the virtual key to the governance proxy in the JSON body (`token` / `model` / `path` / …) using the `api_key` value from LiteLLM, not by reparsing a stripped header.

---

### Issue 12: JWT Required on All Routes Broke the Admin UI (v8 → v9)

**Symptom:** After logging into the UI (`/ui/?login=success`), every page showed `{"error":{"message":"Missing identity token in X-Identity-Token header"}}`. The UI was completely non-functional despite login succeeding.

**Root Cause:** In v8, `custom_auth.py` required a JWT (`X-Identity-Token` header) on **every** non-health, non-master-key request. After a UI login, LiteLLM generates an internal session key (not the master key) and uses it for all subsequent API calls. The UI does not send a JWT.

**Fix (v9):** Introduced an `INFERENCE_PREFIXES` tuple in `custom_auth.py` that lists inference routes. JWT validation and key ownership checks are enforced **only** on inference routes. Management and UI routes call the governance proxy without an identity JWT (per policy) and rely on LiteLLM DB auth for session keys:

```python
INFERENCE_PREFIXES = (
    "/v1/chat/completions", "/chat/completions",
    "/v1/completions", "/completions",
    "/v1/embeddings", "/embeddings",
    "/v1/images", "/v1/audio", "/v1/moderations",
)

is_inference = any(path.startswith(p) for p in INFERENCE_PREFIXES)

if is_inference:
    # validate JWT, extract claims, check key ownership
    ...
else:
    # skip JWT — governance route policy + LiteLLM DB validity
    ...
```

---

### Issue 13: UI Login Returns "Invalid Credentials" (LITELLM_MASTER_KEY Missing)

**Symptom:** POST to `/login` with `username=admin` and `password=<master-key>` returned `Invalid credentials used to access UI`.

**Root Cause:** LiteLLM's `/login` endpoint expects `LITELLM_MASTER_KEY` environment variable. The `litellm-env-secret` only contained `PROXY_MASTER_KEY`.

**Diagnosis:** Checked inside the pod: `LITELLM_MASTER_KEY=NOT SET`, `UI_USERNAME=NOT SET`, `UI_PASSWORD=NOT SET`. The login form expects `application/x-www-form-urlencoded` (not JSON).

**Fix:** Added `LITELLM_MASTER_KEY` to the `litellm-env-secret` with the same value as `PROXY_MASTER_KEY`:

```bash
kubectl patch secret litellm-env-secret -n litellm \
  --type='json' \
  -p='[{"op":"add","path":"/data/LITELLM_MASTER_KEY","value":"<base64-encoded-key>"}]'
```

---

### Issue 14: Governance CEL policies and UI routes

**Symptom:** UI tabs returned 403 if CEL rules in `values-authz.yml` were too strict for management routes (e.g. requiring `identity_token` everywhere).

**Fix:** Tune `litellmPolicies` / `litellmPolicy` so health and management/UI paths behave as intended — often inference routes require identity while session-key-backed UI calls do not. Validate with `helm upgrade` and proxy logs.

---

### Issue 15: Azure AD `sub` Claim is Pairwise (v9 → v10)

**Symptom:** Key ownership check failed because Azure's `sub` claim (`074UOXmkq51-sbWz17hOqNGO-...`) didn't match the `user_id` stored in LiteLLM (which was the Azure `oid` GUID).

**Root Cause:** Azure AD v2.0 tokens use a pairwise `sub` — the same user gets a different `sub` value for each application. The `oid` claim is the stable Azure object ID.

**Fix (v10):** Changed the claim extraction in `custom_auth.py` from `claims.get("sub")` to `claims.get("oid", claims.get("sub"))`. Falls back to `sub` for non-Azure IdPs.

---

### Issue 16: Azure CLI Service Principal Not Registered in Tenant

**Symptom:** `az account get-access-token --resource "api://..."` returned `AADSTS650057: Invalid resource`.

**Root Cause:** The Azure CLI's service principal (`04b07795-8ddb-461a-bbee-02f9e1bf7b46`) was not registered in the tenant, so it couldn't request tokens for the `litellm-proxy` app.

**Fix:** Created the Azure CLI service principal in the tenant and pre-authorized it:

```bash
az ad sp create --id "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}" \
  --body '{"api":{"preAuthorizedApplications":[{"appId":"04b07795-8ddb-461a-bbee-02f9e1bf7b46","delegatedPermissionIds":["e1f1a8b0-1234-5678-9abc-def012345678"]}]}}'
```

---

### Issue 17: Azure AD Consent Not Granted (AADSTS65001)

**Symptom:** `az account get-access-token --resource "api://..."` returned `AADSTS65001: The user or administrator has not consented to use the application`.

**Root Cause:** The Azure CLI had cached tokens from a previous session that did not include consent for the `litellm-proxy` app's `access_as_user` scope.

**Fix:** Clear the cached session and re-login with an explicit scope to trigger the consent prompt in the browser:

```bash
az logout
az login --tenant "3d95acd6-b6ee-428e-a7a0-196120fc3c65" \
  --scope "api://1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe/.default"
```

The browser consent prompt appears once. After granting consent, subsequent `az account get-access-token` calls work without user interaction.

---

## Image Versions

| Tag | Changes |
|-----|---------|
| v1 | Initial custom_auth.py with basic structure |
| v2 | Attempted gRPC proto compilation (failed) |
| v3 | Switched to HTTP mode, initial nestedRequest implementation |
| v4 | Fixed health probe handling (return master_key string) |
| v5 | Fixed role propagation (return key strings, not UserAPIKeyAuth) |
| v6 | Stabilized custom_auth_settings mode: "on" |
| v7 | Fixed CRLF encoding in raw HTTP bytes |
| v8 | Phase 1: JWT identity binding (PyJWT + JWKS + key ownership check + Authorization header reconstruction) |
| v9 | Scoped JWT to inference routes only; UI/management routes pass through without JWT (fixes Issues 16-18) |
| v10 | Azure AD OIDC: use `oid` claim instead of `sub` for stable identity binding (fixes Issue 15) |
