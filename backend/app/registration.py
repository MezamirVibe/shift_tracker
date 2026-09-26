"""Public signup queue plus private CLI consumed by the host provisioner.

Public HTTP has no Docker privileges and can never select an existing tenant code.
"""
import asyncio
from datetime import timedelta
import hashlib
import hmac
import json
import re
import secrets
import sys
import uuid

from fastapi import Depends, HTTPException, Request
from pydantic import BaseModel, Field, SecretStr, field_validator
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .database import SessionFactory, engine, get_session
from .models import OrganizationRegistration as Job, User, Employee, Department, utcnow
from .security import hash_password


class Ticket(BaseModel):
    request_id: uuid.UUID
    claim_secret: str = Field(pattern=r'^[a-f0-9]{64}$')


class Signup(Ticket):
    name: str = Field(min_length=2, max_length=200)
    login: str = Field(min_length=3, max_length=80, pattern=r'^[a-zA-Z0-9_.-]+$')
    password: SecretStr = Field(min_length=12, max_length=128)

    @field_validator('name')
    @classmethod
    def safe_name(cls, value):
        value = value.strip()
        if len(value) < 2 or any(ord(c) < 32 or c in "$'\\" for c in value):
            raise ValueError('Название не должно содержать служебные символы')
        return value


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def result(job):
    return {'request_id': str(job.id), 'status': job.status, 'code': job.code, 'name': job.name,
            'login': job.owner_login}


async def lock_queue(session):
    if session.bind.dialect.name == 'postgresql':
        await session.execute(text('SELECT pg_advisory_xact_lock(193701, 5)'))


def register_routes(app):
    def enabled():
        if not get_settings().PUBLIC_REGISTRATION:
            raise HTTPException(503, 'Создание организаций временно недоступно. Попробуйте позже.')

    @app.post('/api/v1/registration', status_code=202)
    async def signup(body: Signup, request: Request, session: AsyncSession = Depends(get_session)):
        enabled()
        await lock_queue(session)
        existing = await session.get(Job, body.request_id)
        if existing:
            if not hmac.compare_digest(existing.secret_hash, digest(body.claim_secret)):
                raise HTTPException(409, 'Повторите регистрацию с новой заявкой')
            return result(existing)
        settings = get_settings()
        total = await session.scalar(select(func.count()).select_from(Job))
        if total >= settings.REGISTRATION_MAX_ORGANIZATIONS:
            raise HTTPException(503, 'Свободные места на сервере закончились. Попробуйте зарегистрироваться позже.')
        source = request.client.host if request.client else 'unknown'
        source_hash = hmac.new(settings.JWT_SECRET.encode(), source.encode(), hashlib.sha256).hexdigest()
        recent = await session.scalar(select(func.count()).select_from(Job).where(
            Job.source_hash == source_hash, Job.created_at >= utcnow() - timedelta(days=1)))
        if recent >= settings.REGISTRATION_PER_IP_DAY:
            raise HTTPException(429, 'С этого подключения уже созданы организации. Повторите через сутки.')
        job = Job(id=body.request_id, secret_hash=digest(body.claim_secret),
                  code='org-' + secrets.token_hex(8), name=body.name,
                  owner_login=body.login.lower(), source_hash=source_hash,
                  password_hash=await asyncio.to_thread(hash_password, body.password.get_secret_value()))
        session.add(job)
        await session.commit()
        return result(job)

    @app.post('/api/v1/registration/status')
    async def signup_status(body: Ticket, session: AsyncSession = Depends(get_session)):
        enabled()
        job = await session.get(Job, body.request_id)
        if job is None or not hmac.compare_digest(job.secret_hash, digest(body.claim_secret)):
            raise HTTPException(404, 'Регистрация не найдена')
        return result(job)


async def command(action, data):
    """No HTTP route exposes these commands. Inputs and outputs must not be logged."""
    settings = get_settings()
    async with SessionFactory() as session:
        async with session.begin():
            if action == 'install-owner':
                assert not settings.PUBLIC_REGISTRATION
                assert settings.ORGANIZATION_CODE == data['code']
                owner_id = uuid.UUID(data['request_id'])
                existing = await session.get(User, owner_id)
                if existing:
                    assert existing.role_id == 'super_admin' and existing.login == data['login']
                    return {'installed': True}
                assert await session.scalar(select(func.count()).select_from(User)) == 0
                assert await session.scalar(select(func.count()).select_from(Employee)) == 0
                assert await session.scalar(select(func.count()).select_from(Department)) == 0
                assert data['password_hash'].startswith('$argon2id$')
                session.add(User(id=owner_id, login=data['login'], password_hash=data['password_hash'], role_id='super_admin'))
                return {'installed': True}
            assert settings.PUBLIC_REGISTRATION
            await lock_queue(session)
            if action == 'claim':
                job = await session.scalar(select(Job).where(
                    (Job.status == 'pending') | ((Job.status == 'provisioning') &
                    (Job.updated_at < utcnow() - timedelta(minutes=10)))
                ).order_by(Job.created_at).with_for_update().limit(1))
                if not job:
                    return None
                if job.attempts >= 3:
                    job.status, job.password_hash = 'failed', None
                    return None
                job.attempts += 1
                job.status, job.updated_at = 'provisioning', utcnow()
                return {**result(job), 'password_hash': job.password_hash}
            job = await session.get(Job, uuid.UUID(data['request_id']), with_for_update=True)
            assert job and job.status == 'provisioning'
            assert data['code'] == job.code
            if action == 'ready':
                job.status, job.password_hash = 'ready', None
            elif action == 'failed':
                job.status, job.password_hash = 'failed', None
            else:
                raise ValueError('Unknown private command')
            job.updated_at = utcnow()
            return {'status': job.status}


async def cli():
    data = json.loads(sys.stdin.read() or '{}')
    try:
        print(json.dumps(await command(sys.argv[1], data)))
    finally:
        await engine.dispose()


if __name__ == '__main__':
    asyncio.run(cli())
