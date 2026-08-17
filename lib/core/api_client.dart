import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

  Map<String, dynamic>? get currentUser => _currentUser;
  bool get hasSession => _accessToken != null && _refreshToken != null;

  Future<void> _saveSession() async {
    if (!hasSession) {
      await _storage.delete(key: 'shift_tracker_access_token');
      await _storage.delete(key: 'shift_tracker_refresh_token');
      return;
    }
    await _storage.write(
      key: 'shift_tracker_access_token',
      value: _accessToken,
    );
    await _storage.write(
      key: 'shift_tracker_refresh_token',
      value: _refreshToken,
    );
  }

  Future<bool> bootstrapRequired() async {
    final result = await request(
      'GET',
      '/api/v1/auth/bootstrap/status',
      authenticated: false,
    );
    return (result as Map<String, dynamic>)['required'] == true;
  }

  Future<Map<String, dynamic>> login(String login, String password) async {
    final result = await request(
      'POST',
      '/api/v1/auth/login',
      authenticated: false,
      body: {'login': login.trim(), 'password': password},
    ) as Map<String, dynamic>;
    await _acceptTokenPair(result);
    return _currentUser!;
  }

  Future<Map<String, dynamic>?> restoreSession() async {
    try {
      _accessToken = await _storage.read(key: 'shift_tracker_access_token');
      _refreshToken = await _storage.read(key: 'shift_tracker_refresh_token');
      if (!hasSession) return null;
      final result = await request('GET', '/api/v1/auth/me');
      _currentUser = Map<String, dynamic>.from(result as Map);
      return _currentUser;
    } catch (_) {
      await clearSession();
      return null;
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

  Future<bool> _refresh() async {
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
    } catch (_) {
      await clearSession();
      return false;
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
    return jsonDecode(raw);
  }
}
