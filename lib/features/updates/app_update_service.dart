import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api_client.dart';
import '../preferences/preferences_service.dart';
import 'app_release.dart';

enum UpdatePhase { idle, checking, available, downloading, ready, installing }

class AppUpdateService extends ChangeNotifier {
  AppUpdateService(
      {String? platform,
      HttpClient Function()? httpClient,
      Future<Directory> Function()? temporaryDirectory,
      Future<Map<Object?, Object?>?> Function()? appInfo})
      : platform = platform ??
            (Platform.isAndroid
                ? 'android'
                : Platform.isWindows
                    ? 'windows'
                    : 'unsupported'),
        _httpClient = httpClient ?? HttpClient.new,
        _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
        _appInfo = appInfo ??
            (() => _channel.invokeMapMethod<Object?, Object?>('appInfo'));

  static final instance = AppUpdateService();
  static const _channel = MethodChannel('chereda/app_updates');
  final String platform;
  final HttpClient Function() _httpClient;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<Map<Object?, Object?>?> Function() _appInfo;
  UpdatePhase phase = UpdatePhase.idle;
  AppRelease? release;
  String? installedVersion;
  int? installedBuild;
  String? error;
  String? message;
  String? installNotice;
  DateTime? checkedAt;
  double progress = 0;
  File? _download;
  HttpClient? _activeClient;
  bool _cancelled = false;
  bool get supported => platform == 'android' || platform == 'windows';
  bool get busy =>
      phase == UpdatePhase.checking ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.installing;
  bool get hasUpdate => release != null;

