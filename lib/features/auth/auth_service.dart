import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/api_client.dart';
import '../../core/id.dart';
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

class EmployeeAccountCredentials {
  final String employeeId;
  final String fullName;
  final String login;
  final String password;

  const EmployeeAccountCredentials({
    required this.employeeId,
    required this.fullName,
    required this.login,
    required this.password,
  });
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
  bool _serverHasUsers = true;
  bool get hasUsers => _serverHasUsers;

  Future<void> init() async {
    final api = ApiClient.instance;
    final cached = await Future.wait([
      _storage.loadUsers(),
      _storage.loadRoles(),
    ]);
    _users = cached[0] as List<UserAccount>;
    _roles = cached[1] as List<AppRole>;

    final startup = await Future.wait([
      api.bootstrapRequired().then<Object?>((required) => required).catchError(
            (_) => null,
          ),
      api.restoreSession(),
    ]);
    final bootstrapRequired = startup[0] as bool?;
    if (bootstrapRequired != null) {
      _serverHasUsers = !bootstrapRequired;
    }
    final restored = startup[1] as Map<String, dynamic>?;
    if (restored != null) {
      _currentUser = UserAccount.fromApiJson(restored);
      if (_users.every((user) => user.id != _currentUser!.id)) {
        _users = [..._users, _currentUser!];
      }
    }

    _initialized = true;
    notifyListeners();
    if (_currentUser != null) {
      unawaited(_reloadServerStateInBackground());
    }
  }

  Future<void> _reloadServerStateInBackground() async {
    try {
      await _reloadServerState();
      notifyListeners();
    } catch (_) {
      // Кешированных данных достаточно для работы до восстановления сети.
    }
  }

  Future<void> refreshServerState() async {
    await _reloadServerState();
    notifyListeners();
  }

  Future<EmployeeAccountCredentials?> createAccountForEmployee({
    required EmployeeModel employee,
    required String login,
    String? password,
    bool publishLocalChange = true,
  }) async {
    if (!hasPerm(AppPermission.manageUsers) && !isCurrentUserSuperAdmin) {
      return null;
    }
    if (_users.any((user) => user.employeeId == employee.id)) return null;

    final normalizedLogin = login.trim().toLowerCase();
    if (normalizedLogin.length < 3 ||
        _users.any((user) => user.login.toLowerCase() == normalizedLogin)) {
      return null;
    }

    final parts = employee.fullName
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    final lastName = parts.isNotEmpty ? parts.first : 'Сотрудник';
    final firstName = parts.length > 1 ? parts[1] : 'Пользователь';
    final middleName = parts.length > 2 ? parts.sublist(2).join(' ') : '';
    final generatedPassword = password ?? generateReadablePassword();

    try {
      final data = await ApiClient.instance.request(
        'POST',
        '/api/v1/users',
        body: {
          'login': normalizedLogin,
          'password': generatedPassword,
          'role_id': BuiltInRoleIds.worker,
          'last_name': lastName,
          'first_name': firstName,
          'middle_name': middleName,
          'department_id': null,
          'group_id': null,
          'employee_id': employee.id,
        },
      ) as Map<String, dynamic>;
      final user = UserAccount.fromApiJson(data);
      _users = [..._users, user];
      if (publishLocalChange) {
        await _storage.saveUsers(_users);
        notifyListeners();
      }
      return EmployeeAccountCredentials(
        employeeId: employee.id,
        fullName: employee.fullName,
        login: normalizedLogin,
        password: generatedPassword,
      );
    } on ApiException {
      return null;
    }
  }

