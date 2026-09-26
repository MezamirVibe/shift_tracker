import unittest
import uuid
from unittest.mock import patch
import test_timesheets as fixtures
from app.config import get_settings
from app.models import OrganizationRegistration, Employee, User
from app.security import verify_password
from sqlalchemy import select, func


class RegistrationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.t = fixtures.TimesheetTests('test_mixed_marks_and_unplanned_shifts_are_counted')
        await self.t.asyncSetUp()
        self.settings = get_settings()
        self.old = self.settings.PUBLIC_REGISTRATION
        self.settings.PUBLIC_REGISTRATION = True
        self.body = {'request_id': str(uuid.uuid4()), 'claim_secret': 'ab' * 32,
                     'name': 'Новая организация', 'login': 'owner', 'password': 'password-at-least-12'}

    async def asyncTearDown(self):
        self.settings.PUBLIC_REGISTRATION = self.old
        await self.t.asyncTearDown()

    async def test_signup_is_idempotent_and_never_joins_existing_tenant(self):
        first = await self.t.client.post('/api/v1/registration', json=self.body)
        self.assertEqual(first.status_code, 202, first.text)
        second = await self.t.client.post('/api/v1/registration', json=self.body)
        self.assertEqual(first.json(), second.json())
        self.assertRegex(first.json()['code'], r'^org-[a-f0-9]{16}$')
        self.assertNotIn('password', first.text)
        async with self.t.sessions() as session:
            job = await session.get(OrganizationRegistration, uuid.UUID(self.body['request_id']))
            self.assertTrue(verify_password(self.body['password'], job.password_hash))
            self.assertNotEqual(job.secret_hash, self.body['claim_secret'])
            self.assertEqual(await session.scalar(select(func.count()).select_from(Employee)), 2)
            self.assertEqual(await session.scalar(select(func.count()).select_from(User)), 1)
        status = await self.t.client.post('/api/v1/registration/status', json={k:self.body[k] for k in ('request_id','claim_secret')})
        self.assertEqual(status.status_code, 200)
        self.assertEqual(status.json()['status'], 'pending')
        bad = {**self.body, 'claim_secret': 'cc' * 32}
        self.assertEqual((await self.t.client.post('/api/v1/registration/status', json=bad)).status_code, 404)
        self.assertEqual((await self.t.client.post('/api/v1/registration', json=bad)).status_code, 409)

    async def test_disabled_tenant_cannot_register_and_unsafe_input_rejected(self):
        self.settings.PUBLIC_REGISTRATION = False
        self.assertEqual((await self.t.client.post('/api/v1/registration', json=self.body)).status_code, 503)
        self.settings.PUBLIC_REGISTRATION = True
        for field, value in [('password', 'short'), ('name', 'X\nJWT_SECRET=bad'), ('login', '../bad')]:
            result = await self.t.client.post('/api/v1/registration', json={**self.body, field:value})
            self.assertEqual(result.status_code, 422)

    async def test_ip_limit_applies_before_another_password_hash(self):
        for _ in range(2):
            result = await self.t.client.post('/api/v1/registration', json={**self.body, 'request_id':str(uuid.uuid4())})
            self.assertEqual(result.status_code, 202)
        with patch('app.registration.hash_password', side_effect=AssertionError('must not hash')):
            result = await self.t.client.post('/api/v1/registration', json={**self.body, 'request_id':str(uuid.uuid4())})
            self.assertEqual(result.status_code, 429)


if __name__ == '__main__':
    unittest.main()
