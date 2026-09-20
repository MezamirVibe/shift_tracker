import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/auth_models.dart';
import '../../features/auth/auth_service.dart';

class NavItem {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final String? route;

  const NavItem({
    required this.label,
    required this.icon,
    required this.onTap,
    this.route,
  });
}

class AdaptiveScaffold extends StatelessWidget {
  final String title;
  final int? selectedIndex;
  final String? selectedRoute;
  final List<NavItem>? items;
  final List<Widget> actions;
  final Widget child;

  final Widget? floatingActionButton;

  const AdaptiveScaffold({
    super.key,
    required this.title,
    required this.child,
    this.selectedIndex,
    this.selectedRoute,
    this.items,
    this.actions = const [],
    this.floatingActionButton,
  });

  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 980;

  List<NavItem> _defaultItems(BuildContext context) {
    final auth = AuthService.instance;
    final currentRole = auth.roleById(auth.currentUser?.roleId);
    final canEmployees = currentRole?.scopeKind != ScopeKind.self &&
        auth.hasPerm(AppPermission.viewEmployees);
    return [
      NavItem(
        label: 'Главная',
        icon: Icons.home_outlined,
        route: '/',
        onTap: () => context.go('/'),
      ),
      NavItem(
        label: 'График',
        icon: Icons.calendar_view_week_outlined,
        route: '/schedule',
        onTap: () => context.go('/schedule'),
      ),
      if (canEmployees)
        NavItem(
          label: 'Табель',
          icon: Icons.table_view_outlined,
          route: '/timesheet',
          onTap: () => context.go('/timesheet'),
        ),
      if (canEmployees)
        NavItem(
          label: 'Сотрудники',
          icon: Icons.people_outline,
          route: '/employees',
          onTap: () => context.go('/employees'),
        ),
      NavItem(
        label: 'Настройки',
        icon: Icons.settings_outlined,
        route: '/settings',
        onTap: () => context.go('/settings'),
      ),
    ];
  }

  int _resolvedIndex(List<NavItem> resolvedItems) {
    if (selectedRoute != null) {
      final matched = resolvedItems.indexWhere(_matchesRoute);
      if (matched >= 0) return matched;
      final exact = resolvedItems.indexWhere(
        (item) => item.route == selectedRoute,
      );
      if (exact >= 0) return exact;
      if (selectedRoute!.startsWith('/day/') || selectedRoute == '/calendar') {
        final schedule = resolvedItems.indexWhere(
          (item) => item.route == '/schedule',
        );
        if (schedule >= 0) return schedule;
      }
    }
    final legacy = selectedIndex ?? 0;
    return legacy.clamp(0, resolvedItems.length - 1);
  }

  bool _matchesRoute(NavItem item) {
    final route = selectedRoute;
    if (route == null) return false;
    if (item.route == route) return true;
    if (item.route == '/schedule') {
      return route.startsWith('/day/') || route == '/calendar';
    }
    if (item.route == '/employees') return route.startsWith('/employee/');
    if (item.route == '/settings') return route == '/admin';
    if (item.route == '/timesheet') return route.startsWith('/timesheet/');
    return false;
  }

