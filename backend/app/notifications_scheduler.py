"""Opt-in daily summaries; no retroactive notifications or attendance writes."""
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from .history import paid_minutes, planned_on
from .models import Employee, Notification, NotificationPreference, ScopeKind, User
from .notification_events import duration
from .notifications import emit_notification, normalized_preferences


async def _exists(session, user_id, key):
    return await session.scalar(select(Notification.id).where(
        Notification.user_id == user_id, Notification.dedupe_key == key).limit(1)) is not None


def unfinished_counts(report, last_day):
    """Count dates, not employees, using the recipient's local date cutoff."""
    missing, opened = set(), set()
    for row in report['rows']:
        for day in row['days']:
            if not day or day['date'] > last_day.isoformat():
                continue
            if day['planned'] and day['fact'] == 'none':
                missing.add(day['date'])
            if (day['planned'] or day['fact'] != 'none') and not day['closed']:
                opened.add(day['date'])
    return len(missing), len(opened)


async def schedule_notifications(api, session, now):
    # A missing preference row means both reminders are disabled. Master push is
    # deliberately independent: enabling an in-app reminder does not opt into OS push.
    rows = (await session.execute(select(NotificationPreference, User)
        .join(User, User.id == NotificationPreference.user_id)
        .where(User.is_active.is_(True)).options(selectinload(User.role)))).all()
    for preference, user in rows:
        prefs = normalized_preferences(preference)
        if not (prefs['kinds']['shift_reminder'] or prefs['kinds']['unfilled_days']):
            continue
        try:
            zone = ZoneInfo(prefs['timezone'])
        except (ZoneInfoNotFoundError, ValueError):
            continue
        local = now.astimezone(zone)
        today, tomorrow = local.date(), local.date() + timedelta(days=1)
        expiry = datetime.combine(tomorrow, time.min, zone).astimezone(timezone.utc)
        try:
            if (prefs['kinds']['shift_reminder'] and local.hour >= 20 and
                    user.employee_id and api.has_permission(user, 'viewCalendar')):
                key = f'shift-reminder:{tomorrow}'
                if not await _exists(session, user.id, key):
                    employee = await session.scalar(await api.scoped_employees(session,
                        select(Employee).where(Employee.id == user.employee_id, Employee.is_active.is_(True)), user))
                    if employee is not None:
                        scope = await api.attendance_scope(session, user, tomorrow)
                        snapshot = scope.snapshot(employee.id, tomorrow)
                        if snapshot and planned_on(snapshot, tomorrow):
                            await emit_notification(session, user_id=user.id, kind='shift_reminder',
                                title='Завтра рабочая смена',
                                body=f'{tomorrow:%d.%m.%Y}: по плану {duration(paid_minutes(snapshot))}. Проверьте график.',
                                day=tomorrow, employee_id=employee.id, dedupe_key=key, expires_at=expiry)
            if (prefs['kinds']['unfilled_days'] and local.hour >= 18 and
                    user.role.scope_kind != ScopeKind.self and api.has_permission(user, 'editAttendance') and
                    api.has_permission(user, 'viewAttendance') and api.has_permission(user, 'viewEmployees')):
                key = f'unfilled-days:{today}'
                if not await _exists(session, user.id, key):
                    report = await api.get_month_report(today.year, today.month, None, None, user, session)
                    missing, opened = unfinished_counts(report, today)
                    if missing or opened:
                        await emit_notification(session, user_id=user.id, kind='unfilled_days',
                            title='Табель требует внимания', day=today,
                            body=(f'За текущий месяц по {today:%d.%m}: дней с незаполненными отметками — {missing}, '
                                  f'дней с незакрытыми записями — {opened}.'),
                            dedupe_key=key, expires_at=expiry)
        except HTTPException as error:
            if error.status_code not in {403, 404, 409}:
                raise
            # Scope may be removed between selecting recipients and reading the
            # report. Never broaden it to make a scheduled notification succeed.
            continue
