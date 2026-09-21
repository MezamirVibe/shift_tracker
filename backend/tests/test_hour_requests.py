from datetime import date
import unittest
import uuid
from sqlalchemy import select
import test_timesheets as fixture
from app.models import AttendanceDay, AttendanceLock, AttendanceRecord, Role, ScopeKind, User


class HourRequestTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.t = fixture.TimesheetTests('test_mixed_marks_and_unplanned_shifts_are_counted')
        await self.t.asyncSetUp()
        self.manager = self.t.actor
        self.day = date(2026, 8, 3)
        response = await self.t.client.put(f'/api/v1/attendance/{self.day}/{self.t.a.id}', json={
            'fact': 'worked', 'worked_minutes': 480, 'actual_start': '08:00', 'actual_end': '17:00', 'comment': 'Сохранить'})
        self.assertEqual(response.status_code, 200)
        await self.t.client.post(f'/api/v1/attendance/{self.day}/close', json={'planned_employee_ids': [str(self.t.a.id)]})
        self.worker = User(id=uuid.uuid4(), login='worker', password_hash='unused', employee_id=self.t.a.id,
            role=Role(id='specialist', name='Specialist', scope_kind=ScopeKind.self, permissions=['viewCalendar']))
        async with self.t.sessions() as session:
            session.add(self.worker)
            await session.commit()
        self.t.actor = self.worker

    async def asyncTearDown(self):
        await self.t.asyncTearDown()

    async def saved(self):
        async with self.t.sessions() as session:
            record = await session.get(AttendanceRecord, (self.day, self.t.a.id))
            locks = (await session.scalars(select(AttendanceLock))).all()
            days = (await session.scalars(select(AttendanceDay))).all()
            return (record.fact.value, record.worked_minutes, record.actual_start, record.actual_end,
                    record.comment, record.updated_at, len(locks), len(days))

    async def submit(self, minutes=180, request_id=None, day=None):
        return await self.t.client.post('/api/v1/hour-requests', json={'id': str(request_id or uuid.uuid4()),
            'day': str(day or self.day), 'additional_minutes': minutes, 'reason': 'Работал дольше смены'})

    async def review(self, request_id, decision='approved'):
        return await self.t.client.post(f'/api/v1/hour-requests/{request_id}/review', json={'decision': decision, 'comment': 'Проверено'})

    async def test_submission_is_separate_idempotent_and_only_one_pending_per_day(self):
        before = await self.saved()
        key = uuid.uuid4()
        first = await self.submit(request_id=key)
        self.assertEqual(first.status_code, 201, first.text)
        self.assertEqual(first.json()['base_minutes'], 480)
        self.assertEqual((await self.submit(request_id=key)).json()['id'], str(key))
        self.assertEqual((await self.submit()).status_code, 409)
        self.assertEqual((await self.t.client.get('/api/v1/hour-requests')).json()[0]['status'], 'pending')
        self.assertEqual(before, await self.saved())

    async def test_approval_adds_once_and_preserves_closed_day_times_and_comment(self):
        request_id = (await self.submit()).json()['id']
        before = await self.saved()
        self.t.actor = self.manager
        approved = await self.review(request_id)
        self.assertEqual(approved.status_code, 200, approved.text)
        after = await self.saved()
        self.assertEqual(after[1], 660)
        self.assertEqual(after[2:5], before[2:5])
        self.assertEqual(after[6:], before[6:])
        self.assertEqual((await self.review(request_id)).status_code, 200)
        self.assertEqual(await self.saved(), after)
        self.t.actor = self.worker
        own = (await self.t.client.get(f'/api/v1/self/schedule?date_from={self.day}&date_to={self.day}')).json()
        record = own['attendance'][str(self.day)][str(self.t.a.id)]
        self.assertEqual(record['workedMinutes'], 660)
        self.assertTrue(record['closed'])

    async def test_employee_cannot_review_or_read_another_employee_requests(self):
        request_id = (await self.submit()).json()['id']
        self.assertEqual((await self.review(request_id)).status_code, 403)
        self.worker.employee_id = self.t.b.id
        self.assertEqual((await self.t.client.get('/api/v1/hour-requests')).json(), [])
        self.assertEqual((await self.t.client.post(f'/api/v1/hour-requests/{request_id}/cancel')).status_code, 404)
        self.t.actor = self.manager
        self.manager.department_id = self.t.dep_b.id
        self.assertEqual((await self.t.client.get('/api/v1/hour-requests')).json(), [])
        self.assertEqual((await self.review(request_id)).status_code, 404)
        self.assertEqual((await self.saved())[1], 480)

    async def test_stale_request_cannot_overwrite_changed_attendance_and_can_be_rejected(self):
        request_id = (await self.submit()).json()['id']
        async with self.t.sessions() as session:
            record = await session.get(AttendanceRecord, (self.day, self.t.a.id))
            record.worked_minutes = 600
            await session.commit()
        self.t.actor = self.manager
        self.assertEqual((await self.review(request_id)).status_code, 409)
        self.assertEqual((await self.review(request_id, 'rejected')).status_code, 200)
        self.assertEqual((await self.saved())[1], 600)
        self.t.actor = self.worker
        self.assertEqual((await self.submit()).status_code, 201)

    async def test_cancel_and_invalid_requests_do_not_modify_attendance(self):
        before = await self.saved()
        for minutes in (0, -60, 1441, 1000):
            self.assertEqual((await self.submit(minutes)).status_code, 422)
        self.assertEqual((await self.submit(day=date(2099, 1, 1))).status_code, 422)
        request_id = (await self.submit()).json()['id']
        self.assertEqual((await self.t.client.post(f'/api/v1/hour-requests/{request_id}/cancel')).status_code, 200)
        self.t.actor = self.manager
        self.assertEqual((await self.review(request_id)).status_code, 409)
        self.assertEqual(await self.saved(), before)