  Future<void> _showMobileMore(
    BuildContext context,
    List<NavItem> items,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                'Настройки',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            for (final item in items)
              ListTile(
                leading: Icon(item.icon),
                title: Text(item.label),
                selected: _matchesRoute(item),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  item.onTap();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktop(context);
    final resolvedItems = items ?? _defaultItems(context);
    final resolvedIndex = _resolvedIndex(resolvedItems);

    if (!desktop) {
      final primaryItems = resolvedItems
          .where(
            (item) =>
                item.route == '/' ||
                item.route == '/schedule' ||
                item.route == '/timesheet' ||
                item.route == '/employees',
          )
          .toList();
      final moreItems =
          resolvedItems.where((item) => !primaryItems.contains(item)).toList();
      final primaryIndex = primaryItems.indexWhere(_matchesRoute);
      final mobileIndex = primaryIndex >= 0 ? primaryIndex : 0;
      // NavigationBar lays out labels separately from icons; a fixed height
      // can silently clip wrapped labels without reporting a RenderFlex error.
      final compactLabels = MediaQuery.sizeOf(context).width < 380;
      String mobileLabel(NavItem item) =>
          item.route == '/employees' ? 'Люди' : item.label;
      final labels = [
        for (final item in primaryItems) mobileLabel(item),
      ];
      final labelStyle = (compactLabels
          ? Theme.of(context).textTheme.labelSmall
          : Theme.of(context).textTheme.labelMedium)!;
      var navigationHeight = 80.0;
      for (final label in labels) {
        final painter = TextPainter(
          text: TextSpan(text: label, style: labelStyle),
          textDirection: Directionality.of(context),
          textScaler:
              MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
        )..layout(
            maxWidth: MediaQuery.sizeOf(context).width / labels.length - 4);
        final requiredHeight = 56 + painter.height * 2;
        if (requiredHeight > navigationHeight) {
          navigationHeight = requiredHeight;
        }
        painter.dispose();
      }

      return Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: selectedRoute == '/settings' || selectedRoute == '/admin'
              ? BackButton(
                  onPressed: () =>
                      context.go(selectedRoute == '/admin' ? '/settings' : '/'))
              : null,
          actions: [
            ...actions,
            if (selectedRoute != '/settings')
              IconButton(
                tooltip: 'Настройки',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () {
                  if (items == null) {
                    context.go('/settings');
                  } else {
                    _showMobileMore(context, moreItems);
                  }
                },
              ),
          ],
        ),
        body: child,
        floatingActionButton: floatingActionButton,
        bottomNavigationBar: selectedRoute == '/settings' ||
                selectedRoute == '/admin'
            ? null
            : NavigationBar(
                height: navigationHeight,
                labelTextStyle: WidgetStatePropertyAll(labelStyle),
                selectedIndex: mobileIndex,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                onDestinationSelected: (idx) {
                  if (idx < primaryItems.length) {
                    primaryItems[idx].onTap();
                    return;
                  }
                },
                destinations: [
                  for (final item in primaryItems)
                    NavigationDestination(
                      icon: Icon(item.icon),
                      label: mobileLabel(item),
                    ),
                ],
              ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 224,
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border(
                right: BorderSide(color: scheme.outlineVariant),
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 16, 24),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Image.asset(
                            'assets/branding/chereda_app_icon.png',
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Череда',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                'График смен',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      itemCount: resolvedItems.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final item = resolvedItems[index];
                        final selected = index == resolvedIndex;
                        return Material(
                          color: selected
                              ? scheme.primaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            onTap: item.onTap,
                            borderRadius: BorderRadius.circular(10),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 11,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    item.icon,
                                    size: 22,
                                    color: selected
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      item.label,
                                      style: TextStyle(
                                        color: selected
                                            ? scheme.primary
                                            : scheme.onSurface,
                                        fontWeight: selected
                                            ? FontWeight.w600
                                            : FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  _AccountFooter(onTap: () => context.go('/settings')),
                ],
              ),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 76,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    border: Border(
                      bottom: BorderSide(
                        color: scheme.outlineVariant.withValues(alpha: 0.65),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                      ),
                      ...actions,
                    ],
                  ),
                ),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: floatingActionButton,
    );
  }
}

class _AccountFooter extends StatelessWidget {
  final VoidCallback onTap;

  const _AccountFooter({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    final user = auth.currentUser;
    final role = auth.roleById(user?.roleId);
    final name = user?.fullName ?? user?.login ?? 'Пользователь';
    final parts = name.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty);
    final initials = parts.take(2).map((x) => x[0].toUpperCase()).join();
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                CircleAvatar(
                    radius: 18, child: Text(initials.isEmpty ? 'U' : initials)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      Text(
                        role?.name ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