  Future<void> _reloadServerState() async {
    final api = ApiClient.instance;
    final roleFuture = api.request('GET', '/api/v1/roles');
    final userFuture = () async {
      try {
        return await api.request('GET', '/api/v1/users') as List;
      } on ApiException catch (error) {
        if (error.statusCode != 403) rethrow;
        return _currentUser == null ? <dynamic>[] : [_currentUser!.toJson()];
      }
    }();
    final results = await Future.wait([roleFuture, userFuture]);
    final roleData = results[0] as List;
    final userData = results[1] as List;

    _roles = roleData
        .whereType<Map>()
        .map((item) => AppRole.fromApiJson(Map<String, dynamic>.from(item)))
        .toList();
    _users = userData.whereType<Map>().map((item) {
      final json = Map<String, dynamic>.from(item);
      return json.containsKey('last_name')
          ? UserAccount.fromApiJson(json)
          : UserAccount.fromJson(json);
    }).toList();

    await Future.wait([
      _storage.saveRoles(_roles),
      _storage.saveUsers(_users),
    ]);
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

  Future<LoginResult> loginDetailed(
    String login,
    String password, {
    bool rememberSession = true,
  }) async {
    try {
      final data = await ApiClient.instance.login(
        login,
        password,
        rememberSession: rememberSession,
      );
      _currentUser = UserAccount.fromApiJson(data);
      _serverHasUsers = true;
      if (_users.every((user) => user.id != _currentUser!.id)) {
        _users = [..._users, _currentUser!];
      }
      notifyListeners();
      unawaited(_reloadServerStateInBackground());
      return const LoginResult.success();
    } on ApiException catch (error) {
      return LoginResult.fail(error.message);
    } catch (_) {
      return const LoginResult.fail(
        'Сервер недоступен. Проверьте интернет-соединение.',
      );
    }
  }

  Future<bool> login(String login, String password) async {
    final result = await loginDetailed(login, password);
    return result.ok;
  }

  Future<void> logout() async {
    await ApiClient.instance.logout();
    _currentUser = null;
    _users = const [];
    _roles = const [];
    notifyListeners();
  }

  Future<String?> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (newPassword.length < 10) {
      return 'Новый пароль должен содержать не менее 10 символов.';
    }
    try {
      await ApiClient.instance.request(
        'POST',
        '/api/v1/auth/change-password',
        body: {
          'current_password': currentPassword,
          'new_password': newPassword,
        },
      );
      await ApiClient.instance.clearSession();
      _currentUser = null;
      _users = const [];
      _roles = const [];
      notifyListeners();
      return null;
    } on ApiException catch (error) {
      return error.message;
    } catch (_) {
      return 'Сервер недоступен. Проверьте интернет-соединение.';
    }
  }

