#!/usr/bin/env python3
import json
import os
import re
import secrets
import string
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


if len(sys.argv) != 4:
    raise SystemExit("Usage: migrate-local-data.py DATA_DIR ADMIN_LOGIN ADMIN_PASSWORD")

data_dir = Path(sys.argv[1])
admin_login = sys.argv[2]
admin_password = sys.argv[3]
base_url = os.environ.get("SHIFT_TRACKER_API_URL", "https://api.mezamir.com").rstrip("/")
access_token = ""


def read_json(name, default):
    path = data_dir / name
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8-sig"))


def api(method, path, body=None, authenticated=True):
    headers = {"Accept": "application/json"}
    if authenticated:
        headers["Authorization"] = f"Bearer {access_token}"
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body, ensure_ascii=False).encode()
    request = urllib.request.Request(base_url + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError(f"{method} {path}: HTTP {error.code}: {detail}") from error


def temporary_password():
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(18)) + "Aa7!"


tokens = api(
    "POST",
    "/api/v1/auth/login",
    {"login": admin_login, "password": admin_password},
    authenticated=False,
)
access_token = tokens["access_token"]

departments = read_json("departments.json", [])
groups = read_json("groups.json", [])
positions = read_json("positions.json", [])
employees = read_json("employees.json", [])
users = read_json("users.json", [])
roles = read_json("roles.json", [])
attendance = read_json("attendance.json", {})

role_ids = {}
existing_roles = {item["id"]: item for item in api("GET", "/api/v1/roles")}
for item in roles:
    old_id = str(item.get("id", "")).strip()
    if not old_id:
        continue
    if old_id in existing_roles:
        role_ids[old_id] = old_id
        continue
    server_id = re.sub(r"[^a-z0-9_]+", "_", old_id.lower()).strip("_")
    if not server_id or not server_id[0].isalpha():
        server_id = f"role_{server_id or 'custom'}"
    created = api(
        "POST",
        "/api/v1/roles",
        {
            "id": server_id,
            "name": item.get("name", old_id).strip(),
            "scope_kind": item.get("scopeKind", "self"),
            "permissions": item.get("permissions", []),
        },
    )
    role_ids[old_id] = created["id"]

department_ids = {}
existing_departments = {item["name"].strip().lower(): item for item in api("GET", "/api/v1/departments")}
for item in departments:
    name = item.get("name", "").strip()
    existing = existing_departments.get(name.lower())
    created = existing or api("POST", "/api/v1/departments", {"name": name})
    department_ids[str(item["id"])] = created["id"]

group_ids = {}
existing_groups = {
    (item["department_id"], item["name"].strip().lower()): item
    for item in api("GET", "/api/v1/groups")
}
for item in groups:
    department_id = department_ids[str(item["departmentId"])]
    key = (department_id, item.get("name", "").strip().lower())
    created = existing_groups.get(key) or api(
        "POST",
        "/api/v1/groups",
        {"department_id": department_id, "name": item.get("name", "").strip()},
    )
    group_ids[str(item["id"])] = created["id"]

position_ids = {}
existing_positions = {item["name"].strip().lower(): item for item in api("GET", "/api/v1/positions")}
for item in positions:
    name = item.get("name", "").strip()
    created = existing_positions.get(name.lower()) or api(
        "POST", "/api/v1/positions", {"name": name}
    )
    position_ids[name.lower()] = created["id"]

employee_ids = {}
existing_employees = {item["full_name"].strip().lower(): item for item in api("GET", "/api/v1/employees")}
for item in employees:
    name = item.get("fullName", "").strip()
    position_name = item.get("position", "").strip()
    position_id = position_ids.get(position_name.lower())
    if position_name and position_id is None:
        created_position = api("POST", "/api/v1/positions", {"name": position_name})
        position_id = created_position["id"]
        position_ids[position_name.lower()] = position_id
    existing = existing_employees.get(name.lower())
    created = existing or api(
        "POST",
        "/api/v1/employees",
        {
            "full_name": name,
            "position_id": position_id,
            "department_id": department_ids.get(str(item.get("departmentId"))),
            "group_id": group_ids.get(str(item.get("groupId"))),
            "salary": int(item.get("salary", 0)),
            "bonus": int(item.get("bonus", 0)),
            "schedule_type": item.get("scheduleType", "twoTwo"),
            "schedule_start_date": str(item.get("scheduleStartDate", "")).split("T")[0],
            "shift_hours": int(item.get("shiftHours", 12)),
            "break_hours": int(item.get("breakHours", 1)),
        },
    )
    employee_ids[str(item["id"])] = created["id"]

existing_users = {item["login"].strip().lower(): item for item in api("GET", "/api/v1/users")}
created_credentials = []
for item in users:
    login = item.get("login", "").strip()
    if not login or login.lower() in existing_users:
        continue
    password = temporary_password()
    last_name = item.get("lastName", "").strip() or "Администратор"
    first_name = item.get("firstName", "").strip() or login
    api(
        "POST",
        "/api/v1/users",
        {
            "login": login,
            "password": password,
            "role_id": role_ids.get(item.get("roleId"), item.get("roleId", "worker")),
            "last_name": last_name,
            "first_name": first_name,
            "middle_name": item.get("middleName", "").strip(),
            "department_id": department_ids.get(str(item.get("departmentId"))),
            "group_id": group_ids.get(str(item.get("groupId"))),
            "employee_id": employee_ids.get(str(item.get("employeeId"))),
        },
    )
    created_credentials.append((login, password))

existing_attendance = api(
    "GET", "/api/v1/attendance?date_from=2021-01-01&date_to=2031-12-31"
)
for day, day_data in attendance.items():
    if not isinstance(day_data, dict):
        continue
    existing_day = existing_attendance.get(day)
    if isinstance(existing_day, dict):
        existing_meta = existing_day.get("_meta")
        if isinstance(existing_meta, dict) and existing_meta.get("closed") is True:
            continue
    day_employee_ids = []
    for old_employee_id, record in day_data.items():
        if old_employee_id == "_meta" or not isinstance(record, dict):
            continue
        employee_id = employee_ids.get(str(old_employee_id))
        if employee_id is None:
            continue
        day_employee_ids.append(employee_id)
        api(
            "PUT",
            f"/api/v1/attendance/{day}/{employee_id}",
            {
                "fact": record.get("fact", record.get("status", "none")),
                "comment": record.get("comment", record.get("note")),
                "worked_minutes": record.get("workedMinutes"),
            },
        )
    meta = day_data.get("_meta")
    if isinstance(meta, dict) and meta.get("closed") is True:
        api(
            "POST",
            f"/api/v1/attendance/{day}/close",
            {"planned_employee_ids": day_employee_ids},
        )

print(
    "MIGRATION_OK "
    f"departments={len(departments)} groups={len(groups)} positions={len(positions)} "
    f"employees={len(employees)} users={len(users)} roles={len(roles)}"
)
for login, password in created_credentials:
    print(f"MIGRATED_USER login={login} temporary_password={password}")
