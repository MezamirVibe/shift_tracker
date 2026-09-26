import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'auth_service.dart';
import '../../core/api_client.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await AuthService.instance.init();

    if (!mounted) return;

    final auth = AuthService.instance;
    if (ApiClient.instance.organization == null) {
      context.go('/organization');
      return;
    }
    if (!auth.hasUsers) {
      context.go('/login');
      return;
    }

    if (auth.isLoggedIn) {
      context.go('/');
      return;
    }

    context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
