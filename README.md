# AI Auth — LiteLLM + Kyverno Authorization Layer

A production-grade AI gateway that unifies multiple LLM providers behind a single OpenAI-compatible API, with policy-based authorization powered by Kyverno and virtual key management via LiteLLM.

---

## Architecture Overview

```
                         ┌──────────────────────────────────┐
                         │         Client Application       │
                         │   Authorization: Bearer sk-...   │
                         └───────────────┬──────────────────┘
                                         │
                                         ▼
┌────────────────────────────────────────────────────────────────────────────┐
│  LiteLLM Proxy (3 replicas)                                               │
│                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  custom_auth.py                                                      │  │
│  │                                                                      │  │
│  │  1. Health probe? ──────────────────────────► bypass (return master) │  │
│  │  2. Master key?   ──────────────────────────► bypass (return master) │  │
│  │  3. Other requests ──► Kyverno Authz Server ──► 200? proceed        │  │
│  │                                               └──► 403? deny        │  │
│  │  4. Return api_key string for DB lookup                              │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                            │
│  LiteLLM Internal Auth                                                     │
│  ├── Hash virtual key → PostgreSQL lookup                                  │
│  ├── Validate: model access, budget, team, expiry                          │
│  └── Route to provider                                                     │
│                                                                            │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐                   │
│  │  Gemini API   │   │ Anthropic API│   │  Ollama      │                   │
│  └──────────────┘   └──────────────┘   └──────────────┘                   │
│                                                                            │
│  PostgreSQL (1 primary + 2 read replicas) — keys, teams, spend             │
│  Redis (1 master + 2 replicas) — cache, transaction buffer                 │
└────────────────────────────────────────────────────────────────────────────┘
```

### Two-Layer Authorization

| Layer | Component | Responsibility |
|-------|-----------|----------------|
| Coarse-grained | Kyverno Authz Server | Route access, token presence, method checks. Does NOT validate the token itself. |
| Fine-grained | LiteLLM Internal Auth | Token validity (DB lookup), model access, budget enforcement, team/user scoping, spend tracking. |

---

## Components

| Component | Replicas | Namespace | Purpose |
|-----------|----------|-----------|---------|
| LiteLLM Proxy | 3 | `litellm` | AI gateway + custom auth |
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
├── AUTHZ_LAYER_ARCHITECTURE.md        # Future state: Azure AD OIDC integration design
├── Dockerfile                         # Multi-arch image with custom_auth.py
├── custom_auth.py                     # LiteLLM custom auth handler → Kyverno bridge
├── kyverno-validating-policy.yaml     # CEL-based authorization rules
└── litellm-helm/
    ├── values.yaml                    # Helm chart configuration
    └── ...                            # LiteLLM Helm chart templates
```

### Key Files

**`custom_auth.py`** — Replaces LiteLLM's built-in auth. On every request:
1. Bypasses auth for health probes and master key
2. Reconstructs the original HTTP request as raw bytes
3. POSTs raw bytes to Kyverno Authz Server (`nestedRequest: true` mode)
4. If Kyverno allows (200) → returns the API key string for LiteLLM DB lookup
5. If Kyverno denies (non-200) → raises `ProxyException` (403)
6. If Kyverno is unreachable → gracefully falls through to LiteLLM's DB-based auth

**`kyverno-validating-policy.yaml`** — CEL rules evaluated in order:
1. Allow health routes without auth
2. Deny requests missing a Bearer token
3. Allow POST to `/v1/chat/completions` and `/chat/completions`
4. Allow key/team/user/model management routes
5. Allow UI and model listing
6. Default deny everything else

**`Dockerfile`** — Minimal: base LiteLLM database image + custom_auth.py copied to `/etc/litellm/`.

**`litellm-helm/values.yaml`** — Configures the entire stack: model list, HA replicas, Redis/PostgreSQL replication, secret references, custom auth settings.

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

### 5. Build and Push Custom Image

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag <your-registry>/litellm-custom-auth:v7 \
  --push .
```

Update `litellm-helm/values.yaml` with your image repository and tag.

### 6. Deploy LiteLLM

```bash
helm upgrade --install litellm ./litellm-helm \
  -f ./litellm-helm/values.yaml \
  -n litellm
```

### 7. Verify

