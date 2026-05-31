import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../shared/extensions/iterable_x.dart';
import '../employees/employees_storage.dart';
import 'auth_models.dart';
import 'auth_storage.dart';

class LoginResult {
  final bool ok;
  final String? error;

  const LoginResult._(this.ok, this.error);

  const LoginResult.success() : this._(true, null);

  const LoginResult.fail(String message) : this._(false, message);
}

class AuthService extends ChangeNotifier {
  AuthService._();
  static final AuthService instance = AuthService._();

  final AuthStorage _storage = AuthStorage();
  final EmployeesStorage _employeesStorage = EmployeesStorage();
  final Random _random = Random.secure();

  bool _initialized = false;
  bool get initialized => _initialized;

  List<UserAccount> _users = [];
  List<UserAccount> get users => List.unmodifiable(_users);

  List<AppRole> _roles = [];
  List<AppRole> get roles => List.unmodifiable(_roles);

  UserAccount? _currentUser;
  UserAccount? get currentUser => _currentUser;

  bool get isLoggedIn => _currentUser != null;
  bool get hasUsers => _users.isNotEmpty;

  Future<void> init() async {
    _users = await _storage.loadUsers();

    final loadedRoles = await _storage.loadRoles();
    if (loadedRoles.isNotEmpty) {
      _roles = loadedRoles;
    } else {
      final legacyPolicies = await _storage.loadRolePolicies();
      _roles = _buildRolesFromLegacyPolicies(legacyPolicies);

      if (_roles.isEmpty) {
        _roles = _buildDefaultRoles();
      }

      await _storage.saveRoles(_roles);
    }

    final sessionId = await _storage.loadSessionUserId();
    if (sessionId != null) {
      _currentUser = _users
          .where((u) => u.id == sessionId)
          .cast<UserAccount?>()
          .firstOrNull;
    }

    _initialized = true;
    notifyListeners();
  }

  AppRole? roleById(String? id) {
    if (id == null || id.trim().isEmpty) return null;
    return _roles.where((r) => r.id == id.trim()).cast<AppRole?>().firstOrNull;
  }

  UserAccount? userByEmployeeId(String? employeeId) {
    if (employeeId == null || employeeId.trim().isEmpty) return null;
    return _users
        .where((u) => u.employeeId == employeeId)
        .cast<UserAccount?>()
        .firstOrNull;
  }

  bool isSuperAdminRoleId(String? roleId) {
    final role = roleById(roleId);
    if (role == null) return false;
    return role.scopeKind == ScopeKind.all &&
        role.permissions.isEmpty &&
        role.name.trim().toLowerCase() == 'суперадмин';
  }

  bool get isCurrentUserSuperAdmin {
    final u = _currentUser;
    if (u == null) return false;
    final role = roleById(u.roleId);
    if (role == null) return false;
    return role.name.trim().toLowerCase() == 'суперадмин';
  }

  bool hasPerm(AppPermission p) {
    final u = _currentUser;
    if (u == null) return false;

    final role = roleById(u.roleId);
    if (role == null) return false;

    if (role.name.trim().toLowerCase() == 'суперадмин') return true;
    return role.permissions.contains(p);
  }

  List<EmployeeModel> filterEmployeesByScope(List<EmployeeModel> employees) {
    final u = _currentUser;
    if (u == null) return const [];

    final role = roleById(u.roleId);
    if (role == null) return const [];

    if (role.name.trim().toLowerCase() == 'суперадмин' ||
        role.scopeKind == ScopeKind.all) {
      return employees;
    }

    switch (role.scopeKind) {
      case ScopeKind.department:
        final depId = u.departmentId;
        if (depId == null) return const [];
        return employees.where((e) => e.departmentId == depId).toList();

      case ScopeKind.group:
        final groupId = u.groupId;
        if (groupId == null) return const [];
        return employees.where((e) => e.groupId == groupId).toList();

      case ScopeKind.self:
        final employeeId = u.employeeId;
        if (employeeId == null) return const [];
        return employees.where((e) => e.id == employeeId).toList();

      case ScopeKind.all:
        return employees;
    }
  }

