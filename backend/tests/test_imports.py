import base64
from copy import deepcopy
from datetime import date
from io import BytesIO
from pathlib import Path
import unittest
from xml.etree import ElementTree as ET
from zipfile import ZipFile, ZIP_DEFLATED

import test_timesheets as fixtures
from app.models import AttendanceRecord, Employee, FactStatus
from app.timesheet_import import parse_mark, read_timesheet
from app.timesheet_xlsx import make_timesheet, NS
from sqlalchemy import select, func


def fixture_file(name='Новый Иван Иванович', mark='11к'):
    fact = parse_mark(mark)
    entry = {'value': mark, 'fact': fact['fact'], 'minutes': fact['worked_minutes'], 'planned': True, 'missing': False}
    row = {'full_name': name, 'department': 'Старый отдел', 'position': 'Контролёр', 'days': [entry] + [None] * 30,
        'notes': [], 'missing_days': 0, 'open_days': 0, 'total_minutes': fact['worked_minutes']}
    return make_timesheet({'year': 2026, 'month': 8, 'days_in_month': 31, 'rows': [row], 'total_minutes': fact['worked_minutes']})


def mutate_xml(content, path, change):
    result = BytesIO()
    with ZipFile(BytesIO(content)) as source, ZipFile(result, 'w', ZIP_DEFLATED) as target:
        for name in source.namelist():
            data = source.read(name)
            target.writestr(name, change(data) if name == path else data)
    return result.getvalue()


class ImportParserTests(unittest.TestCase):
    def test_all_marks(self):
        for text, fact, minutes in [('11к','businessTrip',660),('о 11','vacationWorked',660),
                ('Б/С','unpaid',0),('бс','unpaid',0),('К','businessTrip',0),('О','vacation',0),
                ('Б','sick',0),('Н','absent',0),('8,5','worked',510),('0','worked',0),('В','worked',0),
                ('7.3333','worked',440)]:
            self.assertEqual(parse_mark(text), {'fact': fact, 'worked_minutes': minutes})
        for value in ('25', '-1', 'NaN', '=11', 'о0', '11hours', '1e3'):
            with self.assertRaises(ValueError): parse_mark(value)
        self.assertIsNone(parse_mark(''))

    def test_export_round_trip_structure_and_only_daily_marks(self):
        parsed = read_timesheet(fixture_file(), 2026, 8)
        self.assertEqual(parsed['errors'], [])
        self.assertEqual(parsed['detected_period'], {'year': 2026, 'month': 8})
        self.assertEqual(len(parsed['rows']), 1)
        self.assertEqual(parsed['rows'][0]['marks'], [{'day': 1, 'fact': 'businessTrip', 'worked_minutes': 660}])

    def test_formulas_are_not_executed_or_trusted(self):
        def formula(data):
            root = ET.fromstring(data)
            cell = root.find(f'.//{{{NS}}}c[@r="J2"]')
            cell.clear(); cell.set('r','J2')
            ET.SubElement(cell, f'{{{NS}}}f').text = 'WEBSERVICE("https://not-accessed.invalid/")'
            ET.SubElement(cell, f'{{{NS}}}v').text = '11'
            return ET.tostring(root)
        content = mutate_xml(fixture_file(), 'xl/worksheets/sheet1.xml', formula)
        result = read_timesheet(content, 2026, 8)
        self.assertEqual(result['error_count'], 1)
        self.assertIn('Формула', result['errors'][0]['message'])

    def test_xml_entities_and_invalid_zip_rejected(self):
        content = mutate_xml(fixture_file(), 'xl/workbook.xml', lambda _: b'<!DOCTYPE x [<!ENTITY a "secret">]><x>&a;</x>')
        for value in (content, b'not a workbook', b'X' * (3 * 1024 * 1024 + 1)):
            with self.assertRaises(ValueError): read_timesheet(value, 2026, 8)

    def test_duplicate_names_blocked(self):
        def duplicate(data):
            root = ET.fromstring(data)
            rows = root.find(f'{{{NS}}}sheetData')
            row = deepcopy(rows[1]); row.set('r', '4')
            for c in row: c.set('r', c.get('r').replace('2', '4'))
            rows.append(row)
            return ET.tostring(root)
        result = read_timesheet(mutate_xml(fixture_file(), 'xl/worksheets/sheet1.xml', duplicate), 2026, 8)
        self.assertGreater(result['error_count'], 0)


class ImportApiTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.t = fixtures.TimesheetTests('test_mixed_marks_and_unplanned_shifts_are_counted')
        await self.t.asyncSetUp()
        self.body = {'file_base64': base64.b64encode(fixture_file()).decode(), 'year': 2026, 'month': 8,
                     'department_id': str(self.t.dep_a.id), 'shift_hours': 9, 'break_hours': 1}

    async def asyncTearDown(self):
        await self.t.asyncTearDown()

    async def preview(self):
        response = await self.t.client.post('/api/v1/imports/timesheet/preview', json=self.body)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    async def commit(self, preview):
        return await self.t.client.post('/api/v1/imports/timesheet/commit', json={**self.body,
            'sheet': preview['sheet'], 'preview_token': preview['preview_token'], 'selected_rows': [2]})

    async def test_preview_is_readonly_commit_is_idempotent_and_scoped(self):
        preview = await self.preview()
        self.assertEqual(preview['rows'][0]['action'], 'create')
        async with self.t.sessions() as session:
            self.assertEqual(await session.scalar(select(func.count()).select_from(Employee)), 2)
        committed = await self.commit(preview)
        self.assertEqual(committed.status_code, 200, committed.text)
        self.assertEqual(committed.json()['created_employees'], 1)
        self.assertEqual(committed.json()['written_marks'], 1)
        self.assertEqual((await self.commit(preview)).status_code, 409)
        repeat = await self.preview()
        self.assertEqual(repeat['rows'][0]['action'], 'match')
        self.assertEqual(repeat['rows'][0]['same_marks'], 1)
        async with self.t.sessions() as session:
            employee = await session.scalar(select(Employee).where(Employee.full_name == 'Новый Иван Иванович'))
            self.assertEqual(employee.department_id, self.t.dep_a.id)
            self.assertEqual(employee.salary, 0)

    async def test_old_marks_and_closed_days_never_overwritten(self):
        self.body['file_base64'] = base64.b64encode(fixture_file('Сотрудник А')).decode()
        self.assertEqual((await self.t.mark('2026-08-01', minutes=120)).status_code, 200)
        preview = await self.preview()
        self.assertEqual(preview['rows'][0]['conflicts'], 1)
        result = await self.commit(preview)
        self.assertEqual(result.status_code, 200, result.text)
        self.assertEqual(result.json()['written_marks'], 0)
        await self.t.client.post('/api/v1/attendance/2026-08-01/close', json={'planned_employee_ids':[str(self.t.a.id)]})
        preview = await self.preview()
        self.assertEqual(preview['rows'][0]['locked'], 1)

    async def test_concurrent_change_requires_new_preview(self):
        self.body['file_base64'] = base64.b64encode(fixture_file('Сотрудник А')).decode()
        preview = await self.preview()
        await self.t.mark('2026-08-01', minutes=120)
        self.assertEqual((await self.commit(preview)).status_code, 409)

    async def test_foreign_department_and_altered_input_blocked(self):
        preview = await self.preview()
        self.body['month'] = 7
        self.assertEqual((await self.commit(preview)).status_code, 409)
        self.body['department_id'] = str(self.t.dep_b.id)
        result = await self.t.client.post('/api/v1/imports/timesheet/preview', json=self.body)
        self.assertEqual(result.status_code, 404)

    async def test_wrong_month_disables_commit(self):
        self.body['month'] = 7
        preview = await self.preview()
        self.assertNotIn('preview_token', preview)
        self.assertGreater(preview['error_count'], 0)

    async def test_actor_and_auth_token_cannot_replace_preview(self):
        preview = await self.preview()
        self.t.actor.token_version += 1
        self.assertEqual((await self.commit(preview)).status_code, 409)
        preview['preview_token'] = 'not-a-token'
        self.assertEqual((await self.commit(preview)).status_code, 409)
