import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/core/api_client.dart';
import 'package:shift_tracker/features/auth/registration_page.dart';
import 'support/layout_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = LayoutFixture();
  setUpAll(() async {
    await fixture.install();
    await ApiClient.instance.clearSession();
    await ApiClient.instance.savePendingRegistration(null);
  });
  tearDownAll(fixture.dispose);

  testWidgets(
      'registration creates only on submit, preserves ticket not password, and shows ready',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var submitted = 0;
    fixture.responder = (method, uri, body) {
      if (uri.path == '/api/v1/registration') {
        submitted++;
        final data = body as Map;
        expect(data['name'], 'Новая компания');
        expect(data['password'], 'a-long-password-123');
        return {
          'request_id': data['request_id'],
          'status': 'pending',
          'code': 'org-1234567890abcdef',
          'name': 'Новая компания',
          'login': 'owner'
        };
      }
      if (uri.path == '/api/v1/registration/status') {
        expect((body as Map).containsKey('password'), isFalse);
        return {
          'status': 'ready',
          'code': 'org-1234567890abcdef',
          'name': 'Новая компания',
          'login': 'owner'
        };
      }
      return null;
    };
    await tester.pumpWidget(const MaterialApp(home: RegistrationPage()));
    await tester.pumpAndSettle();
    expect(submitted, 0);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Новая компания');
    await tester.enterText(fields.at(1), 'owner');
    await tester.enterText(fields.at(2), 'a-long-password-123');
    await tester.enterText(fields.at(3), 'a-long-password-123');
    await tester.ensureVisible(find.text('Зарегистрировать организацию'));
    await tester.tap(find.text('Зарегистрировать организацию'));
    await tester.pumpAndSettle();
    expect(submitted, 1);
      expect(
        (await tester.runAsync(() => ApiClient.instance.pendingRegistration()))!
            .containsKey('password'),
        isFalse);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Организация готова'), findsOneWidget);
    expect(tester.takeException(), isNull);
    fixture.responder = null;
    await tester.pumpWidget(const SizedBox());
  });
}