  String requiredBindingHint(UserRole role) {
    return requiredBindingHintByRoleId(roleIdFromLegacyRole(role));
  }

  String requiredBindingHintByRoleId(String? roleId) {
    final role = roleById(roleId);
    if (role == null) return 'Роль не найдена.';

    if (role.name.trim().toLowerCase() == 'суперадмин' ||
        role.scopeKind == ScopeKind.all) {
      return 'Эта роль видит всё, привязка не требуется.';
    }

    switch (role.scopeKind) {
      case ScopeKind.department:
        return 'Для этой роли нужна привязка к подразделению.';
      case ScopeKind.group:
        return 'Для этой роли нужна привязка к группе.';
      case ScopeKind.self:
        return 'Для этой роли нужен сотрудник.';
      case ScopeKind.all:
        return 'Эта роль видит всё, привязка не требуется.';
    }
  }

  Future<LoginResult> loginDetailed(String login, String password) async {
    final user = _users
        .where((u) => u.login == login.trim())
        .cast<UserAccount?>()
        .firstOrNull;

    if (user == null) {
      return const LoginResult.fail('Неверный логин или пароль');
    }

    final lockUntil = user.lockUntil;
    if (lockUntil != null && DateTime.now().isBefore(lockUntil)) {
      final local = lockUntil.toLocal();
      final hh = local.hour.toString().padLeft(2, '0');
      final mm = local.minute.toString().padLeft(2, '0');
      return LoginResult.fail(
        'Слишком много неудачных попыток. Повторите после $hh:$mm',
      );
    }

    final ok = _storage.verifyPassword(
      password: password,
      saltB64: user.saltB64,
      hashB64: user.hashB64,
      iterations: user.iterations,
    );

    if (!ok) {
      final nextAttempts = user.failedLoginAttempts + 1;
      final shouldLock = nextAttempts >= 4;
      final updated = user.copyWith(
        failedLoginAttempts: nextAttempts,
        lockUntilIso:
            shouldLock ? DateTime.now().add(const Duration(minutes: 5)).toIso8601String() : null,
        clearLockUntil: !shouldLock,
      );

      _replaceUser(updated);
      await _storage.saveUsers(_users);

      if (shouldLock) {
        return const LoginResult.fail(
          'Слишком много неудачных попыток. Вход заблокирован на 5 минут.',
        );
      }

      return LoginResult.fail(
        'Неверный логин или пароль. Попытка $nextAttempts из 3 без блокировки.',
      );
    }

    final cleared = user.copyWith(
      failedLoginAttempts: 0,
      clearLockUntil: true,
    );
    _replaceUser(cleared);
    await _storage.saveUsers(_users);

    _currentUser = cleared;
    await _storage.saveSessionUserId(cleared.id);
    notifyListeners();
    return const LoginResult.success();
  }

  Future<bool> login(String login, String password) async {
    final result = await loginDetailed(login, password);
    return result.ok;
  }

  Future<void> logout() async {
    _currentUser = null;
    await _storage.saveSessionUserId(null);
    notifyListeners();
  }

  Future<String?> createFirstAdmin({
    required String login,
    required String password,
  }) async {
    if (_users.isNotEmpty) return null;

    if (_roles.isEmpty) {
      _roles = _buildDefaultRoles();
      await _storage.saveRoles(_roles);
    }

    final superAdminRole = _roles.firstWhere(
      (r) => r.name.trim().toLowerCase() == 'суперадмин',
      orElse: () => _roles.first,
    );

    final p = _storage.createPasswordHash(password);
    final user = UserAccount(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      login: login.trim(),
      roleId: superAdminRole.id,
      lastName: '',
      firstName: login.trim(),
      middleName: '',
      saltB64: p.saltB64,
      hashB64: p.hashB64,
      iterations: p.iterations,
      departmentId: null,
      groupId: null,
      employeeId: null,
      failedLoginAttempts: 0,
      lockUntilIso: null,
    );

    _users = [user];
    await _storage.saveUsers(_users);

    _currentUser = user;
    await _storage.saveSessionUserId(user.id);

    notifyListeners();
    return user.id;
  }

