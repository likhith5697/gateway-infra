import hashlib
import hmac
import json
import logging
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from handler import lambda_handler  # noqa: E402
from make_token import b64url, make_token  # noqa: E402

SECRET = "unit-test-secret-0123456789abcdef"
ISSUER = "https://auth.example.test"
ALLOW = {"isAuthorized": True}
DENY = {"isAuthorized": False}


@pytest.fixture(autouse=True)
def env(monkeypatch):
    monkeypatch.setenv("JWT_SECRET", SECRET)
    monkeypatch.setenv("JWT_ISSUER", ISSUER)


def event_with(auth_value=None, **extra):
    """Minimal HTTP API v2 authorizer event (headers are lower-cased by API Gateway)."""
    headers = {"host": "api.example.test"}
    if auth_value is not None:
        headers["authorization"] = auth_value
    return {"version": "2.0", "type": "REQUEST", "routeArn": "arn:aws:execute-api:x", "headers": headers, **extra}


def bearer(token):
    return event_with(f"Bearer {token}")


def call(event):
    """Call the handler. An exception here fails the test: the handler must never raise."""
    result = lambda_handler(event, None)
    assert isinstance(result, dict) and set(result) == {"isAuthorized"}
    return result


# --- the cases from the spec -------------------------------------------------

def test_valid_token():
    assert call(bearer(make_token(SECRET, ISSUER))) == ALLOW


def test_expired_token():
    assert call(bearer(make_token(SECRET, ISSUER, ttl=-3600))) == DENY


def test_missing_header():
    assert call(event_with()) == DENY


@pytest.mark.parametrize("value", [
    "{token}",                 # no scheme
    "Basic {token}",           # wrong scheme
    "Token {token}",
    "Bearer",                  # scheme only
    "Bearer ",                 # scheme and a space
    "Bearer  {token}",         # double space
    "Bearer {token} extra",    # trailing junk
])
def test_header_without_bearer(value):
    assert call(event_with(value.format(token=make_token(SECRET, ISSUER)))) == DENY


@pytest.mark.parametrize("token", [
    "not-a-jwt",
    "a.b",
    "a.b.c.d",
    "..",
    "abc.def.",
    "!!!.@@@.###",
    "eyJhbGciOiJIUzI1NiJ9.e30",                         # two segments
    b64url(b"not json") + "." + b64url(b"{}") + "." + b64url(b"sig"),
    b64url(b"[1,2]") + "." + b64url(b"{}") + "." + b64url(b"sig"),   # header not an object
    "x" * 10000,                                         # oversized
])
def test_malformed_token(token):
    assert call(bearer(token)) == DENY


def test_wrong_signature():
    assert call(bearer(make_token("some-other-secret", ISSUER))) == DENY


def test_tampered_payload_fails_signature():
    h, _, s = make_token(SECRET, ISSUER, sub="alice").split(".")
    forged = b64url(json.dumps({"iss": ISSUER, "sub": "admin", "exp": int(time.time()) + 3600}).encode())
    assert call(bearer(f"{h}.{forged}.{s}")) == DENY


def test_wrong_issuer():
    assert call(bearer(make_token(SECRET, "https://evil.example"))) == DENY


@pytest.mark.parametrize("alg", ["none", "None", "NONE", "nOnE"])
def test_alg_none_token(alg):
    claims = b64url(json.dumps({"iss": ISSUER, "exp": int(time.time()) + 3600}).encode())
    header = b64url(json.dumps({"alg": alg, "typ": "JWT"}).encode())
    # unsigned form, and a "signed" form with a junk signature: both must be denied
    assert call(bearer(f"{header}.{claims}.")) == DENY
    assert call(bearer(f"{header}.{claims}.{b64url(b'x')}")) == DENY
    assert call(bearer(make_token(SECRET, ISSUER, alg="none"))) == DENY


@pytest.mark.parametrize("var", ["JWT_SECRET", "JWT_ISSUER"])
def test_secret_env_var_missing(monkeypatch, var):
    token = make_token(SECRET, ISSUER)
    monkeypatch.delenv(var)
    assert call(bearer(token)) == DENY
    monkeypatch.setenv(var, "")
    assert call(bearer(token)) == DENY


@pytest.mark.parametrize("event", [
    None, "", "garbage", 42, [], ["headers"], {},
    {"headers": None}, {"headers": "authorization: Bearer x"}, {"headers": []},
    {"headers": {"authorization": None}}, {"headers": {"authorization": 123}},
    {"headers": {"authorization": ["Bearer x"]}}, {"headers": {1: "Bearer x"}},
])
def test_garbage_event(event):
    assert call(event) == DENY


# --- extra hardening ---------------------------------------------------------

@pytest.mark.parametrize("alg", ["HS512", "HS384", "RS256", "ES256", "hs256", "", None])
def test_other_algs_rejected(alg):
    header = b64url(json.dumps({"alg": alg}).encode())
    h, p, s = make_token(SECRET, ISSUER).split(".")
    assert call(bearer(f"{header}.{p}.{s}")) == DENY


def test_missing_alg_rejected():
    _, p, s = make_token(SECRET, ISSUER).split(".")
    assert call(bearer(f"{b64url(b'{}')}.{p}.{s}")) == DENY


def test_duplicate_alg_key_rejected():
    header = b64url(b'{"alg":"none","alg":"HS256"}')
    _, p, s = make_token(SECRET, ISSUER).split(".")
    assert call(bearer(f"{header}.{p}.{s}")) == DENY


@pytest.mark.parametrize("claims", [
    {"iss": ISSUER},                               # no exp
    {"iss": ISSUER, "exp": "9999999999"},          # exp as string
    {"iss": ISSUER, "exp": True},                  # bool is not a number
    {"exp": 9999999999},                           # no iss
    {"iss": 123, "exp": 9999999999},               # iss not a string
    {"iss": ISSUER, "exp": 9999999999, "nbf": 9999999998},  # not valid yet
])
def test_bad_claims_rejected(claims):
    # Correctly signed, so only the claim checks can reject it.
    h = b64url(json.dumps({"alg": "HS256"}).encode())
    p = b64url(json.dumps(claims).encode())
    s = b64url(hmac.new(SECRET.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest())
    assert call(bearer(f"{h}.{p}.{s}")) == DENY


def test_lowercase_bearer_and_header_name_accepted():
    token = make_token(SECRET, ISSUER)
    assert call({"headers": {"Authorization": f"bearer {token}"}}) == ALLOW


def test_never_logs_token_or_secret(caplog):
    caplog.set_level(logging.DEBUG)
    good = make_token(SECRET, ISSUER)
    bad = make_token("wrong", ISSUER)
    call(bearer(good))
    call(bearer(bad))
    call(bearer("garbage.token.value"))
    text = caplog.text
    assert caplog.records, "expected reason logs"
    for secret_value in (SECRET, good, bad, "garbage.token.value", good.split(".")[2]):
        assert secret_value not in text
