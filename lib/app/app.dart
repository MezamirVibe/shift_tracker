import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/auth_service.dart';
import '../features/preferences/preferences_service.dart';
import '../features/notifications/notifications_service.dart';
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
  final _notifications = NotificationsService.instance;
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  int? _notifiedBuild;

  @override
  void initState() {
    super.initState();
    AuthService.instance.addListener(_handleAuthChanged);
    _preferences.addListener(_handlePreferencesChanged);
    WidgetsBinding.instance.addObserver(this);
    _updates.addListener(_handleUpdateChanged);
    _notifications.onOpen = _openNotification;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_checkUpdates());
      _syncNotifications();
    });
  }

  Future<void> _checkUpdates() async {
    await _updates.check();
    await _updates.readPreviousInstallResult();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _notifications.setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) unawaited(_updates.check());
  }

  void _syncNotifications() {
    final auth = AuthService.instance;
    // Wait for secure session restoration before clearing a cold-start binding.
    if (!auth.initialized) return;
    unawaited(_notifications.syncSession(signedIn: auth.isLoggedIn));
  }

  void _openNotification(String route) {
    if (!mounted || !AuthService.instance.isLoggedIn) return;
    if (_router.routeInformationProvider.value.uri.toString() == route) return;
    _router.push(route);
  }

  void _handleUpdateChanged() {
    final release = _updates.release;
    if (!mounted ||
        !AuthService.instance.isLoggedIn ||
        release == null ||
        _updates.phase != UpdatePhase.available ||
        _notifiedBuild == release.build) {
      return;
    }
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
    _syncNotifications();
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
    _notifications.onOpen = null;
    _notifications.setForeground(false);
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
