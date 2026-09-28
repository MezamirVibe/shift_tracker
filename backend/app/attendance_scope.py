"""Attendance permissions follow the employee's assignment on the selected day."""
import uuid
from collections import defaultdict
from datetime import date

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .history import snapshot_on
from .models import AttendanceLock, AttendanceRecord, EmployeeHistory, User
from .reports import visible_snapshot


class AttendanceScope:
    def __init__(self, user: User, hidden_groups: set[str], revisions: list[EmployeeHistory]):
        self.user = user
        self.hidden_groups = hidden_groups
        self.histories = defaultdict(list)
        for revision in revisions:
            self.histories[revision.employee_id].append(revision)

    @classmethod
    async def load(cls, session: AsyncSession, user: User, last: date, hidden_groups: set[str]):
        revisions = list((await session.scalars(select(EmployeeHistory).where(
            EmployeeHistory.effective_from <= last).order_by(
                EmployeeHistory.employee_id, EmployeeHistory.effective_from))).all())
        return cls(user, hidden_groups, revisions)

    def snapshot(self, employee_id: uuid.UUID, day: date) -> dict | None:
        snapshot = snapshot_on(self.histories.get(employee_id, []), day)
        if snapshot and visible_snapshot(self.user, employee_id, snapshot,
                                        self.hidden_groups, None, None):
            return snapshot
        return None

    @property
    def candidates(self) -> set[uuid.UUID]:
        return {employee_id for employee_id, history in self.histories.items() if any(
            visible_snapshot(self.user, employee_id, revision.snapshot,
                             self.hidden_groups, None, None) for revision in history)}

    async def day_employees(self, session: AsyncSession, day: date) -> dict[uuid.UUID, dict]:
        recorded = set((await session.scalars(select(AttendanceRecord.employee_id).where(
            AttendanceRecord.day == day, AttendanceRecord.employee_id.in_(self.candidates)))).all())
        recorded.update((await session.scalars(select(AttendanceLock.employee_id).where(
            AttendanceLock.day == day, AttendanceLock.employee_id.in_(self.candidates)))).all())
        result = {}
        for employee_id in self.candidates:
            snapshot = self.snapshot(employee_id, day)
            if snapshot and (employee_id in recorded or (
                snapshot.get("is_active", True) and
                day >= date.fromisoformat(snapshot["schedule_start_date"])
            )):
                result[employee_id] = snapshot
        return result
