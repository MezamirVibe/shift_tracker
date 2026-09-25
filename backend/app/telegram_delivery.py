"""Opt-in report delivery. Tokens stay on the server; Telegram is never an auth provider."""
import asyncio
from datetime import datetime, timedelta, timezone
import hashlib
import logging
import re
import secrets
from typing import Literal
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import httpx
from fastapi import Depends, HTTPException
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.concurrency import run_in_threadpool

from .models import BotCursor, DeliveryAttempt, ReportDelivery, User, ScopeKind, utcnow
from .timesheet_xlsx import make_timesheet

log = logging.getLogger(__name__)


class DeliverySettings(BaseModel):
    enabled: bool = False
    cadence: Literal['daily', 'weekly', 'monthly'] = 'monthly'
    weekday: int = Field(default=1, ge=1, le=7)
    month_day: int = Field(default=1, ge=1, le=28)
    hour: int = Field(default=9, ge=0, le=23)
    minute: int = Field(default=0, ge=0, le=59)
    timezone: str = Field(default='Asia/Yekaterinburg', max_length=80)
    period: Literal['current', 'previous'] = 'previous'
    department_id: uuid.UUID | None = None
    group_id: uuid.UUID | None = None
    include_unfinished: bool = False

    @field_validator('timezone')
    @classmethod
    def valid_timezone(cls, value):
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError) as error:
            raise ValueError('Укажите часовой пояс IANA, например Asia/Yekaterinburg') from error
        return value


class ConfirmRecipient(BaseModel):
    chat_id: str = Field(min_length=1, max_length=32)


def aware(value: datetime) -> datetime:
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value


def next_run(config: DeliverySettings, after: datetime) -> datetime:
    after = aware(after)
    zone = ZoneInfo(config.timezone)
    start = after.astimezone(zone).date()
    for offset in range(370):
        day = start + timedelta(days=offset)
        if config.cadence == 'weekly' and day.isoweekday() != config.weekday:
            continue
        if config.cadence == 'monthly' and day.day != config.month_day:
            continue
        local = datetime(day.year, day.month, day.day, config.hour, config.minute, tzinfo=zone)
        candidate = local.astimezone(timezone.utc)
        # Skip nonexistent DST wall times, and run once only in repeated hours.
        if candidate > after and candidate.astimezone(zone).replace(tzinfo=None) == local.replace(tzinfo=None):
            return candidate
    raise ValueError('Не найдено следующее время отправки')


def report_period(config: DeliverySettings, due: datetime) -> tuple[int, int]:
    day = aware(due).astimezone(ZoneInfo(config.timezone)).date().replace(day=1)
    if config.period == 'previous':
        day -= timedelta(days=1)
    return day.year, day.month


