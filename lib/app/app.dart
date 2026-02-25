import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'router.dart';
import 'theme.dart';

class ShiftTrackerApp extends StatefulWidget {
  const ShiftTrackerApp({super.key});

  @override
  State<ShiftTrackerApp> createState() => _ShiftTrackerAppState();
}

class _ShiftTrackerAppState extends State<ShiftTrackerApp> {
  ThemeMode _themeMode = ThemeMode.system;
  late final GoRouter _router = AppRouter.makeRouter();

  void _toggleTheme() {
    setState(() {
      _themeMode = switch (_themeMode) {
        ThemeMode.system => ThemeMode.dark,
        ThemeMode.dark => ThemeMode.light,
        ThemeMode.light => ThemeMode.system,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Учёт смен',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode,
      routerConfig: _router,
      builder: (context, child) {
        return _AppShell(
          onToggleTheme: _toggleTheme,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

class _AppShell extends InheritedWidget {
  final VoidCallback onToggleTheme;

  const _AppShell({
    required this.onToggleTheme,
    required super.child,
  });

  static _AppShell of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_AppShell>()!;

  @override
  bool updateShouldNotify(_AppShell oldWidget) =>
      onToggleTheme != oldWidget.onToggleTheme;
}

VoidCallback themeToggleOf(BuildContext context) =>
    _AppShell.of(context).onToggleTheme;
