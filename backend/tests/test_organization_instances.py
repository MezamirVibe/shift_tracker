"""Real isolated API processes/databases. LOCAL TEST_POSTGRES_URL only."""
import asyncio
from datetime import date
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import unittest
import uuid

import httpx
from sqlalchemy import text
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import create_async_engine

TEST_URL = os.environ.get('TEST_POSTGRES_URL')
BACKEND = Path(__file__).resolve().parents[1]


@unittest.skipUnless(TEST_URL, 'Set LOCAL TEST_POSTGRES_URL for isolated API instances')
class OrganizationInstanceTests(unittest.IsolatedAsyncioTestCase):
    async def test_isolated_databases_with_identical_logins_and_entity_ids(self):
        url = make_url(TEST_URL)
        if url.host not in {'localhost', '127.0.0.1', '::1'}:
            raise RuntimeError('Only a local disposable PostgreSQL server is allowed')
        control = create_async_engine(url, isolation_level='AUTOCOMMIT')
        databases, processes, clients, logs = [], [], [], []
        # Intentionally use the same JWT key: audience must still prevent cross-org access.
        jwt_secret = secrets.token_hex(32)
        bootstrap_secret = secrets.token_hex(32)
        try:
            for code in ('company-a', 'company-b'):
                name = 'test_organization_' + uuid.uuid4().hex
                async with control.connect() as connection:
                    await connection.execute(text(f'CREATE DATABASE "{name}"'))
                databases.append(name)
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1', 0))
                    port = sock.getsockname()[1]
                env = {**os.environ, 'DATABASE_URL': url.set(database=name).render_as_string(hide_password=False),
                       'JWT_SECRET': jwt_secret, 'BOOTSTRAP_TOKEN': bootstrap_secret,
                       'ORGANIZATION_CODE': code, 'ORGANIZATION_NAME': 'Test ' + code}
                log = tempfile.TemporaryFile()
                logs.append(log)
                process = subprocess.Popen([sys.executable, '-m', 'uvicorn', 'app.main:app',
                    '--host', '127.0.0.1', '--port', str(port)], cwd=BACKEND, env=env,
                    stdout=log, stderr=log,
                    creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
                processes.append(process)
                client = httpx.AsyncClient(base_url=f'http://127.0.0.1:{port}', timeout=5)
                clients.append(client)
                for _ in range(150):
                    if process.poll() is not None:
                        self.fail('Isolated test API exited during startup')
                    try:
                        if (await client.get('/health')).status_code == 200:
                            break
                    except httpx.TransportError:
                        pass
                    await asyncio.sleep(0.1)
                else:
                    self.fail('Isolated test API startup timed out')

            tokens = []
            employee_id, department_id = str(uuid.uuid4()), str(uuid.uuid4())
            today = date.today()
            for n, client in enumerate(clients):
                code = ('company-a', 'company-b')[n]
                metadata = await client.get('/api/v1/organization')
                self.assertEqual(metadata.json()['code'], code)
                denied = await client.post('/api/v1/auth/bootstrap', json={'login': 'admin', 'password': 'password-only-for-tests'})
                self.assertEqual(denied.status_code, 403)
                response = await client.post('/api/v1/auth/bootstrap',
                    headers={'X-Bootstrap-Token': bootstrap_secret},
                    json={'login': 'admin', 'password': f'password-only-for-tests-{n}'})
                self.assertEqual(response.status_code, 200, response.text)
                tokens.append(response.json())
                client.headers.update({'Authorization': 'Bearer ' + tokens[n]['access_token'], 'X-Organization-Code': code})
                response = await client.post('/api/v1/departments', json={'id': department_id, 'name': 'ОТК'})
                self.assertEqual(response.status_code, 201, response.text)
                response = await client.post('/api/v1/employees', json={'id': employee_id,
                    'department_id': department_id, 'full_name': f'Employee {code}',
                    'schedule_start_date': today.isoformat(), 'schedule_type': 'fiveTwo'})
                self.assertEqual(response.status_code, 201, response.text)
                response = await client.put(f'/api/v1/attendance/{today}/{employee_id}',
                    json={'fact': 'worked', 'worked_minutes': 60 * (n + 1)})
                self.assertEqual(response.status_code, 200, response.text)
                response = await client.put('/api/v1/preferences', json={'settings': {'organization_test': code}})
                self.assertEqual(response.status_code, 200)

            for n, client in enumerate(clients):
                code = ('company-a', 'company-b')[n]
                foreign = tokens[1 - n]
                for path in ('/api/v1/employees', '/api/v1/users', '/api/v1/preferences',
                             f'/api/v1/reports/month?year={today.year}&month={today.month}'):
                    denied = await client.get(path, headers={'Authorization': 'Bearer ' + foreign['access_token']})
                    self.assertEqual(denied.status_code, 401, path)
                denied = await client.post('/api/v1/auth/refresh', json={'refresh_token': foreign['refresh_token']})
                self.assertEqual(denied.status_code, 401)
                denied = await client.get('/api/v1/employees', headers={'X-Organization-Code': ('company-b', 'company-a')[n]})
                self.assertEqual(denied.status_code, 404)
                people = (await client.get('/api/v1/employees')).json()
                self.assertEqual([e['full_name'] for e in people], [f'Employee {code}'])
                report = (await client.get(f'/api/v1/reports/month?year={today.year}&month={today.month}')).json()
                self.assertEqual(report['total_minutes'], 60 * (n + 1))
                prefs = (await client.get('/api/v1/preferences')).json()
                self.assertEqual(prefs['settings']['organization_test'], code)
                login = await client.post('/api/v1/auth/login', json={'login': 'admin', 'password': f'password-only-for-tests-{1 - n}'})
                self.assertEqual(login.status_code, 401)
        finally:
            for client in clients:
                await client.aclose()
            for process in processes:
                process.terminate()
                try:
                    await asyncio.to_thread(process.wait, 5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    await asyncio.to_thread(process.wait, 5)
            for log in logs:
                log.close()
            for name in databases:
                assert name.startswith('test_organization_') and len(name) == 50
                async with control.connect() as connection:
                    await connection.execute(text(f'DROP DATABASE "{name}"'))
            await control.dispose()
