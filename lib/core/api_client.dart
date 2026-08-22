import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  Map<String, dynamic>? _currentUser;
  Future<bool>? _refreshInFlight;
  bool _persistSession = true;

  static const _accessTokenKey = 'shift_tracker_access_token';
  static const _refreshTokenKey = 'shift_tracker_refresh_token';
  static const _currentUserKey = 'shift_tracker_current_user';
  static const _rememberLoginKey = 'shift_tracker_remember_login';
  static const _savedLoginKey = 'shift_tracker_saved_login';

  Map<String, dynamic>? get currentUser => _currentUser;
  bool get hasSession => _accessToken != null && _refreshToken != null;

  Future<void> _saveSession() async {
    if (!hasSession || !_persistSession) {
      await Future.wait([
        _storage.delete(key: _accessTokenKey),
        _storage.delete(key: _refreshTokenKey),
        _storage.delete(key: _currentUserKey),
      ]);
      return;
    }
    final user = _currentUser;
    await Future.wait([
      _storage.write(key: _accessTokenKey, value: _accessToken),
      _storage.write(key: _refreshTokenKey, value: _refreshToken),
      if (user != null)
        _storage.write(
          key: _currentUserKey,
          value: jsonEncode(user),
        ),
    ]);
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
        _storage.read(key: _rememberLoginKey),
        _storage.read(key: _savedLoginKey),
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
    await _storage.write(key: _rememberLoginKey, value: remember.toString());
    await _storage.write(key: _savedLoginKey, value: login.trim());
  }

  Future<Map<String, dynamic>> login(
    String login,
    String password, {
    bool rememberSession = true,
  }) async {
    _persistSession = rememberSession;
    final result = await request(
      'POST',
      '/api/v1/auth/login',
      authenticated: false,
      body: {'login': login.trim(), 'password': password},
    ) as Map<String, dynamic>;
    await _acceptTokenPair(result);
    await _saveLoginPreference(login, rememberSession);
    return _currentUser!;
  }

  Future<Map<String, dynamic>?> restoreSession() async {
    Map<String, dynamic>? cachedUser;
    try {
      final loginPreference = await loadLoginPreference();
      _persistSession = loginPreference.remember;
      if (!_persistSession) {
        await clearSession();
        return null;
      }
      final stored = await Future.wait([
        _storage.read(key: _accessTokenKey),
        _storage.read(key: _refreshTokenKey),
        _storage.read(key: _currentUserKey),
      ]);
      _accessToken = stored[0];
      _refreshToken = stored[1];
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
      return _currentUser;
    } on ApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        await clearSession();
        return null;
      }
      return cachedUser;
    } catch (_) {
      return cachedUser;
    }
  }

  Future<void> logout() async {
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
    await clearSession();
  }

  Future<void> clearSession() async {
    _accessToken = null;
    _refreshToken = null;
    _currentUser = null;
    await _saveSession();
  }

  Future<void> _acceptTokenPair(Map<String, dynamic> pair) async {
    _accessToken = pair['access_token'] as String;
    _refreshToken = pair['refresh_token'] as String;
    _currentUser = Map<String, dynamic>.from(pair['user'] as Map);
    await _saveSession();
  }

  Future<bool> _refresh() => _refreshInFlight ??= _runRefresh();

  Future<bool> _runRefresh() async {
    try {
      return await _performRefresh();
    } finally {
      _refreshInFlight = null;
    }
  }

  Future<bool> _performRefresh() async {
    final refresh = _refreshToken;
    if (refresh == null) return false;
    try {
      final pair = await request(
        'POST',
        '/api/v1/auth/refresh',
        authenticated: false,
        body: {'refresh_token': refresh},
      ) as Map<String, dynamic>;
      await _acceptTokenPair(pair);
      return true;
    } on ApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        await clearSession();
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
  }) async {
    final request = await _http.openUrl(method, Uri.parse('$baseUrl$path'));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (authenticated) {
      final token = _accessToken;
      if (token == null) throw const ApiException(401, 'Требуется авторизация');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }

    final response = await request.close().timeout(const Duration(seconds: 20));
    final raw = await utf8.decoder.bind(response).join();
    if (response.statusCode == 401 && authenticated && retryAfterRefresh) {
      if (await _refresh()) {
        return this.request(
          method,
          path,
          body: body,
          authenticated: authenticated,
          retryAfterRefresh: false,
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
      return compute(_decodeJsonOffMainIsolate, raw);
    }
    return jsonDecode(raw);
  }
}
