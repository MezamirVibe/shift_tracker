"""Employee requests are separate from attendance; only a scoped reviewer can add hours."""
from datetime import date
import hashlib
import json
from typing import Literal
import uuid

from fastapi import Depends, HTTPException, Query
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from .attendance_audit import attendance_snapshot, record_change
from .models import AttendanceLock, AttendanceRecord, Employee, FactStatus, HourRequest, ScopeKind, User, utcnow
from .pagination import after_cursor, encode_cursor


class RequestIn(BaseModel):
    id: uuid.UUID
    day: date
    additional_minutes: int = Field(strict=True, ge=1, le=1440)
    reason: str = Field(min_length=3, max_length=1000)

    @field_validator("reason")
    @classmethod
    def trimmed_reason(cls, value):
        if len(value.strip()) < 3:
            raise ValueError("Укажите причину запроса")
        return value.strip()


class ReviewIn(BaseModel):
    decision: Literal["approved", "rejected"]
    comment: str = Field(default="", max_length=1000)
    revision: str | None = Field(default=None, max_length=64)
    confirmed_minutes: int | None = Field(default=None, strict=True, ge=1, le=1440)


def snapshot(record):
    return attendance_snapshot(record)


def normalized_baseline(baseline):
    result = {"exists": False, "minutes": 0, "fact": "none", "start": None,
              "end": None, "comment": None, **baseline}
    for field in ("start", "end"):
        value = result[field]
        result[field] = value[:5] if value and value != "None" else None
    return result


def review_revision(current):
    # A changed comment/time does not invalidate a requested hours increment.
    # A changed status or hours does require refreshing the approval preview.
    return hashlib.sha256(json.dumps({key: current[key] for key in ("minutes", "fact", "exists")},
                                     sort_keys=True).encode()).hexdigest()


def output(item, name):
    return {"id": str(item.id), "employee_id": str(item.employee_id), "full_name": name,
            "day": item.day.isoformat(), "additional_minutes": item.additional_minutes,
            "base_minutes": item.baseline["minutes"], "reason": item.reason,
            "status": item.status, "review_comment": item.review_comment,
            "applied_minutes": item.baseline.get("applied_minutes"),
            "created_at": item.created_at.isoformat(),
            "reviewed_at": item.reviewed_at.isoformat() if item.reviewed_at else None}


