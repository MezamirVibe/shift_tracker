import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/auth_service.dart';

class OnboardingService {
  OnboardingService._();

  static final OnboardingService instance = OnboardingService._();

  // Версия повышается при существенном изменении рабочих сценариев, чтобы
  // действующие пользователи тоже увидели актуальное обучение.
  static const int currentVersion = 2;

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<bool> shouldShowForCurrentUser() async {
    final user = AuthService.instance.currentUser;
    if (user == null || user.id.isEmpty) return false;

    try {
      final stored = await _storage.read(key: _key(user.id, user.roleId));
      return int.tryParse(stored ?? '') != currentVersion;
    } catch (_) {
      return true;
    }
  }

  Future<void> completeForCurrentUser() async {
    final user = AuthService.instance.currentUser;
    if (user == null || user.id.isEmpty) return;

    await _storage.write(
      key: _key(user.id, user.roleId),
      value: currentVersion.toString(),
    );
  }

  Future<void> resetForCurrentUser() async {
    final user = AuthService.instance.currentUser;
    if (user == null || user.id.isEmpty) return;
    await _storage.delete(key: _key(user.id, user.roleId));
  }

  String _key(String userId, String roleId) =>
      'shift_tracker_onboarding_${userId}_$roleId';
}
