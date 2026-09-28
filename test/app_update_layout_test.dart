import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/app/theme.dart';
import 'package:shift_tracker/features/updates/app_release.dart';
import 'package:shift_tracker/features/updates/app_update_dialog.dart';
import 'package:shift_tracker/features/updates/app_update_service.dart';

AppUpdateService _service(String platform, String state) {
  final service = AppUpdateService(platform: platform)
    ..installedVersion = '1.6.0'
    ..installedBuild = 12
    ..checkedAt = DateTime(2026, 9, 23, 14, 30)
    ..release = AppRelease(
      version: '1.7.0',
      build: 13,
      url: Uri.parse(
        'https://api.mezamir.com/updates/1.7.0/Chereda-1.7.0-$platform.${platform == 'android' ? 'apk' : 'zip'}',
      ),
      sha256: 'a' * 64,
      size: 80000000,
      notes: const [
        'Проверка новых версий и установка обновления через приложение.',
        'Скачивание с отображением прогресса и проверкой целостности файла.',
        'Сотрудники, табели, настройки и сохранённый вход остаются на месте.',
      ],
    );
  switch (state) {
    case 'downloading':
      service.phase = UpdatePhase.downloading;
      service.progress = 0.42;
    case 'ready':
      service.phase = UpdatePhase.ready;
      service.message = 'Файл проверен. Можно установить обновление.';
    case 'installing':
      service.phase = UpdatePhase.installing;
    case 'error':
      service.phase = UpdatePhase.available;
      service.error =
          'Не удалось проверить или скачать обновление. Проверьте интернет и повторите попытку. Работа с табелем доступна как обычно.';
    default:
      service.phase = UpdatePhase.available;
  }
  return service;
}

Future<void> _openDialog(
  WidgetTester tester,
  AppUpdateService service,
  ThemeData theme, {
  required Size size,
  required double keyboard,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: const TextScaler.linear(1.2),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AppUpdateDialog(service: service),
            ),
            child: const Text('Открыть обновление'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Открыть обновление'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  expect(tester.takeException(), isNull);
}

void main() {
  const states = ['available', 'downloading', 'error', 'ready', 'installing'];
  for (final dark in [false, true]) {
    for (final state in states) {
      testWidgets('updater $state 320px keyboard 240 ${dark ? 'dim' : 'light'}',
          (tester) async {
        final service = _service('android', state);
        addTearDown(service.dispose);
        await _openDialog(
          tester,
          service,
          dark ? AppTheme.dim() : AppTheme.light(),
          size: const Size(320, 640),
          keyboard: 240,
        );
        final action = switch (state) {
          'downloading' => 'Отменить загрузку',
          'ready' => 'Установить',
          'installing' => 'Закрыть',
          _ => 'Скачать обновление',
        };
        final button = find.text(action);
        expect(button.hitTestable(), findsOneWidget);
        final rect = tester.getRect(button);
        expect(rect.bottom, lessThanOrEqualTo(400));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
        if (state == 'ready') {
          await tester.tap(button);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          expect(find.text('Установить обновление?'), findsOneWidget);
          expect(find.text('Позже').hitTestable(), findsOneWidget);
        }
        if (state == 'installing') {
          final close = find.widgetWithText(TextButton, 'Закрыть');
          expect(tester.widget<TextButton>(close).onPressed, isNull);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final state in states) {
    testWidgets('updater Windows $state at 1600px', (tester) async {
      final service = _service('windows', state);
      addTearDown(service.dispose);
      await _openDialog(
        tester,
        service,
        AppTheme.dim(),
        size: const Size(1600, 900),
        keyboard: 0,
      );
      expect(find.text('Новая версия: 1.7.0'), findsOneWidget);
      if (state == 'ready') {
        await tester.tap(find.text('Установить'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.textContaining('«Череда» закроется и откроется'),
            findsOneWidget);
        expect(find.text('Позже').hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
