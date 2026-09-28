"""Focused tests for explicit permanent deletion and editable structure."""
from datetime import date
import uuid
import unittest
from sqlalchemy import select, text, func
import test_timesheets as fixtures
from app.models import (Employee, EmployeeHistory, AttendanceRecord, AttendanceLock,
                        Group, Department, User, Role, ScopeKind)
from app.history import remember_employee


class RemovalTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.t = fixtures.TimesheetTests('test_mixed_marks_and_unplanned_shifts_are_counted')
        await self.t.asyncSetUp()
        async with self.t.sessions() as session:
            await session.execute(text('PRAGMA foreign_keys=ON'))
            role = Role(id='super_admin', name='Admin', scope_kind=ScopeKind.all, permissions=[])
            self.t.actor = User(id=uuid.uuid4(), login='owner', password_hash='unused', role=role)
            self.group = Group(id=uuid.uuid4(), name='Group', department_id=self.t.dep_a.id)
            session.add_all([role, self.t.actor, self.group])
            await session.flush()
            a = await session.get(Employee, self.t.a.id)
            a.group_id = self.group.id
            await remember_employee(session, a, date(2026, 1, 1))
            await session.commit()

    async def asyncTearDown(self):
        await self.t.asyncTearDown()

    async def test_employee_removes_only_confirmed_card_and_its_hours(self):
        await self.t.mark('2026-08-03')
        path = f'/api/v1/employees/{self.t.a.id}'
        self.assertEqual((await self.t.client.delete(path)).status_code, 409)
        self.assertEqual((await self.t.client.delete(path + '?permanent=true')).status_code, 204)
        async with self.t.sessions() as s:
            self.assertIsNone(await s.get(Employee, self.t.a.id))
            self.assertIsNotNone(await s.get(Employee, self.t.b.id))
            for model in (EmployeeHistory, AttendanceRecord, AttendanceLock):
                self.assertEqual(await s.scalar(select(func.count()).select_from(model).where(model.employee_id == self.t.a.id)), 0)

    async def test_linked_login_needs_consent_and_is_revoked(self):
        async with self.t.sessions() as s:
            role = Role(id='worker', name='Worker', scope_kind=ScopeKind.self, permissions=[])
            account = User(id=uuid.uuid4(), login='staff', password_hash='unused', role=role, employee_id=self.t.a.id)
            s.add_all([role, account]); await s.commit()
        path = f'/api/v1/employees/{self.t.a.id}?permanent=true'
        self.assertEqual((await self.t.client.delete(path)).status_code, 409)
        self.assertEqual((await self.t.client.delete(path + '&disable_linked_account=true')).status_code, 204)
        async with self.t.sessions() as s:
            account = await s.get(User, account.id)
            self.assertFalse(account.is_active)
            self.assertIsNone(account.employee_id)
            self.assertEqual(account.token_version, 1)

    async def test_cannot_disable_owner_through_employee_delete(self):
        async with self.t.sessions() as s:
            owner = await s.get(User, self.t.actor.id)
            owner.employee_id = self.t.a.id
            await s.commit()
        result = await self.t.client.delete(f'/api/v1/employees/{self.t.a.id}?permanent=true&disable_linked_account=true')
        self.assertEqual(result.status_code, 409)

    async def test_remove_group_detaches_staff_preserves_history(self):
        path = f'/api/v1/groups/{self.group.id}'
        self.assertEqual((await self.t.client.delete(path)).status_code, 409)
        self.assertEqual((await self.t.client.delete(path + '?detach_members=true')).status_code, 204)
        async with self.t.sessions() as s:
            a = await s.get(Employee, self.t.a.id)
            self.assertIsNone(a.group_id)
            self.assertEqual(a.department_id, self.t.dep_a.id)
            old = await s.get(EmployeeHistory, (a.id, date(2026, 1, 1)))
            self.assertEqual(old.snapshot['group_id'], str(self.group.id))

    async def test_department_and_groups_removed_without_deleting_people(self):
        # Fixture manager has a department-bound login: disabling it is explicit in test setup.
        async with self.t.sessions() as s:
            for account in (await s.scalars(select(User).where(User.department_id == self.t.dep_a.id))).all():
                account.is_active = False
            await s.commit()
        result = await self.t.client.delete(f'/api/v1/departments/{self.t.dep_a.id}?detach_members=true')
        self.assertEqual(result.status_code, 204, result.text)
        async with self.t.sessions() as s:
            self.assertIsNone(await s.get(Department, self.t.dep_a.id))
            self.assertIsNone(await s.get(Group, self.group.id))
            a = await s.get(Employee, self.t.a.id)
            self.assertTrue(a.is_active)
            self.assertIsNone(a.department_id)

    async def test_active_structure_account_blocks_with_actionable_message(self):
        result = await self.t.client.delete(f'/api/v1/departments/{self.t.dep_a.id}?detach_members=true')
        self.assertEqual(result.status_code, 409)
        self.assertIn('Пользователи', result.json()['detail'])


if __name__ == '__main__':
    unittest.main()
