import 'package:flutter/foundation.dart';

import '../employees/employees_storage.dart';
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

    final loadedPolicies = await _storage.loadRolePolicies();
    _policies
      ..clear()
      ..addAll(_buildPoliciesWithDefaults(loadedPolicies));

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
    if (u.role == UserRole.superAdmin) return true;

    final policy = _policies[u.role];
    if (policy == null) return false;
    return policy.permissions.contains(p);
  }

  // -------- scope/visibility

  /// Возвращает список сотрудников, которых текущий пользователь имеет право ВИДЕТЬ по привязке роли.
  /// superAdmin -> все
  /// manager -> departmentId
  /// master -> groupId
  /// worker -> employeeId
  List<EmployeeModel> filterEmployeesByScope(List<EmployeeModel> employees) {
    final u = _currentUser;
    if (u == null) return const [];

    if (u.role == UserRole.superAdmin) return employees;

    switch (u.role) {
      case UserRole.manager:
        final depId = u.departmentId;
        if (depId == null) return const [];
        return employees.where((e) => e.departmentId == depId).toList();

      case UserRole.master:
        final groupId = u.groupId;
        if (groupId == null) return const [];
        return employees.where((e) => e.groupId == groupId).toList();

      case UserRole.worker:
        final employeeId = u.employeeId;
        if (employeeId == null) return const [];
        return employees.where((e) => e.id == employeeId).toList();

      case UserRole.superAdmin:
        return employees;
    }
  }

  /// Подсказка для UI: какая привязка нужна роли
  String requiredBindingHint(UserRole role) {
    switch (role) {
      case UserRole.worker:
        return 'Для роли "Рабочий" нужна привязка к сотруднику.';
      case UserRole.master:
        return 'Для роли "Мастер" нужна привязка к группе.';
      case UserRole.manager:
        return 'Для роли "Руководитель" нужна привязка к подразделению.';
      case UserRole.superAdmin:
        return 'Суперадмин видит всё, привязка не требуется.';
    }
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
    String? departmentId,
    String? groupId,
    String? employeeId,
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
      departmentId: departmentId,
      groupId: groupId,
      employeeId: employeeId,
    );

    _users = [..._users, user];
    await _storage.saveUsers(_users);
    notifyListeners();
    return true;
  }

  Future<bool> updateUserAccess({
    required String userId,
    required UserRole role,
    String? departmentId,
    String? groupId,
    String? employeeId,
  }) async {
    if (!hasPerm(AppPermission.manageUsers) && (currentUser?.role != UserRole.superAdmin)) return false;

    final target = _users.where((u) => u.id == userId).cast<UserAccount?>().firstOrNull;
    if (target == null) return false;

    if (target.role == UserRole.superAdmin && currentUser?.role != UserRole.superAdmin) {
      return false;
    }

    // при смене роли сбрасываем "не свои" привязки
    String? dep = departmentId;
    String? grp = groupId;
    String? emp = employeeId;

    switch (role) {
      case UserRole.manager:
        grp = null;
        emp = null;
        break;
      case UserRole.master:
        dep = null;
        emp = null;
        break;
      case UserRole.worker:
        dep = null;
        grp = null;
        break;
      case UserRole.superAdmin:
        dep = null;
        grp = null;
        emp = null;
        break;
    }

    _users = _users.map((u) {
      if (u.id != userId) return u;
      return u.copyWith(
        role: role,
        departmentId: dep,
        groupId: grp,
        employeeId: emp,
        clearDepartment: dep == null,
        clearGroup: grp == null,
        clearEmployee: emp == null,
      );
    }).toList();

    await _storage.saveUsers(_users);

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

    if (target.role == UserRole.superAdmin) return false;
    if (_currentUser?.id == userId) return false;

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
    final can = (currentUser?.role == UserRole.superAdmin) || hasPerm(AppPermission.editRolePolicies);
    if (!can) return false;

    if (role == UserRole.superAdmin) return false;

    _policies[role] = RolePolicy(role: role, permissions: permissions);
    await _storage.saveRolePolicies(_policies.values.toList());
    notifyListeners();
    return true;
  }

  // -------- defaults

  Map<UserRole, RolePolicy> _buildPoliciesWithDefaults(List<RolePolicy> loaded) {
    final Map<UserRole, RolePolicy> m = {};

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

    for (final entry in defaults.entries) {
      m[entry.key] = RolePolicy(role: entry.key, permissions: entry.value);
    }

    for (final p in loaded) {
      if (p.role == UserRole.superAdmin) continue;
      m[p.role] = p;
    }

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