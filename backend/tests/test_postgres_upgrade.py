"""Opt-in real PostgreSQL checks, isolated in a uniquely named temporary schema.

Run with TEST_POSTGRES_URL=postgresql+asyncpg://... pointing at a LOCAL test server.
Never uses DATABASE_URL to choose the test target.
"""
import asyncio
from datetime import date
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("JWT_SECRET", "test-only-secret-not-used-outside-tests-1234")
os.environ.setdefault("BOOTSTRAP_TOKEN", "test-only-bootstrap-not-used-outside-tests-1234")

import httpx
from sqlalchemy import select, text
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from app import migrations
from app import main as api
from app.main import app, current_user, get_session
from app.models import (Base, Role, ScopeKind, User, Employee, Department,
                        AttendanceDay, AttendanceRecord, FactStatus, ScheduleType, RefreshToken)
from app.security import new_refresh_token

TEST_URL = os.environ.get("TEST_POSTGRES_URL")


@unittest.skipUnless(TEST_URL, "Set TEST_POSTGRES_URL for a local disposable PostgreSQL server")
class PostgreSQLUpgradeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        url = make_url(TEST_URL)
        if url.host not in {"localhost", "127.0.0.1", "::1"}:
            raise RuntimeError("These destructive fixture tests require a local test server")
        self.schema = "test_timesheet_" + uuid.uuid4().hex
        self.control = create_async_engine(url)
        async with self.control.begin() as connection:
            await connection.execute(text(f'CREATE SCHEMA "{self.schema}"'))
        self.engine = create_async_engine(url, connect_args={
            "server_settings": {"search_path": self.schema}})
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        self.engine_patch = patch.object(migrations, "engine", self.engine)
        self.session_patch = patch.object(migrations, "SessionFactory", self.sessions)
        self.engine_patch.start()
        self.session_patch.start()

    async def asyncTearDown(self):
        app.dependency_overrides.clear()
        self.session_patch.stop()
        self.engine_patch.stop()
        await self.engine.dispose()
        # Only drop the schema created by this exact test; never public or a supplied name.
        assert self.schema.startswith("test_timesheet_") and len(self.schema) == 47
        async with self.control.begin() as connection:
            await connection.execute(text(f'DROP SCHEMA "{self.schema}" CASCADE'))
        await self.control.dispose()

    async def test_fresh_install_and_concurrent_startup(self):
        await asyncio.gather(migrations.migrate(), migrations.migrate())
        async with self.sessions() as session:
            versions = (await session.execute(text("SELECT version FROM schema_migrations"))).scalars().all()
            self.assertEqual(versions, ["20260918_timesheets"])

    async def test_concurrent_import_does_not_duplicate_employees(self):
        import base64
        from test_imports import fixture_file
        await self.auth_fixture()
        async with self.sessions() as session:
            dep = Department(id=uuid.uuid4(), name='Import department')
            session.add(dep)
            await session.commit()
        body = {'file_base64': base64.b64encode(fixture_file()).decode(), 'year':2026, 'month':8,
                'department_id': str(dep.id)}
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            preview = await client.post('/api/v1/imports/timesheet/preview', json=body)
            self.assertEqual(preview.status_code, 200, preview.text)
            payload = {**body, 'preview_token':preview.json()['preview_token'], 'selected_rows':[2]}
            responses = await asyncio.gather(*[client.post('/api/v1/imports/timesheet/commit', json=payload) for _ in range(2)])
            self.assertEqual(sorted(r.status_code for r in responses), [200,409], [r.text for r in responses])
        async with self.sessions() as session:
            self.assertEqual(await session.scalar(text('SELECT count(*) FROM employees')), 1)

    async def test_two_delivery_workers_send_one_document(self):
        from datetime import datetime, timezone
        from app.history import remember_employee
        from app.models import ReportDelivery
        from app.telegram_delivery import DeliverySettings, run_due_once
        from test_delivery import FakeTelegram
        await self.auth_fixture()
        now = datetime.now(timezone.utc)
        async with self.sessions() as session:
            admin = await session.scalar(select(User).where(User.login == 'admin'))
            employee = Employee(full_name='Delivery employee', schedule_start_date=date(2026,1,1))
            session.add(employee)
            await session.flush()
            await remember_employee(session, employee, date(2026,1,1))
            cfg = DeliverySettings(enabled=True, cadence='daily', period='current', include_unfinished=True)
            session.add(ReportDelivery(user_id=admin.id, chat_id='123', enabled=True,
                                      next_run_at=now, settings=cfg.model_dump(mode='json')))
            await session.commit()
        telegram = FakeTelegram()
        await asyncio.gather(*[run_due_once(api, self.sessions, telegram, now) for _ in range(2)])
        self.assertEqual(len(telegram.sent), 1)
        async with self.sessions() as session:
            self.assertEqual(await session.scalar(text('SELECT count(*) FROM delivery_attempts')), 1)

    async def test_wrong_organization_is_rejected_before_schema_changes(self):
        async with self.engine.begin() as connection:
            await connection.execute(text('CREATE TABLE organization_identity (id INTEGER PRIMARY KEY, code TEXT NOT NULL)'))
            await connection.execute(text("INSERT INTO organization_identity VALUES (1, 'another-company')"))
        with self.assertRaisesRegex(RuntimeError, 'migration refused'):
            await migrations.migrate()
        async with self.engine.connect() as connection:
            self.assertIsNone(await connection.scalar(text("SELECT to_regclass('employees')")))
            self.assertIsNone(await connection.scalar(text("SELECT to_regclass('schema_migrations')")))

    async def test_concurrent_bootstrap_creates_only_one_administrator(self):
        await migrations.migrate()
        async with self.sessions() as session:
            await api.seed_roles(session)
        async def test_session():
            async with self.sessions() as session:
                yield session
        app.dependency_overrides[get_session] = test_session
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            responses = await asyncio.gather(*[
                client.post('/api/v1/auth/bootstrap', headers={'X-Bootstrap-Token': api.settings.BOOTSTRAP_TOKEN},
                    json={'login': f'admin-{n}', 'password': 'only-for-tests-12345'}) for n in range(3)])
            self.assertEqual(sorted(r.status_code for r in responses), [200, 409, 409])
        async with self.sessions() as session:
            self.assertEqual(await session.scalar(text('SELECT count(*) FROM users')), 1)

    async def auth_fixture(self):
        await migrations.migrate()
        async with self.sessions() as session:
            role = Role(id='super_admin', name='Admin', scope_kind=ScopeKind.all, permissions=[])
            admin = User(id=uuid.uuid4(), login='admin', password_hash='unused', role=role)
            target = User(id=uuid.uuid4(), login='target', password_hash='unused', role=role)
            session.add_all([role, admin, target])
            await session.flush()
            token_id, raw, digest, expires = new_refresh_token()
            session.add(RefreshToken(id=token_id, user_id=target.id, token_hash=digest, expires_at=expires))
            await session.commit()
        async def test_session():
            async with self.sessions() as session:
                yield session
        async def test_actor():
            return admin
        app.dependency_overrides[get_session] = test_session
        app.dependency_overrides[current_user] = test_actor
        return target, raw

    async def test_concurrent_refresh_token_is_consumed_only_once(self):
        _, raw = await self.auth_fixture()
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            responses = await asyncio.gather(*[
                client.post('/api/v1/auth/refresh', json={'refresh_token': raw}) for _ in range(5)])
            self.assertEqual(sorted(r.status_code for r in responses), [200, 401, 401, 401, 401])

    async def test_password_reset_revokes_token_rotating_at_same_time(self):
        target, raw = await self.auth_fixture()
        rotating = asyncio.Event()
        release = asyncio.Event()
        original_issue = api.issue_tokens

        async def delayed_issue(session, user):
            rotating.set()
            await asyncio.wait_for(release.wait(), timeout=10)
            return await original_issue(session, user)

        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            with patch.object(api, 'issue_tokens', delayed_issue):
                refresh_task = asyncio.create_task(client.post('/api/v1/auth/refresh', json={'refresh_token': raw}))
                await asyncio.wait_for(rotating.wait(), timeout=10)
                reset_task = asyncio.create_task(client.post(f'/api/v1/users/{target.id}/reset-password'))
                try:
                    await asyncio.sleep(0.1)
                    self.assertFalse(reset_task.done(), 'Reset must wait for the user lock')
                finally:
                    release.set()
                refreshed, reset = await asyncio.gather(refresh_task, reset_task)
            self.assertEqual(refreshed.status_code, 200, refreshed.text)
            self.assertEqual(reset.status_code, 200, reset.text)
            response = await client.post('/api/v1/auth/refresh', json={
                'refresh_token': refreshed.json()['refresh_token']})
            self.assertEqual(response.status_code, 401)

    async def test_legacy_upgrade_preserves_hours_locks_and_handles_concurrent_closes(self):
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with self.sessions() as session:
            dep = Department(id=uuid.uuid4(), name="Test department")
            role = Role(id="manager", name="Manager", scope_kind=ScopeKind.department,
                        permissions=["viewAttendance", "viewEmployees", "editAttendance"])
            session.add_all([dep, role])
            await session.flush()
            actor = User(id=uuid.uuid4(), login="test-manager", password_hash="unused", role=role,
                         department_id=dep.id)
            employees = [Employee(id=uuid.uuid4(), full_name=f"Test {n}", department_id=dep.id,
                                  schedule_type=ScheduleType.fiveTwo, schedule_start_date=date(2026, 1, 1),
                                  shift_hours=9, break_hours=1) for n in range(2)]
            session.add_all([actor, *employees])
            await session.flush()
            session.add(AttendanceDay(day=date(2026, 8, 3), is_closed=True, closed_by_id=actor.id))
            await session.flush()
            session.add_all([AttendanceRecord(day=date(2026, 8, 3), employee_id=e.id,
                                              fact=FactStatus.worked, worked_minutes=None if i == 0 else 123)
                             for i, e in enumerate(employees)])
            await session.commit()
        # Recreate the legacy shape, entirely inside this test's own schema.
        async with self.engine.begin() as connection:
            for sql in [
                "DROP TABLE employee_history", "DROP TABLE attendance_locks",
                "ALTER TABLE employees DROP COLUMN custom_workdays",
                "ALTER TABLE attendance_records DROP COLUMN actual_start",
                "ALTER TABLE attendance_records DROP COLUMN actual_end",
                "ALTER TYPE fact_status RENAME TO new_fact_status",
                "CREATE TYPE fact_status AS ENUM ('none','worked','absent','sick','vacation')",
                "ALTER TABLE attendance_records ALTER COLUMN fact TYPE fact_status USING fact::text::fact_status",
                "DROP TYPE new_fact_status",
            ]:
                await connection.execute(text(sql))
        await self.engine.dispose()  # Drop cached type OIDs before testing the upgrade.
        await migrations.migrate()
        await migrations.migrate()
        async with self.sessions() as session:
            records = (await session.scalars(select(AttendanceRecord))).all()
            self.assertEqual(sorted(r.worked_minutes for r in records), [123, 480])
            self.assertEqual(await session.scalar(text("SELECT COUNT(*) FROM employee_history")), 2)
            self.assertEqual(await session.scalar(text("SELECT COUNT(*) FROM attendance_locks")), 2)
            self.assertFalse(await session.scalar(text("SELECT is_closed FROM attendance_days")))

        async def test_session():
            async with self.sessions() as session:
                yield session
        async def test_actor():
            return actor
        app.dependency_overrides[get_session] = test_session
        app.dependency_overrides[current_user] = test_actor
        ids = [str(e.id) for e in employees]
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            response = await client.put(f"/api/v1/attendance/2026-08-03/{ids[0]}",
                                        json={"fact": "businessTrip", "worked_minutes": 660})
            self.assertEqual(response.status_code, 409, response.text)
            # Simultaneous closes of the same employees must be idempotent, not produce duplicate locks.
            responses = await asyncio.gather(*[
                client.post("/api/v1/attendance/2026-08-04/close",
                            json={"planned_employee_ids": ids}) for _ in range(3)])
            self.assertTrue(all(r.status_code == 204 for r in responses), [r.text for r in responses])
            response = await client.put(f"/api/v1/attendance/2026-08-05/{ids[0]}",
                                        json={"fact": "businessTrip", "worked_minutes": 660})
            self.assertEqual(response.status_code, 200, response.text)
            response = await client.get("/api/v1/reports/month?year=2026&month=8")
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json()["total_minutes"], 1263)
