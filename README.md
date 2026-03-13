# Demo: Kyverno Authz with LiteLLM Proxy

This repository demonstrates integrating **Kyverno** policy-based authorization with the **LiteLLM** proxy. Every request to LiteLLM is first validated by a custom auth handler that calls a Kyverno HTTP authz service; only allowed requests reach the LLM backends.

## Architecture

```
Client → LiteLLM Proxy → custom_auth.py → Kyverno HTTP authz (:9081) → allow/deny
                              ↓
                    If allowed → LLM (e.g. Gemini)
```

- **LiteLLM Proxy**: Exposes a unified API for LLM models; uses custom auth for every request.
- **custom_auth**: Python module loaded by LiteLLM that forwards request context (token, model, path, etc.) to the authz service.
- **Kyverno**: Runs an HTTP validating policy server. It evaluates policies and returns allow/deny; LiteLLM blocks the request on deny.

## Repository layout

| Path | Description |
|------|-------------|
| **`Kyverno/`** | Kyverno ValidatingPolicy (HTTP mode) and Helm values. The policy server listens on port 9081. |
| **`litellm-helm/`** | Helm chart for LiteLLM proxy: deployment, config, and custom auth script. |

## Prerequisites

- Kubernetes cluster (1.21+)
- Helm 3.8+
- Kyverno installed with HTTP policy support (ValidatingPolicy in HTTP mode)
- (Optional) PV provisioner if using the chart’s built-in PostgreSQL

## Quick start

### 1. Install Kyverno and the policy server

Install [Kyverno](https://kyverno.io/docs/installation/) and enable HTTP policy evaluation. Apply the validating policy and deploy the Kyverno HTTP server so it listens on `:9081`:

```bash
# Install Kyverno (see https://kyverno.io/docs/installation/)
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno -n kyverno --create-namespace

# Apply the validating policy and ensure the authz service is available
kubectl apply -f Kyverno/validating-policy.yaml
helm upgrade --install kyverno-auth ./Kyverno -n kyverno -f Kyverno/values.yaml
```

Ensure the Kyverno HTTP authz service is reachable at `kyverno-auth-service.kyverno.svc.cluster.local:9081` (or update the URL in `litellm-helm/custom_auth.py` to match your setup).

### 2. Create the API key secret for LiteLLM

The proxy reads the model API key from a Kubernetes Secret (see `environmentSecrets` and `proxy_config` in `litellm-helm/values.yaml`):

```bash
kubectl create secret generic litellm-api-keys \
  --from-literal=GEMINI_API_KEY='your-gemini-api-key' \
  -n <namespace>
```

Create the master key secret if you use one (or let the chart generate it).

### 3. Deploy LiteLLM with the custom auth chart

Build the custom image (includes `httpx` for the auth handler) and install the chart:

```bash
cd litellm-helm
docker build -t <your-registry>/litellm-kyverno-auth:latest .
docker push <your-registry>/litellm-kyverno-auth:latest
```

In `values.yaml`, set `image.repository` and `image.tag` to your image. Then:

```bash
helm upgrade --install litellm . -n litellm --create-namespace -f values.yaml
```

The chart mounts `custom_auth.py` from the ConfigMap at `/etc/litellm/custom_auth.py` and sets `general_settings.custom_auth` so LiteLLM calls it on each request.

### 4. Point config to your auth handler

In `litellm-helm/values.yaml`, `proxy_config.general_settings.custom_auth` must match the function name in `custom_auth.py`. For example, if the function is `user_api_key_auth`:

```yaml
proxy_config:
  general_settings:
    custom_auth: custom_auth.user_api_key_auth
    custom_auth_settings:
      mode: "on"
```

Health endpoints (`/health/readiness`, `/health/liveliness`) can be excluded from auth in the handler so Kubernetes probes succeed.

## Configuration summary

| Component | Key setting | Purpose |
|-----------|--------------|---------|
| **LiteLLM** | `proxy_config.general_settings.custom_auth` | Module and function for custom auth (e.g. `custom_auth.user_api_key_auth`). |
| **LiteLLM** | `environmentSecrets` | Secret names whose keys are exposed as env vars; e.g. `GEMINI_API_KEY` for `api_key: os.environ/GEMINI_API_KEY`. |
| **LiteLLM** | `proxy_config.model_list[].litellm_params.api_key` | Use `os.environ/GEMINI_API_KEY` (or your env key) so the key comes from a Secret. |
| **custom_auth.py** | Authz URL | Default: `http://kyverno-auth-service.kyverno.svc.cluster.local:9081`. Change if your Kyverno HTTP service has a different name/port. |
| **Kyverno** | `validating-policy.yaml` | Defines allow/deny rules (path, method, token claims, etc.). |
| **Kyverno** | `values.yaml` (HTTP) | Configures the HTTP server (e.g. `address: :9081`). |

## Custom auth flow (custom_auth.py)

1. Receives `request` and `api_key` from LiteLLM.
2. Optionally skips auth for health paths so probes return 200.
3. Builds a payload (e.g. token, model, path) and POSTs it to the Kyverno authz URL.
4. If the response indicates **deny**, raises HTTP 403 (request blocked).
5. If **allow**, returns `UserAPIKeyAuth(api_key=api_key)` so LiteLLM continues to the LLM.

The authz service must speak HTTP and return a JSON body LiteLLM’s handler can interpret (e.g. an `allow` or `result.allow` field). If your Kyverno deployment uses gRPC (e.g. Envoy ext_authz), you need an HTTP-to-gRPC adapter or a different client in `custom_auth.py`.

## Development

- **LiteLLM chart**: See [litellm-helm/README.md](litellm-helm/README.md) for chart parameters, database options, and examples.
- **Custom auth deps**: Listed in [litellm-helm/requirements-custom-auth.txt](litellm-helm/requirements-custom-auth.txt); the Dockerfile installs them so the mounted `custom_auth.py` can use `httpx`.

## License

See repository license (if any). LiteLLM and Kyverno have their own licenses.
