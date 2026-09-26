from datetime import date
from io import BytesIO
import os
from pathlib import Path
import sys
import unittest
import uuid
from xml.etree import ElementTree as ET
from zipfile import ZipFile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("JWT_SECRET", "test-only-secret-not-used-outside-tests-1234")
os.environ.setdefault("BOOTSTRAP_TOKEN", "test-only-bootstrap-not-used-outside-tests-1234")

import httpx
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.ext.compiler import compiles
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.main import app, current_user, get_session
from app.history import remember_employee
from app.models import (AttendanceLock, AttendanceRecord, Base, Department, Employee, EmployeeHistory,
                        FactStatus, Role, ScheduleType, ScopeKind, User)
from app.reports import day_label, month_report
from app.timesheet_xlsx import make_timesheet, NS


@compiles(JSONB, "sqlite")
def sqlite_jsonb(_type, _compiler, **_kwargs):
    return "JSON"


class TimesheetTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        async with self.sessions() as session:
            self.dep_a = Department(id=uuid.uuid4(), name="Отдел А")
            self.dep_b = Department(id=uuid.uuid4(), name="Отдел Б")
            role = Role(id="manager", name="Manager", scope_kind=ScopeKind.department,
                        permissions=["viewAttendance", "viewEmployees", "editAttendance", "editEmployees"])
            session.add_all([self.dep_a, self.dep_b, role])
            await session.flush()
            self.actor = User(id=uuid.uuid4(), login="manager", password_hash="unused", role=role,
                              department_id=self.dep_a.id)
            self.a = Employee(id=uuid.uuid4(), full_name="Сотрудник А", department_id=self.dep_a.id,
                              schedule_type=ScheduleType.fiveTwo, schedule_start_date=date(2026, 1, 1),
                              shift_hours=9, break_hours=1, salary=999999, bonus=888888)
            self.b = Employee(id=uuid.uuid4(), full_name="Сотрудник Б", department_id=self.dep_b.id,
                              schedule_type=ScheduleType.fiveTwo, schedule_start_date=date(2026, 1, 1),
                              shift_hours=9, break_hours=1)
            session.add_all([self.actor, self.a, self.b])
            await session.flush()
            await remember_employee(session, self.a, date(2026, 1, 1))
            await remember_employee(session, self.b, date(2026, 1, 1))
            await session.commit()

        async def session_dependency():
            async with self.sessions() as session:
                yield session

        async def actor_dependency():
            return self.actor

        app.dependency_overrides[get_session] = session_dependency
        app.dependency_overrides[current_user] = actor_dependency
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")

    async def asyncTearDown(self):
        app.dependency_overrides.clear()
        await self.client.aclose()
        await self.engine.dispose()

    async def mark(self, day, fact="worked", minutes=660, employee=None):
        return await self.client.put(f"/api/v1/attendance/{day}/{employee or self.a.id}",
                                     json={"fact": fact, "worked_minutes": minutes})

    async def report(self, month=8):
        response = await self.client.get(f"/api/v1/reports/month?year=2026&month={month}")
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    async def test_mixed_marks_and_unplanned_shifts_are_counted(self):
        for day, fact, minutes in [(1, "businessTrip", 660), (2, "vacationWorked", 660),
                                   (3, "unpaid", 0), (4, "businessTrip", 0), (31, "worked", 480)]:
            result = await self.mark(f"2026-08-{day:02d}", fact, minutes)
            self.assertEqual(result.status_code, 200, result.text)
        report = await self.report()
        self.assertEqual(report["total_minutes"], 1800)
        row = report["rows"][0]
        self.assertEqual([d["value"] for d in row["days"][:4]], ["11к", "о 11", "б/с", "К"])
        self.assertEqual(row["worked_days"], 3)
        self.assertFalse(row["days"][0]["planned"])
        self.assertNotIn("999999", str(report))
        self.assertNotIn("888888", str(report))

    async def test_closing_does_not_lock_another_department(self):
        response = await self.client.post("/api/v1/attendance/2026-08-03/close",
                            json={"planned_employee_ids": [str(self.a.id)]})
        self.assertEqual(response.status_code, 204, response.text)
        self.assertEqual((await self.mark("2026-08-03")).status_code, 409)
        self.actor.department_id = self.dep_b.id
        self.assertEqual((await self.mark("2026-08-03", employee=self.b.id)).status_code, 200)
        response = await self.client.post("/api/v1/attendance/2026-08-03/reopen",
                                         json={"employee_ids": [str(self.a.id)]})
        self.assertEqual(response.status_code, 404)
        self.actor.department_id = self.dep_a.id
        response = await self.client.post("/api/v1/attendance/2026-08-03/reopen",
                                         json={"employee_ids": [str(self.a.id)]})
        self.assertEqual(response.status_code, 204)
        self.assertEqual((await self.mark("2026-08-03")).status_code, 200)

    async def test_cannot_close_or_export_another_department(self):
        response = await self.client.post("/api/v1/attendance/2026-08-03/close",
                            json={"planned_employee_ids": [str(self.b.id)]})
        self.assertEqual(response.status_code, 404)
        response = await self.client.get(f"/api/v1/reports/month.xlsx?year=2026&month=8&department_id={self.dep_b.id}")
        self.assertEqual(response.status_code, 404)

    async def test_schedule_change_and_deactivation_keep_previous_report(self):
        self.assertEqual((await self.mark("2026-08-03", minutes=None)).status_code, 200)
        before = await self.report()
        response = await self.client.patch(f"/api/v1/employees/{self.a.id}", json={"shift_hours": 12})
        self.assertEqual(response.status_code, 200, response.text)
        # Legacy inactive records may still exist in restored backups. Public deletion is permanent.
        async with self.sessions() as session:
            employee = await session.get(Employee, self.a.id)
            employee.is_active = False
            await remember_employee(session, employee, date.today())
            await session.commit()
        after = await self.report()
        self.assertEqual(after["total_minutes"], 480)
        self.assertEqual(after["rows"][0]["planned_days"], before["rows"][0]["planned_days"])
        self.assertEqual(after["rows"][0]["days"], before["rows"][0]["days"])

    async def test_transfer_only_exposes_historically_authorized_days(self):
        async with self.sessions() as session:
            employee = await session.get(Employee, self.a.id)
            employee.department_id = self.dep_b.id
            await remember_employee(session, employee, date(2026, 8, 15))
            await session.commit()
        report = await self.report()
        row = report["rows"][0]
        self.assertIsNotNone(row["days"][13])
        self.assertTrue(all(day is None for day in row["days"][14:]))
        self.actor.department_id = self.dep_b.id
        row = next(row for row in (await self.report())["rows"] if row["employee_id"] == str(self.a.id))
        self.assertTrue(all(day is None for day in row["days"][:14]))

    async def test_invalid_status_hours_and_bulk_duplicates_are_rejected(self):
        self.assertEqual((await self.mark("2026-08-03", "sick", 660)).status_code, 422)
        self.assertEqual((await self.mark("2026-08-03", "vacationWorked", 0)).status_code, 422)
        item = {"employee_id": str(self.a.id), "fact": "worked", "worked_minutes": 480}
        response = await self.client.put("/api/v1/attendance/2026-08-03", json={"records": [item, item]})
        self.assertEqual(response.status_code, 422)

    async def test_vacation_range_marks_every_calendar_day_without_overwriting_facts(self):
        self.assertEqual((await self.mark("2026-09-22", "worked", 660)).status_code, 200)
        self.assertEqual((await self.mark("2026-09-23", "vacation", 0)).status_code, 200)
        closed = await self.client.post("/api/v1/attendance/2026-09-24/close",
                                        json={"planned_employee_ids": [str(self.a.id)]})
        self.assertEqual(closed.status_code, 204)
        response = await self.client.post("/api/v1/attendance/vacation-range", json={
            "employee_id": str(self.a.id), "date_from": "2026-09-21", "date_to": "2026-09-30",
            "comment": "Ежегодный отпуск",
        })
        self.assertEqual(response.status_code, 200, response.text)
        result = response.json()
        self.assertEqual(len(result["applied"]), 7)
        self.assertEqual(result["skipped_existing"], ["2026-09-22"])
        self.assertEqual(result["already_vacation"], ["2026-09-23"])
        self.assertEqual(result["skipped_closed"], ["2026-09-24"])
        attendance = (await self.client.get(
            "/api/v1/attendance?date_from=2026-09-21&date_to=2026-09-30")).json()
        for day in ["2026-09-21", "2026-09-26", "2026-09-27", "2026-09-30"]:
            self.assertEqual(attendance[day][str(self.a.id)]["fact"], "vacation")
        self.assertEqual(attendance["2026-09-22"][str(self.a.id)]["workedMinutes"], 660)
        self.assertEqual(attendance["2026-09-24"][str(self.a.id)]["fact"], "absent")

    async def test_vacation_range_rejects_other_department_and_invalid_length(self):
        body = {"employee_id": str(self.b.id), "date_from": "2026-09-21", "date_to": "2026-09-30"}
        response = await self.client.post("/api/v1/attendance/vacation-range", json=body)
        self.assertEqual(response.status_code, 404)
        body["employee_id"] = str(self.a.id)
        body["date_to"] = "2028-09-30"
        response = await self.client.post("/api/v1/attendance/vacation-range", json=body)
        self.assertEqual(response.status_code, 422)

    async def test_vacation_range_transfer_is_rejected_without_partial_write(self):
        async with self.sessions() as session:
            employee = await session.get(Employee, self.a.id)
            employee.department_id = self.dep_b.id
            await remember_employee(session, employee, date(2026, 9, 25))
            await session.commit()
        response = await self.client.post("/api/v1/attendance/vacation-range", json={
            "employee_id": str(self.a.id), "date_from": "2026-09-21", "date_to": "2026-09-30",
        })
        self.assertEqual(response.status_code, 404)
        async with self.sessions() as session:
            records = (await session.scalars(select(AttendanceRecord).where(
                AttendanceRecord.employee_id == self.a.id,
                AttendanceRecord.day.between(date(2026, 9, 21), date(2026, 9, 30)),
            ))).all()
            self.assertEqual(records, [])

    async def test_export_has_full_template_blank_finances_and_last_row_totals(self):
        self.assertEqual((await self.mark("2026-08-31", "businessTrip", 630)).status_code, 200)
        response = await self.client.get("/api/v1/reports/month.xlsx?year=2026&month=8")
        self.assertEqual(response.status_code, 200, response.text[:100] if response.status_code != 200 else "")
        with ZipFile(BytesIO(response.content)) as archive:
            root = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
            values = {c.get("r"): c for c in root.findall(f".//{{{NS}}}c")}
            self.assertEqual(values["AO2"].find(f"{{{NS}}}v").text, "10.5")
            self.assertEqual(values["AO3"].find(f"{{{NS}}}f").text, "SUM(AO2:AO2)")
            self.assertEqual(values["AN2"].find(f"{{{NS}}}is/{{{NS}}}t").text, "10,5к")
            for col in ["E", "F", "G", "H", "AP", "AQ", "AR", "AT", "AU", "AV", "AX", "AY", "AZ", "BA", "BD", "BE"]:
                self.assertEqual(len(values[f"{col}2"]), 0, col)
            workbook = ET.fromstring(archive.read("xl/workbook.xml"))
            self.assertEqual(workbook.find(f"{{{NS}}}sheets/{{{NS}}}sheet").get("name"), "08.2026")
            self.assertEqual(root.find(f"{{{NS}}}dimension").get("ref"), "A1:BE3")

    async def test_february_does_not_emit_nonexistent_dates(self):
        report = await self.report(month=2)
        self.assertEqual(len(report["rows"][0]["days"]), 28)
        with ZipFile(BytesIO(make_timesheet(report))) as archive:
            root = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
            cells = {c.get("r"): c for c in root.findall(f".//{{{NS}}}c")}
            self.assertEqual(len(cells["AL1"]), 0)
            self.assertEqual(len(cells["AN2"]), 0)

    async def test_blank_days_are_not_implicitly_absences(self):
        report = await self.report()
        self.assertIsNone(report["rows"][0]["days"][2]["value"])
        self.assertGreater(report["missing_days"], 0)
        self.assertEqual(report["total_minutes"], 0)

    async def test_read_permission_is_enforced_for_export(self):
        self.actor.role.permissions = []
        response = await self.client.get("/api/v1/reports/month.xlsx?year=2026&month=8")
        self.assertEqual(response.status_code, 403)

    async def test_legacy_lock_without_record_is_returned_to_the_ui(self):
        async with self.sessions() as session:
            session.add(AttendanceLock(day=date(2026, 8, 3), employee_id=self.a.id,
                                       closed_by_id=self.actor.id))
            await session.commit()
        response = await self.client.get("/api/v1/attendance?date_from=2026-08-03&date_to=2026-08-03")
        self.assertEqual(response.status_code, 200)
        record = response.json()["2026-08-03"][str(self.a.id)]
        self.assertTrue(record["closed"])
        self.assertEqual(record["fact"], "none")

    async def test_employee_names_and_comments_cannot_inject_formulas(self):
        response = await self.mark("2026-08-03", "vacationWorked", 481)
        self.assertEqual(response.status_code, 200)
        report = await self.report()
        report["rows"][0]["full_name"] = '=HYPERLINK("https://example.invalid","test")'
        report["rows"][0]["notes"] = ["=1+2", "Invalid control: \x01"]
        with ZipFile(BytesIO(make_timesheet(report))) as archive:
            root = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
            cells = {c.get("r"): c for c in root.findall(f".//{{{NS}}}c")}
            self.assertEqual(cells["C2"].get("t"), "inlineStr")
            self.assertIsNone(cells["C2"].find(f"{{{NS}}}f"))
            self.assertEqual(cells["BB2"].get("t"), "inlineStr")
            pane = root.find(f".//{{{NS}}}pane")
            self.assertEqual(pane.get("xSplit"), "4")
            self.assertEqual(pane.get("ySplit"), "1")

    async def test_total_includes_the_last_of_many_employees(self):
        await self.mark("2026-08-31", "worked", 480)
        report = await self.report()
        report["rows"] = [report["rows"][0] for _ in range(74)]
        report["total_minutes"] = 74 * 480
        with ZipFile(BytesIO(make_timesheet(report))) as archive:
            root = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
            cells = {c.get("r"): c for c in root.findall(f".//{{{NS}}}c")}
            self.assertEqual(cells["AO76"].find(f"{{{NS}}}f").text, "SUM(AO2:AO75)")
            self.assertEqual(float(cells["AO76"].find(f"{{{NS}}}v").text), 592)
            self.assertEqual(float(cells["AN76"].find(f"{{{NS}}}v").text), 74)


if __name__ == "__main__":
    unittest.main()
