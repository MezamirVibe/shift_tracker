"""Organization boundaries: public codes are selectors, never authorization."""
import unittest
from unittest.mock import patch
import jwt
import test_timesheets as fixtures
from app import security
from app.main import app, current_user, settings
from app.models import OrganizationIdentity
from app.organization import bind_database


class OrganizationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.t = fixtures.TimesheetTests('test_mixed_marks_and_unplanned_shifts_are_counted')
        await self.t.asyncSetUp()

    async def asyncTearDown(self):
        await self.t.asyncTearDown()

    async def test_public_metadata_exposes_no_secrets_and_header_is_checked(self):
        response = await self.t.client.get('/api/v1/organization')
        self.assertEqual(response.json(), {'code': settings.ORGANIZATION_CODE,
                                          'name': settings.ORGANIZATION_NAME})
        self.assertEqual(response.headers['x-organization-code'], settings.ORGANIZATION_CODE)
        self.assertEqual(response.headers['cache-control'], 'no-store')
        for path in ['/api/v1/organization', '/api/v1/employees', '/api/v1/reports/month?year=2026&month=8']:
            wrong = await self.t.client.get(path, headers={'X-Organization-Code': 'other-company'})
            self.assertEqual(wrong.status_code, 404)

    async def test_foreign_audience_is_rejected_even_with_shared_key_and_identical_user(self):
        app.dependency_overrides.pop(current_user)
        actor = self.t.actor
        token = security.create_access_token(actor.id, actor.token_version)
        response = await self.t.client.get('/api/v1/auth/me', headers={'Authorization': f'Bearer {token}'})
        self.assertEqual(response.status_code, 200, response.text)
        with patch.object(security.settings, 'ORGANIZATION_CODE', 'other-company'):
            foreign = security.create_access_token(actor.id, actor.token_version)
        response = await self.t.client.get('/api/v1/auth/me', headers={'Authorization': f'Bearer {foreign}'})
        self.assertEqual(response.status_code, 401)
        payload = security.decode_access_token(token)
        payload.pop('aud')
        legacy = jwt.encode(payload, settings.JWT_SECRET, algorithm='HS256')
        response = await self.t.client.get('/api/v1/auth/me', headers={'Authorization': f'Bearer {legacy}'})
        self.assertEqual(response.status_code, 401)

    async def test_database_cannot_be_reassigned_to_another_organization(self):
        async with self.t.sessions() as session:
            await bind_database(session, 'company-a')
            await bind_database(session, 'company-a')
            with self.assertRaisesRegex(RuntimeError, 'different organization'):
                await bind_database(session, 'company-b')
            await session.rollback()
            self.assertEqual((await session.get(OrganizationIdentity, 1)).code, 'company-a')