```bash
# Check all pods
kubectl get pods -n litellm
kubectl get pods -n kyverno

# Port-forward LiteLLM
kubectl port-forward -n litellm svc/litellm 4000:4000

# Generate a virtual key
curl -s -X POST "http://127.0.0.1:4000/key/generate" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models":["gemini-flash","claude-sonnet-4-5"],"duration":"1d","key_alias":"test-key"}'

# Test with virtual key (goes through Kyverno)
curl -s -X POST "http://127.0.0.1:4000/v1/chat/completions" \
  -H "Authorization: Bearer <virtual-key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-flash","messages":[{"role":"user","content":"Reply with: kyverno works"}]}'
```

---

## Request Flow

```
1. Client sends: POST /v1/chat/completions, Authorization: Bearer sk-mqx2...

2. custom_auth.py:
   ├── Not a health route
   ├── Not the master key
   ├── Build raw HTTP/1.1 bytes:
   │     POST /v1/chat/completions HTTP/1.1\r\n
   │     authorization: Bearer sk-mqx2...\r\n
   │     content-type: application/json\r\n
   │     \r\n
   │     {"model":"gemini-flash",...}
   └── POST raw bytes → Kyverno Authz Server :9081

3. Kyverno Authz Server:
   ├── Parses raw bytes via Go's httputil.ReadRequest
   ├── Evaluates ValidatingPolicy (CEL):
   │     ├── Has Bearer token? ✓
   │     ├── POST /v1/chat/completions? ✓
   │     └── → http.Allowed()
   └── Returns 200

4. custom_auth.py returns "sk-mqx2..." string

5. LiteLLM Internal Auth:
   ├── SHA256("sk-mqx2...") → lookup in PostgreSQL
   ├── Key found, model "gemini-flash" allowed ✓
   ├── Budget not exceeded ✓
   └── Forward to Gemini API (using real GEMINI_API_KEY)

6. Response returned to client, spend recorded in PostgreSQL
```

---

## Issues Encountered and Fixes

### Issue 1: PostgreSQL Connectivity in HA Mode

**Symptom:** LiteLLM pods crash with `P1001: Can't reach database server at litellm-postgresql:5432`

**Root Cause:** When PostgreSQL is deployed in `replication` mode, the Bitnami chart creates `litellm-postgresql-primary` as the service name, not `litellm-postgresql`. LiteLLM's templates hardcode `litellm-postgresql`.

**Fix:** Added an `ExternalName` Service in `values.yaml` under `extraResources` to alias `litellm-postgresql` → `litellm-postgresql-primary.litellm.svc.cluster.local`. This avoids modifying Helm templates.

```yaml
extraResources:
  - apiVersion: v1
    kind: Service
    metadata:
      name: litellm-postgresql
    spec:
      type: ExternalName
      externalName: litellm-postgresql-primary.litellm.svc.cluster.local
```

---

### Issue 2: Master Key Mismatch (401 on /key/generate)

**Symptom:** `Authentication Error, Invalid proxy server token passed` when calling `/key/generate` with the master key.

**Root Cause:** The Helm chart auto-generates a `litellm-masterkey` secret if not pinned. This created a different master key than the one in `litellm-env-secret`, causing a mismatch.

**Fix:** Pinned the master key source in `values.yaml`:

```yaml
masterkeySecretName: "litellm-env-secret"
masterkeySecretKey: "PROXY_MASTER_KEY"
```

---

### Issue 3: custom_auth.py Not Found (ImportError)

**Symptom:** `ImportError: Could not import user_api_key_auth from custom_auth`

**Root Cause:** `custom_auth.py` was copied to the image's `WORKDIR` (`/app/`), but LiteLLM expects it relative to the config file location at `/etc/litellm/`.

**Fix:** Updated Dockerfile:

```dockerfile
# Before (wrong)
COPY custom_auth.py ./custom_auth.py

# After (correct)
COPY custom_auth.py /etc/litellm/custom_auth.py
```

---

### Issue 4: Health Probes Failing with Custom Auth (CrashLoopBackOff)

**Symptom:** LiteLLM pods in `CrashLoopBackOff`. Logs show: `Only proxy admin can be used to generate, delete, update info for new keys/users/teams. Route=/health/readiness. Your role=unknown`

**Root Cause:** Kubernetes health probes hit `/health/readiness` without any `Authorization` header. The initial `custom_auth.py` raised an `Exception` for health routes, and returning `UserAPIKeyAuth(user_role=PROXY_ADMIN)` did not propagate the role through LiteLLM's post-auth checks in OSS mode.

**Fix:** Return the `master_key` string for health routes. LiteLLM natively recognizes the master key and assigns `PROXY_ADMIN` role:

