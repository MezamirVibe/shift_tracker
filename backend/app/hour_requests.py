"""Employee requests are separate from attendance; only a scoped reviewer can add hours."""
from datetime import date
from typing import Literal
import uuid

from fastapi import Depends, HTTPException
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import AttendanceRecord, Employee, FactStatus, HourRequest, ScopeKind, User, utcnow


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


def snapshot(record):
    if record is None:
        return {"exists": False, "minutes": 0}
    return {"exists": True, "minutes": record.worked_minutes or 0,
            "fact": record.fact.value, "start": str(record.actual_start),
            "end": str(record.actual_end), "comment": record.comment}


def output(item, name):
    return {"id": str(item.id), "employee_id": str(item.employee_id), "full_name": name,
            "day": item.day.isoformat(), "additional_minutes": item.additional_minutes,
            "base_minutes": item.baseline["minutes"], "reason": item.reason,
            "status": item.status, "review_comment": item.review_comment,
            "created_at": item.created_at.isoformat(),
            "reviewed_at": item.reviewed_at.isoformat() if item.reviewed_at else None}


def register_hour_request_routes(app):
    from . import main as api

    def require_reviewer(user):
        if not api.has_permission(user, "editAttendance") or user.role.scope_kind == ScopeKind.self:
            raise HTTPException(403, "Рассматривать запросы может только руководитель")

    @app.get("/api/v1/hour-requests")
    async def list_requests(status: Literal["all", "pending"] = "all",
                            user: User = Depends(api.current_user), session: AsyncSession = Depends(api.get_session)):
        personal = user.role.scope_kind == ScopeKind.self
        if personal:
            if not api.has_permission(user, "viewCalendar"):
                raise HTTPException(403, "Недостаточно прав")
        else:
            require_reviewer(user)
        allowed = (await api.scoped_employees(session, select(Employee.id), user)).subquery()
        query = select(HourRequest, Employee.full_name).join(Employee, Employee.id == HourRequest.employee_id).where(
            HourRequest.employee_id.in_(select(allowed.c.id)))
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
        baseline = snapshot(await session.get(AttendanceRecord, (body.day, employee.id)))
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
        if body.decision == "approved":
            await api.lock_attendance_day(session, item.day)
            await api.attendance_employees(session, user, item.day, {item.employee_id})
            record = await session.get(AttendanceRecord, (item.day, item.employee_id))
            if snapshot(record) != item.baseline:
                raise HTTPException(409, "Табель изменился после отправки запроса. Отклоните запрос с пояснением; сотрудник сможет отправить новый.")
            minutes = item.baseline["minutes"] + item.additional_minutes
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
            # Explicit supervisor approval adjusts only paid minutes; times/comments and locks stay intact.
            record.worked_minutes = minutes
            record.updated_by_id = user.id
        item.status = body.decision
        item.reviewer_id = user.id
        item.review_comment = body.comment.strip() or None
        item.reviewed_at = utcnow()
        await api.audit(session, actor=user, action="review_hour_request", entity_type="hour_request", entity_id=str(item.id),
                        details={"decision": item.status, "additional_minutes": item.additional_minutes})
        await session.commit()
        return output(item, employee.full_name)
