"""Read-only smoke checks; execute inside the matching API container."""
import asyncio
from datetime import date, datetime, timedelta, timezone
from io import BytesIO
import json
import os
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from xml.etree import ElementTree as ET
from zipfile import ZipFile

import jwt
from sqlalchemy import func, select
from app.config import get_settings
from app.database import SessionFactory, engine
from app.models import AttendanceRecord, User


async def identity():
    settings = get_settings()
    async with SessionFactory() as session:
        user = await session.scalar(select(User).where(User.role_id == 'super_admin', User.is_active.is_(True)).limit(1))
        if user is None:
            raise RuntimeError('No active administrator for read-only smoke test')
        latest = await session.scalar(select(func.max(AttendanceRecord.day))) or date.today()
        now = datetime.now(timezone.utc)
        token = jwt.encode({'sub': str(user.id), 'ver': user.token_version, 'type': 'access',
            'aud': settings.ORGANIZATION_CODE, 'iat': now, 'exp': now + timedelta(seconds=90)},
            settings.JWT_SECRET, algorithm='HS256')
    await engine.dispose()
    return token, latest, settings.ORGANIZATION_CODE, settings.ORGANIZATION_NAME


token, month, code, name = asyncio.run(identity())
base = os.environ.get('SMOKE_BASE_URL', 'http://127.0.0.1:8000').rstrip('/')
gateway = os.environ.get('SMOKE_GATEWAY_URL')
if gateway:
    base = gateway.rstrip('/') + '/o/' + code


def fetch(path, authenticated=True, selected=code):
    headers = {'X-Organization-Code': selected}
    if authenticated:
        headers['Authorization'] = 'Bearer ' + token
    with urlopen(Request(base + path, headers=headers), timeout=30) as response:
        assert response.headers['X-Organization-Code'] == code
        return response.read(), response.headers


assert json.loads(fetch('/health', False)[0])['status'] == 'ok'
assert json.loads(fetch('/api/v1/organization', False)[0]) == {'code': code, 'name': name}
for path, authenticated, selected, expected in [
    ('/api/v1/employees', True, 'not-this-organization', 404),
    ('/api/v1/reports/month.xlsx?year=2026&month=8', False, code, 401),
]:
    try:
        fetch(path, authenticated, selected)
        raise AssertionError('Request should have been rejected')
    except HTTPError as error:
        assert error.code == expected, error.code

query = f'?year={month.year}&month={month.month}'
report = json.loads(fetch('/api/v1/reports/month' + query)[0])
assert report['financial_fields_included'] is False
assert report['total_minutes'] == sum(row['total_minutes'] for row in report['rows'])
content, headers = fetch('/api/v1/reports/month.xlsx' + query)
assert 'spreadsheetml.sheet' in headers['Content-Type']
ns = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
with ZipFile(BytesIO(content)) as archive:
    sheet = ET.fromstring(archive.read('xl/worksheets/sheet1.xml'))
    cells = {cell.get('r'): cell for cell in sheet.findall(f'.//{ns}c')}
    end = len(report['rows']) + 2
    if report['rows']:
        assert abs(float(cells[f'AO{end}'].find(f'{ns}v').text) * 60 - report['total_minutes']) < 1e-6
        assert cells[f'AO{end}'].find(f'{ns}f').text == f'SUM(AO2:AO{end - 1})'
    for row in range(2, end):
        for column in ('E', 'F', 'G', 'H', 'AP', 'AQ', 'AR', 'AT', 'AU', 'AV', 'AX', 'AY', 'AZ', 'BA', 'BE'):
            assert len(cells[f'{column}{row}']) == 0

employees = json.loads(fetch('/api/v1/employees')[0])
departments = json.loads(fetch('/api/v1/departments')[0])
if code == 'tehnodor-sk':
    assert len(employees) == 5 and all(e['is_active'] for e in employees)
    assert [d['name'] for d in departments] == ['ОТК']
if gateway:
    with urlopen(gateway.rstrip('/') + '/api/v1/organization', timeout=10) as response:
        assert json.loads(response.read())['code'] == code
    try:
        urlopen(gateway.rstrip('/') + '/o/unknown-code/api/v1/organization', timeout=10)
        raise AssertionError('Unknown organization fell through to default API')
    except HTTPError as error:
        assert error.code == 404
print(json.dumps({'result': 'ORGANIZATION_ROSTER_AND_EXPORT_OK', 'via': base,
    'organization': code, 'active_employees': len(employees), 'departments': len(departments),
    'report_rows': len(report['rows']), 'xlsx_bytes': len(content), 'historical_period': month.strftime('%Y-%m')}))
