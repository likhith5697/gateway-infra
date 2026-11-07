#!/usr/bin/env python3
"""Mint JWTs for MANUAL TESTING of the authorizer. Standard library only.

Examples:
  export JWT_SECRET=dev-secret JWT_ISSUER=https://auth.example.local
  python make_token.py                         # valid HS256 token, 1 hour
  python make_token.py --ttl -60               # already expired
  python make_token.py --iss https://evil      # wrong issuer
  python make_token.py --alg none              # unsigned token (must be rejected)

  curl -H "Authorization: Bearer $(python make_token.py)" https://<api-id>.execute-api.us-east-2.amazonaws.com/orders

Prints only the token. Don't use this to issue real production tokens.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def make_token(
    secret: str,
    iss: str,
    sub: str = "test-user",
    ttl: int = 3600,
    alg: str = "HS256",
    now: int | None = None,
    extra_claims: dict | None = None,
) -> str:
    now = int(time.time()) if now is None else now
    header = {"alg": alg, "typ": "JWT"}
    claims = {"iss": iss, "sub": sub, "iat": now, "exp": now + ttl, **(extra_claims or {})}
    signing_input = f"{b64url(json.dumps(header, separators=(',', ':')).encode())}." \
                    f"{b64url(json.dumps(claims, separators=(',', ':')).encode())}"
    if alg == "none":
        return signing_input + "."  # unsigned: empty signature segment
    if alg != "HS256":
        raise ValueError("only HS256 and none are supported")
    sig = hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest()
    return f"{signing_input}.{b64url(sig)}"


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Mint a test JWT for the Lambda authorizer.")
    p.add_argument("--secret", default=os.environ.get("JWT_SECRET"), help="default: $JWT_SECRET")
    p.add_argument("--iss", default=os.environ.get("JWT_ISSUER"), help="default: $JWT_ISSUER")
    p.add_argument("--sub", default="test-user")
    p.add_argument("--ttl", type=int, default=3600, help="seconds until exp; negative = expired")
    p.add_argument("--alg", default="HS256", choices=["HS256", "none"])
    args = p.parse_args(argv)

    if args.alg == "HS256" and not args.secret:
        p.error("--secret or JWT_SECRET is required")
    if not args.iss:
        p.error("--iss or JWT_ISSUER is required")

    print(make_token(args.secret or "", args.iss, args.sub, args.ttl, args.alg))
    return 0


if __name__ == "__main__":
    sys.exit(main())
