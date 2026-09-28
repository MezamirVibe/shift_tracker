import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/app/theme.dart';
import 'package:shift_tracker/core/api_client.dart';
import 'package:shift_tracker/features/calendar/calendar_page.dart';
import 'package:shift_tracker/features/dashboard/dashboard_page.dart';
import 'package:shift_tracker/features/onboarding/onboarding_service.dart';
import 'package:shift_tracker/features/attendance/hour_requests_page.dart';
import 'support/layout_fixture.dart';

class _CalendarOnlyFixture extends LayoutFixture {
  @override
  Map<String, Object?> get user => {...super.user, 'role': roles[1]};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = _CalendarOnlyFixture();
  var fail = false;
  var personalRequests = 0;
  Map<String, dynamic>? submitted;
  bool pending = false;
  setUpAll(() async {
    fixture.roles[1]['permissions'] = ['viewCalendar'];
    fixture.responder = (method, uri, body) {
      if (uri.path.endsWith('/hour-requests/page')) {
        return {
          'items': pending
              ? [
                  {
                    'id': 'request-1',
                    'employee_id': 'employee-1',
                    'full_name': 'Сотрудник',
                    'day': '2026-09-14',
                    'additional_minutes': 180,
                    'base_minutes': 480,
                    'reason': 'Дополнительная приёмка',
                    'status': 'pending',
                    'created_at': '2026-09-14T12:00:00',
                  }
                ]
              : [],
          'next_cursor': null,
          'pending_count': pending ? 1 : 0
        };
      }
      if (uri.path.endsWith('/self/schedule')) {
        personalRequests++;
        if (fail) throw const ApiException(503, 'Сервер временно недоступен');
        return {
          'employee': {
            ...fixture.employees.first,
            'custom_workdays': [1, 2, 3, 4, 5]
          },
          'attendance': {
            '2026-09-14': {
              'employee-1': {
                'fact': 'worked',
                'workedMinutes': 480,
                'closed': true
              }
            },
            '2026-09-15': {
              'employee-1': {
                'fact': 'worked',
                'workedMinutes': 660,
                'closed': true
              }
            },
          },
          'can_view_attendance': true,
        };
      }
      if (uri.path.endsWith('/hour-requests')) {
        if (method == 'POST') {
          submitted = Map<String, dynamic>.from(body as Map);
          return {'status': 'pending'};
        }
        return <Object>[];
      }
      if (uri.path.endsWith('/employees') || uri.path.endsWith('/attendance')) {
        throw StateError('Calendar-only account must not request $uri');
      }
      return null;
    };
    await fixture.install();
    await OnboardingService.instance.completeForCurrentUser();
  });
  tearDownAll(fixture.dispose);
  setUp(() {
    fail = false;
    personalRequests = 0;
    submitted = null;
    pending = false;
  });

  testWidgets('calendar-only employee dashboard loads its own schedule',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(theme: AppTheme.light(), home: const DashboardPage()));
    await tester.pumpAndSettle();
    expect(personalRequests, 1);
    expect(find.text('Ближайшая смена'), findsOneWidget);
    expect(find.text('Повторить'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('employee week and month load without staff directory access',
      (tester) async {
    for (final month in [false, true]) {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: CalendarPage(
            key: ValueKey(month),
            fullView: month,
            initialDate: DateTime(2026, 9, 21),
          )));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Повторить'), findsNothing);
      expect(tester.takeException(), isNull);
    }
    expect(personalRequests, 2);
  });

  testWidgets('calendar failure ends loading and retry recovers',
      (tester) async {
    fail = true;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: CalendarPage(initialDate: DateTime(2026, 9, 21))));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Сервер временно недоступен'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Повторить'), findsNothing);
    expect(personalRequests, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'personal week shows closed hours and distinct work/off days on phone',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dim(),
        home: RepaintBoundary(
            key: key,
            child: CalendarPage(initialDate: DateTime(2026, 9, 14)))));
    await tester.pumpAndSettle();
    expect(find.text('8 ч'), findsOneWidget);
    expect(find.text('11 ч'), findsOneWidget);
    expect(find.text('Вых.'), findsNWidgets(2));
    expect(find.text('Смена'), findsNWidgets(3));
    expect(find.text('Учтено: 8 ч'), findsOneWidget);
    expect(find.text('День закрыт'), findsOneWidget);
    expect(find.text('Закрыто за эту неделю: 19 ч'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final folder = Platform.environment['LAYOUT_AUDIT_OUTPUT'];
    if (folder != null) {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(folder).create(recursive: true);
        await File('$folder/personal-week-1.6.0.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.text('15').first);
    await tester.pumpAndSettle();
    expect(find.text('Учтено: 11 ч'), findsOneWidget);
    await tester.tap(find.text('19').first);
    await tester.pumpAndSettle();
    expect(find.text('По плану: выходной'), findsOneWidget);
    expect(find.text('Запросить добавление часов'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'pending request replaces submit and details expand in-place in both themes',
      (tester) async {
    pending = true;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final width in [320.0, 1600.0]) {
      tester.view.physicalSize = Size(width, width == 320 ? 740 : 900);
      for (final dark in [false, true]) {
        await tester.pumpWidget(MaterialApp(
          theme: dark ? AppTheme.dim() : AppTheme.light(),
          home: CalendarPage(
              key: ValueKey('$width-$dark'),
              initialDate: DateTime(2026, 9, 14)),
        ));
        await tester.pumpAndSettle();
        expect(find.text('Учтено: 8 ч'), findsOneWidget);
        expect(find.text('Запрошено +3 ч — ожидает решения'), findsOneWidget);
        expect(find.text('Запросить добавление часов'), findsNothing);
        await tester.ensureVisible(find.text('Подробности дня'));
        await tester.pumpAndSettle();
        if (tester.getCenter(find.text('Подробности дня')).dy >
            tester.view.physicalSize.height - 100) {
          await tester.drag(find.byType(ListView).first, const Offset(0, -180));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Подробности дня'));
        await tester.pumpAndSettle();
        expect(find.text('Приход: не указан'), findsOneWidget);
        expect(find.text('Открыть неделю'), findsNothing);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets(
      'request form submits additional hours only and fits phone keyboard',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dim(),
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showHourRequestDialog(context,
                        day: DateTime(2026, 9, 14), baseMinutes: 480),
                    child: const Text('Запрос'))))));
    await tester.tap(find.text('Запрос'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Добавить часов'), '3');
    await tester.enterText(
        find.widgetWithText(TextField, 'Причина'), 'Дополнительная приёмка');
    await tester.ensureVisible(find.text('Отправить запрос'));
    await tester.tap(find.text('Отправить запрос'));
    await tester.pumpAndSettle();
    expect(submitted?['additional_minutes'], 180);
    expect(submitted?['day'], '2026-09-14');
    expect(submitted?['employee_id'], isNull);
    expect(tester.takeException(), isNull);
  });
}
