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
  late AppThemeChoice _theme = _preferences.theme;

  @override
  void initState() {
    super.initState();
    AuthService.instance.addListener(_handleAuthChanged);
    _preferences.addListener(_handlePreferencesChanged);
  }

  void _handleAuthChanged() {
    unawaited(_preferences.syncForCurrentUser());
  }

  void _handlePreferencesChanged() {
    final nextTheme = _preferences.theme;
    if (nextTheme == _theme || !mounted) return;
    setState(() => _theme = nextTheme);
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_handleAuthChanged);
    _preferences.removeListener(_handlePreferencesChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.forChoice(_theme);
    return MaterialApp.router(
      title: 'Череда — график смен',
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: theme,
      themeMode: ThemeMode.light,
      routerConfig: _router,
    );
  }
}
