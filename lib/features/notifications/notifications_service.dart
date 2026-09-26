import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/api_client.dart';
import '../../core/id.dart';
import 'notification_models.dart';

/// All state and asynchronous work belong to one API session and account.
/// Notification content is kept in memory; nothing is shared across accounts.
class NotificationsService extends ChangeNotifier {
  NotificationsService._() {
    _channel.setMethodCallHandler(_nativeEvent);
  }

  static final instance = NotificationsService._();
  static const _channel = MethodChannel('chereda/notifications');
  static const _storage = FlutterSecureStorage();
  final _api = ApiClient.instance;
  String? _owner;
  int? _epoch;
  int _generation = 0;
  String? _bindingId;
  String? _registeredDevice;
  String? _registeredToken;
  Timer? _timer;
  bool _foreground = true;
  bool _suspended = false;
  Future<void>? _refreshing;
  Future<void> _storageQueue = Future<void>.value();
  Future<void> _nativeQueue = Future<void>.value();
  Future<void> _deviceQueue = Future<void>.value();
  List<InboxNotification> _items = const [];
  NotificationPreferences _preferences = const NotificationPreferences();
  NativeNotificationStatus _native = const NativeNotificationStatus();
  int _unreadCount = 0;
  String? _nextCursor;
  bool _loading = false;
  bool _loadingMore = false;
  bool _saving = false;
  bool _preferencesLoaded = false;
  int _settingsRevision = 0;
  String? _lastError;
  String? _deviceError;
  DateTime? _lastUpdated;
  void Function(String route)? onOpen;

  bool get _current =>
      !_suspended &&
      _owner != null &&
      _owner == _api.cacheUserKey &&
      _epoch == _api.sessionEpoch &&
      _api.hasSession;
  bool _valid(int generation) => _current && generation == _generation;
  bool get active => _current;
  List<InboxNotification> get items =>
      _current ? List.unmodifiable(_items) : const [];
  NotificationPreferences get preferences =>
      _current ? _preferences : const NotificationPreferences();
  NativeNotificationStatus get nativeStatus =>
      _current ? _native : const NativeNotificationStatus();
  int get unreadCount => _current ? _unreadCount : 0;
  bool get hasMore => _current && _nextCursor != null;
  bool get loading => _current && _loading;
  bool get loadingMore => _current && _loadingMore;
  bool get saving => _current && _saving;
  bool get preferencesLoaded => _current && _preferencesLoaded;
  String? get lastError => _current ? _lastError : null;
  String? get deviceError => _current ? _deviceError : null;
  DateTime? get lastUpdated => _current ? _lastUpdated : null;

  List<String> get visibleKinds {
    if (!_current) return const [];
    final user = _api.currentUser!;
    final role = user['role'] as Map? ?? const {};
    final permissions = (role['permissions'] as List? ?? const []).toSet();
    final superAdmin = role['id'] == 'super_admin';
    final self = role['scope_kind'] == 'self';
    final employee = user['employee_id'] != null;
    return [
      if (employee && (superAdmin || permissions.contains('viewCalendar'))) ...[
        'hours_closed',
        'request_decision',
        'schedule_changed',
        'shift_reminder',
      ],
      if (!self && (superAdmin || permissions.contains('editAttendance'))) ...[
        'request_created',
      ],
      if (!self && (superAdmin || (permissions.contains('editAttendance') &&
          permissions.contains('viewAttendance') && permissions.contains('viewEmployees'))))
        'unfilled_days',
      if (!self && (superAdmin || permissions.contains('viewAttendance')))
        'delivery_failed',
    ];
  }

  String get deliveryStatus {
    if (!_preferencesLoaded) return 'Настройки уведомлений ещё не загружены.';
    if (!_native.supported) {
      return defaultTargetPlatform == TargetPlatform.windows
          ? 'Фоновые уведомления Windows пока не подключены. История доступна в приложении.'
          : 'Системные уведомления на этом устройстве пока не подключены. История доступна в приложении.';
    }
    if (!_native.configured || !_preferences.pushAvailable) {
      return 'Системные уведомления ещё не подключены для этой сборки или сервера. История работает в приложении.';
    }
    if (!_preferences.pushEnabled)
      return 'Системные уведомления выключены. История продолжает сохраняться.';
    if (_native.permission != 'granted')
      return 'Разрешение на уведомления не выдано. Разрешите их в настройках устройства.';
    if (_registeredToken == null)
      return 'Устройство ещё не подключено. Проверьте сеть и обновите статус.';
    return 'Системные уведомления включены на этом устройстве.';
  }

