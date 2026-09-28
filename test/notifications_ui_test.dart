import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/app/theme.dart';
import 'package:shift_tracker/features/notifications/notification_models.dart';
import 'package:shift_tracker/features/notifications/notification_settings_page.dart';
import 'package:shift_tracker/features/notifications/notifications_page.dart';

const _workerKinds = [
  'hours_closed',
  'request_decision',
  'schedule_changed',
  'shift_reminder'
];
const _managerKinds = ['request_created', 'unfilled_days', 'delivery_failed'];

Future<void> _pump(
  WidgetTester tester,
  Widget body, {
  required bool dark,
  double width = 320,
  double keyboard = 0,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('ru', 'RU'),
    supportedLocales: const [Locale('ru', 'RU')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: dark ? AppTheme.dim() : AppTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: const TextScaler.linear(1.2)),
      child: child!,
    ),
    home:
        Scaffold(appBar: AppBar(title: const Text('Уведомления')), body: body),
  ));
  await tester.pumpAndSettle();
}

NotificationSettingsContent _settings({
  required List<String> kinds,
  required ValueChanged<Map<String, dynamic>> onChanged,
  bool push = true,
  bool windows = false,
  bool permission = false,
}) =>
    NotificationSettingsContent(
      preferences:
          NotificationPreferences(pushEnabled: push, pushAvailable: true),
      visibleKinds: kinds,
      enabled: true,
      loading: false,
      saving: false,
      deliveryStatus: windows
          ? 'Фоновые уведомления Windows пока не подключены. История доступна в приложении.'
          : 'Системные уведомления включены на этом устройстве.',
      canRequestPermission: permission,
      lastUpdated: DateTime(2026, 9, 24, 12, 30),
      onRefresh: () {},
      onPermission: () {},
      onChanged: onChanged,
    );

void main() {
  for (final dark in [false, true]) {
    testWidgets(
        'worker notification settings 320px ${dark ? 'dark' : 'light'} can switch each type off',
        (tester) async {
      final patches = <Map<String, dynamic>>[];
      await _pump(tester,
          _settings(kinds: _workerKinds, onChanged: patches.add, push: false),
          dark: dark);
      expect(find.text('Пуш-уведомления'), findsOneWidget);
      expect(find.text('Новый запрос часов'), findsNothing);
      for (final kind in _workerKinds) {
        final label = find.text(notificationKindLabels[kind]!);
        await tester.ensureVisible(label);
        await tester.pumpAndSettle();
        await tester.tap(label);
        await tester.pump();
        expect((patches.last['kinds'] as Map).keys.single, kind);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'notification inbox 320px ${dark ? 'dark' : 'light'} long text and pagination',
        (tester) async {
      var loaded = false;
      var opened = false;
      var read = false;
      final item = InboxNotification(
        id: 'notification-1',
        kind: 'hours_closed',
        title: 'День закрыт — часы сотрудника учтены руководителем',
        body:
            '24.09.2026: учтено 11 ч. Комментарий руководителя: согласована дополнительная работа после окончания основной смены.',
        createdAt: DateTime(2026, 9, 24, 12, 30),
      );
      await _pump(
          tester,
          NotificationsInboxContent(
            items: [item],
            unreadCount: 1,
            loading: false,
            loadingMore: false,
            hasMore: true,
            lastUpdated: DateTime(2026, 9, 24, 12, 30),
            error:
                'Не удалось обновить уведомления. Показаны последние загруженные данные.',
            onRefresh: () async {},
            onLoadMore: () => loaded = true,
            onReadAll: () => read = true,
            onOpen: (_) => opened = true,
          ),
          dark: dark);
      expect(find.text('Не прочитано'), findsOneWidget);
      expect(find.textContaining('Обновлено:'), findsOneWidget);
      await tester.tap(find.text('Прочитать все'));
      expect(read, isTrue);
      await tester.ensureVisible(find.text(item.title));
      await tester.tap(find.text(item.title));
      expect(opened, isTrue);
      await tester.scrollUntilVisible(find.text('Показать ещё'), 250);
      await tester.tap(find.text('Показать ещё'));
      expect(loaded, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'manager Windows settings stay compact and state missing background delivery',
      (tester) async {
    await _pump(tester,
        _settings(kinds: _managerKinds, onChanged: (_) {}, windows: true),
        dark: true, width: 1440);
    expect(find.text('Новый запрос часов'), findsOneWidget);
    expect(find.text('Ответ на запрос часов'), findsNothing);
    expect(
        find.textContaining('Фоновые уведомления Windows пока не подключены'),
        findsOneWidget);
    expect(find.text('Разрешить на устройстве'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'timezone dialog fits 320px with keyboard and saves explicit value',
      (tester) async {
    final patches = <Map<String, dynamic>>[];
    await _pump(tester, _settings(kinds: _managerKinds, onChanged: patches.add),
        dark: false);
    await tester.scrollUntilVisible(find.text('Не беспокоить'), 250);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Не беспокоить'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Часовой пояс'), 250);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Часовой пояс'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Europe/Moscow');
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(find.text('Сохранить').hitTestable(), findsOneWidget);
    final rect = tester.getRect(find.text('Сохранить'));
    expect(rect.bottom, lessThanOrEqualTo(520));
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(patches.last, {'timezone': 'Europe/Moscow'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty inbox does not pretend an unrefreshed history is read',
      (tester) async {
    await _pump(
        tester,
        NotificationsInboxContent(
          items: const [],
          unreadCount: 0,
          loading: false,
          loadingMore: false,
          hasMore: false,
          onRefresh: () async {},
          onLoadMore: () {},
          onReadAll: () {},
          onOpen: (_) {},
        ),
        dark: true);
    expect(find.text('Новых событий пока нет'), findsOneWidget);
    expect(find.text('Всё прочитано'), findsNothing);
    expect(find.text('Показать ещё'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
