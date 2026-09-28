"""Operator-only roster reduction. Preview by default; never deletes timesheets.

Run with the API stopped and a restore-verified database backup. --apply requires
the exact preview fingerprint and explicit employee IDs, not just a group name.
Compatible with the deployed 1.1 schema; does not run application migrations.
"""
import argparse
import asyncio
from datetime import date, datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sqlalchemy import delete, select, text
from sqlalchemy.orm import selectinload
from app.database import SessionFactory, engine
from app.history import ensure_employee_history, remember_employee
from app.models import (AttendanceDay, AttendanceLock, AttendanceRecord, AuditEvent,
                        Department, Employee, EmployeeHistory, Group, RefreshToken,
                        ScopeKind, User)
from app.reports import month_report


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, default=str,
                                    ensure_ascii=False).encode()).hexdigest()


def columns(row):
    return {column.name: getattr(row, column.name) for column in row.__table__.columns}


async def retain(session, *, group_id, keep_ids, expected_active, department_name,
                 effective_date, apply=False, expected_fingerprint=None):
    if not keep_ids or not department_name.strip():
        raise ValueError('An explicit nonempty roster and department name are required')
    if session.bind.dialect.name == 'postgresql':
        # Covers writes from other API connections, not merely other copies of this tool.
        await session.execute(text('SET LOCAL lock_timeout = \'10s\''))
        await session.execute(text('LOCK TABLE employees, departments, groups, users, '
                                   'employee_history, attendance_records, attendance_days, '
                                   'attendance_locks, refresh_tokens IN SHARE ROW EXCLUSIVE MODE'))
    employees = list((await session.scalars(select(Employee).order_by(Employee.id))).all())
    departments = list((await session.scalars(select(Department).order_by(Department.id))).all())
    groups = list((await session.scalars(select(Group).order_by(Group.id))).all())
    users = list((await session.scalars(select(User).options(selectinload(User.role)).order_by(User.id))).all())
    history = list((await session.scalars(select(EmployeeHistory).order_by(
        EmployeeHistory.employee_id, EmployeeHistory.effective_from))).all())
    before = {'employees': [columns(e) for e in employees],
              'departments': [columns(d) for d in departments],
              'groups': [columns(g) for g in groups],
              'users': [{k: v for k, v in columns(u).items() if k != 'password_hash'} for u in users],
              'history': [columns(h) for h in history]}
    fingerprint = digest(before)
    if apply and (not expected_fingerprint or fingerprint != expected_fingerprint):
        raise ValueError('Roster changed since preview; no changes applied')
    group = next((g for g in groups if g.id == group_id), None)
    actual_keep = {e.id for e in employees if e.is_active and e.group_id == group_id}
    if group is None or actual_keep != set(keep_ids):
        raise ValueError('Group membership does not match the explicitly approved roster')
    if sum(e.is_active for e in employees) != expected_active:
        raise ValueError('Active roster count changed; no changes applied')
    # Do not overwrite already-recorded effective changes or broaden a manager's access.
    if any(h.effective_from >= effective_date for h in history):
        raise ValueError('History already exists on/after the effective date; manual review required')
    if any(u.role.scope_kind in (ScopeKind.department, ScopeKind.group) for u in users):
        raise ValueError('Scoped manager accounts require an explicit reassignment plan')
    target = next(d for d in departments if d.id == group.department_id)
    if any(d.id != target.id and d.name == department_name for d in departments):
        raise ValueError('Another department already has the requested name')
    archived_ids = {e.id for e in employees if e.id not in keep_ids}
    disabled = [u for u in users if u.is_active and u.employee_id in archived_ids
                and u.role.scope_kind == ScopeKind.self and u.role_id != 'super_admin']
    administrator = next((u for u in users if u.is_active and u.role_id == 'super_admin'), None)
    if administrator is None:
        raise ValueError('No active administrator; refusing maintenance')
    plan = {'fingerprint': fingerprint, 'kept': len(keep_ids),
            'archived': sum(e.is_active and e.id in archived_ids for e in employees),
            'disabled_worker_logins': len(disabled), 'departments_after': 1,
            'groups_after': 0, 'effective_date': effective_date.isoformat(),
            'department_name': department_name, 'applied': False}
    if not apply:
        return plan

    async def attendance_digest():
        result = {}
        for model in (AttendanceDay, AttendanceRecord, AttendanceLock):
            rows = [columns(r) for r in (await session.scalars(select(model))).all()]
            result[model.__tablename__] = digest(sorted(rows, key=lambda r: json.dumps(r, sort_keys=True, default=str)))
        return result

    attendance_before = await attendance_digest()
    # Check the actual report builder for every previous month represented in history/marks.
    record_days = (await session.scalars(select(AttendanceRecord.day).distinct())).all()
    months = {(d.year, d.month) for d in record_days if (d.year, d.month) < (effective_date.year, effective_date.month)}
    previous = effective_date.replace(day=1).toordinal() - 1
    previous = date.fromordinal(previous)
    months.add((previous.year, previous.month))
    reports_before = {period: digest(await month_report(session, administrator, *period, set())) for period in months}
    for employee in employees:
        await ensure_employee_history(session, employee)
    target.name = department_name
    for employee in employees:
        employee.is_active = employee.id in keep_ids
        employee.department_id = target.id if employee.is_active else None
        employee.group_id = None
    for user in users:
        user.department_id = None
        user.group_id = None
    now = datetime.now(timezone.utc)
    for user in disabled:
        user.is_active = False
        user.token_version += 1
        tokens = (await session.scalars(select(RefreshToken).where(
            RefreshToken.user_id == user.id, RefreshToken.revoked_at.is_(None)))).all()
        for token in tokens:
            token.revoked_at = now
    for employee in employees:
        await remember_employee(session, employee, effective_date)
    await session.flush()
    await session.execute(delete(Group))
    await session.execute(delete(Department).where(Department.id != target.id))
    # Complete before-image is retained in the private backup. Audit only non-financial structure.
    session.add(AuditEvent(action='retain_department', entity_type='department',
        entity_id=str(target.id), details={**plan, 'kept_employee_ids': sorted(map(str, keep_ids)),
        'archived_employee_ids': sorted(map(str, archived_ids)),
        'disabled_user_ids': [str(u.id) for u in disabled]}))
    await session.flush()
    if await attendance_digest() != attendance_before:
        raise RuntimeError('Attendance data changed; transaction will roll back')
    for period, expected in reports_before.items():
        if digest(await month_report(session, administrator, *period, set())) != expected:
            raise RuntimeError('Historical report changed; transaction will roll back')
    plan.update(applied=True, attendance_unchanged=True,
                previous_reports_unchanged=len(reports_before))
    return plan


async def main(args):
    try:
        async with SessionFactory() as session:
            async with session.begin():
                result = await retain(session, group_id=args.group_id, keep_ids=set(args.keep_id),
                    expected_active=args.expected_active, department_name=args.department_name,
                    effective_date=args.effective_date, apply=args.apply,
                    expected_fingerprint=args.fingerprint)
            print(json.dumps(result, ensure_ascii=False))
    finally:
        await engine.dispose()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--group-id', type=uuid.UUID, required=True)
    parser.add_argument('--keep-id', type=uuid.UUID, action='append', required=True)
    parser.add_argument('--expected-active', type=int, required=True)
    parser.add_argument('--department-name', required=True)
    parser.add_argument('--effective-date', type=date.fromisoformat, required=True)
    parser.add_argument('--fingerprint')
    parser.add_argument('--apply', action='store_true')
    asyncio.run(main(parser.parse_args()))
