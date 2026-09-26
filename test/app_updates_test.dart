import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shift_tracker/core/api_client.dart';
import 'package:shift_tracker/features/updates/app_release.dart';
import 'package:shift_tracker/features/updates/app_update_service.dart';

import 'support/layout_fixture.dart';

const _channel = MethodChannel('chereda/app_updates');
final _payload = utf8.encode('test-only update payload, never installed');

Map<String, Object?> _manifest({String platform = 'android', int build = 14,
    Map<String, Object?> overrides = const {}}) => {
  'schema': 1,
  platform: {
    'version': '1.7.1',
    'build': build,
    'url': 'https://api.mezamir.com/updates/chereda-$build.${platform == 'android' ? 'apk' : 'zip'}',
    'sha256': sha256.convert(_payload).toString(),
    'size': _payload.length,
    'notes': ['Проверка обновлений'],
    ...overrides,
  },
};

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(List<int> bytes, {this.statusCode = 200, int? size})
      : contentLength = size ?? bytes.length,
        body = Stream<List<int>>.value(bytes);
  _Response.chunks(List<List<int>> chunks, {required this.contentLength})
      : statusCode = 200, body = Stream<List<int>>.fromIterable(chunks);
  _Response.json(Object value, {int status = 200})
      : this(utf8.encode(jsonEncode(value)), statusCode: status);
  final Stream<List<int>> body;
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      body.listen(onData, onError: onError, onDone: onDone,
          cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.uri, this.respond);
  final Uri uri;
  final FutureOr<HttpClientResponse> Function(Uri) respond;
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => respond(uri);
  // No headers, cookies or credentials are exposed by this fake. A new attempt
  // to attach session information must therefore fail these download tests.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  _Client(this.respond);
  final FutureOr<HttpClientResponse> Function(Uri) respond;
  final requests = <_Request>[];
  bool closed = false;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    final request = _Request(uri, respond);
    requests.add(request);
    return request;
  }
  @override
  void close({bool force = false}) { closed = true; }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness(this.directory);
  final Directory directory;
  final clients = <_Client>[];
  Map<String, Object?> manifest = _manifest();
  FutureOr<HttpClientResponse> Function(Uri)? override;
  int installedBuild = 13;
  AppUpdateService create() => AppUpdateService(
    platform: 'android',
    temporaryDirectory: () async => directory,
    appInfo: () async => {'version': '1.7.0', 'build': installedBuild,
      'packageName': 'com.example.shift_tracker'},
    httpClient: () {
      final client = _Client((uri) => override?.call(uri) ??
          (uri == AppRelease.metadataUrl
            ? _Response.json(manifest) : _Response(_payload)));
      clients.add(client);
      return client;
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = LayoutFixture();
  late Directory directory;
  late _Harness harness;
  late AppUpdateService service;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(fixture.install);
  tearDownAll(fixture.dispose);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chereda-updater-test-');
    harness = _Harness(directory);
    service = harness.create();
  });
  tearDown(() async {
    fixture.responder = null;
    messenger.setMockMethodCallHandler(_channel, null);
    ApiClient.instance.endAppUpdate();
    service.dispose();
    // Only the unique temporary directory created by this test is removed.
    expect(directory.path, contains('chereda-updater-test-'));
    await directory.delete(recursive: true);
  });

  test('accepts both platforms and normalizes a valid SHA-256', () {
    for (final platform in ['android', 'windows']) {
      final release = AppRelease.fromManifest(_manifest(platform: platform,
          overrides: {'sha256': sha256.convert(_payload).toString().toUpperCase()}), platform);
      expect(release.build, 14);
      expect(release.sha256, sha256.convert(_payload).toString());
      expect(release.notes, ['Проверка обновлений']);
    }
  });

  test('rejects malformed metadata and untrusted download locations', () {
    for (final values in <Map<String, Object?>>[
      {'version': '1.7'}, {'version': '1.7.1+14'}, {'build': 0}, {'build': 14.5},
      {'sha256': 'abc'}, {'size': 0}, {'size': AppRelease.maxSize + 1},
      {'notes': [123]}, {'notes': List.filled(21, 'note')},
      {'url': 'http://api.mezamir.com/updates/new.apk'},
      {'url': 'https://other.example/updates/new.apk'},
      {'url': 'https://api.mezamir.com.evil.example/updates/new.apk'},
      {'url': 'https://user@api.mezamir.com/updates/new.apk'},
      {'url': 'https://api.mezamir.com:8443/updates/new.apk'},
      {'url': 'https://api.mezamir.com/api/new.apk'},
      {'url': 'https://api.mezamir.com/updates/new.apk?token=secret'},
      {'url': 'https://api.mezamir.com/updates/new.apk#fragment'},
      {'url': 'https://api.mezamir.com/updates/new.zip'},
      {'url': 'https://api.mezamir.com/updates/%2f..%2fnew.apk'},
      {'url': 'https://api.mezamir.com/updates/%5c..%5cnew.apk'},
    ]) {
      expect(() => AppRelease.fromManifest(_manifest(overrides: values), 'android'),
          throwsFormatException, reason: '$values');
    }
    expect(() => AppRelease.fromManifest({'schema': 2}, 'android'), throwsFormatException);
    expect(() => AppRelease.fromManifest(_manifest(), 'windows'), throwsFormatException);
    expect(() => AppRelease.fromManifest(_manifest(), 'linux'), throwsFormatException);
  });

  test('only a higher build is offered; failed checks can be retried', () async {
    harness.override = (_) => throw const SocketException('offline test');
    await service.check();
    expect(service.error, isNotNull);
    expect(service.checkedAt, isNull);
    harness.override = null;
    harness.manifest = _manifest(build: 13);
    await service.check();
    expect(service.hasUpdate, isFalse);
    expect(service.phase, UpdatePhase.idle);
    expect(service.error, isNull);
    harness.manifest = _manifest(build: 12);
    await service.check(force: true);
    expect(service.hasUpdate, isFalse);
    harness.manifest = _manifest(build: 14);
    await service.check(force: true);
    expect(service.release?.build, 14);
    expect(service.phase, UpdatePhase.available);
    expect(service.checkedAt, isNotNull);
    expect(harness.clients.every((c) => c.closed), isTrue);
    expect(harness.clients.expand((c) => c.requests).every((r) => !r.followRedirects), isTrue);
  });

  test('never follows redirects and rejects oversized release descriptions', () async {
    harness.override = (_) => _Response([], statusCode: 302);
    await service.check();
    expect(service.error, isNotNull);
    expect(service.hasUpdate, isFalse);
    expect(harness.clients.single.requests.single.followRedirects, isFalse);
    harness.override = (_) => _Response(List.filled(65537, 32));
    await service.check(force: true);
    expect(service.error, contains('размер'));
    expect(service.checkedAt, isNull);
  });

  test('downloads only verified bytes and renames the completed private file', () async {
    await service.check();
    await service.download();
    expect(service.phase, UpdatePhase.ready);
    expect(service.progress, 1);
    expect(service.error, isNull);
    final files = await directory.list(recursive: true).where((f) => f is File).toList();
    expect(files, hasLength(1));
    expect(files.single.path, contains('app-updates'));
    expect(files.single.path, endsWith('.apk'));
    expect(await (files.single as File).readAsBytes(), _payload);
    expect(harness.clients.every((c) => c.closed), isTrue);
  });

  test('rejects checksum and size failures, removes partial files, then retries', () async {
    await service.check();
    for (final response in [
      _Response(List.filled(_payload.length, 0)),
      _Response(_payload, size: _payload.length + 1),
      _Response(_payload.sublist(1), size: -1),
      _Response([..._payload, 0], size: -1),
    ]) {
      harness.override = (_) => response;
      await service.download();
      expect(service.phase, UpdatePhase.available);
      expect(service.error, isNotNull);
      expect(await directory.list(recursive: true).where((f) => f is File).toList(), isEmpty);
    }
    harness.override = null;
    await service.download();
    expect(service.phase, UpdatePhase.ready);
    expect(service.error, isNull);
  });

  test('cancellation leaves no APK or partial file and permits a fresh download', () async {
    await service.check();
    harness.override = (_) => _Response.chunks([
      _payload.sublist(0, 5), _payload.sublist(5),
    ], contentLength: _payload.length);
    void cancelAfterFirstBytes() {
      if (service.phase == UpdatePhase.downloading && service.progress > 0) {
        service.cancelDownload();
      }
    }
    service.addListener(cancelAfterFirstBytes);
    await service.download();
    service.removeListener(cancelAfterFirstBytes);
    expect(service.phase, UpdatePhase.available);
    expect(service.message, contains('отменена'));
    expect(service.error, isNull);
    expect(await directory.list(recursive: true).where((f) => f is File).toList(), isEmpty);
    harness.override = null;
    await service.download();
    expect(service.phase, UpdatePhase.ready);
  });

  test('waits for an in-flight save and requires explicit retry after Android permission', () async {
    await service.check();
    await service.download();
    final saveStarted = Completer<void>();
    final finishSave = Completer<Object?>();
    fixture.responder = (method, uri, body) {
      if (method == 'PUT') {
        saveStarted.complete();
        return finishSave.future;
      }
      return null;
    };
    final saving = ApiClient.instance.request('PUT', '/api/v1/attendance/2026-09-23',
        body: {'employee_id': 'employee-1', 'worked_minutes': 480});
    await saveStarted.future;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return calls.length == 1 ? 'permission_required' : 'installer_opened';
    });
    await service.install();
    expect(calls, isEmpty);
    expect(service.error, contains('сохранения'));
    expect(service.phase, UpdatePhase.ready);
    finishSave.complete({'ok': true});
    await saving;
    await service.install();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'installApk');
    expect((calls.single.arguments as Map)['sha256'], sha256.convert(_payload).toString());
    expect((calls.single.arguments as Map)['build'], 14);
    expect(service.message, contains('ещё раз'));
    expect(service.phase, UpdatePhase.ready);
    await Future<void>.delayed(Duration.zero);
    expect(calls, hasLength(1)); // Returning from permissions must not auto-install.
    await service.install();
    expect(calls, hasLength(2));
    expect(service.message, contains('системном установщике'));
  });

  test('blocks new saves during installation and releases the guard on native error', () async {
    await service.check();
    await service.download();
    final installStarted = Completer<void>();
    final finishInstall = Completer<void>();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      installStarted.complete();
      await finishInstall.future;
      throw PlatformException(code: 'invalid_update', message: 'Подпись не совпадает.');
    });
    final installation = service.install();
    await installStarted.future;
    final before = fixture.transportRequests.length;
    await expectLater(ApiClient.instance.request('PUT', '/api/v1/attendance/2026-09-23',
        body: {'worked_minutes': 480}), throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 409)));
    expect(fixture.transportRequests, hasLength(before));
    finishInstall.complete();
    await installation;
    expect(service.phase, UpdatePhase.ready);
    expect(service.error, 'Подпись не совпадает.');
    expect(ApiClient.instance.beginAppUpdate(), isTrue);
    ApiClient.instance.endAppUpdate();
  });
}
