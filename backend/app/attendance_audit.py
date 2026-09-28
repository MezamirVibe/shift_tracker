"""Detailed attendance history starts when real before/after events are recorded."""
from datetime import date, timedelta
import uuid

from fastapi import Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .history import planned_on
from .models import AttendanceLock, AttendanceRecord, AuditEvent, FactStatus, ScopeKind, User
from .pagination import after_cursor, encode_cursor


def attendance_snapshot(record, *, closed: bool = False) -> dict:
    return {
        "exists": record is not None,
        "minutes": (record.worked_minutes or 0) if record else 0,
        "fact": record.fact.value if record and record.fact else "none",
        "start": record.actual_start.isoformat(timespec="minutes") if record and record.actual_start else None,
        "end": record.actual_end.isoformat(timespec="minutes") if record and record.actual_end else None,
        "comment": record.comment if record else None,
        "closed": closed,
    }


async def record_change(session, actor, day, employee_id, before, after, *,
                        reason: str | None = None, request_id=None, action="manual"):
    if before == after:
        return
    name = " ".join(part for part in (actor.last_name, actor.first_name, actor.middle_name) if part).strip()
    session.add(AuditEvent(actor_id=actor.id, action="attendance_change", entity_type="employee_attendance",
        entity_id=str(employee_id), details={
            "version": 1, "actor_name": name or actor.login,
            "day": day.isoformat(), "employee_id": str(employee_id),
            "before": before, "after": after, "reason": reason,
            "request_id": str(request_id) if request_id else None, "action": action,
        }))


def register_history_routes(app):
    from . import main as api

    @app.get("/api/v1/attendance/action-days")
    async def action_days(date_from: date, date_to: date,
                          user: User = Depends(api.current_user), session: AsyncSession = Depends(api.get_session)):
        if user.role.scope_kind == ScopeKind.self or not api.has_permission(user, "editAttendance"):
            raise HTTPException(403, "Раздел доступен руководителю с правом учёта часов")
        if date_to < date_from or (date_to - date_from).days >= 62 or date_to > date.today():
            raise HTTPException(422, "Выберите не более 62 дней до сегодняшней даты включительно")
        scope = await api.attendance_scope(session, user, date_to)
        candidates = scope.candidates
        records = {(item.day, item.employee_id): item for item in (await session.scalars(
            select(AttendanceRecord).where(AttendanceRecord.day.between(date_from, date_to),
                AttendanceRecord.employee_id.in_(candidates)))).all()}
        locks = {(item.day, item.employee_id) for item in (await session.scalars(
            select(AttendanceLock).where(AttendanceLock.day.between(date_from, date_to),
                AttendanceLock.employee_id.in_(candidates)))).all()}
        days = []
        for offset in range((date_to - date_from).days + 1):
            current_day = date_from + timedelta(days=offset)
            unfilled = unclosed = 0
            for employee_id in candidates:
                snapshot = scope.snapshot(employee_id, current_day)
                if snapshot is None:
                    continue
                key = (current_day, employee_id)
                record = records.get(key)
                # An unplanned shift is still work requiring attention. Closed
                # empty days and ordinary days off do not become phantom shifts.
                if not planned_on(snapshot, current_day) and record is None:
                    continue
                if record is None or record.fact == FactStatus.none:
                    unfilled += 1
                if key not in locks:
                    unclosed += 1
            if unfilled or unclosed:
                days.append({"day": current_day.isoformat(), "unfilled": unfilled, "unclosed": unclosed})
        return {"days": days}

    @app.get("/api/v1/attendance/history")
    async def history(employee_id: uuid.UUID, day: date | None = None,
                      page_size: int = Query(default=30, ge=1, le=100),
                      cursor: str | None = Query(default=None, max_length=300),
                      user: User = Depends(api.current_user), session: AsyncSession = Depends(api.get_session)):
        permission = "viewCalendar" if user.role.scope_kind == ScopeKind.self else "viewAttendance"
        if not api.has_permission(user, permission):
            raise HTTPException(403, "Недостаточно прав для просмотра истории")
        await api.ensure_employee_in_scope(session, user, employee_id)
        scope = await api.attendance_scope(session, user, day or date.max)
        if day is not None and not scope.snapshot(employee_id, day):
            raise HTTPException(404, "Сотрудник не найден на выбранную дату")
        query = select(AuditEvent).where(AuditEvent.action == "attendance_change",
            AuditEvent.entity_type == "employee_attendance", AuditEvent.entity_id == str(employee_id))
        if day:
            query = query.where(AuditEvent.details["day"].as_string() == day.isoformat())
        # Current membership and historical membership are both required. Filtering
        # each event prevents a new department manager reading a previous department.
        items = []
        scan_cursor = cursor
        while len(items) <= page_size:
            rows = list((await session.scalars(after_cursor(query, AuditEvent, scan_cursor)
                .order_by(AuditEvent.created_at.desc(), AuditEvent.id.desc()).limit(100))).all())
            for event in rows:
                details = event.details or {}
                if details.get("version") != 1:
                    continue
                event_day = date.fromisoformat(details["day"])
                if scope.snapshot(employee_id, event_day):
                    items.append((event, {**details, "id": str(event.id),
                                          "created_at": event.created_at.isoformat()}))
                    if len(items) > page_size:
                        break
            if len(items) > page_size or len(rows) < 100:
                break
            scan_cursor = encode_cursor(rows[-1])
        return {"items": [item for _, item in items[:page_size]],
                "next_cursor": encode_cursor(items[page_size - 1][0]) if len(items) > page_size else None}
