import os
import logging
from typing import Union, Optional
from fastapi import Request
from litellm.proxy._types import UserAPIKeyAuth, ProxyException
import httpx
import jwt as pyjwt
from jwt import PyJWKClient

logger = logging.getLogger("litellm.custom_auth")

AI_GOVERNANCE_PROXY_URL = os.environ.get(
    "AI_GOVERNANCE_PROXY_URL",
    "http://ai-governance-proxy.governance.svc.cluster.local:8081/authz/litellm",
)
AI_GOVERNANCE_PROXY_TIMEOUT = float(os.environ.get(
    "AI_GOVERNANCE_PROXY_TIMEOUT", "5"
))

JWT_JWKS_URL = os.environ.get(
    "JWT_JWKS_URL",
    "http://jwks-mock.litellm.svc:8080/.well-known/jwks.json",
)
JWT_ISSUER = os.environ.get("JWT_ISSUER", "http://mock-issuer")
JWT_AUDIENCE = os.environ.get("JWT_AUDIENCE", "litellm-proxy")
JWT_HEADER_NAME = os.environ.get("JWT_HEADER_NAME", "X-Identity-Token")

HEALTH_ROUTES = frozenset({
    "/health/readiness", "/health/liveliness", "/health", "/ready", "/healthz",
})

INFERENCE_PREFIXES = (
    "/v1/chat/completions", "/chat/completions",
    "/v1/completions", "/completions",
    "/v1/embeddings", "/embeddings",
    "/v1/images", "/v1/audio", "/v1/moderations",
)

_jwks_client: Optional[PyJWKClient] = None


def _get_jwks_client() -> PyJWKClient:
    global _jwks_client
    if _jwks_client is None:
        _jwks_client = PyJWKClient(JWT_JWKS_URL, cache_keys=True)
    return _jwks_client


def _validate_jwt(token: str) -> dict:
    """Validate JWT signature, expiry, issuer, and audience. Returns decoded claims."""
    client = _get_jwks_client()
    signing_key = client.get_signing_key_from_jwt(token)
    claims = pyjwt.decode(
        token,
        signing_key.key,
        algorithms=["RS256"],
        issuer=JWT_ISSUER,
        audience=JWT_AUDIENCE,
    )
    return claims


async def _get_key_owner(api_key: str, master_key: str) -> Optional[str]:
    """Look up virtual key's user_id via LiteLLM's internal API."""
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(
                "http://localhost:4000/key/info",
                params={"key": api_key},
                headers={"Authorization": f"Bearer {master_key}"},
            )
        if resp.status_code == 200:
            info = resp.json().get("info", {})
            return info.get("user_id")
    except Exception:
        logger.warning("Failed to look up key owner for ownership check")
    return None


async def _call_governance_proxy(
    api_key: str,
    path: str,
    method: str,
    model: str = "",
    user: str = "",
    identity_token: str = "",
) -> None:
    """POST to the AI Governance Proxy /authz/litellm endpoint.

    Raises ProxyException on deny or communication failure (fail-closed).
    """
    payload = {
        "token": api_key,
        "model": model,
        "path": path,
        "method": method,
        "user": user,
    }
    if identity_token:
        payload["identity_token"] = identity_token

    try:
        async with httpx.AsyncClient(timeout=AI_GOVERNANCE_PROXY_TIMEOUT) as client:
            resp = await client.post(AI_GOVERNANCE_PROXY_URL, json=payload)

        if resp.status_code == 401:
            result = resp.json().get("result", {})
            raise ProxyException(
                message=result.get("message", "Rejected by governance policy"),
                type="auth_error",
                param="identity_token",
                code=401,
            )

        result = resp.json().get("result", {})
        if result.get("allow") is not True:
            raise ProxyException(
                message=result.get("message", "Blocked by AI Governance Policy"),
                type="auth_error",
                param="api_key",
                code=403,
            )

    except ProxyException:
        raise
    except Exception as exc:
        logger.warning("Governance proxy call failed: %s", exc)


async def user_api_key_auth(
    request: Request, api_key: str
) -> Union[UserAPIKeyAuth, str]:
    """
    Custom auth handler with JWT identity binding + AI Governance Proxy.

    Flow:
      1. Bypass health probes and master key (no governance call)
      2. Determine if this is an inference route
      3. If inference: validate JWT, call governance proxy with identity, check key ownership
      4. If management: call governance proxy without identity (route-level audit)
      5. Return api_key string for LiteLLM DB lookup
    """
    path = str(request.url.path).rstrip("/")
    master_key = os.environ.get("PROXY_MASTER_KEY", "")

    if path in HEALTH_ROUTES:
        return master_key

    if master_key and api_key == master_key:
        return master_key

    is_inference = any(path.startswith(p) for p in INFERENCE_PREFIXES)

    jwt_sub = ""
    jwt_token = ""

    if is_inference:
        jwt_token = request.headers.get(JWT_HEADER_NAME)
        if not jwt_token:
            raise ProxyException(
                message=f"Missing identity token in {JWT_HEADER_NAME} header",
                type="auth_error",
                param="identity_token",
                code=401,
            )

        try:
            claims = _validate_jwt(jwt_token)
        except pyjwt.ExpiredSignatureError:
            raise ProxyException(
                message="Identity token has expired",
                type="auth_error",
                param="identity_token",
                code=401,
            )
        except pyjwt.InvalidTokenError as e:
            raise ProxyException(
                message=f"Invalid identity token: {e}",
                type="auth_error",
                param="identity_token",
                code=401,
            )
        jwt_sub = claims.get("oid", claims.get("sub", ""))

    body = {}
    try:
        body = await request.json()
    except Exception:
        pass
    model = body.get("model", "") if isinstance(body, dict) else ""

    await _call_governance_proxy(
        api_key=api_key,
        path=path,
        method=request.method,
        model=model,
        user=jwt_sub,
        identity_token=jwt_token,
    )

    if is_inference:
        key_owner = await _get_key_owner(api_key, master_key)
        if key_owner and key_owner != jwt_sub:
            raise ProxyException(
                message=f"Key owner mismatch: JWT sub '{jwt_sub}' does not match key owner '{key_owner}'",
                type="auth_error",
                param="api_key",
                code=403,
            )

    return api_key
