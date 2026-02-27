enum UserRole {
  superAdmin,
  manager,
  master,
  worker,
}

UserRole userRoleFromString(String? s) {
  switch (s) {
    case 'superAdmin':
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

String userRoleToString(UserRole r) => r.name;

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

/// Права (permissions). Легко расширять.
enum AppPermission {
  viewCalendar,
  viewEmployees,
  viewAttendance,
  editAttendance, // отмечать факт, закрывать/переоткрывать день
  editEmployees, // редактировать сотрудников/графики
  manageUsers, // создавать пользователей, назначать роли
  editRolePolicies, // менять права ролей
  viewMoney, // финансы (на будущее)
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
        if (x is String) perms.add(permFromString(x));
      }
    }

    return RolePolicy(role: role, permissions: perms);
  }

  RolePolicy copyWith({Set<AppPermission>? permissions}) => RolePolicy(
        role: role,
        permissions: permissions ?? this.permissions,
      );
}
