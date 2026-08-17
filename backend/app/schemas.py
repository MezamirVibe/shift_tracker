import uuid
from datetime import date, datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .models import FactStatus, ScheduleType, ScopeKind


class ApiModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


class RoleOut(ApiModel):
    id: str
    name: str
    scope_kind: ScopeKind
    permissions: list[str]
    is_system: bool


class RoleIn(BaseModel):
    id: str = Field(pattern=r"^[a-z][a-z0-9_]{1,79}$")
    name: str = Field(min_length=1, max_length=120)
    scope_kind: ScopeKind
    permissions: list[str] = Field(default_factory=list)


class RoleUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    scope_kind: ScopeKind | None = None
    permissions: list[str] | None = None


class UserOut(ApiModel):
    id: uuid.UUID
    login: str
    role: RoleOut
    last_name: str
    first_name: str
    middle_name: str
    department_id: uuid.UUID | None
    group_id: uuid.UUID | None
    employee_id: uuid.UUID | None


class UserCreate(BaseModel):
    login: str = Field(min_length=3, max_length=120)
    password: str = Field(min_length=10, max_length=256)
    role_id: str
    last_name: str = Field(min_length=1, max_length=120)
    first_name: str = Field(min_length=1, max_length=120)
    middle_name: str = Field(default="", max_length=120)
    department_id: uuid.UUID | None = None
    group_id: uuid.UUID | None = None
    employee_id: uuid.UUID | None = None


class UserUpdate(BaseModel):
    role_id: str
    last_name: str = Field(min_length=1, max_length=120)
    first_name: str = Field(min_length=1, max_length=120)
    middle_name: str = Field(default="", max_length=120)
    department_id: uuid.UUID | None = None
    group_id: uuid.UUID | None = None
    employee_id: uuid.UUID | None = None
    is_active: bool = True


class PasswordResetOut(BaseModel):
    temporary_password: str


class BootstrapIn(BaseModel):
    login: str = Field(min_length=3, max_length=120)
    password: str = Field(min_length=10, max_length=256)


class LoginIn(BaseModel):
    login: str
    password: str


class RefreshIn(BaseModel):
    refresh_token: str


class PasswordChangeIn(BaseModel):
    current_password: str = Field(min_length=1, max_length=256)
    new_password: str = Field(min_length=10, max_length=256)


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int
    user: UserOut


class DepartmentIn(BaseModel):
    id: uuid.UUID | None = None
    name: str = Field(min_length=1, max_length=160)

    @field_validator("name")
    @classmethod
    def clean_name(cls, value: str) -> str:
        return value.strip()


class DepartmentOut(ApiModel):
    id: uuid.UUID
    name: str


class GroupIn(BaseModel):
    id: uuid.UUID | None = None
    department_id: uuid.UUID
    name: str = Field(min_length=1, max_length=160)


class GroupOut(ApiModel):
    id: uuid.UUID
    department_id: uuid.UUID
    name: str


class PositionIn(BaseModel):
    id: uuid.UUID | None = None
    name: str = Field(min_length=1, max_length=160)


class PositionOut(ApiModel):
    id: uuid.UUID
    name: str


class EmployeeIn(BaseModel):
    id: uuid.UUID | None = None
    full_name: str = Field(min_length=1, max_length=240)
    position_id: uuid.UUID | None = None
    department_id: uuid.UUID | None = None
    group_id: uuid.UUID | None = None
    salary: int = Field(default=0, ge=0)
    bonus: int = Field(default=0, ge=0)
    schedule_type: ScheduleType = ScheduleType.twoTwo
    schedule_start_date: date
    shift_hours: int = Field(default=12, ge=1, le=24)
    break_hours: int = Field(default=1, ge=0, le=23)


class EmployeeOut(EmployeeIn):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    is_active: bool
    created_at: datetime
    updated_at: datetime


class EmployeeUpdate(BaseModel):
    full_name: str | None = Field(default=None, min_length=1, max_length=240)
    position_id: uuid.UUID | None = None
    department_id: uuid.UUID | None = None
    group_id: uuid.UUID | None = None
    salary: int | None = Field(default=None, ge=0)
    bonus: int | None = Field(default=None, ge=0)
    schedule_type: ScheduleType | None = None
    schedule_start_date: date | None = None
    shift_hours: int | None = Field(default=None, ge=1, le=24)
    break_hours: int | None = Field(default=None, ge=0, le=23)
    is_active: bool | None = None


class AttendanceRecordIn(BaseModel):
    fact: FactStatus
    comment: str | None = Field(default=None, max_length=4000)
    worked_minutes: int | None = Field(default=None, ge=0, le=1440)


class AttendanceRecordOut(AttendanceRecordIn, ApiModel):
    day: date
    employee_id: uuid.UUID
    updated_at: datetime


class AttendanceCloseIn(BaseModel):
    planned_employee_ids: list[uuid.UUID] = Field(default_factory=list)
