# AI Auth — LiteLLM + Kyverno + JWT Identity Binding

A production-grade AI gateway that unifies multiple LLM providers behind a single OpenAI-compatible API, with three-layer authorization: Kyverno policy evaluation, LiteLLM virtual key management, and JWT identity binding to prevent cross-user key theft.

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
│  LiteLLM Proxy (3 replicas, image: anuddeeph/litellm-custom-auth:v8)        │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  custom_auth.py (Phase 1: JWT Identity Binding)                        │  │
│  │                                                                        │  │
│  │  1. Health probe? ──────────────────────────────► bypass (master key)  │  │
│  │  2. Master key?   ──────────────────────────────► bypass (no JWT)     │  │
│  │  3. Validate JWT (sig, exp, iss, aud) ──────────► 401 if invalid     │  │
│  │  4. Forward to Kyverno (+ X-Jwt-Sub header) ───► 403 if denied      │  │
│  │  5. Key ownership: JWT.sub == key.user_id? ─────► 403 if mismatch   │  │
│  │  6. Return api_key string for DB lookup                               │  │
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
```

### Three-Layer Authorization

| Layer | Component | Responsibility |
|-------|-----------|----------------|
| Identity | JWT validation (PyJWT + JWKS) | Verify caller identity. Reject expired/invalid/missing tokens. |
| Policy | Kyverno Authz Server | Route access, token presence, method checks. JWT claims available as `X-Jwt-Sub`, `X-Jwt-Groups` for future claim-based rules. |
| Access Control | LiteLLM Internal Auth | Token validity (DB lookup), model access, budget enforcement, team/user scoping, spend tracking. |

In addition, `custom_auth.py` performs a **key ownership check**: the JWT `sub` claim must match the virtual key's `user_id`. This prevents cross-user key theft even when teams share the same model permissions.

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
| JWKS Mock | 1 | `litellm` | Serves RSA public key for JWT validation (local testing) |

---

## File Structure

```
AI-auth/
├── README.md                          # This file
├── AUTHZ_LAYER_ARCHITECTURE.md        # Azure AD OIDC integration design
├── Dockerfile                         # Multi-arch image: LiteLLM + PyJWT + custom_auth.py
├── custom_auth.py                     # JWT validation + Kyverno bridge + key ownership check
├── kyverno-validating-policy.yaml     # CEL-based authorization rules (with JWT claim variables)
├── litellm-helm/
│   ├── values.yaml                    # Helm chart configuration
│   └── ...                            # LiteLLM Helm chart templates
└── scripts/
    ├── generate_test_jwt.py           # Generate RSA keys + test JWTs for local testing
    ├── jwks-deployment.yaml           # Kubernetes nginx deployment serving JWKS
    └── keys/
        ├── private.pem                # RSA-2048 private key (test only)
        ├── jwks.json                  # JWKS public key set
        ├── user-a.jwt ... user-d.jwt  # Signed test JWTs per user
```

---

## Request Flow (with JWT Identity Binding)

```
1. Client sends:
     POST /v1/chat/completions
     Authorization: Bearer sk-nhpi... (virtual key)
     X-Identity-Token: eyJhbG...     (JWT signed by mock issuer / Azure AD)

2. custom_auth.py:
   ├── Not a health route, not master key
   ├── Extract JWT from X-Identity-Token header
   ├── Validate JWT via PyJWKClient:
   │     ├── Fetch JWKS from http://jwks-mock:8080/.well-known/jwks.json
   │     ├── Verify RS256 signature with matching kid
   │     ├── Check exp (not expired), iss (mock-issuer), aud (litellm-proxy)
   │     └── Extract claims: sub=user-c, groups=[team-c], email=user-c@example.com
   ├── Build raw HTTP/1.1 bytes with injected claims:
   │     Authorization: Bearer sk-nhpi...
   │     X-Jwt-Sub: user-c
   │     X-Jwt-Email: user-c@example.com
   │     X-Jwt-Groups: team-c
   └── POST raw bytes → Kyverno Authz Server :9081