  Future<String?> createFirstAdmin({
    required String login,
    required String password,
  }) async {
    return null;
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
    List<int> employeeCustomWorkdays = const [1, 2, 3, 4, 5],
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

          final newEmployee = EmployeeModel(
            id: newUuidV4(),
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
            customWorkdays: employeeCustomWorkdays,
          );

          await _employeesStorage.create(newEmployee);
          emp = newEmployee.id;
        } else {
          if (emp == null || emp.isEmpty) return false;
        }
        break;
    }

    try {
      await ApiClient.instance.request(
        'POST',
        '/api/v1/users',
        body: {
          'login': normalizedLogin,
          'password': password,
          'role_id': role.id,
          'last_name': normalizedLastName,
          'first_name': normalizedFirstName,
          'middle_name': normalizedMiddleName,
          'department_id': dep,
          'group_id': grp,
          'employee_id': linkedEmployeeId ?? emp,
        },
      );
      await _reloadServerState();
      notifyListeners();
      return true;
    } on ApiException {
      return false;
    }

    // Legacy local-storage fallback kept for data migration builds.
    // ignore: dead_code
    final p = _storage.createPasswordHash(password);

    final user = UserAccount(
      id: newUuidV4(),
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
    required List<int> customWorkdays,
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

    final nameParts = fullName
        .trim()
        .split(RegExp(r'\s+'))
        .where((x) => x.isNotEmpty)
        .toList();
    final lastName = nameParts.isNotEmpty ? nameParts.first : '';
    final firstName = nameParts.length > 1 ? nameParts[1] : fullName.trim();
    final middleName =
        nameParts.length > 2 ? nameParts.sublist(2).join(' ') : '';

    final employee = EmployeeModel(
      id: newUuidV4(),
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
      customWorkdays: customWorkdays,
    );

    await _employeesStorage.create(employee);

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
    try {
      final data = await ApiClient.instance.request(
        'POST',
        '/api/v1/users',
        body: {
          'login': normalizedLogin,
          'password': password,
          'role_id': role.id,
          'last_name': lastName,
          'first_name': firstName,
          'middle_name': middleName,
          'department_id': boundDepartmentId,
          'group_id': boundGroupId,
          'employee_id': employee.id,
        },
      ) as Map<String, dynamic>;
      final user = UserAccount.fromApiJson(data);
      await _reloadServerState();
      notifyListeners();
      return (employee: employee, user: user, password: password);
    } on ApiException {
      return null;
    }

    // ignore: dead_code
    final p = _storage.createPasswordHash(password);

    final user = UserAccount(
      id: newUuidV4(),
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

    try {
      final data = await ApiClient.instance.request(
        'POST',
        '/api/v1/users/$userId/reset-password',
      ) as Map<String, dynamic>;
      await _reloadServerState();
      notifyListeners();
      return data['temporary_password'] as String;
    } on ApiException {
      return null;
    }

    // ignore: dead_code
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

    try {
      final data = await ApiClient.instance.request(
        'PATCH',
        '/api/v1/users/$userId',
        body: {
          'role_id': role.id,
          'last_name': normalizedLastName,
          'first_name': normalizedFirstName,
          'middle_name': normalizedMiddleName,
          'department_id': dep,
          'group_id': grp,
          'employee_id': emp,
          'is_active': true,
        },
      ) as Map<String, dynamic>;
      if (_currentUser?.id == userId) {
        _currentUser = UserAccount.fromApiJson(data);
      }
      await _reloadServerState();
      notifyListeners();
      return true;
    } on ApiException {
      return false;
    }

    // ignore: dead_code
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

    try {
      await ApiClient.instance.request('DELETE', '/api/v1/users/$userId');
      await _reloadServerState();
      notifyListeners();
      return true;
    } on ApiException {
      return false;
    }

    // ignore: dead_code
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

    try {
      await ApiClient.instance.request(
        'POST',
        '/api/v1/roles',
        body: {
          'id': role.id,
          'name': role.name,
          'scope_kind': scopeKindToString(role.scopeKind),
          'permissions': role.permissions.map(permToString).toList(),
        },
      );
      await _reloadServerState();
      notifyListeners();
      return role.id;
    } on ApiException {
      return null;
    }

    // ignore: dead_code
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

    try {
      await ApiClient.instance.request(
        'PATCH',
        '/api/v1/roles/$id',
        body: {
          if (normalizedName != null && normalizedName.isNotEmpty)
            'name': normalizedName,
          if (scopeKind != null) 'scope_kind': scopeKindToString(scopeKind),
          if (permissions != null)
            'permissions': permissions.map(permToString).toList(),
        },
      );
      await _reloadServerState();
      if (affectsCurrentUser) notifyListeners();
      return true;
    } on ApiException {
      return false;
    }

    // ignore: dead_code
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

    try {
      await ApiClient.instance.request('DELETE', '/api/v1/roles/$id');
      await _reloadServerState();
      notifyListeners();
      return true;
    } on ApiException {
      return false;
    }

    // ignore: dead_code
    _roles = _roles.where((r) => r.id != id).toList();
    await _storage.saveRoles(_roles);

    return true;
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

  String generateReadableLoginCode() {
    const consonants = 'bcdfghjklmnprstvz';
    const vowels = 'aeiou';
    final code = StringBuffer();
    for (var index = 0; index < 2; index++) {
      code.write(consonants[_random.nextInt(consonants.length)]);
      code.write(vowels[_random.nextInt(vowels.length)]);
    }
    code.write(_random.nextInt(10));
    code.write(_random.nextInt(10));
    return code.toString();
  }

  void _replaceUser(UserAccount updated) {
    _users = _users.map((u) => u.id == updated.id ? updated : u).toList();
  }
}
