import json
import asyncio
import sys
from contextlib import suppress
import secrets
import string
import uuid
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta, timezone

import jwt
from fastapi import Depends, FastAPI, Header, HTTPException, Response, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import Select, and_, delete, func, or_, select, text, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from .config import get_settings
from .database import SessionFactory, engine, get_session
from .models import (
    AttendanceDay,
    AttendanceLock,
    AttendanceRecord,
    AuditEvent,
    Base,
    Department,
    Employee,
    EmployeeHistory,
    FactStatus,
    Group,
    Position,
    RefreshToken,
    Role,
    ScopeKind,
    User,
    UserPreference,
    utcnow,
)
from .schemas import (
    AttendanceBulkIn,
    AttendanceRecordIn,
    AttendanceRecordOut,
    AttendanceCloseIn,
    AttendanceReopenIn,
    BootstrapIn,
    DepartmentIn,
    DepartmentOut,
    EmployeeIn,
    EmployeeOut,
    EmployeeUpdate,
    GroupIn,
    GroupOut,
    LoginIn,
    PasswordChangeIn,
    PositionIn,
    PositionOut,
    RefreshIn,
    RoleIn,
    RoleOut,
    RoleUpdate,
    TokenPair,
    UserCreate,
    UserHiddenGroupsIn,
    UserHiddenGroupsOut,
    UserOut,
    UserUpdate,
    UserPreferencesIn,
    UserPreferencesOut,
    PasswordResetOut,
)
from .security import (
    create_access_token,
    decode_access_token,
    hash_password,
    hash_refresh_token,
    new_refresh_token,
    verify_password,
)


from .history import ensure_employee_history, remember_employee, paid_minutes
from .attendance_scope import AttendanceScope
from .migrations import migrate
from .organization import bind_database
from .reports import month_report
from .timesheet_xlsx import make_timesheet

settings = get_settings()
bearer = HTTPBearer(auto_error=False)

DEFAULT_ROLES = (
    {
        "id": "super_admin",
        "name": "Суперадмин",
        "scope_kind": ScopeKind.all,
        "permissions": [],
        "is_system": True,
    },
    {
        "id": "manager",
        "name": "Руководитель",
        "scope_kind": ScopeKind.department,
        "permissions": [
            "viewCalendar",
            "viewEmployees",
            "viewAttendance",
            "editAttendance",
            "editEmployees",
            "manageUsers",
        ],
        "is_system": True,
    },
    {
        "id": "master",
        "name": "Мастер",
        "scope_kind": ScopeKind.group,
        "permissions": [
            "viewCalendar",
            "viewEmployees",
            "viewAttendance",
            "editAttendance",
        ],
        "is_system": True,
    },
    {
        "id": "worker",
        "name": "Рабочий",
        "scope_kind": ScopeKind.self,
        "permissions": ["viewCalendar", "viewEmployees", "viewAttendance"],
        "is_system": True,
    },
)

KNOWN_PERMISSIONS = {
    "viewCalendar",
    "viewEmployees",
    "viewAttendance",
    "editAttendance",
    "editEmployees",
    "manageUsers",
    "editRolePolicies",
    "viewMoney",
}

ADMIN_HIDDEN_GROUPS_KEY = "admin_hidden_group_ids"


async def seed_roles(session: AsyncSession) -> None:
    for definition in DEFAULT_ROLES:
        if await session.get(Role, definition["id"]) is None:
            session.add(Role(**definition))
    await session.commit()


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    await migrate()
    async with SessionFactory() as session:
        await bind_database(session, settings.ORGANIZATION_CODE)
        await seed_roles(session)
    from .telegram_delivery import worker
    delivery_task = asyncio.create_task(worker(sys.modules[__name__])) if settings.TELEGRAM_BOT_TOKEN and settings.TELEGRAM_BOT_USERNAME else None
    try:
        yield
    finally:
        if delivery_task:
            delivery_task.cancel()
            with suppress(asyncio.CancelledError):
                await delivery_task
        await engine.dispose()


app = FastAPI(
    title="Shift Tracker API",
    version="1.5.0",
    docs_url="/docs",
    redoc_url=None,
    lifespan=lifespan,
)

if settings.cors_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["GET", "POST", "PATCH", "PUT", "DELETE", "OPTIONS"],
        allow_headers=["Authorization", "Content-Type", "X-Bootstrap-Token", "X-Organization-Code"],
    )


@app.middleware("http")
async def check_organization(request, call_next):
    from fastapi.responses import JSONResponse
    selected = request.headers.get("X-Organization-Code")
    if selected is not None and selected != settings.ORGANIZATION_CODE:
        return JSONResponse(status_code=404, content={"detail": "Организация не найдена"})
    response = await call_next(request)
    response.headers["X-Organization-Code"] = settings.ORGANIZATION_CODE
    if request.url.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-store"
    return response


@app.get("/api/v1/organization")
async def organization_info() -> dict:
    return {"code": settings.ORGANIZATION_CODE, "name": settings.ORGANIZATION_NAME}


from .registration import register_routes as register_registration_routes
register_registration_routes(app)


def api_error(code: int, detail: str) -> HTTPException:
    return HTTPException(status_code=code, detail=detail)


async def audit(
    session: AsyncSession,
    *,
    actor: User | None,
    action: str,
    entity_type: str,
    entity_id: str | None = None,
    details: dict | None = None,
) -> None:
    session.add(
        AuditEvent(
            actor_id=actor.id if actor else None,
            action=action,
            entity_type=entity_type,
            entity_id=entity_id,
            details=details or {},
        )
    )


def user_query() -> Select[tuple[User]]:
    return select(User).options(selectinload(User.role))


async def load_user(session: AsyncSession, user_id: uuid.UUID) -> User | None:
    return await session.scalar(user_query().where(User.id == user_id))


async def lock_user(session: AsyncSession, user_id: uuid.UUID) -> User | None:
    # Password changes and refresh rotation use the same lock/transaction.
    return await session.scalar(user_query().where(User.id == user_id).with_for_update()
                                .execution_options(populate_existing=True))


def aware_utc(value: datetime) -> datetime:
    # SQLite test databases return naive UTC values; PostgreSQL returns aware values.
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value


async def revoke_sessions(session: AsyncSession, user: User) -> None:
    user.token_version += 1
    await session.execute(update(RefreshToken).where(
        RefreshToken.user_id == user.id, RefreshToken.revoked_at.is_(None)
    ).values(revoked_at=utcnow()))


async def current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
    session: AsyncSession = Depends(get_session),
) -> User:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise api_error(status.HTTP_401_UNAUTHORIZED, "Требуется авторизация")
    try:
        payload = decode_access_token(credentials.credentials)
        if payload.get("type") != "access":
            raise ValueError("wrong token type")
        user_id = uuid.UUID(payload["sub"])
        token_version = int(payload["ver"])
    except (jwt.PyJWTError, KeyError, TypeError, ValueError):
        raise api_error(status.HTTP_401_UNAUTHORIZED, "Недействительный токен") from None

    user = await load_user(session, user_id)
    if user is None or not user.is_active or user.token_version != token_version:
        raise api_error(status.HTTP_401_UNAUTHORIZED, "Сессия недействительна")
    return user


