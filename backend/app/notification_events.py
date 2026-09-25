"""New business events only. Never reconstruct notifications from old audit rows."""
import uuid

from .notifications import emit_to_employee, emit_to_reviewers


SCHEDULE_FIELDS = frozenset({
    "schedule_type", "schedule_start_date", "shift_hours", "break_hours", "custom_workdays",
})


def duration(minutes: int) -> str:
    hours, rest = divmod(max(0, minutes), 60)
    if not rest:
        return f"{hours} ч"
    return f"{hours} ч {rest} мин" if hours else f"{rest} мин"


async def hours_closed(session, employee_id, day, minutes, *, closed=True):
    # The caller holds the day lock and calls only for an actual transition.
    await emit_to_employee(session, employee_id, kind="hours_closed",
        title="День закрыт" if closed else "День переоткрыт",
        body=(f"За {day:%d.%m.%Y} учтено {duration(minutes)}. " +
              ("День закрыт." if closed else "Руководитель переоткрыл день; часы могут измениться.")),
        day=day, dedupe_key=f"day-transition:{uuid.uuid4()}")


async def schedule_changed(session, employee_id, effective_day):
    await emit_to_employee(session, employee_id, kind="schedule_changed",
        title="График изменён",
        body=f"Руководитель изменил ваш график с {effective_day:%d.%m.%Y}. Проверьте ближайшие смены.",
        day=effective_day, dedupe_key=f"schedule-change:{uuid.uuid4()}")


async def request_created(session, item, employee_name):
    await emit_to_reviewers(session, item.employee_id, kind="request_created",
        title="Новый запрос часов",
        body=f"{employee_name}: +{duration(item.additional_minutes)} за {item.day:%d.%m.%Y}. Требуется решение.",
        day=item.day, request_id=item.id, dedupe_key=f"request-created:{item.id}")


async def request_decided(session, item):
    approved = item.status == "approved"
    body = f"Запрос +{duration(item.additional_minutes)} за {item.day:%d.%m.%Y} "
    body += "одобрен." if approved else "отклонён."
    if approved and item.baseline.get("applied_minutes") is not None:
        body += f" Сейчас учтено {duration(item.baseline['applied_minutes'])}."
    if item.review_comment:
        body += f" Ответ руководителя: {item.review_comment}"
    await emit_to_employee(session, item.employee_id, kind="request_decision",
        title="Запрос часов одобрен" if approved else "Запрос часов отклонён",
        body=body, day=item.day, request_id=item.id,
        dedupe_key=f"request-decision:{item.id}")
