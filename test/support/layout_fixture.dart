import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shift_tracker/features/auth/auth_service.dart';
import 'package:shift_tracker/core/api_client.dart';

/// In-memory HTTP only. Layout tests never connect to the production API.
class LayoutFixture extends HttpOverrides {
  static const employeeName =
      'Константинопольский Александр Александрович-Северный';
  static const departmentName =
      'Отдел эксплуатации и технического обслуживания производственного оборудования';
  static const groupName =
      'Группа технического обслуживания производственного оборудования';
  static const positionName =
      'Ведущий специалист по техническому обслуживанию оборудования';
  final unhandled = <String>[];
  final requests = <({String method, String path, Object? body})>[];
  final storage = <String, String>{};
  FutureOr<Object?> Function(String method, Uri uri, Object? body)? responder;
  String? responseOrganizationOverride;
  final transportRequests = <({
    String method,
    Uri uri,
    String? authorization,
    String? organization
  })>[];
  late Directory directory;

  final roles = [
    {
      'id': 'super_admin',
      'name': 'Суперадмин',
      'scope_kind': 'all',
      'permissions': <String>[],
      'is_system': true
    },
    {
      'id': 'worker',
      'name': 'Сотрудник производственного подразделения',
      'scope_kind': 'self',
      'permissions': ['viewCalendar', 'viewEmployees', 'viewAttendance'],
      'is_system': true
    },
  ];

  Map<String, Object?> get user => {
        'id': 'layout-user',
        'login': 'alexander.long.login',
        'role': roles.first,
        'last_name': 'Константинопольский',
        'first_name': 'Александр',
        'middle_name': 'Александрович-Северный',
        'department_id': null,
        'group_id': null,
        'employee_id': 'employee-1',
      };

  List<Map<String, Object?>> get employees => [
        for (var n = 1; n <= 3; n++)
          {
            'id': 'employee-$n',
            'full_name': n == 1 ? employeeName : '$employeeName $n',
            'position_id': 'position-1',
            'position_name': positionName,
            'department_id': 'department-1',
            'group_id': 'group-1',
            'salary': 0,
            'bonus': 0,
            'schedule_type': 'custom',
            'schedule_start_date': '2026-01-01',
            'shift_hours': 12,
            'break_hours': 1,
            'custom_workdays': [1, 2, 3, 4, 5, 6, 7],
            'is_active': true,
          }
      ];

  Object? reply(String method, Uri uri, Object? body) {
    final path = uri.path.replaceFirst(RegExp(r'^/o/[a-z0-9-]+'), '');
    final organizationCode =
        uri.pathSegments.length > 1 && uri.pathSegments.first == 'o'
            ? uri.pathSegments[1]
            : 'tehnodor-sk';
    requests.add((method: method, path: path, body: body));
    if (path == '/api/v1/organization') {
      return {'code': organizationCode, 'name': 'ООО «Технодор СК»'};
    }
    if (path == '/api/v1/auth/login' || path == '/api/v1/auth/refresh') {
      return {
        'access_token': 'layout-test-access',
        'refresh_token': 'layout-test-refresh',
        'expires_in': 3600,
        'user': user,
        'organization': {'code': organizationCode, 'name': 'ООО «Технодор СК»'}
      };
    }
    if (path == '/api/v1/auth/me') return user;
    if (path == '/api/v1/auth/bootstrap/status') return {'required': false};
    if (path == '/api/v1/roles') return roles;
    if (path == '/api/v1/users') return [user];
    if (path == '/api/v1/employees') return employees;
    if (path == '/api/v1/employees/employee-1') return employees.first;
    if (path == '/api/v1/departments') {
      return [
        {'id': 'department-1', 'name': departmentName}
      ];
    }
    if (path == '/api/v1/groups') {
      return [
        {'id': 'group-1', 'department_id': 'department-1', 'name': groupName}
      ];
    }
    if (path == '/api/v1/positions') {
      return [
        {'id': 'position-1', 'name': positionName}
      ];
    }
    if (path == '/api/v1/preferences') return {'settings': <String, Object?>{}};
    if (path == '/api/v1/reports/delivery') {
      return {
        'configured': false,
        'bot_username': null,
        'chat_id': null,
        'chat_title': null,
        'candidate_chat_id': null,
        'candidate_title': null,
        'enabled': false,
        'next_run_at': null,
        'last_status': null,
        'last_run_at': null,
        'settings': {
          'enabled': false,
          'cadence': 'monthly',
          'weekday': 1,
          'month_day': 1,
          'hour': 9,
          'minute': 0,
          'timezone': 'Asia/Yekaterinburg',
          'period': 'previous',
          'department_id': null,
          'group_id': null,
          'include_unfinished': false
        }
      };
    }
    if (path == '/api/v1/reports/month') {
      return {
        'days_in_month': 31,
        'rows': [
          for (final employee in employees)
            {
              'employee_id': employee['id'],
              'full_name': employee['full_name'],
              'department_id': 'department-1',
              'department': departmentName,
              'group_id': 'group-1',
              'group': groupName,
              'position': positionName,
              'total_minutes': 1320,
              'missing_days': 2,
              'open_days': 3,
              'days': List.generate(
                  31,
                  (i) => {
                        'date': '2026-08-${(i + 1).toString().padLeft(2, '0')}',
                        'value': ['11к', 'о 11', 'б/с'][i % 3],
                        'planned': true,
                        'missing': false,
                      }),
            }
        ],
      };
    }
    if (path == '/api/v1/attendance') {
      final first = DateTime.parse(uri.queryParameters['date_from']!);
      final last = DateTime.parse(uri.queryParameters['date_to']!);
      return {
        for (var date = first;
            !date.isAfter(last);
            date = date.add(const Duration(days: 1)))
          date.toIso8601String().split('T').first: {
            'employee-1': {
              'fact': 'worked',
              'workedMinutes': 360,
              'comment': 'Старая отметка без времени',
              'closed': false
            },
            '_meta': {'closed': false},
          }
      };
    }
    if (path.startsWith('/api/v1/attendance/') && method != 'GET') return null;
    if (path == '/api/v1/auth/logout') return null;
    unhandled.add('$method $path');
    return <String, Object?>{};
  }

