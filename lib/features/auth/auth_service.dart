import 'package:flutter/foundation.dart';

import 'auth_models.dart';
import 'auth_storage.dart';

class AuthService extends ChangeNotifier {
  AuthService._();
  static final AuthService instance = AuthService._();

  final AuthStorage _storage = AuthStorage();

  bool _initialized = false;
  bool get initialized => _initialized;

  List<UserAccount> _users = [];
  List<UserAccount> get users => List.unmodifiable(_users);

  UserAccount? _currentUser;
  UserAccount? get currentUser => _currentUser;

  // role -> policy
  final Map<UserRole, RolePolicy> _policies = {};
  Map<UserRole, RolePolicy> get policies => Map.unmodifiable(_policies);

  bool get isLoggedIn => _currentUser != null;
  bool get hasUsers => _users.isNotEmpty;

  Future<void> init() async {
    _users = await _storage.loadUsers();

    // policies
    final loadedPolicies = await _storage.loadRolePolicies();
    _policies
      ..clear()
      ..addAll(_buildPoliciesWithDefaults(loadedPolicies));

    // session
    final sessionId = await _storage.loadSessionUserId();
    if (sessionId != null) {
      _currentUser = _users.where((u) => u.id == sessionId).cast<UserAccount?>().firstOrNull;
    }

    _initialized = true;
    notifyListeners();
  }

  // -------- permissions

  bool hasPerm(AppPermission p) {
    final u = _currentUser;
    if (u == null) return false;
    if (u.role == UserRole.superAdmin) return true; // суперадмин всегда всё

    final policy = _policies[u.role];
    if (policy == null) return false;
    return policy.permissions.contains(p);
  }

  // -------- auth

  Future<bool> login(String login, String password) async {
    final user = _users.where((u) => u.login == login.trim()).cast<UserAccount?>().firstOrNull;
    if (user == null) return false;

    final ok = _storage.verifyPassword(
      password: password,
      saltB64: user.saltB64,
      hashB64: user.hashB64,
      iterations: user.iterations,
    );
    if (!ok) return false;

    _currentUser = user;
    await _storage.saveSessionUserId(user.id);
    notifyListeners();
    return true;
  }

  Future<void> logout() async {
    _currentUser = null;
    await _storage.saveSessionUserId(null);
    notifyListeners();
  }

  /// Создаёт первого суперадмина (только если пользователей нет)
  Future<String?> createFirstAdmin({
    required String login,
    required String password,
  }) async {
    if (_users.isNotEmpty) return null;

    final p = _storage.createPasswordHash(password);
    final user = UserAccount(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      login: login.trim(),
      role: UserRole.superAdmin,
      saltB64: p.saltB64,
      hashB64: p.hashB64,
      iterations: p.iterations,
    );

    _users = [user];
    await _storage.saveUsers(_users);

    // гарантируем дефолтные политики на диске (чтобы manager мог редактировать)
    await _savePoliciesToDiskIfNeeded();

    _currentUser = user;
    await _storage.saveSessionUserId(user.id);

    notifyListeners();
    return user.id;
  }

  // -------- users management

  Future<bool> createUser({
    required String login,
    required String password,
    required UserRole role,
  }) async {
    if (!hasPerm(AppPermission.manageUsers) && (currentUser?.role != UserRole.superAdmin)) return false;

    final normalized = login.trim();
    if (normalized.isEmpty) return false;
    if (_users.any((u) => u.login == normalized)) return false;

    final p = _storage.createPasswordHash(password);
    final user = UserAccount(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      login: normalized,
      role: role,
      saltB64: p.saltB64,
      hashB64: p.hashB64,
      iterations: p.iterations,
    );

    _users = [..._users, user];
    await _storage.saveUsers(_users);
    notifyListeners();
    return true;
  }

  Future<bool> setUserRole({
    required String userId,
    required UserRole role,
  }) async {
    if (!hasPerm(AppPermission.manageUsers) && (currentUser?.role != UserRole.superAdmin)) return false;

    // нельзя менять роль суперадмина, если ты не суперадмин
    final target = _users.where((u) => u.id == userId).cast<UserAccount?>().firstOrNull;
    if (target == null) return false;

    if (target.role == UserRole.superAdmin && currentUser?.role != UserRole.superAdmin) {
      return false;
    }

    _users = _users.map((u) => u.id == userId ? u.copyWith(role: role) : u).toList();
    await _storage.saveUsers(_users);

    // если поменяли роль текущему — обновим
    if (_currentUser?.id == userId) {
      _currentUser = _users.where((u) => u.id == userId).firstOrNull;
    }

    notifyListeners();
    return true;
  }

  Future<bool> deleteUser(String userId) async {
    if (!hasPerm(AppPermission.manageUsers) && (currentUser?.role != UserRole.superAdmin)) return false;

    final target = _users.where((u) => u.id == userId).cast<UserAccount?>().firstOrNull;
    if (target == null) return false;

    if (target.role == UserRole.superAdmin) return false; // суперадмина не удаляем
    if (_currentUser?.id == userId) return false; // сам себя не удаляем

    _users = _users.where((u) => u.id != userId).toList();
    await _storage.saveUsers(_users);
    notifyListeners();
    return true;
  }

  // -------- role policies management

  Future<bool> setRolePolicy({
    required UserRole role,
    required Set<AppPermission> permissions,
  }) async {
    // суперадмин всегда может; руководитель — если разрешено editRolePolicies
    final can = (currentUser?.role == UserRole.superAdmin) || hasPerm(AppPermission.editRolePolicies);
    if (!can) return false;

    // суперадмин политику не редактируем — чтоб не “выломать дверь”
    if (role == UserRole.superAdmin) return false;

    _policies[role] = RolePolicy(role: role, permissions: permissions);
    await _storage.saveRolePolicies(_policies.values.toList());
    notifyListeners();
    return true;
  }

  // -------- defaults

  Map<UserRole, RolePolicy> _buildPoliciesWithDefaults(List<RolePolicy> loaded) {
    final Map<UserRole, RolePolicy> m = {};

    // дефолты (можно менять через UI)
    final defaults = <UserRole, Set<AppPermission>>{
      UserRole.manager: {
        AppPermission.viewCalendar,
        AppPermission.viewEmployees,
        AppPermission.viewAttendance,
        AppPermission.editAttendance,
        AppPermission.editEmployees,
        AppPermission.manageUsers,
        AppPermission.editRolePolicies,
      },
      UserRole.master: {
        AppPermission.viewCalendar,
        AppPermission.viewEmployees,
        AppPermission.viewAttendance,
        AppPermission.editAttendance,
      },
      UserRole.worker: {
        AppPermission.viewCalendar,
        AppPermission.viewEmployees,
        AppPermission.viewAttendance,
      },
    };

    // сначала дефолты
    for (final entry in defaults.entries) {
      m[entry.key] = RolePolicy(role: entry.key, permissions: entry.value);
    }

    // поверх — загруженные (кроме superAdmin)
    for (final p in loaded) {
      if (p.role == UserRole.superAdmin) continue;
      m[p.role] = p;
    }

    // superAdmin в словарь можно не добавлять (обрабатываем отдельно),
    // но оставим для UI/отображения:
    m[UserRole.superAdmin] = const RolePolicy(role: UserRole.superAdmin, permissions: {});
    return m;
  }

  Future<void> _savePoliciesToDiskIfNeeded() async {
    final existing = await _storage.loadRolePolicies();
    if (existing.isNotEmpty) return;
    await _storage.saveRolePolicies(
      _policies.values.where((p) => p.role != UserRole.superAdmin).toList(),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
