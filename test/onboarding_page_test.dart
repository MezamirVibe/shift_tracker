import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/app/theme.dart';
import 'package:shift_tracker/features/onboarding/onboarding_page.dart';

void main() {
  Future<void> pumpOnboarding(
    WidgetTester tester, {
    required OnboardingAudience audience,
    required Size size,
    required ThemeData theme,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: OnboardingPage(
          replay: true,
          audienceOverride: audience,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> goNext(WidgetTester tester) async {
    await tester.tap(find.text('Далее'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('employee onboarding fits a narrow phone and explains basics', (
    tester,
  ) async {
    await pumpOnboarding(
      tester,
      audience: OnboardingAudience.employee,
      size: const Size(360, 720),
      theme: AppTheme.light(),
    );

    expect(find.text('Добро пожаловать в Shift Tracker'), findsOneWidget);
    await goNext(tester);
    expect(find.text('Четыре основных раздела'), findsOneWidget);
    await goNext(tester);
    expect(find.text('Как посмотреть смену'), findsOneWidget);
    await goNext(tester);
    expect(find.text('Весь месяц в календаре'), findsOneWidget);
    await goNext(tester);
    expect(find.text('Всё готово'), findsOneWidget);
    expect(find.text('Начать работу'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manager onboarding explains attendance and administration', (
    tester,
  ) async {
    await pumpOnboarding(
      tester,
      audience: OnboardingAudience.manager,
      size: const Size(390, 844),
      theme: AppTheme.dark(),
    );

    expect(find.text('Добро пожаловать в Shift Tracker'), findsOneWidget);
    await goNext(tester);
    expect(find.text('Где находятся разделы'), findsOneWidget);
    await goNext(tester);
    expect(find.text('Отметка выхода сотрудников'), findsOneWidget);
    await goNext(tester);
    expect(find.text('Контроль месяца'), findsOneWidget);
    await goNext(tester);
    expect(find.text('Сотрудники и доступы'), findsOneWidget);
    await goNext(tester);
    expect(find.text('Можно начинать работу'), findsOneWidget);
    expect(find.text('Начать работу'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
