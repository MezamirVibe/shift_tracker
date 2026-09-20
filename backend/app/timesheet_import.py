"""Bounded, read-only OOXML reader. Never executes formulas or extracts archives.

Only names, positions, department labels and daily marks are read. Monetary
columns, totals and cached formula results are deliberately not imported.
"""
from calendar import monthrange
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from io import BytesIO
import posixpath
import re
from zipfile import BadZipFile, ZipFile
from defusedxml import ElementTree as ET
from defusedxml.common import DefusedXmlException

from .timesheet_xlsx import NS, column

MAX_FILE_BYTES = 3 * 1024 * 1024
MAX_UNCOMPRESSED = 24 * 1024 * 1024
MAX_ROWS = 500
TAG = f"{{{NS}}}"
REL = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"


def normalized(value: str) -> str:
    return " ".join(value.strip().casefold().replace("ё", "е").split())


@dataclass(frozen=True)
class Formula:
    pass


def parse_mark(value) -> dict | None:
    if value is None or str(value).strip() in {"", "-", "—"}:
        return None
    if isinstance(value, Formula):
        raise ValueError("Формула в отметке: замените её вычисленным значением")
    text = re.sub(r"\s+", "", str(value)).casefold().replace(",", ".")
    marks = {"к": "businessTrip", "о": "vacation", "от": "vacation",
             "б": "sick", "н": "absent", "нн": "absent",
             "б/с": "unpaid", "бс": "unpaid", "в": "worked"}
    if text in marks:
        return {"fact": marks[text], "worked_minutes": 0}
    match = re.fullmatch(r"(о)?(\d+(?:\.\d{1,6})?)(к)?", text)
    if not match or (match[1] and match[3]):
        raise ValueError("Неизвестная отметка; используйте часы, К, 11к, О, о 11, Б, Н или б/с")
    try:
        hours = Decimal(match[2])
        if not hours.is_finite() or hours > 24:
            raise ValueError("В одном дне не может быть больше 24 часов")
        minutes = int((hours * 60).quantize(Decimal(1), rounding=ROUND_HALF_UP))
    except InvalidOperation as error:
        raise ValueError("Некорректное число часов") from error
    if match[1] and minutes == 0:
        raise ValueError("Для работы в отпуске нужны положительные часы")
    return {"fact": "vacationWorked" if match[1] else "businessTrip" if match[3] else "worked",
            "worked_minutes": minutes}


