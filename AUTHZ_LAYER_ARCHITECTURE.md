# Centralized Authorization and Token Management Layer

## Scope

This design centralizes identity, authorization, token governance, and budget controls for AI access across LiteLLM and other gateways.

---

## Azure OIDC (No Keycloak) Reference Flow

Use Azure AD (Entra ID) directly as the identity provider for users and groups.

1. User authenticates with Azure OIDC and gets a JWT.
2. Client calls gateway/proxy (LiteLLM) with identity token.
3. LiteLLM `custom_auth` forwards token + request context to AuthZ server.
4. AuthZ server validates token and evaluates policy (user/team/org/model/route/quota).
5. On allow, `custom_auth` returns scoped `UserAPIKeyAuth`.
6. LiteLLM executes request and logs spend tied to user/team/org.

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

1. AuthZ server calls Microsoft Graph using app credentials.
2. Fetches transitive group memberships for `oid`.
3. Applies team/org mapping and authorization policy.

Do not skip this check, or high-group users may bypass team binding.

---

## LiteLLM Integration Pattern

- Keep LiteLLM virtual keys as optional operational credentials.
- Treat Azure JWT as primary identity.
- `custom_auth.py` becomes the adapter that:
  - validates/forwards JWT to AuthZ server
  - receives allow/deny + scoped obligations
  - returns `UserAPIKeyAuth` with `user_id`, `team_id`, `org_id`, allowed models/routes, rpm/tpm, budget limits.

---

## Done Criteria for Phase 1

- A user cannot use another user's key.
- Team/org boundaries are enforced from Azure claims + mapping.
- Every request is traceable to Azure identity in audit logs.
- AuthZ decisions are externalized in central policy service.

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

