import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shift_tracker/features/attendance/import_timesheet_page.dart';
import 'support/layout_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = LayoutFixture();
  setUpAll(fixture.install);
  tearDownAll(fixture.dispose);
  tearDown(() => fixture.responder = null);

  testWidgets('file preview never imports until rows and confirmation selected',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var previews = 0, commits = 0;
    fixture.responder = (method, uri, body) {
      if (uri.path.endsWith('/imports/timesheet/preview')) {
        previews++;
        return {
          'sheets': ['Лист1'],
          'sheet': 'Лист1',
          'needs_sheet': false,
          'detected_period': null,
          'department': 'ОТК',
          'errors': [],
          'error_count': 0,
          'preview_token': 'test-preview',
          'rows': [
            {
              'row': 2,
              'full_name': 'Иванов Иван Иванович',
              'source_department': 'ОТК',
              'position': 'Контролёр',
              'action': 'create',
              'new_marks': 2,
              'same_marks': 0,
              'conflicts': 0,
              'locked': 0,
              'reason': null,
              'archived_namesake': false
            },
            {
              'row': 3,
              'full_name': 'Петров Пётр Петрович',
              'source_department': 'ОТК',
              'position': 'Контролёр',
              'action': 'blocked',
              'new_marks': 0,
              'same_marks': 0,
              'conflicts': 0,
              'locked': 0,
              'reason': 'Несколько одинаковых ФИО',
              'archived_namesake': false
            }
          ]
        };
      }
      if (uri.path.endsWith('/imports/timesheet/commit')) {
        commits++;
        expect((body as Map)['selected_rows'], [2]);
        return {
          'created_employees': 1,
          'written_marks': 2,
          'preserved_marks': 0
        };
      }
      return fixture.reply(method, uri, body);
    };
    final router = GoRouter(initialLocation: '/timesheet/import', routes: [
      GoRoute(
          path: '/timesheet/import',
          builder: (_, __) => ImportTimesheetPage(
              pickFile: () async => XFile.fromData(
                  Uint8List.fromList([1, 2, 3]),
                  name: 'old.xlsx'))),
      GoRoute(
          path: '/timesheet',
          builder: (_, __) => const Scaffold(body: Text('Готовый табель'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать Excel'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Проверить файл'));
    await tester.tap(find.text('Проверить файл'));
    await tester.pumpAndSettle();
    expect(previews, 1);
    expect(commits, 0);
    await tester.ensureVisible(find.text('Выбрать показанных'));
    await tester.tap(find.text('Выбрать показанных'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Импортировать (1)'));
    await tester.tap(find.text('Импортировать (1)'));
    await tester.pumpAndSettle();
    expect(commits, 0);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(commits, 0);
    await tester.tap(find.text('Импортировать (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Импортировать').last);
    await tester.pumpAndSettle();
    expect(commits, 1);
    expect(find.text('Готовый табель'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