class TelegramTransport:
    def __init__(self, token: str):
        self._token = token

    async def call(self, method: str, data: dict, files=None):
        # No URL, request or exception text containing the token may enter logs.
        try:
            async with httpx.AsyncClient(timeout=30, follow_redirects=False) as client:
                response = await client.post(f'https://api.telegram.org/bot{self._token}/{method}',
                                             data=data, files=files)
                result = response.json()
                if response.status_code != 200 or not result.get('ok'):
                    raise RuntimeError('Telegram отклонил запрос. Проверьте доступ бота к чату.')
                return result['result']
        except (httpx.HTTPError, ValueError) as error:
            raise RuntimeError('Нет подтверждения от Telegram. Автоповтор отключён, чтобы не отправить файл дважды.') from None

    async def document(self, chat_id: str, filename: str, content: bytes, caption: str):
        return await self.call('sendDocument', {'chat_id': chat_id, 'caption': caption},
            files={'document': (filename, content, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')})


def can_deliver(api, user):
    return (user.is_active and (api.is_super_admin(user) or user.role.scope_kind != ScopeKind.self)
            and api.has_permission(user, 'viewAttendance') and api.has_permission(user, 'viewEmployees'))


async def poll_updates(session, api, transport):
    if session.bind.dialect.name == 'postgresql':
        if not await session.scalar(text('SELECT pg_try_advisory_xact_lock(193701, 4)')):
            return
    cursor = await session.get(BotCursor, 1)
    if cursor is None:
        cursor = BotCursor(id=1, next_update_id=0)
        session.add(cursor)
    updates = await transport.call('getUpdates', {'offset': str(cursor.next_update_id),
        'timeout': '0', 'limit': '50', 'allowed_updates': '["message"]'})
    for update in updates:
        cursor.next_update_id = max(cursor.next_update_id, int(update['update_id']) + 1)
        message = update.get('message') or {}
        match = re.fullmatch(r'/(?:start|connect)(?:@[A-Za-z0-9_]+)?\s+([A-Za-z0-9_-]{32,64})', message.get('text', ''))
        chat = message.get('chat') or {}
        sender = message.get('from') or {}
        command = re.fullmatch(r'/(time|pause|status)(?:@[A-Za-z0-9_]+)?(?:\s+(\d{2}):(\d{2}))?', message.get('text', ''))
        if command and not sender.get('is_bot'):
            deliveries = list((await session.scalars(select(ReportDelivery).where(
                ReportDelivery.chat_id == str(chat.get('id')),
                ReportDelivery.telegram_actor_id == str(sender.get('id'))).with_for_update())).all())
            # Ambiguous shared recipient: change schedules only from the app.
            if len(deliveries) == 1:
                delivery = deliveries[0]
                user = await api.load_user(session, delivery.user_id)
                if user and can_deliver(api, user):
                    config = DeliverySettings.model_validate(delivery.settings)
                    if command[1] == 'time' and command[2] and int(command[2]) < 24 and int(command[3]) < 60:
                        config.hour, config.minute = int(command[2]), int(command[3])
                        delivery.settings = config.model_dump(mode='json')
                        delivery.next_run_at = next_run(config, utcnow()) if delivery.enabled else None
                        reply = f'Время: {config.hour:02d}:{config.minute:02d}, {config.timezone}. ' + ('Расписание активно.' if delivery.enabled else 'Автоотправка выключена; включить её можно в Череде.')
                    elif command[1] == 'pause':
                        delivery.enabled = False
                        delivery.next_run_at = None
                        reply = 'Автоотправка остановлена. Включить её снова можно в Череде.'
                    elif command[1] == 'status':
                        reply = f'Расписание: {"включено" if delivery.enabled else "выключено"}. Время {config.hour:02d}:{config.minute:02d}, {config.timezone}.'
                    else:
                        reply = 'Для изменения времени: /time 09:30. Часовой пояс и период выбираются в Череде.'
                    await transport.call('sendMessage', {'chat_id': str(chat['id']), 'text': reply})
                    await api.audit(session, actor=user, action='bot_' + command[1], entity_type='report_delivery')
            continue
        if not match or sender.get('is_bot') or chat.get('type') not in {'private', 'group', 'supergroup'}:
            continue
        pair_hash = hashlib.sha256(match[1].encode()).hexdigest()
        delivery = await session.scalar(select(ReportDelivery).where(ReportDelivery.pair_hash == pair_hash).with_for_update())
        if delivery is None or not delivery.pair_expires or aware(delivery.pair_expires) < utcnow():
            continue
        user = await api.load_user(session, delivery.user_id)
        if user is None or not can_deliver(api, user):
            continue
        if chat['type'] != 'private':
            member = await transport.call('getChatMember', {'chat_id': str(chat['id']), 'user_id': str(sender['id'])})
            if member.get('status') not in {'creator', 'administrator'}:
                continue
        delivery.candidate_chat_id = str(chat['id'])
        delivery.candidate_actor_id = str(sender['id'])
        delivery.candidate_title = str(chat.get('title') or ' '.join(filter(None, [chat.get('first_name'), chat.get('last_name')])) or chat['id'])[:240]
        delivery.pair_hash = None  # Single use; even a second legitimate click cannot change the recipient.
        await transport.call('sendMessage', {'chat_id': str(chat['id']),
            'text': 'Чат найден. Вернитесь в Череду и подтвердите получателя. До подтверждения табели не отправляются.'})
    await session.commit()


async def run_due_once(api, sessions, transport, now: datetime | None = None):
    now = aware(now or utcnow())
    async with sessions() as session:
        delivery = await session.scalar(select(ReportDelivery).where(ReportDelivery.enabled.is_(True),
            ReportDelivery.next_run_at <= now).order_by(ReportDelivery.next_run_at).with_for_update(skip_locked=True).limit(1))
        if delivery is None:
            return False
        user_id, due = delivery.user_id, aware(delivery.next_run_at)
        config = DeliverySettings.model_validate(delivery.settings)
        identity = (delivery.chat_id, delivery.settings)
        attempt = DeliveryAttempt(user_id=user_id, due_at=due,
            status='Отправка начата. Если результат не обновится, проверьте чат перед повторной отправкой.')
        session.add(attempt)
        delivery.next_run_at = next_run(config, now)
        delivery.last_run_at = now
        delivery.last_status = attempt.status
        # Persist the claim BEFORE sending. Crashes/timeouts never cause automatic duplicate sends.
        await session.commit()
        attempt_id = attempt.id
    async with sessions() as session:
        delivery = await session.scalar(select(ReportDelivery).where(ReportDelivery.user_id == user_id).with_for_update())
        attempt = await session.get(DeliveryAttempt, attempt_id)
        status = 'Отправка отменена: настройки изменились'
        if delivery and delivery.enabled and (delivery.chat_id, delivery.settings) == identity:
            try:
                user = await api.load_user(session, user_id)
                if user is None or not can_deliver(api, user):
                    delivery.enabled = False
                    raise ValueError('Отправка отключена: у владельца больше нет доступа к табелям')
                if not delivery.chat_id:
                    raise ValueError('Получатель не подтверждён')
                if now - due > timedelta(hours=2):
                    raise ValueError('Пропущено после простоя сервера более двух часов; старые табели автоматически не рассылаются')
                year, month = report_period(config, due)
                report = await api.get_month_report(year, month, config.department_id, config.group_id, user, session)
                if not report['rows']:
                    raise ValueError('Не отправлено: в выбранном периоде нет доступных сотрудников')
                if not config.include_unfinished and (report['missing_days'] or report['open_days']):
                    raise ValueError('Не отправлено: табель не заполнен или дни не закрыты')
                content = await run_in_threadpool(make_timesheet, report)
                result = await transport.document(delivery.chat_id, f'Tabel_{year}_{month:02d}.xlsx', content,
                    f'{api.settings.ORGANIZATION_NAME}\nТабель {month:02d}.{year}' +
                    ('\nНезавершённый табель: проверьте отметки.' if report['missing_days'] or report['open_days'] else ''))
                status = f'Отправлено: {month:02d}.{year}. Сообщение {result["message_id"]}'
            except (ValueError, RuntimeError) as error:
                status = str(error)[:500]
            except HTTPException:
                status = 'Не отправлено: проверьте доступ к выбранному отделу и группе'
            delivery.last_status = status
        attempt.status = status
        if not status.startswith('Отправлено:'):
            from .notifications import emit_notification
            await emit_notification(session, user_id=user_id, kind='delivery_failed',
                title='Табель не отправлен', body=status,
                dedupe_key=f'delivery-failed:{attempt_id}')
        await session.commit()
    return True


async def worker(api):
    transport = TelegramTransport(api.settings.TELEGRAM_BOT_TOKEN)
    while True:
        try:
            async with api.SessionFactory() as session:
                await poll_updates(session, api, transport)
            for _ in range(10):
                if not await run_due_once(api, api.SessionFactory, transport):
                    break
        except asyncio.CancelledError:
            raise
        except Exception as error:
            log.warning('Telegram worker error (%s); no payload or token logged', type(error).__name__)
        await asyncio.sleep(10)


def register_delivery_routes(app):
    from . import main as api

    async def authorized(user: User = Depends(api.current_user)):
        if not can_deliver(api, user):
            raise HTTPException(403, 'Недостаточно прав для отправки табелей')
        return user

    def configured():
        return bool(api.settings.TELEGRAM_BOT_TOKEN and api.settings.TELEGRAM_BOT_USERNAME)

    async def get_delivery(session, user):
        # Serialize create/pair/save/disconnect with the scheduler's recipient row.
        await session.scalar(select(User).where(User.id == user.id).with_for_update())
        delivery = await session.scalar(select(ReportDelivery).where(ReportDelivery.user_id == user.id).with_for_update())
        if delivery is None:
            delivery = ReportDelivery(user_id=user.id, settings=DeliverySettings().model_dump(mode='json'))
            session.add(delivery)
            await session.flush()
        return delivery

    @app.get('/api/v1/reports/delivery')
    async def status(user: User = Depends(authorized), session: AsyncSession = Depends(api.get_session)):
        delivery = await session.get(ReportDelivery, user.id)
        candidate_valid = delivery and delivery.pair_expires and aware(delivery.pair_expires) >= utcnow()
        return {'configured': configured(), 'bot_username': api.settings.TELEGRAM_BOT_USERNAME if configured() else None,
            'chat_id': delivery.chat_id if delivery else None, 'chat_title': delivery.chat_title if delivery else None,
            'candidate_chat_id': delivery.candidate_chat_id if candidate_valid else None,
            'candidate_title': delivery.candidate_title if candidate_valid else None,
            'settings': delivery.settings if delivery else DeliverySettings().model_dump(mode='json'),
            'enabled': delivery.enabled if delivery else False,
            'next_run_at': delivery.next_run_at if delivery and delivery.enabled else None,
            'last_status': delivery.last_status if delivery else None,
            'last_run_at': delivery.last_run_at if delivery else None}

    @app.post('/api/v1/reports/delivery/pair')
    async def pair(user: User = Depends(authorized), session: AsyncSession = Depends(api.get_session)):
        if not configured():
            raise HTTPException(409, 'Бот пока не подключён на сервере организации')
        delivery = await get_delivery(session, user)
        code = secrets.token_urlsafe(24)
        delivery.pair_hash = hashlib.sha256(code.encode()).hexdigest()
        delivery.pair_expires = utcnow() + timedelta(minutes=10)
        delivery.candidate_chat_id = delivery.candidate_title = delivery.candidate_actor_id = None
        await session.commit()
        return {'private_link': f'https://t.me/{api.settings.TELEGRAM_BOT_USERNAME}?start={code}',
                'group_link': f'https://t.me/{api.settings.TELEGRAM_BOT_USERNAME}?startgroup={code}',
                'command': f'/connect@{api.settings.TELEGRAM_BOT_USERNAME} {code}', 'expires_in_seconds': 600}

    @app.post('/api/v1/reports/delivery/confirm')
    async def confirm(body: ConfirmRecipient, user: User = Depends(authorized), session: AsyncSession = Depends(api.get_session)):
        delivery = await get_delivery(session, user)
        if (not delivery.candidate_chat_id or delivery.candidate_chat_id != body.chat_id
                or not delivery.pair_expires or aware(delivery.pair_expires) < utcnow()):
            raise HTTPException(409, 'Подключение истекло или чат изменился. Подключите заново')
        delivery.chat_id, delivery.chat_title = delivery.candidate_chat_id, delivery.candidate_title
        delivery.telegram_actor_id = delivery.candidate_actor_id
        delivery.candidate_chat_id = delivery.candidate_title = delivery.candidate_actor_id = delivery.pair_hash = None
        delivery.pair_expires = None
        delivery.enabled = False  # A new recipient NEVER silently inherits an active schedule.
        delivery.next_run_at = None
        await api.audit(session, actor=user, action='confirm_recipient', entity_type='report_delivery')
        await session.commit()
        return {'ok': True}

    @app.put('/api/v1/reports/delivery')
    async def save(body: DeliverySettings, user: User = Depends(authorized), session: AsyncSession = Depends(api.get_session)):
        delivery = await get_delivery(session, user)
        if body.enabled and (not configured() or not delivery.chat_id):
            raise HTTPException(409, 'Сначала подключите бота и подтвердите получателя')
        if body.department_id and not (user.role.scope_kind == ScopeKind.group and body.group_id):
            api.require_department_scope(user, body.department_id)
        if body.group_id:
            from .models import Group
            group = await session.get(Group, body.group_id)
            if group is None or (body.department_id and group.department_id != body.department_id):
                raise HTTPException(404, 'Группа не найдена')
            await api.require_group_scope(session, user, group)
        delivery.settings = body.model_dump(mode='json')
        delivery.enabled = body.enabled
        delivery.next_run_at = next_run(body, utcnow()) if body.enabled else None
        await api.audit(session, actor=user, action='schedule_report' if body.enabled else 'pause_report', entity_type='report_delivery')
        await session.commit()
        return {'ok': True, 'next_run_at': delivery.next_run_at}

    @app.delete('/api/v1/reports/delivery')
    async def disconnect(user: User = Depends(authorized), session: AsyncSession = Depends(api.get_session)):
        delivery = await get_delivery(session, user)
        delivery.enabled = False
        delivery.next_run_at = delivery.pair_expires = None
        delivery.chat_id = delivery.chat_title = delivery.pair_hash = delivery.telegram_actor_id = None
        delivery.candidate_chat_id = delivery.candidate_title = delivery.candidate_actor_id = None
        await api.audit(session, actor=user, action='disconnect_recipient', entity_type='report_delivery')
        await session.commit()
        return {'ok': True}
