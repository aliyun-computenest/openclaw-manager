#!/usr/bin/env python3
"""
End-to-end verification for: POST /api/users (admin-side create user).

Flow:
  1) GET <PLATFORM_URL>/env-config.js  ->  parse VITE_SUPABASE_URL / ANON_KEY
  2) POST <SUPABASE_URL>/auth/v1/token?grant_type=password (admin login)
  3) Pre-check: ensure target email does NOT exist via GET /api/users?search=
  4) POST /api/users  (admin creates a brand-new user; auto-creates auth + profile)
  5) Verify via GET /api/users?search=<email>  (and optional re-create -> 400)
  6) Cleanup: DELETE /api/users/<id>

The script uses ONLY the Python standard library (urllib + json + ssl).
No third-party deps required.

Usage:
  python3 verify-admin-create-user.py
  python3 verify-admin-create-user.py --keep   # skip cleanup, keep test user

Required:
  --platform-url <URL>   (or env PLATFORM_URL)   e.g. http://<host>:<port>

Env overrides (all optional):
  PLATFORM_URL                                OpenClaw platform base URL
  ADMIN_EMAIL     default admin@openclaw.local
  ADMIN_PASSWORD  default admin123
  VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY  override env-config.js fetch

Exit codes:
  0  PASS
  1  FAIL (assertion failed)
  2  Script crashed / network error
"""

import argparse
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Optional

# ---------------------------------------------------------------------------
# Defaults & CLI
# ---------------------------------------------------------------------------

DEFAULT_ADMIN_EMAIL = "admin@openclaw.local"
DEFAULT_ADMIN_PASSWORD = "admin123"

# Allow self-signed Supabase certs (the cluster often uses *.opentrust.net)
SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify POST /api/users")
    parser.add_argument(
        "--platform-url",
        default=os.environ.get("PLATFORM_URL"),
        help="OpenClaw platform base URL, e.g. http://<host>:<port> "
             "(also via env PLATFORM_URL; required)",
    )
    parser.add_argument(
        "--admin-email",
        default=os.environ.get("ADMIN_EMAIL", DEFAULT_ADMIN_EMAIL),
    )
    parser.add_argument(
        "--admin-password",
        default=os.environ.get("ADMIN_PASSWORD", DEFAULT_ADMIN_PASSWORD),
    )
    parser.add_argument(
        "--keep",
        action="store_true",
        help="Do not delete the created test user at the end",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Tiny logging helpers (no external deps)
# ---------------------------------------------------------------------------

def log_step(title: str, payload: Any = None) -> None:
    print(f"\n=== {title} ===", flush=True)
    if payload is not None:
        print(json.dumps(payload, indent=2, ensure_ascii=False), flush=True)


def log_info(msg: str) -> None:
    print(f"  · {msg}", flush=True)


def die(msg: str, code: int = 1) -> None:
    print(f"\n❌ {msg}", flush=True)
    sys.exit(code)


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

def http_request(
    method: str,
    url: str,
    *,
    headers: Optional[dict] = None,
    body: Any = None,
    timeout: int = 30,
) -> tuple[int, dict, str]:
    """Return (status_code, headers_dict, body_text). Never raises on HTTP errors."""
    data = None
    headers = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers.setdefault("Content-Type", "application/json")

    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX) as resp:
            return resp.status, dict(resp.headers), resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers or {}), exc.read().decode("utf-8", errors="replace")


def http_json(method: str, url: str, **kwargs) -> tuple[int, Any]:
    status, _, text = http_request(method, url, **kwargs)
    try:
        parsed = json.loads(text) if text else None
    except json.JSONDecodeError:
        parsed = {"_raw": text}
    return status, parsed


# ---------------------------------------------------------------------------
# Step implementations
# ---------------------------------------------------------------------------

def fetch_supabase_config(platform_url: str) -> tuple[str, str]:
    """Read VITE_SUPABASE_URL / ANON_KEY from <platform>/env-config.js (or env vars)."""
    env_url = os.environ.get("VITE_SUPABASE_URL")
    env_key = os.environ.get("VITE_SUPABASE_ANON_KEY")
    if env_url and env_key:
        log_info("Using Supabase config from environment variables")
        return env_url, env_key

    target = platform_url.rstrip("/") + "/env-config.js"
    log_info(f"Fetching Supabase config from {target}")
    status, _, text = http_request("GET", target)
    if status != 200:
        die(f"GET {target} returned HTTP {status}", code=2)

    url_match = re.search(r'VITE_SUPABASE_URL:\s*"([^"]+)"', text)
    key_match = re.search(r'VITE_SUPABASE_ANON_KEY:\s*"([^"]+)"', text)
    if not url_match or not key_match:
        die(f"Cannot parse env-config.js (got: {text[:200]!r})", code=2)

    return url_match.group(1), key_match.group(1)


def admin_login(supabase_url: str, anon_key: str, email: str, password: str) -> str:
    """POST {supabase}/auth/v1/token?grant_type=password -> access_token."""
    url = supabase_url.rstrip("/") + "/auth/v1/token?grant_type=password"
    status, body = http_json(
        "POST",
        url,
        headers={"apikey": anon_key},
        body={"email": email, "password": password},
    )
    if status != 200 or not isinstance(body, dict) or "access_token" not in body:
        die(f"Admin login failed (status={status}, body={body})", code=2)

    token = body["access_token"]
    log_info(f"Got admin access_token: {token[:16]}...")
    return token


