import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/app/theme.dart';
import 'package:shift_tracker/core/api_client.dart';
import 'package:shift_tracker/features/calendar/calendar_page.dart';
import 'package:shift_tracker/features/dashboard/dashboard_page.dart';
import 'package:shift_tracker/features/onboarding/onboarding_service.dart';
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
  setUpAll(() async {
    fixture.roles[1]['permissions'] = ['viewCalendar'];
    fixture.responder = (method, uri, body) {
      if (uri.path.endsWith('/self/schedule')) {
        personalRequests++;
        if (fail) throw const ApiException(503, 'Сервер временно недоступен');
        return {
          'employee': fixture.employees.first,
          'attendance': <String, Object?>{},
          'can_view_attendance': false,
        };
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
}
