import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'organization.dart';

dynamic _decodeJsonOffMainIsolate(String raw) => jsonDecode(raw);

class ApiException implements Exception {
  final int statusCode;
  final String message;

  const ApiException(this.statusCode, this.message);

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient._();

  static final ApiClient instance = ApiClient._();
  static const baseUrl = String.fromEnvironment(
    'SHIFT_TRACKER_API_URL',
    defaultValue: 'https://api.mezamir.com',
  );

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  String? _accessToken;
  String? _refreshToken;
  DateTime? _accessTokenExpiresAt;
  Map<String, dynamic>? _currentUser;
  Future<bool>? _refreshInFlight;
  bool _persistSession = true;
  bool _sessionInvalidationNotified = false;
  Organization? _organization;
  Organization? get organization => _organization;
  int _sessionEpoch = 0;
  Future<void> _storageQueue = Future<void>.value();
  int get sessionEpoch => _sessionEpoch;
  String get cacheNamespace =>
      '${base64Url.encode(utf8.encode(baseUrl)).replaceAll('=', '')}_${_organization?.code ?? 'unselected'}';
  String? get cacheUserKey =>
      _currentUser == null ? null : '$cacheNamespace|${_currentUser!['id']}';
  String _scopedKey(String key) => '${cacheNamespace}_$key';
  String get _organizationKey =>
      '${base64Url.encode(utf8.encode(baseUrl))}_organization';

