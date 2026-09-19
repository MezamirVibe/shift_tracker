"""Small, versioned upgrade for existing PostgreSQL installations.

Each version is transactional and serialized with a PostgreSQL advisory lock.
Enum additions commit before application code starts using the new values.
"""
from sqlalchemy import select, text

from .database import SessionFactory, engine
from .history import ensure_employee_history
from .models import Base, Employee


async def migrate() -> None:
    async with engine.begin() as connection:
        await connection.execute(text("SELECT pg_advisory_xact_lock(193701, 1)"))
        await connection.run_sync(Base.metadata.create_all)
        await connection.execute(text("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())"))
        for sql in (
            "ALTER TYPE schedule_type ADD VALUE IF NOT EXISTS 'custom'",
            "ALTER TABLE employees ADD COLUMN IF NOT EXISTS custom_workdays JSONB NOT NULL DEFAULT '[1,2,3,4,5]'::jsonb",
            "ALTER TABLE attendance_records ADD COLUMN IF NOT EXISTS actual_start TIME NULL",
            "ALTER TABLE attendance_records ADD COLUMN IF NOT EXISTS actual_end TIME NULL",
            "ALTER TYPE fact_status ADD VALUE IF NOT EXISTS 'businessTrip'",
            "ALTER TYPE fact_status ADD VALUE IF NOT EXISTS 'vacationWorked'",
            "ALTER TYPE fact_status ADD VALUE IF NOT EXISTS 'unpaid'",
        ):
            await connection.execute(text(sql))

    async with SessionFactory() as session:
        await session.execute(text("SELECT pg_advisory_xact_lock(193701, 1)"))
        applied = await session.scalar(text("SELECT version FROM schema_migrations WHERE version = '20260918_timesheets'"))
        if not applied:
            employees = (await session.scalars(select(Employee))).all()
            for employee in employees:
                await ensure_employee_history(session, employee)
            # Freeze legacy implicit hours before any schedule can be changed.
            await session.execute(text("""
                UPDATE attendance_records AS a
                SET worked_minutes = GREATEST(0, e.shift_hours - e.break_hours) * 60
                FROM employees e
                WHERE a.employee_id = e.id AND a.fact = 'worked' AND a.worked_minutes IS NULL
            """))
            # Preserve old closed days. Future closes only affect specified employees.
            await session.execute(text("""
                INSERT INTO attendance_locks (day, employee_id, closed_by_id, closed_at)
                SELECT d.day, e.id, d.closed_by_id, COALESCE(d.closed_at, NOW())
                FROM attendance_days d CROSS JOIN employees e WHERE d.is_closed
                ON CONFLICT (day, employee_id) DO NOTHING
            """))
            await session.execute(text("UPDATE attendance_days SET is_closed = FALSE WHERE is_closed"))
            await session.execute(text("INSERT INTO schema_migrations (version) VALUES ('20260918_timesheets')"))
        await session.commit()