  String _bindingKey(String owner) =>
      'notification_binding_${base64Url.encode(utf8.encode(owner))}';

  Future<void> _queueStorage(Future<void> Function() action) {
    final pending = _storageQueue.then((_) => action());
    _storageQueue = pending.catchError((Object _) {});
    return pending;
  }

  /// Synchronous visible reset, including invalidation before storage finishes.
  void clearSession() {
    final owner = _owner;
    _generation++;
    _suspended = true;
    _owner = null;
    _epoch = null;
    _bindingId = null;
    _registeredDevice = null;
    _registeredToken = null;
    _items = const [];
    _unreadCount = 0;
    _nextCursor = null;
    _preferences = const NotificationPreferences();
    _native = const NativeNotificationStatus();
    _preferencesLoaded = false;
    _loading = _loadingMore = _saving = false;
    _lastError = _deviceError = null;
    _lastUpdated = null;
    _refreshing = null;
    _timer?.cancel();
    _timer = null;
    if (owner != null) {
      unawaited(_queueStorage(() => _storage.delete(key: _bindingKey(owner)))
          .catchError((Object _) {}));
    }
    // Serial native calls ensure an already-started configure finishes before
    // clear, while later configurations must prove their session is current.
    unawaited(_nativeCall('clear'));
    notifyListeners();
  }