3. Kyverno Authz Server:
   ├── Parses raw bytes via Go's httputil.ReadRequest
   ├── Evaluates ValidatingPolicy (CEL):
   │     ├── Has Bearer token? YES
   │     ├── POST /v1/chat/completions? YES
   │     └── → http.Allowed()
   └── Returns 200

4. custom_auth.py — key ownership check:
   ├── GET /key/info?key=sk-nhpi... (internal loopback)
   ├── Key owner: user_id=user-c
   ├── JWT sub: user-c
   └── Match! Proceed

5. custom_auth.py returns "sk-nhpi..." string

6. LiteLLM Internal Auth:
   ├── SHA256("sk-nhpi...") → lookup in PostgreSQL
   ├── Key found, team=team-c, models=[gemini-flash, claude-sonnet-4-5]
   ├── Model "gemini-flash" allowed, budget not exceeded
   └── Forward to Gemini API (using real GEMINI_API_KEY)

7. Response returned to client, spend recorded
```

---

## Prerequisites

- Kubernetes cluster (tested on Docker Desktop)
- Helm 3
- Docker Buildx (for multi-arch image builds)
- cert-manager installed in the cluster
- Kyverno ValidatingPolicy CRD installed

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

kubectl create secret generic litellm-env-secret \
  -n litellm \
  --from-literal=PROXY_MASTER_KEY='sk-your-master-key-here' \
  --from-literal=GEMINI_API_KEY='your-gemini-key' \
  --from-literal=ANTHROPIC_API_KEY='your-anthropic-key'

kubectl create secret generic litellm-dbcredentials \
  -n litellm \
  --from-literal=username=litellm \
  --from-literal=password=NoTaGrEaTpAsSwOrD
```

### 5. Deploy Mock JWKS Endpoint (local testing)

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

### 6. Build and Push Custom Image

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag <your-registry>/litellm-custom-auth:v8 \
  --push .
```

Update `litellm-helm/values.yaml` with your image repository and tag.

### 7. Deploy LiteLLM

```bash
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

---

## Tested Scenarios

### Scenario A: Model-Based Team Isolation

Teams with different model permissions — isolation enforced by model restrictions on the key.

| Team | User | Models Allowed | Budget |
|------|------|---------------|--------|
| team-a | user-a | gemini-flash only | $10 |
| team-b | user-b | claude-sonnet-4-5 only | $10 |

**Test results:**

| Test | Key | Model | Result |
|------|-----|-------|--------|
| user-a key → gemini | team-a | gemini-flash | **Allowed** |
| user-a key → claude | team-a | claude-sonnet-4-5 | **Denied** — "key not allowed to access model" |
| user-b key → claude | team-b | claude-sonnet-4-5 | **Allowed** |
| user-b key → gemini | team-b | gemini-flash | **Denied** — "key not allowed to access model" |

### Scenario B: Same Models, JWT Identity Isolation

Teams with identical model permissions — isolation enforced by JWT identity binding.

| Team | User | Models Allowed | Budget |
|------|------|---------------|--------|
| team-c | user-c | gemini-flash, claude-sonnet-4-5 | $10 |
| team-d | user-d | gemini-flash, claude-sonnet-4-5 | $10 |

**Test results (Phase 1 — JWT required):**

| Test | JWT | Key | Result |
|------|-----|-----|--------|
| user-c JWT + user-c key | user-c | user-c | **Allowed** — "jwt identity works" |
| user-d JWT + user-d key | user-d | user-d | **Allowed** — "user-d claude ok" |
| user-d JWT + user-c key | user-d | user-c | **Denied** — "JWT sub 'user-d' does not match key owner 'user-c'" |
| user-c JWT + user-d key | user-c | user-d | **Denied** — "JWT sub 'user-c' does not match key owner 'user-d'" |
| No JWT + virtual key | none | user-c | **Denied** — "Missing identity token in X-Identity-Token header" |
| Invalid JWT + key | fake | user-c | **Denied** — "Unable to find a signing key" |
| Master key, no JWT | admin | master | **Allowed** — admin bypass |

