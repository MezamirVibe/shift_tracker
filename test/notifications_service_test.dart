import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/core/api_client.dart';
import 'package:shift_tracker/features/notifications/notifications_service.dart';

import 'support/layout_fixture.dart';

const _channel = MethodChannel('chereda/notifications');
const _eventId = '4528b178-2979-4b13-a198-c9a3ea7dbd87';
const _deviceId = '5941a31c-9e4b-459f-a2b9-201a670658c6';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NotificationsService service;
  final calls = <MethodCall>[];
  late LayoutFixture fixture;
  late Map<String, dynamic> preferences;
  late Map<String, dynamic> event;
  late List<String> opened;
  bool failSave = false;

  setUp(() async {
    calls.clear();
    opened = [];
    failSave = false;
    preferences = {
      'push_enabled': true,
      'push_available': true,
      'kinds': {'hours_closed': true},
      'quiet_hours_enabled': false,
    };
    event = {
      'id': _eventId,
      'kind': 'hours_closed',
      'title': 'День закрыт',
      'body': 'Учтено 11 ч',
      'day': '2026-09-24',
      'created_at': '2026-09-24T12:00:00Z',
      'read_at': null,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.method == 'status' || call.method == 'requestPermission') {
        return {
          'supported': true,
          'configured': true,
          'permission': 'granted',
          'installation_id': _deviceId,
          'token': 'test-device-token-not-real',
        };
      }
      return null;
    });
    fixture = LayoutFixture();
    fixture.responder = (method, uri, body) {
      final path = uri.path.replaceFirst(RegExp(r'^/o/[^/]+'), '');
      if (path == '/api/v1/notifications/preferences') {
        if (method == 'PUT') {
          if (failSave)
            throw const ApiException(503, 'Test connection failure');
          final patch = Map<String, dynamic>.from(body as Map);
          preferences = {
            ...preferences,
            ...patch,
            'kinds': {
              ...preferences['kinds'] as Map,
              ...?patch['kinds'] as Map?
            }
          };
        }
        return Map<String, dynamic>.from(preferences);
      }
      if (path == '/api/v1/notifications') {
        return {
          'items': [event],
          'next_cursor': null,
          'unread_count': 1
        };
      }
      if (path == '/api/v1/notifications/$_eventId/read') {
        return {...event, 'read_at': '2026-09-24T13:00:00Z'};
      }
      if (path.startsWith('/api/v1/notifications/devices')) {
        return {'registered': true};
      }
      return fixture.reply(method, uri, body);
    };
    await fixture.install();
    service = NotificationsService.instance;
    service.clearSession();
    service.setForeground(false);
    service.onOpen = opened.add;
    await service.syncSession(signedIn: true);
  });

  tearDown(() async {
    service.onOpen = null;
    service.clearSession();
    await ApiClient.instance.clearSession();
    await Future<void>.delayed(Duration.zero);
    // Windows can briefly retain a handle from the authentication cache write.
    try {
      await fixture.dispose();
    } on FileSystemException catch (error) {
      if (![32, 145].contains(error.osError?.errorCode)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await fixture.dispose();
    }
  });

  test('refresh keeps delivered notifications and never prompts for permission',
      () async {
    expect(service.items.single.body, 'Учтено 11 ч');
    expect(service.preferencesLoaded, isTrue);
    expect(calls.where((c) => c.method == 'requestPermission'), isEmpty);
    calls.clear();
    await service.refresh();
    expect(
        calls
            .where((c) => c.method == 'configure')
            .every((c) => (c.arguments as Map)['enabled'] == true),
        isTrue);
    expect(calls.where((c) => c.method == 'clear'), isEmpty);
  });

  test(
      'master and individual switches retain inbox without implicit permission',
      () async {
    await service.savePreferences({
      'kinds': {'hours_closed': false}
    });
    expect(service.preferences.kinds['hours_closed'], isFalse);
    expect(
        (calls.lastWhere((c) => c.method == 'configure').arguments
            as Map)['kinds']['hours_closed'],
        isFalse);
    await service.savePreferences({'push_enabled': false});
    expect(service.preferences.pushEnabled, isFalse);
    expect(service.items, hasLength(1));
    expect(
        (calls.lastWhere((c) => c.method == 'configure').arguments
            as Map)['enabled'],
        isFalse);
    expect(calls.where((c) => c.method == 'requestPermission'), isEmpty);
  });

  test('failed save is reported and not presented as disabled', () async {
    failSave = true;
    await service.savePreferences({'push_enabled': false});
    expect(service.preferences.pushEnabled, isTrue);
    expect(service.lastError, contains('не подтверждены сервером'));
    expect(service.saving, isFalse);
  });

  test('signed-out cold start clears a native binding even with no Dart owner',
      () async {
    service.clearSession();
    await Future<void>.delayed(Duration.zero);
    calls.clear();
    await service.syncSession(signedIn: false);
    await Future<void>.delayed(Duration.zero);
    expect(calls.any((c) => c.method == 'clear'), isTrue);
    expect(service.items, isEmpty);
    expect(service.unreadCount, 0);
  });

  test('inflight refresh cannot restore another account notification content',
      () async {
    final gate = Completer<Object?>();
    final previous = fixture.responder!;
    fixture.responder = (method, uri, body) {
      if (uri.path.endsWith('/notifications')) return gate.future;
      return previous(method, uri, body);
    };
    final pending = service.refresh();
    await Future<void>.delayed(Duration.zero);
    service.clearSession();
    gate.complete({
      'items': [event],
      'unread_count': 1,
      'next_cursor': null
    });
    await pending;
    expect(service.items, isEmpty);
    expect(service.preferencesLoaded, isFalse);
    expect(service.loading, isFalse);
  });

  test('native tap validates binding and fetches exact authorized event',
      () async {
    final binding = (calls.lastWhere((c) => c.method == 'configure').arguments
        as Map)['binding_id'];
    Future<void> tap(String bindingId) async {
      final done = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
              _channel.name,
              const StandardMethodCodec()
                  .encodeMethodCall(MethodCall('notificationOpened', {
                'binding_id': bindingId,
                'notification_id': _eventId,
              })),
              (_) => done.complete());
      await done.future;
    }

    await tap('another-account-binding');
    expect(opened, isEmpty);
    await tap(binding as String);
    expect(opened.single, '/schedule?date=2026-09-24');
    await service.refresh();
  });
}
