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
  final UserRole role;

  // password storage
  final String saltB64;
  final String hashB64;
  final int iterations;

  const UserAccount({
    required this.id,
    required this.login,
    required this.role,
    required this.saltB64,
    required this.hashB64,
    required this.iterations,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'login': login,
        'role': userRoleToString(role),
        'saltB64': saltB64,
        'hashB64': hashB64,
        'iterations': iterations,
      };

  static UserAccount fromJson(Map<String, dynamic> json) {
    return UserAccount(
      id: (json['id'] as String?) ?? '',
      login: (json['login'] as String?) ?? '',
      role: userRoleFromString(json['role'] as String?),
      saltB64: (json['saltB64'] as String?) ?? '',
      hashB64: (json['hashB64'] as String?) ?? '',
      iterations: (json['iterations'] as int?) ?? 150000,
    );
  }

  UserAccount copyWith({
    String? login,
    UserRole? role,
    String? saltB64,
    String? hashB64,
    int? iterations,
  }) {
    return UserAccount(
      id: id,
      login: login ?? this.login,
      role: role ?? this.role,
      saltB64: saltB64 ?? this.saltB64,
      hashB64: hashB64 ?? this.hashB64,
      iterations: iterations ?? this.iterations,
    );
  }
}

class AuthStorage {
  static const _usersFile = 'users.json';
  static const _sessionFile = 'session.json';
  static const _rolePoliciesFile = 'role_policies.json';

  Future<File> _file(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  // ---------------- Users ----------------

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

  // ---------------- Session ----------------

  Future<String?> loadSessionUserId() async {
    try {
      final f = await _file(_sessionFile);
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
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

  // ---------------- Role policies ----------------

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

  // ---------------- Password hashing (PBKDF2-HMAC-SHA256) ----------------

  Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  Uint8List _pbkdf2Sha256({
    required String password,
    required Uint8List salt,
    required int iterations,
    required int dkLen,
  }) {
    final passBytes = utf8.encode(password);
    final hmac = (List<int> key, List<int> msg) => Hmac(sha256, key).convert(msg).bytes;

    final hLen = sha256.convert(const <int>[]).bytes.length; // 32
    final l = (dkLen / hLen).ceil();
    final out = BytesBuilder();

    for (int i = 1; i <= l; i++) {
      final blockIndex = ByteData(4)..setUint32(0, i, Endian.big);
      final saltPlus = Uint8List.fromList([...salt, ...blockIndex.buffer.asUint8List()]);

      var u = hmac(passBytes, saltPlus);
      var t = Uint8List.fromList(u);

      for (int j = 2; j <= iterations; j++) {
        u = hmac(passBytes, u);
        for (int k = 0; k < t.length; k++) {
          t[k] = t[k] ^ u[k];
        }
      }

      out.add(t);
    }

    final dk = out.toBytes();
    return dk.sublist(0, dkLen);
  }

  ({String saltB64, String hashB64, int iterations}) createPasswordHash(String password) {
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
