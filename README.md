# AI Auth — LiteLLM + Kyverno + Azure AD OIDC

A production-grade AI gateway that unifies multiple LLM providers behind a single OpenAI-compatible API, with four-layer authorization: Azure AD OIDC identity verification, Kyverno policy evaluation, custom JWT-to-key ownership binding, and LiteLLM virtual key management with spend tracking.

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
│  │     YES → Validate Azure JWT → Kyverno (+ claims) → key ownership    │  │
│  │     NO  → Kyverno (route check only) → LiteLLM DB auth              │  │
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
     │  Azure AD (JWKS)  │  │ Kyverno Authz    │  │ Azure AD (Entra) │
     │  login.microsoft  │  │ Server :9081     │  │ Users & Groups   │
     │  online.com/keys  │  │ nestedRequest    │  │                  │
     └──────────────────┘  └──────────────────┘  └──────────────────┘
```

### Four-Layer Authorization

| Layer | Component | Responsibility |
|-------|-----------|----------------|
| 1. Identity | Azure AD OIDC (PyJWT + JWKS) | Verify caller identity on inference routes via signed JWT. Validate signature, expiry, issuer (`login.microsoftonline.com`), audience (app registration). Extract `oid` as stable user identifier. |
| 2. Policy | Kyverno Authz Server | Coarse-grained authentication gate: reject unauthenticated requests. JWT claims forwarded as `X-Jwt-Sub`, `X-Jwt-Groups`, `X-Jwt-Email` for future claim-based rules. |
| 3. Ownership | custom_auth.py key binding | On inference routes, compare JWT `oid` claim against virtual key's `user_id`. Prevents cross-user key theft even when teams share model permissions. |
| 4. Access Control | LiteLLM Internal Auth | Token validity (DB lookup), model access, budget enforcement, team/user scoping, spend tracking. |

### Route Classification in custom_auth.py

| Route type | Examples | JWT required? | Key ownership check? | Kyverno check? |
|------------|----------|---------------|---------------------|----------------|
| Health | `/health/readiness`, `/healthz` | No (bypass) | No | No |
| Master key | Any route with master key | No (bypass) | No | No |
| Inference | `/v1/chat/completions`, `/v1/embeddings` | **Yes** | **Yes** | Yes (with JWT claims) |
| Management | `/key/*`, `/team/*`, `/user/*`, `/model/*` | No | No | Yes (token presence) |
| UI / SSO | `/ui/*`, `/sso/*`, `/login`, `/global/*`, `/config/*` | No | No | Yes (token presence) |

---

## Components

| Component | Replicas | Namespace | Purpose |
|-----------|----------|-----------|---------|
| LiteLLM Proxy | 3 | `litellm` | AI gateway + custom auth + JWT validation |
| PostgreSQL Primary | 1 | `litellm` | Keys, teams, spend storage |
| PostgreSQL Read Replicas | 2 | `litellm` | Read scaling |
| Redis Master | 1 | `litellm` | Cache + transaction buffer |
| Redis Replicas | 2 | `litellm` | Read scaling |
| Kyverno Authz Server | 1 | `kyverno` | Policy-based authorization |

---

## File Structure

```
AI-auth/
├── README.md                          # This file
├── INSTALLATION.md                    # Step-by-step installation guide
├── AZURE_OIDC_INTEGRATION_PLAN.md     # Azure AD OIDC migration plan
├── AUTHZ_LAYER_ARCHITECTURE.md        # Authorization layer design
├── Dockerfile                         # Multi-arch image: LiteLLM + PyJWT + custom_auth.py
├── custom_auth.py                     # JWT validation + Kyverno bridge + key ownership check
├── kyverno-validating-policy.yaml     # CEL-based authorization rules
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
   ├── Build raw HTTP/1.1 bytes with injected claims:
   │     Authorization: Bearer sk-C4AV...
   │     X-Jwt-Sub: 80fa6a56-cf00-4090-bbce-b6b3021cf1a7
   │     X-Jwt-Email: anudeep.nalla@nirmata.com
   │     X-Jwt-Groups: 1de73371-...,4454a15a-...
   └── POST raw bytes → Kyverno Authz Server :9081

3. Kyverno Authz Server:
   ├── Parses raw bytes via Go's httputil.ReadRequest
   ├── Evaluates ValidatingPolicy (CEL):
   │     ├── Has Bearer token? YES → Allowed
   │     └── (JWT claims available as headers for future rules)
   └── Returns 200

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
   ├── Build raw HTTP/1.1 bytes (no JWT claims injected)
   └── POST raw bytes → Kyverno Authz Server :9081

3. Kyverno: Has Bearer token? YES → Allowed (200)

4. custom_auth.py: skip key ownership check (not inference)

5. Return "sk-session..." → LiteLLM DB lookup → authorize
```

---

## Prerequisites

- Kubernetes cluster (tested on KIND and Docker Desktop)
- Helm 3
- Docker Buildx (for multi-arch image builds)
- Azure CLI (`az`) for Azure AD setup and token acquisition
- cert-manager installed in the cluster
- Kyverno ValidatingPolicy CRD installed
- `curl` and `jq` for testing

---

## Deployment

### 1. Install cert-manager and CRDs

```bash
helm install cert-manager \
  --namespace cert-manager --create-namespace \
  --wait \
  --repo https://charts.jetstack.io cert-manager \
  --set crds.enabled=true

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

kubectl apply \
  -f https://raw.githubusercontent.com/kyverno/kyverno/refs/heads/main/config/crds/policies.kyverno.io/policies.kyverno.io_validatingpolicies.yaml
```

### 2. Deploy Kyverno Authz Server

```bash
helm upgrade --install kyverno-authz-server \
  --namespace kyverno --create-namespace \
  --wait \
  --repo https://kyverno.github.io/kyverno-authz kyverno-authz-server \
  --values - <<'EOF'
config:
  type: http
  http:
    address: ":9081"
    nestedRequest: true
validatingWebhookConfiguration:
  certificates:
    certManager:
      issuerRef:
        group: cert-manager.io
        kind: ClusterIssuer
        name: selfsigned-issuer
EOF
```

### 3. Apply Kyverno Authorization Policy

```bash
kubectl apply -f kyverno-validating-policy.yaml
```

### 4. Create Kubernetes Secrets

```bash
kubectl create namespace litellm

# Environment secret — API keys and master key
kubectl create secret generic litellm-env-secret \
  -n litellm \
  --from-literal=PROXY_MASTER_KEY='sk-your-master-key-here' \
  --from-literal=LITELLM_MASTER_KEY='sk-your-master-key-here' \
  --from-literal=GEMINI_API_KEY='your-gemini-key' \
  --from-literal=ANTHROPIC_API_KEY='your-anthropic-key'

# Database credentials — used by LiteLLM to connect to PostgreSQL
# Must be labeled for Helm adoption (see Issue 22)
kubectl create secret generic litellm-dbcredentials \
  -n litellm \
  --from-literal=username=litellm \
  --from-literal=password=NoTaGrEaTpAsSwOrD
kubectl -n litellm label secret litellm-dbcredentials app.kubernetes.io/managed-by=Helm
kubectl -n litellm annotate secret litellm-dbcredentials \
  meta.helm.sh/release-name=litellm meta.helm.sh/release-namespace=litellm

# PostgreSQL internal secret — required by the Bitnami PostgreSQL subchart
# for primary authentication, postgres superuser, and replication (see Issue 22)
kubectl create secret generic litellm-postgresql \
  -n litellm \
  --from-literal=password='NoTaGrEaTpAsSwOrD' \
  --from-literal=postgres-password='NoTaGrEaTpAsSwOrD' \
  --from-literal=replication-password='NoTaGrEaTpAsSwOrD'
kubectl -n litellm label secret litellm-postgresql app.kubernetes.io/managed-by=Helm
kubectl -n litellm annotate secret litellm-postgresql \
  meta.helm.sh/release-name=litellm meta.helm.sh/release-namespace=litellm
```

> **Important notes:**
> - `LITELLM_MASTER_KEY` must be the same value as `PROXY_MASTER_KEY` — the UI login depends on it. See [Issue 17](#issue-17-ui-login-returns-invalid-credentials-litellm_master_key-missing).
> - Secrets created before `helm install` must have Helm ownership labels/annotations, otherwise Helm will refuse to adopt them with `invalid ownership metadata`. See [Issue 22](#issue-22-helm-cannot-adopt-pre-created-secrets).
> - The `litellm-postgresql` secret must exist before the PostgreSQL StatefulSet starts; without it, pods will fail with `MountVolume.SetUp failed for volume "postgresql-password"`. See [Issue 23](#issue-23-postgresql-secret-not-auto-created-by-bitnami-subchart).

### 5. Deploy Mock JWKS Endpoint (local testing only)

> Skip this step if using Azure AD OIDC in production. Go to [Step 5b](#5b-configure-jwt-for-azure-ad-oidc-production) instead.

```bash
pip install 'PyJWT[crypto]'
python scripts/generate_test_jwt.py

# Deploy the JWKS mock nginx + Service first (the Deployment yaml
# includes a ConfigMap with placeholder data — this is intentional)
kubectl apply -f scripts/jwks-deployment.yaml

# Now overwrite the placeholder ConfigMap with the real JWKS keys.
# IMPORTANT: This must come AFTER kubectl apply, because
# jwks-deployment.yaml contains a ConfigMap with "PLACEHOLDER" data
# that would overwrite the real keys if applied second. See Issue 24.
kubectl create configmap jwks-mock-data \
  -n litellm \
  --from-file=jwks.json=scripts/keys/jwks.json \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart the mock so nginx picks up the real JWKS
kubectl rollout restart deployment jwks-mock -n litellm

# JWT configuration for custom_auth.py (loaded as env vars)
kubectl create configmap litellm-jwt-config \
  -n litellm \
  --from-literal=JWT_JWKS_URL=http://jwks-mock.litellm.svc:8080/.well-known/jwks.json \
  --from-literal=JWT_ISSUER=http://mock-issuer \
  --from-literal=JWT_AUDIENCE=litellm-proxy \
  --from-literal=JWT_HEADER_NAME=X-Identity-Token
```

> **Verify the JWKS endpoint** is serving real keys (not "PLACEHOLDER") before proceeding:
> ```bash
> kubectl exec -n litellm deploy/jwks-mock -- cat /usr/share/nginx/html/.well-known/jwks.json
> ```
> You should see a JSON object with a `keys` array containing `kid: "mock-key-1"`. If you see `PLACEHOLDER`, the ordering was wrong — re-run the `kubectl create configmap ... --dry-run=client` command above. See [Issue 24](#issue-24-jwks-configmap-placeholder-overwrite).

### 5b. Configure JWT for Azure AD OIDC (production)

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

### 6. Build and Push Custom Image

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

### 7. Deploy LiteLLM

```bash
kubectl delete job litellm-migrations -n litellm --ignore-not-found
helm upgrade --install litellm ./litellm-helm \
  -f ./litellm-helm/values.yaml \
  -n litellm
```

### 8. Verify

```bash
kubectl get pods -n litellm
kubectl get pods -n kyverno
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
| `email` | `anudeep.nalla@nirmata.com` | Forwarded to Kyverno as `X-Jwt-Email` |
| `groups` | `["1de73371-...", "4454a15a-..."]` | Forwarded to Kyverno as `X-Jwt-Groups` (comma-separated GUIDs) |
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

**Fix:** Abandoned gRPC entirely. Switched to Kyverno HTTP mode with `nestedRequest: true`.

---

### Issue 8: Immutable Migration Job on Helm Upgrade

**Symptom:** `Job.batch "litellm-migrations" is invalid: spec.template: field is immutable`

**Fix:** Delete the old migration Job before upgrading: `kubectl delete job litellm-migrations -n litellm --ignore-not-found`

---

### Issue 9: Kyverno Policy — Wrong API Version

**Symptom:** `policies.kyverno.io/v1alpha1 ValidatingPolicy is deprecated`

**Fix:** Updated `apiVersion` from `v1alpha1` to `v1`.

---

### Issue 10: Kyverno Policy — Wrong Header Object Path (Envoy vs HTTP Mode)

**Symptom:** `undefined field 'request'` in CEL expression `object.attributes.request.http.headers`

**Root Cause:** Envoy mode uses `object.attributes.request.http.headers`. HTTP mode with `nestedRequest: true` uses a flat structure: `object.attributes.header`, `.path`, `.method`.

**Fix:** Changed all CEL expressions to use the HTTP mode object structure.

---

### Issue 11: Kyverno Policy — Header Value Type Mismatch

**Symptom:** `found no matching overload for 'orValue' applied to 'optional_type(list(string)).(string)'`

**Root Cause:** With `nestedRequest: true`, Go's `http.Header` is `map[string][]string`. The optional wraps `list(string)`, not `string`. Using `.orValue("")` (string default) fails against a list type.

**Fix:** `object.attributes.header[?"Authorization"].orValue([""])[0]` — default to an empty list, take the first element.

---

### Issue 12: Kyverno Policy — Header Key Casing

**Symptom:** Kyverno always returns "Missing or invalid Bearer token" despite the request containing `Authorization: Bearer sk-...`.

**Root Cause:** Go's `httputil.ReadRequest` canonicalizes header keys to title-case (`Authorization`). The policy looked for lowercase `authorization`.

**Diagnosis:** Deployed a debug policy outputting both cases: `lower_auth=none`, `title_auth=Bearer sk-test...`.

**Fix:** Changed `header[?"authorization"]` to `header[?"Authorization"]`.

---

### Issue 13: Raw HTTP Bytes — Escaped vs Real CRLF

**Symptom:** Kyverno could not parse headers from the raw HTTP bytes.

**Root Cause:** Used `\\r\\n` (escaped) in Python f-strings, producing literal backslash characters instead of real CRLF bytes (0x0D 0x0A).

**Fix:** Used `"\r\n".join(lines)` with real carriage-return/line-feed, encoded as `latin-1`.

---

### Issue 14: PostgreSQL Replication Password Missing

**Symptom:** `PASSWORDS ERROR: The secret "litellm-postgresql" does not contain the key "replication-password"`

**Fix:** Added `replicationPassword` to `values.yaml` under `postgresql.auth`.

---

### Issue 15: LiteLLM Strips Authorization Header Before Custom Auth

**Symptom:** After adding JWT validation (v8), Kyverno received `Authorization: Bearer` without the actual token value (`auth_len=6`). JWT claims (`X-Jwt-Sub`) forwarded correctly.

**Root Cause:** LiteLLM's middleware extracts the Bearer token from the `Authorization` header and passes it as the `api_key` parameter to `custom_auth.py`. The `request.headers["authorization"]` value is left as just `"Bearer"` (stripped of the actual token).

**Diagnosis:** Deployed a debug Kyverno policy that returned header values in the denial message: `auth_len=6` confirmed the token was stripped.

**Fix:** In `_build_raw_http_request`, skip the original `authorization` header from `request.headers` and explicitly inject a fresh one from the `api_key` parameter:

```python
lines.append(f"Authorization: Bearer {api_key}")
for key, value in request.headers.items():
    if key.lower() == "authorization":
        continue
    lines.append(f"{key}: {value}")
```

---

### Issue 16: JWT Required on All Routes Broke the Admin UI (v8 → v9)

**Symptom:** After logging into the UI (`/ui/?login=success`), every page showed `{"error":{"message":"Missing identity token in X-Identity-Token header"}}`. The UI was completely non-functional despite login succeeding.

**Root Cause:** In v8, `custom_auth.py` required a JWT (`X-Identity-Token` header) on **every** non-health, non-master-key request. After a UI login, LiteLLM generates an internal session key (not the master key) and uses it for all subsequent API calls. The UI does not send a JWT.

**Fix (v9):** Introduced an `INFERENCE_PREFIXES` tuple in `custom_auth.py` that lists inference routes. JWT validation and key ownership checks are enforced **only** on inference routes. Management and UI routes pass through to Kyverno (token presence check) and LiteLLM's internal DB auth without requiring a JWT:

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
    # skip JWT — Kyverno checks token presence, LiteLLM checks DB validity
    ...
```

---

### Issue 17: UI Login Returns "Invalid Credentials" (LITELLM_MASTER_KEY Missing)

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

### Issue 18: Kyverno Policy Default-Deny Blocked 50+ UI Internal Routes

**Symptom:** UI login succeeded but most tabs showed 403 errors on routes like `/global/spend/teams`, `/config/list`, `/v2/model/info`, and 50+ others.

**Root Cause:** The Kyverno policy had an explicit route allow-list that didn't cover the many internal API routes the UI calls.

**Fix:** Simplified the Kyverno policy from a route-level allow-list to an **authentication gate**:

```yaml
# Old approach (5 route-matching rules + default deny)
# → broke on every new UI route

# New approach (3 rules):
# 1. Allow health routes without auth
# 2. Deny requests without a Bearer token
# 3. Allow all authenticated requests
```

The rationale: Kyverno's role is **coarse-grained** — it only needs to reject unauthenticated requests. Fine-grained authorization (model access, budget, team scoping, JWT identity) is handled by `custom_auth.py` and LiteLLM's internal auth pipeline. The JWT claim variables (`jwt_sub`, `jwt_groups`, `jwt_email`) remain in the policy for future claim-based rules.

---

### Issue 19: Azure AD `sub` Claim is Pairwise (v9 → v10)

**Symptom:** Key ownership check failed because Azure's `sub` claim (`074UOXmkq51-sbWz17hOqNGO-...`) didn't match the `user_id` stored in LiteLLM (which was the Azure `oid` GUID).

**Root Cause:** Azure AD v2.0 tokens use a pairwise `sub` — the same user gets a different `sub` value for each application. The `oid` claim is the stable Azure object ID.

**Fix (v10):** Changed the claim extraction in `custom_auth.py` from `claims.get("sub")` to `claims.get("oid", claims.get("sub"))`. Falls back to `sub` for non-Azure IdPs.

---

### Issue 20: Azure CLI Service Principal Not Registered in Tenant

**Symptom:** `az account get-access-token --resource "api://..."` returned `AADSTS650057: Invalid resource`.

**Root Cause:** The Azure CLI's service principal (`04b07795-8ddb-461a-bbee-02f9e1bf7b46`) was not registered in the tenant, so it couldn't request tokens for the `litellm-proxy` app.

**Fix:** Created the Azure CLI service principal in the tenant and pre-authorized it:

```bash
az ad sp create --id "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}" \
  --body '{"api":{"preAuthorizedApplications":[{"appId":"04b07795-8ddb-461a-bbee-02f9e1bf7b46","delegatedPermissionIds":["e1f1a8b0-1234-5678-9abc-def012345678"]}]}}'
```

---

### Issue 21: Azure AD Consent Not Granted (AADSTS65001)

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

### Issue 22: Helm Cannot Adopt Pre-Created Secrets

**Symptom:** `helm upgrade --install` fails with:

```
Error: Unable to continue with install: Secret "litellm-dbcredentials" in namespace "litellm" exists
and cannot be imported into the current release: invalid ownership metadata;
label validation error: missing key "app.kubernetes.io/managed-by": must be set to "Helm"
```

**Root Cause:** Secrets created with `kubectl create secret` before `helm install` don't have Helm ownership labels. Helm refuses to manage resources it didn't create unless they carry the correct metadata.

**Fix:** Label and annotate any pre-created secrets before running Helm:

```bash
kubectl -n litellm label secret <SECRET_NAME> app.kubernetes.io/managed-by=Helm --overwrite
kubectl -n litellm annotate secret <SECRET_NAME> \
  meta.helm.sh/release-name=litellm meta.helm.sh/release-namespace=litellm --overwrite
```

This applies to `litellm-dbcredentials` and `litellm-postgresql`. The updated Step 4 in the deployment guide already includes these commands.

---

### Issue 23: PostgreSQL Secret Not Auto-Created by Bitnami Subchart

**Symptom:** PostgreSQL StatefulSet pods stuck in `ContainerCreating` with:

```
MountVolume.SetUp failed for volume "postgresql-password" : secret "litellm-postgresql" not found
```

**Root Cause:** The Bitnami PostgreSQL subchart expects a secret named `litellm-postgresql` with keys `password`, `postgres-password`, and `replication-password`. On fresh installs (especially with pre-created `litellm-dbcredentials`), the subchart may not auto-generate this secret, or the timing causes a race condition where the StatefulSet starts before the secret is created.

**Fix:** Pre-create the `litellm-postgresql` secret before `helm install`:

```bash
kubectl create secret generic litellm-postgresql \
  -n litellm \
  --from-literal=password='NoTaGrEaTpAsSwOrD' \
  --from-literal=postgres-password='NoTaGrEaTpAsSwOrD' \
  --from-literal=replication-password='NoTaGrEaTpAsSwOrD'
kubectl -n litellm label secret litellm-postgresql app.kubernetes.io/managed-by=Helm
kubectl -n litellm annotate secret litellm-postgresql \
  meta.helm.sh/release-name=litellm meta.helm.sh/release-namespace=litellm
```

The password values must match `postgresql.auth.password`, `postgresql.auth.postgres-password`, and `postgresql.auth.replicationPassword` in `values.yaml`.

---

### Issue 24: JWKS ConfigMap Placeholder Overwrite

**Symptom:** JWT validation fails with `Expecting value: line 1 column 1 (char 0)` (JSON parse error). All inference requests with valid JWTs return 401.

**Root Cause:** `scripts/jwks-deployment.yaml` contains a `ConfigMap` resource with `data.jwks.json: PLACEHOLDER`. If you run `kubectl apply -f scripts/jwks-deployment.yaml` **after** creating the real ConfigMap from `scripts/keys/jwks.json`, the PLACEHOLDER overwrites the real JWKS keys. The mock nginx endpoint then serves "PLACEHOLDER" instead of a valid JSON key set.

**Diagnosis:** Check the JWKS content from inside the cluster:

```bash
kubectl exec -n litellm deploy/litellm -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://jwks-mock.litellm.svc:8080/.well-known/jwks.json').read())"
```

If it prints `b'PLACEHOLDER\n'`, the ConfigMap was overwritten.

**Fix:** Always apply the deployment YAML first, then overwrite the ConfigMap with the real keys, and restart the mock:

```bash
kubectl apply -f scripts/jwks-deployment.yaml

kubectl create configmap jwks-mock-data \
  -n litellm \
  --from-file=jwks.json=scripts/keys/jwks.json \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment jwks-mock -n litellm
```

**Prevention:** The Step 5 instructions in this guide have been updated to use this ordering. Consider removing the ConfigMap from `jwks-deployment.yaml` entirely and managing it separately.

---

### Issue 25: PyJWKClient Caches Invalid JWKS (Stale Cache After Fix)

**Symptom:** After fixing the JWKS ConfigMap (Issue 24), JWT validation still fails with the same JSON parse error. The JWKS endpoint is confirmed to be serving valid keys, but LiteLLM pods continue to reject JWTs.

**Root Cause:** `custom_auth.py` initializes a global `PyJWKClient` singleton with `cache_keys=True`. Once it fetches the (invalid) JWKS response on the first request, the cached result persists for the lifetime of the process. Fixing the ConfigMap and restarting nginx doesn't help because the LiteLLM process still holds the old cached data.

**Fix:** Restart the LiteLLM deployment after fixing the JWKS endpoint:

```bash
kubectl rollout restart deployment litellm -n litellm
```

The new pods will initialize a fresh `PyJWKClient` and fetch the corrected JWKS on their first JWT validation request.

**Note:** `kubectl port-forward` sessions die when pods restart. Re-establish the port-forward after the rollout completes:

```bash
kubectl port-forward -n litellm svc/litellm 4000:4000
```

---

## Troubleshooting

### Port-forward dies after pod restarts

`kubectl port-forward` targets a specific pod. When pods restart (due to rollout, crash, or scaling), the port-forward silently breaks. Re-establish it:

```bash
kubectl port-forward -n litellm svc/litellm 4000:4000
```

### Anthropic API returns "credit balance is too low"

If Test 5 (claude-sonnet) returns HTTP 400 with `Your credit balance is too low to access the Anthropic API`, the auth layer is working correctly — the request passed all 4 auth checks and reached Anthropic. The issue is with the Anthropic account billing, not the infrastructure. Top up credits at [console.anthropic.com](https://console.anthropic.com).

### Verifying end-to-end connectivity from inside a LiteLLM pod

```bash
kubectl exec -n litellm deploy/litellm -- python3 -c "
import urllib.request, json

# 1. JWKS mock
resp = urllib.request.urlopen('http://jwks-mock.litellm.svc:8080/.well-known/jwks.json')
data = json.loads(resp.read())
print('JWKS:', len(data.get('keys',[])), 'keys, kid:', data['keys'][0]['kid'])

# 2. Kyverno authz server (expect 405 on GET — confirms it's reachable)
try:
    urllib.request.urlopen('http://kyverno-authz-server.kyverno.svc.cluster.local:9081')
except Exception as e:
    print('Kyverno:', e)  # HTTP 405 = reachable, POST-only
"
```

Expected output:
```
JWKS: 1 keys, kid: mock-key-1
Kyverno: HTTP Error 405: Method Not Allowed
```

### Checking LiteLLM custom_auth logs

```bash
kubectl logs -n litellm deploy/litellm --tail=50 | grep -i "auth\|jwt\|kyverno"
```

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
| v10 | Azure AD OIDC: use `oid` claim instead of `sub` for stable identity binding (fixes Issue 19) |
