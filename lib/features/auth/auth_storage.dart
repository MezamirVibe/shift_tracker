import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'auth_models.dart';

class UserAccount {
  final String id;
  final String login;
  final String roleId;

  final String lastName;
  final String firstName;
  final String middleName;

  // password storage
  final String saltB64;
  final String hashB64;
  final int iterations;

  // scope bindings
  final String? departmentId;
  final String? groupId;
  final String? employeeId;

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
  });

  /// Legacy-совместимость для старого кода.
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
    bool clearDepartment = false,
    bool clearGroup = false,
    bool clearEmployee = false,
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
    );
  }
}

class AuthStorage {
  static const _usersFile = 'users.json';
  static const _sessionFile = 'session.json';
  static const _rolePoliciesFile = 'role_policies.json'; // legacy
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

  Future<String?> loadSessionUserId() async {
    try {
      final f = await _file(_sessionFile);
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded['userId'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSessionUserId(String? userId) async {
    final f = await _file(_sessionFile);
    if (userId == null) {
      if (await f.exists()) await f.delete();
      return;
    }
    await f.writeAsString(jsonEncode({'userId': userId}));
  }

  Future<List<RolePolicy>> loadRolePolicies() async {
    try {
      final f = await _file(_rolePoliciesFile);
      if (!await f.exists()) return [];
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];

      return decoded
          .whereType<Map>()
          .map((m) => RolePolicy.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveRolePolicies(List<RolePolicy> policies) async {
    final f = await _file(_rolePoliciesFile);
    final list = policies.map((p) => p.toJson()).toList();
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

  Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  List<int> _hmacSha256(List<int> key, List<int> msg) {
    return Hmac(sha256, key).convert(msg).bytes;
  }

  Uint8List _pbkdf2Sha256({
    required String password,
    required Uint8List salt,
    required int iterations,
    required int dkLen,
  }) {
    final passBytes = utf8.encode(password);
    final hLen = sha256.convert(const []).bytes.length;
    final l = (dkLen / hLen).ceil();

    final out = BytesBuilder();
    for (int i = 1; i <= l; i++) {
      final blockIndex = ByteData(4)..setUint32(0, i, Endian.big);
      final saltPlus = Uint8List.fromList(
        [...salt, ...blockIndex.buffer.asUint8List()],
      );

      var u = _hmacSha256(passBytes, saltPlus);
      final t = Uint8List.fromList(u);

      for (int j = 2; j <= iterations; j++) {
        u = _hmacSha256(passBytes, u);
        for (int k = 0; k < t.length; k++) {
          t[k] = t[k] ^ u[k];
        }
      }

      out.add(t);
    }

    final dk = out.toBytes();
    return dk.sublist(0, dkLen);
  }

  ({String saltB64, String hashB64, int iterations}) createPasswordHash(
    String password,
  ) {
    final salt = _randomBytes(16);
    const iterations = 150000;

    final dk = _pbkdf2Sha256(
      password: password,
      salt: salt,
      iterations: iterations,
      dkLen: 32,
    );

    return (
      saltB64: base64Encode(salt),
      hashB64: base64Encode(dk),
      iterations: iterations,
    );
  }

  bool verifyPassword({
    required String password,
    required String saltB64,
    required String hashB64,
    required int iterations,
  }) {
    try {
      final salt = base64Decode(saltB64);
      final expected = base64Decode(hashB64);

      final dk = _pbkdf2Sha256(
        password: password,
        salt: salt,
        iterations: iterations,
        dkLen: expected.length,
      );

      if (dk.length != expected.length) return false;

      int diff = 0;
      for (int i = 0; i < dk.length; i++) {
        diff |= (dk[i] ^ expected[i]);
      }
      return diff == 0;
    } catch (_) {
      return false;
    }
  }
}