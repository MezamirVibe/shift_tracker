import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/app/theme.dart';
import 'package:shift_tracker/shared/widgets/adaptive_scaffold.dart';

void main() {
  testWidgets('uses the full sidebar on desktop', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const AdaptiveScaffold(
          title: 'Проверка',
          selectedRoute: '/',
          child: Center(child: Text('Содержимое')),
        ),
      ),
    );

    expect(find.text('Shift Tracker'), findsOneWidget);
    expect(find.text('Главная'), findsOneWidget);
    expect(find.text('График'), findsOneWidget);
    expect(find.text('Календарь'), findsOneWidget);
    expect(find.text('Настройки'), findsOneWidget);
    expect(find.text('Содержимое'), findsOneWidget);
  });

  testWidgets('uses bottom navigation on a phone', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const AdaptiveScaffold(
          title: 'Проверка',
          selectedRoute: '/',
          child: Center(child: Text('Мобильное содержимое')),
        ),
      ),
    );

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(4));
    expect(find.text('Главная'), findsOneWidget);
    expect(find.text('График'), findsOneWidget);
    expect(find.text('Календарь'), findsOneWidget);
    expect(find.text('Ещё'), findsOneWidget);
    expect(find.text('Мобильное содержимое'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Ещё'));
    await tester.pumpAndSettle();

    expect(find.text('Настройки'), findsOneWidget);
  });
}
