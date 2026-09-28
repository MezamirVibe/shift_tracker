import argparse
import asyncio
import json
from datetime import date
from pathlib import Path

from sqlalchemy import func, select

from app.database import SessionFactory, engine
from app.models import Department, Employee, Group, Position, ScheduleType


async def import_employees(source: Path) -> None:
    payload = json.loads(source.read_text(encoding="utf-8"))
    created = 0
    updated = 0

    async with SessionFactory() as session:
        department = await session.scalar(
            select(Department).where(Department.name == payload["department"])
        )
        if department is None:
            department = Department(name=payload["department"])
            session.add(department)
            await session.flush()

        groups: dict[str, Group] = {}
        for code, name in payload["groups"].items():
            group = await session.scalar(
                select(Group).where(
                    Group.department_id == department.id,
                    Group.name == name,
                )
            )
            if group is None:
                group = Group(department_id=department.id, name=name)
                session.add(group)
                await session.flush()
            groups[code] = group

        positions: dict[str, Position] = {
            item.name.casefold(): item
            for item in (await session.scalars(select(Position))).all()
        }

        for row in payload["employees"]:
            name = row["full_name"].strip()
            position_name = row["position"].strip()
            group = groups[row["group_code"]]

            position = positions.get(position_name.casefold())
            if position is None:
                position = Position(name=position_name)
                session.add(position)
                await session.flush()
                positions[position_name.casefold()] = position

            employee = await session.scalar(
                select(Employee).where(func.lower(Employee.full_name) == name.lower())
            )
            if employee is None:
                employee = Employee(
                    full_name=name,
                    position_id=position.id,
                    department_id=department.id,
                    group_id=group.id,
                    salary=0,
                    bonus=0,
                    schedule_type=ScheduleType.fiveTwo,
                    schedule_start_date=date(2026, 8, 1),
                    shift_hours=8,
                    break_hours=1,
                    custom_workdays=[1, 2, 3, 4, 5],
                    is_active=True,
                )
                session.add(employee)
                created += 1
            else:
                employee.position_id = position.id
                employee.department_id = department.id
                employee.group_id = group.id
                employee.is_active = True
                updated += 1

        await session.commit()

    await engine.dispose()
    print(
        json.dumps(
            {
                "source": payload["source"],
                "created": created,
                "updated": updated,
                "total": len(payload["employees"]),
                "groups": len(groups),
            },
            ensure_ascii=False,
        )
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    asyncio.run(import_employees(args.source))


if __name__ == "__main__":
    main()
