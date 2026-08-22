import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/auth_service.dart';

class OnboardingService {
  OnboardingService._();

  static final OnboardingService instance = OnboardingService._();

  static const int currentVersion = 1;

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<bool> shouldShowForCurrentUser() async {
    final userId = AuthService.instance.currentUser?.id;
    if (userId == null || userId.isEmpty) return false;

    try {
      final stored = await _storage.read(key: _key(userId));
      return int.tryParse(stored ?? '') != currentVersion;
    } catch (_) {
      return true;
    }
  }

  Future<void> completeForCurrentUser() async {
    final userId = AuthService.instance.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    await _storage.write(
      key: _key(userId),
      value: currentVersion.toString(),
    );
  }

  Future<void> resetForCurrentUser() async {
    final userId = AuthService.instance.currentUser?.id;
    if (userId == null || userId.isEmpty) return;
    await _storage.delete(key: _key(userId));
  }

  String _key(String userId) => 'shift_tracker_onboarding_v$userId';
}
