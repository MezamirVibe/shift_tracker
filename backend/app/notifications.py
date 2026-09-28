"""Tenant-local inbox and opt-in, transactionally queued, private Android pushes.

FCM never receives names, hours, comments or organization identifiers. A push is
only a hint to refresh the authenticated inbox, not an authorization capability.
"""
import asyncio
from datetime import date, datetime, timedelta, timezone
from functools import lru_cache
import hashlib
import json
import logging
from pathlib import Path
from typing import Literal
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import Depends, HTTPException, Query
import httpx
from pydantic import BaseModel, ConfigDict, Field, StrictBool, field_validator
from sqlalchemy import delete, or_, select, text, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.ext.asyncio import AsyncSession

from .models import (Employee, Notification, NotificationDevice, NotificationPreference,
                     NotificationPushJob, ScopeKind, User, utcnow)
from .pagination import after_cursor, encode_cursor

log = logging.getLogger(__name__)
Kind = Literal["hours_closed", "request_decision", "schedule_changed", "shift_reminder",
               "request_created", "unfilled_days", "delivery_failed"]
KINDS = ("hours_closed", "request_decision", "schedule_changed", "shift_reminder",
         "request_created", "unfilled_days", "delivery_failed")
PERSONAL_KINDS = {"hours_closed", "request_decision", "schedule_changed", "shift_reminder"}
REVIEW_KINDS = {"request_created", "unfilled_days"}


