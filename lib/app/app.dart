import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/auth_service.dart';
import '../features/preferences/preferences_service.dart';
import 'router.dart';
import 'theme.dart';

class ShiftTrackerApp extends StatefulWidget {
  const ShiftTrackerApp({super.key});

  @override
  State<ShiftTrackerApp> createState() => _ShiftTrackerAppState();
}

class _ShiftTrackerAppState extends State<ShiftTrackerApp> {
  late final GoRouter _router = AppRouter.makeRouter();
  final _preferences = PreferencesService.instance;

  @override
  void initState() {
    super.initState();
    AuthService.instance.addListener(_handleAuthChanged);
  }

  void _handleAuthChanged() {
    unawaited(_preferences.syncForCurrentUser());
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_handleAuthChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _preferences,
      builder: (context, _) {
        final theme = AppTheme.forChoice(_preferences.theme);
        return MaterialApp.router(
          title: 'Shift Tracker',
          debugShowCheckedModeBanner: false,
          theme: theme,
          darkTheme: theme,
          themeMode: ThemeMode.light,
          routerConfig: _router,
        );
      },
    );
  }
}
