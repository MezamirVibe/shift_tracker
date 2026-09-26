import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/core/api_client.dart';
import 'package:shift_tracker/features/employees/employees_storage.dart';
import 'support/layout_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = LayoutFixture();
  late ApiClient api;
  setUpAll(() async {
    await fixture.install();
    api = ApiClient.instance;
  });
  tearDownAll(() async {
    await api.clearSession();
    await fixture.dispose();
  });
  setUp(() async {
    fixture.responder = null;
    fixture.responseOrganizationOverride = null;
    await api.forgetOrganization();
    await api.selectOrganization('company-a');
    fixture.transportRequests.clear();
  });

  test('invalid codes never reach the network', () async {
    for (final code in ['../company', 'x', 'компания', 'a/b', 'a?b', 'a b']) {
      await expectLater(
          api.selectOrganization(code), throwsA(isA<ApiException>()));
    }
    expect(fixture.transportRequests, isEmpty);
  });

  test('requests and saved login are isolated by organization', () async {
    await api.login('alice', 'test', rememberSession: true);
    final owner = api.cacheUserKey;
    await api.request('GET', '/api/v1/employees');
    expect(fixture.transportRequests.last.uri.path,
        '/o/company-a/api/v1/employees');
    expect(fixture.transportRequests.last.organization, 'company-a');
    expect(fixture.transportRequests.last.authorization,
        'Bearer layout-test-access');
    await api.forgetOrganization();
    await api.selectOrganization('company-b');
    expect(fixture.transportRequests.last.authorization, isNull);
    expect((await api.loadLoginPreference()).login, '');
    await api.login('bob', 'test');
    expect(api.cacheUserKey,
        isNot(owner)); // Fixture intentionally reuses user ID.
    await api.forgetOrganization();
    await api.selectOrganization('company-a');
    expect((await api.loadLoginPreference()).login, 'alice');
    expect(api.hasSession, isFalse);
  });

  test('employee cache is not reused for identical user IDs in another company',
      () async {
    await api.login('admin', 'test');
    final people = EmployeesStorage();
    await people.load();
    await api.forgetOrganization();
    await api.selectOrganization('company-b');
    await api.login('admin', 'test');
    fixture.responder = (method, uri, body) => uri.path.endsWith('/employees')
        ? [
            {...fixture.employees.first, 'full_name': 'Другой сотрудник'}
          ]
        : fixture.reply(method, uri, body);
    expect((await people.load()).single.fullName, 'Другой сотрудник');
  });

  test('late response from previous company is discarded', () async {
    await api.login('admin', 'test');
    final started = Completer<void>();
    final response = Completer<Object?>();
    fixture.responder = (method, uri, body) {
      if (uri.path == '/o/company-a/api/v1/employees') {
        started.complete();
        return response.future;
      }
      return fixture.reply(method, uri, body);
    };
    final pending = expectLater(
        api.request('GET', '/api/v1/employees'),
        throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'status', 409)));
    await started.future;
    await api.forgetOrganization();
    await api.selectOrganization('company-b');
    await api.login('admin', 'test');
    response.complete(fixture.employees);
    await pending;
    expect(api.organization!.code, 'company-b');
    expect(api.hasSession, isTrue);
  });

  test('late login cannot replace a newer organization session', () async {
    final started = Completer<void>();
    final response = Completer<Object?>();
    fixture.responder = (method, uri, body) {
      if (uri.path == '/o/company-a/api/v1/auth/login') {
        started.complete();
        return response.future;
      }
      return fixture.reply(method, uri, body);
    };
    final pending =
        expectLater(api.login('old', 'test'), throwsA(isA<ApiException>()));
    await started.future;
    await api.forgetOrganization();
    await api.selectOrganization('company-b');
    await api.login('new', 'test');
    response.complete(fixture.reply(
        'POST', Uri.parse('/o/company-a/api/v1/auth/login'), null));
    await pending;
    expect(api.organization!.code, 'company-b');
    expect((await api.loadLoginPreference()).login, 'new');
  });

  test('incorrect organization response header and token pair are rejected',
      () async {
    fixture.responseOrganizationOverride = 'wrong-company';
    await expectLater(api.login('admin', 'test'), throwsA(isA<ApiException>()));
    expect(api.hasSession, isFalse);
    fixture.responseOrganizationOverride = null;
    fixture.responder = (method, uri, body) => uri.path.endsWith('/auth/login')
        ? {
            ...fixture.reply(method, uri, body) as Map,
            'organization': {'code': 'wrong-company', 'name': 'Wrong'}
          }
        : fixture.reply(method, uri, body);
    await expectLater(api.login('admin', 'test'), throwsA(isA<ApiException>()));
    expect(api.hasSession, isFalse);
  });
}
