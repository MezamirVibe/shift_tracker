"""Operator-only interactive first administrator creation inside the API container."""
import argparse
import asyncio
from getpass import getpass
from sqlalchemy import func, select
from .config import get_settings
from .database import SessionFactory, engine
from .models import AuditEvent, OrganizationIdentity, Role, User
from .schemas import BootstrapIn
from .security import hash_password


async def provision(body: BootstrapIn):
    try:
        async with SessionFactory() as session:
            async with session.begin():
                # Shared role-row lock also serializes the HTTP bootstrap endpoint.
                role = await session.scalar(select(Role).where(Role.id == 'super_admin').with_for_update())
                identity = await session.get(OrganizationIdentity, 1)
                if role is None or identity is None or identity.code != get_settings().ORGANIZATION_CODE:
                    raise RuntimeError('Start and verify the organization API before provisioning')
                if await session.scalar(select(func.count()).select_from(User)):
                    raise RuntimeError('Organization already has users; refusing to replace credentials')
                session.add(User(login=body.login.strip().lower(), password_hash=hash_password(body.password),
                                 role_id=role.id, first_name=body.login.strip()))
                session.add(AuditEvent(action='operator_bootstrap', entity_type='user'))
        print('Administrator created. No tokens or passwords are printed.')
    finally:
        await engine.dispose()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--login', required=True)
    args = parser.parse_args()
    password = getpass('Administrator password (minimum 10 characters): ')
    if password != getpass('Repeat password: '):
        raise SystemExit('Passwords do not match')
    asyncio.run(provision(BootstrapIn(login=args.login, password=password)))
