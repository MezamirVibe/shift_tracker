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


def request(path, method="GET", body=None, token=None):
    headers = {"Accept": "application/json"}
    data = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    req = urllib.request.Request(base_url + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=20) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


try:
    tokens = request(
        "/api/v1/auth/login",
        method="POST",
        body={"login": login, "password": password},
    )
    token = tokens["access_token"]
    departments = request("/api/v1/departments", token=token)
    groups = request("/api/v1/groups", token=token)
    positions = request("/api/v1/positions", token=token)
    employees = request("/api/v1/employees", token=token)
    attendance = request(
        "/api/v1/attendance?date_from=2021-01-01&date_to=2031-12-31",
        token=token,
    )
except (KeyError, TypeError, urllib.error.URLError) as error:
    print(f"DATA_SMOKE_FAILED: {error}", file=sys.stderr)
    raise SystemExit(1)

print(
    "DATA_SMOKE_OK "
    f"departments={len(departments)} groups={len(groups)} positions={len(positions)} "
    f"employees={len(employees)} attendance_days={len(attendance)}"
)
