"""Fill the checked-in, data-free XLSX template without an Excel installation.

Only the worksheet and workbook metadata are replaced. All cells are explicitly
typed, so employee names and comments cannot become spreadsheet formulas.
"""
from copy import deepcopy
from io import BytesIO
from pathlib import Path
import re
from xml.etree import ElementTree as ET
from zipfile import ZIP_DEFLATED, ZipFile

NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
ET.register_namespace("", NS)
TEMPLATE = Path(__file__).with_name("assets") / "timesheet_template.xlsx"


def tag(name: str) -> str:
    return f"{{{NS}}}{name}"


def column(number: int) -> str:
    result = ""
    while number:
        number, remainder = divmod(number - 1, 26)
        result = chr(65 + remainder) + result
    return result


def cell(parent: ET.Element, address: str, style: str, value=None, formula: str | None = None):
    target = ET.SubElement(parent, tag("c"), {"r": address, "s": style})
    if formula is not None:
        ET.SubElement(target, tag("f")).text = formula
        ET.SubElement(target, tag("v")).text = str(value)
    elif isinstance(value, (int, float)):
        ET.SubElement(target, tag("v")).text = str(value)
    elif value is not None:
        target.set("t", "inlineStr")
        inline = ET.SubElement(target, tag("is"))
        # XML 1.0 disallows control characters; keep tabs, newlines and carriage returns.
        text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", str(value))[:32767]
        ET.SubElement(inline, tag("t"), {"{http://www.w3.org/XML/1998/namespace}space": "preserve"}).text = text
    return target


def make_timesheet(report: dict) -> bytes:
    if not report["rows"]:
        raise ValueError("Нет сотрудников для выгрузки")
    with ZipFile(TEMPLATE) as template:
        files = {name: template.read(name) for name in template.namelist()}
    sheet = ET.fromstring(files["xl/worksheets/sheet1.xml"])
    sheet_data = sheet.find(tag("sheetData"))
    source_rows = {int(row.get("r")): row for row in sheet_data}
    styles = {c.get("r"): c.get("s", "0") for row in sheet_data for c in row}
    header = deepcopy(source_rows[1])
    for child in list(sheet_data):
        sheet_data.remove(child)
    sheet_data.append(header)
    for c in header:
        if c.get("r") in {f"{column(9 + day)}1" for day in range(report["days_in_month"] + 1, 32)}:
            for child in list(c):
                c.remove(child)
            c.attrib.pop("t", None)
    for number, employee in enumerate(report["rows"], start=2):
        row = ET.SubElement(sheet_data, tag("row"), {"r": str(number), "ht": "32", "customHeight": "1"})
        notes = list(employee["notes"])
        if employee["missing_days"]:
            notes.append(f"Не заполнено плановых дней: {employee['missing_days']}")
        if employee["open_days"]:
            notes.append(f"Не закрыто дней: {employee['open_days']}")
        data = {1: number - 1, 2: employee["department"], 3: employee["full_name"],
                4: employee["position"], 54: "\n".join(notes) or None}
        total_formula = f"SUM(J{number}:AN{number})"
        for day, entry in enumerate(employee["days"], start=1):
            if entry is None:
                continue
            data[day + 9] = entry["value"]
            address = f"{column(day + 9)}{number}"
            # Only combined text marks need an additional term. NUMBERVALUE's
            # explicit decimal separator makes fractional hours locale-independent.
            if entry["fact"] == "businessTrip" and entry["minutes"]:
                total_formula += f'+_xlfn.NUMBERVALUE(SUBSTITUTE(LOWER({address}),"к",""),","," ")'
            elif entry["fact"] == "vacationWorked":
                total_formula += f'+_xlfn.NUMBERVALUE(SUBSTITUTE(LOWER({address}),"о",""),","," ")'
        for index in range(1, 58):
            col = column(index)
            style = styles.get(f"{col}2", "0")
            if 10 <= index <= 40:
                day_index = index - 10
                entry = employee["days"][day_index] if day_index < len(employee["days"]) else None
                if entry and entry["missing"]:
                    style = styles.get("J5", style)
                elif entry is None or not entry["planned"]:
                    style = styles.get("J4", style)
            if index == 41:
                # Marks display decimal hours; reconcile their finite precision to whole minutes.
                cell(row, f"AO{number}", style, employee["total_minutes"] / 60,
                     f"ROUND(({total_formula})*60,0)/60")
            else:
                cell(row, f"{col}{number}", style, data.get(index))
        # Keep notes readable without clipping ordinary employee rows.
        lines = sum(max(1, (len(note) + 39) // 40) for note in notes)
        row.set("ht", str(min(409, max(32, lines * 13))))
    last = len(report["rows"]) + 1
    total = last + 1
    row = ET.SubElement(sheet_data, tag("row"), {"r": str(total), "ht": "30", "customHeight": "1"})
    for index in range(1, 58):
        col = column(index)
        style = styles.get(f"{col}3", "0")
        if index == 1:
            cell(row, f"A{total}", style, "ИТОГО")
        elif 10 <= index <= 9 + report["days_in_month"]:
            address_range = f"{col}2:{col}{last}"
            count = sum((e["days"][index - 10] or {}).get("minutes", 0) > 0 for e in report["rows"])
            # Numeric hours plus combined text marks, excluding non-working codes.
            # Avoid wildcard matching so Excel and preview engines agree.
            formula = (f'COUNTIF({address_range},">0")+COUNTA({address_range})'
                       f'-COUNT({address_range})')
            for mark in ("К", "О", "Б", "Н", "б/с"):
                formula += f'-COUNTIF({address_range},"{mark}")'
            cell(row, f"{col}{total}", style, count, formula)
        elif index == 41:
            cell(row, f"AO{total}", style, report["total_minutes"] / 60, f"SUM(AO2:AO{last})")
        else:
            cell(row, f"{col}{total}", style)
    dimension = sheet.find(tag("dimension"))
    if dimension is None:
        dimension = ET.Element(tag("dimension"))
        sheet.insert(1 if sheet.find(tag("sheetPr")) is not None else 0, dimension)
    dimension.set("ref", f"A1:BE{total}")
    for name in ("autoFilter", "conditionalFormatting", "dataValidations", "extLst"):
        for element in list(sheet.findall(tag(name))):
            sheet.remove(element)
    # Keep all 57 columns in their original order, even for hours-only exports.
    workbook = ET.fromstring(files["xl/workbook.xml"])
    workbook.find(f"{tag('sheets')}/{tag('sheet')}").set("name", f"{report['month']:02d}.{report['year']}")
    calc = workbook.find(tag("calcPr"))
    if calc is None:
        calc = ET.SubElement(workbook, tag("calcPr"))
    calc.set("fullCalcOnLoad", "1")
    calc.set("calcMode", "auto")
    files["xl/worksheets/sheet1.xml"] = ET.tostring(sheet, encoding="utf-8", xml_declaration=True)
    files["xl/workbook.xml"] = ET.tostring(workbook, encoding="utf-8", xml_declaration=True)
    output = BytesIO()
    with ZipFile(output, "w", ZIP_DEFLATED) as archive:
        for name, content in files.items():
            archive.writestr(name, content)
    return output.getvalue()
