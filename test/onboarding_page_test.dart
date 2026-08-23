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

    expect(find.text('Обучение сотрудника'), findsWidgets);
    expect(find.textContaining('собственные рабочие данные'), findsOneWidget);
    await goNext(tester);
    expect(find.text('Ваши основные разделы'), findsOneWidget);
    await goNext(tester);
    expect(find.text('Ближайшая смена и неделя'), findsOneWidget);
    await goNext(tester);
    expect(find.text('Что означают события'), findsOneWidget);
    expect(find.textContaining('Отпуск'), findsWidgets);
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

    expect(find.text('Обучение руководителя'), findsWidgets);
    await goNext(tester);
    expect(find.text('Рабочие разделы руководителя'), findsOneWidget);
    await goNext(tester);
    expect(find.text('Найдите нужную смену'), findsOneWidget);
    expect(find.textContaining('Должность оставит'), findsOneWidget);
    await goNext(tester);
    expect(find.text('Отметка выхода сотрудников'), findsOneWidget);
    await goNext(tester);
    expect(
      find.text('Опоздание, ранний уход и переработка'),
      findsOneWidget,
    );
    await goNext(tester);
    expect(find.text('Проверьте и закройте день'), findsOneWidget);
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
