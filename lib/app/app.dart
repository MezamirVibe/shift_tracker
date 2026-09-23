import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/auth_service.dart';
import '../features/preferences/preferences_service.dart';
import '../features/updates/app_update_service.dart';
import '../features/updates/app_update_dialog.dart';
import 'router.dart';
import 'theme.dart';

class ShiftTrackerApp extends StatefulWidget {
  const ShiftTrackerApp({super.key});

  @override
  State<ShiftTrackerApp> createState() => _ShiftTrackerAppState();
}

class _ShiftTrackerAppState extends State<ShiftTrackerApp>
    with WidgetsBindingObserver {
  late final GoRouter _router = AppRouter.makeRouter();
  final _preferences = PreferencesService.instance;
  late AppThemeChoice _theme = _preferences.theme;
  final _updates = AppUpdateService.instance;
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  int? _notifiedBuild;

  @override
  void initState() {
    super.initState();
    AuthService.instance.addListener(_handleAuthChanged);
    _preferences.addListener(_handlePreferencesChanged);
    WidgetsBinding.instance.addObserver(this);
    _updates.addListener(_handleUpdateChanged);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => unawaited(_checkUpdates()));
  }

  Future<void> _checkUpdates() async {
    await _updates.check();
    await _updates.readPreviousInstallResult();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_updates.check());
  }

  void _handleUpdateChanged() {
    final release = _updates.release;
    if (!mounted ||
        !AuthService.instance.isLoggedIn ||
        release == null ||
        _updates.phase != UpdatePhase.available ||
        _notifiedBuild == release.build) return;
    final navigatorContext = _router.routerDelegate.navigatorKey.currentContext;
    if (navigatorContext == null || _messenger.currentState == null) return;
    _notifiedBuild = release.build;
    _messenger.currentState!.showSnackBar(SnackBar(
      content: Text('Доступна «Череда» ${release.version}'),
      duration: const Duration(seconds: 10),
      action: SnackBarAction(
          label: 'Обновить',
          onPressed: () => showAppUpdateDialog(navigatorContext)),
    ));
  }

  void _handleAuthChanged() {
    unawaited(_preferences.syncForCurrentUser());
    _handleUpdateChanged();
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
    _updates.removeListener(_handleUpdateChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.forChoice(_theme);
    return MaterialApp.router(
      title: 'Череда — график смен',
      scaffoldMessengerKey: _messenger,
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru', 'RU'),
      supportedLocales: const [Locale('ru', 'RU')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: theme,
      darkTheme: theme,
      themeMode: ThemeMode.light,
      routerConfig: _router,
    );
  }
}
