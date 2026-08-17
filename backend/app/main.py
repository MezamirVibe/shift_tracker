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
from sqlalchemy import Select, and_, func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from .config import get_settings
from .database import SessionFactory, engine, get_session
from .models import (
    AttendanceDay,
    AttendanceRecord,
    AuditEvent,
    Base,
    Department,
    Employee,
    FactStatus,
    Group,
    Position,
    RefreshToken,
    Role,
    ScopeKind,
    User,
    utcnow,
)
from .schemas import (
    AttendanceRecordIn,
    AttendanceRecordOut,
    AttendanceCloseIn,
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
    UserOut,
    UserUpdate,
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


async def seed_roles(session: AsyncSession) -> None:
    for definition in DEFAULT_ROLES:
        if await session.get(Role, definition["id"]) is None:
            session.add(Role(**definition))
    await session.commit()


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    async with SessionFactory() as session:
        await seed_roles(session)
    yield
    await engine.dispose()


app = FastAPI(
    title="Shift Tracker API",
    version="0.1.0",
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
        allow_headers=["Authorization", "Content-Type", "X-Bootstrap-Token"],
    )


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


def scoped_employees(query: Select, user: User) -> Select:
    if is_super_admin(user) or user.role.scope_kind == ScopeKind.all:
        return query
    if user.role.scope_kind == ScopeKind.department:
        if user.department_id is None:
            return query.where(False)
        return query.where(Employee.department_id == user.department_id)
    if user.role.scope_kind == ScopeKind.group:
        if user.group_id is None:
            return query.where(False)
        return query.where(Employee.group_id == user.group_id)
    if user.employee_id is None:
        return query.where(False)
    return query.where(Employee.id == user.employee_id)


async def ensure_employee_in_scope(
    session: AsyncSession, user: User, employee_id: uuid.UUID
) -> Employee:
    employee = await session.scalar(
        scoped_employees(
            select(Employee).where(Employee.id == employee_id, Employee.is_active.is_(True)),
            user,
        )
    )
    if employee is None:
        raise api_error(status.HTTP_404_NOT_FOUND, "Сотрудник не найден")
    return employee


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
    if (await session.scalar(select(func.count()).select_from(User))) != 0:
        raise api_error(status.HTTP_409_CONFLICT, "Система уже инициализирована")

    role = await session.get(Role, "super_admin")
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
        user_query().where(func.lower(User.login) == body.login.strip().lower())
    )
    generic_error = api_error(status.HTTP_401_UNAUTHORIZED, "Неверный логин или пароль")
    if user is None or not user.is_active:
        raise generic_error

    now = utcnow()
    if user.locked_until is not None and user.locked_until > now:
        raise api_error(status.HTTP_429_TOO_MANY_REQUESTS, "Вход временно заблокирован")
    if user.locked_until is not None and user.locked_until <= now:
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
    await session.commit()
    return await issue_tokens(session, user)


@app.post("/api/v1/auth/refresh", response_model=TokenPair)
async def refresh(body: RefreshIn, session: AsyncSession = Depends(get_session)) -> TokenPair:
    try:
        token_id = uuid.UUID(body.refresh_token.split(".", 1)[0])
    except (ValueError, IndexError):
        raise api_error(status.HTTP_401_UNAUTHORIZED, "Недействительный refresh token") from None
    token = await session.get(RefreshToken, token_id)
    now = utcnow()
    if (
        token is None
        or token.revoked_at is not None
        or token.expires_at <= now
        or token.token_hash != hash_refresh_token(body.refresh_token)
    ):
        raise api_error(status.HTTP_401_UNAUTHORIZED, "Недействительный refresh token")
    token.revoked_at = now
    user = await load_user(session, token.user_id)
    if user is None or not user.is_active:
        await session.commit()
        raise api_error(status.HTTP_401_UNAUTHORIZED, "Пользователь отключён")
    await session.commit()
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