```python
if path in HEALTH_ROUTES:
    return master_key  # LiteLLM resolves master key → PROXY_ADMIN
```

---

### Issue 5: UserAPIKeyAuth Role Not Propagating (role=unknown)

**Symptom:** `/key/generate` returns `Your role=unknown` even when `UserAPIKeyAuth(user_role=LitellmUserRoles.PROXY_ADMIN)` is returned from custom auth.

**Root Cause:** In LiteLLM OSS mode, the `user_role` field from `UserAPIKeyAuth` does not propagate through the internal post-auth checks (`_run_post_custom_auth_checks` → `common_checks` → `_is_allowed_route`). The role remains `unknown`.

**Fix:** Return the raw key string instead of `UserAPIKeyAuth`. LiteLLM's native auth pipeline correctly resolves roles from strings:

```python
# Master key → return string, LiteLLM resolves as PROXY_ADMIN
if master_key and api_key == master_key:
    return master_key

# Virtual key → return string, LiteLLM does DB lookup
return api_key
```

---

### Issue 6: custom_auth_settings mode: "auto" Requires Enterprise

**Symptom:** `mode: "auto"` in `custom_auth_settings` caused unexpected behavior in OSS LiteLLM — the fallback between custom auth and built-in auth did not work.

**Root Cause:** `mode: "auto"` is a LiteLLM Enterprise feature. In OSS, only `mode: "on"` is supported, which means custom auth fully replaces built-in auth.

**Fix:** Set `mode: "on"` and handle all auth paths inside `custom_auth.py` (health probes, master key bypass, Kyverno check, virtual key fallback).

```yaml
custom_auth_settings:
  mode: "on"
```

---

### Issue 7: gRPC Proto Compilation Failed in Docker Build

**Symptom:** Docker build fails with `Could not make proto path relative: envoy/service/auth/v3/authorization.proto: No such file or directory`

**Root Cause:** Initial approach tried to compile Envoy ext_authz gRPC protos inside a multi-stage Docker build. The Envoy `data-plane-api` repo was restructured, and transitive proto dependencies (googleapis, udpa, xds, protoc-gen-validate) were difficult to resolve.

**Fix:** Abandoned gRPC approach entirely. Switched to Kyverno's HTTP mode with `nestedRequest: true`, which accepts raw HTTP bytes instead of gRPC. This reduced the Dockerfile to two lines:

```dockerfile
FROM docker.litellm.ai/berriai/litellm-database:main-stable
COPY custom_auth.py /etc/litellm/custom_auth.py
```

---

### Issue 8: Immutable Migration Job on Helm Upgrade

**Symptom:** `helm upgrade` fails with `Job.batch "litellm-migrations" is invalid: spec.template: field is immutable`

**Root Cause:** Kubernetes Job `spec.template` is immutable after creation. When the image tag changes, Helm tries to update the Job spec, which is not allowed.

**Fix:** Delete the old migration Job before upgrading:

```bash
kubectl delete job litellm-migrations -n litellm --ignore-not-found
helm upgrade litellm ./litellm-helm -f ./litellm-helm/values.yaml -n litellm
```

---

### Issue 9: Kyverno Policy — Wrong API Version

**Symptom:** `Warning: policies.kyverno.io/v1alpha1 ValidatingPolicy is deprecated; use policies.kyverno.io/v1`

**Fix:** Updated `apiVersion` from `v1alpha1` to `v1`:

```yaml
apiVersion: policies.kyverno.io/v1
```

---

### Issue 10: Kyverno Policy — Wrong Header Object Path (Envoy vs HTTP Mode)

**Symptom:** `undefined field 'request'` in CEL expression `object.attributes.request.http.headers`

**Root Cause:** The CEL path `object.attributes.request.http.headers` is for Envoy mode. In HTTP mode, the structure is flat: `object.attributes.header`, `object.attributes.path`, `object.attributes.method`.

**Fix:**

```yaml
# Envoy mode (wrong for HTTP mode)
object.attributes.request.http.headers

# HTTP mode (correct)
object.attributes.header
object.attributes.path
object.attributes.method
```

---

### Issue 11: Kyverno Policy — Header Value Type Mismatch

**Symptom:** `found no matching overload for 'orValue' applied to 'optional_type(list(string)).(string)'`

**Root Cause:** With `nestedRequest: true`, Go's `http.Header` is `map[string][]string` (list of values per header). The CEL optional returns `optional_type(list(string))`, not `optional_type(string)`. Using `orValue("")` (string default) fails.

