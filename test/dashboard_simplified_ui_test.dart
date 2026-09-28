import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/app/theme.dart';
import 'package:shift_tracker/features/dashboard/dashboard_page.dart';
import 'package:shift_tracker/features/onboarding/onboarding_service.dart';

import 'support/layout_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = LayoutFixture();

  setUpAll(() async {
    await fixture.install();
    await OnboardingService.instance.completeForCurrentUser();
  });
  tearDownAll(fixture.dispose);

  testWidgets('manager dashboard shows actions without personal widgets',
      (tester) async {
    for (final scenario in [
      (size: const Size(320, 640), theme: AppTheme.light()),
      (size: const Size(1600, 900), theme: AppTheme.dim()),
    ]) {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(
        theme: scenario.theme,
        home: DashboardPage(key: ValueKey(scenario.size.width)),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Ожидают решения'), findsOneWidget);
      expect(find.text('Сотрудники сегодня'), findsOneWidget);
      expect(find.text('Требуют внимания'), findsOneWidget);
      expect(find.text('Открыть табель за месяц'), findsOneWidget);
      expect(find.text('Ближайшая смена'), findsNothing);
      expect(find.text('Закрытые часы за месяц'), findsNothing);
      expect(tester.takeException(), isNull);
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
