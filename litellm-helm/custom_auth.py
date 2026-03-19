import os
import logging
import base64
import json
from typing import Union, Optional
from fastapi import Request
from litellm.proxy._types import UserAPIKeyAuth, ProxyException
import httpx

logger = logging.getLogger("litellm.custom_auth")

KYVERNO_AUTHZ_URL = os.environ.get(
    "KYVERNO_AUTHZ_URL",
    "http://kyverno-authz-server.kyverno.svc.cluster.local:9081",
)

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


def _decode_jwt_payload(token: str) -> dict:
    """Decode JWT payload without signature verification.

    Safe to call after Kyverno has already validated the token's
    signature, expiry, and issuer via jwks.Fetch + jwt.Decode.
    We only need the claims for the key ownership check.
    """
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return {}
        payload = parts[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return {}


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
    Custom auth handler — JWT validation offloaded to Kyverno.

    Kyverno ValidatingPolicy now handles:
      - JWT signature verification via jwks.Fetch + jwt.Decode
      - JWT expiry validation
      - Enforcing that inference routes carry a valid X-Identity-Token
      - Allowing management/UI routes with just a Bearer token

    custom_auth.py handles:
      1. Health probe and master key bypass (before Kyverno)
      2. Forwarding the raw request (with X-Identity-Token) to Kyverno
      3. Key ownership check: JWT sub/oid must match key's user_id (inference only)
      4. Returning api_key string for LiteLLM DB lookup
    """
    path = str(request.url.path).rstrip("/")
    master_key = os.environ.get("PROXY_MASTER_KEY", "")

    if path in HEALTH_ROUTES:
        return master_key

    if master_key and api_key == master_key:
        return master_key

    is_inference = any(path.startswith(p) for p in INFERENCE_PREFIXES)

    # Forward request to Kyverno for policy evaluation + JWT validation
    try:
        body = b""
        try:
            body = await request.body()
        except Exception:
            pass

        raw_request = _build_raw_http_request(request, body, api_key=api_key)

        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.post(
                KYVERNO_AUTHZ_URL,
                content=raw_request,
                headers={"Content-Type": "application/octet-stream"},
            )

        if response.status_code != 200:
            detail = response.text.strip()
            code = 403
            if "Missing identity token" in detail or "Invalid identity token" in detail:
                code = 401
            jwt_err_signals = ("jwt.Parse", "jwt.Decode", "jws.Verify", "jws.Parse")
            if any(sig in detail for sig in jwt_err_signals):
                detail = "Invalid identity token"
                code = 401
            raise ProxyException(
                message=detail or "Rejected by Kyverno policy",
                type="auth_error",
                param="api_key",
                code=code,
            )

    except ProxyException:
        raise

    except Exception:
        pass

    # Key ownership check — inference routes only
    # JWT signature was already validated by Kyverno; we just read the claims
    if is_inference:
        jwt_token = request.headers.get(JWT_HEADER_NAME, "")
        claims = _decode_jwt_payload(jwt_token)
        jwt_sub = claims.get("oid", claims.get("sub", ""))

        if jwt_sub:
            key_owner = await _get_key_owner(api_key, master_key)
            if key_owner and key_owner != jwt_sub:
                raise ProxyException(
                    message=f"Key owner mismatch: JWT sub '{jwt_sub}' does not match key owner '{key_owner}'",
                    type="auth_error",
                    param="api_key",
                    code=403,
                )

    return api_key


def _build_raw_http_request(
    request: Request, body: bytes, api_key: str = ""
) -> bytes:
    """
    Reconstruct raw HTTP/1.1 request for Kyverno nestedRequest: true.

    Forwards all original headers (including X-Identity-Token for JWT validation)
    except Authorization, which is reconstructed from the api_key parameter
    because LiteLLM strips the token from the original header.
    """
    lines = []
    lines.append(f"{request.method} {request.url.path} HTTP/1.1")
    lines.append(f"Authorization: Bearer {api_key}")
    for key, value in request.headers.items():
        if key.lower() == "authorization":
            continue
        lines.append(f"{key}: {value}")
    header_block = "\r\n".join(lines) + "\r\n\r\n"
    return header_block.encode("latin-1") + body