def is_super_admin(user: User) -> bool:
    return user.role_id == "super_admin"


def has_permission(user: User, permission: str) -> bool:
    return is_super_admin(user) or permission in user.role.permissions


def require_permission(permission: str) -> Callable:
    async def dependency(user: User = Depends(current_user)) -> User:
        if not has_permission(user, permission):
            raise api_error(status.HTTP_403_FORBIDDEN, "Недостаточно прав")
        return user

    return dependency


def require_super_admin(user: User) -> None:
    if not is_super_admin(user):
        raise api_error(status.HTTP_403_FORBIDDEN, "Операция доступна только суперадминистратору")


def has_global_scope(user: User) -> bool:
    return is_super_admin(user) or user.role.scope_kind == ScopeKind.all


def require_global_scope(user: User) -> None:
    if not has_global_scope(user):
        raise api_error(403, "Изменение общего справочника недоступно для этой области доступа")


def require_department_scope(user: User, department_id: uuid.UUID) -> None:
    if not has_global_scope(user) and not (
        user.role.scope_kind == ScopeKind.department and user.department_id == department_id
    ):
        raise api_error(404, "Подразделение не найдено")


async def require_group_scope(session: AsyncSession, user: User, group: Group) -> None:
    if group.id in await admin_hidden_group_ids(session, user.id):
        raise api_error(404, "Группа не найдена")
    if has_global_scope(user):
        return
    if user.role.scope_kind == ScopeKind.department and user.department_id == group.department_id:
        return
    if user.role.scope_kind == ScopeKind.group and user.group_id == group.id:
        return
    raise api_error(404, "Группа не найдена")


def employee_output(item: Employee, user: User) -> EmployeeOut:
    # Redact a DTO, never a persistent ORM object (which could be flushed later).
    result = EmployeeOut.model_validate(item)
    if not has_permission(user, "viewMoney"):
        result = result.model_copy(update={"salary": 0, "bonus": 0})
    return result


async def attendance_scope(session: AsyncSession, user: User, last: date) -> AttendanceScope:
    hidden = set(map(str, await admin_hidden_group_ids(session, user.id)))
    return await AttendanceScope.load(session, user, last, hidden)


async def attendance_employees(session: AsyncSession, user: User, day: date,
                               ids: set[uuid.UUID] | None = None) -> dict[uuid.UUID, dict]:
    scope = await attendance_scope(session, user, day)
    snapshots = await scope.day_employees(session, day)
    if ids is not None and not ids <= snapshots.keys():
        raise api_error(404, "Один из сотрудников не найден на выбранную дату")
    return snapshots


async def validate_user_binding(
    session: AsyncSession,
    *,
    role: Role,
    department_id: uuid.UUID | None,
    group_id: uuid.UUID | None,
    employee_id: uuid.UUID | None,
) -> tuple[uuid.UUID | None, uuid.UUID | None, uuid.UUID | None]:
    if role.scope_kind == ScopeKind.all:
        return None, None, employee_id
    if role.scope_kind == ScopeKind.department:
        if department_id is None or await session.get(Department, department_id) is None:
            raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Нужно существующее подразделение")
        return department_id, None, employee_id
    if role.scope_kind == ScopeKind.group:
        group = await session.get(Group, group_id) if group_id else None
        if group is None:
            raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Нужна существующая группа")
        return None, group.id, employee_id
    employee = await session.get(Employee, employee_id) if employee_id else None
    if employee is None or not employee.is_active:
        raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Нужен активный сотрудник")
    return None, None, employee.id


def generated_password() -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(18))


async def admin_hidden_group_ids(session: AsyncSession, user_id: uuid.UUID) -> list[uuid.UUID]:
    preference = await session.get(UserPreference, user_id)
    raw_ids = (preference.settings or {}).get(ADMIN_HIDDEN_GROUPS_KEY, []) if preference else []
    result: list[uuid.UUID] = []
    for raw_id in raw_ids if isinstance(raw_ids, list) else []:
        try:
            result.append(uuid.UUID(str(raw_id)))
        except (TypeError, ValueError):
            continue
    return result


async def scoped_employees(session: AsyncSession, query: Select, user: User) -> Select:
    if not (is_super_admin(user) or user.role.scope_kind == ScopeKind.all):
        if user.role.scope_kind == ScopeKind.department:
            if user.department_id is None:
                query = query.where(False)
            else:
                query = query.where(Employee.department_id == user.department_id)
        elif user.role.scope_kind == ScopeKind.group:
            if user.group_id is None:
                query = query.where(False)
            else:
                query = query.where(Employee.group_id == user.group_id)
        elif user.employee_id is None:
            query = query.where(False)
        else:
            query = query.where(Employee.id == user.employee_id)

    hidden_group_ids = await admin_hidden_group_ids(session, user.id)
    if hidden_group_ids:
        query = query.where(
            or_(Employee.group_id.is_(None), Employee.group_id.not_in(hidden_group_ids))
        )
    return query


async def ensure_employee_in_scope(
    session: AsyncSession, user: User, employee_id: uuid.UUID
) -> Employee:
    employee = await session.scalar(
        await scoped_employees(
            session,
            select(Employee).where(Employee.id == employee_id, Employee.is_active.is_(True)),
            user,
        )
    )
    if employee is None:
        raise api_error(status.HTTP_404_NOT_FOUND, "Сотрудник не найден")
    return employee


async def ensure_employees_in_scope(
    session: AsyncSession, user: User, employee_ids: set[uuid.UUID]
) -> None:
    if not employee_ids:
        return
    query = await scoped_employees(
        session,
        select(Employee.id).where(
            Employee.id.in_(employee_ids),
            Employee.is_active.is_(True),
        ),
        user,
    )
    found_ids = set((await session.scalars(query)).all())
    if found_ids != employee_ids:
        raise api_error(status.HTTP_404_NOT_FOUND, "Один из сотрудников не найден")


async def issue_tokens(session: AsyncSession, user: User) -> TokenPair:
    token_id, raw_refresh, refresh_hash, expires_at = new_refresh_token()
    session.add(
        RefreshToken(
            id=token_id,
            user_id=user.id,
            token_hash=refresh_hash,
            expires_at=expires_at,
        )
    )
    await session.commit()
    return TokenPair(
        access_token=create_access_token(user.id, user.token_version),
        refresh_token=raw_refresh,
        expires_in=settings.ACCESS_TOKEN_MINUTES * 60,
        user=UserOut.model_validate(user),
        organization={"code": settings.ORGANIZATION_CODE, "name": settings.ORGANIZATION_NAME},
    )


@app.get("/health")
async def health(session: AsyncSession = Depends(get_session)) -> dict:
    await session.scalar(select(func.now()))
    return {"status": "ok"}


@app.get("/api/v1/auth/bootstrap/status")
async def bootstrap_status(session: AsyncSession = Depends(get_session)) -> dict:
    count = await session.scalar(select(func.count()).select_from(User))
    return {"required": count == 0}