def find_user_by_email(platform_url: str, token: str, email: str) -> Optional[dict]:
    """GET /api/users?search=<email> -> matching user_profile or None."""
    qs = urllib.parse.urlencode({"search": email, "pageSize": 100})
    url = f"{platform_url.rstrip('/')}/api/users?{qs}"
    status, body = http_json("GET", url, headers={"Authorization": f"Bearer {token}"})
    if status != 200 or not isinstance(body, dict) or not body.get("success"):
        die(f"GET /api/users failed (status={status}, body={body})", code=2)

    for user in body.get("users", []):
        if user.get("email", "").lower() == email.lower():
            return user
    return None


def create_user(
    platform_url: str,
    token: str,
    *,
    email: str,
    username: str,
    password: str,
    role: str = "user",
    max_instances: int = 5,
) -> tuple[int, Any]:
    """POST /api/users  (admin-side create)."""
    url = f"{platform_url.rstrip('/')}/api/users"
    return http_json(
        "POST",
        url,
        headers={"Authorization": f"Bearer {token}"},
        body={
            "email": email,
            "username": username,
            "password": password,
            "role": role,
            "maxInstances": max_instances,
            "authProvider": "email",
        },
    )


def delete_user(platform_url: str, token: str, user_id: str) -> tuple[int, Any]:
    url = f"{platform_url.rstrip('/')}/api/users/{user_id}"
    return http_json("DELETE", url, headers={"Authorization": f"Bearer {token}"})


# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

def main() -> int:
    args = parse_args()
    platform_url = args.platform_url
    if not platform_url:
        die("missing --platform-url (or env PLATFORM_URL), e.g. http://<host>:<port>", code=2)
    stamp = int(time.time())
    target_email = f"e2e-py-{stamp}@openclaw.local"
    target_username = f"E2EPy{stamp}"
    target_password = f"Tmp_{stamp}_AbC!"

    log_step("config", {
        "platform_url": platform_url,
        "admin_email": args.admin_email,
        "target_email": target_email,
        "target_username": target_username,
    })

    # 1) discover Supabase
    log_step("1) fetch Supabase config")
    supabase_url, anon_key = fetch_supabase_config(platform_url)
    log_step("   -> got", {"supabase_url": supabase_url, "anon_key_prefix": anon_key[:16] + "..."})

    # 2) admin login
    log_step("2) admin login via Supabase")
    token = admin_login(supabase_url, anon_key, args.admin_email, args.admin_password)

    # 3) precondition: target must NOT exist
    log_step("3) pre-check: target email must not exist")
    existing = find_user_by_email(platform_url, token, target_email)
    if existing:
        die(f"precondition failed: {target_email} already exists ({existing.get('id')})")
    log_info("OK, target email does not exist")

    # 4) create user via admin API (the "auto-create" path)
    log_step("4) POST /api/users", {
        "email": target_email,
        "username": target_username,
        "role": "user",
        "maxInstances": 5,
    })
    status, body = create_user(
        platform_url,
        token,
        email=target_email,
        username=target_username,
        password=target_password,
    )
    log_step("   -> response", {"status": status, "body": body})
    if status != 200 or not (isinstance(body, dict) and body.get("success")):
        die(f"POST /api/users failed (status={status}, body={body})")
    created_user_id = body["user"]["id"]
    log_info(f"created user_id = {created_user_id}")

    # 5a) verify via list
    log_step("5a) verify via GET /api/users?search=<email>")
    fetched = find_user_by_email(platform_url, token, target_email)
    if not fetched:
        die(f"user {target_email} not found in /api/users after create")
    if fetched.get("id") != created_user_id:
        die(f"id mismatch: created={created_user_id} listed={fetched.get('id')}")
    log_step("   -> profile row", {
        "id": fetched.get("id"),
        "email": fetched.get("email"),
        "username": fetched.get("username"),
        "role": fetched.get("role"),
        "status": fetched.get("status"),
        "max_agent_instances": fetched.get("max_agent_instances"),
    })

    # 5b) idempotency: re-creating the same email must fail with 4xx
    log_step("5b) re-create same email expects 4xx")
    status2, body2 = create_user(
        platform_url,
        token,
        email=target_email,
        username=target_username + "Dup",
        password=target_password,
    )
    log_step("   -> response", {"status": status2, "body": body2})
    if status2 == 200 and isinstance(body2, dict) and body2.get("success"):
        die("duplicate email creation should have failed but succeeded")
    log_info("OK, duplicate creation correctly rejected")

    # 6) cleanup
    if args.keep:
        log_step("6) cleanup skipped (--keep)", {"user_id": created_user_id, "email": target_email})
    else:
        log_step("6) cleanup", {"user_id": created_user_id})
        st, bd = delete_user(platform_url, token, created_user_id)
        log_step("   -> response", {"status": st, "body": bd})
        if st != 200:
            log_info(f"WARN: delete returned {st}, please clean up manually")

    log_step("VERDICT", {"result": "PASS"})
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 - top-level catch for clean exit code
        print(f"\n💥 Script crashed: {exc!r}", flush=True)
        import traceback
        traceback.print_exc()
        sys.exit(2)
