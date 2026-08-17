#!/usr/bin/env python3
import json
import os
import sys
import urllib.error
import urllib.request


base_url = os.environ.get("SHIFT_TRACKER_API_URL", "https://api.mezamir.com").rstrip("/")
login = os.environ.get("SHIFT_TRACKER_SMOKE_LOGIN")
password = os.environ.get("SHIFT_TRACKER_SMOKE_PASSWORD")

if not login or not password:
    raise SystemExit("Set SHIFT_TRACKER_SMOKE_LOGIN and SHIFT_TRACKER_SMOKE_PASSWORD")


def request(path: str, *, method: str = "GET", body: dict | None = None, token: str | None = None):
    headers = {"Accept": "application/json"}
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(base_url + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as response:
        raw = response.read()
        return response.status, json.loads(raw) if raw else None


try:
    status, bootstrap = request("/api/v1/auth/bootstrap/status")
    assert status == 200 and bootstrap == {"required": False}

    status, tokens = request(
        "/api/v1/auth/login",
        method="POST",
        body={"login": login, "password": password},
    )
    assert status == 200 and tokens["token_type"] == "bearer"

    status, profile = request("/api/v1/auth/me", token=tokens["access_token"])
    assert status == 200 and profile["login"].lower() == login.lower()

    status, roles = request("/api/v1/roles", token=tokens["access_token"])
    assert status == 200 and {role["id"] for role in roles} >= {
        "super_admin",
        "manager",
        "master",
        "worker",
    }

    status, refreshed = request(
        "/api/v1/auth/refresh",
        method="POST",
        body={"refresh_token": tokens["refresh_token"]},
    )
    assert status == 200 and refreshed["refresh_token"] != tokens["refresh_token"]

    status, _ = request(
        "/api/v1/auth/logout",
        method="POST",
        body={"refresh_token": refreshed["refresh_token"]},
        token=refreshed["access_token"],
    )
    assert status == 204
except (AssertionError, KeyError, urllib.error.URLError) as error:
    print(f"AUTH_SMOKE_FAILED: {error}", file=sys.stderr)
    raise SystemExit(1)

print("AUTH_SMOKE_OK")
