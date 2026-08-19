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
    final canEmployees = auth.hasPerm(AppPermission.viewEmployees);
    final canAdmin = auth.isCurrentUserSuperAdmin ||
        auth.hasPerm(AppPermission.manageUsers) ||
        auth.hasPerm(AppPermission.editRolePolicies);
    return [
      NavItem(
        label: 'Главная',
        icon: Icons.home_outlined,
        route: '/',
        onTap: () => context.go('/'),
      ),
      NavItem(
        label: 'График',
        icon: Icons.calendar_month_outlined,
        route: '/schedule',
        onTap: () => context.go('/schedule'),
      ),
      NavItem(
        label: 'Календарь',
        icon: Icons.calendar_month_outlined,
        route: '/calendar',
        onTap: () => context.go('/calendar'),
      ),
      if (canEmployees)
        NavItem(
          label: 'Сотрудники',
          icon: Icons.people_outline,
          route: '/employees',
          onTap: () => context.go('/employees'),
        ),
      if (canAdmin)
        NavItem(
          label: 'Управление',
          icon: Icons.admin_panel_settings_outlined,
          route: '/admin',
          onTap: () => context.go('/admin'),
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
      final exact = resolvedItems.indexWhere(
        (item) => item.route == selectedRoute,
      );
      if (exact >= 0) return exact;
      if (selectedRoute!.startsWith('/day/')) {
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
    return item.route == '/schedule' && route.startsWith('/day/');
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                'Ещё',
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
                item.route == '/calendar',
          )
          .toList();
      final moreItems =
          resolvedItems.where((item) => !primaryItems.contains(item)).toList();
      final primaryIndex = primaryItems.indexWhere(_matchesRoute);
      final mobileIndex = primaryIndex >= 0 ? primaryIndex : 3;

      return Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: actions,
        ),
        body: child,
        floatingActionButton: floatingActionButton,
        bottomNavigationBar: NavigationBar(
          selectedIndex: mobileIndex,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (idx) {
            if (idx < primaryItems.length) {
              primaryItems[idx].onTap();
              return;
            }
            _showMobileMore(context, moreItems);
          },
          destinations: [
            for (final item in primaryItems)
              NavigationDestination(
                icon: Icon(item.icon),
                label: item.label,
              ),
            const NavigationDestination(
              icon: Icon(Icons.more_horiz),
              label: 'Ещё',
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
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Icon(
                            Icons.calendar_view_week_rounded,
                            color: scheme.onPrimary,
                          ),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Shift Tracker',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                'Рабочие смены',
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