@app.post("/api/v1/auth/change-password", status_code=status.HTTP_204_NO_CONTENT)
async def change_password(
    body: PasswordChangeIn,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Response:
    if not verify_password(body.current_password, user.password_hash):
        raise api_error(status.HTTP_400_BAD_REQUEST, "Текущий пароль указан неверно")
    if body.current_password == body.new_password:
        raise api_error(status.HTTP_400_BAD_REQUEST, "Новый пароль должен отличаться")

    user.password_hash = hash_password(body.new_password)
    user.token_version += 1
    tokens = list(
        (
            await session.scalars(
                select(RefreshToken).where(
                    RefreshToken.user_id == user.id,
                    RefreshToken.revoked_at.is_(None),
                )
            )
        ).all()
    )
    now = utcnow()
    for token in tokens:
        token.revoked_at = now
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
    target = await load_user(session, user_id)
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
    target.token_version += 1
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
    target = await load_user(session, user_id)
    if target is None:
        raise api_error(status.HTTP_404_NOT_FOUND, "Пользователь не найден")
    password = generated_password()
    target.password_hash = hash_password(password)
    target.failed_login_attempts = 0
    target.locked_until = None
    target.token_version += 1
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
    target = await load_user(session, user_id)
    if target is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    if target.id == actor.id or target.role_id == "super_admin":
        raise api_error(status.HTTP_409_CONFLICT, "Суперадминистратора удалить нельзя")
    target.is_active = False
    target.token_version += 1
    await audit(session, actor=actor, action="deactivate", entity_type="user", entity_id=str(target.id))
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/api/v1/departments", response_model=list[DepartmentOut])
async def departments(
    _: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> list[Department]:
    return list((await session.scalars(select(Department).order_by(Department.name))).all())


@app.post("/api/v1/departments", response_model=DepartmentOut, status_code=201)
async def create_department(
    body: DepartmentIn,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Department:
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


@app.delete("/api/v1/departments/{department_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_department(
    department_id: uuid.UUID,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Response:
    item = await session.get(Department, department_id)
    if item is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    await audit(session, actor=user, action="delete", entity_type="department", entity_id=str(item.id))
    try:
        await session.delete(item)
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Подразделение используется") from None
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/api/v1/groups", response_model=list[GroupOut])
async def groups(
    department_id: uuid.UUID | None = None,
    _: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> list[Group]:
    query = select(Group).order_by(Group.name)
    if department_id is not None:
        query = query.where(Group.department_id == department_id)
    return list((await session.scalars(query)).all())


@app.post("/api/v1/groups", response_model=GroupOut, status_code=201)
async def create_group(
    body: GroupIn,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Group:
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
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Response:
    item = await session.get(Group, group_id)
    if item is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    await audit(session, actor=user, action="delete", entity_type="group", entity_id=str(item.id))
    try:
        await session.delete(item)
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise api_error(status.HTTP_409_CONFLICT, "Группа используется") from None
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
    user: User = Depends(require_permission("viewEmployees")),
    session: AsyncSession = Depends(get_session),
) -> list[Employee]:
    query = select(Employee).order_by(Employee.full_name)
    if not include_inactive:
        query = query.where(Employee.is_active.is_(True))
    query = scoped_employees(query, user)
    items = list((await session.scalars(query)).all())
    if not has_permission(user, "viewMoney") and not is_super_admin(user):
        for item in items:
            item.salary = 0
            item.bonus = 0
    return items


@app.post("/api/v1/employees", response_model=EmployeeOut, status_code=201)
async def create_employee(
    body: EmployeeIn,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Employee:
    await validate_employee_links(session, body)
    if user.role.scope_kind == ScopeKind.department and body.department_id != user.department_id:
        raise api_error(status.HTTP_403_FORBIDDEN, "Нельзя создавать сотрудника вне своего подразделения")
    if user.role.scope_kind == ScopeKind.group and body.group_id != user.group_id:
        raise api_error(status.HTTP_403_FORBIDDEN, "Нельзя создавать сотрудника вне своей группы")
    if user.role.scope_kind == ScopeKind.self and not is_super_admin(user):
        raise api_error(status.HTTP_403_FORBIDDEN, "Недостаточно области доступа")
    item = Employee(**body.model_dump(exclude_none=True))
    session.add(item)
    await audit(session, actor=user, action="create", entity_type="employee", entity_id=str(item.id))
    await session.commit()
    await session.refresh(item)
    return item


@app.patch("/api/v1/employees/{employee_id}", response_model=EmployeeOut)
async def update_employee(
    employee_id: uuid.UUID,
    body: EmployeeUpdate,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Employee:
    item = await ensure_employee_in_scope(session, user, employee_id)
    changes = body.model_dump(exclude_unset=True)
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
    )
    await validate_employee_links(session, candidate)
    if user.role.scope_kind == ScopeKind.department and candidate.department_id != user.department_id:
        raise api_error(status.HTTP_403_FORBIDDEN, "Нельзя переносить сотрудника вне своего подразделения")
    if user.role.scope_kind == ScopeKind.group and candidate.group_id != user.group_id:
        raise api_error(status.HTTP_403_FORBIDDEN, "Нельзя переносить сотрудника вне своей группы")
    for field, value in changes.items():
        setattr(item, field, value)
    await audit(session, actor=user, action="update", entity_type="employee", entity_id=str(item.id))
    await session.commit()
    await session.refresh(item)
    return item


@app.delete("/api/v1/employees/{employee_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_employee(
    employee_id: uuid.UUID,
    user: User = Depends(require_permission("editEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Response:
    item = await ensure_employee_in_scope(session, user, employee_id)
    linked_users = await session.scalar(
        select(func.count()).select_from(User).where(User.employee_id == item.id, User.is_active.is_(True))
    )
    if linked_users:
        raise api_error(status.HTTP_409_CONFLICT, "Сотрудник связан с активной учётной записью")
    item.is_active = False
    await audit(session, actor=user, action="deactivate", entity_type="employee", entity_id=str(item.id))
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/api/v1/employees/{employee_id}", response_model=EmployeeOut)
async def employee(
    employee_id: uuid.UUID,
    user: User = Depends(require_permission("viewEmployees")),
    session: AsyncSession = Depends(get_session),
) -> Employee:
    item = await ensure_employee_in_scope(session, user, employee_id)
    if not has_permission(user, "viewMoney") and not is_super_admin(user):
        item.salary = 0
        item.bonus = 0
    return item


@app.get("/api/v1/attendance")
async def attendance_range(
    date_from: date,
    date_to: date,
    user: User = Depends(require_permission("viewAttendance")),
    session: AsyncSession = Depends(get_session),
) -> dict[str, dict[str, object]]:
    if date_to < date_from or (date_to - date_from).days > 5000:
        raise api_error(status.HTTP_422_UNPROCESSABLE_ENTITY, "Недопустимый диапазон дат")
    allowed = scoped_employees(select(Employee.id), user).subquery()
    records = list(
        (
            await session.scalars(
                select(AttendanceRecord).where(
                    AttendanceRecord.day.between(date_from, date_to),
                    AttendanceRecord.employee_id.in_(select(allowed.c.id)),
                )
            )
        ).all()
    )
    days = list(
        (
            await session.scalars(
                select(AttendanceDay).where(AttendanceDay.day.between(date_from, date_to))
            )
        ).all()
    )
    result: dict[str, dict[str, object]] = {}
    for item in records:
        day_map = result.setdefault(item.day.isoformat(), {})
        day_map[str(item.employee_id)] = {
            "fact": item.fact.value,
            "comment": item.comment,
            "workedMinutes": item.worked_minutes,
            "updatedAt": item.updated_at.isoformat(),
        }
    for item in days:
        day_map = result.setdefault(item.day.isoformat(), {})
        day_map["_meta"] = {
            "closed": item.is_closed,
            "closedAt": item.closed_at.isoformat() if item.closed_at else None,
            "reopenedAt": item.reopened_at.isoformat() if item.reopened_at else None,
        }
    return result


@app.put("/api/v1/attendance/{day}/{employee_id}", response_model=AttendanceRecordOut)
async def set_attendance(
    day: date,
    employee_id: uuid.UUID,
    body: AttendanceRecordIn,
    user: User = Depends(require_permission("editAttendance")),
    session: AsyncSession = Depends(get_session),
) -> AttendanceRecord:
    await ensure_employee_in_scope(session, user, employee_id)
    attendance_day = await session.get(AttendanceDay, day)
    if attendance_day is None:
        attendance_day = AttendanceDay(day=day)
        session.add(attendance_day)
        await session.flush()
    if attendance_day.is_closed:
        raise api_error(status.HTTP_409_CONFLICT, "День закрыт")
    record = await session.get(AttendanceRecord, (day, employee_id))
    if record is None:
        record = AttendanceRecord(day=day, employee_id=employee_id)
        session.add(record)
    record.fact = body.fact
    record.comment = body.comment.strip() if body.comment else None
    record.worked_minutes = body.worked_minutes
    record.updated_by_id = user.id
    await audit(
        session,
        actor=user,
        action="set_fact",
        entity_type="attendance",
        entity_id=f"{day}:{employee_id}",
    )
    await session.commit()
    await session.refresh(record)
    return record


@app.post("/api/v1/attendance/{day}/close", status_code=status.HTTP_204_NO_CONTENT)
async def close_attendance_day(
    day: date,
    body: AttendanceCloseIn,
    user: User = Depends(require_permission("editAttendance")),
    session: AsyncSession = Depends(get_session),
) -> Response:
    attendance_day = await session.get(AttendanceDay, day)
    if attendance_day is None:
        attendance_day = AttendanceDay(day=day)
        session.add(attendance_day)
        await session.flush()
    if attendance_day.is_closed:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    for employee_id in set(body.planned_employee_ids):
        await ensure_employee_in_scope(session, user, employee_id)
        record = await session.get(AttendanceRecord, (day, employee_id))
        if record is None:
            record = AttendanceRecord(day=day, employee_id=employee_id)
            session.add(record)
        if record.fact.value == "none":
            record.fact = FactStatus.absent
            record.worked_minutes = 0
            record.updated_by_id = user.id
    attendance_day.is_closed = True
    attendance_day.closed_at = utcnow()
    attendance_day.closed_by_id = user.id
    await audit(session, actor=user, action="close", entity_type="attendance_day", entity_id=str(day))
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.post("/api/v1/attendance/{day}/reopen", status_code=status.HTTP_204_NO_CONTENT)
async def reopen_attendance_day(
    day: date,
    user: User = Depends(require_permission("editAttendance")),
    session: AsyncSession = Depends(get_session),
) -> Response:
    attendance_day = await session.get(AttendanceDay, day)
    if attendance_day is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    attendance_day.is_closed = False
    attendance_day.reopened_at = utcnow()
    await audit(session, actor=user, action="reopen", entity_type="attendance_day", entity_id=str(day))
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/api/v1/attendance/{day}", response_model=list[AttendanceRecordOut])
async def attendance(
    day: date,
    user: User = Depends(require_permission("viewAttendance")),
    session: AsyncSession = Depends(get_session),
) -> list[AttendanceRecord]:
    allowed = scoped_employees(select(Employee.id), user).subquery()
    query = (
        select(AttendanceRecord)
        .where(AttendanceRecord.day == day, AttendanceRecord.employee_id.in_(select(allowed.c.id)))
        .order_by(AttendanceRecord.employee_id)
    )
    return list((await session.scalars(query)).all())
