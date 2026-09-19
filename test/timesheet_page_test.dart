import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/app/theme.dart';
import 'package:shift_tracker/features/attendance/timesheet_page.dart';
import 'package:shift_tracker/features/attendance/timesheet_service.dart';
import 'package:shift_tracker/features/attendance/attendance_storage.dart';
import 'package:shift_tracker/core/api_client.dart';

Map<String, dynamic> report({int missing = 0, int open = 0}) => {
      'days_in_month': 31,
      'rows': [
        for (final department in ['А', 'Б'])
          {
            'employee_id': department,
            'full_name': 'Сотрудник $department',
            'department_id': department,
            'department': 'Отдел $department',
            'group_id': null,
            'group': 'Без группы',
            'position': '',
            'total_minutes': 1320,
            'missing_days': missing,
            'open_days': open,
            'days': List.generate(
                31,
                (i) => {
                      'date': '2026-08-${(i + 1).toString().padLeft(2, '0')}',
                      'value': i == 0
                          ? '11к'
                          : i == 1
                              ? 'о 11'
                              : i == 2
                                  ? 'б/с'
                                  : null,
                      'planned': true,
                      'missing': false,
                    }),
          }
      ],
    };

class FakeTimesheets extends TimesheetService {
  Map<String, dynamic> data = report();
  Object? loadError;
  Object? saveError;
  int saves = 0;
  String? savedDepartment;
  final requests = <int>[];
  Completer<Map<String, dynamic>>? delayed;

  @override
  Future<Map<String, dynamic>> load(int year, int month) async {
    requests.add(month);
    if (loadError != null) throw loadError!;
    if (delayed != null) return delayed!.future;
    return data;
  }

  @override
  Future<String?> save(
      {required int year,
      required int month,
      String? departmentId,
      String? groupId,
      required Rect shareOrigin}) async {
    saves++;
    savedDepartment = departmentId;
    if (saveError != null) throw saveError!;
    return 'Табель сохранён';
  }
}

Future<void> mount(WidgetTester tester, FakeTimesheets service,
    {Size size = const Size(1400, 900)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: MonthReportPage(year: 2026, month: 8, service: service)));
  await tester.pumpAndSettle();
}

void main() {
  test('mixed statuses and closed flags round-trip without losing hours', () {
    expect(
        const AttendanceRecord(fact: FactStatus.worked, workedMinutes: 0)
            .hasWorked,
        isFalse);
    for (final fact in [FactStatus.businessTrip, FactStatus.vacationWorked]) {
      final record = AttendanceRecord.fromJson(
          {'fact': fact.name, 'worked_minutes': 660, 'closed': true});
      expect(record.fact, fact);
      expect(record.hasWorked, isTrue);
      expect(AttendanceRecord.fromJson(record.toJson()).workedMinutes, 660);
      expect(AttendanceRecord.fromJson(record.toJson()).closed, isTrue);
    }
    expect(const AttendanceRecord(fact: FactStatus.businessTrip).hasWorked,
        isFalse);
    expect(const AttendanceRecord(fact: FactStatus.unpaid).hasWorked, isFalse);
  });

  testWidgets('desktop displays mixed marks and exports selected department',
      (tester) async {
    final service = FakeTimesheets();
    await mount(tester, service);
    expect(find.text('11к'), findsNWidgets(2));
    expect(find.text('о 11'), findsNWidgets(2));
    expect(find.text('б/с'), findsNWidgets(2));
    await tester.tap(find.text('Все доступные отделы'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отдел А').last);
    await tester.pumpAndSettle();
    expect(find.text('Сотрудник Б'), findsNothing);
    await tester.tap(find.text('Сохранить Excel'));
    await tester.pumpAndSettle();
    expect(service.savedDepartment, 'А');
    expect(service.saves, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('incomplete report requires confirmation and allows cancellation',
      (tester) async {
    final service = FakeTimesheets()..data = report(missing: 2, open: 3);
    await mount(tester, service);
    await tester.tap(find.text('Сохранить Excel'));
    await tester.pumpAndSettle();
    expect(find.text('Выгрузить незавершённый табель?'), findsOneWidget);
    await tester.tap(find.text('Вернуться'));
    await tester.pumpAndSettle();
    expect(service.saves, 0);
    await tester.tap(find.text('Сохранить Excel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выгрузить'));
    await tester.pumpAndSettle();
    expect(service.saves, 1);
  });

  testWidgets('phone layout fits and expands employee days', (tester) async {
    await mount(tester, FakeTimesheets(), size: const Size(390, 844));
    await tester.tap(find.text('Сотрудник А'));
    await tester.pumpAndSettle();
    expect(find.text('11к'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server errors offer retry and recover', (tester) async {
    final service = FakeTimesheets()
      ..loadError = const ApiException(404, 'Not found');
    await mount(tester, service);
    expect(find.textContaining('требуется обновление сервера'), findsOneWidget);
    service.loadError = null;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Сотрудник А'), findsOneWidget);
    await tester.tap(find.byTooltip('Предыдущий месяц'));
    await tester.pumpAndSettle();
    expect(service.requests.last, 7);
    service.saveError = Exception('Нет места');
    await tester.tap(find.text('Сохранить Excel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Не удалось сохранить табель'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