@app.post("/api/v1/auth/bootstrap", response_model=TokenPair)
async def bootstrap(
    body: BootstrapIn,
    x_bootstrap_token: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> TokenPair:
    if x_bootstrap_token != settings.BOOTSTRAP_TOKEN:
        raise api_error(status.HTTP_403_FORBIDDEN, "Недействительный bootstrap token")
    role = await session.scalar(select(Role).where(Role.id == "super_admin").with_for_update())
    if (await session.scalar(select(func.count()).select_from(User))) != 0:
        raise api_error(status.HTTP_409_CONFLICT, "Система уже инициализирована")

    if role is None:
        raise api_error(status.HTTP_500_INTERNAL_SERVER_ERROR, "Системная роль отсутствует")

    user = User(
        login=body.login.strip().lower(),
        password_hash=hash_password(body.password),
        role_id=role.id,
        first_name=body.login.strip(),
    )
    session.add(user)
    await audit(session, actor=None, action="bootstrap", entity_type="user", entity_id=str(user.id))
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Логин уже используется") from None
    user = await load_user(session, user.id)
    assert user is not None
    return await issue_tokens(session, user)


@app.post("/api/v1/auth/login", response_model=TokenPair)
async def login(body: LoginIn, session: AsyncSession = Depends(get_session)) -> TokenPair:
    user = await session.scalar(
        user_query().where(func.lower(User.login) == body.login.strip().lower()).with_for_update()
    )
    generic_error = api_error(status.HTTP_401_UNAUTHORIZED, "Неверный логин или пароль")
    if user is None or not user.is_active:
        raise generic_error

    now = utcnow()
    if user.locked_until is not None and aware_utc(user.locked_until) > now:
        raise api_error(status.HTTP_429_TOO_MANY_REQUESTS, "Вход временно заблокирован")
    if user.locked_until is not None and aware_utc(user.locked_until) <= now:
        user.failed_login_attempts = 0
        user.locked_until = None

    if not verify_password(body.password, user.password_hash):
        user.failed_login_attempts += 1
        if user.failed_login_attempts >= 5:
            user.locked_until = now + timedelta(minutes=5)
            user.failed_login_attempts = 0
        await session.commit()
        raise generic_error

    user.failed_login_attempts = 0
    user.locked_until = None
    await audit(session, actor=user, action="login", entity_type="session")
    return await issue_tokens(session, user)


@app.post("/api/v1/auth/refresh", response_model=TokenPair)
async def refresh(body: RefreshIn, session: AsyncSession = Depends(get_session)) -> TokenPair:
    try:
        token_id = uuid.UUID(body.refresh_token.split(".", 1)[0])
    except (ValueError, IndexError):
        raise api_error(status.HTTP_401_UNAUTHORIZED, "Недействительный refresh token") from None
    token = await session.get(RefreshToken, token_id)
    if token is None:
        raise api_error(status.HTTP_401_UNAUTHORIZED, "Недействительный refresh token")
    user = await lock_user(session, token.user_id)
    await session.refresh(token)
    now = utcnow()
    if (
        token is None
        or token.revoked_at is not None
        or aware_utc(token.expires_at) <= now
        or token.token_hash != hash_refresh_token(body.refresh_token)
    ):
        raise api_error(status.HTTP_401_UNAUTHORIZED, "Недействительный refresh token")
    token.revoked_at = now
    if user is None or not user.is_active:
        await session.commit()
        raise api_error(status.HTTP_401_UNAUTHORIZED, "Пользователь отключён")
    return await issue_tokens(session, user)


@app.post("/api/v1/auth/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(
    body: RefreshIn,
    _: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Response:
    try:
        token_id = uuid.UUID(body.refresh_token.split(".", 1)[0])
    except (ValueError, IndexError):
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    token = await session.get(RefreshToken, token_id)
    if token is not None and token.token_hash == hash_refresh_token(body.refresh_token):
        token.revoked_at = utcnow()
        await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/api/v1/auth/me", response_model=UserOut)
async def me(user: User = Depends(current_user)) -> User:
    return user


@app.get("/api/v1/preferences", response_model=UserPreferencesOut)
async def get_preferences(
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> UserPreferencesOut:
    preference = await session.get(UserPreference, user.id)
    if preference is None:
        return UserPreferencesOut(settings={}, updated_at=None)
    return UserPreferencesOut(
        settings=preference.settings or {},
        updated_at=preference.updated_at,
    )


@app.put("/api/v1/preferences", response_model=UserPreferencesOut)
async def save_preferences(
    payload: UserPreferencesIn,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> UserPreferencesOut:
    if len(json.dumps(payload.settings, ensure_ascii=False)) > 65536:
        raise api_error(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "Настройки слишком большие")

    preference = await session.get(UserPreference, user.id)
    settings_value = dict(payload.settings)
    existing_admin_hidden = (
        (preference.settings or {}).get(ADMIN_HIDDEN_GROUPS_KEY, [])
        if preference is not None
        else []
    )
    settings_value[ADMIN_HIDDEN_GROUPS_KEY] = existing_admin_hidden
    if preference is None:
        preference = UserPreference(user_id=user.id, settings=settings_value)
        session.add(preference)
    else:
        preference.settings = settings_value
        preference.updated_at = utcnow()

    await audit(
        session,
        actor=user,
        action="update_preferences",
        entity_type="user_preferences",
        entity_id=str(user.id),
    )
    await session.commit()
    await session.refresh(preference)
    return UserPreferencesOut(
        settings=preference.settings,
        updated_at=preference.updated_at,
    )


@app.post("/api/v1/auth/change-password", status_code=status.HTTP_204_NO_CONTENT)
async def change_password(
    body: PasswordChangeIn,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Response:
    user = await lock_user(session, user.id)
    if user is None or not user.is_active:
        raise api_error(401, "Сессия недействительна")
    if not verify_password(body.current_password, user.password_hash):
        raise api_error(status.HTTP_400_BAD_REQUEST, "Текущий пароль указан неверно")
    if body.current_password == body.new_password:
        raise api_error(status.HTTP_400_BAD_REQUEST, "Новый пароль должен отличаться")

    user.password_hash = hash_password(body.new_password)
    await revoke_sessions(session, user)
    await audit(session, actor=user, action="change_password", entity_type="user", entity_id=str(user.id))
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/api/v1/roles", response_model=list[RoleOut])
async def roles(
    _: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> list[Role]:
    return list((await session.scalars(select(Role).order_by(Role.name))).all())


@app.post("/api/v1/roles", response_model=RoleOut, status_code=201)
async def create_role(
    body: RoleIn,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Role:
    require_super_admin(user)
    unknown = set(body.permissions) - KNOWN_PERMISSIONS
    if unknown:
        raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Неизвестные права роли")
    if body.id in {definition["id"] for definition in DEFAULT_ROLES}:
        raise api_error(status.HTTP_409_CONFLICT, "Системный идентификатор занят")
    item = Role(
        id=body.id,
        name=body.name.strip(),
        scope_kind=body.scope_kind,
        permissions=sorted(set(body.permissions)),
        is_system=False,
    )
    session.add(item)
    await audit(session, actor=user, action="create", entity_type="role", entity_id=item.id)
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Роль уже существует") from None
    await session.refresh(item)
    return item


@app.patch("/api/v1/roles/{role_id}", response_model=RoleOut)
async def update_role(
    role_id: str,
    body: RoleUpdate,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Role:
    require_super_admin(user)
    role = await session.get(Role, role_id)
    if role is None:
        raise api_error(status.HTTP_404_NOT_FOUND, "Роль не найдена")
    if role.is_system:
        raise api_error(status.HTTP_409_CONFLICT, "Системную роль изменять нельзя")
    if body.permissions is not None:
        unknown = set(body.permissions) - KNOWN_PERMISSIONS
        if unknown:
            raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Неизвестные права роли")
        role.permissions = sorted(set(body.permissions))
    if body.name is not None:
        role.name = body.name.strip()
    if body.scope_kind is not None:
        role.scope_kind = body.scope_kind
    await audit(session, actor=user, action="update", entity_type="role", entity_id=role.id)
    await session.commit()
    await session.refresh(role)
    return role


@app.delete("/api/v1/roles/{role_id}", status_code=204)
async def delete_role(
    role_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Response:
    require_super_admin(user)
    role = await session.get(Role, role_id)
    if role is None:
        return Response(status_code=204)
    if role.is_system:
        raise api_error(status.HTTP_409_CONFLICT, "Системную роль удалять нельзя")
    if await session.scalar(select(func.count()).select_from(User).where(User.role_id == role_id)):
        raise api_error(status.HTTP_409_CONFLICT, "Роль назначена пользователям")
    await audit(session, actor=user, action="delete", entity_type="role", entity_id=role.id)
    await session.delete(role)
    await session.commit()
    return Response(status_code=204)


@app.get("/api/v1/users", response_model=list[UserOut])
async def users(
    user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> list[User]:
    require_super_admin(user)
    return list((await session.scalars(user_query().order_by(User.last_name, User.first_name))).all())


@app.get("/api/v1/users/{user_id}/hidden-groups", response_model=UserHiddenGroupsOut)
async def get_user_hidden_groups(
    user_id: uuid.UUID,
    actor: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> UserHiddenGroupsOut:
    require_super_admin(actor)
    if await session.get(User, user_id) is None:
        raise api_error(status.HTTP_404_NOT_FOUND, "Пользователь не найден")
    return UserHiddenGroupsOut(
        hidden_group_ids=await admin_hidden_group_ids(session, user_id)
    )


@app.put("/api/v1/users/{user_id}/hidden-groups", response_model=UserHiddenGroupsOut)
async def set_user_hidden_groups(
    user_id: uuid.UUID,
    body: UserHiddenGroupsIn,
    actor: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> UserHiddenGroupsOut:
    require_super_admin(actor)
    if await session.get(User, user_id) is None:
        raise api_error(status.HTTP_404_NOT_FOUND, "Пользователь не найден")

    unique_ids = list(dict.fromkeys(body.hidden_group_ids))
    if unique_ids:
        existing_ids = set(
            (
                await session.scalars(select(Group.id).where(Group.id.in_(unique_ids)))
            ).all()
        )
        if existing_ids != set(unique_ids):
            raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Одна из групп не найдена")

    preference = await session.get(UserPreference, user_id)
    settings_value = dict(preference.settings or {}) if preference else {}
    settings_value[ADMIN_HIDDEN_GROUPS_KEY] = [str(group_id) for group_id in unique_ids]
    if preference is None:
        preference = UserPreference(user_id=user_id, settings=settings_value)
        session.add(preference)
    else:
        preference.settings = settings_value
        preference.updated_at = utcnow()

    await audit(
        session,
        actor=actor,
        action="update_group_visibility",
        entity_type="user",
        entity_id=str(user_id),
        details={"hidden_group_ids": settings_value[ADMIN_HIDDEN_GROUPS_KEY]},
    )
    await session.commit()
    return UserHiddenGroupsOut(hidden_group_ids=unique_ids)


@app.post("/api/v1/users", response_model=UserOut, status_code=201)
async def create_user(
    body: UserCreate,
    actor: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> User:
    require_super_admin(actor)
    role = await session.get(Role, body.role_id)
    if role is None:
        raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Роль не найдена")
    dep, group, employee = await validate_user_binding(
        session,
        role=role,
        department_id=body.department_id,
        group_id=body.group_id,
        employee_id=body.employee_id,
    )
    item = User(
        login=body.login.strip().lower(),
        password_hash=hash_password(body.password),
        role_id=role.id,
        last_name=body.last_name.strip(),
        first_name=body.first_name.strip(),
        middle_name=body.middle_name.strip(),
        department_id=dep,
        group_id=group,
        employee_id=employee,
    )
    session.add(item)
    await audit(session, actor=actor, action="create", entity_type="user", entity_id=str(item.id))
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Логин или сотрудник уже используются") from None
    loaded = await load_user(session, item.id)
    assert loaded is not None
    return loaded


@app.patch("/api/v1/users/{user_id}", response_model=UserOut)
async def update_user(
    user_id: uuid.UUID,
    body: UserUpdate,
    actor: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> User:
    require_super_admin(actor)
    target = await lock_user(session, user_id)
    if target is None:
        raise api_error(status.HTTP_404_NOT_FOUND, "Пользователь не найден")
    if target.role_id == "super_admin" and target.id != actor.id:
        raise api_error(status.HTTP_409_CONFLICT, "Нельзя изменять другого суперадминистратора")
    role = await session.get(Role, body.role_id)
    if role is None:
        raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Роль не найдена")
    dep, group, employee = await validate_user_binding(
        session,
        role=role,
        department_id=body.department_id,
        group_id=body.group_id,
        employee_id=body.employee_id,
    )
    if target.id == actor.id and role.id != "super_admin":
        raise api_error(status.HTTP_409_CONFLICT, "Нельзя снять собственные права суперадминистратора")
    target.role_id = role.id
    target.last_name = body.last_name.strip()
    target.first_name = body.first_name.strip()
    target.middle_name = body.middle_name.strip()
    target.department_id = dep
    target.group_id = group
    target.employee_id = employee
    target.is_active = body.is_active
    await revoke_sessions(session, target)
    await audit(session, actor=actor, action="update", entity_type="user", entity_id=str(target.id))
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Сотрудник уже связан с другим пользователем") from None
    loaded = await load_user(session, target.id)
    assert loaded is not None
    return loaded


@app.post("/api/v1/users/{user_id}/reset-password", response_model=PasswordResetOut)
async def reset_user_password(
    user_id: uuid.UUID,
    actor: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> PasswordResetOut:
    require_super_admin(actor)
    target = await lock_user(session, user_id)
    if target is None:
        raise api_error(status.HTTP_404_NOT_FOUND, "Пользователь не найден")
    password = generated_password()
    target.password_hash = hash_password(password)
    target.failed_login_attempts = 0
    target.locked_until = None
    await revoke_sessions(session, target)
    await audit(session, actor=actor, action="reset_password", entity_type="user", entity_id=str(target.id))
    await session.commit()
    return PasswordResetOut(temporary_password=password)


@app.delete("/api/v1/users/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_user(
    user_id: uuid.UUID,
    actor: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Response:
    require_super_admin(actor)
    target = await lock_user(session, user_id)
    if target is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    if target.id == actor.id or target.role_id == "super_admin":
        raise api_error(status.HTTP_409_CONFLICT, "Суперадминистратора удалить нельзя")
    target.is_active = False
    await revoke_sessions(session, target)
    await audit(session, actor=actor, action="deactivate", entity_type="user", entity_id=str(target.id))
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/api/v1/departments", response_model=list[DepartmentOut])
async def departments(
    user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> list[Department]:
    query = select(Department).order_by(Department.name)
    if not has_global_scope(user):
        if user.role.scope_kind == ScopeKind.department:
            query = query.where(Department.id == user.department_id) if user.department_id else query.where(False)
        elif user.role.scope_kind == ScopeKind.group:
            query = query.where(Department.id.in_(select(Group.department_id).where(
                Group.id == user.group_id))) if user.group_id else query.where(False)
        else:
            query = query.where(Department.id.in_(select(Employee.department_id).where(
                Employee.id == user.employee_id))) if user.employee_id else query.where(False)
    return list((await session.scalars(query)).all())


@app.post("/api/v1/departments", response_model=DepartmentOut, status_code=201)
async def create_department(
    body: DepartmentIn,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Department:
    require_global_scope(user)
    item = Department(id=body.id or uuid.uuid4(), name=body.name)
    session.add(item)
    await audit(session, actor=user, action="create", entity_type="department", entity_id=str(item.id))
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Подразделение уже существует") from None
    await session.refresh(item)
    return item


@app.patch("/api/v1/departments/{department_id}", response_model=DepartmentOut)
async def update_department(
    department_id: uuid.UUID,
    body: DepartmentIn,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Department:
    require_department_scope(user, department_id)
    item = await session.get(Department, department_id)
    if item is None:
        raise api_error(status.HTTP_404_NOT_FOUND, "Подразделение не найдено")
    item.name = body.name
    await audit(session, actor=user, action="update", entity_type="department", entity_id=str(item.id))
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Подразделение уже существует") from None
    await session.refresh(item)
    return item


async def detach_structure_members(
    session: AsyncSession, user: User, group_ids: list[uuid.UUID],
    department_id: uuid.UUID | None, detach_members: bool,
) -> None:
    """Keep history intact; removal never deletes employees or broadens user access."""
    hidden = set(await admin_hidden_group_ids(session, user.id))
    if hidden.intersection(group_ids):
        raise api_error(403, "В подразделении есть недоступные вам группы")
    employee_filter = Employee.group_id.in_(group_ids)
    user_filter = User.group_id.in_(group_ids)
    if department_id is not None:
        employee_filter = or_(employee_filter, Employee.department_id == department_id)
        user_filter = or_(user_filter, User.department_id == department_id)
    accounts = list((await session.scalars(select(User).where(user_filter).with_for_update())).all())
    active_accounts = sum(account.is_active for account in accounts)
    if active_accounts:
        raise api_error(409, f"К структуре привязаны действующие учётные записи: {active_accounts}. "
                        "Администратору нужно изменить их область доступа или отключить их в разделе «Пользователи».")
    staff = list((await session.scalars(select(Employee).where(employee_filter).with_for_update())).all())
    if not detach_members and any(employee.is_active for employee in staff):
        raise api_error(409, "Есть действующие сотрудники. Подтвердите удаление структуры без удаления людей "
                        "в новой версии приложения или сначала перенесите сотрудников.")
    for employee in staff:
        await ensure_employee_history(session, employee)
        employee.group_id = None
        if department_id is not None:
            employee.department_id = None
        if employee.is_active:
            await remember_employee(session, employee, date.today())
    for account in accounts:
        account.group_id = None
        if department_id is not None:
            account.department_id = None
    await session.flush()


@app.delete("/api/v1/departments/{department_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_department(
    department_id: uuid.UUID,
    detach_members: bool = False,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Response:
    require_department_scope(user, department_id)
    await lock_employee_roster(session)
    item = await session.get(Department, department_id)
    if item is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    group_ids = list((await session.scalars(select(Group.id).where(Group.department_id == item.id))).all())
    if group_ids and not detach_members:
        raise api_error(409, "В подразделении есть группы. Подтвердите удаление подразделения вместе с группами или перенесите их.")
    await detach_structure_members(session, user, group_ids, item.id, detach_members)
    await session.execute(delete(Group).where(Group.id.in_(group_ids)))
    await audit(session, actor=user, action="delete", entity_type="department", entity_id=str(item.id),
                details={"employees_preserved": True, "removed_groups": len(group_ids)})
    try:
        await session.delete(item)
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Привязки подразделения изменились. Обновите структуру и повторите удаление.") from None
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/api/v1/groups", response_model=list[GroupOut])
async def groups(
    department_id: uuid.UUID | None = None,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> list[Group]:
    query = select(Group).order_by(Group.name)
    if department_id is not None:
        query = query.where(Group.department_id == department_id)
    if not has_global_scope(user):
        if user.role.scope_kind == ScopeKind.department:
            query = query.where(Group.department_id == user.department_id) if user.department_id else query.where(False)
        elif user.role.scope_kind == ScopeKind.group:
            query = query.where(Group.id == user.group_id) if user.group_id else query.where(False)
        else:
            query = query.where(Group.id.in_(select(Employee.group_id).where(
                Employee.id == user.employee_id))) if user.employee_id else query.where(False)
    hidden_ids = await admin_hidden_group_ids(session, user.id)
    if hidden_ids:
        query = query.where(Group.id.not_in(hidden_ids))
    return list((await session.scalars(query)).all())


@app.post("/api/v1/groups", response_model=GroupOut, status_code=201)
async def create_group(
    body: GroupIn,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Group:
    require_department_scope(user, body.department_id)
    if await session.get(Department, body.department_id) is None:
        raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Подразделение не найдено")
    item = Group(id=body.id or uuid.uuid4(), department_id=body.department_id, name=body.name.strip())
    session.add(item)
    await audit(session, actor=user, action="create", entity_type="group", entity_id=str(item.id))
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Группа уже существует") from None
    await session.refresh(item)
    return item


@app.patch("/api/v1/groups/{group_id}", response_model=GroupOut)
async def update_group(
    group_id: uuid.UUID,
    body: GroupIn,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Group:
    item = await session.get(Group, group_id)
    if item is None:
        raise api_error(status.HTTP_404_NOT_FOUND, "Группа не найдена")
    await require_group_scope(session, user, item)
    if body.department_id != item.department_id:
        require_global_scope(user)
        # Moving a populated group would leave employee/user bindings inconsistent.
        in_use = await session.scalar(select(Employee.id).where(Employee.group_id == item.id).limit(1))
        user_in_group = await session.scalar(select(User.id).where(User.group_id == item.id).limit(1))
        if in_use is not None or user_in_group is not None:
            raise api_error(409, "Сначала перенесите сотрудников и пользователей из группы")
    if await session.get(Department, body.department_id) is None:
        raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Подразделение не найдено")
    item.department_id = body.department_id
    item.name = body.name.strip()
    await audit(session, actor=user, action="update", entity_type="group", entity_id=str(item.id))
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Группа уже существует") from None
    await session.refresh(item)
    return item


@app.delete("/api/v1/groups/{group_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_group(
    group_id: uuid.UUID,
    detach_members: bool = False,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Response:
    await lock_employee_roster(session)
    item = await session.get(Group, group_id)
    if item is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    await require_group_scope(session, user, item)
    await detach_structure_members(session, user, [item.id], None, detach_members)
    await audit(session, actor=user, action="delete", entity_type="group", entity_id=str(item.id))
    try:
        await session.delete(item)
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Привязки группы изменились. Обновите структуру и повторите удаление.") from None
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/api/v1/positions", response_model=list[PositionOut])
async def positions(
    _: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> list[Position]:
    return list((await session.scalars(select(Position).order_by(Position.name))).all())


@app.post("/api/v1/positions", response_model=PositionOut, status_code=201)
async def create_position(
    body: PositionIn,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Position:
    item = Position(id=body.id or uuid.uuid4(), name=body.name.strip())
    session.add(item)
    await audit(session, actor=user, action="create", entity_type="position", entity_id=str(item.id))
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Должность уже существует") from None
    await session.refresh(item)
    return item


@app.patch("/api/v1/positions/{position_id}", response_model=PositionOut)
async def update_position(
    position_id: uuid.UUID,
    body: PositionIn,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Position:
    require_global_scope(user)
    item = await session.get(Position, position_id)
    if item is None:
        raise api_error(status.HTTP_404_NOT_FOUND, "Должность не найдена")
    item.name = body.name.strip()
    await audit(session, actor=user, action="update", entity_type="position", entity_id=str(item.id))
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Должность уже существует") from None
    await session.refresh(item)
    return item


@app.delete("/api/v1/positions/{position_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_position(
    position_id: uuid.UUID,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Response:
    require_global_scope(user)
    item = await session.get(Position, position_id)
    if item is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    await audit(session, actor=user, action="delete", entity_type="position", entity_id=str(item.id))
    try:
        await session.delete(item)
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Должность используется") from None
    return Response(status_code=status.HTTP_204_NO_CONTENT)


async def validate_employee_links(session: AsyncSession, body: EmployeeIn) -> None:
    group = await session.get(Group, body.group_id) if body.group_id else None
    if body.group_id and group is None:
        raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Группа не найдена")
    if group and body.department_id != group.department_id:
        raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Группа не относится к подразделению")
    if body.position_id and await session.get(Position, body.position_id) is None:
        raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Должность не найдена")
    if body.department_id and await session.get(Department, body.department_id) is None:
        raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Подразделение не найдено")
    if body.break_hours >= body.shift_hours:
        raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Перерыв должен быть короче смены")


@app.get("/api/v1/employees", response_model=list[EmployeeOut])
async def employees(
    include_inactive: bool = False,
    on_date: date | None = None,
    user: User = Depends(require_permission("viewEmployees")),
    session: AsyncSession = Depends(get_session),
) -> list[EmployeeOut]:
    if on_date is not None:
        if not has_permission(user, "viewAttendance"):
            raise api_error(403, "Недостаточно прав для просмотра истории")
        snapshots = await attendance_employees(session, user, on_date)
        items = list((await session.scalars(select(Employee).where(
            Employee.id.in_(snapshots)).order_by(Employee.full_name))).all())
        result = []
        for item in items:
            snapshot = snapshots[item.id]
            values = EmployeeOut.model_validate(item).model_dump()
            values.update(snapshot)
            # History is deliberately non-financial; never expose current pay here.
            values.update(salary=0, bonus=0, position_id=snapshot.get("position_id"),
                          position_name=snapshot.get("position", ""))
            result.append(EmployeeOut.model_validate(values))
        return result
    query = select(Employee).order_by(Employee.full_name)
    if not include_inactive:
        query = query.where(Employee.is_active.is_(True))
    query = await scoped_employees(session, query, user)
    items = list((await session.scalars(query)).all())
    return [employee_output(item, user) for item in items]


@app.post("/api/v1/employees", response_model=EmployeeOut, status_code=201)
async def create_employee(
    body: EmployeeIn,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> EmployeeOut:
    await lock_employee_roster(session)
    await validate_employee_links(session, body)
    if user.role.scope_kind == ScopeKind.department and body.department_id != user.department_id:
        raise api_error(status.HTTP_403_FORBIDDEN, "Нельзя создавать сотрудника вне своего подразделения")
    if user.role.scope_kind == ScopeKind.group and body.group_id != user.group_id:
        raise api_error(status.HTTP_403_FORBIDDEN, "Нельзя создавать сотрудника вне своей группы")
    if user.role.scope_kind == ScopeKind.self and not is_super_admin(user):
        raise api_error(status.HTTP_403_FORBIDDEN, "Недостаточно области доступа")
    values = body.model_dump(exclude_none=True)
    if not has_permission(user, "viewMoney"):
        values.update(salary=0, bonus=0)
    item = Employee(**values)
    session.add(item)
    await session.flush()
    await remember_employee(session, item, min(date.today(), item.schedule_start_date))
    await audit(session, actor=user, action="create", entity_type="employee", entity_id=str(item.id))
    await session.commit()
    await session.refresh(item)
    return employee_output(item, user)


@app.patch("/api/v1/employees/{employee_id}", response_model=EmployeeOut)
async def update_employee(
    employee_id: uuid.UUID,
    body: EmployeeUpdate,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> EmployeeOut:
    await lock_employee_roster(session)
    item = await ensure_employee_in_scope(session, user, employee_id)
    await ensure_employee_history(session, item)
    changes = body.model_dump(exclude_unset=True)
    if not has_permission(user, "viewMoney"):
        # Older clients send the entire form, including redacted zeros.
        changes.pop("salary", None)
        changes.pop("bonus", None)
    candidate = EmployeeIn(
        id=item.id,
        full_name=changes.get("full_name", item.full_name),
        position_id=changes.get("position_id", item.position_id),
        department_id=changes.get("department_id", item.department_id),
        group_id=changes.get("group_id", item.group_id),
        salary=changes.get("salary", item.salary),
        bonus=changes.get("bonus", item.bonus),
        schedule_type=changes.get("schedule_type", item.schedule_type),
        schedule_start_date=changes.get("schedule_start_date", item.schedule_start_date),
        shift_hours=changes.get("shift_hours", item.shift_hours),
        break_hours=changes.get("break_hours", item.break_hours),
        custom_workdays=changes.get("custom_workdays", item.custom_workdays),
    )
    await validate_employee_links(session, candidate)
    if user.role.scope_kind == ScopeKind.department and candidate.department_id != user.department_id:
        raise api_error(status.HTTP_403_FORBIDDEN, "Нельзя переносить сотрудника вне своего подразделения")
    if user.role.scope_kind == ScopeKind.group and candidate.group_id != user.group_id:
        raise api_error(status.HTTP_403_FORBIDDEN, "Нельзя переносить сотрудника вне своей группы")
    for field, value in changes.items():
        setattr(item, field, value)
    await remember_employee(session, item, date.today())
    await audit(session, actor=user, action="update", entity_type="employee", entity_id=str(item.id))
    await session.commit()
    await session.refresh(item)
    return employee_output(item, user)


@app.delete("/api/v1/employees/{employee_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_employee(
    employee_id: uuid.UUID,
    permanent: bool = False,
    disable_linked_account: bool = False,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Response:
    if not permanent:
        raise api_error(409, "Удаление теперь удаляет карточку и все её часы. Обновите приложение и подтвердите «Удалить навсегда».")
    await lock_employee_roster(session)
    item = await session.scalar(await scoped_employees(session, select(Employee).where(Employee.id == employee_id), user))
    if item is None:
        raise api_error(404, "Сотрудник не найден")
    linked_users = list((await session.scalars(select(User).where(
        User.employee_id == item.id, User.is_active.is_(True)).with_for_update())).all())
    if linked_users:
        if not disable_linked_account:
            raise api_error(409, "У сотрудника есть действующий вход. Администратор может подтвердить его отключение при удалении сотрудника.")
        require_super_admin(user)
        if any(account.id == user.id or account.role_id == "super_admin" for account in linked_users):
            raise api_error(409, "Нельзя отключить собственную учётную запись или суперадминистратора. Сначала измените привязку сотрудника в разделе «Пользователи».")
        for account in linked_users:
            account.is_active = False
            await revoke_sessions(session, account)
            await audit(session, actor=user, action="deactivate", entity_type="user", entity_id=str(account.id))
    # Deletion is explicit and permanent; history of unrelated employees is untouched.
    await session.execute(update(User).where(User.employee_id == item.id).values(employee_id=None))
    await session.execute(delete(AttendanceRecord).where(AttendanceRecord.employee_id == item.id))
    await session.execute(delete(AttendanceLock).where(AttendanceLock.employee_id == item.id))
    await session.execute(delete(EmployeeHistory).where(EmployeeHistory.employee_id == item.id))
    await audit(session, actor=user, action="delete", entity_type="employee", entity_id=str(item.id),
                details={"attendance_deleted": True})
    await session.delete(item)
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/api/v1/employees/{employee_id}", response_model=EmployeeOut)
async def employee(
    employee_id: uuid.UUID,
    user: User = Depends(require_permission("viewEmployees")),
    session: AsyncSession = Depends(get_session),
) -> EmployeeOut:
    item = await ensure_employee_in_scope(session, user, employee_id)
    return employee_output(item, user)


@app.get("/api/v1/attendance")
async def attendance_range(
    date_from: date,
    date_to: date,
    user: User = Depends(require_permission("viewAttendance")),
    session: AsyncSession = Depends(get_session),
) -> dict[str, dict[str, object]]:
    if date_to < date_from or (date_to - date_from).days > 5000:
        raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Недопустимый диапазон дат")
    scope = await attendance_scope(session, user, date_to)
    records = list(
        (
            await session.scalars(
                select(AttendanceRecord).where(
                    AttendanceRecord.day.between(date_from, date_to),
                    AttendanceRecord.employee_id.in_(scope.candidates),
                )
            )
        ).all()
    )
    records = [item for item in records if scope.snapshot(item.employee_id, item.day)]
    locks = list((await session.scalars(select(AttendanceLock).where(
        AttendanceLock.day.between(date_from, date_to),
        AttendanceLock.employee_id.in_(scope.candidates),
    ))).all())
    locked_by_day: dict[date, set[str]] = {}
    for lock in locks:
        if scope.snapshot(lock.employee_id, lock.day):
            locked_by_day.setdefault(lock.day, set()).add(str(lock.employee_id))
    result: dict[str, dict[str, object]] = {}
    for item in records:
        day_map = result.setdefault(item.day.isoformat(), {})
        day_map[str(item.employee_id)] = {
            "fact": item.fact.value,
            "comment": item.comment,
            "workedMinutes": item.worked_minutes,
            "actualStart": item.actual_start.isoformat(timespec="minutes")
            if item.actual_start
            else None,
            "actualEnd": item.actual_end.isoformat(timespec="minutes")
            if item.actual_end
            else None,
            "updatedAt": item.updated_at.isoformat(),
        }
    for day in set(locked_by_day) | {item.day for item in records}:
        day_map = result.setdefault(day.isoformat(), {})
        locked_ids = locked_by_day.get(day, set())
        active_ids = {str(employee_id) for employee_id in scope.candidates
                      if (snapshot := scope.snapshot(employee_id, day)) and
                      snapshot.get("is_active", True) and
                      day >= date.fromisoformat(snapshot["schedule_start_date"])}
        day_map["_meta"] = {
            "closed": bool(active_ids) and active_ids <= locked_ids,
            "closedEmployeeIds": sorted(locked_ids),
        }
        for employee_id in locked_ids:
            day_map.setdefault(employee_id, {"fact": "none", "workedMinutes": 0})
        for employee_id, value in day_map.items():
            if employee_id != "_meta":
                value["closed"] = employee_id in locked_ids
    return result



@app.get("/api/v1/self/schedule")
async def self_schedule(
    date_from: date, date_to: date,
    user: User = Depends(require_permission("viewCalendar")),
    session: AsyncSession = Depends(get_session),
) -> dict:
    # Every personal calendar includes its owner's facts, never the staff directory.
    if user.role.scope_kind != ScopeKind.self:
        raise api_error(403, "Этот раздел предназначен для личного графика сотрудника")
    if date_to < date_from or (date_to - date_from).days > 370:
        raise api_error(422, "Недопустимый диапазон дат")
    employee = await session.scalar(await scoped_employees(
        session, select(Employee).where(Employee.is_active.is_(True)), user,
    ))
    if employee is None:
        raise api_error(409, "Учётная запись не привязана к действующему сотруднику. Попросите администратора проверить привязку.")
    payload = EmployeeOut.model_validate(employee).model_dump(mode="json")
    position = await session.get(Position, employee.position_id) if employee.position_id else None
    payload.pop("salary", None)
    payload.pop("bonus", None)
    payload["position_name"] = position.name if position else ""
    facts = await attendance_range(date_from=date_from, date_to=date_to, user=user, session=session)
    return {"employee": payload, "attendance": facts, "can_view_attendance": True}


async def lock_employee_roster(session: AsyncSession) -> None:
    if session.bind.dialect.name == "postgresql":
        await session.execute(text("SELECT pg_advisory_xact_lock(193701, 3)"))


async def lock_attendance_day(session: AsyncSession, day: date) -> None:
    # Serialize close/edit operations on the same date to prevent lost updates.
    # SQLite is only used by isolated tests; production runs on PostgreSQL.
    if session.bind.dialect.name == "postgresql":
        await session.execute(pg_insert(AttendanceDay).values(day=day).on_conflict_do_nothing())
        await session.scalar(select(AttendanceDay).where(AttendanceDay.day == day).with_for_update())
    elif await session.get(AttendanceDay, day) is None:
        session.add(AttendanceDay(day=day))
        await session.flush()


async def save_attendance_record(session: AsyncSession, user: User, day: date,
                                 employee_id: uuid.UUID, body: AttendanceRecordIn,
                                 snapshot: dict | None = None) -> AttendanceRecord:
    if snapshot is None:
        snapshot = (await attendance_employees(session, user, day, {employee_id}))[employee_id]
    if await session.get(AttendanceLock, (day, employee_id)) is not None:
        raise api_error(409, "День для этого сотрудника закрыт")
    record = await session.get(AttendanceRecord, (day, employee_id))
    if record is None:
        record = AttendanceRecord(day=day, employee_id=employee_id)
        session.add(record)
    minutes = body.worked_minutes
    if body.fact == FactStatus.worked and minutes is None:
        minutes = paid_minutes(snapshot)
    elif body.fact not in {FactStatus.worked, FactStatus.businessTrip, FactStatus.vacationWorked}:
        minutes = 0
    record.fact = body.fact
    record.comment = body.comment.strip() if body.comment else None
    record.worked_minutes = minutes if minutes is not None else 0
    record.actual_start = body.actual_start
    record.actual_end = body.actual_end
    record.updated_by_id = user.id
    return record


@app.put("/api/v1/attendance/{day}/{employee_id}", response_model=AttendanceRecordOut)
async def set_attendance(
    day: date, employee_id: uuid.UUID, body: AttendanceRecordIn,
    user: User = Depends(require_permission("editAttendance")),
    session: AsyncSession = Depends(get_session),
) -> AttendanceRecord:
    await lock_attendance_day(session, day)
    record = await save_attendance_record(session, user, day, employee_id, body)
    await audit(session, actor=user, action="set_fact", entity_type="attendance", entity_id=f"{day}:{employee_id}")
    await session.commit()
    await session.refresh(record)
    return record


@app.put("/api/v1/attendance/{day}", status_code=204)
async def set_attendance_bulk(
    day: date, body: AttendanceBulkIn,
    user: User = Depends(require_permission("editAttendance")),
    session: AsyncSession = Depends(get_session),
) -> Response:
    ids = {item.employee_id for item in body.records}
    if len(ids) != len(body.records):
        raise api_error(422, "Сотрудник указан несколько раз")
    await lock_attendance_day(session, day)
    snapshots = await attendance_employees(session, user, day, ids)
    for item in body.records:
        await save_attendance_record(session, user, day, item.employee_id, item, snapshots[item.employee_id])
    await audit(session, actor=user, action="set_fact_bulk", entity_type="attendance_day",
                entity_id=str(day), details={"records": len(ids)})
    await session.commit()
    return Response(status_code=204)


@app.post("/api/v1/attendance/{day}/close", status_code=204)
async def close_attendance_day(
    day: date, body: AttendanceCloseIn,
    user: User = Depends(require_permission("editAttendance")),
    session: AsyncSession = Depends(get_session),
) -> Response:
    ids = set(body.planned_employee_ids)
    await lock_attendance_day(session, day)
    snapshots = await attendance_employees(session, user, day, ids)
    for employee_id in ids:
        if await session.get(AttendanceLock, (day, employee_id)) is not None:
            continue
        record = await session.get(AttendanceRecord, (day, employee_id))
        if record is None or record.fact == FactStatus.none:
            await save_attendance_record(session, user, day, employee_id,
                                         AttendanceRecordIn(fact=FactStatus.absent, worked_minutes=0),
                                         snapshots[employee_id])
        session.add(AttendanceLock(day=day, employee_id=employee_id, closed_by_id=user.id))
    await audit(session, actor=user, action="close", entity_type="attendance_day",
                entity_id=str(day), details={"employee_ids": sorted(map(str, ids))})
    await session.commit()
    return Response(status_code=204)


@app.post("/api/v1/attendance/{day}/reopen", status_code=204)
async def reopen_attendance_day(
    day: date, body: AttendanceReopenIn | None = None,
    user: User = Depends(require_permission("editAttendance")),
    session: AsyncSession = Depends(get_session),
) -> Response:
    await lock_attendance_day(session, day)
    allowed_ids = set(await attendance_employees(session, user, day))
    ids = set(body.employee_ids) if body and body.employee_ids is not None else allowed_ids
    if not ids <= allowed_ids:
        raise api_error(404, "Один из сотрудников не найден")
    await session.execute(delete(AttendanceLock).where(
        AttendanceLock.day == day, AttendanceLock.employee_id.in_(ids)))
    await audit(session, actor=user, action="reopen", entity_type="attendance_day",
                entity_id=str(day), details={"employee_ids": sorted(map(str, ids))})
    await session.commit()
    return Response(status_code=204)


@app.get("/api/v1/attendance/{day}", response_model=list[AttendanceRecordOut])
async def attendance(
    day: date,
    user: User = Depends(require_permission("viewAttendance")),
    session: AsyncSession = Depends(get_session),
) -> list[AttendanceRecord]:
    scope = await attendance_scope(session, user, day)
    allowed = {employee_id for employee_id in scope.candidates if scope.snapshot(employee_id, day)}
    query = (
        select(AttendanceRecord)
        .where(AttendanceRecord.day == day, AttendanceRecord.employee_id.in_(allowed))
        .order_by(AttendanceRecord.employee_id)
    )
    return list((await session.scalars(query)).all())


@app.get("/api/v1/reports/month")
async def get_month_report(
    year: int, month: int,
    department_id: uuid.UUID | None = None, group_id: uuid.UUID | None = None,
    user: User = Depends(require_permission("viewAttendance")),
    session: AsyncSession = Depends(get_session),
) -> dict:
    if not has_permission(user, "viewEmployees"):
        raise api_error(403, "Недостаточно прав для просмотра табеля")
    hidden = set(map(str, await admin_hidden_group_ids(session, user.id)))
    return await month_report(session, user, year, month, hidden, department_id, group_id)


@app.get("/api/v1/reports/month.xlsx")
async def export_month_report(
    year: int, month: int,
    department_id: uuid.UUID | None = None, group_id: uuid.UUID | None = None,
    user: User = Depends(require_permission("viewAttendance")),
    session: AsyncSession = Depends(get_session),
) -> Response:
    report = await get_month_report(year, month, department_id, group_id, user, session)
    if not report["rows"]:
        raise api_error(404, "Нет сотрудников за выбранный месяц")
    from starlette.concurrency import run_in_threadpool
    content = await run_in_threadpool(make_timesheet, report)
    return Response(content, media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    headers={"Content-Disposition": f'attachment; filename="timesheet-{year}-{month:02d}.xlsx"',
                             "Cache-Control": "no-store"})


from .import_routes import register_import_routes
register_import_routes(app)
from .telegram_delivery import register_delivery_routes
register_delivery_routes(app)
from .hour_requests import register_hour_request_routes
register_hour_request_routes(app)
