import unittest
import uuid
from datetime import date
from sqlalchemy import select
import test_timesheets as fixtures
from app.history import remember_employee
from app.models import Department, Employee, Group, Role, ScopeKind, User
from scripts.retain_department import retain


class RetainDepartmentTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.t = fixtures.TimesheetTests('test_mixed_marks_and_unplanned_shifts_are_counted')
        await self.t.asyncSetUp()
        self.group_id = uuid.uuid4()
        self.worker_id = uuid.uuid4()
        async with self.t.sessions() as session:
            admin = await session.get(User, self.t.actor.id)
            role = Role(id='super_admin', name='Admin', scope_kind=ScopeKind.all, permissions=[])
            worker = Role(id='worker', name='Worker', scope_kind=ScopeKind.self, permissions=[])
            session.add_all([role, worker, Group(id=self.group_id, name='ОТК', department_id=self.t.dep_a.id)])
            await session.flush()
            admin.role_id = role.id
            employee = await session.get(Employee, self.t.a.id)
            employee.group_id = self.group_id
            await remember_employee(session, employee, date(2026, 1, 1))
            session.add(User(id=self.worker_id, login='worker', password_hash='unused', role_id='worker', employee_id=self.t.b.id))
            await session.commit()
        self.args = dict(group_id=self.group_id, keep_ids={self.t.a.id}, expected_active=2,
                         department_name='ОТК', effective_date=date(2026, 9, 19))

    async def asyncTearDown(self):
        await self.t.asyncTearDown()

    async def test_preview_and_apply_preserve_reports_and_administrator(self):
        await self.t.mark('2026-08-03', minutes=660)
        async with self.t.sessions() as session:
            plan = await retain(session, **self.args)
            self.assertEqual(plan['archived'], 1)
            self.assertFalse(plan['applied'])
            self.assertTrue((await session.get(Employee, self.t.b.id)).is_active)
            result = await retain(session, **self.args, apply=True, expected_fingerprint=plan['fingerprint'])
            await session.commit()
            self.assertTrue(result['attendance_unchanged'])
            self.assertEqual(result['previous_reports_unchanged'], 1)
            self.assertEqual((await session.scalars(select(Department.name))).all(), ['ОТК'])
            self.assertEqual((await session.scalars(select(Group))).all(), [])
            self.assertTrue((await session.get(User, self.t.actor.id)).is_active)
            self.assertFalse((await session.get(User, self.worker_id)).is_active)
            self.assertFalse((await session.get(Employee, self.t.b.id)).is_active)

    async def test_stale_preview_and_wrong_membership_are_rejected(self):
        async with self.t.sessions() as session:
            with self.assertRaisesRegex(ValueError, 'changed since preview'):
                await retain(session, **self.args, apply=True, expected_fingerprint='wrong')
            with self.assertRaisesRegex(ValueError, 'approved roster'):
                await retain(session, **{**self.args, 'keep_ids': {self.t.b.id}})
            self.assertTrue((await session.get(Employee, self.t.b.id)).is_active)