  Future<bool> createUser({
    required String login,
    required String password,
    required String roleId,
    required String lastName,
    required String firstName,
    required String middleName,
    String? departmentId,
    String? groupId,
    String? employeeId,
    String? linkedEmployeeId,
    bool createEmployeeForWorker = false,
    String? employeePosition,
    int employeeSalary = 0,
    int employeeBonus = 0,
    ScheduleType employeeScheduleType = ScheduleType.twoTwo,
    DateTime? employeeScheduleStartDate,
    int employeeShiftHours = 12,
    int employeeBreakHours = 1,
  }) async {
    if (!hasPerm(AppPermission.manageUsers) && !isCurrentUserSuperAdmin) {
      return false;
    }

    final normalizedLogin = login.trim();
    final normalizedLastName = lastName.trim();
    final normalizedFirstName = firstName.trim();
    final normalizedMiddleName = middleName.trim();

    if (normalizedLogin.isEmpty ||
        normalizedLastName.isEmpty ||
        normalizedFirstName.isEmpty) {
      return false;
    }

    if (_users.any((u) => u.login == normalizedLogin)) {
      return false;
    }

    final role = roleById(roleId);
    if (role == null) return false;

    String? dep = departmentId?.trim();
    String? grp = groupId?.trim();
    String? emp = employeeId?.trim();

    switch (role.scopeKind) {
      case ScopeKind.all:
        dep = null;
        grp = null;
        break;

      case ScopeKind.department:
        grp = null;
        if (dep == null || dep.isEmpty) return false;
        break;

      case ScopeKind.group:
        if (grp == null || grp.isEmpty) return false;
        dep = null;
        break;

      case ScopeKind.self:
        dep = null;
        grp = null;

        if (createEmployeeForWorker) {
          final workerDepId = departmentId?.trim();
          final workerGroupId = groupId?.trim();

          if (workerDepId == null ||
              workerDepId.isEmpty ||
              workerGroupId == null ||
              workerGroupId.isEmpty) {
            return false;
          }

          final employees = await _employeesStorage.load();

          final newEmployee = EmployeeModel(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            fullName: [
              normalizedLastName,
              normalizedFirstName,
              normalizedMiddleName,
            ].where((x) => x.isNotEmpty).join(' '),
            position: (employeePosition?.trim().isNotEmpty ?? false)
                ? employeePosition!.trim()
                : role.name,
            salary: employeeSalary,
            bonus: employeeBonus,
            departmentId: workerDepId,
            groupId: workerGroupId,
            scheduleType: employeeScheduleType,
            scheduleStartDate: employeeScheduleStartDate ?? DateTime.now(),
            shiftHours: employeeShiftHours,
            breakHours: employeeBreakHours,
          );

          await _employeesStorage.save([...employees, newEmployee]);
          emp = newEmployee.id;
        } else {
          if (emp == null || emp.isEmpty) return false;
        }
        break;
    }

    final p = _storage.createPasswordHash(password);

    final user = UserAccount(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      login: normalizedLogin,
      roleId: role.id,
      lastName: normalizedLastName,
      firstName: normalizedFirstName,
      middleName: normalizedMiddleName,
      saltB64: p.saltB64,
      hashB64: p.hashB64,
      iterations: p.iterations,
      departmentId: dep,
      groupId: grp,
      employeeId: linkedEmployeeId ?? emp,
      failedLoginAttempts: 0,
      lockUntilIso: null,
    );

    _users = [..._users, user];
    await _storage.saveUsers(_users);
    notifyListeners();
    return true;
  }

