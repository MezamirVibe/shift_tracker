"""Regression coverage for the September attendance/security review."""
from datetime import date
import unittest
import uuid

import test_timesheets as fixtures
from app.main import app, current_user, employees
from app.history import remember_employee
from app.models import (Employee, Group, Position, RefreshToken, Role, ScopeKind,
                        User, UserPreference)
from app.security import create_access_token, new_refresh_token


class RegressionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.t = fixtures.TimesheetTests('test_mixed_marks_and_unplanned_shifts_are_counted')
        await self.t.asyncSetUp()
        self.manager = self.t.actor

    async def asyncTearDown(self):
        await self.t.asyncTearDown()

    async def admin(self):
        async with self.t.sessions() as session:
            role = Role(id='super_admin', name='Admin', scope_kind=ScopeKind.all, permissions=[])
            actor = User(id=uuid.uuid4(), login='admin', password_hash='unused', role=role)
            session.add_all([role, actor])
            await session.commit()
            self.t.actor = actor
        return actor

    async def token(self):
        token_id, raw, digest, expires = new_refresh_token()
        async with self.t.sessions() as session:
            session.add(RefreshToken(id=token_id, user_id=self.manager.id,
                                     token_hash=digest, expires_at=expires))
            await session.commit()
        return raw

    async def test_reset_password_revokes_all_old_sessions(self):
        old_access = create_access_token(self.manager.id, self.manager.token_version)
        old_tokens = [await self.token(), await self.token()]
        await self.admin()
        response = await self.t.client.post(f'/api/v1/users/{self.manager.id}/reset-password')
        self.assertEqual(response.status_code, 200)
        new_password = response.json()['temporary_password']
        for raw in old_tokens:
            refreshed = await self.t.client.post('/api/v1/auth/refresh', json={'refresh_token': raw})
            self.assertEqual(refreshed.status_code, 401, refreshed.text)
        app.dependency_overrides.pop(current_user)
        response = await self.t.client.get('/api/v1/auth/me', headers={'Authorization': f'Bearer {old_access}'})
        self.assertEqual(response.status_code, 401)
        response = await self.t.client.post('/api/v1/auth/login', json={
            'login': self.manager.login, 'password': new_password})
        self.assertEqual(response.status_code, 200, response.text)

    async def test_refresh_rotation_rejects_reuse(self):
        raw = await self.token()
        first = await self.t.client.post('/api/v1/auth/refresh', json={'refresh_token': raw})
        self.assertEqual(first.status_code, 200, first.text)
        again = await self.t.client.post('/api/v1/auth/refresh', json={'refresh_token': raw})
        self.assertEqual(again.status_code, 401)
        next_token = await self.t.client.post('/api/v1/auth/refresh', json={
            'refresh_token': first.json()['refresh_token']})
        self.assertEqual(next_token.status_code, 200)

    async def test_deactivation_then_reactivation_does_not_restore_sessions(self):
        raw = await self.token()
        await self.admin()
        self.assertEqual((await self.t.client.delete(f'/api/v1/users/{self.manager.id}')).status_code, 204)
        response = await self.t.client.patch(f'/api/v1/users/{self.manager.id}', json={
            'role_id': 'manager', 'last_name': 'Test', 'first_name': 'Manager',
            'department_id': str(self.t.dep_a.id), 'is_active': True})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual((await self.t.client.post('/api/v1/auth/refresh',
                         json={'refresh_token': raw})).status_code, 401)

    async def test_manager_cannot_mutate_foreign_or_global_structure(self):
        async with self.t.sessions() as session:
            own = Group(id=uuid.uuid4(), department_id=self.t.dep_a.id, name='Own')
            foreign = Group(id=uuid.uuid4(), department_id=self.t.dep_b.id, name='Foreign')
            position = Position(id=uuid.uuid4(), name='Shared position')
            session.add_all([own, foreign, position])
            await session.commit()
        for method, url, body in [
            ('PATCH', f'/api/v1/departments/{self.t.dep_b.id}', {'name': 'Wrong'}),
            ('DELETE', f'/api/v1/departments/{self.t.dep_b.id}', None),
            ('POST', '/api/v1/departments', {'name': 'Wrong'}),
            ('POST', '/api/v1/groups', {'name': 'Wrong', 'department_id': str(self.t.dep_b.id)}),
            ('PATCH', f'/api/v1/groups/{foreign.id}', {'name': 'Wrong', 'department_id': str(self.t.dep_a.id)}),
            ('DELETE', f'/api/v1/groups/{foreign.id}', None),
            ('PATCH', f'/api/v1/groups/{own.id}', {'name': 'Own', 'department_id': str(self.t.dep_b.id)}),
            ('PATCH', f'/api/v1/positions/{position.id}', {'name': 'Wrong'}),
            ('DELETE', f'/api/v1/positions/{position.id}', None),
        ]:
            response = await self.t.client.request(method, url, json=body)
            self.assertIn(response.status_code, (403, 404), (method, url, response.text))
        self.assertEqual((await self.t.client.patch(f'/api/v1/departments/{self.t.dep_a.id}',
                         json={'name': 'Own renamed'})).status_code, 200)
        self.assertEqual((await self.t.client.patch(f'/api/v1/groups/{own.id}', json={
            'name': 'Own renamed', 'department_id': str(self.t.dep_a.id)})).status_code, 200)
        self.assertEqual((await self.t.client.post('/api/v1/positions', json={'name': 'New position'})).status_code, 201)
        departments = (await self.t.client.get('/api/v1/departments')).json()
        groups = (await self.t.client.get('/api/v1/groups')).json()
        self.assertEqual({row['id'] for row in departments}, {str(self.t.dep_a.id)})
        self.assertEqual({row['id'] for row in groups}, {str(own.id)})

    async def test_hidden_group_cannot_be_changed(self):
        async with self.t.sessions() as session:
            group = Group(id=uuid.uuid4(), department_id=self.t.dep_a.id, name='Hidden')
            session.add_all([group, UserPreference(user_id=self.manager.id, settings={
                'admin_hidden_group_ids': [str(group.id)]})])
            await session.commit()
        self.assertEqual((await self.t.client.patch(f'/api/v1/groups/{group.id}', json={
            'department_id': str(self.t.dep_a.id), 'name': 'Wrong'})).status_code, 404)
        self.assertEqual((await self.t.client.delete(f'/api/v1/groups/{group.id}')).status_code, 404)

    async def test_group_manager_cannot_move_or_create_groups(self):
        async with self.t.sessions() as session:
            role = Role(id='group_editor', name='Group editor', scope_kind=ScopeKind.group,
                        permissions=['editEmployees', 'viewEmployees'])
            group = Group(id=uuid.uuid4(), department_id=self.t.dep_a.id, name='Own group')
            session.add_all([role, group])
            await session.commit()
        self.t.actor.role = role
        self.t.actor.role_id = role.id
        self.t.actor.group_id = group.id
        self.assertEqual((await self.t.client.patch(f'/api/v1/groups/{group.id}', json={
            'department_id': str(self.t.dep_a.id), 'name': 'Renamed'})).status_code, 200)
        self.assertEqual((await self.t.client.post('/api/v1/groups', json={
            'department_id': str(self.t.dep_a.id), 'name': 'Extra'})).status_code, 404)
        self.assertEqual((await self.t.client.patch(f'/api/v1/groups/{group.id}', json={
            'department_id': str(self.t.dep_b.id), 'name': 'Moved'})).status_code, 403)

    async def test_money_is_neither_disclosed_nor_overwritten(self):
        async with self.t.sessions() as session:
            result = await employees(user=self.manager, session=session)
            self.assertEqual(result[0].salary, 0)
            await session.commit()  # Redaction must not dirty persistent Employee rows.
        for body in [{'full_name': 'Renamed'}, {'salary': 0, 'bonus': 0}, {'salary': 123, 'bonus': 456}]:
            response = await self.t.client.patch(f'/api/v1/employees/{self.t.a.id}', json=body)
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual((response.json()['salary'], response.json()['bonus']), (0, 0))
        async with self.t.sessions() as session:
            item = await session.get(Employee, self.t.a.id)
            self.assertEqual((item.salary, item.bonus), (999999, 888888))
        response = await self.t.client.post('/api/v1/employees', json={
            'full_name': 'New', 'department_id': str(self.t.dep_a.id),
            'schedule_start_date': '2026-01-01', 'salary': 123, 'bonus': 456})
        self.assertEqual(response.status_code, 201)
        self.assertEqual((response.json()['salary'], response.json()['bonus']), (0, 0))
        await self.admin()
        response = await self.t.client.patch(f'/api/v1/employees/{self.t.a.id}', json={'salary': 123})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['salary'], 123)

    async def test_historical_editor_keeps_old_schedule_and_can_correct_former_employee(self):
        await self.t.mark('2026-08-03', minutes=360)
        await self.t.client.patch(f'/api/v1/employees/{self.t.a.id}', json={'shift_hours': 12})
        # Exercise a legacy backup's history, not the new permanent-delete endpoint.
        async with self.t.sessions() as session:
            employee = await session.get(Employee, self.t.a.id)
            employee.is_active = False
            await remember_employee(session, employee, date.today())
            await session.commit()
        result = await self.t.client.get('/api/v1/employees?on_date=2026-08-03')
        row = next(r for r in result.json() if r['id'] == str(self.t.a.id))
        self.assertEqual(row['shift_hours'], 9)
        self.assertEqual(row['salary'], 0)
        self.assertEqual((await self.t.mark('2026-08-03', minutes=420)).status_code, 200)
        body = {'planned_employee_ids': [str(self.t.a.id)]}
        self.assertEqual((await self.t.client.post('/api/v1/attendance/2026-08-03/close', json=body)).status_code, 204)
        self.assertEqual((await self.t.mark('2026-08-03', minutes=480)).status_code, 409)
        self.assertEqual((await self.t.client.post('/api/v1/attendance/2026-08-03/reopen',
                         json={'employee_ids': [str(self.t.a.id)]})).status_code, 204)
        self.assertEqual((await self.t.mark('2026-08-03', minutes=480)).status_code, 200)
        self.assertEqual((await self.t.mark(date.today().isoformat(), minutes=480)).status_code, 404)
        self.assertEqual((await self.t.report())['total_minutes'], 480)

    async def test_transfer_scope_applies_to_daily_reads_writes_bulk_and_locks(self):
        await self.t.mark('2026-08-03', minutes=360)
        async with self.t.sessions() as session:
            employee = await session.get(Employee, self.t.a.id)
            employee.department_id = self.t.dep_b.id
            await remember_employee(session, employee, date(2026, 8, 15))
            await session.commit()
        self.assertEqual((await self.t.mark('2026-08-03', minutes=420)).status_code, 200)
        self.assertEqual((await self.t.mark('2026-08-20', minutes=480)).status_code, 404)
        self.t.actor.department_id = self.t.dep_b.id
        self.assertEqual((await self.t.mark('2026-08-20', minutes=480)).status_code, 200)
        self.assertEqual((await self.t.mark('2026-08-03', minutes=480)).status_code, 404)
        self.assertEqual((await self.t.client.get('/api/v1/attendance/2026-08-03')).json(), [])
        data = (await self.t.client.get('/api/v1/attendance?date_from=2026-08-01&date_to=2026-08-31')).json()
        self.assertNotIn(str(self.t.a.id), data.get('2026-08-03', {}))
        self.assertIn(str(self.t.a.id), data['2026-08-20'])
        response = await self.t.client.put('/api/v1/attendance/2026-08-03', json={'records': [{
            'employee_id': str(self.t.a.id), 'fact': 'worked', 'worked_minutes': 480}]})
        self.assertEqual(response.status_code, 404)
        for action, key in [('close', 'planned_employee_ids'), ('reopen', 'employee_ids')]:
            response = await self.t.client.post(f'/api/v1/attendance/2026-08-03/{action}',
                                               json={key: [str(self.t.a.id)]})
            self.assertEqual(response.status_code, 404)

    async def test_null_required_employee_fields_are_validation_errors(self):
        for field in ['full_name', 'salary', 'bonus', 'shift_hours', 'is_active', 'schedule_start_date']:
            response = await self.t.client.patch(f'/api/v1/employees/{self.t.a.id}', json={field: None})
            self.assertEqual(response.status_code, 422, (field, response.text))
