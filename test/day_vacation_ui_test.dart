import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/app/theme.dart';
import 'package:shift_tracker/features/auth/auth_service.dart';
import 'package:shift_tracker/features/day/day_page.dart';
import 'support/layout_fixture.dart';

class _OneEmployeeFixture extends LayoutFixture {
  @override
  List<Map<String, Object?>> get employees => [super.employees.first];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = _OneEmployeeFixture();
  Map<String, dynamic>? vacationBody;
  setUpAll(() async {
    fixture.responder = (method, uri, body) {
      if (method == 'POST' &&
          uri.path.endsWith('/attendance/vacation-range')) {
        vacationBody = Map<String, dynamic>.from(body as Map);
        return {
          'applied': ['2026-09-21', '2026-09-30'],
          'already_vacation': <String>[],
          'skipped_closed': <String>[],
          'skipped_existing': <String>[],
        };
      }
      return null;
    };
    await fixture.install();
    await AuthService.instance.init();
    await AuthService.instance
        .loginDetailed('layout', 'test-only', rememberSession: false);
  });
  tearDownAll(fixture.dispose);

  testWidgets('manager sets inclusive vacation period on narrow phone',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: const DayPage(dateIso: '2026-09-21'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отпуск на период'));
    await tester.pumpAndSettle();
    expect(find.text('21.09.2026 – 30.09.2026'), findsOneWidget);
    final comment = find.widgetWithText(
        TextFormField, 'Комментарий (необязательно)');
    await tester.enterText(comment, 'Ежегодный отпуск');
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Назначить'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Назначить')).onPressed,
        isNotNull);
    await tester.tap(find.text('Назначить'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Отпуск сохранён'), findsOneWidget);
    final body = vacationBody!;
    expect(body['employee_id'], 'employee-1');
    expect(body['date_from'], '2026-09-21');
    expect(body['date_to'], '2026-09-30');
    expect(body['comment'], 'Ежегодный отпуск');
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct hours edit does not fabricate clock times',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: const DayPage(dateIso: '2026-08-03'),
    ));
    await tester.pumpAndSettle();
    final edit = find.text('Время').evaluate().isNotEmpty
        ? find.text('Время').first
        : find.text('Время и отклонения').first;
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsNothing);
    final hours = find.widgetWithText(TextFormField, 'Учтено часов');
    await tester.enterText(hours, '11');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    final request = fixture.requests.lastWhere((item) =>
        item.method == 'PUT' && item.path.contains('/attendance/'));
    final body = request.body as Map;
    expect(body['worked_minutes'], 660);
    expect(body['actual_start'], isNull);
    expect(body['actual_end'], isNull);
    expect(tester.takeException(), isNull);
  });
}
