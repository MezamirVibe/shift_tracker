enum UserRole {
  superAdmin,
  manager,
  master,
  worker,
}

UserRole userRoleFromString(String? s) {
  switch (s) {
    case 'superAdmin':
    case 'super_admin':
      return UserRole.superAdmin;
    case 'manager':
      return UserRole.manager;
    case 'master':
      return UserRole.master;
    case 'worker':
      return UserRole.worker;
    default:
      return UserRole.worker;
  }
}

String userRoleToString(UserRole r) {
  switch (r) {
    case UserRole.superAdmin:
      return BuiltInRoleIds.superAdmin;
    case UserRole.manager:
      return BuiltInRoleIds.manager;
    case UserRole.master:
      return BuiltInRoleIds.master;
    case UserRole.worker:
      return BuiltInRoleIds.worker;
  }
}

String roleLabel(UserRole r) {
  switch (r) {
    case UserRole.superAdmin:
      return 'Суперадмин';
    case UserRole.manager:
      return 'Руководитель';
    case UserRole.master:
      return 'Мастер';
    case UserRole.worker:
      return 'Рабочий';
  }
}

class BuiltInRoleIds {
  static const String superAdmin = 'super_admin';
  static const String manager = 'manager';
  static const String master = 'master';
  static const String worker = 'worker';

  static const Set<String> all = {
    superAdmin,
    manager,
    master,
    worker,
  };
}

String roleIdFromLegacyRole(UserRole role) => userRoleToString(role);

String roleLabelById(String roleId) {
  switch (roleId) {
    case BuiltInRoleIds.superAdmin:
      return 'Суперадмин';
    case BuiltInRoleIds.manager:
      return 'Руководитель';
    case BuiltInRoleIds.master:
      return 'Мастер';
    case BuiltInRoleIds.worker:
      return 'Рабочий';
    default:
      return roleId;
  }
}

enum ScopeKind {
  all,
  department,
  group,
  self,
}

ScopeKind scopeKindFromString(String? s) {
  switch (s) {
    case 'all':
      return ScopeKind.all;
    case 'department':
      return ScopeKind.department;
    case 'group':
      return ScopeKind.group;
    case 'self':
      return ScopeKind.self;
    default:
      return ScopeKind.self;
  }
}

String scopeKindToString(ScopeKind s) => s.name;

String scopeKindLabel(ScopeKind s) {
  switch (s) {
    case ScopeKind.all:
      return 'Видит всё';
    case ScopeKind.department:
      return 'Видит подразделение';
    case ScopeKind.group:
      return 'Видит группу';
    case ScopeKind.self:
      return 'Видит только себя';
  }
}

enum AppPermission {
  viewCalendar,
  viewEmployees,
  viewAttendance,
  editAttendance,
  editEmployees,
  manageUsers,
  editRolePolicies,
  viewMoney,
}

AppPermission permFromString(String? s) {
  for (final p in AppPermission.values) {
    if (p.name == s) return p;
  }
  return AppPermission.viewCalendar;
}

String permToString(AppPermission p) => p.name;

String permLabel(AppPermission p) {
  switch (p) {
    case AppPermission.viewCalendar:
      return 'Просмотр календаря';
    case AppPermission.viewEmployees:
      return 'Просмотр сотрудников';
    case AppPermission.viewAttendance:
      return 'Просмотр факта';
    case AppPermission.editAttendance:
      return 'Редактирование факта';
    case AppPermission.editEmployees:
      return 'Редактирование сотрудников';
    case AppPermission.manageUsers:
      return 'Управление пользователями';
    case AppPermission.editRolePolicies:
      return 'Настройка прав ролей';
    case AppPermission.viewMoney:
      return 'Просмотр финансов';
  }
}

class AppRole {
  final String id;
  final String name;
  final ScopeKind scopeKind;
  final Set<AppPermission> permissions;
  final bool isSystem;

  const AppRole({
    required this.id,
    required this.name,
    required this.scopeKind,
    required this.permissions,
    this.isSystem = false,
  });

  bool has(AppPermission permission) => permissions.contains(permission);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'scopeKind': scopeKindToString(scopeKind),
        'permissions': permissions.map(permToString).toList(),
        'isSystem': isSystem,
      };

  static AppRole fromJson(Map<String, dynamic> json) {
    final perms = <AppPermission>{};
    final permsRaw = json['permissions'];
    if (permsRaw is List) {
      for (final x in permsRaw) {
        if (x is String) {
          perms.add(permFromString(x));
        }
      }
    }

    final rawId = (json['id'] as String?)?.trim() ?? '';
    final rawName = (json['name'] as String?)?.trim() ?? '';

    return AppRole(
      id: rawId,
      name: rawName.isEmpty ? roleLabelById(rawId) : rawName,
      scopeKind: scopeKindFromString(json['scopeKind'] as String?),
      permissions: perms,
      isSystem: json['isSystem'] == true,
    );
  }

  AppRole copyWith({
    String? id,
    String? name,
    ScopeKind? scopeKind,
    Set<AppPermission>? permissions,
    bool? isSystem,
  }) {
    return AppRole(
      id: id ?? this.id,
      name: name ?? this.name,
      scopeKind: scopeKind ?? this.scopeKind,
      permissions: permissions ?? this.permissions,
      isSystem: isSystem ?? this.isSystem,
    );
  }
}

///
/// Legacy-совместимость для миграции со старого role_policies.json.
///
class RolePolicy {
  final UserRole role;
  final Set<AppPermission> permissions;

  const RolePolicy({
    required this.role,
    required this.permissions,
  });

  bool has(AppPermission p) => permissions.contains(p);

  Map<String, dynamic> toJson() => {
        'role': userRoleToString(role),
        'permissions': permissions.map(permToString).toList(),
      };

  static RolePolicy fromJson(Map<String, dynamic> json) {
    final role = userRoleFromString(json['role'] as String?);

    final perms = <AppPermission>{};
    final permsRaw = json['permissions'];
    if (permsRaw is List) {
      for (final x in permsRaw) {
        if (x is String) {
          perms.add(permFromString(x));
        }
      }
    }

    return RolePolicy(
      role: role,
      permissions: perms,
    );
  }

  RolePolicy copyWith({Set<AppPermission>? permissions}) => RolePolicy(
        role: role,
        permissions: permissions ?? this.permissions,
      );
}