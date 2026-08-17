import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/app/theme.dart';
import 'package:shift_tracker/features/dashboard/dashboard_customizer.dart';
import 'package:shift_tracker/features/preferences/preferences_page.dart';
import 'package:shift_tracker/features/preferences/preferences_service.dart';

void main() {
  testWidgets('dashboard customizer exposes ordering and device layouts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: DashboardCustomizer(initialMobile: false),
        ),
      ),
    );

    expect(find.text('Настроить главный экран'), findsOneWidget);
    expect(find.text('Компьютер'), findsOneWidget);
    expect(find.text('Телефон'), findsOneWidget);
    expect(find.text('Ближайшая смена'), findsOneWidget);
    expect(find.byIcon(Icons.drag_indicator), findsWidgets);

    await tester.tap(find.text('Телефон'));
    await tester.pumpAndSettle();
    expect(find.text('Ближайшая смена'), findsOneWidget);
  });

  testWidgets('settings page changes the explicit theme choice',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final preferences = PreferencesService.instance;
    await preferences.setTheme(AppThemeChoice.light);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const PreferencesPage(),
      ),
    );

    await tester.tap(find.text('Сумеречная'));
    await tester.pump();
    expect(preferences.theme, AppThemeChoice.dim);

    await preferences.setTheme(AppThemeChoice.light);
  });
}