**Fix:**

```yaml
# Wrong — string default for list type
object.attributes.header[?"authorization"].orValue("")

# Correct — list default, take first element
object.attributes.header[?"Authorization"].orValue([""])[0]
```

---

### Issue 12: Kyverno Policy — Header Key Casing (The Final Bug)

**Symptom:** Kyverno always returns "Missing or invalid Bearer token" even when the request has `Authorization: Bearer sk-...`.

**Root Cause:** With `nestedRequest: true`, Go's `httputil.ReadRequest` parses the raw HTTP bytes and canonicalizes header keys to title-case (`Authorization`, not `authorization`). The policy was looking for lowercase `authorization`.

**Diagnosis:** Deployed a debug policy that returned both `header[?"authorization"]` and `header[?"Authorization"]` in the denial message:

```
lower_auth=none
title_auth=Bearer sk-test1234567890
```

**Fix:**

```yaml
# Wrong — lowercase, Go title-cases headers in nestedRequest mode
object.attributes.header[?"authorization"]

# Correct — title-case matches Go's canonical form
object.attributes.header[?"Authorization"]
```

---

### Issue 13: Raw HTTP Bytes — Escaped vs Real CRLF

**Symptom:** Kyverno receives the raw bytes but can't parse headers correctly.

**Root Cause:** The original `_build_raw_http_request` used `\\r\\n` (escaped) in f-strings, producing literal four-character sequences `\r\n` instead of actual CRLF bytes (0x0D 0x0A). Go's `httputil.ReadRequest` requires real CRLF.

**Fix:**

```python
# Wrong — produces literal backslash-r-backslash-n characters
request_line = f"{request.method} {request.url.path} HTTP/1.1\\r\\n"

# Correct — real CRLF bytes via join
lines = [f"{request.method} {request.url.path} HTTP/1.1"]
for key, value in request.headers.items():
    lines.append(f"{key}: {value}")
header_block = "\r\n".join(lines) + "\r\n\r\n"
return header_block.encode("latin-1") + body
```

---

### Issue 14: PostgreSQL Replication Password Missing

**Symptom:** `helm upgrade` fails with `PASSWORDS ERROR: The secret "litellm-postgresql" does not contain the key "replication-password"`

**Root Cause:** Switching PostgreSQL from `standalone` to `replication` architecture requires a replication password that wasn't in the existing secret.

**Fix:** Added `replicationPassword` to `values.yaml`:

```yaml
postgresql:
  architecture: replication
  auth:
    replicationPassword: NoTaGrEaTpAsSwOrD
```

---

## Virtual Key Management

### Generate a key

```bash
# Admin key (all models, 1 day)
curl -s -X POST "http://127.0.0.1:4000/key/generate" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models":["gemini-flash","claude-sonnet-4-5"],"duration":"1d","key_alias":"my-key"}'

# Team-scoped key
curl -s -X POST "http://127.0.0.1:4000/key/generate" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_id":"<team-id>","models":["gemini-flash"],"duration":"30d","key_alias":"team-key"}'

# User-scoped key
curl -s -X POST "http://127.0.0.1:4000/key/generate" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"user-123","models":["gemini-flash"],"max_budget":5,"duration":"30d"}'
```

### Check key info and spend

```bash
curl -s "http://127.0.0.1:4000/key/info?key=sk-..." \
  -H "Authorization: Bearer $PROXY_MASTER_KEY"
```

### Team management

```bash
# Create team
curl -s -X POST "http://127.0.0.1:4000/team/new" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_alias":"team-a","max_budget":20}'

# List teams
curl -s "http://127.0.0.1:4000/team/list" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY"
```

### Admin UI

Access at `http://127.0.0.1:4000/ui` — login with the master key as the password.

---

## Future Work (Phase 1: Identity Binding)

See [AUTHZ_LAYER_ARCHITECTURE.md](./AUTHZ_LAYER_ARCHITECTURE.md) for the planned Azure AD OIDC integration:

- JWT validation in `custom_auth.py` (Azure AD tokens)
- Kyverno policies evaluate JWT claims (groups, roles, tenant)
- Map Azure `oid` → `user_id`, Azure `groups` → `team_id`, Azure `tid` → `org_id`
- Virtual keys bound to authenticated identity (a key only works for its owner)
- Every request traceable to Azure identity in audit logs

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
| v7 | Fixed CRLF encoding in raw HTTP bytes (\\r\\n → real \r\n) |
