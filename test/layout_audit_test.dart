import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/app/theme.dart';
import 'package:shift_tracker/features/auth/login_page.dart';
import 'package:shift_tracker/features/auth/bootstrap_admin_page.dart';
import 'package:shift_tracker/features/admin/admin_page.dart';
import 'package:shift_tracker/features/admin/roles_editor_page.dart';
import 'package:shift_tracker/features/admin/users_admin_page.dart';
import 'package:shift_tracker/features/admin/positions_page.dart';
import 'package:shift_tracker/features/calendar/calendar_page.dart';
import 'package:shift_tracker/features/dashboard/dashboard_page.dart';
import 'package:shift_tracker/features/day/day_page.dart';
import 'package:shift_tracker/features/employees/employees_page.dart';
import 'package:shift_tracker/features/employees/employee_details_page.dart';
import 'package:shift_tracker/features/preferences/preferences_page.dart';
import 'package:shift_tracker/features/structure/structure_page.dart';
import 'package:shift_tracker/features/attendance/timesheet_page.dart';
import 'package:shift_tracker/features/onboarding/onboarding_page.dart';
import 'package:shift_tracker/features/employees/employee_editor_dialog.dart';
import 'package:shift_tracker/features/employees/employees_storage.dart';
import 'support/layout_fixture.dart';
import 'package:shift_tracker/features/auth/organization_page.dart';
import 'package:shift_tracker/features/attendance/import_timesheet_page.dart';
import 'package:shift_tracker/features/attendance/delivery_page.dart';