  Future<({EmployeeModel employee, UserAccount user, String password})?>
      createEmployeeWithAccount({
    required String fullName,
    required String position,
    required int salary,
    required int bonus,
    required String? departmentId,
    required String? groupId,
    required ScheduleType scheduleType,
    required DateTime scheduleStartDate,
    required int shiftHours,
    required int breakHours,
    required String login,
    required String roleId,
  }) async {
    if (!hasPerm(AppPermission.editEmployees) &&
        !hasPerm(AppPermission.manageUsers) &&
        !isCurrentUserSuperAdmin) {
      return null;
    }

    final normalizedLogin = login.trim();
    if (normalizedLogin.isEmpty) return null;
    if (_users.any((u) => u.login == normalizedLogin)) return null;

    final role = roleById(roleId);
    if (role == null) return null;

    final nameParts =
        fullName.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
    final lastName = nameParts.isNotEmpty ? nameParts.first : '';
    final firstName = nameParts.length > 1 ? nameParts[1] : fullName.trim();
    final middleName =
        nameParts.length > 2 ? nameParts.sublist(2).join(' ') : '';

    final employees = await _employeesStorage.load();

    final employee = EmployeeModel(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      fullName: fullName.trim(),
      position: position.trim(),
      salary: salary,
      bonus: bonus,
      departmentId: departmentId,
      groupId: groupId,
      scheduleType: scheduleType,
      scheduleStartDate: scheduleStartDate,
      shiftHours: shiftHours,
      breakHours: breakHours,
    );

    await _employeesStorage.save([...employees, employee]);

    String? boundDepartmentId;
    String? boundGroupId;

    switch (role.scopeKind) {
      case ScopeKind.all:
        boundDepartmentId = null;
        boundGroupId = null;
        break;
      case ScopeKind.department:
        boundDepartmentId = employee.departmentId;
        boundGroupId = null;
        if (boundDepartmentId == null || boundDepartmentId.isEmpty) {
          return null;
        }
        break;
      case ScopeKind.group:
        boundDepartmentId = null;
        boundGroupId = employee.groupId;
        if (boundGroupId == null || boundGroupId.isEmpty) {
          return null;
        }
        break;
      case ScopeKind.self:
        boundDepartmentId = null;
        boundGroupId = null;
        break;
    }

    final password = generateReadablePassword();
    final p = _storage.createPasswordHash(password);

    final user = UserAccount(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      login: normalizedLogin,
      roleId: role.id,
      lastName: lastName,
      firstName: firstName,
      middleName: middleName,
      saltB64: p.saltB64,
      hashB64: p.hashB64,
      iterations: p.iterations,
      departmentId: boundDepartmentId,
      groupId: boundGroupId,
      employeeId: employee.id,
      failedLoginAttempts: 0,
      lockUntilIso: null,
    );

    _users = [..._users, user];
    await _storage.saveUsers(_users);
    notifyListeners();

    return (employee: employee, user: user, password: password);
  }

  Future<String?> resetPassword(String userId) async {
    if (!hasPerm(AppPermission.manageUsers) && !isCurrentUserSuperAdmin) {
      return null;
    }

    final target =
        _users.where((u) => u.id == userId).cast<UserAccount?>().firstOrNull;
    if (target == null) return null;

    final newPassword = generateReadablePassword();
    final p = _storage.createPasswordHash(newPassword);

    final updated = target.copyWith(
      saltB64: p.saltB64,
      hashB64: p.hashB64,
      iterations: p.iterations,
      failedLoginAttempts: 0,
      clearLockUntil: true,
    );

    _replaceUser(updated);
    await _storage.saveUsers(_users);

    if (_currentUser?.id == updated.id) {
      _currentUser = updated;
    }

    notifyListeners();
    return newPassword;
  }

