import 'package:flutter/foundation.dart';

import '../../shared/extensions/iterable_x.dart';
import '../employees/employees_storage.dart';
import 'auth_models.dart';
import 'auth_storage.dart';

class AuthService extends ChangeNotifier {
  AuthService._();
  static final AuthService instance = AuthService._();

  final AuthStorage _storage = AuthStorage();
  final EmployeesStorage _employeesStorage = EmployeesStorage();

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
        return 'Для этой роли нужен сотрудник. Можно привязать существующего или создать нового.';
      case ScopeKind.all:
        return 'Эта роль видит всё, привязка не требуется.';
    }
  }

  Future<bool> login(String login, String password) async {
    final user = _users
        .where((u) => u.login == login.trim())
        .cast<UserAccount?>()
        .firstOrNull;
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
        emp = null;
        break;

      case ScopeKind.department:
        grp = null;
        emp = null;
        if (dep == null || dep.isEmpty) return false;
        break;

      case ScopeKind.group:
        emp = null;
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
      employeeId: emp,
    );

    _users = [..._users, user];
    await _storage.saveUsers(_users);
    notifyListeners();
    return true;
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
    String? emp = employeeId?.trim();

    switch (role.scopeKind) {
      case ScopeKind.all:
        dep = null;
        grp = null;
        emp = null;
        break;

      case ScopeKind.department:
        grp = null;
        emp = null;
        if (dep == null || dep.isEmpty) return false;
        break;

      case ScopeKind.group:
        dep = null;
        emp = null;
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

  Future<bool> createRole({
    required String id,
    required String name,
    required ScopeKind scopeKind,
    Set<AppPermission> permissions = const {},
  }) async {
    final can =
        isCurrentUserSuperAdmin || hasPerm(AppPermission.editRolePolicies);
    if (!can) return false;

    final normalizedName = name.trim();
    if (normalizedName.isEmpty) return false;

    final generatedId = _generateUniqueRoleId(normalizedName);
    if (generatedId.isEmpty) return false;

    final role = AppRole(
      id: generatedId,
      name: normalizedName,
      scopeKind: scopeKind,
      permissions: Set<AppPermission>.from(permissions),
      isSystem: false,
    );

    _roles = [..._roles, role];
    await _storage.saveRoles(_roles);

    return true;
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

  String _generateUniqueRoleId(String roleName) {
    final base = _slugifyRoleName(roleName);
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
}