  Future<void> install() async {
    await initializeDateFormatting('ru_RU');
    final fontPath = Platform.environment['LAYOUT_AUDIT_FONT'];
    if (fontPath != null) {
      final data = ByteData.sublistView(await File(fontPath).readAsBytes());
      for (final family in ['Segoe UI', 'Roboto']) {
        await (FontLoader(family)..addFont(Future.value(data))).load();
      }
      await (FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
          .load();
    }
    directory = await Directory.systemTemp.createTemp('shift-layout-tests-');
    HttpOverrides.global = this;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return storage[key];
        case 'write':
          storage[key!] = args['value'] as String;
          return null;
        case 'delete':
          storage.remove(key);
          return null;
        case 'readAll':
          return storage;
        case 'deleteAll':
          storage.clear();
          return null;
        case 'containsKey':
          return storage.containsKey(key);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => directory.path);
    await ApiClient.instance.selectOrganization('tehnodor-sk');
    final result = await AuthService.instance
        .loginDetailed('layout', 'test-only', rememberSession: false);
    if (!result.ok) {
      throw StateError('Layout fixture login failed: ${result.error}');
    }
  }

  Future<void> dispose() async {
    HttpOverrides.global = null;
    // Only the random, test-created directory is removed.
    assert(directory.path.contains('shift-layout-tests-'));
    await directory.delete(recursive: true);
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(this);
}

class _Client implements HttpClient {
  final LayoutFixture fixture;
  _Client(this.fixture);
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _Request(fixture, method, url);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  final Map<String, String> values = {};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  set contentType(ContentType? value) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  final LayoutFixture fixture;
  @override
  final String method;
  final Uri url;
  Object? body;
  _Request(this.fixture, this.method, this.url);
  @override
  final HttpHeaders headers = _Headers();
  @override
  void write(Object? object) {
    body = jsonDecode(object.toString());
  }

  @override
  Future<HttpClientResponse> close() async {
    fixture.transportRequests.add((
      method: method,
      uri: url,
      authorization: headers.value('Authorization'),
      organization: headers.value('X-Organization-Code')
    ));
    final value = await (fixture.responder?.call(method, url, body) ??
        fixture.reply(method, url, body));
    return _Response(
        value, fixture.responseOrganizationOverride ?? url.pathSegments[1]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  final List<int> bytes;
  _Response(Object? value, String code)
      : bytes = value == null ? [] : utf8.encode(jsonEncode(value)),
        headers = (_Headers()..set('X-Organization-Code', code));
  @override
  final HttpHeaders headers;
  @override
  int get statusCode => 200;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream<List<int>>.value(bytes).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
