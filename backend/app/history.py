"""History starts at upgrade; previously overwritten information cannot be recovered."""
from datetime import date

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import Department, Employee, EmployeeHistory, Group, Position


async def employee_snapshot(session: AsyncSession, employee: Employee) -> dict:
    department = await session.get(Department, employee.department_id) if employee.department_id else None
    group = await session.get(Group, employee.group_id) if employee.group_id else None
    position = await session.get(Position, employee.position_id) if employee.position_id else None
    return {
        "full_name": employee.full_name,
        "department_id": str(employee.department_id) if employee.department_id else None,
        "department": department.name if department else "Без отдела",
        "group_id": str(employee.group_id) if employee.group_id else None,
        "group": group.name if group else "Без группы",
        "position": position.name if position else "",
        "schedule_type": employee.schedule_type.value,
        "schedule_start_date": employee.schedule_start_date.isoformat(),
        "shift_hours": employee.shift_hours,
        "break_hours": employee.break_hours,
        "custom_workdays": employee.custom_workdays,
        "is_active": employee.is_active,
    }


async def remember_employee(session: AsyncSession, employee: Employee, effective_from: date) -> None:
    await session.flush()
    snapshot = await employee_snapshot(session, employee)
    record = await session.get(EmployeeHistory, (employee.id, effective_from))
    if record is None:
        session.add(EmployeeHistory(employee_id=employee.id, effective_from=effective_from, snapshot=snapshot))
    else:
        record.snapshot = snapshot


async def ensure_employee_history(session: AsyncSession, employee: Employee) -> None:
    existing = await session.scalar(select(EmployeeHistory.employee_id).where(
        EmployeeHistory.employee_id == employee.id).limit(1))
    if existing is None:
        await remember_employee(session, employee, date.min)


def snapshot_on(revisions: list[EmployeeHistory], day: date) -> dict | None:
    result = None
    for revision in revisions:
        if revision.effective_from > day:
            break
        result = revision.snapshot
    return result


def planned_on(snapshot: dict, day: date) -> bool:
    if not snapshot.get("is_active", True):
        return False
    start = date.fromisoformat(snapshot["schedule_start_date"])
    if day < start:
        return False
    kind = snapshot["schedule_type"]
    if kind == "fiveTwo":
        return day.isoweekday() <= 5
    if kind == "custom":
        return day.isoweekday() in snapshot.get("custom_workdays", [1, 2, 3, 4, 5])
    return (day - start).days % 4 < 2


def paid_minutes(snapshot: dict) -> int:
    return max(0, snapshot["shift_hours"] - snapshot["break_hours"]) * 60