def read_timesheet(content: bytes, year: int, month: int, sheet_name: str | None = None) -> dict:
    if not 2000 <= year <= 2100 or not 1 <= month <= 12:
        raise ValueError("Выберите год и месяц табеля")
    if len(content) > MAX_FILE_BYTES:
        raise ValueError("Файл должен быть не больше 3 МБ")
    try:
        with ZipFile(BytesIO(content)) as archive:
            info = archive.infolist()
            if (len(info) > 200 or len({x.filename for x in info}) != len(info)
                    or sum(x.file_size for x in info) > MAX_UNCOMPRESSED
                    or any(x.flag_bits & 1 for x in info)):
                raise ValueError("Слишком большой или защищённый файл Excel")
            if any("vbaProject" in x.filename for x in info):
                raise ValueError("Файлы с макросами не поддерживаются; сохраните копию .xlsx")

            def xml(path):
                return ET.fromstring(archive.read(path))

            workbook = xml("xl/workbook.xml")
            sheets = list(workbook.find(f"{TAG}sheets"))
            names = [sheet.get("name") for sheet in sheets]
            if sheet_name is None and len(sheets) != 1:
                return {"sheets": names, "needs_sheet": True, "rows": [], "errors": []}
            selected = next((sheet for sheet in sheets if sheet_name is None or sheet.get("name") == sheet_name), None)
            if selected is None:
                raise ValueError("Выбранный лист не найден")
            relationships = xml("xl/_rels/workbook.xml.rels")
            link = next((r for r in relationships if r.get("Id") == selected.get(REL)), None)
            if link is None or link.get("TargetMode") == "External":
                raise ValueError("Некорректный лист Excel")
            target = link.get("Target", "")
            path = posixpath.normpath(target.lstrip("/") if target.startswith("/") else "xl/" + target)
            if not path.startswith("xl/worksheets/") or ".." in path:
                raise ValueError("Некорректная ссылка на лист")
            strings = []
            if "xl/sharedStrings.xml" in archive.namelist():
                strings = ["".join(e.itertext()) for e in xml("xl/sharedStrings.xml")]
            sheet = xml(path)
            data = sheet.find(f"{TAG}sheetData")
            if data is None or len(data) > 2000:
                raise ValueError("Лист пустой или слишком большой (до 500 сотрудников)")
            rows = []
            for row in data:
                if len(row) > 256:
                    raise ValueError("Слишком много столбцов на листе")
                cells = {}
                for c in row:
                    address = c.get("r", "")
                    match = re.fullmatch(r"([A-Z]{1,3})([1-9]\d{0,6})", address)
                    if not match:
                        raise ValueError("Некорректный адрес ячейки")
                    col = 0
                    for char in match[1]:
                        col = col * 26 + ord(char) - 64
                    raw = c.findtext(f"{TAG}v")
                    if c.find(f"{TAG}f") is not None:
                        value = Formula()
                    elif c.get("t") == "s":
                        value = strings[int(raw)]
                    elif c.get("t") == "inlineStr":
                        value = "".join(c.find(f"{TAG}is").itertext())
                    else:
                        value = raw
                    cells[col] = value
                rows.append((int(row.get("r")), cells))
    except (BadZipFile, KeyError, IndexError, TypeError, AttributeError, ET.ParseError, DefusedXmlException) as error:
        raise ValueError("Не удалось прочитать .xlsx. Пересохраните файл в Excel") from error

    header_index = None
    for index, (_, cells) in enumerate(rows[:50]):
        labels = {col: normalized(str(value)) for col, value in cells.items()}
        name_col = next((col for col, label in labels.items() if label in {
            "фио", "ф.и.о.", "фамилия имя отчество", "сотрудник"}), None)
        if not name_col:
            continue
        first_day = next((col for col, value in cells.items() if col > name_col
                         and str(value) in {"1", "1.0"}
                         and all(str(cells.get(col + n)) in {str(n + 1), f"{n + 1}.0"} for n in range(28))), None)
        if first_day is not None:
            header_index = index
            break
    if header_index is None:
        raise ValueError("Не найдены заголовки ФИО и дней 1–28. Используйте табель с одной строкой на сотрудника")
    dep_col = next((col for col, label in labels.items() if label in {"отдел", "подразделение"}), None)
    pos_col = next((col for col, label in labels.items() if label == "должность"), None)
    days = monthrange(year, month)[1]
    if any(str(rows[header_index][1].get(first_day + d - 1)) not in {str(d), f"{d}.0"} for d in range(1, days + 1)):
        raise ValueError("Число дней в заголовке не соответствует выбранному месяцу")
    period = re.fullmatch(r"(\d{2})[.\-/](\d{4})", selected.get("name", "").strip())
    detected = {"year": int(period[2]), "month": int(period[1])} if period and 1 <= int(period[1]) <= 12 else None
    errors, employees = [], []
    seen = set()
    for row_number, cells in rows[header_index + 1:]:
        name = cells.get(name_col)
        if name is None or not str(name).strip():
            continue
        if isinstance(name, Formula):
            errors.append({"cell": f"{column(name_col)}{row_number}", "message": "ФИО должно быть текстом, а не формулой"})
            continue
        name = " ".join(str(name).split())
        if normalized(name).startswith(("итого", "всего")):
            continue
        if len(name) > 240 or len(name.split()) < 2:
            errors.append({"cell": f"{column(name_col)}{row_number}", "message": "Укажите полное ФИО (не менее двух слов, до 240 символов)"})
            continue
        key = normalized(name)
        if key in seen:
            errors.append({"cell": f"{column(name_col)}{row_number}", "message": "ФИО повторяется на листе; объедините строки или уточните имена"})
        seen.add(key)
        marks = []
        for d in range(1, 32):
            address = f"{column(first_day + d - 1)}{row_number}"
            value = cells.get(first_day + d - 1) if first_day + d - 1 <= first_day + 30 else None
            # For short-month files the next column is a total, not day 29/30/31.
            if str(rows[header_index][1].get(first_day + d - 1)) not in {str(d), f"{d}.0"}:
                continue
            try:
                mark = parse_mark(value)
                if mark is not None and d > days:
                    raise ValueError("Этого дня нет в выбранном месяце")
                if mark is not None:
                    marks.append({"day": d, **mark})
            except ValueError as error:
                errors.append({"cell": address, "message": str(error)})
        position = cells.get(pos_col) or ""
        department = cells.get(dep_col) or ""
        if isinstance(position, Formula) or len(str(position)) > 160:
            errors.append({"cell": f"{column(pos_col)}{row_number}", "message": "Должность должна быть текстом до 160 символов"})
            position = ""
        employees.append({"row": row_number, "full_name": name, "position": str(position).strip(),
                          "source_department": str(department)[:160], "marks": marks})
        if len(employees) > MAX_ROWS:
            raise ValueError("За один импорт можно добавить не больше 500 сотрудников")
    if not employees:
        raise ValueError("В столбце ФИО нет сотрудников. Выберите заполненный табель, а не пустой шаблон")
    return {"sheets": names, "sheet": selected.get("name"), "detected_period": detected,
            "rows": employees, "errors": errors[:100], "error_count": len(errors), "needs_sheet": False}
