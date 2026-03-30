# Architecture Diagrams — LiteLLM + AI Governance Proxy + Azure AD

This demo wires **LiteLLM** (custom image with `custom_auth.py`) to an **AI Governance Proxy** deployed via **`governance-helm`** and **`values-authz.yml`**. Identity tokens are **Azure AD** JWTs; policy is **CEL** (Kyverno-flavored) evaluated in the proxy on **`POST /authz/litellm`**.

---

## 1. Kubernetes deployment topology

Pods run in two namespaces. External dependencies are Azure AD (JWKS + token issuance) and upstream LLM APIs.

```mermaid
flowchart TB
    subgraph clients["Clients"]
        CLI[CLI / apps / UI]
    end

    subgraph ext["External"]
        AAD["Azure AD Entra ID\n(JWKS + tokens)"]
        UP["Upstream LLMs\nGemini · Anthropic · …"]
    end

    subgraph ns_litellm["Namespace: litellm"]
        LLM["LiteLLM proxy\n(custom_auth.py)"]
        PG[("PostgreSQL\nkeys · teams · spend")]
        RD[("Redis\ncache")]
        LLM --- PG
        LLM --- RD
    end

    subgraph ns_gov["Namespace: governance"]
        GP["AI Governance Proxy\n:8081 /authz/litellm\n(values-authz.yml)"]
    end

    CLI -->|"Authorization: Bearer sk-…\nX-Identity-Token: JWT"| LLM
    LLM -->|"PyJWT + JWKS"| AAD
    LLM -->|"HTTP JSON\nPOST …:8081/authz/litellm"| GP
    GP -->|"OIDC / policy context"| AAD
    LLM --> UP
```

**Service DNS (in-cluster default):** `http://ai-governance-proxy.governance.svc.cluster.local:8081` — override with env **`AI_GOVERNANCE_PROXY_URL`** on LiteLLM if needed.

---

## 2. Inference request path (sequence)

For **`/v1/chat/completions`** (and other inference prefixes), `custom_auth.py` validates the identity JWT, asks the governance proxy for allow/deny, then enforces **virtual key ownership** (`JWT oid` == key `user_id`) before LiteLLM continues.

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant L as LiteLLM
    participant H as custom_auth.py
    participant J as Azure AD JWKS
    participant G as AI Governance Proxy
    participant D as LiteLLM DB
    participant P as LLM provider

    C->>L: POST /v1/chat/completions\nBearer sk-… + X-Identity-Token
    L->>H: user_api_key_auth
    H->>J: Verify JWT signature, iss, aud, exp
    J-->>H: Claims: oid, groups, …
    H->>G: POST /authz/litellm\n(token, model, path, identity_token)
    G-->>H: { allow: true } or 401
    H->>D: key owner lookup (oid vs user_id)
    H-->>L: Return api_key string
    L->>D: Authorize key: model, budget, team
    L->>P: Forward completion request
    P-->>C: Response
```

---

## 3. Authorization layers (logical)

```mermaid
flowchart LR
    subgraph L1["1 · Identity"]
        A1["Azure OIDC\nPyJWT + JWKS"]
    end
    subgraph L2["2 · Policy"]
        A2["Governance proxy\nCEL on /authz/litellm"]
    end
    subgraph L3["3 · Ownership"]
        A3["custom_auth.py\noid ↔ key.user_id"]
    end
    subgraph L4["4 · Access"]
        A4["LiteLLM\nmodels · budget · teams"]
    end
    A1 --> A2 --> A3 --> A4
```

---

## 4. Helm and config touchpoints (no cluster Kyverno)

```mermaid
flowchart LR
    subgraph helm_litellm["litellm-helm"]
        V1["values.yaml\nimage · custom_auth · secrets"]
    end
    subgraph helm_gov["governance-helm"]
        V2["values-authz.yml\nproxy.image · oidcProviders · litellmPolicies"]
    end
    subgraph images["Images"]
        I1["litellm-custom-auth\nDockerfile + custom_auth.py"]
        I2["ai-governance-proxy\nai-governance-proxy/Dockerfile"]
    end
    I1 --> V1
    I2 --> V2
