import os
from typing import Union
from fastapi import Request
from litellm.proxy._types import UserAPIKeyAuth, ProxyException
import httpx


KYVERNO_AUTHZ_URL = os.environ.get(
    "KYVERNO_AUTHZ_URL",
    "http://kyverno-authz-server.kyverno.svc.cluster.local:9081",
)

HEALTH_ROUTES = frozenset({
    "/health/readiness", "/health/liveliness", "/health", "/ready", "/healthz",
})


async def user_api_key_auth(
    request: Request, api_key: str
) -> Union[UserAPIKeyAuth, str]:
    """
    Custom auth handler — replaces LiteLLM's built-in auth entirely (OSS mode).

    Returns the api_key STRING in all success paths so that LiteLLM's internal
    auth resolves roles (master key -> PROXY_ADMIN, virtual key -> DB lookup).

    Kyverno HTTP mode with nestedRequest: true — we reconstruct the original
    HTTP/1.1 request as raw bytes and POST them to Kyverno's root endpoint.
    Kyverno parses these bytes via Go's httputil.ReadRequest to evaluate policies.
    """
    path = str(request.url.path).rstrip("/")
    master_key = os.environ.get("PROXY_MASTER_KEY", "")

    if path in HEALTH_ROUTES:
        return master_key

    if master_key and api_key == master_key:
        return master_key

    try:
        body = b""
        try:
            body = await request.body()
        except Exception:
            pass

        raw_request = _build_raw_http_request(request, body)

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
        pass

    return api_key


def _build_raw_http_request(request: Request, body: bytes) -> bytes:
    """
    Reconstruct a raw HTTP/1.1 request for Kyverno nestedRequest: true.
    Go's httputil.ReadRequest expects real CRLF (0x0D 0x0A), NOT literal backslash-r-backslash-n.
    """
    lines = []
    lines.append(f"{request.method} {request.url.path} HTTP/1.1")
    for key, value in request.headers.items():
        lines.append(f"{key}: {value}")
    header_block = "\r\n".join(lines) + "\r\n\r\n"
    return header_block.encode("latin-1") + body
