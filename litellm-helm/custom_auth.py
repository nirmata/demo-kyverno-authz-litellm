import httpx
from fastapi import Request, HTTPException
from litellm.proxy._types import UserAPIKeyAuth

async def user_api_key_auth(request: Request, api_key: str) -> UserAPIKeyAuth:
    # 1. Get request body
    body = await request.json()
    
    # 2. Prepare payload for OPA
    kyverno_auth_input = {
        "input": {
            "token": api_key,
            "model": body.get("model"),
            "user": body.get("user", "unknown"),
            "path": request.url.path
        }
    }

    # 3. Call OPA (assuming OPA is running at localhost:8181)
    async with httpx.AsyncClient() as client:
        response = await client.post("http://kyverno-auth-service.kyverno.svc.cluster.local:9081", json=kyverno_auth_input)
        result = response.json()

    # 4. Check OPA decision
    if result.get("result", {}).get("allow") is not True:
        raise HTTPException(status_code=403, detail="Blocked by Kyverno Policy")

    # 5. Return auth object if allowed
    return UserAPIKeyAuth(api_key=api_key)