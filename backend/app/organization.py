from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from .models import OrganizationIdentity


async def bind_database(session: AsyncSession, code: str) -> None:
    if session.bind.dialect.name == "postgresql":
        await session.execute(text("SELECT pg_advisory_xact_lock(193701, 2)"))
    identity = await session.scalar(select(OrganizationIdentity).where(OrganizationIdentity.id == 1))
    if identity is None:
        session.add(OrganizationIdentity(id=1, code=code))
    elif identity.code != code:
        raise RuntimeError("Database belongs to a different organization; refusing startup")
    await session.commit()
