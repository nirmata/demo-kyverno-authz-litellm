# Centralized Authorization and Token Management Layer

## Scope

This design centralizes identity, authorization, token governance, and budget controls for AI access across LiteLLM and other gateways. The **AI Governance Proxy** (`ai-governance-proxy`) is the policy decision point for LiteLLM: it exposes `POST /authz/litellm`, validates the user JWT (Azure AD OIDC), evaluates **Kyverno CEL policies** in-process (not the cluster Kyverno admission stack), and returns allow/deny/audit to `custom_auth.py`.

---

## Azure OIDC (No Keycloak) Reference Flow

Use Azure AD (Entra ID) directly as the identity provider for users and groups.

1. User authenticates with Azure OIDC and gets a JWT.
2. Client calls LiteLLM with `Authorization: Bearer <virtual key>` and `X-Identity-Token: <Azure JWT>`.
3. LiteLLM `custom_auth.py` validates the JWT (JWKS, `iss`, `aud`, `exp`) and POSTs context to the **AI Governance Proxy** at `/authz/litellm` (JSON: token, model, path, method, identity token).
4. The governance proxy validates the identity token again for policy (CEL), evaluates policies (e.g. require user identity, model restrictions, audit), and returns `{ result: { allow, message } }`.
5. `custom_auth.py` enforces **virtual key ownership** (`oid` == key `user_id`) and returns the key string for LiteLLM DB lookup.
6. LiteLLM executes the request and logs spend tied to user/team/org.

---

## Identity and Group Source of Truth

- **Users:** Azure AD (claim: `oid`, with `preferred_username` / `email`)
- **Teams:** Azure AD groups (claim: `groups`) mapped to internal `team_id`
- **Org:** Azure tenant id (claim: `tid`) mapped to internal `org_id`

Internal mapping store (DynamoDB or Postgres):

- `azure_oid -> user_id`
- `azure_group_id -> team_id`
- `azure_tid -> org_id`
- optional model/route entitlements per team/org

---

## JWT Claim Mapping (Azure -> Internal)

| Azure Claim | Meaning | Internal Field |
| --- | --- | --- |
| `oid` | Stable user object id | `user_id` (via mapping) |
| `preferred_username` / `email` | User principal | `user_email` |
| `groups` | Group IDs | `team_id` list (via mapping) |
| `tid` | Tenant ID | `org_id` |
| `roles` (optional) | App roles | permissions / policy context |

---

## Required Enforcement Rules (Phase 1)

- deny if JWT missing
- deny if JWT invalid (`iss`, `aud`, `exp`, signature/JWKS)
- deny if user not mapped to allowed org/team
- deny if requested model/route not allowed by policy
- if virtual key is used, deny when key owner != JWT subject/team
- allow only least-privilege scopes from policy response

---

## Group Overage Handling

Azure may omit full `groups` in token for users with many groups.

When overage indicator is present:

1. The governance proxy or a sidecar can call Microsoft Graph using app credentials.
2. Fetch transitive group memberships for `oid`.
3. Apply team/org mapping and authorization policy (today many deployments rely on `groups` in the token only).

Do not skip this check, or high-group users may bypass team binding.

---

## LiteLLM Integration Pattern

- Keep LiteLLM virtual keys as operational credentials; bind them to Azure `oid` in the key record.
- Treat Azure JWT as primary identity on inference routes.
- `custom_auth.py` is the adapter that:
  - validates JWT (PyJWT + JWKS)
  - calls the governance proxy `/authz/litellm` for policy (fail-closed on HTTP errors is configurable; see code)
  - enforces key ownership (`oid` == `user_id`)
  - returns the API key string for LiteLLM’s internal auth (models, budget, teams).

---

## Done Criteria for Phase 1

- A user cannot use another user's virtual key (JWT `oid` binding).
- Team/org boundaries are enforced via LiteLLM teams/keys plus Azure claims where policies apply.
- Inference requests are traceable to Azure identity in the governance Web UI audit stream (`/api/v1/audit/events`).
- Policy decisions for LLM traffic are centralized in the **AI Governance Proxy** (CEL policies loaded from Helm values, e.g. `governance-helm/values-authz.yml`).

---

## Alternative: Keycloak as Identity Normalizer

If Keycloak is introduced as an identity broker in front of Azure AD, you can reduce separate mapping complexity.

### What can be removed or simplified

- Optional removal of dedicated `azure_oid/group/tid -> internal` mapping table in DynamoDB if Keycloak emits normalized claims directly.
- Fewer per-gateway claim transformations (Keycloak protocol mappers provide consistent claim shape).

### What still must exist

- Budget and quota state store (for user/team/org enforcement).
- Key ownership state (if virtual keys are used).
- Audit/event store for compliance and forensics.
- Central policy definitions and policy evaluation service.

### Recommended Keycloak claim contract

- `user_id` (stable internal identifier)
- `team_ids` (array)
- `org_id`
- `roles` / permissions
- optional entitlements (`allowed_models`, `allowed_routes`) for fast-path enforcement

### Tradeoff summary

- **Azure direct + mapping store:** fewer moving parts, more custom claim translation logic in your AuthZ layer.
- **Keycloak + normalized claims:** cleaner identity contract, but adds an extra critical identity component to operate.

