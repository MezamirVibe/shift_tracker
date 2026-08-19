import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../app/theme.dart';
import '../../core/api_client.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import 'user_preferences.dart';

class PreferencesService extends ChangeNotifier {
  PreferencesService._();

  static final PreferencesService instance = PreferencesService._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  UserPreferences _preferences = UserPreferences.defaults();
  UserPreferences get preferences => _preferences;
  AppThemeChoice get theme => _preferences.theme;
  Set<String> get hiddenGroupIds => _preferences.hiddenGroupIds;
  Set<String> get adminHiddenGroupIds => _preferences.adminHiddenGroupIds;
  Set<String> get effectiveHiddenGroupIds => {
        ..._preferences.hiddenGroupIds,
        ..._preferences.adminHiddenGroupIds,
      };

  bool isGroupVisible(String? groupId) =>
      groupId == null || !effectiveHiddenGroupIds.contains(groupId);

  bool _loading = false;
  bool get loading => _loading;

  bool _saving = false;
  bool get saving => _saving;

  String? _lastError;
  String? get lastError => _lastError;

  String? _loadedUserId;

  bool get _showTeamWidgets {
    final auth = AuthService.instance;
    return auth.isCurrentUserSuperAdmin ||
        auth.hasPerm(AppPermission.editAttendance) ||
        auth.hasPerm(AppPermission.editEmployees);
  }

  UserPreferences get _defaults =>
      UserPreferences.defaults(showTeamWidgets: _showTeamWidgets);

  Set<DashboardWidgetType> get allowedWidgets {
    final result = <DashboardWidgetType>{
      DashboardWidgetType.nextShift,
      DashboardWidgetType.weekSchedule,
      DashboardWidgetType.workedHours,
      DashboardWidgetType.quickActions,
      DashboardWidgetType.profile,
    };
    if (_showTeamWidgets) {
      result.addAll({
        DashboardWidgetType.teamToday,
        DashboardWidgetType.attendanceProgress,
      });
    }
    return result;
  }

  List<DashboardWidgetPreference> layoutFor({required bool mobile}) {
    final source =
        mobile ? _preferences.mobileWidgets : _preferences.desktopWidgets;
    final allowed = allowedWidgets;
    return source.where((item) => allowed.contains(item.type)).toList();
  }

  Future<void> syncForCurrentUser({bool force = false}) async {
    final user = AuthService.instance.currentUser;
    if (user == null) {
      _loadedUserId = null;
      _preferences = UserPreferences.defaults();
      _loading = false;
      notifyListeners();
      return;
    }
    if (!force && _loadedUserId == user.id) return;

    _loadedUserId = user.id;
    _loading = true;
    _lastError = null;

    final cacheKey = _cacheKey(user.id);
    try {
      final cached = await _storage.read(key: cacheKey);
      if (cached != null && cached.isNotEmpty) {
        _preferences = UserPreferences.fromJson(
          jsonDecode(cached),
          fallback: _defaults,
        );
        notifyListeners();
      } else {
        _preferences = _defaults;
      }
    } catch (_) {
      _preferences = _defaults;
    }

    try {
      final response = await ApiClient.instance.request(
        'GET',
        '/api/v1/preferences',
      ) as Map<String, dynamic>;
      final settings = response['settings'];
      if (settings is Map && settings.isNotEmpty) {
        _preferences = UserPreferences.fromJson(
          settings,
          fallback: _defaults,
        );
        await _writeCache();
      } else {
        _preferences = _defaults;
        await _writeCache();
        await ApiClient.instance.request(
          'PUT',
          '/api/v1/preferences',
          body: {'settings': _preferences.toJson()},
        );
      }
    } on ApiException catch (error) {
      if (error.statusCode != 404) _lastError = error.message;
    } catch (_) {
      _lastError = 'Не удалось загрузить настройки с сервера';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> setTheme(AppThemeChoice choice) async {
    if (_preferences.theme == choice) return;
    _preferences = _preferences.copyWith(theme: choice);
    notifyListeners();
    await _save();
  }

  Future<void> setHiddenGroupIds(Set<String> groupIds) async {
    final clean = groupIds
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet();
    if (setEquals(clean, _preferences.hiddenGroupIds)) return;
    _preferences = _preferences.copyWith(hiddenGroupIds: clean);
    notifyListeners();
    await _save();
  }

  Future<void> setGroupHidden(String groupId, {required bool hidden}) async {
    final next = {..._preferences.hiddenGroupIds};
    if (hidden) {
      next.add(groupId);
    } else {
      next.remove(groupId);
    }
    await setHiddenGroupIds(next);
  }

  Future<void> restoreAllUserHiddenGroups() => setHiddenGroupIds(const {});

  Future<void> updateLayout({
    required bool mobile,
    required List<DashboardWidgetPreference> items,
  }) async {
    final allowed = allowedWidgets;
    final clean = items.where((item) => allowed.contains(item.type)).toList();
    _preferences = mobile
        ? _preferences.copyWith(mobileWidgets: clean)
        : _preferences.copyWith(desktopWidgets: clean);
    notifyListeners();
    await _save();
  }

  Future<void> resetLayout({required bool mobile}) async {
    final defaults = _defaults;
    _preferences = mobile
        ? _preferences.copyWith(mobileWidgets: defaults.mobileWidgets)
        : _preferences.copyWith(desktopWidgets: defaults.desktopWidgets);
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    if (_loadedUserId == null) return;
    _saving = true;
    _lastError = null;
    notifyListeners();
    await _writeCache();
    try {
      await ApiClient.instance.request(
        'PUT',
        '/api/v1/preferences',
        body: {'settings': _preferences.toJson()},
      );
    } on ApiException catch (error) {
      _lastError = error.statusCode == 404
          ? 'Настройки сохранены на устройстве. Сервер будет обновлён позже.'
          : error.message;
    } catch (_) {
      _lastError = 'Настройки сохранены на устройстве, но сервер недоступен';
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  Future<void> _writeCache() async {
    final userId = _loadedUserId;
    if (userId == null) return;
    await _storage.write(
      key: _cacheKey(userId),
      value: jsonEncode(_preferences.toJson()),
    );
  }

  String _cacheKey(String userId) => 'shift_tracker_preferences_$userId';
}
