from datetime import date, datetime, timedelta, timezone
import unittest
import uuid
from sqlalchemy import select
import test_timesheets as fixture
from app.history import remember_employee
from app.models import (AttendanceDay, AttendanceLock, AttendanceRecord, AuditEvent, Employee,
                        HourRequest, Role, ScopeKind, User)


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

    async def test_comment_only_change_does_not_block_approval_or_overwrite_comment(self):
        request_id = (await self.submit()).json()['id']
        self.t.actor = self.manager
        preview = (await self.t.client.get(f'/api/v1/hour-requests/{request_id}/preview')).json()
        async with self.t.sessions() as session:
            record = await session.get(AttendanceRecord, (self.day, self.t.a.id))
            record.comment = 'Новый комментарий руководителя'
            await session.commit()
        latest = (await self.t.client.get(f'/api/v1/hour-requests/{request_id}/preview')).json()
        self.assertFalse(latest['hours_changed'])
        self.assertEqual(latest['revision'], preview['revision'])
        self.assertEqual([change['field'] for change in latest['changes']], ['comment'])
        response = await self.t.client.post(f'/api/v1/hour-requests/{request_id}/review', json={
            'decision': 'approved', 'revision': preview['revision'], 'comment': ''})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['applied_minutes'], 660)
        saved = await self.saved()
        self.assertEqual(saved[1], 660)
        self.assertEqual(saved[4], 'Новый комментарий руководителя')

    async def test_changed_hours_require_fresh_preview_and_explicit_current_total(self):
        request_id = (await self.submit()).json()['id']
        self.t.actor = self.manager
        initial = (await self.t.client.get(f'/api/v1/hour-requests/{request_id}/preview')).json()
        async with self.t.sessions() as session:
            record = await session.get(AttendanceRecord, (self.day, self.t.a.id))
            record.worked_minutes = 600
            await session.commit()
        preview = (await self.t.client.get(f'/api/v1/hour-requests/{request_id}/preview')).json()
        self.assertTrue(preview['hours_changed'])
        self.assertEqual(preview['proposed_minutes'], 780)
        for payload in (
            {'revision': initial['revision'], 'confirmed_minutes': 780},
            {'revision': preview['revision']},
            {'revision': preview['revision'], 'confirmed_minutes': 660},
        ):
            response = await self.t.client.post(f'/api/v1/hour-requests/{request_id}/review', json={
                'decision': 'approved', **payload})
            self.assertEqual(response.status_code, 409, response.text)
            self.assertEqual((await self.saved())[1], 600)
        response = await self.t.client.post(f'/api/v1/hour-requests/{request_id}/review', json={
            'decision': 'approved', 'revision': preview['revision'], 'confirmed_minutes': 780})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['applied_minutes'], 780)
        self.assertEqual((await self.saved())[1], 780)
        # Retries return the original outcome, never add the delta a second time.
        self.assertEqual((await self.review(request_id)).status_code, 200)
        self.assertEqual((await self.saved())[1], 780)

    async def test_rejection_requires_meaningful_reason(self):
        request_id = (await self.submit()).json()['id']
        before = await self.saved()
        self.t.actor = self.manager
        for reason in ('', '  ', 'no'):
            response = await self.t.client.post(f'/api/v1/hour-requests/{request_id}/review', json={
                'decision': 'rejected', 'comment': reason})
            self.assertEqual(response.status_code, 422)
        pending = (await self.t.client.get('/api/v1/hour-requests/page?status=pending')).json()
        self.assertEqual(pending['pending_count'], 1)
        self.assertEqual((await self.review(request_id, 'rejected')).status_code, 200)
        summary = (await self.t.client.get('/api/v1/hour-requests/summary')).json()
        self.assertEqual(summary['pending_count'], 0)
        self.assertEqual(summary['recent_responses'][0]['review_comment'], 'Проверено')
        self.assertEqual(await self.saved(), before)

    async def test_pagination_reaches_old_requests_without_duplicates_and_stays_scoped(self):
        pending_id = (await self.submit()).json()['id']
        same_time = datetime(2026, 8, 1, tzinfo=timezone.utc)
        async with self.t.sessions() as session:
            session.add_all([HourRequest(id=uuid.uuid4(), employee_id=self.t.a.id, requester_id=self.worker.id,
                day=self.day - timedelta(days=i), additional_minutes=60, baseline={'minutes': 480},
                reason='Старый запрос', status='cancelled', created_at=same_time) for i in range(205)])
            session.add(HourRequest(id=uuid.uuid4(), employee_id=self.t.b.id, day=self.day,
                additional_minutes=60, baseline={'minutes': 480}, reason='Чужой запрос', status='pending'))
            await session.commit()
        found, cursor = [], None
        while True:
            response = await self.t.client.get('/api/v1/hour-requests/page', params={
                'page_size': 37, **({'cursor': cursor} if cursor else {})})
            self.assertEqual(response.status_code, 200, response.text)
            page = response.json()
            self.assertEqual(page['pending_count'], 1)
            self.assertTrue(all(item['employee_id'] == str(self.t.a.id) for item in page['items']))
            found.extend(item['id'] for item in page['items'])
            cursor = page['next_cursor']
            if not cursor:
                break
        self.assertEqual(len(found), 206)
        self.assertEqual(len(set(found)), 206)
        self.assertIn(pending_id, found)
        day = (await self.t.client.get(f'/api/v1/hour-requests/page?day={self.day}&status=pending')).json()
        self.assertEqual([item['id'] for item in day['items']], [pending_id])
        for params in ({'cursor': '!invalid'}, {'page_size': 101}, {'date_from': '2026-09-01', 'date_to': '2026-08-01'}):
            self.assertEqual((await self.t.client.get('/api/v1/hour-requests/page', params=params)).status_code, 422)

    async def test_history_records_real_changes_request_link_actor_and_preserves_other_fields(self):
        request_id = (await self.submit()).json()['id']
        self.t.actor = self.manager
        self.assertEqual((await self.review(request_id)).status_code, 200)
        # Legacy audit rows with no before/after must not become invented details.
        async with self.t.sessions() as session:
            session.add(AuditEvent(actor_id=self.manager.id, action='set_fact', entity_type='attendance',
                                   entity_id=f'{self.day}:{self.t.a.id}', details={}))
            await session.commit()
        self.t.actor = self.worker  # viewCalendar alone permits own history, not directory.
        response = await self.t.client.get(f'/api/v1/attendance/history?employee_id={self.t.a.id}&page_size=1')
        self.assertEqual(response.status_code, 200, response.text)
        item = response.json()['items'][0]
        self.assertEqual(item['before']['minutes'], 480)
        self.assertEqual(item['after']['minutes'], 660)
        self.assertEqual(item['request_id'], request_id)
        self.assertEqual(item['actor_name'], 'manager')
        self.assertEqual(item['reason'], 'Проверено')
        for field in ('start', 'end', 'comment', 'closed'):
            self.assertEqual(item['before'][field], item['after'][field])
        self.assertTrue(item['after']['closed'])
        cursor = response.json()['next_cursor']
        next_page = (await self.t.client.get('/api/v1/attendance/history', params={
            'employee_id': str(self.t.a.id), 'cursor': cursor, 'page_size': 10})).json()
        self.assertEqual([event['action'] for event in next_page['items']], ['close', 'manual'])
        self.assertIsNone(next_page['next_cursor'])
        self.assertEqual((await self.t.client.get(f'/api/v1/attendance/history?employee_id={self.t.b.id}')).status_code, 404)
        self.assertEqual((await self.t.client.get(f'/api/v1/hour-requests/{request_id}/preview')).status_code, 403)

    async def test_history_does_not_leak_previous_department_events(self):
        async with self.t.sessions() as session:
            employee = await session.get(Employee, self.t.a.id)
            employee.department_id = self.t.dep_b.id
            await remember_employee(session, employee, date(2026, 9, 1))
            await session.commit()
        self.t.actor = self.manager
        self.manager.department_id = self.t.dep_b.id
        response = await self.t.client.get(f'/api/v1/attendance/history?employee_id={self.t.a.id}')
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['items'], [])
        response = await self.t.client.get(f'/api/v1/attendance/history?employee_id={self.t.a.id}&day={self.day}')
        self.assertEqual(response.status_code, 404)

    async def test_bulk_close_reopen_history_only_tracks_effective_changes(self):
        self.t.actor = self.manager
        target = date(2026, 8, 4)
        path = f'/api/v1/attendance/{target}'
        body = {'records': [{'employee_id': str(self.t.a.id), 'fact': 'worked', 'worked_minutes': 480}]}
        self.assertEqual((await self.t.client.put(path, json=body)).status_code, 204)
        self.assertEqual((await self.t.client.put(path, json=body)).status_code, 204)
        self.assertEqual((await self.t.client.post(path + '/close', json={'planned_employee_ids': [str(self.t.a.id)]})).status_code, 204)
        self.assertEqual((await self.t.client.post(path + '/reopen', json={'employee_ids': [str(self.t.a.id)]})).status_code, 204)
        response = await self.t.client.get(f'/api/v1/attendance/history?employee_id={self.t.a.id}&day={target}')
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual([event['action'] for event in response.json()['items']], ['reopen', 'close', 'bulk'])

    async def test_action_days_is_readonly_and_uses_historical_scope(self):
        async with self.t.sessions() as session:
            before = (
                len((await session.scalars(select(AttendanceRecord))).all()),
                len((await session.scalars(select(AttendanceLock))).all()),
                len((await session.scalars(select(AuditEvent))).all()),
            )
        self.t.actor = self.manager
        response = await self.t.client.get(
            '/api/v1/attendance/action-days?date_from=2026-08-03&date_to=2026-08-04')
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json(), {
            'days': [{'day': '2026-08-04', 'unfilled': 1, 'unclosed': 1}]})
        async with self.t.sessions() as session:
            after = (
                len((await session.scalars(select(AttendanceRecord))).all()),
                len((await session.scalars(select(AttendanceLock))).all()),
                len((await session.scalars(select(AuditEvent))).all()),
            )
        self.assertEqual(after, before)
        self.t.actor = self.worker
        self.assertEqual((await self.t.client.get(
            '/api/v1/attendance/action-days?date_from=2026-08-03&date_to=2026-08-04')).status_code, 403)
