import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shift_tracker/app/app.dart';
import 'package:shift_tracker/features/auth/auth_service.dart';
import 'package:shift_tracker/features/day/day_page.dart';
import 'package:shift_tracker/features/onboarding/onboarding_service.dart';
import 'support/layout_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = LayoutFixture();
  setUpAll(() async {
    await fixture.install();
    await AuthService.instance.init();
    await AuthService.instance
        .loginDetailed('layout', 'test-only', rememberSession: false);
    await OnboardingService.instance.completeForCurrentUser();
  });
  tearDownAll(fixture.dispose);

  testWidgets('day has desktop back button and preserves selected date',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(initialLocation: '/day/2026-09-02', routes: [
      GoRoute(
          path: '/day/:date',
          builder: (_, state) =>
              DayPage(dateIso: state.pathParameters['date']!)),
      GoRoute(
          path: '/calendar',
          builder: (_, state) => Scaffold(
              body: Text('Календарь ${state.uri.queryParameters['date']}'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.byTooltip('К графику'), findsOneWidget);
    await tester.tap(find.byTooltip('К графику'));
    await tester.pumpAndSettle();
    expect(find.text('Календарь 2026-09-02'), findsOneWidget);
    // A pushed day returns to its exact origin, rather than resetting the calendar.
    unawaited(router.push('/day/2026-09-03'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('К графику'));
    await tester.pumpAndSettle();
    expect(find.text('Календарь 2026-09-02'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('application date picker uses Russian and Monday first',
      (tester) async {
    await tester.pumpWidget(const ShiftTrackerApp());
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold).first);
    final locale = MaterialLocalizations.of(context);
    expect(locale.firstDayOfWeekIndex, 1);
    expect(locale.cancelButtonLabel, 'Отмена');
    expect(locale.formatMonthYear(DateTime(2026, 9, 21)), contains('сентябр'));
    unawaited(showDatePicker(
        context: context,
        initialDate: DateTime(2026, 9, 21),
        firstDate: DateTime(2020),
        lastDate: DateTime(2100)));
    await tester.pumpAndSettle();
    expect(find.text('Select date'), findsNothing);
    expect(find.text('Отмена'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
