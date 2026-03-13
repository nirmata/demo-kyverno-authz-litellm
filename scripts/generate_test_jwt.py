#!/usr/bin/env python3
"""
Generate RSA key pair, JWKS, and signed test JWTs for local testing.

Usage:
    pip install PyJWT[crypto]
    python scripts/generate_test_jwt.py

Outputs:
    scripts/keys/private.pem       — RSA private key (keep secret)
    scripts/keys/jwks.json         — JWKS public key set (deploy to mock endpoint)
    scripts/keys/user-a.jwt        — JWT for user-a (team-a member)
    scripts/keys/user-b.jwt        — JWT for user-b (team-b member)
    scripts/keys/user-c.jwt        — JWT for user-c (team-c member)
    scripts/keys/user-d.jwt        — JWT for user-d (team-d member)
"""

import json
import os
import sys
import time
import base64

try:
    import jwt
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.backends import default_backend
except ImportError:
    print("Install dependencies: pip install 'PyJWT[crypto]'")
    sys.exit(1)

KEYS_DIR = os.path.join(os.path.dirname(__file__), "keys")
ISSUER = "http://mock-issuer"
AUDIENCE = "litellm-proxy"
KID = "mock-key-1"
TOKEN_LIFETIME_SECONDS = 86400 * 30  # 30 days for testing convenience

USERS = [
    {"sub": "user-a", "email": "user-a@example.com", "groups": ["team-a"]},
    {"sub": "user-b", "email": "user-b@example.com", "groups": ["team-b"]},
    {"sub": "user-c", "email": "user-c@example.com", "groups": ["team-c"]},
    {"sub": "user-d", "email": "user-d@example.com", "groups": ["team-d"]},
]


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def generate_or_load_key():
    priv_path = os.path.join(KEYS_DIR, "private.pem")

    if os.path.exists(priv_path):
        with open(priv_path, "rb") as f:
            private_key = serialization.load_pem_private_key(f.read(), password=None, backend=default_backend())
        print(f"Loaded existing key from {priv_path}")
        return private_key

    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
        backend=default_backend(),
    )
    pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    with open(priv_path, "wb") as f:
        f.write(pem)
    print(f"Generated new RSA-2048 key → {priv_path}")
    return private_key


def build_jwks(private_key):
    pub = private_key.public_key()
    pub_numbers = pub.public_numbers()

    n_bytes = pub_numbers.n.to_bytes((pub_numbers.n.bit_length() + 7) // 8, byteorder="big")
    e_bytes = pub_numbers.e.to_bytes((pub_numbers.e.bit_length() + 7) // 8, byteorder="big")

    jwks = {
        "keys": [
            {
                "kty": "RSA",
                "kid": KID,
                "use": "sig",
                "alg": "RS256",
                "n": _b64url(n_bytes),
                "e": _b64url(e_bytes),
            }
        ]
    }
    jwks_path = os.path.join(KEYS_DIR, "jwks.json")
    with open(jwks_path, "w") as f:
        json.dump(jwks, f, indent=2)
    print(f"JWKS written → {jwks_path}")
    return jwks


def generate_jwt(private_key, user: dict) -> str:
    now = int(time.time())
    payload = {
        "iss": ISSUER,
        "aud": AUDIENCE,
        "sub": user["sub"],
        "email": user["email"],
        "groups": user["groups"],
        "iat": now,
        "exp": now + TOKEN_LIFETIME_SECONDS,
    }
    token = jwt.encode(payload, private_key, algorithm="RS256", headers={"kid": KID})
    return token


def main():
    os.makedirs(KEYS_DIR, exist_ok=True)

    private_key = generate_or_load_key()
    build_jwks(private_key)

    print()
    for user in USERS:
        token = generate_jwt(private_key, user)
        token_path = os.path.join(KEYS_DIR, f"{user['sub']}.jwt")
        with open(token_path, "w") as f:
            f.write(token)
        print(f"{user['sub']}: {token_path}")
        print(f"  JWT: {token[:60]}...")
        print()


if __name__ == "__main__":
    main()
