"""Lambda authorizer for API Gateway HTTP API (payload format 2.0, simple responses).

Expects:  Authorization: Bearer <JWT>
Verifies: HS256 signature (JWT_SECRET), exp (required), nbf (if present), iss == JWT_ISSUER.
Returns:  {"isAuthorized": true} or {"isAuthorized": false}

Fails closed: any error, missing input or unexpected shape returns false.
Never logs the token, the Authorization header, the secret or the event.
Standard library only.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import logging
import os
import re
import time

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ALLOWED_ALG = "HS256"
MAX_TOKEN_LENGTH = 8192          # bigger tokens are rejected before any parsing
CLOCK_SKEW_SECONDS = 30          # tolerance for exp / nbf
_B64URL = re.compile(r"^[A-Za-z0-9_-]+$")

DENY = {"isAuthorized": False}
ALLOW = {"isAuthorized": True}


class Reject(Exception):
    """Raised with a short, token-free reason code."""


def _b64url_decode(segment: str) -> bytes:
    if not _B64URL.match(segment):
        raise Reject("bad_base64")
    try:
        return base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4))
    except (binascii.Error, ValueError):
        raise Reject("bad_base64") from None


def _no_duplicate_keys(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise Reject("duplicate_json_key")  # e.g. two "alg" keys; parsers disagree on which wins
    return dict(pairs)


def _json_object(raw: bytes) -> dict:
    try:
        obj = json.loads(raw.decode("utf-8"), object_pairs_hook=_no_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise Reject("bad_json") from None
    if not isinstance(obj, dict):
        raise Reject("bad_json")
    return obj


def _get_authorization_header(event) -> str:
    if not isinstance(event, dict):
        raise Reject("bad_event")
    headers = event.get("headers")
    if not isinstance(headers, dict):
        raise Reject("no_headers")
    # HTTP API v2 lower-cases header names, but match case-insensitively to be safe.
    values = [v for k, v in headers.items() if isinstance(k, str) and k.lower() == "authorization"]
    if len(values) != 1 or not isinstance(values[0], str) or not values[0]:
        raise Reject("no_authorization_header")
    return values[0]


def _extract_bearer(header: str) -> str:
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token or token != token.strip() or " " in token:
        raise Reject("not_bearer")
    if len(token) > MAX_TOKEN_LENGTH:
        raise Reject("token_too_long")
    return token


def _is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def verify_token(token: str, secret: str, issuer: str, now: float | None = None) -> dict:
    """Return the claims if the token is valid, else raise Reject."""
    parts = token.split(".")
    if len(parts) != 3 or not all(parts):
        raise Reject("malformed_token")  # also rejects "x.y." (alg=none tokens have an empty signature)
    header_b64, payload_b64, sig_b64 = parts

    header = _json_object(_b64url_decode(header_b64))
    # Exact match: rejects "none", "None", "HS512", "RS256" (algorithm confusion) and missing alg.
    if header.get("alg") != ALLOWED_ALG:
        raise Reject("bad_alg")
    if "crit" in header:
        raise Reject("unsupported_crit")

    # Verify the signature BEFORE trusting anything in the payload.
    expected = hmac.new(
        secret.encode("utf-8"), f"{header_b64}.{payload_b64}".encode("ascii"), hashlib.sha256
    ).digest()
    if not hmac.compare_digest(expected, _b64url_decode(sig_b64)):
        raise Reject("bad_signature")

    claims = _json_object(_b64url_decode(payload_b64))
    now = time.time() if now is None else now

    exp = claims.get("exp")
    if not _is_number(exp):
        raise Reject("missing_exp")
    if now >= exp + CLOCK_SKEW_SECONDS:
        raise Reject("expired")

    nbf = claims.get("nbf")
    if nbf is not None and (not _is_number(nbf) or now < nbf - CLOCK_SKEW_SECONDS):
        raise Reject("not_yet_valid")

    iss = claims.get("iss")
    if not isinstance(iss, str) or not hmac.compare_digest(iss.encode(), issuer.encode()):
        raise Reject("bad_issuer")

    return claims


def lambda_handler(event, context):
    try:
        secret = os.environ.get("JWT_SECRET", "")
        issuer = os.environ.get("JWT_ISSUER", "")
        if not secret or not issuer:
            raise Reject("missing_config")

        token = _extract_bearer(_get_authorization_header(event))
        claims = verify_token(token, secret, issuer)

        sub = claims.get("sub")
        logger.info("authorized sub=%s", sub if isinstance(sub, str) else "-")
        return dict(ALLOW)
    except Reject as r:
        logger.info("denied reason=%s", r)
        return dict(DENY)
    except Exception as exc:  # fail closed on anything unexpected; log only the type, never values
        logger.warning("denied reason=internal_error type=%s", type(exc).__name__)
        return dict(DENY)