  Future<void> restoreOrganization() async {
    if (_organization != null) return;
    final epoch = _sessionEpoch;
    try {
      final raw = await _storage.read(key: _organizationKey);
      _checkEpoch(epoch);
      if (raw != null) {
        _organization = Organization.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
    } catch (_) {
      if (epoch == _sessionEpoch) _organization = null;
    }
  }

  Future<Organization> selectOrganization(String input) async {
    final String code;
    try {
      code = Organization.parseConnection(input);
    } on FormatException catch (error) {
      throw ApiException(400, error.message);
    }
    if (!Organization.codePattern.hasMatch(code)) {
      throw const ApiException(
        400,
        'Код организации: латинские буквы, цифры и дефис, от 2 до 48 символов.',
      );
    }
    if (hasSession) {
      throw const ApiException(409, 'Сначала выйдите из текущего аккаунта.');
    }
    final epoch = _sessionEpoch;
    final data = await request(
      'GET',
      '/api/v1/organization',
      authenticated: false,
      discoveryCode: code,
    ) as Map<String, dynamic>;
    final selected = Organization.fromJson(data);
    if (selected.code != code) {
      throw const ApiException(
        409,
        'Сервер вернул другую организацию. Вход отменён.',
      );
    }
    _checkEpoch(epoch);
    final clearing = clearSession();
    final clearingEpoch = _sessionEpoch;
    await clearing;
    _checkEpoch(clearingEpoch);
    _organization = selected;
    _sessionEpoch++;
    await _storage.write(
      key: _organizationKey,
      value: jsonEncode(selected.toJson()),
    );
    return selected;
  }

  Future<void> forgetOrganization() async {
    final previous = _organization;
    await logout();
    if (!identical(previous, _organization) || hasSession) {
      throw const ApiException(
        409,
        'Сессия уже изменилась. Повторите действие.',
      );
    }
    _organization = null;
    _sessionEpoch++;
    await _storage.delete(key: _organizationKey);
  }

  void _checkEpoch(int epoch) {
    if (epoch != _sessionEpoch) {
      throw const ApiException(
        409,
        'Организация или пользователь изменились. Повторите действие.',
      );
    }
  }

  // Multi-request operations must carry the starting epoch across every await.
  void checkSessionEpoch(int epoch) => _checkEpoch(epoch);

  VoidCallback? onSessionInvalidated;

  static const _accessTokenKey = 'shift_tracker_access_token';
  static const _refreshTokenKey = 'shift_tracker_refresh_token';
  static const _accessTokenExpiresAtKey =
      'shift_tracker_access_token_expires_at';
  static const _currentUserKey = 'shift_tracker_current_user';
  static const _rememberLoginKey = 'shift_tracker_remember_login';
  static const _savedLoginKey = 'shift_tracker_saved_login';

  Map<String, dynamic>? get currentUser => _currentUser;
  bool get hasSession => _accessToken != null && _refreshToken != null;

  Future<void> _saveSession() {
    final persist = hasSession && _persistSession;
    final values = <String, String?>{
      _scopedKey(_accessTokenKey): persist ? _accessToken : null,
      _scopedKey(_refreshTokenKey): persist ? _refreshToken : null,
      _scopedKey(_accessTokenExpiresAtKey):
          persist ? _accessTokenExpiresAt?.toUtc().toIso8601String() : null,
      _scopedKey(_currentUserKey):
          persist && _currentUser != null ? jsonEncode(_currentUser) : null,
    };
    // Snapshot keys/values now and serialize writes: a slow old login must not
    // resurrect tokens after logout or write into the next organization's keys.
    final pending = _storageQueue.then((_) async {
      await Future.wait(
        values.entries.map(
          (entry) => entry.value == null
              ? _storage.delete(key: entry.key)
              : _storage.write(key: entry.key, value: entry.value),
        ),
      );
    });
    _storageQueue = pending.catchError((Object _) {});
    return pending;
  }

  Future<bool> bootstrapRequired() async {
    final result = await request(
      'GET',
      '/api/v1/auth/bootstrap/status',
      authenticated: false,
    );
    return (result as Map<String, dynamic>)['required'] == true;
  }

  Future<({String login, bool remember})> loadLoginPreference() async {
    try {
      final stored = await Future.wait([
        _storage.read(key: _scopedKey(_rememberLoginKey)),
        _storage.read(key: _scopedKey(_savedLoginKey)),
      ]);
      final rememberRaw = stored[0];
      final remember = rememberRaw != 'false';
      final login = stored[1] ?? '';
      return (login: login, remember: remember);
    } catch (_) {
      return (login: '', remember: true);
    }
  }

  Future<void> _saveLoginPreference(String login, bool remember) async {
    await Future.wait([
      _storage.write(
        key: _scopedKey(_rememberLoginKey),
        value: remember.toString(),
      ),
      _storage.write(key: _scopedKey(_savedLoginKey), value: login.trim()),
    ]);
  }

  Future<Map<String, dynamic>> login(
    String login,
    String password, {
    bool rememberSession = true,
  }) async {
    if (_organization == null) {
      throw const ApiException(400, 'Сначала выберите организацию.');
    }
    if (hasSession) {
      throw const ApiException(409, 'Сначала выйдите из текущего аккаунта.');
    }
    final epoch = ++_sessionEpoch;
    _persistSession = rememberSession;
    final result = await request(
      'POST',
      '/api/v1/auth/login',
      authenticated: false,
      body: {'login': login.trim(), 'password': password},
    ) as Map<String, dynamic>;
    _checkEpoch(epoch);
    await _acceptTokenPair(result);
    _checkEpoch(epoch);
    await _saveLoginPreference(login, rememberSession);
    _checkEpoch(epoch);
    return _currentUser!;
  }

  Future<Map<String, dynamic>?> restoreSession() async {
    if (_organization == null) return null;
    final epoch = _sessionEpoch;
    Map<String, dynamic>? cachedUser;
    try {
      final loginPreference = await loadLoginPreference();
      _checkEpoch(epoch);
      _persistSession = loginPreference.remember;
      if (!_persistSession) {
        await clearSession();
        return null;
      }
      final stored = await Future.wait([
        _storage.read(key: _scopedKey(_accessTokenKey)),
        _storage.read(key: _scopedKey(_refreshTokenKey)),
        _storage.read(key: _scopedKey(_currentUserKey)),
        _storage.read(key: _scopedKey(_accessTokenExpiresAtKey)),
      ]);
      _checkEpoch(epoch);
      _accessToken = stored[0];
      _refreshToken = stored[1];
      _accessTokenExpiresAt =
          DateTime.tryParse(stored[3] ?? '') ?? _expiryFromJwt(_accessToken);
      final cachedRaw = stored[2];
      if (cachedRaw != null && cachedRaw.trim().isNotEmpty) {
        final decoded = jsonDecode(cachedRaw);
        if (decoded is Map) {
          cachedUser = Map<String, dynamic>.from(decoded);
          _currentUser = cachedUser;
        }
      }
      if (!hasSession) return null;
      final result = await request('GET', '/api/v1/auth/me');
      _currentUser = Map<String, dynamic>.from(result as Map);
      await _saveSession();
      _checkEpoch(epoch);
      return _currentUser;
    } on ApiException catch (error) {
      if (epoch != _sessionEpoch) return null;
      if (error.statusCode == 401 || error.statusCode == 403) {
        await clearSession();
        return null;
      }
      return cachedUser;
    } catch (_) {
      if (epoch != _sessionEpoch) return null;
      return cachedUser;
    }
  }

  Future<void> logout() async {
    final epoch = _sessionEpoch;
    final refresh = _refreshToken;
    if (refresh != null && _accessToken != null) {
      try {
        await request(
          'POST',
          '/api/v1/auth/logout',
          body: {'refresh_token': refresh},
        );
      } catch (_) {
        // Локальный выход должен сработать даже при отсутствии сети.
      }
    }
    _checkEpoch(epoch);
    await clearSession();
  }

  Future<void> clearSession() async {
    _sessionEpoch++;
    _refreshInFlight = null;
    _accessToken = null;
    _refreshToken = null;
    _accessTokenExpiresAt = null;
    _currentUser = null;
    await _saveSession();
  }

  Future<void> _acceptTokenPair(Map<String, dynamic> pair) async {
    final info = pair['organization'];
    if (info is! Map || info['code'] != _organization?.code) {
      throw const ApiException(
        409,
        'Сессия относится к другой организации или сервер требует обновления.',
      );
    }
    _accessToken = pair['access_token'] as String;
    _refreshToken = pair['refresh_token'] as String;
    final expiresIn = (pair['expires_in'] as num?)?.toInt();
    _accessTokenExpiresAt = expiresIn == null
        ? _expiryFromJwt(_accessToken)
        : DateTime.now().toUtc().add(Duration(seconds: expiresIn));
    _currentUser = Map<String, dynamic>.from(pair['user'] as Map);
    _sessionInvalidationNotified = false;
    await _saveSession();
  }

  Future<void> _invalidateSession() async {
    final clearing = clearSession();
    final epoch = _sessionEpoch;
    await clearing;
    if (epoch != _sessionEpoch) return;
    if (_sessionInvalidationNotified) return;
    _sessionInvalidationNotified = true;
    onSessionInvalidated?.call();
  }

  Future<bool> _refresh() {
    final active = _refreshInFlight;
    if (active != null) return active;
    late final Future<bool> pending;
    pending = _performRefresh().whenComplete(() {
      if (identical(_refreshInFlight, pending)) _refreshInFlight = null;
    });
    return _refreshInFlight = pending;
  }

  Future<bool> _performRefresh() async {
    final epoch = _sessionEpoch;
    final refresh = _refreshToken;
    if (refresh == null) return false;
    try {
      final pair = await request(
        'POST',
        '/api/v1/auth/refresh',
        authenticated: false,
        body: {'refresh_token': refresh},
      ) as Map<String, dynamic>;
      _checkEpoch(epoch);
      await _acceptTokenPair(pair);
      _checkEpoch(epoch);
      return true;
    } on ApiException catch (error) {
      if (epoch != _sessionEpoch) return false;
      if (error.statusCode == 401 || error.statusCode == 403) {
        await _invalidateSession();
        return false;
      }
      rethrow;
    }
  }

  Future<dynamic> request(
    String method,
    String path, {
    Object? body,
    bool authenticated = true,
    bool retryAfterRefresh = true,
    bool binary = false,
    String? discoveryCode,
  }) =>
      _request(
        method,
        path,
        body: body,
        authenticated: authenticated,
        retryAfterRefresh: retryAfterRefresh,
        binary: binary,
        discoveryCode: discoveryCode,
      );

  String get _registrationKey =>
      '${base64Url.encode(utf8.encode(baseUrl))}_pending_registration';

  Future<void> savePendingRegistration(Map<String, dynamic>? ticket) =>
      ticket == null
          ? _storage.delete(key: _registrationKey)
          : _storage.write(key: _registrationKey, value: jsonEncode(ticket));

  Future<Map<String, dynamic>?> pendingRegistration() async {
    final raw = await _storage.read(key: _registrationKey);
    return raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<Map<String, dynamic>> registerOrganization(
    Map<String, dynamic> body, {
    bool status = false,
  }) async {
    if (hasSession) {
      throw const ApiException(409, 'Сначала выйдите из текущего аккаунта.');
    }
    final epoch = _sessionEpoch;
    final request = await _http.openUrl(
      'POST',
      Uri.parse('$baseUrl/api/v1/registration${status ? '/status' : ''}'),
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 30));
    final raw = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 30));
    _checkEpoch(epoch);
    dynamic data;
    try {
      data = jsonDecode(raw);
    } catch (_) {
      throw const ApiException(
        503,
        'Регистрация временно недоступна. Попробуйте позже.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = data is Map ? data['detail'] : null;
      throw ApiException(
        response.statusCode,
        detail is String
            ? detail
            : 'Проверьте название, логин и пароль (не менее 12 символов).',
      );
    }
    return Map<String, dynamic>.from(data as Map);
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Object? body,
    bool authenticated = true,
    bool retryAfterRefresh = true,
    bool binary = false,
    String? discoveryCode,
  }) async {
    if (discoveryCode != null &&
        (authenticated ||
            path != '/api/v1/organization' ||
            !Organization.codePattern.hasMatch(discoveryCode))) {
      throw const ApiException(400, 'Некорректный запрос организации.');
    }
    final selectedCode = discoveryCode ?? _organization?.code;
    if (selectedCode == null) {
      throw const ApiException(400, 'Сначала выберите организацию.');
    }
    final epoch = _sessionEpoch;
    Future<bool> refreshInScope() async {
      final ok = await _refresh();
      _checkEpoch(epoch);
      return ok;
    }

    String? authorizationToken;
    if (authenticated) {
      if (retryAfterRefresh &&
          _refreshToken != null &&
          _accessTokenNeedsRefresh &&
          await refreshInScope()) {
        return this.request(
          method,
          path,
          body: body,
          authenticated: authenticated,
          retryAfterRefresh: false,
          binary: binary,
        );
      }
      final token = _accessToken;
      if (token == null) {
        if (retryAfterRefresh &&
            _refreshToken != null &&
            await refreshInScope()) {
          return this.request(
            method,
            path,
            body: body,
            authenticated: authenticated,
            retryAfterRefresh: false,
            binary: binary,
          );
        }
        await _invalidateSession();
        throw const ApiException(401, 'Требуется авторизация');
      }
      authorizationToken = token;
    }

    _checkEpoch(epoch);
    final request = await _http.openUrl(
      method,
      Uri.parse('$baseUrl/o/$selectedCode$path'),
    );
    _checkEpoch(epoch);
    request.headers.set('X-Organization-Code', selectedCode);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (authorizationToken != null) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $authorizationToken',
      );
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }

    final response = await request.close().timeout(const Duration(seconds: 20));
    final bytes = await consolidateHttpClientResponseBytes(
      response,
    ).timeout(const Duration(seconds: 30));
    _checkEpoch(epoch);
    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        response.headers.value('X-Organization-Code') != selectedCode) {
      throw const ApiException(
        409,
        'Не удалось подтвердить организацию сервера. Вход отменён.',
      );
    }
    if (binary && response.statusCode >= 200 && response.statusCode < 300) {
      return bytes;
    }
    final raw = utf8.decode(bytes, allowMalformed: true);
    if (response.statusCode == 401 && authenticated && retryAfterRefresh) {
      if (await refreshInScope()) {
        return this.request(
          method,
          path,
          body: body,
          authenticated: authenticated,
          retryAfterRefresh: false,
          binary: binary,
        );
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = 'Ошибка сервера (${response.statusCode})';
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['detail'] is String) {
          message = decoded['detail'] as String;
        }
      } catch (_) {}
      throw ApiException(response.statusCode, message);
    }
    if (raw.trim().isEmpty) return null;
    if (raw.length >= 64 * 1024) {
      final decoded = await compute(_decodeJsonOffMainIsolate, raw);
      _checkEpoch(epoch);
      return decoded;
    }
    return jsonDecode(raw);
  }

  bool get _accessTokenNeedsRefresh {
    final expiresAt = _accessTokenExpiresAt;
    if (expiresAt == null) return false;
    // Обновляем заранее: пользователь не должен увидеть истечение access-токена.
    return !DateTime.now().toUtc().isBefore(
          expiresAt.subtract(const Duration(minutes: 2)),
        );
  }

  DateTime? _expiryFromJwt(String? token) {
    if (token == null || token.isEmpty) return null;
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final decoded = jsonDecode(payload);
      if (decoded is! Map || decoded['exp'] is! num) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        (decoded['exp'] as num).toInt() * 1000,
        isUtc: true,
      );
    } catch (_) {
      return null;
    }
  }
}