  Future<HttpClientResponse> _get(HttpClient client, Uri uri) async {
    if (!AppRelease.trustedUrl(uri)) {
      throw const FormatException('Недопустимый адрес обновления.');
    }
    final request =
        await client.getUrl(uri).timeout(const Duration(seconds: 20));
    // This client never carries session tokens, organization headers or cookies.
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw const HttpException(
          'Не удалось получить обновление. Попробуйте позже.');
    }
    return response;
  }

  Future<void> check({bool force = false}) async {
    if (!supported || busy || phase == UpdatePhase.ready) return;
    if (!force &&
        checkedAt != null &&
        DateTime.now().difference(checkedAt!) < const Duration(hours: 6)) {
      return;
    }
    phase = UpdatePhase.checking;
    error = null;
    message = null;
    notifyListeners();
    final client = _httpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final info = await _appInfo().timeout(const Duration(seconds: 10));
      if (info?['version'] is! String || info?['build'] is! int) {
        throw const FormatException(
            'Не удалось определить установленную версию.');
      }
      installedVersion = info!['version'] as String;
      installedBuild = info['build'] as int;
      final response = await _get(client, AppRelease.metadataUrl);
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 65536) {
          throw const FormatException(
              'Некорректный размер описания обновления.');
        }
      }
      final next =
          AppRelease.fromManifest(jsonDecode(utf8.decode(bytes)), platform);
      release = next.build > installedBuild! ? next : null;
      checkedAt = DateTime.now();
      message = release == null ? 'Установлена актуальная версия.' : null;
    } catch (e) {
      error = _readableError(e);
    } finally {
      client.close(force: true);
      phase = release == null ? UpdatePhase.idle : UpdatePhase.available;
      notifyListeners();
    }
  }

  Future<void> download() async {
    final next = release;
    if (next == null || busy || phase == UpdatePhase.ready) return;
    phase = UpdatePhase.downloading;
    progress = 0;
    error = null;
    message = null;
    _cancelled = false;
    notifyListeners();
    final client = _httpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    _activeClient = client;
    File? partial;
    RandomAccessFile? output;
    try {
      final directory =
          Directory('${(await _temporaryDirectory()).path}/app-updates');
      await directory.create(recursive: true);
      final extension = platform == 'android' ? 'apk' : 'zip';
      final target = File(
          '${directory.path}/chereda-${next.build}-${next.sha256}.$extension');
      partial = File('${target.path}.part');
      final response = await _get(client, next.url);
      if (response.contentLength != -1 && response.contentLength != next.size) {
        throw const FormatException('Размер файла обновления не совпадает.');
      }
      output = await partial.open(mode: FileMode.write);
      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (_cancelled) throw const HttpException('Загрузка отменена.');
        received += chunk.length;
        if (received > next.size) {
          throw const FormatException('Размер файла обновления не совпадает.');
        }
        progress = received / next.size;
        await output.writeFrom(chunk);
        notifyListeners();
      }
      await output.flush();
      await output.close();
      output = null;
      if (_cancelled) throw const HttpException('Загрузка отменена.');
      if (received != next.size ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              next.sha256) {
        throw const FormatException(
            'Файл обновления повреждён. Скачайте его повторно.');
      }
      if (_cancelled) throw const HttpException('Загрузка отменена.');
      _download = await partial.rename(target.path);
      phase = UpdatePhase.ready;
      message = 'Файл проверен. Можно установить обновление.';
    } catch (e) {
      if (!_cancelled) error = _readableError(e);
      message =
          _cancelled ? 'Загрузка отменена. Можно продолжать работу.' : null;
      phase = UpdatePhase.available;
    } finally {
      client.close(force: true);
      _activeClient = null;
      try {
        await output?.close();
      } on FileSystemException {
        // A locked partial file is never offered to the installer.
      }
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } on FileSystemException {
        // Retry can replace only this updater-owned partial file.
      }
      notifyListeners();
    }
  }

  void cancelDownload() {
    if (phase != UpdatePhase.downloading) return;
    _cancelled = true;
    _activeClient?.close(force: true);
  }

  void retryDownload() {
    if (busy) return;
    _download = null;
    error = null;
    message = null;
    phase = release == null ? UpdatePhase.idle : UpdatePhase.available;
    notifyListeners();
  }

  Future<void> install() async {
    final next = release;
    final file = _download;
    if (phase != UpdatePhase.ready || next == null || file == null) return;
    if (PreferencesService.instance.saving ||
        !ApiClient.instance.beginAppUpdate()) {
      error = 'Дождитесь завершения сохранения данных и повторите установку.';
      notifyListeners();
      return;
    }
    phase = UpdatePhase.installing;
    error = null;
    message = null;
    notifyListeners();
    try {
      if (platform == 'android') {
        final result = await _channel.invokeMethod<String>('installApk', {
          'path': file.path,
          'sha256': next.sha256,
          'build': next.build,
        });
        message = result == 'permission_required'
            ? 'Разрешите установку для «Череды» в открывшихся настройках, затем вернитесь и нажмите «Установить» ещё раз.'
            : 'Подтвердите обновление в системном установщике. Если вы отменили его, можно повторить установку.';
      } else if (platform == 'windows') {
        await _installWindows(file, next);
      }
    } catch (e) {
      error = _readableError(e);
    } finally {
      ApiClient.instance.endAppUpdate();
      phase = UpdatePhase.ready;
      notifyListeners();
    }
  }

  Future<void> _installWindows(File archive, AppRelease next) async {
    final directory = archive.parent;
    final token = DateTime.now().microsecondsSinceEpoch;
    final helper = File('${directory.path}/windows-update-$token.ps1');
    final ready = File('${directory.path}/ready-$token.txt');
    final commit = File('${directory.path}/commit-$token.txt');
    final log = File('${directory.path}/result-$token.log');
    await helper.writeAsString(
        await rootBundle.loadString('assets/updater/windows_update.ps1'),
        flush: true);
    final statusFile = File(
        '${(await getApplicationSupportDirectory()).path}/chereda-update-status.json');
    await statusFile.parent.create(recursive: true);
    await statusFile.writeAsString(
        jsonEncode({'log': log.path, 'build': next.build}),
        flush: true);
    final powershell =
        '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
    await Process.start(
        powershell,
        [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          helper.path,
          '-ArchivePath',
          archive.path,
          '-ExpectedSha256',
          next.sha256,
          '-InstallDirectory',
          File(Platform.resolvedExecutable).parent.path,
          '-ParentProcessId',
          '$pid',
          '-ExpectedVersion',
          '${next.version}.${next.build}',
          '-LogPath',
          log.path,
          '-ReadyPath',
          ready.path,
          '-CommitPath',
          commit.path,
        ],
        mode: ProcessStartMode.detached);
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      if (await log.exists() &&
          (await log.readAsString()).contains(' ERROR ')) {
        throw FileSystemException(
            'Не удалось подготовить обновление. Приложение не изменено. Проверьте права на папку приложения. Журнал: ${log.path}');
      }
      if (await ready.exists() &&
          (await ready.readAsString()).trim() == 'READY') {
        // The helper has verified and staged the archive. New API writes are
        // blocked and all earlier writes completed before we reached this point.
        try {
          await commit.writeAsString('COMMIT', flush: true);
        } catch (_) {
          if (await commit.exists()) await commit.delete();
          rethrow;
        }
        exit(0);
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw const FileSystemException(
        'Подготовка заняла слишком много времени. Приложение не закрыто. Повторите установку через две минуты.');
  }

  Future<void> readPreviousInstallResult() async {
    if (platform != 'windows') return;
    try {
      final status = File(
          '${(await getApplicationSupportDirectory()).path}/chereda-update-status.json');
      if (!await status.exists()) return;
      final data = jsonDecode(await status.readAsString()) as Map;
      final log = File(data['log'] as String);
      final text = await log.exists() ? await log.readAsString() : '';
      if (text.contains(' ERROR ')) {
        installNotice =
            'Обновление не завершено. Подробнее в журнале: ${log.path}';
      } else if (text.contains(' SUCCESS ')) {
        installNotice = 'Обновление установлено.';
      } else {
        installNotice =
            'Предыдущее обновление не завершено. Проверьте версию и повторите установку.';
      }
      await status
          .delete(); // Only our consumed status marker, never user data.
      notifyListeners();
    } catch (_) {/* A missing diagnostic must never prevent app startup. */}
  }

  String _readableError(Object e) {
    if (e is PlatformException) {
      return e.message ?? 'Не удалось открыть установщик.';
    }
    if (e is FormatException) return e.message;
    if (e is FileSystemException) return e.message;
    if (e is HttpException) return e.message;
    return 'Не удалось проверить или скачать обновление. Проверьте интернет и повторите попытку. Работа с табелем доступна как обычно.';
  }
}
