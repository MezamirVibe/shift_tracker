"""Notification API and worker checks using only in-memory SQLite and fake FCM."""
from datetime import date, datetime, timedelta, timezone
import unittest
from unittest.mock import patch
import uuid

from sqlalchemy import select

import test_timesheets as fixture
from app import main as api
from app import notifications as notices
from app.history import remember_employee
from app.models import (Employee, Notification, NotificationDevice, NotificationPreference,
                        NotificationPushJob, Role, ScopeKind, User)


class FakeFcm:
    def __init__(self, *results):
        self.results = list(results) or ['sent']
        self.payloads = []

    async def send(self, payload):
        self.payloads.append(payload)
        return self.results.pop(0) if len(self.results) > 1 else self.results[0]


class NotificationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        # Never load a real credential file or let an API response probe it.
        self.availability = patch.object(notices, 'push_available', return_value=False)
        self.availability.start()
        self.addCleanup(self.availability.stop)
        self.now = datetime(2026, 8, 3, 12, tzinfo=timezone.utc)
        self.clock = patch.object(notices, 'utcnow', return_value=self.now)
        self.clock.start()
        self.addCleanup(self.clock.stop)
        self.t = fixture.TimesheetTests('test_mixed_marks_and_unplanned_shifts_are_counted')
        await self.t.asyncSetUp()
        self.manager = self.t.actor
        role = Role(id='notification-specialist', name='Notification specialist',
                    scope_kind=ScopeKind.self, permissions=['viewCalendar'])
        self.worker = User(id=uuid.uuid4(), login='notification-worker', password_hash='unused',
                           employee_id=self.t.a.id, role=role)
        self.other = User(id=uuid.uuid4(), login='notification-other', password_hash='unused',
                          employee_id=self.t.b.id, role=role)
        async with self.t.sessions() as session:
            session.add_all([self.worker, self.other])
            await session.commit()
        self.t.actor = self.worker

    async def asyncTearDown(self):
        await self.t.asyncTearDown()

    async def preferences(self, **values):
        response = await self.t.client.put('/api/v1/notifications/preferences', json=values)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    async def register(self, **overrides):
        body = {'installation_id': str(uuid.uuid4()), 'binding_id': str(uuid.uuid4()),
                'token': 'fake-fcm-token-' + uuid.uuid4().hex, 'platform': 'android', **overrides}
        response = await self.t.client.put('/api/v1/notifications/devices', json=body)
        self.assertEqual(response.status_code, 200, response.text)
        return body

    async def emit(self, kind='hours_closed', user=None, key=None, **values):
        user = user or self.worker
        async with self.t.sessions() as session:
            event = await notices.emit_notification(session, user_id=user.id, kind=kind,
                title='Private employee name', body='Private hours and review comment',
                employee_id=user.employee_id if kind in notices.PERSONAL_KINDS else None,
                day=date(2026, 8, 3), dedupe_key=key or str(uuid.uuid4()), **values)
            await session.commit()
            return event.id if event else None

    async def jobs(self, event_id=None):
        async with self.t.sessions() as session:
            query = select(NotificationPushJob)
            if event_id:
                query = query.where(NotificationPushJob.notification_id == event_id)
            return list((await session.scalars(query)).all())

    async def device(self, body):
        async with self.t.sessions() as session:
            return await session.scalar(select(NotificationDevice).where(
                NotificationDevice.installation_id == uuid.UUID(body['installation_id'])))

    async def dispatch(self, transport, now=None):
        async with self.t.sessions() as session:
            return await notices.dispatch_pending(api, session, now or self.now, transport)

    async def prepare_push(self):
        await self.preferences(push_enabled=True, quiet_hours_enabled=False)
        return await self.register()

    async def test_preferences_defaults_partial_merge_and_strict_validation(self):
        defaults = (await self.t.client.get('/api/v1/notifications/preferences')).json()
        self.assertFalse(defaults['push_enabled'])
        self.assertFalse(defaults['push_available'])
        self.assertFalse(defaults['kinds']['shift_reminder'])
        self.assertFalse(defaults['kinds']['unfilled_days'])
        first = await self.preferences(push_enabled=True, kinds={'hours_closed': False},
                                       quiet_start='23:00', timezone='UTC')
        merged = await self.preferences(kinds={'schedule_changed': False})
        self.assertTrue(merged['push_enabled'])
        self.assertFalse(merged['kinds']['hours_closed'])
        self.assertFalse(merged['kinds']['schedule_changed'])
        self.assertTrue(merged['kinds']['request_decision'])
        self.assertEqual(merged['quiet_start'], first['quiet_start'])
        self.assertEqual(merged['timezone'], 'UTC')
        for invalid in ({'push_enabled': 'true'}, {'kinds': {'hours_closed': 1}},
                        {'kinds': {'unknown_kind': True}}, {'quiet_start': '25:00'},
                        {'quiet_start': '08:00'}, {'timezone': 'Invalid/Zone'}, {'extra': True}):
            with self.subTest(invalid=invalid):
                response = await self.t.client.put('/api/v1/notifications/preferences', json=invalid)
                self.assertEqual(response.status_code, 422, response.text)
        self.assertEqual((await self.t.client.get('/api/v1/notifications/preferences')).json(), merged)

    async def test_kind_and_master_opt_out_suppress_jobs_without_resurrection(self):
        await self.prepare_push()
        closed = await self.emit()
        changed = await self.emit('schedule_changed')
        await self.preferences(kinds={'hours_closed': False})
        self.assertEqual((await self.jobs(closed))[0].status, 'suppressed')
        self.assertEqual((await self.jobs(changed))[0].status, 'pending')
        self.assertEqual(await self.jobs(await self.emit()), [])
        await self.preferences(kinds={'hours_closed': True})
        self.assertEqual((await self.jobs(closed))[0].status, 'suppressed')
        await self.preferences(push_enabled=False)
        self.assertEqual((await self.jobs(changed))[0].status, 'suppressed')
        self.assertEqual(await self.jobs(await self.emit('schedule_changed')), [])
        await self.preferences(push_enabled=True)
        self.assertTrue(all(job.status == 'suppressed' for job in await self.jobs()))
        self.assertEqual((await self.t.client.get('/api/v1/notifications')).json()['unread_count'], 4)

    async def test_inbox_is_independent_of_push_and_emit_is_transactional_and_deduplicated(self):
        await self.register()
        first = await self.emit(key='one-transition')
        self.assertEqual(await self.emit(key='one-transition'), first)
        self.assertEqual(await self.jobs(), [])
        async with self.t.sessions() as session:
            await notices.emit_notification(session, user_id=self.worker.id, kind='hours_closed',
                title='Rolled back', body='Must not persist', employee_id=self.t.a.id,
                day=date(2026, 8, 3), dedupe_key='rollback')
            await session.rollback()
        items = (await self.t.client.get('/api/v1/notifications')).json()['items']
        self.assertEqual([item['id'] for item in items], [str(first)])

    async def test_device_refresh_is_idempotent_and_account_takeover_drops_only_old_jobs(self):
        body = await self.prepare_push()
        event_id = await self.emit()
        original = await self.device(body)
        job_id = (await self.jobs(event_id))[0].id
        await self.register(**body)
        self.assertEqual((await self.device(body)).id, original.id)
        self.assertEqual((await self.jobs(event_id))[0].id, job_id)
        self.t.actor = self.other
        takeover = await self.register(**{**body, 'binding_id': str(uuid.uuid4())})
        replacement = await self.device(takeover)
        self.assertEqual(replacement.user_id, self.other.id)
        self.assertNotEqual(replacement.id, original.id)
        self.assertEqual(await self.jobs(event_id), [])
        self.t.actor = self.worker
        self.assertEqual((await self.t.client.delete(
            '/api/v1/notifications/devices/' + body['installation_id'])).status_code, 204)
        self.assertTrue((await self.device(takeover)).active)
        self.assertEqual((await self.t.client.get('/api/v1/notifications')).json()['items'][0]['id'], str(event_id))

    async def test_token_collision_merges_installations_and_unregister_stays_suppressed(self):
        first = await self.prepare_push()
        second = await self.register()
        event_id = await self.emit()
        self.assertEqual(len(await self.jobs(event_id)), 2)
        body = await self.register(**{**first, 'token': second['token'], 'binding_id': str(uuid.uuid4())})
        async with self.t.sessions() as session:
            self.assertEqual(len((await session.scalars(select(NotificationDevice))).all()), 1)
        self.assertEqual(await self.jobs(event_id), [])
        current_event = await self.emit()
        self.assertEqual((await self.t.client.delete(
            '/api/v1/notifications/devices/' + body['installation_id'])).status_code, 204)
        self.assertFalse((await self.device(body)).active)
        self.assertEqual((await self.jobs(current_event))[0].last_error, 'unregistered')
        await self.register(**body)
        self.assertTrue((await self.device(body)).active)
        self.assertEqual((await self.jobs(current_event))[0].status, 'suppressed')

    async def test_read_ownership_current_scope_and_idempotence(self):
        own_id = await self.emit()
        foreign_id = await self.emit(user=self.other)
        response = await self.t.client.post(f'/api/v1/notifications/{foreign_id}/read')
        self.assertEqual(response.status_code, 404)
        self.assertEqual((await self.t.client.get('/api/v1/notifications')).json()['unread_count'], 1)
        first = await self.t.client.post(f'/api/v1/notifications/{own_id}/read')
        again = await self.t.client.post(f'/api/v1/notifications/{own_id}/read')
        self.assertEqual(first.status_code, 200)
        self.assertEqual(first.json()['read_at'], again.json()['read_at'])
        hidden_id = await self.emit()
        self.worker.employee_id = self.t.b.id
        self.assertEqual((await self.t.client.get('/api/v1/notifications')).json()['items'], [])
        self.assertEqual((await self.t.client.post(f'/api/v1/notifications/{hidden_id}/read')).status_code, 404)
        self.assertEqual((await self.t.client.post('/api/v1/notifications/read-all')).json(), {'updated': 0})
        async with self.t.sessions() as session:
            self.assertIsNone((await session.get(Notification, hidden_id)).read_at)
            self.assertIsNone((await session.get(Notification, foreign_id)).read_at)

    async def test_summary_loses_visibility_when_required_read_permissions_are_revoked(self):
        self.t.actor = self.manager
        summary_id = await self.emit('unfilled_days', user=self.manager)
        self.assertIsNotNone(summary_id)
        original = list(self.manager.role.permissions)
        for permission in ('viewAttendance', 'viewEmployees', 'editAttendance'):
            with self.subTest(permission=permission):
                self.manager.role.permissions = [value for value in original if value != permission]
                self.assertEqual((await self.t.client.get('/api/v1/notifications')).json()['items'], [])
                self.assertEqual((await self.t.client.post(f'/api/v1/notifications/{summary_id}/read')).status_code, 404)
                self.assertEqual((await self.t.client.post('/api/v1/notifications/read-all')).json(), {'updated': 0})
        self.manager.role.permissions = original
        self.assertEqual((await self.t.client.get('/api/v1/notifications')).json()['unread_count'], 1)
        # Even still-permitted aggregate types must not reuse a summary from a
        # broader access snapshot after one of its source permissions changes.
        delivery_id = await self.emit('delivery_failed', user=self.manager)
        self.manager.role.permissions = [value for value in original if value != 'viewEmployees']
        self.assertEqual((await self.t.client.post(f'/api/v1/notifications/{delivery_id}/read')).status_code, 404)

    async def test_employee_history_prevents_old_department_notice_becoming_visible(self):
        self.t.actor = self.manager
        async with self.t.sessions() as session:
            event = await notices.emit_notification(session, user_id=self.manager.id, kind='request_created',
                title='Old department', body='Private old record', employee_id=self.t.a.id,
                day=date(2026, 8, 3), dedupe_key='before-transfer')
            event_id = event.id
            employee = await session.get(Employee, self.t.a.id)
            employee.department_id = self.t.dep_b.id
            await remember_employee(session, employee, date(2026, 9, 1))
            await session.commit()
        self.manager.department_id = self.t.dep_b.id
        self.assertEqual((await self.t.client.get('/api/v1/notifications')).json()['items'], [])
        self.assertEqual((await self.t.client.post(f'/api/v1/notifications/{event_id}/read')).status_code, 404)

    async def test_inbox_pagination_and_read_all_reach_beyond_200_and_skip_hidden_rows(self):
        template_id = await self.emit()
        async with self.t.sessions() as session:
            template = await session.get(Notification, template_id)
            rows = [Notification(id=uuid.uuid4(), user_id=self.worker.id, kind='hours_closed',
                title='Visible', body='Visible', employee_id=self.t.a.id, day=template.day,
                scope_key=template.scope_key, dedupe_key=f'visible-{index}', created_at=self.now)
                for index in range(204)]
            visible_ids = {str(row.id) for row in rows} | {str(template_id)}
            # More than two scan batches can be hidden before the first visible row.
            rows += [Notification(id=uuid.uuid4(), user_id=self.worker.id, kind='hours_closed',
                title='Hidden', body='Hidden', employee_id=self.t.b.id, day=template.day,
                scope_key=template.scope_key, dedupe_key=f'hidden-{index}',
                created_at=self.now + timedelta(minutes=1)) for index in range(230)]
            session.add_all(rows)
            await session.commit()
        foreign_id = await self.emit(user=self.other)
        found, cursor = [], None
        for _ in range(10):
            response = await self.t.client.get('/api/v1/notifications', params={
                'page_size': 37, **({'cursor': cursor} if cursor else {})})
            self.assertEqual(response.status_code, 200, response.text)
            page = response.json()
            self.assertEqual(page['unread_count'], 205)
            found.extend(item['id'] for item in page['items'])
            cursor = page['next_cursor']
            if cursor is None:
                break
        self.assertIsNone(cursor)
        self.assertEqual(len(found), 205)
        self.assertEqual(set(found), visible_ids)
        self.assertEqual((await self.t.client.post('/api/v1/notifications/read-all')).json(), {'updated': 205})
        self.assertEqual((await self.t.client.post('/api/v1/notifications/read-all')).json(), {'updated': 0})
        self.assertEqual((await self.t.client.get('/api/v1/notifications')).json()['unread_count'], 0)
        async with self.t.sessions() as session:
            unread = list((await session.scalars(select(Notification).where(Notification.read_at.is_(None)))).all())
            self.assertEqual(len(unread), 231)
            self.assertIn(foreign_id, [event.id for event in unread])
        for params in ({'cursor': '!invalid'}, {'page_size': 0}, {'page_size': 101}):
            self.assertEqual((await self.t.client.get('/api/v1/notifications', params=params)).status_code, 422)

    async def test_successful_dispatch_only_sends_private_refresh_hint_once(self):
        body = await self.prepare_push()
        event_id = await self.emit(expires_at=self.now + timedelta(hours=2))
        transport = FakeFcm()
        self.assertTrue(await self.dispatch(transport))
        self.assertFalse(await self.dispatch(transport))
        self.assertEqual(transport.payloads, [{'message': {'token': body['token'],
            'data': {'notification_id': str(event_id), 'binding_id': body['binding_id'], 'kind': 'hours_closed'},
            'android': {'priority': 'HIGH', 'ttl': '7200s'}}}])
        job = (await self.jobs(event_id))[0]
        self.assertEqual((job.status, job.attempts, job.last_error), ('sent', 1, None))
        self.assertEqual(notices.aware(job.sent_at), self.now)

    async def test_dispatch_rechecks_read_binding_identity_permissions_and_preferences(self):
        body = await self.prepare_push()
        device_id = (await self.device(body)).id
        scenarios = ('read', 'master_off', 'kind_off', 'inactive_device', 'new_binding',
                     'new_token_version', 'inactive_user', 'new_owner', 'permission_removed', 'new_employee')
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                async with self.t.sessions() as session:
                    user = await api.load_user(session, self.worker.id)
                    device = await session.get(NotificationDevice, device_id)
                    preference = await session.get(NotificationPreference, self.worker.id)
                    user.is_active, user.token_version, user.employee_id = True, self.worker.token_version, self.t.a.id
                    user.role.permissions = ['viewCalendar']
                    device.active, device.user_id, device.binding_id = True, user.id, uuid.UUID(body['binding_id'])
                    preference.settings = {'push_enabled': True, 'quiet_hours_enabled': False}
                    await session.commit()
                event_id = await self.emit()
                async with self.t.sessions() as session:
                    event = await session.get(Notification, event_id)
                    user = await api.load_user(session, self.worker.id)
                    device = await session.get(NotificationDevice, device_id)
                    preference = await session.get(NotificationPreference, self.worker.id)
                    if scenario == 'read':
                        event.read_at = self.now
                    elif scenario == 'master_off':
                        preference.settings = {'push_enabled': False}
                    elif scenario == 'kind_off':
                        preference.settings = {'push_enabled': True, 'kinds': {'hours_closed': False}}
                    elif scenario == 'inactive_device':
                        device.active = False
                    elif scenario == 'new_binding':
                        device.binding_id = uuid.uuid4()
                    elif scenario == 'new_token_version':
                        user.token_version += 1
                    elif scenario == 'inactive_user':
                        user.is_active = False
                    elif scenario == 'new_owner':
                        device.user_id = self.other.id
                    elif scenario == 'permission_removed':
                        user.role.permissions = []
                    else:
                        # The new employee must be free before a legitimate
                        # reassignment because users.employee_id is unique.
                        other_user = await session.get(User, self.other.id)
                        other_user.employee_id = None
                        await session.flush()
                        user.employee_id = self.t.b.id
                    await session.commit()
                transport = FakeFcm()
                self.assertTrue(await self.dispatch(transport))
                job = (await self.jobs(event_id))[0]
                self.assertEqual((job.status, job.attempts, job.last_error), ('suppressed', 0, 'no_longer_allowed'))
                self.assertEqual(transport.payloads, [])

    async def test_retries_back_off_and_stop_after_six_attempts(self):
        await self.prepare_push()
        event_id = await self.emit()
        transport = FakeFcm('retry')
        due = self.now
        for attempt in range(1, 7):
            self.assertTrue(await self.dispatch(transport, due))
            job = (await self.jobs(event_id))[0]
            self.assertEqual(job.attempts, attempt)
            if attempt < 6:
                due += timedelta(seconds=60 * 2 ** (attempt - 1))
                self.assertEqual(job.status, 'pending')
                self.assertEqual(notices.aware(job.available_at), due)
                self.assertFalse(await self.dispatch(transport, due - timedelta(seconds=1)))
        self.assertEqual((job.status, job.last_error), ('failed', 'retry'))
        self.assertFalse(await self.dispatch(transport, due + timedelta(hours=1)))
        self.assertEqual(len(transport.payloads), 6)

    async def test_quiet_hours_delay_without_consuming_attempt_and_expiry_prevents_send(self):
        await self.prepare_push()
        await self.preferences(quiet_hours_enabled=True, timezone='Asia/Yekaterinburg',
                               quiet_start='22:00', quiet_end='08:00')
        quiet = datetime(2026, 8, 3, 18, tzinfo=timezone.utc)
        resume = datetime(2026, 8, 4, 3, tzinfo=timezone.utc)
        event_id = await self.emit()
        transport = FakeFcm()
        self.assertTrue(await self.dispatch(transport, quiet))
        job = (await self.jobs(event_id))[0]
        self.assertEqual((job.status, job.attempts), ('pending', 0))
        self.assertEqual(notices.aware(job.available_at), resume)
        self.assertEqual(transport.payloads, [])
        self.assertFalse(await self.dispatch(transport, resume - timedelta(seconds=1)))
        self.assertTrue(await self.dispatch(transport, resume))
        expiring_id = await self.emit(expires_at=quiet + timedelta(hours=1))
        self.assertTrue(await self.dispatch(transport, quiet))
        self.assertFalse(await self.dispatch(transport, resume))
        self.assertEqual((await self.jobs(expiring_id))[0].status, 'expired')
        self.assertEqual(len(transport.payloads), 1)

    async def test_unregistered_token_and_permanent_rejection_do_not_retry(self):
        body = await self.prepare_push()
        first = await self.emit()
        second = await self.emit('schedule_changed')
        transport = FakeFcm('unregistered')
        self.assertTrue(await self.dispatch(transport))
        self.assertFalse((await self.device(body)).active)
        self.assertTrue(await self.dispatch(transport))
        self.assertEqual(len(transport.payloads), 1)
        self.assertTrue(all(job.status == 'suppressed' for job in await self.jobs()))
        self.assertEqual({job.last_error for job in await self.jobs()}, {'unregistered', 'no_longer_allowed'})
        await self.register(**body)
        rejected_id = await self.emit()
        transport = FakeFcm('rejected')
        self.assertTrue(await self.dispatch(transport))
        job = (await self.jobs(rejected_id))[0]
        self.assertEqual((job.status, job.attempts, job.last_error), ('failed', 1, 'rejected'))
        self.assertFalse(await self.dispatch(transport, self.now + timedelta(minutes=10)))

    async def test_unavailable_fcm_never_touches_credentials_or_loses_pending_jobs(self):
        await self.prepare_push()
        pending_id = await self.emit()
        expired_id = await self.emit(expires_at=self.now - timedelta(seconds=1))
        with patch.object(notices, 'FcmTransport', side_effect=AssertionError('Real FCM forbidden')):
            self.assertFalse(await self.dispatch(None))
        self.assertEqual((await self.jobs(pending_id))[0].status, 'pending')
        self.assertEqual((await self.jobs(pending_id))[0].attempts, 0)
        self.assertEqual((await self.jobs(expired_id))[0].status, 'expired')


class QuietHourTests(unittest.TestCase):
    def test_boundaries_daytime_window_and_dst_gap(self):
        prefs = notices.normalized_preferences({'timezone': 'UTC'})
        self.assertIsNone(notices.quiet_until(prefs, datetime(2026, 8, 3, 8, tzinfo=timezone.utc)))
        self.assertEqual(notices.quiet_until(prefs, datetime(2026, 8, 3, 22, tzinfo=timezone.utc)),
                         datetime(2026, 8, 4, 8, tzinfo=timezone.utc))
        prefs.update(quiet_start='09:00', quiet_end='17:00')
        self.assertEqual(notices.quiet_until(prefs, datetime(2026, 8, 3, 9, 30, tzinfo=timezone.utc)),
                         datetime(2026, 8, 3, 17, tzinfo=timezone.utc))
        prefs.update(timezone='Europe/Berlin', quiet_start='22:00', quiet_end='02:30')
        # On spring clock change, 02:30 does not exist; resume at 03:00 local.
        self.assertEqual(notices.quiet_until(prefs, datetime(2026, 3, 29, 0, 45, tzinfo=timezone.utc)),
                         datetime(2026, 3, 29, 1, tzinfo=timezone.utc))