final captureKey = GlobalKey();
Future<void> capture(WidgetTester tester, String name) async {
  final output = Platform.environment['LAYOUT_AUDIT_OUTPUT'];
  if (output == null) return;
  final boundary =
      captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(output).create(recursive: true);
    await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = LayoutFixture();
  setUpAll(fixture.install);
  tearDownAll(fixture.dispose);

  final screens = <String, Widget Function()>{
    'organization': () => const OrganizationPage(),
    'import-timesheet': () => const ImportTimesheetPage(),
    'delivery': () => const DeliveryPage(),
    'login': () => const LoginPage(),
    'bootstrap': () => const BootstrapAdminPage(),
    'dashboard': () => const DashboardPage(),
    'week': () => CalendarPage(initialDate: DateTime(2026, 8, 3)),
    'calendar': () =>
        CalendarPage(fullView: true, initialDate: DateTime(2026, 8, 3)),
    'day': () => const DayPage(dateIso: '2026-08-03'),
    'employees': () => const EmployeesPage(),
    'employee-details': () => const EmployeeDetailsPage(id: 'employee-1'),
    'preferences': () => const PreferencesPage(),
    'admin': () => const AdminPage(),
    'users': () => const Scaffold(body: UsersAdminPage()),
    'roles': () => const Scaffold(body: RolesEditorPage()),
    'positions': () => const Scaffold(body: PositionsPage()),
    'structure': () => const StructurePage(),
    'timesheet': () => const MonthReportPage(year: 2026, month: 8),
    'employee-onboarding': () => const OnboardingPage(
        replay: true, audienceOverride: OnboardingAudience.employee),
    'manager-onboarding': () => const OnboardingPage(
        replay: true, audienceOverride: OnboardingAudience.manager),
  };
  final scenarios = [
    (
      name: 'phone-keyboard',
      size: const Size(360, 800),
      scale: 1.0,
      keyboard: 310.0
    ),
    (
      name: 'narrow-large-text',
      size: const Size(320, 640),
      scale: 1.5,
      keyboard: 0.0
    ),
    (name: 'landscape', size: const Size(740, 360), scale: 1.0, keyboard: 0.0),
    (
      name: 'small-keyboard',
      size: const Size(320, 568),
      scale: 1.3,
      keyboard: 260.0
    ),
    (
      name: 'accessibility',
      size: const Size(320, 640),
      scale: 2.0,
      keyboard: 0.0
    ),
    (name: 'desktop', size: const Size(1280, 800), scale: 1.25, keyboard: 0.0),
  ];
  for (final scenario in scenarios) {
    for (final screen in screens.entries) {
      testWidgets('${screen.key} ${scenario.name}', (tester) async {
        fixture.unhandled.clear();
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = FakeViewPadding(bottom: scenario.keyboard);
        tester.platformDispatcher.textScaleFactorTestValue = scenario.scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final issues = <String>[];
        final originalHandler = FlutterError.onError;
        FlutterError.onError = (details) => issues.add(details.toString());
        try {
          await tester.pumpWidget(RepaintBoundary(
              key: captureKey,
              child:
                  MaterialApp(theme: AppTheme.light(), home: screen.value())));
          await tester.pumpAndSettle();
          final navigation = find.byType(NavigationBar);
          if (navigation.evaluate().isNotEmpty) {
            final bounds = tester.getRect(navigation);
            for (final label in find
                .descendant(of: navigation, matching: find.byType(Text))
                .evaluate()) {
              final rect =
                  tester.getRect(find.byElementPredicate((e) => e == label));
              expect(rect.bottom, lessThanOrEqualTo(bounds.bottom + 1),
                  reason: 'Navigation label is clipped below the screen');
            }
          }
          if (Platform.environment['LAYOUT_AUDIT_OUTPUT'] != null) {
            await tester.runAsync(() => precacheImage(
                const AssetImage('assets/branding/chereda_app_icon.png'),
                tester.element(find.byType(MaterialApp))));
            await tester.pumpAndSettle();
          }
          await capture(tester, '${screen.key}-${scenario.name}');
          if (screen.key.endsWith('onboarding')) {
            for (var step = 0;
                step < 15 && find.text('Далее').evaluate().isNotEmpty;
                step++) {
              await tester.tap(find.text('Далее'));
              await tester.pumpAndSettle();
            }
            expect(find.text('Начать работу'), findsOneWidget);
          }
          // Exercise lazy list children, not only the first visible card.
          final scrollables = find.byType(Scrollable);
          if (scrollables.evaluate().isNotEmpty) {
            await tester.drag(scrollables.first, const Offset(0, -450),
                warnIfMissed: false);
            await tester.pumpAndSettle();
            await capture(tester, '${screen.key}-${scenario.name}-scrolled');
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          FlutterError.onError = originalHandler;
        }
        expect(fixture.unhandled, isEmpty, reason: 'Missing test API fixture');
        expect(issues, isEmpty, reason: issues.take(4).join('\n'));
      });
    }
  }

  final dialogs = <String,
      ({Widget Function() screen, Future<void> Function(WidgetTester) open})>{
    'password': (
      screen: () => const PreferencesPage(),
      open: (tester) async {
        await tester.ensureVisible(find.text('Сменить пароль'));
        await tester.tap(find.text('Сменить пароль'));
      }
    ),
    'role': (
      screen: () => const Scaffold(body: RolesEditorPage()),
      open: (tester) async {
        final button = find.text('Новая роль').evaluate().isNotEmpty
            ? find.text('Новая роль')
            : find.byTooltip('Новая роль');
        await tester.tap(button);
      }
    ),
    'position': (
      screen: () => const Scaffold(body: PositionsPage()),
      open: (tester) async {
        await tester.ensureVisible(find.text('Добавить должность'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Добавить должность'));
      }
    ),
    'group': (
      screen: () => const StructurePage(),
      open: (tester) async {
        await tester.tap(find.text('Группы'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Добавить группу'));
      }
    ),
    'employee': (
      screen: () => Builder(
          builder: (context) => Scaffold(
              body: Center(
                  child: FilledButton(
                      onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => EmployeeEditorDialog(
                              showAccessFields: true,
                              initial: EmployeeDraft(
                                  fullName: LayoutFixture.employeeName,
                                  position: LayoutFixture.positionName,
                                  salary: 0,
                                  bonus: 0,
                                  departmentId: 'department-1',
                                  groupId: 'group-1',
                                  scheduleType: ScheduleType.custom,
                                  scheduleStartDate: DateTime(2026),
                                  shiftHours: 12,
                                  breakHours: 1,
                                  customWorkdays: [1, 2, 3, 4, 5],
                                  login: 'alexander.long.login',
                                  roleId: 'worker'))),
                      child: const Text('Открыть'))))),
      open: (tester) async {
        await tester.tap(find.text('Открыть'));
      }
    ),
    'attendance': (
      screen: () => const DayPage(dateIso: '2026-08-03'),
      open: (tester) async {
        final group =
            find.byKey(const ValueKey('day-group-${LayoutFixture.groupName}'));
        await tester.ensureVisible(group);
        await tester.tap(group);
        await tester.pumpAndSettle();
        final edit = find.text('Время').evaluate().isNotEmpty
            ? find.text('Время').first
            : find.text('Время и отклонения').first;
        await tester.ensureVisible(edit);
        await tester.pumpAndSettle();
        await tester.tap(edit);
      }
    ),
  };
  for (final scenario in scenarios.where((s) =>
      s.name == 'small-keyboard' ||
      s.name == 'accessibility' ||
      s.name == 'desktop')) {
    for (final dialog in dialogs.entries) {
      testWidgets('dialog-${dialog.key} ${scenario.name}', (tester) async {
        fixture.unhandled.clear();
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scenario.scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final issues = <String>[];
        final originalHandler = FlutterError.onError;
        FlutterError.onError = (details) => issues.add(details.toString());
        try {
          await tester.pumpWidget(RepaintBoundary(
              key: captureKey,
              child: MaterialApp(
                  theme: AppTheme.light(), home: dialog.value.screen())));
          await tester.pumpAndSettle();
          await dialog.value.open(tester);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(issues, isEmpty, reason: issues.take(2).join('\n'));
          final dropdowns = find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byWidgetPredicate(
                  (widget) => widget is DropdownButtonFormField));
          if (dropdowns.evaluate().isNotEmpty) {
            await tester.ensureVisible(dropdowns.first);
            await tester.pumpAndSettle();
            await tester.tap(dropdowns.first);
            await tester.pumpAndSettle();
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
          }
          tester.view.viewInsets = FakeViewPadding(bottom: scenario.keyboard);
          await tester.pumpAndSettle();
          expect(issues, isEmpty, reason: issues.take(2).join('\n'));
          await capture(tester, 'dialog-${dialog.key}-${scenario.name}');
          final scrollables = find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(Scrollable));
          if (scrollables.evaluate().isNotEmpty) {
            await tester.drag(scrollables.first, const Offset(0, -900),
                warnIfMissed: false);
            await tester.pumpAndSettle();
          }
          if (dialog.key == 'attendance') {
            final comment = find.widgetWithText(TextFormField, 'Комментарий');
            await tester.ensureVisible(comment);
            await tester.pumpAndSettle();
            await tester.enterText(comment, 'Только исправлен комментарий');
            await tester.pumpAndSettle();
            await tester.tap(find.text('Сохранить'));
            await tester.pumpAndSettle();
            final saved = fixture.requests.lastWhere((request) =>
                request.method == 'PUT' &&
                request.path.contains('/attendance/'));
            final body = saved.body as Map;
            expect(body['worked_minutes'], 360);
            expect(body['actual_start'], isNull);
            expect(body['actual_end'], isNull);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          FlutterError.onError = originalHandler;
        }
        expect(fixture.unhandled, isEmpty, reason: 'Missing test API fixture');
        expect(issues, isEmpty, reason: issues.take(4).join('\n'));
      });
    }
  }
}
