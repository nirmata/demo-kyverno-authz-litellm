# Installation Guide — AI Auth (LiteLLM + Kyverno + Azure AD OIDC)

End-to-end guide to deploy the AI Auth gateway on Kubernetes with Azure AD OIDC identity binding. Every command is explained so you understand what it does and why it's needed.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Cluster Setup (KIND)](#2-cluster-setup-kind)
3. [Install cert-manager](#3-install-cert-manager)
4. [Install Kyverno Authz Server](#4-install-kyverno-authz-server)
5. [Apply Kyverno Authorization Policy](#5-apply-kyverno-authorization-policy)
6. [Create Kubernetes Namespace and Secrets](#6-create-kubernetes-namespace-and-secrets)
7. [Build and Push Custom LiteLLM Image](#7-build-and-push-custom-litellm-image)
8. [Deploy LiteLLM via Helm](#8-deploy-litellm-via-helm)
9. [Verify the Deployment](#9-verify-the-deployment)
10. [Azure AD App Registration](#10-azure-ad-app-registration)
11. [Create Azure AD Groups](#11-create-azure-ad-groups)
12. [Add Users to Azure AD Groups](#12-add-users-to-azure-ad-groups)
13. [Configure Azure AD Token Claims](#13-configure-azure-ad-token-claims)
14. [Create OAuth2 Scope and Pre-authorize Azure CLI](#14-create-oauth2-scope-and-pre-authorize-azure-cli)
15. [Update Kubernetes ConfigMap for Azure AD](#15-update-kubernetes-configmap-for-azure-ad)
16. [Create LiteLLM Teams and Virtual Keys](#16-create-litellm-teams-and-virtual-keys)
17. [Acquire Azure AD Tokens](#17-acquire-azure-ad-tokens)
18. [Run the End-to-End Test Suite](#18-run-the-end-to-end-test-suite)
19. [Cleanup](#19-cleanup)

---

## 1. Prerequisites

| Tool | Minimum Version | Purpose |
|------|-----------------|---------|
| `kubectl` | 1.27+ | Kubernetes cluster management |
| `helm` | 3.x | Deploying charts (cert-manager, Kyverno, LiteLLM) |
| `docker` | 24+ with Buildx | Building multi-arch custom LiteLLM image |
| `az` (Azure CLI) | 2.50+ | Azure AD app registration, group management, token acquisition |
| `curl` | any | Testing API endpoints |
| `jq` | any | Parsing JSON responses |
| `python3` + `pip` | 3.9+ | Generating mock JWTs (optional, for local testing) |
| `kind` | 0.20+ | (Optional) Local Kubernetes cluster |

Install Azure CLI if you don't have it:

```bash
# macOS
brew install azure-cli

# Linux
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

---

## 2. Cluster Setup (KIND)

> Skip this step if you already have a Kubernetes cluster.

KIND (Kubernetes IN Docker) creates a local cluster using Docker containers as nodes.

```bash
kind create cluster --name ai-auth
```

This creates a single-node Kubernetes cluster named `ai-auth`. KIND automatically configures `kubectl` to point to this cluster by updating your `~/.kube/config`.

Verify the cluster is running:

```bash
kubectl cluster-info --context kind-ai-auth
```

---

## 3. Install cert-manager

cert-manager automates TLS certificate management in Kubernetes. Kyverno's webhook server needs a TLS certificate to communicate with the Kubernetes API server.

```bash
helm install cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --wait \
  --repo https://charts.jetstack.io cert-manager \
  --set crds.enabled=true
```

| Flag | Explanation |
|------|-------------|
| `--namespace cert-manager` | Installs into a dedicated namespace |
| `--create-namespace` | Creates the namespace if it doesn't exist |
| `--wait` | Blocks until all pods are ready before returning |
| `--repo` | Pulls the chart directly from Jetstack's Helm repository |
| `--set crds.enabled=true` | Installs the Custom Resource Definitions (CRDs) that cert-manager needs |

Create a `ClusterIssuer` — this tells cert-manager how to issue certificates. We use self-signed certs since this is for internal Kyverno webhook communication:

```bash
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
```

Install the Kyverno ValidatingPolicy CRD — this custom resource definition is required for Kyverno to understand our authorization policy:

```bash
kubectl apply \
  -f https://raw.githubusercontent.com/kyverno/kyverno/refs/heads/main/config/crds/policies.kyverno.io/policies.kyverno.io_validatingpolicies.yaml
```

---

## 4. Install Kyverno Authz Server

Kyverno Authz Server is a standalone server that evaluates authorization policies against HTTP requests. It acts as a policy decision point.

```bash
helm upgrade --install kyverno-authz-server \
  --namespace kyverno \
  --create-namespace \
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

| Setting | Explanation |
|---------|-------------|
| `config.type: http` | Uses HTTP mode (not gRPC/Envoy). Our `custom_auth.py` sends raw HTTP request bytes to Kyverno for policy evaluation. |
| `config.http.address: ":9081"` | The port Kyverno listens on for authorization requests |
| `config.http.nestedRequest: true` | Tells Kyverno to parse the request body as a nested HTTP request (Go's `httputil.ReadRequest`). This is how `custom_auth.py` forwards the original client request to Kyverno for inspection. |
| `certificates.certManager` | Uses the `selfsigned-issuer` from cert-manager for the webhook's TLS certificate |

---

## 5. Apply Kyverno Authorization Policy

This policy defines the authorization rules that Kyverno evaluates:

```bash
kubectl apply -f kyverno-validating-policy.yaml
```

The policy (`kyverno-validating-policy.yaml`) implements three rules using CEL expressions:

1. **Allow health routes** — `/health/*`, `/ready`, `/healthz` pass without any auth (kubelet probes).
2. **Deny unauthenticated** — Requests without a valid `Authorization: Bearer <token>` header are rejected with 403.
3. **Allow authenticated** — All requests with a Bearer token are allowed through Kyverno.

Fine-grained authorization (model access, budget, team scoping, JWT identity binding) is handled by `custom_auth.py` and LiteLLM's internal auth — not by Kyverno. Kyverno's role is a coarse-grained authentication gate.

The policy also extracts JWT claim headers (`X-Jwt-Sub`, `X-Jwt-Groups`, `X-Jwt-Email`) as variables for future claim-based rules (e.g., allow only certain groups to access specific models at the Kyverno level).

---

## 6. Create Kubernetes Namespace and Secrets

### Create the namespace

```bash
kubectl create namespace litellm
```

All LiteLLM components (proxy, PostgreSQL, Redis) run in this namespace.

### Create the environment secret

```bash
kubectl create secret generic litellm-env-secret \
  -n litellm \
  --from-literal=PROXY_MASTER_KEY='sk-your-master-key-here' \
  --from-literal=LITELLM_MASTER_KEY='sk-your-master-key-here' \
  --from-literal=GEMINI_API_KEY='your-gemini-api-key' \
  --from-literal=ANTHROPIC_API_KEY='your-anthropic-api-key'
```

| Secret Key | Purpose |
|------------|---------|
| `PROXY_MASTER_KEY` | The admin master key for LiteLLM. Used by `custom_auth.py` to bypass JWT checks and for admin operations (creating teams, keys). |
| `LITELLM_MASTER_KEY` | Must be the **same value** as `PROXY_MASTER_KEY`. LiteLLM's UI login uses this env var to validate admin credentials. Without it, the UI shows "Invalid credentials". |
| `GEMINI_API_KEY` | Google Gemini API key — LiteLLM uses this to forward requests to the Gemini API. |
| `ANTHROPIC_API_KEY` | Anthropic API key — LiteLLM uses this to forward requests to the Claude API. |

> Replace `sk-your-master-key-here` with a strong random string. This is the admin key for the entire system.

### Create the database credentials secret

```bash
kubectl create secret generic litellm-dbcredentials \
  -n litellm \
  --from-literal=username=litellm \
  --from-literal=password=YourStrongPasswordHere
```

These credentials are used by both the PostgreSQL deployment and LiteLLM to connect to the database. PostgreSQL stores virtual keys, team configurations, spend tracking, and user data.

### Create the JWT configuration ConfigMap

For initial setup (mock JWT — local testing only):

```bash
kubectl create configmap litellm-jwt-config \
  -n litellm \
  --from-literal=JWT_JWKS_URL=http://jwks-mock.litellm.svc:8080/.well-known/jwks.json \
  --from-literal=JWT_ISSUER=http://mock-issuer \
  --from-literal=JWT_AUDIENCE=litellm-proxy \
  --from-literal=JWT_HEADER_NAME=X-Identity-Token
```

| Config Key | Purpose |
|------------|---------|
| `JWT_JWKS_URL` | URL where `custom_auth.py` fetches the public keys (JWKS) to verify JWT signatures. For local testing, this points to an in-cluster nginx pod. For production, this points to Azure AD. |
| `JWT_ISSUER` | Expected `iss` claim in the JWT. PyJWT rejects tokens with a different issuer. |
| `JWT_AUDIENCE` | Expected `aud` claim in the JWT. PyJWT rejects tokens meant for a different audience. |
| `JWT_HEADER_NAME` | The HTTP header where clients send their identity JWT. Default is `X-Identity-Token` (separate from the `Authorization` header which carries the LiteLLM virtual key). |

> This ConfigMap will be **replaced** with Azure AD values in [Step 15](#15-update-kubernetes-configmap-for-azure-ad).

---

## 7. Build and Push Custom LiteLLM Image

The custom image adds PyJWT (for JWT validation) and `custom_auth.py` (the auth handler) on top of the official LiteLLM database image.

### The Dockerfile

```dockerfile
FROM docker.litellm.ai/berriai/litellm-database:main-stable
RUN pip install --no-cache-dir "PyJWT[crypto]"
COPY custom_auth.py /etc/litellm/custom_auth.py
```

| Line | Explanation |
|------|-------------|
| `FROM ...litellm-database:main-stable` | Base image with LiteLLM + Prisma + database support. The `main-stable` tag is the latest stable release. |
| `RUN pip install "PyJWT[crypto]"` | Installs PyJWT with cryptographic backends (RSA, ECDSA) needed for JWT signature verification. The `[crypto]` extra includes `cryptography` library. |
| `COPY custom_auth.py /etc/litellm/` | Places the custom auth module where LiteLLM expects it. The path `/etc/litellm/` is configured in `values.yaml` via `custom_auth_settings`. |

### Build and push

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag anuddeeph/litellm-custom-auth:v10 \
  --push .
```

| Flag | Explanation |
|------|-------------|
| `--platform linux/amd64,linux/arm64` | Builds for both Intel/AMD and ARM architectures (needed for M1/M2 Macs and mixed clusters) |
| `--tag` | Docker image name and version tag. Replace `anuddeeph` with your registry. |
| `--push` | Pushes to the container registry immediately after building |

> Update `litellm-helm/values.yaml` to match your image repository and tag:
> ```yaml
> image:
>   repository: anuddeeph/litellm-custom-auth
>   tag: "v10"
> ```

---

## 8. Deploy LiteLLM via Helm

LiteLLM is deployed using a Helm chart that includes the proxy, PostgreSQL (1 primary + 2 read replicas), and Redis (1 master + 2 replicas).

```bash
# Delete any existing migration job (it's immutable and blocks upgrades)
kubectl delete job litellm-migrations -n litellm --ignore-not-found

# Deploy or upgrade LiteLLM
helm upgrade --install litellm ./litellm-helm \
  -f ./litellm-helm/values.yaml \
  -n litellm
```

| Command | Explanation |
|---------|-------------|
| `kubectl delete job litellm-migrations` | LiteLLM runs a database migration Job on first deploy. Kubernetes Jobs are immutable — if the image or config changes, the old Job blocks the upgrade. Deleting it allows the new migration to run. `--ignore-not-found` prevents errors on first deploy. |
| `helm upgrade --install` | Installs the chart if it doesn't exist, or upgrades it if it does. Idempotent. |
| `-f ./litellm-helm/values.yaml` | Uses the custom values file with the auth image, PostgreSQL HA config, Redis, and custom auth settings. |
| `-n litellm` | Deploys into the `litellm` namespace. |

Key settings in `values.yaml`:

| Setting | Value | Purpose |
|---------|-------|---------|
| `replicaCount: 3` | Deploys 3 LiteLLM proxy pods for high availability |
| `image.repository` | `anuddeeph/litellm-custom-auth` | Custom image with PyJWT and custom_auth.py |
| `image.tag` | `v10` | Version with Azure AD `oid` claim support |
| `masterkeySecretName` | `litellm-env-secret` | Pins the master key to our secret (prevents Helm from generating a random one) |
| `custom_auth_settings.mode` | `on` | Enables custom auth for every request. OSS LiteLLM only supports `on` (not `auto`). |
| `custom_auth_settings.module` | `custom_auth.user_api_key_auth` | Python module path to the auth function |
| `postgresql.architecture` | `replication` | Deploys PostgreSQL with 1 primary + 2 read replicas |

---

## 9. Verify the Deployment

### Check pod status

```bash
kubectl get pods -n litellm
kubectl get pods -n kyverno
```

Expected output — all pods should be `Running` with `READY 1/1`:

```
NAME                        READY   STATUS    RESTARTS   AGE
litellm-0                   1/1     Running   0          2m
litellm-1                   1/1     Running   0          2m
litellm-2                   1/1     Running   0          2m
litellm-postgresql-primary-0    1/1     Running   0          2m
litellm-postgresql-read-0       1/1     Running   0          2m
litellm-postgresql-read-1       1/1     Running   0          2m
litellm-redis-master-0          1/1     Running   0          2m
litellm-redis-replicas-0        1/1     Running   0          2m
litellm-redis-replicas-1        1/1     Running   0          2m
```

### Port-forward the LiteLLM proxy

```bash
kubectl port-forward -n litellm svc/litellm 4000:4000
```

This maps `localhost:4000` to the LiteLLM service inside the cluster. All subsequent `curl` commands target `http://127.0.0.1:4000`.

### Test health endpoint

```bash
curl -s http://127.0.0.1:4000/health/readiness
```

Expected: `{"status":"healthy",...}`. Health endpoints bypass all auth layers (no JWT, no Bearer token needed).

### Test master key

```bash
export PROXY_MASTER_KEY=$(kubectl get secret -n litellm litellm-env-secret \
  -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)

curl -s http://127.0.0.1:4000/model/info \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" | jq .
```

This retrieves your master key from Kubernetes and tests that admin operations work.

### Verify Azure AD JWKS connectivity from inside the cluster

```bash
kubectl exec -n litellm deploy/litellm -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('https://login.microsoftonline.com/common/discovery/v2.0/keys').read()[:200])"
```

This confirms that LiteLLM pods can reach Microsoft's JWKS endpoint (needed for JWT signature verification). If this fails, check cluster DNS and egress network policies.

---

## 10. Azure AD App Registration

An App Registration in Azure AD (Entra ID) creates an identity for your application. Azure AD will issue JWTs scoped to this application.

### Set variables

```bash
# Your Azure AD tenant ID
TENANT_ID="3d95acd6-b6ee-428e-a7a0-196120fc3c65"
```

### Create the app registration

```bash
az ad app create \
  --display-name "litellm-proxy" \
  --sign-in-audience "AzureADMyOrg"
```

| Flag | Explanation |
|------|-------------|
| `--display-name "litellm-proxy"` | Human-readable name shown in Azure portal |
| `--sign-in-audience "AzureADMyOrg"` | Only users from your tenant can authenticate. Other options: `AzureADMultipleOrgs` (multi-tenant), `AzureADandPersonalMicrosoftAccount` (consumer + work accounts). |

The output includes two IDs you need:

| Field | Example | Usage |
|-------|---------|-------|
| `appId` (Client ID) | `1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe` | Used as `JWT_AUDIENCE` in ConfigMap. Appears in the `aud` claim of issued tokens. |
| `id` (Object ID) | `9c8b9483-4410-40dc-a0f3-ff315b8b9afa` | Used in Graph API calls to modify the app registration. |

Save these values:

```bash
APP_ID="1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe"
APP_OBJECT_ID="9c8b9483-4410-40dc-a0f3-ff315b8b9afa"
```

### Set the Application ID URI

```bash
az ad app update --id "$APP_ID" --identifier-uris "api://${APP_ID}"
```

This sets the Application ID URI to `api://<client-id>`. This URI is used as the `resource` parameter when requesting tokens (`az account get-access-token --resource "api://..."`) and is the standard format for Azure AD APIs.

### Create a service principal

```bash
az ad sp create --id "$APP_ID"
```

A **service principal** is the local representation of the app registration in your tenant. It's needed for users to authenticate against the app. Without it, Azure AD won't issue tokens for this app.

### Set token version to v2.0

```bash
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}" \
  --body '{"api":{"requestedAccessTokenVersion":2}}'
```

Azure AD has two token versions:
- **v1.0**: Legacy format. `iss` includes the tenant ID only. `groups` claim uses display names.
- **v2.0**: Modern format. `iss` includes `/v2.0` suffix. Uses GUIDs for group claims. This is what we want.

The `requestedAccessTokenVersion: 2` ensures all access tokens are v2.0 format, so the `iss` claim will be `https://login.microsoftonline.com/{tenant}/v2.0` — matching what we configure in `JWT_ISSUER`.

---

## 11. Create Azure AD Groups

Azure AD security groups map to LiteLLM teams. When a user authenticates, their group memberships appear in the JWT `groups` claim as GUIDs.

```bash
# Create groups for each LiteLLM team
az ad group create --display-name "litellm-team-a" --mail-nickname "litellm-team-a"
az ad group create --display-name "litellm-team-b" --mail-nickname "litellm-team-b"
az ad group create --display-name "litellm-team-c" --mail-nickname "litellm-team-c"
az ad group create --display-name "litellm-team-d" --mail-nickname "litellm-team-d"
```

| Flag | Explanation |
|------|-------------|
| `--display-name` | Human-readable group name shown in Azure portal |
| `--mail-nickname` | Required by Azure AD. Used as the email alias. Must be unique within the tenant. |

Each command returns a JSON object with the group's `id` (Object ID). Save these:

```bash
GROUP_A="3412b52e-e01e-48e6-9092-6ad4f9f65496"   # litellm-team-a
GROUP_B="c7c1b22b-2635-4ad1-ab0e-0b0927e8c582"   # litellm-team-b
GROUP_C="1de73371-f70e-4ea0-841d-386f873cc557"    # litellm-team-c
GROUP_D="9d7b89cf-1b56-4745-9d8e-279d2e5f59ee"    # litellm-team-d
```

### Team-to-model mapping

| Azure AD Group | LiteLLM Team | Models | Purpose |
|----------------|-------------|--------|---------|
| litellm-team-a | team-a | gemini-flash only | Model isolation test (Scenario A) |
| litellm-team-b | team-b | claude-sonnet-4-5 only | Model isolation test (Scenario A) |
| litellm-team-c | team-c | gemini + claude | JWT identity isolation test (Scenario B) |
| litellm-team-d | team-d | gemini + claude | JWT identity isolation test (Scenario B) |

Teams A and B have **different** model permissions — isolation comes from model restrictions.
Teams C and D have **identical** model permissions — isolation comes purely from JWT identity binding (`oid == key.user_id`).

---

## 12. Add Users to Azure AD Groups

Look up each user's Azure AD Object ID (OID) — this is the stable GUID that identifies the user across all apps:

```bash
# Look up user OIDs by email
az ad user show --id "anudeep.nalla@nirmata.com" --query id -o tsv
az ad user show --id "sachin.agarwal@nirmata.com" --query id -o tsv
az ad user show --id "rahul.kaushal@nirmata.com" --query id -o tsv
```

Save the OIDs:

```bash
OID_ANUDEEP="80fa6a56-cf00-4090-bbce-b6b3021cf1a7"
OID_SACHIN="91c0c55c-0c8a-49fb-85c9-acef4efb798f"
OID_RAHUL="8ca1dc25-e960-4c47-9843-b5b7f51a4315"
```

Add users to their respective groups:

```bash
# Anudeep → team-a (gemini only) and team-c (gemini + claude)
az ad group member add --group "$GROUP_A" --member-id "$OID_ANUDEEP"
az ad group member add --group "$GROUP_C" --member-id "$OID_ANUDEEP"

# Sachin → team-b (claude only)
az ad group member add --group "$GROUP_B" --member-id "$OID_SACHIN"

# Rahul → team-d (gemini + claude)
az ad group member add --group "$GROUP_D" --member-id "$OID_RAHUL"
```

| Flag | Explanation |
|------|-------------|
| `--group` | The Object ID of the Azure AD security group |
| `--member-id` | The Object ID (OID) of the user to add to the group |

Verify memberships:

```bash
az ad group member list --group "$GROUP_C" --query '[].{name:displayName, oid:id}' -o table
```

---

## 13. Configure Azure AD Token Claims

By default, Azure AD access tokens don't include `groups`, `email`, or `preferred_username` claims. We need to configure the app registration to emit these.

```bash
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}" \
  --body '{
    "groupMembershipClaims": "SecurityGroup",
    "optionalClaims": {
      "accessToken": [
        {"name": "email", "essential": false},
        {"name": "preferred_username", "essential": false}
      ]
    }
  }'
```

| Setting | Explanation |
|---------|-------------|
| `groupMembershipClaims: "SecurityGroup"` | Includes the user's security group memberships in the JWT `groups` claim. Values are **group Object IDs (GUIDs)**, not display names. Other options: `"All"` (includes distribution lists, roles), `"None"` (no groups claim). |
| `optionalClaims.accessToken[].email` | Adds the user's email address to the access token. By default, Azure only includes it in ID tokens, not access tokens. |
| `optionalClaims.accessToken[].preferred_username` | Adds the UPN (User Principal Name) to the access token. Useful for logging and display. |

These claims are used by `custom_auth.py`:
- `groups` → forwarded to Kyverno as `X-Jwt-Groups` for future claim-based policies
- `email` → forwarded to Kyverno as `X-Jwt-Email` for audit logging
- `oid` → used as the identity for key ownership checks (always present in v2.0 tokens, no extra config needed)

---

## 14. Create OAuth2 Scope and Pre-authorize Azure CLI

### Add an OAuth2 permission scope

```bash
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}" \
  --body '{
    "api": {
      "oauth2PermissionScopes": [{
        "adminConsentDescription": "Allow the application to access LiteLLM proxy on behalf of the signed-in user",
        "adminConsentDisplayName": "Access LiteLLM Proxy",
        "id": "e1f1a8b0-1234-5678-9abc-def012345678",
        "isEnabled": true,
        "type": "User",
        "value": "access_as_user"
      }]
    }
  }'
```

| Field | Explanation |
|-------|-------------|
| `id` | A unique GUID for this scope. You can generate one or use a fixed value. |
| `value: "access_as_user"` | The scope name. Used in `--scope "api://{app-id}/access_as_user"` when requesting tokens. |
| `type: "User"` | Delegated permission — the user consents to the app acting on their behalf. |

This creates a scope that allows users to request tokens for the `litellm-proxy` app. Without it, `az account get-access-token` would fail with "No scopes available."

### Register Azure CLI service principal in your tenant

```bash
az ad sp create --id "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
```

`04b07795-8ddb-461a-bbee-02f9e1bf7b46` is the **well-known Application ID of the Azure CLI** (hardcoded by Microsoft). This command creates a service principal for the Azure CLI in your tenant, which is required for Azure CLI to request tokens for your app.

Without this step, you'll get `AADSTS650057: Invalid resource` when running `az account get-access-token`.

### Pre-authorize Azure CLI

```bash
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}" \
  --body "{
    \"api\": {
      \"preAuthorizedApplications\": [{
        \"appId\": \"04b07795-8ddb-461a-bbee-02f9e1bf7b46\",
        \"delegatedPermissionIds\": [\"e1f1a8b0-1234-5678-9abc-def012345678\"]
      }]
    }
  }"
```

This tells Azure AD: "The Azure CLI is pre-authorized to request tokens for `litellm-proxy` using the `access_as_user` scope." Without pre-authorization, each user would get an interactive consent prompt the first time they request a token.

The `delegatedPermissionIds` array contains the `id` of the OAuth2 scope created in the previous step.

---

## 15. Update Kubernetes ConfigMap for Azure AD

Now replace the mock JWT configuration with Azure AD endpoints:

```bash
TENANT_ID="3d95acd6-b6ee-428e-a7a0-196120fc3c65"
CLIENT_ID="1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe"

kubectl create configmap litellm-jwt-config \
  -n litellm \
  --from-literal=JWT_JWKS_URL="https://login.microsoftonline.com/${TENANT_ID}/discovery/v2.0/keys" \
  --from-literal=JWT_ISSUER="https://login.microsoftonline.com/${TENANT_ID}/v2.0" \
  --from-literal=JWT_AUDIENCE="${CLIENT_ID}" \
  --from-literal=JWT_HEADER_NAME="X-Identity-Token" \
  --dry-run=client -o yaml | kubectl apply -f -
```

| Config Key | Azure AD Value | Explanation |
|------------|----------------|-------------|
| `JWT_JWKS_URL` | `https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys` | Microsoft's public JWKS endpoint. Contains the RSA public keys used to verify JWT signatures. PyJWKClient caches these keys and auto-refreshes when a new `kid` (Key ID) appears. |
| `JWT_ISSUER` | `https://login.microsoftonline.com/{tenant}/v2.0` | The expected `iss` claim in Azure v2.0 tokens. Must include `/v2.0` suffix. PyJWT rejects tokens with a different issuer. |
| `JWT_AUDIENCE` | `1e959ea2-...` (Client ID) | The app registration's Application (client) ID. Must match the `aud` claim in the token. This ensures tokens issued for other apps are rejected. |
| `JWT_HEADER_NAME` | `X-Identity-Token` | Unchanged — clients still send the JWT in this custom header. |

The `--dry-run=client -o yaml | kubectl apply -f -` pattern creates-or-updates the ConfigMap idempotently. Without it, `kubectl create` would fail if the ConfigMap already exists.

Restart LiteLLM to pick up the new configuration:

```bash
kubectl rollout restart deploy/litellm -n litellm
```

This performs a rolling restart — pods are replaced one at a time with zero downtime. The new pods load the updated `JWT_JWKS_URL`, `JWT_ISSUER`, and `JWT_AUDIENCE` from the ConfigMap.

---

## 16. Create LiteLLM Teams and Virtual Keys

With the proxy running and Azure AD configured, create LiteLLM teams and virtual keys that map to Azure AD users.

### Retrieve the master key

```bash
export PROXY_MASTER_KEY=$(kubectl get secret -n litellm litellm-env-secret \
  -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)
```

### Create teams

```bash
# Team A — gemini only (for Anudeep, Scenario A)
curl -s -X POST "http://127.0.0.1:4000/team/new" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_alias":"litellm-team-a","models":["gemini-flash"],"max_budget":10}' | jq .

# Team B — claude only (for Sachin, Scenario A)
curl -s -X POST "http://127.0.0.1:4000/team/new" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_alias":"litellm-team-b","models":["claude-sonnet-4-5"],"max_budget":10}' | jq .

# Team C — gemini + claude (for Anudeep, Scenario B)
curl -s -X POST "http://127.0.0.1:4000/team/new" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_alias":"litellm-team-c","models":["gemini-flash","claude-sonnet-4-5"],"max_budget":10}' | jq .

# Team D — gemini + claude (for Rahul, Scenario B)
curl -s -X POST "http://127.0.0.1:4000/team/new" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_alias":"litellm-team-d","models":["gemini-flash","claude-sonnet-4-5"],"max_budget":10}' | jq .
```

Each response includes a `team_id` (UUID). Save these for key generation.

### Generate virtual keys

Virtual keys are bound to Azure AD users via the `user_id` field, which must be the user's Azure AD **OID** (Object ID). This is the critical link between Azure AD identity and LiteLLM keys:

```bash
# Key for Anudeep on team-a (gemini only)
curl -s -X POST "http://127.0.0.1:4000/key/generate" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id":"<TEAM_A_ID>",
    "user_id":"80fa6a56-cf00-4090-bbce-b6b3021cf1a7",
    "models":["gemini-flash"],
    "duration":"30d",
    "key_alias":"anudeep-team-a"
  }' | jq .

# Key for Sachin on team-b (claude only)
curl -s -X POST "http://127.0.0.1:4000/key/generate" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id":"<TEAM_B_ID>",
    "user_id":"91c0c55c-0c8a-49fb-85c9-acef4efb798f",
    "models":["claude-sonnet-4-5"],
    "duration":"30d",
    "key_alias":"sachin-team-b"
  }' | jq .

# Key for Anudeep on team-c (gemini + claude)
curl -s -X POST "http://127.0.0.1:4000/key/generate" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id":"<TEAM_C_ID>",
    "user_id":"80fa6a56-cf00-4090-bbce-b6b3021cf1a7",
    "models":["gemini-flash","claude-sonnet-4-5"],
    "duration":"30d",
    "key_alias":"anudeep-team-c"
  }' | jq .

# Key for Rahul on team-d (gemini + claude)
curl -s -X POST "http://127.0.0.1:4000/key/generate" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id":"<TEAM_D_ID>",
    "user_id":"8ca1dc25-e960-4c47-9843-b5b7f51a4315",
    "models":["gemini-flash","claude-sonnet-4-5"],
    "duration":"30d",
    "key_alias":"rahul-team-d"
  }' | jq .
```

> Replace `<TEAM_X_ID>` with the actual `team_id` from the team creation responses.

**Critical**: The `user_id` field **must** be the Azure AD OID. During inference requests, `custom_auth.py` extracts the `oid` claim from the Azure JWT and compares it to the key's `user_id`. If they don't match, the request is rejected with "Key owner mismatch."

Each response includes the generated virtual key (`key`). Save these:

```bash
export KEY_ANUDEEP_A="sk-..."   # Anudeep, team-a, gemini only
export KEY_SACHIN_B="sk-..."    # Sachin, team-b, claude only
export KEY_ANUDEEP_C="sk-..."   # Anudeep, team-c, gemini + claude
export KEY_RAHUL_D="sk-..."     # Rahul, team-d, gemini + claude
```

---

## 17. Acquire Azure AD Tokens

Each user must authenticate with Azure AD to get a JWT. The JWT proves their identity and carries their group memberships.

### First-time login (consent flow)

The first time a user requests a token for `litellm-proxy`, they must grant consent. This opens a browser:

```bash
az logout
az login --tenant "$TENANT_ID" \
  --scope "api://${CLIENT_ID}/.default"
```

| Flag | Explanation |
|------|-------------|
| `az logout` | Clears cached tokens and sessions. Ensures a fresh login. |
| `--tenant` | Forces authentication against your specific tenant (not a personal Microsoft account) |
| `--scope "api://{client-id}/.default"` | Requests all statically defined scopes for the `litellm-proxy` app (includes `access_as_user`). The `.default` scope is a special value that requests all configured permissions. |

This opens a browser window. The user logs in with their Azure AD credentials and consents to the `litellm-proxy` app.

### Get the access token

After login, acquire the access token:

```bash
AZURE_TOKEN=$(az account get-access-token \
  --resource "api://${CLIENT_ID}" \
  --query 'accessToken' \
  -o tsv)
```

| Flag | Explanation |
|------|-------------|
| `--resource "api://{client-id}"` | The Application ID URI of your app registration. Azure AD issues a token with `aud: <client-id>` for this resource. |
| `--query 'accessToken'` | JMESPath query to extract just the token string from the JSON response |
| `-o tsv` | Output as tab-separated value (plain text, no quotes) |

### Inspect the token (optional)

```bash
echo "$AZURE_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```

This decodes the JWT payload (second segment, base64-encoded). Example output:

```json
{
  "aud": "1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe",
  "iss": "https://login.microsoftonline.com/3d95acd6-b6ee-428e-a7a0-196120fc3c65/v2.0",
  "oid": "80fa6a56-cf00-4090-bbce-b6b3021cf1a7",
  "email": "anudeep.nalla@nirmata.com",
  "groups": ["1de73371-f70e-4ea0-841d-386f873cc557", "3412b52e-e01e-48e6-9092-6ad4f9f65496"],
  "name": "Anudeep Nalla",
  "preferred_username": "anudeep.nalla@nirmata.com",
  "scp": "access_as_user",
  "sub": "074UOXmkq51-sbWz17hOqNGO-...",
  "exp": 1773832715
}
```

Key observations:
- `oid` is the stable Azure Object ID — used by `custom_auth.py` for key ownership checks
- `sub` is pairwise (different per app) — **not** used for identity
- `groups` contains Azure AD security group GUIDs
- `scp: "access_as_user"` confirms the OAuth2 scope from Step 14
- `exp` is the Unix timestamp when the token expires (typically 1 hour)

### Repeat for each user

Each user runs the same commands from their machine (they need Azure CLI installed):

```bash
# User logs in
az login --tenant "3d95acd6-b6ee-428e-a7a0-196120fc3c65" \
  --scope "api://1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe/.default"

# Get token
az account get-access-token \
  --resource "api://1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe" \
  --query accessToken -o tsv
```

---

## 18. Run the End-to-End Test Suite

The test script (`scripts/test_azure_oidc.sh`) validates all three authorization scenarios using real Azure AD tokens.

### Set environment variables

```bash
export PROXY_MASTER_KEY=$(kubectl get secret -n litellm litellm-env-secret \
  -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)

# Azure AD tokens (each user runs az account get-access-token)
export TOKEN_ANUDEEP="eyJ0eXAi..."
export TOKEN_SACHIN="eyJ0eXAi..."
export TOKEN_RAHUL="eyJ0eXAi..."

# LiteLLM virtual keys (from Step 16)
export KEY_ANUDEEP_A="sk-..."   # team-a, gemini only
export KEY_SACHIN_B="sk-..."    # team-b, claude only
export KEY_ANUDEEP_C="sk-..."   # team-c, gemini + claude
export KEY_RAHUL_D="sk-..."     # team-d, gemini + claude
```

### Run the tests

```bash
bash scripts/test_azure_oidc.sh
```

Or auto-create teams and keys:

```bash
CREATE_KEYS=true bash scripts/test_azure_oidc.sh
```

### Expected output

```
========================================================================
  TEST RESULTS
========================================================================

  Scenario A — Model-Based Team Isolation:        6 tests
  Scenario B — JWT Identity Key Isolation:         8 tests
  Scenario C — Management Routes (no JWT):         4 tests

  ALL 18 TESTS PASSED

  Azure AD Users Tested:
    Anudeep Nalla   (anudeep.nalla@nirmata.com)  — OID: 80fa6a56-cf00-4090-bbce-b6b3021cf1a7
    Sachin Agarwal  (sachin.agarwal@nirmata.com) — OID: 91c0c55c-0c8a-49fb-85c9-acef4efb798f
    Rahul Kaushal   (rahul.kaushal@nirmata.com)  — OID: 8ca1dc25-e960-4c47-9843-b5b7f51a4315

  Authorization Layers Verified:
    1. Azure AD OIDC — JWT signature, issuer, audience, expiry
    2. Kyverno Authz Server — Bearer token presence gate
    3. custom_auth.py — JWT identity binding (oid == key.user_id)
    4. LiteLLM Internal Auth — model access, budget, team scoping

========================================================================
```

### What the 18 tests verify

**Scenario A — Model-Based Team Isolation (6 tests)**

| # | Test | Expected |
|---|------|----------|
| A1 | Anudeep (team-a key) → gemini | Allowed (model permitted) |
| A2 | Anudeep (team-a key) → claude | Denied (model not permitted) |
| A3 | Sachin (team-b key) → claude | Allowed (model permitted) |
| A4 | Sachin (team-b key) → gemini | Denied (model not permitted) |
| A5 | Anudeep JWT + Sachin's key | Denied (OID mismatch) |
| A6 | Sachin JWT + Anudeep's key | Denied (OID mismatch) |

**Scenario B — JWT Identity Key Isolation (8 tests)**

| # | Test | Expected |
|---|------|----------|
| B1 | Anudeep JWT + Anudeep key → gemini | Allowed (OID matches) |
| B2 | Rahul JWT + Anudeep key | Denied (OID mismatch) |
| B3 | No JWT + virtual key | Denied (missing identity token) |
| B4 | Master key, no JWT | Allowed (admin bypass) |
| B5 | Rahul JWT + Rahul key → claude | Allowed (OID matches) |
| B6 | Anudeep JWT + Rahul key | Denied (OID mismatch) |
| B7 | Fake JWT | Denied (invalid signature) |
| B8 | Old mock JWT (wrong issuer/kid) | Denied (wrong signing key) |

**Scenario C — Management Routes (4 tests)**

| # | Test | Expected |
|---|------|----------|
| C1 | GET /model/info (master key, no JWT) | Allowed |
| C2 | GET /key/info (master key, no JWT) | Allowed |
| C3 | GET /team/list (master key, no JWT) | Allowed |
| C4 | GET /health/readiness (no auth) | Allowed |

---

## 19. Cleanup

### Remove mock JWKS resources (no longer needed with Azure AD)

```bash
kubectl delete -f scripts/jwks-deployment.yaml --ignore-not-found
kubectl delete configmap jwks-mock-data -n litellm --ignore-not-found
```

The mock JWKS (nginx serving a local RSA public key) was used during local development. With Azure AD, `custom_auth.py` fetches public keys directly from `login.microsoftonline.com`.

### Revoke old mock virtual keys

Any virtual keys created with friendly-name `user_id` values (e.g., `user-c`, `user-d`) should be revoked, as they won't work with Azure AD tokens (the OID won't match):

```bash
curl -s -X POST "http://127.0.0.1:4000/key/delete" \
  -H "Authorization: Bearer $PROXY_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"keys":["sk-old-key-1","sk-old-key-2"]}'
```

---

## Quick Reference

### Making an inference request

```bash
curl -X POST "http://127.0.0.1:4000/v1/chat/completions" \
  -H "Authorization: Bearer $VIRTUAL_KEY" \
  -H "X-Identity-Token: $AZURE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemini-flash",
    "messages": [{"role": "user", "content": "hello"}],
    "max_tokens": 10
  }'
```

Two tokens required:
1. `Authorization: Bearer <virtual-key>` — LiteLLM virtual key for model access / budget / spend
2. `X-Identity-Token: <azure-jwt>` — Azure AD JWT proving the caller's identity

### Refreshing expired tokens

Azure AD tokens expire after ~1 hour. Refresh:

```bash
AZURE_TOKEN=$(az account get-access-token \
  --resource "api://1e959ea2-a6a1-4c58-a413-a0b7e7fa71fe" \
  --query accessToken -o tsv)
```

### Accessing the Admin UI

```bash
# Port-forward if not already active
kubectl port-forward -n litellm svc/litellm 4000:4000

# Open http://127.0.0.1:4000/ui
# Login with username: admin, password: <PROXY_MASTER_KEY value>
```

The UI does not require a JWT — it uses session keys internally.

### Key environment variables summary

| Variable | Source | Usage |
|----------|--------|-------|
| `PROXY_MASTER_KEY` | Kubernetes secret | Admin operations, bypass auth |
| `JWT_JWKS_URL` | ConfigMap | Azure AD public key endpoint |
| `JWT_ISSUER` | ConfigMap | Expected token issuer |
| `JWT_AUDIENCE` | ConfigMap | Expected token audience (app client ID) |
| `JWT_HEADER_NAME` | ConfigMap | Header carrying the identity JWT |
| `KYVERNO_AUTHZ_URL` | Defaults in code | Kyverno server URL for policy checks |