  Future<bool> updateUserAccess({
    required String userId,
    required String roleId,
    required String lastName,
    required String firstName,
    required String middleName,
    String? departmentId,
    String? groupId,
    String? employeeId,
  }) async {
    if (!hasPerm(AppPermission.manageUsers) && !isCurrentUserSuperAdmin) {
      return false;
    }

    final target =
        _users.where((u) => u.id == userId).cast<UserAccount?>().firstOrNull;
    if (target == null) return false;

    final role = roleById(roleId);
    if (role == null) return false;

    final normalizedLastName = lastName.trim();
    final normalizedFirstName = firstName.trim();
    final normalizedMiddleName = middleName.trim();

    if (normalizedLastName.isEmpty || normalizedFirstName.isEmpty) {
      return false;
    }

    String? dep = departmentId?.trim();
    String? grp = groupId?.trim();
    String? emp = employeeId?.trim() ?? target.employeeId;

    switch (role.scopeKind) {
      case ScopeKind.all:
        dep = null;
        grp = null;
        break;

      case ScopeKind.department:
        grp = null;
        if (dep == null || dep.isEmpty) return false;
        break;

      case ScopeKind.group:
        dep = null;
        if (grp == null || grp.isEmpty) return false;
        break;

      case ScopeKind.self:
        dep = null;
        grp = null;
        if (emp == null || emp.isEmpty) return false;
        break;
    }

    _users = _users.map((u) {
      if (u.id != userId) return u;
      return u.copyWith(
        roleId: role.id,
        lastName: normalizedLastName,
        firstName: normalizedFirstName,
        middleName: normalizedMiddleName,
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
    if (!hasPerm(AppPermission.manageUsers) && !isCurrentUserSuperAdmin) {
      return false;
    }

    final target =
        _users.where((u) => u.id == userId).cast<UserAccount?>().firstOrNull;
    if (target == null) return false;

    if (_currentUser?.id == userId) return false;

    _users = _users.where((u) => u.id != userId).toList();
    await _storage.saveUsers(_users);
    notifyListeners();
    return true;
  }

  Future<String?> createRole({
    String? id,
    required String name,
    required ScopeKind scopeKind,
    Set<AppPermission> permissions = const {},
  }) async {
    final can =
        isCurrentUserSuperAdmin || hasPerm(AppPermission.editRolePolicies);
    if (!can) return null;

    final normalizedName = name.trim();
    if (normalizedName.isEmpty) return null;

    final requestedId = id?.trim();
    final generatedId = (requestedId != null && requestedId.isNotEmpty)
        ? _generateUniqueRoleId(requestedId)
        : _generateUniqueRoleId(normalizedName);

    if (generatedId.isEmpty) return null;

    final role = AppRole(
      id: generatedId,
      name: normalizedName,
      scopeKind: scopeKind,
      permissions: Set<AppPermission>.from(permissions),
      isSystem: false,
    );

    _roles = [..._roles, role];
    await _storage.saveRoles(_roles);

    return role.id;
  }

  Future<bool> updateRole({
    required String id,
    String? name,
    ScopeKind? scopeKind,
    Set<AppPermission>? permissions,
  }) async {
    final can =
        isCurrentUserSuperAdmin || hasPerm(AppPermission.editRolePolicies);
    if (!can) return false;

    final existing = roleById(id);
    if (existing == null) return false;

    final normalizedName = name?.trim();
    final affectsCurrentUser = _currentUser?.roleId == id;

    _roles = _roles.map((r) {
      if (r.id != id) return r;
      return r.copyWith(
        name: (normalizedName != null && normalizedName.isNotEmpty)
            ? normalizedName
            : r.name,
        scopeKind: scopeKind ?? r.scopeKind,
        permissions: permissions ?? r.permissions,
      );
    }).toList();

    await _storage.saveRoles(_roles);

    if (affectsCurrentUser) {
      notifyListeners();
    }

    return true;
  }

  Future<bool> deleteRole(String id) async {
    final can =
        isCurrentUserSuperAdmin || hasPerm(AppPermission.editRolePolicies);
    if (!can) return false;

    final role = roleById(id);
    if (role == null) return false;

    if (_users.any((u) => u.roleId == id)) return false;

    _roles = _roles.where((r) => r.id != id).toList();
    await _storage.saveRoles(_roles);

    return true;
  }

  List<AppRole> _buildDefaultRoles() {
    return [
      const AppRole(
        id: 'super_admin',
        name: 'Суперадмин',
        scopeKind: ScopeKind.all,
        permissions: <AppPermission>{},
      ),
      const AppRole(
        id: 'manager',
        name: 'Руководитель',
        scopeKind: ScopeKind.department,
        permissions: <AppPermission>{
          AppPermission.viewCalendar,
          AppPermission.viewEmployees,
          AppPermission.viewAttendance,
          AppPermission.editAttendance,
          AppPermission.editEmployees,
          AppPermission.manageUsers,
          AppPermission.editRolePolicies,
        },
      ),
      const AppRole(
        id: 'master',
        name: 'Мастер',
        scopeKind: ScopeKind.group,
        permissions: <AppPermission>{
          AppPermission.viewCalendar,
          AppPermission.viewEmployees,
          AppPermission.viewAttendance,
          AppPermission.editAttendance,
        },
      ),
      const AppRole(
        id: 'worker',
        name: 'Рабочий',
        scopeKind: ScopeKind.self,
        permissions: <AppPermission>{
          AppPermission.viewCalendar,
          AppPermission.viewEmployees,
          AppPermission.viewAttendance,
        },
      ),
    ];
  }

  List<AppRole> _buildRolesFromLegacyPolicies(List<RolePolicy> legacyPolicies) {
    final defaults = _buildDefaultRoles();
    final byId = <String, AppRole>{
      for (final r in defaults) r.id: r,
    };

    for (final policy in legacyPolicies) {
      final roleId = roleIdFromLegacyRole(policy.role);
      final existing = byId[roleId];
      if (existing == null) continue;

      byId[roleId] = existing.copyWith(
        permissions: policy.permissions,
      );
    }

    return byId.values.toList();
  }

  String _generateUniqueRoleId(String raw) {
    final base = _slugifyRoleName(raw);
    if (base.isEmpty) {
      return 'role_${DateTime.now().millisecondsSinceEpoch}';
    }

    if (_roles.every((r) => r.id != base)) {
      return base;
    }

    int i = 2;
    while (_roles.any((r) => r.id == '${base}_$i')) {
      i++;
    }
    return '${base}_$i';
  }

  String _slugifyRoleName(String raw) {
    final map = <String, String>{
      'а': 'a',
      'б': 'b',
      'в': 'v',
      'г': 'g',
      'д': 'd',
      'е': 'e',
      'ё': 'e',
      'ж': 'zh',
      'з': 'z',
      'и': 'i',
      'й': 'i',
      'к': 'k',
      'л': 'l',
      'м': 'm',
      'н': 'n',
      'о': 'o',
      'п': 'p',
      'р': 'r',
      'с': 's',
      'т': 't',
      'у': 'u',
      'ф': 'f',
      'х': 'h',
      'ц': 'c',
      'ч': 'ch',
      'ш': 'sh',
      'щ': 'sch',
      'ъ': '',
      'ы': 'y',
      'ь': '',
      'э': 'e',
      'ю': 'yu',
      'я': 'ya',
    };

    final lower = raw.trim().toLowerCase();
    final buffer = StringBuffer();

    for (final rune in lower.runes) {
      final ch = String.fromCharCode(rune);

      if (map.containsKey(ch)) {
        buffer.write(map[ch]);
        continue;
      }

      final isLatin = RegExp(r'[a-z0-9]').hasMatch(ch);
      if (isLatin) {
        buffer.write(ch);
        continue;
      }

      if (RegExp(r'[\s\-_]').hasMatch(ch)) {
        buffer.write('_');
      }
    }

    final result = buffer.toString().replaceAll(RegExp('_+'), '_');
    return result.replaceAll(RegExp(r'^_+|_+$'), '');
  }

  String generateReadablePassword() {
    const consonants = 'bcdfghjklmnprstvwxz';
    const vowels = 'aeiouy';

    final b = StringBuffer();
    for (int i = 0; i < 3; i++) {
      b.write(consonants[_random.nextInt(consonants.length)]);
      b.write(vowels[_random.nextInt(vowels.length)]);
    }

    for (int i = 0; i < 4; i++) {
      b.write(_random.nextInt(10));
    }

    return b.toString();
  }

  void _replaceUser(UserAccount updated) {
    _users = _users.map((u) => u.id == updated.id ? updated : u).toList();
  }
}