import os
import logging
from typing import Union, Optional
from fastapi import Request
from litellm.proxy._types import UserAPIKeyAuth, ProxyException
import httpx
import jwt as pyjwt
from jwt import PyJWKClient

logger = logging.getLogger("litellm.custom_auth")

KYVERNO_AUTHZ_URL = os.environ.get(
    "KYVERNO_AUTHZ_URL",
    "http://kyverno-authz-server.kyverno.svc.cluster.local:9081",
)

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


async def user_api_key_auth(
    request: Request, api_key: str
) -> Union[UserAPIKeyAuth, str]:
    """
    Custom auth handler with JWT identity binding (Phase 1).

    Flow:
      1. Bypass health probes and master key (no JWT required)
      2. Validate JWT from X-Identity-Token header (signature, exp, iss, aud)
      3. Forward request + JWT claims to Kyverno for policy evaluation
      4. Verify key ownership: JWT sub must match the virtual key's user_id
      5. Return api_key string for LiteLLM DB lookup
    """
    path = str(request.url.path).rstrip("/")
    master_key = os.environ.get("PROXY_MASTER_KEY", "")

    # 1. Health probes — kubelet sends no tokens
    if path in HEALTH_ROUTES:
        return master_key

    # 2. Master key — admin bypass, no JWT required
    if master_key and api_key == master_key:
        return master_key

    # 3. Validate JWT identity token
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

    jwt_sub = claims.get("sub", "")
    jwt_groups = claims.get("groups", [])
    jwt_email = claims.get("email", "")

    # 4. Call Kyverno — inject JWT claims as headers for policy evaluation
    try:
        body = b""
        try:
            body = await request.body()
        except Exception:
            pass

        raw_request = _build_raw_http_request(request, body, api_key=api_key, extra_headers={
            "X-Jwt-Sub": jwt_sub,
            "X-Jwt-Email": jwt_email,
            "X-Jwt-Groups": ",".join(jwt_groups) if jwt_groups else "",
        })

        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.post(
                KYVERNO_AUTHZ_URL,
                content=raw_request,
                headers={"Content-Type": "application/octet-stream"},
            )

        if response.status_code != 200:
            raise ProxyException(
                message=f"Rejected by Kyverno policy: {response.text}",
                type="auth_error",
                param="api_key",
                code=403,
            )

    except ProxyException:
        raise

    except Exception:
        # Kyverno unreachable — fall through to LiteLLM virtual key lookup
        pass

    # 5. Key ownership check — JWT sub must match virtual key's user_id
    key_owner = await _get_key_owner(api_key, master_key)
    if key_owner and key_owner != jwt_sub:
        raise ProxyException(
            message=f"Key owner mismatch: JWT sub '{jwt_sub}' does not match key owner '{key_owner}'",
            type="auth_error",
            param="api_key",
            code=403,
        )

    # 6. Return key string — LiteLLM hashes it, looks it up in DB,
    #    and enforces model/budget/team scoping
    return api_key


def _build_raw_http_request(
    request: Request, body: bytes, api_key: str = "", extra_headers: dict = None
) -> bytes:
    """
    Reconstruct raw HTTP/1.1 request for Kyverno nestedRequest: true.

    LiteLLM's middleware may strip or modify the Authorization header after
    extracting the token, so we skip it from request.headers and always
    inject a fresh one from the api_key parameter.
    """
    lines = []
    lines.append(f"{request.method} {request.url.path} HTTP/1.1")
    lines.append(f"Authorization: Bearer {api_key}")
    for key, value in request.headers.items():
        if key.lower() == "authorization":
            continue
        lines.append(f"{key}: {value}")
    if extra_headers:
        for key, value in extra_headers.items():
            lines.append(f"{key}: {value}")
    header_block = "\r\n".join(lines) + "\r\n\r\n"
    return header_block.encode("latin-1") + body
