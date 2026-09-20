from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=None, case_sensitive=True)

    DATABASE_URL: str
    JWT_SECRET: str = Field(min_length=32)
    BOOTSTRAP_TOKEN: str = Field(min_length=32)
    ACCESS_TOKEN_MINUTES: int = 15
    REFRESH_TOKEN_DAYS: int = 30
    CORS_ORIGINS: str = ""
    ORGANIZATION_CODE: str = Field(default="tehnodor-sk", pattern=r"^[a-z0-9][a-z0-9-]{1,47}$")
    ORGANIZATION_NAME: str = Field(default='ООО «Технодор СК»', min_length=1, max_length=200)
    TELEGRAM_BOT_TOKEN: str = ""
    TELEGRAM_BOT_USERNAME: str = Field(default="", pattern=r"^$|^[A-Za-z0-9_]{5,32}$")

    @property
    def cors_origins(self) -> list[str]:
        return [value.strip() for value in self.CORS_ORIGINS.split(",") if value.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
