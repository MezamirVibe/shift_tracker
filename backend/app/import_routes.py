"""Preview/confirm import; tenant-local, permission-scoped and non-overwriting."""
import base64
import binascii
from calendar import monthrange
from datetime import date, datetime, timedelta, timezone
import hashlib
import json
import uuid

import jwt
from fastapi import Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.concurrency import run_in_threadpool

from .history import remember_employee, employee_snapshot
from .models import AttendanceLock, AttendanceRecord, Employee, FactStatus, Group, Department, Position, ScheduleType, ScopeKind, User
from .schemas import AttendanceRecordIn
from .timesheet_import import MAX_FILE_BYTES, normalized, read_timesheet


class ImportInput(BaseModel):
    file_base64: str = Field(min_length=1, max_length=4 * ((MAX_FILE_BYTES + 2) // 3))
    year: int = Field(ge=2000, le=2100)
    month: int = Field(ge=1, le=12)
    sheet: str | None = Field(default=None, max_length=100)
    department_id: uuid.UUID
    group_id: uuid.UUID | None = None
    # Schedules are never inferred from attendance. The user chooses this default.
    schedule_type: ScheduleType = ScheduleType.fiveTwo
    shift_hours: int = Field(default=9, ge=1, le=24)
    break_hours: int = Field(default=1, ge=0, le=23)


class ImportCommit(ImportInput):
    preview_token: str = Field(max_length=2000)
    selected_rows: list[int] = Field(min_length=1, max_length=500)


def digest(data) -> str:
    return hashlib.sha256(json.dumps(data, sort_keys=True, ensure_ascii=False,
                                     default=str, separators=(",", ":")).encode()).hexdigest()


def register_import_routes(app):
    # Main defines the shared authorization and audit operations before registration.
    from . import main as api

    async def prepare(body: ImportInput, user: User, session: AsyncSession):
        for permission in ("viewEmployees", "viewAttendance", "editEmployees", "editAttendance"):
            if not api.has_permission(user, permission):
                raise HTTPException(403, "Для импорта нужны права на сотрудников и отметки")
        if user.role.scope_kind == ScopeKind.self and not api.is_super_admin(user):
            raise HTTPException(403, "Импорт недоступен для личного графика")
        if body.break_hours >= body.shift_hours or body.schedule_type == ScheduleType.custom:
            raise HTTPException(422, "Выберите график 5/2 или 2/2 и перерыв короче смены")
        department = await session.get(Department, body.department_id)
        if department is None:
            raise HTTPException(404, "Отдел не найден")
        if body.group_id:
            group = await session.get(Group, body.group_id)
            if group is None or group.department_id != body.department_id:
                raise HTTPException(404, "Группа не найдена в выбранном отделе")
            await api.require_group_scope(session, user, group)
        else:
            api.require_department_scope(user, department.id)
        try:
            content = base64.b64decode(body.file_base64, validate=True)
            parsed = await run_in_threadpool(read_timesheet, content, body.year, body.month, body.sheet)
        except (ValueError, binascii.Error) as error:
            raise HTTPException(422, str(error)) from error
        if parsed["needs_sheet"]:
            return parsed, None
        first = date(body.year, body.month, 1)
        last = date(body.year, body.month, monthrange(body.year, body.month)[1])
        employees = list((await session.scalars(await api.scoped_employees(session, select(Employee), user))).all())
        records = {(record.employee_id, record.day.day): record for record in (await session.scalars(
            select(AttendanceRecord).where(AttendanceRecord.employee_id.in_([e.id for e in employees]),
                                           AttendanceRecord.day.between(first, last)))).all()}
        locks = {(lock.employee_id, lock.day.day) for lock in (await session.scalars(
            select(AttendanceLock).where(AttendanceLock.employee_id.in_([e.id for e in employees]),
                                         AttendanceLock.day.between(first, last)))).all()}
        scope = await api.attendance_scope(session, user, last)
        by_name = {}
        for employee in employees:
            by_name.setdefault(normalized(employee.full_name), []).append(employee)
        rows = []
        for source in parsed["rows"]:
            candidates = by_name.get(normalized(source["full_name"]), [])
            matches = [e for e in candidates if e.is_active]
            employee = matches[0] if len(matches) == 1 else None
            reason = None
            if len(matches) > 1:
                reason = "Несколько сотрудников с этим ФИО: уточните имя перед импортом"
            elif employee and (employee.department_id != body.department_id or employee.group_id != body.group_id):
                reason = "Сотрудник уже находится в другом отделе или группе; автоматический перенос запрещён"
            elif employee and any(not (snap := scope.snapshot(employee.id, date(body.year, body.month, m['day'])))
                                  or not snap.get('is_active', True)
                                  or date(body.year, body.month, m['day']) < date.fromisoformat(snap['schedule_start_date'])
                                  for m in source['marks']):
                reason = "Есть даты до начала работы или вне вашей исторической области доступа"
            fresh, same, conflict, locked = [], 0, 0, 0
            for mark in source["marks"]:
                existing = records.get((employee.id, mark["day"])) if employee else None
                if existing and existing.fact.value == mark["fact"] and existing.worked_minutes == mark["worked_minutes"]:
                    same += 1
                elif employee and (employee.id, mark["day"]) in locks:
                    locked += 1
                elif existing and (existing.fact != FactStatus.none or existing.comment or existing.actual_start):
                    conflict += 1
                else:
                    fresh.append(mark)
            rows.append({**source, "employee_id": str(employee.id) if employee else None,
                         "action": "blocked" if reason else "match" if employee else "create",
                         "reason": reason, "archived_namesake": any(not e.is_active for e in candidates),
                         "new_marks": len(fresh), "same_marks": same, "conflicts": conflict, "locked": locked,
                         "write_marks": fresh})
        period = parsed.get("detected_period")
        if period and period != {"year": body.year, "month": body.month}:
            parsed["errors"].append({"cell": parsed["sheet"], "message": "Период в названии листа отличается от выбранного месяца"})
            parsed["error_count"] += 1
        # Compare all import-relevant state at commit, including comments/locks.
        fingerprint = digest({"input": {**body.model_dump(exclude={"preview_token", "selected_rows"}), "sheet": parsed["sheet"]},
                              "rows": rows, "user": [str(user.id), user.token_version, user.role_id,
                                                      user.role.permissions, str(user.department_id), str(user.group_id)],
                              "employees": sorted((str(e.id), str(e.updated_at), e.is_active) for e in employees),
                              "records": sorted((str(e), d, r.fact.value, r.worked_minutes, str(r.updated_at), r.comment)
                                                for (e, d), r in records.items()),
                              "locks": sorted((str(e), d) for e, d in locks)})
        parsed["rows"] = rows
        parsed["department"] = department.name
        return parsed, fingerprint

    def public_preview(parsed):
        return {**parsed, "rows": [{k: v for k, v in row.items() if k not in {"marks", "write_marks"}}
                                  for row in parsed["rows"]]}

    @app.post("/api/v1/imports/timesheet/preview")
    async def preview(body: ImportInput, user: User = Depends(api.current_user),
                      session: AsyncSession = Depends(api.get_session)):
        parsed, fingerprint = await prepare(body, user, session)
        response = public_preview(parsed)
        if fingerprint and not parsed["errors"]:
            now = datetime.now(timezone.utc)
            response["preview_token"] = jwt.encode({"sub": str(user.id), "type": "import-preview",
                "aud": api.settings.ORGANIZATION_CODE, "iat": now, "exp": now + timedelta(minutes=15),
                "fingerprint": fingerprint}, api.settings.JWT_SECRET, algorithm="HS256")
        return response

    @app.post("/api/v1/imports/timesheet/commit")
    async def commit(body: ImportCommit, user: User = Depends(api.current_user),
                     session: AsyncSession = Depends(api.get_session)):
        try:
            claims = jwt.decode(body.preview_token, api.settings.JWT_SECRET, algorithms=["HS256"],
                                audience=api.settings.ORGANIZATION_CODE,
                                options={"require": ["sub", "type", "aud", "exp", "iat", "fingerprint"]})
            if claims["type"] != "import-preview" or claims["sub"] != str(user.id):
                raise jwt.InvalidTokenError()
        except jwt.InvalidTokenError as error:
            raise HTTPException(409, "Предпросмотр истёк. Проверьте файл заново") from error
        await api.lock_employee_roster(session)
        # All writers/close operations use these same day locks, in chronological order.
        for day in range(1, monthrange(body.year, body.month)[1] + 1):
            await api.lock_attendance_day(session, date(body.year, body.month, day))
        parsed, fingerprint = await prepare(body, user, session)
        if not fingerprint or parsed["errors"] or fingerprint != claims["fingerprint"]:
            raise HTTPException(409, "Данные изменились после проверки. Откройте предпросмотр заново")
        selected = set(body.selected_rows)
        rows = [r for r in parsed["rows"] if r["row"] in selected]
        if len(selected) != len(body.selected_rows) or len(rows) != len(selected) or any(r['action'] == 'blocked' for r in rows):
            raise HTTPException(422, "Выберите только проверенные строки без ошибок")
        first = date(body.year, body.month, 1)
        created, written = 0, 0
        existing_scope = await api.attendance_scope(session, user, date(body.year, body.month, monthrange(body.year, body.month)[1]))
        positions = {normalized(p.name): p for p in (await session.scalars(select(Position))).all()}
        for row in rows:
            if row["action"] == "create":
                position = positions.get(normalized(row["position"]))
                if position is None and row["position"]:
                    position = Position(name=row["position"])
                    session.add(position)
                    await session.flush()
                    positions[normalized(row["position"])] = position
                employee = Employee(full_name=row["full_name"], position_id=position.id if position else None,
                    department_id=body.department_id, group_id=body.group_id, salary=0, bonus=0,
                    schedule_type=body.schedule_type, schedule_start_date=first,
                    shift_hours=body.shift_hours, break_hours=body.break_hours, custom_workdays=[1,2,3,4,5])
                session.add(employee)
                await session.flush()
                await remember_employee(session, employee, first)
                new_snapshot = await employee_snapshot(session, employee)
                employee_id = employee.id
                created += 1
            else:
                employee_id = uuid.UUID(row["employee_id"])
                new_snapshot = None
            for mark in row["write_marks"]:
                day = date(body.year, body.month, mark["day"])
                snapshot = new_snapshot or existing_scope.snapshot(employee_id, day)
                if snapshot is None:
                    raise HTTPException(409, "Область доступа изменилась; проверьте файл заново")
                await api.save_attendance_record(session, user, day,
                    employee_id, AttendanceRecordIn(fact=FactStatus(mark["fact"]), worked_minutes=mark["worked_minutes"]), snapshot)
                written += 1
        await api.audit(session, actor=user, action="import_timesheet", entity_type="timesheet",
                        entity_id=f"{body.year}-{body.month:02d}", details={"created": created, "marks": written,
                            "rows": len(rows), "source_sha256": hashlib.sha256(base64.b64decode(body.file_base64)).hexdigest()})
        await session.commit()
        return {"created_employees": created, "written_marks": written,
                "preserved_marks": sum(r['conflicts'] + r['locked'] + r['same_marks'] for r in rows)}
