"""Generate a synthetic report with the production XLSX exporter. No database access."""
import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.models import FactStatus
from app.reports import day_label
from app.timesheet_xlsx import make_timesheet


def demo_report():
    rows = []
    scenarios = [
        ("Пример: Сотрудник 1", [(1, "worked", 660), (2, "businessTrip", 660),
                                (3, "vacationWorked", 660), (4, "unpaid", 0), (31, "worked", 480)]),
        ("Пример: Сотрудник 2", [(1, "businessTrip", 0), (2, "sick", 0),
                                (3, "vacation", 0), (4, "absent", 0), (31, "worked", 480)]),
        ("Пример: Сотрудник 3", [(1, "businessTrip", 485), (2, "vacationWorked", 481),
                                (3, "worked", 503)]),
    ]
    for name, marks in scenarios:
        days = [{"date": f"2026-08-{i:02}", "value": None, "minutes": 0,
                 "fact": "none", "planned": False, "missing": False, "closed": False}
                for i in range(1, 32)]
        for day, fact, minutes in marks:
            days[day - 1].update(value=day_label(FactStatus(fact), minutes), minutes=minutes,
                                 fact=fact, planned=True, closed=True)
        rows.append({"full_name": name, "department": "Демонстрационный отдел",
                     "position": "Демонстрационная должность", "days": days,
                     "total_minutes": sum(m for _, _, m in marks),
                     "missing_days": 0, "open_days": 0,
                     "notes": ["Вымышленные данные для проверки выгрузки"]})
    return {"year": 2026, "month": 8, "days_in_month": 31, "rows": rows,
            "total_minutes": sum(r["total_minutes"] for r in rows)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(make_timesheet(demo_report()))
    print(f"Saved synthetic report: {args.output}")
    print("Expected hours: 41, 8, 24.4833333333333; total 73.4833333333333")
