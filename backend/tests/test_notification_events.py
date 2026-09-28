from datetime import date, datetime, timezone
import unittest
import uuid

from sqlalchemy import select

import test_timesheets as fixture
from app import main as api
from app.models import (AttendanceRecord, Notification, NotificationPreference,
                        Role, ScopeKind, User)
from app.notification_events import duration
from app.notifications_scheduler import schedule_notifications, unfinished_counts


class NotificationEventTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.t = fixture.TimesheetTests('test_mixed_marks_and_unplanned_shifts_are_counted')
        await self.t.asyncSetUp()
        self.manager = self.t.actor
        self.worker = User(id=uuid.uuid4(), login='notification-worker', password_hash='unused',
            employee_id=self.t.a.id, role=Role(id='notification-worker', name='Notification worker',
            scope_kind=ScopeKind.self, permissions=['viewCalendar', 'viewAttendance']))
        async with self.t.sessions() as session:
            session.add(self.worker)
            await session.commit()

    async def asyncTearDown(self):
        await self.t.asyncTearDown()

    async def events(self, user_id=None):
        async with self.t.sessions() as session:
            return (await session.scalars(select(Notification).where(
                Notification.user_id == (user_id or self.worker.id)).order_by(Notification.created_at))).all()

    async def test_close_reopen_are_new_events_and_duplicate_close_does_not_repeat(self):
        day = date(2026, 8, 3)
        self.assertEqual((await self.t.mark(str(day), minutes=660)).status_code, 200)
        close_body = {'planned_employee_ids': [str(self.t.a.id)]}
        for _ in range(2):
            response = await self.t.client.post(f'/api/v1/attendance/{day}/close', json=close_body)
            self.assertEqual(response.status_code, 204, response.text)
        notices = await self.events()
        self.assertEqual(len(notices), 1)
        self.assertEqual(notices[0].kind, 'hours_closed')
        self.assertIn('11 ч', notices[0].body)
        self.assertEqual(await self.events(self.manager.id), [])
        response = await self.t.client.post(f'/api/v1/attendance/{day}/reopen',
                                            json={'employee_ids': [str(self.t.a.id)]})
        self.assertEqual(response.status_code, 204)
        self.assertEqual(len(await self.events()), 2)
        async with self.t.sessions() as session:
            record = await session.get(AttendanceRecord, (day, self.t.a.id))
            self.assertEqual(record.worked_minutes, 660)

    async def test_schedule_noop_and_non_schedule_changes_do_not_notify(self):
        url = f'/api/v1/employees/{self.t.a.id}'
        for patch in ({'shift_hours': 9}, {'full_name': 'Новое имя'}):
            result = await self.t.client.patch(url, json=patch)
            self.assertEqual(result.status_code, 200, result.text)
        self.assertEqual(await self.events(), [])
        self.assertEqual((await self.t.client.patch(url, json={'shift_hours': 12})).status_code, 200)
        notices = await self.events()
        self.assertEqual([n.kind for n in notices], ['schedule_changed'])

    async def test_request_creation_and_decision_are_once_and_hours_preserved(self):
        day = date(2026, 8, 3)
        await self.t.mark(str(day), minutes=480)
        self.t.actor = self.worker
        key = str(uuid.uuid4())
        body = {'id': key, 'day': str(day), 'additional_minutes': 180, 'reason': 'Работал дольше'}
        for _ in range(2):
            response = await self.t.client.post('/api/v1/hour-requests', json=body)
            self.assertEqual(response.status_code, 201, response.text)
        self.assertEqual([n.kind for n in await self.events(self.manager.id)], ['request_created'])
        self.t.actor = self.manager
        for _ in range(2):
            result = await self.t.client.post(f'/api/v1/hour-requests/{key}/review',
                json={'decision': 'approved', 'comment': 'Проверено'})
            self.assertEqual(result.status_code, 200, result.text)
        notices = await self.events()
        self.assertEqual([n.kind for n in notices], ['request_decision'])
        self.assertIn('11 ч', notices[0].body)
        async with self.t.sessions() as session:
            self.assertEqual((await session.get(AttendanceRecord, (day, self.t.a.id))).worked_minutes, 660)

    async def test_reminders_are_opt_in_and_once_in_local_timezone_without_push(self):
        # Monday evening in Yekaterinburg; Tuesday is a planned working day.
        early = datetime(2026, 8, 3, 14, 59, tzinfo=timezone.utc)
        due = datetime(2026, 8, 3, 15, 0, tzinfo=timezone.utc)
        async with self.t.sessions() as session:
            await schedule_notifications(api, session, due)
            await session.commit()
        self.assertEqual(await self.events(), [])
        async with self.t.sessions() as session:
            session.add(NotificationPreference(user_id=self.worker.id,
                settings={'push_enabled': False, 'kinds': {'shift_reminder': True}}))
            await session.commit()
        async with self.t.sessions() as session:
            await schedule_notifications(api, session, early)
            await session.commit()
        self.assertEqual(await self.events(), [])
        for _ in range(2):
            async with self.t.sessions() as session:
                await schedule_notifications(api, session, due)
                await session.commit()
        notices = await self.events()
        self.assertEqual([n.kind for n in notices], ['shift_reminder'])
        self.assertEqual(notices[0].day, date(2026, 8, 4))
        self.assertIn('8 ч', notices[0].body)

    async def test_summary_only_in_allowed_department(self):
        async with self.t.sessions() as session:
            session.add(NotificationPreference(user_id=self.manager.id,
                settings={'kinds': {'unfilled_days': True}}))
            await session.commit()
        for _ in range(2):
            async with self.t.sessions() as session:
                await schedule_notifications(api, session, datetime(2026, 8, 3, 13, tzinfo=timezone.utc))
                await session.commit()
        notices = await self.events(self.manager.id)
        self.assertEqual(len(notices), 1)
        self.assertEqual(notices[0].kind, 'unfilled_days')
        self.assertIn('отметками — 1', notices[0].body)
        self.assertEqual(await self.events(), [])


class NotificationTextTests(unittest.TestCase):
    def test_duration_and_summary_count_dates_not_people_or_future(self):
        self.assertEqual(duration(660), '11 ч')
        self.assertEqual(duration(495), '8 ч 15 мин')
        day = {'date': '2026-08-03', 'planned': True, 'fact': 'none', 'closed': False}
        future = {**day, 'date': '2026-08-04'}
        report = {'rows': [{'days': [day, future]}, {'days': [day]}]}
        self.assertEqual(unfinished_counts(report, date(2026, 8, 3)), (1, 1))
