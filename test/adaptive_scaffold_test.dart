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

    expect(find.text('Череда'), findsOneWidget);
    expect(find.text('Главная'), findsOneWidget);
    expect(find.text('Неделя'), findsOneWidget);
    expect(find.text('Месяц'), findsOneWidget);
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
    expect(find.text('Неделя'), findsOneWidget);
    expect(find.text('Месяц'), findsOneWidget);
    expect(find.text('Настройки'), findsOneWidget);
    expect(find.text('Ещё'), findsNothing);
    expect(find.text('Мобильное содержимое'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short navigation labels fit a narrow phone with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.35;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(
      tester.platformDispatcher.clearTextScaleFactorTestValue,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const AdaptiveScaffold(
          title: 'Проверка',
          selectedRoute: '/schedule',
          child: Center(child: Text('Узкий экран')),
        ),
      ),
    );

    expect(find.text('Неделя'), findsOneWidget);
    expect(find.text('Месяц'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps settings visible and puts admin sections under more',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final items = [
      NavItem(label: 'Главная', icon: Icons.home, route: '/', onTap: () {}),
      NavItem(
        label: 'График',
        icon: Icons.calendar_view_week,
        route: '/schedule',
        onTap: () {},
      ),
      NavItem(
        label: 'Календарь',
        icon: Icons.calendar_month,
        route: '/calendar',
        onTap: () {},
      ),
      NavItem(
        label: 'Сотрудники',
        icon: Icons.people,
        route: '/employees',
        onTap: () {},
      ),
      NavItem(
        label: 'Настройки',
        icon: Icons.settings,
        route: '/settings',
        onTap: () {},
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: AdaptiveScaffold(
          title: 'Проверка',
          selectedRoute: '/',
          items: items,
          child: const SizedBox.shrink(),
        ),
      ),
    );

    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(find.text('Настройки'), findsOneWidget);
    expect(find.text('Ещё'), findsOneWidget);

    await tester.tap(find.text('Ещё'));
    await tester.pumpAndSettle();

    expect(find.text('Сотрудники'), findsOneWidget);
    expect(find.text('Настройки'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