def register_hour_request_routes(app):
    from . import main as api

    def require_reviewer(user):
        if not api.has_permission(user, "editAttendance") or user.role.scope_kind == ScopeKind.self:
            raise HTTPException(403, "Рассматривать запросы может только руководитель")

    async def scoped_requests(session, user):
        if user.role.scope_kind == ScopeKind.self:
            if not api.has_permission(user, "viewCalendar"):
                raise HTTPException(403, "Недостаточно прав")
        else:
            require_reviewer(user)
        allowed = (await api.scoped_employees(session, select(Employee.id), user)).subquery()
        return select(HourRequest, Employee.full_name).join(Employee, Employee.id == HourRequest.employee_id).where(
            HourRequest.employee_id.in_(select(allowed.c.id)))

    async def pending_count(session, query):
        return await session.scalar(select(func.count()).select_from(query.where(HourRequest.status == "pending").subquery()))

    @app.get("/api/v1/hour-requests/page")
    async def request_page(status: Literal["all", "pending"] = "all",
                           page_size: int = Query(default=30, ge=1, le=100),
                           cursor: str | None = Query(default=None, max_length=300),
                           day: date | None = None, date_from: date | None = None, date_to: date | None = None,
                           user: User = Depends(api.current_user), session: AsyncSession = Depends(api.get_session)):
        query = await scoped_requests(session, user)
        count = await pending_count(session, query)
        if date_from and date_to and date_to < date_from:
            raise HTTPException(422, "Недопустимый диапазон дат")
        if status == "pending":
            query = query.where(HourRequest.status == "pending")
        if day is not None:
            query = query.where(HourRequest.day == day)
        if date_from is not None:
            query = query.where(HourRequest.day >= date_from)
        if date_to is not None:
            query = query.where(HourRequest.day <= date_to)
        rows = (await session.execute(after_cursor(query, HourRequest, cursor)
            .order_by(HourRequest.created_at.desc(), HourRequest.id.desc()).limit(page_size + 1))).all()
        return {"items": [output(item, name) for item, name in rows[:page_size]],
                "next_cursor": encode_cursor(rows[page_size - 1][0]) if len(rows) > page_size else None,
                "pending_count": count}

    @app.get("/api/v1/hour-requests/summary")
    async def request_summary(user: User = Depends(api.current_user), session: AsyncSession = Depends(api.get_session)):
        query = await scoped_requests(session, user)
        count = await pending_count(session, query)
        rows = (await session.execute(query.where(HourRequest.status.in_(["approved", "rejected"]))
            .order_by(HourRequest.reviewed_at.desc(), HourRequest.id.desc()).limit(5))).all()
        return {"pending_count": count, "recent_responses": [output(item, name) for item, name in rows]}

    @app.get("/api/v1/hour-requests")
    async def list_requests(status: Literal["all", "pending"] = "all",
                            user: User = Depends(api.current_user), session: AsyncSession = Depends(api.get_session)):
        # Legacy 1.5 clients retain their response shape; 1.6 uses /page.
        query = await scoped_requests(session, user)
        if status == "pending": query = query.where(HourRequest.status == "pending")
        rows = (await session.execute(query.order_by(HourRequest.created_at.desc()).limit(200))).all()
        return [output(item, name) for item, name in rows]

    @app.post("/api/v1/hour-requests", status_code=201)
    async def create_request(body: RequestIn, user: User = Depends(api.require_permission("viewCalendar")),
                             session: AsyncSession = Depends(api.get_session)):
        if user.role.scope_kind != ScopeKind.self or user.employee_id is None:
            raise HTTPException(403, "Запрос доступен сотруднику для своего графика")
        if body.day > date.today() or body.day < date(2000, 1, 1):
            raise HTTPException(422, "Запрос можно отправить за сегодняшний или прошедший день")
        # Serialize employee submissions without creating/modifying an attendance day.
        employee = await session.scalar((await api.scoped_employees(session,
            select(Employee).where(Employee.is_active.is_(True)), user)).with_for_update())
        if employee is None: raise HTTPException(409, "Нет привязки к действующему сотруднику")
        existing = await session.get(HourRequest, body.id)
        if existing:
            if (existing.requester_id, existing.employee_id, existing.day, existing.additional_minutes, existing.reason) != (
                    user.id, employee.id, body.day, body.additional_minutes, body.reason):
                raise HTTPException(409, "Этот идентификатор запроса уже используется")
            return output(existing, employee.full_name)
        pending = await session.scalar(select(HourRequest.id).where(
            HourRequest.employee_id == employee.id, HourRequest.day == body.day, HourRequest.status == "pending"))
        if pending: raise HTTPException(409, "За этот день уже есть запрос. Дождитесь решения или отмените его.")
        await api.attendance_employees(session, user, body.day, {employee.id})
        baseline = attendance_snapshot(await session.get(AttendanceRecord, (body.day, employee.id)),
            closed=await session.get(AttendanceLock, (body.day, employee.id)) is not None)
        if baseline["minutes"] + body.additional_minutes > 1440:
            raise HTTPException(422, "В сумме за день не может быть больше 24 часов")
        item = HourRequest(id=body.id, employee_id=employee.id, requester_id=user.id, day=body.day,
                           additional_minutes=body.additional_minutes, reason=body.reason, baseline=baseline)
        session.add(item)
        await api.audit(session, actor=user, action="request_hours", entity_type="hour_request", entity_id=str(item.id))
        await session.commit()
        return output(item, employee.full_name)

    @app.post("/api/v1/hour-requests/{request_id}/cancel")
    async def cancel_request(request_id: uuid.UUID, user: User = Depends(api.require_permission("viewCalendar")),
                             session: AsyncSession = Depends(api.get_session)):
        item = await session.scalar(select(HourRequest).where(HourRequest.id == request_id).with_for_update())
        if item is None or user.role.scope_kind != ScopeKind.self or item.employee_id != user.employee_id or item.requester_id != user.id:
            raise HTTPException(404, "Запрос не найден")
        if item.status == "cancelled": return {"status": item.status}
        if item.status != "pending": raise HTTPException(409, "Запрос уже рассмотрен")
        item.status = "cancelled"
        item.reviewed_at = utcnow()
        await api.audit(session, actor=user, action="cancel_hour_request", entity_type="hour_request", entity_id=str(item.id))
        await session.commit()
        return {"status": item.status}

    @app.get("/api/v1/hour-requests/{request_id}")
    async def request_details(request_id: uuid.UUID, user: User = Depends(api.current_user),
                              session: AsyncSession = Depends(api.get_session)):
        row = (await session.execute((await scoped_requests(session, user))
            .where(HourRequest.id == request_id))).first()
        if row is None:
            raise HTTPException(404, "Запрос не найден")
        item, name = row
        await api.attendance_employees(session, user, item.day, {item.employee_id})
        return output(item, name)

    @app.get("/api/v1/hour-requests/{request_id}/preview")
    async def review_preview(request_id: uuid.UUID, user: User = Depends(api.current_user),
                             session: AsyncSession = Depends(api.get_session)):
        require_reviewer(user)
        item = await session.get(HourRequest, request_id)
        if item is None:
            raise HTTPException(404, "Запрос не найден")
        employee = await api.ensure_employee_in_scope(session, user, item.employee_id)
        await api.attendance_employees(session, user, item.day, {item.employee_id})
        if item.requester_id == user.id:
            raise HTTPException(403, "Нельзя рассматривать собственные запросы")
        current = attendance_snapshot(await session.get(AttendanceRecord, (item.day, item.employee_id)),
            closed=await session.get(AttendanceLock, (item.day, item.employee_id)) is not None)
        baseline = normalized_baseline(item.baseline)
        return {"request": output(item, employee.full_name), "baseline": baseline, "current": current,
                "proposed_minutes": current["minutes"] + item.additional_minutes,
                "hours_changed": current["minutes"] != baseline["minutes"],
                "changes": [{"field": key, "before": baseline[key], "after": current[key]}
                            for key in baseline if key in current and baseline[key] != current[key]],
                "revision": review_revision(current)}

    @app.post("/api/v1/hour-requests/{request_id}/review")
    async def review_request(request_id: uuid.UUID, body: ReviewIn,
                             user: User = Depends(api.current_user), session: AsyncSession = Depends(api.get_session)):
        require_reviewer(user)
        item = await session.scalar(select(HourRequest).where(HourRequest.id == request_id).with_for_update())
        if item is None: raise HTTPException(404, "Запрос не найден")
        employee = await api.ensure_employee_in_scope(session, user, item.employee_id)
        if item.requester_id == user.id: raise HTTPException(403, "Нельзя одобрять собственные запросы")
        if item.status != "pending":
            if item.status == body.decision: return output(item, employee.full_name)
            raise HTTPException(409, "Запрос уже рассмотрен")
        if body.decision == "rejected" and len(body.comment.strip()) < 3:
            raise HTTPException(422, "Объясните сотруднику причину отклонения (не менее 3 символов)")
        if body.decision == "approved":
            await api.lock_attendance_day(session, item.day)
            await api.attendance_employees(session, user, item.day, {item.employee_id})
            record = await session.get(AttendanceRecord, (item.day, item.employee_id))
            current = attendance_snapshot(record,
                closed=await session.get(AttendanceLock, (item.day, item.employee_id)) is not None)
            baseline = normalized_baseline(item.baseline)
            revision = review_revision(current)
            if body.revision is not None and body.revision != revision:
                raise HTTPException(409, "Часы или отметка изменились. Обновите предпросмотр и подтвердите актуальный итог")
            minutes = current["minutes"] + item.additional_minutes
            if current["minutes"] != baseline["minutes"] and (
                    body.revision != revision or body.confirmed_minutes != minutes):
                raise HTTPException(409, "Часы изменились после запроса. Проверьте и явно подтвердите актуальный итог")
            if body.revision is None and current["fact"] != baseline["fact"]:
                raise HTTPException(409, "Отметка изменилась. Обновите приложение и проверьте актуальный итог")
            if minutes > 1440: raise HTTPException(422, "Больше 24 часов за день")
            if record is None:
                record = AttendanceRecord(day=item.day, employee_id=item.employee_id, fact=FactStatus.worked)
                session.add(record)
            elif record.fact == FactStatus.vacation:
                record.fact = FactStatus.vacationWorked
            elif record.fact == FactStatus.none:
                record.fact = FactStatus.worked
            elif record.fact not in {FactStatus.worked, FactStatus.businessTrip, FactStatus.vacationWorked}:
                raise HTTPException(409, "В табеле отмечено отсутствие. Сначала проверьте отметку и отклоните этот запрос с пояснением.")
            # Explicit supervisor approval adjusts only accounted minutes; times/comments and locks stay intact.
            record.worked_minutes = minutes
            record.updated_by_id = user.id
            await record_change(session, user, item.day, item.employee_id, current,
                attendance_snapshot(record, closed=current["closed"]), action="request_approved",
                reason=body.comment.strip() or item.reason, request_id=item.id)
            # Preserve the original baseline fields and record the actual approved
            # total without a schema migration or inventing totals for old requests.
            item.baseline = {**item.baseline, "applied_minutes": minutes}
        item.status = body.decision
        item.reviewer_id = user.id
        item.review_comment = body.comment.strip() or None
        item.reviewed_at = utcnow()
        await api.audit(session, actor=user, action="review_hour_request", entity_type="hour_request", entity_id=str(item.id),
                        details={"decision": item.status, "additional_minutes": item.additional_minutes})
        await session.commit()
        return output(item, employee.full_name)
