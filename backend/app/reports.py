"""Department timesheets. Financial data is deliberately not part of this API."""
import calendar
import uuid
from collections import defaultdict
from datetime import date

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .history import paid_minutes, planned_on, snapshot_on
from .models import AttendanceLock, AttendanceRecord, EmployeeHistory, FactStatus, ScopeKind, User

WORK_FACTS = {FactStatus.worked, FactStatus.businessTrip, FactStatus.vacationWorked}


def visible_snapshot(user: User, employee_id: uuid.UUID, snapshot: dict,
                     hidden_groups: set[str], department_id: str | None, group_id: str | None) -> bool:
    department = snapshot.get("department_id")
    group = snapshot.get("group_id")
    if group in hidden_groups:
        return False
    if department_id is not None and department != department_id:
        return False
    if group_id is not None and group != group_id:
        return False
    if user.role_id == "super_admin" or user.role.scope_kind == ScopeKind.all:
        return True
    if user.role.scope_kind == ScopeKind.department:
        return user.department_id is not None and department == str(user.department_id)
    if user.role.scope_kind == ScopeKind.group:
        return user.group_id is not None and group == str(user.group_id)
    return user.employee_id is not None and employee_id == user.employee_id


def day_label(fact: FactStatus, minutes: int) -> str | float | None:
    hours = round(minutes / 60, 4)
    text = f"{hours:g}".replace(".", ",")
    if fact == FactStatus.worked:
        return hours
    if fact == FactStatus.businessTrip:
        return f"{text}к" if minutes else "К"
    if fact == FactStatus.vacationWorked:
        return f"о {text}"
    return {FactStatus.none: None, FactStatus.absent: "Н", FactStatus.sick: "Б",
            FactStatus.vacation: "О", FactStatus.unpaid: "б/с"}[fact]


async def month_report(session: AsyncSession, user: User, year: int, month: int,
                       hidden_groups: set[str], department_id: uuid.UUID | None = None,
                       group_id: uuid.UUID | None = None) -> dict:
    if not 2000 <= year <= 2100 or not 1 <= month <= 12:
        raise HTTPException(422, "Недопустимый месяц")
    first = date(year, month, 1)
    count = calendar.monthrange(year, month)[1]
    last = date(year, month, count)
    revisions = list((await session.scalars(select(EmployeeHistory).where(
        EmployeeHistory.effective_from <= last).order_by(
        EmployeeHistory.employee_id, EmployeeHistory.effective_from))).all())
    by_employee: dict[uuid.UUID, list[EmployeeHistory]] = defaultdict(list)
    for revision in revisions:
        by_employee[revision.employee_id].append(revision)
    # Restrict data queries to candidates, then check the effective scope on EVERY day.
    candidates = {employee_id for employee_id, history in by_employee.items() if any(
        visible_snapshot(user, employee_id, item.snapshot, hidden_groups,
                         str(department_id) if department_id else None,
                         str(group_id) if group_id else None) for item in history)}
    records = {(r.employee_id, r.day): r for r in (await session.scalars(
        select(AttendanceRecord).where(AttendanceRecord.day.between(first, last),
                                      AttendanceRecord.employee_id.in_(candidates)))).all()}
    locks = {(r.employee_id, r.day) for r in (await session.scalars(
        select(AttendanceLock).where(AttendanceLock.day.between(first, last),
                                    AttendanceLock.employee_id.in_(candidates)))).all()}
    rows = {}
    today = date.today()
    for employee_id in candidates:
        history = by_employee[employee_id]
        for number in range(1, count + 1):
            day = date(year, month, number)
            snapshot = snapshot_on(history, day)
            record = records.get((employee_id, day))
            if not snapshot or not visible_snapshot(user, employee_id, snapshot, hidden_groups,
                str(department_id) if department_id else None, str(group_id) if group_id else None):
                continue
            if not snapshot.get("is_active", True) and record is None:
                continue
            if day < date.fromisoformat(snapshot["schedule_start_date"]) and record is None:
                continue
            # A transfer mid-month gets separate department/group rows; hours are never duplicated.
            key = (employee_id, snapshot.get("department_id"), snapshot.get("group_id"))
            row = rows.setdefault(key, {
                "employee_id": str(employee_id), "full_name": snapshot["full_name"],
                "department_id": snapshot.get("department_id"), "department": snapshot["department"],
                "group_id": snapshot.get("group_id"), "group": snapshot["group"],
                "position": snapshot["position"], "days": [None] * count,
                "total_minutes": 0, "planned_days": 0, "worked_days": 0,
                "missing_days": 0, "open_days": 0, "notes": [],
            })
            planned = planned_on(snapshot, day)
            fact = record.fact if record else FactStatus.none
            minutes = 0
            if record and fact in WORK_FACTS:
                minutes = record.worked_minutes if record.worked_minutes is not None else (
                    paid_minutes(snapshot) if fact == FactStatus.worked else 0)
            missing = planned and day <= today and fact == FactStatus.none
            closed = (employee_id, day) in locks
            row["days"][number - 1] = {
                "date": day.isoformat(), "fact": fact.value, "minutes": minutes,
                "value": day_label(fact, minutes), "planned": planned,
                "missing": missing, "closed": closed,
            }
            row["total_minutes"] += minutes
            row["planned_days"] += int(planned)
            row["worked_days"] += int(minutes > 0)
            row["missing_days"] += int(missing)
            row["open_days"] += int(day <= today and (planned or fact != FactStatus.none) and not closed)
            if record and record.comment:
                row["notes"].append(f"{number:02d}.{month:02d}: {record.comment}")
    ordered = sorted(rows.values(), key=lambda row: (
        row["department"].casefold(), row["group"].casefold(), row["full_name"].casefold(), row["employee_id"]))
    return {"year": year, "month": month, "days_in_month": count, "rows": ordered,
            "total_minutes": sum(row["total_minutes"] for row in ordered),
            "missing_days": sum(row["missing_days"] for row in ordered),
            "open_days": sum(row["open_days"] for row in ordered),
            "financial_fields_included": False}
