"""Read-only personal calendar, including custom calendar-only employee roles."""
import unittest
import uuid

import test_timesheets as fixture
from app.models import Role, ScopeKind, User


class PersonalScheduleTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.t = fixture.TimesheetTests("test_mixed_marks_and_unplanned_shifts_are_counted")
        await self.t.asyncSetUp()
        await self.t.mark("2026-08-03", minutes=123)
        self.t.actor.department_id = self.t.dep_b.id
        await self.t.mark("2026-08-03", minutes=456, employee=self.t.b.id)
        self.t.actor = User(
            id=uuid.uuid4(), login="personal", password_hash="unused",
            employee_id=self.t.a.id,
            role=Role(id="specialist", name="Specialist", scope_kind=ScopeKind.self,
                      permissions=["viewCalendar"]),
        )

    async def asyncTearDown(self):
        await self.t.asyncTearDown()

    async def get_schedule(self, query="date_from=2026-08-01&date_to=2026-08-31"):
        return await self.t.client.get(f"/api/v1/self/schedule?{query}")

    async def test_calendar_only_reads_own_plan_without_facts_or_money(self):
        response = await self.get_schedule()
        self.assertEqual(response.status_code, 200, response.text)
        data = response.json()
        self.assertEqual(data["employee"]["id"], str(self.t.a.id))
        self.assertEqual(data["employee"]["schedule_start_date"], "2026-01-01")
        self.assertNotIn("salary", data["employee"])
        self.assertNotIn("bonus", data["employee"])
        self.assertEqual(data["attendance"], {})
        self.assertFalse(data["can_view_attendance"])
        for path in ("employees", "attendance?date_from=2026-08-01&date_to=2026-08-31"):
            response = await self.t.client.get(f"/api/v1/{path}")
            self.assertEqual(response.status_code, 403)

    async def test_attendance_permission_reads_only_own_saved_hours(self):
        self.t.actor.role.permissions = ["viewCalendar", "viewAttendance"]
        response = await self.get_schedule()
        self.assertEqual(response.status_code, 200, response.text)
        data = response.json()
        day = data["attendance"]["2026-08-03"]
        self.assertTrue(data["can_view_attendance"])
        self.assertEqual(day[str(self.t.a.id)]["workedMinutes"], 123)
        self.assertNotIn(str(self.t.b.id), str(data))

    async def test_unbound_account_has_actionable_error_and_cannot_read_another_person(self):
        self.t.actor.employee_id = None
        response = await self.get_schedule()
        self.assertEqual(response.status_code, 409)
        self.assertIn("привяз", response.text)

    async def test_permission_scope_and_range_are_enforced(self):
        self.assertEqual((await self.get_schedule(
            "date_from=2026-08-31&date_to=2026-08-01")).status_code, 422)
        self.t.actor.role.permissions = []
        self.assertEqual((await self.get_schedule()).status_code, 403)
        self.t.actor.role.permissions = ["viewCalendar"]
        self.t.actor.role.scope_kind = ScopeKind.department
        self.assertEqual((await self.get_schedule()).status_code, 403)
