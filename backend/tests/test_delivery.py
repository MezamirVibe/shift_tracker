from datetime import datetime, timedelta, timezone
import hashlib
import unittest
from unittest.mock import patch

import test_timesheets as fixtures
from app import main as api
from app.models import ReportDelivery, DeliveryAttempt
from app.telegram_delivery import DeliverySettings, next_run, report_period, run_due_once, poll_updates
from sqlalchemy import select, func


class FakeTelegram:
    def __init__(self):
        self.sent, self.calls, self.updates = [], [], []
        self.fail = False

    async def call(self, method, data, files=None):
        self.calls.append((method, data))
        if method == 'getUpdates':
            result, self.updates = self.updates, []
            return result
        if method == 'getChatMember': return {'status': 'administrator'}
        return {'message_id': 1}

    async def document(self, chat_id, filename, content, caption):
        self.sent.append((chat_id, filename, content, caption))
        if self.fail: raise RuntimeError('Нет подтверждения от Telegram')
        return {'message_id': 1}


class ScheduleTests(unittest.TestCase):
    def test_monthly_uses_local_zone_and_previous_month(self):
        config = DeliverySettings(hour=9, timezone='Asia/Yekaterinburg')
        due = next_run(config, datetime(2026, 8, 31, 23, tzinfo=timezone.utc))
        self.assertEqual(due, datetime(2026, 9, 1, 4, tzinfo=timezone.utc))
        self.assertEqual(report_period(config, due), (2026, 8))
        self.assertEqual(report_period(config, datetime(2027, 1, 1, 4, tzinfo=timezone.utc)), (2026, 12))

    def test_weekly_and_dst_do_not_repeat(self):
        cfg = DeliverySettings(cadence='weekly', weekday=1, timezone='UTC')
        self.assertEqual(next_run(cfg, datetime(2026, 9, 20, 10, tzinfo=timezone.utc)).isoweekday(), 1)
        cfg = DeliverySettings(cadence='daily', hour=2, minute=30, timezone='Europe/Berlin')
        due = next_run(cfg, datetime(2026, 3, 28, 23, tzinfo=timezone.utc))
        self.assertEqual(due.date().isoformat(), '2026-03-30')
        with self.assertRaises(ValueError): DeliverySettings(timezone='../etc/passwd')
        with self.assertRaises(ValueError): DeliverySettings(month_day=31)


class DeliveryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.t = fixtures.TimesheetTests('test_mixed_marks_and_unplanned_shifts_are_counted')
        await self.t.asyncSetUp()
        self.transport = FakeTelegram()
        self.now = datetime.now(timezone.utc).replace(second=0, microsecond=0)

    async def asyncTearDown(self):
        await self.t.asyncTearDown()

    async def schedule(self, *, unfinished=True, enabled=True):
        cfg = DeliverySettings(enabled=enabled, cadence='daily', period='previous', include_unfinished=unfinished)
        async with self.t.sessions() as session:
            session.add(ReportDelivery(user_id=self.t.actor.id, chat_id='123', chat_title='Test',
                telegram_actor_id='12', enabled=enabled, next_run_at=self.now,
                settings=cfg.model_dump(mode='json')))
            await session.commit()

    async def test_no_bot_is_safe_default_and_cannot_enable(self):
        status = await self.t.client.get('/api/v1/reports/delivery')
        self.assertEqual(status.status_code, 200)
        self.assertFalse(status.json()['configured'])
        self.assertFalse(status.json()['enabled'])
        self.assertEqual((await self.t.client.post('/api/v1/reports/delivery/pair')).status_code, 409)
        self.assertEqual((await self.t.client.put('/api/v1/reports/delivery', json={'enabled': True})).status_code, 409)

    async def test_delivery_is_once_and_contains_only_own_department(self):
        await self.schedule()
        self.assertTrue(await run_due_once(api, self.t.sessions, self.transport, self.now))
        self.assertFalse(await run_due_once(api, self.t.sessions, self.transport, self.now))
        self.assertEqual(len(self.transport.sent), 1)
        from zipfile import ZipFile
        from io import BytesIO
        with ZipFile(BytesIO(self.transport.sent[0][2])) as archive:
            content = archive.read('xl/worksheets/sheet1.xml').decode()
        self.assertIn('Сотрудник А', content)
        self.assertNotIn('Сотрудник Б', content)
        async with self.t.sessions() as session:
            self.assertEqual(await session.scalar(select(func.count()).select_from(DeliveryAttempt)), 1)

    async def test_incomplete_and_disabled_reports_are_not_sent(self):
        await self.schedule(unfinished=False)
        await run_due_once(api, self.t.sessions, self.transport, self.now)
        self.assertEqual(self.transport.sent, [])
        async with self.t.sessions() as session:
            delivery = await session.get(ReportDelivery, self.t.actor.id)
            self.assertIn('не заполнен', delivery.last_status)
            delivery.enabled = False
            delivery.next_run_at = self.now
            await session.commit()
        self.assertFalse(await run_due_once(api, self.t.sessions, self.transport, self.now))

    async def test_unknown_send_outcome_is_not_retried(self):
        await self.schedule()
        self.transport.fail = True
        await run_due_once(api, self.t.sessions, self.transport, self.now)
        await run_due_once(api, self.t.sessions, self.transport, self.now)
        self.assertEqual(len(self.transport.sent), 1)

    async def test_pair_needs_app_confirmation_and_cannot_be_replayed(self):
        with patch.object(api.settings, 'TELEGRAM_BOT_TOKEN', 'test-token'), patch.object(api.settings, 'TELEGRAM_BOT_USERNAME', 'chereda_test_bot'):
            result = await self.t.client.post('/api/v1/reports/delivery/pair')
        self.assertEqual(result.status_code, 200, result.text)
        code = result.json()['private_link'].split('start=')[1]
        def message(chat, update):
            return {'update_id': update, 'message': {'text': '/start ' + code,
                'from': {'id': 12, 'is_bot': False}, 'chat': {'id': chat, 'type': 'private', 'first_name': 'Test'}}}
        self.transport.updates = [message(123, 1), message(456, 2)]
        async with self.t.sessions() as session:
            await poll_updates(session, api, self.transport)
        status = (await self.t.client.get('/api/v1/reports/delivery')).json()
        self.assertIsNone(status['chat_id'])
        self.assertEqual(status['candidate_chat_id'], '123')
        bad = await self.t.client.post('/api/v1/reports/delivery/confirm', json={'chat_id': '456'})
        self.assertEqual(bad.status_code, 409)
        good = await self.t.client.post('/api/v1/reports/delivery/confirm', json={'chat_id': '123'})
        self.assertEqual(good.status_code, 200)
        status = (await self.t.client.get('/api/v1/reports/delivery')).json()
        self.assertEqual(status['chat_id'], '123')
        self.assertFalse(status['enabled'])
        self.assertEqual((await self.t.client.post('/api/v1/reports/delivery/confirm', json={'chat_id':'123'})).status_code, 409)

    async def test_bot_time_only_from_confirmed_sender(self):
        await self.schedule()
        def message(sender, update):
            return {'update_id': update, 'message': {'text': '/time 17:25',
                'from': {'id': sender, 'is_bot': False}, 'chat': {'id':123, 'type':'private'}}}
        self.transport.updates = [message(999, 1)]
        async with self.t.sessions() as session:
            await poll_updates(session, api, self.transport)
            self.assertEqual((await session.get(ReportDelivery, self.t.actor.id)).settings['hour'], 9)
        self.transport.updates = [message(12, 2)]
        async with self.t.sessions() as session:
            await poll_updates(session, api, self.transport)
            cfg = (await session.get(ReportDelivery, self.t.actor.id)).settings
            self.assertEqual((cfg['hour'], cfg['minute']), (17,25))