```

This stack does **not** install **Kyverno admission** or **`kyverno-authz-server`**; policy runs **inside** the governance proxy process.

---

## 5. Full stack — like `governance-helm/architecture.png` (LiteLLM + authz)

This matches the **Helm chart** poster layout: MCP agents on `:8080`, six-stage pipeline inside the proxy, SQLite + ConfigMap policies, Postgres/Prometheus MCP backends, Prometheus scrape, Web UI on `:8081`, **plus** the **LiteLLM** namespace and **`POST /authz/litellm`** from `custom_auth.py` and **Azure AD** for OIDC.

```mermaid
flowchart TB
    subgraph z_clients["Clients"]
        direction TB
        REST["API / UI clients\nBearer sk- + X-Identity-Token"]
        MCP_AGENTS["AI agents MCP\nClaude · Cursor · custom"]
    end

    subgraph z_azure["Identity"]
        AAD["Azure AD Entra ID\nJWKS + OIDC"]
    end

    subgraph ns_litellm["Namespace: litellm"]
        direction TB
        LLM["LiteLLM proxy\ncustom_auth.py · PyJWT"]
        LSTORE[("PostgreSQL\nkeys · teams · spend")]
        LREDIS[("Redis")]
        LLM --- LSTORE
        LLM --- LREDIS
    end

    subgraph ns_gov["Namespace: governance — AI Governance Proxy"]
        direction TB
        IMG["anuddeeph/ai-governance-proxy:v2-sse-fix\nproxy.mode authz-provider"]
        PORTS["Ports: :8080 MCP/SSE · :8081 Admin UI + /authz/litellm · :9081 gRPC authz · :9082 HTTP authz"]
        ST1["1 Identity OIDC / CEL"]
        ST2["2 Policy Kyverno CEL"]
        ST3["3 HITL gate"]
        ST4["4 Tool response cache"]
        ST5["5 Forward to MCP backend"]
        ST6["6 Audit + Prometheus metrics"]
        IMG --> PORTS
        PORTS --> ST1
        ST1 --> ST2 --> ST3 --> ST4 --> ST5 --> ST6
        SQLITE[("SQLite\naudit · HITL queue")]
        POL["ConfigMap Kyverno CEL policies\n+ values-authz litellmPolicies"]
        ST6 --- SQLITE
        ST2 --- POL
    end

    subgraph z_mcp_back["MCP backends Helm chart"]
        direction TB
        PG_MCP["Postgres MCP SSE"]
        PG_DB[("PostgreSQL 16")]
        PROM_MCP["Prometheus MCP SSE"]
        PROM_TS[("Prometheus TSDB")]
        PG_MCP --> PG_DB
        PROM_MCP --> PROM_TS
    end

    subgraph z_llm_up["Upstream LLM APIs"]
        UP["Gemini · Anthropic · …"]
    end

    subgraph z_admin["Web UI / ops"]
        UI["Browser: policies · audit log · HITL approvals · health"]
    end

    REST --> LLM
    LLM -->|"JWT verify"| AAD
    LLM -->|"POST :8081 /authz/litellm"| ST2
    MCP_AGENTS -->|":8080 tools/call SSE"| ST1
    ST5 --> PG_MCP
    ST5 --> PROM_MCP
    LLM --> UP
    PROM_TS -->|"/metrics scrape"| ST6
    UI -->|":8081"| ST6
```

**PNG (high level, same content):** [`diagrams/05-full-stack-litellm-governance.png`](diagrams/05-full-stack-litellm-governance.png) — also copied as [`governance-helm/architecture-litellm-authz.png`](governance-helm/architecture-litellm-authz.png) next to the original [`governance-helm/architecture.png`](governance-helm/architecture.png).

---

## PNG exports (static assets)

Pre-rendered PNGs live in [`diagrams/`](diagrams/):

| Diagram | PNG |
|--------|-----|
| 1. Kubernetes topology | [`diagrams/01-topology.png`](diagrams/01-topology.png) |
| 2. Inference sequence | [`diagrams/02-sequence.png`](diagrams/02-sequence.png) |
| 3. Authorization layers | [`diagrams/03-layers.png`](diagrams/03-layers.png) |
| 4. Helm / images | [`diagrams/04-helm.png`](diagrams/04-helm.png) |
| 5. Full stack (Helm poster + LiteLLM + Azure) | [`diagrams/05-full-stack-litellm-governance.png`](diagrams/05-full-stack-litellm-governance.png) · [`governance-helm/architecture-litellm-authz.png`](governance-helm/architecture-litellm-authz.png) |

Source for re-rendering: matching `.mmd` files in the same folder (e.g. `npx @mermaid-js/mermaid-cli mmdc -i diagrams/01-topology.mmd -o diagrams/01-topology.png`, or [kroki.io](https://kroki.io) `POST /mermaid/png`).

---

## Rendering

- **GitHub / GitLab:** Mermaid renders in Markdown previews; PNGs above work anywhere (slides, docs, Confluence uploads).
- **VS Code / Cursor:** Use a Mermaid preview extension, or paste diagrams into [mermaid.live](https://mermaid.live).