  /// Start the old-account DELETE while credentials exist; local reset is
  /// immediate and an offline unregister never holds up logout indefinitely.
  Future<void> disconnect() async {
    final installation = _registeredDevice ?? _native.installationId;
    Future<dynamic>? removing;
    if (_current && installation != null) {
      removing = _api.request('DELETE',
          '/api/v1/notifications/devices/${Uri.encodeComponent(installation)}');
    }
    clearSession();
    if (removing != null) {
      try {
        await removing.timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
  }

  Future<void> syncSession({required bool signedIn}) async {
    final owner = signedIn && _api.hasSession ? _api.cacheUserKey : null;
    if (owner == null) {
      // A previous process may have left a native binding even when this Dart
      // instance has never held a session (expired or non-persistent login).
      clearSession();
      return;
    }
    if (_current) return;
    if (_owner != null) clearSession();
    _suspended = false;
    _owner = owner;
    _epoch = _api.sessionEpoch;
    final generation = ++_generation;
    try {
      await _storageQueue;
      if (!_valid(generation)) return;
      final saved = await _storage.read(key: _bindingKey(owner));
      if (!_valid(generation)) return;
      _bindingId = saved ?? newUuidV4();
      final binding = _bindingId!;
      await _queueStorage(() => _valid(generation)
          ? _storage.write(key: _bindingKey(owner), value: binding)
          : Future<void>.value());
    } catch (_) {
      if (!_valid(generation)) return;
      _bindingId = newUuidV4();
    }
    if (!_valid(generation)) return;
    _schedulePoll();
    await refresh();
    if (!_valid(generation)) return;
    final pending = await _nativeCall('takePendingTap', generation: generation);
    if (_valid(generation) && pending is Map) await _openNative(pending);
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    _schedulePoll();
    if (foreground && _current) unawaited(refresh());
  }

  void _schedulePoll() {
    _timer?.cancel();
    _timer = null;
    if (_foreground && _current) {
      _timer = Timer.periodic(
          const Duration(seconds: 60), (_) => unawaited(refresh()));
    }
  }

  Future<dynamic> _nativeCall(String method,
      {Object? arguments, int? generation}) {
    final pending = _nativeQueue.then<dynamic>((_) async {
      if (generation != null && !_valid(generation)) return null;
      try {
        return await _channel
            .invokeMethod<dynamic>(method, arguments)
            .timeout(const Duration(seconds: 8));
      } on MissingPluginException {
        return null;
      } on PlatformException {
        return null;
      } on TimeoutException {
        return null;
      }
    });
    _nativeQueue = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  Future<void> _loadNative(int generation,
      {bool requestPermission = false}) async {
    final raw = await _nativeCall(
        requestPermission ? 'requestPermission' : 'status',
        generation: generation);
    if (!_valid(generation)) return;
    _native = raw is Map
        ? NativeNotificationStatus.fromJson(raw)
        : const NativeNotificationStatus();
  }

  Future<void> refresh() {
    if (!_current) return Future<void>.value();
    if (_refreshing != null) return _refreshing!;
    final generation = _generation;
    late final Future<void> pending;
    pending = _refresh(generation).whenComplete(() {
      if (identical(_refreshing, pending)) _refreshing = null;
    });
    _refreshing = pending;
    return pending;
  }

  Future<void> _refresh(int generation) async {
    final settingsRevision = _settingsRevision;
    _loading = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        _api.request('GET', '/api/v1/notifications?page_size=30'),
        _api.request('GET', '/api/v1/notifications/preferences'),
      ]);
      if (!_valid(generation)) return;
      _acceptPage(Map<String, dynamic>.from(results[0] as Map), append: false);
      if (!_saving && settingsRevision == _settingsRevision) {
        _preferences = NotificationPreferences.fromJson(
            Map<String, dynamic>.from(results[1] as Map));
        _preferencesLoaded = true;
      }
      _lastError = null;
      _lastUpdated = DateTime.now();
      await _loadNative(generation);
      if (_valid(generation) && !_saving) await _syncDevice(generation);
    } catch (error) {
      if (_valid(generation)) _lastError = _errorText(error);
    } finally {
      if (_valid(generation)) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  void _acceptPage(Map<String, dynamic> data, {required bool append}) {
    final page = (data['items'] as List)
        .whereType<Map>()
        .map((item) =>
            InboxNotification.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    final previous = append ? _items : <InboxNotification>[];
    final seen = previous.map((item) => item.id).toSet();
    _items = [...previous, ...page.where((item) => seen.add(item.id))];
    _nextCursor = data['next_cursor'] as String?;
    _unreadCount = (data['unread_count'] as num?)?.toInt() ?? 0;
  }

  Future<void> loadMore() async {
    if (!_current || _loading || _loadingMore || _nextCursor == null) return;
    final generation = _generation;
    final cursor = _nextCursor!;
    _loadingMore = true;
    notifyListeners();
    try {
      final data = await _api.request('GET',
          '/api/v1/notifications?page_size=30&cursor=${Uri.encodeQueryComponent(cursor)}');
      if (!_valid(generation) || cursor != _nextCursor) return;
      _acceptPage(Map<String, dynamic>.from(data as Map), append: true);
      _lastError = null;
    } catch (error) {
      if (_valid(generation)) _lastError = _errorText(error);
    } finally {
      if (_valid(generation)) {
        _loadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<void> savePreferences(Map<String, dynamic> patch,
      {bool askPermission = false}) async {
    if (!_current || _saving) return;
    final generation = _generation;
    _settingsRevision++;
    _saving = true;
    notifyListeners();
    try {
      final data = await _api
          .request('PUT', '/api/v1/notifications/preferences', body: patch);
      if (!_valid(generation)) return;
      _preferences = NotificationPreferences.fromJson(
          Map<String, dynamic>.from(data as Map));
      _preferencesLoaded = true;
      _lastError = null;
      await _loadNative(generation,
          requestPermission: askPermission && _preferences.pushEnabled);
      if (_valid(generation)) await _syncDevice(generation);
    } catch (_) {
      if (_valid(generation)) {
        _lastError =
            'Не удалось сохранить настройки. Изменения не подтверждены сервером — повторите попытку.';
      }
    } finally {
      if (_valid(generation)) {
        _saving = false;
        notifyListeners();
      }
    }
  }

  Future<void> requestPermission() async {
    if (!_current || _saving) return;
    final generation = _generation;
    await _loadNative(generation, requestPermission: true);
    if (!_valid(generation)) return;
    await _syncDevice(generation);
    if (_valid(generation)) notifyListeners();
  }

  Future<void> _syncDevice(int generation) {
    final pending = _deviceQueue.then((_) => _performDeviceSync(generation));
    _deviceQueue = pending.catchError((Object _) {});
    return pending;
  }

  Future<void> _performDeviceSync(int generation) async {
    if (!_valid(generation) || _bindingId == null) return;
    final enabled = _preferencesLoaded &&
        _preferences.pushEnabled &&
        _preferences.pushAvailable &&
        _native.supported &&
        _native.configured &&
        _native.permission == 'granted';
    try {
      final installation = _native.installationId;
      final token = _native.token;
      if (enabled &&
          installation != null &&
          token != null &&
          token.isNotEmpty) {
        if (_registeredDevice != installation || _registeredToken != token) {
          // Only a new binding/token needs a registration barrier. Ordinary
          // refreshes must not clear the user's delivered system notifications.
          await _nativeCall('configure', generation: generation, arguments: {
            'binding_id': _bindingId,
            'enabled': false,
            'kinds': _preferences.kinds,
          });
          if (!_valid(generation)) return;
          await _api.request('PUT', '/api/v1/notifications/devices', body: {
            'installation_id': installation,
            'binding_id': _bindingId,
            'token': token,
            'platform': 'android',
          });
          if (!_valid(generation)) return;
          _registeredDevice = installation;
          _registeredToken = token;
        }
        await _nativeCall('configure', generation: generation, arguments: {
          'binding_id': _bindingId,
          'enabled': true,
          'kinds': _preferences.kinds,
        });
      } else {
        await _nativeCall('configure', generation: generation, arguments: {
          'binding_id': _bindingId,
          'enabled': false,
          'kinds': _preferences.kinds,
        });
        if (!_valid(generation)) return;
        if (_registeredDevice != null) {
          final previous = _registeredDevice!;
          await _api.request('DELETE',
              '/api/v1/notifications/devices/${Uri.encodeComponent(previous)}');
          if (!_valid(generation)) return;
          _registeredDevice = _registeredToken = null;
        }
      }
      if (_valid(generation)) _deviceError = null;
    } catch (_) {
      if (_valid(generation))
        _deviceError =
            'Не удалось подключить устройство к уведомлениям. Повторите обновление.';
    }
  }

  Future<void> markRead(InboxNotification item) async {
    if (!_current ||
        item.readAt != null ||
        !_items.any((current) => current.id == item.id)) return;
    final generation = _generation;
    try {
      await _api.request(
          'POST', '/api/v1/notifications/${Uri.encodeComponent(item.id)}/read');
      if (!_valid(generation)) return;
      final wasUnread = _items
          .any((current) => current.id == item.id && current.readAt == null);
      _items = _items
          .map((current) => current.id == item.id ? current.asRead() : current)
          .toList();
      if (wasUnread && _unreadCount > 0) _unreadCount--;
      _lastError = null;
    } catch (error) {
      if (_valid(generation)) _lastError = _errorText(error);
    }
    if (_valid(generation)) notifyListeners();
  }

  Future<void> markAllRead() async {
    if (!_current) return;
    final generation = _generation;
    try {
      await _api.request('POST', '/api/v1/notifications/read-all');
      if (!_valid(generation)) return;
      _items = _items.map((item) => item.asRead()).toList();
      _unreadCount = 0;
      _lastError = null;
    } catch (error) {
      if (_valid(generation)) _lastError = _errorText(error);
    }
    if (_valid(generation)) notifyListeners();
  }

  Future<void> openItem(InboxNotification item) async {
    if (!_current || !_items.any((current) => identical(current, item))) return;
    final generation = _generation;
    await markRead(item);
    if (_valid(generation)) onOpen?.call(_routeFor(item));
  }

  String _routeFor(InboxNotification item) {
    if (item.kind == 'request_decision' || item.kind == 'request_created')
      return '/hour-requests';
    if (item.kind == 'delivery_failed') return '/timesheet/delivery';
    if (item.kind == 'unfilled_days') return '/timesheet';
    final day = item.day;
    if (day != null &&
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day) &&
        DateTime.tryParse(day) != null) {
      return '/schedule?date=${Uri.encodeQueryComponent(day)}';
    }
    return '/notifications';
  }

  Future<dynamic> _nativeEvent(MethodCall call) async {
    if (!_current) return false;
    if (call.method == 'tokenChanged') {
      final generation = _generation;
      await _loadNative(generation);
      if (!_valid(generation)) return;
      await _syncDevice(generation);
      if (_valid(generation)) notifyListeners();
    } else if (call.method == 'notificationOpened' && call.arguments is Map) {
      if ((call.arguments as Map)['binding_id'] != _bindingId) return false;
      await _openNative(call.arguments as Map);
      return true;
    }
    return null;
  }

  Future<void> _openNative(Map tap) async {
    if (!_current || tap['binding_id'] != _bindingId) return;
    final id = tap['notification_id'];
    if (id is! String || !RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(id)) return;
    final generation = _generation;
    // The payload is only a hint. The authenticated endpoint checks current
    // recipient/scope and returns details, even for old paginated events.
    try {
      final row = await _api.request(
          'POST', '/api/v1/notifications/${Uri.encodeComponent(id)}/read');
      if (!_valid(generation)) return;
      final item =
          InboxNotification.fromJson(Map<String, dynamic>.from(row as Map));
      if (item.id != id) return;
      onOpen?.call(_routeFor(item));
      unawaited(refresh());
    } catch (_) {
      if (_valid(generation)) {
        _lastError = 'Не удалось открыть уведомление. Обновите историю.';
        notifyListeners();
        onOpen?.call('/notifications');
      }
    }
  }

  String _errorText(Object error) => error is ApiException &&
          error.statusCode == 404
      ? 'Сервер пока не поддерживает уведомления. История недоступна.'
      : 'Не удалось обновить уведомления. Показаны последние загруженные данные.';
}