### How to reproduce the tests

```bash
export PROXY_MASTER_KEY=$(kubectl get secret -n litellm litellm-env-secret \
  -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)
export JWT_C=$(cat scripts/keys/user-c.jwt)
export JWT_D=$(cat scripts/keys/user-d.jwt)

# user-c JWT + user-c key → should work
curl -s -X POST "http://127.0.0.1:4000/v1/chat/completions" \
  -H "Authorization: Bearer <user-c-key>" \
  -H "X-Identity-Token: $JWT_C" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"test"}]}'

# user-d JWT + user-c key → should be denied (owner mismatch)
curl -s -X POST "http://127.0.0.1:4000/v1/chat/completions" \
  -H "Authorization: Bearer <user-c-key>" \
  -H "X-Identity-Token: $JWT_D" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"test"}]}'
```

---

## Virtual Key Management

### Generate keys

```bash
# Team-scoped key (team restricts which models are allowed)
curl -s -X POST "http://127.0.0.1:4000/key/generate" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_id":"<team-id>","user_id":"user-c","models":["gemini-flash","claude-sonnet-4-5"],"duration":"30d","key_alias":"user-c-key"}'
```

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
  -d '{"team_alias":"team-c","models":["gemini-flash","claude-sonnet-4-5"],"max_budget":10}'

curl -s -X POST "http://127.0.0.1:4000/team/member_add" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_id":"<team-id>","member":{"user_id":"user-c","role":"user"}}'
```

### Admin UI

Access at `http://127.0.0.1:4000/ui` — login with the master key as the password.

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

**Root Cause:** Envoy mode uses `object.attributes.request.http.headers`. HTTP mode uses flat `object.attributes.header`, `.path`, `.method`.

**Fix:** Changed all CEL expressions to use the HTTP mode object structure.

---

### Issue 11: Kyverno Policy — Header Value Type Mismatch

**Symptom:** `found no matching overload for 'orValue' applied to 'optional_type(list(string)).(string)'`

**Root Cause:** With `nestedRequest: true`, headers are `map[string][]string`. The optional wraps `list(string)`, not `string`.

**Fix:** `object.attributes.header[?"Authorization"].orValue([""])[0]` — default to empty list, take first element.

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

**Symptom:** After adding JWT validation (v8), Kyverno received `Authorization: Bearer` without the actual token (auth_len=6). JWT claims (X-Jwt-Sub) forwarded correctly.

**Root Cause:** LiteLLM's middleware extracts the Bearer token from the `Authorization` header and passes it as the `api_key` parameter. The `request.headers["authorization"]` value is left as just `"Bearer"` (stripped of the actual token).

**Diagnosis:** Deployed a debug Kyverno policy that returned header values: `auth_len=6` confirmed the token was missing.

**Fix:** In `_build_raw_http_request`, skip the original `authorization` header and explicitly inject a fresh one from the `api_key` parameter:

```python
lines.append(f"Authorization: Bearer {api_key}")
for key, value in request.headers.items():
    if key.lower() == "authorization":
        continue
    lines.append(f"{key}: {value}")
```

---

## Swap to Azure AD (Production)

Replace the mock JWKS with Azure AD by changing three env vars in the `litellm-jwt-config` ConfigMap. No code changes needed:

```bash
kubectl create configmap litellm-jwt-config \
  -n litellm \
  --from-literal=JWT_JWKS_URL=https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys \
  --from-literal=JWT_ISSUER=https://login.microsoftonline.com/{tenant}/v2.0 \
  --from-literal=JWT_AUDIENCE=<azure-app-client-id> \
  --from-literal=JWT_HEADER_NAME=X-Identity-Token \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deploy/litellm -n litellm
```

See [AUTHZ_LAYER_ARCHITECTURE.md](./AUTHZ_LAYER_ARCHITECTURE.md) for the full Azure AD OIDC integration design.

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
