import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'auth_models.dart';

class UserAccount {
  final String id;
  final String login;
  final String roleId;

  final String lastName;
  final String firstName;
  final String middleName;

  final String saltB64;
  final String hashB64;
  final int iterations;

  final String? departmentId;
  final String? groupId;
  final String? employeeId;

  final int failedLoginAttempts;
  final String? lockUntilIso;

  const UserAccount({
    required this.id,
    required this.login,
    required this.roleId,
    required this.lastName,
    required this.firstName,
    required this.middleName,
    required this.saltB64,
    required this.hashB64,
    required this.iterations,
    required this.departmentId,
    required this.groupId,
    required this.employeeId,
    this.failedLoginAttempts = 0,
    this.lockUntilIso,
  });

  UserRole get role => userRoleFromString(roleId);

  String get fullName {
    final parts = <String>[
      lastName.trim(),
      firstName.trim(),
      middleName.trim(),
    ].where((x) => x.isNotEmpty).toList();

    if (parts.isEmpty) return login;
    return parts.join(' ');
  }

  DateTime? get lockUntil {
    final raw = lockUntilIso?.trim();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  bool get isLockedNow {
    final until = lockUntil;
    if (until == null) return false;
    return DateTime.now().isBefore(until);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'login': login,
        'roleId': roleId,
        'lastName': lastName,
        'firstName': firstName,
        'middleName': middleName,
        'saltB64': saltB64,
        'hashB64': hashB64,
        'iterations': iterations,
        'departmentId': departmentId,
        'groupId': groupId,
        'employeeId': employeeId,
        'failedLoginAttempts': failedLoginAttempts,
        'lockUntilIso': lockUntilIso,
      };

  static UserAccount fromJson(Map<String, dynamic> json) {
    final legacyFullName = (json['fullName'] as String?)?.trim() ?? '';
    final parts = legacyFullName
        .split(RegExp(r'\s+'))
        .where((x) => x.trim().isNotEmpty)
        .toList();

    final lastName = (json['lastName'] as String?)?.trim() ??
        (parts.isNotEmpty ? parts[0] : '');
    final firstName = (json['firstName'] as String?)?.trim() ??
        (parts.length > 1 ? parts[1] : '');
    final middleName = (json['middleName'] as String?)?.trim() ??
        (parts.length > 2 ? parts.sublist(2).join(' ') : '');

    final roleId = ((json['roleId'] as String?)?.trim().isNotEmpty ?? false)
        ? (json['roleId'] as String).trim()
        : userRoleToString(userRoleFromString(json['role'] as String?));

    return UserAccount(
      id: (json['id'] as String?) ?? '',
      login: (json['login'] as String?) ?? '',
      roleId: roleId,
      lastName: lastName,
      firstName: firstName,
      middleName: middleName,
      saltB64: (json['saltB64'] as String?) ?? '',
      hashB64: (json['hashB64'] as String?) ?? '',
      iterations: (json['iterations'] as int?) ?? 150000,
      departmentId: (json['departmentId'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['departmentId'] as String?)?.trim(),
      groupId: (json['groupId'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['groupId'] as String?)?.trim(),
      employeeId: (json['employeeId'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['employeeId'] as String?)?.trim(),
      failedLoginAttempts: (json['failedLoginAttempts'] as int?) ?? 0,
      lockUntilIso: (json['lockUntilIso'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['lockUntilIso'] as String?)?.trim(),
    );
  }

  static UserAccount fromApiJson(Map<String, dynamic> json) {
    final role = Map<String, dynamic>.from(json['role'] as Map);
    return UserAccount(
      id: json['id'] as String,
      login: json['login'] as String,
      roleId: role['id'] as String,
      lastName: (json['last_name'] as String?) ?? '',
      firstName: (json['first_name'] as String?) ?? '',
      middleName: (json['middle_name'] as String?) ?? '',
      saltB64: '',
      hashB64: '',
      iterations: 0,
      departmentId: json['department_id'] as String?,
      groupId: json['group_id'] as String?,
      employeeId: json['employee_id'] as String?,
    );
  }

  UserAccount copyWith({
    String? login,
    String? roleId,
    UserRole? role,
    String? lastName,
    String? firstName,
    String? middleName,
    String? saltB64,
    String? hashB64,
    int? iterations,
    String? departmentId,
    String? groupId,
    String? employeeId,
    int? failedLoginAttempts,
    String? lockUntilIso,
    bool clearDepartment = false,
    bool clearGroup = false,
    bool clearEmployee = false,
    bool clearLockUntil = false,
  }) {
    return UserAccount(
      id: id,
      login: login ?? this.login,
      roleId: roleId ?? (role != null ? userRoleToString(role) : this.roleId),
      lastName: lastName ?? this.lastName,
      firstName: firstName ?? this.firstName,
      middleName: middleName ?? this.middleName,
      saltB64: saltB64 ?? this.saltB64,
      hashB64: hashB64 ?? this.hashB64,
      iterations: iterations ?? this.iterations,
      departmentId:
          clearDepartment ? null : (departmentId ?? this.departmentId),
      groupId: clearGroup ? null : (groupId ?? this.groupId),
      employeeId: clearEmployee ? null : (employeeId ?? this.employeeId),
      failedLoginAttempts: failedLoginAttempts ?? this.failedLoginAttempts,
      lockUntilIso: clearLockUntil ? null : (lockUntilIso ?? this.lockUntilIso),
    );
  }
}

class AuthStorage {
  static const _usersFile = 'users.json';
  static const _rolesFile = 'roles.json';

  Future<File> _file(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  Future<List<UserAccount>> loadUsers() async {
    try {
      final f = await _file(_usersFile);
      if (!await f.exists()) return [];
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];

      return decoded
          .whereType<Map>()
          .map((m) => UserAccount.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveUsers(List<UserAccount> users) async {
    final f = await _file(_usersFile);
    final list = users.map((u) => u.toJson()).toList();
    await f.writeAsString(jsonEncode(list));
  }

  Future<List<AppRole>> loadRoles() async {
    try {
      final f = await _file(_rolesFile);
      if (!await f.exists()) return [];
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];

      return decoded
          .whereType<Map>()
          .map((m) => AppRole.fromJson(Map<String, dynamic>.from(m)))
          .where((r) => r.id.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveRoles(List<AppRole> roles) async {
    final f = await _file(_rolesFile);
    final list = roles.map((r) => r.toJson()).toList();
    await f.writeAsString(jsonEncode(list));
  }
}