class PreferencePatch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    push_enabled: StrictBool = False
    kinds: dict[Kind, StrictBool] = Field(default_factory=dict)
    quiet_hours_enabled: StrictBool = True
    quiet_start: str = Field(default="22:00", pattern=r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
    quiet_end: str = Field(default="08:00", pattern=r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
    timezone: str = Field(default="Asia/Yekaterinburg", min_length=1, max_length=100)

    @field_validator("timezone")
    @classmethod
    def valid_timezone(cls, value):
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError):
            raise ValueError("Выберите существующий часовой пояс IANA") from None
        return value


class DeviceIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    installation_id: uuid.UUID
    binding_id: uuid.UUID
    token: str = Field(min_length=20, max_length=4096, pattern=r"^[A-Za-z0-9_:.-]+$")
    platform: Literal["android"]


def normalized_preferences(row_or_dict=None) -> dict:
    source = row_or_dict.settings if isinstance(row_or_dict, NotificationPreference) else row_or_dict
    defaults = PreferencePatch().model_dump()
    defaults["kinds"] = {kind: kind not in {"shift_reminder", "unfilled_days"} for kind in KINDS}
    if source:
        values = PreferencePatch.model_validate(source).model_dump(exclude_unset=True)
        defaults.update({key: value for key, value in values.items() if key != "kinds"})
        defaults["kinds"].update(values.get("kinds", {}))
    return defaults


async def get_preferences(session, user_id) -> dict:
    return normalized_preferences(await session.get(NotificationPreference, user_id))


def aware(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value


def quiet_until(preferences, now):
    """Find the next allowed real instant, including DST gaps/overlaps."""
    if not preferences["quiet_hours_enabled"]:
        return None
    start, end = preferences["quiet_start"], preferences["quiet_end"]
    zone = ZoneInfo(preferences["timezone"])

    def quiet(instant):
        local = instant.astimezone(zone).strftime("%H:%M")
        return start <= local < end if start < end else local >= start or local < end

    now = aware(now)
    if not quiet(now):
        return None
    candidate = now.replace(second=0, microsecond=0) + timedelta(minutes=1)
    # A 26-hour bound covers ordinary DST transitions without busy looping.
    for _ in range(26 * 60):
        if not quiet(candidate):
            return candidate
        candidate += timedelta(minutes=1)
    return now + timedelta(days=1)


async def scope_key(api, session, user) -> str:
    # Conservative snapshot for summaries with no single employee. A changed
    # organization scope never exposes cached details from the previous scope.
    permissions = [api.has_permission(user, permission) for permission in
                   ("viewCalendar", "viewAttendance", "viewEmployees", "editAttendance")]
    value = [user.role.id, user.role.scope_kind.value, str(user.department_id), str(user.group_id),
             str(user.employee_id), permissions,
             sorted(map(str, await api.admin_hidden_group_ids(session, user.id)))]
    return hashlib.sha256(json.dumps(value, separators=(",", ":")).encode()).hexdigest()


def permitted_kind(api, user, kind):
    if not user.is_active:
        return False
    if kind in PERSONAL_KINDS:
        return user.employee_id is not None and api.has_permission(user, "viewCalendar")
    if kind == "unfilled_days":
        return user.role.scope_kind != ScopeKind.self and all(api.has_permission(user, permission)
            for permission in ("editAttendance", "viewAttendance", "viewEmployees"))
    if kind == "request_created":
        return user.role.scope_kind != ScopeKind.self and api.has_permission(user, "editAttendance")
    return kind == "delivery_failed" and user.role.scope_kind != ScopeKind.self and api.has_permission(user, "viewAttendance")


class Visibility:
    """Reuse scope and history once per inbox read, not once per notification."""
    @classmethod
    async def load(cls, api, session, user):
        value = cls()
        value.api, value.user = api, user
        value.key = await scope_key(api, session, user)
        value.employee_ids = set((await session.scalars(await api.scoped_employees(
            session, select(Employee.id).where(Employee.is_active.is_(True)), user))).all())
        value.history = await api.attendance_scope(session, user, date.max)
        return value

    def allows(self, event):
        if event.user_id != self.user.id or not permitted_kind(self.api, self.user, event.kind):
            return False
        if event.employee_id is None:
            return event.kind not in PERSONAL_KINDS and event.scope_key == self.key
        if event.employee_id not in self.employee_ids:
            return False
        if event.kind in PERSONAL_KINDS and event.employee_id != self.user.employee_id:
            return False
        return event.day is None or self.history.snapshot(event.employee_id, event.day) is not None


async def emit_notification(session, *, user_id, kind, title, body, dedupe_key,
                            day=None, employee_id=None, request_id=None, expires_at=None):
    """Add an inbox event and device jobs inside the caller's transaction; never commit."""
    from . import main as api
    if kind not in KINDS or not 1 <= len(dedupe_key) <= 240:
        raise ValueError("Invalid notification event")
    await session.flush()
    user = await api.load_user(session, user_id)
    if user is None or not permitted_kind(api, user, kind):
        return None
    visibility = await Visibility.load(api, session, user)
    now = utcnow()
    event = Notification(id=uuid.uuid4(), user_id=user.id, kind=kind, title=title[:160], body=body[:1500],
        day=day, employee_id=employee_id, request_id=request_id, scope_key=visibility.key,
        dedupe_key=dedupe_key, created_at=now)
    if not visibility.allows(event):
        return None
    insert = sqlite_insert if session.bind.dialect.name == "sqlite" else pg_insert
    inserted = await session.scalar(insert(Notification).values(
        id=event.id, user_id=event.user_id, kind=kind, title=event.title, body=event.body, day=day,
        employee_id=employee_id, request_id=request_id, scope_key=event.scope_key,
        dedupe_key=dedupe_key, created_at=now).on_conflict_do_nothing(
            index_elements=[Notification.user_id, Notification.dedupe_key]).returning(Notification.id))
    if inserted is None:
        return await session.scalar(select(Notification).where(
            Notification.user_id == user.id, Notification.dedupe_key == dedupe_key))
    saved = await session.get(Notification, inserted)
    preferences = await get_preferences(session, user.id)
    if preferences["push_enabled"] and preferences["kinds"][kind]:
        devices = (await session.scalars(select(NotificationDevice).where(
            NotificationDevice.user_id == user.id, NotificationDevice.active.is_(True),
            NotificationDevice.token_version == user.token_version))).all()
        expiry = min(aware(expires_at), now + timedelta(days=1)) if expires_at else now + timedelta(days=1)
        for device in devices:
            session.add(NotificationPushJob(notification_id=inserted, device_id=device.id,
                binding_id=device.binding_id, available_at=now, expires_at=expiry))
    return saved


async def emit_to_employee(session, employee_id, **event):
    user_id = await session.scalar(select(User.id).where(User.employee_id == employee_id, User.is_active.is_(True)))
    if user_id:
        return await emit_notification(session, user_id=user_id, employee_id=employee_id, **event)
    return None


async def emit_to_reviewers(session, employee_id, **event):
    from . import main as api
    users = (await session.scalars(api.user_query().where(User.is_active.is_(True)))).all()
    for user in users:
        if user.employee_id != employee_id and permitted_kind(api, user, "request_created"):
            await emit_notification(session, user_id=user.id, employee_id=employee_id, **event)


def output(event):
    return {"id": str(event.id), "kind": event.kind, "title": event.title, "body": event.body,
            "day": event.day.isoformat() if event.day else None,
            "request_id": str(event.request_id) if event.request_id else None,
            "created_at": aware(event.created_at).isoformat(),
            "read_at": aware(event.read_at).isoformat() if event.read_at else None}


async def visible_rows(session, query, visibility, cursor=None):
    scan = cursor
    while True:
        rows = list((await session.scalars(after_cursor(query, Notification, scan)
            .order_by(Notification.created_at.desc(), Notification.id.desc()).limit(100))).all())
        for event in rows:
            if visibility.allows(event):
                yield event
        if len(rows) < 100:
            return
        scan = encode_cursor(rows[-1])


async def registration_lock(session, keys):
    if session.bind.dialect.name == "postgresql":
        # Fixed order prevents token/install collision races across worker processes.
        for key in sorted({int.from_bytes(hashlib.sha256(value.encode()).digest()[:8], "big", signed=True) for value in keys}):
            await session.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": key})


def register_notification_routes(app):
    from . import main as api

    @app.get("/api/v1/notifications/preferences")
    async def preferences(user: User = Depends(api.current_user), session: AsyncSession = Depends(api.get_session)):
        return {**await get_preferences(session, user.id), "push_available": push_available(api.settings)}

    @app.put("/api/v1/notifications/preferences")
    async def save_preferences(body: PreferencePatch, user: User = Depends(api.current_user),
                               session: AsyncSession = Depends(api.get_session)):
        await registration_lock(session, [f"preferences:{user.id}"])
        row = await session.get(NotificationPreference, user.id)
        previous = normalized_preferences(row)
        supplied = body.model_dump(exclude_unset=True)
        merged = {**previous, **supplied, "kinds": {**previous["kinds"], **supplied.get("kinds", {})}}
        if merged["quiet_start"] == merged["quiet_end"]:
            raise HTTPException(422, "Начало и конец тихих часов должны различаться")
        if row is None:
            row = NotificationPreference(user_id=user.id)
            session.add(row)
        row.settings = merged
        disabled = [kind for kind in KINDS if not merged["push_enabled"] or not merged["kinds"][kind]]
        # Turning a type back on cannot resurrect old pending messages.
        if disabled:
            await session.execute(update(NotificationPushJob).where(NotificationPushJob.status == "pending",
                NotificationPushJob.notification_id.in_(select(Notification.id).where(
                    Notification.user_id == user.id, Notification.kind.in_(disabled))))
                .values(status="suppressed", last_error="preferences_disabled"))
        await session.commit()
        return {**merged, "push_available": push_available(api.settings)}

    @app.get("/api/v1/notifications")
    async def inbox(page_size: int = Query(default=30, ge=1, le=100),
                    cursor: str | None = Query(default=None, max_length=300),
                    user: User = Depends(api.current_user), session: AsyncSession = Depends(api.get_session)):
        visibility = await Visibility.load(api, session, user)
        query = select(Notification).where(Notification.user_id == user.id)
        items = []
        async for event in visible_rows(session, query, visibility, cursor):
            items.append(event)
            if len(items) > page_size:
                break
        unread_count = 0
        async for _ in visible_rows(session, query.where(Notification.read_at.is_(None)), visibility):
            unread_count += 1
        return {"items": [output(event) for event in items[:page_size]], "unread_count": unread_count,
                "next_cursor": encode_cursor(items[page_size - 1]) if len(items) > page_size else None}

    # Register fixed routes before the UUID path.
    @app.post("/api/v1/notifications/read-all")
    async def read_all(user: User = Depends(api.current_user), session: AsyncSession = Depends(api.get_session)):
        visibility = await Visibility.load(api, session, user)
        count = 0
        async for event in visible_rows(session, select(Notification).where(
                Notification.user_id == user.id, Notification.read_at.is_(None)), visibility):
            event.read_at = utcnow()
            count += 1
        await session.commit()
        return {"updated": count}

    @app.put("/api/v1/notifications/devices")
    async def register_device(body: DeviceIn, user: User = Depends(api.current_user),
                              session: AsyncSession = Depends(api.get_session)):
        digest = hashlib.sha256(body.token.encode()).hexdigest()
        await registration_lock(session, [f"device:{body.installation_id}", f"token:{digest}"])
        matches = list((await session.scalars(select(NotificationDevice).where(or_(
            NotificationDevice.installation_id == body.installation_id, NotificationDevice.token_hash == digest))
            .with_for_update())).all())
        # Reuse exactly the same authenticated binding; refresh is idempotent.
        if len(matches) == 1 and (matches[0].installation_id, matches[0].binding_id, matches[0].user_id,
                matches[0].token_hash, matches[0].token_version) == (
                body.installation_id, body.binding_id, user.id, digest, user.token_version):
            matches[0].active = True
            matches[0].updated_at = utcnow()
        else:
            for device in matches:
                # Explicit dependent delete is also correct for SQLite test fixtures.
                await session.execute(delete(NotificationPushJob).where(NotificationPushJob.device_id == device.id))
                await session.delete(device)
            await session.flush()
            session.add(NotificationDevice(installation_id=body.installation_id, binding_id=body.binding_id,
                user_id=user.id, token=body.token, token_hash=digest, token_version=user.token_version,
                platform=body.platform))
        await session.commit()
        return {"registered": True}

    @app.delete("/api/v1/notifications/devices/{installation_id}", status_code=204)
    async def unregister_device(installation_id: uuid.UUID, user: User = Depends(api.current_user),
                                session: AsyncSession = Depends(api.get_session)):
        await registration_lock(session, [f"device:{installation_id}"])
        row = await session.scalar(select(NotificationDevice).where(
            NotificationDevice.installation_id == installation_id, NotificationDevice.user_id == user.id).with_for_update())
        if row is not None:
            row.active = False
            await session.execute(update(NotificationPushJob).where(NotificationPushJob.device_id == row.id,
                NotificationPushJob.status == "pending").values(status="suppressed", last_error="unregistered"))
        await session.commit()

    @app.post("/api/v1/notifications/{notification_id}/read")
    async def read_one(notification_id: uuid.UUID, user: User = Depends(api.current_user),
                       session: AsyncSession = Depends(api.get_session)):
        event = await session.get(Notification, notification_id)
        if event is None or not (await Visibility.load(api, session, user)).allows(event):
            raise HTTPException(404, "Уведомление не найдено")
        if event.read_at is None:
            event.read_at = utcnow()
            await session.commit()
        return output(event)


@lru_cache(maxsize=8)
def _credentials(path, project):
    if not path or not project or not Path(path).is_file():
        return None
    try:
        from google.oauth2 import service_account
        credentials = service_account.Credentials.from_service_account_file(path,
            scopes=["https://www.googleapis.com/auth/firebase.messaging"])
        if credentials.project_id != project:
            return None
        return credentials
    except Exception:
        # No filename, token, account address or credential content in logs.
        log.warning("FCM credentials unavailable; push disabled")
        return None


def push_available(settings):
    return _credentials(settings.GOOGLE_APPLICATION_CREDENTIALS, settings.FCM_PROJECT_ID) is not None


def push_message(notification, device, now, expires_at):
    ttl = max(0, min(86400, int((aware(expires_at) - aware(now)).total_seconds())))
    return {"message": {"token": device.token,
        "data": {"notification_id": str(notification.id), "binding_id": str(device.binding_id), "kind": notification.kind},
        "android": {"priority": "HIGH", "ttl": f"{ttl}s"}}}


class FcmTransport:
    def __init__(self, settings):
        self.project = settings.FCM_PROJECT_ID
        self.credentials = _credentials(settings.GOOGLE_APPLICATION_CREDENTIALS, self.project)

    async def send(self, payload):
        if self.credentials is None:
            return "unavailable"
        try:
            if not self.credentials.valid:
                from google.auth.transport.requests import Request

                def refresh():
                    request = Request()
                    self.credentials.refresh(lambda *args, **kwargs: request(*args, **{**kwargs, "timeout": 10}))

                await asyncio.to_thread(refresh)
            async with httpx.AsyncClient(timeout=12, follow_redirects=False) as client:
                response = await client.post(f"https://fcm.googleapis.com/v1/projects/{self.project}/messages:send",
                    headers={"Authorization": f"Bearer {self.credentials.token}"}, json=payload)
            if response.is_success:
                return "sent"
            try:
                details = response.json().get("error", {}).get("details", [])
                if any(item.get("@type") == "type.googleapis.com/google.firebase.fcm.v1.FcmError"
                       and item.get("errorCode") == "UNREGISTERED" for item in details if isinstance(item, dict)):
                    return "unregistered"
            except (ValueError, AttributeError, TypeError):
                pass
            if response.status_code == 401:
                self.credentials.token = None
            return "retry" if response.status_code in {401, 403, 408, 429} or response.status_code >= 500 else "rejected"
        except Exception:
            # Library exceptions may contain device tokens or key details. Never log them.
            return "retry"


async def dispatch_pending(api, session, now, transport=None):
    """One locked device job per transaction; competing API workers skip it.

    FCM has no exactly-once delivery. A crash after send can cause a retry; the
    Android receiver uses a stable notification ID to replace that notification.
    """
    now = aware(now)
    await session.execute(update(NotificationPushJob).where(NotificationPushJob.status == "pending",
        NotificationPushJob.expires_at <= now).values(status="expired", last_error="expired"))
    if transport is None and not push_available(api.settings):
        await session.commit()
        return False
    job = await session.scalar(select(NotificationPushJob).where(NotificationPushJob.status == "pending",
        NotificationPushJob.available_at <= now, NotificationPushJob.expires_at > now)
        .order_by(NotificationPushJob.available_at).limit(1).with_for_update(skip_locked=True))
    if job is None:
        await session.commit()
        return False
    event = await session.get(Notification, job.notification_id)
    device = await session.get(NotificationDevice, job.device_id)
    user = await api.load_user(session, event.user_id) if event else None
    valid = (event is not None and event.read_at is None and device is not None and device.active and user is not None
             and user.is_active and device.user_id == user.id and device.binding_id == job.binding_id
             and device.token_version == user.token_version)
    if valid:
        valid = (await Visibility.load(api, session, user)).allows(event)
    preferences = await get_preferences(session, user.id) if valid else None
    if not valid or not preferences["push_enabled"] or not preferences["kinds"][event.kind]:
        job.status, job.last_error = "suppressed", "no_longer_allowed"
    elif (resume := quiet_until(preferences, now)) is not None:
        job.available_at = resume
    else:
        job.attempts += 1
        result = await (transport or FcmTransport(api.settings)).send(push_message(event, device, now, job.expires_at))
        if result == "sent":
            job.status, job.sent_at, job.last_error = "sent", now, None
        elif result == "unregistered":
            device.active = False
            job.status, job.last_error = "suppressed", "unregistered"
        elif result == "rejected" or job.attempts >= 6:
            job.status, job.last_error = "failed", result
        else:
            job.available_at = now + timedelta(seconds=min(3600, 60 * 2 ** (job.attempts - 1)))
            job.last_error = result
    await session.commit()
    return True


async def worker(api):
    scheduled_at = None
    while True:
        try:
            now = utcnow()
            if scheduled_at is None or (now - scheduled_at).total_seconds() >= 60:
                from .notifications_scheduler import schedule_notifications
                async with api.SessionFactory() as session:
                    await schedule_notifications(api, session, now)
                    await session.commit()
                scheduled_at = now
            for _ in range(30):
                async with api.SessionFactory() as session:
                    if not await dispatch_pending(api, session, utcnow()):
                        break
        except asyncio.CancelledError:
            raise
        except Exception as error:
            log.warning("Notification worker error (%s); no message, token or credentials logged", type(error).__name__)
        await asyncio.sleep(10)
