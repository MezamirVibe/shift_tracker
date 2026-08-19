import uuid
from datetime import date, datetime, time

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

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


class UserPreferencesIn(BaseModel):
    settings: dict = Field(default_factory=dict)


class UserPreferencesOut(ApiModel):
    settings: dict
    updated_at: datetime | None = None


class UserHiddenGroupsIn(BaseModel):
    hidden_group_ids: list[uuid.UUID] = Field(default_factory=list, max_length=500)


class UserHiddenGroupsOut(BaseModel):
    hidden_group_ids: list[uuid.UUID] = Field(default_factory=list)


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
    custom_workdays: list[int] = Field(
        default_factory=lambda: [1, 2, 3, 4, 5], min_length=1, max_length=7
    )

    @field_validator("custom_workdays")
    @classmethod
    def validate_custom_workdays(cls, value: list[int]) -> list[int]:
        normalized = sorted(set(value))
        if any(day < 1 or day > 7 for day in normalized):
            raise ValueError("Дни недели должны быть в диапазоне от 1 до 7")
        return normalized


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
    custom_workdays: list[int] | None = Field(default=None, min_length=1, max_length=7)
    is_active: bool | None = None

    @field_validator("custom_workdays")
    @classmethod
    def validate_custom_workdays(cls, value: list[int] | None) -> list[int] | None:
        if value is None:
            return None
        normalized = sorted(set(value))
        if any(day < 1 or day > 7 for day in normalized):
            raise ValueError("Дни недели должны быть в диапазоне от 1 до 7")
        return normalized


class AttendanceRecordIn(BaseModel):
    fact: FactStatus
    comment: str | None = Field(default=None, max_length=4000)
    worked_minutes: int | None = Field(default=None, ge=0, le=1440)
    actual_start: time | None = None
    actual_end: time | None = None

    @model_validator(mode="after")
    def validate_actual_times(self) -> "AttendanceRecordIn":
        if (self.actual_start is None) != (self.actual_end is None):
            raise ValueError("Нужно указать и начало, и окончание работы")
        if self.fact != FactStatus.worked and self.actual_start is not None:
            raise ValueError("Фактическое время доступно только для выхода на смену")
        return self


class AttendanceRecordOut(AttendanceRecordIn, ApiModel):
    day: date
    employee_id: uuid.UUID
    updated_at: datetime


class AttendanceBulkItem(AttendanceRecordIn):
    employee_id: uuid.UUID


class AttendanceBulkIn(BaseModel):
    records: list[AttendanceBulkItem] = Field(min_length=1, max_length=500)


class AttendanceCloseIn(BaseModel):
    planned_employee_ids: list[uuid.UUID] = Field(default_factory=list)
